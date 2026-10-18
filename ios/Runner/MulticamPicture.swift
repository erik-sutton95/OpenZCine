import MonitorUI
import OpenCineAppKit
import OpenCineMedia
import OpenZCineCore
import SwiftUI
import UIKit

import class OpenCineCameraVocabulary.CustomLUTStore

/// One member's tile picture: the latest accepted raw frame from its own link and, when its LUT is
/// on, that frame baked through the production `LiveFrameProcessor` graph on the member's own
/// renderer. No frame from another member or from the single-camera monitor reaches it.
///
/// Lifetime fencing: a bake captures the owner epoch (bumped when the member's link is replaced,
/// fails or stops), the look revision and the source generation before it awaits. It publishes
/// only while the epoch and look are unchanged and it is not older than the picture shown. At most
/// one bake runs per member; frames that arrive meanwhile collapse to the newest.
@MainActor
@Observable
final class MulticamMemberPicture {
    /// What the tile shows: the raw frame, or the baked frame while the LUT is on.
    private(set) var image: UIImage?
    private(set) var lutEnabled = false
    private(set) var lutSelection: LUTSelection

    @ObservationIgnored private let renderer: LiveFrameRenderer
    @ObservationIgnored private var raw: UIImage?
    @ObservationIgnored private var epoch: UInt64 = 0
    @ObservationIgnored private(set) var sourceGeneration: UInt64 = 0
    @ObservationIgnored private(set) var lookRevision: UInt64 = 0
    @ObservationIgnored private var shownGeneration: UInt64 = 0
    @ObservationIgnored private(set) var isRetired = false
    @ObservationIgnored private var bake: Task<Void, Never>?
    @ObservationIgnored private var dirty = false
    /// Baked frames published, for tests and diagnostics.
    @ObservationIgnored private(set) var publishedBakes = 0
    /// Test seam: awaited inside a bake after its inputs are captured, before rendering.
    @ObservationIgnored var bakeGate: (@MainActor () async -> Void)?

    init(selection: LUTSelection, fileStore: CustomLUTStore) {
        lutSelection = selection
        renderer = LiveFrameRenderer(fileStore: fileStore)
    }

    /// A newly accepted frame from this member's own link.
    func accept(_ frame: UIImage?) {
        guard !isRetired, let frame else { return }
        raw = frame
        sourceGeneration &+= 1
        present()
    }

    func setLUT(enabled: Bool) {
        guard !isRetired, enabled != lutEnabled else { return }
        lutEnabled = enabled
        lookRevision &+= 1
        present()
    }

    func setLUT(selection: LUTSelection) {
        guard !isRetired, selection != lutSelection else { return }
        lutSelection = selection
        lookRevision &+= 1
        present()
    }

    /// The member's link was replaced, failed or stopped: its old pixels and any late bake are
    /// discarded. The operator's look choice stays with the member.
    func reset() {
        epoch &+= 1
        raw = nil
        image = nil
        shownGeneration = 0
    }

    /// The member left the stage. Nothing published afterwards.
    func retire() {
        reset()
        isRetired = true
        bake?.cancel()
        bake = nil
    }

    private func present() {
        guard let raw else { return }
        guard lutEnabled else {
            // Off is the camera's own picture, at once; an in-flight bake no longer matches.
            image = raw
            shownGeneration = sourceGeneration
            return
        }
        dirty = true
        guard bake == nil else { return }
        bake = Task { [weak self] in
            await self?.runBakes()
        }
    }

    private func runBakes() async {
        defer { bake = nil }
        while dirty, !isRetired, lutEnabled, let source = raw {
            dirty = false
            let captured = (epoch: epoch, look: lookRevision, generation: sourceGeneration)
            let effects = LiveImageEffects(lut: lutSelection)
            if let bakeGate { await bakeGate() }
            let output = await renderer.renderStaticFrame(source, effects: effects)
            guard !Task.isCancelled, !isRetired else { return }
            if captured.epoch == epoch, captured.look == lookRevision, lutEnabled,
                captured.generation >= shownGeneration
            {
                image = output
                shownGeneration = captured.generation
                publishedBakes += 1
            }
        }
    }
}

/// One look the per-member panel offers: a generated built-in look or a stored cube from the
/// app's existing catalog.
struct MulticamLookOption: Identifiable, Equatable {
    let selection: LUTSelection
    let title: String
    var id: String { selection.cacheKey }

    @MainActor
    static func catalog(_ store: CustomLUTStore) -> [MulticamLookOption] {
        MonitorLUT.allCases.map { MulticamLookOption(selection: .builtIn($0), title: $0.rawValue) }
            + [LUTCategory.red, .custom].flatMap { category in
                store.list(category).map {
                    MulticamLookOption(
                        selection: .stored(category: category, fileName: $0.fileName),
                        title: $0.displayName)
                }
            }
    }
}

/// The LUT tool's options: that member's tabs, picture, own on/off and look, over the stage.
struct MulticamLookSettings: View {
    @Bindable var coordinator: MulticamCoordinator
    let member: MulticamMember
    let viewport: MultiviewStageViewport

    var body: some View {
        let picture = member.picture
        MonitorInspector(
            title: "LUT", viewport: viewport.size, safeArea: viewport.safeArea,
            hasNavigation: false, closeIdentifier: "multiview.lut.close",
            onClose: coordinator.closeLookSettings
        ) {
            EmptyView()
        } content: {
            VStack(spacing: 12) {
                MonitorCaptureTabs(
                    options: coordinator.members.filter {
                        coordinator.pictureLUTSlots.contains($0.slot)
                    }.map(\.slot),
                    selection: member.slot,
                    title: { coordinator.member(atSlot: $0)?.letter ?? "" },
                    identifier: { "multiview.lut.camera.\($0)" },
                    select: coordinator.openLookSettings)
                if let image = picture.image {
                    Image(uiImage: image).resizable().aspectRatio(contentMode: .fit)
                        .frame(maxHeight: 180).accessibilityIdentifier("multiview.lut.preview")
                }
                Toggle(
                    "LUT",
                    isOn: Binding(
                        get: { picture.lutEnabled },
                        set: { coordinator.setLUT(enabled: $0, on: member.id) })
                )
                .font(MonitorTheme.font(13, weight: .semibold))
                .accessibilityIdentifier("multiview.lut.enabled")
                ForEach(coordinator.lookOptions()) { option in
                    let chosen = option.selection == picture.lutSelection
                    Button {
                        coordinator.setLUT(selection: option.selection, on: member.id)
                    } label: {
                        HStack {
                            Text(option.title).font(MonitorTheme.font(13, weight: .medium))
                            Spacer()
                            if chosen { Image(systemName: "checkmark") }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("multiview.lut.option.\(option.id)")
                    .accessibilityAddTraits(chosen ? .isSelected : [])
                }
            }
        } footer: {
            EmptyView()
        }
        .accessibilityIdentifier("multiview.lut.panel")
    }
}

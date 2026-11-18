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

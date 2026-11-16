import Foundation
import MonitorPresentation
import MonitorUI
import OpenCineAppKit
import OpenCineAppKitApple
import OpenCineCore
import OpenCineMulticam
import OpenZCineCore
import SwiftUI
import UIKit

import class OpenCineCameraVocabulary.CustomLUTStore

/// What the Multiview stage needs from the app and the platform, injected so the tests run it on
/// scripted bodies and a manual clock.
struct ZCineMultiviewEnvironment {
    /// Opens a PTP session to a picked host (Init, OpenSession, GetDeviceInfo).
    var connect: @Sendable (String) async throws -> ZCineMemberTransport
    /// The device serving a host now, from a fresh presence sweep (never a control-port dial).
    var currentHolder: @Sendable (String) async -> String?
    /// One passive Add-list pass (`NikonDiscovery.multiviewSightings`).
    var sightings:
        @Sendable (_ savedHosts: [String], _ excludedHosts: Set<String>) async -> [DiscoveredCamera]
    /// The saved router and hotspot setups the Add list offers.
    var saved: @MainActor @Sendable () -> [NikonMultiviewSavedSetup]
    var hostPath: any StationHostPath
    var clock: HostClock = .live
    var isCameraRefusal: @Sendable (any Error) -> Bool
    var whiteBalancePresets: [String] = []
    /// The pause after each frame for a tile (the program tile, or one of the others).
    var framePace: @MainActor (_ isProgram: Bool) -> Duration = { _ in .milliseconds(41) }
    var lutFileStore = CustomLUTStore()
    /// Where the stage's layout, selection and Fit/Fill live (ZCine's existing key).
    var presentationStore: MultiviewStagePreferencesStore? = MultiviewStagePreferencesStore(
        storage: .standard, key: "multiview.presentation")
}

/// The stage, for the closures its links and scanner are built with before it exists.
private final class ZCineMultiviewReference: @unchecked Sendable {
    // SAFETY: set once on the main actor before any closure that reads it runs.
    weak var value: ZCineMultiview?
}

/// The app's half of the shared Multiview: one per opened stage. It builds the shared coordinator
/// over four Nikon member links (no commissioner: bodies are already on a router or this phone's
/// hotspot), keeps each tile's picture with its Auto LUT, the settings editor and the Live View
/// loan, and answers the shared screen (`MultiviewScreenHost`).
@MainActor
@Observable
final class ZCineMultiview {
    typealias Link = NikonMultiviewLink<ZCineMemberTransport>

    /// App qualification: four tiles (the engine-port's tested product limit).
    static let tileCount = 4

    let coordinator: MultiviewCoordinator<Link>
    @ObservationIgnored let links: [Link]
    /// Each tile's picture: the newest frame, baked through its Auto LUT while that is on.
    let pictures: [MulticamMemberPicture]
    /// The open settings editor and its tile.
    private(set) var editor: (slot: Int, editor: MulticamCameraEditor)?
    /// The tile lent to the single-camera Live View.
    private(set) var lentSlot: Int?
    /// The box the lent tile handed to Live View: the same session comes back as the same box.
    @ObservationIgnored private var lentTransport: ZCineMemberTransport?
    /// Each tile's camera model as GetDeviceInfo reported it on its current link (kept while it
    /// reconnects).
    private var models: [Int: String] = [:]
    /// The open editor's last command note (a refusal or error), as Pocket's popup shows it.
    private(set) var editorNote: String?
    @ObservationIgnored private var liveExit: (() -> Void)?
    @ObservationIgnored private let clock: HostClock

    /// The operator's record confirmation preference.
    @ObservationIgnored var recordConfirmation: @MainActor () -> Bool = { true }
    /// Lends `slot`'s session to the single-camera monitor; false when it could not open.
    @ObservationIgnored var lendToLiveView: @MainActor (Int, ZCineMemberTransport) -> Bool = {
        _, _ in false
    }
    /// Ends the single-camera monitor's loan.
    @ObservationIgnored var endLiveView: @MainActor () -> Void = {}
    /// The stage stopped: the app drops this Multiview.
    @ObservationIgnored var stopped: @MainActor () -> Void = {}
    /// The single-camera monitor view a lent tile shows in.
    @ObservationIgnored var liveViewContent: @MainActor () -> AnyView = { AnyView(EmptyView()) }
    @ObservationIgnored var logLine: @MainActor (String) -> Void = { _ in }

    init(environment: ZCineMultiviewEnvironment) {
        clock = environment.clock
        let opener = NikonMemberOpener<ZCineMemberTransport>(
            now: environment.clock.now, sleep: environment.clock.sleep,
            currentHolder: environment.currentHolder, connect: environment.connect,
            serialNumber: { $0.serialNumber }, close: { await $0.shutdown() })
        let pace = environment.framePace
        let owner = ZCineMultiviewReference()
        var slotLinks: [Link] = []
        for slot in 0..<Self.tileCount {
            slotLinks.append(
                Link(
                    opener: opener, conversion: Self.conversion,
                    whiteBalancePresets: environment.whiteBalancePresets,
                    isCameraRefusal: environment.isCameraRefusal, clock: environment.clock,
                    framePace: { pace(owner.value?.coordinator.presentation.selected == slot) }))
        }
        links = slotLinks
        pictures = (0..<Self.tileCount).map { _ in
            MulticamMemberPicture(
                selection: .builtIn(.nLogRec709), fileStore: environment.lutFileStore)
        }
        let scanner = NikonMultiviewScanner(
            sightings: environment.sightings, saved: environment.saved,
            excludedHosts: { owner.value?.memberHosts ?? [] })
        coordinator = MultiviewCoordinator(
            links: slotLinks, policy: NikonMultiview.policy, commissioner: nil, scanner: scanner,
            hostPath: environment.hostPath, describe: { $0.record },
            // A stage without a network name is not a journal the shared validation keeps, and
            // Nikon needs no cleanup record: the layout persists through `presentation` below.
            journal: MultiviewJournalStorage(load: { nil }, save: { _ in true }),
            networks: MultiviewNetworkStorage(password: { _, _ in nil }, save: { _ in }),
            budget: ResourceBudget(qualifiedEntries: Self.tileCount),
            sightingAddress: { $0.host }, networkPath: .either, clock: environment.clock)
        owner.value = self
        if let store = environment.presentationStore {
            coordinator.presentation.attachPersistence(load: store.load, save: store.save)
        }
        for slot in 0..<Self.tileCount {
            links[slot].onFrame = { [weak self] frame in self?.show(frame, slot: slot) }
        }
        coordinator.host = self
    }

    /// The look for a recording tone: N-Log and Log3G10 need theirs, SDR and HLG none.
    nonisolated static func look(_ tone: NikonMovieTone) -> MonitorLUT? {
        switch tone {
        case .nLog: .nLogRec709
        case .log3G10: .log3G10Rec709
        case .sdr, .hlg: nil
        }
    }

    nonisolated static let conversion: @Sendable (NikonMovieTone) -> String? = {
        look($0)?.rawValue
    }

    /// Hosts members hold: the Add list never dials or lists them.
    var memberHosts: Set<String> {
        Set(coordinator.members.filter { $0.camera != nil }.map(\.address).filter { !$0.isEmpty })
    }

    private func show(_ frame: PTPLiveViewFrame, slot: Int) {
        applyLUT(slot)
        pictures[slot].accept(UIImage(data: frame.jpeg))
        if let model = links[slot].transport?.model, !model.isEmpty, models[slot] != model {
            models[slot] = model
        }
    }

    /// The tile's Auto LUT: on while the member's choice is on and its tone needs a look.
    func applyLUT(_ slot: Int) {
        let picture = pictures[slot]
        let look = links[slot].recordingTone.flatMap(Self.look)
        if let look { picture.setLUT(selection: .builtIn(look)) }
        picture.setLUT(enabled: coordinator.members[slot].lutEnabled && look != nil)
    }

    // MARK: Live View

    /// The single-camera monitor stood down: the lent session (or the replacement its recovery
    /// opened, nil when lost) goes back to the tile, and the screen leaves Live View.
    func returnFromLiveView(_ transport: ZCineMemberTransport?) {
        guard let slot = lentSlot else { return }
        lentSlot = nil
        lentTransport = nil
        links[slot].reclaim(transport)
        let exit = liveExit
        liveExit = nil
        exit?()
    }

    /// The monitor stood down holding `session`: the lent session itself comes back in the box it
    /// left in (the tile's link takes it back as is), a recovery's replacement in a new one.
    func returnFromLiveView(session: (any NikonMultiviewTransport)?) {
        guard let session else { return returnFromLiveView(nil) }
        if let lent = lentTransport, lent.base === session { return returnFromLiveView(lent) }
        returnFromLiveView(ZCineMemberTransport(session))
    }

    // MARK: Settings editor

    private func retireEditor() {
        guard let open = editor else { return }
        editorNote = nil
        open.editor.retire()
        coordinator.editorLeases.close(coordinator.members[open.slot].entryID)
        editor = nil
    }

    /// The settings the popup offers for this body: the ones it can write (Nikon has no mode,
    /// color or audio control here).
    private func categories(_ slot: Int) -> [MultiviewSettingsCategory] {
        let capabilities = links[slot].snapshot.capabilities
        var result: [MultiviewSettingsCategory] = [.iso, .shutter, .exposure, .wb]
        if capabilities[.focusMode] != nil { result.append(.focus) }
        if capabilities[.aperture] != nil { result.append(.aperture) }
        result.append(.resolution)
        return result
    }

    /// The Add camera list's setup steps: Z bodies join the network from their own menus.
    /// Android twin: `PICKER_GUIDANCE`.
    static let pickerGuidance =
        "On each camera: Network menu \u{2192} Connect to computer, on this phone\u{2019}s Wi-Fi or Personal Hotspot. "
        + "A camera not yet paired with this phone: pair it in Your cameras first."

    /// Under the Format tab's values. Android twin: `FORMAT_NOTE`.
    static let formatNote = "Change the recording format on the camera."

    /// The common setting a category's drum edits.
    static func key(_ category: MultiviewSettingsCategory) -> SettingKey? {
        switch category {
        case .iso: .iso
        case .shutter: .shutter
        case .exposure: .exposureCompensation
        case .wb: .whiteBalance
        case .focus: .focusMode
        case .aperture: .aperture
        // Format: Nikon's common session writes no movie format; the tab reads it back.
        case .resolution, .mode, .color, .audio: nil
        }
    }
}

extension ZCineMultiview: MultiviewHost {
    var confirmsRecord: Bool { recordConfirmation() }

    func openLiveView(slot: Int) -> Bool {
        guard lentSlot == nil, let transport = links[slot].lend() else { return false }
        lentSlot = slot
        lentTransport = transport
        guard lendToLiveView(slot, transport) else {
            lentSlot = nil
            lentTransport = nil
            links[slot].reclaim(transport)
            return false
        }
        return true
    }

    func closeLiveView() {
        guard lentSlot != nil else { return }
        endLiveView()
    }

    func closeEditors() { retireEditor() }

    func memberChanged(slot: Int, _ change: MultiviewMemberChange) {
        if editor?.slot == slot { retireEditor() }
        if change != .control {
            pictures[slot].reset()
            models[slot] = nil
        }
    }

    func stageStopped() {
        retireEditor()
        for picture in pictures { picture.retire() }
        stopped()
    }

    func showsPicture(slot: Int) -> Bool { lentSlot != slot }

    func log(_ line: String) { logLine(line) }

    func readings(slot: Int) -> MultiviewTileReadings? {
        guard let name = coordinator.cameraName(slot: slot) else { return nil }
        let link = links[slot]
        let properties = link.reported
        let snapshot = link.snapshot
        let format = [properties.resolution, properties.fps.map { "\($0)p" }, properties.fileType]
            .compactMap { $0 }.joined(separator: " · ")
        let timecode = link.timecode.flatMap { code -> String? in
            guard code.on else { return nil }
            return MonitorTimecodeFormat.label(
                hours: code.hour, minutes: code.minute, seconds: code.second)
        }
        let hasPicture = pictures[slot].image != nil
        // The take length is the camera's own, as Pocket shows it: a Z body reports none, so the
        // tally reads REC (never a phone-derived count).
        return MultiviewTileReadings(
            name: name, model: models[slot] ?? "", format: format,
            storage: snapshot.storage.storageReadout?.free ?? MultiviewTally.unavailable,
            timecode: timecode, readouts: Self.readouts(properties), recordingSeconds: nil,
            power: snapshot.power, hasPicture: hasPicture,
            accessibilityValue: hasPicture ? "Live" : "Waiting")
    }

    /// ISO, shutter, white balance and focus as read back from the camera; unknown stays unknown.
    static func readouts(_ properties: PTPCameraPropertySnapshot) -> [MultiviewReadout] {
        let shutter =
            properties.shutterMode == .speed
            ? properties.shutterSpeed ?? properties.shutterAngle
            : properties.shutterAngle ?? properties.shutterSpeed
        return [
            MultiviewReadout(
                title: "ISO", value: properties.iso.map(String.init) ?? MultiviewTally.unavailable),
            MultiviewReadout(title: "SHUTTER", value: shutter ?? MultiviewTally.unavailable),
            MultiviewReadout(
                title: "WB",
                value: properties.wbKelvin.map { "\($0)K" } ?? properties.wbMode
                    ?? MultiviewTally.unavailable),
            MultiviewReadout(
                title: "FOCUS", value: properties.focusMode ?? MultiviewTally.unavailable),
        ]
    }

    var editsCameraSettings: Bool { true }
    var appliesAutoLUT: Bool { true }

    func lutChanged(slot: Int) { applyLUT(slot) }

    func openCameraSettings(slot: Int) {
        retireEditor()
        let link = links[slot]
        guard let control = link.control, let owner = link.transport?.commandOwner,
            let lease = coordinator.openEditorLease(slot: slot)
        else { return }
        let source: NikonCameraSession = control.session
        let opened = MulticamCameraEditor(
            member: coordinator.members[slot].entryID, lease: lease, source: source,
            owner: owner
        ) { [weak self, weak control] in
            guard let self, let control, self.links[slot].control === control else {
                return false
            }
            return self.coordinator.editorAdmits(lease, slot: slot)
        }
        // A refused or failed change says so in the popup, as Pocket's does.
        opened.control.onNote = { [weak self, weak opened] note in
            guard let self, let opened, self.editor?.editor === opened else { return }
            self.editorNote = note
        }
        editor = (slot, opened)
    }

    func cameraSettings(slot: Int) -> MultiviewCameraSettingsState? {
        guard let open = editor, open.slot == slot, links[slot].control != nil else { return nil }
        return MultiviewCameraSettingsState(
            categories: categories(slot), recording: links[slot].recordReport?.recording == true,
            note: editorNote)
    }

    func admitsControls(slot: Int) -> Bool {
        links[slot].transport != nil && !links[slot].lent && lentSlot != slot
    }

    var pickerGuidance: String? { Self.pickerGuidance }
}

extension ZCineMultiview: MultiviewScreenHost {
    @ViewBuilder func picture(slot: Int, fill: Bool) -> some View {
        if lentSlot != slot, let image = pictures[slot].image {
            Image(uiImage: image).resizable()
                .aspectRatio(contentMode: fill ? .fill : .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
        }
    }

    func backdrop(
        layout: MultiviewPresentationLayout, geometry: MultiviewStageGeometry, enabled: Bool
    ) -> some ViewModifier {
        EmptyModifier()
    }

    @ViewBuilder func settingsPreview(slot: Int) -> some View {
        if let image = pictures[slot].image {
            Image(uiImage: image).resizable().aspectRatio(contentMode: .fit)
                .frame(maxHeight: 180).accessibilityIdentifier("multiview.settings.preview")
        }
    }

    @ViewBuilder func settingsControls(
        slot: Int, category: MultiviewSettingsCategory, enabled: Bool,
        presented: @escaping () -> Bool, close: @escaping () -> Void
    ) -> some View {
        if editor?.slot == slot, category == .resolution {
            recordingFormat(slot)
        } else if let open = editor, open.slot == slot, let key = Self.key(category),
            let field = open.editor.control.captureField(key)
        {
            MonitorCaptureDrum(control: open.editor.control, field: field)
                .id(field.editor)
                .disabled(!enabled)
                .accessibilityIdentifier("multiview.settings.\(key.rawValue)")
        } else {
            Text("Not available on this camera").font(MonitorTheme.font(13, weight: .medium))
                .foregroundStyle(MonitorTheme.muted)
        }
    }

    /// The Format tab: the recording format as the body reports it (it changes on the camera).
    private func recordingFormat(_ slot: Int) -> some View {
        let properties = links[slot].reported
        let rows: [(String, String?)] = [
            ("Resolution", properties.resolution), ("Frame rate", properties.fps.map { "\($0)p" }),
            ("Codec", properties.fileType), ("Tone", links[slot].recordingTone?.label),
        ]
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(rows, id: \.0) { row in
                HStack {
                    Text(row.0).foregroundStyle(MonitorTheme.muted)
                    Spacer()
                    Text(row.1 ?? MultiviewTally.unavailable).foregroundStyle(MonitorTheme.text)
                }
                .font(MonitorTheme.font(13, weight: .medium))
            }
            Text(Self.formatNote).font(MonitorTheme.font(12)).foregroundStyle(MonitorTheme.muted)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("multiview.settings.format")
    }

    func liveView(slot: Int, exit: @escaping () -> Void) -> some View {
        liveExit = exit
        return liveViewContent()
    }

    var stationBrand: StationNetworkBrand {
        StationNetworkBrand(appName: "OpenZCine", cameraFamily: "Nikon", cameraNetworkPrefix: "")
    }

    var stationServices: StationNetworkServices {
        StationNetworkServices(
            savedNetworks: { [] }, currentSSID: { nil }, hotspotActive: { false },
            acceptsJoin: { _, _ in false })
    }
}

import Network
import SwiftUI
import UIKit
import ZIPFoundation
import os

private let connectionLogger = Logger(
    subsystem: "OpenZCine",
    category: "camera-connection"
)

private let proactiveWiFiJoinLogger = Logger(
    subsystem: "OpenZCine",
    category: "proactive-wifi-join"
)

private func logConnection(_ message: String) {
    #if DEBUG
        // Rich camera diagnostics are developer-only; Release logs retain only a stable hash.
        connectionLogger.error("\(message, privacy: .public)")
    #else
        connectionLogger.error("\(message, privacy: .private(mask: .hash))")
    #endif
}

enum ScreenWakeController {
    @MainActor
    static func apply(keepAwake: Bool) {
        guard UIApplication.shared.isIdleTimerDisabled != keepAwake else { return }
        UIApplication.shared.isIdleTimerDisabled = keepAwake
    }
}

extension ThermalTier {
    /// Maps the platform thermal state onto the portable core tier. An `@unknown` future state is
    /// treated as `.serious` — bias toward shedding load when the OS reports a heat category we don't
    /// recognise yet.
    init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .serious
        }
    }
}

/// Persists app-local operator preferences and assist-overlay configuration across sessions
/// (`UserDefaults`, both `Codable`). Only view-assist/chrome state lives here — never camera
/// exposure, resolution, format, or codec, which the connected camera always owns.
enum PreferencesStore {
    private static let preferencesKey = "operatorPreferences.v1"
    private static let assistConfigKey = "assistConfiguration.v1"

    static func loadPreferences() -> OperatorPreferences {
        guard let data = UserDefaults.standard.data(forKey: preferencesKey),
            var decoded = try? JSONDecoder().decode(OperatorPreferences.self, from: data)
        else { return .defaults }
        decoded.reconcileAssistTools()
        decoded.reconcileDispOrder()
        return decoded
    }

    static func save(_ preferences: OperatorPreferences) {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        UserDefaults.standard.set(data, forKey: preferencesKey)
    }

    static func loadAssistConfiguration() -> AssistConfiguration {
        guard let data = UserDefaults.standard.data(forKey: assistConfigKey),
            let decoded = try? JSONDecoder().decode(AssistConfiguration.self, from: data)
        else { return .defaults }
        return decoded
    }

    static func save(_ configuration: AssistConfiguration) {
        guard let data = try? JSONEncoder().encode(configuration) else { return }
        UserDefaults.standard.set(data, forKey: assistConfigKey)
    }

    static func loadCommandGridOrder() -> [CommandTileKind] {
        let stored: [CommandTileKind]? = UserDefaults.standard.data(forKey: commandGridOrderKey)
            .flatMap { try? JSONDecoder().decode([CommandTileKind].self, from: $0) }
        // Reconcile so tiles added/removed in a newer build are never lost or duplicated.
        return CommandGridOrder.reconciled(stored ?? CommandGridOrder.default)
    }

    static func save(_ commandGridOrder: [CommandTileKind]) {
        guard let data = try? JSONEncoder().encode(commandGridOrder) else { return }
        UserDefaults.standard.set(data, forKey: commandGridOrderKey)
    }

    private static let commandGridOrderKey = "commandGridOrder.v1"
    private static let mediaSortOrderKey = "mediaSortOrder.v1"
    private static let mediaThumbnailSizeKey = "mediaThumbnailSize.v1"
    private static let mediaBrowserLayoutKey = "mediaBrowserLayout.v1"

    static func loadMediaSortOrder() -> MediaSortOrder {
        guard let raw = UserDefaults.standard.string(forKey: mediaSortOrderKey),
            let order = MediaSortOrder(rawValue: raw)
        else { return .newest }
        return order
    }

    static func saveMediaSortOrder(_ order: MediaSortOrder) {
        UserDefaults.standard.set(order.rawValue, forKey: mediaSortOrderKey)
    }

    static func loadMediaThumbnailSize() -> MediaThumbnailSize {
        guard let raw = UserDefaults.standard.string(forKey: mediaThumbnailSizeKey),
            let size = MediaThumbnailSize(rawValue: raw)
        else { return .medium }
        return size
    }

    static func saveMediaThumbnailSize(_ size: MediaThumbnailSize) {
        UserDefaults.standard.set(size.rawValue, forKey: mediaThumbnailSizeKey)
    }

    static func loadMediaBrowserLayout() -> MediaBrowserLayout {
        guard let raw = UserDefaults.standard.string(forKey: mediaBrowserLayoutKey),
            let layout = MediaBrowserLayout(rawValue: raw)
        else { return .grid }
        return layout
    }

    static func saveMediaBrowserLayout(_ layout: MediaBrowserLayout) {
        UserDefaults.standard.set(layout.rawValue, forKey: mediaBrowserLayoutKey)
    }

    private static let movablePanelPositionsKey = "movablePanelPositions.v1"
    private static let proactiveWiFiJoinUserDeniedAtKey = "proactiveWiFiJoinUserDeniedAt.v1"

    /// When the operator last denied the system camera Wi‑Fi join sheet.
    static func loadProactiveWiFiJoinUserDeniedAt() -> Date? {
        let interval = UserDefaults.standard.double(forKey: proactiveWiFiJoinUserDeniedAtKey)
        guard interval > 0 else { return nil }
        return Date(timeIntervalSince1970: interval)
    }

    static func saveProactiveWiFiJoinUserDeniedAt(_ date: Date) {
        UserDefaults.standard.set(
            date.timeIntervalSince1970, forKey: proactiveWiFiJoinUserDeniedAtKey)
    }

    static func loadMovablePanelPositions() -> [String: MovablePanelStoredCenter] {
        guard let data = UserDefaults.standard.data(forKey: movablePanelPositionsKey),
            let decoded = try? JSONDecoder().decode(
                [String: MovablePanelStoredCenter].self, from: data)
        else { return [:] }
        return decoded
    }

    static func saveMovablePanelPositions(_ positions: [String: MovablePanelStoredCenter]) {
        guard let data = try? JSONEncoder().encode(positions) else { return }
        UserDefaults.standard.set(data, forKey: movablePanelPositionsKey)
    }
}

enum DemoFocusDragTarget: Equatable {
    case focus
    case eye
}

/// Normalized centre for a draggable view-assist panel, relative to the overlay viewport bounds.
struct MovablePanelStoredCenter: Codable, Equatable, Sendable {
    var xFraction: Double
    var yFraction: Double

    init(center: CGPoint, in bounds: CGRect) {
        let width = max(bounds.width, 1)
        let height = max(bounds.height, 1)
        xFraction = Double((center.x - bounds.minX) / width)
        yFraction = Double((center.y - bounds.minY) / height)
    }

    func center(in bounds: CGRect) -> CGPoint {
        CGPoint(
            x: bounds.minX + CGFloat(xFraction) * bounds.width,
            y: bounds.minY + CGFloat(yFraction) * bounds.height)
    }
}

/// Why a LUT import failed.
enum LUTImportError: LocalizedError {
    case unreadableArchive

    var errorDescription: String? {
        switch self {
        case .unreadableArchive: "The downloaded archive couldn't be read."
        }
    }
}

/// Why a stored LUT could not be removed from the app-owned library.
enum LUTDeletionError: LocalizedError, Equatable {
    case builtInProtected
    case invalidFileName
    case deletionFailed(String)

    var errorDescription: String? {
        switch self {
        case .builtInProtected: "Built-in LUTs cannot be deleted."
        case .invalidFileName: "That LUT has an invalid stored file name."
        case .deletionFailed(let displayName): "The LUT \(displayName) could not be deleted."
        }
    }
}

/// File-backed store for stored `.cube` LUTs under `<app documents>/luts/<category>` (custom
/// imports, downloaded RED presets). Storage is platform-owned (shell); the portable
/// indexing/parsing lives in OpenZCineCore.
struct LUTFileStore {
    /// Root of the per-category subdirectories, `<app documents>/luts`.
    let root: URL

    init(root: URL? = nil) {
        if let root {
            self.root = root
            return
        }
        let documents =
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        self.root = documents.appendingPathComponent("luts", isDirectory: true)
    }

    private func directory(for category: LUTCategory) -> URL {
        root.appendingPathComponent(category.rawValue.lowercased(), isDirectory: true)
    }

    /// The stored LUTs in `category`, sorted (empty until the directory exists).
    func list(_ category: LUTCategory) -> [StoredLUT] {
        let path = directory(for: category).path
        let names = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        return LUTLibraryIndex.stored(fromFileNames: names)
    }

    /// Copies an external `.cube` into `category`, replacing a same-named file.
    @discardableResult
    func importFile(from source: URL, into category: LUTCategory) throws -> StoredLUT {
        let directory = directory(for: category)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(source.lastPathComponent)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: source, to: destination)
        return StoredLUT(fileName: source.lastPathComponent)
    }

    /// Extracts every `.cube` from a zip's bytes into `category`, flattening nested folders to the
    /// file name and skipping non-`.cube` entries. Returns the stored list (sorted).
    @discardableResult
    func importZip(at zipURL: URL, into category: LUTCategory) throws -> [StoredLUT] {
        // Stream each entry straight to its destination file — never load the whole zip, or any
        // extracted file, into memory (a large RED pack would otherwise sit fully resident).
        let archive: Archive
        do {
            archive = try Archive(url: zipURL, accessMode: .read)
        } catch {
            throw LUTImportError.unreadableArchive
        }
        let directory = directory(for: category)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // A .cube LUT is tens of KB to a few MB; cap per-entry, total bytes, and file count so a
        // malformed or hostile archive (many entries / a zip bomb) can't fill the app container.
        let maxEntryBytes: UInt64 = 64 * 1024 * 1024
        let maxTotalBytes: UInt64 = 512 * 1024 * 1024
        let maxFiles = 512
        var extractedBytes: UInt64 = 0
        var extractedFiles = 0
        for entry in archive
        where entry.type == .file && entry.path.lowercased().hasSuffix(".cube") {
            let entryBytes = UInt64(entry.uncompressedSize)
            guard extractedFiles < maxFiles,
                entryBytes <= maxEntryBytes,
                entryBytes <= maxTotalBytes - extractedBytes
            else { continue }
            let fileName = (entry.path as NSString).lastPathComponent
            let destination = directory.appendingPathComponent(fileName)
            try? FileManager.default.removeItem(at: destination)
            _ = try archive.extract(entry, to: destination)
            extractedBytes += entryBytes
            extractedFiles += 1
        }
        return list(category)
    }

    /// Loads and parses a stored cube, or `nil` if it's missing or malformed.
    func cube(category: LUTCategory, fileName: String) -> CubeLUT? {
        let url = directory(for: category).appendingPathComponent(fileName)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return try? CubeLUT.parse(text)
    }

    /// Deletes one app-owned stored LUT. Built-ins have no file and are always protected.
    func remove(_ lut: StoredLUT, from category: LUTCategory) throws {
        guard category != .builtIn else { throw LUTDeletionError.builtInProtected }
        let directory = directory(for: category).standardizedFileURL
        let candidate = directory.appendingPathComponent(lut.fileName).standardizedFileURL
        guard lut.fileName == (lut.fileName as NSString).lastPathComponent,
            candidate.deletingLastPathComponent() == directory
        else { throw LUTDeletionError.invalidFileName }
        do {
            try FileManager.default.removeItem(at: candidate)
        } catch {
            throw LUTDeletionError.deletionFailed(lut.displayName)
        }
    }
}

enum ExternalInternetLinkReturnPolicy {
    /// Rejoin only after an active browser handoff actually backgrounded the app. Presentation
    /// transitions alone can produce active-state churn while the destination is still opening.
    static func shouldReconnect(handoffActive: Bool, sawBackground: Bool) -> Bool {
        handoffActive && sawBackground
    }
}

@MainActor
@Observable
final class NativeAppModel {
    enum ConnectionState: Equatable {
        case disconnected
        case scanning
        case pairing(pin: String)
        case reconnecting
        case preparingLiveView
        case connected

        var label: String {
            switch self {
            case .disconnected: "Disconnected"
            case .scanning: "Scanning"
            case .pairing: "Pairing"
            case .reconnecting: "Reconnecting"
            case .preparingLiveView: "Preparing"
            case .connected: "Connected"
            }
        }

        var diagnosticEvent: AppDiagnosticEvent {
            switch self {
            case .disconnected: .connectionDisconnected
            case .scanning: .connectionScanning
            case .pairing: .connectionPairing
            case .reconnecting: .connectionReconnecting
            case .preparingLiveView: .connectionPreparingLiveView
            case .connected: .connectionConnected
            }
        }
    }

    enum StartupMode: Equatable {
        case savedCameras
        case discovery
    }

    /// How the operator plans to reach the camera during first-time pairing.
    enum FirstPairTransportMethod: String, CaseIterable, Sendable, Identifiable {
        case cameraAccessPoint
        case phoneHotspot
        case usbC

        var id: String { rawValue }

        var title: String {
            switch self {
            case .cameraAccessPoint: "Camera's Access Point"
            case .phoneHotspot: "Phone's Hotspot"
            case .usbC: "USB-C"
            }
        }

        var detail: String {
            switch self {
            case .cameraAccessPoint:
                "The camera creates a Wi‑Fi network — join it from your iPhone."
            case .phoneHotspot:
                "Turn on Personal Hotspot — the camera joins your iPhone's network."
            case .usbC:
                "Plug the camera into this iPhone with a USB-C cable."
            }
        }

        var systemImage: String {
            switch self {
            case .cameraAccessPoint: "antenna.radiowaves.left.and.right"
            case .phoneHotspot: "personalhotspot"
            case .usbC: "cable.connector"
            }
        }
    }

    /// Guided steps shown only before the first successful camera pairing.
    enum FirstPairWizardStep: Int, CaseIterable, Sendable {
        case permissions = 0
        case chooseTransport = 1
        case prepareCamera = 2
        case connectNetwork = 3
        case discoverAndPair = 4

        var title: String {
            switch self {
            case .permissions: "Allow permissions"
            case .chooseTransport: "Choose how to connect"
            case .prepareCamera: "Prepare your camera"
            case .connectNetwork: "Set up the network"
            case .discoverAndPair: "Find and pair"
            }
        }

        var stepNumber: Int { rawValue + 1 }

        static var stepCount: Int { allCases.count }

        /// Total visible steps for the active transport and whether the permissions step is omitted.
        static func stepCount(
            transport: FirstPairTransportMethod,
            skipsPermissions: Bool
        ) -> Int {
            let base = transport == .cameraAccessPoint ? 4 : 5
            return skipsPermissions ? base - 1 : base
        }

        /// 1-based step index shown in the wizard chrome.
        func displayNumber(skipsPermissions: Bool) -> Int {
            if skipsPermissions {
                guard self != .permissions else { return 0 }
                return rawValue
            }
            return rawValue + 1
        }

        /// Whether this step is the last one for the chosen transport.
        func isFinalStep(for transport: FirstPairTransportMethod) -> Bool {
            switch transport {
            case .cameraAccessPoint:
                return self == .connectNetwork
            case .phoneHotspot, .usbC:
                return self == .discoverAndPair
            }
        }
    }

    /// When true the permissions step is omitted from the wizard and step numbering is adjusted.
    var firstPairWizardSkipsPermissions = false

    /// Password collected from the operator before joining a secured camera access point.
    struct CameraWiFiPasswordSubmission: Equatable, Sendable {
        let ssid: String?
        let password: String
    }

    var firstPairWizardStep: FirstPairWizardStep = .permissions
    var firstPairTransportMethod: FirstPairTransportMethod = .cameraAccessPoint

    /// Forces the first-pair wizard even when saved cameras already exist — set when the operator
    /// explicitly starts pairing a new camera. The wizard is the sole pairing surface.
    var isPairingNewCamera = false

    /// Which discovery backend the connect screen's Wi-Fi / USB-C segment shows. Seeded from the
    /// wizard's step-1 transport choice; switchable at any time on the discovery step.
    enum DiscoveryTransportFilter: String, CaseIterable, Sendable, Identifiable {
        case wiFi
        case usbC

        var id: String { rawValue }

        var title: String {
            switch self {
            case .wiFi: "Wi-Fi"
            case .usbC: "USB-C"
            }
        }
    }

    var discoveryTransportFilter: DiscoveryTransportFilter = .wiFi

    enum ActivePanel: Identifiable, Equatable {
        case picker(CameraPicker)
        case assist(MonitorAssistTool)
        case assistLibrary
        case media
        case settings

        var id: String {
            switch self {
            case .picker(let picker): "picker-\(picker.id)"
            case .assist(let tool): "assist-\(tool.id)"
            case .assistLibrary: "assist-library"
            case .media: "media"
            case .settings: "settings"
            }
        }

        /// Panels that drive their own slide-up/fade reveal (see `schedulePanelReveal`) suppress the
        /// shared insert/remove transition to avoid a double animation. The exposure picker and the
        /// assist options panels both opt in.
        var managesOwnAppearance: Bool {
            switch self {
            case .picker, .assist: return true
            default: return false
            }
        }

        /// Panels presented as a full-screen surface (Operator Setup, Media, Tool Library) rather
        /// than a floating popup: the monitor rails hide behind these so the panel reads
        /// edge-to-edge, while picker/assist popups keep the rails (and feed) visible.
        var coversFullScreen: Bool {
            switch self {
            case .settings, .media, .assistLibrary: return true
            case .picker, .assist: return false
            }
        }
    }

    var connection: ConnectionState = .disconnected {
        didSet {
            publishWatchState()
            guard oldValue != connection else { return }
            AppDiagnostics.shared.record(connection.diagnosticEvent)
        }
    }
    /// Phased lifecycle for the connection progress sheet.
    var connectionPhase: CameraConnectionPhase = .idle
    var isConnectionProgressPresented = false
    var connectionProgressDeviceName = ""
    var connectionProgressIsUSB = false
    /// Failure text pinned for the progress sheet when a failure is surfaced. The sheet must not
    /// read the live `connectionMessage` for this — the discovery loop overwrites that field on
    /// every iteration, which put stale copy ("Found 1 camera.") on the failed card.
    var connectionFailureDetail = ""
    @ObservationIgnored private var connectionProgressShowsFailure = false
    var cameraHost = "192.168.1.1"
    var connectionMessage = "Join your camera's Wi‑Fi network, then come back here to connect."
    var connectedIdentity: NativeCameraIdentity?
    var discoveredCameras: [DiscoveredCamera] = []
    var savedCameras: [PTPIPSavedCameraRecord] = []
    var startupMode: StartupMode = .savedCameras
    var isIPhoneHotspotBridgeActive = false
    var selectedDiscoveredCameraID: String?
    var pendingPairingChallenge: PTPIPPairingChallenge?
    var isDemoSession = false
    /// Demo UI mode (⌘D in a demo session): the feed becomes an interactive stage — drag the eye
    /// marker itself to place it, drag elsewhere to move the AF box, and press 8 to toggle the eye.
    /// Simulator-only tooling for self-serve marketing captures; never reachable outside a demo.
    var demoUIMode = false
    #if DEBUG
        /// Local marketing stills (sorted by filename); number keys switch the demo feed.
        @ObservationIgnored var demoFeedImagePaths: [String] = []
    #endif
    /// SSID of the Wi‑Fi network the phone is currently using, refreshed on link-screen appear.
    var connectedWiFiSSID: String?
    /// Draft Wi‑Fi password typed in the connect popup before a first-time join.
    var cameraWiFiJoinPasswordDraft = ""
    /// True once the draft key came from an on-screen scan (shown in the clear for verification).
    var cameraWiFiJoinKeyFromScan = false
    /// Whether the on-screen credential scanner is presented over the connect popup.
    var isCameraWiFiScannerPresented = false
    /// Join target staged while the connect popup awaits operator confirmation.
    private(set) var pendingCameraWiFiJoinTarget: CameraWiFiJoinPolicy.ProactiveJoinTarget?
    var isMonitorPresented = false {
        didSet {
            syncScreenWakePolicy()
            publishWatchState()
            if oldValue != isMonitorPresented {
                updateBluetoothShutter()
                AppDiagnostics.shared.record(
                    isMonitorPresented ? .monitorPresented : .monitorDismissed)
            }
        }
    }
    var isMediaPlaybackActive = false {
        didSet { syncScreenWakePolicy() }
    }
    /// True while the full-screen clip player owns the process-wide audio session, including when
    /// paused. The Bluetooth shutter must not reconfigure or deactivate that shared session.
    @ObservationIgnored private var mediaPlaybackOwnsAudioSession = false
    /// Full-screen Media browser opened from the connection menu (no live-view session required).
    var isStandaloneMediaLibraryPresented = false {
        didSet {
            if oldValue != isStandaloneMediaLibraryPresented { updateBluetoothShutter() }
        }
    }
    /// Full-screen RED LUT download, presented from the app root (not the LUT picker) so it
    /// survives the monitor collapsing when the internet hop tears the camera session down.
    var isRedDownloadPresented = false
    /// Operator Setup presented standalone from the startup home (no camera connection needed —
    /// e.g. signing in to Frame.io or clearing the media cache before a shoot).
    var isStandaloneSettingsPresented = false
    /// Root-owned presentation state for the report flow, so it survives a camera-AP internet hop.
    var isBugReportPresented = false
    /// True while the phone has left the camera's Wi‑Fi so the RED LUT download can reach the
    /// internet. Drives the download screen's "Switching networks…" state.
    private(set) var internetHopActive = false
    /// True only while a browser link is intentionally using an internet hop. On return to the
    /// foreground, the app rejoins the camera AP through the normal saved-profile pipeline.
    private(set) var externalInternetLinkHandoffActive = false
    /// Set only after an accepted external-browser handoff actually backgrounds OpenZCine. This
    /// prevents transient activation changes during presentation from prompting an immediate
    /// camera-AP rejoin over the page the person just opened.
    @ObservationIgnored private var externalInternetLinkSawBackground = false
    /// True while the root-owned anonymous/GitHub report flow is using the internet side of a
    /// camera-AP hop. Unlike a browser handoff, ordinary foreground transitions must not end this
    /// hop because screenshot picking can briefly move the app inactive while the form is open.
    private(set) var bugReportInternetHandoffActive = false
    /// The selected destination shown while iOS leaves the camera AP and settles on an
    /// internet-capable route. Root ownership keeps this visible after the monitor and Settings
    /// panel collapse with the camera session.
    private(set) var internetDestinationPreparationTitle: String?
    /// Share context to restore after an internet hop re-hosts the media browser (the monitor
    /// panel's view state dies with the monitor): the clips whose share sheet initiated the hop.
    /// The standalone browser consumes this on mount — reopening a single cached clip, or the
    /// share sheet for a multi-clip selection.
    var pendingHopShareResumeClips: [MediaClip]?
    /// Where to return after the hop: the camera's host + AP SSID captured before leaving.
    @ObservationIgnored private var internetHopReturn: (host: String, ssid: String)?
    var displayMode: DispMode = .live
    /// Operator interface lock (the top-left lock button). When on, the monitor's controls — pickers,
    /// assist tools, DISP, tap-to-focus — are inert so nothing changes by accident on set. Record and
    /// the lock itself stay live. Session-only; never persisted, so a relaunch is always unlocked.
    var interfaceLocked = false
    /// App-only lock on the live-view focus point (long-press the AF box). Stops a stray tap from
    /// moving it; the camera remains the source of truth, this just suppresses our ChangeAfArea
    /// sends. Session-only.
    var focusPointLocked = false
    var cameraState = CameraDisplayState.preview
    // Per-frame telemetry (timecode, FPS) is held separately from `cameraState` so updating it
    // never invalidates every view observing the heavy HUD struct — only the readouts re-render.
    var liveTimecode = CameraDisplayState.preview.timecode
    var liveFPS = CameraDisplayState.preview.liveFPS
    /// Top-bar signal indicator level (0–4 bars), derived from the continuously-scored
    /// `linkHealth` transport health with hysteresis (`LinkSignalBars`) so it reads steadily.
    /// USB-C sessions pin to full bars while linked — frame timing there isn't radio quality.
    var liveSignalBars = 0
    /// Host-device thermal pressure, mirrored from `ProcessInfo.thermalState`. Gates graceful
    /// cosmetic load-shedding of the feed + scope refresh cadence (see `ThermalTier`). A no-op until
    /// the device is genuinely hot (`.serious`+); it never touches the camera stream or networking.
    var thermalTier: ThermalTier = .nominal
    /// Apertures the connected camera enumerates for the mounted lens (authoritative; empty until
    /// the camera reports them, e.g. in the demo). The IRIS picker prefers these over the
    /// lens-descriptor-derived fallback ladder.
    var cameraApertures: [String] = []
    /// Recording modes the camera advertises (`MovScreenSize` descriptor) — the only values we'll
    /// write, so we never send an invalid combination the body rejects by closing the connection.
    var cameraScreenModes: [PTPCameraScreenSizeMode] = []
    /// Deduped mode labels for the resolution/frame-rate picker (in the camera's advertised order).
    /// On Nikon ZR with R3D NE / N-RAW, documented FX/DX image areas get `[FX]` / `[DX]` prefixes
    /// (shared policy with Android) so operators see the same RAW crop semantics as the body.
    var resolutionOptions: [String] {
        var seen = Set<String>()
        let codec = cameraPropertySnapshot.fileType
        return cameraScreenModes.map {
            screenSizePresentationLabel(for: $0, codec: codec)
        }.filter { seen.insert($0).inserted }
    }

    /// Whether the connected body is a Nikon ZR (enables ZR-only RAW crop presentation).
    private var isConnectedNikonZR: Bool {
        guard let identity = connectedIdentity else { return false }
        let manufacturer = identity.manufacturer.uppercased()
        let model = identity.model.uppercased()
        // Match the Android facade: manufacturer Nikon + model ZR / NIKON ZR only.
        return manufacturer.contains("NIKON")
            && (model == "ZR" || model == "NIKON ZR" || model.hasSuffix(" ZR"))
    }

    /// Operator-facing screen-size label, including ZR RAW FX/DX tags when applicable.
    private func screenSizePresentationLabel(
        for mode: PTPCameraScreenSizeMode,
        codec: String?
    ) -> String {
        NikonZRRawCropPresentation.label(
            for: mode,
            currentCodec: codec,
            isNikonZR: isConnectedNikonZR)
    }
    /// Codecs the camera advertises (`MovFileType` descriptor) — the only codec values we'll write.
    var cameraFileTypeModes: [PTPCameraFileTypeMode] = []
    /// Codec labels for the codec picker, in the camera's advertised order.
    var codecOptions: [String] { cameraFileTypeModes.map(\.label) }
    /// Camera-advertised option lists for the moded AF / shutter / WB-preset settings, keyed by PTP
    /// property. Read once per poll cycle; an absent or empty entry means the picker keeps its
    /// hardcoded fallback. Reading the real values lets the pickers track whatever the connected body
    /// supports, not just the ZR's defaults.
    var cameraControlOptions: [PTPPropertyCode: [String]] = [:]
    /// Whether the camera reports it's charging. No PTP power-source property is wired yet, so this
    /// stays false on hardware; the indicator's charging glyph is ready for when one is identified.
    var cameraBatteryCharging = false
    var liveFrameImage: UIImage?
    /// AF / face-detection boxes from the latest live-view frame's header, drawn over the feed.
    var liveViewFocus: PTPLiveViewFocusInfo?
    /// Camera-reported audio levels from the live-view header's sound indicator (bytes 824–827),
    /// mapped onto the meter's dBFS scale for the audio-levels panel. Silent until frames carry it.
    var liveAudioLevels: AudioMeterLevels = .silent
    /// Latest scope sample plus derived traffic-light readings — one publish per throttle tick.
    var scopeAssist: ScopeAssistBundle = .empty
    /// Convenience accessor for scope panels that only need bins / points.
    var scopeSamples: ScopeSamples { scopeAssist.samples }
    /// Operator-dragged centres for the movable scopes / false-colour reference, keyed by panel id
    /// (in the live-canvas coordinate space). Session cache; persisted copy lives in
    /// `movablePanelPositions`. Absent in both = the default corner.
    var movablePanelCenters: [String: CGPoint] = [:]
    /// Persisted normalised centres for movable assist panels, keyed by panel id.
    var movablePanelPositions: [String: MovablePanelStoredCenter] =
        PreferencesStore.loadMovablePanelPositions()
    {
        didSet { PreferencesStore.saveMovablePanelPositions(movablePanelPositions) }
    }
    /// Live frames of the currently-shown movable panels (same live-canvas space), so other floating
    /// chrome (the recenter button) can dodge them. Reported by each `MovablePanel`; absent = hidden.
    var movablePanelFrames: [String: CGRect] = [:]
    /// Capture settings the camera refuses to change (body "Control lock"; `MovieTVLockSetting`
    /// can report shutter locked independently). Set when the body rejects a write or the lock
    /// property reads engaged; cleared when a write succeeds or the poll reports unlocked. The bar
    /// shows a lock so the operator knows to change it on the camera (long-press for shutter).
    var lockedControls: Set<CameraPicker> = []
    var activePanel: ActivePanel? {
        didSet {
            // The Bluetooth shutter only listens while the live view is front — re-reconcile
            // when a full-screen panel opens or closes over it.
            if (oldValue?.coversFullScreen ?? false) != (activePanel?.coversFullScreen ?? false) {
                updateBluetoothShutter()
            }
        }
    }
    /// Operator Setup rail tab and per-tab scroll offsets — session-only; survive dismissing the
    /// panel back to live view without resetting to Link / top-of-page.
    var operatorSettingsTab: OperatorSettingsTab = .link
    var operatorSettingsScrollOffsets: [String: CGFloat] = [:]
    /// Global frame of the bottom capture-settings bar. The exposure picker right-aligns to this
    /// bar's right edge and rises just above it, mirroring the mockup's `.pk-card` placement.
    var captureBarFrame: CGRect = .zero
    /// Global frame of the view-assist toolbar (LUT, peaking, waveform, …). Assist quick-settings
    /// popups right-align to this bar's trailing edge and rise just above it on the left side.
    var assistToolbarFrame: CGRect = .zero
    /// Global frame of each capture-setting readout, keyed by its label, so a tap landing on a
    /// different setting while a picker is open can blend straight to that setting's picker.
    var captureSettingFrames: [String: CGRect] = [:]
    /// Global frame of each top-deck readout (resolution, codec), so its drop-down picker can anchor
    /// just beneath the cell and a backdrop tap on the cell can blend/dismiss like the bottom bar.
    var topBarPickerFrames: [CameraPicker: CGRect] = [:]
    /// Drives the exposure picker's slide-up reveal. Animated true on reveal; reset on dismiss.
    var panelRevealed = false
    /// Focus sub-settings the bar doesn't surface (it shows the AF mode). Tracked so the FOCUS
    /// picker's Area / Subject tabs each remember and apply their own value.
    var focusArea = "Single"
    var focusSubject = "Auto"
    /// When non-nil, the next picker present opens on this mode tab (e.g. FOCUS Area = 1).
    var pickerInitialMode: Int?
    var prefersMediaDuration = false
    var isRecording = false {
        didSet {
            guard oldValue != isRecording else { return }
            AppDiagnostics.shared.record(isRecording ? .recordingStarted : .recordingStopped)
        }
    }
    /// Current first-live-view guide card. Nil after completion or while the guide is not visible.
    var liveViewGuideStep: LiveViewGuideStep?
    @ObservationIgnored private var liveViewGuideStore: LiveViewGuideStore
    /// When non-nil, the operator must confirm before the queued start (`true`) or stop (`false`) runs.
    var pendingRecordConfirmation: Bool?
    /// When the app last sent a record start/stop, so the camera-authoritative record state (from the
    /// live-view header) doesn't fight the optimistic flip while the body catches up.
    @ObservationIgnored private var appRecordCommandAt: Date?
    /// Apple Watch companion relay. The phone owns the PTP session and forwards a downscaled feed +
    /// state snapshot to the watch, relaying a Record toggle back. Foreground-only; no-ops when no
    /// watch is paired/reachable.
    @ObservationIgnored let watchRelay = WatchRelay()
    @ObservationIgnored private var watchRelayActivated = false
    /// Bluetooth HID shutter remote → record toggle (volume-press mechanism, opt-in preference).
    @ObservationIgnored private let bluetoothShutter = BluetoothShutterMonitor()
    /// The camera's virtual-horizon roll/pitch (signed degrees) from the live-view header, driving the
    /// level overlay. Nil until the body reports a level — the overlay falls back to CoreMotion then.
    var cameraLevelRoll: Double?
    var cameraLevelPitch: Double?

    init(
        liveViewGuideStore: LiveViewGuideStore = LiveViewGuideStore(),
        lutFileStore: LUTFileStore = LUTFileStore()
    ) {
        self.liveViewGuideStore = liveViewGuideStore
        self.lutFileStore = lutFileStore
    }
    /// Operator preferences (which assist tools are on, their order, chrome visibility) persist
    /// across sessions — loaded on launch, saved on every change. Camera exposure/record settings
    /// are deliberately *not* persisted here; the connected camera is their source of truth.
    var preferences = PreferencesStore.loadPreferences() {
        didSet {
            PreferencesStore.save(preferences)
            syncScreenWakePolicy()
            if oldValue.bluetoothShutterEnabled != preferences.bluetoothShutterEnabled {
                updateBluetoothShutter()
            }
        }
    }
    /// Per-tool assist-overlay configuration (guides, grid, level, …), also persisted.
    var assistConfiguration = PreferencesStore.loadAssistConfiguration() {
        didSet { PreferencesStore.save(assistConfiguration) }
    }
    /// Operator-chosen order of the command-monitor primary grid tiles (drag to reorder), persisted.
    var commandGridOrder = PreferencesStore.loadCommandGridOrder() {
        didSet { PreferencesStore.save(commandGridOrder) }
    }
    /// File store for custom-imported LUTs, and the current list (refreshed when the picker opens).
    let lutFileStore: LUTFileStore
    var customLUTs: [StoredLUT] = []
    var redLUTs: [StoredLUT] = []
    /// On-disk cache + index for camera clips (Media page), and the current library list.
    let mediaClipStore = MediaClipStore()
    var mediaClips: [MediaClip] = []
    var mediaFetchInProgress = false
    /// Movie clips discovered so far during an in-flight `fetchClipsFromCamera` listing pass.
    var mediaFetchListedCount = 0
    /// Per-clip download progress (`clip.id` → 0…1) while a clip streams from the camera.
    var mediaDownloadProgress: [String: Double] = [:]
    @ObservationIgnored private var mediaDownloadInFlight: Set<String> = []
    /// Clips whose fetched thumbnail bytes failed to decode this session — skipped by
    /// `fetchThumbnail` so a body that serves garbage for a clip isn't re-queried every scroll.
    @ObservationIgnored private var thumblessClipIDs: Set<String> = []
    @ObservationIgnored private var mediaFetchTask: Task<Void, Never>?
    /// Bumped per listing pass so a cancelled pass finishing late can't clear a successor's state.
    @ObservationIgnored private var mediaFetchGeneration = 0
    @ObservationIgnored private var thumbnailFetchTask: Task<Void, Never>?
    /// Bumped on every worker start/cancel so a finishing stale worker can't clear the
    /// single-flight slot of a successor (see `startThumbnailWorkerIfNeeded`).
    @ObservationIgnored private var thumbnailWorkerGeneration = 0
    /// A camera listing pass interrupted by backgrounding — re-scheduled on foreground.
    @ObservationIgnored private var mediaFetchInterruptedByBackground = false
    @ObservationIgnored private var thumbnailQueue: [MediaClip] = []
    @ObservationIgnored private var thumbnailQueuedIDs: Set<String> = []
    @ObservationIgnored private var thumbnailWaiters: [String: [CheckedContinuation<Void, Never>]] =
        [:]
    /// Media browser chrome: source bucket, tabs, chip filters, and sort (sort persists).
    var mediaBrowserSource: MediaBrowserSource = .camera
    var mediaCategoryTab: MediaCategoryTab = .videos {
        didSet {
            // Re-run the delta pass so the newly selected category's still-unfetched clips jump
            // the queue (cached clips cost nothing; only new handles hit GetObjectInfo).
            guard oldValue != mediaCategoryTab, mediaBrowserSource == .camera,
                cameraSession != nil
            else { return }
            scheduleFetchClipsFromCamera()
        }
    }
    var mediaFormatFilters: Set<MediaFormatFilter> = []
    var mediaResolutionFilters: Set<MediaResolutionBucket> = []
    var mediaTodayOnly = false
    var mediaStorageSlotFilter: UInt32?
    var mediaSortOrder: MediaSortOrder = PreferencesStore.loadMediaSortOrder() {
        didSet { PreferencesStore.saveMediaSortOrder(mediaSortOrder) }
    }
    var mediaThumbnailSize: MediaThumbnailSize = PreferencesStore.loadMediaThumbnailSize() {
        didSet { PreferencesStore.saveMediaThumbnailSize(mediaThumbnailSize) }
    }
    var mediaBrowserLayout: MediaBrowserLayout = PreferencesStore.loadMediaBrowserLayout() {
        didSet { PreferencesStore.saveMediaBrowserLayout(mediaBrowserLayout) }
    }
    /// Per-slot card capacity from the last `refreshMediaStorageSlots` pass.
    var mediaStorageSlots: [MediaStorageSlotDisplay] = []
    /// Background task streaming the clip currently open in the player, if any.
    @ObservationIgnored private var clipStreamTask: Task<Void, Never>?
    @ObservationIgnored private var clipStreamClipID: String?
    /// Frame.io integration state (Media upload): the connected user (nil = not connected), an
    /// in-flight connect, and per-clip upload progress (`clip.id` → 0…1).
    var frameioUser: FrameioUser?
    var frameioConnecting = false
    var frameioUploadProgress: [String: Double] = [:]
    /// Clip ids with an upload task in flight — blocks duplicate taps before progress is set.
    @ObservationIgnored var frameioUploadInFlight: Set<String> = []
    /// Last Frame.io upload error message, surfaced as a transient toast; cleared after it's shown.
    var frameioUploadError: String?
    var linkHealth = 0
    var linkHealthDetail = "Not connected"

    var displayOrder: [DispMode] {
        preferences.enabledDispOrder
    }

    var isConnected: Bool {
        if case .connected = connection { return true }
        return false
    }

    var isStartupActionLocked: Bool {
        switch connection {
        case .pairing, .reconnecting, .preparingLiveView:
            return true
        case .disconnected, .scanning, .connected:
            return false
        }
    }

    var canEnterLiveView: Bool {
        StartupReadyLiveViewPolicy.canEnterMonitor(
            isConnected: isConnected,
            hasActiveSession: cameraSession != nil,
            isBusy: isStartupActionLocked
        )
    }

    var startupRecoveryPrompt: CameraStartupRecoveryPrompt {
        CameraStartupPolicy.recoveryPrompt(
            savedCameras: savedCameras,
            discoveredCameras: discoveredCameras,
            connectedHost: connectedIdentity?.host,
            isIPhoneHotspotBridgeActive: isIPhoneHotspotBridgeActive
        )
    }

    var pairingDiscoveryCandidates: [DiscoveredCamera] {
        let transportCandidates = discoveredCameras.filter {
            discoveryTransportFilter == .usbC ? $0.isUSB : !$0.isUSB
        }
        return CameraStartupPolicy.pairingDiscoveryCandidates(
            discoveredCameras: transportCandidates,
            savedCameras: savedCameras,
            // A wire-identity migration can leave the app record present while the camera-side
            // profile needs pairing again. In the explicit Pair new flow, surface that known
            // camera only when no genuinely new camera was found so the screen cannot look stuck.
            allowSavedCameraRecovery: isPairingNewCamera
        )
    }

    /// True when discovery found no Wi‑Fi cameras and the phone is not on a camera AP.
    var showsJoinCameraWiFiAction: Bool {
        guard showsManualJoinCameraWiFiAction else { return false }
        guard pairingDiscoveryCandidates.isEmpty else { return false }
        return true
    }

    /// True when the operator can manually trigger a camera Wi‑Fi join from the link screen.
    var showsManualJoinCameraWiFiAction: Bool {
        if discoveryTransportFilter == .usbC { return false }
        if shouldShowFirstPairWizard, firstPairTransportMethod == .usbC { return false }
        // The hotspot path has no phone-side camera-Wi-Fi join: the camera joins the iPhone's
        // Personal Hotspot, so there is no camera SSID to scan or join — the scanner and join
        // button are camera-AP mechanisms only and would dead-end the operator here.
        if shouldShowFirstPairWizard, firstPairTransportMethod == .phoneHotspot { return false }
        return !CameraWiFiJoinPolicy.isOnCameraAccessPoint(
            localAddresses: NativeNetworkInterfaceSnapshot.localIPv4Addresses(),
            connectedSSID: connectedWiFiSSID
        )
    }

    var joinCameraWiFiButtonTitle: String {
        "Connect to camera Wi‑Fi"
    }

    /// Camera Wi‑Fi join from the link/discovery screen: opens the credential scanner immediately.
    /// A saved camera whose SSID is known reconnects directly; otherwise the operator scans the
    /// camera's Connection wizard screen (SSID + key) and the scanned result stages the join —
    /// there is no intermediate "join this network?" confirmation step in between.
    func joinCameraWiFiFromDiscovery() {
        if let camera = preferredJoinCameraWiFiSavedCamera() {
            connectSavedCamera(camera)
            return
        }
        guard canAttemptCameraWiFiJoin() else { return }
        presentCameraWiFiScanner()
    }

    /// Joins the staged camera network after the operator taps Connect in the popup.
    func confirmCameraWiFiJoin() {
        guard let target = pendingCameraWiFiJoinTarget else { return }
        pendingCameraWiFiJoinTarget = nil
        cameraWiFiJoinTask?.cancel()
        cameraWiFiJoinTask = Task { [weak self] in
            await self?.runCameraWiFiJoin(
                target: target,
                joinStrategy: .hotspotConfigurationOnly
            )
        }
    }

    /// True when no password is stored for the staged join target (first-time connect).
    var cameraWiFiJoinNeedsPassword: Bool {
        guard let target = pendingCameraWiFiJoinTarget else { return false }
        return CameraWiFiCredentialStore.password(
            forSSID: targetSSID(for: target),
            prefix: targetPrefix(for: target)
        ) == nil
    }

    /// Opens the on-screen credential scanner over the connect popup.
    func presentCameraWiFiScanner() {
        isCameraWiFiScannerPresented = true
    }

    /// Applies credentials scanned from the camera's Connection wizard: stages an exact-SSID join
    /// and pre-fills the key, so the popup's Connect button runs the normal join pipeline.
    func applyScannedCameraWiFi(ssid: String, key: String) {
        isCameraWiFiScannerPresented = false
        pendingCameraWiFiJoinTarget = .specificSSID(ssid)
        cameraWiFiJoinPasswordDraft = key
        cameraWiFiJoinKeyFromScan = true
        connectionProgressDeviceName = ssid
        connectionProgressIsUSB = false
        connectionProgressShowsFailure = false
        connectionFailureDetail = ""
        connectionPhase = .readyToJoin
        isConnectionProgressPresented = true
        connectionMessage = ConnectionProgressCopy.statusDetail(
            phase: .readyToJoin,
            deviceName: ssid,
            friendlyError: nil
        )
    }

    private func cameraWiFiJoinDeviceName() -> String {
        guard let savedCamera = preferredJoinCameraWiFiSavedCamera() else { return "Nikon camera" }
        return ConnectionProgressCopy.resolveDisplayName(
            rawName: savedCamera.displayName,
            savedCamera: savedCamera
        )
    }

    /// Whether this app has paired the selected discovery camera before. Drives only the button
    /// label (Connect vs Pair); the connection flow probes the camera regardless of this value.
    var selectedPairingCameraIsKnown: Bool {
        guard let camera = selectedPairingDiscoveryCamera,
            let host = PTPIPPairedHosts.normalizedHost(camera.ip)
        else { return false }
        return NativeCameraConnectionStore.shared.knownPairedCameras()
            .contains { $0.host == host }
    }

    var selectedDiscoveredCamera: DiscoveredCamera? {
        if let selectedDiscoveredCameraID,
            let selected = discoveredCameras.first(where: { $0.id == selectedDiscoveredCameraID })
        {
            return selected
        }
        return discoveredCameras.first
    }

    var selectedPairingDiscoveryCamera: DiscoveredCamera? {
        let candidates = pairingDiscoveryCandidates
        if let selectedDiscoveredCameraID,
            let selected = candidates.first(where: { $0.id == selectedDiscoveredCameraID })
        {
            return selected
        }
        return candidates.first
    }

    /// True while the first-pair wizard should own the screen: whenever the operator is explicitly
    /// pairing a new camera, or there are no saved cameras yet (first run, or all cameras removed).
    /// The wizard is the sole pairing surface, so this also covers what the old standalone discovery
    /// page used to handle.
    var shouldShowFirstPairWizard: Bool {
        isPairingNewCamera || savedCameras.isEmpty
    }

    /// Plain-language version of `connectionMessage` for startup screens.
    var userFacingConnectionMessage: String {
        StartupConnectionCopy.friendly(connectionMessage)
    }

    /// Active sheet phase derived from connection flags and explicit phase updates.
    var resolvedConnectionPhase: CameraConnectionPhase {
        ConnectionProgressCopy.resolvePhase(
            isProgressPresented: isConnectionProgressPresented,
            explicitPhase: connectionPhase,
            isEstablishingConnection: isEstablishingConnection,
            isPairing: {
                if case .pairing = connection { return true }
                return connectionPhase == .pairing
            }(),
            isPreparingLiveView: connection == .preparingLiveView,
            isConnected: connection == .connected,
            showsFailure: connectionProgressShowsFailure
        )
    }

    func prepareStartup() {
        guard !didPrepareStartup else { return }
        didPrepareStartup = true
        startPhoneBatteryMonitoring()
        refreshSavedCameras()
        applyStartupDestination()
        if shouldShowFirstPairWizard, firstPairWizardStep == .permissions {
            configureFirstPairWizardEntry()
        }
        Task { await refreshConnectedWiFiSSID() }
        if shouldShowFirstPairWizard, firstPairWizardStep != .discoverAndPair {
            return
        }
        startDiscoveryLoop(resetResults: savedCameras.isEmpty)
    }

    /// Refreshes the cached connected Wi‑Fi SSID used for join-policy checks.
    func refreshConnectedWiFiSSID() async {
        connectedWiFiSSID = await NativeNetworkInterfaceSnapshot.currentWiFiSSID()
    }

    private func canAttemptCameraWiFiJoin() -> Bool {
        guard !isConnected, !isDemoSession else { return false }
        guard !isEstablishingConnection else { return false }
        guard !isConnectionProgressPresented else { return false }
        guard !isMonitorPresented else { return false }
        guard discoveryTransportFilter != .usbC else { return false }
        if shouldShowFirstPairWizard, firstPairTransportMethod == .usbC {
            return false
        }
        return true
    }

    private func persistCameraWiFiPassword(
        _ password: String,
        ssid: String?,
        prefix: String?
    ) {
        if let ssid, !ssid.isEmpty {
            CameraWiFiCredentialStore.savePassword(password, forSSID: ssid)
        }
        if let prefix, !prefix.isEmpty {
            CameraWiFiCredentialStore.savePassword(password, forPrefix: prefix)
        }
    }

    private func mirrorCameraWiFiPasswordToConnectedSSID(_ password: String) async {
        let connectedSSID = await NativeNetworkInterfaceSnapshot.currentWiFiSSID()
        guard let connectedSSID, !connectedSSID.isEmpty else { return }
        CameraWiFiCredentialStore.savePassword(password, forSSID: connectedSSID)
        connectedWiFiSSID = connectedSSID
    }

    private func resolveCameraWiFiCredentials(
        ssid: String?,
        ssidPrefix: String?
    ) -> CameraWiFiPasswordSubmission {
        if let stored = CameraWiFiCredentialStore.password(forSSID: ssid, prefix: ssidPrefix) {
            return CameraWiFiPasswordSubmission(ssid: ssid, password: stored)
        }

        let draftPassword = cameraWiFiJoinPasswordDraft.trimmingCharacters(
            in: .whitespacesAndNewlines)
        if !draftPassword.isEmpty {
            persistCameraWiFiPassword(draftPassword, ssid: ssid, prefix: ssidPrefix)
            cameraWiFiJoinPasswordDraft = ""
            cameraWiFiJoinKeyFromScan = false
            return CameraWiFiPasswordSubmission(ssid: ssid, password: draftPassword)
        }

        // No stored or typed password: attempt an open join; a secured AP fails with a
        // friendly error and the retry re-prompts.
        return CameraWiFiPasswordSubmission(ssid: ssid, password: "")
    }

    private func joinCameraNetwork(
        target: CameraWiFiJoinPolicy.ProactiveJoinTarget,
        credentials: CameraWiFiPasswordSubmission,
        joinStrategy: WiFiJoinCoordinator.JoinStrategy
    ) async throws {
        switch target {
        case .specificSSID(let ssid):
            try await WiFiJoinCoordinator.shared.joinCameraNetwork(
                ssid: ssid,
                password: credentials.password,
                strategy: joinStrategy
            )
        case .ssidPrefix(let prefix):
            if let resolvedSSID = credentials.ssid, !resolvedSSID.isEmpty {
                try await WiFiJoinCoordinator.shared.joinCameraNetwork(
                    ssid: resolvedSSID,
                    password: credentials.password,
                    strategy: joinStrategy
                )
            } else {
                try await WiFiJoinCoordinator.shared.joinCameraNetwork(
                    ssidPrefix: prefix,
                    password: credentials.password,
                    strategy: joinStrategy
                )
            }
        }
        await mirrorCameraWiFiPasswordToConnectedSSID(credentials.password)
    }

    private func surfaceCameraWiFiJoinFailure(_ message: String) {
        connectionProgressShowsFailure = true
        connectionPhase = .failed
        connectionMessage = message
        connectionFailureDetail = message
        proactiveWiFiJoinLogger.error(
            "join failed: \(message, privacy: .private(mask: .hash))"
        )
    }

    private func presentCameraWiFiJoinProgress(deviceName: String) {
        connectionProgressDeviceName = deviceName
        connectionProgressIsUSB = false
        connectionProgressShowsFailure = false
        connectionFailureDetail = ""
        connectionPhase = .joiningWiFi
        isConnectionProgressPresented = true
        connectionMessage = ConnectionProgressCopy.statusDetail(
            phase: .joiningWiFi,
            deviceName: deviceName,
            friendlyError: nil
        )
    }

    private func runCameraWiFiJoin(
        target: CameraWiFiJoinPolicy.ProactiveJoinTarget,
        joinStrategy: WiFiJoinCoordinator.JoinStrategy,
        reconnectHost: String? = nil
    ) async {
        guard !Task.isCancelled else { return }

        // Keep the popup's device-name title if it's already up from the search step.
        let deviceName =
            isConnectionProgressPresented && !connectionProgressDeviceName.isEmpty
            ? connectionProgressDeviceName
            : cameraWiFiJoinDeviceName()
        presentCameraWiFiJoinProgress(deviceName: deviceName)

        proactiveWiFiJoinLogger.info(
            "run strategy=\(String(describing: joinStrategy), privacy: .private(mask: .hash))"
        )

        do {
            let credentials = resolveCameraWiFiCredentials(
                ssid: targetSSID(for: target),
                ssidPrefix: targetPrefix(for: target)
            )
            // First-attempt association flakes are routine right after the camera raises its AP
            // (seen on-device). Retry transparently — the card stays on "Connecting…" — but an
            // explicit "Don't Join" on the iOS alert never loops.
            var joinError: Error?
            for attempt in 1...3 {
                do {
                    if attempt > 1 { try? await Task.sleep(for: .seconds(2)) }
                    guard !Task.isCancelled else { throw CancellationError() }
                    try await joinCameraNetwork(
                        target: target,
                        credentials: credentials,
                        joinStrategy: joinStrategy
                    )
                    joinError = nil
                    break
                } catch let error as WiFiJoinCoordinator.JoinError {
                    if case .userDenied = error { throw error }
                    joinError = error
                    proactiveWiFiJoinLogger.info(
                        "join attempt \(attempt, privacy: .public) failed: \(error.localizedDescription, privacy: .private(mask: .hash))"
                    )
                }
            }
            if let joinError { throw joinError }

            guard !Task.isCancelled else {
                dismissConnectionProgress()
                return
            }

            // Post-hop rejoin: we captured the camera's fixed AP address before leaving, so
            // connect straight to it the way `connectSavedCamera` does — no discovery. After an
            // internet hop the ZR (a) isn't guaranteed to re-advertise Bonjour in the window, so a
            // discovery-only find returns "Joined but couldn't find the camera," AND (b) holds the
            // pre-drop PTP session and lets the first Init(s) time out (~10s each), so a single
            // direct attempt lands on "couldn't connect." A known host fixes (a); retrying the
            // direct connect until an Init lands fixes (b). connectToCamera single-flights, so
            // attempts never stack; the card's Cancel cancels this task.
            if let reconnectHost = reconnectHost?.trimmingCharacters(in: .whitespacesAndNewlines),
                !reconnectHost.isEmpty
            {
                cameraHost = reconnectHost
                let maxAttempts = 6
                for attempt in 1...maxAttempts {
                    // `isConnectionProgressPresented` goes false when the operator taps Cancel/Close
                    // on the card — stop retrying then, even though the .handshaking phase isn't one
                    // `dismissConnectionProgress` cancels this task from.
                    guard !Task.isCancelled, isConnectionProgressPresented else { return }
                    connectToCamera()
                    // Wait for the single-flighted attempt to resolve (success or ~10s Init timeout).
                    while isEstablishingConnection {
                        try? await Task.sleep(for: .milliseconds(200))
                        guard !Task.isCancelled else { return }
                    }
                    if isConnected { return }
                    guard attempt < maxAttempts, isConnectionProgressPresented else { break }
                    // Hold the card in a reconnecting state (not the flashed failure) and give the
                    // ZR a moment to release the stale session before the next Init.
                    connectionProgressShowsFailure = false
                    connectionPhase = .discovering
                    connectionMessage = "Reconnecting to \(deviceName)…"
                    try? await Task.sleep(for: .seconds(2))
                }
                // Exhausted — the last connectToCamera left its failure card up.
                return
            }

            connectionPhase = .discovering
            connectionMessage = "Looking for cameras on your network…"
            // Fresh browse: we just switched networks, so results from the previous one are
            // stale and would auto-pair against an unreachable host.
            restartDiscoveryLoop(resetResults: true)
            // Keep the popup up until the camera answers discovery. Real hardware needs a while
            // after association (DHCP + mDNS settling + the body's PTP service coming up), and one
            // discovery pass can run well past 10s — allow 45s, with the card's Cancel to escape.
            for _ in 0..<180 {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                if !pairingDiscoveryCandidates.isEmpty || isEstablishingConnection { break }
            }
            guard !Task.isCancelled, !isEstablishingConnection else { return }
            if let camera = pairingDiscoveryCandidates.first {
                // The operator already confirmed this join — chain straight into pairing
                // instead of dropping them back on the wizard to tap the camera they chose.
                connectToCamera(camera)
            } else {
                surfaceCameraWiFiJoinFailure(
                    "Joined \(deviceName) but couldn't find the camera on its network. Keep the camera on its connection screen and try again."
                )
            }
        } catch is CancellationError {
            dismissConnectionProgress()
        } catch let error as WiFiJoinCoordinator.JoinError {
            guard !Task.isCancelled else {
                dismissConnectionProgress()
                return
            }
            let message = Self.friendlyCameraWiFiJoinMessage(for: error)
            switch error {
            case .userDenied:
                PreferencesStore.saveProactiveWiFiJoinUserDeniedAt(Date())
                if !isConnectionProgressPresented {
                    presentCameraWiFiJoinProgress(deviceName: deviceName)
                }
                surfaceCameraWiFiJoinFailure(message)
            case .invalidSSID, .timedOut, .system:
                if case .system = error {
                    // A stored wrong password would fail every retry with no way to re-enter
                    // it; drop it so the next attempt re-prompts.
                    // ponytail: also drops a valid password on other association failures.
                    clearStoredCameraWiFiPassword(for: target)
                }
                if !isConnectionProgressPresented {
                    presentCameraWiFiJoinProgress(deviceName: deviceName)
                }
                surfaceCameraWiFiJoinFailure(message)
            }
        } catch {
            guard !Task.isCancelled else {
                dismissConnectionProgress()
                return
            }
            if !isConnectionProgressPresented {
                presentCameraWiFiJoinProgress(deviceName: deviceName)
            }
            surfaceCameraWiFiJoinFailure(
                Self.friendlyCameraWiFiJoinMessage(for: error)
            )
        }
    }

    private func targetSSID(for target: CameraWiFiJoinPolicy.ProactiveJoinTarget) -> String? {
        switch target {
        case .specificSSID(let ssid):
            return ssid
        case .ssidPrefix:
            return nil
        }
    }

    private func targetPrefix(for target: CameraWiFiJoinPolicy.ProactiveJoinTarget) -> String? {
        switch target {
        case .specificSSID:
            return nil
        case .ssidPrefix(let prefix):
            return prefix
        }
    }

    private func clearStoredCameraWiFiPassword(
        for target: CameraWiFiJoinPolicy.ProactiveJoinTarget
    ) {
        switch target {
        case .specificSSID(let ssid):
            CameraWiFiCredentialStore.deletePassword(forSSID: ssid)
        case .ssidPrefix(let prefix):
            CameraWiFiCredentialStore.deletePassword(forPrefix: prefix)
        }
    }

    private static func friendlyCameraWiFiJoinMessage(for error: Error) -> String {
        if let joinError = error as? WiFiJoinCoordinator.JoinError {
            return joinError.localizedDescription
        }
        if error is CancellationError { return "" }
        let lower = error.localizedDescription.lowercased()
        if lower.contains("unable to join") || lower.contains("could not find") {
            return
                "Couldn't reach the camera Wi‑Fi network. Make sure the camera is on and nearby, then try again."
        }
        return error.localizedDescription
    }

    func advanceFirstPairWizard() {
        guard shouldShowFirstPairWizard else { return }
        switch firstPairWizardStep {
        case .permissions:
            firstPairWizardStep = .chooseTransport
        case .chooseTransport:
            firstPairWizardStep = .prepareCamera
        case .prepareCamera:
            firstPairWizardStep = .connectNetwork
        case .connectNetwork:
            if firstPairTransportMethod == .cameraAccessPoint {
                presentCameraWiFiScanner()
            } else {
                enterFirstPairDiscoveryStep()
            }
        case .discoverAndPair:
            break
        }
    }

    func retreatFirstPairWizard() {
        guard shouldShowFirstPairWizard else { return }
        switch firstPairWizardStep {
        case .permissions:
            break
        case .chooseTransport:
            if firstPairWizardSkipsPermissions {
                break
            } else {
                firstPairWizardStep = .permissions
            }
        case .prepareCamera:
            firstPairWizardStep = .chooseTransport
        case .connectNetwork:
            firstPairWizardStep = .prepareCamera
        case .discoverAndPair:
            stopDiscoveryLoop()
            firstPairWizardStep = .connectNetwork
        }
    }

    /// Whether the wizard shows a Back control on the current step.
    func firstPairWizardCanRetreat(from step: FirstPairWizardStep) -> Bool {
        switch step {
        case .permissions:
            return false
        case .chooseTransport:
            return !firstPairWizardSkipsPermissions
        default:
            return true
        }
    }

    /// Total visible steps for the active wizard session.
    func firstPairWizardStepCount() -> Int {
        FirstPairWizardStep.stepCount(
            transport: firstPairTransportMethod,
            skipsPermissions: firstPairWizardSkipsPermissions
        )
    }

    /// 1-based step index for wizard progress chrome.
    func firstPairWizardDisplayStepNumber(for step: FirstPairWizardStep) -> Int {
        step.displayNumber(skipsPermissions: firstPairWizardSkipsPermissions)
    }

    /// Seeds the wizard at permissions or the first post-permissions step.
    private func configureFirstPairWizardEntry() {
        let skipPermissions = StartupPermissionsCoordinator.permissionsAlreadySatisfied(
            alreadyPairedCameras: !savedCameras.isEmpty
        )
        firstPairWizardSkipsPermissions = skipPermissions
        firstPairWizardStep = skipPermissions ? .chooseTransport : .permissions
    }

    /// Skips informational wizard steps and opens camera discovery.
    func skipToFirstPairDiscovery() {
        guard shouldShowFirstPairWizard else { return }
        enterFirstPairDiscoveryStep()
    }

    private func enterFirstPairDiscoveryStep() {
        firstPairWizardStep = .discoverAndPair
        discoveryTransportFilter = firstPairTransportMethod == .usbC ? .usbC : .wiFi
        beginPairingDiscovery()
    }

    /// Clears the explicit "pair new camera" override once pairing completes, so the wizard yields
    /// back to the saved-camera home.
    private func markFirstPairWizardCompleted() {
        isPairingNewCamera = false
    }

    @ObservationIgnored private var batteryObservers: [NSObjectProtocol] = []

    /// Enables `UIDevice` battery monitoring, seeds the readout, and refreshes it on every actual
    /// battery change. Per-frame refresh keeps it current while streaming; the notification observers
    /// keep it current when the stream is paused (command mode) so it doesn't drift stale.
    private func startPhoneBatteryMonitoring() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        cameraState = cameraState.updating(phoneBatteryPercent: currentPhoneBatteryPercent)
        guard batteryObservers.isEmpty else { return }
        let center = NotificationCenter.default
        for name in [
            UIDevice.batteryLevelDidChangeNotification, UIDevice.batteryStateDidChangeNotification,
        ] {
            batteryObservers.append(
                center.addObserver(forName: name, object: nil, queue: nil) { _ in
                    Task { @MainActor [weak self] in self?.refreshPhoneBattery() }
                })
        }
    }

    private func refreshPhoneBattery() {
        cameraState = cameraState.updating(phoneBatteryPercent: currentPhoneBatteryPercent)
    }

    /// Current iPhone battery level as a 0–100 integer. `batteryLevel` is 0.0–1.0 or -1 when
    /// monitoring is disabled / on the simulator; -1 is reported as the existing value.
    private var currentPhoneBatteryPercent: Int {
        let raw = UIDevice.current.batteryLevel
        return raw >= 0 ? Int((raw * 100).rounded()) : cameraState.phoneBatteryPercent
    }

    /// Whether the iPhone is plugged in and charging. Read live from `UIDevice`; surfaced on the
    /// next chrome re-render (each live-view frame), so the charging glyph appears within a frame
    /// of plugging in.
    var phoneBatteryCharging: Bool {
        switch UIDevice.current.batteryState {
        case .charging, .full: true
        default: false
        }
    }

    /// Starts a fresh discovery loop for the wizard's discover step.
    func beginPairingDiscovery() {
        disconnectCameraSession(resetConnection: false)
        connection = .disconnected
        connectedIdentity = nil
        isDemoSession = false
        startupMode = .discovery
        restartDiscoveryLoop(resetResults: true)
    }

    /// Launches the guided first-pair wizard to add another camera. Entry point from the
    /// saved-camera home ("Pair new camera") — the wizard is the sole pairing surface now that the
    /// standalone discovery page is gone.
    func startFirstPairWizard() {
        disconnectCameraSession(resetConnection: false)
        connection = .disconnected
        connectedIdentity = nil
        isDemoSession = false
        stopDiscoveryLoop()
        configureFirstPairWizardEntry()
        firstPairTransportMethod = .cameraAccessPoint
        isPairingNewCamera = true
    }

    /// Returns to the saved-camera home, clearing any explicit pairing override.
    func showSavedCameras() {
        isPairingNewCamera = false
        refreshSavedCameras()
        applyStartupDestination()
        startDiscoveryLoop(resetResults: false)
    }

    func selectDiscoveredCamera(_ camera: DiscoveredCamera) {
        selectedDiscoveredCameraID = camera.id
        cameraHost = camera.ip
    }

    func connectSelectedCamera() {
        if let selectedPairingDiscoveryCamera {
            connectToCamera(selectedPairingDiscoveryCamera)
        } else {
            connectToCamera()
        }
    }

    func connectSavedCamera(_ camera: PTPIPSavedCameraRecord) {
        cameraHost = camera.host
        connectToCamera()
    }

    /// Dismisses the connection progress sheet without tearing down an active session.
    func dismissConnectionProgress() {
        if connectionPhase == .joiningWiFi || connectionPhase == .readyToJoin
            || connectionPhase == .discovering
            || pendingCameraWiFiJoinTarget != nil
        {
            cameraWiFiJoinTask?.cancel()
        }
        pendingCameraWiFiJoinTarget = nil
        cameraWiFiJoinPasswordDraft = ""
        cameraWiFiJoinKeyFromScan = false
        isCameraWiFiScannerPresented = false
        isConnectionProgressPresented = false
        connectionPhase = .idle
        connectionProgressShowsFailure = false
        connectionFailureDetail = ""
    }

    /// Cancels an in-flight connection attempt from the progress sheet.
    func cancelConnectionAttempt() {
        guard isConnectionProgressPresented else { return }
        // Cancel is the operator giving up — disarm the paired-reconnect watcher too, or the
        // background discovery loop keeps re-launching connects they just cancelled.
        pendingPairedReconnectHost = nil
        pendingPairedReconnectSSID = nil
        lastPairedRejoinAttemptAt = nil
        pairedReconnectSawCameraLeave = false
        let failedAttempt = connectionProgressShowsFailure
        dismissConnectionProgress()
        guard !failedAttempt else { return }
        disconnectCameraSession(resetConnection: true)
        startDiscoveryLoop(resetResults: false)
    }

    private func beginConnectionProgress(
        host: String,
        discoveredCamera: DiscoveredCamera?
    ) {
        let normalizedHost = PTPIPPairedHosts.normalizedHost(host) ?? host
        let savedCamera = savedCameras.first { $0.host == normalizedHost }
        let rawName =
            discoveredCamera?.displayName
            ?? savedCamera?.displayName
            ?? connectedIdentity?.displayName
            ?? "Nikon camera"
        connectionProgressDeviceName = ConnectionProgressCopy.resolveDisplayName(
            rawName: rawName,
            savedCamera: savedCamera
        )
        connectionProgressIsUSB =
            host.hasPrefix(DiscoveredCamera.usbHostKeyPrefix)
            || discoveredCamera?.isUSB == true
            || savedCamera?.isUSBTransport == true
        connectionProgressShowsFailure = false
        connectionFailureDetail = ""
        connectionPhase = .handshaking
        isConnectionProgressPresented = true
    }

    func showPairingHelp() {
        connectionMessage =
            "On the camera, open the network menu and turn on Connect to PC. When your camera appears below, tap it and follow the prompts on both screens."
    }

    /// True while a connection is being established — single-flights `connectToCamera` so overlapping
    /// Init attempts can't stack (see the guard inside).
    @ObservationIgnored private var isEstablishingConnection = false

    func connectToCamera(
        _ discoveredCamera: DiscoveredCamera? = nil,
        preservingMonitorSurface: Bool = false
    ) {
        if let discoveredCamera {
            cameraHost = discoveredCamera.ip
        }

        let host = cameraHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else {
            connectionMessage = NativeCameraSessionError.noHost.localizedDescription
            return
        }

        // Single-flight: a PTP-IP camera accepts one command channel per initiator, and overlapping
        // Init attempts (re-taps, an auto-reconnect racing a manual one) can wedge the camera's PTP
        // state machine — coalesce extra triggers instead of stacking attempts. The flag clears in
        // the establishment task's defer, so a failed attempt still frees the next retry.
        guard !isEstablishingConnection else { return }
        isEstablishingConnection = true
        // An auto-reconnect behind a preserved monitor keeps the operator on the frozen frame with
        // the RECOV badge — the full-screen connection progress is for operator-initiated connects.
        if !preservingMonitorSurface {
            beginConnectionProgress(
                host: host,
                discoveredCamera: discoveredCamera
            )
        }

        stopDiscoveryLoop()
        // Fully tear down any previous session BEFORE opening a new command channel: Init over a
        // still-open or half-closed prior command socket can wedge the camera's PTP state machine
        // hard enough to require a battery pull. Clear state synchronously, then await the socket
        // teardown before establishment begins.
        let previousSession = cameraSession
        clearCameraSessionState(
            resetConnection: false, preserveMonitorSurface: preservingMonitorSurface)
        // Captured after the clear (which bumps it): if a disconnect bumps the generation while
        // this attempt is in flight, the attempt must not publish its session — otherwise a slow
        // handshake completing after "Disconnect" silently resurrects the connection.
        let generation = connectionGeneration
        let hadPriorSession = previousSession != nil || sessionTeardownTask != nil
        establishmentTask = Task {
            defer { isEstablishingConnection = false }
            if let previousSession {
                await previousSession.stopLiveView()
                // Graceful CloseSession before dropping sockets — a bare close leaves the ZR
                // holding a stale session that wedges the reconnect (`NativeCameraSession.shutdown`).
                await previousSession.shutdown()
            }
            // Also await any teardown from an earlier disconnect: the camera accepts one command
            // channel per initiator, and Init over a half-closed prior channel can wedge it.
            await sessionTeardownTask?.value
            // Settle before opening a fresh Init on a RECONNECT: the ZR can briefly hold the PTP
            // slot after CloseSession/socket close, and a same-instant Init is what tips a fragile
            // reconnect into a wedge (the log's attempt→timeout→attempt dance). Only on reconnect —
            // a cold first connect has nothing to wait for. [verify-on-HW: tune this settle to the
            // camera's real slot-release time.]
            if hadPriorSession {
                try? await Task.sleep(for: .milliseconds(1200))
            }
            guard connectionGeneration == generation else { return }
            let store = NativeCameraConnectionStore.shared
            let savedCameras = store.savedCameras()
            let knownPairedCameras = store.knownPairedCameras()
            let savedCamera = savedCameras.first {
                $0.host == PTPIPPairedHosts.normalizedHost(host)
            }
            // Saved (trusted) camera → silent reconnect; unknown camera → the (auto-accepted)
            // pairing handshake. We never run the silent probe on an unknown network camera
            // because it is destructive to a camera sitting on its Wi-Fi pairing wizard; USB
            // cameras probe first (no wizard to disturb over the cable).
            let transportKind: CameraTransportKind =
                host.hasPrefix(DiscoveredCamera.usbHostKeyPrefix) ? .usb : .ptpIP
            do {
                try await performWiFiJoinIfNeeded(
                    transportKind: transportKind,
                    savedCamera: savedCamera,
                    discoveredCamera: discoveredCamera,
                    deviceName: connectionProgressDeviceName
                )
            } catch is CancellationError {
                guard connectionGeneration == generation else { return }
                dismissConnectionProgress()
                return
            } catch {
                guard connectionGeneration == generation else { return }
                connection = .disconnected
                connectionPhase = .failed
                connectionProgressShowsFailure = true
                connectionMessage =
                    Self.friendlyCameraWiFiJoinMessage(for: error)
                connectionFailureDetail = connectionMessage
                startDiscoveryLoop(resetResults: false)
                return
            }
            let strategy = CameraStartupPolicy.connectionStrategy(
                host: host,
                savedCameras: savedCameras,
                transportKind: transportKind
            )
            let displayNameHint = discoveredCamera?.displayName ?? savedCamera?.displayName ?? ""
            let transport =
                transportKind == .usb
                ? PTPIPSavedCameraRecord.usbTransportLabel
                : transportLabel(for: discoveredCamera?.source, fallback: savedCamera?.transport)
            pendingPairingSaveCandidate = PendingPairingSaveCandidate(
                host: host,
                displayName: displayNameHint,
                transport: transport
            )
            connection = .scanning
            connectionPhase = .handshaking
            isDemoSession = false
            liveFrameImage = nil
            acceptedPairingForCurrentAttempt = false
            establishmentDiagnostic.withLock { $0 = "" }
            connectionMessage = startupConnectionMessage(for: strategy, host: host)
            logConnection(
                "attempt host=\(host) strategy=\(strategy) saved=\(savedCameras.count) knownPaired=\(knownPairedCameras.count)"
            )
            do {
                let guid = store.guid()
                let attempt = try await establishStartupSession(
                    host: host,
                    guid: guid,
                    strategy: strategy
                )
                let initialSession = attempt.session
                let requestedPairing = attempt.requestedPairing
                // Torn down while establishing (operator disconnect, new attempt): close the fresh
                // session instead of publishing it into cleared state. Graceful CloseSession so the
                // camera releases the slot we just opened (bare close would strand it).
                guard connectionGeneration == generation else {
                    await initialSession.shutdown()
                    return
                }

                let session: NativeCameraSession
                if requestedPairing {
                    if acceptedPairingForCurrentAttempt {
                        savePairedCamera(
                            host: initialSession.identity.host,
                            displayName: initialSession.identity.displayName,
                            transport: transport
                        )
                        // Pairing done → immediate auto-reconnect off the saved profile. Most
                        // wedge-prone moment: without a graceful CloseSession the camera still
                        // holds the pairing session when the reconnect Init lands.
                        await initialSession.shutdown()
                        pendingPairingSaveCandidate = nil
                        pendingPairedReconnectHost = initialSession.identity.host
                        pendingPairedReconnectSSID = cameraAccessPointSSID(
                            host: initialSession.identity.host,
                            displayName: initialSession.identity.displayName
                        )
                        transitionToSavedCameraNetworkCheck(
                            message:
                                "Pairing complete. Tap “Confirm” on the camera — we'll reconnect automatically."
                        )
                        return
                    } else {
                        session = initialSession
                    }
                } else {
                    session = initialSession
                }

                pendingPairingSaveCandidate = nil
                discoveredCameras = []
                pendingPairingChallenge = nil
                cameraSession = session
                connectedIdentity = session.identity
                startKeepAlive(session: session)
                startEventDraining(session: session)
                startLinkHealthMonitoring()
                store.upsertSavedCamera(
                    host: session.identity.host,
                    displayName: session.identity.displayName,
                    transport: transport
                )
                refreshSavedCameras()
                markFirstPairWizardCompleted()
                liveFPS = "READY"
                cameraState = cameraState.updating(
                    cameraName: session.identity.displayName
                )
                connectionMessage =
                    session.identity.establishmentSummary.isEmpty
                    ? "\(session.identity.displayName) is connected."
                    : "\(session.identity.displayName) is connected."
                connection = .connected
                connectionPhase = .connected
                // Reconnect achieved — disarm the paired-reconnect watcher (it stays armed
                // through failed Init attempts so flaky post-hop/post-pairing sessions retry).
                pendingPairedReconnectHost = nil
                pendingPairedReconnectSSID = nil
                lastPairedRejoinAttemptAt = nil
                pairedReconnectSawCameraLeave = false
                connectionProgressDeviceName = ConnectionProgressCopy.resolveDisplayName(
                    rawName: session.identity.displayName,
                    savedCamera: savedCameras.first {
                        $0.host == PTPIPPairedHosts.normalizedHost(session.identity.host)
                    }
                )
                logConnection(
                    "connected host=\(session.identity.host) pairing=\(requestedPairing) summary=\(session.identity.establishmentSummary)"
                )
                // Skip the "camera ready" landing page and drive straight into live view. If live
                // view can't start, startLiveView() falls back to isMonitorPresented = false with
                // connection = .connected, which surfaces the ready page as a recovery screen.
                enterLiveView()
            } catch {
                // Torn down while establishing — the failure belongs to an attempt the operator
                // already abandoned; don't overwrite the current connection state or message.
                guard connectionGeneration == generation else { return }
                let acceptedPairing = acceptedPairingForCurrentAttempt
                if acceptedPairing {
                    savePendingPairingCamera()
                }
                pendingPairingSaveCandidate = nil
                disconnectCameraSession(resetConnection: false)
                if acceptedPairing {
                    pendingPairedReconnectHost = host
                    pendingPairedReconnectSSID = cameraAccessPointSSID(
                        host: host,
                        displayName: connectedIdentity?.displayName
                    )
                    transitionToSavedCameraNetworkCheck(
                        message:
                            "Pairing complete. Tap “Confirm” on the camera — we'll reconnect automatically."
                    )
                    return
                }
                connection = .disconnected
                connectionPhase = .failed
                connectionProgressShowsFailure = true
                let baseError: String
                if isRejectedInitiator(error) {
                    baseError =
                        "The camera didn't recognize this phone. On the camera, create or choose a Connect to PC profile for this iPhone, then try again."
                } else {
                    baseError =
                        (error as? LocalizedError)?.errorDescription
                        ?? error.localizedDescription
                }
                let knownMatchedHost = knownPairedCameras.contains {
                    $0.host == PTPIPPairedHosts.normalizedHost(host)
                }
                connectionMessage = connectionFailureMessage(
                    baseError: baseError,
                    strategy: strategy,
                    savedCamerasCount: savedCameras.count,
                    knownPairedCamerasCount: knownPairedCameras.count,
                    knownMatchedHost: knownMatchedHost,
                    host: host
                )
                connectionFailureDetail = connectionMessage
                logConnection("failed host=\(host) \(self.connectionMessage)")
                startDiscoveryLoop(resetResults: false)
            }
        }
    }

    private func startupConnectionMessage(
        for strategy: CameraConnectionStrategy,
        host: String
    ) -> String {
        let isUSB = host.hasPrefix(DiscoveredCamera.usbHostKeyPrefix)
        switch strategy {
        case .savedProfile:
            return isUSB
                ? "Reconnecting to your saved camera over USB-C…"
                : "Reconnecting to your saved camera…"
        case .firstTimePairing:
            return isUSB
                ? "Setting up your camera over USB-C for the first time…"
                : "Setting up your camera for the first time…"
        case .restoreCameraProfileBeforePairing:
            return "Checking whether this camera already knows your phone…"
        }
    }

    private func connectionFailureMessage(
        baseError: String,
        strategy: CameraConnectionStrategy,
        savedCamerasCount: Int,
        knownPairedCamerasCount: Int,
        knownMatchedHost: Bool,
        host: String
    ) -> String {
        _ = strategy
        _ = savedCamerasCount
        _ = knownPairedCamerasCount
        _ = knownMatchedHost
        _ = host
        return StartupConnectionCopy.friendly(baseError)
    }

    func forgetPairingForCurrentHost() {
        let host = cameraHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return }
        forgetPairing(host: host)
    }

    func forgetPairing(host: String) {
        if connectedIdentity?.host == PTPIPPairedHosts.normalizedHost(host) {
            disconnectCameraSession(resetConnection: false)
            connection = .disconnected
            isDemoSession = false
        }
        // Fully forget the camera, including the knownPaired identity. Silent reconnect still
        // works because every connection probes the camera; if the Nikon still recognizes this
        // phone the next connect reconnects without a code, otherwise it pairs fresh.
        NativeCameraConnectionStore.shared.forgetKnownPairing(host: host)
        refreshSavedCameras()
        applyStartupDestination()
        connectionMessage =
            "Removed this camera from OpenZCine. You can pair it again anytime."
        startDiscoveryLoop(resetResults: savedCameras.isEmpty)
    }

    func updateSavedCameraPresentation(
        camera: PTPIPSavedCameraRecord,
        customName: String?,
        borderColor: String?,
        icon: String?
    ) {
        NativeCameraConnectionStore.shared.updateSavedCameraPresentation(
            host: camera.host,
            customName: customName,
            borderColor: borderColor,
            icon: icon
        )
        refreshSavedCameras()
    }

    func acceptPairing() {
        finishPairing(accepted: true)
    }

    func rejectPairing() {
        finishPairing(accepted: false)
    }

    func disconnect() {
        disconnectCameraSession(resetConnection: true)
        startDiscoveryLoop(resetResults: false)
    }

    /// Presents the versioned guide after the first successfully decoded live-view frame.
    func presentLiveViewGuideIfNeeded() {
        guard liveViewGuideStep == nil, !isDemoSession, liveViewGuideStore.shouldPresent else {
            return
        }
        liveViewGuideStep = .cameraControls
        AppDiagnostics.shared.record(.guidePresented)
    }

    /// Advances the guide or records completion after the final card.
    func advanceLiveViewGuide() {
        guard let current = liveViewGuideStep else { return }
        if let next = current.next {
            liveViewGuideStep = next
            return
        }
        liveViewGuideStore.markCompleted()
        liveViewGuideStep = nil
        AppDiagnostics.shared.record(.guideCompleted)
    }

    /// Dismisses the guide and prevents another automatic presentation for this guide version.
    func skipLiveViewGuide() {
        guard liveViewGuideStep != nil else { return }
        liveViewGuideStore.markCompleted()
        liveViewGuideStep = nil
        AppDiagnostics.shared.record(.guideSkipped)
    }

    /// Resets the guide from System settings, showing it immediately when a monitor is active.
    func replayLiveViewGuide() {
        liveViewGuideStore.reset()
        guard isMonitorPresented else { return }
        activePanel = nil
        liveViewGuideStep = .cameraControls
        AppDiagnostics.shared.record(.guidePresented)
    }

    #if DEBUG
        /// Selects a deterministic guide card for simulator screenshot verification.
        func forceLiveViewGuide(_ step: LiveViewGuideStep) {
            activePanel = nil
            liveViewGuideStep = step
        }
    #endif

    // Demo-session entry points (screenshot/marketing harness — see DemoHarness.swift). Debug-only:
    // with these compiled out, `isDemoSession`/`demoUIMode` can never become true in a Release
    // build, which keeps the demo-interaction helpers further down inert without #if in views.
    #if DEBUG
        func startDemoSession() {
            stopDiscoveryLoop()
            disconnectCameraSession(resetConnection: false)
            isDemoSession = true
            isMonitorPresented = true
            connectedIdentity = nil
            liveFrameImage = nil
            cameraState = .preview
            resetCameraPropertyState()
            resetLinkHealthMeasurements()
            discoveredCameras = []
            connectionMessage = "Demo UI session. No camera commands are being sent."
            connection = .connected
            refreshLinkHealth()
        }

        /// Seeds a representative camera-owned stereo meter and manual sensitivity for simulator
        /// layout verification. Release builds contain neither this helper nor the demo harness.
        func demoSeedAudioMonitor() {
            liveAudioLevels = AudioMeterLevels(
                cameraIndicator: PTPLiveViewSoundIndicator(
                    peakLeft: 12, peakRight: 10, currentLeft: 9, currentRight: 7))
            cameraPropertySnapshot = cameraPropertySnapshot.applying(
                property: .movieAudioInputSensitivity, data: Data([12]))
        }

        /// Routes the simulator's demo-only keyboard surface. Keeping this decision in the model makes
        /// the real shortcut behavior testable independently of Simulator hardware-key forwarding.
        func handleDemoKey(input: String, hasCommand: Bool) {
            let normalized = input.lowercased()
            if hasCommand, normalized == "o" {
                enterInteractiveDemoFromStartupShortcut()
            } else if hasCommand, normalized == "d", isDemoSession {
                demoUIMode.toggle()
                if demoUIMode { demoSeedFocusPair() }
            } else if !hasCommand, normalized == "8", isDemoSession {
                demoToggleEyeBox()
            } else if !hasCommand, isDemoSession, let number = Int(normalized), number >= 1,
                number <= demoFeedImagePaths.count
            {
                demoSelectFeedImage(number)
            }
        }

        /// Simulator marketing entry point for ⌘O. It is intentionally accepted only while the
        /// startup/connection experience is visible: a shortcut can cancel an in-flight connection,
        /// but can never tear down a real live monitor or replace a presented full-screen workflow.
        func enterInteractiveDemoFromStartupShortcut() {
            guard !isMonitorPresented, !isStandaloneMediaLibraryPresented,
                !isStandaloneSettingsPresented, !isRedDownloadPresented
            else { return }
            dismissConnectionProgress()
            startDemoSession()
            demoUIMode = true
            demoSeedFocusPair()
            demoSelectFeedImage(1)
        }
    #endif

    func enterLiveView() {
        guard canEnterLiveView, let session = cameraSession else {
            connectionMessage =
                "Connect to a saved camera first."
            return
        }
        connection = .preparingLiveView
        connectionPhase = .preparingLiveView
        connectionMessage =
            "Opening live view…"
        startLiveView(session: session)
    }

    private let discoveryService = NativeCameraDiscoveryService()
    private let frameDecoder = FrameDecoder()
    @ObservationIgnored private var frameRendererStorage: LiveFrameRenderer?
    /// Whether the CPU renderer's memo may hold a baked frame — lets the identity/Metal display
    /// path skip the per-frame eviction actor hop and evict once on transition instead.
    @ObservationIgnored private var rendererHoldsBakedFrame = false
    private let scopeSampler = FrameScopeSampler()
    private var cameraSession: NativeCameraSession?

    /// User-facing label for the live session's physical link ("Wi-Fi" / "USB-C"), or nil when no
    /// camera session is active.
    var activeTransportLabel: String? {
        cameraSession?.transportKind.savedRecordLabel
    }
    private var discoveryLoopTask: Task<Void, Never>?
    private var discoveryLoopGeneration = 0
    private var liveViewTask: Task<Void, Never>?
    private var keepAliveTask: Task<Void, Never>?
    private var linkHealthUpdateTask: Task<Void, Never>?
    /// The in-flight connection establishment, stored so teardown can cancel it. Guarded by
    /// `connectionGeneration` so an attempt that outlives a disconnect can't resurrect a session.
    @ObservationIgnored private var establishmentTask: Task<Void, Never>?
    /// Monotonic teardown epoch: bumped on every session clear. An establishment attempt captures
    /// the epoch at start and bails before publishing a session if it changed underneath it.
    @ObservationIgnored private var connectionGeneration = 0
    /// The async socket teardown of the previous session. Awaited before any new establishment —
    /// a PTP-IP camera accepts one command channel per initiator, and overlapping the old
    /// half-closed channel with a new Init can wedge the camera's PTP state machine.
    @ObservationIgnored private var sessionTeardownTask: Task<Void, Never>?
    /// Single-flight camera property poll (live view and command mode). Polls must never stack
    /// behind the transaction gate: a slow poll burst would delay the next frame fetch.
    @ObservationIgnored private var propertyPollTask: Task<Void, Never>?
    /// Single-flight drain of queued property writes while live view is down.
    @ObservationIgnored private var pendingWriteDrainTask: Task<Void, Never>?
    @ObservationIgnored private var measuredLiveViewFPS: Double = 0
    @ObservationIgnored private var lastGoodFrameAt: Date?
    @ObservationIgnored private var consecutiveBadLiveFrames = 0
    @ObservationIgnored private var recentKeepaliveFailures = 0
    @ObservationIgnored private var isStreamRecovering = false
    @ObservationIgnored private var signalBarsFilter = LinkSignalBars()
    private var eventDrainTask: Task<Void, Never>?
    /// The fire-and-forget `stopLiveView()` started on background, tracked so a quick return to the
    /// foreground awaits it before restarting the stream (otherwise the stop can land after the
    /// restart and shut the resumed feed back down).
    private var backgroundStopTask: Task<Void, Never>?
    private var pairingContinuation: CheckedContinuation<Bool, Never>?
    private var pendingPairingSaveCandidate: PendingPairingSaveCandidate?
    private var acceptedPairingForCurrentAttempt = false
    /// Host the app just paired and is waiting to rejoin the network with its new profile, so the
    /// discovery loop can reconnect to it automatically once it reappears.
    private var pendingPairedReconnectHost: String?
    /// Whether the just-paired camera has been observed leaving the network, so auto-reconnect
    /// waits for the genuine drop/rejoin instead of grabbing the lingering pre-drop session.
    private var pairedReconnectSawCameraLeave = false
    /// Camera AP SSID captured at pairing time, used to pull the phone back onto the camera network
    /// after the pairing-triggered AP restart (iOS may otherwise drift to a preferred home network).
    @ObservationIgnored private var pendingPairedReconnectSSID: String?
    /// Throttle for the paired-reconnect Wi‑Fi re-apply so it isn't fired every discovery cycle.
    @ObservationIgnored private var lastPairedRejoinAttemptAt: Date?
    /// Saved USB cameras that already got their one silent auto-reconnect attempt for the current
    /// plug-in. A key re-arms when the camera disappears from discovery (unplug).
    @ObservationIgnored private var attemptedUSBAutoReconnectHostKeys: Set<String> = []
    private(set) var cameraPropertySnapshot = PTPCameraPropertySnapshot()
    private var propertyPollIndex = 0
    /// The `LiveViewImageSize` byte last written to the camera, so a thermal/warning step-down only
    /// restarts the stream when the effective size actually changes (start/stop cycling the encoder
    /// is itself a heat source — see `applyThermalStreamStepDownIfNeeded`).
    @ObservationIgnored private var lastAppliedStreamImageSize: UInt8?
    /// Wall-clock cadences gating the descriptor/storage refresh burst to slow timers — re-reading
    /// the rarely-changing enumeration descriptors every poll cycle keeps the camera radio busy
    /// for nothing. `nil` forces a refresh on the first cycle after connect.
    @ObservationIgnored private var lastDescriptorRefreshAt: Date?
    @ObservationIgnored private var lastStorageRefreshAt: Date?
    @ObservationIgnored private var lastRecordingPropertyPollAt: Date?
    /// One-shot per property: first read outcome (bytes or rejection) logged this session, so a
    /// command tile reading "—" on hardware is diagnosable from Console without per-poll spam.
    @ObservationIgnored private var commandTileDiagnosticLogged: Set<PTPPropertyCode> = []
    private static let commandTileDiagnosticProps: Set<PTPPropertyCode> = [
        .movMicrophone, .movRecordMicrophoneLevelValue, .movWindNoiseReduction, .movieAttenuator,
        .gridDisplay,
    ]
    private var lastKnownStorage: PTPStorageInfo?
    private var pendingCameraWrites: [PendingCameraWrite] = []
    /// Optimistic shutter display mode while a `movieShutterMode` write is queued or in flight.
    /// Poll readback is suppressed until the write completes so the status bar and picker tab
    /// don't snap back to the camera's previous mode before the safe point runs.
    private var pendingShutterMode: ShutterDisplayMode?
    /// Optimistic shutter control lock while a `movieTVLockSetting` write is queued or in flight.
    /// `true` = unlocking, `false` = locking. Stale poll readback must not undo the operator's
    /// long-press before the safe point runs or re-lock the picker after an unlock write lands.
    private var pendingShutterLockState: Bool?
    /// Optimistic dual-base ISO circuit while a `movieBaseISO` write is queued or in flight.
    private var pendingBaseISOHigh: Bool?
    /// AF point requested by a feed tap, in the camera's live-view coordinate space. Sent at the
    /// next live-view control safe point via `ChangeAfArea`.
    private var pendingFocusPoint: (x: UInt32, y: UInt32)?
    /// Multi-step focus reset when subject tracking must be released before recentring.
    private var focusResetStep: FocusResetStep?
    /// A record start/stop requested by the record button, serviced at the next live-view safe
    /// point (so the StartMovieRecInCard / EndMovieRec op doesn't race the live-view loop's reads).
    private var pendingRecordToggle = false
    /// Target record state for a queued app record command (`true` = start, `false` = stop). Kept
    /// separately from `isRecording` so the optimistic UI flip isn't undone before the safe point runs.
    private var pendingRecordStart: Bool?
    /// Consecutive live-view-start failures (no first frame), across reconnects. A first-frame
    /// framing desync needs a fresh command channel, so `.neverStarted` full-reconnects; this counter
    /// (reset on a good first frame) bounds that so a body that genuinely can't stream doesn't loop.
    private var consecutiveStartFailures = 0
    @ObservationIgnored private var lastScopeSampleTime: CFAbsoluteTime = 0
    /// True while `sampleLiveScopeAssist` is in flight — skip starting another decode-heavy sample.
    @ObservationIgnored private var scopeSampleInFlight = false
    @ObservationIgnored private var lastFrameDisplayTime: CFAbsoluteTime = 0
    @ObservationIgnored private var lastFocusDisplayTime: CFAbsoluteTime = 0
    @ObservationIgnored private var lastLevelUpdateTime: CFAbsoluteTime = 0
    /// Thermal-shedding-only display gate; NOT a general cap (see `publishLiveFrameDisplay`). A
    /// wall-clock "every N seconds" gate against a ~fixed-period source (the ZR delivers ~30 fps)
    /// only ever lands on an integer division of the source rate — ceil(30/24)=2 makes "1/24 s"
    /// deliver 15 fps, silently halving the feed. Fine as a bounded degraded mode under real
    /// thermal pressure (`ThermalTier`); wrong as an always-on cap. Decode, watchdog, and scope
    /// sampling still run every camera frame.
    private static let liveFrameDisplayMinInterval: CFAbsoluteTime = 1.0 / 24.0
    /// AF / subject-detection box overlay update cap (~15 Hz).
    private static let liveFocusDisplayMinInterval: CFAbsoluteTime = 1.0 / 15.0
    /// Virtual-horizon low-pass update cap when the level assist is on (~10 Hz).
    private static let levelAngleMinInterval: CFAbsoluteTime = 1.0 / 10.0

    @ObservationIgnored private var screenWakeSuppressedForBackground = false
    private var didPrepareStartup = false
    @ObservationIgnored private var cameraWiFiJoinTask: Task<Void, Never>?
    private let establishmentDiagnostic = OSAllocatedUnfairLock(initialState: "")

    private struct PendingPairingSaveCandidate {
        let host: String
        let displayName: String
        let transport: String
    }

    private struct PendingCameraWrite {
        let picker: CameraPicker
        let value: String
        let write: PTPCameraPropertyWrite
    }

    /// Keeps only the last queued value for each concrete PTP property. Rapid drags or taps can
    /// produce dozens of intermediate values; sending each one keeps the radio and camera busy for
    /// states the operator has already left. Coalescing by property preserves dependent writes such
    /// as white-balance mode followed by Kelvin temperature.
    private func enqueueCameraWrite(_ pending: PendingCameraWrite) {
        pendingCameraWrites.removeAll { $0.write.property == pending.write.property }
        pendingCameraWrites.append(pending)
    }

    private struct FocusResetContext: Equatable {
        let recenterX: UInt32
        let recenterY: UInt32
        let demoteSubjectArea: Bool
        let suspendSubjectDetection: Bool
        let savedFocusArea: String
        let savedFocusSubject: String
    }

    private enum FocusResetStep {
        case endTracking(FocusResetContext)
        case afDriveCancel(FocusResetContext)
        case suspendSubjectDetection(FocusResetContext)
        case demoteSubjectArea(FocusResetContext)
        case settleBeforeRecenter(context: FocusResetContext, framesElapsed: Int)
        case recenter(context: FocusResetContext)
        case confirmTrackingReleased(context: FocusResetContext)
        case restoreFocusArea(context: FocusResetContext)
        case restoreSubjectDetection(context: FocusResetContext)
    }

    private func resetCameraPropertyState() {
        cameraPropertySnapshot = PTPCameraPropertySnapshot()
        propertyPollIndex = 0
        lastRecordingPropertyPollAt = nil
        pendingCameraWrites.removeAll()
        pendingShutterMode = nil
        pendingShutterLockState = nil
        pendingBaseISOHigh = nil
        pendingFocusPoint = nil
        focusResetStep = nil
        cameraApertures = []
    }

    private func refreshSavedCameras() {
        savedCameras = NativeCameraConnectionStore.shared.savedCameras()
        if savedCameras.isEmpty, startupMode == .savedCameras {
            startupMode = .discovery
        }
    }

    private func applyStartupDestination() {
        switch CameraStartupPolicy.launchDestination(savedCameras: savedCameras) {
        case .addCamera:
            startupMode = .discovery
        case .savedCameras:
            startupMode = .savedCameras
        }
    }

    private func restartDiscoveryLoop(resetResults: Bool) {
        stopDiscoveryLoop()
        startDiscoveryLoop(resetResults: resetResults)
    }

    /// Pull-to-refresh on the camera list: one immediate, awaited scan — without blanking the
    /// current rows — then the background loop resumes its own cadence. The spinner stays up
    /// exactly as long as the scan actually runs.
    func refreshCameraDiscovery() async {
        guard !isConnected, !isDemoSession else { return }
        stopDiscoveryLoop()
        let guid = NativeCameraConnectionStore.shared.guid()
        let cameras =
            (try? await discoveryService.discover(
                guid: guid,
                priorityHosts: savedCameras.map(\.host)
            ) { [weak self] message in
                self?.connectionMessage = StartupConnectionCopy.friendly(message)
            }) ?? []
        applyDiscoveryResults(cameras)
        startDiscoveryLoop(resetResults: false)
    }

    private func startDiscoveryLoop(resetResults: Bool) {
        guard discoveryLoopTask == nil, !isConnected, !isDemoSession else { return }
        if resetResults {
            discoveredCameras = []
            selectedDiscoveredCameraID = nil
        }

        let guid = NativeCameraConnectionStore.shared.guid()
        discoveryLoopGeneration += 1
        let generation = discoveryLoopGeneration
        discoveryLoopTask = Task { [weak self] in
            await self?.runDiscoveryLoop(guid: guid, generation: generation)
        }
    }

    private func stopDiscoveryLoop() {
        discoveryLoopGeneration += 1
        discoveryLoopTask?.cancel()
        discoveryLoopTask = nil
    }

    private func runDiscoveryLoop(guid: Data, generation: Int) async {
        defer {
            if discoveryLoopGeneration == generation {
                discoveryLoopTask = nil
            }
        }
        var emptyStreak = 0
        while !Task.isCancelled, discoveryLoopGeneration == generation, !isConnected, !isDemoSession
        {
            isIPhoneHotspotBridgeActive = NativePersonalHotspotDetector.isBridgeActive()
            connection = .scanning
            isMonitorPresented = false
            connectionMessage = "Looking for cameras on your network…"

            let cameras: [DiscoveredCamera]
            do {
                cameras = try await discoveryService.discover(
                    guid: guid,
                    priorityHosts: savedCameras.map(\.host)
                ) { [weak self] message in
                    self?.connectionMessage = StartupConnectionCopy.friendly(message)
                }
            } catch {
                cameras = []
                connectionMessage =
                    "Still looking. Turn on Connect to PC on the camera, then join its Wi‑Fi or your iPhone hotspot."
            }

            guard !Task.isCancelled, discoveryLoopGeneration == generation else { break }
            applyDiscoveryResults(cameras)

            if cameras.isEmpty { emptyStreak += 1 } else { emptyStreak = 0 }
            // The first retry stays responsive, then grow to a 30s cap so a connect screen left
            // open does not keep waking a sleeping camera's Wi-Fi radio. Pull-to-refresh remains
            // an immediate, awaited scan when the operator expects a camera to appear.
            let delay = CameraDiscovery.automaticScanRetryInterval(
                emptyStreak: emptyStreak,
                foundCamera: !cameras.isEmpty)
            try? await Task.sleep(for: .seconds(delay))
        }
    }

    /// Resolves the camera's access-point SSID at pairing time: prefer the SSID the phone is on (the
    /// camera AP we paired over), else derive it from the camera's PTP name, else a saved record.
    private func cameraAccessPointSSID(host: String, displayName: String?) -> String? {
        if let ssid = connectedWiFiSSID?.trimmingCharacters(in: .whitespacesAndNewlines),
            ssid.uppercased().hasPrefix(CameraWiFiSSID.nikonAccessPointPrefix.uppercased())
        {
            return ssid
        }
        if let displayName, let derived = CameraWiFiSSID.deriveSSID(fromCameraName: displayName) {
            return derived
        }
        let normalized = PTPIPPairedHosts.normalizedHost(host)
        if let saved = savedCameras.first(where: { $0.host == normalized }) {
            return CameraWiFiSSID.resolve(for: saved)
        }
        return nil
    }

    /// Leaves the camera's Wi‑Fi so iOS falls back to home Wi‑Fi or cellular, letting the RED LUT
    /// download reach the internet from camera-AP transport. The download screen unblocks itself
    /// reactively when reachability flips; ``endInternetHop()`` (fired when that screen
    /// dismisses) arms the rejoin + reconnect.
    func beginInternetHop(rehostActivePanel: Bool = true) {
        guard !internetHopActive else { return }
        internetHopActive = true
        // Capture identity before teardown. The host falls back to the camera-AP convention
        // (cameraHost defaults to the ZR's gateway) so discovery can still match on return even
        // if the session was already gone.
        let host = connectedIdentity?.host ?? cameraHost
        let displayName = connectedIdentity?.displayName
        Task { [weak self] in
            guard let self else { return }
            let currentSSID = await NativeNetworkInterfaceSnapshot.currentWiFiSSID()
            let ssid = currentSSID ?? cameraAccessPointSSID(host: host, displayName: displayName)
            guard let ssid, !ssid.isEmpty else {
                internetHopActive = false
                return
            }
            internetHopReturn = (host, ssid)
            if rehostActivePanel {
                // Long-running downloads and account sign-in keep their initiating surface alive
                // as a root cover. Support/report actions deliberately skip this: their selected
                // destination becomes the next surface after the camera session drops.
                if activePanel == .media {
                    activePanel = nil
                    isStandaloneMediaLibraryPresented = true
                } else {
                    if activePanel == .settings {
                        activePanel = nil
                        isStandaloneSettingsPresented = true
                    }
                    pendingHopShareResumeClips = nil
                }
            } else {
                pendingHopShareResumeClips = nil
            }
            // Nothing may pull the phone back onto the camera AP mid-download.
            stopDiscoveryLoop()
            disconnectCameraSession(resetConnection: true)
            connection = .disconnected
            WiFiJoinCoordinator.shared.leaveCameraNetwork(ssid: ssid)
            // The cached SSID is what AP detection reads — clear it now, or a stale
            // "NIKON_ZR_…" keeps isOnCameraAccessPoint true and the post-hop internet wait
            // spins its full timeout.
            connectedWiFiSSID = nil
        }
    }

    /// True when the phone is joined to the camera's local-only AP (no internet route).
    /// Address + cached-SSID based — deliberately no `NEHotspotNetwork` call, which logs a
    /// nehelper error line per invocation while the wifi-info capability isn't live.
    var isOnCameraAccessPoint: Bool {
        CameraWiFiJoinPolicy.isOnCameraAccessPoint(
            localAddresses: NativeNetworkInterfaceSnapshot.localIPv4Addresses(),
            connectedSSID: connectedWiFiSSID
        )
    }

    /// Waits (post-hop) for iOS to settle on a network with a real internet path. Returns false
    /// on timeout so the caller can rejoin the camera and surface a clear error.
    func waitForInternetPath(timeoutSeconds: Int) async -> Bool {
        for _ in 0..<(timeoutSeconds * 2) {
            guard !Task.isCancelled else { return false }
            try? await Task.sleep(for: .milliseconds(500))
            if !isOnCameraAccessPoint, await Self.hasSatisfiedNetworkPath() { return true }
        }
        return false
    }

    private static func hasSatisfiedNetworkPath() async -> Bool {
        let monitor = NWPathMonitor()
        defer { monitor.cancel() }
        return await withCheckedContinuation { continuation in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            monitor.pathUpdateHandler = { path in
                let first = resumed.withLock { state -> Bool in
                    if state { return false }
                    state = true
                    return true
                }
                guard first else { return }
                continuation.resume(returning: path.status == .satisfied)
            }
            monitor.start(queue: .global(qos: .utility))
        }
    }

    /// Rejoins the camera's Wi‑Fi after an internet hop via the FULL join pipeline the scan flow
    /// uses (`NEHotspotConfiguration` apply with transparent retries, subnet confirmation, then
    /// discovery → connect chaining, narrated in the white card). A fire-and-forget re-apply is
    /// not enough: leaving the AP removes the configuration, so the return is a fresh join racing
    /// iOS settling back onto home Wi‑Fi. No-op when no hop is active.
    func endInternetHop() {
        guard let hopReturn = internetHopReturn else { return }
        internetHopReturn = nil
        internetHopActive = false
        connectionProgressDeviceName = cameraWiFiJoinDeviceName()
        connectionProgressIsUSB = false
        isConnectionProgressPresented = true
        cameraWiFiJoinTask?.cancel()
        cameraWiFiJoinTask = Task { [weak self] in
            await self?.runCameraWiFiJoin(
                target: .specificSSID(hopReturn.ssid),
                joinStrategy: .hotspotConfigurationOnly,
                reconnectHost: hopReturn.host
            )
        }
    }

    /// Leaves the camera AP only when needed and waits for a validated internet route before an
    /// external support, GitHub, or privacy link is opened.
    func prepareExternalInternetLinkHandoff() async -> Bool {
        if bugReportInternetHandoffActive {
            bugReportInternetHandoffActive = false
            externalInternetLinkHandoffActive = true
            externalInternetLinkSawBackground = false
            return true
        }
        guard isOnCameraAccessPoint else { return true }
        beginInternetHop(rehostActivePanel: false)
        guard await waitForInternetPath(timeoutSeconds: 30) else {
            endInternetHop()
            return false
        }
        externalInternetLinkHandoffActive = true
        externalInternetLinkSawBackground = false
        return true
    }

    /// Leaves the camera AP for the in-app report flow without preserving or reopening Settings.
    /// The report becomes the root-owned destination after internet reachability is confirmed.
    func prepareBugReportInternetHandoff() async -> Bool {
        if bugReportInternetHandoffActive { return true }
        guard isOnCameraAccessPoint else { return true }
        beginInternetHop(rehostActivePanel: false)
        guard await waitForInternetPath(timeoutSeconds: 30) else {
            endInternetHop()
            return false
        }
        bugReportInternetHandoffActive = true
        return true
    }

    /// Shows root-owned progress while an external destination waits for an internet route.
    func beginInternetDestinationPreparation(_ title: String) {
        internetDestinationPreparationTitle = title
    }

    /// Clears progress only for the task that originally set it, preventing an older handoff from
    /// hiding a newer destination's status.
    func finishInternetDestinationPreparation(_ title: String) {
        guard internetDestinationPreparationTitle == title else { return }
        internetDestinationPreparationTitle = nil
    }

    /// Completes a rejected browser handoff immediately so the camera is not left disconnected.
    func completeExternalInternetLinkHandoff(browserAccepted: Bool) {
        guard !browserAccepted else { return }
        guard externalInternetLinkHandoffActive else { return }
        externalInternetLinkHandoffActive = false
        externalInternetLinkSawBackground = false
        endInternetHop()
    }

    /// Records that an accepted external page really took OpenZCine into the background. A mere
    /// inactive/active transition is not enough evidence that the person finished with the page.
    func noteExternalInternetLinkHandoffEnteredBackground() {
        guard externalInternetLinkHandoffActive else { return }
        externalInternetLinkSawBackground = true
    }

    /// Rejoins the camera after the person returns from the external browser.
    func resumeExternalInternetLinkHandoffIfNeeded() {
        guard
            ExternalInternetLinkReturnPolicy.shouldReconnect(
                handoffActive: externalInternetLinkHandoffActive,
                sawBackground: externalInternetLinkSawBackground
            )
        else { return }
        externalInternetLinkHandoffActive = false
        externalInternetLinkSawBackground = false
        endInternetHop()
    }

    /// Rejoins the camera when the in-app report flow finishes or is explicitly closed.
    func resumeBugReportInternetHandoffIfNeeded() {
        guard bugReportInternetHandoffActive else { return }
        bugReportInternetHandoffActive = false
        endInternetHop()
    }

    /// Re-applies the camera AP config (throttled) while waiting for a just-paired camera to return,
    /// so the phone rejoins the camera network instead of settling on a preferred home network.
    private func attemptPairedReconnectRejoin() {
        guard let ssid = pendingPairedReconnectSSID, !ssid.isEmpty else { return }
        let now = Date()
        if let last = lastPairedRejoinAttemptAt, now.timeIntervalSince(last) < 5 { return }
        lastPairedRejoinAttemptAt = now
        WiFiJoinCoordinator.shared.reapplyCameraNetwork(ssid: ssid)
    }

    private func applyDiscoveryResults(_ cameras: [DiscoveredCamera]) {
        discoveredCameras = cameras

        // After a fresh pairing the camera shows "Pair complete", then drops off and rejoins with
        // its new profile. Reconnect automatically (silently, since it is now saved) — but only
        // once we've seen it actually leave and come back, so we don't reconnect to the lingering
        // pre-drop session before the operator confirms on the camera.
        if let pendingHost = pendingPairedReconnectHost,
            let normalized = PTPIPPairedHosts.normalizedHost(pendingHost)
        {
            let match = cameras.first(where: {
                PTPIPPairedHosts.normalizedHost($0.ip) == normalized
            })
            if match == nil {
                pairedReconnectSawCameraLeave = true
                // The camera dropped its AP to restart with the new pairing profile. Pull the phone
                // back onto the camera network so discovery can see it return (iOS may otherwise
                // settle on a preferred home network and never rejoin on its own).
                attemptPairedReconnectRejoin()
            } else if pairedReconnectSawCameraLeave, let match {
                // Stay ARMED until a connect actually succeeds (cleared in the connected path):
                // after an AP restart or internet hop the ZR can hold the pre-drop PTP session and
                // let the first Init time out — each discovery pass retries (connectToCamera
                // single-flights). Disarming here would strand the operator on one flaky Init.
                connectionMessage = "Your camera is back online. Reconnecting…"
                connectToCamera(match)
                return
            }
        }

        // A saved USB-C camera reconnects silently the moment it is plugged in. One attempt per
        // plug-in: an attempted host key re-arms only after the camera disappears (unplug), so a
        // body that keeps failing to connect doesn't spin in a reconnect loop.
        let attachedUSBHostKeys = Set(
            cameras.filter(\.isUSB).compactMap { PTPIPPairedHosts.normalizedHost($0.ip) })
        attemptedUSBAutoReconnectHostKeys.formIntersection(attachedUSBHostKeys)
        if !isConnected, startupMode == .savedCameras,
            let usbMatch = cameras.first(where: { camera in
                guard camera.isUSB,
                    let hostKey = PTPIPPairedHosts.normalizedHost(camera.ip),
                    !attemptedUSBAutoReconnectHostKeys.contains(hostKey)
                else { return false }
                return CameraStartupPolicy.savedCamera(forDiscovered: camera, in: savedCameras)
                    != nil
            }),
            let usbMatchHostKey = PTPIPPairedHosts.normalizedHost(usbMatch.ip)
        {
            attemptedUSBAutoReconnectHostKeys.insert(usbMatchHostKey)
            connectionMessage = "Camera detected on USB-C. Reconnecting…"
            connectToCamera(usbMatch)
            return
        }

        guard !cameras.isEmpty else {
            if !isConnected {
                connection = .scanning
            }
            if discoveryService.isUSBControlAuthorizationDenied {
                connectionMessage =
                    "USB-C camera access is turned off for OpenZCine. Allow camera access in Settings › Privacy & Security, or connect over Wi‑Fi."
            } else {
                connectionMessage =
                    startupRecoveryConnectionMessage()
                    ?? "Still looking for your camera. Turn on Connect to PC and stay on the same Wi‑Fi."
            }
            return
        }

        let selectableCameras = startupMode == .discovery ? pairingDiscoveryCandidates : cameras
        let selectedID = selectedDiscoveredCameraID
        if selectableCameras.isEmpty {
            selectedDiscoveredCameraID = nil
        } else if selectedID.map({ id in !selectableCameras.contains(where: { $0.id == id }) })
            ?? true
        {
            selectedDiscoveredCameraID = selectableCameras.first?.id
        }
        if let selectedID = selectedDiscoveredCameraID,
            let selectedCamera = selectableCameras.first(where: { $0.id == selectedID })
        {
            cameraHost = selectedCamera.ip
        }

        if startupMode == .discovery, selectableCameras.isEmpty {
            if !isConnected {
                connection = .scanning
            }
            connectionMessage =
                "Found \(cameras.count) saved camera\(cameras.count == 1 ? "" : "s") nearby. Pair a new camera to add another."
            return
        }
        if !isConnected {
            connection = .disconnected
        }
        let count = startupMode == .discovery ? selectableCameras.count : cameras.count
        connectionMessage =
            "Found \(count) camera\(count == 1 ? "" : "s"). Tap one to connect."
    }

    private func startupRecoveryConnectionMessage() -> String? {
        switch startupRecoveryPrompt {
        case .none:
            return nil
        case .enableIPhoneHotspot(let camera):
            return
                "\(camera.displayTitle) last used this iPhone's Personal Hotspot. Turn the hotspot on and keep Connect to PC enabled on the camera."
        case .waitForIPhoneHotspotCamera(let camera):
            return
                "Personal Hotspot is on. Waiting for \(camera.displayTitle) to join…"
        }
    }

    private func savePendingPairingCamera() {
        guard let candidate = pendingPairingSaveCandidate else { return }
        savePairedCamera(
            host: candidate.host,
            displayName: candidate.displayName,
            transport: candidate.transport
        )
    }

    private func savePairedCamera(host: String, displayName: String, transport: String) {
        NativeCameraConnectionStore.shared.upsertSavedCamera(
            host: host,
            displayName: displayName,
            transport: transport
        )
        refreshSavedCameras()
        markFirstPairWizardCompleted()
        startupMode = .savedCameras
    }

    private func preferredJoinCameraWiFiSavedCamera() -> PTPIPSavedCameraRecord? {
        savedCameras.first { camera in
            guard !camera.isUSBTransport else { return false }
            return CameraWiFiJoinPolicy.resolvedSSID(
                savedCamera: camera,
                discoveredCamera: nil
            ) != nil
        }
    }

    private func preferredJoinCameraWiFiSSID() -> String? {
        guard let camera = preferredJoinCameraWiFiSavedCamera() else { return nil }
        return CameraWiFiJoinPolicy.resolvedSSID(
            savedCamera: camera,
            discoveredCamera: nil
        )
    }

    private func performWiFiJoinIfNeeded(
        transportKind: CameraTransportKind,
        savedCamera: PTPIPSavedCameraRecord?,
        discoveredCamera: DiscoveredCamera?,
        deviceName: String
    ) async throws {
        guard
            let joinTarget = CameraWiFiJoinPolicy.joinTargetIfNeeded(
                transportKind: transportKind,
                localAddresses: NativeNetworkInterfaceSnapshot.localIPv4Addresses(),
                savedCamera: savedCamera,
                discoveredCamera: discoveredCamera,
                connectedSSID: connectedWiFiSSID
            )
        else { return }

        let credentials = resolveCameraWiFiCredentials(
            ssid: joinTarget.ssid,
            ssidPrefix: joinTarget.ssidPrefix
        )
        connectionPhase = .joiningWiFi
        connectionMessage = ConnectionProgressCopy.statusDetail(
            phase: .joiningWiFi,
            deviceName: deviceName,
            friendlyError: nil
        )

        let proactiveTarget: CameraWiFiJoinPolicy.ProactiveJoinTarget
        if let ssid = joinTarget.ssid {
            proactiveTarget = .specificSSID(ssid)
        } else if let prefix = joinTarget.ssidPrefix {
            proactiveTarget = .ssidPrefix(prefix)
        } else {
            return
        }
        // hotspotConfigurationOnly keeps the native join alert over our sheet; the ASK
        // picker rarely discovers Nikon soft-APs and would replace the popup visuals.
        try await joinCameraNetwork(
            target: proactiveTarget,
            credentials: credentials,
            joinStrategy: .hotspotConfigurationOnly
        )
    }

    private func transitionToSavedCameraNetworkCheck(message: String) {
        startupMode = .savedCameras
        isMonitorPresented = false
        connectedIdentity = nil
        connection = .scanning
        if isConnectionProgressPresented {
            // Phase-anchored (not message-anchored) so the instruction survives the discovery
            // loop, which overwrites `connectionMessage` on every iteration. Cleared when the
            // camera returns and `connectToCamera` takes over the phase.
            connectionPhase = .confirmOnCamera
        }
        connectionMessage = message
        startDiscoveryLoop(resetResults: false)
    }

    private func transportLabel(for source: DiscoverySource?, fallback: String?) -> String {
        switch source {
        case .bonjour, .subnetProbe:
            return "Wi-Fi"
        case .manual:
            return "Manual IP"
        case .usb:
            return PTPIPSavedCameraRecord.usbTransportLabel
        case nil:
            return fallback ?? "Wi-Fi"
        }
    }

    private func establishStartupSession(
        host: String,
        guid: Data,
        strategy: CameraConnectionStrategy
    ) async throws -> (session: NativeCameraSession, requestedPairing: Bool) {
        let diagnosticBox = establishmentDiagnostic
        let recordEstablishmentDiagnostic: @Sendable (String) -> Void = { summary in
            diagnosticBox.withLock { $0 = summary }
        }
        switch strategy {
        case .savedProfile:
            do {
                let session = try await establishSession(
                    host: host,
                    guid: guid,
                    requestPairing: false,
                    onEstablishmentDiagnostic: recordEstablishmentDiagnostic
                )
                return (session, false)
            } catch {
                guard isSavedProfileUnavailable(error) else { throw error }
                NativeCameraConnectionStore.shared.forgetKnownPairing(host: host)
                refreshSavedCameras()
                connectionMessage =
                    "Saved camera profile was out of date. Setting up again…"
                let session = try await establishFirstTimePairingSession(
                    host: host,
                    guid: guid,
                    onEstablishmentDiagnostic: recordEstablishmentDiagnostic
                )
                return (session, true)
            }
        case .firstTimePairing:
            let session = try await establishFirstTimePairingSession(
                host: host,
                guid: guid,
                onEstablishmentDiagnostic: recordEstablishmentDiagnostic
            )
            return (session, true)
        case .restoreCameraProfileBeforePairing:
            do {
                connectionMessage =
                    "Checking whether this camera already knows your phone…"
                let session = try await establishSession(
                    host: host,
                    guid: guid,
                    requestPairing: CameraStartupPolicy.startsWithPairingHandshake(
                        for: strategy
                    ),
                    onEstablishmentDiagnostic: recordEstablishmentDiagnostic
                )
                connectionMessage =
                    "This camera already knows your phone. Restoring the connection…"
                return (session, false)
            } catch {
                guard isSavedProfileUnavailable(error) else { throw error }
                connectionMessage =
                    "Setting up your camera for the first time…"
                let session = try await establishFirstTimePairingSession(
                    host: host,
                    guid: guid,
                    onEstablishmentDiagnostic: recordEstablishmentDiagnostic
                )
                return (session, true)
            }
        }
    }

    private func establishFirstTimePairingSession(
        host: String,
        guid: Data,
        onEstablishmentDiagnostic: (@Sendable (String) -> Void)? = nil
    ) async throws
        -> NativeCameraSession
    {
        try await establishSession(
            host: host,
            guid: guid,
            requestPairing: true,
            onPairingChallenge: { [weak self] challenge in
                await self?.autoAcceptPairing(challenge) ?? true
            },
            onEstablishmentDiagnostic: onEstablishmentDiagnostic
        )
    }

    /// Establishes a session over the transport implied by the host key: a `usb:<device-id>` key
    /// connects through ImageCaptureCore, anything else runs the Wi-Fi PTP-IP handshake.
    private func establishSession(
        host: String,
        guid: Data,
        requestPairing: Bool,
        onPairingChallenge: NativePairingChallengeHandler? = nil,
        onEstablishmentDiagnostic: (@Sendable (String) -> Void)? = nil
    ) async throws -> NativeCameraSession {
        guard host.hasPrefix(DiscoveredCamera.usbHostKeyPrefix) else {
            return try await NativeCameraSession.establish(
                host: host,
                guid: guid,
                requestPairing: requestPairing,
                onPairingChallenge: onPairingChallenge,
                onEstablishmentDiagnostic: onEstablishmentDiagnostic
            )
        }
        guard let device = USBCameraDeviceBrowser.shared.device(forHostKey: host) else {
            throw NativeCameraSessionError.connectionFailed(
                "The camera isn't plugged in. Connect it to this device with a USB-C cable, then try again."
            )
        }
        let usbTransport = USBCameraTransport(device: device)
        do {
            try await usbTransport.open()
        } catch {
            usbTransport.close()
            throw error
        }
        return try await NativeCameraSession.establish(
            transport: usbTransport,
            host: host,
            cameraName: device.name,
            requestPairing: requestPairing,
            onPairingChallenge: onPairingChallenge,
            onEstablishmentDiagnostic: onEstablishmentDiagnostic
        )
    }

    private func isRejectedInitiator(_ error: Error) -> Bool {
        guard let sessionError = error as? NativeCameraSessionError else { return false }
        if case .initFailed(.rejectedInitiator) = sessionError {
            return true
        }
        return false
    }

    private func isSavedProfileUnavailable(_ error: Error) -> Bool {
        guard let sessionError = error as? NativeCameraSessionError else { return false }
        if case .savedProfileRequired = sessionError {
            return true
        }
        return isRejectedInitiator(error)
    }

    /// Auto-accepts the pairing challenge without prompting. For a single-operator rig the code
    /// always matches, so confirming it by hand adds friction without protection. Marks the
    /// attempt as paired so that when the camera completes its wizard and drops the connection,
    /// the success/catch path saves the camera and reconnects with the new profile.
    private func autoAcceptPairing(_ challenge: PTPIPPairingChallenge) async -> Bool {
        acceptedPairingForCurrentAttempt = true
        connectionPhase = .pairing
        connectionMessage =
            challenge.pin.map { "Pairing with code \($0)…" }
            ?? "Pairing with your camera…"
        logConnection("auto-accept pairing challenge received")
        return true
    }

    private func confirmPairing(_ challenge: PTPIPPairingChallenge) async -> Bool {
        await withCheckedContinuation { continuation in
            pairingContinuation?.resume(returning: false)
            pairingContinuation = continuation
            pendingPairingChallenge = challenge
            connection = .pairing(pin: challenge.pin ?? "VERIFY")
            connectionPhase = .pairing
            if let pin = challenge.pin {
                connectionMessage = "Confirm code \(pin) on the camera, then tap Pair here."
            } else {
                connectionMessage = "Confirm the pairing request on the camera, then tap Pair here."
            }
            logConnection("pairing alert shown")
        }
    }

    private func finishPairing(accepted: Bool) {
        let continuation = pairingContinuation
        pairingContinuation = nil
        pendingPairingChallenge = nil
        acceptedPairingForCurrentAttempt = accepted
        connection = .scanning
        connectionMessage =
            accepted
            ? "Pairing accepted. Finishing setup…"
            : "Pairing cancelled."
        logConnection("pairing user response accepted=\(accepted)")
        if accepted {
            savePendingPairingCamera()
            transitionToSavedCameraNetworkCheck(
                message:
                    "Pairing saved. If the camera shows a prompt, tap Continue — we'll reconnect automatically."
            )
        }
        continuation?.resume(returning: accepted)
    }

    private func disconnectCameraSession(resetConnection: Bool) {
        let session = cameraSession
        clearCameraSessionState(resetConnection: resetConnection)
        // Fire-and-forget the network teardown, but keep a handle: the next connectToCamera awaits
        // it before opening a new command channel (one PTP-IP command channel per initiator).
        let previousTeardown = sessionTeardownTask
        sessionTeardownTask = Task {
            await previousTeardown?.value
            await session?.stopLiveView()
            // Graceful CloseSession (best-effort, bounded) before dropping sockets so the camera
            // releases its PTP slot rather than holding it until its own keepalive expires — the
            // reconnect-wedge root cause (see `NativeCameraSession.shutdown`).
            await session?.shutdown()
        }
    }

    /// Clears all in-memory session and live-view state. Performs no network I/O, so callers that
    /// are about to open a new session can clear synchronously and then await the previous
    /// session's socket teardown separately (preventing overlapping PTP-IP command channels).
    private func clearCameraSessionState(
        resetConnection: Bool, preserveMonitorSurface: Bool = false
    ) {
        // Invalidate any in-flight establishment attempt: it re-checks this generation before
        // publishing a session, so a handshake finishing after this clear can't resurrect state.
        connectionGeneration += 1
        establishmentTask?.cancel()
        establishmentTask = nil
        pairingContinuation?.resume(returning: false)
        pairingContinuation = nil
        pendingPairingChallenge = nil
        pendingPairingSaveCandidate = nil
        acceptedPairingForCurrentAttempt = false
        pendingPairedReconnectHost = nil
        pendingPairedReconnectSSID = nil
        lastPairedRejoinAttemptAt = nil
        pairedReconnectSawCameraLeave = false
        liveViewTask?.cancel()
        liveViewTask = nil
        keepAliveTask?.cancel()
        keepAliveTask = nil
        linkHealthUpdateTask?.cancel()
        linkHealthUpdateTask = nil
        propertyPollTask?.cancel()
        propertyPollTask = nil
        pendingWriteDrainTask?.cancel()
        pendingWriteDrainTask = nil
        // Media traffic must not outlive the session: an in-flight clip stream or thumbnail sweep
        // would keep hammering the old command channel through the shared transaction gate while
        // the next session tries to establish.
        cancelClipStream()
        mediaFetchTask?.cancel()
        mediaFetchTask = nil
        cancelThumbnailWork(resumingWaiters: true)
        resetLinkHealthMeasurements()
        eventDrainTask?.cancel()
        eventDrainTask = nil
        cameraSession = nil
        connectedIdentity = nil
        // Auto-reconnects keep the monitor shell up with the last frame frozen (RECOV state, same
        // as stall recovery) instead of dismissing and re-presenting the whole surface — on a
        // flapping link that teardown/rebuild churn reads as app-wide lag and instability.
        if !preserveMonitorSurface {
            liveFrameImage = nil
            isMonitorPresented = false
            activePanel = nil
            panelRevealed = false
        }
        isRecording = false
        resetPendingRecordCommand()
        lastAppliedStreamImageSize = nil
        lastDescriptorRefreshAt = nil
        lastStorageRefreshAt = nil
        resetCameraPropertyState()
        // Camera-specific option lists and operator locks must not carry into the next session — a
        // different body (or a fresh re-poll of the same one) advertises its own controls. Cleared
        // here at session teardown, NOT in resetCameraPropertyState, which also runs on every
        // live-view restart and must preserve these across a stall recovery.
        cameraScreenModes = []
        cameraFileTypeModes = []
        cameraControlOptions = [:]
        lockedControls = []
        if resetConnection {
            connection = .disconnected
            isDemoSession = false
            refreshSavedCameras()
            applyStartupDestination()
            connectionMessage = "Disconnected."
            refreshLinkHealth()
        }
    }

    private func startLiveView(session: NativeCameraSession) {
        liveViewTask?.cancel()
        resetCameraPropertyState()
        liveViewTask = Task {
            // Jittered exponential backoff (≈1s → cap 8s) so repeated stalls against a flaky AP don't
            // resync into a restart burst; the random spread de-correlates successive attempts.
            let backoff = ReconnectBackoff(
                baseSeconds: 1, maxSeconds: 8, multiplier: 2, jitterFraction: 0.3)
            // After this many quick back-to-back stalls, stop restarting the stream and re-establish
            // the whole session — the command channel is likely wedged, not just the stream.
            let maxStallRestarts = 3
            var stallAttempt = 0
            while !Task.isCancelled {
                let streamStart = Date()
                let outcome = await streamUntilStall(session: session)
                if Task.isCancelled { return }
                // A stream that ran healthily for a while before blipping resets the streak — only
                // rapid back-to-back stalls (each <30s of streaming) count toward escalation.
                let streamedHealthily = Date().timeIntervalSince(streamStart) > 30
                switch outcome {
                case .taskCancelled:
                    return
                case .neverStarted(let reason):
                    // First-frame failure — often a transient framing desync on the first
                    // GetLiveViewImageEx that leaves the command channel misaligned. Retrying on
                    // this session would read the same bad stream, so full-reconnect (new socket =
                    // clean read buffer) after a short backoff. The counter (reset on a good first
                    // frame) bounds it so a body that truly can't stream gives up.
                    consecutiveStartFailures += 1
                    if consecutiveStartFailures >= maxStallRestarts {
                        logConnection(
                            "live-view never started ×\(consecutiveStartFailures) host=\(session.identity.host) — giving up (\(reason))"
                        )
                        consecutiveStartFailures = 0
                        await session.stopLiveView()
                        isMonitorPresented = false
                        return
                    }
                    let wait = backoff.delaySeconds(
                        forAttempt: consecutiveStartFailures - 1, jitter: .random(in: 0...1))
                    logConnection(
                        "live-view never started ×\(consecutiveStartFailures) host=\(session.identity.host) → reconnect in \(formattedSeconds(wait)) (\(reason))"
                    )
                    connectionMessage = "Live view didn't start — reconnecting…"
                    liveFPS = "RECOV"
                    isStreamRecovering = true
                    connection = .connected
                    await session.stopLiveView()
                    try? await Task.sleep(for: .seconds(wait))
                    guard !Task.isCancelled else { return }
                    cameraHost = session.identity.host
                    connectToCamera(preservingMonitorSurface: true)
                    return
                case .stalled(let reason):
                    if streamedHealthily { stallAttempt = 0 }
                    if stallAttempt >= maxStallRestarts {
                        // The stream keeps dying right after each restart — escalate to a full
                        // reconnect off the saved profile rather than hammering a wedged session.
                        // connectToCamera tears this session down (cancelling this task); if the
                        // camera is truly gone it falls through to discovery on its own.
                        logConnection(
                            "stall-escalate host=\(session.identity.host) consecutive=\(stallAttempt) → full reconnect"
                        )
                        connectionMessage =
                            "Live view isn't recovering — reconnecting to the camera…"
                        cameraHost = session.identity.host
                        connectToCamera()
                        return
                    }
                    // Recover: back off, restart live view. Watchdog handles normal jitter; we
                    // only get here for a real stall (no good frame in the timeout window, or a
                    // run of unparsable frames, or a thrown error).
                    let wait = backoff.delaySeconds(
                        forAttempt: stallAttempt, jitter: .random(in: 0...1))
                    connectionMessage =
                        "Live view stalled (\(reason)). Restarting in \(formattedSeconds(wait))…"
                    liveFPS = "RECOV"
                    isStreamRecovering = true
                    connection = .connected
                    try? await Task.sleep(for: .seconds(wait))
                    guard !Task.isCancelled else { return }
                    stallAttempt += 1
                case .streaming:
                    // Clean exit without cancellation — treat as a stall and restart.
                    if streamedHealthily { stallAttempt = 0 }
                    stallAttempt += 1
                }
            }
        }
    }

    /// Keeps an idle command channel warm: a quiet TCP session is exactly what a Wi-Fi/hotspot NAT
    /// times out, surfacing as a drop on the next operation. While the feed isn't pulling frames,
    /// ping every 10s with a side-effect-free GetDeviceInfo (tuned TCP keepalive backs this up at
    /// the socket layer). Bound to the session: a stale session stops it.
    private func startKeepAlive(session: NativeCameraSession) {
        keepAliveTask?.cancel()
        keepAliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled, let self, self.cameraSession === session else { return }
                // Skip while the frame loop is already keeping the channel busy.
                if self.isMonitorPresented, !self.shouldPauseLiveFeed { continue }
                do {
                    try await session.sendKeepAlive()
                    self.recentKeepaliveFailures = max(0, self.recentKeepaliveFailures - 1)
                } catch {
                    self.recentKeepaliveFailures = min(3, self.recentKeepaliveFailures + 1)
                    logConnection(
                        "keepalive failed host=\(session.identity.host) \(error.localizedDescription)"
                    )
                }
            }
        }
    }

    private func startLinkHealthMonitoring() {
        linkHealthUpdateTask?.cancel()
        linkHealthUpdateTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.refreshLinkHealth()
                try? await Task.sleep(
                    for: (self.isMonitorPresented && self.measuredLiveViewFPS > 0)
                        ? .seconds(1) : .seconds(3))
            }
        }
    }

    func syncScreenWakePolicy() {
        let wantsAwake =
            !screenWakeSuppressedForBackground && preferences.keepScreenAwake
            && (isMonitorPresented || isMediaPlaybackActive)
        ScreenWakeController.apply(keepAwake: wantsAwake)
    }

    /// Mirrors the current `ProcessInfo` thermal state onto `thermalTier`, updating only on a real
    /// change so a poll doesn't needlessly invalidate observers. Drives graceful cosmetic
    /// load-shedding on the live loop (feed + scope refresh cadence).
    func refreshThermalTier() {
        let tier = ThermalTier(ProcessInfo.processInfo.thermalState)
        if tier != thermalTier {
            thermalTier = tier
            // A hotter/cooler phone (or later, an overheating camera) changes the size we should be
            // asking the camera to encode — restart the stream if that target moved.
            applyThermalStreamStepDownIfNeeded()
        }
    }

    // MARK: Live-feed visibility & thermal stream sizing (camera-heat mitigations)

    /// Full-screen panels that completely cover the live feed. Overlay pickers/assist popups leave
    /// the feed visible behind them, so they are deliberately excluded — only these hide it.
    private var activePanelHidesLiveFeed: Bool {
        activePanel?.coversFullScreen ?? false
    }

    /// Whether the live feed is currently not being shown to anyone — Command mode (DISP 3) or a
    /// full-screen panel cover. While true the streaming loop stops pulling frames AND tells the
    /// camera to `EndLiveView`, so the sensor stops encoding for a feed nobody sees (the biggest
    /// avoidable camera-heat source). It resumes on return.
    private var shouldPauseLiveFeed: Bool {
        displayMode == .command || activePanelHidesLiveFeed
    }

    /// The `LiveViewImageSize` byte to request right now: the operator's preset, capped smaller when
    /// the phone is thermally stressed, the camera reports an overheat warning, or a take is in
    /// progress. A smaller preview is less sensor-readout/encode work for the body to do while
    /// things are hot. Never enlarges beyond the operator's chosen preset.
    private var effectiveStreamImageSize: UInt8 {
        LiveViewLoadPolicy.effectiveImageSize(
            requested: preferences.streamPreset.liveViewImageSize,
            isRecording: isRecording,
            thermalTier: thermalTier,
            cameraOverheating: cameraPropertySnapshot.warningStatus.isOverheating)
    }

    /// Restarts live view when `effectiveStreamImageSize` has moved since the last configure — e.g.
    /// the phone crossed a thermal tier. No-op when the size is unchanged or the feed isn't up, so a
    /// stable thermal state never thrashes the encoder.
    private func applyThermalStreamStepDownIfNeeded() {
        guard cameraSession != nil, isMonitorPresented, !shouldPauseLiveFeed else { return }
        guard let applied = lastAppliedStreamImageSize else { return }
        if effectiveStreamImageSize != applied {
            restartLiveViewForQualityChange()
        }
    }

    private func resetLinkHealthMeasurements() {
        measuredLiveViewFPS = 0
        lastGoodFrameAt = nil
        consecutiveBadLiveFrames = 0
        recentKeepaliveFailures = 0
        isStreamRecovering = false
        linkHealth = 0
        linkHealthDetail = "Not connected"
        signalBarsFilter = LinkSignalBars()
        liveSignalBars = 0
    }

    private func refreshLinkHealth() {
        let snapshot = CameraLinkHealthScorer.score(currentLinkHealthInputs())
        linkHealth = snapshot.linkHealthScore
        linkHealthDetail = snapshot.detailCaption
        // USB-C: frame timing isn't radio quality — show full bars whenever the link is alive.
        let bars =
            cameraSession?.transportKind == .usb
            ? (linkHealth > 0 ? 4 : 0)
            : signalBarsFilter.update(score: linkHealth)
        if bars != liveSignalBars { liveSignalBars = bars }
    }

    private func currentLinkHealthInputs() -> CameraLinkHealthInputs {
        if isDemoSession { return CameraLinkHealthInputs(phase: .demo) }
        let phase: CameraLinkPhase
        switch connection {
        case .disconnected: phase = .disconnected
        case .scanning, .pairing, .reconnecting, .preparingLiveView: phase = .connecting
        case .connected:
            if isMonitorPresented, measuredLiveViewFPS > 0 {
                phase = isStreamRecovering ? .recovering : .streaming
            } else {
                phase = .connectedIdle
            }
        }
        let secondsSinceGood = lastGoodFrameAt.map { Date().timeIntervalSince($0) }
        let liveFPSValue =
            (isMonitorPresented && measuredLiveViewFPS > 0) ? measuredLiveViewFPS : nil
        return CameraLinkHealthInputs(
            phase: phase,
            ptpRoundTripMilliseconds: cameraSession?.readLastCommandRoundTripMilliseconds(),
            liveViewFPS: liveFPSValue,
            targetLiveViewFPS: Double(cameraPropertySnapshot.fps ?? 30),
            secondsSinceLastGoodFrame: secondsSinceGood,
            consecutiveBadFrames: consecutiveBadLiveFrames,
            recentCommandFailures: recentKeepaliveFailures,
            isRecoveringStream: isStreamRecovering)
    }

    /// Continuously drains the camera's PTP-IP event channel (record start/stop `0xC10A`/`0xC108`,
    /// DevicePropChanged `0x4006`, store-full `0x400A`, …): if nothing reads it, the camera's send
    /// buffer backs up and can stall the whole session deep into a long take. Record events update
    /// the UI when the operator starts/stops on the body; an interruption also triggers an
    /// immediate warning-status read. Idle `.timeout`s are normal on a sparse channel; any other
    /// error means the connection is gone — the loop ends and the live-view watchdog drives
    /// reconnection. Bound to the session.
    private func startEventDraining(session: NativeCameraSession) {
        eventDrainTask?.cancel()
        eventDrainTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.cameraSession === session else { return }
                do {
                    let event = try await session.nextEvent()
                    if event.eventCode == .movieRecordInterrupted {
                        // An interruption is authoritative even while an optimistic app record
                        // command is in its brief readback-suppression window.
                        self.applyCameraRecordState(isRecording: false, force: true)
                        let error =
                            event.recordingInterruptionErrorCode.map {
                                String(format: "0x%08X", $0)
                            } ?? "unknown"
                        self.connectionMessage =
                            "Recording was interrupted by the camera (error \(error))."
                        await self.refreshWarningStatus(session: session)
                    } else if let recordState = event.inferredRecordState {
                        self.applyCameraRecordState(isRecording: recordState == .recording)
                    }
                } catch let error as NativeCameraSessionError {
                    if case .timeout = error { continue }
                    return
                } catch {
                    return
                }
            }
        }
    }

    /// Releases the live-view pipeline, keepalive, event drain, and discovery when the app is
    /// backgrounded. A field monitor left running with the screen off otherwise keeps decoding ~30
    /// JPEG frames/sec, running the Core Image graph on the GPU, and holding the Wi-Fi radio — the
    /// worst battery/thermal profile on set, and enough sustained work for iOS to jetsam-kill the
    /// app so it vanishes mid-shoot. The session object is kept so `enterForeground()` can resume.
    func enterBackground() {
        AppDiagnostics.shared.record(.enteredBackground)
        screenWakeSuppressedForBackground = true
        syncScreenWakePolicy()
        // Give the volume buttons (and the phone camera) back to the system while backgrounded.
        bluetoothShutter.stop()
        discoveryLoopTask?.cancel()
        discoveryLoopTask = nil
        guard let session = cameraSession else { return }
        liveViewTask?.cancel()
        liveViewTask = nil
        keepAliveTask?.cancel()
        keepAliveTask = nil
        eventDrainTask?.cancel()
        eventDrainTask = nil
        linkHealthUpdateTask?.cancel()
        linkHealthUpdateTask = nil
        // Media PTP traffic (clip download, listing, thumbnail sweep) must pause with the screen
        // off for the same battery/thermal reasons as live view. Clip-stream partial bytes are
        // kept (the next open resumes); an interrupted listing re-schedules on foreground; the
        // thumbnail queue is preserved so the worker picks it back up.
        cancelClipStream()
        if mediaFetchTask != nil {
            mediaFetchTask?.cancel()
            mediaFetchTask = nil
            mediaFetchInterruptedByBackground = true
        }
        cancelThumbnailWork(resumingWaiters: false)
        // Best-effort: also tell the camera to drop live view (saves its battery/thermal). Tracked so
        // a quick foreground return waits for it before restarting; iOS may suspend us before it
        // completes, which is harmless.
        backgroundStopTask = Task { await session.stopLiveView() }
    }

    /// Restores activity when the app returns to the foreground: re-warms the command channel and
    /// event drain, resumes live view if it was up, or restarts discovery on the connect screen. If
    /// the connection died while suspended, the live-view task's own backoff/reconnect recovers.
    func enterForeground() {
        AppDiagnostics.shared.record(.enteredForeground)
        screenWakeSuppressedForBackground = false
        syncScreenWakePolicy()
        guard let session = cameraSession else {
            startDiscoveryLoop(resetResults: false)
            return
        }
        startKeepAlive(session: session)
        startEventDraining(session: session)
        startLinkHealthMonitoring()
        // Resume media work paused by enterBackground.
        if mediaFetchInterruptedByBackground {
            mediaFetchInterruptedByBackground = false
            scheduleFetchClipsFromCamera()
        }
        startThumbnailWorkerIfNeeded()
        if isMonitorPresented {
            // Let the background stopLiveView finish before restarting, so the stop can't land after
            // the restart and tear the resumed stream back down.
            let pendingStop = backgroundStopTask
            Task {
                await pendingStop?.value
                guard cameraSession === session else { return }
                startLiveView(session: session)
            }
        }
    }

    /// Gives system volume behavior back as soon as another surface covers the app. A matching
    /// `didBecomeActive` reconciliation restarts the opt-in after Control Center, prompts, or an
    /// ordinary foreground transition.
    func enterInactive() {
        bluetoothShutter.stop()
    }

    /// Upper bound on a single live-view frame fetch. Generous enough that normal jitter (frames
    /// arrive in ~16-40ms) never trips it, so it only fires on a genuine hang — a camera that
    /// accepted the connection but stopped delivering bytes. Aligned with the watchdog's 6s stall
    /// timeout. On breach the fetch's transaction closes the command socket and the streaming loop
    /// recovers, instead of the fetch hanging forever and jamming the whole command channel.
    private static let liveViewFrameDeadline: Duration = .seconds(6)

    /// The FIRST frame after `StartLiveView` gets more headroom than steady-state frames: the sensor
    /// is spinning up the stream and the initial JPEG is the largest, so a legitimately-slow-but-alive
    /// first frame must not be falsely kicked into a reconnect. [verify-on-HW: measure the real ZR's
    /// first-frame latency and tighten if it lands well under this.]
    private static let firstLiveViewFrameDeadline: Duration = .seconds(10)

    /// One bounded frame fetch, wrapped so every streaming call site uses a consistent deadline.
    private func liveFrameTask(
        _ session: NativeCameraSession,
        deadline: Duration = liveViewFrameDeadline
    ) -> Task<PTPLiveViewFrame, Error> {
        Task { try await session.liveViewFrame(deadline: deadline) }
    }

    /// Runs one live-view streaming attempt until the watchdog declares a stall or the task is
    /// cancelled. Returns the reason streaming stopped so the caller can decide to restart.
    private func streamUntilStall(session: NativeCameraSession) async -> StreamOutcome {
        var deliveredFirstFrame = false
        var frameCounter = 0
        var frameRate = FrameRateSampler()
        var watchdog = LiveViewWatchdog()
        do {
            let requestedSize = effectiveStreamImageSize
            await session.configureLiveView(
                size: requestedSize,
                compression: preferences.qualityBias.liveViewImageCompression)
            lastAppliedStreamImageSize = requestedSize
            try await session.startLiveView()
            var nextFrameTask = liveFrameTask(session, deadline: Self.firstLiveViewFrameDeadline)
            // Every exit (stall return, thrown error, cancellation) must cancel the in-flight
            // fetch: an unstructured task is not auto-cancelled with its parent, and an orphaned
            // fetch keeps the transaction gate held or queued — starving the restarted stream's
            // first commands (operator-visible as "Stop does nothing" during recovery).
            defer { nextFrameTask.cancel() }
            let firstFrame = try await nextFrameTask.value
            guard !Task.isCancelled, cameraSession === session else { return .taskCancelled }
            // Decode off the main actor (FrameDecoder forces the JPEG decode via
            // preparingForDisplay) so the main thread only composites an already-decoded frame.
            let firstImage = await displayReadyLiveFrame(
                from: await frameDecoder.decode(firstFrame.jpeg))
            guard !Task.isCancelled, cameraSession === session else { return .taskCancelled }
            guard let firstImage else {
                throw NativeCameraSessionError.connectionFailed(
                    "Live view returned an unreadable first frame."
                )
            }
            liveFrameImage = firstImage
            liveViewFocus = firstFrame.focus
            applyLiveViewHeaderState(firstFrame)
            isMonitorPresented = true
            AppDiagnostics.shared.record(.liveViewStarted)
            presentLiveViewGuideIfNeeded()
            dismissConnectionProgress()
            deliveredFirstFrame = true
            consecutiveStartFailures = 0
            isStreamRecovering = false
            watchdog.recordGoodFrame(at: Date())
            lastGoodFrameAt = Date()
            consecutiveBadLiveFrames = 0
            frameRate.recordFrame(at: CACurrentMediaTime())
            measuredLiveViewFPS = frameRate.displayFPS
            liveTimecode = firstFrame.timecode
            liveFPS = frameRate.formatted
            cameraState = cameraState.updating(phoneBatteryPercent: currentPhoneBatteryPercent)
            connectionMessage = "Live view streaming from \(session.identity.displayName)."
            connection = .connected
            var pausedForCommand = false
            var liveViewSuspended = false
            nextFrameTask = liveFrameTask(session)
            while !Task.isCancelled {
                if shouldPauseLiveFeed {
                    // Feed hidden (Command mode / DISP 3, or a full-screen cover): stop pulling
                    // frames AND end live view on the camera — sensor readout + JPEG encode is the
                    // dominant camera-heat source. Property polls and queued writes keep running
                    // on this idle cadence (cheap, separate transactions).
                    pausedForCommand = true
                    nextFrameTask.cancel()
                    if !liveViewSuspended {
                        liveViewSuspended = true
                        await session.stopLiveView()
                        lastAppliedStreamImageSize = nil
                    }
                    // Tell the watch so it shows the paused placeholder over the last frame instead
                    // of a stalled preview.
                    publishWatchState()
                    await runCommandModeSafePoint(session: session)
                    try? await Task.sleep(for: .milliseconds(250))
                    continue
                }
                if pausedForCommand {
                    pausedForCommand = false
                    if liveViewSuspended {
                        // Feed came back — re-enter live view at the size the current thermal state
                        // asks for. A start failure returns .stalled so the outer loop's backoff
                        // rebuilds the stream cleanly.
                        liveViewSuspended = false
                        let requestedSize = effectiveStreamImageSize
                        await session.configureLiveView(
                            size: requestedSize,
                            compression: preferences.qualityBias.liveViewImageCompression)
                        lastAppliedStreamImageSize = requestedSize
                        try await session.startLiveView()
                    }
                    watchdog.recordGoodFrame(at: Date())
                    lastGoodFrameAt = Date()
                    consecutiveBadLiveFrames = 0
                    frameRate = FrameRateSampler()
                    lastFrameDisplayTime = 0
                    lastFocusDisplayTime = 0
                    lastLevelUpdateTime = 0
                    lastScopeSampleTime = 0
                    nextFrameTask = liveFrameTask(session)
                }
                let frame = try await nextFrameTask.value
                guard !Task.isCancelled, cameraSession === session else { return .taskCancelled }
                // Bound in-flight frames to one JPEG + one decoded bitmap: finish decode and
                // display before pulling the next camera frame; scope sampling overlaps the next
                // fetch. Scopes must meter the clean frame, never the assist-composited bake
                // (`cleanFrame` is a second reference to a bitmap the render memo retains anyway).
                let cleanFrame = await frameDecoder.decode(frame.jpeg)
                let decoded = await displayReadyLiveFrame(from: cleanFrame)
                guard !Task.isCancelled, cameraSession === session else { return .taskCancelled }
                if let image = decoded, let cleanFrame {
                    frameCounter += 1
                    frameRate.recordFrame(at: CACurrentMediaTime())
                    watchdog.recordGoodFrame(at: Date())
                    lastGoodFrameAt = Date()
                    consecutiveBadLiveFrames = 0
                    measuredLiveViewFPS = frameRate.displayFPS
                    publishLiveFrameDisplay(image: image, focus: frame.focus)
                    applyLiveViewHeaderState(frame)
                    // The CPU path returns a distinct display-baked image. Metal returns the clean
                    // frame because its full-size bake stays GPU-side; give the relay the active
                    // effects in that case so it grades only its small, link-paced thumbnail.
                    let watchEffects = image === cleanFrame ? liveImageEffects : nil
                    watchRelay.ingestFrame(
                        image: image,
                        applying: watchEffects,
                        timecode: frame.timecode,
                        isRecording: frame.isRecording)
                    // Overlap the next camera fetch with scope work — one JPEG in flight, not two.
                    nextFrameTask = liveFrameTask(session)
                    // One shared scope sample per throttle tick feeds histogram, waveform, parade,
                    // and traffic lights (see `ScopeAssistSampling`); the portrait scopes stack
                    // renders exactly these tools, so this set already covers it.
                    let visibleScopes = preferences.visibleAssistTools(for: .liveView)
                    let shouldSampleScopes = ScopeAssistSampling.shouldSample(
                        visible: visibleScopes)
                    if shouldSampleScopes {
                        let now = CFAbsoluteTimeGetCurrent()
                        let scopeInterval = ScopeAssistSampling.thermalScopeInterval(
                            activeScopeCount: ScopeAssistSampling.activeScopeCount(
                                visible: visibleScopes),
                            thermalTier: thermalTier)
                        if !scopeSampleInFlight, now - lastScopeSampleTime >= scopeInterval {
                            lastScopeSampleTime = now
                            // Meter the clean frame: false colour / LUT / zebra / peaking are
                            // display-only assists and must not shift histogram, waveform,
                            // parade, or traffic-light readings.
                            if true {
                                scopeSampleInFlight = true
                                let scopeImage = cleanFrame
                                let visible = visibleScopes
                                let tier = thermalTier
                                Task {
                                    // `defer` so an early exit can never leave the in-flight gate
                                    // stuck true (which would silently stop all scope sampling).
                                    defer { scopeSampleInFlight = false }
                                    let samples = await sampleLiveScopeAssist(
                                        image: scopeImage, visibleScopes: visible,
                                        thermalTier: tier)
                                    // Session torn down while sampling — drop the stale publish.
                                    guard cameraSession === session, !Task.isCancelled else {
                                        return
                                    }
                                    await publishScopeAssist(samples: samples)
                                }
                            } else if scopeAssist != .empty {
                                clearScopeAssist()
                            }
                        }
                    } else if scopeAssist != .empty {
                        clearScopeAssist()
                    }
                    if frame.timecode != liveTimecode { liveTimecode = frame.timecode }
                    let fpsLabel = frameRate.formatted
                    if fpsLabel != liveFPS { liveFPS = fpsLabel }
                    await runLiveViewControlSafePoint(
                        session: session,
                        frameCounter: frameCounter
                    )
                } else {
                    // Corrupt JPEG — count it so a streak forces a restart instead of freezing
                    // silently with the last good frame on screen.
                    watchdog.recordBadFrame()
                    consecutiveBadLiveFrames = watchdog.consecutiveBadFrames
                    nextFrameTask = liveFrameTask(session)
                }
                watchdog.check(at: Date())
                lastGoodFrameAt = watchdog.lastGoodFrameAt
                if watchdog.status == .stalled {
                    return .stalled(reason: "no good frame")
                }
            }
            return .taskCancelled
        } catch {
            guard !Task.isCancelled else { return .taskCancelled }
            if !deliveredFirstFrame {
                AppDiagnostics.shared.record(.liveViewFailed)
                let reason =
                    (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                connectionMessage =
                    "Connected, but live view is not streaming: \(reason)"
                liveFPS = "LINK"
                isStreamRecovering = true
                connection = .connected
                return .neverStarted(reason: reason)
            }
            // A thrown error mid-stream is recoverable: report it and let the outer loop restart.
            let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return .stalled(reason: reason)
        }
    }

    /// Outcome of one streaming attempt, used by the restart loop.
    private enum StreamOutcome {
        case taskCancelled
        case neverStarted(reason: String)
        case streaming
        case stalled(reason: String)
    }

    private func formattedSeconds(_ seconds: Double) -> String {
        seconds >= 1 ? "\(Int(seconds))s" : "\(Int(seconds * 1000))ms"
    }

    private func runLiveViewControlSafePoint(
        session: NativeCameraSession,
        frameCounter: Int
    ) async {
        await runControlSafePoint(
            session: session, pollEveryCall: false, frameCounter: frameCounter)
    }

    /// Services queued writes and property polls while live view is paused in command mode.
    private func runCommandModeSafePoint(session: NativeCameraSession) async {
        await runControlSafePoint(session: session, pollEveryCall: true)
    }

    /// Shared safe point for live-view frames and command-mode maintenance.
    private func runControlSafePoint(
        session: NativeCameraSession,
        pollEveryCall: Bool,
        frameCounter: Int = 0
    ) async {
        if let step = focusResetStep {
            await runFocusResetStep(step, session: session)
            return
        }
        // AF-point taps are interactive — service them first so focus follows the finger promptly.
        if let point = pendingFocusPoint {
            pendingFocusPoint = nil
            do {
                try await session.changeAfArea(x: point.x, y: point.y)
            } catch {
                connectionMessage =
                    "Camera rejected the focus point: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
            }
            return
        }
        // Record start/stop is interactive too — service it before property polls. The button was
        // flipped optimistically; revert it if the camera rejects the op.
        if let start = pendingRecordStart {
            pendingRecordStart = nil
            pendingRecordToggle = false
            appRecordCommandAt = Date()
            do {
                if start {
                    try await session.startRecording()
                } else {
                    try await session.stopRecording()
                }
                // `isRecording` was flipped optimistically before this safe point. Only after the
                // camera accepts the command do we restart the preview at its recording-aware size.
                applyThermalStreamStepDownIfNeeded()
            } catch {
                isRecording = !start
                cameraState = cameraState.updating(recordState: isRecording ? .recording : .standby)
                connectionMessage =
                    "Record \(start ? "start" : "stop") failed: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
            }
            return
        }
        if await performNextPendingCameraWrite(session: session) {
            return
        }
        guard pollEveryCall || frameCounter.isMultiple(of: 8) else { return }
        if isRecording {
            let now = Date()
            guard
                CameraMonitorPollPolicy.isDue(
                    lastRefreshAt: lastRecordingPropertyPollAt,
                    now: now,
                    interval: CameraMonitorPollPolicy.recordingPropertyPollInterval)
            else { return }
            lastRecordingPropertyPollAt = now
        }
        // Don't block the frame loop on a property read — overlapping decode with the in-flight
        // fetch wins more wall-clock than waiting here. Single-flight: stacked poll tasks would
        // queue behind the transaction gate and delay frame fetches (feed jitter); a tick landing
        // while one is in flight is skipped, and the round-robin index resumes where it left off.
        guard propertyPollTask == nil else { return }
        propertyPollTask = Task { [weak self] in
            defer { self?.propertyPollTask = nil }
            guard let self, self.cameraSession === session, !Task.isCancelled else { return }
            await self.pollNextCameraProperty(session: session)
        }
    }

    /// One shared scope sample for every histogram / waveform (CPU) / parade (CPU) / TL assist.
    /// `image` must be the clean decoded camera frame — never the assist-baked display frame.
    private func sampleLiveScopeAssist(
        image: UIImage, visibleScopes: Set<MonitorAssistTool>, thermalTier: ThermalTier
    ) async -> ScopeSamples {
        // ONE sampler for every surface — the same 200px/stride-2 CPU pipeline playback uses;
        // binning the full-resolution frame reads subtly differently from the shared downsampled
        // tap. [1:1 live/playback invariant]
        let stride = ScopeAssistSampling.pointStride
        let includePoints = ScopeAssistSampling.needsPointSamples(visible: visibleScopes)
        return await scopeSampler.sample(
            from: image, maxWidth: 200, stride: stride, includePoints: includePoints)
    }

    /// Bakes active monitor assists into a decoded frame off the main actor so the feed view only
    /// swaps a finished bitmap. Display-only: scopes must keep sampling the clean input frame.
    private func liveFrameRenderer() -> LiveFrameRenderer {
        if let frameRendererStorage { return frameRendererStorage }
        let renderer = LiveFrameRenderer(fileStore: lutFileStore)
        frameRendererStorage = renderer
        return renderer
    }

    private func displayReadyLiveFrame(from decoded: UIImage?) async -> UIImage? {
        guard let decoded else { return nil }
        let effects = liveImageEffects
        // Metal feed bakes assists off-main in `MetalFeedFrameBaker`; identity needs no bake.
        // Either way the renderer actor is skipped — with a single eviction hop on the transition
        // out of CPU baking, so the memo's retained bitmaps (input + bake) are dropped promptly
        // instead of paying a no-op actor round-trip every frame.
        if FeedRenderMode.metalFeedEnabled || effects.isIdentity {
            if rendererHoldsBakedFrame {
                rendererHoldsBakedFrame = false
                await liveFrameRenderer().evictCachedRender()
            }
            return decoded
        }
        rendererHoldsBakedFrame = true
        // Evict + render in one actor hop (was two round-trips per displayed frame).
        return await liveFrameRenderer().renderReplacingCache(decoded, effects: effects)
    }

    /// Publishes decoded frames to SwiftUI every camera frame by default — the feed must track the
    /// camera's delivery rate exactly (matching the FPS counter) to read as smooth. Only gates the
    /// publish rate under genuine thermal pressure (`.serious`/`.critical`) as a bounded degraded
    /// mode. `lastFrameDisplayTime` resets to 0 on pause/restart, so the first frame after any
    /// pause always publishes.
    private func publishLiveFrameDisplay(image: UIImage, focus: PTPLiveViewFocusInfo?) {
        let now = CFAbsoluteTimeGetCurrent()
        if !thermalTier.isSheddingLoad
            || now - lastFrameDisplayTime
                >= thermalTier.sheddingInterval(base: Self.liveFrameDisplayMinInterval)
        {
            lastFrameDisplayTime = now
            if liveFrameImage !== image {
                liveFrameImage = image
            }
        }
        if now - lastFocusDisplayTime >= Self.liveFocusDisplayMinInterval {
            lastFocusDisplayTime = now
            if liveViewFocus != focus { liveViewFocus = focus }
        }
    }

    private func focusResetStepAfterCancel(_ context: FocusResetContext) -> FocusResetStep {
        if context.suspendSubjectDetection {
            return .suspendSubjectDetection(context)
        }
        return focusResetStepAfterSuspend(context)
    }

    private func focusResetStepAfterSuspend(_ context: FocusResetContext) -> FocusResetStep {
        if context.demoteSubjectArea {
            return .demoteSubjectArea(context)
        }
        return .settleBeforeRecenter(context: context, framesElapsed: 0)
    }

    private func currentMovieFocusMode() -> String? {
        cameraPropertySnapshot.focusMode ?? cameraValue(for: .focus)
    }

    private func focusResetStepAfterConfirm(_ context: FocusResetContext) -> FocusResetStep? {
        let focusMode = currentMovieFocusMode()
        if FocusResetRestorePolicy.shouldRestoreFocusArea(
            demoted: context.demoteSubjectArea,
            currentFocusArea: focusArea,
            savedFocusArea: context.savedFocusArea,
            focusMode: focusMode
        ) {
            return .restoreFocusArea(context: context)
        }
        if FocusResetRestorePolicy.shouldRestoreSubjectDetection(
            suspended: context.suspendSubjectDetection,
            currentFocusSubject: focusSubject,
            savedFocusSubject: context.savedFocusSubject,
            focusMode: focusMode
        ) {
            return .restoreSubjectDetection(context: context)
        }
        return nil
    }

    private func logFocusResetComplete(
        context: FocusResetContext,
        restoredArea: Bool,
        restoredSubject: Bool
    ) {
        let headerTracking = FocusResetReleasePolicy.isTrackingIndicatedOnHeader(liveViewFocus)
        var restoreParts: [String] = []
        if restoredArea {
            restoreParts.append("area \(context.savedFocusArea)")
        }
        if restoredSubject {
            restoreParts.append("subject \(context.savedFocusSubject)")
        }
        let restoreSummary =
            restoreParts.isEmpty
            ? "settings unchanged"
            : "restored \(restoreParts.joined(separator: ", "))"
        logConnection(
            headerTracking
                ? "focus reset: complete — header still shows tracking "
                    + "(\(focusResetHeaderSummary(liveViewFocus))), \(restoreSummary)"
                : "focus reset: complete — tracking cleared on header "
                    + "(\(focusResetHeaderSummary(liveViewFocus))), \(restoreSummary)"
        )
    }

    private func focusResetHeaderSummary(_ focus: PTPLiveViewFocusInfo?) -> String {
        guard let focus else { return "header=nil" }
        return "trackingAF=\(focus.trackingAFActive), latched=\(focus.isSubjectTrackingLatched), "
            + "subjectActive=\(focus.subjectDetectionActive)"
    }

    private func runFocusResetStep(_ step: FocusResetStep, session: NativeCameraSession) async {
        switch step {
        case .endTracking(let context):
            // EndTracking (0x9425) must run while TargetTracking/Subject AF-area
            // mode is still active.
            do {
                try await session.endTracking()
                logConnection("focus reset: EndTracking PTP OK")
            } catch {
                connectionMessage =
                    "Camera rejected end-tracking: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
                focusResetStep = nil
                return
            }
            try? await session.waitUntilDeviceReady()
            focusResetStep = .afDriveCancel(context)

        case .afDriveCancel(let context):
            if (try? await session.afDriveCancel()) != nil {
                logConnection("focus reset: AfDriveCancel PTP OK")
            }
            try? await session.waitUntilDeviceReady()
            focusResetStep = focusResetStepAfterCancel(context)

        case .suspendSubjectDetection(let context):
            if let write = PTPCameraPropertyWrite.request(control: .focusSubject, label: "Off") {
                do {
                    try await session.writeCameraProperty(write)
                    focusSubject = "Off"
                    logConnection(
                        "focus reset: MovieAFSubjectDetection → Off PTP OK "
                            + "(saved \(context.savedFocusSubject))"
                    )
                } catch {
                    connectionMessage =
                        "Camera rejected subject-detection suspend: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
                }
            }
            try? await session.waitUntilDeviceReady()
            focusResetStep = focusResetStepAfterSuspend(context)

        case .demoteSubjectArea(let context):
            if let write = PTPCameraPropertyWrite.request(control: .focusArea, label: "Single") {
                do {
                    try await session.writeCameraProperty(write)
                    focusArea = "Single"
                    logConnection(
                        "focus reset: AF area Subject → Single PTP OK "
                            + "(saved \(context.savedFocusArea))"
                    )
                } catch {
                    connectionMessage =
                        "Camera rejected AF-area demotion: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
                }
            }
            try? await session.waitUntilDeviceReady()
            focusResetStep = .settleBeforeRecenter(context: context, framesElapsed: 0)

        case .settleBeforeRecenter(let context, let framesElapsed):
            let elapsed = framesElapsed + 1
            let headerTracking = FocusResetReleasePolicy.isTrackingIndicatedOnHeader(liveViewFocus)
            if FocusResetSettlePolicy.shouldRecenter(
                framesSinceRelease: elapsed,
                isTrackingLatched: liveViewFocus?.isSubjectTrackingLatched ?? false,
                trackingAFActive: liveViewFocus?.trackingAFActive ?? false
            ) {
                if headerTracking {
                    logConnection(
                        "focus reset: header still tracking after \(elapsed) frames "
                            + "(\(focusResetHeaderSummary(liveViewFocus))) — recentering anyway"
                    )
                } else {
                    logConnection(
                        "focus reset: header tracking cleared after \(elapsed) frames "
                            + "(\(focusResetHeaderSummary(liveViewFocus)))"
                    )
                }
                focusResetStep = .recenter(context: context)
            } else {
                focusResetStep = .settleBeforeRecenter(context: context, framesElapsed: elapsed)
            }

        case .recenter(let context):
            do {
                try await session.changeAfArea(x: context.recenterX, y: context.recenterY)
                logConnection(
                    "focus reset: ChangeAfArea → \(context.recenterX),\(context.recenterY) PTP OK "
                        + "(\(focusResetHeaderSummary(liveViewFocus)))"
                )
            } catch {
                connectionMessage =
                    "Camera rejected the focus point: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
                focusResetStep = nil
                return
            }
            try? await session.waitUntilDeviceReady()
            focusResetStep = .confirmTrackingReleased(context: context)

        case .confirmTrackingReleased(let context):
            // Recentre can re-engage tracking on ZR hardware — repeat EndTracking after ChangeAfArea.
            if (try? await session.endTracking()) != nil {
                logConnection("focus reset: post-recenter EndTracking PTP OK")
            }
            if (try? await session.afDriveCancel()) != nil {
                logConnection("focus reset: post-recenter AfDriveCancel PTP OK")
            }
            try? await session.waitUntilDeviceReady()
            if let nextStep = focusResetStepAfterConfirm(context) {
                focusResetStep = nextStep
            } else {
                logFocusResetComplete(context: context, restoredArea: false, restoredSubject: false)
                focusResetStep = nil
            }

        case .restoreFocusArea(let context):
            if let write = PTPCameraPropertyWrite.request(
                control: .focusArea, label: context.savedFocusArea)
            {
                do {
                    try await session.writeCameraProperty(write)
                    focusArea = context.savedFocusArea
                    logConnection(
                        "focus reset: restored area \(context.savedFocusArea) PTP OK"
                    )
                } catch {
                    connectionMessage =
                        "Camera rejected AF-area restore: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
                }
            }
            try? await session.waitUntilDeviceReady()
            if FocusResetRestorePolicy.shouldRestoreSubjectDetection(
                suspended: context.suspendSubjectDetection,
                currentFocusSubject: focusSubject,
                savedFocusSubject: context.savedFocusSubject,
                focusMode: currentMovieFocusMode()
            ) {
                focusResetStep = .restoreSubjectDetection(context: context)
            } else {
                logFocusResetComplete(
                    context: context,
                    restoredArea: focusArea == context.savedFocusArea
                        && context.savedFocusArea != FocusResetRestorePolicy.interimFocusArea,
                    restoredSubject: false
                )
                focusResetStep = nil
            }

        case .restoreSubjectDetection(let context):
            if let write = PTPCameraPropertyWrite.request(
                control: .focusSubject, label: context.savedFocusSubject)
            {
                do {
                    try await session.writeCameraProperty(write)
                    focusSubject = context.savedFocusSubject
                    logConnection(
                        "focus reset: restored subject \(context.savedFocusSubject) PTP OK"
                    )
                } catch {
                    connectionMessage =
                        "Camera rejected subject-detection restore: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
                }
            }
            try? await session.waitUntilDeviceReady()
            logFocusResetComplete(
                context: context,
                restoredArea: context.demoteSubjectArea
                    && context.savedFocusArea != FocusResetRestorePolicy.interimFocusArea
                    && focusArea == context.savedFocusArea,
                restoredSubject: focusSubject == context.savedFocusSubject
            )
            focusResetStep = nil
        }
    }

    /// Applies the per-frame state the camera reports in the LiveViewObject header — its own
    /// virtual-horizon angles, sound-level indicator, and record state — making the camera the
    /// source of truth for each (no property polling, no extra traffic; all decoded from the
    /// header the app already reads).
    private func applyLiveViewHeaderState(_ frame: PTPLiveViewFrame) {
        if levelAssistActive {
            let now = CFAbsoluteTimeGetCurrent()
            if now - lastLevelUpdateTime >= Self.levelAngleMinInterval, let level = frame.level {
                lastLevelUpdateTime = now
                // Signed about level (−180…180) for the horizon, lightly low-passed to settle sensor jitter.
                let roll = PTPLevelAngles.signedDegrees(level.roll)
                let pitch = PTPLevelAngles.signedDegrees(level.pitch)
                cameraLevelRoll = (cameraLevelRoll ?? roll) * 0.7 + roll * 0.3
                cameraLevelPitch = (cameraLevelPitch ?? pitch) * 0.7 + pitch * 0.3
            }
        }
        // Sound indicator (bytes 824–827) → the audio-levels panel. The camera applies its own
        // meter ballistics and peak hold, so segments feed the panel directly.
        if preferences.visibleAssistTools(for: .liveView).contains(.audioMeters),
            let sound = frame.sound
        {
            let levels = AudioMeterLevels(cameraIndicator: sound)
            if liveAudioLevels != levels { liveAudioLevels = levels }
        }
        // Record state (header byte 828). Suppress the override while a queued app command is in
        // flight or briefly after one was sent so the optimistic flip isn't undone before the safe
        // point runs (and while the body catches up).
        applyCameraRecordState(isRecording: frame.isRecording)
    }

    /// Applies camera-authoritative record state from the live-view header or async PTP events.
    private func applyCameraRecordState(isRecording recording: Bool, force: Bool = false) {
        guard force || !shouldSuppressCameraRecordStateSync() else { return }
        guard isRecording != recording else { return }
        isRecording = recording
        cameraState = cameraState.updating(recordState: recording ? .recording : .standby)
        publishWatchState()
        applyThermalStreamStepDownIfNeeded()
    }

    /// Whether live-view header / event readback should defer to an in-flight app record command.
    private func shouldSuppressCameraRecordStateSync() -> Bool {
        if pendingRecordToggle || pendingRecordStart != nil { return true }
        if let sentAt = appRecordCommandAt, Date().timeIntervalSince(sentAt) < 1.5 { return true }
        return false
    }

    private func resetPendingRecordCommand() {
        pendingRecordToggle = false
        pendingRecordStart = nil
        appRecordCommandAt = nil
    }

    /// Drains queued property writes now when live view isn't running (no safe point will come).
    /// Single-flight and bound to the session: rapid picker taps extend the one running drain
    /// instead of stacking tasks on the transaction gate, and a drain never outlives its session.
    private func drainPendingWritesIfIdle() {
        guard !isMonitorPresented, let session = cameraSession else { return }
        guard pendingWriteDrainTask == nil else { return }
        pendingWriteDrainTask = Task { [weak self] in
            defer { self?.pendingWriteDrainTask = nil }
            while !Task.isCancelled {
                guard let self, self.cameraSession === session else { return }
                guard await self.performNextPendingCameraWrite(session: session) else { return }
            }
        }
    }

    private func performNextPendingCameraWrite(session: NativeCameraSession) async -> Bool {
        guard !pendingCameraWrites.isEmpty else { return false }
        let pending = pendingCameraWrites.removeFirst()
        let isShutterModeWrite = pending.write.property == .movieShutterMode
        let isBaseISOWrite = pending.write.property == .movieBaseISO
        let isFocusModeWrite = pending.write.property == .movieFocusMode
        let isShutterLockWrite = pending.write.property == .movieTVLockSetting
        do {
            try await session.writeCameraProperty(pending.write)
            if isShutterModeWrite || isBaseISOWrite || isFocusModeWrite || isShutterLockWrite {
                if let actual = try? await session.readCameraProperty(pending.write.property) {
                    cameraPropertySnapshot = cameraPropertySnapshot.applying(
                        property: pending.write.property, data: actual)
                } else {
                    cameraPropertySnapshot = cameraPropertySnapshot.applying(
                        property: pending.write.property,
                        data: pending.write.data
                    )
                }
                // Clear optimistic mode only after readback confirms the requested circuit — clearing
                // on a lagging readback lets `shutterPickerModeIndex` snap back to the old tab.
                if isShutterModeWrite {
                    let requested =
                        pendingShutterMode
                        ?? PTPCameraPropertyDecoders.shutterMode(pending.write.data[0])
                    if cameraPropertySnapshot.shutterMode == requested {
                        pendingShutterMode = nil
                        await refreshShutterModeDependentOptions(
                            session: session, mode: requested)
                    }
                }
                if isBaseISOWrite {
                    pendingBaseISOHigh = nil
                }
                if isShutterLockWrite {
                    pendingShutterLockState = nil
                }
            } else {
                cameraPropertySnapshot = cameraPropertySnapshot.applying(
                    property: pending.write.property,
                    data: pending.write.data
                )
            }
            publishCameraDisplayState()
            syncFocusFromSnapshot()
            syncShutterLockFromSnapshot()
            // The camera accepted the change, so this control isn't locked (any more).
            if !isShutterLockWrite {
                lockedControls.remove(pending.picker)
            }
            if isShutterLockWrite {
                let unlocking = pending.write.data.first == 0
                connectionMessage =
                    unlocking
                    ? "Shutter control unlocked on camera."
                    : "Shutter control locked on camera."
            } else if isShutterModeWrite {
                connectionMessage =
                    "Shutter mode set to \(pending.value.lowercased())."
            } else if isFocusModeWrite {
                connectionMessage = focusModeWriteMessage(
                    requested: pending.value,
                    reported: cameraPropertySnapshot.focusMode)
            } else {
                connectionMessage = "\(pending.picker.title) set to \(pending.value)."
            }
        } catch {
            // The camera refused the write — the body's "Control lock" has this control locked
            // (it can lock shutter / aperture / focus). Flag it so the bar shows a lock, and
            // revert the optimistic value to what the camera actually reports.
            if isShutterModeWrite {
                pendingShutterMode = nil
            }
            if isBaseISOWrite {
                pendingBaseISOHigh = nil
            }
            if isShutterLockWrite {
                pendingShutterLockState = nil
                if let actual = try? await session.readCameraProperty(pending.write.property) {
                    cameraPropertySnapshot = cameraPropertySnapshot.applying(
                        property: pending.write.property, data: actual)
                    publishCameraDisplayState()
                }
                syncFocusFromSnapshot()
                syncShutterLockFromSnapshot()
                let locking = pending.write.data.first == 1
                connectionMessage =
                    locking
                    ? "Could not lock shutter control on camera."
                    : "Could not unlock shutter control on camera."
            } else if isShutterModeWrite || isBaseISOWrite {
                if let actual = try? await session.readCameraProperty(pending.write.property) {
                    cameraPropertySnapshot = cameraPropertySnapshot.applying(
                        property: pending.write.property, data: actual)
                    publishCameraDisplayState()
                    syncFocusFromSnapshot()
                }
                syncShutterLockFromSnapshot()
                if isShutterModeWrite {
                    connectionMessage =
                        "Shutter angle/speed mode change was rejected by the camera."
                } else {
                    connectionMessage = "ISO base circuit change was rejected by the camera."
                }
            } else {
                lockedControls.insert(pending.picker)
                if let actual = try? await session.readCameraProperty(pending.write.property) {
                    cameraPropertySnapshot = cameraPropertySnapshot.applying(
                        property: pending.write.property, data: actual)
                    publishCameraDisplayState()
                    syncFocusFromSnapshot()
                }
                syncShutterLockFromSnapshot()
                if isFocusModeWrite {
                    connectionMessage = focusModeWriteFailureMessage(
                        requested: pending.value,
                        reported: cameraPropertySnapshot.focusMode)
                } else {
                    connectionMessage =
                        "\(pending.picker.title) is locked on the camera (Control lock)."
                }
            }
        }
        return true
    }

    /// Reflects `MovieTVLockSetting` poll readback into `lockedControls` for the shutter picker.
    private func syncShutterLockFromSnapshot() {
        if let pendingLock = pendingShutterLockState {
            if pendingLock {
                lockedControls.remove(.shutter)
            } else {
                lockedControls.insert(.shutter)
            }
            return
        }
        guard let locked = cameraPropertySnapshot.shutterLocked else { return }
        if locked {
            lockedControls.insert(.shutter)
        } else {
            lockedControls.remove(.shutter)
        }
    }

    private func shouldSuppressShutterLockPoll() -> Bool {
        if pendingCameraWrites.contains(where: { $0.write.property == .movieTVLockSetting }) {
            return true
        }
        if let pending = pendingShutterLockState {
            let expectedLocked = !pending
            return cameraPropertySnapshot.shutterLocked != expectedLocked
        }
        return false
    }

    private func pollNextCameraProperty(session: NativeCameraSession) async {
        let pollOrder = PTPPropertyCode.monitorPollOrder(isRecording: isRecording)
        guard !pollOrder.isEmpty else { return }
        let property = pollOrder[propertyPollIndex % pollOrder.count]
        propertyPollIndex = (propertyPollIndex + 1) % pollOrder.count
        if property == .movieShutterMode, shouldSuppressShutterModePoll() {
            // A mode switch is queued or optimistic — don't let stale camera readback undo the bar.
        } else if property == .movieTVLockSetting, shouldSuppressShutterLockPoll() {
            // A lock/unlock is queued or optimistic — don't let stale poll re-lock the picker.
        } else if property == .movieBaseISO, shouldSuppressBaseISOPoll() {
            // Same for dual-base ISO — keep the picker tab on the circuit the operator chose.
        } else {
            do {
                let data = try await session.readCameraProperty(property)
                if Self.commandTileDiagnosticProps.contains(property),
                    commandTileDiagnosticLogged.insert(property).inserted
                {
                    let hex = data.map { String(format: "%02x", $0) }.joined()
                    logConnection("cmd-tile \(property) ok bytes=[\(hex)] len=\(data.count)")
                }
                cameraPropertySnapshot = cameraPropertySnapshot.applying(
                    property: property, data: data)
                publishCameraDisplayState()
                syncFocusFromSnapshot()
                syncShutterLockFromSnapshot()
                if property == .warningStatus {
                    applyThermalStreamStepDownIfNeeded()
                }
                if property == .movieShutterMode,
                    let pending = pendingShutterMode,
                    cameraPropertySnapshot.shutterMode == pending
                {
                    pendingShutterMode = nil
                    await refreshShutterModeDependentOptions(
                        session: session, mode: pending)
                }
                if property == .movieTVLockSetting,
                    let pending = pendingShutterLockState,
                    cameraPropertySnapshot.shutterLocked == !pending
                {
                    pendingShutterLockState = nil
                }
            } catch {
                // Some properties are mode/lens dependent — keep the last known values. Log the
                // first command-tile failure so an on-hardware "—" is diagnosable from Console.
                if Self.commandTileDiagnosticProps.contains(property),
                    commandTileDiagnosticLogged.insert(property).inserted
                {
                    logConnection("cmd-tile \(property) read failed: \(error)")
                }
            }
        }
        await refreshCameraMaintenanceIfDue(session: session)
    }

    /// Refreshes slow-changing descriptors on a conservative cadence. The first non-recording poll
    /// after a new connection runs both groups; stream restarts preserve the timestamps so they do
    /// not create another descriptor burst. During a take, descriptor traffic is deferred entirely.
    private func refreshCameraMaintenanceIfDue(session: NativeCameraSession) async {
        let now = Date()
        if CameraMonitorPollPolicy.isDue(
            lastRefreshAt: lastStorageRefreshAt,
            now: now,
            interval: CameraMonitorPollPolicy.storageRefreshInterval)
        {
            lastStorageRefreshAt = now
            await refreshStorageInfo(session: session)
        }
        guard !isRecording else { return }
        if CameraMonitorPollPolicy.isDue(
            lastRefreshAt: lastDescriptorRefreshAt,
            now: now,
            interval: CameraMonitorPollPolicy.descriptorRefreshInterval)
        {
            lastDescriptorRefreshAt = now
            await refreshLensApertures(session: session)
            await refreshScreenModes(session: session)
            await refreshFileTypeModes(session: session)
            await refreshControlOptions(session: session)
        }
    }

    /// Re-reads the one real camera warning aggregate after an interrupted take, rather than
    /// waiting for the next low-rate recording health poll. Specific thermal bit semantics remain
    /// verify-on-HW in `CameraWarningStatus`; this still surfaces any body warning as `CHECK`.
    private func refreshWarningStatus(session: NativeCameraSession) async {
        guard let data = try? await session.readCameraProperty(.warningStatus) else { return }
        cameraPropertySnapshot = cameraPropertySnapshot.applying(
            property: .warningStatus, data: data)
        publishCameraDisplayState()
        applyThermalStreamStepDownIfNeeded()
    }

    /// The moded controls whose option lists the camera enumerates, paired with their value width.
    /// ISO is excluded — its dual base circuits switch via `movieBaseISO`, not one flat enum — and WB
    /// Kelvin is a continuous range, so only the WB *preset* mode (`movieWhiteBalance`) is read here.
    private static let enumeratedControls: [(property: PTPPropertyCode, valueByteCount: Int)] = [
        (.movieShutterAngle, 4),
        (.movieShutterSpeed, 4),
        (.movieWhiteBalance, 2),
        (.movieFocusMode, 1),
        (.movieFocusMeteringMode, 2),
        (.movieAFSubjectDetection, 1),
    ]

    /// Reads the camera's advertised option lists for the moded AF / shutter / WB-preset settings
    /// so each picker offers exactly what the body supports. Re-read on the slow descriptor
    /// cadence; on rejection or an empty result the last known options (or hardcoded fallback) are
    /// kept. The WB enum's colour-temperature mode belongs to the Kelvin tab, so it's filtered out.
    private func refreshControlOptions(session: NativeCameraSession) async {
        let shutterMode = effectiveShutterMode()
        for (property, valueByteCount) in Self.enumeratedControls {
            if property == .movieShutterSpeed, shutterMode != .speed { continue }
            if property == .movieShutterAngle, shutterMode != .angle { continue }
            await refreshControlOption(
                session: session, property: property, valueByteCount: valueByteCount)
        }
    }

    /// Re-reads one moded control's `GetDevicePropDescEx` enum and caches the picker labels.
    private func refreshControlOption(
        session: NativeCameraSession,
        property: PTPPropertyCode,
        valueByteCount: Int
    ) async {
        if property == .movieShutterSpeed, effectiveShutterMode() != .speed { return }
        if property == .movieShutterAngle, effectiveShutterMode() != .angle { return }
        do {
            var options = try await session.controlOptions(
                for: property, valueByteCount: valueByteCount)
            if property == .movieWhiteBalance {
                options = options.filter { $0 != "Color temp" }
            }
            if property == .movieFocusMode {
                options = PTPCameraPropertyDecoders.mergedMovieFocusModeOptions(
                    advertised: options)
            }
            // The inactive shutter circuit advertises a single placeholder value — never cache it.
            if property == .movieShutterSpeed || property == .movieShutterAngle,
                options.count <= 1
            {
                return
            }
            if !options.isEmpty, cameraControlOptions[property] != options {
                cameraControlOptions[property] = options
                logConnection("options \(property): \(options.joined(separator: ", "))")
            }
        } catch {
            // Not enumerable on this body or transiently unavailable — keep the fallback.
        }
    }

    /// Optimistic or camera-reported shutter display mode.
    private func effectiveShutterMode() -> ShutterDisplayMode {
        pendingShutterMode ?? cameraPropertySnapshot.shutterMode ?? .angle
    }

    /// Hardcoded shutter drum options for a circuit when describe stays on a placeholder enum.
    private func hardcodedShutterOptions(for mode: ShutterDisplayMode) -> [String] {
        let modes = CameraPicker.shutter.modes
        switch mode {
        case .angle: return modes[0].options
        case .speed: return modes[1].options
        }
    }

    /// Polls `movieShutterMode` until the body reports the requested circuit (or gives up).
    private func waitForShutterModeConfirmation(
        session: NativeCameraSession,
        expected: ShutterDisplayMode,
        maxAttempts: Int = 8,
        delayNanoseconds: UInt64 = 200_000_000
    ) async -> Bool {
        for attempt in 1...maxAttempts {
            if let pending = pendingShutterMode, pending != expected { return false }
            do {
                let data = try await session.readCameraProperty(.movieShutterMode)
                cameraPropertySnapshot = cameraPropertySnapshot.applying(
                    property: .movieShutterMode, data: data)
                publishCameraDisplayState()
                if cameraPropertySnapshot.shutterMode == expected { return true }
            } catch {
                if cameraPropertySnapshot.shutterMode == expected { return true }
            }
            if attempt < maxAttempts {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
        }
        return cameraPropertySnapshot.shutterMode == expected
    }

    /// The ZR only advertises the full `MovieShutterSpeed` enum while in speed mode (and the full
    /// `MovieShutterAngle` set while in angle mode). Re-describe the active circuit after a mode
    /// switch so the picker drum isn't stuck on the single placeholder speed read in angle mode.
    private func refreshShutterModeDependentOptions(
        session: NativeCameraSession,
        mode: ShutterDisplayMode
    ) async {
        guard await waitForShutterModeConfirmation(session: session, expected: mode) else {
            return
        }

        let property: PTPPropertyCode
        switch mode {
        case .speed: property = .movieShutterSpeed
        case .angle: property = .movieShutterAngle
        }
        let valueByteCount = 4
        var lastCount = 0

        for attempt in 1...3 {
            do {
                let options = try await session.controlOptions(
                    for: property, valueByteCount: valueByteCount)
                lastCount = options.count
                if options.count > 1 {
                    cameraControlOptions[property] = options
                    logConnection("options \(property): \(options.joined(separator: ", "))")
                    return
                }
            } catch {
                // Describe failed for this attempt — retry, then fall back below.
            }
            if attempt < 3 {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }

        let fallback = hardcodedShutterOptions(for: mode)
        guard !fallback.isEmpty else { return }
        cameraControlOptions[property] = fallback
        logConnection(
            "shutter-options: using hardcoded fallback for \(mode.rawValue) "
                + "(describe count=\(lastCount), fallback=\(fallback.count))")
        logConnection("options \(property): \(fallback.joined(separator: ", "))")
    }

    /// Reflects camera-reported state (the source of truth) into derived model state: the FOCUS
    /// picker's Area / Subject tabs, and the camera battery's charging indicator (external power).
    private func syncFocusFromSnapshot() {
        if let area = cameraPropertySnapshot.focusArea { focusArea = area }
        if let subject = cameraPropertySnapshot.focusSubject { focusSubject = subject }
        if let onPower = cameraPropertySnapshot.onExternalPower { cameraBatteryCharging = onPower }
    }

    /// Reads the camera's enumerated f-numbers for the mounted lens (via `GetDevicePropDesc`) and
    /// caches them as the authoritative IRIS option list; re-read on the slow descriptor cadence
    /// so a lens swap is reflected. Unverified against real hardware; on rejection or an empty
    /// list the last known apertures (or the lens-derived fallback) are retained.
    private func refreshLensApertures(session: NativeCameraSession) async {
        do {
            let raw = try await session.describeCameraPropertyEnum(
                .movieFNumber, valueByteCount: 2)
            let apertures = PTPCameraPropertyDecoders.apertureList(fromEnum: raw)
            if !apertures.isEmpty {
                cameraApertures = apertures
            }
        } catch {
            // Descriptor not supported or transiently unavailable — keep the last known list.
        }
    }

    /// Reads the camera's advertised recording modes (`MovScreenSize` descriptor) so the picker
    /// offers — and we only ever write — valid modes. Logs them once they change for verification.
    private func refreshScreenModes(session: NativeCameraSession) async {
        do {
            let modes = try await session.screenSizeModes()
            if !modes.isEmpty, modes != cameraScreenModes {
                cameraScreenModes = modes
                logConnection(
                    "screen-modes: "
                        + modes.map { "\($0.label)=0x\(String($0.raw, radix: 16))" }.joined(
                            separator: ", "))
            }
        } catch {
            // Descriptor not supported or transiently unavailable — keep the last known list.
        }
    }

    /// Reads the camera's advertised codecs (`MovFileType` descriptor) so the picker offers — and we
    /// only write — valid ones. Logs them when they change for verification.
    private func refreshFileTypeModes(session: NativeCameraSession) async {
        do {
            let modes = try await session.fileTypeModes()
            if !modes.isEmpty, modes != cameraFileTypeModes {
                cameraFileTypeModes = modes
                logConnection(
                    "codecs: "
                        + modes.map { "\($0.label)=0x\(String($0.raw, radix: 16))" }.joined(
                            separator: ", "))
            }
        } catch {
            // Descriptor not supported or transiently unavailable — keep the last known list.
        }
    }

    /// Reads storage capacity/free space and caches the result. Unverified against real hardware;
    /// on rejection or error the last known value is retained.
    private func refreshStorageInfo(session: NativeCameraSession) async {
        do {
            if let info = try await session.readStorageInfo() {
                lastKnownStorage = info
                publishCameraDisplayState()
            }
        } catch {
            // Storage query not supported or transiently unavailable — keep the last value.
        }
    }

    /// Computes the current `MediaStatus` from cached storage + the camera's codec/resolution/fps.
    /// Returns nil when storage isn't known yet.
    private func currentMediaStatus() -> MediaStatus? {
        guard let storage = lastKnownStorage else { return nil }
        let gigabytes = storage.gigabytesFree
        let percent = storage.percentFree
        let minutes = RecordDurationEstimator.minutesRemaining(
            codec: MonitorTextFormat.codecShortLabel(cameraPropertySnapshot.fileType ?? ""),
            resolutionWidth: Int(
                cameraPropertySnapshot.resolution?.split(separator: "x").first
                    .flatMap { Int($0) } ?? 0),
            resolutionHeight: Int(
                cameraPropertySnapshot.resolution?.split(separator: "x").last
                    .flatMap { Int($0) } ?? 0),
            frameRate: cameraPropertySnapshot.fps ?? 0,
            gigabytesFree: gigabytes
        )
        return MediaStatus(
            gigabytesFree: gigabytes, percentFree: percent, minutesRemaining: minutes)
    }

    /// Publishes property snapshot → monitor readouts, including ZR RAW `[FX]` / `[DX]` tags on the
    /// resolution/frame-rate bar (shared policy with Android).
    private func publishCameraDisplayState(mediaStatus: MediaStatus? = nil) {
        var next = cameraState.applyingCameraProperties(
            cameraPropertySnapshot,
            mediaStatus: mediaStatus ?? currentMediaStatus())
        let labeled = NikonZRRawCropPresentation.label(
            baseLabel: next.resolutionFrameRate,
            rawScreenSize: cameraPropertySnapshot.rawScreenSize,
            currentCodec: cameraPropertySnapshot.fileType,
            isNikonZR: isConnectedNikonZR)
        if labeled != next.resolutionFrameRate {
            next = next.updating(resolutionFrameRate: labeled)
        }
        cameraState = next
    }

    func cycleDisplayMode() {
        guard !interfaceLocked else { return }
        displayMode = preferences.nextDisplayMode(after: displayMode)
    }

    /// Jump straight to a display mode (used by the feed swipe: down → clean, up → live).
    func setDisplayMode(_ mode: DispMode) {
        guard !interfaceLocked, displayMode != mode else { return }
        guard preferences.enabledDispModes.contains(mode) else { return }
        displayMode = mode
    }

    func toggleInterfaceLock() {
        interfaceLocked.toggle()
    }

    func toggleFocusPointLock() {
        guard !interfaceLocked else { return }
        focusPointLocked.toggle()
    }

    /// Reorders a command-grid tile to a new slot (drag-to-reorder). Persisted via `didSet`.
    func moveCommandTile(_ kind: CommandTileKind, to index: Int) {
        let next = CommandGridOrder.moving(kind, to: index, in: commandGridOrder)
        if next != commandGridOrder { commandGridOrder = next }
    }

    /// Reorders assist-toolbar tools (drag-to-reorder in Operator Setup). Persisted via `didSet`.
    func moveAssistToolbar(from source: IndexSet, to destination: Int) {
        var order = preferences.assistToolbarOrder
        order.move(fromOffsets: source, toOffset: destination)
        preferences.assistToolbarOrder = order
    }

    /// Reorders DISP modes (drag-to-reorder in Operator Setup). Persisted via `didSet`.
    func moveDispOrder(from source: IndexSet, to destination: Int) {
        var order = preferences.dispOrder
        order.move(fromOffsets: source, toOffset: destination)
        preferences.dispOrder = order
    }

    func toggleDispMode(_ mode: DispMode) {
        guard preferences.toggleDispMode(mode) else { return }
        reconcileDisplayModeAfterDispPreferenceChange()
    }

    func resetDispPreferences() {
        preferences.dispOrder = OperatorPreferences.defaults.dispOrder
        preferences.enabledDispModes = OperatorPreferences.defaults.enabledDispModes
        reconcileDisplayModeAfterDispPreferenceChange()
    }

    func toggleExposureBarVisibility(_ tool: MonitorAssistTool) {
        preferences.toggleExposureBarControl(tool)
    }

    func toggleFramingBarVisibility(_ tool: MonitorAssistTool) {
        preferences.toggleFramingBarControl(tool)
    }

    /// Toggles monitor-bar visibility for exposure and framing assist tools (Display settings).
    func toggleAssistToolbarVisibility(_ tool: MonitorAssistTool) {
        if MonitorAssistTool.exposureBarTools.contains(tool) {
            toggleExposureBarVisibility(tool)
        } else if MonitorAssistTool.framingBarTools.contains(tool) {
            toggleFramingBarVisibility(tool)
        }
    }

    func resetExposureBarVisibility() {
        preferences.exposureBarVisibleControls =
            OperatorPreferences.defaults.exposureBarVisibleControls
    }

    func resetFramingBarVisibility() {
        preferences.framingBarVisibleControls =
            OperatorPreferences.defaults.framingBarVisibleControls
    }

    /// Restores assist-toolbar order and per-button visibility to defaults (Display settings).
    func resetAssistToolbarPreferences() {
        preferences.assistToolbarOrder = OperatorPreferences.defaults.assistToolbarOrder
        resetExposureBarVisibility()
        resetFramingBarVisibility()
    }

    private func reconcileDisplayModeAfterDispPreferenceChange() {
        if !preferences.enabledDispModes.contains(displayMode) {
            displayMode = preferences.enabledDispOrder.first ?? .live
        }
    }

    // MARK: Demo UI mode (simulator capture driving)

    #if DEBUG
        /// Switches the demo feed to still number `number` (1-based) from `ZC_DEMO_FEED_DIR` and
        /// re-seeds every scope from it, so meters track the new frame like a live stream would.
        func demoSelectFeedImage(_ number: Int) {
            guard isDemoSession, number >= 1, number <= demoFeedImagePaths.count,
                let image = UIImage(contentsOfFile: demoFeedImagePaths[number - 1])
            else { return }
            liveFrameImage = image
            Task { await refreshScopes(from: image, full: true) }
        }
    #endif

    /// Seeds the canonical demo focus + eye AF box pair (same shape as the autostart seed). Called
    /// on demo-mode entry so both interactive targets start visible.
    func demoSeedFocusPair() {
        liveViewFocus = PTPLiveViewFocusInfo(
            coordinateWidth: 6048,
            coordinateHeight: 3400,
            // Idle so demo box 0 shows the dim-white style next to the green face/eye boxes
            // (`.focused` would render every box green — see LiveFocusBoxOverlay.primaryBoxColor).
            focusResult: .unknown,
            subjectDetectionActive: true,
            selectedBoxIndex: 1,
            boxes: [
                PTPLiveViewAFBox(centerX: 3024, centerY: 1700, width: 815, height: 884),
                PTPLiveViewAFBox(centerX: 2835, centerY: 1491, width: 186, height: 186),
            ]
        )
    }

    /// Demo UI mode: drags the main AF box to a feed-relative point. When present, the eye box rides
    /// along with it and is re-clamped; an intentionally removed eye stays removed.
    func demoMoveFocusBox(to point: CGPoint, feedSize: CGSize) {
        guard demoUIMode, feedSize.width > 0, feedSize.height > 0 else { return }
        if liveViewFocus?.boxes.isEmpty != false { demoSeedFocusPair() }
        guard let focus = liveViewFocus, let face = focus.boxes.first else { return }
        let spaceWidth = Double(focus.coordinateWidth)
        let spaceHeight = Double(focus.coordinateHeight)
        let targetX = spaceWidth * min(max(point.x / feedSize.width, 0), 1)
        let targetY = spaceHeight * min(max(point.y / feedSize.height, 0), 1)
        let halfWidth = Double(face.width) / 2
        let halfHeight = Double(face.height) / 2
        let centerX = min(max(targetX, halfWidth), spaceWidth - halfWidth)
        let centerY = min(max(targetY, halfHeight), spaceHeight - halfHeight)
        var boxes = focus.boxes
        let moved = PTPLiveViewAFBox(
            centerX: Int(centerX.rounded()), centerY: Int(centerY.rounded()),
            width: face.width, height: face.height)
        boxes[0] = moved
        if boxes.count > 1 {
            let eye = boxes[1]
            let riddenX = Double(eye.centerX) + centerX - Double(face.centerX)
            let riddenY = Double(eye.centerY) + centerY - Double(face.centerY)
            boxes[1] = Self.demoClampedBox(eye, centerX: riddenX, centerY: riddenY, within: moved)
        }
        liveViewFocus = demoFocusReplacingBoxes(focus, boxes: boxes)
    }

    /// Chooses which demo box a primary drag owns. Starting on the eye moves only that marker;
    /// starting anywhere else moves the main focus box and carries a visible eye along with it.
    func demoFocusDragTarget(at point: CGPoint, feedSize: CGSize) -> DemoFocusDragTarget {
        guard demoUIMode, feedSize.width > 0, feedSize.height > 0,
            let focus = liveViewFocus, focus.boxes.count > 1
        else { return .focus }
        let target = demoFocusCoordinate(for: point, feedSize: feedSize, focus: focus)
        return Self.demoBoxContains(focus.boxes[1], point: target) ? .eye : .focus
    }

    /// Moves the eye/tracking marker within the main focus box. It is deliberately drag-only in the
    /// simulator so a click cannot be misclassified as a secondary click and unexpectedly hide it.
    func demoMoveEyeBox(to point: CGPoint, feedSize: CGSize) {
        guard demoUIMode, feedSize.width > 0, feedSize.height > 0 else { return }
        guard let focus = liveViewFocus, focus.boxes.count > 1 else { return }
        let face = focus.boxes[0]
        let target = demoFocusCoordinate(for: point, feedSize: feedSize, focus: focus)
        var boxes = focus.boxes
        boxes[1] = Self.demoClampedBox(
            boxes[1], centerX: target.x, centerY: target.y, within: face)
        liveViewFocus = PTPLiveViewFocusInfo(
            coordinateWidth: focus.coordinateWidth,
            coordinateHeight: focus.coordinateHeight,
            focusResult: focus.focusResult,
            subjectDetectionActive: true,
            trackingAFActive: focus.trackingAFActive,
            selectedBoxIndex: 1,
            boxes: boxes)
    }

    /// Key 8 toggles the eye marker without relying on Simulator primary/secondary-button routing.
    func demoToggleEyeBox() {
        guard demoUIMode else { return }
        if liveViewFocus?.boxes.isEmpty != false { demoSeedFocusPair() }
        guard let focus = liveViewFocus, let face = focus.boxes.first else { return }
        if focus.boxes.count > 1 {
            liveViewFocus = PTPLiveViewFocusInfo(
                coordinateWidth: focus.coordinateWidth,
                coordinateHeight: focus.coordinateHeight,
                focusResult: focus.focusResult,
                subjectDetectionActive: false,
                trackingAFActive: false,
                selectedBoxIndex: 0,
                boxes: [face])
        } else {
            liveViewFocus = PTPLiveViewFocusInfo(
                coordinateWidth: focus.coordinateWidth,
                coordinateHeight: focus.coordinateHeight,
                focusResult: focus.focusResult,
                subjectDetectionActive: true,
                trackingAFActive: focus.trackingAFActive,
                selectedBoxIndex: 1,
                boxes: [face, Self.demoDefaultEyeBox(within: face)])
        }
    }

    private func demoFocusCoordinate(
        for point: CGPoint, feedSize: CGSize, focus: PTPLiveViewFocusInfo
    ) -> (x: Double, y: Double) {
        (
            x: Double(focus.coordinateWidth) * min(max(point.x / feedSize.width, 0), 1),
            y: Double(focus.coordinateHeight) * min(max(point.y / feedSize.height, 0), 1)
        )
    }

    private static func demoBoxContains(
        _ box: PTPLiveViewAFBox, point: (x: Double, y: Double)
    ) -> Bool {
        let halfWidth = Double(box.width) / 2
        let halfHeight = Double(box.height) / 2
        return point.x >= Double(box.centerX) - halfWidth
            && point.x <= Double(box.centerX) + halfWidth
            && point.y >= Double(box.centerY) - halfHeight
            && point.y <= Double(box.centerY) + halfHeight
    }

    private static func demoDefaultEyeBox(within face: PTPLiveViewAFBox) -> PTPLiveViewAFBox {
        let side = max(1, Int((Double(min(face.width, face.height)) * 0.22).rounded()))
        return PTPLiveViewAFBox(
            centerX: face.centerX,
            centerY: face.centerY,
            width: side,
            height: side)
    }

    /// Returns `box` re-centred as close to (`centerX`, `centerY`) as fits fully inside `frame`.
    private static func demoClampedBox(
        _ box: PTPLiveViewAFBox, centerX: Double, centerY: Double, within frame: PTPLiveViewAFBox
    ) -> PTPLiveViewAFBox {
        let halfWidth = Double(box.width) / 2
        let halfHeight = Double(box.height) / 2
        let minX = Double(frame.centerX) - Double(frame.width) / 2 + halfWidth
        let maxX = Double(frame.centerX) + Double(frame.width) / 2 - halfWidth
        let minY = Double(frame.centerY) - Double(frame.height) / 2 + halfHeight
        let maxY = Double(frame.centerY) + Double(frame.height) / 2 - halfHeight
        return PTPLiveViewAFBox(
            centerX: Int(min(max(centerX, minX), max(minX, maxX)).rounded()),
            centerY: Int(min(max(centerY, minY), max(minY, maxY)).rounded()),
            width: box.width, height: box.height)
    }

    private func demoFocusReplacingBoxes(
        _ focus: PTPLiveViewFocusInfo, boxes: [PTPLiveViewAFBox]
    ) -> PTPLiveViewFocusInfo {
        PTPLiveViewFocusInfo(
            coordinateWidth: focus.coordinateWidth,
            coordinateHeight: focus.coordinateHeight,
            focusResult: focus.focusResult,
            subjectDetectionActive: focus.subjectDetectionActive,
            trackingAFActive: focus.trackingAFActive,
            selectedBoxIndex: focus.selectedBoxIndex,
            boxes: boxes)
    }

    /// Moves the AF point to a feed-relative tap location. Maps the tap into the camera's live-view
    /// coordinate space (the LiveViewObject "whole size") and queues a `ChangeAfArea` for the next
    /// safe point. In the demo it just drops the on-screen AF box at the tap so the point visibly
    /// follows the finger.
    func setFocusPoint(at point: CGPoint, feedSize: CGSize) {
        guard !interfaceLocked, !focusPointLocked else { return }
        guard feedSize.width > 0, feedSize.height > 0 else { return }
        // Light tap confirming the AF point moved; after the guards so locked taps stay silent.
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let normalizedX = min(max(point.x / feedSize.width, 0), 1)
        let normalizedY = min(max(point.y / feedSize.height, 0), 1)
        // Coordinate space from the latest live-view header; fall back to a 16:9 default before the
        // first frame has reported one.
        let coordinateWidth = liveViewFocus?.coordinateWidth ?? 1000
        let coordinateHeight =
            liveViewFocus?.coordinateHeight
            ?? Int((Double(coordinateWidth) * feedSize.height / feedSize.width).rounded())
        applyFocusPoint(
            cameraX: Int((Double(coordinateWidth) * normalizedX).rounded()),
            cameraY: Int((Double(coordinateHeight) * normalizedY).rounded()),
            coordinateWidth: coordinateWidth,
            coordinateHeight: coordinateHeight
        )
    }

    /// Whether a focus reset would do anything, gating the recenter affordance: the AF point sits
    /// meaningfully off the frame centre (>4% on either axis), or subject tracking is latched —
    /// a tracked box can drift through centre while panning, and reset is how tracking ends.
    /// False while locked (the lock pins it on purpose) or before any focus box is known.
    var isFocusResetAvailable: Bool {
        guard !focusPointLocked, let focus = liveViewFocus, let box = focus.boxes.first,
            focus.coordinateWidth > 0, focus.coordinateHeight > 0
        else { return false }
        if focus.isSubjectTrackingLatched { return true }
        let dx =
            abs(Double(box.centerX) - Double(focus.coordinateWidth) / 2)
            / Double(focus.coordinateWidth)
        let dy =
            abs(Double(box.centerY) - Double(focus.coordinateHeight) / 2)
            / Double(focus.coordinateHeight)
        return dx > 0.04 || dy > 0.04
    }

    private var shouldCancelSubjectTrackingOnFocusReset: Bool {
        guard !isDemoSession else { return false }
        if let focus = liveViewFocus, focus.isSubjectTrackingLatched { return true }
        if focusArea == "Subject" { return true }
        if let focus = liveViewFocus {
            if focus.subjectDetectionActive { return true }
            if focus.selectedBoxIndex != nil { return true }
            if focus.boxes.count > 1 { return true }
        }
        if focusSubject != "Off" { return true }
        let mode = cameraPropertySnapshot.focusMode ?? cameraValue(for: .focus)
        return mode == "AF-F"
    }

    /// Recentres the AF point. When subject tracking is active, a multi-step safe-point sequence
    /// sends `EndTracking` while Subject/TargetTracking mode is still engaged, suspends subject
    /// detection, demotes Subject → Single, waits for the header's tracking-AF status byte to
    /// clear, then `ChangeAfArea` to centre, repeats `EndTracking` to release any re-latch, restoring the
    /// saved AF-area and subject-detection picker values (mode settings only — no `StartTracking`).
    /// Release flags use live-view header state as well as picker values so demotion is not skipped
    /// when polls lag hardware. Tap-to-focus is unchanged (`applyFocusPoint` / `pendingFocusPoint`).
    func resetFocusPoint() {
        guard !interfaceLocked, !focusPointLocked else { return }
        let coordinateWidth = liveViewFocus?.coordinateWidth ?? 1000
        let coordinateHeight =
            liveViewFocus?.coordinateHeight ?? Int((Double(coordinateWidth) * 9 / 16).rounded())
        let recenterX = UInt32(max(0, coordinateWidth / 2))
        let recenterY = UInt32(max(0, coordinateHeight / 2))
        if shouldCancelSubjectTrackingOnFocusReset {
            let context = FocusResetContext(
                recenterX: recenterX,
                recenterY: recenterY,
                demoteSubjectArea: FocusResetReleasePolicy.shouldDemoteSubjectArea(
                    focusArea: focusArea,
                    liveViewFocus: liveViewFocus
                ),
                suspendSubjectDetection: FocusResetReleasePolicy.shouldSuspendSubjectDetection(
                    focusSubject: focusSubject,
                    liveViewFocus: liveViewFocus
                ),
                savedFocusArea: focusArea,
                savedFocusSubject: focusSubject
            )
            logConnection(
                "focus reset: queued (demote=\(context.demoteSubjectArea), "
                    + "suspend=\(context.suspendSubjectDetection), "
                    + "saved area \(context.savedFocusArea), subject \(context.savedFocusSubject), "
                    + "\(focusResetHeaderSummary(liveViewFocus)))"
            )
            focusResetStep = .endTracking(context)
            return
        }
        applyFocusPoint(
            cameraX: Int(recenterX),
            cameraY: Int(recenterY),
            coordinateWidth: coordinateWidth,
            coordinateHeight: coordinateHeight
        )
    }

    /// Lifts the recenter-focus button above any movable assist panel (scope / false-colour
    /// reference) that would overlap its bottom-left corner spot, so e.g. a waveform dropped there
    /// pushes it up to the next clear slot. Climbs panel-by-panel (lowest first) until nothing
    /// overlaps. Called by `MonitorShell`'s landscape chrome since it only reads
    /// `movablePanelFrames`, not view-local state.
    func focusResetButtonClearY(centerX: CGFloat, baseY: CGFloat, size: CGFloat) -> CGFloat {
        let half = size / 2
        let gap: CGFloat = 10
        let panels = movablePanelFrames.values.sorted { $0.maxY > $1.maxY }
        var y = baseY
        var moved = true
        var iterations = 0
        while moved && iterations < 8 {
            moved = false
            iterations += 1
            let buttonRect = CGRect(x: centerX - half, y: y - half, width: size, height: size)
            for frame in panels where buttonRect.intersects(frame.insetBy(dx: -gap, dy: -gap)) {
                y = frame.minY - gap - half
                moved = true
            }
        }
        // Never climb off the top of the feed.
        return max(y, 44)
    }

    /// True when `location` (feed space) lands on the camera's current AF / subject box, with a
    /// touch-friendly margin — the gate for the double-tap-to-reset gesture.
    func isLocationOnFocusBox(_ location: CGPoint, feedSize: CGSize) -> Bool {
        guard let focus = liveViewFocus, feedSize.width > 0, feedSize.height > 0 else {
            return false
        }
        return focus.boxIndex(
            containingX: Double(location.x),
            y: Double(location.y),
            feedWidth: Double(feedSize.width),
            feedHeight: Double(feedSize.height),
            padding: 22
        ) != nil
    }

    /// Applies an AF point at the given camera-space coordinate: in the demo it drops the on-screen
    /// box; on a live camera it queues a `ChangeAfArea` for the next safe point.
    private func applyFocusPoint(
        cameraX: Int, cameraY: Int, coordinateWidth: Int, coordinateHeight: Int
    ) {
        guard !isDemoSession else {
            let boxWidth = max(40, coordinateWidth / 7)
            let boxHeight = max(40, coordinateHeight / 7)
            liveViewFocus = PTPLiveViewFocusInfo(
                coordinateWidth: coordinateWidth,
                coordinateHeight: coordinateHeight,
                focusResult: .focused,  // demo tap reads as acquired — shows the green AF state
                subjectDetectionActive: false,
                selectedBoxIndex: 0,
                boxes: [
                    PTPLiveViewAFBox(
                        centerX: cameraX, centerY: cameraY, width: boxWidth, height: boxHeight)
                ]
            )
            return
        }
        pendingFocusPoint = (UInt32(max(0, cameraX)), UInt32(max(0, cameraY)))
    }

    func toggleRecording() {
        if preferences.recordConfirmationEnabled {
            if !isDemoSession {
                guard cameraSession != nil, isMonitorPresented else {
                    connectionMessage = "Start live view before recording."
                    return
                }
            }
            pendingRecordConfirmation = !isRecording
            return
        }
        executeRecordToggle()
    }

    func confirmRecordToggle() {
        guard pendingRecordConfirmation != nil else { return }
        pendingRecordConfirmation = nil
        executeRecordToggle()
    }

    func cancelRecordToggle() {
        pendingRecordConfirmation = nil
    }

    private func executeRecordToggle() {
        if isDemoSession {
            isRecording.toggle()
            // `updating` preserves every other field — crucially `mediaStatus`, so the top-bar MEDIA
            // cell keeps toggling capacity ↔ duration after a record start/stop.
            cameraState = cameraState.updating(recordState: isRecording ? .recording : .standby)
            return
        }
        guard cameraSession != nil, isMonitorPresented else {
            connectionMessage = "Start live view before recording."
            return
        }
        // Optimistically flip the button now (snappy), then queue the actual record op for the next
        // live-view safe point; if the camera rejects it, the safe point reverts the state.
        let targetRecording = !isRecording
        isRecording = targetRecording
        cameraState = cameraState.updating(recordState: targetRecording ? .recording : .standby)
        pendingRecordStart = targetRecording
        pendingRecordToggle = true
        appRecordCommandAt = Date()
        publishWatchState()
    }

    // MARK: Apple Watch relay

    /// Activates the watch relay once and wires its callbacks. Called from the app root on launch.
    func activateWatchRelay() {
        guard !watchRelayActivated else { return }
        watchRelayActivated = true
        watchRelay.onToggleRecord = { [weak self] in
            self?.watchToggleRecord()
                ?? WatchCommandResult(accepted: false, isRecording: false, error: "unavailable")
        }
        watchRelay.onReachabilityChanged = { [weak self] in
            self?.publishWatchState()
        }
        watchRelay.activate()
        publishWatchState()
    }

    // MARK: Bluetooth shutter remote

    /// Whether the remote-shutter mechanism should be live right now: opted in, live monitor up
    /// AND front (no full-screen panel like Operator Setup, Media, or the Tool Library covering
    /// it), app active, and the clip player not owning the audio session. Inside menus the
    /// monitor disarms entirely so the volume keys go back to controlling volume.
    private var bluetoothShutterShouldRun: Bool {
        BluetoothShutterMonitor.shouldRun(
            enabled: preferences.bluetoothShutterEnabled,
            monitorPresented: isMonitorPresented,
            liveViewFront: !activePanelHidesLiveFeed && !isStandaloneMediaLibraryPresented,
            applicationIsActive: UIApplication.shared.applicationState == .active,
            audioSessionAvailable: !mediaPlaybackOwnsAudioSession)
    }

    /// Starts or stops the remote-shutter monitor to match the current state. Idempotent — safe to
    /// call from every seam that changes an input (preference toggle, monitor present/dismiss,
    /// foreground return). Volume observation is the SOLE path: it catches generic Bluetooth HID
    /// remotes and the phone's own volume buttons without an `AVCaptureSession` (which would cost
    /// a permission prompt, the camera-in-use indicator, and thermal/RF load throughout live view).
    func updateBluetoothShutter() {
        let shouldRun = bluetoothShutterShouldRun
        bluetoothShutterLogger.info(
            "BT-SHUTTER reconcile enabled=\(self.preferences.bluetoothShutterEnabled, privacy: .public) monitor=\(self.isMonitorPresented, privacy: .public) shouldRun=\(shouldRun, privacy: .public) kvoActive=\(self.bluetoothShutter.isActive, privacy: .public)"
        )
        guard shouldRun else {
            bluetoothShutter.stop()
            return
        }
        bluetoothShutter.onTrigger = { [weak self] in self?.remoteShutterToggleRecord() }
        let volumeActive = bluetoothShutter.start()
        bluetoothShutterLogger.info(
            "BT-SHUTTER volume monitor armed=\(volumeActive, privacy: .public)")
    }

    /// Coordinates the full-screen clip player's claim on the process-wide audio session with the
    /// volume-button shutter listener. Call with `true` before activating playback and `false`
    /// only after playback has released the session.
    func setMediaPlaybackOwnsAudioSession(_ ownsAudioSession: Bool) {
        guard mediaPlaybackOwnsAudioSession != ownsAudioSession else { return }
        mediaPlaybackOwnsAudioSession = ownsAudioSession
        updateBluetoothShutter()
    }

    /// A remote press bypasses the phone-side confirmation alert by design, exactly like the watch
    /// Record button: an unseen dialog on the phone would strand the take. The volume monitor has
    /// already debounced the press.
    private func remoteShutterToggleRecord() {
        let wasRecording = isRecording
        let hasSession = cameraSession != nil || isDemoSession
        executeRecordToggle()
        bluetoothShutterLogger.info(
            "BT-SHUTTER record callback session=\(hasSession, privacy: .public) monitor=\(self.isMonitorPresented, privacy: .public) before=\(wasRecording, privacy: .public) after=\(self.isRecording, privacy: .public) queued=\(self.pendingRecordToggle, privacy: .public)"
        )
        publishWatchState()
    }

    /// Handles a Record toggle relayed from the watch. Bypasses `recordConfirmationEnabled` —
    /// a phone-side confirmation dialog would strand an unseen prompt while the operator is
    /// looking at the watch.
    func watchToggleRecord() -> WatchCommandResult {
        let wasRecording = isRecording
        executeRecordToggle()
        let accepted = isRecording != wasRecording
        let result = WatchCommandResult(
            accepted: accepted,
            isRecording: isRecording,
            error: accepted ? nil : "Start live view before recording.")
        publishWatchState()
        return result
    }

    /// Builds the current wire snapshot from the live monitor fields.
    func currentWatchRelayState() -> WatchRelayState {
        let hasCamera = isDemoSession || cameraSession != nil
        let connectionState: WatchConnectionState =
            (isMonitorPresented && hasCamera) ? .connected : .noCamera
        let feedLive = connectionState == .connected && !shouldPauseLiveFeed
        return WatchRelayState(
            recordState: cameraState.recordState,
            timecode: liveTimecode,
            mediaStatus: cameraState.mediaStatus,
            media: cameraState.media,
            cameraBatteryPercent: cameraState.cameraBatteryPercent,
            cameraName: cameraState.cameraName,
            isRecording: isRecording,
            connection: connectionState,
            feedLive: feedLive,
            liveFPS: liveFPS)
    }

    /// Publishes the current state to the watch relay (coalesced; no-ops when nothing changed).
    func publishWatchState() {
        watchRelay.ingestState(currentWatchRelayState())
    }

    /// easeOutExpo tween (CSS `cubic-bezier(0.16, 1, 0.3, 1)`) for the exposure picker's slide-up
    /// reveal — a hard front-loaded ramp into a long soft settle, kept brisk so it never lags the
    /// tap. Mirrors the prototype's transform transition in `index.html`.
    private static let panelRevealCurve = Animation.timingCurve(0.16, 1, 0.3, 1, duration: 0.20)

    /// Active shutter picker tab: 0 = angle, 1 = speed. Uses the optimistic mode while a mode
    /// write is pending so the tab doesn't snap back before the safe point runs.
    var shutterPickerModeIndex: Int {
        let mode = pendingShutterMode ?? cameraPropertySnapshot.shutterMode ?? .angle
        return mode == .speed ? 1 : 0
    }

    /// Active ISO picker tab: 0 = low base, 1 = high base. Driven by `movieBaseISO`, not the
    /// sensitivity value — overlapping ISO steps exist on both circuits. Unified-drum codecs
    /// always report 0 (no LOW/HIGH tabs).
    var isoPickerModeIndex: Int {
        guard showsDualBaseISOPicker else { return 0 }
        if let pending = pendingBaseISOHigh { return pending ? 1 : 0 }
        return cameraPropertySnapshot.baseISO == "High" ? 1 : 0
    }

    /// Whether the ISO picker shows separate LOW/HIGH base circuits (R3D NE only).
    var showsDualBaseISOPicker: Bool {
        ISOPickerPolicy.showsDualBaseCircuits(codec: cameraState.codec)
    }

    /// ISO is locked while recording in R3D NE; other codecs allow mid-roll ISO changes.
    var isISORecordingLocked: Bool {
        ISOPickerPolicy.blocksISOChangeWhileRecording(
            codec: cameraState.codec, isRecording: isRecording)
    }

    /// Command grid tiles, omitting the dual-base Mode tile when the codec auto-switches circuits.
    var visibleCommandGridOrder: [CommandTileKind] {
        guard showsDualBaseISOPicker else {
            return commandGridOrder.filter { $0 != .mode }
        }
        return commandGridOrder
    }

    /// Segmented mode tabs for a picker (ISO layout follows the active codec).
    func pickerModes(for picker: CameraPicker) -> [PickerMode] {
        guard picker == .iso else { return picker.modes }
        return ISOPickerPolicy.pickerModes(codec: cameraState.codec).map {
            PickerMode(title: $0.title, detail: $0.detail, options: $0.options, base: $0.base)
        }
    }

    /// Picker header subtitle (ISO reflects dual-base vs unified layout).
    func pickerSubtitle(for picker: CameraPicker) -> String {
        picker == .iso
            ? ISOPickerPolicy.pickerSubtitle(codec: cameraState.codec) : picker.subtitle
    }

    private func shouldSuppressShutterModePoll() -> Bool {
        if pendingCameraWrites.contains(where: { $0.write.property == .movieShutterMode }) {
            return true
        }
        if let pending = pendingShutterMode,
            cameraPropertySnapshot.shutterMode != pending
        {
            return true
        }
        return false
    }

    private func shouldSuppressBaseISOPoll() -> Bool {
        if pendingBaseISOHigh != nil { return true }
        return pendingCameraWrites.contains { $0.write.property == .movieBaseISO }
    }

    /// The picker's current camera readout value.
    func cameraValue(for picker: CameraPicker) -> String {
        switch picker {
        case .resolution: cameraState.resolutionFrameRate
        case .codec: cameraState.codec
        case .mode: commandExposureMode
        default: cameraState.values.first(where: { $0.label == picker.valueLabel })?.value ?? ""
        }
    }

    /// The apertures the IRIS picker offers: the camera's enumerated f-numbers for the mounted lens
    /// when known, otherwise the lens-descriptor-derived third-stop fallback ladder.
    var irisApertures: [String] {
        cameraApertures.isEmpty ? cameraState.availableApertures : cameraApertures
    }

    /// The value to centre a picker mode's drum on. The FOCUS tabs are independent settings and use
    /// their own stored value; alternative circuits (ISO/shutter/WB) use the live value when it
    /// belongs to that mode, otherwise the mode's base.
    func pickerModeValue(_ picker: CameraPicker, mode: Int) -> String {
        if picker == .iso, !showsDualBaseISOPicker {
            return cameraValue(for: picker)
        }
        let modes = pickerModes(for: picker)
        guard modes.indices.contains(mode) else { return cameraValue(for: picker) }
        if picker == .focus {
            switch mode {
            case 1: return focusArea
            case 2: return focusSubject
            default: return cameraValue(for: picker)
            }
        }
        if picker == .shutter {
            switch mode {
            case 0: return cameraPropertySnapshot.shutterAngle ?? modes[0].base
            case 1: return cameraPropertySnapshot.shutterSpeed ?? modes[1].base
            default: break
            }
        }
        if picker == .audio {
            switch mode {
            case 0:
                return cameraPropertySnapshot.audioSensitivity
                    ?? cameraPropertySnapshot.microphoneLevel ?? modes[0].base
            case 1: return cameraPropertySnapshot.audioInput ?? modes[1].base
            case 2: return cameraPropertySnapshot.windNoiseReduction ?? modes[2].base
            case 3: return cameraPropertySnapshot.inputAttenuator ?? modes[3].base
            case 4: return cameraPropertySnapshot.audio32BitFloat ?? modes[4].base
            default: break
            }
        }
        let pickerMode = modes[mode]
        let live = cameraValue(for: picker)
        if pickerMode.options.contains(live) { return live }
        return pickerMode.base.isEmpty ? (pickerMode.options.first ?? live) : pickerMode.base
    }

    /// Applies a value chosen within a picker's mode to the right target: the FOCUS Area / Subject
    /// tabs and the AUDIO tabs route to their own settings, everything else to the shared camera
    /// write.
    func applyPicker(_ picker: CameraPicker, mode: Int, value: String) {
        if picker == .audio {
            // AUDIO is five independent camera settings chosen by tab — each its own PTP property.
            let control: PTPCameraControl? =
                switch mode {
                case 0: .audioSensitivity
                case 1: .audioInput
                case 2: .windFilter
                case 3: .attenuator
                case 4: .audio32BitFloat
                default: nil
                }
            if let control { applyAudioControl(control, value: value) }
            return
        }
        guard picker == .focus else {
            applyPickerValue(value, for: picker)
            return
        }
        // FOCUS is three independent camera settings chosen by tab: AF mode, AF-area mode, and
        // subject detection — each its own PTP property.
        switch mode {
        case 1:
            focusArea = value
            applyFocusControl(.focusArea, value: value)
        case 2:
            focusSubject = value
            applyFocusControl(.focusSubject, value: value)
        default:
            // AF mode also drives the bar's FOCUS readout.
            if isDemoSession {
                applyLocalPickerValue(value, for: .focus)
            } else {
                applyFocusControl(.focusMode, value: value)
            }
        }
    }

    /// Queues a movie-AF control write (focus mode / AF-area / subject detection). No-op in the
    /// demo (the optimistic local update stands).
    private func applyFocusControl(_ control: PTPCameraControl, value: String) {
        guard !isDemoSession else { return }
        guard let write = PTPCameraPropertyWrite.request(control: control, label: value) else {
            connectionMessage = "FOCUS value \(value) could not be encoded."
            return
        }
        if control == .focusMode {
            cameraPropertySnapshot = cameraPropertySnapshot.applying(
                property: write.property, data: write.data)
            publishCameraDisplayState()
            syncFocusFromSnapshot()
        }
        enqueueCameraWrite(PendingCameraWrite(picker: .focus, value: value, write: write))
        connectionMessage =
            isMonitorPresented
            ? "Queued FOCUS \(value) for the next live-view safe point."
            : "Queued FOCUS \(value)."
        drainPendingWritesIfIdle()
    }

    /// Queues a command-audio write (sensitivity / input / wind / attenuator / 32-bit float) with
    /// an optimistic snapshot update so the tile reflects the pick immediately; the poll confirms
    /// it. No-op in the demo. `[ZR · verify-on-HW]` — the body refuses some combinations
    /// (XLR adapters, R3D NE with OZO, slow-motion modes); a rejection surfaces via the write
    /// queue's error message and the next poll restores the tile.
    private func applyAudioControl(_ control: PTPCameraControl, value: String) {
        guard !isDemoSession else { return }
        guard let write = PTPCameraPropertyWrite.request(control: control, label: value) else {
            connectionMessage = "AUDIO value \(value) could not be encoded."
            return
        }
        cameraPropertySnapshot = cameraPropertySnapshot.applying(
            property: write.property, data: write.data)
        enqueueCameraWrite(PendingCameraWrite(picker: .audio, value: value, write: write))
        connectionMessage =
            isMonitorPresented
            ? "Queued AUDIO \(value) for the next live-view safe point."
            : "Queued AUDIO \(value)."
        drainPendingWritesIfIdle()
    }

    private func focusModeWriteMessage(requested: String, reported: String?) -> String {
        if PTPCameraPropertyDecoders.isMovieFocusManual(reported),
            !PTPCameraPropertyDecoders.isMovieFocusManual(requested)
        {
            return
                "Camera stayed in manual focus after selecting \(requested). Rotate the lens focus ring back to AF, then try again."
        }
        if let reported, reported != requested {
            return "FOCUS is \(reported) (requested \(requested))."
        }
        return "FOCUS set to \(requested)."
    }

    private func focusModeWriteFailureMessage(requested: String, reported: String?) -> String {
        if PTPCameraPropertyDecoders.isMovieFocusManual(reported),
            !PTPCameraPropertyDecoders.isMovieFocusManual(requested)
        {
            return
                "FOCUS \(requested) was rejected — the lens focus ring has the camera in manual focus. Rotate it back to AF and try again."
        }
        if let reported {
            return "FOCUS \(requested) was rejected by the camera (still \(reported))."
        }
        return "FOCUS \(requested) was rejected by the camera."
    }

    /// WB fine-tune grid position in cells (x = amber(+)/blue(−), y = green(+)/magenta(−),
    /// the camera's 13×13 grid — one A–B cell = 0.5 units, one G–M cell = 0.25, per Nikon's
    /// fine-tuning convention). Seeded from the camera when the Tint tab opens.
    var whiteBalanceTintAB = 0
    var whiteBalanceTintGM = 0
    @ObservationIgnored private var lastCommittedTint: (ab: Int, gm: Int)?

    /// Whether the active WB mode has a mapped movie tune property (Preset slots and Flash don't).
    var whiteBalanceTintAvailable: Bool {
        WhiteBalanceTint.tuneProperty(forWBModeLabel: cameraPropertySnapshot.wbMode ?? "Auto")
            != nil
    }

    /// Operator-facing tint readout ("A1.5 · G0.75" / "Neutral").
    var whiteBalanceTintLabel: String {
        WhiteBalanceTint.label(
            amberBlueCell: whiteBalanceTintAB, greenMagentaCell: whiteBalanceTintGM)
    }

    /// Queues the WB fine-tune write for the current WB mode at the pad's position. Called on
    /// drag end / arrow tap — deduped against the last commit.
    func commitWhiteBalanceTint() {
        guard !isDemoSession else { return }
        let ab = whiteBalanceTintAB
        let gm = whiteBalanceTintGM
        guard lastCommittedTint?.ab != ab || lastCommittedTint?.gm != gm else { return }
        guard
            let write = WhiteBalanceTint.write(
                wbModeLabel: cameraPropertySnapshot.wbMode ?? "Auto",
                amberBlueCell: ab,
                greenMagentaCell: gm
            )
        else { return }
        lastCommittedTint = (ab, gm)
        enqueueCameraWrite(
            PendingCameraWrite(
                picker: .whiteBalance,
                value: "Tint \(whiteBalanceTintLabel)",
                write: write
            )
        )
    }

    /// Seeds the tint pad from the camera: reads the active WB mode's tune property and decodes
    /// the grid coordinate, so the pad opens on the body's actual fine-tune position instead of
    /// assuming neutral.
    func refreshWhiteBalanceTintFromCamera() {
        guard let session = cameraSession, !isDemoSession else { return }
        guard
            let property = WhiteBalanceTint.tuneProperty(
                forWBModeLabel: cameraPropertySnapshot.wbMode ?? "Auto")
        else { return }
        Task { [weak self] in
            guard let data = try? await session.readCameraProperty(property), data.count >= 2
            else { return }
            let raw = UInt16(data[0]) | (UInt16(data[1]) << 8)
            guard let self, let cells = WhiteBalanceTint.cells(fromPropertyValue: raw) else {
                return
            }
            whiteBalanceTintAB = cells.amberBlue
            whiteBalanceTintGM = cells.greenMagenta
            lastCommittedTint = (cells.amberBlue, cells.greenMagenta)
        }
    }

    /// Switches the camera's dual-base ISO circuit (Low ↔ High) by writing `movieBaseISO`
    /// (1 = Low, 2 = High). Queued before the new ISO value so the base is set first.
    func switchBaseISO(highBase: Bool) {
        guard showsDualBaseISOPicker, !isISORecordingLocked else { return }
        let raw: UInt8 = highBase ? 2 : 1
        let write = PTPCameraPropertyWrite(property: .movieBaseISO, data: Data([raw]))
        cameraPropertySnapshot = cameraPropertySnapshot.applying(
            property: write.property, data: write.data)
        publishCameraDisplayState()
        guard !isDemoSession else { return }
        pendingBaseISOHigh = highBase
        enqueueCameraWrite(
            PendingCameraWrite(
                picker: .iso,
                value: highBase ? "High base" : "Low base",
                write: write
            )
        )
    }

    func switchShutterMode(speedMode: Bool) {
        guard !lockedControls.contains(.shutter) else { return }
        let mode: ShutterDisplayMode = speedMode ? .speed : .angle
        let reported = pendingShutterMode ?? cameraPropertySnapshot.shutterMode
        let write = PTPCameraPropertyWrite.shutterMode(mode)
        cameraPropertySnapshot = cameraPropertySnapshot.applying(
            property: write.property, data: write.data)
        publishCameraDisplayState()
        guard !isDemoSession else { return }
        guard reported != mode else { return }
        pendingShutterMode = mode
        let staleProperty: PTPPropertyCode =
            mode == .speed ? .movieShutterSpeed : .movieShutterAngle
        if (cameraControlOptions[staleProperty]?.count ?? 0) <= 1 {
            cameraControlOptions.removeValue(forKey: staleProperty)
        }
        enqueueCameraWrite(
            PendingCameraWrite(picker: .shutter, value: speedMode ? "Speed" : "Angle", write: write)
        )
        connectionMessage =
            "Queued shutter \(speedMode ? "speed" : "angle") mode for the next live-view safe point."
        if case .picker(.shutter) = activePanel, let session = cameraSession {
            Task {
                await refreshShutterModeDependentOptions(session: session, mode: mode)
            }
        }
    }

    /// Queues a movie-VR write ("OFF"/"ON"/"SPORT"). [verify-on-HW]
    func setVibrationReduction(_ label: String) {
        guard let write = PTPCameraPropertyWrite.vibrationReduction(label: label) else { return }
        cameraPropertySnapshot = cameraPropertySnapshot.applying(
            property: write.property, data: write.data)
        publishCameraDisplayState()
        guard !isDemoSession else { return }
        enqueueCameraWrite(
            PendingCameraWrite(picker: .stabilization, value: label, write: write))
        connectionMessage = "Queued VR \(label) for the next live-view safe point."
        drainPendingWritesIfIdle()
    }

    /// Queues an electronic-VR on/off write. [verify-on-HW]
    func setElectronicVR(on: Bool) {
        let write = PTPCameraPropertyWrite.electronicVR(on: on)
        cameraPropertySnapshot = cameraPropertySnapshot.applying(
            property: write.property, data: write.data)
        publishCameraDisplayState()
        guard !isDemoSession else { return }
        enqueueCameraWrite(
            PendingCameraWrite(
                picker: .stabilization, value: on ? "e-VR ON" : "e-VR OFF", write: write))
        connectionMessage = "Queued e-VR \(on ? "ON" : "OFF") for the next live-view safe point."
        drainPendingWritesIfIdle()
    }

    func showPicker(_ picker: CameraPicker, mode: Int = 0) {
        guard !interfaceLocked else { return }
        // Open only from a clean slate; tapping a setting while a picker is already up blends
        // instead (see CaptureSettingButton / handleBackdropTap).
        guard activePanel == nil else { return }
        panelRevealed = false
        // ISO and shutter tabs follow `movieBaseISO` / `movieShutterMode` on appear — not a
        // caller-supplied default — so seeding mode 0 here would reopen on the wrong circuit.
        switch picker {
        case .iso, .shutter:
            pickerInitialMode = nil
        default:
            pickerInitialMode = mode
        }
        activePanel = .picker(picker)
        schedulePanelReveal()
        if picker == .shutter, !isDemoSession, let session = cameraSession {
            let mode: ShutterDisplayMode = shutterPickerModeIndex == 1 ? .speed : .angle
            Task {
                await refreshShutterModeDependentOptions(session: session, mode: mode)
            }
        }
    }

    /// Queues a `MovieTVLockSetting` write to release the camera's shutter speed/angle lock.
    func unlockShutterControlOnCamera() {
        guard !isDemoSession else {
            lockedControls.remove(.shutter)
            connectionMessage = "Shutter control unlocked on camera."
            return
        }
        guard lockedControls.contains(.shutter) else { return }
        pendingShutterLockState = true
        lockedControls.remove(.shutter)
        let write = PTPCameraPropertyWrite.movieTVLock(unlocked: true)
        enqueueCameraWrite(
            PendingCameraWrite(picker: .shutter, value: "Unlocked", write: write))
        connectionMessage =
            "Queued shutter unlock for the next live-view safe point."
        drainPendingWritesIfIdle()
    }

    /// Queues a `MovieTVLockSetting` write to engage the camera's shutter speed/angle lock.
    func lockShutterControlOnCamera() {
        guard !isDemoSession else {
            lockedControls.insert(.shutter)
            connectionMessage = "Shutter control locked on camera."
            return
        }
        guard !lockedControls.contains(.shutter) else { return }
        pendingShutterLockState = false
        lockedControls.insert(.shutter)
        let write = PTPCameraPropertyWrite.movieTVLock(unlocked: false)
        enqueueCameraWrite(
            PendingCameraWrite(picker: .shutter, value: "Locked", write: write))
        connectionMessage =
            "Queued shutter lock for the next live-view safe point."
        drainPendingWritesIfIdle()
    }

    // MARK: - Command monitor readouts

    /// Exposure/shooting program mode for the command grid's MODE tile (Auto/P/S/A/M/U1–U3),
    /// polled from `ExposureProgramMode 0x500E`. Dash until the first poll lands.
    var commandExposureMode: String {
        cameraPropertySnapshot.exposureMode ?? "—"
    }

    /// IBIS / e-shutter summary for the command grid.
    var commandStabilizationLabel: String {
        cameraPropertySnapshot.stabilizationSummary ?? "—"
    }

    /// Movie VR mode ("OFF"/"ON"/"SPORT"), for `StabilizationPickerPanel`'s selection highlight.
    /// `cameraPropertySnapshot` itself stays private — this is a narrow read-only window onto it,
    /// following `commandStabilizationLabel`'s pattern.
    var stabilizationVR: String? {
        cameraPropertySnapshot.vibrationReduction
    }

    /// Electronic-VR on/off state, for `StabilizationPickerPanel`'s selection highlight.
    var stabilizationElectronicVR: String? {
        cameraPropertySnapshot.electronicVR
    }

    /// Tone/gamma inferred from the active codec family.
    var commandToneLabel: String {
        PTPCameraPropertyDecoders.toneLabel(fromCodec: cameraState.codec) ?? "—"
    }

    /// Audio input sensitivity — the ZR-documented property when polled (Auto / 1–20), else the
    /// legacy manual level or preset reads.
    var commandMicrophoneSensLabel: String {
        if let sensitivity = cameraPropertySnapshot.audioSensitivity { return sensitivity }
        if let level = cameraPropertySnapshot.microphoneLevel { return level }
        return cameraPropertySnapshot.microphoneSensitivity ?? "—"
    }

    var commandWindFilterLabel: String {
        cameraPropertySnapshot.windNoiseReduction ?? "—"
    }

    var commandInputAttenuatorLabel: String {
        cameraPropertySnapshot.inputAttenuator ?? "—"
    }

    var commandMicrophoneInputLabel: String {
        if let input = cameraPropertySnapshot.audioInput {
            return input == "Line" ? "LINE" : "MIC"
        }
        guard let sens = cameraPropertySnapshot.microphoneSensitivity else { return "—" }
        return sens == "Off" ? "OFF" : "MIC"
    }

    /// 32-bit float recording on/off (`Movie32BitFloatAudioRecording`).
    var commandAudio32BitFloatLabel: String {
        cameraPropertySnapshot.audio32BitFloat ?? "—"
    }

    /// True when the body reports a manual sensitivity (vs Auto) — tints the Sens tile amber.
    var commandMicrophoneUsesManualLevel: Bool {
        if let sensitivity = cameraPropertySnapshot.audioSensitivity {
            return sensitivity != "Auto"
        }
        return cameraPropertySnapshot.microphoneLevel != nil
    }

    var commandInputAttenuatorOn: Bool {
        cameraPropertySnapshot.inputAttenuator == "ON"
    }

    /// The camera's framing-grid setting (`GridDisplay` 0xD16C), for the Monitor tile. Dash until
    /// the first poll lands.
    var commandGridLabel: String {
        cameraPropertySnapshot.gridDisplay ?? "—"
    }

    /// Slides the just-presented exposure picker up into place on the next run-loop turn — after
    /// SwiftUI has committed the parked (off-screen) frame the slide interpolates up from.
    /// Driven from the model, not the panel's `.onAppear`: on spam-taps SwiftUI interrupts the
    /// outgoing picker's removal and *reuses* the view, which never re-fires `.onAppear` and
    /// leaves the popup parked off-screen. Re-scheduling on every present is immune to that reuse.
    private func schedulePanelReveal() {
        Task { @MainActor in
            await Self.nextRunLoopTick()
            guard activePanel?.managesOwnAppearance == true else { return }
            withAnimation(Self.panelRevealCurve) { panelRevealed = true }
        }
    }

    /// Suspends until the next main run-loop turn. Bouncing through the Dispatch main queue (rather
    /// than `Task.yield()`) resumes us *after* Core Animation's commit, guaranteeing the caller's
    /// pre-animation state has rendered so the subsequent `withAnimation` has a frame to ease from.
    private static func nextRunLoopTick() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    /// Dismisses the active panel. The picker clears *immediately* so the operator can interact at
    /// once; its outgoing copy just fades out fast via the removal transition (no slide-down, no
    /// lock). Other panels close via the shared transition.
    func dismissActivePanel() {
        guard activePanel != nil else { return }
        // Leave `panelRevealed` true so the outgoing copy fades out *in place* — resetting it here
        // animates the panel downward mid-fade. `showPicker` resets it before the next present.
        activePanel = nil
    }

    /// Opens the Media browser from the connection menu, showing on-device cached clips.
    func openCachedMediaLibrary() {
        // Offline `.camera` aggregates every per-serial bucket and keeps only downloaded
        // clips — camera downloads land there, not in the `local` (iPhone import) bucket.
        mediaBrowserSource = .camera
        refreshMediaClips()
        isStandaloneMediaLibraryPresented = true
    }

    /// Closes the Media browser whether it was opened from the monitor or the connection menu.
    func dismissMediaLibrary() {
        isStandaloneMediaLibraryPresented = false
        isStandaloneSettingsPresented = false
        activePanel = nil
    }

    /// Opens Operator Setup from the startup home, landing on the Storage tab (integrations +
    /// cache are what's actionable without a camera).
    func openStandaloneSettings() {
        operatorSettingsTab = .storage
        isStandaloneSettingsPresented = true
    }

    /// Blends an already-open exposure picker to a different setting: the popup stays put and its
    /// contents cross-fade rather than sliding away and back.
    func switchPicker(to picker: CameraPicker) {
        guard activePanel != nil, activePanel != .picker(picker) else { return }
        withAnimation(.easeInOut(duration: 0.14)) {
            activePanel = .picker(picker)
        }
    }

    /// Routes a tap on the picker backdrop. A tap that lands on a *different* capture setting (bottom
    /// bar) or top-deck readout blends the open popup to it; a tap on the already-open setting, or
    /// anywhere else, dismisses.
    func handleBackdropTap(at location: CGPoint) {
        if case .picker(let current) = activePanel {
            if let match = captureSettingFrames.first(where: {
                $0.value.insetBy(dx: -10, dy: -8).contains(location)
            }),
                let picker = CameraPicker.forValueLabel(match.key),
                picker != current
            {
                switchPicker(to: picker)
                return
            }
            if let match = topBarPickerFrames.first(where: {
                $0.value.insetBy(dx: -10, dy: -8).contains(location)
            }) {
                if match.key == current {
                    dismissActivePanel()
                } else {
                    switchPicker(to: match.key)
                }
                return
            }
        }
        dismissActivePanel()
    }

    func showAssist(_ tool: MonitorAssistTool) {
        guard !interfaceLocked else { return }
        if isScopeCapBlocked(tool) {
            scopeCapNotice += 1
            return
        }
        panelRevealed = false
        activePanel = .assist(tool)
        schedulePanelReveal()
    }

    /// Long-press entry from the assist bar: opens a tool's options drawer, or does nothing for a
    /// tool that has no options.
    func presentAssistOptions(_ tool: MonitorAssistTool) {
        guard tool.hasConfiguration else { return }
        showAssist(tool)
    }

    /// Reloads the list of custom-imported LUTs from disk (called when the LUT picker opens).
    func refreshCustomLUTs() {
        customLUTs = lutFileStore.list(.custom)
    }

    /// Imports a `.cube` the operator picked from Files, selects it, and turns the LUT on.
    func importCustomLUT(from url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let stored = try? lutFileStore.importFile(from: url, into: .custom) else { return }
        LUTCubeCache.invalidate(
            forKey: LUTSelection.stored(category: .custom, fileName: stored.fileName).cacheKey)
        refreshCustomLUTs()
        assistConfiguration.selectedLUT = .stored(category: .custom, fileName: stored.fileName)
        setAssist(.lut, visible: true)
    }

    /// Removes a downloaded/imported LUT and reconciles an active selection without changing the
    /// LUT tool's on/off state. Built-in selections are rejected by the file store.
    func deleteStoredLUT(_ lut: StoredLUT, from category: LUTCategory) throws {
        try lutFileStore.remove(lut, from: category)
        LUTCubeCache.invalidate(
            forKey: LUTSelection.stored(category: category, fileName: lut.fileName).cacheKey)
        switch category {
        case .builtIn:
            return
        case .red:
            refreshRedLUTs()
        case .custom:
            refreshCustomLUTs()
        }

        guard
            case .stored(let selectedCategory, let selectedFileName) =
                assistConfiguration.selectedLUT,
            selectedCategory == category,
            selectedFileName == lut.fileName
        else { return }

        switch category {
        case .builtIn:
            assistConfiguration.selectedLUT = .builtIn(.log3G10Rec709)
        case .red:
            assistConfiguration.selectedLUT =
                LUTLibraryIndex.defaultRedLUT(from: redLUTs)
                .map { .stored(category: .red, fileName: $0.fileName) }
                ?? .builtIn(.log3G10Rec709)
        case .custom:
            assistConfiguration.selectedLUT =
                customLUTs.first
                .map { .stored(category: .custom, fileName: $0.fileName) }
                ?? .builtIn(.log3G10Rec709)
        }
    }

    /// Reloads downloaded RED LUTs from disk (called when the LUT picker opens).
    func refreshRedLUTs() {
        redLUTs = lutFileStore.list(.red)
    }

    /// Imports the RED IPP2 zip the WebView downloaded: extracts its cubes, selects a sensible
    /// default (a REC.709 medium-contrast look when present), and turns the LUT on. Returns the
    /// number of LUTs recognized (0 means a failed/empty download) so the caller can report it.
    @discardableResult
    func importRedZip(from url: URL) async -> Int {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        // The unzip walks and writes hundreds of files — run it off the main actor so the
        // "Adding LUTs…" page keeps animating instead of freezing the UI for the extraction.
        let store = lutFileStore
        let stored = await Task.detached(priority: .userInitiated) {
            try? store.importZip(at: url, into: .red)
        }.value
        guard let stored, let chosen = LUTLibraryIndex.defaultRedLUT(from: stored)
        else { return 0 }
        for lut in stored {
            LUTCubeCache.invalidate(
                forKey: LUTSelection.stored(category: .red, fileName: lut.fileName).cacheKey)
        }
        refreshRedLUTs()
        assistConfiguration.selectedLUT = .stored(category: .red, fileName: chosen.fileName)
        setAssist(.lut, visible: true)
        return stored.count
    }

    /// Toggles the MEDIA cell between capacity (GB · %) and duration (Min) readouts.
    func toggleMediaReadout() {
        prefersMediaDuration.toggle()
    }

    /// The MEDIA cell label, respecting the capacity/duration preference.
    var mediaReadout: String {
        if let status = cameraState.mediaStatus {
            return prefersMediaDuration ? status.durationLabel : status.capacityLabel
        }
        return cameraState.media
    }

    func setMovablePanelCenter(_ id: String, _ center: CGPoint, bounds: CGRect) {
        movablePanelCenters[id] = center
        movablePanelPositions[id] = MovablePanelStoredCenter(center: center, in: bounds)
    }

    /// Whether the monitor shell is currently rendering the portrait tree (set by `MonitorShell`);
    /// scopes the fit-mode 2-scope display cap to portrait so landscape stays uncapped.
    var monitorIsPortrait = false
    /// Bumped each time a scope toggle is refused by the fit-mode cap; the shell's toast keys on it.
    var scopeCapNotice = 0
    /// The copy the scope-cap toast shows; names the escape hatch (close one, or pinch to fill).
    let scopeCapNoticeText = "2 scopes max in fit view — close one or pinch to fill"

    /// Count of live-view-active scope tools (waveform/parade/histogram/traffic lights).
    var activeScopeCount: Int {
        MonitorAssistTool.scopeTools.filter {
            preferences.liveViewVisibleAssistTools.contains($0)
        }.count
    }

    /// True only in portrait-fit with ≥2 scopes already active — the state that refuses a 3rd scope.
    var scopeCapActive: Bool {
        monitorIsPortrait && preferences.portraitFeedAspect == .fit16x9 && activeScopeCount >= 2
    }

    /// Whether activating `tool` is blocked by the fit-mode cap (a scope not yet active while the
    /// cap is engaged). Deactivating an already-active scope is never blocked.
    func isScopeCapBlocked(_ tool: MonitorAssistTool) -> Bool {
        scopeCapActive && MonitorAssistTool.scopeTools.contains(tool)
            && !preferences.liveViewVisibleAssistTools.contains(tool)
    }

    func toggleAssist(_ tool: MonitorAssistTool, context: ViewAssistContext = .liveView) {
        guard !interfaceLocked else { return }
        if context == .liveView, isScopeCapBlocked(tool) {
            scopeCapNotice += 1
            return
        }
        AssistToolActivation.toggle(
            tool, context: context, preferences: &preferences, configuration: &assistConfiguration)
    }

    func setAssist(
        _ tool: MonitorAssistTool, visible: Bool, context: ViewAssistContext = .liveView
    ) {
        guard !interfaceLocked else { return }
        if visible, context == .liveView, isScopeCapBlocked(tool) {
            scopeCapNotice += 1
            return
        }
        AssistToolActivation.set(
            tool, visible: visible, context: context, preferences: &preferences,
            configuration: &assistConfiguration)
    }

    func toggleChrome(_ section: DisplayChromeVisibility.Section) {
        preferences.displayChrome.toggle(section)
    }

    func cycleStreamPreset() {
        preferences.streamPreset = preferences.streamPreset.next
        restartLiveViewForQualityChange()
    }

    func cycleQualityBias() {
        preferences.qualityBias = preferences.qualityBias.next
        restartLiveViewForQualityChange()
    }

    func setStreamPreset(_ preset: OperatorPreferences.StreamPreset) {
        guard preferences.streamPreset != preset else { return }
        preferences.streamPreset = preset
        restartLiveViewForQualityChange()
    }

    func setQualityBias(_ bias: OperatorPreferences.QualityBias) {
        guard preferences.qualityBias != bias else { return }
        preferences.qualityBias = bias
        restartLiveViewForQualityChange()
    }

    /// Re-enter live view so a stream-quality change applies now rather than on the next reconnect.
    /// No-op without a live camera (e.g. the demo), or while the feed is deliberately suspended
    /// behind a full-screen panel, where resume will configure the latest requested quality.
    private func restartLiveViewForQualityChange() {
        guard !isDemoSession, isMonitorPresented, !shouldPauseLiveFeed,
            let session = cameraSession
        else { return }
        startLiveView(session: session)
    }

    func applyPickerValue(_ value: String, for picker: CameraPicker) {
        guard !isDemoSession else {
            applyLocalPickerValue(value, for: picker)
            return
        }
        if picker == .shutter, lockedControls.contains(.shutter) { return }
        if picker == .iso, isISORecordingLocked { return }
        guard let cameraControl = picker.cameraControl else {
            connectionMessage =
                "\(picker.title) is not wired to a verified Nikon property write yet."
            return
        }
        // All writes go through the safe-point queue. Resolution/frame-rate writes the *exact*
        // camera-advertised mode for the picked label — never a hand-packed value; a wrong
        // combination like 6K@60 makes the ZR close the connection. A Kelvin white balance
        // enqueues two writes (colour-temperature mode, then the temperature). Recording format is
        // written *during* live view via the standard SetDevicePropValue (0x1016) — no teardown.
        let writes: [PTPCameraPropertyWrite]
        if cameraControl == .resolution {
            let codec = cameraPropertySnapshot.fileType
            guard
                let mode = cameraScreenModes.first(where: {
                    screenSizePresentationLabel(for: $0, codec: codec) == value
                        || $0.label == value
                        || NikonZRRawCropPresentation.bareLabel($0.label)
                            == NikonZRRawCropPresentation.bareLabel(value)
                })
            else {
                connectionMessage =
                    "\(value) isn't a recording mode the camera reported — pick a listed one."
                return
            }
            writes = [PTPCameraPropertyWrite.screenSize(raw: mode.raw)]
        } else if cameraControl == .codec {
            guard let mode = cameraFileTypeModes.first(where: { $0.label == value }) else {
                connectionMessage =
                    "\(value) isn't a codec the camera reported — pick a listed one."
                return
            }
            writes = [PTPCameraPropertyWrite.fileType(raw: mode.raw)]
        } else {
            writes = PTPCameraPropertyWrite.requests(
                control: cameraControl, label: value, snapshot: cameraPropertySnapshot)
        }
        guard !writes.isEmpty else {
            connectionMessage =
                "\(picker.title) value \(value) could not be encoded for \(cameraControl)."
            return
        }
        for write in writes {
            enqueueCameraWrite(PendingCameraWrite(picker: picker, value: value, write: write))
            // Optimistic UI: reflect the selection in the bar immediately; the poll confirms it.
            cameraPropertySnapshot = cameraPropertySnapshot.applying(
                property: write.property, data: write.data)
        }
        publishCameraDisplayState()
        syncFocusFromSnapshot()
        connectionMessage =
            isMonitorPresented
            ? "Queued \(picker.title) \(value) for the next live-view safe point."
            : "Queued \(picker.title) \(value)."
        drainPendingWritesIfIdle()
    }

    private func applyLocalPickerValue(_ value: String, for picker: CameraPicker) {
        let updated = cameraState.values.map { item in
            item.label == picker.valueLabel
                ? CameraValue(label: item.label, value: value, isSettable: item.isSettable)
                : item
        }
        // `updating` preserves untouched fields (including `mediaStatus`); only the changed value,
        // and resolution/codec when those pickers fire, are overridden.
        cameraState = cameraState.updating(
            resolutionFrameRate: picker == .resolution ? value : nil,
            codec: picker == .codec ? value : nil,
            values: updated
        )
    }
}

extension CameraDisplayState {
    func updating(
        recordState: RecordState? = nil,
        resolutionFrameRate: String? = nil,
        codec: String? = nil,
        media: String? = nil,
        cameraBatteryPercent: Int? = nil,
        phoneBatteryPercent: Int? = nil,
        cameraName: String? = nil,
        lens: String? = nil,
        temperature: String? = nil,
        values: [CameraValue]? = nil
    ) -> CameraDisplayState {
        CameraDisplayState(
            recordState: recordState ?? self.recordState,
            timecode: self.timecode,
            resolutionFrameRate: resolutionFrameRate ?? self.resolutionFrameRate,
            codec: codec ?? self.codec,
            media: media ?? self.media,
            liveFPS: self.liveFPS,
            cameraBatteryPercent: cameraBatteryPercent ?? self.cameraBatteryPercent,
            phoneBatteryPercent: phoneBatteryPercent ?? self.phoneBatteryPercent,
            cameraName: cameraName ?? self.cameraName,
            lens: lens ?? self.lens,
            temperature: temperature ?? self.temperature,
            values: values ?? self.values,
            mediaStatus: self.mediaStatus
        )
    }
}

enum CameraPicker: String, CaseIterable, Identifiable {
    case iso
    case shutter
    case iris
    case whiteBalance
    case focus
    case resolution
    case codec
    case stabilization
    case mode
    case audio

    var id: String { rawValue }

    var title: String {
        switch self {
        case .iso: "ISO"
        case .shutter: "Shutter"
        case .iris: "Iris"
        case .whiteBalance: "White Balance"
        case .focus: "Focus"
        case .resolution: "Resolution Framerate"
        case .codec: "Codec"
        case .stabilization: "Stabilization"
        case .mode: "Mode"
        case .audio: "Audio"
        }
    }

    var subtitle: String {
        switch self {
        case .iso: "Sensitivity · dual base"
        case .shutter: "Angle / speed"
        case .iris: "Aperture"
        case .whiteBalance: "Kelvin / preset / tint"
        case .focus: "AF mode · area · subject"
        case .resolution: "Frame rate"
        case .codec: "Recording codec"
        case .stabilization: "VR · electronic VR"
        case .mode: "Exposure program"
        case .audio: "Sensitivity · input · wind · attenuator"
        }
    }

    var valueLabel: String {
        switch self {
        case .iso: "ISO"
        case .shutter: "SHUTTER"
        case .iris: "IRIS"
        case .whiteBalance: "WB"
        case .focus: "FOCUS"
        case .resolution: "RESOLUTION"
        case .codec: "CODEC"
        case .stabilization: "STAB"
        case .mode: "MODE"
        case .audio: "AUDIO"
        }
    }

    /// Reverse lookup from a `valueLabel` (capture-bar / top-deck cell label) to its picker, built
    /// once — the capture bar re-evaluates per frame, so a per-cell linear scan is too hot.
    private static let byValueLabel: [String: CameraPicker] =
        Dictionary(uniqueKeysWithValues: allCases.map { ($0.valueLabel, $0) })

    /// The picker whose `valueLabel` equals `label`, or nil.
    static func forValueLabel(_ label: String) -> CameraPicker? {
        byValueLabel[label]
    }

    /// Whether this picker is presented from the *top* information deck (dropping down) rather than
    /// the bottom capture bar (rising up). Resolution and codec live in the top deck; everything
    /// else is a bottom-bar exposure setting. Both use the identical `PickerPanel` drum — only the
    /// anchor and slide direction differ.
    var isTopBar: Bool {
        switch self {
        case .resolution, .codec: true
        default: false
        }
    }

    var cameraControl: PTPCameraControl? {
        switch self {
        case .iso:
            .iso
        case .shutter:
            .shutter
        case .iris:
            .iris
        case .whiteBalance:
            .whiteBalanceKelvin
        case .codec:
            .codec
        case .resolution:
            .resolution
        case .focus:
            nil
        case .stabilization:
            // Writes go through the model funcs (`setVibrationReduction` / `setElectronicVR`), not
            // `applyPickerValue` — the tile-tap picker never resolves a PTP control from this.
            nil
        case .mode:
            .exposureMode
        case .audio:
            // Five independent camera settings chosen by tab — routed per mode in `applyPicker`,
            // like FOCUS.
            nil
        }
    }

    var options: [String] {
        switch self {
        case .iso: ["500", "640", "800", "1000", "1250", "1600", "3200", "6400"]
        case .shutter: ["150.0°", "172.8°", "180.0°", "210.0°", "270.0°", "1/50", "1/100"]
        case .iris: ["f/1.4", "f/2.0", "f/2.8", "f/4.0", "f/5.6", "f/8.0", "f/11.0"]
        // Nikon K [Choose color temperature]: 2500–10000 K discrete steps
        // (`WhiteBalanceKelvinPolicy` — ZR K [Choose color temperature] dial).
        case .whiteBalance: WhiteBalanceKelvinPolicy.kelvinOptions
        case .focus: ["MF", "AF-S", "AF-C", "AF-F", "Wide-L", "Auto Subject"]
        case .resolution: ["6K · 24p", "6K · 25p", "6K · 30p", "6K · 50p", "4K · 60p"]
        case .codec: ["R3D NE", "N-RAW", "ProRes RAW HQ", "ProRes 422 HQ", "H.265 10-bit"]
        // Stabilization renders its own `StabilizationPickerPanel`, never the flat drum.
        case .stabilization: []
        case .mode: ["Auto", "P", "A", "S", "M", "U1", "U2", "U3"]
        case .audio: ["Auto"] + (1...20).map(String.init)
        }
    }

    /// Segmented mode tabs shown beneath the value wheel (e.g. ANGLE / SPEED). Empty when the
    /// setting is a single flat list.
    var modes: [PickerMode] {
        switch self {
        case .iso:
            [
                PickerMode(
                    title: "Low Base", detail: "800 · 200-3200",
                    options: [
                        "200", "250", "320", "400", "500", "640", "800", "1000", "1250", "1600",
                        "2000", "2500", "3200",
                    ],
                    base: "800"),
                PickerMode(
                    title: "High Base", detail: "6400 · 1600-25600",
                    options: [
                        "1600", "2000", "2500", "3200", "4000", "5000", "6400", "8000", "10000",
                        "12800", "16000", "20000", "25600",
                    ],
                    base: "6400"),
            ]
        case .shutter:
            [
                PickerMode(
                    title: "Angle",
                    options: [
                        "5.6°", "11.2°", "22.5°", "45°", "72°", "86.4°", "90°", "108°", "144°",
                        "172°", "180°", "216°", "288°", "346°", "360°",
                    ],
                    base: "180°"),
                PickerMode(
                    title: "Speed",
                    options: [
                        "1/6", "1/8", "1/10", "1/13", "1/15", "1/20", "1/25", "1/30", "1/40",
                        "1/50", "1/60", "1/80", "1/100", "1/125", "1/160", "1/200", "1/250",
                        "1/320", "1/400", "1/500", "1/640", "1/800", "1/1000", "1/1250", "1/1600",
                        "1/2000", "1/2500", "1/3200", "1/4000", "1/5000", "1/6400", "1/8000",
                        "1/10000", "1/13000", "1/16000",
                    ],
                    base: "1/50"),
            ]
        case .whiteBalance:
            [
                PickerMode(
                    title: "Kelvin",
                    options: WhiteBalanceKelvinPolicy.kelvinOptions,
                    base: WhiteBalanceKelvinPolicy.defaultLabel),
                // Nikon ZR white-balance presets (labels match PTPCameraPropertyDecoders.wbModeNames
                // so they round-trip with the camera's reported mode).
                PickerMode(
                    title: "Preset",
                    options: [
                        "Auto", "Natural auto", "Sunny", "Cloudy", "Shade", "Incandescent",
                        "Fluorescent", "Flash", "Preset",
                    ],
                    base: "Auto"),
                // WB fine-tune grid — rendered as the tint pad, not a drum (empty options).
                PickerMode(title: "Tint", options: [], base: ""),
            ]
        case .focus:
            [
                PickerMode(
                    title: "AF Mode", options: ["MF", "AF-S", "AF-C", "AF-F"], base: "AF-F"),
                PickerMode(
                    title: "Area", options: ["Single", "Wide-S", "Wide-L", "Auto", "Subject"],
                    base: "Single"),
                PickerMode(
                    title: "Subject",
                    options: ["Auto", "People", "Animal", "Bird", "Vehicle", "Airplane"],
                    base: "Auto"),
            ]
        case .audio:
            // Five independent camera audio settings chosen by tab (ZR video-menu sound settings).
            [
                PickerMode(
                    title: "Sens", detail: "Auto · 1-20",
                    options: ["Auto"] + (1...20).map(String.init), base: "Auto"),
                PickerMode(title: "Input", options: ["Microphone", "Line"], base: "Microphone"),
                PickerMode(title: "Wind", options: ["OFF", "ON"], base: "OFF"),
                PickerMode(title: "Atten", options: ["OFF", "ON"], base: "OFF"),
                PickerMode(title: "Float", options: ["OFF", "ON"], base: "OFF"),
            ]
        case .iris, .resolution, .codec, .stabilization, .mode:
            []
        }
    }

    /// The PTP property whose camera-advertised enum should populate a given mode's drum, or nil to
    /// keep the hardcoded options. Flat pickers ignore `mode`. ISO is absent (its circuits switch via
    /// `movieBaseISO` rather than one enum) as is WB Kelvin (a continuous range, not an enumeration);
    /// IRIS / resolution / codec have their own dedicated descriptor paths.
    func optionProperty(forMode mode: Int) -> PTPPropertyCode? {
        switch self {
        case .focus:
            switch mode {
            case 0: return .movieFocusMode
            case 1: return .movieFocusMeteringMode
            case 2: return .movieAFSubjectDetection
            default: return nil
            }
        case .shutter:
            switch mode {
            case 0: return .movieShutterAngle
            case 1: return .movieShutterSpeed
            default: return nil
            }
        case .whiteBalance:
            return mode == 1 ? .movieWhiteBalance : nil
        case .audio:
            switch mode {
            // Sensitivity is Range-form (Auto + 0…20), not an enumeration — keep the hardcoded
            // Auto · 1-20 list rather than asking the descriptor path for enum values.
            case 1: return .audioInputSelection
            case 2: return .movWindNoiseReduction
            case 3: return .movieAttenuator
            case 4: return .movie32BitFloatAudioRecording
            default: return nil
            }
        case .iso, .iris, .resolution, .codec, .stabilization, .mode:
            return nil
        }
    }
}

/// A segmented mode tab under a picker's value wheel, optionally with a small detail line.
struct PickerMode: Equatable, Sendable {
    let title: String
    var detail: String? = nil
    /// The values this mode's drum offers. Empty for modes that don't yet swap the option set; the
    /// drum then falls back to the picker's flat `options`.
    var options: [String] = []
    /// The value to centre on when this mode is selected (e.g. the native base ISO for that circuit).
    var base: String = ""
}

extension MonitorAssistTool {
    var icon: String {
        switch self {
        case .lut: "camera.filters"
        case .peaking: "mountain.2"
        case .falseColor: "circle.lefthalf.filled"
        case .zebra: "line.diagonal"
        case .waveform: "waveform.path"
        case .parade: "chart.bar.xaxis"
        case .histogram: "waveform"
        case .vectorscope: "circle.grid.cross"
        case .trafficLights: "light.beacon.max"
        case .audioMeters: "slider.vertical.3"
        case .guides: "rectangle.dashed"
        case .grid: "grid"
        case .crosshair: "plus"
        case .level: "gyroscope"
        case .desqueeze: "arrow.left.and.right"
        }
    }

    var title: String {
        switch self {
        case .lut: "LUT"
        case .peaking: "Peaking"
        case .falseColor: "False Color"
        case .zebra: "Zebra"
        case .waveform: "Waveform"
        case .parade: "RGB Parade"
        case .histogram: "Histogram"
        case .vectorscope: "Vectorscope"
        case .trafficLights: "Traffic Lights"
        case .audioMeters: "Audio Levels"
        case .guides: "Guides"
        case .grid: "Grid"
        case .crosshair: "Crosshair"
        case .level: "Horizon"
        case .desqueeze: "Desqueeze"
        }
    }
}

struct NativeAppRoot: View {
    @State private var model = NativeAppModel()
    @State private var deliveryCoordinator = MediaDeliveryCoordinator()
    @State private var showsLaunchSplash = true

    var body: some View {
        ZStack {
            ZCBackground()
            if model.isMonitorPresented {
                MonitorExperience()
                    .environment(model)
            } else {
                LinkExperience()
                    .environment(model)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }

            MediaDeliveryGlobalOverlay()
                .environment(deliveryCoordinator)
                .zIndex(150)

            if let destinationTitle = model.internetDestinationPreparationTitle {
                InternetDestinationPreparationOverlay(destinationTitle: destinationTitle)
                    .transition(.opacity)
                    .zIndex(160)
            }

            if showsLaunchSplash {
                LaunchSplashOverlay(isVisible: $showsLaunchSplash)
                    .transition(.opacity)
                    .zIndex(100)
            }
        }
        .environment(model)
        .environment(deliveryCoordinator)
        .task {
            try? await Task.sleep(for: LaunchSplashTiming.visibleDuration)
            withAnimation(.easeOut(duration: LaunchSplashTiming.fadeOutDuration)) {
                showsLaunchSplash = false
            }
        }
        .fullScreenCover(isPresented: standaloneMediaLibraryPresented) {
            // Passes the real device safe area exactly like the monitor host does — with `.zero`
            // the top bar and category strip render under the status bar / Dynamic Island (only
            // visible now that this cover can be portrait; landscape hid it behind the side rail).
            GeometryReader { proxy in
                let insets = proxy.safeAreaInsets
                let islandOnLeading = insets.leading >= insets.trailing
                MediaBrowserView(
                    safeArea: MonitorEdgeInsets(
                        top: Double(insets.top),
                        leading: islandOnLeading ? Double(insets.leading) : 0,
                        bottom: Double(insets.bottom),
                        trailing: islandOnLeading ? 0 : Double(insets.trailing)
                    ).clearingWindowControls
                )
                .environment(model)
                .environment(deliveryCoordinator)
            }
        }
        // Root-level (not inside the LUT picker) so the cover survives the monitor collapsing
        // when the RED internet hop tears the camera session down mid-download.
        .fullScreenCover(isPresented: redDownloadPresented) {
            RedDownloadView { url in await model.importRedZip(from: url) }
                .environment(model)
        }
        // Operator Setup without a camera (startup home → Settings): Frame.io sign-in and the
        // media cache are managed here before/after a shoot. Passes the real device safe area
        // exactly like the monitor host does — with `.zero` the panel rendered wider than its
        // in-monitor twin and the floating close button overlapped the title.
        .fullScreenCover(isPresented: standaloneSettingsPresented) {
            GeometryReader { proxy in
                // iOS reports the landscape Dynamic Island lane on both short edges; zero the
                // clean side (the smaller inset) so the surface hugs that bezel, matching the
                // monitor's `fullScreenPanelSafeArea`.
                let insets = proxy.safeAreaInsets
                let islandOnLeading = insets.leading >= insets.trailing
                OperatorSettingsPanel(
                    safeArea: MonitorEdgeInsets(
                        top: Double(insets.top),
                        leading: islandOnLeading ? Double(insets.leading) : 0,
                        bottom: Double(insets.bottom),
                        trailing: islandOnLeading ? 0 : Double(insets.trailing)
                    ).clearingWindowControls
                )
                .environment(model)
            }
        }
        .fullScreenCover(isPresented: bugReportPresented) {
            BugReportFlowView(
                onDismiss: {
                    model.isBugReportPresented = false
                    model.resumeBugReportInternetHandoffIfNeeded()
                },
                onBrowserHandoff: { model.isBugReportPresented = false }
            )
            .environment(model)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ZCBackground().ignoresSafeArea())
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
        .task {
            // Activate the Apple Watch companion relay once on launch. No-ops when no watch is
            // paired/reachable or WatchConnectivity is unsupported.
            model.activateWatchRelay()
        }
        .task {
            // Suspend the live-view pipeline, keepalive, event drain, and discovery while backgrounded
            // (battery/thermal/jetsam). Lives for the app's lifetime. async/await, not Combine.
            for await _ in NotificationCenter.default.notifications(
                named: UIApplication.didEnterBackgroundNotification)
            {
                model.noteExternalInternetLinkHandoffEnteredBackground()
                model.enterBackground()
            }
        }
        .task {
            // Resume the session's loops (and live view if it was up) on return to the foreground.
            for await _ in NotificationCenter.default.notifications(
                named: UIApplication.willEnterForegroundNotification)
            {
                model.enterForeground()
            }
        }
        .task {
            // Audio-session activation belongs at didBecomeActive, not willEnterForeground (where
            // iOS can still reject it). This also reclaims the media-volume route after prompts.
            model.updateBluetoothShutter()
            for await _ in NotificationCenter.default.notifications(
                named: UIApplication.didBecomeActiveNotification)
            {
                model.updateBluetoothShutter()
                model.resumeExternalInternetLinkHandoffIfNeeded()
            }
        }
        .task {
            for await _ in NotificationCenter.default.notifications(
                named: UIApplication.willResignActiveNotification)
            {
                model.enterInactive()
            }
        }
        .task {
            // Graceful thermal load-shedding: mirror the OS thermal state onto the model so the live
            // loop slows the feed/scope refresh under real heat instead of waiting for the OS to
            // force-throttle mid-take. Read once up front, then follow change notifications.
            model.refreshThermalTier()
            for await _ in NotificationCenter.default.notifications(
                named: ProcessInfo.thermalStateDidChangeNotification)
            {
                model.refreshThermalTier()
            }
        }
        .background {
            #if DEBUG && targetEnvironment(simulator)
                // Mounted from first render so ⌘O can enter demo mode from startup. The handler
                // ignores demo-only commands until the demo session is active. Debug-only, like
                // every demo entry point (see DemoHarness.swift).
                DemoKeyCommands(model: model)
            #endif
        }
        .task {
            // Demo/screenshot staging (ZC_DEMO_* launch env) — a Debug-only no-op elsewhere.
            DemoHarness.applyLaunchEnvironment(to: model)
        }
    }
    private var standaloneMediaLibraryPresented: Binding<Bool> {
        Binding(
            get: { model.isStandaloneMediaLibraryPresented },
            set: { model.isStandaloneMediaLibraryPresented = $0 }
        )
    }

    private var redDownloadPresented: Binding<Bool> {
        Binding(
            get: { model.isRedDownloadPresented },
            set: { model.isRedDownloadPresented = $0 }
        )
    }

    private var standaloneSettingsPresented: Binding<Bool> {
        Binding(
            get: { model.isStandaloneSettingsPresented },
            set: { model.isStandaloneSettingsPresented = $0 }
        )
    }

    private var bugReportPresented: Binding<Bool> {
        Binding(
            get: { model.isBugReportPresented },
            set: { model.isBugReportPresented = $0 }
        )
    }

}

private struct InternetDestinationPreparationOverlay: View {
    let destinationTitle: String

    var body: some View {
        ZStack {
            Color.black.opacity(0.58)
                .ignoresSafeArea()

            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                    .tint(LiveDesign.accent)

                Text("Switching networks…")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(LiveDesign.text)

                Text("Waiting for an internet connection before opening \(destinationTitle).")
                    .font(.system(size: 14))
                    .foregroundStyle(LiveDesign.muted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 34)
            .padding(.vertical, 24)
            .frame(maxWidth: 430)
            .background(LiveDesign.surface, in: RoundedRectangle(cornerRadius: 18))
            .overlay {
                RoundedRectangle(cornerRadius: 18)
                    .stroke(LiveDesign.hairlineStrong, lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.34), radius: 24, y: 12)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Switching networks")
        .accessibilityValue("Waiting to open \(destinationTitle)")
    }
}

// MARK: - Media library (Media page)

extension NativeAppModel {
    /// Filesystem bucket for the currently connected camera (or `local` offline).
    var mediaBucketID: String { MediaClipStore.bucketID(for: connectedIdentity) }

    /// Whether the on-device `local` bucket has any indexed clips.
    var hasLocalMediaClips: Bool {
        !mediaClipStore.list(cameraID: MediaClipStore.localBucketID).isEmpty
    }

    /// Whether any on-device media bucket has a clip fully downloaded to disk (all camera serials + `local`).
    var hasCachedMediaClips: Bool {
        mediaClipStore.listAllCachedClips().contains { isClipDownloaded($0) }
    }

    /// Clips in the active browser source bucket before chip/tab filters.
    var mediaBrowserSourceClips: [MediaClip] {
        mediaClips
    }

    /// Tab + chip filters composed with AND semantics (format/resolution chips OR within type).
    var filteredMediaClips: [MediaClip] {
        var clips = mediaBrowserSourceClips
        let proxyStems = MediaClipFilename.playableProxyStems(
            in: clips.map(\.filename))
        clips = clips.filter {
            MediaClipFilename.shouldShowInMediaBrowser(
                filename: $0.filename,
                playableProxyStems: proxyStems)
        }

        switch mediaCategoryTab {
        case .all: break
        case .videos:
            clips = clips.filter { MediaClipFilename.isPlayableProxy($0.filename) }
        case .photos:
            clips = clips.filter { MediaClipFilename.isPhoto($0.filename) }
        case .favorites:
            clips = clips.filter(\.isFavorite)
        }

        if !mediaFormatFilters.isEmpty {
            clips = clips.filter { clip in
                mediaFormatFilters.contains { $0.matches(clip) }
            }
        }

        if !mediaResolutionFilters.isEmpty {
            clips = clips.filter { clip in
                guard let bucket = clip.resolutionBucket else { return false }
                return mediaResolutionFilters.contains(bucket)
            }
        }

        if mediaTodayOnly {
            clips = clips.filter(\.isCapturedToday)
        }

        if let slot = mediaStorageSlotFilter {
            clips = clips.filter { $0.storageID == slot }
        }

        if !isConnected {
            clips = clips.filter { isClipDownloaded($0) }
        }

        return MediaClipSorting.sort(clips, order: mediaSortOrder)
    }

    /// On-disk cache size for the active browser source bucket.
    var mediaBrowserCacheByteCount: UInt64 {
        let bucket =
            mediaBrowserSource == .camera ? mediaBucketID : MediaClipStore.localBucketID
        return mediaClipStore.cachedByteCount(cameraID: bucket)
    }

    /// Short transport label for the Media browser status readout.
    var mediaBrowserTransportLabel: String {
        if isDemoSession { return "DEMO" }
        guard isConnected else { return "OFFLINE" }
        return "WIFI"
    }

    /// Storage fragment for the status line (card free space or iPhone cache size).
    var mediaBrowserStorageStatusLabel: String {
        if mediaBrowserSource == .camera, let status = cameraState.mediaStatus {
            return "\(status.gigabytesFree) GB"
        }
        let freeAcrossSlots = mediaStorageSlots.reduce(0) { $0 + $1.freeGigabytes }
        if freeAcrossSlots > 0 { return "\(freeAcrossSlots) GB" }
        return MediaClipFormatting.byteLabel(mediaBrowserCacheByteCount)
    }

    /// Active sheet/chip filters (format, resolution, today, storage slot) — not category tabs.
    var mediaActiveFilterCount: Int {
        MediaBrowserFilterMetrics.activeCount(
            formatFilters: mediaFormatFilters,
            resolutionFilters: mediaResolutionFilters,
            todayOnly: mediaTodayOnly,
            storageSlotFilter: mediaStorageSlotFilter
        )
    }

    /// Clears popup filter state; category tab and sort are unchanged.
    func clearMediaFilters() {
        mediaFormatFilters = []
        mediaResolutionFilters = []
        mediaTodayOnly = false
        mediaStorageSlotFilter = nil
    }

    /// Cycles newest → oldest → name.
    func cycleMediaSortOrder() {
        mediaSortOrder = mediaSortOrder.next
    }

    func toggleMediaFormatFilter(_ filter: MediaFormatFilter) {
        if mediaFormatFilters.contains(filter) {
            mediaFormatFilters.remove(filter)
        } else {
            mediaFormatFilters.insert(filter)
        }
    }

    func toggleMediaResolutionFilter(_ bucket: MediaResolutionBucket) {
        if mediaResolutionFilters.contains(bucket) {
            mediaResolutionFilters.remove(bucket)
        } else {
            mediaResolutionFilters.insert(bucket)
        }
    }

    /// Refreshes per-slot storage cards from the connected camera (no-op when offline).
    func refreshMediaStorageSlots() async {
        guard let session = cameraSession, isConnected else {
            mediaStorageSlots = []
            return
        }
        let slots = await session.readAllStorageInfo()
        let cameraName = cameraState.cameraName
        mediaStorageSlots = slots.enumerated().map { index, slot in
            MediaStorageSlotDisplay(
                storageID: slot.id,
                slotNumber: index + 1,
                cameraName: cameraName,
                usedGigabytes: slot.info.gigabytesUsed,
                freeGigabytes: slot.info.gigabytesFree,
                totalGigabytes: slot.info.gigabytesTotal
            )
        }
    }

    /// Reloads the library list from the on-disk cache + index for the active browser bucket.
    func refreshMediaClips() {
        if !isConnected {
            switch mediaBrowserSource {
            case .camera:
                // Offline camera browsing spans every per-serial bucket; `filteredMediaClips`
                // keeps only fully downloaded entries.
                mediaClips = mediaClipStore.listAllCachedClips()
            case .iPhone:
                mediaClips = mediaClipStore.list(cameraID: MediaClipStore.localBucketID)
            }
            return
        }
        let bucket =
            mediaBrowserSource == .camera ? mediaBucketID : MediaClipStore.localBucketID
        mediaClips = mediaClipStore.list(cameraID: bucket)
    }

    /// Cancels any in-flight listing pass and starts a fresh camera discovery.
    func scheduleFetchClipsFromCamera() {
        mediaFetchTask?.cancel()
        mediaFetchGeneration += 1
        let generation = mediaFetchGeneration
        mediaFetchTask = Task { await fetchClipsFromCamera(generation: generation) }
    }

    /// Total cached clip bytes across every camera bucket on disk (Settings → Storage readout).
    func totalMediaCacheByteCount() -> UInt64 {
        mediaClipStore.allBucketIDs().reduce(0) { total, bucket in
            total + mediaClipStore.cachedByteCount(cameraID: bucket)
        }
    }

    /// Clears cached clip files and thumbnails for EVERY bucket (Settings → Storage), preserving
    /// each bucket's `index.json` (favorites, handles, upload flags) for re-fetch.
    func clearAllMediaCaches() {
        cancelClipStream()
        mediaDownloadProgress.removeAll()
        for bucket in mediaClipStore.allBucketIDs() {
            mediaClipStore.clearCache(cameraID: bucket)
        }
        refreshMediaClips()
    }

    /// Clears on-disk clip cache for the active Media browser source bucket. Cancels any in-flight
    /// stream first; `index.json` metadata (favorites, handles, Frame.io/export flags) is preserved.
    func clearMediaCache() {
        cancelClipStream()
        mediaDownloadProgress.removeAll()

        let bucket =
            mediaBrowserSource == .camera ? mediaBucketID : MediaClipStore.localBucketID
        mediaClipStore.clearCache(cameraID: bucket)
        refreshMediaClips()
    }

    func isClipDownloaded(_ clip: MediaClip) -> Bool {
        guard
            let url = try? mediaClipStore.localURL(
                cameraID: clip.cameraID, filename: clip.filename)
        else { return false }
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        guard clip.sizeBytes > 0 else { return true }
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let onDisk = (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
        return onDisk >= clip.sizeBytes
    }

    func clipLocalURL(_ clip: MediaClip) -> URL? {
        try? mediaClipStore.localURL(cameraID: clip.cameraID, filename: clip.filename)
    }

    /// Lists movie clips on the connected camera and merges them into the library index (metadata
    /// only — clip bytes stream on demand). Delta-syncs against the cached `index.json` so
    /// unchanged handles skip `GetObjectInfo`; discovers in batches so the grid updates
    /// incrementally without blocking the main thread. Thumbnails fetch on demand when cells
    /// appear. Safe no-op with no session. [ZR · verify-on-HW]
    private func fetchClipsFromCamera(generation: Int) async {
        guard let session = cameraSession else { return }
        mediaFetchInProgress = true
        mediaFetchListedCount = 0
        defer {
            // A cancelled pass finishing late must not clear the state of a newer pass.
            if mediaFetchGeneration == generation {
                mediaFetchInProgress = false
                mediaFetchListedCount = 0
                mediaFetchTask = nil
            }
        }

        let bucket = mediaBucketID
        if mediaBrowserSource == .camera {
            refreshMediaClips()
        }

        let cached = mediaClipStore.list(cameraID: bucket)
        let cachedByHandle = Dictionary(
            uniqueKeysWithValues: cached.compactMap { clip in
                clip.handle.map { ($0, clip) }
            }
        )
        let cachedHandleSet = Set(cachedByHandle.keys)

        let listedHandles = await session.listMediaObjectHandles()
        if Task.isCancelled { return }

        // Removal detection always runs against the FULL listing — a scoped pass must never
        // read "absent from my category" as "deleted from the card".
        let delta = MediaClipDiscoveryDelta.compute(
            cachedHandles: cachedHandleSet,
            cameraHandles: listedHandles
        )

        // The pass itself is scoped to the active sidebar category: Videos fetches only videos,
        // Photos only stills. Other categories' metadata is NOT enumerated here — each tab runs
        // its own delta pass on selection (mediaCategoryTab.didSet).
        let cameraHandles = await scopedHandles(
            listedHandles,
            for: mediaCategoryTab,
            cachedByHandle: cachedByHandle,
            session: session
        )
        if Task.isCancelled { return }

        if !delta.removedHandles.isEmpty {
            let removedFilenames = mediaClipStore.applyCameraRemoval(
                cameraID: bucket,
                removedHandles: delta.removedHandles,
                hasLocalFile: { isClipDownloaded($0) }
            )
            if mediaBrowserSource == .camera, bucket == mediaBucketID {
                applyRemovedClipsToMemory(
                    removedFilenames: removedFilenames,
                    clearedHandles: delta.removedHandles
                )
            }
        }

        var listedCount = 0
        var pendingBatch: [MediaClip] = []
        var r3dIndex = R3DClipIndex()
        seedR3DIndex(from: cached, into: &r3dIndex)
        let batchSize = 32
        let flushInterval = Duration.milliseconds(120)
        var lastFlush = ContinuousClock.now

        func flushPendingBatch(force: Bool = false) {
            guard force || !pendingBatch.isEmpty else { return }
            let shouldFlush =
                force
                || pendingBatch.count >= batchSize
                || lastFlush.duration(to: .now) >= flushInterval
            guard shouldFlush else { return }

            let batch = pendingBatch
            pendingBatch.removeAll(keepingCapacity: true)
            lastFlush = .now
            mediaClipStore.upsertBatch(batch, cameraID: bucket)
            if mediaBrowserSource == .camera, bucket == mediaBucketID {
                mergeDiscoveredClipsIntoMemory(batch)
            }
            mediaFetchListedCount = listedCount
        }

        let passTab = mediaCategoryTab
        var learnedOffTab = 0
        for objectHandle in cameraHandles {
            if Task.isCancelled { break }

            let record: MediaClip
            if delta.reuseHandles.contains(objectHandle.handle),
                let cachedClip = cachedByHandle[objectHandle.handle]
            {
                record = cachedClip
            } else {
                guard
                    let camera = await session.fetchMediaClip(
                        handle: objectHandle.handle, storageID: objectHandle.storageID)
                else { continue }
                guard
                    let builtRecord = await buildMediaClipRecord(
                        from: camera, bucket: bucket, r3dIndex: &r3dIndex, session: session)
                else { continue }
                record = builtRecord
            }

            // Learn-then-skip: a record whose fetched type doesn't match the tab (possible when
            // the body doesn't honour format-filtered listing) is still written to the index —
            // so it is never fetched again on any tab — but isn't listed or counted here.
            let matchesTab: Bool
            switch passTab {
            case .videos: matchesTab = record.mediaKind == .video
            case .photos: matchesTab = record.mediaKind == .photo
            case .all, .favorites: matchesTab = true
            }
            pendingBatch.append(record)
            if matchesTab {
                listedCount += 1
                mediaLibraryLogger.debug(
                    "listed clip \(listedCount, privacy: .public): \(record.filename, privacy: .private(mask: .hash))"
                )
            } else {
                learnedOffTab += 1
            }
            flushPendingBatch()
            if (listedCount + learnedOffTab) % batchSize == 0 {
                await Task.yield()
            }
        }

        flushPendingBatch(force: true)
        mediaLibraryLogger.info(
            "delta sync listed \(listedCount, privacy: .public) clip(s) on this tab — card objects: \(delta.reuseHandles.count, privacy: .public) reused, \(delta.fetchHandles.count, privacy: .public) fetched (\(learnedOffTab, privacy: .public) learned off-tab), \(delta.removedHandles.count, privacy: .public) removed"
        )
    }

    /// The handles a listing pass should process for the active sidebar category, newest first.
    /// ponytail: "newest" = descending object handle — handles grow monotonically on Nikon
    /// bodies; switch to capture-date ordering if a body proves otherwise.
    ///
    /// Membership: cached records decide by filename (exact — a warm pass on the Videos tab
    /// never touches the card's hundreds of stills); new, never-fetched handles are scoped by
    /// the camera's format-filtered listing when the body honours it. When it doesn't (rejected
    /// op, or the partition comes back empty), new handles stay IN the pass — their type is
    /// unknowable without `GetObjectInfo`, and dropping them would blank the tab on bodies that
    /// ignore specification-by-format. [ZR · verify-on-HW]
    private func scopedHandles(
        _ handles: [MediaObjectHandle],
        for tab: MediaCategoryTab,
        cachedByHandle: [UInt32: MediaClip],
        session: NativeCameraSession
    ) async -> [MediaObjectHandle] {
        let newestFirst = handles.sorted { $0.handle > $1.handle }
        let wantsVideo: Bool
        switch tab {
        case .videos: wantsVideo = true
        case .photos: wantsVideo = false
        case .all, .favorites: return newestFirst
        }

        var scoped: [MediaObjectHandle] = []
        var unknown: [MediaObjectHandle] = []
        for handle in newestFirst {
            if let cached = cachedByHandle[handle.handle] {
                if (cached.mediaKind == .video) == wantsVideo { scoped.append(handle) }
            } else {
                unknown.append(handle)
            }
        }
        guard !unknown.isEmpty else { return scoped }

        // Partition NEW handles by querying BOTH categories: a body that ignores the format
        // parameter returns the same set for every query, so "the two partitions differ" is the
        // honor signal — a single query can't distinguish "camera filtered" from "camera dumped
        // everything". When honored: keep wanted handles plus the unclassified remainder
        // (R3D/NEF/HEIF ride on vendor codes outside both maps — the loop learns those and
        // files non-matching ones without listing them). When not honored (or rejected): all
        // unknowns stay in, and the loop's learn-then-skip keeps the wrong type off this tab.
        let wantedFormats = wantsVideo ? MediaObjectFormats.video : MediaObjectFormats.photo
        let otherFormats = wantsVideo ? MediaObjectFormats.photo : MediaObjectFormats.video
        if let wantedPartition = try? await session.listMediaObjectHandles(
            formats: wantedFormats),
            let otherPartition = try? await session.listMediaObjectHandles(formats: otherFormats)
        {
            let wantedSet = Set(wantedPartition.map(\.handle))
            let otherSet = Set(otherPartition.map(\.handle))
            if wantedSet != otherSet {
                scoped.append(
                    contentsOf: unknown.filter {
                        wantedSet.contains($0.handle) || !otherSet.contains($0.handle)
                    })
            } else {
                scoped.append(contentsOf: unknown)
            }
        } else {
            scoped.append(contentsOf: unknown)
        }
        return scoped.sorted { $0.handle > $1.handle }
    }

    private func seedR3DIndex(from clips: [MediaClip], into index: inout R3DClipIndex) {
        for clip in clips {
            if MediaClipFilename.isR3D(clip.filename),
                let width = clip.pixelWidth, let height = clip.pixelHeight
            {
                index.registerR3D(filename: clip.filename, width: width, height: height)
            } else if MediaClipFilename.isPlayableProxy(clip.filename) {
                index.noteProxy(clip.filename)
            }
        }
    }

    private func applyRemovedClipsToMemory(
        removedFilenames: Set<String>,
        clearedHandles: Set<UInt32>
    ) {
        if !removedFilenames.isEmpty {
            mediaClips.removeAll { removedFilenames.contains($0.filename) }
        }
        for index in mediaClips.indices {
            guard let handle = mediaClips[index].handle, clearedHandles.contains(handle) else {
                continue
            }
            mediaClips[index].handle = nil
            mediaClips[index].storageID = nil
        }
    }

    /// Builds one `MediaClip` from a PTP discovery record, including optional R3D header parsing.
    private func buildMediaClipRecord(
        from camera: NativeCameraSession.CameraClip,
        bucket: String,
        r3dIndex: inout R3DClipIndex,
        session: NativeCameraSession
    ) async -> MediaClip? {
        guard let filename = MediaClipFilename.safeCameraBasename(camera.info.filename) else {
            mediaLibraryLogger.error("ignored camera media object with unsafe filename")
            return nil
        }
        var pixelWidth = camera.info.imagePixWidth
        var pixelHeight = camera.info.imagePixHeight

        if MediaClipFilename.isR3D(filename), pixelWidth == 0 || pixelHeight == 0 {
            if let header = try? await session.getPartialObject(
                handle: camera.handle,
                offset: 0,
                length: UInt32(R3DHeaderParser.minimumHeaderBytes)),
                let parsed = R3DHeaderParser.parseDimensions(from: header)
            {
                pixelWidth = parsed.width
                pixelHeight = parsed.height
                mediaLibraryLogger.debug(
                    "R3D header parse \(filename, privacy: .private(mask: .hash)): \(parsed.width, privacy: .public)×\(parsed.height, privacy: .public)"
                )
            }
        }

        var record = MediaClip(
            cameraID: bucket, filename: filename, handle: camera.handle,
            storageID: camera.storageID, sizeBytes: UInt64(camera.info.compressedSize),
            captureDate: camera.info.captureDate,
            pixelWidth: pixelWidth > 0 ? pixelWidth : nil,
            pixelHeight: pixelHeight > 0 ? pixelHeight : nil)

        if MediaClipFilename.isR3D(filename), let width = record.pixelWidth,
            let height = record.pixelHeight
        {
            r3dIndex.registerR3D(filename: filename, width: width, height: height)
            linkR3DSourceToExistingProxies(
                r3dFilename: filename, width: width, height: height, bucket: bucket)
        } else if MediaClipFilename.isPlayableProxy(filename) {
            r3dIndex.noteProxy(filename)
            if let sibling = r3dIndex.siblingForProxy(filename) {
                record.sourcePixelWidth = sibling.width
                record.sourcePixelHeight = sibling.height
                record.linkedR3DFilename = sibling.filename
            }
        }
        return record
    }

    /// Merges a discovery batch into the in-memory grid list without re-reading `index.json`.
    private func mergeDiscoveredClipsIntoMemory(_ batch: [MediaClip]) {
        guard !batch.isEmpty else { return }
        var byFilename = Dictionary(uniqueKeysWithValues: mediaClips.map { ($0.filename, $0) })
        for incoming in batch {
            if let existing = byFilename[incoming.filename] {
                byFilename[incoming.filename] = MediaClipStore.mergeCameraDiscovery(
                    existing: existing, incoming: incoming)
            } else {
                byFilename[incoming.filename] = incoming
            }
        }
        mediaClips = Array(byFilename.values)
    }

    /// Backfills R3D source dimensions onto proxy clips indexed before their R3D sibling arrived.
    private func linkR3DSourceToExistingProxies(
        r3dFilename: String,
        width: UInt32,
        height: UInt32,
        bucket: String
    ) {
        let stem = MediaClipFilename.stem(of: r3dFilename)
        let candidates =
            mediaBrowserSource == .camera && bucket == mediaBucketID
            ? mediaClips
            : mediaClipStore.list(cameraID: bucket)
        for clip in candidates {
            guard MediaClipFilename.isPlayableProxy(clip.filename),
                MediaClipFilename.stem(of: clip.filename) == stem,
                clip.linkedR3DFilename == nil
            else { continue }
            mediaClipStore.update(cameraID: bucket, filename: clip.filename) {
                $0.sourcePixelWidth = width
                $0.sourcePixelHeight = height
                $0.linkedR3DFilename = r3dFilename
            }
            if mediaBrowserSource == .camera, bucket == mediaBucketID,
                let index = mediaClips.firstIndex(where: { $0.filename == clip.filename })
            {
                mediaClips[index].sourcePixelWidth = width
                mediaClips[index].sourcePixelHeight = height
                mediaClips[index].linkedR3DFilename = r3dFilename
            }
        }
    }

    /// On-disk thumbnail URL when the camera thumb (or a prior fetch) is cached for this clip.
    func clipThumbnailURL(_ clip: MediaClip) -> URL? {
        guard
            let url = try? mediaClipStore.thumbURL(
                cameraID: clip.cameraID, filename: clip.filename)
        else { return nil }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Starts streaming one clip from the camera for progressive playback. No-op when already cached
    /// or when another stream for the same clip is in flight.
    func startClipStream(_ clip: MediaClip) {
        guard isConnected, !isClipDownloaded(clip), clip.handle != nil else { return }
        if clipStreamClipID == clip.id, let clipStreamTask, !clipStreamTask.isCancelled { return }
        cancelClipStream()
        clipStreamClipID = clip.id
        clipStreamTask = Task { await streamClip(clip) }
    }

    /// Stops the active clip stream (e.g. when the player dismisses). Partial bytes are kept so the
    /// next open can resume.
    func cancelClipStream() {
        clipStreamTask?.cancel()
        clipStreamTask = nil
        clipStreamClipID = nil
    }

    /// Whether this clip is the one currently streaming from the camera.
    func isClipStreaming(_ clip: MediaClip) -> Bool {
        clipStreamClipID == clip.id && mediaDownloadProgress[clip.id] != nil
    }

    /// Byte-fraction of this clip cached locally (0…1), or `nil` when fully cached or unknown.
    /// During an active camera stream prefers the live `mediaDownloadProgress` value; otherwise
    /// derives from on-disk size so partially cached clips show buffer state before resuming.
    func clipBufferedFraction(_ clip: MediaClip) -> Double? {
        let total = clip.sizeBytes
        guard total > 0 else { return nil }
        let cached = mediaClipStore.cachedByteCount(
            cameraID: clip.cameraID, filename: clip.filename)
        if cached >= total { return nil }
        let byteFraction = min(1.0, Double(cached) / Double(total))
        if let live = mediaDownloadProgress[clip.id] {
            return min(1.0, max(byteFraction, live))
        }
        return byteFraction > 0 ? byteFraction : nil
    }

    /// Fetches a camera thumbnail for one clip when a grid cell needs it. Coalesces duplicate
    /// requests and serializes PTP `GetThumb` traffic.
    func ensureThumbnail(for clip: MediaClip) async {
        guard clip.handle != nil else { return }
        guard !mediaClipStore.hasThumbnail(cameraID: clip.cameraID, filename: clip.filename)
        else { return }
        await withCheckedContinuation { continuation in
            thumbnailWaiters[clip.id, default: []].append(continuation)
            if thumbnailQueuedIDs.insert(clip.id).inserted {
                thumbnailQueue.append(clip)
                // Bound the backlog during a fast scroll: drop the oldest requests (their cells
                // have long since scrolled away and re-request on reappear) instead of fetching
                // every clip the finger ever flew past over the camera link.
                while thumbnailQueue.count > Self.maxQueuedThumbnailFetches {
                    let dropped = thumbnailQueue.removeFirst()
                    thumbnailQueuedIDs.remove(dropped.id)
                    resumeThumbnailWaiters(for: dropped.id)
                }
            }
            startThumbnailWorkerIfNeeded()
        }
    }

    /// Cap on queued thumbnail fetches — roughly two screenfuls of the densest grid.
    private static let maxQueuedThumbnailFetches = 48

    /// Stops the thumbnail worker. With `resumingWaiters` (session teardown), also clears the
    /// queue and resumes every waiting cell so no continuation stays suspended for a session that
    /// will never deliver. Without it (backgrounding), the queue and waiters are kept so
    /// `startThumbnailWorkerIfNeeded()` resumes exactly where it left off on foreground.
    private func cancelThumbnailWork(resumingWaiters: Bool) {
        thumbnailWorkerGeneration += 1
        thumbnailFetchTask?.cancel()
        thumbnailFetchTask = nil
        guard resumingWaiters else { return }
        thumbnailQueue.removeAll()
        thumbnailQueuedIDs.removeAll()
        let waiters = thumbnailWaiters
        thumbnailWaiters = [:]
        for continuations in waiters.values {
            for continuation in continuations { continuation.resume() }
        }
    }

    private func startThumbnailWorkerIfNeeded() {
        guard thumbnailFetchTask == nil, !thumbnailQueue.isEmpty else { return }
        thumbnailWorkerGeneration += 1
        let generation = thumbnailWorkerGeneration
        thumbnailFetchTask = Task {
            // A cancelled predecessor finishing its in-flight fetch must not clear a successor's
            // task handle — only the current generation may release the single-flight slot.
            defer {
                if thumbnailWorkerGeneration == generation { thumbnailFetchTask = nil }
            }
            while !Task.isCancelled, !thumbnailQueue.isEmpty {
                let clip = thumbnailQueue.removeFirst()
                thumbnailQueuedIDs.remove(clip.id)
                await fetchThumbnail(for: clip)
                resumeThumbnailWaiters(for: clip.id)
                await Task.yield()
            }
        }
    }

    private func resumeThumbnailWaiters(for clipID: String) {
        let waiters = thumbnailWaiters.removeValue(forKey: clipID) ?? []
        for waiter in waiters { waiter.resume() }
    }

    private func fetchThumbnail(for clip: MediaClip) async {
        guard let session = cameraSession else { return }
        guard let handle = clip.handle else { return }
        guard !thumblessClipIDs.contains(clip.id) else { return }
        guard !mediaClipStore.hasThumbnail(cameraID: clip.cameraID, filename: clip.filename)
        else { return }
        if let data = try? await session.getThumb(handle: handle) {
            // Validate before caching: the body occasionally returns truncated/garbage thumb
            // bytes (seen on-device as repeated ImageIO 'JPEG err=7' spam); caching them would
            // poison the cell decode on every realisation. Invalid data is remembered in-memory
            // so the clip isn't re-fetched every scroll this session — a fresh launch retries.
            if UIImage(data: data) != nil {
                try? mediaClipStore.saveThumbnail(
                    cameraID: clip.cameraID, filename: clip.filename, data: data)
            } else {
                thumblessClipIDs.insert(clip.id)
            }
        }
    }

    private func streamClip(_ clip: MediaClip) async {
        if isClipDownloaded(clip) { return }
        if mediaDownloadInFlight.contains(clip.id) {
            while mediaDownloadInFlight.contains(clip.id), !isClipDownloaded(clip) {
                try? await Task.sleep(for: .milliseconds(50))
                if Task.isCancelled { return }
            }
            return
        }
        guard let session = cameraSession, let handle = clip.handle else { return }
        mediaDownloadInFlight.insert(clip.id)
        defer { mediaDownloadInFlight.remove(clip.id) }
        let bucket = clip.cameraID
        let total = clip.sizeBytes
        do {
            let (fileHandle, startOffset) = try mediaClipStore.openForStreaming(
                cameraID: bucket, filename: clip.filename)
            defer { try? fileHandle.close() }
            var offset = startOffset
            let chunk: UInt32 = 4 << 20  // 4 MiB — fewer round-trips over PTP
            if total > 0, UInt64(offset) >= total {
                mediaDownloadProgress[clip.id] = nil
                return
            }
            mediaDownloadProgress[clip.id] =
                total > 0 ? min(1.0, Double(offset) / Double(total)) : 0
            while !Task.isCancelled {
                let data = try await session.getPartialObject(
                    handle: handle, offset: offset, length: chunk)
                if data.isEmpty { break }
                try fileHandle.write(contentsOf: data)
                offset = offset &+ UInt32(data.count)
                if total > 0 {
                    mediaDownloadProgress[clip.id] = min(1.0, Double(offset) / Double(total))
                }
                if data.count < Int(chunk) { break }
                if total > 0, UInt64(offset) >= total { break }
            }
            if Task.isCancelled {
                mediaDownloadProgress[clip.id] = nil
                return
            }
            mediaDownloadProgress[clip.id] = nil
            mediaLibraryLogger.info(
                "streamed \(clip.filename, privacy: .private(mask: .hash)) (\(offset, privacy: .public) bytes)"
            )
        } catch {
            if Task.isCancelled {
                mediaDownloadProgress[clip.id] = nil
                return
            }
            mediaDownloadProgress[clip.id] = nil
            try? mediaClipStore.removeLocalFile(cameraID: bucket, filename: clip.filename)
            mediaLibraryLogger.error(
                "streamClip(\(clip.filename, privacy: .private(mask: .hash))) failed: \(error.localizedDescription, privacy: .private(mask: .hash))"
            )
        }
        refreshMediaClips()
    }

    /// Downloads a clip into the local cache and reports whether it's fully on disk. Awaits the
    /// same single-flight stream the grid/viewer use (`streamClip` serialises concurrent callers
    /// per clip), so cells show the same progress ring. Sequential by design — the PTP data
    /// channel is one pipe. Used by the delivery pre-pass so shared on-camera clips auto-cache.
    func cacheClipFromCamera(_ clip: MediaClip) async -> Bool {
        if isClipDownloaded(clip) { return true }
        guard isConnected, clip.handle != nil else { return false }
        await streamClip(clip)
        return isClipDownloaded(clip)
    }

    /// Toggles a clip's favorite flag and persists it.
    func toggleClipFavorite(_ clip: MediaClip) {
        mediaClipStore.update(cameraID: clip.cameraID, filename: clip.filename) {
            $0.isFavorite.toggle()
        }
        refreshMediaClips()
    }

    /// Resolves the operator's currently selected LUT to a colour cube, for baking onto media
    /// playback preview / export. Returns nil if a stored `.cube` can't be loaded.
    func currentLUTCube() -> CubeLUT? {
        switch assistConfiguration.selectedLUT {
        case .builtIn(let look): return look.cube()
        case .stored(let category, let fileName):
            return lutFileStore.cube(category: category, fileName: fileName)
        }
    }

    /// Sets a clip's export status in the index and refreshes the list.
    func setClipExportStatus(_ status: ExportStatus, for clip: MediaClip) {
        mediaClipStore.update(cameraID: clip.cameraID, filename: clip.filename) {
            $0.exportStatus = status
        }
        refreshMediaClips()
    }
}

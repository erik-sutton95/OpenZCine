import AVFAudio
import MonitorUI
import Network
import Observation
import OpenCineAppKit
import OpenCineAppKitApple
import OpenCineApple
import OpenCineCameraControls
import OpenCineCore
import OpenCineFrameIO
import OpenCineMedia
import OpenCineRelay
import OpenCineRelayApple
import OpenZCineCore
import SwiftUI
import UIKit
import ZIPFoundation
import os

import struct MonitorPresentation.MonitorEdgeInsets
import enum MonitorPresentation.MonitorMediaLayout
import enum MonitorPresentation.MonitorSettingsTab
import enum MonitorPresentation.MonitorStorageReadoutFormat
import enum MonitorPresentation.MonitorThumbnailSize
import enum MonitorPresentation.MonitorWatcherPasscodeRule
import struct OpenCineCameraVocabulary.CaptureCodecColorChoice
import struct OpenCineCameraVocabulary.CaptureCodecColorChoices
import struct OpenCineCameraVocabulary.ControlCapabilities
import struct OpenCineCameraVocabulary.CustomLUTArchiveEntry
import class OpenCineCameraVocabulary.CustomLUTStore
import class OpenCineCameraVocabulary.LUTPreferences
import struct OpenCineCameraVocabulary.MonitorLutPackImportResult

private let connectionLogger = Logger(
    subsystem: "OpenZCine",
    category: "camera-connection"
)

private let proactiveWiFiJoinLogger = Logger(
    subsystem: "OpenZCine",
    category: "proactive-wifi-join"
)

func logConnection(_ message: String) {
    #if DEBUG
        // Rich camera diagnostics are developer-only; Release logs retain only a stable hash.
        connectionLogger.error("\(message, privacy: .public)")
        ConnectionLogTap.shared.log(message)
    #else
        connectionLogger.error("\(message, privacy: .private(mask: .hash))")
    #endif
}

#if DEBUG
    /// Streams every `logConnection` line to a developer machine on the LAN, so a live hardware
    /// repro can be watched without the operator copying Console output between devices.
    ///
    /// Debug-only diagnostics, inert unless a sink is advertised and Local Network access was
    /// already granted (lines wait in the bounded buffer until then, so the tap never raises the
    /// system prompt at launch, ahead of the wizard's permissions step): browses for
    /// `_ozc-logtap._tcp` (advertise one with `dns-sd -R tap _ozc-logtap._tcp local 9099` and
    /// listen on 9099), connects unicast TCP, and streams timestamped device-prefixed lines.
    /// Attachment itself is evidence: finding the sink takes the same mDNS browse the relay
    /// list uses, so a device that streams here but lists no broadcasts has a relay-specific
    /// problem, while a device that never attaches cannot browse (or was denied Local Network
    /// permission) at all.
    // SAFETY: `@unchecked Sendable` — all mutable state is confined to `queue`, and every
    // Network callback is delivered on `queue`.
    private final class ConnectionLogTap: @unchecked Sendable {
        static let shared = ConnectionLogTap()

        private let queue = DispatchQueue(label: "com.opencapture.openzcine.log-tap")
        private var browser: NWBrowser?
        private var connection: NWConnection?
        private var sinkEndpoint: NWEndpoint?
        private var lastConnectAttempt: Date?
        private var pending: [String] = []
        private var started = false
        /// Latched on any browse failure: diagnostics must never destabilize the patient. The
        /// undeclared-service NoAuth failure did exactly that — on device, the policy hit can
        /// interrupt the app's OTHER local-network flows, including live camera sockets.
        private var disabled = false
        private let devicePrefix = ProcessInfo.processInfo.hostName
        private let timeFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss.SSS"
            return formatter
        }()

        func log(_ message: String) {
            queue.async {
                guard !self.disabled else { return }
                self.startIfNeeded()
                let line =
                    "[\(self.devicePrefix)] \(self.timeFormatter.string(from: Date())) \(message)\n"
                self.pending.append(line)
                // Bounded so an unattended session cannot grow without limit; diagnostics can
                // afford to drop the oldest lines.
                if self.pending.count > 400 { self.pending.removeFirst(self.pending.count - 400) }
                self.reconnectIfNeeded()
                self.flush()
            }
        }

        private func startIfNeeded() {
            guard !started, LocalNetworkAccess.grantRemembered() else { return }
            started = true
            let browser = NWBrowser(
                for: .bonjour(type: "_ozc-logtap._tcp", domain: nil), using: .tcp)
            browser.stateUpdateHandler = { [weak self] state in
                connectionLogger.error("log-tap browse state=\(String(describing: state))")
                if case .failed = state {
                    guard let self else { return }
                    self.disabled = true
                    self.browser?.cancel()
                    self.browser = nil
                    self.connection?.cancel()
                    self.connection = nil
                    self.pending.removeAll()
                }
            }
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                guard let self else { return }
                connectionLogger.error("log-tap browse results=\(results.count)")
                self.sinkEndpoint = results.first?.endpoint
                self.reconnectIfNeeded()
            }
            browser.start(queue: queue)
            self.browser = browser
        }

        private func reconnectIfNeeded() {
            guard connection == nil, let endpoint = sinkEndpoint else { return }
            if let last = lastConnectAttempt, Date().timeIntervalSince(last) < 5 { return }
            lastConnectAttempt = Date()
            let connection = NWConnection(to: endpoint, using: .tcp)
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                connectionLogger.error("log-tap connection state=\(String(describing: state))")
                switch state {
                case .ready:
                    let hello =
                        "[\(self.devicePrefix)] log tap attached "
                        + "os=\(ProcessInfo.processInfo.operatingSystemVersionString)\n"
                    self.pending.insert(hello, at: 0)
                    self.flush()
                case .failed, .cancelled:
                    self.connection = nil
                default:
                    break
                }
            }
            connection.start(queue: queue)
            self.connection = connection
        }

        private func flush() {
            guard let connection, connection.state == .ready, !pending.isEmpty else { return }
            let payload = pending.joined()
            pending.removeAll()
            connection.send(
                content: Data(payload.utf8), completion: .contentProcessed { _ in })
        }
    }
#endif

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

extension MonitorDisplayChrome {
    /// The retired Nikon layout, section by section. The DISP button and the legacy side-rail
    /// switch have no shared twin; sections Nikon never offered keep the shared default.
    init(seededFrom legacy: DisplayChromeVisibility) {
        self.init()
        statusBar = legacy.isVisible(.statusBar)
        toolBar = legacy.isVisible(.assistToolbar)
        cameraValues = legacy.isVisible(.cameraValues)
        lockButton = legacy.isVisible(.lockButton)
        batteries = legacy.isVisible(.batteryIndicators)
        recReadout = legacy.isVisible(.recReadout)
        timecode = legacy.isVisible(.timecodeReadout)
        format = legacy.isVisible(.resolutionReadout)
        codec = legacy.isVisible(.codecReadout)
        storage = legacy.isVisible(.mediaReadout)
        fps = legacy.isVisible(.fpsReadout)
        railRecord = legacy.isVisible(.railRecord)
        railMedia = legacy.isVisible(.railMedia)
        railSettings = legacy.isVisible(.railSettings)
        focusBox = legacy.isVisible(.focusBox)
    }
}

/// Persists app-local operator preferences and assist-overlay configuration across sessions
/// (`UserDefaults`, both `Codable`). Only view-assist/chrome state lives here — never camera
/// exposure, resolution, format, or codec, which the connected camera always owns.
enum PreferencesStore {
    private static let preferencesKey = "operatorPreferences.v1"
    private static let assistConfigKey = "assistConfiguration.v1"

    /// The shared HDR display choice (A2-31), on the common key Pocket and Insta use too.
    static var hdrDisplay: Bool {
        get { MonitorOperatorPreferences(storage: .standard, keys: commonKeys).hdrDisplay }
        set {
            MonitorOperatorPreferences(storage: .standard, keys: commonKeys).hdrDisplay = newValue
        }
    }

    private static let commonKeys = MonitorOperatorPreferences.Keys(
        keepScreenAwake: "OpenZCine.KeepScreenAwake", hdrDisplay: "OpenZCine.HDRDisplay",
        recordConfirmation: "OpenZCine.RecordConfirmation", haptics: "OpenZCine.HapticsEnabled",
        cacheOriginals: "OpenZCine.CacheFullResolution", remoteShutter: "OpenZCine.RemoteShutter")
    /// The blob field the remote shutter choice lived in before the shared key (product ruling
    /// 2026-10-16). It moves to ``commonKeys`` once and is then removed from the blob.
    private static let retiredRemoteShutterField = "bluetoothShutterEnabled"

    static func loadPreferences() -> OperatorPreferences {
        loadPreferences(storage: .standard)
    }

    static func loadPreferences(storage: UserDefaults) -> OperatorPreferences {
        let data = storage.data(forKey: preferencesKey)
        if let data, let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let legacyValues = [
                (commonKeys.keepScreenAwake, legacyBool(raw["keepScreenAwake"])),
                (
                    commonKeys.recordConfirmation,
                    legacyBool(raw["recordConfirmationEnabled"])
                        ?? legacyBool(raw["recordHoldEnabled"])
                ),
                (commonKeys.haptics, legacyBool(raw["hapticsEnabled"])),
            ]
            for (key, value) in legacyValues where storage.object(forKey: key) == nil {
                if let value { storage.set(value, forKey: key) }
            }
            migrateRetiredRemoteShutter(raw, storage: storage)
        }
        var decoded = data.map { OperatorPreferencesDocument(data: $0).decoded() } ?? .defaults
        let common = MonitorOperatorPreferences(storage: storage, keys: commonKeys)
        decoded.keepScreenAwake = common.keepScreenAwake
        decoded.recordConfirmationEnabled = common.recordConfirmation
        decoded.hapticsEnabled = common.haptics
        decoded.bluetoothShutterEnabled = common.remoteShutter
        decoded.reconcileDispOrder()
        return decoded
    }

    /// Moves the stored remote shutter choice to the shared key once: a value already under the
    /// shared key wins, so a second launch changes nothing. The blob field is removed only after
    /// it was read as a Bool; unreadable values and every other field stay.
    private static func migrateRetiredRemoteShutter(_ raw: [String: Any], storage: UserDefaults) {
        guard let stored = raw[retiredRemoteShutterField], let value = legacyBool(stored),
            let key = commonKeys.remoteShutter
        else { return }
        if storage.object(forKey: key) == nil {
            storage.set(value, forKey: key)
        }
        var remaining = raw
        remaining.removeValue(forKey: retiredRemoteShutterField)
        if let data = try? JSONSerialization.data(withJSONObject: remaining, options: [.sortedKeys])
        {
            storage.set(data, forKey: preferencesKey)
        }
    }

    /// Retires readable choices from the blob; an unreadable future value remains untouched.
    private static func withoutRetiredRemoteShutter(_ data: Data) -> Data {
        guard var raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            legacyBool(raw[retiredRemoteShutterField]) != nil,
            raw.removeValue(forKey: retiredRemoteShutterField) != nil,
            let stripped = try? JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys])
        else { return data }
        return stripped
    }

    static func save(_ preferences: OperatorPreferences) {
        save(preferences, previous: loadPreferences(), storage: .standard)
    }

    static func save(
        _ preferences: OperatorPreferences, previous: OperatorPreferences, storage: UserDefaults
    ) {
        let common = MonitorOperatorPreferences(storage: storage, keys: commonKeys)
        if preferences.keepScreenAwake != previous.keepScreenAwake {
            common.keepScreenAwake = preferences.keepScreenAwake
        }
        if preferences.recordConfirmationEnabled != previous.recordConfirmationEnabled {
            common.recordConfirmation = preferences.recordConfirmationEnabled
        }
        if preferences.hapticsEnabled != previous.hapticsEnabled {
            common.haptics = preferences.hapticsEnabled
        }
        if preferences.bluetoothShutterEnabled != previous.bluetoothShutterEnabled {
            common.remoteShutter = preferences.bluetoothShutterEnabled
        }
        // These common choices now belong to their shared keys. Preserve their legacy bytes.
        var legacy = preferences
        legacy.keepScreenAwake = previous.keepScreenAwake
        legacy.recordConfirmationEnabled = previous.recordConfirmationEnabled
        legacy.hapticsEnabled = previous.hapticsEnabled
        legacy.bluetoothShutterEnabled = previous.bluetoothShutterEnabled
        guard legacy != previous else { return }
        guard
            let original = storage.data(forKey: preferencesKey)
                ?? (try? JSONEncoder().encode(OperatorPreferences.defaults)).map(
                    withoutRetiredRemoteShutter),
            let data = try? OperatorPreferencesDocument(data: original).updating(
                legacy, previous: previous)
        else { return }
        storage.set(withoutRetiredRemoteShutter(data), forKey: preferencesKey)
    }

    private static func legacyBool(_ raw: Any?) -> Bool? {
        guard let raw,
            let data = try? JSONSerialization.data(
                withJSONObject: raw, options: [.fragmentsAllowed])
        else { return nil }
        return try? JSONDecoder().decode(Bool.self, from: data)
    }

    /// The shared per-DISP chrome. A mode without a stored layout seeds once from the video side
    /// of the retired per-capture layouts, so an operator's arrangement carries over.
    static func display(seededFrom preferences: OperatorPreferences) -> MonitorDisplayPreferences {
        let display = MonitorDisplayPreferences(
            storage: .standard,
            keys: .init(
                live: "monitorDisplay.live.v1", clean: "monitorDisplay.clean.v1",
                command: "monitorDisplay.command.v1"))
        for mode in MonitorDisplayMode.allCases where !display.hasStoredLayout(for: mode) {
            guard let legacy = DispMode(rawValue: mode.rawValue) else { continue }
            let seeded = MonitorDisplayChrome(
                seededFrom: preferences.chrome(for: legacy, capture: .video))
            switch mode {
            case .live: display.live = seeded
            case .clean: display.clean = seeded
            case .command: display.command = seeded
            }
        }
        return display
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

    /// The DISP 3 tile order through the shared owner, under the key and JSON shape this store
    /// always wrote, so an operator's arrangement carries over. Retired names drop out and tiles
    /// added later join at the end.
    static func commandTileOrder(storage: UserDefaults = .standard)
        -> MonitorCommandTileOrderPreferences<CommandTileKind>
    {
        MonitorCommandTileOrderPreferences(
            storage: storage, key: commandGridOrderKey, all: CommandTileKind.allCases)
    }

    static let assistToolUsage = MonitorToolUsagePreferences(
        storage: .standard, key: "assistToolUsage.v1")

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

    private static let mfScrubEnabledKey = "mfDriveScrubEnabled"

    /// Whether the live-view focus scrub strip is enabled — operator toggle in the FOCUS popup,
    /// available in video and photo mode, **default off**.
    ///
    /// The absent-key fallback IS the migration: the key is only ever written by the toggle's
    /// `didSet`, so "no key" means the operator never chose, and they land on the new default.
    /// An operator who deliberately switched the dial on has `true` stored and keeps it; one who
    /// switched it off has `false` stored and keeps that. No migration record needed.
    static func loadMFScrubEnabled() -> Bool {
        UserDefaults.standard.object(forKey: mfScrubEnabledKey) as? Bool ?? false
    }

    static func saveMFScrubEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: mfScrubEnabledKey)
    }

    static func loadMediaThumbnailSize() -> MonitorThumbnailSize {
        guard let raw = UserDefaults.standard.string(forKey: mediaThumbnailSizeKey),
            let size = MonitorThumbnailSize(rawValue: raw)
        else { return .medium }
        return size
    }

    static func saveMediaThumbnailSize(_ size: MonitorThumbnailSize) {
        UserDefaults.standard.set(size.rawValue, forKey: mediaThumbnailSizeKey)
    }

    static func loadMediaBrowserLayout() -> MonitorMediaLayout {
        guard let raw = UserDefaults.standard.string(forKey: mediaBrowserLayoutKey),
            let layout = MonitorMediaLayout(rawValue: raw)
        else { return .grid }
        return layout
    }

    static func saveMediaBrowserLayout(_ layout: MonitorMediaLayout) {
        UserDefaults.standard.set(layout.rawValue, forKey: mediaBrowserLayoutKey)
    }

    private static let movablePanelPositionsKey = "movablePanelPositions.v1"
    private static let proactiveWiFiJoinUserDeniedAtKey = "proactiveWiFiJoinUserDeniedAt.v1"

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

/// The generated catalogue has no editable stored files. Category policy stays with app composition.
private enum NikonLUTCategoryError: LocalizedError {
    case generatedLooksReadOnly
    var errorDescription: String? { "Built-in LUTs cannot be changed or deleted." }
}

extension CustomLUTStore {
    /// Preserve the existing Nikon document path and saved category names.
    convenience init(root: URL? = nil) {
        let documents =
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        self.init(
            root: root ?? documents.appendingPathComponent("luts", isDirectory: true),
            preferences: LUTPreferences(storage: .standard, namespace: "OpenZCine"))
    }

    private func storedCategory(_ category: LUTCategory) throws -> CustomLUTStore {
        guard category != .builtIn else { throw NikonLUTCategoryError.generatedLooksReadOnly }
        return try self.category(named: category.rawValue.lowercased())
    }

    func list(_ category: LUTCategory) -> [StoredCustomLUT] {
        (try? storedCategory(category).list()) ?? []
    }

    @discardableResult
    func importFile(from source: URL, into category: LUTCategory) throws -> StoredCustomLUT {
        try storedCategory(category).importFile(from: source)
    }

    /// A downloaded LUT pack (a zip or a lone `.cube`) through the shared pack import: each cube
    /// is validated and installed on its own, refusals are counted. ZIPFoundation owns decoding
    /// only; the shared store owns bounds, parse and replacement.
    @discardableResult
    func importPack(at file: URL, into category: LUTCategory) throws -> MonitorLutPackImportResult {
        let store = try storedCategory(category)
        return store.importPack(file: file) { accept in
            let archive = try Archive(url: file, accessMode: .read)
            for entry in archive where entry.type != .directory {
                try accept(
                    CustomLUTArchiveEntry(
                        path: entry.path,
                        uncompressedSize: UInt64(entry.uncompressedSize),
                        isSymbolicLink: entry.type == .symlink,
                        extract: { consume in
                            let checksum = try archive.extract(
                                entry, bufferSize: 64 * 1024, consumer: consume)
                            guard checksum == entry.checksum else {
                                throw Archive.ArchiveError.invalidCRC32
                            }
                        }))
            }
        }
    }

    func cube(category: LUTCategory, fileName: String) -> CubeLUT? {
        try? storedCategory(category).cube(fileName: fileName)
    }

    func remove(_ lut: StoredCustomLUT, from category: LUTCategory) throws {
        try storedCategory(category).remove(lut)
    }
}

enum EventChannelDiagnosticPolicy {
    static func shouldRecordUnexpectedEnd(isCancelled: Bool, ownsSession: Bool) -> Bool {
        !isCancelled && ownsSession
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

        /// A camera link is being paired, prepared, recovered or held.
        var holdsCameraPath: Bool {
            switch self {
            case .disconnected, .scanning: false
            case .pairing, .reconnecting, .preparingLiveView, .connected: true
            }
        }

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

    /// Closed diagnostic token for a failed connection attempt by transport.
    private func connectionFailureDiagnostic(
        transportKind: CameraTransportKind,
        rejectedInitiator: Bool = false
    ) -> AppDiagnosticEvent {
        if rejectedInitiator { return .connectionPairingFailed }
        switch transportKind {
        case .usb: return .connectionUsbFailed
        case .ptpIP: return .connectionPtpFailed
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
        /// Camera control over the device's data port — USB-C, or Lightning through Apple's
        /// camera adapter.
        case usbC
        /// The picture over an HDMI capture device on that same port. Video only: a capture device
        /// digitises a signal, it does not speak to the camera.
        case hdmiCapture
        /// Both devices already on someone else's network — a set router, a travel router, house
        /// Wi-Fi. The app joins nothing and hosts nothing here; it only watches discovery.
        case wiFiNetwork

        var id: String { rawValue }

        /// Whether this path reaches the camera through the device's data port.
        var isCableLink: Bool { self == .usbC || self == .hdmiCapture }

        /// Whether the app itself joins the camera's own access point on this path.
        ///
        /// The single discriminator for every camera-AP mechanism — the Wi-Fi join and the
        /// credential scanner. Written as one question rather than a list of exclusions, because
        /// the list is what went wrong before: each new path had to remember to opt out.
        var joinsCameraAccessPoint: Bool { self == .cameraAccessPoint }

        var title: String {
            switch self {
            case .cameraAccessPoint: "Camera's Access Point"
            case .phoneHotspot: "Phone's Hotspot"
            case .usbC: "USB-C"
            case .hdmiCapture: "HDMI capture"
            case .wiFiNetwork: "Wi-Fi"
            }
        }

        /// Short label for the nested option pills inside the Cable Link card.
        var optionTitle: String {
            switch self {
            case .usbC: DeviceUSBConnector.current == .lightning ? "Lightning" : "USB-C"
            case .hdmiCapture: "HDMI"
            case .cameraAccessPoint: "Camera AP"
            case .phoneHotspot: "Phone Hotspot"
            case .wiFiNetwork: "Wi-Fi"
            }
        }

        /// Closed diagnostic breadcrumb when the operator picks this path.
        var diagnosticEvent: AppDiagnosticEvent {
            switch self {
            case .cameraAccessPoint: .connectionPathCameraAp
            case .phoneHotspot: .connectionPathPhoneHotspot
            case .usbC: .connectionPathUsb
            case .hdmiCapture: .connectionPathHDMICapture
            case .wiFiNetwork: .connectionPathWiFiNetwork
            }
        }

        var detail: String {
            switch self {
            case .cameraAccessPoint:
                "The camera creates a Wi‑Fi network — join it from your iPhone."
            case .phoneHotspot:
                "Turn on Personal Hotspot — the camera joins your iPhone's network."
            case .usbC:
                DeviceUSBConnector.current == .lightning
                    ? "Connect through Apple's Lightning to USB camera adapter — a USB-C to Lightning cable can't host the camera."
                    : "Plug the camera into this device with a USB-C cable."
            case .hdmiCapture:
                "Feed the camera's HDMI output into a USB capture device — full-quality picture, no camera control."
            case .wiFiNetwork:
                "Both devices already on the same network — a set router, or the house Wi-Fi."
            }
        }

        var systemImage: String {
            switch self {
            case .cameraAccessPoint: "antenna.radiowaves.left.and.right"
            case .phoneHotspot: "personalhotspot"
            case .usbC: "cable.connector"
            case .hdmiCapture: "display"
            case .wiFiNetwork: "wifi.router"
            }
        }
    }

    /// The choose step's cards. Both group several paths, so the operator picks a kind of
    /// connection first and the specific one second — two questions that are much easier apart
    /// than one flat list of five.
    enum FirstPairCard: String, CaseIterable, Sendable, Identifiable {
        case wireless
        case cableLink

        var id: String { rawValue }

        var title: String {
            switch self {
            case .wireless: "Wireless"
            case .cableLink: "Cable Link"
            }
        }

        /// The paths this card offers, in the order shown.
        ///
        /// HDMI capture is absent on iPhone rather than shown-and-disabled: `AVCaptureDeviceTypeExternal`
        /// is UVC-on-iPad, so on a phone it is not a path that might work later — it is not a path.
        /// Offering it there would only teach the operator to try something that cannot exist.
        @MainActor var options: [FirstPairTransportMethod] {
            switch self {
            case .wireless: [.cameraAccessPoint, .phoneHotspot, .wiFiNetwork]
            case .cableLink:
                UVCVideoSource.isSupportedHardware ? [.usbC, .hdmiCapture] : [.usbC]
            }
        }

        static func card(for method: FirstPairTransportMethod) -> FirstPairCard {
            method.isCableLink ? .cableLink : .wireless
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

        static var stepCount: Int { allCases.count }

        /// The steps a path actually visits, in order.
        ///
        /// Everything below derives from this one list — the count, the displayed number, the
        /// final step, advancing and retreating — so a path declares its shape here and nowhere
        /// else. It replaced four hand-written switches plus a hardcoded `transport ==
        /// .cameraAccessPoint ? 4 : 5`, which silently assumed every path visited a contiguous run
        /// of the enum. Android's `PairingFlowState` has always been written this way; the fourth
        /// path is what made the divergence expensive.
        static func sequence(
            transport: FirstPairTransportMethod,
            skipsPermissions: Bool
        ) -> [FirstPairWizardStep] {
            // The path is chosen first, so a permission is asked only for a path that uses it:
            // Local Network for the wireless paths, nothing for a cable (USB keeps its own
            // control-access request, HDMI capture its own video-access request). Android's
            // `PairingFlow` has the same order.
            var steps: [FirstPairWizardStep] = [.chooseTransport]
            if !skipsPermissions, !transport.isCableLink { steps.append(.permissions) }
            steps.append(.prepareCamera)
            // HDMI capture is a cable and a capture device: there is no network to set up.
            if transport != .hdmiCapture { steps.append(.connectNetwork) }
            // Camera-AP pairing ends at the network step — joining the camera's Wi-Fi is the last
            // operator action, and connect then runs against the fixed AP address.
            if transport != .cameraAccessPoint { steps.append(.discoverAndPair) }
            return steps
        }

        /// Total visible steps for the active transport and whether the permissions step is omitted.
        static func stepCount(
            transport: FirstPairTransportMethod,
            skipsPermissions: Bool
        ) -> Int {
            sequence(transport: transport, skipsPermissions: skipsPermissions).count
        }

        /// 1-based step index shown in the wizard chrome; 0 when this step is not on the path.
        func displayNumber(transport: FirstPairTransportMethod, skipsPermissions: Bool) -> Int {
            let steps = Self.sequence(transport: transport, skipsPermissions: skipsPermissions)
            guard let index = steps.firstIndex(of: self) else { return 0 }
            return index + 1
        }

        /// Whether this step is the last one for the chosen transport.
        func isFinalStep(for transport: FirstPairTransportMethod) -> Bool {
            Self.sequence(transport: transport, skipsPermissions: false).last == self
        }

        /// The next step on this path, or nil at the end of it.
        func next(
            transport: FirstPairTransportMethod, skipsPermissions: Bool
        ) -> FirstPairWizardStep? {
            let steps = Self.sequence(transport: transport, skipsPermissions: skipsPermissions)
            guard let index = steps.firstIndex(of: self), index + 1 < steps.count else {
                return nil
            }
            return steps[index + 1]
        }

        /// The previous step on this path, or nil at the start of it.
        func previous(
            transport: FirstPairTransportMethod, skipsPermissions: Bool
        ) -> FirstPairWizardStep? {
            let steps = Self.sequence(transport: transport, skipsPermissions: skipsPermissions)
            guard let index = steps.firstIndex(of: self), index > 0 else { return nil }
            return steps[index - 1]
        }
    }

    /// When true the permissions step is omitted from the wizard and step numbering is adjusted.
    var firstPairWizardSkipsPermissions = false

    /// Password collected from the operator before joining a secured camera access point.
    struct CameraWiFiPasswordSubmission: Equatable, Sendable {
        let ssid: String?
        let password: String
    }

    var firstPairWizardStep: FirstPairWizardStep = .chooseTransport
    var firstPairTransportMethod: FirstPairTransportMethod = .cameraAccessPoint

    /// Forces the first-pair wizard even when saved cameras already exist — set when the operator
    /// explicitly starts pairing a new camera. The wizard is the sole pairing surface.
    var isPairingNewCamera = false

    /// The operator chose the camera list over the wizard while owning zero saved cameras.
    /// A watcher-only device joins broadcasts from the list and may never pair anything, so
    /// once it has been there, an empty camera list must not bounce it back into the wizard.
    /// Mirrors `shell.camerasChosen` (the shell's route); kept here because discovery reads it
    /// while the shell's cameras model is still being made.
    var showsCameraListWithoutSavedCameras = false

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
        case media
        case settings

        var id: String {
            switch self {
            case .picker(let picker): "picker-\(picker.id)"
            case .assist(let tool): "assist-\(tool.id)"
            case .media: "media"
            case .settings: "settings"
            }
        }

        /// Panels presented as a full-screen surface (Operator Setup, Media, Tool Library) rather
        /// than a floating popup: the monitor rails hide behind these so the panel reads
        /// edge-to-edge, while picker/assist popups keep the rails (and feed) visible.
        var coversFullScreen: Bool {
            switch self {
            case .settings, .media: return true
            case .picker, .assist: return false
            }
        }
    }

    var connection: ConnectionState = .disconnected {
        didSet {
            syncReportingCameraPath()
            publishWatchState()
            guard oldValue != connection else { return }
            AppDiagnostics.shared.record(connection.diagnosticEvent)
            if let evidence = LocalNetworkAccess.evidence(
                connected: connection == .connected, transport: cameraSession?.transportKind)
            {
                LocalNetworkAccess.shared.note(evidence, source: "camera link connected")
            }
        }
    }
    /// Phased lifecycle for the connection progress sheet.
    var connectionPhase: CameraConnectionPhase = .idle
    /// The connect in flight belongs to a shared-flow attempt: its card or pair page shows it.
    var connectionProgressUsesCard = false
    /// Why the funnel's last connect failed, for the shared flow's typed failure: the thrown
    /// error, or a reason the funnel surfaced without one (a camera Wi-Fi join).
    var lastConnectError: (any Error)?
    var lastConnectFailureReason: ConnectionFailure.Reason?
    @ObservationIgnored lazy var nikonPort = NativeNikonPort(model: self)
    /// Held for the Nikon port's connect in flight: releasing the model releases it, which ends
    /// that attempt (observation never reports a deallocation).
    @ObservationIgnored var nikonConnectReleaseWatch: NikonConnectReleaseWatch?

    /// The watch owns the task handle, rather than the task owning this model across native waits.
    func watchNikonConnectRelease(_ onRelease: @escaping @Sendable () -> Void) {
        let task = establishmentTask
        nikonConnectReleaseWatch?.disarm()
        nikonConnectReleaseWatch = NikonConnectReleaseWatch {
            task?.cancel()
            onRelease()
        }
    }
    @ObservationIgnored lazy var cameras = makeCamerasModel()
    /// The root (`AppShell`): the camera monitor, the shared pair page (a NEARBY camera's Pair)
    /// and the standalone Media and Settings covers.
    @ObservationIgnored lazy var shell = makeShellModel()
    /// Retires a released native capture gesture when its source or monitor presentation changes.
    private(set) var operatorQuickPresentationRevision = UUID()

    func retireOperatorQuickPresentation() {
        operatorQuickPresentationRevision = UUID()
    }

    var diagnosticsShareItem: MonitorDiagnosticsShareItem?
    var diagnosticsErrorMessage: String?
    var isPreparingDiagnostics = false

    /// The app's own connect (the wizard's, a camera-AP join, a setup watch armed here, the
    /// internet-hop rejoin) is running outside a shared-flow attempt: the pair page shows it.
    var showsAppConnectProgress: Bool {
        isConnectionProgressPresented && !connectionProgressUsesCard
    }

    /// Builds the local diagnostics report for the share sheet.
    func shareDiagnostics() {
        guard !isPreparingDiagnostics else { return }
        isPreparingDiagnostics = true
        Task {
            defer { isPreparingDiagnostics = false }
            do {
                diagnosticsShareItem = MonitorDiagnosticsShareItem(
                    url: try await AppDiagnostics.shared.makeReport())
            } catch {
                diagnosticsErrorMessage = error.localizedDescription
            }
        }
    }
    var isConnectionProgressPresented = false
    var connectionProgressDeviceName = ""
    var connectionProgressIsUSB = false
    /// How the attempt on screen reaches the camera, for copy that would otherwise name the wrong
    /// thing — "check your network" over a cable sends the operator to inspect something this
    /// attempt never touches. `nil` before a path is known, which keeps the network wording.
    var connectionProgressPathKind: CameraPath.Kind?
    /// Failure text pinned for the progress sheet when a failure is surfaced. The sheet must not
    /// read the live `connectionMessage` for this — the discovery loop overwrites that field on
    /// every iteration, which put stale copy ("Found 1 camera.") on the failed card.
    var connectionFailureDetail = ""
    /// Live establishment step ("Reading the camera's card… 40%", "Step: app-control switch…"),
    /// written ONLY by the connect machinery — unlike `connectionMessage`, which the discovery loop
    /// overwrites — so the progress sheet can show real progress instead of a frozen "Connecting".
    var connectionStageDetail = ""
    @ObservationIgnored private var connectionProgressShowsFailure = false
    /// Whether an established session dropped and is being recovered behind a preserved monitor.
    /// Drives the recovery affordance over the held frame (`MonitorRecoveryOverlay`).
    private(set) var sessionRecovery: SessionRecoveryState = .idle
    /// True once the attempt-1 card grace has run out (the card shows immediately from attempt 2).
    /// Model-owned deliberately: this timer lived in the overlay as a `.task`, but the overlay
    /// renders NOTHING until the card shows and SwiftUI does not run `.task` on content-less
    /// views — the timer that was supposed to reveal the card could never start, which left a
    /// stalled attempt 1 as a permanent RECOV chip with no card and no way out.
    private(set) var sessionRecoveryCardGraceElapsed = false
    /// Last dialled / connected host. Empty until a real address is known — never a guessed IP.
    var cameraHost = ""
    var connectionMessage = "Join your camera's Wi‑Fi network, then come back here to connect."
    var connectedIdentity: NativeCameraIdentity?
    var discoveredCameras: [DiscoveredCamera] = []
    var savedCameras: [PTPIPSavedCameraRecord] = []
    /// Multicam (NIKON-01): up to four bodies on the shared OpenCineMulticam engine, beside the
    /// single-camera session. Opened from Your cameras; see `beginMulticam`.
    let multicam = MulticamCoordinator(isCameraRefusal: NativeCameraSessionError.isCameraRefusal)
    var startupMode: StartupMode = .savedCameras
    var isIPhoneHotspotBridgeActive = false
    var selectedDiscoveredCameraID: String?
    var pendingPairingChallenge: PTPIPPairingChallenge?
    var isDemoSession = false
    /// Demo review only (`ReviewLaunch(connected: true)`, set by `DemoHarness`): the SIMULATED
    /// camera's card, which removes the objects a deletion names, standing in for the camera
    /// session's delete. Nil everywhere else.
    var reviewCameraDelete: ((MediaObjectHandle) async -> Bool)?
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
    /// The staged network's name, editable for the same reason the key is: one OCR pass produced
    /// both, and either can misread. Seeded when credentials are staged and read back at Connect,
    /// so a corrected name is the one actually joined.
    var cameraWiFiJoinSSIDDraft = ""
    /// Whether the on-screen credential scanner is presented over the connect popup.
    var isCameraWiFiScannerPresented = false
    /// "Wi‑Fi is off" prompt shown when a camera-AP flow starts while the radio is disabled.
    var isWiFiOffPromptPresented = false
    /// Shown when a watcher taps a broadcast while this device sits on the camera's own AP —
    /// the join can't work there (camera APs isolate their clients), so the tap explains
    /// the remedy instead of running the doomed 15 s connect race.
    var isWatcherOnCameraAPNoticePresented = false
    /// Join target staged while the connect popup awaits operator confirmation.
    private(set) var pendingCameraWiFiJoinTarget: CameraWiFiJoinPolicy.ProactiveJoinTarget?
    var isMonitorPresented = false {
        didSet {
            syncScreenWakePolicy()
            publishWatchState()
            if oldValue != isMonitorPresented {
                if !isMonitorPresented { gyroCapture.stop(reason: .disconnected) }
                // Record admission follows live-view readiness.
                refreshCommonControlFacts()
                updateBluetoothShutter()
                AppDiagnostics.shared.record(
                    isMonitorPresented ? .monitorPresented : .monitorDismissed)
                if !isMonitorPresented, shell.monitor != nil { shell.close() }
            }
            // The shell shows every monitor exactly while it is up; a camera taking over a
            // picture-only monitor replaces it.
            if isMonitorPresented { ensureShellMonitor() }
        }
    }
    var isMediaPlaybackActive = false {
        didSet { syncScreenWakePolicy() }
    }
    /// True while the full-screen clip player owns the process-wide audio session, including when
    /// paused. The Bluetooth shutter must not reconfigure or deactivate that shared session.
    @ObservationIgnored private var mediaPlaybackOwnsAudioSession = false
    @ObservationIgnored let playbackAudioSession = MonitorPlaybackAudioSession()
    /// Full-screen Media browser opened from the connection menu (no live-view session required):
    /// the shell's Media cover, not the monitor's panel.
    var isStandaloneMediaLibraryPresented: Bool {
        get { shell.cover == .media && activePanel != .media }
        set { setStandalone(.media, newValue) }
    }
    /// Full-screen RED LUT download, presented from the app root (not the LUT picker) so it
    /// survives the monitor collapsing when the internet hop tears the camera session down.
    var isRedDownloadPresented = false
    /// Operator Setup presented standalone from the startup home (no camera connection needed —
    /// e.g. signing in to Frame.io or clearing the media cache before a shoot): the shell's
    /// Settings cover, not the monitor's panel.
    var isStandaloneSettingsPresented: Bool {
        get { shell.cover == .settings && activePanel != .settings }
        set { setStandalone(.settings, newValue) }
    }

    private func setStandalone(_ cover: ShellModel.Cover, _ shown: Bool) {
        if shown {
            shell.open(cover)
        } else if shell.cover == cover, activePanel != (cover == .media ? .media : .settings) {
            shell.dismissCover()
        }
    }

    /// The shell's cover changed (opened, closed, or cleared by a connect or the monitor
    /// leaving): the Bluetooth shutter follows what is in front, and a closed standalone Media
    /// browser stops its camera reads.
    func noteShellCoverChange(from old: ShellModel.Cover?, to new: ShellModel.Cover?) {
        // The shell closed the cover itself (the chrome editor, a monitor change): the panel it
        // hosted is gone too.
        if new == nil, activePanel == .settings || activePanel == .media { activePanel = nil }
        updateBluetoothShutter()
        if old == .media, new != .media, activePanel != .media { closeMediaBrowse() }
    }
    /// Root-owned presentation state for the problem report sheet.
    var isBugReportPresented = false
    /// HDR display, the phone's outdoor panel boost (A2-31): the shared `LiveHDRDisplay.app`
    /// drives the Metal feed, scopes and chrome from it. Off by default.
    var hdrDisplay: Bool = PreferencesStore.hdrDisplay {
        didSet {
            PreferencesStore.hdrDisplay = hdrDisplay
            LiveHDRDisplay.app.setEnabled(hdrDisplay)
        }
    }
    /// Screen recording, AirPlay or mirroring: the HDR present drops to SDR.
    var screenCaptured = false {
        didSet { LiveHDRDisplay.app.setScreenCaptured(screenCaptured) }
    }
    var hdrDisplayActive: Bool { hdrDisplay && !screenCaptured }
    /// The app's one internet hop (A2-16): the shared owner over the Nikon Wi‑Fi joiner.
    @ObservationIgnored lazy var internetHop = MonitorInternetHop<NikonHopRoute>(
        port: .init(
            onCameraNetwork: { [weak self] in self?.isOnCameraAccessPoint ?? false },
            leave: { [weak self] route, current in
                await self?.leaveForInternetHop(route, current: current)
            },
            rejoin: { [weak self] route, current in
                await self?.rejoinAfterInternetHop(route, current: current)
            }))
    /// The Nikon joiner seams of the hop; tests replace them.
    @ObservationIgnored var hopNative = NikonHopNative()
    /// True while the phone has left the camera's Wi‑Fi so the RED LUT download can reach the
    /// internet. Drives the download screen's "Switching networks…" state.
    var internetHopActive: Bool { internetHop.isActive }
    /// Settings browser links (support, GitHub, privacy) hold the hop until the person returns
    /// from the browser: the shared handoff every app uses (A2-22).
    @ObservationIgnored lazy var browserHandoff = MonitorBrowserInternetHandoff(hop: internetHop)
    /// The selected destination shown while iOS leaves the camera AP and settles on an
    /// internet-capable route. Root ownership keeps this visible after the monitor and Settings
    /// panel collapse with the camera session.
    private(set) var internetDestinationPreparationTitle: String?
    /// The one display owner (Core): the DISP modes this source offers and the current one, each
    /// mode's chrome, the chrome editor, the interface lock and the connect-tap arming. Layouts
    /// saved before it seed once from the video side of the retired per-capture layouts.
    @ObservationIgnored lazy var operatorSession = MonitorOperatorSessionModel(
        shell: shell, assist: assist, display: PreferencesStore.display(seededFrom: preferences))
    var displayMode: MonitorDisplayMode { operatorSession.mode }
    /// Operator interface lock (the rail lock button): the monitor's controls are inert so nothing
    /// changes by accident on set, record included. It lasts one monitor lifetime.
    var interfaceLocked: Bool {
        get { operatorSession.locked }
        set { operatorSession.locked = newValue }
    }
    /// App-only lock on the live-view focus point (long-press the AF box). Stops a stray tap from
    /// moving it; the camera remains the source of truth, this just suppresses our ChangeAfArea
    /// sends. Session-only.
    var focusPointLocked = false
    /// Where the monitor's picture comes from.
    ///
    /// Deliberately independent of the control link: a camera reached over Wi-Fi keeps every
    /// control while its picture arrives over HDMI through a capture device, and a capture device
    /// can drive the monitor with no camera session behind it at all.
    var videoSource: VideoSourceKind = .cameraLiveView {
        didSet {
            if oldValue != videoSource {
                gyroCapture.invalidateMountCalibration(
                    message: "Camera source changed. Start calibration again.")
            }
        }
    }
    /// What the HDMI capture path is doing. Only meaningful while it is the active source.
    var hdmiCaptureState: UVCVideoSourceState = .waitingForDevice
    /// Last HDMI frame size logged by `presentHDMIFrame` — one witness line per change (#115).
    @ObservationIgnored private var lastLoggedHDMIFrameSize: CGSize?
    /// The live capture session. Non-nil only while `videoSource == .hdmiCapture`.
    @ObservationIgnored private var uvcSource: UVCVideoSource?
    /// Frame-rate sampler for the capture path, mirroring the camera stream's `liveFPS` readout.
    @ObservationIgnored private var hdmiFrameRate = FrameRateSampler()

    /// Whether this monitor session has a camera behind it at all.
    ///
    /// Deliberately NOT `cameraSession != nil`. A reconnect clears the session for seconds at a
    /// time while the monitor stays up on purpose, holding the last frame in RECOV — gating chrome
    /// on the live transport would make the status bar and capture strip vanish and return on
    /// every recovery, which reads as the app breaking rather than the link blipping. This tracks
    /// the *kind* of session, so it survives the gap and only clears when the operator leaves the
    /// monitor or starts a capture-only one.
    /// Observed, not `@ObservationIgnored`: the chrome mounts read through it, so a change has to
    /// invalidate the views that hang off it.
    private var isCameraControlSession = false

    /// Whether the camera can actually be read and written.
    ///
    /// The demo session counts: it has no transport, but it deliberately simulates a camera so the
    /// screenshot harness exercises the full chrome. An HDMI capture source with no camera behind
    /// it does not, which is the whole point — nothing may offer to change a setting on a camera
    /// that cannot hear it.
    var hasCameraControl: Bool {
        #if DEBUG
            if demoSuppressesCameraControl { return false }
        #endif
        return isCameraControlSession || isDemoSession
    }

    #if DEBUG
        /// Screenshot/verification affordance: pushes the demo still through the REAL broadcast
        /// path — rate cap, encode, framing, socket — so a two-simulator run exercises the same
        /// code a camera session would, rather than a parallel test-only route.
        func demoBroadcastRelayFrame() {
            guard let image = liveFrameImage else { return }
            broadcastRelayFrame(image: image)
        }

        /// Screenshot affordance: forces the no-control path even inside a demo session. The
        /// simulator exposes no UVC device, so a capture-only monitor cannot be reached for real
        /// there — but its chrome is exactly what needs checking. Compiled out of Release.
        var demoSuppressesCameraControl = false

        /// Screenshot affordance: stages the startup hotspot-recovery strip (active/needed) —
        /// the real prompt derives from saved records plus live hotspot state, so neither state
        /// is reachable headless. Compiled out of Release.
        var demoRecoveryPromptOverride: CameraStartupRecoveryPrompt?

        /// Verification affordance: the watcher passcode a previous join would have stored.
        var demoRelayJoinPasscode: String?
    #endif

    /// What the monitor may truthfully display, given the picture source and the control link.
    /// One definition, shared with Android's policy and with the tests.
    var monitorAvailability: MonitorDataAvailability {
        MonitorDataAvailability(
            source: videoSource, ownsCameraSession: hasCameraControl,
            // A relay viewer has every reading the host forwards.
            receivesCameraMetadata: hasCameraControl || videoSource == .relay,
            // ...and drives the camera only while the host has handed it the token.
            holdsRelayControl: relayHoldsControl)
    }

    // MARK: Relay

    /// Serves this device's picture and readings to other devices. Non-nil only while sharing.
    @ObservationIgnored private var relayHost: MonitorRelayHost?
    /// Receives another device's feed. Non-nil only in a viewer session.
    @ObservationIgnored private var relayClient: MonitorRelayClient?
    @ObservationIgnored private var relayBrowser: MonitorRelayBrowser?
    /// Latest per-frame readings, so the HDMI path — where picture and header arrive on different
    /// loops — can still send the two together.
    @ObservationIgnored private var latestRelayFrameMetadata: MonitorRelayFrameMetadata?
    /// Shared outgoing relay cadence/adaptation/HEVC/JPEG owner; the camera remains borrowed.
    @ObservationIgnored private var relayBroadcastPipeline: MonitorRelayBroadcastPipeline?
    /// Whether the running advertisement includes peer-to-peer, so a session that later proves
    /// its topology can re-advertise to match.
    @ObservationIgnored private var relayHostAdvertisesPeerToPeer = false
    /// The port the last listener bound, asked for again on every restart — PERSISTED, because
    /// the failure it prevents spans relaunches: a killed process never withdraws its Bonjour
    /// record, the relaunched app's registration renames itself under the conflict rules, and
    /// watchers keep resolving the stale-named record for its full TTL. With the port stable,
    /// even a stale record dials into the LIVE listener (the field report's RST storm on the
    /// old port, "I can enter it but there's no feed").
    @ObservationIgnored private var relayListenerPreferredPort: UInt16? =
        (UserDefaults.standard.object(forKey: "relayListenerPreferredPort") as? Int)
        .flatMap { UInt16(exactly: $0) }
    {
        didSet {
            guard let port = relayListenerPreferredPort else { return }
            UserDefaults.standard.set(Int(port), forKey: "relayListenerPreferredPort")
        }
    }
    /// Hardware HEVC for an incoming stream; created with a viewer session.
    @ObservationIgnored private var relayVideoDecoder: MonitorRelayVideoDecoder?

    var isRelayBroadcasting = false {
        willSet {
            let surrendered = newValue && relayControlHeldBy != nil && !applyingRelayCommand
            if surrendered != relayControlSurrendered { groupedStabilizationProducer?.retire() }
        }
    }
    var relayPeerCount = 0
    /// Viewer side: whether this device currently holds the camera.
    var relayHoldsControl = false
    /// Viewer side: who does, when it is not us.
    var relayControlHolderName: String?
    /// Host side: a viewer waiting on an answer, and who currently holds the camera.
    var relayPendingControlRequest: String?
    var relayPendingRequest: RelayHostControl.PendingRequest?
    var relayControlHeldBy: String? {
        willSet {
            let surrendered = isRelayBroadcasting && newValue != nil && !applyingRelayCommand
            if surrendered != relayControlSurrendered { groupedStabilizationProducer?.retire() }
        }
        didSet { refreshCommonControlFacts() }
    }
    /// An armed add-setup watch: the operator tapped "Connect When Plugged In" / "Find On
    /// This Network" / "Wait For Camera" in the add-setup sheet, so the first discovery that
    /// matches the asked-for path IS the operator's tap, given in advance. One-shot,
    /// in-memory — it either fulfills into a connect (which saves the setup with its declared
    /// path, like any connect) or is replaced by the next armed watch.
    struct PendingSetupIntent: Equatable {
        let anchor: PTPIPSavedCameraRecord
        let kind: CameraPath.Kind
    }
    var pendingSetupIntent: PendingSetupIntent?
    /// Last infrastructure search miss (Wi‑Fi path). Drives card copy and the manual-host escape.
    var lastInfrastructureMiss: InfrastructureMissReason?
    /// Consecutive empty infrastructure finder passes while a Wi‑Fi search is armed.
    var infrastructureSearchEmptyStreak = 0
    /// Operator entered a camera IP from the body's network screen (industry PTP-IP escape hatch).
    var isManualCameraHostEntryPresented = false
    var manualCameraHostDraft = ""
    /// Add-setup sheet actions that PRESENT something (the AP join cover, the credential
    /// scanner) must run after the sheet has actually gone — SwiftUI silently drops a
    /// fullScreenCover presented while a sheet is mid-dismissal, which read as the sheet's
    /// buttons doing nothing. The sheet stashes the action; its onDismiss runs it.
    @ObservationIgnored var pendingAddSetupAction: (() -> Void)?
    @ObservationIgnored private let infrastructureCameraFinder = InfrastructureCameraFinder()

    /// Runs and clears the stashed add-setup action; called from the sheet's onDismiss.
    func runPendingAddSetupAction() {
        let action = pendingAddSetupAction
        pendingAddSetupAction = nil
        action?()
    }
    /// True while a relayed command is being executed on this device's session, so the
    /// surrendered-control guards let the watcher's own commands through the shared entry
    /// points they route over.
    @ObservationIgnored private var applyingRelayCommand = false
    /// True while a watcher holds this broadcast's control token: the operator handed the
    /// camera over, so the local camera controls stand down until control is revoked or
    /// given back. Never true on a watcher (watchers don't broadcast their relay session).
    var relayControlSurrendered: Bool {
        isRelayBroadcasting && relayControlHeldBy != nil && !applyingRelayCommand
    }
    private var relayNearby = MonitorRelayNearbyComposition.make()
    var discoveredRelayHosts: [MonitorRelayDiscovery] {
        get { relayNearby.listings }
        set { relayNearby.replaceListings(newValue) }
    }
    var relayPresences: [String: RelayPresence] { relayNearby.presences }
    var networkFiltersDiscovery: Bool { relayNearby.networkFiltersDiscovery }
    @ObservationIgnored private let relayPresenceServer = RelayPresenceServer()

    var visibleRelayBroadcasts: [MonitorRelayDiscovery] {
        relayNearby.watchableListings(selfName: UIDevice.current.name)
    }

    /// Compatibility entry for direct completed reports and existing consumer assertions.
    func applyRelayPresences(_ hits: [String: RelayPresence]) {
        let previous = networkFiltersDiscovery
        relayNearby.applySweep(
            hits, selfName: UIDevice.current.name,
            now: Date.timeIntervalSinceReferenceDate)
        noteRelayFilteringTransition(from: previous)
    }

    /// The actual SDK sweep supplies its captured publication ticket, never ambient authority.
    private func applyRelayPresences(_ hits: [String: RelayPresence], source: UUID) {
        let previous = networkFiltersDiscovery
        guard
            relayNearby.applySweep(
                hits, selfName: UIDevice.current.name,
                now: Date.timeIntervalSinceReferenceDate, source: source)
        else { return }
        noteRelayFilteringTransition(from: previous)
    }

    private func noteRelayFilteringTransition(from previous: Bool) {
        guard previous != networkFiltersDiscovery else { return }
        logConnection(
            networkFiltersDiscovery
                ? "presence answers where Bonjour is blind \u{2014} multicast filtering detected"
                : "Bonjour sees every presence again \u{2014} multicast filtering cleared")
    }

    /// Publishes (or stops) this device's own unicast presence line, mirroring exactly what its
    /// Bonjour advertisement would say — a broadcast with its port, or a bare in-use shield.
    /// On a multicast-filtered network this line is the only reason other devices can see it.
    private func updateRelayPresence() {
        if isRelayBroadcasting {
            relayPresenceServer.update(
                RelayPresence(
                    name: UIDevice.current.name,
                    watchable: true,
                    servedCameraHost: isCameraControlSession ? connectedIdentity?.host : nil,
                    relayPort: relayHost?.boundPort.map(Int.init)
                        ?? relayListenerPreferredPort.map(Int.init)))
        } else if isCameraControlSession, !isDemoSession,
            let host = connectedIdentity?.host, !host.isEmpty
        {
            relayPresenceServer.update(
                RelayPresence(
                    name: UIDevice.current.name, watchable: false,
                    servedCameraHost: host, relayPort: nil))
        } else {
            relayPresenceServer.update(nil)
        }
    }

    /// Advertises the held camera while NOT sharing (see `CameraInUseBeacon`); the real
    /// broadcast's advertisement carries the same shield, so only one runs at a time.
    @ObservationIgnored private var cameraInUseBeacon: CameraInUseBeacon?

    private func updateCameraInUseBeacon() {
        let host = connectedIdentity?.host ?? ""
        let shouldBeacon =
            isCameraControlSession && !isRelayBroadcasting && !isDemoSession && !host.isEmpty
        if shouldBeacon {
            let beacon = cameraInUseBeacon ?? CameraInUseBeacon()
            cameraInUseBeacon = beacon
            beacon.start(hostName: UIDevice.current.name, servedCameraHost: host)
        } else {
            cameraInUseBeacon?.stop()
            cameraInUseBeacon = nil
        }
        // The unicast twin follows every beacon/broadcast transition — same truth, reachable
        // on networks that eat the multicast advertisement.
        updateRelayPresence()
    }
    var showsWatcherBrowse = false
    var watcherBrowseError: String?
    var relayClientState: MonitorRelayClient.State = .idle
    /// The broadcast refused this device for want of a passcode; the waiting overlay asks.
    /// While true, the rejoin watchdog stands down — an auto-rejoin without the code is
    /// guaranteed-denied churn that unmounts the entry field mid-typing.
    var relayJoinNeedsPasscode = false
    /// Whether the current join carried a passcode, so a repeat denial can say "wrong code".
    @ObservationIgnored private var relayPasscodeWasAttempted = false
    /// Whether the broadcaster entertains control requests, from the state payload.
    var relayAllowsControlRequests = true
    /// Why the viewer link is down, shown on the empty feed where the operator is actually
    /// looking. The FPS chip can only say "FAIL"; this carries the reason — a version mismatch,
    /// an unreachable route, a suspended broadcaster — and clears when frames flow again.
    var relayFailureReason: String?
    /// The broadcast this viewer joined, kept so retry — manual and automatic — knows its target.
    @ObservationIgnored private var relayJoinTarget: MonitorRelayDiscovery?
    /// Self-heals a viewer session: rejoins on failure once the broadcast is visible again, and
    /// tears through a connected-but-stalled link (the suspended-broadcaster shape).
    @ObservationIgnored private var relayWatchdogTask: Task<Void, Never>?
    /// Re-sends the held frame to watchers while the camera session recovers, so their stall
    /// watchdogs keep the picture instead of tear-and-rejoin looping through the outage.
    @ObservationIgnored private var relayRecoveryHeartbeatTask: Task<Void, Never>?

    /// Viewers are served at most this often. The camera's own stream can run faster than a
    /// watcher needs, and every extra frame is bandwidth taken from the one being looked at.
    private static let relayFrameInterval: CFAbsoluteTime = 1.0 / 30.0

    /// EMA of the camera feed's fps while the relay is NOT competing with it (no peers being
    /// served). This is the session's own definition of healthy; the starve threshold anchors
    /// to it so the ladder keeps stepping until the operator's monitor gets its rate back —
    /// a fixed floor alone let a 35 fps session pin at 20 while the relay kept the channel.
    @ObservationIgnored private var relaySoloFPSBaseline: Double = 0

    /// Starts or stops serving this device's feed to others.
    func setRelayBroadcasting(_ broadcasting: Bool) {
        guard broadcasting != isRelayBroadcasting else { return }
        // A watcher never advertises: rebroadcasting a relay-received session is how an
        // ex-broadcaster's watchers end up listed as phantom "nearby broadcasts".
        if broadcasting, videoSource == .relay { return }
        if broadcasting {
            moveLegacyRelayPasscodes()
            guard let passcode = relayHostPasscode else {
                connectionMessage =
                    "The broadcast passcode can't be read until this iPhone is unlocked. Unlock it and try again."
                return
            }
            // The real advertisement carries the same shield; the beacon must release the
            // service name before the host claims it.
            cameraInUseBeacon?.stop()
            cameraInUseBeacon = nil
            let host = MonitorRelayHost(profile: preferences.relayEncoderProfile)
            host.watcherPasscode = passcode
            host.allowsControlRequests = preferences.relayAllowsControlRequests
            host.onPeerCountChanged = { [weak self] count in self?.relayPeerCount = count }
            host.onFailure = { [weak self] message in
                self?.connectionMessage = message
                self?.isRelayBroadcasting = false
            }
            host.onControlChanged = { [weak self, weak host] in
                guard let self, let host, self.relayHost === host else { return }
                let source = host.sourceToken
                let revision = host.controlRevision
                let request = host.pendingRequest
                let name = host.pendingRequestName
                let holder = host.controlHolderName
                self.relayPendingRequest = request
                guard self.relayHost === host, host.sourceToken == source,
                    host.controlRevision == revision, host.pendingRequest == request
                else { return }
                self.relayPendingControlRequest = name
                guard self.relayHost === host, host.sourceToken == source,
                    host.controlRevision == revision, host.pendingRequest == request
                else { return }
                self.relayControlHeldBy = holder
            }
            host.onAdmittedCommand = { [weak self, weak host] command, receipt in
                guard let self, let host, self.relayHost === host, host.admits(receipt),
                    let native = self.cameraSession, let owner = native.commandOwner
                else { return }
                let admission = NikonCommandAdmission(
                    owner: owner, isCurrent: host.capturedCommandAdmission(for: receipt))
                self.executeRelayCommand(command, admission: admission)
            }
            relayBroadcastPipeline = MonitorRelayBroadcastPipeline(
                host: host,
                profile: preferences.relayEncoderProfile, frameInterval: Self.relayFrameInterval)
            // Peer-to-peer (AWDL) advertising time-slices the radio the camera stream rides —
            // ~30–100 ms locks every second, measured as multi-fps loss on a router path — so it
            // runs ONLY on positive proof the camera occupies this device's Wi-Fi (AP session),
            // the one case where viewers have no infrastructure path. Unknown topology keeps it
            // OFF: on infrastructure the advertisement already reaches viewers through the
            // network itself, and a viewer that wants an AP-session broadcast can join the
            // camera's network. ("Unknown keeps it on" was tried first — it put AWDL under
            // every router session whose SSID iOS would not disclose, which is most of them.)
            // A live session's establishment latch outranks the SSID read: hardware regularly
            // refuses the Wi-Fi information request (`nehelper invalid result code`), and the
            // latch was decided when the topology actually proved itself.
            let advertisesPeerToPeer =
                isConnected ? establishedSessionUsedCameraAP : cameraAccessPointEvidence == true
            host.onListening = { [weak self] port in
                if let port { self?.relayListenerPreferredPort = port }
                // The presence line carries the relay port; refresh it now that it is bound.
                self?.updateRelayPresence()
            }
            host.start(
                hostName: UIDevice.current.name,
                cameraName: connectedIdentity?.displayName ?? cameraState.cameraName,
                servedCameraHost: isCameraControlSession ? connectedIdentity?.host : nil,
                includePeerToPeer: advertisesPeerToPeer,
                preferredPort: relayListenerPreferredPort)
            relayHost = host
            relayHostAdvertisesPeerToPeer = advertisesPeerToPeer
            isRelayBroadcasting = true
            broadcastRelayState()
            updateRelayPresence()
        } else {
            relayHost?.stop(notifyingViewers: "The broadcast ended.")
            relayHost = nil
            relayBroadcastPipeline?.close()
            relayBroadcastPipeline = nil
            relayPeerCount = 0
            isRelayBroadcasting = false
            // Sharing ended but the session may live on — the in-use shield takes back over.
            updateCameraInUseBeacon()
            if relayHost == nil, !isRelayBroadcasting { relayPendingRequest = nil }
        }
    }

    func grantRelayControl() { relayHost?.grantPendingControl() }
    func declineRelayControl() { relayHost?.declinePendingControl() }
    /// Takes the camera back from a viewer. Always available — this device owns the session, so it
    /// never needs the viewer's cooperation, which is what makes handing control out safe at all.
    func reclaimRelayControl() { relayHost?.reclaimControl() }

    /// Runs a command a viewer issued, on this device's own session.
    ///
    /// Routed through the same entry points the local UI uses rather than a parallel path, so a
    /// relayed record or focus point is subject to every guard, queue and safe point a local one
    /// is — including the interface lock.
    ///
    /// The one thing that does NOT apply is the operator's confirmation prompt: it belongs to
    /// whoever pressed the button, the viewer already answered it on its own screen, and a second
    /// prompt would sit unanswered on a device nobody is holding while the take never starts.
    /// `applyingRelayCommand` is what tells the shared entry points which press this is.
    private func executeRelayCommand(
        _ command: MonitorRelayCommand, admission: NikonCommandAdmission
    ) {
        guard admitsCameraCommand(admission) else { return }
        applyingRelayCommand = true
        defer { applyingRelayCommand = false }
        switch command {
        case .toggleRecording:
            toggleRecording(admission: admission)
        case .focusPoint(let x, let y, let width, let height):
            applyFocusPoint(
                cameraX: x, cameraY: y, coordinateWidth: width, coordinateHeight: height,
                admission: admission)
        case .pickerValue(let picker, let value):
            guard let picker = CameraPicker(rawValue: picker) else { return }
            // Exposure-helper vocabulary (base ISO, ISO auto, shutter mode, WB tint) dispatches
            // to its helper; everything else is a plain value write.
            if routeRelayHelperValue(value, for: picker, admission: admission) { return }
            applyPickerValue(value, for: picker, admission: admission)
        }
    }

    /// Explicit command authority only; no ambient receipt is used by the camera queues.
    private func admitsCameraCommand(_ admission: NikonCommandAdmission?) -> Bool {
        guard let admission else { return true }
        return admission.admits(cameraSession?.commandOwner)
    }

    private func sharedCommandAdmission(_ admission: NikonCommandAdmission)
        -> CommandDispatchAdmission?
    {
        guard admitsCameraCommand(admission), let source = controlSession else { return nil }
        let snapshot = source.refresh()
        return CommandDispatchAdmission(
            session: source.id, epoch: snapshot.epoch, isCurrent: { admission.isCurrent },
            submit: { command in await source.submit(command, admission: admission) })
    }

    /// Publishes the slow-moving readouts. Cheap, so it runs on any change rather than a cadence.
    private func broadcastRelayState() {
        guard let relayHost, isRelayBroadcasting else { return }
        relayHost.broadcast(
            state: MonitorRelayState(
                recordState: cameraState.recordState,
                resolutionFrameRate: cameraState.resolutionFrameRate,
                codec: cameraState.codec,
                media: cameraState.media,
                liveFPS: liveFPS,
                cameraBatteryPercent: cameraState.cameraBatteryPercent,
                cameraName: cameraState.cameraName,
                lens: cameraState.lens,
                temperature: cameraState.temperature,
                values: cameraState.values.map {
                    MonitorRelayState.Value(label: $0.label, value: $0.value)
                },
                mediaStatus: cameraState.mediaStatus,
                isRecording: isRecording,
                allowsControlRequests: preferences.relayAllowsControlRequests,
                batteryReading: cameraBatteryReading, batteryExhausted: cameraBatteryExhausted))
    }

    /// Wire encoding for the focus result. Numeric on purpose — a new enum case must not shift
    /// the meaning of a value already on the wire.
    private static func relayFocusResultCode(_ result: PTPLiveViewFocusInfo.FocusResult) -> Int {
        switch result {
        case .focused: 2
        case .notFocused: 1
        case .unknown: 0
        }
    }

    private static func relayFocusResult(fromCode code: Int) -> PTPLiveViewFocusInfo.FocusResult {
        switch code {
        case 2: .focused
        case 1: .notFocused
        default: .unknown
        }
    }

    /// Records the readings that belong to the frame just received, so they travel with it.
    private func captureRelayFrameMetadata(_ frame: PTPLiveViewFrame) {
        guard isRelayBroadcasting else { return }
        latestRelayFrameMetadata = MonitorRelayFrameMetadata(
            timecode: frame.timecode,
            isRecording: frame.isRecording,
            focus: frame.focus.map { focus in
                MonitorRelayFrameMetadata.Focus(
                    coordinateWidth: focus.coordinateWidth,
                    coordinateHeight: focus.coordinateHeight,
                    focusResult: Self.relayFocusResultCode(focus.focusResult),
                    subjectDetectionActive: focus.subjectDetectionActive,
                    trackingAFActive: focus.trackingAFActive,
                    selectedBoxIndex: focus.selectedBoxIndex,
                    boxes: focus.boxes.map {
                        MonitorRelayFrameMetadata.Box(
                            centerX: $0.centerX, centerY: $0.centerY, width: $0.width,
                            height: $0.height)
                    })
            },
            levelRoll: frame.level.map { PTPLevelAngles.signedDegrees($0.roll) },
            levelPitch: frame.level.map { PTPLevelAngles.signedDegrees($0.pitch) },
            sound: frame.sound.map {
                MonitorRelayFrameMetadata.Sound(
                    peakLeft: $0.peakLeft, peakRight: $0.peakRight,
                    currentLeft: $0.currentLeft, currentRight: $0.currentRight)
            },
            rotation: Int(frame.rotation.rawValue))
    }

    /// Source/native image projection only. Cadence, adaptation, stage bounds and callbacks are
    /// owned by the shared pipeline against this actual native source's retained admission.
    private func broadcastRelayFrame(image: UIImage) {
        guard let pipeline = relayBroadcastPipeline, let source = nativePictureSource else {
            return
        }
        let metadata =
            latestRelayFrameMetadata
            ?? MonitorRelayFrameMetadata(
                timecode: nil, isRecording: isRecording, focus: nil, levelRoll: nil,
                levelPitch: nil, sound: nil)
        let admission = RelayFrameAdmission(isCurrent: { [weak self] in
            source.isActive && self?.nativePictureSource === source
                && self?.relayBroadcastPipeline === pipeline
        })
        let cameraFPS = videoSource == .cameraLiveView ? measuredLiveViewFPS : nil
        if let cgImage = image.cgImage {
            pipeline.submit(
                cgImage, metadata: metadata, admission: admission, cameraFPS: cameraFPS,
                soloBaselineFPS: relaySoloFPSBaseline)
        } else {
            let jpeg = MonitorRelayJPEGImage(image)
            pipeline.submitJPEG(
                metadata: metadata, admission: admission, cameraFPS: cameraFPS,
                soloBaselineFPS: relaySoloFPSBaseline, encode: { jpeg.encode() })
        }
    }

    // MARK: Relay viewer

    func startRelayBrowsing(includePeerToPeer: Bool = true) {
        guard relayBrowser == nil else { return }
        let browser = MonitorRelayBrowser()
        browser.onResults = { [weak self, weak browser] results in
            guard let self, let browser, self.relayBrowser === browser else { return }
            self.relayNearby.acceptListingEvent(results)
        }
        browser.onError = { [weak self, weak browser] error in
            guard let self, let browser, self.relayBrowser === browser else { return }
            self.watcherBrowseError = error
        }
        watcherBrowseError = nil
        relayBrowser = browser
        browser.start(includePeerToPeer: includePeerToPeer)
    }

    /// Whether a relay browse is running; nothing may start one before the operator chooses a
    /// network path, since the browse raises the Local Network prompt.
    var isRelayBrowsing: Bool { relayBrowser != nil }

    func stopRelayBrowsing() {
        relayBrowser?.stop()
        relayBrowser = nil
        discoveredRelayHosts = []
        watcherBrowseError = nil
    }

    /// The shared browse screen precedes joining and leaves Nikon preparation in place beneath it.
    func openWatcherBrowse() {
        guard !isMonitorPresented, cameras.attempts.isEmpty, !isEstablishingConnection,
            !showsAppConnectProgress, connection != .preparingLiveView
        else { return }
        showsWatcherBrowse = true
        startWatcherBrowse()
    }

    /// Joins a broadcasting device. The viewer has no camera session of its own — by design, since
    /// the camera would refuse a second one anyway.
    func joinRelay(_ discovery: MonitorRelayDiscovery) {
        // A watcher ON the camera's own AP can SEE the broadcast (multicast discovery gets
        // through) but its join cannot — camera APs don't pass traffic between their clients,
        // so the 15 s connect race is doomed before it starts. Block it with the remedy
        // instead of failing after the wait.
        guard !isOnCameraAccessPointNetwork else {
            isWatcherOnCameraAPNoticePresented = true
            return
        }
        let wasWatching = videoSource == .relay && isMonitorPresented
        // A second join must not leave the first client running: its callbacks keep writing the
        // shared viewer state, so a stale 15 s timeout would stamp FAIL over a healthy new stream.
        relayClient?.stop()
        relayClient = nil
        relayVideoDecoder?.invalidate()
        relayVideoDecoder = nil
        // Becoming a watcher ends this device's own broadcast (viewers get the ended notice) —
        // it must never advertise a feed it is itself relaying from someone else.
        setRelayBroadcasting(false)
        relayJoinTarget = discovery
        relayFailureReason = nil
        relayJoinNeedsPasscode = false
        showsWatcherBrowse = !wasWatching
        stopDiscoveryLoop()
        // …which also stopped relay browsing (camera list semantics). A viewer session needs it
        // back: the watchdog can only rejoin a broadcast it can still see. Infrastructure-only —
        // AWDL browsing under the decoding stream costs the watcher the same periodic radio
        // locks it costs a broadcaster, and a rejoin only re-finds a path that already worked.
        startRelayBrowsing(includePeerToPeer: false)
        disconnectCameraSession(resetConnection: false)
        cameraState = .blank
        relayedBatteryReading = nil
        relayedBatteryExhausted = nil
        resetCameraPropertyState()
        resetLinkHealthMeasurements()
        discoveredCameras = []
        connectedIdentity = nil
        liveFrameImage = nil
        videoSource = .relay
        isMonitorPresented = wasWatching
        connection = .connected
        connectionMessage = "Joining \(discovery.name)…"
        liveFPS = "LINK"
        operatorSession.declare(modes: displayModes)

        let client = MonitorRelayClient()
        client.onStateChanged = { [weak self, weak client] state in
            guard let self, let client, self.relayClient === client else { return }
            self.relayClientState = state
            // `connectionMessage` is invisible on the monitor, so the FPS chip carries the link
            // state — the same idiom the camera loop uses (RECOV/LINK). Without this, a route
            // that never comes up is indistinguishable from a connected feed with no frames,
            // which is exactly how it was reported from set.
            switch state {
            case .connecting:
                self.liveFPS = "LINK"
            case .waiting(let reason):
                self.liveFPS = "LINK"
                self.connectionMessage = "Can't reach the broadcasting device yet: \(reason)"
                self.relayFailureReason = reason
            case .connected(let hostName, let cameraName):
                self.showsWatcherBrowse = false
                self.shell.dismissCover()
                self.isMonitorPresented = true
                self.connectionMessage =
                    cameraName.map { "Watching \(hostName) — \($0)." }
                    ?? "Watching \(hostName)."
                self.relayFailureReason = nil
            case .failed(let reason):
                self.liveFPS = "FAIL"
                // Watching from ON the camera's own Wi-Fi depends on the AP forwarding
                // client-to-client traffic, which camera APs typically do not — the honest
                // remedy is leaving that network (nearby broadcasts reach this device
                // directly, no shared network needed). Say so instead of a bare "couldn't
                // reach".
                let hint =
                    self.isOnCameraAccessPointNetwork
                    ? " This device is on the camera's own Wi-Fi — leave that network and "
                        + "watch from your regular Wi-Fi; nearby broadcasts reach this "
                        + "device directly."
                    : ""
                self.connectionMessage = reason + hint
                self.relayFailureReason = reason + hint
                // A frozen frame that still looks live is the one failure mode a set monitor
                // must never have — blank it so the reason overlay says what actually happened.
                self.liveFrameImage = nil
            case .idle:
                break
            }
        }
        client.onRelayState = { [weak self] state in self?.applyRelayState(state) }
        client.onControlToken = { [weak self] token in
            guard let self else { return }
            self.relayHoldsControl = token.holderIsRecipient
            self.relayControlHolderName = token.holderIsRecipient ? nil : token.holderName
            // Losing control mid-gesture must not leave a drum open over a camera that has stopped
            // listening to this device.
            if !token.holderIsRecipient { self.dismissActivePanel() }
        }
        client.onFrame = { [weak self, weak client] metadata, image in
            guard let self, let client, self.relayClient === client else { return }
            self.applyRelayFrame(metadata: metadata, image: image, client: client)
        }
        client.onJoinDenied = { [weak self, weak client] denial in
            guard let self, let client, self.relayClient === client else { return }
            // Denied while WATCHING is the broadcaster ending the session deliberately —
            // exit to the camera list. Only a pre-join refusal is a join failure.
            if case .connected = self.relayClientState, !denial.passcodeRequired {
                self.leaveRelay()
                self.connectionMessage = denial.reason
                return
            }
            self.relayJoinNeedsPasscode = denial.passcodeRequired
            // A second denial after a code was sent means the CODE was wrong — say that,
            // not the generic ask.
            self.relayFailureReason =
                denial.passcodeRequired && self.relayPasscodeWasAttempted
                ? "That passcode wasn't accepted — check it with the broadcasting device."
                : denial.reason
            self.liveFPS = "FAIL"
            self.liveFrameImage = nil
        }
        relayHoldsControl = false
        relayControlHolderName = nil
        relayClient = client
        lastGoodFrameAt = Date()
        client.connect(to: discovery.endpoint)
        var joinPasscode =
            relaySubmittedPasscodes[discovery.name]
            ?? Self.storedRelayPasscode(forHost: discovery.name)
        #if DEBUG
            joinPasscode = joinPasscode ?? demoRelayJoinPasscode
        #endif
        relayPasscodeWasAttempted = joinPasscode?.isEmpty == false
        client.introduce(deviceName: UIDevice.current.name, passcode: joinPasscode)
        startRelayWatchdog(for: discovery)
    }

    /// Watcher passcodes, remembered per broadcaster in the Keychain so a set's code is typed
    /// once per device.
    static func storedRelayPasscode(forHost host: String) -> String? {
        RelayLegacyWatcherPasscodes.move(into: .app, from: .standard)
        if case .stored(let code) = WatcherRelayKeychain.app.rememberedPasscodeLookup(forHost: host)
        {
            return code
        }
        return RelayLegacyWatcherPasscodes.unmoved(forHost: host, in: .standard)
    }

    /// Entered codes the Keychain could not keep: they still join in this run, never on disk.
    @ObservationIgnored private var relaySubmittedPasscodes: [String: String] = [:]

    /// Stores the entered code and rejoins with it.
    func submitRelayPasscode(_ code: String) {
        guard let target = relayJoinTarget, let trimmed = MonitorWatcherPasscodeRule.answer(code)
        else { return }
        let saved = WatcherRelayKeychain.app.storeRememberedPasscode(trimmed, forHost: target.name)
        relaySubmittedPasscodes[target.name] = saved ? nil : trimmed
        relayJoinNeedsPasscode = false
        joinRelay(target)
    }

    /// The empty-feed overlay's Try Again — a human-paced version of the watchdog.
    func retryRelayJoin() {
        guard let target = relayJoinTarget else { return }
        joinRelay(target)
    }

    /// One loop covers both dead shapes of a viewer session: a failed link (rejoin as soon as the
    /// broadcast is visible in Bonjour again — the broadcaster reopening its app is exactly the
    /// case that heals here) and a connected-but-stalled one, which is what a suspended
    /// broadcaster looks like from the outside. Cancelled by leaving; replaced by rejoining.
    private func startRelayWatchdog(for target: MonitorRelayDiscovery) {
        relayWatchdogTask?.cancel()
        relayWatchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard let self, !Task.isCancelled, self.videoSource == .relay else { return }
                // A passcode prompt is a HUMAN in the loop: an auto-rejoin without the code is
                // guaranteed to be denied, and each cycle unmounts the entry field mid-typing.
                if self.relayJoinNeedsPasscode { continue }
                // Rejoin through the CURRENT browse result, never the captured one: a Bonjour
                // endpoint pins the interface it was discovered on, and a broadcaster that came
                // back (new port, new interface) leaves the captured endpoint resolving to the
                // dead registration — a rejoin loop that redials the void forever.
                let fresh = self.discoveredRelayHosts.first(where: { $0.id == target.id })
                switch self.relayClientState {
                case .failed, .idle:
                    // `.idle` is a failure's aftermath here, not "never joined": the client's
                    // stop() lands there right after reporting the failure, and leaving the
                    // relay cancels this watchdog before it could ever observe it.
                    if let fresh {
                        self.joinRelay(fresh)
                        return
                    }
                case .connected:
                    if Date().timeIntervalSince(self.lastGoodFrameAt ?? .distantPast) > 8 {
                        self.relayFailureReason =
                            "The stream stalled — reconnecting. Make sure OpenZCine is open "
                            + "on the broadcasting device."
                        self.joinRelay(fresh ?? target)
                        return
                    }
                default:
                    break
                }
            }
        }
    }

    func requestRelayControl() { relayClient?.requestControl() }
    func releaseRelayControl() {
        relayClient?.releaseControl()
        relayHoldsControl = false
    }

    func leaveRelay() {
        showsWatcherBrowse = false
        relayJoinNeedsPasscode = false
        relayPasscodeWasAttempted = false
        relayWatchdogTask?.cancel()
        relayWatchdogTask = nil
        relayJoinTarget = nil
        relayFailureReason = nil
        relayClient?.stop()
        relayClient = nil
        relayVideoDecoder?.invalidate()
        relayVideoDecoder = nil
        relayedBatteryReading = nil
        relayedBatteryExhausted = nil
        relayClientState = .idle
        relayHoldsControl = false
        relayControlHolderName = nil
        videoSource = .cameraLiveView
        liveFrameImage = nil
        isMonitorPresented = false
        connection = .disconnected
        applyStartupDestination()
    }

    private func applyRelayState(_ state: MonitorRelayState) {
        relayedBatteryReading = state.batteryReading
        relayedBatteryExhausted = state.batteryExhausted
        // Absent means an older host that predates the policy — allowed, the old behavior.
        relayAllowsControlRequests = state.allowsControlRequests ?? true
        cameraState = CameraDisplayState(
            recordState: state.recordState,
            timecode: liveTimecode,
            resolutionFrameRate: state.resolutionFrameRate,
            codec: state.codec,
            media: state.media,
            liveFPS: state.liveFPS,
            cameraBatteryPercent: state.cameraBatteryPercent,
            cameraName: state.cameraName,
            lens: state.lens,
            temperature: state.temperature,
            values: state.values.map {
                CameraValue(label: $0.label, value: $0.value, isSettable: false)
            },
            mediaStatus: state.mediaStatus)
        if isRecording != state.isRecording { isRecording = state.isRecording }
        liveFPS = state.liveFPS
    }

    private func applyRelayFrame(
        metadata: MonitorRelayFrameMetadata, image: Data,
        client: MonitorRelayClient
    ) {
        guard relayClient === client, videoSource == .relay else { return }
        applyRelayFrameReadings(metadata)
        if metadata.codec == MonitorRelayProtocol.FrameCodec.hevc {
            let decoder = relayVideoDecoder ?? MonitorRelayVideoDecoder()
            relayVideoDecoder = decoder
            decoder.decode(
                image, isKeyframe: metadata.isKeyframe, parameterSets: metadata.parameterSets
            ) { [weak self] decoded in
                guard let decoded else { return }
                Task { @MainActor in self?.presentRelayFrame(decoded, client: client) }
            }
            return
        }
        guard let decodeSource = frameDecoder.source(client) else { return }
        Task { [weak self] in
            guard let self,
                let decoded = await self.frameDecoder.decode(image, source: decodeSource)
            else { return }
            self.presentRelayFrame(decoded, client: client)
        }
    }

    /// The readings ride with the frame whichever codec carried it.
    private func applyRelayFrameReadings(_ metadata: MonitorRelayFrameMetadata) {
        if let timecode = metadata.timecode { applyLiveViewHeaderTimecode(timecode) }
        // The broadcaster's body orientation rides every frame; a watcher rotates the picture
        // upright exactly like the broadcaster does. Absent (older host) means landscape.
        let rotation =
            metadata.rotation
            .flatMap { PTPLiveViewRotation(rawValue: UInt8(clamping: $0)) } ?? .landscape
        if liveFeedRotation != rotation { liveFeedRotation = rotation }
        liveViewFocus = metadata.focus.map { focus in
            PTPLiveViewFocusInfo(
                coordinateWidth: focus.coordinateWidth,
                coordinateHeight: focus.coordinateHeight,
                focusResult: Self.relayFocusResult(fromCode: focus.focusResult),
                subjectDetectionActive: focus.subjectDetectionActive,
                trackingAFActive: focus.trackingAFActive,
                selectedBoxIndex: focus.selectedBoxIndex,
                boxes: focus.boxes.map {
                    PTPLiveViewAFBox(
                        centerX: $0.centerX, centerY: $0.centerY, width: $0.width,
                        height: $0.height)
                })
        }
        if let roll = metadata.levelRoll { cameraLevelRoll = roll }
        if let pitch = metadata.levelPitch { cameraLevelPitch = pitch }
        observedLiveAudioLevels = metadata.sound.map { sound in
            MonitorAudioMeterLevels(
                cameraIndicator: PTPLiveViewSoundIndicator(
                    peakLeft: sound.peakLeft, peakRight: sound.peakRight,
                    currentLeft: sound.currentLeft, currentRight: sound.currentRight))
        }
    }

    /// One decoded picture onto the viewer's monitor, whichever codec delivered it.
    private func presentRelayFrame(_ decoded: UIImage, client: MonitorRelayClient) {
        guard videoSource == .relay, relayClient === client else { return }
        // A frame or two is always still in the decode pipeline when the link dies; presenting
        // one would repopulate the feed the failure path just blanked, leaving a frozen picture
        // over a FAIL chip.
        switch relayClientState {
        case .failed, .idle: return
        default: break
        }
        Task { [weak self] in
            guard let self else { return }
            guard let display = await self.displayReadyLiveFrame(from: decoded) else { return }
            guard self.videoSource == .relay, self.relayClient === client else { return }
            switch self.relayClientState {
            case .failed, .idle: return
            default: break
            }
            self.publishNativeFrame(display, clean: decoded, owner: .relay(client))
            self.lastGoodFrameAt = Date()
            if self.relayFailureReason != nil { self.relayFailureReason = nil }
            // The viewer's assists meter the clean frame exactly as the host's do.
            self.sampleScopesIfDue(clean: decoded) { [weak self, weak client] in
                guard let self, let client else { return false }
                return self.videoSource == .relay && self.relayClient === client
            }
        }
    }

    var cameraState = CameraDisplayState.blank {
        // The wrist reads battery, media and camera name from here, and had no way to hear about
        // any of them changing. Per-frame telemetry deliberately lives outside this struct (see
        // below), so this fires on real changes, not every frame.
        didSet { publishWatchState() }
    }
    // Per-frame telemetry (timecode, FPS) is held separately from `cameraState` so updating it
    // never invalidates every view observing the heavy HUD struct — only the readouts re-render.
    var liveTimecode = CameraDisplayState.blank.timecode
    /// Whether the body is running timecode at all — the header's own status byte, held apart from
    /// `liveTimecode` on purpose. Chrome that only needs "is there a timecode" must not observe the
    /// counter: that ticks every frame and would re-render the whole top bar at feed rate. Bodies
    /// without timecode hardware pin the status byte to zero forever, which is exactly the signal
    /// that hides the readout rather than parking a frozen 00:00:00:00 on set.
    var cameraReportsTimecode = CameraDisplayState.blank.timecode.on
    var liveFPS = CameraDisplayState.blank.liveFPS
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

    /// Actual advertised movie tuples for the shared format leaf; writes retain their complete labels.
    var recordingFormatPresentations: [NikonRecordingFormatPresentation] {
        var seen = Set<String>()
        return cameraScreenModes.map {
            NikonRecordingFormatPresentation(
                mode: $0, currentCodec: cameraPropertySnapshot.fileType,
                isNikonZR: isConnectedNikonZR)
        }.filter { seen.insert($0.token).inserted }
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
    /// Movie tones each per-codec tone property offers, from the body's own descriptors
    /// (`NikonMovieToneCapability`). Empty on a body without per-codec tone properties.
    var cameraMovieTones: [PTPPropertyCode: [NikonMovieTone]] = [:]
    /// The advertised codecs as picker rows: one per family, carrying the bit depths the body
    /// offers for it so the CODEC drum can flank the row with a depth choice (#276 follow-up).
    var codecFamilies: [PTPCameraCodecFamily] {
        PTPCameraPropertyDecoders.codecFamilies(cameraFileTypeModes)
    }
    /// Codec labels for the codec picker, in the camera's advertised order.
    var codecOptions: [String] { codecFamilies.map(\.label) }
    /// The advertised codec mode the body is currently on — the source of the CODEC picker's
    /// selected bit depth. Nil until the descriptor and the readback agree.
    var activeCodecMode: PTPCameraFileTypeMode? {
        PTPCameraPropertyDecoders.fileTypeMode(
            forFileType: cameraPropertySnapshot.fileType, in: cameraFileTypeModes)
    }
    /// Camera-advertised option lists for the moded AF / shutter / WB-preset settings, keyed by PTP
    /// property. Read once per poll cycle; an absent or empty entry means the picker keeps its
    /// hardcoded fallback. Reading the real values lets the pickers track whatever the connected body
    /// supports, not just the ZR's defaults.
    var cameraControlOptions: [PTPPropertyCode: [String]] = [:]
    /// Describe evidence is independent of the historical picker domains and write policy.
    var cameraDescriptorEvidence: [PTPPropertyCode: NikonDescriptorEvidence] = [:]
    /// Observable actual readback; optimistic picker snapshots cannot establish codec eligibility.
    private(set) var stabilizationFileTypeReadback: String?
    var stabilizationPresentation: NikonStabilizationPresentation {
        NikonStabilizationSettings.presentation(
            vrOptions: cameraControlOptions[.movieVibrationReduction],
            currentVR: stabilizationVR, currentEVR: stabilizationElectronicVR,
            codec: cameraState.codec,
            vrDescriptor: cameraDescriptorEvidence[.movieVibrationReduction] ?? .init(),
            evrDescriptor: cameraDescriptorEvidence[.electronicVR] ?? .init(),
            actualCodec: PTPCameraPropertyDecoders.fileTypeMode(
                forFileType: stabilizationFileTypeReadback, in: cameraFileTypeModes))
    }
    /// Exposure choices actually returned by a descriptor, independent of legacy picker ladders.
    private(set) var advertisedExposureOptions: [PTPPropertyCode: [String]] = [:]
    private var relayedBatteryReading: BatteryReading?
    private var relayedBatteryExhausted: Bool?

    /// The camera's typed power on this device: the session's, or the SIMULATED legacy report
    /// converted at this composition boundary. A relay carries only its reading, so it has none.
    private var cameraPower: PowerStatus? {
        if videoSource == .relay { return nil }
        if isDemoSession {
            return CameraBatteryGauge.gauge(rawBatteryLevel: cameraState.cameraBatteryPercent)
                .powerStatus
        }
        return shell.control.snapshot?.power
    }

    var cameraBatteryReading: BatteryReading? {
        videoSource == .relay ? relayedBatteryReading : cameraPower?.batteryReading
    }

    var cameraPowerCharging: Bool? {
        if videoSource != .relay, isDemoSession { return cameraBatteryCharging }
        return cameraPower.flatMap { $0.charging.value ?? $0.externalPower.value }
    }

    /// The body reports running on external power (spoken as such, and "EXT" without a level).
    var cameraExternalPower: Bool? {
        videoSource == .relay ? nil : cameraPower?.externalPower.value
    }

    var cameraBatteryExhausted: Bool? {
        videoSource == .relay ? relayedBatteryExhausted : cameraPower?.exhausted.value
    }

    var cameraBatteryCharging: Bool?
    private final class NativePictureReference<Value: AnyObject> {
        weak var value: Value?
        init(_ value: Value) { self.value = value }
    }
    private enum NativePictureOwner {
        case local
        case cameraSource(NativePictureReference<NativeCameraSession>)
        case relaySource(NativePictureReference<MonitorRelayClient>)
        case captureSource(NativePictureReference<UVCVideoSource>, StreamGeneration)
        static func camera(_ value: NativeCameraSession) -> Self { .cameraSource(.init(value)) }
        static func relay(_ value: MonitorRelayClient) -> Self { .relaySource(.init(value)) }
        static func capture(_ value: UVCVideoSource, _ generation: StreamGeneration) -> Self {
            .captureSource(.init(value), generation)
        }
        func matches(_ other: NativePictureOwner?) -> Bool {
            switch (self, other) {
            case (.local, .local): return true
            case (.cameraSource(let source), .cameraSource(let other)):
                guard let source = source.value else { return false }
                return source === other.value
            case (.relaySource(let source), .relaySource(let other)):
                guard let source = source.value else { return false }
                return source === other.value
            case (
                .captureSource(let source, let generation),
                .captureSource(let other, let otherGeneration)
            ):
                guard let source = source.value else { return false }
                return source === other.value && generation == otherGeneration
            default: return false
            }
        }
    }
    @ObservationIgnored private let nativePictureBus = LiveFrameSampleBus()
    @ObservationIgnored private var nativePictureSource: LiveFrameSampleBus.Source?
    @ObservationIgnored private var nativePictureOwner: NativePictureOwner?
    @ObservationIgnored private var nativeInspectorImage: UIImage?
    @ObservationIgnored private var nativeInspectorVideoSource: VideoSourceKind?
    @ObservationIgnored lazy var nativeInspectorPreview = NikonLiveInspectorPreview(
        fileStore: lutFileStore)
    /// The clean accepted raster and the same lease used by the actual monitor picture.
    var nativeInspectorFrame: (source: LiveFrameSampleBus.Source, image: UIImage)? {
        guard let source = liveFrameSource, source.isActive, let image = nativeInspectorImage else {
            return nil
        }
        switch nativePictureOwner {
        case .local:
            guard nativeInspectorVideoSource == videoSource else { return nil }
        case .cameraSource(let owner):
            guard videoSource == .cameraLiveView, let value = owner.value,
                value === cameraSession
            else { return nil }
        case .relaySource(let owner):
            guard videoSource == .relay, let value = owner.value, value === relayClient else {
                return nil
            }
            switch relayClientState {
            case .failed, .idle: return nil
            default: break
            }
        case .captureSource(let owner, let generation):
            guard videoSource == .hdmiCapture, let value = owner.value,
                value === uvcSource, value.fence.isCurrent(generation)
            else { return nil }
        case nil: return nil
        }
        return (source, image)
    }
    private(set) var liveFrameSource: LiveFrameSampleBus.Source?
    /// Picture facts for chrome. Raster replacement is observed only by the feed view.
    private(set) var hasLiveFrameImage = false
    /// Source geometry changes independently of image identity, including HDMI format changes.
    private(set) var liveFrameAspect: Double?
    var liveFrameImage: UIImage? {
        didSet {
            let present = liveFrameImage != nil
            if hasLiveFrameImage != present { hasLiveFrameImage = present }
            let aspect = liveFrameImage.flatMap { image in
                image.size.height > 0 ? Double(image.size.width / image.size.height) : nil
            }
            if liveFrameAspect != aspect { liveFrameAspect = aspect }
            if liveFrameImage == nil {
                retireNativePictureSource()
                liveFrameSource = nil
            } else if nativePictureSource == nil {
                nativePictureOwner = .local
                nativePictureSource = nativePictureBus.openSource(.live)
                liveFrameSource = nativePictureSource
            }
            if case .local? = nativePictureOwner {
                nativeInspectorImage = liveFrameImage
                nativeInspectorVideoSource = videoSource
            }
        }
    }
    private func retireNativePictureSource() {
        relayBroadcastPipeline?.retireSource()
        watchRelay.retireSource()
        nativePictureBus.closeSource(nativePictureSource)
        nativePictureSource = nil
        nativePictureOwner = nil
        nativeInspectorImage = nil
        nativeInspectorVideoSource = nil
    }
    /// Retain an accepted held raster through recovery; only a newly admitted picture or clear
    /// retires its render lease. Acquisition callbacks separately check the captured actual source.
    private func publishNativeFrame(_ image: UIImage, clean: UIImage, owner: NativePictureOwner) {
        if !owner.matches(nativePictureOwner) {
            retireNativePictureSource()
            nativePictureOwner = owner
            nativePictureSource = nativePictureBus.openSource(.live)
        }
        if liveFrameSource !== nativePictureSource { liveFrameSource = nativePictureSource }
        if liveFrameImage !== image { liveFrameImage = image }
        nativeInspectorImage = clean
    }
    /// AF / face-detection boxes from the latest live-view frame's header, drawn over the feed.
    var liveViewFocus: PTPLiveViewFocusInfo? {
        didSet {
            // The AF coordinate space belongs to the body, not to one frame, so remember it. Off
            // the camera's own stream no header ever arrives to state it again, and tap-to-focus
            // has to map the tap into that same space or the point lands somewhere else entirely.
            if let focus = liveViewFocus, focus.coordinateWidth > 0, focus.coordinateHeight > 0 {
                lastFocusCoordinateSpace = (focus.coordinateWidth, focus.coordinateHeight)
            }
        }
    }
    /// Last AF coordinate space the camera reported. Survives a switch away from its own stream —
    /// deliberately not cleared by `clearFrameHeaderDerivedState`, which is what makes it useful.
    @ObservationIgnored private var lastFocusCoordinateSpace: (width: Int, height: Int)?
    /// One reported live header measurement. A missing header remains unavailable.
    var observedLiveAudioLevels: MonitorAudioMeterLevels?
    /// Compatibility projection for older native clients; common UI reads the optional observation.
    var liveAudioLevels: MonitorAudioMeterLevels {
        get { observedLiveAudioLevels ?? .silent }
        set { observedLiveAudioLevels = newValue }
    }
    /// How the body is held, from the live-view header's rotation byte (839). The body's own
    /// orientation always lands here so flipping Auto-Rotate Feed back on can restore it.
    /// Only the camera's own stream ever sets this; HDMI capture stays `.landscape`.
    var liveFeedRotation: PTPLiveViewRotation = .landscape
    /// Rotation the monitor applies. Off (``OperatorPreferences/autoRotateFeedEnabled``) keeps
    /// the picture in the camera's native landscape sensor orientation.
    var displayedFeedRotation: PTPLiveViewRotation {
        liveFeedRotation.displayed(autoRotateEnabled: preferences.autoRotateFeedEnabled)
    }
    /// Latest scope bundle, published per throttle tick on the shared sample bus of the
    /// current picture source. A replaced or retired source clears it.
    var scopeAssist: ScopeAssistBundle { nativePictureBus.bundle }
    /// Publishes one bundle for the current picture source; a stale source is rejected.
    func publishLiveScopeBundle(_ bundle: ScopeAssistBundle) {
        nativePictureBus.publish(
            nativePictureSource, source: nil, transfer: bundle.transfer, bundle: bundle)
    }
    /// Async scope derivation retains its original lease, never the source current at completion.
    func captureLiveScopePublication() -> @MainActor (ScopeAssistBundle) -> Void {
        let captured = nativePictureSource
        return { [weak self] bundle in
            _ = self?.nativePictureBus.publish(
                captured, source: nil, transfer: bundle.transfer, bundle: bundle)
        }
    }
    /// A still sampled with no live picture (the demo's mock feed) opens the live source the
    /// frame loop would, or the bus drops its scopes.
    func openStillScopeSource() {
        guard nativePictureSource == nil else { return }
        nativePictureOwner = .local
        nativePictureSource = nativePictureBus.openSource(.live)
    }
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
    /// Capture settings the camera refuses to change (body "Control lock"; `MovieTVLockSetting`
    /// can report shutter locked independently). Set when the body rejects a write or the lock
    /// property reads engaged; cleared when a write succeeds or the poll reports unlocked. The bar
    /// shows a lock so the operator knows to change it on the camera (long-press for shutter).
    var lockedControls: Set<CameraPicker> = []
    var activePanel: ActivePanel? {
        didSet {
            if case .picker(let picker) = activePanel, let setting = picker.nikonControlSetting {
                refreshCommonControlFacts()
                commonEditor = shell.control.edit(setting.key)
            } else {
                commonEditor = nil
            }
            if oldValue == .media, activePanel != .media, !isStandaloneMediaLibraryPresented {
                closeMediaBrowse()
            }
            switch activePanel {
            case .settings: shell.open(.settings)
            case .media: shell.open(.media)
            default:
                // Only the panel's own cover closes with it, never a standalone one. Once the
                // monitor has gone (an internet hop retains the page), the cover is standalone.
                if oldValue == .settings || oldValue == .media, shell.monitor != nil {
                    shell.dismissCover()
                }
            }
            // The Bluetooth shutter only listens while the live view is front — re-reconcile
            // when a full-screen panel opens or closes over it.
            if (oldValue?.coversFullScreen ?? false) != (activePanel?.coversFullScreen ?? false) {
                updateBluetoothShutter()
            }
        }
    }
    @ObservationIgnored private var commonEditor: MonitorControlModel.Editor?
    /// The DISP mode whose chrome the operator is editing on the monitor itself, or `nil` when the
    /// monitor is live. While editing, every element the mode owns mounts — hidden ones at 30% —
    /// with an eye badge on a corner of its bounding box. Session-only.
    var chromeEditorMode: MonitorDisplayMode? { operatorSession.editingMode }
    /// Whether the on-feed 50/50 key has the armed comparison momentarily hidden. Session-only and
    /// deliberately not a preference: it is one half of an A/B, not a setting — see
    /// ``LUTResolution/showsSplitComparisonKey(visibleTools:preferences:)``.
    var splitComparisonMuted = false
    /// Whether `section` mounts on the monitor right now: something feeds it and the operator's
    /// chrome for the current DISP mode shows it (or the editor force-mounts it).
    func chromeSectionMounts(_ section: MonitorDisplayChrome.Section) -> Bool {
        sectionHasASource(section) && operatorSession.mounts(section)
    }

    /// The sections something can fill right now; the shared surface mounts only these.
    var monitorAvailableSections: Set<MonitorDisplayChrome.Section> {
        Set(MonitorDisplayChrome.Section.allCases.filter(sectionHasASource))
    }

    /// Whether anything is actually feeding `section` right now.
    ///
    /// Chrome the operator switched on still hides when nothing can fill it. This is not tidiness:
    /// a readout with no source behind it still looks like an instrument, and the bottom strip in
    /// particular offers pickers that would write to a camera that cannot hear them. Hiding beats
    /// showing "—", which reads as a camera that is attached and silent.
    ///
    /// Only readouts fed by the camera appear here. The assist toolbar, the scopes, the lock and
    /// the FPS chip all keep working on any picture source, because none of them need the camera.
    private func sectionHasASource(_ section: MonitorDisplayChrome.Section) -> Bool {
        let available = monitorAvailability
        switch section {
        case .cameraValues, .codec, .storage, .format:
            return available.cameraControls
        case .batteries:
            // A reading, not a control. The host forwards the camera's charge to every watcher,
            // and the phone's own battery needs no camera at all — gating this on being able to
            // DRIVE the camera hid both from a watcher that was being sent one of them.
            return available.receivesCameraMetadata || !isCameraControlSession
        case .recReadout, .railRecord:
            return available.recordControl
        case .railMedia:
            return available.mediaBrowser
        case .timecode:
            // Photography rents this slot for the SHOTS counter, which has nothing to do with
            // timecode — gate that on the camera link, not on the body's timecode status.
            if isPhotographyMode { return available.cameraControls }
            return available.cameraTimecode && cameraReportsTimecode
        case .focusBox:
            return available.focusBoxes
        case .statusBar, .toolBar, .lockButton, .fps, .railSettings:
            return true
        case .color:
            // The movie tone of the active codec, when the body reports one (R3D NE: Log3G10).
            return available.cameraControls && !isPhotographyMode && codecColorChoices.showsColor
        case .zoomChip:
            // The Nikon integration's control model: zoom stays unknown (no source feeds a chip).
            return controlCapabilities.zoom.isOffered
        case .gimbalStick:
            // No Z body has a motion service, so the model declares no gimbal.
            return controlCapabilities.gimbal.isOffered
        }
    }
    /// Operator Setup rail tab; the shared display owner also keeps each tab's scroll offset
    /// (A2-84), so both survive dismissing the panel back to live view.
    var operatorSettingsTab: MonitorSettingsTab {
        get { operatorSession.settingsTab }
        set { operatorSession.settingsTab = newValue }
    }
    /// One accepted operation survives the intentional settings rehost during an internet hop.
    @ObservationIgnored let settingsAccount = MonitorSettingsAccountModel()
    @ObservationIgnored let settingsSupport = MonitorSettingsSupportModel()
    /// Focus sub-settings the bar doesn't surface (it shows the AF mode). Tracked so the FOCUS
    /// picker's Area / Subject tabs each remember and apply their own value.
    var focusArea = "Single"
    var focusSubject = "Auto"
    /// When non-nil, the next picker present opens on this mode tab (e.g. FOCUS Area = 1).
    var pickerInitialMode: Int?
    var prefersMediaDuration = false
    /// Photo top bar: whether the SHOTS readout is flipped to its storage (GB + %) form.
    var photoPillShowsStorage = false
    let gyroCapture = GyroCaptureCoordinator()

    var isRecording = false {
        didSet {
            guard oldValue != isRecording else { return }
            AppDiagnostics.shared.record(isRecording ? .recordingStarted : .recordingStopped)
        }
    }
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
    @ObservationIgnored private let bluetoothShutter = MonitorRemoteShutter(subsystem: "OpenZCine")
    /// The camera's virtual-horizon roll/pitch (signed degrees) from the live-view header, driving the
    /// level overlay. Nil until the body reports a level — the overlay falls back to CoreMotion then.
    var cameraLevelRoll: Double?
    var cameraLevelPitch: Double?

    init(
        lutFileStore: CustomLUTStore = CustomLUTStore(),
        mediaClipStore: MediaClipStore = MediaClipStore(),
        assist: NikonAssistState? = nil,
        scopePanels: NikonScopePanels? = nil
    ) {
        self.lutFileStore = lutFileStore
        self.mediaClipStore = mediaClipStore
        mediaCacheDirectory = .init(
            root: mediaClipStore.root, fileManager: mediaClipStore.fileManager)
        self.assist = assist ?? .restore()
        self.scopePanels = scopePanels ?? NikonScopePanels()
        self.assist.looks.selection = assistConfiguration.selectedLUT
        let stageStore = MultiviewStagePreferencesStore(
            storage: .standard, key: "multiview.presentation")
        multicam.presentation.attachPersistence(load: stageStore.load, save: stageStore.save)
        multicam.lutFileStore = lutFileStore
        multicam.defaultLUT = { [weak self] in
            self?.assistConfiguration.selectedLUT ?? .builtIn(.nLogRec709)
        }
    }
    /// Operator preferences (which assist tools are on, their order, chrome visibility) persist
    /// across sessions — loaded on launch, saved on every change. Camera exposure/record settings
    /// are deliberately *not* persisted here; the connected camera is their source of truth.
    var preferences = PreferencesStore.loadPreferences() {
        didSet {
            PreferencesStore.save(preferences, previous: oldValue, storage: .standard)
            syncScreenWakePolicy()
            if oldValue.bluetoothShutterEnabled != preferences.bluetoothShutterEnabled {
                updateBluetoothShutter()
            }
        }
    }
    /// The shared Pocket / Insta assist state: which tools are on (live and playback), the clean
    /// view pins and every shared option. Persists itself.
    let assist: NikonAssistState
    /// The shared scope panel stores: each scope's options, size and place.
    let scopePanels: NikonScopePanels
    /// How often each palette tool is used: the shared ranking that orders live and playback.
    var assistToolUsage = PreferencesStore.assistToolUsage.value {
        didSet { PreferencesStore.assistToolUsage.value = assistToolUsage }
    }
    /// The Nikon-only assist settings (LUT catalog pick, level style, zebra units, instant review,
    /// scope panels), also persisted.
    var assistConfiguration = PreferencesStore.loadAssistConfiguration() {
        didSet {
            PreferencesStore.save(assistConfiguration)
            assist.looks.selection = assistConfiguration.selectedLUT
        }
    }
    /// Operator-chosen order of the command-monitor primary grid tiles (drag to reorder), persisted.
    var commandGridOrder = PreferencesStore.commandTileOrder().load() {
        didSet { PreferencesStore.commandTileOrder().save(commandGridOrder) }
    }
    /// File store for custom-imported LUTs, and the current list (refreshed when the picker opens).
    let lutFileStore: CustomLUTStore
    var customLUTs: [StoredCustomLUT] = []
    var redLUTs: [StoredCustomLUT] = []
    /// On-disk cache + index for camera clips (Media page), and the current library list.
    let mediaClipStore: MediaClipStore
    @ObservationIgnored private let mediaCacheDirectory: MonitorMediaCacheDirectory
    private var unopenedMediaRows: [MediaClip] = []
    private(set) var mediaLibrary: MonitorMediaLibraryModel<MediaClip>?
    @ObservationIgnored private var mediaLibraryCodec: NikonMediaLibraryCodec?
    @ObservationIgnored private var mediaLibraryBytes: NikonMediaLibraryByteStore?
    @ObservationIgnored private var mediaLibraryBucket: String?
    @ObservationIgnored private var mediaActionStoreGeneration: UInt64 = 0
    var mediaClips: [MediaClip] {
        get { mediaLibrary?.records.map(\.payload) ?? unopenedMediaRows }
        set {
            guard let owner = mediaLibrary, let codec = mediaLibraryCodec else {
                unopenedMediaRows = newValue
                return
            }
            let token = owner.actionToken
            do {
                let records = try newValue.map(codec.record)
                try owner.applyLocalRecords(
                    .init(
                        resetLibrary: true, upserts: records,
                        sourceFavoriteKeys: Set(newValue.filter(\.isFavorite).map(\.id))),
                    token: token)
            } catch {
                // A retired gallery cannot replace its successor's local metadata.
            }
        }
    }
    var mediaSelectionIsSelecting: Bool {
        get { mediaLibrary?.selecting ?? false }
        set { mediaLibrary?.selecting = newValue }
    }
    var mediaSelectedClipIDs: Set<String> {
        get {
            Set(
                mediaLibrary?.records.filter {
                    mediaLibrary?.selectedIDs.contains($0.asset.id) == true
                }
                .map { $0.payload.id } ?? [])
        }
        set {
            guard let owner = mediaLibrary else { return }
            owner.selectedIDs = Set(
                owner.records.filter { newValue.contains($0.payload.id) }.map { $0.asset.id })
        }
    }
    /// The last grid pass owns its admitted group IDs; current payload lookup preserves native actions.
    @ObservationIgnored private var mediaProjectionSnapshot: NikonAppGalleryProjection?
    var mediaFetchInProgress: Bool { mediaLibrary?.fetching ?? false }
    /// Movie clips discovered so far during an in-flight `fetchClipsFromCamera` listing pass.
    var mediaFetchListedCount: Int {
        mediaFetchInProgress ? mediaProducer?.service.listedCount ?? 0 : 0
    }
    /// Per-clip download progress (`clip.id` → 0…1) while a clip streams from the camera.
    var mediaDownloadProgress: [String: Double] = [:]
    @ObservationIgnored private var mediaDownloadInFlight: Set<String> = []
    /// Deletion progress while a batch delete runs — non-nil hides the per-item grid churn behind
    /// one progress bar, and the grid refreshes once when it clears.
    private var mediaDeletionProgressOverride: MonitorMediaDeletionProgress?
    var mediaDeletionProgress: MonitorMediaDeletionProgress? {
        get {
            mediaLibrary?.deletionProgress ?? mediaDeletionProgressOverride
        }
        set { mediaDeletionProgressOverride = newValue }
    }
    /// Clips whose fetched thumbnail bytes failed to decode this session — skipped by
    /// `fetchThumbnail` so a body that serves garbage for a clip isn't re-queried every scroll.
    @ObservationIgnored private var thumblessClipIDs: Set<String> = []
    /// Debounced re-list while the gallery is open and the body is still writing objects.
    @ObservationIgnored private var galleryRelistTask: Task<Void, Never>?
    /// Tab the last listing pass that ran to completion (not cancelled) was scoped to, nil when
    /// none has. Lets the tab `didSet` skip redundant re-lists; cleared whenever a fresh pass is
    /// scheduled (browser open, source correction, foreground resume) and on session teardown.
    private var mediaFetchCompletedTab: MediaCategoryTab? {
        mediaProducer?.service.coveredCategory.map(MediaCategoryTab.init)
    }
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
    var mediaBrowserSource: MediaBrowserSource = .camera {
        didSet {
            guard oldValue != mediaBrowserSource else { return }
            pruneMediaFiltersToOfferedChips()
        }
    }
    var mediaCategoryTab: MediaCategoryTab = .videos {
        didSet {
            guard oldValue != mediaCategoryTab else { return }
            // Chips the new tab cannot offer would keep filtering invisibly — a MOV filter
            // carried onto Photos empties the grid with nothing in the popup to explain it.
            pruneMediaFiltersToOfferedChips()
            guard mediaBrowserSource == .camera, cameraSession != nil else { return }
            // Tabs are pure filters over already-discovered clips. A pass that completed on
            // All/Favorites enumerated every handle (`scopedHandles`), and one completed on
            // this same tab already covered it — only a tab whose handles the previous scope
            // may have excluded (or a cancelled/interrupted pass) needs the camera again.
            if let completed = mediaFetchCompletedTab,
                completed == .all || completed == .favorites || completed == mediaCategoryTab
            {
                return
            }
            // Re-run the delta pass so the newly selected category's still-unfetched clips jump
            // the queue (cached clips cost nothing; only new handles hit GetObjectInfo).
            scheduleFetchClipsFromCamera()
        }
    }
    var mediaFormatFilters: Set<MediaFormatChip> = []
    var mediaResolutionFilters: Set<NikonMediaResolutionBucket> = []
    /// Still L/M/S size chips — ranked against the sizes present, so this is stills-only.
    var mediaPhotoSizeFilters: Set<NikonMediaPhotoSizeClass> = []
    /// Single relative capture-date window; the windows nest, so they are mutually exclusive.
    var mediaDateWindow: NikonMediaDateWindow?
    var mediaStorageSlotFilter: UInt32?
    var mediaSortOrder: MediaSortOrder = PreferencesStore.loadMediaSortOrder() {
        didSet { PreferencesStore.saveMediaSortOrder(mediaSortOrder) }
    }
    var mediaThumbnailSize: MonitorThumbnailSize = PreferencesStore.loadMediaThumbnailSize() {
        didSet { PreferencesStore.saveMediaThumbnailSize(mediaThumbnailSize) }
    }
    var mediaBrowserLayout: MonitorMediaLayout = PreferencesStore.loadMediaBrowserLayout() {
        didSet { PreferencesStore.saveMediaBrowserLayout(mediaBrowserLayout) }
    }
    /// Per-slot card capacity from the last `refreshMediaStorageSlots` pass.
    var mediaStorageSlots: [MediaStorageSlotDisplay] = []
    /// Actual native stream task captured by an item; retired cleanup cannot stop a successor.
    final class MediaClipStreamTicket {
        let task: Task<Void, Never>
        init(task: Task<Void, Never>) { self.task = task }
    }
    @ObservationIgnored private var clipStreamTicket: MediaClipStreamTicket?
    /// Background task streaming the clip currently open in the player, if any.
    @ObservationIgnored private var clipStreamTask: Task<Void, Never>?
    @ObservationIgnored private var clipStreamClipID: String?
    /// Frame.io: clip ids with an upload in flight (blocks a duplicate upload of one clip), and
    /// the account epoch every captured delivery holds.
    @ObservationIgnored var frameioUploadInFlight: [String: UUID] = [:]
    @ObservationIgnored let frameioAccount = NikonFrameioAccount()
    /// The app-scoped delivery owner: a run survives leaving the gallery or the player (A4-10).
    let delivery = MonitorDeliveryCoordinator()
    var linkHealth = 0
    var linkHealthDetail = "Not connected"

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
        #if DEBUG
            if let demoRecoveryPromptOverride { return demoRecoveryPromptOverride }
        #endif
        return CameraStartupPolicy.recoveryPrompt(
            savedCameras: savedCameras,
            discoveredCameras: discoveredCameras,
            connectedHost: connectedIdentity?.host,
            isIPhoneHotspotBridgeActive: isIPhoneHotspotBridgeActive
        )
    }

    /// Whether iOS has denied USB camera-control access — drives the USB empty state's
    /// permission-recovery copy.
    var isUSBControlAuthorizationDenied: Bool {
        USBCameraDeviceBrowser.shared.isControlAuthorizationDenied
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
        // The scanner and the join button are camera-AP mechanisms. Every other path — hotspot,
        // router, either cable — has no camera SSID to scan or join and would dead-end here.
        if shouldShowFirstPairWizard, !firstPairTransportMethod.joinsCameraAccessPoint {
            return false
        }
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
        guard let rawTarget = pendingCameraWiFiJoinTarget else { return }
        // The name the operator is looking at, which is the scan's unless they corrected it. A
        // misread SSID fails differently from a misread key — nothing to join rather than a
        // refused password — and it used to be uncorrectable for the same reason the key was.
        let corrected = cameraWiFiJoinSSIDDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let target: CameraWiFiJoinPolicy.ProactiveJoinTarget =
            corrected.isEmpty ? rawTarget : .specificSSID(corrected)
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

    /// Whether the current join already has a scanned or manually entered key ready to confirm.
    var cameraWiFiJoinHasPasswordDraft: Bool {
        !cameraWiFiJoinPasswordDraft.isEmpty
    }

    /// Presents the connect card in a "watching this network" state for an armed infrastructure
    /// setup watch, so Find On This Network shows progress from the tap onward. Fulfillment
    /// (`applyDiscoveryResults`) drives the same card through the normal connect phases; Cancel
    /// disarms the watch via `cancelConnectionAttempt`.
    func presentSetupWatchProgress(
        for camera: PTPIPSavedCameraRecord,
        kind: CameraPath.Kind = .infrastructure
    ) {
        connectionProgressDeviceName = ConnectionProgressCopy.resolveDisplayName(
            rawName: camera.displayName, savedCamera: camera)
        connectionProgressIsUSB = kind == .usbC
        connectionProgressPathKind = kind
        connectionProgressShowsFailure = false
        connectionFailureDetail = ""
        connectionPhase = .discovering
        // Says the thing the operator must actually do — a camera that has only ever met this
        // phone one way has no profile for the new path, so it has to be put into its pairing
        // wait by hand. This rides `connectionStageDetail` because that is the only detail the
        // card reads; written to `connectionMessage` alone it never reached the screen, which
        // left the operator watching a spinner — the exact thing the instruction exists to
        // prevent. The connect clears the stage detail when it starts, which is precisely when
        // the instruction stops applying.
        let instruction: String
        switch kind {
        case .phoneHotspot:
            instruction =
                "Turn on Personal Hotspot in Settings, then on the camera: Network menu → Connect to computer → pair with this iPhone's hotspot. We'll connect the moment it joins."
        case .usbC:
            // A cable path has no network step at all, so the network instruction below would be
            // asking the operator to configure something this setup never touches.
            instruction =
                "Connect \(connectionProgressDeviceName) with a USB-C cable. We'll connect the moment it's plugged in."
        default:
            // A router watch armed while this device sits on the CAMERA'S OWN network can never
            // fulfil: the shape test in `applyDiscoveryResults` rejects every candidate on the
            // access point, by design — a body on its own AP is not on anybody's router. Said
            // plainly, because the alternative is what the field hit: a spinner that searches
            // forever with the camera in plain sight and no hint that the phone is the problem.
            // The watch stays armed and self-heals the moment the network changes.
            instruction =
                cameraAccessPointEvidence == true
                ? "This device is on \(connectionProgressDeviceName)'s own Wi-Fi, so there is no network setup to add yet. Join the network you want this setup to use — we keep looking, and the camera appears once you are both on it."
                : NativeNetworkInterfaceSnapshot.currentScanSubnetLabel().map {
                    "Searching \($0), the network this device is on. On the camera: Network menu → Connect to computer → pair with a profile for that same network."
                }
                    ?? "Looking for \(connectionProgressDeviceName) on this network. On the camera: Network menu → Connect to computer → pair with this network's profile."
        }
        connectionStageDetail = instruction
        connectionMessage = instruction
        isConnectionProgressPresented = true
    }

    /// Every camera-AP flow needs the Wi‑Fi radio on; with it off the join can only fail after
    /// a long, confusing search. Called at choose time (scanner open, credential staging) and
    /// again at join time, so a mid-popup Wi‑Fi toggle still lands on the prompt.
    private func ensureWiFiRadioIsOnForCameraAPJoin() -> Bool {
        if NativeNetworkInterfaceSnapshot.isWiFiRadioOn(), !DemoHarness.wiFiRadioOff {
            return true
        }
        isWiFiOffPromptPresented = true
        return false
    }

    /// Opens the on-screen credential scanner over the connect popup.
    func presentCameraWiFiScanner() {
        guard ensureWiFiRadioIsOnForCameraAPJoin() else { return }
        isCameraWiFiScannerPresented = true
    }

    /// Applies credentials scanned from the camera's Connection wizard: stages an exact-SSID join
    /// and pre-fills the key, so the popup's Connect button runs the normal join pipeline.
    func applyScannedCameraWiFi(ssid: String, key: String) {
        stageCameraWiFiCredentials(ssid: ssid, key: key, cameFromScan: true)
    }

    /// Applies credentials copied manually from a camera screen when automatic OCR cannot validate
    /// that body's SSID shape. The exact operator-entered SSID remains authoritative.
    func applyManualCameraWiFi(ssid: String, key: String) {
        stageCameraWiFiCredentials(ssid: ssid, key: key, cameFromScan: false)
    }

    /// "+ Add setup → Camera AP" on a saved camera: stages the camera's own network in the join
    /// popup. With a stored key the popup opens straight on Connect; otherwise it asks for the
    /// key once, in-popup, exactly like a first pair. The record itself is written by the
    /// connect that follows — establishment stamps the AP path from the join it applied.
    func beginAddCameraAPSetup(for camera: PTPIPSavedCameraRecord) {
        // Which camera this setup is FOR. Every other kind already arms this; AP did not, and
        // nothing downstream could then tell the new record which body it belongs to — so it
        // saved itself as a second camera. A host lookup cannot answer this: the AP address is
        // by definition not yet saved.
        pendingSetupIntent = .init(anchor: camera, kind: .cameraAccessPoint)
        guard
            let ssid = CameraWiFiSSID.resolve(for: camera)
                ?? CameraWiFiSSID.deriveSSID(fromCameraName: camera.displayName)
        else {
            // No derivable SSID (custom or generic camera name): the scan reads it off the
            // camera's own network screen, so there is no card to show first.
            presentCameraWiFiScanner()
            return
        }
        // The join card, whose primary button opens the scanner — the wizard's Camera AP shape.
        // The key is deliberately NOT pre-filled from the keychain: a staged key let this card
        // run straight on to connecting, which is what skipped the operator's chance to put the
        // camera on its network screen first.
        stageCameraWiFiCredentials(ssid: ssid, key: "", cameFromScan: false)
    }

    private func stageCameraWiFiCredentials(ssid: String, key: String, cameFromScan: Bool) {
        isCameraWiFiScannerPresented = false
        guard ensureWiFiRadioIsOnForCameraAPJoin() else { return }
        pendingCameraWiFiJoinTarget = .specificSSID(ssid)
        cameraWiFiJoinPasswordDraft = key
        cameraWiFiJoinSSIDDraft = ssid
        cameraWiFiJoinKeyFromScan = cameFromScan
        connectionProgressDeviceName = ssid
        connectionProgressIsUSB = false
        connectionProgressPathKind = nil
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

    var selectedPairingDiscoveryCamera: DiscoveredCamera? {
        let candidates = pairingDiscoveryCandidates
        if let selectedDiscoveredCameraID,
            let selected = candidates.first(where: { $0.id == selectedDiscoveredCameraID })
        {
            return selected
        }
        return candidates.first
    }

    /// The transport wizard, as `AppShell`'s pre-page: when the operator chooses Pair a new
    /// camera, and on first run. With nothing saved the shell routes to its pair page, so a fresh
    /// install reaches the same wizard (Cable Link, Camera AP) as every later pairing, until the
    /// operator chooses the camera list instead (a watcher-only device).
    var shouldShowFirstPairWizard: Bool {
        isPairingNewCamera || (savedCameras.isEmpty && !showsCameraListWithoutSavedCameras)
    }

    /// Plain-language version of `connectionMessage` for startup screens.
    var userFacingConnectionMessage: String {
        StartupConnectionCopy.friendly(connectionMessage, path: connectionProgressPathKind)
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
        moveLegacyRelayPasscodes()
        LiveHDRDisplay.app.setEnabled(hdrDisplay)
        refreshSavedCameras()
        applyStartupDestination()
        if shouldShowFirstPairWizard, firstPairWizardStep == .chooseTransport {
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
        // The post-confirm gap: pairing succeeded on the body and the camera is rebooting its
        // network before the reconnect finds it again. A proactive AP join firing here offered
        // "join NIKON_…" seconds after a ROUTER pairing confirm (from set) — the reconnect
        // machinery owns this window, not the launch-join path.
        guard pendingPairingSaveCandidate == nil else { return false }
        guard discoveryTransportFilter != .usbC else { return false }
        if shouldShowFirstPairWizard, !firstPairTransportMethod.joinsCameraAccessPoint {
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
            cameraWiFiJoinSSIDDraft = ""
            return CameraWiFiPasswordSubmission(ssid: ssid, password: draftPassword)
        }

        // No stored or typed password: attempt an open join; a secured AP fails with a
        // friendly error and the retry re-prompts.
        return CameraWiFiPasswordSubmission(ssid: ssid, password: "")
    }

    /// SSIDs whose join offer the operator explicitly cancelled this session. Cancel means no:
    /// re-offering the same alert minutes later from a reconnect, a launch join or a setup watch
    /// is how "very persistent" prompts happen, and no record heuristic can override a human
    /// who just said no. Session-scoped on purpose; a fresh launch is a fresh question. The
    /// operator's own Connect or Try again is that fresh question too (`forgetDeclinedJoin`).
    @ObservationIgnored private var declinedJoinSSIDs: Set<String> = []

    /// Whether the operator has declined joining `ssid` this session.
    private func joinWasDeclined(ssid: String?, prefix: String?) -> Bool {
        if let ssid, declinedJoinSSIDs.contains(ssid) { return true }
        // A prefix target would re-surface the very SSID that was refused.
        if let prefix, declinedJoinSSIDs.contains(where: { $0.hasPrefix(prefix) }) { return true }
        return false
    }

    /// Lifts the latch for one network when the operator asks for it again. Keeping it made
    /// their Try again skip the join and dial the camera's access-point address from whatever
    /// network the phone was on (FINAL-Z3-08), so only a relaunch could connect.
    private func forgetDeclinedJoin(ssid: String?, prefix: String?) {
        if let ssid { declinedJoinSSIDs.remove(ssid) }
        if let prefix { declinedJoinSSIDs = declinedJoinSSIDs.filter { !$0.hasPrefix(prefix) } }
    }

    private func joinCameraNetwork(
        target: CameraWiFiJoinPolicy.ProactiveJoinTarget,
        credentials: CameraWiFiPasswordSubmission,
        joinStrategy: WiFiJoinCoordinator.JoinStrategy
    ) async throws {
        try await cameraNetworkJoinOperation(
            target: target, credentials: credentials, joinStrategy: joinStrategy)()
    }

    /// Captures the join inputs without keeping the model alive while the system alert waits.
    private func cameraNetworkJoinOperation(
        target: CameraWiFiJoinPolicy.ProactiveJoinTarget,
        credentials: CameraWiFiPasswordSubmission,
        joinStrategy: WiFiJoinCoordinator.JoinStrategy
    ) -> @MainActor () async throws -> Void {
        #if DEBUG
            if let peers = cameraNetworkJoinPeers {
                return { try await peers.join(target) }
            }
        #endif
        // Hotspot work still queued behind an earlier pending join runs only for this connection.
        let generation = connectionGeneration
        let isCurrent: CameraNetworkIsCurrent = { [weak self] in
            self?.connectionGeneration == generation
        }
        return { [weak self] in
            switch target {
            case .specificSSID(let ssid):
                try await WiFiJoinCoordinator.shared.joinCameraNetwork(
                    ssid: ssid,
                    password: credentials.password,
                    strategy: joinStrategy,
                    isCurrent: isCurrent
                )
            case .ssidPrefix(let prefix):
                if let resolvedSSID = credentials.ssid, !resolvedSSID.isEmpty {
                    try await WiFiJoinCoordinator.shared.joinCameraNetwork(
                        ssid: resolvedSSID,
                        password: credentials.password,
                        strategy: joinStrategy,
                        isCurrent: isCurrent
                    )
                } else {
                    try await WiFiJoinCoordinator.shared.joinCameraNetwork(
                        ssidPrefix: prefix,
                        password: credentials.password,
                        strategy: joinStrategy,
                        isCurrent: isCurrent
                    )
                }
            }
            guard isCurrent() else { throw CancellationError() }
            self?.sessionJoinedCameraAccessPoint = true
            let connectedSSID = await NativeNetworkInterfaceSnapshot.currentWiFiSSID()
            guard isCurrent(), let connectedSSID, !connectedSSID.isEmpty else { return }
            CameraWiFiCredentialStore.savePassword(credentials.password, forSSID: connectedSSID)
            self?.connectedWiFiSSID = connectedSSID
        }
    }

    /// Latches a human "no" so nothing re-offers the same network this session.
    private func recordDeclinedJoinIfUserSaidNo(_ error: any Error, ssid: String?) {
        guard case WiFiJoinCoordinator.JoinError.userDenied = error, let ssid, !ssid.isEmpty
        else { return }
        declinedJoinSSIDs.insert(ssid)
        logConnection("join declined by operator — offers for \(ssid) muted this session")
    }

    func surfaceCameraWiFiJoinFailure(
        _ message: String, refusal: CameraHotspotJoinRefusal? = nil
    ) {
        AppDiagnostics.shared.record(.connectionWifiJoinFailed)
        // The connect card reads the typed refusal for its shared copy and Settings fallback.
        lastConnectError = refusal
        lastConnectFailureReason = .joinFailed
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
        connectionProgressPathKind = nil
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
        // Saved-row taps and post-hop rejoins reach here without passing the choose-time gates.
        guard ensureWiFiRadioIsOnForCameraAPJoin() else {
            dismissConnectionProgress()
            return
        }

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
                _ = await directConnectLoop(
                    host: reconnectHost, deviceName: deviceName, maxAttempts: 6,
                    viaCameraAccessPointJoin: true)
                // Exhausted or connected either way — the last attempt owns the card.
                return
            }

            // Camera-AP topology is KNOWN: the body hosts the network at a fixed address (a
            // saved AP setup's host, else the Nikon convention). Dial it directly — running a
            // network search for an address we can already name is the whole
            // "Searching…-fails-then-instant-retry" shape. Discovery below stays the fallback
            // for a body at a nonstandard address.
            if case .specificSSID(let joinedSSID) = target,
                let direct = cameraAPDirectHost(ssid: joinedSSID)
            {
                connectionPhase = .discovering
                connectionMessage = "Connecting to \(deviceName)…"
                if await directConnectLoop(
                    host: direct, deviceName: deviceName, maxAttempts: 2,
                    viaCameraAccessPointJoin: true)
                {
                    return
                }
                guard !Task.isCancelled, isConnectionProgressPresented else { return }
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
                if discoveredCameras.contains(where: { !$0.isUSB }) || isEstablishingConnection {
                    break
                }
            }
            guard !Task.isCancelled, !isEstablishingConnection else { return }
            // The operator consented to this join, so ANY camera on the just-joined network is
            // the one they meant — the saved-camera filter must not hide a body that already
            // has setups on other paths (the add-setup AP join failed exactly there).
            if let camera = pairingDiscoveryCandidates.first
                ?? discoveredCameras.first(where: { !$0.isUSB })
            {
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
            case .invalidSSID, .timedOut, .system, .refused:
                switch error {
                case .system, .refused:
                    // A stored wrong password would fail every retry with no way to re-enter
                    // it; drop it so the next attempt re-prompts.
                    // ponytail: also drops a valid password on other association failures.
                    clearStoredCameraWiFiPassword(for: target)
                default:
                    break
                }
                if !isConnectionProgressPresented {
                    presentCameraWiFiJoinProgress(deviceName: deviceName)
                }
                if case .refused(let refusal) = error {
                    surfaceCameraWiFiJoinFailure(message, refusal: refusal)
                } else {
                    surfaceCameraWiFiJoinFailure(message)
                }
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

    /// A saved dialable address for a camera-AP SSID, if one was learned on a previous connect.
    /// Never invents a global AP IP — nil means rediscover on the live link after join.
    private func cameraAPDirectHost(ssid: String) -> String? {
        guard
            let saved = savedCameras.first(where: { record in
                if case .cameraAccessPoint(let recorded?) = record.path {
                    return recorded == ssid
                }
                return false
            }), CameraDiscovery.isDialableHost(saved.host)
        else { return nil }
        return saved.host
    }

    /// Dials one known host through the single-flighted connect until it lands or attempts run
    /// out. Returns whether this loop resolved the card — connected, or handed off to the
    /// post-pairing wait; the last attempt's failure card stays up.
    private func directConnectLoop(
        host: String, deviceName: String, maxAttempts: Int,
        viaCameraAccessPointJoin: Bool = false
    ) async -> Bool {
        cameraHost = host
        for attempt in 1...maxAttempts {
            // `isConnectionProgressPresented` goes false when the operator taps Cancel/Close
            // on the card — stop retrying then, even though the .handshaking phase isn't one
            // `dismissConnectionProgress` cancels this task from.
            guard !Task.isCancelled, isConnectionProgressPresented else { return false }
            connectToCamera(viaCameraAccessPointJoin: viaCameraAccessPointJoin)
            // Wait for the single-flighted attempt to resolve (success or ~10s Init timeout).
            while isEstablishingConnection {
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled else { return false }
            }
            if isConnected { return true }
            // Pairing just handed the card to the "Confirm on camera" wait (the only thing that
            // arms this). Retrying over that hand-off is what overwrote the instruction before
            // the operator could read it and then redialled a body busy rebooting its access
            // point — "Establishing a secure link…", then "The camera ended the connection".
            // The paired-reconnect machinery owns the return from here.
            if pendingPairedReconnectHost != nil { return true }
            guard attempt < maxAttempts, isConnectionProgressPresented else { break }
            // Hold the card in a reconnecting state (not the flashed failure) and give the
            // ZR a moment to release the stale session before the next Init.
            connectionProgressShowsFailure = false
            connectionPhase = .discovering
            connectionMessage = "Reconnecting to \(deviceName)…"
            try? await Task.sleep(for: .seconds(2))
        }
        return false
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

    /// The camera-AP SSID of the setup about to be forgotten, if that is what this host is.
    /// Router, hotspot and USB setups own no Wi-Fi key, so they clear nothing.
    private func accessPointSSIDBeingForgotten(host: String) -> String? {
        let normalized = PTPIPPairedHosts.normalizedHost(host)
        guard
            let record = savedCameras.first(where: {
                PTPIPPairedHosts.normalizedHost($0.host) == normalized
            }),
            record.path?.kind == .cameraAccessPoint
        else { return nil }
        return CameraWiFiSSID.resolve(for: record)
    }

    /// Removing a camera-AP setup takes its stored key with it: keeping the key is what let a
    /// re-added setup join silently, so the operator could not tell a remembered camera from a
    /// forgotten one — and could not clear it at all short of deleting the app.
    private func clearCameraWiFiCredential(forForgottenSSID ssid: String?) {
        guard let ssid, !ssid.isEmpty else { return }
        CameraWiFiCredentialStore.deletePassword(forSSID: ssid)
        // The prefix entry is the "any NIKON_ZR_… " fallback a first join writes before an exact
        // SSID is known, so it is shared. It only goes when no access-point setup is left to
        // use it — otherwise forgetting one body would break the join for another.
        let accessPointSetupsRemain = savedCameras.contains {
            $0.path?.kind == .cameraAccessPoint
        }
        if !accessPointSetupsRemain {
            CameraWiFiCredentialStore.deletePassword(
                forPrefix: CameraWiFiSSID.nikonAccessPointPrefix)
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
        // Camera-AP's last step hands off to the Wi-Fi scanner rather than to another step.
        if firstPairWizardStep == .connectNetwork, firstPairTransportMethod == .cameraAccessPoint {
            presentCameraWiFiScanner()
            return
        }
        guard
            let next = firstPairWizardStep.next(
                transport: firstPairTransportMethod,
                skipsPermissions: firstPairWizardSkipsPermissions)
        else { return }
        if next == .discoverAndPair {
            enterFirstPairDiscoveryStep()
        } else {
            firstPairWizardStep = next
        }
    }

    func retreatFirstPairWizard() {
        guard shouldShowFirstPairWizard else { return }
        guard
            let previous = firstPairWizardStep.previous(
                transport: firstPairTransportMethod,
                skipsPermissions: firstPairWizardSkipsPermissions)
        else { return }
        // Leaving discovery must stop the scan it started; nothing else here has a side effect.
        if firstPairWizardStep == .discoverAndPair { stopDiscoveryLoop() }
        firstPairWizardStep = previous
    }

    /// Whether the wizard shows a Back control on the current step.
    func firstPairWizardCanRetreat(from step: FirstPairWizardStep) -> Bool {
        step.previous(
            transport: firstPairTransportMethod,
            skipsPermissions: firstPairWizardSkipsPermissions) != nil
    }

    /// Seeds the wizard at the transport choice; a wireless choice then visits permissions unless
    /// Local Network access was already acknowledged.
    private func configureFirstPairWizardEntry() {
        firstPairWizardSkipsPermissions = StartupPermissionsCoordinator.permissionsAlreadySatisfied(
            alreadyPairedCameras: !savedCameras.isEmpty
        )
        firstPairWizardStep = .chooseTransport
        // No relay browse here: the wizard is the first screen of a fresh install, and any
        // Bonjour browse raises the system Local Network prompt before the operator has chosen
        // a path or reached the permissions step. A watcher-only device reaches broadcasts by
        // choosing to: the pair page's watch-feed entry opens the shared browse, and the
        // "Open the camera list" row starts the list's discovery, as in Pocket and Insta.
    }

    private func enterFirstPairDiscoveryStep() {
        firstPairWizardStep = .discoverAndPair
        discoveryTransportFilter = firstPairTransportMethod.isCableLink ? .usbC : .wiFi
        // HDMI has nothing to discover: a capture device is either attached or it isn't, and the
        // step shows its status instead of a camera list. Starting a scan here would spin the
        // radios looking for a camera the operator has already said they aren't connecting to.
        guard firstPairTransportMethod != .hdmiCapture else { return }
        beginPairingDiscovery()
    }

    /// Clears the explicit "pair new camera" override once pairing completes, so the wizard yields
    /// back to the saved-camera home.
    private func markFirstPairWizardCompleted() {
        isPairingNewCamera = false
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
        // Zero saved cameras is a legitimate place to live once the operator has chosen the
        // list — the wizard's "open the camera list" row is exactly that choice.
        showsCameraListWithoutSavedCameras = true
        shell.showCameras()
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
            connectToCamera(selectedPairingDiscoveryCamera, operatorRequested: true)
        } else {
            connectToCamera(operatorRequested: true)
        }
    }

    func connectSavedCamera(_ camera: PTPIPSavedCameraRecord) {
        cameraHost = camera.host
        connectToCamera(setup: camera, operatorRequested: true)
    }

    /// Dismisses the connection progress sheet without tearing down an active session.
    func dismissConnectionProgress() {
        // The connection made it (or the operator left): the phase watchdog's job is done.
        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = nil
        if connectionPhase == .joiningWiFi || connectionPhase == .readyToJoin
            || connectionPhase == .discovering
            || pendingCameraWiFiJoinTarget != nil
        {
            cameraWiFiJoinTask?.cancel()
        }
        pendingCameraWiFiJoinTarget = nil
        cameraWiFiJoinPasswordDraft = ""
        cameraWiFiJoinKeyFromScan = false
        cameraWiFiJoinSSIDDraft = ""
        isCameraWiFiScannerPresented = false
        isConnectionProgressPresented = false
        connectionPhase = .idle
        connectionProgressShowsFailure = false
        connectionFailureDetail = ""
    }

    /// Cancels an in-flight connection attempt from the progress sheet.
    func cancelConnectionAttempt() {
        cameras.consent.retire()
        guard isConnectionProgressPresented else { return }
        // Cancel is the operator giving up — disarm the paired-reconnect watcher too, or the
        // background discovery loop keeps re-launching connects they just cancelled.
        pendingPairedReconnectHost = nil
        pendingPairedReconnectSSID = nil
        lastPairedRejoinAttemptAt = nil
        pairedReconnectSawCameraLeave = false
        pairedReconnectFastPathTask?.cancel()
        pairedReconnectFastPathTask = nil
        // A pairing the operator walked away from leaves no row behind. Only a row THIS pairing
        // created, and only while nothing ever connected through it — a live session means the
        // setup earned its place whatever the card is doing.
        if let created = pairingCreatedRecordHost, !isConnected {
            logConnection("pairing abandoned — removing unconfirmed setup host=\(created)")
            NativeCameraConnectionStore.shared.forgetPairing(host: created)
            savedCameras = NativeCameraConnectionStore.shared.savedCameras()
        }
        pairingCreatedRecordHost = nil
        // An armed setup watch dies with its card for the same reason.
        pendingSetupIntent = nil
        lastInfrastructureMiss = nil
        infrastructureSearchEmptyStreak = 0
        isManualCameraHostEntryPresented = false
        manualCameraHostDraft = ""
        let failedAttempt = connectionProgressShowsFailure
        dismissConnectionProgress()
        guard !failedAttempt else { return }
        disconnectCameraSession(resetConnection: true)
        startDiscoveryLoop(resetResults: false)
    }

    private func beginConnectionProgress(
        host: String,
        discoveredCamera: DiscoveredCamera?,
        setup: PTPIPSavedCameraRecord? = nil
    ) {
        let normalizedHost = PTPIPPairedHosts.normalizedHost(host) ?? host
        let savedCamera = setup ?? savedCameras.first { $0.host == normalizedHost }
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
        // The tapped setup's own declaration when there is one; otherwise all we can honestly say
        // is whether this is a cable, which is the only distinction the copy actually turns on.
        connectionProgressPathKind =
            savedCamera?.pathKind ?? (connectionProgressIsUSB ? .usbC : nil)
        connectionProgressShowsFailure = false
        connectionFailureDetail = ""
        connectionPhase = .handshaking
        isConnectionProgressPresented = true
    }

    /// True while a connection is being established — single-flights `connectToCamera` so overlapping
    /// Init attempts can't stack (see the guard inside).
    @ObservationIgnored private var isEstablishingConnection = false {
        didSet { syncReportingCameraPath() }
    }
    /// Reports stay held back (A6-08) from a connect attempt through pairing, live view and
    /// recovery, until no attempt, no session and no held connection state remain.
    @ObservationIgnored private var reportingCameraPath: ReliabilityCameraPathLease?

    private func syncReportingCameraPath() {
        let held = isEstablishingConnection || cameraSession != nil || connection.holdsCameraPath
        if held, reportingCameraPath == nil {
            reportingCameraPath = ReliabilityDiagnostics.reporting.beginCameraPath()
        } else if !held, let lease = reportingCameraPath {
            reportingCameraPath = nil
            lease.end()
        }
    }

    /// Whether THIS connection attempt applied a camera access-point Wi-Fi configuration.
    /// Feeds the saved record's `pairedViaCameraAccessPoint` evidence on connect success.
    @ObservationIgnored private var sessionJoinedCameraAccessPoint = false

    /// The DECLARED path of the live session, locked at establishment success and held across
    /// every recovery attempt. Recovery, the join gate and the relay's AWDL decision all
    /// dispatch on THIS — never on saved records or a live SSID read: the session proved its
    /// topology once, at establishment, and that answer does not change while it lives.
    @ObservationIgnored private var activeSessionPath: CameraPath?

    /// The a0864f1 latch, now derived: "did this session establish over the camera's AP".
    private var establishedSessionUsedCameraAP: Bool {
        activeSessionPath?.kind == .cameraAccessPoint
    }

    /// Compatibility entry for the currently displayed consent, consumed by the shared owner.
    func confirmTakeOver() {
        if let request = cameras.consent.pending { cameras.consent.confirm(request.id) }
    }

    func cancelTakeOver() {
        if let request = cameras.consent.pending { cameras.consent.cancel(request.id) }
    }

    /// - Parameter setup: the saved setup the operator actually tapped, when there is one.
    ///   THE identity of a connect attempt. A record's `id` is `host|name|kind` precisely because
    ///   one body's access-point and router setups can share an address, so re-deriving the record
    ///   from the dialled host alone returns whichever setup happens to sit first in the canonical
    ///   order — and the whole path dispatch downstream (`performWiFiJoinIfNeeded`) then runs the
    ///   wrong path's machinery. Tapping the AP setup silently took the router's branch, which is
    ///   why it never offered the join. Passed down rather than stored so it cannot go stale.
    /// - Parameter operatorRequested: the operator's own tap (Connect, Try again), as opposed to a
    ///   reconnect, setup watch or recovery. Only such a tap may re-offer a declined join.
    func connectToCamera(
        _ discoveredCamera: DiscoveredCamera? = nil,
        preservingMonitorSurface: Bool = false,
        viaCameraAccessPointJoin: Bool = false,
        setup: PTPIPSavedCameraRecord? = nil,
        takingOverConfirmed: Bool = false,
        operatorRequested: Bool = false
    ) {
        // While the multicam stage is up its members own their links: no single-camera connect
        // starts underneath it (a lent member's Live View recovery still may).
        if multicam.isPresented, multicam.lentMember == nil { return }
        // The gate lives at the funnel every path already goes through, not on the row that
        // happens to show the holder — a second entry point to connecting must not be a second
        // way to drop someone else's session without asking.
        cameras.consent.retire(source: "native-connect")
        if let discoveredCamera, discoveredCamera.isHeldByAnotherDevice, !takingOverConfirmed {
            let generation = connectionGeneration
            cameras.consent.present(
                NikonTakeOverPrompt(
                    camera: discoveredCamera.displayName, holder: discoveredCamera.heldByDeviceName,
                    confirm: { [weak self] in
                        self?.connectToCamera(
                            discoveredCamera, preservingMonitorSurface: preservingMonitorSurface,
                            viaCameraAccessPointJoin: viaCameraAccessPointJoin, setup: setup,
                            takingOverConfirmed: true, operatorRequested: operatorRequested)
                    }, cancel: {}),
                source: "native-connect",
                isCurrent: { [weak self] in
                    guard let self, self.connectionGeneration == generation,
                        !self.multicam.isPresented || self.multicam.lentMember != nil
                    else { return false }
                    return setup.map { saved in self.savedCameras.contains { $0.id == saved.id } }
                        ?? true
                })
            return
        }
        // An attempt carries only its OWN access-point evidence — except one dialled straight off
        // a join this app just applied, which is the strongest proof there is. Clearing it
        // unconditionally threw that proof away one line before the pairing branch asked for it,
        // so the post-pairing wait got no SSID to chase and nothing ever pulled the phone back
        // onto the camera's rebooted network.
        sessionJoinedCameraAccessPoint = viaCameraAccessPointJoin
        relaySoloFPSBaseline = 0
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
        // state machine — coalesce extra triggers instead of stacking attempts. The latch is
        // released by whichever comes first: this attempt finishing, or a teardown replacing it
        // (`clearCameraSessionState`), so a failed or cancelled attempt never blocks the retry.
        guard !isEstablishingConnection else { return }
        // An auto-reconnect behind a preserved monitor keeps the operator on the frozen frame with
        // the RECOV badge — the full-screen connection progress is for operator-initiated connects.
        if !preservingMonitorSurface {
            // A fresh operator connect starts a fresh storm ledger (`SessionDropStormGuard`).
            recoveryEpisode.resetStorm()
            beginConnectionProgress(
                host: host,
                discoveredCamera: discoveredCamera,
                setup: setup
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
        // Claimed AFTER the clear (which releases it) and scoped to this generation: a teardown
        // frees the latch immediately, so the operator's next tap is never swallowed while an
        // abandoned attempt is still unwinding a blocking socket read.
        isEstablishingConnection = true
        // Bounded phase timeouts belong to operator-initiated connects: a recovery attempt behind a
        // preserved monitor is already bounded by its own loop, and failing it here could overlap a
        // second Init with a socket read the first attempt is still blocked in.
        if !preservingMonitorSurface {
            startConnectionTimeoutWatchdog(
                generation: generation,
                isUSB: host.hasPrefix(DiscoveredCamera.usbHostKeyPrefix))
        }
        let hadPriorSession = previousSession != nil || sessionTeardownTask != nil
        let previousTeardown = sessionTeardownTask
        establishmentTask = Task { [weak self] in
            // Only this generation's owner may release the latch — a stale attempt finishing late
            // must not unlatch the attempt that replaced it.
            defer {
                if self?.connectionGeneration == generation {
                    self?.isEstablishingConnection = false
                    // `enterLiveView` is this task's LAST statement, so cancelling the phase
                    // watchdog here disarmed the `.preparingLiveView` budget at the exact
                    // instant it began — "connected but never started live view" then had no
                    // bounded exit (the audit's H2). The first decoded frame cancels it via
                    // `dismissConnectionProgress`; teardown paths cancel it themselves.
                    if self?.connectionPhase != .preparingLiveView {
                        self?.connectionTimeoutTask?.cancel()
                        self?.connectionTimeoutTask = nil
                    }
                }
            }
            if let previousSession {
                await previousSession.stopLiveView()
                // Graceful CloseSession before dropping sockets — a bare close leaves the ZR
                // holding a stale session that wedges the reconnect (`NativeCameraSession.shutdown`).
                await previousSession.shutdown()
            }
            // Also await any teardown from an earlier disconnect: the camera accepts one command
            // channel per initiator, and Init over a half-closed prior channel can wedge it.
            await previousTeardown?.value
            // Settle before opening a fresh Init on a RECONNECT: the ZR can briefly hold the PTP
            // slot after CloseSession/socket close, and a same-instant Init is what tips a fragile
            // reconnect into a wedge (the log's attempt→timeout→attempt dance). Only on reconnect —
            // a cold first connect has nothing to wait for. [verify-on-HW: tune this settle to the
            // camera's real slot-release time.]
            if hadPriorSession {
                try? await Task.sleep(for: .milliseconds(1200))
            }
            guard self?.connectionGeneration == generation else { return }
            let store = NativeCameraConnectionStore.shared
            let savedCameras = store.savedCameras()
            let knownPairedCameras = store.knownPairedCameras()
            // The tapped setup wins outright. The host fallback is for connects that genuinely
            // have no record behind them (first-run pairing, a discovery auto-reconnect) — it may
            // never stand in for a setup the operator chose, because a host can name more than
            // one of them.
            let savedCamera =
                setup
                ?? savedCameras.first {
                    $0.host == PTPIPPairedHosts.normalizedHost(host)
                }
            // Saved (trusted) camera → silent reconnect; unknown camera → the (auto-accepted)
            // pairing handshake. We never run the silent probe on an unknown network camera
            // because it is destructive to a camera sitting on its Wi-Fi pairing wizard; USB
            // cameras probe first (no wizard to disturb over the cable).
            let transportKind: CameraTransportKind =
                host.hasPrefix(DiscoveredCamera.usbHostKeyPrefix) ? .usb : .ptpIP
            let join: (@MainActor () async throws -> Void)?
            do {
                guard let self, self.connectionGeneration == generation else { return }
                join = prepareWiFiJoinIfNeeded(
                    transportKind: transportKind,
                    savedCamera: savedCamera,
                    discoveredCamera: discoveredCamera,
                    deviceName: connectionProgressDeviceName,
                    operatorRequested: operatorRequested)
            }
            do {
                try await join?()
            } catch is CancellationError {
                guard let self, self.connectionGeneration == generation else { return }
                dismissConnectionProgress()
                return
            } catch {
                guard let self, self.connectionGeneration == generation else { return }
                AppDiagnostics.shared.record(
                    transportKind == .usb
                        ? .connectionUsbFailed : .connectionWifiJoinFailed)
                // Behind a preserved monitor the recovery loop owns the outcome — see the
                // establishment catch below.
                if preservingMonitorSurface, isMonitorPresented { return }
                connection = .disconnected
                connectionPhase = .failed
                connectionProgressShowsFailure = true
                connectionMessage =
                    Self.friendlyCameraWiFiJoinMessage(for: error)
                connectionFailureDetail = connectionMessage
                startDiscoveryLoop(resetResults: false)
                return
            }
            // A router or hotspot setup the list does not see is dialled at its stored address
            // blind. Ask the network first (`NikonBodyWake`): a body that answers goes on, a
            // silent one ends here with copy naming the real cause, not a PTP timeout.
            if transportKind == .ptpIP, discoveredCamera == nil, !preservingMonitorSurface,
                let kind = savedCamera?.path?.kind, kind == .infrastructure || kind == .phoneHotspot
            {
                do {
                    guard let self, self.connectionGeneration == generation else { return }
                    connectionPhase = .discovering
                    connectionMessage = NikonBodyWake.wakingMessage(
                        deviceName: connectionProgressDeviceName)
                }
                let wake = await NikonBodyWake.awaitAnswer(
                    host: host, isAlive: { await NativeNikonDiscovery.dialer.isAlive($0) })
                do {
                    guard let self, self.connectionGeneration == generation else { return }
                    logConnection("wake host=\(host) \(wake)")
                    if !wake.answered {
                        AppDiagnostics.shared.record(.connectionPtpFailed)
                        connection = .disconnected
                        connectionPhase = .failed
                        connectionProgressShowsFailure = true
                        connectionMessage = NikonBodyWake.silentMessage(
                            deviceName: connectionProgressDeviceName)
                        connectionFailureDetail = connectionMessage
                        startDiscoveryLoop(resetResults: false)
                        return
                    }
                    connectionPhase = .handshaking
                }
            }
            AppDiagnostics.shared.record(.connectionHandshaking)
            let strategy = CameraStartupPolicy.connectionStrategy(
                host: host,
                savedCameras: savedCameras,
                transportKind: transportKind
            )
            let displayNameHint = discoveredCamera?.displayName ?? savedCamera?.displayName ?? ""
            let transport: String
            let establish:
                @MainActor () async throws -> (
                    session: NativeCameraSession, requestedPairing: Bool
                )
            do {
                guard let self, self.connectionGeneration == generation else { return }
                transport =
                    transportKind == .usb
                    ? PTPIPSavedCameraRecord.usbTransportLabel
                    : transportLabel(
                        for: discoveredCamera?.source, fallback: savedCamera?.transport)
                pendingPairingSaveCandidate = PendingPairingSaveCandidate(
                    host: host,
                    displayName: displayNameHint,
                    transport: transport,
                    // Saved row first, then the add-setup anchor: a new setup's address is not yet
                    // saved, so only the operator's own choice of row can name the body.
                    serialNumber: savedCamera?.serialNumber
                        ?? pendingSetupIntent?.anchor.serialNumber
                )
                connection = .scanning
                connectionPhase = .handshaking
                isDemoSession = false
                // A recovery reconnect PROMISES the held frame stays up - blanking it here was
                // the "black flicker for a few frames" on every fast heal. Only a fresh,
                // operator-initiated connect starts from an empty monitor.
                if !preservingMonitorSurface { liveFrameImage = nil }
                acceptedPairingForCurrentAttempt = false
                establishmentDiagnostic.withLock { $0 = "" }
                connectionMessage = startupConnectionMessage(for: strategy, host: host)
                logConnection(
                    "attempt host=\(host) path=\(savedCamera?.path?.kind.rawValue ?? "none")"
                        + "\(setup == nil ? " (derived)" : " (tapped)")"
                        + " strategy=\(strategy) saved=\(savedCameras.count)"
                        + " knownPaired=\(knownPairedCameras.count)"
                )
                establish = establishStartupSession(
                    host: host, guid: store.guid(), strategy: strategy,
                    allowsPairingEscalation: !preservingMonitorSurface)
            }
            do {
                let attempt: (session: NativeCameraSession, requestedPairing: Bool)
                do {
                    attempt = try await establish()
                } catch let error
                    where strategy == .savedProfile && !preservingMonitorSurface
                    && NativeCameraSession.isRetryableEstablishFailure(
                        error, requestPairing: false)
                {
                    // A first attempt over a fresh camera-AP join regularly dies in the
                    // app-control switch while the body is still finishing its own bring-up —
                    // and the manual Try again then connects almost instantly. Run that retry
                    // for the operator, once, after a short settle. Pairing flows keep manual
                    // behavior (a retry must never loop a PIN prompt).
                    guard self?.connectionGeneration == generation else { return }
                    logConnection(
                        "first establish failed, auto-retrying host=\(host) "
                            + error.localizedDescription)
                    self?.connectionMessage = "The camera answered slowly \u{2014} trying again…"
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    guard self?.connectionGeneration == generation else { return }
                    attempt = try await establish()
                }
                let initialSession = attempt.session
                let requestedPairing = attempt.requestedPairing
                // Torn down while establishing (operator disconnect, new attempt): close the fresh
                // session instead of publishing it into cleared state. Graceful CloseSession so the
                // camera releases the slot we just opened (bare close would strand it).
                guard self?.connectionGeneration == generation else {
                    await initialSession.shutdown()
                    return
                }

                if requestedPairing, self?.acceptedPairingForCurrentAttempt == true {
                    self?.savePairedCamera(
                        host: initialSession.identity.host,
                        displayName: initialSession.identity.displayName,
                        transport: transport,
                        serialNumber: initialSession.identity.serialNumber)
                    // Closing the pairing session must not retain its UI owner either.
                    await initialSession.shutdown()
                    guard let self, self.connectionGeneration == generation else { return }
                    pendingPairingSaveCandidate = nil
                    pendingPairedReconnectHost = initialSession.identity.host
                    pendingPairedReconnectSSID = cameraAccessPointSSID(
                        host: initialSession.identity.host,
                        displayName: initialSession.identity.displayName)
                    transitionToSavedCameraNetworkCheck(
                        message:
                            "Pairing complete. Tap “Confirm” on the camera \u{2014} we'll reconnect automatically."
                    )
                    return
                }
                guard let self, self.connectionGeneration == generation else {
                    await initialSession.shutdown()
                    return
                }
                let session = initialSession

                pendingPairingSaveCandidate = nil
                discoveredCameras = []
                pendingPairingChallenge = nil
                cameraSession = session
                bindMonitorRuntime(session)
                // This monitor session has a camera behind it, and stays that way across reconnect
                // gaps — see `isCameraControlSession`.
                isCameraControlSession = true
                connectedIdentity = session.identity
                startKeepAlive(session: session)
                startEventDraining(session: session)
                startLinkHealthMonitoring()
                // Locked for the session's lifetime — recovery dispatches on THIS, not records.
                // The declared path comes from the same resolution the record save uses: the
                // session's own join proof outranks everything, then the wizard's declaration,
                // then the host's shape.
                activeSessionPath = declaredPathForSave(
                    host: session.identity.host,
                    displayName: session.identity.displayName,
                    setup: setup)
                // The session just proved its topology; a broadcast started before it (or across
                // a path switch) may be advertising for the wrong one. Peer-to-peer is worth its
                // radio cost only on an AP session — and only matters for viewers still LOOKING,
                // so the bounce is limited to an advertisement nobody has answered yet. (The
                // rebound listener asks for its old port back, so even a watcher mid-redial
                // lands on the live listener rather than a dead SRV record.)
                if isRelayBroadcasting, relayPeerCount == 0,
                    relayHostAdvertisesPeerToPeer != establishedSessionUsedCameraAP
                {
                    setRelayBroadcasting(false)
                    setRelayBroadcasting(true)
                } else {
                    // Broadcast-before-connect: the advertisement now names the camera it
                    // serves, so every device that can see it keeps discovery probes off the
                    // body. A TXT re-registration, not a bounce — connections stay up.
                    relayHost?.updateServedCamera(
                        cameraName: session.identity.displayName,
                        servedCameraHost: session.identity.host)
                }
                updateCameraInUseBeacon()
                store.upsertSavedCamera(
                    host: session.identity.host,
                    displayName: session.identity.displayName,
                    transport: transport,
                    onCameraAccessPoint: cameraAccessPointEvidence,
                    // Falls back to the row the operator was adding a setup to: a body that
                    // reports no serial on this path would otherwise save as its own camera.
                    // A body that reports no serial gives an empty string here, not nil.
                    serialNumber: session.identity.serialNumber.isEmpty
                        ? pendingSetupIntent?.anchor.serialNumber
                        : session.identity.serialNumber,
                    path: declaredPathForSave(
                        host: session.identity.host,
                        displayName: session.identity.displayName,
                        setup: setup)
                )
                refreshSavedCameras()
                // AFTER the upsert and the refresh: a first connect creates this setup's record,
                // and what it runs at is read back from the record that now exists rather than
                // from whatever the last setup left behind.
                adoptActiveSetupStreamSettings(host: session.identity.host)
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
                // The pairing produced a working session, so its row has earned its place.
                pairingCreatedRecordHost = nil
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
                guard let self, self.connectionGeneration == generation else { return }
                lastConnectError = error
                let acceptedPairing = acceptedPairingForCurrentAttempt
                if acceptedPairing {
                    savePendingPairingCamera()
                }
                pendingPairingSaveCandidate = nil
                // A recovery attempt behind a preserved monitor keeps the held frame and the
                // recovery affordance. Tearing the surface down and falling back to discovery is
                // exactly what dumped the operator out of live view on a cable knock (#254); the
                // recovery loop owns the retry cadence and the give-up point from here.
                if preservingMonitorSurface, isMonitorPresented {
                    clearCameraSessionState(resetConnection: false, preserveMonitorSurface: true)
                    logConnection(
                        "recovery attempt failed host=\(host) \(error.localizedDescription)")
                    return
                }
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
                if transportKind == .usb,
                    let token = USBHandshakeDiagnostic.from(
                        stage: establishmentDiagnostic.withLock { $0 }),
                    let event = AppDiagnosticEvent(rawValue: token.rawValue)
                {
                    AppDiagnostics.shared.record(event)
                }
                AppDiagnostics.shared.record(
                    connectionFailureDiagnostic(
                        transportKind: transportKind,
                        rejectedInitiator: Self.isRejectedInitiator(error)
                    )
                )
                connection = .disconnected
                connectionPhase = .failed
                connectionProgressShowsFailure = true
                let baseError: String
                if Self.isRejectedInitiator(error) {
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
                // The friendly copy flattens every cause to one line; append the raw error and the
                // establishment trace so a field failure names its exact step. Skip the raw error
                // when the friendly pass had no mapping and echoed it verbatim (no doubled lines).
                let establishmentTrace = establishmentDiagnostic.withLock { $0 }
                var failureParts = [connectionMessage]
                if !baseError.isEmpty, baseError != connectionMessage {
                    failureParts.append(baseError)
                }
                if !establishmentTrace.isEmpty { failureParts.append(establishmentTrace) }
                connectionFailureDetail = failureParts.joined(separator: "\n")
                logConnection("failed host=\(host) \(self.connectionMessage)")
                startDiscoveryLoop(resetResults: false)
            }
        }
    }

    /// Fails an attempt whose current phase stopped making progress, so a first connection either
    /// completes or ends with a truthful error and a Retry — never an open-ended spinner (#264).
    ///
    /// Phases that wait on a person (the iOS join prompt, "Confirm on camera") are deliberately
    /// unbounded; see `CameraConnectionTimeout`. The deadline is absolute rather than a rate
    /// divider, so the 0.5s tick lands the breach within half a second and cannot alias the budget.
    private func startConnectionTimeoutWatchdog(generation: Int, isUSB: Bool) {
        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = Task { [weak self] in
            var watchedPhase = self?.connectionPhase ?? .idle
            var phaseStartedAt = ContinuousClock.now
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled, let self, self.connectionGeneration == generation else {
                    return
                }
                let phase = self.connectionPhase
                if phase != watchedPhase {
                    watchedPhase = phase
                    phaseStartedAt = .now
                    continue
                }
                guard
                    let budget = CameraConnectionTimeout.budgetSeconds(for: phase, isUSB: isUSB),
                    ContinuousClock.now - phaseStartedAt >= .seconds(budget)
                else { continue }
                var message = CameraConnectionTimeout.timeoutMessage(
                    phase: phase, deviceName: self.connectionProgressDeviceName)
                // The forgot-to-switch-networks case: a router/hotspot camera that cannot be
                // found is overwhelmingly a phone on the WRONG network, and a spinner that
                // never says so leaves the operator waiting on a connect that cannot succeed.
                // AP setups are excluded — their remedy is the join prompt, which the connect
                // flow already offers. ponytail: names the situation, not the stored network;
                // stamp the last-connected SSID on the record if this needs to say WHICH one.
                if !isUSB,
                    let record = self.savedCameras.first(where: { $0.host == self.cameraHost }),
                    record.path?.kind == .infrastructure || record.path?.kind == .phoneHotspot
                {
                    message +=
                        " If the camera is on a router or hotspot, make sure this device is "
                        + "on the same network — that is where it was reached last time."
                }
                self.failConnectionAttempt(
                    message: message,
                    diagnostic: isUSB ? .connectionUsbFailed : .connectionPtpFailed,
                    logReason: "timed out in \(phase) after \(Int(budget))s"
                )
                return
            }
        }
    }

    /// Ends the in-flight attempt with exactly the disposal an explicit cancel performs — stale
    /// transport, PTP session, sockets, tasks, queued writes and camera identity released, and the
    /// single-flight latch freed — then surfaces a retryable failure.
    ///
    /// This is the equivalence #264 turns on: a failed first attempt must leave the app in the same
    /// clean state as tapping Cancel, so the identical retry works without one.
    private func failConnectionAttempt(
        message: String,
        diagnostic: AppDiagnosticEvent,
        logReason: String
    ) {
        guard isEstablishingConnection else { return }
        logConnection("attempt failed host=\(cameraHost) — \(logReason)")
        AppDiagnostics.shared.record(diagnostic)
        disconnectCameraSession(resetConnection: false)
        connection = .disconnected
        connectionPhase = .failed
        connectionProgressShowsFailure = true
        connectionMessage = message
        connectionFailureDetail = message
        startDiscoveryLoop(resetResults: false)
    }

    /// Retries from the failed connection card in place. The failed attempt already disposed
    /// everything an explicit cancel would, so this is the same connect the operator would get by
    /// backing out and tapping the camera again — without making them do it.
    func retryConnectionAttempt() {
        guard connectionProgressShowsFailure, !isEstablishingConnection else { return }
        connectToCamera(operatorRequested: true)
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
        return StartupConnectionCopy.friendly(baseError, path: connectionProgressPathKind)
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
        // The setup's Wi-Fi key belongs to the setup, not to the device. Read it BEFORE the
        // record goes, because the SSID is resolved from the record.
        let forgottenAccessPointSSID = accessPointSSIDBeingForgotten(host: host)
        NativeCameraConnectionStore.shared.forgetKnownPairing(host: host)
        refreshSavedCameras()
        clearCameraWiFiCredential(forForgottenSSID: forgottenAccessPointSSID)
        applyStartupDestination()
        connectionMessage =
            "Removed this camera from OpenZCine. You can pair it again anytime."
        startDiscoveryLoop(resetResults: savedCameras.isEmpty)
    }

    func acceptPairing() {
        finishPairing(accepted: true)
    }

    func rejectPairing() {
        finishPairing(accepted: false)
    }

    func disconnect() {
        // A multicam member lent to Live View goes back to its tile; never CloseSession here.
        if multicam.lentMember != nil {
            returnToMulticam()
            return
        }
        // A viewer has no camera session to tear down — it has a socket to a device that does.
        if videoSource == .relay {
            leaveRelay()
            startDiscoveryLoop(resetResults: false)
            return
        }
        setRelayBroadcasting(false)
        // Deliberate exit clears the storm ledger (`SessionDropStormGuard`) with the session.
        recoveryEpisode.resetStorm()
        disconnectCameraSession(resetConnection: true)
        startDiscoveryLoop(resetResults: false)
    }

    // MARK: - Multicam (NIKON-01)

    func beginMulticam() {
        guard !isStartupActionLocked, cameraSession == nil else { return }
        cameras.consent.retire()
        multicam.connect = { [weak self] record in
            guard
                let requireCurrent = self?.nativeConnectAdmission(),
                let establish = self?.sessionEstablishmentOperation(
                    host: record.host, guid: NativeCameraConnectionStore.shared.guid(),
                    requireCurrent: requireCurrent)
            else { throw CancellationError() }
            return try await establish(false, nil)
        }
        multicam.pollInterval = { [weak self] isProgram, base in
            (self?.thermalTier ?? .nominal).multicamPollInterval(isProgram: isProgram, base: base)
        }
        multicam.whiteBalancePresets =
            CameraPicker.whiteBalance.modes.first { $0.title == "Preset" }?.options ?? []
        multicam.begin()
        syncScreenWakePolicy()
    }

    /// Closes every member link. Never stops a recording.
    func endMulticam() {
        if multicam.lentMember != nil { returnToMulticam() }
        multicam.end()
        syncScreenWakePolicy()
    }

    /// One row per saved body; members are omitted, the rest say why they cannot join.
    func multicamPickerRows() -> [MulticamPickerRow] {
        let hotspots = NativeNetworkInterfaceSnapshot.hotspotSubnetBases()
        let availability = { (record: PTPIPSavedCameraRecord) in
            SavedCameraAvailabilityPolicy.resolve(
                camera: record, discoveredCameras: self.discoveredCameras,
                connectedHost: self.connectedIdentity?.host,
                onCameraAccessPoint: self.isOnCameraAccessPointNetwork,
                hotspotSubnetBases: hotspots)
        }
        let members = Set(multicam.members.compactMap(\.device))
        return SavedCameraPathGroups.group(savedCameras).compactMap { group in
            guard
                let active = SavedCameraPathGroups.activePath(
                    in: group, availability: availability)
            else { return nil }
            if let device = NikonMulticamPolicy.device(serialNumber: active.serialNumber),
                members.contains(device)
            {
                return nil
            }
            let reachable: Bool
            if case .offline = availability(active) { reachable = false } else { reachable = true }
            return MulticamPickerRow(
                record: active, refusal: multicam.refusal(for: active, reachable: reachable))
        }
    }

    /// Whether the single-camera monitor is showing a lent multicam member.
    var isMulticamLiveView: Bool { multicam.lentMember != nil && isMonitorPresented }

    /// Opens one member's full Live View on its own open link: the member's stage pump stands
    /// down (the monitor pumps the link now) and the other members keep streaming.
    func openMulticamLiveView(_ id: MonitorEntryID) {
        guard cameraSession == nil, let member = multicam.member(id),
            let link = multicam.lend(id)
        else { return }
        guard let session = link as? NativeCameraSession else {
            multicam.reclaim(link)
            return
        }
        cameraSession = session
        bindMonitorRuntime(session)
        isCameraControlSession = true
        connectedIdentity = session.identity
        activeSessionPath = member.record.path
        startKeepAlive(session: session)
        startEventDraining(session: session)
        startLinkHealthMonitoring()
        cameraState = cameraState.updating(cameraName: member.displayName)
        connection = .connected
        connectionPhase = .connected
        isMonitorPresented = true
        Task {
            // The monitor starts live view as it does on a fresh session.
            await session.stopLiveView()
            guard multicam.lentMember == id, cameraSession === session else { return }
            enterLiveView()
        }
    }

    /// Return to Multicam: the monitor stands down without CloseSession and hands the link (or
    /// the replacement a recovery opened) back to the member's tile.
    func returnToMulticam() {
        guard multicam.lentMember != nil else { return }
        if shell.monitor?.isBorrowed == true {
            shell.close()
            return
        }
        let lent = cameraSession
        let retirement = monitorRuntime?.retirePumps()
        // Stops the monitor's loops, keep-alive and polls; unlike `disconnectCameraSession` it
        // sends no CloseSession, so the member keeps its session.
        clearCameraSessionState(resetConnection: false)
        connection = .disconnected
        connectionPhase = .idle
        Task {
            await retirement?.value
            multicam.reclaim(lent)
        }
    }

    #if DEBUG
        /// Stages the dropped-session recovery affordance for simulator screenshot verification.
        /// No retry loop is started — this only paints the state the loop would publish.
        func forceSessionRecoveryState(_ state: SessionRecoveryState) {
            activePanel = nil
            liveFPS = SessionRecoveryCopy.heldFrameBadge
            sessionRecovery = state
            // A painted state has no retry to wait out: its card shows at once.
            sessionRecoveryCardGraceElapsed = true
        }

        /// Drives the entry point a physical detach reaches once the transport has closed and the
        /// event drain has surfaced the ended channel. Unlike `forceSessionRecoveryState` this
        /// starts the real bounded loop, so a test exercises the shipped path rather than a
        /// painted state.
        func debugSimulateTransportDetach() {
            beginSessionRecovery(host: cameraHost, reason: "transport detached (debug)")
        }

        /// SIMULATED transport facts and clock for the recovery attempts, so a test drives the
        /// shipped loop without a camera: what one attempt's connect does, whether it is still
        /// establishing, whether its control session returned, the picture clocks, and time.
        struct SessionRecoveryPeers {
            var connect: @MainActor () -> Void
            var isEstablishing: @MainActor () -> Bool
            var hasControlSession: @MainActor () -> Bool
            var picture: @MainActor () -> (sourceAt: TimeInterval?, presentedAt: TimeInterval?)
            var now: @MainActor () -> TimeInterval
            var sleep: @MainActor (Duration) async throws -> Void
        }
        @ObservationIgnored var sessionRecoveryPeers: SessionRecoveryPeers? {
            didSet { recoveryEpisode = makeRecoveryEpisode() }
        }

        /// SIMULATED camera access-point peers for the join gate: the iOS join alert's answer,
        /// the camera's readiness probe and the PTP dial, so a test drives the shipped connect
        /// without Wi-Fi or a camera. A dial is recorded, then refused.
        struct CameraNetworkJoinPeers {
            var join: @MainActor (CameraWiFiJoinPolicy.ProactiveJoinTarget) async throws -> Void
            var isAlive: @MainActor (String) async -> Bool
            var dial: @MainActor (String) -> Void
            /// Optional in-memory SDK boundary for native pairing and late-completion tests.
            var establish:
                (
                    @MainActor (
                        String, Data, Bool, NativePairingChallengeHandler?,
                        (@Sendable (String) -> Void)?
                    ) async throws -> NativeCameraSession
                )? = nil
        }
        @ObservationIgnored var cameraNetworkJoinPeers: CameraNetworkJoinPeers?

        /// Connection-lifecycle inspection for the shell's lifecycle tests. Read-only apart from
        /// `debugEnqueueCameraWrite`, which seeds the queued-write path so a test can prove a
        /// reconnect never replays stale camera-setting writes. Keeps the real members private.
        var debugIsEstablishingConnection: Bool { isEstablishingConnection }
        var debugHasCameraSession: Bool { cameraSession != nil }
        /// Adopts an already-established SIMULATED transport session for hosted media tests.
        /// The real session supplies deletion authority; no connection flag bypasses admission.
        func debugAdoptEstablishedMediaSession(_ session: NativeCameraSession?) {
            cameraSession = session
        }
        var debugHoldsReportingCameraPath: Bool { reportingCameraPath != nil }
        var debugConnectionGeneration: Int { connectionGeneration }
        var debugHasSessionRecoveryTask: Bool { recoveryEpisode.isRunning }
        var debugPendingCameraWriteCount: Int { pendingCameraWrites.count }
        /// Services the real property queue at a SIMULATED native safe point.
        func debugServiceNextCameraWrite() async -> Bool {
            guard let cameraSession else { return false }
            return await performNextPendingCameraWrite(session: cameraSession)
        }
        func debugEnqueueCameraWrite(_ property: PTPPropertyCode) {
            enqueueCameraWrite(
                PendingCameraWrite(
                    picker: .iso,
                    value: "debug",
                    write: PTPCameraPropertyWrite(property: property, data: Data([1]))))
        }
    #endif

    // Demo-session entry points (screenshot/marketing harness — see DemoHarness.swift). Debug-only:
    // with these compiled out, `isDemoSession`/`demoUIMode` can never become true in a Release
    // build, which keeps the demo-interaction helpers further down inert without #if in views.
    #if DEBUG
        /// Demo/screenshot affordance: applies one raw property datum to the snapshot so
        /// camera-fed chrome (e.g. the EV meter) captures headlessly.
        func applyDemoProperty(_ property: PTPPropertyCode, data: Data) {
            cameraPropertySnapshot = cameraPropertySnapshot.applying(
                property: property, data: data)
        }

        @ObservationIgnored private var quickDemoDriver: NikonQuickDemoDriver?

        /// Explicit SIMULATED graphical fixture, using the normal declared header projection.
        func seedGraphicalReviewTimecode() {
            guard isDemoSession else { return }
            applyLiveViewHeaderTimecode(
                Timecode(on: true, hour: 1, minute: 23, second: 45, frame: 12))
            prefersMediaDuration = false
        }

        /// SIMULATED descriptor-backed camera for actual shared touch regression tests.
        func seedQuickDemoCamera() {
            guard isDemoSession else { return }
            let modes = [(6048, 3400, 25), (3840, 2160, 25), (1920, 1080, 25)].map {
                width, height, fps in
                let raw = UInt64(width) << 48 | UInt64(height) << 32 | UInt64(fps) << 16
                let size = PTPCameraPropertyDecoders.screenSize(raw)
                return PTPCameraScreenSizeMode(raw: raw, label: "\(width)x\(height) · \(size.fps)p")
            }
            applyBootstrapObservation(.screenModes(modes))
            applyBootstrapObservation(
                .fileTypes(
                    PTPCameraPropertyDecoders.fileTypeModes(
                        fromEnum: [0x0001_0A00, 0x0010_0A00])))
            applyBootstrapObservation(.property(.liveViewSelector, Data([1])))
            applyBootstrapObservation(
                .property(
                    .movieShutterMode,
                    Data([PTPCameraPropertyDecoders.shutterModeCode(.angle)])))
            applyBootstrapObservation(.property(.movieTVLockSetting, Data([0])))
            if let angle = PTPCameraPropertyWrite.request(control: .shutter, label: "180°") {
                applyBootstrapObservation(.property(angle.property, angle.data))
            }
            applyBootstrapObservation(.options(.movieShutterAngle, ["90°", "180°", "270°"]))
            // Manual exposure with manual ISO 800, the value the demo body's ISO readout shows: the
            // common ISO setting is then reported and writable, as on a body in M. Without it the
            // readout had no reported value and nothing to edit, which the shared rule keeps inert.
            applyBootstrapObservation(.property(.exposureProgramMode, Data(ByteCoding.uint16LE(1))))
            applyBootstrapObservation(.property(.movieISOAutoControl, Data([0])))
            applyBootstrapObservation(
                .property(.isoControlSensitivity, Data(ByteCoding.uint32LE(800))))
            applyBootstrapObservation(
                .property(
                    .movieRecordScreenSize,
                    PTPCameraPropertyWrite.screenSize(raw: modes[1].raw).data))
            applyBootstrapObservation(
                .property(
                    .movieFileType,
                    PTPCameraPropertyWrite.fileType(raw: 0x0001_0A00).data))
            let driver = NikonQuickDemoDriver(model: self)
            let session = NikonCameraSession(driver: driver, serialNumber: "SIMULATED-quick")
            driver.session = session
            quickDemoDriver = driver
            shell.control.bind(session)
        }

        func startDemoSession() {
            stopDiscoveryLoop()
            disconnectCameraSession(resetConnection: false)
            isDemoSession = true
            isMonitorPresented = true
            connectedIdentity = nil
            liveFrameImage = nil
            cameraState = .preview
            resetCameraPropertyState()
            // The monitor reads storage from the common session observation, which a body fills
            // from its card readback. Report the demo card (CameraDisplayState.preview) the same
            // way, so the demo header shows its capacity instead of the unknown placeholder.
            lastKnownStorage = cameraState.mediaStatus.map { status in
                let free = UInt64(max(0, status.gigabytesFree)) * 1_000_000_000
                let total = status.percentFree > 0 ? free * 100 / UInt64(status.percentFree) : 0
                return PTPStorageInfo(totalCapacityBytes: total, freeSpaceBytes: free)
            }
            resetLinkHealthMeasurements()
            discoveredCameras = []
            connectionMessage = "Demo UI session. No camera commands are being sent."
            connection = .connected
            refreshLinkHealth()
        }

        /// Seeds a representative camera-owned stereo meter and manual sensitivity for simulator
        /// layout verification. Release builds contain neither this helper nor the demo harness.
        func demoSeedAudioMonitor() {
            liveAudioLevels = MonitorAudioMeterLevels(
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
            } else if !hasCommand, normalized == "p", isDemoSession {
                demoTogglePhotographyMode()
            } else if !hasCommand, isDemoSession, let number = Int(normalized), number >= 1,
                number <= demoFeedImagePaths.count
            {
                demoSelectFeedImage(number)
            }
        }

        /// Toggles cinema ↔ photography chrome for simulator layout checks (`p` in demo).
        func demoTogglePhotographyMode() {
            let toPhoto = cameraPropertySnapshot.captureSelector != .photo
            cameraPropertySnapshot = cameraPropertySnapshot.applying(
                property: .liveViewSelector, data: Data([toPhoto ? 0 : 1]))
            operatorSession.declare(modes: displayModes)
            if toPhoto {
                // Representative stills readouts so the compact photo strip has real labels.
                cameraPropertySnapshot =
                    cameraPropertySnapshot
                    .applying(
                        property: .isoControlSensitivity, data: Data(ByteCoding.uint32LE(6400))
                    )
                    .applying(property: .exposureProgramMode, data: Data(ByteCoding.uint16LE(1)))
                    .applying(property: .stillCaptureMode, data: Data(ByteCoding.uint16LE(0x0001)))
                    .applying(property: .fNumber, data: Data(ByteCoding.uint16LE(280)))
                    .applying(
                        property: .stillShutterSpeed, data: Data(ByteCoding.uint32LE(0x0001_00C8))
                    )
                    .applying(property: .stillFocusMode, data: Data([0]))
                    .applying(property: .flashMode, data: Data(ByteCoding.uint16LE(2)))
                    .applying(
                        property: .exposureMeteringMode, data: Data(ByteCoding.uint16LE(3))
                    )
                    .applying(property: .compressionSetting, data: Data([7]))
                    .applying(
                        property: .exposureRemaining, data: Data(ByteCoding.uint32LE(1234))
                    )
                    .applying(
                        property: .imageSize,
                        data: PTPCameraPropertyDecoders.ptpStringData("6048x4032")
                    )
                    .applying(property: .captureAreaCrop, data: Data([0]))
                    .applying(property: .rawCompressionType, data: Data([4]))
                    .applying(property: .activePicCtrlItem, data: Data(ByteCoding.uint16LE(8)))
                    .applying(property: .userMode, data: Data([19]))
                // The camera-advertised size domain the pill ranks against ("6048x4032" → L)
                // and the Size drum offers — mirrors what the describe path returns on a body.
                cameraControlOptions[.imageSize] = ["6048x4032", "4528x3016", "3024x2016"]
            }
            publishCameraDisplayState()
            connectionMessage =
                toPhoto
                ? "Demo photography mode (press P for cinema)."
                : "Demo cinema mode (press P for photo)."
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
        // Matches Android: fill AF / lens / subject / audio before the feed opens.
        connectionMessage = "Reading camera settings…"
        startLiveView(session: session)
    }

    @ObservationIgnored private var feedIncidentProducer: NikonFeedIncidentProducer?
    private let frameDecoder = FrameDecoder()
    @ObservationIgnored private var frameRendererStorage: LiveFrameRenderer?
    /// Whether the CPU renderer's memo may hold a baked frame — lets the identity/Metal display
    /// path skip the per-frame eviction actor hop and evict once on transition instead.
    @ObservationIgnored private var rendererHoldsBakedFrame = false
    /// The shared assist engine every live picture source's scopes run through (A1-05).
    @ObservationIgnored private let scopeEngine = MonitorAssistEngine(configuration: .nikonMonitor)
    private var cameraSession: NativeCameraSession? {
        didSet {
            if oldValue !== cameraSession { retireMediaProducer() }
            syncReportingCameraPath()
        }
    }
    @ObservationIgnored private var mediaProducer:
        (io: NikonMediaCatalogAdapter, service: NikonMediaService)?

    private func retireMediaProducer() {
        mediaLibrary?.bind(nil)
        mediaLibrary?.close()
        mediaLibraryBytes?.retire()
        mediaProducer?.service.retire()
        mediaProducer = nil
    }
    private func currentMediaService() -> NikonMediaService? {
        guard let native = cameraSession, let common = controlSession, isConnected else {
            return nil
        }
        if let owner = mediaProducer, owner.io.native === native, owner.io.common === common {
            return owner.service
        }
        retireMediaProducer()
        let io = NikonMediaCatalogAdapter(native: native, common: common, namespace: mediaBucketID)
        { [weak self] in
            self?.cameraSession === native && self?.controlSession === common
                && self?.isConnected == true
        }
        let service = NikonMediaService(session: common.id, io: io)
        mediaProducer = (io, service)
        return service
    }
    private func currentMediaServices() -> CameraServices {
        var services = CameraServices()
        if let service = currentMediaService() {
            services.register(service, as: (any CameraMediaService).self)
            services.register(service, as: (any NikonMediaCatalogRecordSource).self)
        }
        return services
    }
    private func closeMediaBrowse() {
        mediaProducer?.service.cancelCatalog()
        mediaLibrary?.close()
    }

    func prepareMediaLibrary(rows: [MediaClip], bucket: String, service: NikonMediaService?) {
        // The gallery's identity is its library (bucket); a camera service change rebinds it,
        // so the screen's scroll, selection and filters survive a reconnect.
        if let owner = mediaLibrary, mediaLibraryBucket == bucket, let codec = mediaLibraryCodec {
            mediaClips = rows
            if codec.service !== service {
                codec.service = service
                owner.bind(service)
            }
            return
        }
        mediaLibrary?.close()
        mediaLibraryBytes?.retire()
        let codec = NikonMediaLibraryCodec(store: mediaClipStore, bucket: bucket, service: service)
        { [weak self] in
            self?.retainsLocalMediaClip($0) == true
        }
        let bytes = NikonMediaLibraryByteStore(store: mediaClipStore, bucket: bucket) {
            [weak self] in
            self?.mediaLibraryBucket == bucket && self?.mediaLibraryCodec === codec
        }
        mediaLibraryCodec = codec
        mediaLibraryBytes = bytes
        mediaLibraryBucket = bucket
        let cache = MonitorMediaCache(
            directory: mediaCacheDirectory, codec: codec,
            eligibility: .minimumFraction(numerator: 1, denominator: 1),
            catalogAddress: mediaClipStore.directory(for: bucket).lastPathComponent + "/index.json",
            preservedMetadata: [], catalogStore: bytes)
        let favorites = NikonMediaLibraryFavorites(
            store: mediaClipStore,
            buckets: Array(Set(rows.map(\.cameraID) + [bucket])))
        let owner = MonitorMediaLibraryModel(
            cache: cache, favorites: favorites, service: service,
            cacheScanning: .background, catalogBase: .freshListing,
            initialCatalog: .init(), initialRecords: (try? rows.map(codec.record)) ?? [])
        owner.visibility = .allRecords
        mediaLibrary = owner
    }

    func captureMediaLibraryAction(_ clips: [MediaClip]) -> NikonMediaLibraryAction? {
        let owner = mediaLibrary
        let bytes = mediaLibraryBytes
        let codec =
            mediaLibraryCodec
            ?? NikonMediaLibraryCodec(
                store: mediaClipStore,
                bucket: clips.first?.cameraID ?? mediaBucketID, service: nil,
                downloaded: { _ in false })
        let root = mediaClipStore.root.absoluteString
        let generation = mediaActionStoreGeneration
        let connection = connectionGeneration
        let session = cameraSession
        return NikonMediaLibraryAction(
            owner: owner, store: mediaClipStore, codec: codec, bytes: bytes,
            clips: clips,
            canonicalCurrent: { [weak self] in
                guard let self else { return false }
                return self.mediaClipStore.root.absoluteString == root
                    && self.mediaActionStoreGeneration == generation
            },
            admitted: { [weak self] in
                guard let self else { return false }
                return self.mediaLibrary === owner && self.mediaLibraryBytes === bytes
                    && self.mediaClipStore.root.absoluteString == root
                    && self.mediaActionStoreGeneration == generation
                    && self.connectionGeneration == connection
                    && self.cameraSession === session
            })
    }

    /// Native callers and deterministic tests use the same delayed result/persistence completion.
    func performCapturedMediaRating(for clip: MediaClip, operation: () async -> Int?) async -> Int?
    {
        await performCapturedMediaRating(
            for: clip, action: captureMediaLibraryAction([clip]), operation: operation)
    }

    private func performCapturedMediaRating(
        for clip: MediaClip, action: NikonMediaLibraryAction?,
        operation: () async -> Int?
    ) async -> Int? {
        guard let stars = await operation() else { return nil }
        if let action {
            guard action.canMutate(clip) else { return stars }
            mediaClipStore.update(cameraID: clip.cameraID, filename: clip.filename) {
                $0.starRating = stars
                $0.isFavorite = stars >= 1
            }
            action.publish()
        } else {
            mirrorRatingIntoIndex(cameraID: clip.cameraID, filename: clip.filename, stars: stars)
        }
        return stars
    }

    /// User-facing label for the live session's physical link ("Wi-Fi" / "USB-C"), or nil when no
    /// camera session is active.
    var activeTransportLabel: String? {
        cameraSession?.transportKind.savedRecordLabel
    }
    private var discoveryLoopTask: Task<Void, Never>?
    private var discoveryLoopGeneration = 0
    /// The serial consumer of the HDMI capture stream. Mutually exclusive with the integration picture pump —
    /// only one picture source drives the monitor at a time.
    private var hdmiConsumerTask: Task<Void, Never>?
    /// Services camera control while the picture comes from somewhere other than the camera's own
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
    /// Bounded-timeout watchdog for the in-flight attempt: fails a phase that stops making
    /// progress instead of letting the operator stare at a spinner (see `CameraConnectionTimeout`).
    @ObservationIgnored private var connectionTimeoutTask: Task<Void, Never>?
    /// Single-flight camera property poll (live view and command mode). Polls must never stack
    /// behind the transaction gate: a slow poll burst would delay the next frame fetch.
    @ObservationIgnored private var propertyPollTask: Task<Void, Never>?
    /// Debounces the body-fired capture sync so a burst's many ObjectAdded events trigger one
    /// instant playback, not one per frame.
    @ObservationIgnored private var lastBodyCaptureSyncAt: Date?
    /// Single-flight drain of queued property writes while live view is down.
    @ObservationIgnored private var pendingWriteDrainTask: Task<Void, Never>?
    @ObservationIgnored private var measuredLiveViewFPS: Double = 0
    @ObservationIgnored private var lastGoodFrameAt: Date?
    @ObservationIgnored private var consecutiveBadLiveFrames = 0
    @ObservationIgnored private var recentKeepaliveFailures = 0
    @ObservationIgnored private var isStreamRecovering = false
    @ObservationIgnored private var signalBarsFilter = LinkSignalBars()
    /// The fire-and-forget `stopLiveView()` started on background, tracked so a quick return to the
    /// foreground awaits it before restarting the stream (otherwise the stop can land after the
    /// restart and shut the resumed feed back down).
    private var backgroundStopTask: Task<Void, Never>?
    private var pairingContinuation: CheckedContinuation<Bool, Never>?
    private var pendingPairingSaveCandidate: PendingPairingSaveCandidate?
    private var acceptedPairingForCurrentAttempt = false

    /// The saved-camera row this pairing brought into existence, until a connection justifies it.
    ///
    /// The record is written the moment the camera drops the connection after accepting the code,
    /// because the reconnect that follows needs a record to find. If the operator gives up before
    /// that reconnect lands, what is left is a camera they never connected to, on a setup that
    /// does not work — cleared on a successful connect, removed on Cancel. Nil whenever the host
    /// already had a setup, so an abandoned re-pair can never delete a working one.
    private var pairingCreatedRecordHost: String?
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
    /// Active post-confirm fast path (see `beginPairedReconnectFastPath`).
    @ObservationIgnored private var pairedReconnectFastPathTask: Task<Void, Never>?
    private(set) var cameraPropertySnapshot = PTPCameraPropertySnapshot() {
        // Everything the wrist knows about the body's MODE comes from here — stills vs cinema,
        // SHOTS, the still image area. Publishing was wired to discrete events only (connect,
        // record, monitor presented, watch reachability), so a change made ON THE CAMERA reached
        // the phone's own chrome and stopped there. `ingestState` coalesces, so a snapshot that
        // changed nothing the watch renders costs one comparison.
        didSet { publishWatchState() }
    }
    /// True while a still release is in flight (optimistic UI lock on the shutter).
    private(set) var isStillCapturing = false
    /// Bumped each time a shutter fired ON THE CAMERA BODY is detected, so the app's shutter
    /// button can pulse in acknowledgement (the app-fired path animates via the press gesture).
    private(set) var bodyShutterPulse = 0
    private var propertyPollIndex = 0
    /// A drifted body clock found at bootstrap, waiting for the first authoritative record state.
    /// Properties the CAMERA announced as changed (`DevicePropChanged`) and that have not been
    /// re-read yet. Drained ahead of the round-robin so a body-side dial/ring/menu edit lands in
    /// one poll tick instead of a full ~20 s cycle.
    @ObservationIgnored private var cameraAnnouncedPropertyChanges = CameraAnnouncedPropertyQueue()
    /// The `LiveViewImageSize` byte last written to the camera, so a thermal/warning step-down only
    /// restarts the stream when the effective size actually changes (start/stop cycling the encoder
    /// is itself a heat source — see `applyThermalStreamStepDownIfNeeded`).
    @ObservationIgnored private var lastAppliedStreamImageSize: UInt8?
    /// The compression byte the running stream was configured with, tracked exactly like the
    /// size above so the reconciler can see a quality-bias change. Without it the bias only
    /// reached the body when a size change happened to force a reconfigure — every settings
    /// change bails out of the immediate restart, because the settings panel hides the feed.
    @ObservationIgnored private var lastAppliedStreamCompression: UInt8?
    /// Adaptive ceiling on `LiveViewImageSize`: congestion lowers it below the operator's
    /// preset, sustained health raises it back. Reset per session.
    /// Wall-clock cadences gating the descriptor/storage refresh burst to slow timers — re-reading
    /// the rarely-changing enumeration descriptors every poll cycle keeps the camera radio busy
    /// for nothing. `nil` forces a refresh on the first cycle after connect.
    @ObservationIgnored private var lastDescriptorRefreshAt: Date?
    @ObservationIgnored private var lastStorageRefreshAt: Date?
    /// Round-robin position for the spread descriptor refresh (one group per pass, not five).
    @ObservationIgnored private var descriptorRefreshCursor = 0
    @ObservationIgnored private var lastRecordingPropertyPollAt: Date?
    /// One-shot per property: first read outcome (bytes or rejection) logged this session, so a
    /// command tile reading "—" on hardware is diagnosable from Console without per-poll spam.
    @ObservationIgnored private var commandTileDiagnosticLogged: Set<PTPPropertyCode> = []
    private static let commandTileDiagnosticProps: Set<PTPPropertyCode> = [
        .movMicrophone, .movRecordMicrophoneLevelValue, .movWindNoiseReduction, .movieAttenuator,
        .gridDisplay,
    ]
    private var lastKnownStorage: PTPStorageInfo?
    /// Last card-slot diagnostic logged, so an unchanged assignment is not logged every refresh.
    private var lastCardSlotDiagnostic: String?
    private var pendingCameraWrites: [PendingCameraWrite] = []

    /// Camera observations, distinct from optimistic picker display values.
    var operatorQuickReportedProperties: PTPCameraPropertySnapshot { reportedPropertySnapshot }

    /// A quick gesture cannot capture another editor's unfinished format or codec choice.
    func operatorQuickHasPendingWrite(for picker: CameraPicker) -> Bool {
        pendingCameraWrites.contains { $0.picker == picker }
    }
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
    /// Optimistic movie ISO auto flag while a `movieISOAutoControl` write is queued or in flight.
    private var pendingISOAuto: Bool?
    /// AF point requested by a feed tap, in the camera's live-view coordinate space. Sent at the
    /// next live-view control safe point via `ChangeAfArea`.
    private var pendingFocusPoint: (x: UInt32, y: UInt32, admission: NikonCommandAdmission?)?
    /// Multi-step focus reset when subject tracking must be released before recentring.
    private var focusResetStep: FocusResetStep?
    /// Readiness polls still owed after a tap's `AfDrive`, spent one per safe point so the drain
    /// never blocks the live-view frame loop it runs inside.
    private var focusAFSettlePolls = 0
    /// A record start/stop requested by the record button, serviced at the next live-view safe
    /// point (so the StartMovieRecInCard / EndMovieRec op doesn't race the live-view loop's reads).
    private var pendingRecordToggle = false
    /// CORE-02 common camera-session seam over this link (ISO, white balance, record). Created
    /// with `cameraSession` and closed with it. Those three commands run through it and only it.
    @ObservationIgnored private var monitorRuntime: NikonMonitorRuntime?
    private var controlSession: NikonCameraSession? { monitorRuntime?.session }
    /// The Nikon integration's one control model of the connected body, else the shared
    /// pre-connection rule over the Nikon static profile.
    var controlCapabilities: ControlCapabilities {
        controlSession?.controlCapabilities(codecColor: codecColorChoices)
            ?? ControlCapabilities(beforeConnection: NikonCameraSession.captureProfile)
    }
    /// Recording as the CAMERA last reported it (live-view header or record events), apart from
    /// the optimistic `isRecording` the button shows. `nil` until the body says.
    @ObservationIgnored private var reportedRecording: Bool?
    /// Property values exactly as read from the camera. `cameraPropertySnapshot` also carries the
    /// pickers' optimistic bytes; the seam reports only these.
    @ObservationIgnored private var reportedPropertySnapshot = PTPCameraPropertySnapshot()
    /// The picture source whose ceiling the scope engine measures; a new one resets the engine.
    @ObservationIgnored private weak var scopeEngineSource: LiveFrameSampleBus.Source?
    @ObservationIgnored private var lastLevelUpdateTime: CFAbsoluteTime = 0
    /// Thermal-shedding-only display gate; NOT a general cap (see `publishLiveFrameDisplay`). A
    /// wall-clock "every N seconds" gate against a ~fixed-period source (the ZR delivers ~30 fps)
    /// only ever lands on an integer division of the source rate — ceil(30/24)=2 makes "1/24 s"
    /// deliver 15 fps, silently halving the feed. Fine as a bounded degraded mode under real
    /// thermal pressure (`ThermalTier`); wrong as an always-on cap. Decode, watchdog, and scope
    /// sampling still run every camera frame.
    /// AF / subject-detection box overlay update cap (~15 Hz).
    /// Virtual-horizon low-pass update cap when the level assist is on (~10 Hz).
    private static let levelAngleMinInterval: CFAbsoluteTime = 1.0 / 10.0

    @ObservationIgnored private let screenWakeOwner = MonitorScreenWakeOwner()
    @ObservationIgnored private var screenWakeSuppressedForBackground = false
    private var didPrepareStartup = false
    @ObservationIgnored private var cameraWiFiJoinTask: Task<Void, Never>?
    private let establishmentDiagnostic = OSAllocatedUnfairLock(initialState: "")

    private struct PendingPairingSaveCandidate {
        let host: String
        let displayName: String
        let transport: String
        /// Identity of the camera this pairing is FOR, when the connect was launched from a saved
        /// one. Nothing here knows a serial of its own — the candidate is built before the
        /// handshake and both save sites run before a session exists — but a serial-less record
        /// is its own card forever (`SavedCameraPathGroups.group`), which is how adding a second
        /// setup to a saved camera produced a second camera. Inheriting is right by construction:
        /// the operator picked the row, declaring this is another way to reach THAT body.
        let serialNumber: String?
    }

    private struct PendingCameraWrite {
        let picker: CameraPicker
        let value: String
        let write: PTPCameraPropertyWrite
        let admission: NikonCommandAdmission?
        init(
            picker: CameraPicker, value: String, write: PTPCameraPropertyWrite,
            admission: NikonCommandAdmission? = nil
        ) {
            self.picker = picker
            self.value = value
            self.write = write
            self.admission = admission
        }
    }

    /// Keeps only the last queued value for each concrete PTP property. Rapid drags or taps can
    /// produce dozens of intermediate values; sending each one keeps the radio and camera busy for
    /// states the operator has already left. Coalescing by property preserves dependent writes such
    /// as white-balance mode followed by Kelvin temperature.
    private func enqueueCameraWrite(_ pending: PendingCameraWrite) {
        dropPendingCameraWrites { $0.write.property == pending.write.property }
        pendingCameraWrites.append(pending)
    }

    /// Removes obsolete Nikon-domain writes. Common ISO/WB operations belong to the runtime.
    private func dropPendingCameraWrites(
        where shouldDrop: (PendingCameraWrite) -> Bool = { _ in true }
    ) {
        pendingCameraWrites.removeAll(where: shouldDrop)
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

    static func heldCaptureMode(_ snapshot: PTPCameraPropertySnapshot, keeping: Bool)
        -> PTPCameraPropertySnapshot
    {
        guard keeping else { return PTPCameraPropertySnapshot() }
        return PTPCameraPropertySnapshot(
            captureSelector: snapshot.captureSelector,
            shotsRemaining: snapshot.cameraShotsRemaining,
            stillsCardShots: snapshot.stillsCardShots)
    }

    /// The readings a property reset leaves standing until a re-read replaces them.
    static func heldPropertySnapshot(
        _ snapshot: PTPCameraPropertySnapshot, keepingCaptureMode: Bool, keepingReadings: Bool
    ) -> PTPCameraPropertySnapshot {
        keepingReadings ? snapshot : heldCaptureMode(snapshot, keeping: keepingCaptureMode)
    }

    /// The display and reported snapshots a property reset leaves standing.
    static func heldPropertySnapshots(
        display: PTPCameraPropertySnapshot, reported: PTPCameraPropertySnapshot,
        keepingCaptureMode: Bool, keepingReadings: Bool
    ) -> (display: PTPCameraPropertySnapshot, reported: PTPCameraPropertySnapshot) {
        let reported = heldPropertySnapshot(
            reported, keepingCaptureMode: keepingCaptureMode, keepingReadings: keepingReadings)
        // The reset drops writes that were queued but never sent, so a kept display falls back to
        // what the camera confirmed instead of a picker's optimistic value.
        guard !keepingReadings else { return (reported, reported) }
        return (heldCaptureMode(display, keeping: keepingCaptureMode), reported)
    }

    /// `keepingCaptureMode` is a restart or same-host recovery: the held body stays in stills or
    /// video (and keeps its shot count) until a re-read replaces them, so its chrome never falls
    /// back to the other mode meanwhile.
    ///
    /// `keepingReadings` is a warm restart that skips the property burst (a Quality Bias change, a
    /// picture-source switch). Nothing re-reads the body then except the slow round-robin, so
    /// clearing the readings left the readouts at "--" and dropped the timecode's frame field
    /// (its precision comes from the reported frame rate) for a whole poll cycle.
    private func resetCameraPropertyState(
        keepingCaptureMode: Bool = false, keepingReadings: Bool = false
    ) {
        (cameraPropertySnapshot, reportedPropertySnapshot) = Self.heldPropertySnapshots(
            display: cameraPropertySnapshot, reported: reportedPropertySnapshot,
            keepingCaptureMode: keepingCaptureMode, keepingReadings: keepingReadings)
        if !keepingReadings { stabilizationFileTypeReadback = nil }
        propertyPollIndex = 0
        cameraAnnouncedPropertyChanges.removeAll()
        lastRecordingPropertyPollAt = nil
        dropPendingCameraWrites()
        pendingShutterMode = nil
        pendingShutterLockState = nil
        pendingBaseISOHigh = nil
        pendingISOAuto = nil
        pendingFocusPoint = nil
        focusResetStep = nil
        focusAFSettlePolls = 0
        // No exit path may leave a focus drive owning the command channel of a dead session.
        cancelManualFocusDrive()
        cameraApertures = []
        advertisedExposureOptions = [:]
        // Still-capture state must never survive a stream (re)start — a stale chained
        // release re-firing after a reconnect loops the whole connection.
        shutterPressLatchedBurst = false
        pendingStillCapture = false
        pendingStillTerminate = false
        pendingStillTerminateQuiet = false
        stillReleaseAwaitingReady = false
        stillReleaseIsOpenShutter = false
        isStillCapturing = false
        chainedBurstFrames = 0
        remoteModeHeldForBurst = false
        cancelStillTimer()
        instantReviewFetchTask?.cancel()
        instantReviewFetchTask = nil
    }

    private func refreshSavedCameras() {
        savedCameras = NativeCameraConnectionStore.shared.savedCameras()
        if savedCameras.isEmpty, startupMode == .savedCameras {
            startupMode = .discovery
        }
    }

    func reloadSavedCameraRecords() {
        let before = savedCameras
        let after = NativeCameraConnectionStore.shared.savedCameras()
        let remainingSSIDs = Set(
            after.filter { $0.pathKind == .cameraAccessPoint }.compactMap {
                CameraWiFiSSID.resolve(for: $0)
            })
        for record in before where record.pathKind == .cameraAccessPoint {
            if let ssid = CameraWiFiSSID.resolve(for: record), !remainingSSIDs.contains(ssid) {
                clearCameraWiFiCredential(forForgottenSSID: ssid)
            }
        }
        savedCameras = after
    }

    var sharedConnection: NikonConnection? {
        guard isConnected, let controlSession, let connectedIdentity else { return nil }
        return NikonConnection(
            session: controlSession, host: connectedIdentity.host, path: activeSessionPath?.kind,
            services: currentMediaServices())
    }

    /// The shared flow wants sightings again (a session ended, the cameras page shows). Never
    /// mid-connect: the funnel owns discovery while it dials a camera.
    func startDiscoveryForSharedFlow() {
        guard !shouldShowFirstPairWizard || firstPairWizardStep == .discoverAndPair else { return }
        // Never before the first render either: the USB browser must not start that early.
        guard didPrepareStartup, !isConnectionProgressPresented, !isEstablishingConnection else {
            return
        }
        startDiscoveryLoop(resetResults: false)
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

    /// The camera LIST never sends a PTP Init: with multiple devices on one network, an idle
    /// device's probe drops the body's live session (single-initiator). Saved rows light from
    /// the kernel-level liveness dial instead. Probes belong to the PAIRING surface only —
    /// a pairing-wait body advertises nothing, so the operator standing one up needs them.
    /// An armed setup watch probes too. The operator tapped a path and was told to put the body
    /// into its pairing wait on that network — which is both the consent a probe needs and the
    /// one state where it is the ONLY thing that works: a waiting body advertises nothing, so a
    /// Bonjour-only pass can never see it. Without this the watch searched forever with the
    /// camera sitting on the network in plain sight.
    private var discoveryProbesCameras: Bool {
        startupMode == .discovery || pendingSetupIntent != nil
    }

    /// The discovery mode of the next pass: `.passive` for the camera list (never the PTP/IP
    /// control port, never a PTP byte; `NikonDiscovery`), `.active` only while pairing or a setup
    /// watch is armed.
    var discoveryMode: DiscoveryMode {
        Self.discoveryMode(probesCameras: discoveryProbesCameras)
    }

    nonisolated static func discoveryMode(probesCameras: Bool) -> DiscoveryMode {
        probesCameras ? .active : .passive
    }

    /// Exercising ICC camera control makes the OS show its "Using Camera Access to Control
    /// Connected Cameras" disclosure on every launch — so USB browsing runs only where a
    /// cable is actually in play: a saved USB-C setup, or the pairing surface.
    var discoveryBrowsesUSB: Bool {
        // Browsing USB starts ImageCaptureCore, whose first start asks for camera control: iOS
        // shows it as the Camera prompt. Only an operator choice on the cable path may raise it
        // (A2-09): the wizard's Cable Link discovery, a saved USB-C setup, or an armed cable
        // watch. That last one matters too: a camera being GIVEN its first USB-C setup has no USB
        // record yet, and "Connect When Plugged In" otherwise waits for a device it never sees.
        (shouldShowFirstPairWizard && discoveryTransportFilter == .usbC)
            || savedCameras.contains(where: \.isUSBTransport)
            || pendingSetupIntent?.kind == .usbC
    }

    /// Pull-to-refresh on the camera list: one immediate, awaited scan — without blanking the
    /// current rows — then the background loop resumes its own cadence. The spinner stays up
    /// exactly as long as the scan actually runs.
    func refreshCameraDiscovery() async {
        guard !isConnected, !isDemoSession else { return }
        stopDiscoveryLoop(keepRelayBrowsing: true)
        let guid = NativeCameraConnectionStore.shared.guid()
        let cameras = await runDiscoveryPass(guid: guid)
        logSetupWatchPass(cameras: cameras)
        applyDiscoveryResults(cameras)
        startDiscoveryLoop(resetResults: false)
    }

    /// Whether this discovery surface should use the isolated infrastructure finder (continuous
    /// Bonjour + patient directed probes + occupancy-first local sweep) instead of the generic
    /// multi-path `discover` pipeline.
    private var usesInfrastructureFinder: Bool {
        if pendingSetupIntent?.kind == .infrastructure { return true }
        if shouldShowFirstPairWizard, firstPairTransportMethod == .wiFiNetwork,
            firstPairWizardStep == .discoverAndPair
        {
            return true
        }
        return false
    }

    /// Hosts worth a directed probe on the **infrastructure / Wi‑Fi** path only.
    ///
    /// A saved Camera AP record often still carries `192.168.1.1` (or another AP-network
    /// address). That is not a target for "both on house Wi‑Fi" search — dialling it only
    /// burns patience on the gateway. Include infrastructure (and dialling) hosts only.
    private var infrastructureDirectedCandidates: [String] {
        var hosts: [String] = []
        for camera in savedCameras {
            switch camera.path?.kind {
            case .infrastructure, .none:
                // Untyped legacy: still a dialable last-known if on this LAN.
                if CameraDiscovery.isDialableHost(camera.host) { hosts.append(camera.host) }
            case .cameraAccessPoint, .phoneHotspot, .usbC, .hdmiCapture:
                break
            }
        }
        if isEstablishingConnection, CameraDiscovery.isDialableHost(cameraHost) {
            hosts.append(cameraHost)
        }
        // Manual entry / last failed dial while an infrastructure watch is armed.
        if pendingSetupIntent?.kind == .infrastructure,
            CameraDiscovery.isDialableHost(cameraHost)
        {
            hosts.append(cameraHost)
        }
        return hosts.filter { CameraDiscovery.isDialableHost($0) }
    }

    /// One discovery pass: infrastructure finder when the Wi‑Fi path is armed, else generic.
    private func runDiscoveryPass(guid: Data) async -> [DiscoveredCamera] {
        if usesInfrastructureFinder {
            let report = await infrastructureCameraFinder.search(
                guid: guid,
                directedCandidates: infrastructureDirectedCandidates,
                excludedHosts: hostsServedByVisibleBroadcasts(),
                onCameraAccessPoint: cameraAccessPointEvidence == true,
                // A known policy denial names the cause at once instead of a silent sweep.
                localNetworkDenied: LocalNetworkAccess.shared.answer == .denied,
                status: { [weak self] message in
                    self?.connectionMessage = StartupConnectionCopy.friendly(message)
                }
            )
            applyInfrastructureSearchReport(report)
            return report.cameras
        }
        lastInfrastructureMiss = nil
        infrastructureSearchEmptyStreak = 0
        let presencePublication = relayNearby.beginSweep()
        defer { relayNearby.retireSweep(presencePublication) }
        return
            (try? await NativeNikonDiscovery.shared.discover(
                discoveryMode,
                guid: guid,
                priorityHosts: discoveryPriorityHosts,
                excludedHosts: { [weak self] in
                    await self?.hostsServedByVisibleBroadcasts() ?? []
                },
                browsesUSB: discoveryBrowsesUSB,
                status: { [weak self] message in
                    await MainActor.run {
                        self?.connectionMessage = StartupConnectionCopy.friendly(message)
                    }
                },
                onPresences: { [weak self] hits in
                    guard !Task.isCancelled else { return }
                    await self?.applyRelayPresences(
                        NativeNikonDiscovery.relayPresences(hits),
                        source: presencePublication)
                }
            )) ?? []
    }

    /// Applies typed infrastructure search outcomes to the connect card and miss streak.
    private func applyInfrastructureSearchReport(_ report: InfrastructureSearchReport) {
        if report.foundCamera {
            lastInfrastructureMiss = nil
            infrastructureSearchEmptyStreak = 0
            return
        }
        lastInfrastructureMiss = report.miss
        infrastructureSearchEmptyStreak += 1
        guard let copy = infrastructureMissCopy else { return }
        if isConnectionProgressPresented, !connectionProgressShowsFailure {
            connectionStageDetail = copy
            connectionMessage = copy
        } else if shouldShowFirstPairWizard {
            connectionMessage = copy
        }
    }

    /// The last empty Wi‑Fi search's typed diagnosis, in operator words — nil until a sweep has
    /// concluded something. The wizard's discovery card reads this directly: `connectionMessage`
    /// carries the same string but renders on the progress screens only, so on the wizard the
    /// diagnosis was computed and then shown nowhere.
    var infrastructureMissCopy: String? {
        guard let miss = lastInfrastructureMiss else { return nil }
        let cameraName: String? = {
            if let title = pendingSetupIntent?.anchor.displayTitle, !title.isEmpty { return title }
            return connectionProgressDeviceName.isEmpty ? nil : connectionProgressDeviceName
        }()
        return InfrastructureDiscovery.operatorCopy(for: miss, cameraName: cameraName)
    }

    /// Whether the manual host entry control should show (Wi‑Fi search stalled with a typed miss).
    var showsManualCameraHostEntry: Bool {
        usesInfrastructureFinder
            && infrastructureSearchEmptyStreak >= 2
            && lastInfrastructureMiss != nil
            && lastInfrastructureMiss != .onCameraAccessPoint
            && lastInfrastructureMiss != .localNetworkDenied
    }

    /// Connect using an address the operator read off the camera's network screen.
    func connectToManualCameraHost(_ rawHost: String) {
        let host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let normalized = PTPIPPairedHosts.normalizedHost(host),
            !DiscoveredCamera.isUSBHostKey(normalized)
        else {
            connectionMessage = "Enter a valid IPv4 address from the camera network screen."
            return
        }
        isManualCameraHostEntryPresented = false
        manualCameraHostDraft = ""
        logConnection("infra-search manual host=\(normalized)")
        let camera = DiscoveredCamera(ip: normalized, name: nil, source: .manual)
        connectToCamera(camera, operatorRequested: true)
    }

    /// Every address a discovery pass should be dialling, and where each came from.
    ///
    /// The probe pass already logs the hosts it TRIED; this says what it should have tried, which
    /// is the only way to see an address going missing between the saved list and the wire. A
    /// field log showed a tapped setup at 192.168.1.246 absent from a trusted list that carried
    /// its three siblings — unanswerable from the trying side alone.
    private var discoveryPriorityHosts: [String] {
        var hosts = savedCameras.map(\.host)
        // An armed watch's anchor is the camera the operator is standing in front of; its address
        // belongs in every pass for as long as the watch lives, whatever the saved list says.
        //
        // EXCEPT when the watch exists to add ANOTHER setup of a kind that can repeat. The anchor
        // is then a sibling — the Wi-Fi setup this camera already has — and its address is on the
        // network the operator has just left. Dialling it is not a shortcut to the new setup, it
        // is a connect to somewhere else that fails and reads as the new setup failing.
        if let intent = pendingSetupIntent, intent.kind != .infrastructure,
            !hosts.contains(intent.anchor.host)
        {
            hosts.append(intent.anchor.host)
        }
        // The address this attempt is actually dialling, for the same reason — and only while one
        // is actually in flight, or a stale `cameraHost` puts a dead address in every pass.
        if isEstablishingConnection, !cameraHost.isEmpty, !hosts.contains(cameraHost) {
            hosts.append(cameraHost)
        }
        // Never queue virtual keys (usb:, ap:) or empty strings as TCP peers.
        return hosts.filter { CameraDiscovery.isDialableHost($0) }
    }

    private func logDiscoveryPriorityHosts() {
        let listing =
            savedCameras
            .map { "\($0.host)/\($0.pathKind?.rawValue ?? "untyped")" }
            .joined(separator: " ")
        logConnection(
            "discovery priority saved=[\(listing)] "
                + "intent=\(pendingSetupIntent?.anchor.host ?? "none") dialling=\(cameraHost)")
    }

    /// One-line verdict per discovery pass while a setup watch is armed — the stuck-"Searching…"
    /// diagnosis line. Read in Console as `setup-watch`.
    ///
    /// Watches scan ACTIVELY on every pass, settled by hardware evidence (2026-08-03): a ZR in
    /// its "pairing computer and camera" wait advertises NOTHING over Bonjour — a probe is the
    /// only thing that finds it — and the probe does not knock it out of pairing (it paired
    /// cleanly right after, twice). The passive-first hedge this replaced burned ~4 wasted
    /// passes before the first active one could fulfill.
    private func logSetupWatchPass(cameras: [DiscoveredCamera]) {
        guard let intent = pendingSetupIntent else { return }
        logDiscoveryPriorityHosts()
        let listing = cameras.map { "\($0.ip)/\($0.displayName)/\($0.source)" }
            .joined(separator: " ")
        logConnection(
            "setup-watch pass kind=\(intent.kind) anchor=\(intent.anchor.displayTitle) "
                + "found=\(cameras.count) [\(listing)]")
    }

    /// A browse blink, missing attribution or a producer recovery window must not unshield
    /// a camera someone nearby serves. Shared value ownership retains the deployed 180 seconds.
    @ObservationIgnored private var servedHostProbeShield = RelayProbeShield(
        policy: RelayProbeShieldPolicy(linger: 180, shieldsSavedHostsForUnnamedBroadcast: true))

    /// Raw and normalized aliases remain Nikon integration facts. Bonjour attribution and
    /// passive unicast presences feed the same shield; an unnamed broadcast shields all saved
    /// camera aliases, while an unnamed presence does not imply that fallback.
    private func hostsServedByVisibleBroadcasts() -> Set<String> {
        let now = Date().timeIntervalSinceReferenceDate
        func aliases(_ host: String?) -> Set<String>? {
            guard let host, !host.isEmpty else { return nil }
            var result: Set<String> = [host]
            if let normalized = PTPIPPairedHosts.normalizedHost(host) { result.insert(normalized) }
            return result
        }
        return servedHostProbeShield.update(
            broadcastHostAliases: discoveredRelayHosts.map { aliases($0.servedCameraHost) },
            presenceHostAliases: Set(relayPresences.values.flatMap { aliases($0.ch) ?? [] }),
            savedHostAliases: Set(savedCameras.flatMap { aliases($0.host) ?? [] }), now: now)
    }

    private func startDiscoveryLoop(resetResults: Bool) {
        guard discoveryLoopTask == nil, !isConnected, !isDemoSession else { return }
        // Cable events refresh the list the moment they happen — the loop's own cadence backs
        // off to 30 s once a camera is found, far too slow for "I just pulled the plug".
        USBCameraDeviceBrowser.shared.onDeviceListChanged = { [weak self] in
            Task { @MainActor in self?.refreshUSBDiscoveryResults() }
        }
        startRelayBrowsing()
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

    /// `keepRelayBrowsing` holds the relay browser open across a momentary loop restart
    /// (pull-to-refresh): the visible broadcasts are what keeps the refresh's own probe pass off
    /// any camera those broadcasts serve — and the rows shouldn't blink out of the list either.
    /// Re-derives the discovery results from the live USB device list, keeping the network
    /// entries as they were — attach and detach both land instantly (detach un-lights the
    /// chip; attach lets an armed Connect-When-Plugged-In watch fulfill without waiting).
    private func refreshUSBDiscoveryResults() {
        guard !isConnected, !isDemoSession, discoveryLoopTask != nil else { return }
        let usb = USBCameraDeviceBrowser.shared.attachedCameras()
        let network = discoveredCameras.filter { $0.source != .usb }
        applyDiscoveryResults(CameraDiscovery.dedupeAndSort(usb + network))
    }

    private func stopDiscoveryLoop(keepRelayBrowsing: Bool = false) {
        discoveryLoopGeneration += 1
        discoveryLoopTask?.cancel()
        discoveryLoopTask = nil
        // Broadcasts are listed beside cameras on the same screen, so they are found and forgotten
        // on the same schedule.
        if !keepRelayBrowsing { stopRelayBrowsing() }
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

            let cameras = await runDiscoveryPass(guid: guid)
            logSetupWatchPass(cameras: cameras)

            guard !Task.isCancelled, discoveryLoopGeneration == generation else { break }
            applyDiscoveryResults(cameras)

            if cameras.isEmpty { emptyStreak += 1 } else { emptyStreak = 0 }
            // The first retry stays responsive, then grow to a 30s cap so a connect screen left
            // open does not keep waking a sleeping camera's Wi-Fi radio. Pull-to-refresh remains
            // an immediate, awaited scan when the operator expects a camera to appear.
            var delay = CameraDiscovery.automaticScanRetryInterval(
                emptyStreak: emptyStreak,
                foundCamera: !cameras.isEmpty)
            // An armed paired-reconnect is actively WAITING for the camera to reboot and
            // return — backing off to half-minute scans there is the "Confirm on camera
            // hangs forever" report. Keep watching closely until it lands or is disarmed.
            if pendingPairedReconnectHost != nil { delay = min(delay, 2) }
            try? await Task.sleep(for: .seconds(delay))
        }
    }

    /// Resolves the camera's access-point SSID at pairing time: prefer the SSID the phone is on (the
    /// camera AP we paired over), else derive it from the camera's PTP name, else a saved record.
    /// The camera-AP SSID to chase after a pairing, or `nil` when this pairing did not happen on
    /// the camera's own network.
    ///
    /// PATH-ISOLATED, and this is the whole point: the SSID is derivable from the camera's NAME
    /// (`ZR_6002199` → `NIKON_ZR_02199`), so the old unconditional derivation armed the AP-rejoin
    /// machinery after a pairing completed over a ROUTER — and the re-apply loops then asked
    /// "join NIKON_ZR_…?" over and over on a path that must never touch the camera AP. A pairing
    /// only earns an AP chase with POSITIVE proof: this attempt applied the AP Wi-Fi config, or
    /// the established session declared the camera-AP path.
    private func cameraAccessPointSSID(host: String, displayName: String?) -> String? {
        // A readable SSID that looks like a camera's own network is PROOF, and it does not matter
        // who put this phone there. This branch used to sit behind the join gate below, so an
        // operator who joined the camera's Wi-Fi by hand resolved to nil — and nil is what the
        // rejoin chase guards on, so it returned at its first line and the confirm-on-camera
        // screen waited for ever with no prompt (field log: `paired-reconnect armed
        // host=192.168.1.1 ssid=unresolvable`, two lines under `connectedSSID=NIKON_ZR_02199`).
        if let ssid = connectedWiFiSSID?.trimmingCharacters(in: .whitespacesAndNewlines),
            CameraWiFiSSID.isNikonZAccessPoint(ssid)
        {
            return ssid
        }
        // Everything past here INFERS an access-point SSID rather than observing one, so it stays
        // behind positive evidence: inferring one on a router or hotspot setup is the path-isolation
        // bug this gate exists for. Live evidence counts alongside our own join — being on the
        // camera's network is the fact that matters, not who arranged it.
        guard
            sessionJoinedCameraAccessPoint || establishedSessionUsedCameraAP
                || liveCameraAccessPointEvidence == true
        else { return nil }
        if let displayName, let derived = CameraWiFiSSID.deriveSSID(fromCameraName: displayName) {
            return derived
        }
        let normalized = PTPIPPairedHosts.normalizedHost(host)
        if let saved = savedCameras.first(where: { $0.host == normalized }) {
            return CameraWiFiSSID.resolve(for: saved)
        }
        return nil
    }

    /// The route a hop leaves from, captured now: the camera's host and name, and whether the
    /// open Media or Settings page stays over the cameras page while the phone is away.
    func hopRoute(rehostActivePanel: Bool = true) -> NikonHopRoute {
        .init(
            host: connectedIdentity?.host ?? cameraHost,
            displayName: connectedIdentity?.displayName, rehostActivePanel: rehostActivePanel)
    }

    /// Leaves the camera's Wi‑Fi so iOS falls back to home Wi‑Fi or cellular, letting the RED LUT
    /// download reach the internet from camera-AP transport. The download screen unblocks itself
    /// reactively when reachability flips; ``endInternetHop()`` (fired when that screen
    /// dismisses) arms the rejoin + reconnect.
    func beginInternetHop() { internetHop.begin(hopRoute()) }

    /// Rejoins the camera after the RED download's hop. No-op when no hop is active.
    func endInternetHop() {
        if let token = internetHop.token { internetHop.end(token) }
    }

    /// The Nikon leave of the shared hop: reads the joined SSID, tears the camera session down
    /// and leaves the AP. Nil when the phone never left.
    private func leaveForInternetHop(
        _ route: NikonHopRoute, current: @escaping @MainActor () -> Bool
    ) async -> NikonHopRoute? {
        let observed = await hopNative.currentSSID()
        guard current(),
            let ssid = observed
                ?? cameraAccessPointSSID(host: route.host, displayName: route.displayName),
            !ssid.isEmpty
        else { return nil }
        var left = route
        left.ssid = ssid
        // Nothing may pull the phone back onto the camera AP mid-download.
        stopDiscoveryLoop()
        // The open Media or Settings page stays, with its view state, over the cameras page
        // (A2-07); support and report links leave nothing behind.
        disconnectCameraSession(
            resetConnection: true, cover: route.rehostActivePanel ? .retain : .dismiss)
        connection = .disconnected
        // The session is gone, so the return is owed even when the hop ended meanwhile.
        guard current() else { return left }
        hopNative.leaveNetwork(ssid, current)
        connectedWiFiSSID = nil
        return left
    }

    /// Rejoins the camera's Wi‑Fi after an internet hop via the FULL join pipeline the scan flow
    /// uses (`NEHotspotConfiguration` apply with transparent retries, subnet confirmation, then
    /// discovery → connect chaining, narrated in the white card). A fire-and-forget re-apply is
    /// not enough: leaving the AP removes the configuration, so the return is a fresh join racing
    /// iOS settling back onto home Wi‑Fi.
    private func rejoinAfterInternetHop(
        _ route: NikonHopRoute, current: @escaping @MainActor () -> Bool
    ) async {
        guard let ssid = route.ssid, current() else { return }
        connectionProgressDeviceName = cameraWiFiJoinDeviceName()
        connectionProgressIsUSB = false
        connectionProgressPathKind = nil
        isConnectionProgressPresented = true
        let previous = cameraWiFiJoinTask
        cameraWiFiJoinTask = nil
        previous?.cancel()
        if let rejoin = hopNative.rejoin {
            await rejoin(route.host, ssid)
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runCameraWiFiJoin(
                target: .specificSSID(ssid), joinStrategy: .hotspotConfigurationOnly,
                reconnectHost: route.host)
        }
        cameraWiFiJoinTask = task
        await task.value
    }

    /// True when the phone is joined to the camera's local-only AP (no internet route).
    /// Address + cached-SSID based; deliberately no `NEHotspotNetwork` call, which logs a
    /// nehelper error line per invocation while the wifi-info capability isn't live.
    var isOnCameraAccessPoint: Bool {
        CameraWiFiJoinPolicy.isOnCameraAccessPoint(
            localAddresses: NativeNetworkInterfaceSnapshot.localIPv4Addresses(),
            connectedSSID: connectedWiFiSSID
        )
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

    /// Re-applies the camera AP config (throttled) while waiting for a just-paired camera to return,
    /// so the phone rejoins the camera network instead of settling on a preferred home network.
    private func attemptPairedReconnectRejoin() {
        guard let ssid = pendingPairedReconnectSSID, !ssid.isEmpty else { return }
        let now = Date()
        if let last = lastPairedRejoinAttemptAt, now.timeIntervalSince(last) < 5 { return }
        lastPairedRejoinAttemptAt = now
        WiFiJoinCoordinator.shared.reapplyCameraNetwork(ssid: ssid)
    }

    /// Post-confirm fast path for the camera-AP case ("Confirm on camera" taking forever).
    ///
    /// After the body-side Confirm the camera reboots its AP. The passive path re-applies the
    /// camera's Wi-Fi only at the END of each discovery pass — and with the phone fallen back to
    /// its home network, a pass can include a blind /24 sweep of the WRONG network, so the rejoin
    /// cadence silently stretched from "every 5 s" to "every sweep". This loop owns the return
    /// directly: re-apply the camera network on a fixed cadence, and the moment the phone is back
    /// on the camera's SSID, dial the known AP host — no discovery in the critical path. The
    /// passive discovery machinery stays untouched underneath as the fallback (and remains the
    /// only mechanism for router-path confirms, where there is no SSID to chase).
    private func beginPairedReconnectFastPath(host: String, ssid: String?) {
        pairedReconnectFastPathTask?.cancel()
        pairedReconnectFastPathTask = nil
        guard let ssid, !ssid.isEmpty else { return }
        pairedReconnectFastPathTask = Task { [weak self] in
            let deadline = ContinuousClock.now + .seconds(90)
            var lastReapply: ContinuousClock.Instant?
            // "Off the camera's SSID" only counts as the camera restarting once we have actually
            // been ON it. Adding a setup to a saved camera starts with iOS already wandered back
            // to a home network, so the very first poll used to read as a restart: the reapply
            // pulled the phone onto the camera's still-running, not-yet-confirmed AP and dialled
            // it, which the body answers by ending the connection.
            var sawCameraNetwork = false
            var sawCameraNetworkDrop = false
            while !Task.isCancelled, ContinuousClock.now < deadline {
                guard let self, !self.isConnected else { return }
                // Both gone = the operator abandoned the flow; the passive path owns any rest.
                if !self.isConnectionProgressPresented, self.pendingPairedReconnectHost == nil {
                    return
                }
                if self.isEstablishingConnection {
                    try? await Task.sleep(for: .milliseconds(250))
                    continue
                }
                // TWO readings, because one of them usually refuses to answer. iOS hands back an
                // SSID only for a network THIS app configured, so on a phone that joined the
                // camera by hand — or that has wandered back to a home network — `currentWiFiSSID`
                // is nil, and the entire restart signal used to be nil with it. That is why this
                // path felt less reliable than every other one: the others ask the camera, and
                // this one asked iOS a question it mostly declines.
                //
                // A mute dial at the access point's own address answers the same question without
                // asking iOS anything, and it is the same evidence the rest of the app runs on.
                // It sends no PTP bytes, so unlike an Init it cannot disturb a body still sitting
                // on its Confirm screen. Off the camera's network that address is somebody's
                // router, which refuses rather than accepts — a refusal is not an answer here.
                let current = await NativeNetworkInterfaceSnapshot.currentWiFiSSID()
                let ssidSaysCameraNetwork =
                    current.map { $0.caseInsensitiveCompare(ssid) == .orderedSame } ?? false
                let hostSaysCameraNetwork =
                    await PTPIPTransport.probePort(
                        host: host,
                        timeoutMilliseconds: InfrastructureDiscovery.blindSweepTimeoutMilliseconds
                    ) == .open
                if ssidSaysCameraNetwork || hostSaysCameraNetwork {
                    sawCameraNetwork = true
                    // Pre-confirm, the phone is often STILL on the camera's old AP — dialing
                    // then grabs the lingering pre-confirm session (what `sawCameraLeave`
                    // exists to prevent). Dial only once the camera has been seen going away:
                    // our own off-network observation, or discovery missing it.
                    guard sawCameraNetworkDrop || self.pairedReconnectSawCameraLeave else {
                        try? await Task.sleep(for: .seconds(1))
                        continue
                    }
                    // Back on the camera's rebooted network: dial the fixed AP host directly.
                    self.cameraHost = host
                    // This loop re-applied the camera's network to get here, so the dial carries
                    // that proof — the record it saves is an access-point setup.
                    self.connectToCamera(viaCameraAccessPointJoin: true)
                    while self.isEstablishingConnection, !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(200))
                    }
                    if self.isConnected { return }
                    // Give the ZR a moment to release its stale session before the next Init.
                    try? await Task.sleep(for: .seconds(2))
                } else {
                    // The phone got kicked off the camera's AP — that IS the restart signal,
                    // but only for a phone that was on it to begin with.
                    if sawCameraNetwork { sawCameraNetworkDrop = true }
                    let now = ContinuousClock.now
                    // The camera is still coming back up for the first seconds after the drop,
                    // and its configuration is still installed on this phone — so give iOS the
                    // chance to re-associate by itself before chasing. An apply that lands early
                    // only costs the operator an "Unable to connect". Hence one interval of
                    // patience first, then a cadence wide enough that an attempt has resolved
                    // before the next begins.
                    if lastReapply == nil { lastReapply = now }
                    if now - lastReapply! >= .seconds(10) {
                        lastReapply = now
                        WiFiJoinCoordinator.shared.reapplyCameraNetwork(ssid: ssid)
                    }
                    try? await Task.sleep(for: .seconds(1))
                }
            }
            // Out of time without a reconnect: hand the AP path back to passive discovery, which
            // is held off below while this loop owns the restart signal. Without this a confirm
            // that lands late would leave the operator on a spinner nothing ever answers.
            // Cancelled means a newer chase already replaced this one in that slot — leave it be.
            if !Task.isCancelled {
                self?.pairedReconnectSawCameraLeave = true
                self?.pairedReconnectFastPathTask = nil
            }
        }
    }

    private func applyDiscoveryResults(_ cameras: [DiscoveredCamera]) {
        discoveredCameras = cameras
        nikonPort.found(cameras)

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
                // A miss only says "not on the network we just swept". On the camera-AP path that
                // network is often the phone's home Wi-Fi, where the camera never was — so it is
                // no evidence the camera restarted, and acting on it dialled a body still waiting
                // for its Confirm. There the fast path owns the signal (it watches the camera's
                // own AP go away) and hands back here if it runs out of time.
                if pendingPairedReconnectSSID == nil {
                    pairedReconnectSawCameraLeave = true
                }
                // The camera dropped its AP to restart with the new pairing profile. Pull the phone
                // back onto the camera network so discovery can see it return (iOS may otherwise
                // settle on a preferred home network and never rejoin on its own) — but only when
                // the fast path is not already chasing it. Two independently throttled re-appliers
                // took turns applying into the same rebooting access point, and every attempt that
                // fails is an "Unable to connect" the operator has to dismiss.
                if pairedReconnectFastPathTask == nil {
                    attemptPairedReconnectRejoin()
                }
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

        // An armed add-setup watch fulfills here: the sheet's tap was the operator's consent,
        // given in advance, for exactly this discovery. (Distinct from the implicit
        // auto-reconnect-on-plug that was removed by request below — this one only ever runs
        // after an explicit arm, once.)
        if let intent = pendingSetupIntent, !isConnected, !isEstablishingConnection {
            // The candidate must sit on the network SHAPE the armed setup asked for — the
            // same per-kind rule as the availability chips. Without it, an armed Router
            // watch was fulfilled instantly by the same body still sitting on the phone's
            // hotspot: it connected over the wrong path, and because that fulfillment fired
            // inside the add-setup sheet's dismissal, the progress cover was silently
            // dropped — the whole connect+pair ran with no visible UI.
            // The join PROOF, not the live-only read the chips use: an AP add-setup watch runs in
            // the moment right after this app applied the access-point configuration, when the
            // SSID is usually still unreadable. Live-only evidence would leave that watch on
            // "Searching…" with the camera in plain sight.
            let onCameraAccessPoint = cameraAccessPointEvidence == true
            let shapeFits: (DiscoveredCamera) -> Bool = { [onCameraAccessPoint] in
                let viaHotspot = CameraStartupPolicy.usesIPhoneHotspot(
                    host: $0.ip,
                    transport: "",
                    hotspotSubnetBases: NativeNetworkInterfaceSnapshot.hotspotSubnetBases())
                switch intent.kind {
                case .usbC, .hdmiCapture:
                    return $0.source == .usb
                case .phoneHotspot:
                    return $0.source != .usb && viaHotspot
                case .infrastructure:
                    return $0.source != .usb && !viaHotspot && !onCameraAccessPoint
                case .cameraAccessPoint:
                    return $0.source != .usb && onCameraAccessPoint
                }
            }
            let strictMatch = cameras.first { discovered in
                shapeFits(discovered)
                    && CameraStartupPolicy.savedCamera(
                        forDiscovered: discovered, in: [intent.anchor]) != nil
            }
            // Generic record names (a bare "Nikon ZR") are blocklisted from name matching, so
            // a watch anchored to one can never fulfill strictly — it sat on "Searching…"
            // forever with the camera in plain sight. The operator's tap consented to THIS
            // camera on THIS network: when exactly one candidate fits the network shape, that
            // is the camera they meant. Two or more stays strict — ambiguity must never
            // auto-connect a wrong body.
            let candidates = cameras.filter(shapeFits)
            let match = strictMatch ?? (candidates.count == 1 ? candidates.first : nil)
            if let match {
                pendingSetupIntent = nil
                logConnection(
                    "setup-watch FULFILLED via \(strictMatch != nil ? "name" : "single-candidate") "
                        + "→ \(match.ip)/\(match.displayName)")
                connectionMessage = "\(intent.anchor.displayTitle) found. Connecting…"
                connectToCamera(match)
                return
            }
            // Keep the CARD honest as the situation moves, not just at arm time. Prefer a typed
            // infrastructure miss (hostsVisibleNoPTP, Local Network, …) already written by the
            // finder — overwriting that with generic "Searching…" erased the diagnosis that
            // makes an empty Wi‑Fi search actionable.
            if intent.kind == .infrastructure, isConnectionProgressPresented,
                !connectionProgressShowsFailure
            {
                // One source for this sentence. The fallbacks used to carry their own prose —
                // longer, and drifting from the typed copy the moment either was edited.
                let wanted = InfrastructureDiscovery.operatorCopy(
                    for: lastInfrastructureMiss
                        ?? (onCameraAccessPoint ? .onCameraAccessPoint : .cameraNotFound),
                    cameraName: connectionProgressDeviceName.isEmpty
                        ? nil : connectionProgressDeviceName)
                if connectionStageDetail != wanted {
                    connectionStageDetail = wanted
                    connectionMessage = wanted
                }
            }
            if !cameras.isEmpty {
                // The diagnosis line for a watch that SEES cameras but fulfills none: name the
                // rejection per candidate (wrong network shape vs blocked name match vs
                // ambiguity between several fitting bodies).
                let verdicts = cameras.map { camera -> String in
                    let fits = shapeFits(camera)
                    let named =
                        CameraStartupPolicy.savedCamera(
                            forDiscovered: camera, in: [intent.anchor]) != nil
                    return "\(camera.ip)/\(camera.displayName) shape=\(fits) name=\(named)"
                }.joined(separator: "; ")
                logConnection(
                    "setup-watch NOT fulfilled: fitting=\(candidates.count) [\(verdicts)]")
            }
        }

        // Plugging in a USB-C camera only LISTS it — connecting is always the operator's tap.
        // (An auto-reconnect-on-plug used to live here; removed by request, it fought the
        // deliberate connect flow now that USB establishment is fast.)

        guard !cameras.isEmpty else {
            if !isConnected {
                connection = .scanning
            }
            if USBCameraDeviceBrowser.shared.isControlAuthorizationDenied {
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
        // Remember whether this row is one we are ABOUT to create, so an abandoned pairing can
        // take it back out again. A host that already had a setup is not ours to remove — the
        // operator has a working record there and a failed re-pair must never cost them it.
        let normalized = PTPIPPairedHosts.normalizedHost(candidate.host)
        let alreadySaved = savedCameras.contains {
            PTPIPPairedHosts.normalizedHost($0.host) == normalized
        }
        pairingCreatedRecordHost = alreadySaved ? nil : candidate.host
        savePairedCamera(
            host: candidate.host,
            displayName: candidate.displayName,
            transport: candidate.transport,
            serialNumber: candidate.serialNumber
        )
    }

    /// Access-point evidence for the record being saved: a configuration applied this attempt is
    /// direct proof; a readable SSID answers either way; nothing readable is no evidence (nil),
    /// which preserves whatever an earlier connection recorded.
    /// Whether the phone is, right now, on a camera's own Wi-Fi — availability chips use
    /// this to stop a same-body discovery over the AP from lighting router/hotspot setups
    /// that have no route from here.
    /// Whether this device is sitting on a camera's own access point RIGHT NOW.
    ///
    /// Deliberately excludes the join latch. `sessionJoinedCameraAccessPoint` records that an
    /// attempt applied an access-point configuration — how it DIALLED, not where the device
    /// ended up — and nothing clears it when that attempt fails, so it outlives the network it
    /// described. Read as a live answer it lit the Camera AP chip green while the phone sat on
    /// the house router with the camera reachable there: the availability guard that keeps an AP
    /// setup dark off its own network never fired, and the name-match fallback then handed the
    /// router's camera to the AP setup. A green AP chip dials the discovered router address
    /// THROUGH the AP setup instead of offering the join, so the false positive also suppresses
    /// the fix.
    ///
    /// An unreadable SSID (the common case — iOS refuses the Wi-Fi information request) means
    /// "unknown", which resolves to not-on-AP. That is the safe direction: a dark AP chip still
    /// connects when tapped, and its connect is the one that offers the join.
    var isOnCameraAccessPointNetwork: Bool { liveCameraAccessPointEvidence == true }

    /// Addresses that belong to a saved camera-AP setup, normalized.
    ///
    /// Reachable ONLY from the camera's own network. Off it the same address is somebody's
    /// router — 192.168.1.1 by convention on both — so a host answering there proves nothing
    /// about where the camera is, and must never satisfy a setup of another kind.
    var savedCameraAccessPointHosts: Set<String> {
        Set(
            savedCameras
                .filter { $0.path?.kind == .cameraAccessPoint }
                .compactMap { PTPIPPairedHosts.normalizedHost($0.host) }
        )
    }

    /// The join proof INCLUDED: what an attempt did counts when declaring the path it took.
    /// The network an infrastructure setup is ON, when this device can read it.
    ///
    /// One camera can be reached from several networks — a studio router, a home router, a
    /// location's Wi-Fi — and each is its own setup. The NAME is what tells them apart. The
    /// address cannot: `describesSameSetup` merges across hosts within a kind on purpose, because
    /// that is how a setup survives the router handing it a different address next week, and
    /// keying on the address would fork one setup on every DHCP lease instead of distinguishing
    /// two networks.
    ///
    /// `nil` when iOS won't tell us (no entitlement, permission refused, or simply not Wi-Fi).
    /// An unnamed network joins the existing unnamed setup rather than starting a new one — the
    /// operator keeps today's single-router behaviour, DHCP absorption included, instead of
    /// collecting a row per lease they cannot tell apart.
    private var infrastructureNetworkName: String? {
        guard let ssid = connectedWiFiSSID?.trimmingCharacters(in: .whitespacesAndNewlines),
            !ssid.isEmpty,
            // The camera's own network is never an infrastructure network, whatever else is true.
            !CameraWiFiSSID.isNikonZAccessPoint(ssid)
        else { return nil }
        return ssid
    }

    private var cameraAccessPointEvidence: Bool? {
        if sessionJoinedCameraAccessPoint { return true }
        return liveCameraAccessPointEvidence
    }

    private var liveCameraAccessPointEvidence: Bool? {
        guard let ssid = connectedWiFiSSID?.trimmingCharacters(in: .whitespacesAndNewlines),
            !ssid.isEmpty
        else { return nil }
        if CameraWiFiSSID.isNikonZAccessPoint(ssid) { return true }
        // A renamed camera AP won't match the factory pattern, but a saved AP setup that
        // recorded this exact SSID is proof all the same.
        if savedCameras.contains(where: { record in
            if case .cameraAccessPoint(let saved?) = record.path { return saved == ssid }
            return false
        }) {
            return true
        }
        return false
    }

    /// The DECLARED path of the session being saved or latched — resolved once, in strict
    /// precedence: structural host shapes, then this attempt's own proof (a join actually
    /// applied; a readable SSID answering either way), then the saved setup's declaration,
    /// then the wizard's, then infrastructure. This is the moment transport intent becomes a
    /// value instead of an artifact for downstream code to re-derive.
    private func declaredPathForSave(
        host: String, displayName: String?, setup: PTPIPSavedCameraRecord? = nil
    ) -> CameraPath {
        let path = resolvedPathForSave(host: host, displayName: displayName, setup: setup)
        // ONE invariant: positive proof we are NOT on the camera's own network demotes an
        // access-point stamp to infrastructure. (Join flags go stale after post-pairing rejoin
        // on house Wi‑Fi.) There is no universal camera-AP IP — SSID/session evidence decides.
        if case .cameraAccessPoint = path, cameraAccessPointEvidence == false {
            return .infrastructure(networkName: infrastructureNetworkName)
        }
        return path
    }

    private func resolvedPathForSave(
        host: String, displayName: String?, setup: PTPIPSavedCameraRecord?
    ) -> CameraPath {
        if host.hasPrefix(DiscoveredCamera.usbHostKeyPrefix) { return .usbC }
        if CameraStartupPolicy.usesIPhoneHotspot(
            host: host,
            transport: "",
            hotspotSubnetBases: NativeNetworkInterfaceSnapshot.hotspotSubnetBases()
        ) {
            return .phoneHotspot
        }
        if sessionJoinedCameraAccessPoint {
            return .cameraAccessPoint(
                ssid: cameraAccessPointSSID(host: host, displayName: displayName))
        }
        // A READABLE SSID answers either way: the camera's own network is an AP session; any
        // other name is positive proof of infrastructure — a saved AP setup reached over the
        // house network is, for THIS session, an infrastructure link and must recover as one.
        switch cameraAccessPointEvidence {
        case true?:
            return .cameraAccessPoint(
                ssid: cameraAccessPointSSID(host: host, displayName: displayName))
        case false?:
            return .infrastructure(networkName: infrastructureNetworkName)
        case nil:
            break
        }
        // Nothing readable (the common hardware case): the saved setup already declares the path
        // — a reconnect must not demote an AP setup to infrastructure just because iOS refused
        // the Wi-Fi information request. The setup the operator TAPPED answers this outright; the
        // host lookup behind it is a guess whenever two of a body's setups share an address, and
        // guessing here mislabels the session for its whole life (recovery dispatches on it).
        if let path = setup?.path { return path }
        if let saved = savedCameras.first(where: {
            $0.host == PTPIPPairedHosts.normalizedHost(host)
        }), let path = saved.path {
            return path
        }
        if shouldShowFirstPairWizard {
            switch firstPairTransportMethod {
            case .cameraAccessPoint:
                return .cameraAccessPoint(
                    ssid: cameraAccessPointSSID(host: host, displayName: displayName))
            case .phoneHotspot: return .phoneHotspot
            case .usbC: return .usbC
            case .hdmiCapture: return .hdmiCapture
            case .wiFiNetwork: return .infrastructure(networkName: infrastructureNetworkName)
            }
        }
        return .infrastructure(networkName: infrastructureNetworkName)
    }

    private func savePairedCamera(
        host: String, displayName: String, transport: String, serialNumber: String? = nil
    ) {
        // Pairing knows the topology better than any later reconnect: the wizard's chosen path is
        // the operator's own declaration, used when the network offers no evidence of its own.
        let onCameraAccessPoint =
            cameraAccessPointEvidence
            ?? (shouldShowFirstPairWizard
                ? firstPairTransportMethod.joinsCameraAccessPoint : nil)
        NativeCameraConnectionStore.shared.upsertSavedCamera(
            host: host,
            displayName: displayName,
            transport: transport,
            onCameraAccessPoint: onCameraAccessPoint,
            serialNumber: serialNumber,
            path: declaredPathForSave(host: host, displayName: displayName)
        )
        refreshSavedCameras()
        markFirstPairWizardCompleted()
        startupMode = .savedCameras
    }

    private func preferredJoinCameraWiFiSavedCamera() -> PTPIPSavedCameraRecord? {
        // Only a DECLARED camera-AP setup can be a join candidate. The old filter (any non-USB
        // record with a resolvable SSID) matched router records too, because the legacy upsert
        // stamped a derived NIKON_… SSID onto every network record it saw.
        savedCameras.first { camera in
            guard camera.path?.kind == .cameraAccessPoint else { return false }
            return CameraWiFiJoinPolicy.resolvedSSID(
                savedCamera: camera,
                discoveredCamera: nil
            ) != nil
        }
    }

    private func prepareWiFiJoinIfNeeded(
        transportKind: CameraTransportKind,
        savedCamera: PTPIPSavedCameraRecord?,
        discoveredCamera: DiscoveredCamera?,
        deviceName: String,
        operatorRequested: Bool
    ) -> (@MainActor () async throws -> Void)? {
        // THE dispatch: only a record DECLARED as a camera-AP setup may proceed toward the join
        // machinery. Router, hotspot and cable setups exit here — for them the code below does
        // not exist, which is the refactor's whole point. (A nil record is a fresh pairing; the
        // wizard gate right after owns that flow.)
        // Every gate below can decline silently, and a silent decline looks exactly like a broken
        // button: the operator taps Camera AP and nothing happens. Each one says which it was.
        if let savedCamera, savedCamera.path?.kind != .cameraAccessPoint {
            logConnection(
                "join skipped: setup path is \(savedCamera.path?.kind.rawValue ?? "none")")
            if let line = ConnectAttemptDiagnostic.line(
                event: "connect.join",
                cameraName: savedCamera.displayName,
                facts: [
                    "join": "skipped-path",
                    "path": savedCamera.path?.kind.rawValue ?? "none",
                ]
            ) {
                AppDiagnostics.shared.recordConnectTrace(line)
            }
            return nil
        }
        // The operator picked a path that never puts this device on the camera's own access point,
        // so joining one is wrong however tempting a saved SSID makes it look.
        if shouldShowFirstPairWizard, !firstPairTransportMethod.joinsCameraAccessPoint {
            logConnection("join skipped: wizard path \(firstPairTransportMethod) never joins an AP")
            return nil
        }
        // RECOVERY of a live monitor session: the dropped session already proved its topology.
        // A router / hotspot / cable session must never answer a drop by reconfiguring Wi-Fi
        // toward the camera's AP — applying that configuration is itself what kicks this phone
        // off the router the camera is about to come back on, and takes every relay watcher
        // down with it. This is deliberately latched session state, not record evidence:
        // records on a device that cannot read SSIDs may never carry evidence at all.
        if isStreamRecovering || sessionRecovery != .idle {
            guard establishedSessionUsedCameraAP else {
                logConnection("join skipped: recovering a session that did not use the camera AP")
                return nil
            }
        }
        guard
            let joinTarget = CameraWiFiJoinPolicy.joinTargetIfNeeded(
                transportKind: transportKind,
                localAddresses: NativeNetworkInterfaceSnapshot.localIPv4Addresses(),
                savedCamera: savedCamera,
                discoveredCamera: discoveredCamera,
                connectedSSID: connectedWiFiSSID
            )
        else {
            // The four ways this returns nil, named so the log distinguishes them: a cable
            // transport, a non-AP setup, this device already being on the camera's AP, and — the
            // quiet one — an SSID that cannot be resolved from the setup at all, which is the
            // difference between "no join needed" and "no join possible".
            logConnection(
                "join skipped: no target — transport=\(transportKind) "
                    + "path=\(savedCamera?.path?.kind.rawValue ?? "none") "
                    + "discovered=\(discoveredCamera == nil ? "nil" : "yes") "
                    + "ssid=\(CameraWiFiJoinPolicy.resolvedSSID(savedCamera: savedCamera, discoveredCamera: discoveredCamera) ?? "unresolvable") "
                    + "connectedSSID=\(connectedWiFiSSID ?? "unreadable")")
            if let line = ConnectAttemptDiagnostic.line(
                event: "connect.join",
                cameraName: savedCamera?.displayName ?? discoveredCamera?.name,
                facts: [
                    "join": "skipped-unresolvable",
                    "ssid": "unresolvable",
                    "path": savedCamera?.path?.kind.rawValue ?? "none",
                ]
            ) {
                AppDiagnostics.shared.recordConnectTrace(line)
            }
            return nil
        }

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
            AppDiagnostics.shared.record(.connectionJoinPrefix)
            if let line = ConnectAttemptDiagnostic.line(
                event: "connect.join",
                cameraName: savedCamera?.displayName ?? discoveredCamera?.name,
                facts: ["join": "prefix", "ssid": "unresolvable"]
            ) {
                AppDiagnostics.shared.recordConnectTrace(line)
            }
        } else {
            logConnection("join skipped: target names neither an SSID nor a prefix")
            return nil
        }
        if operatorRequested {
            forgetDeclinedJoin(ssid: joinTarget.ssid, prefix: joinTarget.ssidPrefix)
        }
        if joinWasDeclined(ssid: joinTarget.ssid, prefix: joinTarget.ssidPrefix) {
            // A "no" to the iOS join alert latches so no automatic connect re-offers the same
            // network. Skipping the join must not mean dialing anyway: the access-point address
            // is not on the phone's network, and the dial fails as "No PTP-IP service answered".
            // A camera that already answers (joined in Settings, SSID unreadable) is still dialed.
            logConnection(
                "join skipped: DECLINED latch for \(joinTarget.ssid ?? joinTarget.ssidPrefix ?? "?")"
            )
            let host = cameraHost.trimmingCharacters(in: .whitespacesAndNewlines)
            let probe = cameraAccessPointProbe()
            return {
                guard await probe(host) else { throw WiFiJoinCoordinator.JoinError.userDenied }
            }
        }
        // hotspotConfigurationOnly keeps the native join alert over our sheet; the ASK
        // picker rarely discovers Nikon soft-APs and would replace the popup visuals.
        let join = cameraNetworkJoinOperation(
            target: proactiveTarget, credentials: credentials,
            joinStrategy: .hotspotConfigurationOnly)
        let reachable = cameraAccessPointReadinessWait()
        return { [weak self] in
            do {
                try await join()
            } catch {
                self?.recordDeclinedJoinIfUserSaidNo(error, ssid: joinTarget.ssid)
                throw error
            }
            await reachable()
        }
    }

    /// Waits for the camera to actually ANSWER after a join, before the session Init goes out.
    ///
    /// The join resolves on association — a new address on the interface — which is not the same
    /// as a usable route. The body's soft access point starts answering about a second after that
    /// address appears, and an Init sent into the gap does not fail fast: it sits in a blackholed
    /// socket until the transaction deadline. That is the "Connecting…" that only Cancel-and-retry
    /// clears, because retrying is what finally dials a settled route.
    ///
    /// Uses the camera list's own readiness probe, which never sends a PTP Init — so waiting here
    /// cannot disturb a body that is still bringing its network up.
    private func cameraAccessPointReadinessWait(timeout: TimeInterval = 12)
        -> @MainActor () async -> Void
    {
        let host = cameraHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let probe = cameraAccessPointProbe()
        return {
            guard !host.isEmpty else { return }
            let deadline = Date().addingTimeInterval(timeout)
            var dials = 0
            while Date() < deadline, !Task.isCancelled {
                dials += 1
                if await probe(host) {
                    logConnection("post-join: \(host) answered after \(dials) dial(s)")
                    return
                }
                try? await Task.sleep(for: .milliseconds(400))
            }
            logConnection("post-join: \(host) silent for \(Int(timeout))s; connecting anyway")
        }
    }

    /// Snapshot the adapter so its asynchronous probe never owns the model.
    private func cameraAccessPointProbe() -> @MainActor (String) async -> Bool {
        #if DEBUG
            if let peers = cameraNetworkJoinPeers { return peers.isAlive }
        #endif
        return { await NativeNikonDiscovery.dialer.isAlive($0) }
    }

    private func transitionToSavedCameraNetworkCheck(message: String) {
        // The one transition on the AP path that said nothing. A field log stopped dead after
        // "auto-accept pairing challenge received" and gave no hint that the flow had handed off
        // to the confirm-and-rejoin wait at all — the next line was a sweep of a different
        // network entirely, minutes later.
        logConnection(
            "paired-reconnect armed host=\(pendingPairedReconnectHost ?? "none") "
                + "ssid=\(pendingPairedReconnectSSID ?? "unresolvable")")
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
        // AP-path confirms chase the camera's rebooted network directly; router-path confirms
        // (no SSID armed) keep discovery as the sole mechanism.
        if let host = pendingPairedReconnectHost {
            beginPairedReconnectFastPath(host: host, ssid: pendingPairedReconnectSSID)
        }
    }

    private func transportLabel(for source: DiscoverySource?, fallback: String?) -> String {
        switch source {
        case .bonjour, .subnetProbe, .liveness:
            return "Wi-Fi"
        case .manual:
            return "Manual IP"
        case .usb:
            return PTPIPSavedCameraRecord.usbTransportLabel
        // A camera reached over Wi-Fi either way; the holder is a fact about right now, not about
        // the transport a saved record should remember.
        case .heldByAnotherDevice:
            return "Wi-Fi"
        case nil:
            return fallback ?? "Wi-Fi"
        }
    }

    /// A short, synchronous check; the returned operation never retains its host across a wait.
    private func nativeConnectAdmission(generation: Int? = nil)
        -> @MainActor @Sendable () throws -> Void
    {
        { [weak self] in
            try Task.checkCancellation()
            guard let self else { throw CancellationError() }
            if let generation, self.connectionGeneration != generation {
                throw CancellationError()
            }
        }
    }

    private func establishStartupSession(
        host: String,
        guid: Data,
        strategy: CameraConnectionStrategy,
        allowsPairingEscalation: Bool = true
    ) -> @MainActor () async throws -> (session: NativeCameraSession, requestedPairing: Bool) {
        connectionStageDetail = ""
        let diagnosticBox = establishmentDiagnostic
        let isUSBHost = host.hasPrefix(DiscoveredCamera.usbHostKeyPrefix)
        let recordEstablishmentDiagnostic: @Sendable (String) -> Void = { [weak self] summary in
            // "stage:" strings are live progress (shown so a stuck connect names its step —
            // that's how the USB hang was pinned down); everything else is the failure trace.
            if summary.hasPrefix("connect.gate ") {
                let line = String(summary.dropFirst("connect.gate ".count))
                AppDiagnostics.shared.recordConnectTrace(line)
                if line.contains("fallback=gen1-name") {
                    AppDiagnostics.shared.record(.connectionGateGen1Fallback)
                } else if line.contains("ops=unknown") {
                    AppDiagnostics.shared.record(.connectionGateUnknownOps)
                }
                return
            }
            if summary.hasPrefix("stage:") {
                let stage = String(summary.dropFirst("stage:".count))
                diagnosticBox.withLock { $0 = summary }
                if isUSBHost,
                    let token = USBHandshakeDiagnostic.from(stage: stage),
                    let event = AppDiagnosticEvent(rawValue: token.rawValue)
                {
                    AppDiagnostics.shared.record(event)
                }
                // Operator-friendly wording; the technical stage ids stay in the failure trace.
                let friendly =
                    switch stage {
                    case "pairing": "Pairing with the camera…"
                    case "app-control switch", "remote-mode fallback":
                        "Taking control of the camera…"
                    case "device info": "Almost connected…"
                    default:
                        stage.hasPrefix("first command") ? "Starting the session…" : "Connecting…"
                    }
                Task { @MainActor in
                    guard let self, self.connectionPhase != .failed else { return }
                    self.connectionStageDetail = friendly
                }
            } else {
                diagnosticBox.withLock { $0 = summary }
            }
        }
        let requireCurrent = nativeConnectAdmission(generation: connectionGeneration)
        let establish = sessionEstablishmentOperation(
            host: host, guid: guid, onEstablishmentDiagnostic: recordEstablishmentDiagnostic,
            requireCurrent: requireCurrent)
        let onPairingChallenge: NativePairingChallengeHandler = { [weak self] challenge in
            await MainActor.run { [weak self] in
                do { try requireCurrent() } catch { return false }
                return self?.autoAcceptPairing(challenge) ?? false
            }
        }
        return { [weak self] in
            try requireCurrent()
            switch strategy {
            case .savedProfile:
                do {
                    let session = try await establish(false, nil)
                    return (session, false)
                } catch {
                    try requireCurrent()
                    // Escalation needs BOTH: an operator-initiated connect (recovery reconnects a
                    // session that was healthy seconds ago - a failure there means wedged or
                    // rebooting, never unpaired, and a pairing barrage against a wedged body only
                    // digs it deeper), and the profile-unavailable signal. The signal includes bare
                    // connection-closed, which a wedged body emits for EVERY attempt - that
                    // combination is what deleted an operator's saved setups mid-outage.
                    guard allowsPairingEscalation, Self.isSavedProfileUnavailable(error) else {
                        throw error
                    }
                    // Deliberately NOT forgetting the saved records up front: success re-saves and
                    // merges them anyway, and a failed escalation must cost the operator nothing.
                    self?.connectionMessage =
                        "Saved camera profile was out of date. Setting up again…"
                    let session = try await establish(true, onPairingChallenge)
                    return (session, true)
                }
            case .firstTimePairing:
                let session = try await establish(true, onPairingChallenge)
                return (session, true)
            case .restoreCameraProfileBeforePairing:
                do {
                    self?.connectionMessage =
                        "Checking whether this camera already knows your phone…"
                    let session = try await establish(
                        CameraStartupPolicy.startsWithPairingHandshake(for: strategy), nil)
                    self?.connectionMessage =
                        "This camera already knows your phone. Restoring the connection…"
                    return (session, false)
                } catch {
                    try requireCurrent()
                    guard Self.isSavedProfileUnavailable(error) else { throw error }
                    self?.connectionMessage =
                        "Setting up your camera for the first time…"
                    let session = try await establish(true, onPairingChallenge)
                    return (session, true)
                }
            }
        }
    }

    /// Establishes a session over the transport implied by the host key: a `usb:<device-id>` key
    /// connects through ImageCaptureCore, anything else runs the Wi-Fi PTP-IP handshake.
    private func sessionEstablishmentOperation(
        host: String,
        guid: Data,
        onEstablishmentDiagnostic: (@Sendable (String) -> Void)? = nil,
        requireCurrent: @escaping @MainActor @Sendable () throws -> Void
    ) -> @MainActor (Bool, NativePairingChallengeHandler?) async throws -> NativeCameraSession {
        let logger = connectionLogger
        #if DEBUG
            let peers = cameraNetworkJoinPeers
        #endif
        return { [weak self] requestPairing, onPairingChallenge in
            try requireCurrent()
            #if DEBUG
                if let peers {
                    if let establish = peers.establish {
                        return try await establish(
                            host, guid, requestPairing, onPairingChallenge,
                            onEstablishmentDiagnostic)
                    }
                    peers.dial(host)
                    throw NativeCameraSessionError.noHost
                }
            #endif
            guard host.hasPrefix(DiscoveredCamera.usbHostKeyPrefix) else {
                do {
                    return try await NativeCameraSession.establish(
                        host: host,
                        guid: guid,
                        requestPairing: requestPairing,
                        onPairingChallenge: onPairingChallenge,
                        onEstablishmentDiagnostic: onEstablishmentDiagnostic,
                        onLiveViewObject: DemoHarness.captureLiveViewObject
                    )
                } catch let error
                    where NativeCameraSession.isBusyEstablishFailure(error) && !requestPairing
                {
                    try requireCurrent()
                    // "Another initiator holds me." The one case this clears by itself is the
                    // handoff: the other device just disconnected and the body is still tearing its
                    // session down. One retry after a settle long enough for any teardown - never
                    // the 1 s hammer, which lands mid-teardown and wedges the body's network stack
                    // (audit M5; two-device handoff brick). A second busy answer means the other
                    // device is genuinely still connected: surface it, with its own copy.
                    logger.info(
                        "Body answered busy; retrying once after a handoff settle")
                    self?.connectionStageDetail =
                        "Camera is in use \u{2014} waiting for it to free up…"
                    try await Task.sleep(for: .seconds(5))
                    try requireCurrent()
                    return try await NativeCameraSession.establish(
                        host: host,
                        guid: guid,
                        requestPairing: requestPairing,
                        onPairingChallenge: onPairingChallenge,
                        onEstablishmentDiagnostic: onEstablishmentDiagnostic,
                        onLiveViewObject: DemoHarness.captureLiveViewObject
                    )
                } catch let error
                    where NativeCameraSession.isRetryableEstablishFailure(
                        error, requestPairing: requestPairing)
                {
                    try requireCurrent()
                    // Right after a camera-AP join the ZR's PTP-IP endpoint can lag the network, or
                    // the previous session slot can still read busy. One silent in-place retry after
                    // a settle beat clears the field-reported one-off connect failures; a second
                    // failure surfaces through the normal path. No Wi-Fi re-join, no pairing -
                    // isRetryableEstablishFailure only passes non-pairing attempts. The sleep throws
                    // on cancellation, so an abandoned attempt never retries.
                    logger.info(
                        "Wi-Fi establish failed once, retrying in place: \(error.localizedDescription, privacy: .private(mask: .hash))"
                    )
                    try await Task.sleep(for: .seconds(1))
                    try requireCurrent()
                    return try await NativeCameraSession.establish(
                        host: host,
                        guid: guid,
                        requestPairing: requestPairing,
                        onPairingChallenge: onPairingChallenge,
                        onEstablishmentDiagnostic: onEstablishmentDiagnostic,
                        onLiveViewObject: DemoHarness.captureLiveViewObject
                    )
                }
            }
            guard let device = USBCameraDeviceBrowser.shared.device(forHostKey: host) else {
                throw NativeCameraSessionError.connectionFailed(
                    "The camera isn't plugged in. Connect it to this device with a USB-C cable, then try again."
                )
            }
            // The long pole over USB is ImageCaptureCore's card scan (pre-warmed at plug-in); show its
            // live progress instead of a dead spinner while the session-open ack waits it out.
            self?.connectionStageDetail = "Reading the camera's card…"
            let scanTicker = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    let percent = device.contentCatalogPercentCompleted
                    if percent > 0 {
                        self?.connectionStageDetail = "Reading the camera's card… \(percent)%"
                    }
                    try? await Task.sleep(for: .milliseconds(700))
                }
            }
            let usbTransport = USBCameraTransport(device: device)
            do {
                try requireCurrent()
                try await usbTransport.open()
                try requireCurrent()
            } catch {
                scanTicker.cancel()
                usbTransport.close()
                AppDiagnostics.shared.record(.usbSessionOpen)
                throw error
            }
            scanTicker.cancel()
            do {
                try requireCurrent()
                return try await NativeCameraSession.establish(
                    transport: usbTransport,
                    host: host,
                    cameraName: device.name,
                    requestPairing: requestPairing,
                    onPairingChallenge: onPairingChallenge,
                    onEstablishmentDiagnostic: onEstablishmentDiagnostic,
                    onLiveViewObject: DemoHarness.captureLiveViewObject
                )
            } catch {
                do { try requireCurrent() } catch {
                    usbTransport.close()
                    throw error
                }
                // An adopted warm session can be a stale corpse (camera slept, ICC housekeeping) that
                // fails its first command with a raw ICC error. Recycle the session once - real close,
                // fresh open, full retry - before surfacing a failure. (establish() already closed the
                // failed transport, which parks the device; the recycle open un-parks it cleanly.)
                self?.connectionStageDetail = "Refreshing the connection…"
                logger.info(
                    "USB establish failed once, recycling session: \(error.localizedDescription, privacy: .private(mask: .hash))"
                )
                let retryTransport = USBCameraTransport(device: device)
                do {
                    try requireCurrent()
                    try await retryTransport.open(recycleFirst: true)
                    try requireCurrent()
                } catch let openError {
                    retryTransport.close()
                    AppDiagnostics.shared.record(.usbSessionOpen)
                    throw openError
                }
                return try await NativeCameraSession.establish(
                    transport: retryTransport,
                    host: host,
                    cameraName: device.name,
                    requestPairing: requestPairing,
                    onPairingChallenge: onPairingChallenge,
                    onEstablishmentDiagnostic: onEstablishmentDiagnostic,
                    onLiveViewObject: DemoHarness.captureLiveViewObject
                )
            }
        }
    }

    private static func isRejectedInitiator(_ error: Error) -> Bool {
        guard let sessionError = error as? NativeCameraSessionError else { return false }
        if case .initFailed(.rejectedInitiator) = sessionError {
            return true
        }
        return false
    }

    private static func isSavedProfileUnavailable(_ error: Error) -> Bool {
        guard let sessionError = error as? NativeCameraSessionError else { return false }
        if case .savedProfileRequired = sessionError {
            return true
        }
        // A hangup DURING a pairing-skipped establishment is the same fact stated rudely: a
        // body given a NEW network profile has never met this initiator on it, and some bodies
        // close the socket right after the app-control switch instead of refusing politely
        // (field signature: "gateOps=known pairing=skipped appMode=0xffff" → connection
        // closed). The recovery is identical — one fresh pairing attempt. A hangup with a
        // genuinely dead network fails that attempt too and surfaces normally, so the
        // fallback costs a mistaken rig nothing but one retry.
        if case .connectionClosed = sessionError {
            return true
        }
        return Self.isRejectedInitiator(error)
    }

    /// Auto-accepts the pairing challenge without prompting. For a single-operator rig the code
    /// always matches, so confirming it by hand adds friction without protection. Marks the
    /// attempt as paired so that when the camera completes its wizard and drops the connection,
    /// the success/catch path saves the camera and reconnects with the new profile.
    private func autoAcceptPairing(_ challenge: PTPIPPairingChallenge) -> Bool {
        acceptedPairingForCurrentAttempt = true
        adoptPairingChallengeName(challenge)
        connectionPhase = .pairing
        connectionMessage =
            challenge.pin.map { "Pairing with code \($0)…" }
            ?? "Pairing with your camera…"
        logConnection("auto-accept pairing challenge received")
        return true
    }

    /// The challenge carries the camera's own name — stamp it onto the pending save so the
    /// record created by the post-confirm path is never "Camera 192.168.1.1".
    private func adoptPairingChallengeName(_ challenge: PTPIPPairingChallenge) {
        guard let name = challenge.cameraName?.trimmingCharacters(in: .whitespacesAndNewlines),
            !name.isEmpty,
            let candidate = pendingPairingSaveCandidate,
            candidate.displayName.isEmpty
        else { return }
        pendingPairingSaveCandidate = PendingPairingSaveCandidate(
            host: candidate.host, displayName: name, transport: candidate.transport,
            serialNumber: candidate.serialNumber)
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

    private func disconnectCameraSession(
        resetConnection: Bool, preserveMonitorSurface: Bool = false,
        cover: ShellModel.CoverRetention = .dismiss
    ) {
        // A lent multicam member returns to its tile instead of closing; a recovery
        // (`preserveMonitorSurface`) still replaces its link, and the tile takes the replacement.
        if multicam.lentMember != nil, !preserveMonitorSurface {
            returnToMulticam()
            return
        }
        let session = cameraSession
        let runtime = monitorRuntime
        if !preserveMonitorSurface, shell.monitor != nil { shell.close(cover) }
        clearCameraSessionState(
            resetConnection: resetConnection, preserveMonitorSurface: preserveMonitorSurface)
        if !preserveMonitorSurface, let runtime {
            sessionTeardownTask = runtime.teardown
            return
        }
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

    // MARK: - Session recovery

    /// The shared recovery episode (OpenCineCameraVocabulary): admission, the drop-storm pause,
    /// the card grace, attempts on the shared backoff, the 180 s budget and the fresh-picture rule.
    /// This model keeps only the Nikon transport behind its port, the held-frame presentation and
    /// the relay heartbeat. A returned PTP control session never ends recovery on its own (A6-02).
    @ObservationIgnored private lazy var recoveryEpisode = makeRecoveryEpisode()
    /// The last live-view frame from the camera and the last picture this monitor published, on
    /// the episode's wall clock. Header-only deliveries count: in Command and on an HDMI source
    /// the header is what the monitor presents from the camera.
    @ObservationIgnored private var recoverySourceFrameAt: TimeInterval?
    @ObservationIgnored private var recoveryPresentedAt: TimeInterval?

    private func makeRecoveryEpisode() -> SessionRecoveryEpisode {
        var timing = SessionRecoveryEpisode.Timing.continuous
        #if DEBUG
            if let peers = sessionRecoveryPeers {
                let origin = ContinuousClock().now
                timing = .init(
                    monotonicNow: { origin.advanced(by: .seconds(peers.now())) },
                    uptime: { peers.now() }, wallNow: { peers.now() },
                    sleep: { try await peers.sleep($0) }, jitter: { 0.5 })
            }
        #endif
        return SessionRecoveryEpisode(
            port: .init(
                observe: { [weak self] in self?.recoveryObservation() ?? .init() },
                cleanup: { [weak self] kind, attempt in
                    self?.cleanUpRecovery(kind, attempt: attempt)
                },
                connect: { [weak self] attempt in
                    guard let self else { return false }
                    self.startRecoveryAttempt(host: attempt.targetID)
                    return true
                },
                holder: { [weak self] attempt, number in
                    guard self?.isDemoSession == false else { return nil }
                    return await NikonTakeOverRecovery.holder(beforeAttempt: number) {
                        await NativeNikonDiscovery.shared.currentHolder(of: attempt.targetID)
                    }
                }),
            attemptDeadline: NikonSessionRecovery.attemptDeadline, timing: timing,
            changed: { [weak self] snapshot, episode in
                self?.publishRecovery(snapshot, fromEpisode: episode != nil)
            })
    }

    /// Recovers an ESTABLISHED session that dropped underneath the operator — a knocked USB cable,
    /// a camera power cycle, a wedged command channel — without leaving live view.
    ///
    /// The monitor stays up on the last decoded frame (badged as held, not live) while the episode
    /// rebuilds the session through the normal `connectToCamera` path: the stale transport, PTP
    /// session, sockets, tasks, queued property writes and camera identity are all disposed (with a
    /// graceful `CloseSession`) before the replacement is built. When the shared budget is spent the
    /// operator chooses: retry, or back to the operator menu.
    ///
    /// Only ever runs against a host this app was already connected to, so a retry can never
    /// blind-probe a camera sitting on its pairing wizard (probing knocks the body out of pairing).
    private func beginSessionRecovery(
        host: String, reason: String, trigger: SessionRecoveryTrigger = .datalinkLost
    ) {
        // Any evidence of a session to recover arms it — a control session that exists or
        // existed, or a presented monitor. Requiring the MONITOR alone (the old guard) silently
        // dropped every death before the first frame, on the ready page, or behind a
        // full-screen panel, while the UI said "connected" forever (the audit's H1/H5).
        guard !isDemoSession,
            isCameraControlSession || cameraSession != nil || isMonitorPresented
        else { return }
        // A paused storm or a spent budget is the operator's decision; the same dead session's
        // other loss reporters (event channel AND stall watchdog fire for one drop) must not
        // restart a run behind it. The episode refuses too; this also covers a painted state.
        if case .pausedAfterRepeatedDrops = sessionRecovery { return }
        if case .waitingForOperator = sessionRecovery { return }
        if case .takenOver = sessionRecovery { return }
        let target = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return }
        recoveryEpisode.begin(targetID: target, trigger: trigger, reason: reason)
    }

    /// One attempt: the normal connect path, which disposes the previous session first.
    private func startRecoveryAttempt(host: String) {
        #if DEBUG
            if let peers = sessionRecoveryPeers {
                peers.connect()
                return
            }
        #endif
        cameraHost = host
        connectToCamera(preservingMonitorSurface: true)
    }

    /// The attempt as the episode sees it: establishing or holding a control session is still
    /// running; neither means the dial gave up. Only the picture clocks can end recovery.
    private func recoveryObservation() -> SessionRecoveryEpisode.Observation {
        var establishing = isEstablishingConnection
        var hasControlSession = cameraSession != nil
        var picture = (sourceAt: recoverySourceFrameAt, presentedAt: recoveryPresentedAt)
        #if DEBUG
            if let peers = sessionRecoveryPeers {
                establishing = peers.isEstablishing()
                hasControlSession = peers.hasControlSession()
                picture = peers.picture()
            }
        #endif
        return .init(
            ownsConnection: true,
            progress: establishing || hasControlSession ? .running : .failed,
            sourceAt: picture.sourceAt, presentedAt: picture.presentedAt)
    }

    private func cleanUpRecovery(
        _ kind: SessionRecoveryEpisode.Cleanup, attempt: SessionRecoveryEpisode.Attempt
    ) {
        switch kind {
        case .initialDrop:
            connection = .reconnecting
            liveFPS = SessionRecoveryCopy.heldFrameBadge
            isStreamRecovering = true
            startRelayRecoveryHeartbeat()
            logConnection(
                "session lost host=\(attempt.targetID) (\(attempt.reason)) → bounded recovery")
        case .stormPause:
            // Reconnects keep succeeding and dying young: an external killer, not a blip.
            // Retrying harder is what churns the body's PTP stack into its battery-pull wedge,
            // so dispose the dead session gracefully and wait for the operator instead.
            logConnection("session lost host=\(attempt.targetID) → storm pause")
            disconnectCameraSession(resetConnection: false, preserveMonitorSurface: true)
        case .failedAttempt, .budgetExhausted:
            // A dial into a vanished network can block a socket past every cancellation, and a
            // control session that never produced a picture is not a monitor. Retire either with
            // a graceful close the next connect awaits.
            guard isEstablishingConnection || cameraSession != nil else { return }
            logConnection(
                "recovery attempt ended without a picture host=\(attempt.targetID), abandoning it")
            disconnectCameraSession(resetConnection: false, preserveMonitorSurface: true)
        }
    }

    private func publishRecovery(_ snapshot: SessionRecoveryEpisode.Snapshot, fromEpisode: Bool) {
        let previous = sessionRecovery
        if previous != snapshot.state { sessionRecovery = snapshot.state }
        if sessionRecoveryCardGraceElapsed != snapshot.cardGraceElapsed {
            sessionRecoveryCardGraceElapsed = snapshot.cardGraceElapsed
        }
        guard fromEpisode, previous != snapshot.state else { return }
        switch snapshot.state {
        case .idle:
            if case .retrying(let attempt, _) = previous, !snapshot.holdsPicture {
                logConnection("recovered host=\(cameraHost) after \(attempt - 1) failed attempt(s)")
            }
        case .waitingForOperator(let attempts):
            logConnection(
                "recovery handed to the operator host=\(cameraHost) after \(attempts) attempt(s)")
        case .pausedAfterRepeatedDrops(let drops):
            logConnection("recovery paused after \(drops) drops host=\(cameraHost)")
        case .takenOver(let holder):
            logConnection(
                "recovery stopped: \(holder ?? "another device") holds host=\(cameraHost)")
        case .retrying:
            break
        }
    }

    /// Keep the watchers alive on the held frame: with no fresh camera frames, every viewer's
    /// stall watchdog would tear down and rejoin in a loop for the whole outage. A 2 s re-send of
    /// the frozen frame stays inside their 8 s stall threshold, so they keep the picture the
    /// broadcaster is holding, same as the broadcaster's own monitor.
    private func startRelayRecoveryHeartbeat() {
        relayRecoveryHeartbeatTask?.cancel()
        relayRecoveryHeartbeatTask = Task { [weak self] in
            var heldBeats = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled else { return }
                guard self.sessionRecovery != .idle else { return }
                // A recovery that gave up (storm pause / spent budget) is the operator's to
                // resolve; re-sending the frozen frame forever would keep every watcher on a
                // healthy-looking feed with no hint the broadcaster stopped trying. One minute
                // of held frames bridges the operator's decision, then the watchers' own stall
                // watchdogs take over honestly.
                switch self.sessionRecovery {
                case .pausedAfterRepeatedDrops, .waitingForOperator, .takenOver:
                    heldBeats += 1
                    if heldBeats > 30 { return }
                default:
                    heldBeats = 0
                }
                if self.isRelayBroadcasting, let held = self.liveFrameImage {
                    self.broadcastRelayFrame(image: held)
                }
            }
        }
    }

    /// Operator action from the recovery affordance: start a fresh bounded recovery run.
    ///
    /// The abandoned attempt has to be cleared, not just unawaited. `connectToCamera` releases the
    /// single-flight latch as part of its own teardown, but only *after* the
    /// `isEstablishingConnection` guard — so a Retry landing while an attempt is still in flight is
    /// swallowed by that guard and starts nothing, which is exactly the hidden-latch failure #264
    /// fixed on the connect path. Recovery attempts deliberately run without the timeout watchdog,
    /// so there is no bound on how long that would last. Clearing here preserves the monitor
    /// surface, so the operator keeps the held frame across the retry.
    func retrySessionRecovery() {
        let host = cameraHost
        cancelSessionRecovery()
        // Operator intent clears the storm ledger: the retry itself is not a drop, and the next
        // pause should take a fresh cluster of drops to earn.
        recoveryEpisode.resetStorm()
        clearCameraSessionState(resetConnection: false, preserveMonitorSurface: true)
        beginSessionRecovery(host: host, reason: "operator retry", trigger: .operatorRetry)
    }

    /// Operator action from the recovery affordance: leave the held frame for the operator menu.
    /// An explicit exit must never be undone by a late reconnect, so this stops retrying first.
    func exitMonitorToOperatorMenu() {
        cancelSessionRecovery()
        disconnect()
    }

    /// Stops any in-flight recovery episode and clears the affordance.
    private func cancelSessionRecovery() {
        recoveryEpisode.cancel()
        relayRecoveryHeartbeatTask?.cancel()
        relayRecoveryHeartbeatTask = nil
        // A painted state (`forceSessionRecoveryState`) never reached the episode.
        sessionRecoveryCardGraceElapsed = false
        sessionRecovery = .idle
    }

    /// Clears all in-memory session and live-view state. Performs no network I/O, so callers that
    /// are about to open a new session can clear synchronously and then await the previous
    /// session's socket teardown separately (preventing overlapping PTP-IP command channels).
    func clearCameraSessionState(
        resetConnection: Bool, preserveMonitorSurface: Bool = false
    ) {
        cameras.consent.retire(source: "native-connect")
        feedIncidentProducer?.end()
        feedIncidentProducer = nil
        gyroCapture.stop(reason: .disconnected)
        // Invalidate any in-flight establishment attempt: it re-checks this generation before
        // publishing a session, so a handshake finishing after this clear can't resurrect state.
        connectionGeneration += 1
        establishmentTask?.cancel()
        establishmentTask = nil
        // Release the single-flight latch with the attempt it belonged to. Cancelling a Task does
        // NOT interrupt a socket read blocked in a non-cancellable syscall, so the abandoned
        // attempt's `defer` can be up to a full socket timeout away — and until it ran, every
        // retry was silently swallowed by the guard in `connectToCamera`. That is the hidden state
        // behind "cancel, then try again, and it connects instantly" (#264).
        isEstablishingConnection = false
        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = nil
        pairingContinuation?.resume(returning: false)
        pairingContinuation = nil
        pendingPairingChallenge = nil
        pendingPairingSaveCandidate = nil
        acceptedPairingForCurrentAttempt = false
        pendingPairedReconnectHost = nil
        pendingPairedReconnectSSID = nil
        lastPairedRejoinAttemptAt = nil
        pairedReconnectSawCameraLeave = false
        monitorRuntime?.stopPreview()
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
        mediaProducer?.service.cancelCatalog()
        mediaLibrary?.close()
        galleryRelistTask?.cancel()
        galleryRelistTask = nil
        cancelThumbnailWork(resumingWaiters: true)
        resetLinkHealthMeasurements()
        cameraSession = nil
        reviewCameraDelete = nil
        // Closing reports unfinished seam operations honestly and never sends a camera command.
        if preserveMonitorSurface {
            monitorRuntime?.recovering()
        } else {
            let retiring = monitorRuntime
            monitorRuntime = nil
            retiring?.session.close(.requested)
        }
        reportedRecording = nil
        connectedIdentity = nil
        // Auto-reconnects keep the monitor shell up with the last frame frozen (RECOV state, same
        // as stall recovery) instead of dismissing and re-presenting the whole surface — on a
        // flapping link that teardown/rebuild churn reads as app-wide lag and instability.
        if !preserveMonitorSurface {
            // Dropping the monitor is always an operator-driven exit (disconnect, cancel, pair a
            // new camera, internet hop). Retries must die with it — a late reconnect resurrecting
            // a session the operator just left is the duplicate-session bug in #253.
            cancelSessionRecovery()
            // The capture path is owned by the monitor, not by the camera session — a control link
            // that drops while the picture is on HDMI degrades to monitor-only rather than going
            // dark (which is why this sits inside the dismissal branch, not beside the session
            // teardown above). Leaving the monitor for real does end it.
            stopHDMICapture()
            videoSource = .cameraLiveView
            // Leaving the monitor ends the session's *kind*, not just its transport — the next one
            // declares itself when it connects.
            isCameraControlSession = false
            // The in-use shield ends with the session's kind, NOT with a recovery gap: a camera
            // mid-recovery is exactly when a foreign probe must stay away.
            updateCameraInUseBeacon()
            liveFrameImage = nil
            // The next body reports its own values; none of this one's survive it (A1-03).
            cameraState = .blank
            isMonitorPresented = false
            activePanel = nil
        }
        isRecording = false
        resetPendingRecordCommand()
        lastAppliedStreamImageSize = nil
        lastAppliedStreamCompression = nil
        lastDescriptorRefreshAt = nil
        lastStorageRefreshAt = nil
        resetCameraPropertyState(keepingCaptureMode: preserveMonitorSurface)
        // Camera-specific option lists and operator locks must not carry into the next session — a
        // different body (or a fresh re-poll of the same one) advertises its own controls. Cleared
        // here at session teardown, NOT in resetCameraPropertyState, which also runs on every
        // live-view restart and must preserve these across a stall recovery.
        cameraScreenModes = []
        cameraFileTypeModes = []
        cameraMovieTones = [:]
        cameraControlOptions = [:]
        cameraDescriptorEvidence = [:]
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

    private func startLiveView(session: NativeCameraSession, skipPropertyBootstrap: Bool = false) {
        let incident = feedIncidentProducer?.beginPreview()
        let retiredDecodeSource = frameDecoder.retireSource()
        Task { await frameDecoder.resetProcessors(source: retiredDecodeSource) }
        if videoSource == .cameraLiveView {
            resetCameraPropertyState(
                keepingCaptureMode: true, keepingReadings: skipPropertyBootstrap)
        }
        var frameRate = FrameRateSampler()
        monitorRuntime?.startPreview(
            bootstrap: { [weak self] in
                guard let self, cameraSession === session else { return }
                if !skipPropertyBootstrap {
                    connectionMessage = "Reading camera settings…"
                    await bootstrapCameraProperties(session: session)
                }
            },
            demand: { [weak self] in
                guard let self else {
                    return NikonPreviewDemand(mode: .covered, size: 0, compression: 0)
                }
                return NikonPreviewDemand(
                    mode: videoSource != .cameraLiveView
                        ? .controlOnly
                        : shouldPauseLiveFeed
                            ? .covered : streamsHeaderOnly ? .headerOnly : .picture,
                    size: effectiveStreamImageSize,
                    compression: preferences.qualityBias.liveViewImageCompression)
            },
            consume: { [weak self] frame, delivery in
                guard let self, cameraSession === session else { return false }
                return await consumeCameraFrame(
                    frame, delivery: delivery, session: session, frameRate: &frameRate,
                    incident: incident)
            },
            safePoint: { [weak self] count, pollEveryCall in
                guard let self, cameraSession === session else { return }
                if shouldPauseLiveFeed { publishWatchState() }
                await runControlSafePoint(
                    session: session, pollEveryCall: pollEveryCall, frameCounter: count)
            },
            applied: { [weak self] demand in
                self?.lastAppliedStreamImageSize = demand.size
                self?.lastAppliedStreamCompression = demand.compression
            },
            resetCadence: { [weak self] in
                frameRate = FrameRateSampler()
                self?.lastLevelUpdateTime = 0
            },
            health: { [weak self] health in
                guard let self, cameraSession === session else { return }
                lastGoodFrameAt = health.lastGoodFrameAt
                consecutiveBadLiveFrames = health.badFrames
                if health.bodyBusy {
                    if liveFPS != "BUSY" {
                        showMonitorNotice(
                            "The camera is busy on the body - the feed resumes automatically.")
                    }
                    liveFPS = "BUSY"
                }
            },
            event: { [weak self] event in
                guard let self, cameraSession === session else { return }
                switch event {
                case .opening:
                    if videoSource == .cameraLiveView { connectionMessage = "Opening live view…" }
                case .restart(let reason, let delay):
                    AppDiagnostics.shared.record(.liveViewStalled)
                    connectionMessage =
                        "Live view stalled (\(reason)). Restarting in \(formattedSeconds(delay))…"
                    liveFPS = "RECOV"
                    isStreamRecovering = true
                    connection = .connected
                case .reconnect(_, _):
                    AppDiagnostics.shared.record(.liveViewFailed)
                    connectionMessage = "Live view didn't start - reconnecting…"
                    liveFPS = "RECOV"
                    isStreamRecovering = true
                    connection = .connected
                case .reconnectReady:
                    cameraHost = session.identity.host
                    connectToCamera(preservingMonitorSurface: true)
                case .recover(let reason):
                    beginSessionRecovery(host: session.identity.host, reason: reason)
                }
            })
    }

    // MARK: - Picture source

    /// Enters a monitor-only session driven by an HDMI capture device, with no camera behind it.
    ///
    /// The wizard's Cable Link → HDMI path lands here: an operator monitoring a camera they cannot
    /// or do not want to control still gets the whole assist stack — LUTs, peaking, false colour,
    /// zebras, scopes, guides, magnification — on a picture that never went through the live-view
    /// JPEG encoder.
    func startHDMIMonitorSession() {
        // A camera is already connected: this is a source change, not a new session. Falling
        // through would tear that session down and silently cost the operator every control they
        // had — the wizard's HDMI card must not be a way to lose a working camera link.
        if cameraSession != nil {
            selectVideoSource(.hdmiCapture)
            return
        }
        stopDiscoveryLoop()
        disconnectCameraSession(resetConnection: false)
        // Nothing may claim a reading from a camera that isn't attached. Without this the display
        // state keeps the `.preview` fixture — a plausible, entirely fictional ISO 800 on a
        // "Nikon ZR" — because applying an empty property snapshot preserves existing values.
        cameraState = .blank
        resetCameraPropertyState()
        resetLinkHealthMeasurements()
        discoveredCameras = []
        connectedIdentity = nil
        liveFrameImage = nil
        isMonitorPresented = true
        connection = .connected
        videoSource = .hdmiCapture
        // Command is a camera-control dashboard: a picture-only source does not offer it.
        operatorSession.declare(modes: displayModes)
        startHDMICapture()
    }

    /// Switches where the monitor's picture comes from, leaving the control session untouched.
    ///
    /// This is the hybrid the feature exists for: exposure, focus mode, record and the media
    /// browser all keep working over PTP while the picture arrives over HDMI at the quality the
    /// camera actually outputs.
    func selectVideoSource(_ kind: VideoSourceKind) {
        guard !interfaceLocked, kind != videoSource else { return }
        videoSource = kind
        logConnection("picture source → \(kind.rawValue)")
        switch kind {
        case .relay:
            // Not reachable through the picker: joining a broadcast is a whole session change, so
            // `joinRelay` owns that transition rather than this switch.
            break
        case .hdmiCapture:
            startHDMICapture()
        case .cameraLiveView:
            stopHDMICapture()
            if let session = cameraSession {
                // Live view stayed running on the body while HDMI held the picture (focus needs
                // it), so end it before the frame loop starts it again: `StartLiveView` against a
                // body that is already streaming does not answer OK, and the loop reads a non-OK
                // start as a failed one and escalates into recovery.
                Task { [weak self] in
                    await session.stopLiveView()
                    guard let self, self.cameraSession === session,
                        self.videoSource == .cameraLiveView
                    else { return }
                    // Skips the property burst: the snapshot is already warm, and re-running it
                    // would freeze the feed for seconds on what should read as an instant change.
                    self.startLiveView(session: session, skipPropertyBootstrap: true)
                }
            }
        }
    }

    /// Brings the capture path up and stands the camera's own stream down.
    private func startHDMICapture() {
        // The two sources must never drive the monitor at once. Ending live view on the body is
        // not just tidiness: sensor readout plus JPEG encode is the dominant camera-heat source,
        // and stopping it hands the whole command channel back to property polling.
        monitorRuntime?.stopPreview()
        if let session = cameraSession {
            // DELIBERATELY not `stopLiveView()`. Focus is live-view-scoped on the body:
            // `ChangeAfArea` moves the *live-view* AF area, and AF/MF drive belong to the same
            // mode. A body whose live view has ended rejects all of them, which presented as the
            // AF box moving on screen — we draw that ourselves — while focus never followed.
            //
            // Cancelling the frame loop above already stops the JPEG transfers and frees the
            // command channel, which is the bulk of the win. Ending live view on the body as well
            // bought back some camera heat and cost every focus control to get it; that is the
            // wrong side of the trade for a monitor whose whole job is judging focus.
            startCameraControlPump(session: session, skipPropertyBootstrap: true)
        }
        // Only a capture-only monitor loses the header. With a session up the pump keeps pulling
        // it, so clearing here would blank the AF box and meters for one tick and nothing more.
        if cameraSession == nil { clearFrameHeaderDerivedState() }
        hdmiFrameRate = FrameRateSampler()
        let source = UVCVideoSource(
            queueLabel: "com.opencapture.openzcine.uvc-capture",
            logSubsystem: "com.opencapture.openzcine",
            onStateChange: { [weak self] state in self?.applyHDMICaptureState(state) })
        // The first frame's claimed colorimetry, appended to the settings readout. One line of
        // evidence that splits "the camera sends its recording gamma over HDMI" (apply the
        // monitoring LUT, or set the camera's HDMI output to SDR) from "the dongle mis-tags the
        // signal" (our side to correct) — without it both read as "the app shifted my colors".
        source.onSignalColorimetry = { [weak self] summary in
            guard let self, case .streaming(let name, let format) = self.hdmiCaptureState
            else { return }
            self.applyHDMICaptureState(
                .streaming(
                    deviceName: name,
                    format: format.map { "\($0) · \(summary)" } ?? summary))
        }
        uvcSource = source
        hdmiCaptureState = .starting
        connectionMessage = UVCVideoSourceState.starting.message
        hdmiConsumerTask?.cancel()
        // One serial consumer, mirroring the camera stream's loop: the source buffers newest-only,
        // so a slow bake drops frames rather than queueing them behind the picture on screen.
        hdmiConsumerTask = Task { [weak self] in
            guard let self else { return }
            // Renders off the main actor, one frame at a time, only for frames this loop takes.
            let renderer = UVCFrameRenderer()
            for await lease in source.frames {
                guard !Task.isCancelled, self.videoSource == .hdmiCapture else {
                    lease.release()
                    break
                }
                // A frame captured before the device went away or changed is stale.
                guard let handoff = await renderer.image(from: lease),
                    source.fence.isCurrent(lease.generation)
                else { continue }
                await self.presentHDMIFrame(
                    handoff.image, source: source, generation: lease.generation)
            }
        }
        Task { await source.start() }
    }

    /// Tears the capture path down. Safe when it was never started.
    private func stopHDMICapture() {
        hdmiConsumerTask?.cancel()
        hdmiConsumerTask = nil
        // The frame loop takes control servicing back when it restarts; two pumps would double
        // every write and poll.
        monitorRuntime?.stopPreview()
        uvcSource?.stop()
        uvcSource = nil
        hdmiCaptureState = .waitingForDevice
    }

    /// Displays one captured frame, and feeds the scope tap and watch relay from it.
    private func presentHDMIFrame(
        _ image: UIImage, source: UVCVideoSource,
        generation: StreamGeneration
    ) async {
        guard videoSource == .hdmiCapture, uvcSource === source,
            source.fence.isCurrent(generation)
        else { return }
        guard let display = await displayReadyLiveFrame(from: image) else { return }
        guard videoSource == .hdmiCapture, uvcSource === source,
            source.fence.isCurrent(generation)
        else { return }
        // One line per size change: the #115 crop hunt. Every SwiftUI link reads
        // aspect-correct statically, so the witness is which size actually arrives here
        // versus what the capture readout claims.
        if image.size != lastLoggedHDMIFrameSize {
            lastLoggedHDMIFrameSize = image.size
            let w = Int(image.size.width * image.scale)
            let h = Int(image.size.height * image.scale)
            logConnection(
                "hdmi frame \(w)x\(h) aspect=\(String(format: "%.3f", Double(w) / Double(max(1, h))))"
            )
        }
        hdmiFrameRate.recordFrame(at: CACurrentMediaTime())
        measuredLiveViewFPS = hdmiFrameRate.displayFPS
        let label = hdmiFrameRate.formatted
        if label != liveFPS { liveFPS = label }
        lastGoodFrameAt = Date()
        consecutiveBadLiveFrames = 0
        // Publish the picture ONLY — deliberately not through `publishLiveFrameDisplay`, which
        // also writes the focus box. On a header-less source the only thing that knows where the
        // AF point is, is our own `ChangeAfArea`; passing nil here wiped the box about one frame
        // after the tap drew it, which reads exactly like tap-to-focus doing nothing at all.
        publishNativeFrame(display, clean: image, owner: .capture(source, generation))
        sampleScopesIfDue(clean: image) { [weak self, weak source] in
            guard let self, let source else { return false }
            return self.videoSource == .hdmiCapture && self.uvcSource === source
                && source.fence.isCurrent(generation)
        }
        // The CPU path returns a distinct display-baked image; the Metal path returns the clean
        // frame because its bake stays GPU-side, so the relay grades its own thumbnail instead.
        watchRelay.ingestFrame(
            image: display,
            applying: display === image ? liveImageEffects : nil,
            timecode: liveTimecode,
            isRecording: isRecording)
        broadcastRelayFrame(image: image)
        if !isMonitorPresented { isMonitorPresented = true }
        if isStreamRecovering { isStreamRecovering = false }
    }

    func applyHDMICaptureState(_ state: UVCVideoSourceState) {
        hdmiCaptureState = state
        guard videoSource == .hdmiCapture else { return }
        connectionMessage = state.message
        // The connect screens read the progress; a capture that stops while the monitor is up
        // says so on the monitor (A1-02).
        if !state.isStreaming { showMonitorNotice(state.message) }
        // Nothing is arriving, so the feed must not keep the last captured frame on screen
        // pretending to be live.
        if !state.isStreaming {
            liveFrameImage = nil
            liveFPS = "—"
        }
    }

    /// Services camera control when the camera's own frame loop isn't running.
    ///
    /// The frame loop's per-frame safe point (`runControlSafePoint`) is the ONLY place queued
    /// property writes, AF-point taps, record start/stop, still release, device-event polls and
    /// the property round-robin are serviced. `drainPendingWritesIfIdle` does not cover the gap:
    /// it refuses while the monitor is up, precisely because the frame loop is normally there.
    ///
    /// So this runs the same safe point on the same cadence. See
    /// `MonitorDataAvailability.requiresControlPump` for when it has to exist.
    private func startCameraControlPump(
        session: NativeCameraSession, skipPropertyBootstrap: Bool
    ) {
        startLiveView(session: session, skipPropertyBootstrap: skipPropertyBootstrap)
    }

    /// Clears everything that only the camera's live-view frame header can supply.
    ///
    /// Leaving the last values up would pin a stale AF box over a live picture and freeze the
    /// audio meter mid-reading — both read as working instruments showing wrong numbers, which is
    /// worse than showing nothing. The level angles fall back to the phone's own CoreMotion
    /// attitude once the camera stops reporting, so the horizon overlay survives the switch.
    private func clearFrameHeaderDerivedState() {
        liveViewFocus = nil
        observedLiveAudioLevels = nil
        liveTimecode = Timecode(on: false, hour: 0, minute: 0, second: 0, frame: 0)
        cameraReportsTimecode = false
        cameraLevelRoll = nil
        cameraLevelPitch = nil
        liveFeedRotation = .landscape
    }

    /// Keeps an idle command channel warm: a quiet TCP session is exactly what a Wi-Fi/hotspot NAT
    /// times out, surfacing as a drop on the next operation. While the feed isn't pulling frames,
    /// ping every 10s with a side-effect-free GetDeviceInfo (tuned TCP keepalive backs this up at
    /// the socket layer). Bound to the session: a stale session stops it.
    private func startKeepAlive(session: NativeCameraSession) {
        monitorRuntime?.startKeepAlive(
            isBusy: { [weak self] in
                guard let self else { return true }
                return isMonitorPresented && !shouldPauseLiveFeed
            },
            failures: { [weak self] in self?.recentKeepaliveFailures = $0 },
            recover: { [weak self] in
                guard let self, cameraSession === session else { return }
                beginSessionRecovery(host: session.identity.host, reason: "keepalive failed ×3")
            })
    }

    private func startLinkHealthMonitoring() {
        linkHealthUpdateTask?.cancel()
        let incident = feedIncidentProducer
        linkHealthUpdateTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.refreshLinkHealth()
                incident?.publish(
                    lifecycle: FeedIncidentLifecycle(
                        foreground: !self.screenWakeSuppressedForBackground,
                        settingsCovered: self.shouldPauseLiveFeed || self.streamsHeaderOnly
                            || self.videoSource != .cameraLiveView,
                        playbackActive: self.isMediaPlaybackActive,
                        connected: self.cameraSession != nil,
                        thermalState: String(ProcessInfo.processInfo.thermalState.rawValue),
                        lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
                        sceneActive: UIApplication.shared.applicationState == .active,
                        assistState: "unknown"))
                try? await Task.sleep(
                    for: (self.isMonitorPresented && self.measuredLiveViewFPS > 0)
                        ? .seconds(1) : .seconds(3))
            }
        }
    }

    /// The root seeds its initial phase independently of the shell's deduplicated session callback.
    func syncScreenWakePolicy(sceneActive: Bool) {
        screenWakeSuppressedForBackground = !sceneActive
        syncScreenWakePolicy()
    }

    func syncScreenWakePolicy() {
        screenWakeOwner.update(
            enabled: preferences.keepScreenAwake,
            sceneActive: !screenWakeSuppressedForBackground)
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

    /// Whether the live feed is currently not being shown to anyone — a full-screen panel cover.
    /// While true the streaming loop stops pulling frames AND tells the camera to `EndLiveView`,
    /// so the sensor stops encoding for a feed nobody sees (the biggest avoidable camera-heat
    /// source). It resumes on return.
    ///
    /// Command mode (DISP 3) is deliberately **not** here: its hero readout is the timecode, and
    /// timecode rides the live-view frame header only — there is no PTP timecode property — so
    /// ending live view froze it (#271). Command uses `streamsHeaderOnly` instead.
    private var shouldPauseLiveFeed: Bool {
        activePanelHidesLiveFeed && !gyroCapture.calibrationInProgress
    }

    /// Command mode (DISP 3): the dashboard hides the image but shows live timecode and record
    /// state, both of which only exist in the live-view frame header. The stream therefore stays
    /// up at the *smallest* frame the body will send and is pulled on a slow cadence, with decode,
    /// display, the watch relay and scope sampling all skipped.
    private var streamsHeaderOnly: Bool {
        displayMode == .command && !activePanelHidesLiveFeed
    }

    /// The `LiveViewImageSize` byte to request right now: the operator's preset, capped smaller when
    /// the phone is thermally stressed, the camera reports an overheat warning, or a take is in
    /// progress. A smaller preview is less sensor-readout/encode work for the body to do while
    /// things are hot. Never enlarges beyond the operator's chosen preset.
    private var effectiveStreamImageSize: UInt8 {
        // Command shows no image at all, and on HDMI the picture comes from the capture device —
        // either way the live-view stream is only a carrier for its header, so ask for the
        // smallest frame the body offers.
        if streamsHeaderOnly || videoSource != .cameraLiveView {
            return LiveViewStreamPreset.fast.liveViewImageSize
        }
        return preferences.streamPreset.liveViewImageSize
    }

    /// Restarts live view when what the stream was configured with has moved since — the phone
    /// crossed a thermal tier, or the operator changed a quality control. No-op when nothing moved
    /// or the feed isn't up, so a stable state never thrashes the encoder.
    ///
    /// COMPRESSION IS RECONCILED TOO, not just size. Both quality controls restart the feed when
    /// they change, but that restart bails whenever the feed is hidden — which is always, because
    /// the settings panel that carries the controls is what hides it. Size then healed itself here
    /// on the way out while compression had no reconciler, so a Quality Bias change did nothing
    /// until a Stream Preset change happened to force a reconfigure and re-send both bytes.
    private func applyThermalStreamStepDownIfNeeded() {
        guard cameraSession != nil, isMonitorPresented, !shouldPauseLiveFeed else { return }
        guard let appliedSize = lastAppliedStreamImageSize else { return }
        if effectiveStreamImageSize != appliedSize
            || preferences.qualityBias.liveViewImageCompression != lastAppliedStreamCompression
        {
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
        // Measured throughput rides with the score because it answers what the score cannot: a
        // link can hold a healthy round trip and still be too narrow to carry the operator's
        // preset. That is the everyday 2.4 GHz picture, and without a rate on screen the only
        // symptom is "it feels slow" with no way to tell whether a smaller preset would help.
        // USB has no radio to be narrow, so it keeps the plain caption.
        if cameraSession?.transportKind != .usb,
            let rate = cameraSession?.linkThroughput.formatted
        {
            linkHealthDetail = "\(snapshot.detailCaption) · \(rate)"
        } else {
            linkHealthDetail = snapshot.detailCaption
        }
        // USB-C: frame timing isn't radio quality — show full bars whenever the link is alive.
        let bars =
            cameraSession?.transportKind == .usb
            ? (linkHealth > 0 ? 4 : 0)
            : signalBarsFilter.update(score: linkHealth)
        if bars != liveSignalBars { liveSignalBars = bars }
        // THE ladder applier: this tick is the only steady-state caller, and without it a
        // step-down waited on the property round-robin's warningStatus visit — 10+ minutes on
        // exactly the congested link that triggered it, with the fetch deadline killing the
        // session first. (The audit's H3.)
        applyThermalStreamStepDownIfNeeded()
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
        let incident = feedIncidentProducer
        monitorRuntime?.startEventDrain(
            receive: { [weak self] event in
                guard let self, cameraSession === session else { return }
                noteStillReviewEvent(event)
                if event.eventCode == .captureComplete || event.eventCode == .objectAdded {
                    handleBodyFiredCapture(session: session)
                } else if event.eventCode == .movieRecordInterrupted {
                    gyroCapture.stop(reason: .interrupted)
                    applyCameraRecordState(isRecording: false, force: true)
                    let error =
                        event.recordingInterruptionErrorCode.map { String(format: "0x%08X", $0) }
                        ?? "unknown"
                    showMonitorNotice("Recording was interrupted by the camera (error \(error)).")
                    await refreshWarningStatus(session: session)
                } else if let recordState = event.inferredRecordState {
                    applyCameraRecordState(isRecording: recordState == .recording)
                } else {
                    noteCameraAnnouncedPropertyChange(event)
                }
            },
            unexpectedEnd: { [weak self] in
                guard let self, cameraSession === session else { return }
                AppDiagnostics.shared.record(.connectionEventChannelEnded)
                incident?.unexpectedDisconnect()
                recoverFromEndedEventChannel(session: session)
            })
    }

    /// The event channel ending for any reason other than an idle timeout means the link is gone —
    /// the cable was pulled, or the body powered off. Over USB this is the *only* prompt signal
    /// (ImageCaptureCore ends the stream on `didRemove`), and until now nothing acted on it: the
    /// monitor sat on a dead session until the operator force-quit (#254/#253). Recover if a
    /// monitor is up; otherwise leave it to the normal connect path.
    private func recoverFromEndedEventChannel(session: NativeCameraSession) {
        guard cameraSession === session, isMonitorPresented else { return }
        beginSessionRecovery(host: session.identity.host, reason: "event channel ended")
    }

    /// Routes a device event from either channel (the GetEventEx poll or the PTP-IP socket).
    /// Capture events sync the app to a body-fired shutter; record-lifecycle events update the
    /// record state.
    private func handlePolledDeviceEvent(_ event: PTPEvent, session: NativeCameraSession) {
        noteStillReviewEvent(event)
        switch event.eventCode {
        case .objectAdded, .captureComplete:
            handleBodyFiredCapture(session: session)
        case .movieRecordStarted, .movieRecordComplete, .movieRecordInterrupted:
            if event.eventCode == .movieRecordInterrupted { gyroCapture.stop(reason: .interrupted) }
            if let state = event.inferredRecordState {
                applyCameraRecordState(isRecording: state == .recording)
            }
        case .devicePropChanged:
            noteCameraAnnouncedPropertyChange(event)
        case .unknown:
            break
        }
    }

    /// Queues an authoritative re-read of a property the CAMERA says changed (`DevicePropChanged`
    /// `0x4006`, from either event channel). The body is the source of truth: a dial, lens ring, or
    /// menu edit must reach every surface promptly, and the round-robin visits any one property
    /// only about every 20 s.
    ///
    /// The event carries no value, so it can only schedule a read — never mutate the snapshot. The
    /// queue is drained in announcement order, a whole burst per poll tick, by
    /// ``pollNextCameraProperty(session:)``: that keeps the reads on the existing single-flight
    /// poll and its cadence instead of racing the frame loop for the transaction gate, while a
    /// ring detent's dependent announcements can no longer bury the one value the operator is
    /// watching. Bounded by construction: deduplicated, and only the codes the monitor decodes.
    private func noteCameraAnnouncedPropertyChange(_ event: PTPEvent) {
        guard let property = event.changedPropertyCode else { return }
        cameraAnnouncedPropertyChanges.note(property)
    }

    /// Syncs the app to a capture fired ON THE CAMERA BODY: pulses the shutter button, runs
    /// instant playback, and refreshes shots-remaining. Debounced so a body burst (many
    /// ObjectAdded events) triggers ONE review, not one per frame. A no-op while an app-initiated
    /// release is in flight (that path runs its own review) or outside photography chrome.
    private func handleBodyFiredCapture(session: NativeCameraSession) {
        // The card object set changed — the next media pass must re-list (a backup twin fires
        // no event of its own).
        mediaProducer?.service.invalidateCatalogCoverage()
        if isStandaloneMediaLibraryPresented, mediaBrowserSource == .camera {
            scheduleDebouncedGalleryRelist()
        }
        guard !isStillCapturing, !pendingStillCapture,
            StillCapturePolicy.prefersPhotographyChrome(
                selector: cameraPropertySnapshot.captureSelector)
        else { return }
        let now = Date()
        if let last = lastBodyCaptureSyncAt, now.timeIntervalSince(last) < 0.8 { return }
        lastBodyCaptureSyncAt = now
        // Pulse the app's shutter button so a body-fired shutter visibly registers, then review.
        bodyShutterPulse &+= 1
        // Freeze the focus box at detection time — the review reads this, not the live value the
        // fetch window keeps overwriting.
        capturedFocusForReview = liveViewFocus
        scheduleInstantReview(session: session)
        Task { [weak self] in
            await self?.readAndApplyCameraProperty(session: session, property: .exposureRemaining)
        }
    }

    /// Releases the live-view pipeline, keepalive, event drain, and discovery when the app is
    /// backgrounded. A field monitor left running with the screen off otherwise keeps decoding ~30
    /// JPEG frames/sec, running the Core Image graph on the GPU, and holding the Wi-Fi radio — the
    /// worst battery/thermal profile on set, and enough sustained work for iOS to jetsam-kill the
    /// app so it vanishes mid-shoot. The session object is kept so `enterForeground()` can resume.
    func enterBackground() {
        retireOperatorQuickPresentation()
        gyroCapture.stop(reason: .backgrounded)
        AppDiagnostics.shared.record(.enteredBackground)
        screenWakeSuppressedForBackground = true
        syncScreenWakePolicy()
        // Give the volume buttons (and the phone camera) back to the system while backgrounded.
        bluetoothShutter.stop()
        // The FULL stop, not a bare task cancel: the discovery loop owns a relay NWBrowser that
        // browses over AWDL, and a bare cancel left that browser running through backgrounding —
        // with nothing on foreground re-stopping it, it kept time-slicing the radio under a
        // later resumed session.
        stopDiscoveryLoop()
        // Above the session guard: during a recovery gap `cameraSession` is nil, and the loop
        // kept opening PTP sessions until iOS suspended the app mid-handshake — leaving the
        // body holding a slot with no CloseSession.
        cancelSessionRecovery()
        guard let session = cameraSession else { return }
        monitorRuntime?.stopPreview()
        linkHealthUpdateTask?.cancel()
        linkHealthUpdateTask = nil
        // Media PTP traffic (clip download, listing, thumbnail sweep) must pause with the screen
        // off for the same battery/thermal reasons as live view. Clip-stream partial bytes are
        // kept (the next open resumes); an interrupted listing re-schedules on foreground; the
        // thumbnail queue is preserved so the worker picks it back up.
        cancelClipStream()
        pauseMediaListingForBackground()
        cancelThumbnailWork(resumingWaiters: false)
        // Best-effort: also tell the camera to drop live view (saves its battery/thermal). Tracked so
        // a quick foreground return waits for it before restarting; iOS may suspend us before it
        // completes, which is harmless.
        backgroundStopTask = Task { await session.stopLiveView() }
    }

    /// Pauses both an admitted cursor and an open request that has not returned a binding yet.
    @discardableResult func pauseMediaListingForBackground() -> Bool {
        guard let owner = mediaLibrary,
            owner.fetching || (owner.browsing && owner.binding == nil)
        else { return false }
        mediaProducer?.service.cancelCatalog()
        owner.close()
        mediaFetchInterruptedByBackground = true
        return true
    }

    /// Restores activity when the app returns to the foreground: re-warms the command channel and
    /// event drain, resumes live view if it was up, or restarts discovery on the connect screen. If
    /// the connection died while suspended, the live-view task's own backoff/reconnect recovers.
    func enterForeground() {
        AppDiagnostics.shared.record(.enteredForeground)
        screenWakeSuppressedForBackground = false
        syncScreenWakePolicy()
        // A relay watcher has no camera session, and `startDiscoveryLoop` bails on its
        // `isConnected` guard — so after one background round-trip the viewer browse never
        // came back, `discoveredRelayHosts` stayed empty, and the rejoin watchdog was blind
        // for the rest of the session (the audit's relay S1 #1).
        if videoSource == .relay {
            startRelayBrowsing(includePeerToPeer: false)
            return
        }
        guard let session = cameraSession else {
            if isCameraControlSession, isMonitorPresented {
                // Backgrounding cancelled an in-flight recovery (deliberately — see
                // `enterBackground`); the operator came back to the held frame, so pick the
                // reconnect back up instead of leaving a dead monitor.
                beginSessionRecovery(host: cameraHost, reason: "foreground resume")
            } else {
                startDiscoveryLoop(resetResults: false)
            }
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

    /// Publishes the integration pump's picture/header delivery. JPEG decoding and native
    /// scopes, relay, watch and display processing stay with their presentation owner.
    private func consumeCameraFrame(
        _ frame: PTPLiveViewFrame, delivery: NikonLiveViewPump.Delivery,
        session: NativeCameraSession, frameRate: inout FrameRateSampler,
        incident: NikonFeedIncidentProducer.Preview?
    ) async -> Bool {
        guard !Task.isCancelled, cameraSession === session else { return false }
        // Calibration needs the raw header at arrival, before decode or display smoothing.
        reconcileGyroCapture(recording: frame.isRecording)
        let cameraDown = frame.level.flatMap { level in
            level.hasPitch
                ? GyroCameraGravity.down(
                    rollDegrees: PTPLevelAngles.signedDegrees(level.roll),
                    pitchDegrees: PTPLevelAngles.signedDegrees(level.pitch)) : nil
        }
        gyroCapture.receiveCalibrationCamera(
            cameraDown,
            at: ProcessInfo.processInfo.systemUptime, sourceID: connectionGeneration)
        if delivery.headerOnly {
            liveViewFocus = frame.focus
            applyLiveViewHeaderState(frame)
            applyLiveViewHeaderTimecode(frame.timecode)
            captureRelayFrameMetadata(frame)
            publishWatchState()
            // Command and an HDMI picture source present the camera's header, not its image.
            let now = Date.timeIntervalSinceReferenceDate
            recoverySourceFrameAt = now
            recoveryPresentedAt = now
            return true
        }
        guard !Task.isCancelled, cameraSession === session,
            let decodeSource = frameDecoder.source(session)
        else { return false }
        incident?.received()
        let cleanFrame = await frameDecoder.decode(
            frame.jpeg, source: decodeSource, incident: incident)
        let decoded = await displayReadyLiveFrame(from: cleanFrame)
        guard !Task.isCancelled, cameraSession === session, let image = decoded, let cleanFrame
        else { return false }
        recoverySourceFrameAt = Date.timeIntervalSinceReferenceDate
        let arrival = CACurrentMediaTime()
        frameRate.recordFrame(at: arrival)
        lastGoodFrameAt = Date()
        consecutiveBadLiveFrames = 0
        measuredLiveViewFPS = frameRate.displayFPS
        if delivery.first {
            publishNativeFrame(image, clean: cleanFrame, owner: .camera(session))
            liveViewFocus = frame.focus
            isMonitorPresented = true
            AppDiagnostics.shared.record(.liveViewStarted)
            dismissConnectionProgress()
            isStreamRecovering = false
            connectionMessage = "Live view streaming from \(session.identity.displayName)."
            connection = .connected
        } else {
            if relayPeerCount == 0, measuredLiveViewFPS > 0 {
                relaySoloFPSBaseline =
                    relaySoloFPSBaseline == 0
                    ? measuredLiveViewFPS
                    : relaySoloFPSBaseline + 0.05 * (measuredLiveViewFPS - relaySoloFPSBaseline)
            }
            publishLiveFrameDisplay(
                image: image, cleanFrame: cleanFrame, focus: frame.focus, session: session)
            captureRelayFrameMetadata(frame)
            broadcastRelayFrame(image: cleanFrame)
            let watchEffects = image === cleanFrame ? liveImageEffects : nil
            watchRelay.ingestFrame(
                image: image, applying: watchEffects, timecode: frame.timecode,
                isRecording: frame.isRecording)
            sampleScopesIfDue(clean: cleanFrame) { [weak self] in self?.cameraSession === session }
        }
        incident?.published()
        recoveryPresentedAt = Date.timeIntervalSinceReferenceDate
        applyLiveViewHeaderState(frame)
        applyLiveViewHeaderTimecode(frame.timecode)
        if !delivery.bodyBusy { liveFPS = frameRate.formatted }
        return true
    }

    private func formattedSeconds(_ seconds: Double) -> String {
        seconds >= 1 ? "\(Int(seconds))s" : "\(Int(seconds * 1000))ms"
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
            let sourceGeneration = connectionGeneration
            guard cameraSession === session else { return }
            // The operator chose to AF at a point — subsequent releases resume normal AF focus.
            do {
                if let admission = point.admission {
                    try admission.require(owner: session.commandOwner)
                }
                focusManuallyDialed = false
                if let admission = point.admission {
                    try await session.changeAfArea(x: point.x, y: point.y, admission: admission)
                } else {
                    try await session.changeAfArea(x: point.x, y: point.y)
                }
                guard cameraSession === session, connectionGeneration == sourceGeneration else {
                    return
                }
                // Moving the point alone never focuses — drive AF like a half-press, with a
                // short DeviceReady drain so the body isn't left mid-drive. Subject tracking
                // latches through the same area change. Out-of-focus or a still-busy timeout
                // stays silent; the AF box state in the header tells the story.
                //
                // This used to key on photography alone, on the assumption that video always
                // runs continuous AF. A video AF-S body has no such loop, so the tap moved the
                // box and focused nothing — #272, where AF-F "worked" only because the camera's
                // own loop chased the box. The policy keys on the focus mode now — the mode of
                // the ACTIVE side: the stills mode (AF-S) driving this decision in video mode is
                // how a tap fired a one-shot drive against a body running AF-F. [verify-on-HW]
                let photography = StillCapturePolicy.prefersPhotographyChrome(
                    selector: cameraPropertySnapshot.captureSelector)
                if StillCapturePolicy.focusPointNeedsAutofocusDrive(
                    focusMode: cameraPropertySnapshot.activeFocusMode(photography: photography),
                    photography: photography)
                {
                    if let admission = point.admission {
                        try await session.afDrive(admission: admission)
                    } else {
                        try await session.afDrive()
                    }
                    guard cameraSession === session, connectionGeneration == sourceGeneration else {
                        return
                    }
                    // Drain readiness one poll per safe point instead of sleeping ~0.5 s inline:
                    // this runs INSIDE the live-view frame loop, so blocking here is a visible
                    // feed hitch every time tap-to-focus starts.
                    focusAFSettlePolls = 4
                }
            } catch {
                guard cameraSession === session, connectionGeneration == sourceGeneration else {
                    return
                }
                if case NativeCameraSessionError.commandAuthorityExpired = error {
                    showMonitorNotice(error.localizedDescription)
                    logConnection("focus point authority expired before the next command")
                    return
                }
                // A focus point the camera refused must read on the monitor (A1-02), or it is
                // indistinguishable from a tap that never registered. Logged with the body's own
                // response code too.
                let reason =
                    (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                logConnection("focus point rejected at (\(point.0),\(point.1)): \(reason)")
                showMonitorNotice("Camera rejected the focus point: \(reason)")
            }
            return
        }
        if focusAFSettlePolls > 0 {
            focusAFSettlePolls -= 1
            if case .inProgress = (try? await session.pollStillReleaseReadiness()) {
                // Still driving — keep the remaining budget and check again next frame.
            } else {
                focusAFSettlePolls = 0
            }
            return
        }
        // The integration owns explicit common record targets and their wire receipts.
        if await monitorRuntime?.serviceControlSafePoint(allowWrites: false) == true { return }
        // Still release (photography mode): fire queued releases and track completion
        // with DeviceReady between frames, exactly like the record path above.
        if await serviceStillCaptureWork(session: session) {
            return
        }
        if await monitorRuntime?.serviceControlSafePoint() == true { return }
        if await performNextPendingCameraWrite(session: session) {
            return
        }
        // Nikon delivers a body-fired capture (ObjectAdded / CaptureComplete) AND
        // `DevicePropChanged` through the GetEventEx poll, not the PTP-IP event socket the drain
        // loop reads — so poll it on a brisk cadence in EVERY chrome. This used to be gated to
        // photography, where it was introduced for body-fired stills, which left cinema mode — how
        // the ZR is normally shot — with no fast path for a body-side aperture/ISO/shutter change
        // at all: it fell back to a round-robin that revisits any one property about every 20 s
        // (#268). The chrome test lives in each consumer, which already applies it:
        // `handleBodyFiredCapture` is a no-op outside photography. Single-flight so the poll can't
        // stack behind the transaction gate and jitter the feed.
        // Both cadences below scale with what one poll actually costs on THIS link: each poll is
        // a PTP round trip the next frame fetch queues behind, and on a router path a fixed
        // stride turned into a visible periodic hitch (see `LiveViewPollPacing`).
        let framePeriodMilliseconds = 1000 / max(1, Double(cameraPropertySnapshot.fps ?? 30))
        let measuredRoundTrip = session.readLastCommandRoundTripMilliseconds()
        monitorRuntime?.pollDeviceEventsAtSafePoint(
            frameCounter: frameCounter,
            framePeriodMilliseconds: framePeriodMilliseconds,
            roundTripMilliseconds: measuredRoundTrip
        ) { [weak self] event in
            guard let self, self.cameraSession === session else { return }
            self.handlePolledDeviceEvent(event, session: session)
        }
        // A pending camera-announced change jumps the background cadence — the operator's own hand
        // on the body should not wait out a poll interval sized for idle round-robin. The stride
        // and its bound live on the queue itself, next to the batch limit they balance against.
        // Only the IDLE round-robin spreads out on a slow link; announced changes keep their fast
        // cadence — one bounded read is worth a frame slot even there.
        let propertyPollStride =
            cameraAnnouncedPropertyChanges.isEmpty
            ? CameraAnnouncedPropertyQueue.idlePollStride
                * LiveViewPollPacing.idlePollStrideMultiplier(
                    roundTripMilliseconds: measuredRoundTrip,
                    framePeriodMilliseconds: framePeriodMilliseconds)
            : cameraAnnouncedPropertyChanges.pollStride
        guard pollEveryCall || frameCounter.isMultiple(of: propertyPollStride) else { return }
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
    /// mode. The publish path has no cadence gate, so the first frame after any
    /// pause always publishes.
    /// Publishes every frame the camera delivers. No cadence cap, by design.
    ///
    /// There used to be a 1/24 s floor here, multiplied further when the phone warmed up. Both are
    /// gone. The cap could only ever make the feed less smooth than the stream the operator paid
    /// for, and worse, a wall-clock `elapsed >= interval` gate against a fixed-period source
    /// cannot land on an arbitrary target rate — it can only pass every Nth frame. Against a
    /// 28 fps stream the "gentle" 1.5x thermal multiplier therefore halved the feed rather than
    /// slowing it by half as much, and the documented 12 fps floor was really about 9.
    ///
    /// The identity and equality checks below are the only filtering that remains, and they
    /// suppress redundant observable writes rather than frames.
    private func publishLiveFrameDisplay(
        image: UIImage, cleanFrame: UIImage, focus: PTPLiveViewFocusInfo?,
        session: NativeCameraSession
    ) {
        publishNativeFrame(image, clean: cleanFrame, owner: .camera(session))
        if liveViewFocus != focus {
            dismissInstantReviewIfAutofocusEngaged(previous: liveViewFocus, next: focus)
            liveViewFocus = focus
        }
    }

    /// A half-press on the body clears the review at once, instead of the operator waiting out a
    /// countdown they have already decided to abandon.
    ///
    /// There is no half-press signal on the wire, so this reads the thing a half-press CAUSES:
    /// autofocus running. Header byte 42 is idle until the body drives AF, so the transition out
    /// of idle is the press. Shooting two or three frames in a row is exactly when the delay is
    /// felt, and exactly when the operator's finger is already back on the button.
    ///
    /// A TRANSITION, never a level: in AF-C and AF-F the body focuses continuously while live view
    /// runs, so AF is already engaged when the review opens and stays that way. Testing the level
    /// would dismiss every review the instant it appeared. This costs the shortcut in those modes
    /// — which is today's behaviour, not a regression — and never fires when nobody pressed.
    private func dismissInstantReviewIfAutofocusEngaged(
        previous: PTPLiveViewFocusInfo?, next: PTPLiveViewFocusInfo?
    ) {
        guard instantReview != nil,
            previous?.focusResult == PTPLiveViewFocusInfo.FocusResult.unknown,
            let engaged = next?.focusResult, engaged != .unknown
        else { return }
        dismissInstantReview()
    }

    /// One shared scope tap per due frame, through the shared assist engine (A1-05): its cadence,
    /// sampler, traffic lights and bundle, on this camera's transfer and stated clip. The portrait
    /// scopes stack renders exactly these tools. Mode-filtered: a clean view with nothing pinned
    /// samples no scopes at all.
    ///
    /// Always metered on the CLEAN frame — false colour, LUT, zebra and peaking are display-only
    /// assists and must not shift histogram, waveform, parade or traffic-light readings. Every
    /// picture source lands here (camera stream, HDMI capture, relay, the demo still), so the
    /// scopes read identically whichever delivered the frame.
    ///
    /// `isStillCurrent` is re-checked when the bundle returns, and the bus refuses a retired
    /// source's lease, so a source torn down mid-tap cannot publish for a gone picture.
    func sampleScopesIfDue(
        clean: UIImage, full: Bool = false, isStillCurrent: @escaping @MainActor () -> Bool
    ) {
        let policy = liveScopePolicy(full: full)
        guard policy.needsScopes else {
            if scopeAssist != .empty { clearScopeAssist() }
            return
        }
        guard let source = nativePictureSource, let image = clean.cgImage else { return }
        if scopeEngineSource !== source {
            scopeEngine.reset()
            scopeEngine.adopt(exposureCeiling: source.exposureCeiling)
            scopeEngineSource = source
        }
        let mapping = exposureSignalMapping
        let transfer = mapping.curve.monitorTransfer
        source.exposureCeiling.declare(clipByte: mapping.clipByte, for: transfer)
        let publish = captureLiveScopePublication()
        scopeEngine.sample(image, effects: policy, transfer: transfer) { result in
            guard let bundle = result.bundle else { return }
            Task { @MainActor in
                guard isStillCurrent() else { return }
                publish(bundle)
            }
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
                showMonitorNotice(
                    "Camera rejected end-tracking: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
                )
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
                    showMonitorNotice(
                        "Camera rejected subject-detection suspend: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
                    )
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
                    showMonitorNotice(
                        "Camera rejected subject-detection restore: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
                    )
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
        // Body rotation (byte 839) → vertical mode. Guarded write: this runs per frame and an
        // unconditional set would invalidate the whole feed layout 30×/s.
        if liveFeedRotation != frame.rotation { liveFeedRotation = frame.rotation }
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
        let reportedLevels = frame.sound.map { MonitorAudioMeterLevels(cameraIndicator: $0) }
        if observedLiveAudioLevels != reportedLevels { observedLiveAudioLevels = reportedLevels }
        // Record state (header byte 828). Suppress the override while a queued app command is in
        // flight or briefly after one was sent so the optimistic flip isn't undone before the safe
        // point runs (and while the body catches up).
        // Observed at arrival: decoding must not replay an older REC report after a newer event.
        applyCameraRecordState(isRecording: frame.isRecording, observeGyro: false)
    }

    /// Applies camera-authoritative record state from the live-view header or async PTP events.
    private func applyCameraRecordState(
        isRecording recording: Bool, force: Bool = false, observeGyro: Bool = true
    ) {
        if observeGyro { reconcileGyroCapture(recording: recording) }
        // The camera's report is recorded even while the button defers to an app command below:
        // that report is exactly what confirms (or never confirms) the command.
        if reportedRecording != recording {
            retireOperatorQuickPresentation()
            reportedRecording = recording
            refreshCommonControlFacts()
        }
        guard force || !shouldSuppressCameraRecordStateSync() else { return }
        guard isRecording != recording else { return }
        isRecording = recording
        cameraState = cameraState.updating(recordState: recording ? .recording : .standby)
        publishWatchState()
        applyThermalStreamStepDownIfNeeded()
    }

    /// Whether live-view header / event readback should defer to an in-flight app record command.
    private func shouldSuppressCameraRecordStateSync() -> Bool {
        if pendingRecordToggle || shell.control.recordPending { return true }
        if let sentAt = appRecordCommandAt, Date().timeIntervalSince(sentAt) < 1.5 { return true }
        return false
    }

    private func resetPendingRecordCommand() {
        pendingRecordToggle = false
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
        let sourceGeneration = connectionGeneration
        guard cameraSession === session else { return true }
        let isShutterModeWrite = pending.write.property == .movieShutterMode
        let isBaseISOWrite = pending.write.property == .movieBaseISO
        let isISOAutoWrite =
            pending.write.property == .movieISOAutoControl
            || pending.write.property == .stillISOAutoControl
        let isFocusModeWrite = pending.write.property == .movieFocusMode
        let isShutterLockWrite = pending.write.property == .movieTVLockSetting
        do {
            let writeStarted = ContinuousClock.now
            if let admission = pending.admission {
                try await session.writeCameraProperty(pending.write, admission: admission)
            } else {
                try await session.writeCameraProperty(pending.write)
            }
            guard cameraSession === session, connectionGeneration == sourceGeneration else {
                return true
            }
            // A body can sit on a write for seconds (e.g. a focus-mode motor handoff) while
            // it holds the transaction gate — and with it the whole feed. Leave a trace so
            // "the app stalled" reports become attributable to the property that stalled.
            let writeSeconds = writeStarted.duration(to: .now) / .seconds(1)
            if writeSeconds > 1.5 {
                AppDiagnostics.shared.record(.propertyWriteSlow)
                logConnection(
                    String(
                        format: "slow write %@: %.1fs",
                        String(describing: pending.write.property), writeSeconds))
            }
            // The CAMERA decides what a write landed on, so read the property back and apply that —
            // never the requested bytes. Echoing the request lets a slow write (a body can sit on
            // one for seconds) clobber a newer body-originated value the poll already picked up,
            // and hides a value the body silently clamped or refused in part. Android confirms
            // every control write by readback (`confirmAndroidControlWrites`); this is parity.
            // A failed read keeps the requested bytes on screen, but never in the reported
            // snapshot: the seam calls that outcome unknown, not success.
            let readback = try? await session.readCameraProperty(pending.write.property)
            guard cameraSession === session, connectionGeneration == sourceGeneration else {
                return true
            }
            if let readback {
                applyCameraRead(pending.write.property, readback)
            } else {
                cameraPropertySnapshot = cameraPropertySnapshot.applying(
                    property: pending.write.property,
                    data: pending.write.data
                )
            }
            // A confirmed write supersedes any queued re-read of the same property.
            cameraAnnouncedPropertyChanges.cancel(pending.write.property)
            if isShutterModeWrite || isBaseISOWrite || isISOAutoWrite || isFocusModeWrite
                || isShutterLockWrite
            {
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
                        guard cameraSession === session, connectionGeneration == sourceGeneration
                        else { return true }
                    }
                }
                if isBaseISOWrite {
                    pendingBaseISOHigh = nil
                }
                if isISOAutoWrite {
                    pendingISOAuto = nil
                }
                if isShutterLockWrite {
                    pendingShutterLockState = nil
                }
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
            } else if isISOAutoWrite {
                connectionMessage =
                    pending.value == "Auto On"
                    ? "ISO set to Auto."
                    : "ISO set to Manual."
            } else if isFocusModeWrite {
                connectionMessage = focusModeWriteMessage(
                    requested: pending.value,
                    reported: cameraPropertySnapshot.focusMode)
            } else {
                connectionMessage = "\(pending.picker.title) set to \(pending.value)."
            }
        } catch {
            guard cameraSession === session, connectionGeneration == sourceGeneration else {
                return true
            }
            if case NativeCameraSessionError.commandAuthorityExpired = error {
                // Refused before the first send, not a camera lock. Keep any valid successor target.
                let refused =
                    [pending]
                    + pendingCameraWrites.filter {
                        $0.admission.map { !$0.admits(session.commandOwner) } == true
                    }
                pendingCameraWrites.removeAll {
                    $0.admission.map { !$0.admits(session.commandOwner) } == true
                }
                for refusedWrite in refused {
                    let property = refusedWrite.write.property
                    guard !pendingCameraWrites.contains(where: { $0.write.property == property })
                    else { continue }
                    if property == .movieShutterMode { pendingShutterMode = nil }
                    if property == .movieBaseISO { pendingBaseISOHigh = nil }
                    if property == .movieISOAutoControl || property == .stillISOAutoControl {
                        pendingISOAuto = nil
                    }
                    if property == .movieTVLockSetting { pendingShutterLockState = nil }
                    if refusedWrite.picker == .whiteBalance { lastCommittedTint = nil }
                }
                cameraPropertySnapshot = reportedPropertySnapshot
                for queued in pendingCameraWrites {
                    cameraPropertySnapshot = cameraPropertySnapshot.applying(
                        property: queued.write.property, data: queued.write.data)
                }
                publishCameraDisplayState()
                syncFocusFromSnapshot()
                syncShutterLockFromSnapshot()
                showMonitorNotice(error.localizedDescription)
                return true
            }
            // The camera refused the write — the body's "Control lock" has this control locked
            // (it can lock shutter / aperture / focus). Flag it so the bar shows a lock, and
            // revert the optimistic value to what the camera actually reports.
            if isShutterModeWrite {
                pendingShutterMode = nil
            }
            if isBaseISOWrite {
                pendingBaseISOHigh = nil
            }
            if isISOAutoWrite {
                pendingISOAuto = nil
            }
            if isShutterLockWrite {
                pendingShutterLockState = nil
                if let actual = try? await session.readCameraProperty(pending.write.property) {
                    guard cameraSession === session, connectionGeneration == sourceGeneration else {
                        return true
                    }
                    applyCameraRead(pending.write.property, actual)
                    publishCameraDisplayState()
                }
                guard cameraSession === session, connectionGeneration == sourceGeneration else {
                    return true
                }
                syncFocusFromSnapshot()
                syncShutterLockFromSnapshot()
                let locking = pending.write.data.first == 1
                showMonitorNotice(
                    locking
                        ? "Could not lock shutter control on camera."
                        : "Could not unlock shutter control on camera.")
            } else if isShutterModeWrite || isBaseISOWrite {
                if let actual = try? await session.readCameraProperty(pending.write.property) {
                    guard cameraSession === session, connectionGeneration == sourceGeneration else {
                        return true
                    }
                    applyCameraRead(pending.write.property, actual)
                    publishCameraDisplayState()
                    syncFocusFromSnapshot()
                }
                guard cameraSession === session, connectionGeneration == sourceGeneration else {
                    return true
                }
                syncShutterLockFromSnapshot()
                showMonitorNotice(
                    isShutterModeWrite
                        ? "Shutter angle/speed mode change was rejected by the camera."
                        : "ISO base circuit change was rejected by the camera.")
            } else {
                lockedControls.insert(pending.picker)
                if let actual = try? await session.readCameraProperty(pending.write.property) {
                    guard cameraSession === session, connectionGeneration == sourceGeneration else {
                        return true
                    }
                    applyCameraRead(pending.write.property, actual)
                    publishCameraDisplayState()
                    syncFocusFromSnapshot()
                }
                guard cameraSession === session, connectionGeneration == sourceGeneration else {
                    return true
                }
                syncShutterLockFromSnapshot()
                showMonitorNotice(
                    isFocusModeWrite
                        ? focusModeWriteFailureMessage(
                            requested: pending.value, reported: cameraPropertySnapshot.focusMode)
                        : "\(pending.picker.title) is locked on the camera (Control lock).")
            }
        }
        return true
    }

    /// Reflects `MovieTVLockSetting` poll readback into `lockedControls` for the shutter picker.
    /// A pending write's target (`true` unlocks) wins over the readback until it lands.
    ///
    /// This runs after every camera property read, four times a second under a cover. An
    /// in-place `insert`/`remove` notifies observers even when membership is unchanged, which
    /// re-ran the hidden live surface on every poll (R-03), so only a real change is written.
    private func syncShutterLockFromSnapshot() {
        guard
            let locked = pendingShutterLockState.map({ !$0 })
                ?? cameraPropertySnapshot.shutterLocked,
            lockedControls.contains(.shutter) != locked
        else { return }
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

    /// Constant camera-header TC sync — every live-view frame updates the hero readout.
    private func applyLiveViewHeaderTimecode(_ timecode: Timecode) {
        if timecode != liveTimecode { liveTimecode = timecode }
        if timecode.on != cameraReportsTimecode { cameraReportsTimecode = timecode.on }
    }

    /// Full live-order property + storage + descriptor burst (Android bootstrap parity).
    /// Call once after connect / before the first `StartLiveView`.
    private func bootstrapCameraProperties(session: NativeCameraSession) async {
        await monitorRuntime?.bootstrapProperties(initial: cameraPropertySnapshot) {
            [weak self] observation in
            guard let self, cameraSession === session else { return }
            applyBootstrapObservation(observation)
        }
    }

    /// Applies the integration's actual bootstrap reports to the app display and common facts.
    /// The steady property poll applies each read through `.property` here too.
    func applyBootstrapObservation(_ observation: NikonBootstrapObservation) {
        switch observation {
        case .property(let property, let data):
            applyCameraRead(property, data)
            // The DISP cycle follows the camera mode from the first read on, not only after a
            // photo/video flip: a connect or reconnect declares it here (baseline computed it).
            if property == .liveViewSelector { operatorSession.declare(modes: displayModes) }
            publishCameraDisplayState()
            syncFocusFromSnapshot()
            syncShutterLockFromSnapshot()
            if property == .warningStatus { applyThermalStreamStepDownIfNeeded() }
        case .storage(let info):
            lastKnownStorage = info
            lastStorageRefreshAt = Date()
        case .apertures(let values):
            cacheAdvertisedApertures(
                values,
                property: reportedPropertySnapshot.captureSelector == .photo
                    ? .fNumber : .movieFNumber)
        case .screenModes(let values): cameraScreenModes = values
        case .fileTypes(let values): cameraFileTypeModes = values
        case .movieTones(let property, let tones): cameraMovieTones[property] = tones
        case .descriptor(let property, let observation):
            cameraDescriptorEvidence[property, default: .init()].record(observation)
        case .options(let property, let values):
            cacheAdvertisedControlOptions(values, property: property)
        case .photographyReady: seedInstantReviewBaseline()
        case .descriptorsReady:
            propertyPollIndex = 0
            lastDescriptorRefreshAt = Date()
            publishCameraDisplayState()
            syncFocusFromSnapshot()
            syncShutterLockFromSnapshot()
        }
    }

    private func cacheAdvertisedControlOptions(_ values: [String], property: PTPPropertyCode) {
        cameraControlOptions[property] = values
        if property == .movieShutterAngle || property == .movieShutterSpeed {
            // An inactive circuit's one-value placeholder is not a writable movie domain.
            advertisedExposureOptions[property] = values.count > 1 ? values : []
        }
    }

    private func cacheAdvertisedApertures(_ values: [String], property: PTPPropertyCode) {
        cameraApertures = values
        advertisedExposureOptions[property] = values
    }

    private func consumeStagedClockSync(session: NativeCameraSession) async {
        guard cameraSession === session else { return }
        await monitorRuntime?.consumeStagedClockSync(recording: reportedRecording)
    }

    /// Reads the active selector's whole monitor property set back-to-back (skipping properties
    /// the body doesn't advertise, like the steady-state poll does) so the chrome fills in one
    /// pass instead of one property per frame gap.
    private func burstMonitorProperties(session: NativeCameraSession) async {
        let order = PTPPropertyCode.monitorPollOrder(
            isRecording: false, captureSelector: cameraPropertySnapshot.captureSelector)
        for property in order where property != .liveViewSelector {
            guard !Task.isCancelled, cameraSession === session else { return }
            guard session.supportsProperty(property) else { continue }
            await readAndApplyCameraProperty(session: session, property: property)
        }
        if StillCapturePolicy.prefersPhotographyChrome(
            selector: cameraPropertySnapshot.captureSelector)
        {
            // A stale remote mode from an interrupted burst would keep the body's controls
            // locked — restore the PC-camera mode defensively on every photo (re)entry.
            // (The burst ceiling itself is written inside the hold's remote-mode bracket;
            // outside remote mode host-set session values don't persist.)
            try? await session.changeCameraMode(remote: false)
            seedInstantReviewBaseline()
        }
    }

    /// Single-flight selector-flip burst: when the body switches photo ↔ movie mid-session, the
    /// freshly relevant property set bursts immediately (frames briefly share the channel) rather
    /// than trickling in through the interleaved poll.
    @ObservationIgnored private var selectorFlipBurstTask: Task<Void, Never>?

    private func burstPropertiesAfterSelectorFlip(session: NativeCameraSession) {
        guard selectorFlipBurstTask == nil else { return }
        logConnection(
            "selector flip → \(cameraPropertySnapshot.captureSelector == .photo ? "photo" : "movie")-order burst"
        )
        selectorFlipBurstTask = Task { [weak self] in
            await self?.burstMonitorProperties(session: session)
            // The flipped side's descriptor domains (image-size enum on the photo side) should
            // land promptly too — let the next maintenance tick run them instead of waiting out
            // the slow cadence.
            self?.lastDescriptorRefreshAt = nil
            self?.selectorFlipBurstTask = nil
        }
    }

    private func pollNextCameraProperty(session: NativeCameraSession) async {
        // A staged clock correction goes first: this is the earliest moment `isRecording`
        // reflects the frame header rather than a fresh session's default.
        await consumeStagedClockSync(session: session)
        guard !Task.isCancelled, cameraSession === session else { return }
        // While the EV tool is on, the indicator reads on every poll tick alongside the
        // round-robin property — a needle visited once per full property cycle lags whole
        // seconds behind the meter. The lit-state gate refreshes on a slow stride, and
        // recording keeps its sparse health poll untouched.
        if !isRecording,
            assist.liveTools.contains(.evMeter),
            session.supportsProperty(.exposureIndicateStatus)
        {
            evFastPollTick &+= 1
            await readAndApplyCameraProperty(
                session: session,
                property: evFastPollTick.isMultiple(of: 8)
                    ? .exposureIndicateLightup : .exposureIndicateStatus)
            guard !Task.isCancelled, cameraSession === session else { return }
        }
        // Auto-exposure shutter/ISO/iris often change with no DevicePropChanged (#268
        // round three: photo A-mode left 1/125 · A900 on screen while the body showed
        // 1/30 · 1000). One rotating camera-owned readout per idle tick; M + manual
        // ISO is a no-op. Recording keeps the compact health poll.
        if !isRecording,
            let autoExposure = CameraAutoExposureReadouts.nextProperty(
                pollIndex: autoExposurePollTick,
                snapshot: cameraPropertySnapshot)
        {
            autoExposurePollTick &+= 1
            if session.supportsProperty(autoExposure) {
                await readAndApplyCameraProperty(session: session, property: autoExposure)
                guard !Task.isCancelled, cameraSession === session else { return }
            }
        }
        // Properties the CAMERA announced as changed jump the queue: they are the operator's own
        // edit on the body, and the round-robin would otherwise take a full cycle to notice. The
        // WHOLE pending burst drains on the tick that sees it, oldest first and capped
        // (`CameraAnnouncedPropertyQueue.batchLimit`) — one detent of an aperture ring announces
        // the aperture plus its dependents, and draining one arbitrary entry per tick left the
        // watched value buried. Maintenance runs once after the batch, not once per read, so the
        // batch stays a tight run of reads. The round-robin index does NOT advance, so no regular
        // property is skipped.
        if !cameraAnnouncedPropertyChanges.isEmpty {
            for announced in cameraAnnouncedPropertyChanges.nextBatch()
            where session.supportsProperty(announced) {
                await readAndApplyCameraProperty(session: session, property: announced)
                guard !Task.isCancelled, cameraSession === session else { return }
            }
            await refreshCameraMaintenanceIfDue(session: session)
            return
        }
        let property = PTPPropertyCode.nextMonitorPollProperty(
            pollIndex: propertyPollIndex,
            isRecording: isRecording,
            captureSelector: cameraPropertySnapshot.captureSelector)
        propertyPollIndex &+= 1
        // Skip 2-byte properties the body's DeviceInfo doesn't advertise (e.g. the legacy
        // microphone pair on cinema bodies) — the read would fail every cycle.
        guard session.supportsProperty(property) else { return }
        if property == .movieShutterMode, shouldSuppressShutterModePoll() {
            // A mode switch is queued or optimistic — don't let stale camera readback undo the bar.
        } else if property == .movieTVLockSetting, shouldSuppressShutterLockPoll() {
            // A lock/unlock is queued or optimistic — don't let stale poll re-lock the picker.
        } else if property == .movieBaseISO, shouldSuppressBaseISOPoll() {
            // Same for dual-base ISO — keep the picker tab on the circuit the operator chose.
        } else {
            await readAndApplyCameraProperty(session: session, property: property)
        }
        await refreshCameraMaintenanceIfDue(session: session)
    }

    /// A value the camera returned, applied to the display snapshot and the reported one.
    private func applyCameraRead(_ property: PTPPropertyCode, _ data: Data) {
        let previous = reportedPropertySnapshot
        cameraPropertySnapshot = cameraPropertySnapshot.applying(property: property, data: data)
        reportedPropertySnapshot = reportedPropertySnapshot.applying(property: property, data: data)
        if property == .movieFileType {
            stabilizationFileTypeReadback = reportedPropertySnapshot.fileType
        }
        if previous.captureSelector != reportedPropertySnapshot.captureSelector {
            advertisedExposureOptions = [:]
        } else if previous.shutterMode != reportedPropertySnapshot.shutterMode {
            advertisedExposureOptions.removeValue(forKey: .movieShutterAngle)
            advertisedExposureOptions.removeValue(forKey: .movieShutterSpeed)
        }
        if previous.lens != reportedPropertySnapshot.lens {
            advertisedExposureOptions.removeValue(forKey: .fNumber)
            advertisedExposureOptions.removeValue(forKey: .movieFNumber)
        }
    }

    /// One property read applied into the snapshot and derived monitor state.
    private func readAndApplyCameraProperty(
        session: NativeCameraSession,
        property: PTPPropertyCode
    ) async {
        do {
            let data = try await session.readCameraProperty(property)
            if Self.commandTileDiagnosticProps.contains(property),
                commandTileDiagnosticLogged.insert(property).inserted
            {
                let hex = data.map { String(format: "%02x", $0) }.joined()
                logConnection("cmd-tile \(property) ok bytes=[\(hex)] len=\(data.count)")
            }
            let previousSelector = cameraPropertySnapshot.captureSelector
            applyBootstrapObservation(.property(property, data))
            if property == .liveViewSelector,
                let previousSelector,
                cameraPropertySnapshot.captureSelector != previousSelector
            {
                // A photo ↔ movie flip mid-session: the freshly relevant set bursts rather than
                // trickling through the interleaved poll. (The nil→first read is the bootstrap's
                // own selector read — its loop already covers the right order.)
                burstPropertiesAfterSelectorFlip(session: session)
                // The other side's panels/popups make no sense on this chrome — close
                // whatever is open rather than leaving a stale drum floating.
                dismissActivePanel()
                // Photography does not offer the command monitor.
                operatorSession.declare(modes: displayModes)
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
        // ONE descriptor group per pass, at a fifth of the group interval — same per-group
        // freshness as the old five-reads-in-a-row burst every full interval, but spread so
        // no single pass steals more than one frame slot (audit finding: wall-clock bursts
        // ignore the frame-relative pacing and landed as a visible periodic hitch on Wi-Fi).
        if CameraMonitorPollPolicy.isDue(
            lastRefreshAt: lastDescriptorRefreshAt,
            now: now,
            interval: CameraMonitorPollPolicy.descriptorRefreshInterval / 5)
        {
            lastDescriptorRefreshAt = now
            switch descriptorRefreshCursor % 5 {
            case 0: await refreshLensApertures(session: session)
            case 1: await refreshStillShutterOptions(session: session)
            case 2: await refreshScreenModes(session: session)
            case 3:
                await refreshFileTypeModes(session: session)
                await refreshMovieToneOptions(session: session)
            default: await refreshControlOptions(session: session)
            }
            descriptorRefreshCursor += 1
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
        // Shared across both chromes — the MODE drum reads the same 0x500E property in movie and
        // photo mode, so it is described on every cadence rather than only in photography.
        (.exposureProgramMode, 2),
    ]

    /// Photo-mode function pickers whose option lists the body enumerates. Read only while the
    /// photography chrome is up: describing the stills AF / drive / quality space in movie mode
    /// costs camera round trips for drums nobody can open, and several of these properties report
    /// a placeholder domain outside their own chrome. Each body advertises its own values in its
    /// own order — that is the whole point of #274, so nothing here has a "union" fallback.
    private static let photographyEnumeratedControls:
        [(property: PTPPropertyCode, valueByteCount: Int)] = [
            (.stillCaptureMode, 2),
            (.userMode, 1),
            (.exposureMeteringMode, 2),
            (.flashMode, 2),
            (.compressionSetting, 1),
            (.rawCompressionType, 1),
            (.activePicCtrlItem, 2),
            (.stillFocusMode, 1),
            (.stillFocusMeteringMode, 2),
            (.afSubjectDetection, 1),
        ]

    /// Reads the camera's advertised option lists for the moded AF / shutter / WB-preset settings
    /// so each picker offers exactly what the body supports. Re-read on the slow descriptor
    /// cadence; on rejection or an empty result the last known options (or hardcoded fallback) are
    /// kept. The WB enum's colour-temperature mode belongs to the Kelvin tab, so it's filtered out.
    private func refreshControlOptions(session: NativeCameraSession) async {
        let shutterMode = effectiveShutterMode()
        let photography = StillCapturePolicy.prefersPhotographyChrome(
            selector: cameraPropertySnapshot.captureSelector)
        let controls =
            Self.enumeratedControls
            + (photography ? Self.photographyEnumeratedControls : [])
        for (property, valueByteCount) in controls {
            if property == .movieShutterSpeed, shutterMode != .speed { continue }
            if property == .movieShutterAngle, shutterMode != .angle { continue }
            // A body that never lists the property spends nothing on a describe that will fail;
            // its picker keeps the conservative fallback.
            if Self.photographyEnumeratedControls.contains(where: { $0.property == property }),
                !session.supportsProperty(property)
            {
                continue
            }
            await refreshControlOption(
                session: session, property: property, valueByteCount: valueByteCount)
        }
        // ImageSize is a standard-space *string* enum, so it takes the plain describe op rather
        // than the fixed-width path above. Photography only, and re-read on this same slow
        // cadence — its domain reshapes when the image-area crop changes.
        if StillCapturePolicy.prefersPhotographyChrome(
            selector: cameraPropertySnapshot.captureSelector),
            session.supportsProperty(.imageSize),
            let options = try? await session.stringEnumOptions(for: .imageSize),
            options.count > 1, cameraControlOptions[.imageSize] != options
        {
            cameraControlOptions[.imageSize] = options
            logConnection("options imageSize: \(options.joined(separator: ", "))")
        }
        // The stills WB preset enum feeds the photo WB popup (the popup itself is the movie
        // one). Colour temperature belongs to the Kelvin tab, mirroring the movie filter.
        if StillCapturePolicy.prefersPhotographyChrome(
            selector: cameraPropertySnapshot.captureSelector),
            session.supportsProperty(.whiteBalance),
            let raw = try? await session.controlOptions(for: .whiteBalance, valueByteCount: 2)
        {
            let options = raw.filter { $0 != "Color temp" }
            if options.count > 1, cameraControlOptions[.whiteBalance] != options {
                cameraControlOptions[.whiteBalance] = options
                logConnection("options stillWB: \(options.joined(separator: ", "))")
            }
        }
        let source = operatorLiveIdentity
        await NikonPropertyBootstrap(link: session).observeStabilizationDescriptors(
            isCurrent: { self.cameraSession === session && self.operatorLiveIdentity == source },
            receive: { self.applyBootstrapObservation($0) })
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
            guard cameraSession === session else { return }
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
                advertisedExposureOptions.removeValue(forKey: property)
                return
            }
            if property == .movieShutterSpeed || property == .movieShutterAngle {
                advertisedExposureOptions[property] = options
            }
            if !options.isEmpty, cameraControlOptions[property] != options {
                cacheAdvertisedControlOptions(options, property: property)
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
                guard cameraSession === session else { return false }
                applyCameraRead(.movieShutterMode, data)
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
        guard await waitForShutterModeConfirmation(session: session, expected: mode),
            cameraSession === session
        else {
            return
        }

        let property: PTPPropertyCode
        switch mode {
        case .speed: property = .movieShutterSpeed
        case .angle: property = .movieShutterAngle
        }
        let valueByteCount = 4
        advertisedExposureOptions.removeValue(forKey: property)
        var lastCount = 0

        for attempt in 1...3 {
            do {
                let options = try await session.controlOptions(
                    for: property, valueByteCount: valueByteCount)
                guard cameraSession === session else { return }
                lastCount = options.count
                if options.count > 1 {
                    cacheAdvertisedControlOptions(options, property: property)
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
    /// list the last known apertures (or the lens-derived fallback) are retained. Photo mode
    /// describes the standard aperture property — the movie enum is not authoritative there.
    private func refreshLensApertures(session: NativeCameraSession) async {
        do {
            let property: PTPPropertyCode =
                StillCapturePolicy.prefersPhotographyChrome(
                    selector: cameraPropertySnapshot.captureSelector)
                ? .fNumber : .movieFNumber
            let raw = try await session.describeCameraPropertyEnum(
                property, valueByteCount: 2)
            guard cameraSession === session else { return }
            let apertures = PTPCameraPropertyDecoders.apertureList(fromEnum: raw)
            advertisedExposureOptions[property] = apertures
            if !apertures.isEmpty {
                cacheAdvertisedApertures(apertures, property: property)
            }
        } catch {
            // Descriptor not supported or transiently unavailable — keep the last known list.
        }
    }

    /// Reads the camera's enumerated stills shutter speeds so the SHUTTER drum offers exactly
    /// what the body accepts — the set reshapes with the program, flash, and e-shutter state,
    /// and includes the Bulb/Time sentinels only where the mode allows them. Photography only,
    /// on the slow descriptor cadence; a failed or single-value read keeps the last list (the
    /// hardcoded ladder is the fallback of last resort). [verify-on-HW]
    private func refreshStillShutterOptions(session: NativeCameraSession) async {
        guard
            StillCapturePolicy.prefersPhotographyChrome(
                selector: cameraPropertySnapshot.captureSelector),
            session.supportsProperty(.stillShutterSpeed)
        else { return }
        do {
            let raw = try await session.describeCameraPropertyEnum(
                .stillShutterSpeed, valueByteCount: 4)
            let labels = raw.map { PTPCameraPropertyDecoders.stillShutterLabel($0) }
            if labels.count > 1, cameraControlOptions[.stillShutterSpeed] != labels {
                cameraControlOptions[.stillShutterSpeed] = labels
                logConnection("options stillShutter: \(labels.count) speeds")
            }
        } catch {
            // Not enumerable on this body or transiently unavailable — keep the fallback.
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

    /// Re-reads the tone descriptor of the active codec only, one read per pass. Each codec family
    /// keeps its own tone property, so a codec change can bring a property not read yet.
    private func refreshMovieToneOptions(session: NativeCameraSession) async {
        guard let raw = activeCodecMode?.raw,
            let property = NikonMovieToneCapability.toneProperty(forFileType: raw),
            session.supportsProperty(property),
            let values = try? await session.describeCameraPropertyEnum(property, valueByteCount: 1)
        else { return }
        let tones = NikonMovieToneCapability.tones(fromEnum: values)
        if !tones.isEmpty { cameraMovieTones[property] = tones }
    }

    /// Reads every card and the body's slot assignment, then caches the readout card: the stills
    /// card in photo mode, else the first usable card. The shots counter follows the stills card
    /// alone, and in photo mode a remote release is pointed at it when the body lets the host
    /// choose (ZT-04/ZT-05). On rejection or no card the last known value is retained.
    private func refreshStorageInfo(session: NativeCameraSession) async {
        let readout = await session.readCardSlots()
        guard let first = readout.cards.first else { return }
        let photo = cameraPropertySnapshot.captureSelector == .photo
        if readout.diagnosticSummary != lastCardSlotDiagnostic {
            lastCardSlotDiagnostic = readout.diagnosticSummary
            connectionLogger.info(
                "card slots \(readout.diagnosticSummary, privacy: .public)")
        }
        if photo, await session.alignActiveSlotToStillsCard(readout) {
            connectionLogger.info("active slot pointed at stills slot")
        }
        lastKnownStorage = (photo ? readout.stillsCard?.info : nil) ?? first.info
        cameraPropertySnapshot = cameraPropertySnapshot.applyingCardSlots(readout)
        reportedPropertySnapshot = reportedPropertySnapshot.applyingCardSlots(readout)
        publishCameraDisplayState()
    }

    /// Computes the current `MediaStatus` from cached storage + the camera's codec/resolution/fps.
    /// Returns nil when storage isn't known yet.
    private func currentMediaStatus() -> MediaStatus? {
        lastKnownStorage.flatMap {
            MediaStatus(
                storage: $0, codec: cameraPropertySnapshot.fileType,
                resolution: cameraPropertySnapshot.resolution, frameRate: cameraPropertySnapshot.fps
            )
        }
    }

    /// Publishes property snapshot → monitor readouts, including ZR RAW `[FX]` / `[DX]` tags on the
    /// resolution/frame-rate bar (shared policy with Android).
    private func publishCameraDisplayState(mediaStatus: MediaStatus? = nil) {
        // With no camera to read, the baseline is the blank state rather than whatever was last
        // published: `applyingCameraProperties` falls back to the *existing* value on every branch,
        // so an empty snapshot over a populated state leaves the old readings standing.
        let baseline = hasCameraControl ? cameraState : CameraDisplayState.blank
        var next = baseline.applyingCameraProperties(
            cameraPropertySnapshot,
            mediaStatus: mediaStatus ?? currentMediaStatus(),
            // Which side's white balance the WB tile means — the movie and stills modes are
            // separate camera settings that decode through the same table.
            photography: isPhotographyMode)
        let labeled = NikonZRRawCropPresentation.label(
            baseLabel: next.resolutionFrameRate,
            rawScreenSize: cameraPropertySnapshot.rawScreenSize,
            currentCodec: cameraPropertySnapshot.fileType,
            isNikonZR: isConnectedNikonZR)
        if labeled != next.resolutionFrameRate {
            next = next.updating(resolutionFrameRate: labeled)
        }
        // Whole-value assignment on purpose: `@Observable` skips an equal `CameraDisplayState`, so
        // an unchanged poll notifies nothing. An in-place edit of `cameraState` would notify always.
        cameraState = next
        broadcastRelayState()
        // Every camera property read lands here, so the seam's snapshot follows the camera.
        refreshCommonControlFacts()
    }

    func cycleDisplayMode() { operatorSession.cycle() }

    /// Jump straight to a display mode (used by the feed swipe: down → clean, up → live).
    func setDisplayMode(_ mode: MonitorDisplayMode) { operatorSession.select(mode) }

    /// The DISP modes this source offers, in order. Command is a camera-control dashboard: a
    /// photography body (its dashboard is movie-shaped) or a picture-only source does not offer it.
    var displayModes: [MonitorDisplayMode] {
        isPhotographyMode || !monitorAvailability.cameraControls
            ? [.live, .clean] : [.live, .clean, .command]
    }

    func toggleInterfaceLock() {
        interfaceLocked.toggle()
    }

    func toggleFocusPointLock() {
        guard !interfaceLocked else { return }
        focusPointLocked.toggle()
    }

    /// Reorders a command-grid tile to a slot of the visible grid (drag to reorder); a hidden
    /// tile keeps its place. Persisted via `didSet`.
    func moveCommandTile(_ kind: CommandTileKind, to index: Int) {
        let hidden = Set(commandGridOrder).subtracting(visibleCommandGridOrder)
        let next = NikonCommandGridOrder.moving(
            kind, to: index, in: commandGridOrder, hidden: hidden)
        if next != commandGridOrder { commandGridOrder = next }
    }

    /// Toggles whether a tool keeps rendering in clean view (DISP 2).
    func toggleCleanViewPin(_ tool: MonitorAssistTool) {
        assist.toggleCleanViewPin(tool.selection)
    }

    /// Opens the Edit view on `mode`: the monitor itself, with an eye badge on every chrome
    /// element the mode owns. Leaves Settings so the operator sees the real thing.
    func beginChromeEditing(_ mode: MonitorDisplayMode) {
        activePanel = nil
        operatorSession.beginEditing(mode)
    }

    /// Done returns to Display settings, where the operator came from.
    func endChromeEditing() {
        operatorSession.finishEditing()
        if shell.cover == .settings { activePanel = .settings }
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
            // (`.focused` would render the AF box green too; see `nikonFocusAreas`).
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
        // A watcher without the control token cannot move focus — its tap is fully inert
        // (`applyFocusPoint` drops it), so the confirming haptic must not fire either (field
        // report: the buzz promised a move the relay never sent). With the token the tap
        // forwards and the haptic stands.
        if videoSource == .relay, !relayHoldsControl { return }
        guard feedSize.width > 0, feedSize.height > 0 else { return }
        // The camera's coordinate space: the latest live-view header, then the last one the
        // camera reported (which outlives a switch to a source that carries no header). Before
        // either, a tap has no camera point; only the SIMULATED demo assumes one (A1-56).
        guard
            let coordinateWidth = liveViewFocus?.coordinateWidth
                ?? lastFocusCoordinateSpace?.width ?? (isDemoSession ? 1000 : nil)
        else {
            showMonitorNotice("Focus point waits for the camera's live view.")
            return
        }
        // Light tap confirming the AF point moved; after the guards so refused taps stay silent.
        if preferences.hapticsEnabled { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        // What the operator touched is the PRESENTED picture, which is not the whole frame: the
        // raster carries the de-squeeze as a centred scale (`LiveFrameRaster.feedScale`), so an
        // anamorphic setup paints into a narrower sub-rect with dead margins either side.
        // Normalising against the frame put the camera coordinate off by the squeeze — the same
        // error `liveFocusBoxRect` used to draw with. Off-picture taps clamp to the edge.
        let presented = desqueezedRect(
            CGRect(origin: .zero, size: feedSize), liveDesqueeze)
        // A mirrored feed is a mirrored tap: what the operator touched on the left of the picture
        // is on the camera's right. Undo the flip here rather than anywhere downstream — the
        // camera's coordinate space never mirrors, only the monitor does.
        let cameraPoint = LiveFeedFocusGesture.cameraPoint(
            CGPoint(x: point.x - presented.minX, y: point.y - presented.minY),
            in: presented.size, mirrored: liveFeedMirrored,
            flippedVertically: liveFeedMirroredVertically)
        let normalizedX = cameraPoint.x
        let normalizedY = cameraPoint.y
        let coordinateHeight =
            liveViewFocus?.coordinateHeight ?? lastFocusCoordinateSpace?.height
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
    /// A watcher sees the broadcaster's focus box ride in with the frames, but may only ACT on
    /// it while holding control — without control the key would sit there doing nothing.
    var isFocusResetAvailable: Bool {
        if videoSource == .relay, !relayHoldsControl { return false }
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
        if PTPCameraPropertyDecoders.isSubjectTrackingArea(focusArea) { return true }
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
            // Same rule as a tap: the recenter sequence owns the channel next, not a retrying
            // focus drive. (The plain-recenter path below gets this via `applyFocusPoint`.)
            cancelManualFocusDrive()
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

    /// Applies an AF point at the given camera-space coordinate: in the demo it drops the on-screen
    /// box; on a live camera it queues a `ChangeAfArea` for the next safe point.
    private func applyFocusPoint(
        cameraX: Int, cameraY: Int, coordinateWidth: Int, coordinateHeight: Int
    ) {
        applyFocusPoint(
            cameraX: cameraX, cameraY: cameraY, coordinateWidth: coordinateWidth,
            coordinateHeight: coordinateHeight, admission: nil)
    }

    private func applyFocusPoint(
        cameraX: Int, cameraY: Int, coordinateWidth: Int, coordinateHeight: Int,
        admission: NikonCommandAdmission?
    ) {
        guard admitsCameraCommand(admission) else { return }
        // The tap wins over the dial: drop any in-flight/queued focus drive so `ChangeAfArea`
        // gets the command channel now instead of behind a retrying drive.
        if videoSource == .relay {
            guard relayHoldsControl else { return }
            relayClient?.send(
                command: .focusPoint(
                    cameraX: cameraX, cameraY: cameraY, coordinateWidth: coordinateWidth,
                    coordinateHeight: coordinateHeight))
            return
        }
        guard !relayControlSurrendered else { return }
        cancelManualFocusDrive()
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
        pendingFocusPoint = (UInt32(max(0, cameraX)), UInt32(max(0, cameraY)), admission)
        // No optimistic box here on purpose. An app-drawn rectangle looks like the real AF box and
        // behaves like nothing — it cannot track, cannot show an eye, cannot go green — so it
        // implies the camera is doing work it isn't. The header pull reports the body's real boxes
        // on any picture source, so the honest thing is to wait the one tick for them.
    }

    func toggleRecording() { toggleRecording(admission: nil) }

    /// The surface's record rules for a press that does not come through its own button: a
    /// remote trigger or a relayed command (A1-24, A1-25). No record under the interface lock,
    /// while control is surrendered, or in photo mode.
    private var admitsRecordPress: Bool {
        !interfaceLocked && !relayControlSurrendered && !isPhotographyMode
    }

    private func toggleRecording(admission: NikonCommandAdmission?) {
        guard admitsCameraCommand(admission) else { return }
        guard admitsRecordPress else { return }
        // Who confirms, and whether the owned-session pre-flight applies at all, is one shared
        // rule — see `MonitorDataAvailability.recordPress`. Both answers turn on facts this
        // method used to ignore: that a watcher has no session of its own, and that a relayed
        // command was already confirmed by the operator who pressed the button.
        switch monitorAvailability.recordPress(
            confirmationEnabled: preferences.recordConfirmationEnabled,
            isRelayedCommand: admission != nil,
            liveViewReady: isDemoSession || (cameraSession != nil && isMonitorPresented))
        {
        // The press resolves to an explicit start or stop from what the operator sees now; that
        // target is what runs, confirmed or not.
        case .confirm:
            pendingRecordConfirmation = !isRecording
        case .run:
            executeRecord(start: !isRecording, admission: admission)
        case .needsLiveView:
            showMonitorNotice("Start live view before recording.")
        }
    }

    // MARK: - Still capture (photography mode)

    /// Whether the current shutter press latched a continuous burst that finger-up must end.
    @ObservationIgnored private var shutterPressLatchedBurst = false
    /// Frames chained in the current hold — a hard cap backstops a finger-up the system
    /// swallowed (gesture-gate timeouts strand the latch otherwise).
    @ObservationIgnored private var chainedBurstFrames = 0
    /// Whether the remote-mode bracket is open for the current burst hold.
    @ObservationIgnored private var remoteModeHeldForBurst = false

    /// Closes the burst's remote-mode bracket, restoring the body's own controls.
    private func exitBurstRemoteModeIfNeeded(session: NativeCameraSession) async {
        guard remoteModeHeldForBurst else { return }
        remoteModeHeldForBurst = false
        try? await session.changeCameraMode(remote: false)
    }

    /// App-side self-timer: countdown seconds a shutter press waits before firing (0 = off).
    /// The countdown is the app's — a remote release never runs the body's own self-timer.
    var photoTimerDelaySeconds = 0
    /// Releases fired back-to-back once the app countdown hits zero (the body's own shot
    /// count is menu-only, so the app covers it).
    var photoTimerShotCount = 1
    /// Seconds left in a running countdown (nil when idle); the shutter core renders it.
    private(set) var stillTimerRemaining: Int?
    @ObservationIgnored private var stillTimerTask: Task<Void, Never>?
    /// Tick counter for the EV meter's per-tick indicator read (see `pollNextCameraProperty`).
    @ObservationIgnored private var evFastPollTick = 0
    /// Rotates camera-owned auto-exposure readouts (see `pollNextCameraProperty`).
    @ObservationIgnored private var autoExposurePollTick = 0

    /// The Timer tab's display value ("Off" / "5s").
    var photoTimerLabel: String {
        photoTimerDelaySeconds > 0 ? "\(photoTimerDelaySeconds)s" : "Off"
    }

    func setPhotoTimer(label: String) {
        let seconds = Int(label.hasSuffix("s") ? String(label.dropLast()) : label) ?? 0
        // The body's own timer owns the release while engaged — the app timer stays off.
        guard
            seconds == 0
                || cameraPropertySnapshot.stillCaptureMode != StillDriveMode.selfTimer.label
        else { return }
        photoTimerDelaySeconds = seconds
        if photoTimerDelaySeconds == 0 { cancelStillTimer() }
    }

    /// Photo DRIVE tab gating: the two timers are mutually exclusive, and an engaged body
    /// timer owns the release mode. States derive from the polled snapshot, so a change made
    /// on the camera itself flows straight into which tabs are live — the camera stays ground
    /// truth.
    func pickerModeDisabled(_ picker: CameraPicker, mode: Int) -> Bool {
        if picker == .stillISO {
            // Mode-aware: the full-auto programs own sensitivity — Manual grays out there.
            return mode == 1 && !stillAllowsManualISO
        }
        if picker == .stillMode {
            // A bank's inner program is settable only while that bank is active.
            return mode == 1 && !["U1", "U2", "U3"].contains(commandExposureMode)
        }
        guard picker == .stillDrive else { return false }
        let builtInOn =
            cameraPropertySnapshot.stillCaptureMode == StillDriveMode.selfTimer.label
        switch mode {
        case 0, 2: return builtInOn
        case 1: return photoTimerDelaySeconds > 0
        default: return false
        }
    }

    /// Steps the timers' shared shot count (1…9); the stepper renders in both timer tabs.
    func adjustPhotoTimerShots(by delta: Int) {
        photoTimerShotCount = min(9, max(1, photoTimerShotCount + delta))
    }

    /// The drive that was active before the Built-in timer engaged, restored on Off.
    @ObservationIgnored private var driveBeforeBuiltInTimer: String?

    /// Engages the body's own self-timer release mode. Its delay and shot count come from the
    /// camera menu — no remote property exposes them — and the countdown runs only for presses
    /// of the physical shutter; command releases still fire immediately.
    func setBuiltInTimer(on: Bool) {
        guard photoTimerDelaySeconds == 0 || !on else { return }
        let timerLabel = StillDriveMode.selfTimer.label
        if on {
            if cameraPropertySnapshot.stillCaptureMode != timerLabel {
                driveBeforeBuiltInTimer = cameraPropertySnapshot.stillCaptureMode
            }
            applyPickerValue(timerLabel, for: .stillDrive)
        } else {
            guard cameraPropertySnapshot.stillCaptureMode == timerLabel else { return }
            applyPickerValue(
                driveBeforeBuiltInTimer ?? StillDriveMode.single.label, for: .stillDrive)
            driveBeforeBuiltInTimer = nil
        }
    }

    private func cancelStillTimer() {
        stillTimerTask?.cancel()
        stillTimerTask = nil
        stillTimerRemaining = nil
        StillTimerBeeper.shared.end()
    }

    /// Runs the armed countdown on the shutter, ticking once a second, then fires the
    /// configured number of releases back-to-back. A press during the countdown or the shot
    /// run cancels the rest.
    private func startStillTimer() {
        stillTimerRemaining = photoTimerDelaySeconds
        OperatorSettingsHaptics.selection(enabled: preferences.hapticsEnabled)
        StillTimerBeeper.shared.begin()
        StillTimerBeeper.shared.playTick()
        stillTimerTask = Task { [weak self] in
            while let remaining = self?.stillTimerRemaining, remaining > 0, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                guard let self else { return }
                self.stillTimerRemaining = remaining - 1
                OperatorSettingsHaptics.selection(enabled: self.preferences.hapticsEnabled)
                if remaining - 1 > 0 { StillTimerBeeper.shared.playTick() }
            }
            guard let self, !Task.isCancelled, self.stillTimerRemaining == 0 else { return }
            self.stillTimerRemaining = nil
            StillTimerBeeper.shared.playFire()
            StillTimerBeeper.shared.end()
            await self.fireTimerShots()
            self.stillTimerTask = nil
        }
    }

    /// The post-countdown release run: each shot waits out the previous one's completion.
    private func fireTimerShots() async {
        let count = max(1, photoTimerShotCount)
        for index in 0..<count {
            if index > 0 {
                var waited = 0.0
                while isStillCapturing, waited < 20, !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(150))
                    waited += 0.15
                }
                guard !isStillCapturing, !Task.isCancelled else { return }
            }
            captureStill()
        }
    }

    /// Countdown feedback for the app self-timer: short generated tones played through the
    /// `.playback` audio category, so they stay audible through the ring/silent switch and
    /// Do Not Disturb — the same way the body's own timer beeper behaves. The session is
    /// active only for the countdown and mixes with other audio rather than interrupting
    /// it. [verify-on-HW: interplay with the BT-shutter volume observer]
    @MainActor
    final class StillTimerBeeper {
        static let shared = StillTimerBeeper()
        private let tick: AVAudioPlayer?
        private let fire: AVAudioPlayer?

        private init() {
            tick = try? AVAudioPlayer(data: Self.toneWAV(frequency: 1_000, seconds: 0.07))
            fire = try? AVAudioPlayer(data: Self.toneWAV(frequency: 1_570, seconds: 0.22))
            tick?.prepareToPlay()
            fire?.prepareToPlay()
        }

        func begin() {
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.playback, options: [.mixWithOthers])
            try? session.setActive(true)
        }

        func playTick() {
            tick?.currentTime = 0
            tick?.play()
        }

        func playFire() {
            fire?.currentTime = 0
            fire?.play()
        }

        /// Gives the audio session back once the release tone has finished sounding.
        func end() {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(400))
                try? AVAudioSession.sharedInstance().setActive(
                    false, options: [.notifyOthersOnDeactivation])
            }
        }

        /// A short faded sine tone as an in-memory 16-bit mono WAV — no bundled asset.
        private static func toneWAV(
            frequency: Double, seconds: Double, amplitude: Double = 0.85
        ) -> Data {
            let rate = 44_100.0
            let count = Int(rate * seconds)
            var data = Data(capacity: 44 + count * 2)
            func append32(_ value: UInt32) {
                withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
            }
            func append16(_ value: UInt16) {
                withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
            }
            data.append(contentsOf: Array("RIFF".utf8))
            append32(UInt32(36 + count * 2))
            data.append(contentsOf: Array("WAVE".utf8))
            data.append(contentsOf: Array("fmt ".utf8))
            append32(16)
            append16(1)
            append16(1)
            append32(UInt32(rate))
            append32(UInt32(rate) * 2)
            append16(2)
            append16(16)
            data.append(contentsOf: Array("data".utf8))
            append32(UInt32(count * 2))
            // A few-ms fade at each end keeps the tone click-free.
            let fade = min(220, count / 4)
            for index in 0..<count {
                let envelope = min(
                    1, min(Double(index) / Double(fade), Double(count - index) / Double(fade)))
                let sample = sin(2 * .pi * frequency * Double(index) / rate) * amplitude * envelope
                append16(UInt16(bitPattern: Int16(sample * 32_767)))
            }
            return data
        }
    }

    /// Finger-down on the shutter control. Single/timer presses fire one release (via
    /// `captureStill`, which also ends an open bulb/time exposure); continuous drives latch
    /// the release until `shutterButtonReleased`. [verify-on-HW: continuous latch-until-
    /// terminate per body]
    func shutterButtonPressed() {
        if stillTimerTask != nil {
            // Second press cancels a running countdown (or the remaining shot run),
            // matching body behaviour.
            cancelStillTimer()
            return
        }
        if photoTimerDelaySeconds > 0, !isStillCapturing {
            startStillTimer()
            return
        }
        if photoTimerShotCount > 1, !isStillCapturing,
            cameraPropertySnapshot.stillCaptureMode == StillDriveMode.selfTimer.label
        {
            // Built-in timer engaged: its countdown never runs for command releases, so the
            // shots field drives a straight run from the press.
            stillTimerTask = Task { [weak self] in
                await self?.fireTimerShots()
                self?.stillTimerTask = nil
            }
            return
        }
        let wasCapturing = isStillCapturing
        captureStill()
        guard !wasCapturing, isStillCapturing, !isDemoSession else { return }
        let drive = cameraPropertySnapshot.stillCaptureMode.flatMap(StillDriveMode.mode(forLabel:))
        shutterPressLatchedBurst = drive?.isContinuous == true
        chainedBurstFrames = 0
    }

    /// Finger-up: ends a latched continuous burst — cancelling a chained-but-unsent release,
    /// or terminating whatever run is still in flight. No-op for single/timer/bulb presses.
    func shutterButtonReleased() {
        guard shutterPressLatchedBurst else { return }
        shutterPressLatchedBurst = false
        chainedBurstFrames = 0
        if pendingStillCapture {
            pendingStillCapture = false
            finishStillRelease(message: nil)
        } else if isStillCapturing {
            // Expected to be refused when the run already ended on its own — stay quiet.
            pendingStillTerminateQuiet = true
            pendingStillTerminate = true
        }
    }

    // MARK: - Instant playback (view-assist PLAY tool)

    /// One presented review: the captured still plus the shot's focus state and a settings
    /// line, both captured at present time so later polls can't rewrite them.
    struct InstantReviewState {
        let image: UIImage
        let focus: PTPLiveViewFocusInfo?
        let infoLine: String?
        /// False while the tiny embedded thumb stands in — the overlay blurs it behind a
        /// spinner, and the review duration doesn't start counting until the sharp image (the
        /// JPEG/HEIF itself, or a RAW's embedded preview) lands.
        var isFullResolution: Bool = true
        /// The captured still's object handle, so the overlay can rate the shot in place.
        /// Nil in the demo and for fallback presentations without a resolved object.
        var handle: UInt32? = nil
    }

    /// The freshest captured still, shown full-screen until the review duration elapses
    /// (or until tapped when the duration is ∞).
    private(set) var instantReview: InstantReviewState?
    @ObservationIgnored private var instantReviewDismissTask: Task<Void, Never>?
    @ObservationIgnored private var instantReviewFetchTask: Task<Void, Never>?
    /// The post-capture diff baseline (last known object handles per storage) plus the handles
    /// `ObjectAdded` announced since. Seeded outside the shutter path so the release itself never
    /// waits on enumeration; the rules are Core's (`NikonStillReview.swift`).
    @ObservationIgnored private let stillReviewTracker = NikonStillReviewObjectTracker()
    /// The focus box frozen at capture time (shutter press / body-capture detect). The review's
    /// focus overlay uses THIS, not live `liveViewFocus` — incoming frames overwrite the live
    /// value during the post-shutter fetch window, so a box moved before the preview lands would
    /// otherwise drag the reviewed shot's reticle with it.
    @ObservationIgnored private var capturedFocusForReview: PTPLiveViewFocusInfo?

    func presentInstantReview(
        _ image: UIImage, isFullResolution: Bool = true, handle: UInt32? = nil
    ) {
        let snap = cameraPropertySnapshot
        let info = [
            snap.iso.map { "ISO \($0)" },
            snap.shutterSpeed,
            snap.fNumber,
            snap.compression,
        ]
        .compactMap { $0 }
        .joined(separator: "   ")
        withAnimation(.easeInOut(duration: 0.18)) {
            instantReview = InstantReviewState(
                image: image,
                focus: capturedFocusForReview ?? liveViewFocus,
                infoLine: info.isEmpty ? nil : info,
                isFullResolution: isFullResolution,
                handle: handle)
        }
        // A stand-in thumb doesn't start the clock — the operator gets the full duration
        // with the real image; the countdown begins on upgrade (or its failure fallback).
        if isFullResolution { startInstantReviewCountdown() }
    }

    /// (Re)arms the auto-dismiss for the configured review duration; ∞ never arms.
    private func startInstantReviewCountdown() {
        instantReviewDismissTask?.cancel()
        let seconds = assistConfiguration.instantReviewSeconds
        guard seconds > 0 else { return }
        instantReviewDismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Double(seconds)))
            guard !Task.isCancelled else { return }
            self?.dismissInstantReview()
        }
    }

    func dismissInstantReview() {
        instantReviewDismissTask?.cancel()
        instantReviewDismissTask = nil
        // A dismissed review stops its image read so the shared channel is released.
        instantReviewFetchTask?.cancel()
        instantReviewFetchTask = nil
        capturedFocusForReview = nil
        withAnimation(.easeInOut(duration: 0.18)) { instantReview = nil }
    }

    /// Seeds the handle baseline so the first post-capture diff has something to diff against.
    /// Called from the photo bootstrap and when the PLAY tool switches on.
    func seedInstantReviewBaseline() {
        guard let session = cameraSession,
            StillCapturePolicy.prefersPhotographyChrome(
                selector: cameraPropertySnapshot.captureSelector),
            assist.instantReview
        else { return }
        let tracker = stillReviewTracker
        Task { await session.seedStillReviewBaseline(tracker: tracker) }
    }

    /// Notes the object handle an `ObjectAdded` event names, from either event channel, so the
    /// next review goes straight to the new object instead of diffing every card.
    private func noteStillReviewEvent(_ event: PTPEvent) {
        stillReviewTracker.note(event)
    }

    /// After a completed release with the PLAY tool on, overlay the just-captured frame: the
    /// tiny embedded thumb lands instantly, then the sharp image (the JPEG/HEIF itself, or a
    /// RAW-only shot's embedded preview) replaces it. Completion is per-run, never per-frame:
    /// a held burst schedules exactly one review, of its last frame, only after the finger
    /// lifts and the run ends. Every quality reviews: the shot's object is looked up within
    /// Core's window, so a slow card write (RAW+JPEG Fine* in M/P/A/S) still lands.
    /// [verify-on-HW: card write time per body and quality]
    private func scheduleInstantReview(session: NativeCameraSession) {
        guard assist.instantReview else { return }
        instantReviewFetchTask?.cancel()
        instantReviewFetchTask = Task { [weak self] in
            let deadline =
                ContinuousClock.now
                + .milliseconds(NikonStillReviewPolicy.objectWindowMilliseconds)
            while ContinuousClock.now < deadline {
                guard let self, !Task.isCancelled, self.cameraSession === session else { return }
                if await self.fetchAndPresentReview(session: session) { return }
                try? await Task.sleep(
                    for: .milliseconds(NikonStillReviewPolicy.objectPollIntervalMilliseconds))
            }
        }
    }

    /// One lookup and, once the shot's object is found, its review: the camera thumb (blurred)
    /// first, then the sharp image swapped over it. False only while the object is not on the
    /// card yet, so the caller retries.
    private func fetchAndPresentReview(session: NativeCameraSession) async -> Bool {
        guard let choice = await session.resolveStillReviewObject(tracker: stillReviewTracker)
        else { return false }
        var presentedThumb = false
        if let thumbData = try? await session.getThumb(handle: choice.handle),
            let thumb = UIImage(data: thumbData), !Task.isCancelled
        {
            presentInstantReview(thumb, isFullResolution: false, handle: choice.handle)
            presentedThumb = true
        }
        // The camera thumb is instant but tiny: read the sharp image and swap it over the
        // presented review (a dismissal cancels this task, which stops the read). If the read
        // fails while the review is still up, the countdown starts on the thumb so a timed
        // review can never hang on the blurred stand-in.
        let sharp = await sharpReviewImage(session: session, choice: choice)
        guard !Task.isCancelled, cameraSession === session else { return true }
        if let sharp {
            if presentedThumb {
                upgradeInstantReview(sharp)
            } else {
                presentInstantReview(sharp, handle: choice.handle)
            }
        } else if instantReview?.isFullResolution == false {
            startInstantReviewCountdown()
        }
        return true
    }

    /// The review's sharp image, decoded display-sized: the review never shows more pixels
    /// than the screen, and a full 45 MP decode allocates surfaces the device may refuse.
    private func sharpReviewImage(
        session: NativeCameraSession, choice: NikonStillReviewSelection.Choice
    ) async -> UIImage? {
        guard let data = await session.stillReviewImageData(for: choice) else { return nil }
        return await MediaCellImageLoader.shared.downsampled(data: data, maxPixelSize: 4096)
    }

    /// Swaps the streamed full-resolution image over the presented review, keeping the
    /// captured focus state and settings line, and starts the review countdown — the
    /// animated flag change drives the overlay's blur-to-sharp blend. No-op once dismissed.
    private func upgradeInstantReview(_ image: UIImage) {
        guard let current = instantReview else { return }
        withAnimation(.easeInOut(duration: 0.4)) {
            instantReview = InstantReviewState(
                image: image, focus: current.focus, infoLine: current.infoLine,
                isFullResolution: true, handle: current.handle)
        }
        startInstantReviewCountdown()
    }

    // MARK: - Manual focus drive (focus-by-wire scrub)

    /// Operator toggle for the live-view focus scrub strip (persisted, default off) — flipped from
    /// the FOCUS popup, in video and photo mode alike.
    var mfDriveScrubEnabled: Bool = PreferencesStore.loadMFScrubEnabled() {
        didSet { PreferencesStore.saveMFScrubEnabled(mfDriveScrubEnabled) }
    }

    /// The live-view focus scrub drives the lens focus-by-wire motor with a remote drive. The
    /// camera permits that ONLY in an AF focus mode — in MF the lens ring has exclusive control
    /// and the body refuses every drive with Invalid_Status ("the focus mode is MF"). So the
    /// strip shows in AF modes (AF-S / AF-C / AF-F / AF-A), NOT MF — the app scrub acts as a
    /// manual-focus override, the way the lens ring overrides during AF. Hidden while a panel is
    /// up so picking a mode in the FOCUS popup can't mount an overlay under the operator's finger.
    /// Both chromes: a focus pull is a video move as much as a stills one, so the only gate is the
    /// operator's own toggle (default off) plus the focus mode.
    /// [verify-on-HW: whether continuous AF fights the drive in AF-C vs AF-S]
    /// Eligibility for the on-feed focus dial in the body's current focus mode.
    var mfDriveEligibility: MFDriveEligibility {
        // Both chromes show the scrub, so resolve against the active side's focus mode.
        MFDriveEligibility.resolve(
            focusMode: cameraPropertySnapshot.activeFocusMode(photography: isPhotographyMode))
    }

    var showsMFDriveScrub: Bool {
        guard mfDriveScrubEnabled, mfDriveEligibility != .unavailable else { return false }
        return isConnected && !isDemoSession && activePanel == nil
    }

    /// True while the dial is on screen but cannot drive — AF-F re-focuses continuously, so the
    /// dial is drawn dimmed and ignores gestures rather than accepting pulls that go nowhere.
    var mfDriveScrubIsInert: Bool { mfDriveEligibility == .blockedByContinuousAF }

    @ObservationIgnored private var mfDriveTask: Task<Void, Never>?
    /// Bumped by `cancelManualFocusDrive()` so a superseded drive can neither keep running nor
    /// clear the task slot its replacement now owns.
    @ObservationIgnored private var mfDriveRunID = 0
    /// Signed pulses awaiting dispatch (+ toward infinity, − toward near). Scrub gestures
    /// accumulate here; a single in-flight drive drains it so gesture speed never floods
    /// the command channel.
    @ObservationIgnored private var mfDrivePendingPulses = 0
    /// Travel-end feedback for the scrub UI: −1 near limit, +1 infinity limit, nil moving.
    private(set) var mfDriveAtEnd: Int?
    /// Net REQUESTED pulses since the dial was armed (+ toward infinity), advanced on the drag
    /// itself — NOT on the camera's per-drive acknowledgement, so the dial tracks the finger
    /// smoothly instead of stepping at the command round-trip rate. Clamped to the pinned travel
    /// ends. The camera exposes no absolute focus distance for AF lenses, so the dial shows this
    /// as a RELATIVE position: once a full near↔infinity sweep pins both ends,
    /// `mfDriveDialFraction` reads 0…1.
    private(set) var mfDriveNetPulses = 0
    /// Pinned pulse offsets of the two travel ends once observed (near, infinity). Nil until hit.
    @ObservationIgnored private var mfDriveNearPulses: Int?
    @ObservationIgnored private var mfDriveInfinityPulses: Int?
    private(set) var mfDriveLastCode: UInt16 = 0
    /// True once the operator drove focus with the dial and hasn't tapped to AF since — the still
    /// release then fires WITHOUT AF so the manually-set focus is preserved.
    @ObservationIgnored private var focusManuallyDialed = false

    /// Relative focus position 0 (near) … 1 (infinity) once both ends have been reached; nil while
    /// the travel isn't yet calibrated (the dial then just scrolls with motion).
    var mfDriveDialFraction: Double? {
        guard let near = mfDriveNearPulses, let far = mfDriveInfinityPulses, far > near else {
            return nil
        }
        return min(1, max(0, Double(mfDriveNetPulses - near) / Double(far - near)))
    }

    /// Re-arms the dial's relative position (call when the strip appears / lens or mode changes).
    func resetMFDriveDial() {
        mfDriveNetPulses = 0
        mfDriveNearPulses = nil
        mfDriveInfinityPulses = nil
        mfDriveAtEnd = nil
    }

    /// Drops an in-flight focus drive and everything queued behind it, freeing the camera command
    /// channel immediately. An AF-point tap is interactive and must win: queueing it behind a
    /// retrying drive is what made tap-to-focus look dead until a shutter release. Also runs on
    /// teardown so no exit path leaves focus commands owned by a dead session.
    func cancelManualFocusDrive() {
        mfDrivePendingPulses = 0
        mfDriveTask?.cancel()
        mfDriveTask = nil
        // A cancelled drive can still be parked in a non-cancellable transaction; its `defer` must
        // not clear a task that a later drag has since installed.
        mfDriveRunID &+= 1
    }

    /// Queues a relative manual-focus drive (signed pulses, + toward infinity). Coalesces
    /// while a drive is in flight. A refused drive is treated as transient — the stepping-motor
    /// lens initializing after a mode change and momentary autofocus activity both refuse for a
    /// beat — so the pulses requeue and retry; only a sustained refusal surfaces one message,
    /// and the strip is never hidden. [verify-on-HW: per-lens pulse feel + which codes a given
    /// lens answers]
    func driveManualFocus(pulses: Int) {
        guard pulses != 0, !isDemoSession, cameraSession != nil else { return }
        mfDrivePendingPulses += pulses
        // Focus is now operator-set; the next release preserves it (no AF) until a tap-to-AF.
        focusManuallyDialed = true
        // Advance the dial position on the DRAG, not the ack — the drum follows the finger
        // smoothly instead of stepping at the command round-trip rate. Clamp to pinned ends so
        // it can't scroll past a known travel limit.
        mfDriveNetPulses += pulses
        if let near = mfDriveNearPulses { mfDriveNetPulses = max(mfDriveNetPulses, near) }
        if let far = mfDriveInfinityPulses { mfDriveNetPulses = min(mfDriveNetPulses, far) }
        mfDriveAtEnd = nil
        guard mfDriveTask == nil else { return }
        let runID = mfDriveRunID
        mfDriveTask = Task { [weak self] in
            defer {
                // Only clear the slot if a `cancelManualFocusDrive()` hasn't already handed it to
                // a newer drive — otherwise two drives end up sharing the command channel.
                if let self, self.mfDriveRunID == runID { self.mfDriveTask = nil }
            }
            // Wall clock, not an iteration count: one drive already costs an activation plus a
            // bounded readiness poll, so a count-based budget silently owns the command channel
            // for tens of seconds — and while it does, the body answers `ChangeAfArea` busy too.
            var refusalRunStartedAt: Date?
            while let self, let session = self.cameraSession,
                self.mfDrivePendingPulses != 0, !Task.isCancelled, self.mfDriveRunID == runID
            {
                let pending = self.mfDrivePendingPulses
                self.mfDrivePendingPulses = 0
                let outcome = await session.mfDrive(
                    towardNear: pending < 0,
                    pulses: UInt32(min(abs(pending), 32767))
                )
                switch outcome {
                case .complete, .stepTooSmall:
                    // Position already advanced optimistically on the drag (above).
                    refusalRunStartedAt = nil
                case .endOfTravel:
                    // Pin this end at the current (optimistic) position so the relative position
                    // calibrates and the dial clamps here on further drives toward it.
                    if pending < 0 {
                        self.mfDriveNearPulses = self.mfDriveNetPulses
                        self.mfDriveAtEnd = -1
                    } else {
                        self.mfDriveInfinityPulses = self.mfDriveNetPulses
                        self.mfDriveAtEnd = 1
                    }
                    self.mfDrivePendingPulses = 0
                    refusalRunStartedAt = nil
                case .refused(let code):
                    // A refusal is transient while AF is momentarily driving (access-denied) or
                    // the lens is still initialising (busy): requeue and retry. A sustained
                    // refusal is a real state block — Invalid_Status means either an unusable
                    // lens or that the focus mode slipped back to MF (the body refuses a remote
                    // drive in MF). Surface one message and leave the strip up to retry.
                    self.mfDriveLastCode = code.rawValue
                    let startedAt = refusalRunStartedAt ?? Date()
                    refusalRunStartedAt = startedAt
                    if MFDriveChannelBudget.shouldRetryRefusal(
                        elapsedSeconds: Date().timeIntervalSince(startedAt))
                    {
                        // Back off FIRST, requeue after: a tap that cancels during the backoff
                        // must not leave this run's pulses behind for the drive that replaces it.
                        try? await Task.sleep(
                            for: .seconds(MFDriveChannelBudget.refusalRetryIntervalSeconds))
                        guard !Task.isCancelled, self.mfDriveRunID == runID else { continue }
                        self.mfDrivePendingPulses += pending
                        continue
                    }
                    // Give the channel back: the next gesture retries from a clean slate, and a
                    // tap-to-focus queued behind this run goes through immediately.
                    self.mfDrivePendingPulses = 0
                    refusalRunStartedAt = nil
                    AppDiagnostics.shared.record(.mfDriveRefused)
                    self.connectionMessage =
                        code.rawValue == PTPResponseCode.invalidStatus.rawValue
                        ? "Can't drive focus in MF — set the camera to an AF focus mode to scrub focus from the app."
                        : "Couldn't drive focus just now — try again (\(String(format: "0x%04X", code.rawValue)))."
                }
            }
        }
    }

    /// Rates the reviewed shot in place (0–5 stars) — writes straight to the captured
    /// object so the culling decision is done before the next frame. Mirrors only a
    /// confirmed write into the index. [verify-on-HW]
    func rateInstantReview(stars: Int) async -> Bool {
        guard let handle = instantReview?.handle, let session = cameraSession else {
            return false
        }
        AppDiagnostics.shared.record(.ratingWriteAttempted)
        do {
            try await performRatingWrite(
                session: session, handle: handle,
                value: StillCapturePolicy.ratingValue(forStars: stars))
        } catch {
            _ = refusalOutcome(error)  // records the refusal breadcrumb with its code
            return false
        }
        // Instant playback holds a raw object handle, not a MediaClip — resolve the JPEG's
        // filename so the confirmed write mirrors into the media index (the review already
        // fetched this ObjectInfo once; a second lookup here is off the hot capture path).
        let confirmed = await confirmedStars(session: session, handle: handle, requested: stars)
        if let info = try? await session.getObjectInfo(handle: handle) {
            mirrorRatingIntoIndex(
                cameraID: mediaBucketID, filename: info.filename, stars: confirmed)
        }
        AppDiagnostics.shared.record(.ratingWriteConfirmed)
        return true
    }

    // MARK: - Media delete + star rating
    // (The rating step table lives in shared core `StillCapturePolicy` — both shells map
    // stars ↔ raw property values through the same code.)

    /// Everything one deletion will actually remove, and why — so the confirm copy and the
    /// delete run from the same expansion and can never disagree.
    struct DeletionPlan {
        /// Requested clips plus every companion object of the same shots, deduplicated.
        let targets: [MediaClip]
        /// RAW siblings pulled in behind requested JPEGs.
        let pairCount: Int
        /// Same-stem camera masters (R3D / NEV) pulled in behind requested proxies.
        let masterCount: Int
        /// Shots whose copy also lives on the other card (backup recording) — deleting the
        /// shot clears both cards.
        let backupCount: Int
    }

    /// Same-stem camera masters (`.R3D` / `.NEV`) on the same card as a playable proxy — the
    /// grid hides them behind the proxy, so deleting the proxy must take them along.
    private func linkedMasters(of clip: MediaClip) -> [MediaClip] {
        guard MediaClipFilename.isPlayableProxy(clip.filename) else { return [] }
        let stem = MediaClipFilename.stem(of: clip.filename)
        return mediaClips.filter {
            $0.id != clip.id && $0.cameraID == clip.cameraID && $0.storageID == clip.storageID
                && ["r3d", "nev"].contains($0.fileExtension)
                && MediaClipFilename.stem(of: $0.filename) == stem
        }
    }

    /// Delete is offered only where deletion removes something: a phone-only copy, or camera
    /// objects while the camera session is up (the same rule as `deleteMediaClips`' canRemove).
    /// ponytail: requested rows only; an offline camera shot's phone-only RAW sibling is not
    /// offered on its own.
    func canDeleteMedia(_ clips: [MediaClip]) -> Bool {
        let connected = cameraSession != nil || reviewCameraDelete != nil
        return clips.contains { $0.allLocations.isEmpty || connected }
    }

    /// Expands a deletion request to the full set of objects it honestly removes: each shot's
    /// RAW sibling and its hidden camera master. Backup copies ride on the shot's own row (the
    /// locations model folds both cards into one row), so they need no separate widening — they
    /// go when `deleteMediaClips` walks the row's `allLocations`.
    func deletionPlan(for clips: [MediaClip]) -> DeletionPlan {
        var byID: [String: MediaClip] = [:]
        var ordered: [MediaClip] = []
        var pairs = 0
        var masters = 0
        var backups = 0
        func insert(_ clip: MediaClip) -> Bool {
            guard byID[clip.id] == nil else { return false }
            byID[clip.id] = clip
            ordered.append(clip)
            if clip.allLocations.count > 1 { backups += 1 }
            return true
        }
        for clip in clips {
            var shot: [MediaClip] = [clip]
            if let raw = rawSibling(of: clip), byID[raw.id] == nil { shot.append(raw) }
            shot.append(contentsOf: linkedMasters(of: clip))
            for (index, piece) in shot.enumerated() where insert(piece) {
                if index > 0 {
                    if piece.isRawPhoto { pairs += 1 } else { masters += 1 }
                }
            }
        }
        return DeletionPlan(
            targets: ordered, pairCount: pairs, masterCount: masters, backupCount: backups)
    }

    /// Destructive-confirmation copy for a deletion, naming only what this request actually
    /// removes: still wording for stills, master wording for proxies with hidden masters, and
    /// the cross-card note only when backup copies really exist.
    func deletionConfirmMessage(for clips: [MediaClip]) -> String {
        deletionConfirmMessage(for: clips, plan: deletionPlan(for: clips))
    }

    func deletionConfirmMessage(for clips: [MediaClip], plan: DeletionPlan) -> String {
        var message: String
        if clips.count == 1, let only = clips.first {
            message =
                only.mediaKind == .photo
                ? "Delete this photo from the camera card?"
                : "Delete \(only.filename) from the camera card?"
        } else {
            message = "Delete \(clips.count) items from the camera card?"
        }
        if plan.pairCount > 0 {
            message += " Both the RAW and JPEG files of a pair are removed."
        }
        if plan.masterCount > 0 {
            message += " The camera master file is removed with its proxy."
        }
        if plan.backupCount > 0 {
            message += " The backup copies on the other card are removed too."
        }
        return message
    }

    /// Captures one immutable consequence set for playback. Gallery/photo callers keep their
    /// existing preparation policy; playback drains only its exact outgoing item first.
    func capturePlaybackMediaDeletion(
        _ clip: MediaClip,
        cleanup: @escaping @MainActor () async -> Bool,
        deleteLocation: ((MediaObjectHandle) async -> Bool)? = nil
    ) -> MonitorOperatorPlaybackDeletionRequest? {
        guard isConnected, mediaBrowserSource == .camera, clip.handle != nil,
            let owner = mediaLibrary,
            let current = mediaClips.first(where: { $0.id == clip.id }),
            NikonMediaLibraryAction.sameContent(clip, current)
        else { return nil }
        let plan = deletionPlan(for: [current])
        guard let action = captureMediaLibraryAction(plan.targets), action.sourceIsCurrent else {
            return nil
        }
        let authority = owner.captureDeletion(
            key: .init("playback-deletion"),
            ifCurrent: { [weak self] in
                self?.isConnected == true && self?.mediaBrowserSource == .camera
                    && action.sourceIsCurrent
            })
        let copy = MonitorPlaybackDeletionConfirmation(
            title: "Delete clip from camera?",
            message: deletionConfirmMessage(for: [current], plan: plan))
        return .init(
            confirmation: copy, authority: authority,
            perform: { [weak self] in
                guard let self, authority.isCurrent, self.mediaLibrary === owner,
                    self.playbackDeletionPlanIsCurrent(plan, requested: current)
                else { return }
                guard await cleanup(), !Task.isCancelled, authority.isCurrent,
                    self.mediaLibrary === owner,
                    self.playbackDeletionPlanIsCurrent(plan, requested: current)
                else { return }
                _ = await self.deleteMediaClips(
                    [current], deleteLocation: deleteLocation,
                    admitted: authority, frozenPlan: plan)
            })
    }

    private func playbackDeletionPlanIsCurrent(_ captured: DeletionPlan, requested: MediaClip)
        -> Bool
    {
        guard let current = mediaClips.first(where: { $0.id == requested.id }),
            NikonMediaLibraryAction.sameContent(requested, current)
        else { return false }
        let actual = deletionPlan(for: [current])
        return actual.pairCount == captured.pairCount && actual.masterCount == captured.masterCount
            && actual.backupCount == captured.backupCount
            && actual.targets.count == captured.targets.count
            && zip(actual.targets, captured.targets).allSatisfy { current, old in
                current.id == old.id && current.allLocations == old.allLocations
                    && NikonMediaLibraryAction.sameContent(old, current)
            }
    }

    /// Deletes clips from the camera card (and any local copies). The request widens through
    /// `deletionPlan` — RAW siblings and hidden camera masters go with their shots, and each
    /// shot's own row deletes every card it lives on. Protected objects are refused by the body
    /// and stay listed. Returns the number of items actually removed. [verify-on-HW]
    func deleteMediaClips(_ clips: [MediaClip]) async -> Int {
        await deleteMediaClips(clips, deleteLocation: nil)
    }

    /// The shared library captures this before preparation; content and source are never rebound.
    func captureMediaDeletionAuthority(_ clips: [MediaClip])
        -> MonitorMediaLibraryDeletionAuthority?
    {
        guard let owner = mediaLibrary,
            let action = captureMediaLibraryAction(deletionPlan(for: clips).targets)
        else { return nil }
        return owner.captureDeletion(key: .init("catalog-deletion")) { action.sourceIsCurrent }
    }

    func deleteMediaClips(
        _ clips: [MediaClip], deleteLocation: ((MediaObjectHandle) async -> Bool)?,
        admitted authority: MonitorMediaLibraryDeletionAuthority? = nil,
        frozenPlan: DeletionPlan? = nil
    ) async -> Int {
        let targets = (frozenPlan ?? deletionPlan(for: clips)).targets
        let deleteLocation = deleteLocation ?? reviewCameraDelete
        let owner = mediaLibrary
        let producer = mediaProducer?.service
        let session = cameraSession
        let action = captureMediaLibraryAction(targets)
        let accepted = authority ?? captureMediaDeletionAuthority(clips)
        if let accepted { action?.admitDeletion(accepted) }
        let plan = targets.map {
            MonitorMediaDeletionTarget(
                value: $0, locations: $0.allLocations,
                canRemove: $0.allLocations.isEmpty || session != nil || deleteLocation != nil)
        }
        let port = MonitorMediaDeletionPort<MediaClip, MediaObjectHandle>(
            remove: { location in
                if let deleteLocation {
                    return await deleteLocation(location) ? .removed : .retained
                }
                guard let session else { return .unknown }
                return (try? await session.deleteObject(handle: location.handle)) != nil
                    ? .removed : .unknown
            },
            commit: { [weak self] clip, survivors in
                guard let self, action?.canMutate(clip) != false else { return false }
                if !survivors.isEmpty {
                    self.mediaClipStore.update(cameraID: clip.cameraID, filename: clip.filename) {
                        $0.storageLocations = survivors
                        $0.handle = survivors.first?.handle
                        $0.storageID = survivors.first?.storageID
                    }
                    return false
                }
                self.mediaClipStore.purgeClip(cameraID: clip.cameraID, filename: clip.filename)
                return true
            },
            finish: { [weak self] in
                guard let self, action?.isCurrent != false else { return }
                if let action { action.publish() } else { self.refreshMediaClips() }
                guard action?.isCurrent != false else { return }
                self.seedInstantReviewBaseline()
                if self.isConnected {
                    if let accepted {
                        await self.scheduleFetchClipsFromCamera(afterDeletion: accepted)
                    } else {
                        self.scheduleFetchClipsFromCamera()
                    }
                }
            })
        if let owner, let accepted {
            return await owner.deleteHostBatch(
                accepted, targets: plan, selectedCount: clips.count,
                preparation: .retireGallery, prepare: { producer?.cancelCatalog() }, port: port)
        }
        // A local-only caller has no browse lease. It uses the same ordered executor and source ACKs.
        producer?.cancelCatalog()
        defer { if action?.isCurrent != false { mediaDeletionProgress = nil } }
        return await MonitorMediaOrderedDeletion.run(
            plan, selectedCount: clips.count,
            ifCurrent: { action?.isCurrent != false }, port: port,
            progress: { [weak self] in
                self?.mediaDeletionProgress = $0
            })
    }

    /// Caches a still's EXIF orientation (1–8) on its index row — the camera's PTP thumbnails
    /// can be EXIF-stripped, so grid/filmstrip decodes need the full file's answer without
    /// re-fetching headers.
    func cacheEXIFOrientation(_ orientation: Int, for clip: MediaClip) {
        guard (1...8).contains(orientation), clip.exifOrientation != orientation else { return }
        mediaClipStore.update(cameraID: clip.cameraID, filename: clip.filename) {
            $0.exifOrientation = orientation
        }
        refreshMediaClips()
    }

    /// Learns a still's orientation from its on-disk bytes (a streamed full file always carries
    /// the header) and caches it once; a no-op for videos and already-resolved rows.
    func resolveEXIFOrientation(for clip: MediaClip, at url: URL) {
        guard clip.mediaKind == .photo, clip.exifOrientation == nil else { return }
        guard let orientation = MediaCellImageLoader.exifOrientation(atFile: url) else { return }
        cacheEXIFOrientation(orientation, for: clip)
    }

    /// The clip's star rating from the camera (0–5); nil when unreachable (offline or a
    /// local-only clip). Mirrors what it reads back into the index so the Favorites cache
    /// self-corrects against the body (truth) on viewer open — no per-cell round-trip needed.
    func mediaStarRating(for clip: MediaClip) async -> Int? {
        guard let handle = clip.handle, let session = cameraSession else { return nil }
        return await performCapturedMediaRating(for: clip) {
            guard let value = try? await session.objectRating(handle: handle) else { return nil }
            return StillCapturePolicy.stars(fromRatingValue: value)
        }
    }

    /// Writes a 0–5 star rating to the clip and confirms it with a readback; a RAW+JPEG pair
    /// writes both sides, tolerating the RAW side's refusal (RAW stills carry no rating
    /// property). Returns the outcome so the viewer can surface a refusal — with the body's raw
    /// response code — instead of a silent rollback. The index mirror lands ONLY on a confirmed
    /// write, so a refused write never leaves a Favorites ghost the card doesn't have. [verify-on-HW]
    func setMediaStarRating(_ stars: Int, for clip: MediaClip) async -> RatingWriteOutcome {
        await setMediaStarRating(stars, for: clip, action: captureMediaLibraryAction([clip]))
    }

    private func setMediaStarRating(
        _ stars: Int, for clip: MediaClip,
        action: NikonMediaLibraryAction?
    ) async -> RatingWriteOutcome {
        guard let handle = clip.handle, let session = cameraSession else { return .offline }
        AppDiagnostics.shared.record(.ratingWriteAttempted)
        let value = StillCapturePolicy.ratingValue(forStars: stars)
        do {
            try await performRatingWrite(session: session, handle: handle, value: value)
        } catch {
            return refusalOutcome(error)
        }
        if let raw = rawSibling(of: clip), let rawHandle = raw.handle {
            try? await performRatingWrite(session: session, handle: rawHandle, value: value)
        }
        // Confirm via readback and mirror ONLY the confirmed value onto the JPEG-side row.
        let confirmed = await confirmedStars(session: session, handle: handle, requested: stars)
        if let action {
            if action.canMutate(clip) {
                mediaClipStore.update(cameraID: clip.cameraID, filename: clip.filename) {
                    $0.starRating = confirmed
                    $0.isFavorite = confirmed >= 1
                }
                action.publish()
            }
        } else {
            mirrorRatingIntoIndex(
                cameraID: clip.cameraID, filename: clip.filename, stars: confirmed)
        }
        AppDiagnostics.shared.record(.ratingWriteConfirmed)
        return .confirmed(confirmed)
    }

    /// Mirrors a CONFIRMED camera star write (viewer or instant playback) into the media index:
    /// caches the star and derives the local favorite flag (`isFavorite = stars ≥ 1`), upserting
    /// a row if the clip isn't indexed yet. The body stays source of truth; this keeps the Media
    /// page's local Favorites filter — which reads the index, not the camera — in agreement.
    func mirrorRatingIntoIndex(cameraID: String, filename: String, stars: Int) {
        mediaClipStore.update(cameraID: cameraID, filename: filename) {
            $0.starRating = stars
            $0.isFavorite = stars >= 1
        }
        refreshMediaClips()
    }

    /// Outcome of a rating write so the UI explains a refusal (with the body's wire code) rather
    /// than rolling back silently.
    enum RatingWriteOutcome: Equatable {
        case confirmed(Int)
        case refused(code: UInt16, message: String)
        case offline
    }

    /// The single object-rating write against the body. Isolated so a future fix can bracket it
    /// with a state-sequencing pre/post hook — some bodies refuse the property write while a
    /// live-view/app-mode session holds a state that disallows it — without touching callers.
    private func performRatingWrite(
        session: NativeCameraSession, handle: UInt32, value: UInt16
    ) async throws {
        // ponytail: state-sequencing seam. If a refusal proves state-based, settle/prepare the
        // body here before the write (and restore after), keeping this the only site that changes.
        try await session.setObjectRating(handle: handle, value: value)
    }

    /// Reads the stored rating back so the index mirrors the body's confirmed value (the body
    /// rounds off-step values down); falls back to the requested count if the readback is unreachable.
    private func confirmedStars(
        session: NativeCameraSession, handle: UInt32, requested: Int
    ) async -> Int {
        guard let value = try? await session.objectRating(handle: handle) else { return requested }
        return StillCapturePolicy.stars(fromRatingValue: value)
    }

    /// Records a refusal breadcrumb and builds the outcome carrying the exact wire code — the
    /// discriminator between a state-based denial and an accepted-but-not-shown write.
    private func refusalOutcome(_ error: Error) -> RatingWriteOutcome {
        guard case NativeCameraSessionError.objectRatingRejected(let response, let rawCode) = error
        else {
            AppDiagnostics.shared.record(.ratingWriteRefused)
            return .refused(code: 0, message: "Rating not saved — the camera didn't respond.")
        }
        AppDiagnostics.shared.record(
            response == .accessDenied ? .ratingWriteRefusedAccessDenied : .ratingWriteRefused)
        let hex = String(format: "0x%04X", rawCode)
        let reason =
            response == .accessDenied
            ? "Access Denied \(hex) — it may not accept ratings in this mode"
            : "response \(hex)"
        return .refused(code: rawCode, message: "Rating not saved — camera refused (\(reason)).")
    }

    /// Release a still when the body is in photo mode; demo mode simulates a brief pulse.
    /// While a bulb/time exposure is holding the shutter open, a second tap ends it.
    func captureStill() { captureStill(admission: nil) }

    private func captureStill(admission: NikonCommandAdmission?) {
        guard admitsCameraCommand(admission), !relayControlSurrendered else { return }
        if isDemoSession {
            guard !isStillCapturing else { return }
            isStillCapturing = true
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 250_000_000)
                isStillCapturing = false
                // Demo instant playback: the staged feed still (or the mock-feed asset the
                // raster falls back to) stands in for the card's just-captured object so the
                // review overlay is verifiable without a body.
                if assist.instantReview,
                    let image = liveFrameImage ?? UIImage(named: "MockFeed")
                {
                    presentInstantReview(image)
                }
            }
            return
        }
        guard cameraSession != nil, isMonitorPresented else {
            // The release's own pre-flight refusal - same sink as every other one (see
            // `finishStillRelease`), so a shutter press against a dropped session says so.
            showMonitorNotice("Connect a camera before capturing.")
            return
        }
        if isStillCapturing {
            if stillReleaseIsOpenShutter { pendingStillTerminateWork = .init(admission: admission) }
            return
        }
        isStillCapturing = true
        pendingStillCaptureWork = .init(admission: admission)
        // Freeze the shot's focus box NOW (press time) - the review overlay reads this, so a box
        // moved during the post-shutter fetch window can't rewrite the reviewed shot's reticle.
        capturedFocusForReview = liveViewFocus
    }

    /// Queued image-area (sensor crop) write, consumed at the next safe point.
    @ObservationIgnored private var pendingImageAreaWrite: StillImageArea?

    /// Sets the photo image area: the pill and feed frame flip optimistically, and the
    /// write lands at the next safe point (poll readback confirms or corrects).
    func setStillImageArea(_ area: StillImageArea) {
        cameraPropertySnapshot = cameraPropertySnapshot.applying(
            property: .captureAreaCrop, data: Data([area.rawValue]))
        publishCameraDisplayState()
        guard !isDemoSession else { return }
        guard cameraSession != nil else { return }
        pendingImageAreaWrite = area
    }

    /// Queues the photo image-size write (the camera's own enumerated resolution string, sent
    /// back verbatim as a PTP string) with an optimistic snapshot update so the pill reflects
    /// the pick immediately; the poll confirms it.
    private func applyStillImageSize(_ value: String) {
        guard let write = PTPCameraPropertyWrite.request(control: .stillImageSize, label: value)
        else { return }
        cameraPropertySnapshot = cameraPropertySnapshot.applying(
            property: write.property, data: write.data)
        publishCameraDisplayState()
        guard !isDemoSession else { return }
        enqueueCameraWrite(PendingCameraWrite(picker: .stillSize, value: value, write: write))
        connectionMessage =
            isMonitorPresented
            ? "Queued Image Size \(value) for the next live-view safe point."
            : "Queued Image Size \(value)."
        drainPendingWritesIfIdle()
    }

    /// Queues a stills tab-setting write (AF-area, subject detection, a U bank's inner
    /// program) with an optimistic snapshot update; the poll confirms or corrects it, and a
    /// body that rejects the value surfaces through the queue.
    private func applyStillControl(
        _ control: PTPCameraControl, picker: CameraPicker, value: String
    ) {
        guard let write = PTPCameraPropertyWrite.request(control: control, label: value) else {
            return
        }
        cameraPropertySnapshot = cameraPropertySnapshot.applying(
            property: write.property, data: write.data)
        publishCameraDisplayState()
        guard !isDemoSession else { return }
        enqueueCameraWrite(PendingCameraWrite(picker: picker, value: value, write: write))
        drainPendingWritesIfIdle()
    }

    /// Queues the NEF (RAW) recording compression write from the quality panel, with an
    /// optimistic snapshot update; the poll confirms or corrects it.
    func applyStillRawCompression(_ value: String) {
        guard
            let write = PTPCameraPropertyWrite.request(control: .stillRawCompression, label: value)
        else { return }
        cameraPropertySnapshot = cameraPropertySnapshot.applying(
            property: write.property, data: write.data)
        publishCameraDisplayState()
        guard !isDemoSession else { return }
        enqueueCameraWrite(PendingCameraWrite(picker: .stillQuality, value: value, write: write))
        connectionMessage =
            isMonitorPresented
            ? "Queued RAW recording \(value) for the next live-view safe point."
            : "Queued RAW recording \(value)."
        drainPendingWritesIfIdle()
    }

    /// Queued still release, consumed at the next live-view/command safe point.
    private struct PendingStillCommand {
        let admission: NikonCommandAdmission?
    }
    @ObservationIgnored private var pendingStillCaptureWork: PendingStillCommand?
    // Existing direct writers create their own nil-admission item, never borrow an older receipt.
    private var pendingStillCapture: Bool {
        get { pendingStillCaptureWork != nil }
        set { pendingStillCaptureWork = newValue ? .init(admission: nil) : nil }
    }
    /// Queued bulb/time termination, consumed at the next safe point.
    @ObservationIgnored private var pendingStillTerminateWork: PendingStillCommand?
    private var pendingStillTerminate: Bool {
        get { pendingStillTerminateWork != nil }
        set { pendingStillTerminateWork = newValue ? .init(admission: nil) : nil }
    }
    /// The queued terminate is a burst-end courtesy - a refusal is expected and stays silent.
    @ObservationIgnored private var pendingStillTerminateQuiet = false
    /// A release was accepted and DeviceReady has not yet confirmed completion.
    @ObservationIgnored private var stillReleaseAwaitingReady = false
    /// DeviceReady reported a bulb/time exposure holding the shutter open.
    private(set) var stillReleaseIsOpenShutter = false
    @ObservationIgnored private var stillReleaseStartedAt: Date?
    @ObservationIgnored private var lastStillReadyPollAt: Date?

    /// Services queued still-release work at a safe point. Returns true when it consumed
    /// the safe point (mirrors the record-toggle contract).
    private func serviceStillCaptureWork(session: NativeCameraSession) async -> Bool {
        if let area = pendingImageAreaWrite {
            pendingImageAreaWrite = nil
            do {
                try await session.writeCameraProperty(
                    PTPCameraPropertyWrite(
                        property: .captureAreaCrop, data: Data([area.rawValue])))
            } catch {
                // Same reason as `finishStillRelease`: this is a monitor-time refusal, and the
                // connect screens are the only place `connectionMessage` is ever read.
                showMonitorNotice(
                    "Image area change failed: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
                )
            }
            return true
        }
        if let work = pendingStillTerminateWork {
            pendingStillTerminateWork = nil
            let quiet = pendingStillTerminateQuiet
            pendingStillTerminateQuiet = false
            do {
                if let admission = work.admission {
                    try await session.terminateStillCapture(admission: admission)
                } else {
                    try await session.terminateStillCapture()
                }
                // Completion (frame delivery) still lands via the readiness poll below.
            } catch {
                if work.admission != nil, cameraSession !== session { return true }
                if !quiet {
                    showMonitorNotice(
                        "Ending the exposure failed: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
                    )
                }
            }
            return true
        }
        if let work = pendingStillCaptureWork {
            pendingStillCaptureWork = nil
            do {
                try work.admission?.require(owner: session.commandOwner)
                if shutterPressLatchedBurst, !remoteModeHeldForBurst {
                    // A continuous hold needs the remote-mode bracket: host-set session
                    // values (the burst ceiling) only persist while remote mode is held -
                    // without it every release snaps back to a single frame. The body's
                    // dials lock for the bracket's duration, so it opens on the press and
                    // closes the moment the burst ends. [verify-on-HW]
                    let ceiling = PTPCameraPropertyWrite(
                        property: .burstNumber, data: Data(ByteCoding.uint16LE(65535)))
                    if let admission = work.admission {
                        do {
                            try await session.changeCameraMode(remote: true, admission: admission)
                        } catch { try admission.require(owner: session.commandOwner) }
                        guard cameraSession === session else { return true }
                        // Entered remote mode must be released by the original cleanup even if
                        // the following unsent ceiling/release is refused after retirement.
                        remoteModeHeldForBurst = true
                        do {
                            try await session.writeCameraProperty(ceiling, admission: admission)
                        } catch { try admission.require(owner: session.commandOwner) }
                    } else {
                        try? await session.changeCameraMode(remote: true)
                        try? await session.writeCameraProperty(ceiling)
                        remoteModeHeldForBurst = true
                    }
                }
                // Preserve the dial-set focus: fire without AF driving when the operator drove
                // focus with the dial and hasn't tapped to AF since (an AF release would re-focus
                // at the box and undo the manual pull).
                if let admission = work.admission {
                    try await session.initiateStillCapture(
                        preserveFocus: focusManuallyDialed, admission: admission)
                    guard cameraSession === session else { return true }
                } else {
                    try await session.initiateStillCapture(preserveFocus: focusManuallyDialed)
                }
                stillReleaseAwaitingReady = true
                stillReleaseStartedAt = Date()
                lastStillReadyPollAt = nil
            } catch {
                if work.admission != nil, cameraSession !== session { return true }
                await exitBurstRemoteModeIfNeeded(session: session)
                finishStillRelease(
                    message:
                        "Still capture failed: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
                )
            }
            return true
        }
        if stillReleaseAwaitingReady {
            // One DeviceReady between frames, throttled so bursts/self-timer don't
            // monopolise the transaction gate.
            let now = Date()
            if let last = lastStillReadyPollAt, now.timeIntervalSince(last) < 0.35 {
                return false
            }
            lastStillReadyPollAt = now
            await pollStillReleaseProgress(session: session)
            return true
        }
        return false
    }

    private func pollStillReleaseProgress(session: NativeCameraSession) async {
        do {
            switch try await session.pollStillReleaseReadiness() {
            case .complete:
                if shutterPressLatchedBurst, !pendingStillTerminate, chainedBurstFrames < 30 {
                    // Finger still down in a continuous drive: chain the next release right
                    // away — one command release delivers a bounded run of frames no matter
                    // the ceiling, so the hold itself drives the burst. The frame cap
                    // backstops a swallowed finger-up. [verify-on-HW]
                    chainedBurstFrames += 1
                    pendingStillCapture = true
                    stillReleaseAwaitingReady = false
                    return
                }
                shutterPressLatchedBurst = false
                chainedBurstFrames = 0
                await exitBurstRemoteModeIfNeeded(session: session)
                finishStillRelease(message: nil)
                // The SHOTS pill reflects the frame immediately (a burst consumes more — the
                // read-back right after corrects the estimate rather than waiting for the
                // slow poll round-robin to reach ExposureRemaining).
                if let shots = cameraPropertySnapshot.shotsRemaining, shots > 0 {
                    cameraPropertySnapshot = cameraPropertySnapshot.decrementingShotsRemaining()
                    publishCameraDisplayState()
                }
                await readAndApplyCameraProperty(session: session, property: .exposureRemaining)
                scheduleInstantReview(session: session)
            case .inProgress:
                stillReleaseIsOpenShutter = false
                // Self-timer waits up to 20 s and bursts can run long; only give up well
                // past anything a working release should need.
                if let startedAt = stillReleaseStartedAt,
                    Date().timeIntervalSince(startedAt) > 45
                {
                    finishStillRelease(
                        message: "The camera did not confirm the still release.")
                }
            case .openShutterInProgress:
                stillReleaseIsOpenShutter = true
            case .failed(let code):
                shutterPressLatchedBurst = false
                chainedBurstFrames = 0
                await exitBurstRemoteModeIfNeeded(session: session)
                finishStillRelease(
                    message: code == .outOfFocus
                        ? "AF did not focus — still not captured."
                        : "Still capture failed (0x\(String(code.rawValue, radix: 16))).")
            }
        } catch {
            await exitBurstRemoteModeIfNeeded(session: session)
            finishStillRelease(
                message:
                    "Still capture status failed: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
            )
        }
    }

    private func finishStillRelease(message: String?) {
        stillReleaseAwaitingReady = false
        stillReleaseIsOpenShutter = false
        stillReleaseStartedAt = nil
        isStillCapturing = false
        // Every failed release ends here — the refusal, the timeout, and both throw paths — so this
        // is the one place the operator has to be told. It used to write `connectionMessage`, which
        // the monitor never renders (see `showMonitorNotice`), leaving a refused shutter silent.
        if let message { showMonitorNotice(message) }
    }

    /// A take is rolling, or a record command is waiting on the operator's confirmation. Clean
    /// view keeps the record control alone on screen while this is true — it strips every other
    /// rail, but never the way to STOP a take (#256).
    var isRecordingOrPending: Bool {
        isRecording || pendingRecordConfirmation != nil
    }

    /// True while the body reports photo mode — the strips and pickers then resolve the stills
    /// set (`CameraPicker.forValueLabel(_:photography:)`) instead of the movie one.
    var isPhotographyMode: Bool {
        StillCapturePolicy.prefersPhotographyChrome(
            selector: cameraPropertySnapshot.captureSelector)
    }

    /// The live assist tools that actually render right now. The single funnel every live overlay,
    /// scope, image effect and sampler reads, which is what makes clean view genuinely clean
    /// (#256). Photography keeps the display tools, as on every app (A1-19), but drops the video
    /// ones (the LUT and the cinema analysis tools): the saved switches are untouched, so the flip
    /// back to video restores them.
    var renderedLiveAssistTools: Set<MonitorAssistTool> {
        guard displayMode != .command else { return [] }
        let photography = isPhotographyMode
        var tools = Set(
            MonitorAssistTool.activeCases.filter {
                assist.isVisible($0.selection) && !(photography && $0.isNikonVideoOnly)
            })
        // The camera's audio meter rides in the live-view frame header, and there is no substitute
        // — the phone's microphone is not what the camera is recording. On any other picture source
        // the meter leaves rather than holding its last reading, which would look live.
        if !monitorAvailability.audioMeters { tools.remove(.audioMeters) }
        return tools
    }

    /// The portrait fit/fill choice the live surface lays out and offers. Fit or fill is a cinema
    /// choice: a stills body lays out its whole image area and offers no key, while the saved choice
    /// waits for video (ZIA-039, as Android Z does).
    var livePortraitAspect: PortraitFeedAspect? {
        isPhotographyMode ? nil : preferences.portraitFeedAspect
    }

    /// Whether the monitored picture is flipped left-to-right (see `MonitorAssistTool.mirror`).
    ///
    /// A display transform and nothing more: the recording, the scopes, and every coordinate the
    /// camera reports stay in the true orientation. Only the raster and the things drawn to sit on
    /// top of it — the AF boxes, and a tap that moves them — take the flip into account.
    var liveFeedMirrored: Bool {
        renderedLiveAssistTools.contains(.mirror) && assist.mirrorHorizontal
    }

    /// Vertical presentation axis, admitted independently from playback visibility.
    var liveFeedMirroredVertically: Bool {
        renderedLiveAssistTools.contains(.mirror) && assist.mirrorVertical
    }

    /// The de-squeeze the live picture presents (DISP mode and photography applied).
    var liveDesqueeze: NikonDesqueeze {
        assist.desqueeze(visible: renderedLiveAssistTools.contains(.desqueeze))
    }

    /// The de-squeeze playback and stills present.
    var playbackDesqueeze: NikonDesqueeze {
        assist.desqueeze(visible: assist.playbackTools.contains(.desqueeze))
    }

    /// The ≤2 scopes the portrait-fit stacked zone shows, already filtered by DISP mode and the
    /// photography toolset. Eligibility is resolved before choosing the canonical first two.
    var renderedFitScopes: [MonitorAssistTool] {
        let rendered = renderedLiveAssistTools
        return preferences.displayedFitScopes(on: rendered)
    }

    /// Runs the target the operator confirmed. It used to recompute `!isRecording` here, so a take
    /// the camera started (or stopped) while the prompt was up was inverted by "Start" (or "Stop").
    func confirmRecordToggle() {
        guard let start = pendingRecordConfirmation else { return }
        pendingRecordConfirmation = nil
        executeRecord(start: start)
    }

    func cancelRecordToggle() {
        pendingRecordConfirmation = nil
    }

    /// Runs an explicit record start (`true`) or stop. The target is resolved once by the caller and
    /// never re-derived here, so it cannot invert a take the camera changed in the meantime.
    private func executeRecord(start: Bool) { executeRecord(start: start, admission: nil) }

    private func executeRecord(start: Bool, admission: NikonCommandAdmission?) {
        guard admitsCameraCommand(admission) else { return }
        if videoSource == .relay {
            // A viewer has no session; the host runs it. The guard is belt-and-braces — the host
            // ignores commands from a non-holder too — but it keeps a revoked device from firing
            // a command it will never see rejected.
            guard relayHoldsControl else { return }
            // The relay wire is a toggle, so never send one the relayed state already satisfies.
            guard start != isRecording else { return }
            relayClient?.send(command: .toggleRecording)
            return
        }
        if isDemoSession {
            isRecording = start
            // `updating` preserves every other field — crucially `mediaStatus`, so the top-bar MEDIA
            // cell keeps toggling capacity ↔ duration after a record start/stop.
            cameraState = cameraState.updating(recordState: isRecording ? .recording : .standby)
            return
        }
        guard shell.control.session != nil, !pictureOnlyMonitor else {
            showMonitorNotice("Start live view before recording.")
            return
        }
        refreshCommonControlFacts()
        if let admission {
            guard let dispatch = sharedCommandAdmission(admission) else { return }
            shell.control.record(start: start, admission: dispatch)
        } else {
            shell.control.record(start: start)
        }

    }

    // MARK: Apple Watch relay

    @ObservationIgnored private var watchCommandSource: NikonCommandAdmission?

    /// Activates the watch relay once and wires its callbacks. Called from the app root on launch.
    func activateWatchRelay() {
        guard !watchRelayActivated else { return }
        watchRelayActivated = true
        watchRelay.onToggleRecord = { [weak self] in
            self?.watchToggleRecord()
                ?? OpenZCineCore.WatchCommandResult(
                    accepted: false, isRecording: false, error: "unavailable")
        }
        watchRelay.onCapture = { [weak self] in
            self?.watchCapture()
                ?? OpenZCineCore.WatchCommandResult(
                    accepted: false, isRecording: false, error: "unavailable")
        }
        watchRelay.onAdmittedToggleRecord = { [weak self] receipt in
            guard let self, let admission = self.watchCommandAdmission(receipt) else {
                return OpenZCineCore.WatchCommandResult(
                    accepted: false, isRecording: false, error: "unavailable")
            }
            return self.watchToggleRecord(admission: admission)
        }
        watchRelay.onAdmittedCapture = { [weak self] receipt in
            guard let self, let admission = self.watchCommandAdmission(receipt) else {
                return OpenZCineCore.WatchCommandResult(
                    accepted: false, isRecording: false, error: "unavailable")
            }
            return self.watchCapture(admission: admission)
        }
        watchRelay.onReachabilityChanged = { [weak self] in
            self?.publishWatchState()
        }
        watchRelay.activate()
        publishWatchState()
    }

    // MARK: Bluetooth shutter remote

    /// Starts or stops the shared remote shutter (A2-32) to match the current state: opted in,
    /// live monitor up AND front (no full-screen panel like Operator Setup, Media, or the Tool
    /// Library covering it), app active, and the clip player not owning the audio session. Inside
    /// menus it disarms entirely so the volume keys go back to controlling volume. Idempotent:
    /// safe to call from every seam that changes an input (preference toggle, monitor
    /// present/dismiss, foreground return).
    func updateBluetoothShutter() {
        bluetoothShutter.onTrigger = { [weak self] in self?.remoteShutterToggleRecord() }
        bluetoothShutter.update(
            enabled: preferences.bluetoothShutterEnabled, monitorPresented: isMonitorPresented,
            liveViewFront: !activePanelHidesLiveFeed && !isStandaloneMediaLibraryPresented,
            audioSessionAvailable: !mediaPlaybackOwnsAudioSession)
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
    func remoteShutterToggleRecord() {
        guard admitsRecordPress else {
            bluetoothShutter.log.info("BT-SHUTTER record refused by the monitor's admission")
            return
        }
        let wasRecording = isRecording
        let hasSession = cameraSession != nil || isDemoSession
        executeRecord(start: !wasRecording)
        bluetoothShutter.log.info(
            "BT-SHUTTER record callback session=\(hasSession, privacy: .public) monitor=\(self.isMonitorPresented, privacy: .public) before=\(wasRecording, privacy: .public) after=\(self.isRecording, privacy: .public) queued=\(self.pendingRecordToggle, privacy: .public)"
        )
        publishWatchState()
    }

    /// Handles a Record toggle relayed from the watch. Bypasses `recordConfirmationEnabled` -
    /// a phone-side confirmation dialog would strand an unseen prompt while the operator is
    /// looking at the watch.
    /// Releases the shutter for the watch, through the phone's own `captureStill` rather than a
    /// second release path - drive mode, focus preservation and the SHOTS decrement all live
    /// there, and a parallel implementation would drift from every one of them.
    private func watchCommandAdmission(_ receipt: RelayWatchCommandAdmission)
        -> NikonCommandAdmission?
    {
        guard receipt.isCurrent, let shown = watchCommandSource,
            shown.admits(cameraSession?.commandOwner)
        else { return nil }
        return NikonCommandAdmission(
            owner: shown.owner, isCurrent: { shown.isCurrent && receipt.isCurrent })
    }

    func watchCapture() -> OpenZCineCore.WatchCommandResult { watchCapture(admission: nil) }

    private var watchCommandFacts: WatchCommandFacts {
        WatchCommandFacts(
            isRecording: isRecording,
            isBusy: shell.control.recordPending || interfaceLocked || relayControlSurrendered,
            isLive: isMonitorPresented && (isDemoSession || cameraSession != nil),
            isPhotography: StillCapturePolicy.prefersPhotographyChrome(
                selector: cameraPropertySnapshot.captureSelector))
    }

    private func watchCapture(admission: NikonCommandAdmission?) -> OpenZCineCore.WatchCommandResult
    {
        let result = WatchCommandPolicy.answer(
            .capture, facts: { watchCommandFacts },
            shutter: {
                guard admitsCameraCommand(admission) else { return .targetChanged }
                // Keep the existing still queue, bulb termination and native first-send admission.
                guard !isStillCapturing || stillReleaseIsOpenShutter else { return .notSent }
                captureStill(admission: admission)
                return pendingStillCaptureWork != nil || pendingStillTerminateWork != nil
                    || (isDemoSession && isStillCapturing) ? .sent : .notSent
            })
        publishWatchState()
        return OpenZCineCore.WatchCommandResult(
            accepted: result.accepted, isRecording: result.isRecording, error: result.error)
    }

    func watchToggleRecord() -> OpenZCineCore.WatchCommandResult {
        watchToggleRecord(admission: nil)
    }

    private func watchToggleRecord(admission: NikonCommandAdmission?)
        -> OpenZCineCore.WatchCommandResult
    {
        let result = WatchCommandPolicy.answer(
            .toggleRecord, facts: { watchCommandFacts },
            shutter: {
                guard admitsCameraCommand(admission) else { return .targetChanged }
                if isDemoSession {
                    executeRecord(start: !isRecording, admission: admission)
                    return .sent
                }
                guard shell.control.session != nil, !pictureOnlyMonitor else { return .notSent }
                refreshCommonControlFacts()
                guard let editor = shell.control.recordEditor() else { return .notSent }
                let accepted: Bool
                if let admission {
                    guard let dispatch = sharedCommandAdmission(admission) else {
                        return .targetChanged
                    }
                    accepted = shell.control.commitRecord(from: editor, admission: dispatch)
                } else {
                    accepted = shell.control.commitRecord(from: editor)
                }
                return accepted ? .sent : .notSent
            })
        publishWatchState()
        return OpenZCineCore.WatchCommandResult(
            accepted: result.accepted, isRecording: result.isRecording, error: result.error)
    }

    /// Builds the current wire snapshot from the live monitor fields.
    func currentWatchRelayState() -> OpenZCineCore.WatchRelayState {
        let hasCamera = isDemoSession || cameraSession != nil
        let connectionState: OpenZCineCore.WatchConnectionState =
            (isMonitorPresented && hasCamera) ? .connected : .noCamera
        let feedLive = connectionState == .connected && !shouldPauseLiveFeed
        return OpenZCineCore.WatchRelayState(
            recordState: cameraState.recordState,
            timecode: liveTimecode,
            mediaStatus: cameraState.mediaStatus,
            media: cameraState.media,
            cameraBatteryPercent: cameraState.cameraBatteryPercent,
            cameraName: cameraState.cameraName,
            isRecording: isRecording,
            connection: connectionState,
            feedLive: feedLive,
            liveFPS: liveFPS,
            // One source for the mode, so the wrist and the phone cannot disagree about which
            // chrome to show.
            isPhotography: StillCapturePolicy.prefersPhotographyChrome(
                selector: cameraPropertySnapshot.captureSelector),
            shotsRemaining: cameraPropertySnapshot.shotsRemaining.map(String.init) ?? "",
            // The still image area the phone itself frames at — carried as a ratio so a crop
            // change on the body reaches the wrist without a second mode-to-shape table.
            feedAspectRatio: StillCapturePolicy.prefersPhotographyChrome(
                selector: cameraPropertySnapshot.captureSelector)
                ? cameraPropertySnapshot.photographyFeedAspect
                : MonitorFeedLayout.aspectRatio,
            batteryReading: cameraBatteryReading, batteryExhausted: cameraBatteryExhausted)
    }

    /// Publishes the current state to the watch relay (coalesced; no-ops when nothing changed).
    func publishWatchState() {
        let owner = cameraSession?.commandOwner
        if watchCommandSource?.owner !== owner { watchRelay.retireSource() }
        watchCommandSource = owner.map { NikonCommandAdmission(owner: $0, isCurrent: { true }) }
        watchRelay.ingestState(currentWatchRelayState())
    }

    /// Active shutter picker tab: 0 = angle, 1 = speed. Uses the optimistic mode while a mode
    /// write is pending so the tab doesn't snap back before the safe point runs.
    var shutterPickerModeIndex: Int {
        let mode = pendingShutterMode ?? cameraPropertySnapshot.shutterMode ?? .angle
        return mode == .speed ? 1 : 0
    }

    /// Active ISO picker tab: R3D NE → low/high base; other codecs → Auto On (0) / Auto Off (1).
    var isoPickerModeIndex: Int {
        if showsDualBaseISOPicker {
            if let pending = pendingBaseISOHigh { return pending ? 1 : 0 }
            return cameraPropertySnapshot.baseISO == "High" ? 1 : 0
        }
        if showsAutoISOPicker {
            return ISOPickerPolicy.autoISOModeIndex(
                codec: cameraState.codec,
                isoAuto: commandISOAuto,
                exposureMode: commandExposureMode)
        }
        return 0
    }

    /// Whether the ISO picker shows separate LOW/HIGH base circuits (R3D NE only).
    var showsDualBaseISOPicker: Bool {
        ISOPickerPolicy.showsDualBaseCircuits(codec: cameraState.codec)
    }

    /// Whether the ISO picker shows Auto On / Auto Off (non-R3D NE movie codecs).
    var showsAutoISOPicker: Bool {
        ISOPickerPolicy.showsAutoISOControl(codec: cameraState.codec)
    }

    /// True when movie ISO auto is on (`MovISOAutoControl`) — not exposure program Auto.
    var isAutoISOActive: Bool {
        ISOPickerPolicy.isAutoISOActive(isoAuto: commandISOAuto, codec: cameraState.codec)
    }

    /// True when the ISO drum is camera-owned (Auto On, or non-R3D mode is not M).
    /// Always false for R3D NE dual-base (manual in every exposure program).
    var isISOValueCameraOwned: Bool {
        ISOPickerPolicy.isISOValueCameraOwned(
            codec: cameraState.codec,
            isoAuto: commandISOAuto,
            exposureMode: commandExposureMode)
    }

    /// True when this codec/mode allows manual ISO writes (R3D always; others only in M).
    var allowsManualISO: Bool {
        ISOPickerPolicy.allowsManualISO(
            codec: cameraState.codec, exposureMode: commandExposureMode)
    }

    /// Optimistic/polled movie ISO auto flag for the Auto On/Off tab and ISO tile.
    var commandISOAuto: Bool? {
        pendingISOAuto ?? cameraPropertySnapshot.isoAuto
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

    /// Segmented mode tabs for a picker (ISO layout follows the active codec + mode).
    func pickerModes(for picker: CameraPicker) -> [PickerMode] {
        guard picker == .iso else { return picker.modes }
        return ISOPickerPolicy.pickerModes(
            codec: cameraState.codec, exposureMode: commandExposureMode
        ).map {
            PickerMode(title: $0.title, detail: $0.detail, options: $0.options, base: $0.base)
        }
    }

    /// Picker header subtitle (ISO reflects dual-base vs unified layout).
    func pickerSubtitle(for picker: CameraPicker) -> String {
        picker == .iso
            ? ISOPickerPolicy.pickerSubtitle(
                codec: cameraState.codec, exposureMode: commandExposureMode)
            : picker.subtitle
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

    /// Top-bar SIZE readout: image area + size class ("FX · L"), ranked against the camera's
    /// enumerated ImageSize strings so the pill never shows a raw resolution.
    var stillSizeAreaDisplay: String? {
        cameraPropertySnapshot.stillSizeAreaLabel(
            sizeOptions: cameraControlOptions[.imageSize] ?? [])
    }

    /// The picker's current camera readout value. The stills pickers read the property snapshot
    /// directly (full labels — the strip compacts some of them, e.g. "Continuous H" → "CH").
    func cameraValue(for picker: CameraPicker) -> String {
        switch picker {
        case .resolution: cameraState.resolutionFrameRate
        case .codec:
            // Match the body's exact `MovFileType` readback onto the advertised row, so the drum
            // centres on the codec it is really recording — and, when that row carries a depth
            // choice, the flanking buttons read the depth off the same match (#276). Falling back
            // to the bar's short label only while the descriptor has not landed.
            PTPCameraPropertyDecoders.codecFamily(
                forFileType: cameraPropertySnapshot.fileType, in: codecFamilies
            )?.label ?? cameraState.codec
        case .mode, .stillMode: commandExposureMode
        case .stillISO: cameraPropertySnapshot.iso.map(String.init) ?? ""
        case .stillShutter: cameraPropertySnapshot.shutterSpeed ?? ""
        case .stillIris: cameraPropertySnapshot.fNumber ?? ""
        case .stillDrive: cameraPropertySnapshot.stillCaptureMode ?? ""
        case .stillFocus: cameraPropertySnapshot.stillFocusMode ?? ""
        case .stillMeter: cameraPropertySnapshot.meteringMode ?? ""
        case .stillSize: stillSizeAreaDisplay ?? ""
        case .stillQuality: cameraPropertySnapshot.compression ?? ""
        case .stillPicture: cameraPropertySnapshot.pictureControl ?? ""
        default: shownCameraValue(picker.valueLabel) ?? ""
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
        if picker == .iso, showsAutoISOPicker {
            // Drum needs a numeric step even when auto is on (tile may show Auto / A51200).
            if let iso = cameraPropertySnapshot.iso, iso > 0 {
                return String(iso)
            }
            let live = cameraValue(for: picker).trimmingCharacters(in: .whitespaces)
            let numeric = live.hasPrefix("A") ? String(live.dropFirst()) : live
            if numeric.allSatisfy(\.isNumber), !numeric.isEmpty { return numeric }
            return ISOPickerPolicy.unifiedOptions.first ?? "800"
        }
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
        if picker == .stillSize {
            // The Area / Size tabs are independent settings with their own stored values.
            switch mode {
            case 0: return cameraPropertySnapshot.imageArea?.label ?? modes[0].base
            case 1: return cameraPropertySnapshot.imageSize ?? modes[1].base
            default: break
            }
        }
        if picker == .stillDrive {
            // Drive is camera state; Built-in reflects the body's self-timer release mode;
            // App is the app-side countdown setting.
            switch mode {
            case 0: return cameraPropertySnapshot.stillCaptureMode ?? modes[0].base
            case 1:
                return cameraPropertySnapshot.stillCaptureMode == StillDriveMode.selfTimer.label
                    ? "On" : "Off"
            case 2: return photoTimerLabel
            default: break
            }
        }
        if picker == .stillFocus {
            // The Area / Subject tabs are independent stills settings with their own values.
            switch mode {
            case 1: return cameraPropertySnapshot.focusArea ?? modes[1].base
            case 2: return cameraPropertySnapshot.focusSubject ?? modes[2].base
            default: break
            }
        }
        if picker == .stillISO {
            // Both tabs centre on the body's live sensitivity (the Auto drum just tracks it).
            let live = cameraValue(for: picker)
            return modes[mode].options.contains(live) ? live : modes[mode].base
        }
        if picker == .stillMode, mode == 1 {
            // The U banks' inner program has its own stored value.
            return cameraPropertySnapshot.userModeProgram ?? modes[1].base
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
        if picker == .stillSize {
            // SIZE is two independent stills settings chosen by tab: the sensor-crop image area
            // (existing safe-point path, reshapes the feed frame) and the image-size string.
            if mode == 0 {
                guard let area = StillImageArea.area(forLabel: value) else { return }
                setStillImageArea(area)
            } else {
                applyStillImageSize(value)
            }
            return
        }
        if picker == .stillDrive, mode > 0 {
            // Built-in engages/releases the body's self-timer drive; App is the in-app
            // countdown, never a camera write. (The shots stepper lives inside both tabs.)
            if mode == 1 {
                setBuiltInTimer(on: value == "On")
            } else {
                setPhotoTimer(label: value)
            }
            return
        }
        if picker == .stillFocus, mode > 0 {
            // AF-area and subject detection are their own stills properties.
            applyStillControl(
                mode == 1 ? .stillFocusArea : .stillFocusSubject,
                picker: .stillFocus, value: value)
            return
        }
        if picker == .stillMode, mode == 1 {
            // The active U bank's inner program is its own property.
            applyStillControl(.stillUserModeProgram, picker: .stillMode, value: value)
            return
        }
        if picker == .stillISO {
            // The Auto tab's drum is display-only; Manual writes only where the exposure
            // mode allows it.
            guard mode == 1, stillAllowsManualISO else { return }
            applyPickerValue(value, for: picker)
            return
        }
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
        if picker == .iso {
            // Manual ISO only in exposure mode M (Auto Off path).
            guard allowsManualISO else { return }
            // Leaving Auto ISO by choosing a drum value (or Auto Off tab already switched M).
            prepareManualISOIfNeeded()
            applyPickerValue(value, for: picker)
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
    @ObservationIgnored private var whiteBalanceTintCells = (amberBlue: 0, greenMagenta: 0)
    @ObservationIgnored private var notifyingWhiteBalanceTint = false
    @ObservationIgnored private var tintAmberBlueNeedsNotification = false
    @ObservationIgnored private var tintGreenMagentaNeedsNotification = false
    var whiteBalanceTintAB: Int {
        get {
            access(keyPath: \.whiteBalanceTintAB)
            return whiteBalanceTintCells.amberBlue
        }
        set {
            whiteBalanceTintCells.amberBlue = newValue
            notifyWhiteBalanceTint(amberBlue: true, greenMagenta: false)
        }
    }
    var whiteBalanceTintGM: Int {
        get {
            access(keyPath: \.whiteBalanceTintGM)
            return whiteBalanceTintCells.greenMagenta
        }
        set {
            whiteBalanceTintCells.greenMagenta = newValue
            notifyWhiteBalanceTint(amberBlue: false, greenMagenta: true)
        }
    }
    @ObservationIgnored private var lastCommittedTint: (ab: Int, gm: Int)?

    /// Commit the complete camera read before any observer can replace its source or values.
    func publishWhiteBalanceTint(amberBlue: Int, greenMagenta: Int) {
        whiteBalanceTintCells = (amberBlue, greenMagenta)
        lastCommittedTint = (amberBlue, greenMagenta)
        notifyWhiteBalanceTint(amberBlue: true, greenMagenta: true)
    }

    private func notifyWhiteBalanceTint(amberBlue: Bool, greenMagenta: Bool) {
        tintAmberBlueNeedsNotification = tintAmberBlueNeedsNotification || amberBlue
        tintGreenMagentaNeedsNotification = tintGreenMagentaNeedsNotification || greenMagenta
        guard !notifyingWhiteBalanceTint else { return }
        notifyingWhiteBalanceTint = true
        defer { notifyingWhiteBalanceTint = false }
        // A nested publication commits immediately. Drain after the outgoing one-shot
        // observer unregisters rather than invoking its willSet callback recursively.
        while tintAmberBlueNeedsNotification || tintGreenMagentaNeedsNotification {
            if tintAmberBlueNeedsNotification {
                tintAmberBlueNeedsNotification = false
                withMutation(keyPath: \.whiteBalanceTintAB) {}
            }
            if tintGreenMagentaNeedsNotification {
                tintGreenMagentaNeedsNotification = false
                withMutation(keyPath: \.whiteBalanceTintGM) {}
            }
        }
    }

    /// Whether the active WB mode has a mapped tune property for the active selector
    /// (Preset slots don't; movie additionally has no Flash tune).
    var whiteBalanceTintAvailable: Bool {
        WhiteBalanceTint.tuneProperty(
            forWBModeLabel: cameraPropertySnapshot.activeWBMode(
                photography: isPhotographyMode) ?? "Auto",
            photography: isPhotographyMode)
            != nil
    }

    /// Operator-facing tint readout ("A1.5 · G0.75" / "Neutral").
    var whiteBalanceTintLabel: String {
        WhiteBalanceTint.label(
            amberBlueCell: whiteBalanceTintAB, greenMagentaCell: whiteBalanceTintGM)
    }

    /// Queues the WB fine-tune write for the current WB mode at the pad's position. Called on
    /// drag end / arrow tap — deduped against the last commit.
    func commitWhiteBalanceTint() { commitWhiteBalanceTint(admission: nil) }

    private func commitWhiteBalanceTint(admission: NikonCommandAdmission?) {
        guard admitsCameraCommand(admission) else { return }
        if forwardExposureHelperOverRelay(
            picker: .whiteBalance, value: "tint \(whiteBalanceTintAB) \(whiteBalanceTintGM)")
        {
            return
        }
        guard !isDemoSession else { return }
        let ab = whiteBalanceTintAB
        let gm = whiteBalanceTintGM
        guard lastCommittedTint?.ab != ab || lastCommittedTint?.gm != gm else { return }
        guard
            let write = WhiteBalanceTint.write(
                wbModeLabel: cameraPropertySnapshot.activeWBMode(
                    photography: isPhotographyMode) ?? "Auto",
                amberBlueCell: ab,
                greenMagentaCell: gm,
                photography: isPhotographyMode
            )
        else { return }
        lastCommittedTint = (ab, gm)
        enqueueCameraWrite(
            PendingCameraWrite(
                picker: .whiteBalance,
                value: "Tint \(whiteBalanceTintLabel)",
                write: write, admission: admission
            )
        )
    }

    /// Seeds the tint pad from the camera: reads the active WB mode's tune property and decodes
    /// the grid coordinate, so the pad opens on the body's actual fine-tune position instead of
    /// assuming neutral.
    func refreshWhiteBalanceTintFromCamera() {
        guard let session = cameraSession, !isDemoSession else { return }
        let generation = connectionGeneration
        let photography = isPhotographyMode
        guard
            let mode = cameraPropertySnapshot.activeWBMode(photography: photography),
            let property = WhiteBalanceTint.tuneProperty(
                forWBModeLabel: mode, photography: photography)
        else { return }
        Task { [weak self] in
            guard let data = try? await session.readCameraProperty(property), data.count >= 2
            else { return }
            let raw = UInt16(data[0]) | (UInt16(data[1]) << 8)
            guard let self, self.cameraSession === session,
                self.connectionGeneration == generation, !self.isDemoSession,
                self.isPhotographyMode == photography,
                self.cameraPropertySnapshot.activeWBMode(photography: photography) == mode,
                let cells = WhiteBalanceTint.cells(fromPropertyValue: raw)
            else {
                return
            }
            publishWhiteBalanceTint(amberBlue: cells.amberBlue, greenMagenta: cells.greenMagenta)
        }
    }

    /// Relay fork shared by the exposure-cell helpers (base ISO, shutter mode, ISO auto, WB
    /// tint): a control-holding watcher forwards the change as a picker command in the same
    /// vocabulary the helpers already stamp on their pending writes, and the host routes it
    /// back to the helper (`routeRelayHelperValue`). Without this every helper either no-oped
    /// on its descriptor guard (empty watcher snapshot — the field "Base ISO HIGH does
    /// nothing") or queued a write no session would ever drain. Returns true when forwarded.
    private func forwardExposureHelperOverRelay(picker: CameraPicker, value: String) -> Bool {
        guard videoSource == .relay else { return false }
        guard relayHoldsControl else { return true }
        relayClient?.send(command: .pickerValue(picker: picker.rawValue, value: value))
        return true
    }

    /// Host-side twin of `forwardExposureHelperOverRelay`: recognizes the helper vocabulary
    /// inside a relayed picker command and dispatches to the helper instead of the generic
    /// value write. Both ends pin the same wire version, so the vocabulary cannot drift.
    /// Returns true when the value was a helper's.
    private func routeRelayHelperValue(
        _ value: String, for picker: CameraPicker, admission: NikonCommandAdmission
    ) -> Bool {
        switch (picker, value) {
        case (.iso, "High base"), (.iso, "Low base"):
            switchBaseISO(highBase: value == "High base", admission: admission)
            return true
        case (.iso, "Auto on"), (.iso, "Auto off"):
            switchAutoISO(enabled: value == "Auto on", admission: admission)
            return true
        case (.shutter, "Speed"), (.shutter, "Angle"):
            switchShutterMode(speedMode: value == "Speed", admission: admission)
            return true
        case (.whiteBalance, let tint) where tint.hasPrefix("tint "):
            let cells = tint.dropFirst(5).split(separator: " ").compactMap { Int($0) }
            guard cells.count == 2 else { return true }
            whiteBalanceTintAB = cells[0]
            whiteBalanceTintGM = cells[1]
            commitWhiteBalanceTint(admission: admission)
            return true
        default:
            return false
        }
    }

    /// Switches the camera's dual-base ISO circuit (Low ↔ High) by writing `movieBaseISO`
    /// (1 = Low, 2 = High). Queued before the new ISO value so the base is set first.
    func switchBaseISO(highBase: Bool) { switchBaseISO(highBase: highBase, admission: nil) }

    private func switchBaseISO(highBase: Bool, admission: NikonCommandAdmission?) {
        guard admitsCameraCommand(admission) else { return }
        if forwardExposureHelperOverRelay(
            picker: .iso, value: highBase ? "High base" : "Low base")
        {
            return
        }
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
                write: write, admission: admission
            )
        )
    }

    /// Toggles movie ISO auto (`MovISOAutoControl`) — not exposure-program Auto/M.
    /// Photo Auto ISO tab index — camera truth (with the optimistic pending overlay).
    var stillISOPickerModeIndex: Int {
        (pendingISOAuto ?? cameraPropertySnapshot.isoAuto) == true ? 0 : 1
    }

    /// Mode-aware manual gate for stills: the full-auto and scene programs own sensitivity
    /// outright, so Manual only offers itself in P/S/A/M and the user banks.
    var stillAllowsManualISO: Bool {
        ["P", "S", "A", "M", "U1", "U2", "U3"].contains(
            cameraPropertySnapshot.exposureMode ?? "")
    }

    /// The stills program actually driving exposure: a U bank runs as its inner program.
    private var effectiveStillProgram: String {
        let mode = cameraPropertySnapshot.exposureMode ?? ""
        if mode.hasPrefix("U") { return cameraPropertySnapshot.userModeProgram ?? mode }
        return mode
    }

    /// Mode-aware write gates for the stills exposure tiles: the body owns shutter outside
    /// M/S and aperture outside M/A, so their drums only collect rejections there. An
    /// unknown program stays enabled rather than guessing a lock. [verify-on-HW]
    var stillAllowsShutterControl: Bool {
        let program = effectiveStillProgram
        return program.isEmpty || program == "M" || program == "S"
    }

    var stillAllowsIrisControl: Bool {
        let program = effectiveStillProgram
        return program.isEmpty || program == "M" || program == "A"
    }

    /// How the strip marks a camera-owned value (baseline 0.55 dim and lock glyph): photo SHUTTER
    /// outside M/S and IRIS outside M/A belong to the program; a camera shutter lock and the
    /// R3D NE ISO lock while recording are locks. A hold on the movie SHUTTER cell toggles the
    /// camera lock wherever no quick adjust owns the hold.
    func readoutCue(for picker: CameraPicker) -> (
        dimmed: Bool, badge: MonitorIcon?, holdsShutterLock: Bool
    ) {
        switch picker {
        case .stillShutter: (!stillAllowsShutterControl, nil, false)
        case .stillIris: (!stillAllowsIrisControl, nil, false)
        case .shutter:
            lockedControls.contains(.shutter) ? (true, .lock, true) : (false, nil, true)
        case .iso: isISORecordingLocked ? (true, .lock, false) : (false, nil, false)
        default: (false, nil, false)
        }
    }

    /// Whether a press on the strip cell may open its quick drum: a movie SHUTTER adjusts only a
    /// known, unlocked circuit, and a camera-owned (dimmed) value has nothing to adjust.
    func readoutQuickEnabled(for picker: CameraPicker) -> Bool {
        (picker != .shutter
            || (cameraPropertySnapshot.shutterLocked == false
                && cameraPropertySnapshot.shutterMode != nil
                && !lockedControls.contains(.shutter)))
            && stillProgramAllows(picker) && !readoutCue(for: picker).dimmed
    }

    /// Whether the exposure program leaves this stills value to the operator.
    func stillProgramAllows(_ picker: CameraPicker) -> Bool {
        switch picker {
        case .stillShutter: stillAllowsShutterControl
        case .stillIris: stillAllowsIrisControl
        default: true
        }
    }

    /// Toggles the stills Auto ISO control with an optimistic snapshot update; the queued
    /// write's readback confirms it, and a change made on the body flows back through the
    /// poll the same way.
    func switchStillAutoISO(enabled: Bool) {
        if !enabled, !stillAllowsManualISO { return }
        let write = PTPCameraPropertyWrite(
            property: .stillISOAutoControl, data: Data([enabled ? 1 : 0]))
        cameraPropertySnapshot = cameraPropertySnapshot.applying(
            property: write.property, data: write.data)
        pendingISOAuto = enabled
        publishCameraDisplayState()
        guard !isDemoSession else { return }
        enqueueCameraWrite(
            PendingCameraWrite(
                picker: .stillISO,
                value: enabled ? "Auto On" : "Auto Off",
                write: write
            )
        )
        drainPendingWritesIfIdle()
    }

    func switchAutoISO(enabled: Bool) { switchAutoISO(enabled: enabled, admission: nil) }

    private func switchAutoISO(enabled: Bool, admission: NikonCommandAdmission?) {
        guard admitsCameraCommand(admission) else { return }
        if forwardExposureHelperOverRelay(picker: .iso, value: enabled ? "Auto on" : "Auto off") {
            return
        }
        guard showsAutoISOPicker, !isISORecordingLocked else { return }
        // Auto Off / manual only in M; ignore attempts from non-M modes.
        if !enabled, !allowsManualISO { return }
        let write = PTPCameraPropertyWrite.movieISOAuto(enabled: enabled)
        cameraPropertySnapshot = cameraPropertySnapshot.applying(
            property: write.property, data: write.data)
        pendingISOAuto = enabled
        publishCameraDisplayState()
        guard !isDemoSession else { return }
        enqueueCameraWrite(
            PendingCameraWrite(
                picker: .iso,
                value: enabled ? "Auto On" : "Auto Off",
                write: write, admission: admission
            )
        )
    }

    /// Ensures ISO writes can stick: when movie ISO auto is on, switch to manual first.
    func prepareManualISOIfNeeded() {
        guard showsAutoISOPicker, isAutoISOActive, !isISORecordingLocked, allowsManualISO else {
            return
        }
        switchAutoISO(enabled: false)
    }

    func switchShutterMode(speedMode: Bool) {
        switchShutterMode(speedMode: speedMode, admission: nil)
    }

    private func switchShutterMode(speedMode: Bool, admission: NikonCommandAdmission?) {
        guard admitsCameraCommand(admission) else { return }
        if forwardExposureHelperOverRelay(picker: .shutter, value: speedMode ? "Speed" : "Angle") {
            return
        }
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
            PendingCameraWrite(
                picker: .shutter, value: speedMode ? "Speed" : "Angle", write: write,
                admission: admission)
        )
        connectionMessage =
            "Queued shutter \(speedMode ? "speed" : "angle") mode for the next live-view safe point."
        if case .picker(.shutter) = activePanel, let session = cameraSession {
            Task {
                await refreshShutterModeDependentOptions(session: session, mode: mode)
            }
        }
    }

    /// The grouped panel's producer, separate from legacy direct setting operations.
    func applyGroupedStabilization(
        _ request: NikonStabilizationRequest, option: String,
        source: MonitorOperatorLiveIdentity
    ) {
        guard operatorLiveIdentity == source, !interfaceLocked, !relayControlSurrendered else {
            return
        }
        #if DEBUG
            if isDemoSession {
                switch request {
                case .movieVR: setVibrationReduction(option)
                case .electronicVR: setElectronicVR(on: option == "ON")
                }
                return
            }
        #endif
        guard let native = cameraSession, let owner = native.commandOwner else { return }
        let producer = currentGroupedStabilizationProducer()
        let commonAuthority = controlSession?.captureCommandAuthority()
        let admission = NikonCommandAdmission(owner: owner) {
            producer.isActive && (commonAuthority?() ?? true)
        }
        switch request {
        case .movieVR: setVibrationReduction(option, admission: admission)
        case .electronicVR: setElectronicVR(on: option == "ON", admission: admission)
        }
    }

    @ObservationIgnored private var groupedStabilizationProducer: NikonCommandOwner?

    /// One observation per producer lifetime, shared by surviving/superseded row payloads.
    /// Pending values, popup state and ordinary property reports are deliberately not observed.
    private func currentGroupedStabilizationProducer() -> NikonCommandOwner {
        if let groupedStabilizationProducer, groupedStabilizationProducer.isActive {
            return groupedStabilizationProducer
        }
        let producer = NikonCommandOwner()
        groupedStabilizationProducer = producer
        withObservationTracking {
            _ = cameraSession
            _ = videoSource
            _ = liveFrameSource
            _ = operatorSession.locked
            _ = shell.monitor?.id
        } onChange: {
            // Before-mutation notification: no actor state is read on the native executor.
            producer.retire()
        }
        return producer
    }

    /// Queues a movie-VR write ("OFF"/"ON"/"SPORT"). [verify-on-HW]
    func setVibrationReduction(_ label: String, admission: NikonCommandAdmission? = nil) {
        guard admitsCameraCommand(admission) else { return }
        guard let write = PTPCameraPropertyWrite.vibrationReduction(label: label) else { return }
        cameraPropertySnapshot = cameraPropertySnapshot.applying(
            property: write.property, data: write.data)
        publishCameraDisplayState()
        guard !isDemoSession else { return }
        enqueueCameraWrite(
            PendingCameraWrite(
                picker: .stabilization, value: label, write: write, admission: admission))
        connectionMessage = "Queued VR \(label) for the next live-view safe point."
        drainPendingWritesIfIdle()
    }

    /// Queues an electronic-VR on/off write. [verify-on-HW]
    func setElectronicVR(on: Bool, admission: NikonCommandAdmission? = nil) {
        guard admitsCameraCommand(admission) else { return }
        let write = PTPCameraPropertyWrite.electronicVR(on: on)
        cameraPropertySnapshot = cameraPropertySnapshot.applying(
            property: write.property, data: write.data)
        publishCameraDisplayState()
        guard !isDemoSession else { return }
        enqueueCameraWrite(
            PendingCameraWrite(
                picker: .stabilization, value: on ? "e-VR ON" : "e-VR OFF", write: write,
                admission: admission))
        connectionMessage = "Queued e-VR \(on ? "ON" : "OFF") for the next live-view safe point."
        drainPendingWritesIfIdle()
    }

    func showPicker(_ picker: CameraPicker, mode: Int = 0) {
        guard !interfaceLocked else { return }
        // No DISP-mode gate: every route here is a tapped control, and any control the operator's
        // configuration mounts — clean's REC options key, an enabled readout — must open its
        // picker. Entering clean still sweeps in-flight popups (see `displayMode.didSet`).
        // The shared camera panel dismisses the outgoing setting before opening another.
        guard activePanel == nil, assist.configureTool == nil else { return }
        // The program owns this stills value: the dimmed tile opens no drum the body would refuse.
        guard stillProgramAllows(picker) else { return }
        // ISO and shutter tabs follow `movieBaseISO` / `movieShutterMode` on appear — not a
        // caller-supplied default — so seeding mode 0 here would reopen on the wrong circuit.
        switch picker {
        case .iso, .shutter:
            pickerInitialMode = nil
        default:
            pickerInitialMode = mode
        }
        activePanel = .picker(picker)
        if picker == .shutter, !isDemoSession, let session = cameraSession {
            let mode: ShutterDisplayMode = shutterPickerModeIndex == 1 ? .speed : .angle
            Task {
                await refreshShutterModeDependentOptions(session: session, mode: mode)
            }
        }
    }

    /// Hold to lock or unlock the camera shutter control, from the SHUTTER panel or strip cell.
    func toggleShutterLockOnCamera() {
        let locked = lockedControls.contains(.shutter)
        if preferences.hapticsEnabled {
            if locked {
                OperatorSettingsHaptics.unlockConfirm()
            } else {
                OperatorSettingsHaptics.lockConfirm()
            }
        }
        if locked {
            unlockShutterControlOnCamera()
        } else {
            lockShutterControlOnCamera()
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

    /// The active codec's tone as the body reports it (baseline "N-Log"), else the tone a codec
    /// name implies (R3D: Log3G10), else the dash placeholder.
    var commandToneLabel: String {
        movieToneReadout ?? PTPCameraPropertyDecoders.toneLabel(fromCodec: cameraState.codec)
            ?? "\u{2014}"
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

    /// Dismisses the active panel. The picker clears *immediately* so the operator can interact at
    /// once; its outgoing copy just fades out fast via the removal transition (no slide-down, no
    /// lock). Other panels close via the shared transition.
    func dismissActivePanel() {
        assist.configureTool = nil
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

    /// Opens Operator Setup from the startup home on the operator's last tab and scroll offset,
    /// the shared landing-tab rule (A2-84).
    func openStandaloneSettings() {
        isStandaloneSettingsPresented = true
    }

    func showAssist(_ tool: MonitorAssistTool) {
        guard !interfaceLocked else { return }
        activePanel = nil
        assist.configureTool = tool.selection
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
    func importCustomLUT(from url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let stored = try lutFileStore.importFile(from: url, into: .custom)
        LUTCubeCache.invalidate(
            forKey: LUTSelection.stored(category: .custom, fileName: stored.fileName).cacheKey)
        refreshCustomLUTs()
        assistConfiguration.selectedLUT = .stored(category: .custom, fileName: stored.fileName)
        setAssist(.lut, visible: true)
    }

    /// Removes a downloaded/imported LUT and reconciles an active selection without changing the
    /// LUT tool's on/off state. Built-in selections are rejected by the file store.
    func deleteStoredLUT(_ lut: StoredCustomLUT, from category: LUTCategory) throws {
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

    /// Imports the RED IPP2 pack the shared download flow fetched: installs its cubes, selects a
    /// sensible default (a REC.709 medium-contrast look when present), and turns the LUT on.
    /// Returns what the import did so the flow can say it in RED's words.
    @discardableResult
    func importRedZip(from url: URL) async -> MonitorLutPackImportResult {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        // The import walks and writes hundreds of files: run it off the main actor so the
        // "Adding LUTs…" page keeps animating instead of freezing the UI for the extraction.
        let store = lutFileStore
        let result = await Task.detached(priority: .userInitiated) {
            (try? store.importPack(at: url, into: .red))
                ?? MonitorLutPackImportResult(importedCount: 0, archiveError: "unreadable store")
        }.value
        guard result.importedCount > 0 else { return result }
        let stored = lutFileStore.list(.red)
        for lut in stored {
            LUTCubeCache.invalidate(
                forKey: LUTSelection.stored(category: .red, fileName: lut.fileName).cacheKey)
        }
        refreshRedLUTs()
        if let chosen = LUTLibraryIndex.defaultRedLUT(from: stored) {
            assistConfiguration.selectedLUT = .stored(category: .red, fileName: chosen.fileName)
            setAssist(.lut, visible: true)
        }
        return result
    }

    /// Opens the Media browser with the sidebar tab matched to the active capture side —
    /// Videos from cinema, Photos from photography.
    func openMediaBrowser() {
        mediaCategoryTab =
            StillCapturePolicy.prefersPhotographyChrome(
                selector: cameraPropertySnapshot.captureSelector) ? .photos : .videos
        activePanel = .media
    }

    /// Toggles the MEDIA cell between capacity (GB · %) and duration (Min) readouts.
    func toggleMediaReadout() {
        prefersMediaDuration.toggle()
    }

    /// The MEDIA cell label, respecting the capacity/duration preference.
    var mediaReadout: String {
        // A relayed source supplies its own observations; the local camera uses the common session.
        if videoSource == .relay {
            if let status = cameraState.mediaStatus {
                return prefersMediaDuration ? status.durationLabel : status.capacityLabel
            }
            return cameraState.media
        }
        let storage = shell.control.snapshot?.storage
        return prefersMediaDuration
            ? storage?.recordingTimeLabel ?? "-- Min"
            : storage?.storageReadout?.label ?? StorageReadout.unavailable
    }

    /// Operator monitor storage uses the same units as every shared live surface.
    var liveMediaReadout: String { liveMediaReadout(portrait: false) }

    /// Portrait keeps a complete, compact label: the nearest whole unit, never a fraction.
    /// Duration mode and every non-portrait surface keep the existing labels.
    func liveMediaReadout(portrait: Bool) -> String {
        if videoSource == .relay {
            guard let status = cameraState.mediaStatus else { return cameraState.media }
            if prefersMediaDuration { return status.durationLabel }
            guard portrait, let bytes = status.freeBytes else { return status.capacityLabel }
            return
                "\(MonitorStorageReadoutFormat.wholeUnitCapacity(bytes: bytes)) · \(status.percentFree)%"
        }
        let storage = shell.control.snapshot?.storage
        return LiveMediaReadout.label(
            storage?.storageReadout, recordingTime: storage?.recordingTimeLabel,
            portrait: portrait, prefersDuration: prefersMediaDuration, photo: isPhotographyMode)
    }

    func setMovablePanelCenter(_ id: String, _ center: CGPoint, bounds: CGRect) {
        movablePanelCenters[id] = center
        movablePanelPositions[id] = MovablePanelStoredCenter(center: center, in: bounds)
    }

    /// Whether the monitor shell is currently rendering the portrait tree (set by `MonitorShell`).
    var monitorIsPortrait = false
    /// Legacy DEBUG screenshot notice. Live scope activation is no longer refused in fit mode.
    let scopeCapNoticeText = "2 scopes max in fit view — close one or pinch to fill"

    /// The shared surface's one note sink: a camera refusal or hint the operator has to be told
    /// about while the monitor is up. The surface clears it after its hold.
    ///
    /// `connectionMessage` is the wrong sink for these: it renders on the connect screens only, so
    /// a refused release written there was indistinguishable from a shutter that never registered.
    /// Android toasts exactly these refusals.
    var monitorNote: String?

    /// Shows `message` on the monitor. Dropped when the monitor is not up (`isMonitorPresented` is
    /// its mount gate): a note queued now would show the moment the monitor next appeared,
    /// minutes later and about something else.
    func showMonitorNotice(_ message: String) {
        guard isMonitorPresented else { return }
        monitorNote = message
    }

    func toggleAssist(_ tool: MonitorAssistTool, context: ViewAssistContext = .liveView) {
        setAssist(tool, visible: !assist.tools(for: context).contains(tool), context: context)
    }

    /// The interface lock guards the shared toggle. Fit placement selects two recent scopes
    /// without changing the operator's active tools, which remain available in fill mode.
    func setAssist(
        _ tool: MonitorAssistTool, visible: Bool, context: ViewAssistContext = .liveView
    ) {
        guard !interfaceLocked else { return }
        assist.set(tool, visible: visible, context: context)
        if context == .liveView { preferences.recordScopeActivation(tool, on: visible) }
        if tool == .instantReview, visible {
            // Arm the post-capture diff with the card's current handles right away.
            seedInstantReviewBaseline()
        }
    }

    func setStreamPreset(_ preset: LiveViewStreamPreset) {
        guard preferences.streamPreset != preset else { return }
        preferences.streamPreset = preset
        recordActiveSetupStreamSettings(streamPreset: preset, qualityBias: nil)
        restartLiveViewForQualityChange()
    }

    func setQualityBias(_ bias: LiveViewQualityBias) {
        guard preferences.qualityBias != bias else { return }
        preferences.qualityBias = bias
        recordActiveSetupStreamSettings(streamPreset: nil, qualityBias: bias)
        restartLiveViewForQualityChange()
    }

    /// What the live session runs at, read off the setup it established over.
    ///
    /// `preferences` stays the value every consumer reads — the live-view configure, the step-down
    /// checker, the settings rows — so this seeds it rather than adding a second source of truth
    /// eight read sites would have to learn about. What changed is where the value COMES from:
    /// the setup's own record, falling back to the shipped default for its path, never to whatever
    /// the previously connected setup happened to leave in `preferences`.
    private func adoptActiveSetupStreamSettings(host: String) {
        let record = activeSetupRecord(host: host)
        let preset = SetupStreamSettings.streamPreset(
            stored: record?.streamPreset,
            pathKind: activeSessionPath?.kind,
            seed: OperatorPreferences.defaults.streamPreset)
        let bias = SetupStreamSettings.qualityBias(
            stored: record?.qualityBias,
            pathKind: activeSessionPath?.kind,
            seed: OperatorPreferences.defaults.qualityBias)
        guard preferences.streamPreset != preset || preferences.qualityBias != bias else { return }
        preferences.streamPreset = preset
        preferences.qualityBias = bias
        // The stream is configured from these during the bootstrap that follows a fresh connect,
        // so nothing needs restarting here — and restarting mid-establishment is the burst loop
        // `restartLiveViewForQualityChange` documents.
        logConnection(
            "setup stream settings preset=\(preset.rawValue) bias=\(bias.rawValue)"
                + " stored=\(record?.qualityBias != nil)")
    }

    /// Writes an operator's pick onto the setup it was made on, so the next connect over this path
    /// starts there. No active session means no setup to write to — the pick still applies to the
    /// live value, it simply has nowhere durable to live.
    private func recordActiveSetupStreamSettings(
        streamPreset: LiveViewStreamPreset?,
        qualityBias: LiveViewQualityBias?
    ) {
        guard !isDemoSession, let host = cameraSession?.identity.host else { return }
        NativeCameraConnectionStore.shared.updateSavedCameraStreamSettings(
            host: host,
            pathKind: activeSessionPath?.kind,
            streamPreset: streamPreset,
            qualityBias: qualityBias)
        refreshSavedCameras()
    }

    /// The record for the setup the live session established over. Keyed by host AND path kind:
    /// a body's access-point and router setups can share an address, so the host alone returns
    /// whichever sits first in the canonical order.
    private func activeSetupRecord(host: String) -> PTPIPSavedCameraRecord? {
        let normalized = PTPIPPairedHosts.normalizedHost(host) ?? host
        return savedCameras.first {
            $0.host == normalized && $0.pathKind == activeSessionPath?.kind
        }
    }

    /// The broadcaster's latency-vs-quality stance. Adopted LIVE: the encoder is swapped and the
    /// host's per-peer window updated in place, while the listener — and every watcher's TCP
    /// connection — stays up. The first restart shipped as a full broadcast bounce, which moved
    /// the listener port and stranded watchers on the stale Bonjour SRV record for its TTL; the
    /// decoder needs no ceremony for the swap, it already rebuilds on changed parameter sets.
    func setRelayEncoderProfile(_ profile: RelayEncoderProfile) {
        guard preferences.relayEncoderProfile != profile else { return }
        preferences.relayEncoderProfile = profile
        guard isRelayBroadcasting, relayHost != nil else { return }
        relayBroadcastPipeline?.adoptProfile(profile)

    }

    /// Applies live to NEW joins; devices already watching keep their access until they leave.
    /// A code the Keychain did not keep changes nothing: the previous code stays in force, as it
    /// does for a code too short for the shared watcher passcode rule.
    func setRelayWatcherPasscode(_ code: String) {
        guard let trimmed = MonitorWatcherPasscodeRule.entry(code).passcode else { return }
        moveLegacyRelayPasscodes()
        guard relayHostPasscode != trimmed else { return }
        guard WatcherRelayKeychain.app.storeHostPasscode(trimmed) else {
            connectionMessage = "The broadcast passcode couldn't be saved. Try again."
            return
        }
        if !preferences.relayWatcherPasscode.isEmpty { preferences.relayWatcherPasscode = "" }
        relayHost?.watcherPasscode = trimmed
    }

    /// The broadcast passcode in force: empty for an open broadcast, nil while the Keychain cannot
    /// answer, so a broadcast never starts unprotected. A preferences copy that has not moved to
    /// the Keychain yet is still the operator's code.
    var relayHostPasscode: String? {
        let legacy = preferences.relayWatcherPasscode
        if !legacy.isEmpty { return legacy }
        return WatcherRelayKeychain.app.hostPasscodeLookup().usableValue
    }

    /// Moves the relay passcodes OpenZCine once kept in UserDefaults into the Keychain (A2-34).
    /// An old copy goes only once the Keychain holds a value that read back.
    func moveLegacyRelayPasscodes() {
        RelayLegacyWatcherPasscodes.move(into: .app, from: .standard)
        let legacy = preferences.relayWatcherPasscode
        guard !legacy.isEmpty,
            WatcherRelayKeychain.app.adoptLegacyHostPasscode(legacy).releasesLegacyCopy
        else { return }
        preferences.relayWatcherPasscode = ""
    }

    /// Applies live: the state broadcast tells watchers, whose ask buttons hide immediately.
    func setRelayAllowsControlRequests(_ allows: Bool) {
        guard preferences.relayAllowsControlRequests != allows else { return }
        preferences.relayAllowsControlRequests = allows
        relayHost?.allowsControlRequests = allows
        if !allows {
            declineRelayControl()
            // Declining only clears a PENDING request — a watcher already holding the token
            // kept it (and kept issuing commands) after the operator turned control off.
            reclaimRelayControl()
        }
        broadcastRelayState()
    }

    /// Re-enter live view so a stream-quality change applies now rather than on the next reconnect.
    /// No-op without a live camera (e.g. the demo), or while the feed is deliberately suspended
    /// behind a full-screen panel, where resume will configure the latest requested quality.
    private func restartLiveViewForQualityChange() {
        guard !isDemoSession, isMonitorPresented, !shouldPauseLiveFeed,
            let session = cameraSession
        else { return }
        // Single-flight: clear the applied size BEFORE restarting so the step-down checker
        // no-ops until the new stream configures and stamps its real size. Leaving the stale
        // size in place let any checker call mid-restart (the warning-status apply inside the
        // bootstrap, the record safe point, the thermal timer) cancel the restart and kick
        // another — an endless burst loop that froze the feed the moment recording began.
        lastAppliedStreamImageSize = nil
        lastAppliedStreamCompression = nil
        startLiveView(session: session, skipPropertyBootstrap: true)
    }

    /// The exact advertised codec mode a CODEC pick resolves to. Two shapes reach here and both
    /// name an advertised value outright — never a label the body did not report:
    ///
    /// - a **bit-depth button** passes that variant's own label ("H.265 10-bit"), which matches a
    ///   mode directly;
    /// - a **drum row** passes the row label ("H.265"), which resolves through the codec family so
    ///   a depth-choice row keeps the depth the body is already on rather than snapping back to
    ///   the first advertised variant — the #276 defect, in the other direction.
    private func codecMode(forPickedLabel label: String) -> PTPCameraFileTypeMode? {
        if let exact = cameraFileTypeModes.first(where: { $0.label == label }) { return exact }
        guard let family = codecFamilies.first(where: { $0.label == label }) else { return nil }
        if let depth = activeCodecMode?.bitDepth,
            let held = family.depths.first(where: { $0.bitDepth == depth })
        {
            return held
        }
        return family.depths.first
    }

    /// One release from the shared compact picker, bounded through the native safe-point queue.
    func applyQuickPicker(
        _ picker: CameraPicker, value: String, identity: NikonCaptureQuickIdentity
    ) {
        guard picker == identity.picker, operatorNativeQuickIsCurrent(identity),
            identity.snapshot.options.contains(value), isMonitorPresented,
            !screenWakeSuppressedForBackground
        else { return }
        #if DEBUG
            if isDemoSession {
                // The explicit simulated descriptor fixture uses the existing local picker path.
                // It never creates transport authority or sends a native command.
                applyPickerValue(value, for: picker)
                return
            }
        #endif
        guard let native = cameraSession, let owner = native.commandOwner,
            let common = controlSession, common.id == identity.source.camera,
            reportedRecording == false
        else { return }
        let current = common.refresh()
        guard current.epoch == identity.source.epoch, current.connection == .ready,
            current.authority == identity.authority
        else { return }
        let revision = operatorQuickPresentationRevision
        let valid = OSAllocatedUnfairLock(initialState: true)
        let admission = NikonCommandAdmission(
            owner: owner, isCurrent: { valid.withLock { $0 } })
        guard queuePickerWrites(value, for: picker, admission: admission) > 0 else { return }
        // The queue's optimistic mutation is complete. No actor suspension occurs before this
        // observation is installed, including when the queue schedules an idle drain task.
        withObservationTracking {
            let current =
                cameraSession === native && operatorQuickPresentationRevision == revision
                && isMonitorPresented && !screenWakeSuppressedForBackground
                && reportedRecording == false && operatorNativeQuickAdmits(identity, target: value)
            if !current { valid.withLock { $0 = false } }
        } onChange: {
            // Observation may notify before the mutation completes. Revoke immediately without
            // reading actor-isolated state from a transport predicate or another executor.
            valid.withLock { $0 = false }
        }
    }

    func applyPickerValue(_ value: String, for picker: CameraPicker) {
        applyPickerValue(value, for: picker, admission: nil)
    }

    private func applyPickerValue(
        _ value: String, for picker: CameraPicker, admission: NikonCommandAdmission?
    ) {
        guard admitsCameraCommand(admission) else { return }
        if videoSource == .relay {
            guard relayHoldsControl else { return }
            relayClient?.send(
                command: .pickerValue(picker: picker.rawValue, value: value))
            return
        }
        guard !relayControlSurrendered else { return }
        guard !isDemoSession else {
            applyLocalPickerValue(value, for: picker)
            return
        }
        if picker == .shutter, lockedControls.contains(.shutter) { return }
        if picker == .iso, isISORecordingLocked { return }
        if let nikon = picker.nikonControlSetting,
            let setting = NikonCameraSession.setting(nikon, label: value),
            shell.control.session != nil, !pictureOnlyMonitor
        {
            refreshCommonControlFacts()
            if let admission {
                guard let dispatch = sharedCommandAdmission(admission) else { return }
                // A watcher supplies its own target; the unattended local editor is unrelated.
                shell.control.set(setting, label: "\(picker.title) \(value)", admission: dispatch)
            } else if let commonEditor {
                guard
                    shell.control.commit(
                        setting, from: commonEditor, label: "\(picker.title) \(value)")
                else { return }
            } else {
                shell.control.set(setting, label: "\(picker.title) \(value)")
            }
            return
        }
        queuePickerWrites(value, for: picker, admission: admission)
    }

    /// Encodes a picker value onto the coalescing write queue (optimistic bar update, safe-point
    /// write, readback). Returns the number of property writes queued.
    @discardableResult
    func queuePickerWrites(
        _ value: String, for picker: CameraPicker
    ) -> Int {
        queuePickerWrites(value, for: picker, admission: nil)
    }

    @discardableResult
    private func queuePickerWrites(
        _ value: String, for picker: CameraPicker, admission: NikonCommandAdmission?
    ) -> Int {
        guard admitsCameraCommand(admission) else { return 0 }
        guard let cameraControl = picker.cameraControl else {
            connectionMessage =
                "\(picker.title) is not wired to a verified Nikon property write yet."
            return 0
        }
        // All writes go through the safe-point queue. Resolution/frame-rate writes the *exact*
        // camera-advertised mode for the picked label — never a hand-packed value; a wrong
        // combination like 6K@60 makes the ZR close the connection. A Kelvin white balance
        // enqueues two writes (colour-temperature mode, then the temperature). Recording format is
        // written *during* live view via the standard SetDevicePropValue (0x1016) — no teardown.
        let writes: [PTPCameraPropertyWrite]
        if cameraControl == .resolution {
            let codec = cameraPropertySnapshot.fileType
            // Precedence, not a first-match-any: the crop-insensitive comparison would otherwise
            // return the FX mode for a picked `[DX]` label. See `pickedModeIndex`.
            guard
                let index = NikonZRRawCropPresentation.pickedModeIndex(
                    for: value,
                    presentationLabels: cameraScreenModes.map {
                        screenSizePresentationLabel(for: $0, codec: codec)
                    },
                    modeLabels: cameraScreenModes.map(\.label)),
                index < cameraScreenModes.count
            else {
                connectionMessage =
                    "\(value) isn't a recording mode the camera reported — pick a listed one."
                return 0
            }
            writes = [PTPCameraPropertyWrite.screenSize(raw: cameraScreenModes[index].raw)]
        } else if cameraControl == .codec {
            guard let mode = codecMode(forPickedLabel: value) else {
                connectionMessage =
                    "\(value) isn't a codec the camera reported — pick a listed one."
                return 0
            }
            writes = [PTPCameraPropertyWrite.fileType(raw: mode.raw)]
        } else {
            writes = PTPCameraPropertyWrite.requests(
                control: cameraControl, label: value, snapshot: cameraPropertySnapshot)
        }
        guard !writes.isEmpty else {
            connectionMessage =
                "\(picker.title) value \(value) could not be encoded for \(cameraControl)."
            return 0
        }
        for write in writes {
            enqueueCameraWrite(
                PendingCameraWrite(picker: picker, value: value, write: write, admission: admission)
            )
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
        return writes.count
    }

    private func applyLocalPickerValue(_ value: String, for picker: CameraPicker) {
        if picker.isStillPicker {
            // The stills strip reads the property snapshot (not `cameraState.values`), so the
            // demo applies the encoded write optimistically — the exact bytes a live body would
            // round-trip.
            guard let control = picker.cameraControl,
                let write = PTPCameraPropertyWrite.request(control: control, label: value)
            else { return }
            cameraPropertySnapshot = cameraPropertySnapshot.applying(
                property: write.property, data: write.data)
            publishCameraDisplayState()
            return
        }
        // Codec picks also land in the property snapshot when the staged descriptor can name the
        // pick, exactly as a body's readback would — that is what the CODEC bit-depth pair reads
        // to fill the active side, so without it the demo shows a pair that never moves.
        if picker == .codec, let mode = codecMode(forPickedLabel: value) {
            cameraPropertySnapshot = cameraPropertySnapshot.applying(
                property: .movieFileType,
                data: PTPCameraPropertyWrite.fileType(raw: mode.raw).data)
        }
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

// The shared shell's app composition. Command, receipt and pending-edit ownership is shared: the
// capture readouts read the control's pending targets directly instead of copying them.
extension NativeAppModel {
    func makeShellModel() -> ShellModel {
        let shell = ShellModel(cameras: cameras)
        shell.onSceneActivity = { [weak self] active in
            if active { self?.enterForeground() } else { self?.enterBackground() }
        }
        shell.control.onNote = { [weak self] in self?.showMonitorNotice($0) }
        return shell
    }

    /// The movie capture values as shown: an unfinished common edit (the shared control's pending
    /// target) over the camera's reported value.
    var shownCameraValues: [CameraValue] {
        Self.showing(shell.control.pending, over: cameraState.values)
    }

    func shownCameraValue(_ label: String) -> String? {
        shownCameraValues.first { $0.label == label }?.value
    }

    static func showing(_ pending: [SettingKey: SettingValue], over values: [CameraValue])
        -> [CameraValue]
    {
        guard !pending.isEmpty else { return values }
        var shown: [String: String] = [:]
        for value in pending.values {
            guard let (setting, label) = NikonCameraSession.settingValue(for: value) else {
                continue
            }
            shown[CameraPicker(setting).valueLabel] = label
        }
        return values.map { item in
            shown[item.label].map {
                CameraValue(label: item.label, value: $0, isSettable: item.isSettable)
            } ?? item
        }
    }

    private func bindMonitorRuntime(_ session: NativeCameraSession) {
        feedIncidentProducer?.end()
        feedIncidentProducer = nil
        // Lent multicam, demo and editor shells never retire a canonical incident source.
        if multicam.lentMember == nil, !isDemoSession {
            let source = ReliabilityDiagnostics.incidents.beginBoundSession(
                ReliabilityDiagnostics.incidents.sessionContext(cameraFamily: "nikon"))
            feedIncidentProducer = NikonFeedIncidentProducer(source: source)
        }
        if let monitorRuntime {
            monitorRuntime.replaceLink(session)
        } else {
            let runtime = NikonMonitorRuntime(link: session, ownsLink: multicam.lentMember == nil)
            runtime.onReadback = { [weak self, weak runtime] write, readback in
                guard let self, monitorRuntime === runtime else { return }
                if let readback { applyCameraRead(write.property, readback) }
                publishCameraDisplayState()
            }
            runtime.onRecordQueued = { [weak self, weak runtime] start in
                guard let self, monitorRuntime === runtime else { return }
                isRecording = start
                pendingRecordToggle = true
                appRecordCommandAt = Date()
                cameraState = cameraState.updating(recordState: start ? .recording : .standby)
                publishWatchState()
            }
            runtime.onRecordCommand = { [weak self, weak runtime] _, accepted in
                guard let self, monitorRuntime === runtime else { return }
                pendingRecordToggle = false
                appRecordCommandAt = Date()
                if accepted {
                    applyThermalStreamStepDownIfNeeded()
                } else if let reportedRecording {
                    isRecording = reportedRecording
                    cameraState = cameraState.updating(
                        recordState: reportedRecording ? .recording : .standby)
                }
            }
            runtime.onClosed = { [weak self, weak runtime] _ in
                guard let self, monitorRuntime === runtime else { return }
                clearCameraSessionState(resetConnection: true)
            }
            monitorRuntime = runtime
        }
        refreshCommonControlFacts()
    }

    /// Every monitor is the shell's, so `AppShell` is its one mount and its covers serve every
    /// source (A1-01, A2-01): the camera's own session, or a picture-only session for a relay
    /// watcher, a capture card or the demo.
    private func ensureShellMonitor() {
        guard isMonitorPresented else { return }
        guard let cameraSession, let controlSession else {
            guard shell.monitor == nil else { return }
            shell.present(
                ConnectedCamera(saved: pictureSourceRecord, session: NikonPictureSourceSession()))
            return
        }
        guard shell.monitor?.session.id != controlSession.id else { return }
        cameras.reloadSaved()
        let identity = cameraSession.identity
        let saved = Self.shellCamera(
            host: cameraSession.host, name: identity.displayName, model: identity.model,
            serial: identity.serialNumber, saved: cameras.saved,
            legacy: NikonSavedRecordsV0.cameras(from: savedCameras))
        let camera = ConnectedCamera(
            saved: saved, session: controlSession, services: currentMediaServices())
        if multicam.lentMember != nil {
            shell.borrow(camera) { [weak self] in self?.returnToMulticam() }
        } else {
            shell.present(camera)
        }
    }

    /// The saved camera the shell presents for a session on `host`. A camera nothing saved yet
    /// is presented by its session's own identity, never persisted here (A2-01).
    static func shellCamera(
        host: String, name: String, model: String, serial: String, saved: [SavedCamera],
        legacy: [SavedCamera]
    ) -> SavedCamera {
        if let camera = (saved + legacy).first(where: { camera in
            camera.routes.contains { $0.extras[NikonSavedRecordsV0.Extra.host] == host }
        }) {
            return camera
        }
        let serial = serial.trimmingCharacters(in: .whitespaces)
        return SavedCamera(
            id: serial.isEmpty ? "session:" + host : "serial:" + serial,
            integration: NikonCameraSession.integration,
            device: serial.isEmpty
                ? nil : .durable(serial, integration: NikonCameraSession.integration),
            advertisedName: name, model: model)
    }

    /// The shell's record for a picture-only monitor; never saved.
    private var pictureSourceRecord: SavedCamera {
        let name =
            switch videoSource {
            case .relay: relayJoinTarget?.name ?? "Relay"
            case .hdmiCapture: "HDMI capture"
            case .cameraLiveView: cameraState.cameraName
            }
        return SavedCamera(
            id: "picture:" + videoSource.rawValue, integration: NikonCameraSession.integration,
            advertisedName: name, model: "")
    }

    /// The monitor shows a picture with no camera control here: a relay watcher forwards its
    /// commands over the relay, and a capture card or the demo has none.
    var pictureOnlyMonitor: Bool { shell.control.session is NikonPictureSourceSession }

    private func refreshCommonControlFacts() {
        monitorRuntime?.updateFacts(nikonControlFacts)
    }

    /// A movie strip value from the common seam. Movie Auto ISO shows the body's working ISO
    /// ("A3200"), as the baseline strip did; the common vocabulary carries only "Auto".
    func commonReadoutLabel(_ value: SettingValue) -> String {
        if value == .iso(.auto),
            let working = ISOPickerPolicy.autoISOLabel(
                iso: reportedPropertySnapshot.iso.map { Int($0) },
                isoAuto: reportedPropertySnapshot.isoAuto,
                codec: reportedPropertySnapshot.fileType ?? "")
        {
            return working
        }
        return MonitorCapturePresentation.label(value)
    }

    var nikonControlFacts: NikonControlFacts {
        let photography = StillCapturePolicy.prefersPhotographyChrome(
            selector: reportedPropertySnapshot.captureSelector)
        // The same preset list the WB picker offers (`PickerPanel`): the body's advertised enum
        // for the active chrome, else the picker's own list, R3D-filtered in movie chrome.
        let fallback = CameraPicker.whiteBalance.modes.first { $0.title == "Preset" }?.options ?? []
        let presets =
            photography
            ? (cameraControlOptions[.whiteBalance] ?? fallback)
            : PTPCameraPropertyDecoders.whiteBalanceOptions(
                advertised: cameraControlOptions[.movieWhiteBalance] ?? fallback,
                codec: cameraState.codec)
        return NikonControlFacts(
            holdsControl: !relayControlSurrendered,
            liveViewReady: isMonitorPresented,
            reported: reportedPropertySnapshot,
            recording: reportedRecording,
            whiteBalancePresets: presets,
            shutterLabels: {
                switch reportedPropertySnapshot.shutterMode {
                case .angle:
                    advertisedExposureOptions[.movieShutterAngle] ?? []
                case .speed:
                    advertisedExposureOptions[.movieShutterSpeed] ?? []
                // No `MovieShutterMode` (non-ZR bodies): the encoder writes by label shape.
                case nil:
                    (advertisedExposureOptions[.movieShutterAngle] ?? [])
                        + (advertisedExposureOptions[.movieShutterSpeed] ?? [])
                }
            }(),
            apertureLabels: advertisedExposureOptions[.movieFNumber] ?? [],
            storage: lastKnownStorage)
    }

}

extension CameraDisplayState {
    func updating(
        recordState: RecordState? = nil,
        resolutionFrameRate: String? = nil,
        codec: String? = nil,
        media: String? = nil,
        cameraBatteryPercent: Int? = nil,
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
    // Photography (stills) pickers — same drum popups, stills PTP properties. The movie pickers
    // above write movie properties and stay untouched in photo mode.
    case stillMode
    case stillISO
    case stillShutter
    case stillIris
    case stillDrive
    case stillFocus
    case stillMeter
    case stillSize
    case stillQuality
    case stillPicture

    var id: String { rawValue }

    /// Whether this is one of the photography (stills) pickers.
    var isStillPicker: Bool {
        switch self {
        case .stillMode, .stillISO, .stillShutter, .stillIris, .stillDrive, .stillFocus,
            .stillMeter, .stillSize, .stillQuality, .stillPicture:
            true
        default:
            false
        }
    }

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
        case .stillMode: "Mode"
        case .stillISO: "ISO"
        case .stillShutter: "Shutter"
        case .stillIris: "Iris"
        case .stillDrive: "Drive"
        case .stillFocus: "Focus"
        case .stillMeter: "Metering"
        case .stillSize: "Image Size"
        case .stillQuality: "Image Quality"
        case .stillPicture: "Profile"
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
        case .stillMode: "Exposure program"
        case .stillISO: "Sensitivity"
        case .stillShutter: "Speed"
        case .stillIris: "Aperture"
        case .stillDrive: "Release mode"
        case .stillFocus: "AF mode"
        case .stillMeter: "Metering pattern"
        case .stillSize: "Area · size"
        case .stillQuality: "RAW · JPEG/HEIF"
        case .stillPicture: "Picture control"
        }
    }

    var valueLabel: String {
        switch self {
        case .iso, .stillISO: "ISO"
        case .shutter, .stillShutter: "SHUTTER"
        case .iris, .stillIris: "IRIS"
        case .whiteBalance: "WB"
        case .focus, .stillFocus: "FOCUS"
        case .resolution: "RESOLUTION"
        case .codec: "CODEC"
        case .stabilization: "STAB"
        case .mode, .stillMode: "MODE"
        case .audio: "AUDIO"
        case .stillDrive: "DRIVE"
        case .stillMeter: "METER"
        case .stillSize: "SIZE"
        case .stillQuality: "QUAL"
        case .stillPicture: "PROFILE"
        }
    }

    /// Reverse lookups from a `valueLabel` (capture-bar / top-deck cell label) to its picker, built
    /// once — the capture bar re-evaluates per frame, so a per-cell linear scan is too hot. The
    /// movie and stills strips reuse labels (ISO/SHUTTER/IRIS/FOCUS/MODE), so each chrome has its
    /// own map.
    private static let byValueLabel: [String: CameraPicker] =
        Dictionary(
            uniqueKeysWithValues: allCases.filter { !$0.isStillPicker }.map { ($0.valueLabel, $0) })
    private static let byStillValueLabel: [String: CameraPicker] =
        Dictionary(
            uniqueKeysWithValues: allCases.filter(\.isStillPicker).map { ($0.valueLabel, $0) })

    /// The picker whose `valueLabel` equals `label`, or nil. `photography` selects the stills
    /// pickers for the photo-mode strip; the movie map stays the default. WB deliberately
    /// reuses the movie picker in photography — identical popup, with the writes routed to
    /// the stills WB properties by the snapshot's selector.
    static func forValueLabel(_ label: String, photography: Bool = false) -> CameraPicker? {
        guard photography else { return byValueLabel[label] }
        if label == "WB" { return .whiteBalance }
        return byStillValueLabel[label]
    }

    /// Whether this picker is presented from the *top* information deck (dropping down) rather than
    /// the bottom capture bar (rising up). Resolution and codec live in the top deck, as does the
    /// photo SIZE pill; everything else is a bottom-bar exposure setting. Both use the identical
    /// `PickerPanel` drum — only the anchor and slide direction differ.
    var isTopBar: Bool {
        switch self {
        case .resolution, .codec, .stillSize, .stillQuality: true
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
        case .stillMode:
            // Same shared `ExposureProgramMode` (0x500E) property the command MODE tile writes.
            .exposureMode
        case .stillISO:
            .stillISO
        case .stillShutter:
            .stillShutter
        case .stillIris:
            .stillIris
        case .stillDrive:
            .stillDrive
        case .stillFocus:
            .stillFocus
        case .stillMeter:
            .stillMeter
        case .stillSize:
            // Two independent camera settings chosen by tab (area crop / size string) — routed
            // per mode in `applyPicker`, like FOCUS.
            nil
        case .stillQuality:
            .stillQuality
        case .stillPicture:
            .stillPictureControl
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
        // Conservative fallback only — the drum prefers the body's own `ExposureProgramMode`
        // enum (see `optionProperty(forMode:)`). No U banks here: a body that has them
        // advertises them, and inferring them from generic photo capability offered a Zf
        // three user modes it does not own (#274).
        case .mode: PTPCameraPropertyDecoders.exposureProgramFallbackOptions
        case .audio: ["Auto"] + (1...20).map(String.init)
        case .stillMode: PTPCameraPropertyDecoders.exposureProgramFallbackOptions
        case .stillISO: StillPickerLadders.isoOptions
        case .stillShutter: StillPickerLadders.shutterOptions
        case .stillIris: StillPickerLadders.irisOptions
        // The label union across the lineup minus the dial-only Quick position and the on-body
        // Self-timer (the app-side Timer tab owns countdowns — a remote release never runs the
        // body's); a body that lacks one rejects the write and the rejection surface handles it.
        case .stillDrive: StillPickerLadders.driveOptions
        case .stillFocus: StillPickerLadders.focusModeOptions
        case .stillMeter: StillPickerLadders.meterOptions
        // SIZE is modes-driven (Area | Size tabs).
        case .stillSize: []
        // The `CompressionSetting` ladder minus the ★ size-priority variants and TIFF —
        // labels round-trip through `PTPCameraPropertyDecoders.compressionSetting`.
        case .stillQuality: StillPickerLadders.qualityOptions
        // The full picture-control set: built-ins, the creative looks, and the custom and
        // downloaded cloud slots (a slot with nothing registered rejects through the
        // queue's surface).
        case .stillPicture: StillPickerLadders.pictureOptions
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
                    title: "Angle", options: ShutterPickerPolicy.angleOptions,
                    base: ShutterPickerPolicy.angleBase),
                PickerMode(
                    title: "Speed", options: ShutterPickerPolicy.speedOptions,
                    base: ShutterPickerPolicy.speedBase),
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
                    title: "AF Mode", options: FocusPickerPolicy.afModeOptions,
                    base: FocusPickerPolicy.afModeBase),
                PickerMode(
                    title: "Area", options: FocusPickerPolicy.areaOptions,
                    base: FocusPickerPolicy.areaBase),
                PickerMode(
                    title: "Subject", options: FocusPickerPolicy.subjectOptions,
                    base: FocusPickerPolicy.subjectBase),
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
        case .stillSize:
            // Two independent stills settings chosen by tab: the sensor-crop image area and the
            // pixel-count image size.
            [
                PickerMode(title: "Area", options: StillPickerLadders.areaOptions, base: "FX"),
                PickerMode(title: "Size", options: StillPickerLadders.sizeOptions, base: "Size L"),
            ]
        case .stillDrive:
            // Release mode plus two timers: Built-in engages the body's self-timer release
            // mode (its delay and shot count come from the camera menu — no remote property
            // exposes them), and App is the in-app countdown with a wider ladder. A remote
            // release never runs the body's countdown, so the two are complementary.
            [
                PickerMode(
                    title: "Drive", options: StillPickerLadders.driveOptions, base: "Single"),
                PickerMode(title: "Built-in Timer", options: ["Off", "On"], base: "Off"),
                PickerMode(
                    title: "App-timer", options: StillPickerLadders.appTimerOptions, base: "Off"),
            ]
        case .stillISO:
            // Auto hands sensitivity to the body (the drum tracks its live pick, locked);
            // Manual writes the stills ISO ladder — mode-aware, so the full-auto programs
            // never offer it.
            [
                PickerMode(title: "Auto", options: CameraPicker.stillISO.options, base: "800"),
                PickerMode(title: "Manual", options: CameraPicker.stillISO.options, base: "800"),
            ]
        case .stillFocus:
            // AF mode, AF-area, and subject detection — three independent stills settings by
            // tab, mirroring the movie FOCUS picker.
            [
                PickerMode(
                    title: "Mode", options: StillPickerLadders.focusModeOptions, base: "AF-S"),
                PickerMode(
                    title: "Area", options: StillPickerLadders.focusAreaOptions, base: "Single"),
                PickerMode(
                    title: "Subject", options: StillPickerLadders.focusSubjectOptions,
                    base: "Auto"),
            ]
        case .stillMode:
            // The main program drum plus the U banks' inner program — settable only while a
            // bank is active, so the tab grays otherwise.
            [
                PickerMode(title: "Mode", options: CameraPicker.stillMode.options, base: "P"),
                PickerMode(title: "U Mode", options: StillPickerLadders.userModeOptions, base: "P"),
            ]
        case .iris, .resolution, .codec, .stabilization, .mode,
            .stillShutter, .stillIris, .stillMeter,
            .stillQuality, .stillPicture:
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
        case .stillSize:
            // The Size tab's strings come straight from the camera's ImageSize enum (bodies
            // report resolutions, and the set reshapes with the area crop); Area stays the
            // fixed crop ladder.
            return mode == 1 ? .imageSize : nil
        case .stillShutter:
            // The body enumerates the stills speeds valid for the active program/flash
            // state — the drum follows it, with the hardcoded ladder as fallback.
            return .stillShutterSpeed
        // Photo-mode function pickers. Each body advertises its own value set and its own order
        // for these; sourcing them from a fixed union is what offered a Zf the U banks it does
        // not have and ordered the Z6III's drive wheel CH before CL (#274).
        case .mode:
            return .exposureProgramMode
        case .stillMode:
            // Mode tab = the program enum; U Mode tab = the bank's inner program.
            return mode == 0 ? .exposureProgramMode : .userMode
        case .stillDrive:
            // Only the Drive tab is a camera enum — the two Timer tabs are app state.
            return mode == 0 ? .stillCaptureMode : nil
        case .stillFocus:
            switch mode {
            case 0: return .stillFocusMode
            case 1: return .stillFocusMeteringMode
            case 2: return .afSubjectDetection
            default: return nil
            }
        case .stillMeter:
            return .exposureMeteringMode
        case .stillQuality:
            return .compressionSetting
        case .stillPicture:
            return .activePicCtrlItem
        case .iso, .iris, .resolution, .codec, .stabilization, .stillISO, .stillIris:
            // ISO circuits switch via `movieBaseISO`; IRIS, resolution and codec have their own
            // dedicated descriptor paths; stabilization renders its own panel.
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

/// The root's live tree: the multicam stage, or the shell with its monitor, pages and covers.
/// Every monitor is the shell's, so this is its one mount (A1-01).
struct NativeRootContent: View {
    @Environment(NativeAppModel.self) private var model

    var body: some View {
        if let review = DemoHarness.stabilizationReview() {
            review
        } else if let review = DemoHarness.connectConsentReview() {
            review
        } else {
            ZStack {
                if model.multicam.isPresented {
                    MulticamStage(
                        coordinator: model.multicam,
                        confirmsRecord: model.preferences.recordConfirmationEnabled,
                        pickerRows: model.multicamPickerRows,
                        openLiveView: model.openMulticamLiveView,
                        close: model.endMulticam
                    )
                    .multiviewStageVisible(model.shell.monitor == nil)
                    .opacity(model.shell.monitor == nil ? 1 : 0)
                    .allowsHitTesting(model.shell.monitor == nil)
                    .accessibilityHidden(model.shell.monitor != nil)
                }
                if !model.multicam.isPresented || model.shell.monitor != nil {
                    LinkExperience()
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                }
            }
        }
    }
}

struct NativeAppRoot: View {
    @State private var model = NativeAppModel()
    @State private var showsLaunchSplash = true
    @State private var startup: MonitorAppStartup

    init(startup: MonitorAppStartup? = nil) {
        _startup = State(
            initialValue: startup
                ?? MonitorAppStartup(
                    reports: .init(
                        reporting: ReliabilityDiagnostics.reporting,
                        tick: { ReliabilityDiagnostics.problemReporting.tick() }),
                    sleep: Self.startupSleep(for:)))
    }

    /// The startup lifetime's waits. A UI test may hold the launch splash for longer
    /// (`ZC_DEMO_SPLASH_HOLD_MS`, Debug only), so its covered state can still be sampled on a
    /// host where launching takes longer than the splash shows; every other wait is unchanged.
    private static func startupSleep(for duration: Duration) async throws {
        if duration == LaunchSplashTiming.visibleDuration, let hold = DemoHarness.launchSplashHold {
            try await hostSleep(for: hold)
        } else {
            try await hostSleep(for: duration)
        }
    }

    var body: some View {
        ZStack {
            MonitorTheme.background.ignoresSafeArea()
            NativeRootContent()

            MonitorOperatorDeliveryChrome(
                model: model.delivery.lifetime, scope: .root, remoteDisplayName: "Frame.io"
            ).zIndex(150)

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
        // The one share sheet, above every cover (A2-52).
        .monitorDeliverySharePresenter(model.delivery.lifetime)
        .monitorHDRDisplay(
            .app, active: model.hdrDisplayActive, screenCaptured: Bindable(model).screenCaptured
        )
        .environment(model)
        .environment(model.delivery)
        .observeMonitorWindowGeometry()
        // Root-level (not inside the LUT picker) so the cover survives the monitor collapsing
        // when the RED internet hop tears the camera session down mid-download.
        .fullScreenCover(isPresented: redDownloadPresented) {
            RedDownloadView { url in await model.importRedZip(from: url) }
                .environment(model)
        }
        .sheet(
            isPresented: Binding(
                get: { model.gyroCapture.logsPresented },
                set: { model.gyroCapture.logsPresented = $0 }
            )
        ) { GyroLogsView(coordinator: model.gyroCapture) }
        .sheet(
            isPresented: Binding(
                get: { model.gyroCapture.mountPresented },
                set: { model.gyroCapture.mountPresented = $0 }
            )
        ) { GyroMountView(coordinator: model.gyroCapture) }
        .sheet(isPresented: bugReportPresented) { ProblemReportView() }
        .monitorAppStartup(startup, splashVisible: $showsLaunchSplash) { choice in
            ReliabilityConsentPrompt(onChoice: choice)
        }
        .onChange(of: model.shell.cover) { old, new in
            model.noteShellCoverChange(from: old, to: new)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MonitorTheme.background.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
        .monitorBrowserHandoffReturn(model.browserHandoff)
        .task {
            // Activate the Apple Watch companion relay once on launch. No-ops when no watch is
            // paired/reachable or WatchConnectivity is unsupported.
            _ = model.shell
            model.activateWatchRelay()
        }
        .task {
            // Suspend the live-view pipeline, keepalive, event drain, and discovery while backgrounded
            // (battery/thermal/jetsam). Lives for the app's lifetime. async/await, not Combine.
            for await _ in NotificationCenter.default.notifications(
                named: UIApplication.didEnterBackgroundNotification)
            {
                model.shell.setSceneActive(false)
            }
        }
        .task {
            // Resume the session's loops (and live view if it was up) on return to the foreground.
            for await _ in NotificationCenter.default.notifications(
                named: UIApplication.willEnterForegroundNotification)
            {
                model.shell.setSceneActive(true)
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
            await DemoHarness.applyLaunchEnvironment(to: model)
        }
    }
    private var redDownloadPresented: Binding<Bool> {
        Binding(
            get: { model.isRedDownloadPresented },
            set: { model.isRedDownloadPresented = $0 }
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

    var mediaFilterOptions: NikonMediaFilterOptions { mediaProjectionPass.filterOptions }
    var mediaGalleryProjection: NikonAppGalleryProjection {
        let pass = mediaProjectionPass
        mediaProjectionSnapshot = pass
        return pass
    }
    var filteredMediaClips: [MediaClip] { mediaGalleryProjection.gridClips }
    func burstSeries(for clip: MediaClip) -> BurstSeries? {
        mediaProjectionSnapshot?.series(for: clip)
    }
    func burstMembers(of clip: MediaClip) -> [MediaClip] {
        mediaProjectionSnapshot?.members(of: clip, current: mediaClips) ?? []
    }
    func burstExpanded(_ clips: [MediaClip]) -> [MediaClip] {
        mediaProjectionSnapshot?.expanded(clips, current: mediaClips)
            ?? NikonAppGalleryProjection.ungroupedExpanded(clips)
    }
    /// Unfiltered source pairing remains separate from visible grid representatives.
    func rawSibling(of clip: MediaClip) -> MediaClip? {
        NikonAppGalleryProjection.rawSibling(of: clip, in: mediaClips)
    }
    /// `rawSibling(of:)` for a whole grid in one pass: the ids that have a RAW companion.
    func rawPairedClipIDs(_ clips: [MediaClip]) -> Set<String> {
        NikonAppGalleryProjection.rawPairedIDs(clips, in: mediaClips)
    }
    /// Grid count per category under the current filters, from the last grid projection.
    func mediaCategoryCount(_ category: MediaCategoryTab) -> Int {
        mediaProjectionSnapshot?.count(in: category) ?? 0
    }

    /// Active chip filters (format, resolution, size, date, storage slot) — not category tabs.
    var mediaActiveFilterCount: Int {
        MediaBrowserFilterMetrics.activeCount(
            formatFilters: mediaFormatFilters,
            resolutionFilters: mediaResolutionFilters,
            photoSizeFilters: mediaPhotoSizeFilters,
            dateWindow: mediaDateWindow,
            storageSlotFilter: mediaStorageSlotFilter
        )
    }

    /// Clears popup filter state; category tab and sort are unchanged.
    func clearMediaFilters() {
        mediaFormatFilters = []
        mediaResolutionFilters = []
        mediaPhotoSizeFilters = []
        mediaDateWindow = nil
        mediaStorageSlotFilter = nil
    }

    /// Drops any active chip the current tab no longer offers.
    ///
    /// Switching from Videos to Photos must not leave an invisible MOV filter behind — the grid
    /// would go empty with nothing in the popup explaining why. Storage slots are deliberately
    /// untouched: they are scoped by the inserted cards, not by the tab's media.
    func pruneMediaFiltersToOfferedChips() {
        let offered = mediaFilterOptions
        mediaFormatFilters.formIntersection(offered.formats)
        mediaResolutionFilters.formIntersection(offered.resolutions)
        mediaPhotoSizeFilters.formIntersection(offered.photoSizes)
        if let window = mediaDateWindow, !offered.dateWindows.contains(window) {
            mediaDateWindow = nil
        }
    }

    /// Cycles newest → oldest → name.
    func cycleMediaSortOrder() {
        mediaSortOrder = mediaSortOrder.next
    }

    func toggleMediaFormatFilter(_ filter: MediaFormatChip) {
        mediaFormatFilters.formSymmetricDifference([filter])
    }

    func toggleMediaResolutionFilter(_ bucket: NikonMediaResolutionBucket) {
        mediaResolutionFilters.formSymmetricDifference([bucket])
    }

    func toggleMediaPhotoSizeFilter(_ size: NikonMediaPhotoSizeClass) {
        mediaPhotoSizeFilters.formSymmetricDifference([size])
    }

    /// Date windows nest, so selecting one replaces the other; tapping the active one clears it.
    func toggleMediaDateWindow(_ window: NikonMediaDateWindow) {
        mediaDateWindow = mediaDateWindow == window ? nil : window
    }

    /// Preserves the original per-appearance storage read through the actual source producer.
    func refreshMediaStorageSlots() async {
        guard let service = currentMediaService() else {
            mediaStorageSlots = []
            return
        }
        do {
            try await service.refreshStorage()
            guard mediaProducer?.service === service, isConnected else { return }
            mediaStorageSlots = NikonMediaCatalogAdapter.displayStorage(
                service.storageRecords, cameraName: cameraState.cameraName)
        } catch {
            // A retired source cannot update successor capacity cards.
        }
    }

    /// Reloads the library list from the on-disk cache + index for the active browser bucket.
    func refreshMediaClips() {
        let bucket = mediaBrowserSource == .camera ? mediaBucketID : MediaClipStore.localBucketID
        let rows: [MediaClip]
        if !isConnected, mediaBrowserSource == .camera {
            rows = mediaClipStore.listAllCachedClips()
        } else {
            rows = mediaClipStore.list(cameraID: bucket)
        }
        prepareMediaLibrary(
            rows: rows, bucket: bucket,
            service: isConnected && mediaBrowserSource == .camera ? currentMediaService() : nil)
    }

    /// Cancels any in-flight listing pass and starts a fresh camera discovery.
    /// `identityProbeBudget` caps how many reused handles are `GetObjectInfo`'d to
    /// catch a formatted card that recycled PTP handles (#296).
    func scheduleFetchClipsFromCamera(identityProbeBudget: Int = 8) {
        guard let owner = prepareCameraMediaListing(identityProbeBudget: identityProbeBudget) else {
            return
        }
        if owner.browsing { owner.refresh() } else { owner.begin() }
    }

    /// Only the exact finished deletion may carry its photo return through this planned relist.
    func scheduleFetchClipsFromCamera(
        afterDeletion authority: MonitorMediaLibraryDeletionAuthority,
        identityProbeBudget: Int = 8
    ) async {
        guard authority.isCompleting, let captured = mediaLibrary,
            captured.cache.directory === authority.directory
        else { return }
        guard let owner = prepareCameraMediaListing(identityProbeBudget: identityProbeBudget),
            owner === captured, authority.isCompleting
        else { return }
        await owner.relist(after: authority)
    }

    private func prepareCameraMediaListing(identityProbeBudget: Int) -> MonitorMediaLibraryModel<
        MediaClip
    >? {
        guard let service = currentMediaService() else { return nil }
        let bucket = mediaBucketID
        let cached = mediaClipStore.list(cameraID: bucket)
        service.configure(
            .init(
                cached: NikonMediaCatalogAdapter.records(cached),
                pairing: NikonMediaCatalogAdapter.pairingRecords(cached),
                category: mediaCategoryTab.nikonMediaCategory,
                identityProbeBudget: identityProbeBudget,
                retainedLocalFilenames: Set(
                    cached.filter { self.retainsLocalMediaClip($0) }.map(\.filename))))
        prepareMediaLibrary(rows: cached, bucket: bucket, service: service)
        return mediaLibrary
    }

    /// Operator Refresh: probe every reused handle so a recycled PTP generation cannot
    /// keep stale filenames. Automatic listing uses the smaller default budget.
    func refreshCameraMediaInventory() {
        scheduleFetchClipsFromCamera(identityProbeBudget: Int.max)
    }

    /// Coalesces ObjectAdded bursts while the gallery is open into one listing pass.
    private func scheduleDebouncedGalleryRelist() {
        galleryRelistTask?.cancel()
        galleryRelistTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled, isStandaloneMediaLibraryPresented else { return }
            scheduleFetchClipsFromCamera()
        }
    }

    /// Legacy indexed-and-browsable clip bytes across camera buckets, excluding local media.
    /// Indexed masters can remain after Clear drops their index; preserve that existing readout.
    func totalMediaCacheByteCount() async throws -> UInt64 {
        let addresses = try await mediaClipStore.cameraCacheReadAddresses()
        return try await mediaCacheDirectory.selectedByteCount(addresses)
    }

    /// The common settings owner counts and clears this canonical all-camera cache only.
    func captureOperatorMediaCacheSource() -> MonitorSettingsCacheSource {
        let root = mediaClipStore.root
        let revision = mediaActionStoreGeneration
        // Delivery exports nothing holds count and clear with it (A2-58).
        return delivery.cacheSource(
            .init(
                identity: .init(namespace: root.path, source: nil), revision: revision,
                isCurrent: { [weak self] in self?.mediaClipStore.root == root },
                count: { [weak self] in (try? await self?.totalMediaCacheByteCount()) ?? 0 },
                clear: { [weak self] in
                    guard let self, self.mediaClipStore.root == root,
                        self.mediaActionStoreGeneration == revision
                    else {
                        throw CancellationError()
                    }
                    try self.clearAllMediaCaches()
                },
                readObserved: { [weak self] in
                    guard let self else { return nil }
                    return try await self.totalMediaCacheByteCount()
                }))
    }

    /// UI actions keep the actual relay source, lease revision and request peer they displayed.
    func captureOperatorSettingsWatchers() -> MonitorSettingsWatchersSource? {
        guard isRelayBroadcasting, let host = relayHost else { return nil }
        let source = host.sourceToken
        let revision = host.controlRevision
        let current: () -> Bool = { [weak self, weak host] in
            guard let self, let host else { return false }
            return self.relayHost === host && host.sourceToken == source
                && host.controlRevision == revision
        }
        let request = relayPendingControlRequest.flatMap {
            name -> MonitorSettingsWatchersSource.Request? in
            guard let captured = relayPendingRequest, host.pendingRequest == captured else {
                return nil
            }
            return .init(
                name: name,
                help:
                    "A device watching this feed is asking to drive the camera. Granting it does not move the camera link: this device keeps that and runs the other one's commands on its behalf, so you can take control back instantly.",
                decline: {
                    if current(), host.pendingRequest == captured { host.declinePendingControl() }
                },
                grant: {
                    if current(), host.pendingRequest == captured { host.grantPendingControl() }
                })
        }
        let holder = relayControlHeldBy.map { name in
            let peer = host.controlHolder
            return MonitorSettingsWatchersSource.Holder(
                name: name,
                help: "Take the camera back. This device holds the link, so it never has to ask.",
                reclaim: { if current(), host.controlHolder == peer { host.reclaimControl() } })
        }
        return .init(
            watching: relayPeerCount == 1 ? "1 device" : "\(relayPeerCount) devices",
            watchingHelp:
                "Devices currently receiving this feed. They see the picture and every view-assist tool, and cannot change anything on the camera unless handed control.",
            request: request, holder: holder)
    }

    /// Clears cached clip files and thumbnails for every camera bucket (Settings → Storage).
    /// Camera indexes are cache — preserving them after a format is what left thumbnail-less
    /// ghosts in the gallery (#296). The on-device `local` library is left intact.
    /// - Throws: `MediaClipCacheClearError` for files that stayed on disk, after every bucket
    ///   was tried and the gallery refreshed.
    func clearAllMediaCaches() throws {
        try Task.checkCancellation()
        mediaActionStoreGeneration &+= 1
        cancelClipStream()
        mediaProducer?.service.cancelCatalog()
        mediaLibrary?.close()
        mediaLibraryBytes?.retire()
        mediaDownloadProgress.removeAll()
        defer {
            refreshMediaClips()
            if mediaBrowserSource == .camera, cameraSession != nil {
                scheduleFetchClipsFromCamera(identityProbeBudget: Int.max)
            }
        }
        var readFailure: (any Error)?
        var cleared = MediaClipCacheClearError(removedBytes: 0, remainingFiles: [])
        for bucket in try mediaClipStore.cacheBucketIDs() {
            try Task.checkCancellation()
            do {
                cleared.removedBytes += try mediaClipStore.clearCache(
                    cameraID: bucket, preservingIndex: false, directory: mediaCacheDirectory)
            } catch let failure as MediaClipCacheClearError {
                cleared.removedBytes += failure.removedBytes
                cleared.remainingFiles += failure.remainingFiles
            } catch is CancellationError { throw CancellationError() } catch {
                if readFailure == nil { readFailure = error }
            }
        }
        if let readFailure { throw readFailure }
        if !cleared.remainingFiles.isEmpty { throw cleared }
    }

    func isClipDownloaded(_ clip: MediaClip) -> Bool {
        guard
            let url = try? mediaClipStore.localURL(
                cameraID: clip.cameraID, filename: clip.filename)
        else { return false }
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let onDisk = (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
        // A local-only legacy row can use the existing nonempty-file fact without claiming a
        // camera extent. Active unknown/sentinel objects cannot establish transfer completion.
        if clip.sizeBytes == 0 {
            return clip.handle == nil && clip.storageID == nil && clip.allLocations.isEmpty
                && onDisk > 0
        }
        guard clip.sizeBytes != UInt64(UInt32.max) else { return false }
        return onDisk >= clip.sizeBytes
    }

    /// Catalog retention preserves legacy unknown-size local bytes without marking a camera
    /// download complete. Used only by removal and retained-filename reconciliation.
    func retainsLocalMediaClip(_ clip: MediaClip) -> Bool {
        guard clip.sizeBytes == 0 else { return isClipDownloaded(clip) }
        guard let url = clipLocalURL(clip),
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        else { return false }
        return ((attributes[.size] as? NSNumber)?.uint64Value ?? 0) > 0
    }

    func clipLocalURL(_ clip: MediaClip) -> URL? {
        try? mediaClipStore.localURL(cameraID: clip.cameraID, filename: clip.filename)
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
    @discardableResult
    func startClipStream(_ clip: MediaClip) -> MediaClipStreamTicket? {
        guard isConnected, !isClipDownloaded(clip), clip.handle != nil else { return nil }
        if clipStreamClipID == clip.id, let clipStreamTask, !clipStreamTask.isCancelled {
            return clipStreamTicket
        }
        cancelClipStream()
        clipStreamClipID = clip.id
        let task = Task { await streamClip(clip) }
        clipStreamTask = task
        let ticket = MediaClipStreamTicket(task: task)
        clipStreamTicket = ticket
        return ticket
    }

    /// Legacy unmigrated callers keep unconditional cancellation and all partial cache bytes.
    func cancelClipStream() {
        clipStreamTask?.cancel()
        clipStreamTask = nil
        clipStreamClipID = nil
        clipStreamTicket = nil
    }

    /// Stop only the exact actual task captured by the outgoing item.
    func cancelClipStream(_ ticket: MediaClipStreamTicket) {
        guard clipStreamTicket === ticket else { return }
        cancelClipStream()
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
                // A thumb that DOES carry EXIF answers the orientation for free — grid cells
                // fall back to this row value when a later decode meets stripped bytes.
                if clip.exifOrientation == nil,
                    let orientation = MediaCellImageLoader.exifOrientation(in: data)
                {
                    cacheEXIFOrientation(orientation, for: clip)
                }
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
            let offset = try await NikonMediaObjectTransfer.stream(
                session: session, handle: handle, totalBytes: total, store: mediaClipStore,
                cameraID: bucket, filename: clip.filename,
                onProgress: { offset in
                    mediaDownloadProgress[clip.id] = Double(offset) / Double(total)
                })
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

    /// Toggles a clip's favorite flag and persists it. The heart and the camera star are one
    /// signal here (Favorites reads `isFavorite || starRating ≥ 1`): favoriting sets ≥1 star,
    /// un-favoriting clears it, and — when connected — writes the matching rating to the body so
    /// the two agree. Best-effort: an offline clip just keeps the local flag until next sync.
    func toggleClipFavorite(_ clip: MediaClip) {
        _ = toggleClipFavorite(clip, ratingOperation: nil)
    }

    @discardableResult func toggleClipFavorite(
        _ clip: MediaClip,
        ratingOperation: ((Int, MediaClip) async -> Int?)?
    ) -> Task<Void, Never>? {
        let action = captureMediaLibraryAction([clip])
        let captured = action?.capturedClip(clip) ?? clip
        let favorite = !captured.isFavorited
        var stars = favorite ? max(captured.starRating ?? 0, 1) : 0
        if action?.canMutate(clip) != false {
            mediaClipStore.update(cameraID: clip.cameraID, filename: clip.filename) {
                $0.isFavorite = favorite
                stars = favorite ? max($0.starRating ?? 0, 1) : 0
                $0.starRating = stars
            }
            if let action { action.publish() } else { refreshMediaClips() }
        }
        guard clip.handle != nil else { return nil }
        return Task {
            if let ratingOperation {
                _ = await performCapturedMediaRating(for: clip, action: action) {
                    await ratingOperation(stars, clip)
                }
            } else {
                _ = await setMediaStarRating(stars, for: clip, action: action)
            }
        }
    }

    /// Resolves the operator's currently selected LUT to a colour cube, for baking onto media
    /// playback preview / export. Returns nil if a stored `.cube` can't be loaded.
    func currentLUTCube() -> CubeLUT? {
        switch assistConfiguration.selectedLUT {
        case .builtIn(let look): return look.cube()
        case .stored(let category, let fileName):
            return lutFileStore.cube(category: category, fileName: fileName)?
                .preparedForRenderer()
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

// The two pickers the Nikon session seam (OpenCineNikon `NikonCameraSession`) owns.
extension CameraPicker {
    init(_ setting: NikonControlSetting) {
        switch setting {
        case .iso: self = .iso
        case .whiteBalance: self = .whiteBalance
        case .shutter: self = .shutter
        case .aperture: self = .iris
        }
    }

    var nikonControlSetting: NikonControlSetting? {
        switch self {
        case .iso: .iso
        case .whiteBalance: .whiteBalance
        case .shutter: .shutter
        case .iris: .aperture
        default: nil
        }
    }
}

extension NativeAppModel {
    /// Actual source lease/freshness and decoded camera reports for opted-in physical checks.
    var nativeQualificationSnapshot: MonitorNativeQualificationSnapshot {
        #if targetEnvironment(simulator)
            let simulated = true
        #else
            let simulated = isDemoSession
        #endif
        let source = nativePictureSource
        return MonitorNativeQualificationSnapshot(
            simulated: simulated,
            sourceIdentity: source.map { String(describing: ObjectIdentifier($0)) },
            sourceActive: source?.isActive,
            sourceFrameAt: lastGoodFrameAt?.timeIntervalSince1970,
            cameraRecording: reportedRecording,
            cameraISO: reportedPropertySnapshot.iso.map { Int($0) },
            cameraISOIsAuto: reportedPropertySnapshot.isoAuto)
    }
}

// MARK: - Codec and colour popup

extension NativeAppModel {
    /// The one codec and colour popup: the advertised codecs and the tones the body offers for
    /// the active codec (R3D NE: Log3G10, shown and fixed). Both header readouts open it.
    var codecColorChoices: CaptureCodecColorChoices {
        let raw = activeCodecMode?.raw
        let offered =
            raw.flatMap(NikonMovieToneCapability.toneProperty(forFileType:)).flatMap {
                cameraMovieTones[$0]
            } ?? []
        return NikonMovieToneCapability.codecColorChoices(
            codecs: cameraFileTypeModes, fileType: raw, offered: offered,
            current: raw.flatMap(cameraPropertySnapshot.movieTone(forFileType:)))
    }

    /// The header colour readout: the active codec's tone, nil while unknown.
    var movieToneReadout: String? { codecColorChoices.selectedColorChoice?.label }

    /// Selects an offered tone for the active codec through the safe-point write queue.
    func applyMovieTone(_ label: String) {
        let choices = codecColorChoices
        guard admitsCameraCommand(nil), videoSource != .relay, !relayControlSurrendered,
            !isRecording,
            choices.colors.contains(where: { $0.label == label && $0.isEditable }),
            let tone = NikonMovieTone(rawValue: label), let raw = activeCodecMode?.raw,
            let write = NikonMovieToneCapability.write(tone, forFileType: raw)
        else { return }
        if isDemoSession {
            cameraPropertySnapshot = cameraPropertySnapshot.applying(
                property: write.property, data: write.data)
            publishCameraDisplayState()
            return
        }
        enqueueCameraWrite(PendingCameraWrite(picker: .codec, value: label, write: write))
        cameraPropertySnapshot = cameraPropertySnapshot.applying(
            property: write.property, data: write.data)
        publishCameraDisplayState()
        connectionMessage =
            isMonitorPresented
            ? "Queued Color \(label) for the next live-view safe point."
            : "Queued Color \(label)."
        drainPendingWritesIfIdle()
    }
}

extension LiveHDRDisplay {
    /// The app's one HDR display owner (A2-31), as in Pocket and Insta.
    static let app = LiveHDRDisplay()
}
extension NativeAppModel {
    /// Keeps the opt-in local to the phone while recording authority remains with the camera.
    func setGyroCaptureEnabled(_ enabled: Bool) {
        gyroCapture.enabled = enabled
        reconcileGyroCapture(recording: reportedRecording)
    }

    private func reconcileGyroCapture(recording: Bool?) {
        let eligible =
            isConnected && cameraSession != nil && isMonitorPresented
            && UIApplication.shared.applicationState == .active
            && !isDemoSession && videoSource != .relay
            && !multicam.isPresented && multicam.lentMember == nil
            && GyroCaptureCoordinator.selectorArms(cameraPropertySnapshot.captureSelector)
        gyroCapture.configure(
            eligible: eligible,
            cameraLabel: connectedIdentity?.model ?? "Nikon camera", recording: recording,
            calibrationSourceID: eligible && videoSource == .cameraLiveView
                ? connectionGeneration : nil)
    }
}

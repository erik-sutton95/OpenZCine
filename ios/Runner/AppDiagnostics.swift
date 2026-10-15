import Foundation
import ImageIO
import MetricKit
import OpenCineMedia
import OpenZCineCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Privacy-safe, high-value application transitions retained across launches for tester support.
///
/// Values are deliberately closed rather than accepting arbitrary strings. This prevents camera
/// names, serials, network details, media names, credentials, or account data from entering the
/// support log by accident.
enum AppDiagnosticEvent: String, Codable, Sendable {
    case appLaunched = "app.launched"
    case sceneConnected = "scene.connected"
    case enteredBackground = "app.background"
    case enteredForeground = "app.foreground"
    case connectionDisconnected = "connection.disconnected"
    case connectionScanning = "connection.scanning"
    case connectionHandshaking = "connection.handshaking"
    case connectionPairing = "connection.pairing"
    case connectionConfirmOnCamera = "connection.confirm-on-camera"
    case connectionJoiningWifi = "connection.joining-wifi"
    case connectionReconnecting = "connection.reconnecting"
    case connectionPreparingLiveView = "connection.preparing-live-view"
    case connectionConnected = "connection.connected"
    case connectionPathCameraAp = "connection.path.camera-ap"
    case connectionPathPhoneHotspot = "connection.path.phone-hotspot"
    case connectionPathUsb = "connection.path.usb"
    case connectionPathHDMICapture = "connection.path.hdmi-capture"
    case connectionPathWiFiNetwork = "connection.path.wifi-network"
    // USB browser truth, so a "USB finds nothing" report shows whether the system ever
    // surfaced a camera and whether control authorization was granted.
    case usbAuthorizationGranted = "usb.authorization.granted"
    case usbAuthorizationDenied = "usb.authorization.denied"
    case usbCameraAttached = "usb.camera.attached"
    case usbCameraDetached = "usb.camera.detached"
    case monitorPresented = "monitor.presented"
    case monitorDismissed = "monitor.dismissed"
    case liveViewStarted = "live-view.started"
    case liveViewFailed = "live-view.failed"
    /// Generic connect failure when a more specific closed code is unavailable.
    case connectionFailed = "error.connection.failed"
    case connectionWifiJoinFailed = "error.connection.wifi-join.failed"
    case connectionUsbFailed = "error.connection.usb.failed"
    // USB handshake stages. The generic `error.connection.usb.failed` breadcrumb cannot
    // tell ICC session-open from PTP OpenSession from application-mode (issue #254).
    case usbSessionOpen = "usb.session.open"
    case usbHandshakeDeviceInfo = "usb.handshake.device-info"
    case usbHandshakeOpenSession = "usb.handshake.open-session"
    case usbHandshakeAppMode = "usb.handshake.app-mode"
    case usbHandshakeIdentify = "usb.handshake.identify"
    case connectionPtpFailed = "error.connection.ptp.failed"
    case connectionPairingFailed = "error.connection.pairing.failed"
    case connectionReconnectFailed = "error.connection.reconnect.failed"
    case connectionEventChannelEnded = "error.connection.event-channel-ended"
    case liveViewStalled = "warning.live-view.stalled"
    case recordingStarted = "recording.started"
    case recordingStopped = "recording.stopped"
    case guidePresented = "live-guide.presented"
    case guideCompleted = "live-guide.completed"
    case guideSkipped = "live-guide.skipped"
    case diagnosticsExported = "diagnostics.exported"
    // Object star-rating writes. The vocabulary stays closed (no free-form codes leak into the
    // support log); the exact wire code rides the user-facing toast instead. Access-Denied gets
    // its own breadcrumb because it is the leading hypothesis for a state-based refusal.
    case ratingWriteAttempted = "rating.write.attempted"
    case ratingWriteConfirmed = "rating.write.confirmed"
    case ratingWriteRefused = "error.rating.write.refused"
    case ratingWriteRefusedAccessDenied = "error.rating.write.refused.access-denied"

    // Manual-focus drives (focus-by-wire scrub). Success stays off the log (a scrub is dozens
    // of drives); only a sustained refusal (retries exhausted) leaves a trace — the wire code
    // rides the user-facing toast.
    case mfDriveRefused = "error.mf.drive.refused"

    // A camera property write held the transaction gate unusually long (>1.5s) — the feed and
    // queued writes stall behind it. The property rides the connection log, not the vocabulary.
    case propertyWriteSlow = "camera.write.slow"

    /// DeviceInfo was empty, so generation was taken from the USB / PTP-IP name.
    case connectionGateGen1Fallback = "connection.gate.gen1-fallback"
    /// DeviceInfo did not arrive; modern pairing / app-mode is still assumed.
    case connectionGateUnknownOps = "connection.gate.unknown-ops"
    /// Camera AP path had no stored or derived SSID, so join used the Nikon prefix.
    case connectionJoinPrefix = "connection.join.prefix"
}

struct DiagnosticBreadcrumb: Codable, Equatable, Sendable {
    let timestamp: Date
    let event: String
}

struct DiagnosticReportMetadata: Equatable, Sendable {
    let generatedAt: Date
    let appVersion: String
    let buildNumber: String
    let deviceClass: String
    let osName: String
    let osVersion: String

    @MainActor static var current: DiagnosticReportMetadata {
        let info = Bundle.main.infoDictionary
        return DiagnosticReportMetadata(
            generatedAt: Date(),
            appVersion: info?["CFBundleShortVersionString"] as? String ?? "unknown",
            buildNumber: info?["CFBundleVersion"] as? String ?? "unknown",
            deviceClass: UIDevice.current.model,
            osName: UIDevice.current.systemName,
            osVersion: UIDevice.current.systemVersion
        )
    }
}

enum DiagnosticReportError: LocalizedError {
    case unavailable
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "Diagnostics are not available on this device."
        case .writeFailed:
            "OpenZCine could not create the diagnostics report."
        }
    }
}

/// Bounded file-backed event and MetricKit payload store owned by the iOS shell.
actor DiagnosticEventStore {
    private let fileManager: FileManager
    private let rootDirectory: URL
    private let eventsURL: URL
    private let connectTraceURL: URL
    private let payloadDirectory: URL
    private let maximumEventBytes: Int
    private let maximumPayloadCount: Int

    init(
        rootDirectory: URL? = nil,
        fileManager: FileManager = .default,
        maximumEventBytes: Int = 256 * 1_024,
        maximumPayloadCount: Int = 8
    ) {
        self.fileManager = fileManager
        let defaultRoot =
            fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("OpenZCine/Diagnostics", isDirectory: true)
            ?? fileManager.temporaryDirectory.appendingPathComponent(
                "OpenZCine/Diagnostics", isDirectory: true)
        self.rootDirectory = rootDirectory ?? defaultRoot
        self.eventsURL = (rootDirectory ?? defaultRoot).appendingPathComponent("events.jsonl")
        self.connectTraceURL = (rootDirectory ?? defaultRoot).appendingPathComponent(
            "connect-trace.jsonl")
        self.payloadDirectory = (rootDirectory ?? defaultRoot).appendingPathComponent(
            "metrickit", isDirectory: true)
        self.maximumEventBytes = max(1_024, maximumEventBytes)
        self.maximumPayloadCount = max(1, maximumPayloadCount)
    }

    /// Appends one sanitized connect-attempt line. Stays on device until the operator
    /// exports a diagnostics report; never enters the anonymous activity log.
    func recordConnectTrace(_ line: String, at timestamp: Date = Date()) {
        guard let sanitized = ConnectAttemptDiagnostic.sanitizedSummary(line) else { return }
        do {
            try prepareDirectories()
            let stamp = ISO8601DateFormatter().string(from: timestamp)
            let data = Data("\(stamp)  \(sanitized)\n".utf8)
            if !fileManager.fileExists(atPath: connectTraceURL.path) {
                guard fileManager.createFile(atPath: connectTraceURL.path, contents: nil) else {
                    return
                }
            }
            let handle = try FileHandle(forWritingTo: connectTraceURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try compactConnectTraceIfNeeded()
        } catch {
            // Diagnostics must never interfere with camera control.
        }
    }

    nonisolated func recentConnectTrace() -> [String] {
        guard let data = try? Data(contentsOf: connectTraceURL) else { return [] }
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .suffix(ConnectAttemptDiagnostic.maximumLineCount)
            .map(String.init)
    }

    func record(_ event: AppDiagnosticEvent, at timestamp: Date = Date()) {
        do {
            try prepareDirectories()
            let breadcrumb = DiagnosticBreadcrumb(timestamp: timestamp, event: event.rawValue)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            var data = try encoder.encode(breadcrumb)
            data.append(0x0A)
            if !fileManager.fileExists(atPath: eventsURL.path) {
                guard fileManager.createFile(atPath: eventsURL.path, contents: nil) else {
                    throw DiagnosticReportError.writeFailed
                }
            }
            let handle = try FileHandle(forWritingTo: eventsURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try compactEventsIfNeeded()
        } catch {
            // Diagnostics must never interfere with camera control or app launch.
        }
    }

    func storeMetricPayload(_ data: Data, kind: String, at timestamp: Date = Date()) {
        guard !data.isEmpty else { return }
        do {
            try prepareDirectories()
            let milliseconds = Int(timestamp.timeIntervalSince1970 * 1_000)
            let safeKind = kind == "metric" ? "metric" : "diagnostic"
            let url = payloadDirectory.appendingPathComponent(
                "\(safeKind)-\(milliseconds)-\(UUID().uuidString).json")
            try data.write(to: url, options: .atomic)
            try trimMetricPayloads()
        } catch {
            // MetricKit delivery is opportunistic. Apple remains the authoritative crash source.
        }
    }

    nonisolated func recentEvents() -> [DiagnosticBreadcrumb] {
        guard let data = try? Data(contentsOf: eventsURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return data.split(separator: 0x0A).compactMap {
            try? decoder.decode(DiagnosticBreadcrumb.self, from: Data($0))
        }
    }

    func metricPayloads() -> [(name: String, data: Data)] {
        guard
            let urls = try? fileManager.contentsOfDirectory(
                at: payloadDirectory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles])
        else { return [] }
        return urls.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return (url.lastPathComponent, data)
        }
    }

    func makeReport(metadata: DiagnosticReportMetadata) throws -> URL {
        try prepareDirectories()
        let report = Self.renderReport(
            metadata: metadata,
            events: recentEvents(),
            connectTrace: recentConnectTrace(),
            payloads: metricPayloads()
        )
        guard let data = report.data(using: .utf8) else {
            throw DiagnosticReportError.unavailable
        }
        let timestamp = Int(metadata.generatedAt.timeIntervalSince1970)
        let url = fileManager.temporaryDirectory.appendingPathComponent(
            "OpenZCine-Diagnostics-\(timestamp).txt")
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw DiagnosticReportError.writeFailed
        }
        return url
    }

    /// The shared OpenCine report (environment header, privacy redaction, journal) with this app's
    /// privacy note, connect-attempt trace and MetricKit payloads as its sections.
    static func renderReport(
        metadata: DiagnosticReportMetadata,
        events: [DiagnosticBreadcrumb],
        connectTrace: [String] = [],
        payloads: [(name: String, data: Data)]
    ) -> String {
        let formatter = ISO8601DateFormatter()
        let environment = Self.environment(metadata)
        var extras: [(name: String, body: String)] = [
            (
                "Before sharing",
                [
                    "Generated: \(formatter.string(from: metadata.generatedAt))",
                    "Review this file before sharing it publicly.",
                    "It intentionally excludes camera frames, media names, camera identities, network",
                    "addresses, Wi-Fi details, pairing data, credentials, and account identifiers.",
                    "The connect-attempt trace below is closed tokens only (body family, DeviceInfo",
                    "known/unknown, pairing decision). It never leaves this phone unless you share",
                    "this file.",
                ].joined(separator: "\n")
            ),
            Self.connectTraceSection(connectTrace),
        ]
        if payloads.isEmpty {
            extras.append(
                (
                    "MetricKit diagnostics",
                    "No MetricKit payloads have been delivered on this device."
                ))
        } else {
            var remainingBytes = 1_048_576
            for payload in payloads.suffix(4) where remainingBytes > 0 {
                let included = payload.data.prefix(remainingBytes)
                extras.append(
                    ("metrickit-\(payload.name)", String(decoding: included, as: UTF8.self)))
                remainingBytes -= included.count
            }
        }
        return DiagnosticReport.fullReport(
            environment: environment,
            journal: Self.journal(events),
            exceptions: [],
            extras: extras,
            isSafeNetwork: { _ in false })
    }

    /// The technical details an operator can add to a problem report (reviewed in the form before
    /// sending): the shared manual report on this app's journal and connect-attempt trace. Reads
    /// the files directly, so the form can build it at once.
    nonisolated func manualReport(metadata: DiagnosticReportMetadata) -> String {
        DiagnosticReport.manualReport(
            environment: Self.environment(metadata),
            journal: Self.journal(recentEvents()),
            exceptions: [],
            extras: [Self.connectTraceSection(recentConnectTrace())],
            isSafeNetwork: { _ in false })
    }

    private static func journal(_ events: [DiagnosticBreadcrumb]) -> [String] {
        let formatter = ISO8601DateFormatter()
        return events.suffix(500).map {
            "\(formatter.string(from: $0.timestamp))  \($0.event)"
        }
    }

    private static func connectTraceSection(_ trace: [String]) -> (name: String, body: String) {
        (
            "Connect attempt trace",
            trace.isEmpty
                ? "No retained connect-attempt trace."
                : trace.suffix(ConnectAttemptDiagnostic.maximumLineCount).joined(separator: "\n")
        )
    }

    private static func environment(_ metadata: DiagnosticReportMetadata) -> DiagnosticEnvironment {
        DiagnosticEnvironment(
            product: "OpenZCine",
            appVersion: metadata.appVersion,
            appBuild: metadata.buildNumber,
            osName: metadata.osName,
            osVersion: metadata.osVersion,
            deviceModel: metadata.deviceClass,
            cameraModel: "unknown",
            phase: "unknown",
            // ponytail: unknown, not off: no local-VPN probe here yet. Pocket and Insta's
            // `LocalVPNProbe` is the one to share when the Nikon report needs it.
            vpnActive: nil)
    }

    static func compactedEventData(_ data: Data, limit: Int) -> Data {
        guard data.count > limit else { return data }
        let target = max(1, limit / 2)
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        var kept: [Data] = []
        var byteCount = 0
        for line in lines.reversed() {
            let lineData = Data(line)
            let nextCount = byteCount + lineData.count + 1
            guard nextCount <= target || kept.isEmpty else { break }
            kept.append(lineData)
            byteCount = nextCount
        }
        var compacted = Data()
        for line in kept.reversed() {
            compacted.append(line)
            compacted.append(0x0A)
        }
        return compacted
    }

    private func prepareDirectories() throws {
        try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: payloadDirectory, withIntermediateDirectories: true)
    }

    private func compactConnectTraceIfNeeded() throws {
        let data = try Data(contentsOf: connectTraceURL)
        guard data.count > maximumEventBytes else { return }
        let compacted = Self.compactedEventData(data, limit: maximumEventBytes)
        try compacted.write(to: connectTraceURL, options: .atomic)
    }

    private func compactEventsIfNeeded() throws {
        let data = try Data(contentsOf: eventsURL)
        guard data.count > maximumEventBytes else { return }
        let compacted = Self.compactedEventData(data, limit: maximumEventBytes)
        try compacted.write(to: eventsURL, options: .atomic)
    }

    private func trimMetricPayloads() throws {
        let urls = try fileManager.contentsOfDirectory(
            at: payloadDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles])
        guard urls.count > maximumPayloadCount else { return }
        let sorted = urls.sorted {
            let lhs =
                (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            let rhs =
                (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            return lhs < rhs
        }
        for url in sorted.prefix(urls.count - maximumPayloadCount) {
            try fileManager.removeItem(at: url)
        }
    }
}

/// Apple-native diagnostic coordinator. TestFlight/Xcode Organizer remains the authoritative,
/// symbolicated crash source; MetricKit fills in locally delivered crash, hang, watchdog, CPU,
/// disk-write, and memory diagnostics without sending app data to a third party.
final class AppDiagnostics: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    static let shared = AppDiagnostics()

    private let store = DiagnosticEventStore()

    private override init() {
        super.init()
    }

    @MainActor
    func start() {
        MXMetricManager.shared.add(self)
        record(.appLaunched)
    }

    func record(_ event: AppDiagnosticEvent) {
        Task { await store.record(event) }
    }

    func recordConnectTrace(_ line: String) {
        Task { await store.recordConnectTrace(line) }
    }

    /// Technical details for an operator's problem report.
    @MainActor
    func manualReport() -> String {
        let report = store.manualReport(metadata: .current)
        let incidents =
            ReliabilityDiagnostics.incidents.reportExtras()
            .first { $0.name == "incidents.txt" }?.body ?? ""
        return incidents.isEmpty ? report : report + "\n" + incidents
    }

    @MainActor
    func makeReport() async throws -> URL {
        let url = try await store.makeReport(metadata: .current)
        await store.record(.diagnosticsExported)
        return url
    }

    nonisolated func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            let data = payload.jsonRepresentation()
            Task { await self.store.storeMetricPayload(data, kind: "metric") }
        }
    }

    nonisolated func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            let data = payload.jsonRepresentation()
            Task { await self.store.storeMetricPayload(data, kind: "diagnostic") }
        }
    }
}

enum SupportLinkCatalog {
    static let support = requiredURL("https://openzcine.app/support/")
    static let privacy = requiredURL("https://openzcine.app/privacy/")
    static let terms = requiredURL("https://openzcine.app/terms/")
    static let source = requiredURL("https://github.com/erik-sutton95/OpenZCine")
    static let securityAdvisory = requiredURL(
        "https://github.com/erik-sutton95/OpenZCine/security/advisories/new"
    )
    static let featureRequest = requiredURL(
        "https://github.com/erik-sutton95/OpenZCine/discussions/new?category=ideas-feature-requests"
    )

    private static func requiredURL(_ string: String) -> URL {
        guard let url = URL(string: string) else {
            preconditionFailure("Invalid checked-in support URL")
        }
        return url
    }
}

struct DiagnosticsShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

/// Small UIKit bridge for sharing the generated text report from the custom SwiftUI settings panel.
struct DiagnosticsShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(
        _ uiViewController: UIActivityViewController, context: Context
    ) {}
}

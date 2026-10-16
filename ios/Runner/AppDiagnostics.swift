import Foundation
import ImageIO
import MetricKit
import OpenCineAppKit
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

struct DiagnosticReportMetadata: Equatable, Sendable {
    let generatedAt: Date
    let appVersion: String
    let buildNumber: String
    let deviceClass: String
    let osName: String
    let osVersion: String

    /// The phone as every app's diagnostics name it: OpenCine `DiagnosticsDevice` (A6-13).
    @MainActor static var current: DiagnosticReportMetadata {
        let info = Bundle.main.infoDictionary
        let device = DiagnosticsDevice.current
        return DiagnosticReportMetadata(
            generatedAt: Date(),
            appVersion: info?["CFBundleShortVersionString"] as? String ?? "unknown",
            buildNumber: info?["CFBundleVersion"] as? String ?? "unknown",
            deviceClass: device.hardwareClass,
            osName: device.osName,
            osVersion: device.osVersion
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

/// The closed event journal, the connect-attempt trace and the MetricKit payloads of the iOS
/// shell. Events and the trace are OpenCine `DiagnosticJournal`s, the owner Pocket, Insta and Z
/// Android use: recording never touches disk on the caller's thread, and each file stays bounded.
/// MetricKit payloads stay this shell's own files.
actor DiagnosticEventStore {
    /// Events the report shows and the event journal keeps (Z Android keeps the same bound).
    static let maximumEventCount = 500

    private let fileManager: FileManager
    private let payloadDirectory: URL
    private let maximumPayloadCount: Int
    private let events: DiagnosticJournal
    private let connectTrace: DiagnosticJournal

    init(
        rootDirectory: URL? = nil,
        fileManager: FileManager = .default,
        maximumPayloadCount: Int = 8
    ) {
        let root =
            rootDirectory
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("OpenZCine/Diagnostics", isDirectory: true)
            ?? fileManager.temporaryDirectory.appendingPathComponent(
                "OpenZCine/Diagnostics", isDirectory: true)
        self.fileManager = fileManager
        self.payloadDirectory = root.appendingPathComponent("metrickit", isDirectory: true)
        self.maximumPayloadCount = max(1, maximumPayloadCount)
        // The journals create their files on the first line; the folder must exist first.
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        Self.moveLegacyFiles(in: root, fileManager: fileManager)
        let redact: @Sendable (String) -> String = {
            PrivacyRedactor.redact($0, isSafeNetwork: { _ in false })
        }
        events = DiagnosticJournal(
            subsystem: "com.opencapture.openzcine", category: "events",
            file: root.appendingPathComponent("events.log"), cap: Self.maximumEventCount,
            redact: redact)
        connectTrace = DiagnosticJournal(
            subsystem: "com.opencapture.openzcine", category: "connect-trace",
            file: root.appendingPathComponent("connect-trace.log"),
            cap: ConnectAttemptDiagnostic.maximumLineCount, redact: redact)
    }

    /// Appends one closed event; never waits on disk.
    nonisolated func record(_ event: AppDiagnosticEvent) {
        events.line(event.rawValue)
    }

    /// Appends one sanitized connect-attempt line. Stays on device until the operator
    /// exports a diagnostics report; never enters the anonymous activity log.
    nonisolated func recordConnectTrace(_ line: String) {
        guard let sanitized = ConnectAttemptDiagnostic.sanitizedSummary(line) else { return }
        connectTrace.line(sanitized)
    }

    /// Journal lines, `<ISO 8601 stamp> <event>`, oldest first.
    nonisolated func recentEvents() -> [String] {
        events.recentLines()
    }

    nonisolated func recentConnectTrace() -> [String] {
        connectTrace.recentLines()
    }

    func storeMetricPayload(_ data: Data, kind: String, at timestamp: Date = Date()) {
        guard !data.isEmpty else { return }
        do {
            try fileManager.createDirectory(
                at: payloadDirectory, withIntermediateDirectories: true)
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
        events: [String],
        connectTrace: [String] = [],
        payloads: [(name: String, data: Data)]
    ) -> String {
        let formatter = ISO8601DateFormatter()
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
            environment: Self.environment(metadata),
            journal: Array(events.suffix(maximumEventCount)),
            exceptions: [],
            extras: extras,
            isSafeNetwork: { _ in false })
    }

    /// The technical details an operator can add to a problem report (reviewed in the form before
    /// sending): the shared manual report on this app's journal and connect-attempt trace. Reads
    /// the journals at once.
    nonisolated func manualReport(metadata: DiagnosticReportMetadata) -> String {
        DiagnosticReport.manualReport(
            environment: Self.environment(metadata),
            journal: Array(recentEvents().suffix(Self.maximumEventCount)),
            exceptions: [],
            extras: [Self.connectTraceSection(recentConnectTrace())],
            isSafeNetwork: { _ in false })
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

    /// One event as an earlier version stored it (`events.jsonl`).
    private struct LegacyBreadcrumb: Decodable {
        let timestamp: Date
        let event: String
    }

    /// An earlier version kept events as JSON breadcrumbs (`events.jsonl`) and the trace with a
    /// two-space stamp separator (`connect-trace.jsonl`). Moves both, once, onto the journal files
    /// in the journal's `<stamp> <text>` format before the journals open them. Corrupt breadcrumbs
    /// stay dropped, as they were on read; a failed write keeps the legacy file for the next launch.
    private static func moveLegacyFiles(in root: URL, fileManager: FileManager) {
        let legacyEvents = root.appendingPathComponent("events.jsonl")
        if let data = try? Data(contentsOf: legacyEvents) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let stamper = ISO8601DateFormatter()
            let lines = data.split(separator: 0x0A)
                .compactMap { try? decoder.decode(LegacyBreadcrumb.self, from: Data($0)) }
                .suffix(maximumEventCount)
                .map { "\(stamper.string(from: $0.timestamp)) \($0.event)" }
            if prepend(lines, to: root.appendingPathComponent("events.log")) {
                try? fileManager.removeItem(at: legacyEvents)
            }
        }
        let legacyTrace = root.appendingPathComponent("connect-trace.jsonl")
        if let text = try? String(contentsOf: legacyTrace, encoding: .utf8) {
            let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
                .suffix(ConnectAttemptDiagnostic.maximumLineCount)
                .map { line -> String in
                    guard let gap = line.range(of: "  ") else { return String(line) }
                    return String(line[..<gap.lowerBound]) + " " + String(line[gap.upperBound...])
                }
            if prepend(lines, to: root.appendingPathComponent("connect-trace.log")) {
                try? fileManager.removeItem(at: legacyTrace)
            }
        }
    }

    /// Puts `lines` ahead of whatever the journal file already holds.
    private static func prepend(_ lines: [String], to file: URL) -> Bool {
        guard !lines.isEmpty else { return true }
        var data = Data((lines.joined(separator: "\n") + "\n").utf8)
        data.append((try? Data(contentsOf: file)) ?? Data())
        do {
            try data.write(to: file, options: .atomic)
            return true
        } catch {
            return false
        }
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

    /// Recorded in call order: the journal queues every line behind the previous one.
    func record(_ event: AppDiagnosticEvent) {
        store.record(event)
    }

    func recordConnectTrace(_ line: String) {
        store.recordConnectTrace(line)
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
        store.record(.diagnosticsExported)
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

import Foundation
import MetricKit
import SwiftUI
import UIKit

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
    case connectionPairing = "connection.pairing"
    case connectionReconnecting = "connection.reconnecting"
    case connectionPreparingLiveView = "connection.preparing-live-view"
    case connectionConnected = "connection.connected"
    case monitorPresented = "monitor.presented"
    case monitorDismissed = "monitor.dismissed"
    case liveViewStarted = "live-view.started"
    case liveViewFailed = "live-view.failed"
    case recordingStarted = "recording.started"
    case recordingStopped = "recording.stopped"
    case guidePresented = "live-guide.presented"
    case guideCompleted = "live-guide.completed"
    case guideSkipped = "live-guide.skipped"
    case diagnosticsExported = "diagnostics.exported"
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
    let operatingSystem: String

    @MainActor static var current: DiagnosticReportMetadata {
        let info = Bundle.main.infoDictionary
        return DiagnosticReportMetadata(
            generatedAt: Date(),
            appVersion: info?["CFBundleShortVersionString"] as? String ?? "unknown",
            buildNumber: info?["CFBundleVersion"] as? String ?? "unknown",
            deviceClass: UIDevice.current.model,
            operatingSystem: "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
        )
    }

    var platformSummary: String {
        "OpenZCine \(appVersion) (build \(buildNumber)), \(deviceClass), \(operatingSystem)"
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
        self.payloadDirectory = (rootDirectory ?? defaultRoot).appendingPathComponent(
            "metrickit", isDirectory: true)
        self.maximumEventBytes = max(1_024, maximumEventBytes)
        self.maximumPayloadCount = max(1, maximumPayloadCount)
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

    func recentEvents() -> [DiagnosticBreadcrumb] {
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

    static func renderReport(
        metadata: DiagnosticReportMetadata,
        events: [DiagnosticBreadcrumb],
        payloads: [(name: String, data: Data)]
    ) -> String {
        let formatter = ISO8601DateFormatter()
        var lines = [
            "OpenZCine Diagnostics",
            "=====================",
            "",
            "Review this file before sharing it publicly.",
            "It intentionally excludes camera frames, media names, camera identities, network",
            "addresses, Wi-Fi details, pairing data, credentials, and account identifiers.",
            "",
            "Generated: \(formatter.string(from: metadata.generatedAt))",
            "App: OpenZCine \(metadata.appVersion) (build \(metadata.buildNumber))",
            "Device class: \(metadata.deviceClass)",
            "Operating system: \(metadata.operatingSystem)",
            "",
            "Recent app events",
            "-----------------",
        ]
        if events.isEmpty {
            lines.append("No retained app events.")
        } else {
            lines.append(
                contentsOf: events.suffix(500).map {
                    "\(formatter.string(from: $0.timestamp))  \($0.event)"
                })
        }

        lines.append(contentsOf: ["", "MetricKit diagnostics", "---------------------"])
        if payloads.isEmpty {
            lines.append("No MetricKit payloads have been delivered on this device.")
        } else {
            var remainingBytes = 1_048_576
            for payload in payloads.suffix(4) where remainingBytes > 0 {
                let included = payload.data.prefix(remainingBytes)
                lines.append(contentsOf: ["", "### \(payload.name)"])
                lines.append(String(decoding: included, as: UTF8.self))
                remainingBytes -= included.count
            }
        }
        lines.append("")
        return lines.joined(separator: "\n")
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

/// Stable support and public-project links shared by Settings and tests.
enum SupportLinkCatalog {
    static let support = requiredURL("https://openzcine.app/support/")
    static let privacy = requiredURL("https://openzcine.app/privacy/")
    static let terms = requiredURL("https://openzcine.app/terms/")
    static let source = requiredURL("https://github.com/erik-sutton95/OpenZCine")
    static let featureRequest = requiredURL(
        "https://github.com/erik-sutton95/OpenZCine/discussions/new?category=ideas-feature-requests"
    )

    @MainActor
    static func bugReport(metadata: DiagnosticReportMetadata = .current) -> URL {
        var components = URLComponents(
            url: requiredURL("https://github.com/erik-sutton95/OpenZCine/issues/new"),
            resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "template", value: "bug_report.yml"),
            URLQueryItem(name: "title", value: "[iOS] "),
            URLQueryItem(name: "platform", value: metadata.platformSummary),
        ]
        return components?.url
            ?? requiredURL(
                "https://github.com/erik-sutton95/OpenZCine/issues/new?template=bug_report.yml")
    }

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

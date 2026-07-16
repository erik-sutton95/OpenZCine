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

/// The frequency selected by a person submitting an anonymous bug report.
enum BugReportFrequency: String, CaseIterable, Codable, Equatable, Sendable {
    case always
    case sometimes
    case once
    case unknown

    var displayName: String {
        switch self {
        case .always:
            "Always"
        case .sometimes:
            "Sometimes"
        case .once:
            "Once"
        case .unknown:
            "Not sure"
        }
    }
}

/// The connection selected by a person submitting an anonymous bug report.
///
/// This is intentionally an explicit, coarse choice. OpenZCine does not inspect or include a
/// network name, address, camera identity, or connection history in a bug report.
enum BugReportConnection: String, CaseIterable, Codable, Equatable, Sendable {
    case wifi
    case usb
    case unknown

    var displayName: String {
        switch self {
        case .wifi:
            "Wi-Fi"
        case .usb:
            "USB"
        case .unknown:
            "Not sure"
        }
    }
}

/// The only device grouping included with an anonymous bug report.
enum BugReportDeviceClass: String, Codable, Equatable, Sendable {
    case phone
    case tablet
    case unknown
}

/// Coarse, privacy-safe execution context attached to an anonymous bug report.
struct BugReportContext: Codable, Equatable, Sendable {
    let platform: String
    let appVersion: String
    let buildNumber: String
    let osVersion: String
    let deviceClass: BugReportDeviceClass
    let connection: BugReportConnection

    /// Reads only the app version, build number, operating-system version, and device class.
    ///
    /// This deliberately never reads a model name, serial number, camera identity, Wi-Fi name,
    /// network address, diagnostic event, MetricKit payload, or persistent identifier.
    @MainActor static func current(connection: BugReportConnection = .unknown) -> BugReportContext {
        let info = Bundle.main.infoDictionary
        let appVersion = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        let buildNumber = info?["CFBundleVersion"] as? String ?? "unknown"
        let deviceClass: BugReportDeviceClass
        switch UIDevice.current.userInterfaceIdiom {
        case .phone:
            deviceClass = .phone
        case .pad:
            deviceClass = .tablet
        default:
            deviceClass = .unknown
        }
        return BugReportContext(
            platform: "ios",
            appVersion: appVersion,
            buildNumber: buildNumber,
            osVersion: UIDevice.current.systemVersion,
            deviceClass: deviceClass,
            connection: connection
        )
    }
}

/// The report body accepted by the public bug-report relay.
struct BugReportPayload: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let summary: String
    let whatHappened: String
    let stepsToReproduce: String?
    let frequency: BugReportFrequency
    let context: BugReportContext

    init(
        summary: String,
        whatHappened: String,
        stepsToReproduce: String?,
        frequency: BugReportFrequency,
        context: BugReportContext
    ) {
        self.schemaVersion = 1
        self.summary = summary
        self.whatHappened = whatHappened
        self.stepsToReproduce = stepsToReproduce
        self.frequency = frequency
        self.context = context
    }
}

/// User-facing validation failures for an anonymous bug-report draft.
enum BugReportValidationError: LocalizedError, Equatable, Sendable {
    case summaryRequired
    case summaryTooLong
    case whatHappenedRequired
    case whatHappenedTooLong
    case stepsTooLong

    var errorDescription: String? {
        switch self {
        case .summaryRequired:
            "Add a short summary before submitting."
        case .summaryTooLong:
            "Keep the summary to 120 characters or fewer."
        case .whatHappenedRequired:
            "Describe what happened before submitting."
        case .whatHappenedTooLong:
            "Keep what happened to 4,000 characters or fewer."
        case .stepsTooLong:
            "Keep reproduction steps to 4,000 characters or fewer."
        }
    }
}

/// Editable, in-memory fields for an anonymous bug report.
///
/// The draft is deliberately not persisted. A failed submission remains visible so it can be
/// corrected and submitted again, but OpenZCine never creates an offline report queue.
struct BugReportDraft: Equatable, Sendable {
    var summary = ""
    var whatHappened = ""
    var stepsToReproduce = ""
    var frequency: BugReportFrequency = .unknown
    var connection: BugReportConnection = .unknown

    func payload(baseContext: BugReportContext) throws -> BugReportPayload {
        let trimmedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSummary.isEmpty else { throw BugReportValidationError.summaryRequired }
        guard trimmedSummary.count <= 120 else { throw BugReportValidationError.summaryTooLong }

        let trimmedWhatHappened = whatHappened.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedWhatHappened.isEmpty else {
            throw BugReportValidationError.whatHappenedRequired
        }
        guard trimmedWhatHappened.count <= 4_000 else {
            throw BugReportValidationError.whatHappenedTooLong
        }

        let trimmedSteps = stepsToReproduce.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedSteps.count <= 4_000 else { throw BugReportValidationError.stepsTooLong }

        return BugReportPayload(
            summary: trimmedSummary,
            whatHappened: trimmedWhatHappened,
            stepsToReproduce: trimmedSteps.isEmpty ? nil : trimmedSteps,
            frequency: frequency,
            context: BugReportContext(
                platform: baseContext.platform,
                appVersion: baseContext.appVersion,
                buildNumber: baseContext.buildNumber,
                osVersion: baseContext.osVersion,
                deviceClass: baseContext.deviceClass,
                connection: connection
            )
        )
    }
}

/// The public GitHub issue created by a successful anonymous bug report, when the relay returns it.
struct BugReportSubmissionReceipt: Equatable, Sendable {
    let issueNumber: Int?
    let issueURL: URL?

    static let empty = BugReportSubmissionReceipt(issueNumber: nil, issueURL: nil)
}

/// A submission failure deliberately expressed without exposing transport or server internals.
enum BugReportSubmissionError: LocalizedError, Equatable, Sendable {
    case rateLimited(retryAfter: Int?)
    case unavailable

    var errorDescription: String? {
        switch self {
        case .rateLimited(let retryAfter):
            if let retryAfter {
                "Too many reports were sent. Try again in about \(retryAfter) seconds."
            } else {
                "Too many reports were sent. Please try again later."
            }
        case .unavailable:
            "The report service is unavailable. Please try again later."
        }
    }
}

/// Boundary used by the SwiftUI form so tests can submit through an in-memory fake.
protocol BugReportSubmitting: Sendable {
    func submit(
        _ report: BugReportPayload,
        idempotencyKey: UUID
    ) async throws -> BugReportSubmissionReceipt
}

/// URLSession client for the public, HTTPS-only anonymous bug-report relay.
struct URLSessionBugReportSubmitter: BugReportSubmitting {
    private let session: URLSession
    /// Retained alongside the session so its no-redirect policy stays alive for this client.
    private let redirectDelegate: BugReportRedirectDelegate?

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
            redirectDelegate = nil
        } else {
            let redirectDelegate = BugReportRedirectDelegate()
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 12
            configuration.timeoutIntervalForResource = 12
            configuration.waitsForConnectivity = false
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            self.session = URLSession(
                configuration: configuration,
                delegate: redirectDelegate,
                delegateQueue: nil
            )
            self.redirectDelegate = redirectDelegate
        }
    }

    func submit(
        _ report: BugReportPayload,
        idempotencyKey: UUID
    ) async throws -> BugReportSubmissionReceipt {
        do {
            let request = try Self.makeRequest(report, idempotencyKey: idempotencyKey)
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else {
                throw BugReportSubmissionError.unavailable
            }
            guard response.url?.scheme?.lowercased() == "https" else {
                throw BugReportSubmissionError.unavailable
            }

            switch response.statusCode {
            case 200, 201:
                return Self.decodeReceipt(data)
            default:
                throw Self.submissionError(
                    statusCode: response.statusCode,
                    retryAfterHeader: response.value(forHTTPHeaderField: "Retry-After")
                )
            }
        } catch let error as BugReportSubmissionError {
            throw error
        } catch {
            throw BugReportSubmissionError.unavailable
        }
    }

    static func makeRequest(
        _ report: BugReportPayload,
        idempotencyKey: UUID
    ) throws -> URLRequest {
        var request = URLRequest(url: SupportLinkCatalog.bugReportEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(idempotencyKey.uuidString, forHTTPHeaderField: "Idempotency-Key")
        request.httpBody = try JSONEncoder().encode(report)
        return request
    }

    static func decodeReceipt(_ data: Data) -> BugReportSubmissionReceipt {
        guard !data.isEmpty,
            let response = try? JSONDecoder().decode(BugReportRelayResponse.self, from: data)
        else {
            return .empty
        }
        return BugReportSubmissionReceipt(
            issueNumber: response.issue?.number,
            issueURL: response.issue?.url
        )
    }

    static func retryAfterSeconds(_ value: String?) -> Int? {
        guard let value, let seconds = Int(value), seconds > 0 else { return nil }
        return seconds
    }

    static func submissionError(
        statusCode: Int,
        retryAfterHeader: String?
    ) -> BugReportSubmissionError {
        guard statusCode == 429 else { return .unavailable }
        return .rateLimited(retryAfter: retryAfterSeconds(retryAfterHeader))
    }
}

private struct BugReportRelayResponse: Decodable {
    struct Issue: Decodable {
        let number: Int?
        let url: URL?
    }

    let issue: Issue?
}

/// Refuses redirects so reports never follow a changed or unexpected destination.
private final class BugReportRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable
{
    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest _: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

/// Main-actor state for the in-app bug-report form.
@MainActor @Observable
final class BugReportFormModel {
    var draft = BugReportDraft()
    private(set) var submissionState: BugReportSubmissionState = .editing

    private let baseContext: BugReportContext
    private let submitter: any BugReportSubmitting
    private var idempotencyKey = UUID()
    private var lastSubmittedPayload: BugReportPayload?

    init(
        baseContext: BugReportContext = .current(),
        submitter: any BugReportSubmitting = URLSessionBugReportSubmitter()
    ) {
        self.baseContext = baseContext
        self.submitter = submitter
    }

    var isSubmitting: Bool {
        if case .submitting = submissionState { return true }
        return false
    }

    var errorMessage: String? {
        if case .failed(let message) = submissionState { return message }
        return nil
    }

    var receipt: BugReportSubmissionReceipt? {
        if case .submitted(let receipt) = submissionState { return receipt }
        return nil
    }

    func submit() async {
        guard !isSubmitting else { return }
        do {
            let report = try draft.payload(baseContext: baseContext)
            // An uncertain transport result may have created an issue. Reusing the key for this
            // exact body makes that retry safe; editing the draft starts a distinct request.
            if lastSubmittedPayload != report {
                idempotencyKey = UUID()
            }
            lastSubmittedPayload = report
            submissionState = .submitting
            submissionState = .submitted(
                try await submitter.submit(report, idempotencyKey: idempotencyKey)
            )
        } catch let error as BugReportValidationError {
            submissionState = .failed(error.errorDescription ?? "Check the report and try again.")
        } catch let error as BugReportSubmissionError {
            submissionState = .failed(error.errorDescription ?? "Please try again later.")
        } catch {
            submissionState = .failed("The report service is unavailable. Please try again later.")
        }
    }

    func startAnotherReport() {
        draft = BugReportDraft()
        idempotencyKey = UUID()
        lastSubmittedPayload = nil
        submissionState = .editing
    }
}

/// UI state for an anonymous bug-report submission.
enum BugReportSubmissionState: Equatable {
    case editing
    case submitting
    case submitted(BugReportSubmissionReceipt)
    case failed(String)
}

/// Stable support, public-project, and feedback endpoints shared by Settings and tests.
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
    static let bugReportEndpoint = requiredURL("https://reports.openzcine.app/v1/bug-reports")

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

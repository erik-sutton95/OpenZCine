import Foundation
import ImageIO
import MetricKit
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

    /// Renders the only activity-log data permitted in an anonymous bug report.
    ///
    /// This intentionally reads no MetricKit payload, timestamp, file name, device name, model,
    /// path, network, camera, pairing, or user-entered value. A stored value must first round-trip
    /// through the closed ``AppDiagnosticEvent`` vocabulary before it can leave the device.
    func anonymousActivityLog() -> [String] {
        Self.anonymousActivityLog(events: recentEvents())
    }

    static func anonymousActivityLog(
        events: [DiagnosticBreadcrumb],
        limit: Int = BugReportAttachmentLimits.maximumActivityLogEvents
    ) -> [String] {
        let boundedLimit = min(max(0, limit), BugReportAttachmentLimits.maximumActivityLogEvents)
        guard boundedLimit > 0 else { return [] }
        return Array(
            events.compactMap { AppDiagnosticEvent(rawValue: $0.event)?.rawValue }
                .suffix(boundedLimit)
        )
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

    /// Returns a bounded, closed-vocabulary event and incident snapshot for an opted-in report.
    ///
    /// Unlike ``makeReport()``, this never includes timestamps, MetricKit data, or device metadata.
    func anonymousActivityLog() async -> [String] {
        await store.anonymousActivityLog()
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

/// Size and count limits shared by the native v2 client and public bug-report relay.
enum BugReportAttachmentLimits {
    static let maximumActivityLogEvents = 200
    static let maximumScreenshotCount = 3
    static let maximumScreenshotBytes = 1_048_576
    static let maximumScreenshotAggregateBytes = maximumScreenshotCount * maximumScreenshotBytes
    static let maximumV2ReportJSONBytes = 16 * 1_024
    static let maximumV2MultipartBodyBytes = 3_211_264
}

/// The report body accepted by the public bug-report relay.
struct BugReportPayload: Codable, Equatable, Sendable {
    /// Maximum encoded UTF-8 JSON request body accepted by the original v1 relay endpoint.
    static let maximumJSONBodyBytes = 12 * 1_024

    let schemaVersion: Int
    let summary: String
    let whatHappened: String
    let stepsToReproduce: String?
    let frequency: BugReportFrequency
    let context: BugReportContext
    /// A closed vocabulary of opted-in app events. It is omitted from v1 reports.
    let activityLog: [String]?

    init(
        summary: String,
        whatHappened: String,
        stepsToReproduce: String?,
        frequency: BugReportFrequency,
        context: BugReportContext,
        schemaVersion: Int = 1,
        activityLog: [String]? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.summary = summary
        self.whatHappened = whatHappened
        self.stepsToReproduce = stepsToReproduce
        self.frequency = frequency
        self.context = context
        self.activityLog = activityLog
    }

    /// Encodes the exact UTF-8 JSON report after enforcing the endpoint-specific size limit.
    func validatedJSONBody() throws -> Data {
        let maximumBytes: Int
        switch schemaVersion {
        case 1:
            guard activityLog == nil else { throw BugReportValidationError.invalidActivityLog }
            maximumBytes = Self.maximumJSONBodyBytes
        case 2:
            if let activityLog {
                guard activityLog.count <= BugReportAttachmentLimits.maximumActivityLogEvents,
                    activityLog.allSatisfy({ AppDiagnosticEvent(rawValue: $0) != nil })
                else {
                    throw BugReportValidationError.invalidActivityLog
                }
            }
            maximumBytes = BugReportAttachmentLimits.maximumV2ReportJSONBytes
        default:
            throw BugReportValidationError.bodyEncodingFailed
        }

        let body: Data
        do {
            body = try JSONEncoder().encode(self)
        } catch {
            throw BugReportValidationError.bodyEncodingFailed
        }
        guard body.count <= maximumBytes else {
            throw BugReportValidationError.bodyTooLarge
        }
        return body
    }
}

/// User-facing validation failures for an anonymous bug-report draft or optional attachment.
enum BugReportValidationError: LocalizedError, Equatable, Sendable {
    case summaryRequired
    case summaryTooLong
    case whatHappenedRequired
    case whatHappenedTooLong
    case stepsTooLong
    case bodyTooLarge
    case bodyEncodingFailed
    case invalidActivityLog
    case screenshotInvalid
    case screenshotTooLarge
    case screenshotLimitExceeded
    case attachmentBodyTooLarge

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
        case .bodyTooLarge:
            "This report is too large. Shorten what happened or the reproduction steps and try again."
        case .bodyEncodingFailed:
            "OpenZCine couldn’t prepare this report. Please try again."
        case .invalidActivityLog:
            "OpenZCine couldn’t prepare the privacy-filtered activity log. Please try again."
        case .screenshotInvalid:
            "OpenZCine couldn’t prepare that screenshot. Choose another image and try again."
        case .screenshotTooLarge:
            "That screenshot is still too large after removing file metadata. Choose a smaller image."
        case .screenshotLimitExceeded:
            "You can attach up to three screenshots."
        case .attachmentBodyTooLarge:
            "The selected attachments are too large. Remove a screenshot and try again."
        }
    }
}

/// An in-memory, freshly rendered PNG attachment with no user-provided name.
struct BugReportScreenshot: Equatable, Identifiable, Sendable {
    let id: UUID
    let pngData: Data

    init(id: UUID = UUID(), pngData: Data) throws {
        guard Self.isPNG(pngData) else { throw BugReportValidationError.screenshotInvalid }
        guard pngData.count <= BugReportAttachmentLimits.maximumScreenshotBytes else {
            throw BugReportValidationError.screenshotTooLarge
        }
        self.id = id
        self.pngData = pngData
    }

    private static func isPNG(_ data: Data) -> Bool {
        data.starts(with: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
    }
}

/// Converts a user-selected image into a small, opaque-name PNG without source metadata.
enum BugReportScreenshotSanitizer {
    private static let maximumSourceBytes = 24 * 1_024 * 1_024
    private static let maximumPixelDimension = 2_560
    private static let minimumPixelDimension = 320

    /// Decodes, orientation-bakes, down-samples, and re-renders a selected image as 8-bit RGBA PNG.
    ///
    /// Only the newly drawn bitmap is encoded. Source EXIF, GPS, TIFF, IPTC, XMP, file names, and
    /// maker information are not copied into the returned data. Metadata chunks emitted by the
    /// platform encoder are stripped before the image enters the report draft.
    static func sanitizedPNG(from sourceData: Data) throws -> Data {
        guard !sourceData.isEmpty, sourceData.count <= maximumSourceBytes,
            let source = CGImageSourceCreateWithData(sourceData as CFData, nil)
        else {
            throw BugReportValidationError.screenshotInvalid
        }

        var dimension = maximumPixelDimension
        while dimension >= minimumPixelDimension {
            guard let thumbnail = thumbnail(from: source, maximumPixelDimension: dimension),
                let normalizedImage = normalizedRGBAImage(from: thumbnail)
            else {
                throw BugReportValidationError.screenshotInvalid
            }

            let pngData = try encodedPNG(from: normalizedImage)
            if pngData.count <= BugReportAttachmentLimits.maximumScreenshotBytes {
                return pngData
            }

            let nextDimension = max(minimumPixelDimension, Int(Double(dimension) * 0.72))
            guard nextDimension < dimension else { break }
            dimension = nextDimension
        }
        throw BugReportValidationError.screenshotTooLarge
    }

    private static func thumbnail(
        from source: CGImageSource,
        maximumPixelDimension: Int
    ) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelDimension,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func normalizedRGBAImage(from image: CGImage) -> CGImage? {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let bitmapInfo =
            CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        guard
            let context = CGContext(
                data: nil,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            )
        else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }

    private static func encodedPNG(from image: CGImage) throws -> Data {
        let output = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                output,
                UTType.png.identifier as CFString,
                1,
                nil
            )
        else {
            throw BugReportValidationError.screenshotInvalid
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw BugReportValidationError.screenshotInvalid
        }
        return try metadataStrippedPNG(from: output as Data)
    }

    private static func metadataStrippedPNG(from encodedPNG: Data) throws -> Data {
        let signature = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        guard encodedPNG.starts(with: signature) else {
            throw BugReportValidationError.screenshotInvalid
        }

        let essentialChunkTypes: Set<String> = ["IHDR", "PLTE", "IDAT", "IEND"]
        var strippedPNG = signature
        var offset = signature.count
        var sawHeader = false
        var sawImageData = false
        var sawEnd = false

        while offset < encodedPNG.count {
            guard encodedPNG.count - offset >= 12 else {
                throw BugReportValidationError.screenshotInvalid
            }

            let payloadLength = (0..<4).reduce(0) { partialResult, index in
                (partialResult << 8) | Int(encodedPNG[offset + index])
            }
            let typeStart = offset + 4
            let payloadStart = offset + 8
            let nextChunkOffset = payloadStart + payloadLength + 4
            guard
                nextChunkOffset <= encodedPNG.count,
                let chunkType = String(data: encodedPNG[typeStart..<payloadStart], encoding: .ascii)
            else {
                throw BugReportValidationError.screenshotInvalid
            }

            switch chunkType {
            case "IHDR":
                guard !sawHeader, !sawImageData, !sawEnd else {
                    throw BugReportValidationError.screenshotInvalid
                }
                sawHeader = true
            case "PLTE":
                guard sawHeader, !sawImageData, !sawEnd else {
                    throw BugReportValidationError.screenshotInvalid
                }
            case "IDAT":
                guard sawHeader, !sawEnd else {
                    throw BugReportValidationError.screenshotInvalid
                }
                sawImageData = true
            case "IEND":
                guard sawHeader, sawImageData, !sawEnd, nextChunkOffset == encodedPNG.count else {
                    throw BugReportValidationError.screenshotInvalid
                }
                sawEnd = true
            default:
                break
            }

            if essentialChunkTypes.contains(chunkType) {
                strippedPNG.append(contentsOf: encodedPNG[offset..<nextChunkOffset])
            }
            offset = nextChunkOffset
        }

        guard sawHeader, sawImageData, sawEnd else {
            throw BugReportValidationError.screenshotInvalid
        }
        return strippedPNG
    }
}

/// A report plus its optional in-memory screenshots. It never retains original file names or data.
struct BugReportSubmission: Equatable, Sendable {
    let report: BugReportPayload
    let screenshots: [BugReportScreenshot]

    init(report: BugReportPayload, screenshots: [BugReportScreenshot] = []) throws {
        let usesV2 = report.activityLog != nil || !screenshots.isEmpty
        guard report.schemaVersion == (usesV2 ? 2 : 1) else {
            throw BugReportValidationError.bodyEncodingFailed
        }
        guard screenshots.count <= BugReportAttachmentLimits.maximumScreenshotCount else {
            throw BugReportValidationError.screenshotLimitExceeded
        }
        guard
            screenshots.reduce(0, { $0 + $1.pngData.count })
                <= BugReportAttachmentLimits.maximumScreenshotAggregateBytes
        else {
            throw BugReportValidationError.attachmentBodyTooLarge
        }
        _ = try report.validatedJSONBody()
        self.report = report
        self.screenshots = screenshots
    }

    var usesAttachmentEndpoint: Bool {
        report.schemaVersion == 2
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
        try payload(baseContext: baseContext, schemaVersion: 1, activityLog: nil)
    }

    func attachmentPayload(
        baseContext: BugReportContext,
        activityLog: [String]?
    ) throws -> BugReportPayload {
        try payload(baseContext: baseContext, schemaVersion: 2, activityLog: activityLog)
    }

    private func payload(
        baseContext: BugReportContext,
        schemaVersion: Int,
        activityLog: [String]?
    ) throws -> BugReportPayload {
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

        let report = BugReportPayload(
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
            ),
            schemaVersion: schemaVersion,
            activityLog: activityLog
        )
        _ = try report.validatedJSONBody()
        return report
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

    func submit(
        _ submission: BugReportSubmission,
        idempotencyKey: UUID
    ) async throws -> BugReportSubmissionReceipt
}

extension BugReportSubmitting {
    func submit(
        _ submission: BugReportSubmission,
        idempotencyKey: UUID
    ) async throws -> BugReportSubmissionReceipt {
        guard !submission.usesAttachmentEndpoint else {
            throw BugReportSubmissionError.unavailable
        }
        return try await submit(submission.report, idempotencyKey: idempotencyKey)
    }
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
        let submission = try BugReportSubmission(report: report)
        return try await submit(submission, idempotencyKey: idempotencyKey)
    }

    func submit(
        _ submission: BugReportSubmission,
        idempotencyKey: UUID
    ) async throws -> BugReportSubmissionReceipt {
        do {
            let request: URLRequest
            if submission.usesAttachmentEndpoint {
                request = try Self.makeMultipartRequest(submission, idempotencyKey: idempotencyKey)
            } else {
                request = try Self.makeRequest(submission.report, idempotencyKey: idempotencyKey)
            }
            return try await submit(request: request)
        } catch let error as BugReportValidationError {
            throw error
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
        guard report.schemaVersion == 1 else { throw BugReportValidationError.bodyEncodingFailed }
        var request = URLRequest(url: SupportLinkCatalog.bugReportEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(idempotencyKey.uuidString, forHTTPHeaderField: "Idempotency-Key")
        request.httpBody = try report.validatedJSONBody()
        return request
    }

    /// Builds the exact, in-memory v2 multipart request so its byte length is fixed before upload.
    static func makeMultipartRequest(
        _ submission: BugReportSubmission,
        idempotencyKey: UUID,
        boundary: String = "OpenZCine-\(UUID().uuidString)"
    ) throws -> URLRequest {
        guard submission.usesAttachmentEndpoint,
            !boundary.isEmpty,
            !boundary.contains("\r"),
            !boundary.contains("\n")
        else {
            throw BugReportValidationError.bodyEncodingFailed
        }

        let reportData = try submission.report.validatedJSONBody()
        var body = Data()
        appendMultipartText("--\(boundary)\r\n", to: &body)
        appendMultipartText(
            "Content-Disposition: form-data; name=\"report\"\r\n"
                + "Content-Type: application/json; charset=utf-8\r\n\r\n",
            to: &body
        )
        body.append(reportData)
        appendMultipartText("\r\n", to: &body)

        for (index, screenshot) in submission.screenshots.enumerated() {
            appendMultipartText("--\(boundary)\r\n", to: &body)
            appendMultipartText(
                "Content-Disposition: form-data; name=\"screenshot\"; "
                    + "filename=\"screenshot-\(index + 1).png\"\r\n"
                    + "Content-Type: image/png\r\n\r\n",
                to: &body
            )
            body.append(screenshot.pngData)
            appendMultipartText("\r\n", to: &body)
        }
        appendMultipartText("--\(boundary)--\r\n", to: &body)

        guard body.count <= BugReportAttachmentLimits.maximumV2MultipartBodyBytes else {
            throw BugReportValidationError.attachmentBodyTooLarge
        }

        var request = URLRequest(url: SupportLinkCatalog.bugReportAttachmentsEndpoint)
        request.httpMethod = "POST"
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )
        request.setValue(idempotencyKey.uuidString, forHTTPHeaderField: "Idempotency-Key")
        request.setValue(String(body.count), forHTTPHeaderField: "Content-Length")
        request.httpBody = body
        return request
    }

    private func submit(request: URLRequest) async throws -> BugReportSubmissionReceipt {
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
    }

    private static func appendMultipartText(_ text: String, to body: inout Data) {
        body.append(contentsOf: text.utf8)
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

/// Supplies the closed-vocabulary activity snapshot when a person explicitly opts in.
protocol BugReportActivityLogProviding: Sendable {
    func activityLog() async -> [String]
}

private struct AppDiagnosticActivityLogProvider: BugReportActivityLogProviding {
    func activityLog() async -> [String] {
        await AppDiagnostics.shared.anonymousActivityLog()
    }
}

/// Main-actor state for the in-app bug-report form.
@MainActor @Observable
final class BugReportFormModel {
    var draft = BugReportDraft()
    var includeActivityLog = false {
        didSet {
            if !includeActivityLog {
                cachedActivityLog = nil
            }
        }
    }
    var includeScreenshots = false {
        didSet {
            if !includeScreenshots {
                screenshots.removeAll()
                attachmentErrorMessage = nil
            }
        }
    }
    private(set) var screenshots: [BugReportScreenshot] = []
    private(set) var attachmentErrorMessage: String?
    private(set) var submissionState: BugReportSubmissionState = .editing

    private let baseContext: BugReportContext
    private let submitter: any BugReportSubmitting
    private let activityLogProvider: any BugReportActivityLogProviding
    private var idempotencyKey = UUID()
    private var lastSubmittedSubmission: BugReportSubmission?
    private var cachedActivityLog: [String]?

    init(
        baseContext: BugReportContext = .current(),
        submitter: any BugReportSubmitting = URLSessionBugReportSubmitter(),
        activityLogProvider: any BugReportActivityLogProviding = AppDiagnosticActivityLogProvider()
    ) {
        self.baseContext = baseContext
        self.submitter = submitter
        self.activityLogProvider = activityLogProvider
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

    /// Re-renders a selected image before retaining it for this in-memory report draft.
    func addScreenshotData(_ sourceData: Data) {
        guard includeScreenshots else { return }
        do {
            guard screenshots.count < BugReportAttachmentLimits.maximumScreenshotCount else {
                throw BugReportValidationError.screenshotLimitExceeded
            }
            let sanitizedData = try BugReportScreenshotSanitizer.sanitizedPNG(from: sourceData)
            screenshots.append(try BugReportScreenshot(pngData: sanitizedData))
            attachmentErrorMessage = nil
        } catch let error as BugReportValidationError {
            attachmentErrorMessage = error.errorDescription
        } catch {
            attachmentErrorMessage = BugReportValidationError.screenshotInvalid.errorDescription
        }
    }

    /// Shows a concise failure when the system picker cannot read a selected image.
    func recordScreenshotImportFailure() {
        attachmentErrorMessage = BugReportValidationError.screenshotInvalid.errorDescription
    }

    func removeScreenshot(id: UUID) {
        screenshots.removeAll { $0.id == id }
        attachmentErrorMessage = nil
    }

    func clearScreenshots() {
        screenshots.removeAll()
        attachmentErrorMessage = nil
    }

    func submit() async {
        guard !isSubmitting else { return }
        do {
            let submission = try await makeSubmission()
            // An uncertain transport result may have created an issue. Reusing the key for this
            // exact body and attachments makes that retry safe; editing either starts a new request.
            if lastSubmittedSubmission != submission {
                idempotencyKey = UUID()
            }
            lastSubmittedSubmission = submission
            submissionState = .submitting
            submissionState = .submitted(
                try await submitter.submit(submission, idempotencyKey: idempotencyKey)
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
        includeActivityLog = false
        includeScreenshots = false
        screenshots.removeAll()
        attachmentErrorMessage = nil
        cachedActivityLog = nil
        idempotencyKey = UUID()
        lastSubmittedSubmission = nil
        submissionState = .editing
    }

    /// Surfaces a route failure without attempting a report over the camera's local-only network.
    func recordInternetRouteFailure() {
        submissionState = .failed(
            "OpenZCine couldn't reach the internet after leaving the camera's Wi-Fi. Check cellular or another Wi-Fi network and try again."
        )
    }

    private func makeSubmission() async throws -> BugReportSubmission {
        let activityLog: [String]?
        if includeActivityLog {
            if let cachedActivityLog {
                activityLog = cachedActivityLog
            } else {
                let snapshot = await activityLogProvider.activityLog()
                cachedActivityLog = snapshot
                activityLog = snapshot
            }
        } else {
            activityLog = nil
        }

        if activityLog != nil || !screenshots.isEmpty {
            let payload = try draft.attachmentPayload(
                baseContext: baseContext,
                activityLog: activityLog
            )
            return try BugReportSubmission(report: payload, screenshots: screenshots)
        }

        return try BugReportSubmission(report: draft.payload(baseContext: baseContext))
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
    static let githubBugReport = requiredURL(
        "https://github.com/erik-sutton95/OpenZCine/issues/new?template=bug_report.yml"
    )
    static let bugReportEndpoint = requiredURL("https://reports.openzcine.app/v1/bug-reports")
    /// The attachment relay endpoint, derived from the stable v1 base rather than duplicated.
    static let bugReportAttachmentsEndpoint: URL = {
        guard
            var components = URLComponents(url: bugReportEndpoint, resolvingAgainstBaseURL: false),
            components.path == "/v1/bug-reports"
        else {
            preconditionFailure("Unexpected checked-in v1 bug-report endpoint")
        }
        components.path = "/v2/bug-reports"
        guard let endpoint = components.url else {
            preconditionFailure("Invalid checked-in v2 bug-report endpoint")
        }
        return endpoint
    }()

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

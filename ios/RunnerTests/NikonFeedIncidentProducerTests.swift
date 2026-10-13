import Foundation
import OpenCineAppKit
import OpenCineApple
import OpenCineMedia
import UIKit
import XCTest

@testable import Runner

/// SIMULATED acquisition owners over the actual app/native JPEG decoder; no camera or upload.
@MainActor
final class NikonFeedIncidentProducerTests: XCTestCase {
    private final class Owner: NSObject {}
    private final class Clock: @unchecked Sendable {
        let lock = NSLock()
        var value: Double = 10
        func read() -> Double { lock.withLock { value } }
    }
    private final class Replacement: @unchecked Sendable {
        let lock = NSLock()
        let successor = Owner()
        var native: MonitorJPEGImageDecoder?
        var old: NikonFeedIncidentProducer?
        var didReplace = false
        func prepare(_ reason: String?) {
            guard reason == nil else { return }
            lock.withLock {
                guard !didReplace else { return }
                didReplace = true
                old?.end()
                _ = native?.source(successor)
            }
        }
    }

    func testActualJPEGDecodeReportsOutputWithoutInventingAcceptancePacketsOrScanout() async throws
    {
        let clock = Clock()
        let producer = makeProducer(clock: clock)
        defer { producer.end() }
        let observer = producer.beginPreview()
        let owner = Owner()
        let decoder = FrameDecoder(native: MonitorJPEGImageDecoder())
        let input = try XCTUnwrap(decoder.source(owner))
        observer.received()
        let image = await decoder.decode(jpeg(), source: input, incident: observer)
        XCTAssertNotNil(image)
        observer.published()
        let sample = producer.snapshot(lifecycle: .init(connected: true), now: clock.read())
        XCTAssertEqual(sample.ages.accessUnitAge, 0)
        XCTAssertEqual(sample.ages.decodedOutputAge, 0)
        XCTAssertNil(sample.ages.packetAge)
        XCTAssertNil(sample.ages.decodeAcceptAge)
        XCTAssertNil(sample.ages.presentAge)
        XCTAssertNil(sample.ingress)
        XCTAssertTrue(sample.lifecycle.outputObservable)
        XCTAssertTrue(sample.lifecycle.liveEstablished)
        XCTAssertFalse(sample.lifecycle.presentationExpected)
    }

    func testRetiredNativeDecodeCallbackCannotPopulateSuccessorConnection() async throws {
        let clock = Clock()
        let old = makeProducer(clock: clock)
        let oldObserver = old.beginPreview()
        let current = makeProducer(clock: clock)
        defer { current.end() }
        let currentObserver = current.beginPreview()
        let gate = Replacement()
        gate.old = old
        let native = MonitorJPEGImageDecoder(unavailable: { gate.prepare($0) })
        gate.native = native
        let decoder = FrameDecoder(native: native)
        let owner = Owner()
        let oldInput = try XCTUnwrap(decoder.source(owner))
        oldObserver.received()
        let retiredImage = await decoder.decode(jpeg(), source: oldInput, incident: oldObserver)
        XCTAssertNil(retiredImage)
        let before = current.snapshot(lifecycle: .init(connected: true), now: clock.read())
        XCTAssertNil(before.ages.accessUnitAge)
        XCTAssertNil(before.ages.decodedOutputAge)
        XCTAssertFalse(before.lifecycle.outputObservable)
        let input = try XCTUnwrap(decoder.source(gate.successor))
        currentObserver.received()
        let currentImage = await decoder.decode(jpeg(), source: input, incident: currentObserver)
        XCTAssertNotNil(currentImage)
        let after = current.snapshot(lifecycle: .init(connected: true), now: clock.read())
        XCTAssertEqual(after.ages.decodedOutputAge, 0)
        XCTAssertTrue(after.lifecycle.outputObservable)
        XCTAssertNil(after.ages.presentAge)
    }

    func testPreviewRestartRejectsOldCapturedObservationWithinTheSameIncidentSource() async throws {
        let clock = Clock()
        let producer = makeProducer(clock: clock)
        defer { producer.end() }
        let old = producer.beginPreview()
        let current = producer.beginPreview()
        let owner = Owner()
        let decoder = FrameDecoder(native: MonitorJPEGImageDecoder())
        let input = try XCTUnwrap(decoder.source(owner))
        old.received()
        let image = await decoder.decode(jpeg(), source: input, incident: old)
        // Decoding itself is unchanged; diagnostics reject retired observation.
        XCTAssertNotNil(image)
        old.published()
        let before = producer.snapshot(lifecycle: .init(connected: true), now: clock.read())
        XCTAssertNil(before.ages.accessUnitAge)
        XCTAssertNil(before.ages.decodedOutputAge)
        XCTAssertFalse(before.lifecycle.liveEstablished)
        current.received()
        let currentImage = await decoder.decode(jpeg(), source: input, incident: current)
        XCTAssertNotNil(currentImage)
        current.published()
        XCTAssertEqual(
            producer.snapshot(lifecycle: .init(connected: true), now: clock.read()).ages
                .decodedOutputAge, 0)
    }

    private func jpeg() -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 32, height: 24)).image { context in
            UIColor.orange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
        }.jpegData(compressionQuality: 0.9)!
    }

    private func makeProducer(clock: Clock) -> NikonFeedIncidentProducer {
        let host = DiagnosticsHost(
            product: "SIMULATED", listingName: "SIMULATED",
            releasePackage: "org.example.simulated", version: "1", build: "1", environment: "test",
            sourceRevision: "test", supportEmail: "support@example.invalid", redact: { $0 })
        let reporting = ReliabilityReporting(
            host: host,
            consent: ReliabilityReportingConsent(
                defaults: UserDefaults(suiteName: UUID().uuidString)!),
            dsn: ReliabilityReportingDSN { [] },
            gate: ReliabilityReportingGate(cameraIPv4Prefix: nil),
            origin: FeedIncidentOrigin(
                derivesTestSource: false, verification: false,
                buildIdentity: nil, injectionActivated: { false }), sink: NoReportSink())
        let runtime = cachedRuntime ?? FeedIncidentRuntime(reporting: reporting, directory: nil)
        cachedRuntime = runtime
        let source = runtime.beginBoundSession(
            .init(
                sessionID: UUID().uuidString, appVersion: "1",
                appBuild: "1", sourceRevision: "test", osName: "test", osVersion: "1",
                hardwareClass: "test", cameraFamily: "test"))
        return NikonFeedIncidentProducer(source: source, clock: clock.read)
    }
    private var cachedRuntime: FeedIncidentRuntime?
    private final class NoReportSink: ReliabilityReportingSink, @unchecked Sendable {
        var isEnabled: Bool { false }
        func start(dsn: String, cacheRoot: URL) {}
        func close() {}
        func flush(timeout: TimeInterval) {}
        func addBreadcrumb(category: String, message: String, data: [String: String]?) {}
        func setTags(_ tags: [String: String]) {}
        func capture(_ event: ReliabilityEvent, attachment: Data, attachmentName: String) {}
    }
}

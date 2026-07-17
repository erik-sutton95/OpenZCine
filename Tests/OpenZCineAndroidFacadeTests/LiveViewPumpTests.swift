// Lifecycle tests for the facade's live-view frame pump against the scripted
// fake ZR: start → frames → stop, disconnect mid-stream, and the latest-wins
// slow-consumer behavior. Frame *payload* parsing is covered by the core's
// PTPLiveViewObject suite; these tests cover what only a socket pair can —
// pump sequencing and the EndLiveView teardown guarantees.

import Foundation
import OpenZCineCore
import Testing

@testable import OpenZCineAndroidFacade

struct LiveViewPumpTests {
    private func connect(to server: FakeZRServer) throws -> PTPIPClientSession {
        try PTPIPClientSession.connect(
            host: "127.0.0.1", port: server.port, timeoutMilliseconds: 2_000)
    }

    @Test func pumpsFramesFromStartToStop() throws {
        let server = try FakeZRServer()
        defer { server.stop() }
        let session = try connect(to: server)
        defer { session.disconnect() }

        let collector = FrameCollector()
        try session.startLiveView(
            onFrame: { frame, timestampNanos in collector.record(frame, at: timestampNanos) },
            onEnded: { collector.markEnded() })
        try collector.waitForFrames(atLeast: 3)

        session.stopLiveView()
        // A returned stop guarantees the terminal callback and a stopped pump.
        #expect(collector.ended)
        let framesAtStop = collector.frameCount
        Thread.sleep(forTimeInterval: 0.15)
        #expect(collector.frameCount == framesAtStop)

        // The body got its EndLiveView — never left streaming (heat-audit rule).
        #expect(!server.isLiveViewActive())
        let operations = server.receivedOperations()
        #expect(operations.contains(.startLiveView))
        #expect(operations.contains(.deviceReady))
        #expect(operations.filter { $0 == .getLiveViewImageEx }.count >= 3)
        #expect(operations.contains(.endLiveView))

        let frames = collector.snapshot()
        #expect(frames.allSatisfy { $0.frame.jpeg.prefix(3) == Data([0xFF, 0xD8, 0xFF]) })
        // Pulled frames only ever move forward (each poll returns the newest),
        // and delivery timestamps are monotonic.
        let counters = frames.map { FakeZRServer.frameCounter(of: $0.frame.timecode) }
        #expect(counters == counters.sorted())
        let timestamps = frames.map(\.timestampNanos)
        #expect(timestamps == timestamps.sorted())
    }

    @Test func disconnectMidStreamStopsPumpAndTearsDownInOrder() throws {
        let server = try FakeZRServer()
        defer { server.stop() }
        let session = try connect(to: server)

        let collector = FrameCollector()
        try session.startLiveView(
            onFrame: { frame, timestampNanos in collector.record(frame, at: timestampNanos) },
            onEnded: { collector.markEnded() })
        try collector.waitForFrames(atLeast: 1)

        session.disconnect()
        #expect(collector.ended)
        #expect(!server.isLiveViewActive())

        // Teardown wire order: the stream is released before the session is.
        let operations = server.receivedOperations()
        let endIndex = try #require(operations.lastIndex(of: .endLiveView))
        let closeIndex = try #require(operations.lastIndex(of: .closeSession))
        #expect(endIndex < closeIndex)

        let framesAtDisconnect = collector.frameCount
        Thread.sleep(forTimeInterval: 0.15)
        #expect(collector.frameCount == framesAtDisconnect)
    }

    @Test func slowConsumerDropsFramesInsteadOfQueueing() throws {
        var options = FakeZRServer.Options()
        options.liveViewFrameIntervalNanoseconds = 10_000_000  // 100 fps source
        let server = try FakeZRServer(options: options)
        defer { server.stop() }
        let session = try connect(to: server)
        defer { session.disconnect() }

        let collector = FrameCollector()
        try session.startLiveView(
            onFrame: { frame, timestampNanos in
                collector.record(frame, at: timestampNanos)
                Thread.sleep(forTimeInterval: 0.15)  // consumer ~6.7 fps
            },
            onEnded: { collector.markEnded() })
        try collector.waitForFrames(atLeast: 4)
        session.stopLiveView()

        // Each ~150 ms stall spans ~15 source frames: deliveries must skip
        // ahead (latest-wins at the source), never replay a queued backlog.
        let counters = collector.snapshot().map {
            FakeZRServer.frameCounter(of: $0.frame.timecode)
        }
        #expect(counters == counters.sorted())
        #expect(zip(counters, counters.dropFirst()).contains { $1 - $0 > 1 })
        // Delivered volume tracks the consumer's pace, not the source's 100 fps.
        #expect(collector.frameCount < 15)
    }

    @Test func secondStartWhileStreamingIsRejected() throws {
        let server = try FakeZRServer()
        defer { server.stop() }
        let session = try connect(to: server)
        defer { session.disconnect() }

        let collector = FrameCollector()
        try session.startLiveView(
            onFrame: { frame, timestampNanos in collector.record(frame, at: timestampNanos) },
            onEnded: { collector.markEnded() })
        defer { session.stopLiveView() }

        #expect(throws: PTPIPClientSessionError.liveViewAlreadyActive) {
            try session.startLiveView(onFrame: { _, _ in }, onEnded: {})
        }
    }

    @Test func liveViewFramesReflectTheCameraRecordingState() throws {
        let server = try FakeZRServer()
        defer { server.stop() }
        let session = try connect(to: server)
        defer { session.disconnect() }

        let collector = FrameCollector()
        try session.startLiveView(
            onFrame: { frame, timestamp in collector.record(frame, at: timestamp) },
            onEnded: { collector.markEnded() })
        try collector.waitForFrames(atLeast: 2)
        #expect(!collector.snapshot().contains { $0.frame.isRecording })

        try session.startRecording()
        try collector.waitForRecordingState(true)

        try session.stopRecording()
        try collector.waitForRecordingState(false, afterRecording: true)
        session.stopLiveView()
    }

    @Test func mediaOwnershipStopsAndExcludesLiveViewUntilReleased() throws {
        let server = try FakeZRServer()
        defer { server.stop() }
        let session = try connect(to: server)
        defer { session.disconnect() }

        let first = FrameCollector()
        try session.startLiveView(
            onFrame: { frame, timestamp in first.record(frame, at: timestamp) },
            onEnded: { first.markEnded() })
        try first.waitForFrames(atLeast: 1)

        session.enterMediaMode()
        #expect(first.ended)
        #expect(!server.isLiveViewActive())
        #expect(throws: PTPIPClientSessionError.mediaModeActive) {
            try session.startLiveView(onFrame: { _, _ in }, onEnded: {})
        }

        session.exitMediaMode()
        let resumed = FrameCollector()
        try session.startLiveView(
            onFrame: { frame, timestamp in resumed.record(frame, at: timestamp) },
            onEnded: { resumed.markEnded() })
        try resumed.waitForFrames(atLeast: 1)
        session.stopLiveView()
        #expect(resumed.ended)
    }

    /// Not a test: an opt-in dev server for the on-device end-to-end. Run
    /// `ZC_FAKE_ZR_PORT=15740 swift test --filter servesFakeZRForDevice` on the
    /// Mac, `adb reverse tcp:15740 tcp:15740`, then launch the app with
    /// `--es zc.session.host 127.0.0.1`. Serves for an hour or until killed.
    /// `ZC_FAKE_ZR_RAW_CROP=1` starts in R3D NE with the documented FX/DX RAW
    /// frame-size domain so the Android picker can be visually checked.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ZC_FAKE_ZR_PORT"] != nil))
    func servesFakeZRForDeviceEndToEnd() throws {
        var options = FakeZRServer.Options()
        options.port =
            UInt16(ProcessInfo.processInfo.environment["ZC_FAKE_ZR_PORT"] ?? "") ?? 15_740
        if ProcessInfo.processInfo.environment["ZC_FAKE_ZR_RAW_CROP"] == "1" {
            let r3dNE: UInt32 = 0x0031_0A03
            let nRAW: UInt32 = 0x0002_0C02
            let fx6K25 = UInt64(6_048) << 48 | UInt64(3_402) << 32 | UInt64(25) << 16
            let fx4K50 = UInt64(4_032) << 48 | UInt64(2_268) << 32 | UInt64(50) << 16
            let dx4K100 = UInt64(3_984) << 48 | UInt64(2_240) << 32 | UInt64(100) << 16
            options.movieFileTypeRaw = r3dNE
            options.movieRecordScreenSizeRaw = fx6K25
            options.descriptorEnumOverrides[.movieFileType] = [r3dNE, nRAW]
            options.screenSizeModesByFileType = [
                r3dNE: [fx6K25, fx4K50, dx4K100],
                nRAW: [fx6K25, fx4K50, dx4K100],
            ]
        }
        let server = try FakeZRServer(options: options)
        print("fake ZR serving on 127.0.0.1:\(server.port) — Ctrl-C to stop")
        Thread.sleep(forTimeInterval: 3_600)
        server.stop()
    }
}

/// Thread-safe frame/end sink for pump assertions.
// SAFETY: `@unchecked Sendable` — all mutable state is guarded by `lock`.
private final class FrameCollector: @unchecked Sendable {
    private struct TimedOut: Error {}

    private let lock = NSLock()
    private var frames: [(frame: PTPLiveViewFrame, timestampNanos: Int64)] = []
    private var endedFlag = false

    func record(_ frame: PTPLiveViewFrame, at timestampNanos: Int64) {
        lock.lock()
        frames.append((frame, timestampNanos))
        lock.unlock()
    }

    func markEnded() {
        lock.lock()
        endedFlag = true
        lock.unlock()
    }

    var ended: Bool {
        lock.lock()
        defer { lock.unlock() }
        return endedFlag
    }

    var frameCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return frames.count
    }

    func snapshot() -> [(frame: PTPLiveViewFrame, timestampNanos: Int64)] {
        lock.lock()
        defer { lock.unlock() }
        return frames
    }

    /// Polls until at least `count` frames arrived; throws past `timeoutSeconds`.
    func waitForFrames(atLeast count: Int, timeoutSeconds: TimeInterval = 5) throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if frameCount >= count { return }
            Thread.sleep(forTimeInterval: 0.02)
        }
        throw TimedOut()
    }

    func waitForRecordingState(
        _ recording: Bool,
        afterRecording: Bool = false,
        timeoutSeconds: TimeInterval = 5
    ) throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            let observed = snapshot().map(\.frame.isRecording)
            let matched =
                if afterRecording {
                    observed.contains(true) && observed.last == recording
                } else {
                    observed.contains(recording)
                }
            if matched { return }
            Thread.sleep(forTimeInterval: 0.02)
        }
        throw TimedOut()
    }
}

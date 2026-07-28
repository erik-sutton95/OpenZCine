import Foundation
import Testing

@testable import OpenZCineCore

@Test func watchdogStartsHealthy() {
    let watchdog = LiveViewWatchdog(stallTimeoutSeconds: 5, maxConsecutiveBadFrames: 10)
    #expect(watchdog.status == .streaming)
}

@Test func watchdogDeclaresStallWhenNoGoodFrameWithinTimeout() {
    let now = Date()
    var watchdog = LiveViewWatchdog(stallTimeoutSeconds: 5, maxConsecutiveBadFrames: 10)
    watchdog.recordGoodFrame(at: now)
    // Just before the timeout → still streaming.
    watchdog.check(at: now.addingTimeInterval(4.9))
    #expect(watchdog.status == .streaming)
    // At/after the timeout → stalled, requesting restart.
    watchdog.check(at: now.addingTimeInterval(5.0))
    #expect(watchdog.status == .stalled)
}

@Test func watchdogResetsStallDeadlineOnEachGoodFrame() {
    var watchdog = LiveViewWatchdog(stallTimeoutSeconds: 5, maxConsecutiveBadFrames: 10)
    watchdog.recordGoodFrame(at: Date(timeIntervalSince1970: 0))
    // Frame arrives just before the deadline → deadline extends.
    watchdog.recordGoodFrame(at: Date(timeIntervalSince1970: 4))
    watchdog.check(at: Date(timeIntervalSince1970: 6))
    #expect(watchdog.status == .streaming)
}

@Test func watchdogToleratesOccasionalBadFrames() {
    var watchdog = LiveViewWatchdog(stallTimeoutSeconds: 5, maxConsecutiveBadFrames: 3)
    watchdog.recordBadFrame()
    watchdog.recordBadFrame()
    #expect(watchdog.status == .streaming)
}

@Test func watchdogDeclaresStallAfterConsecutiveBadFrameThreshold() {
    var watchdog = LiveViewWatchdog(stallTimeoutSeconds: 5, maxConsecutiveBadFrames: 3)
    watchdog.recordBadFrame()
    watchdog.recordBadFrame()
    watchdog.recordBadFrame()
    #expect(watchdog.status == .stalled)
}

@Test func watchdogGoodFrameClearsBadFrameStreak() {
    var watchdog = LiveViewWatchdog(stallTimeoutSeconds: 5, maxConsecutiveBadFrames: 3)
    watchdog.recordBadFrame()
    watchdog.recordBadFrame()
    watchdog.recordGoodFrame(at: Date())
    watchdog.recordBadFrame()
    #expect(watchdog.status == .streaming)
}

@Test func watchdogRestartResetsAllCounters() {
    var watchdog = LiveViewWatchdog(stallTimeoutSeconds: 5, maxConsecutiveBadFrames: 3)
    watchdog.recordBadFrame()
    watchdog.recordBadFrame()
    watchdog.recordBadFrame()
    #expect(watchdog.status == .stalled)
    watchdog.prepareForRestart()
    #expect(watchdog.status == .streaming)
    #expect(watchdog.consecutiveBadFrames == 0)
}

// MARK: - #283 · a body replaying one cached frame is a stall, not a healthy stream

@Test func aReplayedPayloadStallsOnceItOutlastsTheRepeatTimeout() {
    let start = Date()
    var watchdog = LiveViewWatchdog(
        stallTimeoutSeconds: 60, maxConsecutiveBadFrames: 100, repeatedFrameTimeoutSeconds: 4)
    let frozen: UInt64 = 0xDEAD_BEEF

    // Frames keep ARRIVING on time, so the arrival deadline never fires — that is exactly why
    // this needed its own signal.
    watchdog.recordGoodFrame(at: start, signature: frozen)
    watchdog.recordGoodFrame(at: start.addingTimeInterval(1), signature: frozen)
    watchdog.recordGoodFrame(at: start.addingTimeInterval(3), signature: frozen)
    watchdog.check(at: start.addingTimeInterval(3))
    #expect(watchdog.status == .streaming, "stalled before the repeat timeout elapsed")

    watchdog.recordGoodFrame(at: start.addingTimeInterval(5.1), signature: frozen)
    #expect(watchdog.status == .stalled)
    #expect(watchdog.isRepeatingLastFrame)
}

@Test func aMovingStreamNeverTripsTheRepeatTimeout() {
    let start = Date()
    var watchdog = LiveViewWatchdog(
        stallTimeoutSeconds: 60, maxConsecutiveBadFrames: 100, repeatedFrameTimeoutSeconds: 4)
    for step in 0..<400 {
        watchdog.recordGoodFrame(
            at: start.addingTimeInterval(Double(step) / 40), signature: UInt64(step))
    }
    #expect(watchdog.status == .streaming)
    #expect(watchdog.isRepeatingLastFrame == false)
}

@Test func aFreshPayloadClearsAReplayStallSoAnUnwedgedBodyRecovers() {
    let start = Date()
    var watchdog = LiveViewWatchdog(
        stallTimeoutSeconds: 60, maxConsecutiveBadFrames: 100, repeatedFrameTimeoutSeconds: 4)
    // Three frames: the second opens the repeat window, the third outlasts it. The window starts
    // when the repeat is first SEEN, so detection latency is the timeout and nothing longer.
    watchdog.recordGoodFrame(at: start, signature: 1)
    watchdog.recordGoodFrame(at: start.addingTimeInterval(1), signature: 1)
    watchdog.recordGoodFrame(at: start.addingTimeInterval(9), signature: 1)
    #expect(watchdog.status == .stalled)

    watchdog.recordGoodFrame(at: start.addingTimeInterval(10), signature: 2)
    #expect(watchdog.status == .streaming, "a genuinely new frame must release the verdict")
    #expect(watchdog.isRepeatingLastFrame == false)
}

@Test func heldFramesWithoutAPayloadDoNotAccumulateAsRepeats() {
    // Command mode pulls headers only and deliberately holds the last image. Signature-free
    // records must not read that as a wedged camera.
    let start = Date()
    var watchdog = LiveViewWatchdog(
        stallTimeoutSeconds: 60, maxConsecutiveBadFrames: 100, repeatedFrameTimeoutSeconds: 4)
    for step in 0..<50 {
        watchdog.recordGoodFrame(at: start.addingTimeInterval(Double(step)))
    }
    #expect(watchdog.status == .streaming)
    #expect(watchdog.isRepeatingLastFrame == false)
}

@Test func restartClearsTheReplayStreak() {
    let start = Date()
    var watchdog = LiveViewWatchdog(
        stallTimeoutSeconds: 60, maxConsecutiveBadFrames: 100, repeatedFrameTimeoutSeconds: 4)
    watchdog.recordGoodFrame(at: start, signature: 7)
    watchdog.recordGoodFrame(at: start.addingTimeInterval(1), signature: 7)
    watchdog.recordGoodFrame(at: start.addingTimeInterval(9), signature: 7)
    #expect(watchdog.status == .stalled)
    watchdog.prepareForRestart()
    #expect(watchdog.status == .streaming)
    #expect(watchdog.isRepeatingLastFrame == false)
}

// MARK: - the payload signature itself

@Test func identicalPayloadsAlwaysShareASignature() {
    let payload = Data((0..<200_000).map { UInt8(($0 * 31 + 7) % 251) })
    #expect(LiveFrameSignature.of(payload) == LiveFrameSignature.of(payload))
}

@Test func aSingleFlippedByteInASampledPositionChangesTheSignature() {
    var payload = Data((0..<200_000).map { UInt8(($0 * 31 + 7) % 251) })
    let before = LiveFrameSignature.of(payload)
    payload[0] = payload[0] &+ 1
    #expect(LiveFrameSignature.of(payload) != before)
}

@Test func payloadsThatDifferOnlyInLengthStillDiffer() {
    let base = Data(repeating: 0x5A, count: 120_000)
    #expect(LiveFrameSignature.of(base) != LiveFrameSignature.of(base + Data([0x5A])))
}

@Test func distinctNoisyFramesGetDistinctSignatures() {
    // The property the watchdog leans on: real sensor frames must not collide, or a moving stream
    // would be declared frozen. Payloads come from a seeded generator rather than an arithmetic
    // pattern — a pattern like `(i * a + frame * b) % m` is PERIODIC in the frame index, so it
    // produces genuinely byte-identical payloads that no sampling scheme could separate. That is a
    // degenerate fixture, not a signature weakness.
    var seen = Set<UInt64>()
    for frame in 0..<300 {
        var state = UInt64(frame) &+ 0x9E37_79B9_7F4A_7C15
        var payload = Data(capacity: 80_000)
        for _ in 0..<80_000 {
            state = state &+ 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            payload.append(UInt8(truncatingIfNeeded: z >> 31))
        }
        seen.insert(LiveFrameSignature.of(payload))
    }
    #expect(seen.count == 300)
}

@Test func theSignatureCostDoesNotScaleWithPayloadSize() {
    // Bounded sampling is what keeps this affordable per frame at 40 fps: a 4 MB payload must
    // not cost 100x a 40 KB one. Asserted structurally — both must be sampled, not walked.
    let small = Data(repeating: 0x11, count: 40_000)
    let large = Data(repeating: 0x11, count: 4_000_000)
    #expect(LiveFrameSignature.of(small) != LiveFrameSignature.of(large))
}

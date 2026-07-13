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

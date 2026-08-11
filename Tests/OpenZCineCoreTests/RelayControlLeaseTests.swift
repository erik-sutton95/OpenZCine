import Foundation
import Testing

@testable import OpenZCineCore

private let t0 = Date(timeIntervalSince1970: 1_000)

/// The blink this exists for: the watcher's link drops and comes back inside the window, and it is
/// still holding the camera. Nobody had to notice, and nobody had to ask for it again.
@Test func aWatcherThatComesBackKeepsTheControlItHeld() {
    var lease = RelayControlLease()

    let parked = lease.park(watcherID: "watcher-a", now: t0)
    #expect(parked)
    #expect(lease.isParked(at: t0.addingTimeInterval(5)))
    let resumed = lease.claim(watcherID: "watcher-a", now: t0.addingTimeInterval(5))
    #expect(resumed)
    // Claimed once and only once — a second socket cannot inherit the same parked claim.
    let twice = lease.claim(watcherID: "watcher-a", now: t0.addingTimeInterval(6))
    #expect(!twice)
}

/// The window has to outlast the watcher's OWN idea of having dropped, or it can never be used:
/// a stalled session is not declared dead for 8 s, and the rejoin ticks every 3 s after that.
@Test func theWindowOutlastsTheWatchersOwnStallDeadline() {
    #expect(RelayControlLease.defaultWindowSeconds >= 14)
    var lease = RelayControlLease()
    _ = lease.park(watcherID: "watcher-a", now: t0)
    // 8 s to notice the stall, then a 3 s tick, then another to re-find the broadcast.
    #expect(lease.isParked(at: t0.addingTimeInterval(14)))
}

/// And it does end. A watcher that walked off set does not hold the camera indefinitely.
@Test func aWatcherThatNeverComesBackLosesTheCamera() {
    var lease = RelayControlLease(windowSeconds: 20)
    _ = lease.park(watcherID: "watcher-a", now: t0)

    let after = t0.addingTimeInterval(20.001)
    #expect(!lease.isParked(at: after))
    #expect(lease.parkedWatcherID(at: after) == nil)
    let expired = lease.claim(watcherID: "watcher-a", now: after)
    #expect(!expired)
}

/// A parked claim belongs to ONE device. This token presses record, so a near-miss is a miss.
@Test func onlyTheWatcherThatHeldItCanResumeIt() {
    var lease = RelayControlLease()
    _ = lease.park(watcherID: "watcher-a", now: t0)

    let wrongDevice = lease.claim(watcherID: "watcher-b", now: t0.addingTimeInterval(1))
    let anonymous = lease.claim(watcherID: nil, now: t0.addingTimeInterval(1))
    let empty = lease.claim(watcherID: "", now: t0.addingTimeInterval(1))
    #expect(!wrongDevice)
    #expect(!anonymous)
    #expect(!empty)
    // Refused claims leave the real holder's claim intact.
    let realHolder = lease.claim(watcherID: "watcher-a", now: t0.addingTimeInterval(2))
    #expect(realHolder)
}

/// A watcher we could never recognise on return is not parked at all — freezing the camera for a
/// device that can never come back would be worse than the behaviour this replaces.
@Test func anUnrecognisableWatcherReleasesImmediatelyAsBefore() {
    var lease = RelayControlLease()

    let parkedNil = lease.park(watcherID: nil, now: t0)
    #expect(!parkedNil)
    #expect(!lease.isParked(at: t0))

    let parkedEmpty = lease.park(watcherID: "", now: t0)
    #expect(!parkedEmpty)
    #expect(!lease.isParked(at: t0))
}

/// The operator never waits out the window, and a deliberate hand-back is not a disconnection.
@Test func reclaimingAndReleasingBothEndTheClaimAtOnce() {
    var lease = RelayControlLease()
    _ = lease.park(watcherID: "watcher-a", now: t0)

    lease.clear()

    #expect(!lease.isParked(at: t0.addingTimeInterval(1)))
    let afterClear = lease.claim(watcherID: "watcher-a", now: t0.addingTimeInterval(1))
    #expect(!afterClear)
}

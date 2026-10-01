import Testing

@testable import OpenZCineAndroidFacade

/// The JNI facade's owner routing: every session-scoped call resolves exactly
/// its own owner's session, and an unknown owner resolves to nothing (NoSession)
/// rather than falling back to whichever camera connected last.
struct AndroidSessionOwnerRegistryTests {
    private final class Session {}
    private final class Transport {}
    private typealias Registry = AndroidSessionOwnerRegistry<Session, Transport>

    private func connect(_ registry: Registry, owner: Int64) -> Session {
        let session = Session()
        _ = registry.beginConnection(owner: owner)
        #expect(registry.completeConnection(owner: owner, session: session).accepted)
        return session
    }

    @Test func eachOwnerResolvesOnlyItsOwnSession() {
        let registry = Registry()
        let cameraA = connect(registry, owner: 1)
        let cameraB = connect(registry, owner: 2)

        // B connected last; A's commands must still land on A.
        #expect(registry.session(for: 1) === cameraA)
        #expect(registry.session(for: 2) === cameraB)
    }

    @Test func unknownOwnerNeverFallsBackToAnotherCamera() {
        let registry = Registry()
        _ = connect(registry, owner: 1)

        #expect(registry.session(for: 2) == nil)
        #expect(registry.session(for: 0) == nil)
    }

    @Test func disconnectingOneOwnerLeavesTheOtherLiveAndUnreachableByTheFormer() {
        let registry = Registry()
        _ = connect(registry, owner: 1)
        let cameraB = connect(registry, owner: 2)

        let removed = registry.takeOwnedConnection(owner: 1)
        #expect(removed.session != nil)
        #expect(registry.session(for: 1) == nil)
        #expect(registry.session(for: 2) === cameraB)
        // A stale second teardown for A is a no-op, never B's session.
        #expect(registry.takeOwnedConnection(owner: 1).session == nil)
        #expect(registry.session(for: 2) === cameraB)
    }

    @Test func pendingAttemptIsNotRoutableUntilItCompletes() {
        let registry = Registry()
        _ = registry.beginConnection(owner: 1)
        #expect(registry.session(for: 1) == nil)
    }

    @Test func cancelledAttemptCannotPublishALateSession() {
        let registry = Registry()
        let transport = Transport()
        _ = registry.beginConnection(owner: 1, pendingTransport: transport)

        #expect(registry.takeOwnedConnection(owner: 1).pendingTransport === transport)
        #expect(!registry.completeConnection(owner: 1, session: Session()).accepted)
        #expect(registry.session(for: 1) == nil)
    }

    @Test func reconnectingAnOwnerDisplacesOnlyItsOwnSession() {
        let registry = Registry()
        let first = connect(registry, owner: 1)
        let other = connect(registry, owner: 2)
        let replacement = Session()

        _ = registry.beginConnection(owner: 1)
        let completion = registry.completeConnection(owner: 1, session: replacement)
        #expect(completion.accepted)
        #expect(completion.displacedSession === first)
        #expect(registry.session(for: 1) === replacement)
        #expect(registry.session(for: 2) === other)
    }

    @Test func supersededPendingTransportIsReturnedOnlyToItsOwner() {
        let registry = Registry()
        let usbA = Transport()
        _ = registry.beginConnection(owner: 1, pendingTransport: usbA)
        _ = registry.beginConnection(owner: 2, pendingTransport: Transport())

        #expect(registry.beginConnection(owner: 1, pendingTransport: Transport()) === usbA)
        #expect(registry.clearPendingConnection(owner: 2) != nil)
        #expect(registry.clearPendingConnection(owner: 2) == nil)
    }
}

/// STATE-01: two owners live at once through every completion and teardown
/// path, including a late completion that lands after its owner was closed.
struct AndroidSessionOwnerRegistryConcurrentOwnerTests {
    private final class Session {}
    private final class Transport {}
    private typealias Registry = AndroidSessionOwnerRegistry<Session, Transport>

    @Test func twoOwnersNeverCrossOnConnectCommandCloseOrLateCompletion() {
        let registry = Registry()
        let usbB = Transport()
        _ = registry.beginConnection(owner: 1)
        _ = registry.beginConnection(owner: 2, pendingTransport: usbB)

        // A connects while B is still handshaking: B's pending claim survives.
        let cameraA = Session()
        #expect(registry.completeConnection(owner: 1, session: cameraA).accepted)
        #expect(registry.session(for: 2) == nil)

        // A closes; its teardown must not take B's pending transport.
        let closedA = registry.takeOwnedConnection(owner: 1)
        #expect(closedA.session === cameraA)
        #expect(closedA.pendingTransport == nil)

        // A late completion for A (a slow socket after close) is refused.
        #expect(!registry.completeConnection(owner: 1, session: Session()).accepted)
        #expect(registry.session(for: 1) == nil)

        // B completes and is the only routable session; commands for A miss.
        let cameraB = Session()
        let completionB = registry.completeConnection(owner: 2, session: cameraB)
        #expect(completionB.accepted)
        #expect(completionB.displacedSession == nil)
        #expect(registry.session(for: 2) === cameraB)
        #expect(registry.session(for: 1) == nil)

        // A failed retry of A clears only A; B stays live until its own close.
        _ = registry.beginConnection(owner: 1)
        #expect(registry.clearPendingConnection(owner: 1) == nil)
        #expect(registry.session(for: 2) === cameraB)
        #expect(registry.takeOwnedConnection(owner: 2).session === cameraB)
        #expect(registry.takeOwnedConnection(owner: 2).session == nil)
    }

    @Test func parallelOwnersResolveOnlyTheirOwnSessions() async {
        let registry = Registry()
        let owners = Array(Int64(1)...Int64(32))
        await withTaskGroup(of: Bool.self) { group in
            for owner in owners {
                group.addTask {
                    let session = Session()
                    _ = registry.beginConnection(owner: owner)
                    guard registry.completeConnection(owner: owner, session: session).accepted
                    else { return false }
                    let routed = registry.session(for: owner) === session
                    let removed = registry.takeOwnedConnection(owner: owner).session === session
                    return routed && removed && registry.session(for: owner) == nil
                }
            }
            for await ok in group { #expect(ok) }
        }
    }
}

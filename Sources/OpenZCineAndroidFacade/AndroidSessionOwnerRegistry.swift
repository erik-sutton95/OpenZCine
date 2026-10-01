import Foundation

/// The JNI facade's session table, keyed by the opaque connection owner each
/// Kotlin `SwiftCoreCameraSession` attempt generates.
///
/// Multicam holds one live session per owner (USB-C and LAN bodies side by
/// side), so there is deliberately no "current" or "last connected" session:
/// every session-scoped JNI call names its owner and an unknown owner resolves
/// to `nil` (the caller reports NoSession). A command can therefore never fall
/// through to another camera's session.
///
/// Generic over the session and pending-transport types so the routing rules
/// are testable on Darwin; the Android facade instantiates it with
/// `PTPIPClientSession` and `AndroidUSBPTPTransport`.
final class AndroidSessionOwnerRegistry<Session: AnyObject, PendingTransport: AnyObject>:
    @unchecked Sendable
{
    private let lock = NSLock()
    private var sessions: [Int64: Session] = [:]
    private var pendingOwners: Set<Int64> = []
    private var pendingTransports: [Int64: PendingTransport] = [:]

    /// Begins a connection attempt for `owner` and returns only a superseded
    /// pending transport of THAT owner. Other owners' sessions stay live.
    func beginConnection(owner: Int64, pendingTransport: PendingTransport? = nil)
        -> PendingTransport?
    {
        lock.lock()
        defer { lock.unlock() }
        let superseded = pendingTransports[owner]
        pendingOwners.insert(owner)
        pendingTransports[owner] = pendingTransport
        return superseded
    }

    /// The session `owner` established, or `nil` when it has none.
    func session(for owner: Int64) -> Session? {
        lock.lock()
        defer { lock.unlock() }
        return sessions[owner]
    }

    /// Promotes exactly this owner's pending request. A rejected completion
    /// (cancelled or never begun) must disconnect its local session without
    /// publishing a late Kotlin success callback.
    func completeConnection(owner: Int64, session new: Session) -> (
        accepted: Bool, displacedSession: Session?
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard pendingOwners.remove(owner) != nil else { return (false, nil) }
        pendingTransports.removeValue(forKey: owner)
        let displaced = sessions.updateValue(new, forKey: owner)
        return (true, displaced)
    }

    /// Clears one failed/cancelled pending request and returns its claimed
    /// transport, if any, for teardown outside the lock.
    func clearPendingConnection(owner: Int64) -> PendingTransport? {
        lock.lock()
        defer { lock.unlock() }
        guard pendingOwners.remove(owner) != nil else { return nil }
        return pendingTransports.removeValue(forKey: owner)
    }

    /// Atomically takes only `owner`'s resources, so cleanup for a cancelled
    /// attempt A can never close retry B or another camera's session.
    func takeOwnedConnection(owner: Int64) -> (
        session: Session?, pendingTransport: PendingTransport?
    ) {
        lock.lock()
        defer { lock.unlock() }
        pendingOwners.remove(owner)
        return (sessions.removeValue(forKey: owner), pendingTransports.removeValue(forKey: owner))
    }
}

import Darwin
import Foundation
import os

private let transportLogger = Logger(
    subsystem: "OpenZCine",
    category: "camera-connection"
)

/// PTP-IP camera transport: two TCP sockets (command + event) to port 15740, the CIPA DC-005
/// Init handshake, and PTP-IP packet framing — behind the transaction-level `CameraTransport`
/// boundary shared with the USB-C transport.
// SAFETY: `@unchecked Sendable` — `nextTransactionID` is mutated only inside transactions
// serialized by `transactionGate` (`AsyncSerialGate`); socket I/O is serialized on each
// `PTPIPSocket`'s own dispatch queue.
final class PTPIPTransport: CameraTransport, @unchecked Sendable {
    /// How many times the idle limit a single transaction may run before it is killed regardless
    /// of still-arriving bytes. Generous on purpose: the ceiling is a backstop against a body that
    /// trickles forever, not a second opinion on whether a slow link is worth waiting for.
    static let idleDeadlineCeilingMultiple: Double = 4

    private init(
        host: String,
        command: PTPIPSocket,
        event: PTPIPSocket,
        connectionNumber: UInt32,
        cameraName: String?
    ) {
        self.host = host
        self.command = command
        self.event = event
        self.connectionNumber = connectionNumber
        self.cameraName = cameraName
    }

    /// Camera IPv4 address this transport is connected to.
    let host: String
    /// Connection number assigned by the camera's Init_Command_Ack.
    let connectionNumber: UInt32
    /// Camera friendly name reported during the Init handshake.
    let cameraName: String?

    var kind: CameraTransportKind { .ptpIP }

    private let command: PTPIPSocket
    private let event: PTPIPSocket
    private var nextTransactionID: UInt32 = 1
    private let transactionGate = AsyncSerialGate()

    /// Opens the command + event TCP connections and runs the PTP-IP Init handshake.
    static func connect(
        host rawHost: String,
        guid: Data,
        friendlyName: String = PTPIPInitiator.friendlyName
    ) async throws -> PTPIPTransport {
        let host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { throw NativeCameraSessionError.noHost }

        let command = PTPIPSocket(host: host, port: UInt16(ptpIPPort), label: "command")
        var event: PTPIPSocket?
        do {
            try await command.start()
            let initRequest = try PTPIPInitCommandRequest(guid: guid, friendlyName: friendlyName)
            try await command.send(
                PTPIPPacket(type: .initCommandRequest, payload: Data(initRequest.payloadBytes))
            )

            let initReply = try await command.readPacket()
            if initReply.type == .initFail {
                let fail = try PTPIPInitFail(payloadBytes: Array(initReply.payload))
                throw NativeCameraSessionError.initFailed(fail.reason)
            }
            guard initReply.type == .initCommandAck else {
                throw NativeCameraSessionError.unexpectedPacket(
                    expected: "Init_Command_Ack",
                    actual: initReply.type
                )
            }
            let ack = try PTPIPInitCommandAck(payloadBytes: Array(initReply.payload))

            let eventSocket = PTPIPSocket(host: host, port: UInt16(ptpIPPort), label: "event")
            event = eventSocket
            try await eventSocket.start()
            try await eventSocket.send(
                PTPIPPacket(
                    type: .initEventRequest,
                    payload: Data(
                        PTPIPInitEventRequest(connectionNumber: ack.connectionNumber).payloadBytes)
                )
            )
            let eventReply = try await eventSocket.readPacket()
            guard eventReply.type == .initEventAck else {
                throw NativeCameraSessionError.unexpectedPacket(
                    expected: "Init_Event_Ack",
                    actual: eventReply.type
                )
            }

            return PTPIPTransport(
                host: host,
                command: command,
                event: eventSocket,
                connectionNumber: ack.connectionNumber,
                cameraName: ack.cameraName
            )
        } catch {
            command.close()
            event?.close()
            throw error
        }
    }

    /// Minimal Init handshake on the command channel only, used by subnet discovery to identify a
    /// PTP-IP responder without opening a session. Returns the camera name, a placeholder for a
    /// responder that refused the handshake, or nil when nothing answered.
    static func probeCameraName(
        host rawHost: String,
        guid: Data,
        friendlyName: String = PTPIPInitiator.friendlyName,
        timeoutMilliseconds: UInt64 = 1_000
    ) async throws -> String? {
        let host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return nil }

        let command = PTPIPSocket(
            host: host,
            port: UInt16(ptpIPPort),
            label: "discovery",
            timeoutMilliseconds: timeoutMilliseconds
        )
        do {
            try await command.start()
            let initRequest = try PTPIPInitCommandRequest(guid: guid, friendlyName: friendlyName)
            try await command.send(
                PTPIPPacket(type: .initCommandRequest, payload: Data(initRequest.payloadBytes))
            )
            let initReply = try await command.readPacket()
            command.close()

            if initReply.type == .initCommandAck {
                let ack = try PTPIPInitCommandAck(payloadBytes: Array(initReply.payload))
                return ack.cameraName ?? "PTP-IP Camera"
            }
            if initReply.type == .initFail {
                return "PTP-IP Camera"
            }
            return nil
        } catch {
            command.close()
            return nil
        }
    }

    func executeTransaction(
        operationCode: PTPOperationCode,
        transactionID explicitTransactionID: UInt32?,
        parameters: [UInt32],
        dataPhase: PTPDataPhase,
        dataOut: Data?,
        deadline: Duration?
    ) async throws -> PTPIPTransactionResult {
        // Throws `CancellationError` if this task is cancelled while queued — the gate was never
        // acquired, so no `signal()` (the defer below is only registered after acquisition).
        try await transactionGate.wait()
        defer { transactionGate.signal() }
        // Cancelled between acquiring the gate and sending: bail before touching the socket so a
        // stale transaction (e.g. an orphaned live-view fetch after a stall restart) never runs.
        try Task.checkCancellation()

        // Whole-transaction deadline. The send/read calls below block in non-cancellable syscalls
        // on the socket queue, so task cancellation can't interrupt them. On breach we close the
        // command socket instead: `closeDescriptor()` does shutdown(SHUT_RDWR), which wakes the
        // blocked poll and sets the descriptor to -1 — the transaction unwinds, the gate frees, and
        // the next read fails fast rather than reading a desynchronized stream; the session then
        // reconnects. Live-view fetches pass a finite deadline too: the LiveViewWatchdog only
        // evaluates BETWEEN completed frames, so an unbounded fetch that never returns would hold
        // the gate forever and deaden every other command.
        //
        // The bound is IDLE time, not elapsed time. On a narrow or congested link — 2.4 GHz with a
        // neighbour's network on the same channel is the everyday case — one 100 KB frame can
        // legitimately take several seconds while bytes arrive the whole way. An elapsed-time
        // bound reads that as death and closes a perfectly live session, which is how ordinary
        // interference became a dropped connection. A transfer still being DELIVERED is not
        // stalled, however slow; one that has gone silent for the limit is.
        //
        // The absolute ceiling exists because "still trickling" is not the same as "will finish":
        // a body dribbling a byte a second would otherwise hold the gate forever.
        command.markReceiveActivity()
        let deadlineTask: Task<Void, Never>? = deadline.map { limit in
            Task { [command] in
                let startedAt = CFAbsoluteTimeGetCurrent()
                let limitSeconds =
                    Double(limit.components.seconds)
                    + Double(limit.components.attoseconds) / 1e18
                let ceilingSeconds = limitSeconds * Self.idleDeadlineCeilingMultiple
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(250))
                    if Task.isCancelled { return }
                    let idle = command.secondsSinceLastReceive ?? 0
                    let elapsed = CFAbsoluteTimeGetCurrent() - startedAt
                    if idle >= limitSeconds || elapsed >= ceilingSeconds {
                        command.close()
                        return
                    }
                }
            }
        }
        defer { deadlineTask?.cancel() }

        let transactionID = explicitTransactionID ?? nextTransactionID
        if explicitTransactionID == nil {
            nextTransactionID += 1
        }

        let request = PTPOperationRequest(
            dataPhase: dataPhase,
            operationCode: operationCode,
            transactionID: transactionID,
            parameters: parameters
        )
        try await command.send(
            PTPIPPacket(type: .operationRequest, payload: Data(request.payloadBytes))
        )
        if let dataOut {
            try await command.send(
                PTPIPPacket(
                    type: .startData,
                    payload: Data(
                        PTPDataPayloads.startData(
                            transactionID: transactionID,
                            totalLength: UInt64(dataOut.count)
                        ))
                )
            )
            try await command.send(
                PTPIPPacket(
                    type: .endData,
                    payload: Data(
                        PTPDataPayloads.endData(transactionID: transactionID, data: dataOut))
                )
            )
        }

        var packets: [PTPIPPacket] = []
        while true {
            let packet = try await command.readPacket()
            packets.append(packet)
            if packet.type == .operationResponse {
                return try PTPIPTransactionCollector().collect(from: packets)
            }
            // A desynced (or hostile) stream that never sends operationResponse must not grow
            // `packets` and hold the gate forever. Each data packet is already bounded to 128 MiB
            // by the framing layer; a real transaction is a handful of packets.
            guard packets.count <= Self.maxTransactionPackets else {
                throw NativeCameraSessionError.connectionFailed(
                    "PTP-IP transaction exceeded \(Self.maxTransactionPackets) packets without a response — stream desynchronized."
                )
            }
        }
    }

    /// Hard cap on packets collected per transaction. Real Nikon transactions are ≤4 packets
    /// (startData + data + endData + response); generous headroom for chunked data phases.
    private static let maxTransactionPackets = 512

    func nextEvent() async throws -> PTPEvent {
        // Skip any non-event packet the camera pushes on this channel; socket errors (including
        // the benign idle `.timeout`) propagate to the caller's drain loop.
        while true {
            let packet = try await event.readPacket()
            if packet.type == .probeRequest {
                // Liveness ping (CIPA DC-005): the body treats a missing ProbeResponse as a
                // dead initiator and closes the whole session — operator-visible as an
                // "event channel ended" drop. This packet was silently swallowed until now.
                // [verify-on-HW: the ZR probing cadence and whether answering ends the drops]
                try await event.send(PTPIPPacket(type: .probeResponse, payload: packet.payload))
                logConnection("event-channel liveness probe answered")
                continue
            }
            if let parsed = try? PTPEvent(from: packet) {
                return parsed
            }
        }
    }

    func close() {
        command.close()
        event.close()
    }
}

/// Serializes async transactions: one waiter proceeds at a time, FIFO.
// SAFETY: `@unchecked Sendable` — all mutable state is guarded by `lock` (`NSLock`).
final class AsyncSerialGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isAvailable = true
    private var waiters: [(id: UInt64, continuation: CheckedContinuation<Void, any Error>)] = []
    private var nextWaiterID: UInt64 = 0

    /// Waits for exclusive ownership of the gate. Throws `CancellationError` if the task is
    /// cancelled while still queued — in that case the gate was **never acquired** and the caller
    /// must not `signal()`. Cancelled waiters are removed from the queue immediately, so a
    /// cancellation storm (rapid connect/disconnect, live-view restarts) can't leave stale
    /// continuations queued ahead of real commands.
    func wait() async throws {
        let id = makeWaiterID()

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                let action: (() -> Void)?
                lock.lock()
                if Task.isCancelled {
                    // The cancellation handler may have already run (before we enqueued); resolve
                    // here so the continuation is never orphaned.
                    action = { continuation.resume(throwing: CancellationError()) }
                } else if isAvailable {
                    isAvailable = false
                    action = { continuation.resume() }
                } else {
                    waiters.append((id, continuation))
                    action = nil
                }
                lock.unlock()
                action?()
            }
        } onCancel: {
            let cancelled: CheckedContinuation<Void, any Error>?
            lock.lock()
            if let index = waiters.firstIndex(where: { $0.id == id }) {
                cancelled = waiters.remove(at: index).continuation
            } else {
                cancelled = nil
            }
            lock.unlock()
            cancelled?.resume(throwing: CancellationError())
        }
    }

    /// Synchronous (lock use is illegal directly in async contexts).
    private func makeWaiterID() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        nextWaiterID += 1
        return nextWaiterID
    }

    func signal() {
        let next: CheckedContinuation<Void, any Error>?

        lock.lock()
        if waiters.isEmpty {
            isAvailable = true
            next = nil
        } else {
            next = waiters.removeFirst().continuation
        }
        lock.unlock()

        next?.resume()
    }
}

// SAFETY: `@unchecked Sendable` — all socket access is serialized on the private
// `queue` (`DispatchQueue`).
final class PTPIPSocket: @unchecked Sendable {
    init(host: String, port: UInt16, label: String, timeoutMilliseconds: UInt64 = 10_000) {
        self.host = host
        self.port = port
        self.label = label
        self.timeoutMilliseconds = timeoutMilliseconds
    }

    private let host: String
    private let port: UInt16
    private let label: String
    private let timeoutMilliseconds: UInt64
    private let queue = DispatchQueue(label: "camera.ptpip.socket")
    private let descriptorLock = NSLock()
    private var descriptor: Int32 = -1
    /// Latched by `interrupt()` so a descriptor created AFTER the interrupt (cancellation racing
    /// `connectOnQueue`'s socket() call) is shut down the moment it is stored — the abandoned
    /// attempt can never proceed to a live init on a channel nobody owns.
    private var interruptRequested = false
    private var readBuffer = PTPIPReadBuffer()
    /// When this socket last took delivery of any bytes, in `CFAbsoluteTimeGetCurrent` terms.
    ///
    /// The transaction deadline reads it to tell a SLOW transfer from a STOPPED one. Its own lock,
    /// not `descriptorLock`: it is written on the socket queue for every recv and read from the
    /// deadline task, and it must never contend with descriptor teardown.
    private let receiveClockLock = NSLock()
    private var lastReceiveAt: TimeInterval = 0

    /// Seconds since this socket last received anything, or `nil` if it never has.
    var secondsSinceLastReceive: TimeInterval? {
        receiveClockLock.lock()
        defer { receiveClockLock.unlock() }
        guard lastReceiveAt > 0 else { return nil }
        return CFAbsoluteTimeGetCurrent() - lastReceiveAt
    }

    /// Starts the idle clock without a delivery, so a transfer that has not yet produced its first
    /// byte is measured from when it was ASKED for rather than from an unrelated earlier read.
    func markReceiveActivity() {
        receiveClockLock.lock()
        lastReceiveAt = CFAbsoluteTimeGetCurrent()
        receiveClockLock.unlock()
    }

    /// Reused `recv` scratch (serial-queue-owned) — see `receiveOnQueue` for why.
    private var receiveScratch: [UInt8] = []

    func start() async throws {
        try await performOnQueue { try self.connectOnQueue() }
    }

    func close() {
        closeDescriptor()
    }

    /// Unblocks any in-flight poll/recv/connect NOW, without freeing the descriptor: shutdown
    /// makes the fd poll readable-at-EOF, so the serial-queue call returns and throws through
    /// its own error path, which closes. Closing here instead would race descriptor reuse with
    /// the blocked call (audit M1); shutdown cannot. This is what makes an ABANDONED
    /// establishment attempt tear down immediately instead of holding a half-open init channel
    /// at a one-initiator body while the next attempt opens a second one (audit H4 — the
    /// two-command-channels wedge behind the two-device handoff brick).
    func interrupt() {
        descriptorLock.lock()
        interruptRequested = true
        let live = descriptor
        descriptorLock.unlock()
        if live >= 0 {
            Darwin.shutdown(live, SHUT_RDWR)
        }
    }

    func send(_ packet: PTPIPPacket) async throws {
        try await send(Data(packet.serializedBytes))
    }

    func readPacket() async throws -> PTPIPPacket {
        let header = try await readExact(byteCount: 8)
        let headerBytes = Array(header)
        let length = ByteCoding.readUInt32LE(headerBytes, at: 0)
        guard length >= 8 && length <= 128 * 1024 * 1024 else {
            // A length this far out of range means the read cursor is off a packet boundary
            // (reading payload — e.g. JPEG bytes — as a header): a higher-level desync, not
            // framing. Log the raw header + buffer state so the next on-device occurrence is
            // diagnosable; the session recovers via reconnect.
            let hex = headerBytes.map { String(format: "%02X", $0) }.joined(separator: " ")
            transportLogger.error(
                "PTP-IP desync on \(self.label, privacy: .public): length=\(length, privacy: .public) header=[\(hex, privacy: .public)] buffered=\(self.readBuffer.availableCount, privacy: .public)"
            )
            throw NativeCameraSessionError.invalidPacketLength(length)
        }
        let payloadLength = Int(length) - 8
        let payload = payloadLength > 0 ? try await readExact(byteCount: payloadLength) : Data()
        // Build the packet directly from the parsed header + payload Data. The old
        // serialize-then-reparse roundtrip (`headerBytes + Array(payload)` →
        // `init(serializedBytes:)` → `Data(bytes[8..<length])`) copied the whole JPEG-sized
        // payload three extra times per frame (audit finding: the copy chain).
        let type =
            PTPIPPacketType(rawValue: ByteCoding.readUInt32LE(headerBytes, at: 4)) ?? .unknown
        return PTPIPPacket(type: type, payload: payload)
    }

    private func send(_ data: Data) async throws {
        try await performOnQueue { try self.sendOnQueue(data) }
    }

    private func readExact(byteCount: Int) async throws -> Data {
        try await performOnQueue {
            while self.readBuffer.availableCount < byteCount {
                // Cap each recv so an oversized/malformed packet length can't drive one huge
                // transient allocation; the loop still reads the full `byteCount` across chunks.
                let remaining = byteCount - self.readBuffer.availableCount
                let chunk = try self.receiveOnQueue(
                    maximumLength: min(max(remaining, 4096), 256 * 1024))
                self.readBuffer.append(chunk)
            }
            // SAFETY: the loop guarantees availableCount >= byteCount, so `take` cannot return nil.
            return self.readBuffer.take(byteCount)!
        }
    }

    private func performOnQueue<T>(_ work: @Sendable @escaping () throws -> T) async throws -> T {
        // Task cancellation interrupts the blocked syscall instead of letting it run out its
        // own deadline — see `interrupt()`. Without this, cancellation was invisible here and
        // an abandoned attempt kept its socket (and its half-open init at the body) alive for
        // the full poll timeout.
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    do {
                        continuation.resume(returning: try work())
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            interrupt()
        }
    }

    private func connectOnQueue() throws {
        closeDescriptor()

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else {
            throw NativeCameraSessionError.connectionFailed(
                "Enter a numeric IPv4 camera address. Host names are not supported yet."
            )
        }

        let newDescriptor = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard newDescriptor >= 0 else {
            throw socketError(errno, context: "\(label) socket")
        }
        storeDescriptor(newDescriptor)

        var noDelay: Int32 = 1
        setsockopt(
            newDescriptor,
            IPPROTO_TCP,
            TCP_NODELAY,
            &noDelay,
            socklen_t(MemoryLayout<Int32>.size)
        )

        // Enable TCP keepalive so a half-open connection (camera slept, AP dropped the session)
        // is detected by the stack instead of hanging the read indefinitely. On set, the feed
        // freezing without recovery is the worst outcome — fail fast and let the watchdog restart.
        var keepAlive: Int32 = 1
        setsockopt(
            newDescriptor,
            SOL_SOCKET,
            SO_KEEPALIVE,
            &keepAlive,
            socklen_t(MemoryLayout<Int32>.size)
        )

        // Tune the keepalive timers — Darwin defaults to ~2h idle before the first probe, far too
        // slow for WiFi / iPhone-hotspot drops. Probe after 10s idle, then every 5s, giving up after
        // 4 unacked probes: a dead link surfaces in ~30s instead of hours. The 10s idle probe doubles
        // as periodic traffic that keeps the hotspot's NAT mapping alive while the channel is quiet.
        var keepIdleSeconds: Int32 = 10
        setsockopt(
            newDescriptor, IPPROTO_TCP, TCP_KEEPALIVE, &keepIdleSeconds,
            socklen_t(MemoryLayout<Int32>.size))
        var keepIntervalSeconds: Int32 = 5
        setsockopt(
            newDescriptor, IPPROTO_TCP, TCP_KEEPINTVL, &keepIntervalSeconds,
            socklen_t(MemoryLayout<Int32>.size))
        var keepProbeCount: Int32 = 4
        setsockopt(
            newDescriptor, IPPROTO_TCP, TCP_KEEPCNT, &keepProbeCount,
            socklen_t(MemoryLayout<Int32>.size))

        // A peer-closed socket must surface as a send error, never SIGPIPE (the Android facade
        // already sets this; iOS had silently diverged).
        var noSigPipe: Int32 = 1
        setsockopt(
            newDescriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe,
            socklen_t(MemoryLayout<Int32>.size))

        // Live-view frames arrive as ~100 KB bursts every frame period; the default receive
        // window under-buffers that on a lossy AP and turns transient congestion into stalled
        // reads. Half a megabyte absorbs several frames of burst without meaningfully delaying
        // loss feedback.
        var receiveBufferBytes: Int32 = 512 * 1024
        setsockopt(
            newDescriptor, SOL_SOCKET, SO_RCVBUF, &receiveBufferBytes,
            socklen_t(MemoryLayout<Int32>.size))

        let flags = fcntl(newDescriptor, F_GETFL, 0)
        if flags >= 0 {
            _ = fcntl(newDescriptor, F_SETFL, flags | O_NONBLOCK)
        }

        let connectResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.connect(
                    newDescriptor,
                    socketAddress,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                )
            }
        }

        if connectResult != 0 {
            let code = errno
            guard code == EINPROGRESS else {
                closeDescriptor()
                throw socketError(code, context: "\(label) connection")
            }
            try waitForDescriptor(
                newDescriptor, events: Int16(POLLOUT), label: "\(label) connection")

            var connectError: Int32 = 0
            var connectErrorLength = socklen_t(MemoryLayout<Int32>.size)
            let optionResult = getsockopt(
                newDescriptor,
                SOL_SOCKET,
                SO_ERROR,
                &connectError,
                &connectErrorLength
            )
            guard optionResult == 0 else {
                closeDescriptor()
                throw socketError(errno, context: "\(label) connection")
            }
            guard connectError == 0 else {
                closeDescriptor()
                throw socketError(connectError, context: "\(label) connection")
            }
        }
    }

    private func sendOnQueue(_ data: Data) throws {
        let descriptor = try currentDescriptor()
        var offset = 0
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            while offset < data.count {
                try waitForDescriptor(descriptor, events: Int16(POLLOUT), label: "\(label) send")
                let sent = Darwin.send(
                    descriptor, base.advanced(by: offset), data.count - offset, 0)
                if sent > 0 {
                    offset += sent
                    continue
                }
                if sent == 0 {
                    throw NativeCameraSessionError.connectionClosed
                }
                let code = errno
                if code == EINTR || code == EAGAIN || code == EWOULDBLOCK {
                    continue
                }
                throw socketError(code, context: "\(label) send")
            }
        }
    }

    private func receiveOnQueue(maximumLength: Int) throws -> Data {
        let descriptor = try currentDescriptor()
        // One scratch buffer per transport, grown to the largest read ever asked for: the old
        // per-recv `[UInt8](repeating: 0, …)` zero-filled up to 256 KiB per call — at ~100 KB
        // × 30 fps that was tens of MB/s of pure allocator+memset churn on the socket queue.
        // Safe without locking: this only runs on the transport's serial queue.
        if receiveScratch.count < maximumLength {
            receiveScratch = [UInt8](repeating: 0, count: maximumLength)
        }
        // Loop rather than recurse: a flaky link can deliver a stream of spurious poll wakeups
        // followed by EAGAIN/EINTR, and recursing per retry once grew the stack until it crashed
        // the socket queue. The loop re-polls (bounded by the descriptor timeout) in constant
        // stack space.
        while true {
            try waitForDescriptor(descriptor, events: Int16(POLLIN), label: "\(label) receive")

            let received = receiveScratch.withUnsafeMutableBytes { rawBuffer in
                Darwin.recv(descriptor, rawBuffer.baseAddress, maximumLength, 0)
            }
            if received > 0 {
                // Every delivery restarts the idle clock: this is what lets the transaction
                // deadline distinguish a link that is slow from one that has stopped.
                markReceiveActivity()
                return receiveScratch.withUnsafeBytes { rawBuffer in
                    Data(bytes: rawBuffer.baseAddress!, count: received)
                }
            }
            if received == 0 {
                throw NativeCameraSessionError.connectionClosed
            }
            let code = errno
            if code == EINTR || code == EAGAIN || code == EWOULDBLOCK {
                continue
            }
            throw socketError(code, context: "\(label) receive")
        }
    }

    private func waitForDescriptor(_ descriptor: Int32, events: Int16, label: String) throws {
        // Loop rather than recurse on EINTR (and on a wakeup that isn't yet readable): under a
        // signal storm the old recursion grew the stack without bound. The bound is CUMULATIVE
        // across retries — each re-poll used to get the full timeout again, so a stream of
        // spurious wakeups could stretch one "10 s" wait indefinitely (audit finding #13).
        let deadline = DispatchTime.now().advanced(
            by: .milliseconds(Int(min(timeoutMilliseconds, 30_000))))
        while true {
            let remainingMilliseconds =
                (deadline.uptimeNanoseconds &- DispatchTime.now().uptimeNanoseconds) / 1_000_000
            guard DispatchTime.now() < deadline, remainingMilliseconds > 0 else {
                throw NativeCameraSessionError.timeout(label)
            }
            var pollDescriptor = pollfd(fd: descriptor, events: events, revents: 0)
            let result = Darwin.poll(&pollDescriptor, 1, Int32(remainingMilliseconds))
            if result > 0 {
                if (pollDescriptor.revents & events) != 0 {
                    return
                }
                if (pollDescriptor.revents & Int16(POLLHUP | POLLERR | POLLNVAL)) != 0 {
                    throw NativeCameraSessionError.connectionClosed
                }
                // Woke for some other reason without data ready; poll again.
                continue
            }
            if result == 0 {
                throw NativeCameraSessionError.timeout(label)
            }
            let code = errno
            if code == EINTR {
                continue
            }
            throw socketError(code, context: label)
        }
    }

    private func storeDescriptor(_ descriptor: Int32) {
        descriptorLock.lock()
        self.descriptor = descriptor
        let alreadyInterrupted = interruptRequested
        descriptorLock.unlock()
        // Cancellation raced descriptor creation: kill the fresh socket immediately, exactly as
        // if it had existed when `interrupt()` ran. The latch is terminal per socket — a
        // cancelled attempt stays cancelled.
        if alreadyInterrupted {
            Darwin.shutdown(descriptor, SHUT_RDWR)
        }
    }

    private func currentDescriptor() throws -> Int32 {
        descriptorLock.lock()
        defer { descriptorLock.unlock() }
        guard descriptor >= 0 else { throw NativeCameraSessionError.connectionClosed }
        return descriptor
    }

    private func closeDescriptor() {
        descriptorLock.lock()
        let descriptorToClose = descriptor
        descriptor = -1
        descriptorLock.unlock()

        if descriptorToClose >= 0 {
            Darwin.shutdown(descriptorToClose, SHUT_RDWR)
            Darwin.close(descriptorToClose)
        }
    }

    private func socketError(_ code: Int32, context: String) -> NativeCameraSessionError {
        if code == EACCES {
            return .connectionFailed(
                "iOS denied \(context) to \(host):\(port). Confirm Local Network is enabled and that the phone is on the camera network."
            )
        }
        if code == ECONNREFUSED {
            return .connectionFailed(
                "No PTP-IP service answered at \(host):\(port). Confirm the camera is in PC/remote network mode."
            )
        }
        return .connectionFailed("\(context) failed: \(String(cString: strerror(code)))")
    }
}

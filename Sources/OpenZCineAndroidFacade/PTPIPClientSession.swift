// PTP-IP protocol/session layer for the Android facade.
//
// Socket-ownership decision: the sockets live HERE, in Swift, inside the facade
// target — not in Kotlin. AGENTS.md says platform adapters own sockets, and on
// Android the facade *is* the platform adapter: routing every PTP-IP packet
// Kotlin↔Swift over JNI would put several JNI round trips on each transaction
// (and per live-view frame later), while the core deliberately exposes a
// transaction-level `CameraTransport` boundary rather than a packet-pump engine.
// This mirrors `ios/Runner/PTPIPTransport.swift` + `NativeCameraSession.swift`
// (the iOS shell's twin of this file) with the same core codecs underneath;
// the Kotlin side sees only coarse connect / read-property / disconnect calls.
// See docs/investigations/android-core-feasibility.md ("Where sockets go").
//
// Everything below is adapter glue over `OpenZCineCore`: packet framing,
// handshake payloads, transaction collection, property decoding, and pairing
// policies all come from the core. This file compiles on Darwin too, so the
// fake-camera tests in `Tests/OpenZCineAndroidFacadeTests` exercise the exact
// bytes-on-the-wire behavior that ships in the Android `.so`.

import Foundation
import OpenZCineCore

#if canImport(Android)
    import Android
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Darwin)
    import Darwin
#endif

/// Errors surfaced by the facade's PTP-IP session layer.
public enum PTPIPClientSessionError: Error, LocalizedError, Equatable {
    case connectionFailed(String)
    case connectionClosed
    case timeout(String)
    case unexpectedPacket(expected: String, actual: PTPIPPacketType)
    case initFailed(PTPIPInitFailReason)
    case operationRejected(PTPOperationCode, PTPResponseCode)
    case invalidPacketLength(UInt32)
    case pairingChallengeUnavailable
    case appControlUnavailable
    case unsupportedProperty(UInt32)
    case liveViewAlreadyActive

    public var errorDescription: String? {
        switch self {
        case .connectionFailed(let message):
            return message
        case .connectionClosed:
            return "The camera closed the connection."
        case .timeout(let label):
            return "\(label) timed out."
        case .unexpectedPacket(let expected, let actual):
            return "Expected \(expected), got PTP-IP packet \(actual.rawValue)."
        case .initFailed(let reason):
            return "The camera rejected the PTP-IP handshake: \(reason)."
        case .operationRejected(let operation, let response):
            return "Camera rejected \(operation) with response \(response)."
        case .invalidPacketLength(let length):
            return "Invalid PTP-IP packet length \(length)."
        case .pairingChallengeUnavailable:
            return
                "The camera did not provide a pairing code. Restart Connect to Smart Device on the camera, then pair again."
        case .appControlUnavailable:
            return "The camera did not open app-control mode after pairing."
        case .unsupportedProperty(let code):
            return "Property 0x\(PTPIPClientSession.hexString(code)) is not known to the core."
        case .liveViewAlreadyActive:
            return "Live view is already streaming on this session."
        }
    }
}

/// Camera identity assembled from the Init handshake plus `GetDeviceInfo`.
public struct PTPIPClientIdentity: Equatable, Sendable {
    public let cameraName: String
    public let manufacturer: String
    public let model: String
    public let deviceVersion: String
    public let serialNumber: String

    /// Operator-facing camera title, resolved by the core's shared naming policy.
    public var displayName: String {
        CameraDisplayNamePolicy.displayName(
            cameraName: cameraName,
            manufacturer: manufacturer,
            model: model
        )
    }
}

/// A synchronous PTP-IP camera session: two TCP sockets (command + event) to
/// port 15740, the CIPA DC-005 Init handshake, and the Nikon open/pair/identify
/// sequence — the Android twin of `NativeCameraSession.establish`.
///
/// Blocking by design: JNI entry points arrive on JVM threads (Kotlin drives
/// them from `Dispatchers.IO`), so the Dispatch/async machinery the iOS shell
/// needs has no job here. All transactions are serialized on `transactionLock`.
// SAFETY: `@unchecked Sendable` — `nextTransactionID` and socket I/O are only
// touched inside transactions serialized by `transactionLock`.
public final class PTPIPClientSession: @unchecked Sendable {
    private let command: PosixTCPSocket
    private let event: PosixTCPSocket
    private let transactionLock = NSLock()
    private var nextTransactionID: UInt32 = 1
    private var isClosed = false

    /// Live-view pump state, guarded by `liveViewCondition` (never by
    /// `transactionLock` — the pump holds that per transaction, and stop/join
    /// must be able to run while a frame fetch is in flight).
    private let liveViewCondition = NSCondition()
    private var liveViewPumpActive = false
    private var liveViewStopRequested = false

    /// Camera identity resolved during `connect`. Written once by
    /// `identify()` during establishment, before the session escapes to
    /// callers, so reads never race the write.
    public private(set) var identity: PTPIPClientIdentity

    private init(command: PosixTCPSocket, event: PosixTCPSocket, identity: PTPIPClientIdentity) {
        self.command = command
        self.event = event
        self.identity = identity
    }

    // MARK: - Connect

    /// Connects, handshakes, and establishes an app-control PTP session.
    ///
    /// Mirrors the iOS shell's connection strategy: first a quiet saved-profile
    /// attempt (OpenSession → ChangeApplicationMode); when the camera refuses
    /// app control, the link is torn down gracefully and re-established with
    /// the first-time pairing sequence (GetPairingInfo poll → ConfirmPairing).
    /// Progress is pushed through `onPhase` (`.handshaking`, `.pairing`,
    /// `.confirmOnCamera` with the PIN as detail, `.connected`).
    public static func connect(
        host: String,
        port: UInt16 = UInt16(ptpIPPort),
        guid: Data = PTPIPInitiator.appGUID,
        friendlyName: String = PTPIPInitiator.friendlyName,
        timeoutMilliseconds: Int32 = 10_000,
        onPhase: (CameraConnectionPhase, String) -> Void = { _, _ in }
    ) throws -> PTPIPClientSession {
        onPhase(.handshaking, "")
        let probe = try establishLink(
            host: host, port: port, guid: guid, friendlyName: friendlyName,
            timeoutMilliseconds: timeoutMilliseconds)
        do {
            try probe.openSession()
            if try probe.enableAppControl() {
                try probe.identify()
                onPhase(.connected, probe.identity.displayName)
                return probe
            }
        } catch {
            probe.disconnect()
            throw error
        }
        // Saved profile unavailable — release the slot gracefully and pair fresh,
        // exactly like the iOS shell's savedProfile → firstTimePairing fallback.
        probe.disconnect()

        onPhase(.pairing, "")
        let pairing = try establishLink(
            host: host, port: port, guid: guid, friendlyName: friendlyName,
            timeoutMilliseconds: timeoutMilliseconds)
        do {
            try pairing.openSession()
            let challenge = try pairing.waitForPairingChallenge()
            onPhase(.confirmOnCamera, challenge.pin ?? "")
            try pairing.transactExpectingOK(
                .confirmPairing, parameters: [PTPIPSessionScript.pairingConfirmValue])
            guard try pairing.enableAppControl() else {
                throw PTPIPClientSessionError.appControlUnavailable
            }
            try pairing.identify()
            onPhase(.connected, pairing.identity.displayName)
            return pairing
        } catch {
            pairing.disconnect()
            throw error
        }
    }

    /// Opens both TCP channels and runs the PTP-IP Init handshake; returns a
    /// session whose identity carries only the handshake camera name so far.
    private static func establishLink(
        host: String,
        port: UInt16,
        guid: Data,
        friendlyName: String,
        timeoutMilliseconds: Int32
    ) throws -> PTPIPClientSession {
        let command = PosixTCPSocket(
            host: host, port: port, label: "command", timeoutMilliseconds: timeoutMilliseconds)
        let event = PosixTCPSocket(
            host: host, port: port, label: "event", timeoutMilliseconds: timeoutMilliseconds)
        do {
            try command.open()
            let initRequest = try PTPIPInitCommandRequest(guid: guid, friendlyName: friendlyName)
            try command.send(
                PTPIPPacket(type: .initCommandRequest, payload: Data(initRequest.payloadBytes)))
            let initReply = try command.readPacket()
            if initReply.type == .initFail {
                let fail = try PTPIPInitFail(payloadBytes: Array(initReply.payload))
                throw PTPIPClientSessionError.initFailed(fail.reason)
            }
            guard initReply.type == .initCommandAck else {
                throw PTPIPClientSessionError.unexpectedPacket(
                    expected: "Init_Command_Ack", actual: initReply.type)
            }
            let ack = try PTPIPInitCommandAck(payloadBytes: Array(initReply.payload))

            try event.open()
            try event.send(
                PTPIPPacket(
                    type: .initEventRequest,
                    payload: Data(
                        PTPIPInitEventRequest(connectionNumber: ack.connectionNumber).payloadBytes))
            )
            let eventReply = try event.readPacket()
            guard eventReply.type == .initEventAck else {
                throw PTPIPClientSessionError.unexpectedPacket(
                    expected: "Init_Event_Ack", actual: eventReply.type)
            }

            let identity = PTPIPClientIdentity(
                cameraName: ack.cameraName ?? "Nikon camera",
                manufacturer: "", model: "", deviceVersion: "", serialNumber: "")
            return PTPIPClientSession(command: command, event: event, identity: identity)
        } catch {
            command.close()
            event.close()
            throw error
        }
    }

    // MARK: - Session sequence steps

    private func openSession() throws {
        let open = try executeTransaction(.openSession, transactionID: 0, parameters: [1])
        let response = open.operationResponse.responseCode
        guard response == .ok || response == .sessionAlreadyOpen else {
            throw PTPIPClientSessionError.operationRejected(.openSession, response)
        }
    }

    /// Nikon app-control gate. `true` when the camera accepted app control —
    /// `false` routes the caller to first-time pairing (core probe policy).
    private func enableAppControl() throws -> Bool {
        let appMode = try executeTransaction(.changeApplicationMode, parameters: [1])
        return PTPIPSavedProfileProbePolicy.resolve(
            applicationModeResponse: appMode.operationResponse.responseCode) == .accepted
    }

    /// Polls `GetPairingInfo` until the camera produces a pairing challenge,
    /// with the same cadence as the iOS shell (10 attempts, 250 ms apart).
    private func waitForPairingChallenge() throws -> PTPIPPairingChallenge {
        for _ in 1...10 {
            if let pairInfo = try? executeTransaction(.getPairingInfo, dataPhase: .dataIn),
                PTPIPPairingInfoPolicy.resolve(
                    response: pairInfo.operationResponse.responseCode,
                    byteCount: pairInfo.data.count) == .promptUser
            {
                return PTPIPPairingChallenge(data: pairInfo.data, cameraName: identity.cameraName)
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        throw PTPIPClientSessionError.pairingChallengeUnavailable
    }

    /// Runs `GetDeviceInfo` and fills in the full identity — in place, so the
    /// session's transaction-ID sequence keeps counting (a fresh instance here
    /// once restarted IDs mid-session, which a real body may reject).
    private func identify() throws {
        let info = try transactExpectingOK(.getDeviceInfo, dataPhase: .dataIn)
        let deviceInfo = try PTPDeviceInfo(data: info.data)
        identity = PTPIPClientIdentity(
            cameraName: identity.cameraName.isEmpty ? deviceInfo.model : identity.cameraName,
            manufacturer: deviceInfo.manufacturer,
            model: deviceInfo.model,
            deviceVersion: deviceInfo.deviceVersion,
            serialNumber: deviceInfo.serialNumber)
    }

    // MARK: - Properties

    /// Reads one camera property (`GetDevicePropValueEx`) and returns its raw bytes.
    public func readProperty(_ property: PTPPropertyCode) throws -> Data {
        try transactExpectingOK(
            .getDevicePropValueEx, parameters: [property.rawValue], dataPhase: .dataIn
        ).data
    }

    /// Reads a property and decodes it through the core: battery level comes
    /// back as a percentage string (`"80"`), anything else as the raw
    /// little-endian value in hex (`"0x0"`) until its decoder is wired up.
    public func readPropertyDisplayValue(code: UInt32) throws -> String {
        guard let property = PTPPropertyCode(rawValue: code) else {
            throw PTPIPClientSessionError.unsupportedProperty(code)
        }
        let data = try readProperty(property)
        let snapshot = PTPCameraPropertySnapshot().applying(property: property, data: data)
        if property == .batteryLevel, let percent = snapshot.batteryPercent {
            return "\(percent)"
        }
        // ponytail: generic hex fallback — per-property display decoding grows
        // with the monitor UI slice; the raw value is what HW validation needs.
        var value: UInt64 = 0
        for byte in Array(data).prefix(8).reversed() {
            value = value << 8 | UInt64(byte)
        }
        return "0x\(Self.hexString(value))"
    }

    // MARK: - Live view

    /// Poll ceiling for the live-view pump (~30 fps). The camera itself paces
    /// a blocking `GetLiveViewImageEx`, so this only matters against a source
    /// that answers faster than real frames (the fake ZR, a hot cache).
    public static let liveViewFrameIntervalNanoseconds: UInt64 = 33_000_000

    /// Starts live view and pumps frames from a dedicated background thread.
    ///
    /// Synchronous start, asynchronous stream: `StartLiveView` plus the
    /// `DeviceReady` readiness poll (the iOS shell's 40 × 50 ms cadence) run on
    /// the caller's thread and throw on failure — when this returns, the pump
    /// thread is running and neither callback has fired yet. `onFrame` and
    /// `onEnded` are then all delivered from that one pump thread; `onEnded`
    /// fires exactly once, after the final frame, whether the stream ends by
    /// `stopLiveView`, `disconnect`, or a transport error.
    ///
    /// Backpressure is latest-wins by construction: frames are *pulled* one at
    /// a time and delivered synchronously, so a slow consumer polls less often
    /// and each poll returns the camera's newest frame — nothing queues.
    /// Poll pacing uses an absolute schedule (`start + n × interval`), never an
    /// elapsed-time gate, per the wall-clock aliasing lesson.
    public func startLiveView(
        frameIntervalNanoseconds: UInt64 = PTPIPClientSession.liveViewFrameIntervalNanoseconds,
        onFrame: @escaping @Sendable (PTPLiveViewFrame, Int64) -> Void,
        onEnded: @escaping @Sendable () -> Void
    ) throws {
        liveViewCondition.lock()
        guard !liveViewPumpActive else {
            liveViewCondition.unlock()
            throw PTPIPClientSessionError.liveViewAlreadyActive
        }
        liveViewPumpActive = true
        liveViewStopRequested = false
        liveViewCondition.unlock()

        do {
            try transactExpectingOK(.startLiveView)
            try waitForDeviceReady()
        } catch {
            liveViewCondition.lock()
            liveViewPumpActive = false
            liveViewCondition.unlock()
            throw error
        }

        Thread.detachNewThread { [self] in
            runLiveViewPump(
                frameIntervalNanoseconds: frameIntervalNanoseconds,
                onFrame: onFrame, onEnded: onEnded)
        }
    }

    /// Stops the live-view pump and blocks until it has exited — which
    /// includes the pump's best-effort `EndLiveView`, so the camera is never
    /// left streaming (the heat-audit rule). Bounded by the socket timeout
    /// plus margin; a no-op when no pump is running. Safe to call repeatedly.
    public func stopLiveView() {
        liveViewCondition.lock()
        defer { liveViewCondition.unlock() }
        guard liveViewPumpActive else { return }
        liveViewStopRequested = true
        let deadline = Date().addingTimeInterval(
            Double(command.timeoutMilliseconds) / 1_000 + 2)
        while liveViewPumpActive {
            guard liveViewCondition.wait(until: deadline) else { return }
        }
    }

    /// The iOS shell's post-`StartLiveView` readiness poll: `DeviceReady`
    /// until OK, 40 attempts 50 ms apart.
    private func waitForDeviceReady() throws {
        for _ in 0..<40 {
            let ready = try executeTransaction(.deviceReady)
            if ready.operationResponse.responseCode == .ok { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw PTPIPClientSessionError.timeout("Device readiness polling")
    }

    /// Pump body: fetch → deliver → sleep-to-schedule, until stop or a
    /// transport error, then best-effort `EndLiveView` and exactly one
    /// `onEnded`.
    private func runLiveViewPump(
        frameIntervalNanoseconds: UInt64,
        onFrame: (PTPLiveViewFrame, Int64) -> Void,
        onEnded: () -> Void
    ) {
        let startNanos = Self.monotonicNanoseconds()
        var pollIndex: UInt64 = 0
        while !liveViewStopIsRequested() {
            do {
                let result = try transactExpectingOK(.getLiveViewImageEx, dataPhase: .dataIn)
                let frame = try PTPLiveViewObject.frame(from: result.data)
                onFrame(frame, Int64(Self.monotonicNanoseconds()))
            } catch is PTPLiveViewObjectError {
                // A single unparsable frame is stream jitter, not a stream
                // death — skip it, like the iOS watchdog's bad-frame budget.
                // ponytail: no stall watchdog yet; restart machinery arrives
                // with the Android reconnect slice.
            } catch {
                break  // Transport error / rejection: the stream is over.
            }
            // Absolute schedule: poll k is due at start + k × interval. When a
            // fetch overruns, re-anchor to now instead of accumulating debt —
            // an elapsed>=interval gate against a paced source only ever locks
            // onto source/N (the wall-clock aliasing lesson, 4ae1544).
            pollIndex += 1
            let elapsed = Self.monotonicNanoseconds() - startNanos
            let due = pollIndex * frameIntervalNanoseconds
            if due > elapsed {
                Thread.sleep(forTimeInterval: Double(due - elapsed) / 1_000_000_000)
            } else {
                pollIndex = elapsed / frameIntervalNanoseconds
            }
        }

        // Release the camera's encoder before signalling the stream end —
        // never leave the body streaming to nobody (the heat-audit EndLiveView
        // rule). Best-effort: on a dead link this fails fast and teardown
        // proceeds.
        _ = try? transactExpectingOK(.endLiveView)

        // `onEnded` before the join broadcast, so a returned `stopLiveView`
        // (and therefore `disconnect`) guarantees the terminal callback has
        // already been delivered.
        onEnded()
        liveViewCondition.lock()
        liveViewPumpActive = false
        liveViewStopRequested = false
        liveViewCondition.broadcast()
        liveViewCondition.unlock()
    }

    private func liveViewStopIsRequested() -> Bool {
        liveViewCondition.lock()
        defer { liveViewCondition.unlock() }
        return liveViewStopRequested
    }

    /// `CLOCK_MONOTONIC` in nanoseconds — frame timestamps that match the
    /// semantics of Kotlin's `System.nanoTime()`.
    static func monotonicNanoseconds() -> UInt64 {
        var time = timespec()
        clock_gettime(CLOCK_MONOTONIC, &time)
        return UInt64(time.tv_sec) * 1_000_000_000 + UInt64(time.tv_nsec)
    }

    // MARK: - Teardown

    /// Graceful teardown: best-effort `CloseSession` so the camera releases its
    /// session slot immediately, THEN drop both sockets — the same semantics as
    /// the iOS reconnect-wedge fix (`NativeCameraSession.shutdown`). Bounded:
    /// the read timeout is dropped to 2 s first, so a dead link cannot stall
    /// teardown. Safe to call more than once.
    ///
    /// A running live-view pump is stopped (and joined) first, so the wire
    /// order on teardown is always `EndLiveView` → `CloseSession`.
    public func disconnect() {
        stopLiveView()
        transactionLock.lock()
        let alreadyClosed = isClosed
        isClosed = true
        transactionLock.unlock()
        guard !alreadyClosed else { return }

        command.timeoutMilliseconds = 2_000
        _ = try? executeTransaction(.closeSession)
        command.close()
        event.close()
    }

    // MARK: - Transaction executor

    @discardableResult
    private func transactExpectingOK(
        _ operationCode: PTPOperationCode,
        parameters: [UInt32] = [],
        dataPhase: PTPDataPhase = .noDataOrDataIn
    ) throws -> PTPIPTransactionResult {
        let result = try executeTransaction(
            operationCode, parameters: parameters, dataPhase: dataPhase)
        guard result.operationResponse.responseCode == .ok else {
            throw PTPIPClientSessionError.operationRejected(
                operationCode, result.operationResponse.responseCode)
        }
        return result
    }

    /// Executes one full PTP transaction on the command channel: request out,
    /// then packets in until `Operation_Response`, collected by the core.
    // ponytail: read-only slice — the host→camera data-out phase arrives with
    // property writes; nothing in connect/read/disconnect needs it.
    private func executeTransaction(
        _ operationCode: PTPOperationCode,
        transactionID explicitTransactionID: UInt32? = nil,
        parameters: [UInt32] = [],
        dataPhase: PTPDataPhase = .noDataOrDataIn
    ) throws -> PTPIPTransactionResult {
        transactionLock.lock()
        defer { transactionLock.unlock() }

        let transactionID = explicitTransactionID ?? nextTransactionID
        if explicitTransactionID == nil {
            nextTransactionID += 1
        }
        let request = PTPOperationRequest(
            dataPhase: dataPhase,
            operationCode: operationCode,
            transactionID: transactionID,
            parameters: parameters)
        try command.send(
            PTPIPPacket(type: .operationRequest, payload: Data(request.payloadBytes)))

        var packets: [PTPIPPacket] = []
        while true {
            let packet = try command.readPacket()
            packets.append(packet)
            if packet.type == .operationResponse {
                return try PTPIPTransactionCollector().collect(from: packets)
            }
            // Same desync guard as the iOS transport: a stream that never sends
            // operationResponse must not grow `packets` forever.
            guard packets.count <= 512 else {
                throw PTPIPClientSessionError.connectionFailed(
                    "PTP-IP transaction exceeded 512 packets without a response — stream desynchronized."
                )
            }
        }
    }

    /// Uppercase hex without `String(format:)` (which drags umbrella Foundation
    /// on Android — see the feasibility doc's ICU finding).
    static func hexString<Value: BinaryInteger>(_ value: Value) -> String {
        String(value, radix: 16, uppercase: true)
    }
}

/// A blocking POSIX TCP socket with poll-bounded I/O — the facade twin of the
/// iOS shell's `PTPIPSocket`, minus the Dispatch queue (callers here are plain
/// JVM/test threads). Compiles against Darwin, Glibc, and bionic libc.
// SAFETY: `@unchecked Sendable` — the descriptor is guarded by `descriptorLock`;
// I/O is serialized by the owning session's transaction lock.
final class PosixTCPSocket: @unchecked Sendable {
    init(host: String, port: UInt16, label: String, timeoutMilliseconds: Int32) {
        self.host = host
        self.port = port
        self.label = label
        self.timeoutMilliseconds = timeoutMilliseconds
    }

    private let host: String
    private let port: UInt16
    private let label: String
    /// Per-poll timeout; mutable so teardown can shorten it (see `disconnect`).
    var timeoutMilliseconds: Int32
    private let descriptorLock = NSLock()
    private var descriptor: Int32 = -1
    private var readBuffer = PTPIPReadBuffer()

    func open() throws {
        close()

        var address = sockaddr_in()
        #if canImport(Darwin)
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else {
            throw PTPIPClientSessionError.connectionFailed(
                "Enter a numeric IPv4 camera address. Host names are not supported yet.")
        }

        let newDescriptor = socket(AF_INET, SOCK_STREAM, Int32(IPPROTO_TCP))
        guard newDescriptor >= 0 else {
            throw socketError(errno, context: "\(label) socket")
        }
        storeDescriptor(newDescriptor)

        var noDelay: Int32 = 1
        setsockopt(
            newDescriptor, Int32(IPPROTO_TCP), TCP_NODELAY, &noDelay,
            socklen_t(MemoryLayout<Int32>.size))
        #if canImport(Darwin)
            var noSigPipe: Int32 = 1
            setsockopt(
                newDescriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe,
                socklen_t(MemoryLayout<Int32>.size))
        #endif
        // ponytail: the iOS twin's keepalive timer tuning arrives with the
        // Android reconnect machinery — connect/read/disconnect doesn't idle.

        let flags = fcntl(newDescriptor, F_GETFL, 0)
        if flags >= 0 {
            _ = fcntl(newDescriptor, F_SETFL, flags | O_NONBLOCK)
        }

        let connectResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                connect(newDescriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if connectResult != 0 {
            let code = errno
            guard code == EINPROGRESS else {
                close()
                throw socketError(code, context: "\(label) connection")
            }
            try waitForDescriptor(
                newDescriptor, events: Int16(POLLOUT), label: "\(label) connection")

            var connectError: Int32 = 0
            var connectErrorLength = socklen_t(MemoryLayout<Int32>.size)
            guard
                getsockopt(newDescriptor, SOL_SOCKET, SO_ERROR, &connectError, &connectErrorLength)
                    == 0
            else {
                close()
                throw socketError(errno, context: "\(label) connection")
            }
            guard connectError == 0 else {
                close()
                throw socketError(connectError, context: "\(label) connection")
            }
        }
    }

    func close() {
        descriptorLock.lock()
        let descriptorToClose = descriptor
        descriptor = -1
        descriptorLock.unlock()

        if descriptorToClose >= 0 {
            shutdown(descriptorToClose, Int32(SHUT_RDWR))
            #if canImport(Android)
                Android.close(descriptorToClose)
            #elseif canImport(Glibc)
                Glibc.close(descriptorToClose)
            #else
                Darwin.close(descriptorToClose)
            #endif
        }
    }

    func send(_ packet: PTPIPPacket) throws {
        let data = Data(packet.serializedBytes)
        let descriptor = try currentDescriptor()
        #if canImport(Darwin)
            let sendFlags: Int32 = 0
        #else
            let sendFlags = Int32(MSG_NOSIGNAL)
        #endif
        var offset = 0
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            while offset < data.count {
                try waitForDescriptor(descriptor, events: Int16(POLLOUT), label: "\(label) send")
                let sent = platformSend(
                    descriptor, base.advanced(by: offset), data.count - offset, sendFlags)
                if sent > 0 {
                    offset += sent
                    continue
                }
                if sent == 0 {
                    throw PTPIPClientSessionError.connectionClosed
                }
                let code = errno
                if code == EINTR || code == EAGAIN || code == EWOULDBLOCK {
                    continue
                }
                throw socketError(code, context: "\(label) send")
            }
        }
    }

    /// Reads one length-prefixed PTP-IP packet, with the same framing guards as
    /// the iOS transport (8-byte header, 128 MiB payload ceiling).
    func readPacket() throws -> PTPIPPacket {
        let header = try readExact(byteCount: 8)
        let headerBytes = Array(header)
        let length = ByteCoding.readUInt32LE(headerBytes, at: 0)
        guard length >= 8 && length <= 128 * 1024 * 1024 else {
            throw PTPIPClientSessionError.invalidPacketLength(length)
        }
        let payloadLength = Int(length) - 8
        let payload = payloadLength > 0 ? try readExact(byteCount: payloadLength) : Data()
        return try PTPIPPacket(serializedBytes: headerBytes + Array(payload))
    }

    private func readExact(byteCount: Int) throws -> Data {
        let descriptor = try currentDescriptor()
        while readBuffer.availableCount < byteCount {
            try waitForDescriptor(descriptor, events: Int16(POLLIN), label: "\(label) receive")
            let remaining = byteCount - readBuffer.availableCount
            let maximumLength = min(max(remaining, 4096), 256 * 1024)
            var bytes = [UInt8](repeating: 0, count: maximumLength)
            let received = bytes.withUnsafeMutableBytes { rawBuffer in
                recv(descriptor, rawBuffer.baseAddress, maximumLength, 0)
            }
            if received > 0 {
                readBuffer.append(Data(bytes.prefix(received)))
                continue
            }
            if received == 0 {
                throw PTPIPClientSessionError.connectionClosed
            }
            let code = errno
            if code == EINTR || code == EAGAIN || code == EWOULDBLOCK {
                continue
            }
            throw socketError(code, context: "\(label) receive")
        }
        // SAFETY: the loop guarantees availableCount >= byteCount, so `take` cannot return nil.
        return readBuffer.take(byteCount)!
    }

    private func waitForDescriptor(_ descriptor: Int32, events: Int16, label: String) throws {
        // Loop rather than recurse on EINTR / spurious wakeups (same rationale
        // as the iOS twin: a signal storm must not grow the stack).
        while true {
            var pollDescriptor = pollfd(fd: descriptor, events: events, revents: 0)
            let result = poll(&pollDescriptor, 1, min(timeoutMilliseconds, 30_000))
            if result > 0 {
                if (pollDescriptor.revents & events) != 0 {
                    return
                }
                if (pollDescriptor.revents & Int16(POLLHUP | POLLERR | POLLNVAL)) != 0 {
                    throw PTPIPClientSessionError.connectionClosed
                }
                continue
            }
            if result == 0 {
                throw PTPIPClientSessionError.timeout(label)
            }
            if errno == EINTR {
                continue
            }
            throw socketError(errno, context: label)
        }
    }

    private func platformSend(
        _ descriptor: Int32, _ base: UnsafeRawPointer, _ count: Int, _ flags: Int32
    ) -> Int {
        #if canImport(Android)
            Android.send(descriptor, base, count, flags)
        #elseif canImport(Glibc)
            Glibc.send(descriptor, base, count, flags)
        #else
            Darwin.send(descriptor, base, count, flags)
        #endif
    }

    private func storeDescriptor(_ descriptor: Int32) {
        descriptorLock.lock()
        self.descriptor = descriptor
        descriptorLock.unlock()
    }

    private func currentDescriptor() throws -> Int32 {
        descriptorLock.lock()
        defer { descriptorLock.unlock() }
        guard descriptor >= 0 else { throw PTPIPClientSessionError.connectionClosed }
        return descriptor
    }

    private func socketError(_ code: Int32, context: String) -> PTPIPClientSessionError {
        if code == ECONNREFUSED {
            return .connectionFailed(
                "No PTP-IP service answered at \(host):\(port). Confirm the camera is in PC/remote network mode."
            )
        }
        return .connectionFailed("\(context) failed: \(String(cString: strerror(code)))")
    }
}

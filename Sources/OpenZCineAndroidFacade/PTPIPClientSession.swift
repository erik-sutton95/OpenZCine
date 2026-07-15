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
    case unsupportedControl(PTPCameraControl, String)
    case liveViewAlreadyActive
    case mediaModeActive
    case mediaModeRequired
    case eventDrainAlreadyActive

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
        case .unsupportedControl(let control, let label):
            return "\(String(describing: control)) does not support the selection \"\(label)\"."
        case .liveViewAlreadyActive:
            return "Live view is already streaming on this session."
        case .mediaModeActive:
            return "Live view is unavailable while camera media is open."
        case .mediaModeRequired:
            return "Open camera media before starting an object transfer."
        case .eventDrainAlreadyActive:
            return "The camera event channel is already being drained."
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
    private let command: PosixTCPSocket?
    private let event: PosixTCPSocket?
    #if os(Android)
        /// USB owns the physical endpoints in Kotlin. Swift owns the generic
        /// PTP containers and every session operation above this transport.
        private let usbTransport: AndroidUSBPTPTransport?
    #endif
    private let transactionLock = NSLock()
    /// Serializes high-level camera-changing command sequences with recording,
    /// media ownership transitions, and teardown. Individual wire transactions
    /// still use `transactionLock`, so live-view frame reads stay safe between
    /// a multi-write control sequence's individual PTP transactions.
    private let commandLifecycleLock = NSLock()
    /// Accumulated Android monitor state. Access only while
    /// `commandLifecycleLock` is held so a refresh cannot race control writes,
    /// media ownership, or teardown.
    private var androidPropertySnapshot = PTPCameraPropertySnapshot()
    private var androidStorageInfo: PTPStorageInfo?
    private var androidPropertyPollIndex = 0
    private var androidLastStorageRefreshAt: Date?
    private var nextTransactionID: UInt32 = 1
    private var isClosed = false

    /// Live-view pump state, guarded by `liveViewCondition` (never by
    /// `transactionLock` — the pump holds that per transaction, and stop/join
    /// must be able to run while a frame fetch is in flight).
    private let liveViewCondition = NSCondition()
    private var liveViewPumpActive = false
    private var liveViewStopRequested = false
    private var mediaModeActive = false
    /// Preview-only pacing selected by the shared Android live-view policy.
    /// Access while `commandLifecycleLock` is held before start, then copied
    /// into the pump under `liveViewCondition`; this never changes camera
    /// recording settings or the camera's card write cadence.
    private var configuredLiveViewFrameIntervalNanoseconds =
        PTPIPClientSession.liveViewFrameIntervalNanoseconds

    /// Event-channel ownership. PTP-IP events arrive on their own TCP socket,
    /// so a dedicated reader can drain sparse camera pushes without blocking
    /// serialized command transactions or live-view frame reads.
    private let eventDrainCondition = NSCondition()
    private var eventDrainActive = false
    private var eventDrainStopRequested = false

    /// Media payload pump state. Like live view, this is independent of the
    /// transaction lock so stop/join can proceed while one camera read is in
    /// flight.
    private let mediaTransferCondition = NSCondition()
    private var mediaTransferActive = false
    private var mediaTransferStopRequested = false

    /// Camera identity resolved during `connect`. Written once by
    /// `identify()` during establishment, before the session escapes to
    /// callers, so reads never race the write.
    public private(set) var identity: PTPIPClientIdentity

    private init(command: PosixTCPSocket, event: PosixTCPSocket, identity: PTPIPClientIdentity) {
        self.command = command
        self.event = event
        #if os(Android)
            usbTransport = nil
        #endif
        self.identity = identity
    }

    #if os(Android)
        private init(usbTransport: AndroidUSBPTPTransport, identity: PTPIPClientIdentity) {
            command = nil
            event = nil
            self.usbTransport = usbTransport
            self.identity = identity
        }
    #endif

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
        guid: Data = PTPIPInitiator.androidAppGUID,
        friendlyName: String = PTPIPInitiator.androidFriendlyName,
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

    #if os(Android)
        /// Establishes the same Nikon app-control session over a claimed USB
        /// PTP transport. The platform layer vends raw endpoint bytes only;
        /// generic containers, pairing, identity, and all camera operations
        /// remain in Swift/shared core just like the PTP-IP path.
        static func connectUSB(
            transport: AndroidUSBPTPTransport,
            host: String,
            cameraNameHint: String,
            onPhase: (CameraConnectionPhase, String) -> Void = { _, _ in }
        ) throws -> PTPIPClientSession {
            onPhase(.handshaking, "")
            let session = PTPIPClientSession(
                usbTransport: transport,
                identity: PTPIPClientIdentity(
                    cameraName: cameraNameHint,
                    manufacturer: "",
                    model: "",
                    deviceVersion: "",
                    serialNumber: ""
                )
            )
            // The privacy-safe USB key is a Kotlin-local saved-record lookup;
            // PTP has no network host, so it is neither addressed nor sent here.
            _ = host
            do {
                try session.openSession()
                if try session.enableAppControl() {
                    try session.identify()
                    onPhase(.connected, session.identity.displayName)
                    return session
                }

                // A new USB transport cannot be recreated by Swift, so reset
                // the PTP session on this already-claimed interface before
                // executing the same first-time pairing sequence as Wi-Fi.
                // [VERIFY-ON-HW] Confirm the ZR accepts CloseSession followed
                // by OpenSession on one claimed USB interface after app-mode
                // refusal; the transaction sequence reset is covered below.
                _ = try? transport.executeTransactionSynchronously(
                    operationCode: .closeSession,
                    deadline: .seconds(2)
                )
                try session.openSession()
                onPhase(.pairing, "")
                let challenge = try session.waitForPairingChallenge()
                onPhase(.confirmOnCamera, challenge.pin ?? "")
                try session.transactExpectingOK(
                    .confirmPairing,
                    parameters: [PTPIPSessionScript.pairingConfirmValue]
                )
                guard try session.enableAppControl() else {
                    throw PTPIPClientSessionError.appControlUnavailable
                }
                try session.identify()
                onPhase(.connected, session.identity.displayName)
                return session
            } catch {
                session.disconnect()
                throw error
            }
        }
    #endif

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

    /// Refreshes the semantic Android monitor readback without exposing a PTP
    /// property ID or encoded bytes to Kotlin.
    ///
    /// The bootstrap is deliberately bounded to the high-value header and
    /// safety fields. Subsequent calls read one property in the shared core's
    /// conservative round-robin order, so polling does not monopolize the
    /// command channel or starve live-view frame fetches. A `DevicePropChanged`
    /// request is accepted only for a property already supported by that core
    /// order. Any unsupported body/mode read preserves accumulated values and
    /// returns a non-terminal result; it never disconnects the session.
    public func refreshAndroidPropertySnapshot(
        _ request: AndroidCameraPropertyRefreshRequest
    ) -> AndroidCameraPropertyReadback {
        commandLifecycleLock.lock()
        defer { commandLifecycleLock.unlock() }
        guard !isMediaModeActive else {
            return androidPropertyReadback(result: .mediaBusy)
        }

        switch request {
        case .bootstrap:
            var result: AndroidCameraPropertyRefreshResult = .accepted
            for property in Self.androidBootstrapPropertyOrder {
                result = mergedAndroidPropertyRefreshResult(
                    result, refreshAndroidProperty(property))
                if result == .transportFailed { break }
            }
            if result != .transportFailed {
                result = mergedAndroidPropertyRefreshResult(result, refreshAndroidStorage())
            }
            return androidPropertyReadback(result: result)
        case .next(let isRecording):
            let pollOrder = PTPPropertyCode.monitorPollOrder(isRecording: isRecording)
            guard !pollOrder.isEmpty else {
                return androidPropertyReadback(result: .accepted)
            }
            let property = pollOrder[androidPropertyPollIndex % pollOrder.count]
            androidPropertyPollIndex = (androidPropertyPollIndex + 1) % pollOrder.count
            var result = refreshAndroidProperty(property)
            if result != .transportFailed,
                CameraMonitorPollPolicy.isDue(
                    lastRefreshAt: androidLastStorageRefreshAt,
                    now: Date(),
                    interval: CameraMonitorPollPolicy.storageRefreshInterval)
            {
                result = mergedAndroidPropertyRefreshResult(result, refreshAndroidStorage())
            }
            return androidPropertyReadback(result: result)
        case .propertyChanged(let rawCode):
            guard let property = PTPPropertyCode(rawValue: rawCode),
                PTPPropertyCode.liveMonitorPollOrder.contains(property)
            else {
                // The event stream preserves unknown properties for callers,
                // but a raw event alone is not evidence that this readback
                // model knows how to decode one.
                return androidPropertyReadback(result: .accepted)
            }
            return androidPropertyReadback(result: refreshAndroidProperty(property))
        }
    }

    /// Performs one shared-core property read and updates only that decoded
    /// field in the accumulated Android snapshot.
    private func refreshAndroidProperty(
        _ property: PTPPropertyCode
    ) -> AndroidCameraPropertyRefreshResult {
        do {
            let data = try readProperty(property)
            androidPropertySnapshot = androidPropertySnapshot.applying(
                property: property, data: data)
            return .accepted
        } catch let error as PTPIPClientSessionError {
            switch error {
            case .mediaModeActive, .mediaModeRequired:
                return .mediaBusy
            case .operationRejected, .unsupportedProperty:
                return .unsupported
            default:
                return .transportFailed
            }
        } catch {
            return .transportFailed
        }
    }

    /// Refreshes active-card capacity at the shared core's slow storage cadence.
    private func refreshAndroidStorage() -> AndroidCameraPropertyRefreshResult {
        do {
            guard let storage = try readStorageInfo() else { return .unsupported }
            androidStorageInfo = storage
            androidLastStorageRefreshAt = Date()
            return .accepted
        } catch let error as PTPIPClientSessionError {
            switch error {
            case .mediaModeActive, .mediaModeRequired:
                return .mediaBusy
            case .operationRejected:
                return .unsupported
            default:
                return .transportFailed
            }
        } catch {
            return .transportFailed
        }
    }

    /// Packages the accumulated snapshot without allowing a transient failed
    /// read to erase useful last-known camera state.
    private func androidPropertyReadback(
        result: AndroidCameraPropertyRefreshResult
    ) -> AndroidCameraPropertyReadback {
        AndroidCameraPropertyReadback(
            result: result, properties: androidPropertySnapshot, storage: androidStorageInfo)
    }

    /// Preserves the most useful non-terminal reason while a bootstrap carries
    /// on to other supported fields. A transport failure stops that burst.
    private func mergedAndroidPropertyRefreshResult(
        _ lhs: AndroidCameraPropertyRefreshResult,
        _ rhs: AndroidCameraPropertyRefreshResult
    ) -> AndroidCameraPropertyRefreshResult {
        if lhs == .transportFailed || rhs == .transportFailed { return .transportFailed }
        if lhs == .mediaBusy || rhs == .mediaBusy { return .mediaBusy }
        if lhs == .unsupported || rhs == .unsupported { return .unsupported }
        return .accepted
    }

    /// Bounded first-refresh set: the values the operator needs before the
    /// full low-rate round-robin fills in lens, audio, focus, and display
    /// details. Each read remains a separate serialized PTP transaction.
    private static let androidBootstrapPropertyOrder: [PTPPropertyCode] = [
        .movieISOSensitivity,
        .movieShutterMode,
        .movieShutterAngle,
        .movieShutterSpeed,
        .movieFNumber,
        .movieWhiteBalance,
        .movieWBColorTemp,
        .movieRecordScreenSize,
        .movieFileType,
        .batteryLevel,
        .warningStatus,
    ]

    // MARK: - Recording

    /// Starts movie recording to the camera card with Nikon's
    /// `StartMovieRecInCard` operation.
    ///
    /// The transaction executor serializes this with live-view frame reads,
    /// so the command runs at a safe protocol boundary rather than racing a
    /// `GetLiveViewImageEx` read on the shared command socket.
    public func startRecording() throws {
        try performRecordingCommand(.startMovieRecInCard)
    }

    /// Stops movie recording with Nikon's `EndMovieRec` operation.
    public func stopRecording() throws {
        try performRecordingCommand(.endMovieRec)
    }

    private func performRecordingCommand(_ operation: PTPOperationCode) throws {
        commandLifecycleLock.lock()
        defer { commandLifecycleLock.unlock() }
        guard !isMediaModeActive else {
            throw PTPIPClientSessionError.mediaModeActive
        }
        try transactExpectingOK(operation)
    }

    // MARK: - Android live-view configuration

    /// Applies one shared-policy preview request before the next live-view start.
    ///
    /// The two Nikon properties control only the monitor JPEG stream. They are
    /// deliberately configured through the same `SetDevicePropValueEx` path
    /// as the iOS shell, and the frame interval only changes Android's
    /// `GetLiveViewImageEx` pull cadence. No recording property is read or
    /// written here.
    @discardableResult
    public func configureLiveView(
        imageSize: UInt8,
        compression: UInt8,
        frameIntervalNanoseconds: UInt64
    ) -> Bool {
        guard
            (1...3).contains(imageSize),
            (1...3).contains(compression),
            frameIntervalNanoseconds >= Self.liveViewFrameIntervalNanoseconds,
            frameIntervalNanoseconds <= Self.liveViewFrameIntervalNanoseconds * 2
        else { return false }

        commandLifecycleLock.lock()
        defer { commandLifecycleLock.unlock() }
        guard !isMediaModeActive else { return false }

        liveViewCondition.lock()
        guard !liveViewPumpActive else {
            liveViewCondition.unlock()
            return false
        }
        configuredLiveViewFrameIntervalNanoseconds = frameIntervalNanoseconds
        liveViewCondition.unlock()

        let sizeApplied = setLiveViewByte(.liveViewImageSize, value: imageSize)
        let compressionApplied = setLiveViewByte(.liveViewImageCompression, value: compression)
        return sizeApplied && compressionApplied
    }

    /// Mirrors iOS's best-effort preview property write. A body may reject an
    /// unverified compression enum, but the monitor still attempts to start
    /// with the latest safe request instead of mutating a recording setting.
    private func setLiveViewByte(_ property: PTPPropertyCode, value: UInt8) -> Bool {
        do {
            try transactExpectingOK(
                .setDevicePropValueEx,
                parameters: [property.rawValue],
                dataPhase: .dataOut,
                dataOut: Data([value]))
            return true
        } catch {
            return false
        }
    }

    // MARK: - Camera controls

    /// Applies one human-readable Android camera-control selection through the
    /// shared core's Nikon write model.
    ///
    /// Kotlin supplies only a semantic selector and a label; the JNI wire mapper
    /// resolves that selector to ``PTPCameraControl``. This layer validates the
    /// label through `PTPCameraPropertyWrite`, keeps Kelvin white balance as the
    /// required mode-then-temperature sequence, and sends each write through the
    /// same serialized command channel as record control and live view. Codec /
    /// resolution labels intentionally remain unsupported because only
    /// camera-advertised raw descriptor values are safe for those controls.
    public func applyControl(_ control: PTPCameraControl, label: String) throws {
        commandLifecycleLock.lock()
        defer { commandLifecycleLock.unlock() }
        guard !isMediaModeActive else {
            throw PTPIPClientSessionError.mediaModeActive
        }

        let writes = PTPCameraPropertyWrite.requests(
            control: control,
            label: label,
            snapshot: PTPCameraPropertySnapshot())
        guard !writes.isEmpty else {
            throw PTPIPClientSessionError.unsupportedControl(control, label)
        }
        for write in writes {
            try writeCameraProperty(write)
        }
    }

    /// Writes one shared-core-encoded camera property using the operation the
    /// Nikon body expects for that property width. Standard 16-bit `0xDxxx`
    /// properties must use `SetDevicePropValue` (0x1016); only 32-bit extended
    /// `0x0001_Dxxx` properties use Nikon's `SetDevicePropValueEx` (0x943C).
    private func writeCameraProperty(_ write: PTPCameraPropertyWrite) throws {
        let operation: PTPOperationCode =
            write.property.rawValue <= UInt32(UInt16.max)
            ? .setDevicePropValue
            : .setDevicePropValueEx
        try transactExpectingOK(
            operation,
            parameters: [write.property.rawValue],
            dataPhase: .dataOut,
            dataOut: write.data)
    }

    // MARK: - Event channel

    /// Starts one bounded background reader for the PTP-IP event socket.
    ///
    /// The Nikon body pushes asynchronous notifications on this socket. If no
    /// reader drains it, the camera's send buffer can eventually stall an
    /// otherwise healthy session. Parsed events retain their raw code and
    /// parameters, so callers never have to guess the meaning of a vendor
    /// event that the shared core has not classified yet.
    ///
    /// Idle reads time out normally and keep draining. Any other transport
    /// failure ends the stream, closes the command socket (the session is no
    /// longer trustworthy), and is passed to [onEnded] as an operator-facing
    /// message. The callback is delivered at most once. A session owns one
    /// drain for its lifetime; disconnect closes the event socket and joins its
    /// reader before tearing down the command socket.
    public func startEventDrain(
        onEvent: @escaping @Sendable (PTPEvent) -> Void,
        onEnded: @escaping @Sendable (String?) -> Void
    ) throws {
        transactionLock.lock()
        let closed = isClosed
        transactionLock.unlock()
        guard !closed else { throw PTPIPClientSessionError.connectionClosed }

        eventDrainCondition.lock()
        guard !eventDrainActive else {
            eventDrainCondition.unlock()
            throw PTPIPClientSessionError.eventDrainAlreadyActive
        }
        eventDrainActive = true
        eventDrainStopRequested = false
        eventDrainCondition.unlock()

        Thread.detachNewThread { [self] in
            runEventDrain(onEvent: onEvent, onEnded: onEnded)
        }
    }

    /// Stops the event reader by closing its dedicated socket, then waits only
    /// until the reader observes that closure. This is intentionally private:
    /// an active PTP-IP session needs its event socket drained continuously.
    private func stopEventDrain() {
        eventDrainCondition.lock()
        guard eventDrainActive else {
            eventDrainCondition.unlock()
            return
        }
        eventDrainStopRequested = true
        eventDrainCondition.unlock()

        #if os(Android)
            if usbTransport == nil {
                // Closing the PTP-IP event descriptor interrupts a blocked
                // poll immediately. USB interrupt reads are independently
                // bounded to one second, so closing the whole claimed device
                // here would incorrectly tear down command traffic.
                event?.close()
            }
        #else
            // Closing the event descriptor interrupts a blocked poll
            // immediately; the bounded wait below is only a guard against a
            // platform-level wake race, not a normal ten-second socket timeout.
            event?.close()
        #endif

        eventDrainCondition.lock()
        let deadline = Date().addingTimeInterval(eventDrainStopTimeout + 2)
        while eventDrainActive {
            guard eventDrainCondition.wait(until: deadline) else { break }
        }
        eventDrainCondition.unlock()
    }

    private func runEventDrain(
        onEvent: @escaping @Sendable (PTPEvent) -> Void,
        onEnded: @escaping @Sendable (String?) -> Void
    ) {
        #if os(Android)
            if let usbTransport {
                runUSBEventDrain(
                    transport: usbTransport,
                    onEvent: onEvent,
                    onEnded: onEnded
                )
                return
            }
        #endif
        guard let event, let command else {
            finishEventDrain(
                onEnded: onEnded,
                failure: PTPIPClientSessionError.connectionClosed.localizedDescription
            )
            return
        }
        var failure: String?
        while !eventDrainStopIsRequested() {
            do {
                // Mirror the iOS transport: unexpected packets and malformed
                // event payloads are skipped, while valid-but-unknown event
                // codes still surface through PTPEvent.rawEventCode.
                let packet = try event.readPacket()
                guard let parsed = try? PTPEvent(from: packet) else { continue }
                onEvent(parsed)
            } catch let error as PTPIPClientSessionError {
                if case .timeout = error { continue }
                if !eventDrainStopIsRequested() {
                    failure = error.localizedDescription
                }
                break
            } catch {
                if !eventDrainStopIsRequested() {
                    failure = error.localizedDescription
                }
                break
            }
        }

        if failure != nil {
            // A broken event channel means this PTP-IP session can no longer
            // guarantee camera-authoritative state. Close the command socket
            // too, waking any in-flight transaction before Kotlin receives the
            // terminal callback and is allowed to reconnect.
            command.close()
            transactionLock.lock()
            isClosed = true
            transactionLock.unlock()
        }

        finishEventDrain(onEnded: onEnded, failure: failure)
    }

    #if os(Android)
        /// USB PTP events arrive through the claimed interrupt endpoint. A
        /// short idle timeout is normal; any other failure closes the shared
        /// transport so Kotlin cannot continue presenting stale camera state.
        private func runUSBEventDrain(
            transport: AndroidUSBPTPTransport,
            onEvent: @escaping @Sendable (PTPEvent) -> Void,
            onEnded: @escaping @Sendable (String?) -> Void
        ) {
            var failure: String?
            while !eventDrainStopIsRequested() {
                do {
                    onEvent(try transport.nextEventSynchronously())
                } catch let error as AndroidUSBPTPTransportError {
                    if case .timeout = error { continue }
                    if !eventDrainStopIsRequested() {
                        failure = error.localizedDescription
                    }
                    break
                } catch {
                    if !eventDrainStopIsRequested() {
                        failure = error.localizedDescription
                    }
                    break
                }
            }

            if failure != nil {
                transport.close()
                transactionLock.lock()
                isClosed = true
                transactionLock.unlock()
            }
            finishEventDrain(onEnded: onEnded, failure: failure)
        }
    #endif

    /// Marks the single event reader inactive before calling Kotlin back: a
    /// listener may disconnect immediately, and must never wait for its own
    /// Swift-owned reader thread.
    private func finishEventDrain(
        onEnded: @escaping @Sendable (String?) -> Void,
        failure: String?
    ) {
        eventDrainCondition.lock()
        eventDrainActive = false
        eventDrainStopRequested = false
        eventDrainCondition.broadcast()
        eventDrainCondition.unlock()
        onEnded(failure)
    }

    private func eventDrainStopIsRequested() -> Bool {
        eventDrainCondition.lock()
        defer { eventDrainCondition.unlock() }
        return eventDrainStopRequested
    }

    private var eventDrainStopTimeout: TimeInterval {
        #if os(Android)
            if usbTransport != nil { return 1 }
        #endif
        return Double(event?.timeoutMilliseconds ?? 1_000) / 1_000
    }

    // MARK: - Media ownership and transfer

    /// Gives media browsing/playback exclusive ownership of the camera's
    /// serialized command channel. Claiming media mode first prevents a new
    /// live-view start from racing the transition; the existing pump is then
    /// stopped and joined before this method returns.
    public func enterMediaMode() {
        commandLifecycleLock.lock()
        liveViewCondition.lock()
        mediaModeActive = true
        liveViewCondition.unlock()
        commandLifecycleLock.unlock()
        stopLiveView()
    }

    /// Releases media ownership so monitor live view may start again.
    public func exitMediaMode() {
        commandLifecycleLock.lock()
        defer { commandLifecycleLock.unlock() }
        stopMediaTransfer()
        releaseMediaMode()
    }

    /// Clears the media-ownership flag while `commandLifecycleLock` is held.
    private func releaseMediaMode() {
        liveViewCondition.lock()
        mediaModeActive = false
        liveViewCondition.broadcast()
        liveViewCondition.unlock()
    }

    /// Whether the media surface currently owns the shared command channel.
    var isMediaModeActive: Bool {
        liveViewCondition.lock()
        defer { liveViewCondition.unlock() }
        return mediaModeActive
    }

    /// Resolves the true object size. Normal PTP metadata is sufficient below
    /// 4 GiB; its UINT32 sentinel routes large objects through Nikon's 64-bit
    /// `GetObjectSize` operation.
    public func resolvedObjectSize(handle: UInt32, reportedSize: UInt64) throws -> UInt64 {
        guard reportedSize == UInt64(UInt32.max) else { return reportedSize }
        let result = try transactExpectingOK(
            .getObjectSize, parameters: [handle], dataPhase: .dataIn)
        return try PTPObjectSize(data: result.data).bytes
    }

    /// Starts a progressive object transfer on one facade-owned thread.
    ///
    /// Protocol policy stays in the shared core: the cursor selects standard
    /// `GetPartialObject` or Nikon `GetPartialObjectEx`, owns the 4 MiB chunk
    /// size, validates every advance, and maintains the 64-bit offset. All
    /// callbacks are serialized on the pump thread, with exactly one terminal
    /// callback after the final chunk.
    public func startMediaTransfer(
        handle: UInt32,
        reportedSize: UInt64,
        resumeOffset: UInt64 = 0,
        onStarted: @escaping @Sendable (UInt64) -> Void,
        onChunk: @escaping @Sendable (UInt64, Data) -> Bool,
        onCompleted: @escaping @Sendable (UInt64) -> Void,
        onStopped: @escaping @Sendable (UInt64) -> Void,
        onFailed: @escaping @Sendable (String) -> Void
    ) throws {
        guard isMediaModeActive else {
            throw PTPIPClientSessionError.mediaModeRequired
        }
        let totalBytes = try resolvedObjectSize(handle: handle, reportedSize: reportedSize)
        let cursor = try PTPObjectTransferCursor(
            objectHandle: handle,
            totalBytes: totalBytes,
            resumeOffset: resumeOffset,
            supportsExtendedReads: true)

        mediaTransferCondition.lock()
        guard !mediaTransferActive else {
            mediaTransferCondition.unlock()
            throw PTPIPClientSessionError.connectionFailed(
                "A camera-media transfer is already active.")
        }
        mediaTransferActive = true
        mediaTransferStopRequested = false
        mediaTransferCondition.unlock()

        Thread.detachNewThread { [self] in
            runMediaTransfer(
                cursor: cursor,
                onStarted: onStarted,
                onChunk: onChunk,
                onCompleted: onCompleted,
                onStopped: onStopped,
                onFailed: onFailed)
        }
    }

    /// Stops and joins the active object transfer. The in-flight camera read
    /// remains bounded by the command socket timeout. Safe when idle.
    public func stopMediaTransfer() {
        mediaTransferCondition.lock()
        defer { mediaTransferCondition.unlock() }
        guard mediaTransferActive else { return }
        mediaTransferStopRequested = true
        let deadline = Date().addingTimeInterval(
            commandTransactionTimeout + 2)
        while mediaTransferActive {
            guard mediaTransferCondition.wait(until: deadline) else { return }
        }
    }

    private func runMediaTransfer(
        cursor initialCursor: PTPObjectTransferCursor,
        onStarted: (UInt64) -> Void,
        onChunk: (UInt64, Data) -> Bool,
        onCompleted: (UInt64) -> Void,
        onStopped: (UInt64) -> Void,
        onFailed: (String) -> Void
    ) {
        var cursor = initialCursor
        onStarted(cursor.totalBytes)
        var failure: String?

        while !mediaTransferStopIsRequested(), !cursor.isComplete {
            do {
                guard let request = try cursor.nextRequest() else { break }
                let result = try transactExpectingOK(
                    request.operationCode,
                    parameters: request.parameters,
                    dataPhase: .dataIn)
                let offset = cursor.offset
                guard onChunk(offset, result.data) else {
                    throw PTPIPClientSessionError.connectionFailed(
                        "The progressive media cache rejected a camera chunk.")
                }
                // The JNI upcall is synchronous: Kotlin has persisted this
                // range before returning, so only now may the core cursor
                // advance its durable resume point.
                try cursor.advance(by: UInt64(result.data.count))
            } catch {
                failure = error.localizedDescription
                break
            }
        }

        if let failure {
            onFailed(failure)
        } else if mediaTransferStopIsRequested() {
            onStopped(cursor.offset)
        } else {
            onCompleted(cursor.totalBytes)
        }

        mediaTransferCondition.lock()
        mediaTransferActive = false
        mediaTransferStopRequested = false
        mediaTransferCondition.broadcast()
        mediaTransferCondition.unlock()
    }

    private func mediaTransferStopIsRequested() -> Bool {
        mediaTransferCondition.lock()
        defer { mediaTransferCondition.unlock() }
        return mediaTransferStopRequested
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
        frameIntervalNanoseconds: UInt64? = nil,
        onFrame: @escaping @Sendable (PTPLiveViewFrame, Int64) -> Void,
        onEnded: @escaping @Sendable () -> Void
    ) throws {
        liveViewCondition.lock()
        guard !mediaModeActive else {
            liveViewCondition.unlock()
            throw PTPIPClientSessionError.mediaModeActive
        }
        guard !liveViewPumpActive else {
            liveViewCondition.unlock()
            throw PTPIPClientSessionError.liveViewAlreadyActive
        }
        liveViewPumpActive = true
        liveViewStopRequested = false
        let effectiveFrameIntervalNanoseconds =
            frameIntervalNanoseconds ?? configuredLiveViewFrameIntervalNanoseconds
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
                frameIntervalNanoseconds: effectiveFrameIntervalNanoseconds,
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
            commandTransactionTimeout + 2)
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
        commandLifecycleLock.lock()
        defer { commandLifecycleLock.unlock() }
        stopEventDrain()
        stopMediaTransfer()
        releaseMediaMode()
        stopLiveView()
        transactionLock.lock()
        let alreadyClosed = isClosed
        isClosed = true
        transactionLock.unlock()
        guard !alreadyClosed else { return }

        #if os(Android)
            if let usbTransport {
                _ = try? usbTransport.executeTransactionSynchronously(
                    operationCode: .closeSession,
                    deadline: .seconds(2)
                )
                usbTransport.close()
                return
            }
        #endif
        command?.timeoutMilliseconds = 2_000
        _ = try? executeTransaction(.closeSession)
        command?.close()
        event?.close()
    }

    // MARK: - Transaction executor

    // Internal (not private): the media-browse slice (MediaBrowse.swift)
    // extends the session with object/storage transactions.
    @discardableResult
    func transactExpectingOK(
        _ operationCode: PTPOperationCode,
        parameters: [UInt32] = [],
        dataPhase: PTPDataPhase = .noDataOrDataIn,
        dataOut: Data? = nil
    ) throws -> PTPIPTransactionResult {
        let result = try executeTransaction(
            operationCode,
            parameters: parameters,
            dataPhase: dataPhase,
            dataOut: dataOut)
        guard result.operationResponse.responseCode == .ok else {
            throw PTPIPClientSessionError.operationRejected(
                operationCode, result.operationResponse.responseCode)
        }
        return result
    }

    /// Executes one full PTP transaction on the command channel: operation
    /// request, optional host-to-camera data phase, then packets in until
    /// `Operation_Response`, collected by the core.
    func executeTransaction(
        _ operationCode: PTPOperationCode,
        transactionID explicitTransactionID: UInt32? = nil,
        parameters: [UInt32] = [],
        dataPhase: PTPDataPhase = .noDataOrDataIn,
        dataOut: Data? = nil
    ) throws -> PTPIPTransactionResult {
        #if os(Android)
            if let usbTransport {
                return try usbTransport.executeTransactionSynchronously(
                    operationCode: operationCode,
                    transactionID: explicitTransactionID,
                    parameters: parameters,
                    dataPhase: dataPhase,
                    dataOut: dataOut
                )
            }
        #endif
        transactionLock.lock()
        defer { transactionLock.unlock() }

        guard let command else {
            throw PTPIPClientSessionError.connectionClosed
        }

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
        if let dataOut {
            try command.send(
                PTPIPPacket(
                    type: .startData,
                    payload: Data(
                        PTPDataPayloads.startData(
                            transactionID: transactionID,
                            totalLength: UInt64(dataOut.count)))))
            try command.send(
                PTPIPPacket(
                    type: .endData,
                    payload: Data(
                        PTPDataPayloads.endData(transactionID: transactionID, data: dataOut))))
        }

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

    private var commandTransactionTimeout: TimeInterval {
        #if os(Android)
            if usbTransport != nil { return 10 }
        #endif
        return Double(command?.timeoutMilliseconds ?? 10_000) / 1_000
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

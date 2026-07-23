// Scripted fake Nikon ZR: a local PTP-IP TCP server answering the CIPA DC-005
// Init handshake and the Nikon open/pair/identify + property-read sequence,
// so `PTPIPClientSession` can be exercised end to end without hardware.
//
// The payload codecs themselves are covered by the core suites
// (PTPIPHandshakeTests, PTPIPPacketTests, PTPIPTransactionTests); this server
// exists for wire-level session sequencing, which nothing else tests.

import Foundation
import OpenZCineCore

#if canImport(Android)
    import Android
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Darwin)
    import Darwin
#endif

struct FakeZRRequest: Equatable {
    let operation: PTPOperationCode
    let parameters: [UInt32]
    let dataPhase: PTPDataPhase
    let dataOut: Data?

    init(
        operation: PTPOperationCode,
        parameters: [UInt32],
        dataPhase: PTPDataPhase = .noDataOrDataIn,
        dataOut: Data? = nil
    ) {
        self.operation = operation
        self.parameters = parameters
        self.dataPhase = dataPhase
        self.dataOut = dataOut
    }
}

/// One property-write data phase received by the scripted camera.
struct FakeZRPropertyWrite: Equatable {
    let operation: PTPOperationCode
    let property: UInt32
    let data: Data
}

/// One recording card exposed by the scripted camera's storage operations.
struct FakeZRStorageCard: Equatable, Sendable {
    let storageID: UInt32
    let totalCapacityBytes: UInt64
    let freeSpaceBytes: UInt64
}

/// A scripted fake ZR listening on an ephemeral localhost port.
// SAFETY: `@unchecked Sendable` — mutable state is guarded by `lock`; each
// accepted connection runs on its own thread.
final class FakeZRServer: @unchecked Sendable {
    struct Options {
        /// When false, `ChangeApplicationMode` is refused until the pairing
        /// sequence (`GetPairingInfo` + `ConfirmPairing`) completes — the
        /// first-time-pairing camera behavior.
        var acceptsAppControlImmediately = true
        /// Closes the command channel when app control is probed, simulating a
        /// transport failure rather than a recoverable saved-profile rejection.
        var disconnectsOnChangeApplicationMode = false
        /// Reply `Init_Fail` to every `Init_Command_Request`.
        var refusesInit = false
        /// TCP port to listen on; 0 picks an ephemeral port. The on-device
        /// end-to-end run binds the real PTP-IP port (15740) so
        /// `adb reverse tcp:15740 tcp:15740` can reach it.
        var port: UInt16 = 0
        /// Cadence of the synthesized live-view stream: the served frame
        /// counter advances by wall clock at this period, so a slow poller
        /// sees counter gaps (frames dropped at the source, never queued).
        var liveViewFrameIntervalNanoseconds: UInt64 = 40_000_000  // 25 fps
        /// Scripted card contents served by the storage/object operations
        /// (`FakeZRMediaCard.objects` by default; empty = an empty card).
        var mediaObjects: [FakeZRMediaObject] = FakeZRMediaCard.objects
        /// Drops the command socket instead of answering `GetObjectHandles`.
        var disconnectsOnGetObjectHandles = false
        /// Optional ignored/local movie file served as the payload for
        /// `mediaPayloadHandle` during the physical-device playback demo.
        var mediaPayloadFileURL: URL?
        var mediaPayloadHandle: UInt32 = 0x1009
        /// Prints operation names/parameters for opt-in device-demo diagnosis.
        var traceOperations = ProcessInfo.processInfo.environment["ZC_FAKE_ZR_TRACE"] == "1"
        var cameraName = "ZR_6001234"
        var pairingPIN = "1234"
        /// Response sent for `ConfirmPairing`; a non-OK response keeps the
        /// fake unpaired and verifies the app does not claim body confirmation.
        var confirmPairingResponseCode: UInt16 = PTPResponseCode.ok.rawValue
        var batteryPercent: UInt8 = 80
        /// Properties the fake rejects as unsupported for readback tests.
        var unsupportedPropertyCodes: Set<UInt32> = []
        /// Per-property descriptor enums used to prove the app never exposes values outside the
        /// connected body's current advertised domain.
        var descriptorEnumOverrides: [PTPPropertyCode: [UInt32]] = [:]
        /// Descriptor properties reported as readable but not writable.
        var readOnlyDescriptorCodes: Set<UInt32> = []
        /// Per-property wire identity overrides used to exercise descriptor validation.
        var descriptorIdentityOverrides: [UInt32: UInt32] = [:]
        /// Per-property PTP data-type overrides used to exercise descriptor validation.
        var descriptorDataTypeOverrides: [UInt32: UInt16] = [:]
        /// Descriptor properties that return an accepted malformed payload after their first read.
        var malformedDescriptorCodesAfterFirstRead: Set<UInt32> = []
        /// Properties that return valid bytes once, then an accepted short payload.
        var shortPropertyCodesAfterFirstRead: Set<UInt32> = []
        /// Deterministic command-response latency used to prove RTT is measured, not synthesized.
        var commandResponseDelayMilliseconds: UInt64 = 0
        /// Ordered recording cards exposed by both storage-ID operations.
        var storageCards: [FakeZRStorageCard] = [
            FakeZRStorageCard(
                storageID: FakeZRMediaCard.storageID,
                totalCapacityBytes: 1_000_000_000_000,
                freeSpaceBytes: 500_000_000_000)
        ]
        var manufacturer = "Nikon Corporation"
        var model = "ZR"
        var deviceVersion = "01.00"
        var serialNumber = "6001234"
        /// Response sent for Nikon `StartMovieRecInCard`. The default accepts
        /// the command; tests can supply a real PTP rejection code.
        var startRecordingResponseCode: UInt16 = 0x2001
        /// Response sent for Nikon `EndMovieRec`. The default accepts the
        /// command; tests can supply a real PTP rejection code.
        var stopRecordingResponseCode: UInt16 = 0x2001
        /// Response sent for either standard or extended property writes.
        /// Tests use a real PTP rejection code to verify command propagation.
        var propertyWriteResponseCode: UInt16 = 0x2001
        /// Accepted writes that the fake deliberately refuses to apply to authoritative readback.
        var ignoredPropertyWrites: Set<UInt32> = []
        /// Advertised UINT16 range for the active white-balance tune descriptor.
        var whiteBalanceTintMinimum: UInt16 = 0
        var whiteBalanceTintMaximum: UInt16 = 1_224
        var whiteBalanceTintStep: UInt16 = 2
        /// Response sent for Nikon `ChangeAfArea`.
        var changeAfAreaResponseCode: UInt16 = 0x2001
        /// Response sent for Nikon `EndTracking`.
        var endTrackingResponseCode: UInt16 = 0x2001
        /// Response sent for Nikon `AfDriveCancel`.
        var afDriveCancelResponseCode: UInt16 = 0x2001
        /// Whether synthesized live-view headers contain authoritative focus data.
        var focusMetadataEnabled = true
        var focusCoordinateWidth: UInt16 = 6_048
        var focusCoordinateHeight: UInt16 = 3_400
        var focusCenterX: UInt16 = 4_200
        var focusCenterY: UInt16 = 1_200
        var focusTrackingAFActive = true
        var focusSubjectDetectionActive = true
        /// New live-view frames needed after EndTracking before the header clears.
        var focusTrackingReleaseFrames: UInt64 = 3
        /// Removes the complete focus object after release, matching bodies that clear dimensions.
        var focusMetadataDisappearsAfterRelease = false
        /// Keeps dimensions but removes every AF box after release.
        var focusBoxesDisappearAfterRelease = false
        /// Keeps tracking set through the 15-frame settle ceiling.
        var focusTrackingNeverReleases = false
        /// Simulates ChangeAfArea re-latching tracking before the second release.
        var focusRelatchesAfterChange = false
        /// Current camera focus properties, expressed as real camera raw values.
        var focusModeRaw: UInt8 = 1  // AF-C
        var focusAreaRaw: UInt16 = 0x8033  // Subject
        var focusSubjectRaw: UInt8 = 2  // People
        /// Current packed movie-screen-size value returned by property readback.
        var movieRecordScreenSizeRaw: UInt64 = 0x1770_0D08_0019_0000
        /// Current packed movie-file-type value returned by property readback.
        var movieFileTypeRaw: UInt32 = 0x0031_0A03
        /// Optional codec-specific `MovScreenSize` descriptor domains. When configured, a codec
        /// write switches the current screen size to the first value in that codec's domain.
        var screenSizeModesByFileType: [UInt32: [UInt64]] = [:]
    }

    let port: UInt16

    private let options: Options
    private let listenDescriptor: Int32
    private let lock = NSLock()
    /// `stop()` does not return until the listener thread has exited. Without
    /// that handoff, the OS may recycle this raw descriptor for a later fake
    /// server while the old accept loop is still scheduled. The old fixture
    /// could then accept the new server's client and reply with its own script.
    private let acceptLoopExitCondition = NSCondition()
    private let eventConnectionCondition = NSCondition()
    private let eventSendLock = NSLock()
    private var operationLog: [PTPOperationCode] = []
    private var rawOperationLog: [UInt16] = []
    private var requestLog: [FakeZRRequest] = []
    private var propertyWriteLog: [FakeZRPropertyWrite] = []
    private var propertyReadCounts: [UInt32: Int] = [:]
    private var descriptorReadCounts: [UInt32: Int] = [:]
    private var propertyValueOverrides: [UInt32: Data] = [:]
    private var transactionIDLog: [UInt32] = []
    private var pairingConfirmed = false
    private var stopped = false
    private var acceptLoopHasExited = false
    private var liveViewActive = false
    private var liveViewEpoch = Date()
    private var recording = false
    private var focusCenterX: UInt16
    private var focusCenterY: UInt16
    private var focusTrackingAFActive: Bool
    private var focusSubjectDetectionActive: Bool
    private var focusReleaseAtFrame: UInt64?
    private var focusHasReleased = false
    private var focusModeRaw: UInt8
    private var focusAreaRaw: UInt16
    private var focusSubjectRaw: UInt8
    private var eventConnection: Int32 = -1

    init(options: Options = Options()) throws {
        self.options = options
        focusCenterX = options.focusCenterX
        focusCenterY = options.focusCenterY
        focusTrackingAFActive = options.focusTrackingAFActive
        focusSubjectDetectionActive = options.focusSubjectDetectionActive
        focusModeRaw = options.focusModeRaw
        focusAreaRaw = options.focusAreaRaw
        focusSubjectRaw = options.focusSubjectRaw

        let descriptor = socket(AF_INET, SOCK_STREAM, Int32(IPPROTO_TCP))
        guard descriptor >= 0 else { throw FakeZRServerError.socketFailed }
        var reuse: Int32 = 1
        setsockopt(
            descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        #if canImport(Darwin)
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(options.port).bigEndian  // 0 = ephemeral
        address.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian  // 127.0.0.1

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                bind(descriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, listen(descriptor, 8) == 0 else {
            close(descriptor)
            throw FakeZRServerError.bindFailed
        }

        var bound = sockaddr_in()
        var boundLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &bound) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                _ = getsockname(descriptor, socketAddress, &boundLength)
            }
        }
        self.port = UInt16(bigEndian: bound.sin_port)
        self.listenDescriptor = descriptor

        Thread.detachNewThread { [weak self] in self?.acceptLoop() }
    }

    func stop() {
        lock.lock()
        let needsShutdown = !stopped
        stopped = true
        lock.unlock()
        if needsShutdown {
            shutdown(listenDescriptor, Int32(SHUT_RDWR))
            close(listenDescriptor)
        }
        waitForAcceptLoopExit()
    }

    /// Every PTP operation received, in arrival order, across all connections.
    func receivedOperations() -> [PTPOperationCode] {
        lock.lock()
        defer { lock.unlock() }
        return operationLog
    }

    /// Every raw PTP operation code, including vendor codes the production enum does not expose.
    func receivedRawOperationCodes() -> [UInt16] {
        lock.lock()
        defer { lock.unlock() }
        return rawOperationLog
    }

    /// Full operation/parameter records for transfer-range assertions.
    func receivedRequests() -> [FakeZRRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requestLog
    }

    /// Property writes received with their actual host-to-camera data payloads.
    func receivedPropertyWrites() -> [FakeZRPropertyWrite] {
        lock.lock()
        defer { lock.unlock() }
        return propertyWriteLog
    }

    /// Changes the camera-side codec without recording an app property write. Tests use this to
    /// exercise the same state transition that a physical body's `DevicePropChanged(D0AF)` event
    /// announces.
    func setCameraMovieFileType(_ raw: UInt32) {
        lock.lock()
        defer { lock.unlock() }
        updateCameraMovieFileTypeLocked(raw)
    }

    /// Transaction IDs in arrival order (parallel to `receivedOperations`).
    func receivedTransactionIDs() -> [UInt32] {
        lock.lock()
        defer { lock.unlock() }
        return transactionIDLog
    }

    /// Whether the fake body believes it is streaming live view — false again
    /// only after a client `EndLiveView` (the heat-audit assertion hook).
    func isLiveViewActive() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return liveViewActive
    }

    /// Whether the fake body is currently recording to its card.
    func isRecording() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return recording
    }

    /// Waits until a client has completed the PTP-IP event-channel handshake.
    /// Tests use this before injecting an event so delivery never depends on a
    /// connection-accept race.
    func waitForEventChannel(timeout: TimeInterval = 1) -> Bool {
        eventConnectionCondition.lock()
        defer { eventConnectionCondition.unlock() }
        if eventConnection >= 0 { return true }
        return eventConnectionCondition.wait(
            until: Date().addingTimeInterval(timeout)) && eventConnection >= 0
    }

    /// Pushes one raw PTP-IP Event packet to the connected event socket.
    ///
    /// Event codes and parameters intentionally stay raw so facade tests can
    /// cover established Nikon recording events as well as unknown/property
    /// notifications without this fake inventing a vendor-value vocabulary.
    @discardableResult
    func sendEvent(
        rawEventCode: UInt16,
        transactionID: UInt32 = 0,
        parameters: [UInt32] = []
    ) -> Bool {
        eventConnectionCondition.lock()
        let connection = eventConnection
        eventConnectionCondition.unlock()
        guard connection >= 0 else { return false }

        var payload = ByteCoding.uint16LE(rawEventCode) + ByteCoding.uint32LE(transactionID)
        for parameter in parameters { payload += ByteCoding.uint32LE(parameter) }
        eventSendLock.lock()
        send(connection, PTPIPPacket(type: .event, payload: Data(payload)))
        eventSendLock.unlock()
        return true
    }

    /// Simulates the camera dropping only its PTP-IP event socket. The serve
    /// thread owns the eventual close; shutdown merely wakes its blocked read
    /// without racing descriptor reuse in this test server.
    func closeEventChannel() {
        eventConnectionCondition.lock()
        let connection = eventConnection
        eventConnectionCondition.unlock()
        guard connection >= 0 else { return }
        shutdown(connection, Int32(SHUT_RDWR))
    }

    /// Reconstructs the served frame counter from a delivered frame's header
    /// timecode (the base-256 encoding `liveViewObject` writes).
    static func frameCounter(of timecode: Timecode) -> Int {
        ((timecode.hour * 256 + timecode.minute) * 256 + timecode.second) * 256 + timecode.frame
    }

    // MARK: - Connection handling

    private func acceptLoop() {
        defer {
            acceptLoopExitCondition.lock()
            acceptLoopHasExited = true
            acceptLoopExitCondition.broadcast()
            acceptLoopExitCondition.unlock()
        }
        while true {
            lock.lock()
            let shouldStop = stopped
            lock.unlock()
            guard !shouldStop else { return }

            let connection = accept(listenDescriptor, nil, nil)
            guard connection >= 0 else { return }

            lock.lock()
            let stoppedAfterAccept = stopped
            lock.unlock()
            guard !stoppedAfterAccept else {
                close(connection)
                return
            }
            Thread.detachNewThread { [weak self] in self?.serve(connection) }
        }
    }

    private func waitForAcceptLoopExit() {
        acceptLoopExitCondition.lock()
        defer { acceptLoopExitCondition.unlock() }
        while !acceptLoopHasExited {
            acceptLoopExitCondition.wait()
        }
    }

    private func serve(_ connection: Int32) {
        var isEventConnection = false
        defer {
            if isEventConnection { unregisterEventConnection(connection) }
            close(connection)
        }
        while let packet = try? readPacket(connection) {
            switch packet.type {
            case .initCommandRequest:
                if options.refusesInit {
                    send(
                        connection,
                        PTPIPPacket(
                            type: .initFail, payload: Data(ByteCoding.uint32LE(1))))
                    return
                }
                var payload = ByteCoding.uint32LE(1)  // connection number
                payload += [UInt8](repeating: 0xAB, count: 16)  // responder GUID
                payload += PTPIPFriendlyName.encode(options.cameraName)
                send(connection, PTPIPPacket(type: .initCommandAck, payload: Data(payload)))
            case .initEventRequest:
                registerEventConnection(connection)
                isEventConnection = true
                send(connection, PTPIPPacket(type: .initEventAck, payload: Data()))
            case .operationRequest:
                let requestPayload = Array(packet.payload)
                let dataPhase =
                    requestPayload.count >= 4
                    ? ByteCoding.readUInt32LE(requestPayload, at: 0)
                    : 0
                let transactionID =
                    requestPayload.count >= 10
                    ? ByteCoding.readUInt32LE(requestPayload, at: 6)
                    : 0
                let dataOut: Data?
                if dataPhase == PTPDataPhase.dataOut.rawValue {
                    guard
                        let received = try? receiveDataOut(
                            connection, transactionID: transactionID)
                    else { return }
                    dataOut = received
                } else {
                    dataOut = nil
                }
                respond(
                    connection,
                    requestPayload: requestPayload,
                    dataPhase: PTPDataPhase(rawValue: dataPhase) ?? .noDataOrDataIn,
                    dataOut: dataOut)
            default:
                return
            }
        }
    }

    private func respond(
        _ connection: Int32,
        requestPayload bytes: [UInt8],
        dataPhase: PTPDataPhase,
        dataOut: Data?
    ) {
        guard bytes.count >= 10 else { return }
        let rawOperation = ByteCoding.readUInt16LE(bytes, at: 4)
        let transactionID = ByteCoding.readUInt32LE(bytes, at: 6)
        lock.lock()
        rawOperationLog.append(rawOperation)
        lock.unlock()
        guard let operation = PTPOperationCode(rawValue: rawOperation) else {
            sendResponse(connection, code: 0x2005, transactionID: transactionID)
            return
        }
        var parameters: [UInt32] = []
        var parameterOffset = 10
        while parameterOffset + 4 <= bytes.count {
            parameters.append(ByteCoding.readUInt32LE(bytes, at: parameterOffset))
            parameterOffset += 4
        }
        lock.lock()
        operationLog.append(operation)
        requestLog.append(
            FakeZRRequest(
                operation: operation,
                parameters: parameters,
                dataPhase: dataPhase,
                dataOut: dataOut))
        transactionIDLog.append(transactionID)
        lock.unlock()
        if options.traceOperations {
            print("fake ZR \(operation) \(parameters)")
        }
        if options.commandResponseDelayMilliseconds > 0 {
            Thread.sleep(
                forTimeInterval: Double(options.commandResponseDelayMilliseconds) / 1_000)
        }

        switch operation {
        case .openSession, .closeSession:
            sendResponse(connection, code: 0x2001, transactionID: transactionID)
        case .changeApplicationMode:
            if options.disconnectsOnChangeApplicationMode {
                close(connection)
                return
            }
            lock.lock()
            let accepted = options.acceptsAppControlImmediately || pairingConfirmed
            lock.unlock()
            sendResponse(
                connection, code: accepted ? 0x2001 : 0x2002, transactionID: transactionID)
        case .getPairingInfo:
            sendDataIn(
                connection, data: Data(options.pairingPIN.utf8), transactionID: transactionID)
        case .confirmPairing:
            let response = options.confirmPairingResponseCode
            lock.lock()
            if response == PTPResponseCode.ok.rawValue {
                pairingConfirmed = true
            }
            lock.unlock()
            sendResponse(connection, code: response, transactionID: transactionID)
        case .getDeviceInfo:
            sendDataIn(connection, data: deviceInfoDataset(), transactionID: transactionID)
        case .startLiveView:
            lock.lock()
            liveViewActive = true
            liveViewEpoch = Date()
            lock.unlock()
            sendResponse(connection, code: 0x2001, transactionID: transactionID)
        case .deviceReady:
            sendResponse(connection, code: 0x2001, transactionID: transactionID)
        case .changeAfArea:
            guard parameters.count == 2 else {
                sendResponse(connection, code: 0x2005, transactionID: transactionID)
                return
            }
            lock.lock()
            let changeResponse = options.changeAfAreaResponseCode
            if changeResponse == PTPResponseCode.ok.rawValue {
                focusCenterX = UInt16(clamping: parameters[0])
                focusCenterY = UInt16(clamping: parameters[1])
                if options.focusRelatchesAfterChange {
                    focusTrackingAFActive = true
                    focusSubjectDetectionActive = true
                    focusReleaseAtFrame = nil
                    focusHasReleased = false
                }
            }
            lock.unlock()
            sendResponse(connection, code: changeResponse, transactionID: transactionID)
        case .endTracking:
            lock.lock()
            let endTrackingResponse = options.endTrackingResponseCode
            if endTrackingResponse == PTPResponseCode.ok.rawValue,
                !options.focusTrackingNeverReleases
            {
                focusReleaseAtFrame =
                    currentLiveViewFrameIndexLocked()
                    + options.focusTrackingReleaseFrames
            }
            lock.unlock()
            sendResponse(connection, code: endTrackingResponse, transactionID: transactionID)
        case .afDriveCancel:
            sendResponse(
                connection,
                code: options.afDriveCancelResponseCode,
                transactionID: transactionID)
        case .endLiveView:
            lock.lock()
            liveViewActive = false
            lock.unlock()
            sendResponse(connection, code: 0x2001, transactionID: transactionID)
        case .startMovieRecInCard:
            lock.lock()
            let responseCode = options.startRecordingResponseCode
            if responseCode == 0x2001 { recording = true }
            lock.unlock()
            sendResponse(connection, code: responseCode, transactionID: transactionID)
            if responseCode == 0x2001 {
                _ = sendEvent(rawEventCode: 0xC10A, transactionID: transactionID)
            }
        case .endMovieRec:
            lock.lock()
            let responseCode = options.stopRecordingResponseCode
            if responseCode == 0x2001 { recording = false }
            lock.unlock()
            sendResponse(connection, code: responseCode, transactionID: transactionID)
            if responseCode == 0x2001 {
                _ = sendEvent(rawEventCode: 0xC108, transactionID: transactionID)
            }
        case .getLiveViewImageEx:
            lock.lock()
            let active = liveViewActive
            let elapsedNanos = UInt64(max(0, -liveViewEpoch.timeIntervalSinceNow) * 1e9)
            let isRecording = recording
            lock.unlock()
            guard active else {
                sendResponse(connection, code: 0x2019, transactionID: transactionID)  // busy
                return
            }
            let frameIndex = elapsedNanos / options.liveViewFrameIntervalNanoseconds
            sendDataIn(
                connection, data: liveViewObject(frameIndex: frameIndex, isRecording: isRecording),
                transactionID: transactionID)
        case .getVendorStorageIDs, .getStorageIDs:
            var payload = ByteCoding.uint32LE(UInt32(options.storageCards.count))
            for card in options.storageCards {
                payload += ByteCoding.uint32LE(card.storageID)
            }
            sendDataIn(connection, data: Data(payload), transactionID: transactionID)
        case .getStorageInfo:
            let storageID = bytes.count >= 14 ? ByteCoding.readUInt32LE(bytes, at: 10) : 0
            guard let card = options.storageCards.first(where: { $0.storageID == storageID }) else {
                // Invalid_StorageID.
                sendResponse(connection, code: 0x2008, transactionID: transactionID)
                return
            }
            sendDataIn(
                connection,
                data: storageInfoDataset(card),
                transactionID: transactionID)
        case .getObjectHandles:
            if options.disconnectsOnGetObjectHandles {
                shutdown(connection, Int32(SHUT_RDWR))
                return
            }
            let storageID = bytes.count >= 14 ? ByteCoding.readUInt32LE(bytes, at: 10) : 0
            guard options.storageCards.contains(where: { $0.storageID == storageID }) else {
                // Invalid_StorageID.
                sendResponse(connection, code: 0x2008, transactionID: transactionID)
                return
            }
            let objects = storageID == FakeZRMediaCard.storageID ? options.mediaObjects : []
            var payload = ByteCoding.uint32LE(UInt32(objects.count))
            for object in objects {
                payload += ByteCoding.uint32LE(object.handle)
            }
            sendDataIn(connection, data: Data(payload), transactionID: transactionID)
        case .getObjectInfo:
            let handle = bytes.count >= 14 ? ByteCoding.readUInt32LE(bytes, at: 10) : 0
            guard let object = options.mediaObjects.first(where: { $0.handle == handle }) else {
                // Invalid_ObjectHandle.
                sendResponse(connection, code: 0x2009, transactionID: transactionID)
                return
            }
            sendDataIn(connection, data: objectInfoDataset(object), transactionID: transactionID)
        case .getThumb:
            let handle = bytes.count >= 14 ? ByteCoding.readUInt32LE(bytes, at: 10) : 0
            guard let object = options.mediaObjects.first(where: { $0.handle == handle }),
                !object.thumbnail.isEmpty
            else {
                // No_Thumbnail_Present.
                sendResponse(connection, code: 0x2010, transactionID: transactionID)
                return
            }
            sendDataIn(connection, data: Data(object.thumbnail), transactionID: transactionID)
        case .getObjectSize:
            let handle = parameters.first ?? 0
            guard let object = options.mediaObjects.first(where: { $0.handle == handle }),
                let size = mediaObjectSize(object)
            else {
                sendResponse(connection, code: 0x2009, transactionID: transactionID)
                return
            }
            sendDataIn(
                connection, data: Data(ByteCoding.uint64LE(size)),
                transactionID: transactionID)
        case .getPartialObject:
            guard parameters.count >= 3,
                let object = options.mediaObjects.first(where: { $0.handle == parameters[0] }),
                let payload = mediaPayload(
                    object, offset: UInt64(parameters[1]), byteCount: UInt64(parameters[2]))
            else {
                sendResponse(connection, code: 0x2009, transactionID: transactionID)
                return
            }
            sendDataIn(
                connection, data: payload, transactionID: transactionID,
                responseParameters: [UInt32(payload.count)])
        case .getPartialObjectEx:
            guard parameters.count >= 5,
                let object = options.mediaObjects.first(where: { $0.handle == parameters[0] })
            else {
                sendResponse(connection, code: 0x2009, transactionID: transactionID)
                return
            }
            let offset = UInt64(parameters[1]) | UInt64(parameters[2]) << 32
            let maximumBytes = UInt64(parameters[3]) | UInt64(parameters[4]) << 32
            guard
                let payload = mediaPayload(
                    object, offset: offset, byteCount: maximumBytes)
            else {
                sendResponse(connection, code: 0x2009, transactionID: transactionID)
                return
            }
            let count = UInt64(payload.count)
            sendDataIn(
                connection, data: payload, transactionID: transactionID,
                responseParameters: [
                    UInt32(truncatingIfNeeded: count), UInt32(truncatingIfNeeded: count >> 32),
                ])
        case .getDevicePropValueEx:
            let propertyCode = bytes.count >= 14 ? ByteCoding.readUInt32LE(bytes, at: 10) : 0
            guard !options.unsupportedPropertyCodes.contains(propertyCode),
                let property = PTPPropertyCode(rawValue: propertyCode),
                let data = cameraPropertyData(for: property)
            else {
                sendResponse(connection, code: 0x2002, transactionID: transactionID)
                return
            }
            lock.lock()
            let readCount = (propertyReadCounts[propertyCode] ?? 0) + 1
            propertyReadCounts[propertyCode] = readCount
            let sendsShortPayload =
                readCount > 1 && options.shortPropertyCodesAfterFirstRead.contains(propertyCode)
            lock.unlock()
            sendDataIn(
                connection,
                data: sendsShortPayload ? Data() : data,
                transactionID: transactionID)
        case .getDevicePropDescEx:
            let propertyCode = parameters.first ?? 0
            guard !options.unsupportedPropertyCodes.contains(propertyCode),
                let property = PTPPropertyCode(rawValue: propertyCode),
                let descriptor = cameraPropertyDescriptor(for: property)
            else {
                sendResponse(connection, code: 0x2002, transactionID: transactionID)
                return
            }
            lock.lock()
            let readCount = (descriptorReadCounts[propertyCode] ?? 0) + 1
            descriptorReadCounts[propertyCode] = readCount
            let sendsMalformedPayload =
                readCount > 1
                && options.malformedDescriptorCodesAfterFirstRead.contains(propertyCode)
            lock.unlock()
            sendDataIn(
                connection,
                data: sendsMalformedPayload ? Data() : descriptor,
                transactionID: transactionID)
        case .setDevicePropValue, .setDevicePropValueEx:
            guard let property = parameters.first, let dataOut else {
                sendResponse(connection, code: 0x2005, transactionID: transactionID)
                return
            }
            lock.lock()
            propertyWriteLog.append(
                FakeZRPropertyWrite(operation: operation, property: property, data: dataOut))
            let responseCode = options.propertyWriteResponseCode
            if responseCode == PTPResponseCode.ok.rawValue,
                !options.ignoredPropertyWrites.contains(property)
            {
                applyCameraPropertyWriteLocked(property: property, data: dataOut)
            }
            lock.unlock()
            sendResponse(connection, code: responseCode, transactionID: transactionID)
        default:
            sendResponse(connection, code: 0x2005, transactionID: transactionID)
        }
    }

    /// Drains the PTP-IP host-to-camera data phase that follows a `dataOut`
    /// operation request. The production client sends `Start_Data` followed by
    /// `End_Data` for small property writes, while this fake also accepts
    /// intermediate `Data` packets so its framing stays protocol-shaped.
    private func receiveDataOut(_ connection: Int32, transactionID: UInt32) throws -> Data {
        let start = try readPacket(connection)
        guard start.type == .startData else { throw FakeZRServerError.badFrame }
        let startPayload = Array(start.payload)
        guard startPayload.count >= 12,
            ByteCoding.readUInt32LE(startPayload, at: 0) == transactionID
        else { throw FakeZRServerError.badFrame }
        let expectedLength = ByteCoding.readUInt64LE(startPayload, at: 4)

        var data = Data()
        while true {
            let packet = try readPacket(connection)
            guard packet.type == .data || packet.type == .endData else {
                throw FakeZRServerError.badFrame
            }
            let payload = Array(packet.payload)
            guard payload.count >= 4,
                ByteCoding.readUInt32LE(payload, at: 0) == transactionID
            else { throw FakeZRServerError.badFrame }
            data.append(contentsOf: payload.dropFirst(4))
            if packet.type == .endData { break }
        }
        guard UInt64(data.count) == expectedLength else { throw FakeZRServerError.badFrame }
        return data
    }

    // MARK: - Datasets

    /// Minimal standard PTP `DeviceInfo` dataset carrying the identity strings.
    private func deviceInfoDataset() -> Data {
        var bytes: [UInt8] = []
        bytes += ByteCoding.uint16LE(100)  // StandardVersion
        bytes += ByteCoding.uint32LE(0)  // VendorExtensionID
        bytes += ByteCoding.uint16LE(0)  // VendorExtensionVersion
        bytes += ptpString("")  // VendorExtensionDesc
        bytes += ByteCoding.uint16LE(0)  // FunctionalMode
        for _ in 0..<5 {  // Operations/Events/Properties/CaptureFormats/ImageFormats
            bytes += ByteCoding.uint32LE(0)
        }
        bytes += ptpString(options.manufacturer)
        bytes += ptpString(options.model)
        bytes += ptpString(options.deviceVersion)
        bytes += ptpString(options.serialNumber)
        return Data(bytes)
    }

    /// Camera property bytes used by the facade's semantic readback tests.
    ///
    /// Values deliberately exercise every decoder used by the Android monitor
    /// snapshot. They remain camera-side PTP data: Kotlin never sees them.
    private func cameraPropertyData(for property: PTPPropertyCode) -> Data? {
        lock.lock()
        let overridden = propertyValueOverrides[property.rawValue]
        let activeMovieFileTypeRaw = activeMovieFileTypeRawLocked()
        lock.unlock()
        if let overridden { return overridden }
        switch property {
        case .movieRecProhibitionCondition:
            // 0 = nothing prohibits recording.
            return Data(ByteCoding.uint32LE(0))
        case .movieISOSensitivity, .movieExposureIndex:
            return Data(ByteCoding.uint32LE(800))
        case .isoControlSensitivity:
            // Effective/working ISO (0xD0B5) — may differ from dual-base D09E under Auto.
            return Data(ByteCoding.uint32LE(800))
        case .movieISOAutoControl:
            return Data([0])  // manual ISO by default
        case .movieBaseISO:
            return Data([2])  // High
        case .exposureProgramMode:
            return Data(ByteCoding.uint16LE(1))  // M
        case .movieShutterMode:
            return Data([2])  // angle
        case .movieTVLockSetting:
            return Data([0])
        case .movieShutterAngle:
            return Data(ByteCoding.uint32LE(18_000))  // 180°
        case .movieShutterSpeed:
            return Data(ByteCoding.uint32LE(0x0001_0032))  // 1/50
        case .movieFNumber:
            return Data(ByteCoding.uint16LE(280))  // f/2.8
        case .movieWhiteBalance:
            return Data(ByteCoding.uint16LE(0x8012))  // Color temp
        case .movieWBColorTemp:
            return Data(ByteCoding.uint16LE(UInt16(WhiteBalanceKelvinPolicy.defaultKelvin)))
        case .movieRecordScreenSize:
            let raw =
                options.screenSizeModesByFileType[activeMovieFileTypeRaw]?.first
                ?? options.movieRecordScreenSizeRaw
            return Data(ByteCoding.uint64LE(raw))
        case .movieFileType:
            return Data(ByteCoding.uint32LE(activeMovieFileTypeRaw))
        case .batteryLevel:
            return Data([options.batteryPercent])
        case .acPower:
            return Data([1])
        case .warningStatus:
            return Data([0])
        case .focalLength:
            return Data(ByteCoding.uint32LE(2_400))
        case .lensFocalMin:
            return Data(ByteCoding.uint32LE(2_400))
        case .lensFocalMax:
            return Data(ByteCoding.uint32LE(7_000))
        case .lensApertureMin:
            return Data(ByteCoding.uint16LE(280))
        case .movieFocusMode:
            lock.lock()
            defer { lock.unlock() }
            return Data([focusModeRaw])
        case .movieFocusMeteringMode:
            lock.lock()
            defer { lock.unlock() }
            return Data(ByteCoding.uint16LE(focusAreaRaw))
        case .movieAFSubjectDetection:
            lock.lock()
            defer { lock.unlock() }
            return Data([focusSubjectRaw])
        case .movMicrophone:
            return Data([0])  // Auto
        case .movRecordMicrophoneLevelValue:
            return Data([12])
        case .movWindNoiseReduction:
            return Data([1])
        case .movieAttenuator:
            return Data([0])
        case .audioInputSelection:
            return Data([2])  // Line
        case .movieAudioInputSensitivity:
            return Data([0xFF])  // Auto
        case .movie32BitFloatAudioRecording:
            return Data([1])
        case .gridDisplay:
            return Data([1])
        case .movieVibrationReduction:
            return Data([2])  // SPORT
        case .electronicVR:
            return Data([1])
        case .movieWbTuneAuto, .movieWbTuneIncandescent, .movieWbTuneFluorescent,
            .movieWbTuneSunny, .movieWbTuneCloudy, .movieWbTuneShade,
            .movieWbTuneColorTemp, .movieWbTuneNatural:
            return Data(ByteCoding.uint16LE(612))
        case .liveViewSelector:
            // 1 = video (cinema monitor default for facade tests).
            return Data([1])
        case .stillCaptureMode:
            return Data(ByteCoding.uint16LE(0x0001))  // Single
        case .stillShutterSpeed:
            return Data(ByteCoding.uint32LE(0x0001_0032))  // 1/50, fraction-packed
        case .fNumber:
            return Data(ByteCoding.uint16LE(280))  // f/2.8
        case .focusMode:
            return Data(ByteCoding.uint16LE(0x8010))  // AF-S in the 0x500A space
        case .stillFocusMode:
            return Data([0])  // AF-S in the 0xD061 UINT8 space
        case .flashMode:
            return Data(ByteCoding.uint16LE(0x0002))  // Off
        case .exposureMeteringMode:
            return Data(ByteCoding.uint16LE(0x0003))  // Matrix
        case .stillFocusMeteringMode:
            return Data(ByteCoding.uint16LE(0x8010))  // Single-point
        case .compressionSetting, .imageSize:
            return Data([0])
        case .stillISOAutoControl:
            return Data([0])
        case .exposureBiasCompensation:
            return Data(ByteCoding.uint16LE(0))
        case .whiteBalance:
            return Data(ByteCoding.uint16LE(0x0002))
        default:
            return nil
        }
    }

    /// Protocol-shaped descriptor datasets consumed only by shared-core decoders.
    private func cameraPropertyDescriptor(for property: PTPPropertyCode) -> Data? {
        if property == .movieRecordScreenSize,
            let modes = screenSizeModesForActiveFileType(),
            !modes.isEmpty
        {
            return enumDescriptor(
                property: property,
                valueByteCount: 8,
                values: modes.map(ByteCoding.uint64LE))
        }
        if let values = options.descriptorEnumOverrides[property],
            let byteCount = descriptorValueByteCount(property)
        {
            return enumDescriptor(
                property: property,
                valueByteCount: byteCount,
                values: values.map { descriptorBytes($0, byteCount: byteCount) })
        }
        switch property {
        case .movieRecordScreenSize:
            return enumDescriptor(
                property: property,
                valueByteCount: 8,
                values: [
                    ByteCoding.uint64LE(0x1770_0D08_0019_0000),
                    ByteCoding.uint64LE(0x0F00_0870_003C_0000),
                ])
        case .movieFileType:
            return enumDescriptor(
                property: property,
                valueByteCount: 4,
                values: [
                    ByteCoding.uint32LE(0x0031_0A03),
                    ByteCoding.uint32LE(0x0001_0A01),
                ])
        case .movieFNumber:
            return enumDescriptor(
                property: property,
                valueByteCount: 2,
                values: [280, 400, 560, 800, 1_100, 1_600, 2_200].map(ByteCoding.uint16LE))
        case .movieWBColorTemp:
            // Nikon K [Choose color temperature] discrete steps (2500–10000 K).
            return enumDescriptor(
                property: property,
                valueByteCount: 2,
                values: WhiteBalanceKelvinPolicy.kelvinSteps.map {
                    ByteCoding.uint16LE(UInt16($0))
                })
        case .movieWhiteBalance:
            return enumDescriptor(
                property: property,
                valueByteCount: 2,
                values: [
                    0x0002, 0x8016, 0x0004, 0x8010, 0x8011, 0x0006, 0x0005, 0x0007,
                    0x8013, 0x8012,
                ].map(ByteCoding.uint16LE))
        case .movieFocusMode:
            return enumDescriptor(
                property: property, valueByteCount: 1, values: [[0], [1], [2], [4]])
        case .movieFocusMeteringMode:
            return enumDescriptor(
                property: property,
                valueByteCount: 2,
                values: [0x8010, 0x8011, 0x8018, 0x8019, 0x8033].map(ByteCoding.uint16LE))
        case .movieAFSubjectDetection:
            return enumDescriptor(
                property: property,
                valueByteCount: 1,
                values: (0...6).map { [UInt8($0)] })
        case .movieAudioInputSensitivity:
            return enumDescriptor(
                property: property,
                valueByteCount: 1,
                values: [[0xFF]] + (1...20).map { [UInt8($0)] })
        case .audioInputSelection:
            return enumDescriptor(property: property, valueByteCount: 1, values: [[1], [2]])
        case .movWindNoiseReduction, .movieAttenuator, .movie32BitFloatAudioRecording:
            return enumDescriptor(property: property, valueByteCount: 1, values: [[0], [1]])
        case .movieShutterAngle:
            return enumDescriptor(
                property: property,
                valueByteCount: 4,
                values: [9_000, 18_000, 36_000].map(ByteCoding.uint32LE))
        case .movieShutterSpeed:
            return enumDescriptor(
                property: property,
                valueByteCount: 4,
                values: [25, 50, 100].map { ByteCoding.uint32LE(0x0001_0000 | UInt32($0)) })
        case .movieBaseISO:
            return enumDescriptor(property: property, valueByteCount: 1, values: [[1], [2]])
        case .movieISOAutoControl:
            return enumDescriptor(property: property, valueByteCount: 1, values: [[0], [1]])
        case .movieShutterMode:
            return enumDescriptor(property: property, valueByteCount: 1, values: [[1], [2]])
        case .movieTVLockSetting:
            return enumDescriptor(property: property, valueByteCount: 1, values: [[0], [1]])
        case .movieVibrationReduction:
            return enumDescriptor(property: property, valueByteCount: 1, values: [[0], [1], [2]])
        case .electronicVR:
            return enumDescriptor(property: property, valueByteCount: 1, values: [[0], [1]])
        case .movieWbTuneAuto, .movieWbTuneIncandescent, .movieWbTuneFluorescent,
            .movieWbTuneSunny, .movieWbTuneCloudy, .movieWbTuneShade,
            .movieWbTuneColorTemp, .movieWbTuneNatural:
            return rangeDescriptor(property: property, valueByteCount: 2)
        default:
            return nil
        }
    }

    private func screenSizeModesForActiveFileType() -> [UInt64]? {
        lock.lock()
        defer { lock.unlock() }
        return options.screenSizeModesByFileType[activeMovieFileTypeRawLocked()]
    }

    private func activeMovieFileTypeRawLocked() -> UInt32 {
        guard let data = propertyValueOverrides[PTPPropertyCode.movieFileType.rawValue],
            data.count >= MemoryLayout<UInt32>.size
        else {
            return options.movieFileTypeRaw
        }
        return ByteCoding.readUInt32LE(Array(data), at: 0)
    }

    private func descriptorValueByteCount(_ property: PTPPropertyCode) -> Int? {
        switch property {
        case .movieFNumber, .movieWBColorTemp, .movieWhiteBalance,
            .movieFocusMeteringMode:
            2
        case .movieFocusMode, .movieAFSubjectDetection, .movieAudioInputSensitivity,
            .audioInputSelection, .movWindNoiseReduction, .movieAttenuator,
            .movie32BitFloatAudioRecording, .movieBaseISO, .movieShutterMode,
            .movieTVLockSetting, .movieVibrationReduction, .electronicVR:
            1
        case .movieFileType, .movieShutterAngle, .movieShutterSpeed:
            4
        default:
            nil
        }
    }

    private func descriptorBytes(_ value: UInt32, byteCount: Int) -> [UInt8] {
        switch byteCount {
        case 1: [UInt8(truncatingIfNeeded: value)]
        case 2: ByteCoding.uint16LE(UInt16(truncatingIfNeeded: value))
        default: ByteCoding.uint32LE(value)
        }
    }

    private func enumDescriptor(
        property: PTPPropertyCode,
        valueByteCount: Int,
        values: [[UInt8]]
    ) -> Data {
        var bytes = ByteCoding.uint32LE(
            options.descriptorIdentityOverrides[property.rawValue] ?? property.rawValue)
        bytes += ByteCoding.uint16LE(
            options.descriptorDataTypeOverrides[property.rawValue]
                ?? unsignedDataType(for: valueByteCount))
        bytes.append(options.readOnlyDescriptorCodes.contains(property.rawValue) ? 0 : 1)
        bytes += [UInt8](repeating: 0, count: valueByteCount * 2)
        bytes.append(2)  // Enumeration form
        bytes += ByteCoding.uint16LE(UInt16(values.count))
        for value in values {
            bytes += value
        }
        return Data(bytes)
    }

    private func rangeDescriptor(property: PTPPropertyCode, valueByteCount: Int) -> Data {
        var bytes = ByteCoding.uint32LE(
            options.descriptorIdentityOverrides[property.rawValue] ?? property.rawValue)
        bytes += ByteCoding.uint16LE(
            options.descriptorDataTypeOverrides[property.rawValue]
                ?? unsignedDataType(for: valueByteCount))
        bytes.append(options.readOnlyDescriptorCodes.contains(property.rawValue) ? 0 : 1)
        bytes += [UInt8](repeating: 0, count: valueByteCount * 2)
        bytes.append(1)  // Range form; the facade uses shared WhiteBalanceTint grid policy.
        bytes += ByteCoding.uint16LE(options.whiteBalanceTintMinimum)
        bytes += ByteCoding.uint16LE(options.whiteBalanceTintMaximum)
        bytes += ByteCoding.uint16LE(options.whiteBalanceTintStep)
        return Data(bytes)
    }

    private func unsignedDataType(for valueByteCount: Int) -> UInt16 {
        switch valueByteCount {
        case 1: 0x0002
        case 2: 0x0004
        case 4: 0x0006
        case 8: 0x0008
        default: 0
        }
    }

    /// Minimal PIMA `StorageInfo` record: three UINT16 headers followed by
    /// total/free UINT64 values. The parser needs only the first 22 bytes.
    private func storageInfoDataset(_ card: FakeZRStorageCard) -> Data {
        var bytes = [UInt8](repeating: 0, count: 6)
        bytes += ByteCoding.uint64LE(card.totalCapacityBytes)
        bytes += ByteCoding.uint64LE(card.freeSpaceBytes)
        return Data(bytes)
    }

    /// Synthesized Nikon LiveViewObject: the 1024-byte display-info header
    /// followed by a tiny real color-bars JPEG (decodable by any consumer,
    /// including Android's `BitmapFactory` in the on-device end-to-end).
    ///
    /// The header carries only what the facade parses today: the declared
    /// JPEG length at offset 12 and the timecode block — with `frameIndex`
    /// encoded base-256 across the hour/minute/second/frame bytes as a
    /// test-only frame counter (see `frameCounter(of:)`). The JPEG variant
    /// alternates every 25 frames so a watching human sees the stream move.
    private func liveViewObject(frameIndex: UInt64, isRecording: Bool) -> Data {
        let jpeg =
            (frameIndex / 25).isMultiple(of: 2)
            ? FakeZRLiveViewFrames.colorBarsJPEG
            : FakeZRLiveViewFrames.colorBarsMarkerJPEG
        var header = [UInt8](repeating: 0, count: 1024)
        header.replaceSubrange(12..<16, with: ByteCoding.uint32LE(UInt32(jpeg.count)))
        applyFocusHeader(to: &header, frameIndex: frameIndex)
        header[831] = 1  // timecode on
        header[832] = UInt8((frameIndex >> 24) & 0xFF)
        header[833] = UInt8((frameIndex >> 16) & 0xFF)
        header[834] = UInt8((frameIndex >> 8) & 0xFF)
        header[835] = UInt8(frameIndex & 0xFF)
        header[828] = isRecording ? 1 : 0
        return Data(header + jpeg)
    }

    private func applyFocusHeader(to header: inout [UInt8], frameIndex: UInt64) {
        guard options.focusMetadataEnabled else { return }
        lock.lock()
        if let release = focusReleaseAtFrame, frameIndex >= release {
            focusTrackingAFActive = false
            focusReleaseAtFrame = nil
            focusHasReleased = true
        }
        let centerX = focusCenterX
        let centerY = focusCenterY
        let tracking = focusTrackingAFActive
        let subject = focusSubjectDetectionActive
        let released = focusHasReleased
        lock.unlock()

        if released && options.focusMetadataDisappearsAfterRelease { return }

        func writeBE(_ value: UInt16, at offset: Int) {
            header[offset] = UInt8(value >> 8)
            header[offset + 1] = UInt8(value & 0xFF)
        }
        writeBE(options.focusCoordinateWidth, at: 16)
        writeBE(options.focusCoordinateHeight, at: 18)
        header[42] = 2
        header[43] = subject ? 1 : 0
        header[44] = subject ? 2 : 1
        header[45] = subject ? 1 : 0
        header[46] = tracking ? 1 : 0
        if !released || !options.focusBoxesDisappearAfterRelease {
            writeBE(720, at: 48)
            writeBE(480, at: 50)
            writeBE(centerX, at: 52)
            writeBE(centerY, at: 54)
        }
        if subject && (!released || !options.focusBoxesDisappearAfterRelease) {
            writeBE(900, at: 56)
            writeBE(1_100, at: 58)
            writeBE(centerX, at: 60)
            writeBE(centerY, at: 62)
        }
    }

    private func currentLiveViewFrameIndexLocked() -> UInt64 {
        let elapsedNanos = UInt64(max(0, -liveViewEpoch.timeIntervalSinceNow) * 1e9)
        return elapsedNanos / options.liveViewFrameIntervalNanoseconds
    }

    private func applyCameraPropertyWriteLocked(property: UInt32, data: Data) {
        let bytes = Array(data)
        propertyValueOverrides[property] = data
        switch PTPPropertyCode(rawValue: property) {
        case .movieFileType where bytes.count >= MemoryLayout<UInt32>.size:
            updateCameraMovieFileTypeLocked(ByteCoding.readUInt32LE(bytes, at: 0))
        case .movieFocusMode where !bytes.isEmpty:
            focusModeRaw = bytes[0]
        case .movieFocusMeteringMode where bytes.count >= 2:
            focusAreaRaw = ByteCoding.readUInt16LE(bytes, at: 0)
        case .movieAFSubjectDetection where !bytes.isEmpty:
            focusSubjectRaw = bytes[0]
            focusSubjectDetectionActive = bytes[0] != 0
        default:
            break
        }
    }

    private func updateCameraMovieFileTypeLocked(_ raw: UInt32) {
        propertyValueOverrides[PTPPropertyCode.movieFileType.rawValue] = Data(
            ByteCoding.uint32LE(raw))
        if options.screenSizeModesByFileType[raw] != nil {
            propertyValueOverrides[PTPPropertyCode.movieRecordScreenSize.rawValue] = nil
        }
    }

    /// Standard PTP `ObjectInfo` dataset (PIMA 15740 §5.3.1): the 52-byte
    /// fixed prefix, then filename / capture date / modification date /
    /// keywords strings — the layout `PTPObjectInfo` decodes.
    private func objectInfoDataset(_ object: FakeZRMediaObject) -> Data {
        var bytes: [UInt8] = []
        bytes += ByteCoding.uint32LE(FakeZRMediaCard.storageID)  // @0  StorageID
        bytes += ByteCoding.uint16LE(object.objectFormat)  // @4  ObjectFormat
        bytes += ByteCoding.uint16LE(0)  // @6  ProtectionStatus
        let size = mediaObjectSize(object) ?? object.resolvedSizeBytes
        let reportedSize = size >= UInt64(UInt32.max) ? UInt32.max : UInt32(size)
        bytes += ByteCoding.uint32LE(reportedSize)  // @8  ObjectCompressedSize
        bytes += ByteCoding.uint16LE(0x3801)  // @12 ThumbFormat (EXIF JPEG)
        bytes += ByteCoding.uint32LE(UInt32(object.thumbnail.count))  // @14 ThumbCompressedSize
        bytes += ByteCoding.uint32LE(160)  // @18 ThumbPixWidth
        bytes += ByteCoding.uint32LE(90)  // @22 ThumbPixHeight
        bytes += ByteCoding.uint32LE(object.pixelWidth)  // @26 ImagePixWidth
        bytes += ByteCoding.uint32LE(object.pixelHeight)  // @30 ImagePixHeight
        bytes += ByteCoding.uint32LE(0)  // @34 ImageBitDepth
        bytes += ByteCoding.uint32LE(0)  // @38 ParentObject
        bytes += ByteCoding.uint16LE(0)  // @42 AssociationType
        bytes += ByteCoding.uint32LE(0)  // @44 AssociationDesc
        bytes += ByteCoding.uint32LE(0)  // @48 SequenceNumber
        bytes += ptpString(object.filename)
        bytes += ptpString(object.captureDate)
        bytes += ptpString("")  // ModificationDate
        bytes += ptpString("")  // Keywords
        return Data(bytes)
    }

    /// PTP string: UINT8 code-unit count (including trailing NUL) + UTF-16LE units.
    private func ptpString(_ value: String) -> [UInt8] {
        guard !value.isEmpty else { return [0] }
        var units: [UInt8] = []
        for codeUnit in value.utf16 {
            units += ByteCoding.uint16LE(codeUnit)
        }
        units += [0, 0]
        return [UInt8(units.count / 2)] + units
    }

    private func mediaObjectSize(_ object: FakeZRMediaObject) -> UInt64? {
        guard object.handle == options.mediaPayloadHandle,
            let url = options.mediaPayloadFileURL
        else { return object.resolvedSizeBytes }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            let fileSize = attributes[.size] as? NSNumber
        else { return nil }
        return fileSize.uint64Value
    }

    /// Reads only the requested range. Synthetic large objects generate their
    /// bytes on demand, so a >=4 GiB protocol test never allocates the object.
    private func mediaPayload(
        _ object: FakeZRMediaObject, offset: UInt64, byteCount: UInt64
    ) -> Data? {
        guard let totalBytes = mediaObjectSize(object), offset <= totalBytes else { return nil }
        let count = min(byteCount, totalBytes - offset)
        guard count <= UInt64(Int.max) else { return nil }

        if object.handle == options.mediaPayloadHandle,
            let url = options.mediaPayloadFileURL,
            let file = try? FileHandle(forReadingFrom: url)
        {
            defer { try? file.close() }
            do {
                try file.seek(toOffset: offset)
                return try file.read(upToCount: Int(count)) ?? Data()
            } catch {
                return nil
            }
        }
        if let payload = object.payload {
            guard offset <= UInt64(payload.count) else { return nil }
            let start = Int(offset)
            let end = min(payload.count, start + Int(count))
            return payload.subdata(in: start..<end)
        }
        return Data(
            (0..<Int(count)).map { index in
                UInt8(truncatingIfNeeded: offset + UInt64(index) + UInt64(object.handle))
            })
    }

    // MARK: - Framing

    private func registerEventConnection(_ connection: Int32) {
        eventConnectionCondition.lock()
        eventConnection = connection
        eventConnectionCondition.broadcast()
        eventConnectionCondition.unlock()
    }

    private func unregisterEventConnection(_ connection: Int32) {
        eventConnectionCondition.lock()
        if eventConnection == connection { eventConnection = -1 }
        eventConnectionCondition.broadcast()
        eventConnectionCondition.unlock()
    }

    private func sendResponse(
        _ connection: Int32, code: UInt16, transactionID: UInt32,
        parameters: [UInt32] = []
    ) {
        var payload = ByteCoding.uint16LE(code) + ByteCoding.uint32LE(transactionID)
        for parameter in parameters { payload += ByteCoding.uint32LE(parameter) }
        send(connection, PTPIPPacket(type: .operationResponse, payload: Data(payload)))
    }

    private func sendDataIn(
        _ connection: Int32, data: Data, transactionID: UInt32, code: UInt16 = 0x2001,
        responseParameters: [UInt32] = []
    ) {
        send(
            connection,
            PTPIPPacket(
                type: .startData,
                payload: Data(
                    PTPDataPayloads.startData(
                        transactionID: transactionID, totalLength: UInt64(data.count)))))
        send(
            connection,
            PTPIPPacket(
                type: .endData,
                payload: Data(PTPDataPayloads.endData(transactionID: transactionID, data: data))))
        sendResponse(
            connection, code: code, transactionID: transactionID,
            parameters: responseParameters)
    }

    private func send(_ connection: Int32, _ packet: PTPIPPacket) {
        let data = Data(packet.serializedBytes)
        #if canImport(Darwin)
            let flags: Int32 = 0
        #else
            let flags = Int32(MSG_NOSIGNAL)
        #endif
        data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < data.count {
                let sent = platformSend(connection, base + offset, data.count - offset, flags)
                guard sent > 0 else { return }
                offset += sent
            }
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

    private func readPacket(_ connection: Int32) throws -> PTPIPPacket {
        let header = try readExact(connection, byteCount: 8)
        let length = Int(ByteCoding.readUInt32LE(header, at: 0))
        guard length >= 8, length <= 1024 * 1024 else { throw FakeZRServerError.badFrame }
        let payload = try readExact(connection, byteCount: length - 8)
        return try PTPIPPacket(serializedBytes: header + payload)
    }

    private func readExact(_ connection: Int32, byteCount: Int) throws -> [UInt8] {
        var collected: [UInt8] = []
        collected.reserveCapacity(byteCount)
        while collected.count < byteCount {
            var chunk = [UInt8](repeating: 0, count: byteCount - collected.count)
            let received = chunk.withUnsafeMutableBytes { rawBuffer in
                recv(connection, rawBuffer.baseAddress, rawBuffer.count, 0)
            }
            guard received > 0 else { throw FakeZRServerError.connectionClosed }
            collected += chunk.prefix(received)
        }
        return collected
    }
}

enum FakeZRServerError: Error {
    case socketFailed
    case bindFailed
    case badFrame
    case connectionClosed
}

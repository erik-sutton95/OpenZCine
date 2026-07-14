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

/// A scripted fake ZR listening on an ephemeral localhost port.
// SAFETY: `@unchecked Sendable` — mutable state is guarded by `lock`; each
// accepted connection runs on its own thread.
final class FakeZRServer: @unchecked Sendable {
    struct Options {
        /// When false, `ChangeApplicationMode` is refused until the pairing
        /// sequence (`GetPairingInfo` + `ConfirmPairing`) completes — the
        /// first-time-pairing camera behavior.
        var acceptsAppControlImmediately = true
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
        var cameraName = "ZR_6001234"
        var pairingPIN = "1234"
        var batteryPercent: UInt8 = 80
        var manufacturer = "Nikon Corporation"
        var model = "ZR"
        var deviceVersion = "01.00"
        var serialNumber = "6001234"
    }

    let port: UInt16

    private let options: Options
    private let listenDescriptor: Int32
    private let lock = NSLock()
    private var operationLog: [PTPOperationCode] = []
    private var transactionIDLog: [UInt32] = []
    private var pairingConfirmed = false
    private var stopped = false
    private var liveViewActive = false
    private var liveViewEpoch = Date()

    init(options: Options = Options()) throws {
        self.options = options

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
        stopped = true
        lock.unlock()
        shutdown(listenDescriptor, Int32(SHUT_RDWR))
        close(listenDescriptor)
    }

    /// Every PTP operation received, in arrival order, across all connections.
    func receivedOperations() -> [PTPOperationCode] {
        lock.lock()
        defer { lock.unlock() }
        return operationLog
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

    /// Reconstructs the served frame counter from a delivered frame's header
    /// timecode (the base-256 encoding `liveViewObject` writes).
    static func frameCounter(of timecode: Timecode) -> Int {
        ((timecode.hour * 256 + timecode.minute) * 256 + timecode.second) * 256 + timecode.frame
    }

    // MARK: - Connection handling

    private func acceptLoop() {
        while true {
            let connection = accept(listenDescriptor, nil, nil)
            guard connection >= 0 else { return }
            Thread.detachNewThread { [weak self] in self?.serve(connection) }
        }
    }

    private func serve(_ connection: Int32) {
        defer { close(connection) }
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
                send(connection, PTPIPPacket(type: .initEventAck, payload: Data()))
            case .operationRequest:
                respond(connection, requestPayload: Array(packet.payload))
            default:
                return
            }
        }
    }

    private func respond(_ connection: Int32, requestPayload bytes: [UInt8]) {
        guard bytes.count >= 10 else { return }
        let rawOperation = ByteCoding.readUInt16LE(bytes, at: 4)
        let transactionID = ByteCoding.readUInt32LE(bytes, at: 6)
        guard let operation = PTPOperationCode(rawValue: rawOperation) else {
            sendResponse(connection, code: 0x2005, transactionID: transactionID)
            return
        }
        lock.lock()
        operationLog.append(operation)
        transactionIDLog.append(transactionID)
        lock.unlock()

        switch operation {
        case .openSession, .closeSession:
            sendResponse(connection, code: 0x2001, transactionID: transactionID)
        case .changeApplicationMode:
            lock.lock()
            let accepted = options.acceptsAppControlImmediately || pairingConfirmed
            lock.unlock()
            sendResponse(
                connection, code: accepted ? 0x2001 : 0x2002, transactionID: transactionID)
        case .getPairingInfo:
            sendDataIn(
                connection, data: Data(options.pairingPIN.utf8), transactionID: transactionID)
        case .confirmPairing:
            lock.lock()
            pairingConfirmed = true
            lock.unlock()
            sendResponse(connection, code: 0x2001, transactionID: transactionID)
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
        case .endLiveView:
            lock.lock()
            liveViewActive = false
            lock.unlock()
            sendResponse(connection, code: 0x2001, transactionID: transactionID)
        case .getLiveViewImageEx:
            lock.lock()
            let active = liveViewActive
            let elapsedNanos = UInt64(max(0, -liveViewEpoch.timeIntervalSinceNow) * 1e9)
            lock.unlock()
            guard active else {
                sendResponse(connection, code: 0x2019, transactionID: transactionID)  // busy
                return
            }
            let frameIndex = elapsedNanos / options.liveViewFrameIntervalNanoseconds
            sendDataIn(
                connection, data: liveViewObject(frameIndex: frameIndex),
                transactionID: transactionID)
        case .getVendorStorageIDs, .getStorageIDs:
            // One valid volume (both ops report the same card, like a
            // single-card body).
            let payload = ByteCoding.uint32LE(1) + ByteCoding.uint32LE(FakeZRMediaCard.storageID)
            sendDataIn(connection, data: Data(payload), transactionID: transactionID)
        case .getObjectHandles:
            let storageID = bytes.count >= 14 ? ByteCoding.readUInt32LE(bytes, at: 10) : 0
            guard storageID == FakeZRMediaCard.storageID else {
                // Invalid_StorageID.
                sendResponse(connection, code: 0x2008, transactionID: transactionID)
                return
            }
            var payload = ByteCoding.uint32LE(UInt32(options.mediaObjects.count))
            for object in options.mediaObjects {
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
        case .getDevicePropValueEx:
            let propertyCode = bytes.count >= 14 ? ByteCoding.readUInt32LE(bytes, at: 10) : 0
            switch PTPPropertyCode(rawValue: propertyCode) {
            case .batteryLevel:
                sendDataIn(
                    connection, data: Data([options.batteryPercent]),
                    transactionID: transactionID)
            case .movieRecProhibitionCondition:
                // 0 = nothing prohibits recording.
                sendDataIn(
                    connection, data: Data(ByteCoding.uint32LE(0)), transactionID: transactionID)
            default:
                sendResponse(connection, code: 0x2002, transactionID: transactionID)
            }
        default:
            sendResponse(connection, code: 0x2005, transactionID: transactionID)
        }
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

    /// Synthesized Nikon LiveViewObject: the 1024-byte display-info header
    /// followed by a tiny real color-bars JPEG (decodable by any consumer,
    /// including Android's `BitmapFactory` in the on-device end-to-end).
    ///
    /// The header carries only what the facade parses today: the declared
    /// JPEG length at offset 12 and the timecode block — with `frameIndex`
    /// encoded base-256 across the hour/minute/second/frame bytes as a
    /// test-only frame counter (see `frameCounter(of:)`). The JPEG variant
    /// alternates every 25 frames so a watching human sees the stream move.
    private func liveViewObject(frameIndex: UInt64) -> Data {
        let jpeg =
            (frameIndex / 25).isMultiple(of: 2)
            ? FakeZRLiveViewFrames.colorBarsJPEG
            : FakeZRLiveViewFrames.colorBarsMarkerJPEG
        var header = [UInt8](repeating: 0, count: 1024)
        header.replaceSubrange(12..<16, with: ByteCoding.uint32LE(UInt32(jpeg.count)))
        header[831] = 1  // timecode on
        header[832] = UInt8((frameIndex >> 24) & 0xFF)
        header[833] = UInt8((frameIndex >> 16) & 0xFF)
        header[834] = UInt8((frameIndex >> 8) & 0xFF)
        header[835] = UInt8(frameIndex & 0xFF)
        return Data(header + jpeg)
    }

    /// Standard PTP `ObjectInfo` dataset (PIMA 15740 §5.3.1): the 52-byte
    /// fixed prefix, then filename / capture date / modification date /
    /// keywords strings — the layout `PTPObjectInfo` decodes.
    private func objectInfoDataset(_ object: FakeZRMediaObject) -> Data {
        var bytes: [UInt8] = []
        bytes += ByteCoding.uint32LE(FakeZRMediaCard.storageID)  // @0  StorageID
        bytes += ByteCoding.uint16LE(object.objectFormat)  // @4  ObjectFormat
        bytes += ByteCoding.uint16LE(0)  // @6  ProtectionStatus
        bytes += ByteCoding.uint32LE(object.sizeBytes)  // @8  ObjectCompressedSize
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

    // MARK: - Framing

    private func sendResponse(_ connection: Int32, code: UInt16, transactionID: UInt32) {
        let payload = ByteCoding.uint16LE(code) + ByteCoding.uint32LE(transactionID)
        send(connection, PTPIPPacket(type: .operationResponse, payload: Data(payload)))
    }

    private func sendDataIn(
        _ connection: Int32, data: Data, transactionID: UInt32, code: UInt16 = 0x2001
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
        sendResponse(connection, code: code, transactionID: transactionID)
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

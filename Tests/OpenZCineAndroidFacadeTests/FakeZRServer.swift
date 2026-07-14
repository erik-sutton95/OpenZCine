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
        address.sin_port = 0  // ephemeral
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

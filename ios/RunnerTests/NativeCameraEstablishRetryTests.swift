import Foundation
import Testing

@testable import Runner

@Suite("One-shot in-place establish retry policy")
struct NativeCameraEstablishRetryTests {

    // Erik's field failure: camera-AP endpoint not ready right after the Wi-Fi join —
    // the TCP connect (or first handshake read) fails, an immediate manual retry works.
    @Test("Transient link failures on a non-pairing attempt are retryable")
    func transientFailuresRetry() {
        let transientErrors: [NativeCameraSessionError] = [
            .connectionFailed("connect refused"),
            .connectionClosed,
            .timeout("Init handshake"),
            .unexpectedPacket(expected: "InitCommandAck", actual: .initFail),
            .invalidPacketLength(3),
            .operationRejected(.openSession, .deviceBusy),
        ]
        for error in transientErrors {
            #expect(
                NativeCameraSession.isRetryableEstablishFailure(error, requestPairing: false),
                "expected retryable: \(error)"
            )
        }
    }

    @Test("Init_Fail busy (stale session slot) is retryable, rejected initiator is not")
    func initFailReasonsSplit() {
        // Busy is excluded from the generic 1 s in-place retry: the body TOLD us another
        // initiator holds it, and hammering a session slot mid-handoff wedges the body
        // (audit M5, the two-device brick). It gets its own single retry after a 5 s
        // handoff settle in the connect flow instead.
        #expect(
            !NativeCameraSession.isRetryableEstablishFailure(
                NativeCameraSessionError.initFailed(.busy), requestPairing: false
            )
        )
        #expect(
            NativeCameraSession.isBusyEstablishFailure(
                NativeCameraSessionError.initFailed(.busy))
        )
        #expect(
            !NativeCameraSession.isBusyEstablishFailure(
                NativeCameraSessionError.initFailed(.unspecified))
        )
        #expect(
            NativeCameraSession.isRetryableEstablishFailure(
                NativeCameraSessionError.initFailed(.unspecified), requestPairing: false
            )
        )
        // The camera actively refused this phone's GUID — the call site has a dedicated
        // "create a Connect to PC profile" recovery path a silent retry would only delay.
        #expect(
            !NativeCameraSession.isRetryableEstablishFailure(
                NativeCameraSessionError.initFailed(.rejectedInitiator), requestPairing: false
            )
        )
    }

    @Test("Failures with their own fallback or UX are never retried")
    func nonTransientFailuresDoNotRetry() {
        let handledElsewhere: [NativeCameraSessionError] = [
            .savedProfileRequired,
            .pairingRejected,
            .pairingChallengeUnavailable,
            .localNetworkPermissionDenied,
            .noHost,
        ]
        for error in handledElsewhere {
            #expect(
                !NativeCameraSession.isRetryableEstablishFailure(error, requestPairing: false),
                "expected not retryable: \(error)"
            )
        }
    }

    // ZR pairing-probe rule: a body sitting on its pairing wizard must never be re-probed —
    // attempt 1 may have knocked it out of pairing mode, and a retry re-fires camera-side
    // pairing prompts. Pairing attempts fail straight through to the operator.
    @Test("No failure is retryable while a pairing handshake was requested")
    func pairingAttemptsNeverRetry() {
        #expect(
            !NativeCameraSession.isRetryableEstablishFailure(
                NativeCameraSessionError.connectionFailed("connect refused"), requestPairing: true
            )
        )
        #expect(
            !NativeCameraSession.isRetryableEstablishFailure(
                NativeCameraSessionError.initFailed(.busy), requestPairing: true
            )
        )
    }

    @Test("Cancellation is never retried")
    func cancellationDoesNotRetry() {
        #expect(
            !NativeCameraSession.isRetryableEstablishFailure(
                CancellationError(), requestPairing: false
            )
        )
    }

    @Test("Raw socket-layer errors (not session errors) are treated as transient")
    func unknownErrorsRetry() {
        let posixError = NSError(domain: NSPOSIXErrorDomain, code: 61)  // ECONNREFUSED
        #expect(
            NativeCameraSession.isRetryableEstablishFailure(posixError, requestPairing: false)
        )
    }
}

/// USB establish over a scripted transport — ICC has already opened the PTP session
/// (`USBCameraTransport.open` returns only after `hasOpenSession`).
@Suite("USB establish after ICC session open")
struct USBEstablishSequenceTests {
    @Test("A successful in-session GetDeviceInfo skips a second PTP OpenSession")
    func skipRedundantOpenSession() async throws {
        let transport = ScriptedUSBTransport { operation, transactionID in
            #expect(operation != .openSession, "ICC already opened the session")
            if operation == .getDeviceInfo {
                #expect(transactionID == nil, "in-session GetDeviceInfo must not reuse TID 0")
                return try usbOK(data: zrDeviceInfoBytes())
            }
            return try usbOK()
        }

        let session = try await NativeCameraSession.establish(
            transport: transport,
            host: "usb:zr-handshake-tests",
            cameraName: "Nikon ZR",
            requestPairing: false
        )

        #expect(session.transportKind == .usb)
        #expect(!transport.operations.contains(.openSession))
        #expect(transport.operations.contains(.getDeviceInfo))
        transport.close()
    }

    @Test("A failed USB probe still sends OpenSession and reports that stage")
    func failedProbeStillOpensSession() async {
        let transport = ScriptedUSBTransport { operation, _ in
            if operation == .openSession {
                throw NativeCameraSessionError.connectionFailed(
                    "The operation couldn’t be completed. (com.apple.ImageCaptureCore error -21400.)"
                )
            }
            throw NativeCameraSessionError.connectionFailed("probe failed")
        }
        let stages = StageLog()

        await #expect(throws: NativeCameraSessionError.self) {
            _ = try await NativeCameraSession.establish(
                transport: transport,
                host: "usb:zr-handshake-tests",
                cameraName: "Nikon ZR",
                requestPairing: false,
                onEstablishmentDiagnostic: { stages.append($0) }
            )
        }

        let recorded = stages.snapshot
        #expect(recorded.contains(where: { $0.contains("OpenSession") }))
        #expect(
            USBHandshakeDiagnostic.from(stage: recorded.last { $0.hasPrefix("stage:") } ?? "")
                == .openSession)
        #expect(transport.didClose)
    }
}

private final class StageLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    func append(_ value: String) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    var snapshot: [String] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

private final class ScriptedUSBTransport: CameraTransport, @unchecked Sendable {
    let kind: CameraTransportKind = .usb
    private(set) var operations: [PTPOperationCode] = []
    private(set) var didClose = false
    private let handler:
        @Sendable (PTPOperationCode, UInt32?) async throws -> PTPIPTransactionResult

    init(
        handler:
            @escaping @Sendable (PTPOperationCode, UInt32?) async throws ->
            PTPIPTransactionResult
    ) {
        self.handler = handler
    }

    func executeTransaction(
        operationCode: PTPOperationCode,
        transactionID: UInt32?,
        parameters: [UInt32],
        dataPhase: PTPDataPhase,
        dataOut: Data?,
        deadline: Duration?
    ) async throws -> PTPIPTransactionResult {
        operations.append(operationCode)
        return try await handler(operationCode, transactionID)
    }

    func nextEvent() async throws -> PTPEvent {
        throw NativeCameraSessionError.connectionClosed
    }

    func close() { didClose = true }
}

private func usbOK(data: Data = Data(), transactionID: UInt32 = 1) throws -> PTPIPTransactionResult
{
    let payload =
        ByteCoding.uint16LE(PTPResponseCode.ok.rawValue) + ByteCoding.uint32LE(transactionID)
    return PTPIPTransactionResult(
        operationResponse: try PTPOperationResponse(payloadBytes: payload),
        data: data
    )
}

private func zrDeviceInfoBytes() -> Data {
    var bytes: [UInt8] = [
        100, 0,
        10, 0, 0, 0,
        100, 0,
    ]
    bytes.append(contentsOf: ptpString(""))
    bytes.append(contentsOf: [0, 0])
    bytes.append(contentsOf: emptyUInt16Array())
    bytes.append(contentsOf: emptyUInt16Array())
    bytes.append(contentsOf: emptyUInt16Array())
    bytes.append(contentsOf: emptyUInt16Array())
    bytes.append(contentsOf: emptyUInt16Array())
    bytes.append(contentsOf: ptpString("Nikon"))
    bytes.append(contentsOf: ptpString("ZR"))
    bytes.append(contentsOf: ptpString("1.0"))
    bytes.append(contentsOf: ptpString("ABC123"))
    return Data(bytes)
}

private func ptpString(_ value: String) -> [UInt8] {
    guard !value.isEmpty else { return [0] }
    var bytes = [UInt8(value.utf16.count + 1)]
    for unit in value.utf16 {
        bytes += ByteCoding.uint16LE(unit)
    }
    bytes += [0, 0]
    return bytes
}

private func emptyUInt16Array() -> [UInt8] {
    [0, 0, 0, 0]
}

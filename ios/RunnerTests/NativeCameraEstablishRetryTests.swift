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
        #expect(
            NativeCameraSession.isRetryableEstablishFailure(
                NativeCameraSessionError.initFailed(.busy), requestPairing: false
            )
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

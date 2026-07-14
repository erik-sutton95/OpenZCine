// Wire-level tests for the Android facade's PTP-IP session layer against the
// scripted fake ZR. Payload codecs are already covered by the core suites;
// these tests cover what only a socket pair can: connection sequencing, the
// saved-profile → first-time-pairing fallback, property reads through a live
// transaction, and the graceful CloseSession teardown (the reconnect-wedge
// fix semantics carried over from iOS).

import Foundation
import OpenZCineCore
import Testing

@testable import OpenZCineAndroidFacade

struct PTPIPClientSessionTests {
    private func connect(
        to server: FakeZRServer,
        onPhase: (CameraConnectionPhase, String) -> Void = { _, _ in }
    ) throws -> PTPIPClientSession {
        try PTPIPClientSession.connect(
            host: "127.0.0.1",
            port: server.port,
            timeoutMilliseconds: 2_000,
            onPhase: onPhase)
    }

    @Test func connectsWithSavedProfileAndIdentifies() throws {
        let server = try FakeZRServer()
        defer { server.stop() }

        var phases: [CameraConnectionPhase] = []
        let session = try connect(to: server) { phase, _ in phases.append(phase) }
        defer { session.disconnect() }

        #expect(phases == [.handshaking, .connected])
        #expect(session.identity.cameraName == "ZR_6001234")
        #expect(session.identity.manufacturer == "Nikon Corporation")
        #expect(session.identity.model == "ZR")
        #expect(session.identity.serialNumber == "6001234")
        #expect(session.identity.displayName == "ZR_6001234")
        // The quiet saved-profile path must not touch the pairing operations.
        let operations = server.receivedOperations()
        #expect(!operations.contains(.getPairingInfo))
        #expect(!operations.contains(.confirmPairing))
        #expect(operations.prefix(2) == [.openSession, .changeApplicationMode])
    }

    @Test func fallsBackToFirstTimePairingWhenAppControlIsRefused() throws {
        var options = FakeZRServer.Options()
        options.acceptsAppControlImmediately = false
        let server = try FakeZRServer(options: options)
        defer { server.stop() }

        var phases: [(CameraConnectionPhase, String)] = []
        let session = try connect(to: server) { phase, detail in phases.append((phase, detail)) }
        defer { session.disconnect() }

        #expect(phases.map(\.0) == [.handshaking, .pairing, .confirmOnCamera, .connected])
        // The pairing PIN extracted by the core from the challenge bytes.
        #expect(phases.first(where: { $0.0 == .confirmOnCamera })?.1 == "1234")
        #expect(session.identity.model == "ZR")

        let operations = server.receivedOperations()
        // Probe attempt: open + refused app mode + graceful CloseSession…
        #expect(operations.prefix(3) == [.openSession, .changeApplicationMode, .closeSession])
        // …then the fresh pairing session in the iOS-verified order.
        #expect(
            operations.dropFirst(3).prefix(5)
                == [
                    .openSession, .getPairingInfo, .confirmPairing, .changeApplicationMode,
                    .getDeviceInfo,
                ])
    }

    @Test func readsBatteryAndRecordingStateProperties() throws {
        let server = try FakeZRServer()
        defer { server.stop() }
        let session = try connect(to: server)
        defer { session.disconnect() }

        // Battery decodes through the core's snapshot (UINT8 percent).
        let battery = try session.readPropertyDisplayValue(
            code: PTPPropertyCode.batteryLevel.rawValue)
        #expect(battery == "80")

        // Recording state (MovieRecProhibitionCondition): raw value, 0 = recordable.
        let recordingState = try session.readPropertyDisplayValue(
            code: PTPPropertyCode.movieRecProhibitionCondition.rawValue)
        #expect(recordingState == "0x0")

        // Unknown codes are rejected core-side, not sent to the camera.
        #expect(throws: PTPIPClientSessionError.unsupportedProperty(0xBEEF)) {
            try session.readPropertyDisplayValue(code: 0xBEEF)
        }

        // Transaction IDs keep counting across establishment and the property
        // reads — an ID sequence that restarts mid-session is a protocol bug.
        let transactionIDs = server.receivedTransactionIDs()
        #expect(transactionIDs == Array(0..<UInt32(transactionIDs.count)))
    }

    @Test func disconnectSendsGracefulCloseSession() throws {
        let server = try FakeZRServer()
        defer { server.stop() }
        let session = try connect(to: server)

        session.disconnect()
        // Idempotent: a second disconnect must not send another CloseSession.
        session.disconnect()

        let closeCount = server.receivedOperations().filter { $0 == .closeSession }.count
        #expect(closeCount == 1)
        #expect(session.identity.model == "ZR")

        // The link is gone after teardown.
        #expect(throws: PTPIPClientSessionError.self) {
            try session.readPropertyDisplayValue(code: PTPPropertyCode.batteryLevel.rawValue)
        }
    }

    @Test func surfacesInitFail() throws {
        var options = FakeZRServer.Options()
        options.refusesInit = true
        let server = try FakeZRServer(options: options)
        defer { server.stop() }

        #expect(throws: PTPIPClientSessionError.initFailed(.rejectedInitiator)) {
            try connect(to: server)
        }
    }

    @Test func failsCleanlyWhenNothingListens() throws {
        let server = try FakeZRServer()
        let port = server.port
        server.stop()

        // A refused connect surfaces as `.connectionClosed` (POLLHUP on the
        // non-blocking connect) or `.connectionFailed` — never a hang.
        #expect(throws: PTPIPClientSessionError.self) {
            try PTPIPClientSession.connect(
                host: "127.0.0.1", port: port, timeoutMilliseconds: 1_000)
        }
    }
}

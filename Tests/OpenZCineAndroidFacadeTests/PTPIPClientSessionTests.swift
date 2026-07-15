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

    @Test func startsAndStopsMovieRecordingOverTheLiveViewSession() throws {
        let server = try FakeZRServer()
        defer { server.stop() }
        let session = try connect(to: server)
        defer { session.disconnect() }

        try session.startRecording()
        #expect(server.isRecording())

        try session.stopRecording()
        #expect(!server.isRecording())

        let operations = server.receivedOperations()
        #expect(operations.contains(.startMovieRecInCard))
        #expect(operations.contains(.endMovieRec))
    }

    @Test func rejectsRecordingWhileMediaOwnsTheCommandChannel() throws {
        let server = try FakeZRServer()
        defer { server.stop() }
        let session = try connect(to: server)
        defer { session.disconnect() }

        session.enterMediaMode()
        #expect(throws: PTPIPClientSessionError.mediaModeActive) {
            try session.startRecording()
        }
        #expect(!server.receivedOperations().contains(.startMovieRecInCard))
    }

    @Test func writesStandardAndExtendedControlsWithTheCorrectPTPOperations() throws {
        let server = try FakeZRServer()
        defer { server.stop() }
        let session = try connect(to: server)
        defer { session.disconnect() }

        // ISO is a 32-bit 0x0001_Dxxx extended property; focus area is a
        // 16-bit 0xDxxx property. The operation must follow property width,
        // not the payload's byte count.
        try session.applyControl(.iso, label: "800")
        try session.applyControl(.focusArea, label: "Subject")

        #expect(
            server.receivedPropertyWrites()
                == [
                    FakeZRPropertyWrite(
                        operation: .setDevicePropValueEx,
                        property: PTPPropertyCode.movieISOSensitivity.rawValue,
                        data: Data([0x20, 0x03, 0x00, 0x00])),
                    FakeZRPropertyWrite(
                        operation: .setDevicePropValue,
                        property: PTPPropertyCode.movieFocusMeteringMode.rawValue,
                        data: Data([0x33, 0x80])),
                ])
        // Every data-out write remains a normal serialized PTP transaction.
        let transactionIDs = server.receivedTransactionIDs()
        #expect(transactionIDs == Array(0..<UInt32(transactionIDs.count)))
    }

    @Test func kelvinWhiteBalanceWritesModeThenTemperatureAsOneControlSequence() throws {
        let server = try FakeZRServer()
        defer { server.stop() }
        let session = try connect(to: server)
        defer { session.disconnect() }

        try session.applyControl(.whiteBalanceKelvin, label: "5600K")
        try session.startRecording()

        #expect(
            server.receivedPropertyWrites()
                == [
                    FakeZRPropertyWrite(
                        operation: .setDevicePropValue,
                        property: PTPPropertyCode.movieWhiteBalance.rawValue,
                        data: Data([0x12, 0x80])),
                    FakeZRPropertyWrite(
                        operation: .setDevicePropValue,
                        property: PTPPropertyCode.movieWBColorTemp.rawValue,
                        data: Data([0xE0, 0x15])),
                ])
        let operations = server.receivedOperations()
        #expect(operations.filter { $0 == .setDevicePropValue }.count == 2)
        #expect(operations.contains(.startMovieRecInCard))
        if let secondWrite = operations.lastIndex(of: .setDevicePropValue),
            let recordStart = operations.lastIndex(of: .startMovieRecInCard)
        {
            #expect(secondWrite < recordStart)
        }
    }

    @Test func rejectsUnsupportedOrMediaBusyCameraControlsBeforeWriting() throws {
        let server = try FakeZRServer()
        defer { server.stop() }
        let session = try connect(to: server)
        defer { session.disconnect() }

        #expect(
            throws: PTPIPClientSessionError.unsupportedControl(.codec, "H.265")
        ) {
            try session.applyControl(.codec, label: "H.265")
        }
        session.enterMediaMode()
        #expect(throws: PTPIPClientSessionError.mediaModeActive) {
            try session.applyControl(.iso, label: "800")
        }
        #expect(server.receivedPropertyWrites().isEmpty)
    }

    @Test func surfacesCameraRejectionForPropertyWrites() throws {
        var options = FakeZRServer.Options()
        options.propertyWriteResponseCode = PTPResponseCode.deviceBusy.rawValue
        let server = try FakeZRServer(options: options)
        defer { server.stop() }
        let session = try connect(to: server)
        defer { session.disconnect() }

        #expect(
            throws: PTPIPClientSessionError.operationRejected(
                .setDevicePropValue, .deviceBusy)
        ) {
            try session.applyControl(.focusMode, label: "AF-C")
        }
        #expect(server.receivedPropertyWrites().count == 1)
    }

    @Test func surfacesCameraRejectionForMovieRecordStart() throws {
        var options = FakeZRServer.Options()
        options.startRecordingResponseCode = PTPResponseCode.deviceBusy.rawValue
        let server = try FakeZRServer(options: options)
        defer { server.stop() }
        let session = try connect(to: server)
        defer { session.disconnect() }

        #expect(
            throws: PTPIPClientSessionError.operationRejected(
                .startMovieRecInCard, .deviceBusy)
        ) {
            try session.startRecording()
        }
        #expect(!server.isRecording())
    }

    @Test func rapidFakeServerTurnoverRetainsEachCameraScript() throws {
        func verifyRejectingServer() throws {
            let priorServer = try FakeZRServer()
            priorServer.stop()

            var options = FakeZRServer.Options()
            options.startRecordingResponseCode = PTPResponseCode.deviceBusy.rawValue
            let rejectingServer = try FakeZRServer(options: options)
            defer { rejectingServer.stop() }

            let session = try connect(to: rejectingServer)
            defer { session.disconnect() }
            #expect(
                throws: PTPIPClientSessionError.operationRejected(
                    .startMovieRecInCard, .deviceBusy)
            ) {
                try session.startRecording()
            }
        }

        // Start/stop cycles exercise the raw-descriptor reuse case that can
        // otherwise make a concurrently scheduled test connect to a prior
        // fake camera's accept loop.
        for _ in 0..<24 {
            try verifyRejectingServer()
        }
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

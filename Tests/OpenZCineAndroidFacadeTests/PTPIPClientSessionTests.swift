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

@Test func androidInitiatorIdentityIsStableAndDistinctFromIOS() {
    #expect(Array(AndroidPTPIPInitiator.appGUID) == Array("OpenZCineAndroid".utf8))
    #expect(AndroidPTPIPInitiator.appGUID.count == 16)
    #expect(AndroidPTPIPInitiator.appGUID != PTPIPInitiator.appGUID)
    #expect(AndroidPTPIPInitiator.friendlyName == "OpenZCine Android")
    #expect(AndroidPTPIPInitiator.friendlyName != PTPIPInitiator.friendlyName)
}

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

    private func startLiveViewAndWaitForFocus(
        _ session: PTPIPClientSession,
        timeout: TimeInterval = 2
    ) throws {
        let arrival = FocusFrameArrival()
        try session.startLiveView(
            onFrame: { frame, _ in
                arrival.record(frame)
            },
            onEnded: {})
        if !arrival.wait(timeout: timeout) {
            session.stopLiveView()
            throw PTPIPClientSessionError.focusStateUnavailable
        }
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

    @Test func configuresOnlyPreviewPropertiesBeforeLiveViewStarts() throws {
        let server = try FakeZRServer()
        defer { server.stop() }
        let session = try connect(to: server)
        defer { session.disconnect() }

        #expect(
            session.configureLiveView(
                imageSize: 1,
                compression: 3,
                frameIntervalNanoseconds: 49_500_000))
        #expect(
            server.receivedPropertyWrites()
                == [
                    FakeZRPropertyWrite(
                        operation: .setDevicePropValueEx,
                        property: PTPPropertyCode.liveViewImageSize.rawValue,
                        data: Data([1])),
                    FakeZRPropertyWrite(
                        operation: .setDevicePropValueEx,
                        property: PTPPropertyCode.liveViewImageCompression.rawValue,
                        data: Data([3])),
                ])
        let operations = server.receivedOperations()
        #expect(!operations.contains(.startMovieRecInCard))
        #expect(!operations.contains(.endMovieRec))
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

    @Test func descriptorBackedAndroidControlsWriteOnlyExactAdvertisedValues() throws {
        let server = try FakeZRServer()
        defer { server.stop() }
        let session = try connect(to: server)
        defer { session.disconnect() }

        let bootstrap = session.refreshAndroidPropertySnapshot(.bootstrap)
        #expect(bootstrap.result == .accepted)
        #expect(bootstrap.controls.resolutionFrameRate == "6K · 25p")
        #expect(bootstrap.controls.codec == "R3D NE")
        #expect(bootstrap.controls.whiteBalanceTint == "Neutral")
        #expect(bootstrap.controls.shutterValues == ["90°", "180°", "360°"])
        #expect(bootstrap.controls.baseISO == ["Low", "High"])
        #expect(bootstrap.controls.shutterModes == ["Speed", "Angle"])
        #expect(bootstrap.controls.shutterLocks == ["Unlocked", "Locked"])
        #expect(bootstrap.controls.resolutionFrameRates == ["6K · 25p", "4K · 60p"])
        #expect(bootstrap.controls.codecs == ["R3D NE", "H.265"])
        #expect(bootstrap.controls.vibrationReduction == ["OFF", "ON", "SPORT"])
        #expect(bootstrap.controls.electronicVR == ["OFF", "ON"])
        #expect(bootstrap.controls.whiteBalanceTints.contains("A1 · G0.5"))

        let writeBaseline = server.receivedPropertyWrites().count
        try session.applyAndroidControl(.shutter, label: "360°")
        try session.applyAndroidControl(.baseISO, label: "Low")
        try session.applyAndroidControl(.shutterMode, label: "Speed")
        try session.applyAndroidControl(.shutter, label: "1/100")
        try session.applyAndroidControl(.shutterLock, label: "Locked")
        try session.applyAndroidControl(.whiteBalanceTint, label: "A1 · G0.5")
        try session.applyAndroidControl(.resolutionFrameRate, label: "4K · 60p")
        try session.applyAndroidControl(.codec, label: "H.265")
        try session.applyAndroidControl(.vibrationReduction, label: "ON")
        try session.applyAndroidControl(.electronicVR, label: "OFF")

        #expect(
            Array(server.receivedPropertyWrites().dropFirst(writeBaseline))
                == [
                    FakeZRPropertyWrite(
                        operation: .setDevicePropValueEx,
                        property: PTPPropertyCode.movieShutterAngle.rawValue,
                        data: Data(ByteCoding.uint32LE(36_000))),
                    FakeZRPropertyWrite(
                        operation: .setDevicePropValueEx,
                        property: PTPPropertyCode.movieBaseISO.rawValue,
                        data: Data([1])),
                    FakeZRPropertyWrite(
                        operation: .setDevicePropValueEx,
                        property: PTPPropertyCode.movieShutterMode.rawValue,
                        data: Data([1])),
                    FakeZRPropertyWrite(
                        operation: .setDevicePropValue,
                        property: PTPPropertyCode.movieShutterSpeed.rawValue,
                        data: Data(ByteCoding.uint32LE(0x0001_0064))),
                    FakeZRPropertyWrite(
                        operation: .setDevicePropValueEx,
                        property: PTPPropertyCode.movieTVLockSetting.rawValue,
                        data: Data([1])),
                    FakeZRPropertyWrite(
                        operation: .setDevicePropValue,
                        property: PTPPropertyCode.movieWbTuneColorTemp.rawValue,
                        data: Data(ByteCoding.uint16LE(416))),
                    FakeZRPropertyWrite(
                        operation: .setDevicePropValue,
                        property: PTPPropertyCode.movieRecordScreenSize.rawValue,
                        data: Data(ByteCoding.uint64LE(0x0F00_0870_003C_0000))),
                    FakeZRPropertyWrite(
                        operation: .setDevicePropValue,
                        property: PTPPropertyCode.movieFileType.rawValue,
                        data: Data(ByteCoding.uint32LE(0x0001_0A01))),
                    FakeZRPropertyWrite(
                        operation: .setDevicePropValue,
                        property: PTPPropertyCode.movieVibrationReduction.rawValue,
                        data: Data([1])),
                    FakeZRPropertyWrite(
                        operation: .setDevicePropValue,
                        property: PTPPropertyCode.electronicVR.rawValue,
                        data: Data([0])),
                ])

        let refreshed = session.refreshAndroidPropertySnapshot(
            .propertyChanged(PTPPropertyCode.movieFileType.rawValue))
        #expect(refreshed.controls.resolutionFrameRate == "4K · 60p")
        #expect(refreshed.controls.codec == "H.265")
        #expect(refreshed.controls.whiteBalanceTint == "A1 · G0.5")
        #expect(refreshed.properties.shutterMode == .speed)
        #expect(refreshed.properties.shutterSpeed == "1/100")
        #expect(refreshed.properties.baseISO == "Low")
        #expect(refreshed.properties.shutterLocked == true)
        #expect(refreshed.properties.vibrationReduction == "ON")
        #expect(refreshed.properties.electronicVR == "OFF")

        let rejectedBaseline = server.receivedPropertyWrites().count
        #expect(
            throws: PTPIPClientSessionError.unsupportedAndroidControl(
                "resolutionFrameRate", "6K · 60p")
        ) {
            try session.applyAndroidControl(.resolutionFrameRate, label: "6K · 60p")
        }
        #expect(server.receivedPropertyWrites().count == rejectedBaseline)
    }

    @Test func acceptedControlWriteRequiresMatchingAuthoritativeReadback() throws {
        var options = FakeZRServer.Options()
        options.ignoredPropertyWrites = [PTPPropertyCode.movieISOSensitivity.rawValue]
        let server = try FakeZRServer(options: options)
        defer { server.stop() }
        let session = try connect(to: server)
        defer { session.disconnect() }

        #expect(
            throws: PTPIPClientSessionError.controlReadbackMismatch("iso", "1600")
        ) {
            try session.applyAndroidControl(.iso, label: "1600")
        }
        #expect(server.receivedPropertyWrites().count == 1)
    }

    @Test func unsupportedDescriptorsHideOnlyTheirOwnAndroidControls() throws {
        var options = FakeZRServer.Options()
        options.unsupportedPropertyCodes = [
            PTPPropertyCode.movieFileType.rawValue,
            PTPPropertyCode.electronicVR.rawValue,
        ]
        let server = try FakeZRServer(options: options)
        defer { server.stop() }
        let session = try connect(to: server)
        defer { session.disconnect() }

        let bootstrap = session.refreshAndroidPropertySnapshot(.bootstrap)
        #expect(bootstrap.result == .unsupported)
        #expect(bootstrap.controls.codecs.isEmpty)
        #expect(bootstrap.controls.electronicVR.isEmpty)
        #expect(bootstrap.controls.resolutionFrameRates == ["6K · 25p", "4K · 60p"])
        #expect(bootstrap.controls.shutterValues == ["90°", "180°", "360°"])
        #expect(bootstrap.controls.vibrationReduction == ["OFF", "ON", "SPORT"])
    }

    @Test func whiteBalanceTintOptionsRespectTheAdvertisedDescriptorRange() throws {
        var options = FakeZRServer.Options()
        options.whiteBalanceTintMaximum = 612
        let server = try FakeZRServer(options: options)
        defer { server.stop() }
        let session = try connect(to: server)
        defer { session.disconnect() }

        let controls = session.refreshAndroidPropertySnapshot(.bootstrap).controls
        #expect(controls.whiteBalanceTints.count == 85)
        #expect(controls.whiteBalanceTints.contains("B3 · G1.5"))
        #expect(controls.whiteBalanceTints.contains("Neutral"))
        #expect(!controls.whiteBalanceTints.contains("A3 · M1.5"))
    }

    @Test func commandRoundTripUsesMeasuredPTPResponseTimingAndClearsOnDisconnect() throws {
        var options = FakeZRServer.Options()
        options.commandResponseDelayMilliseconds = 12
        let server = try FakeZRServer(options: options)
        defer { server.stop() }
        let session = try connect(to: server)

        _ = try session.readPropertyDisplayValue(code: PTPPropertyCode.batteryLevel.rawValue)
        let measured = try #require(session.latestCommandRoundTripMilliseconds())
        #expect(measured >= 8)
        #expect(measured < 1_000)

        session.disconnect()
        #expect(session.latestCommandRoundTripMilliseconds() == nil)
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
            throws: PTPIPClientSessionError.unsupportedAndroidControl("codec", "Unadvertised")
        ) {
            try session.applyControl(.codec, label: "Unadvertised")
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

    @Test func changeAfAreaUsesExactParametersWithoutADataOutPhase() throws {
        let server = try FakeZRServer()
        defer { server.stop() }
        let session = try connect(to: server)
        defer { session.disconnect() }

        try session.changeAfArea(x: 1_234, y: 567)

        let request = try #require(
            server.receivedRequests().last { $0.operation == .changeAfArea })
        #expect(request.parameters == [1_234, 567])
        #expect(request.dataPhase == .noDataOrDataIn)
        #expect(request.dataOut == nil)
    }

    @Test func changeAfAreaRejectsMediaOwnershipAndCameraRejection() throws {
        var rejectingOptions = FakeZRServer.Options()
        rejectingOptions.changeAfAreaResponseCode = PTPResponseCode.deviceBusy.rawValue
        let rejectingServer = try FakeZRServer(options: rejectingOptions)
        defer { rejectingServer.stop() }
        let rejectingSession = try connect(to: rejectingServer)
        defer { rejectingSession.disconnect() }

        #expect(
            throws: PTPIPClientSessionError.operationRejected(.changeAfArea, .deviceBusy)
        ) {
            try rejectingSession.changeAfArea(x: 3_024, y: 1_700)
        }

        let mediaServer = try FakeZRServer()
        defer { mediaServer.stop() }
        let mediaSession = try connect(to: mediaServer)
        defer { mediaSession.disconnect() }
        mediaSession.enterMediaMode()
        #expect(throws: PTPIPClientSessionError.mediaModeActive) {
            try mediaSession.changeAfArea(x: 3_024, y: 1_700)
        }
        #expect(!mediaServer.receivedOperations().contains(.changeAfArea))
    }

    @Test func resetFocusPointReleasesSettlesRecentresAndRestoresWithoutStartTracking() throws {
        var options = FakeZRServer.Options()
        options.liveViewFrameIntervalNanoseconds = 5_000_000
        options.focusRelatchesAfterChange = true
        let server = try FakeZRServer(options: options)
        defer { server.stop() }
        let session = try connect(to: server)
        defer { session.disconnect() }
        try startLiveViewAndWaitForFocus(session)
        defer { session.stopLiveView() }
        let requestBaseline = server.receivedRequests().count

        try session.resetFocusPoint()

        let resetRequests = Array(server.receivedRequests().dropFirst(requestBaseline))
        let semanticOperations =
            resetRequests.compactMap { request -> PTPOperationCode? in
                switch request.operation {
                case .endTracking, .afDriveCancel, .setDevicePropValue,
                    .setDevicePropValueEx, .changeAfArea:
                    return request.operation
                default:
                    return nil
                }
            }
        #expect(
            semanticOperations == [
                .endTracking,
                .afDriveCancel,
                .setDevicePropValueEx,
                .setDevicePropValue,
                .changeAfArea,
                .endTracking,
                .afDriveCancel,
                .setDevicePropValue,
                .setDevicePropValueEx,
            ])

        let change = try #require(resetRequests.first { $0.operation == .changeAfArea })
        #expect(change.parameters == [3_024, 1_700])
        #expect(change.dataPhase == .noDataOrDataIn)
        #expect(change.dataOut == nil)

        let writes = server.receivedPropertyWrites()
        #expect(
            writes == [
                FakeZRPropertyWrite(
                    operation: .setDevicePropValueEx,
                    property: PTPPropertyCode.movieAFSubjectDetection.rawValue,
                    data: Data([0])),
                FakeZRPropertyWrite(
                    operation: .setDevicePropValue,
                    property: PTPPropertyCode.movieFocusMeteringMode.rawValue,
                    data: Data([0x10, 0x80])),
                FakeZRPropertyWrite(
                    operation: .setDevicePropValue,
                    property: PTPPropertyCode.movieFocusMeteringMode.rawValue,
                    data: Data([0x33, 0x80])),
                FakeZRPropertyWrite(
                    operation: .setDevicePropValueEx,
                    property: PTPPropertyCode.movieAFSubjectDetection.rawValue,
                    data: Data([2])),
            ])

        let firstRelease = try #require(resetRequests.firstIndex { $0.operation == .endTracking })
        let changeIndex = try #require(resetRequests.firstIndex { $0.operation == .changeAfArea })
        let framesBeforeChange =
            resetRequests[firstRelease..<changeIndex]
            .filter { $0.operation == .getLiveViewImageEx }.count
        #expect(framesBeforeChange >= FocusResetSettlePolicy.minimumFramesAfterRelease)
        #expect(framesBeforeChange <= FocusResetSettlePolicy.maximumWaitFrames + 4)
        #expect(resetRequests.filter { $0.operation == .endTracking }.count == 2)
        // Nikon StartTracking is 0x9424. Reset restores picker settings but must never re-latch a
        // tracked target, even though that vendor operation is intentionally absent from our API.
        #expect(!server.receivedRawOperationCodes().contains(0x9424))
    }

    @Test func resetFocusPointUsesTheFifteenFrameCeilingWhenTrackingNeverClears() throws {
        var options = FakeZRServer.Options()
        options.liveViewFrameIntervalNanoseconds = 5_000_000
        options.focusTrackingNeverReleases = true
        let server = try FakeZRServer(options: options)
        defer { server.stop() }
        let session = try connect(to: server)
        defer { session.disconnect() }
        try startLiveViewAndWaitForFocus(session)
        defer { session.stopLiveView() }
        let requestBaseline = server.receivedRequests().count

        try session.resetFocusPoint()

        let resetRequests = Array(server.receivedRequests().dropFirst(requestBaseline))
        let firstRelease = try #require(resetRequests.firstIndex { $0.operation == .endTracking })
        let changeIndex = try #require(resetRequests.firstIndex { $0.operation == .changeAfArea })
        let framesBeforeChange =
            resetRequests[firstRelease..<changeIndex]
            .filter { $0.operation == .getLiveViewImageEx }.count
        #expect(framesBeforeChange >= FocusResetSettlePolicy.maximumWaitFrames)
        #expect(framesBeforeChange <= FocusResetSettlePolicy.maximumWaitFrames + 4)
    }

    @Test func resetFocusPointTreatsMissingPostReleaseBoxesAsTrackingCleared() throws {
        for removesWholeFocusObject in [false, true] {
            var options = FakeZRServer.Options()
            options.liveViewFrameIntervalNanoseconds = 5_000_000
            options.focusMetadataDisappearsAfterRelease = removesWholeFocusObject
            options.focusBoxesDisappearAfterRelease = !removesWholeFocusObject
            let server = try FakeZRServer(options: options)
            defer { server.stop() }
            let session = try connect(to: server)
            defer { session.disconnect() }
            try startLiveViewAndWaitForFocus(session)
            defer { session.stopLiveView() }
            let requestBaseline = server.receivedRequests().count

            try session.resetFocusPoint()

            let resetRequests = Array(server.receivedRequests().dropFirst(requestBaseline))
            let firstRelease = try #require(
                resetRequests.firstIndex { $0.operation == .endTracking })
            let changeIndex = try #require(
                resetRequests.firstIndex { $0.operation == .changeAfArea })
            let framesBeforeChange =
                resetRequests[firstRelease..<changeIndex]
                .filter { $0.operation == .getLiveViewImageEx }.count
            #expect(framesBeforeChange >= FocusResetSettlePolicy.minimumFramesAfterRelease)
            #expect(framesBeforeChange < FocusResetSettlePolicy.maximumWaitFrames)
        }
    }

    @Test func stoppingLiveViewWakesAResetWaitingForNewFocusHeaders() throws {
        var options = FakeZRServer.Options()
        options.liveViewFrameIntervalNanoseconds = 1_000_000_000
        options.focusTrackingNeverReleases = true
        let server = try FakeZRServer(options: options)
        defer { server.stop() }
        let session = try connect(to: server)
        defer { session.disconnect() }
        try startLiveViewAndWaitForFocus(session)

        let completion = FocusResetCompletion()
        Thread.detachNewThread {
            do {
                try session.resetFocusPoint()
                completion.finish(.success(()))
            } catch {
                completion.finish(.failure(error))
            }
        }
        let releaseDeadline = Date().addingTimeInterval(2)
        while !server.receivedOperations().contains(.endTracking), Date() < releaseDeadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        #expect(server.receivedOperations().contains(.endTracking))

        session.stopLiveView()

        let result = try #require(completion.wait(timeout: 1))
        switch result {
        case .success:
            Issue.record("Focus reset unexpectedly completed after live view stopped")
        case .failure(let error):
            #expect(error as? PTPIPClientSessionError == .focusStateUnavailable)
        }
    }

    @Test func resetFocusPointFailsClosedWithoutAuthoritativeLiveFocus() throws {
        let noLiveViewServer = try FakeZRServer()
        defer { noLiveViewServer.stop() }
        let noLiveViewSession = try connect(to: noLiveViewServer)
        defer { noLiveViewSession.disconnect() }
        #expect(throws: PTPIPClientSessionError.focusStateUnavailable) {
            try noLiveViewSession.resetFocusPoint()
        }
        #expect(!noLiveViewServer.receivedOperations().contains(.changeAfArea))

        var noMetadataOptions = FakeZRServer.Options()
        noMetadataOptions.focusMetadataEnabled = false
        let noMetadataServer = try FakeZRServer(options: noMetadataOptions)
        defer { noMetadataServer.stop() }
        let noMetadataSession = try connect(to: noMetadataServer)
        defer { noMetadataSession.disconnect() }
        try noMetadataSession.startLiveView(onFrame: { _, _ in }, onEnded: {})
        defer { noMetadataSession.stopLiveView() }
        Thread.sleep(forTimeInterval: 0.1)
        #expect(throws: PTPIPClientSessionError.focusStateUnavailable) {
            try noMetadataSession.resetFocusPoint()
        }
        #expect(!noMetadataServer.receivedOperations().contains(.changeAfArea))

        var unsupportedOptions = FakeZRServer.Options()
        unsupportedOptions.unsupportedPropertyCodes = [PTPPropertyCode.movieFocusMode.rawValue]
        let unsupportedServer = try FakeZRServer(options: unsupportedOptions)
        defer { unsupportedServer.stop() }
        let unsupportedSession = try connect(to: unsupportedServer)
        defer { unsupportedSession.disconnect() }
        try startLiveViewAndWaitForFocus(unsupportedSession)
        defer { unsupportedSession.stopLiveView() }
        let baseline = unsupportedServer.receivedOperations().count
        #expect(throws: PTPIPClientSessionError.focusStateUnavailable) {
            try unsupportedSession.resetFocusPoint()
        }
        let resetOperations = unsupportedServer.receivedOperations().dropFirst(baseline)
        #expect(!resetOperations.contains(.endTracking))
        #expect(!resetOperations.contains(.changeAfArea))

        var shortOptions = FakeZRServer.Options()
        shortOptions.shortPropertyCodesAfterFirstRead = [
            PTPPropertyCode.movieFocusMode.rawValue
        ]
        let shortServer = try FakeZRServer(options: shortOptions)
        defer { shortServer.stop() }
        let shortSession = try connect(to: shortServer)
        defer { shortSession.disconnect() }
        let seeded =
            shortSession.refreshAndroidPropertySnapshot(
                .propertyChanged(PTPPropertyCode.movieFocusMode.rawValue))
        #expect(seeded.result == .accepted)
        #expect(seeded.properties.focusMode == "AF-C")
        try startLiveViewAndWaitForFocus(shortSession)
        defer { shortSession.stopLiveView() }
        let shortBaseline = shortServer.receivedOperations().count
        #expect(throws: PTPIPClientSessionError.focusStateUnavailable) {
            try shortSession.resetFocusPoint()
        }
        let shortResetOperations = shortServer.receivedOperations().dropFirst(shortBaseline)
        #expect(!shortResetOperations.contains(.endTracking))
        #expect(!shortResetOperations.contains(.changeAfArea))
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

// SAFETY: `@unchecked Sendable` because all mutable state is guarded by `condition`.
private final class FocusFrameArrival: @unchecked Sendable {
    private let condition = NSCondition()
    private var arrived = false

    func record(_ frame: PTPLiveViewFrame) {
        guard frame.focus != nil else { return }
        condition.lock()
        arrived = true
        condition.broadcast()
        condition.unlock()
    }

    func wait(timeout: TimeInterval) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while !arrived, condition.wait(until: deadline) {}
        return arrived
    }
}

// SAFETY: `@unchecked Sendable` because all mutable state is guarded by `condition`.
private final class FocusResetCompletion: @unchecked Sendable {
    private let condition = NSCondition()
    private var result: Result<Void, Error>?

    func finish(_ result: Result<Void, Error>) {
        condition.lock()
        self.result = result
        condition.broadcast()
        condition.unlock()
    }

    func wait(timeout: TimeInterval) -> Result<Void, Error>? {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while result == nil, condition.wait(until: deadline) {}
        return result
    }
}

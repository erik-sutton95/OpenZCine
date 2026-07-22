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
        strategy: PTPIPClientSession.ConnectionStrategy = .restoreProfileThenPairing,
        onPhase: (CameraConnectionPhase, String) -> Void = { _, _ in }
    ) throws -> PTPIPClientSession {
        try PTPIPClientSession.connect(
            host: "127.0.0.1",
            port: server.port,
            timeoutMilliseconds: 2_000,
            strategy: strategy,
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

    @Test func connectsWithExplicitSavedProfileAndIdentifies() throws {
        let server = try FakeZRServer()
        defer { server.stop() }

        var phases: [CameraConnectionPhase] = []
        let session = try connect(to: server, strategy: .savedProfile) { phase, _ in
            phases.append(phase)
        }
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

    @Test func compatibilityStrategyFallsBackToFirstTimePairingWhenAppControlIsRefused() throws {
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
        // First-time Wi-Fi pairing stops after ConfirmPairing; full identity
        // arrives on the post-body-confirm saved-profile reconnect.
        #expect(session.identity.model.isEmpty || session.identity.model == "ZR")

        let operations = server.receivedOperations()
        // Probe attempt: open + refused app mode + graceful CloseSession…
        #expect(operations.prefix(3) == [.openSession, .changeApplicationMode, .closeSession])
        // …then the temporary pairing session. No ChangeApplicationMode after
        // ConfirmPairing — that races the body-confirm AP restart on hardware.
        #expect(
            operations.dropFirst(3).prefix(3)
                == [
                    .openSession, .getPairingInfo, .confirmPairing,
                ])
    }

    @Test func firstTimePairingSkipsSavedProfileProbeAndConfirmsAfterPairingSucceeds() throws {
        var options = FakeZRServer.Options()
        options.acceptsAppControlImmediately = false
        let server = try FakeZRServer(options: options)
        defer { server.stop() }

        var phases: [(CameraConnectionPhase, String)] = []
        var confirmPhaseFollowedSuccessfulConfirm = false
        let session = try connect(to: server, strategy: .firstTimePairing) { phase, detail in
            phases.append((phase, detail))
            if phase == .confirmOnCamera {
                confirmPhaseFollowedSuccessfulConfirm = server.receivedOperations().contains(
                    .confirmPairing)
            }
        }
        defer { session.disconnect() }

        #expect(phases.map(\.0) == [.handshaking, .pairing, .confirmOnCamera, .connected])
        #expect(phases.first(where: { $0.0 == .confirmOnCamera })?.1 == "1234")
        #expect(confirmPhaseFollowedSuccessfulConfirm)
        // Unknown Wi-Fi cameras must never probe `ChangeApplicationMode`: that
        // ejects the ZR from its pairing wizard before it yields a challenge.
        // After ConfirmPairing we also skip app-control/identify so the shell
        // can wait for body Confirm + AP restart (real ZR behavior).
        #expect(
            server.receivedOperations()
                == [
                    .openSession, .getPairingInfo, .confirmPairing,
                ])
    }

    @Test func savedProfileRejectsWithoutStartingFirstTimePairing() throws {
        var options = FakeZRServer.Options()
        options.acceptsAppControlImmediately = false
        let server = try FakeZRServer(options: options)
        defer { server.stop() }

        var phases: [CameraConnectionPhase] = []
        #expect(throws: PTPIPClientSessionError.savedProfileRequired) {
            try connect(to: server, strategy: .savedProfile) { phase, _ in
                phases.append(phase)
            }
        }

        #expect(phases == [.handshaking])
        #expect(
            server.receivedOperations()
                == [.openSession, .changeApplicationMode, .closeSession])
    }

    @Test func restoreStrategyDoesNotPairAfterTransportFailure() throws {
        var options = FakeZRServer.Options()
        options.disconnectsOnChangeApplicationMode = true
        let server = try FakeZRServer(options: options)
        defer { server.stop() }

        #expect(throws: PTPIPClientSessionError.self) {
            try connect(to: server, strategy: .restoreProfileThenPairing)
        }

        let operations = server.receivedOperations()
        #expect(operations.prefix(2) == [.openSession, .changeApplicationMode])
        #expect(!operations.contains(.getPairingInfo))
        #expect(!operations.contains(.confirmPairing))
    }

    @Test func firstTimePairingDoesNotReportCameraConfirmationWhenConfirmIsRejected() throws {
        var options = FakeZRServer.Options()
        options.confirmPairingResponseCode = PTPResponseCode.deviceBusy.rawValue
        let server = try FakeZRServer(options: options)
        defer { server.stop() }

        var phases: [CameraConnectionPhase] = []
        #expect(
            throws: PTPIPClientSessionError.operationRejected(.confirmPairing, .deviceBusy)
        ) {
            try connect(to: server, strategy: .firstTimePairing) { phase, _ in
                phases.append(phase)
            }
        }

        #expect(phases == [.handshaking, .pairing])
        #expect(!server.receivedOperations().contains(.changeApplicationMode))
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
                // Fixed 60 Hz monitor cadence (1e9 / 60).
                frameIntervalNanoseconds: 1_000_000_000 / 60))
        // Thermal-lengthened interval must also be accepted.
        #expect(
            session.configureLiveView(
                imageSize: 1,
                compression: 3,
                frameIntervalNanoseconds: 33_000_000))
        let writes = server.receivedPropertyWrites()
        #expect(writes.count == 4)
        #expect(
            writes.prefix(2)
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
        _ = session.refreshAndroidPropertySnapshot(.bootstrap)

        // ISO is a 32-bit 0x0001_Dxxx extended property; focus area is a
        // 16-bit 0xDxxx property. The operation must follow property width,
        // not the payload's byte count.
        try session.applyControl(.iso, label: "1600")
        try session.applyControl(.focusArea, label: "Subject")

        #expect(
            server.receivedPropertyWrites()
                == [
                    FakeZRPropertyWrite(
                        operation: .setDevicePropValueEx,
                        property: PTPPropertyCode.movieISOSensitivity.rawValue,
                        data: Data([0x40, 0x06, 0x00, 0x00])),
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
        #expect(bootstrap.controls.isoValues == ISOPickerPolicy.highBaseOptions)
        #expect(bootstrap.controls.shutterValues == ["90°", "180°", "360°"])
        #expect(
            bootstrap.controls.irisValues == [
                "f/2.8", "f/4.0", "f/5.6", "f/8.0", "f/11.0", "f/16.0", "f/22.0",
            ])
        #expect(bootstrap.controls.whiteBalanceValues.contains("5560K"))
        #expect(bootstrap.controls.focusAreas.contains("Subject"))
        #expect(bootstrap.controls.audioSensitivities.last == "20")
        #expect(bootstrap.controls.audioInputs == ["Microphone", "Line"])
        #expect(bootstrap.controls.baseISO == ["Low", "High"])
        #expect(bootstrap.controls.shutterModes == ["Speed", "Angle"])
        #expect(bootstrap.controls.shutterLocks == ["Unlocked", "Locked"])
        #expect(bootstrap.controls.resolutionFrameRates == ["6K · 25p", "4K · 60p"])
        #expect(bootstrap.controls.codecs == ["R3D NE", "H.265"])
        #expect(bootstrap.controls.vibrationReduction == ["OFF", "ON", "SPORT"])
        #expect(bootstrap.controls.electronicVR.isEmpty)
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

    @Test func rawCodecChangesRefreshZRFrameSizeModesAndPreserveExactWrites() throws {
        let h265: UInt32 = 0x0001_0A01
        let r3dNE: UInt32 = 0x0031_0A03
        let nRAW: UInt32 = 0x0002_0C02
        let h265ScreenSize: UInt64 = 0x0F00_0870_003C_0000
        let fx6K25 = UInt64(6_048) << 48 | UInt64(3_402) << 32 | UInt64(25) << 16
        let fx4K50 = UInt64(4_032) << 48 | UInt64(2_268) << 32 | UInt64(50) << 16
        let dx4K100 = UInt64(3_984) << 48 | UInt64(2_240) << 32 | UInt64(100) << 16

        var options = FakeZRServer.Options()
        options.movieFileTypeRaw = h265
        options.movieRecordScreenSizeRaw = h265ScreenSize
        options.descriptorEnumOverrides[.movieFileType] = [h265, r3dNE, nRAW]
        options.screenSizeModesByFileType = [
            h265: [h265ScreenSize],
            r3dNE: [fx6K25, fx4K50, dx4K100],
            nRAW: [fx6K25, fx4K50, dx4K100],
        ]
        let server = try FakeZRServer(options: options)
        defer { server.stop() }
        let session = try connect(to: server)
        defer { session.disconnect() }

        let bootstrap = session.refreshAndroidPropertySnapshot(.bootstrap)
        #expect(bootstrap.controls.codec == "H.265")
        #expect(bootstrap.controls.resolutionFrameRate == "4K · 60p")
        #expect(bootstrap.controls.resolutionFrameRates == ["4K · 60p"])

        let screenSizeDescriptorReadsBeforeCodecChange =
            server.receivedRequests().filter {
                $0.operation == .getDevicePropDescEx
                    && $0.parameters.first == PTPPropertyCode.movieRecordScreenSize.rawValue
            }.count
        server.setCameraMovieFileType(r3dNE)

        let r3dReadback = session.refreshAndroidPropertySnapshot(
            .propertyChanged(PTPPropertyCode.movieFileType.rawValue))
        #expect(r3dReadback.result == .accepted)
        #expect(r3dReadback.controls.codec == "R3D NE")
        #expect(r3dReadback.controls.resolutionFrameRate == "[FX] 6K · 25p")
        #expect(
            r3dReadback.controls.resolutionFrameRates
                == ["[FX] 6K · 25p", "[FX] 4K · 50p", "[DX] 4K · 100p"])
        #expect(
            server.receivedRequests().filter {
                $0.operation == .getDevicePropDescEx
                    && $0.parameters.first == PTPPropertyCode.movieRecordScreenSize.rawValue
            }.count == screenSizeDescriptorReadsBeforeCodecChange + 1)

        let writeBaseline = server.receivedPropertyWrites().count
        try session.applyAndroidControl(.resolutionFrameRate, label: "[DX] 4K · 100p")
        #expect(
            server.receivedPropertyWrites().dropFirst(writeBaseline).first
                == FakeZRPropertyWrite(
                    operation: .setDevicePropValue,
                    property: PTPPropertyCode.movieRecordScreenSize.rawValue,
                    data: Data(ByteCoding.uint64LE(dx4K100))))

        let dxReadback = session.refreshAndroidPropertySnapshot(
            .propertyChanged(PTPPropertyCode.movieRecordScreenSize.rawValue))
        #expect(dxReadback.controls.resolutionFrameRate == "[DX] 4K · 100p")

        let screenSizeDescriptorReadsBeforeNRAWWrite =
            server.receivedRequests().filter {
                $0.operation == .getDevicePropDescEx
                    && $0.parameters.first == PTPPropertyCode.movieRecordScreenSize.rawValue
            }.count
        let screenSizeValueReadsBeforeNRAWWrite =
            server.receivedRequests().filter {
                $0.operation == .getDevicePropValueEx
                    && $0.parameters.first == PTPPropertyCode.movieRecordScreenSize.rawValue
            }.count
        try session.applyAndroidControl(.codec, label: "N-RAW")
        #expect(
            server.receivedRequests().filter {
                $0.operation == .getDevicePropDescEx
                    && $0.parameters.first == PTPPropertyCode.movieRecordScreenSize.rawValue
            }.count == screenSizeDescriptorReadsBeforeNRAWWrite + 1)
        #expect(
            server.receivedRequests().filter {
                $0.operation == .getDevicePropValueEx
                    && $0.parameters.first == PTPPropertyCode.movieRecordScreenSize.rawValue
            }.count == screenSizeValueReadsBeforeNRAWWrite + 1)
        let nRAWReadback = session.refreshAndroidPropertySnapshot(
            .propertyChanged(PTPPropertyCode.batteryLevel.rawValue))
        #expect(nRAWReadback.result == .accepted)
        #expect(nRAWReadback.controls.codec == "N-RAW")
        #expect(nRAWReadback.controls.resolutionFrameRate == "[FX] 6K · 25p")
        #expect(
            nRAWReadback.controls.resolutionFrameRates
                == ["[FX] 6K · 25p", "[FX] 4K · 50p", "[DX] 4K · 100p"])
    }

    @Test func rawCodecChangeWithholdsStaleFrameSizeWhileD0A0ReadbackSettles() throws {
        let h265: UInt32 = 0x0001_0A01
        let r3dNE: UInt32 = 0x0031_0A03
        let h265ScreenSize: UInt64 = 0x0F00_0870_003C_0000
        let fx6K25 = UInt64(6_048) << 48 | UInt64(3_402) << 32 | UInt64(25) << 16
        let dx4K100 = UInt64(3_984) << 48 | UInt64(2_240) << 32 | UInt64(100) << 16

        var options = FakeZRServer.Options()
        options.movieFileTypeRaw = h265
        options.movieRecordScreenSizeRaw = h265ScreenSize
        options.descriptorEnumOverrides[.movieFileType] = [h265, r3dNE]
        options.screenSizeModesByFileType = [
            h265: [h265ScreenSize],
            r3dNE: [fx6K25, dx4K100],
        ]
        options.shortPropertyCodesAfterFirstRead = [PTPPropertyCode.movieRecordScreenSize.rawValue]
        let server = try FakeZRServer(options: options)
        defer { server.stop() }
        let session = try connect(to: server)
        defer { session.disconnect() }

        let bootstrap = session.refreshAndroidPropertySnapshot(.bootstrap)
        #expect(bootstrap.controls.resolutionFrameRate == "4K · 60p")

        server.setCameraMovieFileType(r3dNE)
        let settlingReadback = session.refreshAndroidPropertySnapshot(
            .propertyChanged(PTPPropertyCode.movieFileType.rawValue))
        #expect(settlingReadback.result == .transportFailed)
        #expect(settlingReadback.controls.codec == "R3D NE")
        #expect(settlingReadback.controls.resolutionFrameRate == nil)
        #expect(
            settlingReadback.controls.resolutionFrameRates
                == ["[FX] 6K · 25p", "[DX] 4K · 100p"])
    }

    @Test func rawCodecPollRefreshesFrameSizeModesWhenEventIsMissed() throws {
        let h265: UInt32 = 0x0001_0A01
        let r3dNE: UInt32 = 0x0031_0A03
        let h265ScreenSize: UInt64 = 0x0F00_0870_003C_0000
        let fx6K25 = UInt64(6_048) << 48 | UInt64(3_402) << 32 | UInt64(25) << 16
        let dx4K100 = UInt64(3_984) << 48 | UInt64(2_240) << 32 | UInt64(100) << 16

        var options = FakeZRServer.Options()
        options.movieFileTypeRaw = h265
        options.movieRecordScreenSizeRaw = h265ScreenSize
        options.descriptorEnumOverrides[.movieFileType] = [h265, r3dNE]
        options.screenSizeModesByFileType = [
            h265: [h265ScreenSize],
            r3dNE: [fx6K25, dx4K100],
        ]
        let server = try FakeZRServer(options: options)
        defer { server.stop() }
        let session = try connect(to: server)
        defer { session.disconnect() }

        let bootstrap = session.refreshAndroidPropertySnapshot(.bootstrap)
        #expect(bootstrap.controls.codec == "H.265")
        #expect(bootstrap.controls.resolutionFrameRates == ["4K · 60p"])
        let screenSizeDescriptorReadsBeforeCodecChange =
            server.receivedRequests().filter {
                $0.operation == .getDevicePropDescEx
                    && $0.parameters.first == PTPPropertyCode.movieRecordScreenSize.rawValue
            }.count

        // The event may be delayed, dropped, or reordered. The regular monitor poll must still
        // invalidate and rebuild the codec-dependent D0A0 descriptor after it observes D0AF.
        server.setCameraMovieFileType(r3dNE)
        let requestBaseline = server.receivedRequests().count
        let pollOrder = PTPIPClientSession.androidMonitorPollOrder(isRecording: false)
        guard let codecPollIndex = pollOrder.firstIndex(of: .movieFileType) else {
            Issue.record("The live monitor poll must include MovFileType.")
            return
        }
        var r3dReadback = bootstrap
        for _ in 0...codecPollIndex {
            r3dReadback = session.refreshAndroidPropertySnapshot(.next(isRecording: false))
        }

        #expect(r3dReadback.result == .accepted)
        #expect(r3dReadback.controls.codec == "R3D NE")
        #expect(r3dReadback.controls.resolutionFrameRate == "[FX] 6K · 25p")
        #expect(
            r3dReadback.controls.resolutionFrameRates
                == ["[FX] 6K · 25p", "[DX] 4K · 100p"])
        #expect(
            server.receivedRequests().filter {
                $0.operation == .getDevicePropDescEx
                    && $0.parameters.first == PTPPropertyCode.movieRecordScreenSize.rawValue
            }.count == screenSizeDescriptorReadsBeforeCodecChange + 1)
        // Codec change must re-read MovFileType then rebuild MovScreenSize. Extra follow-on
        // screen-size samples (poll-index cadence) may trail the triple; match the sequence, not
        // a hard-coded "last N" that breaks when the live poll order gains properties.
        let afterBaseline = Array(server.receivedRequests().dropFirst(requestBaseline))
        let expectedCodecThenScreenRebuild = [
            FakeZRRequest(
                operation: .getDevicePropValueEx,
                parameters: [PTPPropertyCode.movieFileType.rawValue],
                dataPhase: .dataIn),
            FakeZRRequest(
                operation: .getDevicePropDescEx,
                parameters: [PTPPropertyCode.movieRecordScreenSize.rawValue],
                dataPhase: .dataIn),
            FakeZRRequest(
                operation: .getDevicePropValueEx,
                parameters: [PTPPropertyCode.movieRecordScreenSize.rawValue],
                dataPhase: .dataIn),
        ]
        let hasCodecThenScreenRebuild: Bool = {
            guard afterBaseline.count >= expectedCodecThenScreenRebuild.count else { return false }
            let needle = expectedCodecThenScreenRebuild
            for start in 0...(afterBaseline.count - needle.count) {
                if Array(afterBaseline[start..<(start + needle.count)]) == needle {
                    return true
                }
            }
            return false
        }()
        #expect(hasCodecThenScreenRebuild)
    }

    @Test func rawImageAreaLabelsAreRestrictedToNikonZR() throws {
        let r3dNE: UInt32 = 0x0031_0A03
        let fx6K25 = UInt64(6_048) << 48 | UInt64(3_402) << 32 | UInt64(25) << 16
        let dx4K100 = UInt64(3_984) << 48 | UInt64(2_240) << 32 | UInt64(100) << 16

        func resolutionFrameRates(model: String) throws -> [String] {
            var options = FakeZRServer.Options()
            options.model = model
            options.movieFileTypeRaw = r3dNE
            options.movieRecordScreenSizeRaw = fx6K25
            options.descriptorEnumOverrides[.movieFileType] = [r3dNE]
            options.screenSizeModesByFileType = [r3dNE: [fx6K25, dx4K100]]
            let server = try FakeZRServer(options: options)
            defer { server.stop() }
            let session = try connect(to: server)
            defer { session.disconnect() }
            return session.refreshAndroidPropertySnapshot(.bootstrap).controls.resolutionFrameRates
        }

        #expect(
            try resolutionFrameRates(model: "ZR")
                == ["[FX] 6K · 25p", "[DX] 4K · 100p"])
        #expect(
            try resolutionFrameRates(model: "Z8")
                == ["6K · 25p", "4K · 100p"])
    }

    @Test func dynamicAndroidControlsPreserveAdvertisedRawValuesEndToEnd() throws {
        var options = FakeZRServer.Options()
        options.descriptorEnumOverrides = [
            .movieFNumber: [400, 560],
            .movieWBColorTemp: [5_000, 5_600],
            .movieWhiteBalance: [0x8012, 0x0004],
            .movieFocusMode: [3],
            .movieFocusMeteringMode: [0x8010],
            .movieAFSubjectDetection: [6],
            .movieAudioInputSensitivity: [7],
            .audioInputSelection: [2],
            .movWindNoiseReduction: [0],
            .movieAttenuator: [1],
            .movie32BitFloatAudioRecording: [1],
        ]
        let server = try FakeZRServer(options: options)
        defer { server.stop() }
        let session = try connect(to: server)
        defer { session.disconnect() }

        let controls = session.refreshAndroidPropertySnapshot(.bootstrap).controls
        #expect(controls.irisValues == ["f/4.0", "f/5.6"])
        #expect(controls.whiteBalanceValues == ["5000K", "5600K", "Sunny"])
        #expect(controls.focusModes == ["AF-S", "AF-C", "AF-F", "MF"])
        #expect(controls.focusAreas == ["Single"])
        #expect(controls.focusSubjects == ["Airplane"])
        #expect(controls.audioSensitivities == ["7"])
        #expect(controls.audioInputs == ["Line"])
        #expect(controls.windFilters == ["OFF"])
        #expect(controls.attenuators == ["ON"])
        #expect(controls.audio32BitFloat == ["ON"])

        try session.applyAndroidControl(.iris, label: "f/5.6")
        try session.applyAndroidControl(.whiteBalance, label: "5000K")
        try session.applyAndroidControl(.focusMode, label: "AF-S")
        try session.applyAndroidControl(.focusArea, label: "Single")
        try session.applyAndroidControl(.focusSubject, label: "Airplane")
        try session.applyAndroidControl(.audioSensitivity, label: "7")
        try session.applyAndroidControl(.audioInput, label: "Line")
        try session.applyAndroidControl(.windFilter, label: "OFF")
        try session.applyAndroidControl(.attenuator, label: "ON")
        try session.applyAndroidControl(.audio32BitFloat, label: "ON")

        #expect(
            server.receivedPropertyWrites()
                == [
                    FakeZRPropertyWrite(
                        operation: .setDevicePropValue,
                        property: PTPPropertyCode.movieFNumber.rawValue,
                        data: Data(ByteCoding.uint16LE(560))),
                    FakeZRPropertyWrite(
                        operation: .setDevicePropValue,
                        property: PTPPropertyCode.movieWhiteBalance.rawValue,
                        data: Data(ByteCoding.uint16LE(0x8012))),
                    FakeZRPropertyWrite(
                        operation: .setDevicePropValue,
                        property: PTPPropertyCode.movieWBColorTemp.rawValue,
                        data: Data(ByteCoding.uint16LE(5_000))),
                    FakeZRPropertyWrite(
                        operation: .setDevicePropValue,
                        property: PTPPropertyCode.movieFocusMode.rawValue,
                        data: Data([0])),
                    FakeZRPropertyWrite(
                        operation: .setDevicePropValue,
                        property: PTPPropertyCode.movieFocusMeteringMode.rawValue,
                        data: Data(ByteCoding.uint16LE(0x8010))),
                    FakeZRPropertyWrite(
                        operation: .setDevicePropValueEx,
                        property: PTPPropertyCode.movieAFSubjectDetection.rawValue,
                        data: Data([6])),
                    FakeZRPropertyWrite(
                        operation: .setDevicePropValueEx,
                        property: PTPPropertyCode.movieAudioInputSensitivity.rawValue,
                        data: Data([7])),
                    FakeZRPropertyWrite(
                        operation: .setDevicePropValueEx,
                        property: PTPPropertyCode.audioInputSelection.rawValue,
                        data: Data([2])),
                    FakeZRPropertyWrite(
                        operation: .setDevicePropValue,
                        property: PTPPropertyCode.movWindNoiseReduction.rawValue,
                        data: Data([0])),
                    FakeZRPropertyWrite(
                        operation: .setDevicePropValue,
                        property: PTPPropertyCode.movieAttenuator.rawValue,
                        data: Data([1])),
                    FakeZRPropertyWrite(
                        operation: .setDevicePropValueEx,
                        property: PTPPropertyCode.movie32BitFloatAudioRecording.rawValue,
                        data: Data([1])),
                ])

        let rejectedBaseline = server.receivedPropertyWrites().count
        #expect(throws: PTPIPClientSessionError.unsupportedAndroidControl("iris", "f/2.8")) {
            try session.applyAndroidControl(.iris, label: "f/2.8")
        }
        #expect(
            throws: PTPIPClientSessionError.unsupportedAndroidControl(
                "audioInput", "Microphone")
        ) {
            try session.applyAndroidControl(.audioInput, label: "Microphone")
        }
        #expect(server.receivedPropertyWrites().count == rejectedBaseline)
    }

    @Test func nikonZRFallbacksAreModelScopedAndFailClosedElsewhere() throws {
        let omittedDescriptors: [PTPPropertyCode: [UInt32]] = [
            .movieFNumber: [],
            .movieWBColorTemp: [],
            .movieWhiteBalance: [],
            .movieFocusMode: [],
            .movieFocusMeteringMode: [],
            .movieAFSubjectDetection: [],
            .movieAudioInputSensitivity: [],
            .audioInputSelection: [],
            .movWindNoiseReduction: [],
            .movieAttenuator: [],
            .movie32BitFloatAudioRecording: [],
            .movieBaseISO: [],
            .movieVibrationReduction: [],
            .electronicVR: [],
        ]

        func controls(model: String) throws -> AndroidCameraControlCapabilities {
            var options = FakeZRServer.Options()
            options.model = model
            options.descriptorEnumOverrides = omittedDescriptors
            let server = try FakeZRServer(options: options)
            defer { server.stop() }
            let session = try connect(to: server)
            defer { session.disconnect() }
            _ = session.refreshAndroidPropertySnapshot(.bootstrap)
            for property in [
                PTPPropertyCode.focalLength, .lensFocalMin, .lensFocalMax,
            ] {
                _ = session.refreshAndroidPropertySnapshot(.propertyChanged(property.rawValue))
            }
            return session.refreshAndroidPropertySnapshot(
                .propertyChanged(PTPPropertyCode.lensApertureMin.rawValue)
            ).controls
        }

        let zr = try controls(model: "ZR")
        #expect(zr.isoValues == ISOPickerPolicy.highBaseOptions)
        #expect(!zr.irisValues.isEmpty)
        #expect(!zr.whiteBalanceValues.isEmpty)
        #expect(zr.focusModes == ["AF-S", "AF-C", "AF-F", "MF"])
        #expect(!zr.focusAreas.isEmpty)
        #expect(!zr.focusSubjects.isEmpty)
        #expect(!zr.audioSensitivities.isEmpty)
        #expect(zr.audioInputs == ["Microphone", "Line"])
        #expect(zr.vibrationReduction == ["OFF", "ON", "SPORT"])
        #expect(zr.electronicVR.isEmpty)

        let z8 = try controls(model: "Z8")
        #expect(z8.isoValues.isEmpty)
        #expect(z8.irisValues.isEmpty)
        #expect(z8.whiteBalanceValues.isEmpty)
        #expect(z8.focusModes.isEmpty)
        #expect(z8.focusAreas.isEmpty)
        #expect(z8.focusSubjects.isEmpty)
        #expect(z8.audioSensitivities.isEmpty)
        #expect(z8.audioInputs.isEmpty)
        #expect(z8.windFilters.isEmpty)
        #expect(z8.attenuators.isEmpty)
        #expect(z8.audio32BitFloat.isEmpty)
        #expect(z8.baseISO.isEmpty)
        #expect(z8.vibrationReduction.isEmpty)
        #expect(z8.electronicVR.isEmpty)
    }

    @Test func isoOptionsTrackTheActiveR3DBaseCircuit() throws {
        let server = try FakeZRServer()
        defer { server.stop() }
        let session = try connect(to: server)
        defer { session.disconnect() }

        let high = session.refreshAndroidPropertySnapshot(.bootstrap).controls
        #expect(high.isoValues == ISOPickerPolicy.highBaseOptions)
        // Capability lists still track the active dual-base circuit for the UI ladder.
        // Encoded numeric ISO is still written — the body is the range authority (and Auto
        // can park outside the fixed ladder). Wrong-circuit labels are no longer hard-rejected
        // as "not supported" after a successful body write.
        try session.applyAndroidControl(.iso, label: "1600")
        try session.applyAndroidControl(.iso, label: "800")
        try session.applyAndroidControl(.baseISO, label: "Low")

        let low = session.refreshAndroidPropertySnapshot(
            .propertyChanged(PTPPropertyCode.movieBaseISO.rawValue)
        ).controls
        #expect(low.isoValues == ISOPickerPolicy.lowBaseOptions)
        try session.applyAndroidControl(.iso, label: "800")
        try session.applyAndroidControl(.iso, label: "25600")
    }

    @Test func encodableISOOutsideCapabilityLadderIsStillWritten() throws {
        // Auto can report 51200 while the manual UI ladder tops out at 25600. Capability
        // membership must not flash "not supported" when the shared encoder can still write.
        var options = FakeZRServer.Options()
        options.movieFileTypeRaw = 0x0001_0A01  // H.265 — unified ladder
        let server = try FakeZRServer(options: options)
        defer { server.stop() }
        let session = try connect(to: server)
        defer { session.disconnect() }
        _ = session.refreshAndroidPropertySnapshot(.bootstrap)

        let before = server.receivedPropertyWrites().count
        try session.applyAndroidControl(.iso, label: "51200")
        #expect(server.receivedPropertyWrites().count == before + 1)
        #expect(
            server.receivedPropertyWrites().last?.property
                == PTPPropertyCode.movieExposureIndex.rawValue)
    }

    @Test func electronicVRIsRejectedBeforeWritingForRawOrUnknownCodec() throws {
        let rawServer = try FakeZRServer()
        defer { rawServer.stop() }
        let rawSession = try connect(to: rawServer)
        defer { rawSession.disconnect() }
        _ = rawSession.refreshAndroidPropertySnapshot(.bootstrap)

        #expect(
            throws: PTPIPClientSessionError.unsupportedAndroidControl("electronicVR", "ON")
        ) {
            try rawSession.applyAndroidControl(.electronicVR, label: "ON")
        }
        #expect(rawServer.receivedPropertyWrites().isEmpty)

        let unknownServer = try FakeZRServer()
        defer { unknownServer.stop() }
        let unknownSession = try connect(to: unknownServer)
        defer { unknownSession.disconnect() }
        #expect(
            throws: PTPIPClientSessionError.unsupportedAndroidControl("electronicVR", "ON")
        ) {
            try unknownSession.applyAndroidControl(.electronicVR, label: "ON")
        }
        #expect(unknownServer.receivedPropertyWrites().isEmpty)

        var encodedUnknownOptions = FakeZRServer.Options()
        encodedUnknownOptions.movieFileTypeRaw = 0x007F_0A01
        encodedUnknownOptions.descriptorEnumOverrides[.movieFileType] = [
            0x007F_0A01, 0x0001_0A01,
        ]
        let encodedUnknownServer = try FakeZRServer(options: encodedUnknownOptions)
        defer { encodedUnknownServer.stop() }
        let encodedUnknownSession = try connect(to: encodedUnknownServer)
        defer { encodedUnknownSession.disconnect() }
        let encodedUnknown = encodedUnknownSession.refreshAndroidPropertySnapshot(.bootstrap)
        #expect(encodedUnknown.controls.electronicVR.isEmpty)
        #expect(
            throws: PTPIPClientSessionError.unsupportedAndroidControl("electronicVR", "ON")
        ) {
            try encodedUnknownSession.applyAndroidControl(.electronicVR, label: "ON")
        }
        #expect(encodedUnknownServer.receivedPropertyWrites().isEmpty)
    }

    @Test func baseISOIsUnavailableOutsideTheSharedDualBaseCodecPolicy() throws {
        var options = FakeZRServer.Options()
        options.movieFileTypeRaw = 0x0001_0A01  // H.265
        let server = try FakeZRServer(options: options)
        defer { server.stop() }
        let session = try connect(to: server)
        defer { session.disconnect() }

        let bootstrap = session.refreshAndroidPropertySnapshot(.bootstrap)
        #expect(bootstrap.controls.isoValues == ISOPickerPolicy.unifiedOptions)
        #expect(bootstrap.controls.baseISO.isEmpty)
        #expect(bootstrap.controls.electronicVR == ["OFF", "ON"])
        #expect(throws: PTPIPClientSessionError.unsupportedAndroidControl("baseISO", "Low")) {
            try session.applyAndroidControl(.baseISO, label: "Low")
        }
        #expect(server.receivedPropertyWrites().isEmpty)
    }

    @Test func readOnlyDescriptorNeverAuthorizesItsFallbackWrite() throws {
        var options = FakeZRServer.Options()
        options.readOnlyDescriptorCodes = [PTPPropertyCode.movieFNumber.rawValue]
        let server = try FakeZRServer(options: options)
        defer { server.stop() }
        let session = try connect(to: server)
        defer { session.disconnect() }

        let bootstrap = session.refreshAndroidPropertySnapshot(.bootstrap)
        #expect(bootstrap.result == .unsupported)
        for property in [
            PTPPropertyCode.focalLength, .lensFocalMin, .lensFocalMax, .lensApertureMin,
        ] {
            _ = session.refreshAndroidPropertySnapshot(.propertyChanged(property.rawValue))
        }
        let readback = session.refreshAndroidPropertySnapshot(.propertyChanged(0xDEAD))
        #expect(readback.properties.lens == "24-70mm f/2.8")
        #expect(readback.controls.irisValues.isEmpty)
        #expect(throws: PTPIPClientSessionError.unsupportedAndroidControl("iris", "f/2.8")) {
            try session.applyAndroidControl(.iris, label: "f/2.8")
        }
        #expect(server.receivedPropertyWrites().isEmpty)
    }

    @Test func descriptorIdentityAndDataTypeMismatchesStayIsolated() throws {
        func bootstrap(_ options: FakeZRServer.Options) throws -> AndroidCameraPropertyReadback {
            let server = try FakeZRServer(options: options)
            defer { server.stop() }
            let session = try connect(to: server)
            defer { session.disconnect() }
            return session.refreshAndroidPropertySnapshot(.bootstrap)
        }

        // A wrong identity on D0A0 must not abort the whole catalog as transportFailed.
        // Flexible enum scan may still recover the form tail; invented packs are never used.
        var identityOptions = FakeZRServer.Options()
        identityOptions.descriptorIdentityOverrides[
            PTPPropertyCode.movieRecordScreenSize.rawValue
        ] = PTPPropertyCode.movieFileType.rawValue
        let invalidIdentity = try bootstrap(identityOptions)
        #expect(invalidIdentity.result == .accepted || invalidIdentity.result == .unsupported)
        #expect(invalidIdentity.controls.codecs.contains("R3D NE"))
        #expect(!invalidIdentity.controls.irisValues.isEmpty)

        // Wrong data type on MovFileType: ZR codec fallback + remaining catalog survive.
        var typeOptions = FakeZRServer.Options()
        typeOptions.descriptorDataTypeOverrides[PTPPropertyCode.movieFileType.rawValue] = 0x0004
        let invalidType = try bootstrap(typeOptions)
        #expect(invalidType.result == .accepted)
        #expect(invalidType.controls.codecs.contains("R3D NE"))
        #expect(!invalidType.controls.resolutionFrameRates.isEmpty)
    }

    @Test func partialDescriptorTransportFailureRetainsTheLastCompleteCapabilityGeneration() throws
    {
        var options = FakeZRServer.Options()
        options.malformedDescriptorCodesAfterFirstRead = [
            PTPPropertyCode.movieAudioInputSensitivity.rawValue
        ]
        let server = try FakeZRServer(options: options)
        defer { server.stop() }
        let session = try connect(to: server)
        defer { session.disconnect() }

        let first = session.refreshAndroidPropertySnapshot(.bootstrap)
        #expect(first.result == .accepted)
        #expect(!first.controls.codecs.isEmpty)
        #expect(!first.controls.audioSensitivities.isEmpty)
        let retainedCodecs = first.controls.codecs

        // A later bootstrap that hits a malformed single descriptor must not blank every
        // control. Malformed parse is unsupported (not transport) so the new generation
        // still completes with ZR fallbacks for the bad property and retains others.
        let second = session.refreshAndroidPropertySnapshot(.bootstrap)
        #expect(second.result == .unsupported || second.result == .accepted)
        #expect(second.controls.codecs == retainedCodecs)
        #expect(!second.controls.audioSensitivities.isEmpty)
        try session.applyAndroidControl(.codec, label: retainedCodecs[0])
        #expect(!server.receivedPropertyWrites().isEmpty)
    }

    @Test func kelvinOptionsRequireAnAdvertisedColorTemperatureMode() throws {
        var options = FakeZRServer.Options()
        options.descriptorEnumOverrides[.movieWBColorTemp] = [5_000]
        options.descriptorEnumOverrides[.movieWhiteBalance] = [0x0004]
        let server = try FakeZRServer(options: options)
        defer { server.stop() }
        let session = try connect(to: server)
        defer { session.disconnect() }

        let controls = session.refreshAndroidPropertySnapshot(.bootstrap).controls
        #expect(controls.whiteBalanceValues == ["Sunny"])
        #expect(
            throws: PTPIPClientSessionError.unsupportedAndroidControl(
                "whiteBalance", "5000K")
        ) {
            try session.applyAndroidControl(.whiteBalance, label: "5000K")
        }
        #expect(server.receivedPropertyWrites().isEmpty)
    }

    @Test func captureBarLabelsEncodeBeforeDescriptorCapabilitiesLand() throws {
        // Capture-bar / top-bar pickers open on iOS policy ladders even while the
        // Android capability snapshot is still empty. Those labels must still
        // encode through the shared core — an empty domain must not hard-reject
        // every write with "not supported".
        let server = try FakeZRServer()
        defer { server.stop() }
        let session = try connect(to: server)
        defer { session.disconnect() }

        // Seed only the property values the shared shutter/ISO encoders need —
        // no control-descriptor bootstrap, so capability option lists stay empty.
        _ = session.refreshAndroidPropertySnapshot(
            .propertyChanged(PTPPropertyCode.movieShutterMode.rawValue))
        _ = session.refreshAndroidPropertySnapshot(
            .propertyChanged(PTPPropertyCode.movieISOSensitivity.rawValue))

        let emptyDomain = session.refreshAndroidPropertySnapshot(
            .propertyChanged(PTPPropertyCode.batteryLevel.rawValue)
        ).controls
        #expect(emptyDomain.isoValues.isEmpty)
        #expect(emptyDomain.shutterValues.isEmpty)
        #expect(emptyDomain.focusModes.isEmpty)

        try session.applyAndroidControl(.iso, label: "800")
        try session.applyAndroidControl(.shutter, label: "180°")
        try session.applyAndroidControl(.focusMode, label: "AF-C")
        try session.applyAndroidControl(.shutterMode, label: "Speed")
        try session.applyAndroidControl(.shutterLock, label: "Locked")
        try session.applyAndroidControl(.vibrationReduction, label: "ON")

        let writes = server.receivedPropertyWrites()
        // Without a dual-base codec in the snapshot, ISO writes MovieExposureIndex (0xD1AA).
        #expect(
            writes.contains {
                $0.property == PTPPropertyCode.movieExposureIndex.rawValue
            })
        #expect(
            writes.contains {
                $0.property == PTPPropertyCode.movieShutterAngle.rawValue
            })
        #expect(
            writes.contains {
                $0.property == PTPPropertyCode.movieFocusMode.rawValue
            })
        #expect(
            writes.contains {
                $0.property == PTPPropertyCode.movieShutterMode.rawValue
            })
        #expect(
            writes.contains {
                $0.property == PTPPropertyCode.movieTVLockSetting.rawValue
            })
        #expect(
            writes.contains {
                $0.property == PTPPropertyCode.movieVibrationReduction.rawValue
            })

        // Codec/resolution stay fail-closed until the body advertises raw modes.
        #expect(
            throws: PTPIPClientSessionError.unsupportedAndroidControl(
                "codec", "H.265")
        ) {
            try session.applyAndroidControl(.codec, label: "H.265")
        }
        #expect(
            throws: PTPIPClientSessionError.unsupportedAndroidControl(
                "resolutionFrameRate", "6K · 25p")
        ) {
            try session.applyAndroidControl(.resolutionFrameRate, label: "6K · 25p")
        }
    }

    @Test func acceptedControlWriteRequiresMatchingAuthoritativeReadback() throws {
        var options = FakeZRServer.Options()
        // Default fake codec is R3D NE (dual-base) → ISO writes MovieISOSensitivity.
        options.ignoredPropertyWrites = [PTPPropertyCode.movieISOSensitivity.rawValue]
        let server = try FakeZRServer(options: options)
        defer { server.stop() }
        let session = try connect(to: server)
        defer { session.disconnect() }
        _ = session.refreshAndroidPropertySnapshot(.bootstrap)

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
        // ZR falls back to lab-proven MovFileType raws when the descriptor is rejected so CODEC
        // stays writable; e-VR stays empty because the active codec is raw (or unknown).
        #expect(bootstrap.controls.codecs.contains("R3D NE"))
        #expect(bootstrap.controls.electronicVR.isEmpty)
        #expect(bootstrap.controls.resolutionFrameRates == ["6K · 25p", "4K · 60p"])
        #expect(bootstrap.controls.shutterValues == ["90°", "180°", "360°"])
        #expect(bootstrap.controls.vibrationReduction == ["OFF", "ON", "SPORT"])
    }

    @Test func resolutionWriteUsesExactAdvertisedCatalogPackLikeIOS() throws {
        // iOS baseline: label → first matching camera-advertised raw. No live-pack rewrite.
        let enum25 = UInt64(6_048) << 48 | UInt64(3_402) << 32 | UInt64(25) << 16
        let enum30 = UInt64(6_048) << 48 | UInt64(3_402) << 32 | UInt64(30) << 16

        let r3d: UInt32 = 0x0031_0A03
        var options = FakeZRServer.Options()
        options.movieFileTypeRaw = r3d
        // FakeZR GetDevicePropValue uses the first listed mode when the map is set.
        options.movieRecordScreenSizeRaw = enum30
        options.descriptorEnumOverrides[.movieFileType] = [r3d]
        options.screenSizeModesByFileType = [r3d: [enum30, enum25]]
        let server = try FakeZRServer(options: options)
        defer { server.stop() }
        let session = try connect(to: server)
        defer { session.disconnect() }

        let bootstrap = session.refreshAndroidPropertySnapshot(.bootstrap)
        let label25 =
            bootstrap.controls.resolutionFrameRates.first { $0.contains("25p") } ?? "6K · 25p"
        #expect(bootstrap.controls.resolutionFrameRates.contains { $0.contains("25p") })
        let before = server.receivedPropertyWrites().count
        try session.applyAndroidControl(.resolutionFrameRate, label: label25)
        let writes = Array(server.receivedPropertyWrites().dropFirst(before))
        #expect(writes.count == 1)
        #expect(writes[0].property == PTPPropertyCode.movieRecordScreenSize.rawValue)
        #expect(writes[0].data == Data(ByteCoding.uint64LE(enum25)))
    }

    @Test func screenSizeReadbackMatchesOnDecodedGeometryNotExactBytes() {
        let writtenRaw = UInt64(6_048) << 48 | UInt64(3_402) << 32 | UInt64(25) << 16
        let liveRaw = writtenRaw | 0x8000
        let write = PTPCameraPropertyWrite.screenSize(raw: writtenRaw)
        #expect(
            PTPIPClientSession.propertyWriteMatchesReadback(
                write: write,
                readback: Data(ByteCoding.uint64LE(liveRaw))))
        #expect(
            !PTPIPClientSession.propertyWriteMatchesReadback(
                write: write,
                readback: Data(
                    ByteCoding.uint64LE(
                        UInt64(3_840) << 48 | UInt64(2_160) << 32 | UInt64(25) << 16))))
    }

    @Test func focusModeReadbackMatchesOnLabelIncludingDualMFRaws() {
        // Menu MF (4) vs lens-ring MF (3) both decode to "MF".
        let writeMF = PTPCameraPropertyWrite(
            property: .movieFocusMode, data: Data([4]))
        #expect(
            PTPIPClientSession.propertyWriteMatchesReadback(write: writeMF, readback: Data([4])))
        #expect(
            PTPIPClientSession.propertyWriteMatchesReadback(write: writeMF, readback: Data([3])))
        // AF-F must not match residual MF.
        let writeAFF = PTPCameraPropertyWrite(
            property: .movieFocusMode, data: Data([2]))
        #expect(
            PTPIPClientSession.propertyWriteMatchesReadback(write: writeAFF, readback: Data([2])))
        #expect(
            !PTPIPClientSession.propertyWriteMatchesReadback(write: writeAFF, readback: Data([3])))
    }

    @Test func invalidScreenSizeDescriptorDoesNotWipeTheControlCatalog() throws {
        // A single unparsable D0A0 used to be classified as transportFailed and aborted every
        // subsequent descriptor, leaving the whole Android control surface empty.
        var options = FakeZRServer.Options()
        options.descriptorIdentityOverrides = [
            PTPPropertyCode.movieRecordScreenSize.rawValue: 0xDEAD_BEEF
        ]
        let server = try FakeZRServer(options: options)
        defer { server.stop() }
        let session = try connect(to: server)
        defer { session.disconnect() }

        let bootstrap = session.refreshAndroidPropertySnapshot(.bootstrap)
        // Catalog still completes; other controls keep their descriptors.
        #expect(bootstrap.controls.irisValues.contains("f/2.8"))
        #expect(bootstrap.controls.codecs.contains("R3D NE"))
        #expect(bootstrap.controls.vibrationReduction == ["OFF", "ON", "SPORT"])
        // Flexible enum scan still recovers the form tail even with a wrong property-code header
        // (FakeZR keeps a valid enum block). No invented lab packs are used.
        #expect(bootstrap.controls.resolutionFrameRates.contains("6K · 25p"))
        try session.applyAndroidControl(.resolutionFrameRate, label: "4K · 60p")
        #expect(
            server.receivedPropertyWrites().contains {
                $0.property == PTPPropertyCode.movieRecordScreenSize.rawValue
            })
    }

    @Test func inventedScreenSizeFallbacksAreNeverOfferedOrWritten() throws {
        // Empty / rejected D0A0 must not surface lab-invented packs — those reboot real ZRs.
        var options = FakeZRServer.Options()
        options.unsupportedPropertyCodes = [PTPPropertyCode.movieRecordScreenSize.rawValue]
        let server = try FakeZRServer(options: options)
        defer { server.stop() }
        let session = try connect(to: server)
        defer { session.disconnect() }

        let bootstrap = session.refreshAndroidPropertySnapshot(.bootstrap)
        #expect(bootstrap.controls.resolutionFrameRates.isEmpty)
        #expect(
            throws: PTPIPClientSessionError.unsupportedAndroidControl(
                "resolutionFrameRate", "6K · 25p")
        ) {
            try session.applyAndroidControl(.resolutionFrameRate, label: "6K · 25p")
        }
        #expect(server.receivedPropertyWrites().isEmpty)
        // Other controls still land.
        #expect(!bootstrap.controls.codecs.isEmpty)
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
        _ = session.refreshAndroidPropertySnapshot(.bootstrap)

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
        _ = session.refreshAndroidPropertySnapshot(.bootstrap)

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
        _ = session.refreshAndroidPropertySnapshot(.bootstrap)

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

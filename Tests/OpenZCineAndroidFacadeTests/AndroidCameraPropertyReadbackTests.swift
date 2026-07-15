import OpenZCineCore
import Testing

@testable import OpenZCineAndroidFacade

struct AndroidCameraPropertyReadbackTests {
    private func connect(to server: FakeZRServer) throws -> PTPIPClientSession {
        try PTPIPClientSession.connect(
            host: "127.0.0.1",
            port: server.port,
            timeoutMilliseconds: 2_000)
    }

    @Test func bootstrapAndRoundRobinExposeOnlySemanticDecodedCameraState() throws {
        let server = try FakeZRServer()
        defer { server.stop() }
        let session = try connect(to: server)
        defer { session.disconnect() }

        let bootstrap = session.refreshAndroidPropertySnapshot(.bootstrap)

        #expect(bootstrap.result == .accepted)
        #expect(bootstrap.properties.iso == 800)
        #expect(bootstrap.properties.shutterMode == .angle)
        #expect(bootstrap.properties.shutterAngle == "180°")
        #expect(bootstrap.properties.shutterSpeed == "1/50")
        #expect(bootstrap.properties.fNumber == "f/2.8")
        #expect(bootstrap.properties.wbMode == "Color temp")
        #expect(bootstrap.properties.wbKelvin == 5_600)
        #expect(bootstrap.properties.batteryPercent == 80)
        #expect(bootstrap.properties.warningRaw == 0)
        #expect(bootstrap.storage?.totalCapacityBytes == 1_000_000_000_000)
        #expect(bootstrap.storage?.freeSpaceBytes == 500_000_000_000)
        #expect(bootstrap.controls.resolutionFrameRate == "6K · 25p")
        #expect(bootstrap.controls.codec == "R3D NE")
        #expect(bootstrap.controls.whiteBalanceTint == "Neutral")
        #expect(bootstrap.controls.isoValues == ISOPickerPolicy.highBaseOptions)
        #expect(bootstrap.controls.shutterValues == ["90°", "180°", "360°"])
        #expect(bootstrap.controls.irisValues.first == "f/2.8")
        #expect(bootstrap.controls.whiteBalanceValues.contains("5600K"))
        #expect(bootstrap.controls.focusModes.contains("AF-C"))
        #expect(bootstrap.controls.audioInputs == ["Microphone", "Line"])
        #expect(bootstrap.controls.baseISO == ["Low", "High"])
        #expect(bootstrap.controls.resolutionFrameRates == ["6K · 25p", "4K · 60p"])

        // One complete low-rate pass fills the fields intentionally omitted
        // from the bounded bootstrap (lens, focus, audio, VR, and grid).
        for _ in PTPPropertyCode.liveMonitorPollOrder {
            _ = session.refreshAndroidPropertySnapshot(.next(isRecording: false))
        }
        let complete = session.refreshAndroidPropertySnapshot(.propertyChanged(0xDEAD))
        let properties = complete.properties
        #expect(properties.exposureMode == "M")
        #expect(properties.lens == "24-70mm f/2.8")
        #expect(properties.focusMode == "AF-C")
        #expect(properties.focusArea == "Subject")
        #expect(properties.focusSubject == "People")
        #expect(properties.microphoneSensitivity == "Auto")
        #expect(properties.microphoneLevel == "12")
        #expect(properties.windNoiseReduction == "ON")
        #expect(properties.inputAttenuator == "OFF")
        #expect(properties.audioInput == "Line")
        #expect(properties.audioSensitivity == "Auto")
        #expect(properties.audio32BitFloat == "ON")
        #expect(properties.vibrationReduction == "SPORT")
        #expect(properties.electronicVR == "ON")
        #expect(properties.gridDisplay == "ON")

        let propertyReads =
            server.receivedRequests().filter { $0.operation == .getDevicePropValueEx }
        let expectedBootstrap = [
            PTPPropertyCode.movieISOSensitivity,
            .movieBaseISO,
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
        ].map(\.rawValue)
        let bootstrapReads = Array(
            propertyReads.prefix(expectedBootstrap.count).compactMap(\.parameters.first))
        #expect(bootstrapReads == expectedBootstrap)
        #expect(
            propertyReads.dropFirst(expectedBootstrap.count).first?.parameters.first
                == PTPPropertyCode.movieWbTuneColorTemp.rawValue)
        let roundRobinReads = Array(
            propertyReads.dropFirst(expectedBootstrap.count + 1)
                .prefix(PTPPropertyCode.liveMonitorPollOrder.count)
                .compactMap(\.parameters.first))
        #expect(roundRobinReads == PTPPropertyCode.liveMonitorPollOrder.map(\.rawValue))

        let wire = AndroidCameraPropertyReadbackWire.encode(complete)
        let fields = wireFields(wire)
        #expect(fields["result"] == "accepted")
        #expect(fields["iso"] == "800")
        #expect(fields["shutterMode"] == "angle")
        #expect(fields["temperatureStatus"] == "OK")
        #expect(fields["lens"] == "24-70mm f/2.8")
        #expect(fields["storageFreeSpaceBytes"] != nil)
        #expect(fields["resolutionFrameRate"] == "6K · 25p")
        #expect(fields["codecSelection"] == "R3D NE")
        #expect(fields["whiteBalanceTint"] == "Neutral")
        #expect(
            fields["options.iso"] == ISOPickerPolicy.highBaseOptions.joined(separator: "\u{1F}"))
        #expect(fields["options.iris"]?.contains("f/2.8") == true)
        #expect(fields["options.focusMode"]?.contains("AF-C") == true)
        #expect(fields["options.audioInput"] == "Microphone\u{1F}Line")
        #expect(fields["options.shutter"] == "90°\u{1F}180°\u{1F}360°")
        #expect(fields["options.codec"] == "R3D NE\u{1F}H.265")
        #expect(!wire.contains("D09E"))
    }

    @Test func unsupportedAndMediaOwnedReadbacksRemainNonTerminal() throws {
        var options = FakeZRServer.Options()
        options.unsupportedPropertyCodes.insert(PTPPropertyCode.movieISOSensitivity.rawValue)
        let server = try FakeZRServer(options: options)
        defer { server.stop() }
        let session = try connect(to: server)
        defer { session.disconnect() }

        let unsupported = session.refreshAndroidPropertySnapshot(
            .propertyChanged(PTPPropertyCode.movieISOSensitivity.rawValue))

        #expect(unsupported.result == .unsupported)
        #expect(unsupported.properties.iso == nil)

        let battery = session.refreshAndroidPropertySnapshot(
            .propertyChanged(PTPPropertyCode.batteryLevel.rawValue))
        #expect(battery.result == .accepted)
        #expect(battery.properties.batteryPercent == 80)

        let readsBeforeUnknownEvent =
            server.receivedRequests().filter { $0.operation == .getDevicePropValueEx }.count
        let unknown = session.refreshAndroidPropertySnapshot(.propertyChanged(0xDEAD))
        let readsAfterUnknownEvent =
            server.receivedRequests().filter { $0.operation == .getDevicePropValueEx }.count
        #expect(unknown.result == .accepted)
        #expect(readsAfterUnknownEvent == readsBeforeUnknownEvent)

        session.enterMediaMode()
        let mediaBusy = session.refreshAndroidPropertySnapshot(.next(isRecording: false))
        #expect(mediaBusy.result == .mediaBusy)
        #expect(mediaBusy.properties.batteryPercent == 80)
    }

    private func wireFields(_ wire: String) -> [String: String] {
        Dictionary(
            uniqueKeysWithValues: wire.split(separator: "\n").compactMap { line in
                guard let separator = line.firstIndex(of: "\t") else { return nil }
                return (
                    String(line[..<separator]),
                    String(line[line.index(after: separator)...])
                )
            })
    }
}

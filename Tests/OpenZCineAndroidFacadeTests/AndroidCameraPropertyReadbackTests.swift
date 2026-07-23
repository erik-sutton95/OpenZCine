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
        #expect(bootstrap.properties.wbKelvin == 5_560)
        #expect(bootstrap.properties.batteryPercent == 80)
        #expect(bootstrap.properties.warningRaw == 0)
        #expect(bootstrap.storage?.totalCapacityBytes == 1_000_000_000_000)
        #expect(bootstrap.storage?.freeSpaceBytes == 500_000_000_000)
        #expect(bootstrap.storageSlots.map(\.storageID) == [FakeZRMediaCard.storageID])
        #expect(bootstrap.storageSlots.map(\.slotNumber) == [1])
        #expect(bootstrap.controls.resolutionFrameRate == "6K · 25p")
        #expect(bootstrap.controls.codec == "R3D NE")
        #expect(bootstrap.controls.whiteBalanceTint == "Neutral")
        #expect(bootstrap.controls.isoValues == ISOPickerPolicy.highBaseOptions)
        #expect(bootstrap.controls.shutterValues == ["90°", "180°", "360°"])
        #expect(bootstrap.controls.irisValues.first == "f/2.8")
        #expect(bootstrap.controls.whiteBalanceValues.contains("5560K"))
        #expect(bootstrap.controls.focusModes.contains("AF-C"))
        #expect(bootstrap.controls.audioInputs == ["Microphone", "Line"])
        #expect(bootstrap.controls.baseISO == ["Low", "High"])
        #expect(bootstrap.controls.resolutionFrameRates == ["6K · 25p", "4K · 60p"])

        // Bootstrap already issued the full live-monitor set back-to-back. Steady-state
        // `.next` interleaves LiveViewSelector every other tick, so walk 2× the poll
        // order to visit every non-selector property at least once.
        let androidPollOrder = PTPIPClientSession.androidMonitorPollOrder(isRecording: false)
        for _ in 0..<(androidPollOrder.count * 2) {
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
        let expectedBootstrap = androidPollOrder.map(\.rawValue)
        let bootstrapReads = Array(
            propertyReads.prefix(expectedBootstrap.count).compactMap(\.parameters.first))
        #expect(bootstrapReads == expectedBootstrap)
        // After the full burst, bootstrap still refreshes WB tint via a value
        // read (descriptor path). Steady-state `.next` then resumes at index 0;
        // idle extras (periodic D0A0 / storage) may interleave, so only require
        // that every poll-order property appears again after the bootstrap.
        let afterBootstrap = propertyReads.dropFirst(expectedBootstrap.count)
            .compactMap(\.parameters.first)
        #expect(afterBootstrap.contains(PTPPropertyCode.movieWbTuneColorTemp.rawValue))
        for code in expectedBootstrap {
            #expect(afterBootstrap.contains(code))
        }

        let wire = AndroidCameraPropertyReadbackWire.encode(complete)
        let fields = wireFields(wire)
        #expect(fields["result"] == "accepted")
        #expect(fields["iso"] == "800")
        #expect(fields["shutterMode"] == "angle")
        #expect(fields["temperatureStatus"] == "OK")
        #expect(fields["lens"] == "24-70mm f/2.8")
        #expect(fields["storageFreeSpaceBytes"] != nil)
        #expect(fields["storageSlotCount"] == "1")
        #expect(fields["storageSlot.0.storageId"] == String(FakeZRMediaCard.storageID))
        #expect(fields["storageSlot.0.slotNumber"] == "1")
        #expect(fields["resolutionFrameRate"] == "6K · 25p")
        #expect(fields["codecSelection"] == "R3D NE")
        #expect(fields["tone"] == "Log3G10")
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

    @Test func bootstrapPreservesEveryValidCardInCameraOrder() throws {
        let secondStorageID: UInt32 = 0x0002_0001
        var options = FakeZRServer.Options()
        options.storageCards = [
            FakeZRStorageCard(
                storageID: FakeZRMediaCard.storageID,
                totalCapacityBytes: 954_000_000_000,
                freeSpaceBytes: 242_000_000_000),
            FakeZRStorageCard(
                storageID: secondStorageID,
                totalCapacityBytes: 512_000_000_000,
                freeSpaceBytes: 111_000_000_000),
        ]
        let server = try FakeZRServer(options: options)
        defer { server.stop() }
        let session = try connect(to: server)
        defer { session.disconnect() }

        let bootstrap = session.refreshAndroidPropertySnapshot(.bootstrap)

        #expect(bootstrap.result == .accepted)
        #expect(bootstrap.storage?.totalCapacityBytes == 954_000_000_000)
        #expect(bootstrap.storage?.freeSpaceBytes == 242_000_000_000)
        #expect(
            bootstrap.storageSlots.map(\.storageID) == [FakeZRMediaCard.storageID, secondStorageID])
        #expect(bootstrap.storageSlots.map(\.slotNumber) == [1, 2])
        #expect(
            bootstrap.storageSlots.map(\.storage.totalCapacityBytes) == [
                954_000_000_000, 512_000_000_000,
            ])
        #expect(
            bootstrap.storageSlots.map(\.storage.freeSpaceBytes) == [
                242_000_000_000, 111_000_000_000,
            ])

        let storageReads =
            server.receivedRequests().filter { $0.operation == .getStorageInfo }
        #expect(
            storageReads.compactMap(\.parameters.first) == [
                FakeZRMediaCard.storageID, secondStorageID,
            ])

        let fields = wireFields(AndroidCameraPropertyReadbackWire.encode(bootstrap))
        #expect(fields["storageSlotCount"] == "2")
        #expect(fields["storageSlot.0.storageId"] == String(FakeZRMediaCard.storageID))
        #expect(fields["storageSlot.0.slotNumber"] == "1")
        #expect(fields["storageSlot.0.totalCapacityBytes"] == "954000000000")
        #expect(fields["storageSlot.0.freeSpaceBytes"] == "242000000000")
        #expect(fields["storageSlot.1.storageId"] == String(secondStorageID))
        #expect(fields["storageSlot.1.slotNumber"] == "2")
        #expect(fields["storageSlot.1.totalCapacityBytes"] == "512000000000")
        #expect(fields["storageSlot.1.freeSpaceBytes"] == "111000000000")
    }

    @Test func slotsNumberByThePhysicalSlotInTheStorageID() throws {
        // The second body slot can be enumerated FIRST (vendor storage-list append
        // order) — the published slots must still read SLOT 1 / SLOT 2 by the
        // storage ID's high word, sorted, not by arrival order.
        let slotOneID: UInt32 = 0x0001_0001
        let slotTwoID: UInt32 = 0x0002_0001
        var options = FakeZRServer.Options()
        options.storageCards = [
            FakeZRStorageCard(
                storageID: slotTwoID,
                totalCapacityBytes: 512_000_000_000,
                freeSpaceBytes: 111_000_000_000),
            FakeZRStorageCard(
                storageID: slotOneID,
                totalCapacityBytes: 954_000_000_000,
                freeSpaceBytes: 242_000_000_000),
        ]
        let server = try FakeZRServer(options: options)
        defer { server.stop() }
        let session = try connect(to: server)
        defer { session.disconnect() }

        let bootstrap = session.refreshAndroidPropertySnapshot(.bootstrap)

        #expect(bootstrap.storageSlots.map(\.storageID) == [slotOneID, slotTwoID])
        #expect(bootstrap.storageSlots.map(\.slotNumber) == [1, 2])
        // The legacy single-card readout keeps the enumeration-first card.
        #expect(bootstrap.storage?.totalCapacityBytes == 512_000_000_000)

        let fields = wireFields(AndroidCameraPropertyReadbackWire.encode(bootstrap))
        #expect(fields["storageSlot.0.storageId"] == String(slotOneID))
        #expect(fields["storageSlot.0.slotNumber"] == "1")
        #expect(fields["storageSlot.1.storageId"] == String(slotTwoID))
        #expect(fields["storageSlot.1.slotNumber"] == "2")
    }

    @Test func loneSecondSlotCardKeepsItsPhysicalNumber() throws {
        // A single card living in body slot 2 publishes as slot 2 — the wire's
        // strictly-increasing contract allows the gap.
        func le64(_ value: UInt64) -> [UInt8] {
            (0..<8).map { UInt8((value >> ($0 * 8)) & 0xFF) }
        }
        let storage = try #require(
            PTPStorageInfo([1, 0, 2, 0, 3, 0] + le64(512_000_000_000) + le64(111_000_000_000)))
        let readback = AndroidCameraPropertyReadback(
            result: .accepted,
            properties: PTPCameraPropertySnapshot(),
            storage: nil,
            storageSlots: [
                AndroidCameraStorageSlot(storageID: 0x0002_0001, slotNumber: 2, storage: storage)
            ])
        let fields = wireFields(AndroidCameraPropertyReadbackWire.encode(readback))
        #expect(fields["storageSlotCount"] == "1")
        #expect(fields["storageSlot.0.slotNumber"] == "2")
    }

    @Test func mediaEntryClosesTheEmptyBootstrapStorageRace() throws {
        let secondStorageID: UInt32 = 0x0002_0001
        var options = FakeZRServer.Options()
        options.storageCards = [
            FakeZRStorageCard(
                storageID: FakeZRMediaCard.storageID,
                totalCapacityBytes: 954_000_000_000,
                freeSpaceBytes: 242_000_000_000),
            FakeZRStorageCard(
                storageID: secondStorageID,
                totalCapacityBytes: 512_000_000_000,
                freeSpaceBytes: 111_000_000_000),
        ]
        let server = try FakeZRServer(options: options)
        defer { server.stop() }
        let session = try connect(to: server)
        defer { session.disconnect() }

        // Media wins the race before any monitor bootstrap has populated the
        // accumulated property snapshot.
        let preparation = session.enterMediaModeForBrowse()
        let start = preparation.readback
        defer { session.exitMediaMode() }

        #expect(start.result == .mediaBusy)
        #expect(start.properties.iso == nil)
        #expect(start.storage?.totalCapacityBytes == 954_000_000_000)
        #expect(
            start.storageSlots.map(\.storageID) == [FakeZRMediaCard.storageID, secondStorageID])
        #expect(start.storageSlots.map(\.slotNumber) == [1, 2])
        #expect(
            start.storageSlots.map(\.storage.freeSpaceBytes) == [
                242_000_000_000, 111_000_000_000,
            ])

        let busyBootstrap = session.refreshAndroidPropertySnapshot(.bootstrap)
        #expect(busyBootstrap.result == .mediaBusy)
        #expect(busyBootstrap.storageSlots == start.storageSlots)
        #expect(
            server.receivedRequests().filter { $0.operation == .getDevicePropValueEx }.isEmpty)

        let wire = MediaBrowseStartWire.encode(cursor: 41, readback: start)
        #expect(wire.hasPrefix("OZCMEDIASTART1\t41\nresult\tmediaBusy\n"))
        #expect(wire.contains("storageSlotCount\t2"))
        #expect(wire.contains("storageSlot.1.storageId\t\(secondStorageID)"))
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

        _ = session.enterMediaModeForBrowse()
        let mediaBusy = session.refreshAndroidPropertySnapshot(.next(isRecording: false))
        #expect(mediaBusy.result == .mediaBusy)
        #expect(mediaBusy.properties.batteryPercent == 80)
    }

    @Test func evIndicatorRequestReadsOnlyTheNeedleWithoutAdvancingTheRoundRobin() throws {
        let server = try FakeZRServer()
        defer { server.stop() }
        let session = try connect(to: server)
        defer { session.disconnect() }

        let first = session.refreshAndroidPropertySnapshot(.evIndicator)
        #expect(first.result == .accepted)
        #expect(first.properties.evIndicatorSixths == -4)
        let fields = wireFields(AndroidCameraPropertyReadbackWire.encode(first))
        #expect(fields["evIndicatorSixths"] == "-4")

        // Fast needle reads touch only the exposure indicator (plus its slow
        // lit-state stride) — never a round-robin monitor property.
        let evCodes: Set<UInt32> = [
            PTPPropertyCode.exposureIndicateStatus.rawValue,
            PTPPropertyCode.exposureIndicateLightup.rawValue,
        ]
        let before = server.receivedRequests().filter {
            $0.operation == .getDevicePropValue || $0.operation == .getDevicePropValueEx
        }
        for _ in 0..<8 {
            let readback = session.refreshAndroidPropertySnapshot(.evIndicator)
            #expect(readback.result == .accepted)
        }
        let after = server.receivedRequests().filter {
            $0.operation == .getDevicePropValue || $0.operation == .getDevicePropValueEx
        }
        let evReads = after.dropFirst(before.count)
        #expect(evReads.count == 8)
        #expect(evReads.allSatisfy { evCodes.contains($0.parameters.first ?? 0) })
        // The lit-state gate refreshed at least once across the stride, so the
        // hidden-while-unlit rule tracks the body.
        #expect(
            evReads.contains {
                $0.parameters.first == PTPPropertyCode.exposureIndicateLightup.rawValue
            })
        let lit = session.refreshAndroidPropertySnapshot(.evIndicator)
        #expect(lit.properties.evIndicatorLit == true)
    }

    @Test func wireCarriesThePhotoModeStillsToneMode() {
        let readback = AndroidCameraPropertyReadback(
            result: .accepted,
            properties: PTPCameraPropertySnapshot(captureSelector: .photo, stillToneMode: "HLG"),
            storage: nil)
        let fields = wireFields(AndroidCameraPropertyReadbackWire.encode(readback))
        #expect(fields["captureSelector"] == "photo")
        #expect(fields["stillToneMode"] == "HLG")
    }

    @Test func browseFailureCleanupReleasesOnlyItsOwnershipGeneration() throws {
        let server = try FakeZRServer()
        defer { server.stop() }
        let session = try connect(to: server)
        defer { session.disconnect() }

        let failed = session.enterMediaModeForBrowse()
        session.exitMediaMode(ifOwnedBy: failed.ownershipGeneration)
        let resumed = session.refreshAndroidPropertySnapshot(
            .propertyChanged(PTPPropertyCode.batteryLevel.rawValue))
        #expect(resumed.result == .accepted)

        let stale = session.enterMediaModeForBrowse()
        let current = session.enterMediaModeForBrowse()
        session.exitMediaMode(ifOwnedBy: stale.ownershipGeneration)
        let stillOwned = session.refreshAndroidPropertySnapshot(.next(isRecording: false))
        #expect(stillOwned.result == .mediaBusy)

        session.exitMediaMode(ifOwnedBy: current.ownershipGeneration)
        let resumedAgain = session.refreshAndroidPropertySnapshot(
            .propertyChanged(PTPPropertyCode.batteryLevel.rawValue))
        #expect(resumedAgain.result == .accepted)
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

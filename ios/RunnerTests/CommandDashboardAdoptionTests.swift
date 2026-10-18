import Foundation
import MonitorPresentation
import OpenCineAppKit
import OpenCineCameraControls
import OpenZCineCore
import Testing

@testable import Runner

/// DISP 3 through the shared command dashboard: the order store keeps an operator's existing
/// arrangement, a move on the visible grid leaves hidden tiles in place, and the Nikon projection
/// supplies only tile kinds, values and the pickers they open.
@MainActor @Suite struct CommandDashboardAdoptionTests {
    @Test func stabilizationRowsKeepTheExistingSwiftProjectionAndDistinctRequests() {
        let rows = NikonStabilizationSettings.rows(
            vrOptions: nil, currentVR: nil, currentEVR: "OFF", codec: "H.265")
        #expect(rows.map(\.id) == [.movieVR, .electronicVR])
        #expect(rows[0].options == ["OFF", "ON", "SPORT"])
        #expect(rows[0].current == nil)
        #expect(rows[1].options == ["OFF", "ON"])
        var writes: [(NikonStabilizationRequest, String)] = []
        rows[0].select(
            "SPORT", interactionEnabled: true, currentSource: { true },
            onSelect: { writes.append(($0, $1)) },
            onUnavailable: { _, _ in Issue.record("Unexpected refusal") })
        #expect(writes.count == 1 && writes[0].0 == .movieVR && writes[0].1 == "SPORT")
        rows[1].select(
            "ON", interactionEnabled: true, currentSource: { true },
            onSelect: { writes.append(($0, $1)) },
            onUnavailable: { _, _ in Issue.record("Unexpected refusal") })
        #expect(writes.count == 2 && writes[1].0 == .electronicVR && writes[1].1 == "ON")
    }

    @Test func stabilizationKeepsEmptyDomainUnknownAndSwiftRAWOnlyPolicy() {
        for codec in ["", " ", "unknown", "H.265"] {
            let rows = NikonStabilizationSettings.rows(
                vrOptions: [], currentVR: nil, currentEVR: nil, codec: codec)
            #expect(rows[0].options.isEmpty)
            #expect(rows[0].current == nil && rows[1].current == nil)
            #expect(rows[1].request == .electronicVR)
        }
        for codec in ["R3D NE", "N-RAW", "ProRes RAW HQ"] {
            let rows = NikonStabilizationSettings.rows(
                vrOptions: ["SPORT", "OFF"], currentVR: "unrecognized", currentEVR: "ON",
                codec: codec)
            #expect(rows[0].options == ["SPORT", "OFF"] && rows[0].current == "unrecognized")
            #expect(rows[0].request == .movieVR)
            #expect(rows[1].current == "ON" && rows[1].request == nil)
            #expect(rows[1].unavailableReason == "e-VR is unavailable in RAW codecs")
        }
    }

    @Test func stabilizationEmptyEffectiveDomainWithholdsOnlyItsRequest() throws {
        let codec = try #require(
            PTPCameraPropertyDecoders.fileTypeModes(fromEnum: [0x0001_0A00]).first)
        let cases:
            [([String]?, [String], NikonStabilizationRequest?, [NikonStabilizationRequest])] = [
                ([], [], nil, [.electronicVR]),
                (nil, ["OFF", "ON", "SPORT"], .movieVR, [.movieVR, .electronicVR]),
                (["SPORT", "OFF"], ["SPORT", "OFF"], .movieVR, [.movieVR, .electronicVR]),
            ]
        for (options, expectedOptions, expectedRequest, expectedWrites) in cases {
            let group = NikonStabilizationSettings.presentation(
                vrOptions: options, currentVR: "unrecognized", currentEVR: "OFF", codec: "H.265",
                vrDescriptor: .init(), evrDescriptor: .init(), actualCodec: codec)
            let movie = group.rows[0]
            #expect(movie.options == expectedOptions)
            #expect(movie.current == "unrecognized" && movie.unavailableReason == nil)
            #expect(movie.request == expectedRequest)
            var writes: [NikonStabilizationRequest] = []
            for row in group.rows {
                row.select(
                    row.id == .movieVR ? "SPORT" : "ON", interactionEnabled: true,
                    currentSource: { true }, onSelect: { request, _ in writes.append(request) },
                    onUnavailable: { _, _ in Issue.record("Unexpected refusal") })
            }
            #expect(writes == expectedWrites)
            #expect(group.rows[1].options == ["OFF", "ON"])
            #expect(group.rows[1].current == "OFF" && group.rows[1].unavailableReason == nil)
        }
    }

    @Test func stabilizationHostRetainsDescriptorFactsAndLegacyDomain() throws {
        let model = NativeAppModel()
        let code = PTPPropertyCode.movieVibrationReduction.rawValue
        let bytes = [UInt8(code & 255), UInt8((code >> 8) & 255), 2, 0, 0, 0, 0, 2, 0, 0]
        let descriptor = try #require(
            NikonScalarPropertyDescriptor.parse(
                Data(bytes), property: code, valueByteCount: 1))
        let observation = NikonDescriptorObservation(outcome: .described, descriptor: descriptor)
        model.applyBootstrapObservation(
            .descriptor(.movieVibrationReduction, .init(outcome: .pending)))
        #expect(model.stabilizationPresentation.vrDescriptor.latestAttempt.outcome == .pending)
        model.applyBootstrapObservation(.descriptor(.movieVibrationReduction, observation))
        let group = model.stabilizationPresentation
        #expect(group.vrDescriptor.observation == observation)
        #expect(group.vrDescriptor.observation.capability.access == .readOnly)
        #expect(group.vrDescriptor.observation.capability.offer == [])
        #expect(group.vrDescriptor.optionOrigin == .legacyFallback)
        #expect(group.rows[0].options == ["OFF", "ON", "SPORT"])
        #expect(group.rows[0].request == nil)
        #expect(group.rows[0].unavailableReason == "VR is read-only on this camera")
        model.applyBootstrapObservation(
            .descriptor(.movieVibrationReduction, .init(outcome: .transportFailed)))
        #expect(model.stabilizationPresentation.vrDescriptor.observation == observation)
        #expect(
            model.stabilizationPresentation.vrDescriptor.latestAttempt.outcome == .transportFailed)
        model.disconnect()
        #expect(model.stabilizationPresentation.vrDescriptor.observation.outcome == .notAttempted)
    }

    @Test func stabilizationUsesActualRecognizedCodecRatherThanRetainedDisplay() {
        let model = NativeAppModel()
        let modes = PTPCameraPropertyDecoders.fileTypeModes(fromEnum: [0x0001_0A00, 0x0031_0C03])
        model.applyBootstrapObservation(.fileTypes(modes))
        model.applyDemoProperty(.movieFileType, data: Data(ByteCoding.uint32LE(0x0001_0A00)))
        model.cameraState = model.cameraState.updating(codec: "H.265")
        #expect(
            model.stabilizationPresentation.rows[1].request == nil,
            "An optimistic or demo snapshot is not an actual codec observation")
        for raw: UInt32? in [nil, 0x0099_0A00, 0x0031_0C03, 0x0001_0A00] {
            if let raw {
                model.applyBootstrapObservation(
                    .property(.movieFileType, Data(ByteCoding.uint32LE(raw))))
            }
            // A retained display label never establishes actual codec eligibility.
            model.cameraState = model.cameraState.updating(codec: "H.265")
            let group = model.stabilizationPresentation
            #expect(group.rows[1].options == ["OFF", "ON"])
            #expect((group.rows[1].request != nil) == (raw == 0x0001_0A00))
        }
    }

    @Test func stabilizationLastValidAccessSurvivesCatalogAndAttemptSeparation() throws {
        let code = PTPPropertyCode.movieVibrationReduction.rawValue
        func observed(writable: Bool) throws -> NikonDescriptorObservation {
            let bytes = ByteCoding.uint32LE(code) + [2, 0, writable ? 1 : 0, 0, 0, 2, 1, 0, 2]
            let descriptor = try #require(
                NikonScalarPropertyDescriptor.parse(
                    Data(bytes), property: code, valueByteCount: 1))
            return .init(outcome: .described, descriptor: descriptor)
        }
        let retained = try observed(writable: true)
        let lastValid = try observed(writable: false)
        var evidence = NikonDescriptorEvidence(
            observation: retained,
            latestAttempt: .init(outcome: .notAttempted), lastValidObservation: lastValid)
        let codec = try #require(
            PTPCameraPropertyDecoders.fileTypeModes(fromEnum: [0x0001_0A00]).first)
        func group() -> NikonStabilizationPresentation {
            NikonStabilizationSettings.presentation(
                vrOptions: nil, currentVR: nil, currentEVR: nil,
                codec: "H.265", vrDescriptor: evidence, evrDescriptor: .init(), actualCodec: codec)
        }
        #expect(group().rows[0].options == ["OFF", "ON", "SPORT"])
        #expect(group().rows[0].request == nil)
        #expect(group().rows[1].request == .electronicVR)
        evidence.latestAttempt = retained
        #expect(group().rows[0].request == .movieVR)
    }

    private func withStorage(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "SIMULATED.CommandGrid.\(UUID().uuidString)"
        let storage = try #require(UserDefaults(suiteName: suite))
        defer { storage.removePersistentDomain(forName: suite) }
        try body(storage)
    }

    /// The bytes the retired `PreferencesStore.save(_:)` wrote under `commandGridOrder.v1`.
    @Test func anArrangementStoredBeforeTheSharedOwnerLoadsAndStaysReadable() throws {
        try withStorage { storage in
            let stored: [CommandTileKind] = [.codec, .iso, .mode, .shutter, .iris, .whiteBalance]
            storage.set(try JSONEncoder().encode(stored), forKey: "commandGridOrder.v1")
            let store = PreferencesStore.commandTileOrder(storage: storage)
            // The tiles the stored order lacks join at the end in their declared order.
            #expect(store.load() == stored + [.resolutionFramerate, .ibis])
            store.save(
                moveMonitorCommandTile(
                    store.load(), .ibis, targetIndex: 0, all: CommandTileKind.allCases))
            let reread = try JSONDecoder().decode(
                [CommandTileKind].self, from: #require(storage.data(forKey: "commandGridOrder.v1")))
            #expect(reread == [.ibis] + stored + [.resolutionFramerate])
        }
    }

    @Test func aFreshInstallStartsFromTheDeclaredOrderWithoutWriting() throws {
        try withStorage { storage in
            #expect(
                PreferencesStore.commandTileOrder(storage: storage).load()
                    == CommandTileKind.allCases)
            #expect(storage.object(forKey: "commandGridOrder.v1") == nil)
        }
    }

    @Test func aMoveOnTheVisibleGridKeepsAHiddenTileInPlace() {
        let order = CommandTileKind.allCases  // mode, iso, shutter, iris, wb, rf, codec, ibis
        let hidden: Set<CommandTileKind> = [.mode]
        // Visible slot 1 is the shutter's: the ISO tile moves after it, Mode stays first.
        #expect(
            NikonCommandGridOrder.moving(.iso, to: 1, in: order, hidden: hidden)
                == [
                    .mode, .shutter, .iso, .iris, .whiteBalance, .resolutionFramerate, .codec,
                    .ibis,
                ])
        #expect(
            NikonCommandGridOrder.moving(.codec, to: 0, in: order, hidden: hidden)
                == [
                    .mode, .codec, .iso, .shutter, .iris, .whiteBalance, .resolutionFramerate,
                    .ibis,
                ])
        // A hidden tile cannot be dragged, so asking to move it changes nothing.
        #expect(NikonCommandGridOrder.moving(.mode, to: 4, in: order, hidden: hidden) == order)
        // With nothing hidden the visible slot is the order's slot.
        #expect(
            NikonCommandGridOrder.moving(.mode, to: 99, in: order, hidden: [])
                == [
                    .iso, .shutter, .iris, .whiteBalance, .resolutionFramerate, .codec, .ibis,
                    .mode,
                ])
    }

    @Test func videoTilesFollowTheVisibleOrderAndOpenTheirPickers() throws {
        let model = NativeAppModel()
        let tiles = model.commandDashboardTiles
        #expect(tiles.map(\.kind) == model.visibleCommandGridOrder.map(Optional.some))
        let pickers: [CommandTileKind: CameraPicker] = [
            .mode: .mode, .iso: .iso, .shutter: .shutter, .iris: .iris,
            .whiteBalance: .whiteBalance,
            .resolutionFramerate: .resolution, .codec: .codec, .ibis: .stabilization,
        ]
        for tile in tiles {
            let kind = try #require(tile.kind)
            #expect(tile.request == pickers[kind].map { NikonCommandRequest(picker: $0) })
        }
        #expect(tiles.first { $0.kind == .ibis }?.title == "VR / e-VR")
        #expect(tiles.first { $0.kind == .resolutionFramerate }?.title == "Resolution Framerate")
    }

    @Test func theSideColumnKeepsItsSectionsCellsAndTabs() {
        let model = NativeAppModel()
        let sections = model.commandDashboardSections
        #expect(sections.map(\.title) == ["Image", "Focus", "Audio", "Monitor"])
        #expect(
            sections.map { $0.cells.map(\.title) } == [
                ["Tone", "Picture Profile"], ["Mode", "Area", "Subject"],
                ["Sens", "32-bit Float", "Input", "Wind", "Atten"], ["Grid"],
            ])
        let focus = sections[1].cells.map(\.request)
        #expect(focus == [0, 1, 2].map { NikonCommandRequest(picker: .focus, mode: $0) })
        let audio = sections[2].cells.map { $0.request?.mode }
        #expect(audio == [0, 4, 1, 2, 3])
        // Tone and Grid read camera settings this monitor does not write; the profile is a placeholder.
        #expect(sections[0].cells.allSatisfy { $0.request == nil })
        #expect(sections[0].cells[1].muted)
        #expect(sections[3].cells[0].request == nil)
    }

    @Test func theHealthStripReadsTheCameraState() {
        let model = NativeAppModel()
        let health = model.commandDashboardHealth
        #expect(health.temperature == model.cameraState.temperature)
        #expect(health.temperatureOk == model.cameraState.temperature.hasPrefix("OK"))
        #expect(health.storage == model.liveMediaReadout)
        #expect(health.camera == model.cameraState.cameraName)
        #expect(health.lens == model.cameraState.lens)
    }
}

#if os(iOS)
    import OpenCineHostedAccessibility
    import SwiftUI
    import UIKit
    import XCTest

    /// In-process accessibility/value contracts over the production panel and demo setters.
    /// The legacy selector is retained; activation is not native touch or hit proof. Public touch
    /// evidence is supplied by GroupedStabilizationInputUITests in RunnerUIReview.
    @MainActor
    final class GroupedStabilizationNativeTests: XCTestCase {
        func testObservedReadoutSurvivesEmptyDomainAndUnlistedValue() async throws {
            let fixture = await StabilizationFixture()
            defer { fixture.close() }
            _ = try await fixture.option("electronicVR", 0)
            fixture.model.cameraControlOptions[.movieVibrationReduction] = []
            let empty = try await fixture.element("monitor.independentSettings.movieVR.current")
            XCTAssertEqual(empty.accessibilityLabel, "OFF")
            XCTAssertEqual(fixture.labelCount("e-VR is unavailable in RAW codecs"), 0)
            fixture.attachLandscape(self)
            fixture.model.cameraControlOptions[.movieVibrationReduction] = ["unlisted"]
            let outside = try await fixture.element("monitor.independentSettings.movieVR.current")
            XCTAssertEqual(outside.accessibilityLabel, "OFF")
            fixture.model.cameraControlOptions[.movieVibrationReduction] = ["OFF", "SPORT"]
            let offered = try await fixture.element("monitor.independentSettings.movieVR.option.0")
            {
                $0.accessibilityTraits.contains(.selected)
            }
            XCTAssertTrue(offered.accessibilityTraits.contains(.selected))
            try await fixture.withoutElement("monitor.independentSettings.movieVR.current")
            XCTAssertEqual(fixture.model.stabilizationVR, "OFF")
            XCTAssertEqual(fixture.model.debugPendingCameraWriteCount, 0)
        }

        func testNativeRowsKeepDistinctSettersAndNoWriteOnOpenOrClose() async throws {
            let fixture = await StabilizationFixture()
            defer { fixture.close() }
            XCTAssertEqual(fixture.model.stabilizationVR, "OFF")
            XCTAssertEqual(fixture.model.stabilizationElectronicVR, "OFF")
            let movie = try await fixture.option("movieVR", 2)
            XCTAssertTrue(movie.accessibilityActivate())
            XCTAssertEqual(fixture.model.stabilizationVR, "SPORT")
            XCTAssertEqual(fixture.model.stabilizationElectronicVR, "OFF")
            let electronic = try await fixture.option("electronicVR", 1)
            XCTAssertTrue(electronic.accessibilityActivate())
            XCTAssertEqual(fixture.model.stabilizationVR, "SPORT")
            XCTAssertEqual(fixture.model.stabilizationElectronicVR, "ON")
            XCTAssertEqual(fixture.model.debugPendingCameraWriteCount, 0)
            fixture.attachLandscape(self)
            fixture.close()
            XCTAssertEqual(fixture.model.stabilizationVR, "SPORT")
            XCTAssertEqual(fixture.model.stabilizationElectronicVR, "ON")
            XCTAssertEqual(fixture.model.debugPendingCameraWriteCount, 0)
        }

        func testReadOnlyRefusalShowsItsActualReasonInsteadOfRAW() async throws {
            let fixture = await StabilizationFixture()
            defer { fixture.close() }
            let property = PTPPropertyCode.movieVibrationReduction.rawValue
            let bytes = ByteCoding.uint32LE(property) + [2, 0, 0, 0, 0, 2, 1, 0, 2]
            let descriptor = try XCTUnwrap(
                NikonScalarPropertyDescriptor.parse(
                    Data(bytes), property: property, valueByteCount: 1))
            fixture.model.applyBootstrapObservation(
                .descriptor(
                    .movieVibrationReduction, .init(outcome: .described, descriptor: descriptor)))
            _ = try await fixture.element("monitor.independentSettings.movieVR.reason")
            let reason = "VR is read-only on this camera"
            let before = fixture.labelCount(reason)
            XCTAssertGreaterThan(before, 0)
            let refused = try await fixture.option("movieVR", 1)
            XCTAssertTrue(refused.accessibilityActivate())
            for _ in 0..<200 {
                if fixture.labelCount(reason) > before { break }
                await Task.yield()
            }
            XCTAssertGreaterThan(
                fixture.labelCount(reason), before, "The refusal notice repeats the actual reason")
            XCTAssertEqual(fixture.labelCount("e-VR is unavailable in RAW codecs"), 0)
            XCTAssertEqual(fixture.model.stabilizationVR, "OFF")
            XCTAssertEqual(fixture.model.stabilizationElectronicVR, "OFF")
            XCTAssertEqual(fixture.model.debugPendingCameraWriteCount, 0)
            fixture.attachLandscape(self)
        }

        func testRAWRefusalAndLiveLockKeepObservedValues() async throws {
            let fixture = await StabilizationFixture()
            defer { fixture.close() }
            let codec = PTPCameraPropertyWrite.fileType(raw: 0x0002_0C02)
            fixture.model.applyBootstrapObservation(.property(codec.property, codec.data))
            fixture.model.cameraState = fixture.model.cameraState.applyingCameraProperties(
                fixture.model.cameraPropertySnapshot)
            _ = try await fixture.element("monitor.independentSettings.electronicVR.reason")
            let rawReason = "e-VR is unavailable in RAW codecs"
            let before = fixture.labelCount(rawReason)
            let refused = try await fixture.option("electronicVR", 1)
            XCTAssertTrue(refused.accessibilityActivate())
            for _ in 0..<200 {
                if fixture.labelCount(rawReason) > before { break }
                await Task.yield()
            }
            XCTAssertGreaterThan(fixture.labelCount(rawReason), before)
            XCTAssertEqual(fixture.model.stabilizationElectronicVR, "OFF")
            fixture.model.interfaceLocked = true
            let locked = try await fixture.element("monitor.independentSettings.movieVR.option.2") {
                $0.accessibilityTraits.contains(.notEnabled)
            }
            _ = locked.accessibilityActivate()
            XCTAssertEqual(fixture.model.stabilizationVR, "OFF")
            XCTAssertEqual(fixture.model.stabilizationElectronicVR, "OFF")
            XCTAssertEqual(fixture.model.debugPendingCameraWriteCount, 0)
            fixture.attachLandscape(self)
        }

        func testUnknownReadbackNeverSelectsFirstAndEmptyMovieDomainKeepsElectronicRow()
            async throws
        {
            let fixture = await StabilizationFixture(seed: false)
            defer { fixture.close() }
            let movie = try await fixture.option("movieVR", 0)
            let electronic = try await fixture.option("electronicVR", 0)
            XCTAssertFalse(movie.accessibilityTraits.contains(.selected))
            XCTAssertFalse(electronic.accessibilityTraits.contains(.selected))
            XCTAssertNil(fixture.model.stabilizationVR)
            XCTAssertNil(fixture.model.stabilizationElectronicVR)
            try await fixture.withoutElement("monitor.independentSettings.movieVR.current")
            try await fixture.withoutElement("monitor.independentSettings.electronicVR.current")
            fixture.model.cameraControlOptions[.movieVibrationReduction] = []
            let active = try await fixture.option("electronicVR", 1)
            XCTAssertTrue(active.accessibilityActivate())
            XCTAssertNil(fixture.model.stabilizationVR)
            XCTAssertEqual(fixture.model.stabilizationElectronicVR, "ON")
            XCTAssertEqual(fixture.model.debugPendingCameraWriteCount, 0)
        }
    }

    @MainActor
    private final class StabilizationFixture {
        let model = NativeAppModel()
        let window: UIWindow
        let host: UIHostingController<AnyView>

        init(seed: Bool = true) async {
            _ = await HostedAccessibility.awaitRuntime()
            model.isDemoSession = true
            // The grouped host now needs an actual recognized codec observation. Seed it through
            // the production readback seam; the existing write/RAW assertions stay unchanged.
            model.applyBootstrapObservation(
                .fileTypes(
                    PTPCameraPropertyDecoders.fileTypeModes(fromEnum: [0x0001_0A00, 0x0002_0C02])))
            model.applyBootstrapObservation(
                .property(
                    .movieFileType, Data(ByteCoding.uint32LE(0x0001_0A00))))
            if seed {
                model.setVibrationReduction("OFF")
                model.setElectronicVR(on: false)
            }
            host = UIHostingController(
                rootView: AnyView(
                    StabilizationPickerPanel().environment(model).frame(width: 340).padding(16)))
            window = UIWindow(frame: CGRect(x: 0, y: 0, width: 844, height: 390))
            window.rootViewController = host
            window.makeKeyAndVisible()
            host.view.frame = window.bounds
        }

        func close() {
            window.isHidden = true
            window.rootViewController = nil
        }

        func option(_ row: String, _ index: Int) async throws -> NSObject {
            try await element("monitor.independentSettings.\(row).option.\(index)")
        }

        func element(_ identifier: String, matching match: (NSObject) -> Bool = { _ in true })
            async throws -> NSObject
        {
            for _ in 0..<200 {
                host.view.layoutIfNeeded()
                if let value = HostedAccessibility.reachable(in: host.view).first(where: {
                    HostedAccessibility.identifier($0) == identifier && match($0)
                }) {
                    return value
                }
                await Task.yield()
            }
            throw Missing.element(identifier)
        }

        func labelCount(_ label: String) -> Int {
            host.view.layoutIfNeeded()
            return HostedAccessibility.reachable(in: host.view).filter {
                $0.accessibilityLabel == label
            }.count
        }

        func attachLandscape(_ test: XCTestCase) {
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "SIMULATED grouped stabilization landscape"
            attachment.lifetime = .keepAlways
            test.add(attachment)
        }
        func withoutElement(_ identifier: String) async throws {
            for _ in 0..<200 {
                host.view.layoutIfNeeded()
                if !HostedAccessibility.reachable(in: host.view).contains(where: {
                    HostedAccessibility.identifier($0) == identifier
                }) {
                    return
                }
                await Task.yield()
            }
            throw Missing.element(identifier)
        }
        private enum Missing: Error { case element(String) }
    }
#endif

/// SIMULATED grouped producer through the actual app safe-point queue and Nikon transport.
@MainActor @Suite struct GroupedStabilizationQueueTests {
    @Test func revokedQueuedSelectionDoesNotSendAndFreshSelectedRowStillDispatches() async throws {
        let (model, native, wire) = try await fixture()
        defer {
            model.debugAdoptEstablishedMediaSession(nil)
            native.close()
        }
        model.applyGroupedStabilization(
            .movieVR, option: "SPORT", source: model.operatorLiveIdentity)
        #expect(model.debugPendingCameraWriteCount == 1)
        model.interfaceLocked = true
        model.interfaceLocked = false
        #expect(await model.debugServiceNextCameraWrite())
        #expect(
            await wire.writes.isEmpty,
            "Regranting authority cannot revive an expired queued request")
        #expect(model.debugPendingCameraWriteCount == 0)
        model.applyGroupedStabilization(
            .electronicVR, option: "ON", source: model.operatorLiveIdentity)
        #expect(await model.debugServiceNextCameraWrite())
        #expect(await wire.writes == [.electronicVR])
        #expect(model.stabilizationElectronicVR == "ON")
        #expect(model.stabilizationVR != "SPORT")
        #expect(model.debugPendingCameraWriteCount == 0)
    }

    @Test func queuedNativeWaiterRevokesButEnteredWriteKeepsAuthoritativeReadback() async throws {
        for entered in [false, true] {
            let (model, native, wire) = try await fixture()
            defer {
                model.debugAdoptEstablishedMediaSession(nil)
                native.close()
            }
            model.applyGroupedStabilization(
                .movieVR, option: "SPORT", source: model.operatorLiveIdentity)
            await wire.arm(entered ? .write : .read)
            let blocker =
                entered ? nil : Task { try await native.readCameraProperty(.electronicVR) }
            if !entered { await wire.waitUntilHeld() }
            let drain = Task { await model.debugServiceNextCameraWrite() }
            if entered {
                await wire.waitUntilHeld()
            } else {
                await wire.waitUntilQueued()
                #expect(await wire.writes.isEmpty, "The admitted write has not entered the wire")
                #expect(model.debugPendingCameraWriteCount == 0)
            }
            model.interfaceLocked = true
            await wire.release()
            _ = try await blocker?.value
            #expect(await drain.value)
            #expect(await wire.writes == (entered ? [.movieVibrationReduction] : []))
            #expect(entered ? model.stabilizationVR == "SPORT" : model.stabilizationVR != "SPORT")
            #expect(model.debugPendingCameraWriteCount == 0)
            // Legacy direct operations continue to work while the grouped receipt is expired.
            model.setElectronicVR(on: true)
            #expect(await model.debugServiceNextCameraWrite())
            #expect(await wire.writes.last == .electronicVR)
        }
    }

    @Test func popupFeedbackAndUnchangedAuthorityDoNotRetireQueuedSelection() async throws {
        let (model, native, wire) = try await fixture()
        defer {
            model.debugAdoptEstablishedMediaSession(nil)
            native.close()
        }
        model.applyGroupedStabilization(.movieVR, option: "ON", source: model.operatorLiveIdentity)
        model.connectionMessage = "SIMULATED unrelated feedback"
        model.activePanel = .picker(.stabilization)
        model.dismissActivePanel()
        model.interfaceLocked = false
        model.isRelayBroadcasting = true
        model.relayControlHeldBy = nil
        #expect(await model.debugServiceNextCameraWrite())
        #expect(await wire.writes == [.movieVibrationReduction])
        #expect(model.stabilizationVR == "ON")
    }

    @Test func surrenderAndRegrantCannotReviveAnAlreadyQueuedSelection() async throws {
        let (model, native, wire) = try await fixture()
        defer {
            model.debugAdoptEstablishedMediaSession(nil)
            native.close()
        }
        model.isRelayBroadcasting = true
        model.applyGroupedStabilization(
            .electronicVR, option: "ON", source: model.operatorLiveIdentity)
        model.relayControlHeldBy = "SIMULATED watcher"
        model.relayControlHeldBy = nil
        #expect(await model.debugServiceNextCameraWrite())
        #expect(await wire.writes.isEmpty)
        model.applyGroupedStabilization(.movieVR, option: "ON", source: model.operatorLiveIdentity)
        #expect(await model.debugServiceNextCameraWrite())
        #expect(await wire.writes == [.movieVibrationReduction])
    }

    @Test func sourceReplacementCannotBorrowOldQueuedReceipt() async throws {
        let (model, first, firstWire) = try await fixture()
        let secondWire = GroupedQueueTransport()
        let second = try await NativeCameraSession.establish(
            transport: secondWire, host: "usb:SIMULATED-second", cameraName: "SIMULATED",
            requestPairing: false)
        defer {
            model.debugAdoptEstablishedMediaSession(nil)
            first.close()
            second.close()
        }
        let shown = model.operatorLiveIdentity
        model.applyGroupedStabilization(.movieVR, option: "SPORT", source: shown)
        await secondWire.clearWrites()
        model.debugAdoptEstablishedMediaSession(second)
        #expect(await model.debugServiceNextCameraWrite())
        #expect(await firstWire.writes.isEmpty)
        #expect(
            await secondWire.writes.isEmpty,
            "A replacement with identical display facts cannot borrow old authority")
        model.applyGroupedStabilization(.movieVR, option: "ON", source: model.operatorLiveIdentity)
        #expect(await model.debugServiceNextCameraWrite())
        #expect(await secondWire.writes == [.movieVibrationReduction])
        #expect(model.stabilizationVR == "ON")
    }

    private func fixture() async throws -> (
        NativeAppModel, NativeCameraSession, GroupedQueueTransport
    ) {
        let wire = GroupedQueueTransport()
        let native = try await NativeCameraSession.establish(
            transport: wire, host: "usb:SIMULATED-grouped", cameraName: "SIMULATED",
            requestPairing: false)
        await wire.clearWrites()
        let model = NativeAppModel()
        model.debugAdoptEstablishedMediaSession(native)
        model.isMonitorPresented = true
        model.applyDemoProperty(.movieVibrationReduction, data: Data([0]))
        model.applyDemoProperty(.electronicVR, data: Data([0]))
        return (model, native, wire)
    }
}

private actor GroupedQueueTransport: CameraTransport {
    enum Hold { case read, write }
    nonisolated let kind = CameraTransportKind.usb
    private let establishment = LargeTransferTransport(operations: [
        .setDevicePropValue, .getDevicePropValue,
    ])
    private var values: [UInt32: Data] = [:]
    private(set) var writes: [PTPPropertyCode] = []
    private var hold: Hold?
    private var held = false
    private var entered: CheckedContinuation<Void, Never>?
    private var released: CheckedContinuation<Void, Never>?
    private var transactionActive = false
    private var transactionWaiters: [CheckedContinuation<Void, Never>] = []
    private var queued: CheckedContinuation<Void, Never>?
    func waitUntilQueued() async {
        if !transactionWaiters.isEmpty { return }
        await withCheckedContinuation { queued = $0 }
    }
    private func acquireTransaction() async {
        if !transactionActive {
            transactionActive = true
            return
        }
        await withCheckedContinuation {
            transactionWaiters.append($0)
            queued?.resume()
            queued = nil
        }
    }
    private func releaseTransaction() {
        if transactionWaiters.isEmpty {
            transactionActive = false
        } else {
            transactionWaiters.removeFirst().resume()
        }
    }
    func clearWrites() { writes = [] }
    func arm(_ hold: Hold) { self.hold = hold }
    func waitUntilHeld() async {
        if held { return }
        await withCheckedContinuation { entered = $0 }
    }
    func release() {
        released?.resume()
        released = nil
        held = false
    }
    func executeTransaction(
        operationCode: PTPOperationCode, transactionID: UInt32?, parameters: [UInt32],
        dataPhase: PTPDataPhase, dataOut: Data?, deadline: Duration?
    ) async throws -> PTPIPTransactionResult {
        try await transact(
            operationCode: operationCode, transactionID: transactionID, parameters: parameters,
            dataPhase: dataPhase, dataOut: dataOut, deadline: deadline, admission: nil)
    }
    func executeTransaction(
        operationCode: PTPOperationCode, transactionID: UInt32?, parameters: [UInt32],
        dataPhase: PTPDataPhase, dataOut: Data?, deadline: Duration?,
        admission: NikonCommandAdmission
    ) async throws -> PTPIPTransactionResult {
        try await transact(
            operationCode: operationCode, transactionID: transactionID, parameters: parameters,
            dataPhase: dataPhase, dataOut: dataOut, deadline: deadline, admission: admission)
    }
    private func transact(
        operationCode: PTPOperationCode, transactionID: UInt32?, parameters: [UInt32],
        dataPhase: PTPDataPhase, dataOut: Data?, deadline: Duration?,
        admission: NikonCommandAdmission?
    ) async throws -> PTPIPTransactionResult {
        await acquireTransaction()
        defer { releaseTransaction() }
        try admission?.requireCurrent()
        if operationCode == .getDeviceInfo {
            return try await establishment.executeTransaction(
                operationCode: operationCode, transactionID: transactionID, parameters: parameters,
                dataPhase: dataPhase, dataOut: dataOut, deadline: deadline)
        }
        let property = parameters.first ?? 0
        if operationCode == .setDevicePropValue {
            if let code = PTPPropertyCode(rawValue: property) { writes.append(code) }
            values[property] = dataOut
        }
        if (hold == .read && operationCode == .getDevicePropValue)
            || (hold == .write && operationCode == .setDevicePropValue)
        {
            hold = nil
            held = true
            entered?.resume()
            entered = nil
            await withCheckedContinuation { released = $0 }
        }
        let response =
            ByteCoding.uint16LE(PTPResponseCode.ok.rawValue)
            + ByteCoding.uint32LE(transactionID ?? 1)
        return PTPIPTransactionResult(
            operationResponse: try PTPOperationResponse(payloadBytes: response),
            data: operationCode == .getDevicePropValue ? values[property] ?? Data([0]) : Data())
    }
    func nextEvent() async throws -> PTPEvent { throw NativeCameraSessionError.connectionClosed }
    nonisolated func close() {}
}

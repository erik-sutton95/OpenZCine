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

        func testRAWRefusalAndLiveLockKeepObservedValues() async throws {
            let fixture = await StabilizationFixture()
            defer { fixture.close() }
            let codec = PTPCameraPropertyWrite.fileType(raw: 0x0002_0C02)
            fixture.model.applyDemoProperty(codec.property, data: codec.data)
            fixture.model.cameraState = fixture.model.cameraState.applyingCameraProperties(
                fixture.model.cameraPropertySnapshot)
            _ = try await fixture.element("monitor.independentSettings.electronicVR.reason")
            let refused = try await fixture.option("electronicVR", 1)
            XCTAssertTrue(refused.accessibilityActivate())
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

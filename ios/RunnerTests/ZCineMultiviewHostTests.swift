import OpenCineAppKit
import OpenCineCore
import XCTest

@testable import OpenZCineCore
@testable import Runner

/// This phone on a router's Wi-Fi at 192.168.1.10/24.
@MainActor private final class PhoneOnWiFi: StationHostPath {
    func address(hotspot: Bool) -> String? { hotspot ? nil : "192.168.1.10" }
    func netmask(hotspot: Bool) -> String? { hotspot ? nil : "255.255.255.0" }
    func join(_ network: StationNetwork) async throws -> String? { nil }
}

/// OpenZCine on the shared Multiview: the app's host over OpenCine's coordinator with scripted Z
/// bodies (`DemoMulticamLink`) behind the real Nikon member links. SIMULATED: physical Nikon
/// behavior is untested.
@MainActor
final class ZCineMultiviewHostTests: XCTestCase {
    /// The scripted network: bodies by host, what the passive pass sees, the saved setups.
    private final class Network: @unchecked Sendable {
        let lock = NSLock()
        var bodies: [String: DemoMulticamLink] = [:]
        var seen: [DiscoveredCamera] = []
        var dials: [String] = []
        var excludedAsked: [Set<String>] = []
    }

    private func environment(
        _ network: Network, saved: [NikonMultiviewSavedSetup] = [],
        store: MultiviewStagePreferencesStore? = nil
    ) -> ZCineMultiviewEnvironment {
        ZCineMultiviewEnvironment(
            connect: { host in
                let body = network.lock.withLock { () -> DemoMulticamLink? in
                    network.dials.append(host)
                    return network.bodies[host]
                }
                guard let body else { throw DemoMulticamLink.Refusal() }
                return ZCineMemberTransport(body)
            },
            currentHolder: { _ in nil },
            sightings: { _, excluded in
                network.lock.withLock {
                    network.excludedAsked.append(excluded)
                    return network.seen.filter { !excluded.contains($0.ip) }
                }
            },
            saved: { saved },
            hostPath: PhoneOnWiFi(),
            isCameraRefusal: { $0 is DemoMulticamLink.Refusal },
            framePace: { _ in .milliseconds(40) },
            presentationStore: store)
    }

    private func waitUntil(
        _ what: String, timeout: Duration = .seconds(10), _ condition: () -> Bool
    ) async throws {
        let start = ContinuousClock.now
        while !condition() {
            if ContinuousClock.now - start > timeout {
                XCTFail("Timed out: \(what)")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// A stage with the body "3001" (recording N-Log) live on slot 0 at 192.168.1.20.
    private func liveStage(_ network: Network) async throws -> (ZCineMultiview, DemoMulticamLink) {
        let body = DemoMulticamLink(serialNumber: "3001", model: "Nikon ZR", nLog: true)
        network.bodies["192.168.1.20"] = body
        network.seen = [DiscoveredCamera(ip: "192.168.1.20", name: "ZR", source: .bonjour)]
        let stage = ZCineMultiview(environment: environment(network))
        XCTAssertFalse(stage.coordinator.screenAppeared(startsSession: true), "no network wizard")
        try await waitUntil("the body is listed") { !stage.coordinator.pickerRows().isEmpty }
        let row = try XCTUnwrap(stage.coordinator.pickerRows().first)
        XCTAssertTrue(stage.coordinator.enqueueAdd(pickerRow: row.id, slot: 0))
        try await waitUntil("the tile shows its picture") { stage.pictures[0].image != nil }
        return (stage, body)
    }

    func testTheAddListOffersSightingsAndSavedSetupsButNeverAMember() async throws {
        let network = Network()
        network.seen = [
            DiscoveredCamera(ip: "192.168.1.20", name: "ZR", source: .bonjour),
            DiscoveredCamera(
                ip: "192.168.1.22", source: .heldByAnotherDevice, heldByDeviceName: "iPad"),
        ]
        network.bodies["192.168.1.20"] = DemoMulticamLink(serialNumber: "3001")
        let stage = ZCineMultiview(
            environment: environment(
                network, saved: [NikonMultiviewSavedSetup(host: "192.168.1.21", name: "Z 8 router")]
            ))
        stage.coordinator.start()
        try await waitUntil("the list fills") { stage.coordinator.pickerRows().count == 2 }
        XCTAssertEqual(
            stage.coordinator.pickerRows().map(\.title), ["ZR", "Z 8 router"],
            "a body another device holds is not offered")
        XCTAssertTrue(
            stage.coordinator.pickerFooter.hasSuffix(ZCineMultiview.pickerGuidance),
            "the camera-menu steps follow the footer")
        XCTAssertTrue(network.lock.withLock { network.dials.isEmpty }, "listing dials no body")
        let row = try XCTUnwrap(stage.coordinator.pickerRows().first)
        stage.coordinator.enqueueAdd(pickerRow: row.id, slot: 0)
        try await waitUntil("the member is live") { stage.coordinator.members[0].publishing }
        try await waitUntil("the next pass excludes the member") {
            network.lock.withLock { network.excludedAsked.last == ["192.168.1.20"] }
        }
        XCTAssertEqual(stage.coordinator.pickerRows().map(\.title), ["Z 8 router"])
        XCTAssertEqual(
            network.lock.withLock { network.dials }, ["192.168.1.20"], "only the picked body")
        stage.coordinator.stop()
    }

    func testALiveTileShowsItsReadingsAndAutoLUTFromTheRecordingTone() async throws {
        let network = Network()
        let (stage, _) = try await liveStage(network)
        try await waitUntil("the tone is read") { stage.links[0].recordingTone == .nLog }
        try await waitUntil("the Auto LUT follows the tone") { stage.pictures[0].lutEnabled }
        XCTAssertEqual(stage.pictures[0].lutSelection, .builtIn(.nLogRec709))
        XCTAssertEqual(stage.links[0].autoLUT.conversion, MonitorLUT.nLogRec709.rawValue)
        try await waitUntil("the battery is read") {
            stage.coordinator.stageTile(0)?.batteryBars != nil
        }
        let readings = try XCTUnwrap(stage.readings(slot: 0))
        XCTAssertEqual(readings.name, "ZR")
        XCTAssertEqual(readings.model, "Nikon ZR", "the model GetDeviceInfo reported, as Pocket")
        XCTAssertEqual(readings.timecode, "14:32:08", "HH:MM:SS like Pocket")
        XCTAssertEqual(readings.readouts.first?.value, "800")
        XCTAssertTrue(readings.hasPicture)
        XCTAssertNil(
            readings.recordingSeconds, "a Z body reports no take length: the tally reads REC")
        let tile = try XCTUnwrap(stage.coordinator.stageTile(0))
        // The scripted body reports BatteryLevel 80: four of five bars, no percent.
        XCTAssertNil(tile.battery)
        XCTAssertEqual(tile.batteryBars, 4)
        XCTAssertEqual(tile.batteryBarCount, 5)
        XCTAssertTrue(
            tile.actions.contains { $0.id == MultiviewCameraAction.lut }, "Auto LUT is offered")
        stage.coordinator.toggleLUT(slot: 0)
        XCTAssertFalse(stage.pictures[0].lutEnabled, "the operator turns it off per camera")
        stage.coordinator.stop()
    }

    func testLiveViewBorrowsTheMemberAndItsTileResumesOnReturn() async throws {
        let network = Network()
        let (stage, body) = try await liveStage(network)
        var lent: ZCineMemberTransport?
        stage.lendToLiveView = { _, transport in
            lent = transport
            return true
        }
        var exited = false
        _ = stage.liveView(slot: 0) { exited = true }
        try await waitUntil("the member's control path is up") {
            stage.coordinator.members[0].controlHost != nil
        }
        let session = stage.links[0].session.id
        XCTAssertTrue(stage.coordinator.openLiveView(slot: 0))
        XCTAssertEqual(stage.lentSlot, 0)
        XCTAssertFalse(stage.showsPicture(slot: 0), "repairs wait while Live View holds the link")
        XCTAssertTrue(lent?.base === body)
        XCTAssertTrue(stage.links[0].lent, "the tile's pump stood down")
        let frames = body.frameCount
        // The app hands back the session it holds (`returnToMultiview`): the same one comes back
        // in the box it left in, so the tile keeps its member session.
        stage.returnFromLiveView(session: body)
        XCTAssertTrue(exited, "the screen leaves Live View")
        XCTAssertNil(stage.lentSlot)
        XCTAssertEqual(stage.links[0].session.id, session, "the lent session itself came back")
        try await waitUntil("the tile resumes") { body.frameCount > frames + 3 }
        XCTAssertFalse(body.received.contains("start") || body.received.contains("stop"))
        stage.coordinator.stop()
    }

    func testSettingsGoOnlyToTheirCameraAndARefusalShowsInThePopup() async throws {
        let network = Network()
        let (stage, first) = try await liveStage(network)
        let second = DemoMulticamLink(serialNumber: "3002", model: "Nikon Z 8")
        network.bodies["192.168.1.21"] = second
        network.seen.append(DiscoveredCamera(ip: "192.168.1.21", name: "Z 8", source: .bonjour))
        try await waitUntil("the second body is listed") {
            stage.coordinator.pickerRows().contains { $0.title == "Z 8" }
        }
        let row = try XCTUnwrap(stage.coordinator.pickerRows().first { $0.title == "Z 8" })
        XCTAssertTrue(stage.coordinator.enqueueAdd(pickerRow: row.id, slot: 1))
        try await waitUntil("both members' controls are up") {
            stage.coordinator.members.prefix(2).allSatisfy { $0.controlHost != nil }
                && stage.links[1].reported.batteryPercent != nil
                && stage.coordinator.controlsAvailable(slot: 1)
        }
        stage.openCameraSettings(slot: 1)
        let state = try XCTUnwrap(stage.cameraSettings(slot: 1))
        XCTAssertEqual(state.categories.last, .resolution, "a Format tab, as Pocket's popup has")
        XCTAssertNil(stage.cameraSettings(slot: 0), "the editor is the selected camera's only")
        let editor = try XCTUnwrap(stage.editor?.editor)
        try await waitUntil("the ISO drum is editable") {
            editor.control.captureField(.iso)?.isEditable == true
        }
        func otherISO() throws -> MonitorCaptureChoice {
            let field = try XCTUnwrap(editor.control.captureField(.iso))
            return try XCTUnwrap(field.choices.first { $0.value != field.selection })
        }
        let choice = try otherISO()
        editor.control.set(choice.value, label: choice.label)
        try await waitUntil("only the selected camera receives the ISO write") {
            second.received.contains { $0.hasPrefix("write ") }
        }
        XCTAssertFalse(first.received.contains { $0.hasPrefix("write ") })

        second.refusesWrites = true
        let refused = try otherISO()
        editor.control.set(refused.value, label: refused.label)
        try await waitUntil("the refusal is explained in the popup") {
            stage.cameraSettings(slot: 1)?.note != nil
        }
        stage.coordinator.closeEditors()
        XCTAssertNil(stage.cameraSettings(slot: 1))
        XCTAssertFalse(first.received.contains("start") || second.received.contains("start"))
        stage.coordinator.stop()
    }

    func testTheStageLUTToolBakesEveryMember() async throws {
        let network = Network()
        let (stage, _) = try await liveStage(network)
        let second = DemoMulticamLink(serialNumber: "3002", nLog: true)
        network.bodies["192.168.1.21"] = second
        network.seen.append(DiscoveredCamera(ip: "192.168.1.21", name: "Z 8", source: .bonjour))
        try await waitUntil("the second body is listed") {
            stage.coordinator.pickerRows().contains { $0.title == "Z 8" }
        }
        let row = try XCTUnwrap(stage.coordinator.pickerRows().first { $0.title == "Z 8" })
        XCTAssertTrue(stage.coordinator.enqueueAdd(pickerRow: row.id, slot: 1))
        try await waitUntil("both Auto LUTs follow the N-Log tone") {
            stage.pictures[0].lutEnabled && stage.pictures[1].lutEnabled
        }
        try await waitUntil("each tile shows its baked picture") {
            stage.pictures[0].publishedBakes > 0 && stage.pictures[1].publishedBakes > 0
        }
        stage.coordinator.toggleLUT()
        XCTAssertFalse(
            stage.pictures[0].lutEnabled || stage.pictures[1].lutEnabled,
            "the toolbar turns every look off")
        stage.coordinator.toggleLUT()
        XCTAssertTrue(stage.pictures[0].lutEnabled && stage.pictures[1].lutEnabled)
        stage.coordinator.stop()
    }

    func testRecordConfirmationFollowsThePreferenceAndCloseReturnsNothing() async throws {
        let network = Network()
        let (stage, body) = try await liveStage(network)
        stage.recordConfirmation = { false }
        XCTAssertFalse(stage.confirmsRecord)
        stage.recordConfirmation = { true }
        XCTAssertTrue(stage.confirmsRecord)
        XCTAssertEqual(stage.coordinator.networkRestore, .none, "a Z body is never sent anywhere")
        var stopped = false
        stage.stopped = { stopped = true }
        let closed = await stage.coordinator.closeStage()
        XCTAssertTrue(closed)
        XCTAssertTrue(stopped)
        try await waitUntil("the session is closed") { body.received.contains("shutdown") }
        XCTAssertFalse(body.received.contains("start") || body.received.contains("stop"))
    }

    func testTheStageLayoutKeepsTheExistingPreferenceKey() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "ZCineMultiviewHostTests"))
        defaults.removePersistentDomain(forName: "ZCineMultiviewHostTests")
        let store = MultiviewStagePreferencesStore(storage: defaults, key: "multiview.presentation")
        // What the previous multicam stage saved under the same key.
        XCTAssertTrue(store.save(MultiviewStagePreferences(layout: .grid, selected: 2, fill: true)))
        let stage = ZCineMultiview(environment: environment(Network(), store: store))
        XCTAssertEqual(stage.coordinator.presentation.layout, .grid)
        XCTAssertEqual(stage.coordinator.presentation.selected, 2)
        XCTAssertTrue(stage.coordinator.presentation.fill)
        defaults.removePersistentDomain(forName: "ZCineMultiviewHostTests")
    }
}

import MonitorUI
import OpenCineAppKit
import OpenCineCore
import OpenCineHostedAccessibility
import OpenCineMulticam
import SwiftUI
import UIKit
import XCTest

@testable import OpenZCineCore
@testable import Runner

/// NIKON-01: the app's multicam on the shared engine, with scripted Z bodies
/// (`DemoMulticamLink`) behind the real pumps, plans, leases and member write queues.
@MainActor
final class MulticamCoordinatorTests: XCTestCase {
    func testPresentationStateSurvivesLeavingAndReenteringStage() async throws {
        let stage = coordinator()
        stage.arrangement = .grid
        stage.focusedSlot = 2
        stage.end()
        stage.begin()
        XCTAssertEqual(stage.arrangement, .grid)
        XCTAssertEqual(stage.focusedSlot, 2)
        XCTAssertTrue(stage.members.isEmpty)
        stage.end()
        try await verifyActualStageMountSurvivesBorrowedMonitor()
    }

    /// SIMULATED public-contract session, actual NativeRootContent and shared native stage.
    private func verifyActualStageMountSurvivesBorrowedMonitor() async throws {
        let model = NativeAppModel()
        model.multicam.begin()
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive })
        let previous = scene.keyWindow
        let host = UIHostingController(
            rootView: NativeRootContent()
                .environment(model).environment(model.delivery.lifetime))
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        defer {
            model.shell.close()
            model.multicam.end()
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        func stageController(_ root: UIViewController) -> MultiviewStageController? {
            if let stage = root as? MultiviewStageController { return stage }
            return root.children.lazy.compactMap(stageController).first
        }
        func settle(_ predicate: @escaping @MainActor () -> Bool) async {
            let expected = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in
                    MainActor.assumeIsolated {
                        host.view.layoutIfNeeded()
                        return predicate()
                    }
                }, object: nil)
            let result = await XCTWaiter.fulfillment(of: [expected], timeout: 5)
            XCTAssertEqual(result, .completed)
        }
        await settle { stageController(host) != nil }
        let original = try XCTUnwrap(stageController(host))
        let session = NikonPictureLifetimeSession()
        let camera = ConnectedCamera(
            saved: SavedCamera(
                id: "SIMULATED-multiview-round-trip",
                integration: IntegrationID("org.opencapture.nikon-ptp"),
                advertisedName: "SIMULATED camera", model: "SIMULATED"), session: session)
        var returns = 0
        model.shell.borrow(camera) { returns += 1 }
        await settle { model.shell.hostsMounted == 1 }
        XCTAssertTrue(
            stageController(host) === original,
            "The stage must stay mounted below borrowed Live View")
        model.shell.close()
        await settle { model.shell.hostsUnmounted == 1 && stageController(host) != nil }
        XCTAssertTrue(
            stageController(host) === original,
            "Returning must retain the existing native stage owner")
        XCTAssertEqual(returns, 1)
        XCTAssertEqual(session.commands, 0)
        XCTAssertTrue(session.closes.isEmpty)
    }

    /// SIMULATED body, actual root, native stage and UIKit confirmation presentation.
    /// Covering a retained stage must retire approval even when its record plan stays equal.
    func testHiddenStageRetiresGroupConfirmationWithoutChangingRecordContext() async throws {
        let model = NativeAppModel()
        let link = DemoMulticamLink(serialNumber: "SIMULATED-hidden-confirmation")
        link.frameInterval = .milliseconds(10)
        model.multicam.connect = { _ in link }
        model.preferences.recordConfirmationEnabled = true
        model.multicam.begin()
        model.multicam.add(
            record("SIMULATED-hidden", serial: "SIMULATED-hidden-confirmation"), reachable: true)
        try await live(model.multicam, count: 1)
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive })
        let previous = scene.keyWindow
        let host = UIHostingController(
            rootView: NativeRootContent()
                .environment(model).environment(model.delivery.lifetime))
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        defer {
            model.shell.close()
            model.multicam.end()
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        func settle(_ description: String, _ predicate: @escaping @MainActor () -> Bool) async {
            let expected = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in
                    MainActor.assumeIsolated {
                        host.view.layoutIfNeeded()
                        return predicate()
                    }
                }, object: nil)
            let result = await XCTWaiter.fulfillment(of: [expected], timeout: 5)
            XCTAssertEqual(result, .completed, description)
        }
        func stageController(_ root: UIViewController) -> MultiviewStageController? {
            if let stage = root as? MultiviewStageController { return stage }
            return root.children.lazy.compactMap(stageController).first
        }
        func recordButton() -> NSObject? {
            HostedAccessibility.elements(in: host.view).first {
                HostedAccessibility.identifier($0) == "multiview.recordAll"
            }
        }
        await settle("Actual native record action mounts") { recordButton() != nil }
        let originalStage = try XCTUnwrap(stageController(host))
        let context = model.multicam.groupPlan()
        XCTAssertTrue(context.isExecutable)
        XCTAssertTrue(try XCTUnwrap(recordButton()).accessibilityActivate())
        await settle("Actual group confirmation opens") {
            host.presentedViewController is UIAlertController
        }
        let oldDialog = try XCTUnwrap(host.presentedViewController as? UIAlertController)
        await settle("Actual Start action mounts") {
            oldDialog.view.layoutIfNeeded()
            return HostedAccessibility.elements(in: oldDialog.view).contains {
                $0.accessibilityLabel == "Start"
            }
        }
        let oldStart = try XCTUnwrap(
            HostedAccessibility.elements(in: oldDialog.view)
                .first { $0.accessibilityLabel == "Start" })
        let session = NikonPictureLifetimeSession()
        let camera = ConnectedCamera(
            saved: SavedCamera(
                id: "SIMULATED-cover-only", integration: IntegrationID("org.opencapture.nikon-ptp"),
                advertisedName: "SIMULATED cover", model: "SIMULATED"), session: session)
        model.shell.borrow(camera) {}
        XCTAssertEqual(
            model.multicam.groupPlan(), context,
            "The visibility edge must not rely on a changed plan")
        await settle("Cover retires actual group confirmation") {
            host.presentedViewController == nil
        }
        XCTAssertTrue(stageController(host) === originalStage)
        _ = oldStart.accessibilityActivate()
        XCTAssertFalse(link.received.contains("start"))
        XCTAssertFalse(link.received.contains("stop"))
        model.shell.close()
        await settle("Return restores the retained stage") {
            model.shell.monitor == nil && recordButton() != nil
        }
        XCTAssertTrue(stageController(host) === originalStage)
        XCTAssertNil(host.presentedViewController, "Old confirmation must not resurrect")
        XCTAssertNil(oldDialog.presentingViewController)
        _ = oldStart.accessibilityActivate()
        XCTAssertFalse(link.received.contains("start"))
        XCTAssertFalse(link.received.contains("stop"))
        XCTAssertEqual(session.commands, 0)
        XCTAssertTrue(try XCTUnwrap(recordButton()).accessibilityActivate())
        await settle("A new tap requires a fresh confirmation") {
            host.presentedViewController is UIAlertController
        }
        XCTAssertFalse(host.presentedViewController === oldDialog)
        _ = oldStart.accessibilityActivate()
        XCTAssertNotNil(
            host.presentedViewController, "A retired action cannot consume a fresh approval")
        XCTAssertFalse(link.received.contains("start"))
        XCTAssertFalse(link.received.contains("stop"))
        host.dismiss(animated: false)
    }

    /// SIMULATED bodies exercise the actual root, shared toolbar and native settings drum.
    func testActualMultiviewSettingsRouteOnlyToSelectedMember() async throws {
        let model = NativeAppModel()
        let first = DemoMulticamLink(serialNumber: "SIMULATED-settings-A")
        let second = DemoMulticamLink(serialNumber: "SIMULATED-settings-B")
        first.frameInterval = .milliseconds(10)
        second.frameInterval = .milliseconds(10)
        model.multicam.connect = { $0.host == "SIMULATED-A" ? first : second }
        model.multicam.begin()
        model.multicam.add(record("SIMULATED-A", serial: "SIMULATED-settings-A"), reachable: true)
        model.multicam.add(record("SIMULATED-B", serial: "SIMULATED-settings-B"), reachable: true)
        try await live(model.multicam, count: 2)
        model.multicam.presentation.toolsExpanded = true
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive })
        let previous = scene.keyWindow
        let host = UIHostingController(
            rootView: NativeRootContent()
                .environment(model).environment(model.delivery.lifetime))
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        defer {
            model.multicam.end()
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        func element(_ id: String) -> NSObject? {
            HostedAccessibility.elements(in: host.view).first {
                HostedAccessibility.identifier($0) == id
            }
        }
        func settle(_ message: String, _ predicate: @escaping @MainActor () -> Bool) async {
            let expected = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in
                    MainActor.assumeIsolated {
                        host.view.layoutIfNeeded()
                        return predicate()
                    }
                }, object: nil)
            let result = await XCTWaiter.fulfillment(of: [expected], timeout: 5)
            XCTAssertEqual(result, .completed, message)
        }
        await settle("Actual stage mounts") { element("multiview.recordAll") != nil }
        await settle("A live member with advertised controls offers CAMERA") {
            element("multiview.settings") != nil
        }
        XCTAssertTrue(try XCTUnwrap(element("multiview.settings")).accessibilityActivate())
        await settle("The actual shared inspector opens") {
            element("multiview.settings.panel") != nil
        }
        await settle("The admitted member's typed ISO drum mounts") {
            element("multiview.settings.iso") != nil
        }
        let oldDrum = try XCTUnwrap(element("multiview.settings.iso"))
        oldDrum.accessibilityIncrement()
        try await waitUntil("only the selected camera receives the ISO write") {
            first.received.contains { $0.hasPrefix("write ") }
        }
        XCTAssertFalse(second.received.contains { $0.hasPrefix("write ") })
        await settle("Camera B tab mounts") { element("multiview.settings.camera.1") != nil }
        XCTAssertTrue(try XCTUnwrap(element("multiview.settings.camera.1")).accessibilityActivate())
        await settle("Camera B's reported ISO is shown") {
            element("multiview.settings.iso")?.accessibilityValue?.contains("800") == true
        }
        let beforeA = first.received
        let beforeB = second.received
        let framesA = first.frameCount
        let framesB = second.frameCount
        oldDrum.accessibilityIncrement()
        try await waitUntil("old editor's coalesced input is drained by the actual pumps") {
            first.frameCount >= framesA + 5 && second.frameCount >= framesB + 5
        }
        XCTAssertEqual(first.received, beforeA, "A retired drum cannot queue another write")
        XCTAssertEqual(second.received, beforeB, "A retired drum cannot borrow the next member")
        XCTAssertTrue(try XCTUnwrap(element("monitor.capture.close")).accessibilityActivate())
        await settle("Settings close") { element("multiview.settings.panel") == nil }
        XCTAssertFalse(first.received.contains("start") || first.received.contains("stop"))
        XCTAssertFalse(second.received.contains("start") || second.received.contains("stop"))
    }

    private var links: [String: DemoMulticamLink] = [:]
    /// What a body reports after connect when its saved record has no serial yet.
    private var reportedSerials: [String: String] = [:]

    private func coordinator() -> MulticamCoordinator {
        let coordinator = MulticamCoordinator(isCameraRefusal: { $0 is DemoMulticamLink.Refusal })
        coordinator.recordObservationTimeout = .milliseconds(500)
        coordinator.connect = { [unowned self] record in
            let link = DemoMulticamLink(
                serialNumber: record.serialNumber ?? self.reportedSerials[record.host] ?? "")
            link.frameInterval = .milliseconds(10)
            self.links[record.host] = link
            return link
        }
        coordinator.begin()
        return coordinator
    }

    private func record(_ host: String, serial: String?, path: CameraPath = .usbC)
        -> PTPIPSavedCameraRecord
    {
        PTPIPSavedCameraRecord(
            host: host, displayName: "ZR_\(host)", transport: path.legacyTransportLabel,
            lastSeenAt: nil, serialNumber: serial, path: path)
    }

    private func waitUntil(
        _ what: String, timeout: TimeInterval = 3, _ condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("timed out waiting for \(what)") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func live(_ coordinator: MulticamCoordinator, count: Int) async throws {
        // Live, in the engine group, and the first property poll landed (it moves the
        // capabilities a plan's fingerprint rests on).
        try await waitUntil("\(count) live members") {
            coordinator.members.filter { $0.isLive && $0.properties.batteryPercent != nil }.count
                == count && coordinator.group.entries.count == count
        }
    }

    func testFourBodiesJoinAndAFifthIsRefused() async throws {
        let stage = coordinator()
        let paths: [CameraPath] = [
            .usbC, .infrastructure(networkName: "Set"), .phoneHotspot,
            .infrastructure(networkName: "Set"),
        ]
        for index in 0..<4 {
            XCTAssertNotNil(
                stage.add(
                    record("h\(index)", serial: "S\(index)", path: paths[index]), reachable: true))
        }
        try await live(stage, count: 4)
        XCTAssertEqual(stage.members.map(\.slot).sorted(), [0, 1, 2, 3])
        XCTAssertNil(stage.add(record("h4", serial: "S4"), reachable: true))
        XCTAssertEqual(stage.toast, MulticamCopy.sessionFull)
    }

    func testOneBodyJoinsOnceWhateverPathOrHost() async throws {
        let stage = coordinator()
        stage.add(record("usb:zr", serial: "S1"), reachable: true)
        try await live(stage, count: 1)
        // The same serial over the router is the same body.
        XCTAssertNil(
            stage.add(
                record("10.0.0.9", serial: "S1", path: .infrastructure(networkName: "Set")),
                reachable: true))
        XCTAssertEqual(stage.toast, MulticamCopy.alreadyMember)
        // A path saved before the serial stamp is checked again by what its link reports.
        stage.toast = nil
        reportedSerials["10.0.0.7"] = "S1"
        stage.add(
            record("10.0.0.7", serial: nil, path: .infrastructure(networkName: "Set")),
            reachable: true)
        try await waitUntil("duplicate removed") { stage.toast == MulticamCopy.alreadyMember }
        XCTAssertEqual(stage.members.count, 1)
        XCTAssertEqual(links["10.0.0.7"]?.received.last, "shutdown")
        XCTAssertFalse(links["usb:zr"]?.received.contains("shutdown") ?? true)
    }

    /// A5-01: a member's tile draws the body's five-step gauge from its session's typed power,
    /// never a percent it did not report. Twin of Android `tileShowsTheBodysBatteryBars`.
    func testTileShowsTheBodysBatteryBars() async throws {
        let stage = coordinator()
        stage.add(record("usb:zr", serial: "S1"), reachable: true)
        try await live(stage, count: 1)
        let member = try XCTUnwrap(stage.members.first)
        let view = MulticamStage(
            coordinator: stage, confirmsRecord: false, pickerRows: { [] }, openLiveView: { _ in },
            close: {})
        try await waitUntil("the session reports the gauge") {
            view.tile(member).batteryBars != nil
        }
        let tile = view.tile(member)
        // The scripted body reports BatteryLevel 80: four of five bars, no percent.
        XCTAssertNil(tile.battery)
        XCTAssertEqual(tile.batteryBars, 4)
        XCTAssertEqual(tile.batteryBarCount, 5)
        XCTAssertFalse(tile.charging)
    }

    func testRefusedPaths() {
        let stage = coordinator()
        XCTAssertEqual(
            stage.refusal(
                for: record("192.168.1.1", serial: "A", path: .cameraAccessPoint(ssid: "NIKON")),
                reachable: true), MulticamCopy.cameraWiFi)
        XCTAssertEqual(
            stage.refusal(for: record("hdmi", serial: "B", path: .hdmiCapture), reachable: true),
            MulticamCopy.hdmi)
        XCTAssertEqual(
            stage.refusal(for: record("usb:c", serial: "C"), reachable: false),
            MulticamCopy.notReachable)
        XCTAssertNil(stage.refusal(for: record("usb:d", serial: "D"), reachable: true))
    }

    func testMixedGroupStartStaysMixed() async throws {
        let stage = coordinator()
        for index in 0..<3 { stage.add(record("h\(index)", serial: "S\(index)"), reachable: true) }
        try await live(stage, count: 3)
        links["h1"]?.refusesRecord = true

        let plan = stage.groupPlan()
        XCTAssertEqual(plan.direction, .start)
        XCTAssertEqual(plan.targets.count, 3)
        await stage.run(plan)

        XCTAssertEqual(links["h0"]?.isRecording, true)
        XCTAssertEqual(links["h2"]?.isRecording, true)
        XCTAssertEqual(links["h1"]?.isRecording, false)
        XCTAssertEqual(stage.member(atSlot: 1)?.note, MulticamCopy.couldntRec)
        XCTAssertNil(stage.member(atSlot: 0)?.note)
        XCTAssertEqual(stage.toast, "2 of 3 rolling. ZR_h1 didn't start.")
        // Partial success is not a transaction: nothing stops the cameras that started.
        XCTAssertFalse(links["h0"]?.received.contains("stop") ?? true)
        XCTAssertFalse(stage.toast?.lowercased().contains("sync") ?? false)
    }

    func testLiveViewBorrowKeepsTheSessionAndPausesThatPump() async throws {
        let stage = coordinator()
        for index in 0..<3 { stage.add(record("h\(index)", serial: "S\(index)"), reachable: true) }
        try await live(stage, count: 3)
        let borrowed = try XCTUnwrap(stage.member(atSlot: 1))
        let session = try XCTUnwrap(stage.group[borrowed.id]?.cameraSession)
        let before = stage.groupPlan()

        let link = try XCTUnwrap(stage.lend(borrowed.id))
        XCTAssertTrue(link === links["h1"])
        XCTAssertNil(stage.lend(stage.member(atSlot: 0)!.id), "one Live View at a time")
        let frames = links["h1"]!.frameCount
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(links["h1"]!.frameCount, frames, "the lent member's stage pump stands down")
        XCTAssertGreaterThan(links["h0"]!.frameCount, 0)
        // Group record leaves the lent camera to its Live View.
        let during = stage.groupPlan()
        XCTAssertEqual(during.exclusions.map(\.reason), [.busy])
        XCTAssertEqual(during.targets.count, 2)

        stage.reclaim(link)
        try await waitUntil("pump resumed") { links["h1"]!.frameCount > frames }
        XCTAssertEqual(
            stage.group[borrowed.id]?.cameraSession, session, "same session, no reconnect")
        XCTAssertTrue(before.isCurrent(in: stage.group, at: stage.engineState()))
        XCTAssertFalse(links["h1"]!.received.contains("shutdown"), "no CloseSession")
    }

    func testAReplacementLinkFromLiveViewIsANewSession() async throws {
        let stage = coordinator()
        stage.add(record("h0", serial: "S0"), reachable: true)
        try await live(stage, count: 1)
        let member = try XCTUnwrap(stage.member(atSlot: 0))
        let session = stage.group[member.id]?.cameraSession
        let plan = stage.groupPlan()
        _ = stage.lend(member.id)
        let replacement = DemoMulticamLink(serialNumber: "S0")
        replacement.frameInterval = .milliseconds(10)
        stage.reclaim(replacement)
        try await waitUntil("replacement live") { replacement.frameCount > 0 }
        XCTAssertNotEqual(stage.group[member.id]?.cameraSession, session)
        XCTAssertFalse(plan.isCurrent(in: stage.group, at: stage.engineState()))
    }

    func testValuesGoToThatMemberOnlyAndReadBack() async throws {
        let stage = coordinator()
        for index in 0..<2 { stage.add(record("h\(index)", serial: "S\(index)"), reachable: true) }
        try await live(stage, count: 2)
        try await waitUntil("values polled") { stage.member(atSlot: 1)?.properties.iso == 800 }
        let target = try XCTUnwrap(stage.member(atSlot: 1))
        stage.set(.iso(.manual(1600)), on: target.id, label: "ISO")
        try await waitUntil("readback") { target.properties.iso == 1600 }
        XCTAssertTrue(links["h1"]!.received.contains("write \(PTPPropertyCode.movieExposureIndex)"))
        XCTAssertFalse(links["h0"]!.received.contains { $0.hasPrefix("write") })
        XCTAssertNil(target.note)
        XCTAssertEqual(stage.member(atSlot: 0)?.properties.iso, 800)
    }

    func testRemoveAndEndCloseLinksWithoutStoppingRecording() async throws {
        let stage = coordinator()
        for index in 0..<2 { stage.add(record("h\(index)", serial: "S\(index)"), reachable: true) }
        try await live(stage, count: 2)
        await stage.run(stage.groupPlan())
        XCTAssertEqual(links["h0"]?.isRecording, true)
        stage.remove(stage.member(atSlot: 0)!.id)
        stage.end()
        try await waitUntil("links closed") {
            self.links.values.allSatisfy { $0.received.last == "shutdown" }
        }
        for link in links.values { XCTAssertFalse(link.received.contains("stop")) }
        XCTAssertEqual(links["h0"]?.isRecording, true)
    }
}

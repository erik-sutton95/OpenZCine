import MonitorPresentation
import OpenCineAppUITesting
import UIKit
import XCTest

/// Real device qualification reuses the same shared driver as every camera app.
final class PhysicalReferenceAppTests: OpenCineAppUITesting.PhysicalReferenceAppTests {}

/// Opted-in current-build camera qualification through the common physical driver.
final class PhysicalMigrationQualificationTests: OpenCineAppUITesting
        .PhysicalMigrationQualificationTests
{}

// The UI tests every app shares, run against this app through the demo harness's `ReviewLaunch`
// staging. Motion records a capability skip: a Nikon body has no gimbal.
final class CamerasPageFollowupTests: OpenCineAppUITesting.CamerasPageFollowupTests {}
final class DesqueezeUIFlowTests: OpenCineAppUITesting.DesqueezeUIFlowTests {}
/// Parity finding A1-32: Z draws its own photography-only EV needle, not the shared camera EV
/// meter these cases check. They still run; their failure is expected until Z adopts the shared
/// meter, and XCTest reports the first unexpected pass.
final class EVMeterUIFlowTests: OpenCineAppUITesting.EVMeterUIFlowTests {
    override func setUpWithError() throws {
        try super.setUpWithError()
        // The physical case skips before it meets the gap.
        if !name.contains("Physical") {
            XCTExpectFailure("A1-32: Z has its own EV meter, not the shared one")
        }
    }
}
final class MotionUIFlowTests: OpenCineAppUITesting.MotionUIFlowTests {}
final class ShareUIFlowTests: OpenCineAppUITesting.ShareUIFlowTests {}

// The shared conformance scenarios (OpenCine docs/conformance/SCENARIOS.md), run against the app's
// own composition through the demo harness's `ReviewLaunch` staging.
final class GalleryRoundTrip: OpenCineAppUITesting.GalleryRoundTrip {}
final class ShareRoundTrip: OpenCineAppUITesting.ShareRoundTrip {}
final class ConfirmationCancel: OpenCineAppUITesting.ConfirmationCancel {}
final class ChromeEditReturn: OpenCineAppUITesting.ChromeEditReturn {}
final class AccessibilityTraversal: OpenCineAppUITesting.AccessibilityTraversal {}
final class ConformanceCoverageTests: OpenCineAppUITesting.ConformanceCoverageTests {}
/// SIMULATED launch configuration only; layout and pixel assertions stay in OpenCine.
final class MonitorScreenshotLayoutTests: OpenCineAppUITesting.MonitorScreenshotLayoutTests {
    override var expectedStorageText: String { "521 GB" }
    override var expectedCameraPowerValue: String { "4 of 5 bars" }
    override var expectedCameraPercentText: String? { nil }
    override var reviewLaunchEnvironment: [String: String] {
        [
            "ZC_DEMO_AUTOSTART": "1", "ZC_DEMO_QUICK_SETTINGS": "1", "ZC_DEMO_DISP": "live",
            "ZC_DEMO_GRAPHICAL_REVIEW": "1",
        ]
    }
}

/// The launch splash takes every touch until it fades, and a control beneath it reads as not
/// hittable until then; a tap before that is not delivered.
@MainActor
private func waitUntilHittable(_ element: XCUIElement, timeout: TimeInterval = 10) -> Bool {
    let hittable = XCTNSPredicateExpectation(
        predicate: NSPredicate(format: "exists == true AND hittable == true"), object: element)
    return XCTWaiter().wait(for: [hittable], timeout: timeout) == .completed
}

/// Exercises the actual app root, including its pre-page precedence, without a camera.
@MainActor
final class ConnectFunnelAdoptionTests: XCTestCase {
    func testDirectAndIntegrationConsentUseOneSharedAlertAndCancel() {
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        for entry in ["direct", "nearby"] {
            let app = XCUIApplication()
            app.launchEnvironment["ZC_DEMO_CAMERA_LIST"] = "1"
            app.launchEnvironment["ZC_DEMO_CONNECT_CONSENT"] = entry
            app.launch()
            let alert = app.alerts["Take over this camera?"]
            XCTAssertTrue(
                alert.waitForExistence(timeout: 10),
                "every consent entry must reach the same shared presenter: \(entry)")
            XCTAssertTrue(
                alert.staticTexts[
                    "SIMULATED other phone is using this camera. Connecting will disconnect it."
                ].exists)
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "SIMULATED-consent-\(entry)-landscape"
            shot.lifetime = .keepAlways
            add(shot)
            alert.buttons["Cancel"].tap()
            XCTAssertFalse(alert.waitForExistence(timeout: 2))
            XCTAssertFalse(app.buttons["Take Over"].exists)
            app.terminate()
        }
    }

    func testTypedAddSetupChooserPreservesSetupActions() {
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        app.launchEnvironment["ZC_DEMO_SAVED_PATHS"] = "1"
        app.launch()
        defer { app.terminate() }
        // The first saved camera already has its access-point setup: the host offers the rest.
        let addSetup = app.buttons["cameras.addSetup"].firstMatch
        XCTAssertTrue(waitUntilHittable(addSetup))
        addSetup.tap()
        let usb = app.buttons["addSetup.usbC"]
        XCTAssertTrue(usb.waitForExistence(timeout: 5))
        XCTAssertTrue(usb.isHittable)
        XCTAssertTrue(app.buttons["addSetup.infrastructure"].isHittable)
        XCTAssertTrue(app.buttons["addSetup.phoneHotspot"].exists)
        XCTAssertFalse(app.buttons["addSetup.cameraAccessPoint"].exists)
        XCTAssertEqual(usb.label, "Connect When Plugged In")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "SIMULATED-typed-add-setup-landscape"
        shot.lifetime = .keepAlways
        add(shot)
        app.buttons["Cancel"].tap()
        XCTAssertTrue(addSetup.waitForExistence(timeout: 5))
    }

    func testAppOwnedFirstFrameProgressKeepsItsEscape() {
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        // With the progress sheet (first frame pending) and without it (live view never started).
        for (mode, line) in [
            ("standalone", "Starting live view"), ("neverStarted", "SIMULATED live view did not start"),
        ] {
            let app = XCUIApplication()
            app.launchEnvironment["ZC_DEMO_SAVED_PATHS"] = "1"
            app.launchEnvironment["ZC_DEMO_CONNECT_PREPARING"] = mode
            app.launch()
            let cancel = app.buttons["Cancel"].firstMatch
            XCTAssertTrue(cancel.waitForExistence(timeout: 10), mode)
            // Hittable once the launch splash, which takes touches until it fades, is gone.
            XCTAssertTrue(waitUntilHittable(cancel), mode)
            // The established session keeps its useful progress line, not a bare page.
            XCTAssertTrue(
                app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", line))
                    .firstMatch.waitForExistence(timeout: 5), mode)
            XCTAssertFalse(app.buttons["Back to cameras"].exists, "no separate preparing page")
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "SIMULATED-app-owned-first-frame-\(mode)-landscape"
            shot.lifetime = .keepAlways
            add(shot)
            cancel.tap()
            XCTAssertTrue(app.buttons["cameras.pair"].waitForExistence(timeout: 5), mode)
            app.terminate()
        }
    }

    func testTypedSetupPrecedenceAndStoredLegacyFallback() {
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        for mode in ["both", "legacy"] {
            let app = XCUIApplication()
            app.launchEnvironment["ZC_DEMO_SAVED_PATHS"] = "1"
            app.launchEnvironment["ZC_DEMO_CHOOSER_SLOT"] = mode
            app.launch()
            let addSetup = app.buttons["cameras.addSetup"].firstMatch
            XCTAssertTrue(waitUntilHittable(addSetup))
            addSetup.tap()
            let expected = mode == "legacy" ? "Legacy chooser" : "Typed chooser"
            let absent = mode == "legacy" ? "Typed chooser" : "Legacy chooser"
            XCTAssertTrue(app.staticTexts[expected].waitForExistence(timeout: 5))
            XCTAssertFalse(app.staticTexts[absent].exists)
            app.buttons["Cancel"].tap()
            XCTAssertTrue(addSetup.waitForExistence(timeout: 5))
            app.terminate()
        }
    }

    /// The launch splash takes touches until it fades, so a control beneath it must not read as
    /// hittable: an early tap was lost and the add-setup chooser never opened.
    func testLaunchSplashKeepsTheCamerasPageUnhittableUntilItFades() {
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        app.launchEnvironment["ZC_DEMO_SAVED_PATHS"] = "1"
        app.launch()
        defer { app.terminate() }
        let splash = app.descendants(matching: .any)["monitor-launch-splash"]
        let addSetup = app.buttons["cameras.addSetup"].firstMatch
        XCTAssertTrue(splash.waitForExistence(timeout: 10), "the launch splash must be in the AX tree")
        var coveredSamples = 0
        let deadline = Date().addingTimeInterval(15)
        while splash.exists, Date() < deadline {
            let hittable = addSetup.exists && addSetup.isHittable
            // Only a sample the splash bracketed on both sides counts.
            if splash.exists {
                coveredSamples += 1
                XCTAssertFalse(hittable, "a control under the launch splash read as hittable")
            }
        }
        XCTAssertGreaterThan(coveredSamples, 0)
        XCTAssertFalse(splash.exists, "the launch splash must leave the AX tree once it fades")
        XCTAssertTrue(waitUntilHittable(addSetup))
        addSetup.tap()
        XCTAssertTrue(app.buttons["addSetup.usbC"].waitForExistence(timeout: 5))
    }


    func testSharedProgressSurvivesPostHandshakePreparation() {
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        app.launchEnvironment["ZC_DEMO_SAVED_PATHS"] = "1"
        app.launchEnvironment["ZC_DEMO_CARD"] = "connecting"
        app.launchEnvironment["ZC_DEMO_CONNECT_PREPARING"] = "1"
        app.launch()
        defer { app.terminate() }
        let cancel = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Cancel connecting to")
        ).firstMatch
        XCTAssertTrue(
            cancel.waitForExistence(timeout: 10),
            "shared progress must retain its operator cancel after handshake")
        XCTAssertFalse(
            app.buttons["Back to cameras"].exists,
            "a second preparing page must not replace shared progress")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "SIMULATED-shared-connect-preparing-landscape"
        shot.lifetime = .keepAlways
        add(shot)
    }
}

/// Device lane DEF-Z-FIRSTRUN-WIZARD: a fresh install reaches the same transport wizard as Pair a
/// new camera (Cable Link, Camera AP), not a bare pair page without a way on.
@MainActor
final class FirstRunWizardTests: XCTestCase {
    func testFreshInstallOpensTheTransportWizard() {
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        app.launchEnvironment["ZC_DEMO_FRESH_INSTALL"] = "1"
        app.launch()
        defer { app.terminate() }
        // The wizard's first step: the transport choice, or the permissions step before it on
        // builds that still ask first (A2-09 moves it after the choice).
        let wizard = app.staticTexts.matching(
            NSPredicate(format: "label IN %@", ["Choose how to connect", "Allow permissions"])
        ).firstMatch
        XCTAssertTrue(wizard.waitForExistence(timeout: 15), "first run must open the transport wizard")
        XCTAssertFalse(app.staticTexts["Find your camera"].exists, "not the bare shared pair page")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "SIMULATED-first-run-wizard-landscape"
        shot.lifetime = .keepAlways
        add(shot)
    }
}

/// SIMULATED decisions over actual public AppKit screens with no integrations or transport.
@MainActor
final class StandaloneConsentPresentationTests: XCTestCase {
    func testStandaloneCamerasScreenAnswersAndCancels() { exercise("cameras") }
    func testStandalonePairScreenAnswersAndCancels() { exercise("pair") }
    func testNestedSameOwnerHasExactlyOnePresenter() { exercise("nestedSame") }
    func testNestedDifferentOwnerIsNotSuppressedAndParentSurvivesChildRemoval() {
        exercise("nestedDifferent", checksParent: true)
    }

    private func exercise(_ mode: String, checksParent: Bool = false) {
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        app.launchEnvironment["ZC_DEMO_CAMERA_LIST"] = "1"
        app.launchEnvironment["ZC_DEMO_CONSENT_SCREEN"] = mode
        app.launch()
        defer { app.terminate() }
        let show = app.buttons["Show decision"]
        XCTAssertTrue(waitUntilHittable(show))
        show.tap()
        let alert = app.alerts["SIMULATED decision"]
        guard alert.waitForExistence(timeout: 5) else {
            XCTFail("actual shared screen must present its own consent: \(mode)")
            return
        }
        XCTAssertEqual(app.alerts.count, 1)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "SIMULATED-consent-screen-\(mode)-landscape"
        shot.lifetime = .keepAlways
        add(shot)
        alert.buttons["Continue"].tap()
        XCTAssertTrue(app.staticTexts["Answers: 1, cancels: 0"].waitForExistence(timeout: 5))
        XCTAssertFalse(alert.exists)
        show.tap()
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["Cancel"].tap()
        XCTAssertTrue(app.staticTexts["Answers: 1, cancels: 1"].waitForExistence(timeout: 5))
        XCTAssertFalse(alert.exists)
        if checksParent {
            app.buttons["Hide child"].tap()
            XCTAssertTrue(app.staticTexts["Child removed"].waitForExistence(timeout: 5))
            app.buttons["Show parent decision"].tap()
            XCTAssertTrue(alert.waitForExistence(timeout: 5))
            alert.buttons["Continue"].tap()
            XCTAssertTrue(app.staticTexts["Answers: 2, cancels: 1"].waitForExistence(timeout: 5))
        }
    }
}

/// SIMULATED pixels through the actual app/provider/inspector; no camera transport or hardware claim.
final class NikonLiveLUTWheelTouchTests: SharedAppUITestCase {
    @MainActor
    func testActualLiveWheelDragChangesNikonLookAndPicture() throws {
        #if !targetEnvironment(simulator)
            throw XCTSkip("The generated feed is a simulator presentation fixture")
        #endif
        continueAfterFailure = false
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SIMULATED-F11-LUT-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let feed = UIGraphicsImageRenderer(size: CGSize(width: 320, height: 180)).image { context in
            UIColor.green.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 320, height: 180))
        }
        try XCTUnwrap(feed.pngData()).write(to: directory.appendingPathComponent("1.png"))
        defer {
            app?.terminate()
            XCUIDevice.shared.orientation = .portrait
            try? FileManager.default.removeItem(at: directory)
        }
        launch(
            ReviewLaunch(screen: .live),
            environment: [
                "ZC_DEMO_FEED_DIR": directory.path, "ZC_DEMO_LUT": "Mono",
                "ZC_DEMO_SPLIT": "off",
            ])
        rotate(.landscapeRight)
        let expand = app.buttons["monitor.assists.expand"]
        if expand.waitForExistence(timeout: 5) { expand.tap() }
        let lut = app.buttons["monitor.assist.LUT"]
        XCTAssertTrue(lut.waitForExistence(timeout: 5))
        XCTAssertTrue(lut.isHittable)
        // The same established long-press entry as the shared assist UI flow tests.
        lut.press(forDuration: 0.6)
        XCTAssertTrue(app.buttons["monitor.assist.close"].waitForExistence(timeout: 5))
        let preview = app.images["monitor.inspector.preview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        func waitFor(_ name: String, _ condition: @escaping @MainActor () -> Bool) {
            let ready = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in MainActor.assumeIsolated { condition() } },
                object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed, name)
        }
        func previewPixel() -> [UInt8]? {
            guard preview.exists, let image = preview.screenshot().image.cgImage else { return nil }
            var pixel = [UInt8](repeating: 0, count: 4)
            pixel.withUnsafeMutableBytes { bytes in
                let context = CGContext(
                    data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                    bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                context?.draw(
                    image,
                    in: CGRect(
                        x: -CGFloat(image.width) / 2, y: -CGFloat(image.height) / 2,
                        width: CGFloat(image.width), height: CGFloat(image.height)))
            }
            return pixel
        }
        waitFor("The actual Mono inspector renders the green fixture as gray") {
            guard preview.value as? String == "Picture", let pixel = previewPixel() else {
                return false
            }
            return pixel[1] > 30 && abs(Int(pixel[0]) - Int(pixel[1])) < 5
                && abs(Int(pixel[1]) - Int(pixel[2])) < 5
        }
        capture("SIMULATED-XCUI-Nikon-Mono-before-wheel-drag")
        let options = try XCTUnwrap(
            app.scrollViews.allElementsBoundByIndex.first {
                $0.images["monitor.inspector.preview"].exists
            }, "The actual inspector owns its option scroll view")
        let mono = app.staticTexts["Mono"].firstMatch
        XCTAssertTrue(mono.exists)
        for _ in 0..<3 where !options.frame.contains(mono.frame) { options.swipeUp() }
        XCTAssertTrue(options.frame.contains(mono.frame))
        XCTAssertTrue(mono.isHittable)
        let wheel = try XCTUnwrap(
            app.scrollViews.allElementsBoundByIndex.filter {
                $0.staticTexts["Mono"].exists && $0.staticTexts["Log3G10→709"].exists
            }.min { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height },
            "The real preset wheel is nested inside the actual inspector")
        XCTAssertLessThan(wheel.frame.height, options.frame.height)
        let titles = ["Log3G10→709", "N-Log→709", "Mono", "R3D NE Monitor"]
        func centeredTitle() -> String? {
            titles.first {
                let row = app.staticTexts[$0].firstMatch
                return row.exists && abs(row.frame.midY - wheel.frame.midY) < 2
            }
        }
        XCTAssertEqual(centeredTitle(), "Mono")
        func waitForSettledRow(changedFrom previous: String) {
            var last: (String, CGRect)?
            var unchangedSince = Date()
            waitFor("The dragged Nikon preset row settles and changes selection") {
                guard let title = centeredTitle(), title != previous else { return false }
                let frame = self.app.staticTexts[title].firstMatch.frame
                if last?.0 != title || last?.1 != frame {
                    last = (title, frame)
                    unchangedSince = Date()
                    return false
                }
                // The same stable-frame boundary used by SharedAppUITestCase.rotate.
                return Date().timeIntervalSince(unchangedSince) >= 0.5
            }
        }
        for _ in 0..<4 where centeredTitle() != "Log3G10→709" {
            let previous = try XCTUnwrap(centeredTitle())
            let halfRow = mono.frame.height / 2
            let center = wheel.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            let start = center.withOffset(CGVector(dx: 0, dy: -halfRow))
            let end = center.withOffset(CGVector(dx: 0, dy: halfRow))
            // Element frames and the drag offsets share the app's interface coordinates.
            let startPoint = CGPoint(x: wheel.frame.midX, y: wheel.frame.midY - halfRow)
            let endPoint = CGPoint(x: wheel.frame.midX, y: wheel.frame.midY + halfRow)
            let geometry =
                "options=\(options.frame) wheel=\(wheel.frame) start=\(startPoint) "
                + "end=\(endPoint) screen=\(start.screenPoint)->\(end.screenPoint)"
            XCTAssertTrue(options.frame.contains(startPoint), geometry)
            XCTAssertTrue(options.frame.contains(endPoint), geometry)
            XCTAssertTrue(wheel.frame.contains(startPoint), geometry)
            XCTAssertTrue(wheel.frame.contains(endPoint), geometry)
            // Real synthesized touch; no model mutation, binding setter or app test endpoint.
            start.press(forDuration: 0, thenDragTo: end)
            waitForSettledRow(changedFrom: previous)
        }
        XCTAssertEqual(centeredTitle(), "Log3G10→709")
        capture("SIMULATED-XCUI-Nikon-Log3G10-selected-by-wheel-drag")
        for _ in 0..<3 where !options.frame.contains(preview.frame) { options.swipeDown() }
        XCTAssertTrue(options.frame.contains(preview.frame))
        waitFor("The actual touched selection changes gray Mono into the green Log3G10 picture") {
            guard preview.value as? String == "Picture", let pixel = previewPixel() else {
                return false
            }
            return Int(pixel[1]) > Int(pixel[0]) + 20 && Int(pixel[1]) > Int(pixel[2]) + 20
        }
        XCTAssertEqual(
            app.buttons.matching(NSPredicate(format: "label == %@", "50 / 50 split")).count, 1)
        XCTAssertFalse(app.sliders["Exposure"].exists)
        capture("SIMULATED-XCUI-Nikon-Log3G10-render-after-wheel-drag")
    }
}

/// Z Settings through the shared settings owner, which no Z UI test covered before: every tab in
/// portrait and landscape, the HDR display row (A2-31) and the problem report over the app root
/// with Settings still under it (A2-24).
final class SettingsUIFlowTests: SharedAppUITestCase {
    override func setUp() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    override func tearDown() {
        app?.terminate()
        XCUIDevice.shared.orientation = .portrait
    }

    func testEveryTabInBothOrientationsWithHDRDisplayAndTheRootReport() {
        launch(ReviewLaunch(screen: .settings))
        let tabs = app.scrollViews["monitor.settings.tabs"]
        XCTAssertTrue(tabs.waitForExistence(timeout: 30))
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            rotate(orientation)
            let side = orientation == .portrait ? "portrait" : "landscape"
            for tab in MonitorSettingsTab.allCases {
                let button = app.buttons["monitor.settings.tab.\(tab.rawValue)"]
                XCTAssertTrue(button.waitForExistence(timeout: 5), "\(tab.rawValue) tab")
                reveal(button, in: tabs, portrait: orientation == .portrait)
                button.tap()
                XCTAssertTrue(button.isSelected)
                if tab == .display {
                    XCTAssertTrue(app.staticTexts["HDR display"].firstMatch.waitForExistence(timeout: 5))
                }
                let slug = tab.rawValue.lowercased().replacingOccurrences(of: " ", with: "-")
                capture("z-settings-\(slug)-\(side)")
            }
            let report = app.buttons["support.report.open"]
            XCTAssertTrue(report.waitForExistence(timeout: 5))
            for _ in 0..<4 where !report.isHittable { app.swipeUp() }
            report.tap()
            XCTAssertTrue(app.textViews["What happened?"].waitForExistence(timeout: 5))
            capture("z-settings-report-\(side)")
            app.buttons["Close"].firstMatch.tap()
            XCTAssertTrue(app.buttons["monitor.settings.tab.System"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.textViews["What happened?"].exists)
        }
    }

    private func reveal(_ tab: XCUIElement, in rail: XCUIElement, portrait: Bool) {
        for _ in 0..<6 where !tab.isHittable {
            if portrait {
                if tab.frame.minX < rail.frame.minX { rail.swipeRight() } else { rail.swipeLeft() }
            } else {
                if tab.frame.minY < rail.frame.minY { rail.swipeDown() } else { rail.swipeUp() }
            }
        }
    }
}

/// DISP 3 through the shared command dashboard: a long-press drag reorders the primary grid and
/// the new order is what the next launch shows.
final class CommandGridReorderUITests: SharedAppUITestCase {
    private let environment = ["ZC_DEMO_DISP": "command"]

    override func tearDown() {
        app?.terminate()
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func testDragReordersATileAndTheOrderSurvivesRelaunch() throws {
        continueAfterFailure = false
        open()
        let before = try order()
        XCTAssertGreaterThanOrEqual(before.count, 4, "The video grid shows its tiles")
        capture("z-command-grid-before-drag")
        drag(before[0], onto: before[2])
        var moved = before
        moved.insert(moved.remove(at: 0), at: 2)
        XCTAssertTrue(waitFor(moved), "The held tile lands in the slot it was dropped on")
        capture("z-command-grid-after-drag")

        app.terminate()
        open()
        XCTAssertTrue(waitFor(moved), "The next launch keeps the operator's order")
        capture("z-command-grid-after-relaunch")

        // Leave the order as the run found it.
        drag(before[0], onto: moved[0])
        XCTAssertTrue(waitFor(before), "Dragging back restores the original order")
    }

    /// The side column and the portrait stack live in scrollers, which only an app host vends.
    @MainActor
    func testSideColumnCellsAndThePortraitStackAreReachable() throws {
        continueAfterFailure = false
        open()
        let side = app.descendants(matching: .any)["monitor.command.side"]
        XCTAssertTrue(side.waitForExistence(timeout: 10), "The side column is one labelled container")
        XCTAssertEqual(
            side.label,
            "Image, Focus, Audio, and Monitor controls. Swipe up to reveal more command controls.")
        XCTAssertTrue(app.buttons["Area"].waitForExistence(timeout: 5), "Side cells are buttons")
        XCTAssertTrue(label("Temp").firstMatch.exists, "Landscape shows the health strip")

        rotate(.portrait, settling: tiles.firstMatch)
        XCTAssertTrue(tiles.firstMatch.waitForExistence(timeout: 10), "Portrait stacks the grid")
        XCTAssertTrue(app.buttons["Area"].waitForExistence(timeout: 5), "and the sections below it")
        XCTAssertEqual(label("Temp").count, 0, "Portrait has no health strip")
        capture("z-command-dashboard-portrait-stack")
    }

    @MainActor
    func testPortraitViewportShowsWholePrimaryTilesAndScrollsToTheLastSection() throws {
        continueAfterFailure = false
        open()
        rotate(.portrait, settling: tiles.firstMatch)
        let scroller = app.scrollViews.containing(.any, identifier: "monitor.command.tile.iso").firstMatch
        XCTAssertTrue(scroller.waitForExistence(timeout: 10))
        XCTAssertGreaterThanOrEqual(
            scroller.frame.height, 246,
            "The portrait viewport must show the three 76-point primary rows and their two 9-point gaps")
        XCTAssertFalse(
            app.buttons["monitor.system.focusReset"].exists,
            "Picture-only recenter controls must not cover the command dashboard")
        for identifier in try order() {
            let tile = tiles.matching(identifier: identifier).firstMatch
            XCTAssertTrue(
                contained(tile, in: scroller),
                "The whole primary tile \(identifier) \(tile.frame) must fit inside \(scroller.frame)")
        }
        scroller.swipeUp()
        let last = app.buttons["Grid"]
        XCTAssertTrue(contained(last, in: scroller), "Scrolling reaches the complete final read-only cell")
        capture("z-command-dashboard-portrait-scrolled-end")
    }

    @MainActor
    func testLandscapeSideColumnShowsItsOverflowCueUntilTheEnd() {
        continueAfterFailure = false
        open()
        let side = app.descendants(matching: .any)["monitor.command.side"]
        let more = app.descendants(matching: .any)["monitor.command.more"]
        XCTAssertTrue(more.waitForExistence(timeout: 10), "The overflowing side column must show its scroll cue")
        XCTAssertEqual(more.label, "More command controls below. Swipe up to reveal them.")
        side.swipeUp()
        XCTAssertTrue(contained(app.buttons["Grid"], in: side), "Scrolling reaches the final read-only cell")
        XCTAssertTrue(more.waitForNonExistence(timeout: 10), "The cue clears at the actual content bottom")
        capture("z-command-dashboard-landscape-scrolled-end")
    }

    @MainActor private func contained(_ element: XCUIElement, in viewport: XCUIElement) -> Bool {
        let visible = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            MainActor.assumeIsolated {
                element.exists && !element.frame.isEmpty
                    // Native accessibility edges can round by one display point.
                    && viewport.frame.insetBy(dx: -1, dy: -1).contains(element.frame)
            }
        }, object: nil)
        return XCTWaiter().wait(for: [visible], timeout: 10) == .completed
    }

    @MainActor private func label(_ text: String) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", text))
    }

    @MainActor private func open() {
        launch(ReviewLaunch(screen: .live), environment: environment)
        rotate(.landscapeLeft, settling: tiles.firstMatch)
        XCTAssertTrue(tiles.firstMatch.waitForExistence(timeout: 30), "DISP 3 shows the command grid")
        XCTAssertTrue(waitUntilHittable(tiles.firstMatch, timeout: 15))
    }

    @MainActor private var tiles: XCUIElementQuery {
        app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'monitor.command.tile.'"))
    }

    /// Tile identifiers in reading order: top row first, left to right.
    @MainActor private func order() throws -> [String] {
        let root = try app.snapshot()
        var found: [String: CGRect] = [:]
        func collect(_ element: XCUIElementSnapshot) {
            if element.identifier.hasPrefix("monitor.command.tile."), found[element.identifier] == nil {
                found[element.identifier] = element.frame
            }
            element.children.forEach(collect)
        }
        collect(root)
        return found.sorted {
            let (first, second) = ($0.value, $1.value)
            return first.midY.rounded() != second.midY.rounded()
                ? first.midY < second.midY : first.midX < second.midX
        }.map(\.key)
    }

    @MainActor private func waitFor(_ expected: [String]) -> Bool {
        let arranged = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
            MainActor.assumeIsolated { (try? order()) == expected }
        }, object: nil)
        return XCTWaiter().wait(for: [arranged], timeout: 10) == .completed
    }

    @MainActor private func drag(_ identifier: String, onto target: String) {
        let center = CGVector(dx: 0.5, dy: 0.5)
        let source = tiles.matching(identifier: identifier).firstMatch
        let destination = tiles.matching(identifier: target).firstMatch
        XCTAssertTrue(waitUntilHittable(source))
        source.coordinate(withNormalizedOffset: center).press(
            forDuration: 0.8, thenDragTo: destination.coordinate(withNormalizedOffset: center),
            withVelocity: .slow, thenHoldForDuration: 0.4)
    }
}

/// DISP 3 in landscape and portrait, attached to the result bundle for visual review.
final class CommandGridScreenshotUITests: SharedAppUITestCase {
    override func tearDown() {
        app?.terminate()
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func testCommandDashboardInBothOrientations() {
        launch(ReviewLaunch(screen: .live), environment: ["ZC_DEMO_DISP": "command"])
        let tile = app.descendants(matching: .any)["monitor.command.tile.iso"]
        XCTAssertTrue(tile.waitForExistence(timeout: 30), "The dashboard must mount before capture")
        for orientation in [UIDeviceOrientation.landscapeLeft, .portrait] {
            rotate(orientation, settling: tile)
            XCTAssertTrue(waitUntilHittable(tile), "The mounted dashboard must clear the launch splash")
            capture("z-command-dashboard-\(orientation == .portrait ? "portrait" : "landscape")")
        }
    }
}

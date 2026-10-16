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
/// Parity finding A1-32 closed: the body's exposure indicator feeds the shared camera EV meter.
final class EVMeterUIFlowTests: OpenCineAppUITesting.EVMeterUIFlowTests {}
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
            XCTAssertTrue(cancel.isHittable, mode)
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

    /// The cameras page settles after the launch splash; a tap before then is not delivered.
    private func waitUntilHittable(_ element: XCUIElement, timeout: TimeInterval = 10) -> Bool {
        let hittable = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND hittable == true"), object: element)
        return XCTWaiter().wait(for: [hittable], timeout: timeout) == .completed
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
        XCTAssertTrue(show.waitForExistence(timeout: 10))
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

/// SIMULATED: the codec and colour readouts open one popup listing the codec ladder and the
/// staged H.265 tones (SDR, HLG, N-Log), in both orientations.
final class CodecColorPopupUITests: OpenCineAppUITesting.CodecColorPopupUITests {
    override var hasCodecReadout: Bool { true }
    override var reviewLaunchEnvironment: [String: String] {
        [
            "ZC_DEMO_AUTOSTART": "1", "ZC_DEMO_QUICK_SETTINGS": "1", "ZC_DEMO_DISP": "live",
            "ZC_DEMO_GRAPHICAL_REVIEW": "1", "ZC_DEMO_CODEC_DESCRIPTOR": "1",
        ]
    }
}

/// SIMULATED: ISO, shutter, white balance and focus open the shared drawer and mode strip, in
/// both orientations, as on every app. Z names white balance by its common setting key.
final class CapturePopupUITests: OpenCineAppUITesting.CapturePopupUITests {
    override var reviewLaunchEnvironment: [String: String] {
        [
            "ZC_DEMO_AUTOSTART": "1", "ZC_DEMO_QUICK_SETTINGS": "1", "ZC_DEMO_DISP": "live",
            "ZC_DEMO_GRAPHICAL_REVIEW": "1",
        ]
    }
    override var readouts: [(popup: String, identifier: String)] {
        [
            ("iso", "monitor.capture.iso"), ("shutter", "monitor.capture.shutter"),
            ("wb", "monitor.capture.whiteBalance"), ("focus", "monitor.capture.focus"),
        ]
    }
}

/// SIMULATED: in photography the ISO popup is the same shared ladder drawer as in movie mode,
/// with the body's Auto and Manual tabs on the shared mode strip.
final class NikonPhotoCapturePopupUITests: SharedAppUITestCase {
    @MainActor
    func testSIMULATEDPhotoISOOpensTheSharedLadderDrawer() throws {
        #if !targetEnvironment(simulator)
            throw XCTSkip("SIMULATED popup staging requires a private simulator")
        #endif
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment.merge(
            [
                "ZC_DEMO_AUTOSTART": "1", "ZC_DEMO_QUICK_SETTINGS": "1", "ZC_DEMO_DISP": "live",
                "ZC_DEMO_GRAPHICAL_REVIEW": "1", "ZC_DEMO_PHOTO": "1",
            ]
        ) { _, value in value }
        app.launch()
        defer {
            app.terminate()
            XCUIDevice.shared.orientation = .portrait
        }
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            let iso = app.buttons["monitor.capture.stillISO"]
            XCTAssertTrue(iso.waitForExistence(timeout: 20), "The photo ISO readout must be shown")
            rotate(orientation, settling: iso)
            tapWhenReady(iso, in: app, "The photo ISO readout")
            XCTAssertTrue(
                app.buttons["monitor.capture.close"].waitForExistence(timeout: 8),
                "The photo ISO readout must open the common drawer")
            XCTAssertTrue(
                app.descendants(matching: .any)["ladder_sheet"].waitForExistence(timeout: 5),
                "Photo ISO must draw the shared ladder sheet")
            let auto = app.buttons["monitor.capture.tab.0"]
            let manual = app.buttons["monitor.capture.tab.1"]
            XCTAssertTrue(auto.waitForExistence(timeout: 5))
            XCTAssertEqual(auto.label, "Auto")
            XCTAssertEqual(manual.label, "Manual")
            XCTAssertNotEqual(auto.isSelected, manual.isSelected, "Exactly one tab is selected")
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            let name = orientation == .portrait ? "portrait" : "landscape"
            shot.name = "SIMULATED Z photo iso popup \(name)"
            shot.lifetime = .keepAlways
            add(shot)
            let close = app.buttons["monitor.capture.close"]
            close.tap()
            XCTAssertTrue(close.waitForNonExistence(timeout: 8))
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

/// SIMULATED: in photography the body's exposure indicator (+4/6 EV, staged by `ZC_DEMO_EV`) is
/// drawn by the shared camera EV meter every app uses, in both orientations. No camera transport.
final class NikonSharedEVMeterUITests: SharedAppUITestCase {
    @MainActor
    func testSIMULATEDCameraIndicatorDrawsTheSharedEVMeterInBothOrientations() throws {
        #if !targetEnvironment(simulator)
            throw XCTSkip("SIMULATED meter staging requires a private simulator")
        #endif
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment.merge(
            [
                "ZC_DEMO_AUTOSTART": "1", "ZC_DEMO_DISP": "live", "ZC_DEMO_GRAPHICAL_REVIEW": "1",
                "ZC_DEMO_PHOTO": "1", "ZC_DEMO_EV": "4",
            ]
        ) { _, value in value }
        app.launch()
        defer {
            app.terminate()
            XCUIDevice.shared.orientation = .portrait
        }
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            let meter = app.descendants(matching: .any)["monitor.ev.meter"]
            XCTAssertTrue(meter.waitForExistence(timeout: 20), "The shared EV meter must be shown")
            let reading = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "value == %@", "Camera exposure +0.7 EV"), object: meter)
            XCTAssertEqual(XCTWaiter.wait(for: [reading], timeout: 10), .completed)
            XCTAssertTrue(app.frame.contains(meter.frame), "The meter must be on screen")
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "SIMULATED Z shared EV meter \(orientation == .portrait ? "portrait" : "landscape")"
            shot.lifetime = .keepAlways
            add(shot)
        }
    }
}

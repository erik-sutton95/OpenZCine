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
final class PhysicalCameraNetworkTests: OpenCineAppUITesting.PhysicalCameraNetworkTests {}
/// The first-pair wizard cases (Z3 items 1, 2, 3 and 5) drive this app's wizard.
final class PhysicalCameraPairingTests: OpenCineAppUITesting.PhysicalCameraPairingTests {}

// The UI tests every app shares, run against this app through the demo harness's `ReviewLaunch`
// staging. Motion records a capability skip: a Nikon body has no gimbal.
final class CamerasPageFollowupTests: OpenCineAppUITesting.CamerasPageFollowupTests {}
final class DesqueezeUIFlowTests: OpenCineAppUITesting.DesqueezeUIFlowTests {}
/// Parity finding A1-32 closed: the body's exposure indicator feeds the shared camera EV meter.
/// A Nikon body offers that meter in photography only (`MonitorAssistCapabilities.nikon`), so the
/// review stages the demo camera in photography.
final class EVMeterUIFlowTests: OpenCineAppUITesting.EVMeterUIFlowTests {
    override var meterLaunchEnvironment: [String: String] { ["ZC_DEMO_PHOTO": "1"] }
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
final class ScreenMatrix: OpenCineAppUITesting.ScreenMatrix {}
final class ConformanceCoverageTests: OpenCineAppUITesting.ConformanceCoverageTests {}
/// SIMULATED launch configuration only; layout and pixel assertions stay in OpenCine.
final class MonitorScreenshotLayoutTests: OpenCineAppUITesting.MonitorScreenshotLayoutTests {
    override var expectedStorageText: String { "521GB" }
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
        // OpenCine's shared chooser, the one Pocket shows, with Nikon's own routes as options.
        XCTAssertTrue(
            app.staticTexts["How should this camera connect?"].waitForExistence(timeout: 5))
        // A demo camera without a model is named alone, no dangling separator.
        XCTAssertFalse(
            app.staticTexts.matching(NSPredicate(format: "label ENDSWITH %@", " ·")).firstMatch
                .exists)
        XCTAssertFalse(
            app.staticTexts.matching(
                NSPredicate(format: "label BEGINSWITH %@", "Add a setup")
            ).firstMatch.exists)
        let usb = app.buttons["addSetup.usb"]
        XCTAssertTrue(usb.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["addSetup.wifi"].exists)
        XCTAssertTrue(app.buttons["addSetup.phoneHotspot"].exists)
        XCTAssertFalse(app.buttons["addSetup.cameraAccessPoint"].exists)
        XCTAssertEqual(app.buttons["addSetup.wifi"].label, "Find on this network")
        XCTAssertEqual(usb.label, "Connect when plugged in")
        // Shared order: the networks first, then the cable.
        XCTAssertLessThan(app.buttons["addSetup.wifi"].frame.minY, usb.frame.minY)
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
            ("standalone", "Starting live view"),
            ("neverStarted", "SIMULATED live view did not start"),
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
        // A hosted runner spends most of the normal 2.25 s splash inside the launch itself, so
        // the splash could leave before one bracketed sample. Holding it keeps the proof the same.
        app.launchEnvironment["ZC_DEMO_SPLASH_HOLD_MS"] = "10000"
        app.launch()
        defer { app.terminate() }
        let splash = app.descendants(matching: .any)["monitor-launch-splash"]
        let addSetup = app.buttons["cameras.addSetup"].firstMatch
        XCTAssertTrue(
            splash.waitForExistence(timeout: 10), "the launch splash must be in the AX tree")
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
        XCTAssertTrue(
            wizard.waitForExistence(timeout: 15), "first run must open the transport wizard")
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

/// SIMULATED native input: compact level options keep their 44pt target without a taller drawing.
final class LevelSelectorHitTargetTests: SharedAppUITestCase {
    @MainActor
    func testSIMULATEDLevelOptionsAcceptUpperAndLowerTargetEdgeTaps() throws {
        #if !targetEnvironment(simulator)
            throw XCTSkip("SIMULATED level staging requires a private simulator")
        #endif
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment.merge([
            "ZC_DEMO_AUTOSTART": "1", "ZC_DEMO_QUICK_SETTINGS": "1", "ZC_DEMO_DISP": "live",
            "ZC_DEMO_GRAPHICAL_REVIEW": "1",
        ]) { _, value in value }
        app.launch()
        defer {
            app.terminate()
            XCUIDevice.shared.orientation = .portrait
        }
        let expand = app.buttons["monitor.assists.expand"]
        XCTAssertTrue(expand.waitForExistence(timeout: 20))
        rotate(.landscapeLeft, settling: expand)
        tapWhenReady(expand, in: app, "The View Assist palette")
        let level = app.buttons["monitor.assist.LEVEL"]
        for _ in 0..<5 where !level.isHittable {
            let palette = app.scrollViews.allElementsBoundByIndex.first {
                $0.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'monitor.assist.'"))
                    .count > 0
            }
            try XCTUnwrap(palette, "View Assist palette must be scrollable").swipeLeft()
        }
        XCTAssertTrue(level.isHittable)
        level.press(forDuration: 0.6)
        let horizon = app.buttons["Horizon"].firstMatch
        let gauge = app.buttons["Gauge"].firstMatch
        XCTAssertTrue(horizon.waitForExistence(timeout: 8))
        XCTAssertTrue(gauge.waitForExistence(timeout: 8))
        for orientation in [UIDeviceOrientation.landscapeLeft, .portrait] {
            rotate(orientation, settling: horizon)
            for (target, other) in [(horizon, gauge), (gauge, horizon)] {
                for offset in [CGFloat(-21), 21] {
                    tapWhenReady(other, in: app, "The other level style")
                    waitForSelected(other)
                    // One point inside the 44pt floor, outside the compact painted label.
                    target.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                        .withOffset(CGVector(dx: 0, dy: offset)).tap()
                    waitForSelected(target)
                    XCTAssertFalse(other.isSelected, "An edge tap must select only its own option")
                }
            }
            capture("SIMULATED-level-target-\(orientation.rawValue)")
        }
    }

    @MainActor
    private func waitForSelected(_ option: XCUIElement) {
        let selected = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "selected == true"), object: option)
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 5), .completed)
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
                predicate: NSPredicate(format: "value == %@", "Camera exposure +0.7 EV"),
                object: meter)
            XCTAssertEqual(XCTWaiter.wait(for: [reading], timeout: 10), .completed)
            XCTAssertTrue(app.frame.contains(meter.frame), "The meter must be on screen")
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name =
                "SIMULATED Z shared EV meter \(orientation == .portrait ? "portrait" : "landscape")"
            shot.lifetime = .keepAlways
            add(shot)
        }
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

    func testDisconnectedTeleprompterSavesTheScriptAndKeepsPlaybackExplicit() throws {
        // This fixture runs on the task simulator; reading another test process’s clipboard can prompt.
        defer { UIPasteboard.general.items = [] }
        let script =
            String(
                repeating:
                    "Welcome to our camera test.\n\nWe pause between paragraphs and keep the camera controls separate.\n\n",
                count: 6)
        UIPasteboard.general.string = script
        launch(
            ReviewLaunch(screen: .cameras),
            environment: [
                "ZC_DEMO_CAMERA_LIST": "1",
                "ZC_DEMO_TELEPROMPTER_SUITE": "teleprompter-ui-test." + UUID().uuidString,
            ])
        rotate(.landscapeLeft)
        let settings = app.buttons["cameras.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()
        let controls = app.buttons["monitor.settings.tab.Controls"]
        reveal(controls, in: app.scrollViews["monitor.settings.tabs"], portrait: false)
        controls.tap()
        openTeleprompterFromControls()
        let managerControls = app.descendants(matching: .any)["teleprompter.manager.controls"]
            .firstMatch
        XCTAssertTrue(managerControls.waitForExistence(timeout: 5))
        XCTAssertFalse(
            app.descendants(matching: .any)["teleprompter.manager.preview"].firstMatch.exists)
        XCTAssertFalse(app.buttons["teleprompter.read"].exists)
        capture("z-teleprompter-empty-settings-landscape")
        app.buttons["teleprompter.import.paste"].tap()
        XCTAssertTrue(
            app.descendants(matching: .any).matching(identifier: "teleprompter.import.preview")
                .firstMatch.waitForExistence(timeout: 5))
        capture("z-teleprompter-import-preview-landscape")
        app.buttons["teleprompter.import.use"].tap()
        rotate(.portrait)
        XCTAssertTrue(app.buttons["teleprompter.read"].isHittable)
        XCTAssertTrue(app.sliders["teleprompter.fontSize"].isHittable)
        XCTAssertTrue(app.sliders["teleprompter.speed"].isHittable)
        XCTAssertFalse(
            app.descendants(matching: .any)["teleprompter.manager.preview"].firstMatch.exists)
        capture("z-teleprompter-settings-portrait")
        rotate(.landscapeLeft)
        app.buttons["teleprompter.read"].tap()
        let play = app.buttons["teleprompter.play"]
        XCTAssertTrue(play.waitForExistence(timeout: 5))
        play.tap()
        XCTAssertEqual(play.label, "Pause")
        XCUIDevice.shared.press(.home)
        app.activate()
        rotate(.landscapeLeft)
        XCTAssertTrue(play.waitForExistence(timeout: 5))
        XCTAssertEqual(play.label, "Play")
        func scriptTop() throws -> CGFloat {
            try XCTUnwrap(
                app.staticTexts.matching(
                    NSPredicate(format: "label BEGINSWITH %@", "Welcome to our camera test.")
                )
                .allElementsBoundByIndex.first
            ).frame.minY
        }
        let pausedPosition = try scriptTop()
        let quickSettings = app.buttons["teleprompter.settings"]
        let reset = app.buttons["teleprompter.reset"]
        XCTAssertTrue(quickSettings.isHittable)
        XCTAssertGreaterThan(play.frame.midX, app.frame.midX)
        XCTAssertLessThan(play.frame.minX, reset.frame.minX)
        XCTAssertLessThan(reset.frame.minX, quickSettings.frame.minX)
        quickSettings.tap()
        XCTAssertTrue(app.sliders["teleprompter.fontSize"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.sliders["teleprompter.fontSize"].isHittable)
        XCTAssertTrue(app.sliders["teleprompter.speed"].isHittable)
        app.sliders["teleprompter.fontSize"].adjust(toNormalizedSliderPosition: 1)
        app.sliders["teleprompter.speed"].adjust(toNormalizedSliderPosition: 1)
        XCTAssertTrue(app.staticTexts["Speed 300"].exists)
        capture("z-teleprompter-direct-settings-landscape")
        app.buttons["teleprompter.read"].tap()
        let reader = app.descendants(matching: .any)["teleprompter.reader"].firstMatch
        XCTAssertEqual(reader.frame.width, app.frame.width, accuracy: 1)
        XCTAssertEqual(reader.frame.height, app.frame.height, accuracy: 1)
        XCTAssertEqual(try scriptTop(), pausedPosition, accuracy: 1.5)
        XCTAssertEqual(play.label, "Play")
        play.tap()
        XCTAssertEqual(play.label, "Pause")
        play.tap()
        XCTAssertEqual(play.label, "Play")
        app.buttons["teleprompter.reset"].tap()
        capture("z-teleprompter-reading-landscape")
        quickSettings.tap()
        app.buttons["teleprompter.close"].tap()
        openTeleprompterFromControls()
        app.buttons["teleprompter.edit"].tap()
        let editor = app.textViews["teleprompter.script.editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertEqual(
            editor.value as? String, script)
        editor.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Done"].isHittable)
        XCTAssertTrue(editor.isHittable)
        XCTAssertGreaterThanOrEqual(editor.frame.height, 44)
        XCTAssertLessThanOrEqual(editor.frame.maxY, app.keyboards.firstMatch.frame.minY + 1)
        capture("z-teleprompter-editing-keyboard-landscape")
    }

    func testImportedTeleprompterReturnsToLiveAndLeavesCameraControlsReachable() {
        // This fixture runs on the task simulator; reading another test process’s clipboard can prompt.
        defer { UIPasteboard.general.items = [] }
        UIPasteboard.general.string =
            String(
                repeating:
                    "Read this script over the live picture.\n\nThe camera controls stay reachable.\n\n",
                count: 6)
        launch(ReviewLaunch(screen: .live))
        rotate(.landscapeLeft)
        let record = app.buttons["monitor.system.record"]
        XCTAssertTrue(record.waitForExistence(timeout: 10))
        app.buttons["monitor.system.settings"].tap()
        let controls = app.buttons["monitor.settings.tab.Controls"]
        reveal(controls, in: app.scrollViews["monitor.settings.tabs"], portrait: false)
        controls.tap()
        openTeleprompterFromControls()
        app.buttons["teleprompter.import.paste"].tap()
        XCTAssertTrue(app.buttons["teleprompter.import.use"].waitForExistence(timeout: 5))
        app.buttons["teleprompter.import.use"].tap()
        let overlay = app.descendants(matching: .any)["teleprompter.overlay"].firstMatch
        XCTAssertTrue(overlay.waitForExistence(timeout: 10))
        XCTAssertTrue(record.isHittable)
        let quickSettings = app.buttons["teleprompter.settings"]
        XCTAssertTrue(quickSettings.isHittable)
        let prompt = app.buttons["monitor.assist.PROMPT"]
        XCTAssertTrue(prompt.isHittable)
        capture("z-teleprompter-live-overlay-landscape")
        let recordingLabel = record.label
        for orientation in [UIDeviceOrientation.portrait, .landscapeRight, .landscapeLeft] {
            rotate(orientation, settling: overlay)
            let frame = overlay.frame
            XCTAssertTrue(app.frame.insetBy(dx: -1, dy: -1).contains(frame))
            if orientation == .portrait {
                XCTAssertGreaterThan(frame.height, app.frame.width * 9 / 16 * 1.5)
            } else {
                XCTAssertGreaterThan(frame.height, app.frame.height * 0.4)
            }
            XCTAssertGreaterThan(
                frame.width, app.frame.width * (orientation == .portrait ? 0.75 : 0.6))
            for id in [
                "monitor.system.record", "monitor.system.settings", "monitor.system.media",
                "monitor.system.lock", "monitor.capture.iso", "monitor.capture.shutter",
                "monitor.assist.PROMPT",
            ] {
                let control = app.buttons[id]
                if control.exists {
                    XCTAssertTrue(control.isHittable, "Reader leaves \(id) reachable")
                    XCTAssertFalse(frame.intersects(control.frame), "Reader clears \(id)")
                }
            }
            XCTAssertTrue(app.buttons["teleprompter.play"].isHittable)
            XCTAssertTrue(app.buttons["teleprompter.reset"].isHittable)
            XCTAssertTrue(app.buttons["teleprompter.settings"].isHittable)
            XCTAssertEqual(record.label, recordingLabel)
            capture("z-teleprompter-expanded-\(orientation.rawValue)")
            if orientation == .portrait {
                app.buttons["monitor.capture.iso"].tap()
                let close = app.buttons["monitor.capture.close"]
                XCTAssertTrue(close.waitForExistence(timeout: 5))
                close.tap()
                XCTAssertTrue(overlay.waitForExistence(timeout: 5))
            }
        }

        let lock = app.buttons["monitor.system.lock"]
        let play = app.buttons["teleprompter.play"]
        let reset = app.buttons["teleprompter.reset"]
        XCTAssertTrue(lock.isHittable && play.exists && reset.exists)
        lock.tap()
        XCTAssertFalse(play.isEnabled)
        XCTAssertFalse(reset.isEnabled)
        XCTAssertFalse(quickSettings.isEnabled)
        lock.tap()
        XCTAssertTrue(play.isEnabled && reset.isEnabled && quickSettings.isEnabled)
        prompt.tap()
        XCTAssertFalse(overlay.exists)
        XCTAssertTrue(record.isHittable)
        prompt.tap()
        XCTAssertTrue(overlay.waitForExistence(timeout: 5))
        app.buttons["monitor.assists.expand"].tap()
        let chips = app.buttons.matching(
            NSPredicate(format: "identifier MATCHES %@", "monitor\\.assist\\.[A-Z0-9_]+"))
        let firstChip = chips.allElementsBoundByIndex.first { $0.isHittable }
        XCTAssertNotNil(firstChip)
        if let firstChip {
            let paletteScroll = app.scrollViews.containing(
                .button, identifier: firstChip.identifier
            ).firstMatch
            XCTAssertTrue(paletteScroll.exists)
            for _ in 0..<8 where !prompt.isHittable { paletteScroll.swipeLeft() }
            XCTAssertTrue(prompt.isHittable)
            for chip in chips.allElementsBoundByIndex
            where chip.isHittable && chip.identifier != prompt.identifier {
                XCTAssertTrue(chip.frame.minX < prompt.frame.minX + 1)
                if abs(chip.frame.minX - prompt.frame.minX) < 1 {
                    XCTAssertLessThan(chip.frame.minY, prompt.frame.minY)
                }
            }
        }
        capture("z-teleprompter-last-expanded-tool-landscape")
        app.buttons["monitor.assists.collapse"].tap()
        let restored = NSPredicate { _, _ in prompt.isHittable }
        XCTAssertEqual(
            XCTWaiter.wait(
                for: [XCTNSPredicateExpectation(predicate: restored, object: nil)], timeout: 5),
            .completed)
        capture("z-teleprompter-reserved-collapsed-tool-landscape")
        quickSettings.tap()
        let opacity = app.sliders["teleprompter.opacity"]
        XCTAssertTrue(opacity.waitForExistence(timeout: 5))
        let options = app.scrollViews.containing(
            .button, identifier: "teleprompter.manage"
        ).firstMatch
        for _ in 0..<6 where !options.frame.contains(opacity.frame) { options.swipeUp() }
        XCTAssertTrue(opacity.isHittable && options.frame.contains(opacity.frame))
        let wasOpaque = app.staticTexts["Background 100%"].exists
        opacity.adjust(toNormalizedSliderPosition: wasOpaque ? 0 : 1)
        XCTAssertTrue(app.staticTexts[wasOpaque ? "Background 0%" : "Background 100%"].exists)
        capture("z-teleprompter-quick-controls-landscape")
    }

    func testTeleprompterExtremeSettingsAndCancelledImportsInLandscape() {
        defer { UIPasteboard.general.items = [] }
        let script = String(
            repeating:
                "Keep the live picture visible.\n\nRead comfortably between camera checks.\n\n",
            count: 6)
        UIPasteboard.general.string = script
        launch(ReviewLaunch(screen: .live))
        rotate(.landscapeLeft)
        let record = app.buttons["monitor.system.record"]
        XCTAssertTrue(record.waitForExistence(timeout: 10))
        app.buttons["monitor.system.settings"].tap()
        let controls = app.buttons["monitor.settings.tab.Controls"]
        reveal(controls, in: app.scrollViews["monitor.settings.tabs"], portrait: false)
        controls.tap()
        openTeleprompterFromControls()
        app.buttons["teleprompter.import.paste"].tap()
        XCTAssertTrue(app.buttons["teleprompter.import.use"].waitForExistence(timeout: 5))
        app.buttons["teleprompter.import.use"].tap()
        let overlay = app.descendants(matching: .any)["teleprompter.overlay"].firstMatch
        let prompt = app.buttons["monitor.assist.PROMPT"]
        XCTAssertTrue(overlay.waitForExistence(timeout: 10))

        func revealOption(_ option: XCUIElement, in scroll: XCUIElement) {
            for _ in 0..<6 where !option.isHittable {
                if option.frame.midY < scroll.frame.minY {
                    scroll.swipeDown()
                } else {
                    scroll.swipeUp()
                }
            }
            XCTAssertTrue(option.isHittable)
        }

        for value in [CGFloat(0), CGFloat(1)] {
            prompt.press(forDuration: 0.6)
            let options = app.scrollViews.containing(
                .button, identifier: "teleprompter.manage"
            ).firstMatch
            XCTAssertTrue(options.waitForExistence(timeout: 5))
            let font = app.sliders["Text size"]
            revealOption(font, in: options)
            font.adjust(toNormalizedSliderPosition: 1)
            XCTAssertTrue(app.staticTexts["Text 72"].exists)
            let opacity = app.sliders["teleprompter.opacity"]
            revealOption(opacity, in: options)
            opacity.adjust(toNormalizedSliderPosition: value)
            let percent = Int(value * 100)
            XCTAssertTrue(app.staticTexts["Background \(percent)%"].exists)
            app.buttons["monitor.assist.close"].tap()
            XCTAssertTrue(overlay.waitForExistence(timeout: 5))
            XCTAssertTrue(record.isHittable)
            let window = app.frame.insetBy(dx: -0.5, dy: -0.5)
            XCTAssertTrue(window.contains(overlay.frame))
            for identifier in ["teleprompter.play", "teleprompter.reset"] {
                let button = app.buttons[identifier]
                XCTAssertTrue(button.isHittable && window.contains(button.frame))
            }
            capture("z-teleprompter-72pt-opacity-\(percent)-landscape")
        }
        prompt.press(forDuration: 0.6)
        let options = app.scrollViews.containing(
            .button, identifier: "teleprompter.manage"
        ).firstMatch
        let manage = app.buttons["teleprompter.manage"]
        revealOption(manage, in: options)
        manage.tap()
        XCTAssertTrue(app.buttons["teleprompter.close"].waitForExistence(timeout: 5))
        app.buttons["teleprompter.import.link"].tap()
        let url = app.textFields["teleprompter.import.url"]
        XCTAssertTrue(url.waitForExistence(timeout: 5))
        url.tap()
        url.typeText("https://example.com/script.txt")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        capture("z-teleprompter-link-keyboard-landscape")
        app.buttons["Cancel"].firstMatch.tap()
        XCTAssertTrue(url.waitForNonExistence(timeout: 5))
        app.buttons["teleprompter.import.file"].tap()
        let cancel = app.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 10))
        capture("z-teleprompter-native-file-picker-landscape")
        cancel.tap()
        let edit = app.buttons["teleprompter.edit"]
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        edit.tap()
        let editor = app.textViews["teleprompter.script.editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertEqual(
            editor.value as? String, script)
    }

    func testTeleprompterImportsDirectMarkdownAndRefreshRequiresAcceptance() throws {
        guard let source = ProcessInfo.processInfo.environment["TELEPROMPTER_SMOKE_URL"] else {
            throw XCTSkip(
                "Supply a public direct Markdown URL for the optional network smoke check.")
        }
        launch(ReviewLaunch(screen: .cameras), environment: ["ZC_DEMO_CAMERA_LIST": "1"])
        rotate(.landscapeLeft)
        let settings = app.buttons["cameras.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()
        let controls = app.buttons["monitor.settings.tab.Controls"]
        reveal(controls, in: app.scrollViews["monitor.settings.tabs"], portrait: false)
        controls.tap()
        openTeleprompterFromControls()
        app.buttons["teleprompter.import.link"].tap()
        let url = app.textFields["teleprompter.import.url"]
        XCTAssertTrue(url.waitForExistence(timeout: 5))
        url.tap()
        url.typeText(source)
        let load = app.buttons["teleprompter.import.load"]
        if !load.isHittable { app.swipeUp() }
        XCTAssertTrue(load.isHittable)
        load.tap()
        let use = app.buttons["teleprompter.import.use"]
        XCTAssertTrue(use.waitForExistence(timeout: 30))
        capture("z-teleprompter-remote-markdown-preview-landscape")
        use.tap()
        let refresh = app.buttons["teleprompter.import.refresh"]
        XCTAssertTrue(refresh.waitForExistence(timeout: 5))
        refresh.tap()
        XCTAssertTrue(use.waitForExistence(timeout: 30))
        app.buttons["Cancel"].firstMatch.tap()
        XCTAssertTrue(refresh.waitForExistence(timeout: 5))
        app.buttons["teleprompter.read"].tap()
        XCTAssertTrue(app.buttons["teleprompter.play"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["teleprompter.play"].label, "Play")
    }

    private func openTeleprompterFromControls() {
        let open = app.buttons["settings.controls.teleprompter"]
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        for _ in 0..<6 where !open.isHittable { app.swipeUp() }
        XCTAssertTrue(open.isHittable)
        open.tap()
        XCTAssertTrue(app.buttons["teleprompter.close"].waitForExistence(timeout: 5))
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
                    XCTAssertTrue(
                        app.staticTexts["HDR display"].firstMatch.waitForExistence(timeout: 5))
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
        XCTAssertTrue(
            side.waitForExistence(timeout: 10), "The side column is one labelled container")
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
        let scroller = app.scrollViews.containing(.any, identifier: "monitor.command.tile.iso")
            .firstMatch
        XCTAssertTrue(scroller.waitForExistence(timeout: 10))
        XCTAssertGreaterThanOrEqual(
            scroller.frame.height, 246,
            "The portrait viewport must show the three 76-point primary rows and their two 9-point gaps"
        )
        XCTAssertFalse(
            app.buttons["monitor.system.focusReset"].exists,
            "Picture-only recenter controls must not cover the command dashboard")
        for identifier in try order() {
            let tile = tiles.matching(identifier: identifier).firstMatch
            XCTAssertTrue(
                contained(tile, in: scroller),
                "The whole primary tile \(identifier) \(tile.frame) must fit inside \(scroller.frame)"
            )
        }
        scroller.swipeUp()
        let last = app.buttons["Grid"]
        XCTAssertTrue(
            contained(last, in: scroller), "Scrolling reaches the complete final read-only cell")
        capture("z-command-dashboard-portrait-scrolled-end")
    }

    @MainActor
    func testLandscapeSideColumnShowsItsOverflowCueUntilTheEnd() {
        continueAfterFailure = false
        open()
        let side = app.descendants(matching: .any)["monitor.command.side"]
        let more = app.descendants(matching: .any)["monitor.command.more"]
        XCTAssertTrue(
            more.waitForExistence(timeout: 10),
            "The overflowing side column must show its scroll cue")
        XCTAssertEqual(more.label, "More command controls below. Swipe up to reveal them.")
        side.swipeUp()
        XCTAssertTrue(
            contained(app.buttons["Grid"], in: side), "Scrolling reaches the final read-only cell")
        XCTAssertTrue(
            more.waitForNonExistence(timeout: 10), "The cue clears at the actual content bottom")
        capture("z-command-dashboard-landscape-scrolled-end")
    }

    @MainActor private func contained(_ element: XCUIElement, in viewport: XCUIElement) -> Bool {
        let visible = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
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
        XCTAssertTrue(
            tiles.firstMatch.waitForExistence(timeout: 30), "DISP 3 shows the command grid")
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
            if element.identifier.hasPrefix("monitor.command.tile."),
                found[element.identifier] == nil
            {
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
        let arranged = XCTNSPredicateExpectation(
            predicate: NSPredicate { [self] _, _ in
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
            XCTAssertTrue(
                waitUntilHittable(tile), "The mounted dashboard must clear the launch splash")
            capture("z-command-dashboard-\(orientation == .portrait ? "portrait" : "landscape")")
        }
    }
}

/// SIMULATED callback receipts from actual shared row views, driven only by public XCUI input.
/// These prove the app projection and row callbacks, not camera transport or hardware acceptance.
@MainActor
final class GroupedStabilizationInputUITests: XCTestCase {
    private var app: XCUIApplication!

    private func finish() {
        app?.terminate()
        XCUIDevice.shared.orientation = .portrait
    }

    func testVisibleSelectionsSendExactlyTheirIndependentRequests() {
        defer { finish() }
        launch("normal")
        tap("open")
        expect("requests", "none")
        tapRow("movieVR", 2)
        expect("requests", "vr:SPORT")
        tapRow("electronicVR", 1)
        expect("requests", "vr:SPORT|evr:ON")
        tap("close")
        expect("requests", "vr:SPORT|evr:ON")
        tap("open")
        expect("requests", "vr:SPORT|evr:ON")
        capture("independent-requests")
    }

    func testRAWLockAndRetiredSourceRefuseActualTouches() {
        defer { finish() }
        launch("raw")
        tap("open")
        tapRow("electronicVR", 1)
        expect("requests", "none")
        expect("refusals", "1")
        expect("reason", "e-VR is unavailable in RAW codecs")
        tap("lock")
        let locked = row("movieVR", 2)
        XCTAssertTrue(locked.exists)
        XCTAssertFalse(locked.isEnabled)
        XCTAssertTrue(app.frame.contains(locked.frame))
        XCTAssertGreaterThanOrEqual(locked.frame.height, 44)
        // Public coordinate input still reaches the visible disabled region; no handler shortcut.
        locked.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        expect("requests", "none")
        tap("lock")
        tap("retireSource")
        expect("source", "retired")
        tapRow("movieVR", 2)
        expect("requests", "none")
        expect("refusals", "1")
        capture("refused-touches")
    }

    func testUnknownEmptyAndUnlistedReadbacksNeverInferSelection() {
        defer { finish() }
        launch("unknown")
        tap("open")
        expect("observations", "nil|nil")
        XCTAssertFalse(row("electronicVR", 0).isSelected)
        XCTAssertFalse(row("electronicVR", 1).isSelected)
        tap("observeOutside")
        let observed = app.staticTexts["monitor.independentSettings.movieVR.current"]
        XCTAssertTrue(observed.waitForExistence(timeout: 5))
        XCTAssertEqual(observed.label, "ON")
        expect("requests", "none")
        tapRow("electronicVR", 1)
        expect("requests", "evr:ON")
        expect("observations", "ON|nil")
        tap("offerMovie")
        XCTAssertEqual(observed.label, "unlisted observation")
        XCTAssertFalse(row("movieVR", 0).isSelected)
        XCTAssertFalse(row("movieVR", 1).isSelected)
        XCTAssertFalse(row("movieVR", 2).isSelected)
        tapRow("movieVR", 2)
        expect("requests", "evr:ON|vr:SPORT")
        expect("observations", "unlisted observation|nil")
        capture("unknown-and-unlisted")
    }

    private func launch(_ mode: String) {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        app = XCUIApplication()
        app.launchEnvironment["ZC_DEMO_STABILIZATION_PANEL"] = mode
        app.launch()
        XCTAssertTrue(app.staticTexts["simulated.stabilization.label"].waitForExistence(timeout: 5))
    }

    private func tap(_ identifier: String) {
        let button = app.buttons["simulated.stabilization." + identifier]
        XCTAssertTrue(
            waitUntilHittable(button, timeout: 5), "Visible public control: \(identifier)")
        button.tap()
    }

    private func row(_ identifier: String, _ index: Int) -> XCUIElement {
        app.buttons["monitor.independentSettings.\(identifier).option.\(index)"]
    }

    private func tapRow(_ identifier: String, _ index: Int) {
        let button = row(identifier, index)
        XCTAssertTrue(waitUntilHittable(button, timeout: 5))
        button.tap()
    }

    private func expect(_ identifier: String, _ value: String) {
        let receipt = app.staticTexts["simulated.stabilization." + identifier]
        let matches = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", value), object: receipt)
        XCTAssertEqual(XCTWaiter.wait(for: [matches], timeout: 3), .completed)
    }

    private func capture(_ label: String) {
        let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        image.name = "SIMULATED-grouped-\(label)-landscape-public-input"
        image.lifetime = .keepAlways
        add(image)
        let receipt = XCTAttachment(
            string:
                "SIMULATED row callback scope; requests=\(app.staticTexts["simulated.stabilization.requests"].value ?? "unread"); refusals=\(app.staticTexts["simulated.stabilization.refusals"].value ?? "unread")"
        )
        receipt.name = "SIMULATED grouped row callback receipt"
        receipt.lifetime = .keepAlways
        add(receipt)
    }
}

/// SIMULATED owner hardware pass 2026-10-28: a photography value slides straight into a new
/// value in one motion (press, drag, lift), as every readout does in the other apps.
final class NikonPhotoQuickDragUITests: SharedAppUITestCase {
    @MainActor
    func testSIMULATEDPhotoValuesPressAndDragInOneMotion() throws {
        #if !targetEnvironment(simulator)
            throw XCTSkip("SIMULATED quick staging requires a private simulator")
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
        for orientation in [UIDeviceOrientation.landscapeLeft, .portrait] {
            for identifier in ["monitor.capture.stillISO", "monitor.capture.stillShutter"] {
                let readout = app.buttons[identifier]
                XCTAssertTrue(readout.waitForExistence(timeout: 20), identifier)
                rotate(orientation, settling: readout)
                let before = try XCTUnwrap(readout.value as? String)
                let start = readout.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                start.press(
                    forDuration: 0.02, thenDragTo: start.withOffset(CGVector(dx: -120, dy: 0)))
                let changed = XCTNSPredicateExpectation(
                    predicate: NSPredicate(format: "value != %@", before), object: readout)
                XCTAssertEqual(
                    XCTWaiter.wait(for: [changed], timeout: 5), .completed,
                    "\(identifier) must take the dragged value without a second touch")
                XCTAssertFalse(
                    app.buttons["monitor.capture.close"].exists,
                    "A press-drag never leaves the drawer open")
                capture("SIMULATED-photo-quick-drag-\(identifier)-\(orientation.rawValue)")
            }
        }
    }
}

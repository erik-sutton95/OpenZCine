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
    override var expectedStorageText: String { "521 GB" }
    override var expectedPortraitStorageText: String { "521GB" }
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
        // A hosted runner spends most of the normal 2.25 s splash inside the launch itself, so
        // the splash could leave before one bracketed sample. Holding it keeps the proof the same.
        app.launchEnvironment["ZC_DEMO_SPLASH_HOLD_MS"] = "10000"
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

// The receipt value types below mirror the app-side definitions in RunnerTests
// (`GyroCaptureTests.swift`): the accepted cross-process contract keeps one shape on both
// sides, carried by the `NativeUIReceiptBridge` container convention.

/// Screen-space point as the app observed it; the reader taps exactly this point.
struct GyroReachPoint: Codable, Equatable {
    let x: Double
    let y: Double
    let nativeX: Double
    let nativeY: Double

    var nativePoint: CGPoint { CGPoint(x: nativeX, y: nativeY) }
    var point: CGPoint { CGPoint(x: x, y: y) }
    var finite: Bool { [x, y, nativeX, nativeY].allSatisfy(\.isFinite) }
}

/// Screen-space rectangle; the reader compares its device-coordinate edges at screen scale.
struct GyroReachRect: Codable, Equatable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    init(_ rect: CGRect) {
        x = min(rect.origin.x, rect.origin.x + rect.size.width)
        y = min(rect.origin.y, rect.origin.y + rect.size.height)
        width = rect.size.width
        height = rect.size.height
    }

    var rect: CGRect {
        CGRect(origin: CGPoint(x: x, y: y), size: CGSize(width: width, height: height))
    }

    func contains(_ point: GyroReachPoint, margin: Double = 0) -> Bool {
        point.x >= x - margin && point.x < x + width + margin
            && point.y >= y - margin && point.y < y + height + margin
    }

    var finite: Bool { [x, y, width, height].allSatisfy(\.isFinite) && width > 0 && height > 0 }
}

/// One gyro control as the reader must see it: identity, painted and expanded frames, and
/// a reach point 2pt inside the expanded lower edge.
struct GyroReachControl: Codable, Equatable {
    let identifier: String?
    let label: String?
    let button: Bool
    let axFrame: GyroReachRect
    let textFrame: GyroReachRect?
    let expandedFrame: GyroReachRect
    let reachPoint: GyroReachPoint
}

/// The owner observation snapshot the reader waits on.
struct GyroReachOutcome: Codable, Equatable {
    let calibrationPoseCount: Int
    let calibrationInProgress: Bool
    let mountCalibrationSaved: Bool
    let logsPresented: Bool
    let logsCount: Int
    let presentedClass: String?
}

/// The app-published reach receipt, bridged from the host app's container.
struct GyroReachReceipt: Codable {
    let schema: Int
    let nonce: String
    let sourceSeal: String
    let bundleID: String
    let simulatorID: String
    let processID: Int32
    let sequence: UInt64
    let observedAt: Double
    let mode: String
    let foreground: Bool
    let keyWindow: Bool
    let rootMounted: Bool
    let rootFillsScene: Bool
    let sceneID: String
    let windowIdentity: String
    let windowFrame: GyroReachRect
    let screenFrame: GyroReachRect
    let screenScale: Double
    let orientation: Int
    let controls: [GyroReachControl]
    let outsidePoint: GyroReachPoint?
    let neighborPoint: GyroReachPoint?
    let outcome: GyroReachOutcome
    let ownerObservations: [String]
}

/// Attach-only native input for the gyro 44pt reach proof.
///
/// Input only: attaches to the unit-test host (the real Runner app) mounting the gyro
/// fixture in its actual scene; never launches, activates or drives the product UI. Every
/// tap is a public `XCUICoordinate.tap()` at a point the app published in its receipt, and
/// the outcome is the app's own coordinator state, bridged back as receipt revisions.
/// Outside the focused native input envelope the whole case skips.
@MainActor
final class GyroNativeInputUITests: XCTestCase {
    private var nonce = ""
    private var sourceSeal = ""
    private var bundleID = ""
    private var simulatorID = ""
    private var receiptURL: URL!
    private var finalSequence: UInt64 = 0

    func testSupplyNativeInputToTheGyroReachProof() async throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        guard env["OPENCINE_NATIVE_UI_MODE"] != nil else {
            throw XCTSkip("The gyro reach reader needs the native input bridge envelope.")
        }
        guard env["OPENCINE_NATIVE_UI_MODE"] == "gyro-hosted-native-input",
            let nonce = env["OPENCINE_NATIVE_UI_NONCE"], UUID(uuidString: nonce) != nil,
            let sourceSeal = env["OPENCINE_NATIVE_UI_SOURCE_SEAL"], sourceSeal.count == 64,
            let bundleID = env["OPENCINE_NATIVE_UI_BUNDLE_ID"],
            let simulatorID = env["SIMULATOR_UDID"], UUID(uuidString: simulatorID) != nil
        else {
            XCTFail("The native input envelope is incomplete.")
            return
        }
        self.nonce = nonce
        self.sourceSeal = sourceSeal
        self.bundleID = bundleID
        self.simulatorID = simulatorID
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SIMULATED-native-reader-" + nonce, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        receiptURL = directory.appendingPathComponent("app-receipt.json")
        FileHandle.standardOutput.write(
            Data("SIMULATED_NATIVE_UI_INBOX:\(receiptURL.path)\n".utf8))
        // Input only: attaches to the hosted bundle; never launch or activate.
        let app = XCUIApplication(bundleIdentifier: bundleID)
        var notes: [String] = []
        var tapInvoked = 0
        defer { recordOutcome(tapInvoked: tapInvoked, notes: notes) }

        let initial = try await receipt(deadline: .seconds(90)) {
            $0.mode == "gyro-restart-ready" && $0.outcome.calibrationPoseCount == 2
        }
        try verifyIdentity(initial, app: app)
        try verifyGeometry(initial)
        notes.append("identity and geometry verified for \(initial.controls.count) controls")

        // Outside negative: outside every expanded control region nothing may react. The
        // app-side test asserts the same unchanged outcome independently.
        let outside = try XCTUnwrap(initial.outsidePoint)
        try tap(outside, app: app)
        tapInvoked += 1
        try await requireUnchanged(since: initial, window: .seconds(3), what: "outside negative")

        // Reach: restart. Restarting resets the pose sequence to zero.
        try await reach(
            "gyro.calibration.restart", from: initial, app: app,
            until: { $0.mode == "gyro-cancel-ready" && $0.outcome.calibrationPoseCount == 0 })
        tapInvoked += 1
        notes.append("restart: poses 0")

        // Reach: cancel. Ending the calibration is the cancel control's outcome.
        try await reach(
            "gyro.calibration.cancel", app: app,
            until: {
                $0.mode == "gyro-capture-ready" && $0.outcome.calibrationInProgress
                    && $0.ownerObservations.contains("cancel: in progress false")
            })
        tapInvoked += 1
        notes.append("cancel: in progress false")

        // Reach: capture. A fresh first pose must be capturable through the 44pt region.
        try await reach(
            "gyro.calibration.capture", app: app,
            until: {
                // The fixture verifies pose 1 before cancelling calibration to prepare logs.
                // Keep that original owner observation instead of asserting on the reset state.
                $0.mode == "gyro-logs-ready"
                    && $0.ownerObservations.contains("capture: poses 1, in progress true")
            })
        tapInvoked += 1
        notes.append("capture: poses 1")

        // Neighbor negative: in the passive area above the Share/Delete gap, outside both
        // action bands, nothing may react.
        let logsReceipt = try await receipt(deadline: .seconds(30)) {
            $0.mode == "gyro-logs-ready"
        }
        try verifyGeometry(logsReceipt)
        let neighbor = try XCTUnwrap(logsReceipt.neighborPoint)
        try tap(neighbor, app: app)
        tapInvoked += 1
        try await requireUnchanged(
            since: logsReceipt, window: .seconds(3), what: "neighbor negative")

        // Reach: the status pill. `openLogs` is the coordinator's own observation.
        try await reach(
            "monitor.gyroStatus", app: app,
            until: { $0.mode == "gyro-share-ready" && $0.outcome.logsPresented })
        tapInvoked += 1
        notes.append("status: logs presented")

        let shareReceipt = try await receipt(deadline: .seconds(30)) {
            $0.mode == "gyro-share-ready"
        }
        try tapReach(
            try control(labelled: "Share", in: shareReceipt), app: app, receipt: shareReceipt)
        tapInvoked += 1
        _ = try await receipt(deadline: .seconds(30)) { $0.outcome.presentedClass != nil }
        notes.append("share: system sheet presented")
        let closeShare = app.buttons["Close"].firstMatch
        XCTAssertTrue(closeShare.waitForExistence(timeout: 15), "The real Share sheet must close")
        closeShare.tap()
        tapInvoked += 1

        // Reach: delete. The confirmation dialog exists beforehand and is gone after the
        // destructive confirm; the coordinator's own delete empties the logs.
        let deleteReceipt = try await receipt(deadline: .seconds(30)) {
            $0.mode == "gyro-delete-ready"
        }
        let deleteControl = try control(labelled: "Delete", in: deleteReceipt)
        try tapReach(deleteControl, app: app, receipt: deleteReceipt)
        tapInvoked += 1
        var dialogButton = app.sheets.buttons["Delete"].firstMatch
        if !dialogButton.waitForExistence(timeout: 15) {
            dialogButton = app.alerts.buttons["Delete"].firstMatch
            XCTAssertTrue(
                dialogButton.waitForExistence(timeout: 15),
                "The confirmation dialog must exist")
        }
        notes.append("delete: confirmation dialog present")
        dialogButton.tap()
        tapInvoked += 1
        let settled = try await receipt(deadline: .seconds(30)) {
            $0.mode == "gyro-settled" && $0.outcome.logsCount == 0
        }
        XCTAssertEqual(app.sheets.count, 0, "The confirmation dialog must be gone")
        XCTAssertEqual(settled.outcome.logsCount, 0, "The confirmed delete must empty the logs")
        notes.append("delete: logs emptied after confirm")
    }

    // MARK: reader mechanics (accepted attach-only patterns)

    private func require(_ condition: Bool, _ reason: String) throws {
        if !condition {
            throw NSError(
                domain: "GyroReachReader", code: 2,
                userInfo: [NSLocalizedDescriptionKey: reason])
        }
    }

    /// The accepted device-edge comparator at screen scale: floating-safe frame equality.
    private func deviceEdges(_ frame: GyroReachRect, scale: Double) -> [Double] {
        [
            frame.x * scale, frame.y * scale,
            (frame.x + frame.width) * scale, (frame.y + frame.height) * scale,
        ]
    }

    private func verifyIdentity(_ receipt: GyroReachReceipt, app: XCUIApplication) throws {
        try require(receipt.schema == 1, "Unexpected receipt schema")
        try require(receipt.nonce == nonce, "Receipt nonce mismatch")
        try require(receipt.sourceSeal == sourceSeal, "Receipt source seal mismatch")
        try require(receipt.bundleID == bundleID, "Receipt bundle mismatch")
        try require(
            UUID(uuidString: receipt.simulatorID) == UUID(uuidString: simulatorID),
            "Receipt simulator mismatch")
        try require(receipt.processID > 0, "Receipt process id must be positive")
        try require(receipt.foreground, "The host app must be foreground active")
        try require(receipt.keyWindow, "The fixture window must be key")
        try require(receipt.rootMounted && receipt.rootFillsScene, "The fixture root must fill")
        try require(app.state == .runningForeground, "The host app must be running foreground")
        let appFrame = GyroReachRect(app.frame)
        try require(
            receipt.screenScale > 0 && receipt.windowFrame.finite && appFrame.finite
                && deviceEdges(appFrame, scale: receipt.screenScale)
                    == deviceEdges(receipt.windowFrame, scale: receipt.screenScale),
            "The app frame must match the receipt window at device edges")
    }

    /// Every control's expanded region meets the 44pt floor, and its reach point lies
    /// inside that region and outside every sibling's.
    private func verifyGeometry(_ receipt: GyroReachReceipt) throws {
        for control in receipt.controls {
            try require(
                control.expandedFrame.finite, "The expanded frame must be finite")
            try require(
                control.expandedFrame.width >= 44 && control.expandedFrame.height >= 44,
                "The expanded region must meet the 44pt floor")
            try require(
                control.expandedFrame.contains(control.reachPoint),
                "The reach point must lie inside the expanded region")
            for sibling in receipt.controls where sibling != control {
                try require(
                    !sibling.expandedFrame.contains(control.reachPoint, margin: 1),
                    "The reach point must not sit inside a sibling's region")
            }
        }
    }

    private func control(identifier: String, in receipt: GyroReachReceipt) throws
        -> GyroReachControl
    {
        try XCTUnwrap(
            receipt.controls.first { $0.identifier == identifier },
            "Missing \(identifier) in the receipt")
    }

    private func control(labelled label: String, in receipt: GyroReachReceipt) throws
        -> GyroReachControl
    {
        try XCTUnwrap(
            receipt.controls.first { $0.label == label && $0.button },
            "Missing the \(label) control in the receipt")
    }

    /// Builds the accepted coordinate from the app anchor and requires the dynamic
    /// screenPoint to equal the app-observed point exactly before tapping.
    private func tap(_ point: GyroReachPoint, app: XCUIApplication) throws {
        try require(point.finite, "The tapped point must be finite")
        let coordinate = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0)).withOffset(
            CGVector(dx: point.x - app.frame.minX, dy: point.y - app.frame.minY))
        let actual = coordinate.screenPoint
        print(
            "GYRO_NATIVE_POINT: expected=\(point.nativePoint) scene=\(point.point) actual=\(actual) app=\(app.frame)"
        )
        try require(
            actual == point.nativePoint,
            "The reader coordinate \(actual) must equal the app-observed point \(point.nativePoint) exactly"
        )
        coordinate.tap()
    }

    /// Asserts a control's reach geometry before tapping its reach point.
    private func tapReach(
        _ control: GyroReachControl, app: XCUIApplication, receipt: GyroReachReceipt
    ) throws {
        try require(control.button, "A same-label StaticText must never replace the Button")
        try require(
            !(control.textFrame ?? control.axFrame).contains(control.reachPoint),
            "The reach tap must be outside the observed compact paint frame")
        try require(
            control.expandedFrame.width >= 44 && control.expandedFrame.height >= 44,
            "The control must declare a 44pt region")
        try require(
            control.expandedFrame.contains(control.reachPoint),
            "The reach point must lie inside the expanded region")
        for sibling in receipt.controls where sibling != control {
            try require(
                !sibling.expandedFrame.contains(control.reachPoint, margin: 1),
                "The reach point must not sit inside a sibling's region")
        }
        try tap(control.reachPoint, app: app)
    }

    /// Taps the named control's reach point and waits for the next phase condition.
    private func reach(
        _ identifier: String, from current: GyroReachReceipt? = nil, app: XCUIApplication,
        until condition: @escaping (GyroReachReceipt) -> Bool
    ) async throws {
        let source: GyroReachReceipt
        if let current {
            source = current
        } else {
            source = try await receipt(deadline: .seconds(30)) { _ in true }
        }
        let control = try control(identifier: identifier, in: source)
        try tapReach(control, app: app, receipt: source)
        _ = try await receipt(deadline: .seconds(30), condition)
    }

    /// The latest bridged receipt, identity-verified and fresh.
    private func receipt(
        deadline: Duration, _ condition: ((GyroReachReceipt) -> Bool)? = nil
    ) async throws -> GyroReachReceipt {
        let clock = ContinuousClock()
        let limit = clock.now.advanced(by: deadline)
        while clock.now < limit {
            if let data = FileManager.default.contents(atPath: receiptURL.path),
                let value = try? JSONDecoder().decode(GyroReachReceipt.self, from: data),
                value.schema == 1, value.nonce == nonce, value.sourceSeal == sourceSeal,
                value.bundleID == bundleID,
                UUID(uuidString: value.simulatorID) == UUID(uuidString: simulatorID),
                value.processID > 0,
                value.foreground, value.keyWindow, value.rootMounted, value.rootFillsScene,
                Date().timeIntervalSince1970 - value.observedAt <= 10,
                condition?(value) ?? true
            {
                finalSequence = value.sequence
                return value
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw NSError(
            domain: "GyroReachReader", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for a receipt"])
    }

    /// Every negative receipt advances sequence and time after input, with a final fresh
    /// observation after the full window; stale bridge snapshots cannot prove no change.
    private func requireUnchanged(
        since baseline: GyroReachReceipt, window: Duration, what: String
    ) async throws {
        let clock = ContinuousClock()
        let limit = clock.now.advanced(by: window)
        var previous = baseline
        while true {
            let completesWindow = clock.now >= limit
            let observedAfter = Date().timeIntervalSince1970
            let current = try await receipt(deadline: .seconds(2)) {
                $0.sequence > previous.sequence
                    && $0.observedAt > max(previous.observedAt, observedAfter)
            }
            try require(
                current.outcome == baseline.outcome, "\(what) changed an owner outcome")
            previous = current
            if completesWindow { return }
            try await Task.sleep(for: .milliseconds(200))
        }
    }

    private func recordOutcome(tapInvoked: Int, notes: [String]) {
        let record: [String: Any] = [
            "nonce": nonce, "sourceSeal": sourceSeal, "bundleID": bundleID,
            "simulatorID": simulatorID, "tapInvoked": tapInvoked, "notes": notes,
            "finalSequence": Int(finalSequence),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        else { return }
        FileHandle.standardOutput.write(
            Data("GYRO_NATIVE_INPUT_OUTCOME:\(String(decoding: data, as: UTF8.self))\n".utf8))
    }
}

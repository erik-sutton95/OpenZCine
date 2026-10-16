import MonitorPresentation
import OpenCineAppUITesting
import XCTest

/// Real device qualification reuses the same shared driver as every camera app.
final class PhysicalReferenceAppTests: OpenCineAppUITesting.PhysicalReferenceAppTests {}

/// Opted-in current-build camera qualification through the common physical driver.
final class PhysicalMigrationQualificationTests: OpenCineAppUITesting.PhysicalMigrationQualificationTests {}

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

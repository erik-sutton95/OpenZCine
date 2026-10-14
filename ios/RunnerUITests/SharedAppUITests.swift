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

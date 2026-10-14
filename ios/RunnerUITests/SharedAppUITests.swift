import OpenCineAppUITesting

/// Real device qualification reuses the same shared driver as every camera app.
final class PhysicalReferenceAppTests: OpenCineAppUITesting.PhysicalReferenceAppTests {}

/// Opted-in current-build camera qualification through the common physical driver.
final class PhysicalMigrationQualificationTests: OpenCineAppUITesting.PhysicalMigrationQualificationTests {}

/// SIMULATED launch configuration only; layout and pixel assertions stay in OpenCine.
final class MonitorScreenshotLayoutTests: OpenCineAppUITesting.MonitorScreenshotLayoutTests {
    override var expectedStorageText: String { "521 GB" }
    override var expectedCameraPowerValue: String { "4 of 5 bars" }
    override var expectedCameraPercentText: String? { nil }
    override var reviewLaunchEnvironment: [String: String] {
        ["ZC_DEMO_AUTOSTART": "1", "ZC_DEMO_QUICK_SETTINGS": "1", "ZC_DEMO_DISP": "live", "ZC_DEMO_GRAPHICAL_REVIEW": "1"]
    }
}

import Foundation
import Testing

@testable import Runner

/// The level overlay's device fallback maps CoreMotion gravity (fixed, portrait-referenced device
/// frame: +x out the right edge, +y out the top) to screen-plane roll for the two orientations the
/// app supports. An axis pointing at the ground reads +1, at the sky −1 — so upright portrait is
/// gravity (0, −1) and upright LandscapeRight (home side right, device +x skyward) is (−1, 0).
@Suite("Level gauge display roll")
struct LevelDisplayRollTests {

    /// Gravity components for a device rotated `phi` degrees counterclockwise (viewer's
    /// perspective) from portrait-upright: g.x = −sin φ, g.y = −cos φ.
    private func gravity(deviceCCWDegrees phi: Double) -> (x: Double, y: Double) {
        let r = phi * .pi / 180
        return (-sin(r), -cos(r))
    }

    @Test("Portrait: upright reads level, clockwise tilt reads positive")
    func portraitMapping() {
        let level = gravity(deviceCCWDegrees: 0)
        #expect(
            abs(DeviceLevel.displayRoll(gravityX: level.x, gravityY: level.y, isPortrait: true))
                < 0.0001)

        // 10° clockwise = −10° CCW.
        let tilted = gravity(deviceCCWDegrees: -10)
        let roll = DeviceLevel.displayRoll(gravityX: tilted.x, gravityY: tilted.y, isPortrait: true)
        #expect(abs(roll - 10) < 0.0001)
    }

    @Test("LandscapeRight: upright reads level, clockwise tilt reads positive")
    func landscapeRightMapping() {
        // Interface LandscapeRight = device rotated +90° CCW (home side right).
        let level = gravity(deviceCCWDegrees: 90)
        #expect(level.x == -1)
        #expect(
            abs(DeviceLevel.displayRoll(gravityX: level.x, gravityY: level.y, isPortrait: false))
                < 0.0001)

        let tilted = gravity(deviceCCWDegrees: 80)  // 10° clockwise from landscape-upright
        let roll = DeviceLevel.displayRoll(
            gravityX: tilted.x, gravityY: tilted.y, isPortrait: false)
        #expect(abs(roll - 10) < 0.0001)
    }

    @Test("The two orientations disagree by exactly 90° for the same physical pose")
    func orientationOffset() {
        let pose = gravity(deviceCCWDegrees: 45)
        let portrait = DeviceLevel.displayRoll(gravityX: pose.x, gravityY: pose.y, isPortrait: true)
        let landscape = DeviceLevel.displayRoll(
            gravityX: pose.x, gravityY: pose.y, isPortrait: false)
        #expect(abs((portrait - landscape) - (-90)) < 0.0001)
    }
}

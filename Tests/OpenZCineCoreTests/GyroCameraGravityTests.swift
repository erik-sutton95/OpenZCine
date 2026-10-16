import Foundation
import Testing

@testable import OpenZCineCore

struct GyroCameraGravityTests {
    @Test func knownCameraDirections() throws {
        let level = try #require(GyroCameraGravity.down(rollDegrees: 0, pitchDegrees: 0))
        #expect(level == GyroVector3(x: -1, y: 0, z: 0))
        let left = try #require(GyroCameraGravity.down(rollDegrees: 30, pitchDegrees: 0))
        let right = try #require(GyroCameraGravity.down(rollDegrees: -30, pitchDegrees: 0))
        #expect(left.y > 0)
        #expect(right.y < 0)
        let up = try #require(GyroCameraGravity.down(rollDegrees: 0, pitchDegrees: 30))
        let down = try #require(GyroCameraGravity.down(rollDegrees: 0, pitchDegrees: -30))
        #expect(up.z > 0)
        #expect(down.z < 0)
    }

    @Test func mixedPoseRemainsUnitLengthAndPitchDoesNotFollowRoll() throws {
        let gravity = try #require(GyroCameraGravity.down(rollDegrees: -45, pitchDegrees: 30))
        #expect(
            abs(gravity.x * gravity.x + gravity.y * gravity.y + gravity.z * gravity.z - 1) < 1e-12)
        #expect(abs(gravity.z - 0.5) < 1e-12)
        #expect(gravity.y < 0)
        #expect(GyroCameraGravity.down(rollDegrees: .nan, pitchDegrees: 0) == nil)
        #expect(GyroCameraGravity.down(rollDegrees: 0, pitchDegrees: .infinity) == nil)
    }
}

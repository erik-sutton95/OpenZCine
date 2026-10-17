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

    @Test func compoundInclinationsRecoverPhysicalDown() throws {
        let gravity = try #require(GyroCameraGravity.down(rollDegrees: -45, pitchDegrees: 30))
        #expect(abs(gravity.x + sqrt(3.0 / 7)) < 1e-12)
        #expect(abs(gravity.y + sqrt(3.0 / 7)) < 1e-12)
        #expect(abs(gravity.z - 1 / sqrt(7.0)) < 1e-12)
    }

    @Test func projectedAnglesRoundTripBothHemispheres() throws {
        for x in [-2.0, 2.0] {
            for y in [-1.0, 1.0] {
                for z in [-3.0, 3.0] {
                    let expected = try GyroVector3(x: x, y: y, z: z).normalized()
                    let actual = try #require(
                        GyroCameraGravity.down(
                            rollDegrees: atan2(y, -x) * 180 / .pi,
                            pitchDegrees: atan2(z, -x) * 180 / .pi))
                    #expect(actual.angle(to: expected) < 1e-10)
                }
            }
        }
    }

    @Test func projectedAnglesHandlePolesAndRejectAmbiguity() throws {
        let left = try #require(GyroCameraGravity.down(rollDegrees: 90, pitchDegrees: 0))
        let up = try #require(GyroCameraGravity.down(rollDegrees: 0, pitchDegrees: 90))
        #expect(left.angle(to: GyroVector3(x: 0, y: 1, z: 0)) < 1e-10)
        #expect(up.angle(to: GyroVector3(x: 0, y: 0, z: 1)) < 1e-10)
        #expect(GyroCameraGravity.down(rollDegrees: 90, pitchDegrees: 90) == nil)
        #expect(GyroCameraGravity.down(rollDegrees: -90, pitchDegrees: 90) == nil)
        #expect(GyroCameraGravity.down(rollDegrees: 30, pitchDegrees: 120) == nil)
        #expect(GyroCameraGravity.down(rollDegrees: .nan, pitchDegrees: 0) == nil)
        #expect(GyroCameraGravity.down(rollDegrees: 0, pitchDegrees: .infinity) == nil)
    }
}

import Foundation
import Testing

@testable import OpenZCineCore

@Suite("LiveView header: record state + level")
struct LiveViewHeaderTests {
    /// Builds a 1024-byte display-info header with the record-state byte (828) and the three
    /// big-endian 16.16 fixed-point level angles (Rolling 840 / Pitching 844 / Yawing 848).
    private func header(recState: UInt8, roll: UInt32, pitch: UInt32, yaw: UInt32) -> Data {
        var bytes = [UInt8](repeating: 0, count: 1024)
        bytes[828] = recState
        func writeBE(_ value: UInt32, at offset: Int) {
            bytes[offset] = UInt8((value >> 24) & 0xFF)
            bytes[offset + 1] = UInt8((value >> 16) & 0xFF)
            bytes[offset + 2] = UInt8((value >> 8) & 0xFF)
            bytes[offset + 3] = UInt8(value & 0xFF)
        }
        writeBE(roll, at: 840)
        writeBE(pitch, at: 844)
        writeBE(yaw, at: 848)
        return Data(bytes)
    }

    /// degrees → 16.16 fixed-point raw value.
    private func fixed(_ degrees: Double) -> UInt32 { UInt32(degrees * 65536) }

    @Test func recordStateByte() {
        #expect(
            PTPLiveViewObject.recordingState(from: header(recState: 1, roll: 0, pitch: 0, yaw: 0)))
        #expect(
            !PTPLiveViewObject.recordingState(from: header(recState: 0, roll: 0, pitch: 0, yaw: 0)))
    }

    @Test func levelAnglesDecode16_16() {
        let level = PTPLiveViewObject.levelAngles(
            from: header(recState: 0, roll: fixed(10.5), pitch: fixed(2.0), yaw: fixed(3.25)))
        let angles = try? #require(level)
        #expect(abs((angles?.roll ?? -1) - 10.5) < 0.001)
        #expect(abs((angles?.pitch ?? -1) - 2.0) < 0.001)
        #expect(abs((angles?.yaw ?? -1) - 3.25) < 0.001)
    }

    @Test func levelMaxMatchesDocumentedRange() {
        // The spec's stated maximum, 359.9999847412109375, is exactly 359 + 65535/65536.
        let level = PTPLiveViewObject.levelAngles(
            from: header(recState: 0, roll: 0x00FF_FFFF & 0xFFFF_FFFF, pitch: 0, yaw: 0))
        // 0x00FFFFFF is 255.99998..°; just assert decode is value/65536.
        #expect(abs((level?.roll ?? 0) - (Double(0x00FF_FFFF) / 65536.0)) < 0.0001)
    }

    @Test func levelNilWhenRollUnreliable() {
        // 0xFFFFFFFF == "angle not acquired / unreliable" per the spec.
        let level = PTPLiveViewObject.levelAngles(
            from: header(recState: 0, roll: 0xFFFF_FFFF, pitch: fixed(2.0), yaw: 0))
        #expect(level == nil)
    }

    @Test func signedRollWrapsAroundLevel() {
        // Roll is reported 0–360 (0 = level); the overlay wants a signed tilt about 0.
        #expect(abs(PTPLevelAngles.signedDegrees(0.5) - 0.5) < 1e-9)
        #expect(abs(PTPLevelAngles.signedDegrees(359.5) - -0.5) < 1e-9)
        #expect(abs(PTPLevelAngles.signedDegrees(180) - 180) < 1e-9)
        #expect(abs(PTPLevelAngles.signedDegrees(270) - -90) < 1e-9)
    }
}

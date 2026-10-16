import Foundation

/// Converts camera level angles to physical down in Gyroflow's up/left/backward basis.
public enum GyroCameraGravity {
    /// Requires measured roll and pitch; callers must reject missing camera axes first.
    /// Roll is positive with the camera's top leaning left; pitch is positive lens-up.
    /// A calibration is usable only after its independent mixed-pose check passes.
    public static func down(rollDegrees: Double, pitchDegrees: Double) -> GyroVector3? {
        guard rollDegrees.isFinite, pitchDegrees.isFinite,
            abs(rollDegrees) <= 360, abs(pitchDegrees) <= 360
        else { return nil }
        let roll = rollDegrees * .pi / 180
        let pitch = pitchDegrees * .pi / 180
        return GyroVector3(
            x: -cos(pitch) * cos(roll),
            y: cos(pitch) * sin(roll),
            z: sin(pitch))
    }
}

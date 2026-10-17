import Foundation

/// Converts camera level angles to physical down in Gyroflow's up/left/backward basis.
public enum GyroCameraGravity {
    /// Requires measured roll and pitch; callers must reject missing camera axes first.
    /// Roll is positive with the camera's top leaning left; pitch is positive lens-up.
    /// The angles are independent projected inclinations, not Euler angles. Inconsistent
    /// hemispheres or a simultaneous 90-degree inclination cannot determine physical down.
    /// A calibration is usable only after its independent mixed-pose check passes.
    public static func down(rollDegrees: Double, pitchDegrees: Double) -> GyroVector3? {
        guard rollDegrees.isFinite, pitchDegrees.isFinite,
            abs(rollDegrees) <= 360, abs(pitchDegrees) <= 360
        else { return nil }
        let roll = rollDegrees * .pi / 180
        let pitch = pitchDegrees * .pi / 180
        let cr = cos(roll)
        let cp = cos(pitch)
        let epsilon = 1e-12
        guard abs(cr) > epsilon || abs(cp) > epsilon else { return nil }
        guard abs(cr) <= epsilon || abs(cp) <= epsilon || cr * cp >= 0 else { return nil }
        let hemisphere = abs(cr) >= abs(cp) ? cr : cp
        let direction = GyroVector3(
            x: -cr * cp, y: sin(roll) * cp, z: sin(pitch) * cr)
        return try? (direction * (hemisphere < 0 ? -1 : 1)).normalized()
    }
}

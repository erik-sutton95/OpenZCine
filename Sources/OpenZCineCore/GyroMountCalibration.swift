import Foundation

/// A vector in fixed sensor axes; calibration inputs describe physical down, not screen orientation.
public struct GyroVector3: Codable, Equatable, Sendable {
    /// Component along the fixed X axis.
    public let x: Double
    /// Component along the fixed Y axis.
    public let y: Double
    /// Component along the fixed Z axis.
    public let z: Double

    /// Creates a vector; calibration rejects nonfinite or zero gravity readings.
    public init(x: Double, y: Double, z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }

    var length: Double { hypot(hypot(x, y), z) }
    func dot(_ other: Self) -> Double { x * other.x + y * other.y + z * other.z }
    func cross(_ other: Self) -> Self {
        Self(
            x: y * other.z - z * other.y, y: z * other.x - x * other.z,
            z: x * other.y - y * other.x)
    }
    func normalized() throws -> Self {
        let magnitude = length
        guard magnitude.isFinite, magnitude > 1e-12 else {
            throw GyroMountCalibrationError.invalidReadings
        }
        return self * (1 / magnitude)
    }
    func angle(to other: Self) -> Double {
        atan2(cross(other).length, dot(other)) * 180 / .pi
    }
    static func + (a: Self, b: Self) -> Self { Self(x: a.x + b.x, y: a.y + b.y, z: a.z + b.z) }
    static func * (a: Self, scale: Double) -> Self {
        Self(x: a.x * scale, y: a.y * scale, z: a.z * scale)
    }
}

/// Averaged simultaneous physical-down readings in phone axes and camera-up/left/backward axes.
public struct GyroCalibrationPose: Equatable, Sendable {
    /// Physical down in the phone's fixed hardware axes.
    public let phoneDown: GyroVector3
    /// Physical down in the camera's fixed up/left/backward basis.
    public let cameraDown: GyroVector3

    /// Creates one still pose; the solver normalizes both readings.
    public init(phoneDown: GyroVector3, cameraDown: GyroVector3) {
        self.phoneDown = phoneDown
        self.cameraDown = cameraDown
    }

    func normalized() throws -> Self {
        try Self(phoneDown: phoneDown.normalized(), cameraDown: cameraDown.normalized())
    }
}

/// Calibration failures shared by both shells, including capture readiness and geometry checks.
public enum GyroMountCalibrationError: Error, LocalizedError, Equatable, Sendable {
    /// A sensor reading or timestamp is invalid.
    case invalidReadings
    /// The still window does not yet contain enough independent readings.
    case insufficientReadings
    /// The newest readings are stale, in the future, or too far apart in time.
    case staleReadings
    /// Gravity varied too far during the capture window.
    case moving
    /// The two fitted gravity directions are too close or nearly opposite.
    case insufficientSeparation
    /// The two sensors disagree about the angle between the fitted poses.
    case inconsistentPoses
    /// Validation needs both tilt within and roll outside the first two poses' plane.
    case unmixedValidation
    /// The independently measured third pose does not match the fitted rotation.
    case validationMismatch
    /// A saved rotation is not a finite, proper orthonormal rotation.
    case invalidCalibration
    /// A completed capture session must be reset before starting again.
    case completed

    /// Operator-readable recovery guidance.
    public var errorDescription: String? {
        switch self {
        case .invalidReadings: "Calibration needs valid, increasing phone and camera readings."
        case .insufficientReadings: "Hold the rig still for at least one second before capturing."
        case .staleReadings: "Wait for fresh phone and camera level readings."
        case .moving: "Keep the phone fixed to the camera and hold the rig still."
        case .insufficientSeparation: "Use a pose 20 to 160 degrees from the first pose."
        case .inconsistentPoses:
            "The phone and camera disagree. Keep the mount fixed and try again."
        case .unmixedValidation: "For the final pose, tilt and roll the camera together."
        case .validationMismatch: "The final pose did not match. Reset calibration and try again."
        case .invalidCalibration: "The saved gyro mount calibration is invalid. Calibrate again."
        case .completed: "Calibration is complete. Reset to calibrate another mount."
        }
    }
}

/// A validated proper rotation from raw phone axes into Gyroflow's camera-up/left/backward basis.
public struct GyroMountCalibration: Codable, Equatable, Sendable {
    private let rotation: [GyroVector3]
    /// Independent third-pose angular error; never a percentage confidence score.
    public let validationErrorDegrees: Double
    /// Angular separation of the two camera poses used to fit the rotation.
    public let separationDegrees: Double

    /// Solves from two nonparallel still poses and verifies a held-out mixed third pose.
    public static func solve(
        first: GyroCalibrationPose, second: GyroCalibrationPose, validation: GyroCalibrationPose
    ) throws -> Self {
        let first = try first.normalized()
        let second = try second.normalized()
        let validation = try validation.normalized()
        let separation = try validatePair(first: first, second: second)
        let phone = try basis(first.phoneDown, second.phoneDown)
        let camera = try basis(first.cameraDown, second.cameraDown)
        let minimumMixedComponent: Double = sin(15 * .pi / 180)
        guard abs(validation.phoneDown.dot(phone.1)) >= minimumMixedComponent,
            abs(validation.phoneDown.dot(phone.2)) >= minimumMixedComponent,
            abs(validation.cameraDown.dot(camera.1)) >= minimumMixedComponent,
            abs(validation.cameraDown.dot(camera.2)) >= minimumMixedComponent
        else { throw GyroMountCalibrationError.unmixedValidation }
        let rows = [
            phone.0 * camera.0.x + phone.1 * camera.1.x + phone.2 * camera.2.x,
            phone.0 * camera.0.y + phone.1 * camera.1.y + phone.2 * camera.2.y,
            phone.0 * camera.0.z + phone.1 * camera.1.z + phone.2 * camera.2.z,
        ]
        let mapped = GyroVector3(
            x: rows[0].dot(validation.phoneDown),
            y: rows[1].dot(validation.phoneDown), z: rows[2].dot(validation.phoneDown))
        let error = mapped.angle(to: validation.cameraDown)
        guard error <= 2 else { throw GyroMountCalibrationError.validationMismatch }
        return try Self(
            rotation: rows, validationErrorDegrees: error, separationDegrees: separation)
    }

    /// Rotates angular velocity exactly once, preserving radians/second and the sensor timestamp.
    public func applying(to sample: GyroSample) -> GyroSample {
        let vector = GyroVector3(x: sample.x, y: sample.y, z: sample.z)
        return GyroSample(
            timestamp: sample.timestamp, x: rotation[0].dot(vector),
            y: rotation[1].dot(vector), z: rotation[2].dot(vector))
    }

    /// Decodes only a finite proper rotation and valid stored quality measurements.
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            rotation: values.decode([GyroVector3].self, forKey: .rotation),
            validationErrorDegrees: values.decode(Double.self, forKey: .validationErrorDegrees),
            separationDegrees: values.decode(Double.self, forKey: .separationDegrees))
    }

    static func validatePair(first: GyroCalibrationPose, second: GyroCalibrationPose) throws
        -> Double
    {
        let first = try first.normalized()
        let second = try second.normalized()
        let phone = first.phoneDown.angle(to: second.phoneDown)
        let camera = first.cameraDown.angle(to: second.cameraDown)
        guard (20...160).contains(phone), (20...160).contains(camera) else {
            throw GyroMountCalibrationError.insufficientSeparation
        }
        guard abs(phone - camera) <= 2 else { throw GyroMountCalibrationError.inconsistentPoses }
        return camera
    }

    private static func basis(_ first: GyroVector3, _ second: GyroVector3) throws
        -> (GyroVector3, GyroVector3, GyroVector3)
    {
        let third = try first.cross(second).normalized()
        return (first, third.cross(first), third)
    }

    private init(rotation: [GyroVector3], validationErrorDegrees: Double, separationDegrees: Double)
        throws
    {
        guard rotation.count == 3,
            rotation.allSatisfy({ $0.length.isFinite && abs($0.length - 1) <= 1e-6 }),
            abs(rotation[0].dot(rotation[1])) <= 1e-6,
            abs(rotation[0].dot(rotation[2])) <= 1e-6,
            abs(rotation[1].dot(rotation[2])) <= 1e-6,
            abs(rotation[0].dot(rotation[1].cross(rotation[2])) - 1) <= 1e-6,
            validationErrorDegrees.isFinite, (0...2).contains(validationErrorDegrees),
            separationDegrees.isFinite, (20...160).contains(separationDegrees)
        else { throw GyroMountCalibrationError.invalidCalibration }
        self.rotation = rotation
        self.validationErrorDegrees = validationErrorDegrees
        self.separationDegrees = separationDegrees
    }
}

/// Three still captures over phone-clock timestamps; platform adapters supply physical-down vectors.
public struct GyroMountCalibrationSession: Sendable {
    /// Number of accepted poses, including the independent final verification pose.
    public var poseCount: Int { poses.count }
    private var poses: [GyroCalibrationPose] = []
    private var phone: [Reading] = []
    private var camera: [Reading] = []
    private var lastPhoneTimestamp: Double?
    private var lastCameraTimestamp: Double?
    private var lastCameraVector: GyroVector3?
    private var inputFailure: GyroMountCalibrationError?

    /// Starts an empty calibration session.
    public init() {}

    /// Adds a new phone sample and the latest camera sample. Repeated camera timestamps are not
    /// counted twice; duplicate/backward phone timestamps or backward camera timestamps clear the window.
    public mutating func add(
        phoneDown: GyroVector3, phoneTimestamp: Double,
        cameraDown: GyroVector3, cameraTimestamp: Double
    ) {
        do {
            try validateTimestamps(phone: phoneTimestamp, camera: cameraTimestamp)
            let phoneDown = try phoneDown.normalized()
            let cameraDown = try cameraDown.normalized()
            guard abs(phoneTimestamp - cameraTimestamp) <= 0.25 else {
                throw GyroMountCalibrationError.staleReadings
            }
            guard lastCameraTimestamp != cameraTimestamp || lastCameraVector == cameraDown else {
                throw GyroMountCalibrationError.invalidReadings
            }
            append(phoneDown, at: phoneTimestamp, cameraDown: cameraDown, at: cameraTimestamp)
            guard phone.count <= 512, camera.count <= 512 else {
                throw GyroMountCalibrationError.invalidReadings
            }
            inputFailure = nil
        } catch {
            clearWindow()
            inputFailure = (error as? GyroMountCalibrationError) ?? .invalidReadings
        }
    }

    /// Captures a fresh still window, returning a verified rotation only after the third pose.
    /// A failed capture never advances the pose count.
    public mutating func capture(at timestamp: Double) throws -> GyroMountCalibration? {
        guard poseCount < 3 else { throw GyroMountCalibrationError.completed }
        if let inputFailure { throw inputFailure }
        let pose = try currentPose(at: timestamp)
        if poses.count == 1, let first = poses.first {
            _ = try GyroMountCalibration.validatePair(first: first, second: pose)
        }
        let result: GyroMountCalibration?
        if poses.count == 2 {
            result = try GyroMountCalibration.solve(
                first: poses[0], second: poses[1], validation: pose)
        } else {
            result = nil
        }
        poses.append(pose)
        clearWindow()
        return result
    }

    /// Rejects an unavailable adapter reading while preserving previously accepted poses.
    public mutating func invalidateReadings() {
        clearWindow()
        inputFailure = .invalidReadings
    }

    /// Discards all poses and readings before calibrating again.
    public mutating func reset() { self = Self() }

    private func validateTimestamps(phone: Double, camera: Double) throws {
        guard phone.isFinite, camera.isFinite, phone >= 0, camera >= 0,
            lastPhoneTimestamp.map({ phone > $0 }) ?? true,
            lastCameraTimestamp.map({ camera >= $0 }) ?? true
        else { throw GyroMountCalibrationError.invalidReadings }
    }

    private mutating func append(
        _ phoneDown: GyroVector3, at phoneTimestamp: Double,
        cameraDown: GyroVector3, at cameraTimestamp: Double
    ) {
        phone.append(Reading(vector: phoneDown, timestamp: phoneTimestamp))
        if lastCameraTimestamp != cameraTimestamp {
            camera.append(Reading(vector: cameraDown, timestamp: cameraTimestamp))
        }
        lastPhoneTimestamp = phoneTimestamp
        lastCameraTimestamp = cameraTimestamp
        lastCameraVector = cameraDown
        let oldest = max(phoneTimestamp, cameraTimestamp) - 1.5
        phone.removeAll { $0.timestamp < oldest }
        camera.removeAll { $0.timestamp < oldest }
    }

    private func currentPose(at timestamp: Double) throws -> GyroCalibrationPose {
        guard phone.count >= 15, camera.count >= 5,
            let firstPhone = phone.first, let lastPhone = phone.last,
            let firstCamera = camera.first, let lastCamera = camera.last
        else { throw GyroMountCalibrationError.insufficientReadings }
        guard timestamp.isFinite,
            (0...0.25).contains(timestamp - lastPhone.timestamp),
            (0...0.25).contains(timestamp - lastCamera.timestamp)
        else { throw GyroMountCalibrationError.staleReadings }
        let duration =
            min(lastPhone.timestamp, lastCamera.timestamp)
            - max(firstPhone.timestamp, firstCamera.timestamp)
        guard duration >= 1 - 1e-9 else { throw GyroMountCalibrationError.insufficientReadings }
        return try GyroCalibrationPose(phoneDown: mean(phone), cameraDown: mean(camera))
    }

    private func mean(_ readings: [Reading]) throws -> GyroVector3 {
        let sum = readings.reduce(GyroVector3(x: 0, y: 0, z: 0)) { $0 + $1.vector }
        let mean = try sum.normalized()
        guard readings.allSatisfy({ $0.vector.angle(to: mean) <= 3 }) else {
            throw GyroMountCalibrationError.moving
        }
        return mean
    }

    private mutating func clearWindow() {
        phone.removeAll(keepingCapacity: true)
        camera.removeAll(keepingCapacity: true)
    }

    private struct Reading: Sendable {
        let vector: GyroVector3
        let timestamp: Double
    }
}

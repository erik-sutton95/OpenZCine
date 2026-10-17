import Foundation
import Testing

@testable import OpenZCineCore

@Suite("Automatic gyro mount calibration")
struct GyroMountCalibrationTests {
    private let first = GyroVector3(x: -1, y: 0, z: 0)
    private let second = GyroVector3(x: -sqrt(0.75), y: 0, z: 0.5)
    private let third = GyroVector3(x: -0.75, y: sqrt(0.1875), z: 0.5)

    @Test func arbitraryRotationRecoversAllAxesAndPreservesUnits() throws {
        let axis = GyroVector3(x: 0.3, y: -0.4, z: 0.7)
        let calibration = try GyroMountCalibration.solve(
            first: pose(first, axis: axis), second: pose(second, axis: axis),
            validation: pose(third, axis: axis))
        for vector in [
            GyroVector3(x: 1, y: 0, z: 0), GyroVector3(x: 0, y: 1, z: 0),
            GyroVector3(x: 0, y: 0, z: 1), GyroVector3(x: 1.3, y: -2.4, z: 3.5),
        ] {
            let sample = GyroSample(timestamp: 12.345, x: vector.x, y: vector.y, z: vector.z)
            let mapped = calibration.applying(to: sample)
            let expected = rotate(vector, axis: axis, degrees: 53)
            #expect(close(mapped.x, expected.x) && close(mapped.y, expected.y))
            #expect(close(mapped.z, expected.z))
            #expect(mapped.timestamp == sample.timestamp)
            #expect(close(GyroVector3(x: mapped.x, y: mapped.y, z: mapped.z).length, vector.length))
        }
        #expect(calibration.validationErrorDegrees < 1e-10)
        #expect(close(calibration.separationDegrees, 30))
    }

    @Test(arguments: GyroMountPreset.allCases)
    func cardinalCalibrationsMatchExistingPhysicalMounts(mount: GyroMountPreset) throws {
        func pose(_ vector: GyroVector3) -> GyroCalibrationPose {
            GyroCalibrationPose(
                phoneDown: inverseRemap(vector, mount.orientation), cameraDown: vector)
        }
        let calibration = try GyroMountCalibration.solve(
            first: pose(first), second: pose(second), validation: pose(third))
        let camera = GyroVector3(x: 1.3, y: -2.4, z: 3.5)
        let raw = inverseRemap(camera, mount.orientation)
        let mapped = calibration.applying(
            to: GyroSample(timestamp: 1, x: raw.x, y: raw.y, z: raw.z))
        #expect(close(mapped.x, camera.x) && close(mapped.y, camera.y) && close(mapped.z, camera.z))
    }

    @Test func rejectsDegenerateInconsistentOrReflectedPoses() throws {
        let a = identityPose(first)
        let b = identityPose(second)
        #expect(throws: GyroMountCalibrationError.insufficientSeparation) {
            try GyroMountCalibration.solve(first: a, second: a, validation: identityPose(third))
        }
        #expect(throws: GyroMountCalibrationError.insufficientSeparation) {
            try GyroMountCalibration.solve(
                first: a, second: identityPose(first * -1),
                validation: identityPose(third))
        }
        let mismatched = GyroCalibrationPose(
            phoneDown: second,
            cameraDown: GyroVector3(x: -sqrt(0.5), y: 0, z: sqrt(0.5)))
        #expect(throws: GyroMountCalibrationError.inconsistentPoses) {
            try GyroMountCalibration.solve(
                first: a, second: mismatched, validation: identityPose(third))
        }
        #expect(throws: GyroMountCalibrationError.unmixedValidation) {
            try GyroMountCalibration.solve(first: a, second: b, validation: b)
        }
        let pureRoll = GyroVector3(x: -sqrt(0.5), y: sqrt(0.5), z: 0)
        #expect(throws: GyroMountCalibrationError.unmixedValidation) {
            try GyroMountCalibration.solve(first: a, second: b, validation: identityPose(pureRoll))
        }
        let reflected = GyroCalibrationPose(
            phoneDown: third,
            cameraDown: GyroVector3(x: third.x, y: -third.y, z: third.z))
        #expect(throws: GyroMountCalibrationError.validationMismatch) {
            try GyroMountCalibration.solve(first: a, second: b, validation: reflected)
        }
    }

    @Test func normalizesGravityAndRejectsNonfiniteOrZeroInputs() throws {
        let scaled = try GyroMountCalibration.solve(
            first: GyroCalibrationPose(phoneDown: first * 9.81, cameraDown: first * 2),
            second: GyroCalibrationPose(phoneDown: second * 9.81, cameraDown: second * 2),
            validation: GyroCalibrationPose(phoneDown: third * 9.81, cameraDown: third * 2))
        #expect(scaled.validationErrorDegrees < 1e-10)
        for bad in [
            GyroVector3(x: 0, y: 0, z: 0), GyroVector3(x: .nan, y: 0, z: 0),
            GyroVector3(x: 1, y: .infinity, z: 0),
        ] {
            #expect(throws: GyroMountCalibrationError.invalidReadings) {
                try GyroMountCalibration.solve(
                    first: identityPose(bad), second: identityPose(second),
                    validation: identityPose(third))
            }
        }
    }

    @Test func heldOutErrorReportsSmallNoiseButRejectsLargerMismatch() throws {
        let axis = GyroVector3(x: third.y, y: -third.x, z: 0)
        let noisy = GyroCalibrationPose(
            phoneDown: third,
            cameraDown: rotate(third, axis: axis, degrees: 1))
        let calibration = try GyroMountCalibration.solve(
            first: identityPose(first), second: identityPose(second), validation: noisy)
        #expect(close(calibration.validationErrorDegrees, 1))
        let bad = GyroCalibrationPose(
            phoneDown: third,
            cameraDown: rotate(third, axis: axis, degrees: 3))
        #expect(throws: GyroMountCalibrationError.validationMismatch) {
            try GyroMountCalibration.solve(
                first: identityPose(first), second: identityPose(second),
                validation: bad)
        }
    }

    @Test func persistedCalibrationRejectsScalingShearReflectionAndInvalidQuality() throws {
        let calibration = try GyroMountCalibration.solve(
            first: identityPose(first), second: identityPose(second),
            validation: identityPose(third))
        let data = try JSONEncoder().encode(calibration)
        #expect(try JSONDecoder().decode(GyroMountCalibration.self, from: data) == calibration)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let badRows: [[GyroVector3]] = [
            [
                GyroVector3(x: 2, y: 0, z: 0), GyroVector3(x: 0, y: 1, z: 0),
                GyroVector3(x: 0, y: 0, z: 1),
            ],
            [
                GyroVector3(x: -1, y: 0, z: 0), GyroVector3(x: 0, y: 1, z: 0),
                GyroVector3(x: 0, y: 0, z: 1),
            ],
            [
                GyroVector3(x: 1, y: 0, z: 0), GyroVector3(x: 0.1, y: sqrt(0.99), z: 0),
                GyroVector3(x: 0, y: 0, z: 1),
            ],
            [],
        ]
        for rows in badRows {
            var bad = json
            bad["rotation"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(rows))
            let bytes = try JSONSerialization.data(withJSONObject: bad)
            #expect(throws: GyroMountCalibrationError.invalidCalibration) {
                try JSONDecoder().decode(GyroMountCalibration.self, from: bytes)
            }
        }
        for field in ["validationErrorDegrees", "separationDegrees"] {
            var bad = json
            bad[field] = -1
            let bytes = try JSONSerialization.data(withJSONObject: bad)
            #expect(throws: GyroMountCalibrationError.invalidCalibration) {
                try JSONDecoder().decode(GyroMountCalibration.self, from: bytes)
            }
        }
    }

    @Test func captureCountsDistinctCameraSamplesAndPreservesFailedPoseProgress() throws {
        var session = GyroMountCalibrationSession()
        feed(&session, first, base: 0)
        #expect(try session.capture(at: 1.3) == nil)
        #expect(session.poseCount == 1)
        feed(&session, first, base: 2)
        #expect(throws: GyroMountCalibrationError.insufficientSeparation) {
            try session.capture(at: 3.3)
        }
        #expect(session.poseCount == 1)
        feed(&session, second, base: 4)
        #expect(try session.capture(at: 5.3) == nil)
        feed(&session, second, base: 6)
        #expect(throws: GyroMountCalibrationError.unmixedValidation) {
            try session.capture(at: 7.3)
        }
        #expect(session.poseCount == 2)
        feed(&session, third, base: 8)
        #expect(try session.capture(at: 9.3) != nil)
        #expect(session.poseCount == 3)
        #expect(throws: GyroMountCalibrationError.completed) { try session.capture(at: 9.3) }
        session.reset()
        #expect(session.poseCount == 0)
        #expect(throws: GyroMountCalibrationError.insufficientReadings) {
            try session.capture(at: 10)
        }
    }

    @Test func rejectsMovingStaleAndUndersampledWindows() {
        var moving = GyroMountCalibrationSession()
        for index in 0..<40 {
            let t = Double(index) / 30
            let angle = (index.isMultiple(of: 2) ? 5.0 : -5.0) * .pi / 180
            moving.add(
                phoneDown: GyroVector3(x: -cos(angle), y: sin(angle), z: 0), phoneTimestamp: t,
                cameraDown: first, cameraTimestamp: Double(index / 6) / 5)
        }
        #expect(throws: GyroMountCalibrationError.moving) { try moving.capture(at: 1.3) }
        var stale = GyroMountCalibrationSession()
        feed(&stale, first, base: 0)
        #expect(throws: GyroMountCalibrationError.staleReadings) { try stale.capture(at: 1.6) }
        #expect(throws: GyroMountCalibrationError.staleReadings) { try stale.capture(at: 1) }
        var short = GyroMountCalibrationSession()
        for index in 0..<40 {
            short.add(
                phoneDown: first, phoneTimestamp: Double(index) / 1000,
                cameraDown: first, cameraTimestamp: 0)
        }
        #expect(throws: GyroMountCalibrationError.insufficientReadings) {
            try short.capture(at: 0.04)
        }
        #expect(moving.poseCount == 0 && stale.poseCount == 0 && short.poseCount == 0)
    }

    @Test func invalidOrReplayedReadingsClearOnlyTheCurrentWindow() throws {
        for failure in 0..<6 {
            var session = GyroMountCalibrationSession()
            feed(&session, first, base: 0)
            _ = try session.capture(at: 1.3)
            feed(&session, second, base: 2)
            if failure == 5 {
                session.invalidateReadings()
            } else {
                session.add(
                    phoneDown: failure == 0 ? GyroVector3(x: .nan, y: 0, z: 0) : second,
                    phoneTimestamp: failure == 4 ? 3.8 : (failure == 1 ? 3.3 : 3.4),
                    cameraDown: failure == 3 ? third : second,
                    cameraTimestamp: failure == 2 ? 3 : 3.2)
            }
            #expect(
                throws: failure == 4 ? GyroMountCalibrationError.staleReadings : .invalidReadings
            ) {
                try session.capture(at: 3.4)
            }
            #expect(session.poseCount == 1)
            feed(&session, second, base: 4)
            #expect(try session.capture(at: 5.3) == nil)
            #expect(session.poseCount == 2)
        }
    }

    private func identityPose(_ vector: GyroVector3) -> GyroCalibrationPose {
        GyroCalibrationPose(phoneDown: vector, cameraDown: vector)
    }
    private func pose(_ camera: GyroVector3, axis: GyroVector3) -> GyroCalibrationPose {
        GyroCalibrationPose(phoneDown: rotate(camera, axis: axis, degrees: -53), cameraDown: camera)
    }
    private func rotate(_ vector: GyroVector3, axis: GyroVector3, degrees: Double) -> GyroVector3 {
        // Independent Rodrigues reference, rather than the solver's basis construction.
        let axis = axis * (1 / axis.length)
        let angle = degrees * .pi / 180
        return vector * cos(angle) + axis.cross(vector) * sin(angle)
            + axis * (axis.dot(vector) * (1 - cos(angle)))
    }
    private func inverseRemap(_ camera: GyroVector3, _ orientation: String) -> GyroVector3 {
        var phone = [0.0, 0.0, 0.0]
        for (character, value) in zip(orientation, [camera.x, camera.y, camera.z]) {
            switch character {
            case "X": phone[0] = value
            case "x": phone[0] = -value
            case "Y": phone[1] = value
            case "y": phone[1] = -value
            case "Z": phone[2] = value
            default: phone[2] = -value
            }
        }
        return GyroVector3(x: phone[0], y: phone[1], z: phone[2])
    }
    private func feed(
        _ session: inout GyroMountCalibrationSession, _ down: GyroVector3, base: Double
    ) {
        for index in 0..<40 {
            session.add(
                phoneDown: down, phoneTimestamp: base + Double(index) / 30,
                cameraDown: down, cameraTimestamp: base + Double(index / 6) / 5)
        }
    }
    private func close(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-10 }
}

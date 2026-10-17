import Foundation
import OpenZCineCore

/// Owner-keyed Android access to the portable mount-calibration workflow.
public final class GyroCalibrationWire: @unchecked Sendable {
    /// Shared registry; each open calibration screen owns one independent session.
    public static let shared = GyroCalibrationWire()
    private let lock = NSLock()
    private var sessions: [String: GyroMountCalibrationSession] = [:]

    /// Starts a calibration without starting sensors or changing a saved alignment.
    public func create() -> String {
        lock.withLock {
            let owner = UUID().uuidString
            sessions[owner] = GyroMountCalibrationSession()
            return owner
        }
    }

    /// Supplies raw physical-down phone data paired with measured camera level angles.
    public func add(owner: String, observationJSON: String) -> String? {
        lock.withLock {
            guard var session = sessions[owner] else { return nil }
            guard observationJSON.utf8.count <= 4_096,
                let data = observationJSON.data(using: .utf8),
                let observation = try? JSONDecoder().decode(Observation.self, from: data),
                let cameraDown = GyroCameraGravity.down(
                    rollDegrees: observation.rollDegrees, pitchDegrees: observation.pitchDegrees)
            else {
                session.invalidateReadings()
                sessions[owner] = session
                return reply(session, error: "Camera level readings are unavailable.")
            }
            session.add(
                phoneDown: observation.phoneDown, phoneTimestamp: observation.phoneTimestamp,
                cameraDown: cameraDown, cameraTimestamp: observation.cameraTimestamp)
            sessions[owner] = session
            return reply(session)
        }
    }

    /// Captures a still pose, returning an alignment only after the independent third pose passes.
    public func capture(owner: String, timestamp: Double) -> String? {
        lock.withLock {
            guard var session = sessions[owner] else { return nil }
            do {
                let calibration = try session.capture(at: timestamp)
                sessions[owner] = session
                return reply(session, calibration: calibration)
            } catch {
                sessions[owner] = session
                return reply(session, error: error.localizedDescription)
            }
        }
    }

    /// Releases a calibration screen's transient samples and poses.
    public func close(owner: String) { _ = lock.withLock { sessions.removeValue(forKey: owner) } }

    /// Checks a stored value through the same rotation validation used on iOS.
    public func validate(_ calibrationJSON: String) -> Bool {
        Self.decode(calibrationJSON) != nil
    }

    /// Decodes a bounded, validated calibration for the take's immutable descriptor.
    static func decode(_ json: String) -> GyroMountCalibration? {
        guard json.utf8.count <= 4_096, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(GyroMountCalibration.self, from: data)
    }

    private func reply(
        _ session: GyroMountCalibrationSession, calibration: GyroMountCalibration? = nil,
        error: String? = nil
    ) -> String? {
        guard
            let bytes = try? JSONEncoder().encode(
                Reply(poseCount: session.poseCount, calibration: calibration, error: error))
        else { return nil }
        return String(data: bytes, encoding: .utf8)
    }

    private struct Observation: Decodable {
        let phoneDown: GyroVector3
        let phoneTimestamp: Double
        let rollDegrees: Double
        let pitchDegrees: Double
        let cameraTimestamp: Double
    }

    private struct Reply: Encodable {
        let poseCount: Int
        let calibration: GyroMountCalibration?
        let error: String?
    }
}

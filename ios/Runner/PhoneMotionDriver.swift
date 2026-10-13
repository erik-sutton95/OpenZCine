import CoreMotion
import Foundation
import OpenZCineCore

/// The bounded handoff between Core Motion's serial callback queue and the log writer.
// SAFETY: every access to mutable callback state is guarded by lock.
final class GyroSampleBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [GyroSample] = []
    private var failure: GyroLogTermination?

    func append(_ sample: GyroSample) {
        lock.lock()
        defer { lock.unlock() }
        guard failure == nil else { return }
        guard samples.count < GyroTakeSession.maximumBufferedSamples else {
            failure = .bufferOverflow
            return
        }
        samples.append(sample)
    }

    func fail() {
        lock.lock()
        defer { lock.unlock() }
        failure = .sensorStalled
    }

    func drain() -> (samples: [GyroSample], failure: GyroLogTermination?) {
        lock.lock()
        defer { lock.unlock() }
        let result = (samples, failure)
        samples.removeAll(keepingCapacity: true)
        failure = nil
        return result
    }
}

@MainActor protocol GyroMotionDriving: AnyObject {
    func startGyro(into buffer: GyroSampleBuffer) throws
    func stopGyro()
}

enum PhoneMotionError: LocalizedError {
    case unavailable
    var errorDescription: String? { "This phone's gyroscope is unavailable." }
}

/// One motion manager serves the raw gyro logger and the independently paced level overlay.
@MainActor final class PhoneMotionDriver: GyroMotionDriving {
    static let shared = PhoneMotionDriver()
    private let manager = CMMotionManager()
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "org.openzcine.gyro"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        return queue
    }()
    private var gravityConsumers: [UUID: (Double, Double, Double) -> Void] = [:]

    func startGyro(into buffer: GyroSampleBuffer) throws {
        guard manager.isGyroAvailable else { throw PhoneMotionError.unavailable }
        manager.stopGyroUpdates()
        manager.gyroUpdateInterval = 1 / GyroTakeSession.requestedRate
        manager.startGyroUpdates(to: queue, withHandler: Self.gyroHandler(into: buffer))
    }

    // Core Motion invokes this on its sensor queue; the handler must not inherit MainActor.
    nonisolated static func gyroHandler(into buffer: GyroSampleBuffer)
        -> @Sendable (CMGyroData?, Error?) -> Void
    {
        { data, error in
            guard error == nil, let data else {
                buffer.fail()
                return
            }
            let rate = data.rotationRate
            buffer.append(GyroSample(timestamp: data.timestamp, x: rate.x, y: rate.y, z: rate.z))
        }
    }

    func stopGyro() { manager.stopGyroUpdates() }

    func startLevel(_ receive: @escaping (Double, Double, Double) -> Void) -> UUID {
        let id = UUID()
        gravityConsumers[id] = receive
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return id }
        manager.deviceMotionUpdateInterval = 1.0 / 30.0
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let gravity = motion?.gravity else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                for consumer in self.gravityConsumers.values {
                    consumer(gravity.x, gravity.y, gravity.z)
                }
            }
        }
        return id
    }

    func stopLevel(_ id: UUID) {
        gravityConsumers.removeValue(forKey: id)
        if gravityConsumers.isEmpty { manager.stopDeviceMotionUpdates() }
    }
}

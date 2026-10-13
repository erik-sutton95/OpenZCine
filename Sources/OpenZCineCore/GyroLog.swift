import Foundation

/// One gyroscope reading in fixed device axes, radians per second, on the sensor clock.
public struct GyroSample: Codable, Equatable, Sendable {
    /// Monotonic sensor time in seconds, never callback arrival or wall-clock time.
    public let timestamp: Double
    /// Angular velocity around the device's X axis, in radians per second.
    public let x: Double
    /// Angular velocity around the device's Y axis, in radians per second.
    public let y: Double
    /// Angular velocity around the device's Z axis, in radians per second.
    public let z: Double

    /// Creates a sample; the session rejects non-finite values and non-increasing timestamps.
    public init(timestamp: Double, x: Double, y: Double, z: Double) {
        self.timestamp = timestamp
        self.x = x
        self.y = y
        self.z = z
    }

    var isFinite: Bool { timestamp.isFinite && x.isFinite && y.isFinite && z.isFinite }
}

/// Why the phone stopped collecting a take's motion; this never commands the camera.
public enum GyroLogTermination: String, Codable, Sendable {
    /// Camera stop was observed and the postroll completed.
    case normal
    /// The recording was interrupted without a more specific cause.
    case interrupted
    /// The camera connection ended before the log completed.
    case disconnected
    /// The app left the foreground.
    case backgrounded
    /// The operator disabled gyro logging.
    case disabled
    /// No new motion arrived for the sensor-health timeout.
    case sensorStalled
    /// A bounded capture or output queue overflowed.
    case bufferOverflow
    /// The platform could not persist the output.
    case writeFailure
    /// Complete rows were recovered from an abandoned partial file.
    case recovered
}

/// Immutable identity and timing context written before a take's first GCSV bytes.
public struct GyroLogDescriptor: Codable, Equatable, Sendable, Identifiable {
    /// Unique identity for file ownership and adjacent overlapping takes.
    public let id: UUID
    /// Operator-visible camera label, without implying a known camera clip filename.
    public let cameraLabel: String
    /// Wall-clock time at which recording was first observed.
    public let startDate: Date
    /// Safe, unique filename for the finalized GCSV.
    public let filename: String
    /// Observed recording start minus log origin, in seconds; not a synchronization result.
    public let approximateStartOffset: Double
    /// True when recording was already active at first observation.
    public let isPartial: Bool

    /// Creates persisted metadata for a take, including its unique export filename.
    public init(
        id: UUID = UUID(), cameraLabel: String, startDate: Date,
        approximateStartOffset: Double, isPartial: Bool
    ) {
        self.id = id
        self.cameraLabel = cameraLabel
        self.startDate = startDate
        self.approximateStartOffset = approximateStartOffset
        self.isPartial = isPartial
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        filename = "OpenZCine-\(formatter.string(from: startDate))-\(id.uuidString).gcsv"
    }
}

/// Final sample health and coverage retained by the platform alongside a GCSV file.
public struct GyroLogSummary: Codable, Equatable, Sendable, Identifiable {
    /// Original take identity and approximate timing.
    public let descriptor: GyroLogDescriptor
    /// Number of successfully encoded, strictly increasing samples.
    public let sampleCount: Int
    /// Time between the first and last encoded sensor samples, in seconds.
    public let duration: Double
    /// Delivered samples per second, measured from sensor timestamps.
    public let measuredRate: Double
    /// Largest interval between encoded samples, in seconds.
    public let largestGap: Double
    /// Invalid or non-increasing samples rejected during this take.
    public let rejectedSampleCount: Int
    /// Reason this log ended.
    public let termination: GyroLogTermination
    /// True for incomplete pre/post coverage, late starts, lost samples, or interruptions/recovery.
    public let isPartial: Bool
    /// Unique take identity.
    public var id: UUID { descriptor.id }
    /// Operator-visible camera label.
    public var cameraLabel: String { descriptor.cameraLabel }
    /// Wall-clock time when recording was observed.
    public var startDate: Date { descriptor.startDate }
    /// Final GCSV filename.
    public var filename: String { descriptor.filename }
    /// Observed REC start relative to the first retained sample, matching Gyroflow's time origin.
    /// Negative values mean motion capture began after the observed recording start.
    public let approximateStartOffset: Double
    /// Whether any encoded interval exceeded 50 milliseconds.
    public var hasGapWarning: Bool { GyroStatistics.exceedsGapLimit(largestGap) }
}

/// Ordered file operations; the shell owns the file handles and performs all storage work.
public enum GyroLogUpdate: Equatable, Sendable {
    /// Persist the descriptor and open an app-private partial file.
    case opened(GyroLogDescriptor)
    /// Append bytes to the identified partial file in the order returned.
    case appended(id: UUID, data: Data)
    /// Flush, close and retain the summary, marking interrupted logs honestly.
    case finished(GyroLogSummary)
}

struct GyroStatistics: Sendable {
    var count = 0
    var first: Double?
    var last: Double?
    var largestGap = 0.0
    var rejected = 0

    static func exceedsGapLimit(_ interval: Double) -> Bool {
        (interval * 1_000_000).rounded() > 50_000
    }

    mutating func accept(_ timestamp: Double) {
        if let last { largestGap = max(largestGap, timestamp - last) }
        if first == nil { first = timestamp }
        last = timestamp
        count += 1
    }

    func summary(
        _ descriptor: GyroLogDescriptor, reason: GyroLogTermination,
        incompleteCoverage: Bool = false, origin: Double = 0
    ) -> GyroLogSummary {
        let duration = max(0, (last ?? 0) - (first ?? 0))
        let firstOffset = (((first ?? origin) - origin) * 1_000_000).rounded() / 1_000_000
        return GyroLogSummary(
            descriptor: descriptor, sampleCount: count, duration: duration,
            measuredRate: count > 1 && duration > 0 ? Double(count - 1) / duration : 0,
            largestGap: largestGap, rejectedSampleCount: rejected, termination: reason,
            isPartial: descriptor.isPartial || reason != .normal || rejected > 0
                || incompleteCoverage || Self.exceedsGapLimit(largestGap),
            approximateStartOffset: descriptor.approximateStartOffset - firstOffset
        )
    }
}

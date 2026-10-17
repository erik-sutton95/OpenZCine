import Foundation

/// Invalid motion input or an unsupported/corrupt partial-log header.
public enum GyroGCSVError: Error, LocalizedError, Equatable, Sendable {
    /// A sample cannot be represented by a finite, nonnegative microsecond row.
    case invalidSample
    /// Recovery only accepts the gyro-only GCSV schema emitted by this logger.
    case invalidHeader

    /// Operator-readable explanation of the failure.
    public var errorDescription: String? {
        switch self {
        case .invalidSample: "The gyro sample has invalid values or timing."
        case .invalidHeader: "The partial gyro log has an invalid header."
        }
    }
}

/// Portable GCSV 1.3 bytes; storage and camera synchronization remain outside this encoder.
public enum GyroGCSVEncoder {
    /// Emits camera axes for calibrated takes, or the take's selected raw-device remap.
    public static func header(descriptor: GyroLogDescriptor) -> Data {
        let camera = descriptor.cameraLabel.replacingOccurrences(of: ",", with: " ")
            .replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        let status =
            descriptor.mountCalibration == nil
            ? (descriptor.mount == .unconfigured ? "unverified" : "operator_selected")
            : "calibrated"
        return Data(
            """
            GYROFLOW IMU LOG
            version,1.3
            id,OpenZCine
            orientation,\(descriptor.orientation)
            orientation_status,\(status)
            mount_preset,\(descriptor.mount.rawValue)
            camera,\(camera)
            session_uuid,\(descriptor.id.uuidString)
            requested_sample_rate,100
            tscale,0.000001
            gscale,1
            t,gx,gy,gz

            """.utf8)
    }

    /// Encodes a sample relative to a fixed sensor-clock origin, applying a frozen calibration once.
    public static func row(
        _ sample: GyroSample, origin: Double, mountCalibration: GyroMountCalibration? = nil
    ) throws -> Data {
        let sample = mountCalibration?.applying(to: sample) ?? sample
        let microseconds = ((sample.timestamp - origin) * 1_000_000).rounded()
        guard sample.isFinite, origin.isFinite, microseconds.isFinite,
            microseconds >= 0, microseconds < Double(Int64.max)
        else { throw GyroGCSVError.invalidSample }
        return Data(
            String(
                format: "%lld,%.9f,%.9f,%.9f\n", locale: Locale(identifier: "en_US_POSIX"),
                Int64(microseconds), sample.x, sample.y, sample.z
            ).utf8)
    }
}

/// Incrementally validates an abandoned partial log without retaining its contents in memory.
public struct GyroGCSVRecovery: Sendable {
    /// Length of the valid prefix through the last complete line. Truncate the source to this size.
    public private(set) var validByteCount: UInt64 = 0
    private var byteCount: UInt64 = 0
    private var line: [UInt8] = []
    private var headerLines = 0
    private var hasTimeScale = false
    private var hasGyroScale = false
    private var hasOrientation = false
    private var orientation: String?
    private var headerComplete = false
    private var halted = false
    private var statistics = GyroStatistics()

    /// Starts validation for one partial GCSV file.
    public init() {}

    /// Consumes a file chunk. A damaged data row ends the retained prefix; a damaged header throws.
    public mutating func accept(_ chunk: Data) throws {
        guard !halted else { return }
        for byte in chunk {
            byteCount += 1
            if byte == 10 {
                try acceptLine()
                line.removeAll(keepingCapacity: true)
                if halted { return }
                validByteCount = byteCount
            } else {
                line.append(byte)
                if line.count > 4_096 {
                    guard headerComplete else { throw GyroGCSVError.invalidHeader }
                    rejectRow()
                    return
                }
            }
        }
    }

    /// Summarizes complete validated rows. An unterminated final line is deliberately excluded.
    public func finish(descriptor: GyroLogDescriptor) throws -> GyroLogSummary {
        guard headerComplete, orientation == descriptor.orientation else {
            throw GyroGCSVError.invalidHeader
        }
        return statistics.summary(descriptor, reason: .recovered)
    }

    private mutating func acceptLine() throws {
        guard let text = String(bytes: line, encoding: .utf8) else {
            guard headerComplete else { throw GyroGCSVError.invalidHeader }
            rejectRow()
            return
        }
        if !headerComplete {
            try acceptHeader(text)
            return
        }
        let fields = text.split(separator: ",", omittingEmptySubsequences: false)
        guard fields.count == 4, let micros = Int64(fields[0]), micros >= 0,
            fields.dropFirst().allSatisfy({ Double($0)?.isFinite == true })
        else {
            rejectRow()
            return
        }
        let timestamp = Double(micros) / 1_000_000
        guard statistics.last.map({ timestamp > $0 }) ?? true else {
            rejectRow()
            return
        }
        statistics.accept(timestamp)
    }

    private mutating func acceptHeader(_ text: String) throws {
        defer { headerLines += 1 }
        guard headerLines < 32 else { throw GyroGCSVError.invalidHeader }
        if headerLines == 0 {
            guard text == "GYROFLOW IMU LOG" else { throw GyroGCSVError.invalidHeader }
        } else if headerLines == 1 {
            guard text == "version,1.3" else { throw GyroGCSVError.invalidHeader }
        } else if text == "t,gx,gy,gz" {
            guard hasTimeScale, hasGyroScale, hasOrientation else {
                throw GyroGCSVError.invalidHeader
            }
            headerComplete = true
        } else if text.hasPrefix("orientation,") {
            let value = String(text.dropFirst("orientation,".count))
            guard GyroMountPreset.allCases.contains(where: { $0.orientation == value }),
                !hasOrientation
            else {
                throw GyroGCSVError.invalidHeader
            }
            hasOrientation = true
            orientation = value
        } else if text.hasPrefix("tscale,") {
            guard text == "tscale,0.000001", !hasTimeScale else {
                throw GyroGCSVError.invalidHeader
            }
            hasTimeScale = true
        } else if text.hasPrefix("gscale,") {
            guard text == "gscale,1", !hasGyroScale else { throw GyroGCSVError.invalidHeader }
            hasGyroScale = true
        } else if !text.contains(",") {
            throw GyroGCSVError.invalidHeader
        }
    }

    private mutating func rejectRow() {
        statistics.rejected += 1
        halted = true
    }
}

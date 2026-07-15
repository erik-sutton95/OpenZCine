import OpenZCineCore

/// Fixed-width JNI state for Android decoded-playback audio metering.
///
/// The payload order is `[leftLevelDB, leftPeakDB, leftPeakAgeSeconds,
/// rightLevelDB, rightPeakDB, rightPeakAgeSeconds]`. Android retains and returns
/// the complete payload on each poll so peak hold remains owned by the shared
/// Swift ballistics rather than being approximated in Kotlin.
public struct PlaybackAudioMeterWire: Equatable, Sendable {
    /// Number of `Float` values in every valid payload.
    public static let scalarCount = 6

    /// Shared-core stereo levels represented by this wire value.
    public let levels: AudioMeterLevels

    /// A silent meter state suitable for starting or restarting a polling loop.
    public static let silent = PlaybackAudioMeterWire(levels: .silent)

    /// Decodes a complete state payload, rejecting non-finite or impossible values.
    public init?(payload: [Float]) {
        guard payload.count == Self.scalarCount, payload.allSatisfy(\.isFinite) else {
            return nil
        }
        let left = AudioMeterChannel(
            levelDB: Double(payload[0]),
            peakDB: Double(payload[1]),
            peakAge: Double(payload[2])
        )
        let right = AudioMeterChannel(
            levelDB: Double(payload[3]),
            peakDB: Double(payload[4]),
            peakAge: Double(payload[5])
        )
        guard Self.isValid(left), Self.isValid(right) else { return nil }
        levels = AudioMeterLevels(left: left, right: right)
    }

    /// Advances both channels through the shared dBFS conversion and ballistics policy.
    ///
    /// Invalid prior state restarts from silence. Non-finite input peaks are treated as
    /// silence, and a non-finite delta is treated as zero elapsed time, so malformed JNI
    /// input can never poison the retained meter state.
    public static func advance(
        previousPayload: [Float],
        leftPeakLinear: Float,
        rightPeakLinear: Float,
        deltaTimeSeconds: Float
    ) -> PlaybackAudioMeterWire {
        let previous = PlaybackAudioMeterWire(payload: previousPayload) ?? .silent
        let dt = deltaTimeSeconds.isFinite ? max(0, Double(deltaTimeSeconds)) : 0
        let leftPeak = leftPeakLinear.isFinite ? Double(leftPeakLinear) : 0
        let rightPeak = rightPeakLinear.isFinite ? Double(rightPeakLinear) : 0
        return PlaybackAudioMeterWire(
            levels: AudioMeterLevels(
                left: AudioMeterBallistics.step(
                    previous.levels.left, peakLinear: leftPeak, dt: dt),
                right: AudioMeterBallistics.step(
                    previous.levels.right, peakLinear: rightPeak, dt: dt)
            )
        )
    }

    /// Encodes presentation values plus peak ages for the next Android poll.
    public var payload: [Float] {
        [
            Float(levels.left.levelDB),
            Float(levels.left.peakDB),
            Float(levels.left.peakAge),
            Float(levels.right.levelDB),
            Float(levels.right.peakDB),
            Float(levels.right.peakAge),
        ]
    }

    private init(levels: AudioMeterLevels) {
        self.levels = levels
    }

    private static func isValid(_ channel: AudioMeterChannel) -> Bool {
        channel.levelDB >= AudioMeterBallistics.floorDB
            && channel.levelDB <= 0
            && channel.peakDB >= channel.levelDB
            && channel.peakDB <= 0
            && channel.peakAge >= 0
    }
}

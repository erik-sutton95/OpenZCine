import Foundation

/// One channel of a broadcast-style dBFS bar meter: the decaying level bar plus its peak-hold
/// marker. Values are dBFS clamped to `AudioMeterBallistics.floorDB`…0.
public struct AudioMeterChannel: Equatable, Sendable {
    /// Bar level in dBFS.
    public var levelDB: Double
    /// Peak-hold marker in dBFS (never reads below `levelDB`).
    public var peakDB: Double
    /// Seconds the current peak marker has been held — drives the hold-then-decay release.
    public var peakAge: Double

    public init(
        levelDB: Double = AudioMeterBallistics.floorDB,
        peakDB: Double = AudioMeterBallistics.floorDB,
        peakAge: Double = 0
    ) {
        self.levelDB = levelDB
        self.peakDB = peakDB
        self.peakAge = peakAge
    }

    public static let silent = AudioMeterChannel()
}

/// Stereo readout published to the playback audio-levels panel.
public struct AudioMeterLevels: Equatable, Sendable {
    public var left: AudioMeterChannel
    public var right: AudioMeterChannel

    public init(left: AudioMeterChannel, right: AudioMeterChannel) {
        self.left = left
        self.right = right
    }

    public static let silent = AudioMeterLevels(left: .silent, right: .silent)
}

extension AudioMeterLevels {
    /// Maps the camera's 15-segment live-view sound indicator onto the meter's dBFS scale so the
    /// live monitor renders through the same panel as playback: segment 0 sits at the meter floor
    /// (silence), segment 14 at 0 dBFS, spaced evenly in dB between. `[ZR · verify-on-HW]` — the
    /// spec gives no per-segment dB values, so even spacing is an assumption to check against the
    /// body's own meter. The camera applies its own ballistics and peak hold, so its values feed
    /// the panel directly with no local decay.
    public init(cameraIndicator sound: PTPLiveViewSoundIndicator) {
        func decibels(_ segment: Int) -> Double {
            let fraction =
                Double(min(max(segment, 0), PTPLiveViewSoundIndicator.maxSegment))
                / Double(PTPLiveViewSoundIndicator.maxSegment)
            return AudioMeterBallistics.floorDB * (1 - fraction)
        }
        self.init(
            left: AudioMeterChannel(
                levelDB: decibels(sound.currentLeft), peakDB: decibels(sound.peakLeft)),
            right: AudioMeterChannel(
                levelDB: decibels(sound.currentRight), peakDB: decibels(sound.peakRight)))
    }
}

/// dBFS conversion and meter ballistics (instant attack, timed decay, peak hold) for the playback
/// audio meters. Pure — the shell's audio tap supplies linear frame peaks and a wall-clock `dt`.
public enum AudioMeterBallistics {
    /// Meter floor — anything quieter renders as silence.
    public static let floorDB = -60.0
    /// Bar fall rate once the signal drops (dB per second) — fast but readable, PPM-style.
    public static let levelDecayPerSecond = 26.0
    /// How long a peak marker holds before it starts to fall.
    public static let peakHoldSeconds = 1.8
    /// Peak-marker fall rate once the hold expires (dB per second).
    public static let peakDecayPerSecond = 12.0

    /// Linear amplitude (0…1) → dBFS, clamped to `floorDB`…0.
    public static func decibels(fromLinear amplitude: Double) -> Double {
        guard amplitude > 0 else { return floorDB }
        return max(floorDB, min(0, 20 * log10(amplitude)))
    }

    /// Advances one channel by `dt` seconds, given the loudest linear sample amplitude observed
    /// since the previous step. The bar attacks instantly and decays at `levelDecayPerSecond`; the
    /// peak marker grabs new maxima, holds `peakHoldSeconds`, then falls at `peakDecayPerSecond`.
    public static func step(
        _ channel: AudioMeterChannel, peakLinear: Double, dt: Double
    ) -> AudioMeterChannel {
        let dt = max(0, dt)
        let incoming = decibels(fromLinear: peakLinear)
        var next = channel
        let decayed = max(floorDB, channel.levelDB - levelDecayPerSecond * dt)
        next.levelDB = max(incoming, decayed)
        if incoming >= channel.peakDB {
            next.peakDB = incoming
            next.peakAge = 0
        } else {
            next.peakAge = channel.peakAge + dt
            if next.peakAge > peakHoldSeconds {
                next.peakDB = max(floorDB, channel.peakDB - peakDecayPerSecond * dt)
            }
        }
        next.peakDB = max(next.peakDB, next.levelDB)
        return next
    }
}

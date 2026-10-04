import OpenCineMedia

/// Shared portable meter channel, retaining the app's source-compatible name.
public typealias AudioMeterChannel = MonitorAudioMeterChannel

/// Shared stereo readout. Missing source observations stay optional in playback.
public typealias AudioMeterLevels = MonitorAudioMeterLevels

/// Shared dBFS conversion and peak-hold policy used by both native playback adapters.
public typealias AudioMeterBallistics = MonitorAudioMeterBallistics

extension AudioMeterLevels {
    /// Maps the camera's 15-segment live-view sound indicator onto the meter's dBFS scale so the
    /// live monitor renders through the same panel as playback: segment 0 sits at the meter floor
    /// (silence), segment 14 at 0 dBFS, spaced evenly in dB between. `[ZR · verify-on-HW]` — the
    /// spec gives no per-segment dB values, so even spacing is an assumption to check against the
    /// body's own meter. The camera applies its own ballistics and peak hold, so its values feed
    /// the panel directly with no local decay.
    public init(cameraIndicator sound: PTPLiveViewSoundIndicator) {
        func decibels(_ segment: Int) -> Double {
            PTPLiveViewSoundIndicator.decibels(
                segment: segment, floorDB: AudioMeterBallistics.floorDB)
        }
        self.init(
            left: AudioMeterChannel(
                levelDB: decibels(sound.currentLeft), peakDB: decibels(sound.peakLeft)),
            right: AudioMeterChannel(
                levelDB: decibels(sound.currentRight), peakDB: decibels(sound.peakRight)))
    }
}

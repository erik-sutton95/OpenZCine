// The shared meter types, re-exported so the Runner, the Watch app and the Android JNI facade
// keep importing OpenZCineCore only.
@_exported import enum OpenCineMedia.MonitorAudioMeterBallistics
@_exported import struct OpenCineMedia.MonitorAudioMeterChannel
@_exported import struct OpenCineMedia.MonitorAudioMeterLevels

extension MonitorAudioMeterLevels {
    /// Maps the camera's 15-segment live-view sound indicator onto the meter's dBFS scale so the
    /// live monitor renders through the same panel as playback: segment 0 sits at the meter floor
    /// (silence), segment 14 at 0 dBFS, spaced evenly in dB between. `[ZR · verify-on-HW]` — the
    /// spec gives no per-segment dB values, so even spacing is an assumption to check against the
    /// body's own meter. The camera applies its own ballistics and peak hold, so its values feed
    /// the panel directly with no local decay.
    public init(cameraIndicator sound: PTPLiveViewSoundIndicator) {
        func decibels(_ segment: Int) -> Double {
            PTPLiveViewSoundIndicator.decibels(
                segment: segment, floorDB: MonitorAudioMeterBallistics.floorDB)
        }
        self.init(
            left: MonitorAudioMeterChannel(
                levelDB: decibels(sound.currentLeft), peakDB: decibels(sound.peakLeft)),
            right: MonitorAudioMeterChannel(
                levelDB: decibels(sound.currentRight), peakDB: decibels(sound.peakRight)))
    }
}

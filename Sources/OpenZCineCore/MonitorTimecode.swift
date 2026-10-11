import MonitorPresentation

extension Timecode {
    /// Shared monitor readout from enabled camera-header telemetry, including genuine frames.
    /// The header reports no drop-frame mode; none is inferred from the recording format.
    public var monitorLabel: String? {
        guard on else { return nil }
        return MonitorTimecodeFormat.label(
            hours: hour, minutes: minute, seconds: second, frames: frame)
    }
}

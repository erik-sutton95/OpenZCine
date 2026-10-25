import MonitorPresentation
import OpenCineMedia

/// The photo SHOTS pill's storage side. Android: `MonitorScreen` (the photo SHOTS pill).
public enum LiveMediaReadout {
    /// Free space and percentage (`521GB 47%`), never a recording time, in the one live storage
    /// precision (`StorageReadoutCycle`). Without a capacity only the free space.
    public static func photoStorage(_ readout: StorageReadout?) -> String {
        guard let readout else { return StorageReadout.unavailable }
        return StorageReadoutCycle.forms(
            freeBytes: readout.freeBytes, percent: readout.percent, recordingTime: nil, photo: true
        ).joined(separator: " ")
    }
}

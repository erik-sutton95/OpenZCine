import MonitorPresentation
import OpenCineMedia

/// The local camera's live storage label: the MEDIA cell, and the storage side of the photo
/// SHOTS pill. Android: `MonitorScreen` (`mediaLabel`, the photo SHOTS pill).
public enum LiveMediaReadout {
    /// `recordingTime` is the volume's estimated remaining time; `prefersDuration` is the MEDIA
    /// cell's tap preference. Photo has no recording time: the SHOTS pill's storage side reads
    /// the free space and its percentage, as on Android.
    public static func label(_ readout: StorageReadout?, recordingTime: String?, portrait: Bool,
        prefersDuration: Bool, photo: Bool) -> String {
        if prefersDuration && !photo { return recordingTime ?? "-- Min" }
        guard let readout else { return StorageReadout.unavailable }
        // Portrait keeps a complete, compact label: the nearest whole unit, never a fraction.
        let free = portrait ? MonitorStorageReadoutFormat.wholeUnitCapacity(bytes: readout.freeBytes) : readout.free
        guard photo, let percent = readout.percent else { return free }
        return "\(free) \(percent)"
    }
}

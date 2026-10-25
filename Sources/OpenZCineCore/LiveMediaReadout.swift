import MonitorPresentation
import OpenCineMedia

/// The local camera's live storage label: the MEDIA cell, and the storage side of the photo
/// SHOTS pill. Android: `MonitorScreen` (`mediaLabel`, the photo SHOTS pill).
public enum LiveMediaReadout {
    /// `recordingTime` is the volume's estimated remaining time; `prefersDuration` is the MEDIA
    /// cell's tap preference. Photo has no recording time: the SHOTS pill's storage side reads
    /// the free space and its percentage, as on Android.
    public static func label(
        _ readout: StorageReadout?, recordingTime: String?, portrait: Bool,
        prefersDuration: Bool, photo: Bool
    ) -> String {
        if prefersDuration && !photo { return recordingTime ?? "-- Min" }
        guard let readout else { return StorageReadout.unavailable }
        // Portrait keeps a complete, compact label: the nearest whole unit, never a fraction.
        let free =
            portrait
            ? MonitorStorageReadoutFormat.wholeUnitCapacity(bytes: readout.freeBytes) : readout.free
        guard photo, let percent = readout.percent else { return free }
        return "\(free) \(percent)"
    }

    /// The forms one tap on the video MEDIA cell steps through, as on the shared live surface in
    /// Pocket and Insta (A5-11): the free space, its percentage when the card reports a
    /// capacity, then the estimated recording time when one is known. Android:
    /// `liveMediaForms` (`MonitorReadouts`).
    public static func videoForms(free: String, percent: String?, recordingTime: String?)
        -> [String]
    {
        [free]
            + MonitorStorageReadoutFormat.alternatives(
                percent: percent, recordingTime: recordingTime, photo: false)
    }

    /// The local camera's video forms from the common storage readout.
    public static func videoForms(
        _ readout: StorageReadout?, recordingTime: String?, portrait: Bool
    ) -> [String] {
        let free =
            readout.map {
                portrait
                    ? MonitorStorageReadoutFormat.wholeUnitCapacity(bytes: $0.freeBytes) : $0.free
            } ?? StorageReadout.unavailable
        return videoForms(free: free, percent: readout?.percent, recordingTime: recordingTime)
    }
}

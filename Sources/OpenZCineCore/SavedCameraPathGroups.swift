import Foundation

/// Groups per-path records of the SAME physical body for presentation.
///
/// A saved record is one PATH to a camera — hotspot, router and cable are separate records
/// with separate hosts, which is what made one body show up as several rows. The camera itself
/// is identified by the body serial stamped at connect, so grouping keys on that and nothing
/// else: names cannot be trusted (#293's two bodies on one address), and hosts are exactly
/// what differs between paths. Grouping is presentation-only — records stay per-path on disk,
/// nothing migrates, and a record that predates the serial stamp stays a singleton row until
/// its next connect stamps it into its group.
public enum SavedCameraPathGroups {
    /// Same-camera groups, each ordered most-recently-seen first. Group order follows the
    /// input order of each group's first-seen record, so the list stays stable.
    public static func group(_ records: [PTPIPSavedCameraRecord]) -> [[PTPIPSavedCameraRecord]] {
        var groups: [[PTPIPSavedCameraRecord]] = []
        var indexBySerial: [String: Int] = [:]
        for record in records {
            let serial =
                record.serialNumber?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !serial.isEmpty else {
                groups.append([record])
                continue
            }
            if let index = indexBySerial[serial] {
                groups[index].append(record)
            } else {
                indexBySerial[serial] = groups.count
                groups.append([record])
            }
        }
        return groups.map { group in
            group.sorted { ($0.lastSeenAt ?? .distantPast) > ($1.lastSeenAt ?? .distantPast) }
        }
    }

    /// The path whose record drives the group's row: a connected path beats a discovered one,
    /// a discovered one beats an offline one, and ties go to the most recently seen (the
    /// group's own order).
    public static func activePath(
        in group: [PTPIPSavedCameraRecord],
        availability: (PTPIPSavedCameraRecord) -> SavedCameraAvailability
    ) -> PTPIPSavedCameraRecord? {
        group.first {
            if case .connected = availability($0) { return true }
            return false
        }
            ?? group.first {
                if case .available = availability($0) { return true }
                return false
            }
            ?? group.first
    }

    /// The short label a path chip wears — the declared path's own name. The inference chain
    /// this replaced (USB label/host shape → hotspot subnet → evidence tri-state → "Wi-Fi")
    /// survives only for a record built without a path, which store reads never produce.
    public static func pathLabel(for record: PTPIPSavedCameraRecord) -> String {
        record.path?.displayLabel ?? "Wi-Fi"
    }

    /// The chip label for one setup, distinguished when a camera has more than one of its kind.
    ///
    /// Only routers can repeat — the access point is the camera's own network, the hotspot is this
    /// phone, the cable is the cable — and two chips both reading "Router" tell an operator
    /// nothing about which is the studio and which is the one in the bag.
    ///
    /// The qualifier is whatever the record is actually keyed on, so the label can never disagree
    /// with the identity: the network's name where iOS or Android would give us one, and otherwise
    /// its subnet, which needs no permission and is the thing that separates them anyway. A lone
    /// router keeps the bare word — a qualifier nothing is being distinguished FROM is just noise.
    public static func pathChipLabel(
        for record: PTPIPSavedCameraRecord,
        in group: [PTPIPSavedCameraRecord]
    ) -> String {
        let base = pathLabel(for: record)
        guard record.pathKind == .infrastructure,
            group.filter({ $0.pathKind == .infrastructure }).count > 1,
            let qualifier = networkQualifier(for: record)
        else { return base }
        return "\(base) · \(qualifier)"
    }

    /// What names this record's network to a person: its SSID, else its subnet as "192.168.1.x".
    public static func networkQualifier(for record: PTPIPSavedCameraRecord) -> String? {
        if case .infrastructure(let network?) = record.path,
            !network.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return network
        }
        return CameraDiscovery.subnetBase(for: record.host).map { "\($0).x" }
    }
}

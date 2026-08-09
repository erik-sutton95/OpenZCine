import Foundation

/// User-selected presentation metadata for a saved camera.
public struct PTPIPSavedCameraPresentation: Codable, Equatable, Sendable {
    public init(
        customName: String? = nil,
        borderColor: String? = nil,
        icon: String? = nil,
        wifiSSID: String? = nil
    ) {
        self.customName = customName
        self.borderColor = borderColor
        self.icon = icon
        self.wifiSSID = wifiSSID
    }

    /// User-defined display name. The camera-assigned name remains on the saved record.
    public var customName: String?
    /// User-selected border/accent color tag.
    public var borderColor: String?
    /// User-selected icon tag.
    public var icon: String?
    /// Camera Wi‑Fi hotspot SSID (e.g. `NIKON_ZR_01234`), used for programmatic join prompts.
    public var wifiSSID: String?
}

/// App-side metadata for a Nikon camera profile that has already been paired.
public struct PTPIPSavedCameraRecord: Codable, Equatable, Identifiable, Sendable {
    /// Saved-record transport label for USB-C tethered cameras.
    public static let usbTransportLabel = "USB-C"

    public init(
        host: String,
        displayName: String,
        transport: String,
        lastSeenAt: Date?,
        presentation: PTPIPSavedCameraPresentation? = nil,
        pairedViaCameraAccessPoint: Bool? = nil,
        serialNumber: String? = nil,
        path: CameraPath? = nil,
        streamPreset: OperatorPreferences.StreamPreset? = nil,
        qualityBias: OperatorPreferences.QualityBias? = nil,
        setupName: String? = nil
    ) {
        self.host = host
        self.displayName = displayName
        self.transport = transport
        self.lastSeenAt = lastSeenAt
        self.presentation = presentation
        self.pairedViaCameraAccessPoint = pairedViaCameraAccessPoint
        self.serialNumber = serialNumber
        self.path = path
        self.streamPreset = streamPreset
        self.qualityBias = qualityBias
        self.setupName = setupName
    }

    public var host: String  // IP address, hostname, or `usb:<device-id>` key
    public var displayName: String  // camera-assigned name
    public var transport: String  // e.g. "Wi-Fi", "USB-C"
    public var lastSeenAt: Date?
    public var presentation: PTPIPSavedCameraPresentation?
    /// LEGACY access-point evidence, superseded by `path`. Still written for downgrade safety,
    /// read only by the one-time migration that stamps `path` onto old records. The tri-state
    /// (`true`/`false`/`nil`) was the root of the transport disease: most connects cannot read
    /// the SSID, so most records carried `nil`, and every consumer guessed differently.
    public var pairedViaCameraAccessPoint: Bool?
    /// The body serial stamped at connect. Identifies the CAMERA across its path records
    /// (hotspot, router and cable are separate records with separate hosts); presentation
    /// groups on it so one body reads as one row with many paths. `nil` predates the stamp —
    /// such a record stays a singleton row and self-heals into its group on the next connect.
    public var serialNumber: String?
    /// The DECLARED path this record reaches the camera by — the record IS one camera setup,
    /// keyed by (camera, path kind). `nil` only on records that predate the field; the store
    /// migrates them on first read and the value never leaves `nil` afterwards.
    public var path: CameraPath?
    /// What the camera is asked to SEND on this setup, chosen by the operator while connected to
    /// it. `nil` means never chosen here, which is not the same as a value — see
    /// ``SetupStreamSettings``. Per setup rather than per app because the constraint they answer
    /// to belongs to the path: the camera's own access point is a different link from a cable,
    /// and one global key meant a bias dropped for the AP followed the operator onto USB-C.
    public var streamPreset: OperatorPreferences.StreamPreset?
    /// The operator's own name for THIS setup — "Studio", "Van", "Mum's house".
    ///
    /// Distinct from `presentation.customName`, which names the CAMERA and titles its whole row:
    /// naming one of a body's setups must not rename the body. `nil` falls back to the generated
    /// label, which is what most setups will wear forever.
    public var setupName: String?
    /// The compression grade this setup runs at; `nil` means never chosen here. See
    /// ``streamPreset``.
    public var qualityBias: OperatorPreferences.QualityBias?

    /// This record's row key beside identity: at most one setup per kind and camera.
    public var pathKind: CameraPath.Kind? { path?.kind }

    /// User-facing title, preferring a custom name when one exists.
    public var displayTitle: String {
        if let customName = presentation?.customName?.trimmingCharacters(
            in: .whitespacesAndNewlines),
            !customName.isEmpty
        {
            return customName
        }
        return displayName
    }

    /// Host plus name plus path kind: two bodies legitimately share an address (every camera-AP
    /// AP and router setups can share an address), so any narrower id
    /// gave SwiftUI duplicate identities the moment both were saved.
    public var id: String {
        // The network joins the key for the same reason it joins `describesSameSetup`: two router
        // setups of one camera are two rows, and two rows answering to one id collide in the card
        // list and in reconnect targeting.
        var id = host + "|" + displayName.lowercased() + "|" + (path?.kind.rawValue ?? "")
        if case .infrastructure(let network) = path {
            // Whatever `describesSameSetup` separates on has to reach the id, or two rows it
            // keeps apart end up sharing an identity in the card list and in reconnect targeting.
            id += "|" + (network?.lowercased() ?? CameraDiscovery.subnetBase(for: host) ?? "")
        }
        return id
    }

    /// Whether this camera was saved from a USB-C tethered pairing. USB records carry a
    /// `usb:<device-id>` host key, so network availability checks do not apply to them.
    public var isUSBTransport: Bool {
        if let path { return path.kind == .usbC }
        return Self.isUSBTransportLabel(transport)
            || host.hasPrefix(DiscoveredCamera.usbHostKeyPrefix)
    }

    public static func isUSBTransportLabel(_ transport: String) -> Bool {
        transport.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(usbTransportLabel) == .orderedSame
    }
}

/// Canonicalizes and updates saved camera profile records.
///
/// A record IS one camera setup: (camera identity, declared path kind) is the row key. There is
/// no cross-kind merging and no topology inference here — the one place inference survives is
/// `typed(_:)`, the one-time migration of records that predate the `path` field.
public enum PTPIPSavedCameraRecords {
    public static func canonicalized(_ records: [PTPIPSavedCameraRecord])
        -> [PTPIPSavedCameraRecord]
    {
        var output: [PTPIPSavedCameraRecord] = []
        for record in records.flatMap(typed) {
            guard let normalized = normalizedRecord(record) else { continue }
            if let index = output.firstIndex(where: { describesSameSetup($0, normalized) }) {
                output[index] = preferredRecord(existing: output[index], candidate: normalized)
            } else {
                output.append(normalized)
            }
        }
        return output
    }

    /// One-time typing of a record that predates the declared path — THE residence of topology
    /// inference, and its retirement home. Everything downstream reads `path`.
    ///
    /// The AP-proven case may split: a historically merged record could carry a router host under
    /// an access-point stamp (the merge rules once allowed it), and that one poisoned record is
    /// the recurring "join NIKON_…" prompt on router connects. The split gives each path its own
    /// row. The AP half does **not** invent a fixed IP — camera AP addresses vary; connect after
    /// join rediscovers on the live link. The foreign host becomes the infrastructure setup.
    public static func typed(_ record: PTPIPSavedCameraRecord) -> [PTPIPSavedCameraRecord] {
        if let path = record.path {
            // A DECLARED path is authoritative — with one exception: an access-point stamp on a
            // dialable host that was never re-learned on the camera's own network still poisons
            // reconnect (dials a house/router address while believing it is already the AP setup).
            // Split that into a rediscovery-backed AP row plus an infrastructure row for the host.
            guard case .cameraAccessPoint = path,
                CameraDiscovery.isDialableHost(record.host)
            else { return [record] }
            // A real IPv4 on an AP setup is fine when it is simply the last learned address on
            // that path — only untyped migration still needs the poison split below. Typed AP
            // rows keep their learned host; connect-after-join rediscovers when the host is stale.
            return [record]
        }
        var typedRecord = record
        if record.isUSBTransport {
            typedRecord.path = .usbC
            return [typedRecord]
        }
        if CameraStartupPolicy.usesIPhoneHotspot(host: record.host, transport: record.transport) {
            typedRecord.path = .phoneHotspot
            return [typedRecord]
        }
        guard record.pairedViaCameraAccessPoint == true else {
            typedRecord.path = .infrastructure(networkName: nil)
            return [typedRecord]
        }
        return splittingAccessPoint(record)
    }

    /// Migration helper: stamp an access-point path without inventing a global camera-AP IP.
    /// The learned host (if any) is kept; connect after join rediscovers when it is stale.
    private static func splittingAccessPoint(_ record: PTPIPSavedCameraRecord)
        -> [PTPIPSavedCameraRecord]
    {
        let ssid =
            record.path?.accessPointSSID
            ?? record.presentation?.wifiSSID
            ?? CameraWiFiSSID.deriveSSID(fromCameraName: record.displayName)
        var accessPoint = record
        accessPoint.pairedViaCameraAccessPoint = true
        accessPoint.path = .cameraAccessPoint(ssid: ssid)
        return [accessPoint]
    }

    public static func upserting(
        host rawHost: String,
        displayName rawDisplayName: String,
        transport rawTransport: String,
        lastSeenAt: Date?,
        pairedViaCameraAccessPoint: Bool? = nil,
        serialNumber: String? = nil,
        path: CameraPath? = nil,
        into records: [PTPIPSavedCameraRecord]
    ) -> [PTPIPSavedCameraRecord] {
        guard let host = PTPIPPairedHosts.normalizedHost(rawHost) else {
            return canonicalized(records)
        }
        let updated = PTPIPSavedCameraRecord(
            host: host,
            displayName: normalizedDisplayName(rawDisplayName, host: host),
            transport: normalizedTransport(rawTransport),
            lastSeenAt: lastSeenAt,
            pairedViaCameraAccessPoint: pairedViaCameraAccessPoint,
            serialNumber: normalizedOptionalTag(serialNumber),
            path: path
        )
        return canonicalized(records + [updated])
    }

    public static func updatingWiFiSSID(
        host rawHost: String,
        wifiSSID: String?,
        in records: [PTPIPSavedCameraRecord]
    ) -> [PTPIPSavedCameraRecord] {
        guard let host = PTPIPPairedHosts.normalizedHost(rawHost) else {
            return canonicalized(records)
        }
        let normalizedSSID = normalizedOptionalTag(wifiSSID)
        return canonicalized(records).map { record in
            guard record.host == host else { return record }
            var updated = record
            let existing = record.presentation
            updated.presentation = normalizedPresentation(
                PTPIPSavedCameraPresentation(
                    customName: existing?.customName,
                    borderColor: existing?.borderColor,
                    icon: existing?.icon,
                    wifiSSID: normalizedSSID
                )
            )
            return updated
        }
    }

    public static func updatingPresentation(
        host rawHost: String,
        customName: String?,
        borderColor: String?,
        icon: String?,
        in records: [PTPIPSavedCameraRecord]
    ) -> [PTPIPSavedCameraRecord] {
        guard let host = PTPIPPairedHosts.normalizedHost(rawHost) else {
            return canonicalized(records)
        }
        return canonicalized(records).map { record in
            guard record.host == host else { return record }
            var updated = record
            updated.presentation = normalizedPresentation(
                PTPIPSavedCameraPresentation(
                    customName: customName,
                    borderColor: borderColor,
                    icon: icon,
                    wifiSSID: record.presentation?.wifiSSID
                )
            )
            return updated
        }
    }

    /// Records the stream settings an operator chose while connected to ONE setup.
    ///
    /// Keyed by (host, path kind), never host alone: one body's access-point and router setups
    /// legitimately share an address, and so do two camera-AP Nikons (all of them answer on
    /// address). Matching on the host would write the cable's choice onto the AP's record —
    /// which is the class of bug the declared path exists to end.
    ///
    /// A `nil` argument leaves that setting untouched rather than clearing it, so a caller that
    /// knows only one of the two does not have to read the other back first.
    public static func updatingStreamSettings(
        host rawHost: String,
        pathKind: CameraPath.Kind?,
        streamPreset: OperatorPreferences.StreamPreset?,
        qualityBias: OperatorPreferences.QualityBias?,
        in records: [PTPIPSavedCameraRecord]
    ) -> [PTPIPSavedCameraRecord] {
        guard let host = PTPIPPairedHosts.normalizedHost(rawHost) else {
            return canonicalized(records)
        }
        return canonicalized(records).map { record in
            guard record.host == host, record.pathKind == pathKind else { return record }
            var updated = record
            if let streamPreset { updated.streamPreset = streamPreset }
            if let qualityBias { updated.qualityBias = qualityBias }
            return updated
        }
    }

    /// Names one setup, keyed by (host, path kind) like the stream settings — a body's setups
    /// share a camera, and renaming the studio router must not rename the one in the van.
    /// A blank name clears back to the generated label.
    public static func updatingSetupName(
        host rawHost: String,
        pathKind: CameraPath.Kind?,
        setupName: String?,
        in records: [PTPIPSavedCameraRecord]
    ) -> [PTPIPSavedCameraRecord] {
        guard let host = PTPIPPairedHosts.normalizedHost(rawHost) else {
            return canonicalized(records)
        }
        return canonicalized(records).map { record in
            guard record.host == host, record.pathKind == pathKind else { return record }
            var updated = record
            updated.setupName = normalizedOptionalTag(setupName)
            return updated
        }
    }

    public static func removing(
        _ rawHost: String,
        displayName: String? = nil,
        from records: [PTPIPSavedCameraRecord]
    ) -> [PTPIPSavedCameraRecord] {
        guard let host = PTPIPPairedHosts.normalizedHost(rawHost) else {
            return canonicalized(records)
        }
        return canonicalized(records).filter { record in
            guard record.host == host else { return true }
            // With two bodies legitimately sharing an address (camera-AP), the name narrows the
            // removal to the one the operator forgot — else forgetting one deletes both.
            guard let displayName, !displayName.isEmpty else { return false }
            return !namesCompatible(record.displayName, displayName)
        }
    }

    private static func normalizedDisplayName(_ displayName: String, host: String) -> String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Camera \(host)" : trimmed
    }

    private static func normalizedTransport(_ transport: String) -> String {
        let trimmed = transport.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Wi-Fi" : trimmed
    }

    private static func normalizedRecord(_ record: PTPIPSavedCameraRecord)
        -> PTPIPSavedCameraRecord?
    {
        guard let host = PTPIPPairedHosts.normalizedHost(record.host) else { return nil }
        return PTPIPSavedCameraRecord(
            host: host,
            displayName: normalizedDisplayName(record.displayName, host: host),
            transport: normalizedTransport(record.transport),
            lastSeenAt: record.lastSeenAt,
            presentation: normalizedPresentation(record.presentation),
            pairedViaCameraAccessPoint: record.pairedViaCameraAccessPoint,
            serialNumber: record.serialNumber,
            path: record.path,
            // Carried, not normalized: there is nothing to normalize about an enum, and this
            // rebuild runs on every read. A field missing from here is a field the store quietly
            // erases the next time anything touches the list.
            streamPreset: record.streamPreset,
            qualityBias: record.qualityBias,
            setupName: normalizedOptionalTag(record.setupName)
        )
    }

    /// Whether two typed records are the same setup — the same camera reached by the same KIND
    /// of path. This replaced `recordsDescribeSameCamera` + `pathKindsCompatible` + the
    /// evidence gate: with the path declared, "may these merge?" stops being a heuristic.
    private static func describesSameSetup(
        _ lhs: PTPIPSavedCameraRecord,
        _ rhs: PTPIPSavedCameraRecord
    ) -> Bool {
        // Kind first: one camera's AP and router setups are two rows FOREVER — the historical
        // cross-kind swallow is what poisoned multi-path records. (Both-nil only occurs on
        // records built directly in tests; `canonicalized` types everything first.)
        guard lhs.path?.kind == rhs.path?.kind else { return false }
        // Within infrastructure the NETWORK is part of the key: one camera reached from a home
        // router and from a portable one is two setups, not one that keeps changing address.
        //
        // Two things can name a network, and they are consulted in that ORDER — the same order
        // `id` above resolves them in, which is not a coincidence: a row key and the matcher that
        // decides which rows exist have to be the same function, or rows kept apart collide in the
        // card list. They were not, and this is where they disagreed.
        //
        // The NAME first, when we have one for both. A named network is ONE network however many
        // subnets its leases land on — a mesh with a VLAN per band, or a 6 GHz radio on its own
        // segment, is still the operator's one Wi-Fi. Insisting on the subnet on top of the name
        // forked a second Wi-Fi row for a camera they added once, and then a third.
        //
        // The SUBNET when either is unnamed, which is most of the time: the SSID is ideal and
        // `NEHotspotNetwork.fetchCurrent` only returns a network THIS APP configured — so a
        // camera's own access point is readable and somebody's router never is, precisely
        // backwards for this. The subnet needs no permission and is the right shape besides. A
        // different router is a different subnet in practice (192.168.1.x at home, 192.168.129.x
        // on a portable), while a lease moving within one router stays inside its own.
        //
        // Both rules can be fooled, and both are wrong in the same direction on purpose: two
        // routers sharing an SSID merge, and so do two that both hand out 192.168.1.x. That is
        // genuinely ambiguous, and merging is the recoverable answer — a spare row the operator
        // never made is the one they cannot explain.
        if case .infrastructure(let lhsNetwork) = lhs.path,
            case .infrastructure(let rhsNetwork) = rhs.path
        {
            if let lhsNetwork, let rhsNetwork {
                if lhsNetwork != rhsNetwork { return false }
            } else if CameraDiscovery.subnetBase(for: lhs.host)
                != CameraDiscovery.subnetBase(for: rhs.host)
            {
                return false
            }
        }
        // A shared address only means "same camera" when the names don't contradict it. Every
        // two bodies can share an address, so a bare host match let a newly paired second body
        // swallow the first one's record (#293); DHCP reuse does the same on a router. Two
        // non-empty, different names on one address are two different bodies.
        if lhs.host == rhs.host {
            return namesCompatible(lhs.displayName, rhs.displayName)
        }
        // Two stamped serials that differ are two bodies regardless of the name (#293's
        // lineage). The cross-host merge below absorbs a DHCP move within one kind.
        if let lhsSerial = lhs.serialNumber, let rhsSerial = rhs.serialNumber,
            !lhsSerial.isEmpty, !rhsSerial.isEmpty, lhsSerial != rhsSerial
        {
            return false
        }
        return cameraNamesMatch(savedName: lhs.displayName, discoveredName: rhs.displayName)
    }

    /// Whether two display names could describe one body. Uses the same normalization as
    /// `cameraNamesMatch`: a generic or placeholder name carries no identity, so it contradicts
    /// nothing — only two *assigned* names that differ prove two different bodies.
    private static func namesCompatible(_ lhs: String, _ rhs: String) -> Bool {
        guard let left = normalizedAssignedCameraName(lhs),
            let right = normalizedAssignedCameraName(rhs)
        else { return true }
        return left == right
    }

    private static func preferredRecord(
        existing: PTPIPSavedCameraRecord,
        candidate: PTPIPSavedCameraRecord
    ) -> PTPIPSavedCameraRecord {
        let preferred: PTPIPSavedCameraRecord
        let fallback: PTPIPSavedCameraRecord
        switch (existing.lastSeenAt, candidate.lastSeenAt) {
        case (let existingSeen?, let candidateSeen?):
            (preferred, fallback) =
                candidateSeen >= existingSeen
                ? (candidate, existing) : (existing, candidate)
        case (nil, _?):
            (preferred, fallback) = (candidate, existing)
        case (_?, nil):
            (preferred, fallback) = (existing, candidate)
        case (nil, nil):
            (preferred, fallback) = (candidate, existing)
        }
        var merged = preferred
        // An update that carries no access-point evidence must never erase evidence a previous
        // connection recorded — a reconnect upsert usually knows nothing about the topology.
        if merged.pairedViaCameraAccessPoint == nil {
            merged.pairedViaCameraAccessPoint = fallback.pairedViaCameraAccessPoint
        }
        // Same-kind merges keep the richer payload: an SSID or network name learned once must
        // not be erased by a later upsert that happens not to know it.
        switch (merged.path, fallback.path) {
        case (.cameraAccessPoint(nil)?, .cameraAccessPoint(let ssid?)?):
            merged.path = .cameraAccessPoint(ssid: ssid)
        case (.infrastructure(nil)?, .infrastructure(let network?)?):
            merged.path = .infrastructure(networkName: network)
        case (nil, let fallbackPath?):
            merged.path = fallbackPath
        default:
            break
        }
        if merged.serialNumber == nil {
            merged.serialNumber = fallback.serialNumber
        }
        // Same rule as the evidence above, and it is load-bearing here: every reconnect upserts a
        // record that knows nothing about stream settings, so without this the operator's choice
        // for this setup would survive exactly until the next time they connected to it.
        if merged.streamPreset == nil {
            merged.streamPreset = fallback.streamPreset
        }
        if merged.qualityBias == nil {
            merged.qualityBias = fallback.qualityBias
        }
        if merged.setupName == nil {
            merged.setupName = fallback.setupName
        }
        if merged.presentation == nil {
            merged.presentation = fallback.presentation
        } else if let fallbackPresentation = fallback.presentation,
            merged.presentation?.wifiSSID == nil,
            fallbackPresentation.wifiSSID != nil
        {
            merged.presentation = normalizedPresentation(
                PTPIPSavedCameraPresentation(
                    customName: merged.presentation?.customName,
                    borderColor: merged.presentation?.borderColor,
                    icon: merged.presentation?.icon,
                    wifiSSID: fallbackPresentation.wifiSSID
                )
            )
        }
        return merged
    }

    fileprivate static func cameraNamesMatch(savedName: String, discoveredName: String) -> Bool {
        guard let savedName = normalizedAssignedCameraName(savedName),
            let discoveredName = normalizedAssignedCameraName(discoveredName)
        else {
            return false
        }
        return savedName == discoveredName
    }

    private static func normalizedAssignedCameraName(_ rawName: String) -> String? {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let foldedName = name.lowercased()
        guard name.localizedCaseInsensitiveCompare("PTP-IP Camera") != .orderedSame else {
            return nil
        }
        guard
            ![
                "camera",
                "nikon camera",
                "nikon zr",
                "nikon corporation zr",
            ].contains(foldedName)
        else {
            return nil
        }
        guard
            name.range(
                of: "Camera ", options: [.anchored, .caseInsensitive, .diacriticInsensitive])
                == nil
        else {
            return nil
        }
        return foldedName
    }

    private static func normalizedPresentation(
        _ presentation: PTPIPSavedCameraPresentation?
    ) -> PTPIPSavedCameraPresentation? {
        guard let presentation else { return nil }
        let customName = normalizedOptionalTag(presentation.customName)
        let borderColor = normalizedOptionalTag(presentation.borderColor)
        let icon = normalizedOptionalTag(presentation.icon)
        let wifiSSID = normalizedOptionalTag(presentation.wifiSSID)
        guard customName != nil || borderColor != nil || icon != nil || wifiSSID != nil else {
            return nil
        }
        return PTPIPSavedCameraPresentation(
            customName: customName,
            borderColor: borderColor,
            icon: icon,
            wifiSSID: wifiSSID
        )
    }

    private static func normalizedOptionalTag(_ rawValue: String?) -> String? {
        let trimmed = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

public enum SavedCameraAvailability: Equatable, Sendable {
    case offline
    case available(DiscoveredCamera)
    case connected
}

public enum SavedCameraAvailabilityPolicy {
    public static func resolve(
        camera: PTPIPSavedCameraRecord,
        discoveredCameras: [DiscoveredCamera],
        connectedHost rawConnectedHost: String?,
        onCameraAccessPoint: Bool = false,
        hotspotSubnetBases: [String] = []
    ) -> SavedCameraAvailability {
        guard let host = PTPIPPairedHosts.normalizedHost(camera.host) else {
            return .offline
        }
        // An AP setup is reachable ONLY from the camera's own network (SSID proof). Without
        // that, something answering at a learned AP host on house Wi‑Fi is not the AP path.
        if camera.path?.kind == .cameraAccessPoint, !onCameraAccessPoint {
            return .offline
        }
        if PTPIPPairedHosts.normalizedHost(rawConnectedHost ?? "") == host {
            return .connected
        }
        if let discovered = discoveredCameras.first(where: { candidate in
            // Exact host match for dialable IPs and virtual keys (usb:…).
            if PTPIPPairedHosts.normalizedHost(candidate.ip) == host {
                return true
            }
            guard
                PTPIPSavedCameraRecords.cameraNamesMatch(
                    savedName: camera.displayName,
                    discoveredName: candidate.displayName
                )
            else { return false }
            // Name-match only for DHCP moves on the SAME network shape as this setup.
            let viaHotspot = CameraStartupPolicy.usesIPhoneHotspot(
                host: candidate.ip,
                transport: "",
                hotspotSubnetBases: hotspotSubnetBases)
            switch camera.path?.kind {
            case .phoneHotspot:
                return viaHotspot
            case .infrastructure:
                return !viaHotspot && !onCameraAccessPoint
            case .cameraAccessPoint:
                // On the camera AP, any name-matched discovery is the body (hosts vary; no
                // universal AP IP). Off the AP this function already returned offline above.
                return onCameraAccessPoint
            case .usbC, .hdmiCapture, nil:
                return true
            }
        }) {
            return .available(discovered)
        }
        return .offline
    }
}

public enum CameraStartupDestination: Equatable, Sendable {
    case addCamera
    case savedCameras
}

public enum CameraStartupRecoveryPrompt: Equatable, Sendable {
    case none
    case enableIPhoneHotspot(PTPIPSavedCameraRecord)
    case waitForIPhoneHotspotCamera(PTPIPSavedCameraRecord)
}

public enum CameraConnectionStrategy: Equatable, Sendable {
    case savedProfile
    case firstTimePairing
    case restoreCameraProfileBeforePairing
}

public enum CameraStartupPolicy {
    public static func launchDestination(savedCameras: [PTPIPSavedCameraRecord])
        -> CameraStartupDestination
    {
        PTPIPSavedCameraRecords.canonicalized(savedCameras).isEmpty ? .addCamera : .savedCameras
    }

    /// Returns cameras that have not already been saved by this app.
    ///
    /// When `allowSavedCameraRecovery` is true and discovery found no new cameras, the discovered
    /// saved cameras are returned as a repair fallback. This lets an explicit pairing flow recover
    /// a stale camera-side profile without allowing known cameras to crowd out a genuinely new one.
    public static func pairingDiscoveryCandidates(
        discoveredCameras: [DiscoveredCamera],
        savedCameras: [PTPIPSavedCameraRecord],
        allowSavedCameraRecovery: Bool = false
    ) -> [DiscoveredCamera] {
        let savedCameras = PTPIPSavedCameraRecords.canonicalized(savedCameras)
        let newCameras = discoveredCameras.filter { discoveredCamera in
            !savedCameras.contains { savedCamera in
                discoveryCamera(discoveredCamera, matchesSavedCamera: savedCamera)
            }
        }
        if allowSavedCameraRecovery, newCameras.isEmpty {
            return discoveredCameras
        }
        return newCameras
    }

    /// Resolves the connection strategy. A camera with a local saved profile is trusted and
    /// reconnects silently (`savedProfile`). Anything else runs the first-time pairing handshake
    /// (which the app auto-accepts). Over Wi-Fi we never silently probe an unknown camera: the
    /// probe is destructive to a camera sitting on its Wi-Fi pairing wizard — it kicks it out of
    /// pairing mode — so an unknown network camera must always go straight to the handshake.
    ///
    /// Over USB there is no network-profile wizard to disturb, and the camera may already trust
    /// the tethered host, so an unknown USB camera probes first and falls back to pairing
    /// (`restoreCameraProfileBeforePairing`). `[VERIFY-ON-HW]` — confirm the ZR's USB pairing
    /// behavior on hardware.
    public static func connectionStrategy(
        host rawHost: String,
        savedCameras: [PTPIPSavedCameraRecord],
        transportKind: CameraTransportKind = .ptpIP
    ) -> CameraConnectionStrategy {
        guard let host = PTPIPPairedHosts.normalizedHost(rawHost) else {
            return .firstTimePairing
        }
        let hasSavedProfile = PTPIPSavedCameraRecords.canonicalized(savedCameras)
            .contains { $0.host == host }
        if hasSavedProfile { return .savedProfile }
        return transportKind == .usb ? .restoreCameraProfileBeforePairing : .firstTimePairing
    }

    /// Returns the saved record matching a discovered camera (by host key or assigned camera
    /// name). Used to reconnect a saved USB camera silently the moment it is plugged in.
    public static func savedCamera(
        forDiscovered discoveredCamera: DiscoveredCamera,
        in savedCameras: [PTPIPSavedCameraRecord]
    ) -> PTPIPSavedCameraRecord? {
        PTPIPSavedCameraRecords.canonicalized(savedCameras).first { savedCamera in
            discoveryCamera(discoveredCamera, matchesSavedCamera: savedCamera)
        }
    }

    public static func startsWithPairingHandshake(for strategy: CameraConnectionStrategy) -> Bool {
        switch strategy {
        case .savedProfile, .restoreCameraProfileBeforePairing:
            return false
        case .firstTimePairing:
            return true
        }
    }

    public static func recoveryPrompt(
        savedCameras: [PTPIPSavedCameraRecord],
        discoveredCameras: [DiscoveredCamera],
        connectedHost: String?,
        isIPhoneHotspotBridgeActive: Bool = false
    ) -> CameraStartupRecoveryPrompt {
        let cameras = PTPIPSavedCameraRecords.canonicalized(savedCameras)
        guard !cameras.isEmpty else { return .none }

        let hasReachableCamera = cameras.contains { camera in
            SavedCameraAvailabilityPolicy.resolve(
                camera: camera,
                discoveredCameras: discoveredCameras,
                connectedHost: connectedHost
            ) != .offline
        }
        guard !hasReachableCamera else { return .none }

        guard let hotspotCamera = cameras.first(where: isIPhoneHotspotCamera) else {
            return .none
        }
        if isIPhoneHotspotBridgeActive {
            return .waitForIPhoneHotspotCamera(hotspotCamera)
        }
        return .enableIPhoneHotspot(hotspotCamera)
    }

    private static func isIPhoneHotspotCamera(_ camera: PTPIPSavedCameraRecord) -> Bool {
        // Records reaching here are canonicalized, hence typed: the declared path answers.
        camera.path?.kind == .phoneHotspot
    }

    /// True when a camera reaches the app over the iPhone's Personal Hotspot — the phone hosts and
    /// the camera joins, so the phone never joins a network.
    ///
    /// Identified by a hotspot transport label, a declared hotspot path on a saved record, or —
    /// when the phone exposes its hotspot interface addresses — a host on the **same /24 as that
    /// live interface**. No fixed hotspot IP range is assumed (Apple's assignment can vary).
    ///
    /// - Parameter hotspotSubnetBases: /24 bases of this device's Personal Hotspot interface(s),
    ///   e.g. from `bridge*` addresses. Empty when the hotspot is down or unknown.
    public static func usesIPhoneHotspot(
        host: String,
        transport: String,
        hotspotSubnetBases: [String] = []
    ) -> Bool {
        if isIPhoneHotspotTransport(transport) { return true }
        guard let base = CameraDiscovery.subnetBase(for: host), !hotspotSubnetBases.isEmpty else {
            return false
        }
        return hotspotSubnetBases.contains(base)
    }

    private static func discoveryCamera(
        _ discoveredCamera: DiscoveredCamera,
        matchesSavedCamera savedCamera: PTPIPSavedCameraRecord
    ) -> Bool {
        PTPIPPairedHosts.normalizedHost(discoveredCamera.ip) == savedCamera.host
            || PTPIPSavedCameraRecords.cameraNamesMatch(
                savedName: savedCamera.displayName,
                discoveredName: discoveredCamera.displayName
            )
    }

    private static func isIPhoneHotspotTransport(_ rawTransport: String) -> Bool {
        let normalized = rawTransport.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalized.contains("iphone hotspot")
            || normalized.contains("personal hotspot")
    }
}

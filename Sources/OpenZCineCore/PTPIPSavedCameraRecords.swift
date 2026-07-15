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
        presentation: PTPIPSavedCameraPresentation? = nil
    ) {
        self.host = host
        self.displayName = displayName
        self.transport = transport
        self.lastSeenAt = lastSeenAt
        self.presentation = presentation
    }

    public var host: String  // IP address, hostname, or `usb:<device-id>` key
    public var displayName: String  // camera-assigned name
    public var transport: String  // e.g. "Wi-Fi", "USB-C"
    public var lastSeenAt: Date?
    public var presentation: PTPIPSavedCameraPresentation?

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

    public var id: String { host }

    /// Whether this camera was saved from a USB-C tethered pairing. USB records carry a
    /// `usb:<device-id>` host key, so network availability checks do not apply to them.
    public var isUSBTransport: Bool {
        transport.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(Self.usbTransportLabel) == .orderedSame
            || host.hasPrefix(DiscoveredCamera.usbHostKeyPrefix)
    }
}

/// Canonicalizes and updates saved camera profile records.
public enum PTPIPSavedCameraRecords {
    public static func canonicalized(_ records: [PTPIPSavedCameraRecord])
        -> [PTPIPSavedCameraRecord]
    {
        var output: [PTPIPSavedCameraRecord] = []
        for record in records {
            guard let normalized = normalizedRecord(record) else { continue }
            if let index = output.firstIndex(where: { recordsDescribeSameCamera($0, normalized) }) {
                output[index] = preferredRecord(existing: output[index], candidate: normalized)
            } else {
                output.append(normalized)
            }
        }
        return output
    }

    public static func upserting(
        host rawHost: String,
        displayName rawDisplayName: String,
        transport rawTransport: String,
        lastSeenAt: Date?,
        into records: [PTPIPSavedCameraRecord]
    ) -> [PTPIPSavedCameraRecord] {
        guard let host = PTPIPPairedHosts.normalizedHost(rawHost) else {
            return canonicalized(records)
        }
        let updated = PTPIPSavedCameraRecord(
            host: host,
            displayName: normalizedDisplayName(rawDisplayName, host: host),
            transport: normalizedTransport(rawTransport),
            lastSeenAt: lastSeenAt
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

    public static func removing(
        _ rawHost: String,
        from records: [PTPIPSavedCameraRecord]
    ) -> [PTPIPSavedCameraRecord] {
        guard let host = PTPIPPairedHosts.normalizedHost(rawHost) else {
            return canonicalized(records)
        }
        return canonicalized(records).filter { $0.host != host }
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
            presentation: normalizedPresentation(record.presentation)
        )
    }

    private static func recordsDescribeSameCamera(
        _ lhs: PTPIPSavedCameraRecord,
        _ rhs: PTPIPSavedCameraRecord
    ) -> Bool {
        lhs.host == rhs.host
            || cameraNamesMatch(savedName: lhs.displayName, discoveredName: rhs.displayName)
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
        connectedHost rawConnectedHost: String?
    ) -> SavedCameraAvailability {
        guard let host = PTPIPPairedHosts.normalizedHost(camera.host) else {
            return .offline
        }
        if PTPIPPairedHosts.normalizedHost(rawConnectedHost ?? "") == host {
            return .connected
        }
        if let discovered = discoveredCameras.first(where: {
            PTPIPPairedHosts.normalizedHost($0.ip) == host
                || PTPIPSavedCameraRecords.cameraNamesMatch(
                    savedName: camera.displayName,
                    discoveredName: $0.displayName
                )
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
        usesIPhoneHotspot(host: camera.host, transport: camera.transport)
    }

    /// True when a camera reaches the app over the iPhone's Personal Hotspot — the phone hosts and
    /// the camera joins, so the phone never joins a network. Identified by a hotspot transport label
    /// or a 172.20.10.x hotspot-subnet host. Pass `transport: ""` to check a bare host (e.g. a
    /// freshly discovered camera with no saved transport).
    public static func usesIPhoneHotspot(host: String, transport: String) -> Bool {
        isIPhoneHotspotTransport(transport) || isIPhoneHotspotHost(host)
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

    private static func isIPhoneHotspotHost(_ rawHost: String) -> Bool {
        guard let host = PTPIPPairedHosts.normalizedHost(rawHost) else { return false }
        let octets = host.split(separator: ".").compactMap { Int($0) }
        return octets.count == 4
            && octets[0] == 172
            && octets[1] == 20
            && octets[2] == 10
    }
}

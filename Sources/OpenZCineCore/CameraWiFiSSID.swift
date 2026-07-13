import Foundation

/// Nikon ZR camera access-point SSID derivation and join policy.
public enum CameraWiFiSSID {
    /// Prefix of the camera's Wi‑Fi hotspot SSID (e.g. `NIKON_ZR_01234`).
    public static let nikonAccessPointPrefix = "NIKON_ZR_"

    /// Prefix of the PTP-IP friendly camera name (e.g. `ZR_6001234`).
    public static let ptpFriendlyNamePrefix = "ZR_"

    /// Derives the camera AP SSID from a PTP friendly name (`ZR_6001234` → `NIKON_ZR_01234`).
    public static func deriveSSID(fromCameraName name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.uppercased().hasPrefix(ptpFriendlyNamePrefix) else { return nil }
        let serial = String(trimmed.dropFirst(ptpFriendlyNamePrefix.count))
        guard let suffix = serialSuffixForSSID(serial) else { return nil }
        return nikonAccessPointPrefix + suffix
    }

    /// Returns a stored SSID from the saved record, or derives one from its display name.
    public static func resolve(for record: PTPIPSavedCameraRecord) -> String? {
        if let stored = record.presentation?.wifiSSID?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !stored.isEmpty
        {
            return stored
        }
        return deriveSSID(fromCameraName: record.displayName)
    }

    private static func serialSuffixForSSID(_ serial: String) -> String? {
        let digits = serial.filter(\.isNumber)
        guard digits.count >= 5 else { return nil }
        return String(digits.suffix(5))
    }
}

/// Decides when OpenZCine should prompt iOS to join the camera Wi‑Fi network.
public enum CameraWiFiJoinPolicy {
    /// Target for `NEHotspotConfiguration` — either an exact SSID or a prefix match.
    public struct JoinTarget: Equatable, Sendable {
        public let ssid: String?
        public let ssidPrefix: String?

        public init(ssid: String) {
            self.ssid = ssid
            self.ssidPrefix = nil
        }

        public init(ssidPrefix: String) {
            self.ssid = nil
            self.ssidPrefix = ssidPrefix
        }
    }

    /// Whether the phone is joined to a Nikon ZR camera Wi‑Fi hotspot.
    ///
    /// Uses the connected SSID when available. Subnet-only matching is intentionally **not** used:
    /// `192.168.1.0/24` is a common home-router range and would false-positive when the camera AP
    /// is nearby but the phone remains on home Wi‑Fi.
    public static func isOnCameraAccessPoint(
        localAddresses: [String],
        connectedSSID: String? = nil
    ) -> Bool {
        _ = localAddresses
        guard let ssid = connectedSSID?.trimmingCharacters(in: .whitespacesAndNewlines),
            !ssid.isEmpty
        else { return false }
        return ssid.uppercased().hasPrefix(CameraWiFiSSID.nikonAccessPointPrefix.uppercased())
    }

    /// Resolves the camera SSID without considering the current network.
    public static func resolvedSSID(
        savedCamera: PTPIPSavedCameraRecord?,
        discoveredCamera: DiscoveredCamera?
    ) -> String? {
        if let savedCamera, let ssid = CameraWiFiSSID.resolve(for: savedCamera) {
            return ssid
        }
        if let name = discoveredCamera?.name,
            let ssid = CameraWiFiSSID.deriveSSID(fromCameraName: name)
        {
            return ssid
        }
        return nil
    }

    /// Returns a join target when a Wi‑Fi connect should prompt iOS to join the camera network first.
    public static func joinTargetIfNeeded(
        transportKind: CameraTransportKind,
        localAddresses: [String],
        savedCamera: PTPIPSavedCameraRecord?,
        discoveredCamera: DiscoveredCamera?,
        connectedSSID: String? = nil
    ) -> JoinTarget? {
        guard transportKind == .ptpIP else { return nil }
        guard
            !isOnCameraAccessPoint(
                localAddresses: localAddresses,
                connectedSSID: connectedSSID
            )
        else { return nil }
        // iPhone-hotspot cameras need NO phone-side join: the phone hosts the hotspot and the
        // camera joins it, so there's nothing for iOS to "switch networks" to. Without this, the
        // phone would enter the Wi-Fi-join phase (wrong "Tap Join when iOS asks…" copy) and even
        // attempt to join a network for a camera that's already reachable on the hotspot subnet.
        if let savedCamera,
            CameraStartupPolicy.usesIPhoneHotspot(
                host: savedCamera.host, transport: savedCamera.transport)
        {
            return nil
        }
        if let discoveredCamera,
            CameraStartupPolicy.usesIPhoneHotspot(host: discoveredCamera.ip, transport: "")
        {
            return nil
        }
        guard
            let ssid = resolvedSSID(
                savedCamera: savedCamera,
                discoveredCamera: discoveredCamera
            )
        else { return nil }
        return JoinTarget(ssid: ssid)
    }

    /// Target for a proactive Wi‑Fi join attempt on app launch or foreground.
    public enum ProactiveJoinTarget: Equatable, Sendable {
        case specificSSID(String)
        case ssidPrefix(String)
    }

    /// Resolves a proactive join target when the phone is off the camera AP subnet.
    ///
    /// Prefers a saved camera's SSID when available; otherwise matches any nearby Nikon ZR AP
    /// via `NIKON_ZR_` prefix (no saved profile required).
    public static func proactiveJoinTarget(
        localAddresses: [String],
        savedCameras: [PTPIPSavedCameraRecord],
        connectedSSID: String? = nil
    ) -> ProactiveJoinTarget? {
        guard
            !isOnCameraAccessPoint(
                localAddresses: localAddresses,
                connectedSSID: connectedSSID
            )
        else { return nil }

        for camera in savedCameras where !camera.isUSBTransport {
            if let ssid = CameraWiFiSSID.resolve(for: camera) {
                return .specificSSID(ssid)
            }
        }

        return .ssidPrefix(CameraWiFiSSID.nikonAccessPointPrefix)
    }

    /// Resolves which SSID or prefix should be used when looking up stored Wi‑Fi credentials.
    public static func credentialLookupSSID(
        for joinTarget: JoinTarget,
        resolvedSSID: String?
    ) -> (ssid: String?, prefix: String?) {
        if let ssid = joinTarget.ssid ?? resolvedSSID, !ssid.isEmpty {
            return (ssid, nil)
        }
        return (nil, joinTarget.ssidPrefix)
    }
}

/// Session-scoped debounce for proactive camera Wi‑Fi join prompts.
public struct ProactiveWiFiJoinSessionPolicy: Sendable {
    /// Minimum interval between join attempts after a dismiss or failure.
    public static let cooldownInterval: TimeInterval = 30

    /// Cooldown after the operator denies the system join sheet (persisted across launches).
    public static let userDeniedCooldown: TimeInterval = 300

    /// Debounce before applying hotspot configuration on launch or foreground.
    public static let launchDebounce: TimeInterval = 0

    public private(set) var lastAttemptAt: Date?
    public private(set) var userDeniedThisSession = false
    public private(set) var succeededThisSession = false

    public init() {}

    /// Whether another proactive join attempt is allowed.
    public func shouldAttempt(
        lastUserDeniedAt: Date? = nil,
        at now: Date = Date()
    ) -> Bool {
        if userDeniedThisSession { return false }
        if succeededThisSession { return false }
        if let deniedAt = lastUserDeniedAt,
            now.timeIntervalSince(deniedAt) < Self.userDeniedCooldown
        {
            return false
        }
        if let lastAttemptAt,
            now.timeIntervalSince(lastAttemptAt) < Self.cooldownInterval
        {
            return false
        }
        return true
    }

    public mutating func recordAttempt(at now: Date = Date()) {
        lastAttemptAt = now
    }

    public mutating func recordUserDenied() {
        userDeniedThisSession = true
    }

    public mutating func recordSuccess() {
        succeededThisSession = true
    }
}

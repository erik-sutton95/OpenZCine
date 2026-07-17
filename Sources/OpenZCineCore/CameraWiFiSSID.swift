import Foundation

/// Nikon Z camera access-point identification, ZR derivation, and join policy.
public enum CameraWiFiSSID {
    /// ZR-specific prefix retained for deriving an SSID from the ZR's PTP friendly name.
    public static let nikonAccessPointPrefix = "NIKON_ZR_"

    /// Brand prefix shared by Nikon Z access-point names across camera models.
    public static let nikonAccessPointBrandPrefix = "NIKON"

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

    /// Whether an SSID has the conservative shape of a Nikon Z camera access point.
    ///
    /// Nikon bodies do not share the ZR's exact underscore/model/serial layout. The stable contract
    /// is a Nikon brand prefix, a Z-series marker, at least one serial/model digit, and only the
    /// ASCII characters camera-generated network names use. This intentionally does not reconstruct
    /// an unfamiliar model name; exact scanned or stored SSIDs remain authoritative.
    public static func isNikonZAccessPoint(_ rawSSID: String) -> Bool {
        let ssid = rawSSID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (8...32).contains(ssid.utf8.count) else { return false }
        let uppercase = ssid.uppercased()
        guard uppercase.hasPrefix(nikonAccessPointBrandPrefix) else { return false }

        let suffix = uppercase.dropFirst(nikonAccessPointBrandPrefix.count)
        guard suffix.contains("Z"), suffix.contains(where: \.isNumber) else { return false }
        return suffix.unicodeScalars.allSatisfy { scalar in
            scalar.value <= 0x7F
                && (CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "-")
        }
    }

    /// Normalizes an OCR token only enough to repair the Nikon brand, then validates its full shape.
    ///
    /// Model and serial characters are preserved rather than guessed, so a future body cannot be
    /// silently joined under a synthesized SSID. Nikon camera SSIDs are emitted in uppercase.
    static func normalizedScannedNikonZAccessPoint(_ rawSSID: String) -> String? {
        let trimmed = rawSSID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= nikonAccessPointBrandPrefix.count else { return nil }

        let uppercase = trimmed.uppercased()
        let brandEnd = uppercase.index(
            uppercase.startIndex,
            offsetBy: nikonAccessPointBrandPrefix.count
        )
        let brand = String(uppercase[..<brandEnd])
        guard correctedNikonBrand(brand) == nikonAccessPointBrandPrefix else { return nil }

        let candidate = nikonAccessPointBrandPrefix + String(uppercase[brandEnd...])
        guard isNikonZAccessPoint(candidate) else { return nil }
        return candidate
    }

    private static func serialSuffixForSSID(_ serial: String) -> String? {
        let digits = serial.filter(\.isNumber)
        guard digits.count >= 5 else { return nil }
        return String(digits.suffix(5))
    }

    private static func correctedNikonBrand(_ brand: String) -> String {
        String(
            brand.map { character -> Character in
                switch character {
                case "0": return "O"
                case "1", "L": return "I"
                case "5": return "S"
                case "8": return "B"
                default: return character
                }
            })
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

    /// Whether the phone is joined to a Nikon Z camera Wi‑Fi hotspot.
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
        return CameraWiFiSSID.isNikonZAccessPoint(ssid)
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
    /// Prefers a saved camera's exact SSID when available; otherwise matches a nearby Nikon Z AP
    /// by its shared brand prefix (no saved profile required).
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

        return .ssidPrefix(CameraWiFiSSID.nikonAccessPointBrandPrefix)
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

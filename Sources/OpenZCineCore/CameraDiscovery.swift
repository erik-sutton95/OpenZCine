import Foundation

/// Source from which a camera was discovered.
public enum DiscoverySource: String, Codable, Equatable, Sendable {
    case bonjour  // Bonjour/mDNS
    case subnetProbe
    case manual  // entered by the user
    case usb  // USB-C (ImageCaptureCore device enumeration)
}

/// A camera discovered on the network or attached over USB.
public struct DiscoveredCamera: Equatable, Identifiable, Sendable {
    /// Prefix of the stable host key used for USB-attached cameras (no IP address exists).
    public static let usbHostKeyPrefix = "usb:"

    public init(ip: String, name: String? = nil, source: DiscoverySource) {
        self.ip = ip
        self.name = name
        self.source = source
    }

    /// Camera IP address, or a `usb:<device-id>` host key for USB-attached cameras.
    public let ip: String
    public let name: String?
    public let source: DiscoverySource

    public var id: String { ip }

    /// Whether this camera is attached over USB rather than reachable by IP.
    public var isUSB: Bool { source == .usb }

    /// User-facing display name.
    public var displayName: String {
        guard let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Camera \(ip)"
        }
        return name
    }
}

/// Camera discovery and network scanning policies.
public enum CameraDiscovery {
    /// Default Nikon ZR access point IP address.
    public static let nikonZRAccessPointHost = "192.168.1.1"

    /// Delay before the next automatic discovery pass. The first retry is responsive, then the
    /// backoff protects a sleeping camera's Wi-Fi radio from repeated saved-host probes. Pull to
    /// refresh remains the operator's immediate scan path.
    public static func automaticScanRetryInterval(
        emptyStreak: Int,
        foundCamera: Bool
    ) -> TimeInterval {
        guard !foundCamera else { return 30 }
        return switch max(emptyStreak, 1) {
        case 1: 0.85
        case 2: 2
        case 3: 5
        case 4: 12
        default: 30
        }
    }

    /// Returns whether the address is a private IPv4 address.
    public static func isPrivateIPv4(_ address: String) -> Bool {
        guard let octets = ipv4Octets(address) else { return false }
        if octets[0] == 10 { return true }
        if octets[0] == 172 && (16...31).contains(octets[1]) { return true }
        if octets[0] == 192 && octets[1] == 168 { return true }
        return false
    }

    /// Returns whether the address should be included in default subnet scans.
    public static func isDefaultScanIPv4(_ address: String) -> Bool {
        guard isPrivateIPv4(address), let octets = ipv4Octets(address) else { return false }
        return octets[0] != 10
    }

    /// Returns whether the interface should be used for subnet scanning.
    public static func isSupportedScanInterface(name: String, address: String) -> Bool {
        isDefaultScanIPv4(address)
    }

    /// Extracts the /24 subnet base from an IPv4 address.
    public static func subnetBase(for address: String) -> String? {
        guard let octets = ipv4Octets(address) else { return nil }
        return "\(octets[0]).\(octets[1]).\(octets[2])"
    }

    /// Returns all host addresses in the specified /24 subnet.
    public static func fastHosts(inSubnet subnet: String) -> [String] {
        (1...254).map { "\(subnet).\($0)" }
    }

    /// Returns fallback host addresses for automatic discovery in the subnet.
    public static func automaticFallbackHosts(inSubnet subnet: String) -> [String] {
        fastHosts(inSubnet: subnet)
    }

    /// Splits the automatic scan list into a fast priority pass and the remaining sweep.
    ///
    /// Priority hosts are the addresses most likely to answer — saved cameras' last-known hosts
    /// plus the ZR access-point address — probed as their own first chunk so the common
    /// reconnect case resolves in a single probe round instead of waiting on the subnet sweep.
    /// Hosts are normalized, deduped, and never include the phone's own addresses; the remainder
    /// preserves `automaticScanHosts` order minus the priority entries.
    public static func prioritizedScanHosts(
        priorityHosts: [String],
        localAddresses: [String]
    ) -> (priority: [String], remaining: [String]) {
        let localAddressSet = Set(localAddresses.compactMap(PTPIPPairedHosts.normalizedHost))
        var seen: Set<String> = []
        var priority: [String] = []
        for host in [nikonZRAccessPointHost] + priorityHosts {
            guard let normalized = PTPIPPairedHosts.normalizedHost(host),
                !localAddressSet.contains(normalized),
                !seen.contains(normalized)
            else { continue }
            seen.insert(normalized)
            priority.append(normalized)
        }
        let remaining = automaticScanHosts(localAddresses: localAddresses)
            .filter { !seen.contains($0) }
        return (priority, remaining)
    }

    /// Builds a comprehensive scan list from local network interfaces.
    public static func automaticScanHosts(localAddresses: [String]) -> [String] {
        let localAddressSet = Set(localAddresses.compactMap(PTPIPPairedHosts.normalizedHost))
        let subnets = Set<String>(
            localAddressSet.compactMap { address in
                guard isSupportedScanInterface(name: "", address: address) else { return nil }
                return subnetBase(for: address)
            }
        )

        var hosts = [nikonZRAccessPointHost]
        for subnet in subnets.sorted() {
            hosts.append(contentsOf: automaticFallbackHosts(inSubnet: subnet))
        }

        var seen: Set<String> = []
        var output: [String] = []
        for host in hosts {
            guard let normalized = PTPIPPairedHosts.normalizedHost(host),
                !localAddressSet.contains(normalized),
                !seen.contains(normalized)
            else {
                continue
            }
            seen.insert(normalized)
            output.append(normalized)
        }
        return output
    }

    /// Deduplicates and sorts discovered cameras. USB-attached cameras (which carry a
    /// `usb:<device-id>` host key instead of an IP) always pass the address filter and sort ahead
    /// of network cameras — a plugged-in camera is the most deliberate signal an operator can give.
    public static func dedupeAndSort(
        _ cameras: [DiscoveredCamera],
        includeTenDotSubnets: Bool = false
    ) -> [DiscoveredCamera] {
        var seen = Set<String>()
        var usbCameras: [DiscoveredCamera] = []
        var networkCameras: [DiscoveredCamera] = []

        for camera in cameras {
            let normalizedIP = camera.ip.trimmingCharacters(in: .whitespaces)
            guard !seen.contains(normalizedIP) else { continue }
            if camera.isUSB {
                seen.insert(normalizedIP)
                usbCameras.append(camera)
                continue
            }
            let allowed =
                includeTenDotSubnets
                ? isPrivateIPv4(normalizedIP)
                : isDefaultScanIPv4(normalizedIP)
            guard allowed else { continue }
            seen.insert(normalizedIP)
            networkCameras.append(camera)
        }

        return usbCameras
            + networkCameras.sorted { lhs, rhs in
                let lhsIP = lhs.ip.trimmingCharacters(in: .whitespaces)
                let rhsIP = rhs.ip.trimmingCharacters(in: .whitespaces)
                return ipSortValue(lhsIP) < ipSortValue(rhsIP)
            }
    }

    private static func ipv4Octets(_ address: String) -> [Int]? {
        let parts = address.split(separator: ".")
        guard parts.count == 4 else { return nil }
        let octets = parts.compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else {
            return nil
        }
        return octets
    }

    private static func ipSortValue(_ address: String) -> UInt32 {
        guard let octets = ipv4Octets(address) else { return UInt32.max }
        return octets.reduce(UInt32(0)) { partial, octet in
            (partial << 8) + UInt32(octet)
        }
    }
}

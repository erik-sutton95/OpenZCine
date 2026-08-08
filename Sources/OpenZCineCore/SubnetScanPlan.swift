import Foundation

/// One local IPv4 interface, including the prefix the OS actually gave it.
public struct LocalIPv4Interface: Sendable, Equatable {
    public let name: String
    public let address: String
    /// Dotted netmask (`255.255.255.0`). `nil` when the OS did not supply one.
    public let netmask: String?

    public init(name: String, address: String, netmask: String? = nil) {
        self.name = name
        self.address = address
        self.netmask = netmask
    }
}

/// Which /24s a camera search should sweep, and in what order.
///
/// Discovery used to assume the phone's own /24 was the whole world: the interface's netmask was
/// read from `getifaddrs` and thrown away, and the scan list came from `subnetBase(for:)`, which
/// takes the first three octets of an address and calls it a subnet. On a network handing out
/// 192.168.1.x that search can never reach a camera at 192.168.2.245 — the field report this
/// exists for — and it could not even tell that it was looking at a fraction of its own link,
/// because it had discarded the one number that says so.
///
/// Two things are wrong with that and both are fixed here. The real prefix decides what is ON-LINK,
/// so a device on a /16 sweeps the /16's neighbourhood rather than 1/256th of it. And a /24 that
/// finds nothing widens to its neighbours anyway, because consumer routers routinely route between
/// their own subnets — a camera one third-octet away is usually reachable, just never asked.
///
/// Order is everything, because the sweep stops at the first camera it finds. Nearest first, from
/// where the evidence already points.
public enum SubnetScanPlan: Sendable {
    /// Hard ceiling on how many /24s one plan may name.
    ///
    /// A /16 holds 256 of them and blind-probing all of it is minutes of radio for a device that
    /// is nearly always within a step or two of where we are standing. The cap keeps a widening
    /// search bounded; the ORDER is what makes it find things.
    public static let maximumSubnets = 12

    /// The /24 bases to sweep, nearest-first, deduplicated.
    ///
    /// - Parameters:
    ///   - interfaces: This device's live IPv4 interfaces, netmask included where known.
    ///   - savedHosts: Addresses cameras have answered on before — the strongest evidence there
    ///     is about where this operator's gear lives, and worth a whole subnet each.
    public static func orderedSubnets(
        interfaces: [LocalIPv4Interface],
        savedHosts: [String] = [],
        limit: Int = maximumSubnets
    ) -> [String] {
        var ordered: [String] = []
        var seen: Set<String> = []
        func append(_ base: String?) {
            guard let base, !seen.contains(base), ordered.count < limit else { return }
            seen.insert(base)
            ordered.append(base)
        }

        let scannable = interfaces.filter { isDefaultScanIPv4($0.address) }

        // 1. The subnets this device is standing in. Always first: a camera on our own link needs
        //    no routing to answer, and this is the case that resolves in half a second.
        for interface in scannable {
            append(CameraDiscovery.subnetBase(for: interface.address))
        }

        // 2. Subnets a camera has actually answered on before. Evidence beats proximity — a saved
        //    host two hundred third-octets away is still somewhere this rig has really worked.
        for host in savedHosts where isDefaultScanIPv4(host) {
            append(CameraDiscovery.subnetBase(for: host))
        }

        // 3. Outward from each interface, alternating up and down. Inside the interface's own
        //    prefix these are literally on-link; outside it they are the routed neighbours a
        //    consumer router will usually carry us to. Same ladder either way — the difference is
        //    only how likely each rung is to answer, and the sweep stops at the first that does.
        for interface in scannable {
            guard let octets = ipv4Octets(interface.address) else { continue }
            for step in 1...limit {
                for candidate in [octets[2] + step, octets[2] - step]
                where (0...255).contains(candidate) {
                    append("\(octets[0]).\(octets[1]).\(candidate)")
                }
            }
        }
        return ordered
    }

    /// How many trailing addresses of a /24 the interface's own prefix actually covers.
    ///
    /// Answers "is this neighbour on-link or routed", which is not a distinction the sweep needs
    /// to act on — it probes either way — but is exactly what the operator's network is doing, and
    /// what a diagnosis should be able to say.
    public static func prefixLength(netmask: String?) -> Int? {
        guard let netmask, let octets = ipv4Octets(netmask) else { return nil }
        var bits = 0
        var seenZero = false
        for octet in octets {
            for shift in stride(from: 7, through: 0, by: -1) {
                let isSet = (octet >> shift) & 1 == 1
                if isSet {
                    // A netmask is a run of ones then a run of zeroes; anything else is not one.
                    if seenZero { return nil }
                    bits += 1
                } else {
                    seenZero = true
                }
            }
        }
        return bits
    }

    /// Whether `host` sits inside `interface`'s own subnet — on-link, needing no router.
    public static func isOnLink(host: String, interface: LocalIPv4Interface) -> Bool {
        guard let prefix = prefixLength(netmask: interface.netmask),
            let hostOctets = ipv4Octets(host),
            let localOctets = ipv4Octets(interface.address)
        else { return false }
        let hostValue = packed(hostOctets)
        let localValue = packed(localOctets)
        guard prefix > 0 else { return true }
        guard prefix < 32 else { return hostValue == localValue }
        let mask = UInt32.max << (32 - UInt32(prefix))
        return (hostValue & mask) == (localValue & mask)
    }

    private static func packed(_ octets: [Int]) -> UInt32 {
        octets.reduce(UInt32(0)) { ($0 << 8) | UInt32($1 & 0xFF) }
    }

    private static func ipv4Octets(_ value: String) -> [Int]? {
        let parts = value.split(separator: ".")
        guard parts.count == 4 else { return nil }
        let octets = parts.compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else { return nil }
        return octets
    }

    private static func isDefaultScanIPv4(_ address: String) -> Bool {
        CameraDiscovery.isSupportedScanInterface(name: "", address: address)
    }
}

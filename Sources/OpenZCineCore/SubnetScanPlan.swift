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
    // The widening ladder that used to live here — twelve /24s, nearest-first, one more rung
    // per empty pass — is gone. It was written for a camera reachable on a neighbouring subnet,
    // and it ended up running ONLY on the camera's own access point and the phone's hotspot,
    // because the one path where a neighbour was plausible got its own finder that deliberately
    // refuses to widen. Both remaining paths are single-subnet by construction, so every rung
    // past the first was radio time that could not find anything. What is left is the prefix
    // arithmetic, which is a fact about the link rather than a plan.

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
}

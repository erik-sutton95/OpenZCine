import Foundation
import Testing

@testable import OpenZCineCore

private func wifi(_ address: String, netmask: String? = "255.255.255.0") -> LocalIPv4Interface {
    LocalIPv4Interface(name: "en0", address: address, netmask: netmask)
}

/// The field report this exists for: phone on 192.168.1.x, camera at 192.168.2.245, and a search
/// that could never reach it because the plan was always exactly one /24.
@Test func theNeighbouringSubnetIsSweptRightAfterOurOwn() {
    let plan = SubnetScanPlan.orderedSubnets(interfaces: [wifi("192.168.1.42")])

    #expect(plan.first == "192.168.1")
    #expect(plan.contains("192.168.2"))
    // Nearest first: the camera one step away must not sit behind ten other subnets.
    let neighbour = try! #require(plan.firstIndex(of: "192.168.2"))
    #expect(neighbour <= 2)
}

/// Our own link resolves in one round; everything else is a widening guess behind it.
@Test func ourOwnSubnetIsAlwaysFirst() {
    let plan = SubnetScanPlan.orderedSubnets(
        interfaces: [wifi("10.0.5.9", netmask: "255.255.0.0")],
        savedHosts: ["192.168.1.50"]
    )

    #expect(plan.first == "10.0.5")
}

/// Evidence beats proximity: a subnet a camera has really answered on outranks a guess.
@Test func aSubnetACameraHasAnsweredOnComesBeforeGuesses() {
    let plan = SubnetScanPlan.orderedSubnets(
        interfaces: [wifi("192.168.1.42")],
        savedHosts: ["192.168.129.246"]
    )

    let saved = try! #require(plan.firstIndex(of: "192.168.129"))
    let guessed = try! #require(plan.firstIndex(of: "192.168.2"))
    #expect(saved < guessed)
}

/// Bounded on purpose. A /16 holds 256 /24s and blind-probing all of it is minutes of radio.
@Test func thePlanIsBoundedAndFreeOfDuplicates() {
    let plan = SubnetScanPlan.orderedSubnets(
        interfaces: [wifi("192.168.1.42"), wifi("192.168.1.43")],
        savedHosts: ["192.168.1.50", "192.168.2.9"]
    )

    #expect(plan.count <= SubnetScanPlan.maximumSubnets)
    #expect(Set(plan).count == plan.count)
}

/// The ladder walks outward in both directions and never leaves the octet range.
@Test func theLadderStaysInsideTheOctetAndWalksBothWays() {
    let low = SubnetScanPlan.orderedSubnets(interfaces: [wifi("192.168.0.10")])
    #expect(
        low.allSatisfy { base in
            guard let last = base.split(separator: ".").last, let octet = Int(last) else {
                return false
            }
            return (0...255).contains(octet)
        })
    #expect(low.contains("192.168.1"))

    let high = SubnetScanPlan.orderedSubnets(interfaces: [wifi("192.168.255.10")])
    #expect(high.contains("192.168.254"))
    #expect(high.allSatisfy { !$0.hasSuffix(".256") })
}

/// The netmask is the ground truth the old code threw away.
@Test func aPrefixIsReadFromTheNetmaskAndRejectsNonsense() {
    #expect(SubnetScanPlan.prefixLength(netmask: "255.255.255.0") == 24)
    #expect(SubnetScanPlan.prefixLength(netmask: "255.255.0.0") == 16)
    #expect(SubnetScanPlan.prefixLength(netmask: "255.255.254.0") == 23)
    #expect(SubnetScanPlan.prefixLength(netmask: "0.0.0.0") == 0)
    #expect(SubnetScanPlan.prefixLength(netmask: "255.255.255.255") == 32)
    // A netmask is a run of ones then zeroes. Anything else is not one, and guessing at it would
    // be worse than admitting we do not know.
    #expect(SubnetScanPlan.prefixLength(netmask: "255.0.255.0") == nil)
    #expect(SubnetScanPlan.prefixLength(netmask: "nonsense") == nil)
    #expect(SubnetScanPlan.prefixLength(netmask: nil) == nil)
}

/// Whether a neighbour is on-link or routed — the fact the sweep does not need but a diagnosis does.
@Test func onLinkFollowsTheRealPrefixNotTheThirdOctet() {
    let wide = wifi("192.168.1.42", netmask: "255.255.0.0")
    #expect(SubnetScanPlan.isOnLink(host: "192.168.2.245", interface: wide))
    #expect(!SubnetScanPlan.isOnLink(host: "10.0.0.5", interface: wide))

    let narrow = wifi("192.168.1.42", netmask: "255.255.255.0")
    // The exact case from the field: same third-octet neighbour, and on a /24 it is NOT on-link —
    // reachable only if the router carries us there, which is why the sweep tries it anyway.
    #expect(!SubnetScanPlan.isOnLink(host: "192.168.2.245", interface: narrow))
    #expect(SubnetScanPlan.isOnLink(host: "192.168.1.245", interface: narrow))

    // Without a netmask there is no claim to make.
    #expect(
        !SubnetScanPlan.isOnLink(host: "192.168.1.9", interface: wifi("192.168.1.42", netmask: nil))
    )
}

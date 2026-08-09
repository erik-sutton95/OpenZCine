import Foundation
import Testing

@testable import OpenZCineCore

private func wifi(_ address: String, netmask: String? = "255.255.255.0") -> LocalIPv4Interface {
    LocalIPv4Interface(name: "en0", address: address, netmask: netmask)
}

/// The field report this exists for: phone on 192.168.1.x, camera at 192.168.2.245, and a search
/// that could never reach it because the plan was always exactly one /24.
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

/// A USB camera's saved "host" is a device-id key, not an address. The network probe used to dial
/// it as one every pass, waiting on a hostname that cannot resolve.
@Test func aUSBHostKeyIsNeverANetworkProbeCandidate() {
    #expect(DiscoveredCamera.isUSBHostKey("usb:00000030-3030"))
    #expect(!DiscoveredCamera.isUSBHostKey("192.168.1.246"))

    let split = CameraDiscovery.prioritizedScanHosts(
        priorityHosts: ["192.168.1.246", "usb:00000030-3030-3030-3036-303032313939"],
        localAddresses: ["192.168.1.146"]
    )

    #expect(split.priority.contains("192.168.1.246"))
    #expect(!split.priority.contains { DiscoveredCamera.isUSBHostKey($0) })
}

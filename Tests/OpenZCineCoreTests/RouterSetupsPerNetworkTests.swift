import Foundation
import Testing

@testable import OpenZCineCore

private func router(
    host: String, network: String?, name: String = "ZR_6002199", seen: TimeInterval = 0
) -> PTPIPSavedCameraRecord {
    PTPIPSavedCameraRecord(
        host: host,
        displayName: name,
        transport: "Wi-Fi",
        lastSeenAt: Date(timeIntervalSince1970: seen),
        path: .infrastructure(networkName: network)
    )
}

/// One camera reached from the studio and from home is two setups. The network name is the only
/// thing that can say so — the address cannot, because a router hands out a different one whenever
/// it feels like it.
@Test func twoNamedNetworksAreTwoRouterSetups() {
    let records = [
        router(host: "192.168.1.50", network: "Studio", seen: 1),
        router(host: "10.0.0.9", network: "Home", seen: 2),
    ]

    let canonical = PTPIPSavedCameraRecords.canonicalized(records)

    #expect(canonical.count == 2)
    #expect(Set(canonical.map(\.id)).count == 2)
}

/// THE reason this is not keyed on the address: the same router handing out a new lease is still
/// one setup, and forking on it would collect a row per week.
@Test func aNewAddressOnTheSameNetworkStaysOneSetup() {
    let records = [
        router(host: "192.168.1.50", network: "Studio", seen: 1),
        router(host: "192.168.1.77", network: "Studio", seen: 2),
    ]

    let canonical = PTPIPSavedCameraRecords.canonicalized(records)

    #expect(canonical.count == 1)
    #expect(canonical.first?.host == "192.168.1.77")
}

/// When iOS declines to name the network, the operator keeps exactly what they have today: one
/// router setup that absorbs address changes. Collecting a row per unidentifiable lease would be
/// worse than not splitting at all.
@Test func anUnnamedNetworkJoinsWhateverIsAlreadyThere() {
    let namedThenUnnamed = PTPIPSavedCameraRecords.canonicalized([
        router(host: "192.168.1.50", network: "Studio", seen: 1),
        router(host: "192.168.1.77", network: nil, seen: 2),
    ])
    #expect(namedThenUnnamed.count == 1)

    let twoUnnamed = PTPIPSavedCameraRecords.canonicalized([
        router(host: "192.168.1.50", network: nil, seen: 1),
        router(host: "192.168.1.77", network: nil, seen: 2),
    ])
    #expect(twoUnnamed.count == 1)
}

/// A network learned once must not be erased by a later connect that could not read it — the
/// merge already protects the AP's SSID this way, and a router's name is worth the same care.
@Test func aNetworkNameSurvivesAConnectThatCouldNotReadIt() {
    let canonical = PTPIPSavedCameraRecords.canonicalized([
        router(host: "192.168.1.50", network: "Studio", seen: 1),
        router(host: "192.168.1.50", network: nil, seen: 2),
    ])

    #expect(canonical.count == 1)
    if case .infrastructure(let network) = canonical.first?.path {
        #expect(network == "Studio")
    } else {
        Issue.record("expected an infrastructure path")
    }
}

/// The network splits infrastructure setups only. Nothing else has more than one of its kind: the
/// access point is the camera's own network, the hotspot is this phone, the cable is the cable.
@Test func onlyInfrastructureSplitsOnItsNetwork() {
    var accessPoint = router(host: "192.168.1.1", network: nil, seen: 1)
    accessPoint.path = .cameraAccessPoint(ssid: "NIKON_ZR_6002199")
    var sameCameraLater = router(host: "192.168.1.1", network: nil, seen: 2)
    sameCameraLater.path = .cameraAccessPoint(ssid: "NIKON_ZR_OTHER_NAME")

    #expect(PTPIPSavedCameraRecords.canonicalized([accessPoint, sameCameraLater]).count == 1)
}

/// Two bodies are still two cameras, whatever network they share — the name check that guards a
/// shared address has to survive the network key sitting above it.
@Test func twoBodiesOnOneNetworkAreStillTwoCameras() {
    let records = [
        router(host: "192.168.1.50", network: "Studio", name: "ZR_6002199", seen: 1),
        router(host: "192.168.1.50", network: "Studio", name: "ZR_7000000", seen: 2),
    ]

    #expect(PTPIPSavedCameraRecords.canonicalized(records).count == 2)
}

/// The case the field hit, and the reason the SSID alone was not enough: iOS only reveals a
/// network THIS APP configured, so a home router and a portable one both arrive unnamed. Their
/// subnets are what tell them apart, and those need no permission at all.
@Test func twoUnnamedRoutersOnDifferentSubnetsAreTwoSetups() {
    let canonical = PTPIPSavedCameraRecords.canonicalized([
        router(host: "192.168.1.246", network: nil, seen: 1),
        router(host: "192.168.129.66", network: nil, seen: 2),
    ])

    #expect(canonical.count == 2)
    #expect(Set(canonical.map(\.id)).count == 2)
}

/// And the balance it has to strike: a lease moving inside ONE router is still one setup.
@Test func anUnnamedRouterAbsorbsItsOwnLeaseChanges() {
    let canonical = PTPIPSavedCameraRecords.canonicalized([
        router(host: "192.168.1.50", network: nil, seen: 1),
        router(host: "192.168.1.246", network: nil, seen: 2),
    ])

    #expect(canonical.count == 1)
    #expect(canonical.first?.host == "192.168.1.246")
}

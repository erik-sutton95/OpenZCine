import Foundation
import Testing

@testable import OpenZCineCore

private func record(
    host: String,
    name: String = "ZR_6002199",
    transport: String = "Wi-Fi",
    seen: TimeInterval? = nil,
    ap: Bool? = nil,
    serial: String? = nil
) -> PTPIPSavedCameraRecord {
    PTPIPSavedCameraRecord(
        host: host,
        displayName: name,
        transport: transport,
        lastSeenAt: seen.map(Date.init(timeIntervalSince1970:)),
        pairedViaCameraAccessPoint: ap,
        serialNumber: serial
    )
}

/// One body, three paths — the reason grouping exists: hotspot, router and cable used to be
/// three rows for the same camera.
@Test func pathGroupsCollectTheSameBodyAcrossPaths() {
    let groups = SavedCameraPathGroups.group([
        record(host: "172.20.10.2", seen: 100, serial: "6002199"),
        record(host: "10.99.0.20", seen: 300, serial: "6002199"),
        record(host: "usb:demo", transport: "USB-C", seen: 200, serial: "6002199"),
    ])
    #expect(groups.count == 1)
    // Most recently seen leads the group.
    #expect(groups[0].map(\.host) == ["10.99.0.20", "usb:demo", "172.20.10.2"])
}

/// Two bodies never group on name or address — only a matching serial groups (#293 lineage).
@Test func pathGroupsKeepDifferentBodiesApart() {
    let groups = SavedCameraPathGroups.group([
        record(host: "192.168.1.1", name: "ZR_A", serial: "6002199"),
        record(host: "192.168.1.1", name: "ZR_B", serial: "7005555"),
    ])
    #expect(groups.count == 2)
}

/// A record that predates the serial stamp stays its own row — it self-heals into the group
/// on its next connect, exactly like the access-point evidence field.
@Test func pathGroupsLeaveLegacyRecordsAlone() {
    let groups = SavedCameraPathGroups.group([
        record(host: "10.99.0.20", serial: "6002199"),
        record(host: "192.168.1.1", serial: nil),
    ])
    #expect(groups.count == 2)
}

/// The row follows the path that can actually do something: connected, then discovered, then
/// the most recently seen.
@Test func activePathPrefersConnectedThenAvailable() {
    let hotspot = record(host: "172.20.10.2", seen: 300, serial: "6002199")
    let router = record(host: "10.99.0.20", seen: 100, serial: "6002199")
    let group = SavedCameraPathGroups.group([hotspot, router])[0]

    let discovered = DiscoveredCamera(ip: "10.99.0.20", name: "ZR_6002199", source: .bonjour)
    let routerAvailable = SavedCameraPathGroups.activePath(in: group) {
        $0.host == "10.99.0.20" ? .available(discovered) : .offline
    }
    #expect(routerAvailable?.host == "10.99.0.20")

    let bothOffline = SavedCameraPathGroups.activePath(in: group) { _ in .offline }
    #expect(bothOffline?.host == "172.20.10.2")

    let hotspotConnected = SavedCameraPathGroups.activePath(in: group) {
        $0.host == "172.20.10.2" ? .connected : .available(discovered)
    }
    #expect(hotspotConnected?.host == "172.20.10.2")
}

/// Chip labels come from the DECLARED path; legacy records earn theirs through the one-time
/// migration, exactly as a store read delivers them.
@Test func pathLabelsComeFromTheDeclaredPath() {
    func label(_ legacy: PTPIPSavedCameraRecord) -> String {
        SavedCameraPathGroups.pathLabel(for: PTPIPSavedCameraRecords.typed(legacy)[0])
    }
    #expect(label(record(host: "usb:demo", transport: "USB-C")) == "USB-C")
    #expect(label(record(host: "172.20.10.2")) == "Hotspot")
    #expect(label(record(host: "10.99.0.20", ap: false)) == "Router")
    #expect(label(record(host: "192.168.1.1", ap: true)) == "Camera AP")
    // No evidence ever → the migration lands it on infrastructure, and the chip says so.
    #expect(label(record(host: "192.168.1.1")) == "Router")
}

/// The serial survives the canonicalizing merge the way the evidence field does: an update
/// that carries none must never erase the one a connect recorded.
@Test func serialNumberSurvivesTheCanonicalizingMerge() {
    let stamped = record(host: "10.99.0.20", seen: 100, serial: "6002199")
    let records = PTPIPSavedCameraRecords.upserting(
        host: "10.99.0.20",
        displayName: "ZR_6002199",
        transport: "Wi-Fi",
        lastSeenAt: Date(timeIntervalSince1970: 200),
        into: [stamped]
    )
    #expect(records.count == 1)
    #expect(records.first?.serialNumber == "6002199")
}

/// Canonicalization must KEEP same-name records whose path kinds differ — hotspot, router and
/// cable for one body are three records on purpose. Before this, the cross-host name merge
/// collapsed them to the newest and multi-path could never exist.
@Test func canonicalizedKeepsDistinctPathKindsForOneBody() {
    let records = PTPIPSavedCameraRecords.canonicalized([
        record(host: "172.20.10.2", seen: 100, ap: false, serial: "6002199"),
        record(host: "10.99.0.20", seen: 200, ap: false, serial: "6002199"),
        record(host: "usb:demo", transport: "USB-C", seen: 300, serial: "6002199"),
    ])
    #expect(records.count == 3)
}

/// The DHCP-move merge survives WITHIN a kind: the router path re-leasing a new address stays
/// one record (the newest), not a chip per stale IP.
@Test func canonicalizedStillAbsorbsADHCPMoveWithinOneKind() {
    let records = PTPIPSavedCameraRecords.canonicalized([
        record(host: "10.99.0.20", seen: 100, ap: false, serial: "6002199"),
        record(host: "10.99.0.31", seen: 200, ap: false, serial: "6002199"),
    ])
    #expect(records.count == 1)
    #expect(records.first?.host == "10.99.0.31")
}

/// Two different stamped serials never merge, whatever the names claim.
@Test func canonicalizedRefusesToMergeDifferentSerials() {
    let records = PTPIPSavedCameraRecords.canonicalized([
        record(host: "10.99.0.20", name: "ZR", seen: 100, ap: false, serial: "6002199"),
        record(host: "10.99.0.31", name: "ZR", seen: 200, ap: false, serial: "7005555"),
    ])
    #expect(records.count == 2)
}

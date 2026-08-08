import Foundation
import Testing

@testable import OpenZCineCore

// MARK: - The type itself

@Test func cameraPathRoundTripsThroughCodable() throws {
    let paths: [CameraPath] = [
        .cameraAccessPoint(ssid: "NIKON_ZR_02199"),
        .cameraAccessPoint(ssid: nil),
        .infrastructure(networkName: "Studio 5G"),
        .infrastructure(networkName: nil),
        .phoneHotspot,
        .usbC,
        .hdmiCapture,
    ]
    let decoded = try JSONDecoder().decode(
        [CameraPath].self, from: JSONEncoder().encode(paths))
    #expect(decoded == paths)
}

@Test func cameraPathKindsCoverEveryCase() {
    #expect(CameraPath.cameraAccessPoint(ssid: "X").kind == .cameraAccessPoint)
    #expect(CameraPath.infrastructure(networkName: "X").kind == .infrastructure)
    #expect(CameraPath.phoneHotspot.kind == .phoneHotspot)
    #expect(CameraPath.usbC.kind == .usbC)
    #expect(CameraPath.hdmiCapture.kind == .hdmiCapture)
}

@Test func recordsWithoutThePathFieldStillDecode() throws {
    // The exact payload every install upgrades from: no `path` key anywhere.
    let legacyJSON = """
        [{"host":"192.168.1.240","displayName":"ZR_6002199","transport":"Wi-Fi",
        "pairedViaCameraAccessPoint":true,"serialNumber":"6002199"}]
        """
    let records = try JSONDecoder().decode(
        [PTPIPSavedCameraRecord].self, from: Data(legacyJSON.utf8))
    #expect(records.count == 1)
    #expect(records[0].path == nil)
}

// MARK: - One-time migration (`typed`)

@Test func migrationTypesUSBRecordsByHostKeyAndByLabel() {
    let byHost = PTPIPSavedCameraRecord(
        host: "usb:0x1234", displayName: "ZR_6002199", transport: "Wi-Fi", lastSeenAt: nil)
    let byLabel = PTPIPSavedCameraRecord(
        host: "usb:0x9999", displayName: "ZR_6002199", transport: "USB-C", lastSeenAt: nil)
    #expect(PTPIPSavedCameraRecords.typed(byHost).map(\.path) == [.usbC])
    #expect(PTPIPSavedCameraRecords.typed(byLabel).map(\.path) == [.usbC])
}

@Test func migrationTypesHotspotRecordsByHostSubnet() {
    let record = PTPIPSavedCameraRecord(
        host: "172.20.10.8", displayName: "ZR_6002199", transport: "Wi-Fi", lastSeenAt: nil)
    #expect(PTPIPSavedCameraRecords.typed(record).map(\.path) == [.phoneHotspot])
}

@Test func migrationTypesEvidencelessRecordsAsInfrastructure() {
    // `nil` evidence was the common case — most connects cannot read the SSID. Infrastructure
    // is the safe landing: it never prompts a Wi-Fi join, which is exactly the historical
    // behavior the join gate enforced for unproven records.
    let record = PTPIPSavedCameraRecord(
        host: "192.168.1.240", displayName: "ZR_6002199", transport: "Wi-Fi", lastSeenAt: nil)
    #expect(
        PTPIPSavedCameraRecords.typed(record).map(\.path)
            == [.infrastructure(networkName: nil)])
}

@Test func migrationTypesAccessPointProvenRecordAtTheAPAddress() {
    let record = PTPIPSavedCameraRecord(
        host: "192.168.1.1", displayName: "ZR_6002199", transport: "Wi-Fi", lastSeenAt: nil,
        presentation: PTPIPSavedCameraPresentation(wifiSSID: "NIKON_ZR_02199"),
        pairedViaCameraAccessPoint: true)
    let typed = PTPIPSavedCameraRecords.typed(record)
    #expect(typed.count == 1)
    #expect(typed[0].path == .cameraAccessPoint(ssid: "NIKON_ZR_02199"))
    #expect(typed[0].host == "192.168.1.1")
}

/// The un-poisoning: a historically merged record carrying a router host under an AP stamp —
/// the shape behind every recurring "join NIKON_…" prompt on router connects — splits into the
/// two setups it always described.
@Test func migrationSplitsThePoisonedMergedRecordIntoAPAndInfrastructureSetups() {
    let poisoned = PTPIPSavedCameraRecord(
        host: "192.168.1.246", displayName: "ZR_6002199", transport: "Wi-Fi",
        lastSeenAt: Date(timeIntervalSince1970: 1_700_000_000),
        presentation: PTPIPSavedCameraPresentation(wifiSSID: "NIKON_ZR_02199"),
        pairedViaCameraAccessPoint: true,
        serialNumber: "6002199")

    let typed = PTPIPSavedCameraRecords.typed(poisoned)

    #expect(typed.count == 2)
    let ap = typed.first { $0.path?.kind == .cameraAccessPoint }
    let infra = typed.first { $0.path?.kind == .infrastructure }
    // The AP setup lives at the AP's fixed address, with the camera's own SSID.
    #expect(ap?.host == CameraDiscovery.nikonZRAccessPointHost)
    #expect(ap?.path == .cameraAccessPoint(ssid: "NIKON_ZR_02199"))
    // The router path keeps the host the camera actually had on that network.
    #expect(infra?.host == "192.168.1.246")
    // Both setups keep the camera's identity.
    #expect(typed.allSatisfy { $0.serialNumber == "6002199" })
}

@Test func migrationDerivesTheAPSSIDFromTheCameraNameWhenUnstamped() {
    let record = PTPIPSavedCameraRecord(
        host: "192.168.1.1", displayName: "ZR_6002199", transport: "Wi-Fi", lastSeenAt: nil,
        pairedViaCameraAccessPoint: true)
    let typed = PTPIPSavedCameraRecords.typed(record)
    #expect(typed.count == 1)
    if case .cameraAccessPoint(let ssid)? = typed[0].path {
        #expect(ssid?.hasPrefix("NIKON_") == true)
    } else {
        Issue.record("expected an access-point path, got \(String(describing: typed[0].path))")
    }
}

@Test func migrationLeavesAlreadyTypedRecordsAlone() {
    let record = PTPIPSavedCameraRecord(
        host: "192.168.1.246", displayName: "ZR_6002199", transport: "Wi-Fi", lastSeenAt: nil,
        pairedViaCameraAccessPoint: true,
        path: .infrastructure(networkName: "Studio 5G"))
    #expect(PTPIPSavedCameraRecords.typed(record) == [record])
}

@Test func canonicalizingTwiceIsAFixedPoint() {
    let records = [
        PTPIPSavedCameraRecord(
            host: "192.168.1.246", displayName: "ZR_6002199", transport: "Wi-Fi",
            lastSeenAt: nil,
            presentation: PTPIPSavedCameraPresentation(wifiSSID: "NIKON_ZR_02199"),
            pairedViaCameraAccessPoint: true, serialNumber: "6002199"),
        PTPIPSavedCameraRecord(
            host: "usb:0x1234", displayName: "ZR_6002199", transport: "USB-C",
            lastSeenAt: nil, serialNumber: "6002199"),
    ]
    let once = PTPIPSavedCameraRecords.canonicalized(records)
    #expect(PTPIPSavedCameraRecords.canonicalized(once) == once)
    #expect(once.allSatisfy { $0.path != nil })
}

// MARK: - Kind-keyed setups

@Test func upsertingWithAPathUpdatesTheSameKindRowInPlace() {
    let records = PTPIPSavedCameraRecords.upserting(
        host: "192.168.1.240", displayName: "ZR_6002199", transport: "Wi-Fi",
        lastSeenAt: Date(timeIntervalSince1970: 1_700_000_000),
        serialNumber: "6002199",
        path: .infrastructure(networkName: nil),
        into: [])

    // The camera moved to a new DHCP lease on the same network: same kind, host updates.
    let moved = PTPIPSavedCameraRecords.upserting(
        host: "192.168.1.77", displayName: "ZR_6002199", transport: "Wi-Fi",
        lastSeenAt: Date(timeIntervalSince1970: 1_700_000_500),
        serialNumber: "6002199",
        path: .infrastructure(networkName: nil),
        into: records)
    #expect(moved.count == 1)
    #expect(moved[0].host == "192.168.1.77")

    // The same camera declared over its own AP: a different kind, a second row.
    let withAP = PTPIPSavedCameraRecords.upserting(
        host: "192.168.1.1", displayName: "ZR_6002199", transport: "Wi-Fi",
        lastSeenAt: Date(timeIntervalSince1970: 1_700_001_000),
        serialNumber: "6002199",
        path: .cameraAccessPoint(ssid: "NIKON_ZR_02199"),
        into: moved)
    #expect(withAP.count == 2)
    #expect(Set(withAP.compactMap(\.pathKind)) == [.infrastructure, .cameraAccessPoint])
}

@Test func sameKindMergeKeepsTheRicherPathPayload() {
    let known = PTPIPSavedCameraRecords.upserting(
        host: "192.168.1.1", displayName: "ZR_6002199", transport: "Wi-Fi",
        lastSeenAt: Date(timeIntervalSince1970: 1_700_000_000),
        serialNumber: "6002199",
        path: .cameraAccessPoint(ssid: "NIKON_ZR_02199"),
        into: [])

    // A refresh that no longer knows the SSID must not erase it.
    let refreshed = PTPIPSavedCameraRecords.upserting(
        host: "192.168.1.1", displayName: "ZR_6002199", transport: "Wi-Fi",
        lastSeenAt: Date(timeIntervalSince1970: 1_700_000_500),
        serialNumber: "6002199",
        path: .cameraAccessPoint(ssid: nil),
        into: known)
    #expect(refreshed.count == 1)
    #expect(refreshed[0].path == .cameraAccessPoint(ssid: "NIKON_ZR_02199"))
}

@Test func recordIDsStayDistinctAcrossOneCamerasSetups() {
    let records = [
        PTPIPSavedCameraRecord(
            host: "192.168.1.1", displayName: "ZR_6002199", transport: "Wi-Fi",
            lastSeenAt: nil, path: .cameraAccessPoint(ssid: "NIKON_ZR_02199")),
        PTPIPSavedCameraRecord(
            host: "192.168.1.1", displayName: "ZR_6002199", transport: "Wi-Fi",
            lastSeenAt: nil, path: .infrastructure(networkName: nil)),
    ]
    #expect(Set(records.map(\.id)).count == 2)
}

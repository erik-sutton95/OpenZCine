import Foundation
import Testing

@testable import OpenZCineCore

@Test func savedCameraRecordsUpsertCanonicalizesAndPreservesMetadata() {
    let oldSeen = Date(timeIntervalSince1970: 1_700_000_000)
    let newSeen = Date(timeIntervalSince1970: 1_800_000_000)
    // The saved record's name is unknown (pre-identify pairing writes an empty display name), so
    // the refreshed connection with the real name merges into it rather than duplicating.
    let records = [
        PTPIPSavedCameraRecord(
            host: " 192.168.1.42 ",
            displayName: "",
            transport: "Wi-Fi",
            lastSeenAt: oldSeen
        )
    ]

    let updated = PTPIPSavedCameraRecords.upserting(
        host: "192.168.1.42",
        displayName: "Nikon ZR",
        transport: "Wi-Fi",
        lastSeenAt: newSeen,
        into: records
    )

    #expect(
        updated == [
            PTPIPSavedCameraRecord(
                host: "192.168.1.42",
                displayName: "Nikon ZR",
                transport: "Wi-Fi",
                lastSeenAt: newSeen,
                path: .infrastructure(networkName: nil)
            )
        ])
}

/// The #293 report: pairing a second body removed the first. Every camera-AP Nikon is
/// 192.168.1.1, so both records share one address — a shared host must merge records only when
/// the names don't contradict it, and forgetting one of the two must not delete the other.
@Test func savedCameraRecordsKeepTwoBodiesSharingTheAccessPointAddress() {
    let seen = Date(timeIntervalSince1970: 1_800_000_000)
    let records = PTPIPSavedCameraRecords.upserting(
        host: "192.168.1.1",
        displayName: "Z 6III_1234567",
        transport: "Wi-Fi",
        lastSeenAt: seen,
        into: []
    )

    let both = PTPIPSavedCameraRecords.upserting(
        host: "192.168.1.1",
        displayName: "Z 5_7654321",
        transport: "Wi-Fi",
        lastSeenAt: seen.addingTimeInterval(60),
        into: records
    )
    #expect(both.map(\.displayName) == ["Z 6III_1234567", "Z 5_7654321"])
    // Distinct SwiftUI identities even on the shared address.
    #expect(Set(both.map(\.id)).count == 2)

    // Forgetting the Z 5 by name leaves the Z 6III standing; the nameless form keeps its old
    // remove-everything-at-this-host meaning for callers that predate the collision fix.
    let afterForget = PTPIPSavedCameraRecords.removing(
        "192.168.1.1", displayName: "Z 5_7654321", from: both)
    #expect(afterForget.map(\.displayName) == ["Z 6III_1234567"])
}

@Test func savedCameraRecordsAppendNewRecordsAndRemoveInvalidDuplicates() {
    let seen = Date(timeIntervalSince1970: 1_800_000_000)
    let records = [
        PTPIPSavedCameraRecord(host: " ", displayName: "", transport: "Wi-Fi", lastSeenAt: nil),
        PTPIPSavedCameraRecord(
            host: "192.168.1.42",
            displayName: "Nikon ZR",
            transport: "Wi-Fi",
            lastSeenAt: seen
        ),
        PTPIPSavedCameraRecord(
            host: " 192.168.1.42 ",
            displayName: "Nikon ZR",
            transport: "Wi-Fi",
            lastSeenAt: nil
        ),
    ]

    let updated = PTPIPSavedCameraRecords.upserting(
        host: "172.20.10.15",
        displayName: "Studio ZR",
        transport: "Wi-Fi",
        lastSeenAt: seen,
        into: records
    )

    #expect(updated.map(\.host) == ["192.168.1.42", "172.20.10.15"])
    #expect(updated.map(\.displayName) == ["Nikon ZR", "Studio ZR"])
}

@Test func savedCameraRecordsUpsertSameCameraNewPathKindAddsASecondPath() {
    // Historically the camera-AP upsert REPLACED the hotspot record ("the camera moved").
    // Hotspot and camera AP are different PATH KINDS the operator deliberately switches
    // between, so both survive now — path grouping presents them as one row.
    let oldSeen = Date(timeIntervalSince1970: 1_700_000_000)
    let newSeen = Date(timeIntervalSince1970: 1_800_000_000)
    let records = [
        PTPIPSavedCameraRecord(
            host: "172.20.10.8",
            displayName: "ZR_6001234",
            transport: "iPhone hotspot",
            lastSeenAt: oldSeen,
            presentation: PTPIPSavedCameraPresentation(
                customName: "A Cam",
                borderColor: "blue",
                icon: "a"
            )
        )
    ]

    let updated = PTPIPSavedCameraRecords.upserting(
        host: "192.168.1.1",
        displayName: "ZR_6001234",
        transport: "Camera AP",
        lastSeenAt: newSeen,
        into: records
    )

    #expect(updated.count == 2)
    #expect(updated.contains { $0.host == "172.20.10.8" })
    #expect(updated.contains { $0.host == "192.168.1.1" })
    // The hotspot path keeps its own presentation; the row-level title falls back across the
    // group, and renames apply to every path.
    #expect(
        updated.first { $0.host == "172.20.10.8" }?.presentation?.customName == "A Cam")
}

@Test func savedCameraRecordsUpdatePresentationNormalizesUserMetadata() {
    let records = [
        PTPIPSavedCameraRecord(
            host: "192.168.1.1",
            displayName: "ZR_6001234",
            transport: "Wi-Fi",
            lastSeenAt: nil
        )
    ]

    let updated = PTPIPSavedCameraRecords.updatingPresentation(
        host: " 192.168.1.1 ",
        customName: "  A Cam  ",
        borderColor: " green ",
        icon: " b ",
        in: records
    )

    #expect(updated[0].displayTitle == "A Cam")
    #expect(
        updated[0].presentation
            == PTPIPSavedCameraPresentation(customName: "A Cam", borderColor: "green", icon: "b")
    )
}

@Test func savedCameraRecordsUpdatePresentationFallsBackToCameraNameWhenCustomNameIsEmpty() {
    let records = [
        PTPIPSavedCameraRecord(
            host: "192.168.1.1",
            displayName: "ZR_6001234",
            transport: "Wi-Fi",
            lastSeenAt: nil,
            presentation: PTPIPSavedCameraPresentation(
                customName: "A Cam",
                borderColor: "blue",
                icon: "a"
            )
        )
    ]

    let updated = PTPIPSavedCameraRecords.updatingPresentation(
        host: "192.168.1.1",
        customName: " ",
        borderColor: "amber",
        icon: "viewfinder",
        in: records
    )

    #expect(updated[0].displayTitle == "ZR_6001234")
    #expect(
        updated[0].presentation
            == PTPIPSavedCameraPresentation(
                customName: nil,
                borderColor: "amber",
                icon: "viewfinder"
            )
    )
}

@Test func savedCameraRecordsCanonicalizedKeepsSameCameraDistinctPathKinds() {
    // Pre-multi-path this collapsed to the newest record. A hotspot record and a camera-AP
    // record for one body are two PATHS now; only a same-kind DHCP move still merges (see
    // canonicalizedStillAbsorbsADHCPMoveWithinOneKind).
    let oldSeen = Date(timeIntervalSince1970: 1_700_000_000)
    let newSeen = Date(timeIntervalSince1970: 1_800_000_000)
    let records = [
        PTPIPSavedCameraRecord(
            host: "172.20.10.8",
            displayName: "ZR_6001234",
            transport: "iPhone hotspot",
            lastSeenAt: oldSeen
        ),
        PTPIPSavedCameraRecord(
            host: "192.168.1.1",
            displayName: "ZR_6001234",
            transport: "Camera AP",
            lastSeenAt: newSeen
        ),
    ]

    let canonical = PTPIPSavedCameraRecords.canonicalized(records)

    #expect(canonical.count == 2)
    #expect(canonical.contains { $0.host == "172.20.10.8" })
    #expect(canonical.contains { $0.host == "192.168.1.1" })
}

@Test func savedCameraRecordsDoNotCollapseGenericModelNamesAcrossHosts() {
    let oldSeen = Date(timeIntervalSince1970: 1_700_000_000)
    let newSeen = Date(timeIntervalSince1970: 1_800_000_000)
    let records = [
        PTPIPSavedCameraRecord(
            host: "172.20.10.8",
            displayName: "Nikon ZR",
            transport: "iPhone hotspot",
            lastSeenAt: oldSeen
        ),
        PTPIPSavedCameraRecord(
            host: "192.168.1.1",
            displayName: "Nikon ZR",
            transport: "Camera AP",
            lastSeenAt: newSeen
        ),
    ]

    let canonical = PTPIPSavedCameraRecords.canonicalized(records)

    // Both hosts survive; canonicalization also stamps each record's declared path, so compare
    // the identity axes rather than the whole value.
    #expect(canonical.map(\.host) == records.map(\.host))
    #expect(canonical.map(\.displayName) == records.map(\.displayName))
}

@Test func savedCameraRecordsRemoveByCanonicalHost() {
    let records = [
        PTPIPSavedCameraRecord(
            host: "192.168.1.42",
            displayName: "Nikon ZR",
            transport: "Wi-Fi",
            lastSeenAt: nil
        ),
        PTPIPSavedCameraRecord(
            host: "172.20.10.15",
            displayName: "Studio ZR",
            transport: "Wi-Fi",
            lastSeenAt: nil
        ),
    ]

    #expect(
        PTPIPSavedCameraRecords.removing(" 192.168.1.42 ", from: records).map(\.host)
            == ["172.20.10.15"])
}

@Test func savedCameraAvailabilityUsesActiveSessionBeforeLastSeen() {
    let camera = PTPIPSavedCameraRecord(
        host: "192.168.1.1",
        displayName: "ZR_6001234",
        transport: "Wi-Fi",
        lastSeenAt: Date(timeIntervalSince1970: 1_700_000_000)
    )

    let status = SavedCameraAvailabilityPolicy.resolve(
        camera: camera,
        discoveredCameras: [],
        connectedHost: " 192.168.1.1 "
    )

    #expect(status == .connected)
}

@Test func savedCameraAvailabilityUsesCurrentDiscoveryBeforeLastSeen() {
    let camera = PTPIPSavedCameraRecord(
        host: "172.20.10.8",
        displayName: "ZR_6001234",
        transport: "Wi-Fi",
        lastSeenAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let discovered = DiscoveredCamera(ip: "172.20.10.8", name: "ZR_6001234", source: .bonjour)

    let status = SavedCameraAvailabilityPolicy.resolve(
        camera: camera,
        discoveredCameras: [discovered],
        connectedHost: nil
    )

    #expect(status == .available(discovered))
}

@Test func savedCameraAvailabilityCanFollowCameraNameAfterAddressChanges() {
    let camera = PTPIPSavedCameraRecord(
        host: "172.20.10.8",
        displayName: "ZR_6001234",
        transport: "Wi-Fi",
        lastSeenAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let discovered = DiscoveredCamera(ip: "172.20.10.15", name: "ZR_6001234", source: .bonjour)

    let status = SavedCameraAvailabilityPolicy.resolve(
        camera: camera,
        discoveredCameras: [discovered],
        connectedHost: nil
    )

    #expect(status == .available(discovered))
}

@Test func savedCameraAvailabilityFallsBackToOfflineWhenNotSeen() {
    let camera = PTPIPSavedCameraRecord(
        host: "172.20.10.8",
        displayName: "ZR_6001234",
        transport: "Wi-Fi",
        lastSeenAt: Date(timeIntervalSince1970: 1_700_000_000)
    )

    let status = SavedCameraAvailabilityPolicy.resolve(
        camera: camera,
        discoveredCameras: [
            DiscoveredCamera(ip: "172.20.10.9", name: "Other", source: .subnetProbe)
        ],
        connectedHost: nil
    )

    #expect(status == .offline)
}

/// The multi-path regression, from set: a router connect (SSID unreadable, so evidence nil) was
/// swallowed INTO the same body's camera-AP record by the cross-host merge. One merged record then
/// ping-ponged its evidence stamp with every connect — prompting "join NIKON_…" on the router path
/// and silently skipping the join on the AP path. An AP-proven record and an unproven record are
/// two PATHS of one camera: separate records, grouped as one row by `SavedCameraPathGroups`.
@Test func routerConnectDoesNotMergeIntoTheAccessPointRecord() {
    let apRecord = PTPIPSavedCameraRecord(
        host: "192.168.1.1",
        displayName: "ZR_6002199",
        transport: "Wi-Fi",
        lastSeenAt: Date(timeIntervalSince1970: 1_700_000_000),
        pairedViaCameraAccessPoint: true,
        serialNumber: "6002199"
    )

    let records = PTPIPSavedCameraRecords.upserting(
        host: "10.99.0.20",
        displayName: "ZR_6002199",
        transport: "Wi-Fi",
        lastSeenAt: Date(timeIntervalSince1970: 1_700_000_500),
        pairedViaCameraAccessPoint: nil,
        serialNumber: "6002199",
        into: [apRecord]
    )

    #expect(records.count == 2)
    #expect(records.contains { $0.host == "192.168.1.1" && $0.pairedViaCameraAccessPoint == true })
    #expect(records.contains { $0.host == "10.99.0.20" })
}

/// The healing the evidence leniency exists for: a legacy record (nil evidence) absorbing the same
/// camera's DHCP move on the same network shape — neither record is AP-proven, so they merge.
@Test func legacyRouterRecordAbsorbsADHCPMove() {
    let legacy = PTPIPSavedCameraRecord(
        host: "10.99.0.20",
        displayName: "ZR_6002199",
        transport: "Wi-Fi",
        lastSeenAt: Date(timeIntervalSince1970: 1_700_000_000)
    )

    let records = PTPIPSavedCameraRecords.upserting(
        host: "10.99.0.57",
        displayName: "ZR_6002199",
        transport: "Wi-Fi",
        lastSeenAt: Date(timeIntervalSince1970: 1_700_000_500),
        pairedViaCameraAccessPoint: false,
        into: [legacy]
    )

    #expect(records.map(\.host) == ["10.99.0.57"])
}

/// A host cannot identify a setup, and this is the test that says so out loud.
///
/// Every camera-AP Nikon answers at 192.168.1.1, and a home router hands out that same address —
/// so one body's AP and Router setups legitimately collide on `host`. The connect pipeline used to
/// re-derive "which setup am I dialling" with `savedCameras.first { $0.host == host }`, which
/// silently returned whichever was saved first: tapping Camera AP ran the Router's branch, so the
/// join was never offered and the dial went out on the wrong network.
@Test func oneHostCanNameTwoSetupsSoItCannotIdentifyOne() {
    let shared = "192.168.1.1"
    let records = PTPIPSavedCameraRecords.canonicalized([
        PTPIPSavedCameraRecord(
            host: shared,
            displayName: "ZR_6002199",
            transport: "Wi-Fi",
            lastSeenAt: nil,
            serialNumber: "6002199",
            path: .infrastructure(networkName: "Home")
        ),
        PTPIPSavedCameraRecord(
            host: shared,
            displayName: "ZR_6002199",
            transport: "Wi-Fi",
            lastSeenAt: nil,
            serialNumber: "6002199",
            path: .cameraAccessPoint(ssid: "NIKON_ZR_6002199")
        ),
    ])

    // Both survive: canonicalization keys on the declared path, not the address.
    #expect(records.count == 2)
    let ids = Set(records.map { $0.id })
    #expect(ids.count == 2)
    // And the lookup the connect pipeline must never make is ambiguous by construction.
    #expect(records.filter { $0.host == shared }.count == 2)
}

/// An access-point setup lives at the AP's fixed address, and a record that says otherwise is
/// repaired even though it already carries a declared path.
///
/// The migration split only ever ran on UNTYPED records, so a record poisoned after being typed
/// had nothing left to repair it: the post-pairing rejoin left the join flag set while the camera
/// came back on the house network, and the session that landed there was saved as an AP setup
/// holding a router address. Tapping it dialled an address the camera never answers on, and the
/// join that would have fixed it was suppressed — the app believed it already had the AP setup.
@Test func aTypedAccessPointSetupOnAForeignHostIsSplitApart() {
    let records = PTPIPSavedCameraRecords.canonicalized([
        PTPIPSavedCameraRecord(
            host: "192.168.1.246",
            displayName: "ZR_6002199",
            transport: "Wi-Fi",
            lastSeenAt: nil,
            serialNumber: "6002199",
            path: .cameraAccessPoint(ssid: "NIKON_ZR_6002199")
        )
    ])

    let accessPoint = records.first { $0.path?.kind == .cameraAccessPoint }
    let infrastructure = records.first { $0.path?.kind == .infrastructure }
    // The AP setup is pinned to the AP's address, keeping the SSID it needs to offer the join.
    #expect(accessPoint?.host == CameraDiscovery.nikonZRAccessPointHost)
    #expect(accessPoint?.path?.accessPointSSID == "NIKON_ZR_6002199")
    // The foreign address becomes the router setup it always described, rather than vanishing.
    #expect(infrastructure?.host == "192.168.1.246")
}

/// A well-formed access-point setup is left exactly as it is — the repair must not fire on the
/// records it exists to protect.
@Test func aTypedAccessPointSetupAtItsOwnAddressIsUntouched() {
    let record = PTPIPSavedCameraRecord(
        host: CameraDiscovery.nikonZRAccessPointHost,
        displayName: "ZR_6002199",
        transport: "Wi-Fi",
        lastSeenAt: nil,
        serialNumber: "6002199",
        path: .cameraAccessPoint(ssid: "NIKON_ZR_6002199")
    )
    let records = PTPIPSavedCameraRecords.canonicalized([record])
    #expect(records.count == 1)
    #expect(records.first?.path?.kind == .cameraAccessPoint)
    #expect(records.first?.host == CameraDiscovery.nikonZRAccessPointHost)
}

import Foundation
import Testing

@testable import OpenZCineCore

@Test func savedCameraRecordsUpsertCanonicalizesAndPreservesMetadata() {
    let oldSeen = Date(timeIntervalSince1970: 1_700_000_000)
    let newSeen = Date(timeIntervalSince1970: 1_800_000_000)
    let records = [
        PTPIPSavedCameraRecord(
            host: " 192.168.1.42 ",
            displayName: "Old Name",
            transport: "USB-C",
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
                lastSeenAt: newSeen
            )
        ])
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
            displayName: "Duplicate",
            transport: "USB-C",
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

@Test func savedCameraRecordsUpsertSameCameraNameUpdatesHostAndTransport() {
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

    #expect(
        updated == [
            PTPIPSavedCameraRecord(
                host: "192.168.1.1",
                displayName: "ZR_6001234",
                transport: "Camera AP",
                lastSeenAt: newSeen,
                presentation: PTPIPSavedCameraPresentation(
                    customName: "A Cam",
                    borderColor: "blue",
                    icon: "a"
                )
            )
        ])
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

@Test func savedCameraRecordsCanonicalizedCollapsesExistingSameCameraNameDuplicates() {
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

    #expect(
        canonical == [
            PTPIPSavedCameraRecord(
                host: "192.168.1.1",
                displayName: "ZR_6001234",
                transport: "Camera AP",
                lastSeenAt: newSeen
            )
        ])
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

    #expect(canonical == records)
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

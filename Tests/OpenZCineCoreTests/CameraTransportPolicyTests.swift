import Foundation
import Testing

@testable import OpenZCineCore

@Test func transportKindMapsToSavedRecordLabels() {
    #expect(CameraTransportKind.ptpIP.savedRecordLabel == "Wi-Fi")
    #expect(CameraTransportKind.usb.savedRecordLabel == "USB-C")
}

@Test func dedupeKeepsUSBCamerasAheadOfNetworkCameras() {
    let cameras = [
        DiscoveredCamera(ip: "192.168.1.20", name: "Wi-Fi ZR", source: .bonjour),
        DiscoveredCamera(ip: "usb:ABC123", name: "Tethered ZR", source: .usb),
        DiscoveredCamera(ip: "192.168.1.4", name: "Second ZR", source: .subnetProbe),
    ]

    let deduped = CameraDiscovery.dedupeAndSort(cameras)

    #expect(deduped.map(\.ip) == ["usb:ABC123", "192.168.1.4", "192.168.1.20"])
}

@Test func dedupeDropsDuplicateUSBEntries() {
    let cameras = [
        DiscoveredCamera(ip: "usb:ABC123", name: "Tethered ZR", source: .usb),
        DiscoveredCamera(ip: "usb:ABC123", name: "Tethered ZR", source: .usb),
    ]

    #expect(CameraDiscovery.dedupeAndSort(cameras).count == 1)
}

@Test func usbHostKeysAreNotValidNetworkScanTargets() {
    #expect(!CameraDiscovery.isPrivateIPv4("usb:ABC123"))
    #expect(!CameraDiscovery.isDefaultScanIPv4("usb:ABC123"))
}

@Test func savedRecordDetectsUSBTransportByLabelAndHostKey() {
    let byLabel = PTPIPSavedCameraRecord(
        host: "usb:abc123",
        displayName: "ZR",
        transport: "USB-C",
        lastSeenAt: nil
    )
    let byHostOnly = PTPIPSavedCameraRecord(
        host: "usb:abc123",
        displayName: "ZR",
        transport: "Wi-Fi",
        lastSeenAt: nil
    )
    let wifi = PTPIPSavedCameraRecord(
        host: "192.168.1.4",
        displayName: "ZR",
        transport: "Wi-Fi",
        lastSeenAt: nil
    )

    #expect(byLabel.isUSBTransport)
    #expect(byHostOnly.isUSBTransport)
    #expect(!wifi.isUSBTransport)
}

@Test func usbHostKeysSurviveSavedRecordCanonicalization() {
    let records = PTPIPSavedCameraRecords.upserting(
        host: "usb:ABC123",
        displayName: "Nikon ZR",
        transport: "USB-C",
        lastSeenAt: Date(),
        into: []
    )

    #expect(records.count == 1)
    #expect(records[0].host == "usb:abc123")
    #expect(records[0].transport == "USB-C")
}

@Test func unknownUSBCameraProbesBeforePairing() {
    let strategy = CameraStartupPolicy.connectionStrategy(
        host: "usb:abc123",
        savedCameras: [],
        transportKind: .usb
    )

    #expect(strategy == .restoreCameraProfileBeforePairing)
}

@Test func savedUSBCameraReconnectsSilently() {
    let saved = PTPIPSavedCameraRecord(
        host: "usb:abc123",
        displayName: "Nikon ZR",
        transport: "USB-C",
        lastSeenAt: Date()
    )

    let strategy = CameraStartupPolicy.connectionStrategy(
        host: "usb:ABC123",
        savedCameras: [saved],
        transportKind: .usb
    )

    #expect(strategy == .savedProfile)
}

@Test func unknownNetworkCameraStillPairsFirst() {
    let strategy = CameraStartupPolicy.connectionStrategy(
        host: "192.168.1.4",
        savedCameras: []
    )

    #expect(strategy == .firstTimePairing)
}

@Test func savedCameraLookupMatchesDiscoveredUSBCameraByHostKey() {
    let saved = PTPIPSavedCameraRecord(
        host: "usb:abc123",
        displayName: "Nikon ZR",
        transport: "USB-C",
        lastSeenAt: Date()
    )
    let discovered = DiscoveredCamera(ip: "usb:ABC123", name: "Nikon ZR", source: .usb)

    let match = CameraStartupPolicy.savedCamera(forDiscovered: discovered, in: [saved])

    #expect(match?.host == "usb:abc123")
}

@Test func savedCameraLookupIgnoresUnrelatedCameras() {
    let saved = PTPIPSavedCameraRecord(
        host: "192.168.1.4",
        displayName: "Camera 192.168.1.4",
        transport: "Wi-Fi",
        lastSeenAt: Date()
    )
    let discovered = DiscoveredCamera(ip: "usb:ABC123", name: "PTP-IP Camera", source: .usb)

    #expect(CameraStartupPolicy.savedCamera(forDiscovered: discovered, in: [saved]) == nil)
}

@Test func savedUSBCameraAvailabilityResolvesFromUSBDiscovery() {
    let saved = PTPIPSavedCameraRecord(
        host: "usb:abc123",
        displayName: "Nikon ZR",
        transport: "USB-C",
        lastSeenAt: Date()
    )
    let discovered = DiscoveredCamera(ip: "usb:ABC123", name: "Nikon ZR", source: .usb)

    let availability = SavedCameraAvailabilityPolicy.resolve(
        camera: saved,
        discoveredCameras: [discovered],
        connectedHost: nil
    )

    #expect(availability == .available(discovered))
}

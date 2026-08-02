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

@Test func routerSetupReadsOfflineWhileOnTheCameraAccessPoint() {
    // On the camera's own AP the body is discovered — over a network the router setup
    // cannot use. The name-match fallback must not light it.
    let router = PTPIPSavedCameraRecord(
        host: "192.168.1.20",
        displayName: "ZR_6002199",
        transport: "Wi-Fi",
        lastSeenAt: Date(),
        path: .infrastructure(networkName: "StudioNet")
    )
    let overAP = DiscoveredCamera(ip: "192.168.0.1", name: "ZR_6002199", source: .bonjour)

    #expect(
        SavedCameraAvailabilityPolicy.resolve(
            camera: router,
            discoveredCameras: [overAP],
            connectedHost: nil,
            onCameraAccessPoint: true
        ) == .offline)
    // Off the AP the same discovery keeps lighting it (the DHCP-moved-host case).
    #expect(
        SavedCameraAvailabilityPolicy.resolve(
            camera: router,
            discoveredCameras: [overAP],
            connectedHost: nil,
            onCameraAccessPoint: false
        ) == .available(overAP))
    // The AP setup itself, and cable paths, are untouched by the flag.
    let apSetup = PTPIPSavedCameraRecord(
        host: "192.168.0.1",
        displayName: "ZR_6002199",
        transport: "Wi-Fi",
        lastSeenAt: Date(),
        path: .cameraAccessPoint(ssid: "NikonZR_123")
    )
    #expect(
        SavedCameraAvailabilityPolicy.resolve(
            camera: apSetup,
            discoveredCameras: [overAP],
            connectedHost: nil,
            onCameraAccessPoint: true
        ) == .available(overAP))
    let usb = PTPIPSavedCameraRecord(
        host: "usb:abc123",
        displayName: "ZR_6002199",
        transport: "USB-C",
        lastSeenAt: Date(),
        path: .usbC
    )
    let usbDiscovered = DiscoveredCamera(ip: "usb:ABC123", name: "ZR_6002199", source: .usb)
    #expect(
        SavedCameraAvailabilityPolicy.resolve(
            camera: usb,
            discoveredCameras: [usbDiscovered],
            connectedHost: nil,
            onCameraAccessPoint: true
        ) == .available(usbDiscovered))
}

@Test func hotspotDiscoveryLightsOnlyTheHotspotSetup() {
    // A body found over the phone's hotspot (fixed 172.20.10.x subnet) must light the
    // Hotspot setup and never the Router one — and a router-network discovery must not
    // light the Hotspot setup.
    let router = PTPIPSavedCameraRecord(
        host: "192.168.1.20",
        displayName: "ZR_6002199",
        transport: "Wi-Fi",
        lastSeenAt: Date(),
        path: .infrastructure(networkName: nil)
    )
    let hotspot = PTPIPSavedCameraRecord(
        host: "172.20.10.2",
        displayName: "ZR_6002199",
        transport: "Wi-Fi",
        lastSeenAt: Date(),
        path: .phoneHotspot
    )
    let overHotspot = DiscoveredCamera(ip: "172.20.10.3", name: "ZR_6002199", source: .bonjour)
    let overRouter = DiscoveredCamera(ip: "192.168.1.77", name: "ZR_6002199", source: .bonjour)

    #expect(
        SavedCameraAvailabilityPolicy.resolve(
            camera: router, discoveredCameras: [overHotspot], connectedHost: nil) == .offline)
    #expect(
        SavedCameraAvailabilityPolicy.resolve(
            camera: hotspot, discoveredCameras: [overHotspot], connectedHost: nil)
            == .available(overHotspot))
    #expect(
        SavedCameraAvailabilityPolicy.resolve(
            camera: hotspot, discoveredCameras: [overRouter], connectedHost: nil) == .offline)
    #expect(
        SavedCameraAvailabilityPolicy.resolve(
            camera: router, discoveredCameras: [overRouter], connectedHost: nil)
            == .available(overRouter))
}

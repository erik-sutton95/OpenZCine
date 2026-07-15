import Testing

@testable import OpenZCineCore

@Test func startupPolicyOpensAddCameraWhenNoSavedCamerasExist() {
    #expect(CameraStartupPolicy.launchDestination(savedCameras: []) == .addCamera)
}

@Test func startupPolicyOpensSavedCamerasWhenProfilesExist() {
    let saved = [
        PTPIPSavedCameraRecord(
            host: "192.168.1.1",
            displayName: "Nikon ZR",
            transport: "Wi-Fi",
            lastSeenAt: nil
        )
    ]

    #expect(CameraStartupPolicy.launchDestination(savedCameras: saved) == .savedCameras)
}

@Test func startupPolicyReturnsToAddCameraAfterOnlyProfileIsDeleted() {
    let saved = [
        PTPIPSavedCameraRecord(
            host: "192.168.1.1",
            displayName: "Nikon ZR",
            transport: "Wi-Fi",
            lastSeenAt: nil
        )
    ]

    let remaining = PTPIPSavedCameraRecords.removing("192.168.1.1", from: saved)

    #expect(CameraStartupPolicy.launchDestination(savedCameras: remaining) == .addCamera)
}

@Test func connectionPolicyUsesSavedProfileForKnownCamera() {
    let saved = [
        PTPIPSavedCameraRecord(
            host: "192.168.1.1",
            displayName: "Nikon ZR",
            transport: "Wi-Fi",
            lastSeenAt: nil
        )
    ]

    let strategy = CameraStartupPolicy.connectionStrategy(
        host: " 192.168.1.1 ",
        savedCameras: saved
    )

    #expect(strategy == .savedProfile)
}

@Test func connectionPolicyPairsWhenNoSavedProfile() {
    let strategy = CameraStartupPolicy.connectionStrategy(
        host: "192.168.1.1",
        savedCameras: []
    )

    // No saved profile → run the (auto-accepted) first-time pairing handshake. Never silently
    // probe an unknown camera: the probe is destructive to a camera on its pairing wizard.
    #expect(strategy == .firstTimePairing)
}

@Test func restoreCameraProfileStrategyLetsCameraMediatePairingPrompt() {
    #expect(
        !CameraStartupPolicy.startsWithPairingHandshake(
            for: .restoreCameraProfileBeforePairing
        ))
}

@Test func savedProfileStrategySkipsPairingHandshake() {
    #expect(!CameraStartupPolicy.startsWithPairingHandshake(for: .savedProfile))
}

@Test func firstTimePairingStrategyStartsWithPairingHandshake() {
    #expect(CameraStartupPolicy.startsWithPairingHandshake(for: .firstTimePairing))
}

@Test func startupPolicyPromptsForIPhoneHotspotWhenSavedHotspotCameraIsOffline() {
    let camera = PTPIPSavedCameraRecord(
        host: "172.20.10.8",
        displayName: "ZR_6001234",
        transport: "iPhone hotspot",
        lastSeenAt: nil
    )

    let prompt = CameraStartupPolicy.recoveryPrompt(
        savedCameras: [camera],
        discoveredCameras: [],
        connectedHost: nil
    )

    #expect(prompt == .enableIPhoneHotspot(camera))
}

@Test func startupPolicyDoesNotPromptForHotspotWhenSavedCameraIsAvailable() {
    let camera = PTPIPSavedCameraRecord(
        host: "172.20.10.8",
        displayName: "ZR_6001234",
        transport: "iPhone hotspot",
        lastSeenAt: nil
    )
    let discovered = DiscoveredCamera(ip: "172.20.10.8", name: "ZR_6001234", source: .bonjour)

    let prompt = CameraStartupPolicy.recoveryPrompt(
        savedCameras: [camera],
        discoveredCameras: [discovered],
        connectedHost: nil
    )

    #expect(prompt == .none)
}

@Test func startupPolicyTreatsHotspotSubnetAsIPhoneHotspotTransport() {
    let camera = PTPIPSavedCameraRecord(
        host: "172.20.10.11",
        displayName: "ZR_6001234",
        transport: "Wi-Fi",
        lastSeenAt: nil
    )

    let prompt = CameraStartupPolicy.recoveryPrompt(
        savedCameras: [camera],
        discoveredCameras: [],
        connectedHost: nil
    )

    #expect(prompt == .enableIPhoneHotspot(camera))
}

@Test func startupPolicyWaitsForCameraWhenIPhoneHotspotBridgeIsActive() {
    let camera = PTPIPSavedCameraRecord(
        host: "172.20.10.11",
        displayName: "ZR_6001234",
        transport: "Wi-Fi",
        lastSeenAt: nil
    )

    let prompt = CameraStartupPolicy.recoveryPrompt(
        savedCameras: [camera],
        discoveredCameras: [],
        connectedHost: nil,
        isIPhoneHotspotBridgeActive: true
    )

    #expect(prompt == .waitForIPhoneHotspotCamera(camera))
}

@Test func startupPolicyHidesSavedCameraFromPairingDiscoveryByHost() {
    let saved = [
        PTPIPSavedCameraRecord(
            host: "192.168.1.1",
            displayName: "ZR_6001234",
            transport: "Camera AP",
            lastSeenAt: nil
        )
    ]
    let unsavedCamera = DiscoveredCamera(
        ip: "192.168.1.45",
        name: "ZR_7000000",
        source: .bonjour
    )
    let discovered = [
        DiscoveredCamera(ip: "192.168.1.1", name: "ZR_6001234", source: .bonjour),
        unsavedCamera,
    ]

    let candidates = CameraStartupPolicy.pairingDiscoveryCandidates(
        discoveredCameras: discovered,
        savedCameras: saved
    )

    #expect(candidates == [unsavedCamera])
}

@Test func startupPolicyHidesSavedCameraFromPairingDiscoveryByAssignedName() {
    let saved = [
        PTPIPSavedCameraRecord(
            host: "172.20.10.8",
            displayName: "ZR_6001234",
            transport: "iPhone hotspot",
            lastSeenAt: nil
        )
    ]
    let discovered = [
        DiscoveredCamera(ip: "192.168.1.1", name: "ZR_6001234", source: .subnetProbe)
    ]

    let candidates = CameraStartupPolicy.pairingDiscoveryCandidates(
        discoveredCameras: discovered,
        savedCameras: saved
    )

    #expect(candidates.isEmpty)
}

@Test func startupPolicySurfacesSavedHotspotCameraForExplicitRepair() {
    let saved = [
        PTPIPSavedCameraRecord(
            host: "172.20.10.8",
            displayName: "ZR_6001234",
            transport: "iPhone hotspot",
            lastSeenAt: nil
        )
    ]
    let rediscovered = DiscoveredCamera(
        ip: "172.20.10.15",
        name: "ZR_6001234",
        source: .bonjour
    )

    let candidates = CameraStartupPolicy.pairingDiscoveryCandidates(
        discoveredCameras: [rediscovered],
        savedCameras: saved,
        allowSavedCameraRecovery: true
    )

    #expect(candidates == [rediscovered])
}

@Test func startupPolicyKeepsNewCamerasAheadOfSavedRepairFallback() {
    let saved = [
        PTPIPSavedCameraRecord(
            host: "172.20.10.8",
            displayName: "ZR_6001234",
            transport: "iPhone hotspot",
            lastSeenAt: nil
        )
    ]
    let rediscoveredSavedCamera = DiscoveredCamera(
        ip: "172.20.10.15",
        name: "ZR_6001234",
        source: .bonjour
    )
    let newCamera = DiscoveredCamera(
        ip: "172.20.10.16",
        name: "ZR_7000000",
        source: .bonjour
    )

    let candidates = CameraStartupPolicy.pairingDiscoveryCandidates(
        discoveredCameras: [rediscoveredSavedCamera, newCamera],
        savedCameras: saved,
        allowSavedCameraRecovery: true
    )

    #expect(candidates == [newCamera])
}

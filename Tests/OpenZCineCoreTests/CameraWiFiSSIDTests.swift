import Foundation
import Testing

@testable import OpenZCineCore

@Test func cameraWiFiSSIDDerivesNikonZRAccessPointFromFriendlyName() {
    #expect(CameraWiFiSSID.deriveSSID(fromCameraName: "ZR_6001234") == "NIKON_ZR_01234")
    #expect(CameraWiFiSSID.deriveSSID(fromCameraName: "zr_6001234") == "NIKON_ZR_01234")
}

@Test func cameraWiFiSSIDRejectsNonZRNames() {
    #expect(CameraWiFiSSID.deriveSSID(fromCameraName: "Nikon ZR") == nil)
    #expect(CameraWiFiSSID.deriveSSID(fromCameraName: "PTP-IP Camera") == nil)
}

@Test func cameraWiFiSSIDPrefersStoredSSIDOnSavedRecord() {
    let saved = PTPIPSavedCameraRecord(
        host: "192.168.1.1",
        displayName: "ZR_6001234",
        transport: "Wi-Fi",
        lastSeenAt: nil,
        presentation: PTPIPSavedCameraPresentation(wifiSSID: "NIKON_ZR_CUSTOM")
    )
    #expect(CameraWiFiSSID.resolve(for: saved) == "NIKON_ZR_CUSTOM")
}

@Test func cameraWiFiJoinPolicySkipsJoinOnCameraSubnet() {
    let saved = PTPIPSavedCameraRecord(
        host: "192.168.1.1",
        displayName: "ZR_6001234",
        transport: "Wi-Fi",
        lastSeenAt: nil
    )
    let target = CameraWiFiJoinPolicy.joinTargetIfNeeded(
        transportKind: .ptpIP,
        localAddresses: ["192.168.1.42"],
        savedCamera: saved,
        discoveredCamera: nil,
        connectedSSID: "NIKON_ZR_01234"
    )
    #expect(target == nil)
}

@Test func cameraWiFiJoinPolicyDoesNotFalsePositiveOnHome1921681Subnet() {
    let saved = PTPIPSavedCameraRecord(
        host: "192.168.1.1",
        displayName: "ZR_6001234",
        transport: "Wi-Fi",
        lastSeenAt: nil
    )
    let target = CameraWiFiJoinPolicy.joinTargetIfNeeded(
        transportKind: .ptpIP,
        localAddresses: ["192.168.1.42"],
        savedCamera: saved,
        discoveredCamera: nil,
        connectedSSID: "HomeNetwork"
    )
    #expect(target == CameraWiFiJoinPolicy.JoinTarget(ssid: "NIKON_ZR_01234"))
}

@Test func cameraWiFiJoinPolicySkipsJoinForIPhoneHotspotCameraByTransport() {
    // The phone hosts its Personal Hotspot and the camera joins it — the phone joins nothing, so
    // no "Tap Join" Wi-Fi-join phase (and no spurious join of the phone's own hotspot SSID).
    let saved = PTPIPSavedCameraRecord(
        host: "172.20.10.5",
        displayName: "ZR_6001234",
        transport: "iPhone Hotspot",
        lastSeenAt: nil
    )
    let target = CameraWiFiJoinPolicy.joinTargetIfNeeded(
        transportKind: .ptpIP,
        localAddresses: ["172.20.10.1"],
        savedCamera: saved,
        discoveredCamera: nil,
        connectedSSID: "My iPhone"
    )
    #expect(target == nil)
}

@Test func cameraWiFiJoinPolicySkipsJoinForIPhoneHotspotCameraByHost() {
    // Host in the 172.20.10.x hotspot subnet marks a hotspot camera even without a transport label.
    let saved = PTPIPSavedCameraRecord(
        host: "172.20.10.7",
        displayName: "ZR_6001234",
        transport: "Wi-Fi",
        lastSeenAt: nil
    )
    let target = CameraWiFiJoinPolicy.joinTargetIfNeeded(
        transportKind: .ptpIP,
        localAddresses: ["172.20.10.1"],
        savedCamera: saved,
        discoveredCamera: nil,
        connectedSSID: "My iPhone"
    )
    #expect(target == nil)
}

@Test func cameraWiFiJoinPolicySkipsJoinForDiscoveredHotspotCamera() {
    // First-pair over hotspot: no saved camera yet, camera discovered on the hotspot subnet.
    let discovered = DiscoveredCamera(
        ip: "172.20.10.5", name: "ZR_6001234", source: .subnetProbe)
    let target = CameraWiFiJoinPolicy.joinTargetIfNeeded(
        transportKind: .ptpIP,
        localAddresses: ["172.20.10.1"],
        savedCamera: nil,
        discoveredCamera: discovered,
        connectedSSID: "My iPhone"
    )
    #expect(target == nil)
}

@Test func isOnCameraAccessPointRequiresNikonSSID() {
    #expect(
        CameraWiFiJoinPolicy.isOnCameraAccessPoint(
            localAddresses: ["192.168.1.42"],
            connectedSSID: "NIKON_ZR_01234"
        )
    )
    #expect(
        !CameraWiFiJoinPolicy.isOnCameraAccessPoint(
            localAddresses: ["192.168.1.42"],
            connectedSSID: "HomeNetwork"
        )
    )
    #expect(
        !CameraWiFiJoinPolicy.isOnCameraAccessPoint(
            localAddresses: ["192.168.1.42"],
            connectedSSID: nil
        )
    )
}

@Test func cameraWiFiJoinPolicyPromptsWhenOffCameraSubnet() {
    let saved = PTPIPSavedCameraRecord(
        host: "192.168.1.1",
        displayName: "ZR_6001234",
        transport: "Wi-Fi",
        lastSeenAt: nil
    )
    let target = CameraWiFiJoinPolicy.joinTargetIfNeeded(
        transportKind: .ptpIP,
        localAddresses: ["10.0.0.12"],
        savedCamera: saved,
        discoveredCamera: nil
    )
    #expect(target == CameraWiFiJoinPolicy.JoinTarget(ssid: "NIKON_ZR_01234"))
}

@Test func proactiveJoinTargetUsesSavedCameraSSIDWhenOffSubnet() {
    let saved = PTPIPSavedCameraRecord(
        host: "192.168.1.1",
        displayName: "ZR_6001234",
        transport: "Wi-Fi",
        lastSeenAt: nil
    )
    let target = CameraWiFiJoinPolicy.proactiveJoinTarget(
        localAddresses: ["10.0.0.12"],
        savedCameras: [saved]
    )
    #expect(target == .specificSSID("NIKON_ZR_01234"))
}

@Test func proactiveJoinTargetSkipsWhenOnCameraSSID() {
    let saved = PTPIPSavedCameraRecord(
        host: "192.168.1.1",
        displayName: "ZR_6001234",
        transport: "Wi-Fi",
        lastSeenAt: nil
    )
    let target = CameraWiFiJoinPolicy.proactiveJoinTarget(
        localAddresses: ["192.168.1.42"],
        savedCameras: [saved],
        connectedSSID: "NIKON_ZR_01234"
    )
    #expect(target == nil)
}

@Test func proactiveJoinTargetProceedsOnHome1921681WithoutNikonSSID() {
    let target = CameraWiFiJoinPolicy.proactiveJoinTarget(
        localAddresses: ["192.168.1.42"],
        savedCameras: [],
        connectedSSID: "HomeNetwork"
    )
    #expect(target == .ssidPrefix("NIKON_ZR_"))
}

@Test func proactiveJoinTargetUsesPrefixWithNoSavedCameras() {
    let target = CameraWiFiJoinPolicy.proactiveJoinTarget(
        localAddresses: ["10.0.0.12"],
        savedCameras: []
    )
    #expect(target == .ssidPrefix("NIKON_ZR_"))
}

@Test func proactiveJoinSessionPolicyRespectsPersistedUserDenied() {
    var policy = ProactiveWiFiJoinSessionPolicy()
    let deniedAt = Date(timeIntervalSince1970: 2_000)
    #expect(!policy.shouldAttempt(lastUserDeniedAt: deniedAt, at: deniedAt.addingTimeInterval(60)))
    #expect(policy.shouldAttempt(lastUserDeniedAt: deniedAt, at: deniedAt.addingTimeInterval(301)))
}

@Test func proactiveJoinSessionPolicyRespectsUserDenied() {
    var policy = ProactiveWiFiJoinSessionPolicy()
    policy.recordUserDenied()
    #expect(!policy.shouldAttempt())
}

@Test func proactiveJoinSessionPolicyCooldownBlocksRapidRetries() {
    var policy = ProactiveWiFiJoinSessionPolicy()
    let now = Date(timeIntervalSince1970: 1_000)
    policy.recordAttempt(at: now)
    #expect(!policy.shouldAttempt(at: now.addingTimeInterval(5)))
    #expect(policy.shouldAttempt(at: now.addingTimeInterval(30)))
}

@Test func proactiveJoinSessionPolicySkipsAfterSuccess() {
    var policy = ProactiveWiFiJoinSessionPolicy()
    policy.recordSuccess()
    #expect(!policy.shouldAttempt())
}

@Test func joinTargetCredentialLookupPrefersExactSSID() {
    let target = CameraWiFiJoinPolicy.JoinTarget(ssid: "NIKON_ZR_01234")
    let lookup = CameraWiFiJoinPolicy.credentialLookupSSID(
        for: target,
        resolvedSSID: nil
    )
    #expect(lookup.ssid == "NIKON_ZR_01234")
    #expect(lookup.prefix == nil)
}

@Test func joinTargetCredentialLookupFallsBackToPrefix() {
    let target = CameraWiFiJoinPolicy.JoinTarget(ssidPrefix: CameraWiFiSSID.nikonAccessPointPrefix)
    let lookup = CameraWiFiJoinPolicy.credentialLookupSSID(
        for: target,
        resolvedSSID: nil
    )
    #expect(lookup.ssid == nil)
    #expect(lookup.prefix == CameraWiFiSSID.nikonAccessPointPrefix)
}

@Test func connectionProgressJoiningWiFiCopy() {
    #expect(
        ConnectionProgressCopy.statusTitle(phase: .joiningWiFi, isUSB: false) == "Connecting…"
    )
    let detail = ConnectionProgressCopy.statusDetail(
        phase: .joiningWiFi,
        deviceName: "Nikon ZR",
        friendlyError: nil
    )
    #expect(detail.contains("Tap Join"))
}

@Test func connectionProgressPhaseResolverMapsJoiningWiFi() {
    let joining = ConnectionProgressCopy.resolvePhase(
        isProgressPresented: true,
        explicitPhase: .joiningWiFi,
        isEstablishingConnection: true,
        isPairing: false,
        isPreparingLiveView: false,
        isConnected: false,
        showsFailure: false
    )
    #expect(joining == .joiningWiFi)
}

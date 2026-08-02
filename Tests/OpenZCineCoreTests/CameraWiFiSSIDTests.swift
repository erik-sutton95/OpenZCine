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

@Test func cameraWiFiSSIDRecognizesModelSpecificNikonZAccessPointShapes() {
    #expect(CameraWiFiSSID.isNikonZAccessPoint("NIKON_ZR_01234"))
    #expect(CameraWiFiSSID.isNikonZAccessPoint("NIKONZ_8_X12345"))
    #expect(CameraWiFiSSID.isNikonZAccessPoint("nikon-z-9-98765"))
}

@Test func cameraWiFiSSIDRejectsUnrelatedOrMalformedNetworkNames() {
    #expect(!CameraWiFiSSID.isNikonZAccessPoint("HomeNetwork"))
    #expect(!CameraWiFiSSID.isNikonZAccessPoint("NIKON_CAMERA_12345"))
    #expect(!CameraWiFiSSID.isNikonZAccessPoint("NIKONZ@8@12345"))
    #expect(!CameraWiFiSSID.isNikonZAccessPoint("NIKONZ_CAMERA"))
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

/// The router regression, caught by a tester: a saved camera record collapses camera-AP, hotspot
/// and router into one "Wi-Fi" transport, so when the same body was later found on a set router,
/// the join policy resolved the record's stored SSID and told iOS to LEAVE that router for the
/// camera's own access point — a join prompt for a camera the phone could already see. Cancelling
/// and retrying "worked" only because the second attempt raced discovery. A discovered camera is
/// by definition reachable on the network this device is already on, so no join may ever fire.
@Test func cameraWiFiJoinPolicyNeverJoinsForADiscoveredCamera() {
    let saved = PTPIPSavedCameraRecord(
        host: "10.99.0.20",
        displayName: "ZR_6001234",
        transport: "Wi-Fi",
        lastSeenAt: nil,
        presentation: PTPIPSavedCameraPresentation(wifiSSID: "NIKON_ZR_02199")
    )
    let target = CameraWiFiJoinPolicy.joinTargetIfNeeded(
        transportKind: .ptpIP,
        // On the router's subnet, NOT the camera-AP one — precisely the trap.
        localAddresses: ["10.99.0.7"],
        savedCamera: saved,
        discoveredCamera: DiscoveredCamera(ip: "10.99.0.20", name: "ZR_6001234", source: .bonjour),
        connectedSSID: "SET-ROUTER"
    )
    #expect(target == nil)
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
    // Evidence-stamped AP record: the point under test is that a HOME network sharing the
    // camera-AP's 192.168.1.0/24 range must not fake "already on the AP" and suppress the join.
    let saved = PTPIPSavedCameraRecord(
        host: "192.168.1.1",
        displayName: "ZR_6001234",
        transport: "Wi-Fi",
        lastSeenAt: nil,
        pairedViaCameraAccessPoint: true
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
        CameraWiFiJoinPolicy.isOnCameraAccessPoint(
            localAddresses: ["192.168.1.42"],
            connectedSSID: "NIKONZ_8_X12345"
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
        lastSeenAt: nil,
        pairedViaCameraAccessPoint: true
    )
    let target = CameraWiFiJoinPolicy.joinTargetIfNeeded(
        transportKind: .ptpIP,
        localAddresses: ["10.0.0.12"],
        savedCamera: saved,
        discoveredCamera: nil
    )
    #expect(target == CameraWiFiJoinPolicy.JoinTarget(ssid: "NIKON_ZR_01234"))
}

@Test func proactiveJoinTargetRequiresPositiveAPEvidence() {
    // Spontaneous joins are opt-in by evidence: a record that has actually joined the
    // camera's AP (stamped true) volunteers; one with no evidence — every record on a device
    // that cannot read SSIDs — must not reconfigure Wi-Fi on its own.
    let stamped = PTPIPSavedCameraRecord(
        host: "192.168.1.1",
        displayName: "ZR_6001234",
        transport: "Wi-Fi",
        lastSeenAt: nil,
        pairedViaCameraAccessPoint: true
    )
    let target = CameraWiFiJoinPolicy.proactiveJoinTarget(
        localAddresses: ["10.0.0.12"],
        savedCameras: [stamped]
    )
    #expect(target == .specificSSID("NIKON_ZR_01234"))
}

/// The field shape behind the recurring alert: every record predates the evidence field and
/// the device never reads SSIDs, so nothing can ever earn `false` either. No evidence, no
/// spontaneous prompt — the operator-initiated connect path is unaffected.
@Test func proactiveJoinTargetStaysQuietForAllLegacyRecords() {
    let legacy = PTPIPSavedCameraRecord(
        host: "192.168.1.1",
        displayName: "ZR_6001234",
        transport: "Wi-Fi",
        lastSeenAt: nil
    )
    let target = CameraWiFiJoinPolicy.proactiveJoinTarget(
        localAddresses: ["10.0.0.12"],
        savedCameras: [legacy]
    )
    #expect(target == nil)
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
    #expect(target == .ssidPrefix("NIKON"))
}

@Test func proactiveJoinTargetUsesPrefixWithNoSavedCameras() {
    let target = CameraWiFiJoinPolicy.proactiveJoinTarget(
        localAddresses: ["10.0.0.12"],
        savedCameras: []
    )
    #expect(target == .ssidPrefix("NIKON"))
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
    let target = CameraWiFiJoinPolicy.JoinTarget(
        ssidPrefix: CameraWiFiSSID.nikonAccessPointBrandPrefix)
    let lookup = CameraWiFiJoinPolicy.credentialLookupSSID(
        for: target,
        resolvedSSID: nil
    )
    #expect(lookup.ssid == nil)
    #expect(lookup.prefix == CameraWiFiSSID.nikonAccessPointBrandPrefix)
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

/// A router camera drops off the network and the app used to answer with "join NIKON_…" — leaving
/// the shared network to look for a camera that was never on its own AP with this device. Positive
/// evidence of a non-AP camera suppresses the join even when nothing is currently discovered.
@Test func cameraWiFiJoinPolicyNeverJoinsForARouterPairedCameraOnDrop() {
    let saved = PTPIPSavedCameraRecord(
        host: "10.99.0.20",
        displayName: "ZR_6001234",
        transport: "Wi-Fi",
        lastSeenAt: nil,
        pairedViaCameraAccessPoint: false
    )
    let target = CameraWiFiJoinPolicy.joinTargetIfNeeded(
        transportKind: .ptpIP,
        localAddresses: ["10.99.0.7"],
        savedCamera: saved,
        // The drop: the camera is momentarily invisible, which is exactly when the old
        // reachability guard could not help.
        discoveredCamera: nil,
        connectedSSID: "SET-ROUTER"
    )
    #expect(target == nil)
}

/// A record with no evidence either way — every record on a device that cannot read SSIDs, and
/// everything saved before the field existed — must NOT volunteer the join. This was the last
/// hole in the "join NIKON_…" saga: a router operator's records could never earn `false`, so
/// the legacy allowance kept prompting them to leave the router forever. Positive proof only —
/// the same rule the proactive path already follows.
@Test func cameraWiFiJoinPolicyDoesNotJoinForALegacyRecordOnDrop() {
    let saved = PTPIPSavedCameraRecord(
        host: "192.168.1.1",
        displayName: "ZR_6001234",
        transport: "Wi-Fi",
        lastSeenAt: nil
    )
    let target = CameraWiFiJoinPolicy.joinTargetIfNeeded(
        transportKind: .ptpIP,
        localAddresses: ["10.99.0.7"],
        savedCamera: saved,
        discoveredCamera: nil,
        connectedSSID: "HOME-WIFI"
    )
    #expect(target == nil)
}

/// The AP-path row keeps its prompt: a record that PROVED it lives on the camera's access point
/// still offers the join when the camera is not visible on the current network.
@Test func cameraWiFiJoinPolicyStillJoinsForAnAPProvenRecordOnDrop() {
    let saved = PTPIPSavedCameraRecord(
        host: "192.168.1.1",
        displayName: "ZR_6001234",
        transport: "Wi-Fi",
        lastSeenAt: nil,
        pairedViaCameraAccessPoint: true
    )
    let target = CameraWiFiJoinPolicy.joinTargetIfNeeded(
        transportKind: .ptpIP,
        localAddresses: ["10.99.0.7"],
        savedCamera: saved,
        discoveredCamera: nil,
        connectedSSID: "HOME-WIFI"
    )
    #expect(target?.ssid == "NIKON_ZR_01234")
}

/// The proactive launch join must not fish for a router camera's derived SSID either — and when
/// every saved camera is known to live off the AP path, the brand-prefix fallback is pure noise.
@Test func proactiveJoinTargetSuppressedWhenAllCamerasAreOffTheAPPath() {
    let routerCamera = PTPIPSavedCameraRecord(
        host: "10.99.0.20",
        displayName: "ZR_6001234",
        transport: "Wi-Fi",
        lastSeenAt: nil,
        pairedViaCameraAccessPoint: false
    )
    let target = CameraWiFiJoinPolicy.proactiveJoinTarget(
        localAddresses: ["10.99.0.7"],
        savedCameras: [routerCamera]
    )
    #expect(target == nil)
}

/// An AP-paired camera beside a router one keeps its proactive join.
@Test func proactiveJoinTargetPrefersTheAPPairedCamera() {
    let routerCamera = PTPIPSavedCameraRecord(
        host: "10.99.0.20",
        displayName: "Z6_7005555",
        transport: "Wi-Fi",
        lastSeenAt: nil,
        pairedViaCameraAccessPoint: false
    )
    let apCamera = PTPIPSavedCameraRecord(
        host: "192.168.1.1",
        displayName: "ZR_6001234",
        transport: "Wi-Fi",
        lastSeenAt: nil,
        pairedViaCameraAccessPoint: true
    )
    let target = CameraWiFiJoinPolicy.proactiveJoinTarget(
        localAddresses: ["10.99.0.7"],
        savedCameras: [routerCamera, apCamera]
    )
    #expect(target == .specificSSID("NIKON_ZR_01234"))
}

/// The reconnect upsert usually carries no topology evidence; it must not erase what pairing
/// recorded — nil never clobbers a known value through the canonicalizing merge.
@Test func savedCameraMergePreservesAccessPointEvidenceThroughAnUpsert() {
    let paired = PTPIPSavedCameraRecord(
        host: "10.99.0.20",
        displayName: "ZR_6001234",
        transport: "Wi-Fi",
        lastSeenAt: Date(timeIntervalSince1970: 100),
        pairedViaCameraAccessPoint: false
    )
    let records = PTPIPSavedCameraRecords.upserting(
        host: "10.99.0.20",
        displayName: "ZR_6001234",
        transport: "Wi-Fi",
        lastSeenAt: Date(timeIntervalSince1970: 200),
        into: [paired]
    )
    #expect(records.count == 1)
    #expect(records.first?.pairedViaCameraAccessPoint == false)
}

/// The field shape behind the persistent "join NIKON_…" prompt on the router path: the SAME
/// physical body often exists twice — the router record with `false` evidence beside a legacy
/// record from its AP days with none. Once anything proves off-AP use, a no-evidence record may
/// not volunteer its stored SSID; only positive AP evidence still may.
@Test func proactiveJoinTargetIgnoresLegacyRecordsOnceOffAPUseIsProven() {
    let routerCamera = PTPIPSavedCameraRecord(
        host: "10.99.0.20",
        displayName: "ZR_6001234",
        transport: "Wi-Fi",
        lastSeenAt: nil,
        pairedViaCameraAccessPoint: false
    )
    let legacyTwin = PTPIPSavedCameraRecord(
        host: "192.168.1.1",
        displayName: "Nikon ZR legacy",
        transport: "Wi-Fi",
        lastSeenAt: nil,
        presentation: PTPIPSavedCameraPresentation(wifiSSID: "NIKON_ZR_02199")
    )
    let target = CameraWiFiJoinPolicy.proactiveJoinTarget(
        localAddresses: ["10.99.0.7"],
        savedCameras: [routerCamera, legacyTwin]
    )
    #expect(target == nil)
}

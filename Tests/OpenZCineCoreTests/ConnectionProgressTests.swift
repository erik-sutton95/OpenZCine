import Testing

@testable import OpenZCineCore

@Test func connectionProgressResolvesZRServiceNameToNikonZR() {
    let name = ConnectionProgressCopy.resolveDisplayName(
        rawName: "ZR_6001234",
        savedCamera: nil
    )
    #expect(name == "Nikon ZR")
}

@Test func connectionProgressPrefersSavedCustomName() {
    let saved = PTPIPSavedCameraRecord(
        host: "192.168.1.1",
        displayName: "ZR_6001234",
        transport: "Wi-Fi",
        lastSeenAt: nil,
        presentation: PTPIPSavedCameraPresentation(customName: "A-Cam")
    )

    let name = ConnectionProgressCopy.resolveDisplayName(
        rawName: "ZR_6001234",
        savedCamera: saved
    )
    #expect(name == "A-Cam")
}

@Test func connectionProgressUsesUnifiedConnectingCopy() {
    #expect(
        ConnectionProgressCopy.statusTitle(phase: .handshaking, isUSB: true)
            == "Connecting…"
    )
    #expect(
        ConnectionProgressCopy.statusTitle(phase: .handshaking, isUSB: false) == "Connecting…"
    )
    #expect(
        ConnectionProgressCopy.statusTitle(phase: .pairing, isUSB: true) == "Pairing…"
    )
}

@Test func connectionProgressPhaseResolverMapsPairingAndFailure() {
    let pairing = ConnectionProgressCopy.resolvePhase(
        isProgressPresented: true,
        explicitPhase: .handshaking,
        isEstablishingConnection: true,
        isPairing: true,
        isPreparingLiveView: false,
        isConnected: false,
        showsFailure: false
    )
    #expect(pairing == .pairing)

    let failed = ConnectionProgressCopy.resolvePhase(
        isProgressPresented: true,
        explicitPhase: .handshaking,
        isEstablishingConnection: false,
        isPairing: false,
        isPreparingLiveView: false,
        isConnected: false,
        showsFailure: true
    )
    #expect(failed == .failed)

    let idle = ConnectionProgressCopy.resolvePhase(
        isProgressPresented: false,
        explicitPhase: .handshaking,
        isEstablishingConnection: true,
        isPairing: false,
        isPreparingLiveView: false,
        isConnected: false,
        showsFailure: false
    )
    #expect(idle == .idle)
}

@Test func connectionProgressPhaseResolverPassesReadyToJoinThrough() {
    let ready = ConnectionProgressCopy.resolvePhase(
        isProgressPresented: true,
        explicitPhase: .readyToJoin,
        isEstablishingConnection: false,
        isPairing: false,
        isPreparingLiveView: false,
        isConnected: false,
        showsFailure: false
    )
    #expect(ready == .readyToJoin)
    #expect(
        ConnectionProgressCopy.statusTitle(phase: .readyToJoin, isUSB: false) == "Ready to connect")
}

@Test func connectionProgressConfirmOnCameraExplainsAPRestart() {
    #expect(
        ConnectionProgressCopy.statusTitle(phase: .confirmOnCamera, isUSB: false)
            == "Confirm on camera"
    )
    let detail = ConnectionProgressCopy.statusDetail(
        phase: .confirmOnCamera,
        deviceName: "Nikon ZR",
        friendlyError: nil
    )
    #expect(detail.contains("Tap “Confirm”"))
    #expect(detail.contains("reconnect"))

    // The explicit phase must survive resolution during the discovery wait (no other flag set).
    let resolved = ConnectionProgressCopy.resolvePhase(
        isProgressPresented: true,
        explicitPhase: .confirmOnCamera,
        isEstablishingConnection: false,
        isPairing: false,
        isPreparingLiveView: false,
        isConnected: false,
        showsFailure: false
    )
    #expect(resolved == .confirmOnCamera)
}

@Test func connectionProgressFailureDetailUsesFriendlyError() {
    let detail = ConnectionProgressCopy.statusDetail(
        phase: .failed,
        deviceName: "Nikon ZR",
        friendlyError: "Couldn't reach the camera. Check Wi‑Fi and try again."
    )
    #expect(detail == "Couldn't reach the camera. Check Wi‑Fi and try again.")
}

import Testing

@testable import Runner

@Suite("First-pair wizard step numbering")
struct FirstPairWizardStepTests {

    @Test("Camera Access Point uses four steps when permissions are shown")
    func cameraAPWithPermissions() {
        let count = NativeAppModel.FirstPairWizardStep.stepCount(
            transport: .cameraAccessPoint,
            skipsPermissions: false
        )
        #expect(count == 4)
        #expect(
            NativeAppModel.FirstPairWizardStep.connectNetwork.displayNumber(
                transport: .cameraAccessPoint, skipsPermissions: false) == 4)
        #expect(
            NativeAppModel.FirstPairWizardStep.connectNetwork.isFinalStep(
                for: .cameraAccessPoint))
        #expect(
            !NativeAppModel.FirstPairWizardStep.discoverAndPair.isFinalStep(
                for: .cameraAccessPoint))
    }

    @Test("Camera Access Point uses three steps when permissions are skipped")
    func cameraAPSkipsPermissions() {
        let count = NativeAppModel.FirstPairWizardStep.stepCount(
            transport: .cameraAccessPoint,
            skipsPermissions: true
        )
        #expect(count == 3)
        #expect(
            NativeAppModel.FirstPairWizardStep.chooseTransport.displayNumber(
                transport: .cameraAccessPoint, skipsPermissions: true) == 1)
        #expect(
            NativeAppModel.FirstPairWizardStep.connectNetwork.displayNumber(
                transport: .cameraAccessPoint, skipsPermissions: true) == 3)
    }

    @Test("Phone Hotspot and USB-C keep five steps when permissions are shown")
    func hotspotAndUSBWithPermissions() {
        for transport: NativeAppModel.FirstPairTransportMethod in [.phoneHotspot, .usbC] {
            let count = NativeAppModel.FirstPairWizardStep.stepCount(
                transport: transport,
                skipsPermissions: false
            )
            #expect(count == 5)
            #expect(
                NativeAppModel.FirstPairWizardStep.discoverAndPair.isFinalStep(for: transport))
            #expect(
                !NativeAppModel.FirstPairWizardStep.connectNetwork.isFinalStep(for: transport))
            #expect(
                NativeAppModel.FirstPairWizardStep.discoverAndPair.displayNumber(
                    transport: transport, skipsPermissions: false) == 5)
        }
    }

    @Test("Phone Hotspot and USB-C use four steps when permissions are skipped")
    func hotspotAndUSBSKipPermissions() {
        for transport: NativeAppModel.FirstPairTransportMethod in [.phoneHotspot, .usbC] {
            let count = NativeAppModel.FirstPairWizardStep.stepCount(
                transport: transport,
                skipsPermissions: true
            )
            #expect(count == 4)
            #expect(
                NativeAppModel.FirstPairWizardStep.discoverAndPair.displayNumber(
                    transport: transport, skipsPermissions: true) == 4)
        }
    }

    /// HDMI capture reaches the camera through a cable and a capture device: there is no network
    /// to set up, so it visits one step fewer than the other cable path and ends on the capture
    /// step instead of a camera list.
    @Test("HDMI capture skips the network step")
    func hdmiCaptureSkipsNetwork() {
        let steps = NativeAppModel.FirstPairWizardStep.sequence(
            transport: .hdmiCapture, skipsPermissions: false)
        #expect(steps == [.permissions, .chooseTransport, .prepareCamera, .discoverAndPair])
        #expect(
            NativeAppModel.FirstPairWizardStep.stepCount(
                transport: .hdmiCapture, skipsPermissions: false) == 4)
        #expect(
            NativeAppModel.FirstPairWizardStep.stepCount(
                transport: .hdmiCapture, skipsPermissions: true) == 3)
        #expect(NativeAppModel.FirstPairWizardStep.discoverAndPair.isFinalStep(for: .hdmiCapture))
        // The numbering is contiguous even though the visited steps are not — the whole reason the
        // sequence replaced `rawValue` arithmetic, which would have numbered this one 5 of 4.
        #expect(
            NativeAppModel.FirstPairWizardStep.discoverAndPair.displayNumber(
                transport: .hdmiCapture, skipsPermissions: false) == 4)
        // A step this path never visits reports no number rather than a misleading one.
        #expect(
            NativeAppModel.FirstPairWizardStep.connectNetwork.displayNumber(
                transport: .hdmiCapture, skipsPermissions: false) == 0)
    }

    /// Walking the path in both directions has to stay on it — the bug a hand-written switch
    /// invites is stepping into `connectNetwork` because it happens to be the next raw value.
    @Test("Advancing and retreating skip the steps the path omits")
    func hdmiCaptureWalk() {
        let transport = NativeAppModel.FirstPairTransportMethod.hdmiCapture
        #expect(
            NativeAppModel.FirstPairWizardStep.prepareCamera.next(
                transport: transport, skipsPermissions: false) == .discoverAndPair)
        #expect(
            NativeAppModel.FirstPairWizardStep.discoverAndPair.previous(
                transport: transport, skipsPermissions: false) == .prepareCamera)
        #expect(
            NativeAppModel.FirstPairWizardStep.discoverAndPair.next(
                transport: transport, skipsPermissions: false) == nil)
        // Skipping permissions removes the only step before the choice, so Back disappears there.
        #expect(
            NativeAppModel.FirstPairWizardStep.chooseTransport.previous(
                transport: transport, skipsPermissions: true) == nil)
        #expect(
            NativeAppModel.FirstPairWizardStep.chooseTransport.previous(
                transport: transport, skipsPermissions: false) == .permissions)
    }

    /// The wizard offers three cards; the two cable paths share the third one.
    @Test("HDMI capture is a nested option, not a fourth card")
    func cableLinkCardGrouping() {
        #expect(
            NativeAppModel.FirstPairTransportMethod.cardCases == [
                .cameraAccessPoint, .phoneHotspot, .usbC,
            ])
        #expect(
            NativeAppModel.FirstPairTransportMethod.usbC.nestedOptions == [.usbC, .hdmiCapture])
        #expect(NativeAppModel.FirstPairTransportMethod.cameraAccessPoint.nestedOptions.isEmpty)
        #expect(NativeAppModel.FirstPairTransportMethod.phoneHotspot.nestedOptions.isEmpty)
        #expect(NativeAppModel.FirstPairTransportMethod.usbC.cardTitle == "Cable Link")
        #expect(NativeAppModel.FirstPairTransportMethod.hdmiCapture.cardTitle == "Cable Link")
        #expect(NativeAppModel.FirstPairTransportMethod.hdmiCapture.isCableLink)
        #expect(NativeAppModel.FirstPairTransportMethod.usbC.isCableLink)
        #expect(!NativeAppModel.FirstPairTransportMethod.phoneHotspot.isCableLink)
    }

    @MainActor
    @Test("Phone Hotspot pairing surfaces a saved camera when it is the only repair candidate")
    func phoneHotspotSavedCameraRepairFallback() {
        let model = NativeAppModel()
        model.isPairingNewCamera = true
        model.firstPairTransportMethod = .phoneHotspot
        model.discoveryTransportFilter = .wiFi
        model.savedCameras = [
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
        let unrelatedUSB = DiscoveredCamera(
            ip: "usb:TEST",
            name: "ZR_7000000",
            source: .usb
        )
        model.discoveredCameras = [rediscovered, unrelatedUSB]

        #expect(model.pairingDiscoveryCandidates == [rediscovered])
    }

    @MainActor
    @Test("Manual camera Wi-Fi details stage an exact join without claiming OCR")
    func manualCameraWiFiDetails() {
        let model = NativeAppModel()
        model.isCameraWiFiScannerPresented = true

        model.applyManualCameraWiFi(ssid: "NIKON-Z-FUTURE-42", key: "camera-passphrase")

        #expect(model.pendingCameraWiFiJoinTarget == .specificSSID("NIKON-Z-FUTURE-42"))
        #expect(model.cameraWiFiJoinPasswordDraft == "camera-passphrase")
        #expect(model.cameraWiFiJoinHasPasswordDraft)
        #expect(!model.cameraWiFiJoinKeyFromScan)
        #expect(!model.isCameraWiFiScannerPresented)
        #expect(model.connectionPhase == .readyToJoin)
        #expect(model.isConnectionProgressPresented)
    }

    @MainActor
    @Test("Scanned camera Wi-Fi details retain their verification source")
    func scannedCameraWiFiDetails() {
        let model = NativeAppModel()

        model.applyScannedCameraWiFi(ssid: "NIKONZ_8_X12345", key: "b4c5d6e7")

        #expect(model.pendingCameraWiFiJoinTarget == .specificSSID("NIKONZ_8_X12345"))
        #expect(model.cameraWiFiJoinKeyFromScan)
        #expect(model.cameraWiFiJoinHasPasswordDraft)
    }
}

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

    /// The wizard offers two cards, each grouping several paths — the operator picks a kind of
    /// connection first and the specific one second. Five flat choices is the version this
    /// replaced.
    @Test("Every path belongs to exactly one card")
    func cardGrouping() {
        #expect(NativeAppModel.FirstPairCard.allCases == [.wireless, .cableLink])
        #expect(
            NativeAppModel.FirstPairCard.wireless.options == [
                .cameraAccessPoint, .phoneHotspot, .wiFiNetwork,
            ])
        #expect(NativeAppModel.FirstPairCard.cableLink.options == [.usbC, .hdmiCapture])
        // Every path is reachable, and from one card only.
        let grouped = NativeAppModel.FirstPairCard.allCases.flatMap(\.options)
        #expect(Set(grouped) == Set(NativeAppModel.FirstPairTransportMethod.allCases))
        #expect(grouped.count == NativeAppModel.FirstPairTransportMethod.allCases.count)
        for method in NativeAppModel.FirstPairTransportMethod.allCases {
            #expect(NativeAppModel.FirstPairCard.card(for: method).options.contains(method))
        }
    }

    /// The camera-AP mechanisms — the Wi-Fi join and the credential scanner — belong to exactly
    /// one path. Every other path has no camera SSID to scan or join, and offering it one
    /// dead-ends the operator. This is one question rather than a list of exclusions because the
    /// list is what went wrong: each new path had to remember to opt out.
    @Test("Only the camera access point joins the camera's own network")
    func cameraAccessPointIsTheOnlyJoiner() {
        for method in NativeAppModel.FirstPairTransportMethod.allCases {
            #expect(method.joinsCameraAccessPoint == (method == .cameraAccessPoint))
        }
    }

    /// The router path is the hotspot path's shape: the app joins and hosts nothing, so it walks
    /// the same five steps and ends by finding a camera someone else's network is carrying.
    @Test("The router path walks the same steps as the hotspot path")
    func routerPathSteps() {
        let steps = NativeAppModel.FirstPairWizardStep.sequence(
            transport: .wiFiNetwork, skipsPermissions: false)
        #expect(
            steps == [
                .permissions, .chooseTransport, .prepareCamera, .connectNetwork, .discoverAndPair,
            ]
        )
        #expect(
            NativeAppModel.FirstPairWizardStep.stepCount(
                transport: .wiFiNetwork, skipsPermissions: false) == 5)
        #expect(
            NativeAppModel.FirstPairWizardStep.discoverAndPair.isFinalStep(for: .wiFiNetwork))
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

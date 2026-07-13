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
                skipsPermissions: false) == 4)
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
                skipsPermissions: true) == 1)
        #expect(
            NativeAppModel.FirstPairWizardStep.connectNetwork.displayNumber(
                skipsPermissions: true) == 3)
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
                    skipsPermissions: false) == 5)
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
                    skipsPermissions: true) == 4)
        }
    }
}

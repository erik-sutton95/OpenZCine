import Foundation
import MonitorPresentation
import OpenCineApple
import OpenCineCore
import OpenZCineCore
import Testing

@testable import Runner

@Suite("First-pair wizard step numbering")
struct FirstPairWizardStepTests {

    @Test("SIMULATED: transport is chosen before a wireless permission request")
    func networkPermissionFollowsTransportChoice() {
        for transport: NativeAppModel.FirstPairTransportMethod in [
            .cameraAccessPoint, .phoneHotspot, .wiFiNetwork,
        ] {
            let steps = NativeAppModel.FirstPairWizardStep.sequence(
                transport: transport, skipsPermissions: false)
            #expect(Array(steps.prefix(2)) == [.chooseTransport, .permissions])
        }
    }

    @Test("SIMULATED: USB control does not require phone camera or Local Network access")
    func usbControlSkipsUnrelatedNetworkPermissions() {
        let steps = NativeAppModel.FirstPairWizardStep.sequence(
            transport: .usbC, skipsPermissions: false)
        #expect(steps == [.chooseTransport, .prepareCamera, .connectNetwork, .discoverAndPair])
    }

    @Test("SIMULATED: capture requests its own video access without a Local Network gate")
    func captureSkipsNetworkPermissionStep() {
        let steps = NativeAppModel.FirstPairWizardStep.sequence(
            transport: .hdmiCapture, skipsPermissions: false)
        #expect(steps == [.chooseTransport, .prepareCamera, .discoverAndPair])
    }

    @Test("SIMULATED: pairing asks no phone camera permission; only Local Network is required")
    func firstPairPermissionIsLocalNetworkOnly() {
        #expect(StartupPermissionKind.allCases == [.localNetwork])
        // The step shows the shared evidence states; an unanswered probe is never denial.
        func shown(_ acknowledged: Bool, _ answer: CameraNetworkPermissionState?, _ asked: Bool)
            -> CameraNetworkPermissionState
        {
            StartupPermissionsCoordinator.shownState(
                acknowledged: acknowledged, answer: answer, requested: asked)
        }
        #expect(shown(false, nil, false) == .unknown)
        #expect(shown(false, nil, true) == .requested)
        #expect(shown(false, .denied, true) == .denied)
        #expect(shown(false, .allowed, false) == .allowed)
        #expect(shown(true, nil, false) == .allowed)
    }

    @Test("SIMULATED: the wizard browses nothing before a path is chosen (Z3-05)")
    @MainActor
    func wizardEntryStartsNoLocalNetworkBrowse() {
        // Any Bonjour browse raises the system Local Network prompt. On device the wizard's
        // entry browse put that prompt over step 1 of a fresh install, before any transport
        // choice; the prompt belongs to the permissions step's Local Network row.
        let model = NativeAppModel()
        model.startFirstPairWizard()
        #expect(model.firstPairWizardStep == .chooseTransport)
        #expect(!model.isRelayBrowsing)
        model.prepareStartup()
        #expect(!model.isRelayBrowsing)

        // Watching stays one deliberate tap away: the shared browse starts the relay browse.
        model.openWatcherBrowse()
        #expect(model.isRelayBrowsing)
        model.stopRelayBrowsing()
        #expect(!model.isRelayBrowsing)
    }

    @Test("SIMULATED: the debug log tap waits for a remembered Local Network grant")
    @MainActor
    func logTapWaitsForLocalNetworkGrant() throws {
        let suite = "w3.log-tap.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(!LocalNetworkAccess.grantRemembered(defaults: defaults))
        let access = LocalNetworkAccess(defaults: defaults, record: { _ in })
        access.note(.operationSucceeded, source: "camera link connected")
        #expect(LocalNetworkAccess.grantRemembered(defaults: defaults))
    }

    @Test("SIMULATED: the wizard step reads the app's one Local Network owner (Z8)")
    @MainActor
    func wizardReadsTheAppLocalNetworkOwner() throws {
        let suite = "w3.local-network.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var events: [AppDiagnosticEvent] = []
        let access = LocalNetworkAccess(defaults: defaults, record: { events.append($0) })
        let wizard = StartupPermissionsCoordinator(access: access, defaults: defaults)
        #expect(wizard.localNetwork == .unknown)
        #expect(access.reported == .unknown)
        #expect(
            !StartupPermissionsCoordinator.permissionsAlreadySatisfied(
                alreadyPairedCameras: false, access: access))

        // A camera link that completed over Wi-Fi proves access for the whole app: the step,
        // the diagnostics report and the next launch's wizard all see it.
        access.note(.operationSucceeded, source: "camera link connected")
        #expect(wizard.localNetwork == .allowed)
        #expect(wizard.allRequiredGranted)
        #expect(access.reported == .allowed)
        #expect(events == [.localNetworkAllowed])
        let nextLaunch = LocalNetworkAccess(defaults: defaults, record: { _ in })
        #expect(nextLaunch.acknowledged)
        #expect(
            StartupPermissionsCoordinator.permissionsAlreadySatisfied(
                alreadyPairedCameras: false, access: nextLaunch))
    }

    @Test("SIMULATED: a policy denial is the app's answer until a grant replaces it")
    @MainActor
    func denialIsTheAppAnswer() throws {
        let suite = "w3.local-network.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var events: [AppDiagnosticEvent] = []
        let access = LocalNetworkAccess(defaults: defaults, record: { events.append($0) })
        let wizard = StartupPermissionsCoordinator(access: access, defaults: defaults)
        access.note(.policyDenied, source: "camera link denied")
        access.note(.waiting, source: "camera link waiting")
        #expect(wizard.localNetwork == .denied)
        #expect(access.answer == .denied)
        #expect(!access.acknowledged)
        access.note(.operationSucceeded, source: "camera link connected")
        #expect(wizard.localNetwork == .allowed)
        #expect(events == [.localNetworkDenied, .localNetworkAllowed])
    }

    @Test("SIMULATED: only a camera link completed over the network proves Local Network access")
    func connectionEvidence() {
        #expect(
            LocalNetworkAccess.evidence(connected: true, transport: .ptpIP) == .operationSucceeded)
        #expect(LocalNetworkAccess.evidence(connected: true, transport: .usb) == nil)
        #expect(LocalNetworkAccess.evidence(connected: false, transport: .ptpIP) == nil)
        #expect(LocalNetworkAccess.evidence(connected: true, transport: nil) == nil)
    }

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

    @Test("USB-C prepare and network copy is device-neutral for iPad")
    func usbCopyDoesNotAssumeIPhone() {
        let steps = StartupWizardContent.preparationSteps(for: .usbC).joined(separator: " ")
        #expect(!steps.localizedCaseInsensitiveContains("iPhone"))
        let network = StartupWizardContent.networkSections(for: .usbC, tight: false)
            .flatMap(\.lines).joined(separator: " ")
        #expect(!network.localizedCaseInsensitiveContains("iPhone"))
        #expect(
            !StartupWizardContent.networkSubtitle(for: .usbC, tight: false)
                .localizedCaseInsensitiveContains("iPhone"))
    }

    @Test("Discovery rows lead with the selection and name a camera's holder")
    func discoveryRows() {
        let free = DiscoveredCamera(ip: "192.168.1.44", name: "Z8_4005555", source: .bonjour)
        let held = DiscoveredCamera(
            ip: "192.168.1.45", name: "Z6_3001234", source: .heldByAnotherDevice,
            heldByDeviceName: "Director's iPad")
        let rows = StartupWizardContent.discoveryDevices([free, held], selectedID: free.id)
        #expect(rows.map(\.id) == [free.id, held.id])
        #expect(rows.map(\.name) == [free.displayName, held.displayName])
        #expect(rows.map(\.isPrimary) == [true, false])
        #expect(rows.map(\.subtitle) == ["Wi-Fi · nearby", "In use by Director's iPad"])
        #expect(rows.allSatisfy { $0.signalBars == nil })
    }

    @Test("Discovery waiting copy follows the chosen path")
    func discoveryWaitingCopy() {
        let denied = StartupWizardContent.discoveryWaiting(
            transport: .usbC, pairingMethod: .usbC, usbAuthorizationDenied: true)
        #expect(denied.title == "USB camera access is off")
        #expect(denied.hint.contains("Settings"))
        let hotspot = StartupWizardContent.discoveryWaiting(
            transport: .wiFi, pairingMethod: .phoneHotspot, usbAuthorizationDenied: true)
        #expect(hotspot.title == "Waiting for the camera")
        #expect(hotspot.hint == "Waiting for the camera to join this phone's hotspot.")
    }

    /// USB-C asks no Local Network permission (A2-09), so it visits one step fewer than the
    /// hotspot path when permissions are shown.
    @Test("Phone Hotspot keeps five steps and USB-C four when permissions are shown")
    func hotspotAndUSBWithPermissions() {
        for transport: NativeAppModel.FirstPairTransportMethod in [.phoneHotspot, .usbC] {
            let expected = transport == .usbC ? 4 : 5
            let count = NativeAppModel.FirstPairWizardStep.stepCount(
                transport: transport,
                skipsPermissions: false
            )
            #expect(count == expected)
            #expect(
                NativeAppModel.FirstPairWizardStep.discoverAndPair.isFinalStep(for: transport))
            #expect(
                !NativeAppModel.FirstPairWizardStep.connectNetwork.isFinalStep(for: transport))
            #expect(
                NativeAppModel.FirstPairWizardStep.discoverAndPair.displayNumber(
                    transport: transport, skipsPermissions: false) == expected)
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
        #expect(steps == [.chooseTransport, .prepareCamera, .discoverAndPair])
        #expect(
            NativeAppModel.FirstPairWizardStep.stepCount(
                transport: .hdmiCapture, skipsPermissions: false) == 3)
        #expect(
            NativeAppModel.FirstPairWizardStep.stepCount(
                transport: .hdmiCapture, skipsPermissions: true) == 3)
        #expect(NativeAppModel.FirstPairWizardStep.discoverAndPair.isFinalStep(for: .hdmiCapture))
        // The numbering is contiguous even though the visited steps are not — the whole reason the
        // sequence replaced `rawValue` arithmetic, which would have numbered this one 5 of 3.
        #expect(
            NativeAppModel.FirstPairWizardStep.discoverAndPair.displayNumber(
                transport: .hdmiCapture, skipsPermissions: false) == 3)
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
        // The choice is the first step on every path, so Back never precedes it.
        #expect(
            NativeAppModel.FirstPairWizardStep.chooseTransport.previous(
                transport: transport, skipsPermissions: true) == nil)
        #expect(
            NativeAppModel.FirstPairWizardStep.chooseTransport.previous(
                transport: transport, skipsPermissions: false) == nil)
        // A wireless permission step returns to the choice.
        #expect(
            NativeAppModel.FirstPairWizardStep.permissions.previous(
                transport: .wiFiNetwork, skipsPermissions: false) == .chooseTransport)
    }

    /// The wizard offers two cards, each grouping several paths — the operator picks a kind of
    /// connection first and the specific one second. Five flat choices is the version this
    /// replaced.
    @Test("Every path belongs to exactly one card")
    @MainActor func cardGrouping() {
        #expect(NativeAppModel.FirstPairCard.allCases == [.wireless, .cableLink])
        #expect(
            NativeAppModel.FirstPairCard.wireless.options == [
                .cameraAccessPoint, .phoneHotspot, .wiFiNetwork,
            ])
        // HDMI capture is UVC-on-iPad, so on a phone it is absent rather than shown-and-disabled —
        // the cable card is the one place the offered set depends on the hardware.
        #expect(
            NativeAppModel.FirstPairCard.cableLink.options
                == (UVCVideoSource.isSupportedHardware ? [.usbC, .hdmiCapture] : [.usbC]))
        // Every path this device can offer is reachable, and from one card only.
        let grouped = NativeAppModel.FirstPairCard.allCases.flatMap(\.options)
        let offerable = NativeAppModel.FirstPairTransportMethod.allCases.filter {
            $0 != .hdmiCapture || UVCVideoSource.isSupportedHardware
        }
        #expect(Set(grouped) == Set(offerable))
        #expect(grouped.count == offerable.count)
        for method in offerable {
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
                .chooseTransport, .permissions, .prepareCamera, .connectNetwork, .discoverAndPair,
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

    /// The two staging tests below only reach their subject if the radio gate lets them through,
    /// and that gate reads a DEVICE's radio. Every simulator borrows the host's networking, so a
    /// wired machine — a CI runner — used to answer "off" and fail them while they passed on every
    /// laptop. Asserting the precondition here means the next time that breaks, the failure names
    /// the reason instead of pointing at Wi-Fi staging.
    @Test("A simulator never reports the operator's Wi-Fi radio as switched off")
    func simulatorAlwaysReportsARadio() {
        #expect(NativeNetworkInterfaceSnapshot.isWiFiRadioOn())
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

@Suite @MainActor
struct CameraNetworkNativeCharacterizationTests {
    @Test func cancellingAnOutstandingPickerIsCancellationNotFallback() async {
        guard #available(iOS 18.0, *) else { return }
        let session = ControlledAccessorySession()
        let owner = AccessorySetupWiFiCoordinator(makeNative: { session.native })
        let joining = Task {
            try await owner.joinCameraNetwork(ssid: "NIKON_ZR_TEST", password: nil)
        }
        await session.waitForPicker()
        joining.cancel()
        do {
            try await joining.value
            Issue.record("Cancelled picker cannot succeed")
        } catch { #expect(error is CancellationError) }
    }

    @Test func aCancelledNativePickerIsRetiredBeforeAnotherSessionIsAdmitted() async {
        guard #available(iOS 18.0, *) else { return }
        let factory = ControlledAccessoryFactory()
        let owner = AccessorySetupWiFiCoordinator(makeNative: { factory.make() })
        let joining = Task {
            try await owner.joinCameraNetwork(ssid: "NIKON_ZR_TEST", password: nil)
        }
        await factory.sessions[0].waitForPicker()
        joining.cancel()
        _ = await joining.result
        #expect(factory.sessions[0].invalidations == 1)
        let replacement = Task {
            try await owner.joinCameraNetwork(ssid: "NIKON_ZR_NEXT", password: nil)
        }
        await factory.waitForPicker(count: 2)
        #expect(factory.sessions.count == 2)
        factory.sessions[0].event?(.pickerDidDismiss)
        replacement.cancel()
        _ = await replacement.result
    }

    @Test func cancellationDuringNativeJoinCannotBecomeReadinessSuccess() async {
        guard #available(iOS 18.0, *) else { return }
        let session = ControlledAccessorySession(authorizedSSID: "NIKON_ZR_TEST")
        let owner = AccessorySetupWiFiCoordinator(makeNative: { session.native })
        let joining = Task {
            try await owner.joinCameraNetwork(ssid: "NIKON_ZR_TEST", password: nil)
        }
        await session.waitForNativeJoin()
        joining.cancel()
        session.completeJoin()
        do {
            try await joining.value
            Issue.record("Cancelled join cannot become ready")
        } catch { #expect(error is CancellationError) }
    }
}

/// SIMULATED: picker, native joins and events never call AccessorySetupKit or network APIs.
@available(iOS 18.0, *)
@MainActor private final class ControlledAccessorySession {
    var event: (@MainActor (AccessorySetupWiFiCoordinator.Event) -> Void)?
    var invalidations = 0
    var onPicker: (() -> Void)?
    private var pickerShown = false
    private var pickerWaiter: CheckedContinuation<Void, Never>?
    private var joinWaiter: CheckedContinuation<Void, Error>?
    private var joinedWaiter: CheckedContinuation<Void, Never>?
    let authorizedSSID: String?
    init(authorizedSSID: String? = nil) { self.authorizedSSID = authorizedSSID }
    var native: AccessorySetupWiFiCoordinator.Native {
        .init(
            activate: { [unowned self] callback in
                event = callback
                callback(.activated)
            },
            accessories: { [unowned self] in
                authorizedSSID.map { [.init(ssid: $0, authorized: true, native: nil)] } ?? []
            },
            showPicker: { [unowned self] _, _ in
                pickerShown = true
                pickerWaiter?.resume()
                pickerWaiter = nil
                onPicker?()
            },
            join: { [unowned self] _, _ in
                try await withCheckedThrowingContinuation { continuation in
                    joinWaiter = continuation
                    joinedWaiter?.resume()
                    joinedWaiter = nil
                }
            }, invalidate: { [unowned self] in invalidations += 1 },
            localAddresses: { [] }, currentSSID: { nil })
    }
    func waitForPicker() async {
        if pickerShown { return }
        await withCheckedContinuation { pickerWaiter = $0 }
    }
    func waitForNativeJoin() async {
        if joinWaiter != nil { return }
        await withCheckedContinuation { joinedWaiter = $0 }
    }
    func completeJoin() {
        joinWaiter?.resume()
        joinWaiter = nil
    }
}

@available(iOS 18.0, *)
@MainActor private final class ControlledAccessoryFactory {
    var sessions: [ControlledAccessorySession] = []
    private var pickerCount = 0
    private var waiting: (Int, CheckedContinuation<Void, Never>)?
    func make() -> AccessorySetupWiFiCoordinator.Native {
        let session = ControlledAccessorySession()
        session.onPicker = { [unowned self] in
            pickerCount += 1
            if let (count, continuation) = waiting, pickerCount >= count {
                waiting = nil
                continuation.resume()
            }
        }
        sessions.append(session)
        return session.native
    }
    func waitForPicker(count: Int) async {
        if pickerCount >= count { return }
        await withCheckedContinuation { waiting = (count, $0) }
    }
}

/// Device lane DEF-Z-FIRSTRUN-WIZARD and DEF-Z-FIRSTRUN-CAMERA: a fresh install with no saved
/// camera opens the same transport wizard as Pair a new camera, and discovery leaves USB camera
/// control (the iOS Camera prompt) alone until the operator chooses the cable path.
@MainActor
@Suite("First run")
struct FirstRunTests {
    private func freshModel() -> NativeAppModel {
        let model = NativeAppModel()
        model.savedCameras = []
        model.showsCameraListWithoutSavedCameras = false
        model.isPairingNewCamera = false
        model.startupMode = .discovery
        model.discoveryTransportFilter = .wiFi
        return model
    }

    @Test("A fresh install opens the transport wizard, not the bare pair page")
    func freshInstallOpensTheWizard() {
        let model = freshModel()
        #expect(model.shouldShowFirstPairWizard, "first run must reach Cable Link and Camera AP")
        model.showsCameraListWithoutSavedCameras = true
        #expect(!model.shouldShowFirstPairWizard, "choosing the camera list leaves the wizard")
    }

    @Test("Discovery does not touch USB camera control before the cable path is chosen")
    func usbWaitsForTheCablePath() {
        let model = freshModel()
        #expect(!model.discoveryBrowsesUSB, "no Camera prompt before a path is chosen")
        model.isPairingNewCamera = true
        model.firstPairTransportMethod = .cameraAccessPoint
        #expect(!model.discoveryBrowsesUSB, "a wireless path never asks for USB control")
        model.discoveryTransportFilter = .usbC
        #expect(model.discoveryBrowsesUSB, "the cable path browses USB")
    }

    /// A2-09 composed order on the integrated model: first run lands on the transport choice,
    /// every wireless path asks for Local Network only after that choice, and USB camera control
    /// waits for an operator choice on the cable path (Cable Link, a saved USB-C setup or an
    /// armed USB-C watch).
    @Test("First run: wizard, then transport, then permissions; USB only on the cable path")
    func firstRunComposedOrder() {
        let model = freshModel()
        #expect(model.shouldShowFirstPairWizard, "nothing saved opens the transport wizard")
        #expect(!model.discoveryBrowsesUSB, "no Camera prompt on launch")
        for transport: NativeAppModel.FirstPairTransportMethod in [
            .cameraAccessPoint, .phoneHotspot, .wiFiNetwork,
        ] {
            let steps = Array(
                NativeAppModel.FirstPairWizardStep.sequence(
                    transport: transport, skipsPermissions: false))
            #expect(steps.first == .chooseTransport, "the transport choice comes first")
            #expect(steps.firstIndex(of: .permissions) == 1, "permissions follow the choice")
            model.isPairingNewCamera = true
            model.firstPairTransportMethod = transport
            #expect(!model.discoveryBrowsesUSB, "a wireless path never asks for USB control")
        }
        let cable = Array(
            NativeAppModel.FirstPairWizardStep.sequence(transport: .usbC, skipsPermissions: false))
        #expect(cable.first == .chooseTransport)
        #expect(!cable.contains(.permissions), "Cable Link asks no Local Network permission")
        model.firstPairTransportMethod = .usbC
        model.discoveryTransportFilter = .usbC
        #expect(model.discoveryBrowsesUSB, "Cable Link discovery browses USB")

        let wireless = PTPIPSavedCameraRecord(
            host: "192.168.1.30", displayName: "ZR_6002199", transport: "Wi-Fi", lastSeenAt: nil)
        let cabled = PTPIPSavedCameraRecord(
            host: "usb:demo-zr", displayName: "ZR_6002199", transport: "USB-C", lastSeenAt: nil)
        let saved = NativeAppModel()
        saved.isPairingNewCamera = false
        saved.startupMode = .savedCameras
        saved.discoveryTransportFilter = .wiFi
        saved.savedCameras = [wireless]
        #expect(!saved.discoveryBrowsesUSB, "a Wi-Fi-only camera list leaves USB alone")
        saved.pendingSetupIntent = .init(anchor: wireless, kind: .cameraAccessPoint)
        #expect(!saved.discoveryBrowsesUSB, "an armed wireless watch leaves USB alone")
        saved.pendingSetupIntent = .init(anchor: wireless, kind: .usbC)
        #expect(saved.discoveryBrowsesUSB, "an armed USB-C watch browses USB")
        saved.pendingSetupIntent = nil
        saved.savedCameras = [wireless, cabled]
        #expect(saved.discoveryBrowsesUSB, "a saved USB-C setup browses USB")
    }
}

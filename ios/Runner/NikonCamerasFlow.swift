import MonitorPresentation
import MonitorUI
import OpenCineApple
import OpenCineAppKit
import OpenCineCore
import OpenZCineCore
import SwiftUI

/// OpenZCine on the shared connection flow (SHELL-02): the saved-camera document with this app's
/// own records mirrored, and the `NikonConnectPort` over the app's discovery loop and connect
/// funnel. The funnel keeps its save rules: it writes the records as it always has, and every
/// write is merged into the document right away (`NativeCameraConnectionStore.onSavedCamerasChanged`).
@MainActor
enum NikonCameras {
    /// The document in the app's namespace; the records stay where every older build reads them
    /// (Keychain Wi-Fi keys, the GUID and the paired-host memory are never touched).
    static let documentKey = "OpenZCine.Cameras"
    static let legacyKey = "OpenZCine.PTPIP.SavedCameras"

    /// `onChange`: the shared page patched the records (a rename, a forgotten setup); the app
    /// reads them back.
    static func store(_ defaults: UserDefaults = .standard, onChange: @escaping () -> Void) -> SavedCamerasStore {
        SavedCamerasStore(
            document: .userDefaults(defaults, key: documentKey),
            legacy: .init(
                data: StoredData(
                    read: { defaults.data(forKey: legacyKey) },
                    write: {
                        defaults.set($0, forKey: legacyKey)
                        onChange()
                    }),
                codec: NikonSavedRecordsV0(), source: "records"))
    }

    /// The setups a camera could still add. HDMI capture is a picture source (iPad only), not a
    /// setup; Wi-Fi stays on offer however many are saved (one setup per network).
    static func missingKinds(_ records: [PTPIPSavedCameraRecord]) -> [CameraPath.Kind] {
        let saved = Set(records.compactMap(\.pathKind))
        var kinds: [CameraPath.Kind] = [.usbC, .cameraAccessPoint, .infrastructure, .phoneHotspot]
        if UVCVideoSource.isSupportedHardware { kinds.append(.hdmiCapture) }
        return kinds.filter { $0 == .infrastructure || !saved.contains($0) }
    }

    /// The records behind a saved camera, most recently seen first (its routes' hosts and kinds).
    static func records(of camera: SavedCamera, in records: [PTPIPSavedCameraRecord]) -> [PTPIPSavedCameraRecord] {
        camera.routes.compactMap { route in
            let host = route.extras[NikonSavedRecordsV0.Extra.host]
            return records.first {
                $0.host == host && $0.pathKind.map(NikonSavedRecordsV0.routeKind) == route.kind
            }
        }
    }
}

/// The app's pipeline as the Nikon integration sees it. One connect at a time, like the funnel.
@MainActor
final class NativeNikonPort: NikonConnectPort {
    var onSightings: (([DiscoveredCamera]) -> Void)?
    var onPhase: ((CameraConnectionPhase, String?) -> Void)?
    /// What the shared flow asks discovery for; `nil` while it is not listening.
    private(set) var requestedMode: DiscoveryMode?
    /// Screenshot staging (`ZC_DEMO_CARD`): `connecting` holds the card on its steps, `failed`
    /// fails it, without dialling anything.
    var demoOutcome: String?
    private unowned let model: NativeAppModel
    private var pending: CheckedContinuation<NikonConnection, Error>?
    private var attemptID = UUID()
    private var approvedTakeOvers: Set<String> = []

    init(model: NativeAppModel) { self.model = model }

    var savedRecords: [PTPIPSavedCameraRecord] { NativeCameraConnectionStore.shared.savedCameras() }

    func startDiscovery(_ mode: DiscoveryMode) {
        requestedMode = mode
        model.startDiscoveryForSharedFlow()
    }

    func stopDiscovery() { requestedMode = nil }

    /// Screenshot staging (`ZC_DEMO_NEARBY`): sightings no simulator network produces.
    var demoSightings: [DiscoveredCamera] = []

    /// Every discovery pass, from `applyDiscoveryResults`.
    func found(_ cameras: [DiscoveredCamera]) { onSightings?(cameras + demoSightings) }

    func connect(_ request: NikonConnectRequest) async throws -> NikonConnection {
        finish(.failure(CancellationError()))
        let token = UUID()
        attemptID = token
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending = continuation
                guard !Task.isCancelled else {
                    finish(.failure(CancellationError()))
                    return
                }
                if let demoOutcome {
                    stage(demoOutcome)
                    return
                }
                model.connectionProgressUsesCard = true
                model.lastConnectError = nil
                model.lastConnectFailureReason = nil
                do {
                    try model.runSharedConnect(request)
                    track()
                } catch {
                    model.connectionProgressUsesCard = false
                    finish(.failure(error))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard self?.attemptID == token else { return }
                self?.cancel()
            }
        }
    }

    func cancel() {
        guard pending != nil else { return }
        finish(.failure(CancellationError()))
        model.cancelConnectionAttempt()
        model.connectionProgressUsesCard = false
    }

    func forget(hosts: [String]) {
        for host in hosts { model.forgetPairing(host: host) }
    }

    func allowTakeOver(host: String) { approvedTakeOvers.insert(host) }

    func consumeTakeOver(host: String) -> Bool { approvedTakeOvers.remove(host) != nil }

    private func finish(_ result: Result<NikonConnection, Error>) {
        let waiter = pending
        pending = nil
        waiter?.resume(with: result)
    }

    /// Follows the funnel until it connects, fails or is dismissed, reporting each phase.
    private func track() {
        guard pending != nil else { return }
        withObservationTracking {
            _ = model.resolvedConnectionPhase
            _ = model.connectionStageDetail
            _ = model.connection
            _ = model.isConnectionProgressPresented
        } onChange: { [weak self] in
            Task { @MainActor in self?.track() }
        }
        observe()
    }

    private func observe() {
        guard pending != nil else { return }
        if let connection = model.sharedConnection {
            model.connectionProgressUsesCard = false
            model.isPairingNearby = false
            finish(.success(connection))
            return
        }
        let phase = model.resolvedConnectionPhase
        switch phase {
        case .failed:
            let failure = Self.failure(
                model.lastConnectError, reason: model.lastConnectFailureReason,
                message: model.connectionFailureDetail.isEmpty ? model.connectionMessage : model.connectionFailureDetail)
            // The card shows the failure now; the funnel's own sheet stands down.
            model.dismissConnectionProgress()
            finish(.failure(failure))
        case .idle where !model.isConnectionProgressPresented:
            finish(.failure(CancellationError()))
        case .idle, .connected:
            break
        default:
            onPhase?(phase, model.connectionStageDetail.isEmpty ? nil : model.connectionStageDetail)
        }
    }

    /// A failed connect, typed, in the funnel's own words, with its diagnostics report on offer.
    static func failure(_ error: (any Error)?, reason: ConnectionFailure.Reason?, message: String) -> ConnectionFailure {
        var failure =
            error.map { NikonIntegration.failure($0, message: message) }
            ?? ConnectionFailure(
                reason: reason ?? .other, title: "Couldn't connect", message: message,
                actions: reason == .permission(.localNetwork) ? [.openSettings, .retry] : [.retry],
                code: "\(NikonCameraSession.integration.rawValue).connect.failed")
        failure.actions.append(.integration(id: diagnosticsAction, title: "Share diagnostics"))
        return failure
    }

    static let diagnosticsAction = "diagnostics"
    static let takeOverAction = "takeOver"

    private func stage(_ outcome: String) {
        onPhase?(.discovering, nil)
        onPhase?(.handshaking, "Establishing a secure link with ZR_6002199.")
        guard outcome == "failed" else { return }
        finish(
            .failure(
                Self.failure(
                    NativeCameraSessionError.timeout("Camera handshake"), reason: nil,
                    message: "The camera didn't answer in time. Check it is on and on this network, then try again.")))
    }
}

/// The shared cameras page with this app's NEARBY rows (feeds other devices share, the filtered
/// network notice), its add-setup sheet and its take-over prompt.
struct NikonCamerasPage: View {
    @Environment(NativeAppModel.self) private var model
    let safeArea: EdgeInsets

    static let relayPrefix = "relay:"
    static let filterNoticeID = "notice:filter"

    var body: some View {
        CamerasScreen(
            model: model.cameras, brandName: "OpenZCine", nearbyNote: "on this network",
            safeArea: safeArea,
            onPair: {
                // A NEARBY camera's Pair picks it on the shared pair page; "Pair a new camera"
                // walks the wizard.
                if model.cameras.selection != nil {
                    model.isPairingNearby = true
                } else {
                    model.startFirstPairWizard()
                }
            },
            onMedia: { model.openCachedMediaLibrary() },
            onSettings: { model.openStandaloneSettings() },
            onMultiview: { model.beginMulticam() },
            onIntegrationAction: { cameraID, action in
                if action == NativeNikonPort.takeOverAction,
                    case .saved(let camera, let routeID) = model.cameras.failures[cameraID]?.target,
                    let host = camera.routes.first(where: { $0.id == routeID })?.extras[NikonSavedRecordsV0.Extra.host]
                {
                    model.nikonPort.allowTakeOver(host: host)
                    _ = model.cameras.perform(.retry, for: cameraID)
                    return
                }
                if action == NativeNikonPort.diagnosticsAction { model.shareDiagnostics() }
            },
            extraNearby: extraNearby,
            onExtraNearby: { id in
                guard let broadcast = model.visibleRelayBroadcasts.first(where: { Self.relayPrefix + $0.id == id })
                else { return }
                model.joinRelay(broadcast)
            })
        .onAppear {
            model.cameras.sessionEnded()
            model.cameras.reloadSaved()
            model.nikonPort.found(model.discoveredCameras)
        }
    }

    /// The filtered-network notice when proven, then the broadcasts another device shares.
    private var extraNearby: [CameraListItem] {
        var items: [CameraListItem] = []
        if model.networkFiltersDiscovery {
            items.append(
                CameraListItem(
                    id: Self.filterNoticeID, name: "This network", subtitle: "Cameras below were found directly",
                    status: "", actionTitle: "", isAvailable: false,
                    failure: CameraConnectFailure(
                        title: "Discovery is filtered",
                        message:
                            "This network blocks device discovery (multicast/mDNS is filtered), so devices can be unstable or missing here. OpenZCine is reaching them directly instead. For reliable discovery, disable multicast filtering and multicast minimum-rate limits on the router.",
                        actions: [])))
        }
        for broadcast in model.visibleRelayBroadcasts {
            items.append(
                CameraListItem(
                    id: Self.relayPrefix + broadcast.id, name: broadcast.name, subtitle: "Live feed from another device",
                    badge: "LIVE", status: "Watch this device's feed", actionTitle: "Watch"))
        }
        return items
    }
}

/// The add-setup slot: the app's own sheet for the camera's anchor setup. Its actions run once
/// the sheet has gone (a cover presented mid-dismissal is dropped).
struct NikonAddSetupSlot: View {
    let model: NativeAppModel
    let camera: SavedCamera
    let done: (RouteDraft?) -> Void

    var body: some View {
        let records = NikonCameras.records(of: camera, in: model.savedCameras)
        Group {
            if let anchor = records.first {
                StartupAddSetupSheet(
                    camera: anchor, missingKinds: NikonCameras.missingKinds(records),
                    addRoute: { done(RouteDraft(kind: NikonSavedRecordsV0.routeKind($0))) }
                )
                .environment(model)
            }
        }
        .onDisappear {
            done(nil)
            model.runPendingAddSetupAction()
        }
    }
}

/// Connecting would drop another device's session on this camera: the operator decides.
struct NikonTakeOverPromptView: View {
    let prompt: NikonTakeOverPrompt

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Take over \(prompt.camera)?")
                .font(MonitorTheme.font(15, weight: .semibold))
            Text(prompt.fallbackText)
                .font(MonitorTheme.font(12)).foregroundStyle(MonitorTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button("Cancel") { prompt.cancel() }
                    .buttonStyle(.bordered)
                Button("Take Over", role: .destructive) { prompt.confirm() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(maxWidth: 420, alignment: .leading)
        .background(MonitorTheme.surface, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityIdentifier("cameras.take-over")
    }
}

/// The app's own connect on the shared pair page: what the connection sheet showed, in the
/// page's rail and pane. The staged camera Wi-Fi to confirm (or scan), the live step, a manual
/// address after an empty search, and a failure with Try again and diagnostics.
@MainActor
struct NikonConnectFlow {
    let model: NativeAppModel

    private var phase: CameraConnectionPhase { model.resolvedConnectionPhase }

    func flow(steps: [CameraPairingStep], current: Int) -> IntegrationPairingFlow {
        IntegrationPairingFlow(
            presentation: presentation(steps: steps, current: current),
            onPrimary: primary,
            onBack: { model.cancelConnectionAttempt() },
            content: AnyView(NikonConnectPane().environment(model)))
    }

    func presentation(steps: [CameraPairingStep], current: Int) -> CameraPairingPresentation {
        let status = ConnectionProgressCopy.statusTitle(phase: phase, isUSB: model.connectionProgressIsUSB)
        let failed = phase == .failed
        let working = phase != .readyToJoin && phase != .connected && !failed
        return CameraPairingPresentation(
            steps: steps, currentStep: current,
            title: model.connectionProgressDeviceName, body: failed ? status : detail,
            target: model.connectionProgressDeviceName, hint: "",
            progress: working ? status : nil,
            error: failed ? failureDetail : nil,
            primaryAction: primaryTitle, primaryActionEnabled: true,
            backAction: failed ? "Close" : "Cancel")
    }

    private var needsScan: Bool { model.cameraWiFiJoinNeedsPassword && !model.cameraWiFiJoinHasPasswordDraft }

    private var primaryTitle: String? {
        switch phase {
        case .readyToJoin: needsScan ? "Scan SSID & key" : "Connect"
        // Retry in place: the failed attempt disposed everything a cancel would (#264).
        case .failed: "Try again"
        default: nil
        }
    }

    private func primary() {
        switch phase {
        case .readyToJoin where needsScan: model.presentCameraWiFiScanner()
        case .readyToJoin: model.confirmCameraWiFiJoin()
        case .failed: model.retryConnectionAttempt()
        default: break
        }
    }

    /// The live step beats a static phase line while a step is grinding; never the discovery
    /// loop's `connectionMessage`, which it keeps overwriting.
    private var detail: String {
        let stage = model.connectionStageDetail
        if !stage.isEmpty, phase != .connected, phase != .readyToJoin { return stage }
        return ConnectionProgressCopy.statusDetail(
            phase: phase, deviceName: model.connectionProgressDeviceName, friendlyError: nil,
            path: model.connectionProgressPathKind)
    }

    /// Pinned when the failure surfaced (`connectionFailureDetail`).
    private var failureDetail: String {
        if !model.connectionFailureDetail.isEmpty { return model.connectionFailureDetail }
        return ConnectionProgressCopy.statusDetail(
            phase: .failed, deviceName: model.connectionProgressDeviceName, friendlyError: nil,
            path: model.connectionProgressPathKind)
    }
}

/// The pair page's pane while the app's own connect runs (see `NikonConnectFlow`).
struct NikonConnectPane: View {
    @Environment(NativeAppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 10) {
            switch model.resolvedConnectionPhase {
            case .readyToJoin:
                if model.cameraWiFiJoinNeedsPassword, !model.cameraWiFiJoinHasPasswordDraft {
                    caption("Point at your camera's Connection wizard screen.")
                } else if model.cameraWiFiJoinKeyFromScan {
                    // Editable: OCR misreads a character now and then (0/O, 1/l, 5/S, 8/B), and
                    // either field can misread. A wrong key is refused; a wrong name never appears.
                    field("Network", $model.cameraWiFiJoinSSIDDraft, "Camera Wi-Fi network name")
                    field("Key", $model.cameraWiFiJoinPasswordDraft, "Camera Wi-Fi key")
                    caption("Scanned from the camera screen. Tap to fix anything that misread.")
                } else if model.cameraWiFiJoinHasPasswordDraft {
                    caption("Wi-Fi details entered manually. Connect when they match the camera.")
                }
            case .failed:
                Button(model.isPreparingDiagnostics ? "Preparing…" : "Share diagnostics") { model.shareDiagnostics() }
                    .buttonStyle(CameraPageButtonStyle())
                    .disabled(model.isPreparingDiagnostics)
            case .connected:
                Label("Connected", systemImage: "checkmark.circle.fill")
                    .font(MonitorTheme.font(13, weight: .semibold))
            default:
                // After a typed empty infrastructure search: the address on the camera's screen.
                if model.showsManualCameraHostEntry || model.isManualCameraHostEntryPresented {
                    manualHostEntry
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var manualHostEntry: some View {
        @Bindable var model = model
        if model.isManualCameraHostEntryPresented {
            TextField("Camera IP (e.g. 192.168.1.246)", text: $model.manualCameraHostDraft)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.numbersAndPunctuation)
                .modifier(NikonFieldStyle())
            Button("Connect to this address") { model.connectToManualCameraHost(model.manualCameraHostDraft) }
                .buttonStyle(CameraPageButtonStyle(primary: true))
                .disabled(model.manualCameraHostDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } else {
            Button("Enter address from camera") { model.isManualCameraHostEntryPresented = true }
                .buttonStyle(CameraPageButtonStyle())
                .accessibilityHint("Opens a field for the IP shown on the camera network menu")
        }
    }

    private func field(_ title: String, _ text: Binding<String>, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(MonitorTheme.font(8, weight: .bold)).tracking(1.3)
                .foregroundStyle(MonitorTheme.faint)
            TextField(title, text: text)
                .font(.body.monospaced())
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .modifier(NikonFieldStyle())
                .accessibilityLabel(label)
                .accessibilityHint("Scanned from the camera screen. Edit it if it misread.")
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(MonitorTheme.font(12)).foregroundStyle(MonitorTheme.muted)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct NikonFieldStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
    }
}

/// The app's own connect outside the wizard (a camera-AP join from add-setup, the internet-hop
/// rejoin, a reconnect it starts itself) on the shared pair page.
struct NikonConnectScreen: View {
    @Environment(NativeAppModel.self) private var model
    let safeArea: EdgeInsets

    var body: some View {
        PairScreen(
            model: model.cameras, safeArea: safeArea,
            onDone: { model.cancelConnectionAttempt() },
            onDiagnostics: { model.shareDiagnostics() },
            onReportProblem: { model.isBugReportPresented = true },
            pairingFlow: NikonConnectFlow(model: model).flow(
                steps: [CameraPairingStep("Connect", "")], current: 0))
    }
}

extension NativeAppModel {
    func makeCamerasModel() -> CamerasModel {
        let slots = IntegrationSlots(
            addRoute: { [unowned self] camera, done in
                AnyView(NikonAddSetupSlot(model: self, camera: camera, done: done))
            },
            prompt: { prompt in
                (prompt as? NikonTakeOverPrompt).map { AnyView(NikonTakeOverPromptView(prompt: $0)) }
            })
        // The rebrand-key move runs before the shared store reads the records.
        _ = NativeCameraConnectionStore.shared
        let cameras = CamerasModel(
            integrations: [AppIntegration(NikonIntegration(port: nikonPort), slots: slots)],
            store: NikonCameras.store { [weak self] in self?.reloadSavedCameraRecords() })
        NativeCameraConnectionStore.shared.onSavedCamerasChanged = { [weak cameras] in cameras?.reloadSaved() }
        return cameras
    }

    /// Starts one of the funnel's connects for the shared flow, as the camera rows used to.
    func runSharedConnect(_ request: NikonConnectRequest) throws {
        switch request {
        case .saved(let host, let path):
            guard
                let record = savedCameras.first(where: {
                    $0.host == PTPIPPairedHosts.normalizedHost(host) && $0.pathKind == path
                })
            else {
                throw ConnectionFailure(
                    reason: .notFound, title: "Setup unavailable", message: "This saved setup is no longer available.",
                    actions: [.pairAgain], code: "nikon.setup.gone")
            }
            let availability = SavedCameraAvailabilityPolicy.resolve(
                camera: record, discoveredCameras: discoveredCameras, connectedHost: connectedIdentity?.host,
                onCameraAccessPoint: isOnCameraAccessPointNetwork,
                hotspotSubnetBases: NativeNetworkInterfaceSnapshot.hotspotSubnetBases())
            if case .available(let discovered) = availability {
                let approved = nikonPort.consumeTakeOver(host: host)
                if discovered.isHeldByAnotherDevice, !approved {
                    throw ConnectionFailure(
                        reason: .heldElsewhere, title: "Camera in use",
                        message: discovered.heldByLabel ?? "Another device is using this camera.",
                        actions: [.integration(id: NativeNikonPort.takeOverAction, title: "Take over"), .retry],
                        code: "nikon.held")
                }
                connectToCamera(discovered, setup: record, takingOverConfirmed: approved)
            } else {
                connectSavedCamera(record)
            }
        case .discovered(let camera, let takeOver):
            connectToCamera(camera, takingOverConfirmed: takeOver)
        case .addSetup(let anchorHost, let anchorPath, let path):
            // Adding a setup arms the funnel's watch for the body on that path.
            guard
                let anchor = savedCameras.first(where: {
                    $0.host == PTPIPPairedHosts.normalizedHost(anchorHost) && $0.pathKind == anchorPath
                })
            else {
                throw ConnectionFailure(
                    reason: .notFound, title: "Setup unavailable", message: "This saved setup is no longer available.",
                    actions: [.pairAgain], code: "nikon.setup.gone")
            }
            pendingSetupIntent = .init(anchor: anchor, kind: path)
            presentSetupWatchProgress(for: anchor, kind: path)
            // A pass now: a path that is already reachable connects without waiting.
            Task { await refreshCameraDiscovery() }
        }
    }
}

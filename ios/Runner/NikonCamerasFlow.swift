import MonitorPresentation
import MonitorUI
import OpenCineAppKit
import OpenCineApple
import OpenCineCore
import OpenZCineCore
import SwiftUI
import os

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
    static func store(_ defaults: UserDefaults = .standard, onChange: @escaping () -> Void)
        -> SavedCamerasStore
    {
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
    static func records(of camera: SavedCamera, in records: [PTPIPSavedCameraRecord])
        -> [PTPIPSavedCameraRecord]
    {
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
    /// Weak: the shared integration owns this port, and its discovery and connect tasks can
    /// outlive the model (a model torn down while a stream's termination hop is queued). A
    /// call that arrives after the model is gone does nothing instead of trapping.
    private weak var model: NativeAppModel?
    private var pending: CheckedContinuation<NikonConnection, Error>?
    private var attemptID = UUID()

    init(model: NativeAppModel) { self.model = model }

    var savedRecords: [PTPIPSavedCameraRecord] { NativeCameraConnectionStore.shared.savedCameras() }

    func startDiscovery(_ mode: DiscoveryMode) {
        requestedMode = mode
        model?.startDiscoveryForSharedFlow()
    }

    func stopDiscovery() { requestedMode = nil }

    /// Screenshot staging (`ZC_DEMO_NEARBY`): sightings no simulator network produces.
    var demoSightings: [DiscoveredCamera] = []

    /// Every discovery pass, from `applyDiscoveryResults`. A liveness answer at a camera
    /// access point's address (192.168.1.1 by convention, also the commonest home router) says
    /// nothing about the camera unless this phone is on that access point, as the old list ruled.
    func found(_ cameras: [DiscoveredCamera]) {
        guard let model else { return }
        let accessPoints =
            model.isOnCameraAccessPointNetwork ? [] : model.savedCameraAccessPointHosts
        let visible = cameras.filter { camera in
            camera.source != .liveness
                || !accessPoints.contains(PTPIPPairedHosts.normalizedHost(camera.ip) ?? camera.ip)
        }
        onSightings?(visible + demoSightings)
    }

    func connect(_ request: NikonConnectRequest) async throws -> NikonConnection {
        try await connect(request, takingOverConfirmed: false)
    }

    /// A fresh presence sweep: the list's held rows can predate the phone that went live.
    func currentHolder(of host: String) async -> String? {
        guard demoOutcome == nil else { return nil }
        return await NativeNikonDiscovery.shared.currentHolder(of: host)
    }

    func connect(_ request: NikonConnectRequest, takingOverConfirmed: Bool) async throws
        -> NikonConnection
    {
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
                    model?.nikonConnectReleaseWatch = NikonConnectReleaseWatch { [weak self] in
                        Task { @MainActor in self?.modelReleased(during: token) }
                    }
                    stage(demoOutcome)
                    return
                }
                guard let model else {
                    finish(.failure(CancellationError()))
                    return
                }
                model.connectionProgressUsesCard = true
                model.lastConnectError = nil
                model.lastConnectFailureReason = nil
                do {
                    try model.runSharedConnect(request, takingOverConfirmed: takingOverConfirmed)
                    model.watchNikonConnectRelease { [weak self] in
                        Task { @MainActor in self?.modelReleased(during: token) }
                    }
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
        model?.cancelConnectionAttempt()
        model?.connectionProgressUsesCard = false
    }

    func forget(hosts: [String]) {
        for host in hosts { model?.forgetPairing(host: host) }
    }

    /// The model went away while attempt `token` waited: nothing is left to cancel but the wait.
    private func modelReleased(during token: UUID) {
        guard attemptID == token else { return }
        finish(.failure(CancellationError()))
    }

    private func finish(_ result: Result<NikonConnection, Error>) {
        let waiter = pending
        pending = nil
        waiter?.resume(with: result)
    }

    /// Follows the funnel until it connects, fails or is dismissed, reporting each phase.
    private func track() {
        guard pending != nil else { return }
        guard let model else { return finish(.failure(CancellationError())) }
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
        guard let model else { return finish(.failure(CancellationError())) }
        if let connection = model.sharedConnection {
            model.connectionProgressUsesCard = false
            model.shell.endPairing()
            finish(.success(connection))
            return
        }
        let phase = model.resolvedConnectionPhase
        switch phase {
        case .failed:
            let failure = Self.failure(
                model.lastConnectError, reason: model.lastConnectFailureReason,
                message: model.connectionFailureDetail.isEmpty
                    ? model.connectionMessage : model.connectionFailureDetail)
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
    static func failure(_ error: (any Error)?, reason: ConnectionFailure.Reason?, message: String)
        -> ConnectionFailure
    {
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

    private func stage(_ outcome: String) {
        onPhase?(.discovering, nil)
        onPhase?(.handshaking, "Establishing a secure link with ZR_6002199.")
        guard outcome == "failed" else { return }
        finish(
            .failure(
                Self.failure(
                    NativeCameraSessionError.timeout("Camera handshake"), reason: nil,
                    message:
                        "The camera didn't answer in time. Check it is on and on this network, then try again."
                )))
    }
}

/// Ends a pending Nikon connect when its model releases the active watch.
/// Disarm a superseded watch before replacement so shared native work keeps running.
final class NikonConnectReleaseWatch: Sendable {
    private let onRelease: OSAllocatedUnfairLock<(@Sendable () -> Void)?>

    init(_ onRelease: @escaping @Sendable () -> Void) {
        self.onRelease = .init(initialState: onRelease)
    }

    /// Retires this watch without cancelling work owned by its replacement.
    func disarm() { onRelease.withLock { $0 = nil } }

    deinit { onRelease.withLock { $0 }?() }
}

/// Host setup capabilities, live reachability and actions for the shared typed chooser. The
/// chooser and its copy are OpenCine's (`StationNetworkSetupRules.setupChooser`), the same one
/// every app shows; this host adds USB-C, the camera's Wi-Fi and HDMI capture as routes and keeps
/// what each one does.
@MainActor
struct NikonSetupOptions {
    let model: NativeAppModel
    let camera: PTPIPSavedCameraRecord

    static func flow(
        model: NativeAppModel, camera: SavedCamera, done: @escaping (RouteDraft?) -> Void
    ) -> AddSetupFlow {
        let records = NikonCameras.records(of: camera, in: model.savedCameras)
        guard let anchor = records.first else {
            return AddSetupFlow(
                chooser: StationNetworkSetupRules.setupChooser(
                    context: .camera(camera), routes: []),
                onSelect: { _ in }, onCancel: { done(nil) })
        }
        let host = Self(model: model, camera: anchor)
        let routes = NikonCameras.missingKinds(records).map { kind in
            StationSetupRoute(
                NikonSavedRecordsV0.routeKind(kind),
                actionTitle: actionTitle(
                    for: kind, reachable: host.discoveredMatch(for: kind) != nil))
        }
        return AddSetupFlow(
            chooser: StationNetworkSetupRules.setupChooser(
                context: .camera(camera), routes: routes),
            onSelect: { option in
                switch NikonSavedRecordsV0.pathKind(option.kind) {
                case .cameraAccessPoint:
                    model.pendingAddSetupAction = { [weak model] in
                        model?.beginAddCameraAPSetup(for: anchor)
                    }
                    done(nil)
                case .hdmiCapture:
                    model.pendingAddSetupAction = { [weak model] in model?.startHDMIMonitorSession()
                    }
                    done(nil)
                case .usbC, .infrastructure, .phoneHotspot:
                    done(RouteDraft(kind: option.kind))
                }
            },
            onDismiss: {
                done(nil)
                model.runPendingAddSetupAction()
            }, onCancel: { done(nil) })
    }

    /// The live words of a route's action: what tapping it does right now.
    static func actionTitle(for kind: CameraPath.Kind, reachable: Bool) -> String {
        switch kind {
        case .cameraAccessPoint: return "Join camera Wi-Fi"
        case .usbC: return reachable ? "Connect now" : "Connect when plugged in"
        case .infrastructure: return reachable ? "Connect now" : "Find on this network"
        case .phoneHotspot: return "Wait for camera"
        case .hdmiCapture: return "Use HDMI capture"
        }
    }

    /// The discovered camera that would satisfy this kind RIGHT NOW, if any.
    private func discoveredMatch(for kind: CameraPath.Kind) -> DiscoveredCamera? {
        switch kind {
        case .usbC:
            return model.discoveredCameras.first { $0.source == .usb }
        case .infrastructure:
            // On the camera's own AP this body is discovered, over a network the Wi-Fi
            // setup can't use. Same rule as the availability chips: no route, no match.
            guard !model.isOnCameraAccessPointNetwork else { return nil }
            let accessPointHosts = model.savedCameraAccessPointHosts
            return model.discoveredCameras.first { discovered in
                // A camera-AP record's host is an address on the CAMERA's own network:
                // 192.168.1.1 by convention, which is also the commonest home-router address
                // there is. Something answering there is either the camera on its access
                // point (a different setup) or the operator's router, and the liveness dial
                // this row can come from, a kernel RST, cannot tell those apart. Either
                // way it is never the Wi-Fi setup being added. Left in, a saved Camera AP
                // setup put "Connect Now" on the Wi-Fi row of a camera that was nowhere on
                // this network, and the connect it offered dialled the router.
                guard let host = PTPIPPairedHosts.normalizedHost(discovered.ip),
                    !accessPointHosts.contains(host)
                else { return false }
                return discovered.source != .usb
                    && CameraStartupPolicy.savedCamera(
                        forDiscovered: discovered, in: [camera]) != nil
            }
        case .cameraAccessPoint, .phoneHotspot, .hdmiCapture:
            return nil
        }
    }
}

/// The app's own connect on the shared pair page: what the connection sheet showed, in the
/// page's rail and pane. The staged camera Wi-Fi to confirm (or scan), the live step, a manual
/// address after an empty search, and a failure with Try again and diagnostics.
@MainActor
struct NikonConnectFlow {
    let model: NativeAppModel

    var phase: CameraConnectionPhase {
        let phase = model.resolvedConnectionPhase
        // An established session without its first frame is still preparing live view, with or
        // without the progress sheet (live view that never started leaves the sheet dismissed).
        let established = model.isConnected || model.connection == .preparingLiveView
        if established, !model.isMonitorPresented, phase == .connected || phase == .idle {
            return .preparingLiveView
        }
        return phase
    }

    func flow(steps: [CameraPairingStep], current: Int) -> IntegrationPairingFlow {
        IntegrationPairingFlow(
            presentation: presentation(steps: steps, current: current),
            onPrimary: primary,
            onBack: {
                // The progress owner tears down its attempt, an established session included.
                // Without it (live view never started), Back ends the session directly.
                if !model.isConnectionProgressPresented,
                    model.isConnected || model.connection == .preparingLiveView
                {
                    model.disconnect()
                } else {
                    model.cancelConnectionAttempt()
                }
            },
            content: AnyView(NikonConnectPane().environment(model)))
    }

    func presentation(steps: [CameraPairingStep], current: Int) -> CameraPairingPresentation {
        let status = ConnectionProgressCopy.statusTitle(
            phase: phase, isUSB: model.connectionProgressIsUSB)
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

    private var needsScan: Bool {
        model.cameraWiFiJoinNeedsPassword && !model.cameraWiFiJoinHasPasswordDraft
    }

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
        // Without the progress sheet the session's own message (a live view that did not start,
        // a reconnect) is the useful line.
        if !model.isConnectionProgressPresented, !model.userFacingConnectionMessage.isEmpty {
            return model.userFacingConnectionMessage
        }
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
            switch NikonConnectFlow(model: model).phase {
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
                Button(model.isPreparingDiagnostics ? "Preparing…" : "Share diagnostics") {
                    model.shareDiagnostics()
                }
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
            Button("Connect to this address") {
                model.connectToManualCameraHost(model.manualCameraHostDraft)
            }
            .buttonStyle(CameraPageButtonStyle(primary: true))
            .disabled(
                model.manualCameraHostDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
        let flow = NikonConnectFlow(model: model).flow(
            steps: [CameraPairingStep("Connect", "")], current: 0)
        // Presentation only: this established/app-owned connection must not start pair discovery.
        PairCameraPage(
            presentation: flow.presentation, safeArea: safeArea,
            onSelect: flow.onSelect, onPrimary: flow.onPrimary, onBack: flow.onBack,
            onDiagnostics: { model.shareDiagnostics() },
            onReportProblem: { model.isBugReportPresented = true },
            extra: { flow.content })
    }
}

extension NativeAppModel {
    func makeCamerasModel() -> CamerasModel {
        let slots = DemoHarness.addSetupSlots(
            IntegrationSlots(
                addSetup: { [unowned self] camera, done in
                    NikonSetupOptions.flow(model: self, camera: camera, done: done)
                }))
        // The rebrand-key move runs before the shared store reads the records.
        _ = NativeCameraConnectionStore.shared
        let cameras = CamerasModel(
            integrations: [AppIntegration(NikonIntegration(port: nikonPort), slots: slots)],
            store: NikonCameras.store { [weak self] in self?.reloadSavedCameraRecords() },
            // A reachable setup beats a newer offline one (Nikon main's row rule).
            routePolicy: .preferReachable)
        NativeCameraConnectionStore.shared.onSavedCamerasChanged = { [weak cameras] in
            cameras?.reloadSaved()
        }
        return cameras
    }

    /// Starts one of the funnel's connects for the shared flow, as the camera rows used to.
    func runSharedConnect(_ request: NikonConnectRequest, takingOverConfirmed: Bool = false) throws
    {
        switch request {
        case .saved(let host, let path):
            guard
                let record = savedCameras.first(where: {
                    $0.host == PTPIPPairedHosts.normalizedHost(host) && $0.pathKind == path
                })
            else {
                throw ConnectionFailure(
                    reason: .notFound, title: "Setup unavailable",
                    message: "This saved setup is no longer available.",
                    actions: [.pairAgain], code: "nikon.setup.gone")
            }
            let availability = SavedCameraAvailabilityPolicy.resolve(
                camera: record, discoveredCameras: discoveredCameras,
                connectedHost: connectedIdentity?.host,
                onCameraAccessPoint: isOnCameraAccessPointNetwork,
                hotspotSubnetBases: NativeNetworkInterfaceSnapshot.hotspotSubnetBases())
            if case .available(let discovered) = availability {
                let approved = takingOverConfirmed
                if discovered.isHeldByAnotherDevice, !approved {
                    throw ConnectionFailure(
                        reason: .heldElsewhere, title: "Camera in use",
                        message: NikonTakeOverPrompt.message(holder: discovered.heldByDeviceName),
                        actions: [.retry],
                        code: "nikon.held")
                }
                connectToCamera(
                    discovered, setup: record, takingOverConfirmed: approved,
                    operatorRequested: true)
            } else {
                connectSavedCamera(record)
            }
        case .discovered(let camera, let takeOver):
            connectToCamera(
                camera, takingOverConfirmed: takeOver || takingOverConfirmed,
                operatorRequested: true)
        case .addSetup(let anchorHost, let anchorPath, let path):
            // Adding a setup arms the funnel's watch for the body on that path.
            guard
                let anchor = savedCameras.first(where: {
                    $0.host == PTPIPPairedHosts.normalizedHost(anchorHost)
                        && $0.pathKind == anchorPath
                })
            else {
                throw ConnectionFailure(
                    reason: .notFound, title: "Setup unavailable",
                    message: "This saved setup is no longer available.",
                    actions: [.pairAgain], code: "nikon.setup.gone")
            }
            pendingSetupIntent = .init(anchor: anchor, kind: path)
            presentSetupWatchProgress(for: anchor, kind: path)
            // A pass now: a path that is already reachable connects without waiting.
            Task { await refreshCameraDiscovery() }
        }
    }
}

import MonitorPresentation
import MonitorUI
import OpenCineAppKit
import OpenZCineCore
import SwiftUI

/// The shared root (`AppShell`): the camera monitor, the shared cameras and pair pages with this
/// app's own pages before them (the first-pair wizard, preparing live view, its own connect),
/// and the standalone Media and Settings covers.
struct LinkExperience: View {
    @Environment(NativeAppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL

    static let relayPrefix = "relay:"
    static let filterNoticeID = "notice:filter"

    var body: some View {
        // The pages' ground and ink; the monitor keeps its own.
        let pages = model.shell.monitor == nil
        AppShell(
            model: model.shell, brand: ShellBrand(name: "OpenZCine", nearbyNote: "on this network"),
            actions: actions, extraNearby: extraNearby, coverPresentation: .shell, prePage: prePage
        ) { _ in
            MonitorExperience()
        } page: { cover in
            NikonCoverPage(cover: cover)
        }
        .background {
            if pages { MonitorTheme.background.ignoresSafeArea() }
        }
        .foregroundStyle(pages ? AnyShapeStyle(MonitorTheme.text) : AnyShapeStyle(.primary))
        // Scanner blur backdrop lives on the presenter (not inside the fullScreenCover) so it
        // fades in place via opacity while the card keeps the cover's slide — the backdrop must
        // not ride the vertical slide.
        .overlay {
            ZStack {
                if model.isCameraWiFiScannerPresented {
                    scannerBlurBackdrop
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.15), value: model.isCameraWiFiScannerPresented)
        }
        .onAppear {
            model.prepareStartup()
            Task {
                await model.refreshConnectedWiFiSSID()
            }
        }
        .onChange(of: showsCamerasPage, initial: true) { _, shows in
            guard shows else { return }
            model.cameras.sessionEnded()
            model.cameras.reloadSaved()
            model.nikonPort.found(model.discoveredCameras)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task {
                    await model.refreshConnectedWiFiSSID()
                }
            }
        }
        .alert("Pair with camera?", isPresented: pairingAlertPresented) {
            Button("Cancel", role: .cancel) {
                model.rejectPairing()
            }
            Button("Pair") {
                model.acceptPairing()
            }
        } message: {
            Text(pairingAlertMessage)
        }
        .alert("Wi‑Fi is off", isPresented: Bindable(model).isWiFiOffPromptPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(
                "Joining the camera's Wi‑Fi needs Wi‑Fi turned on. Enable it in Control Center or Settings, then try again."
            )
        }
        .alert(
            "Leave the camera's Wi‑Fi",
            isPresented: Bindable(model).isWatcherOnCameraAPNoticePresented
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(
                "This device is on the camera's own Wi‑Fi, which doesn't pass traffic between devices — the broadcast can't reach it here. Switch to your regular Wi‑Fi, then join."
            )
        }
        // Owned at the root so the credential scanner can present directly from the join/scan
        // action and from the pair page's join step.
        .cameraWiFiScannerCover(model)
        .sheet(item: Bindable(model).diagnosticsShareItem) { DiagnosticsShareSheet(url: $0.url) }
        .alert(
            "Couldn't Share Diagnostics",
            isPresented: Binding(
                get: { model.diagnosticsErrorMessage != nil },
                set: { if !$0 { model.diagnosticsErrorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.diagnosticsErrorMessage ?? "Please try again.")
        }
    }

    /// Blurred dim layer shown behind the credential-scanner card. Purely visual — tap-to-dismiss
    /// is owned by the transparent catcher inside the scanner cover, since this layer sits beneath
    /// the cover and cannot receive its touches.
    private var scannerBlurBackdrop: some View {
        Rectangle()
            .fill(.regularMaterial)
            // A faint dim over the blur lifts the light card off the (often bright) app behind it.
            .overlay(Color.black.opacity(0.12))
            .ignoresSafeArea()
            .allowsHitTesting(false)
    }

    /// The page this app shows before the shared ones, if any (SHELL-02): the wizard, the ready
    /// page while a connected camera's live view starts, the app's own connect in progress.
    private var prePageKind: NikonPrePage.Kind? {
        if model.shouldShowFirstPairWizard { return .wizard }
        if model.isConnected { return .preparing }
        if model.showsAppConnectProgress { return .connecting }
        return nil
    }

    private func prePage(_ safeArea: EdgeInsets) -> NikonPrePage? {
        prePageKind.map { NikonPrePage(kind: $0, safeArea: safeArea) }
    }

    /// The shared cameras page is the one showing.
    private var showsCamerasPage: Bool { model.shell.route == .cameras && prePageKind == nil }

    private var actions: ShellActions {
        ShellActions(
            diagnostics: { model.shareDiagnostics() },
            reportProblem: { model.isBugReportPresented = true },
            multiview: MulticamCoordinator.tileCount > 1 ? { model.beginMulticam() } : nil,
            integrationAction: { cameraID, action in
                if action == NativeNikonPort.takeOverAction,
                    case .saved(let camera, let routeID) = model.cameras.failures[cameraID]?.target,
                    let host = camera.routes.first(where: { $0.id == routeID })?.extras[
                        NikonSavedRecordsV0.Extra.host]
                {
                    model.nikonPort.allowTakeOver(host: host)
                    _ = model.cameras.perform(.retry, for: cameraID)
                    return
                }
                if action == NativeNikonPort.diagnosticsAction { model.shareDiagnostics() }
            },
            privacy: { openURL(SupportLinkCatalog.privacy) },
            terms: { openURL(SupportLinkCatalog.terms) },
            pair: {
                // A NEARBY camera's Pair picks it on the shared pair page; "Pair a new camera"
                // walks the wizard.
                if model.cameras.selection != nil {
                    model.shell.beginPairing()
                } else {
                    model.startFirstPairWizard()
                }
            },
            media: { model.openCachedMediaLibrary() },
            settings: { model.openStandaloneSettings() },
            extraNearby: { id in
                guard
                    let broadcast = model.visibleRelayBroadcasts.first(where: {
                        Self.relayPrefix + $0.id == id
                    })
                else { return }
                model.joinRelay(broadcast)
            })
    }

    /// The filtered-network notice when proven, then the broadcasts another device shares.
    private var extraNearby: [CameraListItem] {
        var items: [CameraListItem] = []
        if model.networkFiltersDiscovery {
            items.append(
                CameraListItem(
                    id: Self.filterNoticeID, name: "This network",
                    subtitle: "Cameras below were found directly",
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
                    id: Self.relayPrefix + broadcast.id, name: broadcast.name,
                    subtitle: "Live feed from another device",
                    badge: "LIVE", status: "Watch this device's feed", actionTitle: "Watch"))
        }
        return items
    }

    private var pairingAlertPresented: Binding<Bool> {
        Binding(
            get: { model.pendingPairingChallenge != nil },
            set: { isPresented in
                if !isPresented, model.pendingPairingChallenge != nil {
                    model.rejectPairing()
                }
            }
        )
    }

    private var pairingAlertMessage: String {
        guard let challenge = model.pendingPairingChallenge else {
            return "Confirm the pairing request on the camera, then tap Pair."
        }
        let cameraName = challenge.cameraName ?? "your camera"
        if let pin = challenge.pin {
            return "Make sure code \(pin) matches on \(cameraName), then tap Pair."
        }
        return "Confirm the pairing request from \(cameraName), then tap Pair."
    }
}

/// This app's pages before the shared ones, laid out in the safe area the shell hands them.
struct NikonPrePage: View {
    enum Kind {
        case wizard
        case preparing
        case connecting
    }

    @Environment(NativeAppModel.self) private var model
    let kind: Kind
    let safeArea: EdgeInsets

    var body: some View {
        // The shell's pages ignore the safe area; the layout fits what is left of it.
        GeometryReader { proxy in
            let layout = StartupContentLayout.fit(
                viewportWidth: Double(proxy.size.width - safeArea.leading - safeArea.trailing),
                viewportHeight: Double(proxy.size.height - safeArea.top - safeArea.bottom),
                safeArea: MonitorEdgeInsets(
                    top: Double(safeArea.top), leading: Double(safeArea.leading),
                    bottom: Double(safeArea.bottom), trailing: Double(safeArea.trailing)))
            switch kind {
            case .wizard:
                StartupFirstPairWizardView(
                    isBusy: model.isStartupActionLocked, contentLayout: layout, safeArea: safeArea)
            case .preparing:
                StartupPreparingLiveView(compact: layout.mode == .singleColumn)
                    .padding(
                        EdgeInsets(
                            top: safeArea.top + 24, leading: safeArea.leading + 24,
                            bottom: safeArea.bottom + 24, trailing: safeArea.trailing + 24))
            case .connecting:
                NikonConnectScreen(safeArea: safeArea)
            }
        }
    }
}

/// The standalone Media and Settings covers: the cameras page's, or a panel an internet hop
/// re-hosts once the monitor has gone.
private struct NikonCoverPage: View {
    @Environment(NativeAppModel.self) private var model
    let cover: ShellModel.Cover

    var body: some View {
        MonitorCoverPage { insets in
            let safeArea = MonitorEdgeInsets(
                top: Double(insets.top),
                leading: Double(insets.leading),
                bottom: Double(insets.bottom),
                trailing: Double(insets.trailing))
            switch cover {
            case .media: MediaBrowserView(safeArea: safeArea)
            case .settings: OperatorSettingsPanel(safeArea: safeArea)
            }
        }
        .background(MonitorTheme.background.ignoresSafeArea())
        // A cover, like the full-screen presentation it replaces: VoiceOver stays on it.
        .accessibilityAddTraits(.isModal)
    }
}

extension View {
    /// The camera Wi‑Fi credential scanner, mounted on a surface that is free to present it.
    /// `active` picks which of the two mounts is the live one — see the call sites.
    fileprivate func cameraWiFiScannerCover(
        _ model: NativeAppModel,
        active: Bool = true
    ) -> some View {
        fullScreenCover(
            isPresented: active
                ? Bindable(model).isCameraWiFiScannerPresented : .constant(false)
        ) {
            CameraWiFiScannerScreen(
                onCapture: { model.applyScannedCameraWiFi(ssid: $0.ssid, key: $0.key) },
                onManualEntry: { model.applyManualCameraWiFi(ssid: $0.ssid, key: $0.key) },
                onCancel: { model.isCameraWiFiScannerPresented = false },
                startsInManualEntry: DemoHarness.cameraWiFiScannerMode == "manual"
            )
        }
    }
}

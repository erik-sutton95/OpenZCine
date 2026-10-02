import OpenCineAppKit
import OpenZCineCore
import SwiftUI

struct LinkExperience: View {
    @Environment(NativeAppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL

    var body: some View {
        // The safe area is read here and handed to the shared pages, which draw edge to edge.
        GeometryReader { proxy in
            page(proxy)
                .ignoresSafeArea()
        }
        .background(StartupColors.backdrop.ignoresSafeArea())
        .foregroundStyle(StartupColors.ink)
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

    /// The shared pages (SHELL-02): the wizard and the app's own connects on the pair page, the
    /// saved cameras on the cameras page.
    @ViewBuilder private func page(_ proxy: GeometryProxy) -> some View {
        let safeArea = proxy.safeAreaInsets
        let layout = StartupContentLayout.fit(
            viewportWidth: Double(proxy.size.width), viewportHeight: Double(proxy.size.height),
            safeArea: proxy.monitorEdgeInsets)
        if model.shouldShowFirstPairWizard {
            StartupFirstPairWizardView(
                isBusy: model.isStartupActionLocked, contentLayout: layout, safeArea: safeArea)
        } else if model.isConnected {
            StartupPreparingLiveView(compact: layout.mode == .singleColumn)
                .padding(
                    EdgeInsets(
                        top: safeArea.top + 24, leading: safeArea.leading + 24,
                        bottom: safeArea.bottom + 24,
                        trailing: safeArea.trailing + 24))
        } else if model.showsAppConnectProgress {
            NikonConnectScreen(safeArea: safeArea)
        } else if model.isPairingNearby {
            PairScreen(
                model: model.cameras, safeArea: safeArea,
                onDone: { model.isPairingNearby = false },
                onDiagnostics: { model.shareDiagnostics() },
                onReportProblem: { model.isBugReportPresented = true },
                onPrivacy: { openURL(SupportLinkCatalog.privacy) },
                onTerms: { openURL(SupportLinkCatalog.terms) })
        } else {
            NikonCamerasPage(safeArea: safeArea)
        }
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

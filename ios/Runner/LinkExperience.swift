import SwiftUI

struct LinkExperience: View {
    @Environment(NativeAppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        GeometryReader { proxy in
            let contentLayout = StartupContentLayout.fit(
                viewportWidth: Double(proxy.size.width),
                viewportHeight: Double(proxy.size.height),
                safeArea: proxy.monitorEdgeInsets
            )
            let compact = contentLayout.mode == .singleColumn
            let contentMargins = StartupLayoutMargins.content(
                for: proxy.monitorEdgeInsets,
                compact: compact
            )
            let headerMargins = StartupLayoutMargins.header(
                for: proxy.monitorEdgeInsets,
                compact: compact
            )
            let contentHorizontalAlignment = StartupContentHorizontalAlignment.resolve(
                profile: contentLayout.profile,
                safeArea: proxy.monitorEdgeInsets
            )

            let wizardFillsViewport = model.shouldShowFirstPairWizard
            // Proportional vertical rhythm: wizard gaps derive from viewport height (clamped) so
            // taller devices breathe more; horizontal columns are already fraction-based.
            let viewportHeight = Double(proxy.size.height)
            // Landscape: percentage-of-height top margin keeps the header clear of the top edge on
            // every device. Portrait has abundant height — pin the header near the top; the
            // percentage margin is a landscape-band budget and reads as a dead gap when tall.
            let isPortraitViewport = proxy.size.height > proxy.size.width
            // NOTE: this VStack lays out INSIDE the safe area (no ignoresSafeArea on the root), so
            // the padding must NOT add safeArea.top again — in portrait the ~60pt island inset
            // double-counted into a dead band above the title (landscape's top inset is ~0).
            let topPadding =
                isPortraitViewport
                ? 16
                : StartupLayoutMargins.headerTopMargin(
                    for: proxy.monitorEdgeInsets,
                    viewportHeight: viewportHeight,
                    compact: compact || wizardFillsViewport
                )
            // Cards sit closer to the pushed-down header, preserving the non-scrolling wizard's
            // total vertical budget.
            let wizardHeaderGap = min(16, max(8, viewportHeight * 0.028))
            let bottomPadding =
                wizardFillsViewport
                ? proxy.monitorEdgeInsets.bottom
                    + (isPortraitViewport ? 12 : min(28, max(14, viewportHeight * 0.045)))
                : contentMargins.bottom

            VStack(alignment: .leading, spacing: 0) {
                StartupHeader(title: headerTitle, statusTitle: statusTitle, isBusy: isBusy)
                    .padding(.leading, CGFloat(headerMargins.leading))
                    // Only the wizard reclaims the trailing inset, so only there does the header
                    // extend to match (status pill lines up with the content).
                    .padding(.trailing, wizardFillsViewport ? 24 : CGFloat(headerMargins.trailing))
                    .ignoresSafeArea(.container, edges: wizardFillsViewport ? .trailing : [])

                if wizardFillsViewport {
                    StartupFirstPairWizardView(
                        compact: compact,
                        isBusy: isBusy,
                        contentLayout: contentLayout
                    )
                    .environment(model)
                    .padding(.leading, CGFloat(headerMargins.leading))
                    // Trailing is the rounded-corner side (island is on leading) — reclaim its
                    // safe-area inset; the 24pt margin keeps card text ~40pt off the screen edge,
                    // clear of the island pill even rotated the other way.
                    .padding(.trailing, 24)
                    .padding(.top, CGFloat(wizardHeaderGap))  // cards don't crowd the header row
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .ignoresSafeArea(.container, edges: .trailing)
                } else {
                    Group {
                        if model.isConnected {
                            // Live view starts automatically; minimal inline preparing state (live
                            // view failures surface inline here too).
                            StartupPreparingLiveView(compact: compact)
                                .environment(model)
                        } else {
                            // Not wizard and not connected ⇒ saved cameras exist (the wizard owns
                            // the empty/pairing states and is the only pairing surface).
                            StartupSavedCamerasView(compact: compact, contentLayout: contentLayout)
                                .environment(model)
                        }
                    }
                    .padding(.leading, CGFloat(contentMargins.leading))
                    .padding(.trailing, CGFloat(contentMargins.trailing))
                    .padding(.top, compact ? 14 : 20)
                    // Fill the space below the header instead of centering between spacers, so the
                    // landscape two-column layout uses the full height (no empty band at the bottom).
                    .frame(
                        maxWidth: .infinity,
                        maxHeight: .infinity,
                        alignment: contentHorizontalAlignment == .center ? .top : .topLeading
                    )
                }
            }
            .padding(.top, CGFloat(topPadding))
            .padding(.bottom, CGFloat(bottomPadding))
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
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
        .fullScreenCover(isPresented: connectionProgressSheetPresented) {
            ConnectionProgressSheet()
                .environment(model)
        }
        // Owned at the root so the credential scanner can present directly from the join/scan action
        // (no intermediate confirmation popup) and also over the connection progress sheet.
        .fullScreenCover(isPresented: Bindable(model).isCameraWiFiScannerPresented) {
            CameraWiFiScannerScreen(
                onCapture: { model.applyScannedCameraWiFi(ssid: $0.ssid, key: $0.key) },
                onCancel: { model.isCameraWiFiScannerPresented = false }
            )
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

    private var statusTitle: String {
        StartupConnectionCopy.friendlyStatusTitle(
            for: model.connection,
            isDiscovering: model.connection == .scanning
                || (model.startupMode == .discovery && !model.isConnected)
        )
    }

    private var isBusy: Bool {
        model.isStartupActionLocked
    }

    /// Contextual header title next to the OpenZCine logo.
    private var headerTitle: String {
        if model.shouldShowFirstPairWizard { return "Connection setup" }
        if model.isConnected { return "Connecting" }
        if model.startupMode == .savedCameras, !model.savedCameras.isEmpty { return "Your cameras" }
        return "Find your camera"
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

    private var connectionProgressSheetPresented: Binding<Bool> {
        Binding(
            get: { model.isConnectionProgressPresented },
            set: { isPresented in
                if !isPresented, model.isConnectionProgressPresented {
                    model.dismissConnectionProgress()
                }
            }
        )
    }

}

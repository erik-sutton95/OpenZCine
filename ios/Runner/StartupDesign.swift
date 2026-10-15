import AVFoundation
import MonitorPresentation
import MonitorUI
import OpenCineAppKit
import OpenCineApple
import OpenZCineCore
import SwiftUI

/// Maps technical connection/discovery status strings to operator-friendly copy for startup screens.
enum StartupConnectionCopy {
    /// - Parameter path: how the attempt reaches the camera, where it is known. These lines are
    ///   matched on the TEXT of a status, which carries no idea of which path produced it — so a
    ///   cable failure was being answered with "check Wi‑Fi", sending the operator to inspect a
    ///   radio this attempt never used. `nil` keeps the Wi‑Fi wording, right for every path with a
    ///   network.
    static func friendly(_ raw: String, path: CameraPath.Kind? = nil) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        let checkTheLink =
            path == .usbC || path == .hdmiCapture ? "Check the cable" : "Check Wi‑Fi"

        let lower = trimmed.lowercased()
        if lower.contains("imagecapturecore") {
            // Raw ICC error (e.g. -21400 on a stale USB session): the app retries with a session
            // recycle automatically, so reaching the operator means even that failed.
            return "The USB link got stuck. Unplug the cable, plug it back in, and try again."
        }
        if lower.contains("ptp-ip") || lower.contains("ptp ip") {
            if lower.contains("no") && (lower.contains("service") || lower.contains("answered")) {
                return "Couldn't reach the camera. \(checkTheLink) and try again."
            }
            if lower.contains("handshake") || lower.contains("rejected") {
                return "The camera didn't accept the connection. Check Connect to PC and try again."
            }
            if lower.contains("desync") || lower.contains("invalid") {
                return "Lost contact with the camera. Try connecting again."
            }
        }
        if lower.contains("bonjour") || lower.contains("_ptp._tcp")
            || lower.contains("subnet probe")
        {
            return "Searching nearby networks for your camera…"
        }
        if lower.contains("scanning bonjour") {
            return "Searching for cameras on your Wi‑Fi…"
        }
        if lower.contains("probing local subnets")
            || lower.contains("checking ") && lower.contains("ptp-ip port")
        {
            return "Still searching your network for cameras…"
        }
        if lower.contains("personal hotspot bridge") {
            return "iPhone hotspot is active. Waiting for your camera to appear…"
        }
        if lower.contains("enter the camera ip") || lower.contains("nikon zr wi-fi") {
            return "Enter the camera's IP address, or join its Wi‑Fi network first."
        }
        if lower.contains("local network") && lower.contains("blocked") {
            return
                "OpenZCine needs local network access. Allow it in Settings → OpenZCine → Local Network."
        }
        if lower.contains("timed out") {
            return "The camera didn't respond in time. \(checkTheLink) and try again."
        }
        if lower.contains("closed the connection") {
            return "The camera ended the connection. Try again."
        }
        if trimmed.contains("‹") {
            return trimmed.components(separatedBy: "‹").first?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? trimmed
        }
        return trimmed
    }

}

/// Minimal inline state shown while the post-connect property burst and first
/// live-view frame run after a successful connection (Android "Reading camera
/// settings…" parity). Replaces the former full-screen "Camera ready" landing.
struct StartupPreparingLiveView: View {
    @Environment(NativeAppModel.self) private var model
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                ProgressView()
                    .controlSize(.regular)
                    .tint(MonitorTheme.accent)
                StartupIconSquare(systemName: "camera.aperture", size: 48)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text(
                    model.userFacingConnectionMessage.isEmpty
                        ? "Reading camera settings…"
                        : model.userFacingConnectionMessage
                )
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(MonitorTheme.text)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            }

            // Always offer a way back: this screen also shows when live view fails to start, and
            // hiding the button there (a session still exists) left the operator stuck.
            Button {
                model.disconnect()
            } label: {
                Label("Back to cameras", systemImage: "chevron.backward")
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                    .frame(maxWidth: 230)
            }
            .buttonStyle(StartupOutlineButtonStyle())
        }
        .frame(maxWidth: compact ? .infinity : 400, alignment: .leading)
    }
}

/// "+ Add setup" on a saved camera: a mini-wizard scoped to THIS camera, offering only the
/// path kinds it doesn't have yet. Nothing here re-runs first pair — records write themselves
/// at the next connect, stamped with the declared path; this sheet only prepares the way
/// (joins the camera's Wi-Fi for AP, instructs for the rest).
struct StartupAddSetupSheet: View {
    @Environment(NativeAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let camera: PTPIPSavedCameraRecord
    let missingKinds: [CameraPath.Kind]
    /// The shared flow's add-route (SHELL-02): a reachable path connects now, an unreachable one
    /// is watched for, and either way the camera's card shows the attempt.
    let addRoute: (CameraPath.Kind) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add a setup · \(camera.displayTitle)")
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(MonitorTheme.text)
            Text(
                "One camera, several ways to reach it. Pick how this rig runs; the setup "
                    + "saves itself the first time you connect that way."
            )
            .font(.system(size: 13, weight: .regular, design: .rounded))
            .foregroundStyle(MonitorTheme.muted)
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(missingKinds, id: \.self) { kind in
                        setupRow(kind)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(MonitorTheme.background)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder private func setupRow(_ kind: CameraPath.Kind) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon(for: kind))
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(MonitorTheme.accent)
                .frame(width: 30, height: 30)
                .background(MonitorTheme.raised.opacity(0.5), in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(title(for: kind))
                    .font(.system(size: 14.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(MonitorTheme.text)
                Text(guidance(for: kind))
                    .font(.system(size: 12.5, weight: .regular, design: .rounded))
                    .foregroundStyle(MonitorTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                // Every row DOES something — a "+ Add setup" that only explains is a dead
                // end. Try-now-else-watch: connect immediately when the path is already
                // reachable, otherwise dismiss into the list, which is watching for it.
                setupActionButton(kind)
                    .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(MonitorTheme.raised.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
    }

    /// The discovered camera that would satisfy this kind RIGHT NOW, if any.
    private func discoveredMatch(for kind: CameraPath.Kind) -> DiscoveredCamera? {
        switch kind {
        case .usbC:
            return model.discoveredCameras.first { $0.source == .usb }
        case .infrastructure:
            // On the camera's own AP this body is discovered — over a network the Wi-Fi
            // setup can't use. Same rule as the availability chips: no route, no match.
            guard !model.isOnCameraAccessPointNetwork else { return nil }
            let accessPointHosts = model.savedCameraAccessPointHosts
            return model.discoveredCameras.first { discovered in
                // A camera-AP record's host is an address on the CAMERA's own network —
                // 192.168.1.1 by convention, which is also the commonest home-router address
                // there is. Something answering there is either the camera on its access
                // point (a different setup) or the operator's router, and the liveness dial
                // this row can come from — a kernel RST — cannot tell those apart. Either
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

    @ViewBuilder private func setupActionButton(_ kind: CameraPath.Kind) -> some View {
        let match = discoveredMatch(for: kind)
        let title: String? = {
            switch kind {
            case .cameraAccessPoint: return "Join Camera Wi-Fi"
            case .usbC: return match != nil ? "Connect Now" : "Connect When Plugged In"
            case .infrastructure:
                return match != nil ? "Connect Now" : "Find On This Network"
            case .phoneHotspot: return "Wait For Camera"
            case .hdmiCapture: return "Use HDMI Capture"
            }
        }()
        if let title {
            Button {
                // Anything that PRESENTS (the join cover, the connect popup) runs from the
                // sheet's onDismiss — fired mid-dismissal it is silently dropped, which is
                // exactly how "Join Camera Wi-Fi" did nothing. Pure state writes run now.
                switch kind {
                case .cameraAccessPoint:
                    model.pendingAddSetupAction = { [weak model] in
                        model?.beginAddCameraAPSetup(for: camera)
                    }
                case .usbC, .infrastructure, .phoneHotspot:
                    // Connecting over this path IS adding the setup: the record saves itself
                    // with the declared path at establishment. Not reachable yet, the attempt
                    // watches for it (the first discovery on this path connects).
                    addRoute(kind)
                case .hdmiCapture:
                    // Picture-only and no PTP control, so there is nothing to watch FOR — the
                    // dongle either has a signal or it doesn't. Start the capture session
                    // straight away; it adopts a live camera link as a source change rather
                    // than tearing it down (`startHDMIMonitorSession`).
                    model.pendingAddSetupAction = { [weak model] in
                        model?.startHDMIMonitorSession()
                    }
                }
                dismiss()
            } label: {
                Text(title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(MonitorTheme.text)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(MonitorTheme.accent.opacity(0.35), in: Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    private func icon(for kind: CameraPath.Kind) -> String {
        switch kind {
        case .cameraAccessPoint: return "personalhotspot"
        case .infrastructure: return "wifi.router"
        case .phoneHotspot: return "iphone.radiowaves.left.and.right"
        case .usbC: return "cable.connector"
        case .hdmiCapture: return "tv"
        }
    }

    private func title(for kind: CameraPath.Kind) -> String {
        switch kind {
        case .cameraAccessPoint: return "Camera access point"
        case .infrastructure: return "Wi-Fi network"
        case .phoneHotspot: return "This device's hotspot"
        case .usbC: return "USB-C cable"
        case .hdmiCapture: return "HDMI capture"
        }
    }

    private func guidance(for kind: CameraPath.Kind) -> String {
        switch kind {
        case .cameraAccessPoint:
            return
                "This device joins the camera's own Wi-Fi — best in the field with no other "
                + "gear. You'll be asked for the camera's network key the first time only."
        case .infrastructure:
            return
                "Put the camera and this device on the same network (a set router, house "
                + "Wi-Fi). Turn on Connect to PC on the camera with a profile for that "
                + "network; it appears in the camera list and saves on connect. Each network "
                + "you use keeps its own setup, so a studio and a home router are two."
        case .phoneHotspot:
            return
                "Turn on this device's Personal Hotspot and point a camera network profile "
                + "at it. The camera joins YOU — once it does, it appears in the list."
        case .usbC:
            return
                "Plug the camera straight into this device. It connects and saves itself — "
                + "nothing to configure."
        case .hdmiCapture:
            return "Use the connect screen's Cable Link → HDMI capture for a picture-only feed."
        }
    }
}

/// Typography for the wizard rows Nikon still draws (the permission rows), per startup profile.
struct WizardCompactStyle: Sendable {
    let checklistFontSize: CGFloat
    let checklistDetailFontSize: CGFloat
    let isTight: Bool

    static func make(profile: StartupLayoutProfile) -> WizardCompactStyle {
        switch profile {
        case .compactPortrait:
            WizardCompactStyle(
                checklistFontSize: 11, checklistDetailFontSize: 10, isTight: true)
        case .compactLandscape:
            WizardCompactStyle(
                checklistFontSize: 13, checklistDetailFontSize: 12, isTight: true)
        case .regularLandscape:
            WizardCompactStyle(
                checklistFontSize: 14, checklistDetailFontSize: 13, isTight: true)
        case .wideLandscape:
            WizardCompactStyle(
                checklistFontSize: 15, checklistDetailFontSize: 14, isTight: false)
        }
    }
}

enum StartupWizardContent {
    /// High-level "get the camera ready" instructions per transport, shown as numbered cards on the
    /// prepare step. Camera Access Point is the scan path; the others hand off to the network step.
    // [VERIFY-ON-HW] Confirm the ZR's exact menu wording for each path on hardware.
    static func preparationSteps(
        for transport: NativeAppModel.FirstPairTransportMethod
    ) -> [String] {
        switch transport {
        case .cameraAccessPoint:
            return [
                "On the camera: Network menu → Connect to computer → Network settings.",
                "Choose Create Profile and give the profile a name.",
                "Select Direct connection to computer — the camera shows its SSID and key.",
            ]
        case .phoneHotspot:
            return [
                "Turn on Personal Hotspot on your iPhone (Settings → Personal Hotspot).",
                "On the same screen, turn off Maximize Compatibility — it slows live view.",
                "On the camera: Network menu → Connect to computer.",
                "We'll walk through joining your hotspot in the next step.",
            ]
        case .usbC:
            return [
                "In the camera's setup menu, set USB to MTP/PTP.",
                "Connect the USB‑C cable between the camera and this device.",
                "Leave the camera switched on — no network profile is needed.",
            ]
        case .wiFiNetwork:
            return [
                "Join this device to the set's network in iOS Settings, if it isn't already.",
                "On the camera: Network menu → Connect to computer → Network settings.",
                "Create Profile → Search for Wi‑Fi network → join that same network.",
            ]
        case .hdmiCapture:
            return [
                "Connect the capture device to this iPad, and the camera's HDMI output to it.",
                "Set the camera's HDMI output to 1080p and turn its display info off — 4K is often more than a capture device can lock onto, and anything the camera draws becomes part of the signal.",
                "Nothing is sent to the camera on this path: it's a picture, not a connection.",
            ]
        }
    }

    static func networkSections(
        for transport: NativeAppModel.FirstPairTransportMethod,
        tight: Bool
    ) -> [CameraPairingInstruction] {
        switch transport {
        case .cameraAccessPoint:
            return [
                CameraPairingInstruction(
                    title: "On camera", icon: .camera,
                    lines: tight
                        ? ["Keep the SSID & key screen visible"]
                        : [
                            "Leave the camera on its Direct connection screen",
                            "It shows the network SSID and key",
                        ]
                ),
                CameraPairingInstruction(
                    title: "On iPhone", icon: .phone,
                    lines: tight
                        ? ["Tap Connect my camera, then scan the SSID & key to join"]
                        : [
                            "Tap Connect my camera below",
                            "Scan the camera's SSID & key screen — we join for you, no typing",
                        ]
                ),
            ]
        case .phoneHotspot:
            // Single full-width card keeps the ZR menu path one line per step (side-by-side
            // halves overflowed). The iPhone hotspot step lives in the subtitle.
            return [
                CameraPairingInstruction(
                    title: "On camera", icon: .camera,
                    lines: [
                        "Connect to computer → Network settings",
                        "Create Profile → name your profile",
                        "Search for Wi‑Fi network → Join your iPhone hotspot",
                        "IP address → Obtain automatically",
                    ]
                )
            ]
        case .usbC:
            return [
                CameraPairingInstruction(
                    title: "On camera", icon: .camera,
                    lines: tight
                        ? [
                            "Plug the camera into this device with USB-C",
                            "Confirm any connection prompt on the camera",
                        ]
                        : [
                            "Plug the camera into this device with a USB-C cable",
                            "If the camera shows a connection prompt, confirm it",
                        ]
                ),
                CameraPairingInstruction(
                    title: "On iPhone", icon: .phone,
                    lines: tight
                        ? ["Tap Allow when iOS asks for camera access"]
                        : [
                            "iOS asks to allow OpenZCine to access the camera the first time — tap Allow",
                            "Return here once the cable is connected",
                        ]
                ),
            ]
        case .wiFiNetwork:
            // The app joins nothing here — both devices are already on someone else's network —
            // so this step is a check, not an action.
            return [
                CameraPairingInstruction(
                    title: "On camera", icon: .camera,
                    lines: [
                        "Confirm the camera joined the network",
                        "IP address → Obtain automatically",
                    ]
                ),
                CameraPairingInstruction(
                    title: "On iPhone", icon: .phone,
                    lines: tight
                        ? ["Be on the same network, then find your camera"]
                        : [
                            "Check this device is on that same network",
                            "Then tap Continue to find the camera",
                        ]
                ),
            ]
        case .hdmiCapture:
            // Unreachable: `FirstPairWizardStep.sequence` omits the network step for HDMI, which
            // reaches the camera through a cable and has no network to set up.
            return []
        }
    }

    static func networkSubtitle(
        for transport: NativeAppModel.FirstPairTransportMethod,
        tight: Bool
    ) -> String {
        switch transport {
        case .cameraAccessPoint:
            return tight
                ? "Point your phone at the camera's SSID & key screen to join it — no typing."
                : "The camera now shows its Wi‑Fi SSID and key. Scan that screen with your phone and OpenZCine joins the camera's network for you — no typing."
        case .phoneHotspot:
            return
                "On iPhone: Settings → Personal Hotspot → turn on Allow Others to Join. Then on the camera:"
        case .usbC:
            return tight
                ? "Plug in the cable, allow camera access, then find your camera."
                : "Connect the cable, confirm the camera's prompt, and allow camera access on this device when asked."
        case .wiFiNetwork:
            return tight
                ? "Put both on the same network, then find the camera."
                : "Nothing to join from here — get the camera onto the same network this device is on, and it will appear in the next step."
        case .hdmiCapture:
            return ""  // Unreachable — HDMI has no network step.
        }
    }

    /// Nearby cameras as rows for the discovery step; the selected camera is the primary row.
    static func discoveryDevices(_ cameras: [DiscoveredCamera], selectedID: String?)
        -> [CameraListItem]
    {
        cameras.map { camera in
            CameraListItem(
                id: camera.id, name: camera.displayName,
                // The holder replaces "nearby" rather than joining it: on this row the question
                // is not where the camera is, it is who has it.
                subtitle: camera.heldByLabel ?? "\(camera.source.pairingLabel) · nearby",
                status: "", actionTitle: "", isPrimary: camera.id == selectedID)
        }
    }

    /// What the discovery step is waiting for while it has found nothing, in the terms of the path
    /// the operator picked (`transport` only knows Wi-Fi versus USB, and three different Wi-Fi
    /// paths reach this step expecting three different things to happen next).
    static func discoveryWaiting(
        transport: NativeAppModel.DiscoveryTransportFilter,
        pairingMethod: NativeAppModel.FirstPairTransportMethod,
        usbAuthorizationDenied: Bool
    ) -> (title: String, hint: String) {
        if transport == .usbC {
            // iOS denied USB camera control: nothing can ever appear until it's re-allowed, so the
            // Settings recovery leads instead of cable guidance.
            if usbAuthorizationDenied {
                return (
                    "USB camera access is off",
                    "Allow camera connections for OpenZCine in Settings ▸ Privacy & Security, then plug the camera back in."
                )
            }
            // A USB-C-to-Lightning cable wires this phone as the device end; the camera can only
            // enumerate through Apple's host-mode adapter.
            if DeviceUSBConnector.current == .lightning {
                return (
                    "Lightning needs the camera adapter",
                    "Connect the camera through Apple's Lightning to USB camera adapter — a plain USB-C to Lightning cable can't host it."
                )
            }
            return (
                "Waiting for camera on USB-C",
                "Plug the camera into this device with a USB-C cable."
            )
        }
        switch pairingMethod {
        case .wiFiNetwork:
            // Nothing to join from here: both ends are already somebody else's guests, so the one
            // thing worth showing is WHICH network this device is searching. The SSID would read
            // better; iOS refuses it often enough that the subnet, which always answers, is the
            // honest choice.
            guard let network = NativeNetworkInterfaceSnapshot.currentScanSubnetLabel() else {
                return (
                    "Looking on your network", "The camera appears once it's on this same network."
                )
            }
            return (
                "Looking on your network", "Searching \(network) — the camera has to be on it too."
            )
        case .phoneHotspot:
            // The direction matters: the CAMERA joins this phone, the phone joins nothing.
            return (
                "Waiting for the camera", "Waiting for the camera to join this phone's hotspot."
            )
        case .cameraAccessPoint:
            // Reachable when a saved AP setup sends the operator back through discovery.
            return ("Looking for cameras", "Waiting for the camera's own network.")
        default:
            return ("Looking for cameras", "Waiting for the camera to appear.")
        }
    }
}

struct StartupFirstPairWizardView: View {
    @Environment(NativeAppModel.self) private var model
    let isBusy: Bool
    let contentLayout: StartupContentLayout
    var safeArea = EdgeInsets()
    @State private var permissions = StartupPermissionsCoordinator()
    /// The attached capture device (HDMI path). The dongle is very often plugged in *after* landing
    /// on the step, so the readout follows the hardware rather than the step's first look.
    @State private var captureDeviceName: String? = UVCVideoSource.attachedDeviceName

    private var style: WizardCompactStyle {
        WizardCompactStyle.make(profile: contentLayout.profile)
    }
    private var step: NativeAppModel.FirstPairWizardStep { model.firstPairWizardStep }
    private var transport: NativeAppModel.FirstPairTransportMethod {
        model.firstPairTransportMethod
    }

    /// The wizard on the shared pair page (SHELL-02): its steps in the rail, each step's copy,
    /// instructions, cameras and checks as page values; only the permission rows and the transport
    /// cards are drawn here. A connect it starts shows its progress in the same page.
    var body: some View {
        PairScreen(
            model: model.cameras, safeArea: safeArea,
            onDone: { model.showSavedCameras() },
            onDiagnostics: { model.shareDiagnostics() },
            onReportProblem: { model.isBugReportPresented = true },
            onWatchFeed: { model.showSavedCameras() },
            pairingFlow: model.showsAppConnectProgress
                ? NikonConnectFlow(model: model).flow(
                    steps: railSteps, current: railSteps.count - 1)
                : IntegrationPairingFlow(
                    presentation: presentation,
                    onSelect: { id in
                        if let camera = model.pairingDiscoveryCandidates.first(where: {
                            $0.id == id
                        }) {
                            model.selectDiscoveredCamera(camera)
                        }
                    },
                    onPrimary: primary,
                    onBack: {
                        if model.firstPairWizardCanRetreat(from: step) {
                            model.retreatFirstPairWizard()
                        } else {
                            model.showSavedCameras()
                        }
                    },
                    content: AnyView(stepBody))
        )
        .onReceive(
            NotificationCenter.default.publisher(for: AVCaptureDevice.wasConnectedNotification)
        ) { _ in captureDeviceName = UVCVideoSource.attachedDeviceName }
        .onReceive(
            NotificationCenter.default.publisher(for: AVCaptureDevice.wasDisconnectedNotification)
        ) { _ in captureDeviceName = UVCVideoSource.attachedDeviceName }
        .onChange(of: step) { _, _ in captureDeviceName = UVCVideoSource.attachedDeviceName }
    }

    private var railSteps: [CameraPairingStep] {
        NativeAppModel.FirstPairWizardStep.sequence(
            transport: model.firstPairTransportMethod,
            skipsPermissions: model.firstPairWizardSkipsPermissions
        ).map { CameraPairingStep($0.title, "") }
    }

    private var presentation: CameraPairingPresentation {
        let steps = NativeAppModel.FirstPairWizardStep.sequence(
            transport: transport,
            skipsPermissions: model.firstPairWizardSkipsPermissions)
        // Transport is chosen by tapping a card; discovery advances by connecting to a found
        // camera; camera access point ends at the network step, whose button opens the scanner.
        let primary =
            step != .chooseTransport
            && (!step.isFinalStep(for: transport)
                || (step == .connectNetwork && transport == .cameraAccessPoint))
        var page = CameraPairingPresentation(
            steps: steps.map { CameraPairingStep($0.title, "") },
            currentStep: steps.firstIndex(of: step) ?? 0,
            title: stepTitle, body: "", target: "Nikon Z", hint: "",
            primaryAction: primary
                ? (step == .connectNetwork ? "Connect my camera" : "Continue") : nil,
            // The operator can't leave the permissions step until the required permissions are
            // granted: the camera can't be reached without them.
            primaryActionEnabled: !isBusy
                && (step != .permissions || permissions.allRequiredGranted),
            backAction: model.firstPairWizardCanRetreat(from: step) ? "Back" : "Your cameras")
        switch step {
        case .permissions, .chooseTransport:
            break
        case .prepareCamera:
            page.instructions = [
                CameraPairingInstruction(
                    title: "Before you connect", icon: .camera,
                    lines: StartupWizardContent.preparationSteps(for: transport))
            ]
        case .connectNetwork:
            page.body = StartupWizardContent.networkSubtitle(for: transport, tight: style.isTight)
            page.instructions = StartupWizardContent.networkSections(
                for: transport, tight: style.isTight)
        case .discoverAndPair where transport == .hdmiCapture:
            captureDeviceStep(&page)
        case .discoverAndPair:
            discoveryStep(&page)
        }
        return page
    }

    /// HDMI has no camera to find: the capture device is either attached or it isn't, and the
    /// answer comes from AVFoundation immediately rather than from a scan. So the step reports
    /// that and starts the monitor instead of listing cameras.
    private func captureDeviceStep(_ page: inout CameraPairingPresentation) {
        let supported = UVCVideoSource.isSupportedHardware
        let ready = supported && captureDeviceName != nil
        page.body =
            "The camera isn't contacted on this path — nothing is sent to it, so exposure, focus and record stay on the body. Connect over Wi‑Fi as well if you want to control it from here."
        page.checks = [
            CameraPairingCheck(
                title: ready
                    ? "Capture device ready"
                    : supported ? "Waiting for the capture device" : "Needs an iPad",
                subtitle: captureDeviceDetail(supported: supported),
                state: ready ? .complete : supported ? .active : .waiting,
                stateLabel: ready ? "READY" : supported ? "WAITING" : "IPAD ONLY")
        ]
        page.primaryAction = "Start monitoring"
        page.primaryActionEnabled = supported
    }

    private func captureDeviceDetail(supported: Bool) -> String {
        guard supported else {
            return
                "iOS doesn't expose USB capture devices to apps — this path works on iPad. Use USB‑C or Wi‑Fi on this device."
        }
        if let captureDeviceName {
            return "\(captureDeviceName) — connect the camera's HDMI output to it and start."
        }
        #if DEBUG
            // The Debug-only phone experiment: without this, a phone that enumerates nothing looks
            // identical to an iPad with the cable unplugged, and the result would be unreadable.
            if !UVCVideoSource.isDocumentedHardware {
                return
                    "Debug build: this device isn't documented to expose USB capture devices, so it will most likely find nothing. Plug one in and see."
            }
        #endif
        return "Connect the capture device to this iPad, then the camera's HDMI output into it."
    }

    /// Nearby cameras for Phone Hotspot, USB-C and the set's network: tap one to select it, then
    /// pair or connect. While nothing is found the page says what the search is waiting for, in the
    /// terms of the path the operator picked.
    private func discoveryStep(_ page: inout CameraPairingPresentation) {
        let candidates = model.pairingDiscoveryCandidates
        let selected = model.selectedPairingDiscoveryCamera
        page.devices = StartupWizardContent.discoveryDevices(candidates, selectedID: selected?.id)
        if candidates.isEmpty {
            let denied = model.isUSBControlAuthorizationDenied
            let waiting = StartupWizardContent.discoveryWaiting(
                transport: model.discoveryTransportFilter, pairingMethod: transport,
                usbAuthorizationDenied: denied)
            page.emptyTitle = waiting.title
            // A diagnosis the moment the search has one. "The camera appears once it's on this
            // network" is honest only while nothing is known; once a sweep has proved the subnet
            // silent, or busy with nothing serving PTP, the waiting line withholds the one thing
            // the operator could act on.
            page.body = model.infrastructureMissCopy ?? waiting.hint
            // Nothing can appear until USB access is allowed again, so nothing is "searching".
            page.progress = denied && model.discoveryTransportFilter == .usbC ? nil : "Searching"
        }
        let action = StartupDiscoveryPrimaryAction.resolve(
            hasSelectedCamera: selected != nil, isBusy: isBusy,
            isKnownCamera: model.selectedPairingCameraIsKnown)
        if let title = action.title {
            page.primaryAction = title
            page.primaryActionEnabled = action.isEnabled
        } else if candidates.isEmpty, model.showsJoinCameraWiFiAction {
            page.primaryAction = model.joinCameraWiFiButtonTitle
            page.primaryActionEnabled = !isBusy
        }
    }

    private func primary() {
        switch step {
        case .discoverAndPair where transport == .hdmiCapture:
            model.startHDMIMonitorSession()
        case .discoverAndPair where model.selectedPairingDiscoveryCamera != nil:
            model.connectSelectedCamera()
        case .discoverAndPair:
            model.joinCameraWiFiFromDiscovery()
        default:
            model.advanceFirstPairWizard()
        }
    }

    private var stepTitle: String {
        switch (step, model.firstPairTransportMethod) {
        case (.prepareCamera, .hdmiCapture):
            // The camera is half of it; the capture device is the half that has to be right.
            return "Prepare the camera and capture device"
        case (.connectNetwork, .usbC):
            return "Connect the cable"
        case (.connectNetwork, .cameraAccessPoint):
            return "Join the camera's Wi-Fi"
        case (.connectNetwork, .phoneHotspot):
            return "Turn on your hotspot"
        case (.connectNetwork, .wiFiNetwork):
            // A CHECK, not a setup: the app joins nothing here and neither does the operator.
            return "Get both on one network"
        case (.discoverAndPair, .hdmiCapture):
            return "Connect the capture device"
        case (.discoverAndPair, .phoneHotspot):
            // The direction is the whole point of this path: the camera joins the phone.
            return "Wait for the camera"
        default:
            return step.title
        }
    }

    /// The permission rows and the transport cards act on their own taps, so they stay views; every
    /// other step is page values.
    @ViewBuilder
    private var stepBody: some View {
        switch step {
        case .permissions:
            StartupWizardPermissionsStep(coordinator: permissions, style: style)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        case .chooseTransport:
            transportCards
        case .prepareCamera, .connectNetwork, .discoverAndPair:
            EmptyView()
        }
    }

    /// Three side-by-side columns in landscape; stacked full-width cards in portrait, where the
    /// columns are too narrow (truncated titles) — gated on the style's transport-split flag.
    @ViewBuilder
    private var transportCards: some View {
        // `cardCases`, not `allCases`: HDMI capture is a nested option inside the Cable Link card
        // rather than a fourth column — see `FirstPairTransportMethod.cardCases`.
        let cards = ForEach(NativeAppModel.FirstPairCard.allCases) { card in
            StartupWizardTransportCard(card: card) { chosen in
                model.firstPairTransportMethod = chosen
                AppDiagnostics.shared.record(chosen.diagnosticEvent)
                model.advanceFirstPairWizard()
            }
            .frame(maxWidth: .infinity)
        }
        VStack(spacing: 12) {
            cards
            wizardCameraListLink
        }
    }

    /// The way out of the wizard for a device that will not pair a camera.
    ///
    /// A watcher-only device never pairs, so the wizard is the only screen it would ever see —
    /// this row hands it the camera-list home, where nearby broadcasts are listed and joined.
    /// The list screen owns that choice; the wizard only points at it.
    private var wizardCameraListLink: some View {
        Button {
            model.showSavedCameras()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(MonitorTheme.accent)
                Text("Watching another device?")
                    .font(.system(size: 13, weight: .regular, design: .rounded))
                    .foregroundStyle(MonitorTheme.muted)
                Text("Open the camera list")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(MonitorTheme.accent)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(MonitorTheme.muted)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                MonitorTheme.raised.opacity(0.4),
                in: RoundedRectangle(cornerRadius: 12)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.white.opacity(0.1), lineWidth: 1))
        }
        .buttonStyle(.monitorTapTarget)
    }

}

extension DiscoverySource {
    /// Where a found camera was seen, for its row on the discovery step.
    fileprivate var pairingLabel: String {
        switch self {
        case .bonjour, .subnetProbe, .liveness: "Wi-Fi"
        case .manual: "Manual"
        case .usb: "USB-C"
        // The holder's name is what this row is for, and it replaces the transport label: the
        // camera is on Wi-Fi either way, and that is not the fact standing between the operator
        // and a picture.
        case .heldByAnotherDevice: "In use"
        }
    }
}

/// One transport option in the first-run picker: name, stream-mode badge, tradeoff tagline, and a
/// battery / stream / wireless readout. Neutral — no option is crowned as the recommended one.
struct StartupWizardTransportCard: View {
    let card: NativeAppModel.FirstPairCard
    /// The chosen path — this card's own, or one of its nested options.
    let onSelect: (NativeAppModel.FirstPairTransportMethod) -> Void

    /// Whether the nested choice is open. Cards without nested options never set it.
    /// The debug seed exists because expansion is a tap — unreachable headless — and the
    /// expanded step's overflow behavior is exactly what screenshots must check.
    @State private var showsOptions: Bool = DemoHarness.wizardExpanded

    private var options: [NativeAppModel.FirstPairTransportMethod] { card.options }

    var body: some View {
        // The whole surface toggles the options; the option pills stay Buttons and win their own
        // hits. This is deliberately a tap gesture rather than a Button: a Button may not contain
        // Buttons (the pills would render and never fire), and the earlier header-only Button left
        // everything below it dead — on an iPad the cards are tall, so most of the card did not
        // respond at all.
        cardSurface {
            header
            if showsOptions {
                optionPills.padding(.top, 10)
            } else {
                tradeoffs.padding(.top, 10)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.spring(duration: 0.26)) { showsOptions.toggle() }
        }
    }

    /// The card's tile: padding, fill and border, with an accent edge while its options are open.
    private func cardSurface<Content: View>(
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(MonitorTheme.raised.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(
                    showsOptions
                        ? MonitorTheme.accent.opacity(0.45) : Color.white.opacity(0.1),
                    lineWidth: 1)
        )
    }

    /// Glyph, title and one-word headline — the part that is always tappable.
    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(systemName: iconName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(MonitorTheme.accent)
                .frame(width: 34, height: 34)
                .background(
                    MonitorTheme.accent.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 9)
                )
                .padding(.bottom, 10)
            Text(card.title)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(MonitorTheme.text)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(headline)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(MonitorTheme.accent)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(MonitorTheme.accent.opacity(0.15), in: Capsule())
                .fixedSize()
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var tradeoffs: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(pros, id: \.self) { pro in
                tradeoffRow(symbol: "plus", color: MonitorTheme.linkHealthColor(.stable), text: pro)
            }
            tradeoffRow(symbol: "minus", color: MonitorTheme.faint, text: con)
        }
    }

    /// The nested choice: which end of the cable is doing the work.
    @ViewBuilder private var optionPills: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(options) { option in
                Button {
                    onSelect(option)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: option.systemImage)
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 14)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(option.optionTitle)
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                .foregroundStyle(MonitorTheme.text)
                            Text(optionCaption(option))
                                .font(.system(size: 10, weight: .regular, design: .rounded))
                                .foregroundStyle(MonitorTheme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                                .multilineTextAlignment(.leading)
                        }
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(MonitorTheme.accent)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        MonitorTheme.accent.opacity(0.1),
                        in: RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.monitorTapTarget)
            }
        }
    }

    private func optionCaption(_ option: NativeAppModel.FirstPairTransportMethod) -> String {
        switch option {
        case .cameraAccessPoint: "Simplest, nothing to set up"
        case .phoneHotspot: "Best wireless quality"
        case .wiFiNetwork: "A set router or house Wi‑Fi"
        case .usbC: "Full camera control"
        case .hdmiCapture:
            UVCVideoSource.isDocumentedHardware
                ? "Picture only, full quality"
                : (UVCVideoSource.isSupportedHardware
                    ? "Picture only — unsupported here" : "Needs an iPad")
        }
    }

    /// A single pro (+) or con (−) line.
    private func tradeoffRow(symbol: String, color: Color, text: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(color)
                .frame(width: 12)
                .padding(.top, 3)
            Text(text)
                .font(.system(size: 12, weight: .regular, design: .rounded))
                .foregroundStyle(MonitorTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Transport glyph: the camera broadcasting its own network, the phone radiating its hotspot
    /// (the literal `personalhotspot` chain glyph reads as a hyperlink out of Settings context),
    /// and the same cable connector the discovery card uses for USB.
    private var iconName: String {
        switch card {
        case .wireless: "antenna.radiowaves.left.and.right"
        case .cableLink: "cable.connector"
        }
    }

    /// One-word "why pick this" — the differentiator, not a stream-preset label.
    private var headline: String {
        switch card {
        case .wireless: "Most freedom"
        case .cableLink: "Most stable"
        }
    }

    private var pros: [String] {
        switch card {
        case .wireless:
            ["Move freely around the set", "No cable to the camera"]
        case .cableLink:
            ["Most stable, lowest latency", "No Wi‑Fi radio draining battery"]
        }
    }

    private var con: String {
        switch card {
        case .wireless: "Heavier battery use"
        case .cableLink: "Less freedom to move"
        }
    }
}

struct StartupIconSquare: View {
    let systemName: String
    var size: CGFloat = 56
    var cornerRadius: CGFloat = MonitorTheme.radius
    var tint: Color = MonitorTheme.accent

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(MonitorTheme.raised)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius).stroke(
                    tint.opacity(0.46), lineWidth: 1)
            )
            .overlay {
                Image(systemName: systemName)
                    .font(.system(size: max(16, size * 0.38), weight: .medium))
                    .foregroundStyle(tint)
            }
            .frame(width: size, height: size)
    }
}

struct StartupOutlineButtonStyle: ButtonStyle {

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .semibold, design: .rounded))
            .foregroundStyle(MonitorTheme.text)
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
            .background(
                MonitorTheme.raised.opacity(configuration.isPressed ? 0.98 : 0.82),
                in: RoundedRectangle(cornerRadius: MonitorTheme.radius)
            )
            .overlay(
                RoundedRectangle(cornerRadius: MonitorTheme.radius).stroke(
                    Color.white.opacity(0.12), lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.78 : 1)
    }
}

/// Asks before connecting to a camera another device is holding.
///
/// A modifier rather than an alert written into one screen: the pairing wizard and the saved-camera
/// list both reach the same connect, so the confirmation has to be wherever the operator is when
/// the model raises it. The alert names the device that loses its session, because "are you sure"
/// without that is not a decision anyone can make.
struct TakeOverConfirmation: ViewModifier {
    /// Passed in rather than read from the environment: this is mounted at the app root, above
    /// the point where the model is installed, and an `@Environment` lookup there traps at launch.
    let model: NativeAppModel

    func body(content: Content) -> some View {
        content.alert(
            "Take over this camera?",
            isPresented: Binding(
                get: { model.pendingTakeOverCamera != nil },
                set: { if !$0 { model.cancelTakeOver() } }
            )
        ) {
            Button("Take Over", role: .destructive) { model.confirmTakeOver() }
            Button("Cancel", role: .cancel) { model.cancelTakeOver() }
        } message: {
            Text(takeOverMessage)
        }
    }

    private var takeOverMessage: String {
        let holder = model.pendingTakeOverCamera?.heldByDeviceName
        guard let holder, !holder.isEmpty else {
            return "Another device is using this camera. Connecting will disconnect it."
        }
        return "\(holder) is using this camera. Connecting will disconnect it."
    }
}

extension View {
    func takeOverConfirmation(model: NativeAppModel) -> some View {
        modifier(TakeOverConfirmation(model: model))
    }
}

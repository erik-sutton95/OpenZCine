import SwiftUI

/// Maps technical connection/discovery status strings to operator-friendly copy for startup screens.
enum StartupConnectionCopy {
    static func friendly(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }

        let lower = trimmed.lowercased()
        if lower.contains("imagecapturecore") {
            // Raw ICC error (e.g. -21400 on a stale USB session): the app retries with a session
            // recycle automatically, so reaching the operator means even that failed.
            return "The USB link got stuck. Unplug the cable, plug it back in, and try again."
        }
        if lower.contains("ptp-ip") || lower.contains("ptp ip") {
            if lower.contains("no") && (lower.contains("service") || lower.contains("answered")) {
                return "Couldn't reach the camera. Check Wi‑Fi and try again."
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
            return "The camera didn't respond in time. Check Wi‑Fi and try again."
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

    static func friendlyStatusTitle(
        for connection: NativeAppModel.ConnectionState, isDiscovering: Bool
    ) -> String {
        switch connection {
        case .disconnected:
            return isDiscovering ? "Looking" : "Ready"
        case .scanning:
            return "Looking"
        case .pairing:
            return "Pairing"
        case .reconnecting:
            return "Reconnecting"
        case .preparingLiveView:
            return "Reading"
        case .connected:
            return "Connected"
        }
    }
}

enum StartupColors {
    static let background = Color(red: 0.114, green: 0.094, blue: 0.075)
    static let surface = Color(red: 0.086, green: 0.075, blue: 0.059)
    static let tile = Color(red: 0.141, green: 0.122, blue: 0.102)
    static let control = Color(red: 0.173, green: 0.149, blue: 0.125)
    static let ink = Color(red: 0.949, green: 0.925, blue: 0.886)
    static let muted = Color(red: 0.655, green: 0.612, blue: 0.553)
    static let dim = Color(red: 0.490, green: 0.447, blue: 0.392)
    static let border = Color.white
    static let card = surface.opacity(0.58)
    static let accent = Color(red: 0.878, green: 0.655, blue: 0.227)
    static let ready = Color(red: 0.247, green: 0.710, blue: 0.416)
    static let destructive = Color(red: 0.930, green: 0.267, blue: 0.267)
    static let darkText = Color(red: 0.110, green: 0.086, blue: 0.047)

    /// Cinematic page backdrop for the connection screens: a warm near-black base with a soft glow
    /// from the upper area that falls off toward the edges (matches the setup mockup).
    static var backdrop: some View {
        ZStack {
            Color(red: 0.055, green: 0.045, blue: 0.034)
            RadialGradient(
                colors: [
                    Color(red: 0.132, green: 0.108, blue: 0.082),
                    Color(red: 0.055, green: 0.045, blue: 0.034).opacity(0),
                ],
                center: UnitPoint(x: 0.5, y: 0.24),
                startRadius: 8,
                endRadius: 760
            )
        }
    }
}

struct StartupHeader: View {
    @Environment(\.openURL) private var openURL

    var title: String = "Connection setup"
    let statusTitle: String
    let isBusy: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 11) {
            VStack(alignment: .leading, spacing: 1) {
                Text("OPENZCINE")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .tracking(1.3)
                    .foregroundStyle(StartupColors.muted)
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Text(title)
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(StartupColors.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    legalLink("Privacy", path: "privacy")
                    legalLink("Terms", path: "terms")
                }
            }

            Spacer(minLength: 8)

            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                Text(statusTitle)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(statusColor)
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(StartupColors.surface.opacity(0.50), in: Capsule())
            .overlay(Capsule().stroke(statusColor.opacity(0.40), lineWidth: 1))
        }
    }

    /// Quiet utility text link to a policy page on openzcine.app — deliberately dimmer than the
    /// title so it never competes with it.
    private func legalLink(_ label: String, path: String) -> some View {
        Button(label) {
            guard let url = URL(string: "https://openzcine.app/\(path)") else { return }
            openURL(url)
        }
        .font(.system(size: 11, weight: .medium, design: .rounded))
        .foregroundStyle(StartupColors.dim)
        .lineLimit(1)
        .fixedSize()
        .buttonStyle(.zcTapTarget)
        .accessibilityLabel("Open the OpenZCine \(label) page")
    }

    private var statusColor: Color {
        if isBusy
            || [
                "Looking", "Pairing", "Reconnecting", "Starting", "Reading", "Discovering",
                "Preparing",
            ]
            .contains(statusTitle)
        {
            return StartupColors.accent
        }
        return StartupColors.ready
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
                    .tint(StartupColors.accent)
                StartupIconSquare(systemName: "camera.aperture", size: 48)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text(
                    model.userFacingConnectionMessage.isEmpty
                        ? "Reading camera settings…"
                        : model.userFacingConnectionMessage
                )
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(StartupColors.ink)
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

struct StartupSavedCamerasView: View {
    @Environment(NativeAppModel.self) private var model
    let compact: Bool
    let contentLayout: StartupContentLayout

    var body: some View {
        // Split on actual available width, not the shared `compact` mode (which reads iPhone
        // landscape as single-column): two columns whenever the width can hold them.
        GeometryReader { proxy in
            let twoColumn = proxy.size.width >= 640
            Group {
                if twoColumn {
                    HStack(alignment: .top, spacing: 16) {
                        introCard(hugsContent: false)
                            .frame(width: max(288, proxy.size.width * 0.36))
                            .frame(maxHeight: .infinity)
                        cameraListCard
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 14) {
                        // Hugging intro: the landscape Spacer makes the card height-greedy, which
                        // stacked stole half the screen from the camera list as a dead band.
                        introCard(hugsContent: true)
                        cameraListCard
                            .frame(maxHeight: .infinity)
                    }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
    }

    private func introCard(hugsContent: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Your cameras.")
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundStyle(StartupColors.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(
                "Tap a saved camera to reconnect. Recovery help stays on the row that needs it."
            )
            .font(.system(size: 13, weight: .regular, design: .rounded))
            .foregroundStyle(StartupColors.muted)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 10)

            if hugsContent {
                Color.clear.frame(height: 16)  // stacked: hug, give the camera list the height
            } else {
                Spacer(minLength: 12)  // two-column: fill the column, pin buttons to the bottom
            }

            VStack(spacing: 10) {
                Button {
                    model.startFirstPairWizard()
                } label: {
                    Text("Pair new camera")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(StartupFilledButtonStyle())
                .disabled(isBusy)

                StartupMediaLibraryButton(compact: true, disabled: isBusy)

                // Settings work without a camera — Frame.io sign-in and cache live in Storage.
                Button {
                    model.openStandaloneSettings()
                } label: {
                    Label("Settings", systemImage: "gearshape")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(StartupQuietButtonStyle())
                .disabled(isBusy)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(cardBackground)
    }

    private var cameraListCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("CAMERA LIST")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .tracking(1.4)
                .foregroundStyle(StartupColors.muted)
            Text("Tap a camera to connect")
                .font(.system(size: 25, weight: .bold, design: .rounded))
                .foregroundStyle(StartupColors.ink)
                .padding(.top, 6)

            ScrollView {
                VStack(spacing: 12) {
                    if let hotspotPrompt {
                        StartupHotspotRecoveryCard(
                            camera: hotspotPrompt.camera,
                            bridgeIsActive: hotspotPrompt.bridgeIsActive
                        )
                    }
                    ForEach(model.savedCameras) { camera in
                        let availability = SavedCameraAvailabilityPolicy.resolve(
                            camera: camera,
                            discoveredCameras: model.discoveredCameras,
                            connectedHost: model.connectedIdentity?.host
                        )
                        StartupCameraListRow(
                            camera: camera,
                            availability: availability,
                            isBusy: isBusy,
                            isRecoveryTarget: hotspotPrompt?.camera.host == camera.host
                        )
                        .environment(model)
                    }
                }
                .padding(.top, 16)
                .padding(.bottom, 4)
            }
            // Pull down to rescan: one awaited discovery pass (rows keep their last state while
            // it runs), then the background loop resumes.
            .refreshable {
                await model.refreshCameraDiscovery()
            }
            .fadeOverflowBottom()
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(cardBackground)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(StartupColors.card)
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(StartupColors.border.opacity(0.08), lineWidth: 1)
            )
    }

    private var isBusy: Bool {
        model.isStartupActionLocked
    }

    private var hotspotPrompt: (camera: PTPIPSavedCameraRecord, bridgeIsActive: Bool)? {
        switch model.startupRecoveryPrompt {
        case .none:
            return nil
        case .enableIPhoneHotspot(let camera):
            return (camera, false)
        case .waitForIPhoneHotspotCamera(let camera):
            return (camera, true)
        }
    }
}

struct StartupHotspotRecoveryCard: View {
    let camera: PTPIPSavedCameraRecord
    let bridgeIsActive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "personalhotspot")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(StartupColors.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(StartupColors.ink)
                    Text(camera.displayTitle)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(StartupColors.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }

            Text(detail)
                .font(.system(size: 12, weight: .regular, design: .rounded))
                .foregroundStyle(StartupColors.muted)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                ForEach(steps, id: \.self) { step in
                    StartupStepPill(text: step)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .background(
            StartupColors.surface.opacity(0.74),
            in: RoundedRectangle(cornerRadius: DesignTokens.cornerRadius)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.cornerRadius)
                .stroke(StartupColors.accent.opacity(0.35), lineWidth: 1)
        )
    }

    private var title: String {
        bridgeIsActive ? "iPhone Hotspot active" : "iPhone Hotspot needed"
    }

    private var detail: String {
        if bridgeIsActive {
            return
                "Your iPhone hotspot is ready. Keep Connect to PC on in the camera menu — we'll connect as soon as the camera joins."
        }
        return
            "Open Settings → Personal Hotspot, turn on Allow Others to Join, then return here while the camera connects."
    }

    private var steps: [String] {
        if bridgeIsActive {
            return ["Hotspot on", "Connect to PC", "Waiting"]
        }
        return ["Settings", "Hotspot", "Allow others"]
    }
}

struct StartupStepPill: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(StartupColors.ink)
            .lineLimit(1)
            .minimumScaleFactor(0.78)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(StartupColors.control.opacity(0.78), in: Capsule())
            .overlay(Capsule().stroke(StartupColors.border.opacity(0.10), lineWidth: 1))
    }
}

enum StartupCameraColorOption: String, CaseIterable, Identifiable {
    case amber
    case green
    case blue
    case red
    case violet
    case white

    var id: String { rawValue }

    static func resolve(_ rawValue: String?) -> StartupCameraColorOption {
        rawValue.flatMap(StartupCameraColorOption.init(rawValue:)) ?? .amber
    }

    var title: String {
        switch self {
        case .amber: "Amber"
        case .green: "Green"
        case .blue: "Blue"
        case .red: "Red"
        case .violet: "Violet"
        case .white: "White"
        }
    }

    var color: Color {
        switch self {
        case .amber:
            return StartupColors.accent
        case .green:
            return StartupColors.ready
        case .blue:
            return Color(red: 0.294, green: 0.624, blue: 0.969)
        case .red:
            return StartupColors.destructive
        case .violet:
            return Color(red: 0.675, green: 0.506, blue: 0.945)
        case .white:
            return StartupColors.ink
        }
    }
}

enum StartupCameraIconOption: String, CaseIterable, Identifiable {
    case viewfinder
    case camera
    case video
    case a
    case b
    case c

    var id: String { rawValue }

    static func resolve(_ rawValue: String?) -> StartupCameraIconOption {
        rawValue.flatMap(StartupCameraIconOption.init(rawValue:)) ?? .viewfinder
    }

    var title: String {
        switch self {
        case .viewfinder: "Viewfinder"
        case .camera: "Camera"
        case .video: "Video"
        case .a: "A"
        case .b: "B"
        case .c: "C"
        }
    }

    var systemName: String? {
        switch self {
        case .viewfinder:
            return "viewfinder"
        case .camera:
            return "camera"
        case .video:
            return "video"
        case .a, .b, .c:
            return nil
        }
    }
}

struct StartupCameraIconSquare: View {
    let option: StartupCameraIconOption
    var size: CGFloat = 56
    var cornerRadius: CGFloat = DesignTokens.cornerRadius
    var tint: Color

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(StartupColors.tile)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius).stroke(
                    tint.opacity(0.52), lineWidth: 1.2)
            )
            .overlay {
                if let systemName = option.systemName {
                    Image(systemName: systemName)
                        .font(.system(size: max(16, size * 0.38), weight: .medium))
                        .foregroundStyle(tint)
                } else {
                    Text(option.title)
                        .font(.system(size: max(18, size * 0.42), weight: .bold, design: .rounded))
                        .foregroundStyle(tint)
                }
            }
            .frame(width: size, height: size)
    }
}

/// One rich row in the landscape camera list: identity + transport/SSID/last-connected detail,
/// a status pill, and a Connect/Reconnect action. Edit/remove live in a long-press menu.
struct StartupCameraListRow: View {
    @Environment(NativeAppModel.self) private var model
    @State private var isDeleteConfirmationPresented = false
    @State private var isRenamePresented = false
    @State private var renameText = ""
    let camera: PTPIPSavedCameraRecord
    let availability: SavedCameraAvailability
    let isBusy: Bool
    var isRecoveryTarget: Bool = false

    var body: some View {
        // Ticks once a second so the card-scan state (pill %, dimmed Preparing… button, subtitle)
        // stays live between discovery passes — the scan progresses outside observable state.
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 8) {
                    Text(title)
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(StartupColors.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    statusPill
                    connectButton
                    optionsMenu
                }
                Text(subtitle)
                    .font(.system(size: 13, weight: .regular, design: .rounded))
                    .foregroundStyle(StartupColors.muted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StartupColors.tile.opacity(0.45), in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14).stroke(borderColor, lineWidth: 1)
        )
        .contextMenu { menuActions }
        .alert("Remove camera?", isPresented: $isDeleteConfirmationPresented) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) {
                model.forgetPairing(host: camera.host)
            }
        } message: {
            Text("Remove \(camera.displayTitle) from saved cameras on this iPhone.")
        }
        .alert("Rename camera", isPresented: $isRenamePresented) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Save") { commitRename() }
        } message: {
            Text("Give this camera a name you'll recognize.")
        }
    }

    @ViewBuilder private var menuActions: some View {
        Button {
            renameText = camera.presentation?.customName ?? ""
            isRenamePresented = true
        } label: {
            Label("Rename", systemImage: "pencil")
        }
        Button(role: .destructive) {
            isDeleteConfirmationPresented = true
        } label: {
            Label("Remove", systemImage: "trash")
        }
    }

    private func commitRename() {
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        model.updateSavedCameraPresentation(
            camera: camera,
            customName: trimmed.isEmpty ? nil : trimmed,
            borderColor: camera.presentation?.borderColor,
            icon: camera.presentation?.icon
        )
    }

    private func connect() {
        switch availability {
        case .available(let discoveredCamera):
            model.connectToCamera(discoveredCamera)
        case .connected, .offline:
            model.connectSavedCamera(camera)
        }
    }

    /// True while the plugged-in camera's card scan is still running — the window where a tap
    /// would sit in "Reading the camera's card…" instead of connecting instantly.
    private var isPreparingCard: Bool {
        if let usbScan { return !usbScan.ready }
        return false
    }

    @ViewBuilder private var connectButton: some View {
        // While the card scan runs, the button dims and says so — but stays tappable: a scan that
        // silently failed would otherwise strand the row disabled forever, and an early tap still
        // works (the progress sheet narrates the remaining scan).
        if isPrimary, !isPreparingCard {
            Button {
                connect()
            } label: {
                Text(buttonLabel).fixedSize()
            }
            .buttonStyle(StartupFilledButtonStyle())
            .disabled(isBusy)
        } else {
            Button {
                connect()
            } label: {
                Text(isPreparingCard ? "Preparing…" : buttonLabel).fixedSize()
            }
            .buttonStyle(StartupOutlineButtonStyle())
            .opacity(isPreparingCard ? 0.55 : 1)
            .disabled(isBusy)
        }
    }

    private var statusPill: some View {
        Text(statusText)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(statusColor)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .overlay(Capsule().stroke(statusColor.opacity(0.5), lineWidth: 1))
    }

    /// USB card-scan state for this row's discovered camera; nil for Wi-Fi rows or once absent.
    private var usbScan: (ready: Bool, percent: Int)? {
        guard case .available(let discovered) = availability else { return nil }
        return model.usbCardScan(for: discovered)
    }

    /// Discoverable rename / remove, mirroring the long-press context menu.
    private var optionsMenu: some View {
        Menu {
            menuActions
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(StartupColors.muted)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Camera options")
    }

    private var isPrimary: Bool {
        if isRecoveryTarget { return false }
        switch availability {
        case .available, .connected: return true
        case .offline: return false
        }
    }

    private var buttonLabel: String { isRecoveryTarget ? "Reconnect" : "Connect" }

    private var statusText: String {
        if isRecoveryTarget { return "Waiting for hotspot" }
        switch availability {
        case .connected: return "Connected"
        case .available:
            if let usbScan {
                return usbScan.ready ? "Ready" : "Preparing card… \(usbScan.percent)%"
            }
            return "Online"
        case .offline: return "Offline"
        }
    }

    private var statusColor: Color {
        if isRecoveryTarget { return StartupColors.accent }
        switch availability {
        case .connected, .available:
            if let usbScan, !usbScan.ready { return StartupColors.accent }
            return StartupColors.ready
        case .offline: return StartupColors.dim
        }
    }

    private var borderColor: Color {
        if isRecoveryTarget { return StartupColors.accent.opacity(0.35) }
        switch availability {
        case .connected, .available: return StartupColors.ready.opacity(0.28)
        case .offline: return StartupColors.border.opacity(0.08)
        }
    }

    private var title: String {
        let base = ConnectionProgressCopy.resolveDisplayName(
            rawName: camera.displayName, savedCamera: nil)
        let custom =
            camera.presentation?.customName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return custom.isEmpty ? base : "\(base) · \(custom)"
    }

    private var subtitle: String {
        if isPreparingCard {
            return "USB-C · getting the card ready — connect will be instant once it's done"
        }
        var parts: [String] = []
        if camera.isUSBTransport {
            parts.append("USB-C")
            parts.append("connect cable to wake the session")
        } else {
            parts.append("Wi‑Fi")
            if let ssid = CameraWiFiSSID.resolve(for: camera) { parts.append(ssid) }
            parts.append(lastConnectedText)
        }
        return parts.joined(separator: " · ")
    }

    private var lastConnectedText: String {
        guard let lastSeenAt = camera.lastSeenAt else { return "saved profile" }
        let seconds = max(0, Date().timeIntervalSince(lastSeenAt))
        if seconds < 86_400 { return "last connected today" }
        if seconds < 172_800 { return "last connected yesterday" }
        return "last connected \(Int(seconds / 86_400))d ago"
    }
}

struct StartupSavedCameraEditorSheet: View {
    @Environment(NativeAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let camera: PTPIPSavedCameraRecord
    @State private var customName: String
    @State private var selectedColor: StartupCameraColorOption
    @State private var selectedIcon: StartupCameraIconOption

    init(camera: PTPIPSavedCameraRecord) {
        self.camera = camera
        _customName = State(initialValue: camera.presentation?.customName ?? "")
        _selectedColor = State(
            initialValue: StartupCameraColorOption.resolve(camera.presentation?.borderColor)
        )
        _selectedIcon = State(
            initialValue: StartupCameraIconOption.resolve(camera.presentation?.icon))
    }

    var body: some View {
        GeometryReader { proxy in
            let layout = StartupSavedCameraEditorLayout.fit(
                viewportWidth: Double(proxy.size.width),
                viewportHeight: Double(proxy.size.height),
                safeArea: proxy.monitorEdgeInsets
            )

            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        header
                        nameEditor
                        colorPicker
                        iconPicker
                    }
                    .padding(.horizontal, CGFloat(layout.horizontalPadding))
                    .padding(.top, CGFloat(layout.verticalPadding))
                    .padding(.bottom, 16)
                    .frame(maxWidth: CGFloat(layout.maxContentWidth), alignment: .leading)
                    .frame(maxWidth: .infinity)
                }

                actions
                    .padding(.horizontal, CGFloat(layout.horizontalPadding))
                    .padding(.top, 12)
                    .padding(.bottom, CGFloat(layout.verticalPadding))
                    .frame(maxWidth: CGFloat(layout.maxContentWidth))
                    .frame(maxWidth: .infinity)
                    .background(StartupColors.background)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .background(StartupColors.background)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Camera identity")
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(StartupColors.ink)
            Text(camera.displayName)
                .font(.system(size: 12, weight: .regular, design: .rounded))
                .foregroundStyle(StartupColors.muted)
                .lineLimit(1)
        }
    }

    private var nameEditor: some View {
        HStack(alignment: .top, spacing: 22) {
            StartupCameraIconSquare(
                option: selectedIcon,
                size: 72,
                tint: selectedColor.color
            )

            VStack(alignment: .leading, spacing: 9) {
                Text("Display name")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(StartupColors.muted)
                TextField(camera.displayName, text: $customName)
                    .textInputAutocapitalization(.words)
                    .disableAutocorrection(true)
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(StartupColors.ink)
                    .padding(.horizontal, 13)
                    .frame(height: 42)
                    .background(
                        StartupColors.control,
                        in: RoundedRectangle(cornerRadius: DesignTokens.cornerRadius)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignTokens.cornerRadius)
                            .stroke(StartupColors.border.opacity(0.12), lineWidth: 1)
                    )

                Button("Use camera name") {
                    customName = ""
                }
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(StartupColors.muted)
            }
        }
    }

    private var colorPicker: some View {
        optionSection(title: "Border color") {
            HStack(spacing: 10) {
                ForEach(StartupCameraColorOption.allCases) { option in
                    colorButton(option)
                }
            }
        }
    }

    private var iconPicker: some View {
        optionSection(title: "Icon") {
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3),
                spacing: 10
            ) {
                ForEach(StartupCameraIconOption.allCases) { option in
                    iconButton(option)
                }
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 12) {
            Button {
                dismiss()
            } label: {
                Text("Cancel")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(StartupOutlineButtonStyle())

            Button {
                model.updateSavedCameraPresentation(
                    camera: camera,
                    customName: customName,
                    borderColor: selectedColor.rawValue,
                    icon: selectedIcon.rawValue
                )
                dismiss()
            } label: {
                Text("Save")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(StartupFilledButtonStyle())
        }
    }

    private func colorButton(_ option: StartupCameraColorOption) -> some View {
        Button {
            selectedColor = option
        } label: {
            Circle()
                .fill(option.color)
                .frame(width: 28, height: 28)
                .overlay(
                    Circle().stroke(
                        StartupColors.ink.opacity(selectedColor == option ? 0.92 : 0.18),
                        lineWidth: selectedColor == option ? 2 : 1
                    )
                )
                .overlay {
                    if selectedColor == option {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(
                                option == .white ? StartupColors.background : StartupColors.ink)
                    }
                }
        }
        .buttonStyle(.zcTapTarget)
        .accessibilityLabel(option.title)
    }

    private func iconButton(_ option: StartupCameraIconOption) -> some View {
        Button {
            selectedIcon = option
        } label: {
            HStack(spacing: 9) {
                StartupCameraIconSquare(
                    option: option,
                    size: 34,
                    tint: selectedColor.color
                )
                Text(option.title)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(StartupColors.ink)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 48)
            .background(
                StartupColors.control.opacity(selectedIcon == option ? 1.0 : 0.54),
                in: RoundedRectangle(cornerRadius: DesignTokens.cornerRadius)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.cornerRadius)
                    .stroke(
                        selectedIcon == option
                            ? selectedColor.color.opacity(0.70)
                            : StartupColors.border.opacity(0.08),
                        lineWidth: selectedIcon == option ? 1.5 : 1
                    )
            )
        }
        .buttonStyle(.zcTapTarget)
    }

    @ViewBuilder
    private func optionSection<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(StartupColors.muted)
            content()
        }
    }
}

/// Typography and spacing tuned so the first-pair wizard fits in landscape without scrolling.
struct WizardCompactStyle: Sendable {
    let progressSpacing: CGFloat
    let stepContentSpacing: CGFloat
    let sectionSpacing: CGFloat
    let titleFontSize: CGFloat
    let bodyFontSize: CGFloat
    let checklistFontSize: CGFloat
    let checklistDetailFontSize: CGFloat
    let checklistSpacing: CGFloat
    let transportCardSpacing: CGFloat
    let transportRowMinHeight: CGFloat
    let useTransportSplitLayout: Bool
    let useInstructionSplitLayout: Bool
    let useDualDeviceColumns: Bool
    let introColumnFraction: CGFloat
    let footerSpacing: CGFloat
    let footerActionSpacing: CGFloat
    let isTight: Bool

    /// Builds wizard chrome for the active startup layout profile. The app is landscape-locked, so
    /// every landscape profile uses bounded vertical layout with tight height budgeting.
    static func make(profile: StartupLayoutProfile) -> WizardCompactStyle {
        switch profile {
        case .compactPortrait:
            return WizardCompactStyle(
                progressSpacing: 4,
                stepContentSpacing: 6,
                sectionSpacing: 6,
                titleFontSize: 19,
                bodyFontSize: 11,
                checklistFontSize: 11,
                checklistDetailFontSize: 10,
                checklistSpacing: 4,
                transportCardSpacing: 5,
                transportRowMinHeight: 52,
                useTransportSplitLayout: false,
                useInstructionSplitLayout: false,
                useDualDeviceColumns: false,
                introColumnFraction: 0.38,
                footerSpacing: 2,
                footerActionSpacing: 8,
                isTight: true
            )
        case .compactLandscape:
            return WizardCompactStyle(
                progressSpacing: 4,
                stepContentSpacing: 6,
                sectionSpacing: 6,
                titleFontSize: 18,
                bodyFontSize: 12,
                checklistFontSize: 13,
                checklistDetailFontSize: 12,
                checklistSpacing: 3,
                transportCardSpacing: 5,
                transportRowMinHeight: 48,
                useTransportSplitLayout: true,
                useInstructionSplitLayout: true,
                useDualDeviceColumns: true,
                introColumnFraction: 0.34,
                footerSpacing: 2,
                footerActionSpacing: 8,
                isTight: true
            )
        case .regularLandscape:
            return WizardCompactStyle(
                progressSpacing: 6,
                stepContentSpacing: 8,
                sectionSpacing: 8,
                titleFontSize: 21,
                bodyFontSize: 13,
                checklistFontSize: 14,
                checklistDetailFontSize: 13,
                checklistSpacing: 4,
                transportCardSpacing: 6,
                transportRowMinHeight: 56,
                useTransportSplitLayout: true,
                useInstructionSplitLayout: true,
                useDualDeviceColumns: false,
                introColumnFraction: 0.36,
                footerSpacing: 4,
                footerActionSpacing: 10,
                isTight: true
            )
        case .wideLandscape:
            return WizardCompactStyle(
                progressSpacing: 8,
                stepContentSpacing: 10,
                sectionSpacing: 10,
                titleFontSize: 23,
                bodyFontSize: 14,
                checklistFontSize: 15,
                checklistDetailFontSize: 14,
                checklistSpacing: 5,
                transportCardSpacing: 8,
                transportRowMinHeight: 62,
                useTransportSplitLayout: true,
                useInstructionSplitLayout: true,
                useDualDeviceColumns: false,
                introColumnFraction: 0.38,
                footerSpacing: 4,
                footerActionSpacing: 12,
                isTight: false
            )
        }
    }
}

/// Device label used in wizard network instructions.
enum StartupWizardDevice: String, Sendable {
    case camera
    case iPhone

    var title: String {
        switch self {
        case .camera: "On camera"
        case .iPhone: "On iPhone"
        }
    }

    var systemImage: String {
        switch self {
        case .camera: "camera.aperture"
        case .iPhone: "iphone"
        }
    }
}

/// One numbered item in the shared camera-menu checklist (step 2).
/// Device-specific instructions for the network step, branched by transport method.
struct StartupWizardDeviceSection: Identifiable, Sendable {
    let id: String
    let device: StartupWizardDevice
    let steps: [String]
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
                "Connect the USB‑C cable between the camera and your iPhone.",
                "Leave the camera switched on — no network profile is needed.",
            ]
        }
    }

    static func networkSections(
        for transport: NativeAppModel.FirstPairTransportMethod,
        tight: Bool
    ) -> [StartupWizardDeviceSection] {
        switch transport {
        case .cameraAccessPoint:
            return [
                StartupWizardDeviceSection(
                    id: "camera-ap-camera",
                    device: .camera,
                    steps: tight
                        ? ["Keep the SSID & key screen visible"]
                        : [
                            "Leave the camera on its Direct connection screen",
                            "It shows the network SSID and key",
                        ]
                ),
                StartupWizardDeviceSection(
                    id: "camera-ap-iphone",
                    device: .iPhone,
                    steps: tight
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
                StartupWizardDeviceSection(
                    id: "hotspot-camera",
                    device: .camera,
                    steps: [
                        "Connect to computer → Network settings",
                        "Create Profile → name your profile",
                        "Search for Wi‑Fi network → Join your iPhone hotspot",
                        "IP address → Obtain automatically",
                    ]
                )
            ]
        case .usbC:
            return [
                StartupWizardDeviceSection(
                    id: "usb-camera",
                    device: .camera,
                    steps: tight
                        ? [
                            "Plug the camera into this iPhone with USB-C",
                            "Confirm any connection prompt on the camera",
                        ]
                        : [
                            "Plug the camera into this iPhone with a USB-C cable",
                            "If the camera shows a connection prompt, confirm it",
                        ]
                ),
                StartupWizardDeviceSection(
                    id: "usb-iphone",
                    device: .iPhone,
                    steps: tight
                        ? ["Tap Allow when iOS asks for camera access"]
                        : [
                            "iOS asks to allow OpenZCine to access the camera the first time — tap Allow",
                            "Return here once the cable is connected",
                        ]
                ),
            ]
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
                : "Connect the cable, confirm the camera's prompt, and allow camera access on this iPhone when asked."
        }
    }
}

/// Prepare-step instructions as spacious numbered cards (one sentence each), matching the first-run
/// mockup. Sized for the short landscape height — no scrolling.
struct StartupWizardPrepareCards: View {
    let steps: [String]
    let style: WizardCompactStyle

    var body: some View {
        VStack(alignment: .leading, spacing: style.isTight ? 6 : 10) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .top, spacing: style.isTight ? 10 : 12) {
                    Text("\(index + 1)")
                        .font(
                            .system(size: style.isTight ? 12 : 13, weight: .bold, design: .rounded)
                        )
                        .foregroundStyle(StartupColors.accent)
                        .frame(width: style.isTight ? 24 : 30, height: style.isTight ? 24 : 30)
                        .background(
                            StartupColors.accent.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(StartupColors.accent.opacity(0.45), lineWidth: 1)
                        )

                    Text(step)
                        .font(
                            .system(
                                size: style.checklistFontSize + 1, weight: .medium, design: .rounded
                            )
                        )
                        .foregroundStyle(StartupColors.ink)
                        .lineSpacing(1)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, style.isTight ? 12 : 16)
                .padding(.vertical, style.isTight ? 9 : 15)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    StartupColors.card,
                    in: RoundedRectangle(cornerRadius: DesignTokens.cornerRadius)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DesignTokens.cornerRadius)
                        .stroke(StartupColors.border.opacity(0.10), lineWidth: 1)
                )
            }
        }
    }
}

struct StartupWizardDeviceInstructionCard: View {
    let section: StartupWizardDeviceSection
    let style: WizardCompactStyle

    var body: some View {
        VStack(alignment: .leading, spacing: style.isTight ? 6 : 8) {
            HStack(spacing: 8) {
                Image(systemName: section.device.systemImage)
                    .font(.system(size: style.isTight ? 13 : 15, weight: .semibold))
                    .foregroundStyle(StartupColors.accent)
                Text(section.device.title)
                    .font(.system(size: style.isTight ? 11 : 12, weight: .bold, design: .rounded))
                    .foregroundStyle(StartupColors.ink)
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: style.checklistSpacing) {
                ForEach(Array(section.steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(index + 1)")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundStyle(StartupColors.muted)
                            .frame(width: 14, alignment: .trailing)
                            .padding(.top, 1)
                        Text(step)
                            .font(
                                .system(
                                    size: style.checklistFontSize, weight: .medium,
                                    design: .rounded)
                            )
                            .foregroundStyle(StartupColors.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(.horizontal, style.isTight ? 10 : 14)
        .padding(.vertical, style.isTight ? 10 : 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            StartupColors.card, in: RoundedRectangle(cornerRadius: DesignTokens.cornerRadius)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.cornerRadius)
                .stroke(StartupColors.border.opacity(0.10), lineWidth: 1)
        )
    }
}

struct StartupWizardInfoBanner: View {
    let text: String
    let style: WizardCompactStyle

    var body: some View {
        HStack(alignment: .top, spacing: style.isTight ? 8 : 10) {
            Image(systemName: "info.circle.fill")
                .font(.system(size: style.isTight ? 12 : 14, weight: .semibold))
                .foregroundStyle(StartupColors.accent)
            Text(text)
                .font(
                    .system(size: style.checklistDetailFontSize, weight: .regular, design: .rounded)
                )
                .foregroundStyle(StartupColors.muted)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, style.isTight ? 10 : 12)
        .padding(.vertical, style.isTight ? 8 : 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            StartupColors.surface.opacity(0.72),
            in: RoundedRectangle(cornerRadius: DesignTokens.cornerRadius)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.cornerRadius)
                .stroke(StartupColors.accent.opacity(0.28), lineWidth: 1)
        )
    }
}

struct StartupFirstPairWizardView: View {
    @Environment(NativeAppModel.self) private var model
    let compact: Bool
    let isBusy: Bool
    let contentLayout: StartupContentLayout

    // Owned here (not inside the step) so the shell's Continue can gate on it — the operator must
    // grant the required permissions before leaving the permissions step.
    @State private var permissions = StartupPermissionsCoordinator()

    private var style: WizardCompactStyle {
        WizardCompactStyle.make(profile: contentLayout.profile)
    }

    private var showsFooter: Bool {
        // Transport is chosen by tapping a card (selects + advances in one), so it needs no footer.
        // Discovery gets a footer too now — for a Back button consistent with the other steps.
        step != .chooseTransport
    }

    private var step: NativeAppModel.FirstPairWizardStep { model.firstPairWizardStep }

    private var wizardStepCount: Int { model.firstPairWizardStepCount() }

    private var wizardDisplayStepNumber: Int {
        model.firstPairWizardDisplayStepNumber(for: step)
    }

    var body: some View {
        GeometryReader { geo in
            if geo.size.width >= 640 {
                HStack(alignment: .top, spacing: 16) {
                    introCard
                        // Narrower intro column → wider step card, so content (esp. the 3 transport
                        // cards) wraps less and doesn't crowd the bottom edge.
                        .frame(width: max(236, geo.size.width * 0.28))
                        .frame(maxHeight: .infinity)
                    stepCard
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    portraitIntroHeader
                    StartupWizardProgress(
                        currentStep: wizardDisplayStepNumber,
                        totalSteps: wizardStepCount,
                        compact: true
                    )
                    stepCard
                        .frame(maxHeight: .infinity)
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Left column: goal + progress

    private var introCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("FIRST RUN")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .tracking(1.4)
                .foregroundStyle(StartupColors.muted)
            Text("Pair your camera.")
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .foregroundStyle(StartupColors.ink)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
            Text("We'll walk you through it — your camera is connected in about a minute.")
                .font(.system(size: 13, weight: .regular, design: .rounded))
                .foregroundStyle(StartupColors.muted)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)

            Spacer(minLength: 16)

            StartupWizardProgress(
                currentStep: wizardDisplayStepNumber,
                totalSteps: wizardStepCount,
                compact: true
            )
            Text(introFooterText)
                .font(.system(size: 11, weight: .regular, design: .rounded))
                .foregroundStyle(StartupColors.dim)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)

            // Escape hatch when pairing an additional camera over an existing library — otherwise
            // the wizard (now the sole pairing surface) would be a dead end for returning operators.
            if !model.savedCameras.isEmpty {
                yourCamerasButton
                    .padding(.top, 12)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(StartupCardBackground())
    }

    /// Wizard-exit affordance in the outline button style. Padding lives on the LABEL: the style
    /// has no horizontal insets, so a `.fixedSize()` button otherwise clips against the border.
    private var yourCamerasButton: some View {
        Button {
            model.showSavedCameras()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                Image(systemName: "camera")
                    .font(.system(size: 13, weight: .semibold))
                Text("Your cameras")
            }
            .lineLimit(1)
            .padding(.horizontal, 14)
        }
        .buttonStyle(StartupWizardOutlineButtonStyle())
        .fixedSize()
    }

    /// Compact intro for the stacked (portrait) wizard — keeps the walkthrough framing and the
    /// escape back to the saved-cameras home that the two-column intro card provides.
    private var portraitIntroHeader: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("FIRST RUN")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .tracking(1.4)
                        .foregroundStyle(StartupColors.muted)
                    Text("Pair your camera.")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(StartupColors.ink)
                        .padding(.top, 4)
                }
                Spacer(minLength: 12)
                if !model.savedCameras.isEmpty {
                    yourCamerasButton
                }
            }
            Text("We'll walk you through it — your camera is connected in about a minute.")
                .font(.system(size: 12, weight: .regular, design: .rounded))
                .foregroundStyle(StartupColors.muted)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
            // The same per-step helper line the landscape intro column shows.
            Text(introFooterText)
                .font(.system(size: 11, weight: .regular, design: .rounded))
                .foregroundStyle(StartupColors.dim)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
        }
    }

    /// Left-column helper line, kept relevant to the current step (the transport-tradeoff
    /// blurb only makes sense while choosing a transport).
    private var introFooterText: String {
        switch step {
        case .permissions:
            return "Only what pairing needs — change anytime in iOS Settings."
        case .chooseTransport:
            return "Each trades battery, quality, and convenience — pick what fits the shoot."
        case .prepareCamera:
            return
                "Menu names match the Nikon ZR; they may vary by model and firmware version."
        case .connectNetwork:
            return "Get both devices onto the same network — we'll find the camera automatically."
        case .discoverAndPair:
            return "Keep the camera powered on and nearby while we find it."
        }
    }

    // MARK: - Right column: current step

    private var stepCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("STEP \(wizardDisplayStepNumber) OF \(wizardStepCount)")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .tracking(1.4)
                .foregroundStyle(StartupColors.muted)
            Text(step.title)
                .font(.system(size: style.titleFontSize + 2, weight: .bold, design: .rounded))
                .foregroundStyle(StartupColors.ink)
                .padding(.top, 6)

            stepBody
                .padding(.top, style.isTight ? 8 : 12)
                // Light steps (permissions) center vertically in landscape, where the slack is a
                // thin band. Portrait's slack is huge — centering strands the content mid-card,
                // so it stays top-aligned and the slack pools above the pinned footer.
                .frame(
                    maxWidth: .infinity, maxHeight: .infinity,
                    alignment: step == .permissions
                        && contentLayout.profile != .compactPortrait ? .leading : .topLeading)

            if showsFooter {
                stepNav
                    .padding(.top, style.isTight ? 10 : 14)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(StartupCardBackground())
    }

    @ViewBuilder
    private var stepBody: some View {
        switch step {
        case .permissions:
            StartupWizardPermissionsStep(coordinator: permissions, style: style)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        case .chooseTransport:
            transportCards
        case .prepareCamera:
            // Numbered instruction cards (mockup style). The shell supplies the heading and nav.
            StartupWizardPrepareCards(
                steps: StartupWizardContent.preparationSteps(for: model.firstPairTransportMethod),
                style: style
            )
            .frame(maxWidth: .infinity, alignment: .topLeading)
        case .connectNetwork:
            StartupWizardNetworkStep(style: style).environment(model)
        case .discoverAndPair:
            StartupDiscoveryView(isBusy: isBusy)
                .environment(model)
        }
    }

    /// Three side-by-side columns in landscape; stacked full-width cards in portrait, where the
    /// columns are too narrow (truncated titles) — gated on the style's transport-split flag.
    @ViewBuilder
    private var transportCards: some View {
        let cards = ForEach(NativeAppModel.FirstPairTransportMethod.allCases) { method in
            StartupWizardTransportCard(method: method) {
                model.firstPairTransportMethod = method
                model.advanceFirstPairWizard()
            }
            .frame(maxWidth: .infinity)
        }
        if style.useTransportSplitLayout {
            HStack(alignment: .top, spacing: 12) { cards }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // Scrolls: with the portrait intro header above the card, three stacked cards can
            // exceed the remaining height on phones — the last card must never clip dead.
            ScrollView(showsIndicators: false) {
                VStack(spacing: 12) { cards }
            }
            .fadeOverflowBottom()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    private var stepNav: some View {
        // Compact 40pt button styles keep the footer short enough for the tallest step to clear
        // the bottom edge in landscape; bounded widths keep "Connect my camera" on one line.
        HStack(spacing: 10) {
            if model.firstPairWizardCanRetreat(from: step) {
                Button {
                    model.retreatFirstPairWizard()
                } label: {
                    Label("Back", systemImage: "chevron.left")
                        .lineLimit(1)
                }
                .buttonStyle(StartupWizardOutlineButtonStyle())
                .frame(width: 116)
            }

            Spacer(minLength: 0)

            // Discovery advances by connecting to a found camera, so it shows no primary button.
            // Camera Access Point ends at connectNetwork — the primary button opens the scanner.
            if !step.isFinalStep(for: model.firstPairTransportMethod)
                || (step == .connectNetwork && model.firstPairTransportMethod == .cameraAccessPoint)
            {
                Button {
                    model.advanceFirstPairWizard()
                } label: {
                    Text(primaryWizardActionTitle)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                .buttonStyle(StartupWizardFilledButtonStyle())
                .frame(maxWidth: 220)
                // The operator can't leave the permissions step until the required permissions are
                // granted — we can't reach the camera without them.
                .disabled(step == .permissions && !permissions.allRequiredGranted)
            }
        }
    }

    private var primaryWizardActionTitle: String {
        step == .connectNetwork ? "Connect my camera" : "Continue"
    }
}

/// Fades out the bottom edge of a vertical scroll viewport while more content lies below the
/// fold — the "there's more" affordance (Android: `Modifier.fadeOverflowBottom`). Apply to the
/// `ScrollView` itself.
struct StartupOverflowFade: ViewModifier {
    var fadeHeight: CGFloat
    @State private var canScrollFurther = false

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentSize.height - geometry.containerSize.height
                        - geometry.contentOffset.y > 2
                } action: { _, more in
                    canScrollFurther = more
                }
                .mask(
                    VStack(spacing: 0) {
                        Color.black
                        LinearGradient(
                            colors: [.black, canScrollFurther ? .clear : .black],
                            startPoint: .top, endPoint: .bottom
                        )
                        .frame(height: fadeHeight)
                    }
                )
                .animation(.easeInOut(duration: 0.18), value: canScrollFurther)
        } else {
            // Pre-18 systems can't observe scroll geometry cheaply (same trade-off as the assist
            // toolbar); skip the affordance rather than fade a bottom that may not overflow.
            content
        }
    }
}

extension View {
    /// See `StartupOverflowFade`.
    func fadeOverflowBottom(height: CGFloat = 28) -> some View {
        modifier(StartupOverflowFade(fadeHeight: height))
    }
}

/// Shared rounded card surface for the two-column startup screens.
struct StartupCardBackground: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(StartupColors.card)
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(StartupColors.border.opacity(0.08), lineWidth: 1)
            )
    }
}

/// One transport option in the first-run picker: name, stream-mode badge, tradeoff tagline, and a
/// battery / stream / wireless readout. Neutral — no option is crowned as the recommended one.
struct StartupWizardTransportCard: View {
    let method: NativeAppModel.FirstPairTransportMethod
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 0) {
                Image(systemName: iconName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(StartupColors.accent)
                    .frame(width: 34, height: 34)
                    .background(
                        StartupColors.accent.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 9)
                    )
                    .padding(.bottom, 10)
                Text(method.title)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(StartupColors.ink)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(headline)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(StartupColors.accent)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(StartupColors.accent.opacity(0.15), in: Capsule())
                    .fixedSize()
                    .padding(.top, 8)

                VStack(alignment: .leading, spacing: 6) {
                    ForEach(pros, id: \.self) { pro in
                        tradeoffRow(symbol: "plus", color: StartupColors.ready, text: pro)
                    }
                    tradeoffRow(symbol: "minus", color: StartupColors.dim, text: con)
                }
                .padding(.top, 10)

                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(StartupColors.tile.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(StartupColors.border.opacity(0.1), lineWidth: 1)
            )
        }
        .buttonStyle(.zcTapTarget)
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
                .foregroundStyle(StartupColors.muted)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Transport glyph: the camera broadcasting its own network, the phone radiating its hotspot
    /// (the literal `personalhotspot` chain glyph reads as a hyperlink out of Settings context),
    /// and the same cable connector the discovery card uses for USB.
    private var iconName: String {
        switch method {
        case .cameraAccessPoint: "antenna.radiowaves.left.and.right"
        case .phoneHotspot: "iphone.radiowaves.left.and.right"
        case .usbC: "cable.connector"
        }
    }

    /// One-word "why pick this" — the differentiator, not a stream-preset label.
    private var headline: String {
        switch method {
        case .cameraAccessPoint: "Simplest"
        case .phoneHotspot: "Best wireless"
        case .usbC: "Most stable"
        }
    }

    private var pros: [String] {
        switch method {
        case .cameraAccessPoint:
            ["Lightest battery use", "No phone setup needed"]
        case .phoneHotspot:
            ["Best wireless quality", "Stable at high settings"]
        case .usbC:
            ["Most stable, lowest latency", "No Wi‑Fi radio draining battery"]
        }
    }

    private var con: String {
        switch method {
        case .cameraAccessPoint: "Softer link, lower quality"
        case .phoneHotspot: "Heavier battery drain"
        case .usbC: "Less freedom to move"
        }
    }
}

struct StartupWizardProgress: View {
    let currentStep: Int
    let totalSteps: Int
    var spacing: CGFloat = 10
    var compact = false

    var body: some View {
        if compact {
            VStack(alignment: .leading, spacing: spacing) {
                HStack(spacing: 6) {
                    Text("Setup")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(StartupColors.muted)
                    Spacer(minLength: 0)
                    Text("Step \(currentStep) of \(totalSteps)")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(StartupColors.dim)
                }
                HStack(spacing: 4) {
                    ForEach(1...totalSteps, id: \.self) { step in
                        Capsule()
                            .fill(
                                step <= currentStep
                                    ? StartupColors.accent : StartupColors.control.opacity(0.55)
                            )
                            .frame(height: 3)
                            .overlay {
                                if step > currentStep {
                                    Capsule().stroke(
                                        StartupColors.border.opacity(0.08), lineWidth: 1)
                                }
                            }
                    }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: spacing) {
                Text("Set up your first camera")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(StartupColors.muted)
                HStack(spacing: 8) {
                    ForEach(1...totalSteps, id: \.self) { step in
                        Capsule()
                            .fill(
                                step <= currentStep
                                    ? StartupColors.accent : StartupColors.control.opacity(0.55)
                            )
                            .frame(height: 4)
                            .overlay {
                                if step > currentStep {
                                    Capsule().stroke(
                                        StartupColors.border.opacity(0.08), lineWidth: 1)
                                }
                            }
                    }
                }
                Text("Step \(currentStep) of \(totalSteps)")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(StartupColors.dim)
            }
        }
    }
}

struct StartupWizardNetworkStep: View {
    @Environment(NativeAppModel.self) private var model
    let style: WizardCompactStyle

    private var transport: NativeAppModel.FirstPairTransportMethod {
        model.firstPairTransportMethod
    }

    private var deviceSections: [StartupWizardDeviceSection] {
        StartupWizardContent.networkSections(for: transport, tight: style.isTight)
    }

    var body: some View {
        // The wizard shell already renders "STEP n OF m" + the step title — no repeated intro
        // here (it double-rendered and overlapped). Just the subtitle, then the instructions.
        VStack(alignment: .leading, spacing: style.sectionSpacing) {
            Text(StartupWizardContent.networkSubtitle(for: transport, tight: style.isTight))
                .font(.system(size: style.bodyFontSize, weight: .regular, design: .rounded))
                .foregroundStyle(StartupColors.muted)
                .fixedSize(horizontal: false, vertical: true)
            networkInstructions
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var networkInstructions: some View {
        if style.useDualDeviceColumns, deviceSections.count > 1 {
            HStack(alignment: .top, spacing: style.transportCardSpacing) {
                ForEach(deviceSections) { section in
                    StartupWizardDeviceInstructionCard(section: section, style: style)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: style.sectionSpacing) {
                ForEach(deviceSections) { section in
                    StartupWizardDeviceInstructionCard(section: section, style: style)
                }
            }
        }
    }
}

/// The wizard's discover-and-pair step: a compact, single-column list of nearby cameras.
/// This is only ever embedded in the first-pair wizard for Phone Hotspot and USB‑C — the wizard
/// shell supplies the step heading and the Back button, so this renders just the controls.
struct StartupDiscoveryView: View {
    @Environment(NativeAppModel.self) private var model
    let isBusy: Bool

    var body: some View {
        discoveryControls
            .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var discoveryControls: some View {
        let pairingCandidates = model.pairingDiscoveryCandidates
        let selectedPairingCamera = model.selectedPairingDiscoveryCamera
        let primaryAction = StartupDiscoveryPrimaryAction.resolve(
            hasSelectedCamera: selectedPairingCamera != nil,
            isBusy: isBusy,
            isKnownCamera: model.selectedPairingCameraIsKnown
        )

        return VStack(spacing: 8) {
            if pairingCandidates.isEmpty {
                StartupEmptyDiscoveryCard(
                    compact: true,
                    transport: model.discoveryTransportFilter
                )
                // Indeterminate "something's happening" line in place of the status text.
                StartupIndeterminateBar()
                    .padding(.top, 2)
                if model.showsJoinCameraWiFiAction {
                    Button {
                        model.joinCameraWiFiFromDiscovery()
                    } label: {
                        Text(model.joinCameraWiFiButtonTitle)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(StartupFilledButtonStyle())
                    .disabled(isBusy)
                }
            } else {
                ForEach(pairingCandidates.prefix(2)) { camera in
                    StartupDiscoveredCameraCard(
                        camera: camera,
                        selected: selectedPairingCamera?.id == camera.id,
                        compact: true
                    )
                    .environment(model)
                }
            }

            if let title = primaryAction.title {
                Button {
                    model.connectSelectedCamera()
                } label: {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(StartupFilledButtonStyle())
                .disabled(!primaryAction.isEnabled)
            }
        }
    }
}

/// A thin accent line whose segment slides back and forth — an indeterminate "working" indicator,
/// used on the discovery step in place of a status string.
struct StartupIndeterminateBar: View {
    @State private var animating = false

    var body: some View {
        GeometryReader { geo in
            let trackWidth = geo.size.width
            let segmentWidth = max(44, trackWidth * 0.32)
            Capsule()
                .fill(StartupColors.accent)
                .frame(width: segmentWidth, height: 3)
                .offset(x: animating ? trackWidth - segmentWidth : 0)
                .animation(
                    .easeInOut(duration: 0.85).repeatForever(autoreverses: true), value: animating)
        }
        .frame(height: 3)
        .frame(maxWidth: .infinity)
        .background(StartupColors.control.opacity(0.45), in: Capsule())
        .onAppear { animating = true }
    }
}

struct StartupDiscoveredCameraCard: View {
    @Environment(NativeAppModel.self) private var model
    let camera: DiscoveredCamera
    let selected: Bool
    var compact = false

    var body: some View {
        Button {
            model.selectDiscoveredCamera(camera)
        } label: {
            HStack(spacing: compact ? 10 : 14) {
                StartupIconSquare(systemName: "viewfinder", size: compact ? 36 : 48)

                VStack(alignment: .leading, spacing: compact ? 3 : 7) {
                    Text(camera.displayName)
                        .font(
                            .system(
                                size: compact ? 13 : 15, weight: .semibold, design: .rounded)
                        )
                        .foregroundStyle(StartupColors.ink)
                        .lineLimit(1)
                    Text("\(sourceLabel(camera.source)) · nearby")
                        .font(
                            .system(
                                size: compact ? 10 : 12, weight: .regular, design: .rounded)
                        )
                        .foregroundStyle(StartupColors.muted)
                        .lineLimit(1)
                }

                Spacer()

                Image(systemName: "cellularbars")
                    .font(.system(size: compact ? 16 : 20, weight: .semibold))
                    .foregroundStyle(StartupColors.accent)
            }
            .padding(.horizontal, compact ? 12 : 16)
            .frame(height: compact ? 64 : 84)
            .background(
                StartupColors.card, in: RoundedRectangle(cornerRadius: DesignTokens.cornerRadius)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.cornerRadius)
                    .stroke(
                        selected
                            ? StartupColors.accent.opacity(0.50)
                            : StartupColors.border.opacity(0.10),
                        lineWidth: selected ? 2 : 1)
            )
        }
        .buttonStyle(.zcTapTarget)
    }

    private func sourceLabel(_ source: DiscoverySource) -> String {
        switch source {
        case .bonjour, .subnetProbe: "Wi-Fi"
        case .manual: "Manual"
        case .usb: "USB-C"
        }
    }
}

struct StartupEmptyDiscoveryCard: View {
    var compact = false
    var transport: NativeAppModel.DiscoveryTransportFilter = .wiFi

    private var isUSB: Bool { transport == .usbC }

    var body: some View {
        VStack(spacing: compact ? 6 : 10) {
            Image(systemName: isUSB ? "cable.connector" : "dot.radiowaves.left.and.right")
                .font(.system(size: compact ? 18 : 24, weight: .semibold))
                .foregroundStyle(StartupColors.accent)
            Text(isUSB ? "Waiting for camera on USB-C" : "Looking for cameras")
                .font(.system(size: compact ? 13 : 15, weight: .semibold, design: .rounded))
                .foregroundStyle(StartupColors.ink)
            Text(
                isUSB
                    ? (compact
                        ? "Plug the camera into this device with a USB-C cable."
                        : "Plug the camera into this device with a USB-C cable — it appears here the moment it's detected.")
                    // The Wi‑Fi arm renders only on the wizard's Phone Hotspot discovery step
                    // (camera-AP pairing ends at connectNetwork) — so the hint must describe the
                    // hotspot direction: the CAMERA joins this phone, the phone joins nothing.
                    : (compact
                        ? "Waiting for the camera to join this phone's hotspot."
                        : "The camera appears here a few seconds after it joins this phone's hotspot.")
            )
            .font(.system(size: compact ? 10 : 12, weight: .regular, design: .rounded))
            .foregroundStyle(StartupColors.muted)
            .multilineTextAlignment(.center)
            .lineLimit(compact ? 2 : nil)
            .minimumScaleFactor(compact ? 0.85 : 1)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, compact ? 12 : 18)
        .padding(.vertical, compact ? 12 : 24)
        .background(
            StartupColors.card, in: RoundedRectangle(cornerRadius: DesignTokens.cornerRadius)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.cornerRadius).stroke(
                StartupColors.border.opacity(0.10), lineWidth: 1))
    }
}

struct StartupIconSquare: View {
    let systemName: String
    var size: CGFloat = 56
    var cornerRadius: CGFloat = DesignTokens.cornerRadius
    var tint: Color = StartupColors.accent

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(StartupColors.tile)
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

struct StartupMediaLibraryButton: View {
    @Environment(NativeAppModel.self) private var model
    var compact = false
    var disabled = false

    var body: some View {
        Group {
            if compact {
                Button {
                    model.openCachedMediaLibrary()
                } label: {
                    Label("Media Library", systemImage: "film.stack")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(StartupQuietButtonStyle())
            } else {
                Button {
                    model.openCachedMediaLibrary()
                } label: {
                    Label("Media Library", systemImage: "film.stack")
                        .frame(width: 215, alignment: .leading)
                }
                .buttonStyle(StartupOutlineButtonStyle())
            }
        }
        .disabled(disabled)
    }
}

struct StartupOutlineButtonStyle: ButtonStyle {

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .semibold, design: .rounded))
            .foregroundStyle(StartupColors.ink)
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
            .background(
                StartupColors.control.opacity(configuration.isPressed ? 0.98 : 0.82),
                in: RoundedRectangle(cornerRadius: DesignTokens.cornerRadius)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.cornerRadius).stroke(
                    StartupColors.border.opacity(0.12), lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.78 : 1)
    }
}

struct StartupFilledButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Label(configuration: configuration)
    }

    // Nested so it can read `isEnabled` — a disabled filled button must look disabled (dimmed), not
    // fully lit but unresponsive.
    private struct Label: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(StartupColors.darkText)
                .padding(.horizontal, 22)
                .padding(.vertical, 14)
                .background(
                    StartupColors.accent.opacity(configuration.isPressed ? 0.80 : 1),
                    in: RoundedRectangle(cornerRadius: DesignTokens.cornerRadius)
                )
                .opacity(isEnabled ? 1 : 0.4)
        }
    }
}

/// Compact wizard footer buttons sized to fit within the fixed footer band.
struct StartupWizardFilledButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Label(configuration: configuration)
    }

    // Nested so it can read `isEnabled` — a gated Continue (e.g. permissions step) must look
    // disabled, not stay fully accent-lit while being inert.
    private struct Label: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(isEnabled ? StartupColors.darkText : StartupColors.muted)
                .frame(maxWidth: .infinity)
                .frame(height: 40)
                .background(
                    isEnabled
                        ? StartupColors.accent.opacity(configuration.isPressed ? 0.80 : 1)
                        : StartupColors.control.opacity(0.6),
                    in: RoundedRectangle(cornerRadius: DesignTokens.cornerRadius)
                )
                .opacity(isEnabled ? 1 : 0.55)
        }
    }
}

struct StartupWizardOutlineButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold, design: .rounded))
            .foregroundStyle(StartupColors.ink)
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .background(
                StartupColors.control.opacity(configuration.isPressed ? 0.98 : 0.82),
                in: RoundedRectangle(cornerRadius: DesignTokens.cornerRadius)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.cornerRadius).stroke(
                    StartupColors.border.opacity(0.12), lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.78 : 1)
    }
}

struct StartupQuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundStyle(StartupColors.ink)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                StartupColors.control.opacity(configuration.isPressed ? 0.98 : 0.66),
                in: RoundedRectangle(cornerRadius: DesignTokens.cornerRadius)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.cornerRadius).stroke(
                    StartupColors.border.opacity(0.08), lineWidth: 1))
    }
}

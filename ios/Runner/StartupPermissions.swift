import AVFoundation
import Foundation
import Network
import SwiftUI
import UIKit
import dnssd

/// The iOS permissions the first-run connection flow needs, surfaced up front so the operator can
/// grant them deliberately (one tap each) instead of being ambushed by system prompts mid-pairing.
enum StartupPermissionKind: String, CaseIterable, Identifiable {
    case camera
    case localNetwork

    var id: String { rawValue }

    var title: String {
        switch self {
        case .camera: "Camera"
        case .localNetwork: "Local Network"
        }
    }

    var detail: String {
        switch self {
        case .camera: "Scan the Wi‑Fi details off the camera screen."
        case .localNetwork: "Find and stream from the ZR over Wi‑Fi."
        }
    }

    var systemImage: String {
        switch self {
        case .camera: "camera.fill"
        case .localNetwork: "wifi"
        }
    }
}

/// What we can tell the operator about a permission. iOS exposes a readable status for camera;
/// Local Network has no authorization API (TN3179, FB8711182), so its state comes from probing:
/// self-discovering our own published Bonjour service ⇒ `.granted`, an NWBrowser parked in
/// `.waiting(kDNSServiceErr_PolicyDenied)` ⇒ `.denied`, and `.requested` while neither signal
/// has arrived (prompt still up, or probe in flight).
enum StartupPermissionState: Equatable {
    case notDetermined
    case requested
    case granted
    case denied
}

/// Reads and requests the first-run permissions, exposing live status to the wizard step. Requests
/// fire the real system prompt; a permission already denied deep-links to Settings (iOS won't
/// re-prompt once decided).
@MainActor @Observable
final class StartupPermissionsCoordinator {
    private(set) var camera: StartupPermissionState = .notDetermined
    private(set) var localNetwork: StartupPermissionState = .notDetermined

    @ObservationIgnored private var localNetworkProbe: LocalNetworkPermissionProbe?

    /// The permissions pairing genuinely can't proceed without. Both must be *granted* — merely
    /// having fired the prompt is not enough, since the operator can answer "Don't Allow" and the
    /// wizard's Continue must stay gated in that case.
    var allRequiredGranted: Bool {
        camera == .granted && localNetwork == .granted
    }

    private static let localNetworkAcknowledgedKey = "StartupPermissions.localNetworkAcknowledged"
    /// Set on the first Local Network row tap. iOS kills the app when the Settings toggle changes,
    /// resetting the coordinator to `.notDetermined` — this flag tells `refresh()` a probe is a
    /// continuation (not an ambush) so the row updates without another tap after relaunch.
    private static let localNetworkRequestedOnceKey = "StartupPermissions.localNetworkRequestedOnce"

    @ObservationIgnored private var localNetworkReprobe: Task<Void, Never>?

    /// Whether the wizard can skip the permissions step — camera is authorized and Local Network
    /// was already acknowledged in a prior session (or the operator has paired before).
    static func permissionsAlreadySatisfied(alreadyPairedCameras: Bool) -> Bool {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { return false }
        if UserDefaults.standard.bool(forKey: localNetworkAcknowledgedKey) { return true }
        return alreadyPairedCameras
    }

    private static func persistLocalNetworkAcknowledged() {
        UserDefaults.standard.set(true, forKey: localNetworkAcknowledgedKey)
    }

    func state(for kind: StartupPermissionKind) -> StartupPermissionState {
        switch kind {
        case .camera: camera
        case .localNetwork: localNetwork
        }
    }

    /// Re-reads camera status; call on appear and on return from Settings. Local Network has no
    /// readable status, so once a request is in flight (or denied) this re-probes — silent after
    /// the prompt is answered, since iOS never re-prompts a determined permission. That picks up
    /// both the prompt's answer (the alert flips scenePhase) and a Settings toggle.
    func refresh() {
        camera = Self.map(AVCaptureDevice.authorizationStatus(for: .video))
        if UserDefaults.standard.bool(forKey: Self.localNetworkAcknowledgedKey) {
            localNetwork = .granted
        } else if localNetwork == .requested || localNetwork == .denied {
            startLocalNetworkProbe()
        } else if localNetwork == .notDetermined,
            UserDefaults.standard.bool(forKey: Self.localNetworkRequestedOnceKey)
        {
            // Row was already tapped once — iOS killed and relaunched the app on the Settings
            // toggle flip, so resume probing instead of waiting for a second tap.
            localNetwork = .requested
            startLocalNetworkProbe()
        }
    }

    func request(_ kind: StartupPermissionKind) {
        switch kind {
        case .camera: requestCamera()
        case .localNetwork: requestLocalNetwork()
        }
    }

    private func requestCamera() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .notDetermined:
            Task {
                let granted = await AVCaptureDevice.requestAccess(for: .video)
                camera = granted ? .granted : .denied
            }
        case .authorized:
            camera = .granted
        case .denied, .restricted:
            camera = .denied
            Self.openSettings()
        @unknown default:
            break
        }
    }

    private func requestLocalNetwork() {
        switch localNetwork {
        case .granted:
            return
        case .denied:
            // iOS never re-prompts a denied permission — Settings is the only way back.
            Self.openSettings()
        case .notDetermined, .requested:
            localNetwork = .requested
            UserDefaults.standard.set(true, forKey: Self.localNetworkRequestedOnceKey)
            startLocalNetworkProbe()
        }
    }

    private func startLocalNetworkProbe() {
        localNetworkReprobe?.cancel()
        localNetworkProbe = LocalNetworkPermissionProbe { [weak self] result in
            guard let self else { return }
            localNetwork = result
            if result == .granted {
                Self.persistLocalNetworkAcknowledged()
                localNetworkReprobe?.cancel()
            } else if result == .denied {
                scheduleLocalNetworkReprobe()
            }
        }
    }

    /// Re-probes a denied Local Network permission every couple of seconds. TN3179 only promises
    /// grant auto-retry for `NWConnection` — a parked `NWBrowser` that saw a (possibly stale)
    /// PolicyDenied is not guaranteed to recover on its own, so a Settings grant could otherwise
    /// go unnoticed until the operator left and re-entered the step. Denied probes are free (the
    /// OS blocks the multicast locally); the loop dies with the coordinator or on grant.
    private func scheduleLocalNetworkReprobe() {
        localNetworkReprobe?.cancel()
        localNetworkReprobe = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self, self.localNetwork == .denied else { return }
            self.startLocalNetworkProbe()
        }
    }

    private static func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private static func map(_ status: AVAuthorizationStatus) -> StartupPermissionState {
        switch status {
        case .authorized: .granted
        case .denied, .restricted: .denied
        case .notDetermined: .notDetermined
        @unknown default: .notDetermined
        }
    }
}

/// Fires the iOS Local Network prompt and detects the answer using the only signals Apple
/// sanctions (TN3179 — there is no status API, FB8711182):
///
/// - **Prompt trigger**: a `NetServiceBrowser` browse for the camera's PTP service (an `NWBrowser`
///   alone didn't fire the prompt on device). Its delegate callbacks carry no permission signal —
///   `willSearch` fires before the answer, denial is silent — so none are wired.
/// - **Granted**: self-discovering our own Bonjour beacon (`_ozcprobe._tcp`) via `NWBrowser` —
///   any result means our multicast went through.
/// - **Denied**: the same `NWBrowser` parks in `.waiting(kDNSServiceErr_PolicyDenied)`. Parked is
///   NOT terminal — Network framework auto-retries a waiting browse after a Settings grant, so
///   report denied but keep the browse alive; cancelling on denial left the step stuck at denied
///   because a fresh probe could still see the stale PolicyDenied.
///
/// Until a signal arrives the state stays `.requested`, keeping Continue gated — the fail-safe.
@MainActor
private final class LocalNetworkPermissionProbe: NSObject {
    /// Dedicated probe type — published and browsed only by this class, so a hit can't collide
    /// with real camera discovery. Must stay listed in Info.plist `NSBonjourServices`.
    static let beaconType = "_ozcprobe._tcp"

    private let prompt = NetServiceBrowser()
    private let beacon: NetService
    private let detector: NWBrowser
    private let onResult: @MainActor (StartupPermissionState) -> Void
    private var reported = false

    init(onResult: @escaping @MainActor (StartupPermissionState) -> Void) {
        self.onResult = onResult
        // The port is never connected to — the beacon exists only to be discovered.
        beacon = NetService(
            domain: "local.", type: Self.beaconType + ".", name: "OpenZCine", port: 61735)
        detector = NWBrowser(
            for: .bonjour(type: Self.beaconType, domain: nil),
            using: NWParameters()
        )
        super.init()

        prompt.searchForServices(ofType: "_ptp._tcp.", inDomain: "local.")
        beacon.publish()

        detector.stateUpdateHandler = { [weak self] state in
            guard case .waiting(let error) = state,
                error == .dns(DNSServiceErrorType(kDNSServiceErr_PolicyDenied))
            else { return }
            // Waiting means parked, not failed: keep the browse running so a later grant in
            // Settings auto-retries it and the granted signal below still fires.
            MainActor.assumeIsolated { self?.reportDenied() }
        }
        detector.browseResultsChangedHandler = { [weak self] results, _ in
            guard !results.isEmpty else { return }
            MainActor.assumeIsolated { self?.reportGranted() }
        }
        detector.start(queue: .main)
    }

    private func reportDenied() {
        guard !reported else { return }
        onResult(.denied)
    }

    private func reportGranted() {
        guard !reported else { return }
        reported = true
        onResult(.granted)
        prompt.stop()
        beacon.stop()
        detector.cancel()
    }
}

// MARK: - Wizard step view

/// First-run wizard step (step 1 of 5): lists the permissions pairing needs and lets the operator
/// grant each with a single tap. Blocking — the shell's Continue stays disabled until the required
/// permissions are granted (see `allRequiredGranted`), since the camera can't be reached without them.
struct StartupWizardPermissionsStep: View {
    let coordinator: StartupPermissionsCoordinator
    let style: WizardCompactStyle
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "lock.shield")
                        .font(.system(size: style.isTight ? 12 : 14, weight: .semibold))
                        .foregroundStyle(StartupColors.accent)
                    Text("iOS permissions")
                        .font(
                            .system(
                                size: style.isTight ? 10 : 11, weight: .semibold, design: .rounded)
                        )
                        .foregroundStyle(StartupColors.muted)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, style.isTight ? 12 : 14)
                .padding(.top, style.isTight ? 10 : 12)
                .padding(.bottom, style.isTight ? 6 : 8)

                ForEach(Array(StartupPermissionKind.allCases.enumerated()), id: \.element.id) {
                    index, kind in
                    if index > 0 {
                        Rectangle()
                            .fill(StartupColors.border.opacity(0.10))
                            .frame(height: 1)
                            .padding(.leading, style.isTight ? 42 : 48)
                    }
                    StartupPermissionRow(
                        kind: kind,
                        state: coordinator.state(for: kind),
                        style: style
                    ) {
                        coordinator.request(kind)
                    }
                }
            }
            .background(
                StartupColors.card, in: RoundedRectangle(cornerRadius: DesignTokens.cornerRadius)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.cornerRadius)
                    .stroke(StartupColors.border.opacity(0.12), lineWidth: 1)
            )

            if !coordinator.allRequiredGranted {
                Text("Both are required to connect to your camera — grant them to continue.")
                    .font(
                        .system(size: style.isTight ? 11 : 12, weight: .regular, design: .rounded)
                    )
                    .foregroundStyle(StartupColors.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { coordinator.refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { coordinator.refresh() }
        }
    }
}

private struct StartupPermissionRow: View {
    let kind: StartupPermissionKind
    let state: StartupPermissionState
    let style: WizardCompactStyle
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .center, spacing: style.isTight ? 8 : 10) {
                Image(systemName: kind.systemImage)
                    .font(.system(size: style.isTight ? 14 : 16, weight: .semibold))
                    .foregroundStyle(StartupColors.accent)
                    .frame(width: style.isTight ? 30 : 34, height: style.isTight ? 30 : 34)
                    .background(StartupColors.accent.opacity(0.14), in: Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text(kind.title)
                        .font(
                            .system(
                                size: style.checklistFontSize + 2, weight: .semibold,
                                design: .rounded)
                        )
                        .foregroundStyle(StartupColors.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(kind.detail)
                        .font(
                            .system(
                                size: style.checklistDetailFontSize + 1, weight: .regular,
                                design: .rounded)
                        )
                        .foregroundStyle(StartupColors.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                statusControl
            }
            .padding(.horizontal, style.isTight ? 14 : 16)
            .padding(.vertical, style.isTight ? 11 : 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var statusControl: some View {
        switch state {
        case .granted:
            pill(
                text: "Allowed", systemImage: "checkmark", fill: StartupColors.ready.opacity(0.16),
                stroke: StartupColors.ready.opacity(0.5), textColor: StartupColors.ready)
        case .denied:
            pill(
                text: "Settings", systemImage: "gearshape.fill",
                fill: StartupColors.control.opacity(0.6),
                stroke: StartupColors.border.opacity(0.12), textColor: StartupColors.muted)
        case .requested:
            pill(
                text: "Requested", systemImage: nil, fill: StartupColors.control.opacity(0.6),
                stroke: StartupColors.border.opacity(0.12), textColor: StartupColors.muted)
        case .notDetermined:
            pill(
                text: "Allow", systemImage: nil, fill: StartupColors.accent,
                stroke: .clear, textColor: StartupColors.darkText)
        }
    }

    private func pill(
        text: String, systemImage: String?, fill: Color, stroke: Color, textColor: Color
    ) -> some View {
        HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .bold))
            }
            Text(text)
                .font(.system(size: style.isTight ? 14 : 15, weight: .semibold, design: .rounded))
        }
        .foregroundStyle(textColor)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(fill, in: Capsule())
        .overlay(Capsule().stroke(stroke, lineWidth: 1))
        .fixedSize()
    }
}

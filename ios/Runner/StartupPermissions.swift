import Foundation
import MonitorUI
import OpenCineApple
import OpenCineCore
import OpenZCineCore
import SwiftUI
import UIKit

/// The iOS permission the wireless first-pair paths need, surfaced right after the path is chosen
/// so the operator can grant it deliberately instead of being ambushed by a system prompt
/// mid-pairing. Cable paths ask nothing here: USB keeps its own camera-control request and HDMI
/// capture its own video request. The phone camera is not a pairing requirement either: only the
/// optional credential scanner uses it, iOS asks at that moment, and manual entry always works.
enum StartupPermissionKind: String, CaseIterable, Identifiable {
    case localNetwork

    var id: String { rawValue }

    var title: String {
        switch self {
        case .localNetwork: "Local Network"
        }
    }

    var detail: String {
        switch self {
        case .localNetwork: "Find and stream from your camera over Wi‑Fi."
        }
    }

    var systemImage: String {
        switch self {
        case .localNetwork: "wifi"
        }
    }
}

/// The app's one Local Network observer (TN3179), as Pocket and Insta keep theirs: the permission
/// belongs to the app, not to a wizard step or a camera session. It holds OpenCine's
/// `LocalNetworkPrivacy` (probe lifetime and evidence rule), records each new answer as a closed
/// diagnostic event, remembers a grant across launches, and takes evidence from a camera link
/// that completed over the network. The first-pair wizard step drives its probe.
@MainActor @Observable
final class LocalNetworkAccess {
    static let shared = LocalNetworkAccess()

    /// The existing probe: a `NetServiceBrowser` browse for the camera's PTP service fires the
    /// prompt (an `NWBrowser` alone didn't on device), and self-discovering our own beacon type
    /// grants. The type must stay listed in Info.plist `NSBonjourServices`.
    static let probe = LocalNetworkPrivacy.Probe(
        browseType: "_ozcprobe._tcp", resultsGrant: true,
        beacon: .init(name: "OpenZCine", port: 61735), promptTrigger: "_ptp._tcp.")

    private static let acknowledgedKey = "StartupPermissions.localNetworkAcknowledged"

    /// The latest evidence; `requested` while a probe has no answer yet.
    private(set) var state: CameraNetworkPermissionState = .unknown
    /// The last explicit answer. A re-probe's `requested` never hides it.
    private(set) var answer: CameraNetworkPermissionState?
    /// A grant seen in this or an earlier launch: a remembered answer, not fresh OS evidence.
    private(set) var acknowledged: Bool

    /// What diagnostics report: the last answer, else the current evidence.
    var reported: CameraNetworkPermissionState { answer ?? state }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let record: (AppDiagnosticEvent) -> Void
    @ObservationIgnored private lazy var privacy = LocalNetworkPrivacy { [weak self] state, _ in
        self?.receive(state)
    }
    @ObservationIgnored private var reprobe: Task<Void, Never>?
    /// The wizard step shows the permission: a denial keeps re-probing while it does.
    @ObservationIgnored private var probing = false

    init(
        defaults: UserDefaults = .standard,
        record: @escaping (AppDiagnosticEvent) -> Void = { AppDiagnostics.shared.record($0) }
    ) {
        self.defaults = defaults
        self.record = record
        acknowledged = defaults.bool(forKey: Self.acknowledgedKey)
    }

    /// Starts (or restarts) the probe for the wizard step; the shared observer stops the previous
    /// one first.
    func startProbing() {
        probing = true
        reprobe?.cancel()
        privacy.start(Self.probe)
    }

    /// Ends the probe, its beacon and any pending re-probe when the step goes away.
    func stopProbing() {
        probing = false
        reprobe?.cancel()
        reprobe = nil
        privacy.stop()
    }

    /// Evidence from a camera operation whose own guard already rejected retired attempts.
    func note(_ evidence: CameraNetworkPermissionEvidence, source: String) {
        privacy.note(evidence, source: source)
    }

    /// A camera link that completed over the network proves access; USB proves nothing.
    nonisolated static func evidence(
        connected: Bool, transport: CameraTransportKind?
    ) -> CameraNetworkPermissionEvidence? {
        connected && transport == .ptpIP ? .operationSucceeded : nil
    }

    private func receive(_ next: CameraNetworkPermissionState) {
        let before = reported
        state = next
        switch next {
        case .allowed:
            answer = .allowed
            reprobe?.cancel()
            privacy.stop()
            if !acknowledged {
                acknowledged = true
                defaults.set(true, forKey: Self.acknowledgedKey)
            }
        case .denied:
            answer = .denied
            scheduleReprobe()
        case .unknown, .requested:
            break
        }
        // One event per new answer: a re-probe of a denial is not news.
        if reported != before, let event = AppDiagnosticEvent(localNetwork: reported) {
            record(event)
        }
    }

    /// Re-probes a denied Local Network permission every couple of seconds while the step shows.
    /// TN3179 only promises grant auto-retry for `NWConnection`; a parked `NWBrowser` that saw a
    /// (possibly stale) PolicyDenied is not guaranteed to recover on its own, so a Settings grant
    /// could otherwise go unnoticed until the operator left and re-entered the step. Denied probes
    /// are free (the OS blocks the multicast locally); the loop ends with the step or on grant.
    private func scheduleReprobe() {
        guard probing else { return }
        reprobe?.cancel()
        reprobe = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self, self.probing, self.answer == .denied else { return }
            self.privacy.start(Self.probe)
        }
    }
}

/// The first-pair step's view of the app's Local Network owner. A request fires the real system
/// prompt; a permission already denied deep-links to Settings (iOS won't re-prompt once decided).
@MainActor @Observable
final class StartupPermissionsCoordinator {
    @ObservationIgnored private let access: LocalNetworkAccess
    @ObservationIgnored private let defaults: UserDefaults
    /// The row was tapped (or a probe resumed) and no answer has arrived yet.
    private var requested = false

    init(access: LocalNetworkAccess = .shared, defaults: UserDefaults = .standard) {
        self.access = access
        self.defaults = defaults
    }

    /// What the row shows: a remembered grant, else the owner's last answer, else whether the
    /// prompt was asked for. Local Network has no authorization API (TN3179, FB8711182): an
    /// unanswered probe is `requested`, never `denied`.
    var localNetwork: CameraNetworkPermissionState {
        Self.shownState(
            acknowledged: access.acknowledged, answer: access.answer, requested: requested)
    }

    /// Pairing can't proceed over Wi‑Fi without Local Network access, and merely having fired
    /// the prompt is not enough: the operator can answer "Don't Allow".
    var allRequiredGranted: Bool { localNetwork == .allowed }

    nonisolated static func shownState(
        acknowledged: Bool, answer: CameraNetworkPermissionState?, requested: Bool
    ) -> CameraNetworkPermissionState {
        if acknowledged { return .allowed }
        if let answer { return answer }
        return requested ? .requested : .unknown
    }

    /// Set on the first Local Network row tap. iOS kills the app when the Settings toggle changes,
    /// resetting the step; this flag tells `refresh()` a probe is a continuation (not an ambush)
    /// so the row updates without another tap after relaunch.
    private static let localNetworkRequestedOnceKey = "StartupPermissions.localNetworkRequestedOnce"

    /// Whether the wizard can skip the permissions step: Local Network was acknowledged (in this
    /// or a prior session), or the operator has paired before.
    static func permissionsAlreadySatisfied(
        alreadyPairedCameras: Bool, access: LocalNetworkAccess = .shared
    ) -> Bool {
        access.acknowledged || alreadyPairedCameras
    }

    func state(for kind: StartupPermissionKind) -> CameraNetworkPermissionState {
        switch kind {
        case .localNetwork: localNetwork
        }
    }

    /// Call on appear and on return from Settings. Local Network has no readable status, so once
    /// a request is in flight (or denied) this re-probes: silent after the prompt is answered,
    /// since iOS never re-prompts a determined permission. That picks up both the prompt's answer
    /// (the alert flips scenePhase) and a Settings toggle.
    func refresh() {
        switch localNetwork {
        case .allowed:
            return
        case .requested, .denied:
            access.startProbing()
        case .unknown:
            // Row was already tapped once: iOS killed and relaunched the app on the Settings
            // toggle flip, so resume probing instead of waiting for a second tap.
            guard defaults.bool(forKey: Self.localNetworkRequestedOnceKey) else { return }
            requested = true
            access.startProbing()
        }
    }

    func request(_ kind: StartupPermissionKind) {
        switch kind {
        case .localNetwork: requestLocalNetwork()
        }
    }

    /// Ends the probe, its beacon and any pending re-probe when the step goes away.
    func stop() {
        access.stopProbing()
    }

    private func requestLocalNetwork() {
        switch localNetwork {
        case .allowed:
            return
        case .denied:
            // iOS never re-prompts a denied permission; Settings is the only way back.
            Self.openSettings()
        case .unknown, .requested:
            requested = true
            defaults.set(true, forKey: Self.localNetworkRequestedOnceKey)
            access.startProbing()
        }
    }

    private static func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

// MARK: - Wizard step view

/// Wireless first-pair step, right after the path is chosen: lists the permission the path needs
/// and lets the operator grant it with a single tap. Blocking: the shell's Continue stays disabled
/// until it is granted (see `allRequiredGranted`), since the camera can't be reached without it.
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
                        .foregroundStyle(MonitorTheme.accent)
                    Text("iOS permissions")
                        .font(
                            .system(
                                size: style.isTight ? 10 : 11, weight: .semibold, design: .rounded)
                        )
                        .foregroundStyle(MonitorTheme.muted)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, style.isTight ? 12 : 14)
                .padding(.top, style.isTight ? 10 : 12)
                .padding(.bottom, style.isTight ? 6 : 8)

                ForEach(Array(StartupPermissionKind.allCases.enumerated()), id: \.element.id) {
                    index, kind in
                    if index > 0 {
                        Rectangle()
                            .fill(Color.white.opacity(0.10))
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
                MonitorTheme.surface, in: RoundedRectangle(cornerRadius: MonitorTheme.radius)
            )
            .overlay(
                RoundedRectangle(cornerRadius: MonitorTheme.radius)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )

            if !coordinator.allRequiredGranted {
                Text("Required to reach your camera over Wi‑Fi. Allow it to continue.")
                    .font(
                        .system(size: style.isTight ? 11 : 12, weight: .regular, design: .rounded)
                    )
                    .foregroundStyle(MonitorTheme.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { coordinator.refresh() }
        .onDisappear { coordinator.stop() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { coordinator.refresh() }
        }
    }
}

private struct StartupPermissionRow: View {
    let kind: StartupPermissionKind
    let state: CameraNetworkPermissionState
    let style: WizardCompactStyle
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .center, spacing: style.isTight ? 8 : 10) {
                Image(systemName: kind.systemImage)
                    .font(.system(size: style.isTight ? 14 : 16, weight: .semibold))
                    .foregroundStyle(MonitorTheme.accent)
                    .frame(width: style.isTight ? 30 : 34, height: style.isTight ? 30 : 34)
                    .background(MonitorTheme.accent.opacity(0.14), in: Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text(kind.title)
                        .font(
                            .system(
                                size: style.checklistFontSize + 2, weight: .semibold,
                                design: .rounded)
                        )
                        .foregroundStyle(MonitorTheme.text)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(kind.detail)
                        .font(
                            .system(
                                size: style.checklistDetailFontSize + 1, weight: .regular,
                                design: .rounded)
                        )
                        .foregroundStyle(MonitorTheme.muted)
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
        case .allowed:
            pill(
                text: "Allowed", systemImage: "checkmark",
                fill: MonitorTheme.linkHealthColor(.stable).opacity(0.16),
                stroke: MonitorTheme.linkHealthColor(.stable).opacity(0.5),
                textColor: MonitorTheme.linkHealthColor(.stable))
        case .denied:
            pill(
                text: "Settings", systemImage: "gearshape.fill",
                fill: MonitorTheme.raised.opacity(0.6),
                stroke: Color.white.opacity(0.12), textColor: MonitorTheme.muted)
        case .requested:
            pill(
                text: "Requested", systemImage: nil, fill: MonitorTheme.raised.opacity(0.6),
                stroke: Color.white.opacity(0.12), textColor: MonitorTheme.muted)
        case .unknown:
            pill(
                text: "Allow", systemImage: nil, fill: MonitorTheme.accent,
                stroke: .clear, textColor: MonitorTheme.onAccent)
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

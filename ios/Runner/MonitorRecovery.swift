import SwiftUI

/// Recovery affordance shown over a **held** live-view frame after an established session dropped.
///
/// The operator stays in the monitor — a knocked cable or a camera power cycle should not throw a
/// shoot back to the connect screen — but the frame behind this is the last one received, not live,
/// so it is dimmed and the chrome's frame-rate readout reads `NO LINK`. Two ways out, per the
/// shared `SessionRecoveryState`: retry here, or leave for the operator menu.
///
/// Deliberately built from the monitor's own chrome idiom (`LiveDesign` palette, `liquidGlass`,
/// `DesignTokens.cornerRadius`, `minTapTarget`) rather than a system alert: alerts are portrait-
/// biased and this app is a ~400pt-tall landscape monitor.
struct MonitorRecoveryOverlay: View {
    @Environment(NativeAppModel.self) private var model

    /// The first automatic retry fires immediately and usually heals a blip within a second
    /// or two — flashing the full card + dimmed backdrop for that was the "retry prompt for
    /// like a sec". The card waits out a short grace on attempt 1; a second attempt or the
    /// give-up state is a real outage and shows at once. The grace timer is MODEL state:
    /// this view renders nothing until the card shows, and SwiftUI does not run `.task` on
    /// content-less views — a view-side timer here could never fire, so a stalled attempt 1
    /// was a permanent RECOV chip with no card and no way out.
    private func showsCard(_ state: SessionRecoveryState) -> Bool {
        guard state.isRecovering else { return false }
        if model.isDemoSession { return true }
        if case .retrying(let attempt, _) = state, attempt <= 1 {
            return model.sessionRecoveryCardGraceElapsed
        }
        return true
    }

    var body: some View {
        recoveryBody(model.sessionRecovery)
    }

    @ViewBuilder private func recoveryBody(_ state: SessionRecoveryState) -> some View {
        if showsCard(state) {
            ZStack {
                // Reads as "this image is frozen" at a glance. Non-interactive so the chrome
                // underneath stays reachable — the operator may still want Settings or Media.
                Color.black.opacity(0.34)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)

                card(state: state)
                    .frame(maxWidth: 460)
                    .padding(.horizontal, 24)
            }
            .transition(.opacity)
        }
    }

    private func card(state: SessionRecoveryState) -> some View {
        VStack(spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                statusIcon(state: state)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 3) {
                    Text(SessionRecoveryCopy.title(state))
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(LiveDesign.text)
                    Text(
                        SessionRecoveryCopy.detail(
                            state, deviceName: model.connectionProgressDeviceName)
                    )
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(LiveDesign.muted)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 10) {
                actionButton(
                    title: "Retry connection",
                    systemImage: "arrow.clockwise",
                    tint: LiveDesign.accent
                ) {
                    model.retrySessionRecovery()
                }
                actionButton(
                    title: "Operator menu",
                    systemImage: "chevron.backward",
                    tint: nil
                ) {
                    model.exitMonitorToOperatorMenu()
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .liquidGlass(
            in: RoundedRectangle(cornerRadius: DesignTokens.cornerRadius, style: .continuous)
        )
        .shadow(color: .black.opacity(0.35), radius: 22, y: 10)
    }

    @ViewBuilder private func statusIcon(state: SessionRecoveryState) -> some View {
        switch state {
        case .retrying:
            ProgressView()
                .controlSize(.small)
                .tint(LiveDesign.accent)
        case .waitingForOperator, .idle:
            Image(systemName: "cable.connector.slash")
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(LiveDesign.accent)
        }
    }

    private func actionButton(
        title: String,
        systemImage: String,
        tint: Color?,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(tint == nil ? LiveDesign.text : Color.black)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity)
                .liquidGlass(in: Capsule(), tint: tint, interactive: true)
                .minTapTarget()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

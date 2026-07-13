import SwiftUI

/// Connection progress sheet: one centered light card for every flow (scanned camera-AP join,
/// saved-camera reconnect, USB) and every phase — confirm → join → discover → pair → connect →
/// live view. Styled to match ``CameraWiFiScannerScreen`` so the whole connection journey reads
/// as a single visual language; only the middle content swaps per phase.
struct ConnectionProgressSheet: View {
    @Environment(NativeAppModel.self) private var model

    private let cardCornerRadius: CGFloat = 24
    private let cardMaxWidth: CGFloat = 360

    var body: some View {
        ZStack {
            backdrop

            card
                .frame(maxWidth: cardMaxWidth)
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .interactiveDismissDisabled(phase != .failed)
        .presentationBackground(.clear)
    }

    private var phase: CameraConnectionPhase {
        model.resolvedConnectionPhase
    }

    private var deviceName: String {
        model.connectionProgressDeviceName
    }

    private var statusLabel: String {
        ConnectionProgressCopy.statusTitle(phase: phase, isUSB: model.connectionProgressIsUSB)
    }

    /// Failure text pinned at surfacing time (`connectionFailureDetail`) — the live
    /// `connectionMessage` keeps being overwritten by the discovery loop, so reading it here
    /// showed stale copy like "Found 1 camera." on the failed card.
    private var failureDetail: String {
        if !model.connectionFailureDetail.isEmpty {
            return model.connectionFailureDetail
        }
        return ConnectionProgressCopy.statusDetail(
            phase: .failed,
            deviceName: deviceName,
            friendlyError: nil
        )
    }

    private var backdrop: some View {
        // The credential scanner's backdrop: a blurred pass over the app with a faint dim that
        // lifts the light card off the (often bright) content behind it.
        Rectangle()
            .fill(.regularMaterial)
            .overlay(Color.black.opacity(0.12))
            .ignoresSafeArea()
    }

    private var card: some View {
        VStack(spacing: 16) {
            VStack(spacing: 8) {
                Text(deviceName)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)

                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)

            phaseContent
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(
            Color(.systemBackground),
            in: RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
        )
        .shadow(color: .black.opacity(0.22), radius: 30, y: 14)
        // Force the light surface + dark-on-white content of the scanner regardless of the app's
        // (typically dark) appearance, so the two screens are visually identical.
        .environment(\.colorScheme, .light)
    }

    private var detail: String {
        if phase == .failed { return failureDetail }
        return ConnectionProgressCopy.statusDetail(
            phase: phase,
            deviceName: deviceName,
            friendlyError: nil
        )
    }

    /// Phase-specific middle of the card: credentials + Connect while ready, a progress row
    /// while joining/discovering/pairing/connecting, and a result row once connected or failed.
    @ViewBuilder private var phaseContent: some View {
        switch phase {
        case .readyToJoin:
            joinActions
            cancelButton
        case .connected:
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color(.systemGreen))
                Text(statusLabel)
                    .foregroundStyle(.primary)
            }
            .font(.body)
        case .failed:
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(Color(.systemRed))
                Text(statusLabel)
                    .foregroundStyle(.primary)
            }
            .font(.body)
            cancelButton
        default:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(statusLabel)
                    .foregroundStyle(.secondary)
            }
            .font(.body)
            cancelButton
        }
    }

    /// First-time credential entry (scan or scanned-key confirm) plus the Connect action.
    @ViewBuilder
    private var joinActions: some View {
        VStack(spacing: 12) {
            if model.cameraWiFiJoinNeedsPassword, !model.cameraWiFiJoinKeyFromScan {
                // First-time connect: scanning the camera's SSID + key is the sole path.
                Button {
                    model.presentCameraWiFiScanner()
                } label: {
                    Label("Scan SSID & key", systemImage: "text.viewfinder")
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Text("Point at your camera's Connection wizard screen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                if model.cameraWiFiJoinKeyFromScan {
                    // Scanned key: shown read-only so a stray tap can't clear or mangle it.
                    // If the OCR misread, Cancel and rescan — there's no manual edit path.
                    Text(model.cameraWiFiJoinPasswordDraft)
                        .font(.body.monospaced())
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(
                            Color(.secondarySystemBackground),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                    Text("Scanned from camera screen — check it matches.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                connectButton
            }
        }
    }

    private var connectButton: some View {
        Button {
            model.confirmCameraWiFiJoin()
        } label: {
            Text("Connect")
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }

    /// Cancel styled like the scanner's: a large bordered secondary action inside the card.
    private var cancelButton: some View {
        Button(role: .cancel) {
            model.cancelConnectionAttempt()
        } label: {
            Text(phase == .failed ? "Close" : "Cancel")
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .accessibilityHint(
            phase == .failed
                ? "Dismisses this connection attempt"
                : "Cancels connecting to this camera")
    }
}

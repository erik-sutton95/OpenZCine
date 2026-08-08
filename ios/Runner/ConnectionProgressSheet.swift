import SwiftUI

/// Connection progress sheet: one centered light card for every flow (scanned camera-AP join,
/// saved-camera reconnect, USB) and every phase — confirm → join → discover → pair → connect →
/// live view. Styled to match ``CameraWiFiScannerScreen`` so the whole connection journey reads
/// as a single visual language; only the middle content swaps per phase.
struct ConnectionProgressSheet: View {
    @Environment(NativeAppModel.self) private var model

    private let cardCornerRadius: CGFloat = 24
    private let cardMaxWidth: CGFloat = 360

    @State private var isPreparingDiagnostics = false
    @State private var diagnosticsShareItem: DiagnosticsShareItem?
    @State private var diagnosticsErrorMessage: String?

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
        .sheet(item: $diagnosticsShareItem) { item in
            DiagnosticsShareSheet(url: item.url)
        }
        .alert(
            "Couldn’t Share Diagnostics",
            isPresented: Binding(
                get: { diagnosticsErrorMessage != nil },
                set: { if !$0 { diagnosticsErrorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(diagnosticsErrorMessage ?? "Please try again.")
        }
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
        // Live establishment step (safe to read, unlike `connectionMessage` — only the connect
        // machinery writes it): real progress ("Reading the camera's card… 40%") beats a static
        // phase title while a step is grinding.
        let stage = model.connectionStageDetail
        if !stage.isEmpty, phase != .connected, phase != .readyToJoin {
            return stage
        }
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
            // Retry in place. The failed attempt disposed everything an explicit cancel would, so
            // this is the same connect the operator used to have to get by cancelling and tapping
            // the camera again (#264) — the workaround, promoted to a button.
            Button {
                model.retryConnectionAttempt()
            } label: {
                Text("Try again")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityHint("Retries connecting to this camera")
            Button {
                prepareDiagnosticsReport()
            } label: {
                Text(isPreparingDiagnostics ? "Preparing…" : "Share diagnostics")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(isPreparingDiagnostics)
            .accessibilityLabel("Share diagnostics")
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
        @Bindable var model = model
        return VStack(spacing: 12) {
            if model.cameraWiFiJoinNeedsPassword, !model.cameraWiFiJoinHasPasswordDraft {
                // First-time connect: scan the camera screen, with manual entry available there.
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
                    // EDITABLE, and it used to be a read-only `Text` — "so a stray tap can't
                    // clear or mangle it", which protected the wrong thing. OCR misreads a
                    // character now and then (0/O, 1/l, 5/S, 8/B are the whole story), and the
                    // caption asks the operator to check it matches while giving them no way to
                    // act when it does not: a field report is someone who could SEE the wrong
                    // character and could only cancel or connect with a key they knew was wrong.
                    //
                    // The original worry is answered by the field's own behaviour rather than by
                    // refusing input — a `TextField` seeded with the scan keeps its text until
                    // someone deliberately edits it, and nothing here clears on focus.
                    // BOTH fields, because one OCR pass produced both and either can misread.
                    // A wrong key is refused by the network; a wrong name simply never appears,
                    // which reads as "the camera isn't there" and is the harder of the two to
                    // diagnose from the outside.
                    scannedField(
                        title: "Network",
                        text: $model.cameraWiFiJoinSSIDDraft,
                        accessibilityLabel: "Camera Wi-Fi network name")
                    scannedField(
                        title: "Key",
                        text: $model.cameraWiFiJoinPasswordDraft,
                        accessibilityLabel: "Camera Wi-Fi key")
                    Text("Scanned from the camera screen — tap to fix anything that misread.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if model.cameraWiFiJoinHasPasswordDraft {
                    Text("Wi-Fi details entered manually — connect when they match the camera.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                connectButton
            }
        }
    }

    /// One corrected-scan field: a label above the value, so two of them read as a pair rather
    /// than as two anonymous boxes.
    private func scannedField(
        title: String, text: Binding<String>, accessibilityLabel: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            TextField(title, text: text)
                .font(.body.monospaced())
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    Color(.secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
                .accessibilityLabel(accessibilityLabel)
                .accessibilityHint("Scanned from the camera screen. Edit it if it misread.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

    private func prepareDiagnosticsReport() {
        guard !isPreparingDiagnostics else { return }
        isPreparingDiagnostics = true
        Task {
            defer { isPreparingDiagnostics = false }
            do {
                diagnosticsShareItem = DiagnosticsShareItem(
                    url: try await AppDiagnostics.shared.makeReport())
            } catch {
                diagnosticsErrorMessage = error.localizedDescription
            }
        }
    }
}

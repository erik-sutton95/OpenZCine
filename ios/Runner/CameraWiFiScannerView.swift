import SwiftUI
import VisionKit

/// Apple-native modal that reads the camera's on-screen Connection wizard (SSID + Key) with the
/// phone's rear camera and hands validated credentials back to the connect popup. VisionKit does
/// the OCR; ``CameraWiFiScreenParser`` validates and self-corrects. A live viewfinder window is
/// embedded in the card so the operator can frame the camera's wizard screen. Manual entry remains
/// available when glare, localization, or a future camera SSID format prevents automatic capture.
struct CameraWiFiScannerScreen: View {
    let onCapture: (CameraWiFiScreenParser.Credentials) -> Void
    let onManualEntry: (CameraWiFiScreenParser.Credentials) -> Void
    let onCancel: () -> Void

    @State private var showsManualEntry: Bool
    @State private var manualSSID = ""
    @State private var manualKey = ""
    @State private var manualSubmissionAttempted = false
    @State private var scanIssue: CameraWiFiScreenParser.Result?

    private let cardCornerRadius: CGFloat = 24
    private let cardMaxWidth: CGFloat = 360

    init(
        onCapture: @escaping (CameraWiFiScreenParser.Credentials) -> Void,
        onManualEntry: @escaping (CameraWiFiScreenParser.Credentials) -> Void,
        onCancel: @escaping () -> Void,
        startsInManualEntry: Bool = false
    ) {
        self.onCapture = onCapture
        self.onManualEntry = onManualEntry
        self.onCancel = onCancel
        _showsManualEntry = State(initialValue: startsInManualEntry)
    }

    var body: some View {
        GeometryReader { proxy in
            // The viewfinder is the flexible element in the vertical stack. Cap its height so the
            // whole card (title + instruction + viewfinder + actions) fits within the short,
            // ~402pt landscape canvas with comfortable margins and no clipping. Recognition help
            // borrows height from the viewfinder rather than growing the card past an edge.
            let fixedHeight: CGFloat = scanIssueMessage == nil ? 232 : 280
            let viewfinderMaxHeight = max(112, min(240, proxy.size.height - fixedHeight))

            ZStack {
                // Transparent full-screen tap target for dismiss. The *visible* blur backdrop is
                // rendered by the presenter (LinkExperience) so it fades in place instead of
                // sliding up with this cover — only the card should ride the cover's slide.
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onCancel)

                card(viewfinderMaxHeight: viewfinderMaxHeight)
                    .frame(maxWidth: cardMaxWidth)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // Clear so the presenter's blurred backdrop shows through around the card, and so only the
        // card (not the backdrop) rides the cover's built-in slide transition.
        .presentationBackground(.clear)
    }

    @ViewBuilder
    private func card(viewfinderMaxHeight: CGFloat) -> some View {
        VStack(spacing: 16) {
            header
            if showsManualEntry {
                manualEntryForm
            } else {
                viewfinder
                    .frame(maxHeight: viewfinderMaxHeight)
                if let scanIssueMessage {
                    Text(scanIssueMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                scanActions
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(
            Color(.systemBackground),
            in: RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
        )
        .shadow(color: .black.opacity(0.22), radius: 30, y: 14)
        // Force the light surface + dark-on-white content of the reference regardless of the
        // app's (typically dark) field appearance.
        .environment(\.colorScheme, .light)
    }

    private var header: some View {
        VStack(spacing: 8) {
            Text(showsManualEntry ? "Enter Wi‑Fi Details" : "Scan Wi‑Fi Details")
                .font(.title3.weight(.bold))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)

            Text(headerDetail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }

    private var headerDetail: String {
        if showsManualEntry {
            return "Copy the SSID and key exactly as they appear on the camera screen."
        }
        return "Point your phone at the camera's Connection wizard screen showing the SSID and key."
    }

    /// Rounded viewfinder window holding the live scan feed (or a placeholder when unsupported).
    private var viewfinder: some View {
        ZStack {
            if DataScannerViewController.isSupported {
                CameraWiFiScannerRepresentable(
                    onCapture: onCapture,
                    onIssue: { scanIssue = $0 }
                )
            } else {
                unsupportedPlaceholder
            }
        }
        .aspectRatio(4.0 / 3.0, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.cornerRadius, style: .continuous)
                .strokeBorder(Color.black.opacity(0.12), lineWidth: 1)
        )
    }

    private var scanIssueMessage: String? {
        switch scanIssue {
        case .needsKey:
            "SSID found. Keep the key in frame, or enter both details manually."
        case .unsupportedSSID:
            "Camera text found, but this SSID format wasn't recognized. Enter it manually."
        case .credentials, .noCredentials, nil:
            nil
        }
    }

    private var unsupportedPlaceholder: some View {
        ZStack {
            Color.black
            VStack(spacing: 8) {
                Image(systemName: "camera.viewfinder")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(.white.opacity(0.7))
                    .accessibilityLabel("Camera viewfinder")
                Text("Camera unavailable")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .padding(16)
        }
    }

    private var scanActions: some View {
        HStack(spacing: 12) {
            Button("Enter manually") {
                showsManualEntry = true
            }
            .accessibilityHint("Opens fields for the camera network name and key")

            Button("Cancel", role: .cancel, action: onCancel)
                .accessibilityHint("Closes the scanner without joining")
        }
        .font(.body.weight(.semibold))
        .buttonStyle(.bordered)
        .controlSize(.large)
        .frame(maxWidth: .infinity)
    }

    private var manualEntryForm: some View {
        VStack(spacing: 12) {
            TextField("Camera Wi-Fi SSID", text: $manualSSID)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .textContentType(.none)
                .accessibilityLabel("Camera Wi-Fi SSID")

            SecureField("Camera Wi-Fi key", text: $manualKey)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textContentType(.password)
                .privacySensitive()
                .accessibilityLabel("Camera Wi-Fi key")

            if manualSubmissionAttempted, manualCredentials == nil {
                Text("Enter the complete SSID and an 8–63 character Wi-Fi key.")
                    .font(.caption)
                    .foregroundStyle(Color(.systemRed))
                    .multilineTextAlignment(.center)
            }

            Button("Use These Details") {
                submitManualCredentials()
            }
            .font(.body.weight(.semibold))
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .frame(maxWidth: .infinity)

            HStack(spacing: 12) {
                Button("Back to scan") {
                    manualSubmissionAttempted = false
                    showsManualEntry = false
                }
                Button("Cancel", role: .cancel, action: onCancel)
            }
            .font(.body.weight(.semibold))
            .buttonStyle(.bordered)
            .controlSize(.large)
            .frame(maxWidth: .infinity)
        }
        .textFieldStyle(.roundedBorder)
    }

    private var manualCredentials: CameraWiFiScreenParser.Credentials? {
        CameraWiFiScreenParser.manualCredentials(ssid: manualSSID, key: manualKey)
    }

    private func submitManualCredentials() {
        manualSubmissionAttempted = true
        guard let manualCredentials else { return }
        onManualEntry(manualCredentials)
    }
}

/// Wraps `DataScannerViewController` and reports the first frame whose recognized text yields a
/// valid Nikon SSID + key.
private struct CameraWiFiScannerRepresentable: UIViewControllerRepresentable {
    let onCapture: (CameraWiFiScreenParser.Credentials) -> Void
    let onIssue: (CameraWiFiScreenParser.Result) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.text()],
            qualityLevel: .accurate,
            recognizesMultipleItems: true,
            isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: false,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        try? scanner.startScanning()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onCapture: onCapture, onIssue: onIssue)
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let onCapture: (CameraWiFiScreenParser.Credentials) -> Void
        private let onIssue: (CameraWiFiScreenParser.Result) -> Void
        private var didCapture = false
        private var lastIssue: CameraWiFiScreenParser.Result?

        init(
            onCapture: @escaping (CameraWiFiScreenParser.Credentials) -> Void,
            onIssue: @escaping (CameraWiFiScreenParser.Result) -> Void
        ) {
            self.onCapture = onCapture
            self.onIssue = onIssue
        }

        func dataScanner(
            _ scanner: DataScannerViewController,
            didAdd addedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            handle(allItems, scanner)
        }

        func dataScanner(
            _ scanner: DataScannerViewController,
            didUpdate updatedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            handle(allItems, scanner)
        }

        // ponytail: accept the first frame that fully validates rather than voting across N
        // frames — the popup shows the result for the operator to confirm/edit before joining,
        // which is the human vote. Add frame-consensus if field glare proves it necessary.
        private func handle(_ items: [RecognizedItem], _ scanner: DataScannerViewController) {
            guard !didCapture else { return }
            let lines = items.compactMap { item -> String? in
                if case .text(let text) = item { return text.transcript }
                return nil
            }
            let result = CameraWiFiScreenParser.result(lines: lines)
            switch result {
            case .credentials(let credentials):
                didCapture = true
                scanner.stopScanning()
                onCapture(credentials)
            case .needsKey, .unsupportedSSID:
                guard lastIssue != result else { return }
                lastIssue = result
                onIssue(result)
            case .noCredentials:
                break
            }
        }
    }
}

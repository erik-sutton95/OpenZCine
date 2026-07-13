import SwiftUI
import VisionKit

/// Apple-native modal that reads the camera's on-screen Connection wizard (SSID + Key) with the
/// phone's rear camera and hands validated credentials back to the connect popup. VisionKit does
/// the OCR; ``CameraWiFiScreenParser`` validates and self-corrects. A live viewfinder window is
/// embedded in the card so the operator can frame the camera's wizard screen. Scanning is the sole
/// path — Cancel is the only secondary action.
struct CameraWiFiScannerScreen: View {
    let onCapture: (CameraWiFiScreenParser.Credentials) -> Void
    let onCancel: () -> Void

    private let cardCornerRadius: CGFloat = 24
    private let cardMaxWidth: CGFloat = 360

    var body: some View {
        GeometryReader { proxy in
            // The viewfinder is the flexible element in the vertical stack. Cap its height so the
            // whole card (title + instruction + viewfinder + Cancel) fits within the short,
            // landscape-locked (~402pt tall) canvas with comfortable margins and no clipping.
            let viewfinderMaxHeight = max(132, min(240, proxy.size.height - 232))

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
            viewfinder
                .frame(maxHeight: viewfinderMaxHeight)
            cancelButton
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
            Text("Scan Wi‑Fi Details")
                .font(.title3.weight(.bold))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)

            Text(
                "Point your phone at the camera's Connection wizard screen showing the SSID and key."
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }

    /// Rounded viewfinder window holding the live scan feed (or a placeholder when unsupported).
    private var viewfinder: some View {
        ZStack {
            if DataScannerViewController.isSupported {
                CameraWiFiScannerRepresentable(onCapture: onCapture)
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

    private var cancelButton: some View {
        Button(role: .cancel, action: onCancel) {
            Text("Cancel")
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .accessibilityHint("Closes the scanner without joining")
    }
}

/// Wraps `DataScannerViewController` and reports the first frame whose recognized text yields a
/// valid Nikon SSID + key.
private struct CameraWiFiScannerRepresentable: UIViewControllerRepresentable {
    let onCapture: (CameraWiFiScreenParser.Credentials) -> Void

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
        Coordinator(onCapture: onCapture)
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let onCapture: (CameraWiFiScreenParser.Credentials) -> Void
        private var didCapture = false

        init(onCapture: @escaping (CameraWiFiScreenParser.Credentials) -> Void) {
            self.onCapture = onCapture
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
            guard let credentials = CameraWiFiScreenParser.parse(lines: lines) else { return }
            didCapture = true
            scanner.stopScanning()
            onCapture(credentials)
        }
    }
}

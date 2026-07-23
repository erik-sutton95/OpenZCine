import SwiftUI

/// System-rail still shutter (replaces the red record control in photography mode).
/// The strip itself reuses the cinema capture bar (`MonitorCaptureStrip`) with
/// photography readouts, so only the shutter needs a dedicated control.
struct PhotographyShutterButton: View {
    let isCapturing: Bool

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(Color.white.opacity(0.92), lineWidth: 3)
                .frame(width: 54, height: 54)
            Circle()
                .fill(isCapturing ? Color.white.opacity(0.5) : Color.white)
                .frame(width: 42, height: 42)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isCapturing ? "Capturing" : "Shutter")
    }
}

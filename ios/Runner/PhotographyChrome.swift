import SwiftUI

/// System-rail still shutter (replaces the red record control in photography mode).
/// The strip itself reuses the cinema capture bar (`MonitorCaptureStrip`) with
/// photography readouts, so only the shutter needs a dedicated control.
struct PhotographyShutterButton: View {
    let isCapturing: Bool
    /// Matches the cinema record control's footprint — the shutter sits in the same rail slot.
    private let size = CGFloat(MonitorSideRailControlLayout.recordButtonSize)

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(Color.white.opacity(0.92), lineWidth: 4)
                .frame(width: size, height: size)
            Circle()
                .fill(isCapturing ? Color.white.opacity(0.5) : Color.white)
                .frame(width: size - 17, height: size - 17)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isCapturing ? "Capturing" : "Shutter")
    }
}

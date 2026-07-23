import SwiftUI

/// System-rail still shutter (replaces the red record control in photography mode).
/// The strip itself reuses the cinema capture bar (`MonitorCaptureStrip`) with
/// photography readouts, so only the shutter needs a dedicated control.
struct PhotographyShutterButton: View {
    let isCapturing: Bool
    /// Seconds left in the app-side self-timer countdown (nil when idle) — drawn in the core.
    var countdown: Int? = nil
    /// Timer delay armed but not counting — a small glyph in the core hints the press will wait.
    var timerArmed: Bool = false
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
            if let countdown {
                Text("\(countdown)")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(.black)
                    .contentTransition(.numericText(countsDown: true))
            } else if timerArmed {
                Image(systemName: "timer")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.black.opacity(0.55))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: countdown)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            countdown != nil ? "Timer running" : isCapturing ? "Capturing" : "Shutter")
    }
}

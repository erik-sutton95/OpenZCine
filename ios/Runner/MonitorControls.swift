import MonitorUI
import OpenZCineCore
import SwiftUI
import UIKit

/// Light selection tap for operator-setup controls; respects the Controls-tab haptics preference.
enum OperatorSettingsHaptics {
    @MainActor
    static func selection(enabled: Bool) {
        guard enabled else { return }
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.prepare()
        generator.impactOccurred()
    }

    /// Firm tap confirming a camera shutter control-lock release (long-press unlock).
    @MainActor
    static func unlockConfirm() {
        let generator = UIImpactFeedbackGenerator(style: .rigid)
        generator.prepare()
        generator.impactOccurred(intensity: 1.0)
    }

    /// Firm tap confirming a camera shutter control-lock engage (long-press lock).
    @MainActor
    static func lockConfirm() {
        let generator = UIImpactFeedbackGenerator(style: .rigid)
        generator.prepare()
        generator.impactOccurred(intensity: 1.0)
    }
}

struct FPSChip: View {
    let fps: String
    /// Live link quality (0–4 bars) from `NativeAppModel.liveSignalBars` — transport health, not
    /// radio RSSI (which iOS apps can't read without special entitlements).
    let signalBars: Int

    private var signalTint: Color {
        switch signalBars {
        case 3...: LiveDesign.good
        case 2: LiveDesign.accent
        case 1: LiveDesign.rec
        default: LiveDesign.faint
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "cellularbars", variableValue: Double(signalBars) / 4.0)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(signalTint)
            Text("FPS")
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundStyle(LiveDesign.faint)
                .lineLimit(1)
            // `frameRate.formatted` is two decimals (e.g. "25.00") — without a hard
            // single-line policy the monospaced value wraps under deck squeeze as
            // "25.0" / "0". Never allow multi-line in the top bar.
            Text(fps)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(LiveDesign.text)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .fixedSize(horizontal: true, vertical: false)
        }
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .glassCapsule()
    }
}

struct SegmentedButtons: View {
    let items: [String]
    let selected: String
    let onSelect: (String) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(items, id: \.self) { item in
                Button {
                    onSelect(item)
                } label: {
                    Text(item)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(item == selected ? LiveDesign.accent : LiveDesign.muted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            item == selected ? LiveDesign.accentDim : LiveDesign.glassBright,
                            in: Capsule()
                        )
                }
                .buttonStyle(.monitorTapTarget)
            }
        }
    }
}

/// Converts the existing source-owned selection callback into a common binding.
struct NikonSettingsChoices: View {
    @Environment(NativeAppModel.self) private var model
    let options: [String]
    let selected: String
    var compact = false
    var stacked = false
    let onSelect: (String) -> Void

    var body: some View {
        MonitorSegmentedControl(
            options: options,
            selection: Binding(get: { selected }, set: onSelect),
            compact: compact, stacked: stacked, title: { $0 },
            onSelectionFeedback: {
                OperatorSettingsHaptics.selection(enabled: model.preferences.hapticsEnabled)
            }
        )
        .buttonStyle(MonitorSettingsButtonStyle())
    }
}

/// Source-specific panel switches retain the existing feedback preference before mutation.
struct NikonSettingsSwitch: View {
    @Environment(NativeAppModel.self) private var model
    let title: String
    var help: String? = nil
    var showTopDivider = true
    var stacked = false
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        MonitorSettingsSwitchInlineRow(
            title: title, help: help,
            showTopDivider: showTopDivider, stacked: stacked, isOn: isOn,
            feedback: {
                OperatorSettingsHaptics.selection(enabled: model.preferences.hapticsEnabled)
            },
            action: action)
    }
}

/// Selectable inline colour dots (the mockup's `zebra-color` / peaking colour group).

/// An inline on/off switch row (label + help + switch) for the divided assist/controls cards.

struct CloseButton: View {
    @Environment(NativeAppModel.self) private var model
    var action: (() -> Void)? = nil
    var size: CGFloat = 34

    var body: some View {
        Button {
            if let action {
                action()
            } else {
                model.dismissMediaLibrary()
            }
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: size * 0.38, weight: .bold))
                .frame(width: size, height: size)
                .glassCircle(interactive: true)
        }
        .buttonStyle(.monitorTapTarget)
    }
}

struct CircleIconButton: View {
    let systemName: String
    let size: CGFloat

    init(systemName: String, size: CGFloat = 52) {
        self.systemName = systemName
        self.size = size
    }

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 18, weight: .medium))
            .frame(width: size, height: size)
            .glassCircle(interactive: true)
            .minTapTarget()
    }
}

struct GlassPanel<Content: View>: View {
    let cornerRadius: CGFloat
    let padding: EdgeInsets
    @ViewBuilder let content: Content

    init(
        cornerRadius: CGFloat = LiveDesign.cornerRadius,
        padding: EdgeInsets = EdgeInsets(top: 18, leading: 18, bottom: 18, trailing: 18),
        @ViewBuilder content: () -> Content
    ) {
        self.cornerRadius = cornerRadius
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        content
            .padding(padding)
            .liquidGlass(in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

/// WB fine-tune ("tint") control mirroring the camera body: a 13×13 grid pad (amber ↔ blue on
/// x, green ↔ magenta on y) with step arrows on all four sides — one tap moves one grid cell,
/// 0.5 units on A–B and 0.25 on G–M, exactly the body's own increments. Dragging the pad jogs
/// freely (write commits on release); arrows commit per tap; double-tap resets to neutral.
/// Dimmed for WB modes with no tune property (Preset slots, Flash).
struct WhiteBalanceTintPad: View {
    @Environment(NativeAppModel.self) private var model

    private let side: CGFloat = 108

    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            HStack(spacing: 8) {
                arrow("chevron.left", label: "Blue", dx: -1, dy: 0)
                VStack(spacing: 8) {
                    arrow("chevron.up", label: "Green", dx: 0, dy: 1)
                    pad
                    arrow("chevron.down", label: "Magenta", dx: 0, dy: -1)
                }
                arrow("chevron.right", label: "Amber", dx: 1, dy: 0)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(model.whiteBalanceTintLabel)
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(
                        model.whiteBalanceTintLabel == "Neutral"
                            ? LiveDesign.muted : LiveDesign.accent
                    )
                    .lineLimit(1)
                Text("Steps of 0.5 (A–B) and 0.25 (G–M),\nlike the camera body.")
                    .font(.system(size: 11))
                    .foregroundStyle(LiveDesign.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Double-tap the pad to reset.")
                    .font(.system(size: 11))
                    .foregroundStyle(LiveDesign.faint)
            }

            Spacer(minLength: 0)
        }
        .opacity(model.whiteBalanceTintAvailable ? 1 : 0.35)
        .allowsHitTesting(model.whiteBalanceTintAvailable)
        .onAppear { model.refreshWhiteBalanceTintFromCamera() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("White balance tint")
        .accessibilityValue(model.whiteBalanceTintLabel)
    }

    private func arrow(_ symbol: String, label: String, dx: Int, dy: Int) -> some View {
        Button {
            let range = WhiteBalanceTint.cellRange
            model.whiteBalanceTintAB = min(
                max(model.whiteBalanceTintAB + dx, range.lowerBound), range.upperBound)
            model.whiteBalanceTintGM = min(
                max(model.whiteBalanceTintGM + dy, range.lowerBound), range.upperBound)
            model.commitWhiteBalanceTint()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(LiveDesign.text)
                .frame(width: 28, height: 28)
                .background(LiveDesign.glassBright, in: Circle())
        }
        .buttonStyle(.monitorTapTarget)
        .accessibilityLabel("Shift toward \(label)")
    }

    private var pad: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(LiveDesign.glass)
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(LiveDesign.hairline, lineWidth: 1)

            // Crosshair axes, ending short of the letters capping each end.
            Path { path in
                path.move(to: CGPoint(x: side / 2, y: 18))
                path.addLine(to: CGPoint(x: side / 2, y: side - 18))
                path.move(to: CGPoint(x: 18, y: side / 2))
                path.addLine(to: CGPoint(x: side - 18, y: side / 2))
            }
            .stroke(LiveDesign.hairline, lineWidth: 1)

            // Axis letters in Nikon's notation, centred on the axis each one extends.
            axisLetter("G", color: .green, x: side / 2, y: 10)
            axisLetter("M", color: .pink, x: side / 2, y: side - 10)
            axisLetter("B", color: .blue, x: 10, y: side / 2)
            axisLetter("A", color: .orange, x: side - 10, y: side / 2)

            Circle()
                .fill(LiveDesign.accent)
                .frame(width: 13, height: 13)
                .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
                .position(
                    x: thumbOffset(model.whiteBalanceTintAB),
                    y: side - thumbOffset(model.whiteBalanceTintGM)
                )
        }
        .frame(width: side, height: side)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            model.whiteBalanceTintAB = 0
            model.whiteBalanceTintGM = 0
            model.commitWhiteBalanceTint()
        }
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { gesture in
                    model.whiteBalanceTintAB = cell(from: gesture.location.x / side)
                    model.whiteBalanceTintGM = cell(from: 1 - gesture.location.y / side)
                }
                .onEnded { _ in
                    model.commitWhiteBalanceTint()
                }
        )
    }

    private func axisLetter(_ letter: String, color: Color, x: CGFloat, y: CGFloat) -> some View {
        Text(letter)
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .foregroundStyle(color.opacity(0.85))
            .position(x: x, y: y)
    }

    /// Pad-space offset for an axis cell (0 = lower bound edge, `side` = upper bound edge).
    private func thumbOffset(_ value: Int) -> CGFloat {
        let range = WhiteBalanceTint.cellRange
        let t =
            CGFloat(value - range.lowerBound)
            / CGFloat(range.upperBound - range.lowerBound)
        return t * side
    }

    /// Snaps a normalised 0…1 pad coordinate to the nearest grid cell.
    private func cell(from t: CGFloat) -> Int {
        let range = WhiteBalanceTint.cellRange
        let clamped = min(max(t, 0), 1)
        let value =
            CGFloat(range.lowerBound)
            + clamped * CGFloat(range.upperBound - range.lowerBound)
        return Int(value.rounded())
    }
}

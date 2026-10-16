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

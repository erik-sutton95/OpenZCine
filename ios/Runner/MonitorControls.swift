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

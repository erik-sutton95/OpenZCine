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

struct StatusReadout: View {
    let label: String
    let value: String
    var isInteractive: Bool = false
    var isActive: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 3) {
                Text(label)
                    .font(.system(size: 9, weight: .bold, design: .default))
                    .foregroundStyle(isActive ? LiveDesign.accent : LiveDesign.faint)
                    .textCase(.uppercase)
                if isInteractive {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(isActive ? LiveDesign.accent : LiveDesign.faint)
                }
            }
            Text(value)
                .font(.system(size: 15, weight: .medium, design: .monospaced))
                .foregroundStyle(LiveDesign.text)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }
}

struct RecordChip: View {
    let state: RecordState

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(state == .recording ? LiveDesign.rec : LiveDesign.faint)
                .frame(width: 9, height: 9)
            Text(state.label)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(state == .recording ? LiveDesign.text : LiveDesign.muted)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .glassCapsule()
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
            Text(fps)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(LiveDesign.text)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .glassCapsule()
    }
}

struct BatteryPill: View {
    let percent: Int
    let icon: String

    var body: some View {
        VStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
            Text("\(percent)%")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
        }
        .foregroundStyle(.primary.opacity(0.82))
        .frame(width: 36, height: 66)
        .glassCapsule()
    }
}

struct BaseISOCard: View {
    let title: String
    let value: String

    var body: some View {
        VStack(spacing: 3) {
            Text(title)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(LiveDesign.accent)
            Text(value)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(LiveDesign.muted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .liquidGlass(
            in: RoundedRectangle(cornerRadius: LiveDesign.cornerRadius, style: .continuous))
    }
}

struct SegmentedRow: View {
    let items: [String]
    let selected: String

    var body: some View {
        HStack(spacing: 6) {
            ForEach(items, id: \.self) { item in
                Text(item)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(item == selected ? .blue : .secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        item == selected ? .blue.opacity(0.16) : .white.opacity(0.05), in: Capsule()
                    )
            }
        }
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
                .buttonStyle(.zcTapTarget)
            }
        }
    }
}

struct GlassChoice: View {
    let title: String
    var isSelected = false

    var body: some View {
        Text(title)
            .font(.system(size: 14, weight: .medium, design: .monospaced))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .allowsTightening(true)
            .foregroundStyle(isSelected ? LiveDesign.accent : LiveDesign.text)
            .padding(.horizontal, 2)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                isSelected ? LiveDesign.accentDim : LiveDesign.glassBright,
                in: RoundedRectangle(cornerRadius: LiveDesign.cornerRadius)
            )
            .overlay(
                RoundedRectangle(cornerRadius: LiveDesign.cornerRadius)
                    .stroke(isSelected ? LiveDesign.accentDim : LiveDesign.hairline, lineWidth: 1)
            )
    }
}

struct GridToggle: View {
    let title: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            GlassChoice(title: title, isSelected: isOn)
        }
        .buttonStyle(.zcTapTarget)
    }
}

struct ToggleRow: View {
    let title: String
    let isOn: Bool

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
            Spacer()
            Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isOn ? LiveDesign.accent : LiveDesign.muted)
        }
        .padding(14)
        .background(
            isOn ? LiveDesign.accentDim : LiveDesign.glassBright,
            in: RoundedRectangle(cornerRadius: LiveDesign.cornerRadius)
        )
    }
}

struct SettingCard: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(LiveDesign.faint)
            Text(value)
                .font(.system(size: 17, weight: .medium, design: .default))
                .foregroundStyle(LiveDesign.text)
                .lineLimit(2)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, minHeight: 70, alignment: .leading)
        .padding(12)
        .liquidGlass(
            in: RoundedRectangle(cornerRadius: LiveDesign.cornerRadius, style: .continuous))
    }
}

struct SettingActionCard: View {
    let title: String
    let value: String
    var destructive = false
    var isActive: Bool?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(title)
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(LiveDesign.faint)
                    Text(value)
                        .font(.system(size: 17, weight: .medium, design: .default))
                        .foregroundStyle(destructive ? LiveDesign.rec : LiveDesign.text)
                        .lineLimit(2)
                        .minimumScaleFactor(0.75)
                }
                Spacer(minLength: 0)
                if let isActive {
                    Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isActive ? LiveDesign.accent : LiveDesign.muted)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(LiveDesign.muted)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 70, alignment: .leading)
            .padding(12)
            .background(
                destructive ? LiveDesign.rec.opacity(0.10) : LiveDesign.glassBright,
                in: RoundedRectangle(cornerRadius: LiveDesign.cornerRadius)
            )
            .overlay(
                RoundedRectangle(cornerRadius: LiveDesign.cornerRadius)
                    .stroke(
                        destructive ? LiveDesign.rec.opacity(0.28) : LiveDesign.hairline,
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.zcTapTarget)
    }
}

struct SettingsGroupCard<Content: View>: View {
    let title: String
    let caption: String
    var onReset: (() -> Void)? = nil
    @ViewBuilder let content: Content

    init(
        title: String, caption: String, onReset: (() -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.caption = caption
        self.onReset = onReset
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold, design: .default))
                        .foregroundStyle(LiveDesign.text)
                    Text(caption)
                        .font(.system(size: 11.5, weight: .regular, design: .default))
                        .foregroundStyle(LiveDesign.muted)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
                Spacer(minLength: 0)
                if let onReset {
                    SettingsResetButton(action: onReset)
                }
            }
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .liquidGlass(
            in: RoundedRectangle(cornerRadius: LiveDesign.cornerRadius, style: .continuous))
    }
}

struct SettingsActionRow: View {
    let title: String
    let value: String
    var destructive = false
    var action: () -> Void = {}

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 11, weight: .semibold, design: .default))
                        .foregroundStyle(destructive ? LiveDesign.rec : LiveDesign.text)
                    Text(value)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(
                            destructive
                                ? LiveDesign.rec.opacity(0.84)
                                : LiveDesign.muted
                        )
                        .lineLimit(1)
                        .minimumScaleFactor(0.62)
                }
                Spacer(minLength: 0)
                Image(systemName: destructive ? "xmark.circle" : "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(destructive ? LiveDesign.rec : LiveDesign.faint)
            }
            .frame(minHeight: 38)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                destructive ? LiveDesign.rec.opacity(0.10) : LiveDesign.background.opacity(0.42),
                in: RoundedRectangle(cornerRadius: LiveDesign.cornerRadius)
            )
            .overlay(
                RoundedRectangle(cornerRadius: LiveDesign.cornerRadius)
                    .stroke(destructive ? LiveDesign.rec.opacity(0.32) : LiveDesign.hairline)
            )
        }
        .buttonStyle(.zcTapTarget)
    }
}

struct SettingsSwitchGraphic: View {
    let isOn: Bool

    var body: some View {
        Capsule()
            .fill(isOn ? LiveDesign.accentDim : LiveDesign.surface)
            .frame(width: 39, height: 22)
            .overlay(alignment: isOn ? .trailing : .leading) {
                Circle()
                    .fill(isOn ? LiveDesign.accent : LiveDesign.muted)
                    .frame(width: 15, height: 15)
                    .padding(3.5)
            }
            .overlay(Capsule().stroke(isOn ? LiveDesign.accentDim : LiveDesign.hairline))
    }
}

struct SettingsResetButton: View {
    @Environment(NativeAppModel.self) private var model
    let action: () -> Void

    var body: some View {
        Button {
            OperatorSettingsHaptics.selection(enabled: model.preferences.hapticsEnabled)
            action()
        } label: {
            Image(systemName: "arrow.counterclockwise")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(LiveDesign.muted)
                .frame(width: 28, height: 28)
                .background(LiveDesign.background.opacity(0.42), in: Circle())
                .overlay(Circle().stroke(LiveDesign.hairline, lineWidth: 1))
        }
        .buttonStyle(.zcTapTarget)
        .accessibilityLabel("Reset to defaults")
    }
}

/// Horizontal settings strip that scrolls internally without expanding the parent card width.
struct SettingsHorizontalStrip<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            content()
                .padding(.vertical, 1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// While a settings reorder list is mid-drag, parent scroll views should pause so drop targets stay
/// stable under the finger.
struct SettingsReorderActiveKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

/// Finger Y in the settings scroll viewport (`settingsScroll` space) while a reorder handle is
/// dragged; `nil` when idle. Drives edge auto-scroll in `SettingsTabScrollArea`.
struct SettingsReorderDragViewportYKey: PreferenceKey {
    static let defaultValue: CGFloat? = nil
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        if let next = nextValue() { value = next }
    }
}

/// Coordinate space name shared with `SettingsTabScrollArea` for viewport-relative drag location.
enum SettingsScrollCoordinateSpace {
    static let name = "settingsScroll"
}

/// Compact vertical reorder list for settings cards: the handle is `.draggable`, each row a
/// `.dropDestination`, so iOS floats the drag preview and tracks the finger — no hand-positioned
/// overlay to miscompute the offset. Kept out of a reorderable `List` (its UIKit snapshot
/// miscomputes the horizontal offset inside the settings `ScrollView`). Do NOT scroll-disable the
/// parent mid-drag — that drops the drops; scrolling on lets iOS deliver drops and auto-scroll.
private struct SettingsReorderList<Item: Identifiable, RowContent: View>: View
where Item.ID == String {
    let items: [Item]
    /// Per-row height budget (content + vertical insets ≈ 44–46 pt).
    var rowHeight: CGFloat = 46
    let onMove: (IndexSet, Int) -> Void
    @ViewBuilder let rowContent: (Item, Int) -> RowContent

    @State private var dropTargetIndex: Int?
    private let shuffle = Animation.spring(response: 0.28, dampingFraction: 0.86)

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                draggableRow(item: item, index: index)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func draggableRow(item: Item, index: Int) -> some View {
        reorderRow(item: item, index: index)
            // Insertion indicator: a line at the top of the row the drop will land on.
            .overlay(alignment: .top) {
                if dropTargetIndex == index {
                    Capsule()
                        .fill(LiveDesign.accent)
                        .frame(height: 2)
                        .padding(.horizontal, 4)
                }
            }
            .dropDestination(for: String.self) { droppedIDs, _ in
                performMove(draggedID: droppedIDs.first, toIndex: index)
            } isTargeted: { targeted in
                dropTargetIndex =
                    targeted ? index : (dropTargetIndex == index ? nil : dropTargetIndex)
            }
    }

    private func performMove(draggedID: String?, toIndex index: Int) -> Bool {
        defer { dropTargetIndex = nil }
        guard let draggedID,
            let from = items.firstIndex(where: { $0.id == draggedID }),
            from != index
        else { return false }
        // `move(toOffset:)` inserts before the offset, so dropping onto a row *below* the source
        // needs +1 to land after it.
        withAnimation(shuffle) {
            onMove(IndexSet(integer: from), from < index ? index + 1 : index)
        }
        return true
    }

    private func reorderRow(item: Item, index: Int) -> some View {
        HStack(spacing: 6) {
            rowContent(item, index)
                .frame(maxWidth: .infinity, alignment: .leading)
            reorderGrip(item: item, index: index)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .frame(minHeight: rowHeight - 12, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func reorderGrip(item: Item, index: Int) -> some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(LiveDesign.faint)
            .frame(width: 44, height: rowHeight - 12)
            .contentShape(Rectangle())
            // The framework floats this preview under the finger — no manual position/offset math.
            // The preview renders `rowContent` directly (NOT `reorderRow`, which would recurse
            // through the grip's `.draggable` into an unresolvable opaque `some View` type).
            .draggable(item.id) {
                rowContent(item, index)
                    .frame(width: 300, alignment: .leading)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 10)
                    .background(LiveDesign.surface, in: RoundedRectangle(cornerRadius: 10))
            }
            .accessibilityLabel("Reorder handle")
            .accessibilityHint("Drag to reorder.")
    }
}

/// Assist-toolbar order and per-button visibility for Display settings.
struct AssistToolbarOrderStrip: View {
    @Environment(NativeAppModel.self) private var model

    var body: some View {
        SettingsReorderList(
            items: model.preferences.assistToolbarOrder,
            onMove: model.moveAssistToolbar
        ) { tool, index in
            let visible = model.preferences.isAssistToolbarButtonVisible(tool)
            let canToggleVisibility = tool != .lut
            HStack(spacing: 10) {
                Text("\(index + 1)")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(LiveDesign.muted)
                    .frame(width: 18, height: 18)
                    .background(LiveDesign.surface, in: Circle())
                AssistToolIcon(tool: tool, size: 15)
                    .frame(width: 22)
                Text(tool.displaySettingsTitle)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(visible ? LiveDesign.text : LiveDesign.muted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Spacer(minLength: 0)
                Text(tool.rawValue)
                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(LiveDesign.faint)
                if canToggleVisibility {
                    Button {
                        model.toggleAssistToolbarVisibility(tool)
                    } label: {
                        Image(systemName: visible ? "eye.fill" : "eye.slash")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(visible ? LiveDesign.accent : LiveDesign.faint)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.zcTapTarget)
                }
            }
            .accessibilityLabel("\(tool.displaySettingsTitle), position \(index + 1)")
            .accessibilityHint(
                canToggleVisibility
                    ? "Tap the eye to show or hide on the monitor bar. Drag to reorder."
                    : "Drag to reorder."
            )
        }
    }
}

struct DisplayOrderStrip: View {
    @Environment(NativeAppModel.self) private var model

    var body: some View {
        SettingsReorderList(
            items: model.preferences.dispOrder,
            onMove: model.moveDispOrder
        ) { mode, index in
            let enabled = model.preferences.enabledDispModes.contains(mode)
            HStack(spacing: 10) {
                Text("\(index + 1)")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(LiveDesign.muted)
                    .frame(width: 18, height: 18)
                    .background(LiveDesign.surface, in: Circle())
                Text(mode.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(
                        mode == model.displayMode && enabled
                            ? LiveDesign.accent
                            : LiveDesign.text
                    )
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Spacer(minLength: 0)
                Button {
                    model.toggleDispMode(mode)
                } label: {
                    Image(systemName: enabled ? "eye.fill" : "eye.slash")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(enabled ? LiveDesign.accent : LiveDesign.faint)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.zcTapTarget)
            }
            .accessibilityLabel("\(mode.title), position \(index + 1)")
            .accessibilityHint("Tap the eye to toggle visibility. Drag to reorder.")
        }
    }
}

struct DisplayToggleItem: View {
    let title: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold, design: .default))
                    .foregroundStyle(LiveDesign.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.64)
                Spacer(minLength: 0)
                SettingsSwitchGraphic(isOn: isOn)
                    .scaleEffect(0.86)
            }
            .padding(.horizontal, 9)
            .frame(height: 46)
            .background(
                LiveDesign.background.opacity(0.38),
                in: RoundedRectangle(cornerRadius: LiveDesign.cornerRadius)
            )
            .overlay(
                RoundedRectangle(cornerRadius: LiveDesign.cornerRadius)
                    .stroke(LiveDesign.hairline, lineWidth: 1)
            )
        }
        .buttonStyle(.zcTapTarget)
    }
}

// MARK: - Mockup-parity settings primitives
//
// These mirror the HTML operator-setup surface (settings-seg, settings-row, dash-scale, …) so the
// native panel matches the prototype 1:1. Controls that the core model already backs are wired to
// it; the rest are presentation-only for now (see `SettingsUIState`).

/// The mockup's per-row `?` help affordance — taps reveal a one-line explanation in a popover.
struct HelpBadge: View {
    let text: String
    @State private var showing = false

    var body: some View {
        Button {
            showing.toggle()
        } label: {
            Image(systemName: "questionmark")
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(LiveDesign.faint)
                .frame(width: 16, height: 16)
                .background(LiveDesign.background.opacity(0.5), in: Circle())
                .overlay(Circle().stroke(LiveDesign.hairline, lineWidth: 1))
        }
        .buttonStyle(.zcTapTarget)
        .popover(isPresented: $showing) {
            Text(text)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(LiveDesign.text)
                .padding(12)
                .frame(width: 248)
                .fixedSize(horizontal: false, vertical: true)
                .presentationCompactAdaptation(.popover)
        }
    }
}

/// Compact inline segmented control sized to its options (the mockup's `settings-seg`).
struct SettingsSegmented: View {
    @Environment(NativeAppModel.self) private var model
    let options: [String]
    let selected: String
    /// When true, segments share the row width equally — use inside two-column settings grids so
    /// intrinsic segment width cannot blow out the panel.
    var compact: Bool = false
    /// When true, labels sit below the title in a stacked card row instead of beside it.
    var stacked: Bool = false
    let onSelect: (String) -> Void

    private var segmentFontSize: CGFloat {
        if stacked { return 12 }
        return compact ? 11 : 11
    }

    var body: some View {
        HStack(spacing: compact || stacked ? 3 : 3) {
            ForEach(options, id: \.self) { option in
                let active = option == selected
                Button {
                    guard option != selected else { return }
                    OperatorSettingsHaptics.selection(enabled: model.preferences.hapticsEnabled)
                    onSelect(option)
                } label: {
                    Text(option)
                        .font(
                            .system(
                                size: segmentFontSize, weight: active ? .semibold : .medium)
                        )
                        .foregroundStyle(active ? LiveDesign.text : LiveDesign.muted)
                        .lineLimit(1)
                        .minimumScaleFactor(stacked ? 1 : (compact ? 0.85 : 1))
                        .padding(.horizontal, stacked ? 8 : (compact ? 8 : 11))
                        .padding(.vertical, stacked ? 7 : (compact ? 6 : 6))
                        .frame(maxWidth: compact || stacked ? .infinity : nil)
                        .frame(minHeight: stacked ? 32 : nil)
                        .background(
                            active ? LiveDesign.surface : Color.clear,
                            in: RoundedRectangle(
                                cornerRadius: DesignTokens.cornerRadius, style: .continuous))
                }
                .buttonStyle(.zcTapTarget)
            }
        }
        .padding(3)
        .background(
            LiveDesign.background.opacity(0.5),
            in: RoundedRectangle(cornerRadius: DesignTokens.cornerRadius, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.cornerRadius, style: .continuous)
                .stroke(LiveDesign.hairline, lineWidth: 1)
        )
        .modifier(SettingsSegmentedWidthStyle(compact: compact || stacked))
    }
}

/// Stop-picker for crush/clip compensation — short labels and larger touch targets in
/// compact operator-setup cards.
struct SettingsCrushClipSegmented: View {
    @Environment(NativeAppModel.self) private var model
    let selected: AssistConfiguration.CrushClipCompensation
    var compact: Bool = false
    let onSelect: (AssistConfiguration.CrushClipCompensation) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(AssistConfiguration.CrushClipCompensation.allCases) { option in
                let active = option == selected
                Button {
                    guard option != selected else { return }
                    OperatorSettingsHaptics.selection(enabled: model.preferences.hapticsEnabled)
                    onSelect(option)
                } label: {
                    // Fraction glyphs in both variants: the quarter-stop decimals ("0.25")
                    // truncate in the side-by-side quick-settings row. Full value stays in the
                    // accessibility label below.
                    Text(option.compactLabel)
                        .font(
                            .system(size: compact ? 12 : 11, weight: active ? .semibold : .medium)
                        )
                        .foregroundStyle(active ? LiveDesign.text : LiveDesign.muted)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 34)
                        .background(
                            active ? LiveDesign.surface : Color.clear,
                            in: RoundedRectangle(
                                cornerRadius: DesignTokens.cornerRadius, style: .continuous))
                }
                .buttonStyle(.zcTapTarget)
                .accessibilityLabel(option.label)
            }
        }
        .padding(4)
        .background(
            LiveDesign.background.opacity(0.5),
            in: RoundedRectangle(cornerRadius: DesignTokens.cornerRadius, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.cornerRadius, style: .continuous)
                .stroke(LiveDesign.hairline, lineWidth: 1)
        )
        .frame(maxWidth: .infinity)
    }
}

extension AssistConfiguration.CrushClipCompensation {
    /// Presentation in-app compact label (full stop value remains in accessibility).
    fileprivate var compactLabel: String {
        switch self {
        case .zero: "0"
        case .quarter: "¼"
        case .half: "½"
        case .threeQuarter: "¾"
        case .one: "1"
        }
    }
}

/// Wide single-column cards keep intrinsic segment width; compact grid cards fill their column.
private struct SettingsSegmentedWidthStyle: ViewModifier {
    let compact: Bool

    func body(content: Content) -> some View {
        if compact {
            content.frame(maxWidth: .infinity)
        } else {
            // Without this the row's layout compresses the segments and truncates
            // "Fast/Balanced/Quality" to ellipses.
            content.fixedSize(horizontal: true, vertical: false)
        }
    }
}

/// One label-plus-trailing-control row for a divider-separated card (the mockup's `settings-row`).
struct SettingsInlineRow<Trailing: View>: View {
    let title: String
    var help: String? = nil
    var showTopDivider = true
    /// When true, the trailing control sits below the label — use in narrow two-column cards.
    var stacked: Bool = false
    @ViewBuilder let trailing: Trailing

    var body: some View {
        VStack(spacing: 0) {
            if showTopDivider {
                Rectangle().fill(LiveDesign.hairline).frame(height: 1)
            }
            if stacked {
                VStack(alignment: .leading, spacing: 6) {
                    labelRow
                    trailing
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, minHeight: 44)
            } else {
                HStack(spacing: 8) {
                    labelRow
                    Spacer(minLength: 12)
                    trailing
                }
                // Stay greedy so a divided row card fills its full grid span instead of shrink-wrapping
                // to the rows' intrinsic width (which would clip titles on the left).
                .frame(maxWidth: .infinity, minHeight: 50)
            }
        }
    }

    private var labelRow: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(LiveDesign.text)
                .lineLimit(stacked ? 2 : 1)
                .fixedSize(horizontal: !stacked, vertical: false)
                .layoutPriority(1)
            if let help { HelpBadge(text: help) }
            if !stacked { Spacer(minLength: 0) }
        }
    }
}

/// Plain monospace value text (`settings-value`).
struct SettingsValueText: View {
    let value: String
    var body: some View {
        Text(value)
            .font(.system(size: 12.5, weight: .medium, design: .monospaced))
            .foregroundStyle(LiveDesign.muted)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }
}

/// Range slider with a trailing percent readout (the mockup's `wave-brightness-control`).
struct SettingsPercentSlider: View {
    @Environment(NativeAppModel.self) private var model
    @Binding var value: Int
    let range: ClosedRange<Int>

    var body: some View {
        HStack(spacing: 9) {
            Slider(
                value: Binding(
                    get: { Double(value) },
                    set: { newValue in
                        let rounded = Int(newValue.rounded())
                        guard rounded != value else { return }
                        OperatorSettingsHaptics.selection(enabled: model.preferences.hapticsEnabled)
                        value = rounded
                    }),
                in: Double(range.lowerBound)...Double(range.upperBound),
                step: 1
            )
            .tint(LiveDesign.accent)
            Text("\(value)%")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(LiveDesign.text)
                .frame(width: 40, alignment: .trailing)
                .monospacedDigit()
        }
    }
}

/// Amber action pill (`settings-action`).
struct SettingsActionPill: View {
    let title: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title.uppercased())
                .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                .kerning(0.6)
                .foregroundStyle(LiveDesign.accent)
                .lineLimit(1)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(LiveDesign.accentDim, in: Capsule())
                .overlay(Capsule().stroke(LiveDesign.accent.opacity(0.5), lineWidth: 1))
        }
        .buttonStyle(.zcTapTarget)
    }
}

/// A card whose rows are divider-separated with no per-row borders (the mockup's wide row card).
/// Always Liquid Glass on iOS — no surface/flat demotion for scroll regions.
struct SettingsRowCard<Content: View>: View {
    var title: String? = nil
    var onReset: (() -> Void)? = nil
    @ViewBuilder let content: Content

    init(
        title: String? = nil, onReset: (() -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.onReset = onReset
        self.content = content()
    }

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: LiveDesign.cornerRadius, style: .continuous)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                HStack(alignment: .firstTextBaseline) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(LiveDesign.text)
                    Spacer(minLength: 0)
                    if let onReset {
                        SettingsResetButton(action: onReset)
                    }
                }
                .frame(minHeight: 24, alignment: .topLeading)
                .padding(.top, 11)
                .padding(.bottom, 2)
            }
            content
        }
        .padding(.horizontal, 13)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlass(in: cardShape)
    }
}

/// The mockup's dash-scale meter (Link Health): a state marker over a 12-dash
/// track lit to the current band, with a Poor / Watch / Stable legend.
struct SettingsDashScale: View {
    let title: String
    let caption: String
    /// 0–100 link score; the band (Poor < 50, Watch 50–79, Stable 80+) drives colour and marker.
    let score: Int

    private enum Band { case poor, watch, stable }
    private var band: Band { score >= 80 ? .stable : (score >= 50 ? .watch : .poor) }
    private var bandColor: Color {
        switch band {
        case .poor: LiveDesign.rec
        case .watch: LiveDesign.accent
        case .stable: LiveDesign.good
        }
    }
    private var bandName: String {
        switch band {
        case .poor: "POOR"
        case .watch: "WATCH"
        case .stable: "STABLE"
        }
    }
    private var litCount: Int {
        switch band {
        case .poor: 4
        case .watch: 8
        case .stable: 12
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(LiveDesign.text)
            Text(caption)
                .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                .foregroundStyle(LiveDesign.muted)
            HStack(spacing: 0) {
                ForEach(0..<3) { slot in
                    ZStack {
                        if slot == bandSlot { marker }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 19)
            HStack(spacing: 3) {
                ForEach(0..<12, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(dashColor(index))
                        .frame(height: 6)
                }
            }
            HStack(spacing: 0) {
                legend("Poor", "<50").frame(maxWidth: .infinity, alignment: .leading)
                legend("Watch", "50-79").frame(maxWidth: .infinity, alignment: .center)
                legend("Stable", "80+").frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlass(
            in: RoundedRectangle(cornerRadius: LiveDesign.cornerRadius, style: .continuous))
    }

    private var bandSlot: Int {
        switch band {
        case .poor: 0
        case .watch: 1
        case .stable: 2
        }
    }

    private var marker: some View {
        Text(bandName)
            .font(.system(size: 9.5, weight: .bold, design: .monospaced))
            .kerning(0.5)
            .foregroundStyle(bandColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(bandColor.opacity(0.12), in: Capsule())
            .overlay(Capsule().stroke(bandColor, lineWidth: 1))
    }

    private func dashColor(_ index: Int) -> Color {
        guard index < litCount else { return LiveDesign.hairlineStrong }
        if index < 4 { return LiveDesign.rec.opacity(0.8) }
        if index < 8 { return LiveDesign.accent.opacity(0.85) }
        return LiveDesign.good.opacity(0.9)
    }

    private func legend(_ name: String, _ sub: String) -> some View {
        HStack(spacing: 4) {
            Text(name)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(LiveDesign.muted)
            Text(sub)
                .font(.system(size: 9, weight: .regular, design: .monospaced))
                .foregroundStyle(LiveDesign.faint)
        }
    }
}

/// Selectable inline colour dots (the mockup's `zebra-color` / peaking colour group).
struct SettingsColorDots: View {
    @Environment(NativeAppModel.self) private var model
    struct Dot: Identifiable {
        let name: String
        let color: Color
        var id: String { name }
    }
    let dots: [Dot]
    let selected: String
    var compact: Bool = false
    let onSelect: (String) -> Void

    private var dotDiameter: CGFloat { compact ? 15 : 13 }
    private var hitTarget: CGFloat { 44 }

    var body: some View {
        HStack(spacing: compact ? 4 : 6) {
            ForEach(dots) { dot in
                Button {
                    guard dot.name != selected else { return }
                    OperatorSettingsHaptics.selection(enabled: model.preferences.hapticsEnabled)
                    onSelect(dot.name)
                } label: {
                    Circle()
                        .fill(dot.color)
                        .frame(width: dotDiameter, height: dotDiameter)
                        .frame(width: hitTarget, height: hitTarget)
                        .background(LiveDesign.background.opacity(0.5), in: Circle())
                        .overlay(
                            Circle().stroke(
                                dot.name == selected ? dot.color : LiveDesign.hairline,
                                lineWidth: dot.name == selected ? 2 : 1))
                }
                .buttonStyle(.zcTapTarget)
                .accessibilityLabel(dot.name)
            }
        }
    }
}

/// Small numeric field used by the zebra threshold rows (the mockup's `settings-num`).
struct SettingsNumberField: View {
    @Binding var value: Int
    var maximum: Int = 100

    var body: some View {
        TextField("", value: $value, format: .number)
            .keyboardType(.numberPad)
            .multilineTextAlignment(.center)
            .font(.system(size: 12, weight: .semibold, design: .monospaced))
            .foregroundStyle(LiveDesign.text)
            .frame(width: 44, height: 30)
            .background(
                LiveDesign.background.opacity(0.5),
                in: RoundedRectangle(cornerRadius: DesignTokens.cornerRadius, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.cornerRadius, style: .continuous)
                    .stroke(LiveDesign.hairline, lineWidth: 1)
            )
            .onChange(of: value) { _, newValue in
                value = min(max(newValue, 0), maximum)
            }
    }
}

/// An inline on/off switch row (label + help + switch) for the divided assist/controls cards.
struct SettingsSwitchInlineRow: View {
    @Environment(NativeAppModel.self) private var model
    let title: String
    var help: String? = nil
    var showTopDivider = true
    /// When true, the switch sits below the label — use in narrow two-column cards.
    var stacked: Bool = false
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        SettingsInlineRow(
            title: title, help: help, showTopDivider: showTopDivider, stacked: stacked
        ) {
            Button {
                OperatorSettingsHaptics.selection(enabled: model.preferences.hapticsEnabled)
                action()
            } label: {
                SettingsSwitchGraphic(isOn: isOn)
            }
            .buttonStyle(.zcTapTarget)
        }
    }
}

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
        .buttonStyle(.zcTapTarget)
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
        .buttonStyle(.zcTapTarget)
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

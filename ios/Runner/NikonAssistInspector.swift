import MonitorPresentation
import MonitorUI
import OpenCineAppKit
import OpenCineMedia
import OpenZCineCore
import SwiftUI

/// The approved palette defaults, with the between-shots PLAY and EV leading the photo toolset.
let nikonAssistUsageSeed = MonitorToolUsage.fieldMonitorSeed.merging(["PLAY": 8, "EV": 7]) { $1 }

extension NativeAppModel {
    /// The live palette for this camera: the cinema set, or the photo toolset with PLAY and the
    /// camera EV meter.
    var liveAssistPaletteTools: [MonitorAssistTool] {
        let photography = StillCapturePolicy.prefersPhotographyChrome(
            selector: cameraPropertySnapshot.captureSelector)
        return MonitorAssistTool.activeCases.filter {
            photography ? $0.appliesToPhotography : !$0.isPhotographyOnly
        }
    }

    /// Playback drops the camera-fed tools: the horizon and the EV needle need a camera, and PLAY
    /// reviews a capture.
    var playbackAssistPaletteTools: [MonitorAssistTool] {
        MonitorAssistTool.activeCases.filter { $0 != .level && !$0.isPhotographyOnly }
    }
}

/// The glyph for a Nikon tool: the shared artwork, or this camera's PLAY.
struct NikonAssistGlyph: View {
    let tool: MonitorAssistTool
    var size: CGFloat? = nil

    var body: some View {
        if let shared = MonitorPresentation.MonitorAssistTool(rawValue: tool.rawValue) {
            MonitorAssistToolGlyph(tool: shared, size: size)
        } else {
            MonitorIcon.image.frame(width: size, height: size)
        }
    }
}

/// The shared assist palette over the shared state. Toggles go through the model, which keeps the
/// interface lock and the portrait two-scope cap; long press opens the shared inspector.
struct NikonAssistPalette: View {
    @Environment(NativeAppModel.self) private var model
    let tools: [MonitorAssistTool]
    let context: ViewAssistContext
    let layout: MonitorAssistPaletteLayout
    @Binding var expanded: Bool
    let onOptions: (MonitorAssistTool) -> Void

    var body: some View {
        @Bindable var model = model
        let on = model.assist.tools(for: context)
        MonitorAssistPalette(
            tools: tools.map {
                MonitorToolItem(
                    id: $0.rawValue, title: $0.displaySettingsTitle, enabled: on.contains($0),
                    hasOptions: $0.hasConfiguration)
            },
            layout: layout, usageSeed: nikonAssistUsageSeed, usage: $model.assistToolUsage,
            expanded: $expanded,
            onToggle: { id in
                guard let tool = MonitorAssistTool(rawValue: id) else { return }
                OperatorSettingsHaptics.selection(enabled: model.preferences.hapticsEnabled)
                model.toggleAssist(tool, context: context)
            },
            onOptions: { id in
                guard !model.interfaceLocked, let tool = MonitorAssistTool(rawValue: id) else {
                    return
                }
                onOptions(tool)
            },
            icon: { id in
                if let tool = MonitorAssistTool(rawValue: id) { NikonAssistGlyph(tool: tool) }
            })
    }
}

/// The shared assist inspector: its frame and tab strip, the shared settings cards, and this
/// camera's typed extensions (its LUT catalog, the camera level style and instant review).
/// Selecting a tab never switches that assist on.
struct NikonAssistInspector: View {
    let tool: MonitorAssistTool
    let tools: [MonitorAssistTool]
    let viewport: CGSize
    var safeArea = EdgeInsets()
    let onSelect: (MonitorAssistTool) -> Void
    let onDismiss: () -> Void

    private var tabs: [MonitorAssistTool] { tools.filter(\.hasConfiguration) }
    private func descriptor(_ tool: MonitorAssistTool) -> MonitorInspectorTool<MonitorAssistTool> {
        MonitorInspectorTool(value: tool, title: tool.title, label: tool.rawValue,
            contentStyle: tool == .waveform || tool == .parade ? .fullWidth : .card)
    }

    var body: some View {
        MonitorToolInspector(selection: descriptor(tool), tools: tabs.map(descriptor),
            viewport: viewport, safeArea: safeArea, onSelect: onSelect, onDismiss: onDismiss
        ) { selection in
            NikonAssistGlyph(tool: selection, size: 17)
        } content: {
            NikonAssistOptions(tool: tool)
        } footer: {
            EmptyView()
        }
    }

}

/// One tool's options: the shared menus over the shared state, or this camera's own.
struct NikonAssistOptions: View {
    @Environment(NativeAppModel.self) private var model
    let tool: MonitorAssistTool

    var body: some View {
        let menus = NikonAssistMenuAdapter(model: model, compact: false)
        switch tool {
        case .falseColor: menus.falseColor
        case .zebra: menus.zebra
        case .waveform: menus.waveform
        case .parade: menus.parade
        case .histogram: menus.histogram
        case .vectorscope: menus.vectorscope
        case .trafficLights: menus.trafficLights
        case .peaking: menus.peaking
        case .instantReview: instantReviewRows
        case .guides:
            MonitorGuidesMenu(
                family: model.assist.binding(\.guideFamily),
                selected: model.assist.selectedGuides,
                mask: model.assist.binding(\.guideMask), feedback: selectionFeedback,
                onToggle: { model.assist.toggleGuide($0) })
        case .grid:
            MonitorGridMenu(
                selected: model.assist.gridOptions, feedback: selectionFeedback,
                onToggle: { model.assist.toggleGrid($0) })
        case .level:
            SegmentedButtons(
                items: AssistConfiguration.Level.Style.allCases.map(\.rawValue),
                selected: model.assistConfiguration.level.style.rawValue
            ) { value in
                if let style = AssistConfiguration.Level.Style(rawValue: value) {
                    model.assistConfiguration.level.style = style
                }
            }
        case .desqueeze:
            // On/off is the palette's DE-SQ chip; this only configures factor and axis.
            MonitorDesqueezeMenu(
                selected: model.assist.desqueezeCustom
                    ? nil : MonitorDesqueezePreset.matching(model.assist.desqueezeFactor),
                custom: model.assist.desqueezeCustom,
                factor: Binding(
                    get: { model.assist.desqueezeFactor },
                    set: { model.assist.updateDesqueezeCustom($0) }),
                horizontal: model.assist.binding(\.desqueezeHorizontal),
                help:
                    "Corrects an anamorphic squeeze on this monitor only. The recording and the scopes are never de-squeezed.",
                selectionFeedback: selectionFeedback,
                onSelect: {
                    if let preset = $0 {
                        model.assist.selectDesqueezePreset(preset)
                    } else {
                        model.assist.selectDesqueezeCustom()
                    }
                }, onFinish: { model.assist.persist() })
        case .lut:
            LUTPickerContent()
        case .crosshair:
            Text("Tap the palette button to show or hide the centre crosshair.")
                .font(.system(size: 13))
                .foregroundStyle(LiveDesign.muted)
        case .audioMeters, .evMeter, .mirror, .magnification:
            // No options (`hasConfiguration` is false), so the inspector never offers them.
            EmptyView()
        }
    }

    private var instantReviewRows: some View {
        Group {
            MonitorSettingsInlineRow(
                title: "Review Duration",
                help:
                    "How long the captured frame stays up after a release. ∞ keeps it until tapped. A held burst reviews its last frame once the run ends.",
                showTopDivider: false
            ) {
                NikonSettingsChoices(
                    options: ["3s", "5s", "7s", "∞"], selected: instantReviewDurationLabel
                ) {
                    model.assistConfiguration.instantReviewSeconds =
                        $0 == "∞" ? 0 : Int($0.dropLast()) ?? 5
                }
            }
            NikonSettingsSwitch(
                title: "Focus Point",
                help: "Overlay the AF box the shot focused with on the review.",
                isOn: model.assistConfiguration.instantReviewShowsFocusPoint
            ) {
                model.assistConfiguration.instantReviewShowsFocusPoint.toggle()
            }
            NikonSettingsSwitch(
                title: "Capture Info",
                help: "Show the shot's ISO, shutter, iris, and quality under the review.",
                isOn: model.assistConfiguration.instantReviewShowsCaptureInfo
            ) {
                model.assistConfiguration.instantReviewShowsCaptureInfo.toggle()
            }
        }
    }

    private var instantReviewDurationLabel: String {
        let seconds = model.assistConfiguration.instantReviewSeconds
        return seconds > 0 ? "\(seconds)s" : "∞"
    }

    private func selectionFeedback() {
        OperatorSettingsHaptics.selection(enabled: model.preferences.hapticsEnabled)
    }
}

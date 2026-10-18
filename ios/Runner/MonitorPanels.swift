import MonitorPresentation
import MonitorUI
import OpenCineAppKit
import OpenCineAppKitApple
import OpenCineApple
import OpenCineCameraControls
import OpenCineMedia
import OpenCineNikon
import OpenZCineCore
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// What a command dashboard tile opens: a Nikon picker on one of its segmented tabs.
struct NikonCommandRequest: Hashable {
    let picker: CameraPicker
    var mode = 0
}

typealias NikonCommandTile = MonitorCommandTile<CommandTileKind, NikonCommandRequest>

/// The DISP 3 order on the visible grid. The shared dashboard reports a drop as a slot of the
/// tiles it shows; a tile this body hides (the dual-base Mode tile) keeps its place in the stored
/// order instead of shifting every slot after it.
enum NikonCommandGridOrder {
    static func moving(
        _ kind: CommandTileKind, to index: Int, in order: [CommandTileKind],
        hidden: Set<CommandTileKind>
    ) -> [CommandTileKind] {
        let full = monitorCommandTileOrder(order, all: CommandTileKind.allCases)
        let visible = full.filter { !hidden.contains($0) }
        var moved = moveMonitorCommandTile(visible, kind, targetIndex: index, all: visible)
            .makeIterator()
        return full.map { hidden.contains($0) ? $0 : moved.next() ?? $0 }
    }
}

/// The Nikon values of the shared command dashboard (DISP 3): tile kinds, titles, live values
/// and the pickers they open. Layout, reorder and accessibility belong to `MonitorCommandDashboard`.
extension NativeAppModel {
    /// Video tiles follow the operator's order; photography tiles mirror the landscape stills
    /// strip tile for tile in its fixed order, so they carry no kind.
    var commandDashboardTiles: [NikonCommandTile] {
        if isPhotographyMode {
            return cameraPropertySnapshot.photographyCaptureValues.map { entry in
                NikonCommandTile(
                    title: Self.commandStillsTitle(entry.label), value: entry.value,
                    request: CameraPicker.forValueLabel(entry.label, photography: true).map {
                        NikonCommandRequest(picker: $0)
                    })
            }
        }
        return visibleCommandGridOrder.map { kind in
            NikonCommandTile(
                kind: kind, title: Self.commandTitle(kind), value: commandValue(kind),
                request: NikonCommandRequest(picker: Self.commandPicker(kind)))
        }
    }

    var commandDashboardSections: [MonitorCommandSection<CommandTileKind, NikonCommandRequest>] {
        func focus(_ title: String, _ value: String, _ mode: Int) -> NikonCommandTile {
            NikonCommandTile(
                title: title, value: value, request: NikonCommandRequest(picker: .focus, mode: mode)
            )
        }
        func audio(_ title: String, _ value: String, _ mode: Int, amber: Bool = false)
            -> NikonCommandTile
        {
            NikonCommandTile(
                title: title, value: value,
                request: NikonCommandRequest(picker: .audio, mode: mode),
                amber: amber)
        }
        return [
            MonitorCommandSection(
                title: "Image",
                cells: [
                    NikonCommandTile(title: "Tone", value: commandToneLabel),
                    NikonCommandTile(title: "Picture Profile", value: "\u{2014}", muted: true),
                ]),
            MonitorCommandSection(
                title: "Focus",
                cells: [
                    focus("Mode", shownCameraValue("FOCUS") ?? "\u{2014}", 0),
                    focus("Area", focusArea, 1),
                    focus("Subject", focusSubject, 2),
                ]),
            MonitorCommandSection(
                title: "Audio",
                cells: [
                    audio(
                        "Sens", commandMicrophoneSensLabel, 0,
                        amber: commandMicrophoneUsesManualLevel),
                    audio("32-bit Float", commandAudio32BitFloatLabel, 4),
                    audio("Input", commandMicrophoneInputLabel, 1),
                    audio("Wind", commandWindFilterLabel, 2),
                    audio("Atten", commandInputAttenuatorLabel, 3, amber: commandInputAttenuatorOn),
                ]),
            // Grid reads the camera's framing-grid setting (GridDisplay 0xD16C), not the app's
            // overlay toggle. Assist, DISP and Guides have no camera connection point, so none.
            MonitorCommandSection(
                title: "Monitor", cells: [NikonCommandTile(title: "Grid", value: commandGridLabel)]),
        ]
    }

    var commandDashboardHealth: MonitorCommandHealth {
        let temperature = cameraState.temperature
        return MonitorCommandHealth(
            temperature: temperature, temperatureOk: temperature.hasPrefix("OK"),
            storage: liveMediaReadout,
            camera: cameraState.cameraName, lens: cameraState.lens)
    }

    private static func commandTitle(_ kind: CommandTileKind) -> String {
        switch kind {
        case .mode: "Mode"
        case .iso: "ISO"
        case .shutter: "Shutter"
        case .iris: "Iris"
        case .whiteBalance: "White Bal"
        case .resolutionFramerate: "Resolution Framerate"
        case .codec: "Codec"
        case .ibis: "VR / e-VR"
        }
    }

    private static func commandPicker(_ kind: CommandTileKind) -> CameraPicker {
        switch kind {
        case .mode: .mode
        case .iso: .iso
        case .shutter: .shutter
        case .iris: .iris
        case .whiteBalance: .whiteBalance
        case .resolutionFramerate: .resolution
        case .codec: .codec
        case .ibis: .stabilization
        }
    }

    private func commandValue(_ kind: CommandTileKind) -> String {
        switch kind {
        case .mode: commandExposureMode
        case .iso: shownCameraValue("ISO") ?? "\u{2014}"
        case .shutter: shownCameraValue("SHUTTER") ?? "\u{2014}"
        case .iris: shownCameraValue("IRIS") ?? "\u{2014}"
        case .whiteBalance: shownCameraValue("WB") ?? "\u{2014}"
        case .resolutionFramerate: cameraState.resolutionFrameRate
        case .codec: cameraState.codec
        case .ibis: commandStabilizationLabel
        }
    }

    /// Grid title for a photography strip label (the video tiles' casing).
    private static func commandStillsTitle(_ label: String) -> String {
        switch label {
        case "MODE": "Mode"
        case "ISO": "ISO"
        case "SHUTTER": "Shutter"
        case "IRIS": "Iris"
        case "DRIVE": "Drive"
        case "FOCUS": "Focus"
        case "WB": "White Bal"
        case "METER": "Meter"
        case "PROFILE": "Profile"
        default: label
        }
    }
}

struct PickerHeader: View {
    let label: String
    let subtitle: String
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(label)
                    .font(.system(size: 18, weight: .heavy, design: .default))
                    .kerning(2)
                    .foregroundStyle(LiveDesign.text)
                    // The setting name is the anchor of the header — never let it wrap to a second
                    // line (e.g. "RESOLUTION" in the narrower top-bar popdown).
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                Text(subtitle)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .kerning(1.5)
                    .textCase(.uppercase)
                    .foregroundStyle(LiveDesign.faint)
            }
            Spacer(minLength: 8)
            CloseButton(action: onClose)
        }
    }
}

/// Existing independent native writes, never a coupled stabilization command.
enum NikonStabilizationRequest: String, Sendable {
    case movieVR = "vr"
    case electronicVR = "evr"
}

/// Nikon source facts accompany the existing group without changing its eligibility policy.
struct NikonStabilizationPresentation {
    let rows: [IndependentSettingRow<NikonStabilizationRequest, NikonStabilizationRequest>]
    let vrDescriptor: NikonDescriptorEvidence
    let evrDescriptor: NikonDescriptorEvidence
}

/// The existing Swift host projection. This does not normalize Android or wire admission.
enum NikonStabilizationSettings {
    static func presentation(
        vrOptions: [String]?, currentVR: String?, currentEVR: String?, codec: String,
        vrDescriptor: NikonDescriptorEvidence, evrDescriptor: NikonDescriptorEvidence,
        actualCodec: PTPCameraFileTypeMode?
    ) -> NikonStabilizationPresentation {
        var vr = vrDescriptor
        // Existing Swift fallback is legacy authorization, independent of the observed GetSet.
        vr.optionOrigin = vrOptions == nil ? .legacyFallback : .unknown
        var evr = evrDescriptor
        evr.optionOrigin = .legacyFallback
        let effectiveRows = rows(
            vrOptions: vrOptions, currentVR: currentVR, currentEVR: currentEVR, codec: codec)
        let projected = effectiveRows.map { row in
            let evidence = row.id == .movieVR ? vr : evr
            let latest = evidence.latestAttempt
            let observed =
                latest.outcome == .described && latest.descriptor != nil
                ? latest : (evidence.lastValidObservation ?? evidence.observation)
            let readOnly = observed.outcome == .described && observed.descriptor?.writable == false
            let codecReason: String?
            if row.id == .electronicVR {
                if let actualCodec {
                    codecReason =
                        MonitorTextFormat.isRawCodec(
                            PTPCameraPropertyDecoders.fileType(actualCodec.raw))
                        ? "e-VR is unavailable in RAW codecs" : nil
                } else {
                    codecReason = "e-VR is unavailable until the camera codec is known"
                }
            } else {
                codecReason = nil
            }
            let reason = readOnly ? "\(row.title) is read-only on this camera" : codecReason
            return IndependentSettingRow(
                id: row.id, title: row.title, options: row.options, current: row.current,
                request: reason == nil && !row.options.isEmpty ? row.id : nil,
                unavailableReason: reason)
        }
        return NikonStabilizationPresentation(rows: projected, vrDescriptor: vr, evrDescriptor: evr)
    }

    static func rows(
        vrOptions: [String]?, currentVR: String?, currentEVR: String?, codec: String
    ) -> [IndependentSettingRow<NikonStabilizationRequest, NikonStabilizationRequest>] {
        let raw = MonitorTextFormat.isRawCodec(codec)
        return [
            .init(
                id: .movieVR, title: "VR", options: vrOptions ?? ["OFF", "ON", "SPORT"],
                current: currentVR, request: .movieVR, unavailableReason: nil),
            .init(
                id: .electronicVR, title: "e-VR", options: ["OFF", "ON"], current: currentEVR,
                request: raw ? nil : .electronicVR,
                unavailableReason: raw ? "e-VR is unavailable in RAW codecs" : nil),
        ]
    }
}

/// Stabilization picker for the existing ibis tile, using the shared independent row renderer.
struct StabilizationPickerPanel: View {
    @Environment(NativeAppModel.self) private var model
    @State private var blockedNoticeReason: String?
    /// Bumped when the operator taps a refused row with an explanation.
    @State private var blockedNoticeRevision = 0

    var body: some View {
        let source = model.operatorLiveIdentity
        MonitorIndependentSettingsPanel(
            rows: model.stabilizationPresentation.rows,
            interactionEnabled: !model.interfaceLocked && !model.relayControlSurrendered,
            currentSource: { model.operatorLiveIdentity == source },
            onSelect: { request, option in
                model.applyGroupedStabilization(request, option: option, source: source)
            },
            onUnavailable: { _, reason in
                guard let reason else { return }
                blockedNoticeReason = reason
                blockedNoticeRevision += 1
            }
        )
        // No outer padding — `pickerBodyContent` already wraps this in a padded GlassPanel, so an
        // extra .padding(16) doubled the inset to ~36pt. The toast floats ABOVE the sheet header
        // so it's never cut off at the bottom edge.
        .overlay(alignment: .top) {
            if let blockedNoticeReason {
                MonitorTransientNotice(
                    text: blockedNoticeReason, revision: blockedNoticeRevision
                )
                .offset(y: -52)
            }
        }
    }

}

/// A drum-style value wheel with the wireframe's look: a momentum scroll that snaps (`viewAligned`)
/// to each value like a drum, with the centred value enlarged and gold, the rest dimmed, bracketed
/// by hairlines and faded at the edges. The centred value is reported through `selection`, updating
/// as the drum locks onto each detent.
/// A pair of buttons flanking the settled drum value: WB Kelvin's −10 / +10, and the CODEC
/// drum's advertised bit depths (8-bit left, 10-bit right — same idiom, Erik's ask on #276).
/// The captions default to the Kelvin pair so that call site stays as it was.
struct DrumSideAdjust {
    var minusEnabled: Bool
    var plusEnabled: Bool
    var onMinus: () -> Void
    var onPlus: () -> Void
    var minusTitle: String = "−10"
    var plusTitle: String = "+10"
    var minusAccessibilityLabel: String = "Decrease Kelvin by 10"
    var plusAccessibilityLabel: String = "Increase Kelvin by 10"
    /// Filled treatment for a side that IS the current camera value (the active bit depth).
    /// Kelvin's steps are relative nudges, so neither side is ever "selected" there.
    var minusSelected: Bool = false
    var plusSelected: Bool = false
    /// Accessibility hint for the drum carrying the pair.
    var hint: String = "Use minus 10 and plus 10 beside the selected value to fine-adjust"
}

/// The photo Quality picker: two side-by-side drums — RAW on/off and the JPEG/HEIF tier —
/// each with its sub-option beneath (NEF compression under RAW, the ★ optimal-quality toggle
/// under the tier). The pair composes one image-quality write; NEF compression writes its own
/// property. There is no nothing-selected quality on the body, so turning the last active half
/// off bounces the other half back on, and each half's sub-option dims while that half is off.
struct QualityPickerPanel: View {
    @Environment(NativeAppModel.self) private var model
    var embedded = false
    /// The composed pair, seeded from the camera once on appear (never re-read in `body` —
    /// the wheels would jog mid-spin like every other drum).
    @State private var config = StillQualityConfiguration(
        rawEnabled: true, tier: .fine, starred: false)
    @State private var rawSelection = ""
    @State private var tierSelection = ""
    /// Last composed label written, so bounces and re-seeds don't fire redundant writes.
    @State private var lastApplied = ""

    private static let rawOptions = ["On", "Off"]
    private static let tierOptions = StillQualityConfiguration.Tier.allCases.map(\.rawValue)
    /// Conservative fallback only — the body's own `RawCompressionType` enum wins below.
    /// First-generation Z bodies use the Compressed/Uncompressed pair and reject this trio, so
    /// offering it unconditionally is the same "options the body does not have" defect (#274).
    private static let nefOptions = [
        "High efficiency", "High efficiency★", "Lossless compression",
    ]

    var body: some View {
        Group {
            if embedded {
                contents
            } else {
                GlassPanel(padding: EdgeInsets(top: 16, leading: 20, bottom: 16, trailing: 20)) {
                    contents
                }
            }
        }
        .onAppear(perform: seed)
        .onChange(of: rawSelection) { _, newValue in
            guard !newValue.isEmpty else { return }
            let enabled = newValue == "On"
            guard enabled != config.rawEnabled else { return }
            config.rawEnabled = enabled
            if !enabled, config.tier == .off {
                // Dropping RAW with the tier off would select nothing — bounce the tier on.
                config.tier = .fine
                tierSelection = config.tier.rawValue
            }
            applyIfChanged()
        }
        .onChange(of: tierSelection) { _, newValue in
            guard let tier = StillQualityConfiguration.Tier(rawValue: newValue),
                tier != config.tier
            else { return }
            config.tier = tier
            if tier == .off {
                config.starred = false
                if !config.rawEnabled {
                    // Tier off with RAW off would select nothing — bounce RAW on.
                    config.rawEnabled = true
                    rawSelection = "On"
                }
            }
            applyIfChanged()
        }
    }

    /// A captioned drum column, equal-width so the two wheels split the panel evenly.
    private var contents: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !embedded {
                PickerHeader(label: "QUALITY", subtitle: CameraPicker.stillQuality.subtitle) {
                    model.dismissActivePanel()
                }
            }
            HStack(alignment: .top, spacing: 16) {
                column(caption: "RAW") {
                    MonitorValueDrum(
                        options: Self.rawOptions, selection: $rawSelection,
                        haptics: model.preferences.hapticsEnabled)
                    nefRows
                }
                column(caption: "JPEG · HEIF") {
                    MonitorValueDrum(
                        options: Self.tierOptions, selection: $tierSelection,
                        haptics: model.preferences.hapticsEnabled)
                    starToggle
                }
            }
        }
    }

    private func column(
        caption: String, @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(caption)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .kerning(1.5)
                .foregroundStyle(LiveDesign.faint)
                .frame(maxWidth: .infinity, alignment: .center)
            content()
        }
        .frame(maxWidth: .infinity)
    }

    /// The NEF (RAW) recording compression rows — a RAW setting, parked while RAW is off.
    private var nefRows: some View {
        let enabled = config.rawEnabled
        let current = model.cameraPropertySnapshot.rawCompression
        let options = model.cameraControlOptions[.rawCompressionType] ?? Self.nefOptions
        return VStack(spacing: 6) {
            ForEach(options, id: \.self) { option in
                optionChip(option, active: current == option, enabled: enabled) {
                    model.applyStillRawCompression(option)
                }
            }
        }
        .opacity(enabled ? 1 : 0.35)
        .disabled(!enabled)
    }

    /// The ★ optimal-quality toggle — meaningless with the tier off, so it dims there.
    private var starToggle: some View {
        let enabled = config.tier != .off
        return optionChip("★ Optimal quality", active: config.starred, enabled: enabled) {
            config.starred.toggle()
            applyIfChanged()
        }
        .opacity(enabled ? 1 : 0.35)
        .disabled(!enabled)
    }

    /// A compact selectable row in the mode-bar chip style.
    private func optionChip(
        _ label: String, active: Bool, enabled: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .foregroundStyle(active ? LiveDesign.accent : LiveDesign.muted)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(
                    active ? LiveDesign.accentDim : LiveDesign.background.opacity(0.28),
                    in: RoundedRectangle(cornerRadius: LiveDesign.cornerRadius, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: LiveDesign.cornerRadius, style: .continuous)
                        .stroke(active ? LiveDesign.accent : LiveDesign.hairline, lineWidth: 1)
                }
        }
        .buttonStyle(.monitorTapTarget)
    }

    private func seed() {
        guard rawSelection.isEmpty else { return }
        if let label = model.cameraPropertySnapshot.compression,
            let code = PTPCameraPropertyDecoders.compressionSettingCode(for: label),
            let decoded = StillQualityConfiguration.decode(compressionCode: code)
        {
            config = decoded
        }
        rawSelection = config.rawEnabled ? "On" : "Off"
        tierSelection = config.tier.rawValue
        lastApplied = config.compressionLabel ?? ""
    }

    private func applyIfChanged() {
        guard let label = config.compressionLabel, label != lastApplied else { return }
        lastApplied = label
        model.applyPicker(.stillQuality, mode: 0, value: label)
    }
}

/// One button flanking a picker drum. `selected` fills it solid: the CODEC pair shows which bit
/// depth the body is on; Kelvin's relative steps never set it.
struct DrumSideAdjustButton: View {
    let title: String
    let enabled: Bool
    var selected = false
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(
                    selected
                        ? LiveDesign.background : (enabled ? LiveDesign.accent : LiveDesign.faint)
                )
                .frame(width: 56, height: 40)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(selected ? LiveDesign.accent : LiveDesign.accentDim)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(
                            enabled ? LiveDesign.accent : LiveDesign.hairline, lineWidth: 1.5)
                )
        }
        // 56×40 draws smaller than the 44pt HIG minimum on one axis, and the panel's glass
        // ripples past the drawn edge — pad the hit test out to it (`minTapTarget`).
        .buttonStyle(.monitorTapTarget)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// Supplies current source-calibrated bindings to the concrete shared assist menus.
@MainActor struct NikonAssistMenuAdapter {
    let model: NativeAppModel
    var compact: Bool = false
    var context: ViewAssistContext = .liveView

    private var mapping: ExposureSignalMapping {
        context == .playback ? model.playbackExposureSignalMapping : model.exposureSignalMapping
    }

    /// The shared monitor scale order, with camera calibration supplied separately.
    static let falseColorScales = MonitorFalseColorSelection.allCases

    var falseColor: MonitorFalseColorMenu<MonitorFalseColorSelection> {
        MonitorFalseColorMenu(
            scales: Self.falseColorScales,
            scale: model.assist.binding(\.falseColorScale),
            referenceEnabled: model.assist.binding(\.falseColorReference),
            read709: model.assist.binding(\.falseColorRec709),
            optionalReference: falseColorReference,
            title: { $0.referenceScaleLabel },
            scaleHelp:
                "CineStop marks exposure relative to 18% gray. Video and IRE read the monitor signal. Limits paints shadow and highlight warnings. The camera supplies the source curve and clip calibration.",
            readHelp:
                "LOG reads the source signal. 709 reads the built-in Rec.709 monitor look, independently of the selected creative LUT.",
            referenceHelp: "Show a compact color key over live view while False Color is active.",
            compact: compact, selectionFeedback: selectionFeedback,
            readFeedback: selectionFeedback, referenceFeedback: selectionFeedback,
            onReferenceEnabled: { model.setAssist(.falseColor, visible: true, context: context) })
    }

    var falseColorReference: MonitorFalseColorReferenceValues {
        FalseColorReference.values(
            scale: model.assist.falseColorScale.nikonScale, mapping: mapping,
            read709: model.assist.falseColorRec709)
    }

    var zebra: MonitorZebraMenu<AssistConfiguration.Zebra.Unit, MonitorZebraPaint> {
        MonitorZebraMenu(
            units: AssistConfiguration.Zebra.Unit.allCases,
            unit: Binding(
                get: { model.assistConfiguration.zebra.unit },
                set: { model.assistConfiguration.zebra.unit = $0 }),
            title: { $0 == .native ? "0-255" : "IRE" }, unitsTitle: "Units",
            unitsHelp:
                "Switch between native 0-255 encoded codes and a 0-100 monitoring IRE scale.",
            highlightHelp:
                "High zebra warns when bright detail approaches clipping after the active log curve is compensated.",
            midtoneHelp:
                "Midtone zebra marks the chosen monitoring level after curve compensation.",
            highlight: zebraZone(highlight: true), midtone: zebraZone(highlight: false),
            compact: compact, selectionFeedback: selectionFeedback,
            toggleFeedback: selectionFeedback)
    }

    private func zebraZone(highlight: Bool) -> MonitorZebraNumberZone<
        MonitorZebraPaint
    > {
        let assist = model.assist
        let unit = model.assistConfiguration.zebra.unit
        let level: ReferenceWritableKeyPath<NikonAssistState, Double> =
            highlight ? \.zebraHighlightIRE : \.zebraMidtoneIRE
        let threshold = Binding(
            get: {
                unit.displayValue(for: assist[keyPath: level], mapping: mapping)
            },
            set: {
                let ire = unit.monitorPercent(fromDisplay: $0, mapping: mapping)
                // In place, so observers hear it even when the level is unchanged (a plain set
                // skips equal values): a native code past the curve's clip then redraws as the
                // threshold it maps to.
                func write(_ stored: inout Double) { stored = ire }
                if highlight {
                    write(&assist.zebraHighlightIRE)
                } else {
                    write(&assist.zebraMidtoneIRE)
                }
                assist.persist()
            })
        let colors = (highlight ? SettingsPalette.highlight : SettingsPalette.midtone).compactMap {
            dot in
            MonitorZebraPaint(rawValue: dot.name).map {
                MonitorSettingsColorDot(value: $0, title: dot.name, color: dot.color)
            }
        }
        return MonitorZebraNumberZone(
            enabled: assist.binding(highlight ? \.zebraHighlight : \.zebraMidtone),
            entry: MonitorZebraNumberEntry(
                value: threshold,
                maximum: unit == .native ? 255 : 100,
                identifier: "settings.zebra.threshold.\(highlight ? "Highlight" : "Midtone")"),
            colors: colors,
            paint: assist.binding(highlight ? \.zebraHighlightColor : \.zebraMidtoneColor))
    }

    var waveform: MonitorScopeTraceMenu<MonitorWaveformMode> {
        let options = model.scopePanels.waveform.optionsBinding
        return MonitorScopeTraceMenu(
            modes: MonitorWaveformMode.allCases, mode: options.mode,
            brightness: Binding(
                get: { options.wrappedValue.brightness },
                set: {
                    options.wrappedValue.brightness = MonitorWaveformOptions.clampedBrightness($0)
                }),
            guides: options.guides, title: { $0.rawValue },
            brightnessHelp: "Raise trace intensity when the preview is dark or low contrast.",
            compact: compact, modeFeedback: selectionFeedback, guideFeedback: selectionFeedback)
    }

    var parade: MonitorScopeTraceMenu<MonitorParadeMode> {
        let options = model.scopePanels.parade.optionsBinding
        return MonitorScopeTraceMenu(
            modes: MonitorParadeMode.allCases, mode: options.mode,
            brightness: Binding(
                get: { options.wrappedValue.brightness },
                set: {
                    options.wrappedValue.brightness = MonitorParadeOptions.clampedBrightness($0)
                }),
            guides: options.guides, title: { $0.rawValue },
            brightnessHelp: "Raise trace intensity for the separated channel lanes.",
            compact: compact, modeFeedback: selectionFeedback, guideFeedback: selectionFeedback)
    }

    var vectorscope: MonitorVectorscopeMenu {
        let options = model.scopePanels.vectorscope.optionsBinding
        return MonitorVectorscopeMenu(
            zoom: options.zoom,
            brightness: Binding(
                get: { options.wrappedValue.brightness },
                set: {
                    options.wrappedValue.brightness = MonitorVectorscopeOptions.clampedBrightness(
                        $0)
                }),
            zoomHelp:
                "Magnifies only the chroma trace; the graticule stays at unity. The vectorscope reads the monitor image after its active LUT or display tone map.",
            brightnessHelp: "Raise trace intensity when the chroma plot is hard to read.",
            compact: compact, zoomFeedback: selectionFeedback)
    }

    private var compensation: Binding<MonitorCrushClipCompensation> {
        model.assist.binding(\.crushClipCompensation)
    }

    var histogram: MonitorHistogramMenu {
        MonitorHistogramMenu(
            trafficLights: model.scopePanels.histogram.optionsBinding.trafficLights,
            compensation: compensation,
            trafficHelp: "Show small RGB edge blocks for crushed and clipped channels.",
            compensationHelp:
                "Stops of crush/clip tolerance before a traffic light glows. Shared with the goal-post meter.",
            compact: compact, trafficFeedback: selectionFeedback)
    }

    var trafficLights: MonitorCrushClipMenu {
        MonitorCrushClipMenu(
            compensation: compensation,
            help:
                "Stops of crush/clip tolerance before a channel indicator glows. Shared with histogram traffic lights.",
            compact: compact, showTopDivider: false)
    }

    var peaking: MonitorPeakingMenu {
        MonitorPeakingMenu(
            options: Binding(
                get: {
                    MonitorPeakingOptions(
                        color: model.assist.peakingColor,
                        sensitivity: model.assist.peakingSensitivity)
                },
                set: {
                    model.assist.peakingColor = $0.color
                    model.assist.peakingSensitivity = $0.sensitivity
                    model.assist.persist()
                }),
            colors: SettingsPalette.peaking.compactMap { dot in
                MonitorPeakingColor(rawValue: dot.name).map {
                    MonitorSettingsColorDot(value: $0, title: dot.name, color: dot.color)
                }
            },
            sensitivityHelp:
                "Higher sensitivity catches finer edges but can get noisy on detailed scenes.",
            colorHelp: "Choose the edge color that stays readable over your typical scene.",
            compact: compact, feedback: selectionFeedback)
    }

    private func selectionFeedback() {
        OperatorSettingsHaptics.selection(enabled: model.preferences.hapticsEnabled)
    }
}

/// Nikon supplies catalogue values and actions; the shared picker owns tabs, rows and import UI.
struct NikonLUTPicker: View {
    let embedded: Bool

    init(embedded: Bool = true) { self.embedded = embedded }
    @Environment(NativeAppModel.self) private var model
    @State private var redFilter = RedOutputFilter.all

    enum RedOutputFilter: String, CaseIterable {
        case all = "All"
        case rec709 = "Rec.709"
        case rec2020 = "Rec.2020"

        var match: String? {
            switch self {
            case .all: nil
            case .rec709: "REC709"
            case .rec2020: "REC2020"
            }
        }
    }

    var body: some View {
        MonitorLUTPickerView(
            assist: model.assist, embedded: embedded,
            haptics: OperatorHaptics(isEnabled: { model.preferences.hapticsEnabled }),
            palette: LiveDesign.self,
            prepare: {
                model.refreshCustomLUTs()
                model.refreshRedLUTs()
                Task.detached(priority: .utility) { LUTCubeCache.prewarmBuiltIns() }
            }, libraries: { libraries }
        )
        .onChange(of: model.assist.splitComparison) { _, enabled in
            if enabled {
                model.splitComparisonMuted = false
                model.setAssist(.lut, visible: true)
            }
        }
    }

    /// These descriptors are also used by composition tests, without substituting another provider.
    var libraries: [LUTPickerLibrary] {
        let selected = model.assistConfiguration.selectedLUT
        let builtIn = MonitorLUT.allCases.map {
            LUTPickerLibrary.Entry(id: $0.rawValue, title: $0.rawValue)
        }
        let builtInLook: MonitorLUT? = {
            if case .builtIn(let look) = selected { return look }
            return nil
        }()
        let builtInLibrary = LUTPickerLibrary(
            title: LUTCategory.builtIn.rawValue, entries: builtIn,
            isCurrent: builtInLook != nil, selectedID: builtInLook?.rawValue,
            representative: .init(
                id: MonitorLUT.log3G10Rec709.rawValue,
                title: MonitorLUT.log3G10Rec709.rawValue), caption: builtInLook?.credit ?? "",
            select: { entry in
                guard let look = MonitorLUT(rawValue: entry.id) else { return }
                model.assistConfiguration.selectedLUT = .builtIn(look)
                model.setAssist(.lut, visible: true)
            })
        let availability = InternetReachability.shared.redLUTDownloadAvailability
        let red = storedLibrary(
            .red, files: filteredRedLUTs,
            empty: .init(
                title: "RED IPP2 LUTs",
                hint: availability.blockedReason
                    ?? "Download RED's official looks. You'll accept RED's terms.",
                action: .init(
                    title: "Download from RED",
                    systemImage: availability.isAvailable ? "arrow.down.circle" : "wifi.slash",
                    perform: { model.isRedDownloadPresented = true })))
        let custom = storedLibrary(
            .custom, files: model.customLUTs,
            empty: .init(
                title: "No custom LUTs yet", hint: "Import a .cube file to add your own look."))
        return [builtInLibrary, red, custom]
    }

    private var filteredRedLUTs: [StoredCustomLUT] {
        let filtered =
            redFilter.match.map { needle in
                model.redLUTs.filter { $0.fileName.uppercased().contains(needle) }
            } ?? model.redLUTs
        guard let preferred = LUTLibraryIndex.defaultRedLUT(from: model.redLUTs),
            filtered.contains(preferred)
        else { return filtered }
        return [preferred] + filtered.filter { $0 != preferred }
    }

    private func storedLibrary(
        _ category: LUTCategory, files: [StoredCustomLUT],
        empty: LUTPickerLibrary.Empty
    ) -> LUTPickerLibrary {
        let selectedID: String? = {
            if case .stored(let current, let name) = model.assistConfiguration.selectedLUT,
                current == category
            {
                return name
            }
            return nil
        }()
        let entries = files.map { lut in
            LUTPickerLibrary.Entry(
                id: lut.fileName,
                title: category == .red ? RedPresetName.short(lut.fileName) : lut.displayName)
        }
        let preferred =
            category == .red
            ? LUTLibraryIndex.defaultRedLUT(from: model.redLUTs)?.fileName : files.first?.fileName
        return LUTPickerLibrary(
            title: category.rawValue, layout: category == .custom ? .files : .drum,
            entries: entries, isCurrent: selectedID != nil, selectedID: selectedID,
            representative: entries.first { $0.id == preferred } ?? entries.first,
            filter: category == .red && !model.redLUTs.isEmpty
                ? .init(
                    options: RedOutputFilter.allCases.map(\.rawValue),
                    selection: Binding(
                        get: { redFilter.rawValue },
                        set: { raw in
                            guard let filter = RedOutputFilter(rawValue: raw) else { return }
                            redFilter = filter
                            if let selectedID,
                                !filteredRedLUTs.contains(where: { $0.fileName == selectedID }),
                                let first = filteredRedLUTs.first
                            {
                                model.assistConfiguration.selectedLUT = .stored(
                                    category: .red, fileName: first.fileName)
                            }
                        })) : nil,
            markedIDs: category == .red ? Set(preferred.map { [$0] } ?? []) : [],
            empty: empty,
            select: { entry in
                model.assistConfiguration.selectedLUT = .stored(
                    category: category, fileName: entry.id)
                model.setAssist(.lut, visible: true)
            },
            delete: { entry in
                try model.deleteStoredLUT(StoredCustomLUT(fileName: entry.id), from: category)
                if category == .red, filteredRedLUTs.isEmpty { redFilter = .all }
            }, importCube: category == .custom ? { try model.importCustomLUT(from: $0) } : nil)
    }
}

enum SettingsPalette {
    struct Dot {
        let name: String
        let color: Color
    }

    static let highlight: [SettingsPalette.Dot] = [
        .init(name: "White", color: LiveDesign.text),
        .init(name: "Amber", color: LiveDesign.amber),
        .init(name: "Red", color: LiveDesign.rec),
    ]
    static let midtone: [SettingsPalette.Dot] = [
        .init(name: "Amber", color: LiveDesign.amber),
        .init(name: "Cyan", color: LiveDesign.info),
        .init(name: "Green", color: LiveDesign.good),
    ]
    static let peaking: [SettingsPalette.Dot] = [
        .init(name: "White", color: LiveDesign.text),
        .init(name: "Blue", color: LiveDesign.info),
        .init(name: "Red", color: LiveDesign.rec),
        .init(name: "Green", color: LiveDesign.good),
    ]
}

extension MonitorSettingsTab {
    /// Screenshot affordance (link/assist/controls/display/storage/system) picking the initial
    /// rail tab. Defaults to Link in normal launches.
    static var demoLaunchTab: MonitorSettingsTab {
        demoLaunchTab(DemoHarness.panelTab)
    }

    static func demoLaunchTab(_ rawValue: String?) -> MonitorSettingsTab {
        switch rawValue {
        case "sharing": .sharing
        case "assist": .assist
        case "controls": .controls
        case "display": .display
        case "storage": .storage
        case "system": .system
        default: .link
        }
    }
}

/// Z's legal set (A2-27): privacy and terms are this app's own text, readable on the camera's
/// network and ending with the full web page's address (Android twin: `ZLegalDocuments`).
/// Licenses and NOTICE are the repository's LICENSE, THIRD-PARTY-NOTICES.md and NOTICE, copied
/// into the bundle's Legal folder at build time (OpenCine `scripts/stage-legal-resources.py`),
/// with the platform's third-party notices. A build missing one shows the unavailable page.
extension MonitorLegalDocuments {
    static let z = MonitorLegalDocuments(
        wordmark: "OpenZCine", privacy: .text(zPrivacy), terms: .text(zTerms),
        licenses: bundledText([
            resource("LICENSE", extension: "txt", subdirectory: "Legal", in: .main),
            resource("THIRD-PARTY-NOTICES", extension: "txt", subdirectory: "Legal", in: .main),
            MonitorPlatformLegalNotices.text,
        ]),
        notice: bundledText([
            resource("NOTICE", extension: "txt", subdirectory: "Legal", in: .main)
        ])
    )

    private static let zPrivacy = """
        OpenZCine talks to your Nikon Z camera over Wi-Fi or USB-C. The app has no account. Automatic error reports are optional and off by default.

        OpenCapture is the data controller. Privacy or deletion requests: support@opencapture.org.

        \(MonitorSettingsCopy.reliabilityReportsPrivacy)

        Reporting a problem yourself
        Report a Problem sends your description and any optional reply email to OpenCapture through Sentry when you tap Send report. Technical details are included only if you choose them and can be reviewed first. You can choose up to three photos or screenshots and review or remove them before sending. Selected images are resized and re-encoded without original filenames or location metadata. Only share images you have permission to send; no images are attached automatically. This one-off submission does not enable automatic reports. Unsent reports stay privately on this phone, expire after 7 days (removed when the app next runs), wait until you leave camera Wi-Fi, and can be removed before delivery. Do not include passwords or other sensitive information in your message. You can decline the first-launch prompt and enable automatic reports later in System.

        What stays on this phone
        • Saved cameras, pairing profiles and the reconnect identity. Camera Wi-Fi passwords are stored in the iOS Keychain on this phone only.
        • Operator preferences such as Keep Screen Awake and the selected look.
        • Imported .cube files you choose to open and RED looks you download.
        • Saved feed incident and session reports, until you delete them in System.

        What never leaves the phone
        • Live view, camera settings and pairing traffic stay on the local link. We do not operate a cloud.

        Third parties
        • Apple may process permission prompts and OS diagnostics under its own policies. TestFlight betas may send crash reports to the developer under Apple terms.
        • Frame.io is optional. If this build is configured and you sign in, clips you pick upload from this phone to Adobe. The token stays in the on-device Keychain.
        • RED looks are optional. If you choose Download from RED, the app shows RED's IPP2 output presets page inside the app and downloads the file you pick from RED's servers. That visit and download are governed by RED's own privacy policy.
        • Saving a clip or using the share sheet is something you start. Apple or the app you pick then handles that file.
        • The source is at github.com/erik-sutton95/OpenZCine.

        The full privacy policy is https://openzcine.app/privacy/
        """

    private static let zTerms = """
        OpenZCine is free software under the Apache License 2.0. You may use, modify, and share it under that license. The App Store build is also subject to Apple's standard Licensed Application End User License Agreement.

        This is an unofficial camera monitor and remote control. It is not affiliated with, endorsed by, or supported by Nikon. "Nikon" and "Nikon Z" are trademarks of Nikon Corporation, used only to identify the cameras the app can talk to. RED, Adobe and Frame.io belong to their owners and are named only to identify optional features.

        OpenZCine remotely controls physical camera equipment. Wireless links drop, settings writes can be rejected, and the display can lag the camera's real state. Always verify the recording state, exposure and media on the camera itself. Use on productions is at your own risk.

        The software is provided on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND. See LICENSE in the repository.

        By using the app you agree to follow the Code of Conduct when participating in the project.

        The full terms are https://openzcine.app/terms/
        """
}

/// The internet-backed destination selected from Operator Setup.
///
/// Keeping the selection as a value lets the camera-AP confirmation survive the tap and route to
/// the exact page or in-app report flow after the camera session has been disconnected.
enum SettingsInternetDestination: String, CaseIterable, Identifiable {
    case support
    case featureRequest
    case sourceCode
    case privacyPolicy
    case termsOfUse

    var id: String { rawValue }

    var title: String {
        switch self {
        case .support: "Support"
        case .featureRequest: "Request a Feature"
        case .sourceCode: "Source Code"
        case .privacyPolicy: "Privacy Policy"
        case .termsOfUse: "Terms of Use"
        }
    }

    var webURL: URL? {
        switch self {
        case .support: SupportLinkCatalog.support
        case .featureRequest: SupportLinkCatalog.featureRequest
        case .sourceCode: SupportLinkCatalog.source
        case .privacyPolicy: SupportLinkCatalog.privacy
        case .termsOfUse: SupportLinkCatalog.terms
        }
    }

    var confirmationMessage: String {
        MonitorSettingsCopy.browserConfirmation(title: title, app: "OpenZCine")
    }

    static func demoValue(_ rawValue: String?) -> SettingsInternetDestination? {
        switch rawValue {
        case "support": .support
        case "feature": .featureRequest
        default: nil
        }
    }
}

/// A supplied common-cover clearance stays authoritative through rotation.
/// An omitted clearance keeps the legacy containing-window fallback.
private struct NikonSettingsViewport<Content: View>: View {
    @Environment(\.monitorWindowGeometry) private var windowGeometry
    let fallback: MonitorEdgeInsets?
    @ViewBuilder let content: (EdgeInsets, Bool) -> Content

    var body: some View {
        GeometryReader { proxy in
            let insets =
                fallback.map { supplied in
                    EdgeInsets(
                        top: CGFloat(supplied.top), leading: CGFloat(supplied.leading),
                        bottom: CGFloat(supplied.bottom), trailing: CGFloat(supplied.trailing))
                } ?? (windowGeometry.validSize == nil ? EdgeInsets() : windowGeometry.safeArea)
            content(insets, proxy.size.height > proxy.size.width)
        }
    }
}

struct OperatorSettingsPanel: View {
    var safeArea: MonitorEdgeInsets? = nil
    @Environment(NativeAppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var relayPasscodeDraft: String?
    @State private var reliabilityOptIn = ReliabilityDiagnostics.reporting.isOptedIn

    var body: some View {
        let _ = model.settingsAccount.accountRevision
        NikonSettingsViewport(fallback: safeArea) { insets, _ in
            MonitorOperatorSettingsScreen(
                brand: "OpenZCine", configuration: configuration(insets: insets),
                library: model.mediaLibrary,
                selectedTab: Binding(
                    get: { model.operatorSettingsTab }, set: { model.operatorSettingsTab = $0 }),
                operatorSession: model.operatorSession, sourceIdentity: model.shell.monitor?.id)
        }
        .observeMonitorWindowGeometry()
        .onAppear {
            model.settingsAccount.bind(accountActions)
            model.settingsSupport.bind(supportActions)
            if let destination = SettingsInternetDestination.demoValue(
                DemoHarness.internetHandoffConfirmation),
                let value = browserDestination(destination)
            {
                model.settingsSupport.request(value)
            } else if DemoHarness.openBugReport {
                model.isBugReportPresented = true
            }
        }
    }

    private func configuration(insets: EdgeInsets) -> MonitorOperatorSettingsConfiguration<
        NikonMonitorLooks
    > {
        let menus = NikonAssistMenuAdapter(model: model, compact: true)
        return .init(
            safeArea: insets,
            phase: isConnected
                ? "\(model.cameraState.cameraName) · \(transportLabel)" : model.linkHealthDetail,
            isLive: isConnected, sharingSubtitle: "Broadcast this feed and manage its watchers.",
            close: {
                model.settingsAccount.retire()
                model.settingsSupport.retire()
                model.dismissMediaLibrary()
            },
            disconnect: {
                model.settingsAccount.retire()
                model.settingsSupport.retire()
                model.disconnect()
            }, feedback: settingsFeedback, link: linkSource, sharing: sharingSource,
            assist: .init(
                state: model.assist, stores: model.scopePanels.operatorStores,
                falseColorLooks: .signal, palette: LiveDesign.self,
                haptics: .init(isEnabled: { [weak model] in
                    model?.preferences.hapticsEnabled == true
                }),
                transfer: model.exposureSignalMapping.curve.monitorTransfer,
                clipByte: model.exposureSignalMapping.clipByte,
                signalOptions: .init(
                    falseColor: AnyView(menus.falseColor), zebra: AnyView(menus.zebra),
                    reference: menus.falseColorReference,
                    resetFalseColor: { model.assist.resetOptions(.falseColor) },
                    resetZebra: {
                        model.assist.resetOptions(.zebra)
                        model.assistConfiguration.zebra = AssistConfiguration.defaults.zebra
                    }),
                exposureHelp:
                    "Shows the camera's exposure reading in the monitor. The recording is unchanged.",
                lookLabel: lookLabel,
                lookCatalog: { AnyView(NikonLUTPicker(embedded: false).environment(model)) }),
            controls: .init(
                recordConfirmation: preferenceBinding(\.recordConfirmationEnabled),
                haptics: .init(
                    value: preferenceBinding(\.hapticsEnabled),
                    help: "Short confirmation pulses for critical switches and setting changes."),
                keepAwake: .init(
                    value: preferenceBinding(\.keepScreenAwake),
                    help: MonitorSettingsCopy.keepScreenAwake),
                input: .init(
                    remoteShutter: .volumeButtons(
                        enabled: preferenceBinding(\.bluetoothShutterEnabled)),
                    autoRotate: .init(
                        enabled: preferenceBinding(\.autoRotateFeedEnabled),
                        help:
                            "Turns the monitoring image upright when the camera is held on its side or upside down. Off keeps the picture in the camera's native orientation. Display only. The recording is never affected."
                    ))),
            display: .init(
                hdr: .init(
                    value: Binding(get: { model.hdrDisplay }, set: { model.hdrDisplay = $0 }),
                    help: MonitorSettingsCopy.hdrPanel(cameraMode: "N-Log or HLG tone mode")),
                sections: model.controlCapabilities.displaySections),
            cache: .init(
                source: model.captureOperatorMediaCacheSource(),
                clearHelp:
                    "Removes cached clip files, thumbnails, and camera indexes for every camera. The on-device library is left intact. Connected, the gallery reloads from the camera; favorites of remote-only shots are rebuilt only if those shots are still on the card."
            ),
            account: accountSource, support: supportSource,
            information: .init(
                theme: "Charcoal", protocolName: "PTP / PTP-IP",
                version: MonitorSettingsAppInformation.version(),
                themeHelp:
                    "Charcoal field-monitor chrome with gold accents, tuned for low reflection on set.",
                protocolHelp:
                    "Camera control speaks standard PTP over USB and PTP-IP over Wi-Fi; no vendor SDK is bundled or required.",
                versionHelp: MonitorSettingsCopy.versionHelp(app: "OpenZCine")),
            gyro: .init(
                enabled: Binding(
                    get: { model.gyroCapture.enabled }, set: { model.setGyroCaptureEnabled($0) }),
                status: model.gyroCapture.failure ?? model.gyroCapture.statusText,
                openLogs: model.gyroCapture.openLogs,
                mountName: model.gyroCapture.mountName,
                configureMount: model.gyroCapture.openMount)
        )
    }

    private func settingsFeedback() {
        OperatorSettingsHaptics.selection(enabled: model.preferences.hapticsEnabled)
    }
    private func preferenceBinding(_ keyPath: WritableKeyPath<OperatorPreferences, Bool>)
        -> Binding<Bool>
    {
        Binding(
            get: { model.preferences[keyPath: keyPath] },
            set: { model.preferences[keyPath: keyPath] = $0 })
    }
    private var selectableVideoSources: [VideoSourceKind] {
        VideoSourceKind.operatorSelectableCases.filter {
            $0 != .hdmiCapture || UVCVideoSource.isSupportedHardware
        }
    }
    private var linkSource: MonitorSettingsLinkSource {
        .init(
            transport: transportLabel,
            transportHelp:
                "Transport is selected on the connection screen; USB-C and Wi-Fi are exclusive for the current session.",
            phase: model.connection.label,
            phaseHelp: "The current connection state reported by this device.",
            network: nil, networkHelp: "", signalBars: model.liveSignalBars,
            saved: model.savedCameras.map {
                .init(id: $0.host, name: $0.displayName, detail: $0.host)
            },
            savedHelp: "Cameras paired through the connection screen.",
            processing: .init(
                upscaler: Binding(
                    get: { FeedUpscaleSwitch.shared.upscaler },
                    set: { FeedUpscaleSwitch.shared.upscaler = $0 }),
                feedback: settingsFeedback, rows: processingRows),
            sourceGroups: sourceGroups,
            healthScore: model.linkHealth, healthCaption: linkHealthCaption)
    }
    private func choice(
        id: String, title: String, help: String, options: [String], value: String,
        compact: Bool = false, select: @escaping (String) -> Void
    ) -> MonitorSettingsSourceProperty {
        let identity = model.operatorLiveIdentity
        return .init(
            id: id, title: title, help: help,
            value: .choice(
                .init(
                    options: options,
                    selection: Binding(
                        get: { value },
                        set: { if model.operatorLiveIdentity == identity { select($0) } }),
                    help: help, feedback: settingsFeedback)), compact: compact)
    }
    private var sourceGroups: [MonitorSettingsSourceGroup] {
        var groups: [MonitorSettingsSourceGroup] = []
        var source: [MonitorSettingsSourceProperty] = []
        if selectableVideoSources.count > 1, model.monitorAvailability.offersSourceSwitch {
            source.append(
                choice(
                    id: "picture.source", title: "Picture Source",
                    help:
                        "Where the monitor's image comes from. HDMI shows the camera's clean output through a USB capture device — full rate, no live-view compression — while exposure, focus, record and the media browser keep working over the camera link. The AF boxes, the camera's audio meter and its timecode travel inside the live-view stream, so they leave with it.",
                    options: selectableVideoSources.map(\.title), value: model.videoSource.title
                ) { value in
                    if let kind = selectableVideoSources.first(where: { $0.title == value }) {
                        model.selectVideoSource(kind)
                    }
                })
        }
        if model.videoSource == .hdmiCapture {
            source.append(
                .init(
                    id: "picture.capture", title: "Capture Device",
                    help:
                        "The attached USB capture device, the format it is sending, and what the signal claims to be (primaries/transfer/matrix). If the picture shows the device's own \"No Signal\" card while this still reads a healthy rate, the camera's HDMI output resolution is one the device cannot lock onto — 4K is the usual culprit, and 1080p is the safe choice. Set the camera to a clean output too, or its overlays arrive as part of the picture. And if the image looks flat or green-tinted next to the camera's own live view, the camera is sending its recording gamma (N-Log/HLG) over HDMI — apply your monitoring LUT, or set the camera's HDMI output to SDR.",
                    value: .reported(model.hdmiCaptureState.shortStatus)))
        }
        if model.videoSource == .relay {
            source.append(
                .init(
                    id: "picture.heldBy", title: "Held By",
                    help: "Which device the camera is currently taking commands from.",
                    value: .reported(
                        model.relayHoldsControl
                            ? "This device" : model.relayControlHolderName ?? "The broadcaster")))
        }
        if !source.isEmpty {
            groups.append(.init(id: "picture.source", title: "Picture Source", properties: source))
        }
        groups.append(
            .init(
                id: "picture", title: "Picture",
                properties: [
                    choice(
                        id: "picture.stream", title: "Stream Preset",
                        help:
                            "Combines Nikon live-view stream size and compression grade into three operator-facing choices.",
                        options: LiveViewStreamPreset.allCases.map(\.rawValue),
                        value: model.preferences.streamPreset.rawValue
                    ) {
                        if let preset = LiveViewStreamPreset(rawValue: $0) {
                            model.setStreamPreset(preset)
                        }
                    },
                    choice(
                        id: "picture.quality", title: "Quality Bias",
                        help:
                            "Steers the selected stream preset toward smaller frames or more image detail.",
                        options: LiveViewQualityBias.allCases.map(\.settingsLabel),
                        value: model.preferences.qualityBias.settingsLabel
                    ) { value in
                        if let bias = LiveViewQualityBias.allCases.first(where: {
                            $0.settingsLabel == value
                        }) {
                            model.setQualityBias(bias)
                        }
                    },
                ]))
        return groups
    }

    /// Z's own processing rows after the shared Feed Upscaler (A2-78): noise reduction and the
    /// debug frame capture.
    private var processingRows: [MonitorSettingsSourceProperty] {
        var processing: [MonitorSettingsSourceProperty] = []
        if LiveDenoiseSwitch.isSupportedOnThisDevice {
            if let reason = LiveDenoiseSwitch.decoderReportsUnavailable {
                processing.append(
                    .init(
                        id: "processing.denoise", title: "Feed Noise Reduction",
                        help:
                            "The noise filter turned itself off after the camera sent something it could not take. Reconnecting the camera gives it another go.",
                        value: .reported(reason)))
            } else {
                processing.append(
                    .init(
                        id: "processing.denoise", title: "Feed Noise Reduction",
                        help:
                            "Averages the live view against the frames either side of it to reduce sensor noise, which is worth having on a dim high-ISO set. It only removes grain that CHANGES between frames — the blocky structure of a compressed stream stays put — and it holds two frames back to see ahead, so the picture lags the camera slightly. The recording is never affected.",
                        value: .toggle(
                            .init(
                                value: Binding(
                                    get: { LiveDenoiseSwitch.shared.enabled },
                                    set: { LiveDenoiseSwitch.shared.enabled = $0 }),
                                help: "", feedback: settingsFeedback))))
            }
        }
        #if DEBUG
            processing.append(
                .init(
                    id: "processing.capture", title: "Capture Frames",
                    help:
                        "Debug: saves raw live-view frames to the app container, one a second, for the focus-peaking test corpus. Start it, dismiss this panel, then rack focus slowly end to end.",
                    value: .native(AnyView(LiveViewCaptureControl()))))
        #endif
        return processing
    }

    private var sharingSource: MonitorSettingsSharingSource {
        .init(
            enabled: model.videoSource != .relay,
            unavailableHelp:
                "This device is watching another device's broadcast. Sharing is done from the broadcasting device — re-sharing a received feed would stack a second encode and a second hop of delay on everyone downstream.",
            sharing: Binding(
                get: { model.isRelayBroadcasting }, set: { model.setRelayBroadcasting($0) }),
            passcode: Binding(
                get: { relayPasscodeDraft ?? model.relayHostPasscode ?? "" },
                set: { relayPasscodeDraft = $0 }),
            controlRequests: Binding(
                get: { model.preferences.relayAllowsControlRequests },
                set: { model.setRelayAllowsControlRequests($0) }),
            prioritySelection: Binding(
                get: { model.preferences.relayEncoderProfile.title },
                set: { title in
                    if let profile = RelayEncoderProfile.allCases.first(where: { $0.title == title }
                    ) {
                        model.setRelayEncoderProfile(profile)
                    }
                }), priorities: RelayEncoderProfile.allCases.map(\.title),
            help: .init(
                sharing:
                    "Serves this device's picture and the camera's readings to other devices running OpenZCine. The camera itself only ever talks to one device; this is how a second screen exists at all. Works on a shared network and directly device-to-device. Watchers should NOT join the camera's own Wi-Fi: its access point drops the monitor when a second device joins; they stay on their own network (or none) and find this broadcast in the camera list.",
                passcode:
                    "A passcode of at least four characters watchers must enter once per device before they receive anything: no picture, no readings without it. Leave empty for an open broadcast. Devices already watching keep their access until they leave.",
                controlRequests:
                    "Whether watchers may ask to drive the camera at all. Off hides the ask on their side; granting, declining and taking back stay here either way.",
                priority:
                    "Low latency is the tightest glass-to-glass path, the stance for pulling focus. Quality trades about four frames (~130 ms) for a steadier, better-looking stream: longer keyframe spacing spends the bitrate where it shows, and a deeper per-watcher window rides out network jitter instead of dropping. Changing it mid-broadcast briefly restarts the stream; watchers rejoin on their own."
            ),
            browseHelp: "Find another device's broadcast in the camera list.",
            browse: model.showSavedCameras,
            passcodeChanged: { model.setRelayWatcherPasscode($0) },
            watchers: model.captureOperatorSettingsWatchers(), unavailableTitle: "Watching",
            unavailableValue: model.cameraState.cameraName)
    }

    private var accountActions: MonitorSettingsAccountActions {
        let account = model.frameioAccount.capture()
        return .overInternetHop(
            identity: account.identity,
            isCurrent: { [weak model] in model != nil && account.isCurrent },
            connect: { [weak model] in
                guard let model else { throw CancellationError() }
                try await model.connectFrameio(captured: account)
            },
            disconnect: { [weak model] in if account.isCurrent { model?.disconnectFrameio() } },
            hop: model.internetHop, route: { [weak model] in model?.hopRoute() },
            internetFailure: MonitorSettingsCopy.accountInternetFailure)
    }
    private var accountSource: MonitorSettingsAccountSource {
        .init(
            title: "Frame.io",
            help:
                "Sign in once here and the share sheet's Frame.io option unlocks everywhere. On the camera's Wi‑Fi, signing in hops to home Wi‑Fi or cellular, signs in, then reconnects the camera. Logging out removes the stored sign-in and remembered project.",
            model: model.settingsAccount, actions: accountActions,
            readState: {
                if model.isFrameioConnected { return .signedIn }
                if !model.isFrameioConfigured { return .notConfigured }
                return model.settingsAccount.busy ? .connecting : .signedOut
            }, consentTitle: MonitorSettingsCopy.accountConsentTitle,
            consentMessage: MonitorSettingsCopy.accountConsentMessage(service: "Frame.io"),
            consentAction: MonitorSettingsCopy.accountConsentAction)
    }

    private func browserDestination(_ source: SettingsInternetDestination)
        -> MonitorSettingsBrowserDestination?
    {
        source.webURL.map {
            .init(
                id: source.id, title: source.title, url: $0,
                confirmationMessage: source.confirmationMessage)
        }
    }
    private var supportActions: MonitorSettingsSupportActions {
        let approvedAPDeparture = model.isOnCameraAccessPoint
        var preparingTitle: String?
        return .init(
            identity: ObjectIdentifier(model), isCurrent: { [weak model] in model != nil },
            requiresInternetConsent: model.isOnCameraAccessPoint,
            makeReport: { try await AppDiagnostics.shared.makeReport() },
            prepareBrowser: { [weak model] admission in
                guard let model else { return nil }
                return await model.browserHandoff.prepare(
                    route: model.hopRoute(rehostActivePanel: false),
                    admission: {
                        let admitted = admission()
                        return admitted && (approvedAPDeparture || !model.isOnCameraAccessPoint)
                    })
            },
            open: { url in
                await withCheckedContinuation { continuation in
                    openURL(url) { continuation.resume(returning: $0) }
                }
            },
            preparationChanged: { [weak model] title in
                if let title {
                    preparingTitle = title
                    model?.beginInternetDestinationPreparation(title)
                } else if let captured = preparingTitle {
                    preparingTitle = nil
                    model?.finishInternetDestinationPreparation(captured)
                }
            },
            internetFailure: MonitorSettingsCopy.browserInternetFailure(app: "OpenZCine")
        )
    }
    private var supportSource: MonitorSettingsSupportSource {
        .init(
            consent: Binding(
                get: { reliabilityOptIn },
                set: {
                    reliabilityOptIn = $0
                    ReliabilityDiagnostics.reporting.setConsent($0)
                }), available: ReliabilityDiagnostics.reporting.isAvailable,
            automaticHelp: MonitorSettingsCopy.automaticReports,
            unavailableHelp: Self.reliabilityUnavailableHelp,
            sourceHelp: "View the OpenZCine project and contribute on GitHub.",
            termsHelp: "Read the OpenZCine terms of use.",
            model: model.settingsSupport, actions: supportActions,
            links: [
                browserDestination(.support).map {
                    .init(
                        destination: $0,
                        help:
                            "Connection guides, camera controls, media workflows, and troubleshooting.",
                        actionTitle: "Open", accessibilityLabel: "Open Support")
                },
                browserDestination(.featureRequest).map {
                    .init(
                        destination: $0,
                        help: "Start an idea in the project’s feature-request discussion category.",
                        actionTitle: "Request", accessibilityLabel: "Request a Feature")
                },
            ].compactMap { $0 }, privacy: browserDestination(.privacyPolicy),
            source: browserDestination(.sourceCode), terms: browserDestination(.termsOfUse),
            reportTitle: "Report a Problem", reportActionTitle: "Report",
            diagnosticsHelp:
                "Create a local report with recent app events and Apple diagnostics. Review it before sharing.",
            report: { model.isBugReportPresented = true },
            shareReport: { AnyView(MonitorActivityShareSheet(items: [$0])) },
            deleteStoredReports: { ReliabilityDiagnostics.incidents.deleteStoredIncidents {} },
            deleteReportsHelp:
                "Removes the feed incident and session reports stored on this phone.",
            legal: .z)
    }
    private var lookLabel: String {
        switch model.assistConfiguration.selectedLUT {
        case .builtIn(let look): return look.rawValue
        case .stored(_, let name): return (name as NSString).deletingPathExtension
        }
    }
    static let reliabilityUnavailableHelp =
        "This build cannot send automatic reports. You can still share diagnostics stored on this phone."

    private var isConnected: Bool {
        model.isDemoSession || model.connection == .connected
            || model.connection == .preparingLiveView
    }
    private var linkHealthCaption: String {
        guard isConnected || model.isDemoSession else { return model.linkHealthDetail }
        let band = MonitorLinkHealthBand(score: model.linkHealth)
        let bandName =
            switch band {
            case .stable: "Stable"
            case .watch: "Watch"
            case .poor: "Poor"
            }
        return "\(model.linkHealthDetail) · \(bandName)"
    }
    private var transportLabel: String {
        if model.isDemoSession { return "Demo session" }
        guard isConnected else { return "Not connected" }
        return "\(model.activeTransportLabel ?? "Wi-Fi") active"
    }
}

/// The "Focus dial": a thin vertical drum on the live view beside the right system rail, shown
/// while an AF focus mode is active on a focus-by-wire lens. Drag up toward ∞, down toward NEAR;
/// the drum's ticks scroll with the drive so it reads like a physical focus ring, and — once a
/// full near↔∞ sweep calibrates the travel — a relative position (0 = near, 100 = ∞) is shown
/// (the camera exposes no absolute distance for AF lenses). Travel ends light their label with a
/// haptic. [verify-on-HW: pulses-per-point feel per lens]
struct MFDriveVerticalScrub: View {
    @Environment(NativeAppModel.self) private var model
    @State private var lastDragY: CGFloat?
    @State private var isDragging = false

    /// Drag-to-pulse gain at the slow end of the ramp.
    ///
    /// Was 4, which a real video pull found too coarse to trim focus with: at 4, and with the
    /// speed ramp reaching ×3 after only a 12pt/frame move, a careful nudge already moved the lens
    /// further than the operator wanted. 2 makes a slow drag genuinely fine and keeps the flick
    /// useful — see `speedRampDivisor`.
    ///
    /// ponytail: this is a calibration knob, not a derived constant. It is tuned against how a
    /// focus-by-wire lens actually travels, which no test can tell us — raise it if a full sweep
    /// cannot cross the range on a real body, lower it if trimming still overshoots.
    private static let pulsesPerPoint = 2
    /// Points of per-frame travel that buy one extra multiple of gain, up to `maxSpeedFactor`.
    /// Larger divisor = the ramp needs a more deliberate flick, so slow drags stay in the fine band.
    private static let speedRampDivisor: CGFloat = 14
    private static let maxSpeedFactor: CGFloat = 4
    /// Drum geometry: one tick every `pulsesPerTick` pulses, `tickSpacing` points apart.
    private static let tickSpacing: CGFloat = 11
    private static let pulsesPerTick: CGFloat = 220

    /// Pulses for one drag frame. Extracted so the gain curve is unit-testable — the sensitivity
    /// is the whole point of this control and a real pull found the old curve too coarse.
    static func pulses(forDelta delta: CGFloat) -> Int {
        let speedFactor = min(1 + abs(delta) / speedRampDivisor, maxSpeedFactor)
        return Int(delta * CGFloat(pulsesPerPoint) * speedFactor)
    }

    var body: some View {
        VStack(spacing: 5) {
            Text("∞")
                .foregroundStyle(model.mfDriveAtEnd == 1 ? LiveDesign.accent : LiveDesign.muted)
            drum
                .frame(width: 30)
                .frame(maxHeight: .infinity)
            Text("NEAR")
                .foregroundStyle(model.mfDriveAtEnd == -1 ? LiveDesign.accent : LiveDesign.muted)
            if let fraction = model.mfDriveDialFraction {
                Text("\(Int((fraction * 100).rounded()))")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(LiveDesign.text)
            }
        }
        .font(.system(size: 9, weight: .semibold, design: .monospaced))
        .padding(.vertical, 10)
        .padding(.horizontal, 6)
        .liquidGlass(in: Capsule())
        // AF-F re-focuses continuously, so a pull is overridden as fast as it lands. Drawn dimmed
        // and inert rather than hidden: the dial disappearing when the operator changes focus mode
        // reads as a bug, while a greyed one says "wrong mode for this", which is the truth.
        .opacity(model.mfDriveScrubIsInert ? 0.55 : 1)  // matches the Android strip
        .allowsHitTesting(!model.mfDriveScrubIsInert)
        .accessibilityHint(
            model.mfDriveScrubIsInert
                ? "Unavailable in AF-F. The camera refocuses continuously in this mode." : ""
        )
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { value in
                    isDragging = true
                    let delta = (lastDragY ?? value.startLocation.y) - value.location.y
                    lastDragY = value.location.y
                    // Upward drag drives toward infinity. Ring-like speed response: a slow drag
                    // steps finely, a deliberate flick multiplies travel.
                    model.driveManualFocus(
                        pulses: Self.pulses(forDelta: delta))
                }
                .onEnded { _ in
                    lastDragY = nil
                    isDragging = false
                }
        )
        .sensoryFeedback(.impact(weight: .medium), trigger: model.mfDriveAtEnd) { _, end in
            end != nil
        }
        // Re-arm the relative position each time the dial appears (new lens/mode/session).
        .onAppear { model.resetMFDriveDial() }
    }

    /// The scrolling tick drum with a fixed centre reference line marking the current position.
    private var drum: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                Capsule()
                    .fill(Color.white.opacity(isDragging ? 0.14 : 0.06))
                    .overlay(
                        Capsule().strokeBorder(
                            isDragging ? LiveDesign.accent.opacity(0.7) : LiveDesign.hairline,
                            lineWidth: 1))
                Canvas { ctx, canvas in
                    let mid = canvas.height / 2
                    let current = CGFloat(model.mfDriveNetPulses) / Self.pulsesPerTick
                    let span = Int(mid / Self.tickSpacing) + 2
                    let base = Int(current.rounded())
                    for offset in -span...span {
                        let index = base + offset
                        let y = mid - (CGFloat(index) - current) * Self.tickSpacing
                        guard y >= 0, y <= canvas.height else { continue }
                        let major = index % 5 == 0
                        let w = (major ? 0.72 : 0.4) * canvas.width
                        let rect = CGRect(
                            x: (canvas.width - w) / 2, y: y, width: w, height: major ? 1.5 : 1)
                        ctx.fill(
                            Path(rect),
                            with: .color(.white.opacity(major ? 0.5 : 0.28)))
                    }
                }
                // Fixed centre line = the current focus position.
                Rectangle()
                    .fill(LiveDesign.accent.opacity(0.95))
                    .frame(width: isDragging ? 26 : 20, height: 2)
                    .position(x: size.width / 2, y: size.height / 2)
            }
            .animation(.easeOut(duration: 0.12), value: isDragging)
        }
    }
}

#if DEBUG
    /// Debug trigger for the focus-peaking frame corpus.
    ///
    /// Polls `DemoHarness` rather than being pushed to, so the capture path stays lock-only and
    /// never hops to the main actor once a second while the stream is running. Polling only ticks
    /// while this row is on screen.
    private struct LiveViewCaptureControl: View {
        @State private var status: String?

        var body: some View {
            HStack(spacing: 10) {
                if let status {
                    Text(status)
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(LiveDesign.muted)
                        .lineLimit(1)
                }
                MonitorSettingsActionPill(title: status == nil ? "Start" : "Restart") {
                    DemoHarness.startLiveViewCapture()
                    status = DemoHarness.liveViewCaptureStatus()
                }
            }
            .task {
                while !Task.isCancelled {
                    status = DemoHarness.liveViewCaptureStatus()
                    try? await Task.sleep(for: .milliseconds(400))
                }
            }
        }
    }
#endif

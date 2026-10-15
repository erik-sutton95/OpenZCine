import MonitorPresentation
import MonitorUI
import Observation
import OpenCineAppKit
import OpenCineApple
import OpenCineCameraControls
import OpenCineMedia
import OpenZCineCore
import SwiftUI

import class OpenCineCameraVocabulary.CustomLUTStore

/// The approved palette defaults, with the between-shots PLAY and EV leading the photo toolset.
let nikonAssistUsageSeed = MonitorToolUsage.fieldMonitorSeed.merging(["PLAY": 8, "EV": 7]) { $1 }

extension NativeAppModel {
    /// The live palette for this camera: every display tool, plus PLAY and the camera EV meter
    /// in photography. Display tools never depend on the capture mode (A1-19).
    var liveAssistPaletteTools: [MonitorAssistTool] {
        let photography = StillCapturePolicy.prefersPhotographyChrome(
            selector: cameraPropertySnapshot.captureSelector)
        return MonitorAssistTool.activeCases.filter { photography || !$0.isPhotographyOnly }
    }

    /// Playback drops the camera-fed tools: the horizon and the EV needle need a camera, and PLAY
    /// reviews a capture.
    var playbackAssistPaletteTools: [MonitorAssistTool] {
        MonitorAssistTool.activeCases.filter { $0 != .level && !$0.isPhotographyOnly }
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
            NikonLUTPicker()
        case .crosshair:
            Text("Tap the palette button to show or hide the centre crosshair.")
                .font(.system(size: 13))
                .foregroundStyle(LiveDesign.muted)
        case .mirror:
            MonitorMirrorMenu(
                horizontal: model.assist.binding(\.mirrorHorizontal),
                vertical: model.assist.binding(\.mirrorVertical),
                explanation: MirrorAssist.explanation,
                horizontalHelp: MirrorAssist.horizontalHelp,
                verticalHelp: MirrorAssist.verticalHelp, feedback: selectionFeedback)
        case .audioMeters, .evMeter, .magnification:
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
                    options: MonitorReviewDuration.allCases.map(\.label),
                    selected: MonitorReviewDuration.fromSeconds(
                        model.assistConfiguration.instantReviewSeconds
                    ).label
                ) { label in
                    model.assistConfiguration.instantReviewSeconds =
                        MonitorReviewDuration.allCases.first { $0.label == label }?.rawValue ?? 5
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

    private func selectionFeedback() {
        OperatorSettingsHaptics.selection(enabled: model.preferences.hapticsEnabled)
    }
}

/// Captured native picture/effects facts. A retained displayed raster alone is not a new source.
struct NikonInspectorImageMeaning: Equatable {
    let source: MonitorOperatorLiveIdentity
    let presentation: UUID
    let tool: MonitorAssistTool
    let effects: LiveImageEffects
    let lutRevision: String?
    let mirrored: Bool
    let flipped: Bool
    let desqueeze: Double
    let desqueezeHorizontal: Bool
}

extension NativeAppModel {
    func nativeInspectorMeaning(tool: MonitorAssistTool) -> NikonInspectorImageMeaning? {
        guard assist.configureTool == tool.selection, assist.inspectorSceneActive,
            !assist.liveCovered, !assist.gradesClip, !interfaceLocked, chromeEditorMode == nil,
            activePanel == nil, displayMode != .command, nativeInspectorFrame != nil
        else { return nil }
        let effects = inspectorImageEffects(tool: tool)
        return .init(
            source: operatorLiveIdentity, presentation: operatorQuickPresentationRevision,
            tool: tool, effects: effects,
            lutRevision: effects.lut.map { LUTCubeCache.versionedKey(forKey: $0.cacheKey) },
            mirrored: tool == .mirror && assist.mirrorHorizontal,
            flipped: tool == .mirror && assist.mirrorVertical,
            desqueeze: tool == .desqueeze ? assist.desqueezeFactor : 1,
            desqueezeHorizontal: assist.desqueezeHorizontal)
    }
}

/// One bounded job across closing, tab changes and reopening. The app's renderer preserves the
/// Nikon calibration; shared admission owns cadence and keeps retired work occupying its slot.
@MainActor @Observable final class NikonLiveInspectorPreview {
    @ObservationIgnored private let renderer: LiveFrameRenderer
    @ObservationIgnored private var admission = MonitorPreviewAdmission()
    @ObservationIgnored private var owner: UUID?
    @ObservationIgnored private var meaning: NikonInspectorImageMeaning?
    @ObservationIgnored private var publishedMeaning: NikonInspectorImageMeaning?
    private(set) var image: CGImage?

    init(fileStore: CustomLUTStore) { renderer = LiveFrameRenderer(fileStore: fileStore) }

    func image(matching meaning: NikonInspectorImageMeaning) -> CGImage? {
        let retained = image
        return publishedMeaning == meaning ? retained : nil
    }

    func synchronize(_ next: NikonInspectorImageMeaning?) {
        guard meaning != next else { return }
        meaning = next
        if let owner { admission.invalidate(owner: owner) }
        publishedMeaning = nil
        image = nil
    }

    func run(model: NativeAppModel, tool: MonitorAssistTool) async {
        guard !Task.isCancelled else { return }
        let capturedOwner = UUID()
        owner = capturedOwner
        admission.activate(owner: capturedOwner)
        publishedMeaning = nil
        image = nil
        defer {
            admission.deactivate(owner: capturedOwner)
            if owner == capturedOwner {
                owner = nil
                meaning = nil
                publishedMeaning = nil
                image = nil
            }
        }
        while !Task.isCancelled, owner == capturedOwner {
            synchronize(model.nativeInspectorMeaning(tool: tool))
            if let meaning, let frame = model.nativeInspectorFrame,
                let ticket = admission.acquire(
                    owner: capturedOwner, nowNanoseconds: DispatchTime.now().uptimeNanoseconds)
            {
                let rendered = await renderer.renderInspectorFrame(
                    frame.image, effects: meaning.effects)
                // Keep the slot through adoption/discard, including synchronous observation callbacks.
                defer { admission.complete(ticket) }
                if !Task.isCancelled, admission.isCurrent(ticket), frame.source.isActive,
                    owner == capturedOwner, model.nativeInspectorMeaning(tool: tool) == meaning,
                    let rendered
                {
                    publishedMeaning = meaning
                    image = rendered
                }
            }
            guard !Task.isCancelled, owner == capturedOwner else { return }
            do {
                try await Task.sleep(
                    nanoseconds: MonitorPreviewAdmission.minimumIntervalNanoseconds)
            } catch { return }
        }
    }
}

/// Nikon supplies its calibrated image source and observations; the shared view owns preview UI.
struct NikonAssistInspectorPreview: View {
    @Environment(NativeAppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    let tool: MonitorAssistTool

    private var meaning: NikonInspectorImageMeaning? {
        scenePhase == .active ? model.nativeInspectorMeaning(tool: tool) : nil
    }

    private var picture: MonitorInspectorRenderedPictureSource {
        let identity = meaning.flatMap { meaning in
            model.nativeInspectorFrame.map {
                MonitorInspectorRenderedPictureSource.Identity(
                    source: ObjectIdentifier($0.source),
                    presentation: meaning.presentation)
            }
        }
        return .init(
            identity: identity,
            read: {
                guard let meaning, let image = model.nativeInspectorPreview.image(matching: meaning)
                else { return nil }
                return MonitorInspectorRenderedPicture(
                    image: image,
                    aspectMultiplier: meaning.desqueezeHorizontal
                        ? meaning.desqueeze : 1 / meaning.desqueeze,
                    mirrorHorizontal: meaning.mirrored, mirrorVertical: meaning.flipped)
            }, run: { await model.nativeInspectorPreview.run(model: model, tool: tool) })
    }

    var body: some View {
        MonitorLookInspectorPreview(
            tool: tool.selection, assist: model.assist,
            stores: model.scopePanels.operatorStores,
            haptics: .init(isEnabled: { model.preferences.hapticsEnabled }),
            picture: picture, readBundle: { model.scopeAssist },
            readAudio: { model.observedLiveAudioLevels },
            readAudioSensitivity: { model.cameraPropertySnapshot.audioSensitivity }
        )
        .onChange(of: meaning) { _, next in model.nativeInspectorPreview.synchronize(next) }
    }
}

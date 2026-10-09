import MonitorPresentation
import MonitorUI
import OpenCineAppKit
import OpenCineCameraControls
import OpenCineCore
import OpenCineMedia
import OpenZCineCore
import SwiftUI

/// Source facts and bounded body operations for the complete common monitor owner.
private enum NikonLiveReadoutKey: Hashable {
    case picker(CameraPicker)
    case storage
}

extension NativeAppModel {
    var operatorLiveIdentity: MonitorOperatorLiveIdentity {
        .init(monitor: shell.monitor?.id, camera: shell.control.snapshot?.session,
            epoch: shell.control.snapshot?.epoch, picture: videoSource.rawValue,
            pictureOwner: liveFrameSource.map(ObjectIdentifier.init))
    }
}

struct NikonMonitorShell: View {
    @Environment(NativeAppModel.self) private var model
    let context: LiveViewLayoutContext
    private typealias Readout = MonitorOperatorLiveReadout<NikonLiveReadoutKey, DisplayChromeVisibility.Section>

    private var sourceAspect: Double {
        let raw: Double
        if model.videoSource == .hdmiCapture, let image = model.liveFrameImage, image.size.height > 0 {
            raw = Double(image.size.width / image.size.height)
        } else { raw = model.isPhotographyMode ? model.cameraPropertySnapshot.photographyFeedAspect : 16 / 9 }
        return model.displayedFeedRotation.isVertical ? 1 / raw : raw
    }
    private var safeArea: MonitorSafeArea {
        .init(top: context.feedSafeArea.top, leading: context.feedSafeArea.leading,
            bottom: context.feedSafeArea.bottom, trailing: context.feedSafeArea.trailing)
    }
    private var layout: FieldMonitorLayout {
        .init(width: context.viewportWidth, height: context.viewportHeight, safeArea: safeArea,
            sourceAspect: sourceAspect, fill: model.preferences.portraitFeedAspect != .fit16x9,
            showsValues: model.chromeSectionMounts(.cameraValues), topControlInset: context.topControlInset)
    }
    private var mounted: Set<DisplayChromeVisibility.Section> {
        let rail = model.monitorSideRailPlan
        var value = Set(DisplayChromeVisibility.Section.allCases.filter { model.chromeSectionMounts($0) })
        for section in [DisplayChromeVisibility.Section.batteryIndicators, .lockButton, .railSettings,
            .railMedia, .railRecord, .railDisp] {
            if model.railControlMounts(section, plan: rail) { value.insert(section) }
            else { value.remove(section) }
        }
        return value
    }
    private var readouts: [Readout] {
        let values = model.isPhotographyMode ? model.cameraPropertySnapshot.photographyCaptureValues : model.shownCameraValues
        return values.compactMap { value in
            guard let picker = CameraPicker.forValueLabel(value.label, photography: model.isPhotographyMode) else { return nil }
            // The shutter's lock and angle/speed circuits use the existing typed LadderSheet.
            let field = value.label == "SHUTTER" ? nil : picker.nikonControlSetting.flatMap { model.shell.control.captureField($0.key) }
            return Readout(id: .picker(picker), title: value.label, value: value.value, field: field,
                accessibilityIdentifier: picker.nikonControlSetting.map { "monitor.capture." + $0.key.rawValue } ?? "")
        }
    }
    private var status: MonitorOperatorLiveStatus<NikonLiveReadoutKey, DisplayChromeVisibility.Section> {
        let photo = model.isPhotographyMode
        let reportedRecord = model.shell.control.session == nil
            ? (model.isDemoSession || model.videoSource == .relay ? model.isRecording : nil) : model.shell.control.isRecording
        let tc = model.liveTimecode
        let recording = MonitorStatusPresentation(recording: reportedRecord,
            timecode: model.cameraReportsTimecode ? String(format: "%02d:%02d:%02d", tc.hour, tc.minute, tc.second) : nil)
        var format: [Readout] = []
        if mounted.contains(.resolutionReadout) {
            format.append(.init(id: .picker(photo ? .stillSize : .resolution), title: "Format",
                value: photo ? model.stillSizeAreaDisplay ?? "--" : model.cameraState.resolutionFrameRate,
                section: .resolutionReadout))
        }
        if mounted.contains(.codecReadout) {
            format.append(.init(id: .picker(photo ? .stillQuality : .codec), title: "Codec",
                value: photo ? model.cameraPropertySnapshot.stillQualityCompactLabel ?? "--" : MonitorTextFormat.codecCompactLabel(model.cameraState.codec),
                section: .codecReadout))
        }
        let storage: Readout?
        if photo && mounted.contains(.timecodeReadout) {
            storage = .init(id: .storage, title: "Storage",
                value: model.photoPillShowsStorage ? model.mediaReadout : model.cameraPropertySnapshot.shotsRemaining.map { "\($0) SHOTS" } ?? "--",
                section: .timecodeReadout, action: { model.photoPillShowsStorage.toggle() })
        } else if mounted.contains(.mediaReadout) {
            storage = .init(id: .storage, title: "Storage", value: model.mediaReadout,
                section: .mediaReadout, action: model.toggleMediaReadout)
        } else { storage = nil }
        return .init(recording: recording, showsTimecode: !photo && mounted.contains(.timecodeReadout),
            showsRecording: !photo && mounted.contains(.recReadout), storage: storage, format: format,
            fps: mounted.contains(.fpsReadout) ? model.liveFPS : nil,
            signalBars: mounted.contains(.fpsReadout) ? model.liveSignalBars : nil, fpsSection: .fpsReadout)
    }
    private var power: [MonitorOperatorPowerReading] {
        let gauge = CameraBatteryGauge.gauge(rawBatteryLevel: model.cameraState.cameraBatteryPercent)
        return [.init(id: "phone", title: "Phone battery", camera: false,
            percent: model.cameraState.phoneBatteryPercent, warning: model.cameraState.phoneBatteryPercent <= 15,
            charging: model.phoneBatteryCharging),
            .init(id: "camera", title: "Camera battery", camera: true,
                bars: gauge == .unknown ? nil : gauge.filledBars, barCount: CameraBatteryGauge.barCount,
                warning: gauge.urgency != .nominal, exhausted: gauge.pulses, charging: model.cameraBatteryCharging)]
    }
    private var panel: MonitorOperatorCameraPanel<NikonLiveReadoutKey>? {
        guard case .picker(let picker) = model.activePanel else { return nil }
        return .init(key: .picker(picker), top: picker.isTopBar,
            chrome: picker.usesLadderSheet ? .sharedSheet : .content,
            title: picker == .stabilization ? "VR / E-VR" : picker.valueLabel,
            subtitle: model.pickerSubtitle(for: picker))
    }
    private var haptics: OperatorHaptics { .init(isEnabled: { [weak model] in model?.preferences.hapticsEnabled == true }) }
    private var assists: MonitorOperatorLiveAssistSource {
        .init(stores: model.scopePanels.operatorStores,
            looks: .init(scaleHelp: "The reported source selects its exposure curve.", rec709LookCurve: { _ in nil }),
            haptics: haptics, readBundle: {
                var value = model.scopeAssist
                value.levelAxis = model.exposureSignalMapping.scopeLevelAxis
                return value
            }, readTransfer: { model.scopeAssist.transfer }, readClipByte: { _ in model.scopeAssist.clipByte },
            audioAvailable: model.monitorAvailability.audioMeters,
            configurableTools: Set(model.liveAssistPaletteTools.filter { !model.isScopeCapBlocked($0) }.map(\.selection)),
            optionsUnavailableNotice: model.scopeCapNoticeText, paradeIntensityScale: 0.25)
    }
    private var bodyViews: MonitorOperatorBodyViews {
        .init(focusDrive: model.showsMFDriveScrub ? AnyView(MFDriveVerticalScrub()) : nil,
            dashboard: AnyView(NikonCommandDashboard(layout: layout)), connection: connectionControl,
            comparison: LUTResolution.showsSplitComparisonKey(visibleTools: model.renderedLiveAssistTools, enabled: model.assist.splitComparison)
                ? AnyView(SplitComparisonKey()) : nil,
            resetFocus: mounted.contains(.focusBox) && model.isFocusResetAvailable ? (model.resetFocusPoint as () -> Void) : nil)
    }
    private var connectionControl: AnyView? {
        if model.videoSource == .relay, model.relayHoldsControl || model.relayAllowsControlRequests { return AnyView(WatcherControlKey()) }
        if model.relayControlSurrendered { return AnyView(BroadcasterControlKey()) }
        return nil
    }

    var body: some View {
        @Bindable var model = model
        let layout: FieldMonitorLayout = self.layout
        let identity = model.operatorLiveIdentity
        let menus = NikonAssistMenuAdapter(model: model, compact: false)
        MonitorOperatorDescriptorLiveSurface(host: model, control: model.shell.control, identity: identity,
            current: { [weak model] in model?.operatorLiveIdentity == $0 }, layout: layout, safeArea: safeArea, sourceAspect: sourceAspect,
            sections: .init(status: .statusBar, power: .batteryIndicators, capture: .cameraValues,
                assists: .assistToolbar, lock: .lockButton, settings: .railSettings, media: .railMedia, record: .railRecord, display: .railDisp),
            mounted: mounted, editing: model.chromeEditorMode,
            locked: Binding(get: { model.interfaceLocked }, set: { _ in model.toggleInterfaceLock() }),
            covered: model.activePanel?.coversFullScreen == true, clean: model.displayMode == .clean,
            command: model.displayMode == .command, readOnly: model.relayControlSurrendered,
            recovering: model.sessionRecovery.isRecovering, status: status, power: power, readouts: readouts,
            panel: panel, open: { key in if case .picker(let picker) = key { model.showPicker(picker) } },
            dismiss: { if model.activePanel?.coversFullScreen == false { model.dismissActivePanel() } },
            settings: { model.activePanel = .settings }, media: model.openMediaBrowser,
            cycleDisplay: model.cycleDisplayMode, displayTitle: model.displayMode.title,
            displayIndex: model.displayOrder.firstIndex(of: model.displayMode), displayCount: model.displayOrder.count,
            photo: model.isPhotographyMode, confirmRecord: model.preferences.recordConfirmationEnabled,
            externalRecord: model.shell.control.session == nil ? .init(recording: model.isDemoSession || model.videoSource == .relay ? model.isRecording : nil,
                confirmation: model.pendingRecordConfirmation, request: model.toggleRecording,
                cancel: model.cancelRecordToggle, confirm: model.confirmRecordToggle) : nil,
            assist: model.assist, tools: model.liveAssistPaletteTools.map(\.selection), usage: $model.assistToolUsage,
            toggleTool: { if let tool = MonitorAssistTool(rawValue: $0.rawValue) { model.toggleAssist(tool, context: .liveView) } },
            assistSource: assists, signalOptions: .init(falseColor: AnyView(menus.falseColor), zebra: AnyView(menus.zebra),
                reference: menus.falseColorReference, level: AnyView(NikonAssistOptions(tool: .level)),
                instantReview: AnyView(NikonAssistOptions(tool: .instantReview))),
            readAudio: { model.monitorAvailability.audioMeters ? model.observedLiveAudioLevels : nil },
            fittedScopes: model.renderedFitScopes.map(\.selection), renderedTools: Set(model.renderedLiveAssistTools.map(\.selection)),
            usageSeed: nikonAssistUsageSeed, cameraViews: bodyViews, retireEditor: model.displaySession.retireEditor,
            returnToStage: model.isMulticamLiveView ? (model.returnToMulticam as () -> Void) : nil,
            notice: model.monitorNotice, noticeRevision: model.monitorNoticeTrigger,
            onCaptureFrame: { if model.operatorLiveIdentity == identity { model.captureBarFrame = $0 } },
            picture: {
                GeometryReader { picture in
                    LiveFeedModule(viewportWidth: picture.size.width, fixedContentHeight: picture.size.height)
                        .opacity(model.displayMode == .command ? 0 : 1)
                        .allowsHitTesting(model.chromeEditorMode == nil && !model.interfaceLocked && model.displayMode != .command)
                }.transaction { $0.animation = nil }
            }, cameraPanel: { key in
                if case .picker(let picker) = key { NikonCameraSettingExtension(picker: picker) }
            }, photoRelease: { NikonPhotoRelease(diameter: Double($0)) }, preview: { _ in EmptyView() },
            lookMenu: { LUTPickerContent() })
            .overlay { MonitorRecoveryOverlay() }
            .frame(width: context.viewportWidth, height: context.viewportHeight, alignment: .topLeading)
            .onChange(of: layout.portrait, initial: true) { _, value in model.monitorIsPortrait = value }
            .onChange(of: model.activePanel) { _, panel in
                // Compatibility callers still presenting a native assist route feed the same shared inspector.
                if case .assist(let tool) = panel { model.activePanel = nil; model.assist.configureTool = tool.selection }
            }
    }
}

/// Each extension is one native property domain. Common popup placement and lifecycle live above it.
private struct NikonCameraSettingExtension: View {
    let picker: CameraPicker
    var body: some View {
        if picker == .stillQuality { QualityPickerPanel(embedded: true) }
        else if picker == .stabilization { StabilizationPickerPanel() }
        else if picker.usesLadderSheet { LadderPickerPanel(picker: picker, chromeless: true) }
        else { PickerPanel(picker: picker, embedded: true) }
    }
}

/// Lens, camera health and reorderable body tiles are a coherent native dashboard.
private struct NikonCommandDashboard: View {
    let layout: FieldMonitorLayout
    var body: some View {
        VStack(spacing: 12) {
            CommandHealthStrip()
            HStack(alignment: .top, spacing: 12) {
                CommandPrimaryGrid(availableHeight: max(44, layout.picture.height - 72))
                CommandSideColumn().frame(width: max(160, layout.picture.width * 0.27))
            }
        }
    }
}

/// Nikon still release keeps finger-down/finger-up, burst/timer and body-trigger feedback.
/// A remote relay or SIMULATED demo has its own bounded command adapter during migration.
private struct NikonPhotoRelease: View {
    @Environment(NativeAppModel.self) private var model
    let diameter: Double
    @GestureState private var shutterHeld = false
    @State private var pressedSource: MonitorOperatorLiveIdentity?
    @State private var bodyShutterFlash = false
    var body: some View {
        let source = model.operatorLiveIdentity
        Group {
            if model.isPhotographyMode {
                PhotographyShutterButton(
                    isCapturing: model.isStillCapturing, countdown: model.stillTimerRemaining,
                    timerArmed: model.photoTimerDelaySeconds > 0
                )
                .scaleEffect(diameter / MonitorSideRailControlLayout.recordButtonSize)
                .scaleEffect(shutterHeld ? 0.93 : bodyShutterFlash ? 0.88 : 1)
                .contentShape(Circle())
                .gesture(
                    DragGesture(minimumDistance: 0).updating($shutterHeld) { _, held, _ in
                        held = true
                    }
                )
                .onChange(of: shutterHeld) { _, held in
                    if held {
                        guard model.operatorLiveIdentity == source else { return }
                        pressedSource = source
                        model.shutterButtonPressed()
                    } else {
                        let pressed = pressedSource
                        pressedSource = nil
                        if let pressed, model.operatorLiveIdentity == pressed {
                            model.shutterButtonReleased()
                        }
                    }
                }
                .onChange(of: source) { _, value in
                    if pressedSource != value { pressedSource = nil }
                }
                .onChange(of: model.bodyShutterPulse) { _, _ in
                    bodyShutterFlash = true
                    Task {
                        try? await Task.sleep(for: .milliseconds(130))
                        bodyShutterFlash = false
                    }
                }
                .accessibilityAction { if model.operatorLiveIdentity == source { model.captureStill() } }
                .accessibilityIdentifier("monitor.system.shutter")
            }
        }.opacity(model.relayControlSurrendered ? 0.4 : 1).allowsHitTesting(
            !model.relayControlSurrendered)
    }
}

struct SplitComparisonKey: View {
    @Environment(NativeAppModel.self) private var model

    var body: some View {
        Button {
            model.splitComparisonMuted.toggle()
            OperatorSettingsHaptics.selection(enabled: model.preferences.hapticsEnabled)
        } label: {
            Text("50/50")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(model.splitComparisonMuted ? LiveDesign.muted : LiveDesign.accent)
                .frame(width: 44, height: 30)
                .background(.black.opacity(0.55), in: Capsule())
                .overlay(
                    Capsule().strokeBorder(
                        model.splitComparisonMuted
                            ? LiveDesign.hairline : LiveDesign.accentDim, lineWidth: 1))
        }
        .buttonStyle(.monitorTapTarget)
        // Interactive glass ripples past the Button's real hit-test; every small round control
        // here carries this for the same reason.
        .minTapTarget()
        .accessibilityLabel("50/50 comparison")
        .accessibilityValue(model.splitComparisonMuted ? "Hidden" : "Shown")
    }
}

import MonitorPresentation
import MonitorUI
import OpenCineAppKit
import OpenCineCore
import OpenZCineCore
import SwiftUI

/// Nikon fills bounded property, photography and native renderer slots in the common monitor.
/// Shared AppKit owns the screen tree and shared presentation owns every common chrome frame.
struct NikonMonitorShell: View {
    @Environment(NativeAppModel.self) private var model
    let context: LiveViewLayoutContext
    @State private var railExpanded = false

    /// The palette folds away under the lock, an open panel, clean view or the chrome editor.
    private var paletteCollapses: Bool {
        model.interfaceLocked || model.activePanel != nil || model.displayMode == .clean
            || model.chromeEditorMode != nil
    }

    private var sourceAspect: Double {
        let raw: Double
        if model.videoSource == .hdmiCapture, let image = model.liveFrameImage,
            image.size.height > 0
        {
            raw = Double(image.size.width / image.size.height)
        } else {
            raw =
                model.isPhotographyMode
                ? model.cameraPropertySnapshot.photographyFeedAspect : 16 / 9
        }
        return model.displayedFeedRotation.isVertical ? 1 / raw : raw
    }

    private var layout: FieldMonitorLayout {
        FieldMonitorLayout(
            width: context.viewportWidth, height: context.viewportHeight,
            safeArea: MonitorSafeArea(
                top: context.feedSafeArea.top, leading: context.feedSafeArea.leading,
                bottom: context.feedSafeArea.bottom, trailing: context.feedSafeArea.trailing),
            sourceAspect: sourceAspect, fill: model.preferences.portraitFeedAspect != .fit16x9,
            showsValues: model.chromeSectionMounts(.cameraValues),
            topControlInset: context.topControlInset)
    }

    var body: some View {
        let layout = layout
        let editing = model.chromeEditorMode
        MonitorScreen(
            control: model.shell.control, layout: layout, sourceAspect: sourceAspect,
            presentation: MonitorScreenPresentation(
                visible: model.activePanel?.coversFullScreen != true,
                interactive: editing == nil,
                statusMounted: model.chromeSectionMounts(.statusBar),
                powerMounted: model.railControlMounts(
                    .batteryIndicators, plan: model.monitorSideRailPlan),
                captureMounted: model.chromeSectionMounts(.cameraValues)
                    && model.displayMode != .command,
                captureInteractive: model.activePanel == nil,
                locked: model.interfaceLocked, popupInteractive: editing == nil,
                capturePresented: model.activePanel?.coversFullScreen == false,
                recovering: model.sessionRecovery.isRecovering)
        ) {
            // Geometry supplied by MonitorCanvas is already fitted/cropped. The native adapter
            // has no viewport placement authority and stays mounted even in command display.
            GeometryReader { picture in
                LiveFeedModule(
                    safeArea: .zero, viewportWidth: picture.size.width, canvasOffsetX: 0,
                    fixedContentHeight: picture.size.height, sharedPictureGeometry: true
                )
                .opacity(model.displayMode == .command ? 0 : 1)
                .allowsHitTesting(
                    editing == nil && !model.interfaceLocked && model.displayMode != .command)
            }
            .transaction { $0.animation = nil }
        } assists: {
            EmptyView()
        } signal: {
            EmptyView()
        } status: {
            NikonMonitorStatus(layout: layout)
                .chromeEditable(.statusBar, editing: editing)
                .liveViewGuideAnchor(.infoBar)
        } power: {
            NikonMonitorPower(horizontal: layout.portrait && !layout.tablet)
                .chromeEditable(.batteryIndicators, editing: editing)
        } capture: {
            NikonCaptureControls(
                columns: layout.portrait && !layout.tablet ? (model.isPhotographyMode ? 5 : 3) : 12
            )
            .chromeEditable(.cameraValues, editing: editing)
            .liveViewGuideAnchor(.cameraControls)
        } system: {
            NikonMonitorSystem(layout: layout)
        } tools: {
            nativeTools(layout)
        } panels: {
            if let panel = model.activePanel, !panel.coversFullScreen {
                PanelHost(
                    panel: panel, chromeInsets: context.chromeInsets,
                    feedSafeArea: context.feedSafeArea, isPortrait: context.isPortrait)
            }
        } cover: {
            MonitorFullScreenPanelOverlay(context: context)
        } recovery: {
            MonitorRecoveryOverlay()
        }
        .coordinateSpace(name: ChromeEditSpace.name)
        .overlayPreferenceValue(ChromeEditBoundsKey.self) { boxes in
            if let mode = editing {
                ChromeEditBadgeLayer(
                    mode: mode, boxes: boxes,
                    viewport: CGSize(width: layout.viewport.width, height: layout.viewport.height))
            }
        }
        .overlay(alignment: .bottom) {
            if let mode = editing {
                ChromeEditBanner(mode: mode).padding(.bottom, max(16, context.feedSafeArea.bottom))
            } else if !model.monitorNotice.isEmpty {
                MonitorToast(text: model.monitorNotice, trigger: model.monitorNoticeTrigger)
                    .padding(.bottom, layout.viewport.height - layout.picture.maxY + 16)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: context.viewportWidth, height: context.viewportHeight, alignment: .topLeading)
        .offset(x: context.canvasOffsetX)
        .onChange(of: layout.portrait, initial: true) { _, portrait in
            model.monitorIsPortrait = portrait
        }
    }

    /// Native scopes, focus and unique camera tools remain adapters until the runtime slice.
    /// Their bounds come from the shared layout, independently of common status/capture/system.
    @ViewBuilder private func nativeTools(_ layout: FieldMonitorLayout) -> some View {
        // Relay/demo still supply their actual legacy state until Z3 adopts a common binding.
        // Keep the shared lamp/border below covers, without inventing a camera observation.
        if model.shell.control.session == nil && model.isRecording { MonitorRecordingBorder() }
        if model.displayMode == .command {
            NikonCommandControls(layout: layout)
        } else {
            FeedAssistOverlayModule(
                safeArea: context.feedSafeArea, viewportWidth: context.viewportWidth,
                canvasOffsetX: 0, horizontalDirection: context.horizontalDirection,
                suppressFloatingScopes: layout.portrait && !layout.fillsPicture
            )
            .allowsHitTesting(!model.interfaceLocked)
            if layout.portrait && !layout.fillsPicture, !model.renderedFitScopes.isEmpty {
                let room = max(0, layout.values.y - layout.picture.maxY - 32)
                PortraitScopesStack()
                    .frame(width: layout.picture.width - 28, height: min(184, room))
                    .position(
                        x: layout.picture.midX, y: layout.picture.maxY + 16 + min(184, room) / 2)
            }
            if model.chromeSectionMounts(.assistToolbar) {
                let tools = model.liveAssistPaletteTools
                let (metrics, frame) = MonitorAssistPaletteLayout.fieldMonitor(
                    layout, toolCount: tools.count, safeTop: context.feedSafeArea.top)
                NikonAssistPalette(
                    tools: tools, context: .liveView, layout: metrics, expanded: $railExpanded,
                    onOptions: { model.presentAssistOptions($0) }
                )
                .chromeEditable(.assistToolbar, editing: model.chromeEditorMode)
                .liveViewGuideAnchor(.viewAssist)
                .opacity(model.interfaceLocked ? 0.4 : 1)
                .allowsHitTesting(!model.interfaceLocked)
                .position(x: frame.midX, y: frame.midY)
                // MonitorScreen draws the camera values after this slot: the expanded landscape
                // palette's lower row must cover them, as Pocket's does; panels (10) stay above.
                .zIndex(6)
                .onChange(of: paletteCollapses) { _, collapse in
                    if collapse { railExpanded = false }
                }
            }
            if model.showsMFDriveScrub {
                MFDriveVerticalScrub().frame(height: min(280, layout.viewport.height * 0.55))
                    .position(
                        x: max(layout.picture.x + 30, layout.record.x - 34), y: layout.picture.midY
                    )
                    .allowsHitTesting(!model.interfaceLocked)
            }
            if model.chromeSectionMounts(.focusBox), model.isFocusResetAvailable,
                !model.interfaceLocked, model.chromeEditorMode == nil
            {
                MonitorChromeButton(
                    "Reset focus point", size: CGSize(width: 40, height: 40),
                    action: model.resetFocusPoint
                ) {
                    Image(systemName: "dot.viewfinder")
                }.position(x: layout.focusReset.midX, y: layout.focusReset.midY)
            }
            if LUTResolution.showsSplitComparisonKey(
                visibleTools: model.renderedLiveAssistTools, enabled: model.assist.splitComparison),
                !model.interfaceLocked, model.chromeEditorMode == nil
            {
                SplitComparisonKey().position(
                    x: layout.focusReset.midX, y: layout.focusReset.midY - 50)
            }
        }
        if !model.interfaceLocked, model.chromeEditorMode == nil {
            if model.videoSource == .relay,
                model.relayHoldsControl || model.relayAllowsControlRequests
            {
                WatcherControlKey().position(x: layout.picture.midX, y: layout.values.y - 28)
            } else if model.relayControlSurrendered {
                BroadcasterControlKey().position(x: layout.picture.midX, y: layout.values.y - 28)
            }
        }
    }
}

/// Format/storage and photography telemetry are Nikon-specific values, not a second status bar.
private struct NikonMonitorStatus: View {
    @Environment(NativeAppModel.self) private var model
    let layout: FieldMonitorLayout

    private var status: MonitorStatusPresentation {
        let recording =
            model.shell.control.session == nil
            ? (model.isDemoSession || model.videoSource == .relay ? model.isRecording : nil)
            : model.shell.control.isRecording
        let tc = model.liveTimecode
        return MonitorStatusPresentation(
            recording: recording,
            timecode: model.cameraReportsTimecode
                ? String(format: "%02d:%02d:%02d", tc.hour, tc.minute, tc.second) : nil)
    }

    var body: some View {
        MonitorStatusChrome(
            layout: layout, status: status,
            showsTimecode: !model.isPhotographyMode && model.chromeSectionMounts(.timecodeReadout),
            showsRecording: !model.isPhotographyMode && model.chromeSectionMounts(.recReadout)
        ) {
            if model.isPhotographyMode, model.chromeSectionMounts(.timecodeReadout) {
                Button {
                    model.photoPillShowsStorage.toggle()
                } label: {
                    Text(
                        model.photoPillShowsStorage
                            ? model.mediaReadout
                            : model.cameraPropertySnapshot.shotsRemaining.map { "\($0) SHOTS" }
                                ?? "--")
                }.font(MonitorTheme.font(12, weight: .medium)).buttonStyle(.plain)
                    .chromeEditable(.timecodeReadout, editing: model.chromeEditorMode)
            } else if model.chromeSectionMounts(.mediaReadout) {
                Button(action: model.toggleMediaReadout) { Text(model.mediaReadout) }
                    .font(MonitorTheme.font(12, weight: .medium)).buttonStyle(.plain)
                    .chromeEditable(.mediaReadout, editing: model.chromeEditorMode)
            }
        } format: {
            HStack(spacing: 8) {
                if model.chromeSectionMounts(.resolutionReadout) {
                    readout(
                        model.isPhotographyMode ? .stillSize : .resolution,
                        value: model.isPhotographyMode
                            ? model.stillSizeAreaDisplay ?? "--"
                            : model.cameraState.resolutionFrameRate
                    )
                    .chromeEditable(.resolutionReadout, editing: model.chromeEditorMode)
                }
                if model.chromeSectionMounts(.codecReadout) {
                    readout(
                        model.isPhotographyMode ? .stillQuality : .codec,
                        value: model.isPhotographyMode
                            ? model.cameraPropertySnapshot.stillQualityCompactLabel ?? "--"
                            : MonitorTextFormat.codecCompactLabel(model.cameraState.codec)
                    )
                    .chromeEditable(.codecReadout, editing: model.chromeEditorMode)
                }
            }
        } color: {
            EmptyView()
        } mode: {
            // The shared bar shows `link` only in portrait; Nikon main keeps the FPS readout in the
            // landscape bar too, behind the same Display toggle.
            fpsReadout
        } link: {
            fpsReadout
        }
    }

    @ViewBuilder private var fpsReadout: some View {
        if model.chromeSectionMounts(.fpsReadout) {
            FPSChip(fps: model.liveFPS, signalBars: model.liveSignalBars)
                .chromeEditable(.fpsReadout, editing: model.chromeEditorMode)
        }
    }

    private func readout(_ picker: CameraPicker, value: String) -> some View {
        Button {
            model.activePanel == .picker(picker)
                ? model.dismissActivePanel() : model.showPicker(picker)
        } label: {
            Text(value.replacingOccurrences(of: " · ", with: "·"))
                .font(MonitorTheme.font(12, weight: .medium)).lineLimit(1).minimumScaleFactor(0.75)
        }.buttonStyle(.plain).geometryGroup()
            .background {
                GeometryReader { proxy in
                    Color.clear.onChange(of: proxy.frame(in: .global), initial: true) { _, frame in
                        model.topBarPickerFrames[picker] = frame
                    }.onDisappear { model.topBarPickerFrames[picker] = nil }
                }
            }
    }
}

private struct NikonMonitorPower: View {
    @Environment(NativeAppModel.self) private var model
    let horizontal: Bool
    var body: some View {
        AnyLayout(
            horizontal
                ? AnyLayout(HStackLayout(spacing: 5))
                : AnyLayout(VStackLayout(alignment: .leading, spacing: 5))
        ) {
            BatteryIndicator(
                percent: model.cameraState.phoneBatteryPercent,
                deviceSystemName: "iphone", isCamera: false, isCharging: model.phoneBatteryCharging)
            BatteryIndicator(
                percent: model.cameraState.cameraBatteryPercent,
                deviceSystemName: "camera", isCamera: true, isCharging: model.cameraBatteryCharging)
        }
    }
}

private struct NikonCaptureControls: View {
    @Environment(NativeAppModel.self) private var model
    let columns: Int
    @State private var ownership = MonitorReadoutOwnership()
    @State private var preview: MonitorReadoutValue<MonitorCaptureField>?
    private var values: [CameraValue] {
        model.isPhotographyMode
            ? model.cameraPropertySnapshot.photographyCaptureValues : model.shownCameraValues
    }
    var body: some View {
        MonitorControlGrid(columns: columns, spacing: 6, equalColumns: columns < values.count) {
            ForEach(values) { value in
                if !model.isPhotographyMode, value.label != "SHUTTER",
                    let picker = CameraPicker.forValueLabel(value.label, photography: false),
                    let setting = picker.nikonControlSetting,
                    let field = model.shell.control.captureField(setting.key)
                {
                    common(field, picker: picker, label: value.label)
                } else {
                    CaptureSettingButton(value: value)
                }
            }
        }
        .opacity(model.relayControlSurrendered ? 0.4 : 1)
        .allowsHitTesting(!model.relayControlSurrendered)
        .contentShape(Rectangle()).onTapGesture {}
        .background {
            GeometryReader { proxy in
                Color.clear.onChange(of: proxy.frame(in: .global), initial: true) { _, frame in
                    model.captureBarFrame = frame
                }
                .onDisappear { model.captureBarFrame = .zero }
            }
        }
        .overlay(alignment: .top) {
            if let preview {
                MonitorCaptureDrum(
                    control: model.shell.control, field: preview.sourceIdentity,
                    enabled: false, haptics: false, previewPosition: preview.position,
                    previewSelection: preview.selection
                )
                .frame(width: min(360, model.captureBarFrame.width), height: 120)
                .background(MonitorTheme.canvas, in: RoundedRectangle(cornerRadius: 16))
                .offset(y: -130).allowsHitTesting(false)
            }
        }
        .onChange(of: model.interfaceLocked) { _, locked in if locked { preview = nil } }
        .onChange(of: columns) { _, _ in preview = nil }
    }

    private func common(_ field: MonitorCaptureField, picker: CameraPicker, label: String)
        -> some View
    {
        MonitorCaptureReadout(
            control: model.shell.control, field: field,
            enabled: !model.interfaceLocked && !model.relayControlSurrendered
                && model.activePanel == nil,
            active: model.activePanel == .picker(picker), ownership: $ownership,
            presentationOwner: { preview?.id },
            admission: {
                !model.interfaceLocked && !model.relayControlSurrendered && model.activePanel == nil
            }
        ) { event in
            switch event {
            case .open:
                model.showPicker(picker)
            case .preview(let value):
                if ownership.owns(value.id) { preview = value }
            case .commit, .cancel: break
            }
            switch event {
            case .commit(let value, _): if preview?.id == value.id { preview = nil }
            case .cancel(let id): if preview?.id == id { preview = nil }
            default: break
            }
        }
        .accessibilityIdentifier("monitor.capture.\(picker.rawValue)")
        .background {
            GeometryReader { proxy in
                Color.clear.onChange(of: proxy.frame(in: .global), initial: true) { _, frame in
                    model.captureSettingFrames[label] = frame
                }
                .onDisappear { model.captureSettingFrames[label] = nil }
            }
        }
    }
}

private struct NikonMonitorSystem: View {
    @Environment(NativeAppModel.self) private var model
    let layout: FieldMonitorLayout
    var body: some View {
        let plan = model.monitorSideRailPlan
        let editing = model.chromeEditorMode
        MonitorSystemControls(
            layout: layout,
            visibility: MonitorSystemControlsVisibility(
                lock: model.railControlMounts(.lockButton, plan: plan),
                settings: model.railControlMounts(.railSettings, plan: plan),
                media: model.railControlMounts(.railMedia, plan: plan),
                record: model.railControlMounts(.railRecord, plan: plan),
                display: model.railControlMounts(.railDisp, plan: plan)),
            interactive: editing == nil, navigationHidden: false
        ) {
            if model.isMulticamLiveView {
                MonitorChromeButton(
                    "Return to Multicam",
                    size: CGSize(width: layout.lock.width, height: layout.lock.height),
                    action: model.returnToMulticam
                ) {
                    Image(systemName: "square.grid.2x2")
                }.accessibilityIdentifier("monitor.system.multicamReturn")
            } else {
                MonitorLockButton(
                    locked: Binding(
                        get: { model.interfaceLocked }, set: { _ in model.toggleInterfaceLock() }),
                    side: layout.lock.width
                )
                .liveViewGuideAnchor(.lock)
            }
        } settings: {
            MonitorChromeButton(
                "Open Operator Setup",
                size: CGSize(width: layout.settings.width, height: layout.settings.height)
            ) {
                model.activePanel = .settings
            } label: {
                MonitorIcon.settings
            }
            .accessibilityIdentifier("monitor.system.settings").liveViewGuideAnchor(.settings)
            .chromeEditable(.railSettings, editing: editing)
        } media: {
            MonitorChromeButton(
                "Open Media", size: CGSize(width: layout.media.width, height: layout.media.height),
                action: model.openMediaBrowser
            ) {
                // Nikon main: a photo glyph reads as "media" on the stills side; cinema keeps film.
                if model.isPhotographyMode { MonitorIcon.image } else { MonitorIcon.film }
            }.accessibilityIdentifier("monitor.system.media").liveViewGuideAnchor(.media)
                .chromeEditable(.railMedia, editing: editing)
        } record: {
            NikonCaptureAction(diameter: layout.record.width)
                .chromeEditable(.railRecord, editing: editing).liveViewGuideAnchor(.record)
        } display: {
            MonitorChromeButton(
                "Change display mode",
                size: CGSize(width: layout.display.width, height: layout.display.height),
                action: model.cycleDisplayMode
            ) {
                VStack(spacing: 3) {
                    Text("DISP").font(MonitorTheme.font(12, weight: .bold))
                    HStack(spacing: 3) {
                        ForEach(model.displayOrder) { mode in
                            Capsule().fill(
                                mode == model.displayMode ? MonitorTheme.accent : MonitorTheme.faint
                            )
                            .frame(width: 14, height: 3)
                        }
                    }
                }
            }.accessibilityIdentifier("monitor.system.display").liveViewGuideAnchor(.display)
                .chromeEditable(.railDisp, editing: editing)
        }
    }
}

/// Nikon still release keeps finger-down/finger-up, burst/timer and body-trigger feedback.
/// A remote relay or SIMULATED demo has its own bounded command adapter during migration.
private struct NikonCaptureAction: View {
    @Environment(NativeAppModel.self) private var model
    let diameter: Double
    @GestureState private var shutterHeld = false
    @State private var bodyShutterFlash = false
    var body: some View {
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
                    if held { model.shutterButtonPressed() } else { model.shutterButtonReleased() }
                }
                .onChange(of: model.bodyShutterPulse) { _, _ in
                    bodyShutterFlash = true
                    Task {
                        try? await Task.sleep(for: .milliseconds(130))
                        bodyShutterFlash = false
                    }
                }
                .accessibilityAction { model.captureStill() }
                .accessibilityIdentifier("monitor.system.shutter")
            } else if model.shell.control.session != nil {
                MonitorCaptureButton(
                    control: model.shell.control, diameter: diameter,
                    enabled: !model.relayControlSurrendered,
                    confirm: model.preferences.recordConfirmationEnabled,
                    haptics: model.preferences.hapticsEnabled, confirmationPolicy: .explicitTarget)
            } else {
                Button(action: model.toggleRecording) {
                    MonitorRecordLamp(diameter: diameter, recording: model.isRecording)
                }.buttonStyle(.plain).accessibilityIdentifier("monitor.system.record")
                    .alert(
                        model.pendingRecordConfirmation == true
                            ? "Start recording?" : "Stop recording?",
                        isPresented: Binding(
                            get: { model.pendingRecordConfirmation != nil },
                            set: { if !$0 { model.cancelRecordToggle() } })
                    ) {
                        Button("Cancel", role: .cancel, action: model.cancelRecordToggle)
                        Button(
                            model.pendingRecordConfirmation == true ? "Start" : "Stop",
                            action: model.confirmRecordToggle)
                    }
            }
        }.opacity(model.relayControlSurrendered ? 0.4 : 1).allowsHitTesting(
            !model.relayControlSurrendered)
    }
}

/// Reorderable Nikon ride-along properties in DISP 3 are a bounded integration panel.
/// Shared status, system controls and picture ownership remain outside this panel.
private struct NikonCommandControls: View {
    @Environment(NativeAppModel.self) private var model
    let layout: FieldMonitorLayout
    var body: some View {
        VStack(spacing: 12) {
            CommandHealthStrip()
            HStack(alignment: .top, spacing: 12) {
                CommandPrimaryGrid(availableHeight: max(44, layout.picture.height - 72))
                CommandSideColumn().frame(width: max(160, layout.picture.width * 0.27))
            }
        }
        .frame(
            width: max(1, layout.picture.width - 32), height: max(44, layout.picture.height - 100)
        )
        .position(x: layout.picture.midX, y: layout.picture.midY + 12)
        .opacity(model.interfaceLocked ? 0.4 : 1)
        .allowsHitTesting(!model.interfaceLocked && !model.relayControlSurrendered)
    }
}

/// Unified system-control cluster for both monitor shells: lock, DISP, record (with its
/// confirmation alert), media, and settings.
///
/// `.axisVertical` renders the landscape lock + right-rail buttons, each positioned absolutely at
/// its `slots` frame (viewport-absolute, from the zone map). `.axisHorizontal` renders the portrait
/// bottom bar row. Mounted once per orientation inside `canvasLayer` (landscape) or at the
/// `systemBar` zone (portrait).

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

/// Self-dissolving notice pill (scope cap, R7). One at a time; a new `trigger` restarts the clock.
/// Tap-through — it never intercepts touches on the toolbar beneath it.
struct MonitorToast: View {
    let text: String
    let trigger: Int
    @State private var visible = false

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(LiveDesign.text)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .liquidGlass(in: Capsule())
            .opacity(visible ? 1 : 0)
            .animation(.easeInOut(duration: 0.2), value: visible)
            .allowsHitTesting(false)
            .task(id: trigger) {
                guard trigger > 0 else { return }
                visible = true
                try? await Task.sleep(for: .seconds(2.5))
                visible = false
            }
    }
}

/// A full-screen panel (Operator Setup, Media, Tool Library) rendered on the extended
/// physical-screen layer so its opaque surface reaches the bezel. A standalone `View` (not a
/// `MonitorShell` computed property) so `LiveViewShell` constructs it directly, past its
/// `.ignoresSafeArea(.container, edges: .all)` — the one true extended-layer mount point (see
/// `MonitorShell.body`). Reading it off a sibling `MonitorShell` instance crashed: `@Environment`
/// resolves against THIS view's tree position, and a bare property getter never gets one.
struct MonitorFullScreenPanelOverlay: View {
    @Environment(NativeAppModel.self) private var model
    let context: LiveViewLayoutContext

    var body: some View {
        if let panel = model.activePanel, panel.coversFullScreen {
            GeometryReader { phys in
                PanelHost(
                    panel: panel, chromeInsets: context.chromeInsets,
                    feedSafeArea: fullScreenPanelSafeArea,
                    isPortrait: context.isPortrait
                )
                .environment(model)
                .frame(width: phys.size.width, height: phys.size.height)
            }
            .ignoresSafeArea()
            .transition(.opacity.animation(.easeInOut(duration: 0.22)))
        }
    }

    /// Insets a landscape full-screen panel should clear — zero the clean short edge so the
    /// surface hugs that bezel while clearing the Dynamic Island on the side it sits. Portrait
    /// passes the safe area straight through.
    private var fullScreenPanelSafeArea: MonitorEdgeInsets {
        guard !context.isPortrait else { return context.feedSafeArea.clearingWindowControls }
        let islandOnLeading = context.horizontalDirection != .mirrored
        return MonitorEdgeInsets(
            top: context.feedSafeArea.top,
            leading: islandOnLeading ? context.feedSafeArea.leading : 0,
            bottom: context.feedSafeArea.bottom,
            trailing: islandOnLeading ? 0 : context.feedSafeArea.trailing
        ).clearingWindowControls
    }
}

import MonitorPresentation
import MonitorUI
import OpenCineAppKit
import OpenCineCameraControls
import OpenCineCore
import OpenCineMedia
import OpenCineNikon
import OpenZCineCore
import SwiftUI

import enum OpenCineCameraVocabulary.CaptureCodecColorReadout

/// The FORMAT readout: the common recording label behind the displayed movie token's image-area
/// tag (`[FX] 6K · 25p`), as the body shows it. Kotlin twin: `nikonRecordingFormatLabel`.
func nikonRecordingFormatLabel(_ label: String?, imageArea: String?) -> String? {
    label.map { text in imageArea.map { "[\($0)] " + text } ?? text }
}

extension CaptureCodecColorReadout {
    /// Codec and colour are one popup on a Z body: both readouts open the codec picker, which
    /// carries the active codec's tones.
    var nikonPicker: CameraPicker { .codec }
}

/// Source facts and bounded body operations for the complete common monitor owner.
private enum NikonLiveReadoutKey: Hashable {
    case picker(CameraPicker)
    case storage
    /// The colour (movie tone) readout. It opens the same codec and colour popup as the codec.
    case color
}

/// A native quick gesture retains exact advertised domains and source authority.
struct NikonCaptureQuickIdentity: Hashable, Sendable {
    enum Kind: Hashable, Sendable { case format, codec }
    let source: MonitorCaptureSourceIdentity
    let authority: ControlAuthority
    let kind: Kind
    let formatRaw: [UInt64]
    let formatTokens: [String]
    let codecRaw: [UInt32]
    let codecLabels: [String]
    let formatDependency: UInt64?
    let codecDependency: String?
    let shutterMode: String?
    let shutterLocked: Bool?
    let pictureControl: String?
    let snapshot: MonitorReadoutSnapshot
    let displayedSelection: String

    var picker: CameraPicker { kind == .format ? .resolution : .codec }

    func admits(_ current: Self, target: String) -> Bool {
        source == current.source && authority == current.authority && kind == current.kind
            && formatRaw == current.formatRaw && formatTokens == current.formatTokens
            && codecRaw == current.codecRaw && codecLabels == current.codecLabels
            && formatDependency == current.formatDependency
            && codecDependency == current.codecDependency
            && shutterMode == current.shutterMode && shutterLocked == current.shutterLocked
            && pictureControl == current.pictureControl && snapshot.options.contains(target)
            && (current.snapshot.selection == snapshot.selection
                || current.snapshot.selection == target)
            && (current.displayedSelection == snapshot.selection
                || current.displayedSelection == target)
    }
}

extension NativeAppModel {
    var operatorLiveIdentity: MonitorOperatorLiveIdentity {
        .init(
            monitor: shell.monitor?.id, camera: shell.control.snapshot?.session,
            epoch: shell.control.snapshot?.epoch, picture: videoSource.rawValue,
            pictureOwner: liveFrameSource.map(ObjectIdentifier.init))
    }

    func operatorNativeQuick(for picker: CameraPicker)
        -> MonitorOperatorNativeCaptureQuick<NikonCaptureQuickIdentity>?
    {
        buildNativeQuick(for: picker, allowPending: false)
    }

    private func buildNativeQuick(for picker: CameraPicker, allowPending: Bool)
        -> MonitorOperatorNativeCaptureQuick<NikonCaptureQuickIdentity>?
    {
        // Initial gestures cannot borrow a queued selection. Admission after release ignores the
        // pending queue itself: its own drain may remove the entry before the transport predicate.
        if !allowPending {
            guard !operatorQuickHasPendingWrite(for: .resolution),
                !operatorQuickHasPendingWrite(for: .codec)
            else { return nil }
        }
        let reported = operatorQuickReportedProperties
        guard picker == .resolution || picker == .codec,
            let state = shell.control.snapshot, state.connection == .ready,
            reported.captureSelector == .video, cameraPropertySnapshot.captureSelector == .video,
            shell.control.isRecording == false,
            !interfaceLocked, !relayControlSurrendered, !sessionRecovery.isRecovering,
            chromeEditorMode == nil, activePanel == nil, !lockedControls.contains(picker),
            monitorAvailability.cameraControls
        else { return nil }
        switch state.authority {
        case .owner, .lease: break
        default: return nil
        }
        let properties = cameraPropertySnapshot
        let formatRaw = cameraScreenModes.map(\.raw)
        let formatTokens = recordingFormatPresentations.map(\.token)
        let codecRaw = cameraFileTypeModes.map(\.raw)
        let codecLabels = cameraFileTypeModes.map(\.label)
        let reportedCodecs = cameraFileTypeModes.filter {
            PTPCameraPropertyDecoders.fileType($0.raw) == reported.fileType
        }
        let displayedCodecs = cameraFileTypeModes.filter {
            PTPCameraPropertyDecoders.fileType($0.raw) == properties.fileType
        }
        guard !formatRaw.isEmpty, formatRaw.count == formatTokens.count,
            Set(formatRaw).count == formatRaw.count, Set(formatTokens).count == formatTokens.count,
            !codecRaw.isEmpty, Set(codecRaw).count == codecRaw.count,
            Set(codecLabels).count == codecLabels.count,
            let raw = reported.rawScreenSize, let formatIndex = formatRaw.firstIndex(of: raw),
            let displayedRaw = properties.rawScreenSize,
            let displayedFormatIndex = formatRaw.firstIndex(of: displayedRaw),
            reportedCodecs.count == 1, displayedCodecs.count == 1
        else { return nil }
        let codec = reportedCodecs[0]
        let displayedCodec = displayedCodecs[0]
        let kind: NikonCaptureQuickIdentity.Kind = picker == .resolution ? .format : .codec
        if !allowPending {
            guard displayedRaw == raw, displayedCodec.raw == codec.raw else { return nil }
        } else {
            // An optimistic change to the other property invalidates this command immediately.
            guard kind == .format ? displayedCodec.raw == codec.raw : displayedRaw == raw
            else { return nil }
        }
        let snapshot = MonitorReadoutSnapshot(
            title: kind == .format ? "Format" : "Codec",
            options: kind == .format ? formatTokens : codecLabels,
            selection: kind == .format ? formatTokens[formatIndex] : codec.label)
        let identity = NikonCaptureQuickIdentity(
            source: .init(
                camera: state.session, epoch: state.epoch, monitor: shell.monitor?.id,
                pictureOwner: liveFrameSource.map(ObjectIdentifier.init),
                picture: videoSource.rawValue),
            authority: state.authority, kind: kind,
            formatRaw: formatRaw,
            formatTokens: kind == .format ? formatTokens : cameraScreenModes.map(\.label),
            codecRaw: codecRaw, codecLabels: codecLabels,
            formatDependency: kind == .codec ? displayedRaw : nil,
            codecDependency: kind == .format ? properties.fileType : nil,
            shutterMode: properties.shutterMode?.rawValue,
            shutterLocked: properties.shutterLocked, pictureControl: properties.pictureControl,
            snapshot: snapshot,
            displayedSelection: kind == .format
                ? formatTokens[displayedFormatIndex] : displayedCodec.label)
        return .init(identity: identity, snapshot: snapshot, enabled: true, delayed: true)
    }

    func operatorNativeQuickIsCurrent(_ identity: NikonCaptureQuickIdentity) -> Bool {
        operatorNativeQuick(for: identity.picker)?.identity == identity
    }

    /// Own optimistic selection may advance; source, circuits and advertised domains may not.
    func operatorNativeQuickAdmits(_ identity: NikonCaptureQuickIdentity, target: String) -> Bool {
        guard let current = buildNativeQuick(for: identity.picker, allowPending: true)?.identity
        else {
            return false
        }
        return identity.admits(current, target: target)
    }
}

/// A monitor source with a picture and no camera control here: a relay watcher, a capture card
/// or the demo. The shell owns it like a camera, so `AppShell` hosts every monitor (A1-01). It
/// reports a ready, read-only link and refuses every command; closing ends it.
@MainActor
final class NikonPictureSourceSession: CameraSession {
    nonisolated let id = CameraSessionID()
    private var snapshot: CameraSnapshot
    private var subscribers: [AsyncStream<CameraSnapshot>.Continuation] = []

    init() { snapshot = CameraSnapshot(session: id, connection: .ready, authority: .readOnly) }

    func snapshots() async -> AsyncStream<CameraSnapshot> {
        let (stream, continuation) = AsyncStream<CameraSnapshot>.makeStream(
            bufferingPolicy: .bufferingNewest(1))
        continuation.yield(snapshot)
        if case .disconnected = snapshot.connection {
            continuation.finish()
        } else {
            subscribers.append(continuation)
        }
        return stream
    }
    func submit(_ command: CameraCommand) async -> CommandReceipt {
        CommandReceipt(
            operation: command.operation, session: id, intent: command.intent,
            stage: .rejected(.readOnly))
    }
    func outcome(of operation: OperationID) async -> CommandReceipt? { nil }
    func receipt(of operation: OperationID) async -> CommandReceipt? { nil }
    func close(_ reason: SessionCloseReason) async {
        if case .disconnected = snapshot.connection { return }
        snapshot.connection = .disconnected(reason)
        snapshot.revision = snapshot.revision.next()
        for subscriber in subscribers {
            subscriber.yield(snapshot)
            subscriber.finish()
        }
        subscribers.removeAll()
    }
}

struct NikonMonitorShell: View {
    @Environment(NativeAppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.monitorWindowGeometry) private var windowGeometry
    let context: LiveViewLayoutContext
    private typealias Section = MonitorDisplayChrome.Section
    private typealias Readout = MonitorOperatorLiveReadout<NikonLiveReadoutKey, Section>

    private var sourceAspect: Double {
        Self.picture(model).aspect
    }
    /// Picture facts read by the shared chrome, independently of the raster view.
    static func picture(_ model: NativeAppModel) -> MonitorOperatorLivePicture {
        let raw: Double
        if model.videoSource == .hdmiCapture, let aspect = model.liveFrameAspect {
            raw = aspect
        } else {
            raw =
                model.isPhotographyMode
                ? model.cameraPropertySnapshot.photographyFeedAspect : 16 / 9
        }
        return .init(
            aspect: model.displayedFeedRotation.isVertical ? 1 / raw : raw,
            waiting: !model.hasLiveFrameImage && !model.isDemoSession,
            vertical: model.displayedFeedRotation.isVertical, flipped: false,
            recovering: model.sessionRecovery.isRecovering)
    }
    /// The shared field-monitor geometry. Portrait fill yields to de-squeeze, as on every app.
    private var live: LiveMonitorLayout {
        let safe = context.feedSafeArea
        return .fieldMonitor(
            size: CGSize(width: context.viewportWidth, height: context.viewportHeight),
            safeArea: EdgeInsets(
                top: safe.top, leading: safe.leading, bottom: safe.bottom, trailing: safe.trailing),
            sourceAspect: sourceAspect,
            fill: model.preferences.portraitFeedAspect == .fill && model.liveDesqueeze.factor <= 1,
            showsValues: model.chromeSectionMounts(.cameraValues),
            showsBottomBars: model.chromeSectionMounts(.toolBar)
                || model.chromeSectionMounts(.cameraValues),
            topControlInset: context.topControlInset)
    }
    private var readouts: [Readout] {
        let values =
            model.isPhotographyMode
            ? model.cameraPropertySnapshot.photographyCaptureValues : model.shownCameraValues
        return values.compactMap { value in
            guard
                let picker = CameraPicker.forValueLabel(
                    value.label, photography: model.isPhotographyMode)
            else { return nil }
            // A held shutter adjusts its reported circuit. Lock controls stay in the full sheet.
            let quickEnabled =
                picker != .shutter
                || (model.cameraPropertySnapshot.shutterLocked == false
                    && model.cameraPropertySnapshot.shutterMode != nil
                    && !model.lockedControls.contains(.shutter))
            let field =
                quickEnabled
                ? picker.nikonControlSetting.flatMap { model.shell.control.captureField($0.key) }
                : nil
            let common = !model.isPhotographyMode && !model.isDemoSession && model.videoSource != .relay
                ? picker.nikonControlSetting.map { model.shell.control.captureValue($0.key, selection: .pending) } : nil
            let label = common.map { $0.map(MonitorCapturePresentation.label) ?? "--" } ?? value.value
            return Readout(
                id: .picker(picker), title: value.label, value: label, field: field,
                quickEnabled: quickEnabled,
                accessibilityIdentifier: "monitor.capture."
                    + (picker.nikonControlSetting.map(\.key.rawValue) ?? picker.rawValue))
        }
    }
    /// A relay or demo monitor has no camera control here; it forwards the host's recording state.
    private var forwardedRecording: Bool? {
        model.isDemoSession || model.videoSource == .relay ? model.isRecording : nil
    }
    private var status: MonitorOperatorLiveStatus<NikonLiveReadoutKey, Section> {
        let photo = model.isPhotographyMode
        let recordingFormat = model.shell.control.snapshot.map(MonitorCapturePresentation.recordingFormat)
        let recordingLabel = recordingFormat.flatMap(MonitorCapturePresentation.recordingLabel)
        let imageArea = model.recordingFormatPresentations.first { $0.token == model.cameraState.resolutionFrameRate }?.imageArea
        let formatLabel = nikonRecordingFormatLabel(recordingLabel, imageArea: imageArea)
        // The common session publishes the header timecode at frame precision (A5-04).
        let recording =
            model.pictureOnlyMonitor
            ? MonitorStatusPresentation(
                recording: forwardedRecording,
                timecode: model.cameraReportsTimecode ? model.liveTimecode.monitorLabel : nil,
                timecodePlaceholder: Timecode.placeholder)
            : model.shell.control.statusPresentation()
        var format: [Readout] = []
        if model.chromeSectionMounts(.format) {
            format.append(
                .init(
                    id: .picker(photo ? .stillSize : .resolution), title: "Format",
                    value: photo
                        ? model.stillSizeAreaDisplay ?? "--"
                        : model.isDemoSession || model.videoSource == .relay ? model.cameraState.resolutionFrameRate : formatLabel ?? "--",
                    section: .format))
        }
        if model.chromeSectionMounts(.codec) {
            format.append(
                .init(
                    id: .picker(photo ? .stillQuality : .codec), title: "Codec",
                    value: photo
                        ? model.cameraPropertySnapshot.stillQualityCompactLabel ?? "--"
                        : model.isDemoSession || model.videoSource == .relay ? MonitorTextFormat.codecCompactLabel(model.cameraState.codec)
                            : recordingFormat?.codec.map(MonitorTextFormat.codecCompactLabel) ?? "--",
                    section: .codec))
        }
        let storage: Readout?
        if photo && model.chromeSectionMounts(.timecode) {
            storage = .init(
                id: .storage, title: "Storage",
                value: model.photoPillShowsStorage
                    ? model.liveMediaReadout
                    : model.cameraPropertySnapshot.shotsRemaining.map { "\($0) SHOTS" } ?? "--",
                section: .timecode, action: { model.photoPillShowsStorage.toggle() })
        } else if model.chromeSectionMounts(.storage) {
            storage = .init(
                id: .storage, title: "Storage", value: model.liveMediaReadout,
                section: .storage, action: model.toggleMediaReadout)
        } else {
            storage = nil
        }
        let fps = model.chromeSectionMounts(.fps)
        // Codec and colour are one popup: the colour readout opens the codec picker.
        let color: Readout? =
            !photo && model.chromeSectionMounts(.color)
            ? .init(
                id: .color, title: "Color", value: model.movieToneReadout ?? "--", section: .color,
                accessibilityIdentifier: "monitor.capture.color")
            : nil
        return .init(
            recording: recording, showsTimecode: !photo && model.chromeSectionMounts(.timecode),
            showsRecording: !photo && model.chromeSectionMounts(.recReadout), storage: storage,
            format: format, fps: fps ? model.liveFPS : nil,
            signalBars: fps ? model.liveSignalBars : nil, fpsSection: .fps, color: color)
    }
    /// The body's coarse gauge. An unread battery is absent, never an empty red cell.
    private var cameraBattery: MonitorOperatorPowerReading? {
        .camera(
            model.cameraBatteryReading, exhausted: model.cameraBatteryExhausted,
            charging: model.cameraPowerCharging)
    }

    private var panel: MonitorOperatorCameraPanel<NikonLiveReadoutKey>? {
        guard case .picker(let picker) = model.activePanel else { return nil }
        return .init(
            key: .picker(picker), top: picker.isTopBar,
            chrome: picker.usesLadderSheet ? .sharedSheet : .content,
            title: picker == .stabilization
                ? "VR / E-VR" : picker == .codec ? model.codecColorChoices.title : picker.valueLabel,
            subtitle: model.pickerSubtitle(for: picker))
    }
    private var captureInputs:
        MonitorOperatorCaptureInputs<NikonLiveReadoutKey, Section, NikonCaptureQuickIdentity>
    {
        .init(
            readouts: readouts, panel: panel, haptics: model.preferences.hapticsEnabled,
            open: { key in
                switch key {
                case .picker(let picker): model.showPicker(picker)
                case .color: model.showPicker(CaptureCodecColorReadout.color.nikonPicker)
                case .storage: break
                }
            },
            dismiss: {
                if model.activePanel?.coversFullScreen == false { model.dismissActivePanel() }
            },
            isTop: { key in
                switch key {
                case .picker(let picker): picker.isTopBar
                case .color: CaptureCodecColorReadout.color.nikonPicker.isTopBar
                case .storage: false
                }
            },
            nativeQuick: { key in
                guard case .picker(let picker) = key else { return nil }
                return model.operatorNativeQuick(for: picker)
            },
            nativeCurrent: { key, identity in
                guard key == .picker(identity.picker) else { return false }
                return model.operatorNativeQuickIsCurrent(identity)
            },
            nativeCommit: { key, identity, value in
                guard key == .picker(identity.picker), model.operatorNativeQuickIsCurrent(identity),
                    identity.snapshot.options.contains(value)
                else { return }
                model.applyQuickPicker(identity.picker, value: value, identity: identity)
            })
    }
    private var record: MonitorOperatorRecordSource {
        .init(
            photo: model.isPhotographyMode, confirm: model.preferences.recordConfirmationEnabled,
            busy: false, openMode: nil,
            external: model.pictureOnlyMonitor
                ? .init(
                    recording: forwardedRecording, confirmation: model.pendingRecordConfirmation,
                    request: model.toggleRecording, cancel: model.cancelRecordToggle,
                    confirm: model.confirmRecordToggle) : nil)
    }
    private var source: MonitorOperatorLiveSource<NikonLiveReadoutKey, NikonCaptureQuickIdentity> {
        .init(
            identity: { model.operatorLiveIdentity }, available: { model.monitorAvailableSections },
            picture: { Self.picture(model) },
            status: { status }, cameraBattery: { cameraBattery }, capture: { captureInputs },
            record: { record },
            // The Nikon EV needle and level remain native instruments until F04 and A1-31.
            exposure: nil, level: nil,
            audio: {
                model.monitorAvailability.audioMeters
                    ? model.observedLiveAudioLevels.map { .init(levels: $0, caption: nil) } : nil
            },
            readOnly: { model.relayControlSurrendered },
            borrowed: { model.isMulticamLiveView },
            returnToStage: model.isMulticamLiveView ? (model.returnToMulticam as () -> Void) : nil,
            coverOpen: { model.activePanel?.coversFullScreen == true },
            note: Binding(get: { model.monitorNote }, set: { model.monitorNote = $0 }),
            settings: { model.activePanel = .settings }, media: model.openMediaBrowser)
    }
    /// The scope source the shared surface reads: the model's published samples and facts.
    static func assistSource(_ model: NativeAppModel) -> MonitorOperatorLiveAssistSource {
        .init(
            stores: model.scopePanels.operatorStores,
            looks: .init(
                scaleHelp: "The reported source selects its exposure curve.",
                rec709LookCurve: { _ in nil }),
            haptics: .init(isEnabled: { [weak model] in
                model?.preferences.hapticsEnabled == true
            }),
            readBundle: { model.scopeAssist }, readTransfer: { model.scopeAssist.transfer },
            readClipByte: { _ in model.scopeAssist.clipByte },
            audioAvailable: model.monitorAvailability.audioMeters,
            configurableTools: Set(model.liveAssistPaletteTools.map(\.selection)),
            paradeIntensityScale: 1)
    }
    private func assists(_ layout: FieldMonitorLayout) -> MonitorOperatorLiveAssists {
        @Bindable var model = model
        let menus = NikonAssistMenuAdapter(model: model, compact: false)
        return .init(
            scopes: Self.assistSource(model),
            tools: { model.liveAssistPaletteTools.map(\.selection) },
            rendered: {
                Set(
                    model.renderedLiveAssistTools.filter {
                        !layout.portrait || layout.fillsPicture
                            || !MonitorAssistTool.scopeTools.contains($0)
                            || model.renderedFitScopes.contains($0)
                    }.map(\.selection))
            },
            fitted: { model.renderedFitScopes.map(\.selection) },
            signalOptions: .init(
                falseColor: AnyView(menus.falseColor), zebra: AnyView(menus.zebra),
                reference: menus.falseColorReference,
                level: AnyView(NikonAssistOptions(tool: .level)),
                instantReview: AnyView(NikonAssistOptions(tool: .instantReview))),
            usage: $model.assistToolUsage, usageSeed: nikonAssistUsageSeed,
            toggle: {
                if let tool = MonitorAssistTool(rawValue: $0.rawValue) {
                    model.toggleAssist(tool, context: .liveView)
                }
            })
    }
    private func bodyViews(_ layout: FieldMonitorLayout) -> MonitorOperatorBodyViews {
        .init(
            focusDrive: model.showsMFDriveScrub ? AnyView(MFDriveVerticalScrub()) : nil,
            dashboard: AnyView(NikonCommandDashboard(layout: layout)),
            connection: connectionControl,
            comparison: LUTResolution.showsSplitComparisonKey(
                visibleTools: model.renderedLiveAssistTools, enabled: model.assist.splitComparison)
                ? AnyView(SplitComparisonKey()) : nil,
            resetFocus: model.chromeSectionMounts(.focusBox) && model.isFocusResetAvailable
                ? (model.resetFocusPoint as () -> Void) : nil,
            // Framing marks ride the picture in the camera's own orientation (FeedAlignedAssists).
            feedMarks: AnyView(EmptyView()),
            waiting: model.videoSource == .relay && model.relayFailureReason != nil
                ? AnyView(RelayJoinRecovery()) : nil)
    }
    private var connectionControl: AnyView? {
        if model.videoSource == .relay, model.relayHoldsControl || model.relayAllowsControlRequests
        {
            return AnyView(WatcherControlKey())
        }
        if model.relayControlSurrendered { return AnyView(BroadcasterControlKey()) }
        return nil
    }
    private var portraitAspect: Binding<PortraitFeedAspect> {
        Binding(
            get: { model.preferences.portraitFeedAspect },
            set: { model.preferences.portraitFeedAspect = $0 })
    }

    var body: some View {
        let live = self.live
        let layout =
            live.presentation
            ?? FieldMonitorLayout(width: context.viewportWidth, height: context.viewportHeight)
        MonitorOperatorLiveSurface(
            host: model, control: model.shell.control, session: model.operatorSession,
            layout: live, source: source, assists: assists(layout), views: bodyViews(layout),
            portraitAspect: portraitAspect,
            picture: {
                GeometryReader { picture in
                    LiveFeedModule(
                        viewportWidth: picture.size.width, fixedContentHeight: picture.size.height)
                }
            },
            cameraPanel: { key, _ in
                if case .picker(let picker) = key { NikonCameraSettingExtension(picker: picker) }
            }, photoRelease: { NikonPhotoRelease(diameter: Double($0)) },
            preview: {
                if let tool = MonitorAssistTool(rawValue: $0.rawValue),
                    MonitorInspectorPreviewPolicy.isImage($0)
                        || [
                            .waveform, .parade, .histogram, .vectorscope, .trafficLights,
                            .audioMeters,
                        ].contains(
                            tool)
                {
                    NikonAssistInspectorPreview(tool: tool)
                }
            },
            lookMenu: { NikonLUTPicker() }
        )
        .overlay { MonitorRecoveryOverlay() }
        .frame(width: context.viewportWidth, height: context.viewportHeight, alignment: .topLeading)
        .onChange(of: layout.portrait, initial: true) { _, value in model.monitorIsPortrait = value
        }
        .onChange(of: model.shell.monitor?.id, initial: true) { _, monitor in
            model.operatorSession.synchronize(source: monitor)
        }
        .onChange(of: layout) { _, _ in model.retireOperatorQuickPresentation() }
        .onChange(of: windowGeometry) { _, _ in model.retireOperatorQuickPresentation() }
        .onChange(of: scenePhase) { _, _ in model.retireOperatorQuickPresentation() }
        .onDisappear { model.retireOperatorQuickPresentation() }
        .onChange(of: model.activePanel) { _, panel in
            // Compatibility callers still presenting a native assist route feed the same shared inspector.
            if case .assist(let tool) = panel {
                model.activePanel = nil
                model.assist.configureTool = tool.selection
            }
        }
    }
}

/// Each extension is one native property domain. Common popup placement and lifecycle live above it.
private struct NikonCameraSettingExtension: View {
    let picker: CameraPicker
    var body: some View {
        if picker == .stillQuality {
            QualityPickerPanel(embedded: true)
        } else if picker == .stabilization {
            StabilizationPickerPanel()
        } else {
            LadderPickerPanel(picker: picker)
        }
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
                .accessibilityAction {
                    if model.operatorLiveIdentity == source { model.captureStill() }
                }
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

package com.opencapture.openzcine

import com.opencapture.opencine.media.recordingTimeLabel
import com.opencapture.opencine.media.storageReadout
import com.opencapture.opencine.media.StorageReadout
import com.opencapture.opencine.nikon.LiveFocusInfo
import java.util.concurrent.atomic.AtomicReference
import com.opencapture.monitorui.MonitorIcon
import com.opencapture.opencine.cameracontrols.*
import android.os.Build
import android.view.HapticFeedbackConstants
import androidx.activity.compose.BackHandler
import androidx.annotation.StringRes
import androidx.compose.foundation.background
import com.opencapture.monitorui.MonitorAssistTool
import com.opencapture.monitorui.monitorBackdropSource
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.rememberTransformableState
import androidx.compose.foundation.gestures.transformable
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.positionChange
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.absoluteOffset
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.snapshotFlow
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.layout
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.platform.LocalResources
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.onLongClick
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.tween
import androidx.compose.ui.platform.testTag
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.IntSize
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.displayCutout
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.currentStateAsState
import com.opencapture.opencine.core.SettingKey
import com.opencapture.opencine.appkit.MonitorPhotoRelease
import com.opencapture.opencine.appkit.MonitorPhotoTimer
import com.opencapture.opencine.appkit.MonitorNativeWrites
import com.opencapture.opencine.appkit.rememberPhoneBatteryReadout
import com.opencapture.opencine.appkit.MonitorBackdropActivation
import com.opencapture.opencine.appkit.MonitorControlModel
import com.opencapture.opencine.appkit.statusPresentation
import com.opencapture.opencine.appkit.MonitorCaptureField
import com.opencapture.opencine.appkit.captureField
import com.opencapture.opencine.appkit.commit
import com.opencapture.opencine.appkit.quickControl
import com.opencapture.opencine.appkit.MonitorCaptureDrum
import com.opencapture.opencine.appkit.MonitorCaptureButton
import com.opencapture.monitorui.monitorBottomInsetDp
import com.opencapture.monitorui.monitorLeadingInsetDp
import com.opencapture.monitorui.MonitorRect
import com.opencapture.monitorui.MonitorCameraValues
import com.opencapture.monitorui.MonitorValue
import com.opencapture.monitorui.MonitorSystemControls
import com.opencapture.monitorui.MonitorSystemControlsVisibility
import com.opencapture.monitorui.MonitorStatusChrome
import com.opencapture.monitorui.MonitorStatusPresentation
import com.opencapture.openzcine.bridge.AndroidLinkHealthMonitor
import com.opencapture.openzcine.bridge.AndroidLiveViewController
import com.opencapture.opencine.nikon.NikonOpenCineSession
import com.opencapture.openzcine.bridge.SwiftCore
import com.opencapture.opencine.nikon.SwiftCoreCameraSession
import com.opencapture.openzcine.bridge.SwiftLiveViewPolicyInput
import com.opencapture.opencine.nikon.SwiftLiveViewPreviewState
import com.opencapture.opencine.nikon.CameraControl
import com.opencapture.opencine.nikon.CameraControlException
import com.opencapture.opencine.nikon.CameraPropertySnapshot
import com.opencapture.opencine.nikon.CameraSessionEvent
import com.opencapture.openzcine.diagnostics.AndroidDiagnosticEvent
import com.opencapture.opencine.nikon.CameraFocusException
import com.opencapture.opencine.nikon.CameraFocusPoint
import com.opencapture.opencine.nikon.CameraPropertyRefreshFailure
import com.opencapture.opencine.nikon.CameraPropertyRefreshStatus
import com.opencapture.opencine.nikon.CameraRecordingException
import com.opencapture.opencine.nikon.CameraRecordingState
import com.opencapture.opencine.nikon.CameraSession
import com.opencapture.opencine.nikon.CameraSessionState
import com.opencapture.opencine.nikon.CameraTemperatureStatus
import com.opencapture.opencine.nikon.LiveAudioMeterLevels
import com.opencapture.opencine.nikon.LiveFeedRotation
import com.opencapture.opencine.nikon.LiveFocusResult
import com.opencapture.opencine.nikon.metadataOnly
import com.opencapture.opencine.nikon.LiveFrameSource
import com.opencapture.openzcine.core.MonitorDataAvailability
import com.opencapture.opencine.nikonwire.MonitorRelayWire
import com.opencapture.openzcine.lut.AndroidLutLibrary
import com.opencapture.opencine.appkit.MonitorRemoteShutter
import com.opencapture.opencine.appkit.MonitorRemoteShutterCommand
import com.opencapture.opencine.appkit.monitorRemoteShutterShouldArm
import com.opencapture.openzcine.remote.routeMediaRemoteShutterCommand
import com.opencapture.openzcine.settings.LocalLevelStyle
import com.opencapture.openzcine.settings.OperatorSettings
import com.opencapture.opencine.appkit.MonitorDisplayMode
import com.opencapture.opencine.appkit.MonitorDisplaySection
import com.opencapture.opencine.appkit.MonitorOperatorSessionModel
import com.opencapture.openzcine.wear.AndroidWearPhoneRelay
import com.opencapture.openzcine.wear.WearRecordCommandSafety
import com.opencapture.openzcine.wear.androidWatchRelayState
import com.opencapture.openzcine.wear.executeWearRecordCommand
import com.opencapture.openzcine.wearrelay.WatchCommandResult
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.onEach
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.conflate
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import com.opencapture.opencine.nikon.IsoPickerPolicy
import com.opencapture.opencine.nikon.SwiftCoreLiveFrameSource
import com.opencapture.opencine.runtime.nativeFeedContentRect
import com.opencapture.opencine.vocabulary.SessionRecoveryUi
import com.opencapture.opencine.nikon.MonitorPictureClock
import android.os.SystemClock

/** Gives the live quick-settings panel first refusal on the system Back action. */
@Composable
internal fun LiveAssistOptionsBackHandler(visible: Boolean, onDismiss: () -> Unit) {
    BackHandler(enabled = visible, onBack = onDismiss)
}

/** Places a composable at an absolute zone frame (full-viewport dp coordinates). */
internal fun Modifier.zone(frame: MonitorRect): Modifier =
    offset(frame.x.dp, frame.y.dp).size(frame.width.dp, frame.height.dp)

/**
 * Lays the feed stack out in the camera's own frame — sides swapped when the body is vertical —
 * and rotates it upright into the container (the Android half of iOS `rotatedFeedImage`).
 * Compose maps pointer input back through the layer, so gestures, AF overlays, and punch-in
 * anchors inside keep operating in the camera's pre-rotation space with no coordinate changes.
 */
internal fun Modifier.liveFeedBodyRotation(rotation: LiveFeedRotation): Modifier =
    if (rotation == LiveFeedRotation.LANDSCAPE) {
        this
    } else {
        layout { measurable, constraints ->
                val swap = rotation.isVertical
                val placeable =
                    measurable.measure(
                        if (swap && constraints.hasBoundedWidth && constraints.hasBoundedHeight) {
                            Constraints.fixed(constraints.maxHeight, constraints.maxWidth)
                        } else {
                            constraints
                        },
                    )
                layout(constraints.maxWidth, constraints.maxHeight) {
                    placeable.place(
                        (constraints.maxWidth - placeable.width) / 2,
                        (constraints.maxHeight - placeable.height) / 2,
                    )
                }
            }
            .graphicsLayer { rotationZ = rotation.displayDegreesClockwise }
    }

/** Seats fail-closed feed feedback below any status deck mounted over the live image. */
internal fun liveFeedColorNoticeTopInsetDp(
    feed: MonitorRect,
    infoBar: MonitorRect,
    statusBarVisible: Boolean,
): Float {
    val edgeGap = 8f
    if (!statusBarVisible) return edgeGap
    return maxOf(edgeGap, infoBar.y + infoBar.height - feed.y + edgeGap)
}

/** Unwraps the owning [android.app.Activity] (a ComposeView's context is a wrapper). */
private tailrec fun android.content.Context.findActivity(): android.app.Activity? =
    when (this) {
        is android.app.Activity -> this
        is android.content.ContextWrapper -> baseContext.findActivity()
        else -> null
    }

/**
 * The monitor shell — a 1:1 port of the iOS `MonitorShell`
 * (ios/Runner/MonitorUnified.swift), laid out by the same shared OpenCine
 * `MonitorLayoutPolicy.fieldMonitor` geometry in both orientations.
 *
 * Scope: feed, top info deck (landscape pill / portrait bar), lock/battery
 * band, capture strip, assist toolbar (wired to the feed-effects engine and
 * the scope panels), record / DISP / media / settings controls, DISP 1→2→3
 * cycling incl. the command dashboard, persisted portrait fit/fill geometry,
 * and camera-backed in-monitor pickers. Every writable selection reuses the
 * typed CameraSession/Swift command seam; descriptor-dependent controls stay
 * read-only rather than receiving guessed options.
 *
 * [liveBackdrop] is the presented picture every shared material panel samples; without it the
 * panels show the shared material's plain fill.
 *
 * [assist] is shared with Operator Settings so toolbar and settings changes
 * immediately drive the same feed-effects and scope state.
 */
@Composable
internal fun MonitorScreen(
    session: CameraSession,
    commonSession: NikonOpenCineSession,
    commonControl: MonitorControlModel,
    /** The one display owner: DISP mode, each mode's chrome, the editor and the lock. */
    operatorSession: MonitorOperatorSessionModel,
    frameSource: LiveFrameSource?,
    assists: NikonAssists,
    operatorSettings: OperatorSettings,
    lutLibrary: AndroidLutLibrary? = null,
    /**
     * Shared camera-AP → internet hop owner (Frame.io + RED download). Required
     * for "Download over internet" while bound to the camera access point.
     */
    frameioController: com.opencapture.opencine.frameio.FrameioDeliveryController? = null,
    liveViewEnabled: Boolean = true,
    liveBackdrop: NikonLiveBackdrop? = null,
    mediaRemoteShutter: MonitorRemoteShutter? = null,
    isMonitorFront: Boolean = true,
    sessionRecoveryEnabled: Boolean = true,
    linkHealth: AndroidLinkHealthMonitor? = null,
    activeTransportIsUsb: Boolean = false,
    isDemoSession: Boolean = false,
    /**
     * What the monitor can truthfully display given who owns the camera — the iOS
     * `monitorAvailability` gate. A relay watcher passes `watcher(holdsControl)`: readings keep
     * flowing, but record/media/pickers/batteries unmount until it holds the control token.
     */
    availability: MonitorDataAvailability = MonitorDataAvailability.OWNING,
    /**
     * A watcher's camera readouts, forwarded by the broadcasting host (iOS `applyRelayState`).
     * Non-null only on the watch surface; feeds the top-bar pills so they never show the
     * retention preview seeds as if a camera reported them.
     */
    relayedState: MonitorRelayWire.State? = null,
    onOpenSettings: () -> Unit = {},
    onOpenMedia: () -> Unit = {},
    /** Leaves the held frame for the saved-camera home after a session drop. */
    onBackToOperatorMenu: () -> Unit = {},
    /** Debug-only staged recovery state for screenshot verification (`DemoHarness`). */
    recoveryStateOverride: SessionRecoveryUi? = null,
    /** Closed diagnostics breadcrumbs for the MF drive failure surfaces. */
    onDriveDiagnostic: (AndroidDiagnosticEvent) -> Unit = {},
    /**
     * A relay watcher holds this broadcast's control token — local camera controls stand
     * down (grayed, non-writing) until the operator revokes or the watcher gives it back.
     */
    controlsSurrendered: Boolean = false,
    incidentProducer: com.opencapture.openzcine.diagnostics.NikonFeedIncidentProducer? = null,
    /** A multicam member lent to this monitor: Media stays with the stage, and the lock key returns to it. */
    borrowed: Boolean = false,
    returnToStage: (() -> Unit)? = null,
    /** The one note sink; refusals and interruptions arrive through [MonitorControlModel.onNote]. */
    note: String? = null,
    clearNote: (String) -> Unit = {},
) {
    val appContext = LocalContext.current.applicationContext
    // A monitor-scoped relay means the wearable never becomes an independent
    // LiveFrameSource subscriber or a background camera owner.
    val wearRelay = remember(appContext) { AndroidWearPhoneRelay(appContext) }
    DisposableEffect(wearRelay, session) {
        wearRelay.bindSource(session)
        onDispose { wearRelay.bindSource(null) }
    }
    val lifecycleState by LocalLifecycleOwner.current.lifecycle.currentStateAsState()
    val sessionState by session.state.collectAsState()
    val internetHopState = frameioController?.internetHopState
    val cameraFeedStatus =
        remember(sessionState, internetHopState) {
            resolveMonitorCameraStatus(sessionState, internetHopState)
        }
    val monitorAccessibilityState = monitorCameraStatusAccessibility(cameraFeedStatus)
    val cameraProperties by session.cameraProperties.collectAsState()
    // Real press-tracked still release over the session (single, bulb/time,
    // and hold-to-burst with the remote-mode bracket). [verify-on-HW]
    val stillCapture = remember(session) { StillCaptureController(session) }
    val stillCapturing by stillCapture.isCapturing.collectAsState()
    // Post-capture instant playback (PLAY view-assist tool).
    val instantReview = remember(session) { InstantReviewController(session) }
    // The AF boxes on the latest presented frame, captured into the review a release produces.
    val captureReviewFocus = remember(session) { AtomicReference<LiveFocusInfo?>(null) }
    val instantReviewState by instantReview.review.collectAsState()
    // MF focus-by-wire drive (on-feed vertical strip beside the system rail).
    val mfDrive = remember(session) { MFDriveController(session) }
    val mfDriveAtEnd by mfDrive.atEnd.collectAsState()
    val mfDriveNetPulses by mfDrive.netPulses.collectAsState()
    val mfDriveDialFraction by mfDrive.dialFraction.collectAsState()
    val propertyRefreshStatus by session.propertyRefreshStatus.collectAsState()
    // Hold live view until the full post-connect property burst finishes so
    // AF mode / lens / subject / audio land in ~1–3 s instead of ~30 s of
    // interleaved one-property-per-1.5 s polls against the LV pump.
    val initialMonitorPropertiesReady by session.initialMonitorPropertiesReady.collectAsState()
    val commandRoundTripMilliseconds by
        session.latestCommandRoundTripMilliseconds.collectAsState()
    val cameraReadouts =
        remember(cameraProperties, relayedState) {
            monitorCameraReadouts(cameraProperties).let { readouts ->
                // A watcher's camera battery arrives over the relay, not from a session of its
                // own (iOS `applyRelayState`).
                relayedState?.let { readouts.copy(batteryPercent = it.cameraBatteryPercent) }
                    ?: readouts
            }
        }
    val phoneBatteryReadout = rememberPhoneBatteryReadout()
    val exposureAssistCameraInput =
        remember(
            cameraProperties.codec,
            cameraProperties.iso,
            cameraProperties.baseIso,
            cameraProperties.captureSelector,
            cameraProperties.stillToneMode,
        ) {
            ExposureAssistCameraInput(
                codec = cameraProperties.codec,
                iso = cameraProperties.iso,
                baseIso = cameraProperties.baseIso,
                // Photography live view is a display-referred stills preview, so the
                // assists anchor on the stills tone mode instead of the movie codec's
                // log curve (iOS `exposureSignalMapping`). Swift owns the curve choice.
                stillsToneMode =
                    if (prefersPhotographyChrome(cameraProperties)) {
                        cameraProperties.stillToneMode.orEmpty()
                    } else {
                        null
                    },
            )
        }
    val thermalTier = rememberAndroidThermalTier()
    val actualLinkHealth = linkHealth ?: remember(session) { AndroidLinkHealthMonitor() }
    val swiftLiveFrameSource =
        (session as? SwiftCoreCameraSession)?.liveFrames as? SwiftCoreLiveFrameSource
    val liveViewController =
        remember(swiftLiveFrameSource) {
            swiftLiveFrameSource?.let(::AndroidLiveViewController)
        }
    val noPreviewApplication =
        remember { MutableStateFlow<SwiftLiveViewPreviewState>(SwiftLiveViewPreviewState.Idle) }
    val previewApplication by
        (swiftLiveFrameSource?.previewState ?: noPreviewApplication).collectAsState()
    // Bounded recovery behind a preserved monitor: the operator keeps the held frame and gets
    // Retry / Operator menu once the shared attempt budget is spent, instead of a static
    // "No camera" over a loop that never stops (#253/#254).
    var sessionRecoveryState by
        remember(session) { mutableStateOf<SessionRecoveryUi>(SessionRecoveryUi.Idle) }
    var sessionRecoveryRetryTicket by remember(session) { mutableIntStateOf(0) }
    // Recovery ends on a fresh camera frame the monitor presents, never on a returned control
    // session alone (A6-02). The frame and present paths below stamp it.
    val recoveryPictures = remember(session) { MonitorPictureClock(SystemClock::elapsedRealtime) }
    // The session is Disconnected while recovering, so the affordance needs the name from before
    // the drop rather than the live identity.
    var lastConnectedCameraName by remember(session) { mutableStateOf("") }
    LaunchedEffect(sessionState) {
        (sessionState as? CameraSessionState.Connected)?.let {
            lastConnectedCameraName = it.identity.name
        }
    }
    MonitorSessionRecoveryEffect(
        session,
        pictures = recoveryPictures,
        enabled = sessionRecoveryEnabled,
        retryTicket = sessionRecoveryRetryTicket,
        onRecoveryState = { sessionRecoveryState = it },
    )

    // The display owner is the shared session's. Command (DISP 3) is a camera-control dashboard: a
    // stills body (its dashboard is movie-shaped) or a session with no camera behind it (a watcher
    // without the control token) does not offer it (iOS `displayOrder`). Recording is owned by the
    // CameraSession; the shell only renders its state and asks it to send a Nikon command.
    val offersCommand = !prefersPhotographyChrome(cameraProperties) && availability.cameraControls
    SideEffect {
        operatorSession.declare(if (offersCommand) listOf(MonitorDisplayMode.LIVE, MonitorDisplayMode.CLEAN,
            MonitorDisplayMode.COMMAND) else listOf(MonitorDisplayMode.LIVE, MonitorDisplayMode.CLEAN))
    }
    val effectiveDisplayMode = operatorSession.mode
    val locked = operatorSession.locked
    var focusPointLocked by remember(session) { mutableStateOf(false) }
    var focusLockHolding by remember(session) { mutableStateOf(false) }
    var focusMoveRequestsInFlight by remember(session) { mutableStateOf(0) }
    var focusResetPending by remember(session) { mutableStateOf(false) }
    val focusCommandPending = focusMoveRequestsInFlight > 0 || focusResetPending
    val focusLockProgress by
        animateFloatAsState(
            targetValue = if (focusLockHolding && !focusPointLocked) 1f else 0f,
            animationSpec =
                tween(
                    durationMillis = if (focusLockHolding) 200 else 160,
                    delayMillis = if (focusLockHolding) 100 else 0,
                    easing = LinearEasing,
                ),
            label = "focusPointLockProgress",
        )
    LaunchedEffect(sessionState) {
        if (sessionState !is CameraSessionState.Connected) {
            focusPointLocked = false
            focusLockHolding = false
            focusMoveRequestsInFlight = 0
            focusResetPending = false
        }
    }
    DisposableEffect(session) {
        onDispose {
            focusPointLocked = false
            focusLockHolding = false
        }
    }
    val recordingState by session.recordingState.collectAsState()
    val recording =
        recordingState == CameraRecordingState.STARTING ||
            recordingState == CameraRecordingState.RECORDING
    val previewPolicyRecording = previewPolicyRecordingActive(recordingState)
    // The Android shell stores operator intent only. Swift resolves that
    // intent against the portable stream/thermal policy, then the active
    // source restarts just its preview pump when the approved request moves.
    // A camera warning becomes an overheating input only for the explicit HOT
    // state; WARNING remains informational until Nikon hardware proves it is
    // safe to treat as a thermal stop signal.
    val liveViewPolicyInput =
        remember(
            operatorSettings.streamPreset,
            operatorSettings.qualityBias,
            thermalTier,
            previewPolicyRecording,
            cameraProperties.temperatureStatus,
        ) {
            SwiftLiveViewPolicyInput(
                streamPreset = operatorSettings.streamPreset.wireValue,
                qualityBias = operatorSettings.qualityBias.wireValue,
                thermalTier = thermalTier.wireValue,
                isRecording = previewPolicyRecording,
                cameraOverheating =
                    cameraProperties.temperatureStatus == CameraTemperatureStatus.HOT,
            )
        }
    LaunchedEffect(liveViewController, liveViewPolicyInput) {
        liveViewController?.apply(liveViewPolicyInput)
    }
    // Record start/stop changes the thermal LV size and restarts the pump. If the
    // body rejects the first configure pass, preview can sit in Rejected with no
    // frames (and a frozen TC) until the whole monitor remounts. Re-apply once the
    // recording state settles so a stuck rejection recovers without a reconnect.
    LaunchedEffect(liveViewController, recordingState) {
        if (liveViewController == null) return@LaunchedEffect
        if (
            recordingState != CameraRecordingState.RECORDING &&
                recordingState != CameraRecordingState.STANDBY
        ) {
            return@LaunchedEffect
        }
        delay(350)
        liveViewController.apply(liveViewPolicyInput)
    }
    val sharedControlState by commonControl.state.collectAsState()
    val recordCommandPending = sharedControlState.recordPending ||
        recordingState == CameraRecordingState.STARTING ||
            recordingState == CameraRecordingState.STOPPING
    val recordControlEnabled =
        availability.canDriveCamera &&
            sessionState is CameraSessionState.Connected &&
            !recordCommandPending &&
            // A watcher holding the control token owns the camera outright. Leaving the host's
            // record button live meant a lit disc that STILL wrote to the body behind the
            // watcher's back; iOS blocks its hit-testing alongside the 0.4 dim
            // (`MonitorUnified` record/shutter, `relayControlSurrendered`).
            !controlsSurrendered
    val recordScope = rememberCoroutineScope()
    // CORE-02: ISO, white balance and record go through the OpenCine camera-session seam. It
    // admits them against camera-reported state, keeps receipts, and drives [session] itself.
    SideEffect { commonSession.updateMonitorAuthority(availability, controlsSurrendered) }
    val commandTileOrderStore = remember(appContext) { commandTileOrderStore(appContext) }
    var commandTileOrder by remember(commandTileOrderStore) {
        mutableStateOf(commandTileOrderStore.load())
    }
    var activeCommandControl by remember { mutableStateOf<CommandControlRequest?>(null) }
    var activeMonitorPickerKind by remember { mutableStateOf<MonitorPickerKind?>(null) }
    // iOS `isRedDownloadPresented` — full-screen RED IPP2 download cover.
    var redDownloadPresented by remember { mutableStateOf(false) }
    // iOS pendingShutterLockState: optimistic lock UI until poll matches the write.
    var optimisticShutterLocked by remember { mutableStateOf<Boolean?>(null) }
    var commonEditor by remember { mutableStateOf<MonitorControlModel.Editor?>(null) }
    val quickCaptureOwner = remember(session) { NikonCaptureQuickOwner() }
    DisposableEffect(quickCaptureOwner) { onDispose { quickCaptureOwner.retire() } }
    LaunchedEffect(activeMonitorPickerKind, activeCommandControl?.control) {
        val key = when {
            activeMonitorPickerKind == MonitorPickerKind.ISO || activeCommandControl?.control == CameraControl.ISO -> SettingKey.ISO
            activeMonitorPickerKind == MonitorPickerKind.WHITE_BALANCE || activeCommandControl?.control == CameraControl.WHITE_BALANCE -> SettingKey.WHITE_BALANCE
            activeMonitorPickerKind == MonitorPickerKind.SHUTTER || activeCommandControl?.control == CameraControl.SHUTTER -> SettingKey.SHUTTER
            activeMonitorPickerKind == MonitorPickerKind.IRIS || activeCommandControl?.control == CameraControl.IRIS -> SettingKey.APERTURE
            else -> null
        }
        commonEditor = key?.let(commonControl::edit)
    }
    // The other side's panels/popups make no sense after a photo ↔ movie flip —
    // close whatever is open rather than leaving a stale drum floating (iOS
    // dismissActivePanel-on-flip). The nil→first read is the bootstrap's own
    // selector read, not a flip.
    var lastCaptureSelector by remember { mutableStateOf(cameraProperties.captureSelector) }
    LaunchedEffect(cameraProperties.captureSelector) {
        val previous = lastCaptureSelector
        lastCaptureSelector = cameraProperties.captureSelector
        if (previous != null && cameraProperties.captureSelector != previous) {
            activeCommandControl = null
            activeMonitorPickerKind = null
            assists.shared.configureTool = null
        }
    }
    var commandControlFeedback by remember { mutableStateOf<CommandControlFeedback?>(null) }
    /**
     * Native control writes through the Core latest-wins queue (iOS write-queue coalesce): the drum lands
     * optimistically, an in-flight write never blocks it, and only the last label per control goes out.
     */
    val nativeWrites = remember(session) {
        MonitorNativeWrites<CameraControl, Pair<CommandControlRequest, String>>(
            recordScope,
            write = { control, (_, label) ->
                // Facade applyControl already confirms the write on the wire. Do not soft-fail from a
                // lagging property poll (see docs/android-control-writes.md).
                if (control in NikonOpenCineSession.CONTROLS && (!prefersPhotographyChrome(session.cameraProperties.value) ||
                        control !in setOf(CameraControl.SHUTTER, CameraControl.IRIS))) {
                    NikonOpenCineSession.settingValue(control, label)?.let { commonControl.set(it, label) }
                } else {
                    session.applyControl(control, label)
                }
                // One refresh keeps tiles and bar honest; settles still enqueue while this runs.
                session.refreshProperties()
            },
            // Already matches the readback (scrolled back, or a coalesced write landed): skip the wire trip.
            // REC and codec always write, like iOS: a soft label match can lag behind the body.
            confirmed = { control, (_, label) ->
                control != CameraControl.RESOLUTION_FRAMERATE && control != CameraControl.CODEC &&
                    cameraPropertyConfirmsSelection(session.cameraProperties.value, control, label)
            },
            refused = { _, (request, _), error ->
                commandControlFeedback = CommandControlFeedback(
                    appContext.getString(R.string.control_error, request.title,
                        error.message ?: appContext.getString(R.string.control_change_rejected)),
                    isError = true,
                )
            },
        )
    }
    val pendingCommandControl = nativeWrites.pending
    val resources = LocalResources.current
    val stringResolver = remember(resources) { resources.phoneStringResolver() }
    // Drop optimistic override once the body reports the same lock state (iOS poll settle).
    LaunchedEffect(cameraProperties.shutterLocked, optimisticShutterLocked) {
        val optimistic = optimisticShutterLocked ?: return@LaunchedEffect
        if (cameraProperties.shutterLocked == optimistic) {
            optimisticShutterLocked = null
        }
    }
    val effectiveShutterLocked = optimisticShutterLocked ?: cameraProperties.shutterLocked
    val shownCameraProperties = cameraProperties.withPendingControls(sharedControlState.pending)
    val commandPresentation =
        remember(
            shownCameraProperties,
            propertyRefreshStatus,
            sessionState,
            commandTileOrder,
            recording,
            stringResolver,
        ) {
            commandDashboardPresentation(
                snapshot = shownCameraProperties,
                refreshStatus = propertyRefreshStatus,
                sessionState = sessionState,
                tileOrder = commandTileOrder,
                strings = stringResolver,
                recording = recording,
            )
        }
    val captureSettings =
        remember(
            commandPresentation,
            stringResolver,
            effectiveShutterLocked,
            cameraProperties.isoAuto,
            cameraProperties.exposureMode,
            relayedState,
        ) {
            monitorCaptureSettings(
                commandPresentation,
                stringResolver,
                shutterLockedOnCamera = effectiveShutterLocked,
                isoAuto = cameraProperties.isoAuto,
                exposureMode = cameraProperties.exposureMode,
            ).let { settings ->
                // A watcher's strip shows the broadcaster's values (iOS `applyRelayState`);
                // no local session ever fills these cells.
                relayedState?.let { relayCaptureSettings(settings, it.values) } ?: settings
            }
        }
    val topPillPickers =
        remember(commandPresentation, stringResolver) {
            monitorTopPillPickers(commandPresentation, stringResolver)
        }
    val isPhotographyMode = prefersPhotographyChrome(cameraProperties)
    // App-side photo timers (iOS photoTimerDelaySeconds / photoTimerShotCount /
    // driveBeforeBuiltInTimer): the countdown is the app's — a remote release
    // never runs the body's own self-timer.
    var photoTimerDelaySeconds by remember { mutableIntStateOf(0) }
    var photoTimerShotCount by remember { mutableIntStateOf(1) }
    var driveBeforeBuiltInTimer by remember { mutableStateOf<String?>(null) }
    // iOS `photoPillShowsStorage`: the SHOTS pill's storage flip-side.
    var photoPillShowsStorage by remember { mutableStateOf(false) }
    // The photo strip's nine tiles + stills pickers; WB reuses the movie
    // presentation (identical popup, writes routed to the stills properties
    // by the facade's selector).
    val photographySettings =
        remember(cameraProperties, captureSettings, photoTimerDelaySeconds, isPhotographyMode) {
            if (!isPhotographyMode) {
                emptyList()
            } else {
                photographyCaptureSettings(
                    properties = cameraProperties,
                    wbPicker =
                        captureSettings
                            .firstOrNull { it.kind == MonitorPickerKind.WHITE_BALANCE }
                            ?.picker,
                    photoTimerDelaySeconds = photoTimerDelaySeconds,
                )
            }
        }
    val photographyTopPickers =
        remember(cameraProperties, isPhotographyMode) {
            if (isPhotographyMode) photographyTopBarPickers(cameraProperties) else emptyMap()
        }
    val activeMonitorPicker =
        if (isPhotographyMode) {
            photographySettings.firstOrNull { it.kind == activeMonitorPickerKind }?.picker
                ?: activeMonitorPickerKind?.let(photographyTopPickers::get)
        } else {
            captureSettings.firstOrNull { it.kind == activeMonitorPickerKind }?.picker
                ?: activeMonitorPickerKind?.let(topPillPickers::get)
        }
    val mediaOwnsCommandChannel =
        (propertyRefreshStatus as? CameraPropertyRefreshStatus.Degraded)?.failure ==
            CameraPropertyRefreshFailure.MEDIA_BUSY
    val commandControlsEnabled =
        sessionState is CameraSessionState.Connected &&
            !locked &&
            !mediaOwnsCommandChannel &&
            !controlsSurrendered
    LaunchedEffect(sessionState, activeMonitorPickerKind, activeMonitorPicker) {
        if (sessionState !is CameraSessionState.Connected ||
            (activeMonitorPickerKind != null && activeMonitorPicker == null)
        ) {
            activeMonitorPickerKind = null
        }
    }
    val moveCommandTileTo: (CommandTileKind, Int) -> Unit = { kind, target ->
        val current = commandTileOrder
        val next = moveCommandTile(current, kind, target)
        if (next != current) {
            commandTileOrder = next
            commandTileOrderStore.save(next)
        }
    }
    /**
     * A DISP 3 tile — grid or side column — opens the SAME tabbed picker the capture strip does
     * whenever one already owns its control (iOS `CommandPrimaryGrid` and `CommandSmallTile` both
     * call `model.showPicker`). Command mode mounts no capture strip, so sending every tile to the
     * one-list drum is exactly how shutter Angle↔Speed, the ISO base/Auto tabs with their ★ native
     * markers, the WB tint pad and the FOCUS Mode/Area/Subject bar went missing there. Controls the
     * strip has no cell for (audio, tone, grid) still take the drum.
     */
    val openCommandControl: (CommandControlRequest) -> Unit = { request ->
        assists.shared.configureTool = null
        // Same picker source the portrait live grid resolves against, so a stills body never
        // matches a cinema request against the movie strip.
        val pickerSource = if (isPhotographyMode) photographySettings else captureSettings
        val kind = monitorPickerKindForRequest(pickerSource, request)
        activeMonitorPickerKind = kind
        activeCommandControl = if (kind == null) request else null
        commandControlFeedback = null
    }
    val applyCameraControl: (CommandControlRequest, String) -> Unit =
        applyCameraControl@{ request, label ->
            if (!commandControlsEnabled) return@applyCameraControl
            if (request.control in NikonOpenCineSession.CONTROLS &&
                (!isPhotographyMode || request.control !in setOf(CameraControl.SHUTTER, CameraControl.IRIS))) {
                val value = NikonOpenCineSession.settingValue(request.control, label) ?: return@applyCameraControl
                val editor = commonEditor
                if (editor?.key == value.key) {
                    if (!commonControl.commit(value, editor, label)) {
                        commonControl.onNote("The camera changed. Reopen this control.")
                    }
                } else {
                    commonControl.set(value, label)
                }
                return@applyCameraControl
            }
            // Exit movie ISO auto by choosing a drum value: write MovISOAutoControl Off first
            // so the body accepts the manual ISO write (non-R3D NE codecs).
            // Manual ISO / Auto Off: R3D NE always; other codecs only in M.
            val codecForISO =
                (cameraProperties.codecSelection ?: cameraProperties.codec)
                    ?.takeIf { it != "—" }
                    .orEmpty()
            if (
                request.control == CameraControl.ISO &&
                    !IsoPickerPolicy.allowsManualISO(
                        codecForISO,
                        cameraProperties.exposureMode,
                    )
            ) {
                return@applyCameraControl
            }
            if (
                request.control == CameraControl.ISO_AUTO &&
                    label.equals(IsoPickerPolicy.AUTO_ISO_OFF_LABEL, ignoreCase = true) &&
                    !IsoPickerPolicy.allowsManualISO(
                        codecForISO,
                        cameraProperties.exposureMode,
                    )
            ) {
                return@applyCameraControl
            }
            if (
                request.control == CameraControl.ISO &&
                    IsoPickerPolicy.isAutoISOActive(cameraProperties.isoAuto, codecForISO)
            ) {
                nativeWrites.submit(CameraControl.ISO_AUTO,
                    CommandControlRequest(
                        title = "ISO",
                        control = CameraControl.ISO_AUTO,
                        currentValue = IsoPickerPolicy.AUTO_ISO_OFF_LABEL,
                        options =
                            listOf(
                                IsoPickerPolicy.AUTO_ISO_ON_LABEL,
                                IsoPickerPolicy.AUTO_ISO_OFF_LABEL,
                            ),
                    ) to IsoPickerPolicy.AUTO_ISO_OFF_LABEL)
            }
            commandControlFeedback = null
            if (activeCommandControl?.control == request.control) {
                activeCommandControl = request.copy(currentValue = label)
            }
            nativeWrites.submit(request.control, request to label)
        }
    /**
     * Photography write router (iOS `applyPicker` stills paths): the DRIVE
     * timer tabs are app semantics — Built-in engages/restores the body's
     * self-timer drive, App-timer is the in-app countdown — and stills ISO
     * only writes where the exposure program allows it.
     */
    val applyPhotographyControl: (CommandControlRequest, String) -> Unit =
        applyPhotography@{ request, label ->
            when (request.title) {
                "Built-in Timer" -> {
                    // The two timers are mutually exclusive (iOS setBuiltInTimer).
                    if (label == "On") {
                        if (photoTimerDelaySeconds > 0) return@applyPhotography
                        if (
                            cameraProperties.stillCaptureMode !=
                            StillPickerPolicy.SELF_TIMER_LABEL
                        ) {
                            driveBeforeBuiltInTimer = cameraProperties.stillCaptureMode
                            applyCameraControl(
                                request.copy(title = "DRIVE"),
                                StillPickerPolicy.SELF_TIMER_LABEL,
                            )
                        }
                    } else if (
                        cameraProperties.stillCaptureMode == StillPickerPolicy.SELF_TIMER_LABEL
                    ) {
                        applyCameraControl(
                            request.copy(title = "DRIVE"),
                            driveBeforeBuiltInTimer ?: "Single",
                        )
                        driveBeforeBuiltInTimer = null
                    }
                }
                "App-timer" -> {
                    // The body's own timer owns the release while engaged —
                    // the app timer stays off (iOS setPhotoTimer).
                    val seconds = photoTimerSeconds(label)
                    if (
                        seconds == 0 ||
                        cameraProperties.stillCaptureMode != StillPickerPolicy.SELF_TIMER_LABEL
                    ) {
                        photoTimerDelaySeconds = seconds
                    }
                }
                else -> {
                    if (
                        request.control == CameraControl.STILL_ISO &&
                        !StillPickerPolicy.allowsManualISO(cameraProperties.exposureMode)
                    ) {
                        return@applyPhotography
                    }
                    applyCameraControl(request, label)
                }
            }
        }
    // App self-timer (iOS startStillTimer/fireTimerShots): a per-second beep
    // through usage-media playback so it stays audible per the device's silent
    // behaviour, a white tally pulse per tick, and the shots run chained after
    // the countdown. A second press cancels the countdown or remaining run.
    val photoTimer = remember(session) { MonitorPhotoTimer(recordScope) }
    val photoTimerRemaining = photoTimer.remaining
    val photoTimerTone =
        remember { android.media.ToneGenerator(android.media.AudioManager.STREAM_MUSIC, 80) }
    DisposableEffect(Unit) { onDispose { photoTimerTone.release() } }
    fun startPhotoTimer(seconds: Int) = photoTimer.start(
        seconds, photoTimerShotCount, capturing = { stillCapture.isCapturing.value },
        release = { stillCapture.pressed(recordScope, continuousDrive = false, preserveFocus = mfDrive.focusManuallyDialed) },
        onTick = { left ->
            if (left > 0) photoTimerTone.startTone(android.media.ToneGenerator.TONE_PROP_BEEP, 70)
            else photoTimerTone.startTone(android.media.ToneGenerator.TONE_PROP_BEEP2, 200)
        },
    )
    // Photography shutter press/release (iOS shutterButtonPressed/Released):
    // countdown/timer runs first; continuous drives latch the burst for the
    // duration of the hold.
    val photoShutterPressed: () -> Unit = pressed@{
        // A second press cancels a running countdown (or the remaining shot run), matching the body.
        if (photoTimer.cancel()) return@pressed
        if (photoTimerDelaySeconds > 0 && !stillCapturing) {
            startPhotoTimer(photoTimerDelaySeconds)
            return@pressed
        }
        if (
            photoTimerShotCount > 1 && !stillCapturing &&
            cameraProperties.stillCaptureMode == StillPickerPolicy.SELF_TIMER_LABEL
        ) {
            // Built-in timer engaged: its countdown never runs for command
            // releases, so the shots field drives a straight run from the press.
            startPhotoTimer(0)
            return@pressed
        }
        stillCapture.pressed(
            recordScope,
            continuousDrive =
                cameraProperties.stillCaptureMode in StillPickerPolicy.CONTINUOUS_DRIVES,
            // A dialled focus must survive the shutter — an AF release would re-focus at the
            // box and undo the pull (iOS `focusManuallyDialed`).
            preserveFocus = mfDrive.focusManuallyDialed,
        )
    }
    val photoShutterReleased: () -> Unit = { stillCapture.released(recordScope) }
    // Arm the instant-review diff with the card's current handles the moment
    // PLAY is on in photo mode (iOS seedInstantReviewBaseline call sites);
    // leaving photo mode or losing the session drops any presented review.
    LaunchedEffect(sessionState, isPhotographyMode, assists.instantReview) {
        if (
            sessionState is CameraSessionState.Connected &&
            isPhotographyMode &&
            assists.instantReview
        ) {
            instantReview.seedBaseline(this)
        } else {
            instantReview.dismiss()
        }
    }
    // Completion is per-run, never per-frame — a held burst schedules exactly
    // one review, of its last frame. Reassigned per composition so the hook
    // reads current mode/quality state.
    // A press that cannot proceed must explain itself — never a silent
    // dead shutter (body refusal, busy channel, unsupported session).
    stillCapture.onFailure = { message -> commonControl.onNote(message) }
    // A sustained refusal (retries exhausted) explains itself once per run — the
    // strip stays up so the next gesture tries again.
    mfDrive.onRefusalExhausted = { message ->
        onDriveDiagnostic(AndroidDiagnosticEvent.MF_DRIVE_REFUSED)
        commonControl.onNote(message)
    }
    // Travel end: a firm tick as NEAR / ∞ lights (iOS impact haptic).
    val mfHapticView = LocalView.current
    LaunchedEffect(mfDriveAtEnd) {
        if (mfDriveAtEnd != null) {
            mfHapticView.performOperatorHaptic(
                HapticFeedbackConstants.LONG_PRESS,
                enabled = operatorSettings.hapticsEnabled.value,
            )
        }
    }
    // Bumped when a shutter fires ON THE BODY reaches the app, so the shutter button can pulse
    // in acknowledgement (iOS `bodyShutterPulse`); the app-fired path animates via its press.
    var bodyShutterPulse by remember { mutableIntStateOf(0) }
    // Body-fired shutter (iOS 5e366e7): the capture-complete event syncs the
    // app exactly as if it fired the release — instant playback against the
    // fresh card diff plus a shots-remaining refresh — gated to photo mode
    // and suppressed while an app release is in flight (that path schedules
    // its own review). The diff baseline is maintained outside the shutter
    // path, so captures the app didn't initiate resolve the same way.
    LaunchedEffect(session) {
        // Debounce the body-capture sync: the GetEventEx poll surfaces a burst as many
        // ObjectAdded/CaptureComplete events (and the same shot can arrive on both the poll and
        // the socket), so collapse them to ONE review — iOS uses a 0.8 s window.
        var lastBodyCaptureSyncNanos = 0L
        session.events.collect { event ->
            if (event !is CameraSessionEvent.StillCaptureCompleted) return@collect
            val snapshot = session.cameraProperties.value
            val action =
                bodyCaptureSyncAction(
                    isPhotography = prefersPhotographyChrome(snapshot),
                    instantReviewEnabled = assists.instantReview,
                    appReleaseInFlight = stillCapture.isCapturing.value,
                )
            if (action == BodyCaptureSync.IGNORE) return@collect
            val nowNanos = System.nanoTime()
            if (nowNanos - lastBodyCaptureSyncNanos < 800_000_000L) return@collect
            lastBodyCaptureSyncNanos = nowNanos
            // A body capture reached the app: pulse the shutter button so it visibly registers
            // (iOS `bodyShutterPulse &+= 1`), then run the shots refresh / instant review.
            bodyShutterPulse++
            recordScope.launch { runCatching { session.refreshProperties() } }
            if (action == BodyCaptureSync.REVIEW_AND_SHOTS) {
                instantReview.onCaptureRunCompleted(
                    recordScope,
                    enabled = true,
                    compression = snapshot.compression,
                    infoLine = photographyReviewInfoLine(snapshot),
                    focus = captureReviewFocus.get(),
                )
            }
        }
    }
    stillCapture.onRunCompleted = {
        instantReview.onCaptureRunCompleted(
            recordScope,
            enabled = isPhotographyMode && assists.instantReview,
            compression = cameraProperties.compression,
            infoLine = photographyReviewInfoLine(cameraProperties),
            focus = captureReviewFocus.get(),
        )
    }
    // iOS shutter long-press (strip cell + open picker panel): toggle MovieTVLock.
    val shutterHapticView = LocalView.current
    val shutterLongPressToggle: () -> Unit = {
        if (operatorSettings.hapticsEnabled.value) {
            shutterHapticView.performOperatorHaptic(HapticFeedbackConstants.LONG_PRESS)
        }
        toggleShutterLockOnCamera(
            captureSettings = captureSettings,
            cameraProperties = cameraProperties,
            applyCameraControl = applyCameraControl,
            onOptimisticShutterLocked = { optimisticShutterLocked = it },
            shutterLockedOverride = effectiveShutterLocked,
        )
    }
    // The shared record button owns its confirmation; while it is open the watch and the media
    // remote shutter stay off, as they did behind the old Nikon dialog.
    var recordConfirmationOpen by remember { mutableStateOf(false) }
    // Match the iOS watch's intentional confirmation bypass only after all
    // Android monitor/session/pending-command safety gates still hold. A watch
    // never owns a camera path; this reaches the same CameraSession seam as
    // the on-phone record control.
    val latestWearRecordCommand =
        rememberUpdatedState<suspend (CameraSession, com.opencapture.opencine.nikon.CameraCommandAdmission) -> WatchCommandResult>(
            newValue = { source, admission ->
                val safety =
                    WearRecordCommandSafety(
                        monitorFront = isMonitorFront,
                        applicationResumed = lifecycleState.isAtLeast(Lifecycle.State.RESUMED),
                        cameraConnected = sessionState is CameraSessionState.Connected,
                        recordCommandPending = recordCommandPending,
                        recordConfirmationPending = recordConfirmationOpen,
                        cameraControlPending = pendingCommandControl != null,
                    )
                executeWearRecordCommand(safety, recording) { target ->
                    if (source !== session || !admission.admits(source)) throw CameraRecordingException.CommandRejected
                    val snapshot = commonSession.refresh()
                    val dispatch = com.opencapture.opencine.core.CommandDispatchAdmission(
                        session = commonSession.id, epoch = snapshot.epoch,
                        isCurrent = { admission.admits(source) },
                        submit = { command -> commonSession.submit(command, admission) },
                    )
                    val receipt = commonControl.recordAndWait(target, dispatch)
                        ?: throw CameraRecordingException.NotConnected
                    when (receipt.stage) {
                        com.opencapture.opencine.core.CommandStage.Confirmed -> Unit
                        is com.opencapture.opencine.core.CommandStage.Rejected,
                        is com.opencapture.opencine.core.CommandStage.Failed -> throw CameraRecordingException.CommandRejected
                        else -> throw CameraRecordingException.TransportFailed
                    }
                }
            },
        )
    DisposableEffect(wearRelay) {
        wearRelay.setAdmittedCommandHandler { source, admission -> latestWearRecordCommand.value.invoke(source, admission) }
        onDispose {
            wearRelay.publishDisconnected()
            wearRelay.close()
        }
    }
    // Data Layer listeners exist only while the foreground monitor is
    // resumable. Backgrounding publishes one unavailable state before
    // detaching, and no relay-owned callback retains a live-frame source.
    val wearRelayForeground =
        isMonitorFront && lifecycleState.isAtLeast(Lifecycle.State.RESUMED)
    LaunchedEffect(wearRelay, wearRelayForeground) {
        if (wearRelayForeground) {
            wearRelay.activate()
        } else {
            wearRelay.publishDisconnected()
            wearRelay.deactivate()
        }
    }
    val mediaRemoteShutterShouldArm =
        monitorRemoteShutterShouldArm(
            enabled = operatorSettings.mediaRemoteShutterEnabled.value,
            monitorIsFront = isMonitorFront,
            cameraConnected = sessionState is CameraSessionState.Connected,
            recordCommandPending = recordCommandPending,
            applicationResumed = lifecycleState.isAtLeast(Lifecycle.State.RESUMED),
            recordConfirmationPending = recordConfirmationOpen,
            cameraControlPending = pendingCommandControl != null,
        )
    val latestRemoteShutterAction =
        rememberUpdatedState<(MonitorRemoteShutterCommand) -> Unit>(
            newValue = remoteShutterAction@{ command ->
                if (!mediaRemoteShutterShouldArm) return@remoteShutterAction
                recordScope.launch {
                    try {
                        routeMediaRemoteShutterCommand(
                            session = session,
                            command = command,
                            isRecording = recording,
                            recordControlEnabled = recordControlEnabled,
                        )
                    } catch (error: CameraRecordingException) {
                        error.message?.let(commonControl.onNote)
                    }
                }
            },
        )
    DisposableEffect(mediaRemoteShutter, mediaRemoteShutterShouldArm) {
        val shutter = mediaRemoteShutter
        if (shutter != null && mediaRemoteShutterShouldArm) {
            shutter.arm { command -> latestRemoteShutterAction.value(command) }
        } else {
            shutter?.disarm()
        }
        onDispose { shutter?.disarm() }
    }
    // Sticky-immersive bar cycle. The platform's own transient reveal is
    // deliberately opaque to apps (measured on the SM-A127F: no WindowInsets
    // change, no visibility event, and only an unreliable zero-inset
    // animation dispatch), so chrome could never move off the overlaid bars.
    // The app does still receive the edge swipe's pointer events, so the
    // shell detects the gesture itself — observe-only, nothing consumed —
    // and owns the cycle: show() the bars for real (dispatching genuine
    // insets, so the rail glides inward), hold them for a grace period, then
    // hide() (the rail reclaims the edge).
    var barsShown by remember { mutableStateOf(false) }
    // The bar lanes chrome must clear, published by the cycle below once the
    // shown insets are actually applied (Compose's own WindowInsets never
    // update after a programmatic show() on this device, so the applied
    // values are read off rootWindowInsets and pushed through this state).
    var barInsets by remember { mutableStateOf(androidx.core.graphics.Insets.NONE) }
    val view = LocalView.current
    LaunchedEffect(barsShown) {
        if (!barsShown) return@LaunchedEffect
        val window = view.context.findActivity()?.window ?: return@LaunchedEffect
        val controller = WindowCompat.getInsetsController(window, view)
        controller.show(WindowInsetsCompat.Type.systemBars())
        // Wait (briefly) for the show to land, then publish the real lanes.
        var attempts = 0
        while (attempts < 20) {
            delay(50)
            attempts++
            val applied =
                view.rootWindowInsets?.let {
                    WindowInsetsCompat.toWindowInsetsCompat(it, view)
                        .getInsets(WindowInsetsCompat.Type.systemBars())
                } ?: androidx.core.graphics.Insets.NONE
            if (applied != androidx.core.graphics.Insets.NONE) {
                barInsets = applied
                break
            }
        }
        delay(3_000)
        controller.hide(WindowInsetsCompat.Type.systemBars())
        barInsets = androidx.core.graphics.Insets.NONE
        barsShown = false
    }

    BoxWithConstraints(
        Modifier.fillMaxSize()
            .background(Color.Black)
            .semantics { contentDescription = monitorAccessibilityState }
            .pointerInput(Unit) {
                awaitEachGesture {
                    val down = awaitFirstDown(pass = PointerEventPass.Initial)
                    val edge = 24.dp.toPx()
                    val nearTop = down.position.y < edge
                    val nearRight = down.position.x > size.width - edge
                    if (!nearTop && !nearRight) return@awaitEachGesture
                    var travelX = 0f
                    var travelY = 0f
                    while (true) {
                        val event = awaitPointerEvent(PointerEventPass.Initial)
                        val change = event.changes.firstOrNull { it.id == down.id } ?: break
                        if (!change.pressed) break
                        val delta = change.positionChange()
                        travelX += delta.x
                        travelY += delta.y
                        val inward = if (nearTop) travelY else -travelX
                        if (inward > 40.dp.toPx()) {
                            barsShown = true
                            break
                        }
                    }
                }
            },
    ) {
        val density = LocalDensity.current
        val direction = LocalLayoutDirection.current
        val isPortrait = maxHeight > maxWidth
        // Live safe area: the punch-hole cutout plus the applied system-bar
        // lanes published by the cycle above. Each edge animates so the
        // chrome glides off the bars and back instead of jumping. The top
        // and bottom lanes flow through the safe area (the zone map's chrome
        // insets track them), but the RIGHT rail is centered in the letterbox
        // lane between the feed and the viewport edge and ignores trailing
        // insets by design — so the nav-bar lane shrinks the viewport width
        // instead, which slides the whole lane (and rail) inward.
        // ponytail: fixed-landscape means the nav bar can only sit on the
        // right on this device class; a left-handed nav lane would need a
        // leading offset too.
        val cutout = WindowInsets.displayCutout
        fun edgeDp(cutoutPx: Int, barPx: Int): Float =
            with(density) { maxOf(cutoutPx, barPx).toDp().value }
        val safeTop by animateFloatAsState(
            edgeDp(cutout.getTop(density), barInsets.top),
            label = "safeTop",
        )
        val safeBottom by animateFloatAsState(
            monitorBottomInsetDp(
                rawInsetDp = edgeDp(cutout.getBottom(density), barInsets.bottom),
                isPortrait = isPortrait,
            ),
            label = "safeBottom",
        )
        // Leading carries the synthesized iPhone island lane (see
        // monitorLeadingInsetDp) in LANDSCAPE only; the floor exists to move
        // the feed off the side chrome lane, which portrait doesn't have —
        // there the raw cutout flows through. Trailing gets NO floor — in the
        // landscape zone map the trailing inset only feeds the
        // which-side-is-the-cutout comparison and moves no frame (iOS's 44pt
        // trailing is < the 59pt leading, same branch), the rail centering in
        // the letterbox lane on both platforms.
        val safeLeading by animateFloatAsState(
            with(density) {
                val cutoutDp = cutout.getLeft(this, direction).toDp().value
                if (isPortrait) {
                    cutoutDp
                } else {
                    monitorLeadingInsetDp(
                        cutoutDp = cutoutDp,
                        transientBarDp = barInsets.left.toDp().value,
                    )
                }
            },
            label = "safeLeading",
        )
        val safeTrailing =
            with(density) { cutout.getRight(this, direction).toDp().value }
        // Landscape-only right-hand nav-bar lane (portrait bars are top/bottom
        // and already flow through safeTop/safeBottom).
        val navLane by animateFloatAsState(
            if (isPortrait) {
                0f
            } else {
                with(density) {
                    maxOf(0, barInsets.right - cutout.getRight(this, direction)).toDp().value
                }
            },
            label = "navLane",
        )
        val viewportWidth = maxWidth.value - navLane
        val viewportHeight = maxHeight.value
        val isClean = effectiveDisplayMode == MonitorDisplayMode.CLEAN
        val isCommand = effectiveDisplayMode == MonitorDisplayMode.COMMAND
        // Body rotation from the live-view header (vertical mode). Screen-scoped state because
        // layout reads it well before the frame collectors are declared; the header collector
        // (open in every DISP mode) writes it, and a source change resets it.
        var liveFeedRotation by remember { mutableStateOf(LiveFeedRotation.LANDSCAPE) }
        // Whether the body runs timecode at all: the live-view header's own status byte. Bodies with no
        // timecode hardware pin it to zero forever, and that is exactly the signal that hides the readout
        // instead of parking a frozen 00:00:00:00 on set. The same collector latches it, only on a change.
        var cameraReportsTimecode by remember { mutableStateOf(false) }
        val displayedFeedRotation =
            liveFeedRotation.displayed(autoRotateEnabled = operatorSettings.autoRotateFeedEnabled.value)
        val isVerticalFeed = displayedFeedRotation.isVertical
        // Fit or fill is a cinema choice: a stills body lays out its whole image area (a centre crop of a
        // still makes no sense) and the dashboard has no picture to fill. Offering no choice there also
        // hides the key. Vertical mode always lays out as fill (shared layout policy).
        val portraitAspect = operatorSettings.portraitFeedAspect.takeIf { !isPhotographyMode && !isCommand }
        // Chrome the operator switched on still hides when nothing can fill it (iOS `sectionHasASource`).
        val available = availability.monitorSections(cameraReportsTimecode, isPhotographyMode)
        val mounted: (MonitorDisplaySection) -> Boolean = { it in available && operatorSession.mounts(it) }
        val statusBarVisible = mounted(MonitorDisplaySection.STATUS_BAR)
        val assistToolbarVisible = mounted(MonitorDisplaySection.TOOL_BAR)
        val cameraValuesVisible = mounted(MonitorDisplaySection.CAMERA_VALUES)
        val editingDisplay = operatorSession.editingMode
        val liveAssistChips =
            nikonLiveAssistChips(
                photography = isPhotographyMode,
                imageEffects = liveFeedEffectsPlatformAvailable(Build.VERSION.SDK_INT, SwiftCore.isAvailable),
            )
        val liveAssistTools = liveAssistChips.mapNotNull { (it as? NikonAssistChip.Tool)?.tool }
        // Picture identity belongs to the session. Acquisition follows the existing preview
        // policy, so command mode/background/bootstrap release demand without disposing its host.
        val pictureFrameSource = remember(session, frameSource) {
            frameSource ?: (session as? SwiftCoreCameraSession)?.liveFrames
        }
        val liveFeedPresentation =
            remember(pictureFrameSource) { LiveFeedPresentationState() }
        val liveFeedEffectsPresentation =
            remember(pictureFrameSource) { LiveFeedEffectsPresentationState() }
        // Photography passes its still image-area ratio (3:2/1:1/16:9) so the
        // portrait fit feed renders whole under the top bar; video keeps 16:9.
        // A vertically held body inverts the displayed ratio (shared core clamps
        // the resulting tall feed above the stacked bands).
        val portraitFeedAspectRatio =
            (if (frameSource != null && liveFeedPresentation.sourceWidth > 0 && liveFeedPresentation.sourceHeight > 0)
                liveFeedPresentation.sourceWidth.toFloat() / liveFeedPresentation.sourceHeight
            else if (isPhotographyMode) photographyFeedAspect(cameraProperties.imageArea) else 16f / 9f)
                .let { if (isVerticalFeed) 1f / it else it }
        // The shared field-monitor entry (iOS `LiveMonitorLayout.fieldMonitor`): picture, chrome and scope
        // clearance are common policy; this adapter supplies only the window's facts.
        val geometry = monitorOperatorFieldLayout(
            MonitorOperatorViewport(viewportWidth, viewportHeight, safeLeading, safeTrailing,
                portraitPhoneSafeTop(safeTop, viewportWidth, viewportHeight), safeBottom, 1f,
                safeLeading > 0f || safeTrailing > 0f),
            assists.shared, mounted, portraitAspect, portraitFeedAspectRatio, isVerticalFeed)
        val fieldLayout = checkNotNull(geometry.layout.field)
        val isPortraitFill = isPortrait && fieldLayout.fillsPicture
        // Raster/overlay fit: the rotated 9:16 picture pillarboxes inside the fill frame:
        // aspect-filling it would centre-crop the top and bottom of the vertical shot.
        val portraitRasterFill = isPortraitFill && !isVerticalFeed
        // The shared material samples the presented picture; a vertical feed (its geometry is
        // rotated) and the dashboard (no picture) keep the material's plain fill.
        if (liveBackdrop != null) {
            MonitorBackdropActivation(pictureFrameSource != null && liveViewEnabled && isMonitorFront &&
                !isVerticalFeed && !isCommand, liveBackdrop::setActive)
            DisposableEffect(liveBackdrop, pictureFrameSource) { onDispose { liveBackdrop.sourceChanged() } }
        }
        // Portrait fit stacks the first two eligible scopes in canonical order under the picture; the
        // others stay active and return in fill and landscape.
        val portraitScopes =
            if (isPortrait && !isPortraitFill && !isCommand) {
                assists.shared.portraitScopes(scopesShown {
                    assists.shared.rendersLive(it, effectiveDisplayMode, isPhotographyMode)
                })
            } else { emptyList() }
        val scopeZone = monitorOperatorFittedScopeZone(fieldLayout)
        // Local framing is deliberately read from the operator store rather
        // than the camera session: grid/crosshair/guides are composited over
        // the existing feed zone and never alter the Nikon Grid Display.
        val localFraming = assists.shared.framing(assists.shared::isOn, operatorSettings.levelStyle)
        // What the feed overlays actually draw: the operator's framing config with the tools this
        // DISP mode suppresses switched off. The stored config is untouched, so leaving clean
        // restores the previous set exactly.
        val renderedFraming =
            assists.shared.framing({ assists.shared.rendersLive(it, effectiveDisplayMode, isPhotographyMode) },
                operatorSettings.levelStyle)
        // While the EV meter tool is on, the session interleaves fast needle
        // reads between regular property polls (dropped again on dispose so a
        // dismissed monitor can't keep the extra camera traffic alive).
        LaunchedEffect(session, localFraming.evMeterEnabled) {
            session.setExposureIndicatorFastPolling(localFraming.evMeterEnabled)
        }
        DisposableEffect(session) {
            onDispose { session.setExposureIndicatorFastPolling(false) }
        }
        val liveFeedColorNoticeTopInset =
            liveFeedColorNoticeTopInsetDp(
                feed = fieldLayout.picture,
                infoBar = fieldLayout.status,
                statusBarVisible = statusBarVisible,
            )
        // The gauge is a HUD instrument, so its lower track must clear the
        // bottom strips actually mounted over the feed. Pass this local pixel
        // inset into the overlay rather than guessing from a device class or
        // a global screen margin; it preserves the iOS visible-feed seating
        // rule for every zone-map size and operator chrome configuration. The mount flags already
        // carry the mode — clean can now mount either bar — so re-asking "is this clean" here would
        // seat the gauge under a bar that is on screen.
        val bottomChromeTop =
            listOfNotNull(
                    fieldLayout.assists.takeIf { assistToolbarVisible }?.y,
                    fieldLayout.values.takeIf { cameraValuesVisible }?.y,
                )
                .minOrNull()
        val levelGaugeBottomChromeInset =
            with(density) {
                bottomChromeTop?.let { chromeTop ->
                    maxOf(0f, fieldLayout.picture.maxY - chromeTop).dp.toPx()
                } ?: 0f
            }

        // An explicit demo source wins; otherwise a connected Swift-core
        // session streams its own live view. Media ownership gates collection,
        // and backgrounding drops below STARTED so the camera receives
        // EndLiveView instead of continuing sensor readout for no consumer.
        val activeFrameSource =
            if (!liveViewEnabled || !initialMonitorPropertiesReady) {
                // Gate LV until bootstrap owns the command channel and fills
                // every monitor property (or the session never bootstraps).
                null
            } else {
                frameSource
                    ?: (session as? SwiftCoreCameraSession)
                        ?.liveFrames
                        ?.takeIf {
                            sessionState is CameraSessionState.Connected &&
                                lifecycleState.isAtLeast(Lifecycle.State.STARTED)
                        }
            }
        // Every preview consumer takes this monitor-only path. In DISP 3 it
        // becomes null before feed, audio, scope, health, or wearable effects
        // can hold the shared Swift source open, so its final collector ends
        // live view.
        val monitorFrameSource = monitorPreviewFrameSource(activeFrameSource, isCommand)
        // Whether a picture has ever reached the screen on this session. Scoped to the session, not
        // to the source, on purpose: a DISP 3 round trip drops the source and the decoder keeps the
        // last JPEG on screen, so re-arming here would flash "waiting" over a frame that is visibly
        // there. iOS asks the same question of `liveFrameImage`, which the held frame keeps non-nil.
        var hasPresentedFrame by remember(session) { mutableStateOf(false) }
        // The chrome observes only frames the existing feed decoder actually
        // presents. This adds no LiveFrameSource subscriber, so OPE-60's
        // current-stream health collector remains the sole link-score input
        // and DISP 3 still releases native live view.
        val timecodeOwner = monitorTimecodeOwner(sessionState)
        // iOS top-bar semantics: readouts seed from the preview values and
        // hold the last camera readback rather than blanking to "—"; FPS is
        // the live-measured delivery rate ("READY" before the first frame);
        // the media cell cycles capacity <-> estimated minutes.
        val readoutRetention =
            remember(session, timecodeOwner) { MonitorReadoutRetention(timecodeOwner) }
        LaunchedEffect(cameraProperties) { readoutRetention.update(cameraProperties) }
        // A watcher's pills show what the host formatted, never the retention's preview seeds
        // masquerading as a reporting camera (iOS `applyRelayState`).
        LaunchedEffect(relayedState) { relayedState?.let(readoutRetention::applyRelayed) }
        // The rate cell doubles as the link readout (shared words and rate, A3-16): a route that never
        // comes up must read differently from a connected feed with no frames.
        val presentedFrames = remember(pictureFrameSource) { PresentedFrameCounter() }
        val link = rememberMonitorLinkReadout(presentedFrames) {
            nikonLinkObservation(sessionState, recoveryStateOverride ?: sessionRecoveryState,
                previewApplication is SwiftLiveViewPreviewState.Rejected, presentedFrames,
                actualLinkHealth.presentation.signalBars)
        }
        var prefersMediaDuration by rememberSaveable { mutableStateOf(false) }
        val topBarMedia = if (relayedState != null) {
            if (prefersMediaDuration) readoutRetention.media.durationLabel else readoutRetention.media.capacityLabel
        } else {
            val storage = sharedControlState.snapshot?.storage
            if (prefersMediaDuration) storage?.recordingTimeLabel ?: "-- Min"
            else storage?.storageReadout?.label ?: StorageReadout.UNAVAILABLE
        }
        val watchRelayState =
            remember(
                sessionState,
                cameraProperties,
                recording,
                isMonitorFront,
                lifecycleState,
                monitorFrameSource,
            ) {
                androidWatchRelayState(
                    sessionState = sessionState,
                    cameraProperties = cameraProperties,
                    isRecording = recording,
                    monitorFront = isMonitorFront,
                    applicationResumed = lifecycleState.isAtLeast(Lifecycle.State.RESUMED),
                    liveFeedActive = monitorFrameSource != null && isMonitorFront,
                )
            }
        LaunchedEffect(wearRelay, watchRelayState) {
            wearRelay.publishState(watchRelayState)
        }
        // Health collection deliberately owns no demo or command-dashboard
        // subscription: only the real Swift live source is evidence of a
        // camera stream, and DISP 3 must still send EndLiveView when it loses
        // the final preview consumer.
        val healthFrameSource =
            monitorFrameSource?.takeIf { it === swiftLiveFrameSource }
        // The BODY's recording rate, not the preview pull rate. iOS scores against
        // `cameraPropertySnapshot.fps` (`NativeAppRoot.currentLinkHealthInputs`); the 60 Hz pull is
        // a rate we ASK for and the body never produces at, so a healthy 25p feed scored ~41 here
        // against 100 on iPhone — two bars beside four, next to an identical FPS number.
        val healthTargetFramesPerSecond =
            validMonitorFrameRate(cameraProperties.frameRate)?.toDouble() ?: 30.0
        LaunchedEffect(
            actualLinkHealth,
            sessionState,
            healthFrameSource,
            frameSource,
            isDemoSession,
            activeTransportIsUsb,
            healthTargetFramesPerSecond,
        ) {
            actualLinkHealth.updateSession(
                state = sessionState,
                streamRequested = healthFrameSource != null,
                transportIsUsb = activeTransportIsUsb,
                targetFramesPerSecond = healthTargetFramesPerSecond,
                isDemoSession = isDemoSession || frameSource != null,
                connectionOwner = (session as? SwiftCoreCameraSession)?.connectionOwner,
            )
        }
        // Link health must use generation-filtered frames so a restart does not
        // score a stale replay JPEG as a live stream. Conflate so chrome never
        // backpressures the shared live-frame bus (feed hitch root cause).
        LaunchedEffect(actualLinkHealth, healthFrameSource, incidentProducer) {
            val incident = incidentProducer
            val swiftSource =
                healthFrameSource as? SwiftCoreLiveFrameSource
                    ?: return@LaunchedEffect
            swiftSource.currentStreamFrames
                .onEach { incident?.received() }
                .metadataOnly()
                .conflate()
                .collect(actualLinkHealth::recordFrame)
        }
        // The live-view header carries the body's timecode (the common session publishes it, A5-04),
        // its rotation and its timecode status byte. Deliberately NOT `monitorFrameSource`: that goes
        // null in Command, which dropped the last subscriber, ended live view, and froze the
        // dashboard's clock at the last pre-Command frame (#271). This collector holds the stream
        // open in every DISP mode while decode/scopes/audio still stand down.
        val timecodeFrameSource = monitorTimecodeFrameSource(activeFrameSource)
        LaunchedEffect(timecodeFrameSource) {
            val source = timecodeFrameSource
            if (source == null) {
                // No stream, no body rotation, no timecode status: never leave a stale vertical
                // layout — or a stale "this body runs TC" claim — up.
                liveFeedRotation = LiveFeedRotation.LANDSCAPE
                cameraReportsTimecode = false
                return@LaunchedEffect
            }
            source.frames
                .metadataOnly()
                .conflate()
                .collect { frame ->
                    withContext(Dispatchers.Main.immediate) {
                        // Only the status bit, and only on a change: the counter beside it ticks
                        // every frame and must never reach the chrome that reads this.
                        val reportsTimecode = frame.timecode?.on == true
                        if (cameraReportsTimecode != reportsTimecode) {
                            cameraReportsTimecode = reportsTimecode
                        }
                        if (liveFeedRotation != frame.rotation) {
                            liveFeedRotation = frame.rotation
                        }
                    }
                }
        }
        // Recovery picture proof: frames of the current native stream only (a replayed JPEG from
        // the dropped session proves nothing). Command presents the frame header, not its image,
        // so there the delivery is the presented picture (iOS `consumeCameraFrame` parity). Keyed
        // like the timecode collector, which already holds the stream open in every DISP mode.
        LaunchedEffect(timecodeFrameSource, isCommand, recoveryPictures) {
            val source = timecodeFrameSource ?: return@LaunchedEffect
            val frames = (source as? SwiftCoreLiveFrameSource)?.currentStreamFrames ?: source.frames
            withContext(Dispatchers.Default) {
                frames.collect {
                    recoveryPictures.noteSourceFrame()
                    if (isCommand) recoveryPictures.notePresented()
                }
            }
        }
        LaunchedEffect(actualLinkHealth, propertyRefreshStatus) {
            actualLinkHealth.reportPropertyRefresh(propertyRefreshStatus)
        }
        LaunchedEffect(actualLinkHealth, commandRoundTripMilliseconds) {
            actualLinkHealth.reportRoundTripMilliseconds(commandRoundTripMilliseconds)
        }
        val incidentLifecycle by rememberUpdatedState(com.opencapture.opencine.media.FeedIncidentLifecycle(
            foreground = lifecycleState.isAtLeast(Lifecycle.State.STARTED),
            settingsCovered = !isMonitorFront || healthFrameSource == null,
            connected = sessionState is CameraSessionState.Connected,
            sceneActive = lifecycleState.isAtLeast(Lifecycle.State.RESUMED),
            thermalState = "unknown", assistState = "unknown"))
        LaunchedEffect(actualLinkHealth, healthFrameSource, incidentProducer) {
            val incident = incidentProducer
            while (true) {
                delay(1_000)
                actualLinkHealth.refresh()
                incident?.publish(incidentLifecycle)
            }
        }
        var feedPointerSize by remember(monitorFrameSource) { mutableStateOf(IntSize.Zero) }
        // The drawn picture inside that zone (letterboxed when the feed's aspect differs),
        // which is what bounds the zoom pan. Filled in where the content rect is resolved.
        var feedPictureSize by remember(monitorFrameSource) { mutableStateOf(0f to 0f) }
        // Mode-filtered render inputs (#256): the operator's stored on/off state is untouched, so
        // leaving clean restores everything exactly.
        // The 50/50 comparison is an operator preference rather than a toolbar toggle, so it joins
        // the effect set here; `FeedEffects.activeSplitComparison` then keeps it tied to the LUT.
        //
        // `splitComparisonMuted` is the on-feed quick key's own state — session-only and
        // deliberately not persisted: it is one half of an A/B while judging a look, not a
        // setting. The armed preference is what mounts the key, so muting never removes it.
        var splitComparisonMuted by remember { mutableStateOf(false) }
        // Arming the comparison from the LUT popup clears the mute, so the split is showing when
        // the operator comes back to the image.
        LaunchedEffect(assists.shared.splitComparison) {
            if (assists.shared.splitComparison) splitComparisonMuted = false
        }
        // The zoom is session-only: it is a focus check, not a setting, and a monitor that reopens
        // already magnified is a monitor that lies about the framing.
        var committedZoom by remember { mutableStateOf(FeedZoom.NONE) }
        // Read at composition scope ONLY through this boolean. `committedZoom` itself changes on
        // every pointer event of a gesture, and reading it here would recompose the whole monitor
        // tree each time — which is what made the gesture feel laggy. The transform is read in the
        // graphicsLayer lambda instead, so a gesture costs a redraw and not a recomposition.
        val isFeedZoomed by remember { derivedStateOf { committedZoom.isZoomed } }
        // The same instrument the playback viewer uses (`MediaStillViewer`): Compose's own
        // multitouch transform, which resolves centroid, zoom and pan together per event. Rolling
        // this by hand off the feed's pointer arbiter gave a noticeably worse gesture.
        val feedTransformState =
            rememberTransformableState { centroid, zoomChange, panChange, _ ->
                val width = feedPointerSize.width.toFloat()
                val height = feedPointerSize.height.toFloat()
                if (width > 0f && height > 0f) {
                    // The picture, not the zone: a letterboxed feed must not be draggable until
                    // its black bars invade.
                    val picture = feedPictureSize
                    committedZoom =
                        feedZoomAfterTransform(
                            committed = committedZoom,
                            zoomChange = zoomChange,
                            centroidX = centroid.x,
                            centroidY = centroid.y,
                            panChangeX = panChange.x,
                            panChangeY = panChange.y,
                            width = width,
                            height = height,
                            pictureWidth = picture.first.takeIf { it > 0f } ?: width,
                            pictureHeight = picture.second.takeIf { it > 0f } ?: height,
                        )
                }
            }
        // A pinch released just about 1x settles back to the whole frame, as playback does.
        LaunchedEffect(feedTransformState) {
            snapshotFlow { feedTransformState.isTransformInProgress }
                .collect { inProgress ->
                    if (!inProgress) committedZoom = feedZoomSettled(committedZoom)
                }
        }
        val renderedEffects =
            assists.feedEffects { assists.shared.rendersLive(it, effectiveDisplayMode, isPhotographyMode) }
                .let { if (splitComparisonMuted) it.copy(splitComparison = null) else it }
        val renderedAudioMeters =
            assists.shared.rendersLive(MonitorAssistTool.AUDIO, effectiveDisplayMode, isPhotographyMode)
        var liveAudioLevels by
            remember(monitorFrameSource) { mutableStateOf<LiveAudioMeterLevels?>(null) }
        LaunchedEffect(monitorFrameSource, renderedAudioMeters) {
            if (!renderedAudioMeters || monitorFrameSource == null) {
                liveAudioLevels = null
                return@LaunchedEffect
            }
            monitorFrameSource.frames
                .metadataOnly()
                .conflate()
                .collect { frame ->
                    liveAudioLevels = frame.audioLevels
                }
        }
        val physicalViewport = MonitorRect(0f, 0f, viewportWidth, viewportHeight)
        val inspectorPreview = remember(appContext) { NikonLiveInspectorPreview(appContext) }
        DisposableEffect(inspectorPreview) { onDispose { inspectorPreview.close() } }
        val inspectorSourceIdentity = listOf(sharedControlState.snapshot?.session,
            sharedControlState.snapshot?.epoch, pictureFrameSource, physicalViewport,
            LocalDensity.current.density, LocalDensity.current.fontScale)
        SideEffect {
            inspectorPreview.configure(monitorFrameSource, inspectorSourceIdentity,
                isMonitorFront && !locked && editingDisplay == null &&
                    lifecycleState.isAtLeast(Lifecycle.State.RESUMED))
        }
        // Photography's landscape feed: the still image-area's shape centred in
        // the clear box between the chrome lanes — the rail and capture band
        // never overlap the image (iOS centered letterbox + reserved lanes).
        val effectiveFeed = fieldLayout.picture

        // Feed at the shared zone-map frame. Fit keeps the whole frame;
        // portrait fill centre-crops the image and every feed-aligned overlay
        // through the same content-rect resolver. Command unmounts the feed.
        val feedFocus = liveFeedPresentation.focus
        SideEffect { captureReviewFocus.set(feedFocus) }

        // A half-press on the body clears the instant review at once, instead of the operator
        // waiting out a countdown they have already decided to abandon. Twin of iOS
        // `dismissInstantReviewIfAutofocusEngaged`.
        //
        // There is no half-press on the wire, so this reads what a half-press CAUSES: autofocus
        // running. The body reports no focus result until it drives AF, so leaving UNKNOWN is the
        // press. Shooting two or three frames in a row is exactly when the wait is felt, and
        // exactly when the finger is already back on the button.
        //
        // A TRANSITION, never a level: in AF-C and AF-F the body focuses continuously while live
        // view runs, so AF is already engaged when the review opens and stays that way — testing
        // the level would dismiss every review the instant it appeared. The shortcut is simply
        // unavailable in those modes, which is today's behaviour rather than a regression.
        val feedFocusResult = feedFocus?.result
        var previousFocusResult by remember { mutableStateOf<LiveFocusResult?>(null) }
        LaunchedEffect(feedFocusResult) {
            val previous = previousFocusResult
            previousFocusResult = feedFocusResult
            if (instantReviewState != null &&
                previous == LiveFocusResult.UNKNOWN &&
                feedFocusResult != null &&
                feedFocusResult != LiveFocusResult.UNKNOWN
            ) {
                instantReview.dismiss()
            }
        }
        val feedContent =
            nativeFeedContentRect(
                containerWidth = feedPointerSize.width.toFloat(),
                containerHeight = feedPointerSize.height.toFloat(),
                sourceWidth = liveFeedPresentation.sourceWidth,
                sourceHeight = liveFeedPresentation.sourceHeight,
                aspectFill = portraitRasterFill,
            )
        // Publish the drawn picture's size so the zoom pan bounds on it rather than on the zone.
        LaunchedEffect(feedContent) {
            feedPictureSize =
                feedContent?.let { it.width.toFloat() to it.height.toFloat() } ?: (0f to 0f)
        }
        val focusMetadataAvailable =
            sessionState is CameraSessionState.Connected &&
                monitorFrameSource != null &&
                focusMetadataSupportsDirectInput(feedFocus)
        val feedPointerViewport =
            LiveOverlayRect(
                left = 0f,
                top = 0f,
                width = feedPointerSize.width.toFloat(),
                height = feedPointerSize.height.toFloat(),
            )
        val feedGestureGeometry =
            if (feedContent != null) {
                focusFeedGeometry(
                    content = feedContent,
                    horizontalPresentationScale = localFraming.horizontalPresentationScale,
                    verticalPresentationScale = localFraming.verticalPresentationScale,
                    viewport = feedPointerViewport,
                    coordinateWidth = feedFocus?.coordinateWidth.takeIf {
                        focusMetadataAvailable
                    },
                    coordinateHeight = feedFocus?.coordinateHeight.takeIf {
                        focusMetadataAvailable
                    },
                    generation = liveFeedPresentation.focusGestureGeometryGeneration,
                    mirrored = renderedFraming.mirrorsHorizontally,
                    mirroredVertical = renderedFraming.flipsVertically,
                )
            } else {
                focusFeedViewportGeometry(
                    viewport = feedPointerViewport,
                    generation = liveFeedPresentation.focusGestureGeometryGeneration,
                )
            }
        val otherCameraCommandPending = pendingCommandControl != null || recordCommandPending
        val focusGestureContext =
            FocusFeedGestureContext(
                geometry = feedGestureGeometry,
                interfaceLocked = locked || isCommand,
                focusPointLocked = focusPointLocked,
                focusAvailable = focusMetadataAvailable,
                commandPending = otherCameraCommandPending || focusResetPending,
                mediaBusy = mediaOwnsCommandChannel,
            )
        val toggleFocusPointLock: () -> Unit = toggleFocusPointLock@{
            if (!focusGestureContext.canRecognizeFocusGesture) return@toggleFocusPointLock
            val next = !focusPointLocked
            focusPointLocked = next
            focusLockHolding = false
            view.performOperatorHaptic(
                if (next) {
                    HapticFeedbackConstants.LONG_PRESS
                } else {
                    HapticFeedbackConstants.KEYBOARD_TAP
                },
                enabled = operatorSettings.hapticsEnabled.value,
            )
        }
        val handleFocusFeedAction: (FocusFeedGestureAction) -> Unit = handleFocusFeedAction@{ action ->
            when (action) {
                is FocusFeedGestureAction.SetFocusPoint -> {
                    if (!focusGestureContext.canSetFocusPoint) {
                        return@handleFocusFeedAction
                    }
                    // The operator chose to AF at a point — subsequent releases resume normal
                    // AF focus (iOS clears the same flag before changeAfArea).
                    mfDrive.clearManualFocus()
                    // …and the tap wins the command channel: drop any retrying focus drive so
                    // changeAfArea isn't stuck behind it on cameraCommandMutex (iOS
                    // `applyFocusPoint` → `cancelManualFocusDrive`).
                    mfDrive.cancel()
                    focusMoveRequestsInFlight += 1
                    recordScope.launch {
                        try {
                            val accepted =
                                session.changeAfArea(
                                    CameraFocusPoint(action.coordinate.x, action.coordinate.y),
                                )
                            if (accepted && operatorSettings.hapticsEnabled.value) {
                                view.performOperatorHaptic(HapticFeedbackConstants.KEYBOARD_TAP)
                            }
                        } catch (error: CameraFocusException) {
                            commonControl.onNote(error.message
                                ?: appContext.getString(R.string.focus_change_rejected))
                        } finally {
                            focusMoveRequestsInFlight =
                                (focusMoveRequestsInFlight - 1).coerceAtLeast(0)
                        }
                    }
                }
                is FocusFeedGestureAction.RequestDisplayMode -> {
                    if (!focusGestureContext.canRecognizeDisplayGesture) {
                        return@handleFocusFeedAction
                    }
                    if (operatorSession.select(action.mode) && operatorSettings.hapticsEnabled.value) {
                        view.performOperatorHaptic(HapticFeedbackConstants.CLOCK_TICK)
                    }
                }
                FocusFeedGestureAction.ToggleFocusPointLock -> toggleFocusPointLock()
            }
        }
        val focusResetVisible =
            focusResetAvailable(feedFocus, focusPointLocked) &&
                // A watcher has no focus-box source to recenter (iOS `.focusBox` mount rule):
                // the relayed session reads Connected, so the availability gate must lead.
                mounted(MonitorDisplaySection.FOCUS_BOX) &&
                sessionState is CameraSessionState.Connected &&
                !mediaOwnsCommandChannel &&
                !otherCameraCommandPending
        val requestFocusReset: () -> Unit = resetFocusPoint@{
            if (focusCommandPending) return@resetFocusPoint
            focusResetPending = true
            // The recenter sequence owns the command channel next, not a retrying focus drive.
            mfDrive.cancel()
            recordScope.launch {
                try {
                    session.resetFocusPoint()
                    if (operatorSettings.hapticsEnabled.value) {
                        view.performOperatorHaptic(HapticFeedbackConstants.KEYBOARD_TAP)
                    }
                } catch (error: CameraFocusException) {
                    commonControl.onNote(error.message ?: appContext.getString(R.string.focus_reset_failed))
                } finally {
                    focusResetPending = false
                }
            }
        }
        val displayModeDescription =
            stringResource(
                R.string.display_mode_description,
                stringResource(effectiveDisplayMode.labelResource()),
            )
        val liveViewDescription =
            when {
                monitorFrameSource == null -> stringResource(R.string.live_view_unavailable)
                focusPointLocked -> stringResource(R.string.live_view_focus_locked)
                focusGestureContext.canRecognizeFocusGesture ->
                    stringResource(R.string.live_view_focus_available)
                else -> stringResource(R.string.live_view_focus_unavailable)
            }
        val focusLockActionLabel =
            stringResource(
                if (focusPointLocked) R.string.focus_unlock_position
                else R.string.focus_lock_position,
            )
        val openSharedPicker: (MonitorPickerKind) -> Unit = { kind ->
            assists.shared.configureTool = null
            activeCommandControl = null
            activeMonitorPickerKind = nextMonitorPicker(activeMonitorPickerKind, kind,
                sessionState is CameraSessionState.Connected && !locked && editingDisplay == null &&
                    isMonitorFront && pendingCommandControl == null)
            commandControlFeedback = null
        }
        val nativeSettings = if (isPhotographyMode) photographySettings else captureSettings
        fun fieldFor(kind: MonitorPickerKind): MonitorCaptureField? {
            if (isPhotographyMode) return null
            val key = when (kind) {
                MonitorPickerKind.ISO -> SettingKey.ISO
                MonitorPickerKind.SHUTTER -> SettingKey.SHUTTER
                MonitorPickerKind.IRIS -> SettingKey.APERTURE
                MonitorPickerKind.WHITE_BALANCE -> SettingKey.WHITE_BALANCE
                else -> return null
            }
            return commonControl.captureField(key)
        }
        val readouts: List<MonitorOperatorLiveReadout<String, MonitorDisplaySection>> = nativeSettings.map { setting ->
            val field = fieldFor(setting.kind)
            MonitorOperatorLiveReadout(setting.kind.name, field?.title ?: setting.label,
                if (field != null) field.label else setting.value, field = field,
                quickEnabled = setting.kind != MonitorPickerKind.SHUTTER || isPhotographyMode ||
                    (effectiveShutterLocked == false && cameraProperties.shutterMode != null),
            )
        }
        val scopes = scopesShown { assists.shared.rendersLive(it, effectiveDisplayMode, isPhotographyMode) }
        val emptyScopes = remember { MutableStateFlow(com.opencapture.opencine.media.ScopeAssistBundle.EMPTY) }
        val scopeSource = monitorFrameSource?.let { source -> rememberNikonLiveScopeBundles(scopes,
            portraitScopes, assists.shared, exposureAssistCameraInput, renderedEffects.lut, lutLibrary,
            thermalTier, source, isPortrait, isPortraitFill, scopeZone) } ?: emptyScopes
        val floating = MonitorAnalysisPanelLayout(physicalViewport, geometry.scopePlacement)
        val reference = liveFeedEffectsPresentation.falseColorReference?.let { value ->
            value.referenceValues(falseColorReferenceCopy(value.scale)).takeIf { it.segments.isNotEmpty() }
        }
        val placement = MonitorAssistPanelPlacement(
            read = { tool, portrait -> if (tool == MonitorAssistTool.AUDIO) assists.shared.audioCenterFor(portrait)
                else assists.shared.centerFor(tool, portrait) },
            write = { tool, center, portrait -> if (tool == MonitorAssistTool.AUDIO) assists.shared.storeAudioCenter(center, portrait)
                else assists.shared.storeCenter(tool, center, portrait) },
            falseColorDefaultHorizontalFraction = if (isPortraitFill) 1f else 0f,
            portraitAudioTrailingGapDp = 10f, landscapeAudioTrailingGapDp = 10f,
            audioBottomGapDp = 14f + LiveDesign.CONTROL_HEIGHT_DP,
            movementInsetDp = 0f, referenceDefaultFrame = controlSafeFalseColorReferenceDefaultFrame(
                fieldLayout.picture, floating, horizontalFraction = if (isPortraitFill) 1f else 0f))
        val lutImportLauncher =
            androidx.activity.compose.rememberLauncherForActivityResult(
                androidx.activity.result.contract.ActivityResultContracts.OpenDocument(),
            ) { uri ->
                val library = lutLibrary
                if (uri != null && library != null) {
                    recordScope.launch {
                        when (val result = library.importDocument(appContext.contentResolver, uri)) {
                            is com.opencapture.opencine.cameracontrols.MonitorLutImportResult.Imported -> {
                                // iOS importCustomLUT: select + enable the LUT immediately —
                                // the graded feed is the confirmation the operator sees.
                                if (library.prepare(result.entry.selection)) {
                                    assists.selectLut(FeedLutSelection.Stored(result.entry.selection))
                                }
                                commonControl.onNote("${result.entry.displayName} imported.")
                            }
                            is com.opencapture.opencine.cameracontrols.MonitorLutImportResult.Rejected ->
                                commonControl.onNote(result.message)
                        }
                    }
                }
            }
        val assistSource = MonitorOperatorAssistSource(
            AssistHost(com.opencapture.openzcine.settings.SettingsPalette.peaking,
                com.opencapture.openzcine.settings.SettingsPalette.highlight, com.opencapture.openzcine.settings.SettingsPalette.midtone),
            scopeSource, scopeStackMoved = {}, lookPicker = null, panelPlacement = placement,
            preview = { tool -> NikonInspectorImagePreview(tool, assists, inspectorPreview,
                exposureAssistCameraInput, lutLibrary, inspectorSourceIdentity, liveFeedPresentation.colorMode) },
            lookMenu = { NikonLutOptions(assists, lutLibrary,
                onOpenRedDownload = { assists.shared.configureTool = null; redDownloadPresented = true },
                onRequestLutImport = lutLibrary?.let { { lutImportLauncher.launch(arrayOf("*/*", "application/octet-stream")) } },
                includesComparison = false) }, paradeIntensityScale = 1.0)
        val haptics = com.opencapture.opencine.appkit.LocalOperatorHaptics.current
        val signal = MonitorOperatorSignalOptions(
            falseColor = { com.opencapture.openzcine.settings.nikonAssistSection(MonitorAssistTool.FALSE,
                assists.shared, exposureAssistCameraInput, haptics::selection)?.Menu() },
            zebra = { com.opencapture.openzcine.settings.nikonAssistSection(MonitorAssistTool.ZEBRA,
                assists.shared, exposureAssistCameraInput, haptics::selection)?.Menu() },
            reference = reference, referenceAvailable = reference != null,
            level = { com.opencapture.monitorui.settings.MonitorSettingsChoices(LocalLevelStyle.entries,
                operatorSettings.levelStyle, accentSelection = true, title = LocalLevelStyle::label) {
                haptics.selection(); operatorSettings.levelStyle = it } },
            instantReview = { NikonReviewOptions(assists) })
        val usageStore = remember(appContext) { com.opencapture.opencine.appkit.MonitorToolUsagePreferences(
            appContext.getSharedPreferences("assist", android.content.Context.MODE_PRIVATE), "assistToolUsage.v1") }
        var usage by remember(usageStore) { mutableStateOf(usageStore.value) }
        val palette = liveAssistChips.map { chip ->
            val tool = (chip as? NikonAssistChip.Tool)?.tool
            MonitorOperatorPaletteItem(chip.id, tool?.title ?: "Instant Playback", tool?.chipLabel ?: "PLAY", tool,
                if (tool != null) assists.shared.isOn(tool) else assists.instantReview,
                toggle = { haptics.selection(); if (tool != null) assists.shared.toggle(tool)
                    else assists.instantReview = !assists.instantReview }, hasOptions = tool?.nikonHasOptions == true,
                glyph = if (tool == null) ({ tint, decoration -> MonitorIcon(MonitorIcon.IMAGE, null, decoration, tint) }) else null)
        }
        val reset = if (focusResetVisible) MonitorOperatorFocusReset(
            stringResource(when { focusResetPending -> R.string.focus_resetting
                focusMoveRequestsInFlight > 0 -> R.string.focus_reset_moving; else -> R.string.focus_reset }),
            !focusCommandPending, focusResetPending, requestFocusReset) else null
        val comparison = if (renderedEffects.lut != null && assists.shared.splitComparison) MonitorOperatorLookComparison(
            stringResource(R.string.split_comparison_key), splitComparisonMuted) { splitComparisonMuted = !splitComparisonMuted } else null
        val identity = MonitorOperatorLiveIdentity(sharedControlState.snapshot?.session,
            sharedControlState.snapshot?.epoch, pictureFrameSource)
        val currentPicture = rememberUpdatedState(pictureFrameSource)
        val statusStorage = if (isPhotographyMode && mounted(MonitorDisplaySection.TIMECODE)) {
            val storage = cameraProperties.storage
            val capacity = storage?.readout?.takeIf { photoPillShowsStorage && it.totalBytes != null }
            MonitorOperatorLiveReadout<String, MonitorDisplaySection>("shots", "Shots remaining",
                if (capacity != null) "${capacity.free} ${capacity.percent}"
                else cameraProperties.shotsRemaining?.let { "${shotsRemainingCompactLabel(it)} SHOTS" },
                MonitorDisplaySection.TIMECODE, action = { photoPillShowsStorage = !photoPillShowsStorage })
        } else if (mounted(MonitorDisplaySection.STORAGE)) MonitorOperatorLiveReadout("storage", "Media remaining",
            topBarMedia, MonitorDisplaySection.STORAGE, action = { prefersMediaDuration = !prefersMediaDuration }) else null
        val resolutionKind = if (isPhotographyMode) MonitorPickerKind.SIZE else MonitorPickerKind.RESOLUTION
        val codecKind = if (isPhotographyMode) MonitorPickerKind.QUALITY else MonitorPickerKind.CODEC
        val panelValue = activeMonitorPicker?.let { picker -> MonitorOperatorCameraPanel(picker.kind.name,
            picker.kind.isTopBarPicker(), if (picker.kind == MonitorPickerKind.QUALITY) 400f else 340f,
            if (picker.kind == MonitorPickerKind.QUALITY) 380f else 300f,
            chrome = if (picker.kind in ladderKinds) MonitorOperatorCameraPanelChrome.SHARED_SHEET else MonitorOperatorCameraPanelChrome.CONTENT,
            title = picker.title, subtitle = picker.subtitle) }
            ?: activeCommandControl?.let { request -> MonitorOperatorCameraPanel("command:${request.control.name}",
                false, chrome = MonitorOperatorCameraPanelChrome.CONTENT, title = request.title,
                subtitle = stringResource(R.string.command_current_value, request.currentValue)) }
        val headerReadouts = listOfNotNull(
            if (!mounted(MonitorDisplaySection.FORMAT)) null else MonitorOperatorLiveReadout(resolutionKind.name, "Image size",
                if (isPhotographyMode) cameraProperties.stillSizeAreaLabel() else readoutRetention.resolution,
                MonitorDisplaySection.FORMAT, action = { openSharedPicker(resolutionKind) }),
            if (!mounted(MonitorDisplaySection.CODEC)) null else MonitorOperatorLiveReadout(codecKind.name, "Codec",
                if (isPhotographyMode) cameraProperties.stillQualityCompactLabel() else readoutRetention.codec,
                MonitorDisplaySection.CODEC, action = { openSharedPicker(codecKind) }))
        val quickPickers = nativeSettings.mapNotNull { setting -> setting.picker?.let { setting.kind to it } }.toMap() +
            if (isPhotographyMode) photographyTopPickers else topPillPickers
        val snapshot = sharedControlState.snapshot
        val quickCommandsEnabled = commandControlsEnabled && editingDisplay == null && isMonitorFront &&
            lifecycleState.isAtLeast(Lifecycle.State.RESUMED) && pendingCommandControl == null &&
            (recoveryStateOverride ?: sessionRecoveryState) == SessionRecoveryUi.Idle &&
            snapshot?.connection == com.opencapture.opencine.core.ConnectionState.Ready &&
            (snapshot.authority == com.opencapture.opencine.core.ControlAuthority.Owner ||
                snapshot.authority is com.opencapture.opencine.core.ControlAuthority.Lease)
        val (captureInputs, nativeQuickReceipts) = nikonCaptureInputs(readouts, headerReadouts, panelValue,
            quickPickers, cameraProperties, identity, session.reportedRecording.value, quickCommandsEnabled,
            quickCaptureOwner,
            columns = if (isPortrait && !fieldLayout.tablet) { if (isPhotographyMode) 5 else 3 } else readouts.size,
            open = { id -> MonitorPickerKind.entries.firstOrNull { it.name == id }?.let(openSharedPicker) },
            dismiss = { activeMonitorPickerKind = null; activeCommandControl = null; commandControlFeedback = null },
            commit = { key, captured, target ->
                val admission = com.opencapture.opencine.nikon.CameraCommandAdmission(session) {
                    val latest = commonControl.state.value.snapshot
                    session.state.value is CameraSessionState.Connected &&
                        latest?.session == captured.source.camera && latest?.epoch == captured.source.epoch &&
                        latest?.connection == com.opencapture.opencine.core.ConnectionState.Ready &&
                        (latest.authority == com.opencapture.opencine.core.ControlAuthority.Owner ||
                            latest.authority is com.opencapture.opencine.core.ControlAuthority.Lease) &&
                        captured.admitsReported(session.cameraProperties.value, session.reportedRecording.value, target) &&
                        quickCaptureOwner.admits(key, captured, target)
                }
                recordScope.launch {
                    try {
                        session.applyControl(captured.request.control, target, admission)
                        if (admission.admits(session)) session.refreshProperties()
                    } catch (error: CameraControlException) {
                        if (admission.admits(session)) commandControlFeedback = CommandControlFeedback(
                            appContext.getString(R.string.control_error, captured.request.title,
                                error.message ?: appContext.getString(R.string.control_change_rejected)), isError = true)
                    }
                }
            })
        SideEffect { quickCaptureOwner.publish(nativeQuickReceipts) }
        val source = MonitorOperatorLiveSource(
            identity = { MonitorOperatorLiveIdentity(commonControl.state.value.snapshot?.session,
                commonControl.state.value.snapshot?.epoch, currentPicture.value) },
            available = available,
            picture = MonitorOperatorLivePicture(portraitFeedAspectRatio,
                // A connected camera that has not delivered a picture yet looks exactly like a wedged one;
                // the demo feed's first frame is synthetic and instant.
                waiting = pictureFrameSource != null && !hasPresentedFrame && !isDemoSession &&
                    sessionState is CameraSessionState.Connected,
                vertical = isVerticalFeed, flipped = renderedFraming.mirrorsHorizontally,
                recovering = (recoveryStateOverride ?: sessionRecoveryState) != SessionRecoveryUi.Idle),
            status = MonitorOperatorLiveStatus({ commonControl.statusPresentation() },
                !isPhotographyMode && mounted(MonitorDisplaySection.TIMECODE),
                !isPhotographyMode && mounted(MonitorDisplaySection.REC_READOUT), statusStorage, headerReadouts,
                link.label, link.bars,
                MonitorDisplaySection.FPS, recordingSection = MonitorDisplaySection.REC_READOUT,
                timecodeSection = MonitorDisplaySection.TIMECODE),
            // A watcher's camera battery arrives over the relay as the host's raw level (cameraReadouts).
            cameraBattery = nikonCameraBatteryReading(cameraReadouts.batteryPercent, cameraReadouts.externalPower),
            capture = captureInputs,
            record = MonitorOperatorRecordSource(isPhotographyMode, operatorSettings.recordConfirmationEnabled.value,
                busy = !recordControlEnabled, openMode = null, confirmingChanged = { recordConfirmationOpen = it }),
            // The body's 1/6 EV exposure indicator, photography only, on the shared gauge (A1-32);
            // the level stays native (A3-25).
            exposure = if (isPhotographyMode) { { nikonExposureStops(cameraProperties) } } else null,
            level = null, levelViewFlip = false, audio = null,
            // Control held by a watcher, a camera this device cannot drive, or a card transfer that owns
            // the command channel: presentation stays, commands are refused.
            readOnly = controlsSurrendered || !availability.canDriveCamera || mediaOwnsCommandChannel ||
                sessionState !is CameraSessionState.Connected,
            borrowed = borrowed, returnToStage = returnToStage, coverOpen = !isMonitorFront,
            note = note, clearNote = clearNote, vpnActive = { com.opencapture.opencine.platform.LocalVPNProbe.isActive(appContext) },
            settings = onOpenSettings, media = onOpenMedia,
            audioLevels = if (renderedAudioMeters) MonitorOperatorLiveAudio(liveAudioLevels?.let { levels ->
                com.opencapture.opencine.media.MonitorAudioMeterLevels(
                    com.opencapture.opencine.media.MonitorAudioMeterChannel(levels.left.levelDb, levels.left.peakDb),
                    com.opencapture.opencine.media.MonitorAudioMeterChannel(levels.right.levelDb, levels.right.peakDb)) },
                "${stringResource(R.string.audio_sensitivity_label)}\n${displayedAudioSensitivity(cameraProperties.microphoneSensitivity)}",
                stringResource(R.string.audio_no_data), if (liveAudioLevels?.isDebugFixture == true) "DEBUG FIXTURE\nNOT CAMERA AUDIO" else null,
                audioMeterStateDescription(resources.phoneStringResolver(), liveAudioLevels,
                    cameraProperties.microphoneSensitivity)) else null,
        )
        // Scopes that are not fitted float; GUIDES, GRID and CROSS ride the picture in the camera's own
        // orientation (they rotate with a vertical body), so the shared overlay leaves them alone.
        val rendered = liveAssistTools.filter { tool ->
            tool !in setOf(MonitorAssistTool.GUIDES, MonitorAssistTool.GRID, MonitorAssistTool.CROSS) &&
                assists.shared.rendersLive(tool, effectiveDisplayMode, isPhotographyMode) &&
                (tool !in ScopeKind.canonical.map { it.assistTool } ||
                    (scopeSource !== emptyScopes && (!isPortrait || isPortraitFill || tool.scopeKind in portraitScopes)))
        }.toSet()
        MonitorOperatorLiveSurface(commonControl, operatorSession, geometry, source,
            MonitorOperatorLiveAssists(assistSource, palette, rendered, null, signal, usage,
                { usage = it; usageStore.value = it }, nikonUsageSeed,
                fitted = if (scopeSource !== emptyScopes) portraitScopes.map { it.assistTool } else emptyList()),
            MonitorOperatorBodyViews(
                dashboard = { accepts ->
                    CommandDashboard(commandPresentation, isPortrait, commandControlsEnabled && accepts,
                        pendingCommandControl, openCommandControl, moveCommandTileTo,
                        link.label, link.bars)
                },
                focusDrive = if (
                    // Operator preference (FOCUS popup toggle, iOS `mfDriveScrubEnabled`), default OFF; off
                    // hides the strip even in an AF focus mode. Video and photo alike.
                    operatorSettings.mfDriveScrubEnabled.value && !isClean &&
                        sessionState is CameraSessionState.Connected && !isDemoSession &&
                        // Mirrors the shared core's `MFDriveEligibility.resolve`: no mode or MF means no dial
                        // (the lens ring owns focus in MF); AF-F mounts it inert below.
                        mfDriveEligibility(cameraProperties.activeFocusMode(photography = isPhotographyMode)) !=
                            MfDriveEligibility.UNAVAILABLE &&
                        // The strip absorbs taps, so it waits for every panel to close (iOS `showsMFDriveScrub
                        // … && activePanel == nil`).
                        activeCommandControl == null && activeMonitorPickerKind == null &&
                        assists.shared.configureTool == null
                ) { accepts ->
                    // Re-arm the relative position when the dial (re)appears.
                    DisposableEffect(Unit) {
                        mfDrive.resetDial()
                        onDispose {}
                    }
                    // The shared admission decides whether the lens may move (A3-02): a surrendered or
                    // read-only monitor shows the strip inert.
                    MFDriveStrip(
                        atEnd = mfDriveAtEnd,
                        enabled = accepts && mfDriveEligibility(
                            cameraProperties.activeFocusMode(photography = isPhotographyMode),
                        ) == MfDriveEligibility.DRIVABLE,
                        onDrive = { pulses -> mfDrive.drive(recordScope, pulses) },
                        modifier = Modifier.fillMaxSize(),
                        netPulses = mfDriveNetPulses,
                        dialFraction = mfDriveDialFraction,
                    )
                } else null,
                resetFocus = reset, comparison = comparison),
            modifier = Modifier.fillMaxSize(),
            portraitAspect = portraitAspect,
            setPortraitAspect = { operatorSettings.portraitFeedAspect = it },
            picture = {
            Box(
                Modifier.zone(effectiveFeed)
                    .clipToBounds()
                    // Canvas content is not exposed as an accessibility node
                    // by every Android view bridge. The feed container is the
                    // stable, descriptive region for TalkBack and UI tests.
                    .semantics {
                        stateDescription = displayModeDescription
                        contentDescription = liveViewDescription
                        if (focusGestureContext.canRecognizeFocusGesture) {
                            onLongClick(
                                label = focusLockActionLabel,
                            ) {
                                toggleFocusPointLock()
                                true
                            }
                        }
                    }
                    .testTag("monitor_live_feed"),
                contentAlignment = Alignment.Center,
            ) {
            liveBackdrop?.let { backdrop ->
                // Passive geometry for the shared material: where the picture draws in this zone. It
                // stays outside the punch-in layer, so a zoomed picture samples unzoomed (blurred anyway).
                Box(Modifier.matchParentSize().monitorBackdropSource(backdrop.source,
                    imageRect = liveBackdropImageRect(effectiveFeed.width * density.density,
                        effectiveFeed.height * density.density, liveFeedPresentation.sourceWidth,
                        liveFeedPresentation.sourceHeight, portraitRasterFill,
                        localFraming.horizontalPresentationScale, localFraming.verticalPresentationScale),
                    mirrored = renderedFraming.mirrorsHorizontally,
                    flippedVertically = renderedFraming.flipsVertically))
            }
            Box(
                // Vertical mode first: the whole feed stack — raster, AF boxes, punch-in,
                // gestures — lays out in the camera's own frame and rotates upright as one,
                // inside the zone clip.
                Modifier.liveFeedBodyRotation(displayedFeedRotation)
                    // Punch-in goes LAST and wraps the WHOLE feed stack, not just the raster: the
                    // AF box and focus ring are siblings of it, so scaling the raster alone would
                    // leave them behind at unmagnified positions over a magnified picture. Inside
                    // clipToBounds so the magnified frame is still cropped to the feed zone; ahead
                    // of the gestures so Compose maps a touch back through the scale and
                    // tap-to-focus still lands on the pixel under the finger.
                    // OUTSIDE the zoom layer, as the playback viewer's is. Inside it, Compose maps
                    // pointer positions back through the scale before reporting them, so a finger
                    // travelling D pixels arrives as D/scale and the picture tracks at a fraction
                    // of the finger — worse the further you zoom.
                    //
                    // Pinch always transforms; a one-finger drag only pans once zoomed, so an
                    // unzoomed drag still reaches the DISP swipe in the arbiter below.
                    .transformable(
                        state = feedTransformState,
                        canPan = { committedZoom.isZoomed },
                    )
                    .graphicsLayer {
                        // A CENTER-anchored scale then the offset, in that order — the pair every
                        // formula in FeedZoom is written against. Anchoring on the AF box instead
                        // (as the retired MAG tool did) would make the pinch pivot somewhere the
                        // operator's fingers are not.
                        //
                        // Read inside this lambda on purpose: graphicsLayer defers its state reads
                        // to the draw phase, so a gesture redraws without recomposing.
                        val zoom = committedZoom
                        scaleX = zoom.scale
                        scaleY = zoom.scale
                        transformOrigin = TransformOrigin.Center
                        translationX = zoom.offsetX
                        translationY = zoom.offsetY
                    }
                    .onSizeChanged { feedPointerSize = it }
                    // Stays INSIDE the layer: tap-to-focus wants its coordinates mapped back
                    // through the scale so a tap lands on the pixel under the finger.
                    .focusFeedGestures(
                        sourceIdentity = sharedControlState.snapshot?.let { it.session to it.epoch },
                        geometry = feedGestureGeometry,
                        context = focusGestureContext,
                        isPortrait = isPortrait,
                        isZoomed = isFeedZoomed,
                        onHoldingChanged = { focusLockHolding = it },
                        // A zoom or a pan must never move the focus box. The arbiter lives inside
                        // the zoom layer, so its coordinates are divided by the scale: a 200px pan
                        // at 4x reaches it as 50px, lands under its tap threshold, and would be
                        // read as a tap-to-focus. Deferring to the transform while it is running
                        // settles it by intent rather than by tuning a threshold against a moving
                        // coordinate space. A discrete tap starts no transform and still focuses.
                        onAction = { action ->
                            if (!feedTransformState.isTransformInProgress) {
                                handleFocusFeedAction(action)
                            }
                        },
                    ),
                contentAlignment = Alignment.Center,
            ) {
                if (pictureFrameSource != null) {
                    LiveFeedView(
                        pictureFrameSource,
                        // De-squeeze only. The punch-in is a separate layer on the feed container
                        // so it also carries the AF box and focus ring, and so it can take its own
                        // origin — the two transforms need different ones.
                        Modifier.fillMaxSize().graphicsLayer {
                            scaleX = localFraming.horizontalPresentationScale
                            scaleY = localFraming.verticalPresentationScale
                        },
                        incidentObserver = incidentProducer,
                        onPresentedFrame = { frame, bitmap, baker, look ->
                            // TC is owned by the stream collector above; present
                            // path only drives FPS + wear (decode can lag a take).
                            presentedFrames.presented(android.os.SystemClock.elapsedRealtime())
                            hasPresentedFrame = true
                            recoveryPictures.notePresented()
                            inspectorPreview.accept(pictureFrameSource, bitmap)
                            wearRelay.ingestPresentedFrame(session, frame, bitmap, baker)
                            liveBackdrop?.accept(pictureFrameSource, bitmap, look)
                        },
                        presentationState = liveFeedPresentation,
                        collectFrames = monitorFrameSource != null,
                        effects = renderedEffects,
                        configuration = assists.shared.feedEffectsConfiguration,
                        cameraInput = exposureAssistCameraInput,
                        lutLibrary = lutLibrary,
                        effectsPresentationState = liveFeedEffectsPresentation,
                        aspectFill = portraitRasterFill,
                        // Reads the DISP-filtered set, not the raw config, so clean view honours
                        // the pin exactly as every other framing tool does.
                        mirrored = renderedFraming.mirrorsHorizontally,
                        mirroredVertical = renderedFraming.flipsVertically,
                        // A rotated (vertical) feed presents via Compose: SurfaceView buffers
                        // composite outside the Compose layer and never rotate with it.
                        preferComposablePresentation = displayedFeedRotation != LiveFeedRotation.LANDSCAPE,
                    )
                    // Nothing draws over the picture here: the waiting plate is the surface's, and the
                    // picture carries no texture (A3-04).
                } else {
                    // Hop-aware status: after RED/Frame.io internet hop the session is
                    // Disconnected while Wi‑Fi rejoins — never leave the operator on a bare
                    // "No camera" while we are actively searching / rejoining.
                    MonitorFeedCameraStatus(status = cameraFeedStatus)
                }
                LocalFramingAssistOverlay(
                    configuration = renderedFraming,
                    presentationState = liveFeedPresentation,
                    aspectFill = portraitRasterFill,
                    splitComparison = renderedEffects.activeSplitComparison,
                )
                LiveFrameMetadataOverlay(
                    presentationState = liveFeedPresentation,
                    configuration = renderedFraming,
                    isPortrait = isPortrait,
                    aspectFill = portraitRasterFill,
                    gaugeBottomChromeInset = levelGaugeBottomChromeInset,
                    focusPointLocked = focusPointLocked,
                    focusLockProgress = focusLockProgress,
                    focusBoxVisible = mounted(MonitorDisplaySection.FOCUS_BOX),
                    focusBoxAlpha = 1f,
                    // The editor's outline, dimming and badge, through the surface's one editor.
                    focusBoxEditModifier = if (editingDisplay == null) null
                        else Modifier.monitorOperatorChromeEditable(MonitorDisplaySection.FOCUS_BOX),
                )
            }
                // Outside the rotated stack: reads as screen chrome, never sideways text.
                LiveFeedColorModeNotice(
                    colorMode = liveFeedPresentation.colorMode,
                    effectsActive = !renderedEffects.isIdentity,
                    modifier =
                        Modifier.align(Alignment.TopCenter)
                            .padding(top = liveFeedColorNoticeTopInset.dp),
                )
            }
            },
            cameraPanel = { key, pickerFrame, isTopDropDown, _ ->
                activeMonitorPicker?.takeIf { it.kind.name == key }?.let { picker ->
                    CompositionLocalProvider(com.opencapture.opencine.cameracontrols.LocalViewportPortrait provides isPortrait) {
                    MonitorControlPickerPanel(
                        picker = picker,
                        frame = pickerFrame,
                        commonControl = if (isPhotographyMode) null else commonControl,
                        commonField = fieldFor(picker.kind),
                        controlsEnabled = commandControlsEnabled,
                        pendingControl = pendingCommandControl,
                        feedback = commandControlFeedback,
                        onSelect =
                            if (isPhotographyMode) {
                                applyPhotographyControl
                            } else {
                                applyCameraControl
                            },
                        // Unconditional (#328): never hold the popup hostage to an in-flight
                        // write — the drain loop completes it with the panel closed (iOS
                        // `dismissActivePanel` has no pending gate either).
                        onDismiss = {
                            activeMonitorPickerKind = null
                            commandControlFeedback = null
                        },
                        slideFromTop = isTopDropDown,
                        // The stills SHUTTER picker has no movie TV-lock hold.
                        onShutterLongPress =
                            if (isPhotographyMode) null else shutterLongPressToggle,
                        timerShotsCount = photoTimerShotCount,
                        onAdjustTimerShots =
                            if (isPhotographyMode) {
                                { delta ->
                                    photoTimerShotCount =
                                        (photoTimerShotCount + delta).coerceIn(1, 9)
                                }
                            } else {
                                null
                            },
                        nefCompression = cameraProperties.rawCompression,
                        nefOptions =
                            cameraProperties.controlCapabilities.options(
                                CameraControl.STILL_RAW_COMPRESSION),
                        mfScrubEnabled = operatorSettings.mfDriveScrubEnabled.value,
                        onToggleMfScrub = { operatorSettings.mfDriveScrubEnabled.toggle() },
                        chromeless = true,
                    )
                    }
                }
                activeCommandControl?.takeIf { "command:${it.control.name}" == key }?.let { request ->
                    CompositionLocalProvider(com.opencapture.opencine.cameracontrols.LocalViewportPortrait provides isPortrait) {
                        CommandControlDialog(
                            request = request,
                            controlsEnabled = commandControlsEnabled,
                            pendingControl = pendingCommandControl,
                            feedback = commandControlFeedback,
                            onSelect = { label -> applyCameraControl(request, label) },
                            onDismiss = { activeCommandControl = null },
                            chromeless = true,
                        )
                    }
                }
            },
            photoRelease = { enabled, decoration -> MonitorPhotoRelease(geometry.layout.record.width, enabled, decoration,
                capturing = stillCapturing, timerRemaining = photoTimerRemaining, bodyPulse = bodyShutterPulse,
                onPressed = photoShutterPressed, onReleased = photoShutterReleased) },
        )

        // App self-timer tally: a white border pulse at the physical edge per
        // countdown tick (iOS timer tally), fading within each second.
        photoTimerRemaining?.let { remaining ->
            val pulse = remember(remaining) { Animatable(1f) }
            LaunchedEffect(remaining) {
                pulse.animateTo(0.2f, animationSpec = tween(durationMillis = 900))
            }
            Box(
                Modifier.fillMaxSize()
                    .border(
                        4.dp,
                        Color.White.copy(alpha = pulse.value),
                        RoundedCornerShape(24.dp),
                    ),
            )
        }

        // Post-capture instant playback cover (photography PLAY tool): the
        // just-captured still full-screen until the duration elapses or a tap.
        instantReviewState?.let { review ->
            InstantReviewOverlay(
                review = review,
                onDismiss = instantReview::dismiss,
                onToggleStar = { starred -> instantReview.setStarred(recordScope, starred) },
                desqueeze = localFraming,
                options = assists.reviewOptions,
            )
        }

        // Dropped-session recovery over the held frame: the shared card and its grace (iOS `MonitorRecoveryOverlay`).
        // Nikon bodies drop the session when another phone scans for them, so the paused copy says so.
        com.opencapture.opencine.cameracontrols.MonitorOperatorRecoveryCard(
            state = recoveryStateOverride ?: sessionRecoveryState,
            cameraName = recoveryStateOverride?.let { "Nikon ZR" } ?: lastConnectedCameraName,
            onRetry = {
                // Operator intent: a fresh drop ledger and a fresh episode (iOS parity). The
                // recovery effect hands the ticket to its coordinator.
                sessionRecoveryRetryTicket += 1
            },
            onOperatorMenu = onBackToOperatorMenu,
            dropSuspect = com.opencapture.opencine.vocabulary.SessionDropSuspect.OTHER_DEVICE_SCANNING,
        )
        // Registered HERE, not inside the options popup: launching the document picker pauses
        // the activity and the transient popup dismisses with it, so a launcher remembered in
        // the popup composition is disposed exactly when its result arrives — every picked
        // cube was silently dropped (#295). The monitor composition survives the round trip.
        if (redDownloadPresented && lutLibrary != null) {
            com.opencapture.openzcine.lut.RedLutDownloadScreen(
                lutLibrary = lutLibrary,
                frameioController = frameioController,
                onClose = { redDownloadPresented = false },
                onImported = { count ->
                    if (count > 0) assists.shared.armLut()
                },
            )
        }

    }
}

/**
 * iOS shutter long-press: toggle `MovieTVLockSetting` (0.45s hold on the
 * SHUTTER capture cell **or** open shutter picker — “hold anywhere”). Lock is
 * not a picker tab (Angle / Speed only). Always builds a
 * [CameraControl.SHUTTER_LOCK] write like iOS `unlock/lockShutterControlOnCamera`.
 *
 * @param onOptimisticShutterLocked mirrors iOS `pendingShutterLockState` so the
 * drum undims immediately while the write confirms.
 * @param shutterLockedOverride preferred lock state when optimistic UI is active.
 */
internal fun toggleShutterLockOnCamera(
    captureSettings: List<MonitorCaptureSettingPresentation>,
    cameraProperties: CameraPropertySnapshot,
    applyCameraControl: (CommandControlRequest, String) -> Unit,
    onOptimisticShutterLocked: ((Boolean) -> Unit)? = null,
    shutterLockedOverride: Boolean? = null,
) {
    // Need a shutter cell so we only long-press when shutter chrome is present.
    if (captureSettings.none { it.kind == MonitorPickerKind.SHUTTER }) return
    // null readback: still attempt Unlock so a settling body is not stuck behind a
    // non-functional long-press (iOS always sends the toggle).
    val locked = (shutterLockedOverride ?: cameraProperties.shutterLocked) != false
    val next = if (locked) "Unlocked" else "Locked"
    val options =
        cameraProperties.controlCapabilities.shutterLocks
            .ifEmpty { listOf("Unlocked", "Locked") }
    // Optimistic UI before the safe-point write lands (iOS lockedControls flip).
    onOptimisticShutterLocked?.invoke(next == "Locked")
    applyCameraControl(
        CommandControlRequest(
            title = "Shutter Lock",
            control = CameraControl.SHUTTER_LOCK,
            currentValue = if (locked) "Locked" else "Unlocked",
            options = options,
        ),
        next,
    )
}

/**
 * The sections something feeds now: the Kotlin twin of iOS `sectionHasASource`. Chrome the operator
 * switched on still hides when nothing can fill it: a readout with no source still looks like an
 * instrument, and the capture strip offers pickers that would write to a camera that cannot hear them.
 * The tool bar, lock, FPS chip and Settings work on any picture source; no Nikon source feeds a color
 * chip, a zoom chip or a gimbal stick.
 */
internal fun MonitorDataAvailability.monitorSections(
    /** The live-view header's timecode status bit; bodies with no timecode hardware pin it to zero. */
    cameraReportsTimecode: Boolean,
    isPhotographyMode: Boolean,
): Set<MonitorDisplaySection> =
    MonitorDisplaySection.entries.filter { section ->
        when (section) {
            MonitorDisplaySection.CAMERA_VALUES, MonitorDisplaySection.CODEC, MonitorDisplaySection.STORAGE,
            MonitorDisplaySection.FORMAT,
            -> cameraControls
            // A reading, not a control: the host forwards the camera's charge to a watcher.
            MonitorDisplaySection.BATTERIES -> receivesCameraMetadata
            MonitorDisplaySection.REC_READOUT, MonitorDisplaySection.RAIL_RECORD -> recordControl
            MonitorDisplaySection.RAIL_MEDIA -> mediaBrowser
            // Photography rents this slot for the SHOTS counter, gated on the camera link.
            MonitorDisplaySection.TIMECODE ->
                if (isPhotographyMode) cameraControls else cameraTimecode && cameraReportsTimecode
            MonitorDisplaySection.FOCUS_BOX -> focusBoxes
            MonitorDisplaySection.STATUS_BAR, MonitorDisplaySection.TOOL_BAR, MonitorDisplaySection.LOCK_BUTTON,
            MonitorDisplaySection.FPS, MonitorDisplaySection.RAIL_SETTINGS,
            -> true
            MonitorDisplaySection.COLOR, MonitorDisplaySection.ZOOM_CHIP, MonitorDisplaySection.GIMBAL_STICK -> false
        }
    }.toSet()

/**
 * A portrait phone's top inset for the shared field layout, at least 44 dp. The shared layout hangs
 * the battery and FPS band 40 dp above the status row, in the cutout; a phone with no top cutout
 * (0 under immersive) would stack the band on the status row, the batteries over CODEC and FPS over
 * the clock. From 44 dp up the band keeps the gap it has on a punch-hole phone.
 */
internal fun portraitPhoneSafeTop(safeTop: Float, width: Float, height: Float): Float =
    if (height > width && width < 600f) maxOf(safeTop, 44f) else safeTop

/** Localized DISP mode label for the monitor's accessibility description. */
@StringRes
private fun MonitorDisplayMode.labelResource(): Int =
    when (this) {
        MonitorDisplayMode.LIVE -> R.string.display_mode_live
        MonitorDisplayMode.CLEAN -> R.string.display_mode_clean
        MonitorDisplayMode.COMMAND -> R.string.display_mode_command
    }

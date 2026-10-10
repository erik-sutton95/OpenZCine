package com.opencapture.openzcine

import com.opencapture.monitorui.MonitorIcon
import com.opencapture.opencine.cameracontrols.*
import android.os.Build
import android.view.HapticFeedbackConstants
import android.widget.Toast
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.gestures.waitForUpOrCancellation
import com.opencapture.monitorui.MonitorAssistTool
import kotlinx.coroutines.withTimeoutOrNull
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.rememberTransformableState
import androidx.compose.foundation.gestures.transformable
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.positionChange
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.absoluteOffset
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.CircularProgressIndicator
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
import androidx.compose.runtime.mutableStateMapOf
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
import com.kyant.backdrop.backdrops.layerBackdrop
import com.kyant.backdrop.backdrops.rememberLayerBackdrop
import com.opencapture.opencine.core.SettingKey
import com.opencapture.opencine.appkit.rememberPhoneBatteryReadout
import com.opencapture.opencine.appkit.MonitorControlModel
import com.opencapture.opencine.appkit.MonitorCaptureField
import com.opencapture.opencine.appkit.captureField
import com.opencapture.opencine.appkit.commit
import com.opencapture.opencine.appkit.quickControl
import com.opencapture.opencine.appkit.MonitorCaptureDrum
import com.opencapture.opencine.appkit.MonitorCaptureButton
import com.opencapture.opencine.appkit.ChromeEditBadges
import com.opencapture.opencine.appkit.ChromeEditDoneBanner
import com.opencapture.opencine.appkit.ChromeEditHost
import com.opencapture.opencine.appkit.chromeEditable
import com.opencapture.monitorui.MonitorLayoutPolicy
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
import com.opencapture.openzcine.remote.AndroidMediaRemoteShutter
import com.opencapture.openzcine.remote.MediaRemoteShutterCommand
import com.opencapture.openzcine.remote.routeMediaRemoteShutterCommand
import com.opencapture.openzcine.remote.shouldArmMediaRemoteShutter
import com.opencapture.openzcine.settings.CaptureLayoutMode
import com.opencapture.openzcine.settings.ChromeSection
import com.opencapture.openzcine.settings.LocalLevelStyle
import com.opencapture.openzcine.settings.MonitorDisplayMode
import com.opencapture.openzcine.settings.labelResource
import com.opencapture.openzcine.settings.OperatorSettings
import com.opencapture.openzcine.settings.PortraitFeedAspect
import com.opencapture.openzcine.wear.AndroidWearPhoneRelay
import com.opencapture.openzcine.wear.WearRecordCommandSafety
import com.opencapture.openzcine.wear.androidWatchRelayState
import com.opencapture.openzcine.wear.executeWearRecordCommand
import com.opencapture.openzcine.wearrelay.WatchCommandResult
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.conflate
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import com.opencapture.opencine.nikon.IsoPickerPolicy
import com.opencapture.opencine.nikon.SwiftCoreLiveFrameSource
import com.opencapture.opencine.runtime.nativeFeedContentRect
import com.opencapture.opencine.vocabulary.SessionRecoveryUi
import com.opencapture.opencine.nikon.ProductionSessionRetryScheduleBridge

/** Gives the live quick-settings panel first refusal on the system Back action. */
@Composable
internal fun LiveAssistOptionsBackHandler(visible: Boolean, onDismiss: () -> Unit) {
    BackHandler(enabled = visible, onBack = onDismiss)
}

/**
 * A live capture picker stays mounted while its real camera command is in
 * flight, then closes when its mode or chrome region is no longer available.
 *
 * Top-bar resolution/codec pickers (iOS `CameraPicker.isTopBar`) do **not**
 * depend on the bottom capture strip — they stay open whenever live chrome is
 * active, matching iOS's independent top-deck panel host.
 */
internal fun retainMonitorPickerForChrome(
    mode: MonitorDisplayMode,
    cameraValuesVisible: Boolean,
    cameraCommandPending: Boolean,
    isTopBarPicker: Boolean = false,
): Boolean =
    cameraCommandPending ||
        (mode == MonitorDisplayMode.LIVE && (cameraValuesVisible || isTopBarPicker))

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

/** The on-feed 50/50 quick key, matching the iOS pill. */
private const val SPLIT_KEY_WIDTH_DP = 44f
private const val SPLIT_KEY_HEIGHT_DP = 30f

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
 * Chrome glass runs the GPU treatment (GlassChrome.kt) at this device's
 * [resolveTier] ceiling (FULL on API 33+ with enough RAM, else FLAT);
 * [glassTierOverride] (`zc.glass.tier` debug intent extra) can only lower.
 *
 * [assist] is shared with Operator Settings so toolbar and settings changes
 * immediately drive the same feed-effects and scope state.
 */
@Composable
internal fun MonitorScreen(
    session: CameraSession,
    commonSession: NikonOpenCineSession,
    commonControl: MonitorControlModel,
    frameSource: LiveFrameSource?,
    assists: NikonAssists,
    operatorSettings: OperatorSettings,
    lutLibrary: AndroidLutLibrary? = null,
    /**
     * Shared camera-AP → internet hop owner (Frame.io + RED download). Required
     * for "Download over internet" while bound to the camera access point.
     */
    frameioController: com.opencapture.openzcine.frameio.FrameioDeliveryController? = null,
    liveViewEnabled: Boolean = true,
    glassTierOverride: String? = null,
    mediaRemoteShutter: AndroidMediaRemoteShutter? = null,
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
        enabled = sessionRecoveryEnabled,
        retryTicket = sessionRecoveryRetryTicket,
        onRecoveryState = { sessionRecoveryState = it },
    )

    // Kyant layer-backdrop glass (AndroidLiquidGlass):
    //  • feedBackdrop — live view only; bars/chips sample with Modifier.glass.
    //  • sceneBackdrop — feed + chrome; pickers/assist use Modifier.overlayGlass
    //    so UI under a popup actually blurs (sibling-overlay pattern).
    // Older APIs fall back to FLAT opaque fill (see resolveTier).
    val feedBackdrop = rememberLayerBackdrop()
    val sceneBackdrop =
        rememberLayerBackdrop {
            drawRect(LiveDesign.background)
            drawContent()
        }
    val activityManager =
        remember(appContext) {
            appContext.getSystemService(android.content.Context.ACTIVITY_SERVICE)
                as android.app.ActivityManager
        }
    val totalRamBytes =
        remember(activityManager) {
            android.app.ActivityManager.MemoryInfo()
                .also(activityManager::getMemoryInfo)
                .totalMem
        }
    val glass =
        remember(
            glassTierOverride,
            feedBackdrop,
            sceneBackdrop,
            totalRamBytes,
            activityManager.isLowRamDevice,
        ) {
            val tier =
                resolveTier(
                    sdkInt = android.os.Build.VERSION.SDK_INT,
                    override = glassTierOverride,
                    isLowRamDevice = activityManager.isLowRamDevice,
                    totalRamBytes = totalRamBytes,
                )
            MonitorGlass(
                tier,
                layerBackdrop = feedBackdrop,
                overlayBackdrop = sceneBackdrop,
                // Pin FULL only when the operator explicitly forces it; otherwise
                // allow frame-budget demote so borderline devices still fall back.
                allowDemote = glassTierOverride?.lowercase() != "full",
            )
        }
    MonitorGlassBudgetLoop(glass)

    // Shell state, iOS-model-equivalent: a typed DISP mode and the interface
    // lock. Order/enablement live in OperatorSettings and remain observable
    // while the full-screen settings overlay keeps this monitor mounted.
    // Recording is owned by the CameraSession; the shell only renders its
    // state and asks it to send a Nikon command.
    val displaySession = operatorSettings.displaySession
    val displayMode = displaySession.mode
    // Photography hides the command monitor (its dashboard is still
    // movie-shaped); the DISP indicator and cycle follow this filtered order
    // (iOS `displayOrder`).
    val displayModeOrder =
        photographyDisplayModeOrder(
            operatorSettings.enabledDisplayModeOrder,
            // Command is entirely a camera-control surface — a session with no camera behind it
            // (a watcher without the control token) drops it from the cycle rather than offering
            // an empty dashboard (iOS `displayOrder`).
            hidesCommand =
                prefersPhotographyChrome(cameraProperties) || !availability.cameraControls,
        )
    val effectiveDisplayMode =
        displayMode.takeIf(displayModeOrder::contains) ?: displayModeOrder.first()
    val locked = displaySession.locked
    DisposableEffect(displaySession, session) {
        onDispose {
            displaySession.locked = false
            displaySession.retireEditor()
            displaySession.mode = MonitorDisplayMode.LIVE
        }
    }
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
    val commandTileOrderStore = remember(appContext) { CommandTileOrderStore(appContext) }
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
            // Photography has no command dashboard — flipping to photo while
            // it is up snaps back to live (iOS flip handler).
            if (
                prefersPhotographyChrome(cameraProperties) &&
                displayMode == MonitorDisplayMode.COMMAND
            ) {
                displaySession.mode = MonitorDisplayMode.LIVE
            }
        }
    }
    val analysisPanelFrames =
        remember { mutableStateMapOf<MonitorAnalysisPanelID, MonitorRect>() }
    val onAnalysisPanelFrameChanged =
        remember(analysisPanelFrames) {
            { id: MonitorAnalysisPanelID, frame: MonitorRect? ->
                if (frame == null) {
                    analysisPanelFrames.remove(id)
                } else {
                    analysisPanelFrames[id] = frame
                }
                Unit
            }
        }
    /**
     * Latest desired label per control while an apply is in flight (iOS write-queue
     * coalesce). Scrolling the drum must never drop intermediate settles — only the
     * last value for each property is sent once the prior write finishes.
     */
    val desiredControlWrites =
        remember { mutableStateMapOf<CameraControl, Pair<CommandControlRequest, String>>() }
    var pendingCommandControl by remember { mutableStateOf<CameraControl?>(null) }
    var commandControlFeedback by remember { mutableStateOf<CommandControlFeedback?>(null) }
    var controlApplyLoopRunning by remember { mutableStateOf(false) }
    LaunchedEffect(effectiveDisplayMode) {
        displaySession.reconcile(displayModeOrder)
    }
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
    /**
     * The one way the DISP key changes mode, for both orientations. Gated on the interface lock
     * like every other control (iOS `cycleDisplayMode` guards `!interfaceLocked`): the feed swipe
     * to the same modes already refuses while locked, so a live button beside it read as the lock
     * being broken.
     */
    val cycleDisplayMode: () -> Unit = {
        if (!locked) {
            assists.shared.configureTool = null
            displaySession.cycle(displayModeOrder)
        }
    }
    /**
     * iOS-style apply: optimistic UI (caller already landed the drum), never block the
     * wheel on an in-flight write, coalesce rapid settles to the latest label per control.
     */
    fun drainCameraControlWrites() {
        if (controlApplyLoopRunning) return
        controlApplyLoopRunning = true
        recordScope.launch {
            try {
                while (desiredControlWrites.isNotEmpty()) {
                    val control = desiredControlWrites.keys.first()
                    val (req, desiredLabel) = desiredControlWrites.remove(control) ?: continue
                    // Already matches live readback (operator scrolled back, or a prior
                    // coalesced write landed) — skip the wire trip. Always send REC/codec
                    // like iOS (exact advertised pack write); never skip those on a soft
                    // label match that can lag behind the body.
                    val alwaysWrite =
                        control == CameraControl.RESOLUTION_FRAMERATE
                            || control == CameraControl.CODEC
                    if (!alwaysWrite
                        && cameraPropertyConfirmsSelection(
                            session.cameraProperties.value,
                            control,
                            desiredLabel,
                        )
                    ) {
                        continue
                    }
                    pendingCommandControl = control
                    try {
                        // Facade applyControl already confirms the write on the wire. Do not
                        // soft-fail from a lagging property poll (see docs/android-control-writes.md).
                        if (control in NikonOpenCineSession.CONTROLS &&
                            (!isPhotographyMode || control !in setOf(CameraControl.SHUTTER, CameraControl.IRIS))) {
                            NikonOpenCineSession.settingValue(control, desiredLabel)?.let { commonControl.set(it, desiredLabel) }
                        } else {
                            session.applyControl(control, desiredLabel)
                        }
                        // One refresh keeps tiles/bar honest; settles still enqueue while this runs.
                        session.refreshProperties()
                    } catch (error: CameraControlException) {
                        if (desiredControlWrites[control] == null) {
                            commandControlFeedback =
                                CommandControlFeedback(
                                    appContext.getString(
                                        R.string.control_error,
                                        req.title,
                                        error.message
                                            ?: appContext.getString(
                                                R.string.control_change_rejected,
                                            ),
                                    ),
                                    isError = true,
                                )
                        }
                    }
                }
            } finally {
                pendingCommandControl = null
                controlApplyLoopRunning = false
                // Settle may land in the map after the while-check empties it.
                if (desiredControlWrites.isNotEmpty()) {
                    drainCameraControlWrites()
                }
            }
        }
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
                        Toast.makeText(appContext, "The camera changed. Reopen this control.", Toast.LENGTH_SHORT).show()
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
                desiredControlWrites[CameraControl.ISO_AUTO] =
                    CommandControlRequest(
                        title = "ISO",
                        control = CameraControl.ISO_AUTO,
                        currentValue = IsoPickerPolicy.AUTO_ISO_OFF_LABEL,
                        options =
                            listOf(
                                IsoPickerPolicy.AUTO_ISO_ON_LABEL,
                                IsoPickerPolicy.AUTO_ISO_OFF_LABEL,
                            ),
                    ) to IsoPickerPolicy.AUTO_ISO_OFF_LABEL
            }
            desiredControlWrites[request.control] = request to label
            commandControlFeedback = null
            if (activeCommandControl?.control == request.control) {
                activeCommandControl = request.copy(currentValue = label)
            }
            drainCameraControlWrites()
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
    var photoTimerRemaining by remember { mutableStateOf<Int?>(null) }
    var photoTimerJob by remember { mutableStateOf<Job?>(null) }
    val photoTimerTone =
        remember { android.media.ToneGenerator(android.media.AudioManager.STREAM_MUSIC, 80) }
    DisposableEffect(Unit) { onDispose { photoTimerTone.release() } }
    fun firePhotoTimerShots(): Job =
        recordScope.launch {
            repeat(maxOf(1, photoTimerShotCount)) { index ->
                if (index > 0) {
                    // Each shot waits out the previous one's completion.
                    var waitedMillis = 0
                    while (stillCapture.isCapturing.value && waitedMillis < 20_000) {
                        delay(150)
                        waitedMillis += 150
                    }
                    if (stillCapture.isCapturing.value) return@launch
                }
                stillCapture.pressed(
                    recordScope,
                    continuousDrive = false,
                    preserveFocus = mfDrive.focusManuallyDialed,
                )
                delay(150)
            }
        }
    // Photography shutter press/release (iOS shutterButtonPressed/Released):
    // countdown/timer runs first; continuous drives latch the burst for the
    // duration of the hold.
    val photoShutterPressed: () -> Unit = pressed@{
        if (photoTimerJob?.isActive == true) {
            // Second press cancels a running countdown (or the remaining shot
            // run), matching body behaviour.
            photoTimerJob?.cancel()
            photoTimerJob = null
            photoTimerRemaining = null
            return@pressed
        }
        if (photoTimerDelaySeconds > 0 && !stillCapturing) {
            photoTimerJob =
                recordScope.launch {
                    try {
                        var remaining = photoTimerDelaySeconds
                        photoTimerRemaining = remaining
                        photoTimerTone.startTone(
                            android.media.ToneGenerator.TONE_PROP_BEEP, 70,
                        )
                        while (remaining > 0) {
                            delay(1000)
                            remaining -= 1
                            photoTimerRemaining = remaining
                            if (remaining > 0) {
                                photoTimerTone.startTone(
                                    android.media.ToneGenerator.TONE_PROP_BEEP, 70,
                                )
                            }
                        }
                        photoTimerTone.startTone(
                            android.media.ToneGenerator.TONE_PROP_BEEP2, 200,
                        )
                        photoTimerRemaining = null
                        firePhotoTimerShots().join()
                    } finally {
                        photoTimerRemaining = null
                    }
                }
            return@pressed
        }
        if (
            photoTimerShotCount > 1 && !stillCapturing &&
            cameraProperties.stillCaptureMode == StillPickerPolicy.SELF_TIMER_LABEL
        ) {
            // Built-in timer engaged: its countdown never runs for command
            // releases, so the shots field drives a straight run from the press.
            photoTimerJob = firePhotoTimerShots()
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
    stillCapture.onFailure = { message ->
        Toast.makeText(appContext, message, Toast.LENGTH_SHORT).show()
    }
    // A sustained refusal (retries exhausted) explains itself once per run — the
    // strip stays up so the next gesture tries again.
    mfDrive.onRefusalExhausted = { message ->
        onDriveDiagnostic(AndroidDiagnosticEvent.MF_DRIVE_REFUSED)
        Toast.makeText(appContext, message, Toast.LENGTH_SHORT).show()
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
        shouldArmMediaRemoteShutter(
            enabled = operatorSettings.mediaRemoteShutterEnabled.value,
            monitorIsFront = isMonitorFront,
            cameraConnected = sessionState is CameraSessionState.Connected,
            recordCommandPending = recordCommandPending,
            applicationResumed = lifecycleState.isAtLeast(Lifecycle.State.RESUMED),
            recordConfirmationPending = recordConfirmationOpen,
            cameraControlPending = pendingCommandControl != null,
        )
    val latestRemoteShutterAction =
        rememberUpdatedState<(MediaRemoteShutterCommand) -> Unit>(
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
                        Toast.makeText(appContext, error.message, Toast.LENGTH_SHORT).show()
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
        // Command always uses the fit zone, matching iOS. The persisted fill
        // choice returns unchanged when the operator cycles back to Live.
        // Photography always lays out as fit too — its feed is the still image
        // area (3:2/1:1/16:9), and a 16:9 centre-crop "fill" of a still makes no
        // sense (iOS `isFill = persistedAspect == .fill && !isPhotography`).
        // Body rotation from the live-view header (vertical mode). Screen-scoped state because
        // zone layout reads it well before the frame collectors are declared; the timecode
        // collector (open in every DISP mode) writes it, and a source change resets it.
        var liveFeedRotation by remember { mutableStateOf(LiveFeedRotation.LANDSCAPE) }
        // Whether the body runs timecode at all — the live-view header's own status byte, held
        // apart from the retained counter on purpose. Chrome that only asks "is there a timecode"
        // must not observe the counter: that ticks every frame and would re-render the whole top
        // bar at feed rate (the reason `MonitorTimecodeRetention` is leaf-observed). Bodies with
        // no timecode hardware pin the status byte to zero forever, and that is exactly the signal
        // that hides the readout instead of parking a frozen 00:00:00:00 on set. The same collector
        // that owns `liveFeedRotation` latches it, and a source change resets it.
        var cameraReportsTimecode by remember { mutableStateOf(false) }
        val displayedFeedRotation =
            liveFeedRotation.displayed(autoRotateEnabled = operatorSettings.autoRotateFeedEnabled.value)
        val isVerticalFeed = displayedFeedRotation.isVertical
        val portraitAspect = operatorSettings.portraitFeedAspect
        // Zone/chrome layout: vertical mode always lays out as FILL, matching iOS — the fill
        // zones are exactly the vertical viewer (feed spanning the bands, floating assist rail,
        // capture bar over the feed bottom); fit's stacked bands would strand the controls.
        //
        // That holds for a stills body too, and only the PERSISTED cinema choice is photography's
        // to be excluded from. Vertical fill does not crop — the picture pillarboxes inside the
        // frame (see `portraitRasterFill` below) — so the reason photography avoids fill does not
        // apply here, while fit hands a 2:3 still a feed tall enough to push its own stacked bands
        // off the screen: clipped toolbar, shutter over the DRIVE tile, white balance gone.
        val isPortraitFill =
            isPortrait && !isCommand &&
                (isVerticalFeed || (portraitAspect.fillsViewport && !isPhotographyMode))
        // Raster/overlay fit: the rotated 9:16 picture pillarboxes inside the fill frame —
        // aspect-filling it would centre-crop the top and bottom of the vertical shot.
        val portraitRasterFill = isPortraitFill && !isVerticalFeed

        // One authoritative mode filter, mirroring core `MonitorChromePolicy`: clean (DISP 2) is a
        // bare image unless the operator pinned a tool to it, and it strips the deck/rails/bands
        // as well (#256).
        // Chrome is per DISP mode (iOS `OperatorPreferences.chrome(for:)`) — read this mode's set,
        // never the global one, or DISP 2's bare image leaks back into DISP 1.
        // …and per capture side: a cinema rig and a stills body keep separate layouts (iOS
        // `NativeAppModel.captureLayoutMode`).
        val captureLayoutMode =
            if (isPhotographyMode) CaptureLayoutMode.PHOTO else CaptureLayoutMode.VIDEO
        val chrome = operatorSettings.chrome(effectiveDisplayMode, captureLayoutMode)
        // The Edit view force-mounts every element the mode owns — hidden ones at 30% with a
        // badge — so nothing can be switched off beyond reach (iOS `chromeSectionMounts`).
        val chromeEditorMode = operatorSettings.chromeEditorMode
        val editingThisMode =
            chromeEditorMode != null && chromeEditorMode == effectiveDisplayMode
        val mounts: (ChromeSection) -> Boolean = { section ->
            // A section with nothing feeding it hides whatever the operator set — a readout with
            // no source still looks like an instrument (iOS `sectionHasASource`). The edit view's
            // force-mount cannot override a missing source either.
            availability.hasSource(section, cameraReportsTimecode, isPhotographyMode) &&
                ((editingThisMode && section.isConfigurableIn(effectiveDisplayMode)) ||
                    chrome[section].value)
        }
        val statusBarVisible = mounts(ChromeSection.STATUS_BAR)
        val assistToolbarVisible = mounts(ChromeSection.ASSIST_TOOLBAR)
        val cameraValuesVisible = mounts(ChromeSection.CAMERA_VALUES)
        val chromeEditBoxes = remember { mutableStateMapOf<ChromeSection, MonitorRect>() }
        // Done returns to where the operator came from, Display settings, not to the live monitor
        // with no way back but the rail they may have just hidden.
        val chromeEditHost =
            remember(operatorSettings, captureLayoutMode, onOpenSettings) {
                NikonChromeEditHost(operatorSettings, captureLayoutMode, onOpenSettings)
            }
        LaunchedEffect(chromeEditorMode) {
            // Editing a mode means looking at it.
            chromeEditorMode?.let { displaySession.mode = it }
        }
        val liveAssistChips =
            nikonLiveAssistChips(
                photography = isPhotographyMode,
                imageEffects = liveFeedEffectsPlatformAvailable(Build.VERSION.SDK_INT, SwiftCore.isAvailable),
            )
        val liveAssistTools = liveAssistChips.mapNotNull { (it as? NikonAssistChip.Tool)?.tool }
        val bottomBarHeight =
            when {
                isPortrait && assistToolbarVisible -> LiveDesign.CONTROL_HEIGHT_DP
                !isPortrait && (assistToolbarVisible || cameraValuesVisible) ->
                    LiveDesign.CONTROL_HEIGHT_DP
                else -> 0f
            }

        // Same core call the iOS shell makes once per layout pass. The
        // landscape map is mode-invariant (iOS gates chrome shell-side), but
        // the portrait map encodes per-mode zones, so mode/scope key the map
        // alongside geometry.
        // Portrait's shared scopes zone must reflect panels actually mounted,
        // not every remembered landscape scope. The selection mirrors iOS:
        // two newest activations, then canonical presentation order.
        val portraitScopes =
            if (isPortrait && !isPortraitFill && effectiveDisplayMode == MonitorDisplayMode.LIVE) {
                // Photography suppresses the cinema-only scopes at render, so the
                // zone must bill only the photography-visible ones (just the
                // histogram) — a band sized to the full set opens a dead gap
                // between feed and toolbar (iOS
                // `displayedFitScopes.filter(appliesToPhotography)`).
                assists.shared.portraitScopes(scopesShown(assists.shared::isOn)).let { scopes ->
                    if (isPhotographyMode) scopes.filter { it.appliesToPhotography } else scopes
                }
            } else {
                emptyList()
            }
        val scopeCount = portraitScopes.size
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
        // Shared presentation owns every common rectangle; native assist and popup adapters read
        // it directly.
        val fieldLayout = MonitorLayoutPolicy.fieldMonitor(
            width = viewportWidth, height = viewportHeight,
            safeTop = portraitPhoneSafeTop(safeTop, viewportWidth, viewportHeight),
            safeLeading = safeLeading, safeBottom = safeBottom, safeTrailing = safeTrailing,
            sourceAspect = portraitFeedAspectRatio, fill = isPortraitFill,
            showsValues = cameraValuesVisible, hasDisplayCutout = safeLeading > 0 || safeTrailing > 0,
        )
        // Portrait fit stacks the scopes between the picture and the camera values.
        val scopeRoom = (fieldLayout.values.y - fieldLayout.picture.maxY - 32f).coerceAtLeast(0f).coerceAtMost(184f)
        val scopeZone = if (isPortrait && !isPortraitFill) MonitorRect(fieldLayout.picture.x + 14f,
            fieldLayout.picture.maxY + 16f, fieldLayout.picture.width - 28f, scopeRoom) else null
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
        val timecodeRetention =
            remember(session, timecodeOwner) { MonitorTimecodeRetention(timecodeOwner) }
        // Do not read timecodeRetention here — that recomposes the whole monitor
        // chrome at feed rate. Leaf RetainedCameraTimecodeReadout observes it.
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
        val fpsSampler = remember(session, timecodeOwner) { MonitorFrameRateSampler() }
        // The rate cell doubles as the link readout: with `connectionMessage` invisible behind the
        // monitor, a route that never comes up is otherwise indistinguishable from a connected feed
        // with no frames — which is exactly how it was reported from set (iOS `liveFPS`).
        val feedState =
            monitorFeedState(
                recovery = recoveryStateOverride ?: sessionRecoveryState,
                previewRejected = previewApplication is SwiftLiveViewPreviewState.Rejected,
            )
        var prefersMediaDuration by rememberSaveable { mutableStateOf(false) }
        val topBarMedia =
            if (prefersMediaDuration) {
                readoutRetention.media.durationLabel
            } else {
                readoutRetention.media.capacityLabel
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
        LaunchedEffect(actualLinkHealth, healthFrameSource) {
            val swiftSource =
                healthFrameSource as? SwiftCoreLiveFrameSource
                    ?: return@LaunchedEffect
            swiftSource.currentStreamFrames
                .metadataOnly()
                .conflate()
                .collect(actualLinkHealth::recordFrame)
        }
        // Constant camera-header TC sync — every live-view frame updates the
        // hero readout (standby and rolling). No free-run or lag probing.
        //
        // Deliberately NOT `monitorFrameSource`: that goes null in Command, which dropped the last
        // subscriber, ended live view, and froze the dashboard's hero clock at the last pre-Command
        // frame (#271). Timecode only exists in the live-view frame header, so this collector holds
        // the stream open in every DISP mode while decode/scopes/audio still stand down.
        val timecodeFrameSource = monitorTimecodeFrameSource(activeFrameSource)
        LaunchedEffect(timecodeFrameSource, timecodeRetention) {
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
                        timecodeRetention.accept(frame.timecode)
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
        LaunchedEffect(actualLinkHealth, propertyRefreshStatus) {
            actualLinkHealth.reportPropertyRefresh(propertyRefreshStatus)
        }
        LaunchedEffect(actualLinkHealth, commandRoundTripMilliseconds) {
            actualLinkHealth.reportRoundTripMilliseconds(commandRoundTripMilliseconds)
        }
        LaunchedEffect(actualLinkHealth, healthFrameSource) {
            while (true) {
                delay(1_000)
                actualLinkHealth.refresh()
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
        // Every rail control is the operator's to hide, per DISP mode and capture side. The core
        // rule (mirrored in `OperatorSettings.sideRailPlan`) applies the two guarantees that keep a
        // configuration from locking the operator inside it: record while a take is rolling, and
        // Settings when no enabled DISP mode carries one.
        val railPlan =
            operatorSettings.sideRailPlan(
                mode = effectiveDisplayMode,
                capture = captureLayoutMode,
                interfaceLocked = locked,
                recordingOrPending =
                    recording || recordCommandPending || recordConfirmationOpen,
            )
        val railMounts: (ChromeSection) -> Boolean = { section ->
            // Availability outranks the rail plan's self-restore guarantees: a watcher without
            // control must not get the record button forced back on by the broadcaster's own
            // recording state riding in over the relay.
            availability.hasSource(section, cameraReportsTimecode, isPhotographyMode) &&
                if (editingThisMode && section.isConfigurableIn(effectiveDisplayMode)) {
                    true
                } else {
                    when (section) {
                        ChromeSection.LOCK_BUTTON -> railPlan.lock
                        ChromeSection.BATTERY_INDICATORS -> railPlan.batteries
                        ChromeSection.RAIL_DISP -> railPlan.disp
                        ChromeSection.RAIL_RECORD -> railPlan.record
                        ChromeSection.RAIL_MEDIA -> railPlan.media
                        ChromeSection.RAIL_SETTINGS -> railPlan.settings
                        else -> mounts(section)
                    }
                }
        }
        val physicalViewport = MonitorRect(0f, 0f, viewportWidth, viewportHeight)
        // Photography's landscape feed: the still image-area's shape centred in
        // the clear box between the chrome lanes — the rail and capture band
        // never overlap the image (iOS centered letterbox + reserved lanes).
        val effectiveFeed = fieldLayout.picture
        val analysisChromeMounts =
            remember(
                isPortrait,
                isPortraitFill,
                isClean,
                isCommand,
                assistToolbarVisible,
                cameraValuesVisible,
                railPlan,
            ) {
                monitorAnalysisChromeMounts(
                    isPortrait = isPortrait,
                    isPortraitFill = isPortraitFill,
                    isClean = isClean,
                    isCommand = isCommand,
                    assistToolbarVisible = assistToolbarVisible,
                    cameraValuesVisible = cameraValuesVisible,
                    landscapeRail = railPlan,
                )
            }
        val analysisPanelLayout =
            remember(
                fieldLayout,
                physicalViewport,
                isPortrait,
                isPortraitFill,
                statusBarVisible,
                analysisChromeMounts,
            ) {
                monitorAnalysisPanelLayout(
                    layout = fieldLayout,
                    physicalViewport = physicalViewport,
                    isPortrait = isPortrait,
                    isPortraitFill = isPortraitFill,
                    statusBarVisible = statusBarVisible,
                    chromeMounts = analysisChromeMounts,
                )
            }

        // Feed at the shared zone-map frame. Fit keeps the whole frame;
        // portrait fill centre-crops the image and every feed-aligned overlay
        // through the same content-rect resolver. Command unmounts the feed.
        val feedFocus = liveFeedPresentation.focus

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
                            Toast.makeText(
                                    appContext,
                                    error.message
                                        ?: appContext.getString(R.string.focus_change_rejected),
                                    Toast.LENGTH_SHORT,
                                )
                                .show()
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
                    operatorSettings.displayModeForExplicitRequest(action.mode)
                        ?.takeIf(displayModeOrder::contains)
                        ?.let { next ->
                        if (next != effectiveDisplayMode) {
                            displaySession.select(next, displayModeOrder)
                            if (operatorSettings.hapticsEnabled.value) {
                                view.performOperatorHaptic(HapticFeedbackConstants.CLOCK_TICK)
                            }
                        }
                    }
                }
                FocusFeedGestureAction.ToggleFocusPointLock -> toggleFocusPointLock()
            }
        }
        val focusResetVisible =
            focusResetAvailable(feedFocus, focusPointLocked) &&
                // A watcher has no focus-box source to recenter (iOS `.focusBox` mount rule):
                // the relayed session reads Connected, so the availability gate must lead.
                availability.hasSource(ChromeSection.FOCUS_BOX) &&
                sessionState is CameraSessionState.Connected &&
                !locked &&
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
                    Toast.makeText(
                            appContext,
                            error.message ?: appContext.getString(R.string.focus_reset_failed),
                            Toast.LENGTH_SHORT,
                        )
                        .show()
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
        // Full-scene recording so overlay glass (pickers) blurs chrome + feed.
        // Kyant sibling pattern: this box records; popups are drawn *outside* it.
        val sceneLayer =
            if (glass.tier == GlassTier.FULL && glass.overlayBackdrop != null) {
                Modifier.layerBackdrop(glass.overlayBackdrop)
            } else {
                Modifier
            }
        val openSharedPicker: (MonitorPickerKind) -> Unit = { kind ->
            assists.shared.configureTool = null
            activeCommandControl = null
            activeMonitorPickerKind = nextMonitorPicker(activeMonitorPickerKind, kind,
                sessionState is CameraSessionState.Connected && !locked && !editingThisMode &&
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
        val readouts: List<MonitorOperatorLiveReadout<String, ChromeSection>> = nativeSettings.map { setting ->
            val field = fieldFor(setting.kind)
            MonitorOperatorLiveReadout(setting.kind.name, field?.title ?: setting.label,
                if (field != null) field.label else setting.value, field = field,
                quickEnabled = setting.kind != MonitorPickerKind.SHUTTER,
                itemModifier = if (setting.kind == MonitorPickerKind.SHUTTER && !isPhotographyMode) {
                    Modifier.pointerInput(session, sessionState is CameraSessionState.Connected,
                        commandControlsEnabled, locked, editingThisMode, isMonitorFront) {
                        awaitEachGesture {
                            awaitFirstDown()
                            val captured = commonControl.state.value.snapshot?.let { it.session to it.epoch }
                            val released = withTimeoutOrNull(450L) { waitForUpOrCancellation() }
                            if (commonControl.state.value.snapshot?.let { it.session to it.epoch } == captured &&
                                sessionState is CameraSessionState.Connected && !locked && !editingThisMode && isMonitorFront) {
                                if (released == null) {
                                    if (commandControlsEnabled) shutterLongPressToggle()
                                    waitForUpOrCancellation()
                                }
                                else openSharedPicker(MonitorPickerKind.SHUTTER)
                            }
                        }
                    }
                } else Modifier,
            )
        }
        val timecode = timecodeRetention.timecodeFor(sessionState)
        val commonStatus = MonitorStatusPresentation(commonControl.isRecording,
            timecode = if (cameraReportsTimecode) timecode?.let {
                "%02d:%02d:%02d".format(java.util.Locale.ROOT, it.hour, it.minute, it.second)
            } else null)
        val scopes = scopesShown { assists.shared.rendersLive(it, effectiveDisplayMode, isPhotographyMode) }
        val emptyScopes = remember { MutableStateFlow(com.opencapture.opencine.media.ScopeAssistBundle.EMPTY) }
        val scopeSource = monitorFrameSource?.let { source -> rememberNikonLiveScopeBundles(scopes,
            portraitScopes, assists.shared, exposureAssistCameraInput, renderedEffects.lut, lutLibrary,
            thermalTier, source, isPortrait, isPortraitFill, scopeZone) } ?: emptyScopes
        val floating = analysisPanelLayout ?: MonitorAnalysisPanelLayout(physicalViewport, physicalViewport)
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
                        when (val result = library.importFromDocument(uri)) {
                            is com.opencapture.openzcine.lut.CustomLutImportResult.Imported -> {
                                // iOS importCustomLUT: select + enable the LUT immediately —
                                // the graded feed is the confirmation the operator sees.
                                if (library.prepare(result.entry.selection)) {
                                    assists.selectLut(FeedLutSelection.Stored(result.entry.selection))
                                }
                                Toast.makeText(
                                    appContext,
                                    "${result.entry.displayName} imported.",
                                    Toast.LENGTH_SHORT,
                                ).show()
                            }
                            is com.opencapture.openzcine.lut.CustomLutImportResult.Rejected ->
                                Toast.makeText(appContext, result.message, Toast.LENGTH_SHORT)
                                    .show()
                        }
                    }
                }
            }
        val assistSource = MonitorOperatorAssistSource(
            AssistHost(com.opencapture.openzcine.settings.SettingsPalette.peaking,
                com.opencapture.openzcine.settings.SettingsPalette.highlight, com.opencapture.openzcine.settings.SettingsPalette.midtone),
            scopeSource, scopeStackMoved = {}, lookPicker = null, panelPlacement = placement,
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
                haptics.selection(); operatorSettings.levelStyle = it } })
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
        val aspectToggleVisible = isPortrait && !isCommand && !isPhotographyMode && !isVerticalFeed &&
            !locked && chromeEditorMode == null
        val bottomChromeInsetDp = with(density) { levelGaugeBottomChromeInset.toDp().value }
        val onFeedLaneInset = bottomChromeInsetDp + if (aspectToggleVisible)
            FOCUS_RESET_BUTTON_SIZE_DP + FOCUS_RESET_PANEL_GAP_DP else 0f
        val aspect = if (aspectToggleVisible) {
            val fills = operatorSettings.portraitFeedAspect.fillsViewport
            MonitorOperatorAspectControl(focusResetButtonBaseFrame(fieldLayout.picture, true, bottomChromeInsetDp),
                fills, stringResource(if (fills) R.string.portrait_aspect_fit else R.string.portrait_aspect_fill)) {
                operatorSettings.portraitFeedAspect = if (fills) PortraitFeedAspect.FIT_16_9 else PortraitFeedAspect.FILL }
        } else null
        val reset = if (focusResetVisible) MonitorOperatorFocusReset(
            focusResetButtonClearFrame(focusResetButtonBaseFrame(effectiveFeed, isPortrait, onFeedLaneInset),
                analysisPanelFrames.values, effectiveFeed),
            stringResource(when { focusResetPending -> R.string.focus_resetting
                focusMoveRequestsInFlight > 0 -> R.string.focus_reset_moving; else -> R.string.focus_reset }),
            !focusCommandPending, focusResetPending, requestFocusReset) else null
        val comparison = if (renderedEffects.lut != null && assists.shared.splitComparison &&
            !locked && chromeEditorMode == null) MonitorOperatorLookComparison(
            splitComparisonKeyFrame(effectiveFeed, isPortrait, onFeedLaneInset, focusResetVisible,
                SPLIT_KEY_WIDTH_DP, SPLIT_KEY_HEIGHT_DP), stringResource(R.string.split_comparison_key),
            splitComparisonMuted) { splitComparisonMuted = !splitComparisonMuted } else null
        val identity = MonitorOperatorLiveIdentity(sharedControlState.snapshot?.session,
            sharedControlState.snapshot?.epoch, pictureFrameSource)
        val currentPicture = rememberUpdatedState(pictureFrameSource)
        val statusStorage = if (isPhotographyMode && mounts(ChromeSection.TIMECODE_READOUT)) {
            val storage = cameraProperties.storage
            val capacity = storage?.takeIf { photoPillShowsStorage && it.totalCapacityBytes > 0 }
            MonitorOperatorLiveReadout<String, ChromeSection>("shots", "Shots remaining",
                if (capacity != null) "${capacity.freeSpaceBytes / 1_000_000_000} GB ${capacity.freeSpaceBytes * 100 / capacity.totalCapacityBytes}%"
                else cameraProperties.shotsRemaining?.let { "${shotsRemainingCompactLabel(it)} SHOTS" },
                ChromeSection.TIMECODE_READOUT, action = { photoPillShowsStorage = !photoPillShowsStorage })
        } else if (mounts(ChromeSection.MEDIA_READOUT)) MonitorOperatorLiveReadout("storage", "Media remaining",
            topBarMedia, ChromeSection.MEDIA_READOUT, action = { prefersMediaDuration = !prefersMediaDuration }) else null
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
        MonitorOperatorDescriptorLiveSurface(
            control = commonControl, identity = identity,
            current = { captured -> val snapshot = commonControl.state.value.snapshot
                snapshot?.session == captured.camera && snapshot?.epoch == captured.epoch &&
                    currentPicture.value === captured.pictureOwner },
            layout = fieldLayout, viewport = physicalViewport,
            sections = MonitorOperatorLiveSections(ChromeSection.STATUS_BAR, ChromeSection.BATTERY_INDICATORS,
                ChromeSection.CAMERA_VALUES, ChromeSection.ASSIST_TOOLBAR, ChromeSection.LOCK_BUTTON,
                ChromeSection.RAIL_SETTINGS, ChromeSection.RAIL_MEDIA, ChromeSection.RAIL_RECORD, ChromeSection.RAIL_DISP),
            mounted = ChromeSection.entries.filter(railMounts).toSet(), host = chromeEditHost, editing = chromeEditorMode,
            locked = locked, setLocked = { displaySession.locked = it }, covered = !isMonitorFront,
            clean = isClean, command = isCommand, readOnly = !commandControlsEnabled || controlsSurrendered,
            recovering = (recoveryStateOverride ?: sessionRecoveryState) != SessionRecoveryUi.Idle,
            status = MonitorOperatorLiveStatus(commonStatus, !isPhotographyMode && mounts(ChromeSection.TIMECODE_READOUT),
                !isPhotographyMode && mounts(ChromeSection.REC_READOUT), statusStorage,
                listOf(MonitorOperatorLiveReadout(resolutionKind.name, "Image size",
                    if (isPhotographyMode) cameraProperties.stillSizeAreaLabel() else readoutRetention.resolution,
                    ChromeSection.RESOLUTION_READOUT, action = { openSharedPicker(resolutionKind) }),
                    MonitorOperatorLiveReadout(codecKind.name, "Codec",
                        if (isPhotographyMode) cameraProperties.stillQualityCompactLabel() else readoutRetention.codec,
                        ChromeSection.CODEC_READOUT, action = { openSharedPicker(codecKind) })),
                fpsChipLabel(fpsSampler.formatted.toDoubleOrNull(), feedState), actualLinkHealth.presentation.signalBars,
                ChromeSection.FPS_READOUT),
            power = listOf(MonitorOperatorPowerReading(false, phoneBatteryReadout.percent, phoneBatteryReadout.externalPower),
                MonitorOperatorPowerReading(true, cameraReadouts.batteryPercent, cameraReadouts.externalPower)),
            readouts = readouts, panel = panelValue,
            open = { id -> MonitorPickerKind.entries.firstOrNull { it.name == id }?.let(openSharedPicker) },
            dismiss = { activeMonitorPickerKind = null; activeCommandControl = null; commandControlFeedback = null },
            retireReadout = { commonEditor = null }, settings = onOpenSettings, media = onOpenMedia,
            cycleDisplay = cycleDisplayMode, displayIndex = displayModeOrder.indexOf(effectiveDisplayMode).takeIf { it >= 0 },
            displayCount = displayModeOrder.size, displayTitle = displayModeDescription, photo = isPhotographyMode,
            confirmRecord = operatorSettings.recordConfirmationEnabled.value, recordEnabled = recordControlEnabled,
            onRecordConfirming = { recordConfirmationOpen = it }, assist = assists.shared, assists = assistSource,
            palette = palette, usage = usage, setUsage = { usage = it; usageStore.value = it }, usageSeed = nikonUsageSeed,
            renderedTools = liveAssistTools.filter { tool ->
                assists.shared.rendersLive(tool, effectiveDisplayMode, isPhotographyMode) &&
                    (tool !in ScopeKind.canonical.map { it.assistTool } || scopeSource !== emptyScopes)
            }.toSet(),
            fittedScopes = if (scopeSource !== emptyScopes) portraitScopes.map { it.assistTool } else emptyList(),
            scopeZone = scopeZone, signalOptions = signal,
            audio = if (renderedAudioMeters) MonitorOperatorLiveAudio(liveAudioLevels?.let { levels ->
                com.opencapture.opencine.media.MonitorAudioMeterLevels(
                    com.opencapture.opencine.media.MonitorAudioMeterChannel(levels.left.levelDb, levels.left.peakDb),
                    com.opencapture.opencine.media.MonitorAudioMeterChannel(levels.right.levelDb, levels.right.peakDb)) },
                "${stringResource(R.string.audio_sensitivity_label)}\n${displayedAudioSensitivity(cameraProperties.microphoneSensitivity)}",
                stringResource(R.string.audio_no_data), if (liveAudioLevels?.isDebugFixture == true) "DEBUG FIXTURE\nNOT CAMERA AUDIO" else null,
                audioMeterStateDescription(resources.phoneStringResolver(), liveAudioLevels,
                    cameraProperties.microphoneSensitivity)) else null,
            reference = reference, aspect = aspect, resetFocus = reset, comparison = comparison,
            cameraViews = MonitorOperatorBodyViews(
                dashboard = { accepts ->
                    val nativeBounds = MonitorRect(fieldLayout.picture.x + 16f, fieldLayout.picture.y + 12f,
                        fieldLayout.picture.width - 32f, (fieldLayout.picture.height - 24f).coerceAtLeast(44f))
                    if (isPortrait) {
                        Column(Modifier.zone(nativeBounds).verticalScroll(rememberScrollState()),
                            verticalArrangement = Arrangement.spacedBy(12.dp)) {
                            CommandGrid(commandPresentation.tiles, commandControlsEnabled && accepts,
                                pendingCommandControl, openCommandControl, moveCommandTileTo,
                                modifier = Modifier.fillMaxWidth().height(portraitCommandGridHeightDp(commandPresentation.tiles.size).dp))
                            CommandSecondarySections(commandPresentation.sideSections, commandControlsEnabled && accepts,
                                pendingCommandControl, openCommandControl, compact = false)
                        }
                    } else {
                        Row(Modifier.zone(nativeBounds), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                            Column(Modifier.weight(2.35f).fillMaxHeight(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                                CommandHealthStrip(commandPresentation, fpsSampler.formatted, actualLinkHealth.presentation.signalBars)
                                CommandGrid(commandPresentation.tiles, commandControlsEnabled && accepts,
                                    pendingCommandControl, openCommandControl, moveCommandTileTo,
                                    modifier = Modifier.fillMaxWidth().weight(1f))
                            }
                            CommandSideColumn(commandPresentation.sideSections, commandControlsEnabled && accepts,
                                pendingCommandControl, openCommandControl, Modifier.weight(.85f).fillMaxHeight())
                        }
                    }
                },
                focusDrive = { accepts ->
                if (
                    // Operator preference (FOCUS popup toggle, iOS `mfDriveScrubEnabled`) —
                    // default OFF, and off hides the strip even in an AF focus mode. Video and
                    // photo alike: a focus pull is a video move too (iOS `showsMFDriveScrub`).
                    operatorSettings.mfDriveScrubEnabled.value &&
                    !isClean && !locked &&
                    sessionState is CameraSessionState.Connected &&
                    !isDemoSession &&
                    // Mirrors the shared core's `MFDriveEligibility.resolve`: no mode or MF means
                    // no dial at all (the lens ring owns focus in MF); AF-F mounts it INERT below,
                    // because a dial that vanishes on a mode change reads as a bug while a greyed
                    // one says "wrong mode for this".
                    mfDriveEligibility(
                        cameraProperties.activeFocusMode(photography = isPhotographyMode),
                    ) != MfDriveEligibility.UNAVAILABLE &&
                    // The strip absorbs taps (it drives on drag, swallows plain taps
                    // so they can't move the AF point under it). Mounting it over an
                    // open picker/popup would eat the popup's dismiss taps — picking
                    // MF in the FOCUS popup flips focusMode while that popup is still
                    // up, so it waits for every panel to close (iOS `showsMFDriveScrub
                    // … && activePanel == nil`).
                    activeCommandControl == null &&
                    activeMonitorPickerKind == null &&
                    assists.shared.configureTool == null
                ) {
                    val rightRailLeading =
                        minOf(fieldLayout.record.x, fieldLayout.display.x, fieldLayout.media.x, fieldLayout.settings.x)
                    // Re-arm the relative position when the dial (re)appears.
                    DisposableEffect(Unit) {
                        mfDrive.resetDial()
                        onDispose {}
                    }
                    MFDriveStrip(
                        atEnd = mfDriveAtEnd,
                        enabled =
                            mfDriveEligibility(
                                cameraProperties.activeFocusMode(photography = isPhotographyMode),
                            ) == MfDriveEligibility.DRIVABLE,
                        onDrive = { pulses -> mfDrive.drive(recordScope, pulses) },
                        modifier =
                            Modifier.zone(
                                mfDriveStripFrame(physicalViewport, rightRailLeading),
                            ),
                        netPulses = mfDriveNetPulses,
                        dialFraction = mfDriveDialFraction,
                    )
                }
                }),
            captureColumns = if (isPortrait && !fieldLayout.tablet) { if (isPhotographyMode) 5 else 3 } else readouts.size,
            modifier = Modifier.fillMaxSize().then(sceneLayer), chromeBoxes = chromeEditBoxes,
            resumed = lifecycleState.isAtLeast(Lifecycle.State.RESUMED),
            retainsPanel = activeMonitorPickerKind?.let { retainMonitorPickerForChrome(effectiveDisplayMode,
                cameraValuesVisible, pendingCommandControl != null, it.isTopBarPicker()) } ?: true,
            nativeFraming = true, floatingBounds = analysisPanelLayout?.viewport, floatingPlacement = analysisPanelLayout?.safeBounds,
            onPanelFrameChanged = { tool, frame -> val id = when (tool) {
                MonitorAssistTool.WAVE -> MonitorAnalysisPanelID.WAVEFORM; MonitorAssistTool.PARADE -> MonitorAnalysisPanelID.PARADE
                MonitorAssistTool.HISTO -> MonitorAnalysisPanelID.HISTOGRAM; MonitorAssistTool.VECTOR -> MonitorAnalysisPanelID.VECTORSCOPE
                MonitorAssistTool.LIGHTS -> MonitorAnalysisPanelID.TRAFFIC_LIGHTS; MonitorAssistTool.FALSE -> MonitorAnalysisPanelID.FALSE_COLOR_REFERENCE
                else -> null }; if (id != null) onAnalysisPanelFrameChanged(id, frame) },
            picture = {

            Box(
                Modifier.zone(effectiveFeed).alpha(if (isCommand) 0f else 1f)
                    // Feed-only recording for bar/chip glass (over the video).
                    .then(
                        if (glass.tier == GlassTier.FULL && glass.layerBackdrop != null) {
                            Modifier.layerBackdrop(glass.layerBackdrop)
                        } else {
                            Modifier
                        },
                    )
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
                if (
                    sessionState is CameraSessionState.Connected &&
                        !initialMonitorPropertiesReady &&
                        frameSource == null &&
                        !isCommand
                ) {
                    // Brief hold while the full property bootstrap fills AF /
                    // lens / subject / audio without fighting live-view pulls.
                    Column(
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(12.dp),
                    ) {
                        CircularProgressIndicator(
                            color = LiveDesign.accent,
                            strokeWidth = 2.dp,
                            modifier = Modifier.size(28.dp),
                        )
                        Text(
                            text = stringResource(R.string.camera_reading_properties),
                            style = chromeStyle(13f, FontWeight.Medium),
                            color = LiveDesign.muted,
                        )
                    }
                }
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
                        onPresentedFrame = { frame, bitmap, baker ->
                            // TC is owned by the stream collector above; present
                            // path only drives FPS + wear (decode can lag a take).
                            fpsSampler.accept(System.nanoTime())
                            hasPresentedFrame = true
                            wearRelay.ingestPresentedFrame(session, frame, bitmap, baker)
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
                        // SurfaceView graded feed is invisible to Kyant
                        // layerBackdrop — FULL glass must present via Compose. A rotated
                        // (vertical) feed must too: SurfaceView buffers composite outside
                        // the Compose layer and never rotate with it.
                        preferComposablePresentation =
                            glass.tier == GlassTier.FULL ||
                                displayedFeedRotation != LiveFeedRotation.LANDSCAPE,
                    )
                    // Presentation-only texture: after the camera frame/effect renderer, before
                    // every geometry-bearing assist. Scopes continue sampling monitorFrameSource.
                    FeedTextureOverlay(
                        presentationState = liveFeedPresentation,
                        aspectFill = portraitRasterFill,
                        horizontalPresentationScale = localFraming.horizontalPresentationScale,
                        verticalPresentationScale = localFraming.verticalPresentationScale,
                    )
                    // A camera that is connected but has not delivered a picture yet looks exactly
                    // like a wedged one — black, with the chrome cheerfully reporting a live
                    // session. iOS says so outright while `liveFrameImage` is nil
                    // (`LiveFeedWaitingOverlay`), and exempts the demo feed, whose first frame is
                    // synthetic and instant. The property-bootstrap hold above owns its own words.
                    if (!hasPresentedFrame && !isDemoSession) {
                        Column(
                            horizontalAlignment = Alignment.CenterHorizontally,
                            verticalArrangement = Arrangement.spacedBy(10.dp),
                        ) {
                            MonitorIcon(
                                MonitorIcon.FOCUS,
                                null,
                                Modifier.size(28.dp),
                                LiveDesign.text.copy(alpha = 0.28f),
                            )
                            Text(
                                text = stringResource(R.string.monitor_waiting_live_view),
                                style = chromeStyle(17f, FontWeight.SemiBold, mono = true),
                                color = LiveDesign.text.copy(alpha = 0.28f),
                            )
                        }
                    }
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
                    cleanMode = isClean,
                    isPortrait = isPortrait,
                    aspectFill = portraitRasterFill,
                    isPhotography = isPhotographyMode,
                    gaugeBottomChromeInset = levelGaugeBottomChromeInset,
                    focusPointLocked = focusPointLocked,
                    focusLockProgress = focusLockProgress,
                    focusBoxVisible = mounts(ChromeSection.FOCUS_BOX),
                    focusBoxAlpha =
                        if (editingThisMode && !chrome[ChromeSection.FOCUS_BOX].value) 0.3f else 1f,
                    focusBoxEditModifier =
                        if (chromeEditorMode == null) {
                            null
                        } else {
                            Modifier.nikonChromeEditable(
                                chromeEditHost,
                                ChromeSection.FOCUS_BOX,
                                chromeEditorMode,
                                chromeEditBoxes,
                            )
                        },
                    evIndicatorSixths = cameraProperties.evIndicatorSixths,
                    evIndicatorLit = cameraProperties.evIndicatorLit,
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
            cameraPanel = { key, pickerFrame, isTopDropDown ->
                activeMonitorPicker?.takeIf { it.kind.name == key }?.let { picker ->
                    CompositionLocalProvider(LocalMonitorGlass provides glass,
                        com.opencapture.opencine.cameracontrols.LocalViewportPortrait provides isPortrait) {
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
                    CompositionLocalProvider(LocalMonitorGlass provides glass,
                        com.opencapture.opencine.cameracontrols.LocalViewportPortrait provides isPortrait) {
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
            photoRelease = { enabled, decoration -> PhotographyShutterButton(stillCapturing, decoration,
                enabled = enabled && !controlsSurrendered, timerRemaining = photoTimerRemaining,
                bodyShutterPulse = bodyShutterPulse, onPressed = photoShutterPressed, onReleased = photoShutterReleased) },
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
            )
        }

        // Dropped-session recovery over the held frame (iOS `MonitorRecoveryOverlay`).
        MonitorRecoveryOverlay(
            state = recoveryStateOverride ?: sessionRecoveryState,
            cameraName = recoveryStateOverride?.let { "Nikon ZR" } ?: lastConnectedCameraName,
            onRetry = {
                // Operator intent clears the storm ledger: the retry is not a drop, and the
                // next pause should take a fresh cluster of drops to earn (iOS parity).
                ProductionSessionRetryScheduleBridge.resetDropStormGuard()
                sessionRecoveryRetryTicket += 1
            },
            onBackToOperatorMenu = onBackToOperatorMenu,
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
 * Photography hides the command display mode — its dashboard is still
 * movie-shaped (iOS `displayOrder` filter). Empty results (COMMAND-only
 * preference in photo mode) recover to the always-safe live mode.
 */
internal fun photographyDisplayModeOrder(
    order: List<MonitorDisplayMode>,
    hidesCommand: Boolean,
): List<MonitorDisplayMode> {
    if (!hidesCommand) return order
    return order.filterNot { it == MonitorDisplayMode.COMMAND }
        .ifEmpty { listOf(MonitorDisplayMode.LIVE) }
}

/**
 * Whether anything is actually feeding [section] right now — the Kotlin twin of iOS
 * `sectionHasASource`. Chrome the operator switched on still hides when nothing can fill it:
 * a readout with no source behind it still looks like an instrument, and the capture strip in
 * particular offers pickers that would write to a camera that cannot hear them. Only readouts
 * fed by the camera appear here; the assist toolbar, lock, FPS chip and rail utilities keep
 * working on any picture source.
 */
internal fun MonitorDataAvailability.hasSource(
    section: ChromeSection,
    /**
     * The live-view header's timecode status bit. Bodies with no timecode hardware pin it to zero
     * forever, and the readout hides rather than showing a frozen 00:00:00:00. Defaulted for
     * callers asking about a section that has nothing to do with the timecode slot.
     */
    cameraReportsTimecode: Boolean = true,
    isPhotographyMode: Boolean = false,
): Boolean =
    when (section) {
        ChromeSection.CAMERA_VALUES,
        ChromeSection.CODEC_READOUT,
        ChromeSection.MEDIA_READOUT,
        ChromeSection.RESOLUTION_READOUT,
        ChromeSection.BATTERY_INDICATORS,
        -> cameraControls
        ChromeSection.REC_READOUT, ChromeSection.RAIL_RECORD -> recordControl
        ChromeSection.RAIL_MEDIA -> mediaBrowser
        // Photography rents this slot for the SHOTS counter, which has nothing to do with
        // timecode — gate that on the camera link, not on the body's timecode status.
        ChromeSection.TIMECODE_READOUT ->
            if (isPhotographyMode) cameraControls else cameraTimecode && cameraReportsTimecode
        ChromeSection.FOCUS_BOX -> focusBoxes
        else -> true
    }

/**
 * The word the frame-rate chip carries instead of a rate, mirroring what iOS parks in `liveFPS`
 * (`NativeAppRoot`): `SessionRecoveryCopy.heldFrameBadge` for the whole bounded-recovery arc after
 * an established session drops, `"RECOV"` while the session is up but the stream is being restarted.
 * A dropped session outranks a rejected stream — the link is the bigger fact.
 *
 * `null` means "print the measured rate": nothing is wrong that the chip has to say.
 *
 * [MonitorFeedState.BUSY] and [MonitorFeedState.FAIL] are deliberately unreachable here. The
 * body-busy hold lives inside the facade's live-view pump (`PTPIPClientSession`, no Kotlin-visible
 * state) and the relay client's failure never reaches this screen — `RelayWatchController` is
 * MainActivity's. Both need a signal plumbed in before this can name them.
 */
internal fun monitorFeedState(
    recovery: SessionRecoveryUi,
    previewRejected: Boolean,
): MonitorFeedState? =
    when {
        recovery != SessionRecoveryUi.Idle -> MonitorFeedState.NO_LINK
        previewRejected -> MonitorFeedState.RECOV
        else -> null
    }

/** The next mode after [current] in the effective DISP order, wrapping. */
internal fun nextDisplayModeInOrder(
    order: List<MonitorDisplayMode>,
    current: MonitorDisplayMode,
): MonitorDisplayMode {
    return com.opencapture.opencine.appkit.MonitorDisplaySession.next(order, current) ?: current
}

/**
 * A portrait phone's top inset for the shared field layout, at least 44 dp. The shared layout hangs
 * the battery and FPS band 40 dp above the status row, in the cutout; a phone with no top cutout
 * (0 under immersive) would stack the band on the status row, the batteries over CODEC and FPS over
 * the clock. From 44 dp up the band keeps the gap it has on a punch-hole phone.
 */
internal fun portraitPhoneSafeTop(safeTop: Float, width: Float, height: Float): Float =
    if (height > width && width < 600f) maxOf(safeTop, 44f) else safeTop

// MARK: - Edit view (per-DISP chrome)

/**
 * [chromeEditable] into the Edit view's badge [boxes]. The box goes when its element leaves the
 * screen (a readout that lost its source, the media readout giving way to the shots pill), so no
 * eye is left over nothing; iOS measures by preference, which has no stale box to drop.
 */
@Composable
internal fun Modifier.nikonChromeEditable(
    host: NikonChromeEditHost,
    section: ChromeSection,
    mode: MonitorDisplayMode?,
    boxes: MutableMap<ChromeSection, MonitorRect>,
): Modifier {
    DisposableEffect(boxes, section) { onDispose { boxes.remove(section) } }
    return chromeEditable(host, section, mode) { key, rect -> boxes[key] = rect }
}

/**
 * The Edit view's host (iOS `NativeAppModel: ChromeEditHost`): this monitor's own sections and DISP
 * modes, on the capture side the body reports. Ending the edit opens Display settings again.
 */
internal class NikonChromeEditHost(
    private val settings: OperatorSettings,
    private val capture: CaptureLayoutMode,
    private val onEnded: () -> Unit,
) : ChromeEditHost<ChromeSection, MonitorDisplayMode> {
    override val chromeEditSections: List<ChromeSection> = PLACEMENT_ORDER
    override fun chromeSectionTitle(section: ChromeSection): String = section.title
    override fun chromeSectionID(section: ChromeSection): String = section.key
    override fun chromeModeTitle(mode: MonitorDisplayMode): String = mode.label
    override fun isChromeConfigurable(section: ChromeSection, mode: MonitorDisplayMode): Boolean =
        section.isConfigurableIn(mode)
    override fun isChromeVisible(section: ChromeSection, mode: MonitorDisplayMode): Boolean =
        settings.chrome(mode, capture)[section].value
    override fun toggleChrome(section: ChromeSection, mode: MonitorDisplayMode) {
        settings.toggleChrome(section, mode, capture)
    }
    override fun endChromeEditing() {
        settings.endChromeEditing()
        onEnded()
    }

    companion object {
        /**
         * The lock and batteries first: on a portrait phone they share the status bar's top corner,
         * where the edge inset leaves room for one eye, so the long status bar takes a spot along
         * its own edge instead of stacking on theirs.
         */
        val PLACEMENT_ORDER: List<ChromeSection> =
            listOf(ChromeSection.LOCK_BUTTON, ChromeSection.BATTERY_INDICATORS) +
                ChromeSection.entries.filter { it != ChromeSection.LOCK_BUTTON && it != ChromeSection.BATTERY_INDICATORS }
    }
}

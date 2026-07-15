package com.opencapture.openzcine

import android.view.HapticFeedbackConstants
import android.widget.Toast
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.positionChange
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.onLongClick
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.tween
import androidx.compose.ui.platform.testTag
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.IntSize
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.displayCutout
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.currentStateAsState
import com.opencapture.openzcine.bridge.AndroidLinkHealthMonitor
import com.opencapture.openzcine.bridge.AndroidLiveViewController
import com.opencapture.openzcine.bridge.MonitorZones
import com.opencapture.openzcine.bridge.SwiftCore
import com.opencapture.openzcine.bridge.SwiftCoreCameraSession
import com.opencapture.openzcine.bridge.SwiftLiveViewPolicyInput
import com.opencapture.openzcine.bridge.SwiftLiveViewPreviewState
import com.opencapture.openzcine.bridge.ZoneFrame
import com.opencapture.openzcine.core.CameraControl
import com.opencapture.openzcine.core.CameraControlException
import com.opencapture.openzcine.core.CameraFocusException
import com.opencapture.openzcine.core.CameraFocusPoint
import com.opencapture.openzcine.core.CameraPropertyRefreshFailure
import com.opencapture.openzcine.core.CameraPropertyRefreshStatus
import com.opencapture.openzcine.core.CameraRecordingException
import com.opencapture.openzcine.core.CameraRecordingState
import com.opencapture.openzcine.core.CameraSession
import com.opencapture.openzcine.core.CameraSessionState
import com.opencapture.openzcine.core.CameraTemperatureStatus
import com.opencapture.openzcine.core.LiveAudioMeterLevels
import com.opencapture.openzcine.core.LiveFrameSource
import com.opencapture.openzcine.core.LiveFrameTimecode
import com.opencapture.openzcine.lut.AndroidLutLibrary
import com.opencapture.openzcine.media.LiveAssistOptionsOverlay
import com.opencapture.openzcine.media.retainLiveAssistOptions
import com.opencapture.openzcine.remote.AndroidMediaRemoteShutter
import com.opencapture.openzcine.remote.MediaRemoteShutterCommand
import com.opencapture.openzcine.remote.routeMediaRemoteShutterCommand
import com.opencapture.openzcine.remote.shouldArmMediaRemoteShutter
import com.opencapture.openzcine.settings.MonitorDisplayMode
import com.opencapture.openzcine.settings.OperatorSettings
import com.opencapture.openzcine.wear.AndroidWearPhoneRelay
import com.opencapture.openzcine.wear.WearRecordCommandSafety
import com.opencapture.openzcine.wear.androidWatchRelayState
import com.opencapture.openzcine.wear.executeWearRecordCommand
import com.opencapture.openzcine.wearrelay.WatchCommandResult
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch

/** One measured live-toolbar tool and the orientation in which its anchor is valid. */
private data class LiveAssistOptionsRequest(
    val tool: AssistTool,
    val anchorBounds: Rect,
    val portrait: Boolean,
)

/** Gives the live quick-settings panel first refusal on the system Back action. */
@Composable
internal fun LiveAssistOptionsBackHandler(visible: Boolean, onDismiss: () -> Unit) {
    BackHandler(enabled = visible, onBack = onDismiss)
}

/** Which landscape rail controls remain mounted for one chrome/recording state. */
internal data class LandscapeSideRailPlan(
    val fullRailsVisible: Boolean,
    val settingsRecoveryVisible: Boolean,
    val recordingSafetyVisible: Boolean,
)

/**
 * Hiding side rails never removes the Settings recovery path. An active or
 * pending recording also retains its record control until the camera settles.
 */
internal fun landscapeSideRailPlan(
    sideRailsVisible: Boolean,
    recording: Boolean,
    recordCommandPending: Boolean,
    recordConfirmationPending: Boolean,
): LandscapeSideRailPlan =
    LandscapeSideRailPlan(
        fullRailsVisible = sideRailsVisible,
        settingsRecoveryVisible = !sideRailsVisible,
        recordingSafetyVisible =
            !sideRailsVisible &&
                (recording || recordCommandPending || recordConfirmationPending),
    )

/**
 * A live capture picker stays mounted while its real camera command is in
 * flight, then closes when its mode or chrome region is no longer available.
 */
internal fun retainMonitorPickerForChrome(
    mode: MonitorDisplayMode,
    cameraValuesVisible: Boolean,
    cameraCommandPending: Boolean,
): Boolean = cameraCommandPending || (mode == MonitorDisplayMode.LIVE && cameraValuesVisible)

/** Settings-only affordance used when the landscape side rails are hidden. */
@Composable
internal fun LandscapeSettingsRecoveryButton(
    modifier: Modifier = Modifier,
    onOpenSettings: () -> Unit,
) {
    AuxCircleButton(
        modifier.semantics {
            contentDescription = "Open Settings, restore hidden monitor controls"
        },
        onClick = onOpenSettings,
    ) { glyphModifier, tint ->
        GearGlyph(tint, glyphModifier)
    }
}

/** Places a composable at an absolute zone frame (full-viewport dp coordinates). */
internal fun Modifier.zone(frame: ZoneFrame): Modifier =
    offset(frame.x.dp, frame.y.dp).size(frame.width.dp, frame.height.dp)

/**
 * The iPhone Dynamic Island's landscape leading safe-area inset, in points/dp —
 * the canonical iOS geometry throughout the core tests
 * (`Tests/OpenZCineCoreTests/MonitorLayoutPolicyTests.swift`:
 * `MonitorEdgeInsets(top: 0, leading: 59, bottom: 21, trailing: 44)`).
 * `MonitorFeedLayout.leadingInset` turns it into a left chrome lane: the feed
 * starts at x = 59 while the fixed-margin lock button and battery rail
 * (chrome insets ignore the safe area; lock spans x 16–56) sit beside it.
 */
internal const val IOS_ISLAND_LANE_DP = 59f

/**
 * The bottom inset handed to the portrait zone map while Android's system bars
 * are hidden. The SM-A127F reports a zero bottom inset in sticky immersive
 * mode, but the physical gesture/home-indicator area is still present. This
 * floor keeps the 83dp record control comfortably above that edge after the
 * shared layout reclaims its 14dp system-bar lift.
 */
internal const val PORTRAIT_SYSTEM_RAIL_BOTTOM_INSET_DP = 30f

/**
 * Leading inset handed to the zone map, in dp: the display cutout floored at
 * [IOS_ISLAND_LANE_DP], plus any transient system-bar lane on this edge.
 *
 * Devices whose punch-hole resolves below the core's 50dp cutout threshold
 * (SM-A127F: zero inset) would otherwise run the feed edge-to-edge, putting
 * the lock button and battery rail ON the image. Flooring the cutout at the
 * iPhone island lane synthesizes the iOS composition — feed right of the
 * chrome — as a platform-adapter decision, keeping the shared core
 * platform-blind. The floor is a MINIMUM under the physical cutout only; a
 * transient bar on this edge (reverse-landscape nav bar) still ADDS its lane
 * on top so the feed clears the overlay.
 */
internal fun monitorLeadingInsetDp(cutoutDp: Float, transientBarDp: Float): Float =
    maxOf(cutoutDp, IOS_ISLAND_LANE_DP) + maxOf(0f, transientBarDp - cutoutDp)

/**
 * Bottom inset handed to the zone map, in dp.
 *
 * Sticky immersive mode can report no Android navigation-bar inset even
 * though a device still reserves its gesture area at the physical bottom.
 * Keep a portrait-only floor so the fixed system rail and its record button
 * never touch that edge; a real, larger system-bar/cutout inset still wins.
 */
internal fun monitorBottomInsetDp(rawInsetDp: Float, isPortrait: Boolean): Float =
    if (isPortrait) {
        maxOf(rawInsetDp, PORTRAIT_SYSTEM_RAIL_BOTTOM_INSET_DP)
    } else {
        rawInsetDp
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
 * (ios/Runner/MonitorUnified.swift), laid out by the SAME shared-core zone
 * map via [SwiftCore.monitorZoneMap] in both orientations.
 *
 * Scope: feed, top info deck (landscape pill / portrait bar), lock/battery
 * band, capture strip, assist toolbar (wired to the feed-effects engine and
 * the scope panels), record / DISP / media / settings controls, DISP 1→2→3
 * cycling incl. the command dashboard, persisted portrait fit/fill geometry,
 * and camera-backed in-monitor pickers. Every writable selection reuses the
 * typed CameraSession/Swift command seam; descriptor-dependent controls stay
 * read-only rather than receiving guessed options.
 *
 * Chrome glass runs the tiered GPU treatment (GlassChrome.kt) at this
 * device's [resolveTier] ceiling; [glassTierOverride] (`zc.glass.tier`
 * debug intent extra) forces a lower tier for testing.
 *
 * [assist] is shared with Operator Settings so toolbar and settings changes
 * immediately drive the same feed-effects and scope state.
 */
@Composable
fun MonitorScreen(
    session: CameraSession,
    frameSource: LiveFrameSource?,
    assist: AssistState,
    operatorSettings: OperatorSettings,
    lutLibrary: AndroidLutLibrary? = null,
    liveViewEnabled: Boolean = true,
    glassTierOverride: String? = null,
    mediaRemoteShutter: AndroidMediaRemoteShutter? = null,
    isMonitorFront: Boolean = true,
    linkHealth: AndroidLinkHealthMonitor? = null,
    activeTransportIsUsb: Boolean = false,
    isDemoSession: Boolean = false,
    onOpenSettings: () -> Unit = {},
    onOpenMedia: () -> Unit = {},
) {
    val appContext = LocalContext.current.applicationContext
    // A monitor-scoped relay means the wearable never becomes an independent
    // LiveFrameSource subscriber or a background camera owner.
    val wearRelay = remember(appContext) { AndroidWearPhoneRelay(appContext) }
    val lifecycleState by LocalLifecycleOwner.current.lifecycle.currentStateAsState()
    val sessionState by session.state.collectAsState()
    val monitorAccessibilityState =
        when (sessionState) {
            is CameraSessionState.Connected -> "Camera connected"
            CameraSessionState.Connecting -> "Camera connecting"
            CameraSessionState.Disconnected -> "Camera disconnected"
        }
    val cameraProperties by session.cameraProperties.collectAsState()
    val propertyRefreshStatus by session.propertyRefreshStatus.collectAsState()
    val cameraReadouts = remember(cameraProperties) { monitorCameraReadouts(cameraProperties) }
    val phoneBatteryReadout = rememberPhoneBatteryReadout()
    val exposureAssistCameraInput =
        remember(cameraProperties.codec, cameraProperties.iso, cameraProperties.baseIso) {
            ExposureAssistCameraInput(
                codec = cameraProperties.codec,
                iso = cameraProperties.iso,
                baseIso = cameraProperties.baseIso,
            )
        }
    val thermalTier = rememberAndroidThermalTier()
    val actualLinkHealth = linkHealth ?: remember(session) { AndroidLinkHealthMonitor() }
    val swiftLiveFrameSource =
        (session as? SwiftCoreCameraSession)?.liveFrames as? com.opencapture.openzcine.bridge.SwiftCoreLiveFrameSource
    val liveViewController =
        remember(swiftLiveFrameSource) {
            swiftLiveFrameSource?.let(::AndroidLiveViewController)
        }
    val noPreviewApplication =
        remember { MutableStateFlow<SwiftLiveViewPreviewState>(SwiftLiveViewPreviewState.Idle) }
    val previewApplication by
        (swiftLiveFrameSource?.previewState ?: noPreviewApplication).collectAsState()
    LaunchedEffect(session) { session.connect() }

    // Shared glass state: the active tier plus the one blurred backdrop
    // texture every glass pill samples. The frame-clock loop is the perf
    // safety net — sustained overruns of the 48 ms p90 budget drop one tier
    // (FULL → BLUR → FLAT) and stop the backdrop work with it.
    val glass = remember {
        MonitorGlass(resolveTier(android.os.Build.VERSION.SDK_INT, glassTierOverride))
    }
    LaunchedEffect(glass) {
        val budget = FrameBudgetWindow()
        var last = 0L
        while (glass.tier != GlassTier.FLAT) {
            withFrameNanos { now ->
                if (last != 0L && budget.frame(now - last)) glass.demote()
                last = now
            }
        }
    }

    // Shell state, iOS-model-equivalent: a typed DISP mode and the interface
    // lock. Order/enablement live in OperatorSettings and remain observable
    // while the full-screen settings overlay keeps this monitor mounted.
    // Recording is owned by the CameraSession; the shell only renders its
    // state and asks it to send a Nikon command.
    var displayMode by remember { mutableStateOf(MonitorDisplayMode.LIVE) }
    val effectiveDisplayMode = operatorSettings.reconciledDisplayMode(displayMode)
    var locked by remember { mutableStateOf(false) }
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
    LaunchedEffect(
        liveViewController,
        operatorSettings.streamPreset,
        operatorSettings.qualityBias,
        thermalTier,
        previewPolicyRecording,
        cameraProperties.temperatureStatus,
    ) {
        liveViewController?.apply(
            SwiftLiveViewPolicyInput(
                streamPreset = operatorSettings.streamPreset.wireValue,
                qualityBias = operatorSettings.qualityBias.wireValue,
                thermalTier = thermalTier.wireValue,
                isRecording = previewPolicyRecording,
                cameraOverheating = cameraProperties.temperatureStatus == CameraTemperatureStatus.HOT,
            ),
        )
    }
    val recordCommandPending =
        recordingState == CameraRecordingState.STARTING ||
            recordingState == CameraRecordingState.STOPPING
    val recordControlEnabled =
        sessionState is CameraSessionState.Connected && !recordCommandPending
    val recordScope = rememberCoroutineScope()
    val commandTileOrderStore = remember(appContext) { CommandTileOrderStore(appContext) }
    var commandTileOrder by remember(commandTileOrderStore) {
        mutableStateOf(commandTileOrderStore.load())
    }
    var activeCommandControl by remember { mutableStateOf<CommandControlRequest?>(null) }
    var activeMonitorPickerKind by remember { mutableStateOf<MonitorPickerKind?>(null) }
    var activeAssistOptions by remember { mutableStateOf<LiveAssistOptionsRequest?>(null) }
    val analysisPanelPlacementStore =
        remember(appContext) { MonitorAnalysisPanelPlacementStore(appContext) }
    var analysisPanelPlacementRevision by remember { mutableIntStateOf(0) }
    LiveAssistOptionsBackHandler(visible = activeAssistOptions != null) {
        activeAssistOptions = null
    }
    var pendingCommandControl by remember { mutableStateOf<CameraControl?>(null) }
    var commandControlFeedback by remember { mutableStateOf<CommandControlFeedback?>(null) }
    LaunchedEffect(effectiveDisplayMode) {
        if (displayMode != effectiveDisplayMode) displayMode = effectiveDisplayMode
    }
    val commandPresentation =
        remember(
            cameraProperties,
            propertyRefreshStatus,
            sessionState,
            commandTileOrder,
            recording,
        ) {
            commandDashboardPresentation(
                snapshot = cameraProperties,
                refreshStatus = propertyRefreshStatus,
                sessionState = sessionState,
                tileOrder = commandTileOrder,
                recording = recording,
            )
        }
    val captureSettings = remember(commandPresentation) { monitorCaptureSettings(commandPresentation) }
    val activeMonitorPicker =
        captureSettings.firstOrNull { it.kind == activeMonitorPickerKind }?.picker
    val mediaOwnsCommandChannel =
        (propertyRefreshStatus as? CameraPropertyRefreshStatus.Degraded)?.failure ==
            CameraPropertyRefreshFailure.MEDIA_BUSY
    val commandControlsEnabled =
        sessionState is CameraSessionState.Connected &&
            !locked &&
            !mediaOwnsCommandChannel
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
    val applyCameraControl: (CommandControlRequest, String) -> Unit = applyCameraControl@{ request, label ->
        if (!commandControlsEnabled || pendingCommandControl != null) return@applyCameraControl
        pendingCommandControl = request.control
        commandControlFeedback = null
        recordScope.launch {
            try {
                session.applyControl(request.control, label)
                session.refreshProperties()
                if (cameraPropertyConfirmsSelection(session.cameraProperties.value, request.control, label)) {
                    if (activeCommandControl?.control == request.control) {
                        activeCommandControl = request.copy(currentValue = label)
                    }
                    commandControlFeedback =
                        CommandControlFeedback("${request.title} set to $label.", isError = false)
                } else {
                    commandControlFeedback =
                        CommandControlFeedback(
                            "${request.title} request accepted; awaiting camera readback.",
                            isError = false,
                        )
                }
            } catch (error: CameraControlException) {
                commandControlFeedback =
                    CommandControlFeedback(
                        error.message ?: "The camera rejected the control change.",
                        isError = true,
                    )
            } finally {
                pendingCommandControl = null
            }
        }
    }
    var pendingRecordTarget by remember { mutableStateOf<Boolean?>(null) }
    val sendRecordCommand: (Boolean) -> Unit = { target ->
        recordScope.launch {
            try {
                session.setRecording(target)
            } catch (error: CameraRecordingException) {
                Toast.makeText(appContext, error.message, Toast.LENGTH_SHORT).show()
            }
        }
    }
    val requestRecordToggle: () -> Unit = {
        if (recordControlEnabled) {
            val target = !recording
            if (operatorSettings.recordConfirmationEnabled.value) {
                pendingRecordTarget = target
                mediaRemoteShutter?.disarm()
            } else {
                sendRecordCommand(target)
            }
        }
    }
    // Match the iOS watch's intentional confirmation bypass only after all
    // Android monitor/session/pending-command safety gates still hold. A watch
    // never owns a camera path; this reaches the same CameraSession seam as
    // the on-phone record control.
    val latestWearRecordCommand =
        rememberUpdatedState<suspend () -> WatchCommandResult>(
            newValue = {
                val safety =
                    WearRecordCommandSafety(
                        monitorFront = isMonitorFront,
                        applicationResumed = lifecycleState.isAtLeast(Lifecycle.State.RESUMED),
                        cameraConnected = sessionState is CameraSessionState.Connected,
                        recordCommandPending = recordCommandPending,
                        recordConfirmationPending = pendingRecordTarget != null,
                        cameraControlPending = pendingCommandControl != null,
                    )
                executeWearRecordCommand(safety, recording, session::setRecording)
            },
        )
    DisposableEffect(wearRelay) {
        wearRelay.setCommandHandler { latestWearRecordCommand.value.invoke() }
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
            recordConfirmationPending = pendingRecordTarget != null,
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
        val portraitAspect = operatorSettings.portraitFeedAspect
        val isPortraitFill = isPortrait && !isCommand && portraitAspect.fillsViewport

        val statusBarVisible = operatorSettings.statusBarVisible.value
        val assistToolbarVisible = operatorSettings.assistToolbarVisible.value
        val cameraValuesVisible = operatorSettings.cameraValuesVisible.value
        val sideRailsVisible = operatorSettings.sideRailsVisible.value
        val visibleAssistTools = operatorSettings.visibleAssistToolbarTools
        val openAssistOptions: (AssistTool, Rect) -> Unit = { tool, anchor ->
            if (!locked) {
                activeMonitorPickerKind = null
                activeCommandControl = null
                commandControlFeedback = null
                activeAssistOptions = LiveAssistOptionsRequest(tool, anchor, isPortrait)
            }
        }
        LaunchedEffect(
            activeAssistOptions,
            isPortrait,
            isClean,
            isCommand,
            locked,
            lifecycleState,
            visibleAssistTools,
            assistToolbarVisible,
        ) {
            val request = activeAssistOptions ?: return@LaunchedEffect
            val retained =
                request.portrait == isPortrait &&
                    retainLiveAssistOptions(
                        tool = request.tool,
                        visibleTools = visibleAssistTools,
                        liveMode = !isClean && !isCommand && assistToolbarVisible,
                        locked = locked,
                        resumed = lifecycleState.isAtLeast(Lifecycle.State.RESUMED),
                    )
            if (!retained) activeAssistOptions = null
        }
        LaunchedEffect(
            effectiveDisplayMode,
            cameraValuesVisible,
            pendingCommandControl,
        ) {
            if (activeMonitorPickerKind != null &&
                !retainMonitorPickerForChrome(
                    mode = effectiveDisplayMode,
                    cameraValuesVisible = cameraValuesVisible,
                    cameraCommandPending = pendingCommandControl != null,
                )
            ) {
                activeMonitorPickerKind = null
                commandControlFeedback = null
            }
        }
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
                assist.displayedPortraitScopes
            } else {
                emptyList()
            }
        val scopeCount = portraitScopes.size
        val zones =
            remember(
                viewportWidth, viewportHeight, safeTop, safeLeading, safeBottom, safeTrailing,
                isPortrait, effectiveDisplayMode, isPortraitFill, scopeCount, bottomBarHeight,
            ) {
                MonitorZones.parse(
                    SwiftCore.monitorZoneMap(
                        viewportWidth = viewportWidth,
                        viewportHeight = viewportHeight,
                        safeTop = safeTop,
                        safeLeading = safeLeading,
                        safeBottom = safeBottom,
                        safeTrailing = safeTrailing,
                        mode = effectiveDisplayMode.wireIndex,
                        isPortrait = isPortrait,
                        aspectFill = isPortraitFill,
                        scopeCount = scopeCount,
                        mirrored = false,
                        bottomBarHeight = bottomBarHeight,
                    ),
                )
            }
        // Local framing is deliberately read from the operator store rather
        // than the camera session: grid/crosshair/guides are composited over
        // the existing feed zone and never alter the Nikon Grid Display.
        val localFraming = operatorSettings.localFramingAssistConfiguration
        // The gauge is a HUD instrument, so its lower track must clear the
        // bottom strips actually mounted over the feed. Pass this local pixel
        // inset into the overlay rather than guessing from a device class or
        // a global screen margin; it preserves the iOS visible-feed seating
        // rule for every zone-map size and operator chrome configuration.
        val bottomChromeTop =
            listOfNotNull(
                    zones.assistStrip?.takeIf { !isClean && assistToolbarVisible }?.y,
                    zones.captureStrip?.takeIf { !isClean && cameraValuesVisible }?.y,
                )
                .minOrNull()
        val levelGaugeBottomChromeInset =
            with(density) {
                bottomChromeTop?.let { chromeTop ->
                    maxOf(0f, zones.feed.y + zones.feed.height - chromeTop).dp.toPx()
                } ?: 0f
            }

        // An explicit demo source wins; otherwise a connected Swift-core
        // session streams its own live view. Media ownership gates collection,
        // and backgrounding drops below STARTED so the camera receives
        // EndLiveView instead of continuing sensor readout for no consumer.
        val activeFrameSource =
            if (!liveViewEnabled) {
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
        // The chrome observes only frames the existing feed decoder actually
        // presents. This adds no LiveFrameSource subscriber, so OPE-60's
        // current-stream health collector remains the sole link-score input
        // and DISP 3 still releases native live view.
        val timecodeOwner = monitorTimecodeOwner(sessionState)
        val timecodeRetention =
            remember(session, timecodeOwner) { MonitorTimecodeRetention(timecodeOwner) }
        val presentedTimecode = timecodeRetention.timecodeFor(sessionState)
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
        val appliedPreviewRequest =
            if (previewApplication is SwiftLiveViewPreviewState.Idle) {
                null
            } else {
                swiftLiveFrameSource?.appliedPreviewRequest
            }
        val healthTargetFramesPerSecond =
            appliedPreviewRequest?.targetFramesPerSecond ?: 30.0
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
            )
        }
        LaunchedEffect(actualLinkHealth, healthFrameSource) {
            (healthFrameSource as? com.opencapture.openzcine.bridge.SwiftCoreLiveFrameSource)
                ?.currentStreamFrames
                ?.collect(actualLinkHealth::recordFrame)
        }
        LaunchedEffect(actualLinkHealth, propertyRefreshStatus) {
            actualLinkHealth.reportPropertyRefresh(propertyRefreshStatus)
        }
        LaunchedEffect(actualLinkHealth, healthFrameSource) {
            while (true) {
                delay(1_000)
                actualLinkHealth.refresh()
            }
        }
        val liveFeedPresentation =
            remember(monitorFrameSource) { LiveFeedPresentationState() }
        val liveFeedEffectsPresentation =
            remember(monitorFrameSource) { LiveFeedEffectsPresentationState() }
        var feedPointerSize by remember(monitorFrameSource) { mutableStateOf(IntSize.Zero) }
        val audioMetersEnabled = assist.audioMetersEnabled
        var liveAudioLevels by
            remember(monitorFrameSource) { mutableStateOf<LiveAudioMeterLevels?>(null) }
        LaunchedEffect(monitorFrameSource, audioMetersEnabled) {
            if (!audioMetersEnabled || monitorFrameSource == null) {
                liveAudioLevels = null
                return@LaunchedEffect
            }
            monitorFrameSource.frames.collect { frame ->
                liveAudioLevels = frame.audioLevels
            }
        }
        val railPlan =
            landscapeSideRailPlan(
                sideRailsVisible = sideRailsVisible,
                recording = recording,
                recordCommandPending = recordCommandPending,
                recordConfirmationPending = pendingRecordTarget != null,
            )
        val physicalViewport = ZoneFrame(0f, 0f, viewportWidth, viewportHeight)
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
                    landscapeFullSideRails = railPlan.fullRailsVisible,
                    landscapeSettingsRecovery = railPlan.settingsRecoveryVisible,
                    landscapeRecordingSafety = railPlan.recordingSafetyVisible,
                )
            }
        val analysisPanelLayout =
            remember(
                zones,
                physicalViewport,
                isPortrait,
                isPortraitFill,
                statusBarVisible,
                analysisChromeMounts,
            ) {
                monitorAnalysisPanelLayout(
                    zones = zones,
                    physicalViewport = physicalViewport,
                    isPortrait = isPortrait,
                    isPortraitFill = isPortraitFill,
                    statusBarVisible = statusBarVisible,
                    chromeMounts = analysisChromeMounts,
                )
            }

        // Backdrop geometry for the glass pipeline: the viewport and the feed
        // zone in root px. The blurred texture covers the whole viewport
        // (black letterbox included), so pills over black sample the same
        // map. setLayout is idempotent per geometry, so calling it on every
        // recomposition is free.
        val backdropFeedRect =
            with(density) {
                android.graphics.RectF(
                    zones.feed.x.dp.toPx(),
                    zones.feed.y.dp.toPx(),
                    (zones.feed.x + zones.feed.width).dp.toPx(),
                    (zones.feed.y + zones.feed.height).dp.toPx(),
                )
            }
        // setLayout resets the backdrop's draw-observed frame counter when
        // dimensions change. Commit that mutation after composition so a
        // concurrent decode-thread submit cannot conflict with the initial
        // landscape/portrait subcomposition during rotation.
        SideEffect {
            glass.backdrop.setLayout(
                rootWidthPx = constraints.maxWidth.toFloat(),
                rootHeightPx = constraints.maxHeight.toFloat(),
                feedRectPx = backdropFeedRect,
                aspectFill = isPortraitFill,
            )
        }

        // Feed at the shared zone-map frame. Fit keeps the whole frame;
        // portrait fill centre-crops the image and every feed-aligned overlay
        // through the same content-rect resolver. Command unmounts the feed.
        val feedFocus = liveFeedPresentation.focus
        val feedContent =
            liveFeedContentRect(
                containerWidth = feedPointerSize.width.toFloat(),
                containerHeight = feedPointerSize.height.toFloat(),
                sourceWidth = liveFeedPresentation.sourceWidth,
                sourceHeight = liveFeedPresentation.sourceHeight,
                aspectFill = isPortraitFill,
            )
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
                interfaceLocked = locked,
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
            if (operatorSettings.hapticsEnabled.value) {
                view.performHapticFeedback(
                    if (next) {
                        HapticFeedbackConstants.LONG_PRESS
                    } else {
                        HapticFeedbackConstants.KEYBOARD_TAP
                    },
                )
            }
        }
        val handleFocusFeedAction: (FocusFeedGestureAction) -> Unit = handleFocusFeedAction@{ action ->
            when (action) {
                is FocusFeedGestureAction.SetFocusPoint -> {
                    if (!focusGestureContext.canSetFocusPoint) {
                        return@handleFocusFeedAction
                    }
                    focusMoveRequestsInFlight += 1
                    recordScope.launch {
                        try {
                            val accepted =
                                session.changeAfArea(
                                    CameraFocusPoint(action.coordinate.x, action.coordinate.y),
                                )
                            if (accepted && operatorSettings.hapticsEnabled.value) {
                                view.performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP)
                            }
                        } catch (error: CameraFocusException) {
                            Toast.makeText(
                                    appContext,
                                    error.message ?: "The camera rejected the focus-point change.",
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
                    operatorSettings.displayModeForExplicitRequest(action.mode)?.let { next ->
                        if (next != effectiveDisplayMode) {
                            displayMode = next
                            if (operatorSettings.hapticsEnabled.value) {
                                view.performHapticFeedback(HapticFeedbackConstants.CLOCK_TICK)
                            }
                        }
                    }
                }
                FocusFeedGestureAction.ToggleFocusPointLock -> toggleFocusPointLock()
            }
        }
        if (!isCommand) {
            Box(
                Modifier.zone(zones.feed)
                    .clipToBounds()
                    .onSizeChanged { feedPointerSize = it }
                    // Canvas content is not exposed as an accessibility node
                    // by every Android view bridge. The feed container is the
                    // stable, descriptive region for TalkBack and UI tests.
                    .semantics {
                        stateDescription = "Display mode ${effectiveDisplayMode.label}"
                        contentDescription =
                            when {
                                monitorFrameSource == null -> "Live view unavailable"
                                focusPointLocked ->
                                    "Live view active. Focus point position locked in app."
                                focusGestureContext.canRecognizeFocusGesture ->
                                    "Live view active. Tap to move focus point; hold to lock its position."
                                else ->
                                    "Live view active. Camera focus point control unavailable."
                            }
                        if (focusGestureContext.canRecognizeFocusGesture) {
                            onLongClick(
                                label =
                                    if (focusPointLocked) {
                                        "Unlock focus point position"
                                    } else {
                                        "Lock focus point position"
                                    },
                            ) {
                                toggleFocusPointLock()
                                true
                            }
                        }
                    }
                    .testTag("monitor_live_feed")
                    .focusFeedGestures(
                        geometry = feedGestureGeometry,
                        context = focusGestureContext,
                        isPortrait = isPortrait,
                        onHoldingChanged = { focusLockHolding = it },
                        onAction = handleFocusFeedAction,
                        onPortraitPinch = { zoom ->
                            portraitAspectAfterPinch(zoom, portraitAspect)?.let { next ->
                                operatorSettings.portraitFeedAspect = next
                            }
                        },
                    ),
                contentAlignment = Alignment.Center,
            ) {
                if (monitorFrameSource != null) {
                    LiveFeedView(
                        monitorFrameSource,
                        Modifier.fillMaxSize().graphicsLayer {
                            scaleX = localFraming.horizontalPresentationScale
                            scaleY = localFraming.verticalPresentationScale
                        },
                        onFrame = glass::submit,
                        onPresentedFrame = { frame, bitmap, baker ->
                            timecodeRetention.accept(frame.timecode)
                            wearRelay.ingestPresentedFrame(frame, bitmap, baker)
                        },
                        presentationState = liveFeedPresentation,
                        effects = assist.effects,
                        configuration = operatorSettings.feedEffectsConfiguration,
                        cameraInput = exposureAssistCameraInput,
                        lutLibrary = lutLibrary,
                        effectsPresentationState = liveFeedEffectsPresentation,
                        aspectFill = isPortraitFill,
                    )
                    // Presentation-only texture: after the camera frame/effect renderer, before
                    // every geometry-bearing assist. Scopes continue sampling monitorFrameSource.
                    FeedTextureOverlay(
                        presentationState = liveFeedPresentation,
                        aspectFill = isPortraitFill,
                        horizontalPresentationScale = localFraming.horizontalPresentationScale,
                        verticalPresentationScale = localFraming.verticalPresentationScale,
                    )
                } else {
                    Text(
                        text =
                            when (val current = sessionState) {
                                is CameraSessionState.Connected -> current.identity.name
                                CameraSessionState.Connecting -> "Connecting…"
                                CameraSessionState.Disconnected -> "No camera"
                            },
                        style = chromeStyle(15f, FontWeight.Medium),
                        color = LiveDesign.muted,
                    )
                }
                LocalFramingAssistOverlay(
                    configuration = localFraming,
                    cleanMode = isClean,
                    presentationState = liveFeedPresentation,
                    aspectFill = isPortraitFill,
                )
                LiveFrameMetadataOverlay(
                    presentationState = liveFeedPresentation,
                    configuration = localFraming,
                    cleanMode = isClean,
                    isPortrait = isPortrait,
                    aspectFill = isPortraitFill,
                    gaugeBottomChromeInset = levelGaugeBottomChromeInset,
                    focusPointLocked = focusPointLocked,
                    focusLockProgress = focusLockProgress,
                )
                val focusResetVisible =
                    focusResetAvailable(feedFocus, focusPointLocked) &&
                        sessionState is CameraSessionState.Connected &&
                        !locked &&
                        !mediaOwnsCommandChannel &&
                        !otherCameraCommandPending
                if (focusResetVisible) {
                    IconButton(
                        onClick = resetFocusPoint@{
                            if (focusCommandPending) return@resetFocusPoint
                            focusResetPending = true
                            recordScope.launch {
                                try {
                                    session.resetFocusPoint()
                                    if (operatorSettings.hapticsEnabled.value) {
                                        view.performHapticFeedback(
                                            HapticFeedbackConstants.KEYBOARD_TAP,
                                        )
                                    }
                                } catch (error: CameraFocusException) {
                                    Toast.makeText(
                                            appContext,
                                            error.message ?: "The camera could not reset focus.",
                                            Toast.LENGTH_SHORT,
                                        )
                                        .show()
                                } finally {
                                    focusResetPending = false
                                }
                            }
                        },
                        enabled = !focusCommandPending,
                        modifier =
                            Modifier
                                .align(
                                    if (isPortrait) {
                                        Alignment.BottomEnd
                                    } else {
                                        Alignment.BottomStart
                                    },
                                )
                                .padding(
                                    start = 10.dp,
                                    end = 10.dp,
                                    bottom =
                                        with(density) {
                                            levelGaugeBottomChromeInset.toDp()
                                        } + 10.dp,
                                )
                                .size(40.dp)
                                .background(Color.Black.copy(alpha = 0.58f), CircleShape)
                                .border(1.dp, LiveDesign.hairline, CircleShape)
                                .testTag("focus_reset_button")
                                .semantics {
                                    contentDescription =
                                        when {
                                            focusResetPending ->
                                                "Resetting focus point to center"
                                            focusMoveRequestsInFlight > 0 ->
                                                "Reset focus point unavailable while moving focus"
                                            else -> "Reset focus point to center"
                                        }
                                },
                    ) {
                        Text(
                            text = if (focusResetPending) "…" else "◎",
                            style = chromeStyle(18f, FontWeight.SemiBold),
                            color = LiveDesign.text,
                        )
                    }
                }
            }
        }
        CompositionLocalProvider(LocalMonitorGlass provides glass) {
            if (isPortrait) {
                PortraitChrome(
                    zones = zones,
                    viewportHeight = viewportHeight,
                    isCommand = isCommand,
                    isFill = isPortraitFill,
                    locked = locked,
                    recording = recording,
                    timecode = presentedTimecode,
                    cameraReadouts = cameraReadouts,
                    assist = assist,
                    operatorSettings = operatorSettings,
                    commandPresentation = commandPresentation,
                    captureSettings = captureSettings,
                    activeMonitorPicker = activeMonitorPickerKind,
                    commandControlsEnabled = commandControlsEnabled,
                    pendingCommandControl = pendingCommandControl,
                    displayMode = effectiveDisplayMode,
                    enabledDisplayModeOrder = operatorSettings.enabledDisplayModeOrder,
                    onLock = { locked = !locked },
                    recordEnabled = recordControlEnabled,
                    onRecord = requestRecordToggle,
                    onDisp = {
                        activeAssistOptions = null
                        displayMode = operatorSettings.nextDisplayMode(effectiveDisplayMode)
                    },
                    onOpenMedia = {
                        activeAssistOptions = null
                        if (pendingCommandControl == null) activeMonitorPickerKind = null
                        onOpenMedia()
                    },
                    onOpenSettings = {
                        activeAssistOptions = null
                        if (pendingCommandControl == null) activeMonitorPickerKind = null
                        onOpenSettings()
                    },
                    onOpenMonitorPicker = { kind ->
                        activeAssistOptions = null
                        activeCommandControl = null
                        activeMonitorPickerKind =
                            nextMonitorPicker(
                                current = activeMonitorPickerKind,
                                requested = kind,
                                controlsEnabled =
                                    commandControlsEnabled && pendingCommandControl == null,
                            )
                        commandControlFeedback = null
                    },
                    onOpenCommandControl = {
                        activeAssistOptions = null
                        activeMonitorPickerKind = null
                        activeCommandControl = it
                        commandControlFeedback = null
                    },
                    onMoveCommandTile = moveCommandTileTo,
                    onReorderStarted = {
                        if (operatorSettings.hapticsEnabled.value) {
                            view.performHapticFeedback(HapticFeedbackConstants.LONG_PRESS)
                        }
                    },
                    onOpenAssistOptions = openAssistOptions,
                )
            } else {
                if (isCommand) {
                    // The DISP 3 dashboard fills the deck span between the
                    // rails on the warm command background (iOS CommandMonitor).
                    Box(Modifier.fillMaxSize().background(LiveDesign.background))
                    val top = maxOf(14f, safeTop)
                    CommandDashboard(
                        recording = recording,
                        timecode = presentedTimecode,
                        presentation = commandPresentation,
                        controlsEnabled = commandControlsEnabled,
                        pendingControl = pendingCommandControl,
                        onOpenControl = {
                            activeAssistOptions = null
                            activeMonitorPickerKind = null
                            activeCommandControl = it
                            commandControlFeedback = null
                        },
                        onMoveTile = moveCommandTileTo,
                        onReorderStarted = {
                            if (operatorSettings.hapticsEnabled.value) {
                                view.performHapticFeedback(HapticFeedbackConstants.LONG_PRESS)
                            }
                        },
                        modifier =
                            Modifier.zone(
                                ZoneFrame(
                                    zones.infoBar.x,
                                    top,
                                    zones.infoBar.width,
                                    maxOf(0f, viewportHeight - top - safeBottom - 16f),
                                ),
                            ).alpha(if (locked) 0.4f else 1f),
                    )
                } else {
                    // Top info pill, centered in the deck band; compact in clean
                    // mode. The deck is feed-anchored and the synthesized island
                    // lane (see monitorLeadingInsetDp) starts the feed right of
                    // the lock, so the band always clears it — same as iPhone
                    // geometry.
                    if (operatorSettings.statusBarVisible.value) {
                        Box(Modifier.zone(zones.infoBar), contentAlignment = Alignment.Center) {
                            FitScale(zones.infoBar.width.dp) {
                                InfoPill(
                                    compact = isClean,
                                    recording = recording,
                                    timecode = presentedTimecode,
                                    recReadoutVisible = operatorSettings.recReadoutVisible.value,
                                    codecReadoutVisible = operatorSettings.codecReadoutVisible.value,
                                    mediaReadoutVisible = operatorSettings.mediaReadoutVisible.value,
                                    fpsReadoutVisible = operatorSettings.fpsReadoutVisible.value,
                                    signalBars = actualLinkHealth.presentation.signalBars,
                                    resolution = cameraReadouts.resolution,
                                    codec = cameraReadouts.codec,
                                    media = cameraReadouts.media,
                                    fps = cameraReadouts.framesPerSecond,
                                )
                            }
                        }
                    }

                    // Bottom bars — live mode only, dimmed while locked: the
                    // assist toolbar at its zone, and the capture strip whose
                    // glass hugs its readouts against the band's trailing edge
                    // like the iOS content-hugging strip.
                    if (!isClean) {
                        if (assistToolbarVisible) {
                            zones.assistStrip?.let { strip ->
                                AssistToolbar(
                                    assist,
                                    Modifier.zone(strip).alpha(if (locked) 0.4f else 1f),
                                    visibleTools = operatorSettings.visibleAssistToolbarTools,
                                    framingConfiguration = localFraming,
                                    onToggleFramingTool = operatorSettings::toggleLocalFramingTool,
                                    hapticsEnabled = operatorSettings.hapticsEnabled.value,
                                    enabled = !locked,
                                    onLongPressToolAnchored = openAssistOptions,
                                )
                            }
                        }
                        if (cameraValuesVisible) {
                            zones.captureStrip?.let { strip ->
                                Box(
                                    Modifier.zone(strip).alpha(if (locked) 0.4f else 1f),
                                    contentAlignment = Alignment.CenterEnd,
                                ) {
                                    FitScale(strip.width.dp) {
                                        MonitorCaptureStrip(
                                            settings = captureSettings,
                                            activePicker = activeMonitorPickerKind,
                                            controlsEnabled = commandControlsEnabled,
                                            pendingControl = pendingCommandControl,
                                            onOpenPicker = { kind ->
                                                activeCommandControl = null
                                                activeMonitorPickerKind =
                                                    nextMonitorPicker(
                                                        current = activeMonitorPickerKind,
                                                        requested = kind,
                                                        controlsEnabled =
                                                            commandControlsEnabled &&
                                                                pendingCommandControl == null,
                                                    )
                                                commandControlFeedback = null
                                            },
                                        )
                                    }
                                }
                            }
                        }
                    }
                }

                if (railPlan.fullRailsVisible) {
                    // Persistent side rails: lock + authoritative batteries +
                    // record / configured DISP / media / settings.
                    LockButton(locked, Modifier.zone(zones.lock)) { locked = !locked }
                    zones.batteryPhone?.let {
                        BatteryIndicatorColumn(
                            percent = phoneBatteryReadout.percent,
                            isCamera = false,
                            modifier = Modifier.zone(it),
                            externalPower = phoneBatteryReadout.externalPower,
                        )
                    }
                    zones.batteryCamera?.let {
                        BatteryIndicatorColumn(
                            percent = cameraReadouts.batteryPercent,
                            isCamera = true,
                            modifier = Modifier.zone(it),
                            externalPower = cameraReadouts.externalPower,
                        )
                    }
                    AuxCircleButton(
                        Modifier.zone(zones.settings),
                        onClick = {
                            if (pendingCommandControl == null) activeMonitorPickerKind = null
                            onOpenSettings()
                        },
                    ) { glyphModifier, tint ->
                        GearGlyph(tint, glyphModifier)
                    }
                    AuxCircleButton(
                        Modifier.zone(zones.media),
                        onClick = {
                            if (pendingCommandControl == null) activeMonitorPickerKind = null
                            onOpenMedia()
                        },
                    ) { glyphModifier, tint ->
                        MediaStackGlyph(tint, glyphModifier)
                    }
                    RecordButton(
                        recording = recording,
                        modifier = Modifier.zone(zones.record),
                        enabled = recordControlEnabled,
                        onClick = requestRecordToggle,
                    )
                    val enabledOrder = operatorSettings.enabledDisplayModeOrder
                    DispButton(
                        activeIndex = enabledOrder.indexOf(effectiveDisplayMode),
                        modeCount = enabledOrder.size,
                        isLiveActive = effectiveDisplayMode == MonitorDisplayMode.LIVE,
                        modifier = Modifier.zone(zones.disp),
                    ) {
                        activeAssistOptions = null
                        displayMode = operatorSettings.nextDisplayMode(effectiveDisplayMode)
                    }
                } else {
                    if (railPlan.recordingSafetyVisible) {
                        RecordButton(
                            recording = recording,
                            modifier = Modifier.zone(zones.record),
                            enabled = recordControlEnabled,
                            onClick = requestRecordToggle,
                        )
                    }
                    LandscapeSettingsRecoveryButton(
                        modifier = Modifier.zone(zones.settings),
                        onOpenSettings = {
                            activeAssistOptions = null
                            if (pendingCommandControl == null) activeMonitorPickerKind = null
                            onOpenSettings()
                        },
                    )
                }
            }
        }
        // One monitor-owned sampler serves every toolbar-selected scope.
        // Landscape and portrait fill float every selection; portrait fit
        // mounts only its recency-selected ≤2 stack in the shared zone.
        if (!isCommand && assist.selectedScopes.isNotEmpty() && monitorFrameSource != null) {
            ScopePanels(
                selectedScopes = assist.selectedScopes,
                portraitScopes = portraitScopes,
                crushClipCompensationRaw = operatorSettings.scopeCrushClipCompensation.wireValue,
                histogramTrafficLightsEnabled = operatorSettings.histogramTrafficLightsEnabled.value,
                configuration = operatorSettings.scopeAssistConfiguration,
                cameraInput = exposureAssistCameraInput,
                lutSelection = assist.effects.lut,
                lutLibrary = lutLibrary,
                onScaleChange = { kind, scale ->
                    operatorSettings.scopeAssistConfiguration =
                        operatorSettings.scopeAssistConfiguration.withScale(kind, scale)
                },
                thermalTier = thermalTier,
                source = monitorFrameSource,
                isPortrait = isPortrait,
                portraitFloating = isPortraitFill,
                feed = zones.feed,
                infoBar = zones.infoBar,
                scopeZone = zones.scopes,
                panelLayout = analysisPanelLayout,
                placementStore = analysisPanelPlacementStore,
                placementRevision = analysisPanelPlacementRevision,
                hapticsEnabled = operatorSettings.hapticsEnabled.value,
            )
        }
        if (!isCommand && (!isPortrait || isPortraitFill) && audioMetersEnabled) {
            val audioBounds = if (isPortraitFill) zones.feed else physicalViewport
            AudioMetersOverlay(
                levels = liveAudioLevels,
                sensitivity = cameraProperties.microphoneSensitivity,
                feed = zones.feed,
                viewport = audioBounds,
            )
        }
        // Match iOS z-order: the false-colour key is mounted after floating
        // scopes and audio so nothing can obscure or intercept its drag target.
        if (!isCommand && (!isPortrait || isPortraitFill)) {
            val falseColorBounds = if (isPortraitFill) zones.feed else physicalViewport
            CompositionLocalProvider(LocalMonitorGlass provides glass) {
                FalseColorReferenceOverlay(
                    effectsState = liveFeedEffectsPresentation,
                    feed = zones.feed,
                    viewport = falseColorBounds,
                    // Portrait fill owns a persistent assist rail at the
                    // feed's leading edge. Seat the movable reference at the
                    // trailing edge by default so VIEW remains visible and
                    // tappable before the operator customises placement.
                    defaultHorizontalFraction = if (isPortraitFill) 1f else 0f,
                    panelLayout = analysisPanelLayout,
                    placementStore = analysisPanelPlacementStore,
                    placementRevision = analysisPanelPlacementRevision,
                    hapticsEnabled = operatorSettings.hapticsEnabled.value,
                )
            }
        }

        if (!isCommand && !isClean) {
            activeMonitorPicker?.let { picker ->
                val anchor =
                    if (zones.captureStrip != null) {
                        MonitorPickerAnchor.CAPTURE_STRIP
                    } else {
                        MonitorPickerAnchor.CONTROLS_GRID
                    }
                val pickerFrame =
                    monitorPickerFrame(
                        viewport = physicalViewport,
                        zones = zones,
                        isPortrait = isPortrait,
                        anchor = anchor,
                    )
                if (pickerFrame.width > 0f && pickerFrame.height >= 120f) {
                    CompositionLocalProvider(LocalMonitorGlass provides glass) {
                        MonitorControlPickerPanel(
                            picker = picker,
                            frame = pickerFrame,
                            controlsEnabled = commandControlsEnabled,
                            pendingControl = pendingCommandControl,
                            feedback = commandControlFeedback,
                            onSelect = applyCameraControl,
                            onDismiss = {
                                if (pendingCommandControl == null) {
                                    activeMonitorPickerKind = null
                                    commandControlFeedback = null
                                }
                            },
                        )
                    }
                }
            }
        }

        // Recording tally border at the physical edge (iOS `RecordingBorderModule`).
        if (recording) {
            Box(
                Modifier.fillMaxSize()
                    .border(4.dp, LiveDesign.rec, RoundedCornerShape(24.dp)),
            )
        }
        activeAssistOptions?.let { request ->
            val recenterPanel =
                request.tool.monitorAnalysisPanelID()?.takeIf { analysisPanelLayout != null }?.let { id ->
                    {
                        analysisPanelPlacementStore.recenter(id)
                        analysisPanelPlacementRevision += 1
                    }
                }
            CompositionLocalProvider(LocalMonitorGlass provides glass) {
                LiveAssistOptionsOverlay(
                    tool = request.tool,
                    anchorBounds = request.anchorBounds,
                    assistState = assist,
                    settings = operatorSettings,
                    cameraInput = exposureAssistCameraInput,
                    lutLibrary = lutLibrary,
                    onRecenterPanel = recenterPanel,
                    onDismiss = { activeAssistOptions = null },
                )
            }
        }
    }
    pendingRecordTarget?.let { target ->
        AlertDialog(
            onDismissRequest = { pendingRecordTarget = null },
            title = { Text(if (target) "Start recording?" else "Stop recording?") },
            text = {
                Text(
                    if (target) {
                        "The camera will begin recording."
                    } else {
                        "The camera will stop recording."
                    },
                )
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        pendingRecordTarget = null
                        if (recordControlEnabled && target != recording) {
                            sendRecordCommand(target)
                        }
                    },
                ) {
                    Text(if (target) "Start" else "Stop")
                }
            },
            dismissButton = {
                TextButton(onClick = { pendingRecordTarget = null }) { Text("Cancel") }
            },
        )
    }
    activeCommandControl?.let { request ->
        CommandControlDialog(
            request = request,
            controlsEnabled = commandControlsEnabled,
            pendingControl = pendingCommandControl,
            feedback = commandControlFeedback,
            onSelect = { label -> applyCameraControl(request, label) },
            onDismiss = { activeCommandControl = null },
        )
    }
}

/** The landscape top deck (iOS `MonitorInfoBar` `.infoPill`). */
@Composable
private fun InfoPill(
    compact: Boolean,
    recording: Boolean,
    timecode: LiveFrameTimecode?,
    recReadoutVisible: Boolean,
    codecReadoutVisible: Boolean,
    mediaReadoutVisible: Boolean,
    fpsReadoutVisible: Boolean,
    signalBars: Int,
    resolution: String,
    codec: String,
    media: String,
    fps: String,
) {
    Row(
        modifier = Modifier.glass(ChromeShape).padding(horizontal = 12.dp, vertical = 6.dp),
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (recReadoutVisible) RecordChip(recording)
        CameraTimecodeReadout(timecode = timecode, sizeSp = 20f, weight = FontWeight.Medium)
        if (!compact) {
            ReadoutPill(resolution) { VideoGlyph(LiveDesign.muted) }
            if (codecReadoutVisible) {
                ReadoutPill(codec) { FilmGlyph(LiveDesign.muted) }
            }
            if (mediaReadoutVisible) {
                ReadoutPill(media) { SdCardGlyph(LiveDesign.muted) }
            }
        }
        if (fpsReadoutVisible) {
            FpsChip(signalBars, fps)
        }
    }
}

/**
 * The portrait chrome tree, every region at its zone-map frame (iOS
 * `portraitShell`): full-width top bar, fit-mode assist toolbar + tile grid
 * (or the command timecode band + grid), stacked scopes (mounted by the
 * caller), the fill capture strip + vertical assist rail, and the bottom
 * system band.
 */
@Composable
private fun PortraitChrome(
    zones: MonitorZones,
    viewportHeight: Float,
    isCommand: Boolean,
    isFill: Boolean,
    locked: Boolean,
    recording: Boolean,
    timecode: LiveFrameTimecode?,
    cameraReadouts: MonitorCameraReadouts,
    assist: AssistState,
    operatorSettings: OperatorSettings,
    commandPresentation: CommandDashboardPresentation,
    captureSettings: List<MonitorCaptureSettingPresentation>,
    activeMonitorPicker: MonitorPickerKind?,
    commandControlsEnabled: Boolean,
    pendingCommandControl: CameraControl?,
    displayMode: MonitorDisplayMode,
    enabledDisplayModeOrder: List<MonitorDisplayMode>,
    onLock: () -> Unit,
    recordEnabled: Boolean,
    onRecord: () -> Unit,
    onDisp: () -> Unit,
    onOpenMedia: () -> Unit,
    onOpenSettings: () -> Unit,
    onOpenMonitorPicker: (MonitorPickerKind) -> Unit,
    onOpenCommandControl: (CommandControlRequest) -> Unit,
    onMoveCommandTile: (CommandTileKind, Int) -> Unit,
    onReorderStarted: () -> Unit,
    onOpenAssistOptions: (AssistTool, Rect) -> Unit,
) {
    val context = LocalContext.current
    var railExpanded by remember { mutableStateOf(false) }
    LaunchedEffect(isFill, isCommand) {
        if (!isFill || isCommand) railExpanded = false
    }
    if (operatorSettings.statusBarVisible.value) {
        PortraitInfoBar(
            timecode = timecode,
            media = cameraReadouts.media,
            cameraBatteryPercent = cameraReadouts.batteryPercent,
            cameraExternalPower = cameraReadouts.externalPower,
            modifier = Modifier.zone(zones.infoBar),
        )
    }

    // Fit-mode horizontal assist toolbar between the scopes zone and the tile
    // grid (live only — the map emits the zone). 12/4dp insets float the
    // glass pill off the screen edges, like iOS.
    if (!isCommand && operatorSettings.assistToolbarVisible.value) {
        zones.assistStrip?.let { strip ->
            AssistToolbar(
                assist,
                Modifier.zone(
                    ZoneFrame(strip.x + 12f, strip.y + 4f, strip.width - 24f, strip.height - 8f),
                ).alpha(if (locked) 0.4f else 1f),
                visibleTools = operatorSettings.visibleAssistToolbarTools,
                framingConfiguration = operatorSettings.localFramingAssistConfiguration,
                onToggleFramingTool = operatorSettings::toggleLocalFramingTool,
                hapticsEnabled = operatorSettings.hapticsEnabled.value,
                enabled = !locked,
                maximumActiveScopes = 2,
                onScopeLimitReached = {
                    Toast.makeText(
                        context,
                        "2 scopes max in fit view. Close one or pinch to fill.",
                        Toast.LENGTH_SHORT,
                    ).show()
                },
                onLongPressToolAnchored = onOpenAssistOptions,
            )
        }
    }

    // Controls zone: fit-mode live tiles, or a command dashboard that keeps
    // the system rail fixed while its primary and secondary settings scroll.
    zones.controlsGrid?.takeIf { it.height > 0 }?.let { grid ->
        if (isCommand) {
            PortraitCommandDashboard(
                presentation = commandPresentation,
                timecode = timecode,
                controlsEnabled = commandControlsEnabled,
                pendingControl = pendingCommandControl,
                onOpenControl = onOpenCommandControl,
                onMoveTile = onMoveCommandTile,
                onReorderStarted = onReorderStarted,
                modifier =
                    Modifier.zone(grid)
                        .alpha(if (locked) 0.4f else 1f),
            )
        } else {
            CommandGrid(
                tiles = commandPresentation.tiles,
                controlsEnabled = commandControlsEnabled,
                pendingControl = pendingCommandControl,
                onOpenControl = { request ->
                    monitorPickerKindForRequest(captureSettings, request)
                        ?.let(onOpenMonitorPicker)
                        ?: onOpenCommandControl(request)
                },
                onMoveTile = onMoveCommandTile,
                onReorderStarted = onReorderStarted,
                modifier =
                    Modifier.zone(
                        ZoneFrame(
                            grid.x,
                            grid.y,
                            grid.width,
                            maxOf(0f, grid.height - 8f),
                        ),
                    )
                        .padding(horizontal = 12.dp)
                        .alpha(if (locked) 0.4f else 1f),
            )
        }
    }

    if (!isCommand && isFill && operatorSettings.cameraValuesVisible.value) {
        zones.captureStrip?.let { strip ->
            Box(
                Modifier.zone(strip).alpha(if (locked) 0.4f else 1f),
                contentAlignment = Alignment.Center,
            ) {
                FitScale(strip.width.dp) {
                    MonitorCaptureStrip(
                        settings = captureSettings,
                        activePicker = activeMonitorPicker,
                        controlsEnabled = commandControlsEnabled,
                        pendingControl = pendingCommandControl,
                        onOpenPicker = onOpenMonitorPicker,
                    )
                }
            }
        }
    }

    if (!isCommand && isFill && operatorSettings.assistToolbarVisible.value) {
        val railFrame =
            portraitFillAssistRailFrame(
                feed = zones.feed,
                captureStrip = zones.captureStrip.takeIf {
                    operatorSettings.cameraValuesVisible.value
                },
                expanded = railExpanded,
            )
        PortraitFillAssistRail(
            state = assist,
            expanded = railExpanded,
            onExpandedChange = { railExpanded = it },
            modifier = Modifier.zone(railFrame).alpha(if (locked) 0.4f else 1f),
            visibleTools = operatorSettings.visibleAssistToolbarTools,
            framingConfiguration = operatorSettings.localFramingAssistConfiguration,
            onToggleFramingTool = operatorSettings::toggleLocalFramingTool,
            hapticsEnabled = operatorSettings.hapticsEnabled.value,
            enabled = !locked,
            onLongPressToolAnchored = onOpenAssistOptions,
        )
    }

    // Opaque band behind the system controls through the physical bottom
    // edge, so the record button never floats on bare black (iOS R4).
    Box(
        Modifier.zone(
            ZoneFrame(
                zones.systemCluster.x,
                zones.systemCluster.y,
                zones.systemCluster.width,
                maxOf(0f, viewportHeight - zones.systemCluster.y),
            ),
        ).background(LiveDesign.glass),
    )

    // Bottom system band: equal gaps around natural control sizes (iOS
    // `PortraitSystemBar` uses equal spacers, not equal columns).
    Row(
        Modifier.zone(zones.systemCluster),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Spacer(Modifier.weight(1f))
        LockButton(locked, Modifier.size(40.dp), onClick = onLock)
        Spacer(Modifier.weight(1f))
        DispButton(
            activeIndex = enabledDisplayModeOrder.indexOf(displayMode),
            modeCount = enabledDisplayModeOrder.size,
            isLiveActive = displayMode == MonitorDisplayMode.LIVE,
            modifier = Modifier.size(width = 74.dp, height = 44.dp),
            onClick = onDisp,
        )
        Spacer(Modifier.weight(1f))
        RecordButton(
            recording = recording,
            modifier = Modifier.size(83.dp),
            enabled = recordEnabled,
            onClick = onRecord,
        )
        Spacer(Modifier.weight(1f))
        AuxCircleButton(Modifier.size(63.dp), onClick = onOpenMedia) { glyphModifier, tint ->
            MediaStackGlyph(tint, glyphModifier)
        }
        Spacer(Modifier.weight(1f))
        AuxCircleButton(Modifier.size(63.dp), onClick = onOpenSettings) { glyphModifier, tint ->
            GearGlyph(tint, glyphModifier)
        }
        Spacer(Modifier.weight(1f))
    }
}

/**
 * The portrait top bar (iOS `MonitorInfoBar` `.infoBar`): accent-frames
 * timecode leading, storage centered on the screen width, camera battery
 * inline trailing, on the plain glass band.
 */
@Composable
private fun PortraitInfoBar(
    timecode: LiveFrameTimecode?,
    media: String,
    cameraBatteryPercent: Int?,
    cameraExternalPower: Boolean?,
    modifier: Modifier = Modifier,
) {
    val cameraBattery =
        monitorBatteryPresentation(cameraBatteryPercent, cameraExternalPower)
    Box(modifier.background(LiveDesign.glass).padding(horizontal = 16.dp)) {
        Text(
            media,
            style = chromeStyle(13f, FontWeight.Medium),
            color = LiveDesign.muted,
            maxLines = 1,
            modifier = Modifier.align(Alignment.Center),
        )
        Row(Modifier.fillMaxSize(), verticalAlignment = Alignment.CenterVertically) {
            CameraTimecodeReadout(timecode = timecode, sizeSp = 15f)
            Spacer(Modifier.weight(1f))
            Row(
                horizontalArrangement = Arrangement.spacedBy(5.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                BatteryGlyph(
                    cameraBattery.percent,
                    if (cameraBattery.percent == null && !cameraBattery.externalPower) {
                        LiveDesign.faint
                    } else {
                        LiveDesign.accent
                    },
                    modifier = Modifier.size(22.dp, 11.dp),
                    externalPower = cameraBattery.externalPower,
                )
                Text(
                    cameraBattery.label,
                    style = chromeStyle(10.5f, FontWeight.Medium, mono = true),
                    color = LiveDesign.text.copy(alpha = 0.72f),
                )
                CameraGlyph(LiveDesign.muted, Modifier.size(15.dp, 12.dp))
            }
        }
    }
}

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
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.width
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
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
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
import androidx.compose.ui.platform.LocalResources
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.res.stringResource
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
import com.kyant.backdrop.backdrops.layerBackdrop
import com.kyant.backdrop.backdrops.rememberLayerBackdrop
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
import com.opencapture.openzcine.core.CameraPropertySnapshot
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
import com.opencapture.openzcine.settings.labelResource
import com.opencapture.openzcine.settings.OperatorSettings
import com.opencapture.openzcine.wear.AndroidWearPhoneRelay
import com.opencapture.openzcine.wear.WearRecordCommandSafety
import com.opencapture.openzcine.wear.androidWatchRelayState
import com.opencapture.openzcine.wear.executeWearRecordCommand
import com.opencapture.openzcine.wearrelay.WatchCommandResult
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import java.util.concurrent.atomic.AtomicBoolean

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

/** Settings-only affordance used when the landscape side rails are hidden. */
@Composable
internal fun LandscapeSettingsRecoveryButton(
    modifier: Modifier = Modifier,
    onOpenSettings: () -> Unit,
) {
    val description = stringResource(R.string.monitor_settings_recovery)
    AuxCircleButton(
        modifier.semantics {
            contentDescription = description
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

/** Seats fail-closed feed feedback below any status deck mounted over the live image. */
internal fun liveFeedColorNoticeTopInsetDp(
    feed: ZoneFrame,
    infoBar: ZoneFrame,
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
    frameSource: LiveFrameSource?,
    assist: AssistState,
    operatorSettings: OperatorSettings,
    lutLibrary: AndroidLutLibrary? = null,
    liveViewEnabled: Boolean = true,
    glassTierOverride: String? = null,
    mediaRemoteShutter: AndroidMediaRemoteShutter? = null,
    isMonitorFront: Boolean = true,
    sessionRecoveryEnabled: Boolean = true,
    linkHealth: AndroidLinkHealthMonitor? = null,
    activeTransportIsUsb: Boolean = false,
    isDemoSession: Boolean = false,
    liveViewGuideController: LiveViewGuideController? = null,
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
            is CameraSessionState.Connected -> stringResource(R.string.camera_connected)
            CameraSessionState.Connecting -> stringResource(R.string.camera_connecting)
            CameraSessionState.Disconnected -> stringResource(R.string.camera_disconnected)
        }
    val cameraProperties by session.cameraProperties.collectAsState()
    val propertyRefreshStatus by session.propertyRefreshStatus.collectAsState()
    val commandRoundTripMilliseconds by
        session.latestCommandRoundTripMilliseconds.collectAsState()
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
    MonitorSessionRecoveryEffect(session, enabled = sessionRecoveryEnabled)

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
    val liveViewGuideVisible =
        liveViewGuideController?.activeStep != null &&
            isMonitorFront &&
            effectiveDisplayMode == MonitorDisplayMode.LIVE &&
            !recording
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
        sessionState is CameraSessionState.Connected &&
            !recordCommandPending &&
            !liveViewGuideVisible
    val recordScope = rememberCoroutineScope()
    val guideNeedsRealFrame = liveViewGuideController?.needsRealDecodedFrame == true
    val latestGuideNeedsRealFrame = rememberUpdatedState(guideNeedsRealFrame)
    val guideFrameDispatchPending = remember(session) { AtomicBoolean(false) }
    val commandTileOrderStore = remember(appContext) { CommandTileOrderStore(appContext) }
    var commandTileOrder by remember(commandTileOrderStore) {
        mutableStateOf(commandTileOrderStore.load())
    }
    var activeCommandControl by remember { mutableStateOf<CommandControlRequest?>(null) }
    var activeMonitorPickerKind by remember { mutableStateOf<MonitorPickerKind?>(null) }
    var activeAssistOptions by remember { mutableStateOf<LiveAssistOptionsRequest?>(null) }
    // iOS pendingShutterLockState: optimistic lock UI until poll matches the write.
    var optimisticShutterLocked by remember { mutableStateOf<Boolean?>(null) }
    LaunchedEffect(liveViewGuideVisible) {
        if (liveViewGuideVisible) {
            activeCommandControl = null
            activeMonitorPickerKind = null
            activeAssistOptions = null
        }
    }
    val analysisPanelPlacementStore =
        remember(appContext) { MonitorAnalysisPanelPlacementStore(appContext) }
    var analysisPanelPlacementRevision by remember { mutableIntStateOf(0) }
    val analysisPanelFrames =
        remember { mutableStateMapOf<MonitorAnalysisPanelID, ZoneFrame>() }
    val onAnalysisPanelFrameChanged =
        remember(analysisPanelFrames) {
            { id: MonitorAnalysisPanelID, frame: ZoneFrame? ->
                if (frame == null) {
                    analysisPanelFrames.remove(id)
                } else {
                    analysisPanelFrames[id] = frame
                }
                Unit
            }
        }
    LiveAssistOptionsBackHandler(visible = activeAssistOptions != null) {
        activeAssistOptions = null
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
    // iOS `captureBarFrame`: measured glass pill so the exposure picker
    // trailing-aligns to the content-hugging bar (not the wider zone slot).
    var measuredCaptureBar by remember { mutableStateOf<ZoneFrame?>(null) }
    LaunchedEffect(effectiveDisplayMode) {
        if (displayMode != effectiveDisplayMode) displayMode = effectiveDisplayMode
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
    val commandPresentation =
        remember(
            cameraProperties,
            propertyRefreshStatus,
            sessionState,
            commandTileOrder,
            recording,
            stringResolver,
        ) {
            commandDashboardPresentation(
                snapshot = cameraProperties,
                refreshStatus = propertyRefreshStatus,
                sessionState = sessionState,
                tileOrder = commandTileOrder,
                strings = stringResolver,
                recording = recording,
            )
        }
    val captureSettings =
        remember(commandPresentation, stringResolver, effectiveShutterLocked) {
            monitorCaptureSettings(
                commandPresentation,
                stringResolver,
                shutterLockedOnCamera = effectiveShutterLocked,
            )
        }
    val topPillPickers =
        remember(commandPresentation, stringResolver) {
            monitorTopPillPickers(commandPresentation, stringResolver)
        }
    val activeMonitorPicker =
        captureSettings.firstOrNull { it.kind == activeMonitorPickerKind }?.picker
            ?: activeMonitorPickerKind?.let(topPillPickers::get)
    val mediaOwnsCommandChannel =
        (propertyRefreshStatus as? CameraPropertyRefreshStatus.Degraded)?.failure ==
            CameraPropertyRefreshFailure.MEDIA_BUSY
    val commandControlsEnabled =
        sessionState is CameraSessionState.Connected &&
            !locked &&
            !liveViewGuideVisible &&
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
                        session.applyControl(control, desiredLabel)
                        // Property poll will also catch up; one refresh keeps tiles/bar honest
                        // after the native confirm without freezing the drum (settles still
                        // enqueue into desiredControlWrites while this runs).
                        session.refreshProperties()
                        val confirmed =
                            cameraPropertyConfirmsSelection(
                                session.cameraProperties.value,
                                control,
                                desiredLabel,
                            )
                        // Only surface failures. iOS does not flash "set to …" on every snap.
                        if (!confirmed && desiredControlWrites[control] == null) {
                            commandControlFeedback =
                                CommandControlFeedback(
                                    appContext.getString(
                                        R.string.control_confirmation_failed,
                                        req.title,
                                        desiredLabel,
                                    ),
                                    isError = true,
                                )
                        }
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
            desiredControlWrites[request.control] = request to label
            commandControlFeedback = null
            if (activeCommandControl?.control == request.control) {
                activeCommandControl = request.copy(currentValue = label)
            }
            drainCameraControlWrites()
        }
    // iOS shutter long-press (strip cell + open picker panel): toggle MovieTVLock.
    val shutterHapticView = LocalView.current
    val shutterLongPressToggle: () -> Unit = {
        if (operatorSettings.hapticsEnabled.value) {
            shutterHapticView.performHapticFeedback(HapticFeedbackConstants.LONG_PRESS)
        }
        toggleShutterLockOnCamera(
            captureSettings = captureSettings,
            cameraProperties = cameraProperties,
            applyCameraControl = applyCameraControl,
            onOptimisticShutterLocked = { optimisticShutterLocked = it },
            shutterLockedOverride = effectiveShutterLocked,
        )
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
                        monitorFront = isMonitorFront && !liveViewGuideVisible,
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
            monitorIsFront = isMonitorFront && !liveViewGuideVisible,
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
            activeMonitorPickerKind,
        ) {
            val kind = activeMonitorPickerKind ?: return@LaunchedEffect
            val topBar =
                kind == MonitorPickerKind.RESOLUTION || kind == MonitorPickerKind.CODEC
            if (
                !retainMonitorPickerForChrome(
                    mode = effectiveDisplayMode,
                    cameraValuesVisible = cameraValuesVisible,
                    cameraCommandPending = pendingCommandControl != null,
                    isTopBarPicker = topBar,
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
        val liveFeedColorNoticeTopInset =
            liveFeedColorNoticeTopInsetDp(
                feed = zones.feed,
                infoBar = zones.infoBar,
                statusBarVisible = operatorSettings.statusBarVisible.value,
            )
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
        // Do not read timecodeRetention here — that recomposes the whole monitor
        // chrome at feed rate. Leaf RetainedCameraTimecodeReadout observes it.
        // iOS top-bar semantics: readouts seed from the preview values and
        // hold the last camera readback rather than blanking to "—"; FPS is
        // the live-measured delivery rate ("READY" before the first frame);
        // the media cell cycles capacity <-> estimated minutes.
        val readoutRetention =
            remember(session, timecodeOwner) { MonitorReadoutRetention(timecodeOwner) }
        LaunchedEffect(cameraProperties) { readoutRetention.update(cameraProperties) }
        val fpsSampler = remember(session, timecodeOwner) { MonitorFrameRateSampler() }
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
                liveViewGuideVisible,
                lifecycleState,
                monitorFrameSource,
            ) {
                androidWatchRelayState(
                    sessionState = sessionState,
                    cameraProperties = cameraProperties,
                    isRecording = recording,
                    monitorFront = isMonitorFront && !liveViewGuideVisible,
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
        LaunchedEffect(actualLinkHealth, commandRoundTripMilliseconds) {
            actualLinkHealth.reportRoundTripMilliseconds(commandRoundTripMilliseconds)
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
                interfaceLocked = locked || liveViewGuideVisible,
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
        val focusResetVisible =
            focusResetAvailable(feedFocus, focusPointLocked) &&
                sessionState is CameraSessionState.Connected &&
                !locked &&
                !mediaOwnsCommandChannel &&
                !otherCameraCommandPending
        val requestFocusReset: () -> Unit = resetFocusPoint@{
            if (focusCommandPending) return@resetFocusPoint
            focusResetPending = true
            recordScope.launch {
                try {
                    session.resetFocusPoint()
                    if (operatorSettings.hapticsEnabled.value) {
                        view.performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP)
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
        Box(Modifier.fillMaxSize().then(sceneLayer)) {
        if (!isCommand) {
            Box(
                Modifier.zone(zones.feed)
                    // Feed-only recording for bar/chip glass (over the video).
                    .then(
                        if (glass.tier == GlassTier.FULL && glass.layerBackdrop != null) {
                            Modifier.layerBackdrop(glass.layerBackdrop)
                        } else {
                            Modifier
                        },
                    )
                    .clipToBounds()
                    .onSizeChanged { feedPointerSize = it }
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
                        onPresentedFrame = { frame, bitmap, baker ->
                            timecodeRetention.accept(frame.timecode)
                            fpsSampler.accept(System.nanoTime())
                            wearRelay.ingestPresentedFrame(frame, bitmap, baker)
                            val isRealCameraFrame =
                                realDecodedFrameCanTriggerGuide(
                                    isDemoSession = isDemoSession,
                                    hasExplicitFrameSource = frameSource != null,
                                    monitorUsesSwiftCameraSource =
                                        monitorFrameSource === swiftLiveFrameSource,
                                    cameraConnected =
                                        sessionState is CameraSessionState.Connected,
                                )
                            if (isRealCameraFrame &&
                                latestGuideNeedsRealFrame.value &&
                                guideFrameDispatchPending.compareAndSet(false, true)
                            ) {
                                recordScope.launch {
                                    try {
                                        if (liveViewGuideController?.needsRealDecodedFrame == true) {
                                            liveViewGuideController.onRealDecodedFrame()
                                        }
                                    } finally {
                                        guideFrameDispatchPending.set(false)
                                    }
                                }
                            }
                        },
                        presentationState = liveFeedPresentation,
                        effects = assist.effects,
                        configuration = operatorSettings.feedEffectsConfiguration,
                        cameraInput = exposureAssistCameraInput,
                        lutLibrary = lutLibrary,
                        effectsPresentationState = liveFeedEffectsPresentation,
                        aspectFill = isPortraitFill,
                        // SurfaceView graded feed is invisible to Kyant
                        // layerBackdrop — FULL glass must present via Compose.
                        preferComposablePresentation = glass.tier == GlassTier.FULL,
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
                                CameraSessionState.Connecting ->
                                    stringResource(R.string.camera_connecting_short)
                                CameraSessionState.Disconnected ->
                                    stringResource(R.string.camera_none)
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
                LiveFeedColorModeNotice(
                    colorMode = liveFeedPresentation.colorMode,
                    effectsActive = !assist.effects.isIdentity,
                    modifier =
                        Modifier.align(Alignment.TopCenter)
                            .padding(top = liveFeedColorNoticeTopInset.dp),
                )
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
                    timecodeRetention = timecodeRetention,
                    sessionState = sessionState,
                    // iOS portrait centers the same toggle-aware, retention-held
                    // media readout the landscape pill shows.
                    cameraReadouts = cameraReadouts.copy(media = topBarMedia),
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
                    resolutionPickerAvailable = MonitorPickerKind.RESOLUTION in topPillPickers,
                    codecPickerAvailable = MonitorPickerKind.CODEC in topPillPickers,
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
                    onShutterLongPress = shutterLongPressToggle,
                    onCaptureBarBounds = { measuredCaptureBar = it },
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
                        timecodeRetention = timecodeRetention,
                        sessionState = sessionState,
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
                                    timecodeRetention = timecodeRetention,
                                    sessionState = sessionState,
                                    recReadoutVisible = operatorSettings.recReadoutVisible.value,
                                    codecReadoutVisible = operatorSettings.codecReadoutVisible.value,
                                    mediaReadoutVisible = operatorSettings.mediaReadoutVisible.value,
                                    fpsReadoutVisible = operatorSettings.fpsReadoutVisible.value,
                                    signalBars = actualLinkHealth.presentation.signalBars,
                                    resolution = readoutRetention.resolution,
                                    codec = readoutRetention.codec,
                                    media = topBarMedia,
                                    fps = fpsSampler.formatted,
                                    activePicker = activeMonitorPickerKind,
                                    resolutionPickerAvailable =
                                        MonitorPickerKind.RESOLUTION in topPillPickers,
                                    codecPickerAvailable =
                                        MonitorPickerKind.CODEC in topPillPickers,
                                    pickersEnabled =
                                        commandControlsEnabled && pendingCommandControl == null,
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
                                    onToggleMediaReadout = {
                                        prefersMediaDuration = !prefersMediaDuration
                                    },
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
                                        onShutterLongPress = shutterLongPressToggle,
                                        onBarBoundsInRoot = { measuredCaptureBar = it },
                                        maxContentWidth = strip.width.dp,
                                    )
                                }
                            }
                        }
                    }
                }

                if (railPlan.fullRailsVisible) {
                    // Persistent side rails: lock + authoritative batteries +
                    // record / configured DISP / media / settings.
                    LockButton(locked, Modifier.zone(zones.lock)) { locked = !locked }
                    // Like iOS hugging the Dynamic Island, the two battery
                    // indicators cluster around the punch-hole camera when the
                    // display cutout sits in the leading lane (camera battery
                    // above the cutout, phone below); zone-map frames are the
                    // fallback on cutout-less hardware.
                    val batteryView = LocalView.current
                    val batteryDensity = LocalDensity.current
                    val cutoutCenterY =
                        remember(batteryView, isPortrait, zones) {
                            if (isPortrait) {
                                null
                            } else {
                                batteryView.rootWindowInsets
                                    ?.displayCutout
                                    ?.boundingRects
                                    ?.minByOrNull { it.left }
                                    ?.takeIf { it.left.toFloat() < zones.feed.width / 2f }
                                    ?.exactCenterY()
                                    ?.div(batteryDensity.density)
                            }
                        }
                    val (phoneBatteryFrame, cameraBatteryFrame) =
                        cutoutHuggedBatteryFrames(
                            phone = zones.batteryPhone,
                            camera = zones.batteryCamera,
                            cutoutCenterY = cutoutCenterY,
                            bounds = zones.feed,
                        )
                    phoneBatteryFrame?.let {
                        BatteryIndicatorColumn(
                            percent = phoneBatteryReadout.percent,
                            isCamera = false,
                            modifier = Modifier.zone(it),
                            externalPower = phoneBatteryReadout.externalPower,
                        )
                    }
                    cameraBatteryFrame?.let {
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
                onPanelFrameChanged = onAnalysisPanelFrameChanged,
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
                    onPanelFrameChanged = onAnalysisPanelFrameChanged,
                )
            }
        }

        // Keep the reset affordance above every movable scope/reference panel. The pure placement
        // policy mirrors iOS and this later composition order remains reachable even if a viewport
        // is too crowded to provide a geometrically clear slot.
        if (focusResetVisible) {
            val bottomChromeInset =
                with(density) { levelGaugeBottomChromeInset.toDp().value }
            val baseFrame =
                focusResetButtonBaseFrame(
                    feed = zones.feed,
                    isPortrait = isPortrait,
                    bottomChromeInset = bottomChromeInset,
                )
            val resetFrame =
                focusResetButtonClearFrame(
                    base = baseFrame,
                    panelFrames = analysisPanelFrames.values,
                    bounds = zones.feed,
                )
            val resetDescription =
                stringResource(
                    when {
                        focusResetPending -> R.string.focus_resetting
                        focusMoveRequestsInFlight > 0 -> R.string.focus_reset_moving
                        else -> R.string.focus_reset
                    },
                )
            IconButton(
                onClick = requestFocusReset,
                enabled = !focusCommandPending,
                modifier =
                    Modifier
                        .zone(resetFrame)
                        .background(Color.Black.copy(alpha = 0.55f), CircleShape)
                        .testTag("focus_reset_button")
                        .semantics {
                            contentDescription = resetDescription
                        },
            ) {
                if (focusResetPending) {
                    Text(
                        text = "…",
                        style = chromeStyle(18f, FontWeight.SemiBold),
                        color = LiveDesign.text,
                    )
                } else {
                    // iOS uses `dot.viewfinder` in a 40pt black circle.
                    DotViewfinderGlyph(
                        LiveDesign.text,
                        Modifier.size(17.dp),
                    )
                }
            }
        }
        } // end sceneLayer (feed + chrome under popups)

        if (!isCommand && !isClean) {
            activeMonitorPicker?.let { picker ->
                // iOS: resolution/codec drop *down* from the top deck on landscape;
                // every other picker (and all portrait pickers) rise from the capture strip.
                val isTopDropDown =
                    !isPortrait && picker.kind.isTopBarPicker()
                val pickerFrame =
                    if (isTopDropDown) {
                        monitorTopBarPickerFrame(
                            viewport = physicalViewport,
                            zones = zones,
                            isCommandCenter = false,
                        )
                    } else {
                        val anchor =
                            if (zones.captureStrip != null) {
                                MonitorPickerAnchor.CAPTURE_STRIP
                            } else {
                                MonitorPickerAnchor.CONTROLS_GRID
                            }
                        monitorPickerFrame(
                            viewport = physicalViewport,
                            zones = zones,
                            isPortrait = isPortrait,
                            anchor = anchor,
                            measuredCaptureBar = measuredCaptureBar,
                        )
                    }
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
                            slideFromTop = isTopDropDown,
                            onShutterLongPress = shutterLongPressToggle,
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
        if (liveViewGuideVisible) {
            val guideController = requireNotNull(liveViewGuideController)
            val guideAssistTarget =
                if (isPortraitFill) {
                    portraitFillAssistRailFrame(
                        feed = zones.feed,
                        captureStrip = zones.captureStrip.takeIf { cameraValuesVisible },
                        expanded = false,
                    )
                } else {
                    zones.assistStrip
                }
            LiveViewGuideOverlay(
                controller = guideController,
                zones = zones,
                isPortrait = isPortrait,
                usesVerticalAssistRail = isPortraitFill,
                assistTarget = guideAssistTarget,
            )
        }
    }
    pendingRecordTarget?.let { target ->
        AlertDialog(
            onDismissRequest = { pendingRecordTarget = null },
            title = {
                Text(
                    stringResource(
                        if (target) R.string.record_start_title else R.string.record_stop_title,
                    ),
                )
            },
            text = {
                Text(
                    stringResource(
                        if (target) R.string.record_start_message else R.string.record_stop_message,
                    ),
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
                    Text(stringResource(if (target) R.string.action_start else R.string.action_stop))
                }
            },
            dismissButton = {
                TextButton(onClick = { pendingRecordTarget = null }) {
                    Text(stringResource(R.string.action_cancel))
                }
            },
        )
    }
    activeCommandControl?.let { request ->
        CompositionLocalProvider(LocalMonitorGlass provides glass) {
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
}

/**
 * iOS `PortraitRecOptionsButton` menu: a compact glass popover (not a Material
 * dropdown) anchored under the button, with 14sp medium items and a hairline
 * divider, each routing straight into the resolution/codec pickers.
 */
@Composable
private fun RecOptionsPopover(
    expanded: Boolean,
    onDismiss: () -> Unit,
    resolutionAvailable: Boolean,
    codecAvailable: Boolean,
    onResolution: () -> Unit,
    onCodec: () -> Unit,
) {
    if (!expanded) return
    androidx.compose.ui.window.Popup(
        alignment = Alignment.TopEnd,
        offset = androidx.compose.ui.unit.IntOffset(0, with(LocalDensity.current) { 46.dp.roundToPx() }),
        onDismissRequest = onDismiss,
        properties = androidx.compose.ui.window.PopupProperties(focusable = true),
    ) {
        Column(
            Modifier.width(220.dp)
                .glass(ChromeShape)
                .border(1.dp, LiveDesign.hairline, ChromeShape),
        ) {
            if (resolutionAvailable) {
                RecOptionItem(stringResource(R.string.rec_option_resolution)) {
                    onDismiss()
                    onResolution()
                }
            }
            if (resolutionAvailable && codecAvailable) {
                Box(Modifier.fillMaxWidth().height(1.dp).background(LiveDesign.hairline))
            }
            if (codecAvailable) {
                RecOptionItem(stringResource(R.string.rec_option_codec)) {
                    onDismiss()
                    onCodec()
                }
            }
        }
    }
}

/** One iOS rec-options menu row: 14sp medium text, generous padding. */
@Composable
private fun RecOptionItem(text: String, onClick: () -> Unit) {
    Text(
        text,
        style = chromeStyle(14f, FontWeight.Medium),
        color = LiveDesign.text,
        modifier =
            Modifier.fillMaxWidth()
                .chromeClickable(onClick)
                .padding(horizontal = 14.dp, vertical = 12.dp),
    )
}

/** The landscape top deck (iOS `MonitorInfoBar` `.infoPill`). */
@Composable
private fun InfoPill(
    compact: Boolean,
    recording: Boolean,
    timecodeRetention: MonitorTimecodeRetention,
    sessionState: CameraSessionState,
    recReadoutVisible: Boolean,
    codecReadoutVisible: Boolean,
    mediaReadoutVisible: Boolean,
    fpsReadoutVisible: Boolean,
    signalBars: Int,
    resolution: String,
    codec: String,
    media: String,
    fps: String,
    activePicker: MonitorPickerKind? = null,
    resolutionPickerAvailable: Boolean = false,
    codecPickerAvailable: Boolean = false,
    pickersEnabled: Boolean = false,
    onOpenPicker: (MonitorPickerKind) -> Unit = {},
    onToggleMediaReadout: (() -> Unit)? = null,
) {
    Row(
        modifier = Modifier.glass(ChromeShape).padding(horizontal = 12.dp, vertical = 6.dp),
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (recReadoutVisible) RecordChip(recording)
        RetainedCameraTimecodeReadout(
            retention = timecodeRetention,
            sessionState = sessionState,
            sizeSp = 20f,
            weight = FontWeight.Medium,
        )
        if (!compact) {
            // Resolution/codec readouts are ALWAYS buttons like iOS's top-bar
            // readout buttons — press feedback included. The tap no-ops only
            // while locked / command-gated (`pickersEnabled`), matching iOS
            // `interfaceLocked`. Option lists come from camera descriptors or
            // the same static fallbacks iOS uses when descriptors are empty.
            ReadoutPill(
                resolution,
                active = activePicker == MonitorPickerKind.RESOLUTION,
                onClick = {
                    if (pickersEnabled) onOpenPicker(MonitorPickerKind.RESOLUTION)
                },
            ) { tint ->
                VideoGlyph(tint)
            }
            if (codecReadoutVisible) {
                ReadoutPill(
                    codec,
                    active = activePicker == MonitorPickerKind.CODEC,
                    onClick = {
                        if (pickersEnabled) onOpenPicker(MonitorPickerKind.CODEC)
                    },
                ) { tint ->
                    FilmGlyph(tint)
                }
            }
            if (mediaReadoutVisible) {
                // iOS media cell: tap cycles capacity <-> remaining minutes;
                // deliberately NOT lock-gated (it is a readout mode, not a
                // camera command).
                ReadoutPill(media, onClick = onToggleMediaReadout) { tint ->
                    SdCardGlyph(tint)
                }
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
    timecodeRetention: MonitorTimecodeRetention,
    sessionState: CameraSessionState,
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
    onShutterLongPress: (() -> Unit)? = null,
    onCaptureBarBounds: ((ZoneFrame) -> Unit)? = null,
    resolutionPickerAvailable: Boolean = false,
    codecPickerAvailable: Boolean = false,
    onOpenCommandControl: (CommandControlRequest) -> Unit,
    onMoveCommandTile: (CommandTileKind, Int) -> Unit,
    onReorderStarted: () -> Unit,
    onOpenAssistOptions: (AssistTool, Rect) -> Unit,
) {
    val context = LocalContext.current
    val scopeLimitMessage = stringResource(R.string.scope_fit_limit)
    var railExpanded by remember { mutableStateOf(false) }
    LaunchedEffect(isFill, isCommand) {
        if (!isFill || isCommand) railExpanded = false
    }
    // iOS mounts the portrait info bar unconditionally — it shows in live,
    // clean, AND command portrait, independent of the status-bar toggle
    // (which governs only the landscape pill).
    run {
        PortraitInfoBar(
            timecodeRetention = timecodeRetention,
            sessionState = sessionState,
            media = cameraReadouts.media,
            cameraBatteryPercent = cameraReadouts.batteryPercent,
            cameraExternalPower = cameraReadouts.externalPower,
            modifier = Modifier.zone(zones.infoBar),
        )
    }

    // REC-options button (iOS PortraitRecOptionsButton): a glass circle at the
    // feed's top-trailing corner, under the top bar. iOS always mounts it in
    // non-command portrait (dimmed while locked) and always offers both menu
    // rows; showPicker itself no-ops while locked.
    if (!isCommand) {
        var recOptionsExpanded by remember { mutableStateOf(false) }
        val recOptionsFrame =
            ZoneFrame(
                x = zones.feed.x + zones.feed.width - 44f - 10f,
                y = zones.infoBar.y + zones.infoBar.height + 10f,
                width = 44f,
                height = 44f,
            )
        Box(Modifier.zone(recOptionsFrame).alpha(if (locked) 0.4f else 1f)) {
            AuxCircleButton(
                Modifier.fillMaxSize(),
                onClick = { recOptionsExpanded = true },
            ) { glyphModifier, tint ->
                VideoGlyph(tint, glyphModifier)
            }
            RecOptionsPopover(
                expanded = recOptionsExpanded,
                onDismiss = { recOptionsExpanded = false },
                resolutionAvailable = true,
                codecAvailable = true,
                onResolution = { onOpenMonitorPicker(MonitorPickerKind.RESOLUTION) },
                onCodec = { onOpenMonitorPicker(MonitorPickerKind.CODEC) },
            )
        }
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
                        scopeLimitMessage,
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
                timecodeRetention = timecodeRetention,
                sessionState = sessionState,
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
                MonitorCaptureStrip(
                    settings = captureSettings,
                    activePicker = activeMonitorPicker,
                    controlsEnabled = commandControlsEnabled,
                    pendingControl = pendingCommandControl,
                    onOpenPicker = onOpenMonitorPicker,
                    onShutterLongPress = onShutterLongPress,
                    onBarBoundsInRoot = onCaptureBarBounds,
                    maxContentWidth = strip.width.dp,
                )
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
    timecodeRetention: MonitorTimecodeRetention,
    sessionState: CameraSessionState,
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
            RetainedCameraTimecodeReadout(
                retention = timecodeRetention,
                sessionState = sessionState,
                sizeSp = 15f,
            )
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

/** Canvas stand-in for SF `dot.viewfinder` (the focus-reset affordance). */
@Composable
private fun DotViewfinderGlyph(
    tint: androidx.compose.ui.graphics.Color,
    modifier: Modifier = Modifier,
) {
    androidx.compose.foundation.Canvas(modifier) {
        val stroke = size.minDimension * 0.09f
        val corner = size.minDimension * 0.26f
        // Center dot.
        drawCircle(tint, radius = size.minDimension * 0.14f, center = center)
        // Four open viewfinder corners.
        val w = size.width
        val h = size.height
        fun cornerPath(
            startX: Float, startY: Float, midX: Float, midY: Float, endX: Float, endY: Float,
        ) {
            val path = androidx.compose.ui.graphics.Path().apply {
                moveTo(startX, startY)
                lineTo(midX, midY)
                lineTo(endX, endY)
            }
            drawPath(
                path,
                tint,
                style =
                    androidx.compose.ui.graphics.drawscope.Stroke(
                        width = stroke,
                        cap = androidx.compose.ui.graphics.StrokeCap.Round,
                    ),
            )
        }
        cornerPath(corner, 0f, 0f, 0f, 0f, corner)
        cornerPath(w - corner, 0f, w, 0f, w, corner)
        cornerPath(w, h - corner, w, h, w - corner, h)
        cornerPath(corner, h, 0f, h, 0f, h - corner)
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
 * Clusters the landscape battery indicators around the display cutout —
 * phone battery above, camera battery below, mirroring how iOS flanks the
 * Dynamic Island. Returns the zone-map frames untouched when there is no
 * usable cutout or the hugged frames would leave the feed bounds.
 */
internal fun cutoutHuggedBatteryFrames(
    phone: ZoneFrame?,
    camera: ZoneFrame?,
    cutoutCenterY: Float?,
    bounds: ZoneFrame,
): Pair<ZoneFrame?, ZoneFrame?> {
    if (phone == null || camera == null || cutoutCenterY == null) return phone to camera
    val gap = 28f
    val phoneFrame = phone.copy(y = cutoutCenterY - gap / 2f - phone.height)
    val cameraFrame = camera.copy(y = cutoutCenterY + gap / 2f)
    val top = bounds.y
    val bottom = bounds.y + bounds.height
    if (phoneFrame.y < top || cameraFrame.y + cameraFrame.height > bottom) {
        return phone to camera
    }
    return phoneFrame to cameraFrame
}

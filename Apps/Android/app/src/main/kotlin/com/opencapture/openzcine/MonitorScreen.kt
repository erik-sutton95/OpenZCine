package com.opencapture.openzcine

import android.view.HapticFeedbackConstants
import android.widget.Toast
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
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
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.IconButton
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Visibility
import androidx.compose.material.icons.filled.VisibilityOff
import androidx.compose.material3.Icon
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
import androidx.compose.runtime.snapshotFlow
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Rect
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
import com.opencapture.openzcine.core.CameraSessionEvent
import com.opencapture.openzcine.core.CameraStorageStatus
import com.opencapture.openzcine.diagnostics.AndroidDiagnosticEvent
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
import com.opencapture.openzcine.core.LiveFeedRotation
import com.opencapture.openzcine.core.LiveFrameSource
import com.opencapture.openzcine.core.LiveFrameTimecode
import com.opencapture.openzcine.core.MonitorDataAvailability
import com.opencapture.openzcine.relay.MonitorRelayWire
import com.opencapture.openzcine.lut.AndroidLutLibrary
import com.opencapture.openzcine.media.LiveAssistOptionsOverlay
import com.opencapture.openzcine.media.retainLiveAssistOptions
import com.opencapture.openzcine.remote.AndroidMediaRemoteShutter
import com.opencapture.openzcine.remote.MediaRemoteShutterCommand
import com.opencapture.openzcine.remote.routeMediaRemoteShutterCommand
import com.opencapture.openzcine.remote.shouldArmMediaRemoteShutter
import com.opencapture.openzcine.settings.CaptureLayoutMode
import com.opencapture.openzcine.settings.ChromeSection
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

/** The on-feed 50/50 quick key, matching the iOS pill. */
private const val SPLIT_KEY_WIDTH_DP = 44f
private const val SPLIT_KEY_HEIGHT_DP = 30f

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
    liveViewGuideController: LiveViewGuideController? = null,
    onOpenSettings: () -> Unit = {},
    onOpenMedia: () -> Unit = {},
    /** Leaves the held frame for the saved-camera home after a session drop. */
    onBackToOperatorMenu: () -> Unit = {},
    /** Debug-only staged recovery state for screenshot verification (`DemoHarness`). */
    recoveryStateOverride: MonitorRecoveryState? = null,
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
        (session as? SwiftCoreCameraSession)?.liveFrames as? com.opencapture.openzcine.bridge.SwiftCoreLiveFrameSource
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
        remember(session) { mutableStateOf<MonitorRecoveryState>(MonitorRecoveryState.Idle) }
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
    var displayMode by remember { mutableStateOf(MonitorDisplayMode.LIVE) }
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
    var locked by remember { mutableStateOf(false) }
    // Photography's lock-side vertical assist rail (iOS `photoRailExpanded`).
    var photoRailExpanded by remember { mutableStateOf(true) }
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
    // iOS `isRedDownloadPresented` — full-screen RED IPP2 download cover.
    var redDownloadPresented by remember { mutableStateOf(false) }
    // iOS pendingShutterLockState: optimistic lock UI until poll matches the write.
    var optimisticShutterLocked by remember { mutableStateOf<Boolean?>(null) }
    LaunchedEffect(liveViewGuideVisible) {
        if (liveViewGuideVisible) {
            activeCommandControl = null
            activeMonitorPickerKind = null
            activeAssistOptions = null
        }
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
            activeAssistOptions = null
            // Photography has no command dashboard — flipping to photo while
            // it is up snaps back to live (iOS flip handler).
            if (
                prefersPhotographyChrome(cameraProperties) &&
                displayMode == MonitorDisplayMode.COMMAND
            ) {
                displayMode = MonitorDisplayMode.LIVE
            }
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
    // iOS `topBarPickerFrames`: measured deck pills so a popdown centres under
    // its own cell rather than the info bar's midpoint.
    val measuredTopPills = remember { mutableStateMapOf<MonitorPickerKind, ZoneFrame>() }
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
            !liveViewGuideVisible &&
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
                        session.applyControl(control, desiredLabel)
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
    LaunchedEffect(sessionState, isPhotographyMode, assist.instantReviewEnabled) {
        if (
            sessionState is CameraSessionState.Connected &&
            isPhotographyMode &&
            assist.instantReviewEnabled
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
                    instantReviewEnabled = assist.instantReviewEnabled,
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
            enabled = isPhotographyMode && assist.instantReviewEnabled,
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
        val isVerticalFeed = liveFeedRotation.isVertical
        val portraitAspect = operatorSettings.portraitFeedAspect
        // Zone/chrome layout: vertical mode always lays out as FILL, matching iOS — the fill
        // zones are exactly the vertical viewer (feed spanning the bands, floating assist rail,
        // capture bar over the feed bottom); fit's stacked bands would strand the controls.
        val isPortraitFill =
            isPortrait && !isCommand && !isPhotographyMode &&
                (isVerticalFeed || portraitAspect.fillsViewport)
        // Raster/overlay fit: the rotated 9:16 picture pillarboxes inside the fill frame —
        // aspect-filling it would centre-crop the top and bottom of the vertical shot.
        val portraitRasterFill = isPortraitFill && !isVerticalFeed

        // One authoritative mode filter, mirroring core `MonitorChromePolicy`: clean (DISP 2) is a
        // bare image unless the operator pinned a tool to it, and it strips the deck/rails/bands
        // as well (#256).
        val cleanViewPins = operatorSettings.cleanViewPinnedTools
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
        val chromeEditBoxes = remember { mutableStateMapOf<ChromeSection, Rect>() }
        val recordChromeEditBounds: (ChromeSection, Rect) -> Unit = { section, rect ->
            chromeEditBoxes[section] = rect
        }
        LaunchedEffect(chromeEditorMode) {
            // Editing a mode means looking at it.
            chromeEditorMode?.let { displayMode = it }
        }
        val visibleAssistTools = operatorSettings.visibleAssistToolbarTools
        val openAssistOptions: (AssistTool, Rect) -> Unit = { tool, anchor ->
            // Clean view defers transient pop-ups (#256) — the toolbar that opens them is hidden
            // there anyway, so this only catches a stray remote/hardware route.
            if (!locked && monitorAllowsPopups(effectiveDisplayMode)) {
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
            val topBar = kind.isTopBarPicker()
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
                // Photography suppresses the cinema-only scopes at render, so the
                // zone must bill only the photography-visible ones (just the
                // histogram) — a band sized to the full set opens a dead gap
                // between feed and toolbar (iOS
                // `displayedFitScopes.filter(appliesToPhotography)`).
                assist.displayedPortraitScopes.let { scopes ->
                    if (isPhotographyMode) scopes.filter { it.appliesToPhotography } else scopes
                }
            } else {
                emptyList()
            }
        val scopeCount = portraitScopes.size
        // Photography passes its still image-area ratio (3:2/1:1/16:9) so the
        // portrait fit feed renders whole under the top bar; video keeps 16:9.
        // A vertically held body inverts the displayed ratio (shared core clamps
        // the resulting tall feed above the stacked bands).
        val portraitFeedAspectRatio =
            (if (isPhotographyMode) photographyFeedAspect(cameraProperties.imageArea) else 16f / 9f)
                .let { if (isVerticalFeed) 1f / it else it }
        val zones =
            remember(
                viewportWidth, viewportHeight, safeTop, safeLeading, safeBottom, safeTrailing,
                isPortrait, effectiveDisplayMode, isPortraitFill, scopeCount, bottomBarHeight,
                portraitFeedAspectRatio,
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
                        portraitFeedAspectRatio = portraitFeedAspectRatio,
                    ),
                )
            }
        // Local framing is deliberately read from the operator store rather
        // than the camera session: grid/crosshair/guides are composited over
        // the existing feed zone and never alter the Nikon Grid Display.
        val localFraming = operatorSettings.localFramingAssistConfiguration
        // What the feed overlays actually draw: the operator's framing config with the tools this
        // DISP mode suppresses switched off. The stored config is untouched, so leaving clean
        // restores the previous set exactly.
        val renderedFraming =
            renderedFramingAssists(
                localFraming, effectiveDisplayMode, cleanViewPins, isPhotographyMode)
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
                feed = zones.feed,
                infoBar = zones.infoBar,
                statusBarVisible = statusBarVisible,
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
        // Link health must use generation-filtered frames so a restart does not
        // score a stale replay JPEG as a live stream. Conflate so chrome never
        // backpressures the shared live-frame bus (feed hitch root cause).
        LaunchedEffect(actualLinkHealth, healthFrameSource) {
            val swiftSource =
                healthFrameSource as? com.opencapture.openzcine.bridge.SwiftCoreLiveFrameSource
                    ?: return@LaunchedEffect
            swiftSource.currentStreamFrames
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
        val liveFeedPresentation =
            remember(monitorFrameSource) { LiveFeedPresentationState() }
        val liveFeedEffectsPresentation =
            remember(monitorFrameSource) { LiveFeedEffectsPresentationState() }
        var feedPointerSize by remember(monitorFrameSource) { mutableStateOf(IntSize.Zero) }
        // The drawn picture inside that zone (letterboxed when the feed's aspect differs),
        // which is what bounds the zoom pan. Filled in where the content rect is resolved.
        var feedPictureSize by remember(monitorFrameSource) { mutableStateOf(0f to 0f) }
        val audioMetersEnabled = assist.audioMetersEnabled
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
        LaunchedEffect(operatorSettings.splitComparisonEnabled.value) {
            if (operatorSettings.splitComparisonEnabled.value) splitComparisonMuted = false
        }
        // The zoom is session-only: it is a focus check, not a setting, and a monitor that reopens
        // already magnified is a monitor that lies about the framing.
        var committedZoom by remember { mutableStateOf(FeedZoom.NONE) }
        val feedZoom = committedZoom
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
            renderedFeedEffects(
                assist.effects.copy(
                    splitComparison =
                        operatorSettings.activeSplitComparison?.takeUnless { splitComparisonMuted },
                ),
                effectiveDisplayMode,
                cleanViewPins,
                isPhotographyMode,
            )
        val renderedAudioMeters =
            audioMetersEnabled &&
                assistToolRendersInMode(
                    AssistTool.AUDIO, effectiveDisplayMode, cleanViewPins, isPhotographyMode)
        var liveAudioLevels by
            remember(monitorFrameSource) { mutableStateOf<LiveAudioMeterLevels?>(null) }
        LaunchedEffect(monitorFrameSource, renderedAudioMeters) {
            if (!renderedAudioMeters || monitorFrameSource == null) {
                liveAudioLevels = null
                return@LaunchedEffect
            }
            monitorFrameSource.frames
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
                    recording || recordCommandPending || pendingRecordTarget != null,
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
        val physicalViewport = ZoneFrame(0f, 0f, viewportWidth, viewportHeight)
        // Photography's landscape feed: the still image-area's shape centred in
        // the clear box between the chrome lanes — the rail and capture band
        // never overlap the image (iOS centered letterbox + reserved lanes).
        val landscapePhotoFeed =
            if (!isPortrait && isPhotographyMode && !isCommand) {
                val batteryTrailing =
                    zones.batteryPhone?.let { anchor ->
                        val stack = batteryRowStackFrame(anchor = anchor, lock = zones.lock)
                        stack.x + stack.width
                    }
                val leftChromeTrailing =
                    maxOf(zones.lock.x + zones.lock.width, batteryTrailing ?: 0f)
                val railLaneTrailing =
                    if (assistToolbarVisible) {
                        leftChromeTrailing + 12f + ASSIST_RAIL_EXPANDED_WIDTH_DP + 8f
                    } else {
                        leftChromeTrailing + 8f
                    }
                val rightRailLeading =
                    minOf(zones.record.x, zones.disp.x, zones.media.x, zones.settings.x) - 8f
                photographyFeedFrame(
                    cinemaFeed = zones.feed,
                    viewport = physicalViewport,
                    imageArea = cameraProperties.imageArea,
                    leadingLaneTrailing = railLaneTrailing,
                    trailingLaneLeading = rightRailLeading,
                )
            } else {
                null
            }
        val effectiveFeed = landscapePhotoFeed ?: zones.feed
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
                            displayMode = next
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
        Box(Modifier.fillMaxSize().then(sceneLayer)) {
        if (!isCommand) {
            Box(
                Modifier.zone(effectiveFeed)
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
                Modifier.liveFeedBodyRotation(liveFeedRotation)
                    // Punch-in goes LAST and wraps the WHOLE feed stack, not just the raster: the
                    // AF box and focus ring are siblings of it, so scaling the raster alone would
                    // leave them behind at unmagnified positions over a magnified picture. Inside
                    // clipToBounds so the magnified frame is still cropped to the feed zone; ahead
                    // of the gestures so Compose maps a touch back through the scale and
                    // tap-to-focus still lands on the pixel under the finger.
                    .graphicsLayer {
                        // A CENTER-anchored scale then the offset, in that order — the pair every
                        // formula in FeedZoom is written against. Anchoring on the AF box instead
                        // (as the retired MAG tool did) would make the pinch pivot somewhere the
                        // operator's fingers are not.
                        scaleX = feedZoom.scale
                        scaleY = feedZoom.scale
                        transformOrigin = TransformOrigin.Center
                        translationX = feedZoom.offsetX
                        translationY = feedZoom.offsetY
                    }
                    .onSizeChanged { feedPointerSize = it }
                    // Pinch always transforms; a one-finger drag only pans once zoomed, so an
                    // unzoomed drag still reaches the DISP swipe in the arbiter below.
                    .transformable(
                        state = feedTransformState,
                        canPan = { feedZoom.isZoomed },
                    )
                    .focusFeedGestures(
                        geometry = feedGestureGeometry,
                        context = focusGestureContext,
                        isPortrait = isPortrait,
                        isZoomed = feedZoom.isZoomed,
                        onHoldingChanged = { focusLockHolding = it },
                        onAction = handleFocusFeedAction,
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
                } else if (monitorFrameSource != null) {
                    LiveFeedView(
                        monitorFrameSource,
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
                        effects = renderedEffects,
                        configuration = operatorSettings.feedEffectsConfiguration,
                        cameraInput = exposureAssistCameraInput,
                        lutLibrary = lutLibrary,
                        effectsPresentationState = liveFeedEffectsPresentation,
                        aspectFill = portraitRasterFill,
                        // SurfaceView graded feed is invisible to Kyant
                        // layerBackdrop — FULL glass must present via Compose. A rotated
                        // (vertical) feed must too: SurfaceView buffers composite outside
                        // the Compose layer and never rotate with it.
                        preferComposablePresentation =
                            glass.tier == GlassTier.FULL ||
                                liveFeedRotation != LiveFeedRotation.LANDSCAPE,
                    )
                    // Presentation-only texture: after the camera frame/effect renderer, before
                    // every geometry-bearing assist. Scopes continue sampling monitorFrameSource.
                    FeedTextureOverlay(
                        presentationState = liveFeedPresentation,
                        aspectFill = portraitRasterFill,
                        horizontalPresentationScale = localFraming.horizontalPresentationScale,
                        verticalPresentationScale = localFraming.verticalPresentationScale,
                    )
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
                            Modifier.chromeEditable(
                                ChromeSection.FOCUS_BOX,
                                chromeEditorMode,
                                operatorSettings,
                                recordChromeEditBounds,
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
        }
        CompositionLocalProvider(LocalMonitorGlass provides glass) {
            if (isPortrait) {
                PortraitChrome(
                    zones = zones,
                    viewportHeight = viewportHeight,
                    isCommand = isCommand,
                    isFill = isPortraitFill,
                    availability = availability,
                    locked = locked,
                    recording = recording,
                    timecodeRetention = timecodeRetention,
                    cameraReportsTimecode = cameraReportsTimecode,
                    sessionState = sessionState,
                    // iOS portrait centers the same toggle-aware, retention-held
                    // media readout the landscape pill shows.
                    cameraReadouts = cameraReadouts.copy(media = topBarMedia),
                    assist = assist,
                    operatorSettings = operatorSettings,
                    commandPresentation = commandPresentation,
                    captureSettings = captureSettings,
                    photographySettings = photographySettings,
                    activeMonitorPicker = activeMonitorPickerKind,
                    commandControlsEnabled = commandControlsEnabled,
                    pendingCommandControl = pendingCommandControl,
                    displayMode = effectiveDisplayMode,
                    enabledDisplayModeOrder = displayModeOrder,
                    cameraProperties = cameraProperties,
                    stillCapturing = stillCapturing,
                    bodyShutterPulse = bodyShutterPulse,
                    onShutterPressed = photoShutterPressed,
                    onShutterReleased = photoShutterReleased,
                    photoTimerRemaining = photoTimerRemaining,
                    onLock = { locked = !locked },
                    recordEnabled = recordControlEnabled,
                    onRecord = requestRecordToggle,
                    onDisp = {
                        activeAssistOptions = null
                        displayMode = nextDisplayModeInOrder(displayModeOrder, effectiveDisplayMode)
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
                            view.performOperatorHaptic(HapticFeedbackConstants.LONG_PRESS)
                        }
                    },
                    onOpenAssistOptions = openAssistOptions,
                    onChromeEditBounds = recordChromeEditBounds,
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
                        showsTimecode = cameraReportsTimecode,
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
                                view.performOperatorHaptic(HapticFeedbackConstants.LONG_PRESS)
                            }
                        },
                        liveFps = fpsSampler.formatted,
                        signalBars = actualLinkHealth.presentation.signalBars,
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
                    // Photography swaps the movie readouts for stills ones in
                    // the same chrome (iOS `isPhotography`).
                    val isPhotography = prefersPhotographyChrome(cameraProperties)
                    // Top info pill, centered in the deck band; compact in clean
                    // mode. The deck is feed-anchored and the synthesized island
                    // lane (see monitorLeadingInsetDp) starts the feed right of
                    // the lock, so the band always clears it — same as iPhone
                    // geometry.
                    if (statusBarVisible) {
                        // Photography centres the deck pill group over the
                        // centred FEED, not the band (iOS centres the deck
                        // over the feed) — a band slice symmetric about the
                        // feed midpoint makes Center land there.
                        val deckHost =
                            if (isPhotography) {
                                photographyStripHostFrame(
                                    band = zones.infoBar,
                                    feedCenterX =
                                        effectiveFeed.x + effectiveFeed.width / 2f,
                                )
                            } else {
                                zones.infoBar
                            }
                        Box(Modifier.zone(deckHost), contentAlignment = Alignment.Center) {
                            FitScale(deckHost.width.dp) {
                                InfoPill(
                                    modifier =
                                        Modifier.chromeEditable(
                                            ChromeSection.STATUS_BAR,
                                            chromeEditorMode,
                                            operatorSettings,
                                            recordChromeEditBounds,
                                        ),
                                    recording = recording,
                                    timecodeRetention = timecodeRetention,
                                    sessionState = sessionState,
                                    isPhotography = isPhotography,
                                    shotsRemaining = cameraProperties.shotsRemaining,
                                    stillSize =
                                        cameraProperties.stillSizeAreaLabel()
                                            ?: cameraProperties.stillSizeCompactLabel(),
                                    stillQuality = cameraProperties.stillQualityCompactLabel(),
                                    photoStorage = cameraProperties.storage,
                                    photoPillShowsStorage = photoPillShowsStorage,
                                    onTogglePhotoPill = {
                                        photoPillShowsStorage = !photoPillShowsStorage
                                    },
                                    onPillBounds = { kind, frame ->
                                        measuredTopPills[kind] = frame
                                    },
                                    recReadoutVisible = mounts(ChromeSection.REC_READOUT),
                                    timecodeReadoutVisible =
                                        mounts(ChromeSection.TIMECODE_READOUT),
                                    resolutionReadoutVisible =
                                        mounts(ChromeSection.RESOLUTION_READOUT),
                                    codecReadoutVisible = mounts(ChromeSection.CODEC_READOUT),
                                    mediaReadoutVisible = mounts(ChromeSection.MEDIA_READOUT),
                                    fpsReadoutVisible = mounts(ChromeSection.FPS_READOUT),
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
                    // Photography keeps the toolbar but narrows it to the
                    // stills-relevant tools (iOS `appliesToPhotography`).
                    if (!isClean || chromeEditorMode == MonitorDisplayMode.CLEAN) {
                        // Photography moves the assist tools to the lock-side
                        // vertical rail (below), handing the whole band to the
                        // capture strip (iOS `assistVisible = … && !isPhotographyBand`).
                        if (assistToolbarVisible && !isPhotography) {
                            zones.assistStrip?.let { strip ->
                                AssistToolbar(
                                    assist,
                                    Modifier.zone(strip)
                                        .chromeEditable(
                                            ChromeSection.ASSIST_TOOLBAR,
                                            chromeEditorMode,
                                            operatorSettings,
                                            recordChromeEditBounds,
                                        )
                                        .alpha(if (locked) 0.4f else 1f),
                                    visibleTools =
                                        frontPinnedAssistTools(
                                            operatorSettings.visibleAssistToolbarTools
                                                .filterNot { it.isPhotographyOnly },
                                            photography = false,
                                        ),
                                    framingConfiguration = localFraming,
                                    onToggleFramingTool = operatorSettings::toggleLocalFramingTool,
                                    hapticsEnabled = operatorSettings.hapticsEnabled.value,
                                    enabled = !locked,
                                    onLongPressToolAnchored = openAssistOptions,
                                )
                            }
                        }
                        // Photography's collapsible vertical assist rail,
                        // top-aligned next to the lock button and expanding
                        // downward until it reaches the capture band (iOS
                        // photo-rail placement in `MonitorUnified`).
                        if (assistToolbarVisible && isPhotography && !locked) {
                            zones.assistStrip?.let { band ->
                                val batteryTrailing =
                                    zones.batteryPhone?.let { anchor ->
                                        val stack =
                                            batteryRowStackFrame(
                                                anchor = anchor,
                                                lock = zones.lock,
                                            )
                                        stack.x + stack.width
                                    }
                                val railFrame =
                                    photographyAssistRailFrame(
                                        lock = zones.lock,
                                        batteryTrailing = batteryTrailing,
                                        assistBand = band,
                                        measuredCaptureBar = measuredCaptureBar,
                                        expanded = photoRailExpanded,
                                    )
                                PortraitFillAssistRail(
                                    state = assist,
                                    expanded = photoRailExpanded,
                                    onExpandedChange = { photoRailExpanded = it },
                                    modifier = Modifier.zone(railFrame),
                                    visibleTools =
                                        frontPinnedAssistTools(
                                            operatorSettings.visibleAssistToolbarTools.filter {
                                                it.appliesToPhotography
                                            },
                                            photography = true,
                                        ),
                                    framingConfiguration = localFraming,
                                    onToggleFramingTool =
                                        operatorSettings::toggleLocalFramingTool,
                                    hapticsEnabled = operatorSettings.hapticsEnabled.value,
                                    enabled = !locked,
                                    onLongPressToolAnchored = openAssistOptions,
                                )
                            }
                        }
                        if (cameraValuesVisible) {
                            zones.captureStrip?.let { strip ->
                                // Photography owns the whole band (assist lives
                                // on the rail) and centres the strip under the
                                // centred FEED, not the screen (iOS photo band
                                // alignment .center).
                                val stripHost =
                                    if (isPhotography) {
                                        val bandLeft =
                                            minOf(zones.assistStrip?.x ?: strip.x, strip.x)
                                        val bandRight =
                                            maxOf(
                                                (zones.assistStrip?.let { it.x + it.width })
                                                    ?: (strip.x + strip.width),
                                                strip.x + strip.width,
                                            )
                                        photographyStripHostFrame(
                                            band =
                                                ZoneFrame(
                                                    bandLeft,
                                                    strip.y,
                                                    bandRight - bandLeft,
                                                    strip.height,
                                                ),
                                            feedCenterX =
                                                effectiveFeed.x + effectiveFeed.width / 2f,
                                        )
                                    } else {
                                        strip
                                    }
                                Box(
                                    Modifier.zone(stripHost)
                                        .chromeEditable(
                                            ChromeSection.CAMERA_VALUES,
                                            chromeEditorMode,
                                            operatorSettings,
                                            recordChromeEditBounds,
                                        )
                                        .alpha(if (locked) 0.4f else 1f),
                                    contentAlignment =
                                        if (isPhotography) {
                                            Alignment.Center
                                        } else {
                                            Alignment.CenterEnd
                                        },
                                ) {
                                    if (isPhotography) {
                                        // The stills strip is the SAME shared
                                        // strip — cells, active accents, and
                                        // pinned widths — over the stills
                                        // presentation set (iOS reuses
                                        // CaptureSettingButton for both).
                                        MonitorCaptureStrip(
                                            settings = photographySettings,
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
                                            onShutterLongPress = null,
                                            onBarBoundsInRoot = { measuredCaptureBar = it },
                                            maxContentWidth = stripHost.width.dp,
                                        )
                                    } else {
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
                }

                // Focus-by-wire scrub strip: on the live view just left of the right system rail
                // in an AF focus mode. The camera refuses a remote drive in MF (Invalid_Status) —
                // the lens ring owns focus there — so the scrub shows in AF modes (AF-S/AF-C/AF-F/
                // AF-A) and acts as a manual-focus override. A refused drive is transient, so the
                // strip never hides on a refusal; it retries.
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
                    mfDriveEligibility(cameraProperties.focusMode) != MfDriveEligibility.UNAVAILABLE &&
                    // The strip absorbs taps (it drives on drag, swallows plain taps
                    // so they can't move the AF point under it). Mounting it over an
                    // open picker/popup would eat the popup's dismiss taps — picking
                    // MF in the FOCUS popup flips focusMode while that popup is still
                    // up, so it waits for every panel to close (iOS `showsMFDriveScrub
                    // … && activePanel == nil`).
                    activeCommandControl == null &&
                    activeMonitorPickerKind == null &&
                    activeAssistOptions == null
                ) {
                    val rightRailLeading =
                        minOf(zones.record.x, zones.disp.x, zones.media.x, zones.settings.x)
                    // Re-arm the relative position when the dial (re)appears.
                    DisposableEffect(Unit) {
                        mfDrive.resetDial()
                        onDispose {}
                    }
                    MFDriveStrip(
                        atEnd = mfDriveAtEnd,
                        enabled =
                            mfDriveEligibility(cameraProperties.focusMode) ==
                                MfDriveEligibility.DRIVABLE,
                        onDrive = { pulses -> mfDrive.drive(recordScope, pulses) },
                        modifier =
                            Modifier.zone(
                                mfDriveStripFrame(physicalViewport, rightRailLeading),
                            ),
                        netPulses = mfDriveNetPulses,
                        dialFraction = mfDriveDialFraction,
                    )
                }

                // Side rails: lock + authoritative batteries + record / DISP / media / settings,
                // each on its own switch (iOS `MonitorSystemCluster` off `sideRailPlan`). The
                // whole leading cluster nudges left off the feed edge; the lock and the battery
                // shift by the SAME amount so their deliberate gap is preserved.
                if (railMounts(ChromeSection.LOCK_BUTTON)) {
                    LockButton(
                        locked,
                        Modifier.zone(
                            zones.lock.copy(x = zones.lock.x - LEADING_RAIL_LEFT_NUDGE_DP),
                        ).chromeEditable(
                            ChromeSection.LOCK_BUTTON,
                            chromeEditorMode,
                            operatorSettings,
                            recordChromeEditBounds,
                        ),
                    ) { locked = !locked }
                }
                // Like iOS seating the combined indicator directly under the
                // lock button, the two battery rows stack at the top of the
                // leading lane, just below the lock's clearance.
                zones.batteryPhone?.takeIf {
                    railMounts(ChromeSection.BATTERY_INDICATORS)
                }?.let { anchor ->
                    BatteryRowStack(
                        phonePercent = phoneBatteryReadout.percent,
                        cameraPercent = cameraReadouts.batteryPercent,
                        modifier =
                            Modifier.zone(
                                batteryRowStackFrame(
                                    anchor =
                                        anchor.copy(
                                            x = anchor.x - LEADING_RAIL_LEFT_NUDGE_DP,
                                        ),
                                    lock = zones.lock,
                                ),
                            ).chromeEditable(
                                ChromeSection.BATTERY_INDICATORS,
                                chromeEditorMode,
                                operatorSettings,
                                recordChromeEditBounds,
                            ),
                        phoneExternalPower = phoneBatteryReadout.externalPower,
                        cameraExternalPower = cameraReadouts.externalPower,
                    )
                }
                if (railMounts(ChromeSection.RAIL_SETTINGS)) {
                    AuxCircleButton(
                        Modifier.zone(zones.settings).chromeEditable(
                            ChromeSection.RAIL_SETTINGS,
                            chromeEditorMode,
                            operatorSettings,
                            recordChromeEditBounds,
                        ),
                        onClick = {
                            if (pendingCommandControl == null) activeMonitorPickerKind = null
                            onOpenSettings()
                        },
                    ) { glyphModifier, tint ->
                        GearGlyph(tint, glyphModifier)
                    }
                }
                if (railMounts(ChromeSection.RAIL_MEDIA)) {
                    AuxCircleButton(
                        Modifier.zone(zones.media).chromeEditable(
                            ChromeSection.RAIL_MEDIA,
                            chromeEditorMode,
                            operatorSettings,
                            recordChromeEditBounds,
                        ),
                        onClick = {
                            if (pendingCommandControl == null) activeMonitorPickerKind = null
                            onOpenMedia()
                        },
                    ) { glyphModifier, tint ->
                        // Photo glyph reads better as "media" on the stills side;
                        // cinema keeps the film-roll glyph (iOS `mediaButton`).
                        if (isPhotographyMode) {
                            PhotoGlyph(tint, glyphModifier)
                        } else {
                            MediaStackGlyph(tint, glyphModifier)
                        }
                    }
                }
                if (railMounts(ChromeSection.RAIL_RECORD)) {
                    val recordModifier =
                        Modifier.zone(zones.record).chromeEditable(
                            ChromeSection.RAIL_RECORD,
                            chromeEditorMode,
                            operatorSettings,
                            recordChromeEditBounds,
                        )
                    if (isPhotographyMode) {
                        PhotographyShutterButton(
                            isCapturing = stillCapturing,
                            modifier = recordModifier,
                            timerRemaining = photoTimerRemaining,
                            bodyShutterPulse = bodyShutterPulse,
                            onPressed = photoShutterPressed,
                            onReleased = photoShutterReleased,
                        )
                    } else {
                        RecordButton(
                            recording = recording,
                            modifier = recordModifier,
                            enabled = recordControlEnabled,
                            onClick = requestRecordToggle,
                        )
                    }
                }
                if (railMounts(ChromeSection.RAIL_DISP)) {
                    DispButton(
                        activeIndex = displayModeOrder.indexOf(effectiveDisplayMode),
                        modeCount = displayModeOrder.size,
                        isLiveActive = effectiveDisplayMode == MonitorDisplayMode.LIVE,
                        modifier =
                            Modifier.zone(zones.disp).chromeEditable(
                                ChromeSection.RAIL_DISP,
                                chromeEditorMode,
                                operatorSettings,
                                recordChromeEditBounds,
                            ),
                    ) {
                        activeAssistOptions = null
                        displayMode = nextDisplayModeInOrder(displayModeOrder, effectiveDisplayMode)
                    }
                }
            }
        }
        // One monitor-owned sampler serves every toolbar-selected scope.
        // Landscape and portrait fill float every selection; portrait fit
        // mounts only its recency-selected ≤2 stack in the shared zone.
        val renderedScopeSet =
            renderedScopes(
                assist.selectedScopes, effectiveDisplayMode, cleanViewPins, isPhotographyMode)
        if (renderedScopeSet.isNotEmpty() && monitorFrameSource != null) {
            ScopePanels(
                selectedScopes = renderedScopeSet,
                portraitScopes = portraitScopes,
                crushClipCompensationRaw = operatorSettings.scopeCrushClipCompensation.wireValue,
                histogramTrafficLightsEnabled = operatorSettings.histogramTrafficLightsEnabled.value,
                configuration = operatorSettings.scopeAssistConfiguration,
                cameraInput = exposureAssistCameraInput,
                // The mode-filtered look, not the stored one: the vectorscope reads the MONITOR
                // image, so it must push its samples through the LUT actually baked into the frame
                // — none in photography, and none in clean unless the operator pinned it. Mirrors
                // iOS passing `renderedLiveAssistTools` to `vectorscopeMonitorCube`.
                lutSelection = renderedEffects.lut,
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
        if (!isCommand && (!isPortrait || isPortraitFill) && renderedAudioMeters) {
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
        if (!isCommand && (!isPortrait || isPortraitFill) && renderedEffects.falseColor != null) {
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

        // Fit/Fill quick key (iOS parity): the feed frame's own bottom-right corner control — the
        // explicit aspect toggle beside the pinch, replacing any settings-row picker. Mounted only
        // where the choice is real: photography forces fit, a vertical feed forces fill, command
        // has no feed; lock and the Edit view hide every on-feed affordance. The reset/50-50
        // stack seats one slot higher while it shows, through the shared lane inset below.
        val aspectToggleVisible =
            isPortrait && !isCommand && !isPhotographyMode && !isVerticalFeed &&
                !locked && chromeEditorMode == null
        val bottomChromeInsetDp = with(density) { levelGaugeBottomChromeInset.toDp().value }
        val onFeedLaneInset =
            bottomChromeInsetDp +
                (
                    if (aspectToggleVisible) {
                        FOCUS_RESET_BUTTON_SIZE_DP + FOCUS_RESET_PANEL_GAP_DP
                    } else {
                        0f
                    }
                )
        if (aspectToggleVisible) {
            val fillsViewport = operatorSettings.portraitFeedAspect.fillsViewport
            val toggleFrame =
                focusResetButtonBaseFrame(
                    feed = zones.feed,
                    isPortrait = true,
                    bottomChromeInset = bottomChromeInsetDp,
                )
            val toggleDescription =
                stringResource(
                    if (fillsViewport) {
                        R.string.portrait_aspect_fit
                    } else {
                        R.string.portrait_aspect_fill
                    },
                )
            Box(
                Modifier
                    .zone(toggleFrame)
                    .background(Color.Black.copy(alpha = 0.55f), CircleShape)
                    .border(1.dp, LiveDesign.hairline, CircleShape)
                    .chromeClickable {
                        operatorSettings.portraitFeedAspect =
                            if (fillsViewport) {
                                PortraitFeedAspect.FIT_16_9
                            } else {
                                PortraitFeedAspect.FILL
                            }
                    }
                    .testTag("portrait_aspect_toggle")
                    .semantics { contentDescription = toggleDescription },
                contentAlignment = Alignment.Center,
            ) {
                // iOS full-screen arrows in a 40pt black circle.
                FullScreenArrowsGlyph(
                    LiveDesign.text,
                    expand = !fillsViewport,
                    modifier = Modifier.size(15.dp),
                )
            }
        }

        // Keep the reset affordance above every movable scope/reference panel. The pure placement
        // policy mirrors iOS and this later composition order remains reachable even if a viewport
        // is too crowded to provide a geometrically clear slot.
        if (focusResetVisible) {
            // Photography's letterboxed feed frame (not the zone map's full-bleed rect):
            // its leading edge clears the vertical assist rail's lane by construction, so
            // the affordance seats beside the rail like iOS instead of under it.
            val baseFrame =
                focusResetButtonBaseFrame(
                    feed = effectiveFeed,
                    isPortrait = isPortrait,
                    bottomChromeInset = onFeedLaneInset,
                )
            val resetFrame =
                focusResetButtonClearFrame(
                    base = baseFrame,
                    panelFrames = analysisPanelFrames.values,
                    bounds = effectiveFeed,
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

        // 50/50 quick key: hides and restores the armed comparison without reopening the LUT
        // popup, because judging a look is an A/B the operator repeats. Mounted by the ARMED
        // preference — muting must never remove the only control that undoes it — and it rides the
        // LUT's own visibility, so clean view carries it exactly where the operator pinned the
        // tool. Same rule as `LUTResolution.showsSplitComparisonKey` on iOS.
        if (renderedEffects.lut != null &&
            operatorSettings.splitComparisonEnabled.value &&
            !locked &&
            chromeEditorMode == null
        ) {
            val keyFrame =
                splitComparisonKeyFrame(
                    feed = effectiveFeed,
                    isPortrait = isPortrait,
                    bottomChromeInset = onFeedLaneInset,
                    focusResetMounted = focusResetVisible,
                    widthDp = SPLIT_KEY_WIDTH_DP,
                    heightDp = SPLIT_KEY_HEIGHT_DP,
                )
            val splitKeyDescription = stringResource(R.string.split_comparison_key)
            Box(
                Modifier
                    .zone(keyFrame)
                    .background(Color.Black.copy(alpha = 0.55f), CircleShape)
                    .border(
                        1.dp,
                        if (splitComparisonMuted) LiveDesign.hairline else LiveDesign.accentDim,
                        CircleShape,
                    )
                    .chromeClickable { splitComparisonMuted = !splitComparisonMuted }
                    .testTag("split_comparison_key")
                    .semantics { contentDescription = splitKeyDescription },
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    text = "50/50",
                    style = chromeStyle(11f, FontWeight.Bold),
                    color = if (splitComparisonMuted) LiveDesign.muted else LiveDesign.accent,
                )
            }
        }
        // The punch-in quick key is retired with the MAG tool it drove: zoom is direct
        // manipulation now, so the feed itself is the control and a key would have nothing to say.
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
                            kind = picker.kind,
                            anchorPill = measuredTopPills[picker.kind],
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
                            onSelect =
                                if (isPhotographyMode) {
                                    applyPhotographyControl
                                } else {
                                    applyCameraControl
                                },
                            onDismiss = {
                                if (pendingCommandControl == null) {
                                    activeMonitorPickerKind = null
                                    commandControlFeedback = null
                                }
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
                        )
                    }
                }
            }
        }

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
                desqueeze = operatorSettings.localFramingAssistConfiguration,
            )
        }

        // Recording tally border at the physical edge (iOS `RecordingBorderModule`).
        if (recording) {
            Box(
                Modifier.fillMaxSize()
                    .border(4.dp, LiveDesign.rec, RoundedCornerShape(24.dp)),
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
                                    assist.selectStoredLut(result.entry.selection)
                                    if (!assist.isOn(AssistTool.LUT)) assist.toggle(AssistTool.LUT)
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
                    onOpenRedDownload = { redDownloadPresented = true },
                    onRequestLutImport =
                        lutLibrary?.let {
                            {
                                lutImportLauncher.launch(
                                    arrayOf("*/*", "application/octet-stream"))
                            }
                        },
                    onDismiss = { activeAssistOptions = null },
                )
            }
        }
        if (redDownloadPresented && lutLibrary != null) {
            com.opencapture.openzcine.lut.RedLutDownloadScreen(
                lutLibrary = lutLibrary,
                frameioController = frameioController,
                onClose = { redDownloadPresented = false },
                onImported = { count ->
                    if (count > 0 && !assist.isOn(AssistTool.LUT)) {
                        assist.toggle(AssistTool.LUT)
                    }
                },
            )
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
        if (chromeEditorMode != null) {
            // Editing the layout and operating the camera are different modes. This swallows
            // every touch bound for the monitor — focus, pickers, record, DISP — so a stray tap
            // while arranging chrome can never reach the camera. Only the badges and Done, which
            // mount above it, respond.
            Box(
                Modifier.fillMaxSize().pointerInput(Unit) {
                    awaitPointerEventScope {
                        while (true) {
                            awaitPointerEvent().changes.forEach { it.consume() }
                        }
                    }
                },
            )
            ChromeEditOverlay(
                mode = chromeEditorMode,
                boxes = chromeEditBoxes,
                settings = operatorSettings,
                feed = effectiveFeed,
                // Just clear of the bottom bars, whose top corners carry badges that straddle the
                // edge — a bottom-centred banner sat on the tool bar's eye and swallowed the tap.
                bannerBottomDp =
                    if (isPortrait) {
                        effectiveFeed.y + effectiveFeed.height - 12f
                    } else {
                        (zones.assistStrip?.y ?: (effectiveFeed.y + effectiveFeed.height)) - 18f
                    },
                onDone = {
                    operatorSettings.endChromeEditing()
                    // Done returns to where the operator came from — Display settings — not to the
                    // live monitor with no way back but the rail they may have just hidden.
                    onOpenSettings()
                },
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
    modifier: Modifier = Modifier,
    recording: Boolean,
    timecodeRetention: MonitorTimecodeRetention,
    sessionState: CameraSessionState,
    recReadoutVisible: Boolean,
    timecodeReadoutVisible: Boolean,
    resolutionReadoutVisible: Boolean,
    codecReadoutVisible: Boolean,
    mediaReadoutVisible: Boolean,
    fpsReadoutVisible: Boolean,
    signalBars: Int,
    resolution: String,
    codec: String,
    media: String,
    fps: String,
    isPhotography: Boolean = false,
    shotsRemaining: Int? = null,
    stillSize: String? = null,
    stillQuality: String? = null,
    photoStorage: CameraStorageStatus? = null,
    photoPillShowsStorage: Boolean = false,
    onTogglePhotoPill: (() -> Unit)? = null,
    activePicker: MonitorPickerKind? = null,
    resolutionPickerAvailable: Boolean = false,
    codecPickerAvailable: Boolean = false,
    pickersEnabled: Boolean = false,
    onOpenPicker: (MonitorPickerKind) -> Unit = {},
    onToggleMediaReadout: (() -> Unit)? = null,
    /** Publishes each picker pill's root bounds so its popdown can centre under it. */
    onPillBounds: ((MonitorPickerKind, ZoneFrame) -> Unit)? = null,
) {
    Row(
        modifier = modifier.glass(ChromeShape).padding(horizontal = 12.dp, vertical = 6.dp),
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        // Photography swaps the movie readouts for stills ones in the same
        // pill (iOS InfoPillContent): shots remaining takes the timecode slot,
        // image size and quality take resolution and codec as popup buttons.
        // Every cell is the operator's to hide, in every DISP mode. Clean used to strip the deck
        // to timecode + FPS with a hard-coded `compact` flag, so hiding CODEC or MEDIA there did
        // nothing — the cells were dropped either way. The configuration IS the compact deck now
        // (iOS `InfoPillContent`).
        if (isPhotography) {
            if (timecodeReadoutVisible) {
                ShotsRemainingReadout(
                    shotsRemaining,
                    storage = photoStorage,
                    showsStorage = photoPillShowsStorage,
                    onToggle = onTogglePhotoPill,
                )
            }
            if (resolutionReadoutVisible) {
                // The SIZE pill drops the Area | Size drum down exactly like
                // the cinema resolution/codec pills (iOS imageAreaButton).
                ReadoutPill(
                    stillSize ?: "—",
                    active = activePicker == MonitorPickerKind.SIZE,
                    onClick = {
                        if (pickersEnabled) onOpenPicker(MonitorPickerKind.SIZE)
                    },
                    onBoundsInRoot =
                        onPillBounds?.let { report ->
                            { frame -> report(MonitorPickerKind.SIZE, frame) }
                        },
                ) { tint ->
                    PhotoGlyph(tint, Modifier.size(14.dp, 11.dp))
                }
            }
            if (codecReadoutVisible) {
                ReadoutPill(
                    stillQuality ?: "—",
                    active = activePicker == MonitorPickerKind.QUALITY,
                    onClick = {
                        if (pickersEnabled) onOpenPicker(MonitorPickerKind.QUALITY)
                    },
                    onBoundsInRoot =
                        onPillBounds?.let { report ->
                            { frame -> report(MonitorPickerKind.QUALITY, frame) }
                        },
                ) { tint ->
                    ApertureGlyph(tint, Modifier.size(12.dp))
                }
            }
            // No MEDIA cell in photo mode — the SHOTS readout tap-toggles
            // to the storage form instead (iOS).
            if (fpsReadoutVisible) {
                FpsChip(signalBars, fps)
            }
            return@Row
        }
        if (recReadoutVisible) RecordChip(recording)
        if (timecodeReadoutVisible) {
            RetainedCameraTimecodeReadout(
                retention = timecodeRetention,
                sessionState = sessionState,
                sizeSp = 20f,
                weight = FontWeight.Medium,
            )
        }
        if (resolutionReadoutVisible) {
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
                onBoundsInRoot =
                    onPillBounds?.let { report ->
                        { frame -> report(MonitorPickerKind.RESOLUTION, frame) }
                    },
            ) { tint ->
                VideoGlyph(tint)
            }
        }
        if (codecReadoutVisible) {
            ReadoutPill(
                codec,
                active = activePicker == MonitorPickerKind.CODEC,
                onClick = {
                    if (pickersEnabled) onOpenPicker(MonitorPickerKind.CODEC)
                },
                onBoundsInRoot =
                    onPillBounds?.let { report ->
                        { frame -> report(MonitorPickerKind.CODEC, frame) }
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
    /** Whether non-critical chrome mounts; clean view (DISP 2) strips it all (#256). */
    isFill: Boolean,
    availability: MonitorDataAvailability,
    locked: Boolean,
    recording: Boolean,
    timecodeRetention: MonitorTimecodeRetention,
    /** Live-view header timecode status; a body that runs none gets no readout and no hero band. */
    cameraReportsTimecode: Boolean,
    sessionState: CameraSessionState,
    cameraReadouts: MonitorCameraReadouts,
    assist: AssistState,
    operatorSettings: OperatorSettings,
    commandPresentation: CommandDashboardPresentation,
    captureSettings: List<MonitorCaptureSettingPresentation>,
    photographySettings: List<MonitorCaptureSettingPresentation>,
    activeMonitorPicker: MonitorPickerKind?,
    commandControlsEnabled: Boolean,
    pendingCommandControl: CameraControl?,
    displayMode: MonitorDisplayMode,
    enabledDisplayModeOrder: List<MonitorDisplayMode>,
    cameraProperties: CameraPropertySnapshot,
    stillCapturing: Boolean,
    bodyShutterPulse: Int = 0,
    onShutterPressed: () -> Unit,
    onShutterReleased: () -> Unit,
    photoTimerRemaining: Int? = null,
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
    /** Publishes each badgeable element's drawn bounds while the Edit view is open. */
    onChromeEditBounds: (ChromeSection, Rect) -> Unit = { _, _ -> },
) {
    val isPhotography = prefersPhotographyChrome(cameraProperties)
    val context = LocalContext.current
    val scopeLimitMessage = stringResource(R.string.scope_fit_limit)
    var railExpanded by remember { mutableStateOf(false) }
    LaunchedEffect(isFill, isCommand) {
        if (!isFill || isCommand) railExpanded = false
    }
    // Chrome is per DISP mode and capture side, so portrait answers to the same switches landscape
    // does — the top bar used to ignore the operator's Status Bar choice entirely, and its cells
    // honoured none of the per-readout switches at all.
    val captureLayoutMode =
        if (isPhotography) CaptureLayoutMode.PHOTO else CaptureLayoutMode.VIDEO
    val chrome = operatorSettings.chrome(displayMode, captureLayoutMode)
    val chromeEditorMode = operatorSettings.chromeEditorMode
    val mounts: (ChromeSection) -> Boolean = { section ->
        // Same source gate as landscape: no feeding data, no instrument (iOS
        // `sectionHasASource`).
        availability.hasSource(section, cameraReportsTimecode, isPhotography) &&
            ((chromeEditorMode == displayMode &&
                chromeEditorMode != null &&
                section.isConfigurableIn(displayMode)) || chrome[section].value)
    }
    val railPlan =
        operatorSettings.sideRailPlan(
            mode = displayMode,
            capture = captureLayoutMode,
            interfaceLocked = locked,
            recordingOrPending = recording,
        )
    if (mounts(ChromeSection.STATUS_BAR)) {
        PortraitInfoBar(
            timecodeRetention = timecodeRetention,
            sessionState = sessionState,
            media = cameraReadouts.media,
            showsTimecode = mounts(ChromeSection.TIMECODE_READOUT),
            showsMedia = mounts(ChromeSection.MEDIA_READOUT),
            // The bar's battery gauge answers to the Monitor Chrome battery switch, like the
            // landscape rail's pair (iOS `InfoBarContent`).
            showsBattery = mounts(ChromeSection.BATTERY_INDICATORS),
            cameraBatteryPercent = cameraReadouts.batteryPercent,
            cameraExternalPower = cameraReadouts.externalPower,
            modifier =
                Modifier.zone(zones.infoBar)
                    .chromeEditable(
                        ChromeSection.STATUS_BAR,
                        chromeEditorMode,
                        operatorSettings,
                        onChromeEditBounds,
                    ),
        )
    }

    // REC-options button (iOS PortraitRecOptionsButton): a glass circle at the
    // feed's top-trailing corner, under the top bar. It rides with the record control — hiding
    // record hides its options too — and steps aside while the Edit view is open.
    if (!isCommand && mounts(ChromeSection.RAIL_RECORD) && chromeEditorMode == null) {
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
    // glass pill off the screen edges, like iOS. Photography narrows the
    // tool list to the stills set (iOS `appliesToPhotography`).
    val photographyAssistTools =
        frontPinnedAssistTools(
            operatorSettings.visibleAssistToolbarTools.filter {
                if (isPhotography) it.appliesToPhotography else !it.isPhotographyOnly
            },
            photography = isPhotography,
        )
    if (!isCommand && mounts(ChromeSection.ASSIST_TOOLBAR)) {
        zones.assistStrip?.let { strip ->
            AssistToolbar(
                assist,
                Modifier.zone(
                    ZoneFrame(strip.x + 12f, strip.y + 4f, strip.width - 24f, strip.height - 8f),
                ).chromeEditable(
                    ChromeSection.ASSIST_TOOLBAR,
                    chromeEditorMode,
                    operatorSettings,
                    onChromeEditBounds,
                ).alpha(if (locked) 0.4f else 1f),
                visibleTools = photographyAssistTools,
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
    // Every tile is a camera control — a watcher without the token gets the
    // feed's dead space back instead of a grid of dashes.
    zones.controlsGrid?.takeIf { it.height > 0 && availability.cameraControls }?.let { grid ->
        if (isCommand) {
            PortraitCommandDashboard(
                presentation = commandPresentation,
                timecodeRetention = timecodeRetention,
                showsTimecode = cameraReportsTimecode,
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
                // Photography renders the stills strip tile-for-tile (MODE ISO
                // SHUTTER IRIS DRIVE FOCUS WB METER PROFILE) instead of the movie
                // RESOLUTION/CODEC/VR grid (iOS CommandPrimaryGrid). Taps route to
                // the same stills pickers via the mapping below.
                tiles =
                    if (isPhotography) {
                        photographyCommandTiles(photographySettings)
                    } else {
                        commandPresentation.tiles
                    },
                controlsEnabled = commandControlsEnabled,
                pendingControl = pendingCommandControl,
                onOpenControl = { request ->
                    val pickerSource = if (isPhotography) photographySettings else captureSettings
                    monitorPickerKindForRequest(pickerSource, request)
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

    if (!isCommand && isFill && mounts(ChromeSection.CAMERA_VALUES)) {
        zones.captureStrip?.let { strip ->
            Box(
                Modifier.zone(strip)
                    .chromeEditable(
                        ChromeSection.CAMERA_VALUES,
                        chromeEditorMode,
                        operatorSettings,
                        onChromeEditBounds,
                    ).alpha(if (locked) 0.4f else 1f),
                contentAlignment = Alignment.Center,
            ) {
                MonitorCaptureStrip(
                    // Photography swaps in the stills presentation set over the
                    // same shared strip (cells, accents, pinned widths).
                    settings = if (isPhotography) photographySettings else captureSettings,
                    activePicker = activeMonitorPicker,
                    controlsEnabled = commandControlsEnabled,
                    pendingControl = pendingCommandControl,
                    onOpenPicker = onOpenMonitorPicker,
                    // The stills strip has no movie TV-lock hold on SHUTTER.
                    onShutterLongPress = if (isPhotography) null else onShutterLongPress,
                    onBarBoundsInRoot = onCaptureBarBounds,
                    maxContentWidth = strip.width.dp,
                )
            }
        }
    }

    if (!isCommand && isFill && mounts(ChromeSection.ASSIST_TOOLBAR)) {
        val railFrame =
            portraitFillAssistRailFrame(
                feed = zones.feed,
                captureStrip = zones.captureStrip.takeIf {
                    mounts(ChromeSection.CAMERA_VALUES)
                },
                expanded = railExpanded,
            )
        PortraitFillAssistRail(
            state = assist,
            expanded = railExpanded,
            onExpandedChange = { railExpanded = it },
            modifier = Modifier.zone(railFrame).alpha(if (locked) 0.4f else 1f),
            visibleTools = photographyAssistTools,
            framingConfiguration = operatorSettings.localFramingAssistConfiguration,
            onToggleFramingTool = operatorSettings::toggleLocalFramingTool,
            hapticsEnabled = operatorSettings.hapticsEnabled.value,
            enabled = !locked,
            onLongPressToolAnchored = onOpenAssistOptions,
        )
    }

    // Bottom system band: equal gaps around natural control sizes (iOS
    // `PortraitSystemBar` uses equal spacers, not equal columns). Every control answers to its own
    // switch; the opaque glass draws only when the band still carries one, because an empty band
    // over the letterbox is just a black stripe.
    val railMounts: (ChromeSection) -> Boolean = { section ->
        // Availability outranks the plan's guarantees, exactly like landscape.
        availability.hasSource(section, cameraReportsTimecode, isPhotography) &&
            if (chromeEditorMode == displayMode && chromeEditorMode != null &&
                section.isConfigurableIn(displayMode)
            ) {
                true
            } else {
                when (section) {
                    ChromeSection.LOCK_BUTTON -> railPlan.lock
                    ChromeSection.RAIL_DISP -> railPlan.disp
                    ChromeSection.RAIL_RECORD -> railPlan.record
                    ChromeSection.RAIL_MEDIA -> railPlan.media
                    ChromeSection.RAIL_SETTINGS -> railPlan.settings
                    else -> mounts(section)
                }
            }
    }
    if (!railPlan.isEmpty || chromeEditorMode == displayMode) {
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
    }
    // Record anchors DEAD-CENTRE as an overlay; the side clusters spread through their own
    // weighted halves. The old single equal-gap flow re-centred the whole row whenever a
    // neighbour unmounted -- clean view drops the lock, and record walked visibly
    // off-centre (iOS `portraitBody` carries the same rule).
    Box(
        Modifier.zone(zones.systemCluster),
        contentAlignment = Alignment.Center,
    ) {
        Row(
            Modifier.fillMaxSize(),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Row(
                Modifier.weight(1f),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Spacer(Modifier.weight(1f))
                if (railMounts(ChromeSection.LOCK_BUTTON)) {
                    LockButton(
                        locked,
                        Modifier.size(40.dp).chromeEditable(
                            ChromeSection.LOCK_BUTTON,
                            chromeEditorMode,
                            operatorSettings,
                            onChromeEditBounds,
                        ),
                        onClick = onLock,
                    )
                    Spacer(Modifier.weight(1f))
                }
                if (railMounts(ChromeSection.RAIL_DISP)) {
                    DispButton(
                        activeIndex = enabledDisplayModeOrder.indexOf(displayMode),
                        modeCount = enabledDisplayModeOrder.size,
                        isLiveActive = displayMode == MonitorDisplayMode.LIVE,
                        modifier =
                            Modifier.size(width = 74.dp, height = 44.dp).chromeEditable(
                                ChromeSection.RAIL_DISP,
                                chromeEditorMode,
                                operatorSettings,
                                onChromeEditBounds,
                            ),
                        onClick = onDisp,
                    )
                    Spacer(Modifier.weight(1f))
                }
            }
            if (railMounts(ChromeSection.RAIL_RECORD)) {
                // Centre lane kept clear under the overlaid record button.
                Spacer(Modifier.width(83.dp))
            }
            Row(
                Modifier.weight(1f),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Spacer(Modifier.weight(1f))
                if (railMounts(ChromeSection.RAIL_MEDIA)) {
                    AuxCircleButton(
                        Modifier.size(63.dp).chromeEditable(
                            ChromeSection.RAIL_MEDIA,
                            chromeEditorMode,
                            operatorSettings,
                            onChromeEditBounds,
                        ),
                        onClick = onOpenMedia,
                    ) { glyphModifier, tint ->
                        if (isPhotography) {
                            PhotoGlyph(tint, glyphModifier)
                        } else {
                            MediaStackGlyph(tint, glyphModifier)
                        }
                    }
                    Spacer(Modifier.weight(1f))
                }
                if (railMounts(ChromeSection.RAIL_SETTINGS)) {
                    AuxCircleButton(
                        Modifier.size(63.dp).chromeEditable(
                            ChromeSection.RAIL_SETTINGS,
                            chromeEditorMode,
                            operatorSettings,
                            onChromeEditBounds,
                        ),
                        onClick = onOpenSettings,
                    ) { glyphModifier, tint ->
                        GearGlyph(tint, glyphModifier)
                    }
                    Spacer(Modifier.weight(1f))
                }
            }
        }
        if (railMounts(ChromeSection.RAIL_RECORD)) {
            val recordModifier =
                Modifier.size(83.dp).chromeEditable(
                    ChromeSection.RAIL_RECORD,
                    chromeEditorMode,
                    operatorSettings,
                    onChromeEditBounds,
                )
            if (isPhotography) {
                PhotographyShutterButton(
                    isCapturing = stillCapturing,
                    modifier = recordModifier,
                    timerRemaining = photoTimerRemaining,
                    bodyShutterPulse = bodyShutterPulse,
                    onPressed = onShutterPressed,
                    onReleased = onShutterReleased,
                )
            } else {
                RecordButton(
                    recording = recording,
                    modifier = recordModifier,
                    enabled = recordEnabled,
                    onClick = onRecord,
                )
            }
        }
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
    showsTimecode: Boolean = true,
    showsMedia: Boolean = true,
    showsBattery: Boolean = true,
) {
    val cameraBattery =
        monitorBatteryPresentation(cameraBatteryPercent, cameraExternalPower)
    Box(modifier.background(LiveDesign.glass).padding(horizontal = 16.dp)) {
        if (showsMedia) {
            Text(
                media,
                style = chromeStyle(13f, FontWeight.Medium),
                color = LiveDesign.muted,
                maxLines = 1,
                modifier = Modifier.align(Alignment.Center),
            )
        }
        Row(Modifier.fillMaxSize(), verticalAlignment = Alignment.CenterVertically) {
            if (showsTimecode) {
                RetainedCameraTimecodeReadout(
                    retention = timecodeRetention,
                    sessionState = sessionState,
                    sizeSp = 15f,
                )
            }
            Spacer(Modifier.weight(1f))
            if (showsBattery) {
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
 * The portrait Fit/Fill key's glyph: iOS `arrow.up.left.and.arrow.down.right` when [expand] is
 * true (fit, tapping fills), `arrow.down.right.and.arrow.up.left` otherwise.
 */
@Composable
private fun FullScreenArrowsGlyph(
    tint: androidx.compose.ui.graphics.Color,
    expand: Boolean,
    modifier: Modifier = Modifier,
) {
    androidx.compose.foundation.Canvas(modifier) {
        val stroke = size.minDimension * 0.11f
        val head = size.minDimension * 0.26f
        val inset = size.minDimension * 0.06f
        val mid = size.minDimension * 0.42f
        fun arrow(tipX: Float, tipY: Float, tailX: Float, tailY: Float) {
            val path = androidx.compose.ui.graphics.Path().apply {
                moveTo(tailX, tailY)
                lineTo(tipX, tipY)
                // L-shaped barbs run back toward the tail along each axis.
                moveTo(tipX + (if (tailX > tipX) head else -head), tipY)
                lineTo(tipX, tipY)
                lineTo(tipX, tipY + (if (tailY > tipY) head else -head))
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
        val w = size.width
        val h = size.height
        if (expand) {
            arrow(inset, inset, mid, mid)
            arrow(w - inset, h - inset, w - mid, h - mid)
        } else {
            arrow(mid, mid, inset, inset)
            arrow(w - mid, h - mid, w - inset, h - inset)
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

/** Clearance between the battery row stack and the lock button above it (dp). */
internal const val BATTERY_STACK_CLEARANCE_DP = 10f

/**
 * Seats the stacked battery rows in the leading rail lane, directly under the
 * lock button (iOS parity). [anchor] is the zone map's phone-indicator frame —
 * it carries the lane's leading x.
 */
internal fun batteryRowStackFrame(anchor: ZoneFrame, lock: ZoneFrame): ZoneFrame =
    ZoneFrame(
        x = anchor.x,
        y = lock.y + lock.height + BATTERY_STACK_CLEARANCE_DP,
        width = BATTERY_STACK_WIDTH_DP,
        height = BATTERY_STACK_HEIGHT_DP,
    )

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

/** The next mode after [current] in the effective DISP order, wrapping. */
internal fun nextDisplayModeInOrder(
    order: List<MonitorDisplayMode>,
    current: MonitorDisplayMode,
): MonitorDisplayMode {
    if (order.isEmpty()) return current
    val index = order.indexOf(current)
    return if (index < 0) order.first() else order[(index + 1) % order.size]
}

// MARK: - Edit view (per-DISP chrome)

/**
 * The drawn bounds of the landscape rail column — settings, media, record and DISP. The zone map's
 * system cluster unions the top-left lock button in with these, which makes it span the whole
 * screen and useless as an outline; the lock carries its own badge anyway.
 */
private fun railColumnFrame(zones: MonitorZones): ZoneFrame {
    val column = listOf(zones.settings, zones.media, zones.record, zones.disp)
    val left = column.minOf { it.x }
    val top = column.minOf { it.y }
    val right = column.maxOf { it.x + it.width }
    val bottom = column.maxOf { it.y + it.height }
    return ZoneFrame(left, top, right - left, bottom - top)
}

/**
 * Marks a monitor element as editable: while the Edit view is open on a mode that owns [section],
 * the element is outlined, dimmed to 30% when hidden, and publishes its **drawn** bounds through
 * [onBounds] so the badge layer can place one eye on it. A no-op outside the editor.
 *
 * Bounds are measured, never taken from the zone map: a zone frame is a layout budget and several
 * elements draw inset within theirs, so an outline off the budget would highlight the wrong thing.
 * Mirrors iOS `ChromeEditable`.
 */
@Composable
internal fun Modifier.chromeEditable(
    section: ChromeSection,
    mode: MonitorDisplayMode?,
    settings: OperatorSettings,
    onBounds: (ChromeSection, Rect) -> Unit,
): Modifier {
    if (mode == null || !section.isConfigurableIn(mode)) return this
    val on = settings.chrome(mode)[section].value
    val outline =
        if (on) LiveDesign.accent.copy(alpha = 0.75f) else LiveDesign.muted.copy(alpha = 0.75f)
    return this
        .onGloballyPositioned { onBounds(section, it.boundsInRoot()) }
        // Drawn outside the alpha layer so a hidden element's outline stays readable at 30%.
        .drawWithContent {
            drawContent()
            drawRoundRect(
                color = outline,
                cornerRadius = CornerRadius(8.dp.toPx()),
                style =
                    Stroke(
                        width = 1.dp.toPx(),
                        pathEffect =
                            PathEffect.dashPathEffect(
                                floatArrayOf(3.dp.toPx(), 3.dp.toPx()),
                            ),
                    ),
            )
        }
        .alpha(if (on) 1f else 0.3f)
}

/**
 * Everything the Edit view puts on top of the monitor: one eye badge per measured element, and the
 * banner that names the mode and gets the operator back out.
 *
 * Placement comes from [ChromeEditLayout], which mirrors the core, so both shells agree.
 */
@Composable
private fun ChromeEditOverlay(
    mode: MonitorDisplayMode,
    boxes: Map<ChromeSection, Rect>,
    settings: OperatorSettings,
    /** The image area the banner centres on — not the screen; the rails sit outside it. */
    feed: ZoneFrame,
    /** Where the banner's bottom edge sits, in the same dp space as [feed]. */
    bannerBottomDp: Float,
    onDone: () -> Unit,
) {
    val density = LocalDensity.current
    BoxWithConstraints(Modifier.fillMaxSize()) {
        val widthDp = maxWidth.value
        val heightDp = maxHeight.value
        val placements =
            ChromeEditLayout.badgeFrames(
                ChromeSection.entries.mapNotNull { section ->
                    boxes[section]?.let { rect ->
                        with(density) {
                            ChromeEditBox(
                                section = section,
                                left = rect.left.toDp().value,
                                top = rect.top.toDp().value,
                                width = rect.width.toDp().value,
                                height = rect.height.toDp().value,
                            )
                        }
                    }
                },
                viewportWidth = widthDp,
                viewportHeight = heightDp,
            )
        placements.forEach { (section, placement) ->
            ChromeEditBadge(
                section = section,
                mode = mode,
                settings = settings,
                modifier = Modifier.offset(placement.left.dp, placement.top.dp),
            )
        }
        // Anchored by its BOTTOM edge and centred on the feed, so the banner's own height never
        // matters and it never lands on a badge (iOS `MonitorShell`'s banner overlay).
        Box(
            Modifier.absoluteOffset(feed.x.dp, feed.y.dp)
                .size(feed.width.dp, (bannerBottomDp - feed.y).coerceAtLeast(0f).dp),
            contentAlignment = Alignment.BottomCenter,
        ) {
            ChromeEditBanner(mode = mode, onDone = onDone)
        }
    }
}

/**
 * One eye badge. Tapping it shows or hides that element **for the DISP mode being edited**.
 *
 * A hidden element keeps rendering at 30% for as long as the editor is open, and keeps this badge,
 * which is the whole point: switching something off must never put it out of reach of switching
 * back on.
 */
@Composable
private fun ChromeEditBadge(
    section: ChromeSection,
    mode: MonitorDisplayMode,
    settings: OperatorSettings,
    modifier: Modifier = Modifier,
) {
    val on = settings.chrome(mode)[section].value
    val description = "${section.title}: ${if (on) "shown" else "hidden"}"
    Box(
        modifier
            // The 26dp disc is under the 48dp minimum and sits over live chrome, so the touch
            // target is grown around it rather than relying on the disc itself.
            .size(ChromeEditLayout.BADGE_SIZE_DP.dp)
            .background(
                if (on) LiveDesign.accent else Color.Black.copy(alpha = 0.9f),
                CircleShape,
            )
            .border(1.dp, LiveDesign.text.copy(alpha = 0.55f), CircleShape)
            .chromeClickable { settings.toggleChrome(section, mode) }
            .semantics { contentDescription = description },
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            imageVector = if (on) Icons.Filled.Visibility else Icons.Filled.VisibilityOff,
            contentDescription = null,
            tint = if (on) LiveDesign.background else LiveDesign.text,
            modifier = Modifier.size(14.dp),
        )
    }
}

/** Names the mode being edited and gets the operator back out (iOS `ChromeEditBanner`). */
@Composable
private fun ChromeEditBanner(
    mode: MonitorDisplayMode,
    onDone: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier
            .glass(CircleShape)
            .padding(start = 12.dp, end = 6.dp, top = 6.dp, bottom = 6.dp),
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column {
            Text(
                stringResource(
                    R.string.settings_chrome_edit_title,
                    stringResource(mode.labelResource()),
                ),
                style = chromeStyle(11.5f, FontWeight.SemiBold),
                color = LiveDesign.text,
            )
            Text(
                stringResource(R.string.settings_chrome_edit_hint),
                style = chromeStyle(10f, FontWeight.Normal),
                color = LiveDesign.muted,
            )
        }
        Text(
            stringResource(R.string.settings_chrome_edit_done),
            style = chromeStyle(11.5f, FontWeight.Bold),
            color = LiveDesign.background,
            modifier =
                Modifier.background(LiveDesign.accent, CircleShape)
                    .chromeClickable(onDone)
                    .padding(horizontal = 14.dp, vertical = 7.dp),
        )
    }
}

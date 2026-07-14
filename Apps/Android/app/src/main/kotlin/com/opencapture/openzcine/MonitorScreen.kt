package com.opencapture.openzcine

import android.widget.Toast
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
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.animation.core.animateFloatAsState
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.displayCutout
import com.opencapture.openzcine.bridge.MonitorZones
import com.opencapture.openzcine.bridge.SwiftCore
import com.opencapture.openzcine.bridge.SwiftCoreCameraSession
import com.opencapture.openzcine.bridge.ZoneFrame
import com.opencapture.openzcine.core.CameraRecordingException
import com.opencapture.openzcine.core.CameraRecordingState
import com.opencapture.openzcine.core.CameraSession
import com.opencapture.openzcine.core.CameraSessionState
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.currentStateAsState
import com.opencapture.openzcine.core.LiveFrameSource
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * Fake monitor readouts behind the state seam — mirrors the iOS demo state
 * (`CameraDisplayState.preview`) so side-by-side screenshots match. Real
 * values arrive with the session facade later.
 */
internal object DemoMonitorState {
    const val RESOLUTION = "6K·25p"
    const val CODEC = "R3D NE"
    const val MEDIA = "521 GB·47%"
    const val FPS = "25.00"
    const val FRAME_RATE = 25
    const val SIGNAL_BARS = 4
    const val CAMERA_BATTERY = 80
    const val PHONE_BATTERY = 84

    /** label / current value / widest value (fixes the cell width, iOS `widestValue`). */
    val VALUES =
        listOf(
            Triple("ISO", "800", "25600"),
            Triple("SHUTTER", "180°", "1/16000"),
            Triple("IRIS", "f/2.8", "f/2.8"),
            Triple("WB", "5600K", "5600K"),
            Triple("FOCUS", "AF-C", "Wide-L"),
        )
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
 * cycling incl. the command dashboard, and the portrait fit layout. Deferred:
 * pickers/panels, portrait fill aspect, command tile interaction.
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
    liveViewEnabled: Boolean = true,
    glassTierOverride: String? = null,
    onOpenSettings: () -> Unit = {},
    onOpenMedia: () -> Unit = {},
) {
    val appContext = LocalContext.current.applicationContext
    val sessionState by session.state.collectAsState()
    val monitorAccessibilityState =
        when (sessionState) {
            is CameraSessionState.Connected -> "Camera connected"
            CameraSessionState.Connecting -> "Camera connecting"
            CameraSessionState.Disconnected -> "Camera disconnected"
        }
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

    // Shell state, iOS-model-equivalent: DISP index (0 live, 1 clean,
    // 2 command), the interface lock, and the fake-clock timecode tick.
    // Recording is owned by the CameraSession; the shell only renders its
    // state and asks it to send a Nikon command.
    var dispIndex by remember { mutableIntStateOf(0) }
    var locked by remember { mutableStateOf(false) }
    val recordingState by session.recordingState.collectAsState()
    val recording =
        recordingState == CameraRecordingState.STARTING ||
            recordingState == CameraRecordingState.RECORDING
    val recordCommandPending =
        recordingState == CameraRecordingState.STARTING ||
            recordingState == CameraRecordingState.STOPPING
    val recordControlEnabled =
        sessionState is CameraSessionState.Connected && !recordCommandPending
    val recordScope = rememberCoroutineScope()
    val requestRecordToggle: () -> Unit = {
        if (recordControlEnabled) {
            recordScope.launch {
                try {
                    session.setRecording(!recording)
                } catch (error: CameraRecordingException) {
                    Toast.makeText(appContext, error.message, Toast.LENGTH_SHORT).show()
                }
            }
        }
    }
    var frameCount by remember { mutableLongStateOf(0L) }
    LaunchedEffect(Unit) {
        val startNanos = System.nanoTime()
        while (true) {
            delay(40)
            frameCount =
                (System.nanoTime() - startNanos) * DemoMonitorState.FRAME_RATE / 1_000_000_000L
        }
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
            edgeDp(cutout.getBottom(density), barInsets.bottom),
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

        // Same core call the iOS shell makes once per layout pass. The
        // landscape map is mode-invariant (iOS gates chrome shell-side), but
        // the portrait map encodes per-mode zones, so mode/scope key the map
        // alongside geometry.
        val scopeCount = if (assist.scope != null) 1 else 0
        val zones =
            remember(
                viewportWidth, viewportHeight, safeTop, safeLeading, safeBottom, safeTrailing,
                isPortrait, dispIndex, scopeCount,
            ) {
                MonitorZones.parse(
                    SwiftCore.monitorZoneMap(
                        viewportWidth = viewportWidth,
                        viewportHeight = viewportHeight,
                        safeTop = safeTop,
                        safeLeading = safeLeading,
                        safeBottom = safeBottom,
                        safeTrailing = safeTrailing,
                        mode = dispIndex,
                        isPortrait = isPortrait,
                        aspectFill = false,
                        scopeCount = scopeCount,
                        mirrored = false,
                        bottomBarHeight = LiveDesign.CONTROL_HEIGHT_DP,
                    ),
                )
            }
        val isClean = dispIndex == 1
        val isCommand = dispIndex == 2

        // An explicit demo source wins; otherwise a connected Swift-core
        // session streams its own live view. Media ownership gates collection,
        // and backgrounding drops below STARTED so the camera receives
        // EndLiveView instead of continuing sensor readout for no consumer.
        val lifecycleState by LocalLifecycleOwner.current.lifecycle.currentStateAsState()
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

        // Backdrop geometry for the glass pipeline: the viewport and the feed
        // zone in root px. The blurred texture covers the whole viewport
        // (black letterbox included), so pills over black sample the same
        // map. setLayout is idempotent per geometry, so calling it on every
        // recomposition is free.
        with(density) {
            glass.backdrop.setLayout(
                rootWidthPx = constraints.maxWidth.toFloat(),
                rootHeightPx = constraints.maxHeight.toFloat(),
                feedRectPx =
                    android.graphics.RectF(
                        zones.feed.x.dp.toPx(),
                        zones.feed.y.dp.toPx(),
                        (zones.feed.x + zones.feed.width).dp.toPx(),
                        (zones.feed.y + zones.feed.height).dp.toPx(),
                    ),
            )
        }

        // Feed at the zone map's feed frame; LiveFeedView aspect-fits within
        // it. Command (DISP 3) unmounts the feed behind the dashboard, iOS
        // semantics.
        if (!isCommand) {
            Box(Modifier.zone(zones.feed), contentAlignment = Alignment.Center) {
                if (activeFrameSource != null) {
                    LiveFeedView(
                        activeFrameSource,
                        Modifier.fillMaxSize(),
                        onFrame = glass::submit,
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
            }
        }

        CompositionLocalProvider(LocalMonitorGlass provides glass) {
            if (isPortrait) {
                PortraitChrome(
                    zones = zones,
                    viewportHeight = viewportHeight,
                    isCommand = isCommand,
                    locked = locked,
                    recording = recording,
                    frameCount = frameCount,
                    assist = assist,
                    dispIndex = dispIndex,
                    onLock = { locked = !locked },
                    recordEnabled = recordControlEnabled,
                    onRecord = requestRecordToggle,
                    onDisp = { dispIndex = (dispIndex + 1) % 3 },
                    onOpenMedia = onOpenMedia,
                    onOpenSettings = onOpenSettings,
                )
            } else {
                if (isCommand) {
                    // The DISP 3 dashboard fills the deck span between the
                    // rails on the warm command background (iOS CommandMonitor).
                    Box(Modifier.fillMaxSize().background(LiveDesign.background))
                    val top = maxOf(14f, safeTop)
                    CommandDashboard(
                        recording = recording,
                        frameCount = frameCount,
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
                    Box(Modifier.zone(zones.infoBar), contentAlignment = Alignment.Center) {
                        FitScale(zones.infoBar.width.dp) {
                            InfoPill(compact = isClean, recording = recording, frameCount = frameCount)
                        }
                    }

                    // Bottom bars — live mode only, dimmed while locked: the
                    // assist toolbar at its zone, and the capture strip whose
                    // glass hugs its readouts against the band's trailing edge
                    // like the iOS content-hugging strip.
                    if (!isClean) {
                        zones.assistStrip?.let { strip ->
                            AssistToolbar(
                                assist,
                                Modifier.zone(strip).alpha(if (locked) 0.4f else 1f),
                            )
                        }
                        zones.captureStrip?.let { strip ->
                            Box(
                                Modifier.zone(strip).alpha(if (locked) 0.4f else 1f),
                                contentAlignment = Alignment.CenterEnd,
                            ) {
                                FitScale(strip.width.dp) { CaptureStrip() }
                            }
                        }
                    }
                }

                // Side rails: lock + battery indicators + record / DISP /
                // media / settings — mounted in every mode, like iOS.
                LockButton(locked, Modifier.zone(zones.lock)) { locked = !locked }
                zones.batteryPhone?.let {
                    BatteryIndicatorColumn(
                        percent = DemoMonitorState.PHONE_BATTERY,
                        isCamera = false,
                        modifier = Modifier.zone(it),
                    )
                }
                zones.batteryCamera?.let {
                    BatteryIndicatorColumn(
                        percent = DemoMonitorState.CAMERA_BATTERY,
                        isCamera = true,
                        modifier = Modifier.zone(it),
                    )
                }
                AuxCircleButton(
                    Modifier.zone(zones.settings),
                    onClick = onOpenSettings,
                ) { glyphModifier, tint ->
                    GearGlyph(tint, glyphModifier)
                }
                AuxCircleButton(
                    Modifier.zone(zones.media),
                    onClick = onOpenMedia,
                ) { glyphModifier, tint ->
                    MediaStackGlyph(tint, glyphModifier)
                }
                RecordButton(
                    recording = recording,
                    modifier = Modifier.zone(zones.record),
                    enabled = recordControlEnabled,
                    onClick = requestRecordToggle,
                )
                DispButton(
                    activeIndex = dispIndex,
                    modeCount = 3, // Live / Clean / Command, matching iOS.
                    modifier = Modifier.zone(zones.disp),
                ) {
                    dispIndex = (dispIndex + 1) % 3
                }
            }
        }
        // Scope panel: toolbar-toggled (seeded by `--es zc.scopes`). Landscape
        // floats it over the feed (the map carries no scopes zone there);
        // portrait mounts the stacked zone the map emits (fit + live only).
        val activeScope = assist.scope
        if (!isCommand && activeScope != null && activeFrameSource != null) {
            val scopeFrame =
                if (isPortrait) {
                    zones.scopes?.let {
                        ZoneFrame(it.x + 12f, it.y, it.width - 24f, it.height)
                    }
                } else {
                    zones.scopes ?: floatingScopeFrame(activeScope, zones.feed, zones.infoBar)
            }
            scopeFrame?.let { ScopePanel(activeScope, activeFrameSource, Modifier.zone(it)) }
        }

        // Recording tally border at the physical edge (iOS `RecordingBorderModule`).
        if (recording) {
            Box(
                Modifier.fillMaxSize()
                    .border(4.dp, LiveDesign.rec, RoundedCornerShape(24.dp)),
            )
        }
    }
}

/** The landscape top deck (iOS `MonitorInfoBar` `.infoPill`). */
@Composable
private fun InfoPill(compact: Boolean, recording: Boolean, frameCount: Long) {
    Row(
        modifier = Modifier.glass(ChromeShape).padding(horizontal = 12.dp, vertical = 6.dp),
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        RecordChip(recording)
        Text(
            timecodeAnnotated(frameCount, DemoMonitorState.FRAME_RATE),
            style = chromeStyle(20f, FontWeight.Medium, mono = true),
            maxLines = 1,
        )
        if (!compact) {
            ReadoutPill(DemoMonitorState.RESOLUTION) { VideoGlyph(LiveDesign.muted) }
            ReadoutPill(DemoMonitorState.CODEC) { FilmGlyph(LiveDesign.muted) }
            ReadoutPill(DemoMonitorState.MEDIA) { SdCardGlyph(LiveDesign.muted) }
        }
        FpsChip(DemoMonitorState.SIGNAL_BARS, DemoMonitorState.FPS)
    }
}

/**
 * The portrait chrome tree, every region at its zone-map frame (iOS
 * `portraitShell`): full-width top bar, fit-mode assist toolbar + tile grid
 * (or the command timecode band + grid), stacked scopes (mounted by the
 * caller), and the bottom system band. The fill aspect (capture strip over
 * the feed + vertical assist rail) is deferred with the aspect toggle.
 */
@Composable
private fun PortraitChrome(
    zones: MonitorZones,
    viewportHeight: Float,
    isCommand: Boolean,
    locked: Boolean,
    recording: Boolean,
    frameCount: Long,
    assist: AssistState,
    dispIndex: Int,
    onLock: () -> Unit,
    recordEnabled: Boolean,
    onRecord: () -> Unit,
    onDisp: () -> Unit,
    onOpenMedia: () -> Unit,
    onOpenSettings: () -> Unit,
) {
    PortraitInfoBar(frameCount, Modifier.zone(zones.infoBar))

    // Fit-mode horizontal assist toolbar between the scopes zone and the tile
    // grid (live only — the map emits the zone). 12/4dp insets float the
    // glass pill off the screen edges, like iOS.
    if (!isCommand) {
        zones.assistStrip?.let { strip ->
            AssistToolbar(
                assist,
                Modifier.zone(
                    ZoneFrame(strip.x + 12f, strip.y + 4f, strip.width - 24f, strip.height - 8f),
                ).alpha(if (locked) 0.4f else 1f),
            )
        }
    }

    // Controls zone: fit-mode live tiles, or the command hero-timecode band +
    // grid (iOS reserves 80pt off the top of the tile region for it).
    zones.controlsGrid?.takeIf { it.height > 0 }?.let { grid ->
        val tcBand = if (isCommand) 80f else 0f
        if (isCommand) {
            Box(
                Modifier.zone(ZoneFrame(grid.x, grid.y, grid.width, tcBand))
                    .padding(horizontal = 12.dp),
                contentAlignment = Alignment.Center,
            ) {
                CommandTimecode(frameCount, sizeSp = 52f)
            }
        }
        CommandGrid(
            Modifier.zone(
                ZoneFrame(
                    grid.x,
                    grid.y + tcBand,
                    grid.width,
                    maxOf(0f, grid.height - tcBand - (if (isCommand) 0f else 8f)),
                ),
            )
                .padding(horizontal = 12.dp)
                .alpha(if (locked) 0.4f else 1f),
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
            activeIndex = dispIndex,
            modeCount = 3,
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
private fun PortraitInfoBar(frameCount: Long, modifier: Modifier = Modifier) {
    Box(modifier.background(LiveDesign.glass).padding(horizontal = 16.dp)) {
        Text(
            DemoMonitorState.MEDIA,
            style = chromeStyle(13f, FontWeight.Medium),
            color = LiveDesign.muted,
            maxLines = 1,
            modifier = Modifier.align(Alignment.Center),
        )
        Row(Modifier.fillMaxSize(), verticalAlignment = Alignment.CenterVertically) {
            Text(
                timecodeAnnotated(frameCount, DemoMonitorState.FRAME_RATE),
                style = chromeStyle(15f, FontWeight.Normal, mono = true),
                maxLines = 1,
            )
            Spacer(Modifier.weight(1f))
            Row(
                horizontalArrangement = Arrangement.spacedBy(5.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                BatteryGlyph(
                    DemoMonitorState.CAMERA_BATTERY,
                    LiveDesign.accent,
                    Modifier.size(22.dp, 11.dp),
                )
                Text(
                    "${DemoMonitorState.CAMERA_BATTERY}%",
                    style = chromeStyle(10.5f, FontWeight.Medium, mono = true),
                    color = LiveDesign.text.copy(alpha = 0.72f),
                )
                CameraGlyph(LiveDesign.muted, Modifier.size(15.dp, 12.dp))
            }
        }
    }
}

/** The ISO/SHUTTER/IRIS/WB/FOCUS readout bar (iOS `MonitorCaptureStrip`, landscape). */
@Composable
private fun CaptureStrip() {
    Row(
        modifier =
            Modifier.height(LiveDesign.CONTROL_HEIGHT_DP.dp)
                .glass(ChromeShape)
                .padding(horizontal = 12.dp, vertical = 4.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        DemoMonitorState.VALUES.forEach { (label, value, widest) ->
            CaptureSettingCell(label, value, widest)
        }
    }
}

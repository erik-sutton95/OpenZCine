package com.opencapture.openzcine

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
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.platform.LocalView
import androidx.compose.animation.core.animateFloatAsState
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.displayCutout
import com.opencapture.openzcine.bridge.MonitorZones
import com.opencapture.openzcine.bridge.SwiftCore
import com.opencapture.openzcine.bridge.ZoneFrame
import com.opencapture.openzcine.core.CameraSession
import com.opencapture.openzcine.core.CameraSessionState
import com.opencapture.openzcine.core.LiveFrameSource
import kotlinx.coroutines.delay

/**
 * Fake monitor readouts behind the state seam — mirrors the iOS demo state
 * (`CameraDisplayState.preview`) so side-by-side screenshots match. Real
 * values arrive with the session facade later.
 */
private object DemoMonitorState {
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
private fun Modifier.zone(frame: ZoneFrame): Modifier =
    offset(frame.x.dp, frame.y.dp).size(frame.width.dp, frame.height.dp)

/** Unwraps the owning [android.app.Activity] (a ComposeView's context is a wrapper). */
private tailrec fun android.content.Context.findActivity(): android.app.Activity? =
    when (this) {
        is android.app.Activity -> this
        is android.content.ContextWrapper -> baseContext.findActivity()
        else -> null
    }

/**
 * The landscape monitor shell — a 1:1 port of the iOS `MonitorShell`
 * (ios/Runner/MonitorUnified.swift) landscape branch, laid out by the SAME
 * shared-core zone map via [SwiftCore.monitorZoneMap].
 *
 * v1 scope: feed, top info pill, lock/battery band, capture strip, record /
 * DISP / media / settings rail, DISP 1↔2 cycling. Deferred: the assist
 * toolbar zone (skipped — its capture-strip sibling renders at its own zone),
 * scopes, pickers/panels, portrait.
 */
@Composable
fun MonitorScreen(session: CameraSession, frameSource: LiveFrameSource?) {
    val sessionState by session.state.collectAsState()
    LaunchedEffect(session) { session.connect() }

    // Shell state, iOS-model-equivalent: DISP index (0 live, 1 clean), the
    // interface lock, the record toggle, and the fake-clock timecode tick.
    var dispIndex by remember { mutableIntStateOf(0) }
    var locked by remember { mutableStateOf(false) }
    var recording by remember { mutableStateOf(false) }
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
        val safeLeading by animateFloatAsState(
            edgeDp(cutout.getLeft(density, direction), barInsets.left),
            label = "safeLeading",
        )
        val safeTrailing =
            with(density) { cutout.getRight(this, direction).toDp().value }
        val navLane by animateFloatAsState(
            with(density) {
                maxOf(0, barInsets.right - cutout.getRight(this, direction)).toDp().value
            },
            label = "navLane",
        )
        val viewportWidth = maxWidth.value - navLane
        val viewportHeight = maxHeight.value

        // Same core call the iOS shell makes once per layout pass. The
        // landscape map is mode-invariant (iOS gates chrome shell-side), so
        // the map is keyed on geometry only.
        val zones =
            remember(viewportWidth, viewportHeight, safeTop, safeLeading, safeBottom, safeTrailing) {
                MonitorZones.parse(
                    SwiftCore.monitorZoneMap(
                        viewportWidth = viewportWidth,
                        viewportHeight = viewportHeight,
                        safeTop = safeTop,
                        safeLeading = safeLeading,
                        safeBottom = safeBottom,
                        safeTrailing = safeTrailing,
                        mode = dispIndex,
                        isPortrait = false,
                        aspectFill = false,
                        scopeCount = 0,
                        mirrored = false,
                        bottomBarHeight = LiveDesign.CONTROL_HEIGHT_DP,
                    ),
                )
            }
        val isClean = dispIndex == 1

        // Feed at the zone map's feed frame; LiveFeedView aspect-fits within it.
        Box(Modifier.zone(zones.feed), contentAlignment = Alignment.Center) {
            if (frameSource != null) {
                LiveFeedView(frameSource, Modifier.fillMaxSize())
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

        // Top info pill, centered in the deck band; compact in clean mode.
        // The core anchors the deck to the feed, and iPhones always carry a
        // landscape island inset that starts the feed right of the lock; this
        // device's sub-50dp cutout resolves to no inset, so the raw band would
        // run under the lock. Clamp the band's leading edge past the lock —
        // on iPhone-style geometry (deck.x > lock.maxX) this is a no-op.
        val pillBand =
            zones.infoBar.let { deck ->
                val leading = maxOf(deck.x, zones.lock.x + zones.lock.width + 8f)
                ZoneFrame(leading, deck.y, deck.width - (leading - deck.x), deck.height)
            }
        Box(Modifier.zone(pillBand), contentAlignment = Alignment.Center) {
            FitScale(pillBand.width.dp) {
                InfoPill(compact = isClean, recording = recording, frameCount = frameCount)
            }
        }

        // Bottom capture strip — live mode only, dimmed while locked; the
        // glass hugs its readouts against the band's trailing edge like the
        // iOS content-hugging strip. The assist toolbar zone to its left is
        // deferred (v1 skips assists).
        if (!isClean) {
            zones.captureStrip?.let { strip ->
                Box(
                    Modifier.zone(strip).alpha(if (locked) 0.4f else 1f),
                    contentAlignment = Alignment.CenterEnd,
                ) {
                    FitScale(strip.width.dp) { CaptureStrip() }
                }
            }
        }

        // Side rails: lock + battery indicators + record / DISP / media / settings.
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
        AuxCircleButton(Modifier.zone(zones.settings)) { glyphModifier, tint ->
            GearGlyph(tint, glyphModifier)
        }
        AuxCircleButton(Modifier.zone(zones.media)) { glyphModifier, tint ->
            MediaStackGlyph(tint, glyphModifier)
        }
        RecordButton(recording, Modifier.zone(zones.record)) { recording = !recording }
        DispButton(
            activeIndex = dispIndex,
            modeCount = 3, // Live / Clean / Command dashes, matching iOS; Command lands later.
            modifier = Modifier.zone(zones.disp),
        ) {
            dispIndex = (dispIndex + 1) % 2
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

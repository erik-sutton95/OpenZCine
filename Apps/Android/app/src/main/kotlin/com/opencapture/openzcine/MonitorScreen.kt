package com.opencapture.openzcine

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
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
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.displayCutout
import androidx.compose.foundation.layout.systemBars
import androidx.compose.foundation.layout.union
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
    const val SIGNAL_BARS = 0
    const val CAMERA_BATTERY = 80
    const val PHONE_BATTERY = 84
    val VALUES =
        listOf(
            "ISO" to "800",
            "SHUTTER" to "180°",
            "IRIS" to "f/2.8",
            "WB" to "5600K",
            "FOCUS" to "AF-C",
        )
}

/** Places a composable at an absolute zone frame (full-viewport dp coordinates). */
private fun Modifier.zone(frame: ZoneFrame): Modifier =
    offset(frame.x.dp, frame.y.dp).size(frame.width.dp, frame.height.dp)

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

    BoxWithConstraints(Modifier.fillMaxSize().background(Color.Black)) {
        val density = LocalDensity.current
        val direction = LocalLayoutDirection.current
        val safe = WindowInsets.systemBars.union(WindowInsets.displayCutout)
        val safeTop = with(density) { safe.getTop(this).toDp().value }
        val safeBottom = with(density) { safe.getBottom(this).toDp().value }
        val safeLeading = with(density) { safe.getLeft(this, direction).toDp().value }
        val safeTrailing = with(density) { safe.getRight(this, direction).toDp().value }
        val viewportWidth = maxWidth.value
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
        Box(Modifier.zone(zones.infoBar), contentAlignment = Alignment.Center) {
            InfoPill(compact = isClean, recording = recording, frameCount = frameCount)
        }

        // Bottom capture strip — live mode only, dimmed while locked. The
        // assist toolbar zone to its left is deferred (v1 skips assists).
        if (!isClean) {
            zones.captureStrip?.let { strip ->
                Box(Modifier.zone(strip).alpha(if (locked) 0.4f else 1f)) {
                    CaptureStrip()
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
            Modifier.fillMaxSize()
                .glass(ChromeShape)
                .padding(horizontal = 12.dp, vertical = 4.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        DemoMonitorState.VALUES.forEach { (label, value) -> CaptureSettingCell(label, value) }
    }
}

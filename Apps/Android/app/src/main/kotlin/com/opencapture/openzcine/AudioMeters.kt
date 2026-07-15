package com.opencapture.openzcine

import android.content.Context
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.opencapture.openzcine.bridge.ZoneFrame
import com.opencapture.openzcine.core.LiveAudioMeterChannel
import com.opencapture.openzcine.core.LiveAudioMeterLevels
import kotlin.math.max
import kotlin.math.min

private const val AUDIO_METER_PANEL_WIDTH = 28f
private const val AUDIO_METER_DEBUG_PANEL_WIDTH = 104f
private const val AUDIO_METER_PANEL_HEIGHT = 168f
private const val AUDIO_METER_FLOOR_DB = -60.0
private const val AUDIO_METER_YELLOW_DB = -18.0
private const val AUDIO_METER_RED_DB = -6.0
private const val AUDIO_PANEL_EDGE_GAP = 10f
private const val AUDIO_PANEL_BOTTOM_CHROME_CLEARANCE = 14f + LiveDesign.CONTROL_HEIGHT_DP

/** Physical panel footprint; the wider size is reserved for the debug-only provenance label. */
internal fun audioMeterPanelSize(isDebugFixture: Boolean): Pair<Float, Float> =
    (if (isDebugFixture) AUDIO_METER_DEBUG_PANEL_WIDTH else AUDIO_METER_PANEL_WIDTH) to
        AUDIO_METER_PANEL_HEIGHT

/**
 * Floating camera-audio panel for landscape and portrait-fill monitors.
 *
 * This mirrors the iOS audio meter's bottom-trailing default and normalized
 * drag persistence. Portrait fit suppresses floating panels; portrait fill
 * clamps them to the shared visible feed zone. Playback may mount the panel
 * against the exact aspect-fit video rectangle.
 */
@Composable
internal fun AudioMetersOverlay(
    levels: LiveAudioMeterLevels?,
    sensitivity: String?,
    feed: ZoneFrame,
    viewport: ZoneFrame,
    placementStoreName: String = "audioMeterPlacement",
    bottomChromeClearance: Float = AUDIO_PANEL_BOTTOM_CHROME_CLEARANCE,
    trailingEdgeGap: Float = AUDIO_PANEL_EDGE_GAP,
) {
    val context = LocalContext.current.applicationContext
    val store =
        remember(context, placementStoreName) {
            AudioMeterPlacementStore(context, placementStoreName)
        }
    val isDebugFixture = levels?.isDebugFixture == true
    val (width, height) = audioMeterPanelSize(isDebugFixture)
    val default =
        floatingAudioMeterFrame(
            feed,
            viewport,
            width,
            height,
            bottomChromeClearance,
            trailingEdgeGap,
        )
    var frame by remember(default, viewport) { mutableStateOf(store.resolve(default, viewport)) }
    val density = LocalDensity.current

    AudioMetersPanel(
        levels = levels,
        sensitivity = sensitivity,
        modifier =
            Modifier
                .zone(frame)
                .pointerInput(viewport, width, height) {
                    detectDragGestures(
                        onDragEnd = { store.save(frame, viewport) },
                    ) { change, dragAmount ->
                        change.consume()
                        frame =
                            clampScopeFrame(
                                frame.copy(
                                    x = frame.x + dragAmount.x / density.density,
                                    y = frame.y + dragAmount.y / density.density,
                                ),
                                viewport,
                            )
                    }
                },
    )
}

/** Bottom-trailing iOS-equivalent default, constrained to the physical viewport. */
internal fun floatingAudioMeterFrame(
    feed: ZoneFrame,
    viewport: ZoneFrame,
    width: Float,
    height: Float,
    bottomChromeClearance: Float = AUDIO_PANEL_BOTTOM_CHROME_CLEARANCE,
    trailingEdgeGap: Float = AUDIO_PANEL_EDGE_GAP,
): ZoneFrame {
    val bottomEdge =
        min(
            feed.y + feed.height,
            viewport.y + viewport.height - bottomChromeClearance.coerceAtLeast(0f),
        )
    return clampScopeFrame(
        ZoneFrame(
            x = feed.x + feed.width - width - trailingEdgeGap.coerceAtLeast(0f),
            y = bottomEdge - height - AUDIO_PANEL_EDGE_GAP,
            width = width,
            height = height,
        ),
        viewport,
    )
}

/** Compose panel mirroring iOS's compact two-channel dBFS meter. */
@Composable
private fun AudioMetersPanel(
    levels: LiveAudioMeterLevels?,
    sensitivity: String?,
    modifier: Modifier = Modifier,
) {
    val isDebugFixture = levels?.isDebugFixture == true
    Column(
        modifier =
            modifier
                .background(Color(0xBA060907), ChromeShape)
                .border(1.dp, LiveDesign.hairline, ChromeShape)
                .clipToBounds()
                .padding(horizontal = 3.dp, vertical = 7.dp)
                .semantics {
                    contentDescription = "Audio Levels"
                    stateDescription = audioMeterStateDescription(levels, sensitivity)
                },
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        androidx.compose.material3.Text(
            "AUDIO",
            style = chromeStyle(6f, FontWeight.Bold, mono = true),
            color = LiveDesign.text.copy(alpha = 0.58f),
            maxLines = 1,
        )
        Box(
            Modifier.weight(1f).fillMaxWidth(),
            contentAlignment = Alignment.Center,
        ) {
            Canvas(Modifier.fillMaxSize()) { drawAudioMeters(levels) }
            if (levels == null) {
                androidx.compose.material3.Text(
                    "NO\nDATA",
                    style = chromeStyle(6f, FontWeight.Bold, mono = true),
                    color = LiveDesign.muted.copy(alpha = 0.74f),
                )
            }
        }
        if (isDebugFixture) {
            androidx.compose.material3.Text(
                "DEBUG FIXTURE —\nNOT CAMERA AUDIO",
                style = chromeStyle(6f, FontWeight.Bold, mono = true),
                color = LiveDesign.accent.copy(alpha = 0.88f),
                maxLines = 2,
            )
        } else {
            androidx.compose.material3.Text(
                "SENS",
                style = chromeStyle(5f, FontWeight.SemiBold, mono = true),
                color = LiveDesign.text.copy(alpha = 0.42f),
                maxLines = 1,
            )
            androidx.compose.material3.Text(
                displayedAudioSensitivity(sensitivity),
                style = chromeStyle(8f, FontWeight.Bold, mono = true),
                color = LiveDesign.text.copy(alpha = 0.72f),
                maxLines = 1,
            )
        }
    }
}

/** iOS-equivalent sensitivity label fallback. */
internal fun displayedAudioSensitivity(value: String?): String =
    value?.trim()?.takeIf(String::isNotEmpty)?.uppercase() ?: "—"

/** TalkBack-facing readout; fixture provenance is explicit rather than implied by moving bars. */
internal fun audioMeterStateDescription(
    levels: LiveAudioMeterLevels?,
    sensitivity: String?,
): String {
    if (levels == null) {
        return "Camera audio level unavailable, sensitivity ${displayedAudioSensitivity(sensitivity)}."
    }
    fun channel(name: String, value: LiveAudioMeterChannel): String =
        if (value.levelDb <= AUDIO_METER_FLOOR_DB + 0.5) {
            "$name silent"
        } else {
            "$name %.0f dB, peak %.0f".format(value.levelDb, value.peakDb)
        }
    return buildString {
        append(channel("left", levels.left))
        append(", ")
        append(channel("right", levels.right))
        append(", sensitivity ")
        append(displayedAudioSensitivity(sensitivity))
        if (levels.isDebugFixture) append(", debug fixture, not camera audio")
    }
}

/** Draws the two level bars directly from Swift-provided dBFS values. */
private fun DrawScope.drawAudioMeters(levels: LiveAudioMeterLevels?) {
    val visualWidth = min(22.dp.toPx(), max(0f, size.width - 2.dp.toPx()))
    if (visualWidth <= 0f || size.height <= 0f) return
    val left = (size.width - visualWidth) / 2f
    val bars = Rect(left, 2.dp.toPx(), left + visualWidth, size.height - 2.dp.toPx())
    val gap = 2.dp.toPx()
    val barWidth = max(1f, (bars.width - gap) / 2f)
    val green = Color(0xE656EB84)
    val yellow = Color(0xF5F5D052)
    val red = Color(0xF5FF5C52)

    fun y(db: Double): Float {
        val fraction = ((db.coerceIn(AUDIO_METER_FLOOR_DB, 0.0) - AUDIO_METER_FLOOR_DB) /
            -AUDIO_METER_FLOOR_DB).toFloat()
        return bars.bottom - fraction * bars.height
    }

    listOf(0.0, AUDIO_METER_RED_DB, AUDIO_METER_YELLOW_DB, -36.0).forEach { mark ->
        drawLine(
            LiveDesign.text.copy(alpha = 0.10f),
            Offset(bars.left, y(mark)),
            Offset(bars.right, y(mark)),
            strokeWidth = 1.dp.toPx(),
        )
    }

    val channels = listOf(levels?.left, levels?.right)
    channels.forEachIndexed { index, channel ->
        val track =
            Rect(
                left = bars.left + index * (barWidth + gap),
                top = bars.top,
                right = bars.left + index * (barWidth + gap) + barWidth,
                bottom = bars.bottom,
            )
        drawRoundRect(
            LiveDesign.text.copy(alpha = 0.08f),
            topLeft = track.topLeft,
            size = track.size,
            cornerRadius = CornerRadius(2.dp.toPx()),
        )
        if (channel == null) return@forEachIndexed

        val levelTop = y(channel.levelDb)
        fun drawFilledZone(highDb: Double, lowDb: Double, color: Color) {
            val top = max(levelTop, y(highDb))
            val bottom = y(lowDb)
            if (top < bottom) {
                drawRect(
                    color,
                    topLeft = Offset(track.left, top),
                    size = Size(track.width, bottom - top),
                )
            }
        }
        drawFilledZone(0.0, AUDIO_METER_RED_DB, red)
        drawFilledZone(AUDIO_METER_RED_DB, AUDIO_METER_YELLOW_DB, yellow)
        drawFilledZone(AUDIO_METER_YELLOW_DB, AUDIO_METER_FLOOR_DB, green)
        val peakY = y(max(channel.levelDb, channel.peakDb))
        drawLine(
            LiveDesign.text.copy(alpha = 0.92f),
            Offset(track.left - 1.dp.toPx(), peakY),
            Offset(track.right + 1.dp.toPx(), peakY),
            strokeWidth = 1.5.dp.toPx(),
        )
    }
}

/** Current Android equivalent of iOS's persisted movable audio-panel centre. */
private class AudioMeterPlacementStore(context: Context, name: String) {
    private val preferences = context.getSharedPreferences(name, Context.MODE_PRIVATE)

    fun resolve(default: ZoneFrame, bounds: ZoneFrame): ZoneFrame {
        if (!preferences.contains(CENTER_X_KEY) || !preferences.contains(CENTER_Y_KEY)) return default
        val normalizedX = preferences.getFloat(CENTER_X_KEY, 0.5f)
        val normalizedY = preferences.getFloat(CENTER_Y_KEY, 0.5f)
        if (!normalizedX.isFinite() || !normalizedY.isFinite()) return default
        return clampScopeFrame(
            ZoneFrame(
                x = bounds.x + normalizedX * bounds.width - default.width / 2f,
                y = bounds.y + normalizedY * bounds.height - default.height / 2f,
                width = default.width,
                height = default.height,
            ),
            bounds,
        )
    }

    fun save(frame: ZoneFrame, bounds: ZoneFrame) {
        val centerX = (frame.x + frame.width / 2f - bounds.x) / max(1f, bounds.width)
        val centerY = (frame.y + frame.height / 2f - bounds.y) / max(1f, bounds.height)
        preferences.edit()
            .putFloat(CENTER_X_KEY, centerX.coerceIn(0f, 1f))
            .putFloat(CENTER_Y_KEY, centerY.coerceIn(0f, 1f))
            .apply()
    }

    private companion object {
        const val CENTER_X_KEY = "audio.centerX"
        const val CENTER_Y_KEY = "audio.centerY"
    }
}

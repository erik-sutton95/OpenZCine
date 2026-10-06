package com.opencapture.openzcine

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalResources
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.opencapture.monitorui.MonitorAudioMeter
import com.opencapture.monitorui.MonitorAudioOrientation
import com.opencapture.monitorui.MonitorRect
import com.opencapture.monitorui.MonitorScopeSize
import com.opencapture.monitorui.MonitorScopeStoredCenter
import com.opencapture.opencine.nikon.LiveAudioMeterChannel
import com.opencapture.opencine.nikon.LiveAudioMeterLevels
import kotlin.math.min

private const val AUDIO_METER_PANEL_WIDTH = 28f
private const val AUDIO_METER_DEBUG_PANEL_WIDTH = 104f
private const val AUDIO_METER_PANEL_HEIGHT = 168f
private const val AUDIO_METER_FLOOR_DB = -60.0
private const val AUDIO_PANEL_EDGE_GAP = 10f
private const val AUDIO_PANEL_BOTTOM_CHROME_CLEARANCE = 14f + LiveDesign.CONTROL_HEIGHT_DP

/** Physical panel footprint; the wider size is reserved for the debug-only provenance label. */
internal fun audioMeterPanelSize(isDebugFixture: Boolean): Pair<Float, Float> =
    (if (isDebugFixture) AUDIO_METER_DEBUG_PANEL_WIDTH else AUDIO_METER_PANEL_WIDTH) to
        AUDIO_METER_PANEL_HEIGHT

/**
 * Floating camera-audio panel for landscape and portrait-fill monitors and playback: the shared
 * movable panel and meter, with the camera's microphone sensitivity under the bars, the no-data
 * state, debug-fixture provenance and the spoken readout. Unplaced, it sits bottom-trailing (iOS).
 */
@Composable
internal fun AudioMetersOverlay(
    levels: LiveAudioMeterLevels?,
    sensitivity: String?,
    feed: MonitorRect,
    panelLayout: MonitorAnalysisPanelLayout,
    stored: MonitorScopeStoredCenter?,
    onStore: (MonitorScopeStoredCenter) -> Unit,
    hapticsEnabled: Boolean = true,
    bottomChromeClearance: Float = AUDIO_PANEL_BOTTOM_CHROME_CLEARANCE,
    trailingEdgeGap: Float = AUDIO_PANEL_EDGE_GAP,
) {
    val (width, height) = audioMeterPanelSize(levels?.isDebugFixture == true)
    val default =
        floatingAudioMeterFrame(feed, panelLayout.viewport, width, height, bottomChromeClearance, trailingEdgeGap)
    MovableMonitorPanel(
        identity = "audio",
        base = MonitorScopeSize(width, height),
        panelLayout = panelLayout,
        stored = stored,
        onStore = onStore,
        hapticsEnabled = hapticsEnabled,
        defaultFrame = default,
    ) { modifier -> AudioMetersPanel(levels, sensitivity, modifier) }
}

/** Bottom-trailing iOS-equivalent default, constrained to the physical viewport. */
internal fun floatingAudioMeterFrame(
    feed: MonitorRect,
    viewport: MonitorRect,
    width: Float,
    height: Float,
    bottomChromeClearance: Float = AUDIO_PANEL_BOTTOM_CHROME_CLEARANCE,
    trailingEdgeGap: Float = AUDIO_PANEL_EDGE_GAP,
): MonitorRect {
    val bottomEdge =
        min(
            feed.y + feed.height,
            viewport.y + viewport.height - bottomChromeClearance.coerceAtLeast(0f),
        )
    return clampScopeFrame(
        MonitorRect(
            x = feed.x + feed.width - width - trailingEdgeGap.coerceAtLeast(0f),
            y = bottomEdge - height - AUDIO_PANEL_EDGE_GAP,
            width = width,
            height = height,
        ),
        viewport,
    )
}

/** The shared two-channel meter over the Swift dBFS levels, with Nikon's caption under it. */
@Composable
private fun AudioMetersPanel(
    levels: LiveAudioMeterLevels?,
    sensitivity: String?,
    modifier: Modifier = Modifier,
) {
    val resources = LocalResources.current
    val strings = remember(resources) { resources.phoneStringResolver() }
    val title = stringResource(R.string.audio_levels_title)
    val state = audioMeterStateDescription(strings, levels, sensitivity)
    val silent = LiveAudioMeterChannel(levelDb = Double.NEGATIVE_INFINITY, peakDb = Double.NEGATIVE_INFINITY)
    val left = levels?.left ?: silent
    val right = levels?.right ?: silent
    Column(
        modifier.clearAndSetSemantics {
            contentDescription = title
            stateDescription = state
        },
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Box(Modifier.weight(1f).fillMaxWidth(), contentAlignment = Alignment.Center) {
            MonitorAudioMeter(
                left.levelDb, left.peakDb, right.levelDb, right.peakDb,
                MonitorAudioOrientation.VERTICAL, showDB = false, modifier = Modifier.matchParentSize(),
            )
            if (levels == null) {
                Text(
                    stringResource(R.string.audio_no_data),
                    style = chromeStyle(6f, FontWeight.Bold, mono = true),
                    color = LiveDesign.muted.copy(alpha = 0.74f),
                )
            }
        }
        Column(Modifier.padding(bottom = 5.dp), horizontalAlignment = Alignment.CenterHorizontally) {
            if (levels?.isDebugFixture == true) {
                Text(
                    "DEBUG FIXTURE —\nNOT CAMERA AUDIO",
                    style = chromeStyle(6f, FontWeight.Bold, mono = true),
                    color = LiveDesign.accent.copy(alpha = 0.88f),
                    maxLines = 2,
                )
            } else {
                Text(
                    stringResource(R.string.audio_sensitivity_label),
                    style = chromeStyle(5f, FontWeight.SemiBold, mono = true),
                    color = LiveDesign.text.copy(alpha = 0.42f),
                    maxLines = 1,
                )
                Text(
                    displayedAudioSensitivity(sensitivity),
                    style = chromeStyle(8f, FontWeight.Bold, mono = true),
                    color = LiveDesign.text.copy(alpha = 0.72f),
                    maxLines = 1,
                )
            }
        }
    }
}

/** iOS-equivalent sensitivity label fallback. */
internal fun displayedAudioSensitivity(value: String?): String =
    value?.trim()?.takeIf(String::isNotEmpty)?.uppercase() ?: "—"

/** TalkBack-facing readout; fixture provenance is explicit rather than implied by moving bars. */
internal fun audioMeterStateDescription(
    strings: PhoneStringResolver,
    levels: LiveAudioMeterLevels?,
    sensitivity: String?,
): String {
    if (levels == null) {
        return strings.resolve(
            R.string.audio_state_unavailable,
            displayedAudioSensitivity(sensitivity),
        )
    }
    fun channel(name: String, value: LiveAudioMeterChannel): String =
        if (value.levelDb <= AUDIO_METER_FLOOR_DB + 0.5) {
            strings.resolve(R.string.audio_channel_silent, name)
        } else {
            strings.resolve(
                R.string.audio_channel_level,
                name,
                value.levelDb,
                value.peakDb,
            )
        }
    val summary =
        strings.resolve(
            R.string.audio_state_summary,
            channel(strings.resolve(R.string.audio_channel_left), levels.left),
            channel(strings.resolve(R.string.audio_channel_right), levels.right),
            displayedAudioSensitivity(sensitivity),
        )
    return if (levels.isDebugFixture) {
        summary + ", debug fixture, not camera audio"
    } else {
        summary
    }
}

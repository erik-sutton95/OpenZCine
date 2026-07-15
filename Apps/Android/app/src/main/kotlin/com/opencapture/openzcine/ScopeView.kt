package com.opencapture.openzcine

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.BlendMode
import android.graphics.Paint
import android.graphics.Typeface
import android.util.Log
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.drawIntoCanvas
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import com.opencapture.openzcine.bridge.ScopeAnchors
import com.opencapture.openzcine.bridge.ScopeTraces
import com.opencapture.openzcine.bridge.SwiftCore
import com.opencapture.openzcine.bridge.TrafficLightsBarSide
import com.opencapture.openzcine.bridge.TrafficLightsReading
import com.opencapture.openzcine.bridge.ZoneFrame
import com.opencapture.openzcine.core.LiveFrame
import java.nio.ByteBuffer
import java.util.concurrent.atomic.AtomicReference
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.sin
import kotlin.math.sqrt
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

private const val TAG = "ZCScope"

/** Wire ordinal for RED Log3G10 — the ZR live-view default and iOS fallback curve. */
private const val CURVE_LOG3G10 = 0

/** Scope refresh period — ~10 Hz, timer-driven on an absolute schedule. */
private const val SCOPE_PERIOD_NANOS = 100_000_000L

/** Widest reduction frame handed to the core sampler (1280→160, 1024→128). */
private const val REDUCTION_MAX_WIDTH = 160

/** Matches iOS's fixed 14pt bottom inset below its 58pt monitor control band. */
private const val LANDSCAPE_SCOPE_BOTTOM_CHROME_CLEARANCE = 14f + LiveDesign.CONTROL_HEIGHT_DP

/** iOS `feedOutsideCenter` gap between a floating panel and its cleared edge. */
private const val SCOPE_PANEL_EDGE_GAP = 10f

/** Android mirror of iOS's canonical scope-tool order. */
enum class ScopeKind(val token: String, val title: String, val chip: String) {
    WAVEFORM("wave", "WAVE", "LUMA"),
    PARADE("parade", "PARADE", "RGB"),
    HISTOGRAM("histo", "HISTO", "RGBL"),
    VECTORSCOPE("vector", "VECTOR", "MON · 1X"),
    TRAFFIC_LIGHTS("lights", "TL", "RGB"),
    ;

    companion object {
        /** Canonical presentation order, matching `MonitorAssistTool.scopeTools` on iOS. */
        val canonical: List<ScopeKind> = entries.toList()

        /** Parses a persisted or debug-intent token, accepting old friendly aliases safely. */
        fun fromToken(value: String?): ScopeKind? =
            when (value?.trim()?.lowercase()) {
                "wave" -> WAVEFORM
                "parade" -> PARADE
                "histo", "histogram" -> HISTOGRAM
                "vector", "vectorscope" -> VECTORSCOPE
                "lights", "traffic", "traffic-lights", "trafficlights", "tl" -> TRAFFIC_LIGHTS
                else -> null
            }

        /**
         * Decodes comma-separated scope tokens in activation order. Unknown and
         * duplicate values are ignored; all-invalid input remains `null` so it
         * preserves the old intent semantics of falling back to saved state.
         */
        fun parseTokens(value: String?): List<ScopeKind>? {
            if (value == null) return null
            val parsed = value.split(',').mapNotNull(::fromToken).distinct()
            return parsed.takeIf { it.isNotEmpty() }
        }

        /** Persists an active set in stable canonical order. */
        fun tokens(selected: Set<ScopeKind>): String =
            canonical.filter(selected::contains).joinToString(",") { it.token }
    }
}

/** Which Swift payloads the shared monitor sampler must retain for visible scopes. */
data class ScopeSamplingDemand(
    val traces: Boolean,
    val vector: Boolean,
    val pointTrace: Boolean,
    val histogram: Boolean,
    /** Whether any visible surface needs the Swift-owned RGB edge reading. */
    val trafficLights: Boolean,
)

/** Pure scope-demand planner: no panel can require a redundant sampling loop. */
fun scopeSamplingDemand(
    selected: Set<ScopeKind>,
    histogramTrafficLightsEnabled: Boolean = true,
): ScopeSamplingDemand {
    val pointTrace = ScopeKind.WAVEFORM in selected || ScopeKind.PARADE in selected
    val histogram = ScopeKind.HISTOGRAM in selected
    val trafficLights =
        ScopeKind.TRAFFIC_LIGHTS in selected || (histogram && histogramTrafficLightsEnabled)
    return ScopeSamplingDemand(
        traces = pointTrace || histogram || trafficLights,
        vector = ScopeKind.VECTORSCOPE in selected,
        pointTrace = pointTrace,
        histogram = histogram,
        trafficLights = trafficLights,
    )
}

/**
 * Normalizes a persisted scope history without inventing recency for a
 * pre-migration selection. Keeping an empty order is how portrait uses the
 * iOS canonical-prefix fallback for legacy data.
 */
fun normalizeScopeOrder(order: List<ScopeKind>, selected: Set<ScopeKind>): List<ScopeKind> {
    val seen = mutableSetOf<ScopeKind>()
    return order.filter { it in selected && seen.add(it) }
}

/** iOS portrait-fit policy: two newest active scopes, displayed in canonical order. */
fun portraitDisplayedScopes(selected: Set<ScopeKind>, activationOrder: List<ScopeKind>): List<ScopeKind> {
    val active = ScopeKind.canonical.filter(selected::contains)
    val ordered = normalizeScopeOrder(activationOrder, selected)
    val chosen = if (ordered.isEmpty()) active.take(2) else ordered.takeLast(2)
    return ScopeKind.canonical.filter(chosen::contains)
}

/** One floating panel's default physical size, mirroring the iOS base footprints. */
fun scopePanelSize(kind: ScopeKind): Pair<Float, Float> =
    when (kind) {
        ScopeKind.WAVEFORM, ScopeKind.PARADE -> 250f to 153f
        ScopeKind.HISTOGRAM -> 250f to 77f
        ScopeKind.VECTORSCOPE -> 190f to 190f
        ScopeKind.TRAFFIC_LIGHTS -> 74f to 168f
    }

/**
 * Default landscape frame for a floating panel. The anchors mirror iOS's
 * movable panels (wave top-leading, parade/vector top side, histogram
 * bottom-trailing, traffic lights bottom-leading) but give every Android
 * default a distinct initial location. Dragging can always refine a crowded
 * five-scope setup and persists a normalized centre across viewport changes.
 */
fun floatingScopeFrame(
    kind: ScopeKind,
    feed: ZoneFrame,
    infoBar: ZoneFrame,
    viewport: ZoneFrame = feed,
): ZoneFrame {
    val (width, height) = scopePanelSize(kind)
    val top = max(feed.y, infoBar.y + infoBar.height) + SCOPE_PANEL_EDGE_GAP
    val bottomEdge =
        min(
            feed.y + feed.height,
            viewport.y + viewport.height - LANDSCAPE_SCOPE_BOTTOM_CHROME_CLEARANCE,
        )
    val bottom = bottomEdge - SCOPE_PANEL_EDGE_GAP - height
    val leading = feed.x + SCOPE_PANEL_EDGE_GAP
    val trailing = feed.x + feed.width - width - SCOPE_PANEL_EDGE_GAP
    val candidate =
        when (kind) {
            ScopeKind.WAVEFORM -> ZoneFrame(leading, top, width, height)
            ScopeKind.PARADE -> ZoneFrame(trailing, top, width, height)
            ScopeKind.VECTORSCOPE ->
                ZoneFrame(
                    feed.x + (feed.width - width) / 2f,
                    viewport.y + (viewport.height - height) / 2f,
                    width,
                    height,
                )
            ScopeKind.HISTOGRAM -> ZoneFrame(trailing, bottom, width, height)
            ScopeKind.TRAFFIC_LIGHTS -> ZoneFrame(leading, bottom, width, height)
        }
    return clampScopeFrame(candidate, viewport)
}

/** Keeps a floating panel wholly inside the physical viewport's safe drawing bounds. */
fun clampScopeFrame(frame: ZoneFrame, bounds: ZoneFrame): ZoneFrame {
    val width = min(frame.width, bounds.width)
    val height = min(frame.height, bounds.height)
    val maxX = bounds.x + bounds.width - width
    val maxY = bounds.y + bounds.height - height
    return ZoneFrame(
        x = frame.x.coerceIn(bounds.x, maxX),
        y = frame.y.coerceIn(bounds.y, maxY),
        width = width,
        height = height,
    )
}

// ── Scope palette (iOS MonitorOverlays.swift `ScopePalette`, values 1:1) ──

private fun rgba(r: Int, g: Int, b: Int, a: Float) = Color(r / 255f, g / 255f, b / 255f, a)

private object ScopePalette {
    val lumaGhost = rgba(182, 190, 186, 0.08f)
    val luma = rgba(222, 230, 224, 1.0f)
    val lumaHot = rgba(255, 255, 255, 1.0f)
    val paradeRed = rgba(255, 86, 78, 1.0f)
    val paradeGreen = rgba(102, 232, 132, 1.0f)
    val paradeBlue = rgba(92, 156, 255, 1.0f)
    val boundary = rgba(220, 235, 225, 0.8f)
    val clip = rgba(255, 150, 142, 0.8f)
    val middle = rgba(246, 241, 226, 0.8f)
    val graticule = rgba(220, 235, 225, 0.55f)
    val graticuleFaint = rgba(220, 235, 225, 0.30f)
    val histogramRedFill = rgba(255, 48, 44, 0.17f)
    val histogramGreenFill = rgba(0, 238, 70, 0.15f)
    val histogramBlueFill = rgba(45, 76, 255, 0.19f)
    val histogramRedStroke = rgba(255, 48, 44, 0.96f)
    val histogramGreenStroke = rgba(0, 238, 70, 0.92f)
    val histogramBlueStroke = rgba(45, 76, 255, 0.94f)
    val histogramLumaStroke = rgba(245, 242, 232, 0.58f)
    val panelBackground = Color(0.025f, 0.036f, 0.03f, 0.72f)
    val trafficRed = rgba(255, 92, 82, 1f)
    val trafficGreen = rgba(86, 235, 132, 1f)
    val trafficBlue = rgba(96, 158, 255, 1f)

    /** Phosphor persistence: the previous tick draws first at this opacity. */
    const val TRAIL_DECAY = 0.35f
}

// ── Tick payload ──

/** Immutable monitor-wide scope snapshot: every visible panel reads this same clean-frame tick. */
private class ScopeDrawData(
    val traces: ScopeTraces? = null,
    val trailTraces: ScopeTraces? = null,
    /** Blended + smoothed display bins per channel (histogram kind only). */
    val histogram: HistogramDisplay? = null,
    val vector: ImageBitmap? = null,
    val vectorTrail: ImageBitmap? = null,
    val trafficLights: TrafficLightsReading? = null,
)

private class HistogramDisplay(
    val luma: FloatArray,
    val red: FloatArray,
    val green: FloatArray,
    val blue: FloatArray,
    val peak: Float,
)

// ── Shared monitor coordinator ──

/**
 * Renders every selected scope from one monitor-owned sampler. A panel is a
 * pure view of [ScopeDrawData], so enabling five tools never creates five
 * JPEG decoders, frame collectors, or timer loops.
 */
@Composable
fun ScopePanels(
    selectedScopes: Set<ScopeKind>,
    portraitScopes: List<ScopeKind>,
    crushClipCompensationRaw: Int,
    histogramTrafficLightsEnabled: Boolean,
    source: com.opencapture.openzcine.core.LiveFrameSource,
    isPortrait: Boolean,
    feed: ZoneFrame,
    infoBar: ZoneFrame,
    scopeZone: ZoneFrame?,
    viewport: ZoneFrame,
) {
    val displayed =
        if (isPortrait) {
            portraitScopes.filter(selectedScopes::contains)
        } else {
            ScopeKind.canonical.filter(selectedScopes::contains)
        }
    // This guard also stops all collection when no displayed panel exists.
    if (displayed.isEmpty()) return
    if (isPortrait && scopeZone == null) return

    val snapshot =
        rememberScopeSnapshot(
            source,
            displayed.toSet(),
            crushClipCompensationRaw,
            histogramTrafficLightsEnabled,
        )
    val needsAnchors = displayed.any { it != ScopeKind.TRAFFIC_LIGHTS }
    val anchors =
        remember(needsAnchors) {
            if (needsAnchors) ScopeAnchors.parse(SwiftCore.scopeAnchors(CURVE_LOG3G10)) else null
        }

    if (isPortrait) {
        val zone = requireNotNull(scopeZone)
        PortraitScopePanels(displayed, zone, anchors, snapshot, histogramTrafficLightsEnabled)
    } else {
        LandscapeScopePanels(
            displayed,
            feed,
            infoBar,
            viewport,
            anchors,
            snapshot,
            histogramTrafficLightsEnabled,
        )
    }
}

/** Renders the portrait subset into the shared stack zone from the core layout map. */
@Composable
private fun PortraitScopePanels(
    displayed: List<ScopeKind>,
    zone: ZoneFrame,
    anchors: ScopeAnchors?,
    snapshot: ScopeDrawData?,
    histogramTrafficLightsEnabled: Boolean,
) {
    val spacing = 8f
    val panelHeight = max(0f, (zone.height - spacing * (displayed.size - 1)) / displayed.size)
    Box(Modifier.zone(zone)) {
        displayed.forEachIndexed { index, kind ->
            ScopePanel(
                kind = kind,
                anchors = anchors,
                data = snapshot,
                histogramTrafficLightsEnabled = histogramTrafficLightsEnabled,
                fillsWidth = kind == ScopeKind.TRAFFIC_LIGHTS,
                modifier =
                    Modifier.zone(
                        ZoneFrame(
                            x = 12f,
                            y = index * (panelHeight + spacing),
                            width = max(0f, zone.width - 24f),
                            height = panelHeight,
                        ),
                    ),
            )
        }
    }
}

/** Renders draggable, normalized-persisted landscape panels at distinct iOS-informed defaults. */
@Composable
private fun LandscapeScopePanels(
    displayed: List<ScopeKind>,
    feed: ZoneFrame,
    infoBar: ZoneFrame,
    viewport: ZoneFrame,
    anchors: ScopeAnchors?,
    snapshot: ScopeDrawData?,
    histogramTrafficLightsEnabled: Boolean,
) {
    val context = LocalContext.current.applicationContext
    val store = remember(context) { ScopePanelPlacementStore(context) }
    Box(Modifier.fillMaxSize()) {
        displayed.forEach { kind ->
            val default = floatingScopeFrame(kind, feed, infoBar, viewport)
            FloatingScopePanel(kind, default, viewport, store) { modifier ->
                ScopePanel(
                    kind = kind,
                    anchors = anchors,
                    data = snapshot,
                    histogramTrafficLightsEnabled = histogramTrafficLightsEnabled,
                    fillsWidth = false,
                    modifier = modifier,
                )
            }
        }
    }
}

/** Current Android equivalent of iOS's persisted movable panel centre. */
private class ScopePanelPlacementStore(context: Context) {
    private val preferences = context.getSharedPreferences("scopePanelPlacement", Context.MODE_PRIVATE)

    fun resolve(kind: ScopeKind, default: ZoneFrame, bounds: ZoneFrame): ZoneFrame {
        val xKey = "${kind.token}.centerX"
        val yKey = "${kind.token}.centerY"
        if (!preferences.contains(xKey) || !preferences.contains(yKey)) return default
        val normalizedX = preferences.getFloat(xKey, 0.5f)
        val normalizedY = preferences.getFloat(yKey, 0.5f)
        if (!normalizedX.isFinite() || !normalizedY.isFinite()) return default
        val centerX = bounds.x + normalizedX * bounds.width
        val centerY = bounds.y + normalizedY * bounds.height
        return clampScopeFrame(
            ZoneFrame(centerX - default.width / 2f, centerY - default.height / 2f, default.width, default.height),
            bounds,
        )
    }

    fun save(kind: ScopeKind, frame: ZoneFrame, bounds: ZoneFrame) {
        val centerX = (frame.x + frame.width / 2f - bounds.x) / max(1f, bounds.width)
        val centerY = (frame.y + frame.height / 2f - bounds.y) / max(1f, bounds.height)
        preferences.edit()
            .putFloat("${kind.token}.centerX", centerX.coerceIn(0f, 1f))
            .putFloat("${kind.token}.centerY", centerY.coerceIn(0f, 1f))
            .apply()
    }
}

/** Drag wrapper for a floating panel. The persisted state commits only after a completed drag. */
@Composable
private fun FloatingScopePanel(
    kind: ScopeKind,
    default: ZoneFrame,
    bounds: ZoneFrame,
    store: ScopePanelPlacementStore,
    content: @Composable (Modifier) -> Unit,
) {
    val density = LocalDensity.current
    var frame by remember(kind, default, bounds) { mutableStateOf(store.resolve(kind, default, bounds)) }
    content(
        Modifier
            .zone(frame)
            .pointerInput(kind, bounds, default.width, default.height) {
                detectDragGestures(
                    onDragEnd = { store.save(kind, frame, bounds) },
                ) { change, dragAmount ->
                    change.consume()
                    frame =
                        clampScopeFrame(
                            frame.copy(
                                x = frame.x + dragAmount.x / density.density,
                                y = frame.y + dragAmount.y / density.density,
                            ),
                            bounds,
                        )
                }
            },
    )
}

/** One panel view of the shared [ScopeDrawData]; it never samples or collects frames itself. */
@Composable
private fun ScopePanel(
    kind: ScopeKind,
    anchors: ScopeAnchors?,
    data: ScopeDrawData?,
    histogramTrafficLightsEnabled: Boolean,
    fillsWidth: Boolean,
    modifier: Modifier = Modifier,
) {
    if (kind == ScopeKind.TRAFFIC_LIGHTS) {
        TrafficLightsPanel(data?.trafficLights ?: TrafficLightsReading.EMPTY, fillsWidth, modifier)
        return
    }
    val resolvedAnchors = anchors ?: return
    Box(
        modifier
            .background(ScopePalette.panelBackground, ChromeShape)
            .border(1.dp, LiveDesign.hairline, ChromeShape),
    ) {
        Canvas(Modifier.fillMaxSize()) {
            drawScope(kind, resolvedAnchors, data, histogramTrafficLightsEnabled)
        }
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 8.dp).padding(top = 4.dp),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                kind.title,
                style = chromeStyle(10.5f, FontWeight.Bold, mono = true),
                color = LiveDesign.text.copy(alpha = 0.66f),
                maxLines = 1,
            )
            Text(
                kind.chip,
                style = chromeStyle(9.5f, FontWeight.Bold, mono = true),
                color = LiveDesign.text.copy(alpha = 0.58f),
                maxLines = 1,
            )
        }
    }
}

/** Real RED-style RGB goal-post meter; side/fill arrives fully computed from Swift. */
@Composable
private fun TrafficLightsPanel(
    reading: TrafficLightsReading,
    fillsWidth: Boolean,
    modifier: Modifier = Modifier,
) {
    BoxWithConstraints(
        modifier
            .background(ScopePalette.panelBackground, ChromeShape)
            .border(1.dp, LiveDesign.hairline, ChromeShape)
            .semantics {
                contentDescription = "Traffic Lights"
                stateDescription = trafficLightsStateDescription(reading)
            },
    ) {
        val uiScale = min(maxWidth.value / 74f, maxHeight.value / 168f).coerceAtLeast(0f)
        Canvas(Modifier.fillMaxSize()) { drawTrafficLights(reading, fillsWidth, uiScale) }
        Text(
            "TL",
            modifier = Modifier.align(Alignment.TopCenter).padding(top = (8f * uiScale).dp),
            style = chromeStyle(8.5f * uiScale, FontWeight.Bold, mono = true),
            color = LiveDesign.text.copy(alpha = 0.58f),
            maxLines = 1,
        )
    }
}

private fun trafficLightsStateDescription(reading: TrafficLightsReading): String {
    fun channel(name: String, value: com.opencapture.openzcine.bridge.TrafficLightsChannel): String {
        val direction =
            when (value.side) {
                TrafficLightsBarSide.NEUTRAL -> "balanced"
                TrafficLightsBarSide.OVER -> "over"
                TrafficLightsBarSide.UNDER -> "under"
            }
        val flags = listOfNotNull("clip".takeIf { value.clip }, "crush".takeIf { value.crush })
        return "$name $direction${if (flags.isEmpty()) "" else " (${flags.joinToString()})"}"
    }
    return listOf(
        channel("red", reading.red),
        channel("green", reading.green),
        channel("blue", reading.blue),
    ).joinToString(", ")
}

private fun DrawScope.drawTrafficLights(
    reading: TrafficLightsReading,
    fillsWidth: Boolean,
    uiScale: Float,
) {
    val channels =
        listOf(
            ScopePalette.trafficRed to reading.red,
            ScopePalette.trafficGreen to reading.green,
            ScopePalette.trafficBlue to reading.blue,
        )
    val scale = uiScale.coerceAtLeast(0f)
    val dotRadius = 4.dp.toPx() * scale
    val columnGap = 6.dp.toPx() * scale
    // These base positions reproduce the iOS `TrafficLightsMeterMini` stack:
    // 8pt top padding, title, 6pt gap, 8pt clip dot, 4pt gap, 108pt track,
    // 4pt gap, then the 8pt crush dot. The full panel scales from 74×168.
    val topDotY = 28.dp.toPx() * scale
    val trackTop = 36.dp.toPx() * scale
    val trackHeight = 108.dp.toPx() * scale
    val trackBottom = trackTop + trackHeight
    val centreY = (trackTop + trackBottom) / 2f
    val centerLineHeight = max(1.dp.toPx(), 0.85.dp.toPx() * scale)
    val halfHeight = (trackHeight - centerLineHeight) / 2f
    val columnWidth =
        if (fillsWidth) {
            min(
                44.dp.toPx(),
                max(11.dp.toPx() * scale, (size.width - 16.dp.toPx() * scale) / 6f),
            )
        } else {
            11.dp.toPx() * scale
        }
    val centres =
        if (fillsWidth) {
            val horizontalPadding = 8.dp.toPx() * scale
            val cellWidth = (size.width - horizontalPadding * 2f - columnGap * 2f) / 3f
            List(3) { index ->
                horizontalPadding + cellWidth / 2f + index * (cellWidth + columnGap)
            }
        } else {
            val centre = size.width / 2f
            listOf(centre - columnWidth - columnGap, centre, centre + columnWidth + columnGap)
        }
    channels.forEachIndexed { index, (color, channel) ->
        val centreX = centres[index]
        val trackLeft = centreX - columnWidth / 2f
        val fillHeight = halfHeight * channel.fill
        val trackColor = LiveDesign.text.copy(alpha = 0.08f)
        drawRoundRect(
            trackColor,
            topLeft = Offset(trackLeft, trackTop),
            size = Size(columnWidth, trackHeight),
            cornerRadius = CornerRadius(2.dp.toPx() * scale),
        )
        drawRect(
            LiveDesign.text.copy(alpha = 0.14f),
            topLeft = Offset(trackLeft, centreY - centerLineHeight / 2f),
            size = Size(columnWidth, centerLineHeight),
        )
        when (channel.side) {
            TrafficLightsBarSide.OVER ->
                if (fillHeight > 0f) {
                    val height = max(1.5.dp.toPx() * scale, fillHeight)
                    val top = centreY - height
                    drawRoundRect(
                        brush =
                            Brush.verticalGradient(
                                listOf(color.copy(alpha = 0.92f), color.copy(alpha = 0.35f)),
                                startY = top,
                                endY = centreY,
                            ),
                        topLeft = Offset(trackLeft, top),
                        size = Size(columnWidth, height),
                        cornerRadius = CornerRadius(2.dp.toPx() * scale),
                    )
                }
            TrafficLightsBarSide.UNDER ->
                if (fillHeight > 0f) {
                    val height = max(1.5.dp.toPx() * scale, fillHeight)
                    drawRoundRect(
                        brush =
                            Brush.verticalGradient(
                                listOf(color.copy(alpha = 0.35f), color.copy(alpha = 0.92f)),
                                startY = centreY,
                                endY = centreY + height,
                            ),
                        topLeft = Offset(trackLeft, centreY),
                        size = Size(columnWidth, height),
                        cornerRadius = CornerRadius(2.dp.toPx() * scale),
                    )
                }
            TrafficLightsBarSide.NEUTRAL -> Unit
        }
        drawTrafficIndicator(color, channel.clip, dotRadius, Offset(centreX, topDotY), scale)
        drawTrafficIndicator(
            color,
            channel.crush,
            dotRadius,
            Offset(centreX, 152.dp.toPx() * scale),
            scale,
        )
    }
}

/** iOS-matched hollow/filled Traffic Lights clip or crush indicator. */
private fun DrawScope.drawTrafficIndicator(
    color: Color,
    active: Boolean,
    radius: Float,
    centre: Offset,
    uiScale: Float,
) {
    if (active) drawCircle(color, radius, centre)
    drawCircle(
        color.copy(alpha = if (active) 1f else 0.75f),
        radius,
        centre,
        style = Stroke(width = max(1.dp.toPx(), 1.5.dp.toPx() * uiScale)),
    )
}

/**
 * One cancellation-safe clean-frame sampling loop per monitor. It reduces
 * the source JPEG once per tick, asks Swift only for demanded trace/vector
 * payloads, and publishes one immutable snapshot to every visible panel.
 */
@Composable
private fun rememberScopeSnapshot(
    source: com.opencapture.openzcine.core.LiveFrameSource,
    selected: Set<ScopeKind>,
    crushClipCompensationRaw: Int,
    histogramTrafficLightsEnabled: Boolean,
): ScopeDrawData? {
    val data = remember { mutableStateOf<ScopeDrawData?>(null) }
    val ordered = ScopeKind.canonical.filter(selected::contains)
    LaunchedEffect(source, ordered, crushClipCompensationRaw, histogramTrafficLightsEnabled) {
        data.value = null
        withContext(Dispatchers.Default) {
            pumpScopes(
                source.frames,
                ordered.toSet(),
                crushClipCompensationRaw,
                histogramTrafficLightsEnabled,
            ) { data.value = it }
        }
    }
    return data.value
}

/**
 * Absolute-schedule sampler: never gates by source-frame cadence, so it
 * retains the iOS wall-clock anti-aliasing policy while sharing one decoder.
 */
private suspend fun pumpScopes(
    frames: Flow<LiveFrame>,
    selected: Set<ScopeKind>,
    crushClipCompensationRaw: Int,
    histogramTrafficLightsEnabled: Boolean,
    present: (ScopeDrawData) -> Unit,
): Unit = coroutineScope {
    val demand = scopeSamplingDemand(selected, histogramTrafficLightsEnabled)
    if (!demand.traces && !demand.vector) return@coroutineScope

    val latest = AtomicReference<ByteArray?>(null)
    launch { frames.collect { latest.set(it.jpegData) } }

    val tap = ScopeFrameTap()
    val stats = ScopeTickStats { if (BuildConfig.DEBUG) Log.d(TAG, it) }
    val vectorBitmaps = VectorBitmapRing()
    var lastProcessed: ByteArray? = null
    var previousTraces: ScopeTraces? = null
    var previousHistogram: ScopeTraces? = null
    var previousVector: ImageBitmap? = null
    val startNanos = System.nanoTime()
    var tick = 0L
    while (true) {
        tick = max(tick + 1, (System.nanoTime() - startNanos) / SCOPE_PERIOD_NANOS)
        val waitMillis = (startNanos + tick * SCOPE_PERIOD_NANOS - System.nanoTime()) / 1_000_000
        if (waitMillis > 0) delay(waitMillis)

        val jpeg = latest.get() ?: continue
        if (jpeg === lastProcessed) continue // static feed — retain the last immutable snapshot
        lastProcessed = jpeg

        val tickStart = System.nanoTime()
        val reduced = tap.reduce(jpeg) ?: continue
        val traces =
            if (demand.traces) {
                try {
                    ScopeTraces.parse(
                        SwiftCore.scopeTraces(
                            reduced.rgba, reduced.width, reduced.height,
                            reduced.bytesPerRow, CURVE_LOG3G10, crushClipCompensationRaw,
                        ),
                    )
                } catch (error: IllegalArgumentException) {
                    Log.w(TAG, "discarding malformed Swift scope payload", error)
                    continue
                }
            } else {
                null
            }
        val vector =
            if (demand.vector) {
                vectorBitmaps.imageFrom(
                    SwiftCore.scopeVector(
                        reduced.rgba, reduced.width, reduced.height,
                        reduced.bytesPerRow, CURVE_LOG3G10,
                    ),
                )
            } else {
                null
            }

        val traceForPanel = traces.takeIf { demand.pointTrace }
        val histogram = traces?.takeIf { demand.histogram }?.let { histogramDisplay(it, previousHistogram) }
        val trafficLights = traces?.trafficLights?.takeIf { demand.trafficLights }
        present(
            ScopeDrawData(
                traces = traceForPanel,
                trailTraces = previousTraces.takeIf { demand.pointTrace },
                histogram = histogram,
                vector = vector,
                vectorTrail = previousVector.takeIf { demand.vector },
                trafficLights = trafficLights,
            ),
        )
        if (demand.pointTrace) previousTraces = traces
        if (demand.histogram) previousHistogram = traces
        if (demand.vector) previousVector = vector
        stats.tickCompleted(System.nanoTime() - tickStart, System.nanoTime())
    }
}

/** One reduced frame ready for the core sampler. */
private class ReducedFrame(
    val rgba: ByteArray,
    val width: Int,
    val height: Int,
    val bytesPerRow: Int,
)

/**
 * JPEG → small RGBA reduction, allocation-free in steady state: the JPEG is
 * decoded straight at 1/2ⁿ scale (`inSampleSize` — the DCT-domain fast path,
 * far cheaper than full decode + rescale, and independent of the feed
 * renderer's bitmap ring, so a tick can never observe a torn frame) into one
 * reused mutable bitmap, then copied into a reused RGBA byte array.
 */
private class ScopeFrameTap {
    private val boundsOptions = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    private val options = BitmapFactory.Options().apply { inMutable = true }
    private var bitmap: Bitmap? = null
    private var rgba = ByteArray(0)

    fun reduce(jpeg: ByteArray): ReducedFrame? {
        BitmapFactory.decodeByteArray(jpeg, 0, jpeg.size, boundsOptions)
        if (boundsOptions.outWidth <= 0) return null
        var sample = 1
        while (boundsOptions.outWidth / sample > REDUCTION_MAX_WIDTH) sample *= 2
        options.inSampleSize = sample
        options.inBitmap = bitmap
        val decoded =
            try {
                BitmapFactory.decodeByteArray(jpeg, 0, jpeg.size, options)
            } catch (_: IllegalArgumentException) {
                // Pooled bitmap incompatible (feed size changed) — decode fresh.
                options.inBitmap = null
                BitmapFactory.decodeByteArray(jpeg, 0, jpeg.size, options)
            } ?: return null
        bitmap = decoded
        val byteCount = decoded.rowBytes * decoded.height
        if (rgba.size != byteCount) rgba = ByteArray(byteCount)
        decoded.copyPixelsToBuffer(ByteBuffer.wrap(rgba))
        return ReducedFrame(rgba, decoded.width, decoded.height, decoded.rowBytes)
    }
}

/**
 * Ring of reused 128×128 bitmaps for the vectorscope density image — 3 deep so
 * the bitmap being written is never one the RenderThread may still read
 * (current frame + trail), mirroring [JpegFrameDecoder]'s ring rationale.
 */
private class VectorBitmapRing {
    private val pool = arrayOfNulls<Bitmap>(3)
    private var next = 0

    fun imageFrom(premultipliedRgba: ByteArray): ImageBitmap? {
        if (premultipliedRgba.isEmpty()) return null
        val side = sqrt(premultipliedRgba.size / 4.0).toInt()
        var bitmap = pool[next]
        if (bitmap == null || bitmap.width != side) {
            bitmap = Bitmap.createBitmap(side, side, Bitmap.Config.ARGB_8888)
            pool[next] = bitmap
        }
        bitmap.copyPixelsFromBuffer(ByteBuffer.wrap(premultipliedRgba))
        next = (next + 1) % pool.size
        return bitmap.asImageBitmap()
    }
}

/** `0.65·current + 0.35·previous` display-bin blend, then a radius-2 box smooth (iOS parity). */
private fun histogramDisplay(current: ScopeTraces, previous: ScopeTraces?): HistogramDisplay {
    fun channel(now: FloatArray, before: FloatArray?): FloatArray {
        val blended =
            if (before == null || before.size != now.size) {
                now
            } else {
                FloatArray(now.size) { now[it] * 0.65f + before[it] * 0.35f }
            }
        val smoothed = FloatArray(blended.size)
        for (index in blended.indices) {
            val lower = max(0, index - 2)
            val upper = min(blended.size - 1, index + 2)
            var sum = 0f
            for (i in lower..upper) sum += blended[i]
            smoothed[index] = sum / (upper - lower + 1)
        }
        return smoothed
    }
    val luma = channel(current.histogramLuma, previous?.histogramLuma)
    val red = channel(current.histogramRed, previous?.histogramRed)
    val green = channel(current.histogramGreen, previous?.histogramGreen)
    val blue = channel(current.histogramBlue, previous?.histogramBlue)
    val peak = max(max(luma.max(), red.max()), max(max(green.max(), blue.max()), 1f))
    return HistogramDisplay(luma, red, green, blue, peak)
}

/** ~10 Hz cadence accounting: achieved rate plus per-tick cost every 5 s. */
private class ScopeTickStats(private val log: (String) -> Unit) {
    private var ticks = 0L
    private var totalNanos = 0L
    private var maxNanos = 0L
    private var windowStart = 0L

    fun tickCompleted(costNanos: Long, nowNanos: Long) {
        if (windowStart == 0L) windowStart = nowNanos
        ticks++
        totalNanos += costNanos
        maxNanos = max(maxNanos, costNanos)
        val elapsed = nowNanos - windowStart
        if (elapsed < 5_000_000_000L) return
        log(
            "scope pacing: %.1f Hz | tick avg %.1f ms max %.1f ms"
                .format(ticks * 1e9 / elapsed, totalNanos / ticks / 1e6, maxNanos / 1e6),
        )
        ticks = 0
        totalNanos = 0
        maxNanos = 0
        windowStart = nowNanos
    }
}

// ── Drawing ──

/** iOS `scopePlotRect`: 6pt side insets, 26pt title clearance, 8pt bottom. */
private fun DrawScope.plotRect(): Rect =
    Rect(
        6.dp.toPx(),
        26.dp.toPx(),
        size.width - 6.dp.toPx(),
        size.height - 8.dp.toPx(),
    )

/** Leaves the iOS-matched left/right clearance for histogram RGB edge blocks. */
private fun DrawScope.histogramPlotRect(showTrafficLights: Boolean): Rect =
    if (!showTrafficLights) {
        plotRect()
    } else {
        Rect(
            26.dp.toPx(),
            26.dp.toPx(),
            size.width - 26.dp.toPx(),
            size.height - 8.dp.toPx(),
        )
    }

/** iOS `scopeLevelY`: display level 0…1 to y, with the 4% top/bottom buffer. */
private fun levelY(level: Float, plot: Rect): Float =
    plot.bottom - (0.04f + level * 0.92f) * plot.height

private fun DrawScope.drawScope(
    kind: ScopeKind,
    anchors: ScopeAnchors,
    data: ScopeDrawData?,
    histogramTrafficLightsEnabled: Boolean,
) {
    val plot =
        if (kind == ScopeKind.HISTOGRAM) {
            histogramPlotRect(histogramTrafficLightsEnabled)
        } else {
            plotRect()
        }
    when (kind) {
        ScopeKind.WAVEFORM, ScopeKind.PARADE -> {
            data?.trailTraces?.let { drawTrace(kind, it, plot, ScopePalette.TRAIL_DECAY) }
            data?.traces?.let { drawTrace(kind, it, plot, 1f) }
            drawAxisGuides(anchors, plot)
        }
        ScopeKind.HISTOGRAM -> {
            val lights = data?.trafficLights?.takeIf { histogramTrafficLightsEnabled }
            drawHistogramClipZone(plot, lights)
            data?.histogram?.let { drawHistogram(it, plot) }
            drawHistogramGuides(anchors, plot)
            lights?.let(::drawHistogramTrafficLights)
        }
        ScopeKind.VECTORSCOPE -> {
            val side = min(plot.width, plot.height)
            val square =
                Rect(
                    plot.center.x - side / 2, plot.center.y - side / 2,
                    plot.center.x + side / 2, plot.center.y + side / 2,
                )
            data?.vectorTrail?.let { drawVectorDensity(it, square, ScopePalette.TRAIL_DECAY) }
            data?.vector?.let { drawVectorDensity(it, square, 1f) }
            drawVectorGraticule(anchors, square)
        }
        ScopeKind.TRAFFIC_LIGHTS -> Unit // Rendered by TrafficLightsPanel, never this Canvas path.
    }
}

// Waveform / parade points render through the native canvas: one batched
// `drawPoints(FloatArray)` per pass over a reused scratch array — no per-point
// object allocation (the Compose `drawPoints(List<Offset>)` overload boxes).
private val pointScratch = ThreadLocal.withInitial { FloatArray(0) }

private fun DrawScope.drawPointPass(
    xy: FloatArray,
    count: Int,
    color: Color,
    widthPx: Float,
    opacity: Float,
) {
    if (count == 0) return
    drawIntoCanvas { canvas ->
        val paint = Paint()
        paint.isAntiAlias = false
        paint.strokeCap = Paint.Cap.SQUARE
        paint.strokeWidth = widthPx
        paint.blendMode = BlendMode.PLUS
        paint.color =
            android.graphics.Color.argb(
                (color.alpha * opacity * 255).roundToInt(),
                (color.red * 255).roundToInt(),
                (color.green * 255).roundToInt(),
                (color.blue * 255).roundToInt(),
            )
        canvas.nativeCanvas.drawPoints(xy, 0, count * 2, paint)
    }
}

/** Fills the scratch array with plot-space positions for one channel. */
private fun fillChannel(
    traces: ScopeTraces,
    channelOffset: Int,
    plot: Rect,
    laneOrigin: Float,
    laneWidth: Float,
    out: FloatArray,
): Int {
    val stride = ScopeTraces.POINT_STRIDE
    for (index in 0 until traces.pointCount) {
        val x = traces.points[index * stride]
        val level = traces.points[index * stride + channelOffset]
        out[index * 2] = laneOrigin + x * laneWidth
        out[index * 2 + 1] = levelY(level, plot)
    }
    return traces.pointCount
}

private fun DrawScope.drawTrace(kind: ScopeKind, traces: ScopeTraces, plot: Rect, opacity: Float) {
    if (traces.pointCount == 0) return
    var scratch = pointScratch.get() ?: FloatArray(0)
    if (scratch.size < traces.pointCount * 2) {
        scratch = FloatArray(traces.pointCount * 2)
        pointScratch.set(scratch)
    }
    when (kind) {
        ScopeKind.WAVEFORM -> {
            // Luma trace: 2px additive ghost + 1px core, brighter every 4th dot.
            val count = fillChannel(traces, 1, plot, plot.left, plot.width, scratch)
            drawPointPass(scratch, count, ScopePalette.lumaGhost, 2.dp.toPx(), opacity)
            drawPointPass(scratch, count, ScopePalette.luma, 1.dp.toPx(), opacity)
            var hot = 0
            for (index in 0 until count step 4) {
                scratch[hot * 2] = scratch[index * 2]
                scratch[hot * 2 + 1] = scratch[index * 2 + 1]
                hot++
            }
            drawPointPass(scratch, hot, ScopePalette.lumaHot, 1.dp.toPx(), opacity)
        }
        ScopeKind.PARADE -> {
            val laneWidth = plot.width / 3
            val lanes =
                listOf(
                    Pair(2, ScopePalette.paradeRed),
                    Pair(3, ScopePalette.paradeGreen),
                    Pair(4, ScopePalette.paradeBlue),
                )
            for ((laneIndex, lane) in lanes.withIndex()) {
                val origin = plot.left + laneIndex * laneWidth
                val count = fillChannel(traces, lane.first, plot, origin, laneWidth - 1, scratch)
                drawPointPass(scratch, count, lane.second, 1.dp.toPx(), opacity)
            }
        }
        else -> Unit
    }
}

/** Boundary lines (code 0/255) plus the three fixed anchor lines. */
private fun DrawScope.drawAxisGuides(anchors: ScopeAnchors, plot: Rect) {
    val dashed = PathEffect.dashPathEffect(floatArrayOf(4.dp.toPx(), 4.dp.toPx()))
    fun line(level: Float, color: Color, width: Float, effect: PathEffect? = null) {
        val y = levelY(level, plot)
        drawLine(
            color, Offset(plot.left, y), Offset(plot.right, y),
            strokeWidth = width, pathEffect = effect,
        )
    }
    line(0f, ScopePalette.boundary, 1.25.dp.toPx())
    line(1f, ScopePalette.boundary, 1.25.dp.toPx())
    line(anchors.clipLine, ScopePalette.clip, 1.dp.toPx(), dashed)
    line(anchors.midGray, ScopePalette.middle, 1.dp.toPx())
    line(anchors.crushLine, ScopePalette.clip, 1.dp.toPx(), dashed)
}

private fun DrawScope.drawHistogram(display: HistogramDisplay, plot: Rect) {
    fun channel(bins: FloatArray, fill: Color, stroke: Color, strokeWidth: Float) {
        val path = histogramPath(bins, plot, display.peak, closed = true)
        drawPath(path, fill, alpha = 0.92f, blendMode = androidx.compose.ui.graphics.BlendMode.Plus)
        val outline = histogramPath(bins, plot, display.peak, closed = false)
        drawPath(
            outline, stroke, alpha = 0.92f,
            style = Stroke(strokeWidth, cap = androidx.compose.ui.graphics.StrokeCap.Round),
            blendMode = androidx.compose.ui.graphics.BlendMode.Plus,
        )
    }
    channel(display.red, ScopePalette.histogramRedFill, ScopePalette.histogramRedStroke, 1.8.dp.toPx())
    channel(display.green, ScopePalette.histogramGreenFill, ScopePalette.histogramGreenStroke, 1.8.dp.toPx())
    channel(display.blue, ScopePalette.histogramBlueFill, ScopePalette.histogramBlueStroke, 1.8.dp.toPx())
    // Luma: dim outline only (a fill washed mid-tones white on iOS).
    drawPath(
        histogramPath(display.luma, plot, display.peak, closed = false),
        ScopePalette.histogramLumaStroke,
        alpha = 0.58f,
        style = Stroke(1.4.dp.toPx(), cap = androidx.compose.ui.graphics.StrokeCap.Round),
    )
}

/** iOS histogram 95…100 IRE clip tint, driven by the Swift-owned RGB edge flags. */
private fun DrawScope.drawHistogramClipZone(plot: Rect, lights: TrafficLightsReading?) {
    val hasClip = lights?.let { it.red.clip || it.green.clip || it.blue.clip } ?: false
    if (!hasClip) return
    val left = plot.left + plot.width * 0.95f
    drawRect(
        ScopePalette.clip.copy(alpha = 0.14f),
        topLeft = Offset(left, plot.top),
        size = Size(plot.right - left, plot.height),
    )
}

/** Small RGB edge blocks flanking the histogram — left crush, right clip. */
private fun DrawScope.drawHistogramTrafficLights(reading: TrafficLightsReading) {
    val blockWidth = 7.5.dp.toPx()
    val blockHeight = 15.dp.toPx()
    val gap = 3.dp.toPx()
    val top = 12.dp.toPx()
    val left = 11.dp.toPx()
    val right = size.width - 11.dp.toPx() - blockWidth
    val corner = CornerRadius(2.dp.toPx())
    val channels =
        listOf(
            Triple(ScopePalette.trafficRed, reading.red.crush, reading.red.clip),
            Triple(ScopePalette.trafficGreen, reading.green.crush, reading.green.clip),
            Triple(ScopePalette.trafficBlue, reading.blue.crush, reading.blue.clip),
        )

    fun block(x: Float, y: Float, color: Color, active: Boolean) {
        if (active) {
            drawRoundRect(
                color,
                topLeft = Offset(x, y),
                size = Size(blockWidth, blockHeight),
                cornerRadius = corner,
            )
        }
        drawRoundRect(
            color.copy(alpha = if (active) 1f else 0.8f),
            topLeft = Offset(x, y),
            size = Size(blockWidth, blockHeight),
            cornerRadius = corner,
            style = Stroke(1.5.dp.toPx()),
        )
    }

    channels.forEachIndexed { index, (color, crush, clip) ->
        val y = top + index * (blockHeight + gap)
        block(left, y, color, crush)
        block(right, y, color, clip)
    }
}

/** Smoothed contour over the display bins (quadratic midpoints, iOS `histogramPaths`). */
private fun histogramPath(bins: FloatArray, plot: Rect, peak: Float, closed: Boolean): Path {
    val path = Path()
    fun x(index: Int) = plot.left + index.toFloat() / (bins.size - 1) * plot.width
    fun y(index: Int) = plot.bottom - bins[index] / peak * plot.height
    if (closed) {
        path.moveTo(plot.left, plot.bottom)
        path.lineTo(x(0), y(0))
    } else {
        path.moveTo(x(0), y(0))
    }
    for (index in 1 until bins.size) {
        val midX = (x(index - 1) + x(index)) / 2
        val midY = (y(index - 1) + y(index)) / 2
        path.quadraticTo(x(index - 1), y(index - 1), midX, midY)
    }
    path.quadraticTo(x(bins.size - 2), y(bins.size - 2), x(bins.size - 1), y(bins.size - 1))
    if (closed) {
        path.lineTo(plot.right, plot.bottom)
        path.close()
    }
    return path
}

/** Quarter grid, 0/255 boundaries, and the three anchors as vertical lines. */
private fun DrawScope.drawHistogramGuides(anchors: ScopeAnchors, plot: Rect) {
    for (step in 1..3) {
        val y = plot.top + plot.height * step / 4
        drawLine(rgba(220, 235, 225, 0.06f), Offset(plot.left, y), Offset(plot.right, y), 1.dp.toPx())
    }
    fun vertical(fraction: Float, color: Color, width: Float, effect: PathEffect? = null) {
        val x = plot.left + fraction * plot.width
        drawLine(color, Offset(x, plot.top), Offset(x, plot.bottom), width, pathEffect = effect)
    }
    vertical(0f, ScopePalette.boundary, 1.25.dp.toPx())
    vertical(1f, ScopePalette.boundary, 1.25.dp.toPx())
    val dashed = PathEffect.dashPathEffect(floatArrayOf(4.dp.toPx(), 4.dp.toPx()))
    vertical(anchors.crushLine, ScopePalette.clip, 1.dp.toPx(), dashed)
    vertical(anchors.midGray, ScopePalette.middle, 1.dp.toPx())
    vertical(anchors.clipLine, ScopePalette.clip, 1.dp.toPx(), dashed)
}

/**
 * Blits the 128×128 density image into the square trace rect. The bilinear
 * upscale melts bins into soft blobs (approximating the iOS Gaussian pass);
 * a second crisp low-alpha draw keeps small saturated features locatable.
 */
private fun DrawScope.drawVectorDensity(image: ImageBitmap, square: Rect, opacity: Float) {
    val dstOffset = IntOffset(square.left.roundToInt(), square.top.roundToInt())
    val dstSize = IntSize(square.width.roundToInt(), square.height.roundToInt())
    drawImage(
        image,
        srcOffset = IntOffset.Zero,
        srcSize = IntSize(image.width, image.height),
        dstOffset = dstOffset,
        dstSize = dstSize,
        alpha = opacity,
        blendMode = androidx.compose.ui.graphics.BlendMode.Plus,
    )
    drawImage(
        image,
        srcOffset = IntOffset.Zero,
        srcSize = IntSize(image.width, image.height),
        dstOffset = dstOffset,
        dstSize = dstSize,
        alpha = 0.35f * opacity,
        blendMode = androidx.compose.ui.graphics.BlendMode.Plus,
    )
}

/**
 * Vectorscope graticule: outer ring, centre crosshair, the dashed I-phase
 * skin-tone line at 123°, and the six 75% targets at the core-supplied CbCr
 * positions ([ScopeAnchors.vectorTargets] — trace and graticule can never
 * disagree about the matrix).
 */
private fun DrawScope.drawVectorGraticule(anchors: ScopeAnchors, square: Rect) {
    val centre = square.center
    val radius = square.width / 2
    drawCircle(ScopePalette.graticule, radius, centre, style = Stroke(1.25.dp.toPx()))
    val cross = 8.dp.toPx()
    drawLine(
        ScopePalette.graticuleFaint,
        Offset(centre.x - cross, centre.y), Offset(centre.x + cross, centre.y), 1.dp.toPx(),
    )
    drawLine(
        ScopePalette.graticuleFaint,
        Offset(centre.x, centre.y - cross), Offset(centre.x, centre.y + cross), 1.dp.toPx(),
    )
    val skinAngle = Math.toRadians(123.0)
    drawLine(
        ScopePalette.middle,
        centre,
        Offset(
            centre.x + (cos(skinAngle) * radius * 0.92).toFloat(),
            centre.y - (sin(skinAngle) * radius * 0.92).toFloat(),
        ),
        1.dp.toPx(),
        pathEffect = PathEffect.dashPathEffect(floatArrayOf(4.dp.toPx(), 4.dp.toPx())),
    )
    val labels = listOf("R", "Mg", "B", "Cy", "G", "Yl")
    val boxSide = 7.dp.toPx()
    drawIntoCanvas { canvas ->
        val textPaint = Paint(Paint.ANTI_ALIAS_FLAG)
        textPaint.typeface = Typeface.create(Typeface.MONOSPACE, Typeface.BOLD)
        textPaint.textSize = 6.5.dp.toPx()
        textPaint.textAlign = Paint.Align.CENTER
        textPaint.color = android.graphics.Color.argb(140, 220, 235, 225)
        for ((index, target) in anchors.vectorTargets.withIndex()) {
            val point =
                Offset(
                    centre.x + target.first * square.width,
                    centre.y - target.second * square.height,
                )
            drawRect(
                ScopePalette.graticule.copy(alpha = 0.6f),
                topLeft = Offset(point.x - boxSide / 2, point.y - boxSide / 2),
                size = Size(boxSide, boxSide),
                style = Stroke(1.dp.toPx()),
            )
            val dx = point.x - centre.x
            val dy = point.y - centre.y
            val length = max(1f, sqrt(dx * dx + dy * dy))
            val push = 10.dp.toPx()
            canvas.nativeCanvas.drawText(
                labels[index],
                point.x + dx / length * push,
                point.y + dy / length * push + textPaint.textSize / 3,
                textPaint,
            )
        }
    }
}

package com.opencapture.openzcine

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.BlendMode
import android.graphics.Paint
import android.graphics.Typeface
import android.util.Log
import android.view.HapticFeedbackConstants
import android.view.TextureView
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.detectDragGesturesAfterLongPress
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
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
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.customActions
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
import com.opencapture.openzcine.lut.AndroidLutLibrary
import com.opencapture.openzcine.lut.PackedStoredLut
import com.opencapture.openzcine.lut.StoredLutSelection
import com.opencapture.openzcine.settings.ScopeAssistConfiguration
import com.opencapture.openzcine.settings.ScopeGuideLines
import com.opencapture.openzcine.settings.ScopeParadeMode
import com.opencapture.openzcine.settings.ScopeWaveformMode
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

private const val NANOS_PER_SECOND = 1_000_000_000.0

/** Widest reduction frame handed to the core sampler (1280→160, 1024→128). */
private const val REDUCTION_MAX_WIDTH = 160

/** Matches iOS's fixed 14pt bottom inset below its 58pt monitor control band. */
private const val LANDSCAPE_SCOPE_BOTTOM_CHROME_CLEARANCE = 14f + LiveDesign.CONTROL_HEIGHT_DP

/** iOS `feedOutsideCenter` gap between a floating panel and its cleared edge. */
private const val SCOPE_PANEL_EDGE_GAP = 10f

/** iOS exterior grip geometry: 14dp bracket in a 56dp operator touch target. */
private const val SCOPE_RESIZE_GRIP_VISUAL_SIZE = 14f
private const val SCOPE_RESIZE_GRIP_HIT_SIZE = 56f
private const val SCOPE_RESIZE_GRIP_EXTERIOR_GAP = 2f
private const val SCOPE_RESIZE_GRIP_PAD =
    SCOPE_RESIZE_GRIP_HIT_SIZE - SCOPE_RESIZE_GRIP_VISUAL_SIZE

private const val PLAYBACK_SCOPE_PLACEMENT_STORE = "playbackScopePanelPlacement"

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

/** Exact Android mirror of iOS `ScopeAssistSampling.thermalScopeInterval`. */
internal fun scopePeriodNanos(activeScopeCount: Int, thermalTier: AndroidThermalTier): Long {
    val baseFramesPerSecond = if (activeScopeCount > 3) 24.0 else 30.0
    val multiplier =
        when (thermalTier) {
            AndroidThermalTier.NOMINAL, AndroidThermalTier.FAIR -> 1.0
            // Core serious ×1.5 shedding, then iOS scope-specific ×2.
            AndroidThermalTier.SERIOUS -> 3.0
            // Core critical ×2 shedding, then iOS scope-specific ×2.5.
            AndroidThermalTier.CRITICAL -> 5.0
        }
    return (NANOS_PER_SECOND / baseFramesPerSecond * multiplier).roundToInt().toLong()
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
internal fun scopePanelBaseSize(kind: ScopeKind): Pair<Float, Float> =
    when (kind) {
        ScopeKind.WAVEFORM, ScopeKind.PARADE -> 250f to 153f
        ScopeKind.HISTOGRAM -> 250f to 77f
        ScopeKind.VECTORSCOPE -> 190f to 190f
        ScopeKind.TRAFFIC_LIGHTS -> 74f to 168f
    }

/** One floating panel's current requested physical size. */
fun scopePanelSize(
    kind: ScopeKind,
    configuration: ScopeAssistConfiguration = ScopeAssistConfiguration(),
): Pair<Float, Float> {
    val (width, height) = scopePanelBaseSize(kind)
    val scale =
        when (kind) {
            ScopeKind.WAVEFORM -> configuration.waveformScale
            ScopeKind.PARADE -> configuration.paradeScale
            ScopeKind.HISTOGRAM -> configuration.histogramScale
            ScopeKind.VECTORSCOPE -> configuration.vectorscopeScale
            ScopeKind.TRAFFIC_LIGHTS -> configuration.trafficLightsScale
        }
    return width * scale to height * scale
}

/** Uniform layout-only scale cap; applying it never rewrites the operator's stored scale. */
internal fun scopePresentationScale(
    kind: ScopeKind,
    requestedScale: Float,
    bounds: ZoneFrame,
): Float {
    val (baseWidth, baseHeight) = scopePanelBaseSize(kind)
    return scopePresentationScale(baseWidth, baseHeight, requestedScale, bounds)
}

private fun scopePresentationScale(
    baseWidth: Float,
    baseHeight: Float,
    requestedScale: Float,
    bounds: ZoneFrame,
): Float =
    minOf(
        ScopeAssistConfiguration.clampScale(requestedScale),
        bounds.width / baseWidth,
        bounds.height / baseHeight,
    ).coerceAtLeast(0f)

/** Current persisted scale for one scope kind. */
internal fun ScopeAssistConfiguration.scaleFor(kind: ScopeKind): Float =
    when (kind) {
        ScopeKind.WAVEFORM -> waveformScale
        ScopeKind.PARADE -> paradeScale
        ScopeKind.HISTOGRAM -> histogramScale
        ScopeKind.VECTORSCOPE -> vectorscopeScale
        ScopeKind.TRAFFIC_LIGHTS -> trafficLightsScale
    }

/** Copies one monitor resize gesture into its matching persisted field. */
internal fun ScopeAssistConfiguration.withScale(kind: ScopeKind, scale: Float): ScopeAssistConfiguration {
    val normalized = ScopeAssistConfiguration.clampScale(scale)
    return when (kind) {
        ScopeKind.WAVEFORM -> copy(waveformScale = normalized)
        ScopeKind.PARADE -> copy(paradeScale = normalized)
        ScopeKind.HISTOGRAM -> copy(histogramScale = normalized)
        ScopeKind.VECTORSCOPE -> copy(vectorscopeScale = normalized)
        ScopeKind.TRAFFIC_LIGHTS -> copy(trafficLightsScale = normalized)
    }
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
    configuration: ScopeAssistConfiguration = ScopeAssistConfiguration(),
): ZoneFrame {
    val (width, height) = scopePanelSize(kind, configuration)
    return floatingScopeFrame(kind, feed, infoBar, viewport, width, height)
}

private fun floatingScopeFrame(
    kind: ScopeKind,
    feed: ZoneFrame,
    infoBar: ZoneFrame,
    viewport: ZoneFrame,
    width: Float,
    height: Float,
): ZoneFrame {
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
            ScopeKind.VECTORSCOPE -> ZoneFrame(trailing, top, width, height)
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

/** Mirrors iOS `MovablePanel`'s four-point position grid. */
internal fun snapScopeFrame(frame: ZoneFrame): ZoneFrame =
    frame.copy(
        x = (frame.x / 4f).roundToInt() * 4f,
        y = (frame.y / 4f).roundToInt() * 4f,
    )

// ── Scope palette (iOS MonitorOverlays.swift `ScopePalette`, values 1:1) ──

private fun rgba(r: Int, g: Int, b: Int, a: Float) = Color(r / 255f, g / 255f, b / 255f, a)

private object ScopePalette {
    val lumaGhost = rgba(182, 190, 186, 0.08f)
    val luma = rgba(222, 230, 224, 1.0f)
    val lumaHot = rgba(255, 255, 255, 1.0f)
    val paradeRed = rgba(255, 86, 78, 1.0f)
    val paradeGreen = rgba(102, 232, 132, 1.0f)
    val paradeBlue = rgba(92, 156, 255, 1.0f)
    // RGB waveform overlays share one plot, so iOS uses lower-alpha colours
    // than the separated full-opacity parade lanes.
    val overlayRed = rgba(255, 64, 54, 0.55f)
    val overlayGreen = rgba(70, 240, 110, 0.55f)
    val overlayBlue = rgba(72, 148, 255, 0.62f)
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
    val vector: VectorDensityImage? = null,
    val vectorTrail: VectorDensityImage? = null,
    val trafficLights: TrafficLightsReading? = null,
)

/** Paired soft and crisp rasters used by the iOS-matching vectorscope passes. */
private data class VectorDensityImage(
    val soft: ImageBitmap,
    val crisp: ImageBitmap,
)

private class HistogramDisplay(
    val luma: FloatArray,
    val red: FloatArray,
    val green: FloatArray,
    val blue: FloatArray,
    val peak: Float,
)

/** One immutable native registration request for the vectorscope monitor cube. */
internal data class ScopeVectorLutRequest(
    val lookOrdinal: Int,
    val packedRgba: ByteArray? = null,
    val cubeSize: Int = 0,
)

/**
 * Resolves iOS's vectorscope LUT policy: the active operator LUT when enabled,
 * otherwise the camera curve's built-in monitor transform. A selected stored
 * cube that is unavailable fails closed, because substituting the camera curve
 * would plot a different monitor image than the feed. Preparation is retried
 * when the library render generation changes.
 */
internal fun scopeVectorLutRequest(
    selection: FeedLutSelection?,
    curveOrdinal: Int,
    packedStored: (StoredLutSelection) -> PackedStoredLut?,
): ScopeVectorLutRequest? =
    when (selection) {
        is FeedLutSelection.BuiltIn -> ScopeVectorLutRequest(selection.value.wireOrdinal)
        is FeedLutSelection.Stored ->
            packedStored(selection.value)?.let {
                ScopeVectorLutRequest(lookOrdinal = -1, packedRgba = it.rgba, cubeSize = it.cubeSize)
            }
        null -> ScopeVectorLutRequest(curveOrdinal)
    }

// ── Shared monitor coordinator ──

/**
 * Renders every selected scope from one monitor-owned sampler. A panel is a
 * pure view of [ScopeDrawData], so enabling five tools never creates five
 * JPEG decoders, frame collectors, or timer loops.
 */
@Composable
internal fun ScopePanels(
    selectedScopes: Set<ScopeKind>,
    portraitScopes: List<ScopeKind>,
    crushClipCompensationRaw: Int,
    histogramTrafficLightsEnabled: Boolean,
    configuration: ScopeAssistConfiguration,
    cameraInput: ExposureAssistCameraInput,
    lutSelection: FeedLutSelection?,
    lutLibrary: AndroidLutLibrary?,
    onScaleChange: (ScopeKind, Float) -> Unit,
    thermalTier: AndroidThermalTier,
    source: com.opencapture.openzcine.core.LiveFrameSource,
    isPortrait: Boolean,
    portraitFloating: Boolean = false,
    feed: ZoneFrame,
    infoBar: ZoneFrame,
    scopeZone: ZoneFrame?,
    panelLayout: MonitorAnalysisPanelLayout?,
    placementStore: MonitorAnalysisPanelPlacementStore,
    placementRevision: Int,
    hapticsEnabled: Boolean,
    onPanelFrameChanged: (MonitorAnalysisPanelID, ZoneFrame?) -> Unit = { _, _ -> },
) {
    val displayed =
        displayedScopeKinds(
            selectedScopes = selectedScopes,
            portraitScopes = portraitScopes,
            isPortrait = isPortrait,
            portraitFloating = portraitFloating,
        )
    // This guard also stops all collection when no displayed panel exists.
    if (displayed.isEmpty()) return
    if (isPortrait && !portraitFloating && scopeZone == null) return
    // A scope cannot honor camera-dependent display mapping without the Swift
    // facade, so fail closed rather than locally selecting a fallback curve.
    val mapping = remember(cameraInput) { resolveExposureAssistMapping(cameraInput) } ?: return
    val lutRenderGeneration = lutLibrary?.renderGeneration?.collectAsState()?.value ?: 0L
    LaunchedEffect(lutLibrary, lutSelection) {
        val stored = (lutSelection as? FeedLutSelection.Stored)?.value
        if (stored != null) lutLibrary?.prepare(stored)
    }
    val vectorLut =
        remember(lutSelection, mapping.curveOrdinal, lutLibrary, lutRenderGeneration) {
            scopeVectorLutRequest(lutSelection, mapping.curveOrdinal) { selection ->
                lutLibrary?.packedCube(selection)
            }
        }

    val snapshot =
        rememberScopeSnapshot(
            source,
            displayed.toSet(),
            crushClipCompensationRaw,
            histogramTrafficLightsEnabled,
            mapping.curveOrdinal,
            mapping.clipNative,
            configuration.vectorscopeZoom.wireOrdinal,
            configuration.vectorscopeBrightness,
            vectorLut,
            thermalTier,
        )
    val needsAnchors = displayed.any { it != ScopeKind.TRAFFIC_LIGHTS }
    val anchors =
        remember(needsAnchors, mapping.curveOrdinal) {
            if (needsAnchors) ScopeAnchors.parse(SwiftCore.scopeAnchors(mapping.curveOrdinal)) else null
        }

    if (isPortrait && !portraitFloating) {
        val zone = requireNotNull(scopeZone)
        PortraitScopePanels(
            displayed,
            zone,
            anchors,
            snapshot,
            histogramTrafficLightsEnabled,
            configuration,
        )
    } else {
        val layout = requireNotNull(panelLayout)
        FloatingScopePanels(
            displayed,
            feed,
            infoBar,
            layout,
            anchors,
            snapshot,
            histogramTrafficLightsEnabled,
            configuration,
            onScaleChange,
            placementStore = placementStore,
            placementRevision = placementRevision,
            hapticsEnabled = hapticsEnabled,
            onPanelFrameChanged = onPanelFrameChanged,
        )
    }
}

/**
 * Playback counterpart to [ScopePanels]. It renders the same panels and asks
 * the same Swift scope wires for analysis, but the frame tap is Media3's
 * TextureView rather than a camera JPEG flow. [currentFrameKey] is read on the
 * main thread and prevents a paused frame from being resampled indefinitely.
 * TextureView bitmap capture reads the decoded SurfaceTexture content before
 * the view's RenderEffect, preserving the clean-source scope invariant.
 */
@Composable
internal fun PlaybackScopePanels(
    selectedScopes: Set<ScopeKind>,
    crushClipCompensationRaw: Int,
    histogramTrafficLightsEnabled: Boolean,
    configuration: ScopeAssistConfiguration,
    cameraInput: ExposureAssistCameraInput,
    lutSelection: FeedLutSelection?,
    lutLibrary: AndroidLutLibrary?,
    onScaleChange: (ScopeKind, Float) -> Unit,
    thermalTier: AndroidThermalTier,
    textureView: TextureView,
    currentFrameKey: () -> Long,
    cleanFrameSource: PlaybackScopeFrameSource?,
    feed: ZoneFrame,
    infoBar: ZoneFrame,
    viewport: ZoneFrame,
) {
    val displayed = ScopeKind.canonical.filter(selectedScopes::contains)
    if (displayed.isEmpty()) return
    val mapping = remember(cameraInput) { resolveExposureAssistMapping(cameraInput) } ?: return
    val lutRenderGeneration = lutLibrary?.renderGeneration?.collectAsState()?.value ?: 0L
    LaunchedEffect(lutLibrary, lutSelection) {
        val stored = (lutSelection as? FeedLutSelection.Stored)?.value
        if (stored != null) lutLibrary?.prepare(stored)
    }
    val vectorLut =
        remember(lutSelection, mapping.curveOrdinal, lutLibrary, lutRenderGeneration) {
            scopeVectorLutRequest(lutSelection, mapping.curveOrdinal) { selection ->
                lutLibrary?.packedCube(selection)
            }
        }
    val latestFrameKey by rememberUpdatedState(currentFrameKey)
    val snapshot =
        rememberPlaybackScopeSnapshot(
            textureView = textureView,
            currentFrameKey = { latestFrameKey() },
            cleanFrameSource = cleanFrameSource,
            selected = displayed.toSet(),
            crushClipCompensationRaw = crushClipCompensationRaw,
            histogramTrafficLightsEnabled = histogramTrafficLightsEnabled,
            curveOrdinal = mapping.curveOrdinal,
            clipNative = mapping.clipNative,
            vectorscopeZoomOrdinal = configuration.vectorscopeZoom.wireOrdinal,
            vectorscopeBrightness = configuration.vectorscopeBrightness,
            vectorLut = vectorLut,
            thermalTier = thermalTier,
        )
    val needsAnchors = displayed.any { it != ScopeKind.TRAFFIC_LIGHTS }
    val anchors =
        remember(needsAnchors, mapping.curveOrdinal) {
            if (needsAnchors) ScopeAnchors.parse(SwiftCore.scopeAnchors(mapping.curveOrdinal)) else null
        }
    FloatingScopePanels(
        displayed = displayed,
        feed = feed,
        infoBar = infoBar,
        panelLayout = MonitorAnalysisPanelLayout(viewport = viewport, safeBounds = viewport),
        anchors = anchors,
        snapshot = snapshot,
        histogramTrafficLightsEnabled = histogramTrafficLightsEnabled,
        configuration = configuration,
        onScaleChange = onScaleChange,
        placementStoreName = PLAYBACK_SCOPE_PLACEMENT_STORE,
    )
}

/** Resolves stacked portrait-fit scopes versus uncapped floating fill/landscape scopes. */
internal fun displayedScopeKinds(
    selectedScopes: Set<ScopeKind>,
    portraitScopes: List<ScopeKind>,
    isPortrait: Boolean,
    portraitFloating: Boolean,
): List<ScopeKind> =
    if (isPortrait && !portraitFloating) {
        portraitScopes.filter(selectedScopes::contains)
    } else {
        ScopeKind.canonical.filter(selectedScopes::contains)
    }

/** Renders the portrait subset into the shared stack zone from the core layout map. */
@Composable
private fun PortraitScopePanels(
    displayed: List<ScopeKind>,
    zone: ZoneFrame,
    anchors: ScopeAnchors?,
    snapshot: ScopeDrawData?,
    histogramTrafficLightsEnabled: Boolean,
    configuration: ScopeAssistConfiguration,
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
                configuration = configuration,
                // iOS portrait fit gives each enabled scope an equal full-width
                // share and deliberately ignores landscape footprint scale.
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
private fun FloatingScopePanels(
    displayed: List<ScopeKind>,
    feed: ZoneFrame,
    infoBar: ZoneFrame,
    panelLayout: MonitorAnalysisPanelLayout,
    anchors: ScopeAnchors?,
    snapshot: ScopeDrawData?,
    histogramTrafficLightsEnabled: Boolean,
    configuration: ScopeAssistConfiguration,
    onScaleChange: (ScopeKind, Float) -> Unit,
    placementStoreName: String = "scopePanelPlacement",
    placementStore: MonitorAnalysisPanelPlacementStore? = null,
    placementRevision: Int = 0,
    hapticsEnabled: Boolean = true,
    onPanelFrameChanged: (MonitorAnalysisPanelID, ZoneFrame?) -> Unit = { _, _ -> },
) {
    val context = LocalContext.current.applicationContext
    val legacyStore =
        remember(context, placementStoreName, placementStore) {
            placementStore?.let { null } ?: ScopePanelPlacementStore(context, placementStoreName)
        }
    val scopeLayout =
        if (placementStore != null) {
            panelLayout.withScopeGripClearance()
        } else {
            panelLayout
        }
    Box(Modifier.fillMaxSize()) {
        displayed.forEach { kind ->
            key(kind) {
                val default =
                    controlSafeScopeDefaultFrame(
                        kind = kind,
                        feed = feed,
                        infoBar = infoBar,
                        layout = scopeLayout,
                        configuration = configuration,
                    )
                val baseSize = scopePanelBaseSize(kind)
                FloatingScopePanel(
                    kind = kind,
                    default = default,
                    panelLayout = scopeLayout,
                    scale = configuration.scaleFor(kind),
                    baseWidth = baseSize.first,
                    baseHeight = baseSize.second,
                    placementStore = placementStore,
                    legacyStore = legacyStore,
                    placementRevision = placementRevision,
                    hapticsEnabled = hapticsEnabled,
                    onPanelFrameChanged = onPanelFrameChanged,
                    onScaleChange = { onScaleChange(kind, it) },
                ) { modifier ->
                    ScopePanel(
                        kind = kind,
                        anchors = anchors,
                        data = snapshot,
                        histogramTrafficLightsEnabled = histogramTrafficLightsEnabled,
                        configuration = configuration,
                        fillsWidth = false,
                        modifier = modifier,
                    )
                }
            }
        }
    }
}

/** Preserves the established viewport-relative anchor, then applies control clearance exactly once. */
internal fun controlSafeScopeDefaultFrame(
    kind: ScopeKind,
    feed: ZoneFrame,
    infoBar: ZoneFrame,
    layout: MonitorAnalysisPanelLayout,
    configuration: ScopeAssistConfiguration = ScopeAssistConfiguration(),
): ZoneFrame =
    scopePanelBaseSize(kind).let { (baseWidth, baseHeight) ->
        val presentationScale =
            scopePresentationScale(
                kind = kind,
                requestedScale = configuration.scaleFor(kind),
                bounds = layout.safeBounds,
            )
        clampScopeFrame(
            floatingScopeFrame(
                kind = kind,
                feed = feed,
                infoBar = infoBar,
                viewport = layout.viewport,
                width = baseWidth * presentationScale,
                height = baseHeight * presentationScale,
            ),
            layout.safeBounds,
        )
    }

/** Leaves the exterior resize target inside the control-clear presentation frame. */
internal fun MonitorAnalysisPanelLayout.withScopeGripClearance(): MonitorAnalysisPanelLayout =
    copy(
        safeBounds =
            safeBounds.copy(
                width = max(0f, safeBounds.width - SCOPE_RESIZE_GRIP_PAD),
                height = max(0f, safeBounds.height - SCOPE_RESIZE_GRIP_PAD),
            ),
    )

/** Current Android equivalent of iOS's persisted movable panel centre. */
internal class ScopePanelPlacementStore(context: Context, name: String) {
    private val preferences = context.getSharedPreferences(name, Context.MODE_PRIVATE)

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
internal fun FloatingScopePanel(
    kind: ScopeKind,
    default: ZoneFrame,
    panelLayout: MonitorAnalysisPanelLayout,
    scale: Float,
    baseWidth: Float,
    baseHeight: Float,
    placementStore: MonitorAnalysisPanelPlacementStore?,
    legacyStore: ScopePanelPlacementStore?,
    placementRevision: Int,
    hapticsEnabled: Boolean,
    onPanelFrameChanged: (MonitorAnalysisPanelID, ZoneFrame?) -> Unit = { _, _ -> },
    onScaleChange: (Float) -> Unit,
    content: @Composable (Modifier) -> Unit,
) {
    val density = LocalDensity.current
    val view = LocalView.current
    val panelID = kind.monitorAnalysisPanelID()
    fun resolvedFrame(): ZoneFrame =
        placementStore?.resolve(panelID, default, panelLayout)
            ?: requireNotNull(legacyStore).resolve(kind, default, panelLayout.safeBounds)

    fun saveFrame(frame: ZoneFrame) {
        if (placementStore != null) {
            placementStore.save(panelID, frame, panelLayout)
        } else {
            requireNotNull(legacyStore).save(kind, frame, panelLayout.safeBounds)
        }
    }
    var frame by
        remember(kind, default, panelLayout, placementRevision) {
            mutableStateOf(resolvedFrame())
        }
    val currentFrameCallback by rememberUpdatedState(onPanelFrameChanged)
    SideEffect { currentFrameCallback(panelID, frame) }
    DisposableEffect(panelID) {
        onDispose { currentFrameCallback(panelID, null) }
    }
    var liveScale by
        remember(kind, scale, panelLayout, baseWidth, baseHeight) {
            mutableStateOf(
                scopePresentationScale(
                    baseWidth = baseWidth,
                    baseHeight = baseHeight,
                    requestedScale = scale,
                    bounds = panelLayout.safeBounds,
                ),
            )
        }
    var isDragging by remember { mutableStateOf(false) }
    var isResizing by remember { mutableStateOf(false) }
    var hapticCell by remember { mutableIntStateOf(Int.MIN_VALUE) }
    val outerFrame =
        frame.copy(
            width = frame.width + SCOPE_RESIZE_GRIP_PAD,
            height = frame.height + SCOPE_RESIZE_GRIP_PAD,
        )
    Box(
        Modifier
            .zone(outerFrame)
            .graphicsLayer {
                val lifted = isDragging || isResizing
                scaleX = if (lifted) 1.03f else 1f
                scaleY = if (lifted) 1.03f else 1f
                shadowElevation = if (lifted) 18.dp.toPx() else 0f
            },
    ) {
        Box(
            Modifier
                .size(frame.width.dp, frame.height.dp)
                .semantics {
                    contentDescription = "${kind.title} analysis panel, movable"
                    if (placementStore != null) {
                        customActions =
                            listOf(
                                CustomAccessibilityAction("Recenter ${kind.title} panel") {
                                    placementStore.recenter(panelID)
                                    frame = clampScopeFrame(default, panelLayout.safeBounds)
                                    true
                                },
                            )
                    }
                }
                .pointerInput(
                    kind,
                    default,
                    panelLayout,
                    baseWidth,
                    baseHeight,
                    scale,
                    placementRevision,
                    hapticsEnabled,
                ) {
                detectDragGesturesAfterLongPress(
                    onDragStart = {
                        isDragging = true
                        if (hapticsEnabled) {
                            view.performHapticFeedback(HapticFeedbackConstants.LONG_PRESS)
                        }
                    },
                    onDragEnd = {
                        isDragging = false
                        saveFrame(frame)
                    },
                    onDragCancel = { isDragging = false },
                ) { change, dragAmount ->
                    change.consume()
                    val snapped =
                        clampScopeFrame(
                            snapScopeFrame(
                                frame.copy(
                                    x = frame.x + dragAmount.x / density.density,
                                    y = frame.y + dragAmount.y / density.density,
                                ),
                            ),
                            panelLayout.safeBounds,
                        )
                    val cell =
                        ((snapped.x + snapped.width / 2f) / 22f).roundToInt() * 100_000 +
                            ((snapped.y + snapped.height / 2f) / 22f).roundToInt()
                    if (cell != hapticCell) {
                        hapticCell = cell
                        if (hapticsEnabled) {
                            view.performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP)
                        }
                    }
                    frame = snapped
                }
            },
        ) {
            content(Modifier.fillMaxSize())
        }
        Canvas(
            Modifier
                .offset(
                    (frame.width - SCOPE_RESIZE_GRIP_VISUAL_SIZE).dp,
                    (frame.height - SCOPE_RESIZE_GRIP_VISUAL_SIZE).dp,
                )
                .size(SCOPE_RESIZE_GRIP_HIT_SIZE.dp)
                .semantics { contentDescription = "Resize ${kind.title} panel" }
                .pointerInput(
                    kind,
                    default,
                    panelLayout,
                    baseWidth,
                    baseHeight,
                    scale,
                    placementRevision,
                    hapticsEnabled,
                ) {
                    var startScale = liveScale
                    var accumulated = 0f
                    detectDragGesturesAfterLongPress(
                        onDragStart = {
                            isResizing = true
                            startScale = liveScale
                            accumulated = 0f
                            if (hapticsEnabled) {
                                view.performHapticFeedback(HapticFeedbackConstants.LONG_PRESS)
                            }
                        },
                        onDragEnd = {
                            isResizing = false
                            saveFrame(frame)
                            onScaleChange(liveScale)
                        },
                        onDragCancel = {
                            isResizing = false
                            onScaleChange(liveScale)
                        },
                    ) { change, dragAmount ->
                        change.consume()
                        accumulated += (dragAmount.x + dragAmount.y) / density.density
                        val requested =
                            ScopeAssistConfiguration.clampScale(
                                startScale + accumulated / (baseWidth + baseHeight),
                            )
                        val fitted =
                            scopePresentationScale(
                                baseWidth = baseWidth,
                                baseHeight = baseHeight,
                                requestedScale = requested,
                                bounds = panelLayout.safeBounds,
                            )
                        val rounded =
                            scopePresentationScale(
                                baseWidth = baseWidth,
                                baseHeight = baseHeight,
                                requestedScale = (fitted * 100).roundToInt() / 100f,
                                bounds = panelLayout.safeBounds,
                            )
                        val centerX = frame.x + frame.width / 2f
                        val centerY = frame.y + frame.height / 2f
                        liveScale = rounded
                        frame =
                            clampScopeFrame(
                                ZoneFrame(
                                    centerX - baseWidth * rounded / 2f,
                                    centerY - baseHeight * rounded / 2f,
                                    baseWidth * rounded,
                                    baseHeight * rounded,
                                ),
                                panelLayout.safeBounds,
                            )
                    }
                },
        ) {
            val leg = SCOPE_RESIZE_GRIP_VISUAL_SIZE.dp.toPx()
            val vertex = Offset(leg + SCOPE_RESIZE_GRIP_EXTERIOR_GAP.dp.toPx(), leg + SCOPE_RESIZE_GRIP_EXTERIOR_GAP.dp.toPx())
            val color = if (isResizing) LiveDesign.accent else LiveDesign.muted
            drawLine(color, vertex, Offset(vertex.x - leg, vertex.y), 1.5.dp.toPx())
            drawLine(color, vertex, Offset(vertex.x, vertex.y - leg), 1.5.dp.toPx())
        }
    }
}

/** One panel view of the shared [ScopeDrawData]; it never samples or collects frames itself. */
@Composable
private fun ScopePanel(
    kind: ScopeKind,
    anchors: ScopeAnchors?,
    data: ScopeDrawData?,
    histogramTrafficLightsEnabled: Boolean,
    configuration: ScopeAssistConfiguration,
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
            drawScope(kind, resolvedAnchors, data, histogramTrafficLightsEnabled, configuration)
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
                scopeChip(kind, configuration),
                style = chromeStyle(9.5f, FontWeight.Bold, mono = true),
                color = LiveDesign.text.copy(alpha = 0.58f),
                maxLines = 1,
            )
        }
    }
}

/** Compact current-option readout in each scope title bar. */
private fun scopeChip(kind: ScopeKind, configuration: ScopeAssistConfiguration): String =
    when (kind) {
        ScopeKind.WAVEFORM -> configuration.waveformMode.label
        ScopeKind.PARADE -> configuration.paradeMode.label
        ScopeKind.HISTOGRAM -> ScopeKind.HISTOGRAM.chip
        ScopeKind.VECTORSCOPE -> "MON · ${configuration.vectorscopeZoom.label}"
        ScopeKind.TRAFFIC_LIGHTS -> ScopeKind.TRAFFIC_LIGHTS.chip
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
    curveOrdinal: Int,
    clipNative: Float,
    vectorscopeZoomOrdinal: Int,
    vectorscopeBrightness: Int,
    vectorLut: ScopeVectorLutRequest?,
    thermalTier: AndroidThermalTier,
): ScopeDrawData? {
    val data = remember { mutableStateOf<ScopeDrawData?>(null) }
    val ordered = ScopeKind.canonical.filter(selected::contains)
    LaunchedEffect(
        source,
        ordered,
        crushClipCompensationRaw,
        histogramTrafficLightsEnabled,
        curveOrdinal,
        clipNative,
        vectorscopeZoomOrdinal,
        vectorscopeBrightness,
        vectorLut,
        thermalTier,
    ) {
        data.value = null
        withContext(Dispatchers.Default) {
            pumpScopes(
                source.frames,
                ordered.toSet(),
                crushClipCompensationRaw,
                histogramTrafficLightsEnabled,
                curveOrdinal,
                clipNative,
                vectorscopeZoomOrdinal,
                vectorscopeBrightness,
                vectorLut,
                scopePeriodNanos(ordered.size, thermalTier),
            ) { data.value = it }
        }
    }
    return data.value
}

/** One cancellation-safe scope snapshot sourced from decoded Media3 video. */
@Composable
private fun rememberPlaybackScopeSnapshot(
    textureView: TextureView,
    currentFrameKey: () -> Long,
    cleanFrameSource: PlaybackScopeFrameSource?,
    selected: Set<ScopeKind>,
    crushClipCompensationRaw: Int,
    histogramTrafficLightsEnabled: Boolean,
    curveOrdinal: Int,
    clipNative: Float,
    vectorscopeZoomOrdinal: Int,
    vectorscopeBrightness: Int,
    vectorLut: ScopeVectorLutRequest?,
    thermalTier: AndroidThermalTier,
): ScopeDrawData? {
    val data = remember { mutableStateOf<ScopeDrawData?>(null) }
    val tap = remember(textureView) { PlaybackScopeFrameTap() }
    val ordered = ScopeKind.canonical.filter(selected::contains)
    LaunchedEffect(
        textureView,
        cleanFrameSource,
        ordered,
        crushClipCompensationRaw,
        histogramTrafficLightsEnabled,
        curveOrdinal,
        clipNative,
        vectorscopeZoomOrdinal,
        vectorscopeBrightness,
        vectorLut,
        thermalTier,
    ) {
        data.value = null
        if (cleanFrameSource != null) cleanFrameSource.reset() else tap.reset()
        withContext(Dispatchers.Default) {
            pumpReducedScopes(
                selected = ordered.toSet(),
                crushClipCompensationRaw = crushClipCompensationRaw,
                histogramTrafficLightsEnabled = histogramTrafficLightsEnabled,
                curveOrdinal = curveOrdinal,
                clipNative = clipNative,
                vectorscopeZoomOrdinal = vectorscopeZoomOrdinal,
                vectorscopeBrightness = vectorscopeBrightness,
                vectorLut = vectorLut,
                scopePeriodNanos = scopePeriodNanos(ordered.size, thermalTier),
                nextFrame = {
                    if (cleanFrameSource != null) {
                        cleanFrameSource.capture()
                    } else {
                        tap.capture(textureView, currentFrameKey)
                    }
                },
                present = { data.value = it },
            )
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
    curveOrdinal: Int,
    clipNative: Float,
    vectorscopeZoomOrdinal: Int,
    vectorscopeBrightness: Int,
    vectorLut: ScopeVectorLutRequest?,
    scopePeriodNanos: Long,
    present: (ScopeDrawData) -> Unit,
): Unit = coroutineScope {
    val latest = AtomicReference<LiveScopeInput?>(null)
    var generation = 0L
    val collector =
        launch {
            frames.collect { frame ->
                generation += 1
                latest.set(LiveScopeInput(generation, frame.jpegData))
            }
        }
    val tap = ScopeFrameTap()
    var lastGeneration = Long.MIN_VALUE
    try {
        pumpReducedScopes(
            selected = selected,
            crushClipCompensationRaw = crushClipCompensationRaw,
            histogramTrafficLightsEnabled = histogramTrafficLightsEnabled,
            curveOrdinal = curveOrdinal,
            clipNative = clipNative,
            vectorscopeZoomOrdinal = vectorscopeZoomOrdinal,
            vectorscopeBrightness = vectorscopeBrightness,
            vectorLut = vectorLut,
            scopePeriodNanos = scopePeriodNanos,
            nextFrame = {
                val next = latest.get() ?: return@pumpReducedScopes null
                if (next.generation == lastGeneration) return@pumpReducedScopes null
                lastGeneration = next.generation
                tap.reduce(next.jpeg)
            },
            present = present,
        )
    } finally {
        collector.cancel()
    }
}

/**
 * Absolute-schedule clean-frame sampler shared by live JPEG and playback
 * TextureView inputs. All signal analysis and display-axis policy remains in
 * the Swift core; this loop only owns demand, cadence, and immutable trails.
 */
private suspend fun pumpReducedScopes(
    selected: Set<ScopeKind>,
    crushClipCompensationRaw: Int,
    histogramTrafficLightsEnabled: Boolean,
    curveOrdinal: Int,
    clipNative: Float,
    vectorscopeZoomOrdinal: Int,
    vectorscopeBrightness: Int,
    vectorLut: ScopeVectorLutRequest?,
    scopePeriodNanos: Long,
    nextFrame: suspend () -> ReducedScopeFrame?,
    present: (ScopeDrawData) -> Unit,
) {
    val demand = scopeSamplingDemand(selected, histogramTrafficLightsEnabled)
    if (!demand.traces && !demand.vector) return

    val vectorLutHandle =
        if (demand.vector && vectorLut != null) {
            SwiftCore.registerScopeVectorLut(
                vectorLut.lookOrdinal,
                vectorLut.packedRgba,
                vectorLut.cubeSize,
            )
        } else {
            0L
        }
    if (demand.vector && vectorLutHandle <= 0) {
        Log.w(TAG, "active vectorscope LUT is unavailable; vectorscope rendering disabled")
        if (!demand.traces) return
    }

    try {
        val stats = ScopeTickStats { if (BuildConfig.DEBUG) Log.d(TAG, it) }
        val vectorBitmaps = VectorBitmapRing()
        var previousTraces: ScopeTraces? = null
        var previousHistogram: ScopeTraces? = null
        var previousVector: VectorDensityImage? = null
        val startNanos = System.nanoTime()
        var tick = 0L
        while (true) {
            tick = max(tick + 1, (System.nanoTime() - startNanos) / scopePeriodNanos)
            val waitMillis = (startNanos + tick * scopePeriodNanos - System.nanoTime()) / 1_000_000
            if (waitMillis > 0) delay(waitMillis)

            val tickStart = System.nanoTime()
            val reduced = nextFrame() ?: continue
            val traces =
                if (demand.traces) {
                    try {
                        ScopeTraces.parse(
                            SwiftCore.scopeTraces(
                                reduced.rgba, reduced.width, reduced.height,
                                reduced.bytesPerRow,
                                curveOrdinal,
                                clipNative,
                                crushClipCompensationRaw,
                                demand.pointTrace,
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
                if (demand.vector && vectorLutHandle > 0) {
                    vectorBitmaps.imageFrom(
                        SwiftCore.scopeVector(
                            reduced.rgba, reduced.width, reduced.height,
                            reduced.bytesPerRow,
                            curveOrdinal,
                            vectorscopeZoomOrdinal,
                            vectorscopeBrightness,
                            vectorLutHandle,
                        ),
                    )
                } else {
                    null
                }

            val traceForPanel = traces.takeIf { demand.pointTrace }
            val histogram =
                traces?.takeIf { demand.histogram }?.let { histogramDisplay(it, previousHistogram) }
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
            if (demand.vector && vectorLutHandle > 0) previousVector = vector
            stats.tickCompleted(System.nanoTime() - tickStart, System.nanoTime())
        }
    } finally {
        if (vectorLutHandle > 0) SwiftCore.unregisterScopeVectorLut(vectorLutHandle)
    }
}

private data class LiveScopeInput(val generation: Long, val jpeg: ByteArray)

/** One reduced frame ready for the core sampler. */
internal class ReducedScopeFrame(
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

    fun reduce(jpeg: ByteArray): ReducedScopeFrame? {
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
        return ReducedScopeFrame(rgba, decoded.width, decoded.height, decoded.rowBytes)
    }
}

/**
 * Media3 TextureView → small RGBA reduction for playback scopes.
 *
 * Capture happens on the main thread as required by TextureView, directly
 * into a reused 160px-wide bitmap. The bitmap copy is the SurfaceTexture's
 * decoded image; a RenderEffect attached to the view is composited later by
 * RenderNode and is therefore absent from this clean scope input.
 */
private class PlaybackScopeFrameTap {
    private var bitmap: Bitmap? = null
    private var rgba = ByteArray(0)
    private var lastFrameKey = Long.MIN_VALUE

    /** Allows a restarted analysis pipeline to sample the current paused frame once. */
    fun reset() {
        lastFrameKey = Long.MIN_VALUE
    }

    suspend fun capture(textureView: TextureView, frameKey: () -> Long): ReducedScopeFrame? =
        withContext(Dispatchers.Main.immediate) {
            if (!textureView.isAvailable || textureView.width <= 0 || textureView.height <= 0) {
                return@withContext null
            }
            val key = frameKey()
            if (key == lastFrameKey) return@withContext null
            val targetWidth = min(REDUCTION_MAX_WIDTH, textureView.width)
            val targetHeight =
                max(
                    1,
                    (textureView.height.toLong() * targetWidth / textureView.width).toInt(),
                )
            val target =
                bitmap?.takeIf { it.width == targetWidth && it.height == targetHeight }
                    ?: Bitmap.createBitmap(targetWidth, targetHeight, Bitmap.Config.ARGB_8888)
            val captured =
                try {
                    textureView.getBitmap(target)
                } catch (_: IllegalStateException) {
                    null
                } ?: return@withContext null
            bitmap = captured
            val byteCount = captured.rowBytes * captured.height
            if (rgba.size != byteCount) rgba = ByteArray(byteCount)
            captured.copyPixelsToBuffer(ByteBuffer.wrap(rgba))
            lastFrameKey = key
            ReducedScopeFrame(rgba, captured.width, captured.height, captured.rowBytes)
        }
}

/** A clean decoded-frame source owned by a playback video effect. */
internal interface PlaybackScopeFrameSource {
    /** Allows a restarted analysis pipeline to consume the current paused frame once. */
    fun reset()

    /** Returns the newest unconsumed reduced frame, or null when no decoded frame changed. */
    suspend fun capture(): ReducedScopeFrame?
}

/**
 * Ring of reused 128×128 bitmaps for the vectorscope density image — 3 deep so
 * the bitmap being written is never one the RenderThread may still read
 * (current frame + trail), mirroring [JpegFrameDecoder]'s ring rationale.
 */
private class VectorBitmapRing {
    private val crispPool = arrayOfNulls<Bitmap>(3)
    private val softPool = arrayOfNulls<Bitmap>(3)
    private var next = 0

    fun imageFrom(displayRgba: ByteArray): VectorDensityImage? {
        if (!isValidVectorPayloadSize(displayRgba.size)) return null
        val side = 128
        val imageByteCount = side * side * 4
        var crispBitmap = crispPool[next]
        if (crispBitmap == null || crispBitmap.width != side) {
            crispBitmap = Bitmap.createBitmap(side, side, Bitmap.Config.ARGB_8888)
            crispPool[next] = crispBitmap
        }
        var softBitmap = softPool[next]
        if (softBitmap == null || softBitmap.width != side) {
            softBitmap = Bitmap.createBitmap(side, side, Bitmap.Config.ARGB_8888)
            softPool[next] = softBitmap
        }
        softBitmap.copyPixelsFromBuffer(ByteBuffer.wrap(displayRgba, 0, imageByteCount))
        crispBitmap.copyPixelsFromBuffer(
            ByteBuffer.wrap(displayRgba, imageByteCount, imageByteCount),
        )
        next = (next + 1) % crispPool.size
        return VectorDensityImage(softBitmap.asImageBitmap(), crispBitmap.asImageBitmap())
    }
}

/** Swift vectorscope payloads are exactly one soft + crisp 128×128 RGBA pair. */
internal fun isValidVectorPayloadSize(byteCount: Int): Boolean = byteCount == 2 * 128 * 128 * 4

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

/** Cadence accounting: achieved rate plus per-tick cost every 5 seconds. */
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
    configuration: ScopeAssistConfiguration,
) {
    val plot =
        if (kind == ScopeKind.HISTOGRAM) {
            histogramPlotRect(histogramTrafficLightsEnabled)
        } else {
            plotRect()
        }
    when (kind) {
        ScopeKind.WAVEFORM, ScopeKind.PARADE -> {
            val brightness =
                if (kind == ScopeKind.WAVEFORM) {
                    configuration.waveformBrightness / 100f
                } else {
                    configuration.paradeBrightness / 100f
                }
            data?.trailTraces?.let {
                drawTrace(kind, it, plot, ScopePalette.TRAIL_DECAY * brightness, configuration)
            }
            data?.traces?.let { drawTrace(kind, it, plot, brightness, configuration) }
            val guides =
                if (kind == ScopeKind.WAVEFORM) configuration.waveformGuides else configuration.paradeGuides
            drawAxisGuides(anchors, plot, guides)
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
            data?.vectorTrail?.let {
                drawVectorDensity(it, square, ScopePalette.TRAIL_DECAY, crispCore = false)
            }
            data?.vector?.let { drawVectorDensity(it, square, 1f, crispCore = true) }
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
        scopeTracePassOpacities(opacity).forEach { passOpacity ->
            paint.color =
                android.graphics.Color.argb(
                    scopeTraceAlpha(color.alpha, passOpacity),
                    (color.red * 255).roundToInt(),
                    (color.green * 255).roundToInt(),
                    (color.blue * 255).roundToInt(),
                )
            canvas.nativeCanvas.drawPoints(xy, 0, count * 2, paint)
        }
    }
}

/** Converts a possibly boosted trace opacity into Android's non-wrapping 8-bit alpha. */
internal fun scopeTraceAlpha(colorAlpha: Float, opacity: Float): Int =
    (colorAlpha * opacity * 255).roundToInt().coerceIn(0, 255)

/** Splits a 0…2 brightness gain into additive, non-wrapping Canvas passes. */
internal fun scopeTracePassOpacities(opacity: Float): List<Float> {
    var remaining = opacity.coerceIn(0f, 2f)
    val passes = mutableListOf<Float>()
    while (remaining > 0f) {
        val pass = min(1f, remaining)
        passes += pass
        remaining -= pass
    }
    return passes
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

private fun DrawScope.drawTrace(
    kind: ScopeKind,
    traces: ScopeTraces,
    plot: Rect,
    opacity: Float,
    configuration: ScopeAssistConfiguration,
) {
    if (traces.pointCount == 0) return
    var scratch = pointScratch.get() ?: FloatArray(0)
    if (scratch.size < traces.pointCount * 2) {
        scratch = FloatArray(traces.pointCount * 2)
        pointScratch.set(scratch)
    }
    when (kind) {
        ScopeKind.WAVEFORM -> {
            if (configuration.waveformMode == ScopeWaveformMode.LUMA) {
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
            } else {
                waveformRgbChannels(traces, plot, scratch, opacity)
            }
        }
        ScopeKind.PARADE -> {
            val lanes =
                if (configuration.paradeMode == ScopeParadeMode.RGB) {
                    listOf(
                        Pair(2, ScopePalette.paradeRed),
                        Pair(3, ScopePalette.paradeGreen),
                        Pair(4, ScopePalette.paradeBlue),
                    )
                } else {
                    listOf(
                        Pair(1, ScopePalette.luma),
                        Pair(2, ScopePalette.paradeRed),
                        Pair(3, ScopePalette.paradeGreen),
                        Pair(4, ScopePalette.paradeBlue),
                    )
                }
            val laneWidth = plot.width / lanes.size
            for ((laneIndex, lane) in lanes.withIndex()) {
                val origin = plot.left + laneIndex * laneWidth
                val count = fillChannel(traces, lane.first, plot, origin, laneWidth - 1, scratch)
                drawPointPass(scratch, count, lane.second, 1.dp.toPx(), opacity)
            }
        }
        else -> Unit
    }
}

/** RGB waveform mode overlays source channels over the same horizontal scan. */
private fun DrawScope.waveformRgbChannels(
    traces: ScopeTraces,
    plot: Rect,
    scratch: FloatArray,
    opacity: Float,
) {
    val channels =
        listOf(
            Pair(2, ScopePalette.overlayRed),
            Pair(3, ScopePalette.overlayGreen),
            Pair(4, ScopePalette.overlayBlue),
        )
    for ((offset, color) in channels) {
        val count = fillChannel(traces, offset, plot, plot.left, plot.width, scratch)
        drawPointPass(scratch, count, color, 1.dp.toPx(), opacity)
    }
}

/** Boundary lines (code 0/255) plus the three fixed anchor lines. */
private fun DrawScope.drawAxisGuides(anchors: ScopeAnchors, plot: Rect, guides: ScopeGuideLines) {
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
    if (guides.clip) line(anchors.clipLine, ScopePalette.clip, 1.dp.toPx(), dashed)
    if (guides.middle) line(anchors.midGray, ScopePalette.middle, 1.dp.toPx())
    if (guides.crush) line(anchors.crushLine, ScopePalette.clip, 1.dp.toPx(), dashed)
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
 * Blits the 128×128 density image into the square trace rect. [image.soft] is
 * a real 1.1-bin Gaussian pass, matching iOS; current traces add the same 0.35
 * crisp core while phosphor trails remain soft-only.
 */
private fun DrawScope.drawVectorDensity(
    image: VectorDensityImage,
    square: Rect,
    opacity: Float,
    crispCore: Boolean,
) {
    val dstOffset = IntOffset(square.left.roundToInt(), square.top.roundToInt())
    val dstSize = IntSize(square.width.roundToInt(), square.height.roundToInt())
    drawImage(
        image.soft,
        srcOffset = IntOffset.Zero,
        srcSize = IntSize(image.soft.width, image.soft.height),
        dstOffset = dstOffset,
        dstSize = dstSize,
        alpha = opacity,
        blendMode = androidx.compose.ui.graphics.BlendMode.Plus,
    )
    if (!crispCore) return
    drawImage(
        image.crisp,
        srcOffset = IntOffset.Zero,
        srcSize = IntSize(image.crisp.width, image.crisp.height),
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

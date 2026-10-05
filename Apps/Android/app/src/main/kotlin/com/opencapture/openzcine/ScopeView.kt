package com.opencapture.openzcine

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.util.Log
import android.view.HapticFeedbackConstants
import android.view.TextureView
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.gestures.detectDragGesturesAfterLongPress
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.size
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
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalResources
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.unit.dp
import androidx.compose.ui.zIndex
import com.opencapture.monitorui.MonitorHistogramScopePlot
import com.opencapture.monitorui.MonitorMaterial
import com.opencapture.monitorui.MonitorParadeScopePlot
import com.opencapture.monitorui.MonitorScopePanelMath
import com.opencapture.monitorui.MonitorTrafficLightsGeometry
import com.opencapture.monitorui.MonitorTrafficLightsMeter
import com.opencapture.monitorui.MonitorVectorscopeScopePlot
import com.opencapture.monitorui.MonitorWaveformScopePlot
import com.opencapture.monitorui.monitorMaterial
import com.opencapture.opencine.appkit.MonitorAssistState
import com.opencapture.opencine.media.MonitorLUTCube
import com.opencapture.opencine.media.MonitorTransfer
import com.opencapture.opencine.media.ScopeAssistBundle
import com.opencapture.opencine.media.ScopeChannelLight
import com.opencapture.opencine.media.ScopeHistogramDisplay
import com.opencapture.opencine.media.ScopeLevelAxis
import com.opencapture.opencine.media.ScopeSampler
import com.opencapture.opencine.media.ScopeSamples
import com.opencapture.opencine.media.ScopeTrafficLightsReading
import com.opencapture.opencine.nikon.LiveFrame
import com.opencapture.opencine.nikon.LiveFrameSource
import com.opencapture.opencine.runtime.ScopeSampleBus
import com.opencapture.openzcine.bridge.SwiftCore
import com.opencapture.openzcine.bridge.ZoneFrame
import com.opencapture.openzcine.lut.AndroidLutLibrary
import com.opencapture.openzcine.lut.PackedStoredLut
import com.opencapture.openzcine.lut.StoredLutSelection
import java.nio.ByteBuffer
import java.util.concurrent.atomic.AtomicReference
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
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

/** Sampling step in pixels, the iOS live tap's `ScopeAssistSampling.pointStride`. */
private const val SAMPLE_STRIDE = 2

/** Code values per level axis and per histogram channel. */
private const val LEVEL_AXIS_BINS = 256

/** Built-in vectorscope look size, as the feed's baked built-in LUTs. */
private const val VECTOR_LUT_SIZE = 33

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
enum class ScopeKind(val token: String) {
    WAVEFORM("wave"),
    PARADE("parade"),
    HISTOGRAM("histo"),
    VECTORSCOPE("vector"),
    TRAFFIC_LIGHTS("lights"),
    ;

    /**
     * Whether this scope is offered in still photography. Only the histogram is
     * (mirrors `MonitorAssistTool.appliesToPhotography` on iOS, where among the
     * scope tools HISTO alone is photography-visible); the cinema scopes are
     * suppressed, so a photography scope band must not bill them.
     */
    val appliesToPhotography: Boolean
        get() = this == HISTOGRAM

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

@Composable
private fun scopeTitle(kind: ScopeKind): String =
    stringResource(
        when (kind) {
            ScopeKind.WAVEFORM -> R.string.scope_title_waveform
            ScopeKind.PARADE -> R.string.scope_title_parade
            ScopeKind.HISTOGRAM -> R.string.scope_title_histogram
            ScopeKind.VECTORSCOPE -> R.string.scope_title_vectorscope
            ScopeKind.TRAFFIC_LIGHTS -> R.string.scope_title_traffic_lights
        },
    )

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
    // iOS refreshes its scopes at ~10 Hz; ticking faster than the reference
    // buys nothing visually and triples decode + raster + redraw work.
    val baseFramesPerSecond = if (activeScopeCount > 3) 10.0 else 12.0
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
    assist: MonitorAssistState = MonitorAssistState(),
): Pair<Float, Float> {
    val (width, height) = scopePanelBaseSize(kind)
    val scale = assist.scaleFor(kind)
    return width * scale to height * scale
}

/** The shared panel scale range. */
internal fun clampScopeScale(value: Float): Float = MonitorScopePanelMath.clampedScale(value.toDouble()).toFloat()

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
        clampScopeScale(requestedScale),
        bounds.width / baseWidth,
        bounds.height / baseHeight,
    ).coerceAtLeast(0f)

/** Current persisted scale for one scope kind. */
internal fun MonitorAssistState.scaleFor(kind: ScopeKind): Float =
    when (kind) {
        ScopeKind.WAVEFORM -> waveScale
        ScopeKind.PARADE -> paradeScale
        ScopeKind.HISTOGRAM -> histoScale
        ScopeKind.VECTORSCOPE -> vectorScale
        ScopeKind.TRAFFIC_LIGHTS -> lightsScale
    }.toFloat()

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
    assist: MonitorAssistState = MonitorAssistState(),
): ZoneFrame {
    val (width, height) = scopePanelSize(kind, assist)
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

/** The vectorscope's monitor look as a shared cube; null fails closed (no trace). */
internal fun ScopeVectorLutRequest.cube(): MonitorLUTCube? =
    packedRgba?.let { runCatching { MonitorLUTCube(cubeSize, it) }.getOrNull() }
        ?: SwiftCore.bakeLut(lookOrdinal, VECTOR_LUT_SIZE)?.let { MonitorLUTCube(VECTOR_LUT_SIZE, it) }

/** This camera's level axis for the shared plots (Swift `ScopeFrameWire.levelAxis`). */
private fun nikonScopeLevelAxis(curveOrdinal: Int, clipNative: Float): ScopeLevelAxis? {
    val flat = SwiftCore.scopeLevelAxis(curveOrdinal, clipNative)
    if (flat.size != LEVEL_AXIS_BINS + 1) return null
    return ScopeLevelAxis(flat.copyOf(LEVEL_AXIS_BINS), flat[LEVEL_AXIS_BINS].toDouble())
}

/** The core Traffic Lights meter on this tick's shared histograms. */
private fun nikonTrafficLights(samples: ScopeSamples, inputs: ScopeTickInputs): ScopeTrafficLightsReading {
    val histograms = FloatArray(4 * LEVEL_AXIS_BINS)
    listOf(samples.histogramLuma, samples.histogramRed, samples.histogramGreen, samples.histogramBlue)
        .forEachIndexed { channel, bins ->
            for (index in 0 until minOf(bins.size, LEVEL_AXIS_BINS)) {
                histograms[channel * LEVEL_AXIS_BINS + index] = bins[index].toFloat()
            }
        }
    val flat =
        SwiftCore.scopeTrafficLights(
            histograms, inputs.curveOrdinal, inputs.clipNative, inputs.crushClipCompensationRaw)
    if (flat.size != 9) return ScopeTrafficLightsReading.NONE
    fun light(channel: Int) =
        ScopeChannelLight(
            clip = flat[channel * 3 + 1] != 0f,
            crush = flat[channel * 3 + 2] != 0f,
            level = flat[channel * 3].toDouble(),
        )
    return ScopeTrafficLightsReading(light(0), light(1), light(2))
}

/** Everything one sampler run needs; a change restarts the run. */
private data class ScopeTickInputs(
    val selected: Set<ScopeKind>,
    val histogramTrafficLightsEnabled: Boolean,
    val crushClipCompensationRaw: Int,
    val curveOrdinal: Int,
    val clipNative: Float,
    val axis: ScopeLevelAxis,
    val vectorLut: ScopeVectorLutRequest?,
    val periodNanos: Long,
)

@Composable
private fun rememberScopeVectorLut(
    lutSelection: FeedLutSelection?,
    lutLibrary: AndroidLutLibrary?,
    curveOrdinal: Int,
): ScopeVectorLutRequest? {
    val lutRenderGeneration = lutLibrary?.renderGeneration?.collectAsState()?.value ?: 0L
    LaunchedEffect(lutLibrary, lutSelection) {
        val stored = (lutSelection as? FeedLutSelection.Stored)?.value
        if (stored != null) lutLibrary?.prepare(stored)
    }
    return remember(lutSelection, curveOrdinal, lutLibrary, lutRenderGeneration) {
        scopeVectorLutRequest(lutSelection, curveOrdinal) { selection ->
            lutLibrary?.packedCube(selection)
        }
    }
}

// ── Shared monitor coordinator ──

/**
 * Renders every selected scope from one monitor-owned sampler that publishes
 * the shared [ScopeAssistBundle] on a [ScopeSampleBus]. A panel is a pure view
 * of the bus, so enabling five tools never creates five JPEG decoders, frame
 * collectors, or timer loops.
 */
@Composable
internal fun ScopePanels(
    selectedScopes: Set<ScopeKind>,
    portraitScopes: List<ScopeKind>,
    assist: MonitorAssistState,
    cameraInput: ExposureAssistCameraInput,
    lutSelection: FeedLutSelection?,
    lutLibrary: AndroidLutLibrary?,
    thermalTier: AndroidThermalTier,
    source: LiveFrameSource,
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
    val axis =
        remember(mapping.curveOrdinal, mapping.clipNative) {
            nikonScopeLevelAxis(mapping.curveOrdinal, mapping.clipNative)
        } ?: return
    val vectorLut = rememberScopeVectorLut(lutSelection, lutLibrary, mapping.curveOrdinal)
    val bus = remember { ScopeSampleBus() }
    val inputs =
        ScopeTickInputs(
            selected = ScopeKind.canonical.filter(displayed::contains).toSet(),
            histogramTrafficLightsEnabled = assist.histoTrafficLights,
            crushClipCompensationRaw = assist.crushClipCompensation.raw,
            curveOrdinal = mapping.curveOrdinal,
            clipNative = mapping.clipNative,
            axis = axis,
            vectorLut = vectorLut,
            periodNanos = scopePeriodNanos(displayed.size, thermalTier),
        )
    LaunchedEffect(source, inputs) {
        withContext(Dispatchers.Default) { pumpLiveScopes(source.frames, inputs, bus) }
    }
    val bundle = bus.publications.collectAsState().value.bundle

    if (isPortrait && !portraitFloating) {
        PortraitScopePanels(
            displayed,
            requireNotNull(scopeZone),
            axis,
            bundle,
            assist,
        )
    } else {
        FloatingScopePanels(
            displayed,
            feed,
            infoBar,
            requireNotNull(panelLayout),
            axis,
            bundle,
            assist,
            placementStore = placementStore,
            placementRevision = placementRevision,
            hapticsEnabled = hapticsEnabled,
            onPanelFrameChanged = onPanelFrameChanged,
        )
    }
}

/**
 * Playback counterpart to [ScopePanels]. It renders the same panels from the
 * same shared sampler on the bus's playback role, but the frame tap is Media3's
 * TextureView rather than a camera JPEG flow. [currentFrameKey] is read on the
 * main thread and prevents a paused frame from being resampled indefinitely.
 * TextureView bitmap capture reads the decoded SurfaceTexture content before
 * the view's RenderEffect, preserving the clean-source scope invariant.
 */
@Composable
internal fun PlaybackScopePanels(
    selectedScopes: Set<ScopeKind>,
    assist: MonitorAssistState,
    cameraInput: ExposureAssistCameraInput,
    lutSelection: FeedLutSelection?,
    lutLibrary: AndroidLutLibrary?,
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
    val axis =
        remember(mapping.curveOrdinal, mapping.clipNative) {
            nikonScopeLevelAxis(mapping.curveOrdinal, mapping.clipNative)
        } ?: return
    val vectorLut = rememberScopeVectorLut(lutSelection, lutLibrary, mapping.curveOrdinal)
    val latestFrameKey by rememberUpdatedState(currentFrameKey)
    val bus = remember { ScopeSampleBus() }
    val tap = remember(textureView) { PlaybackScopeFrameTap() }
    val inputs =
        ScopeTickInputs(
            selected = displayed.toSet(),
            histogramTrafficLightsEnabled = assist.histoTrafficLights,
            crushClipCompensationRaw = assist.crushClipCompensation.raw,
            curveOrdinal = mapping.curveOrdinal,
            clipNative = mapping.clipNative,
            axis = axis,
            vectorLut = vectorLut,
            periodNanos = scopePeriodNanos(displayed.size, thermalTier),
        )
    LaunchedEffect(textureView, cleanFrameSource, inputs) {
        if (cleanFrameSource != null) cleanFrameSource.reset() else tap.reset()
        withContext(Dispatchers.Default) {
            pumpReducedScopes(inputs, bus, ScopeSampleBus.Role.PLAYBACK) {
                if (cleanFrameSource != null) {
                    cleanFrameSource.capture()
                } else {
                    tap.capture(textureView) { latestFrameKey() }
                }
            }
        }
    }
    FloatingScopePanels(
        displayed = displayed,
        feed = feed,
        infoBar = infoBar,
        panelLayout = MonitorAnalysisPanelLayout(viewport = viewport, safeBounds = viewport),
        axis = axis,
        bundle = bus.publications.collectAsState().value.bundle,
        assist = assist,
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
    axis: ScopeLevelAxis,
    bundle: ScopeAssistBundle,
    assist: MonitorAssistState,
) {
    val spacing = 8f
    val panelHeight = max(0f, (zone.height - spacing * (displayed.size - 1)) / displayed.size)
    Box(Modifier.zone(zone)) {
        displayed.forEachIndexed { index, kind ->
            ScopePanel(
                kind = kind,
                axis = axis,
                bundle = bundle,
                assist = assist,
                // iOS portrait fit gives each enabled scope an equal full-width
                // share and deliberately ignores landscape footprint scale.
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
    axis: ScopeLevelAxis,
    bundle: ScopeAssistBundle,
    assist: MonitorAssistState,
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
                        assist = assist,
                    )
                val baseSize = scopePanelBaseSize(kind)
                FloatingScopePanel(
                    kind = kind,
                    default = default,
                    panelLayout = scopeLayout,
                    scale = assist.scaleFor(kind),
                    baseWidth = baseSize.first,
                    baseHeight = baseSize.second,
                    placementStore = placementStore,
                    legacyStore = legacyStore,
                    placementRevision = placementRevision,
                    hapticsEnabled = hapticsEnabled,
                    onPanelFrameChanged = onPanelFrameChanged,
                    onScaleChange = { assist.setScale(kind.assistTool, it.toDouble()) },
                ) { modifier ->
                    ScopePanel(
                        kind = kind,
                        axis = axis,
                        bundle = bundle,
                        assist = assist,
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
    assist: MonitorAssistState = MonitorAssistState(),
): ZoneFrame =
    scopePanelBaseSize(kind).let { (baseWidth, baseHeight) ->
        val presentationScale =
            scopePresentationScale(
                kind = kind,
                requestedScale = assist.scaleFor(kind),
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
    val localizedTitle = scopeTitle(kind)
    val panelDescription = stringResource(R.string.scope_panel_description, localizedTitle)
    val recenterDescription = stringResource(R.string.scope_panel_recenter, localizedTitle)
    val resizeDescription = stringResource(R.string.scope_panel_resize, localizedTitle)
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
    val lifted = isDragging || isResizing
    // Outer box is only layout + grip hit area — never elevate it (empty pad
    // made a hard rectangular "box under" shadow). Lift/shadow match iOS soft
    // shadow on the panel chrome only.
    Box(Modifier.zone(outerFrame)) {
        Box(
            Modifier
                .size(frame.width.dp, frame.height.dp)
                .zIndex(if (lifted) 1f else 0f)
                // Outside the lift layer, so the 1.03 lift never scales the finger's delta.
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
                            view.performOperatorHaptic(HapticFeedbackConstants.LONG_PRESS)
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
                            view.performOperatorHaptic(HapticFeedbackConstants.KEYBOARD_TAP)
                        }
                    }
                    frame = snapped
                }
            }
                .graphicsLayer {
                    scaleX = if (lifted) 1.03f else 1f
                    scaleY = if (lifted) 1.03f else 1f
                    shadowElevation = if (lifted) 18.dp.toPx() else 0f
                    shape = ChromeShape
                    clip = true
                    ambientShadowColor = Color.Black.copy(alpha = 0.5f)
                    spotShadowColor = Color.Black.copy(alpha = 0.5f)
                }
                .semantics {
                    contentDescription = panelDescription
                    if (placementStore != null) {
                        customActions =
                            listOf(
                                CustomAccessibilityAction(recenterDescription) {
                                    placementStore.recenter(panelID)
                                    frame = clampScopeFrame(default, panelLayout.safeBounds)
                                    true
                                },
                            )
                    }
                }
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
                .semantics { contentDescription = resizeDescription }
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
                                view.performOperatorHaptic(HapticFeedbackConstants.LONG_PRESS)
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
                            clampScopeScale(
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

/** One panel view of the shared bundle; it never samples or collects frames itself. */
@Composable
private fun ScopePanel(
    kind: ScopeKind,
    axis: ScopeLevelAxis,
    bundle: ScopeAssistBundle,
    assist: MonitorAssistState,
    modifier: Modifier = Modifier,
) {
    if (kind == ScopeKind.TRAFFIC_LIGHTS) {
        TrafficLightsPanel(bundle.traffic, modifier)
        return
    }
    Box(modifier.monitorMaterial(MonitorMaterial.Scope, ChromeShape)) {
        when (kind) {
            ScopeKind.WAVEFORM ->
                MonitorWaveformScopePlot(
                    bundle, axis, assist.waveMode, waveformParadeIntensity(assist.waveBrightness),
                    assist.waveGuides,
                )
            ScopeKind.PARADE ->
                MonitorParadeScopePlot(
                    bundle, axis, assist.paradeMode, waveformParadeIntensity(assist.paradeBrightness),
                    assist.paradeGuides,
                )
            ScopeKind.HISTOGRAM ->
                MonitorHistogramScopePlot(
                    bundle.histogramDisplay, bundle.traffic, assist.histoTrafficLights)
            ScopeKind.VECTORSCOPE ->
                MonitorVectorscopeScopePlot(
                    bundle, assist.vectorZoom, assist.vectorBrightness,
                )
            ScopeKind.TRAFFIC_LIGHTS -> Unit
        }
    }
}

/** The shared RGB goal-post meter with the camera's spoken per-channel state. */
@Composable
private fun TrafficLightsPanel(reading: ScopeTrafficLightsReading, modifier: Modifier = Modifier) {
    val resources = LocalResources.current
    val strings = remember(resources) { resources.phoneStringResolver() }
    val title = stringResource(R.string.scope_traffic_lights)
    val state = trafficLightsStateDescription(reading, strings)
    Box(
        modifier
            .monitorMaterial(MonitorMaterial.Scope, ChromeShape)
            .semantics {
                contentDescription = title
                stateDescription = state
            },
    ) {
        MonitorTrafficLightsMeter(reading)
    }
}

private fun trafficLightsStateDescription(
    reading: ScopeTrafficLightsReading,
    strings: PhoneStringResolver,
): String {
    fun channel(name: String, value: ScopeChannelLight): String {
        val direction =
            when (MonitorTrafficLightsGeometry.channelDisplay(value.level).side) {
                MonitorTrafficLightsGeometry.BarSide.NEUTRAL ->
                    strings.resolve(R.string.scope_direction_balanced)
                MonitorTrafficLightsGeometry.BarSide.OVER -> strings.resolve(R.string.scope_direction_over)
                MonitorTrafficLightsGeometry.BarSide.UNDER -> strings.resolve(R.string.scope_direction_under)
            }
        val flags =
            listOfNotNull(
                strings.resolve(R.string.scope_flag_clip).takeIf { value.clip },
                strings.resolve(R.string.scope_flag_crush).takeIf { value.crush },
            )
        return if (flags.isEmpty()) {
            strings.resolve(R.string.scope_channel_state, name, direction)
        } else {
            val flagCopy =
                if (flags.size == 2) {
                    strings.resolve(R.string.scope_flags_both, flags[0], flags[1])
                } else {
                    flags.single()
                }
            strings.resolve(R.string.scope_channel_state_flags, name, direction, flagCopy)
        }
    }
    return strings.resolve(
        R.string.scope_state_description,
        channel(strings.resolve(R.string.scope_channel_red), reading.red),
        channel(strings.resolve(R.string.scope_channel_green), reading.green),
        channel(strings.resolve(R.string.scope_channel_blue), reading.blue),
    )
}

/**
 * Absolute-schedule live sampler: never gates by source-frame cadence, so it
 * retains the iOS wall-clock anti-aliasing policy while sharing one decoder.
 */
private suspend fun pumpLiveScopes(
    frames: Flow<LiveFrame>,
    inputs: ScopeTickInputs,
    bus: ScopeSampleBus,
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
        pumpReducedScopes(inputs, bus, ScopeSampleBus.Role.LIVE) {
            val next = latest.get() ?: return@pumpReducedScopes null
            if (next.generation == lastGeneration) return@pumpReducedScopes null
            lastGeneration = next.generation
            tap.reduce(next.jpeg)
        }
    } finally {
        collector.cancel()
    }
}

/**
 * Absolute-schedule clean-frame sampler shared by live JPEG and playback
 * TextureView inputs. Sampling and plots are the shared OpenCine scopes; the
 * camera's level axis and Traffic Lights come from the Swift core. This loop
 * owns demand, cadence and the bus lease.
 */
private suspend fun pumpReducedScopes(
    inputs: ScopeTickInputs,
    bus: ScopeSampleBus,
    role: ScopeSampleBus.Role,
    nextFrame: suspend () -> ReducedScopeFrame?,
) {
    val demand = scopeSamplingDemand(inputs.selected, inputs.histogramTrafficLightsEnabled)
    if (!demand.traces && !demand.vector) return
    val look = if (demand.vector) inputs.vectorLut?.cube() else null
    if (demand.vector && look == null) {
        Log.w(TAG, "active vectorscope LUT is unavailable; vectorscope rendering disabled")
    }
    val lease = bus.openSource(role)
    try {
        val stats = ScopeTickStats { if (BuildConfig.DEBUG) Log.d(TAG, it) }
        var bundle = ScopeAssistBundle.EMPTY
        val startNanos = System.nanoTime()
        var tick = 0L
        while (true) {
            tick = max(tick + 1, (System.nanoTime() - startNanos) / inputs.periodNanos)
            val waitMillis = (startNanos + tick * inputs.periodNanos - System.nanoTime()) / 1_000_000
            if (waitMillis > 0) delay(waitMillis)

            val tickStart = System.nanoTime()
            val reduced = nextFrame() ?: continue
            val samples =
                ScopeSampler.sampleRaw(
                    reduced.rgba, reduced.width, reduced.height, reduced.bytesPerRow,
                    MonitorTransfer.REC709, includePoints = demand.pointTrace || look != null,
                    stride = SAMPLE_STRIDE, includeSampleCoordinates = true, requireCompleteRows = true,
                )
            bundle =
                ScopeAssistBundle(
                    revision = bundle.revision + 1,
                    samples = samples,
                    vectorscopePoints = look?.let { ScopeSampler.monitorPoints(samples.points, it) }.orEmpty(),
                    trailSamples = bundle.samples,
                    trailVectorscopePoints = bundle.vectorscopePoints,
                    traffic =
                        if (demand.trafficLights) nikonTrafficLights(samples, inputs)
                        else ScopeTrafficLightsReading.NONE,
                    histogramDisplay =
                        if (demand.histogram) {
                            ScopeSampler.histogramDisplay(samples, bundle.histogramDisplay, inputs.axis)
                        } else {
                            ScopeHistogramDisplay.EMPTY
                        },
                )
            if (!bus.publish(lease, bundle)) return
            stats.tickCompleted(System.nanoTime() - tickStart, System.nanoTime())
        }
    } finally {
        bus.closeSource(lease)
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

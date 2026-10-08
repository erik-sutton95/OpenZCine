package com.opencapture.openzcine

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.util.Log
import android.view.HapticFeedbackConstants
import android.view.TextureView
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.layout.LayoutCoordinates
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalResources
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.unit.dp
import com.opencapture.monitorui.MonitorHistogramScopePlot
import com.opencapture.monitorui.MonitorMaterial
import com.opencapture.monitorui.MonitorMovableScopePanel
import com.opencapture.monitorui.MonitorParadeScopePlot
import com.opencapture.monitorui.MonitorScopePanelSize
import com.opencapture.monitorui.MonitorScopePoint
import com.opencapture.monitorui.MonitorScopeRect
import com.opencapture.monitorui.MonitorScopeSize
import com.opencapture.monitorui.MonitorScopeStoredCenter
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
import com.opencapture.opencine.media.ScopeClipSnapshot
import com.opencapture.opencine.media.ScopeHistogramDisplay
import com.opencapture.opencine.media.ScopeLevelAxis
import com.opencapture.opencine.media.ScopeSampler
import com.opencapture.opencine.media.ScopeSamples
import com.opencapture.opencine.media.ScopeTrafficLightsReading
import com.opencapture.opencine.nikon.LiveFrame
import com.opencapture.opencine.nikon.LiveFrameSource
import com.opencapture.opencine.runtime.ScopeSampleBus
import com.opencapture.openzcine.bridge.SwiftCore
import com.opencapture.monitorui.MonitorRect
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
import kotlinx.coroutines.flow.map
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

/** Current persisted scale for one scope kind. */
internal fun MonitorAssistState.scaleFor(kind: ScopeKind): Float =
    when (kind) {
        ScopeKind.WAVEFORM -> waveScale
        ScopeKind.PARADE -> paradeScale
        ScopeKind.HISTOGRAM -> histoScale
        ScopeKind.VECTORSCOPE -> vectorScale
        ScopeKind.TRAFFIC_LIGHTS -> lightsScale
    }.toFloat()

/** Keeps a floating panel wholly inside the physical viewport's safe drawing bounds. */
fun clampScopeFrame(frame: MonitorRect, bounds: MonitorRect): MonitorRect {
    val width = min(frame.width, bounds.width)
    val height = min(frame.height, bounds.height)
    val maxX = bounds.x + bounds.width - width
    val maxY = bounds.y + bounds.height - height
    return MonitorRect(
        x = frame.x.coerceIn(bounds.x, maxX),
        y = frame.y.coerceIn(bounds.y, maxY),
        width = width,
        height = height,
    )
}

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
        ?: SwiftCore.takeIf { it.isAvailable }?.bakeLut(lookOrdinal, VECTOR_LUT_SIZE)
            ?.let { MonitorLUTCube(VECTOR_LUT_SIZE, it) }

/** This camera's level axis for the shared plots (Swift `ScopeFrameWire.levelAxis`). */
private fun nikonScopeLevelAxis(curveOrdinal: Int, clipNative: Float): ScopeLevelAxis? {
    if (!SwiftCore.isAvailable) return null
    val flat = SwiftCore.scopeLevelAxis(curveOrdinal, clipNative)
    if (flat.size != LEVEL_AXIS_BINS + 1) return null
    return ScopeLevelAxis(flat.copyOf(LEVEL_AXIS_BINS), flat[LEVEL_AXIS_BINS].toDouble())
}

/** The core Traffic Lights meter on this tick's shared histograms. */
private fun nikonTrafficLights(samples: ScopeSamples, inputs: ScopeTickInputs): ScopeTrafficLightsReading {
    if (!SwiftCore.isAvailable) return ScopeTrafficLightsReading.NONE
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
internal data class ScopeTickInputs(
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
internal fun rememberNikonLiveScopeBundles(
    selectedScopes: Set<ScopeKind>, portraitScopes: List<ScopeKind>, assist: MonitorAssistState,
    cameraInput: ExposureAssistCameraInput, lutSelection: FeedLutSelection?, lutLibrary: AndroidLutLibrary?,
    thermalTier: AndroidThermalTier, source: LiveFrameSource, isPortrait: Boolean,
    portraitFloating: Boolean, scopeZone: MonitorRect?,
): Flow<ScopeAssistBundle>? {
    val displayed =
        displayedScopeKinds(
            selectedScopes = selectedScopes,
            portraitScopes = portraitScopes,
            isPortrait = isPortrait,
            portraitFloating = portraitFloating,
        )
    // This guard also stops all collection when no displayed panel exists.
    if (displayed.isEmpty()) return null
    if (isPortrait && !portraitFloating && scopeZone == null) return null
    // A scope cannot honor camera-dependent display mapping without the Swift
    // facade, so fail closed rather than locally selecting a fallback curve.
    val mapping = remember(cameraInput) { resolveExposureAssistMapping(cameraInput) } ?: return null
    val axis =
        remember(mapping.curveOrdinal, mapping.clipNative) {
            nikonScopeLevelAxis(mapping.curveOrdinal, mapping.clipNative)
        } ?: return null
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
    return remember(bus, axis, mapping.curveOrdinal, mapping.clipNative) {
        val transfer = when (mapping.curveOrdinal) {
            ExposureCurveOrdinals.NIKON_NLOG -> MonitorTransfer.NLOG
            ExposureCurveOrdinals.RED_LOG3G10 -> MonitorTransfer.LOG3G10
            ExposureCurveOrdinals.HLG -> MonitorTransfer.HDR
            else -> MonitorTransfer.SRGB
        }
        bus.publications.map { publication ->
            publication.bundle.copy(levelAxis = axis, transfer = transfer,
                ceiling = ScopeClipSnapshot(transfer, mapping.clipNative.roundToInt()))
        }
    }
}

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
    scopeZone: MonitorRect?,
    panelLayout: MonitorAnalysisPanelLayout?,
    hapticsEnabled: Boolean,
    onPanelFrameChanged: (MonitorAnalysisPanelID, MonitorRect?) -> Unit = { _, _ -> },
) {
    val displayed = displayedScopeKinds(selectedScopes, portraitScopes, isPortrait, portraitFloating)
    val flow = rememberNikonLiveScopeBundles(selectedScopes, portraitScopes, assist, cameraInput, lutSelection,
        lutLibrary, thermalTier, source, isPortrait, portraitFloating, scopeZone) ?: return
    val bundle = flow.collectAsState(initial = ScopeAssistBundle.EMPTY).value
    val axis = bundle.levelAxis ?: return

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
            requireNotNull(panelLayout),
            assist,
            hapticsEnabled = hapticsEnabled,
            onPanelFrameChanged = onPanelFrameChanged,
        ) { kind, modifier -> ScopePanel(kind, axis, bundle, assist, modifier) }
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
/** Native source calibration borrowed by the complete shared playback scope session. */
internal data class NikonPlaybackScopeConfiguration(
    private val inputs: ScopeTickInputs,
    private val look: MonitorLUTCube?,
) {
    val cadenceMilliseconds: Long get() = (inputs.periodNanos / 1_000_000L).coerceAtLeast(1L)
    val axis: ScopeLevelAxis get() = inputs.axis
    val transfer: MonitorTransfer get() = when (inputs.curveOrdinal) {
        ExposureCurveOrdinals.NIKON_NLOG -> MonitorTransfer.NLOG
        ExposureCurveOrdinals.RED_LOG3G10 -> MonitorTransfer.LOG3G10
        ExposureCurveOrdinals.HLG -> MonitorTransfer.HDR
        else -> MonitorTransfer.SRGB
    }
    val clipByte: Int get() = inputs.clipNative.roundToInt()
    fun samples(frame: ReducedScopeFrame): ScopeSamples {
        val demand = scopeSamplingDemand(inputs.selected, inputs.histogramTrafficLightsEnabled)
        return ScopeSampler.sampleRaw(frame.rgba, frame.width, frame.height, frame.bytesPerRow,
            MonitorTransfer.REC709, includePoints = demand.pointTrace || look != null,
            stride = SAMPLE_STRIDE, includeSampleCoordinates = true, requireCompleteRows = true)
    }
    fun bundle(samples: ScopeSamples, previous: ScopeAssistBundle): ScopeAssistBundle =
        deriveNikonScopeBundle(samples, inputs, look, previous).copy(
            transfer = transfer, ceiling = ScopeClipSnapshot(transfer, clipByte), levelAxis = axis)
}

@Composable
internal fun rememberNikonPlaybackScopeConfiguration(
    selected: Set<ScopeKind>, assist: MonitorAssistState, cameraInput: ExposureAssistCameraInput,
    lutSelection: FeedLutSelection?, lutLibrary: AndroidLutLibrary?, thermalTier: AndroidThermalTier,
): NikonPlaybackScopeConfiguration? {
    val mapping = remember(cameraInput) { resolveExposureAssistMapping(cameraInput) } ?: return null
    val axis = remember(mapping.curveOrdinal, mapping.clipNative) {
        nikonScopeLevelAxis(mapping.curveOrdinal, mapping.clipNative)
    } ?: return null
    val vector = rememberScopeVectorLut(lutSelection, lutLibrary, mapping.curveOrdinal)
    val look = remember(vector) { vector?.cube() }
    return NikonPlaybackScopeConfiguration(ScopeTickInputs(selected, assist.histoTrafficLights,
        assist.crushClipCompensation.raw, mapping.curveOrdinal, mapping.clipNative, axis, vector,
        scopePeriodNanos(selected.size, thermalTier)), look)
}

private fun deriveNikonScopeBundle(samples: ScopeSamples, inputs: ScopeTickInputs,
    look: MonitorLUTCube?, previous: ScopeAssistBundle): ScopeAssistBundle {
    val demand = scopeSamplingDemand(inputs.selected, inputs.histogramTrafficLightsEnabled)
    return ScopeAssistBundle(revision = previous.revision + 1, samples = samples,
        vectorscopePoints = look?.let { ScopeSampler.monitorPoints(samples.points, it) }.orEmpty(),
        trailSamples = previous.samples, trailVectorscopePoints = previous.vectorscopePoints,
        traffic = if (demand.trafficLights) nikonTrafficLights(samples, inputs) else ScopeTrafficLightsReading.NONE,
        histogramDisplay = if (demand.histogram) ScopeSampler.histogramDisplay(samples, previous.histogramDisplay, inputs.axis)
            else ScopeHistogramDisplay.EMPTY)
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
    zone: MonitorRect,
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
                        MonitorRect(
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

/**
 * The shared Pocket / Insta movable scope panels over the shared assist state: direct drag,
 * corner resize, hold for the tool's options, and a centre saved per orientation. An unplaced
 * panel starts at the canvas centre, as on Pocket. Each panel reports its frame (monitor-zone dp)
 * so the focus-reset button can climb above it.
 */
@Composable
internal fun FloatingScopePanels(
    displayed: List<ScopeKind>,
    panelLayout: MonitorAnalysisPanelLayout,
    assist: MonitorAssistState,
    hapticsEnabled: Boolean = true,
    onPanelFrameChanged: (MonitorAnalysisPanelID, MonitorRect?) -> Unit = { _, _ -> },
    content: @Composable (ScopeKind, Modifier) -> Unit,
) {
    val portrait = panelLayout.viewport.height > panelLayout.viewport.width
    displayed.forEach { kind ->
        key(kind) {
            val tool = kind.assistTool
            val description = stringResource(R.string.scope_panel_description, scopeTitle(kind))
            MovableMonitorPanel(
                identity = kind.token,
                base = kind.panelBase,
                panelLayout = panelLayout,
                stored = assist.centerFor(tool, portrait),
                onStore = { assist.storeCenter(tool, it, portrait) },
                hapticsEnabled = hapticsEnabled,
                panelID = kind.monitorAnalysisPanelID(),
                onPanelFrameChanged = onPanelFrameChanged,
                scale = assist.scaleFor(kind).toDouble(),
                onScale = { assist.setScale(tool, it) },
                onOpenOptions = { assist.configureTool = tool },
                // The scope plates draw their own material, as in the portrait stack.
                fillPlate = false,
            ) { modifier -> content(kind, modifier.semantics { contentDescription = description }) }
        }
    }
}

/**
 * One movable monitor panel on the shared [MonitorMovableScopePanel], in monitor-zone dp: drag
 * within [panelLayout]'s safe bounds, the centre stored normalized to its viewport. It reports its
 * frame so the focus-reset button can climb above it. An unplaced panel starts at [defaultFrame]'s
 * centre, or the viewport centre.
 */
@Composable
internal fun MovableMonitorPanel(
    identity: String,
    base: MonitorScopeSize,
    panelLayout: MonitorAnalysisPanelLayout,
    stored: MonitorScopeStoredCenter?,
    onStore: (MonitorScopeStoredCenter) -> Unit,
    hapticsEnabled: Boolean,
    panelID: MonitorAnalysisPanelID? = null,
    onPanelFrameChanged: (MonitorAnalysisPanelID, MonitorRect?) -> Unit = { _, _ -> },
    defaultFrame: MonitorRect? = null,
    scale: Double = 1.0,
    onScale: ((Double) -> Unit)? = null,
    onOpenOptions: (() -> Unit)? = null,
    fillPlate: Boolean = true,
    content: @Composable (Modifier) -> Unit,
) {
    val density = LocalDensity.current.density
    val view = LocalView.current
    val canvas = panelLayout.viewport.scopeRect(density)
    val bounds = panelLayout.safeBounds.scopeRect(density)
    val report by rememberUpdatedState(onPanelFrameChanged)
    var origin by remember { mutableStateOf<LayoutCoordinates?>(null) }
    if (panelID != null) DisposableEffect(panelID) { onDispose { report(panelID, null) } }
    Box(Modifier.fillMaxSize().onGloballyPositioned { origin = it }) {
        MonitorMovableScopePanel(
            identity = identity,
            base = base,
            scale = scale,
            stored = stored,
            canvas = canvas,
            placementBounds = bounds,
            defaultCenter =
                defaultFrame?.let { MonitorScopePoint((it.x + it.width / 2f) * density, (it.y + it.height / 2f) * density) }
                    ?: MonitorScopePoint(canvas.midX, canvas.midY),
            enabled = true,
            onStore = onStore,
            onScale = onScale,
            onOpenOptions = onOpenOptions?.let { open -> { _ -> open() } },
            onConfirm = {
                if (hapticsEnabled) view.performOperatorHaptic(HapticFeedbackConstants.LONG_PRESS)
            },
            fillPlate = fillPlate,
        ) { size ->
            content(
                Modifier
                    .size(size.width.dp, size.height.dp)
                    .onGloballyPositioned { coordinates ->
                        val id = panelID ?: return@onGloballyPositioned
                        val root = origin ?: return@onGloballyPositioned
                        val at = root.localPositionOf(coordinates, Offset.Zero)
                        report(
                            id,
                            MonitorRect(
                                at.x / density, at.y / density,
                                coordinates.size.width / density,
                                coordinates.size.height / density,
                            ),
                        )
                    },
            )
        }
    }
}

/** The shared panel footprint for one scope. */
private val ScopeKind.panelBase: MonitorScopeSize
    get() =
        when (this) {
            ScopeKind.WAVEFORM -> MonitorScopePanelSize.waveform
            ScopeKind.PARADE -> MonitorScopePanelSize.parade
            ScopeKind.HISTOGRAM -> MonitorScopePanelSize.histogram
            ScopeKind.VECTORSCOPE -> MonitorScopePanelSize.vectorscope
            ScopeKind.TRAFFIC_LIGHTS -> MonitorScopePanelSize.trafficLights
        }

private fun MonitorRect.scopeRect(density: Float): MonitorScopeRect =
    MonitorScopeRect(x * density, y * density, width * density, height * density)

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
            bundle = deriveNikonScopeBundle(samples, inputs, look, bundle)
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
    val publication: Long = 0L,
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
internal class PlaybackScopeFrameTap {
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
            ReducedScopeFrame(rgba.copyOf(), captured.width, captured.height, captured.rowBytes, key)
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

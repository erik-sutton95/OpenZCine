package com.opencapture.openzcine

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.util.Log
import android.view.TextureView
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.remember
import com.opencapture.opencine.appkit.MonitorAssistState
import com.opencapture.opencine.media.MonitorLUTCube
import com.opencapture.opencine.media.MonitorTransfer
import com.opencapture.opencine.media.ScopeAssistBundle
import com.opencapture.opencine.media.ScopeClipSnapshot
import com.opencapture.opencine.media.ScopeSampler
import com.opencapture.opencine.media.ScopeSamples
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

/** Which payloads the scope sampler must take for the visible scopes. */
data class ScopeSamplingDemand(
    val traces: Boolean,
    val vector: Boolean,
    val pointTrace: Boolean,
    val histogram: Boolean,
    /** Whether any visible surface reads the shared RGB lamps. */
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

/** First two eligible selections, without changing the active set or floating-scope order. */
fun portraitDisplayedScopes(selected: Set<ScopeKind>): List<ScopeKind> =
    ScopeKind.canonical.filter(selected::contains).take(2)

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

/** Everything one sampler run needs; a change restarts the run. */
internal data class ScopeTickInputs(
    val selected: Set<ScopeKind>,
    val histogramTrafficLightsEnabled: Boolean,
    /** The operator's crush/clip compensation as the shared lamps' pixel fraction. */
    val trafficThreshold: Double,
    /** The camera curve as the shared transfer and its stated clip: the only Nikon facts. */
    val transfer: MonitorTransfer,
    val clipByte: Int,
    val vectorLut: ScopeVectorLutRequest?,
    val periodNanos: Long,
) {
    constructor(selected: Set<ScopeKind>, assist: MonitorAssistState, mapping: ExposureAssistMapping,
        vectorLut: ScopeVectorLutRequest?, periodNanos: Long) : this(selected, assist.histoTrafficLights,
        assist.crushClipCompensation.pixelFractionThreshold, mapping.transfer, mapping.clipByte, vectorLut, periodNanos)

    val ceiling: ScopeClipSnapshot get() = ScopeClipSnapshot(transfer, clipByte)

    /** The camera's raw tap, sampled on its own curve. */
    fun samples(frame: ReducedScopeFrame, includePoints: Boolean): ScopeSamples =
        ScopeSampler.sampleRaw(frame.rgba, frame.width, frame.height, frame.bytesPerRow, transfer,
            includePoints = includePoints, stride = SAMPLE_STRIDE, includeSampleCoordinates = true,
            requireCompleteRows = true)

    /** The shared bundle (lamps with hysteresis and the clip shelf, histogram on the shared axis). */
    fun bundle(samples: ScopeSamples, look: MonitorLUTCube?, previous: ScopeAssistBundle): ScopeAssistBundle =
        ScopeSampler.bundle(samples, transfer,
            includePoints = scopeSamplingDemand(selected, histogramTrafficLightsEnabled).pointTrace,
            includeVectorPoints = look != null, look = look, trafficThreshold = trafficThreshold,
            previous = previous, ceiling = ceiling)
}

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
    val vectorLut = rememberScopeVectorLut(lutSelection, lutLibrary, mapping.curveOrdinal)
    val bus = remember { ScopeSampleBus() }
    val inputs = ScopeTickInputs(ScopeKind.canonical.filter(displayed::contains).toSet(), assist, mapping,
        vectorLut, scopePeriodNanos(displayed.size, thermalTier))
    LaunchedEffect(source, inputs) {
        withContext(Dispatchers.Default) { pumpLiveScopes(source.frames, inputs, bus) }
    }
    return remember(bus) { bus.publications.map { it.bundle } }
}

/**
 * Playback counterpart to the live tap: the same shared bundle from Media3's clean decoded
 * frame. TextureView bitmap capture reads the decoded SurfaceTexture content before the view's
 * RenderEffect, preserving the clean-source scope invariant.
 */
internal data class NikonPlaybackScopeConfiguration(
    private val inputs: ScopeTickInputs,
    private val look: MonitorLUTCube?,
) {
    val cadenceMilliseconds: Long get() = (inputs.periodNanos / 1_000_000L).coerceAtLeast(1L)
    val transfer: MonitorTransfer get() = inputs.transfer
    val clipByte: Int get() = inputs.clipByte
    fun samples(frame: ReducedScopeFrame): ScopeSamples = inputs.samples(frame,
        scopeSamplingDemand(inputs.selected, inputs.histogramTrafficLightsEnabled).pointTrace || look != null)
    fun bundle(samples: ScopeSamples, previous: ScopeAssistBundle): ScopeAssistBundle =
        inputs.bundle(samples, look, previous)
}

@Composable
internal fun rememberNikonPlaybackScopeConfiguration(
    selected: Set<ScopeKind>, assist: MonitorAssistState, cameraInput: ExposureAssistCameraInput,
    lutSelection: FeedLutSelection?, lutLibrary: AndroidLutLibrary?, thermalTier: AndroidThermalTier,
): NikonPlaybackScopeConfiguration? {
    val mapping = remember(cameraInput) { resolveExposureAssistMapping(cameraInput) } ?: return null
    val vector = rememberScopeVectorLut(lutSelection, lutLibrary, mapping.curveOrdinal)
    val look = remember(vector) { vector?.cube() }
    return NikonPlaybackScopeConfiguration(ScopeTickInputs(selected, assist, mapping, vector,
        scopePeriodNanos(selected.size, thermalTier)), look)
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
 * TextureView inputs. Sampling, lamps, axis and plots are the shared OpenCine
 * scopes over the camera's transfer and stated clip. This loop owns demand,
 * cadence and the bus lease.
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
            bundle = inputs.bundle(inputs.samples(reduced, demand.pointTrace || look != null), look, bundle)
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

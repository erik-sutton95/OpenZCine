package com.opencapture.openzcine

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.BlendMode
import android.graphics.Paint
import android.graphics.Typeface
import android.util.Log
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.drawIntoCanvas
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import com.opencapture.openzcine.bridge.ScopeAnchors
import com.opencapture.openzcine.bridge.ScopeTraces
import com.opencapture.openzcine.bridge.SwiftCore
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

/**
 * The four v1 scopes, selectable through the debug intent
 * `--es zc.scopes wave|parade|histo|vector` (the real scope picker is chrome
 * work, out of scope here).
 */
enum class ScopeKind(val token: String, val title: String, val chip: String) {
    WAVEFORM("wave", "WAVE", "LUMA"),
    PARADE("parade", "PARADE", "RGB"),
    HISTOGRAM("histo", "HISTO", "RGBL"),
    VECTORSCOPE("vector", "VECTOR", "MON · 1X"),
    ;

    companion object {
        /** Parses an intent token; null for absent/unknown values. */
        fun fromToken(value: String?): ScopeKind? = entries.firstOrNull { it.token == value }
    }
}

/**
 * Default frame for the floating scope panel, mirroring the iOS landscape
 * `MovablePanel` sizes anchored inside the feed's top-leading corner, below
 * the info deck (the landscape zone map carries no scopes zone — scopes float
 * over the feed on both platforms).
 */
// ponytail: fixed top-leading anchor for the single debug scope; per-kind iOS
// default corners + dragging arrive with the real scope-picker chrome.
fun floatingScopeFrame(kind: ScopeKind, feed: ZoneFrame, infoBar: ZoneFrame): ZoneFrame {
    val (width, height) =
        when (kind) {
            ScopeKind.WAVEFORM, ScopeKind.PARADE -> 250f to 153f
            ScopeKind.HISTOGRAM -> 250f to 77f
            ScopeKind.VECTORSCOPE -> 190f to 190f
        }
    return ZoneFrame(feed.x + 12f, infoBar.y + infoBar.height + 8f, width, height)
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

    /** Phosphor persistence: the previous tick draws first at this opacity. */
    const val TRAIL_DECAY = 0.35f
}

// ── Tick payload ──

/** One presented scope tick: the current payload plus the previous one (trail). */
private class ScopeDrawData(
    val traces: ScopeTraces? = null,
    val trailTraces: ScopeTraces? = null,
    /** Blended + smoothed display bins per channel (histogram kind only). */
    val histogram: HistogramDisplay? = null,
    val vector: ImageBitmap? = null,
    val vectorTrail: ImageBitmap? = null,
)

private class HistogramDisplay(
    val luma: FloatArray,
    val red: FloatArray,
    val green: FloatArray,
    val blue: FloatArray,
    val peak: Float,
)

// ── Panel ──

/**
 * One scope panel — waveform, RGB parade, histogram, or vectorscope — fed by
 * the live JPEG stream at ~10 Hz. All axis/curve math comes from the Swift
 * core over the facade ([SwiftCore.scopeTraces] / [SwiftCore.scopeVector] /
 * [SwiftCore.scopeAnchors]); this composable only reduces the frame and draws.
 */
@Composable
fun ScopePanel(kind: ScopeKind, source: com.opencapture.openzcine.core.LiveFrameSource, modifier: Modifier = Modifier) {
    val anchors = remember { ScopeAnchors.parse(SwiftCore.scopeAnchors(CURVE_LOG3G10)) }
    val data = remember { mutableStateOf<ScopeDrawData?>(null) }

    LaunchedEffect(source, kind) {
        withContext(Dispatchers.Default) {
            pumpScope(source.frames, kind) { data.value = it }
        }
    }

    Box(
        modifier
            .background(ScopePalette.panelBackground, ChromeShape)
            .border(1.dp, LiveDesign.hairline, ChromeShape),
    ) {
        Canvas(Modifier.fillMaxSize()) { drawScope(kind, anchors, data.value) }
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

// ── Pump: absolute-schedule ~10 Hz reduction ──

/**
 * Decodes the live JPEG at 1/8-class resolution and drives one scope tick
 * through the facade every [SCOPE_PERIOD_NANOS].
 *
 * Cadence is timer-driven against an absolute schedule (`start + n·period`) —
 * NEVER an `elapsed >= interval` gate against the frame stream, which only
 * ever locks onto integer divisions of the source rate (the repo's wall-clock
 * aliasing scar, fixed 4ae1544 on iOS). A tick that finds no new frame skips
 * the work and keeps the schedule.
 */
private suspend fun pumpScope(
    frames: Flow<LiveFrame>,
    kind: ScopeKind,
    present: (ScopeDrawData) -> Unit,
): Unit = coroutineScope {
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
        if (jpeg === lastProcessed) continue // static feed — hold the trace
        lastProcessed = jpeg

        val tickStart = System.nanoTime()
        val reduced = tap.reduce(jpeg) ?: continue
        when (kind) {
            ScopeKind.WAVEFORM, ScopeKind.PARADE -> {
                val traces =
                    ScopeTraces.parse(
                        SwiftCore.scopeTraces(
                            reduced.rgba, reduced.width, reduced.height,
                            reduced.bytesPerRow, CURVE_LOG3G10,
                        ),
                    )
                present(ScopeDrawData(traces = traces, trailTraces = previousTraces))
                previousTraces = traces
            }
            ScopeKind.HISTOGRAM -> {
                val traces =
                    ScopeTraces.parse(
                        SwiftCore.scopeTraces(
                            reduced.rgba, reduced.width, reduced.height,
                            reduced.bytesPerRow, CURVE_LOG3G10,
                        ),
                    )
                present(ScopeDrawData(histogram = histogramDisplay(traces, previousHistogram)))
                previousHistogram = traces
            }
            ScopeKind.VECTORSCOPE -> {
                val pixels =
                    SwiftCore.scopeVector(
                        reduced.rgba, reduced.width, reduced.height,
                        reduced.bytesPerRow, CURVE_LOG3G10,
                    )
                val image = vectorBitmaps.imageFrom(pixels)
                present(ScopeDrawData(vector = image, vectorTrail = previousVector))
                previousVector = image
            }
        }
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

/** iOS `scopeLevelY`: display level 0…1 to y, with the 4% top/bottom buffer. */
private fun levelY(level: Float, plot: Rect): Float =
    plot.bottom - (0.04f + level * 0.92f) * plot.height

private fun DrawScope.drawScope(kind: ScopeKind, anchors: ScopeAnchors, data: ScopeDrawData?) {
    val plot = plotRect()
    when (kind) {
        ScopeKind.WAVEFORM, ScopeKind.PARADE -> {
            data?.trailTraces?.let { drawTrace(kind, it, plot, ScopePalette.TRAIL_DECAY) }
            data?.traces?.let { drawTrace(kind, it, plot, 1f) }
            drawAxisGuides(anchors, plot)
        }
        ScopeKind.HISTOGRAM -> {
            data?.histogram?.let { drawHistogram(it, plot) }
            drawHistogramGuides(anchors, plot)
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
    var scratch = pointScratch.get()
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

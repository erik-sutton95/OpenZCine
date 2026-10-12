@file:androidx.media3.common.util.UnstableApi

package com.opencapture.openzcine

import android.content.Context
import android.graphics.Bitmap
import android.util.Log
import androidx.compose.runtime.collectAsState
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import com.opencapture.monitorui.MonitorBackdropPolicy
import com.opencapture.monitorui.MonitorBackdropSource
import com.opencapture.opencine.appkit.MonitorInspectorPreviewClient
import com.opencapture.opencine.media.FeedEffectsRenderPlan
import com.opencapture.opencine.nikon.LiveFrameSource
import com.opencapture.opencine.runtime.InspectorPreviewFrame
import com.opencapture.opencine.runtime.InspectorPreviewPipeline
import com.opencapture.opencine.runtime.MonitorBitmapPreviewEncoder
import com.opencapture.opencine.runtime.NativeBackdropFeed
import com.opencapture.opencine.runtime.nativeFeedContentRect
import com.opencapture.opencine.runtime.ScopeSampleBus

/** A bounded tap of accepted native pictures, never a second decoder or source subscription. */
internal class NikonLiveInspectorPreview(private val context: Context) :
    MonitorInspectorPreviewClient<ImageBitmap>, AutoCloseable {
    private val samples = ScopeSampleBus()
    private val pipeline = InspectorPreviewPipeline(samples, ::Media3FeedGlBackend, "ZCInspector")
    private val lock = Any()
    private data class Source(val producer: LiveFrameSource, val identity: Any, val lease: ScopeSampleBus.Source)
    private var source: Source? = null
    private var owner: Any? = null
    private var closed = false

    /** Presentation-thread facts are mirrored here before worker admission. */
    fun configure(producer: LiveFrameSource?, identity: Any?, active: Boolean) {
        val next = synchronized(lock) {
            if (closed) return
            val previous = source
            if (active && producer != null && identity != null &&
                previous?.producer === producer && previous.identity == identity) return
            samples.closeSource(previous?.lease)
            source = if (active && producer != null && identity != null)
                Source(producer, identity, samples.openSource()) else null
            source
        }
        // Replacement closes the old lease immediately, including already posted delivery.
        pipeline.sourceChanged(next?.lease)
    }

    override fun open(owner: Any, playback: Boolean, plan: FeedEffectsRenderPlan, receive: (ImageBitmap?) -> Unit) {
        if (playback) return
        synchronized(lock) { if (closed) return; this.owner = owner }
        pipeline.open(owner, false, context, plan) { receive(it?.asImageBitmap()) }
    }
    override fun update(owner: Any, plan: FeedEffectsRenderPlan) = pipeline.update(owner, plan)
    override fun close(owner: Any) {
        synchronized(lock) { if (this.owner === owner) this.owner = null }
        pipeline.close(owner)
    }

    /** The decoder's pooled bitmap is copied while still borrowed, only after bounded admission. */
    fun accept(producer: LiveFrameSource, bitmap: Bitmap) {
        val captured = synchronized(lock) {
            val source = source?.takeIf { it.producer === producer } ?: return
            source to (owner ?: return)
        }
        if (decodedLiveFeedColorMode(bitmap) != LiveFeedColorMode.SDR) return
        val ticket = pipeline.acquire(captured.second, false, System.nanoTime(), captured.first.lease) ?: return
        var submitted = false
        try {
            val frame = liveSampleFrame(bitmap) ?: return
            pipeline.submit(ticket, frame) {
                synchronized(lock) { !closed && source === captured.first && owner === captured.second }
            }
            submitted = true
        } catch (error: RuntimeException) {
            // A retired preview worker or failed readback must not terminate live acquisition.
            Log.w("ZCInspector", "Preview capture unavailable", error)
        } finally { if (!submitted) pipeline.cancel(ticket) }
    }

    override fun close() {
        synchronized(lock) {
            if (closed) return
            closed = true
            samples.closeSource(source?.lease)
            source = null
            owner = null
        }
        pipeline.close()
    }
}


/** One <=213x120 RGBA copy of a presented picture, taken while the decoder still lends the bitmap. */
private fun liveSampleFrame(bitmap: Bitmap): InspectorPreviewFrame? {
    val maximumWidth = minOf(213, (bitmap.width.toDouble() * 120 / bitmap.height).toInt().coerceAtLeast(1))
    val snapshot = MonitorBitmapPreviewEncoder.snapshot(bitmap, maximumWidth) ?: return null
    try {
        val pixels = IntArray(snapshot.width * snapshot.height)
        snapshot.getPixels(pixels, 0, snapshot.width, 0, 0, snapshot.width, snapshot.height)
        val rgba = ByteArray(pixels.size * 4)
        pixels.forEachIndexed { index, pixel ->
            rgba[index * 4] = (pixel ushr 16).toByte()
            rgba[index * 4 + 1] = (pixel ushr 8).toByte()
            rgba[index * 4 + 2] = pixel.toByte()
            rgba[index * 4 + 3] = (pixel ushr 24).toByte()
        }
        return InspectorPreviewFrame(snapshot.width, snapshot.height, rgba)
    } finally { snapshot.recycle() }
}

/**
 * The live picture under the shared material, the source every Core [monitorMaterial] panel samples
 * (A3-09). The same bounded tap of presented pictures as the inspector preview, graded with the live
 * look by Core's [NativeBackdropFeed] at the shared admission rate. The monitor activates it.
 */
internal class NikonLiveBackdrop(context: Context) : AutoCloseable {
    val source = MonitorBackdropSource()
    private val feed = NativeBackdropFeed(context, ::Media3FeedGlBackend, MonitorBackdropPolicy.MINIMUM_INTERVAL_NS,
        receive = { source.image = it }, logTag = "ZCBackdrop")
    @Volatile private var producer: LiveFrameSource? = null

    fun setActive(active: Boolean) = feed.setActive(active)

    /** A changed or retired picture source drops the sample it left under the glass. */
    fun sourceChanged() = feed.sourceChanged()

    /** [plan] is the live look on the picture; null shows it plain. */
    fun accept(producer: LiveFrameSource, bitmap: Bitmap, plan: FeedEffectsRenderPlan?) {
        if (this.producer !== producer) {
            this.producer = producer
            feed.attach(producer)
        }
        if (!feed.hasDemand(producer) || decodedLiveFeedColorMode(bitmap) != LiveFeedColorMode.SDR) return
        val look = plan ?: FeedEffectsRenderPlan.IDENTITY
        feed.updatePlan(producer, look)
        val ticket = feed.acquire(producer, System.nanoTime()) ?: return
        var submitted = false
        try {
            val frame = liveSampleFrame(bitmap) ?: return
            feed.submit(ticket, frame, look)
            submitted = true
        } catch (error: RuntimeException) {
            Log.w("ZCBackdrop", "Backdrop capture unavailable", error)
        } finally { if (!submitted) feed.cancel(ticket) }
    }

    override fun close() = feed.close()
}

/**
 * Where the presented picture sits in its feed zone, in zone pixels: the raster's fit or fill, then the
 * de-squeeze scale about the zone centre (the feed view's own layer). Null before the first frame.
 */
internal fun liveBackdropImageRect(zoneWidth: Float, zoneHeight: Float, sourceWidth: Int, sourceHeight: Int,
    aspectFill: Boolean, scaleX: Float, scaleY: Float): Rect? {
    val content = nativeFeedContentRect(zoneWidth, zoneHeight, sourceWidth, sourceHeight, aspectFill) ?: return null
    val cx = zoneWidth / 2f
    val cy = zoneHeight / 2f
    return Rect(cx + (content.left - cx) * scaleX, cy + (content.top - cy) * scaleY,
        cx + (content.left + content.width - cx) * scaleX, cy + (content.top + content.height - cy) * scaleY)
}

/** The shared image view owns inspector/lifecycle retirement; this adapter supplies native facts. */
@androidx.compose.runtime.Composable
internal fun NikonInspectorImagePreview(
    tool: com.opencapture.monitorui.MonitorAssistTool,
    assists: NikonAssists,
    client: NikonLiveInspectorPreview,
    cameraInput: ExposureAssistCameraInput,
    lutLibrary: com.opencapture.openzcine.lut.AndroidLutLibrary?,
    sourceIdentity: Any,
    colorMode: LiveFeedColorMode,
) {
    if (!com.opencapture.opencine.cameracontrols.MonitorInspectorImagePreviewPolicy.supports(tool)) return
    val effects = assists.feedEffects { candidate ->
        candidate == tool || (candidate == com.opencapture.monitorui.MonitorAssistTool.LUT &&
            assists.shared.isOn(candidate))
    }.copy(splitComparison = null)
    val configuration = assists.shared.feedEffectsConfiguration
    val lutGeneration = lutLibrary?.renderGeneration?.collectAsState()?.value
    androidx.compose.runtime.LaunchedEffect(lutLibrary, effects.lut) {
        (effects.lut as? FeedLutSelection.Stored)?.value?.let { lutLibrary?.prepare(it) }
    }
    val plan = androidx.compose.runtime.remember(tool, effects, configuration, cameraInput, lutLibrary, lutGeneration) {
        FeedEffectsRenderPlanFactory.create(effects, configuration, cameraInput, lutLibrary)
            ?.takeIf { (effects.lut == null || it.baseCube != null) &&
                (effects.falseColor == null || it.falseColorReady) }
    }
    if (plan == null || colorMode != LiveFeedColorMode.SDR) {
        com.opencapture.monitorui.MonitorImagePreview(null, "${tool.title} image preview",
            waitingLabel = "Preview unavailable")
    } else {
        com.opencapture.opencine.cameracontrols.MonitorOperatorInspectorImagePreview(
            tool, assists.shared, client, plan.nativePlan, sourceIdentity, colorMode.ordinal, false)
    }
}

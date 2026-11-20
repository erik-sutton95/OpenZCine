package com.opencapture.openzcine

import android.Manifest
import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Rect
import android.util.Log
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.core.graphics.createBitmap
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.opencapture.monitorui.livestream.LiveStreamMonitorControls
import com.opencapture.opencine.appkitnative.LiveStreamComposition
import com.opencapture.opencine.appkitnative.LiveStreamCoordinator
import com.opencapture.opencine.appkitnative.LiveStreamSource
import com.opencapture.opencine.media.FeedEffectsRenderPlan
import com.opencapture.opencine.nikon.LiveFrame
import com.opencapture.opencine.nikon.SavedCameraTransport
import com.opencapture.opencine.runtime.MonitorCleanPictureFrame
import com.opencapture.opencine.runtime.MonitorCleanPictureTap
import com.opencapture.opencine.streaming.StreamConnectionRoute
import com.opencapture.opencine.streaming.StreamingNative
import com.opencapture.openzcine.pairing.rememberPermissionGate
import java.nio.ByteBuffer
import kotlinx.coroutines.CoroutineScope

private const val TAG = "ZCLiveStream"

/**
 * The stream route of the camera on the monitor, from the app's existing connection mode only (it
 * never asks the camera): the HDMI capture card while the monitor shows it, otherwise the saved
 * setup's transport. No session on the monitor, or one without a saved setup (the debug demo), is
 * no camera.
 */
internal fun liveStreamRoute(
    hasSession: Boolean,
    hdmiCapture: Boolean,
    transport: SavedCameraTransport?,
): StreamConnectionRoute? = when {
    !hasSession -> null
    hdmiCapture -> StreamConnectionRoute.CAPTURE_CARD
    else -> when (transport) {
        SavedCameraTransport.CAMERA_ACCESS_POINT -> StreamConnectionRoute.CAMERA_WIFI
        SavedCameraTransport.INFRASTRUCTURE -> StreamConnectionRoute.SHARED_WIFI
        SavedCameraTransport.PHONE_HOTSPOT -> StreamConnectionRoute.DEVICE_HOTSPOT
        SavedCameraTransport.USB_C -> StreamConnectionRoute.USB_CABLE
        null -> null
    }
}

/**
 * The shape the monitor shows a [width] by [height] picture at under its de-squeeze presentation
 * scales, so the stream carries the same shape; null when de-squeeze is off.
 */
internal fun liveStreamPictureAspect(width: Int, height: Int, scaleX: Float, scaleY: Float): Float? =
    if ((scaleX == 1f && scaleY == 1f) || width <= 0 || height <= 0) null
    else (width * scaleX) / (height * scaleY)

/**
 * OpenZCine's live streaming: one clean picture tap and one coordinator for the process, owned by
 * the retained [AppRoot] and closed with it.
 *
 * The Z monitor presents decoded bitmaps through its own renderer, not OpenCine's native live feed
 * sessions, so nothing in the runtime feeds the tap. [accept] is the producer: the monitor hands it
 * every presented picture and it submits a raw copy (with the live look; the tap drops assists) at
 * the tap's own cadence, only while a stream is attached. It also records the picture's real size
 * as the stream source.
 */
internal class LiveStreamAdoption private constructor(
    private val cleanPicture: MonitorCleanPictureTap,
    route: () -> StreamConnectionRoute?,
    scope: CoroutineScope,
    context: Context,
) : AutoCloseable {
    @Volatile private var picture: LiveStreamSource? = null
    private var scaled: Bitmap? = null
    private val scalePaint by lazy { Paint(Paint.FILTER_BITMAP_FLAG) }

    val coordinator: LiveStreamCoordinator = LiveStreamComposition.coordinator(
        context,
        preferencesFile = "${context.packageName}.live-stream",
        keystoreAlias = "${context.packageName}.live-stream",
        cleanPicture = cleanPicture,
        route = route,
        source = { picture },
        scope = scope,
    )

    /**
     * Main thread, once per presented picture of the monitor's camera. [aspect] is the shape the
     * monitor shows it at while de-squeeze is on (null keeps the picture's own).
     */
    fun accept(frame: LiveFrame, bitmap: Bitmap, plan: FeedEffectsRenderPlan?, aspect: Float?) {
        val size = LiveStreamSource(bitmap.width, bitmap.height, null, null)
        if (size != picture) {
            picture = size
            coordinator.refresh()
        }
        cleanPicture.setPictureAspect(aspect)
        if (!cleanPicture.frameDue(System.nanoTime())) return
        if (bitmap.config != Bitmap.Config.ARGB_8888 || decodedLiveFeedColorMode(bitmap) != LiveFeedColorMode.SDR) return
        val raw = try {
            rawFrame(bitmap)
        } catch (error: RuntimeException) {
            Log.w(TAG, "clean picture copy failed; the stream keeps its last picture", error)
            return
        }
        cleanPicture.submit(raw, frame.timestampNanos, plan ?: FeedEffectsRenderPlan.IDENTITY)
    }

    /** The monitor's picture source went away: no source until the next picture. */
    fun pictureEnded() {
        if (picture == null) return
        picture = null
        coordinator.refresh()
    }

    /** RGBA rows of [bitmap], scaled down first when wider than the tap reads back. */
    private fun rawFrame(bitmap: Bitmap): MonitorCleanPictureFrame {
        val source = if (bitmap.width <= cleanPicture.maxWidth && bitmap.rowBytes == bitmap.width * 4) {
            bitmap
        } else {
            scaledCopy(bitmap)
        }
        val rgba = cleanPicture.frameBuffer(source.width * source.height * 4)
        // ARGB_8888 is RGBA in memory, the order the tap uploads.
        source.copyPixelsToBuffer(ByteBuffer.wrap(rgba))
        return MonitorCleanPictureFrame(source.width, source.height, rgba)
    }

    private fun scaledCopy(bitmap: Bitmap): Bitmap {
        val width = minOf(bitmap.width, cleanPicture.maxWidth)
        val height = (bitmap.height.toLong() * width / bitmap.width).toInt().coerceAtLeast(1)
        val target = scaled?.takeIf { it.width == width && it.height == height }
            ?: createBitmap(width, height).also {
                scaled?.recycle()
                scaled = it
            }
        Canvas(target).drawBitmap(bitmap, null, Rect(0, 0, width, height), scalePaint)
        return target
    }

    override fun close() {
        coordinator.stop()
        cleanPicture.close()
        scaled?.recycle()
        scaled = null
    }

    companion object {
        /**
         * The app's streaming, or null when the Swift library that carries the streaming engine is
         * not loaded (a build without the staged core): the card and the Go live control stay away.
         */
        fun create(context: Context, scope: CoroutineScope, route: () -> StreamConnectionRoute?): LiveStreamAdoption? {
            if (!StreamingNative.isAvailable) return null
            val app = context.applicationContext
            val tap = MonitorCleanPictureTap(app)
            return try {
                LiveStreamAdoption(tap, route, scope, app)
            } catch (error: UnsatisfiedLinkError) {
                // A staged library older than the streaming engine.
                Log.e(TAG, "live streaming unavailable in this build", error)
                tap.close()
                null
            }
        }
    }
}

/**
 * The Go live control, status, notice and warnings for the top center of the monitor picture. The
 * microphone is asked through the app's permission gate before a confirmed start; the start runs
 * when it is granted (from the dialog or from Settings on return). A refusal still goes through the
 * coordinator, which ends with the microphone notice.
 */
@Composable
internal fun LiveStreamMonitorOverlay(coordinator: LiveStreamCoordinator, modifier: Modifier = Modifier) {
    val state by coordinator.state.collectAsState()
    var startWhenGranted by remember { mutableStateOf(false) }
    val microphone = rememberPermissionGate("livestream.microphone", listOf(Manifest.permission.RECORD_AUDIO)) {
        if (startWhenGranted) {
            startWhenGranted = false
            coordinator.goLive()
        }
    }
    // The ask returns on resume (after the gate's own observer, registered first). A start still
    // waiting then was refused: the coordinator shows the microphone notice.
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    DisposableEffect(lifecycle, coordinator) {
        val observer = LifecycleEventObserver { _, event ->
            if (event != Lifecycle.Event.ON_RESUME || !startWhenGranted) return@LifecycleEventObserver
            startWhenGranted = false
            coordinator.goLive()
        }
        lifecycle.addObserver(observer)
        onDispose { lifecycle.removeObserver(observer) }
    }
    LiveStreamMonitorControls(state, coordinator, modifier) {
        if (microphone.granted) {
            coordinator.goLive()
        } else {
            startWhenGranted = true
            microphone.request()
        }
    }
}

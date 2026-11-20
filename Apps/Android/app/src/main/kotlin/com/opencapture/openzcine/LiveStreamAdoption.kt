package com.opencapture.openzcine

import android.content.Context
import android.graphics.Bitmap
import android.util.Log
import com.opencapture.opencine.appkitnative.LiveStreamComposition
import com.opencapture.opencine.appkitnative.LiveStreamCoordinator
import com.opencapture.opencine.appkitnative.LiveStreamSource
import com.opencapture.opencine.media.FeedEffectsRenderPlan
import com.opencapture.opencine.nikon.LiveFrame
import com.opencapture.opencine.nikon.SavedCameraTransport
import com.opencapture.opencine.runtime.MonitorCleanPictureTap
import com.opencapture.opencine.streaming.StreamConnectionRoute
import com.opencapture.opencine.streaming.StreamingNative
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
 * every presented picture and the tap's `submitBitmap` copies it (with the live look; the tap drops
 * assists) at the tap's own cadence, only while a stream is attached. It also records the picture's
 * real size as the stream source.
 */
internal class LiveStreamAdoption private constructor(
    private val cleanPicture: MonitorCleanPictureTap,
    route: () -> StreamConnectionRoute?,
    scope: CoroutineScope,
    context: Context,
) : AutoCloseable {
    @Volatile private var picture: LiveStreamSource? = null

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
        // An HDR picture is not the identity SDR the tap expects; the stream keeps its last frame.
        if (!cleanPicture.wantsFrames || decodedLiveFeedColorMode(bitmap) != LiveFeedColorMode.SDR) return
        cleanPicture.submitBitmap(bitmap, frame.timestampNanos, plan ?: FeedEffectsRenderPlan.IDENTITY)
    }

    /** The monitor's picture source went away: no source until the next picture. */
    fun pictureEnded() {
        if (picture == null) return
        picture = null
        coordinator.refresh()
    }

    override fun close() {
        coordinator.stop()
        cleanPicture.close()
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

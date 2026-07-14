package com.opencapture.openzcine

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.MediaCodecList
import android.util.Log
import androidx.compose.foundation.Canvas
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import com.opencapture.openzcine.core.LiveFrameSource
import kotlin.math.min
import kotlin.math.roundToInt
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

private const val TAG = "ZCLiveFeed"

/**
 * Decodes the live-view JPEG stream into a small ring of reused [Bitmap]s.
 *
 * Decode-path decision (OPE-28 spike), measured on the SM-A127F floor device:
 * - **Chosen: [BitmapFactory.decodeByteArray] + `inBitmap` reuse.** After the
 *   ring fills, the steady state is zero per-frame allocation — the JPEG is
 *   decoded straight into an existing buffer. Sustains the 25 fps stream with
 *   ~2/3 of the frame budget idle on the test device.
 * - **ImageDecoder**: allocates a fresh (often hardware) bitmap per frame —
 *   25 allocations/s of ~2.7 MB each is pure GC churn with no quality upside
 *   for a monitor feed.
 * - **MediaCodec `video/mjpeg`**: probed at runtime (see the one-shot log in
 *   [LiveFeedView]); no decoder on the SM-A127F and rarely present on any
 *   SoC, so it can only ever be an opportunistic fast path — not worth a
 *   second pipeline for the spike.
 * - **SurfaceView / AndroidExternalSurface**: a software-canvas blit plus its
 *   own lifecycle and pacing. A Compose draw-scope state read invalidates
 *   *draw only* (no recomposition, no layout), which measures equivalently
 *   smooth here with far less code; revisit only if profiling shows the
 *   texture upload hurting.
 *
 * The ring is 3 deep so the bitmap being decoded into is never the one the
 * RenderThread may still be drawing (current frame + one in flight).
 */
class JpegFrameDecoder {
    private val pool = arrayOfNulls<Bitmap>(3)
    private var next = 0
    private val options = BitmapFactory.Options().apply { inMutable = true }

    /** Decodes [jpeg] into the next pooled bitmap; null if the data is invalid. */
    fun decode(jpeg: ByteArray): Bitmap? {
        options.inBitmap = pool[next]
        val decoded =
            try {
                BitmapFactory.decodeByteArray(jpeg, 0, jpeg.size, options)
            } catch (_: IllegalArgumentException) {
                // Pooled bitmap incompatible (feed size changed) — decode fresh
                // and let the ring re-fill at the new size.
                options.inBitmap = null
                BitmapFactory.decodeByteArray(jpeg, 0, jpeg.size, options)
            } ?: return null
        pool[next] = decoded
        next = (next + 1) % pool.size
        return decoded
    }
}

/**
 * Renders a [LiveFrameSource] as the monitor feed: decodes off the main
 * thread with latest-wins conflation ([pumpFrames]) and draws the newest
 * frame aspect-fit (black letterbox) into the full modifier bounds.
 *
 * The frame state is read inside the [Canvas] draw lambda only, so a new
 * frame costs one draw invalidation — no recomposition, no layout.
 */
@Composable
fun LiveFeedView(source: LiveFrameSource, modifier: Modifier = Modifier) {
    val frame = remember { mutableStateOf<ImageBitmap?>(null) }

    LaunchedEffect(source) {
        if (BuildConfig.DEBUG) {
            Log.d(TAG, "hardware MJPEG decoder available: ${hasMjpegDecoder()}")
        }
        val decoder = JpegFrameDecoder()
        val stats = FramePacingStats(log = { if (BuildConfig.DEBUG) Log.d(TAG, it) })
        // ponytail: pumps while composed; lifecycle pause/resume lands with the
        // real camera source wiring.
        withContext(Dispatchers.Default) {
            pumpFrames(
                frames = source.frames,
                stats = stats,
                decode = decoder::decode,
                present = { frame.value = it.asImageBitmap() },
            )
        }
    }

    Canvas(modifier) {
        val image = frame.value ?: return@Canvas
        val scale = min(size.width / image.width, size.height / image.height)
        val dstSize = IntSize((image.width * scale).roundToInt(), (image.height * scale).roundToInt())
        val dstOffset =
            IntOffset(
                ((size.width - dstSize.width) / 2f).roundToInt(),
                ((size.height - dstSize.height) / 2f).roundToInt(),
            )
        drawImage(image, dstOffset = dstOffset, dstSize = dstSize)
    }
}

/** Runtime probe: does this SoC expose a hardware MJPEG video decoder? */
private fun hasMjpegDecoder(): Boolean =
    MediaCodecList(MediaCodecList.ALL_CODECS).codecInfos.any { info ->
        !info.isEncoder &&
            info.supportedTypes.any {
                it.equals("video/mjpeg", ignoreCase = true) ||
                    it.equals("video/x-motion-jpeg", ignoreCase = true)
            }
    }

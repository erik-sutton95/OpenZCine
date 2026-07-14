package com.opencapture.openzcine

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.MediaCodecList
import android.os.Build
import android.util.Log
import androidx.compose.foundation.Canvas
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
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
 *
 * [onFrame] observes each presented frame on the decode thread — the glass
 * backdrop producer hooks in here ([MonitorGlass.submit]). The bitmap is
 * pooled; it stays valid until two more frames have been decoded.
 *
 * [effects] bakes the GPU assist chain (LUT / false colour / peaking / zebra,
 * see [FeedEffectsRenderer]) into the drawn frame. The default preserves the
 * plain feed unless the debug harness switched effects on; devices below
 * API 33 (AGSL) or builds without the staged Swift core always render plain.
 */
@Composable
fun LiveFeedView(
    source: LiveFrameSource,
    modifier: Modifier = Modifier,
    onFrame: ((Bitmap) -> Unit)? = null,
    effects: FeedEffects = FeedEffectsState.current,
) {
    val frame = remember { mutableStateOf<ImageBitmap?>(null) }
    // This changes only once, after the first valid JPEG renders. It exposes
    // a useful TalkBack state and lets UI tests distinguish a mounted feed
    // from a camera stream that is genuinely presenting frames.
    val hasPresentedFrame = remember(source) { mutableStateOf(false) }
    val renderer =
        remember(effects) {
            when {
                effects.isIdentity -> null
                Build.VERSION.SDK_INT >= 33 -> FeedEffectsRenderer.create(effects)
                else -> {
                    Log.w(TAG, "feed effects need Android 13+ (AGSL); rendering the plain feed")
                    null
                }
            }
        }

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
                present = {
                    frame.value = it.asImageBitmap()
                    hasPresentedFrame.value = true
                    onFrame?.invoke(it)
                },
            )
        }
    }

    Canvas(
        modifier.semantics {
            contentDescription =
                if (hasPresentedFrame.value) "Live view active" else "Live view starting"
        },
    ) {
        val image = frame.value ?: return@Canvas
        val scale = min(size.width / image.width, size.height / image.height)
        val dstSize = IntSize((image.width * scale).roundToInt(), (image.height * scale).roundToInt())
        val dstOffset =
            IntOffset(
                ((size.width - dstSize.width) / 2f).roundToInt(),
                ((size.height - dstSize.height) / 2f).roundToInt(),
            )
        if (Build.VERSION.SDK_INT >= 33 && renderer != null) {
            renderer.draw(
                canvas = drawContext.canvas.nativeCanvas,
                frame = image.asAndroidBitmap(),
                dstLeft = dstOffset.x.toFloat(),
                dstTop = dstOffset.y.toFloat(),
                dstWidth = dstSize.width.toFloat(),
                dstHeight = dstSize.height.toFloat(),
            )
        } else {
            drawImage(image, dstOffset = dstOffset, dstSize = dstSize)
        }
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

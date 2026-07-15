package com.opencapture.openzcine

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.MediaCodecList
import android.os.Build
import android.util.Log
import androidx.compose.foundation.Canvas
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.Stable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import com.opencapture.openzcine.core.LiveCameraLevel
import com.opencapture.openzcine.core.LiveFocusInfo
import com.opencapture.openzcine.core.LiveFrame
import com.opencapture.openzcine.core.LiveFrameSource
import com.opencapture.openzcine.lut.AndroidLutLibrary
import kotlin.math.min
import kotlin.math.roundToInt
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

private const val TAG = "ZCLiveFeed"

/** The exact integer destination rectangle used by the aspect-fit feed Canvas. */
internal data class LiveFeedContentRect(
    val left: Int,
    val top: Int,
    val width: Int,
    val height: Int,
)

/**
 * Resolves the same pixel-rounded aspect-fit rectangle the feed renderer
 * draws. Feed overlays call this instead of estimating against the monitor
 * zone, which can contain black letterbox space.
 */
internal fun liveFeedContentRect(
    containerWidth: Float,
    containerHeight: Float,
    sourceWidth: Int,
    sourceHeight: Int,
): LiveFeedContentRect? {
    if (containerWidth <= 0f || containerHeight <= 0f || sourceWidth <= 0 || sourceHeight <= 0) {
        return null
    }
    val scale = min(containerWidth / sourceWidth, containerHeight / sourceHeight)
    val width = (sourceWidth * scale).roundToInt()
    val height = (sourceHeight * scale).roundToInt()
    if (width <= 0 || height <= 0) return null
    return LiveFeedContentRect(
        left = ((containerWidth - width) / 2f).roundToInt(),
        top = ((containerHeight - height) / 2f).roundToInt(),
        width = width,
        height = height,
    )
}

/** One immutable image-and-metadata record accepted by the latest-wins feed. */
@Immutable
private data class LiveFeedPresentation(
    val image: ImageBitmap,
    val sourceWidth: Int,
    val sourceHeight: Int,
    val focus: LiveFocusInfo?,
    val level: LiveCameraLevel?,
)

/**
 * Presentation data paired with the bitmap that the feed actually accepted
 * after latest-wins conflation. It prevents focus and virtual-horizon overlays
 * from drifting onto a different decoded frame by publishing one immutable
 * image-and-metadata record, rather than a sequence of mutable fields.
 */
@Stable
public class LiveFeedPresentationState {
    private var presentation: LiveFeedPresentation? by mutableStateOf(null)

    /** The exact image whose metadata the other accessors describe. */
    internal val image: ImageBitmap?
        get() = presentation?.image

    /** Width of the decoded image currently on screen, or zero before a frame. */
    public val sourceWidth: Int
        get() = presentation?.sourceWidth ?: 0

    /** Height of the decoded image currently on screen, or zero before a frame. */
    public val sourceHeight: Int
        get() = presentation?.sourceHeight ?: 0

    /** Camera-origin focus metadata paired with the visible image. */
    public val focus: LiveFocusInfo?
        get() = presentation?.focus

    /** Camera-origin virtual-horizon metadata paired with the visible image. */
    public val level: LiveCameraLevel?
        get() = presentation?.level

    internal fun present(frame: LiveFrame, bitmap: Bitmap) {
        presentation =
            LiveFeedPresentation(
                image = bitmap.asImageBitmap(),
                sourceWidth = bitmap.width,
                sourceHeight = bitmap.height,
                focus = frame.focus,
                level = frame.level,
            )
    }

    internal fun clear() {
        presentation = null
    }
}

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
 * [presentationState], when supplied, retains the same frame's camera
 * metadata and image dimensions for feed-aligned overlays.
 *
 * [effects] bakes the GPU assist chain (LUT / false colour / peaking / zebra,
 * see [FeedEffectsRenderer]) into the drawn frame. The default preserves the
 * plain feed unless the debug harness switched effects on; devices below
 * API 33 (AGSL) or builds without the staged Swift core always render plain.
 * [configuration] is local operator choice only; [cameraInput] is forwarded
 * unchanged to Swift, which owns camera curve/clip policy for both the
 * renderer and the optional false-colour reference key.
 */
@Composable
fun LiveFeedView(
    source: LiveFrameSource,
    modifier: Modifier = Modifier,
    onFrame: ((Bitmap) -> Unit)? = null,
    presentationState: LiveFeedPresentationState? = null,
    effects: FeedEffects = FeedEffectsState.current,
    configuration: FeedEffectsConfiguration = FeedEffectsConfiguration(),
    cameraInput: ExposureAssistCameraInput = ExposureAssistCameraInput(),
    lutLibrary: AndroidLutLibrary? = null,
) {
    val fallbackFrame = remember(source) { mutableStateOf<ImageBitmap?>(null) }
    // Stored selections are prepared off the UI thread. Until the shared Swift parser has produced
    // a packed payload, the renderer remains fail-closed (plain feed), then rebuilds on generation.
    val lutRenderGeneration = lutLibrary?.renderGeneration?.collectAsState()?.value ?: 0L
    LaunchedEffect(lutLibrary, effects.lut) {
        val stored = (effects.lut as? FeedLutSelection.Stored)?.value
        if (stored != null) lutLibrary?.prepare(stored)
    }
    val renderer =
        remember(effects, configuration, cameraInput, lutLibrary, lutRenderGeneration) {
            when {
                effects.isIdentity -> null
                Build.VERSION.SDK_INT >= 33 ->
                    FeedEffectsRenderer.create(effects, configuration, cameraInput, lutLibrary)
                else -> {
                    Log.w(TAG, "feed effects need Android 13+ (AGSL); rendering the plain feed")
                    null
                }
            }
        }
    val falseColorReference =
        remember(renderer, effects.falseColor, configuration.falseColorReferenceEnabled, cameraInput) {
            // Do not show a palette for an effect that failed closed (for
            // example below API 33 or if the Swift payload was rejected).
            if (renderer == null) {
                null
            } else {
                effects.falseColor
                    ?.takeIf { configuration.falseColorReferenceEnabled }
                    ?.let { scale -> resolveFalseColorReference(scale, cameraInput) }
            }
        }

    LaunchedEffect(source, presentationState) {
        presentationState?.clear()
        fallbackFrame.value = null
        if (BuildConfig.DEBUG) {
            Log.d(TAG, "hardware MJPEG decoder available: ${hasMjpegDecoder()}")
        }
        val decoder = JpegFrameDecoder()
        val stats = FramePacingStats(log = { if (BuildConfig.DEBUG) Log.d(TAG, it) })
        // ponytail: pumps while composed; lifecycle pause/resume lands with the
        // real camera source wiring.
        withContext(Dispatchers.Default) {
            pumpFramesWithSourceFrame(
                frames = source.frames,
                stats = stats,
                decode = decoder::decode,
                present = { sourceFrame, bitmap ->
                    if (presentationState != null) {
                        presentationState.present(sourceFrame, bitmap)
                    } else {
                        fallbackFrame.value = bitmap.asImageBitmap()
                    }
                    onFrame?.invoke(bitmap)
                },
            )
        }
    }

    Canvas(modifier) {
        val image = presentationState?.image ?: fallbackFrame.value ?: return@Canvas
        val content =
            liveFeedContentRect(
                containerWidth = size.width,
                containerHeight = size.height,
                sourceWidth = image.width,
                sourceHeight = image.height,
            ) ?: return@Canvas
        val dstSize = IntSize(content.width, content.height)
        val dstOffset = IntOffset(content.left, content.top)
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
        falseColorReference?.let { reference ->
            drawFalseColorReference(reference, content.left.toFloat(), content.top.toFloat(), content.width.toFloat())
        }
    }
}

/** Draws the Swift-derived palette key only while false colour is actively rendered. */
private fun androidx.compose.ui.graphics.drawscope.DrawScope.drawFalseColorReference(
    reference: FeedFalseColorReference,
    feedLeft: Float,
    feedTop: Float,
    feedWidth: Float,
) {
    if (reference.colors.isEmpty()) return
    val block = 8.dp.toPx()
    val gap = 2.dp.toPx()
    val padding = 5.dp.toPx()
    val keyWidth = padding * 2 + reference.colors.size * block + (reference.colors.size - 1) * gap
    val left = (feedLeft + feedWidth - keyWidth - 8.dp.toPx()).coerceAtLeast(feedLeft + 4.dp.toPx())
    val top = feedTop + 8.dp.toPx()
    drawRoundRect(
        color = Color(0.025f, 0.036f, 0.03f, 0.82f),
        topLeft = Offset(left, top),
        size = Size(keyWidth, block + padding * 2),
        cornerRadius = CornerRadius(4.dp.toPx()),
    )
    reference.colors.forEachIndexed { index, rgb ->
        drawRoundRect(
            color = Color(rgb[0], rgb[1], rgb[2]),
            topLeft = Offset(left + padding + index * (block + gap), top + padding),
            size = Size(block, block),
            cornerRadius = CornerRadius(1.dp.toPx()),
        )
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

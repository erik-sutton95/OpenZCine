package com.opencapture.openzcine

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.MediaCodecList
import android.os.Build
import android.util.Log
import android.view.HapticFeedbackConstants
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.gestures.detectDragGesturesAfterLongPress
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.Stable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.graphics.drawscope.clipRect
import androidx.compose.ui.graphics.drawscope.drawIntoCanvas
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.opencapture.openzcine.bridge.ZoneFrame
import com.opencapture.openzcine.bridge.SwiftCore
import com.opencapture.openzcine.core.LiveCameraLevel
import com.opencapture.openzcine.core.LiveFocusInfo
import com.opencapture.openzcine.core.LiveFrame
import com.opencapture.openzcine.core.LiveFrameSource
import com.opencapture.openzcine.lut.AndroidLutLibrary
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

private const val TAG = "ZCLiveFeed"
private const val FALSE_COLOR_REFERENCE_WIDTH = 264f
private const val FALSE_COLOR_REFERENCE_HEIGHT = 52f
private const val FALSE_COLOR_REFERENCE_GAP = 10f
private const val FALSE_COLOR_REFERENCE_BOTTOM_CLEARANCE = 14f + LiveDesign.CONTROL_HEIGHT_DP

/** The exact integer destination rectangle used by the feed Canvas. */
internal data class LiveFeedContentRect(
    val left: Int,
    val top: Int,
    val width: Int,
    val height: Int,
)

/**
 * Resolves the same pixel-rounded fit or fill rectangle the feed renderer
 * draws. Feed overlays call this instead of estimating against the monitor
 * zone, which can contain letterbox space or a centre-cropped image.
 */
internal fun liveFeedContentRect(
    containerWidth: Float,
    containerHeight: Float,
    sourceWidth: Int,
    sourceHeight: Int,
    aspectFill: Boolean = false,
): LiveFeedContentRect? {
    if (containerWidth <= 0f || containerHeight <= 0f || sourceWidth <= 0 || sourceHeight <= 0) {
        return null
    }
    val scale =
        if (aspectFill) {
            max(containerWidth / sourceWidth, containerHeight / sourceHeight)
        } else {
            min(containerWidth / sourceWidth, containerHeight / sourceHeight)
        }
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

/**
 * Presentation data paired with the bitmap that the feed actually accepted
 * after latest-wins conflation.
 *
 * **Split state on purpose:** [frameEpoch] invalidates only the feed Canvas
 * draw. Geometry / focus / level use separate Snapshot fields that only write
 * when values change — a single `mutableStateOf(presentation)` was forcing the
 * entire monitor chrome tree to recompose at feed rate (~25 Hz) on every
 * frame and janking the UI thread on A12-class devices.
 */
@Stable
public class LiveFeedPresentationState {
    /** Bumped when the feed Canvas should redraw; feed Canvas is the only intended reader. */
    private var frameEpoch by mutableLongStateOf(0L)
    private var latestBitmap: Bitmap? = null
    /** Cap Compose draw invalidations so UI thread keeps free time for input. */
    private var lastDrawPublishNanos: Long = 0L
    private var textureSourceGeometry: FeedTextureSourceGeometry? by mutableStateOf(null)
    private var presentedColorMode: LiveFeedColorMode by mutableStateOf(LiveFeedColorMode.UNKNOWN)
    private var focusGestureGeometrySignature: FocusGestureGeometrySignature? = null
    private var retainedSourceWidth by mutableIntStateOf(0)
    private var retainedSourceHeight by mutableIntStateOf(0)
    private var retainedFocus: LiveFocusInfo? by mutableStateOf(null)
    private var retainedLevel: LiveCameraLevel? by mutableStateOf(null)

    /** Changes only when source or camera focus-coordinate geometry changes. */
    internal var focusGestureGeometryGeneration: Long by mutableLongStateOf(0L)
        private set

    /** Resolution-only state observed by the cached presentation texture. */
    internal val feedTextureSourceGeometry: FeedTextureSourceGeometry?
        get() = textureSourceGeometry

    /**
     * Latest decoded bitmap. Reading this also observes [frameEpoch] so the
     * feed Canvas redraws without publishing a new presentation object.
     */
    internal val bitmap: Bitmap?
        get() {
            // Touch frameEpoch so Canvas invalidates on every present.
            @Suppress("UNUSED_EXPRESSION")
            frameEpoch
            return latestBitmap
        }

    /** Width of the decoded image currently on screen, or zero before a frame. */
    public val sourceWidth: Int
        get() = retainedSourceWidth

    /** Height of the decoded image currently on screen, or zero before a frame. */
    public val sourceHeight: Int
        get() = retainedSourceHeight

    /** Camera-origin focus metadata paired with the visible image. */
    public val focus: LiveFocusInfo?
        get() = retainedFocus

    /** Camera-origin virtual-horizon metadata paired with the visible image. */
    public val level: LiveCameraLevel?
        get() = retainedLevel

    /** Electrical color contract of the decoded frame currently on screen. */
    internal val colorMode: LiveFeedColorMode
        get() = presentedColorMode

    internal fun present(
        frame: LiveFrame,
        bitmap: Bitmap,
        colorMode: LiveFeedColorMode,
    ) {
        val nextGestureGeometry =
            FocusGestureGeometrySignature(
                sourceWidth = bitmap.width,
                sourceHeight = bitmap.height,
                coordinateWidth = frame.focus?.coordinateWidth ?: 0,
                coordinateHeight = frame.focus?.coordinateHeight ?: 0,
            )
        if (nextGestureGeometry != focusGestureGeometrySignature) {
            focusGestureGeometrySignature = nextGestureGeometry
            focusGestureGeometryGeneration += 1
        }
        if (presentedColorMode != colorMode) presentedColorMode = colorMode
        if (retainedSourceWidth != bitmap.width) retainedSourceWidth = bitmap.width
        if (retainedSourceHeight != bitmap.height) retainedSourceHeight = bitmap.height
        if (retainedFocus != frame.focus) retainedFocus = frame.focus
        if (retainedLevel != frame.level) retainedLevel = frame.level
        latestBitmap = bitmap
        // Always keep the newest bitmap; only invalidate Compose draw at ~20 Hz
        // so the UI thread is not saturated by 25–30 full-frame Skia blits/s.
        val now = System.nanoTime()
        if (lastDrawPublishNanos == 0L || now - lastDrawPublishNanos >= MIN_DRAW_INTERVAL_NANOS) {
            lastDrawPublishNanos = now
            frameEpoch += 1
        }
        val nextTextureGeometry =
            retainedFeedTextureSourceGeometry(
                current = textureSourceGeometry,
                width = bitmap.width,
                height = bitmap.height,
            )
        if (nextTextureGeometry !== textureSourceGeometry) {
            textureSourceGeometry = nextTextureGeometry
        }
    }

    internal fun clear() {
        if (focusGestureGeometrySignature != null) {
            focusGestureGeometrySignature = null
            focusGestureGeometryGeneration += 1
        }
        latestBitmap = null
        lastDrawPublishNanos = 0L
        frameEpoch += 1
        if (retainedSourceWidth != 0) retainedSourceWidth = 0
        if (retainedSourceHeight != 0) retainedSourceHeight = 0
        if (retainedFocus != null) retainedFocus = null
        if (retainedLevel != null) retainedLevel = null
        textureSourceGeometry = null
        presentedColorMode = LiveFeedColorMode.UNKNOWN
    }

    private companion object {
        /** ~20 fps max Compose feed redraws — leaves headroom for chrome input. */
        const val MIN_DRAW_INTERVAL_NANOS: Long = 50_000_000L
    }
}

private data class FocusGestureGeometrySignature(
    val sourceWidth: Int,
    val sourceHeight: Int,
    val coordinateWidth: Int,
    val coordinateHeight: Int,
)

@Immutable
internal data class FalseColorReferencePresentation(
    val scale: FeedFalseColorScale,
    val reference: FeedFalseColorReference,
)

/** Render-success state consumed by the unscaled sibling reference overlay. */
@Stable
public class LiveFeedEffectsPresentationState {
    internal var falseColorReference: FalseColorReferencePresentation? by mutableStateOf(null)
        private set

    internal fun present(scale: FeedFalseColorScale, reference: FeedFalseColorReference) {
        falseColorReference = FalseColorReferencePresentation(scale, reference)
    }

    internal fun clear() {
        falseColorReference = null
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
 * - **Subsample via [maxLongSide]**: full 1080p texture upload every frame was
 *   janking the UI thread on A12-class (gfxinfo ~50 ms draw). Cap the long
 *   side near display resolution so Skia uploads ~¼ the pixels without
 *   visible quality loss on a phone monitor.
 * - **ImageDecoder**: allocates a fresh (often hardware) bitmap per frame —
 *   25 allocations/s of ~2.7 MB each is pure GC churn with no quality upside
 *   for a monitor feed.
 * - **MediaCodec `video/mjpeg`**: probed at runtime (see the one-shot log in
 *   [LiveFeedView]); no decoder on the SM-A127F and rarely present on any
 *   SoC, so it can only ever be an opportunistic fast path — not worth a
 *   second pipeline for the spike.
 *
 * The ring is 3 deep so the bitmap being decoded into is never the one the
 * RenderThread may still be drawing (current frame + one in flight).
 */
class JpegFrameDecoder(
    /**
     * Maximum long-side pixels for the decoded bitmap. `0` keeps the source
     * resolution; default [DEFAULT_MAX_LONG_SIDE] matches phone feed size.
     */
    private val maxLongSide: Int = DEFAULT_MAX_LONG_SIDE,
) {
    private val pool = arrayOfNulls<Bitmap>(3)
    private var next = 0
    private val options =
        BitmapFactory.Options().apply {
            inMutable = true
            inPreferredConfig = Bitmap.Config.ARGB_8888
            // Keep the JPEG's declared color space intact. Forcing sRGB here
            // would erase wide-gamut/HDR evidence before the fail-closed gate
            // can reject a source the monitor cubes do not yet support.
        }

    /** Decodes [jpeg] into the next pooled bitmap; null if the data is invalid. */
    fun decode(jpeg: ByteArray): Bitmap? {
        options.inSampleSize = 1
        if (maxLongSide > 0) {
            options.inJustDecodeBounds = true
            options.inBitmap = null
            BitmapFactory.decodeByteArray(jpeg, 0, jpeg.size, options)
            options.inSampleSize =
                jpegSampleSizeForLongSide(options.outWidth, options.outHeight, maxLongSide)
            options.inJustDecodeBounds = false
        }
        // Prefer pool reuse; IllegalArgumentException resets the ring slot.
        options.inBitmap = pool[next]
        val decoded =
            try {
                BitmapFactory.decodeByteArray(jpeg, 0, jpeg.size, options)
            } catch (_: IllegalArgumentException) {
                // Pooled bitmap incompatible (size/sample change) — decode fresh.
                options.inBitmap = null
                BitmapFactory.decodeByteArray(jpeg, 0, jpeg.size, options)
            } ?: return null
        pool[next] = decoded
        next = (next + 1) % pool.size
        return decoded
    }

    companion object {
        /**
         * Phone feed long side (≈540p after sample-2 of 1080p). Full 1080p
         * uploads were ~50 ms UI-thread draw on SM-A127F (gfxinfo).
         */
        const val DEFAULT_MAX_LONG_SIDE: Int = 960
    }
}

/** Power-of-two [BitmapFactory.Options.inSampleSize] so long side ≤ [maxLongSide]. */
internal fun jpegSampleSizeForLongSide(width: Int, height: Int, maxLongSide: Int): Int {
    if (maxLongSide <= 0 || width <= 0 || height <= 0) return 1
    val longSide = maxOf(width, height)
    var sample = 1
    // Grow sample until decoded long side is at most maxLongSide.
    while (longSide / sample > maxLongSide) {
        sample *= 2
    }
    return sample
}

/**
 * Renders a [LiveFrameSource] as the monitor feed: decodes off the main
 * thread with latest-wins conflation ([pumpFrames]) and draws the newest
 * frame into the full modifier bounds. [aspectFill] selects the portrait
 * centre-crop path; the default keeps the whole frame visible.
 *
 * The frame state is read inside the [Canvas] draw lambda only, so a new
 * frame costs one draw invalidation — no recomposition, no layout.
 *
 * [onFrame] observes each presented frame on the decode thread — the glass
 * backdrop producer hooks in here ([MonitorGlass.submit]). The bitmap is
 * pooled; it stays valid until two more frames have been decoded.
 * [onPresentedFrame] observes the exact source [LiveFrame], decoded bitmap,
 * and optional [LiveFramePreviewBaker] accepted for display. The
 * phone-mediated Wear relay uses this callback rather than collecting [source]
 * itself, so it cannot keep camera live view running while the monitor is
 * hidden or backgrounded. When image assists are visible, the baker reuses the
 * exact phone shader so the wrist preview is display-baked too.
 * [presentationState], when supplied, retains the same frame's camera
 * metadata and image dimensions for feed-aligned overlays.
 *
 * [effects] bakes the GPU assist chain (LUT / false colour / peaking / zebra)
 * into the drawn frame. The default preserves the plain feed. Presentation:
 * - **FLAT glass / no glass:** graded frames go to a GLES/Vulkan [SurfaceView]
 *   (A12-class path; AGSL live grade janked ~99% frames with LUT).
 * - **FULL liquid glass:** Compose [Canvas] (+ AGSL [FeedEffectsRenderer] when
 *   graded). Kyant `layerBackdrop` only records HWUI/Compose draw commands —
 *   a SurfaceView is a separate buffer and never appears under glass blur.
 * Builds without the staged Swift core, and frames outside original SDR,
 * always render plain.
 * [configuration] is local operator choice only; [cameraInput] is forwarded
 * unchanged to Swift, which owns camera curve/clip policy for both the
 * renderer and the optional false-colour reference key.
 *
 * @param preferComposablePresentation When true (FULL liquid glass), force the
 *   Compose Canvas present path so chrome/popups can blur the live feed.
 */
@Composable
fun LiveFeedView(
    source: LiveFrameSource,
    modifier: Modifier = Modifier,
    onFrame: ((Bitmap) -> Unit)? = null,
    onPresentedFrame: ((LiveFrame, Bitmap, LiveFramePreviewBaker?) -> Unit)? = null,
    presentationState: LiveFeedPresentationState? = null,
    effects: FeedEffects = FeedEffectsState.current,
    configuration: FeedEffectsConfiguration = FeedEffectsConfiguration(),
    cameraInput: ExposureAssistCameraInput = ExposureAssistCameraInput(),
    lutLibrary: AndroidLutLibrary? = null,
    effectsPresentationState: LiveFeedEffectsPresentationState? = null,
    aspectFill: Boolean = false,
    preferComposablePresentation: Boolean = false,
) {
    val applicationContext = LocalContext.current.applicationContext
    val fallbackFrame = remember(source) { mutableStateOf<ImageBitmap?>(null) }
    val fallbackColorMode = remember(source) { mutableStateOf(LiveFeedColorMode.UNKNOWN) }
    // GPU present (Vulkan preferred, GLES fallback) for FLAT glass. FULL glass
    // must stay on Compose Canvas so Kyant can sample the feed.
    val gpuBackend = remember(source) { LiveFeedGpuBackendFactory.create(applicationContext) }
    val lifecycleOwner = LocalLifecycleOwner.current
    val latestPresentedFrame = rememberUpdatedState(onPresentedFrame)
    DisposableEffect(gpuBackend) {
        onDispose { gpuBackend.dispose() }
    }
    DisposableEffect(lifecycleOwner, gpuBackend) {
        val lifecycle = lifecycleOwner.lifecycle
        val observer =
            LifecycleEventObserver { _, event ->
                when (event) {
                    Lifecycle.Event.ON_RESUME -> gpuBackend.resume()
                    Lifecycle.Event.ON_PAUSE,
                    Lifecycle.Event.ON_DESTROY,
                    -> gpuBackend.pause()
                    else -> Unit
                }
            }
        lifecycle.addObserver(observer)
        if (lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)) {
            gpuBackend.resume()
        }
        onDispose {
            lifecycle.removeObserver(observer)
            gpuBackend.pause()
        }
    }
    // Stored selections are prepared off the UI thread. Until the shared Swift parser has produced
    // a packed payload, the renderer remains fail-closed (plain feed), then rebuilds on generation.
    val lutRenderGeneration = lutLibrary?.renderGeneration?.collectAsState()?.value ?: 0L
    LaunchedEffect(lutLibrary, effects.lut) {
        val stored = (effects.lut as? FeedLutSelection.Stored)?.value
        if (stored != null) lutLibrary?.prepare(stored)
    }
    val colorMode = presentationState?.colorMode ?: fallbackColorMode.value
    var renderPlan by remember { mutableStateOf<FeedEffectsRenderPlan?>(null) }
    // Wear / small preview baker only (not the live monitor path).
    var previewBaker by remember { mutableStateOf<LiveFramePreviewBaker?>(null) }
    // AGSL grade for the Compose present path (FULL glass). Mid/high devices
    // only — A12 stays on FLAT + GPU SurfaceView.
    var composableEffectsRenderer by remember { mutableStateOf<FeedEffectsRenderer?>(null) }
    LaunchedEffect(
        effects,
        configuration,
        cameraInput,
        lutLibrary,
        lutRenderGeneration,
        colorMode,
        preferComposablePresentation,
    ) {
        // Never retain a plan for a superseded selection while its
        // replacement is prepared. Cube baking is native/CPU work off UI.
        renderPlan = null
        previewBaker = null
        (composableEffectsRenderer as? AutoCloseable)?.close()
        composableEffectsRenderer = null
        gpuBackend.updatePlan(null, aspectFill)
        if (effects.isIdentity) return@LaunchedEffect
        if (!liveFeedEffectsCanRender(Build.VERSION.SDK_INT, SwiftCore.isAvailable, colorMode)) {
            if (colorMode != LiveFeedColorMode.UNKNOWN) {
                Log.w(TAG, "feed effects unavailable for $colorMode live input; rendering the plain feed")
            }
            return@LaunchedEffect
        }
        val nextPlan =
            withContext(Dispatchers.Default) {
                FeedEffectsRenderPlanFactory.create(
                    effects,
                    configuration,
                    cameraInput,
                    lutLibrary,
                )
            }
        renderPlan = nextPlan
        if (nextPlan != null) {
            if (!preferComposablePresentation) {
                gpuBackend.updatePlan(nextPlan, aspectFill)
            }
            // Small-preview baker for Wear: GLES path reuses the same plan via
            // LegacyFeedEffectsPreviewBaker; AGSL baker is API 33-only fallback.
            previewBaker =
                withContext(Dispatchers.Default) {
                    LegacyFeedEffectsPreviewBaker(applicationContext, nextPlan)
                }
            if (preferComposablePresentation && Build.VERSION.SDK_INT >= 33) {
                composableEffectsRenderer =
                    withContext(Dispatchers.Default) {
                        runCatching { FeedEffectsRenderer.create(nextPlan) }.getOrNull()
                    }
            }
        }
    }
    SideEffect {
        val plan = renderPlan
        if (!preferComposablePresentation && plan != null && !gpuBackend.renderFailed) {
            gpuBackend.updatePlan(plan, aspectFill)
        }
    }
    // SurfaceView is a separate buffer — Kyant layerBackdrop cannot sample it.
    // FULL liquid glass therefore stays on Compose Canvas even when graded.
    val gpuSurfaceActive =
        !preferComposablePresentation &&
            renderPlan != null &&
            !gpuBackend.renderFailed
    val gpuFramesRequested = gpuSurfaceActive
    val latestGpuFramesRequested = rememberUpdatedState(gpuFramesRequested)
    LaunchedEffect(gpuFramesRequested) {
        if (!gpuFramesRequested) gpuBackend.clearFrame()
    }
    val falseColorReady =
        (gpuSurfaceActive || composableEffectsRenderer != null) &&
            renderPlan?.falseColorReady == true
    LaunchedEffect(
        falseColorReady,
        effects.falseColor,
        configuration.falseColorReferenceEnabled,
        cameraInput,
        effectsPresentationState,
    ) {
        effectsPresentationState?.clear()
        val scale = effects.falseColor?.takeIf { configuration.falseColorReferenceEnabled }
        if (falseColorReady && scale != null) {
            val reference = withContext(Dispatchers.Default) { resolveFalseColorReference(scale, cameraInput) }
            if (reference != null) effectsPresentationState?.present(scale, reference)
        }
    }
    val ownedPreviewBaker = previewBaker
    val latestPreviewBaker = rememberUpdatedState(ownedPreviewBaker)
    DisposableEffect(ownedPreviewBaker) {
        onDispose { (ownedPreviewBaker as? AutoCloseable)?.close() }
    }
    val ownedComposableRenderer = composableEffectsRenderer
    DisposableEffect(ownedComposableRenderer) {
        onDispose { (ownedComposableRenderer as? AutoCloseable)?.close() }
    }

    LaunchedEffect(source, presentationState) {
        presentationState?.clear()
        fallbackFrame.value = null
        fallbackColorMode.value = LiveFeedColorMode.UNKNOWN
        gpuBackend.clearFrame()
        if (BuildConfig.DEBUG) {
            Log.d(
                TAG,
                "hardware MJPEG decoder available: ${LiveFeedMjpegHardware.isAvailable()} " +
                    "gpuBackend=${gpuBackend.kind} composablePresent=$preferComposablePresentation",
            )
        }
        // Low-RAM devices (A12 class): slightly smaller decode when assists are
        // active so GPU grade bandwidth stays under the frame budget.
        val lowEnd =
            runCatching {
                val am =
                    applicationContext.getSystemService(Context.ACTIVITY_SERVICE)
                        as android.app.ActivityManager
                val info = android.app.ActivityManager.MemoryInfo().also(am::getMemoryInfo)
                am.isLowRamDevice || info.totalMem < MIN_FULL_GLASS_RAM_BYTES
            }.getOrDefault(false)
        val decoder =
            JpegFrameDecoder(
                maxLongSide =
                    if (lowEnd && !effects.isIdentity) {
                        720
                    } else {
                        JpegFrameDecoder.DEFAULT_MAX_LONG_SIDE
                    },
            )
        val stats = FramePacingStats(log = { if (BuildConfig.DEBUG) Log.d(TAG, it) })
        withContext(Dispatchers.Default) {
            pumpFramesWithSourceFrame(
                frames = source.frames,
                stats = stats,
                decode = decoder::decode,
                present = { sourceFrame, bitmap ->
                    val frameColorMode = decodedLiveFeedColorMode(bitmap)
                    if (presentationState != null) {
                        presentationState.present(sourceFrame, bitmap, frameColorMode)
                    } else {
                        fallbackFrame.value = bitmap.asImageBitmap()
                        fallbackColorMode.value = frameColorMode
                    }
                    if (latestGpuFramesRequested.value &&
                        frameColorMode == LiveFeedColorMode.SDR
                    ) {
                        gpuBackend.submitFrame(bitmap)
                    } else {
                        gpuBackend.clearFrame()
                    }
                    onFrame?.invoke(bitmap)
                    latestPresentedFrame.value?.invoke(
                        sourceFrame,
                        bitmap,
                        latestPreviewBaker.value.takeIf {
                            frameColorMode == LiveFeedColorMode.SDR
                        },
                    )
                },
            )
        }
    }

    if (gpuSurfaceActive) {
        AndroidView(
            factory = { context ->
                gpuBackend.createView(context).also { view ->
                    gpuBackend.attach(view)
                }
            },
            modifier = modifier,
            update = {
                val plan = renderPlan
                if (plan != null) gpuBackend.updatePlan(plan, aspectFill)
            },
            onRelease = { view -> gpuBackend.detach(view) },
        )
    } else {
        // Compose Canvas is what Kyant layerBackdrop records for liquid glass.
        // Graded FULL glass uses AGSL; plain feed is a direct bitmap blit.
        val agslRenderer = composableEffectsRenderer
        Canvas(modifier) {
            val androidBitmap =
                presentationState?.bitmap
                    ?: fallbackFrame.value?.asAndroidBitmap()
                    ?: return@Canvas
            val content =
                liveFeedContentRect(
                    containerWidth = size.width,
                    containerHeight = size.height,
                    sourceWidth = androidBitmap.width,
                    sourceHeight = androidBitmap.height,
                    aspectFill = aspectFill,
                ) ?: return@Canvas
            drawIntoCanvas { canvas ->
                if (agslRenderer != null &&
                    Build.VERSION.SDK_INT >= 33 &&
                    decodedLiveFeedColorMode(androidBitmap) == LiveFeedColorMode.SDR
                ) {
                    agslRenderer.draw(
                        canvas.nativeCanvas,
                        androidBitmap,
                        content.left.toFloat(),
                        content.top.toFloat(),
                        content.width.toFloat(),
                        content.height.toFloat(),
                    )
                } else {
                    val dst =
                        android.graphics.Rect(
                            content.left,
                            content.top,
                            content.left + content.width,
                            content.top + content.height,
                        )
                    canvas.nativeCanvas.drawBitmap(androidBitmap, null, dst, null)
                }
            }
        }
    }
}

/** Visible fail-closed feedback when a future live source is not original SDR. */
@Composable
internal fun LiveFeedColorModeNotice(
    colorMode: LiveFeedColorMode,
    effectsActive: Boolean,
    modifier: Modifier = Modifier,
) {
    if (!effectsActive) return
    val copy =
        when (colorMode) {
            LiveFeedColorMode.HDR -> stringResource(R.string.feed_hdr_assists_off)
            LiveFeedColorMode.UNSUPPORTED -> stringResource(R.string.feed_color_assists_off)
            LiveFeedColorMode.UNKNOWN,
            LiveFeedColorMode.SDR,
            -> return
        }
    Box(
        modifier
            .glass(ChromeShape)
            .semantics { contentDescription = copy.lowercase() }
            .padding(horizontal = 10.dp, vertical = 6.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            text = copy,
            style = chromeStyle(9f, androidx.compose.ui.text.font.FontWeight.Bold, mono = true),
            color = LiveDesign.accent,
        )
    }
}

/**
 * Unscaled sibling of [LiveFeedView]. Keeping the reference outside the feed's
 * de-squeeze graphics layer preserves its 264×52 iOS footprint and typography.
 */
@Composable
internal fun FalseColorReferenceOverlay(
    effectsState: LiveFeedEffectsPresentationState,
    feed: ZoneFrame,
    viewport: ZoneFrame,
    modifier: Modifier = Modifier,
    placementStoreName: String = FalseColorReferencePlacementStore.STORE_NAME,
    bottomChromeClearance: Float = FALSE_COLOR_REFERENCE_BOTTOM_CLEARANCE,
    defaultHorizontalFraction: Float = 0f,
    panelLayout: MonitorAnalysisPanelLayout? = null,
    placementStore: MonitorAnalysisPanelPlacementStore? = null,
    placementRevision: Int = 0,
    hapticsEnabled: Boolean = true,
    onPanelFrameChanged: (MonitorAnalysisPanelID, ZoneFrame?) -> Unit = { _, _ -> },
) {
    val presentation = effectsState.falseColorReference ?: return
    val resolvedLayout =
        panelLayout ?: MonitorAnalysisPanelLayout(viewport = viewport, safeBounds = viewport)
    val default =
        remember(feed, resolvedLayout, bottomChromeClearance, defaultHorizontalFraction) {
            controlSafeFalseColorReferenceDefaultFrame(
                feed = feed,
                layout = resolvedLayout,
                bottomChromeClearance = bottomChromeClearance,
                horizontalFraction = defaultHorizontalFraction,
            )
        }
    val context = LocalContext.current.applicationContext
    val legacyStore =
        remember(context, placementStoreName, placementStore) {
            placementStore?.let { null }
                ?: FalseColorReferencePlacementStore(context, placementStoreName)
        }
    val panelID = MonitorAnalysisPanelID.FALSE_COLOR_REFERENCE
    fun resolvedFrame(): ZoneFrame =
        placementStore?.resolve(panelID, default, resolvedLayout)
            ?: requireNotNull(legacyStore).resolve(default, resolvedLayout.safeBounds)

    fun saveFrame(frame: ZoneFrame) {
        if (placementStore != null) {
            placementStore.save(panelID, frame, resolvedLayout)
        } else {
            requireNotNull(legacyStore).save(frame, resolvedLayout.safeBounds)
        }
    }
    var frame by
        remember(default, resolvedLayout, placementRevision) {
            mutableStateOf(resolvedFrame())
        }
    val currentFrameCallback by rememberUpdatedState(onPanelFrameChanged)
    SideEffect { currentFrameCallback(panelID, frame) }
    DisposableEffect(panelID) {
        onDispose { currentFrameCallback(panelID, null) }
    }
    var hapticCell by remember { mutableIntStateOf(Int.MIN_VALUE) }
    val density = LocalDensity.current
    val view = LocalView.current
    val referenceDescription = stringResource(R.string.false_color_reference_description)
    val recenterDescription = stringResource(R.string.false_color_recenter_description)
    val copy =
        FalseColorReferenceCopy(
            title = stringResource(R.string.false_color_title),
            scale = stringResource(presentation.scale.labelResource()),
            stopLabels =
                listOf(
                    stringResource(R.string.false_color_axis_min),
                    stringResource(R.string.false_color_axis_minus_three),
                    stringResource(R.string.false_color_axis_middle_gray),
                    stringResource(R.string.false_color_axis_skin),
                    stringResource(R.string.false_color_axis_plus_two),
                    stringResource(R.string.false_color_axis_max),
                ),
            ireLabels =
                listOf(
                    stringResource(R.string.false_color_axis_clip_shadows),
                    stringResource(R.string.false_color_axis_middle_gray),
                    stringResource(R.string.false_color_axis_skin_high),
                    stringResource(R.string.false_color_axis_highlights_clip),
                ),
            limitsLabels =
                listOf(
                    stringResource(R.string.false_color_axis_crushed),
                    stringResource(R.string.false_color_axis_midtones),
                    stringResource(R.string.false_color_axis_clipped),
                ),
        )
    Canvas(
        modifier
            .zone(frame)
            .glass(ChromeShape)
            .semantics {
                contentDescription = referenceDescription
                if (placementStore != null) {
                    customActions =
                        listOf(
                            CustomAccessibilityAction(recenterDescription) {
                                placementStore.recenter(panelID)
                                frame = clampScopeFrame(default, resolvedLayout.safeBounds)
                                true
                            },
                        )
                }
            }
            .pointerInput(default, resolvedLayout, placementRevision, hapticsEnabled) {
                detectDragGesturesAfterLongPress(
                    onDragStart = {
                        if (hapticsEnabled) {
                            view.performHapticFeedback(HapticFeedbackConstants.LONG_PRESS)
                        }
                    },
                    onDragEnd = { saveFrame(frame) },
                ) { change, dragAmount ->
                    change.consume()
                    val snapped =
                        clampScopeFrame(
                            snapFalseColorReferenceFrame(
                                frame.copy(
                                    x = frame.x + dragAmount.x / density.density,
                                    y = frame.y + dragAmount.y / density.density,
                                ),
                            ),
                            resolvedLayout.safeBounds,
                        )
                    val cell =
                        ((snapped.x + snapped.width / 2f) / 22f).roundToInt() * 100_000 +
                            ((snapped.y + snapped.height / 2f) / 22f).roundToInt()
                    if (cell != hapticCell) {
                        hapticCell = cell
                        if (hapticsEnabled) {
                            view.performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP)
                        }
                    }
                    frame = snapped
                }
            },
    ) {
        drawFalseColorReference(presentation, copy)
    }
}

/** Preserves the established viewport-relative anchor, then applies control clearance exactly once. */
internal fun controlSafeFalseColorReferenceDefaultFrame(
    feed: ZoneFrame,
    layout: MonitorAnalysisPanelLayout,
    bottomChromeClearance: Float = FALSE_COLOR_REFERENCE_BOTTOM_CLEARANCE,
    horizontalFraction: Float = 0f,
): ZoneFrame =
    clampScopeFrame(
        falseColorReferenceDefaultFrame(
            feed = feed,
            viewport = layout.viewport,
            bottomChromeClearance = bottomChromeClearance,
            horizontalFraction = horizontalFraction,
        ),
        layout.safeBounds,
    )

/** iOS `feedOutsideCenter(.bottomLeading)` translated into the Android zone map. */
internal fun falseColorReferenceDefaultFrame(
    feed: ZoneFrame,
    viewport: ZoneFrame,
    bottomChromeClearance: Float = FALSE_COLOR_REFERENCE_BOTTOM_CLEARANCE,
    horizontalFraction: Float = 0f,
): ZoneFrame {
    val feedBottom = feed.y + feed.height
    val outsideTop = feedBottom + FALSE_COLOR_REFERENCE_GAP
    val viewportBottom = viewport.y + viewport.height
    val top =
        if (outsideTop + FALSE_COLOR_REFERENCE_HEIGHT <= viewportBottom) {
            outsideTop
        } else {
            min(
                feedBottom,
                viewportBottom - bottomChromeClearance.coerceAtLeast(0f),
            ) - FALSE_COLOR_REFERENCE_GAP - FALSE_COLOR_REFERENCE_HEIGHT
        }
    return clampScopeFrame(
        ZoneFrame(
            x =
                feed.x +
                    maxOf(0f, feed.width - min(FALSE_COLOR_REFERENCE_WIDTH, feed.width)) *
                    horizontalFraction.coerceIn(0f, 1f),
            y = top,
            width = min(FALSE_COLOR_REFERENCE_WIDTH, feed.width),
            height = FALSE_COLOR_REFERENCE_HEIGHT,
        ),
        viewport,
    )
}

/** Mirrors iOS `MovablePanel`'s fine 4-point position grid. */
internal fun snapFalseColorReferenceFrame(frame: ZoneFrame): ZoneFrame =
    frame.copy(
        x = (frame.x / 4f).roundToInt() * 4f,
        y = (frame.y / 4f).roundToInt() * 4f,
    )

/** Persists the normalized centre used by iOS's `MovablePanel(id: "fcref")`. */
private class FalseColorReferencePlacementStore(context: Context, name: String) {
    private val preferences = context.getSharedPreferences(name, Context.MODE_PRIVATE)

    fun resolve(default: ZoneFrame, bounds: ZoneFrame): ZoneFrame {
        if (!preferences.contains(CENTER_X_KEY) || !preferences.contains(CENTER_Y_KEY)) return default
        val normalizedX = preferences.getFloat(CENTER_X_KEY, 0.5f)
        val normalizedY = preferences.getFloat(CENTER_Y_KEY, 0.5f)
        if (!normalizedX.isFinite() || !normalizedY.isFinite()) return default
        return clampScopeFrame(
            default.copy(
                x = bounds.x + normalizedX * bounds.width - default.width / 2f,
                y = bounds.y + normalizedY * bounds.height - default.height / 2f,
            ),
            bounds,
        )
    }

    fun save(frame: ZoneFrame, bounds: ZoneFrame) {
        val centerX = (frame.x + frame.width / 2f - bounds.x) / maxOf(1f, bounds.width)
        val centerY = (frame.y + frame.height / 2f - bounds.y) / maxOf(1f, bounds.height)
        preferences.edit()
            .putFloat(CENTER_X_KEY, centerX.coerceIn(0f, 1f))
            .putFloat(CENTER_Y_KEY, centerY.coerceIn(0f, 1f))
            .apply()
    }

    companion object {
        const val STORE_NAME = "falseColorReferencePlacement"
        const val CENTER_X_KEY = "fcref.centerX"
        const val CENTER_Y_KEY = "fcref.centerY"
    }
}

/** Draws the Swift-derived palette geometry and camera-aware reference axis. */
private data class FalseColorReferenceCopy(
    val title: String,
    val scale: String,
    val stopLabels: List<String>,
    val ireLabels: List<String>,
    val limitsLabels: List<String>,
)

@androidx.annotation.StringRes
internal fun FeedFalseColorScale.labelResource(): Int =
    when (this) {
        FeedFalseColorScale.STOPS -> R.string.false_color_scale_stops
        FeedFalseColorScale.IRE -> R.string.false_color_scale_ire
        FeedFalseColorScale.LIMITS -> R.string.false_color_scale_limits
    }

private fun androidx.compose.ui.graphics.drawscope.DrawScope.drawFalseColorReference(
    presentation: FalseColorReferencePresentation,
    copy: FalseColorReferenceCopy,
) {
    val reference = presentation.reference
    if (reference.segments.isEmpty()) return
    val panelWidth = size.width
    val panelHeight = size.height
    if (panelWidth < 120.dp.toPx() || panelHeight < 38.dp.toPx()) return
    val left = 0f
    val top = 0f
    val padding = 7.dp.toPx()
    val barLeft = left + padding
    val barTop = top + 21.dp.toPx()
    val barWidth = panelWidth - padding * 2
    val barHeight = 8.dp.toPx()
    val neutral =
        if (presentation.scale == FeedFalseColorScale.STOPS) {
            listOf(Color(0.04f, 0.04f, 0.04f), Color(0.86f, 0.86f, 0.86f))
        } else {
            listOf(Color(0.54f, 0.54f, 0.54f), Color(0.75f, 0.75f, 0.75f))
        }
    clipRect(barLeft, barTop, barLeft + barWidth, barTop + barHeight) {
        drawRect(
            brush = Brush.horizontalGradient(neutral, startX = barLeft, endX = barLeft + barWidth),
            topLeft = Offset(barLeft, barTop),
            size = Size(barWidth, barHeight),
        )
        reference.segments.forEach { segment ->
            drawRect(
                color = Color(segment.color[0], segment.color[1], segment.color[2]),
                topLeft = Offset(barLeft + barWidth * segment.lowerFraction, barTop),
                size = Size(maxOf(1f, barWidth * (segment.upperFraction - segment.lowerFraction)), barHeight),
            )
        }
    }
    drawIntoCanvas { canvas ->
        val paint = android.graphics.Paint(android.graphics.Paint.ANTI_ALIAS_FLAG).apply {
            typeface = android.graphics.Typeface.create(android.graphics.Typeface.MONOSPACE, android.graphics.Typeface.NORMAL)
        }
        paint.color = LiveDesign.text.toArgb()
        paint.textSize = 8.5.dp.toPx()
        paint.typeface = android.graphics.Typeface.create(android.graphics.Typeface.MONOSPACE, android.graphics.Typeface.BOLD)
        paint.textAlign = android.graphics.Paint.Align.LEFT
        canvas.nativeCanvas.drawText(copy.title, barLeft, top + 13.dp.toPx(), paint)
        paint.color = LiveDesign.muted.toArgb()
        paint.textSize = 7.5.dp.toPx()
        paint.typeface = android.graphics.Typeface.create(android.graphics.Typeface.MONOSPACE, android.graphics.Typeface.NORMAL)
        paint.textAlign = android.graphics.Paint.Align.RIGHT
        val curve = if (reference.curveOrdinal == 0) "L3G10" else "N-Log"
        canvas.nativeCanvas.drawText("${copy.scale} · $curve", left + panelWidth - padding, top + 13.dp.toPx(), paint)

        paint.textSize = 5.5.dp.toPx()
        paint.textAlign = android.graphics.Paint.Align.CENTER
        val labels: List<Pair<String, Float>> =
            if (presentation.scale == FeedFalseColorScale.STOPS) {
                copy.stopLabels.zip(reference.stopMarkerFractions.toList())
            } else {
                val axis =
                    if (presentation.scale == FeedFalseColorScale.IRE) {
                        copy.ireLabels
                    } else {
                        copy.limitsLabels
                    }
                axis.mapIndexed { index, label -> label to index.toFloat() / (axis.size - 1) }
            }
        labels.forEach { (label, fraction) ->
            val x = (barLeft + barWidth * fraction).coerceIn(barLeft + 8.dp.toPx(), barLeft + barWidth - 8.dp.toPx())
            canvas.nativeCanvas.drawText(label, x, top + 44.dp.toPx(), paint)
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

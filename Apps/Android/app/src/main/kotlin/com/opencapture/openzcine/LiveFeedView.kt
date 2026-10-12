package com.opencapture.openzcine

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import com.opencapture.opencine.runtime.MonitorJpegFrameDecoder
import com.opencapture.opencine.runtime.MonitorBitmapPreviewBaker
import com.opencapture.opencine.runtime.MonitorFrameDecodeWorker
import com.opencapture.opencine.runtime.MonitorFramePacingStats
import com.opencapture.opencine.runtime.monitorPumpFramesWithSourceFrame
import android.os.Build
import android.util.Log
import androidx.compose.foundation.Canvas
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
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.graphics.drawscope.drawIntoCanvas
import androidx.compose.ui.graphics.drawscope.scale
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.opencapture.monitorui.MonitorFalseColorReference
import com.opencapture.monitorui.MonitorMaterial
import com.opencapture.monitorui.monitorMaterial
import com.opencapture.opencine.cameracontrols.FalseColorReference as CommonFalseColorReference
import com.opencapture.monitorui.MonitorFalseColorReferenceMarker
import com.opencapture.monitorui.MonitorFalseColorReferenceSegment
import com.opencapture.monitorui.MonitorFalseColorReferenceValues
import com.opencapture.monitorui.MonitorRect
import com.opencapture.monitorui.MonitorScopePanelSize
import com.opencapture.monitorui.MonitorScopeStoredCenter
import com.opencapture.openzcine.bridge.SwiftCore
import com.opencapture.opencine.nikon.LiveCameraLevel
import com.opencapture.opencine.nikon.LiveFocusInfo
import com.opencapture.opencine.nikon.LiveFrame
import com.opencapture.opencine.nikon.LiveFrameSource
import com.opencapture.openzcine.lut.AndroidLutLibrary
import kotlin.math.min
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import com.opencapture.opencine.runtime.nativeFeedContentRect

private const val TAG = "ZCLiveFeed"

/**
 * Paint for the feed blit. A null Paint means NO filtering: Android samples nearest-neighbour, so
 * the live-view frame — 1024x576 at the Quality preset — arrives on a 1080p panel as hard pixel
 * blocks and reads as roughly half the resolution it is.
 *
 * `isFilterBitmap` turns that into a bilinear reconstruction, and `isDither` breaks up the banding
 * an 8-bit gradient shows once it is stretched. This is the floor, not iOS parity: iOS
 * reconstructs the same frame with MetalFX Spatial over a Lanczos fallback, which resolves finer
 * detail than bilinear can.
 *
 * Lazy on purpose: `Paint` is a stubbed framework class on the local JVM, so building it at file
 * initialisation makes every unit test that touches anything in this file fail to load the class.
 * Deferring to first draw keeps it off the test path entirely.
 */
private val feedBlitPaint: android.graphics.Paint by lazy {
    android.graphics.Paint().apply {
        isFilterBitmap = true
        isDither = true
    }
}

private const val FALSE_COLOR_REFERENCE_WIDTH = 264f
private const val FALSE_COLOR_REFERENCE_HEIGHT = 52f
private const val FALSE_COLOR_REFERENCE_GAP = 10f
private const val FALSE_COLOR_REFERENCE_BOTTOM_CLEARANCE = 14f + LiveDesign.CONTROL_HEIGHT_DP

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
    private var presentedColorMode: LiveFeedColorMode by mutableStateOf(LiveFeedColorMode.UNKNOWN)
    private var focusGestureGeometrySignature: FocusGestureGeometrySignature? = null
    private var retainedSourceWidth by mutableIntStateOf(0)
    private var retainedSourceHeight by mutableIntStateOf(0)
    private var retainedFocus: LiveFocusInfo? by mutableStateOf(null)
    private var retainedLevel: LiveCameraLevel? by mutableStateOf(null)

    /** Changes only when source or camera focus-coordinate geometry changes. */
    internal var focusGestureGeometryGeneration: Long by mutableLongStateOf(0L)
        private set

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
        // Every delivered frame is drawn. The camera's pull rate is the only limiter, which is
        // what makes the feed as smooth as the body allows.
        //
        // This used to gate on `elapsed >= 50ms` to hold redraws near 20 Hz. An elapsed-time gate
        // against a fixed-period source cannot land on an arbitrary target — it only ever passes
        // one frame in N. Against a 40 ms (25 fps) stream the 50 ms gate skipped every second
        // frame and ran at 12.5 fps; against 30 fps it ran at 15. It cost far more than the ~20 it
        // claimed to keep. Same aliasing that silently halved the iOS feed in 4ae1544.
        frameEpoch += 1
    }

    internal fun clear() {
        if (focusGestureGeometrySignature != null) {
            focusGestureGeometrySignature = null
            focusGestureGeometryGeneration += 1
        }
        latestBitmap = null
        frameEpoch += 1
        if (retainedSourceWidth != 0) retainedSourceWidth = 0
        if (retainedSourceHeight != 0) retainedSourceHeight = 0
        if (retainedFocus != null) retainedFocus = null
        if (retainedLevel != null) retainedLevel = null
        presentedColorMode = LiveFeedColorMode.UNKNOWN
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
    val read709: Boolean = false,
)

/** Render-success state consumed by the unscaled sibling reference overlay. */
@Stable
public class LiveFeedEffectsPresentationState {
    internal var falseColorReference: FalseColorReferencePresentation? by mutableStateOf(null)
        private set

    internal fun present(scale: FeedFalseColorScale, reference: FeedFalseColorReference, read709: Boolean = false) {
        falseColorReference = FalseColorReferencePresentation(scale, reference, read709)
    }

    internal fun clear() {
        falseColorReference = null
    }
}

/**
 * The live-view JPEG decode cap, for the shared ring decoder
 * ([com.opencapture.opencine.runtime.MonitorJpegFrameDecoder]).
 *
 * Decode-path decision (OPE-28 spike), measured on the SM-A127F floor device:
 * - **Chosen: [BitmapFactory.decodeByteArray] + `inBitmap` reuse.** After the
 *   ring fills, the steady state is zero per-frame allocation — the JPEG is
 *   decoded straight into an existing buffer. Sustains the 25 fps stream with
 *   ~2/3 of the frame budget idle on the test device.
 * - **Subsample via the long-side cap**: full 1080p texture upload every frame was
 *   janking the UI thread on A12-class (gfxinfo ~50 ms draw), so the long side
 *   is capped. That cap was 960 against a 1080p source; against the **1024**-wide
 *   live-view frame it quietly cost a factor of four. `inSampleSize` is
 *   power-of-two, so a source only 6.7% over the cap does not shrink by 6.7% —
 *   it halves, and 1024×576 decoded to 512×288 then gets upscaled ~4.6× to the
 *   panel, turning every 8×8 JPEG block into a ~37 px slab. That is most of the
 *   "cheap JPEG" look on Android, and it applied to every device: the low-end
 *   branch (720) and the default (960) both resolved to sample=2 at this width.
 *   The cap now sits at the feed's own width so the common case decodes 1:1,
 *   while anything genuinely larger is still bounded.
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
const val LIVE_FEED_MAX_LONG_SIDE: Int = 1024

/**
 * Renders a [LiveFrameSource] as the monitor feed: decodes off the main
 * thread with latest-wins conflation ([monitorPumpFramesWithSourceFrame]) and draws the newest
 * frame into the full modifier bounds. [aspectFill] selects the portrait
 * centre-crop path; the default keeps the whole frame visible.
 *
 * The frame state is read inside the [Canvas] draw lambda only, so a new
 * frame costs one draw invalidation — no recomposition, no layout.
 *
 * [onFrame] observes each presented frame on the decode thread. The bitmap is
 * pooled; it stays valid until two more frames have been decoded.
 * [onPresentedFrame] observes the exact source [LiveFrame], decoded bitmap,
 * optional [MonitorBitmapPreviewBaker] and live look accepted for display; the
 * shared material's backdrop samples the picture there. The
 * phone-mediated Wear relay uses this callback rather than collecting [source]
 * itself, so it cannot keep camera live view running while the monitor is
 * hidden or backgrounded. When image assists are visible, the baker reuses the
 * exact phone shader so the wrist preview is display-baked too.
 * [presentationState], when supplied, retains the same frame's camera
 * metadata and image dimensions for feed-aligned overlays.
 *
 * [effects] bakes the GPU assist chain (LUT / false colour / peaking / zebra)
 * into the drawn frame. The default preserves the plain feed. Presentation:
 * graded frames go to a GLES/Vulkan [SurfaceView] (A12-class path; AGSL live
 * grade janked ~99% frames with LUT); [preferComposablePresentation] keeps
 * them on a Compose [Canvas] (+ AGSL [FeedEffectsRenderer]).
 * Builds without the staged Swift core, and frames outside original SDR,
 * always render plain.
 * [configuration] is local operator choice only; [cameraInput] is forwarded
 * unchanged to Swift, which owns camera curve/clip policy for both the
 * renderer and the optional false-colour reference key.
 *
 * @param preferComposablePresentation When true (a rotated vertical feed), force
 *   the Compose Canvas present path: SurfaceView buffers never rotate with Compose.
 */
@Composable
internal fun LiveFeedView(
    source: LiveFrameSource,
    modifier: Modifier = Modifier,
    onFrame: ((Bitmap) -> Unit)? = null,
    onPresentedFrame: ((LiveFrame, Bitmap, MonitorBitmapPreviewBaker?, com.opencapture.opencine.media.FeedEffectsRenderPlan?) -> Unit)? = null,
    incidentObserver: com.opencapture.openzcine.diagnostics.NikonFeedIncidentProducer? = null,
    presentationState: LiveFeedPresentationState? = null,
    effects: FeedEffects,
    configuration: FeedEffectsConfiguration = FeedEffectsConfiguration(),
    cameraInput: ExposureAssistCameraInput = ExposureAssistCameraInput(),
    lutLibrary: AndroidLutLibrary? = null,
    effectsPresentationState: LiveFeedEffectsPresentationState? = null,
    aspectFill: Boolean = false,
    /**
     * Flips the picture left-to-right, for a camera pointed back at the person watching it. A
     * display transform only: the recording, the scopes, and every camera-reported coordinate stay
     * in the true orientation (iOS `MonitorAssistTool.mirror`).
     */
    mirrored: Boolean = false,
    preferComposablePresentation: Boolean = false,
    /** Pauses acquisition without replacing the retained native picture host or held raster. */
    collectFrames: Boolean = true,
    /** Vertical display transform; raw frame publication remains in source orientation. */
    mirroredVertical: Boolean = false,
) {
    val applicationContext = LocalContext.current.applicationContext
    val fallbackFrame = remember(source) { mutableStateOf<ImageBitmap?>(null) }
    val fallbackColorMode = remember(source) { mutableStateOf(LiveFeedColorMode.UNKNOWN) }
    // GPU present (Vulkan preferred, GLES fallback); a rotated feed stays on Compose Canvas.
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
    var previewBaker by remember { mutableStateOf<MonitorBitmapPreviewBaker?>(null) }
    // AGSL grade for the Compose present path (a rotated vertical feed), API 33+.
    var composableEffectsRenderer by remember { mutableStateOf<FeedEffectsRenderer?>(null) }
    LaunchedEffect(
        effects,
        configuration,
        cameraInput,
        lutLibrary,
        lutRenderGeneration,
        colorMode,
        preferComposablePresentation,
        aspectFill,
    ) {
        // Keep the *current* plan on screen while the next one bakes. Clearing
        // plan / SurfaceView mid-toggle was the black flash on LUT/peak/zebra.
        if (
            !effects.isIdentity &&
                !liveFeedEffectsCanRender(Build.VERSION.SDK_INT, SwiftCore.isAvailable, colorMode)
        ) {
            if (colorMode != LiveFeedColorMode.UNKNOWN) {
                Log.w(TAG, "feed effects unavailable for $colorMode live input; rendering the plain feed")
            }
            return@LaunchedEffect
        }
        if (!SwiftCore.isAvailable) return@LaunchedEffect
        val previousBaker = previewBaker
        val previousComposable = composableEffectsRenderer
        val nextPlan =
            withContext(Dispatchers.Default) {
                FeedEffectsRenderPlanFactory.create(
                    effects,
                    configuration,
                    cameraInput,
                    lutLibrary,
                )
            }
        if (nextPlan == null) return@LaunchedEffect
        // Atomic present-path swap: push GPU uniforms first, then Compose state.
        if (!preferComposablePresentation) {
            gpuBackend.updatePlan(nextPlan, aspectFill, mirrored, mirroredVertical)
        }
        renderPlan = nextPlan
        val nextBaker =
            withContext(Dispatchers.Default) {
                LegacyFeedEffectsPreviewBaker(applicationContext, nextPlan)
            }
        previewBaker = nextBaker
        if (previousBaker !== nextBaker) {
            (previousBaker as? AutoCloseable)?.close()
        }
        if (preferComposablePresentation && Build.VERSION.SDK_INT >= 33) {
            val nextComposable =
                withContext(Dispatchers.Default) {
                    runCatching { FeedEffectsRenderer.create(nextPlan) }.getOrNull()
                }
            composableEffectsRenderer = nextComposable
            if (previousComposable !== nextComposable) {
                (previousComposable as? AutoCloseable)?.close()
            }
        } else if (composableEffectsRenderer != null) {
            (composableEffectsRenderer as? AutoCloseable)?.close()
            composableEffectsRenderer = null
        }
    }
    SideEffect {
        val plan = renderPlan
        if (!preferComposablePresentation && plan != null && !gpuBackend.renderFailed) {
            gpuBackend.updatePlan(plan, aspectFill, mirrored, mirroredVertical)
        }
    }
    // Keep the GPU surface mounted whenever the Swift core can grade so toggles
    // never remount AndroidView (another source of flash).
    val gpuSurfaceActive =
        !preferComposablePresentation &&
            SwiftCore.isAvailable &&
            !gpuBackend.renderFailed &&
            renderPlan != null
    val gpuFramesRequested = gpuSurfaceActive
    val latestGpuFramesRequested = rememberUpdatedState(gpuFramesRequested)
    // Do not clearFrame when the surface briefly becomes inactive — that blacked
    // the swapchain between effect plans. Source teardown clears explicitly.
    val falseColorReady =
        (gpuSurfaceActive || composableEffectsRenderer != null) &&
            renderPlan?.falseColorReady == true
    LaunchedEffect(
        falseColorReady,
        effects.falseColor,
        configuration.falseColorReferenceEnabled,
        effects.falseColorRec709,
        cameraInput,
        effectsPresentationState,
    ) {
        effectsPresentationState?.clear()
        val scale = effects.falseColor?.takeIf { configuration.falseColorReferenceEnabled }
        if (falseColorReady && scale != null) {
            val reference = withContext(Dispatchers.Default) { resolveFalseColorReference(scale, cameraInput, read709 = effects.falseColorRec709) }
            if (reference != null) effectsPresentationState?.present(scale, reference, effects.falseColorRec709)
        }
    }
    val ownedPreviewBaker = previewBaker
    val latestPreviewBaker = rememberUpdatedState(ownedPreviewBaker)
    val latestRenderPlan = rememberUpdatedState(renderPlan)
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
    }
    LaunchedEffect(source, presentationState, collectFrames, incidentObserver) {
        if (!collectFrames) return@LaunchedEffect
        if (BuildConfig.DEBUG) {
            Log.d(
                TAG,
                "gpuBackend=${gpuBackend.kind} composablePresent=$preferComposablePresentation",
            )
        }
        // Always decode the frame at its native size.
        //
        // Low-RAM devices used to drop to a 720 cap whenever an assist was active, described as a
        // "slightly smaller decode". `inSampleSize` is power-of-two, so against the 1024-wide
        // live-view frame there is no slightly: 720 resolves to sample=2 and decodes 512x288 —
        // quarter resolution, stretched back over the whole panel. That is what read as "half the
        // resolution of iOS" on the A12, and it was invisible in the relay, which encodes the
        // source frame and so looked correct on the receiving device.
        //
        // The same power-of-two trap already cost this path once, when a 960 cap carried over from
        // a 1080p source halved every frame on every device.
        val decoder = MonitorJpegFrameDecoder(maxLongSide = LIVE_FEED_MAX_LONG_SIDE)
        val stats = MonitorFramePacingStats(log = { if (BuildConfig.DEBUG) Log.d(TAG, it) })
        // Capture the connection observer once. A successor callback must not retag old work.
        val incident = incidentObserver.takeIf { source is com.opencapture.opencine.nikon.SwiftCoreLiveFrameSource }
        val frames = if (incident != null && source is com.opencapture.opencine.nikon.SwiftCoreLiveFrameSource)
            source.currentStreamFrames else source.frames
        val decodeWorker = MonitorFrameDecodeWorker("zc-feed-decode")
        try {
            decodeWorker.run { isCurrent ->
            monitorPumpFramesWithSourceFrame(
                frames = frames,
                stats = stats,
                timestampNanos = { it.timestampNanos },
                isCurrent = isCurrent,
                // An HDMI capture frame arrives already decoded; everything
                // else is the camera's live-view JPEG.
                decode = { frame ->
                    if (incident != null) incident.decode { decoder.decode(frame.jpegData) }
                    else (frame as? BitmapLiveFrame)?.bitmap ?: decoder.decode(frame.jpegData)
                },
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
                    incident?.published()
                    onFrame?.invoke(bitmap)
                    latestPresentedFrame.value?.invoke(
                        sourceFrame,
                        bitmap,
                        latestPreviewBaker.value.takeIf {
                            frameColorMode == LiveFeedColorMode.SDR
                        },
                        latestRenderPlan.value?.nativePlan,
                    )
                },
            )
            }
        } finally {
            decodeWorker.close()
        }
    }

    if (gpuSurfaceActive) {
        AndroidView(
            factory = { context ->
                gpuBackend.createView(context).also { view ->
                    view.tag = "monitor.native.picture"
                    gpuBackend.attach(view)
                }
            },
            modifier = modifier,
            update = {
                val plan = renderPlan
                if (plan != null) gpuBackend.updatePlan(plan, aspectFill, mirrored, mirroredVertical)
            },
            onRelease = { view -> gpuBackend.detach(view) },
        )
    } else {
        // Graded composable presentation uses AGSL; plain feed is a direct bitmap blit.
        val agslRenderer = composableEffectsRenderer
        Canvas(modifier) {
            val androidBitmap =
                presentationState?.bitmap
                    ?: fallbackFrame.value?.asAndroidBitmap()
                    ?: return@Canvas
            val content =
                nativeFeedContentRect(
                    containerWidth = size.width,
                    containerHeight = size.height,
                    sourceWidth = androidBitmap.width,
                    sourceHeight = androidBitmap.height,
                    aspectFill = aspectFill,
                ) ?: return@Canvas
            // The Compose path mirrors with a scale about the picture's own centre — the same flip
            // the two GPU backends do by folding their sampling coordinate. Each renderer applies
            // it itself because a SurfaceView cannot be transformed from Compose.
            val pivot =
                Offset(
                    content.left + content.width / 2f,
                    content.top + content.height / 2f,
                )
            val paintFeed: DrawScope.() -> Unit = {
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
                    canvas.nativeCanvas.drawBitmap(androidBitmap, null, dst, feedBlitPaint)
                    }
                }
            }
            if (mirrored || mirroredVertical) {
                scale(scaleX = if (mirrored) -1f else 1f,
                    scaleY = if (mirroredVertical) -1f else 1f, pivot = pivot) { paintFeed() }
            } else {
                paintFeed()
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
            .monitorMaterial(MonitorMaterial.Compact, ChromeShape)
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
 * The false-colour key on the shared movable panel and ruler. The Swift-calibrated bands, stop
 * markers and curve name arrive as the shared reference values; [stored] and [onStore] keep its
 * centre (live: the shared assist state; playback: its own preference file). Unscaled sibling of
 * [LiveFeedView], outside the feed's de-squeeze layer.
 */
@Composable
internal fun FalseColorReferenceOverlay(
    effectsState: LiveFeedEffectsPresentationState,
    feed: MonitorRect,
    panelLayout: MonitorAnalysisPanelLayout,
    stored: MonitorScopeStoredCenter?,
    onStore: (MonitorScopeStoredCenter) -> Unit,
    bottomChromeClearance: Float = FALSE_COLOR_REFERENCE_BOTTOM_CLEARANCE,
    defaultHorizontalFraction: Float = 0f,
    hapticsEnabled: Boolean = true,
    onPanelFrameChanged: (MonitorAnalysisPanelID, MonitorRect?) -> Unit = { _, _ -> },
) {
    val presentation = effectsState.falseColorReference ?: return
    if (presentation.reference.segments.isEmpty()) return
    val default =
        remember(feed, panelLayout, bottomChromeClearance, defaultHorizontalFraction) {
            controlSafeFalseColorReferenceDefaultFrame(
                feed = feed,
                layout = panelLayout,
                bottomChromeClearance = bottomChromeClearance,
                horizontalFraction = defaultHorizontalFraction,
            )
        }
    val description = stringResource(R.string.false_color_reference_description)
    val values = presentation.referenceValues(falseColorReferenceCopy(presentation.scale))
    MovableMonitorPanel(
        identity = MonitorAnalysisPanelID.FALSE_COLOR_REFERENCE.storageKey,
        base = MonitorScopePanelSize.falseColorReference,
        panelLayout = panelLayout,
        stored = stored,
        onStore = onStore,
        hapticsEnabled = hapticsEnabled,
        panelID = MonitorAnalysisPanelID.FALSE_COLOR_REFERENCE,
        onPanelFrameChanged = onPanelFrameChanged,
        defaultFrame = default,
        // The shared ruler draws its own plate.
        fillPlate = false,
    ) { modifier ->
        MonitorFalseColorReference(values, modifier.semantics { contentDescription = description })
    }
}


/** Preserves the established viewport-relative anchor, then applies control clearance exactly once. */
internal fun controlSafeFalseColorReferenceDefaultFrame(
    feed: MonitorRect,
    layout: MonitorAnalysisPanelLayout,
    bottomChromeClearance: Float = FALSE_COLOR_REFERENCE_BOTTOM_CLEARANCE,
    horizontalFraction: Float = 0f,
): MonitorRect =
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
    feed: MonitorRect,
    viewport: MonitorRect,
    bottomChromeClearance: Float = FALSE_COLOR_REFERENCE_BOTTOM_CLEARANCE,
    horizontalFraction: Float = 0f,
): MonitorRect {
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
        MonitorRect(
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

/** The ruler's localized words: scale name and axis labels per scale. */
internal data class FalseColorReferenceCopy(
    val scale: String,
    val stopLabels: List<String>,
    val ireLabels: List<String>,
    val limitsLabels: List<String>,
)

@Composable
internal fun falseColorReferenceCopy(scale: FeedFalseColorScale): FalseColorReferenceCopy =
    FalseColorReferenceCopy(
        scale = scale.label,
        stopLabels =
            listOf(
                stringResource(R.string.false_color_axis_min),
                "−2",
                "−1",
                stringResource(R.string.false_color_axis_middle_gray),
                "+1",
                stringResource(R.string.false_color_axis_plus_two),
                "Clip",
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

/** The Swift reference as the shared ruler's values: bands, stop markers (STOPS) or axis words. */
internal fun FalseColorReferencePresentation.referenceValues(
    copy: FalseColorReferenceCopy,
): MonitorFalseColorReferenceValues {
    val curve = reference.curveLabel(read709)
    return MonitorFalseColorReferenceValues(
        subtitle = "${copy.scale} · $curve",
        segments =
            reference.segments.mapIndexed { index, segment ->
                MonitorFalseColorReferenceSegment(
                    index,
                    segment.lowerFraction.toDouble(),
                    segment.upperFraction.toDouble(),
                    segment.color[0].toDouble(),
                    segment.color[1].toDouble(),
                    segment.color[2].toDouble(),
                )
            },
        markers =
            if (scale == FeedFalseColorScale.STOPS) {
                // The shared ruler starts each label 10 dp before its stop and clips at the panel, so the
                // Min and Max ends (0 and 1) are held 16 dp inside it, where the old ruler aligned them.
                val edge = 16.0 / MonitorScopePanelSize.falseColorReference.width
                copy.stopLabels.zip(reference.stopMarkerFractions.toList()).mapIndexed { index, (label, at) ->
                    MonitorFalseColorReferenceMarker(index, label, at.toDouble().coerceIn(edge, 1.0 - edge))
                }
            } else {
                emptyList()
            },
        axisLabels = CommonFalseColorReference.axisLabels(scale.sharedScale),
    )
}

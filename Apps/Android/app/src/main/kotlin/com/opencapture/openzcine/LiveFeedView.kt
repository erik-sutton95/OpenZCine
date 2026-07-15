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
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.Stable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
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
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import com.opencapture.openzcine.bridge.ZoneFrame
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
    private var textureSourceGeometry: FeedTextureSourceGeometry? by mutableStateOf(null)

    /** Resolution-only state observed by the cached presentation texture. */
    internal val feedTextureSourceGeometry: FeedTextureSourceGeometry?
        get() = textureSourceGeometry

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
        presentation = null
        textureSourceGeometry = null
    }
}

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
    onPresentedFrame: ((LiveFrame, Bitmap, LiveFramePreviewBaker?) -> Unit)? = null,
    presentationState: LiveFeedPresentationState? = null,
    effects: FeedEffects = FeedEffectsState.current,
    configuration: FeedEffectsConfiguration = FeedEffectsConfiguration(),
    cameraInput: ExposureAssistCameraInput = ExposureAssistCameraInput(),
    lutLibrary: AndroidLutLibrary? = null,
    effectsPresentationState: LiveFeedEffectsPresentationState? = null,
    aspectFill: Boolean = false,
) {
    val fallbackFrame = remember(source) { mutableStateOf<ImageBitmap?>(null) }
    val latestPresentedFrame = rememberUpdatedState(onPresentedFrame)
    // Stored selections are prepared off the UI thread. Until the shared Swift parser has produced
    // a packed payload, the renderer remains fail-closed (plain feed), then rebuilds on generation.
    val lutRenderGeneration = lutLibrary?.renderGeneration?.collectAsState()?.value ?: 0L
    LaunchedEffect(lutLibrary, effects.lut) {
        val stored = (effects.lut as? FeedLutSelection.Stored)?.value
        if (stored != null) lutLibrary?.prepare(stored)
    }
    var renderer by remember { mutableStateOf<FeedEffectsRenderer?>(null) }
    LaunchedEffect(effects, configuration, cameraInput, lutLibrary, lutRenderGeneration) {
        // Never retain a renderer for a superseded selection while its
        // replacement is prepared. Cube baking and bitmap upload are native/
        // CPU work, so keep the Compose thread responsive during configuration
        // changes such as repeated zebra threshold taps.
        renderer = null
        renderer =
            when {
                effects.isIdentity -> null
                Build.VERSION.SDK_INT >= 33 ->
                    withContext(Dispatchers.Default) {
                        FeedEffectsRenderer.create(effects, configuration, cameraInput, lutLibrary)
                    }
                else -> {
                    Log.w(TAG, "feed effects need Android 13+ (AGSL); rendering the plain feed")
                    null
                }
            }
    }
    LaunchedEffect(
        renderer,
        effects.falseColor,
        configuration.falseColorReferenceEnabled,
        cameraInput,
        effectsPresentationState,
    ) {
        effectsPresentationState?.clear()
        val scale = effects.falseColor?.takeIf { configuration.falseColorReferenceEnabled }
        if (renderer?.falseColorReady == true && scale != null) {
            val reference = withContext(Dispatchers.Default) { resolveFalseColorReference(scale, cameraInput) }
            if (reference != null) effectsPresentationState?.present(scale, reference)
        }
    }
    val ownedRenderer = renderer
    val latestPreviewBaker = rememberUpdatedState<LiveFramePreviewBaker?>(ownedRenderer)
    DisposableEffect(ownedRenderer) {
        onDispose {
            if (Build.VERSION.SDK_INT >= 33) ownedRenderer?.close()
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
                    latestPresentedFrame.value?.invoke(
                        sourceFrame,
                        bitmap,
                        latestPreviewBaker.value,
                    )
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
                aspectFill = aspectFill,
            ) ?: return@Canvas
        val dstSize = IntSize(content.width, content.height)
        val dstOffset = IntOffset(content.left, content.top)
        val activeRenderer = renderer
        if (Build.VERSION.SDK_INT >= 33 && activeRenderer != null) {
            activeRenderer.draw(
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
    var hapticCell by remember { mutableIntStateOf(Int.MIN_VALUE) }
    val density = LocalDensity.current
    val view = LocalView.current
    Canvas(
        modifier
            .zone(frame)
            .glass(ChromeShape)
            .semantics {
                contentDescription = "False color reference, movable panel"
                if (placementStore != null) {
                    customActions =
                        listOf(
                            CustomAccessibilityAction("Recenter false color reference") {
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
        drawFalseColorReference(presentation)
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
private fun androidx.compose.ui.graphics.drawscope.DrawScope.drawFalseColorReference(
    presentation: FalseColorReferencePresentation,
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
        canvas.nativeCanvas.drawText("False Color", barLeft, top + 13.dp.toPx(), paint)
        paint.color = LiveDesign.muted.toArgb()
        paint.textSize = 7.5.dp.toPx()
        paint.typeface = android.graphics.Typeface.create(android.graphics.Typeface.MONOSPACE, android.graphics.Typeface.NORMAL)
        paint.textAlign = android.graphics.Paint.Align.RIGHT
        val curve = if (reference.curveOrdinal == 0) "L3G10" else "N-Log"
        canvas.nativeCanvas.drawText("${presentation.scale.label} · $curve", left + panelWidth - padding, top + 13.dp.toPx(), paint)

        paint.textSize = 5.5.dp.toPx()
        paint.textAlign = android.graphics.Paint.Align.CENTER
        val labels: List<Pair<String, Float>> =
            if (presentation.scale == FeedFalseColorScale.STOPS) {
                listOf("Min", "−3", "18%", "Skin", "+2", "Max").zip(reference.stopMarkerFractions.toList())
            } else {
                val axis =
                    if (presentation.scale == FeedFalseColorScale.IRE) {
                        listOf("clip / shadows", "18%", "skin hi", "highlights → clip")
                    } else {
                        listOf("crushed", "midtones untouched", "clipped")
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

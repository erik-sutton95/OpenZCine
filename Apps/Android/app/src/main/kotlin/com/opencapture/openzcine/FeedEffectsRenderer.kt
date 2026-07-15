package com.opencapture.openzcine

import android.graphics.Bitmap
import android.graphics.BitmapShader
import android.graphics.Canvas
import android.graphics.ColorSpace
import android.graphics.HardwareRenderer
import android.graphics.Paint
import android.graphics.PixelFormat
import android.graphics.RenderNode
import android.graphics.RuntimeShader
import android.graphics.Shader
import android.hardware.HardwareBuffer
import android.media.ImageReader
import android.util.Log
import androidx.annotation.RequiresApi
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.opencapture.openzcine.bridge.SwiftCore
import com.opencapture.openzcine.lut.AndroidLutLibrary
import java.nio.ByteBuffer

private const val TAG = "ZCFeedEffects"

/** Produces a bounded copy of the exact image treatment shown on the phone. */
public fun interface LiveFramePreviewBaker {
    /** Returns an owned display-baked bitmap, or null when rendering failed. */
    public fun bakePreview(frame: Bitmap, maximumWidth: Int): Bitmap?
}

/**
 * Effects [LiveFeedView] applies by default. Debug-intent driven (see
 * `DemoHarness`) until the assist toolbar owns it; release builds never set it.
 */
object FeedEffectsState {
    var current: FeedEffects by mutableStateOf(FeedEffects.NONE)
}

/**
 * GPU effect chain for the live feed — one AGSL pass over the decoded frame,
 * mirroring the iOS `LiveFrameProcessor` order of operations:
 *
 * 1. **Base look**: false colour (which replaces the creative grade) or the
 *    selected LUT, as a 3D-LUT sample of the encoded source pixel. The cube is
 *    baked by the Swift core and uploaded once as a packed-2D texture
 *    (`width = size²`, `height = size`; slice tiles along x). The shader takes
 *    two bilinear taps on adjacent blue slices and mixes — trilinear, the same
 *    interpolation `CIColorCube`/`CubeLUT.map` perform.
 * 2. **Focus peaking**, measured from the *source* frame: the de-logged grey
 *    (the core's black→clip stretch, uniforms from `feedEffectsScalars`) runs a
 *    two-scale gradient difference — first-derivative magnitude peaks ON the
 *    edge (single line), and subtracting the coarse-scale gradient cancels
 *    defocused background edges. Overlay colour is `LiveDesign.accent`.
 * 3. **Zebra**, also measured from the source frame: Rec.709 luma against the
 *    core-supplied highlight threshold and midtone band, drawn as diagonal
 *    stripes over the graded image.
 *
 * All colour math lives in the Swift core; this class uploads baked payloads
 * and interpolates. Requires API 33 (AGSL) and the staged Swift core —
 * [create] returns null otherwise and the feed renders plain.
 */
@RequiresApi(33)
class FeedEffectsRenderer private constructor(private val shader: RuntimeShader) :
    LiveFramePreviewBaker,
    AutoCloseable {
    private val paint = Paint().apply { shader = this@FeedEffectsRenderer.shader }
    private val renderLock = Any()

    /** One shader wrapper per ring bitmap; content updates are picked up via generation id. */
    private val feedShaders = HashMap<Bitmap, BitmapShader>()
    private var previewTarget: HardwarePreviewTarget? = null
    private var closed = false

    /** Draws [frame] with the effect chain into the letterboxed destination rect. */
    fun draw(
        canvas: Canvas,
        frame: Bitmap,
        dstLeft: Float,
        dstTop: Float,
        dstWidth: Float,
        dstHeight: Float,
    ) {
        synchronized(renderLock) {
            if (closed) return
            drawLocked(canvas, frame, dstLeft, dstTop, dstWidth, dstHeight)
        }
    }

    /**
     * Renders the same AGSL chain into a small relay-owned bitmap. This shares
     * the exact shader, cube, and thresholds used by the visible phone feed;
     * no second LUT/peaking/zebra implementation can drift from it.
     */
    override fun bakePreview(frame: Bitmap, maximumWidth: Int): Bitmap? =
        synchronized(renderLock) {
            if (closed) return@synchronized null
            val width = minOf(frame.width, maximumWidth).coerceAtLeast(1)
            val height = (frame.height * width.toFloat() / frame.width).toInt().coerceAtLeast(1)
            val target =
                previewTarget?.takeIf { it.width == width && it.height == height }
                    ?: run {
                        previewTarget?.close()
                        previewTarget = null
                        HardwarePreviewTarget.create(width, height)?.also { previewTarget = it }
                    }
                    ?: return@synchronized null
            try {
                target.render { canvas ->
                    drawLocked(
                        canvas = canvas,
                        frame = frame,
                        dstLeft = 0f,
                        dstTop = 0f,
                        dstWidth = width.toFloat(),
                        dstHeight = height.toFloat(),
                    )
                }
            } catch (_: RuntimeException) {
                target.close()
                previewTarget = null
                null
            } catch (_: OutOfMemoryError) {
                null
            }
        }

    /** Releases the offscreen hardware target created only when a watch requests effects. */
    override fun close() {
        synchronized(renderLock) {
            if (closed) return
            closed = true
            previewTarget?.close()
            previewTarget = null
            feedShaders.clear()
        }
    }

    /** Small persistent HWUI surface used because RuntimeShader cannot draw to a software Canvas. */
    private class HardwarePreviewTarget private constructor(
        val width: Int,
        val height: Int,
        private val imageReader: ImageReader,
        private val renderNode: RenderNode,
        private val renderer: HardwareRenderer,
    ) : AutoCloseable {
        fun render(draw: (Canvas) -> Unit): Bitmap? {
            while (true) {
                val stale = imageReader.acquireLatestImage() ?: break
                stale.close()
            }
            val canvas = renderNode.beginRecording(width, height)
            try {
                draw(canvas)
            } finally {
                renderNode.endRecording()
            }
            renderer.createRenderRequest().setWaitForPresent(true).syncAndDraw()
            val image = imageReader.acquireLatestImage() ?: return null
            return image.use {
                val hardwareBuffer = image.hardwareBuffer ?: return@use null
                val hardwareBitmap =
                    Bitmap.wrapHardwareBuffer(
                        hardwareBuffer,
                        ColorSpace.get(ColorSpace.Named.SRGB),
                    ) ?: return@use null
                try {
                    hardwareBitmap.copy(Bitmap.Config.ARGB_8888, false)
                } finally {
                    hardwareBitmap.recycle()
                }
            }
        }

        override fun close() {
            renderer.destroy()
            imageReader.close()
        }

        companion object {
            fun create(width: Int, height: Int): HardwarePreviewTarget? {
                var reader: ImageReader? = null
                return try {
                    val usage =
                        HardwareBuffer.USAGE_GPU_COLOR_OUTPUT or
                            HardwareBuffer.USAGE_GPU_SAMPLED_IMAGE
                    reader =
                        ImageReader.newInstance(
                            width,
                            height,
                            PixelFormat.RGBA_8888,
                            2,
                            usage,
                        )
                    val node = RenderNode("OpenZCine Wear preview").apply { setPosition(0, 0, width, height) }
                    val renderer =
                        HardwareRenderer().apply {
                            setSurface(requireNotNull(reader).surface)
                            setContentRoot(node)
                        }
                    HardwarePreviewTarget(width, height, requireNotNull(reader), node, renderer)
                } catch (_: RuntimeException) {
                    reader?.close()
                    null
                }
            }
        }
    }

    private fun drawLocked(
        canvas: Canvas,
        frame: Bitmap,
        dstLeft: Float,
        dstTop: Float,
        dstWidth: Float,
        dstHeight: Float,
    ) {
        // The decode ring holds 3 bitmaps; a growing map means the feed size
        // changed and the old ring was dropped — start over.
        if (feedShaders.size > 4) feedShaders.clear()
        val feed =
            feedShaders.getOrPut(frame) {
                BitmapShader(frame, Shader.TileMode.CLAMP, Shader.TileMode.CLAMP).apply {
                    filterMode = BitmapShader.FILTER_MODE_LINEAR
                }
            }
        shader.setInputShader("feed", feed)
        shader.setFloatUniform("dstOffset", dstLeft, dstTop)
        shader.setFloatUniform("srcScale", frame.width / dstWidth)
        canvas.drawRect(dstLeft, dstTop, dstLeft + dstWidth, dstTop + dstHeight, paint)
    }

    companion object {
        /** Curve ordinal for RED Log3G10 — the offline-monitoring default (see iOS
         * `playbackExposureSignalMapping`); camera-driven curve selection lands with
         * the session-backed feed. Mirrors `FeedEffectsWire.curve`. */
        private const val CURVE_LOG3G10 = 0

        /** iOS `ZebraSettings` defaults: highlight at monitor 100%, midtone at 55%. */
        private const val ZEBRA_HIGHLIGHT_IRE = 100f
        private const val ZEBRA_MIDTONE_IRE = 55f

        /** 33³ matches the iOS built-in looks; false colour uses the core's 64³. */
        private const val LUT_SIZE = 33

        /**
         * Renderer for [effects], or null when nothing is on or the Swift
         * core isn't staged — callers fall back to the plain feed. Callers
         * own the API 33 (AGSL) gate, per the class annotation.
         */
        fun create(
            effects: FeedEffects,
            lutLibrary: AndroidLutLibrary? = null,
        ): FeedEffectsRenderer? {
            if (effects.isIdentity) return null
            if (!SwiftCore.isAvailable) {
                Log.w(TAG, "feed effects need the Swift core (just android-core); rendering plain")
                return null
            }
            return try {
                build(effects, lutLibrary)
            } catch (e: RuntimeException) {
                Log.e(TAG, "feed-effects pipeline setup failed; rendering the plain feed", e)
                null
            }
        }

        /** Bakes once per selection: cube upload + threshold uniforms, never per frame. */
        private fun build(
            effects: FeedEffects,
            lutLibrary: AndroidLutLibrary?,
        ): FeedEffectsRenderer {
            val shader = RuntimeShader(EFFECTS_AGSL)

            val cube: ByteArray?
            val cubeSize: Int
            val lutSelection = effects.lut
            when {
                effects.falseColor != null -> {
                    cube = SwiftCore.bakeFalseColorCube(effects.falseColor.wireOrdinal, CURVE_LOG3G10)
                    cubeSize = 64
                }
                lutSelection is FeedLutSelection.BuiltIn -> {
                    cube = SwiftCore.bakeLut(lutSelection.value.wireOrdinal, LUT_SIZE)
                    cubeSize = LUT_SIZE
                }
                lutSelection is FeedLutSelection.Stored -> {
                    // A stored selection is only usable after Android's bounded app-private store
                    // has revalidated it through Swift and cached the existing packed-cube payload.
                    // There is intentionally no Kotlin parser/sample fallback on a cold/corrupt file.
                    val packed = lutLibrary?.packedCube(lutSelection.value)
                    cube = packed?.rgba
                    cubeSize = packed?.cubeSize ?: 0
                }
                else -> {
                    cube = null
                    cubeSize = 0
                }
            }
            if (cubeSize > 0 && cube == null) {
                Log.w(TAG, "core returned no cube for $effects; base look disabled")
            }
            if (cube != null) {
                check(cube.size == cubeSize * cubeSize * cubeSize * 4) { "bad cube payload" }
                val lut = Bitmap.createBitmap(cubeSize * cubeSize, cubeSize, Bitmap.Config.ARGB_8888)
                lut.copyPixelsFromBuffer(ByteBuffer.wrap(cube))
                shader.setInputShader(
                    "lut",
                    BitmapShader(lut, Shader.TileMode.CLAMP, Shader.TileMode.CLAMP).apply {
                        filterMode = BitmapShader.FILTER_MODE_LINEAR
                    },
                )
                shader.setFloatUniform("lutSize", cubeSize.toFloat())
            } else {
                // Every declared child must be bound; lutSize 0 keeps grade() a no-op.
                val stub = Bitmap.createBitmap(1, 1, Bitmap.Config.ARGB_8888)
                shader.setInputShader(
                    "lut",
                    BitmapShader(stub, Shader.TileMode.CLAMP, Shader.TileMode.CLAMP),
                )
                shader.setFloatUniform("lutSize", 0f)
            }

            val scalars =
                requireNotNull(
                    SwiftCore.feedEffectsScalars(
                        CURVE_LOG3G10,
                        ZEBRA_HIGHLIGHT_IRE,
                        ZEBRA_MIDTONE_IRE,
                    ),
                ) { "core rejected the effect scalars" }
            shader.setFloatUniform("deLogRange", scalars[0], scalars[1])
            shader.setFloatUniform("peakingOn", if (effects.peaking) 1f else 0f)
            shader.setFloatUniform(
                "peakingColor",
                LiveDesign.accent.red,
                LiveDesign.accent.green,
                LiveDesign.accent.blue,
            )
            shader.setFloatUniform("zebraOn", if (effects.zebra) 1f else 0f)
            shader.setFloatUniform("zebraHighlight", scalars[2])
            shader.setFloatUniform("zebraMidtone", scalars[3])
            if (BuildConfig.DEBUG) {
                Log.d(
                    TAG,
                    "pipeline up: $effects cube=${cube?.size ?: 0}B " +
                        "scalars=${scalars.joinToString()}",
                )
            }
            return FeedEffectsRenderer(shader)
        }
    }
}

/**
 * The single-pass effect shader. Peaking/zebra measure the SOURCE pixel so a
 * grade never changes what reads as in-focus or clipped (iOS invariant).
 *
 * Renderer-tuning constants (thresholds, gains, stripe pitch) mirror the iOS
 * compositor's; the colour math (cube contents, de-log anchors, zebra
 * thresholds) arrives baked from the Swift core via uniforms/textures.
 */
private val EFFECTS_AGSL =
    """
    uniform shader feed;          // decoded frame, bitmap px
    uniform shader lut;           // packed cube: width = n*n, height = n
    uniform float lutSize;        // cube edge n; < 2 disables the base look
    uniform float2 dstOffset;     // letterbox origin, canvas px
    uniform float srcScale;       // canvas px -> bitmap px

    uniform float peakingOn;
    uniform float3 peakingColor;
    uniform float2 deLogRange;    // core black/clip anchors, normalized code

    uniform float zebraOn;
    uniform float zebraHighlight; // core threshold, normalized code
    uniform float zebraMidtone;   // core band centre, normalized code

    const float3 LUMA709 = float3(0.2126, 0.7152, 0.0722);
    const float PEAKING_THRESHOLD = 0.04;   // on the defocus-cancelled gradient
    const float PEAKING_RAMP = 24.0;
    const float DEFOCUS_REJECTION = 1.35;   // iOS ImageEffectsCompositor
    const float ZEBRA_GAIN = 40.0;          // iOS soft-threshold ramp
    const float ZEBRA_HALF_WIDTH = 5.0 / 255.0;
    const float STRIPE_PITCH = 14.14;       // iOS 5 px stripes rotated 45 deg

    float3 grade(float3 c) {
        if (lutSize < 2.0) return c;
        float n = lutSize;
        float b = clamp(c.b, 0.0, 1.0) * (n - 1.0);
        float s0 = floor(b);
        float s1 = min(s0 + 1.0, n - 1.0);
        float x = clamp(c.r, 0.0, 1.0) * (n - 1.0) + 0.5;
        float y = clamp(c.g, 0.0, 1.0) * (n - 1.0) + 0.5;
        float3 lo = float3(lut.eval(float2(s0 * n + x, y)).rgb);
        float3 hi = float3(lut.eval(float2(s1 * n + x, y)).rgb);
        return mix(lo, hi, b - s0);
    }

    // De-logged grey: the core's black->clip stretch of the mean channel.
    float deLogGrey(float2 p) {
        float3 c = float3(feed.eval(p).rgb);
        float g = (c.r + c.g + c.b) / 3.0;
        return clamp((g - deLogRange.x) / (deLogRange.y - deLogRange.x), 0.0, 1.0);
    }

    // Central-difference gradient magnitude per pixel at sampling distance d.
    float gradMag(float2 p, float d) {
        float gx = deLogGrey(p + float2(d, 0.0)) - deLogGrey(p - float2(d, 0.0));
        float gy = deLogGrey(p + float2(0.0, d)) - deLogGrey(p - float2(0.0, d));
        return length(float2(gx, gy)) / (2.0 * d);
    }

    half4 main(float2 fragCoord) {
        float2 src = (fragCoord - dstOffset) * srcScale;
        float3 source = float3(feed.eval(src).rgb);
        float3 color = grade(source);

        if (peakingOn > 0.5) {
            // fine - k*coarse: a sharp edge keeps fine-scale gradient a wide
            // (defocused) edge lacks; both scales cancel on blurred edges.
            float fine = gradMag(src, 1.0);
            float coarse = gradMag(src, 2.6);
            float response = fine - DEFOCUS_REJECTION * coarse;
            float mask = clamp((response - PEAKING_THRESHOLD) * PEAKING_RAMP, 0.0, 1.0);
            color = mix(color, peakingColor, mask);
        }

        if (zebraOn > 0.5) {
            float luma = dot(source, LUMA709);
            float stripe = step(0.5, fract((fragCoord.x + fragCoord.y) / STRIPE_PITCH));
            float hi = clamp((luma - zebraHighlight) * ZEBRA_GAIN, 0.0, 1.0);
            color = mix(color, float3(1.0), hi * stripe);
            float mid = clamp((luma - (zebraMidtone - ZEBRA_HALF_WIDTH)) * ZEBRA_GAIN, 0.0, 1.0)
                * clamp(((zebraMidtone + ZEBRA_HALF_WIDTH) - luma) * ZEBRA_GAIN, 0.0, 1.0);
            color = mix(color, float3(1.0, 0.72, 0.2), mid * stripe);
        }

        return half4(half3(color), 1.0);
    }
    """
        .trimIndent()

package com.opencapture.openzcine

import android.graphics.Bitmap
import android.graphics.BitmapShader
import android.graphics.Canvas
import android.graphics.ColorSpace
import android.graphics.HardwareRenderer
import android.graphics.Paint
import android.graphics.PixelFormat
import android.graphics.RenderEffect
import android.graphics.RenderNode
import android.graphics.RuntimeShader
import android.graphics.Shader
import android.hardware.HardwareBuffer
import android.media.ImageReader
import androidx.annotation.RequiresApi
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.opencapture.openzcine.lut.AndroidLutLibrary
import java.nio.ByteBuffer

/** Produces a bounded copy of the exact image treatment shown on the phone. */
public fun interface LiveFramePreviewBaker {
    /** Returns an owned display-baked bitmap, or null when rendering failed. */
    public fun bakePreview(frame: Bitmap, maximumWidth: Int): Bitmap?
}

/**
 * Process-local compatibility mirror for callers that have not yet adopted an
 * explicit [AssistState]. Normal monitor construction passes restored effects
 * directly and must never use this mutable value as persistence input.
 */
object FeedEffectsState {
    var current: FeedEffects by mutableStateOf(FeedEffects.NONE)
}

/**
 * GPU effect chain for the live feed — one AGSL pass over the decoded frame,
 * mirroring the iOS `LiveFrameProcessor` order of operations:
 *
 * 1. **Base look**: STOPS/IRE false colour replaces the creative grade; LIMITS
 *    keeps the selected LUT and composites a core-baked paint/mask pair over
 *    it. Every cube is baked by Swift and uploaded once as a packed-2D texture
 *    (`width = size²`, `height = size`; slice tiles along x). The shader takes
 *    two bilinear taps on adjacent blue slices and mixes — trilinear, the same
 *    interpolation `CIColorCube`/`CubeLUT.map` perform.
 * 2. **Focus peaking**, measured from the *source* frame: the de-logged grey
 *    (the core's camera-aware black→clip stretch, uniforms from
 *    `feedEffectsConfiguration`) runs a
 *    two-scale gradient difference — first-derivative magnitude peaks ON the
 *    edge (single line), and subtracting the coarse-scale gradient cancels
 *    defocused background edges. Overlay colour comes from the shared-core
 *    iOS peaking-colour configuration.
 * 3. **Zebra**, also measured from the source frame: Rec.709 luma against the
 *    core-supplied dual-zone thresholds and independently selected stripe
 *    colours, drawn over the graded image.
 *
 * All colour math lives in the Swift core; this class uploads baked payloads
 * and interpolates. Requires API 33 (AGSL) and the staged Swift core —
 * [create] returns null otherwise and the feed renders plain.
 */
@RequiresApi(33)
class FeedEffectsRenderer private constructor(
    private val shader: RuntimeShader,
    internal val falseColorReady: Boolean,
) :
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
        shader.setFloatUniform("sourceSize", frame.width.toFloat(), frame.height.toFloat())
        canvas.drawRect(dstLeft, dstTop, dstLeft + dstWidth, dstTop + dstHeight, paint)
    }

    /**
     * Binds this same effect chain to an Android view's RenderNode input.
     *
     * Media3 playback uses a TextureView whose local coordinate space is the
     * decoded video's aspect-fit rectangle. The view supplies the `feed`
     * shader input, while Swift-baked LUT/false-colour data and the existing
     * peaking/zebra uniforms remain identical to live view. Returning null for
     * an empty size keeps the caller from installing an invalid shader during
     * the initial layout pass.
     */
    fun viewRenderEffect(width: Int, height: Int): RenderEffect? {
        if (width <= 0 || height <= 0) return null
        shader.setFloatUniform("dstOffset", 0f, 0f)
        shader.setFloatUniform("srcScale", 1f)
        shader.setFloatUniform("sourceSize", width.toFloat(), height.toFloat())
        return RenderEffect.createRuntimeShaderEffect(shader, "feed")
    }

    companion object {
        /**
         * Renderer for [effects], or null when nothing is on or the Swift
         * core isn't staged — callers fall back to the plain feed. Callers
         * own the API 33 (AGSL) gate, per the class annotation.
         */
        fun create(
            effects: FeedEffects,
            configuration: FeedEffectsConfiguration,
            cameraInput: ExposureAssistCameraInput,
            lutLibrary: AndroidLutLibrary? = null,
        ): FeedEffectsRenderer? {
            val plan =
                FeedEffectsRenderPlanFactory.create(
                    effects,
                    configuration,
                    cameraInput,
                    lutLibrary,
                ) ?: return null
            return build(plan)
        }

        /** Uploads an already-resolved shared plan into the API 33 AGSL adapter. */
        internal fun create(plan: FeedEffectsRenderPlan): FeedEffectsRenderer = build(plan)

        /** Uploads one shared immutable plan into the API 33 AGSL adapter. */
        private fun build(plan: FeedEffectsRenderPlan): FeedEffectsRenderer {
            val shader = RuntimeShader(EFFECTS_AGSL)
            val renderConfiguration = plan.configuration
            uploadCube(shader, "lut", "lutSize", plan.baseCube)
            uploadCube(shader, "limitsPaintCube", "limitsPaintSize", plan.limitsPaintCube)
            uploadCube(shader, "limitsWeightCube", "limitsWeightSize", plan.limitsWeightCube)
            shader.setFloatUniform("limitsOn", if (plan.limitsReady) 1f else 0f)

            shader.setFloatUniform(
                "deLogCurve0to3",
                renderConfiguration.deLogCurve[0],
                renderConfiguration.deLogCurve[1],
                renderConfiguration.deLogCurve[2],
                renderConfiguration.deLogCurve[3],
            )
            shader.setFloatUniform("deLogCurve4", renderConfiguration.deLogCurve[4])
            shader.setFloatUniform("peakingOn", if (plan.effects.peaking) 1f else 0f)
            shader.setFloatUniform(
                "peakingColor",
                renderConfiguration.peakingColor[0],
                renderConfiguration.peakingColor[1],
                renderConfiguration.peakingColor[2],
            )
            shader.setFloatUniform("peakingThreshold", renderConfiguration.peakingThreshold)
            shader.setFloatUniform("peakingRamp", renderConfiguration.peakingRamp)
            shader.setFloatUniform(
                "zebraHighlightOn",
                if (plan.effects.zebra && renderConfiguration.highlightEnabled) 1f else 0f,
            )
            shader.setFloatUniform("zebraHighlight", renderConfiguration.highlightCode)
            shader.setFloatUniform(
                "zebraHighlightColor",
                renderConfiguration.highlightColor[0],
                renderConfiguration.highlightColor[1],
                renderConfiguration.highlightColor[2],
            )
            shader.setFloatUniform(
                "zebraMidtoneOn",
                if (plan.effects.zebra && renderConfiguration.midtoneEnabled) 1f else 0f,
            )
            shader.setFloatUniform("zebraMidtone", renderConfiguration.midtoneCode)
            shader.setFloatUniform(
                "zebraMidtoneColor",
                renderConfiguration.midtoneColor[0],
                renderConfiguration.midtoneColor[1],
                renderConfiguration.midtoneColor[2],
            )
            return FeedEffectsRenderer(shader, plan.falseColorReady)
        }

        /** Uploads a core-baked packed cube, or a bound stub when that stage is unavailable. */
        private fun uploadCube(
            shader: RuntimeShader,
            shaderName: String,
            sizeName: String,
            cube: FeedEffectsCube?,
        ) {
            if (cube != null) {
                val bitmap =
                    Bitmap.createBitmap(cube.size * cube.size, cube.size, Bitmap.Config.ARGB_8888)
                bitmap.copyPixelsFromBuffer(ByteBuffer.wrap(cube.rgba))
                shader.setInputShader(
                    shaderName,
                    BitmapShader(bitmap, Shader.TileMode.CLAMP, Shader.TileMode.CLAMP).apply {
                        filterMode = BitmapShader.FILTER_MODE_LINEAR
                    },
                )
                shader.setFloatUniform(sizeName, cube.size.toFloat())
            } else {
                // AGSL requires every declared child to be bound. The zero size keeps this cube
                // stage inactive without inventing a local colour fallback.
                val stub = Bitmap.createBitmap(1, 1, Bitmap.Config.ARGB_8888)
                shader.setInputShader(
                    shaderName,
                    BitmapShader(stub, Shader.TileMode.CLAMP, Shader.TileMode.CLAMP),
                )
                shader.setFloatUniform(sizeName, 0f)
            }
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
    uniform shader feed;               // decoded frame, bitmap px
    uniform shader lut;                // packed cube: width = n*n, height = n
    uniform float lutSize;             // cube edge n; < 2 disables the base look
    uniform shader limitsPaintCube;    // Swift-baked additive Limits colour cube
    uniform float limitsPaintSize;
    uniform shader limitsWeightCube;   // Swift-baked additive Limits zone mask
    uniform float limitsWeightSize;
    uniform float limitsOn;
    uniform float2 dstOffset;          // letterbox origin, canvas px
    uniform float srcScale;            // canvas px -> bitmap px
    uniform float2 sourceSize;         // decoded frame extent, bitmap px

    uniform float peakingOn;
    uniform float3 peakingColor;
    uniform float4 deLogCurve0to3;     // core quarter-axis camera tone curve
    uniform float deLogCurve4;
    uniform float peakingThreshold;    // core sensitivity policy
    uniform float peakingRamp;         // core sensitivity policy

    uniform float zebraHighlightOn;
    uniform float zebraHighlight;      // core threshold, normalized code
    uniform float3 zebraHighlightColor;
    uniform float zebraMidtoneOn;
    uniform float zebraMidtone;        // core band centre, normalized code
    uniform float3 zebraMidtoneColor;

    const float3 LUMA709 = float3(0.2126, 0.7152, 0.0722);
    const float PEAKING_EDGE_INSET = 6.0;
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

    float3 limitsPaint(float3 c) {
        if (limitsPaintSize < 2.0) return c;
        float n = limitsPaintSize;
        float b = clamp(c.b, 0.0, 1.0) * (n - 1.0);
        float s0 = floor(b);
        float s1 = min(s0 + 1.0, n - 1.0);
        float x = clamp(c.r, 0.0, 1.0) * (n - 1.0) + 0.5;
        float y = clamp(c.g, 0.0, 1.0) * (n - 1.0) + 0.5;
        float3 lo = float3(limitsPaintCube.eval(float2(s0 * n + x, y)).rgb);
        float3 hi = float3(limitsPaintCube.eval(float2(s1 * n + x, y)).rgb);
        return mix(lo, hi, b - s0);
    }

    float limitsWeight(float3 c) {
        if (limitsWeightSize < 2.0) return 0.0;
        float n = limitsWeightSize;
        float b = clamp(c.b, 0.0, 1.0) * (n - 1.0);
        float s0 = floor(b);
        float s1 = min(s0 + 1.0, n - 1.0);
        float x = clamp(c.r, 0.0, 1.0) * (n - 1.0) + 0.5;
        float y = clamp(c.g, 0.0, 1.0) * (n - 1.0) + 0.5;
        float lo = limitsWeightCube.eval(float2(s0 * n + x, y)).r;
        float hi = limitsWeightCube.eval(float2(s1 * n + x, y)).r;
        return clamp(mix(lo, hi, b - s0), 0.0, 1.0);
    }

    float monotoneTone(float y0, float y1, float y2, float y3, float t) {
        // Equal-spaced cubic Hermite interpolation is the shader equivalent of
        // the smooth five-control-point CIToneCurve used by iOS. Clamping each
        // segment prevents overshoot across a monotone camera response.
        float m1 = 0.5 * (y2 - y0);
        float m2 = 0.5 * (y3 - y1);
        float t2 = t * t;
        float t3 = t2 * t;
        float value =
            (2.0 * t3 - 3.0 * t2 + 1.0) * y1
            + (t3 - 2.0 * t2 + t) * m1
            + (-2.0 * t3 + 3.0 * t2) * y2
            + (t3 - t2) * m2;
        return clamp(value, min(y1, y2), max(y1, y2));
    }

    // De-logged grey: five camera-aware tone-curve points, matching iOS's
    // quarter-axis CIToneCurve configuration without recreating curve policy.
    float deLogGrey(float2 p) {
        float3 c = float3(feed.eval(p).rgb);
        float position = clamp((c.r + c.g + c.b) / 3.0, 0.0, 1.0) * 4.0;
        int segment = int(floor(position));
        if (segment > 3) segment = 3;
        float fraction = position - float(segment);
        if (segment == 0) {
            return monotoneTone(
                deLogCurve0to3.x,
                deLogCurve0to3.x,
                deLogCurve0to3.y,
                deLogCurve0to3.z,
                fraction);
        } else if (segment == 1) {
            return monotoneTone(
                deLogCurve0to3.x,
                deLogCurve0to3.y,
                deLogCurve0to3.z,
                deLogCurve0to3.w,
                fraction);
        } else if (segment == 2) {
            return monotoneTone(
                deLogCurve0to3.y,
                deLogCurve0to3.z,
                deLogCurve0to3.w,
                deLogCurve4,
                fraction);
        } else {
            return monotoneTone(
                deLogCurve0to3.z,
                deLogCurve0to3.w,
                deLogCurve4,
                deLogCurve4,
                fraction);
        }
        return deLogCurve4;
    }

    // 1 px central differences — no 3×3 / pre-blur fattening.
    float edgeMagnitude(float2 p) {
        float l = deLogGrey(p - float2(1.0, 0.0));
        float r = deLogGrey(p + float2(1.0, 0.0));
        float u = deLogGrey(p - float2(0.0, 1.0));
        float d = deLogGrey(p + float2(0.0, 1.0));
        return length(float2(r - l, d - u)) * 0.5;
    }

    half4 main(float2 fragCoord) {
        float2 src = (fragCoord - dstOffset) * srcScale;
        float3 source = float3(feed.eval(src).rgb);
        float3 color = grade(source);

        if (limitsOn > 0.5) {
            color = mix(color, limitsPaint(source), limitsWeight(source));
        }

        if (peakingOn > 0.5) {
            if (src.x >= PEAKING_EDGE_INSET && src.y >= PEAKING_EDGE_INSET
                && src.x < sourceSize.x - PEAKING_EDGE_INSET
                && src.y < sourceSize.y - PEAKING_EDGE_INSET) {
                float g = edgeMagnitude(src);
                float threshold = clamp(peakingThreshold * 30.0, 0.045, 0.14);
                float aa = threshold * (0.06 + 0.04 * clamp(160.0 / max(peakingRamp, 1.0), 0.5, 1.5));
                float core = smoothstep(threshold, threshold + aa, g);
                float under = smoothstep(threshold - aa * 0.35, threshold, g) * (1.0 - core);
                color = mix(color, float3(0.04, 0.04, 0.05), under * 0.28);
                color = mix(color, peakingColor, core);
            }
        }

        if (zebraHighlightOn > 0.5 || zebraMidtoneOn > 0.5) {
            float luma = dot(source, LUMA709);
            float stripe = step(0.5, fract((fragCoord.x + fragCoord.y) / STRIPE_PITCH));
            if (zebraHighlightOn > 0.5) {
                float hi = clamp((luma - zebraHighlight) * ZEBRA_GAIN, 0.0, 1.0);
                color = mix(color, zebraHighlightColor, hi * stripe);
            }
            if (zebraMidtoneOn > 0.5) {
                float mid = clamp((luma - (zebraMidtone - ZEBRA_HALF_WIDTH)) * ZEBRA_GAIN, 0.0, 1.0)
                    * clamp(((zebraMidtone + ZEBRA_HALF_WIDTH) - luma) * ZEBRA_GAIN, 0.0, 1.0);
                color = mix(color, zebraMidtoneColor, mid * stripe);
            }
        }

        return half4(half3(color), 1.0);
    }
    """
        .trimIndent()

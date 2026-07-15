package com.opencapture.openzcine

import android.graphics.Bitmap
import android.graphics.BitmapShader
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RenderEffect
import android.graphics.RuntimeShader
import android.graphics.Shader
import android.util.Log
import androidx.annotation.RequiresApi
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.opencapture.openzcine.bridge.SwiftCore
import com.opencapture.openzcine.lut.AndroidLutLibrary
import java.nio.ByteBuffer
import java.util.LinkedHashMap

private const val TAG = "ZCFeedEffects"

/**
 * Small process-local cache for immutable Swift-baked cube payloads. Changing
 * zebra or peaking settings rebuilds shader uniforms but must not rebake the
 * same 1 MB false-colour textures. Access is synchronized because renderer
 * construction runs off the Compose thread.
 */
private object FeedEffectsCubeCache {
    private const val MAX_ENTRIES = 8
    private val cubes =
        object : LinkedHashMap<String, ByteArray>(MAX_ENTRIES, 0.75f, true) {
            override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, ByteArray>?): Boolean =
                size > MAX_ENTRIES
        }

    fun value(key: String, bake: () -> ByteArray?): ByteArray? =
        synchronized(cubes) {
            cubes[key] ?: bake()?.also { cubes[key] = it }
        }
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
) {
    private val paint = Paint().apply { shader = this@FeedEffectsRenderer.shader }

    /** One shader wrapper per ring bitmap; content updates are picked up via generation id. */
    private val feedShaders = HashMap<Bitmap, BitmapShader>()

    /** Draws [frame] with the effect chain into the letterboxed destination rect. */
    fun draw(
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
        /** 33³ matches the iOS built-in looks; false colour uses the core's 64³. */
        private const val LUT_SIZE = 33

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
            if (effects.isIdentity) return null
            if (!SwiftCore.isAvailable) {
                Log.w(TAG, "feed effects need the Swift core (just android-core); rendering plain")
                return null
            }
            return try {
                build(effects, configuration.normalized(), cameraInput, lutLibrary)
            } catch (e: RuntimeException) {
                Log.e(TAG, "feed-effects pipeline setup failed; rendering the plain feed", e)
                null
            }
        }

        /** Bakes once per selection: cube upload + threshold uniforms, never per frame. */
        private fun build(
            effects: FeedEffects,
            configuration: FeedEffectsConfiguration,
            cameraInput: ExposureAssistCameraInput,
            lutLibrary: AndroidLutLibrary?,
        ): FeedEffectsRenderer {
            val shader = RuntimeShader(EFFECTS_AGSL)

            val renderConfiguration =
                requireNotNull(
                    SwiftCore.feedEffectsConfiguration(
                        cameraInput.codec,
                        cameraInput.isoWireValue,
                        cameraInput.baseIso,
                        configuration.peakingSensitivity.wireOrdinal,
                        configuration.peakingColor.wireOrdinal,
                        configuration.zebraHighlightEnabled,
                        configuration.zebraHighlightIre,
                        configuration.zebraHighlightColor.wireOrdinal,
                        configuration.zebraMidtoneEnabled,
                        configuration.zebraMidtoneIre,
                        configuration.zebraMidtoneColor.wireOrdinal,
                    ),
                ) { "core rejected the effect configuration" }
                    .let(FeedEffectsRenderConfiguration::parse)

            val cube: ByteArray?
            val cubeSize: Int
            val lutSelection = effects.lut
            when {
                effects.falseColor != null && effects.falseColor != FeedFalseColorScale.LIMITS -> {
                    cube =
                        FeedEffectsCubeCache.value(
                            "false:${effects.falseColor.wireOrdinal}:${renderConfiguration.curveOrdinal}:" +
                                renderConfiguration.clipNative.toBits(),
                        ) {
                            SwiftCore.bakeFalseColorCube(
                                effects.falseColor.wireOrdinal,
                                renderConfiguration.curveOrdinal,
                                renderConfiguration.clipNative,
                            )
                        }
                    cubeSize = 64
                }
                lutSelection is FeedLutSelection.BuiltIn -> {
                    cube =
                        FeedEffectsCubeCache.value("lut:${lutSelection.value.wireOrdinal}:$LUT_SIZE") {
                            SwiftCore.bakeLut(lutSelection.value.wireOrdinal, LUT_SIZE)
                        }
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
            uploadCube(shader, "lut", "lutSize", cube, cubeSize)

            val limitsActive = effects.falseColor == FeedFalseColorScale.LIMITS
            val limitsPaint =
                if (limitsActive) {
                    FeedEffectsCubeCache.value(
                        "limits-paint:${renderConfiguration.curveOrdinal}:" +
                            renderConfiguration.clipNative.toBits(),
                    ) {
                        SwiftCore.bakeFalseColorLimitsPaint(
                            renderConfiguration.curveOrdinal,
                            renderConfiguration.clipNative,
                        )
                    }
                } else {
                    null
                }
            val limitsWeight =
                if (limitsActive) {
                    FeedEffectsCubeCache.value(
                        "limits-weight:${renderConfiguration.curveOrdinal}:" +
                            renderConfiguration.clipNative.toBits(),
                    ) {
                        SwiftCore.bakeFalseColorLimitsWeight(
                            renderConfiguration.curveOrdinal,
                            renderConfiguration.clipNative,
                        )
                    }
                } else {
                    null
                }
            val limitsReady = limitsPaint != null && limitsWeight != null
            uploadCube(shader, "limitsPaintCube", "limitsPaintSize", limitsPaint, 64)
            uploadCube(shader, "limitsWeightCube", "limitsWeightSize", limitsWeight, 64)
            shader.setFloatUniform("limitsOn", if (limitsReady) 1f else 0f)

            shader.setFloatUniform(
                "deLogCurve0to3",
                renderConfiguration.deLogCurve[0],
                renderConfiguration.deLogCurve[1],
                renderConfiguration.deLogCurve[2],
                renderConfiguration.deLogCurve[3],
            )
            shader.setFloatUniform("deLogCurve4", renderConfiguration.deLogCurve[4])
            shader.setFloatUniform("peakingOn", if (effects.peaking) 1f else 0f)
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
                if (effects.zebra && renderConfiguration.highlightEnabled) 1f else 0f,
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
                if (effects.zebra && renderConfiguration.midtoneEnabled) 1f else 0f,
            )
            shader.setFloatUniform("zebraMidtone", renderConfiguration.midtoneCode)
            shader.setFloatUniform(
                "zebraMidtoneColor",
                renderConfiguration.midtoneColor[0],
                renderConfiguration.midtoneColor[1],
                renderConfiguration.midtoneColor[2],
            )
            if (BuildConfig.DEBUG) {
                Log.d(
                    TAG,
                    "pipeline up: $effects cube=${cube?.size ?: 0}B " +
                        "curve=${renderConfiguration.curveOrdinal} clip=${renderConfiguration.clipNative} " +
                        "limits=$limitsReady",
                )
            }
            val falseColorReady =
                when (effects.falseColor) {
                    FeedFalseColorScale.STOPS, FeedFalseColorScale.IRE -> cube != null
                    FeedFalseColorScale.LIMITS -> limitsReady
                    null -> false
                }
            return FeedEffectsRenderer(shader, falseColorReady)
        }

        /** Uploads a core-baked packed cube, or a bound stub when that stage is unavailable. */
        private fun uploadCube(
            shader: RuntimeShader,
            shaderName: String,
            sizeName: String,
            cube: ByteArray?,
            cubeSize: Int,
        ) {
            if (cube != null && cubeSize >= 2) {
                check(cube.size == cubeSize * cubeSize * cubeSize * 4) { "bad $shaderName cube payload" }
                val bitmap = Bitmap.createBitmap(cubeSize * cubeSize, cubeSize, Bitmap.Config.ARGB_8888)
                bitmap.copyPixelsFromBuffer(ByteBuffer.wrap(cube))
                shader.setInputShader(
                    shaderName,
                    BitmapShader(bitmap, Shader.TileMode.CLAMP, Shader.TileMode.CLAMP).apply {
                        filterMode = BitmapShader.FILTER_MODE_LINEAR
                    },
                )
                shader.setFloatUniform(sizeName, cubeSize.toFloat())
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
    const float DEFOCUS_REJECTION = 1.35;   // iOS ImageEffectsCompositor
    const float PEAKING_EDGE_INSET = 10.4;  // 2.6px coarse radius × iOS crop factor 4
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

    // Sobel's orthogonal 1-2-1 smoothing supplies the fine noise-floor blur;
    // the 2.6px pass is iOS's defocus-rejection scale.
    float gradMag(float2 p, float d) {
        float tl = deLogGrey(p + float2(-d, -d));
        float tc = deLogGrey(p + float2(0.0, -d));
        float tr = deLogGrey(p + float2(d, -d));
        float ml = deLogGrey(p + float2(-d, 0.0));
        float mr = deLogGrey(p + float2(d, 0.0));
        float bl = deLogGrey(p + float2(-d, d));
        float bc = deLogGrey(p + float2(0.0, d));
        float br = deLogGrey(p + float2(d, d));
        float gx = -tl - 2.0 * ml - bl + tr + 2.0 * mr + br;
        float gy = -tl - 2.0 * tc - tr + bl + 2.0 * bc + br;
        return length(float2(gx, gy)) / (8.0 * d);
    }

    half4 main(float2 fragCoord) {
        float2 src = (fragCoord - dstOffset) * srcScale;
        float3 source = float3(feed.eval(src).rgb);
        float3 color = grade(source);

        if (limitsOn > 0.5) {
            color = mix(color, limitsPaint(source), limitsWeight(source));
        }

        if (peakingOn > 0.5) {
            // Fine/coarse derivative-of-Gaussian approximations at the exact
            // iOS radii. Suppress the coarse-filter fringe with the same crop.
            if (src.x >= PEAKING_EDGE_INSET && src.y >= PEAKING_EDGE_INSET
                && src.x < sourceSize.x - PEAKING_EDGE_INSET
                && src.y < sourceSize.y - PEAKING_EDGE_INSET) {
                float fine = gradMag(src, 0.8);
                float coarse = gradMag(src, 2.6);
                float response = fine - DEFOCUS_REJECTION * coarse;
                float mask = clamp((response - peakingThreshold) * peakingRamp, 0.0, 1.0);
                color = mix(color, peakingColor, mask);
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

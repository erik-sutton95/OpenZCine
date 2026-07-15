package com.opencapture.openzcine

import android.graphics.Bitmap
import android.graphics.BitmapShader
import android.graphics.Canvas
import android.graphics.Paint
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

private const val TAG = "ZCFeedEffects"

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
class FeedEffectsRenderer private constructor(private val shader: RuntimeShader) {
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
        canvas.drawRect(dstLeft, dstTop, dstLeft + dstWidth, dstTop + dstHeight, paint)
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
                        SwiftCore.bakeFalseColorCube(
                            effects.falseColor.wireOrdinal,
                            renderConfiguration.curveOrdinal,
                            renderConfiguration.clipNative,
                        )
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
            uploadCube(shader, "lut", "lutSize", cube, cubeSize)

            val limitsActive = effects.falseColor == FeedFalseColorScale.LIMITS
            val limitsPaint =
                if (limitsActive) {
                    SwiftCore.bakeFalseColorLimitsPaint(
                        renderConfiguration.curveOrdinal,
                        renderConfiguration.clipNative,
                    )
                } else {
                    null
                }
            val limitsWeight =
                if (limitsActive) {
                    SwiftCore.bakeFalseColorLimitsWeight(
                        renderConfiguration.curveOrdinal,
                        renderConfiguration.clipNative,
                    )
                } else {
                    null
                }
            val limitsReady = limitsPaint != null && limitsWeight != null
            uploadCube(shader, "limitsPaintCube", "limitsPaintSize", limitsPaint, 64)
            uploadCube(shader, "limitsWeightCube", "limitsWeightSize", limitsWeight, 64)
            shader.setFloatUniform("limitsOn", if (limitsReady) 1f else 0f)

            shader.setFloatUniform("deLogRange", renderConfiguration.deLogBlack, renderConfiguration.deLogClip)
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
            return FeedEffectsRenderer(shader)
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

    uniform float peakingOn;
    uniform float3 peakingColor;
    uniform float2 deLogRange;         // core black/clip anchors, normalized code
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

        if (limitsOn > 0.5) {
            color = mix(color, limitsPaint(source), limitsWeight(source));
        }

        if (peakingOn > 0.5) {
            // fine - k*coarse: a sharp edge keeps fine-scale gradient a wide
            // (defocused) edge lacks; both scales cancel on blurred edges.
            float fine = gradMag(src, 1.0);
            float coarse = gradMag(src, 2.6);
            float response = fine - DEFOCUS_REJECTION * coarse;
            float mask = clamp((response - peakingThreshold) * peakingRamp, 0.0, 1.0);
            color = mix(color, peakingColor, mask);
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

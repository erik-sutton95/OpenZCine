package com.opencapture.openzcine

import android.graphics.Bitmap
import android.graphics.BitmapShader
import android.graphics.Canvas
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.RuntimeShader
import android.graphics.Shader
import android.os.Build
import android.util.Log
import androidx.annotation.RequiresApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.drawIntoCanvas
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInRoot
import androidx.compose.ui.unit.dp
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

// Custom GPU liquid-glass treatment for the monitor chrome (OPE-47).
//
// Architecture (matches a classic grab-pass + panel blur):
//
//  1. [GlassBackdrop] is a simple GRAB pass: each feed frame is downscaled
//     once into a double-buffered viewport texture (feed + black surround).
//     No CPU blur, no in-place mutation of the published texture — write to
//     the back buffer, then atomically publish. That is what killed the
//     flickering (decode thread was box-blurring the same bitmap the GPU
//     was sampling).
//  2. Panel shaders sample that grab pass and blur in AGSL (API 33+ FULL).
//     One shared grab, many samplers — never a per-pill screen capture.
//  3. Older devices / demoted chrome use FLAT: a more opaque solid fill with
//     no grab sampling and no fake frost (same policy as pre–iOS 26).

private const val TAG = "ZCGlass"

/**
 * Grab-pass resolution: 1/8 of the viewport (~200×90 on A12). Tiny enough
 * that a 5-tap AGSL frost is cheap; large enough that the upscale is smooth.
 */
private const val GRAB_DOWNSCALE = 8

/** Refraction geometry, dp. */
private const val REFRACTION_BEVEL_DP = 10f
private const val REFRACTION_AMOUNT_DP = 14f

/**
 * AGSL multi-tap frost radius in screen px. At 1/8 grab scale this is ~2–3
 * grab texels — soft glass, not mush.
 */
private const val SHADER_BLUR_SPREAD_DP = 12f

/** Warm glass tint (LiveDesign.glass RGB), translucent so frost shows through. */
private const val GLASS_TINT_R = 0.105f
private const val GLASS_TINT_G = 0.092f
private const val GLASS_TINT_B = 0.073f
private const val GLASS_TINT_A = 0.38f

/**
 * Glass quality tiers.
 *
 * - [FULL]: grab pass + AGSL frost / refraction (API 33+).
 * - [FLAT]: more opaque solid fill — the floor on older systems and after
 *   demote. No grab, no blur stand-in.
 */
enum class GlassTier {
    /** Flat more-opaque chrome fill (older API / demoted / no feed grab). */
    FLAT,

    /** Grab pass + AGSL frost + edge refraction + specular (API 33+). */
    FULL,
}

/**
 * API 33+ → FULL, else → FLAT. Debug [override] (`full`/`flat`/`blur`) can only
 * lower the tier — `"blur"` maps to FLAT (no mid-tier fake frost).
 */
fun resolveTier(sdkInt: Int, override: String? = null): GlassTier {
    val capability = if (sdkInt >= 33) GlassTier.FULL else GlassTier.FLAT
    val requested =
        when (override?.lowercase()) {
            "full" -> GlassTier.FULL
            "flat", "blur" -> GlassTier.FLAT
            else -> capability
        }
    return if (requested.ordinal < capability.ordinal) requested else capability
}

/**
 * Sustained frame-budget detector. When more than [maxOverBudget] of a
 * [window]-frame block exceed [budgetNanos], answers demote-now.
 */
class FrameBudgetWindow(
    private val budgetNanos: Long = 48_000_000L,
    private val window: Int = 240,
    private val maxOverBudget: Int = 24,
    private val warmup: Int = 60,
) {
    private var skipped = 0
    private var seen = 0
    private var overBudget = 0

    fun frame(deltaNanos: Long): Boolean {
        if (skipped < warmup) {
            skipped++
            return false
        }
        seen++
        if (deltaNanos > budgetNanos) overBudget++
        if (seen < window) return false
        val demote = overBudget > maxOverBudget
        seen = 0
        overBudget = 0
        return demote
    }
}

/**
 * Shared **grab pass** — one low-res viewport texture of the live feed
 * (plus black letterbox), rebuilt once per decoded frame.
 *
 * Double-buffered: the decode thread always writes the *back* buffer, then
 * publishes it. The GPU only ever samples the published front, so there is
 * no tear/flicker from in-place mutation or CPU box-blur mid-sample.
 */
class GlassBackdrop {
    private val bilinear = Paint(Paint.FILTER_BITMAP_FLAG)
    private var intermediate: Bitmap? = null
    private val pool = arrayOfNulls<Bitmap>(2)
    private var writeIndex = 0
    private var rootWidth = 0f
    private var rootHeight = 0f
    private var feedRect = RectF()
    private var aspectFill = false

    /**
     * Published grab texture. Stable until the next [submit] finishes; never
     * written after publish.
     */
    @Volatile
    var texture: Bitmap? = null
        private set

    /**
     * Monotonic grab generation. Pills read this in draw so a new grab costs
     * one draw invalidation — no recomposition of the tree beyond invalidation.
     */
    var frame: Int by mutableIntStateOf(0)
        private set

    fun uvScaleX(): Float = texture?.let { it.width / rootWidth } ?: 0f

    fun uvScaleY(): Float = texture?.let { it.height / rootHeight } ?: 0f

    fun overlapsFeed(left: Float, top: Float, right: Float, bottom: Float): Boolean =
        left < feedRect.right &&
            right > feedRect.left &&
            top < feedRect.bottom &&
            bottom > feedRect.top

    /** (Re)configures viewport + feed-zone geometry, in root px. */
    fun setLayout(
        rootWidthPx: Float,
        rootHeightPx: Float,
        feedRectPx: RectF,
        aspectFill: Boolean = false,
    ) {
        synchronized(this) {
            feedRect = feedRectPx
            this.aspectFill = aspectFill
            if (rootWidth == rootWidthPx && rootHeight == rootHeightPx && pool[0] != null) return
            rootWidth = rootWidthPx
            rootHeight = rootHeightPx
            val w = max(1, (rootWidthPx / GRAB_DOWNSCALE).roundToInt())
            val h = max(1, (rootHeightPx / GRAB_DOWNSCALE).roundToInt())
            pool[0] = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
            pool[1] = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
            writeIndex = 0
            texture = null
            frame = 0
        }
    }

    /**
     * Grab pass: composite the feed frame into the back buffer, then publish.
     * Decode-thread only. No CPU blur — panels blur when they sample.
     */
    fun submit(bitmap: Bitmap) {
        synchronized(this) {
            val back = pool[writeIndex] ?: return
            val content =
                glassBackdropContentRect(
                    feedWidth = feedRect.width(),
                    feedHeight = feedRect.height(),
                    sourceWidth = bitmap.width,
                    sourceHeight = bitmap.height,
                    aspectFill = aspectFill,
                ) ?: return
            val contentW = content.width.toFloat()
            val contentH = content.height.toFloat()
            val contentLeft = feedRect.left + content.left
            val contentTop = feedRect.top + content.top
            val sx = back.width / rootWidth
            val sy = back.height / rootHeight

            // Two-step bilinear downsample into the feed rect (letterbox stays black).
            val midW = max(1, (contentW * sx * 4f).roundToInt())
            val midH = max(1, (contentH * sy * 4f).roundToInt())
            val mid =
                intermediate?.takeIf { it.width == midW && it.height == midH }
                    ?: Bitmap.createBitmap(midW, midH, Bitmap.Config.ARGB_8888)
                        .also { intermediate = it }
            Canvas(mid).drawBitmap(
                bitmap,
                null,
                RectF(0f, 0f, midW.toFloat(), midH.toFloat()),
                bilinear,
            )

            val canvas = Canvas(back)
            canvas.drawColor(android.graphics.Color.BLACK)
            val saveCount = canvas.save()
            canvas.clipRect(
                feedRect.left * sx,
                feedRect.top * sy,
                feedRect.right * sx,
                feedRect.bottom * sy,
            )
            canvas.drawBitmap(
                mid,
                null,
                RectF(
                    contentLeft * sx,
                    contentTop * sy,
                    (contentLeft + contentW) * sx,
                    (contentTop + contentH) * sy,
                ),
                bilinear,
            )
            canvas.restoreToCount(saveCount)

            // Publish completed grab; next write goes to the other buffer.
            texture = back
            writeIndex = 1 - writeIndex
            frame++
        }
    }
}

/** Uses the feed renderer's exact pixel-rounded transform for glass sampling. */
internal fun glassBackdropContentRect(
    feedWidth: Float,
    feedHeight: Float,
    sourceWidth: Int,
    sourceHeight: Int,
    aspectFill: Boolean,
): LiveFeedContentRect? =
    liveFeedContentRect(
        containerWidth = feedWidth,
        containerHeight = feedHeight,
        sourceWidth = sourceWidth,
        sourceHeight = sourceHeight,
        aspectFill = aspectFill,
    )

/**
 * Per-screen glass state: active [tier] + shared grab-pass [backdrop].
 */
class MonitorGlass(initialTier: GlassTier) {
    var tier: GlassTier by mutableStateOf(initialTier)
        private set

    val backdrop = GlassBackdrop()

    /** Grab-pass update; no-op when FLAT (no sampling). */
    fun submit(bitmap: Bitmap) {
        if (tier == GlassTier.FULL) backdrop.submit(bitmap)
    }

    /** FULL → FLAT. Opaque fill is the floor. */
    fun demote() {
        if (tier == GlassTier.FLAT) return
        runCatching {
            Log.w(TAG, "sustained frame-budget overrun — degrading glass $tier -> ${GlassTier.FLAT}")
        }
        tier = GlassTier.FLAT
    }
}

/**
 * Glass state for monitor chrome. Null / FLAT → opaque solid fill (no grab).
 */
val LocalMonitorGlass = compositionLocalOf<MonitorGlass?> { null }

/**
 * AGSL panel shader: samples the grab pass, multi-tap blurs, then optionally
 * refracts + adds specular. Blur lives here — never in the grab producer.
 *
 * FULL always enables the lens (refraction uniform > 0).
 */
private val GLASS_SHADER_SRC =
    """
    uniform shader grab;
    uniform float2 size;
    uniform float radius;
    uniform float2 origin;
    uniform float2 uvScale;
    uniform float bevel;
    uniform float refraction;
    uniform float blurSpread;
    uniform float4 tint;

    float roundedBoxSDF(float2 p, float2 halfSize, float r) {
        float2 q = abs(p) - halfSize + r;
        return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
    }

    // 5-tap cross Gaussian of the grab pass (center + 4 axes).
    half3 sampleFrost(float2 screenPx) {
        float2 c = (screenPx + origin) * uvScale;
        float2 s = float2(blurSpread, blurSpread) * uvScale;
        half3 acc = grab.eval(c).rgb * 0.36;
        acc += grab.eval(c + float2(s.x, 0.0)).rgb * 0.16;
        acc += grab.eval(c - float2(s.x, 0.0)).rgb * 0.16;
        acc += grab.eval(c + float2(0.0, s.y)).rgb * 0.16;
        acc += grab.eval(c - float2(0.0, s.y)).rgb * 0.16;
        return acc;
    }

    half4 main(float2 coord) {
        float2 halfSize = size * 0.5;
        float2 p = coord - halfSize;
        float sd = roundedBoxSDF(p, halfSize, radius);
        float t = clamp(1.0 + sd / max(bevel, 0.001), 0.0, 1.0);

        float2 q = abs(p) - halfSize + radius;
        float2 n;
        if (q.x > 0.0 && q.y > 0.0) {
            n = normalize(max(q, 0.001)) * sign(p);
        } else if (q.x > q.y) {
            n = float2(sign(p.x), 0.0);
        } else {
            n = float2(0.0, sign(p.y));
        }

        // Lens: shift sample inward near the rim when refraction > 0.
        float2 samplePx = coord - n * (refraction * t * t);
        half3 bg = sampleFrost(samplePx);

        half lum = dot(bg, half3(0.299, 0.587, 0.114));
        half3 vib = mix(half3(lum), bg, 1.22);
        half3 body = mix(vib, half3(tint.r, tint.g, tint.b), half(tint.a));

        float yNorm = clamp(coord.y / max(size.y, 1.0), 0.0, 1.0);
        float topSpec = pow(1.0 - yNorm, 2.4) * 0.22;
        float edge = exp(-abs(sd) * 0.55) * 0.14 * (1.0 - yNorm * 0.5);
        half3 spec = half3(0.968, 0.937, 0.882) * half(topSpec + edge);

        return half4(body + spec, 1.0);
    }
    """
        .trimIndent()

private val RimHighlight =
    Brush.verticalGradient(
        listOf(
            Color(0.968f, 0.937f, 0.882f, 0.55f),
            Color(0.968f, 0.937f, 0.882f, 0.08f),
        ),
    )

/**
 * Per-pill draw state. Uniforms re-set only when geometry / published grab
 * identity changes — not every fragment.
 */
private class GlassPillNode(useAgsl: Boolean) {
    var origin = Offset.Zero
    val runtime: RuntimeShader? =
        if (useAgsl && Build.VERSION.SDK_INT >= 33) RuntimeShader(GLASS_SHADER_SRC) else null
    val paint = Paint(Paint.FILTER_BITMAP_FLAG or Paint.ANTI_ALIAS_FLAG)
    val matrix = Matrix()
    var shader: BitmapShader? = null
    private var boundTexture: Bitmap? = null
    private var boundOrigin = Offset.Unspecified
    private var boundWidth = -1f
    private var boundHeight = -1f
    private var boundRefract = Float.NaN

    fun rebindNeeded(
        texture: Bitmap,
        width: Float,
        height: Float,
        refract: Float,
    ): Boolean =
        texture !== boundTexture ||
            origin != boundOrigin ||
            width != boundWidth ||
            height != boundHeight ||
            refract != boundRefract

    fun shaderFor(texture: Bitmap): BitmapShader {
        if (texture === boundTexture) shader?.let { return it }
        return BitmapShader(texture, Shader.TileMode.CLAMP, Shader.TileMode.CLAMP)
            .also {
                if (Build.VERSION.SDK_INT >= 33) {
                    it.filterMode = BitmapShader.FILTER_MODE_LINEAR
                }
                shader = it
            }
    }

    fun markBound(texture: Bitmap, width: Float, height: Float, refract: Float) {
        boundTexture = texture
        boundOrigin = origin
        boundWidth = width
        boundHeight = height
        boundRefract = refract
    }
}

/**
 * iOS `liquidGlass` entry point.
 *
 * - FULL (API 33+): AGSL samples the grab pass, blurs + refracts in-shader.
 * - FLAT / no LocalMonitorGlass: more opaque solid fill — no grab, no fake frost.
 */
@Composable
fun Modifier.glass(shape: Shape = ChromeShape): Modifier {
    val glass = LocalMonitorGlass.current
    if (glass == null || glass.tier == GlassTier.FLAT) {
        return background(LiveDesign.glassOpaque, shape)
            .border(1.dp, LiveDesign.hairlineStrong, shape)
    }
    // FULL: grab + AGSL (requires API 33 RuntimeShader).
    val node = remember(glass) { GlassPillNode(useAgsl = true) }
    return onGloballyPositioned { node.origin = it.positionInRoot() }
        .drawBehind { drawGlassPanel(node, glass.backdrop, shape) }
        .border(1.dp, RimHighlight, shape)
}

/**
 * Nested chips inside a glass slab: opaque flat fill (no second grab sample).
 */
fun Modifier.chipGlass(shape: Shape = ChromeShape): Modifier =
    background(LiveDesign.glassOpaque, shape).border(1.dp, LiveDesign.hairline, shape)

private fun DrawScope.drawGlassPanel(
    node: GlassPillNode,
    backdrop: GlassBackdrop,
    shape: Shape,
) {
    val radius =
        if (shape === CircleShape) size.minDimension / 2f
        else min(LiveDesign.CORNER_RADIUS_DP.dp.toPx(), size.minDimension / 2f)
    // Reading frame invalidates draw when a new grab publishes.
    val grabGeneration = backdrop.frame
    val texture = backdrop.texture
    if (grabGeneration <= 0 || texture == null) {
        drawRoundRect(
            color = LiveDesign.glassOpaque,
            cornerRadius = CornerRadius(radius, radius),
        )
        return
    }
    val refractPx = REFRACTION_AMOUNT_DP.dp.toPx()
    if (node.rebindNeeded(texture, size.width, size.height, refractPx)) {
        val source = node.shaderFor(texture)
        val runtime = node.runtime
        if (runtime != null && Build.VERSION.SDK_INT >= 33) {
            bindPanelShader(runtime, node, backdrop, source, radius, refractPx)
        } else {
            // Should not reach: FULL is API 33+ only. Opaque fallback.
            node.paint.shader = null
            node.paint.color =
                android.graphics.Color.argb(
                    (0.90f * 255).toInt(),
                    (0.105f * 255).toInt(),
                    (0.092f * 255).toInt(),
                    (0.073f * 255).toInt(),
                )
        }
        node.markBound(texture, size.width, size.height, refractPx)
    }
    drawIntoCanvas {
        it.nativeCanvas.drawRoundRect(0f, 0f, size.width, size.height, radius, radius, node.paint)
    }
}

@RequiresApi(33)
private fun DrawScope.bindPanelShader(
    runtime: RuntimeShader,
    node: GlassPillNode,
    backdrop: GlassBackdrop,
    source: BitmapShader,
    radius: Float,
    refractPx: Float,
) {
    node.matrix.reset()
    source.setLocalMatrix(node.matrix)
    runtime.setFloatUniform("size", size.width, size.height)
    runtime.setFloatUniform("radius", radius)
    runtime.setFloatUniform("origin", node.origin.x, node.origin.y)
    runtime.setFloatUniform("uvScale", backdrop.uvScaleX(), backdrop.uvScaleY())
    runtime.setFloatUniform("bevel", REFRACTION_BEVEL_DP.dp.toPx())
    runtime.setFloatUniform("refraction", refractPx)
    runtime.setFloatUniform("blurSpread", SHADER_BLUR_SPREAD_DP.dp.toPx())
    runtime.setFloatUniform(
        "tint",
        GLASS_TINT_R,
        GLASS_TINT_G,
        GLASS_TINT_B,
        GLASS_TINT_A,
    )
    runtime.setInputShader("grab", source)
    node.paint.shader = runtime
}

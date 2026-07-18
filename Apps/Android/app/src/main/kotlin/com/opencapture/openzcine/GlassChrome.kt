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
// The rejected library eval (branch task/glass-eval) proved the failure mode
// to avoid: every glass node re-recording the full-screen backdrop into its
// own offscreen layer costs ~4 ms of MAIN-THREAD CPU per node per frame while
// the GPU idles. The structural fix here is ONE shared backdrop, many
// samplers:
//
//  1. [GlassBackdrop] downscales each decoded feed frame into a single tiny
//     viewport texture (visible feed + black surround), produced ONCE per feed
//     frame on the decode thread — no per-node capture anywhere.
//  2. The shared texture is box-blurred once per frame on the decode thread
//     (~20k px at 1/8 scale — microseconds). Pills never re-blur.
//  3. Tier FULL (API 33+): AGSL single-sample + edge refraction + specular
//     rim + warm tint, all on the GPU. One texture fetch per fragment.
//  4. Tier BLUR (API 31–32): sample the pre-blurred texture straight under a
//     light surface fill.
//  5. There is no FLAT tier — BLUR is the floor. Frame-budget overruns may
//     demote FULL → BLUR only.
//  6. [FrameBudgetWindow] auto-degrades FULL → BLUR when frame timing blows
//     the budget for a sustained window — a counter and a threshold only.

private const val TAG = "ZCGlass"

/**
 * Backdrop texture scale: 1/8 of screen (~200×90 on A12). Higher than the
 * original 1/16 so GPU multi-tap / upscale reads as smooth frosted glass
 * rather than blocky color patches, while still keeping the texture tiny.
 */
private const val BACKDROP_DOWNSCALE = 8

/**
 * CPU box-blur for tier BLUR only (FULL blurs on the GPU in AGSL).
 * Radius 2 × 3 separable passes ≈ a soft Gaussian at the 1/8 texture scale.
 */
private const val BLUR_RADIUS = 2
private const val BLUR_PASSES = 3

/** Refraction geometry, dp: the rim band width and the max inward sample displacement. */
private const val REFRACTION_BEVEL_DP = 10f
private const val REFRACTION_AMOUNT_DP = 14f

/**
 * Warm glass tint composited in the FULL AGSL path (matches LiveDesign.glass
 * RGB). Kept lighter than an opaque fill so the blurred feed reads through
 * like iOS liquid glass.
 */
private const val GLASS_TINT_R = 0.105f
private const val GLASS_TINT_G = 0.092f
private const val GLASS_TINT_B = 0.073f
private const val GLASS_TINT_A = 0.38f

/**
 * Glass quality tiers, ascending. **BLUR is the floor** — there is no flat
 * solid-fill tier. [resolveTier] picks the platform ceiling; [MonitorGlass.demote]
 * may drop FULL → BLUR under sustained frame-budget overruns, never below BLUR.
 */
enum class GlassTier {
    /**
     * Shared pre-blurred backdrop under a light surface fill (minimum Android
     * chrome treatment on every API level we ship).
     */
    BLUR,

    /** Shared backdrop + per-pill AGSL edge refraction (needs `RuntimeShader`, API 33). */
    FULL,
}

/**
 * The tier this device runs: API 33+ → FULL, else → BLUR (the floor). Optional
 * debug [override] (`full`/`blur`, the `zc.glass.tier` intent extra) can only
 * lower the tier — FULL needs `RuntimeShader`. Legacy `"flat"` overrides are
 * treated as BLUR.
 */
fun resolveTier(sdkInt: Int, override: String? = null): GlassTier {
    val capability = if (sdkInt >= 33) GlassTier.FULL else GlassTier.BLUR
    val requested =
        when (override?.lowercase()) {
            "full" -> GlassTier.FULL
            "blur", "flat" -> GlassTier.BLUR
            else -> capability
        }
    return if (requested.ordinal < capability.ordinal) requested else capability
}

/**
 * Sustained frame-budget detector: feed every frame interval, and when more
 * than [maxOverBudget] of a [window]-frame block exceed [budgetNanos] (i.e.
 * the block's p90 is worse than the budget), it answers demote-now.
 * The first [warmup] frames are ignored so app startup jank never demotes.
 *
 * ponytail: a counter + threshold, not a jank framework — no percentile
 * buckets, no re-promotion; upgrade to JankStats if this ever needs nuance.
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

    /** Records one frame interval; true means the budget was blown for a full window. */
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
 * Shared blurred backdrop texture, rebuilt once per feed frame: the decoded
 * frame is downsampled hard (two bilinear steps, ≤4× each, to avoid
 * shimmer), composited over black at the feed renderer's exact fit/fill
 * screen rect (so letterbox and crop are IN the texture),
 * then box-blurred at the tiny resolution. Total cost is a fraction of a
 * millisecond on the decode thread; the render side only ever samples.
 *
 * ONE texture, ONE [BitmapShader], mutated in place: keeping the shader
 * object (and its uniforms/matrix) untouched across frames means a pill's
 * per-frame re-record replays a CACHED native shader instead of rebuilding
 * it — rebinding a fresh shader per frame is exactly the per-node cost the
 * rejected library died of. The RenderThread may sample the bitmap while the
 * decode thread rewrites it; a torn row inside a 16×-downscaled blur is
 * invisible, and the pixel buffer itself is stable (no realloc), so the race
 * is benign. ponytail: revisit with a double buffer only if visible shimmer
 * ever shows up.
 */
class GlassBackdrop {
    private val bilinear = Paint(Paint.FILTER_BITMAP_FLAG)
    private var canvas: Canvas? = null
    private var intermediate: Bitmap? = null
    private var pixels = IntArray(0)
    private var scratch = IntArray(0)
    private var rootWidth = 0f
    private var rootHeight = 0f
    private var feedRect = RectF()
    private var aspectFill = false

    /**
     * The shared texture. Each glass pill wraps it in its own [BitmapShader]
     * (all wrappers share the one GPU upload, keyed by the bitmap), so
     * per-pill matrices/uniforms never dirty each other.
     */
    var texture: Bitmap? = null
        private set

    /**
     * Count of textures produced (0 before the first). Pills read this in
     * their draw phase, so a new backdrop costs one draw invalidation per
     * pill — no recomposition, no layout, no shader rebuild.
     */
    var frame: Int by mutableIntStateOf(0)
        private set

    /** Horizontal backdrop-texels-per-screen-px factor (0 until configured). */
    fun uvScaleX(): Float = texture?.let { it.width / rootWidth } ?: 0f

    /** Vertical backdrop-texels-per-screen-px factor (0 until configured). */
    fun uvScaleY(): Float = texture?.let { it.height / rootHeight } ?: 0f

    /** True when the rect ([left],[top])–([right],[bottom]) overlaps the feed zone. */
    fun overlapsFeed(left: Float, top: Float, right: Float, bottom: Float): Boolean =
        left < feedRect.right &&
            right > feedRect.left &&
            top < feedRect.bottom &&
            bottom > feedRect.top

    /** (Re)configures viewport + feed-zone geometry, in root px. Idempotent per layout. */
    fun setLayout(
        rootWidthPx: Float,
        rootHeightPx: Float,
        feedRectPx: RectF,
        aspectFill: Boolean = false,
    ) {
        synchronized(this) {
            feedRect = feedRectPx
            this.aspectFill = aspectFill
            if (rootWidth == rootWidthPx && rootHeight == rootHeightPx && texture != null) return
            rootWidth = rootWidthPx
            rootHeight = rootHeightPx
            val w = max(1, (rootWidthPx / BACKDROP_DOWNSCALE).roundToInt())
            val h = max(1, (rootHeightPx / BACKDROP_DOWNSCALE).roundToInt())
            val fresh = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
            texture = fresh
            canvas = Canvas(fresh)
            pixels = IntArray(w * h)
            scratch = IntArray(w * h)
            frame = 0
        }
    }

    /**
     * Rebuilds the backdrop from a decoded feed [bitmap]. Decode-thread only.
     *
     * @param bakeCpuBlur when true (tier BLUR), run the separable box blur on
     *   the CPU. FULL leaves the texture sharp and blurs on the GPU in AGSL.
     */
    fun submit(bitmap: Bitmap, bakeCpuBlur: Boolean = true) {
        synchronized(this) {
            val target = texture ?: return
            val canvas = this.canvas ?: return
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

            // Two-step downsample: frame → ~4× the final region → backdrop.
            // Bilinear GPU-accelerated draws (FILTER_BITMAP_FLAG) — no CPU
            // pixel loops for the scale itself.
            val sx = uvScaleX()
            val sy = uvScaleY()
            val midW = max(1, (contentW * sx * 4f).roundToInt())
            val midH = max(1, (contentH * sy * 4f).roundToInt())
            val mid =
                intermediate?.takeIf { it.width == midW && it.height == midH }
                    ?: Bitmap.createBitmap(midW, midH, Bitmap.Config.ARGB_8888)
                        .also { intermediate = it }
            Canvas(mid).drawBitmap(bitmap, null, RectF(0f, 0f, midW.toFloat(), midH.toFloat()), bilinear)

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
            if (bakeCpuBlur) blur(target)
            frame++
        }
    }

    // ponytail: CPU box blur at 1/8 is ~20k pixels — a fraction of a
    // millisecond. Cheaper than per-pill multi-tap AGSL on weak GPUs (A12).
    private fun blur(bitmap: Bitmap) {
        val w = bitmap.width
        val h = bitmap.height
        bitmap.getPixels(pixels, 0, w, 0, 0, w, h)
        repeat(BLUR_PASSES) {
            boxBlur(pixels, scratch, w, h, horizontal = true)
            boxBlur(scratch, pixels, w, h, horizontal = false)
        }
        bitmap.setPixels(pixels, 0, w, 0, 0, w, h)
    }

    /** One separable box-blur pass (radius [BLUR_RADIUS], clamped edges, opaque RGB). */
    private fun boxBlur(src: IntArray, dst: IntArray, w: Int, h: Int, horizontal: Boolean) {
        val outer = if (horizontal) h else w
        val inner = if (horizontal) w else h
        val div = 2 * BLUR_RADIUS + 1
        for (o in 0 until outer) {
            fun idx(i: Int) = if (horizontal) o * w + i else i * w + o
            var r = 0
            var g = 0
            var b = 0
            for (k in -BLUR_RADIUS..BLUR_RADIUS) {
                val c = src[idx(k.coerceIn(0, inner - 1))]
                r += (c ushr 16) and 0xFF
                g += (c ushr 8) and 0xFF
                b += c and 0xFF
            }
            for (i in 0 until inner) {
                dst[idx(i)] =
                    (0xFF shl 24) or ((r / div) shl 16) or ((g / div) shl 8) or (b / div)
                val drop = src[idx((i - BLUR_RADIUS).coerceIn(0, inner - 1))]
                val add = src[idx((i + BLUR_RADIUS + 1).coerceIn(0, inner - 1))]
                r += ((add ushr 16) and 0xFF) - ((drop ushr 16) and 0xFF)
                g += ((add ushr 8) and 0xFF) - ((drop ushr 8) and 0xFF)
                b += (add and 0xFF) - (drop and 0xFF)
            }
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
 * Per-screen glass state: the active [tier] plus the shared [backdrop].
 * Created once by the monitor screen and provided through
 * [LocalMonitorGlass].
 */
class MonitorGlass(initialTier: GlassTier) {
    /** Active tier; [demote] may drop FULL → BLUR, never re-promotes, never below BLUR. */
    var tier: GlassTier by mutableStateOf(initialTier)
        private set

    /** The shared blurred backdrop all glass pills sample. */
    val backdrop = GlassBackdrop()

    /**
     * Feeds one decoded frame into the backdrop. FULL and BLUR both bake a
     * small CPU box-blur once per frame (~20k px) so the AGSL path stays a
     * single GPU texture fetch + refraction.
     */
    fun submit(bitmap: Bitmap) {
        backdrop.submit(bitmap, bakeCpuBlur = true)
    }

    /** Drops FULL → BLUR after a sustained frame-budget overrun. BLUR is the floor. */
    fun demote() {
        if (tier == GlassTier.BLUR) return
        // runCatching: unit tests stub android.util.Log.
        runCatching {
            Log.w(TAG, "sustained frame-budget overrun — degrading glass $tier -> ${GlassTier.BLUR}")
        }
        tier = GlassTier.BLUR
    }
}

/**
 * Glass state for the monitor chrome. Null (screens without a feed backdrop)
 * still paints the BLUR-floor surface tint — never an unfrosted solid flat.
 */
val LocalMonitorGlass = compositionLocalOf<MonitorGlass?> { null }

/**
 * AGSL liquid-glass pill shader (tier FULL) — GPU path, one texture fetch:
 *
 *  1. Single sample of the shared pre-blurred backdrop (blur is baked once
 *     per feed frame; FILTER_MODE_LINEAR softens the 1/8 upscale).
 *  2. Convex-lens edge refraction near the rim (iOS liquid-glass bulge).
 *  3. Warm translucent tint + top specular + edge highlight, composited
 *     in-shader so Compose never paints a heavy opaque fill on top.
 *
 * Uniforms: `size`/`radius` pill local px, `origin` pill top-left in root px,
 * `uvScale` root px → backdrop texels, `bevel`/`refraction` rim geometry px,
 * `tint` RGBA warm glass fill.
 */
private val GLASS_SHADER_SRC =
    """
    uniform shader backdrop;
    uniform float2 size;
    uniform float radius;
    uniform float2 origin;
    uniform float2 uvScale;
    uniform float bevel;
    uniform float refraction;
    uniform float4 tint;

    float roundedBoxSDF(float2 p, float2 halfSize, float r) {
        float2 q = abs(p) - halfSize + r;
        return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
    }

    half4 main(float2 coord) {
        float2 halfSize = size * 0.5;
        float2 p = coord - halfSize;
        float sd = roundedBoxSDF(p, halfSize, radius);

        // Lens profile: 0 interior → 1 at the rim.
        float t = clamp(1.0 + sd / bevel, 0.0, 1.0);

        // Outward normal for refraction.
        float2 q = abs(p) - halfSize + radius;
        float2 n;
        if (q.x > 0.0 && q.y > 0.0) {
            n = normalize(max(q, 0.001)) * sign(p);
        } else if (q.x > q.y) {
            n = float2(sign(p.x), 0.0);
        } else {
            n = float2(0.0, sign(p.y));
        }

        // Inward sample shift near the rim (glass bulge).
        float2 samplePx = coord - n * (refraction * t * t);
        half3 bg = backdrop.eval((samplePx + origin) * uvScale).rgb;

        // Mild vibrancy so the warm tint doesn't grey out the feed.
        half lum = dot(bg, half3(0.299, 0.587, 0.114));
        half3 vib = mix(half3(lum), bg, 1.22);

        // Translucent warm glass over the frosted feed (iOS liquid-glass body).
        half3 body = mix(vib, half3(tint.r, tint.g, tint.b), half(tint.a));

        // Top specular: bright warm rim falling off toward the bottom.
        float yNorm = clamp(coord.y / max(size.y, 1.0), 0.0, 1.0);
        float topSpec = pow(1.0 - yNorm, 2.4) * 0.22;
        // Edge caustic: thin highlight along the SDF boundary.
        float edge = exp(-abs(sd) * 0.55) * 0.14 * (1.0 - yNorm * 0.5);
        half3 spec = half3(0.968, 0.937, 0.882) * half(topSpec + edge);

        return half4(body + spec, 1.0);
    }
    """
        .trimIndent()

/**
 * Top-weighted rim highlight (stolen from the eval — it reads better than
 * the uniform hairline): bright warm-white at the top edge fading to nearly
 * nothing at the bottom. Used as the stroke on BLUR/FULL pills.
 */
private val RimHighlight =
    Brush.verticalGradient(
        listOf(
            Color(0.968f, 0.937f, 0.882f, 0.55f),
            Color(0.968f, 0.937f, 0.882f, 0.08f),
        ),
    )

/** Lighter surface fill for tier BLUR so the baked backdrop still shows. */
private val BlurSurfaceTint = Color(GLASS_TINT_R, GLASS_TINT_G, GLASS_TINT_B, 0.42f)

/**
 * Per-call-site draw state: the pill's root position, reusable paint
 * objects, and the last-bound geometry. Uniforms/matrices are only re-set
 * when geometry actually changed — every set dirties the shader's native
 * instance and forces a per-frame rebuild otherwise.
 */
private class GlassPillNode(refract: Boolean) {
    var origin = Offset.Zero
    val runtime: RuntimeShader? =
        if (refract && Build.VERSION.SDK_INT >= 33) RuntimeShader(GLASS_SHADER_SRC) else null
    val paint = Paint(Paint.FILTER_BITMAP_FLAG or Paint.ANTI_ALIAS_FLAG)
    val matrix = Matrix()
    var shader: BitmapShader? = null
    private var boundTexture: Bitmap? = null
    private var boundOrigin = Offset.Unspecified
    private var boundWidth = -1f
    private var boundHeight = -1f

    /** True when the shader binding must be refreshed for this draw. */
    fun rebindNeeded(texture: Bitmap, width: Float, height: Float): Boolean =
        texture !== boundTexture ||
            origin != boundOrigin ||
            width != boundWidth ||
            height != boundHeight

    /** This node's own [BitmapShader] over the shared [texture]. */
    fun shaderFor(texture: Bitmap): BitmapShader {
        if (texture === boundTexture) shader?.let { return it }
        return BitmapShader(texture, Shader.TileMode.CLAMP, Shader.TileMode.CLAMP)
            .also {
                if (Build.VERSION.SDK_INT >= 33) {
                    // Sampling through the AGSL lens bypasses the paint's filter
                    // flag; without this the 16× upscale is blocky nearest-neighbor.
                    it.filterMode = BitmapShader.FILTER_MODE_LINEAR
                }
                shader = it
            }
    }

    fun markBound(texture: Bitmap, width: Float, height: Float) {
        boundTexture = texture
        boundOrigin = origin
        boundWidth = width
        boundHeight = height
    }
}

/**
 * iOS `liquidGlass` equivalent — the single entry point for chrome glass
 * styling (mirrors `ios/Runner/DesignShared.swift`), tiered by
 * [MonitorGlass.tier]:
 *
 * - FULL: shared pre-blurred backdrop + AGSL refraction/specular/tint on the
 *   GPU (one texture fetch per fragment). Tint is in-shader so Compose never
 *   paints a heavy opaque fill on top of the frost.
 * - BLUR (floor): shared pre-blurred backdrop under a light surface fill + rim.
 *   Also used when no [LocalMonitorGlass] is provided (no feed to sample).
 *
 * There is no solid-fill FLAT tier.
 *
 * All drawing stays inside the pill geometry (a native rounded-rect fill),
 * so the glass never repaints outside its bounds and the zone-frame tap
 * targets are untouched.
 */
@Composable
fun Modifier.glass(shape: Shape = ChromeShape): Modifier {
    val glass = LocalMonitorGlass.current
    // No feed backdrop (settings/media/etc.): still the BLUR-floor surface,
    // never an unfrosted opaque solid.
    if (glass == null) {
        return background(BlurSurfaceTint, shape).border(1.dp, RimHighlight, shape)
    }
    val tier = glass.tier
    val node = remember(glass, tier) { GlassPillNode(refract = tier == GlassTier.FULL) }
    val liquid = tier == GlassTier.FULL
    return onGloballyPositioned { node.origin = it.positionInRoot() }
        .drawBehind { drawGlassBackdrop(node, glass.backdrop, shape, liquid) }
        .then(
            // FULL composites tint in AGSL; BLUR still needs a translucent
            // surface so letterbox (black) pills don't look empty.
            if (liquid) {
                Modifier
            } else {
                Modifier.background(BlurSurfaceTint, shape)
            },
        )
        .border(1.dp, RimHighlight, shape)
}

/**
 * Glass for chips nested INSIDE a glass slab (the info deck's readout
 * capsules): BLUR-floor tint only, not a second refracting layer. Matches
 * iOS nested chips (tinted overlays on the slab, not stacked glass) and
 * keeps the AGSL node count at the slab level.
 */
fun Modifier.chipGlass(shape: Shape = ChromeShape): Modifier =
    background(BlurSurfaceTint, shape).border(1.dp, LiveDesign.hairline, shape)

/**
 * Draws the shared backdrop clipped to the pill's rounded rect. Reading
 * [GlassBackdrop.frame] here means each new backdrop invalidates draw only.
 *
 * ponytail: chrome uses exactly two shapes (capsule / 16dp rounded rect), so
 * the corner radius is resolved by shape identity — generalize via
 * Shape.createOutline if a third ever appears.
 */
private fun DrawScope.drawGlassBackdrop(
    node: GlassPillNode,
    backdrop: GlassBackdrop,
    shape: Shape,
    liquid: Boolean,
) {
    val radius =
        if (shape === CircleShape) size.minDimension / 2f
        else min(LiveDesign.CORNER_RADIUS_DP.dp.toPx(), size.minDimension / 2f)
    val texture = backdrop.texture
    // Until the first feed frame lands, paint the warm glass tint so pills
    // aren't hollow. FULL never puts an opaque Compose fill on top of the
    // AGSL pass (that killed the liquid look), so this is the only fallback.
    if (backdrop.frame <= 0 || texture == null) {
        drawRoundRect(
            color = BlurSurfaceTint,
            cornerRadius =
                androidx.compose.ui.geometry.CornerRadius(radius, radius),
        )
        return
    }
    if (node.rebindNeeded(texture, size.width, size.height)) {
        val source = node.shaderFor(texture)
        val runtime = node.runtime
        if (liquid && Build.VERSION.SDK_INT >= 33 && runtime != null) {
            // FULL: GPU multi-tap blur + refraction + tint for every pill,
            // including letterbox chrome (samples black + warm tint → still
            // reads as glass, keeps one shader path).
            setLiquidGlassUniforms(runtime, node, backdrop, source, radius)
        } else {
            // Tier BLUR: map the pre-blurred backdrop straight into pill space.
            node.matrix.setScale(1f / backdrop.uvScaleX(), 1f / backdrop.uvScaleY())
            node.matrix.postTranslate(-node.origin.x, -node.origin.y)
            source.setLocalMatrix(node.matrix)
            node.paint.shader = source
        }
        node.markBound(texture, size.width, size.height)
    }
    drawIntoCanvas {
        it.nativeCanvas.drawRoundRect(0f, 0f, size.width, size.height, radius, radius, node.paint)
    }
}

/** Tier FULL only: binds geometry + backdrop to the AGSL liquid-glass lens. */
@RequiresApi(33)
private fun DrawScope.setLiquidGlassUniforms(
    runtime: RuntimeShader,
    node: GlassPillNode,
    backdrop: GlassBackdrop,
    source: BitmapShader,
    radius: Float,
) {
    // Identity matrix: AGSL maps root px → backdrop texels itself.
    node.matrix.reset()
    source.setLocalMatrix(node.matrix)
    runtime.setFloatUniform("size", size.width, size.height)
    runtime.setFloatUniform("radius", radius)
    runtime.setFloatUniform("origin", node.origin.x, node.origin.y)
    runtime.setFloatUniform("uvScale", backdrop.uvScaleX(), backdrop.uvScaleY())
    runtime.setFloatUniform("bevel", REFRACTION_BEVEL_DP.dp.toPx())
    runtime.setFloatUniform("refraction", REFRACTION_AMOUNT_DP.dp.toPx())
    runtime.setFloatUniform(
        "tint",
        GLASS_TINT_R,
        GLASS_TINT_G,
        GLASS_TINT_B,
        GLASS_TINT_A,
    )
    runtime.setInputShader("backdrop", source)
    node.paint.shader = runtime
}

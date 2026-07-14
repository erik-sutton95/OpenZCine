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
//  1. [GlassBackdrop] turns each decoded feed frame into a single tiny
//     blurred texture covering the whole viewport (feed + black letterbox),
//     produced ONCE per feed frame on the decode thread — no per-node
//     capture anywhere.
//  2. Every glass pill samples that shared texture at screen-mapped UVs:
//     tier FULL adds an AGSL edge-refraction lens (API 33+), tier BLUR draws
//     the pre-blurred texture straight (the blur is baked into the texture,
//     so no RenderEffect is even needed), tier FLAT is the original
//     hand-rolled translucent fill.
//  3. [FrameBudgetWindow] auto-degrades one tier when frame timing blows the
//     budget for a sustained window — a counter and a threshold, nothing more.

private const val TAG = "ZCGlass"

/** Backdrop texture scale: 1/16 of screen resolution (~100×45 px on the A12 floor device). */
private const val BACKDROP_DOWNSCALE = 16

/** Box-blur radius (backdrop texels ≈ 16 screen px each) and pass count (2 ≈ tent kernel). */
private const val BLUR_RADIUS = 1
private const val BLUR_PASSES = 2

/** Refraction geometry, dp: the rim band width and the max inward sample displacement. */
private const val REFRACTION_BEVEL_DP = 8f
private const val REFRACTION_AMOUNT_DP = 12f

/**
 * Glass quality tiers, ascending. [resolveTier] picks the platform ceiling;
 * [MonitorGlass.demote] steps down one tier under sustained frame-budget
 * overruns.
 */
enum class GlassTier {
    /** Hand-rolled translucent fill + hairline — the original treatment, zero extra cost. */
    FLAT,

    /** Shared pre-blurred backdrop under the pill fill, no refraction. */
    BLUR,

    /** Shared backdrop + per-pill AGSL edge refraction (needs `RuntimeShader`, API 33). */
    FULL,
}

/**
 * The tier this device runs: platform capability (API 33+ FULL, 31–32 BLUR,
 * below FLAT) clamped by an optional debug [override] (`full`/`blur`/`flat`,
 * the `zc.glass.tier` intent extra). The override can only lower the tier —
 * FULL physically needs `RuntimeShader`.
 *
 * BLUR would technically run on API 29 (it is just a bitmap draw), but
 * devices that old are also the weakest; keeping them on FLAT skips the
 * per-frame backdrop production entirely.
 */
fun resolveTier(sdkInt: Int, override: String? = null): GlassTier {
    val capability =
        when {
            sdkInt >= 33 -> GlassTier.FULL
            sdkInt >= 31 -> GlassTier.BLUR
            else -> GlassTier.FLAT
        }
    val requested =
        when (override?.lowercase()) {
            "full" -> GlassTier.FULL
            "blur" -> GlassTier.BLUR
            "flat" -> GlassTier.FLAT
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
 * shimmer), composited over black at its aspect-fit screen rect (so the
 * letterbox is IN the texture — pills over pure black sample the same map),
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
    fun setLayout(rootWidthPx: Float, rootHeightPx: Float, feedRectPx: RectF) {
        synchronized(this) {
            feedRect = feedRectPx
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

    /** Rebuilds the backdrop from a decoded feed [bitmap]. Decode-thread only. */
    fun submit(bitmap: Bitmap) {
        synchronized(this) {
            val target = texture ?: return
            val canvas = this.canvas ?: return
            // Aspect-fit rect of the frame inside the feed zone (same math as
            // LiveFeedView), in root px.
            val scale = min(feedRect.width() / bitmap.width, feedRect.height() / bitmap.height)
            val fitW = bitmap.width * scale
            val fitH = bitmap.height * scale
            val fitLeft = feedRect.left + (feedRect.width() - fitW) / 2f
            val fitTop = feedRect.top + (feedRect.height() - fitH) / 2f

            // Two-step downsample: frame → ~4× the final region → backdrop.
            val sx = uvScaleX()
            val sy = uvScaleY()
            val midW = max(1, (fitW * sx * 4f).roundToInt())
            val midH = max(1, (fitH * sy * 4f).roundToInt())
            val mid =
                intermediate?.takeIf { it.width == midW && it.height == midH }
                    ?: Bitmap.createBitmap(midW, midH, Bitmap.Config.ARGB_8888)
                        .also { intermediate = it }
            Canvas(mid).drawBitmap(bitmap, null, RectF(0f, 0f, midW.toFloat(), midH.toFloat()), bilinear)

            canvas.drawColor(android.graphics.Color.BLACK)
            canvas.drawBitmap(
                mid,
                null,
                RectF(fitLeft * sx, fitTop * sy, (fitLeft + fitW) * sx, (fitTop + fitH) * sy),
                bilinear,
            )
            blur(target)
            frame++
        }
    }

    // ponytail: CPU box blur — at 1/16 resolution this is ~4.5k pixels, a few
    // microseconds per frame; a GPU RenderEffect pass would cost more in
    // layer/readback plumbing than it saves.
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

/**
 * Per-screen glass state: the active [tier] plus the shared [backdrop].
 * Created once by the monitor screen and provided through
 * [LocalMonitorGlass].
 */
class MonitorGlass(initialTier: GlassTier) {
    /** Active tier; drops via [demote], never re-promotes within a process. */
    var tier: GlassTier by mutableStateOf(initialTier)
        private set

    /** The shared blurred backdrop all glass pills sample. */
    val backdrop = GlassBackdrop()

    /** Feeds one decoded frame into the backdrop; free when the tier is FLAT. */
    fun submit(bitmap: Bitmap) {
        if (tier != GlassTier.FLAT) backdrop.submit(bitmap)
    }

    /** Steps down one tier after a sustained frame-budget overrun. */
    fun demote() {
        if (tier == GlassTier.FLAT) return
        val downgraded = GlassTier.entries[tier.ordinal - 1]
        Log.w(TAG, "sustained frame-budget overrun — degrading glass $tier -> $downgraded")
        tier = downgraded
    }
}

/**
 * Glass state for the monitor chrome. Null (the default, and every screen
 * that never provides it) keeps [glass] on the hand-rolled FLAT treatment.
 */
val LocalMonitorGlass = compositionLocalOf<MonitorGlass?> { null }

/**
 * AGSL liquid-glass pill shader (tier FULL): samples the shared blurred
 * backdrop at screen-mapped UVs and bends the samples near the rim like a
 * convex lens edge — the piece of the rejected library eval that genuinely
 * read closer to iOS.
 *
 * Uniforms: `size`/`radius` describe the pill in local px, `origin` is the
 * pill's top-left in root px, `uvScale` maps root px → backdrop texels,
 * `bevel` is the rim band width and `refraction` the max inward sample
 * displacement (both px). The smoky surface tint and the rim highlight are
 * composited on top in Compose, shared with tier BLUR.
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

    // Signed distance to a rounded rect centred at the origin (negative inside).
    float roundedBoxSDF(float2 p, float2 halfSize, float r) {
        float2 q = abs(p) - halfSize + r;
        return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
    }

    half4 main(float2 coord) {
        float2 halfSize = size * 0.5;
        float2 p = coord - halfSize;
        float sd = roundedBoxSDF(p, halfSize, radius);

        // Lens profile: 0 in the interior, ramping quadratically to 1 at the rim.
        float t = clamp(1.0 + sd / bevel, 0.0, 1.0);

        // Outward normal: exact in the corner circles, axis-aligned on the
        // straight edges (q picks the nearest edge).
        float2 q = abs(p) - halfSize + radius;
        float2 n;
        if (q.x > 0.0 && q.y > 0.0) {
            n = normalize(max(q, 0.001)) * sign(p);
        } else if (q.x > q.y) {
            n = float2(sign(p.x), 0.0);
        } else {
            n = float2(0.0, sign(p.y));
        }

        // Displace the sample inward near the rim: the interior content
        // stretches out to the edge, reading as a glass bulge.
        float2 sample = coord - n * (refraction * t * t);
        half4 bg = backdrop.eval((sample + origin) * uvScale);

        // Mild vibrancy: the smoky surface tint on top mutes color, so nudge
        // saturation back up — never past the iOS reference's restraint.
        half lum = dot(bg.rgb, half3(0.299, 0.587, 0.114));
        half3 vib = mix(half3(lum), bg.rgb, 1.25);
        return half4(vib, 1.0);
    }
    """
        .trimIndent()

/**
 * Top-weighted rim highlight (stolen from the eval — it reads better than
 * the uniform hairline): bright warm-white at the top edge fading to nearly
 * nothing at the bottom.
 */
private val RimHighlight =
    Brush.verticalGradient(
        listOf(
            Color(0.968f, 0.937f, 0.882f, 0.45f),
            Color(0.968f, 0.937f, 0.882f, 0.06f),
        ),
    )

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
 * - FULL: AGSL edge refraction over the shared backdrop, smoky surface fill,
 *   top-weighted rim highlight.
 * - BLUR: the shared pre-blurred backdrop straight under the same fill+rim.
 * - FLAT (and any screen without [LocalMonitorGlass]): the original
 *   hand-rolled fill + uniform hairline.
 *
 * All drawing stays inside the pill geometry (a native rounded-rect fill),
 * so the glass never repaints outside its bounds and the zone-frame tap
 * targets are untouched.
 */
@Composable
fun Modifier.glass(shape: Shape = ChromeShape): Modifier {
    val glass = LocalMonitorGlass.current
    val tier = glass?.tier ?: GlassTier.FLAT
    if (glass == null || tier == GlassTier.FLAT) {
        return background(LiveDesign.glass, shape).border(1.dp, LiveDesign.hairline, shape)
    }
    val node = remember(glass, tier) { GlassPillNode(refract = tier == GlassTier.FULL) }
    return onGloballyPositioned { node.origin = it.positionInRoot() }
        .drawBehind { drawGlassBackdrop(node, glass.backdrop, shape) }
        .background(LiveDesign.glass, shape)
        .border(1.dp, RimHighlight, shape)
}

/**
 * Glass for chips nested INSIDE a glass slab (the info deck's readout
 * capsules): always the flat treatment. Matches iOS, where nested chips are
 * tinted overlays on the slab, not stacked glass — and it keeps the
 * refracting-node count at the slab level (6 nodes, not 10).
 */
fun Modifier.chipGlass(shape: Shape = ChromeShape): Modifier =
    background(LiveDesign.glass, shape).border(1.dp, LiveDesign.hairline, shape)

/**
 * Draws the shared backdrop clipped to the pill's rounded rect. Reading
 * [GlassBackdrop.frame] here means each new backdrop invalidates draw only.
 *
 * ponytail: chrome uses exactly two shapes (capsule / 16dp rounded rect), so
 * the corner radius is resolved by shape identity — generalize via
 * Shape.createOutline if a third ever appears.
 */
private fun DrawScope.drawGlassBackdrop(node: GlassPillNode, backdrop: GlassBackdrop, shape: Shape) {
    if (backdrop.frame <= 0) return
    val texture = backdrop.texture ?: return
    val radius =
        if (shape === CircleShape) size.minDimension / 2f
        else min(LiveDesign.CORNER_RADIUS_DP.dp.toPx(), size.minDimension / 2f)
    if (node.rebindNeeded(texture, size.width, size.height)) {
        val source = node.shaderFor(texture)
        val runtime = node.runtime
        // Pills entirely over the letterbox (side rails, capture strip on
        // tall feeds) skip the AGSL lens: refracting near-black is visually
        // identical to sampling it straight (judged by eye on the A12), and
        // it keeps the per-frame runtime-effect count at the pills actually
        // over the image.
        val overFeed =
            backdrop.overlapsFeed(
                node.origin.x,
                node.origin.y,
                node.origin.x + size.width,
                node.origin.y + size.height,
            )
        if (Build.VERSION.SDK_INT >= 33 && runtime != null && overFeed) {
            setRefractionUniforms(runtime, node, backdrop, source, radius)
        } else {
            // Tier BLUR (and letterbox pills on FULL): map the backdrop
            // straight into pill-local space.
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

/** Tier FULL only: binds this frame's geometry + backdrop to the AGSL lens. */
@RequiresApi(33)
private fun DrawScope.setRefractionUniforms(
    runtime: RuntimeShader,
    node: GlassPillNode,
    backdrop: GlassBackdrop,
    source: BitmapShader,
    radius: Float,
) {
    runtime.setFloatUniform("size", size.width, size.height)
    runtime.setFloatUniform("radius", radius)
    runtime.setFloatUniform("origin", node.origin.x, node.origin.y)
    runtime.setFloatUniform("uvScale", backdrop.uvScaleX(), backdrop.uvScaleY())
    runtime.setFloatUniform("bevel", REFRACTION_BEVEL_DP.dp.toPx())
    runtime.setFloatUniform("refraction", REFRACTION_AMOUNT_DP.dp.toPx())
    runtime.setInputShader("backdrop", source)
    node.paint.shader = runtime
}

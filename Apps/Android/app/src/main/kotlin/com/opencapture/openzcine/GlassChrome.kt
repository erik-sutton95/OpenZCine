package com.opencapture.openzcine

import android.os.Build
import android.util.Log
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.shape.CornerBasedShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.unit.dp
import com.kyant.backdrop.backdrops.LayerBackdrop
import com.kyant.backdrop.drawBackdrop
import com.kyant.backdrop.effects.blur
import com.kyant.backdrop.effects.lens
import com.kyant.backdrop.effects.vibrancy
import com.kyant.backdrop.highlight.Highlight

// Liquid glass via Kyant0/AndroidLiquidGlass (io.github.kyant0:backdrop).
//
// 1:1 with the library catalog pattern:
//   • Parent content records into a LayerBackdrop (Modifier.layerBackdrop).
//   • Glass pills use Modifier.drawBackdrop { vibrancy(); blur(); lens() }.
//   • Effect order is color-filter → blur → lens (library requirement).
//
// Older / demoted devices: FLAT more-opaque fill — no fake frost.
// See https://github.com/Kyant0/AndroidLiquidGlass and
// https://kyant.gitbook.io/backdrop

private const val TAG = "ZCGlass"

/**
 * Glass quality tiers.
 *
 * - [FULL]: Kyant layer-backdrop + blur + lens (API 33+ RuntimeShader lens).
 * - [FLAT]: more opaque solid fill (older API / demoted / no layer backdrop).
 */
enum class GlassTier {
    FLAT,
    FULL,
}

/**
 * API 33+ → FULL (lens needs RuntimeShader). Else → FLAT.
 * Debug override `zc.glass.tier` can only lower; legacy `"blur"` → FLAT.
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
 * Sustained frame-budget detector: demote FULL → FLAT under sustained jank.
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
 * Monitor glass session: tier + Kyant [LayerBackdrop] for chrome sampling.
 *
 * Create the backdrop with [com.kyant.backdrop.backdrops.rememberLayerBackdrop]
 * and attach it to the live feed (or full monitor content) via
 * [com.kyant.backdrop.backdrops.layerBackdrop].
 */
class MonitorGlass(
    initialTier: GlassTier,
    val layerBackdrop: LayerBackdrop? = null,
) {
    var tier: GlassTier by mutableStateOf(initialTier)
        private set

    /** No-op: Kyant records the layer; no per-frame bitmap grab. */
    @Suppress("UNUSED_PARAMETER")
    fun submit(bitmap: android.graphics.Bitmap) = Unit

    fun demote() {
        if (tier == GlassTier.FLAT) return
        runCatching {
            Log.w(TAG, "sustained frame-budget overrun — degrading glass FULL -> FLAT")
        }
        tier = GlassTier.FLAT
    }
}

/**
 * Glass session for the monitor shell. Null / FLAT → opaque solid fill.
 */
val LocalMonitorGlass = compositionLocalOf<MonitorGlass?> { null }

/** Warm surface tint drawn over the frosted backdrop (dark monitor chrome). */
private val GlassSurfaceTint = Color(0.105f, 0.092f, 0.073f, 0.28f)

/**
 * iOS `liquidGlass` entry point — Kyant `drawBackdrop` on API 33+ FULL,
 * opaque flat fill otherwise.
 */
@Composable
fun Modifier.glass(shape: Shape = ChromeShape): Modifier {
    val glass = LocalMonitorGlass.current
    val backdrop = glass?.layerBackdrop
    val tier = glass?.tier ?: GlassTier.FLAT
    if (backdrop == null || tier == GlassTier.FLAT || Build.VERSION.SDK_INT < 33) {
        return background(LiveDesign.glassOpaque, shape)
            .border(1.dp, LiveDesign.hairlineStrong, shape)
    }

    // 1:1 Kyant catalog effect chain (DialogContent / LiquidButton style):
    // vibrancy → blur → lens.
    return this.drawBackdrop(
        backdrop = backdrop,
        shape = { shape },
        effects = {
            vibrancy()
            blur(8f.dp.toPx())
            // Lens requires CornerBasedShape (RoundedCornerShape / CircleShape).
            if (shape is CornerBasedShape) {
                lens(
                    refractionHeight = 12f.dp.toPx(),
                    refractionAmount = 24f.dp.toPx(),
                    depthEffect = true,
                )
            }
        },
        highlight = { Highlight.Default },
        onDrawSurface = {
            drawRect(GlassSurfaceTint)
        },
    )
}

/**
 * Nested chips inside a glass slab: opaque flat (no second backdrop sample).
 */
fun Modifier.chipGlass(shape: Shape = ChromeShape): Modifier =
    background(LiveDesign.glassOpaque, shape).border(1.dp, LiveDesign.hairline, shape)

/**
 * Runs the frame-budget demote loop for a [MonitorGlass] session.
 * Stops once the tier is FLAT.
 */
@Composable
fun MonitorGlassBudgetLoop(glass: MonitorGlass) {
    LaunchedEffect(glass) {
        val budget = FrameBudgetWindow()
        var last = 0L
        while (glass.tier != GlassTier.FLAT) {
            withFrameNanos { now ->
                if (last != 0L && budget.frame(now - last)) glass.demote()
                last = now
            }
        }
    }
}

/**
 * Feed content-rect helper retained for glass-era layout tests (analysis
 * placement still uses the same fit/fill math as the old grab pass).
 */
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

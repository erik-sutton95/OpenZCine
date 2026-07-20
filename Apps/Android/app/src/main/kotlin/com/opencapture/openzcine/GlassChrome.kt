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
import com.kyant.backdrop.highlight.HighlightStyle

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
 * Capability floor for liquid glass.
 *
 * - Pre-API 33 → FLAT (lens needs RuntimeShader).
 * - Low-RAM / under 4 GB total → FLAT (Exynos 850 class like Galaxy A12
 *   cannot sustain Kyant blur+lens under live feed).
 * - Else → FULL on API 33+.
 *
 * Debug override `zc.glass.tier` can only lower; legacy `"blur"` → FLAT.
 * `"full"` never raises above [capability] — low-RAM devices stay FLAT even
 * when the intent asks for full glass.
 */
fun resolveTier(
    sdkInt: Int,
    override: String? = null,
    isLowRamDevice: Boolean = false,
    totalRamBytes: Long = Long.MAX_VALUE,
): GlassTier {
    val lowEnd =
        isLowRamDevice ||
            (totalRamBytes in 1L until MIN_FULL_GLASS_RAM_BYTES)
    val capability =
        when {
            sdkInt < 33 -> GlassTier.FLAT
            lowEnd -> GlassTier.FLAT
            else -> GlassTier.FULL
        }
    val requested =
        when (override?.lowercase()) {
            "full" -> GlassTier.FULL
            "flat", "blur" -> GlassTier.FLAT
            else -> capability
        }
    return if (requested.ordinal < capability.ordinal) requested else capability
}

/** Devices reporting under this total RAM stay on FLAT glass. */
const val MIN_FULL_GLASS_RAM_BYTES: Long = 4L * 1024L * 1024L * 1024L

/**
 * Sustained frame-budget detector used when [MonitorGlass.allowDemote] is
 * true. Defaults are moderate: demote after a short warm-up if most frames
 * miss a 48 ms budget (so a mid-range phone that snuck into FULL still
 * falls back cleanly without waiting a full minute).
 */
class FrameBudgetWindow(
    private val budgetNanos: Long = 48_000_000L,
    private val window: Int = 90,
    private val maxOverBudget: Int = 45,
    private val warmup: Int = 45,
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
 * Monitor glass session: tier + Kyant [LayerBackdrop]s for sampling.
 *
 * **Two recorded layers** (Kyant coordinates-dependent pattern):
 * - [layerBackdrop] / feed: live-view only — bottom bars and chips sample this.
 * - [overlayBackdrop] / scene: feed + chrome — pickers and assist options
 *   sample this so UI behind a popup actually blurs (not only the video).
 *
 * Attach with [com.kyant.backdrop.backdrops.layerBackdrop]. Popups must be
 * **siblings outside** the scene recording so they do not loop.
 *
 * **Feed present path:** layer recording only sees Compose/HWUI draws.
 * [SurfaceView] / [android.opengl.GLSurfaceView] live feed (FLAT + LUT/GPU)
 * never appears in the sample — [LiveFeedView] forces Compose Canvas when
 * [tier] is [GlassTier.FULL] so glass blur includes the video.
 *
 * @param allowDemote When true, [MonitorGlassBudgetLoop] may lower FULL → FLAT
 *   under sustained jank. API gating still uses [resolveTier].
 */
class MonitorGlass(
    initialTier: GlassTier,
    val layerBackdrop: LayerBackdrop? = null,
    /**
     * Full-scene recording for overlay glass (pickers). Falls back to
     * [layerBackdrop] when null.
     */
    val overlayBackdrop: LayerBackdrop? = null,
    val allowDemote: Boolean = false,
) {
    var tier: GlassTier by mutableStateOf(initialTier)
        private set

    init {
        runCatching {
            Log.i(
                TAG,
                "glass session tier=$initialTier allowDemote=$allowDemote " +
                    "sdk=${Build.VERSION.SDK_INT} feedBackdrop=${layerBackdrop != null} " +
                    "overlayBackdrop=${overlayBackdrop != null}",
            )
        }
    }

    /** No-op: Kyant records the layer; no per-frame bitmap grab. */
    @Suppress("UNUSED_PARAMETER")
    fun submit(bitmap: android.graphics.Bitmap) = Unit

    fun demote() {
        if (!allowDemote || tier == GlassTier.FLAT) return
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

/**
 * Surface over the frosted backdrop for FULL glass (outer frames / bars).
 * Kept darker to match iOS `Glass.regular` panels.
 */
private val GlassSurfaceTint = Color(0.105f, 0.092f, 0.073f, 0.56f)

/**
 * Nested chips inside a glass panel (top-bar STBY / resolution / codec / FPS).
 * Independent of [GlassSurfaceTint]: stacked on the already-dark outer panel,
 * so chips must stay lighter than the frame. 0.74 with surface 0.56 made pills
 * too dark — ease chips only.
 */
private val ChipGlassFill = Color(0.105f, 0.092f, 0.073f, 0.48f)

/**
 * Specular edge highlight for FULL glass. Tuned on device: mid was faint, 2×
 * (0.84 / white 0.52) a touch strong — settle just under that.
 */
private val GlassEdgeHighlight =
    Highlight(
        width = 0.45.dp,
        blurRadius = 0.3.dp,
        alpha = 0.70f,
        style =
            HighlightStyle.Default(
                color = Color.White.copy(alpha = 0.42f),
                falloff = 1.7f,
            ),
    )

/**
 * iOS `liquidGlass` entry point — Kyant `drawBackdrop` on API 33+ FULL,
 * opaque flat fill otherwise. Samples the **feed** backdrop (bars over video).
 */
@Composable
fun Modifier.glass(shape: Shape = ChromeShape): Modifier {
    val glass = LocalMonitorGlass.current
    return glassBackdrop(
        backdrop = glass?.layerBackdrop,
        tier = glass?.tier ?: GlassTier.FLAT,
        shape = shape,
    )
}

/**
 * Glass for popups / sheets that must blur **chrome + feed** (iOS picker /
 * assist panels). Samples [MonitorGlass.overlayBackdrop] when present.
 */
@Composable
fun Modifier.overlayGlass(shape: Shape = ChromeShape): Modifier {
    val glass = LocalMonitorGlass.current
    return glassBackdrop(
        backdrop = glass?.overlayBackdrop ?: glass?.layerBackdrop,
        tier = glass?.tier ?: GlassTier.FLAT,
        shape = shape,
    )
}

@Composable
private fun Modifier.glassBackdrop(
    backdrop: LayerBackdrop?,
    tier: GlassTier,
    shape: Shape,
): Modifier {
    if (backdrop == null || tier == GlassTier.FLAT || Build.VERSION.SDK_INT < 33) {
        return background(LiveDesign.glassOpaque, shape)
            .border(1.dp, LiveDesign.hairlineStrong, shape)
    }

    // Approximate iOS Glass.regular: vibrancy → soft blur → lens edge, then a
    // light warm darken (not LiveDesign.glassOpaque / 0.64 slab).
    return this.drawBackdrop(
        backdrop = backdrop,
        shape = { shape },
        effects = {
            vibrancy()
            blur(12f.dp.toPx())
            // Lens requires CornerBasedShape (RoundedCornerShape / CircleShape).
            if (shape is CornerBasedShape) {
                lens(
                    refractionHeight = 10f.dp.toPx(),
                    refractionAmount = 20f.dp.toPx(),
                    depthEffect = true,
                )
            }
        },
        highlight = { GlassEdgeHighlight },
        onDrawSurface = {
            drawRect(GlassSurfaceTint)
        },
    )
}

/**
 * Nested chips inside a glass slab (iOS nested `glassCapsule` / `liquidGlass`).
 * Soft fill + muted hairline — not [LiveDesign.glassOpaque], and not the full
 * [LiveDesign.hairlineStrong] stroke that reads as a double rim vs iOS.
 */
fun Modifier.chipGlass(shape: Shape = ChromeShape): Modifier =
    background(ChipGlassFill, shape)
        .border(0.5.dp, LiveDesign.hairline.copy(alpha = 0.10f), shape)

/**
 * Optional frame-budget demote loop. No-op unless [MonitorGlass.allowDemote]
 * is true (off by default — see [MonitorGlass]).
 */
@Composable
fun MonitorGlassBudgetLoop(glass: MonitorGlass) {
    if (!glass.allowDemote || glass.tier == GlassTier.FLAT) return
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

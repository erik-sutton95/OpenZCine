package com.opencapture.openzcine

import com.opencapture.monitorui.MonitorIcon
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.layout.layout
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.text.PlatformTextStyle
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.foundation.clickable
import androidx.compose.material3.Text
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.onClick as semanticsOnClick
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.toggleableState
import androidx.compose.ui.state.ToggleableState
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.offset
import com.opencapture.opencine.appkit.LocalOperatorHaptics

// Compose mirrors of the iOS monitor chrome primitives (ios/Runner/
// MonitorControls.swift + MonitorExperience.swift). Layout frames come from the
// shared core's zone map; these components only mirror the DRAWING — pill
// shapes, type hierarchy, and LiveDesign colors. SF Symbols are approximated
// with small Canvas glyphs; SF→Roboto type differences are accepted.

/** Rounded chrome shape (iOS `LiveDesign.cornerRadius`). */
val ChromeShape = RoundedCornerShape(LiveDesign.CORNER_RADIUS_DP.dp)

// The glass treatment itself (Modifier.glass / Modifier.chipGlass and the
// tiered GPU backdrop pipeline behind it) lives in GlassChrome.kt.

/**
 * Apple's HIG minimum touch target, which iOS puts under every chrome button through
 * `ZCTapTargetButtonStyle` → `minTapTarget` (ios/Runner/DesignShared.swift:30-42, 61-67).
 * Material's own floor is 48dp; 44 is the parity number and still fits the 46dp top deck band.
 */
internal const val MIN_TAP_TARGET_DP = 44f

/**
 * Grows a control's touch area to [MIN_TAP_TARGET_DP] without moving anything drawn — the Compose
 * transcription of the positive-then-negative padding iOS uses (`MinTapTargetModifier`,
 * ios/Runner/DesignShared.swift:114-137). It lives inside [chromeClickable] so
 * every chrome control inherits the floor from one place, the way iOS inherits it from one button
 * style instead of from its 131 call sites.
 *
 * Deliberately NOT `Modifier.minimumInteractiveComponentSize()`: that one reports the floored size
 * to the parent. The top deck's readout pills are ~27dp tall inside a 46dp band whose glass capsule
 * is drawn by the deck Row itself (`InfoPill`), so a pill that measured 44dp would inflate that
 * capsule past the band — moving drawn chrome is the one thing a tap-target fix must not do.
 */
@Composable
private fun Modifier.tapTargetFloor(click: Modifier.() -> Modifier): Modifier {
    val floorPx = with(LocalDensity.current) { MIN_TAP_TARGET_DP.dp.roundToPx() }
    // The drawn size is only knowable by measuring it, so the pad lands on the pass after — the
    // same one-frame settle as the iOS preference-key version.
    var drawn by remember { mutableStateOf(IntSize.Zero) }
    val padX = if (drawn.width <= 0) 0 else ((floorPx - drawn.width) / 2).coerceAtLeast(0)
    val padY = if (drawn.height <= 0) 0 else ((floorPx - drawn.height) / 2).coerceAtLeast(0)
    val expands = padX > 0 || padY > 0
    return this.then(if (expands) Modifier.tapTargetInset(padX, padY) else Modifier)
        .click()
        .then(if (expands) Modifier.tapTargetExpand(padX, padY) else Modifier)
        .onSizeChanged { size ->
            // Only a control that could still be under the floor is worth recording. Every scrim,
            // full-width row and media-grid cell clears it already, and publishing their size would
            // cost each of them a recomposition to compute a pad of zero.
            val next = if (size.width < floorPx || size.height < floorPx) size else IntSize.Zero
            if (next != drawn) drawn = next
        }
}

/** Pads the click node out around the drawn content — the half of the pair that is felt. */
private fun Modifier.tapTargetExpand(padX: Int, padY: Int): Modifier =
    layout { measurable, constraints ->
        val placeable = measurable.measure(constraints.offset(-2 * padX, -2 * padY))
        layout(placeable.width + 2 * padX, placeable.height + 2 * padY) {
            placeable.place(padX, padY)
        }
    }

/**
 * Hands the parent back the size it would have had — the half of the pair that is invisible.
 *
 * It inflates the constraints by exactly what [tapTargetExpand] subtracts again, so the drawn
 * content still measures against the caller's own constraints: a fixed-size caller (every
 * `Modifier.zone(...)` rail button) can't be squeezed by the pad and feed a smaller size back in.
 */
private fun Modifier.tapTargetInset(padX: Int, padY: Int): Modifier =
    layout { measurable, constraints ->
        val placeable = measurable.measure(constraints.offset(2 * padX, 2 * padY))
        layout(
            (placeable.width - 2 * padX).coerceAtLeast(0),
            (placeable.height - 2 * padY).coerceAtLeast(0),
        ) {
            placeable.place(-padX, -padY)
        }
    }

/**
 * Click without the Material ripple (chrome buttons highlight by state, not ripple), on a hit area
 * floored at [MIN_TAP_TARGET_DP] — see [tapTargetFloor].
 */
@Composable
fun Modifier.chromeClickable(onClick: () -> Unit): Modifier =
    chromeClickable(enabled = true, onClick = onClick)

/** Disabled chrome controls keep their visual state but reject touch input. */
@Composable
fun Modifier.chromeClickable(enabled: Boolean, onClick: () -> Unit): Modifier {
    val haptics = LocalOperatorHaptics.current
    val interaction = remember { MutableInteractionSource() }
    return tapTargetFloor {
        clickable(
            enabled = enabled,
            interactionSource = interaction,
            indication = null,
            onClick = {
                haptics.selection()
                onClick()
            },
        )
    }
}

/** Text style matching iOS `.system(size:weight:design:)` closely enough. */
fun chromeStyle(size: Float, weight: FontWeight, mono: Boolean = false): TextStyle =
    TextStyle(
        fontSize = size.sp,
        lineHeight = size.sp,
        fontWeight = weight,
        fontFamily = if (mono) FontFamily.Monospace else FontFamily.SansSerif,
        platformStyle = PlatformTextStyle(includeFontPadding = false),
    )

/** Signal bars + FPS readout capsule (iOS `FPSChip`). */
@Composable
fun FpsChip(signalBars: Int, fps: String, modifier: Modifier = Modifier) {
    val tint =
        when {
            signalBars >= 3 -> LiveDesign.good
            signalBars == 2 -> LiveDesign.accent
            signalBars == 1 -> LiveDesign.rec
            else -> LiveDesign.faint
        }
    Row(
        modifier = modifier.chipGlass(CircleShape).padding(horizontal = 11.dp, vertical = 7.dp),
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        SignalBarsGlyph(bars = signalBars, tint = tint)
        Text(
            stringResource(R.string.monitor_fps),
            style = chromeStyle(8f, FontWeight.Bold, mono = true),
            color = LiveDesign.faint,
            maxLines = 1,
        )
        // Mirror iOS: two-decimal FPS must never wrap to "25.0" / "0".
        Text(
            fps,
            style = chromeStyle(12f, FontWeight.Medium, mono = true),
            color = LiveDesign.text,
            maxLines = 1,
            softWrap = false,
        )
    }
}

/**
 * Measures its single child unbounded and scales it down (top-start anchored)
 * to fit [maxWidth] — the shell-level analog of iOS `minimumScaleFactor`, so
 * chrome pills compress instead of wrapping when a band runs tight.
 */
@Composable
fun FitScale(maxWidth: Dp, content: @Composable () -> Unit) {
    Layout(content) { measurables, _ ->
        val placeable = measurables.first().measure(Constraints())
        val maxPx = maxWidth.roundToPx()
        val scale = if (placeable.width > maxPx) maxPx / placeable.width.toFloat() else 1f
        val width = (placeable.width * scale).toInt()
        val height = (placeable.height * scale).toInt()
        layout(width, height) {
            placeable.placeWithLayer(0, 0) {
                scaleX = scale
                scaleY = scale
                transformOrigin = TransformOrigin(0f, 0f)
            }
        }
    }
}

// MARK: - Canvas glyphs (SF Symbol approximations)

/** SF `cellularbars` with `variableValue` (filled bars vs dim bars). */
@Composable
fun SignalBarsGlyph(bars: Int, tint: Color, modifier: Modifier = Modifier.size(16.dp, 12.dp)) {
    Canvas(modifier) {
        val barWidth = size.width / 4f * 0.68f
        val gap = size.width / 4f * 0.32f
        for (index in 0 until 4) {
            val height = size.height * (0.35f + 0.65f * index / 3f)
            drawRoundRect(
                if (index < bars) tint else tint.copy(alpha = 0.3f),
                topLeft = Offset(index * (barWidth + gap), size.height - height),
                size = Size(barWidth, height),
                cornerRadius = CornerRadius(barWidth * 0.35f),
            )
        }
    }
}

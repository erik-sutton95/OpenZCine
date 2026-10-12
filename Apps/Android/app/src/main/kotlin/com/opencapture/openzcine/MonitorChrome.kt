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
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.text.PlatformTextStyle
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.material3.Text
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.onClick as semanticsOnClick
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.toggleableState
import androidx.compose.ui.state.ToggleableState
import com.opencapture.monitorui.MonitorMaterial
import com.opencapture.monitorui.monitorMaterial

// Compose mirrors of the iOS monitor chrome primitives (ios/Runner/
// MonitorControls.swift + MonitorExperience.swift). Layout frames come from the
// shared core's zone map; these components only mirror the DRAWING — pill
// shapes, type hierarchy, and LiveDesign colors. SF Symbols are approximated
// with small Canvas glyphs; SF→Roboto type differences are accepted.

/** Rounded chrome shape (iOS `LiveDesign.cornerRadius`). */
val ChromeShape = RoundedCornerShape(LiveDesign.CORNER_RADIUS_DP.dp)

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
        modifier = modifier.monitorMaterial(MonitorMaterial.Compact, CircleShape).padding(horizontal = 11.dp, vertical = 7.dp),
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

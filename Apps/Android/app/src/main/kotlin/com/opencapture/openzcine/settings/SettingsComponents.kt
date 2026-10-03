package com.opencapture.openzcine.settings

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.setProgress
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.kyant.backdrop.backdrops.layerBackdrop
import com.kyant.backdrop.backdrops.rememberLayerBackdrop
import com.opencapture.openzcine.ChromeShape
import com.opencapture.openzcine.GlassTier
import com.opencapture.openzcine.LiveDesign
import com.opencapture.openzcine.LocalMonitorGlass
import com.opencapture.openzcine.chromeStyle
import com.opencapture.openzcine.glass
import com.opencapture.openzcine.glass.LiquidSlider
import kotlin.math.roundToInt

@Composable
internal fun Modifier.settingsClickable(role: Role, onClick: () -> Unit): Modifier =
    clickable(
        interactionSource = remember { MutableInteractionSource() },
        indication = null,
        role = role,
        onClick = onClick,
    )

private enum class LinkHealthBand(val label: String) {
    POOR("POOR"), WATCH("WATCH"), STABLE("STABLE")
}

/** Actual camera-link health; the app supplies its existing score and caption. */
@Composable
public fun SettingsDashScale(title: String, caption: String, score: Int) {
    val band =
        when {
            score >= 80 -> LinkHealthBand.STABLE
            score >= 50 -> LinkHealthBand.WATCH
            else -> LinkHealthBand.POOR
        }
    val bandColor =
        when (band) {
            LinkHealthBand.POOR -> LiveDesign.rec
            LinkHealthBand.WATCH -> LiveDesign.accent
            LinkHealthBand.STABLE -> LiveDesign.good
        }
    val litCount =
        when (band) {
            LinkHealthBand.POOR -> 4
            LinkHealthBand.WATCH -> 8
            LinkHealthBand.STABLE -> 12
        }
    val bandSlot =
        when (band) {
            LinkHealthBand.POOR -> 0
            LinkHealthBand.WATCH -> 1
            LinkHealthBand.STABLE -> 2
        }
    Column(
        Modifier.fillMaxWidth()
            .glass(ChromeShape)
            .padding(13.dp),
        verticalArrangement = Arrangement.spacedBy(9.dp),
    ) {
        Text(title, style = chromeStyle(13f, FontWeight.SemiBold), color = LiveDesign.text)
        Text(
            caption,
            style = chromeStyle(11.5f, FontWeight.Medium, mono = true),
            color = LiveDesign.muted,
        )
        Row(Modifier.fillMaxWidth().height(19.dp)) {
            repeat(3) { slot ->
                Box(Modifier.weight(1f).fillMaxWidth(), contentAlignment = Alignment.Center) {
                    if (slot == bandSlot) {
                        Text(
                            band.label,
                            style = chromeStyle(9.5f, FontWeight.Bold, mono = true),
                            color = bandColor,
                            letterSpacing = 0.5.sp,
                            modifier =
                                Modifier
                                    .background(bandColor.copy(alpha = 0.12f), CircleShape)
                                    .border(1.dp, bandColor, CircleShape)
                                    .padding(horizontal = 10.dp, vertical = 4.dp),
                        )
                    }
                }
            }
        }
        Row(
            Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(3.dp),
        ) {
            repeat(12) { index ->
                val fill =
                    when {
                        index >= litCount -> LiveDesign.hairlineStrong
                        index < 4 -> LiveDesign.rec.copy(alpha = 0.8f)
                        index < 8 -> LiveDesign.accent.copy(alpha = 0.85f)
                        else -> LiveDesign.good.copy(alpha = 0.9f)
                    }
                Box(
                    Modifier.weight(1f)
                        .height(6.dp)
                        .background(fill, CircleShape),
                )
            }
        }
        Row(Modifier.fillMaxWidth()) {
            DashLegend("Poor", "<50", Modifier.weight(1f), Alignment.Start)
            DashLegend("Watch", "50-79", Modifier.weight(1f), Alignment.CenterHorizontally)
            DashLegend("Stable", "80+", Modifier.weight(1f), Alignment.End)
        }
    }
}

@Composable
private fun DashLegend(
    name: String,
    sub: String,
    modifier: Modifier,
    alignment: Alignment.Horizontal,
) {
    Row(
        modifier,
        horizontalArrangement =
            when (alignment) {
                Alignment.Start -> Arrangement.Start
                Alignment.End -> Arrangement.End
                else -> Arrangement.Center
            },
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(name, style = chromeStyle(10f, FontWeight.SemiBold), color = LiveDesign.muted)
        Spacer(Modifier.size(4.dp))
        Text(sub, style = chromeStyle(9f, FontWeight.Normal, mono = true), color = LiveDesign.faint)
    }
}

/** Source swatches retain the existing names used by Nikon stored paint values. */
public data class SettingsColorDot(val name: String, val color: Color)

public object SettingsPalette {
    public val highlight: List<SettingsColorDot> =
        listOf(
            SettingsColorDot("White", LiveDesign.text),
            SettingsColorDot("Amber", LiveDesign.accent),
            SettingsColorDot("Red", LiveDesign.rec),
        )
    public val midtone: List<SettingsColorDot> =
        listOf(
            SettingsColorDot("Amber", LiveDesign.accent),
            SettingsColorDot("Cyan", LiveDesign.info),
            SettingsColorDot("Green", LiveDesign.good),
        )
    public val peaking: List<SettingsColorDot> =
        listOf(
            SettingsColorDot("White", LiveDesign.text),
            SettingsColorDot("Blue", LiveDesign.info),
            SettingsColorDot("Red", LiveDesign.rec),
            SettingsColorDot("Green", LiveDesign.good),
        )
}

/** Playback still uses the app glass owner; migrate with its separately reviewed media seam. */
@Composable
public fun GlassPillSlider(
    value: Int,
    range: IntRange,
    onChange: (Int) -> Unit,
    modifier: Modifier = Modifier,
) {
    val monitorGlass = LocalMonitorGlass.current
    // Liquid glass only when the monitor session is on FULL tier. Standalone
    // Operator Setup and FLAT-tier devices get the solid white capsule thumb.
    val useLiquidGlass = monitorGlass?.tier == GlassTier.FULL
    val localBackdrop = rememberLayerBackdrop()
    val sceneBackdrop = monitorGlass?.layerBackdrop
    val latestOnChange by rememberUpdatedState(onChange)
    val latestValue by rememberUpdatedState(value)
    val floatRange = range.first.toFloat()..range.last.toFloat()
    // Continuous thumb position while dragging. Discrete onChange (Int steps) alone cannot
    // drive a smooth pill drag — intermediate floats would be rounded away and the thumb
    // would stick (especially on short ranges like desqueeze 0…10).
    var displayValue by remember { mutableFloatStateOf(value.toFloat()) }
    // Accept external commits without yanking the pill back to the last Int mid-drag.
    SideEffect {
        if (displayValue.roundToInt().coerceIn(range) != value) {
            displayValue = value.toFloat()
        }
    }

    Box(
        modifier
            .height(40.dp)
            .then(
                if (useLiquidGlass && sceneBackdrop == null) {
                    Modifier.layerBackdrop(localBackdrop)
                } else {
                    Modifier
                },
            )
            .semantics(mergeDescendants = true) {
                stateDescription = "$value%"
                setProgress { target ->
                    val next =
                        (range.first + target * (range.last - range.first))
                            .roundToInt()
                            .coerceIn(range)
                    displayValue = next.toFloat()
                    latestOnChange(next)
                    true
                }
            },
        contentAlignment = Alignment.Center,
    ) {
        if (useLiquidGlass && sceneBackdrop == null) {
            Box(
                Modifier
                    .matchParentSize()
                    .background(
                        brush =
                            Brush.horizontalGradient(
                                colors =
                                    listOf(
                                        LiveDesign.surface,
                                        LiveDesign.background,
                                        LiveDesign.surface,
                                    ),
                            ),
                    ),
            )
        }
        LiquidSlider(
            value = { displayValue },
            onValueChange = { next ->
                displayValue = next
                val rounded = next.roundToInt().coerceIn(range)
                if (rounded != latestValue) latestOnChange(rounded)
            },
            valueRange = floatRange,
            visibilityThreshold = 0.5f,
            backdrop = sceneBackdrop ?: localBackdrop,
            modifier = Modifier.fillMaxWidth(),
            accentColor = LiveDesign.accent,
            useLiquidGlass = useLiquidGlass,
        )
    }
}

/** Physical close lane reserved by the Nikon full-screen page adapter. */
@Composable
public fun PanelCloseButton(onClick: () -> Unit) {
    Box(
        Modifier.size(37.dp).glass(CircleShape).settingsClickable(role = Role.Button, onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Canvas(Modifier.size(13.dp)) {
            val stroke = 2.2.dp.toPx()
            drawLine(
                LiveDesign.text,
                Offset(0f, 0f),
                Offset(size.width, size.height),
                stroke,
                StrokeCap.Round,
            )
            drawLine(
                LiveDesign.text,
                Offset(size.width, 0f),
                Offset(0f, size.height),
                stroke,
                StrokeCap.Round,
            )
        }
    }
}

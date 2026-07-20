package com.opencapture.openzcine.settings

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.runtime.remember
import com.opencapture.openzcine.ChromeShape
import com.opencapture.openzcine.LiveDesign
import com.opencapture.openzcine.R
import com.opencapture.openzcine.chromeStyle
import com.opencapture.openzcine.glass

// Compose ports of the iOS operator-settings primitives (ios/Runner/
// MonitorControls.swift: SettingsRowCard, SettingsInlineRow,
// SettingsSwitchInlineRow, SettingsSwitchGraphic, SettingsValueText,
// SettingsGroupCard, DisplayToggleItem, CloseButton). Same metrics and
// LiveDesign colors so the two shells render matching settings chrome.
// ponytail: help "?" badges (iOS HelpBadge popovers) are skipped in v1 — the
// row copy stands alone; add them when a row genuinely needs explanation.

/** Ripple-free click carrying a semantics [role] (the settings-panel `chromeClickable`). */
@Composable
internal fun Modifier.settingsClickable(role: Role, onClick: () -> Unit): Modifier =
    clickable(
        interactionSource = remember { MutableInteractionSource() },
        indication = null,
        role = role,
        onClick = onClick,
    )

/**
 * A card whose rows are divider-separated with no per-row borders (iOS
 * `SettingsRowCard`). Optional [title] / [onReset] match the assist-tool cards
 * on Operator Setup → View Assist.
 */
@Composable
public fun SettingsRowCard(
    title: String? = null,
    onReset: (() -> Unit)? = null,
    content: @Composable () -> Unit,
) {
    Column(
        Modifier.fillMaxWidth()
            .glass(ChromeShape)
            .padding(horizontal = 13.dp)
            .padding(bottom = 4.dp),
    ) {
        if (title != null) {
            Row(
                Modifier.fillMaxWidth().padding(top = 11.dp, bottom = 2.dp).defaultMinSize(minHeight = 24.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    title,
                    style = chromeStyle(13f, FontWeight.SemiBold),
                    color = LiveDesign.text,
                )
                Spacer(Modifier.weight(1f))
                if (onReset != null) {
                    SettingsResetButton(onClick = onReset)
                }
            }
        }
        content()
    }
}

/** Circular counter-clockwise reset control (iOS `SettingsResetButton`, 28dp). */
@Composable
public fun SettingsResetButton(onClick: () -> Unit) {
    val description = stringResource(R.string.settings_reset_defaults)
    Box(
        Modifier.size(28.dp)
            .background(LiveDesign.background.copy(alpha = 0.42f), CircleShape)
            .border(1.dp, LiveDesign.hairline, CircleShape)
            .settingsClickable(role = Role.Button, onClick = onClick)
            .semantics { contentDescription = description },
        contentAlignment = Alignment.Center,
    ) {
        // Simple two-arc “↺” mark without pulling in an icon dependency.
        Canvas(Modifier.size(12.dp)) {
            val stroke = 1.6.dp.toPx()
            drawArc(
                color = LiveDesign.muted,
                startAngle = -40f,
                sweepAngle = 260f,
                useCenter = false,
                style = Stroke(width = stroke, cap = StrokeCap.Round),
            )
            val tipX = size.width * 0.78f
            val tipY = size.height * 0.18f
            drawLine(
                LiveDesign.muted,
                Offset(tipX - 3.dp.toPx(), tipY),
                Offset(tipX, tipY),
                stroke,
                StrokeCap.Round,
            )
            drawLine(
                LiveDesign.muted,
                Offset(tipX, tipY),
                Offset(tipX, tipY + 3.dp.toPx()),
                stroke,
                StrokeCap.Round,
            )
        }
    }
}

/**
 * Accent capsule action used on Link / System trailing controls (iOS
 * `SettingsActionPill`). Title is uppercased to match the iOS monospaced pill.
 */
@Composable
public fun SettingsActionPill(title: String, onClick: () -> Unit) {
    Text(
        title.uppercase(),
        style = chromeStyle(10.5f, FontWeight.Bold, mono = true),
        color = LiveDesign.accent,
        maxLines = 1,
        letterSpacing = 0.6.sp,
        modifier =
            Modifier
                .background(LiveDesign.accentDim, CircleShape)
                .border(1.dp, LiveDesign.accent.copy(alpha = 0.5f), CircleShape)
                .settingsClickable(role = Role.Button, onClick = onClick)
                .padding(horizontal = 14.dp, vertical = 9.dp),
    )
}

/**
 * Link Health dash-scale meter (iOS `SettingsDashScale`): POOR / WATCH / STABLE
 * marker over a 12-dash track with a three-band legend.
 */
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

private enum class LinkHealthBand(val label: String) {
    POOR("POOR"),
    WATCH("WATCH"),
    STABLE("STABLE"),
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

/**
 * One label-plus-trailing-control row for a divider-separated card
 * (iOS `SettingsInlineRow`).
 */
@Composable
public fun SettingsInlineRow(
    title: String,
    showTopDivider: Boolean = true,
    trailing: @Composable () -> Unit,
) {
    Column {
        if (showTopDivider) {
            Box(Modifier.fillMaxWidth().height(1.dp).background(LiveDesign.hairline))
        }
        Row(
            Modifier.fillMaxWidth().defaultMinSize(minHeight = 50.dp),
            horizontalArrangement = Arrangement.spacedBy(12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                title,
                style = chromeStyle(12.5f, FontWeight.SemiBold),
                color = LiveDesign.text,
                maxLines = 1,
            )
            Spacer(Modifier.weight(1f))
            trailing()
        }
    }
}

/** Switch row inside a row card (iOS `SettingsSwitchInlineRow`). */
@Composable
public fun SettingsSwitchRow(
    title: String,
    isOn: Boolean,
    showTopDivider: Boolean = true,
    onToggle: () -> Unit,
) {
    SettingsInlineRow(title = title, showTopDivider = showTopDivider) {
        Box(Modifier.settingsClickable(role = Role.Switch, onClick = onToggle)) {
            SettingsSwitchGraphic(isOn = isOn)
        }
    }
}

/** The gold capsule switch graphic (iOS `SettingsSwitchGraphic`, 39×22). */
@Composable
public fun SettingsSwitchGraphic(isOn: Boolean) {
    Box(
        Modifier.size(width = 39.dp, height = 22.dp)
            .background(if (isOn) LiveDesign.accentDim else LiveDesign.surface, CircleShape)
            .border(1.dp, if (isOn) LiveDesign.accentDim else LiveDesign.hairline, CircleShape)
            .padding(3.5.dp),
        contentAlignment = if (isOn) Alignment.CenterEnd else Alignment.CenterStart,
    ) {
        Box(
            Modifier.size(15.dp)
                .background(if (isOn) LiveDesign.accent else LiveDesign.muted, CircleShape)
        )
    }
}

/** Plain monospace value text (iOS `SettingsValueText`). */
@Composable
public fun SettingsValueText(value: String) {
    Text(
        value,
        style = chromeStyle(12.5f, FontWeight.Medium, mono = true),
        color = LiveDesign.muted,
        maxLines = 1,
    )
}

/** Accent inline action ("Open", "Sign in") — the iOS System-tab link button treatment. */
@Composable
public fun SettingsLinkAction(
    title: String,
    contentDescription: String = title,
    onClick: () -> Unit,
): Unit {
    Box(
        Modifier.defaultMinSize(minWidth = 48.dp, minHeight = 48.dp)
            .settingsClickable(role = Role.Button, onClick = onClick)
            .semantics { this.contentDescription = contentDescription }
            .padding(horizontal = 4.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            title,
            style = chromeStyle(13f, FontWeight.SemiBold),
            color = LiveDesign.accent,
        )
    }
}

/**
 * Quiet utility text link — mirrors the startup header's Privacy/Terms
 * treatment (iOS `StartupHeader.legalLink`): deliberately dimmer than row
 * titles so it never competes with them.
 */
@Composable
public fun SettingsQuietLink(title: String, onClick: () -> Unit): Unit {
    Box(
        Modifier.defaultMinSize(minWidth = 48.dp, minHeight = 48.dp)
            .settingsClickable(role = Role.Button, onClick = onClick)
            .padding(horizontal = 4.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            title,
            fontSize = 11.sp,
            fontWeight = FontWeight.Medium,
            color = LiveDesign.faint,
            maxLines = 1,
        )
    }
}

/**
 * Titled glass card with an optional per-tool reset and free-form content.
 *
 * [captionMaxLines] defaults to the compact settings-card treatment. Flows
 * that communicate a consequential choice can opt into an unbounded caption
 * so accessibility font scaling never hides that context.
 */
@Composable
public fun SettingsGroupCard(
    title: String,
    caption: String,
    onReset: (() -> Unit)? = null,
    captionMaxLines: Int = 2,
    content: @Composable () -> Unit,
) {
    Column(
        Modifier.fillMaxWidth().glass(ChromeShape).padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(11.dp),
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Row(
                Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    title,
                    style = chromeStyle(13f, FontWeight.SemiBold),
                    color = LiveDesign.text,
                )
                Spacer(Modifier.weight(1f))
                if (onReset != null) {
                    SettingsResetButton(onClick = onReset)
                }
            }
            Text(
                caption,
                style = chromeStyle(11.5f, FontWeight.Normal),
                color = LiveDesign.muted,
                maxLines = captionMaxLines,
            )
        }
        content()
    }
}

/** Small label + switch tile for toggle grids (iOS `DisplayToggleItem`). */
@Composable
public fun DisplayToggleItem(
    title: String,
    isOn: Boolean,
    modifier: Modifier = Modifier,
    onToggle: () -> Unit,
) {
    Row(
        modifier
            .height(46.dp)
            .background(LiveDesign.background.copy(alpha = 0.38f), ChromeShape)
            .border(1.dp, LiveDesign.hairline, ChromeShape)
            .settingsClickable(role = Role.Switch, onClick = onToggle)
            .padding(horizontal = 9.dp),
        horizontalArrangement = Arrangement.spacedBy(7.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            title,
            style = chromeStyle(11.5f, FontWeight.SemiBold),
            color = LiveDesign.text,
            maxLines = 1,
        )
        Spacer(Modifier.weight(1f))
        SettingsSwitchGraphic(isOn = isOn)
    }
}

/** Floating xmark close button on a glass circle (iOS `CloseButton`, 37pt). */
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

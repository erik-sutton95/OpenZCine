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
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.runtime.remember
import com.opencapture.openzcine.ChromeShape
import com.opencapture.openzcine.LiveDesign
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

/** A card whose rows are divider-separated with no per-row borders (iOS `SettingsRowCard`). */
@Composable
public fun SettingsRowCard(content: @Composable () -> Unit) {
    Column(
        Modifier.fillMaxWidth()
            .glass(ChromeShape)
            .padding(horizontal = 13.dp)
            .padding(bottom = 4.dp)
    ) {
        content()
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
public fun SettingsLinkAction(title: String, onClick: () -> Unit) {
    Text(
        title,
        style = chromeStyle(13f, FontWeight.SemiBold),
        color = LiveDesign.accent,
        modifier = Modifier.settingsClickable(role = Role.Button, onClick = onClick).padding(4.dp),
    )
}

/**
 * Quiet utility text link — mirrors the startup header's Privacy/Terms
 * treatment (iOS `StartupHeader.legalLink`): deliberately dimmer than row
 * titles so it never competes with them.
 */
@Composable
public fun SettingsQuietLink(title: String, onClick: () -> Unit) {
    Text(
        title,
        fontSize = 11.sp,
        fontWeight = FontWeight.Medium,
        color = LiveDesign.faint,
        maxLines = 1,
        modifier = Modifier.settingsClickable(role = Role.Button, onClick = onClick).padding(4.dp),
    )
}

/** Titled glass card with a caption over free-form content (iOS `SettingsGroupCard`). */
@Composable
public fun SettingsGroupCard(title: String, caption: String, content: @Composable () -> Unit) {
    Column(
        Modifier.fillMaxWidth().glass(ChromeShape).padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(11.dp),
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(title, style = chromeStyle(13f, FontWeight.SemiBold), color = LiveDesign.text)
            Text(
                caption,
                style = chromeStyle(11.5f, FontWeight.Normal),
                color = LiveDesign.muted,
                maxLines = 1,
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

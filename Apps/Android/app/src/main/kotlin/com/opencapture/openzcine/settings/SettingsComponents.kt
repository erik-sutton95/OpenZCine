package com.opencapture.openzcine.settings

import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import com.opencapture.monitorui.settings.MonitorSettingsColorDot
import com.opencapture.openzcine.LiveDesign
import com.opencapture.openzcine.R
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.res.stringResource
import com.opencapture.monitorui.MonitorIcon
import com.opencapture.monitorui.MonitorMaterial
import com.opencapture.monitorui.monitorMaterial

@Composable
internal fun Modifier.settingsClickable(role: Role, onClick: () -> Unit): Modifier =
    clickable(
        interactionSource = remember { MutableInteractionSource() },
        indication = null,
        role = role,
        onClick = onClick,
    )

/** Source swatches retain the existing names used by Nikon stored paint values. */
public object SettingsPalette {
    public val highlight: List<MonitorSettingsColorDot> =
        listOf(
            MonitorSettingsColorDot("White", LiveDesign.text),
            MonitorSettingsColorDot("Amber", LiveDesign.amber),
            MonitorSettingsColorDot("Red", LiveDesign.rec),
        )
    public val midtone: List<MonitorSettingsColorDot> =
        listOf(
            MonitorSettingsColorDot("Amber", LiveDesign.amber),
            MonitorSettingsColorDot("Cyan", LiveDesign.info),
            MonitorSettingsColorDot("Green", LiveDesign.good),
        )
    public val peaking: List<MonitorSettingsColorDot> =
        listOf(
            MonitorSettingsColorDot("White", LiveDesign.text),
            MonitorSettingsColorDot("Blue", LiveDesign.info),
            MonitorSettingsColorDot("Red", LiveDesign.rec),
            MonitorSettingsColorDot("Green", LiveDesign.good),
        )
}

/** Physical close lane reserved by the Nikon full-screen page adapter. */
@Composable
public fun PanelCloseButton(onClick: () -> Unit, modifier: Modifier = Modifier) {
    val close = stringResource(R.string.action_close)
    Box(
        modifier.size(37.dp).monitorMaterial(MonitorMaterial.Compact, CircleShape).settingsClickable(role = Role.Button, onClick = onClick)
            .semantics { contentDescription = close },
        contentAlignment = Alignment.Center,
    ) {
        MonitorIcon(MonitorIcon.X, null, Modifier.size(14.dp), LiveDesign.text)
    }
}

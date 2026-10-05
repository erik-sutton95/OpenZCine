package com.opencapture.openzcine.settings

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import com.opencapture.monitorui.settings.MonitorSettingsColorDot
import com.opencapture.openzcine.LiveDesign
import com.opencapture.openzcine.glass

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
            MonitorSettingsColorDot("Amber", LiveDesign.accent),
            MonitorSettingsColorDot("Red", LiveDesign.rec),
        )
    public val midtone: List<MonitorSettingsColorDot> =
        listOf(
            MonitorSettingsColorDot("Amber", LiveDesign.accent),
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

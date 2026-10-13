package com.opencapture.openzcine.gyro

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.selection.selectable
import androidx.compose.material3.RadioButton
import androidx.compose.material3.RadioButtonDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import com.opencapture.monitorui.MonitorPalette
import com.opencapture.monitorui.settings.MonitorSettingsActionPill
import com.opencapture.monitorui.settings.MonitorSettingsRowCard

/** Saves the phone's physical mount for future takes; screen rotation has no effect. */
@Composable
internal fun GyroMountScreen(state: GyroCaptureState, onSelect: (String) -> Unit, onClose: () -> Unit) {
    BackHandler(onBack = onClose)
    Column(Modifier.fillMaxSize().background(MonitorPalette.background)
        .windowInsetsPadding(WindowInsets.safeDrawing).padding(16.dp).testTag("gyro-mount"),
        verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
            Text("Phone mount", color = MonitorPalette.text)
            MonitorSettingsActionPill("Close", onClick = onClose)
        }
        LazyColumn(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            item {
                Text(if (state.mountOptions.size == 1) "Configure the phone-to-camera alignment in Gyroflow for this mount."
                    else "Directions are viewed from behind an upright camera. Keep the phone screen parallel to the camera's back, perpendicular to the lens axis. For an angled holder, leave the mount unconfigured and set rotation in Gyroflow.",
                    color = MonitorPalette.muted)
            }
            for ((group, options) in state.mountOptions.groupBy { it.group }) {
                if (group != null) item { Text(group, color = MonitorPalette.text) }
                items(options, key = { it.id }) { option ->
                    MonitorSettingsRowCard {
                        Row(Modifier.fillMaxWidth().selectable(selected = option.id == state.mountPreset,
                            role = Role.RadioButton, onClick = { onSelect(option.id) })
                            .testTag("gyro-mount-${option.id}"), verticalAlignment = Alignment.CenterVertically) {
                            RadioButton(selected = option.id == state.mountPreset, onClick = null,
                                colors = RadioButtonDefaults.colors(selectedColor = MonitorPalette.accent,
                                    unselectedColor = MonitorPalette.muted))
                            Column(Modifier.weight(1f).padding(vertical = 6.dp)) {
                                Text(option.title, color = MonitorPalette.text)
                                Text(option.detail, color = MonitorPalette.muted)
                            }
                        }
                    }
                }
            }
        }
        Text("Changes apply to the next take. Existing logs keep their recorded mount.", color = MonitorPalette.muted)
    }
}

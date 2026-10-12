package com.opencapture.openzcine.settings

import com.opencapture.monitorui.settings.MonitorSettingsColorDot
import com.opencapture.openzcine.LiveDesign

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

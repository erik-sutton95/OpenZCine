package com.opencapture.openzcine

import androidx.compose.runtime.Composable
import com.opencapture.monitorui.settings.MonitorSettingsChoices
import com.opencapture.monitorui.settings.MonitorSettingsInlineRow
import com.opencapture.monitorui.settings.MonitorSettingsSwitchInlineRow
import com.opencapture.opencine.appkit.MonitorReviewDuration

/** Nikon supplies review preferences to the shared inspector's typed extension slot. */
@Composable
internal fun NikonReviewOptions(assists: NikonAssists) {
    val options = assists.reviewOptions
    MonitorSettingsInlineRow("Review Duration", showTopDivider = false, stacked = true,
        help = "How long the captured frame stays up after a release. ∞ keeps it until tapped.") {
        MonitorSettingsChoices(MonitorReviewDuration.entries, options.duration, accentSelection = true,
            title = MonitorReviewDuration::label) {
            assists.updateReviewOptions(options.copy(duration = it))
        }
    }
    MonitorSettingsSwitchInlineRow("Focus Point", options.showsFocusPoint,
        help = "Overlay the AF box the shot focused with on the review.") {
        assists.updateReviewOptions(options.copy(showsFocusPoint = !options.showsFocusPoint))
    }
    MonitorSettingsSwitchInlineRow("Capture Info", options.showsCaptureInfo,
        help = "Show the shot's ISO, shutter, iris, and quality under the review.") {
        assists.updateReviewOptions(options.copy(showsCaptureInfo = !options.showsCaptureInfo))
    }
}

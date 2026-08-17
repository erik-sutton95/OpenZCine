package com.opencapture.openzcine

import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.test.click
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performTouchInput
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.UiDevice
import com.opencapture.openzcine.bridge.ZoneFrame
import com.opencapture.openzcine.core.CameraControl
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Instrumented contract that the shared settings-picker panel stays dismissable while a
 * camera-control write is in flight (#328). A focus-mode write can hold the command mutex
 * for seconds (or wedge entirely on a flaky link); gating Back/scrim/X on the pending write
 * trapped the operator in the popup with no exit but killing the app. iOS
 * `dismissActivePanel` has no such gate — dismissal is always allowed and the write
 * finishes in the background.
 */
@RunWith(AndroidJUnit4::class)
class MonitorPickerDismissComposeTest {
    @get:Rule
    val composeRule = createComposeRule()

    private val pickerFrame = ZoneFrame(x = 140f, y = 40f, width = 220f, height = 220f)

    private fun focusPicker(): MonitorPickerPresentation {
        val request =
            CommandControlRequest(
                title = "Focus",
                control = CameraControl.FOCUS_MODE,
                currentValue = "AF-C",
                options = listOf("AF-S", "AF-C", "MF"),
            )
        return MonitorPickerPresentation(
            kind = MonitorPickerKind.FOCUS,
            title = "FOCUS",
            subtitle = "AF-C",
            modes = listOf(MonitorPickerModePresentation(label = "MODE", request = request)),
        )
    }

    private fun mountPanel(onDismiss: () -> Unit) {
        composeRule.setContent {
            MonitorControlPickerPanel(
                picker = focusPicker(),
                frame = pickerFrame,
                controlsEnabled = true,
                // The write that used to freeze every dismissal path.
                pendingControl = CameraControl.FOCUS_MODE,
                feedback = null,
                onSelect = { _, _ -> },
                onDismiss = onDismiss,
            )
        }
        composeRule.waitForIdle()
    }

    @Test
    fun backDismissesPickerWhileWritePending() {
        var dismissed = false
        mountPanel { dismissed = true }

        UiDevice.getInstance(InstrumentationRegistry.getInstrumentation()).pressBack()

        composeRule.runOnIdle { assertTrue(dismissed) }
    }

    @Test
    fun scrimTapDismissesPickerWhileWritePending() {
        var dismissed = false
        mountPanel { dismissed = true }

        // Top-left corner is well outside the picker frame — this is the backdrop.
        composeRule.onRoot().performTouchInput { click(Offset(8f, 8f)) }

        composeRule.runOnIdle { assertTrue(dismissed) }
    }
}

package com.opencapture.openzcine.gyro

import android.graphics.Bitmap
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.opencapture.openzcine.OpenZCineTheme
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

@RunWith(AndroidJUnit4::class)
class GyroCalibrationComposeTest {
    @get:Rule val compose = createComposeRule()

    @Test fun threePoseWizardRequiresVerificationAndOffersRetryAndReset() {
        var state by mutableStateOf(GyroCaptureState())
        var verificationAttempts = 0
        compose.setContent {
            OpenZCineTheme {
            GyroMountScreen(state, onSelect = {}, onClose = {},
                onCalibrate = { state = state.copy(calibration = GyroCalibrationState(active = true)) },
                onCapture = {
                    state = when (state.calibration.poseCount) {
                        0, 1 -> state.copy(calibration = GyroCalibrationState(active = true,
                            poseCount = state.calibration.poseCount + 1))
                        else -> if (++verificationAttempts == 1) state.copy(calibration = GyroCalibrationState(
                            active = true, poseCount = 2, error = "Hold still and verify again."))
                            else state.copy(calibration = GyroCalibrationState(poseCount = 3), mountCalibration = "verified")
                    }
                },
                onCancelCalibration = { state = state.copy(calibration = GyroCalibrationState()) },
                onResetCalibration = { state = state.copy(mountCalibration = null) })
            }
        }
        compose.onNodeWithText("CALIBRATE").performScrollTo().performClick()
        compose.onNodeWithText("Step 1 of 3").assertIsDisplayed()
        saveScreenshot("step-1")
        compose.onNodeWithText("CAPTURE").performClick()
        compose.onNodeWithText("Step 2 of 3").assertIsDisplayed()
        saveScreenshot("step-2")
        compose.onNodeWithText("CAPTURE").performClick()
        compose.onNodeWithText("Step 3 of 3").assertIsDisplayed()
        compose.onAllNodesWithText("Calibrated phone mount").assertCountEquals(0)
        saveScreenshot("step-3")
        compose.onNodeWithText("VERIFY").performClick()
        compose.onNodeWithText("Hold still and verify again.").assertIsDisplayed()
        saveScreenshot("retry")
        compose.onAllNodesWithText("Calibrated phone mount").assertCountEquals(0)
        compose.onNodeWithText("VERIFY").performClick()
        compose.onNodeWithText("Calibrated phone mount").assertIsDisplayed()
        saveScreenshot("verified")
        compose.onNodeWithText("RESET").performScrollTo().performClick()
        compose.onNodeWithText("Automatic calibration").assertIsDisplayed()
        saveScreenshot("reset")
        compose.onNodeWithText("CALIBRATE").performClick()
        compose.onNodeWithText("CANCEL").performClick()
        compose.onNodeWithText("Automatic calibration").assertIsDisplayed()
    }

    private fun saveScreenshot(name: String) {
        if (InstrumentationRegistry.getArguments().getString("gyroCalibrationScreenshots") != "true") return
        compose.waitForIdle()
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val image = requireNotNull(instrumentation.uiAutomation.takeScreenshot())
        try {
            check(image.width > image.height) { "The calibration flow must be verified in landscape." }
            val directory = requireNotNull(instrumentation.targetContext.getExternalFilesDir(null))
            File(directory, "gyro-calibration-ui-$name.png").outputStream().use {
                check(image.compress(Bitmap.CompressFormat.PNG, 100, it))
            }
        } finally { image.recycle() }
    }
}

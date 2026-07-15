package com.opencapture.openzcine

import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.UiDevice
import org.junit.Assert.assertFalse
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** Instrumented contract that live assist options consume Back before the monitor host. */
@OptIn(ExperimentalTestApi::class)
@RunWith(AndroidJUnit4::class)
class LiveAssistBackHandlerComposeTest {
    @get:Rule
    val composeRule = createComposeRule()

    @Test
    fun backDismissesLiveAssistOptions() {
        var visible = true
        composeRule.setContent {
            LiveAssistOptionsBackHandler(visible = visible) { visible = false }
        }

        composeRule.waitForIdle()
        UiDevice.getInstance(InstrumentationRegistry.getInstrumentation()).pressBack()

        composeRule.runOnIdle { assertFalse(visible) }
    }
}

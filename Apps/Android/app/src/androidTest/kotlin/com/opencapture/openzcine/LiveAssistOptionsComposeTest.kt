package com.opencapture.openzcine

import android.content.Context
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.opencapture.openzcine.media.LiveAssistOptionsOverlay
import com.opencapture.openzcine.settings.OperatorSettings
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** Device rendering contract for every real live-monitor assist configuration panel. */
@OptIn(ExperimentalTestApi::class)
@RunWith(AndroidJUnit4::class)
class LiveAssistOptionsComposeTest {
    @get:Rule
    val composeRule = createComposeRule()

    @Test
    fun everyConfigurableAssistRendersItsRealPanel() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val preferences =
            context.getSharedPreferences("ope65-live-assist-options", Context.MODE_PRIVATE)
        preferences.edit().clear().commit()
        val settings = OperatorSettings(preferences)
        val assistState = AssistState(FeedEffects.NONE, null)
        val activeTool = mutableStateOf(AssistTool.LUT)
        composeRule.setContent {
            OpenZCineTheme {
                LiveAssistOptionsOverlay(
                    tool = activeTool.value,
                    anchorBounds = Rect(120f, 120f, 180f, 180f),
                    assistState = assistState,
                    settings = settings,
                    cameraInput = ExposureAssistCameraInput(),
                    lutLibrary = null,
                    onDismiss = {},
                )
            }
        }

        AssistTool.entries.filter(AssistTool::hasConfiguration).forEach { tool ->
            composeRule.runOnIdle { activeTool.value = tool }
            composeRule.waitForIdle()
            composeRule
                .onNodeWithContentDescription("Dismiss ${tool.settingsTitle} options")
                .assertIsDisplayed()
            composeRule.onAllNodesWithText(tool.settingsTitle.uppercase())[0].assertIsDisplayed()
        }

        preferences.edit().clear().commit()
    }
}

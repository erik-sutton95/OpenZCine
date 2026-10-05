package com.opencapture.openzcine

import android.content.Context
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.assertHeightIsAtLeast
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.test.click
import androidx.compose.ui.unit.dp
import androidx.test.core.app.ApplicationProvider
import com.opencapture.monitorui.MonitorFieldLayout
import com.opencapture.monitorui.MonitorLayoutPolicy
import com.opencapture.monitorui.MonitorRect
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test

class LiveViewGuideComposeTest {
    @get:Rule val compose = createComposeRule()

    private lateinit var controller: LiveViewGuideController

    @Before
    fun prepareController() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val preferences =
            context.getSharedPreferences("live-guide-compose-test", Context.MODE_PRIVATE)
        preferences.edit().clear().commit()
        controller = LiveViewGuideController(preferences)
        controller.onRealDecodedFrame()
    }

    @Test
    fun guideAdvancesThroughAllThreeAccessibleSteps() {
        compose.setContent {
            OpenZCineTheme {
                LiveViewGuideOverlay(
                    controller = controller,
                    layout = testLayout(),
                    isPortrait = false,
                    usesVerticalAssistRail = false,
                )
            }
        }

        compose.onNodeWithTag("live_guide_card").assertIsDisplayed()
        compose.onNodeWithText("Status & camera controls").assertIsDisplayed()
        compose.onNodeWithContentDescription("Next Live View Guide step")
            .assertHeightIsAtLeast(48.dp)
            .performClick()
        compose.onNodeWithText("View Assist").assertIsDisplayed()
        compose.onNodeWithContentDescription("Next Live View Guide step").performClick()
        compose.onNodeWithText("System controls").assertIsDisplayed()
        compose.onNodeWithContentDescription("Finish Live View Guide")
            .assertHeightIsAtLeast(48.dp)
            .performClick()

        assertTrue(compose.onAllNodesWithTag("live_guide_card").fetchSemanticsNodes().isEmpty())
    }

    @Test
    fun modalScrimConsumesTapsBeforeUnderlyingCameraCommand() {
        val commandCount = mutableIntStateOf(0)
        compose.setContent {
            OpenZCineTheme {
                Box(Modifier.fillMaxSize()) {
                    Box(
                        Modifier.fillMaxSize()
                            .testTag("underlying_camera_command")
                            .clickable { commandCount.intValue += 1 },
                    )
                    LiveViewGuideOverlay(
                        controller = controller,
                        layout = testLayout(),
                        isPortrait = false,
                        usesVerticalAssistRail = false,
                    )
                }
            }
        }

        compose.onNodeWithContentDescription("Live View Guide modal background")
            .performTouchInput { click(position = center.copy(x = 8f, y = 8f)) }

        compose.runOnIdle { assertEquals(0, commandCount.intValue) }
    }

    private fun testLayout(): MonitorFieldLayout =
        MonitorLayoutPolicy.fieldMonitor(width = 720f, height = 393f).copy(
            picture = MonitorRect(60f, 50f, 600f, 300f),
            status = MonitorRect(210f, 10f, 300f, 40f),
            values = MonitorRect(220f, 340f, 280f, 44f),
            assists = MonitorRect(60f, 340f, 150f, 44f),
            system = MonitorRect(660f, 50f, 60f, 300f),
            lock = MonitorRect(5f, 12f, 48f, 48f),
            display = MonitorRect(665f, 65f, 48f, 48f),
            record = MonitorRect(660f, 130f, 58f, 58f),
            media = MonitorRect(665f, 205f, 48f, 48f),
            settings = MonitorRect(665f, 270f, 48f, 48f),
        )
}

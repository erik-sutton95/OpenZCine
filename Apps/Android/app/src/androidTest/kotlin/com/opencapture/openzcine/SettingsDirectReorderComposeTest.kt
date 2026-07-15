package com.opencapture.openzcine

import android.content.Context
import androidx.compose.foundation.layout.size
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.unit.dp
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.opencapture.openzcine.settings.AssistToolbarOrderList
import com.opencapture.openzcine.settings.DisplayModeOrderList
import com.opencapture.openzcine.settings.MonitorDisplayMode
import com.opencapture.openzcine.settings.OperatorSettings
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** Instrumented contract for the Display tab's real drag handle. */
@OptIn(ExperimentalTestApi::class)
@RunWith(AndroidJUnit4::class)
class SettingsDirectReorderComposeTest {
    @get:Rule
    val composeRule = createComposeRule()

    @Test
    fun dragHandleMovesTheExactToolAndDoesNotToggleItsVisibility() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val preferences = context.getSharedPreferences("ope65-settings-reorder", Context.MODE_PRIVATE)
        preferences.edit().clear().commit()
        val settings = OperatorSettings(preferences)
        var interactions = 0
        composeRule.setContent {
            OpenZCineTheme {
                AssistToolbarOrderList(
                    settings = settings,
                    onInteraction = { interactions += 1 },
                )
            }
        }

        composeRule
            .onNodeWithContentDescription("Reorder LUT, position 1")
            .performTouchInput {
                down(center)
                advanceEventTime(700)
                moveBy(Offset(0f, height * 2.2f))
                advanceEventTime(50)
                up()
            }

        composeRule.runOnIdle {
            assertTrue(settings.assistToolbarOrder.indexOf(AssistTool.LUT) >= 2)
            assertTrue(settings.isAssistToolbarToolVisible(AssistTool.LUT))
            assertEquals(1, interactions)
        }
        preferences.edit().clear().commit()
    }

    @Test
    fun dispHandleReordersModesAndLastEnabledModeCannotBeHidden() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val preferences = context.getSharedPreferences("ope66-settings-disp", Context.MODE_PRIVATE)
        preferences.edit().clear().commit()
        val settings = OperatorSettings(preferences)
        composeRule.setContent {
            OpenZCineTheme {
                DisplayModeOrderList(settings = settings, onInteraction = {})
            }
        }

        composeRule
            .onNodeWithContentDescription("Reorder Command, position 3")
            .performTouchInput {
                down(center)
                advanceEventTime(700)
                moveBy(Offset(0f, -height * 2.2f))
                advanceEventTime(50)
                up()
            }
        composeRule.onNodeWithContentDescription("Include Live in DISP cycle").performClick()
        composeRule.onNodeWithContentDescription("Include Clean in DISP cycle").performClick()
        composeRule.onNodeWithContentDescription("Include Command in DISP cycle").performClick()

        composeRule.runOnIdle {
            assertEquals(MonitorDisplayMode.COMMAND, settings.displayModeOrder.first())
            assertEquals(setOf(MonitorDisplayMode.COMMAND), settings.enabledDisplayModes)
        }
        preferences.edit().clear().commit()
    }

    @Test
    fun hiddenRailSettingsRecoveryRemainsReachable() {
        var opened = false
        composeRule.setContent {
            OpenZCineTheme {
                LandscapeSettingsRecoveryButton(
                    modifier = Modifier.size(63.dp),
                    onOpenSettings = { opened = true },
                )
            }
        }

        composeRule
            .onNodeWithContentDescription("Open Settings, restore hidden monitor controls")
            .assertIsDisplayed()
            .performClick()

        composeRule.runOnIdle { assertTrue(opened) }
    }
}

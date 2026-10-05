package com.opencapture.openzcine

import android.content.Context
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.SideEffect
import androidx.compose.ui.test.performScrollTo
import com.opencapture.monitorui.settings.LocalMonitorSettingsScrollContext
import com.opencapture.monitorui.settings.MonitorSettingsPage
import com.opencapture.monitorui.settings.MonitorSettingsScrollContext
import com.opencapture.monitorui.settings.MonitorSettingsTab
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.unit.dp
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.opencapture.openzcine.settings.DisplayModeOrderList
import com.opencapture.openzcine.settings.MonitorDisplayMode
import com.opencapture.openzcine.settings.OperatorSettings
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** Instrumented contract for the Display tab's real drag handle (the DISP order list). */
@OptIn(ExperimentalTestApi::class)
@RunWith(AndroidJUnit4::class)
class SettingsDirectReorderComposeTest {
    @get:Rule
    val composeRule = createComposeRule()

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
    fun actualSharedPageEdgeScrollsDuringGripDragAndRetiresOnRelease() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val preferences = context.getSharedPreferences("z2-settings-page-edge", Context.MODE_PRIVATE)
        preferences.edit().clear().commit()
        val settings = OperatorSettings(preferences)
        var pageScroll: MonitorSettingsScrollContext? = null
        var interactions = 0
        composeRule.setContent {
            OpenZCineTheme {
                MonitorSettingsPage(
                    brand = "SIMULATED", selection = MonitorSettingsTab.DISPLAY, onSelect = {},
                    isLive = false, phaseLabel = "SIMULATED", disconnect = null,
                    modifier = Modifier.size(width = 400.dp, height = 500.dp),
                ) {
                    val scroll = checkNotNull(LocalMonitorSettingsScrollContext.current)
                    SideEffect { pageScroll = scroll }
                    // Room above and below so the short DISP list sits inside a page that scrolls.
                    Spacer(Modifier.height(600.dp))
                    DisplayModeOrderList(
                        settings = settings, onInteraction = { interactions += 1 },
                        parentScrollState = scroll.scrollState, viewportBounds = scroll.viewportBounds,
                    )
                    Spacer(Modifier.height(600.dp))
                }
            }
        }
        val grip = composeRule.onNodeWithContentDescription("Reorder Live, position 1")
        grip.performScrollTo()
        val initial = checkNotNull(pageScroll).scrollState.value
        val gripBounds = grip.fetchSemanticsNode().boundsInRoot
        val viewport = checkNotNull(checkNotNull(pageScroll).viewportBounds)
        grip.performTouchInput {
            down(center)
            advanceEventTime(700)
            moveTo(Offset(center.x, viewport.bottom - gripBounds.top - 8f))
        }
        composeRule.waitUntil(timeoutMillis = 2_000) {
            checkNotNull(pageScroll).scrollState.value > initial + 40
        }
        composeRule.onRoot().performTouchInput { up() }
        composeRule.runOnIdle {
            assertEquals(MonitorDisplayMode.LIVE, settings.displayModeOrder.last())
            assertTrue(MonitorDisplayMode.LIVE in settings.enabledDisplayModes)
            assertEquals(1, interactions)
        }
        val settled = checkNotNull(pageScroll).scrollState.value
        composeRule.mainClock.advanceTimeBy(400)
        composeRule.runOnIdle { assertEquals(settled, checkNotNull(pageScroll).scrollState.value) }
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

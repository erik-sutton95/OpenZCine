package com.opencapture.openzcine

import androidx.compose.runtime.Composable
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.filter
import androidx.compose.ui.test.hasAnyAncestor
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onAllNodesWithContentDescription
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.opencapture.monitorui.settings.*
import com.opencapture.opencine.cameracontrols.*
import com.opencapture.opencine.media.MonitorCrushClipCompensation
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** SIMULATED host values through the exact published settings calls and actual native page. */
@Suppress("DEPRECATION")
@RunWith(AndroidJUnit4::class)
class PublishedOperatorSettingsCompatibilityTest {
    @get:Rule val composeRule = createComposeRule()

    @Test fun publishedNamedListAndBorrowedScreenRenderAndInvokeTheirSuppliedActions() {
        var trafficCalls = 0
        var returned = 0
        var selected: String? = null
        var visibilityCalls = 0
        val sections = listOf(MonitorAssistSettingsSection.Histogram(
            false, { trafficCalls++ }, MonitorCrushClipCompensation.ZERO, {},
            "SIMULATED published traffic help", "SIMULATED compensation help"))
        val configuration = publishedConfiguration(sections)
        val choices = listOf(MonitorDisplayChoice("original", "Original"), MonitorDisplayChoice("alternate", "Alternate"))
        val displaySections = listOf(MonitorDisplaySection(
            id = "published", title = "Published controls", caption = "SIMULATED borrowed values",
            visibility = listOf(MonitorDisplayToggle("legacy-visible", "Legacy visibility", true) { visibilityCalls++ }),
            style = MonitorDisplaySectionStyle.CONTROLS))
        val order = MonitorDisplayOrderGroup("Published order", "SIMULATED order", emptyList(), move = { _, _ -> })
        val display = MonitorOperatorBorrowedDisplay(
            layoutTitle = "Published layout", layoutHelp = "SIMULATED layout help", choices = choices,
            selection = "original", onSelect = { selected = it }, expandedSection = "published", onExpand = {},
            sections = displaySections, order = order, returnedFromEditor = { returned++ })
        composeRule.setContent {
            OpenZCineTheme {
                MonitorOperatorSettingsScreen(configuration = configuration, borrowedDisplay = display,
                    initialTab = MonitorSettingsTab.ASSIST, sourceIdentity = "published-fixture")
            }
        }
        composeRule.runOnIdle {
            assertSame(sections, configuration.assistSections)
            assertNull(configuration.assist)
            assertNull(configuration.account)
            assertSame(choices, display.choices)
            assertSame(displaySections, display.sections)
            assertSame(order, display.order)
            assertEquals("original", display.selection)
            assertEquals("published", display.expandedSection)
            assertEquals(0, returned)
        }
        val trafficHelp = composeRule.onAllNodesWithContentDescription("Help")
            .filter(hasAnyAncestor(hasTestTag("settings.assist.histogram")))[0]
        trafficHelp.performScrollTo().performClick()
        composeRule.onNodeWithText("SIMULATED published traffic help").assertIsDisplayed()
        trafficHelp.performClick()
        composeRule.onAllNodesWithContentDescription("Traffic Lights").assertCountEquals(1)
        composeRule.onNodeWithContentDescription("Traffic Lights").performScrollTo().performClick()
        composeRule.runOnIdle { assertEquals(1, trafficCalls) }
        composeRule.onNodeWithTag("monitor.settings.tab.Display").performScrollTo().performClick()
        composeRule.onNodeWithText("Published layout").performScrollTo().assertIsDisplayed()
        composeRule.runOnIdle { assertEquals(1, returned) }
        composeRule.onNodeWithText("Alternate").performScrollTo().performClick()
        composeRule.runOnIdle { assertEquals("alternate", selected) }
        composeRule.onNodeWithContentDescription("Legacy visibility").performScrollTo().performClick()
        composeRule.runOnIdle { assertEquals(1, visibilityCalls) }
        composeRule.onNodeWithTag("monitor.settings.tab.View Assist").performScrollTo().performClick()
        composeRule.onNodeWithTag("monitor.settings.tab.Display").performScrollTo().performClick()
        composeRule.runOnIdle { assertEquals(2, returned) }
    }

    @Test fun publishedPositionalConstructorsAndTwoArgumentScreenKeepTheirDefaults() {
        val list = emptyList<MonitorAssistSettingsSection>()
        val named = publishedConfiguration(list)
        // Original constructor positional order, including the defaulted account position.
        val configuration = MonitorOperatorSettingsConfiguration(
            named.brand, named.isLive, named.phase, named.close, named.disconnect, named.feedback,
            named.link, named.sharing, named.sharingSubtitle, named.sharingRail, list, named.controls,
            named.cache, null, named.support, named.information)
        val display = MonitorOperatorBorrowedDisplay("Published layout", "SIMULATED help",
            emptyList(), "original", {}, null, {}, emptyList(),
            MonitorDisplayOrderGroup("Published order", "SIMULATED order", emptyList(), move = { _, _ -> }))
        composeRule.setContent { OpenZCineTheme { MonitorOperatorSettingsScreen(configuration, display) } }
        composeRule.onNodeWithText("SIMULATED transport").assertIsDisplayed()
        composeRule.onAllNodesWithContentDescription("Traffic Lights").assertCountEquals(0)
        composeRule.runOnIdle {
            assertSame(list, configuration.assistSections)
            display.returnedFromEditor()
        }
    }

    private fun publishedConfiguration(sections: List<MonitorAssistSettingsSection>) =
        MonitorOperatorSettingsConfiguration(
            brand = "SIMULATED", isLive = false, phase = "SIMULATED idle", close = {}, disconnect = null,
            feedback = {}, link = MonitorSettingsLinkSource("SIMULATED transport", "SIMULATED transport help",
                "SIMULATED phase", "SIMULATED phase help", "SIMULATED health", "SIMULATED health help", null),
            sharing = null, sharingSubtitle = null, sharingRail = null, assistSections = sections,
            controls = MonitorSettingsControlsSource(false, {}, false, {}, false, {}, "SIMULATED awake help",
                rotationHelp = "SIMULATED rotation help"), cache = null,
            support = MonitorSettingsSupportSource(null, false, "SIMULATED reports help", "SIMULATED unavailable",
                null, "SIMULATED report", "SIMULATED report help", "SIMULATED report action", {}, {}, null, null,
                emptyList(), "SIMULATED source help", "SIMULATED terms help", {}, {}),
            information = MonitorSettingsInformationSource("SIMULATED theme", "SIMULATED protocol", "SIMULATED version",
                "SIMULATED theme help", "SIMULATED protocol help", "SIMULATED version help"))

    // Compile every published Screen call form; required arguments retain their named labels.
    @Composable private fun publishedScreenCalls(configuration: MonitorOperatorSettingsConfiguration,
        borrowedDisplay: MonitorOperatorBorrowedDisplay) {
        MonitorOperatorSettingsScreen(configuration, borrowedDisplay)
        MonitorOperatorSettingsScreen(configuration, borrowedDisplay, MonitorSettingsTab.ASSIST)
        MonitorOperatorSettingsScreen(configuration, borrowedDisplay, MonitorSettingsTab.DISPLAY, "identity")
        MonitorOperatorSettingsScreen(configuration = configuration, borrowedDisplay = borrowedDisplay,
            sourceIdentity = "identity")
    }
}

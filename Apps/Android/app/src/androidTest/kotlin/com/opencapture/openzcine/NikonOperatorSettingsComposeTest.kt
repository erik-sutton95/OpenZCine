package com.opencapture.openzcine

import android.content.Context
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsFocused
import androidx.compose.ui.test.hasAnyAncestor
import androidx.compose.ui.test.hasClickAction
import androidx.compose.ui.test.hasContentDescription
import androidx.compose.ui.test.hasSetTextAction
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.printToString
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performTextReplacement
import androidx.compose.ui.test.performImeAction
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.opencapture.opencine.nikon.CameraIdentity
import com.opencapture.opencine.nikon.CameraSession
import com.opencapture.opencine.nikon.FakeCameraSession
import com.opencapture.openzcine.diagnostics.BugReportSubmitter
import com.opencapture.openzcine.diagnostics.SystemSettingsActions
import com.opencapture.openzcine.media.MediaCacheStore
import com.opencapture.openzcine.settings.OperatorSettings
import com.opencapture.openzcine.settings.OperatorSettingsScreen
import com.opencapture.openzcine.settings.OperatorSettingsTab
import com.opencapture.openzcine.settings.CaptureLayoutMode
import com.opencapture.openzcine.settings.MonitorDisplayMode
import java.nio.file.Files
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import com.opencapture.openzcine.bridge.SwiftCore
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** SIMULATED inputs through the actual Nikon page and shared navigation/safety controls. */
@RunWith(AndroidJUnit4::class)
class NikonOperatorSettingsComposeTest {
    @get:Rule val composeRule = createComposeRule()

    @Test fun sharedSafetyControlsPersistExistingKeysAndEveryTabRemainsReachable() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val preferences = context.getSharedPreferences("z2-settings-page", Context.MODE_PRIVATE)
        preferences.edit().clear().putString("unrelated.operator.choice", "retained").commit()
        val settings = OperatorSettings(preferences)
        show(settings, OperatorSettingsTab.CONTROLS)

        for (label in listOf("Record confirmation", "Keep screen awake", "Haptics")) {
            composeRule.onNodeWithContentDescription(label).performScrollTo().performClick()
        }
        composeRule.runOnIdle {
            val reloaded = OperatorSettings(preferences)
            assertFalse(reloaded.recordConfirmationEnabled.value)
            assertFalse(reloaded.keepScreenAwake.value)
            assertFalse(reloaded.hapticsEnabled.value)
            assertFalse(preferences.getBoolean("controls.recordConfirmation", true))
            assertFalse(preferences.getBoolean("controls.keepScreenAwake", true))
            assertFalse(preferences.getBoolean("controls.haptics", true))
            assertEquals("retained", preferences.getString("unrelated.operator.choice", null))
        }
        for (tab in OperatorSettingsTab.entries) {
            composeRule.onNodeWithTag("monitor.settings.tab.${tab.title}")
                .performScrollTo().performClick().assertIsDisplayed()
        }
        preferences.edit().clear().commit()
    }

    @Test fun liveSessionWithoutDisconnectAuthorityOffersNoInertAction() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val preferences = context.getSharedPreferences("z2-settings-read-only", Context.MODE_PRIVATE)
        preferences.edit().clear().commit()
        val session = FakeCameraSession(CameraIdentity("SIMULATED", "SIMULATED", "settings-read-only"))
        runBlocking { session.connect() }
        show(OperatorSettings(preferences), OperatorSettingsTab.LINK, session)
        composeRule.onNodeWithText("Active link").assertIsDisplayed()
        composeRule.onNodeWithText("Disconnect").assertDoesNotExist()
        preferences.edit().clear().commit()
    }

    @Test fun commonSectionsOmitUnsupportedChoicesAndInvokeExistingNativeRoutes() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val preferences = context.getSharedPreferences("z2-settings-sections", Context.MODE_PRIVATE)
        preferences.edit().clear().commit()
        val called = mutableListOf<String>()
        val actions = object : SystemSettingsActions by NoExternalActions {
            override fun openSupport(): Boolean { called += "support"; return true }
            override fun openSource(): Boolean { called += "source"; return true }
            override fun openPrivacy(): Boolean { called += "privacy"; return true }
            override fun openTerms(): Boolean { called += "terms"; return true }
        }
        show(OperatorSettings(preferences), OperatorSettingsTab.STORAGE, actions = actions)
        composeRule.onNodeWithText("Full Resolution Caching").assertDoesNotExist()
        composeRule.onNodeWithText("Local Media Cache").performScrollTo().assertIsDisplayed()
        composeRule.onNodeWithTag("monitor.settings.tab.System").performScrollTo().performClick()
        composeRule.onNodeWithText("Automatic error reports").assertDoesNotExist()
        composeRule.onNodeWithText("Licenses").assertDoesNotExist()
        composeRule.onNodeWithText("NOTICE").assertDoesNotExist()
        for (label in listOf("Open Source Code", "Open Privacy Policy", "Open Terms of Use", "Open Support")) {
            composeRule.onNodeWithContentDescription(label).performScrollTo().performClick()
        }
        composeRule.runOnIdle {
            assertEquals(listOf("source", "privacy", "terms", "support"), called)
            assertFalse(preferences.contains("cache.originals"))
        }
        preferences.edit().clear().commit()
    }

    @Test fun unsupportedReadAndUnknownCalibrationOmitCommonControls() {
        val colors = listOf(com.opencapture.monitorui.settings.MonitorSettingsColorDot("White", androidx.compose.ui.graphics.Color.White))
        val absent = com.opencapture.monitorui.MonitorZebraNumberZone(false, null,
            com.opencapture.opencine.media.MonitorZebraPaint.WHITE, colors, onEnabled = {}, onPaint = {})
        composeRule.setContent {
            OpenZCineTheme {
                androidx.compose.foundation.layout.Column {
                    com.opencapture.monitorui.MonitorFalseColorMenu(
                        scales = listOf("Stops", "IRE"), scale = "IRE", onScale = {}, title = { it },
                        readChoice = null, reference = null, referenceEnabled = false, onReferenceEnabled = {},
                        scaleHelp = "SIMULATED missing calibration", readHelp = "", referenceHelp = "")
                    com.opencapture.monitorui.MonitorZebraMenu(units = listOf("Native", "IRE"), unit = "IRE",
                        title = { it }, onUnit = {}, unitsHelp = "", highlightHelp = "", midtoneHelp = "",
                        highlight = absent, midtone = absent)
                }
            }
        }
        composeRule.onNodeWithText("Read").assertDoesNotExist()
        composeRule.onNodeWithText("LOG").assertDoesNotExist()
        composeRule.onNodeWithText("REFERENCE KEY").assertDoesNotExist()
        composeRule.onAllNodes(hasSetTextAction()).assertCountEquals(0)
        composeRule.onNodeWithContentDescription("Highlight").assertExists()
        composeRule.onNodeWithContentDescription("Midtone").assertExists()
    }

    @Test fun actualCommonAssistMenusPersistIndependentValuesAndKnownSourceReference() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val preferences = context.getSharedPreferences("z2-settings-assist-menus", Context.MODE_PRIVATE)
        preferences.edit().clear().putString("unrelated.operator.choice", "retained").commit()
        val settings = OperatorSettings(preferences)
        val session = FakeCameraSession(CameraIdentity("SIMULATED", "SIMULATED", "settings-assists"))
        runBlocking { session.connect() }
        val originalParade = settings.scopeAssistConfiguration.paradeMode
        show(settings, OperatorSettingsTab.ASSIST, session)
        fun choose(card: String, text: String) {
            composeRule.onNode(hasText(text) and hasAnyAncestor(hasTestTag("settings.assist.$card")))
                .performScrollTo().performClick()
        }
        choose("waveform", "Luma")
        composeRule.runOnIdle { assertEquals(originalParade, settings.scopeAssistConfiguration.paradeMode) }
        choose("parade", "YRGB")
        choose("vectorscope", "4x")
        choose("peaking", "High")
        composeRule.onNode(hasContentDescription("1.0") and hasAnyAncestor(hasTestTag("settings.assist.trafficLights")))
            .performScrollTo().performClick()
        composeRule.onNodeWithText("Read").assertDoesNotExist()
        composeRule.onNodeWithText("LOG").assertDoesNotExist()
        composeRule.onNodeWithText("REFERENCE KEY").performScrollTo().assertIsDisplayed()
        composeRule.runOnIdle {
            val reloaded = OperatorSettings(preferences)
            assertEquals(com.opencapture.openzcine.settings.ScopeWaveformMode.LUMA, reloaded.scopeAssistConfiguration.waveformMode)
            assertEquals(com.opencapture.openzcine.settings.ScopeParadeMode.YRGB, reloaded.scopeAssistConfiguration.paradeMode)
            assertEquals(com.opencapture.openzcine.settings.ScopeVectorscopeZoom.X4, reloaded.scopeAssistConfiguration.vectorscopeZoom)
            assertEquals(FeedPeakingSensitivity.HIGH, reloaded.feedEffectsConfiguration.peakingSensitivity)
            assertEquals(com.opencapture.openzcine.settings.ScopeCrushClipCompensation.ONE, reloaded.scopeCrushClipCompensation)
            assertEquals("retained", preferences.getString("unrelated.operator.choice", null))
        }
        preferences.edit().clear().commit()
    }

    @Test fun actualZebraEditorClampsOnDoneAndKeepsKnownNativeConversion() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val preferences = context.getSharedPreferences("z2-settings-number", Context.MODE_PRIVATE)
        preferences.edit().clear().commit()
        val settings = OperatorSettings(preferences)
        val session = FakeCameraSession(CameraIdentity("SIMULATED", "SIMULATED", "settings-number"))
        runBlocking { session.connect() }
        val properties = session.cameraProperties.value
        val input = ExposureAssistCameraInput(codec = properties.codec, iso = properties.iso, baseIso = properties.baseIso)
        assertTrue("Actual numeric page requires the packaged Swift core", SwiftCore.isAvailable)
        assertNotNull(zebraEditorValue(input, FeedZebraUnit.IRE, settings.feedEffectsConfiguration.zebraHighlightIre))
        show(settings, OperatorSettingsTab.ASSIST, session)
        composeRule.onNodeWithTag("settings.zebra.threshold.Highlight", useUnmergedTree = true)
            .assertExists(composeRule.onRoot(useUnmergedTree = true).printToString())
        val threshold = hasAnyAncestor(hasTestTag("settings.zebra.threshold.Highlight"))
        fun enterAndFinish(text: String) {
            composeRule.onNodeWithTag("settings.zebra.threshold.Highlight", useUnmergedTree = true).performScrollTo()
            composeRule.onNode(threshold and hasClickAction(), useUnmergedTree = true).performClick()
            val editor = composeRule.onNode(threshold and hasSetTextAction(), useUnmergedTree = true)
            editor.assertIsFocused()
            editor.performTextReplacement(text)
            editor.performImeAction()
            composeRule.onNode(threshold and hasSetTextAction(), useUnmergedTree = true).assertDoesNotExist()
        }
        enterAndFinish("999")
        composeRule.runOnIdle { assertEquals(100f, settings.feedEffectsConfiguration.zebraHighlightIre) }
        composeRule.runOnIdle {
            settings.feedEffectsConfiguration = settings.feedEffectsConfiguration.copy(zebraUnit = FeedZebraUnit.NATIVE)
        }
        enterAndFinish("999")
        composeRule.runOnIdle {
            assertEquals(zebraMonitorPercent(input, FeedZebraUnit.NATIVE, 255f),
                settings.feedEffectsConfiguration.zebraHighlightIre)
        }
        enterAndFinish("128")
        composeRule.runOnIdle {
            assertEquals(zebraMonitorPercent(input, FeedZebraUnit.NATIVE, 128f),
                settings.feedEffectsConfiguration.zebraHighlightIre)
        }
        val retained = settings.feedEffectsConfiguration.zebraHighlightIre
        enterAndFinish("")
        composeRule.runOnIdle { assertEquals(retained, settings.feedEffectsConfiguration.zebraHighlightIre) }
        composeRule.onNode(threshold and hasClickAction(), useUnmergedTree = true).performClick()
        composeRule.onNode(threshold and hasSetTextAction(), useUnmergedTree = true).performTextReplacement("120")
        val midtone = hasAnyAncestor(hasTestTag("settings.zebra.threshold.Midtone"))
        composeRule.onNodeWithTag("settings.zebra.threshold.Midtone", useUnmergedTree = true).performScrollTo()
        composeRule.onNode(midtone and hasClickAction(), useUnmergedTree = true).performClick()
        composeRule.onNode(midtone and hasSetTextAction(), useUnmergedTree = true).assertIsFocused()
        composeRule.onNode(threshold and hasSetTextAction(), useUnmergedTree = true).assertDoesNotExist()
        composeRule.runOnIdle {
            assertEquals(zebraMonitorPercent(input, FeedZebraUnit.NATIVE, 120f),
                settings.feedEffectsConfiguration.zebraHighlightIre)
        }
        composeRule.onNode(midtone and hasSetTextAction(), useUnmergedTree = true).performImeAction()
        preferences.edit().clear().commit()
    }

    @Test fun actualCommonDisplayKeepsCaptureLayoutsIndependentAndAdmitsOnlyTheCurrentEditor() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val preferences = context.getSharedPreferences("z2-display-capture", Context.MODE_PRIVATE)
        preferences.edit().clear().putString("unrelated.operator.choice", "retained").commit()
        val settings = OperatorSettings(preferences)
        val videoRecord = settings.chrome(MonitorDisplayMode.LIVE, CaptureLayoutMode.VIDEO).railRecord.value
        val photoRecord = settings.chrome(MonitorDisplayMode.LIVE, CaptureLayoutMode.PHOTO).railRecord.value
        show(settings, OperatorSettingsTab.DISPLAY)
        composeRule.onNodeWithText("DISP 1 · Live").performScrollTo().performClick()
        composeRule.onNodeWithTag("monitor.settings.display.edit.LIVE").assertIsDisplayed()
        composeRule.onNodeWithText("Photo").performScrollTo().performClick()
        composeRule.onNodeWithTag("monitor.settings.display.edit.LIVE").assertDoesNotExist()
        composeRule.onNodeWithTag("monitor.settings.display.toggle.RAIL_RECORD").performScrollTo().performClick()
        composeRule.runOnIdle {
            val reloaded = OperatorSettings(preferences)
            assertEquals(videoRecord, reloaded.chrome(MonitorDisplayMode.LIVE, CaptureLayoutMode.VIDEO).railRecord.value)
            assertEquals(!photoRecord, reloaded.chrome(MonitorDisplayMode.LIVE, CaptureLayoutMode.PHOTO).railRecord.value)
            assertEquals("retained", preferences.getString("unrelated.operator.choice", null))
        }
        composeRule.onNodeWithText("Video").performScrollTo().performClick()
        composeRule.onNodeWithTag("monitor.settings.display.edit.LIVE").performScrollTo().assertIsDisplayed()
        composeRule.onNodeWithText("DISP 3 · Command").performScrollTo().performClick()
        composeRule.onNodeWithTag("monitor.settings.display.edit.COMMAND").assertDoesNotExist()
        composeRule.onNodeWithTag("monitor.settings.display.toggle.RAIL_RECORD").performScrollTo().assertIsDisplayed()
        preferences.edit().clear().commit()
    }

    @Test fun actualCommonDisplayContainsFullLabelsAndSwitchesInsideEachCard() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val preferences = context.getSharedPreferences("z2-display-label-fit", Context.MODE_PRIVATE)
        preferences.edit().clear().commit()
        show(OperatorSettings(preferences), OperatorSettingsTab.DISPLAY)
        composeRule.onNodeWithText("DISP 1 · Live").performScrollTo().performClick()
        composeRule.onNodeWithText("Photo").performScrollTo().performClick()
        for ((id, label) in listOf("CAMERA_VALUES" to "Camera Values", "RESOLUTION_READOUT" to "RESOLUTION")) {
            val tag = "monitor.settings.display.toggle.$id"
            val row = composeRule.onNodeWithTag(tag, useUnmergedTree = true).performScrollTo()
            val text = composeRule.onNode(hasText(label) and hasAnyAncestor(hasTestTag(tag)), useUnmergedTree = true)
            text.assertIsDisplayed()
            val cardBounds = row.fetchSemanticsNode().boundsInRoot
            val textBounds = text.fetchSemanticsNode().boundsInRoot
            val density = context.resources.displayMetrics.density
            // Actual native text must leave the existing 39dp switch, both 7dp row gaps,
            // and the 9dp trailing inset inside the rendered card.
            assertTrue("$label must leave room for its complete switch",
                textBounds.right + 62f * density <= cardBounds.right + 1f)
            assertTrue("$label stays inside the leading inset", textBounds.left >= cardBounds.left + 9f * density - 1f)
        }
        preferences.edit().clear().commit()
    }

    @Test fun actualCommonDisplayPreservesEmptyCleanPinsAndLastEnabledMode() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val preferences = context.getSharedPreferences("z2-display-pins", Context.MODE_PRIVATE)
        preferences.edit().clear().commit()
        val settings = OperatorSettings(preferences)
        val kept = AssistTool.entries.filter(settings::isPinnedToCleanView)
        show(settings, OperatorSettingsTab.DISPLAY)
        composeRule.onNodeWithText("DISP 2 · Clean").performScrollTo().performClick()
        for (tool in kept) {
            composeRule.onNodeWithTag("monitor.settings.display.toggle.${tool.name}")
                .performScrollTo().performClick()
        }
        for (mode in MonitorDisplayMode.entries) {
            composeRule.onNodeWithTag("monitor.settings.display.visibility.${mode.name}")
                .performScrollTo().performClick()
        }
        composeRule.runOnIdle {
            val reloaded = OperatorSettings(preferences)
            assertTrue(AssistTool.entries.none(reloaded::isPinnedToCleanView))
            assertEquals(setOf(MonitorDisplayMode.COMMAND), reloaded.enabledDisplayModes)
            assertEquals(setOf(MonitorDisplayMode.COMMAND), settings.enabledDisplayModes)
        }
        preferences.edit().clear().commit()
    }

    private fun show(
        settings: OperatorSettings, initial: OperatorSettingsTab, session: CameraSession? = null,
        actions: SystemSettingsActions = NoExternalActions,
    ) {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val guide = LiveViewGuideController(context.getSharedPreferences("z2-settings-guide", Context.MODE_PRIVATE))
        val cache = MediaCacheStore(Files.createTempDirectory(context.cacheDir.toPath(), "z2-settings"))
        composeRule.setContent {
            OpenZCineTheme {
                OperatorSettingsScreen(
                    session = session, assistState = AssistState(FeedEffects.NONE, null),
                    settings = settings, mediaCacheStore = cache,
                    systemSettingsActions = actions,
                    bugReportSubmitter = BugReportSubmitter { error("This page fixture never submits a report") },
                    liveViewGuideController = guide, onShowGuideOnNextRealFrame = {},
                    initialTab = initial, onClose = {},
                )
            }
        }
    }

    private object NoExternalActions : SystemSettingsActions {
        override fun openSupport(): Boolean = false
        override fun requestFeature(): Boolean = false
        override fun openGitHubBugReport(): Boolean = false
        override fun openSecurityAdvisory(): Boolean = false
        override fun openSource(): Boolean = false
        override fun openPrivacy(): Boolean = false
        override fun openTerms(): Boolean = false
        override fun shareDiagnostics(): Boolean = false
    }
}

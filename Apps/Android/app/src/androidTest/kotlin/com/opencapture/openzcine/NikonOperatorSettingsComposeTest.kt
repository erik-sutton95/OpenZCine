package com.opencapture.openzcine

import android.content.Context
import android.content.SharedPreferences
import com.opencapture.monitorui.MonitorAssistTool
import com.opencapture.monitorui.MonitorParadeMode
import com.opencapture.monitorui.MonitorVectorscopeZoom
import com.opencapture.monitorui.MonitorWaveformMode
import com.opencapture.monitorui.MonitorZebraUnit
import com.opencapture.opencine.media.MonitorCrushClipCompensation
import com.opencapture.opencine.media.MonitorPeakingSense
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsFocused
import androidx.compose.ui.test.hasAnyAncestor
import androidx.compose.ui.test.onAllNodesWithContentDescription
import androidx.compose.foundation.layout.width
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
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

        for (label in listOf("Record confirmation", "Keep screen awake", "Haptics", "Bluetooth Remote Shutter", "Auto-Rotate Feed")) {
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
            assertFalse(reloaded.mediaRemoteShutterEnabled.value)
            assertFalse(reloaded.autoRotateFeedEnabled.value)
            assertFalse(preferences.getBoolean("controls.mediaRemoteShutter.v1", true))
            assertFalse(preferences.getBoolean("controls.autoRotateFeed", true))
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

    @Test fun commonAssistCardsOmitUnavailableResetsAndUnknownInputChoices() {
        composeRule.setContent {
            OpenZCineTheme {
                androidx.compose.foundation.layout.Column {
                    com.opencapture.monitorui.settings.MonitorViewAssistSettings(listOf(
                        com.opencapture.monitorui.settings.MonitorAssistSettingsSection.Unavailable(
                            com.opencapture.monitorui.MonitorAssistTool.FALSE, "SIMULATED unavailable processor")))
                    com.opencapture.monitorui.settings.MonitorInputOrientationSettings(rotationHelp = "")
                }
            }
        }
        composeRule.onNodeWithText("SIMULATED unavailable processor").assertIsDisplayed()
        composeRule.onNodeWithContentDescription("Reset to defaults").assertDoesNotExist()
        composeRule.onNodeWithText("Input & orientation").assertDoesNotExist()
        composeRule.onNodeWithText("Remote shutter").assertDoesNotExist()
        composeRule.onNodeWithText("Auto-Rotate Feed").assertDoesNotExist()
        composeRule.onAllNodes(hasSetTextAction()).assertCountEquals(0)
    }

    @Test fun compactAssistCardKeepsEveryFractionTargetInsideItsActualHost() {
        var selected = com.opencapture.opencine.media.MonitorCrushClipCompensation.ZERO
        composeRule.setContent {
            OpenZCineTheme {
                androidx.compose.foundation.layout.Column(androidx.compose.ui.Modifier.width(300.dp).testTag("compact.assist")) {
                    com.opencapture.monitorui.settings.MonitorViewAssistSettings(listOf(
                        com.opencapture.monitorui.settings.MonitorAssistSettingsSection.TrafficLights(
                            selected, { selected = it }, "SIMULATED tolerance")))
                }
            }
        }
        val host = composeRule.onNodeWithTag("compact.assist").fetchSemanticsNode().boundsInRoot
        val density = ApplicationProvider.getApplicationContext<Context>().resources.displayMetrics.density
        for (value in com.opencapture.opencine.media.MonitorCrushClipCompensation.entries) {
            val node = composeRule.onNodeWithContentDescription(value.label)
            val bounds = node.fetchSemanticsNode().boundsInRoot
            assertTrue("${value.label} retains a complete touch target", bounds.width >= 44f * density - 1f)
            assertTrue("${value.label} is inside the common card", bounds.left >= host.left && bounds.right <= host.right + 1f)
            node.performClick()
            composeRule.runOnIdle { assertEquals(value, selected) }
        }
    }

    @Test fun narrowNativeZonesWrapControlsAndKeepCompleteColorTargets() {
        val colors = listOf("White", "Amber", "Red").map {
            com.opencapture.monitorui.settings.MonitorSettingsColorDot(it, androidx.compose.ui.graphics.Color.White)
        }
        val entry = com.opencapture.monitorui.MonitorZebraNumberEntry(80, 100, {}, "narrow.native.threshold")
        val zone = com.opencapture.monitorui.MonitorZebraNumberZone(false, entry,
            com.opencapture.opencine.media.MonitorZebraPaint.WHITE, colors, onEnabled = {}, onPaint = {})
        composeRule.setContent {
            OpenZCineTheme {
                androidx.compose.foundation.layout.Column(androidx.compose.ui.Modifier
                    .width(230.dp).testTag("narrow.native.zone")) {
                    com.opencapture.monitorui.MonitorZebraMenu(units = listOf("Native", "IRE"), unit = "IRE",
                        title = { it }, onUnit = {}, unitsHelp = "", highlightHelp = "", midtoneHelp = "",
                        highlight = zone, midtone = zone)
                }
            }
        }
        val root = composeRule.onNodeWithTag("narrow.native.zone").fetchSemanticsNode().boundsInRoot
        val density = ApplicationProvider.getApplicationContext<Context>().resources.displayMetrics.density
        for (label in listOf("White", "Amber", "Red")) {
            val targets = composeRule.onAllNodesWithContentDescription(label).fetchSemanticsNodes()
            assertEquals(2, targets.size)
            targets.forEach {
                val bounds = it.boundsInRoot
                assertTrue("$label keeps its complete touch target", bounds.width >= 44f * density - 1f)
                assertTrue("$label stays inside its narrow host", bounds.left >= root.left && bounds.right <= root.right + 1f)
            }
        }
    }

    @Test fun actualCommonAssistMenusPersistIndependentValuesAndKnownSourceReference() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val preferences = context.getSharedPreferences("z2-settings-assist-menus", Context.MODE_PRIVATE)
        preferences.edit().clear().putString("unrelated.operator.choice", "retained").commit()
        val settings = OperatorSettings(preferences)
        val stores = assistStores("z2-settings-assist-menus")
        val assist = restoreAssists(stores).shared
        val session = FakeCameraSession(CameraIdentity("SIMULATED", "SIMULATED", "settings-assists"))
        runBlocking { session.connect() }
        val originalParade = assist.paradeMode
        show(settings, OperatorSettingsTab.ASSIST, session, assists = restoreAssists(stores).also { assistsShown = it })
        fun choose(card: String, text: String) {
            composeRule.onNode(hasText(text) and hasAnyAncestor(hasTestTag("settings.assist.$card")))
                .performScrollTo().performClick()
        }
        choose("waveform", "Luma")
        composeRule.runOnIdle { assertEquals(originalParade, assistsShown.shared.paradeMode) }
        choose("parade", "YRGB")
        composeRule.onNode(hasContentDescription("Reset to defaults") and hasAnyAncestor(hasTestTag("settings.assist.waveform")))
            .performScrollTo().performClick()
        composeRule.runOnIdle {
            assertEquals(MonitorWaveformMode.RGB, assistsShown.shared.waveMode)
            assertEquals(MonitorParadeMode.YRGB, assistsShown.shared.paradeMode)
        }
        choose("waveform", "Luma")
        choose("vectorscope", "4x")
        choose("peaking", "High")
        composeRule.onNode(hasContentDescription("1.0") and hasAnyAncestor(hasTestTag("settings.assist.trafficLights")))
            .performScrollTo().performClick()
        composeRule.onNode(hasContentDescription("Reset to defaults") and hasAnyAncestor(hasTestTag("settings.assist.histogram")))
            .performScrollTo().performClick()
        composeRule.runOnIdle {
            // The histogram reset takes the shared default (coordinator decision adopt-shared).
            assertEquals(MonitorCrushClipCompensation.ZERO, assistsShown.shared.crushClipCompensation)
            assertEquals(MonitorPeakingSense.HIGH, assistsShown.shared.peakingSensitivity)
        }
        composeRule.onNode(hasContentDescription("1.0") and hasAnyAncestor(hasTestTag("settings.assist.trafficLights")))
            .performScrollTo().performClick()
        composeRule.onNodeWithText("Read").assertDoesNotExist()
        composeRule.onNodeWithText("LOG").assertDoesNotExist()
        composeRule.onNodeWithText("REFERENCE KEY").performScrollTo().assertIsDisplayed()
        val key = composeRule.onNodeWithTag("monitor.false-color.reference")
            .performScrollTo().fetchSemanticsNode().boundsInRoot
        val density = context.resources.displayMetrics.density
        for (label in listOf("Min", "−3", "18%", "Skin", "+2", "Max")) {
            val caption = composeRule.onNodeWithText(label).fetchSemanticsNode().boundsInRoot
            assertTrue("$label must fit in the caption band without inherited body line spacing",
                caption.height <= key.height - 40f * density + 1f)
            assertTrue("$label must clear the key's bottom inset", caption.bottom <= key.bottom - 7f * density + 1f)
        }
        composeRule.runOnIdle {
            val reloaded = restoreAssists(stores).shared
            assertEquals(MonitorWaveformMode.LUMA, reloaded.waveMode)
            assertEquals(MonitorParadeMode.YRGB, reloaded.paradeMode)
            assertEquals(MonitorVectorscopeZoom.X4, reloaded.vectorZoom)
            assertEquals(MonitorPeakingSense.HIGH, reloaded.peakingSensitivity)
            assertEquals(MonitorCrushClipCompensation.ONE, reloaded.crushClipCompensation)
            assertEquals("retained", preferences.getString("unrelated.operator.choice", null))
        }
        preferences.edit().clear().commit()
        stores.forEach { it.edit().clear().commit() }
    }

    @Test fun actualZebraEditorClampsOnDoneAndKeepsKnownNativeConversion() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val preferences = context.getSharedPreferences("z2-settings-number", Context.MODE_PRIVATE)
        preferences.edit().clear().commit()
        val settings = OperatorSettings(preferences)
        val assists = idleNikonAssists()
        val zebra = { assists.shared.zebraHighlightIRE.toFloat() }
        val session = FakeCameraSession(CameraIdentity("SIMULATED", "SIMULATED", "settings-number"))
        runBlocking { session.connect() }
        val properties = session.cameraProperties.value
        val input = ExposureAssistCameraInput(codec = properties.codec, iso = properties.iso, baseIso = properties.baseIso)
        assertTrue("Actual numeric page requires the packaged Swift core", SwiftCore.isAvailable)
        assertNotNull(zebraEditorValue(input, FeedZebraUnit.IRE, zebra()))
        show(settings, OperatorSettingsTab.ASSIST, session, assists = assists)
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
        composeRule.runOnIdle { assertEquals(100f, zebra()) }
        composeRule.runOnIdle {
            assists.shared.updateZebraUnit(MonitorZebraUnit.NATIVE)
        }
        enterAndFinish("999")
        composeRule.runOnIdle {
            assertEquals(zebraMonitorPercent(input, FeedZebraUnit.NATIVE, 255f),
                zebra())
        }
        enterAndFinish("128")
        composeRule.runOnIdle {
            assertEquals(zebraMonitorPercent(input, FeedZebraUnit.NATIVE, 128f),
                zebra())
        }
        val retained = zebra()
        enterAndFinish("")
        composeRule.runOnIdle { assertEquals(retained, zebra()) }
        composeRule.onNode(threshold and hasClickAction(), useUnmergedTree = true).performClick()
        composeRule.onNode(threshold and hasSetTextAction(), useUnmergedTree = true).performTextReplacement("120")
        val midtone = hasAnyAncestor(hasTestTag("settings.zebra.threshold.Midtone"))
        composeRule.onNodeWithTag("settings.zebra.threshold.Midtone", useUnmergedTree = true).performScrollTo()
        composeRule.onNode(midtone and hasClickAction(), useUnmergedTree = true).performClick()
        composeRule.onNode(midtone and hasSetTextAction(), useUnmergedTree = true).assertIsFocused()
        composeRule.onNode(threshold and hasSetTextAction(), useUnmergedTree = true).assertDoesNotExist()
        composeRule.runOnIdle {
            assertEquals(zebraMonitorPercent(input, FeedZebraUnit.NATIVE, 120f),
                zebra())
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
        val stores = assistStores("z2-display-pins")
        val kept = restoreAssists(stores).shared.pinned
        show(settings, OperatorSettingsTab.DISPLAY, assists = restoreAssists(stores))
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
            assertTrue(restoreAssists(stores).shared.pinned.isEmpty())
            assertEquals(setOf(MonitorDisplayMode.COMMAND), reloaded.enabledDisplayModes)
            assertEquals(setOf(MonitorDisplayMode.COMMAND), settings.enabledDisplayModes)
        }
        preferences.edit().clear().commit()
        stores.forEach { it.edit().clear().commit() }
    }

    private fun show(
        settings: OperatorSettings, initial: OperatorSettingsTab, session: CameraSession? = null,
        actions: SystemSettingsActions = NoExternalActions, assists: NikonAssists = idleNikonAssists(),
    ) {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val guide = LiveViewGuideController(context.getSharedPreferences("z2-settings-guide", Context.MODE_PRIVATE))
        val cache = MediaCacheStore(Files.createTempDirectory(context.cacheDir.toPath(), "z2-settings"))
        composeRule.setContent {
            OpenZCineTheme {
                OperatorSettingsScreen(
                    session = session, assists = assists,
                    settings = settings, mediaCacheStore = cache,
                    systemSettingsActions = actions,
                    bugReportSubmitter = BugReportSubmitter { error("This page fixture never submits a report") },
                    liveViewGuideController = guide, onShowGuideOnNextRealFrame = {},
                    initialTab = initial, onClose = {},
                )
            }
        }
    }

    private lateinit var assistsShown: NikonAssists

    private fun assistStores(name: String): List<SharedPreferences> {
        val context = ApplicationProvider.getApplicationContext<Context>()
        return listOf("assist", "operator", "playback").map {
            context.getSharedPreferences("$name.$it", Context.MODE_PRIVATE).apply { edit().clear().commit() }
        }
    }

    private fun restoreAssists(stores: List<SharedPreferences>) = restoreNikonAssists(stores[0], stores[1], stores[2])

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

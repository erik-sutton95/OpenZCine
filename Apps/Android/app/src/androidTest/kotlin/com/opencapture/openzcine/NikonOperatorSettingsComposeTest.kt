package com.opencapture.openzcine

import android.app.Instrumentation
import android.content.Context
import android.content.Intent
import androidx.test.platform.app.InstrumentationRegistry
import com.opencapture.opencine.core.IntegrationID
import com.opencapture.opencine.core.RouteKind
import com.opencapture.opencine.core.SavedCamera
import com.opencapture.opencine.core.SavedRoute
import android.content.SharedPreferences
import com.opencapture.monitorui.MonitorAssistTool
import com.opencapture.monitorui.MonitorParadeMode
import com.opencapture.monitorui.MonitorVectorscopeZoom
import com.opencapture.monitorui.MonitorWaveformMode
import com.opencapture.monitorui.MonitorZebraUnit
import com.opencapture.monitorui.settings.MonitorSettingsTab
import com.opencapture.opencine.media.MonitorCrushClipCompensation
import com.opencapture.opencine.media.MonitorPeakingSense
import androidx.compose.ui.test.assertContentDescriptionEquals
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.text.TextLayoutResult
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
import com.opencapture.openzcine.diagnostics.SystemSettingsActions
import com.opencapture.openzcine.media.MediaCacheStore
import com.opencapture.openzcine.settings.OperatorSettings
import com.opencapture.openzcine.settings.OperatorSettingsScreen
import com.opencapture.opencine.appkit.MonitorDisplayMode
import com.opencapture.opencine.appkit.MonitorDisplaySection
import androidx.compose.runtime.SideEffect
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
        show(settings, MonitorSettingsTab.CONTROLS)

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
        for (tab in MonitorSettingsTab.entries) {
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
        show(OperatorSettings(preferences), MonitorSettingsTab.LINK, session)
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
        }
        // Source is a web page: capture the browser intent instead of opening it. Privacy and terms
        // are bundled pages (A2-27) and never leave the app.
        val opened = mutableListOf<String>()
        val browser = object : Instrumentation.ActivityMonitor() {
            override fun onStartActivity(intent: Intent): Instrumentation.ActivityResult? =
                if (intent.action != Intent.ACTION_VIEW) null
                else Instrumentation.ActivityResult(0, null).also { opened += intent.dataString.orEmpty() }
        }
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        instrumentation.addMonitor(browser)
        try {
            show(OperatorSettings(preferences), MonitorSettingsTab.STORAGE, actions = actions)
            composeRule.onNodeWithText("Full Resolution Caching").assertDoesNotExist()
            composeRule.onNodeWithText("Local Media Cache").performScrollTo().assertIsDisplayed()
            composeRule.onNodeWithTag("monitor.settings.tab.System").performScrollTo().performClick()
            // OpenCine's reliability reporting (D2): the row is now part of the System tab.
            composeRule.onNodeWithText("Automatic error reports").performScrollTo().assertIsDisplayed()
            for (label in listOf("Open Source Code", "Open Support")) {
                composeRule.onNodeWithContentDescription(label).performScrollTo().performClick()
            }
            composeRule.runOnIdle {
                assertEquals(listOf("https://github.com/erik-sutton95/OpenZCine"), opened)
                assertEquals(listOf("support"), called)
                assertFalse(preferences.contains("cache.originals"))
            }
        } finally {
            instrumentation.removeMonitor(browser)
        }
        preferences.edit().clear().commit()
    }

    @Test fun systemTabShipsTheLegalPagesAndDiagnosticOptionsOffline() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val preferences = context.getSharedPreferences("z2-settings-legal", Context.MODE_PRIVATE)
        preferences.edit().clear().commit()
        show(OperatorSettings(preferences), MonitorSettingsTab.SYSTEM)
        composeRule.onNodeWithText("Diagnostic options").performScrollTo().assertIsDisplayed()
        composeRule.onNodeWithText("Share Diagnostics").assertDoesNotExist()
        for ((page, attribution) in listOf("licenses" to "Apache License, Version 2.0",
            "notice" to "not affiliated with or endorsed by Nikon Corporation",
            "privacy" to "OpenCapture is the data controller",
            "terms" to "not affiliated with, endorsed by, or supported by Nikon")) {
            val document = hasAnyAncestor(hasTestTag("legal.document.$page"))
            val open = mapOf("licenses" to "Open Licenses", "notice" to "Open NOTICE",
                "privacy" to "Open Privacy Policy", "terms" to "Open Terms of Use").getValue(page)
            composeRule.onNodeWithContentDescription(open).performScrollTo().performClick()
            composeRule.onNodeWithTag("legal.document.$page").assertIsDisplayed()
            composeRule.onNode(hasText(attribution, substring = true) and document).assertExists()
            composeRule.onNode(hasContentDescription("Close") and document).performClick()
            composeRule.onNodeWithTag("legal.document.$page").assertDoesNotExist()
        }
        preferences.edit().clear().commit()
    }

    @Test fun clearingTheCacheAsksFirst() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val preferences = context.getSharedPreferences("z2-settings-clear", Context.MODE_PRIVATE)
        preferences.edit().clear().commit()
        show(OperatorSettings(preferences), MonitorSettingsTab.STORAGE)
        composeRule.onNodeWithText("Clear").performScrollTo().performClick()
        composeRule.onNodeWithText("Clear cache?").assertIsDisplayed()
        composeRule.onNodeWithText("Cancel").performClick()
        composeRule.onNodeWithText("Clear cache?").assertDoesNotExist()
        preferences.edit().clear().commit()
    }

    @Test fun linkHealthScaleIsPresentBeforeACameraLinks() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val preferences = context.getSharedPreferences("z2-settings-link-health", Context.MODE_PRIVATE)
        preferences.edit().clear().commit()
        show(OperatorSettings(preferences), MonitorSettingsTab.LINK)
        composeRule.onNodeWithText("Link Health").assertIsDisplayed()
        composeRule.onNodeWithText(context.getString(R.string.settings_link_no_camera_caption)).assertIsDisplayed()
        preferences.edit().clear().commit()
    }

    @Test fun linkTabListsTheSavedSetups() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val preferences = context.getSharedPreferences("z2-settings-saved", Context.MODE_PRIVATE)
        preferences.edit().clear().commit()
        val saved = SavedCamera(id = "SIMULATED-saved", integration = IntegrationID("nikon"), name = "B camera",
            advertisedName = "Z6_3", model = "Z6III",
            routes = listOf(SavedRoute(key = "ap", kind = RouteKind.CAMERA_ACCESS_POINT, network = "Z6III_SIMULATED")))
        show(OperatorSettings(preferences), MonitorSettingsTab.LINK, savedCameras = listOf(saved))
        composeRule.onNodeWithText("Your cameras").performScrollTo().assertIsDisplayed()
        composeRule.onNodeWithText("B camera").performScrollTo().assertIsDisplayed()
        composeRule.onNodeWithText("Z6III_SIMULATED").assertIsDisplayed()
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
        show(settings, MonitorSettingsTab.ASSIST, session, assists = restoreAssists(stores).also { assistsShown = it })
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
        // The Nikon source supports the Read choice (LOG reads the source signal, 709 the
        // monitor look); the card offers it next to the scale choices.
        val falseColor = hasAnyAncestor(hasTestTag("settings.assist.falseColor"))
        composeRule.onNode(hasText("Read") and falseColor).performScrollTo().assertIsDisplayed()
        composeRule.onNode(hasText("LOG") and falseColor).assertIsDisplayed()
        composeRule.onNode(hasText("709") and falseColor).assertIsDisplayed()
        composeRule.onNodeWithText("REFERENCE KEY").performScrollTo().assertIsDisplayed()
        val key = composeRule.onNodeWithTag("monitor.false-color.reference")
            .performScrollTo().fetchSemanticsNode().boundsInRoot
        val density = context.resources.displayMetrics.density
        composeRule.onNodeWithText("CineStop · L3G10").assertIsDisplayed()
        // The V2 payload calibrates these six markers for this fixture's source curve.
        // Keep the original caption height and bottom-inset bounds for every marker.
        for (label in listOf("−6", "−4", "−2", "18%", "+2", "clip")) {
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
        assertNotNull(zebraEditorValue(input, MonitorZebraUnit.IRE, zebra()))
        show(settings, MonitorSettingsTab.ASSIST, session, assists = assists)
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
            assertEquals(zebraMonitorPercent(input, MonitorZebraUnit.NATIVE, 255f),
                zebra())
        }
        enterAndFinish("128")
        composeRule.runOnIdle {
            assertEquals(zebraMonitorPercent(input, MonitorZebraUnit.NATIVE, 128f),
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
            assertEquals(zebraMonitorPercent(input, MonitorZebraUnit.NATIVE, 120f),
                zebra())
        }
        composeRule.onNode(midtone and hasSetTextAction(), useUnmergedTree = true).performImeAction()
        preferences.edit().clear().commit()
    }

    @Test fun actualCommonDisplayWritesTheOneSharedLayoutPerMode() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val preferences = context.getSharedPreferences("z2-display-shared", Context.MODE_PRIVATE)
        preferences.edit().clear().putString("unrelated.operator.choice", "retained").commit()
        val settings = OperatorSettings(preferences)
        val record = settings.displayPreferences.live.isVisible(MonitorDisplaySection.RAIL_RECORD)
        show(settings, MonitorSettingsTab.DISPLAY)
        composeRule.onNodeWithText("DISP 1 · Live").performScrollTo().performClick()
        // No live monitor under these settings, so Edit view has nothing to open on.
        composeRule.onNodeWithTag("monitor.settings.display.edit.LIVE").assertDoesNotExist()
        composeRule.onNodeWithTag("monitor.settings.display.toggle.LIVE.RAIL_RECORD").performScrollTo().performClick()
        composeRule.runOnIdle {
            val reloaded = OperatorSettings(preferences).displayPreferences
            assertEquals(!record, reloaded.live.isVisible(MonitorDisplaySection.RAIL_RECORD))
            assertEquals(record, reloaded.command.isVisible(MonitorDisplaySection.RAIL_RECORD))
            assertEquals("retained", preferences.getString("unrelated.operator.choice", null))
        }
        composeRule.onNodeWithText("DISP 3 · Command").performScrollTo().performClick()
        composeRule.onNodeWithTag("monitor.settings.display.edit.COMMAND").assertDoesNotExist()
        composeRule.onNodeWithTag("monitor.settings.display.toggle.COMMAND.RAIL_RECORD").performScrollTo().assertIsDisplayed()
        preferences.edit().clear().commit()
    }

    @Test fun actualCommonDisplayOffersEditViewOverALiveMonitor() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val preferences = context.getSharedPreferences("z2-display-edit", Context.MODE_PRIVATE)
        preferences.edit().clear().commit()
        show(OperatorSettings(preferences), MonitorSettingsTab.DISPLAY, editsLiveView = true)
        composeRule.onNodeWithText("DISP 1 · Live").performScrollTo().performClick()
        composeRule.onNodeWithTag("monitor.settings.display.edit.LIVE").performScrollTo().assertIsDisplayed()
        preferences.edit().clear().commit()
    }

    @Test fun actualCommonDisplayContainsFullLabelsAndSwitchesInsideEachCard() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val preferences = context.getSharedPreferences("z2-display-label-fit", Context.MODE_PRIVATE)
        preferences.edit().clear().commit()
        show(OperatorSettings(preferences), MonitorSettingsTab.DISPLAY)
        composeRule.onNodeWithText("DISP 1 · Live").performScrollTo().performClick()
        for ((id, label) in listOf("LIVE.CAMERA_VALUES" to "Camera Values", "LIVE.FORMAT" to "Format")) {
            // The shared row (iOS MonitorDisplaySections twin): the full label leads, its switch trails on the
            // same line and is named by the label.
            val toggle = composeRule.onNodeWithTag("monitor.settings.display.toggle.$id", useUnmergedTree = true)
                .performScrollTo().assertIsDisplayed().assertContentDescriptionEquals(label)
            val switch = toggle.fetchSemanticsNode().boundsInRoot
            val text = composeRule.onAllNodes(hasText(label), useUnmergedTree = true).fetchSemanticsNodes()
                .single { it.boundsInRoot.center.y in switch.top..switch.bottom }
            val layout = mutableListOf<TextLayoutResult>()
            text.config[SemanticsActions.GetTextLayoutResult].action?.invoke(layout)
            assertTrue("$label is drawn whole on one line", layout.single().let { it.lineCount == 1 && !it.isLineEllipsized(0) })
            assertTrue("$label must leave room for its complete switch", text.boundsInRoot.right <= switch.left)
        }
        preferences.edit().clear().commit()
    }

    @Test fun actualCommonDisplayPreservesEmptyCleanPins() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val preferences = context.getSharedPreferences("z2-display-pins", Context.MODE_PRIVATE)
        preferences.edit().clear().commit()
        val settings = OperatorSettings(preferences)
        val stores = assistStores("z2-display-pins")
        val kept = restoreAssists(stores).shared.pinned
        show(settings, MonitorSettingsTab.DISPLAY, assists = restoreAssists(stores))
        composeRule.onNodeWithText("DISP 2 · Clean").performScrollTo().performClick()
        for (tool in kept) {
            composeRule.onNodeWithTag("monitor.settings.display.toggle.clean.pin.${tool.name}")
                .performScrollTo().performClick()
        }
        composeRule.runOnIdle { assertTrue(restoreAssists(stores).shared.pinned.isEmpty()) }
        preferences.edit().clear().commit()
        stores.forEach { it.edit().clear().commit() }
    }

    // F05 replaced app-private capture layouts with one shared layout per declared DISP mode.
    @Test fun actualSharedDisplayPersistsDeclaredModesAndRetiresOnlyTheCurrentEditor() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val preferences = context.getSharedPreferences("z2-display-declared", Context.MODE_PRIVATE)
        preferences.edit().clear().putString("unrelated.operator.choice", "retained").commit()
        val settings = OperatorSettings(preferences)
        val liveRecord = settings.displayPreferences.live.isVisible(MonitorDisplaySection.RAIL_RECORD)
        val commandRecord = settings.displayPreferences.command.isVisible(MonitorDisplaySection.RAIL_RECORD)
        val offersEditor = androidx.compose.runtime.mutableStateOf(true)
        show(settings, MonitorSettingsTab.DISPLAY, editorAvailable = { offersEditor.value })
        composeRule.onNodeWithText("DISP 1 · Live").performScrollTo().performClick()
        composeRule.onNodeWithTag("monitor.settings.display.edit.LIVE").performScrollTo().assertIsDisplayed()
        composeRule.onNodeWithTag("monitor.settings.display.toggle.LIVE.RAIL_RECORD").performScrollTo().performClick()
        composeRule.runOnIdle {
            val reloaded = OperatorSettings(preferences).displayPreferences
            assertEquals(!liveRecord, reloaded.live.isVisible(MonitorDisplaySection.RAIL_RECORD))
            assertEquals(commandRecord, reloaded.command.isVisible(MonitorDisplaySection.RAIL_RECORD))
            assertEquals("retained", preferences.getString("unrelated.operator.choice", null))
            operatorSessionShown.synchronize("SIMULATED-first-display-source")
        }
        composeRule.onNodeWithTag("monitor.settings.display.edit.LIVE").performScrollTo().performClick()
        composeRule.runOnIdle {
            assertEquals(MonitorDisplayMode.LIVE, operatorSessionShown.editingMode)
            operatorSessionShown.synchronize("SIMULATED-successor-display-source")
            assertEquals(null, operatorSessionShown.editingMode)
            offersEditor.value = false
        }
        composeRule.onNodeWithTag("monitor.settings.display.edit.LIVE").assertDoesNotExist()
        composeRule.runOnIdle { offersEditor.value = true }
        composeRule.onNodeWithTag("monitor.settings.display.edit.LIVE").performScrollTo().assertIsDisplayed()
        preferences.edit().clear().commit()
    }

    // Declared capabilities replace the retired enabledDisplayModes preference; empty pins persist.
    @Test fun actualSharedDisplayKeepsEmptyCleanPinsAcrossDeclaredModeChanges() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val preferences = context.getSharedPreferences("z2-display-declared-pins", Context.MODE_PRIVATE)
        preferences.edit().clear().putString("unrelated.operator.choice", "retained").commit()
        val settings = OperatorSettings(preferences)
        val stores = assistStores("z2-display-declared-pins")
        val kept = restoreAssists(stores).shared.pinned
        val modes = androidx.compose.runtime.mutableStateOf(listOf(MonitorDisplayMode.LIVE, MonitorDisplayMode.CLEAN, MonitorDisplayMode.COMMAND))
        show(settings, MonitorSettingsTab.DISPLAY, assists = restoreAssists(stores), declaredModes = { modes.value })
        composeRule.onNodeWithText("DISP 2 · Clean").performScrollTo().performClick()
        for (tool in kept) {
            composeRule.onNodeWithTag("monitor.settings.display.toggle.clean.pin.${tool.name}")
                .performScrollTo().performClick()
        }
        composeRule.runOnIdle {
            assertTrue(restoreAssists(stores).shared.pinned.isEmpty())
            modes.value = listOf(MonitorDisplayMode.COMMAND)
        }
        composeRule.onNodeWithText("DISP 1 · Live").assertDoesNotExist()
        composeRule.onNodeWithText("DISP 2 · Clean").assertDoesNotExist()
        composeRule.onNodeWithText("DISP 3 · Command").performScrollTo().assertIsDisplayed()
        composeRule.runOnIdle {
            assertEquals(listOf(MonitorDisplayMode.COMMAND), operatorSessionShown.modes)
            assertEquals(MonitorDisplayMode.COMMAND, operatorSessionShown.mode)
            assertTrue(restoreAssists(stores).shared.pinned.isEmpty())
            assertEquals("retained", preferences.getString("unrelated.operator.choice", null))
            modes.value = emptyList()
        }
        composeRule.onNodeWithText("DISP 3 · Command").performScrollTo().assertIsDisplayed()
        composeRule.runOnIdle {
            assertEquals(listOf(MonitorDisplayMode.COMMAND), operatorSessionShown.modes)
            assertTrue(restoreAssists(stores).shared.pinned.isEmpty())
        }
        preferences.edit().clear().commit()
        stores.forEach { it.edit().clear().commit() }
    }

    private fun show(
        settings: OperatorSettings, initial: MonitorSettingsTab, session: CameraSession? = null,
        actions: SystemSettingsActions = NoExternalActions, assists: NikonAssists = idleNikonAssists(),
        editsLiveView: Boolean = false,
        /** The modes a mounted video monitor declares (Command is the body's dashboard, DISP 3). */
        modes: List<MonitorDisplayMode> = listOf(MonitorDisplayMode.LIVE, MonitorDisplayMode.CLEAN, MonitorDisplayMode.COMMAND),
        savedCameras: List<SavedCamera> = emptyList(),
        declaredModes: (() -> List<MonitorDisplayMode>)? = null,
        editorAvailable: (() -> Boolean)? = null,
    ) {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val cache = MediaCacheStore(Files.createTempDirectory(context.cacheDir.toPath(), "z2-settings"))
        composeRule.setContent {
            OpenZCineTheme {
                val operatorSession = rememberTestOperatorSession(assists, settings)
                val offered = declaredModes?.invoke() ?: modes
                val editsCurrentLiveView = editorAvailable?.invoke() ?: editsLiveView
                SideEffect { operatorSession.declare(offered); operatorSessionShown = operatorSession }
                OperatorSettingsScreen(
                    session = session, assists = assists,
                    operatorSession = operatorSession, editsLiveView = editsCurrentLiveView,
                    settings = settings, mediaCacheStore = cache,
                    systemSettingsActions = actions,
                    onReportProblem = {},
                    initialTab = initial, savedCameras = savedCameras, onClose = {},
                )
            }
        }
    }

    private lateinit var operatorSessionShown: com.opencapture.opencine.appkit.MonitorOperatorSessionModel
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
        override fun openSource(): Boolean = false
        override fun openPrivacy(): Boolean = false
        override fun openTerms(): Boolean = false
        override fun shareDiagnostics(): Boolean = false
    }
}

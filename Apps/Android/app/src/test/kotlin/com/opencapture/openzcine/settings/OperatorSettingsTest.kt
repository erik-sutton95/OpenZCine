package com.opencapture.openzcine.settings

import com.opencapture.openzcine.TestSharedPreferences
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class OperatorSettingsTest {
    private val store = TestSharedPreferences()

    @Test
    fun `readouts default visible`() {
        val settings = OperatorSettings(store)
        assertTrue(settings.statusBarVisible.value)
        assertTrue(settings.sideRailsVisible.value)
        assertTrue(settings.assistToolbarVisible.value)
        assertTrue(settings.cameraValuesVisible.value)
        assertTrue(settings.recReadoutVisible.value)
        assertTrue(settings.codecReadoutVisible.value)
        assertTrue(settings.mediaReadoutVisible.value)
        assertTrue(settings.fpsReadoutVisible.value)
        assertTrue(settings.recordConfirmationEnabled.value)
        assertTrue(settings.mediaRemoteShutterEnabled.value)
        assertTrue(settings.hapticsEnabled.value)
        assertTrue(settings.keepScreenAwake.value)
        assertTrue(settings.autoRotateFeedEnabled.value)
        // The focus dial is opt-in on a fresh install, in video and photo mode alike.
        assertFalse(settings.mfDriveScrubEnabled.value)
        assertEquals(LocalLevelStyle.HORIZON, settings.levelStyle)
        assertEquals(LiveViewStreamPreset.QUALITY, settings.streamPreset)
        assertEquals(LiveViewQualityBias.BALANCED, settings.qualityBias)
        assertEquals(PortraitFeedAspect.FIT_16_9, settings.portraitFeedAspect)
        assertEquals(MonitorDisplayMode.entries.toList(), settings.displayModeOrder)
        assertEquals(MonitorDisplayMode.entries.toSet(), settings.enabledDisplayModes)
    }

    @Test
    fun `toggle writes through and survives a reload`() {
        OperatorSettings(store).apply {
            fpsReadoutVisible.toggle()
            sideRailsVisible.toggle()
        }
        val reloaded = OperatorSettings(store)
        assertEquals(false, reloaded.fpsReadoutVisible.value)
        assertEquals(false, reloaded.sideRailsVisible.value)
    }

    @Test
    fun `DISP order enablement and cycling persist`() {
        val settings = OperatorSettings(store)
        settings.moveDisplayMode(MonitorDisplayMode.COMMAND, targetIndex = 0)
        assertTrue(settings.toggleDisplayMode(MonitorDisplayMode.CLEAN))

        val restored = OperatorSettings(store)
        assertEquals(
            listOf(
                MonitorDisplayMode.COMMAND,
                MonitorDisplayMode.LIVE,
                MonitorDisplayMode.CLEAN,
            ),
            restored.displayModeOrder,
        )
        assertEquals(
            setOf(MonitorDisplayMode.LIVE, MonitorDisplayMode.COMMAND),
            restored.enabledDisplayModes,
        )
        assertEquals(
            MonitorDisplayMode.COMMAND,
            restored.nextDisplayMode(MonitorDisplayMode.LIVE),
        )
        assertEquals(
            MonitorDisplayMode.LIVE,
            restored.nextDisplayMode(MonitorDisplayMode.COMMAND),
        )
        assertEquals(
            MonitorDisplayMode.COMMAND,
            restored.nextDisplayMode(MonitorDisplayMode.CLEAN),
        )
        assertEquals(
            MonitorDisplayMode.LIVE,
            restored.displayModeForExplicitRequest(MonitorDisplayMode.LIVE),
        )
        assertEquals(
            null,
            restored.displayModeForExplicitRequest(MonitorDisplayMode.CLEAN),
        )
    }

    @Test
    fun `DISP persistence reconciles unknown duplicate and missing values deterministically`() {
        store.edit()
            .putString("display.disp.order.v1", "command,UNKNOWN,command,live")
            .putStringSet("display.disp.enabled.v1", linkedSetOf("UNKNOWN", "clean"))
            .apply()

        val settings = OperatorSettings(store)

        assertEquals(
            listOf(
                MonitorDisplayMode.COMMAND,
                MonitorDisplayMode.LIVE,
                MonitorDisplayMode.CLEAN,
            ),
            settings.displayModeOrder,
        )
        assertEquals(setOf(MonitorDisplayMode.CLEAN), settings.enabledDisplayModes)
        assertEquals(
            "COMMAND,LIVE,CLEAN",
            store.getString("display.disp.order.v1", null),
        )
        assertEquals(
            mutableSetOf("CLEAN"),
            store.getStringSet("display.disp.enabled.v1", mutableSetOf()),
        )
        assertEquals(
            MonitorDisplayMode.CLEAN,
            settings.reconciledDisplayMode(MonitorDisplayMode.LIVE),
        )
        assertFalse(settings.toggleDisplayMode(MonitorDisplayMode.CLEAN))
        assertEquals(setOf(MonitorDisplayMode.CLEAN), settings.enabledDisplayModes)
    }

    @Test
    fun `corrupt empty enabled DISP set recovers all safe defaults`() {
        store.edit()
            .putStringSet("display.disp.enabled.v1", linkedSetOf("UNKNOWN"))
            .apply()

        val settings = OperatorSettings(store)

        assertEquals(MonitorDisplayMode.entries.toSet(), settings.enabledDisplayModes)
        assertEquals(
            MonitorDisplayMode.entries.mapTo(linkedSetOf<String>()) { it.name },
            store.getStringSet("display.disp.enabled.v1", mutableSetOf()),
        )
    }

    @Test
    fun `link preview choices persist separately from camera settings`() {
        OperatorSettings(store).apply {
            streamPreset = LiveViewStreamPreset.QUALITY
            qualityBias = LiveViewQualityBias.DETAIL
        }

        val restored = OperatorSettings(store)
        assertEquals(LiveViewStreamPreset.QUALITY, restored.streamPreset)
        assertEquals(LiveViewQualityBias.DETAIL, restored.qualityBias)
        assertEquals("QUALITY", store.getString("link.streamPreset.v1", null))
        assertEquals("DETAIL", store.getString("link.qualityBias.v1", null))
    }

    @Test
    fun `portrait feed aspect defaults to fit and persists fill`() {
        val settings = OperatorSettings(store)
        assertEquals(PortraitFeedAspect.FIT_16_9, settings.portraitFeedAspect)

        settings.portraitFeedAspect = PortraitFeedAspect.FILL

        assertEquals(PortraitFeedAspect.FILL, OperatorSettings(store).portraitFeedAspect)
        assertEquals("FILL", store.getString("display.portraitFeedAspect.v1", null))
    }

    @Test
    fun `storage keys never collide`() {
        val keys = OperatorSettings(store).all.map { it.key }
        assertEquals(keys.size, keys.toSet().size)
    }

    @Test
    fun `local monitor controls persist and drive the screen awake policy`() {
        OperatorSettings(store).apply {
            statusBarVisible.toggle()
            sideRailsVisible.toggle()
            assistToolbarVisible.toggle()
            cameraValuesVisible.toggle()
            recordConfirmationEnabled.toggle()
            mediaRemoteShutterEnabled.toggle()
            keepScreenAwake.toggle()
            autoRotateFeedEnabled.toggle()
        }

        val restored = OperatorSettings(store)
        assertFalse(restored.statusBarVisible.value)
        assertFalse(restored.sideRailsVisible.value)
        assertFalse(restored.assistToolbarVisible.value)
        assertFalse(restored.cameraValuesVisible.value)
        assertFalse(restored.recordConfirmationEnabled.value)
        assertFalse(restored.mediaRemoteShutterEnabled.value)
        assertFalse(restored.shouldKeepScreenAwake(monitorPresented = true))
        assertFalse(restored.shouldKeepScreenAwake(monitorPresented = false))
        assertFalse(restored.autoRotateFeedEnabled.value)
    }

    @Test
    fun `level style persists and malformed values fall back to the horizon`() {
        OperatorSettings(store).levelStyle = LocalLevelStyle.GAUGE
        assertEquals(LocalLevelStyle.GAUGE, OperatorSettings(store).levelStyle)

        store.edit().putString("assist.local.levelStyle.v1", "NOT_A_LEVEL_STYLE").apply()
        assertEquals(LocalLevelStyle.HORIZON, OperatorSettings(store).levelStyle)
    }

    @Test
    fun `version text matches the iOS format`() {
        assertEquals("0.1.117 (42)", appVersionText("0.1.117", 42))
    }

    @Test
    fun `chrome is configured per DISP mode and clean defaults to a bare image`() {
        val settings = OperatorSettings(store)
        val clean = settings.chrome(MonitorDisplayMode.CLEAN)

        assertTrue(settings.chrome(MonitorDisplayMode.LIVE).statusBar.value)
        assertFalse(clean.statusBar.value)
        assertFalse(clean.assistToolbar.value)
        assertFalse(clean.cameraValues.value)
        assertFalse(clean.lockButton.value)
        // Clean keeps what the operator needs to work in it and get back out.
        assertTrue(clean.batteryIndicators.value)
        assertTrue(clean.focusBox.value)
        assertTrue(clean.railDisp.value)
        assertTrue(clean.railRecord.value)
        assertTrue(clean.railMedia.value)
        assertTrue(clean.railSettings.value)
        // Switching the bar back on in clean should yield a complete bar.
        assertTrue(clean.fpsReadout.value)
    }

    @Test
    fun `video and photo layouts are independent and start identical`() {
        val settings = OperatorSettings(store)

        assertTrue(
            settings.chrome(MonitorDisplayMode.LIVE, CaptureLayoutMode.PHOTO).assistToolbar.value,
        )
        settings.toggleChrome(
            ChromeSection.ASSIST_TOOLBAR,
            MonitorDisplayMode.LIVE,
            CaptureLayoutMode.PHOTO,
        )
        assertFalse(
            settings.chrome(MonitorDisplayMode.LIVE, CaptureLayoutMode.PHOTO).assistToolbar.value,
        )
        assertTrue(
            settings.chrome(MonitorDisplayMode.LIVE, CaptureLayoutMode.VIDEO).assistToolbar.value,
            "a stills operator's layout must not reshape the cinema one",
        )
    }

    @Test
    fun `every rail control is hideable but record and settings cannot strand the operator`() {
        val settings = OperatorSettings(store)
        val full =
            settings.sideRailPlan(
                MonitorDisplayMode.LIVE,
                CaptureLayoutMode.VIDEO,
                interfaceLocked = false,
                recordingOrPending = false,
            )
        assertTrue(full.disp && full.record && full.media && full.settings)

        MonitorDisplayMode.entries.forEach { mode ->
            ChromeSection.railControls.forEach { settings.chrome(mode)[it].value = false }
        }
        val stripped =
            settings.sideRailPlan(
                MonitorDisplayMode.LIVE,
                CaptureLayoutMode.VIDEO,
                interfaceLocked = false,
                recordingOrPending = false,
            )
        assertTrue(stripped.disp, "the DISP key is never hideable — it is the only way to change mode")
        assertFalse(stripped.media)
        assertFalse(stripped.record, "standby record is the operator's to hide")
        assertTrue(stripped.settings, "Settings is the only route back to these switches")
        assertTrue(
            settings.sideRailPlan(
                MonitorDisplayMode.LIVE,
                CaptureLayoutMode.VIDEO,
                interfaceLocked = false,
                recordingOrPending = true,
            ).record,
        )
    }

    @Test
    fun `a hidden lock key still renders while controls are locked`() {
        val settings = OperatorSettings(store)
        MonitorDisplayMode.entries.forEach {
            // Clean already ships with the key off, so set rather than toggle.
            settings.chrome(it)[ChromeSection.LOCK_BUTTON].value = false
        }
        MonitorDisplayMode.entries.forEach { mode ->
            assertFalse(
                settings.sideRailPlan(
                    mode,
                    CaptureLayoutMode.VIDEO,
                    interfaceLocked = false,
                    recordingOrPending = false,
                ).lock,
            )
            assertTrue(
                settings.sideRailPlan(
                    mode,
                    CaptureLayoutMode.VIDEO,
                    interfaceLocked = true,
                    recordingOrPending = false,
                ).lock,
                "the lock key is the only control that clears the lock",
            )
        }
    }

    @Test
    fun `toggling one mode's chrome leaves the others alone`() {
        val settings = OperatorSettings(store)

        settings.toggleChrome(ChromeSection.STATUS_BAR, MonitorDisplayMode.CLEAN)
        assertTrue(settings.chrome(MonitorDisplayMode.CLEAN).statusBar.value)
        assertTrue(settings.chrome(MonitorDisplayMode.LIVE).statusBar.value)

        settings.toggleChrome(ChromeSection.STATUS_BAR, MonitorDisplayMode.LIVE)
        assertFalse(settings.chrome(MonitorDisplayMode.LIVE).statusBar.value)
        assertTrue(settings.chrome(MonitorDisplayMode.CLEAN).statusBar.value)

        settings.resetChromeVisibility(MonitorDisplayMode.CLEAN)
        assertFalse(settings.chrome(MonitorDisplayMode.CLEAN).statusBar.value)
        assertFalse(
            settings.chrome(MonitorDisplayMode.LIVE).statusBar.value,
            "resetting one mode must not touch another",
        )
    }

    @Test
    fun `sections a mode does not own are not toggleable`() {
        val settings = OperatorSettings(store)

        assertFalse(ChromeSection.STATUS_BAR.isConfigurableIn(MonitorDisplayMode.COMMAND))
        assertFalse(ChromeSection.FOCUS_BOX.isConfigurableIn(MonitorDisplayMode.COMMAND))
        assertFalse(ChromeSection.SIDE_RAILS.isConfigurableIn(MonitorDisplayMode.LIVE))
        assertFalse(ChromeSection.SIDE_RAILS.isConfigurableIn(MonitorDisplayMode.CLEAN))
        // Clean is DISP 1 with different defaults, not a smaller feature.
        assertTrue(ChromeSection.LOCK_BUTTON.isConfigurableIn(MonitorDisplayMode.CLEAN))
        assertEquals(
            ChromeSection.configurableIn(MonitorDisplayMode.LIVE),
            ChromeSection.configurableIn(MonitorDisplayMode.CLEAN),
        )
        assertTrue(ChromeSection.LOCK_BUTTON.isConfigurableIn(MonitorDisplayMode.COMMAND))
        // 15, not 16: the DISP key is never offered anywhere.
        assertFalse(ChromeSection.RAIL_DISP.isConfigurableIn(MonitorDisplayMode.LIVE))
        assertFalse(ChromeSection.RAIL_DISP.isConfigurableIn(MonitorDisplayMode.CLEAN))
        assertEquals(15, ChromeSection.configurableIn(MonitorDisplayMode.LIVE).size)
        assertEquals(
            listOf(
                ChromeSection.LOCK_BUTTON,
                ChromeSection.BATTERY_INDICATORS,
                ChromeSection.RAIL_RECORD,
                ChromeSection.RAIL_MEDIA,
                ChromeSection.RAIL_SETTINGS,
            ),
            ChromeSection.configurableIn(MonitorDisplayMode.COMMAND),
        )

        settings.toggleChrome(ChromeSection.STATUS_BAR, MonitorDisplayMode.COMMAND)
        assertTrue(
            settings.chrome(MonitorDisplayMode.COMMAND).statusBar.value,
            "a non-owned section must not flip",
        )
    }

    @Test
    fun `command inherits the operator's existing chrome so no monitor changes on update`() {
        // A store written before chrome went per-mode: only the original global keys exist.
        store.edit().putBoolean("display.sideRails", false)
            .putBoolean("display.batteryIndicators", false).apply()

        val settings = OperatorSettings(store)

        // The one stored whole-rail value expands into all four of its controls, so an operator
        // who hid the rail does not find it back on their monitor after the split.
        ChromeSection.railControls.forEach {
            assertFalse(settings.chrome(MonitorDisplayMode.LIVE)[it].value)
            assertFalse(settings.chrome(MonitorDisplayMode.COMMAND)[it].value)
            // …and into both capture sides.
            assertFalse(settings.chrome(MonitorDisplayMode.LIVE, CaptureLayoutMode.PHOTO)[it].value)
        }
        assertFalse(settings.chrome(MonitorDisplayMode.COMMAND).batteryIndicators.value)
        // Clean still lands on its own documented default, not the inherited one.
        ChromeSection.railControls.forEach {
            assertTrue(settings.chrome(MonitorDisplayMode.CLEAN)[it].value)
        }
    }

    @Test
    fun `the chrome editor mode is session only`() {
        val settings = OperatorSettings(store)
        assertEquals(null, settings.chromeEditorMode)
        settings.beginChromeEditing(MonitorDisplayMode.CLEAN)
        assertEquals(MonitorDisplayMode.CLEAN, settings.chromeEditorMode)
        settings.endChromeEditing()
        assertEquals(null, settings.chromeEditorMode)
        // Nothing was written, so a relaunch never resumes the editor.
        assertEquals(null, OperatorSettings(store).chromeEditorMode)
    }
}

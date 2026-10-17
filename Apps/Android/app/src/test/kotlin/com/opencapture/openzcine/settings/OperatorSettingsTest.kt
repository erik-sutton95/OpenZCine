package com.opencapture.openzcine.settings

import com.opencapture.opencine.appkit.MonitorDisplayChrome
import com.opencapture.opencine.appkit.MonitorDisplayMode
import com.opencapture.opencine.appkit.MonitorDisplaySection
import com.opencapture.opencine.cameracontrols.PortraitFeedAspect
import com.opencapture.openzcine.TestSharedPreferences
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class OperatorSettingsTest {
    private val store = TestSharedPreferences()

    @Test
    fun `controls default on and the focus dial off`() {
        val settings = OperatorSettings(store)
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
        assertEquals(PortraitFeedAspect.FIT_16X9, settings.portraitFeedAspect)
    }

    @Test
    fun `toggle writes through and survives a reload`() {
        OperatorSettings(store).apply {
            hapticsEnabled.toggle()
            mfDriveScrubEnabled.toggle()
        }
        val reloaded = OperatorSettings(store)
        assertEquals(false, reloaded.hapticsEnabled.value)
        assertEquals(true, reloaded.mfDriveScrubEnabled.value)
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
        assertEquals(PortraitFeedAspect.FIT_16X9, settings.portraitFeedAspect)

        settings.portraitFeedAspect = PortraitFeedAspect.FILL

        assertEquals(PortraitFeedAspect.FILL, OperatorSettings(store).portraitFeedAspect)
        assertEquals("FILL", store.getString("display.portraitFeedAspect.v1", null))
    }

    @Test
    fun `shared operator preferences read and write the existing safety keys`() {
        val fresh = OperatorSettings(TestSharedPreferences()).operatorPreferences
        assertTrue(fresh.haptics && fresh.keepScreenAwake && fresh.recordConfirmation)
        // Values an earlier release stored under Z's keys come through the shared owner unchanged.
        store.edit().putBoolean("controls.haptics", false).putBoolean("controls.keepScreenAwake", false)
            .putBoolean("controls.recordConfirmation", false).commit()
        val settings = OperatorSettings(store)
        val shared = settings.operatorPreferences
        assertFalse(shared.haptics || shared.keepScreenAwake || shared.recordConfirmation)
        assertFalse(settings.hapticsEnabled.value || settings.keepScreenAwake.value || settings.recordConfirmationEnabled.value)
        settings.hapticsEnabled.toggle()
        settings.keepScreenAwake.toggle()
        settings.recordConfirmationEnabled.toggle()
        assertTrue(shared.haptics && shared.keepScreenAwake && shared.recordConfirmation)
        val keys = listOf("controls.haptics", "controls.keepScreenAwake", "controls.recordConfirmation")
        assertTrue(keys.all { store.getBoolean(it, false) })
        assertEquals(keys.toSet(), store.all.keys)
    }

    @Test
    fun `storage keys never collide`() {
        val keys = OperatorSettings(store).all.map { it.key }
        assertEquals(keys.size, keys.toSet().size)
    }

    @Test
    fun `local monitor controls persist and drive the screen awake policy`() {
        OperatorSettings(store).apply {
            recordConfirmationEnabled.toggle()
            mediaRemoteShutterEnabled.toggle()
            keepScreenAwake.toggle()
            autoRotateFeedEnabled.toggle()
        }

        val restored = OperatorSettings(store)
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
    fun `a fresh install keeps following the shared display defaults`() {
        val display = OperatorSettings(store).displayPreferences
        MonitorDisplayMode.entries.forEach { assertFalse(display.hasStoredLayout(it)) }
        assertEquals(MonitorDisplayChrome.liveDefaults, display.live)
        assertEquals(MonitorDisplayChrome.cleanDefaults, display.clean)
    }

    @Test
    fun `the retired video-side chrome seeds each DISP layout once`() {
        store.edit()
            .putBoolean("display.statusBar", false)
            .putBoolean("display.sideRails", false)
            .putBoolean("display.railSettings", true)
            .putBoolean("display.clean.lockButton", true)
            .putBoolean("display.photo.cameraValues", false)
            .apply()
        val display = OperatorSettings(store).displayPreferences

        // DISP 1: its own switches; a rail switch never stored follows the older whole-rail switch.
        assertFalse(display.live.isVisible(MonitorDisplaySection.STATUS_BAR))
        assertFalse(display.live.isVisible(MonitorDisplaySection.RAIL_RECORD))
        assertFalse(display.live.isVisible(MonitorDisplaySection.RAIL_MEDIA))
        assertTrue(display.live.isVisible(MonitorDisplaySection.RAIL_SETTINGS))
        // The photo side retires: its switches carry nowhere.
        assertTrue(display.live.isVisible(MonitorDisplaySection.CAMERA_VALUES))
        // DISP 2 keeps its bare defaults apart from what the operator stored.
        assertTrue(display.clean.isVisible(MonitorDisplaySection.LOCK_BUTTON))
        assertFalse(display.clean.isVisible(MonitorDisplaySection.STATUS_BAR))
        // DISP 3 inherits DISP 1 where it has nothing of its own, rails included.
        assertFalse(display.command.isVisible(MonitorDisplaySection.STATUS_BAR))
        assertFalse(display.command.isVisible(MonitorDisplaySection.RAIL_RECORD))

        // Once seeded the shared layout is the operator's; the retired keys never apply again.
        display.live = display.live.toggling(MonitorDisplaySection.STATUS_BAR)
        assertTrue(OperatorSettings(store).displayPreferences.live.isVisible(MonitorDisplaySection.STATUS_BAR))
    }

    /** Product ruling 2026-10-16: Z's remote shutter moves onto the shared key; the choice carries over once. */
    @Test
    fun `a stored remote shutter choice moves to the shared key once and the retired key is removed`() {
        store.edit().putBoolean("controls.mediaRemoteShutter.v1", false).commit()
        val settings = OperatorSettings(store)
        assertFalse(settings.mediaRemoteShutterEnabled.value)
        assertFalse(settings.operatorPreferences.remoteShutter)
        assertEquals(false, store.all["OpenZCine.RemoteShutter"])
        assertFalse(store.contains("controls.mediaRemoteShutter.v1"))
        val snapshot = store.all.toMap()
        assertFalse(OperatorSettings(store).mediaRemoteShutterEnabled.value)
        assertEquals(snapshot, store.all.toMap(), "a second launch changes nothing")
    }

    @Test
    fun `without a stored remote shutter choice the shared default applies and nothing is written`() {
        val settings = OperatorSettings(store)
        assertTrue(settings.mediaRemoteShutterEnabled.value)
        assertTrue(store.all.isEmpty())
        settings.mediaRemoteShutterEnabled.toggle()
        assertEquals(false, store.all["OpenZCine.RemoteShutter"])
        assertFalse(store.contains("controls.mediaRemoteShutter.v1"))
        assertFalse(OperatorSettings(store).mediaRemoteShutterEnabled.value)
    }

    @Test
    fun `an already migrated choice wins over a stale retired key, which is removed`() {
        store.edit().putBoolean("OpenZCine.RemoteShutter", false)
            .putBoolean("controls.mediaRemoteShutter.v1", true).commit()
        assertFalse(OperatorSettings(store).mediaRemoteShutterEnabled.value)
        assertEquals(false, store.all["OpenZCine.RemoteShutter"])
        assertFalse(store.contains("controls.mediaRemoteShutter.v1"))
        assertFalse(OperatorSettings(store).mediaRemoteShutterEnabled.value)
    }

    @Test
    fun `an unreadable retired remote shutter value is left alone and the default applies`() {
        store.edit().putString("controls.mediaRemoteShutter.v1", "future").commit()
        assertTrue(OperatorSettings(store).mediaRemoteShutterEnabled.value)
        assertEquals("future", store.getString("controls.mediaRemoteShutter.v1", null))
        assertFalse(store.contains("OpenZCine.RemoteShutter"))
    }

    @Test
    fun `an unreadable retired shutter survives a shared choice and unrelated edits`() {
        store.edit().putString("controls.mediaRemoteShutter.v1", "future")
            .putBoolean("OpenZCine.RemoteShutter", false).commit()
        val settings = OperatorSettings(store)
        assertFalse(settings.mediaRemoteShutterEnabled.value)
        assertEquals("future", store.getString("controls.mediaRemoteShutter.v1", null))
        settings.keepScreenAwake.toggle()
        assertFalse(settings.keepScreenAwake.value)
        assertEquals("future", store.getString("controls.mediaRemoteShutter.v1", null))
        assertFalse(OperatorSettings(store).mediaRemoteShutterEnabled.value)
        assertEquals(false, store.all["OpenZCine.RemoteShutter"])
    }
}

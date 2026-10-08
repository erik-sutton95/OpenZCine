package com.opencapture.openzcine.media

import com.opencapture.monitorui.MonitorAssistTool
import com.opencapture.monitorui.MonitorScopeStoredCenter
import com.opencapture.opencine.appkit.MonitorToolUsagePreferences
import com.opencapture.openzcine.StoredPanelCenter
import com.opencapture.openzcine.TestSharedPreferences
import com.opencapture.openzcine.restoreNikonAssists
import kotlin.test.*

class NikonPlaybackPlacementAdoptionTest {
    @Test fun `playback panels borrow their exact deployed files without live placement fallback`() {
        val live = TestSharedPreferences(); val reference = TestSharedPreferences(); val audio = TestSharedPreferences()
        val state = restoreNikonAssists(live, TestSharedPreferences(), TestSharedPreferences()).shared
        state.storeCenter(MonitorAssistTool.FALSE, MonitorScopeStoredCenter(0.1, 0.2), true)
        state.storeCenter(MonitorAssistTool.AUDIO, MonitorScopeStoredCenter(0.2, 0.3), true)
        val port = playbackPanelPlacement(StoredPanelCenter(reference, "fcref"), StoredPanelCenter(audio, "audio"), state)
        assertNull(port.read(MonitorAssistTool.FALSE, true)); assertNull(port.read(MonitorAssistTool.AUDIO, true))
        reference.edit().putFloat("fcref.centerX", 0.75f).putFloat("fcref.centerY", 0.25f).apply()
        audio.edit().putFloat("audio.centerX", 0.5f).putFloat("audio.centerY", 0.75f).apply()
        assertEquals(MonitorScopeStoredCenter(0.75, 0.25), port.read(MonitorAssistTool.FALSE, false))
        assertEquals(MonitorScopeStoredCenter(0.5, 0.75), port.read(MonitorAssistTool.AUDIO, true))
        port.write(MonitorAssistTool.FALSE, MonitorScopeStoredCenter(0.25, 0.5), true)
        port.write(MonitorAssistTool.AUDIO, MonitorScopeStoredCenter(0.75, 0.5), false)
        assertEquals(0.25f, reference.getFloat("fcref.centerX", -1f)); assertEquals(0.75f, audio.getFloat("audio.centerX", -1f))
        assertFalse(reference.contains("audio.centerX")); assertFalse(audio.contains("fcref.centerX"))
        assertEquals(MonitorScopeStoredCenter(0.1, 0.2), state.centerFor(MonitorAssistTool.FALSE, true))
        assertEquals(0.72f, port.falseColorDefaultHorizontalFraction)
        assertEquals(70f, port.portraitAudioTrailingGapDp); assertEquals(10f, port.landscapeAudioTrailingGapDp)
        assertTrue(port.usesAnalysisViewport)
        assertEquals(10f, port.referenceBelowFeedGapDp); assertEquals(10f, port.audioBottomGapDp)
        assertEquals(0f, port.movementInsetDp)
    }
    @Test fun `shared assist usage persists the deployed Nikon JSON key and reenters unchanged`() {
        val store = TestSharedPreferences()
        store.edit().putString("assistToolUsage.v1", "{\"scores\":{\"FALSE\":3},\"counts\":{\"FALSE\":3},\"lastUsed\":{\"FALSE\":100},\"clock\":100}").apply()
        val borrowed = MonitorToolUsagePreferences(store, "assistToolUsage.v1")
        assertEquals(3, borrowed.value.counts["FALSE"])
        borrowed.value = borrowed.value.recording("AUDIO", 101.0)
        val reentered = MonitorToolUsagePreferences(store, "assistToolUsage.v1").value
        assertEquals(3, reentered.counts["FALSE"]); assertEquals(1, reentered.counts["AUDIO"])
        assertEquals(setOf("assistToolUsage.v1"), store.getAll().keys)
    }
}

package com.opencapture.openzcine

import com.opencapture.monitorui.MonitorFieldLayout
import com.opencapture.monitorui.MonitorRect
import com.opencapture.monitorui.MonitorAssistTool
import com.opencapture.monitorui.MonitorScopeStoredCenter
import com.opencapture.opencine.appkit.MonitorAssistState
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** Focused OPE-68 geometry, normalization, migration, and lifecycle contracts. */
class MonitorAnalysisPanelPlacementTest {
    @Test
    fun `landscape false colour default preserves its legacy anchor then clamps once`() {
        val zones = landscapeZones()
        val layout = MonitorAnalysisPanelLayout(LANDSCAPE_VIEWPORT, MonitorRect(64f, 62f, 704f, 251f))

        assertEquals(
            MonitorRect(64f, 259f, 264f, 52f),
            controlSafeFalseColorReferenceDefaultFrame(
                feed = zones.picture,
                layout = layout,
            ),
        )
    }

    @Test
    fun `legacy stores read finite pairs and reconcile out of range values`() {
        val current = TestSharedPreferences()
        val legacyScopes = TestSharedPreferences()
        val legacyFalseColor = TestSharedPreferences()
        legacyScopes.edit()
            .putFloat("wave.centerX", 1.2f)
            .putFloat("wave.centerY", -0.2f)
            .apply()
        legacyFalseColor.edit()
            .putFloat("fcref.centerX", 0.25f)
            .putFloat("fcref.centerY", 0.75f)
            .apply()
        val store =
            MonitorAnalysisPanelPlacementStore(
                current,
                legacyScopes,
                legacyFalseColor,
            )

        assertEquals(
            NormalizedPanelCenter(1f, 0f),
            store.storedCenter(MonitorAnalysisPanelID.WAVEFORM),
        )
        assertEquals(
            NormalizedPanelCenter(0.25f, 0.75f),
            store.storedCenter(MonitorAnalysisPanelID.FALSE_COLOR_REFERENCE),
        )

        val assist = MonitorAssistState()
        store.movePanelCentres(into = assist)

        assertEquals(MonitorScopeStoredCenter(1.0, 0.0), assist.centerFor(MonitorAssistTool.WAVE, portrait = false))
        assertEquals(MonitorScopeStoredCenter(0.25, 0.75), assist.centerFor(MonitorAssistTool.FALSE, portrait = true))
        assertFalse(legacyScopes.contains("wave.centerX"))
        assertFalse(legacyFalseColor.contains("fcref.centerY"))
    }

    @Test
    fun `partial or malformed current pair is dropped and removed`() {
        val current = TestSharedPreferences()
        current.edit()
            .putInt("schema", 2)
            .putFloat("wave.centerX.v2", 0.4f)
            .apply()
        current.edit()
            .putString("fcref.centerX.v2", "invalid")
            .putFloat("fcref.centerY.v2", 0.5f)
            .apply()
        val store = MonitorAnalysisPanelPlacementStore(current)

        assertNull(store.storedCenter(MonitorAnalysisPanelID.WAVEFORM))
        assertNull(store.storedCenter(MonitorAnalysisPanelID.FALSE_COLOR_REFERENCE))
        assertFalse(current.contains("wave.centerX.v2"))
        assertFalse(current.contains("fcref.centerY.v2"))
    }

    @Test
    fun `absent schema ignores orphan v2 data without passive mutation`() {
        val current = TestSharedPreferences()
        current.edit()
            .putFloat("wave.centerX.v2", 0.8f)
            .putFloat("wave.centerY.v2", 0.7f)
            .apply()
        val store = MonitorAnalysisPanelPlacementStore(current)

        assertNull(store.storedCenter(MonitorAnalysisPanelID.WAVEFORM))
        assertFalse(current.contains("schema"))
        assertEquals(0.8f, current.getFloat("wave.centerX.v2", 0f))
        assertEquals(0.7f, current.getFloat("wave.centerY.v2", 0f))
    }

    @Test
    fun `older schema ignores stale v2 and reads only the explicit legacy pair`() {
        val current = TestSharedPreferences()
        current.edit()
            .putInt("schema", 1)
            .putFloat("wave.centerX.v2", 0.9f)
            .putFloat("wave.centerY.v2", 0.9f)
            .apply()
        val legacy = TestSharedPreferences()
        legacy.edit()
            .putFloat("wave.centerX", 0.25f)
            .putFloat("wave.centerY", 0.5f)
            .apply()
        val store =
            MonitorAnalysisPanelPlacementStore(
                current,
                legacy,
                TestSharedPreferences(),
            )

        assertEquals(
            NormalizedPanelCenter(0.25f, 0.5f),
            store.storedCenter(MonitorAnalysisPanelID.WAVEFORM),
        )
    }

    @Test
    fun `corrupt schema fails closed without consuming or deleting any stored pair`() {
        val current = TestSharedPreferences()
        current.edit()
            .putString("schema", "invalid")
            .putFloat("wave.centerX.v2", 0.8f)
            .putFloat("wave.centerY.v2", 0.7f)
            .apply()
        val legacy = TestSharedPreferences()
        legacy.edit()
            .putFloat("wave.centerX", 0.2f)
            .putFloat("wave.centerY", 0.3f)
            .apply()
        val store =
            MonitorAnalysisPanelPlacementStore(
                current,
                legacy,
                TestSharedPreferences(),
            )

        assertNull(store.storedCenter(MonitorAnalysisPanelID.WAVEFORM))
        store.movePanelCentres(into = MonitorAssistState())
        assertEquals("invalid", current.getString("schema", null))
        assertEquals(0.8f, current.getFloat("wave.centerX.v2", 0f))
        assertTrue(legacy.contains("wave.centerX"))
    }

    @Test
    fun `future schema fails closed without downgrade`() {
        val current = TestSharedPreferences()
        current.edit()
            .putInt("schema", 3)
            .putFloat("wave.centerX.v2", 0.8f)
            .putFloat("wave.centerY.v2", 0.7f)
            .putFloat("future-only", 42f)
            .apply()
        val store = MonitorAnalysisPanelPlacementStore(current)

        assertNull(store.storedCenter(MonitorAnalysisPanelID.WAVEFORM))
        store.movePanelCentres(into = MonitorAssistState())
        assertEquals(3, current.getInt("schema", 0))
        assertEquals(42f, current.getFloat("future-only", 0f))
        assertEquals(0.8f, current.getFloat("wave.centerX.v2", 0f))
    }

    @Test
    fun `recenter clears an unmigrated legacy centre`() {
        val legacyScopes = TestSharedPreferences()
        legacyScopes.edit()
            .putFloat("histo.centerX", 0.8f)
            .putFloat("histo.centerY", 0.7f)
            .apply()
        val store =
            MonitorAnalysisPanelPlacementStore(
                TestSharedPreferences(),
                legacyScopes,
                TestSharedPreferences(),
            )

        store.recenter(MonitorAnalysisPanelID.HISTOGRAM)

        assertNull(store.storedCenter(MonitorAnalysisPanelID.HISTOGRAM))
        assertFalse(legacyScopes.contains("histo.centerX"))
        assertFalse(legacyScopes.contains("histo.centerY"))
    }

    @Test
    fun `recenter affects only the requested panel`() {
        val current = TestSharedPreferences()
        current.edit()
            .putInt("schema", 2)
            .putFloat("wave.centerX.v2", 0.6f)
            .putFloat("wave.centerY.v2", 0.6f)
            .putFloat("histo.centerX.v2", 0.45f)
            .putFloat("histo.centerY.v2", 0.5f)
            .apply()
        val store = MonitorAnalysisPanelPlacementStore(current)

        store.recenter(MonitorAnalysisPanelID.WAVEFORM)

        assertNull(store.storedCenter(MonitorAnalysisPanelID.WAVEFORM))
        assertEquals(NormalizedPanelCenter(0.45f, 0.5f), store.storedCenter(MonitorAnalysisPanelID.HISTOGRAM))
    }

    @Test
    fun `panel centres move once into the shared assist state`() {
        val current = TestSharedPreferences()
        val legacyScopes = TestSharedPreferences()
        current.edit()
            .putInt("schema", 2)
            .putFloat("wave.centerX.v2", 0.25f)
            .putFloat("wave.centerY.v2", 0.75f)
            .putFloat("histo.centerX.v2", 0.875f)
            .putFloat("histo.centerY.v2", 0.125f)
            .putFloat("fcref.centerX.v2", 0.5f)
            .putFloat("fcref.centerY.v2", 0.25f)
            .apply()
        legacyScopes.edit()
            .putFloat("lights.centerX", 0.125f)
            .putFloat("lights.centerY", 0.625f)
            .apply()
        val store = MonitorAnalysisPanelPlacementStore(current, legacyScopes, TestSharedPreferences())
        val assist =
            MonitorAssistState().apply {
                storeCenter(MonitorAssistTool.HISTO, MonitorScopeStoredCenter(0.5, 0.5))
            }

        store.movePanelCentres(into = assist)

        assertEquals(MonitorScopeStoredCenter(0.25, 0.75), assist.centerFor(MonitorAssistTool.WAVE, portrait = false))
        assertNull(assist.centerFor(MonitorAssistTool.WAVE, portrait = true))
        assertEquals(MonitorScopeStoredCenter(0.125, 0.625), assist.centerFor(MonitorAssistTool.LIGHTS, portrait = false))
        // A centre the shared state already holds wins.
        assertEquals(MonitorScopeStoredCenter(0.5, 0.5), assist.centerFor(MonitorAssistTool.HISTO, portrait = false))
        // The false-colour key had one centre for landscape and portrait fill.
        assertEquals(MonitorScopeStoredCenter(0.5, 0.25), assist.centerFor(MonitorAssistTool.FALSE, portrait = false))
        assertEquals(MonitorScopeStoredCenter(0.5, 0.25), assist.centerFor(MonitorAssistTool.FALSE, portrait = true))
        MonitorAnalysisPanelID.entries.forEach { assertNull(store.storedCenter(it)) }
        assertFalse(legacyScopes.contains("lights.centerX"))

        // A later launch finds nothing left to move.
        assist.storeCenter(MonitorAssistTool.WAVE, MonitorScopeStoredCenter(0.375, 0.375))
        assist.storeCenter(MonitorAssistTool.FALSE, MonitorScopeStoredCenter(0.75, 0.75))
        store.movePanelCentres(into = assist)
        assertEquals(MonitorScopeStoredCenter(0.375, 0.375), assist.centerFor(MonitorAssistTool.WAVE, portrait = false))
        assertEquals(MonitorScopeStoredCenter(0.75, 0.75), assist.centerFor(MonitorAssistTool.FALSE, portrait = false))
    }

    @Test
    fun `the live audio meter centre moves once into both shared slots`() {
        val preferences = TestSharedPreferences()
        preferences.edit().putFloat("audio.centerX", 0.9f).putFloat("audio.centerY", 0.8f).apply()
        val stored = StoredPanelCenter(preferences, "audio")
        val assist = MonitorAssistState()

        stored.moveAudioCentre(into = assist)

        val expected = MonitorScopeStoredCenter(0.9f.toDouble(), 0.8f.toDouble())
        assertEquals(expected, assist.audioCenterFor(portrait = false))
        assertEquals(expected, assist.audioCenterFor(portrait = true))
        assertNull(stored.load())
        assertFalse(preferences.contains("audio.centerX"))
    }

    @Test
    fun `a stored panel centre keeps its file keys and drops a partial or non finite pair`() {
        val preferences = TestSharedPreferences()
        val stored = StoredPanelCenter(preferences, "fcref")
        assertNull(stored.load())

        stored.save(MonitorScopeStoredCenter(0.25, 1.5))
        assertEquals(0.25f, preferences.getFloat("fcref.centerX", Float.NaN))
        assertEquals(1f, preferences.getFloat("fcref.centerY", Float.NaN))
        assertEquals(MonitorScopeStoredCenter(0.25, 1.0), stored.load())

        preferences.edit().remove("fcref.centerY").apply()
        assertNull(stored.load())
        preferences.edit().putFloat("fcref.centerY", Float.NaN).apply()
        assertNull(stored.load())
    }

    private fun landscapeZones(): MonitorFieldLayout =
        testFieldLayout(
            picture = MonitorRect(59f, 0f, 734f, 393f),
            status = MonitorRect(100f, 8f, 500f, 46f),
            values = MonitorRect(430f, 321f, 363f, 58f),
            assists = MonitorRect(59f, 321f, 350f, 58f),
            system = MonitorRect(16f, 14f, 816f, 365f),
            lock = MonitorRect(16f, 14f, 40f, 40f),
            display = MonitorRect(780f, 300f, 44f, 34f),
            record = MonitorRect(776f, 160f, 72f, 72f),
            media = MonitorRect(782f, 100f, 40f, 40f),
            settings = MonitorRect(782f, 50f, 40f, 40f),
            gauges = MonitorRect(16f, 80f, 38f, 233f),
        )

    private companion object {
        val LANDSCAPE_VIEWPORT = MonitorRect(0f, 0f, 848f, 393f)
    }
}

/** A field layout with the slots a geometry test names; every other slot is empty. */
internal fun testFieldLayout(
    picture: MonitorRect,
    status: MonitorRect,
    values: MonitorRect,
    assists: MonitorRect,
    system: MonitorRect,
    lock: MonitorRect,
    display: MonitorRect,
    record: MonitorRect,
    media: MonitorRect,
    settings: MonitorRect,
    gauges: MonitorRect = MonitorRect(0f, 0f, 0f, 0f),
): MonitorFieldLayout {
    val empty = MonitorRect(0f, 0f, 0f, 0f)
    return MonitorFieldLayout(
        viewport = empty, picture = picture, status = status, values = values, system = system,
        lock = lock, gauges = gauges, settings = settings, media = media, record = record,
        display = display, assists = assists, stick = empty, zoom = empty, gimbal = empty,
        headTrack = empty, aspectToggle = empty, focusReset = empty, portrait = false,
        tablet = false, fillsPicture = false, controlsFloor = 0f,
    )
}

package com.opencapture.openzcine

import com.opencapture.monitorui.MonitorFieldLayout
import com.opencapture.monitorui.MonitorRect
import com.opencapture.monitorui.MonitorAssistTool
import com.opencapture.monitorui.MonitorScopeStoredCenter
import com.opencapture.opencine.appkit.MonitorAssistState
import com.opencapture.openzcine.settings.SideRailPlan
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** Focused OPE-68 geometry, normalization, migration, and lifecycle contracts. */
class MonitorAnalysisPanelPlacementTest {
    @Test
    fun `landscape safe frame comes from mapped chrome and clears every control band`() {
        val zones = landscapeZones()
        val layout =
            requireNotNull(
                monitorAnalysisPanelLayout(
                    layout = zones,
                    physicalViewport = LANDSCAPE_VIEWPORT,
                    isPortrait = false,
                    isPortraitFill = false,
                    statusBarVisible = true,
                    chromeMounts = LANDSCAPE_LIVE_CHROME,
                ),
            )

        assertEquals(LANDSCAPE_VIEWPORT, layout.viewport)
        // Side rails only — full height, left of record/media/settings, right of lock/battery.
        assertEquals(MonitorRect(64f, 0f, 704f, 393f), layout.safeBounds)
        assertTrue(layout.safeBounds.x > zones.lock.x + zones.lock.width)
        assertTrue(layout.safeBounds.x > zones.gauges.x + zones.gauges.width)
        assertTrue(layout.safeBounds.x + layout.safeBounds.width < zones.record.x)
        // Top status / bottom strips are intentionally *not* carved (iOS free-roam parity).
        assertEquals(LANDSCAPE_VIEWPORT.y, layout.safeBounds.y)
        assertEquals(LANDSCAPE_VIEWPORT.height, layout.safeBounds.height)
    }

    @Test
    fun `hidden landscape rails release only space without mounted recovery controls`() {
        val zones = landscapeZones()
        val hiddenChrome =
            monitorAnalysisChromeMounts(
                isPortrait = false,
                isPortraitFill = false,
                isClean = false,
                isCommand = false,
                assistToolbarVisible = true,
                cameraValuesVisible = true,
                landscapeRail = RAIL_SETTINGS_ONLY,
            )
        val hiddenRecordingChrome =
            hiddenChrome.copy(landscapeRail = RAIL_SETTINGS_ONLY.copy(record = true))
        val hiddenLayout =
            requireNotNull(
                monitorAnalysisPanelLayout(
                    layout = zones,
                    physicalViewport = LANDSCAPE_VIEWPORT,
                    isPortrait = false,
                    isPortraitFill = false,
                    statusBarVisible = true,
                    chromeMounts = hiddenChrome,
                ),
            )
        val hiddenRecordingLayout =
            requireNotNull(
                monitorAnalysisPanelLayout(
                    layout = zones,
                    physicalViewport = LANDSCAPE_VIEWPORT,
                    isPortrait = false,
                    isPortraitFill = false,
                    statusBarVisible = true,
                    chromeMounts = hiddenRecordingChrome,
                ),
            )

        assertEquals(MonitorRect(0f, 0f, 774f, 393f), hiddenLayout.safeBounds)
        assertEquals(MonitorRect(0f, 0f, 768f, 393f), hiddenRecordingLayout.safeBounds)
        assertEquals(zones.settings.x - 8f, hiddenLayout.safeBounds.x + hiddenLayout.safeBounds.width)
        assertEquals(
            zones.record.x - 8f,
            hiddenRecordingLayout.safeBounds.x + hiddenRecordingLayout.safeBounds.width,
        )
    }

    @Test
    fun `portrait fill clears top capture system and the assist palette column`() {
        val zones = portraitZones()
        val layout =
            requireNotNull(
                monitorAnalysisPanelLayout(
                    layout = zones,
                    physicalViewport = PORTRAIT_VIEWPORT,
                    isPortrait = true,
                    isPortraitFill = true,
                    statusBarVisible = true,
                    chromeMounts = PORTRAIT_FILL_CHROME,
                ),
            )
        val palette = zones.assists

        assertEquals(zones.picture, layout.viewport)
        // Palette column 8 + 56 wide, then the 8 dp control clearance.
        assertEquals(MonitorRect(72f, 60f, 328f, 542f), layout.safeBounds)
        assertTrue(layout.safeBounds.x > palette.x + palette.width)
        assertTrue(layout.safeBounds.y + layout.safeBounds.height < zones.values.y)
        assertTrue(layout.safeBounds.y + layout.safeBounds.height < zones.system.y)
    }

    @Test
    fun `chrome mount policy matches live clean and command rendering conditions`() {
        val livePortraitFill =
            monitorAnalysisChromeMounts(
                isPortrait = true,
                isPortraitFill = true,
                isClean = false,
                isCommand = false,
                assistToolbarVisible = true,
                cameraValuesVisible = true,
            )
        val cleanPortraitFill =
            monitorAnalysisChromeMounts(
                isPortrait = true,
                isPortraitFill = true,
                isClean = true,
                isCommand = false,
                assistToolbarVisible = true,
                cameraValuesVisible = true,
            )
        val commandPortraitFill =
            monitorAnalysisChromeMounts(
                isPortrait = true,
                isPortraitFill = true,
                isClean = false,
                isCommand = true,
                assistToolbarVisible = true,
                cameraValuesVisible = true,
            )
        val cleanLandscape =
            monitorAnalysisChromeMounts(
                isPortrait = false,
                isPortraitFill = false,
                isClean = true,
                isCommand = false,
                assistToolbarVisible = true,
                cameraValuesVisible = true,
            )

        assertEquals(MonitorAnalysisChromeMounts(assistStrip = true, captureStrip = true), livePortraitFill)
        assertEquals(livePortraitFill, cleanPortraitFill)
        assertEquals(MonitorAnalysisChromeMounts(assistStrip = false, captureStrip = false), commandPortraitFill)
        assertEquals(MonitorAnalysisChromeMounts(assistStrip = false, captureStrip = false), cleanLandscape)
        assertEquals(
            MonitorRect(72f, 60f, 328f, 542f),
            requireNotNull(
                monitorAnalysisPanelLayout(
                    layout = portraitZones(),
                    physicalViewport = PORTRAIT_VIEWPORT,
                    isPortrait = true,
                    isPortraitFill = true,
                    statusBarVisible = true,
                    chromeMounts = cleanPortraitFill,
                ),
            ).safeBounds,
        )
    }

    @Test
    fun `portrait fit has no movable analysis canvas`() {
        assertNull(
            monitorAnalysisPanelLayout(
                layout = portraitZones(),
                physicalViewport = PORTRAIT_VIEWPORT,
                isPortrait = true,
                isPortraitFill = false,
                statusBarVisible = true,
                chromeMounts = PORTRAIT_FIT_CHROME,
            ),
        )
    }

    @Test
    fun `landscape false colour default preserves its legacy anchor then clamps once`() {
        val zones = landscapeZones()
        val layout =
            requireNotNull(
                monitorAnalysisPanelLayout(
                    layout = zones,
                    physicalViewport = LANDSCAPE_VIEWPORT,
                    isPortrait = false,
                    isPortraitFill = false,
                    statusBarVisible = true,
                    chromeMounts = LANDSCAPE_LIVE_CHROME,
                ),
            )

        assertEquals(
            MonitorRect(64f, 259f, 264f, 52f),
            controlSafeFalseColorReferenceDefaultFrame(
                feed = zones.picture,
                layout = layout.copy(safeBounds = MonitorRect(64f, 62f, 704f, 251f)),
            ),
        )
    }

    @Test
    fun `portrait fill false colour default preserves its legacy anchor then clamps once`() {
        val zones = portraitZones()
        val panelLayout =
            requireNotNull(
                monitorAnalysisPanelLayout(
                    layout = zones,
                    physicalViewport = PORTRAIT_VIEWPORT,
                    isPortrait = true,
                    isPortraitFill = true,
                    statusBarVisible = true,
                    chromeMounts = PORTRAIT_FILL_CHROME,
                ),
            )

        assertEquals(
            MonitorRect(136f, 540f, 264f, 52f),
            controlSafeFalseColorReferenceDefaultFrame(
                feed = zones.picture,
                layout = panelLayout,
                horizontalFraction = 1f,
            ),
        )
    }

    @Test
    fun `normalized centre survives resolution and orientation changes`() {
        val preferences = TestSharedPreferences()
        val store = MonitorAnalysisPanelPlacementStore(preferences)
        val landscape =
            MonitorAnalysisPanelLayout(
                viewport = MonitorRect(0f, 0f, 1_000f, 500f),
                safeBounds = MonitorRect(0f, 0f, 1_000f, 500f),
            )
        val portrait =
            MonitorAnalysisPanelLayout(
                viewport = MonitorRect(0f, 0f, 400f, 800f),
                safeBounds = MonitorRect(80f, 60f, 320f, 600f),
            )
        store.save(
            MonitorAnalysisPanelID.WAVEFORM,
            MonitorRect(700f, 300f, 100f, 50f),
            landscape,
        )

        val restored =
            store.resolve(
                MonitorAnalysisPanelID.WAVEFORM,
                MonitorRect(0f, 0f, 100f, 50f),
                portrait,
            )

        assertEquals(MonitorRect(250f, 495f, 100f, 50f), restored)
        assertEquals(
            NormalizedPanelCenter(0.75f, 0.65f),
            store.storedCenter(MonitorAnalysisPanelID.WAVEFORM),
        )
    }

    @Test
    fun `layout clamp is temporary and expanded chrome restores the stored intent`() {
        val preferences = TestSharedPreferences()
        val store = MonitorAnalysisPanelPlacementStore(preferences)
        val viewport = MonitorRect(0f, 0f, 800f, 400f)
        val wide = MonitorAnalysisPanelLayout(viewport, viewport)
        val narrow = MonitorAnalysisPanelLayout(viewport, MonitorRect(100f, 80f, 400f, 180f))
        val size = MonitorRect(0f, 0f, 180f, 100f)
        store.save(
            MonitorAnalysisPanelID.HISTOGRAM,
            MonitorRect(620f, 280f, size.width, size.height),
            wide,
        )

        val temporarilyClamped = store.resolve(MonitorAnalysisPanelID.HISTOGRAM, size, narrow)
        val restored = store.resolve(MonitorAnalysisPanelID.HISTOGRAM, size, wide)

        assertEquals(MonitorRect(320f, 160f, 180f, 100f), temporarilyClamped)
        assertEquals(MonitorRect(620f, 280f, 180f, 100f), restored)
    }

    @Test
    fun `legacy stores migrate finite pairs and reconcile out of range values`() {
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
        assertFalse(legacyScopes.contains("wave.centerX"))
        assertFalse(legacyFalseColor.contains("fcref.centerY"))
        assertEquals(2, current.getInt("schema", 0))
    }

    @Test
    fun `partial or malformed current pair deterministically falls back and is removed`() {
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
        val layout =
            MonitorAnalysisPanelLayout(
                viewport = MonitorRect(0f, 0f, 400f, 300f),
                safeBounds = MonitorRect(40f, 20f, 320f, 240f),
            )
        val default = MonitorRect(60f, 40f, 100f, 60f)

        assertEquals(default, store.resolve(MonitorAnalysisPanelID.WAVEFORM, default, layout))
        assertEquals(
            default,
            store.resolve(MonitorAnalysisPanelID.FALSE_COLOR_REFERENCE, default, layout),
        )
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
        val layout = testLayout()
        val default = MonitorRect(40f, 30f, 100f, 60f)

        assertEquals(default, store.resolve(MonitorAnalysisPanelID.WAVEFORM, default, layout))
        assertFalse(current.contains("schema"))
        assertEquals(0.8f, current.getFloat("wave.centerX.v2", 0f))
        assertEquals(0.7f, current.getFloat("wave.centerY.v2", 0f))
    }

    @Test
    fun `older schema ignores stale v2 and migrates only the explicit legacy pair`() {
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
        assertEquals(2, current.getInt("schema", 0))
        assertEquals(0.25f, current.getFloat("wave.centerX.v2", 0f))
        assertFalse(legacy.contains("wave.centerX"))
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
        val default = MonitorRect(40f, 30f, 100f, 60f)

        assertEquals(default, store.resolve(MonitorAnalysisPanelID.WAVEFORM, default, testLayout()))
        assertEquals("invalid", current.getString("schema", null))
        assertEquals(0.8f, current.getFloat("wave.centerX.v2", 0f))
        assertTrue(legacy.contains("wave.centerX"))
    }

    @Test
    fun `future schema fails closed without downgrade until an operator deliberately saves`() {
        val current = TestSharedPreferences()
        current.edit()
            .putInt("schema", 3)
            .putFloat("wave.centerX.v2", 0.8f)
            .putFloat("wave.centerY.v2", 0.7f)
            .putFloat("future-only", 42f)
            .apply()
        val store = MonitorAnalysisPanelPlacementStore(current)
        val layout = testLayout()
        val default = MonitorRect(40f, 30f, 100f, 60f)

        assertEquals(default, store.resolve(MonitorAnalysisPanelID.WAVEFORM, default, layout))
        assertEquals(3, current.getInt("schema", 0))
        assertEquals(42f, current.getFloat("future-only", 0f))

        store.save(
            MonitorAnalysisPanelID.WAVEFORM,
            MonitorRect(200f, 150f, 100f, 60f),
            layout,
        )

        assertEquals(2, current.getInt("schema", 0))
        assertFalse(current.contains("future-only"))
        assertNotNull(store.storedCenter(MonitorAnalysisPanelID.WAVEFORM))
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
    fun `recenter affects only the requested panel including when another panel is hidden`() {
        val store = MonitorAnalysisPanelPlacementStore(TestSharedPreferences())
        val layout =
            MonitorAnalysisPanelLayout(
                viewport = MonitorRect(0f, 0f, 400f, 300f),
                safeBounds = MonitorRect(0f, 0f, 400f, 300f),
            )
        val default = MonitorRect(20f, 20f, 100f, 60f)
        store.save(MonitorAnalysisPanelID.WAVEFORM, MonitorRect(240f, 180f, 100f, 60f), layout)
        store.save(MonitorAnalysisPanelID.HISTOGRAM, MonitorRect(180f, 120f, 100f, 60f), layout)

        store.recenter(MonitorAnalysisPanelID.WAVEFORM)

        assertEquals(default, store.resolve(MonitorAnalysisPanelID.WAVEFORM, default, layout))
        assertNotNull(store.storedCenter(MonitorAnalysisPanelID.HISTOGRAM))
        assertEquals(
            MonitorRect(180f, 120f, 100f, 60f),
            store.resolve(MonitorAnalysisPanelID.HISTOGRAM, default, layout),
        )
    }

    @Test
    fun `scope centres move once into the shared assist state and the false colour key stays`() {
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

        store.moveScopeCentres(into = assist)

        assertEquals(MonitorScopeStoredCenter(0.25, 0.75), assist.centerFor(MonitorAssistTool.WAVE, portrait = false))
        assertNull(assist.centerFor(MonitorAssistTool.WAVE, portrait = true))
        assertEquals(MonitorScopeStoredCenter(0.125, 0.625), assist.centerFor(MonitorAssistTool.LIGHTS, portrait = false))
        // A centre the shared state already holds wins.
        assertEquals(MonitorScopeStoredCenter(0.5, 0.5), assist.centerFor(MonitorAssistTool.HISTO, portrait = false))
        ScopeKind.entries.forEach { assertNull(store.storedCenter(it.monitorAnalysisPanelID())) }
        assertFalse(legacyScopes.contains("lights.centerX"))
        assertEquals(
            NormalizedPanelCenter(0.5f, 0.25f),
            store.storedCenter(MonitorAnalysisPanelID.FALSE_COLOR_REFERENCE),
        )

        // A later launch finds nothing left to move.
        assist.storeCenter(MonitorAssistTool.WAVE, MonitorScopeStoredCenter(0.375, 0.375))
        store.moveScopeCentres(into = assist)
        assertEquals(MonitorScopeStoredCenter(0.375, 0.375), assist.centerFor(MonitorAssistTool.WAVE, portrait = false))
    }

    @Test
    fun `focus reset base frame preserves landscape and portrait feed corners`() {
        assertEquals(
            MonitorRect(69f, 271f, 40f, 40f),
            focusResetButtonBaseFrame(
                feed = landscapeZones().picture,
                isPortrait = false,
                bottomChromeInset = 72f,
            ),
        )
        assertEquals(
            MonitorRect(350f, 560f, 40f, 40f),
            focusResetButtonBaseFrame(
                feed = portraitZones().picture,
                isPortrait = true,
                bottomChromeInset = 64f,
            ),
        )
    }


    @Test
    fun `focus reset climbs overlapping panels from lowest to highest`() {
        val bounds = MonitorRect(0f, 0f, 400f, 320f)
        val base = MonitorRect(20f, 270f, 40f, 40f)
        val panels =
            listOf(
                MonitorRect(10f, 250f, 180f, 70f),
                MonitorRect(10f, 160f, 180f, 50f),
            )

        assertEquals(
            MonitorRect(20f, 110f, 40f, 40f),
            focusResetButtonClearFrame(base, panels, bounds),
        )
    }

    @Test
    fun `focus reset ignores distant panels and clamps impossible stacks to feed top`() {
        val bounds = MonitorRect(0f, 20f, 400f, 300f)
        val base = MonitorRect(20f, 270f, 40f, 40f)

        assertEquals(
            base,
            focusResetButtonClearFrame(
                base = base,
                panelFrames = listOf(MonitorRect(220f, 240f, 100f, 70f)),
                bounds = bounds,
            ),
        )
        assertEquals(
            MonitorRect(20f, 20f, 40f, 40f),
            focusResetButtonClearFrame(
                base = base,
                panelFrames = listOf(MonitorRect(0f, 20f, 160f, 300f)),
                bounds = bounds,
            ),
        )
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

    private fun portraitZones(): MonitorFieldLayout =
        testFieldLayout(
            picture = MonitorRect(0f, 52f, 400f, 622f),
            status = MonitorRect(0f, 0f, 400f, 52f),
            values = MonitorRect(0f, 610f, 400f, 64f),
            // The shared portrait palette (MonitorLayoutPolicy.portraitAssists): 48 + 8 wide at x 8.
            assists = MonitorRect(8f, 511f, 56f, 83f),
            system = MonitorRect(0f, 680f, 400f, 90f),
            lock = MonitorRect(0f, 680f, 80f, 90f),
            display = MonitorRect(80f, 680f, 80f, 90f),
            record = MonitorRect(160f, 680f, 80f, 90f),
            media = MonitorRect(240f, 680f, 80f, 90f),
            settings = MonitorRect(320f, 680f, 80f, 90f),
        )

    private fun testLayout(): MonitorAnalysisPanelLayout =
        MonitorAnalysisPanelLayout(
            viewport = MonitorRect(0f, 0f, 400f, 300f),
            safeBounds = MonitorRect(20f, 10f, 360f, 270f),
        )

    private companion object {
        val RAIL_ALL =
            SideRailPlan(
                lock = true,
                batteries = true,
                disp = true,
                record = true,
                media = true,
                settings = true,
            )
        val RAIL_SETTINGS_ONLY =
            SideRailPlan(
                lock = false,
                batteries = false,
                disp = false,
                record = false,
                media = false,
                settings = true,
            )
        val LANDSCAPE_VIEWPORT = MonitorRect(0f, 0f, 848f, 393f)
        val PORTRAIT_VIEWPORT = MonitorRect(0f, 0f, 400f, 800f)
        val LANDSCAPE_LIVE_CHROME =
            MonitorAnalysisChromeMounts(
                assistStrip = true,
                captureStrip = true,
                landscapeRail = RAIL_ALL,
            )
        val PORTRAIT_FILL_CHROME = MonitorAnalysisChromeMounts(assistStrip = true, captureStrip = true)
        val PORTRAIT_FIT_CHROME = MonitorAnalysisChromeMounts(assistStrip = true, captureStrip = false)
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

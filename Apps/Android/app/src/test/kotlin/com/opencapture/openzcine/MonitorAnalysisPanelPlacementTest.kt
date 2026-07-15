package com.opencapture.openzcine

import com.opencapture.openzcine.bridge.MonitorZones
import com.opencapture.openzcine.bridge.ZoneFrame
import com.opencapture.openzcine.bridge.ZoneStyle
import com.opencapture.openzcine.settings.ScopeAssistConfiguration
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
                    zones = zones,
                    physicalViewport = LANDSCAPE_VIEWPORT,
                    isPortrait = false,
                    isPortraitFill = false,
                    statusBarVisible = true,
                    chromeMounts = LANDSCAPE_LIVE_CHROME,
                ),
            )

        assertEquals(LANDSCAPE_VIEWPORT, layout.viewport)
        assertEquals(ZoneFrame(64f, 62f, 704f, 251f), layout.safeBounds)
        assertTrue(layout.safeBounds.x > zones.lock.x + zones.lock.width)
        assertTrue(layout.safeBounds.x > requireNotNull(zones.batteryCluster).x + zones.batteryCluster.width)
        assertTrue(layout.safeBounds.x + layout.safeBounds.width < zones.record.x)
        assertTrue(layout.safeBounds.y + layout.safeBounds.height < requireNotNull(zones.captureStrip).y)
        assertTrue(layout.safeBounds.y + layout.safeBounds.height < requireNotNull(zones.assistStrip).y)
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
                landscapeSettingsRecovery = true,
            )
        val hiddenRecordingChrome =
            hiddenChrome.copy(landscapeRecordingSafety = true)
        val hiddenLayout =
            requireNotNull(
                monitorAnalysisPanelLayout(
                    zones = zones,
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
                    zones = zones,
                    physicalViewport = LANDSCAPE_VIEWPORT,
                    isPortrait = false,
                    isPortraitFill = false,
                    statusBarVisible = true,
                    chromeMounts = hiddenRecordingChrome,
                ),
            )

        assertEquals(ZoneFrame(0f, 62f, 774f, 251f), hiddenLayout.safeBounds)
        assertEquals(ZoneFrame(0f, 62f, 768f, 251f), hiddenRecordingLayout.safeBounds)
        assertEquals(zones.settings.x - 8f, hiddenLayout.safeBounds.x + hiddenLayout.safeBounds.width)
        assertEquals(
            zones.record.x - 8f,
            hiddenRecordingLayout.safeBounds.x + hiddenRecordingLayout.safeBounds.width,
        )
    }

    @Test
    fun `portrait fill clears top capture system and worst case expanded assist rail`() {
        val zones = portraitZones()
        val layout =
            requireNotNull(
                monitorAnalysisPanelLayout(
                    zones = zones,
                    physicalViewport = PORTRAIT_VIEWPORT,
                    isPortrait = true,
                    isPortraitFill = true,
                    statusBarVisible = true,
                    chromeMounts = PORTRAIT_FILL_CHROME,
                ),
            )
        val expandedRail =
            portraitFillAssistRailFrame(
                feed = zones.feed,
                captureStrip = zones.captureStrip,
                expanded = true,
            )

        assertEquals(zones.feed, layout.viewport)
        assertEquals(ZoneFrame(78f, 60f, 322f, 542f), layout.safeBounds)
        assertTrue(layout.safeBounds.x > expandedRail.x + expandedRail.width)
        assertTrue(layout.safeBounds.y + layout.safeBounds.height < requireNotNull(zones.captureStrip).y)
        assertTrue(layout.safeBounds.y + layout.safeBounds.height < zones.systemCluster.y)
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

        assertEquals(MonitorAnalysisChromeMounts(false, true, true), livePortraitFill)
        assertEquals(livePortraitFill, cleanPortraitFill)
        assertEquals(MonitorAnalysisChromeMounts(false, false, false), commandPortraitFill)
        assertEquals(MonitorAnalysisChromeMounts(false, false, false), cleanLandscape)
        assertEquals(
            ZoneFrame(78f, 60f, 322f, 542f),
            requireNotNull(
                monitorAnalysisPanelLayout(
                    zones = portraitZones(),
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
                zones = portraitZones(),
                physicalViewport = PORTRAIT_VIEWPORT,
                isPortrait = true,
                isPortraitFill = false,
                statusBarVisible = true,
                chromeMounts = PORTRAIT_FIT_CHROME,
            ),
        )
    }

    @Test
    fun `scope body reserves the exterior resize target inside safe bounds`() {
        val layout =
            MonitorAnalysisPanelLayout(
                viewport = ZoneFrame(0f, 0f, 400f, 300f),
                safeBounds = ZoneFrame(40f, 30f, 320f, 240f),
            )

        val scopeLayout = layout.withScopeGripClearance()

        assertEquals(ZoneFrame(40f, 30f, 278f, 198f), scopeLayout.safeBounds)
    }

    @Test
    fun `landscape defaults preserve legacy anchors then clamp once to control safe bounds`() {
        val zones = landscapeZones()
        val layout =
            requireNotNull(
                monitorAnalysisPanelLayout(
                    zones = zones,
                    physicalViewport = LANDSCAPE_VIEWPORT,
                    isPortrait = false,
                    isPortraitFill = false,
                    statusBarVisible = true,
                    chromeMounts = LANDSCAPE_LIVE_CHROME,
                ),
            ).withScopeGripClearance()

        assertEquals(
            ZoneFrame(476f, 194f, 250f, 77f),
            controlSafeScopeDefaultFrame(
                ScopeKind.HISTOGRAM,
                zones.feed,
                zones.infoBar,
                layout,
            ),
        )
        assertEquals(
            ZoneFrame(64f, 259f, 264f, 52f),
            controlSafeFalseColorReferenceDefaultFrame(
                feed = zones.feed,
                layout = layout.copy(safeBounds = ZoneFrame(64f, 62f, 704f, 251f)),
            ),
        )
    }

    @Test
    fun `portrait fill defaults preserve legacy anchors then clamp once to safe bounds`() {
        val zones = portraitZones()
        val panelLayout =
            requireNotNull(
                monitorAnalysisPanelLayout(
                    zones = zones,
                    physicalViewport = PORTRAIT_VIEWPORT,
                    isPortrait = true,
                    isPortraitFill = true,
                    statusBarVisible = true,
                    chromeMounts = PORTRAIT_FILL_CHROME,
                ),
            )

        assertEquals(
            ZoneFrame(108f, 483f, 250f, 77f),
            controlSafeScopeDefaultFrame(
                ScopeKind.HISTOGRAM,
                zones.feed,
                zones.infoBar,
                panelLayout.withScopeGripClearance(),
            ),
        )
        assertEquals(
            ZoneFrame(136f, 540f, 264f, 52f),
            controlSafeFalseColorReferenceDefaultFrame(
                feed = zones.feed,
                layout = panelLayout,
                horizontalFraction = 1f,
            ),
        )
    }

    @Test
    fun `every scope family fits uniformly at min and max then restores its requested scale`() {
        val landscapeZones = landscapeZones()
        val portraitZones = portraitZones()
        val layouts =
            listOf(
                Triple(
                    landscapeZones.feed,
                    landscapeZones.infoBar,
                    requireNotNull(
                        monitorAnalysisPanelLayout(
                            zones = landscapeZones,
                            physicalViewport = LANDSCAPE_VIEWPORT,
                            isPortrait = false,
                            isPortraitFill = false,
                            statusBarVisible = true,
                            chromeMounts = LANDSCAPE_LIVE_CHROME,
                        ),
                    ).withScopeGripClearance(),
                ),
                Triple(
                    portraitZones.feed,
                    portraitZones.infoBar,
                    requireNotNull(
                        monitorAnalysisPanelLayout(
                            zones = portraitZones,
                            physicalViewport = PORTRAIT_VIEWPORT,
                            isPortrait = true,
                            isPortraitFill = true,
                            statusBarVisible = true,
                            chromeMounts = PORTRAIT_FILL_CHROME,
                        ),
                    ).withScopeGripClearance(),
                ),
            )
        val roomy =
            MonitorAnalysisPanelLayout(
                viewport = ZoneFrame(0f, 0f, 1_200f, 900f),
                safeBounds = ZoneFrame(0f, 0f, 1_200f, 900f),
            )

        layouts.forEach { (feed, infoBar, layout) ->
            ScopeKind.entries.forEach { kind ->
                listOf(
                    ScopeAssistConfiguration.MIN_SCALE,
                    ScopeAssistConfiguration.MAX_SCALE,
                ).forEach { requestedScale ->
                    val configuration = configurationAtScale(requestedScale)
                    val frame =
                        controlSafeScopeDefaultFrame(
                            kind = kind,
                            feed = feed,
                            infoBar = infoBar,
                            layout = layout,
                            configuration = configuration,
                        )
                    val (baseWidth, baseHeight) = scopePanelBaseSize(kind)
                    val expectedScale =
                        scopePresentationScale(kind, requestedScale, layout.safeBounds)

                    assertEquals(baseWidth * expectedScale, frame.width, 0.001f)
                    assertEquals(baseHeight * expectedScale, frame.height, 0.001f)
                    assertEquals(baseWidth * frame.height, baseHeight * frame.width, 0.01f)
                    assertTrue(frame.x >= layout.safeBounds.x)
                    assertTrue(frame.y >= layout.safeBounds.y)
                    assertTrue(frame.x + frame.width <= layout.safeBounds.x + layout.safeBounds.width)
                    assertTrue(frame.y + frame.height <= layout.safeBounds.y + layout.safeBounds.height)

                    val restored =
                        controlSafeScopeDefaultFrame(
                            kind = kind,
                            feed = feed,
                            infoBar = infoBar,
                            layout = roomy,
                            configuration = configuration,
                        )
                    assertEquals(baseWidth * requestedScale, restored.width, 0.001f)
                    assertEquals(baseHeight * requestedScale, restored.height, 0.001f)
                }
            }
        }
    }

    @Test
    fun `normalized centre survives resolution and orientation changes`() {
        val preferences = TestSharedPreferences()
        val store = MonitorAnalysisPanelPlacementStore(preferences)
        val landscape =
            MonitorAnalysisPanelLayout(
                viewport = ZoneFrame(0f, 0f, 1_000f, 500f),
                safeBounds = ZoneFrame(0f, 0f, 1_000f, 500f),
            )
        val portrait =
            MonitorAnalysisPanelLayout(
                viewport = ZoneFrame(0f, 0f, 400f, 800f),
                safeBounds = ZoneFrame(80f, 60f, 320f, 600f),
            )
        store.save(
            MonitorAnalysisPanelID.WAVEFORM,
            ZoneFrame(700f, 300f, 100f, 50f),
            landscape,
        )

        val restored =
            store.resolve(
                MonitorAnalysisPanelID.WAVEFORM,
                ZoneFrame(0f, 0f, 100f, 50f),
                portrait,
            )

        assertEquals(ZoneFrame(250f, 495f, 100f, 50f), restored)
        assertEquals(
            NormalizedPanelCenter(0.75f, 0.65f),
            store.storedCenter(MonitorAnalysisPanelID.WAVEFORM),
        )
    }

    @Test
    fun `layout clamp is temporary and expanded chrome restores the stored intent`() {
        val preferences = TestSharedPreferences()
        val store = MonitorAnalysisPanelPlacementStore(preferences)
        val viewport = ZoneFrame(0f, 0f, 800f, 400f)
        val wide = MonitorAnalysisPanelLayout(viewport, viewport)
        val narrow = MonitorAnalysisPanelLayout(viewport, ZoneFrame(100f, 80f, 400f, 180f))
        val size = ZoneFrame(0f, 0f, 180f, 100f)
        store.save(
            MonitorAnalysisPanelID.HISTOGRAM,
            ZoneFrame(620f, 280f, size.width, size.height),
            wide,
        )

        val temporarilyClamped = store.resolve(MonitorAnalysisPanelID.HISTOGRAM, size, narrow)
        val restored = store.resolve(MonitorAnalysisPanelID.HISTOGRAM, size, wide)

        assertEquals(ZoneFrame(320f, 160f, 180f, 100f), temporarilyClamped)
        assertEquals(ZoneFrame(620f, 280f, 180f, 100f), restored)
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
                viewport = ZoneFrame(0f, 0f, 400f, 300f),
                safeBounds = ZoneFrame(40f, 20f, 320f, 240f),
            )
        val default = ZoneFrame(60f, 40f, 100f, 60f)

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
        val default = ZoneFrame(40f, 30f, 100f, 60f)

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
        val default = ZoneFrame(40f, 30f, 100f, 60f)

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
        val default = ZoneFrame(40f, 30f, 100f, 60f)

        assertEquals(default, store.resolve(MonitorAnalysisPanelID.WAVEFORM, default, layout))
        assertEquals(3, current.getInt("schema", 0))
        assertEquals(42f, current.getFloat("future-only", 0f))

        store.save(
            MonitorAnalysisPanelID.WAVEFORM,
            ZoneFrame(200f, 150f, 100f, 60f),
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
                viewport = ZoneFrame(0f, 0f, 400f, 300f),
                safeBounds = ZoneFrame(0f, 0f, 400f, 300f),
            )
        val default = ZoneFrame(20f, 20f, 100f, 60f)
        store.save(MonitorAnalysisPanelID.WAVEFORM, ZoneFrame(240f, 180f, 100f, 60f), layout)
        store.save(MonitorAnalysisPanelID.HISTOGRAM, ZoneFrame(180f, 120f, 100f, 60f), layout)

        store.recenter(MonitorAnalysisPanelID.WAVEFORM)

        assertEquals(default, store.resolve(MonitorAnalysisPanelID.WAVEFORM, default, layout))
        assertNotNull(store.storedCenter(MonitorAnalysisPanelID.HISTOGRAM))
        assertEquals(
            ZoneFrame(180f, 120f, 100f, 60f),
            store.resolve(MonitorAnalysisPanelID.HISTOGRAM, default, layout),
        )
    }

    @Test
    fun `focus reset base frame preserves landscape and portrait feed corners`() {
        assertEquals(
            ZoneFrame(69f, 271f, 40f, 40f),
            focusResetButtonBaseFrame(
                feed = landscapeZones().feed,
                isPortrait = false,
                bottomChromeInset = 72f,
            ),
        )
        assertEquals(
            ZoneFrame(350f, 560f, 40f, 40f),
            focusResetButtonBaseFrame(
                feed = portraitZones().feed,
                isPortrait = true,
                bottomChromeInset = 64f,
            ),
        )
    }

    @Test
    fun `focus reset climbs overlapping panels from lowest to highest`() {
        val bounds = ZoneFrame(0f, 0f, 400f, 320f)
        val base = ZoneFrame(20f, 270f, 40f, 40f)
        val panels =
            listOf(
                ZoneFrame(10f, 250f, 180f, 70f),
                ZoneFrame(10f, 160f, 180f, 50f),
            )

        assertEquals(
            ZoneFrame(20f, 110f, 40f, 40f),
            focusResetButtonClearFrame(base, panels, bounds),
        )
    }

    @Test
    fun `focus reset ignores distant panels and clamps impossible stacks to feed top`() {
        val bounds = ZoneFrame(0f, 20f, 400f, 300f)
        val base = ZoneFrame(20f, 270f, 40f, 40f)

        assertEquals(
            base,
            focusResetButtonClearFrame(
                base = base,
                panelFrames = listOf(ZoneFrame(220f, 240f, 100f, 70f)),
                bounds = bounds,
            ),
        )
        assertEquals(
            ZoneFrame(20f, 20f, 40f, 40f),
            focusResetButtonClearFrame(
                base = base,
                panelFrames = listOf(ZoneFrame(0f, 20f, 160f, 300f)),
                bounds = bounds,
            ),
        )
    }

    private fun landscapeZones(): MonitorZones =
        MonitorZones(
            feed = ZoneFrame(59f, 0f, 734f, 393f),
            infoBar = ZoneFrame(100f, 8f, 500f, 46f),
            captureStrip = ZoneFrame(430f, 321f, 363f, 58f),
            assistStrip = ZoneFrame(59f, 321f, 350f, 58f),
            systemCluster = ZoneFrame(16f, 14f, 816f, 365f),
            lock = ZoneFrame(16f, 14f, 40f, 40f),
            disp = ZoneFrame(780f, 300f, 44f, 34f),
            record = ZoneFrame(776f, 160f, 72f, 72f),
            media = ZoneFrame(782f, 100f, 40f, 40f),
            settings = ZoneFrame(782f, 50f, 40f, 40f),
            batteryCluster = ZoneFrame(16f, 80f, 38f, 233f),
            batteryStyle = ZoneStyle.BATTERY_RAIL,
            batteryPhone = ZoneFrame(16f, 90f, 38f, 70f),
            batteryCamera = ZoneFrame(16f, 230f, 38f, 70f),
            scopes = null,
            controlsGrid = null,
        )

    private fun portraitZones(): MonitorZones =
        MonitorZones(
            feed = ZoneFrame(0f, 52f, 400f, 622f),
            infoBar = ZoneFrame(0f, 0f, 400f, 52f),
            captureStrip = ZoneFrame(0f, 610f, 400f, 64f),
            assistStrip = null,
            systemCluster = ZoneFrame(0f, 680f, 400f, 90f),
            lock = ZoneFrame(0f, 680f, 80f, 90f),
            disp = ZoneFrame(80f, 680f, 80f, 90f),
            record = ZoneFrame(160f, 680f, 80f, 90f),
            media = ZoneFrame(240f, 680f, 80f, 90f),
            settings = ZoneFrame(320f, 680f, 80f, 90f),
            batteryCluster = null,
            batteryStyle = null,
            batteryPhone = null,
            batteryCamera = null,
            scopes = null,
            controlsGrid = null,
        )

    private fun configurationAtScale(scale: Float): ScopeAssistConfiguration =
        ScopeAssistConfiguration(
            waveformScale = scale,
            paradeScale = scale,
            vectorscopeScale = scale,
            histogramScale = scale,
            trafficLightsScale = scale,
        )

    private fun testLayout(): MonitorAnalysisPanelLayout =
        MonitorAnalysisPanelLayout(
            viewport = ZoneFrame(0f, 0f, 400f, 300f),
            safeBounds = ZoneFrame(20f, 10f, 360f, 270f),
        )

    private companion object {
        val LANDSCAPE_VIEWPORT = ZoneFrame(0f, 0f, 848f, 393f)
        val PORTRAIT_VIEWPORT = ZoneFrame(0f, 0f, 400f, 800f)
        val LANDSCAPE_LIVE_CHROME =
            MonitorAnalysisChromeMounts(
                assistStrip = true,
                assistRail = false,
                captureStrip = true,
                landscapeFullSideRails = true,
            )
        val PORTRAIT_FILL_CHROME = MonitorAnalysisChromeMounts(false, true, true)
        val PORTRAIT_FIT_CHROME = MonitorAnalysisChromeMounts(true, false, false)
    }
}

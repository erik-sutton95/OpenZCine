package com.opencapture.openzcine

import com.opencapture.opencine.appkit.MonitorReviewOptions
import com.opencapture.opencine.appkit.MonitorReviewDuration
import com.opencapture.monitorui.MonitorAssistTool
import com.opencapture.monitorui.MonitorAssistUsage
import com.opencapture.monitorui.MonitorFalseColorSelection
import com.opencapture.monitorui.MonitorGuideFamily
import com.opencapture.monitorui.MonitorParadeMode
import com.opencapture.monitorui.MonitorScopeGuides
import com.opencapture.monitorui.MonitorVectorscopeZoom
import com.opencapture.monitorui.MonitorWaveformMode
import com.opencapture.monitorui.MonitorGuideAspect
import com.opencapture.monitorui.MonitorToolUsageState
import com.opencapture.monitorui.MonitorZebraUnit
import com.opencapture.opencine.media.MonitorCrushClipCompensation
import com.opencapture.opencine.media.MonitorDesqueezeDirection
import com.opencapture.opencine.media.MonitorDesqueezePreset
import com.opencapture.opencine.media.MonitorPeakingColor
import com.opencapture.opencine.media.MonitorPeakingSense
import com.opencapture.opencine.media.MonitorZebraPaint
import com.opencapture.opencine.appkit.MonitorAssistState
import com.opencapture.openzcine.lut.StoredLutCategory
import com.opencapture.openzcine.lut.StoredLutSelection
import com.opencapture.openzcine.settings.LocalLevelStyle
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class NikonAssistsTest {
    private val assist = TestSharedPreferences()
    private val operator = TestSharedPreferences()
    private val playback = TestSharedPreferences()

    private fun restore(
        debugEffects: FeedEffects? = null,
        debugScopes: List<ScopeKind>? = null,
        availableStoredLut: (StoredLutSelection) -> Boolean = { true },
    ) = restoreNikonAssists(assist, operator, playback, debugEffects, debugScopes, availableStoredLut)

    private val NikonAssists.live: FeedEffects get() = feedEffects(shared::isOn)

    @Test fun `review duration focus and capture info survive restoring the operator preferences`() {
        val options = MonitorReviewOptions(MonitorReviewDuration.SEVEN_SECONDS, false, false)
        restore().updateReviewOptions(options)
        assertEquals(options, restore().reviewOptions)
        val held = options.copy(duration = MonitorReviewDuration.UNTIL_DISMISSED)
        restore().updateReviewOptions(held)
        assertEquals(held, restore().reviewOptions)
        assertNull(restore().reviewOptions.duration.automaticDismissMillis)
    }

    @Test
    fun `canonical false color choices reach distinct native scales and retain read mode`() {
        assertEquals(listOf("CineStop", "Video", "IRE", "Limits"), nikonFalseColorScales.map { it.menuLabel })
        assertEquals(listOf(FeedFalseColorScale.STOPS, FeedFalseColorScale.VIDEO,
            FeedFalseColorScale.IRE, FeedFalseColorScale.LIMITS), nikonFalseColorScales.map { it.feedScale })
        val state = restore()
        assertFalse(state.shared.falseColorRec709)
        for (scale in nikonFalseColorScales) {
            state.shared.setFalseColor(scale)
            state.shared.setFalseColorRead(true)
            val restored = restore()
            assertEquals(scale, restored.shared.falseColorScale)
            assertEquals(scale.feedScale, restored.live.falseColor)
            assertTrue(restored.live.falseColorRec709)
        }
    }

    @Test
    fun `mirror axes persist and live and playback visibility remain independent`() {
        val state = restore()
        assertTrue(MonitorAssistTool.MIRROR.nikonHasOptions)
        assertTrue(state.shared.mirrorHorizontal)
        assertFalse(state.shared.mirrorVertical)
        state.shared.setMirrorAxes(horizontal = false, vertical = true)
        state.shared.toggle(MonitorAssistTool.MIRROR)
        val restored = restore()
        val framing = restored.shared.framing(restored.shared::isVisible, LocalLevelStyle.HORIZON)
        assertFalse(framing.mirrorsHorizontally)
        assertTrue(framing.flipsVertically)
        assertFalse(restored.shared.isPlaybackVisible(MonitorAssistTool.MIRROR))
    }

    @Test
    fun `lut toggles on with the default look and off again`() {
        val state = restore()
        assertFalse(state.shared.isOn(MonitorAssistTool.LUT))
        state.shared.toggle(MonitorAssistTool.LUT)
        assertEquals(FeedLutSelection.BuiltIn(FeedLut.LOG3G10_709), state.live.lut)
        state.shared.toggle(MonitorAssistTool.LUT)
        assertNull(state.live.lut)
        assertTrue(state.live.isIdentity)
    }

    @Test
    fun `stops false colour takes render precedence but preserves lut activation`() {
        val state = restore()
        state.selectLut(FeedLutSelection.BuiltIn(FeedLut.MONO))
        state.shared.toggle(MonitorAssistTool.FALSE)
        assertEquals(FeedLutSelection.BuiltIn(FeedLut.MONO), state.live.lut)
        assertEquals(FeedFalseColorScale.STOPS, state.live.falseColor)
        state.shared.toggle(MonitorAssistTool.FALSE)
        assertNull(state.live.falseColor)
        assertEquals(FeedLutSelection.BuiltIn(FeedLut.MONO), state.live.lut)
    }

    @Test
    fun `limits to stops keeps the active lut and false off resumes it`() {
        val mono = FeedLutSelection.BuiltIn(FeedLut.MONO)
        val state = restore()
        state.selectLut(mono)

        // Choosing a scale shows it (shared behavior: the reference key is on by default).
        state.shared.setFalseColor(MonitorFalseColorSelection.LIMITS)
        assertEquals(FeedFalseColorScale.LIMITS, state.live.falseColor)
        assertEquals(mono, state.live.lut)

        state.shared.setFalseColor(MonitorFalseColorSelection.SCENE_STOPS)
        assertEquals(FeedFalseColorScale.STOPS, state.live.falseColor)
        assertEquals(mono, state.live.lut)

        state.shared.toggle(MonitorAssistTool.FALSE)
        assertNull(state.live.falseColor)
        assertEquals(mono, state.live.lut)
    }

    @Test
    fun `scopes are independently active and reactivation updates recency`() {
        val state = restore().shared
        state.toggle(MonitorAssistTool.WAVE)
        state.toggle(MonitorAssistTool.VECTOR)
        assertEquals(setOf(ScopeKind.WAVEFORM, ScopeKind.VECTORSCOPE), scopesShown(state::isOn))
        state.toggle(MonitorAssistTool.WAVE)
        assertFalse(state.isOn(MonitorAssistTool.WAVE))
        state.toggle(MonitorAssistTool.WAVE)
        assertEquals(
            listOf(ScopeKind.WAVEFORM, ScopeKind.VECTORSCOPE),
            state.portraitScopes(scopesShown(state::isOn)),
        )
    }

    @Test
    fun `portrait fit shows the first two eligible scopes regardless of activation order`() {
        val state = restore().shared
        state.toggle(MonitorAssistTool.WAVE)
        state.toggle(MonitorAssistTool.VECTOR)
        state.toggle(MonitorAssistTool.HISTO)

        assertEquals(
            listOf(ScopeKind.WAVEFORM, ScopeKind.HISTOGRAM),
            state.portraitScopes(scopesShown(state::isOn)),
        )
        state.toggle(MonitorAssistTool.HISTO)
        assertEquals(
            listOf(ScopeKind.WAVEFORM, ScopeKind.VECTORSCOPE),
            state.portraitScopes(scopesShown(state::isOn)),
        )
    }

    @Test
    fun `effects state feeds the engine input`() {
        val state = restore()
        state.shared.toggle(MonitorAssistTool.PEAK)
        state.shared.toggle(MonitorAssistTool.ZEBRA)
        assertTrue(state.live.peaking)
        assertTrue(state.live.zebra)
    }

    @Test
    fun `audio meter toggle persists independently of image assists and scopes`() {
        val state = restore()
        assertFalse(state.shared.isOn(MonitorAssistTool.AUDIO))
        state.shared.toggle(MonitorAssistTool.AUDIO)
        val restored = restore()
        assertTrue(restored.shared.isOn(MonitorAssistTool.AUDIO))
        assertTrue(restored.live.isIdentity)
        assertTrue(scopesShown(restored.shared::isOn).isEmpty())
    }

    @Test
    fun `every toggle persists across a reconnect`() {
        val firstSession = restore()
        firstSession.shared.toggle(MonitorAssistTool.LUT)
        firstSession.shared.toggle(MonitorAssistTool.PEAK)
        firstSession.shared.toggle(MonitorAssistTool.HISTO)
        firstSession.shared.toggle(MonitorAssistTool.WAVE)

        val reconnected = restore()
        assertEquals(firstSession.live, reconnected.live)
        assertEquals(setOf(ScopeKind.WAVEFORM, ScopeKind.HISTOGRAM), scopesShown(reconnected.shared::isOn))
        assertEquals(
            listOf(ScopeKind.WAVEFORM, ScopeKind.HISTOGRAM),
            reconnected.shared.portraitScopes(scopesShown(reconnected.shared::isOn)),
        )
    }

    @Test
    fun `changing a stored look persists and arms the look`() {
        val state = restore()
        state.selectLut(FeedLutSelection.BuiltIn(FeedLut.NLOG_709))
        state.shared.setFalseColor(MonitorFalseColorSelection.IRE)
        state.shared.toggle(MonitorAssistTool.FALSE)

        val restored = restore()
        assertEquals(FeedLutSelection.BuiltIn(FeedLut.NLOG_709), restored.lut)
        assertEquals(FeedLutSelection.BuiltIn(FeedLut.NLOG_709), restored.live.lut)
        assertNull(restored.live.falseColor)
        restored.shared.toggle(MonitorAssistTool.FALSE)
        assertEquals(FeedFalseColorScale.IRE, restored.live.falseColor)
    }

    @Test
    fun `validated app private stored selection survives restart and missing files fall back safely`() {
        val selection =
            requireNotNull(
                StoredLutSelection.fromPersisted(StoredLutCategory.CUSTOM.name, "operator-look-a1b2c3d4e5f6.cube"),
            )
        restore().selectLut(FeedLutSelection.Stored(selection))

        val restored = restore(availableStoredLut = { it == selection })
        assertEquals(FeedLutSelection.Stored(selection), restored.lut)
        assertEquals(FeedLutSelection.Stored(selection), restored.live.lut)
        assertEquals(StoredLutCategory.CUSTOM.name, assist.getString("lut.selection.category.v1", null))
        assertEquals(selection.fileName, assist.getString("lut.selection.file.v1", null))
        assertFalse(
            assist.all.keys.any { key ->
                key.contains("uri", ignoreCase = true) || key.contains("path", ignoreCase = true)
            },
        )

        val unavailable = restore(availableStoredLut = { false })
        assertEquals(FeedLutSelection.BuiltIn(FeedLut.LOG3G10_709), unavailable.lut)
        assertEquals(FeedLutSelection.BuiltIn(FeedLut.LOG3G10_709), unavailable.live.lut)
    }

    @Test
    fun `explicit empty debug effect override stays distinct from a normal restore and is not saved`() {
        assist.edit().putString("tokens", "zebra").putString("scopes", "wave").apply()
        restore()

        val overridden = restore(debugEffects = FeedEffects.NONE)
        assertTrue(overridden.live.isIdentity)
        assertTrue(scopesShown(overridden.shared::isOn).isEmpty())

        val normal = restore()
        assertTrue(normal.live.zebra)
        assertEquals(setOf(ScopeKind.WAVEFORM), scopesShown(normal.shared::isOn))
    }

    @Test
    fun `legacy image-assist selections migrate once and become active choices`() {
        assist.edit()
            .putString("tokens", "zebra")
            .putString("lut", FeedLut.MONO.id)
            .putString("fcScale", FeedFalseColorScale.IRE.id)
            .apply()

        val state = restore()
        assertTrue(state.live.zebra)
        assertFalse(state.shared.isOn(MonitorAssistTool.LUT))
        assertEquals(FeedLutSelection.BuiltIn(FeedLut.MONO), state.lut)
        state.shared.toggle(MonitorAssistTool.LUT)
        assertEquals(FeedLutSelection.BuiltIn(FeedLut.MONO), state.live.lut)
        state.shared.toggle(MonitorAssistTool.FALSE)
        assertEquals(FeedFalseColorScale.IRE, state.live.falseColor)

        // The shared record now owns the state: legacy keys are not read again.
        assist.edit().putString("tokens", "peaking").apply()
        assertFalse(restore().live.peaking)
    }

    @Test
    fun `legacy single scope migrates without inventing portrait recency`() {
        assist.edit().putString("scope", "vector").apply()
        val state = restore().shared
        assertEquals(setOf(ScopeKind.VECTORSCOPE), scopesShown(state::isOn))
        assertEquals(listOf(ScopeKind.VECTORSCOPE), state.portraitScopes(scopesShown(state::isOn)))
    }

    @Test
    fun `legacy multi scope selection keeps all selections with canonical fit placement`() {
        assist.edit()
            .putString("scopes", "wave,parade,histo,lights")
            .putString("scopeActivationOrder", "wave,parade,histo,lights")
            .apply()

        val state = restore().shared
        assertEquals(
            setOf(ScopeKind.WAVEFORM, ScopeKind.PARADE, ScopeKind.HISTOGRAM, ScopeKind.TRAFFIC_LIGHTS),
            scopesShown(state::isOn),
        )
        assertEquals(
            listOf(ScopeKind.WAVEFORM, ScopeKind.PARADE),
            state.portraitScopes(scopesShown(state::isOn)),
        )
        state.toggle(MonitorAssistTool.WAVE)
        assertEquals(
            setOf(ScopeKind.PARADE, ScopeKind.HISTOGRAM, ScopeKind.TRAFFIC_LIGHTS),
            scopesShown(restore().shared::isOn),
        )
    }

    @Test
    fun `migrated operators keep their zebra crush framing and pins, and the toolbar order is dropped`() {
        operator.edit()
            .putString("display.assistToolbar.order.v1", "PEAK,LUT,ZEBRA")
            .putStringSet("display.assistToolbar.visible.v1", setOf("PEAK"))
            .putBoolean("display.assistToolbar.audioMeters.visibility.migrated.v1", true)
            .putStringSet("display.assistToolbar.cleanViewPinned.v1", setOf("ZEBRA", "GRID"))
            .putString("assist.zebra.unit.v1", "NATIVE")
            .putFloat("assist.zebra.highlight.ire.v1", 95f)
            .putInt("assist.scopes.crushClipCompensation.v1", 5)
            .putBoolean("assist.local.grid.visible.v2", true)
            .putBoolean("assist.local.phiGrid.v1", true)
            .putStringSet("assist.local.guides.ratios.v2", setOf("RATIO_239"))
            .putString("assist.local.desqueeze.ratio.v2", "X150")
            .putString("assist.local.desqueeze.orientation.v2", "HORIZONTAL")
            .apply()
        playback.edit().putStringSet("framingTools.v1", setOf("GUIDES")).apply()

        val state = restore().shared
        assertEquals(MonitorZebraUnit.NATIVE, state.zebraUnit)
        assertEquals(95.0, state.zebraHighlightIRE)
        assertEquals(MonitorCrushClipCompensation.HALF, state.crushClipCompensation)
        assertTrue(state.isOn(MonitorAssistTool.GRID))
        assertTrue(state.gridPhi)
        assertEquals(setOf(MonitorGuideAspect.CINEMA), state.selectedGuides)
        assertEquals(MonitorDesqueezePreset.X150, state.desqueezePreset)
        // Nikon's "horizontal" narrowed the picture; the shared direction names the squeeze axis.
        assertEquals(MonitorDesqueezeDirection.VERTICAL, state.desqueezeDirection)
        assertEquals(setOf(MonitorAssistTool.ZEBRA, MonitorAssistTool.GRID), state.pinned)
        assertTrue(state.isPlaybackVisible(MonitorAssistTool.GUIDES))
        assertFalse(state.isOn(MonitorAssistTool.GUIDES))
        assertFalse(operator.contains("display.assistToolbar.order.v1"))
        assertFalse(operator.contains("display.assistToolbar.visible.v1"))
        assertFalse(operator.contains("display.assistToolbar.audioMeters.visibility.migrated.v1"))
    }

    @Test
    fun `fresh installs take the shared assist defaults with the look off`() {
        val state = restore().shared
        assertEquals(99.0, state.zebraHighlightIRE)
        assertEquals(MonitorCrushClipCompensation.ZERO, state.crushClipCompensation)
        assertFalse(state.isOn(MonitorAssistTool.LUT))
    }

    @Test
    fun `playback visibility persists without replacing live state`() {
        val state = restore().shared
        state.togglePlayback(MonitorAssistTool.LUT)
        state.togglePlayback(MonitorAssistTool.WAVE)
        state.togglePlayback(MonitorAssistTool.AUDIO)
        state.togglePlayback(MonitorAssistTool.GUIDES)

        val restored = restore().shared
        for (tool in listOf(MonitorAssistTool.LUT, MonitorAssistTool.WAVE, MonitorAssistTool.AUDIO, MonitorAssistTool.GUIDES)) {
            assertTrue(restored.isPlaybackVisible(tool), tool.name)
            assertFalse(restored.isOn(tool), tool.name)
        }
    }

    @Test
    fun `playback framing changes visibility but retains configured values`() {
        val state = restore().shared
        state.selectedGuides = setOf(MonitorGuideAspect.CINEMA)
        state.selectDesqueezePreset(MonitorDesqueezePreset.X160)
        state.updateDesqueezeDirection(MonitorDesqueezeDirection.VERTICAL)
        state.toggle(MonitorAssistTool.GUIDES)
        state.toggle(MonitorAssistTool.CROSS)
        state.togglePlayback(MonitorAssistTool.GRID)
        state.togglePlayback(MonitorAssistTool.DESQ)

        val framing = state.framing(state::isPlaybackVisible, LocalLevelStyle.HORIZON)
        assertFalse(framing.guidesVisible)
        assertTrue(framing.gridVisible)
        assertFalse(framing.centerCrosshairEnabled)
        assertTrue(framing.desqueezeEnabled)
        assertEquals(setOf(MonitorGuideAspect.CINEMA), framing.selectedGuideRatios)
        assertEquals(1.6f, framing.desqueezeFactor)
        assertEquals(MonitorDesqueezeDirection.VERTICAL, framing.desqueezeDirection)
    }

    @Test
    fun `playback visibility uses the live look and false colour configuration`() {
        val state = restore()
        state.selectLut(FeedLutSelection.BuiltIn(FeedLut.NLOG_709))
        state.shared.setFalseColor(MonitorFalseColorSelection.IRE)
        state.shared.toggle(MonitorAssistTool.LUT)
        state.shared.togglePlayback(MonitorAssistTool.LUT)
        state.shared.togglePlayback(MonitorAssistTool.FALSE)

        val playback = state.feedEffects(state.shared::isPlaybackVisible)
        assertEquals(FeedLutSelection.BuiltIn(FeedLut.NLOG_709), playback.lut)
        assertEquals(FeedFalseColorScale.IRE, playback.falseColor)
        assertNull(state.live.lut)
    }

    @Test
    fun `playback option tools match the shared long press contract`() {
        val tools = nikonPlaybackAssistTools(imageEffects = true)
        assertFalse(MonitorAssistTool.LEVEL in tools)
        assertFalse(MonitorAssistTool.EV in tools)
        assertFalse(MonitorAssistTool.ND in tools)
        assertTrue(MonitorAssistTool.AUDIO in tools)
        assertEquals(
            tools.toSet() - setOf(MonitorAssistTool.AUDIO),
            tools.filter { it.nikonHasOptions }.toSet(),
        )
        assertTrue(MonitorAssistTool.MIRROR.nikonHasOptions)
        assertTrue(MonitorAssistTool.CROSS.nikonHasOptions)
        assertTrue(MonitorAssistTool.LEVEL.nikonHasOptions)
        assertFalse(MonitorAssistTool.EV.nikonHasOptions)
        assertEquals(
            tools.filterNot { it.isImageEffect },
            nikonPlaybackAssistTools(imageEffects = false),
        )
    }

    @Test
    fun `photography leads with instant playback then the EV meter`() {
        val photo = nikonLiveAssistChips(photography = true, imageEffects = true)
        val ranked = MonitorAssistUsage.ranked(photo, { it.id }, MonitorToolUsageState(), nikonUsageSeed)
        assertEquals(listOf("PLAY", "EV"), ranked.take(2).map { it.id })
        assertTrue(photo.all { it !is NikonAssistChip.Tool || it.tool.appliesToPhotography })

        val video = nikonLiveAssistChips(photography = false, imageEffects = true)
        assertFalse(video.any { it == NikonAssistChip.InstantReview })
        assertFalse(NikonAssistChip.Tool(MonitorAssistTool.EV) in video)
    }

    @Test
    fun `live inspector closes when its tool or lifecycle is no longer interactive`() {
        val tools = listOf(MonitorAssistTool.PEAK, MonitorAssistTool.EV)
        assertTrue(retainLiveAssistOptions(MonitorAssistTool.PEAK, tools, liveMode = true, locked = false, resumed = true))
        assertFalse(retainLiveAssistOptions(null, tools, liveMode = true, locked = false, resumed = true))
        assertFalse(retainLiveAssistOptions(MonitorAssistTool.EV, tools, liveMode = true, locked = false, resumed = true))
        assertFalse(retainLiveAssistOptions(MonitorAssistTool.AUDIO, tools + MonitorAssistTool.AUDIO, true, false, true))
        assertFalse(retainLiveAssistOptions(MonitorAssistTool.WAVE, tools, liveMode = true, locked = false, resumed = true))
        assertFalse(retainLiveAssistOptions(MonitorAssistTool.PEAK, tools, liveMode = false, locked = false, resumed = true))
        assertFalse(retainLiveAssistOptions(MonitorAssistTool.PEAK, tools, liveMode = true, locked = true, resumed = true))
        assertFalse(retainLiveAssistOptions(MonitorAssistTool.PEAK, tools, liveMode = true, locked = false, resumed = false))
    }

    /** Restores from a fresh set of stores holding only [operatorValues] (an old install). */
    private fun migrate(vararg operatorValues: Pair<String, Any>): MonitorAssistState {
        val legacy = TestSharedPreferences()
        val edit = legacy.edit()
        operatorValues.forEach { (key, value) ->
            when (value) {
                is Boolean -> edit.putBoolean(key, value)
                is Int -> edit.putInt(key, value)
                is Float -> edit.putFloat(key, value)
                is String -> edit.putString(key, value)
                is Set<*> -> edit.putStringSet(key, value.filterIsInstance<String>().toSet())
            }
        }
        edit.apply()
        return restoreNikonAssists(TestSharedPreferences(), legacy, TestSharedPreferences()).shared
    }

    /** Spelled out rather than read from the source: a test that reads it asserts nothing. */
    private val stockPins =
        setOf(MonitorAssistTool.LUT, MonitorAssistTool.PEAK, MonitorAssistTool.DESQ, MonitorAssistTool.MIRROR)

    @Test
    fun `clean view ships with the tools that make it a picture`() {
        val state = restore().shared
        assertEquals(stockPins, state.pinned)
        assertEquals(stockPins, restore().shared.pinned)
    }

    @Test
    fun `an operator who pinned nothing keeps nothing pinned`() {
        // An explicitly empty pin set means "chose nothing" and must survive a reload untouched.
        restore().shared.apply { stockPins.forEach(::togglePin) }
        assertEquals(emptySet(), restore().shared.pinned)
    }

    @Test
    fun `fresh installs start from the shared assist defaults`() {
        val state = restore().shared
        for (tool in MonitorAssistTool.entries) assertFalse(state.isOn(tool), tool.name)
        assertTrue(state.gridThirds)
        assertFalse(state.gridPhi)
        assertFalse(state.gridDiagonal)
        assertTrue(state.falseColorReference)
        assertEquals(MonitorFalseColorSelection.SCENE_STOPS, state.falseColorScale)
        assertEquals(MonitorPeakingSense.MED, state.peakingSensitivity)
        assertEquals(MonitorPeakingColor.RED, state.peakingColor)
        assertEquals(MonitorZebraUnit.IRE, state.zebraUnit)
        assertEquals(55.0, state.zebraMidtoneIRE)
        assertEquals(MonitorWaveformMode.RGB, state.waveMode)
        assertEquals(MonitorParadeMode.RGB, state.paradeMode)
        assertEquals(MonitorVectorscopeZoom.X1, state.vectorZoom)
        assertEquals(100, state.vectorBrightness)
        assertTrue(state.histoTrafficLights)
        assertEquals(setOf(MonitorGuideAspect.CINEMA), state.selectedGuides)
        assertEquals(MonitorDesqueezeDirection.HORIZONTAL, state.desqueezeDirection)
    }

    @Test
    fun `local framing selections persist apart from camera grid state`() {
        restore().shared.apply {
            updateGuideFamily(MonitorGuideFamily.SOCIAL)
            selectedGuides = emptySet()
            toggleGuide(MonitorGuideAspect.VERTICAL)
            toggleGuide(MonitorGuideAspect.SQUARE)
            updateGuideMask(true)
            toggle(MonitorAssistTool.GRID)
            setGridOption(thirds = true, phi = true, diagonal = true)
            toggle(MonitorAssistTool.CROSS)
            toggle(MonitorAssistTool.LEVEL)
            toggle(MonitorAssistTool.DESQ)
            updateDesqueezeFactor(1.65)
            updateDesqueezeDirection(MonitorDesqueezeDirection.VERTICAL)
        }

        val restored = restore().shared
        assertEquals(MonitorGuideFamily.SOCIAL, restored.guideFamily)
        assertEquals(setOf(MonitorGuideAspect.VERTICAL, MonitorGuideAspect.SQUARE), restored.selectedGuides)
        assertTrue(restored.isOn(MonitorAssistTool.GUIDES))
        assertTrue(restored.guideMask)
        assertTrue(restored.isOn(MonitorAssistTool.GRID))
        assertTrue(restored.gridThirds && restored.gridPhi && restored.gridDiagonal)
        assertTrue(restored.isOn(MonitorAssistTool.CROSS))
        assertTrue(restored.isOn(MonitorAssistTool.LEVEL))
        assertTrue(restored.isOn(MonitorAssistTool.DESQ))
        assertEquals(1.65, restored.desqueezeFactor, absoluteTolerance = 0.001)
        assertEquals(MonitorDesqueezeDirection.VERTICAL, restored.desqueezeDirection)
    }

    @Test
    fun `framing toolbar actions toggle presentation only and keep the chosen frames`() {
        val state = restore().shared
        state.toggle(MonitorAssistTool.GUIDES)
        assertTrue(state.framing(state::isOn, LocalLevelStyle.HORIZON).drawsGuides)
        assertEquals(setOf(MonitorGuideAspect.CINEMA), state.selectedGuides)

        state.toggle(MonitorAssistTool.GRID)
        assertTrue(state.framing(state::isOn, LocalLevelStyle.HORIZON).drawsGrid)

        state.toggle(MonitorAssistTool.GUIDES)
        assertFalse(state.framing(state::isOn, LocalLevelStyle.HORIZON).drawsGuides)
        assertEquals(setOf(MonitorGuideAspect.CINEMA), state.selectedGuides)
        assertTrue(restore().shared.isOn(MonitorAssistTool.GRID))
    }

    @Test
    fun `scope compensation round trips every step`() {
        val state = restore().shared
        MonitorCrushClipCompensation.entries.forEach { compensation ->
            state.setCompensation(compensation)
            assertEquals(compensation, restore().shared.crushClipCompensation)
        }
        state.setHistogram(traffic = false)
        assertFalse(restore().shared.histoTrafficLights)
    }

    @Test
    fun `exposure assists persist and clamp out of range values`() {
        restore().shared.apply {
            setFalseColor(reference = false)
            setPeaking(MonitorPeakingColor.BLUE, MonitorPeakingSense.HIGH)
            updateZebraUnit(MonitorZebraUnit.NATIVE)
            setZebraHighlight(false, 101.0, MonitorZebraPaint.CYAN)
            setZebraMidtone(false, -5.0, MonitorZebraPaint.GREEN)
            setWaveform(MonitorWaveformMode.LUMA, 250, MonitorScopeGuides(clip = false, crush = true, middle = false), 2.0)
            setParade(MonitorParadeMode.YRGB, -1, MonitorScopeGuides(clip = true, crush = false, middle = false), 0.0)
            setVectorscope(MonitorVectorscopeZoom.X4, 150, 1.2)
            setScale(MonitorAssistTool.HISTO, 0.8)
            setScale(MonitorAssistTool.LIGHTS, 1.6)
        }

        val restored = restore().shared
        assertFalse(restored.falseColorReference)
        assertEquals(MonitorPeakingSense.HIGH, restored.peakingSensitivity)
        assertEquals(MonitorPeakingColor.BLUE, restored.peakingColor)
        assertEquals(MonitorZebraUnit.NATIVE, restored.zebraUnit)
        assertFalse(restored.zebraHighlight)
        assertEquals(100.0, restored.zebraHighlightIRE)
        assertEquals(MonitorZebraPaint.CYAN, restored.zebraHighlightColor)
        assertFalse(restored.zebraMidtone)
        assertEquals(0.0, restored.zebraMidtoneIRE)
        assertEquals(MonitorZebraPaint.GREEN, restored.zebraMidtoneColor)
        assertEquals(1.6, restored.waveScale)
        assertEquals(MonitorWaveformMode.LUMA, restored.waveMode)
        assertEquals(MonitorScopeGuides(clip = false, crush = true, middle = false), restored.waveGuides)
        assertEquals(200, restored.waveBrightness)
        assertEquals(0.6, restored.paradeScale)
        assertEquals(MonitorParadeMode.YRGB, restored.paradeMode)
        assertEquals(0, restored.paradeBrightness)
        assertEquals(MonitorVectorscopeZoom.X4, restored.vectorZoom)
        assertEquals(150, restored.vectorBrightness)
        assertEquals(0.8, restored.histoScale)
        assertEquals(1.6, restored.lightsScale)
    }

    @Test
    fun `waveform and parade use the common unity brightness scale`() {
        assertEquals(0.0, waveformParadeIntensity(0))
        assertEquals(1.0, waveformParadeIntensity(100))
        assertEquals(2.0, waveformParadeIntensity(200))
        assertEquals(2.0, waveformParadeIntensity(Int.MAX_VALUE))
    }

    @Test
    fun `legacy waveform and parade brightness migrates once and repairs wrong typed values`() {
        val versionKey = "assist.scopes.waveformParade.brightnessCalibrationVersion.v1"
        val waveformKey = "assist.scopes.waveform.brightness.v1"
        val paradeKey = "assist.scopes.parade.brightness.v1"
        val vectorKey = "assist.scopes.vector.brightness.v1"

        val absent = migrate()
        assertEquals(100, absent.waveBrightness)
        assertEquals(100, absent.paradeBrightness)

        val legacy = migrate(waveformKey to 25, paradeKey to 50, vectorKey to 25)
        assertEquals(100, legacy.waveBrightness)
        assertEquals(200, legacy.paradeBrightness)
        assertEquals(25, legacy.vectorBrightness)

        val current = migrate(versionKey to 2, waveformKey to 25, paradeKey to 50)
        assertEquals(25, current.waveBrightness)
        assertEquals(50, current.paradeBrightness)

        val corrupt = migrate(versionKey to "not-a-version", waveformKey to "not-a-brightness", paradeKey to Int.MAX_VALUE)
        assertEquals(100, corrupt.waveBrightness)
        assertEquals(200, corrupt.paradeBrightness)

        val overflow = migrate(waveformKey to Int.MAX_VALUE, paradeKey to Int.MIN_VALUE)
        assertEquals(200, overflow.waveBrightness)
        assertEquals(0, overflow.paradeBrightness)
    }

    @Test
    fun `nonfinite legacy exposure and scope values recover to defaults`() {
        val state =
            migrate(
                "assist.zebra.highlight.ire.v1" to Float.NaN,
                "assist.zebra.midtone.ire.v1" to Float.POSITIVE_INFINITY,
                "assist.scopes.waveform.scale.v1" to Float.NaN,
                "assist.scopes.vector.scale.v1" to Float.NEGATIVE_INFINITY,
            )
        assertEquals(99.0, state.zebraHighlightIRE)
        assertEquals(55.0, state.zebraMidtoneIRE)
        assertEquals(1.0, state.waveScale)
        assertEquals(1.0, state.vectorScale)
    }

    @Test
    fun `legacy compensation values migrate with clamps`() {
        assertEquals(MonitorCrushClipCompensation.ZERO, migrate().crushClipCompensation)
        assertEquals(MonitorCrushClipCompensation.HALF, migrate("assist.scopes.crushClipCompensation.v1" to 5).crushClipCompensation)
        assertEquals(MonitorCrushClipCompensation.ONE, migrate("assist.scopes.crushClipCompensation.v1" to 15).crushClipCompensation)
        assertEquals(MonitorCrushClipCompensation.ZERO, migrate("assist.scopes.crushClipCompensation.v1" to -1).crushClipCompensation)
        // The newer key wins over the older one.
        assertEquals(
            MonitorCrushClipCompensation.QUARTER,
            migrate("scope-meter-v1" to 2, "assist.scopes.crushClipCompensation.v1" to 10).crushClipCompensation,
        )
    }

    @Test
    fun `legacy single framing selections migrate without changing camera grid state`() {
        val state =
            migrate(
                "assist.local.ruleOfThirds" to true,
                "assist.local.framingGuide.v1" to "CINEMA_239",
                "assist.local.desqueezePresentation.v1" to "X165",
            )
        assertTrue(state.isOn(MonitorAssistTool.GRID))
        assertTrue(state.isOn(MonitorAssistTool.GUIDES))
        assertEquals(setOf(MonitorGuideAspect.CINEMA), state.selectedGuides)
        assertTrue(state.isOn(MonitorAssistTool.DESQ))
        assertEquals(1.65, state.desqueezeFactor, absoluteTolerance = 0.001)
        // Nikon's unset axis narrowed the picture, which the shared model calls vertical.
        assertEquals(MonitorDesqueezeDirection.VERTICAL, state.desqueezeDirection)

        assertEquals(setOf(MonitorGuideAspect.HD), migrate("assist.local.framingGuide.v1" to "WIDESCREEN_16_9").selectedGuides)
    }

    @Test
    fun `malformed legacy framing selections safely fall back to inactive defaults`() {
        val state =
            migrate(
                "assist.local.guides.ratios.v2" to setOf("NOT_A_GUIDE"),
                "assist.local.desqueeze.ratio.v2" to "NOT_A_PRESENTATION",
                "assist.local.desqueeze.orientation.v2" to "NOT_AN_AXIS",
                "assist.peaking.color.v1" to "NOT_A_COLOR",
                "assist.scopes.waveform.mode.v1" to "NOT_A_MODE",
            )
        assertTrue(state.selectedGuides.isEmpty())
        assertFalse(state.isOn(MonitorAssistTool.DESQ))
        assertEquals(MonitorDesqueezePreset.X133.factor, state.desqueezeFactor)
        assertEquals(MonitorDesqueezeDirection.VERTICAL, state.desqueezeDirection)
        assertEquals(MonitorPeakingColor.RED, state.peakingColor)
        assertEquals(MonitorWaveformMode.RGB, state.waveMode)
    }

    @Test
    fun `per tool resets restore the shared defaults without moving scope panels`() {
        val state = restore().shared
        state.setFalseColor(MonitorFalseColorSelection.LIMITS, reference = false)
        state.setPeaking(MonitorPeakingColor.BLUE, MonitorPeakingSense.HIGH)
        state.updateZebraUnit(MonitorZebraUnit.NATIVE)
        state.setZebraHighlight(false, 42.0, MonitorZebraPaint.CYAN)
        state.setZebraMidtone(false, 12.0, MonitorZebraPaint.GREEN)
        state.setWaveform(MonitorWaveformMode.LUMA, 180, MonitorScopeGuides(false, false, false), 1.4)
        state.setParade(MonitorParadeMode.YRGB, 170, MonitorScopeGuides(false, false, false), 1.3)
        state.setVectorscope(MonitorVectorscopeZoom.X4, 160, 1.2)
        state.setHistogram(false, MonitorCrushClipCompensation.ONE, 0.8)
        state.setScale(MonitorAssistTool.LIGHTS, 1.5)

        MonitorAssistTool.entries.forEach(state::resetSettings)
        val restored = restore().shared

        assertEquals(MonitorFalseColorSelection.SCENE_STOPS, restored.falseColorScale)
        assertTrue(restored.falseColorReference)
        assertEquals(MonitorPeakingColor.RED, restored.peakingColor)
        assertEquals(MonitorPeakingSense.MED, restored.peakingSensitivity)
        assertEquals(MonitorZebraUnit.IRE, restored.zebraUnit)
        assertTrue(restored.zebraHighlight)
        assertEquals(99.0, restored.zebraHighlightIRE)
        assertEquals(MonitorZebraPaint.WHITE, restored.zebraHighlightColor)
        assertTrue(restored.zebraMidtone)
        assertEquals(55.0, restored.zebraMidtoneIRE)
        assertEquals(MonitorZebraPaint.AMBER, restored.zebraMidtoneColor)
        assertEquals(MonitorWaveformMode.RGB, restored.waveMode)
        assertEquals(MonitorScopeGuides(), restored.waveGuides)
        assertEquals(100, restored.waveBrightness)
        assertEquals(1.4, restored.waveScale)
        assertEquals(MonitorParadeMode.RGB, restored.paradeMode)
        assertEquals(1.3, restored.paradeScale)
        assertEquals(MonitorVectorscopeZoom.X1, restored.vectorZoom)
        assertEquals(100, restored.vectorBrightness)
        assertEquals(1.2, restored.vectorScale)
        assertTrue(restored.histoTrafficLights)
        assertEquals(MonitorCrushClipCompensation.ZERO, restored.crushClipCompensation)
        assertEquals(0.8, restored.histoScale)
        assertEquals(1.5, restored.lightsScale)
    }
}

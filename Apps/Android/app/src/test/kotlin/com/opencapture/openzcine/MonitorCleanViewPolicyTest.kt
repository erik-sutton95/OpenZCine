package com.opencapture.openzcine

import com.opencapture.openzcine.settings.MonitorDisplayMode
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertSame
import kotlin.test.assertTrue

/**
 * Android's half of the shared clean-view contract (#256). The rule itself is asserted once in the
 * core (`MonitorChromePolicy`); this covers the Kotlin projections the Compose shell renders from.
 */
class MonitorCleanViewPolicyTest {
    @Test
    fun `clean hides every tool that is not pinned and command hides all of them`() {
        for (tool in AssistTool.entries) {
            assertTrue(
                assistToolRendersInMode(tool, MonitorDisplayMode.LIVE, emptySet()),
                "$tool must render in live",
            )
            assertFalse(
                assistToolRendersInMode(tool, MonitorDisplayMode.CLEAN, emptySet()),
                "$tool must be hidden in clean by default",
            )
            assertFalse(
                assistToolRendersInMode(tool, MonitorDisplayMode.COMMAND, setOf(tool)),
                "$tool must be hidden in command even when pinned",
            )
            assertTrue(
                assistToolRendersInMode(tool, MonitorDisplayMode.CLEAN, setOf(tool)),
                "$tool must render in clean once pinned",
            )
        }
    }

    @Test
    fun `clean strips chrome and defers popups`() {
        assertTrue(monitorShowsChrome(MonitorDisplayMode.LIVE))
        assertFalse(monitorShowsChrome(MonitorDisplayMode.CLEAN))
        assertTrue(monitorShowsChrome(MonitorDisplayMode.COMMAND))
        assertTrue(monitorAllowsPopups(MonitorDisplayMode.LIVE))
        assertFalse(monitorAllowsPopups(MonitorDisplayMode.CLEAN))
        // Command's dashboard tiles open the value pickers, so pop-ups stay allowed there.
        assertTrue(monitorAllowsPopups(MonitorDisplayMode.COMMAND))
    }

    @Test
    fun `clean renders exactly the pinned scopes and leaves the stored set alone`() {
        val selected = setOf(ScopeKind.WAVEFORM, ScopeKind.HISTOGRAM, ScopeKind.TRAFFIC_LIGHTS)

        assertEquals(
            selected,
            renderedScopes(selected, MonitorDisplayMode.LIVE, emptySet()),
        )
        assertTrue(renderedScopes(selected, MonitorDisplayMode.CLEAN, emptySet()).isEmpty())
        assertEquals(
            setOf(ScopeKind.HISTOGRAM),
            renderedScopes(selected, MonitorDisplayMode.CLEAN, setOf(AssistTool.HISTO)),
        )
        assertTrue(renderedScopes(selected, MonitorDisplayMode.COMMAND, emptySet()).isEmpty())
    }

    @Test
    fun `clean bakes only the pinned feed effects`() {
        val effects =
            FeedEffects(
                lut = FeedLutSelection.BuiltIn(FeedLut.LOG3G10_709),
                falseColor = FeedFalseColorScale.STOPS,
                peaking = true,
                zebra = true,
            )

        // Live is handed the identical instance — no needless recomposition input.
        assertSame(effects, renderedFeedEffects(effects, MonitorDisplayMode.LIVE, emptySet()))

        val bare = renderedFeedEffects(effects, MonitorDisplayMode.CLEAN, emptySet())
        assertTrue(bare.isIdentity)

        val pinnedPeaking =
            renderedFeedEffects(effects, MonitorDisplayMode.CLEAN, setOf(AssistTool.PEAK))
        assertTrue(pinnedPeaking.peaking)
        assertFalse(pinnedPeaking.zebra)
        assertNull(pinnedPeaking.lut)
        assertNull(pinnedPeaking.falseColor)

        // Leaving clean restores the operator's set untouched.
        assertSame(effects, renderedFeedEffects(effects, MonitorDisplayMode.LIVE, setOf(AssistTool.PEAK)))
    }

    @Test
    fun `clean draws only the pinned framing aids`() {
        val configuration =
            com.opencapture.openzcine.settings.LocalFramingAssistConfiguration(
                guidesVisible = true,
                guideFamily = com.opencapture.openzcine.settings.LocalFramingGuideFamily.FILM,
                selectedGuideRatios =
                    setOf(com.opencapture.openzcine.settings.LocalFramingAspectRatio.RATIO_239),
                guideMaskEnabled = true,
                gridVisible = true,
                ruleOfThirdsEnabled = true,
                phiGridEnabled = false,
                diagonalGridEnabled = false,
                centerCrosshairEnabled = true,
                levelEnabled = true,
                evMeterEnabled = true,
                desqueezeEnabled = true,
                desqueezeRatio = com.opencapture.openzcine.settings.LocalDesqueezeRatio.X133,
                desqueezeOrientation =
                    com.opencapture.openzcine.settings.LocalDesqueezeOrientation.HORIZONTAL,
            )

        assertSame(
            configuration,
            renderedFramingAssists(configuration, MonitorDisplayMode.LIVE, emptySet()),
        )

        val bare = renderedFramingAssists(configuration, MonitorDisplayMode.CLEAN, emptySet())
        assertFalse(bare.guidesVisible)
        assertFalse(bare.gridVisible)
        assertFalse(bare.centerCrosshairEnabled)
        assertFalse(bare.levelEnabled)
        assertFalse(bare.evMeterEnabled)
        assertFalse(bare.desqueezeEnabled)

        val pinnedGuides =
            renderedFramingAssists(configuration, MonitorDisplayMode.CLEAN, setOf(AssistTool.GUIDES))
        assertTrue(pinnedGuides.guidesVisible)
        assertFalse(pinnedGuides.gridVisible)
    }

    @Test
    fun `a hidden lock button still renders while controls are locked`() {
        // The lock button is the only control that clears the lock, so hiding it must never
        // strand an operator who locked first and hid it after. Same rule as the core's
        // `MonitorChromePolicy.showsLockControl`.
        assertTrue(
            monitorShowsLockControl(MonitorDisplayMode.LIVE, lockButtonVisible = true, interfaceLocked = false),
        )
        assertFalse(
            monitorShowsLockControl(MonitorDisplayMode.LIVE, lockButtonVisible = false, interfaceLocked = false),
        )
        assertTrue(
            monitorShowsLockControl(MonitorDisplayMode.LIVE, lockButtonVisible = false, interfaceLocked = true),
        )
        assertTrue(
            monitorShowsLockControl(MonitorDisplayMode.COMMAND, lockButtonVisible = false, interfaceLocked = true),
        )
        // Clean strips the rail either way — not a fourth clean-view exception.
        assertFalse(
            monitorShowsLockControl(MonitorDisplayMode.CLEAN, lockButtonVisible = true, interfaceLocked = true),
        )
    }

    @Test
    fun `battery indicators hide on request and always in clean`() {
        assertTrue(monitorShowsBatteryIndicators(MonitorDisplayMode.LIVE, batteryIndicatorsVisible = true))
        assertTrue(monitorShowsBatteryIndicators(MonitorDisplayMode.COMMAND, batteryIndicatorsVisible = true))
        assertFalse(monitorShowsBatteryIndicators(MonitorDisplayMode.CLEAN, batteryIndicatorsVisible = true))
        for (mode in MonitorDisplayMode.entries) {
            assertFalse(
                monitorShowsBatteryIndicators(mode, batteryIndicatorsVisible = false),
                "batteries must stay hidden in $mode",
            )
        }
    }

    @Test
    fun `command keeps the timecode source while dropping every preview consumer`() {
        val source = object : com.opencapture.openzcine.core.LiveFrameSource {
            override val frames = kotlinx.coroutines.flow.emptyFlow<com.opencapture.openzcine.core.LiveFrame>()
        }
        assertNull(monitorPreviewFrameSource(source, isCommandMode = true))
        assertSame(source, monitorTimecodeFrameSource(source))
        assertNull(monitorTimecodeFrameSource(null))
    }
}

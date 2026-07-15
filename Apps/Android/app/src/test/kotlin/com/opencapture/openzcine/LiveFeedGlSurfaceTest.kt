package com.opencapture.openzcine

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class LiveFeedGlSurfaceTest {
    @Test
    fun `api 29 floor exposes image assists only with the staged Swift policy`() {
        assertFalse(liveFeedEffectsPlatformAvailable(28, true))
        for (sdk in 29..36) {
            assertTrue(liveFeedEffectsPlatformAvailable(sdk, true))
            assertFalse(liveFeedEffectsPlatformAvailable(sdk, false))
        }
    }

    @Test
    fun `live assist color gate accepts original SDR and rejects HDR or unknown input`() {
        assertEquals(
            LiveFeedColorMode.SDR,
            classifyLiveFeedColorMode(
                hasGainmap = false,
                isSrgb = true,
                usesHdrTransfer = false,
                usesFloatingPointPixels = false,
            ),
        )
        assertEquals(
            LiveFeedColorMode.HDR,
            classifyLiveFeedColorMode(
                hasGainmap = true,
                isSrgb = true,
                usesHdrTransfer = false,
                usesFloatingPointPixels = false,
            ),
        )
        assertEquals(
            LiveFeedColorMode.HDR,
            classifyLiveFeedColorMode(
                hasGainmap = false,
                isSrgb = false,
                usesHdrTransfer = true,
                usesFloatingPointPixels = true,
            ),
        )
        assertEquals(
            LiveFeedColorMode.UNSUPPORTED,
            classifyLiveFeedColorMode(
                hasGainmap = false,
                isSrgb = false,
                usesHdrTransfer = false,
                usesFloatingPointPixels = false,
            ),
        )

        assertTrue(liveFeedEffectsCanRender(29, true, LiveFeedColorMode.SDR))
        assertTrue(liveFeedEffectsCanRender(36, true, LiveFeedColorMode.SDR))
        assertFalse(liveFeedEffectsCanRender(32, true, LiveFeedColorMode.HDR))
        assertFalse(liveFeedEffectsCanRender(36, true, LiveFeedColorMode.UNSUPPORTED))
        assertFalse(liveFeedEffectsCanRender(36, true, LiveFeedColorMode.UNKNOWN))
    }

    @Test
    fun `legacy GL viewport exactly mirrors fit and portrait fill canvas geometry`() {
        assertEquals(
            LiveFeedGlViewport(x = 0, y = 187, width = 400, height = 225),
            liveFeedGlViewport(400, 600, 1_920, 1_080, aspectFill = false),
        )
        assertEquals(
            LiveFeedGlViewport(x = -333, y = 0, width = 1_067, height = 600),
            liveFeedGlViewport(400, 600, 1_920, 1_080, aspectFill = true),
        )
        assertNull(liveFeedGlViewport(0, 600, 1_920, 1_080, aspectFill = true))
    }

    @Test
    fun `a replacement plan clears a fail closed legacy renderer for retry`() {
        val state = LegacyLiveFeedSurfaceState()
        val failedPlan = testRenderPlan()
        state.update(failedPlan, aspectFill = false)
        assertTrue(state.recordRenderFailure(failedPlan))
        assertTrue(state.renderFailed)

        state.update(failedPlan, aspectFill = true)
        assertTrue(state.renderFailed)

        val replacement = testRenderPlan()
        state.update(replacement, aspectFill = true)
        assertFalse(state.renderFailed)
        assertFalse(state.recordRenderFailure(failedPlan))
        state.dispose()
    }

    private fun testRenderPlan(): FeedEffectsRenderPlan =
        FeedEffectsRenderPlan(
            effects = FeedEffects(),
            configuration =
                FeedEffectsRenderConfiguration(
                    curveOrdinal = 0,
                    clipNative = 255f,
                    deLogCurve = floatArrayOf(0f, 0.25f, 0.5f, 0.75f, 1f),
                    peakingThreshold = 0.1f,
                    peakingRamp = 10f,
                    peakingColor = floatArrayOf(1f, 0f, 0f),
                    highlightEnabled = false,
                    highlightCode = 1f,
                    highlightColor = floatArrayOf(1f, 1f, 1f),
                    midtoneEnabled = false,
                    midtoneCode = 0.5f,
                    midtoneColor = floatArrayOf(1f, 1f, 1f),
                ),
            baseCube = null,
            limitsPaintCube = null,
            limitsWeightCube = null,
        )
}

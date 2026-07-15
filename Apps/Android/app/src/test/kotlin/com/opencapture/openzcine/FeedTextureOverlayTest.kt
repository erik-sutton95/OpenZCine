package com.opencapture.openzcine

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertSame
import kotlin.test.assertTrue

class FeedTextureOverlayTest {
    @Test
    fun `vignette policy matches iOS radii and edge opacity`() {
        assertEquals(70f, FeedTexturePattern.VIGNETTE_START_RADIUS_DP)
        assertEquals(620f, FeedTexturePattern.VIGNETTE_END_RADIUS_DP)
        assertEquals(0.46f, FeedTexturePattern.VIGNETTE_EDGE_OPACITY)
    }

    @Test
    fun `fit texture clips to image and leaves letterbox untouched`() {
        val visible =
            feedTextureVisibleRect(
                containerWidth = 400f,
                containerHeight = 600f,
                sourceWidth = 1_920,
                sourceHeight = 1_080,
                aspectFill = false,
                horizontalPresentationScale = 1f,
                verticalPresentationScale = 1f,
            )

        assertNotNull(visible)
        assertEquals(0f, visible.left)
        assertEquals(188f, visible.top)
        assertEquals(400f, visible.width)
        assertEquals(225f, visible.height)
    }

    @Test
    fun `fill texture clips centre-cropped overhang to visible image`() {
        val visible =
            feedTextureVisibleRect(
                containerWidth = 400f,
                containerHeight = 600f,
                sourceWidth = 1_920,
                sourceHeight = 1_080,
                aspectFill = true,
                horizontalPresentationScale = 1f,
                verticalPresentationScale = 1f,
            )

        assertNotNull(visible)
        assertEquals(LiveOverlayRect(0f, 0f, 400f, 600f), visible)
    }

    @Test
    fun `texture follows de-squeezed image without changing overlay geometry`() {
        val visible =
            feedTextureVisibleRect(
                containerWidth = 1_000f,
                containerHeight = 1_000f,
                sourceWidth = 1_920,
                sourceHeight = 1_080,
                aspectFill = false,
                horizontalPresentationScale = 0.5f,
                verticalPresentationScale = 1f,
            )

        assertNotNull(visible)
        assertEquals(250f, visible.left)
        assertEquals(219f, visible.top)
        assertEquals(500f, visible.width)
        assertEquals(563f, visible.height)
    }

    @Test
    fun `texture has no render plan before a valid source frame`() {
        assertNull(
            feedTextureVisibleRect(
                containerWidth = 400f,
                containerHeight = 600f,
                sourceWidth = 0,
                sourceHeight = 0,
                aspectFill = false,
                horizontalPresentationScale = 1f,
                verticalPresentationScale = 1f,
            ),
        )
    }

    @Test
    fun `grain pattern is deterministic and matches iOS sample policy`() {
        assertEquals(180, FeedTexturePattern.normalizedX.size)
        assertEquals(180, FeedTexturePattern.normalizedY.size)
        assertEquals(180, FeedTexturePattern.opacity.size)

        for (index in 0 until FeedTexturePattern.GRAIN_SAMPLE_COUNT) {
            assertEquals(
                ((index * 73) % 791).toFloat() / 791f,
                FeedTexturePattern.normalizedX[index],
            )
            assertEquals(
                ((index * 47) % 367).toFloat() / 367f,
                FeedTexturePattern.normalizedY[index],
            )
            assertEquals(
                0.016f + (index % 5) * 0.004f,
                FeedTexturePattern.opacity[index],
            )
            assertTrue(FeedTexturePattern.normalizedX[index] in 0f..<1f)
            assertTrue(FeedTexturePattern.normalizedY[index] in 0f..<1f)
        }
    }

    @Test
    fun `unchanged stream resolution reuses allocation policy state`() {
        val first = retainedFeedTextureSourceGeometry(null, 1_920, 1_080)
        val next = retainedFeedTextureSourceGeometry(first, 1_920, 1_080)
        val changed = retainedFeedTextureSourceGeometry(next, 1_280, 720)

        assertNotNull(first)
        assertSame(first, next)
        assertNotNull(changed)
        assertTrue(changed !== first)
        assertEquals(FeedTextureSourceGeometry(1_280, 720), changed)
        assertNull(retainedFeedTextureSourceGeometry(changed, 0, 720))
    }
}

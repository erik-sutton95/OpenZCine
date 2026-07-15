package com.opencapture.openzcine

import android.graphics.Bitmap
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.requiredSize
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toPixelMap
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.opencapture.openzcine.core.LiveFrame
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** Device-rendered pixel contract for the cached vignette and fit clipping. */
@RunWith(AndroidJUnit4::class)
class FeedTextureOverlayComposeTest {
    @get:Rule
    val composeRule = createComposeRule()

    @Test
    fun vignetteDarkensVisibleFeedEdgesWithoutTouchingLetterbox() {
        val presentation = LiveFeedPresentationState()
        presentation.present(
            frame = LiveFrame(timestampNanos = 0L, jpegData = ByteArray(0)),
            bitmap = Bitmap.createBitmap(1_920, 1_080, Bitmap.Config.ARGB_8888),
            colorMode = LiveFeedColorMode.SDR,
        )
        val neutral = Color(0xFF808080)
        composeRule.setContent {
            Box(
                Modifier
                    .requiredSize(width = 320.dp, height = 240.dp)
                    .background(neutral)
                    .testTag(SURFACE_TAG),
            ) {
                FeedTextureOverlay(
                    presentationState = presentation,
                    aspectFill = false,
                    horizontalPresentationScale = 1f,
                    verticalPresentationScale = 1f,
                )
            }
        }

        val pixels = composeRule.onNodeWithTag(SURFACE_TAG).captureToImage().toPixelMap()
        val centre = pixels[pixels.width / 2, pixels.height / 2]
        val letterbox = pixels[pixels.width / 2, pixels.height / 20]
        val feedEdge =
            averageRed(
                pixels = pixels,
                startX = pixels.width / 30,
                startY = pixels.height * 5 / 32,
                sampleSize = 8,
            )

        assertEquals(neutral.red.toDouble(), centre.red.toDouble(), 0.01)
        assertEquals(neutral.red.toDouble(), letterbox.red.toDouble(), 0.01)
        assertTrue(feedEdge < centre.red - 0.02f)
    }

    private fun averageRed(
        pixels: androidx.compose.ui.graphics.PixelMap,
        startX: Int,
        startY: Int,
        sampleSize: Int,
    ): Float {
        var total = 0f
        for (x in startX until startX + sampleSize) {
            for (y in startY until startY + sampleSize) {
                total += pixels[x, y].red
            }
        }
        return total / (sampleSize * sampleSize)
    }

    private companion object {
        const val SURFACE_TAG = "feed-texture-test-surface"
    }
}

@file:androidx.media3.common.util.UnstableApi

package com.opencapture.openzcine

import android.content.ContentValues
import android.graphics.Bitmap
import android.graphics.Color
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.MediaStore
import android.view.PixelCopy
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

private const val SCREENSHOT_ARGUMENT = "ope91Screenshots"

/** Device proof for the API 29-32 live surface, runnable on newer GLES2 devices too. */
@RunWith(AndroidJUnit4::class)
class LegacyLiveFeedGlSurfaceTest {
    @get:Rule
    val composeRule = createComposeRule()

    @Test
    fun unsupportedLiveColorIsVisibleAndNeverPretendsTheAssistRendered() {
        val effectsActive = mutableStateOf(true)
        composeRule.setContent {
            OpenZCineTheme {
                Box(
                    modifier = Modifier.fillMaxSize(),
                    contentAlignment = Alignment.TopCenter,
                ) {
                    Box(
                        Modifier.padding(top = 8.dp)
                            .size(width = 280.dp, height = 46.dp)
                            .glass(ChromeShape),
                    )
                    LiveFeedColorModeNotice(
                        colorMode = LiveFeedColorMode.HDR,
                        effectsActive = effectsActive.value,
                        modifier = Modifier.padding(top = 62.dp),
                    )
                }
            }
        }

        composeRule.onNodeWithText("HDR LIVE VIEW · IMAGE ASSISTS OFF").assertIsDisplayed()
        composeRule
            .onNodeWithContentDescription("hdr live view · image assists off")
            .assertIsDisplayed()
        saveDeviceScreenshot("hdr-live-assists-off.png")

        composeRule.runOnIdle { effectsActive.value = false }
        composeRule.waitUntil(5_000) {
            composeRule
                .onAllNodesWithText("HDR LIVE VIEW · IMAGE ASSISTS OFF")
                .fetchSemanticsNodes()
                .isEmpty()
        }
    }

    @Test
    fun sharedPlanRendersIntoTheExactFitViewport() {
        var surface: LegacyLiveFeedGlSurface? = null
        val surfaceState = LegacyLiveFeedSurfaceState()
        val source = Bitmap.createBitmap(160, 90, Bitmap.Config.ARGB_8888)
        val topColor = Color.rgb(180, 64, 210)
        val bottomColor = Color.rgb(30, 190, 70)
        for (y in 0 until source.height) {
            val color = if (y < source.height / 2) topColor else bottomColor
            for (x in 0 until source.width) source.setPixel(x, y, color)
        }
        composeRule.setContent {
            Box(Modifier.size(200.dp)) {
                AndroidView(
                    factory = { context ->
                        LegacyLiveFeedGlSurface(context).also {
                            surface = it
                            surfaceState.attach(it)
                        }
                    },
                    modifier = Modifier.fillMaxSize(),
                    onRelease = surfaceState::detach,
                )
            }
        }
        composeRule.waitUntil(5_000) {
            surface?.let { view ->
                view.width > 0 && view.height > 0 && view.holder.surface.isValid
            } == true
        }
        val liveSurface = requireNotNull(surface)
        composeRule.runOnIdle {
            // The view mounted while the host lifecycle was paused. Resuming
            // must accept the next frame without allowing background copies.
            surfaceState.resume()
            surfaceState.update(identityLutPlan(), aspectFill = false)
            surfaceState.submit(source)
        }

        val output = copyRenderedSurface(liveSurface)
        try {
            val content =
                requireNotNull(
                    liveFeedContentRect(
                        output.width.toFloat(),
                        output.height.toFloat(),
                        source.width,
                        source.height,
                    ),
                )
            assertPixelNear(
                topColor,
                output.getPixel(output.width / 2, content.top + content.height / 4),
                "upright top",
            )
            assertPixelNear(
                bottomColor,
                output.getPixel(output.width / 2, content.top + content.height * 3 / 4),
                "upright bottom",
            )
            assertEquals(Color.BLACK, output.getPixel(output.width / 2, 4))
            assertEquals(Color.BLACK, output.getPixel(output.width / 2, output.height - 5))
        } finally {
            output.recycle()
            surfaceState.dispose()
            source.recycle()
        }
    }

    @Test
    fun legacyWearPreviewUsesTheSameUprightEffectProgram() {
        val source = Bitmap.createBitmap(4, 4, Bitmap.Config.ARGB_8888)
        val topColor = Color.rgb(180, 64, 210)
        val bottomColor = Color.rgb(30, 190, 70)
        for (y in 0 until source.height) {
            val color = if (y < source.height / 2) topColor else bottomColor
            for (x in 0 until source.width) source.setPixel(x, y, color)
        }
        val baker =
            LegacyFeedEffectsPreviewBaker(
                InstrumentationRegistry.getInstrumentation().targetContext,
                identityLutPlan(),
            )
        val output = try {
            requireNotNull(baker.bakePreview(source, maximumWidth = 2))
        } finally {
            baker.close()
            source.recycle()
        }
        try {
            assertEquals(2, output.width)
            assertEquals(2, output.height)
            assertPixelNear(topColor, output.getPixel(1, 0), "Wear upright top")
            assertPixelNear(bottomColor, output.getPixel(1, 1), "Wear upright bottom")
        } finally {
            output.recycle()
        }
    }

    @Test
    fun legacyFramePoolOwnsPixelsAfterTheDecoderReusesItsBitmap() {
        val originalColor = Color.rgb(180, 64, 210)
        val reusedColor = Color.rgb(30, 190, 70)
        val source = Bitmap.createBitmap(8, 8, Bitmap.Config.ARGB_8888)
        val pool = LegacyLiveFeedFramePool(size = 1)
        source.eraseColor(originalColor)
        val lease = requireNotNull(pool.copy(source))
        try {
            source.eraseColor(reusedColor)
            assertPixelNear(originalColor, lease.bitmap.getPixel(4, 4), "pool-owned pixel")
        } finally {
            lease.release()
            pool.close()
            source.recycle()
        }
    }

    private fun copyRenderedSurface(surface: LegacyLiveFeedGlSurface): Bitmap {
        repeat(20) {
            val (output, result) = copySurface(surface)
            if (result == PixelCopy.SUCCESS) {
                val center = output.getPixel(output.width / 2, output.height / 2)
                if (Color.red(center) > 0 || Color.green(center) > 0 || Color.blue(center) > 0) {
                    return output
                }
            }
            output.recycle()
            SystemClock.sleep(50)
        }
        val (output, result) = copySurface(surface)
        assertEquals(PixelCopy.SUCCESS, result)
        return output
    }

    private fun saveDeviceScreenshot(name: String) {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        if (InstrumentationRegistry.getArguments().getString(SCREENSHOT_ARGUMENT) != "true") {
            return
        }
        val screenshot = requireNotNull(instrumentation.uiAutomation.takeScreenshot())
        val values =
            ContentValues().apply {
                put(MediaStore.Images.Media.DISPLAY_NAME, name)
                put(MediaStore.Images.Media.MIME_TYPE, "image/png")
                put(
                    MediaStore.Images.Media.RELATIVE_PATH,
                    "${Environment.DIRECTORY_PICTURES}/OpenZCine-OPE91",
                )
            }
        val resolver = instrumentation.targetContext.contentResolver
        val output =
            checkNotNull(
                resolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values),
            )
        resolver.openOutputStream(output).use { stream ->
            checkNotNull(stream)
            check(screenshot.compress(Bitmap.CompressFormat.PNG, 100, stream))
        }
        screenshot.recycle()
        println("OPE91_SCREENSHOT=$output")
    }

    private fun copySurface(surface: LegacyLiveFeedGlSurface): Pair<Bitmap, Int> {
        val output = Bitmap.createBitmap(surface.width, surface.height, Bitmap.Config.ARGB_8888)
        val latch = CountDownLatch(1)
        var result = PixelCopy.ERROR_UNKNOWN
        PixelCopy.request(
            surface,
            output,
            { status ->
                result = status
                latch.countDown()
            },
            Handler(Looper.getMainLooper()),
        )
        assertTrue("PixelCopy timed out", latch.await(5, TimeUnit.SECONDS))
        return output to result
    }

    private fun assertPixelNear(expected: Int, actual: Int, label: String) {
        val channels =
            listOf(
                Color.red(expected) to Color.red(actual),
                Color.green(expected) to Color.green(actual),
                Color.blue(expected) to Color.blue(actual),
            )
        assertTrue(
            "$label expected ${Color.red(expected)},${Color.green(expected)},${Color.blue(expected)} " +
                "but got ${Color.red(actual)},${Color.green(actual)},${Color.blue(actual)}",
            channels.all { (wanted, got) -> kotlin.math.abs(wanted - got) <= 3 },
        )
    }

    private fun identityLutPlan(): FeedEffectsRenderPlan =
        FeedEffectsRenderPlan(
            effects = FeedEffects(lut = FeedLutSelection.BuiltIn(FeedLut.LOG3G10_709)),
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
            baseCube = identityCube(),
            limitsPaintCube = null,
            limitsWeightCube = null,
        )

    private fun identityCube(): FeedEffectsCube {
        val size = 2
        val rgba = ByteArray(size * size * size * 4)
        for (green in 0 until size) {
            for (blue in 0 until size) {
                for (red in 0 until size) {
                    val offset = (green * size * size + blue * size + red) * 4
                    rgba[offset] = (red * 255).toByte()
                    rgba[offset + 1] = (green * 255).toByte()
                    rgba[offset + 2] = (blue * 255).toByte()
                    rgba[offset + 3] = 0xff.toByte()
                }
            }
        }
        return FeedEffectsCube(size, rgba)
    }
}

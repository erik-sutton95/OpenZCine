@file:androidx.media3.common.util.UnstableApi

package com.opencapture.openzcine.media

import android.graphics.Bitmap
import android.graphics.Color
import android.opengl.EGL14
import android.opengl.EGLContext
import android.opengl.EGLDisplay
import android.opengl.EGLSurface
import android.opengl.GLES20
import androidx.media3.common.util.GlUtil
import androidx.media3.effect.BaseGlShaderProgram
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.opencapture.openzcine.FeedEffects
import com.opencapture.openzcine.FeedEffectsCube
import com.opencapture.openzcine.FeedEffectsRenderConfiguration
import com.opencapture.openzcine.FeedEffectsRenderPlan
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.abs
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/** On-device pixel contract for the API 29–32 Media3 GLES playback renderer. */
@RunWith(AndroidJUnit4::class)
class PlaybackFeedEffectGlTest {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext

    @Test
    fun sdrIdentityRampPreservesDisplayCodeValues() {
        val codes = intArrayOf(0, 64, 128, 255)
        val input =
            Bitmap.createBitmap(codes.size, 1, Bitmap.Config.ARGB_8888).apply {
                codes.forEachIndexed { x, code -> setPixel(x, 0, Color.rgb(code, code, code)) }
            }

        val output = render(identityPlan(), input)

        codes.forEachIndexed { x, expected ->
            val offset = x * 4
            assertNear(expected, output[offset].unsigned(), "red[$x]")
            assertNear(expected, output[offset + 1].unsigned(), "green[$x]")
            assertNear(expected, output[offset + 2].unsigned(), "blue[$x]")
        }
    }

    @Test
    fun cubeAtlasPreservesTheGreenAxisAcrossTiledRows() {
        val cube = greenAxisCube()
        val input =
            Bitmap.createBitmap(2, 1, Bitmap.Config.ARGB_8888).apply {
                setPixel(0, 0, Color.BLACK)
                setPixel(1, 0, Color.GREEN)
            }

        val output = render(identityPlan(cube), input)

        assertNear(0, output[0].unsigned(), "green-axis low")
        assertNear(255, output[4].unsigned(), "green-axis high")
    }

    @Test
    fun cubeAtlasPreservesAllRgbAxesAcrossTiles() {
        val input = Bitmap.createBitmap(8, 1, Bitmap.Config.ARGB_8888)
        val expected = mutableListOf<IntArray>()
        var x = 0
        for (blue in 0..1) {
            for (green in 0..1) {
                for (red in 0..1) {
                    val color =
                        intArrayOf(
                            red * 255,
                            green * 255,
                            blue * 255,
                        )
                    expected += color
                    input.setPixel(x++, 0, Color.rgb(color[0], color[1], color[2]))
                }
            }
        }

        val output = render(identityPlan(identityCube()), input)

        expected.forEachIndexed { index, color ->
            val offset = index * 4
            assertNear(color[0], output[offset].unsigned(), "red[$index]")
            assertNear(color[1], output[offset + 1].unsigned(), "green[$index]")
            assertNear(color[2], output[offset + 2].unsigned(), "blue[$index]")
        }
    }

    private fun render(plan: FeedEffectsRenderPlan, input: Bitmap): ByteArray {
        val display = GlUtil.getDefaultEglDisplay()
        val eglContext = GlUtil.createEglContext(display)
        val surface = GlUtil.createFocusedPlaceholderEglSurface(eglContext, display)
        var inputTexture = 0
        var outputTexture = 0
        var framebuffer = 0
        var program: BaseGlShaderProgram? = null
        try {
            inputTexture = GlUtil.createTexture(input)
            outputTexture = GlUtil.createTexture(input.width, input.height, false)
            framebuffer = GlUtil.createFboForTexture(outputTexture)
            GlUtil.focusFramebuffer(
                display,
                eglContext,
                surface,
                framebuffer,
                input.width,
                input.height,
            )
            val displaySize = PlaybackEffectDisplaySize().apply {
                update(input.width.toFloat(), input.height.toFloat())
            }
            program =
                PlaybackFeedEffect(plan, displaySize).toGlShaderProgram(context, false)
                    as BaseGlShaderProgram
            program.configure(input.width, input.height)
            program.drawFrame(inputTexture, 0L)
            GLES20.glFinish()
            val pixels =
                ByteBuffer.allocateDirect(input.width * input.height * 4)
                    .order(ByteOrder.nativeOrder())
            GLES20.glReadPixels(
                0,
                0,
                input.width,
                input.height,
                GLES20.GL_RGBA,
                GLES20.GL_UNSIGNED_BYTE,
                pixels,
            )
            GlUtil.checkGlError()
            pixels.position(0)
            return ByteArray(pixels.capacity()).also { output -> pixels.get(output) }
        } finally {
            program?.release()
            if (framebuffer != 0) GlUtil.deleteFbo(framebuffer)
            if (outputTexture != 0) GlUtil.deleteTexture(outputTexture)
            if (inputTexture != 0) GlUtil.deleteTexture(inputTexture)
            input.recycle()
            releaseEgl(display, eglContext, surface)
        }
    }

    private fun identityPlan(baseCube: FeedEffectsCube? = null): FeedEffectsRenderPlan =
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
            baseCube = baseCube,
            limitsPaintCube = null,
            limitsWeightCube = null,
        )

    private fun greenAxisCube(): FeedEffectsCube {
        val size = 2
        val rgba = ByteArray(size * size * size * 4)
        for (green in 0 until size) {
            for (blue in 0 until size) {
                for (red in 0 until size) {
                    val offset = (green * size * size + blue * size + red) * 4
                    val value = if (green == 0) 0.toByte() else 0xff.toByte()
                    rgba[offset] = value
                    rgba[offset + 1] = value
                    rgba[offset + 2] = value
                    rgba[offset + 3] = 0xff.toByte()
                }
            }
        }
        return FeedEffectsCube(size, rgba)
    }

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

    private fun releaseEgl(
        display: EGLDisplay,
        context: EGLContext,
        surface: EGLSurface,
    ) {
        EGL14.eglMakeCurrent(
            display,
            EGL14.EGL_NO_SURFACE,
            EGL14.EGL_NO_SURFACE,
            EGL14.EGL_NO_CONTEXT,
        )
        if (surface != EGL14.EGL_NO_SURFACE) GlUtil.destroyEglSurface(display, surface)
        GlUtil.destroyEglContext(display, context)
        GlUtil.terminate(display)
    }

    private fun assertNear(expected: Int, actual: Int, label: String) {
        assertTrue("$label expected $expected, got $actual", abs(expected - actual) <= 2)
    }

    private fun Byte.unsigned(): Int = toInt() and 0xff
}

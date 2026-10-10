@file:androidx.media3.common.util.UnstableApi

package com.opencapture.openzcine

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import android.opengl.EGL14
import android.opengl.GLES20
import androidx.media3.common.util.GlUtil
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.opencapture.opencine.media.MonitorLUTCube
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Real GPU readback, SIMULATED device gate: the shared one-pass Bitmap look renders the exact
 * pixels of the frozen donor GLES program, magnified and minified. No tolerance, no skip.
 */
@RunWith(AndroidJUnit4::class)
class NikonBitmapGlesPixelParityTest {
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext

    /** Lossless decode of hard black/white/colour edges, so the cubic overshoots both ends. */
    private fun decodedEdges(): Bitmap {
        val raster = Bitmap.createBitmap(17, 9, Bitmap.Config.ARGB_8888)
        val bars = intArrayOf(Color.BLACK, Color.WHITE, Color.RED, Color.BLACK, Color.BLUE, Color.WHITE)
        for (y in 0 until 9) for (x in 0 until 17) {
            raster.setPixel(x, y, if (y in 3..5 && x in 7..9) Color.WHITE else bars[(x / 3) % bars.size])
        }
        val encoded = ByteArrayOutputStream()
        try { check(raster.compress(Bitmap.CompressFormat.PNG, 100, encoded)) } finally { raster.recycle() }
        val bytes = encoded.toByteArray()
        return requireNotNull(BitmapFactory.decodeByteArray(bytes, 0, bytes.size))
    }

    private fun render(width: Int, height: Int, draw: (Int, Bitmap) -> Unit): ByteArray {
        val display = GlUtil.getDefaultEglDisplay()
        val eglContext = GlUtil.createEglContext(display)
        val surface = GlUtil.createFocusedPlaceholderEglSurface(eglContext, display)
        val input = decodedEdges()
        var inputTexture = 0
        var outputTexture = 0
        var framebuffer = 0
        try {
            inputTexture = GlUtil.createTexture(input)
            outputTexture = GlUtil.createTexture(width, height, false)
            framebuffer = GlUtil.createFboForTexture(outputTexture)
            GlUtil.focusFramebuffer(display, eglContext, surface, framebuffer, width, height)
            GLES20.glClearColor(0f, 0f, 0f, 1f)
            GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)
            draw(inputTexture, input)
            GLES20.glFinish()
            val pixels = ByteBuffer.allocateDirect(width * height * 4).order(ByteOrder.nativeOrder())
            GLES20.glReadPixels(0, 0, width, height, GLES20.GL_RGBA, GLES20.GL_UNSIGNED_BYTE, pixels)
            GlUtil.checkGlError()
            return ByteArray(pixels.capacity()).also { pixels.position(0); pixels.get(it) }
        } finally {
            if (framebuffer != 0) GlUtil.deleteFbo(framebuffer)
            if (outputTexture != 0) GlUtil.deleteTexture(outputTexture)
            if (inputTexture != 0) GlUtil.deleteTexture(inputTexture)
            input.recycle()
            EGL14.eglMakeCurrent(display, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT)
            GlUtil.destroyEglSurface(display, surface)
            GlUtil.destroyEglContext(display, eglContext)
            GlUtil.terminate(display)
        }
    }

    private fun donor(plan: FeedEffectsRenderPlan, width: Int, height: Int, mirrored: Boolean) =
        render(width, height) { texture, input ->
            val program = FrozenNikonFeedEffectsGlProgram(context, plan, flipInputVertically = true)
            try {
                program.draw(texture, input.width.toFloat(), input.height.toFloat(),
                    width.toFloat(), height.toFloat(), mirrored)
            } finally { program.release() }
        }

    private fun shared(plan: FeedEffectsRenderPlan, width: Int, height: Int, mirrored: Boolean, onePass: Boolean) =
        render(width, height) { texture, input ->
            val program = com.opencapture.opencine.runtime.FeedEffectsGlProgram(
                Media3FeedGlBackend(context), plan.nativePlan, flipInputVertically = true)
            try {
                program.draw(texture, input.width.toFloat(), input.height.toFloat(),
                    width.toFloat(), height.toFloat(), mirrored, onePassUpscale = onePass)
            } finally { program.release() }
        }

    private fun configuration(zebra: Boolean) = FeedEffectsRenderConfiguration(
        curveOrdinal = 0, clipNative = 255f, deLogCurve = floatArrayOf(0f, 0.25f, 0.5f, 0.75f, 1f),
        peakingRatioThreshold = 1.35f, peakingNoiseGate = 0.008f, peakingColor = floatArrayOf(1f, 0f, 0f),
        highlightEnabled = zebra, highlightCode = 0.9f, highlightColor = floatArrayOf(1f, 1f, 1f),
        midtoneEnabled = zebra, midtoneCode = 0.3f, midtoneColor = floatArrayOf(1f, 0.72f, 0.2f),
    )

    private fun cube(): MonitorLUTCube {
        val size = 2
        val rgba = ByteArray(size * size * size * 4)
        for (green in 0 until size) for (blue in 0 until size) for (red in 0 until size) {
            val offset = (green * size * size + blue * size + red) * 4
            rgba[offset] = (green * 255).toByte()
            rgba[offset + 1] = (blue * 255).toByte()
            rgba[offset + 2] = (red * 255).toByte()
            rgba[offset + 3] = 0xff.toByte()
        }
        return MonitorLUTCube(size, rgba)
    }

    private fun plans(): Map<String, FeedEffectsRenderPlan> = mapOf(
        "identity" to FeedEffectsRenderPlan(FeedEffects(), configuration(false), null, null, null),
        "lut" to FeedEffectsRenderPlan(
            FeedEffects(lut = FeedLutSelection.BuiltIn(FeedLut.entries.first())),
            configuration(false), cube(), null, null),
        "split" to FeedEffectsRenderPlan(
            FeedEffects(lut = FeedLutSelection.BuiltIn(FeedLut.entries.first()),
                splitComparison = FeedSplitOrientation.VERTICAL),
            configuration(false), cube(), null, null),
        "zebra" to FeedEffectsRenderPlan(FeedEffects(zebra = true), configuration(true), null, null, null),
        "peaking" to FeedEffectsRenderPlan(FeedEffects(peaking = true), configuration(false), null, null, null),
    )

    @Test fun magnifiedAndMinifiedOnePassLookMatchesFrozenDonorExactly() {
        for ((name, plan) in plans()) {
            for ((width, height) in listOf(61 to 35, 11 to 6)) {
                for (mirrored in listOf(false, true)) {
                    val label = "$name ${width}x$height mirrored=$mirrored"
                    val expected = donor(plan, width, height, mirrored)
                    assertEquals(label, width * height * 4, expected.size)
                    assertArrayEquals(label, expected, shared(plan, width, height, mirrored, onePass = true))
                }
            }
        }
    }

    @Test fun sharedTwoPassDefaultIsNotTheDonorWhenMagnified() {
        // Nonvacuity: the gate above exercises reconstruction, which the existing shared
        // look default leaves off.
        val plan = plans().getValue("identity")
        val expected = donor(plan, 61, 35, mirrored = false)
        assertFalse(expected.contentEquals(shared(plan, 61, 35, mirrored = false, onePass = false)))
        assertArrayEquals(
            donor(plan, 11, 6, mirrored = false),
            shared(plan, 11, 6, mirrored = false, onePass = false),
        )
    }
}

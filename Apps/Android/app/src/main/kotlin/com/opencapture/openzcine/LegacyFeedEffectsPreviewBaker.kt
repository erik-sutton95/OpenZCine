@file:androidx.media3.common.util.UnstableApi

package com.opencapture.openzcine

import android.content.Context
import android.graphics.Bitmap
import android.opengl.EGL14
import android.opengl.EGLContext
import android.opengl.EGLDisplay
import android.opengl.EGLSurface
import android.opengl.GLES20
import android.opengl.GLUtils
import androidx.media3.common.util.GlUtil
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Offscreen GLES2 baker for Wear previews on Android 10 through Android 12L.
 *
 * The phone surface and this relay-owned context both use [FeedEffectsGlProgram],
 * so a watch never receives an ungraded frame while the legacy phone monitor
 * shows LUT, false-color, peaking, or zebra assists.
 */
internal class LegacyFeedEffectsPreviewBaker(
    context: Context,
    private val plan: FeedEffectsRenderPlan,
) : LiveFramePreviewBaker, AutoCloseable {
    private val applicationContext = context.applicationContext
    private val lock = Any()

    private var display: EGLDisplay = EGL14.EGL_NO_DISPLAY
    private var eglContext: EGLContext = EGL14.EGL_NO_CONTEXT
    private var surface: EGLSurface = EGL14.EGL_NO_SURFACE
    private var program: FeedEffectsGlProgram? = null
    private var inputTexture = 0
    private var inputWidth = 0
    private var inputHeight = 0
    private var outputTexture = 0
    private var framebuffer = 0
    private var outputWidth = 0
    private var outputHeight = 0
    private var closed = false

    override fun bakePreview(frame: Bitmap, maximumWidth: Int): Bitmap? =
        synchronized(lock) {
            if (closed || frame.isRecycled) return@synchronized null
            val width = minOf(frame.width, maximumWidth.coerceAtLeast(1)).coerceAtLeast(1)
            val height =
                (frame.height * width.toFloat() / frame.width)
                    .toInt()
                    .coerceAtLeast(1)
            try {
                ensureContext()
                makeCurrent()
                ensureOutput(width, height)
                uploadInput(frame)
                GlUtil.focusFramebuffer(
                    display,
                    eglContext,
                    surface,
                    framebuffer,
                    width,
                    height,
                )
                GLES20.glClearColor(0f, 0f, 0f, 1f)
                GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)
                requireNotNull(program).draw(
                    inputTexture,
                    frame.width.toFloat(),
                    frame.height.toFloat(),
                    width.toFloat(),
                    height.toFloat(),
                )
                GLES20.glFinish()
                readTopDownBitmap(width, height)
            } catch (_: Exception) {
                resetContext()
                null
            } catch (_: OutOfMemoryError) {
                resetContext()
                null
            } finally {
                releaseCurrent()
            }
        }

    override fun close() {
        synchronized(lock) {
            if (closed) return
            closed = true
            resetContext()
        }
    }

    private fun ensureContext() {
        if (eglContext != EGL14.EGL_NO_CONTEXT && program != null) return
        display = GlUtil.getDefaultEglDisplay()
        eglContext = GlUtil.createEglContext(display)
        surface = GlUtil.createFocusedPlaceholderEglSurface(eglContext, display)
        program =
            FeedEffectsGlProgram(
                applicationContext,
                plan,
                flipInputVertically = true,
            )
    }

    private fun ensureOutput(width: Int, height: Int) {
        if (outputWidth == width && outputHeight == height && framebuffer != 0) return
        if (framebuffer != 0) GlUtil.deleteFbo(framebuffer)
        if (outputTexture != 0) GlUtil.deleteTexture(outputTexture)
        outputTexture = GlUtil.createTexture(width, height, false)
        framebuffer = GlUtil.createFboForTexture(outputTexture)
        outputWidth = width
        outputHeight = height
    }

    private fun uploadInput(bitmap: Bitmap) {
        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        if (inputTexture == 0 || bitmap.width != inputWidth || bitmap.height != inputHeight) {
            if (inputTexture != 0) GlUtil.deleteTexture(inputTexture)
            inputTexture = GlUtil.createTexture(bitmap)
            inputWidth = bitmap.width
            inputHeight = bitmap.height
            return
        }
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, inputTexture)
        GLUtils.texSubImage2D(GLES20.GL_TEXTURE_2D, 0, 0, 0, bitmap)
        GlUtil.checkGlError()
    }

    private fun readTopDownBitmap(width: Int, height: Int): Bitmap {
        val rowBytes = width * 4
        val pixels =
            ByteBuffer.allocateDirect(rowBytes * height)
                .order(ByteOrder.nativeOrder())
        GLES20.glReadPixels(
            0,
            0,
            width,
            height,
            GLES20.GL_RGBA,
            GLES20.GL_UNSIGNED_BYTE,
            pixels,
        )
        GlUtil.checkGlError()
        pixels.position(0)
        val bottomUp = ByteArray(pixels.capacity())
        pixels.get(bottomUp)
        val topDown = ByteArray(bottomUp.size)
        for (row in 0 until height) {
            val source = (height - row - 1) * rowBytes
            bottomUp.copyInto(topDown, row * rowBytes, source, source + rowBytes)
        }
        return Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888).apply {
            copyPixelsFromBuffer(ByteBuffer.wrap(topDown))
        }
    }

    private fun makeCurrent() {
        check(EGL14.eglMakeCurrent(display, surface, surface, eglContext)) {
            "EGL could not focus the legacy Wear preview context"
        }
    }

    private fun releaseCurrent() {
        if (display == EGL14.EGL_NO_DISPLAY) return
        EGL14.eglMakeCurrent(
            display,
            EGL14.EGL_NO_SURFACE,
            EGL14.EGL_NO_SURFACE,
            EGL14.EGL_NO_CONTEXT,
        )
    }

    private fun resetContext() {
        if (display != EGL14.EGL_NO_DISPLAY && eglContext != EGL14.EGL_NO_CONTEXT) {
            runCatching {
                makeCurrent()
                program?.release()
                if (framebuffer != 0) GlUtil.deleteFbo(framebuffer)
                if (outputTexture != 0) GlUtil.deleteTexture(outputTexture)
                if (inputTexture != 0) GlUtil.deleteTexture(inputTexture)
            }
        }
        program = null
        inputTexture = 0
        inputWidth = 0
        inputHeight = 0
        outputTexture = 0
        framebuffer = 0
        outputWidth = 0
        outputHeight = 0
        releaseCurrent()
        if (surface != EGL14.EGL_NO_SURFACE) runCatching { GlUtil.destroyEglSurface(display, surface) }
        if (eglContext != EGL14.EGL_NO_CONTEXT) runCatching {
            GlUtil.destroyEglContext(display, eglContext)
        }
        if (display != EGL14.EGL_NO_DISPLAY) runCatching { GlUtil.terminate(display) }
        surface = EGL14.EGL_NO_SURFACE
        eglContext = EGL14.EGL_NO_CONTEXT
        display = EGL14.EGL_NO_DISPLAY
    }
}

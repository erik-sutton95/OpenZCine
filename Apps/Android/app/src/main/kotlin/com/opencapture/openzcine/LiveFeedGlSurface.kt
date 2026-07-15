@file:androidx.media3.common.util.UnstableApi

package com.opencapture.openzcine

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.ColorSpace
import android.opengl.GLES20
import android.opengl.GLSurfaceView
import android.opengl.GLUtils
import android.os.Build
import android.util.Log
import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import javax.microedition.khronos.egl.EGLConfig
import javax.microedition.khronos.opengles.GL10

private const val LEGACY_GL_TAG = "ZCLiveFeedGL"

/** Electrical color contract of one decoded monitor frame. */
internal enum class LiveFeedColorMode {
    UNKNOWN,
    SDR,
    HDR,
    UNSUPPORTED,
}

/** Pure color-mode decision used by the decoder seam and JVM tests. */
internal fun classifyLiveFeedColorMode(
    hasGainmap: Boolean,
    isSrgb: Boolean,
    usesHdrTransfer: Boolean,
    usesFloatingPointPixels: Boolean,
): LiveFeedColorMode =
    when {
        hasGainmap || usesHdrTransfer -> LiveFeedColorMode.HDR
        isSrgb && !usesFloatingPointPixels -> LiveFeedColorMode.SDR
        else -> LiveFeedColorMode.UNSUPPORTED
    }

/**
 * Classifies the decoded bitmap before any assist renderer can see it.
 *
 * Nikon's current MJPEG monitor path is requested as 8-bit sRGB. Ultra HDR,
 * HLG/PQ, floating-point, or unrecognised wide-gamut input fails closed to the
 * plain feed rather than silently feeding a different electrical space into
 * the monitor cubes.
 */
internal fun decodedLiveFeedColorMode(bitmap: Bitmap): LiveFeedColorMode {
    val colorSpace = bitmap.colorSpace
    val usesHdrTransfer =
        Build.VERSION.SDK_INT >= 34 &&
            (colorSpace == ColorSpace.get(ColorSpace.Named.BT2020_HLG) ||
                colorSpace == ColorSpace.get(ColorSpace.Named.BT2020_PQ))
    return classifyLiveFeedColorMode(
        hasGainmap = Build.VERSION.SDK_INT >= 34 && bitmap.hasGainmap(),
        isSrgb = colorSpace?.isSrgb == true,
        usesHdrTransfer = usesHdrTransfer,
        usesFloatingPointPixels = bitmap.config == Bitmap.Config.RGBA_F16,
    )
}

/** Feed effects are supported throughout the app's API 29+ platform floor. */
internal fun liveFeedEffectsPlatformAvailable(sdk: Int, swiftCoreAvailable: Boolean): Boolean =
    sdk >= 29 && swiftCoreAvailable

/** Per-frame gate: the current LUT/effect plan consumes original SDR values only. */
internal fun liveFeedEffectsCanRender(
    sdk: Int,
    swiftCoreAvailable: Boolean,
    colorMode: LiveFeedColorMode,
): Boolean =
    liveFeedEffectsPlatformAvailable(sdk, swiftCoreAvailable) && colorMode == LiveFeedColorMode.SDR

/** Exact OpenGL viewport corresponding to the Canvas feed destination. */
internal data class LiveFeedGlViewport(
    val x: Int,
    val y: Int,
    val width: Int,
    val height: Int,
)

/** Resolves Compose top-left geometry into OpenGL's bottom-left viewport coordinates. */
internal fun liveFeedGlViewport(
    surfaceWidth: Int,
    surfaceHeight: Int,
    sourceWidth: Int,
    sourceHeight: Int,
    aspectFill: Boolean,
): LiveFeedGlViewport? {
    val content =
        liveFeedContentRect(
            containerWidth = surfaceWidth.toFloat(),
            containerHeight = surfaceHeight.toFloat(),
            sourceWidth = sourceWidth,
            sourceHeight = sourceHeight,
            aspectFill = aspectFill,
        ) ?: return null
    return LiveFeedGlViewport(
        x = content.left,
        y = surfaceHeight - content.top - content.height,
        width = content.width,
        height = content.height,
    )
}

/** One pool-owned bitmap that remains immutable until the GL upload releases it. */
internal class LegacyLiveFeedFrameLease(
    val bitmap: Bitmap,
    private val releaseSlot: () -> Unit,
) {
    private val released = AtomicBoolean(false)

    fun release() {
        if (released.compareAndSet(false, true)) releaseSlot()
    }
}

/** Bounded copy pool preventing decoder reuse from racing the legacy GL thread. */
internal class LegacyLiveFeedFramePool(size: Int = 3) {
    private val slots = List(size) { Slot() }
    private var closed = false

    @Synchronized
    fun copy(frame: Bitmap): LegacyLiveFeedFrameLease? {
        if (closed) return null
        val slot = slots.firstOrNull { !it.leased } ?: return null
        slot.leased = true
        return try {
            val target = slot.targetFor(frame)
            checkNotNull(slot.canvas) { "legacy frame-pool slot has no canvas" }
                .drawBitmap(frame, 0f, 0f, null)
            LegacyLiveFeedFrameLease(target) { release(slot) }
        } catch (_: RuntimeException) {
            slot.leased = false
            null
        } catch (_: OutOfMemoryError) {
            slot.leased = false
            null
        }
    }

    @Synchronized
    fun close() {
        closed = true
        slots.filterNot(Slot::leased).forEach(Slot::recycle)
    }

    @Synchronized
    private fun release(slot: Slot) {
        slot.leased = false
        if (closed) slot.recycle()
    }

    private class Slot {
        var bitmap: Bitmap? = null
        var canvas: Canvas? = null
        var leased = false

        fun targetFor(source: Bitmap): Bitmap {
            val current = bitmap
            if (current != null &&
                canvas != null &&
                !current.isRecycled &&
                current.width == source.width &&
                current.height == source.height &&
                current.colorSpace == source.colorSpace
            ) {
                return current
            }
            recycle()
            val colorSpace = checkNotNull(source.colorSpace) { "SDR live frame has no color space" }
            val created =
                Bitmap.createBitmap(
                    source.width,
                    source.height,
                    Bitmap.Config.ARGB_8888,
                    source.hasAlpha(),
                    colorSpace,
                )
            return try {
                val createdCanvas = Canvas(created)
                created.density = source.density
                bitmap = created
                canvas = createdCanvas
                created
            } catch (error: RuntimeException) {
                created.recycle()
                throw error
            } catch (error: OutOfMemoryError) {
                created.recycle()
                throw error
            }
        }

        fun recycle() {
            canvas?.setBitmap(null)
            canvas = null
            bitmap?.takeUnless(Bitmap::isRecycled)?.recycle()
            bitmap = null
        }
    }
}

/**
 * Compose-owned handoff that keeps frame delivery draw-only. Updating a frame
 * never writes Compose state or rebuilds the AndroidView; only a plan failure
 * crosses back to composition so the plain Canvas path can recover.
 */
@Stable
internal class LegacyLiveFeedSurfaceState {
    private val framePool = LegacyLiveFeedFramePool()
    private val pendingFrame = AtomicReference<LegacyLiveFeedFrameLease?>(null)
    private val surface = AtomicReference<LegacyLiveFeedGlSurface?>(null)
    private val disposed = AtomicBoolean(false)
    private var plan: FeedEffectsRenderPlan? = null
    private var aspectFill: Boolean = false
    private val lifecycleResumed = AtomicBoolean(false)

    var renderFailed: Boolean by mutableStateOf(false)
        private set

    fun submit(frame: Bitmap) {
        if (!acceptingFrames()) return
        val lease = framePool.copy(frame) ?: return
        if (!acceptingFrames()) {
            lease.release()
            return
        }
        pendingFrame.getAndSet(lease)?.release()
        if (!acceptingFrames()) {
            pendingFrame.compareAndSet(lease, null)
            lease.release()
            return
        }
        surface.get()?.let(::drainFrameTo)
    }

    fun update(plan: FeedEffectsRenderPlan, aspectFill: Boolean) {
        if (disposed.get()) return
        if (this.plan !== plan) renderFailed = false
        this.plan = plan
        this.aspectFill = aspectFill
        surface.get()?.update(plan, aspectFill)
    }

    fun attach(next: LegacyLiveFeedGlSurface) {
        if (disposed.get()) {
            next.closeForFrameSubmission()
            return
        }
        if (!lifecycleResumed.get()) next.onPause()
        surface.getAndSet(next)?.takeIf { it !== next }?.closeForFrameSubmission()
        if (disposed.get()) {
            surface.compareAndSet(next, null)
            next.closeForFrameSubmission()
            return
        }
        next.onRenderFailure = { failedPlan, error ->
            next.post {
                if (recordRenderFailure(failedPlan)) {
                    Log.e(LEGACY_GL_TAG, "legacy live assist renderer failed closed", error)
                }
            }
        }
        val currentPlan = plan
        if (currentPlan != null) next.update(currentPlan, aspectFill)
        if (lifecycleResumed.get()) {
            next.onResume()
            drainFrameTo(next)
        }
    }

    fun detach(view: LegacyLiveFeedGlSurface) {
        view.closeForFrameSubmission()
        surface.compareAndSet(view, null)
        view.onRenderFailure = null
    }

    fun clear() {
        pendingFrame.getAndSet(null)?.release()
        surface.get()?.clearFrame()
    }

    fun resume() {
        if (!lifecycleResumed.compareAndSet(false, true)) return
        surface.get()?.onResume()
    }

    fun pause() {
        if (!lifecycleResumed.compareAndSet(true, false)) return
        clear()
        surface.get()?.onPause()
    }

    fun dispose() {
        if (!disposed.compareAndSet(false, true)) return
        surface.getAndSet(null)?.let { view ->
            view.onRenderFailure = null
            view.closeForFrameSubmission()
        }
        pendingFrame.getAndSet(null)?.release()
        framePool.close()
    }

    internal fun recordRenderFailure(failedPlan: FeedEffectsRenderPlan): Boolean {
        if (plan !== failedPlan) return false
        renderFailed = true
        return true
    }

    private fun drainFrameTo(target: LegacyLiveFeedGlSurface) {
        if (!acceptingFrames() || surface.get() !== target) return
        pendingFrame.getAndSet(null)?.let(target::submit)
    }

    private fun acceptingFrames(): Boolean = !disposed.get() && lifecycleResumed.get()
}

/** API 29-32 one-pass GLES surface for the live JPEG monitor. */
internal class LegacyLiveFeedGlSurface(context: Context) : GLSurfaceView(context) {
    private val feedRenderer = LegacyLiveFeedGlRenderer(context.applicationContext)

    var onRenderFailure: ((FeedEffectsRenderPlan, Throwable) -> Unit)? = null

    init {
        setEGLContextClientVersion(2)
        preserveEGLContextOnPause = true
        setRenderer(feedRenderer)
        renderMode = RENDERMODE_WHEN_DIRTY
        feedRenderer.onFailure = { plan, error -> onRenderFailure?.invoke(plan, error) }
    }

    fun submit(frame: LegacyLiveFeedFrameLease) {
        if (feedRenderer.submit(frame)) requestRender()
    }

    fun closeForFrameSubmission() {
        feedRenderer.closeForFrameSubmission()
    }

    fun clearFrame() {
        feedRenderer.clearFrame()
        requestRender()
    }

    fun update(plan: FeedEffectsRenderPlan, aspectFill: Boolean) {
        feedRenderer.plan.set(plan)
        feedRenderer.aspectFill = aspectFill
        requestRender()
    }

    override fun onDetachedFromWindow() {
        closeForFrameSubmission()
        queueEvent(feedRenderer::release)
        super.onDetachedFromWindow()
    }
}

private class LegacyLiveFeedGlRenderer(
    private val context: Context,
) : GLSurfaceView.Renderer {
    private val frame = AtomicReference<LegacyLiveFeedFrameLease?>(null)
    private val clearRequested = AtomicBoolean(false)
    private val acceptingFrames = AtomicBoolean(true)
    val plan = AtomicReference<FeedEffectsRenderPlan?>(null)

    @Volatile var aspectFill: Boolean = false
    var onFailure: ((FeedEffectsRenderPlan, Throwable) -> Unit)? = null

    private var surfaceWidth = 0
    private var surfaceHeight = 0
    private var inputTexture = 0
    private var inputWidth = 0
    private var inputHeight = 0
    private var activePlan: FeedEffectsRenderPlan? = null
    private var program: FeedEffectsGlProgram? = null

    override fun onSurfaceCreated(gl: GL10?, config: EGLConfig?) {
        // Every context owns a fresh texture/program namespace. References to
        // an evicted context must never be deleted through the new one.
        inputTexture = 0
        inputWidth = 0
        inputHeight = 0
        activePlan = null
        program = null
        GLES20.glClearColor(0f, 0f, 0f, 1f)
    }

    override fun onSurfaceChanged(gl: GL10?, width: Int, height: Int) {
        surfaceWidth = width.coerceAtLeast(0)
        surfaceHeight = height.coerceAtLeast(0)
        GLES20.glViewport(0, 0, surfaceWidth, surfaceHeight)
    }

    override fun onDrawFrame(gl: GL10?) {
        GLES20.glViewport(0, 0, surfaceWidth, surfaceHeight)
        GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)
        if (clearRequested.getAndSet(false)) {
            inputWidth = 0
            inputHeight = 0
        }
        val nextPlan = plan.get() ?: return
        if (surfaceWidth <= 0 || surfaceHeight <= 0) return
        val nextFrame = frame.getAndSet(null)
        try {
            ensureProgram(nextPlan)
            if (nextFrame != null) uploadFrame(nextFrame.bitmap)
            if (inputTexture == 0 || inputWidth <= 0 || inputHeight <= 0) return
            val viewport =
                liveFeedGlViewport(
                    surfaceWidth = surfaceWidth,
                    surfaceHeight = surfaceHeight,
                    sourceWidth = inputWidth,
                    sourceHeight = inputHeight,
                    aspectFill = aspectFill,
                ) ?: return
            GLES20.glViewport(viewport.x, viewport.y, viewport.width, viewport.height)
            requireNotNull(program).draw(
                inputTexture,
                inputWidth.toFloat(),
                inputHeight.toFloat(),
                viewport.width.toFloat(),
                viewport.height.toFloat(),
            )
            GLES20.glViewport(0, 0, surfaceWidth, surfaceHeight)
        } catch (error: Exception) {
            release()
            GLES20.glViewport(0, 0, surfaceWidth, surfaceHeight)
            GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)
            onFailure?.invoke(nextPlan, error)
        } finally {
            nextFrame?.release()
        }
    }

    fun submit(next: LegacyLiveFeedFrameLease): Boolean {
        if (!acceptingFrames.get()) {
            next.release()
            return false
        }
        frame.getAndSet(next)?.release()
        if (!acceptingFrames.get()) {
            frame.compareAndSet(next, null)
            next.release()
            return false
        }
        return true
    }

    fun closeForFrameSubmission() {
        acceptingFrames.set(false)
        frame.getAndSet(null)?.release()
    }

    fun clearFrame() {
        frame.getAndSet(null)?.release()
        clearRequested.set(true)
    }

    fun release() {
        closeForFrameSubmission()
        runCatching { program?.release() }
        program = null
        activePlan = null
        if (inputTexture != 0) {
            GLES20.glDeleteTextures(1, intArrayOf(inputTexture), 0)
            inputTexture = 0
        }
        inputWidth = 0
        inputHeight = 0
    }

    private fun ensureProgram(nextPlan: FeedEffectsRenderPlan) {
        if (activePlan === nextPlan && program != null) return
        program?.release()
        // GLUtils uploads Android bitmap row zero at texture v=0. Unlike a
        // Media3 input texture, the raw live bitmap therefore needs a source
        // sampling flip to remain upright in the display viewport.
        program = FeedEffectsGlProgram(context, nextPlan, flipInputVertically = true)
        activePlan = nextPlan
    }

    private fun uploadFrame(bitmap: Bitmap) {
        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        if (inputTexture == 0) {
            val textures = IntArray(1)
            GLES20.glGenTextures(1, textures, 0)
            inputTexture = textures[0]
            check(inputTexture != 0) { "OpenGL did not allocate the live input texture" }
            GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, inputTexture)
            GLES20.glTexParameteri(
                GLES20.GL_TEXTURE_2D,
                GLES20.GL_TEXTURE_MIN_FILTER,
                GLES20.GL_LINEAR,
            )
            GLES20.glTexParameteri(
                GLES20.GL_TEXTURE_2D,
                GLES20.GL_TEXTURE_MAG_FILTER,
                GLES20.GL_LINEAR,
            )
            GLES20.glTexParameteri(
                GLES20.GL_TEXTURE_2D,
                GLES20.GL_TEXTURE_WRAP_S,
                GLES20.GL_CLAMP_TO_EDGE,
            )
            GLES20.glTexParameteri(
                GLES20.GL_TEXTURE_2D,
                GLES20.GL_TEXTURE_WRAP_T,
                GLES20.GL_CLAMP_TO_EDGE,
            )
        } else {
            GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, inputTexture)
        }
        GLES20.glPixelStorei(GLES20.GL_UNPACK_ALIGNMENT, 1)
        if (bitmap.width != inputWidth || bitmap.height != inputHeight) {
            GLUtils.texImage2D(GLES20.GL_TEXTURE_2D, 0, bitmap, 0)
            inputWidth = bitmap.width
            inputHeight = bitmap.height
        } else {
            GLUtils.texSubImage2D(GLES20.GL_TEXTURE_2D, 0, 0, 0, bitmap)
        }
    }
}

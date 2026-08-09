@file:androidx.media3.common.util.UnstableApi

package com.opencapture.openzcine

import android.content.Context
import android.graphics.Bitmap
import android.opengl.GLES20
import androidx.media3.common.util.GlProgram
import androidx.media3.common.util.GlUtil
import java.nio.ByteBuffer

private const val FEED_EFFECTS_VERTEX_SHADER = "shaders/playback_feed_vertex_es2.glsl"
private const val FEED_EFFECTS_FRAGMENT_SHADER = "shaders/playback_feed_fragment_es2.glsl"
private const val PEAKING_BLUR_FRAGMENT_SHADER = "shaders/peaking_blur_fragment_es2.glsl"
private const val PEAKING_MASK_FRAGMENT_SHADER = "shaders/peaking_mask_fragment_es2.glsl"

/**
 * Shared GLES2 adapter for the immutable Swift-owned feed-effects plan.
 *
 * Media3 playback and the API 29-32 live JPEG surface both call this class, so
 * LUT, false-color, peaking, and zebra uniforms cannot drift between the two
 * Android render paths. Callers own the input texture, output framebuffer,
 * viewport, and GL thread.
 *
 * Peaking is three passes, and all of them live in here rather than at the three call
 * sites: pass 1 takes the vertical half of the separable re-blur, pass 2 folds the
 * horizontal half and writes the finished detector mask (both at SOURCE resolution), and
 * pass 3 closes that mask and composites. [draw] saves and restores the caller's
 * framebuffer and viewport around the offscreen passes, so the contract above is
 * unchanged — callers still own the output framebuffer and never learn the mask exists.
 *
 * Splitting the re-blur is what makes the feature affordable: 20 taps per source pixel
 * against 68 for the fused form, for an identical result. See
 * `peaking_blur_fragment_es2.glsl` for the algebra and the measurement.
 */
internal class FeedEffectsGlProgram(
    context: Context,
    plan: FeedEffectsRenderPlan,
    flipInputVertically: Boolean = false,
) {
    private val program = GlProgram(context, FEED_EFFECTS_VERTEX_SHADER, FEED_EFFECTS_FRAGMENT_SHADER)
    private val baseCube = uploadCube(plan.baseCube)
    private val limitsPaintCube = uploadCube(plan.limitsPaintCube)
    private val limitsWeightCube = uploadCube(plan.limitsWeightCube)

    /** Passes 1 and 2, built only when peaking is on — they are the cost of the feature. */
    private val blurProgram =
        if (plan.effects.peaking) {
            GlProgram(context, FEED_EFFECTS_VERTEX_SHADER, PEAKING_BLUR_FRAGMENT_SHADER)
        } else {
            null
        }
    private val maskProgram =
        if (plan.effects.peaking) {
            GlProgram(context, FEED_EFFECTS_VERTEX_SHADER, PEAKING_MASK_FRAGMENT_SHADER)
        } else {
            null
        }
    private var blurTarget: PeakingMaskTarget? = null
    private var maskTarget: PeakingMaskTarget? = null

    /**
     * Bound to `uPeakingMask` whenever pass 1 did not run. An unbound GLES sampler reads
     * undefined data, so peaking-off still has to hand the composite a real texture; a 1x1
     * transparent one reads as "no stroke, no hairline" in both channels.
     */
    private var maskStubTexture = 0

    init {
        program.setBufferAttribute(
            "aFramePosition",
            GlUtil.getNormalizedCoordinateBounds(),
            GlUtil.HOMOGENEOUS_COORDINATE_VECTOR_SIZE,
        )
        program.setFloatsUniform("uFlipInputY", flag(flipInputVertically))
        bindStaticUniforms(plan)
        blurProgram?.let { blur ->
            blur.setBufferAttribute(
                "aFramePosition",
                GlUtil.getNormalizedCoordinateBounds(),
                GlUtil.HOMOGENEOUS_COORDINATE_VECTOR_SIZE,
            )
            blur.setFloatsUniform("uFlipInputY", flag(flipInputVertically))
        }
        maskProgram?.let { mask ->
            mask.setBufferAttribute(
                "aFramePosition",
                GlUtil.getNormalizedCoordinateBounds(),
                GlUtil.HOMOGENEOUS_COORDINATE_VECTOR_SIZE,
            )
            mask.setFloatsUniform("uFlipInputY", flag(flipInputVertically))
            mask.setFloatsUniform(
                "uPeakingRatioThreshold",
                floatArrayOf(plan.configuration.peakingRatioThreshold),
            )
            mask.setFloatsUniform(
                "uPeakingNoiseGate",
                floatArrayOf(plan.configuration.peakingNoiseGate),
            )
        }
    }

    /** Draws one source texture through the shared assist plan. */
    fun draw(
        inputTexture: Int,
        sourceWidth: Float,
        sourceHeight: Float,
        displayWidth: Float,
        displayHeight: Float,
        /**
         * Horizontal flip for a camera pointed back at the operator. Per-draw rather than a
         * constructor flag like [flipInputVertically]: this one is an operator switch that has to
         * take effect on the next frame, not a property of the pipeline.
         */
        mirrored: Boolean = false,
    ) {
        val mask = renderPeakingMask(inputTexture, sourceWidth, sourceHeight)
        program.use()
        program.setSamplerTexIdUniform("uTexSampler", inputTexture, 0)
        program.setSamplerTexIdUniform("uPeakingMask", mask, 4)
        program.setSamplerTexIdUniform("uLut", baseCube.textureId, 1)
        program.setSamplerTexIdUniform("uLimitsPaintCube", limitsPaintCube.textureId, 2)
        program.setSamplerTexIdUniform("uLimitsWeightCube", limitsWeightCube.textureId, 3)
        program.setFloatsUniform(
            "uSourceSize",
            floatArrayOf(sourceWidth.coerceAtLeast(1f), sourceHeight.coerceAtLeast(1f)),
        )
        program.setFloatsUniform(
            "uDisplaySize",
            floatArrayOf(displayWidth.coerceAtLeast(1f), displayHeight.coerceAtLeast(1f)),
        )
        program.setFloatsUniform("uMirror", flag(mirrored))
        program.bindAttributesAndUniforms()
        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
        GlUtil.checkGlError()
    }

    /**
     * Runs the two offscreen detector passes and returns the finished mask texture,
     * restoring the caller's framebuffer and viewport before it returns. Returns the stub
     * when peaking is off, so the composite always has a bound sampler.
     */
    private fun renderPeakingMask(
        inputTexture: Int,
        sourceWidth: Float,
        sourceHeight: Float,
    ): Int {
        val blur = blurProgram ?: return maskStub()
        val mask = maskProgram ?: return maskStub()
        val width = sourceWidth.toInt().coerceAtLeast(1)
        val height = sourceHeight.toInt().coerceAtLeast(1)
        val sourceSize = floatArrayOf(width.toFloat(), height.toFloat())

        // The caller owns the output framebuffer and viewport; borrow and hand them back.
        //
        // READ BEFORE ALLOCATING, always. Creating a target has to bind its own framebuffer to
        // attach the texture, and does not put the previous binding back — so asking for the
        // targets first captures the freshly made FBO as "previous" and the composite then
        // renders into the mask instead of onto the screen. That is a black feed under live
        // chrome on every frame that allocates, alternating with good frames once the targets
        // cache: the flicker, and the feed that never updates.
        val previousFramebuffer = IntArray(1)
        GLES20.glGetIntegerv(GLES20.GL_FRAMEBUFFER_BINDING, previousFramebuffer, 0)
        val previousViewport = IntArray(4)
        GLES20.glGetIntegerv(GLES20.GL_VIEWPORT, previousViewport, 0)

        val blurPass = peakingBlurTarget(width, height)
        val maskPass = peakingMaskTarget(width, height)

        // Pass 1 — the vertical half of the re-blur, both of the quad's rows per texel.
        GlUtil.focusFramebufferUsingCurrentContext(blurPass.framebufferId, width, height)
        blur.use()
        blur.setSamplerTexIdUniform("uTexSampler", inputTexture, 0)
        blur.setFloatsUniform("uSourceSize", sourceSize)
        blur.bindAttributesAndUniforms()
        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
        GlUtil.checkGlError()

        // Pass 2 — the horizontal fold, the operator and the ramps. Still needs the source
        // itself: the fine gradient is measured on raw pixels, never on the re-blur.
        GlUtil.focusFramebufferUsingCurrentContext(maskPass.framebufferId, width, height)
        mask.use()
        mask.setSamplerTexIdUniform("uTexSampler", inputTexture, 0)
        mask.setSamplerTexIdUniform("uPeakingBlur", blurPass.textureId, 1)
        mask.setFloatsUniform("uSourceSize", sourceSize)
        mask.bindAttributesAndUniforms()
        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
        GlUtil.checkGlError()

        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, previousFramebuffer[0])
        GLES20.glViewport(
            previousViewport[0],
            previousViewport[1],
            previousViewport[2],
            previousViewport[3],
        )
        return maskPass.textureId
    }

    private fun maskStub(): Int {
        if (maskStubTexture == 0) maskStubTexture = uploadStubTexture()
        return maskStubTexture
    }

    /** The mask is source-sized, so a feed resolution change rebuilds it. */
    private fun peakingMaskTarget(width: Int, height: Int): PeakingMaskTarget {
        maskTarget?.let { existing ->
            if (existing.width == width && existing.height == height) return existing
            existing.release()
            maskTarget = null
        }
        return createSourceSizedTarget(width, height).also { maskTarget = it }
    }

    /** Same size and format as the mask: it holds the vertical re-blur, 16 bits per row. */
    private fun peakingBlurTarget(width: Int, height: Int): PeakingMaskTarget {
        blurTarget?.let { existing ->
            if (existing.width == width && existing.height == height) return existing
            existing.release()
            blurTarget = null
        }
        return createSourceSizedTarget(width, height).also { blurTarget = it }
    }

    /**
     * RGBA8, deliberately: the blur pass packs each value across two channels to get 16
     * bits, because a half-float target throws on an ES2 context and that throw tears down
     * the live GPU surface. See `peaking_blur_fragment_es2.glsl`.
     */
    private fun createSourceSizedTarget(width: Int, height: Int): PeakingMaskTarget {
        val textureId = GlUtil.createTexture(width, height, /* useHighPrecisionColorComponents= */ false)
        val framebufferId = GlUtil.createFboForTexture(textureId)
        return PeakingMaskTarget(textureId, framebufferId, width, height)
    }

    /** Releases only textures and program state owned by this adapter. */
    fun release() {
        program.delete()
        blurProgram?.delete()
        maskProgram?.delete()
        blurTarget?.release()
        blurTarget = null
        maskTarget?.release()
        maskTarget = null
        if (maskStubTexture != 0) {
            GlUtil.deleteTexture(maskStubTexture)
            maskStubTexture = 0
        }
        GlUtil.deleteTexture(baseCube.textureId)
        GlUtil.deleteTexture(limitsPaintCube.textureId)
        GlUtil.deleteTexture(limitsWeightCube.textureId)
    }

    private fun bindStaticUniforms(plan: FeedEffectsRenderPlan) {
        val configuration = plan.configuration
        program.setFloatsUniform("uLutSize", floatArrayOf(baseCube.cubeSize.toFloat()))
        // Both are always set, even off: `setFloatsUniform` throws on a uniform GLSL dead-stripped
        // for being unreferenced, and on the live path that throw drops the whole GPU surface.
        program.setFloatsUniform("uSplitOn", flag(plan.splitComparison != null))
        program.setFloatsUniform(
            "uSplitVertical",
            flag(plan.splitComparison == FeedSplitOrientation.VERTICAL),
        )
        program.setFloatsUniform(
            "uLimitsPaintSize",
            floatArrayOf(limitsPaintCube.cubeSize.toFloat()),
        )
        program.setFloatsUniform(
            "uLimitsWeightSize",
            floatArrayOf(limitsWeightCube.cubeSize.toFloat()),
        )
        program.setFloatsUniform("uLimitsOn", flag(plan.limitsReady))
        // The detector's thresholds belong to pass 1 and are bound on `maskProgram`; the
        // composite only needs to know whether to paint and in what colour.
        program.setFloatsUniform("uPeakingOn", flag(plan.effects.peaking))
        program.setFloatsUniform("uPeakingColor", configuration.peakingColor)
        program.setFloatsUniform(
            "uZebraHighlightOn",
            flag(plan.effects.zebra && configuration.highlightEnabled),
        )
        program.setFloatsUniform(
            "uZebraHighlight",
            floatArrayOf(configuration.highlightCode),
        )
        program.setFloatsUniform("uZebraHighlightColor", configuration.highlightColor)
        program.setFloatsUniform(
            "uZebraMidtoneOn",
            flag(plan.effects.zebra && configuration.midtoneEnabled),
        )
        program.setFloatsUniform("uZebraMidtone", floatArrayOf(configuration.midtoneCode))
        program.setFloatsUniform("uZebraMidtoneColor", configuration.midtoneColor)
    }

    private fun uploadCube(cube: FeedEffectsCube?): UploadedFeedEffectsCube {
        if (cube == null) {
            val stub = Bitmap.createBitmap(1, 1, Bitmap.Config.ARGB_8888)
            return UploadedFeedEffectsCube(upload(stub), 0)
        }
        val atlas = feedEffectsCubeAtlas(cube)
        val bitmap = Bitmap.createBitmap(atlas.width, atlas.height, Bitmap.Config.ARGB_8888)
        bitmap.copyPixelsFromBuffer(ByteBuffer.wrap(atlas.rgba))
        return UploadedFeedEffectsCube(upload(bitmap), atlas.cubeSize)
    }

    private fun uploadStubTexture(): Int {
        val stub = Bitmap.createBitmap(1, 1, Bitmap.Config.ARGB_8888)
        return upload(stub)
    }

    private fun upload(bitmap: Bitmap): Int =
        try {
            GlUtil.createTexture(bitmap)
        } finally {
            bitmap.recycle()
        }

    private fun flag(enabled: Boolean): FloatArray = floatArrayOf(if (enabled) 1f else 0f)
}

private data class UploadedFeedEffectsCube(
    val textureId: Int,
    val cubeSize: Int,
)

/** Offscreen colour target for the peaking mask: R = stroke opacity, G = the hairline's. */
private data class PeakingMaskTarget(
    val textureId: Int,
    val framebufferId: Int,
    val width: Int,
    val height: Int,
) {
    fun release() {
        GlUtil.deleteFbo(framebufferId)
        GlUtil.deleteTexture(textureId)
    }
}

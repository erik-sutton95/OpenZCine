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
private const val PEAKING_MASK_FRAGMENT_SHADER = "shaders/peaking_mask_fragment_es2.glsl"

/**
 * Shared GLES2 adapter for the immutable Swift-owned feed-effects plan.
 *
 * Media3 playback and the API 29-32 live JPEG surface both call this class, so
 * LUT, false-color, peaking, and zebra uniforms cannot drift between the two
 * Android render paths. Callers own the input texture, output framebuffer,
 * viewport, and GL thread.
 *
 * Peaking is two passes, and both live in here rather than at the three call sites:
 * pass 1 renders the detector into an offscreen mask at SOURCE resolution, pass 2
 * closes that mask and composites. [draw] saves and restores the caller's framebuffer
 * and viewport around pass 1, so the contract above is unchanged — callers still own
 * the output framebuffer and never learn the mask exists. See
 * `peaking_mask_fragment_es2.glsl` for why the detector cannot stay inline.
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

    /** Pass 1, built only when peaking is on — it is the whole cost of the feature. */
    private val maskProgram =
        if (plan.effects.peaking) {
            GlProgram(context, FEED_EFFECTS_VERTEX_SHADER, PEAKING_MASK_FRAGMENT_SHADER)
        } else {
            null
        }
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
        program.bindAttributesAndUniforms()
        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
        GlUtil.checkGlError()
    }

    /**
     * Renders the detector into the offscreen mask and returns its texture, restoring the
     * caller's framebuffer and viewport before it returns. Returns the stub when peaking is
     * off, so the composite always has a bound sampler.
     */
    private fun renderPeakingMask(
        inputTexture: Int,
        sourceWidth: Float,
        sourceHeight: Float,
    ): Int {
        val mask = maskProgram ?: return maskStub()
        val width = sourceWidth.toInt().coerceAtLeast(1)
        val height = sourceHeight.toInt().coerceAtLeast(1)
        val target = peakingMaskTarget(width, height)

        // The caller owns the output framebuffer and viewport; borrow and hand them back.
        val previousFramebuffer = IntArray(1)
        GLES20.glGetIntegerv(GLES20.GL_FRAMEBUFFER_BINDING, previousFramebuffer, 0)
        val previousViewport = IntArray(4)
        GLES20.glGetIntegerv(GLES20.GL_VIEWPORT, previousViewport, 0)

        GlUtil.focusFramebufferUsingCurrentContext(target.framebufferId, width, height)
        mask.use()
        mask.setSamplerTexIdUniform("uTexSampler", inputTexture, 0)
        mask.setFloatsUniform("uSourceSize", floatArrayOf(width.toFloat(), height.toFloat()))
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
        return target.textureId
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
        val textureId = GlUtil.createTexture(width, height, /* useHighPrecisionColorComponents= */ false)
        val framebufferId = GlUtil.createFboForTexture(textureId)
        return PeakingMaskTarget(textureId, framebufferId, width, height).also { maskTarget = it }
    }

    /** Releases only textures and program state owned by this adapter. */
    fun release() {
        program.delete()
        maskProgram?.delete()
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

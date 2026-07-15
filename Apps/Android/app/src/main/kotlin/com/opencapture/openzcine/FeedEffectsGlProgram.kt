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

/**
 * Shared GLES2 adapter for the immutable Swift-owned feed-effects plan.
 *
 * Media3 playback and the API 29-32 live JPEG surface both call this class, so
 * LUT, false-color, peaking, and zebra uniforms cannot drift between the two
 * Android render paths. Callers own the input texture, output framebuffer,
 * viewport, and GL thread.
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

    init {
        program.setBufferAttribute(
            "aFramePosition",
            GlUtil.getNormalizedCoordinateBounds(),
            GlUtil.HOMOGENEOUS_COORDINATE_VECTOR_SIZE,
        )
        program.setFloatsUniform("uFlipInputY", flag(flipInputVertically))
        bindStaticUniforms(plan)
    }

    /** Draws one source texture through the shared assist plan. */
    fun draw(
        inputTexture: Int,
        sourceWidth: Float,
        sourceHeight: Float,
        displayWidth: Float,
        displayHeight: Float,
    ) {
        program.use()
        program.setSamplerTexIdUniform("uTexSampler", inputTexture, 0)
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

    /** Releases only textures and program state owned by this adapter. */
    fun release() {
        program.delete()
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
        program.setFloatsUniform(
            "uDeLogCurve0To3",
            configuration.deLogCurve.copyOfRange(0, 4),
        )
        program.setFloatsUniform("uDeLogCurve4", floatArrayOf(configuration.deLogCurve[4]))
        program.setFloatsUniform("uPeakingOn", flag(plan.effects.peaking))
        program.setFloatsUniform("uPeakingColor", configuration.peakingColor)
        program.setFloatsUniform(
            "uPeakingThreshold",
            floatArrayOf(configuration.peakingThreshold),
        )
        program.setFloatsUniform("uPeakingRamp", floatArrayOf(configuration.peakingRamp))
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

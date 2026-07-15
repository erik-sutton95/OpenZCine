@file:androidx.media3.common.util.UnstableApi

package com.opencapture.openzcine.media

import android.content.Context
import android.graphics.Bitmap
import android.opengl.GLES20
import androidx.media3.common.VideoFrameProcessingException
import androidx.media3.common.util.GlProgram
import androidx.media3.common.util.GlUtil
import androidx.media3.common.util.Size
import androidx.media3.effect.BaseGlShaderProgram
import androidx.media3.effect.GlEffect
import androidx.media3.effect.GlShaderProgram
import com.opencapture.openzcine.FeedEffectsCube
import com.opencapture.openzcine.FeedEffectsRenderPlan
import com.opencapture.openzcine.feedEffectsCubeAtlas
import java.io.IOException
import java.nio.ByteBuffer
import kotlin.math.max

private const val VERTEX_SHADER_PATH = "shaders/playback_feed_vertex_es2.glsl"
private const val FRAGMENT_SHADER_PATH = "shaders/playback_feed_fragment_es2.glsl"

/** Display-pixel extent used to keep peaking and zebra geometry independent of decode resolution. */
internal class PlaybackEffectDisplaySize {
    @Volatile private var extent = DisplayExtent(0f, 0f)

    fun update(width: Float, height: Float) {
        extent =
            if (width.isFinite() && height.isFinite() && width > 0f && height > 0f) {
                DisplayExtent(width, height)
            } else {
                DisplayExtent(0f, 0f)
            }
    }

    fun resolve(inputWidth: Int, inputHeight: Int): DisplayExtent {
        val current = extent
        return if (current.width > 0f && current.height > 0f) {
            current
        } else {
            DisplayExtent(max(1, inputWidth).toFloat(), max(1, inputHeight).toFloat())
        }
    }
}

internal data class DisplayExtent(val width: Float, val height: Float)

/** Media3 playback effect that applies the shared feed-assist plan on API 29–32. */
internal class PlaybackFeedEffect(
    private val plan: FeedEffectsRenderPlan,
    private val displaySize: PlaybackEffectDisplaySize,
) : GlEffect {
    override fun toGlShaderProgram(context: Context, useHdr: Boolean): GlShaderProgram {
        if (useHdr) {
            throw VideoFrameProcessingException(
                "Playback image assists support SDR proxy frames only",
            )
        }
        return PlaybackFeedShaderProgram(context, plan, displaySize)
    }
}

/** One-pass GLES2 renderer preserving the AGSL source/base-look/peaking/zebra operation order. */
private class PlaybackFeedShaderProgram(
    context: Context,
    private val plan: FeedEffectsRenderPlan,
    private val displaySize: PlaybackEffectDisplaySize,
) : BaseGlShaderProgram(false, 1) {
    private val glProgram = createProgram(context)
    private val baseCube = uploadCube(plan.baseCube)
    private val limitsPaintCube = uploadCube(plan.limitsPaintCube)
    private val limitsWeightCube = uploadCube(plan.limitsWeightCube)
    private var inputWidth = 1
    private var inputHeight = 1

    init {
        glProgram.setBufferAttribute(
            "aFramePosition",
            GlUtil.getNormalizedCoordinateBounds(),
            GlUtil.HOMOGENEOUS_COORDINATE_VECTOR_SIZE,
        )
        bindStaticUniforms()
    }

    override fun configure(inputWidth: Int, inputHeight: Int): Size {
        this.inputWidth = max(1, inputWidth)
        this.inputHeight = max(1, inputHeight)
        return Size(this.inputWidth, this.inputHeight)
    }

    override fun drawFrame(inputTexId: Int, presentationTimeUs: Long) {
        try {
            glProgram.use()
            glProgram.setSamplerTexIdUniform("uTexSampler", inputTexId, 0)
            glProgram.setSamplerTexIdUniform("uLut", baseCube.textureId, 1)
            glProgram.setSamplerTexIdUniform("uLimitsPaintCube", limitsPaintCube.textureId, 2)
            glProgram.setSamplerTexIdUniform("uLimitsWeightCube", limitsWeightCube.textureId, 3)
            val extent = displaySize.resolve(inputWidth, inputHeight)
            glProgram.setFloatsUniform("uDisplaySize", floatArrayOf(extent.width, extent.height))
            glProgram.bindAttributesAndUniforms()
            GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
            GlUtil.checkGlError()
        } catch (error: GlUtil.GlException) {
            throw VideoFrameProcessingException(error, presentationTimeUs)
        }
    }

    override fun release() {
        try {
            glProgram.delete()
            GlUtil.deleteTexture(baseCube.textureId)
            GlUtil.deleteTexture(limitsPaintCube.textureId)
            GlUtil.deleteTexture(limitsWeightCube.textureId)
        } catch (error: GlUtil.GlException) {
            throw VideoFrameProcessingException(error)
        } finally {
            super.release()
        }
    }

    private fun bindStaticUniforms() {
        val configuration = plan.configuration
        glProgram.setFloatsUniform("uLutSize", floatArrayOf(baseCube.cubeSize.toFloat()))
        glProgram.setFloatsUniform(
            "uLimitsPaintSize",
            floatArrayOf(limitsPaintCube.cubeSize.toFloat()),
        )
        glProgram.setFloatsUniform(
            "uLimitsWeightSize",
            floatArrayOf(limitsWeightCube.cubeSize.toFloat()),
        )
        glProgram.setFloatsUniform("uLimitsOn", flag(plan.limitsReady))
        glProgram.setFloatsUniform(
            "uDeLogCurve0To3",
            configuration.deLogCurve.copyOfRange(0, 4),
        )
        glProgram.setFloatsUniform("uDeLogCurve4", floatArrayOf(configuration.deLogCurve[4]))
        glProgram.setFloatsUniform("uPeakingOn", flag(plan.effects.peaking))
        glProgram.setFloatsUniform("uPeakingColor", configuration.peakingColor)
        glProgram.setFloatsUniform(
            "uPeakingThreshold",
            floatArrayOf(configuration.peakingThreshold),
        )
        glProgram.setFloatsUniform("uPeakingRamp", floatArrayOf(configuration.peakingRamp))
        glProgram.setFloatsUniform(
            "uZebraHighlightOn",
            flag(plan.effects.zebra && configuration.highlightEnabled),
        )
        glProgram.setFloatsUniform("uZebraHighlight", floatArrayOf(configuration.highlightCode))
        glProgram.setFloatsUniform("uZebraHighlightColor", configuration.highlightColor)
        glProgram.setFloatsUniform(
            "uZebraMidtoneOn",
            flag(plan.effects.zebra && configuration.midtoneEnabled),
        )
        glProgram.setFloatsUniform("uZebraMidtone", floatArrayOf(configuration.midtoneCode))
        glProgram.setFloatsUniform("uZebraMidtoneColor", configuration.midtoneColor)
    }

    private fun flag(enabled: Boolean): FloatArray = floatArrayOf(if (enabled) 1f else 0f)

    private fun uploadCube(cube: FeedEffectsCube?): UploadedCube {
        if (cube == null) {
            val stub = Bitmap.createBitmap(1, 1, Bitmap.Config.ARGB_8888)
            return UploadedCube(upload(stub), 0)
        }
        val atlas = feedEffectsCubeAtlas(cube)
        val bitmap = Bitmap.createBitmap(atlas.width, atlas.height, Bitmap.Config.ARGB_8888)
        bitmap.copyPixelsFromBuffer(ByteBuffer.wrap(atlas.rgba))
        return UploadedCube(upload(bitmap), atlas.cubeSize)
    }

    private fun upload(bitmap: Bitmap): Int =
        try {
            GlUtil.createTexture(bitmap)
        } finally {
            bitmap.recycle()
        }

    companion object {
        private fun createProgram(context: Context): GlProgram =
            try {
                GlProgram(context, VERTEX_SHADER_PATH, FRAGMENT_SHADER_PATH)
            } catch (error: IOException) {
                throw VideoFrameProcessingException(error)
            } catch (error: GlUtil.GlException) {
                throw VideoFrameProcessingException(error)
            }
    }
}

private data class UploadedCube(
    val textureId: Int,
    val cubeSize: Int,
)

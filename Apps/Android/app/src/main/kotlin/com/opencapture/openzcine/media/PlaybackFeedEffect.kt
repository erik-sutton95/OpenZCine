@file:androidx.media3.common.util.UnstableApi

package com.opencapture.openzcine.media

import android.content.Context
import androidx.media3.common.VideoFrameProcessingException
import androidx.media3.common.util.GlUtil
import androidx.media3.common.util.Size
import androidx.media3.effect.BaseGlShaderProgram
import androidx.media3.effect.GlEffect
import androidx.media3.effect.GlShaderProgram
import com.opencapture.openzcine.FeedEffectsGlProgram
import com.opencapture.openzcine.FeedEffectsRenderPlan
import kotlin.math.max

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
    private val glProgram =
        try {
            FeedEffectsGlProgram(context, plan)
        } catch (error: Exception) {
            throw VideoFrameProcessingException(error)
        }
    private var inputWidth = 1
    private var inputHeight = 1

    override fun configure(inputWidth: Int, inputHeight: Int): Size {
        this.inputWidth = max(1, inputWidth)
        this.inputHeight = max(1, inputHeight)
        return Size(this.inputWidth, this.inputHeight)
    }

    override fun drawFrame(inputTexId: Int, presentationTimeUs: Long) {
        try {
            val extent = displaySize.resolve(inputWidth, inputHeight)
            glProgram.draw(
                inputTexId,
                inputWidth.toFloat(),
                inputHeight.toFloat(),
                extent.width,
                extent.height,
            )
        } catch (error: GlUtil.GlException) {
            throw VideoFrameProcessingException(error, presentationTimeUs)
        }
    }

    override fun release() {
        try {
            glProgram.release()
        } catch (error: GlUtil.GlException) {
            throw VideoFrameProcessingException(error)
        } finally {
            super.release()
        }
    }
}

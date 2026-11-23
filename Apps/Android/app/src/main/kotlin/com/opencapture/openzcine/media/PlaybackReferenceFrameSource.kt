@file:androidx.media3.common.util.UnstableApi

package com.opencapture.openzcine.media

import androidx.media3.common.GlTextureInfo
import androidx.media3.common.util.GlRect
import androidx.media3.common.util.Size
import androidx.media3.effect.ByteBufferGlEffect
import com.google.common.util.concurrent.Futures
import com.google.common.util.concurrent.ListenableFuture
import com.opencapture.opencine.runtime.MonitorCleanPictureFrame
import java.util.concurrent.atomic.AtomicReference
import kotlin.math.roundToInt

/**
 * Older Android bakes the assists into the Media3 surface itself. Keep a bounded pre-effect
 * picture so a parked clip can save its exact raster without seeking or changing those effects.
 */
internal class PlaybackReferenceFrameSource {
    private data class Stamped(val timeUs: Long, val frame: MonitorCleanPictureFrame)
    private val latest = AtomicReference<Stamped?>(null)

    fun clear(): Unit = latest.set(null)

    fun frame(timeUs: Long): MonitorCleanPictureFrame? =
        latest.get()?.takeIf { it.timeUs == timeUs }?.frame

    val effect: ByteBufferGlEffect<Unit> = ByteBufferGlEffect(object : ByteBufferGlEffect.Processor<Unit> {
        private var width = 1
        private var height = 1

        override fun configure(inputWidth: Int, inputHeight: Int): Size {
            width = maxOf(1, inputWidth)
            height = maxOf(1, inputHeight)
            val scale = minOf(1f, 640f / maxOf(width, height))
            return Size((width * scale).roundToInt().coerceAtLeast(1), (height * scale).roundToInt().coerceAtLeast(1))
        }

        override fun getScaledRegion(presentationTimeUs: Long): GlRect = GlRect(width, height)

        override fun processImage(image: ByteBufferGlEffect.Image, presentationTimeUs: Long): ListenableFuture<Unit> {
            val rgba = ByteArray(image.width * image.height * 4)
            image.pixelBuffer.duplicate().apply { rewind(); get(rgba) }
            latest.set(Stamped(presentationTimeUs, MonitorCleanPictureFrame(image.width, image.height, rgba, bottomUp = true)))
            return Futures.immediateFuture(Unit)
        }

        override fun finishProcessingAndBlend(outputFrame: GlTextureInfo, presentationTimeUs: Long, result: Unit): Unit = Unit
        override fun release(): Unit = clear()
    })
}

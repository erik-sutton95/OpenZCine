@file:androidx.media3.common.util.UnstableApi

package com.opencapture.openzcine.media

import androidx.media3.common.GlTextureInfo
import androidx.media3.common.util.GlRect
import androidx.media3.common.util.Size
import androidx.media3.effect.ByteBufferGlEffect
import com.google.common.util.concurrent.Futures
import com.google.common.util.concurrent.ListenableFuture
import com.opencapture.openzcine.PlaybackScopeFrameSource
import com.opencapture.openzcine.ReducedScopeFrame
import java.nio.ByteBuffer
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference
import kotlin.math.max
import kotlin.math.min

private const val REDUCED_SCOPE_WIDTH = 160

/**
 * Clean pre-effect playback tap backed by Media3's asynchronous pixel-buffer effect.
 *
 * The effect is ordered immediately before the display-assist shader. Its no-op blend preserves
 * the full-resolution decoded frame for that shader while this source publishes a small owned RGBA
 * copy for Swift scope analysis.
 */
internal class PlaybackCleanScopeFrameSource : PlaybackScopeFrameSource {
    private val generation = AtomicLong(0L)
    private val lastConsumedGeneration = AtomicLong(Long.MIN_VALUE)
    private val latest = AtomicReference<StampedScopeFrame?>(null)
    private val processor = CleanScopeProcessor(::publish)

    /** Media3 effect to place before every display-assist effect. */
    val effect: ByteBufferGlEffect<Unit> = ByteBufferGlEffect(processor)

    override fun reset() {
        lastConsumedGeneration.set(Long.MIN_VALUE)
    }

    override suspend fun capture(): ReducedScopeFrame? {
        while (true) {
            val frame = latest.get() ?: return null
            val consumed = lastConsumedGeneration.get()
            if (consumed == frame.generation) return null
            if (lastConsumedGeneration.compareAndSet(consumed, frame.generation)) {
                return frame.frame
            }
        }
    }

    private fun publish(frame: ReducedScopeFrame) {
        latest.set(StampedScopeFrame(generation.incrementAndGet(), frame))
    }
}

private data class StampedScopeFrame(
    val generation: Long,
    val frame: ReducedScopeFrame,
)

/** ByteBufferGlEffect processor that downsamples before scheduling its GLES pixel read. */
private class CleanScopeProcessor(
    private val publish: (ReducedScopeFrame) -> Unit,
) : ByteBufferGlEffect.Processor<Unit> {
    private var inputWidth = 1
    private var inputHeight = 1

    override fun configure(inputWidth: Int, inputHeight: Int): Size {
        this.inputWidth = max(1, inputWidth)
        this.inputHeight = max(1, inputHeight)
        val width = min(REDUCED_SCOPE_WIDTH, this.inputWidth)
        val height = max(1, (this.inputHeight.toLong() * width / this.inputWidth).toInt())
        return Size(width, height)
    }

    override fun getScaledRegion(presentationTimeUs: Long): GlRect =
        GlRect(inputWidth, inputHeight)

    override fun processImage(
        image: ByteBufferGlEffect.Image,
        presentationTimeUs: Long,
    ): ListenableFuture<Unit> {
        val rgba = glRgbaTopDown(image.pixelBuffer, image.width, image.height)
        publish(
            ReducedScopeFrame(
                rgba = rgba,
                width = image.width,
                height = image.height,
                bytesPerRow = image.width * 4,
            ),
        )
        return Futures.immediateFuture(Unit)
    }

    override fun finishProcessingAndBlend(
        outputFrame: GlTextureInfo,
        presentationTimeUs: Long,
        result: Unit,
    ) = Unit

    override fun release(): Unit = Unit
}

/** Copies GLES bottom-up RGBA rows into the top-down layout consumed by the Swift scope wire. */
internal fun glRgbaTopDown(source: ByteBuffer, width: Int, height: Int): ByteArray {
    require(width > 0 && height > 0) { "scope frame dimensions must be positive" }
    val bytesPerRow = width * 4
    require(source.capacity() >= bytesPerRow * height) { "scope pixel buffer is truncated" }
    val input = source.duplicate()
    val output = ByteArray(bytesPerRow * height)
    for (outputRow in 0 until height) {
        input.position((height - outputRow - 1) * bytesPerRow)
        input.get(output, outputRow * bytesPerRow, bytesPerRow)
    }
    return output
}

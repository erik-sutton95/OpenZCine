package com.opencapture.openzcine

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Typeface
import com.opencapture.openzcine.core.LiveFrame
import com.opencapture.openzcine.core.LiveFrameSource
import java.io.ByteArrayOutputStream
import kotlin.math.abs
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOn

/**
 * Debug-only [LiveFrameSource] that synthesizes JPEG frames on the fly —
 * colour bars, a bouncing marker, and a running timecode drawn into a bitmap
 * and compressed per frame. No binary frame assets in the repo; the pattern
 * moves every frame so a static screenshot proves live rendering (timecode)
 * and dropped frames are visible as marker jumps.
 *
 * Emission is paced against an absolute schedule (`start + n * period`), not
 * per-frame sleeps, so compression cost doesn't skew the rate.
 */
class DemoFrameSource(
    private val width: Int = 1280,
    private val height: Int = 720,
    private val framesPerSecond: Int = 25,
) : LiveFrameSource {
    override val frames: Flow<LiveFrame> =
        flow {
            val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
            val canvas = Canvas(bitmap)
            val stream = ByteArrayOutputStream()
            val periodNanos = 1_000_000_000L / framesPerSecond
            val startNanos = System.nanoTime()
            var frameIndex = 0L
            while (true) {
                drawTestPattern(canvas, frameIndex)
                stream.reset()
                bitmap.compress(Bitmap.CompressFormat.JPEG, 80, stream)
                emit(LiveFrame(timestampNanos = System.nanoTime(), jpegData = stream.toByteArray()))
                frameIndex++
                val dueNanos = startNanos + frameIndex * periodNanos
                val waitMillis = (dueNanos - System.nanoTime()) / 1_000_000
                if (waitMillis > 0) delay(waitMillis)
            }
        }
            .flowOn(Dispatchers.Default)

    private val paint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val textPaint =
        Paint(Paint.ANTI_ALIAS_FLAG).apply {
            typeface = Typeface.MONOSPACE
            textSize = 56f
            color = Color.WHITE
        }
    // Classic bar colours: white, yellow, cyan, green, magenta, red, blue, black.
    private val barColors =
        intArrayOf(
            0xFFB4B4B4.toInt(), 0xFFB4B400.toInt(), 0xFF00B4B4.toInt(), 0xFF00B400.toInt(),
            0xFFB400B4.toInt(), 0xFFB40000.toInt(), 0xFF0000B4.toInt(), 0xFF101010.toInt(),
        )

    private fun drawTestPattern(canvas: Canvas, frameIndex: Long) {
        val barWidth = width / barColors.size.toFloat()
        for ((index, color) in barColors.withIndex()) {
            paint.color = color
            canvas.drawRect(index * barWidth, 0f, (index + 1) * barWidth, height * 0.7f, paint)
        }
        paint.color = Color.BLACK
        canvas.drawRect(0f, height * 0.7f, width.toFloat(), height.toFloat(), paint)

        // Bouncing gold marker across the lower band — one bar width per second.
        val travel = width - 160f
        val phase = frameIndex % (2 * travel).toLong()
        val x = abs(phase - travel)
        paint.color = 0xFFFFE100.toInt() // BrandColors.accent
        canvas.drawRect(x, height * 0.72f, x + 160f, height * 0.86f, paint)

        val seconds = frameIndex / framesPerSecond
        val timecode =
            "%02d:%02d:%02d:%02d"
                .format(seconds / 3600, seconds / 60 % 60, seconds % 60, frameIndex % framesPerSecond)
        canvas.drawText("OPENZCINE DEMO  $timecode", 24f, height - 32f, textPaint)
    }
}

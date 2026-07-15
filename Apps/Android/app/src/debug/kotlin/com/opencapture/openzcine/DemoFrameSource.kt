package com.opencapture.openzcine

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Typeface
import com.opencapture.openzcine.core.LiveAudioMeterChannel
import com.opencapture.openzcine.core.LiveAudioMeterLevels
import com.opencapture.openzcine.core.LiveCameraLevel
import com.opencapture.openzcine.core.LiveFocusBox
import com.opencapture.openzcine.core.LiveFocusInfo
import com.opencapture.openzcine.core.LiveFocusResult
import com.opencapture.openzcine.core.LiveFrame
import com.opencapture.openzcine.core.LiveFrameSource
import com.opencapture.openzcine.core.LiveFrameTimecode
import java.io.ByteArrayOutputStream
import kotlin.math.cos
import kotlin.math.roundToInt
import kotlin.math.sin
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOn

/**
 * Debug-only [LiveFrameSource] that synthesizes JPEG frames on the fly —
 * colour bars and a running timecode drawn into a bitmap and compressed per
 * frame. No binary frame assets are in the repo; the running timecode changes
 * every frame so a static screenshot proves live rendering.
 *
 * Emission is paced against an absolute schedule (`start + n * period`), not
 * per-frame sleeps, so compression cost doesn't skew the rate.
 */
class DemoFrameSource(
    private val width: Int = 1280,
    private val height: Int = 720,
    private val framesPerSecond: Int = 25,
    /** Omit the synthetic level only when visually exercising device-tilt fallback. */
    private val includeDebugCameraLevel: Boolean = true,
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
                emit(
                    LiveFrame(
                        timestampNanos = System.nanoTime(),
                        jpegData = stream.toByteArray(),
                        audioLevels = debugAudioLevels(frameIndex),
                        focus = debugFocusInfo(frameIndex),
                        level = debugCameraLevel(frameIndex).takeIf { includeDebugCameraLevel },
                        timecode = debugTimecode(frameIndex),
                        measuredFramesPerSecond = framesPerSecond.toDouble(),
                    ),
                )
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
            // Keep the fixture's motion proof in the left lower band so it
            // cannot overlap either iOS-matched Gauge axis in screenshots.
            textSize = 34f
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

        val seconds = frameIndex / framesPerSecond
        val timecode =
            "%02d:%02d:%02d:%02d"
                .format(seconds / 3600, seconds / 60 % 60, seconds % 60, frameIndex % framesPerSecond)
        // Keep the debug-only proof-of-motion label in the visible feed band:
        // the monitor's real capture chrome intentionally overlays the lower
        // image area, so a bottom-aligned label would look clipped in a test
        // screenshot even though the renderer is correct.
        paint.color = Color.BLACK
        canvas.drawRect(0f, height * 0.60f, width.toFloat(), height * 0.70f, paint)
        canvas.drawText("DEMO  $timecode", 24f, height * 0.68f, textPaint)
    }

    /** Synthetic timecode exists only in this explicit debug source set. */
    private fun debugTimecode(frameIndex: Long): LiveFrameTimecode {
        val seconds = frameIndex / framesPerSecond
        return LiveFrameTimecode(
            on = true,
            hour = (seconds / 3_600 % 24).toInt(),
            minute = (seconds / 60 % 60).toInt(),
            second = (seconds % 60).toInt(),
            frame = (frameIndex % framesPerSecond).toInt(),
        )
    }

    /**
     * Debug-only moving bars for visual verification. These values never pass
     * through the camera bridge; [LiveAudioMeterLevels.isDebugFixture] keeps
     * the monitor visibly labelled `DEBUG FIXTURE — NOT CAMERA AUDIO`.
     */
    private fun debugAudioLevels(frameIndex: Long): LiveAudioMeterLevels {
        val seconds = frameIndex.toDouble() / framesPerSecond.toDouble()
        val leftLevel = -34.0 + 25.0 * ((sin(seconds * 4.1) + 1.0) / 2.0)
        val rightLevel = -42.0 + 28.0 * ((sin(seconds * 3.3 + 1.2) + 1.0) / 2.0)
        return LiveAudioMeterLevels(
            left = LiveAudioMeterChannel(leftLevel, (leftLevel + 6.0).coerceAtMost(0.0)),
            right = LiveAudioMeterChannel(rightLevel, (rightLevel + 9.0).coerceAtMost(0.0)),
            isDebugFixture = true,
        )
    }

    /**
     * Synthetic overlay data for visual verification only. [isDebugFixture]
     * keeps the monitor from presenting these moving boxes as Nikon AF data.
     */
    private fun debugFocusInfo(frameIndex: Long): LiveFocusInfo {
        val seconds = frameIndex.toDouble() / framesPerSecond.toDouble()
        val faceCenterX = (width * (0.5 + 0.18 * sin(seconds * 0.8))).roundToInt()
        val faceCenterY = (height * (0.42 + 0.08 * cos(seconds * 1.1))).roundToInt()
        val faceWidth = (width * 0.22).roundToInt()
        val faceHeight = (height * 0.34).roundToInt()
        val eyeSize = (height * 0.10).roundToInt()
        return LiveFocusInfo(
            coordinateWidth = width,
            coordinateHeight = height,
            result = LiveFocusResult.FOCUSED,
            subjectDetectionActive = true,
            trackingAFActive = true,
            selectedBoxIndex = 1,
            boxes =
                listOf(
                    LiveFocusBox(
                        centerX = faceCenterX,
                        centerY = faceCenterY,
                        width = faceWidth,
                        height = faceHeight,
                    ),
                    LiveFocusBox(
                        centerX = faceCenterX - faceWidth / 6,
                        centerY = faceCenterY - faceHeight / 8,
                        width = eyeSize,
                        height = eyeSize,
                    ),
                ),
            isDebugFixture = true,
        )
    }

    /** Synthetic camera-level substitute, visibly labelled by the overlay as a debug fixture. */
    private fun debugCameraLevel(frameIndex: Long): LiveCameraLevel {
        val seconds = frameIndex.toDouble() / framesPerSecond.toDouble()
        return LiveCameraLevel(
            rollDegrees = 7.5 * sin(seconds * 0.65),
            pitchDegrees = 4.0 * cos(seconds * 0.48),
            yawDegrees = 0.0,
            isDebugFixture = true,
        )
    }
}

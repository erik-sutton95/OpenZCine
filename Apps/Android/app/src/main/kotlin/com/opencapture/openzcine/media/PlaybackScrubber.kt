package com.opencapture.openzcine.media

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.dp
import com.opencapture.openzcine.LiveDesign
import kotlin.math.max

/**
 * iOS `PlaybackScrubber` port: 3pt track, buffer layer, accent fill, 12pt thumb.
 * Drag seeks with preview; release commits exact seek via [onSeek].
 */
@Composable
internal fun PlaybackScrubber(
    progressMs: Long,
    durationMs: Long,
    bufferedFraction: Float?,
    onScrubbingChanged: (Boolean) -> Unit,
    onProgressChange: (Long) -> Unit,
    onSeek: (Long) -> Unit,
    modifier: Modifier = Modifier,
) {
    val duration = max(1L, durationMs)
    val fraction = (progressMs.toFloat() / duration.toFloat()).coerceIn(0f, 1f)
    val buffer = bufferedFraction?.coerceIn(0f, 1f) ?: 0f
    var widthPx by remember { mutableFloatStateOf(1f) }
    var dragProgressMs by remember { mutableLongStateOf(-1L) }
    val density = LocalDensity.current
    val trackHeight = with(density) { 3.dp.toPx() }
    val thumbSize = with(density) { 12.dp.toPx() }
    val hairline = LiveDesign.hairline
    val accent = LiveDesign.accent
    val bufferColor = accent.copy(alpha = 0.32f)
    val displayFraction =
        ((if (dragProgressMs >= 0L) dragProgressMs else progressMs).toFloat() / duration.toFloat())
            .coerceIn(0f, 1f)

    fun progressAt(x: Float): Long {
        val f = (x / max(1f, widthPx)).coerceIn(0f, 1f)
        return (f * duration).toLong()
    }

    Canvas(
        modifier
            .fillMaxWidth()
            .height(22.dp)
            .pointerInput(duration) {
                detectTapGestures { offset ->
                    val target = progressAt(offset.x)
                    onScrubbingChanged(true)
                    onProgressChange(target)
                    onSeek(target)
                    onScrubbingChanged(false)
                    dragProgressMs = -1L
                }
            }
            .pointerInput(duration) {
                detectHorizontalDragGestures(
                    onDragStart = { offset ->
                        onScrubbingChanged(true)
                        val target = progressAt(offset.x)
                        dragProgressMs = target
                        onProgressChange(target)
                    },
                    onDragEnd = {
                        val target = dragProgressMs.takeIf { it >= 0L } ?: progressMs
                        onSeek(target.coerceIn(0L, duration))
                        onScrubbingChanged(false)
                        dragProgressMs = -1L
                    },
                    onDragCancel = {
                        onScrubbingChanged(false)
                        dragProgressMs = -1L
                    },
                    onHorizontalDrag = { change, _ ->
                        change.consume()
                        val target = progressAt(change.position.x)
                        dragProgressMs = target
                        onProgressChange(target)
                    },
                )
            },
    ) {
        widthPx = size.width
        val cy = size.height / 2f
        val trackTop = cy - trackHeight / 2f
        // Background track
        drawRoundRect(
            color = hairline,
            topLeft = Offset(0f, trackTop),
            size = Size(size.width, trackHeight),
            cornerRadius = CornerRadius(trackHeight / 2f, trackHeight / 2f),
        )
        // Buffer
        if (buffer > 0f) {
            drawRoundRect(
                color = bufferColor,
                topLeft = Offset(0f, trackTop),
                size = Size(max(trackHeight, size.width * buffer), trackHeight),
                cornerRadius = CornerRadius(trackHeight / 2f, trackHeight / 2f),
            )
        }
        // Progress
        drawRoundRect(
            color = accent,
            topLeft = Offset(0f, trackTop),
            size = Size(max(trackHeight, size.width * displayFraction), trackHeight),
            cornerRadius = CornerRadius(trackHeight / 2f, trackHeight / 2f),
        )
        // Thumb
        val thumbX = (size.width * displayFraction).coerceIn(0f, size.width)
        drawCircle(
            color = accent,
            radius = thumbSize / 2f,
            center = Offset(thumbX, cy),
        )
    }
}

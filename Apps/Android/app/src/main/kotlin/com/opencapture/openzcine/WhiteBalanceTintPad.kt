package com.opencapture.openzcine

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.wrapContentHeight
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import android.graphics.Paint as AndroidPaint
import android.graphics.Rect as AndroidRect
import android.graphics.Typeface
import kotlin.math.roundToInt

/**
 * iOS `WhiteBalanceTintPad` — 1:1 geometry and interaction:
 * - 108pt pad, 28pt circular chevron arrows, 8pt arrow/pad gap, 20pt pad↔copy gap
 * - Crosshair inset 18pt; axis letters at 10pt from edges
 * - Gold 13pt thumb; drag commits on release; double-tap Neutral
 *
 * Intrinsic height is fixed (not weight-compressed) so the magenta arrow is
 * never clipped by a short parent.
 */
@Composable
internal fun WhiteBalanceTintPad(
    currentLabel: String,
    available: Boolean,
    interactive: Boolean,
    onCommit: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    val density = LocalDensity.current
    val sidePx = with(density) { PAD_SIDE_DP.dp.toPx() }
    val range = WhiteBalanceTintGrid.cellRange
    val seed = remember(currentLabel) { WhiteBalanceTintGrid.cellsFromLabel(currentLabel) }
    var ab by remember(currentLabel) { mutableIntStateOf(seed.first) }
    var gm by remember(currentLabel) { mutableIntStateOf(seed.second) }
    LaunchedEffect(currentLabel) {
        val cells = WhiteBalanceTintGrid.cellsFromLabel(currentLabel)
        ab = cells.first
        gm = cells.second
    }
    val label = WhiteBalanceTintGrid.label(ab, gm)
    val enabled = available && interactive
    val a11y =
        stringResource(R.string.camera_wb_tint_description) + " " +
            stringResource(R.string.camera_wb_tint_value, label)

    // Intrinsic size: arrows + pad + gaps. Do not fill/weight-compress — that
    // is what clipped the magenta chevron on the A12 landscape picker.
    Row(
        modifier =
            modifier
                .fillMaxWidth()
                .wrapContentHeight()
                .alpha(if (available) 1f else 0.35f)
                .semantics { contentDescription = a11y },
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(20.dp),
    ) {
        Row(
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            TintChevronArrow(
                direction = ChevronDirection.LEFT,
                enabled = enabled,
                contentDescription = stringResource(R.string.camera_wb_tint_shift_blue),
            ) {
                ab = WhiteBalanceTintGrid.clamp(ab - 1)
                onCommit(WhiteBalanceTintGrid.label(ab, gm))
            }
            Column(
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                TintChevronArrow(
                    direction = ChevronDirection.UP,
                    enabled = enabled,
                    contentDescription = stringResource(R.string.camera_wb_tint_shift_green),
                ) {
                    gm = WhiteBalanceTintGrid.clamp(gm + 1)
                    onCommit(WhiteBalanceTintGrid.label(ab, gm))
                }
                Box(
                    Modifier
                        .size(PAD_SIDE_DP.dp)
                        .background(LiveDesign.glass, RoundedCornerShape(12.dp))
                        .border(1.dp, LiveDesign.hairline, RoundedCornerShape(12.dp))
                        .pointerInput(enabled) {
                            if (!enabled) return@pointerInput
                            detectTapGestures(
                                onDoubleTap = {
                                    ab = 0
                                    gm = 0
                                    onCommit(WhiteBalanceTintGrid.label(0, 0))
                                },
                            )
                        }
                        .pointerInput(enabled) {
                            if (!enabled) return@pointerInput
                            detectDragGestures(
                                onDrag = { change, _ ->
                                    change.consume()
                                    val x = (change.position.x / sidePx).coerceIn(0f, 1f)
                                    val y = (change.position.y / sidePx).coerceIn(0f, 1f)
                                    ab = cellFromNormalized(x)
                                    gm = cellFromNormalized(1f - y)
                                },
                                onDragEnd = {
                                    onCommit(WhiteBalanceTintGrid.label(ab, gm))
                                },
                                onDragCancel = {
                                    onCommit(WhiteBalanceTintGrid.label(ab, gm))
                                },
                            )
                        },
                ) {
                    Canvas(Modifier.fillMaxSize()) {
                        val stroke = 1.dp.toPx()
                        val inset = 18.dp.toPx()
                        val edge = 10.dp.toPx()
                        drawLine(
                            LiveDesign.hairline,
                            Offset(size.width / 2f, inset),
                            Offset(size.width / 2f, size.height - inset),
                            stroke,
                        )
                        drawLine(
                            LiveDesign.hairline,
                            Offset(inset, size.height / 2f),
                            Offset(size.width - inset, size.height / 2f),
                            stroke,
                        )
                        // iOS axisLetter uses `.position(x,y)` — glyph centre on the
                        // axis point. Paint + getTextBounds centres the actual cap
                        // ink (not the loose Text layout box, which sits low).
                        drawAxisLetter("G", Color.Green.copy(alpha = 0.85f), size.width / 2f, edge)
                        drawAxisLetter(
                            "M",
                            Color(0xFFFF2D95).copy(alpha = 0.85f),
                            size.width / 2f,
                            size.height - edge,
                        )
                        drawAxisLetter("B", Color.Blue.copy(alpha = 0.85f), edge, size.height / 2f)
                        drawAxisLetter(
                            "A",
                            Color(0xFFFF9500).copy(alpha = 0.85f),
                            size.width - edge,
                            size.height / 2f,
                        )
                    }

                    val thumbX = thumbOffset(ab, range.first, range.last, sidePx)
                    val thumbY = sidePx - thumbOffset(gm, range.first, range.last, sidePx)
                    val halfThumb = with(density) { 6.5.dp.toPx() }
                    Box(
                        Modifier
                            .offset {
                                IntOffset(
                                    (thumbX - halfThumb).roundToInt(),
                                    (thumbY - halfThumb).roundToInt(),
                                )
                            }
                            .size(13.dp)
                            .shadow(3.dp, CircleShape, ambientColor = Color.Black.copy(alpha = 0.4f))
                            .background(LiveDesign.accent, CircleShape),
                    )
                }
                TintChevronArrow(
                    direction = ChevronDirection.DOWN,
                    enabled = enabled,
                    contentDescription = stringResource(R.string.camera_wb_tint_shift_magenta),
                ) {
                    gm = WhiteBalanceTintGrid.clamp(gm - 1)
                    onCommit(WhiteBalanceTintGrid.label(ab, gm))
                }
            }
            TintChevronArrow(
                direction = ChevronDirection.RIGHT,
                enabled = enabled,
                contentDescription = stringResource(R.string.camera_wb_tint_shift_amber),
            ) {
                ab = WhiteBalanceTintGrid.clamp(ab + 1)
                onCommit(WhiteBalanceTintGrid.label(ab, gm))
            }
        }

        // iOS trailing copy column — leading-aligned, no vertical compression.
        Column(
            verticalArrangement = Arrangement.spacedBy(6.dp),
            modifier = Modifier.weight(1f, fill = true),
        ) {
            Text(
                label,
                style = chromeStyle(17f, FontWeight.SemiBold),
                color = if (label == "Neutral") LiveDesign.muted else LiveDesign.accent,
                maxLines = 1,
            )
            Text(
                stringResource(R.string.camera_wb_tint_steps_help),
                style = chromeStyle(11f, FontWeight.Normal),
                color = LiveDesign.muted,
            )
            Text(
                stringResource(R.string.camera_wb_tint_double_tap_help),
                style = chromeStyle(11f, FontWeight.Normal),
                color = LiveDesign.faint,
            )
        }
    }
}

private enum class ChevronDirection { LEFT, RIGHT, UP, DOWN }

/** 28dp glass-bright circle with a 13pt bold chevron — iOS SF Symbol look. */
@Composable
private fun TintChevronArrow(
    direction: ChevronDirection,
    enabled: Boolean,
    contentDescription: String,
    onClick: () -> Unit,
) {
    Box(
        Modifier
            .size(28.dp)
            .background(LiveDesign.glassBright, CircleShape)
            .chromeClickable(enabled, onClick = onClick)
            .semantics { this.contentDescription = contentDescription },
        contentAlignment = Alignment.Center,
    ) {
        Canvas(Modifier.size(13.dp)) {
            val stroke =
                Stroke(
                    width = 2.2.dp.toPx(),
                    cap = StrokeCap.Round,
                    join = StrokeJoin.Round,
                )
            val w = size.width
            val h = size.height
            val path =
                Path().apply {
                    when (direction) {
                        ChevronDirection.LEFT -> {
                            moveTo(w * 0.62f, h * 0.18f)
                            lineTo(w * 0.32f, h * 0.5f)
                            lineTo(w * 0.62f, h * 0.82f)
                        }
                        ChevronDirection.RIGHT -> {
                            moveTo(w * 0.38f, h * 0.18f)
                            lineTo(w * 0.68f, h * 0.5f)
                            lineTo(w * 0.38f, h * 0.82f)
                        }
                        ChevronDirection.UP -> {
                            moveTo(w * 0.18f, h * 0.62f)
                            lineTo(w * 0.5f, h * 0.32f)
                            lineTo(w * 0.82f, h * 0.62f)
                        }
                        ChevronDirection.DOWN -> {
                            moveTo(w * 0.18f, h * 0.38f)
                            lineTo(w * 0.5f, h * 0.68f)
                            lineTo(w * 0.82f, h * 0.38f)
                        }
                    }
                }
            drawPath(path, LiveDesign.text, style = stroke)
        }
    }
}

/**
 * Draw a bold 9sp axis letter with its **glyph ink** centred on `(x, y)`.
 *
 * Compose `Text` layout boxes include font ascent/descent padding that sits
 * capital letters slightly below the geometric centre — enough that G/M/B/A
 * all looked a touch low vs the crosshair. `getTextBounds` tracks the real
 * ink, matching iOS SwiftUI `.position` optical placement.
 */
private fun DrawScope.drawAxisLetter(letter: String, color: Color, x: Float, y: Float) {
    val paint =
        AndroidPaint(AndroidPaint.ANTI_ALIAS_FLAG).apply {
            this.color = color.toArgb()
            textSize = 9.sp.toPx()
            typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
            textAlign = AndroidPaint.Align.CENTER
        }
    val bounds = AndroidRect()
    paint.getTextBounds(letter, 0, letter.length, bounds)
    // bounds are relative to the baseline; centre the ink box on (x, y).
    val baseline = y - (bounds.top + bounds.bottom) / 2f
    drawContext.canvas.nativeCanvas.drawText(letter, x, baseline, paint)
}

private fun thumbOffset(value: Int, lower: Int, upper: Int, sidePx: Float): Float {
    val t = (value - lower).toFloat() / (upper - lower).toFloat()
    return t * sidePx
}

private fun cellFromNormalized(t: Float): Int {
    val range = WhiteBalanceTintGrid.cellRange
    val clamped = t.coerceIn(0f, 1f)
    val value = range.first + clamped * (range.last - range.first)
    return WhiteBalanceTintGrid.clamp(value.roundToInt())
}

/** iOS `side: CGFloat = 108`. */
private const val PAD_SIDE_DP = 108f

/** Full pad cluster height: 28 + 8 + 108 + 8 + 28 (arrows + gaps + pad). */
internal val WhiteBalanceTintPadClusterHeightDp = 28f + 8f + PAD_SIDE_DP + 8f + 28f

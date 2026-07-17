package com.opencapture.openzcine

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
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
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
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlin.math.roundToInt

/**
 * iOS `WhiteBalanceTintPad`: 13×13 fine-tune grid (amber↔blue / green↔magenta)
 * with four step arrows, drag-to-jog (commit on release), and double-tap reset
 * to Neutral. Dimmed when the active WB mode has no tune property.
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

    Row(
        modifier =
            modifier
                .fillMaxWidth()
                .alpha(if (available) 1f else 0.35f)
                .semantics { contentDescription = a11y },
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(20.dp),
    ) {
        Row(
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            TintArrow(
                symbol = "‹",
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
                TintArrow(
                    symbol = "ˆ",
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
                                    // Screen y grows downward; grid y is green(+) up.
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
                    // Crosshair axes (short of the letter caps).
                    androidx.compose.foundation.Canvas(Modifier.fillMaxSize()) {
                        val stroke = 1.dp.toPx()
                        val inset = 18.dp.toPx()
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
                    }
                    AxisLetter("G", Color(0xFF3DCC6A), Alignment.TopCenter)
                    AxisLetter("M", Color(0xFFE85A9A), Alignment.BottomCenter)
                    AxisLetter("B", Color(0xFF3D8BFF), Alignment.CenterStart)
                    AxisLetter("A", Color(0xFFFF9A3D), Alignment.CenterEnd)

                    val thumbX =
                        thumbOffset(ab, range.first, range.last, sidePx)
                    val thumbY =
                        sidePx - thumbOffset(gm, range.first, range.last, sidePx)
                    Box(
                        Modifier
                            .offset {
                                IntOffset(
                                    (thumbX - with(density) { 6.5.dp.toPx() }).roundToInt(),
                                    (thumbY - with(density) { 6.5.dp.toPx() }).roundToInt(),
                                )
                            }
                            .size(13.dp)
                            .shadow(3.dp, CircleShape)
                            .background(LiveDesign.accent, CircleShape),
                    )
                }
                TintArrow(
                    symbol = "ˇ",
                    enabled = enabled,
                    contentDescription = stringResource(R.string.camera_wb_tint_shift_magenta),
                ) {
                    gm = WhiteBalanceTintGrid.clamp(gm - 1)
                    onCommit(WhiteBalanceTintGrid.label(ab, gm))
                }
            }
            TintArrow(
                symbol = "›",
                enabled = enabled,
                contentDescription = stringResource(R.string.camera_wb_tint_shift_amber),
            ) {
                ab = WhiteBalanceTintGrid.clamp(ab + 1)
                onCommit(WhiteBalanceTintGrid.label(ab, gm))
            }
        }

        Column(
            verticalArrangement = Arrangement.spacedBy(6.dp),
            modifier = Modifier.weight(1f),
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

@Composable
private fun TintArrow(
    symbol: String,
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
        Text(
            symbol,
            color = LiveDesign.text,
            fontSize = 16.sp,
            fontWeight = FontWeight.Bold,
        )
    }
}

@Composable
private fun androidx.compose.foundation.layout.BoxScope.AxisLetter(
    letter: String,
    color: Color,
    alignment: Alignment,
) {
    Text(
        letter,
        modifier =
            Modifier
                .align(alignment)
                .padding(2.dp),
        color = color.copy(alpha = 0.85f),
        fontSize = 9.sp,
        fontWeight = FontWeight.Bold,
    )
}

private fun thumbOffset(value: Int, lower: Int, upper: Int, sidePx: Float): Float {
    val t = (value - lower).toFloat() / (upper - lower).toFloat()
    return t * sidePx
}

private fun cellFromNormalized(t: Float): Int {
    val range = WhiteBalanceTintGrid.cellRange
    val clamped = t.coerceIn(0f, 1f)
    val value =
        range.first +
            clamped * (range.last - range.first)
    return WhiteBalanceTintGrid.clamp(value.roundToInt())
}

private const val PAD_SIDE_DP = 108f

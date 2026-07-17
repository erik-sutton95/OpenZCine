package com.opencapture.openzcine

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.PlatformTextStyle
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.foundation.clickable
import androidx.compose.material3.Text
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.onClick as semanticsOnClick
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.Dp
import com.opencapture.openzcine.core.LiveFrameTimecode

// Compose mirrors of the iOS monitor chrome primitives (ios/Runner/
// MonitorControls.swift + MonitorExperience.swift). Layout frames come from the
// shared core's zone map; these components only mirror the DRAWING — pill
// shapes, type hierarchy, and LiveDesign colors. SF Symbols are approximated
// with small Canvas glyphs; SF→Roboto type differences are accepted.

/** Rounded chrome shape (iOS `LiveDesign.cornerRadius`). */
val ChromeShape = RoundedCornerShape(LiveDesign.CORNER_RADIUS_DP.dp)

// The glass treatment itself (Modifier.glass / Modifier.chipGlass and the
// tiered GPU backdrop pipeline behind it) lives in GlassChrome.kt.

/** Click without the Material ripple (chrome buttons highlight by state, not ripple). */
@Composable
fun Modifier.chromeClickable(onClick: () -> Unit): Modifier =
    chromeClickable(enabled = true, onClick = onClick)

/** Disabled chrome controls keep their visual state but reject touch input. */
@Composable
fun Modifier.chromeClickable(enabled: Boolean, onClick: () -> Unit): Modifier =
    clickable(
        enabled = enabled,
        interactionSource = remember { MutableInteractionSource() },
        indication = null,
        onClick = onClick,
    )

/** Text style matching iOS `.system(size:weight:design:)` closely enough. */
fun chromeStyle(size: Float, weight: FontWeight, mono: Boolean = false): TextStyle =
    TextStyle(
        fontSize = size.sp,
        lineHeight = size.sp,
        fontWeight = weight,
        fontFamily = if (mono) FontFamily.Monospace else FontFamily.SansSerif,
        platformStyle = PlatformTextStyle(includeFontPadding = false),
    )

/** Camera `HH:MM:SS` with the exact camera-provided `:FF` field tinted accent. */
fun timecodeAnnotated(timecode: LiveFrameTimecode): AnnotatedString {
    val label = cameraTimecodeLabel(timecode)
    val main = label.take(8)
    val frames = label.drop(8)
    return buildAnnotatedString {
        withStyle(SpanStyle(color = LiveDesign.text)) { append(main) }
        withStyle(SpanStyle(color = LiveDesign.accent)) { append(frames) }
    }
}

/** Camera timecode text that never substitutes an elapsed shell clock. */
@Composable
fun CameraTimecodeReadout(
    timecode: LiveFrameTimecode?,
    sizeSp: Float,
    weight: FontWeight = FontWeight.Normal,
    modifier: Modifier = Modifier,
) {
    val available = authoritativeTimecode(timecode)
    if (available == null) {
        val description = stringResource(R.string.timecode_unavailable_description)
        Text(
            UNAVAILABLE_TIMECODE,
            style = chromeStyle(sizeSp, weight, mono = true),
            color = LiveDesign.muted,
            maxLines = 1,
            modifier = modifier.semantics { contentDescription = description },
        )
    } else {
        val label = cameraTimecodeLabel(available)
        val description = stringResource(R.string.timecode_description, label)
        Text(
            timecodeAnnotated(available),
            style = chromeStyle(sizeSp, weight, mono = true),
            maxLines = 1,
            modifier = modifier.semantics { contentDescription = description },
        )
    }
}

/** STBY/REC pill: state dot + label in a glass capsule (iOS `RecordChip`). */
@Composable
fun RecordChip(recording: Boolean) {
    Row(
        modifier = Modifier.chipGlass(CircleShape).padding(horizontal = 12.dp, vertical = 7.dp),
        horizontalArrangement = Arrangement.spacedBy(7.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            Modifier.size(9.dp)
                .background(if (recording) LiveDesign.rec else LiveDesign.faint, CircleShape),
        )
        Text(
            text =
                stringResource(
                    if (recording) R.string.record_state_rec
                    else R.string.record_state_standby_short,
                ),
            style = chromeStyle(11f, FontWeight.Bold, mono = true),
            color = if (recording) LiveDesign.text else LiveDesign.muted,
        )
    }
}

/** Glyph + value in a glass capsule (iOS `inlineReadout`). */
@Composable
fun ReadoutPill(
    value: String,
    active: Boolean = false,
    onClick: (() -> Unit)? = null,
    icon: @Composable (Color) -> Unit,
) {
    // Active = the iOS readout-button treatment: accent-dim capsule + an
    // accent-dim border (iOS strokes with accentDim, not full accent) with
    // glyph and value going gold while its picker is open.
    val surface =
        if (active) {
            Modifier.background(LiveDesign.accentDim, CircleShape)
                .border(1.dp, LiveDesign.accentDim, CircleShape)
        } else {
            Modifier.chipGlass(CircleShape)
        }
    Row(
        modifier =
            surface
                .then(
                    if (onClick != null) Modifier.chromeClickable(true, onClick) else Modifier
                )
                .padding(horizontal = 10.dp, vertical = 6.dp),
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        icon(if (active) LiveDesign.accent else LiveDesign.muted)
        Text(
            // iOS collapses " · " to "·" in the tight top-bar pills.
            text = value.replace(" · ", "·"),
            style = chromeStyle(15f, FontWeight.Medium, mono = true),
            color = if (active) LiveDesign.accent else LiveDesign.text,
            maxLines = 1,
        )
    }
}

/** Signal bars + FPS readout capsule (iOS `FPSChip`). */
@Composable
fun FpsChip(signalBars: Int, fps: String) {
    val tint =
        when {
            signalBars >= 3 -> LiveDesign.good
            signalBars == 2 -> LiveDesign.accent
            signalBars == 1 -> LiveDesign.rec
            else -> LiveDesign.faint
        }
    Row(
        modifier = Modifier.chipGlass(CircleShape).padding(horizontal = 11.dp, vertical = 7.dp),
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        SignalBarsGlyph(bars = signalBars, tint = tint)
        Text(
            stringResource(R.string.monitor_fps),
            style = chromeStyle(8f, FontWeight.Bold, mono = true),
            color = LiveDesign.faint,
        )
        Text(
            fps,
            style = chromeStyle(12f, FontWeight.Medium, mono = true),
            color = LiveDesign.text,
        )
    }
}

/**
 * One exposure readout: small label over a large mono value (iOS
 * `CaptureSettingButton`). [widestValue] reserves the cell's width so the bar
 * never shifts when a value changes — the iOS `widestValue` hidden-overlay trick.
 */
@Composable
fun CaptureSettingCell(label: String, value: String, widestValue: String = value) {
    Column(
        modifier = Modifier.padding(vertical = 5.dp, horizontal = 8.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(3.dp),
    ) {
        Text(label, style = chromeStyle(9f, FontWeight.SemiBold), color = LiveDesign.faint)
        Box(contentAlignment = Alignment.Center) {
            Text(
                widestValue,
                style = chromeStyle(19f, FontWeight.Medium, mono = true),
                color = Color.Transparent,
                maxLines = 1,
            )
            Text(
                value,
                style = chromeStyle(19f, FontWeight.Medium, mono = true),
                color = LiveDesign.text,
                maxLines = 1,
            )
        }
    }
}

/**
 * Measures its single child unbounded and scales it down (top-start anchored)
 * to fit [maxWidth] — the shell-level analog of iOS `minimumScaleFactor`, so
 * chrome pills compress instead of wrapping when a band runs tight.
 */
@Composable
fun FitScale(maxWidth: Dp, content: @Composable () -> Unit) {
    Layout(content) { measurables, _ ->
        val placeable = measurables.first().measure(Constraints())
        val maxPx = maxWidth.roundToPx()
        val scale = if (placeable.width > maxPx) maxPx / placeable.width.toFloat() else 1f
        val width = (placeable.width * scale).toInt()
        val height = (placeable.height * scale).toInt()
        layout(width, height) {
            placeable.placeWithLayer(0, 0) {
                scaleX = scale
                scaleY = scale
                transformOrigin = TransformOrigin(0f, 0f)
            }
        }
    }
}

/** Lock toggle: glass rounded square, gold when engaged (iOS `lockButton`). */
@Composable
fun LockButton(locked: Boolean, modifier: Modifier = Modifier, onClick: () -> Unit) {
    val tint = if (locked) LiveDesign.accent else LiveDesign.text.copy(alpha = 0.86f)
    Box(
        modifier =
            modifier
                .glass(ChromeShape)
                .then(
                    if (locked) {
                        Modifier.border(
                            1.5.dp,
                            LiveDesign.accent.copy(alpha = 0.75f),
                            ChromeShape,
                        )
                    } else {
                        Modifier
                    },
                )
                .chromeClickable(onClick),
        contentAlignment = Alignment.Center,
    ) {
        PadlockGlyph(tint = tint, filled = locked, modifier = Modifier.size(13.dp, 17.dp))
    }
}

/** DISP pill: label over mode dashes, the active dash lit (iOS `displayButton`). */
@Composable
fun DispButton(
    activeIndex: Int,
    modeCount: Int,
    isLiveActive: Boolean = activeIndex == 0,
    modifier: Modifier = Modifier,
    onClick: () -> Unit,
) {
    // The operator can reorder modes, so live tint follows typed mode state
    // rather than assuming indicator position zero is always Live.
    val labelColor = if (isLiveActive) LiveDesign.info else LiveDesign.text
    Column(
        modifier = modifier.glass(ChromeShape).chromeClickable(onClick),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Text(
            stringResource(R.string.monitor_disp),
            style = chromeStyle(12f, FontWeight.Bold),
            color = labelColor,
        )
        Row(
            Modifier.padding(top = 3.dp),
            horizontalArrangement = Arrangement.spacedBy(3.dp),
        ) {
            repeat(modeCount) { index ->
                Box(
                    Modifier.size(width = 14.dp, height = 3.dp)
                        .background(
                            if (index == activeIndex) LiveDesign.info
                            else LiveDesign.hairlineStrong,
                            CircleShape,
                        ),
                )
            }
        }
    }
}

/** Round glass auxiliary button (iOS `AssetCircleButton`). */
@Composable
fun AuxCircleButton(
    modifier: Modifier = Modifier,
    onClick: () -> Unit = {},
    glyph: @Composable (Modifier, Color) -> Unit,
) {
    Box(
        modifier = modifier.glass(CircleShape).chromeClickable(onClick),
        contentAlignment = Alignment.Center,
    ) {
        // iOS sizes the asset glyph at 44% of the circle diameter.
        glyph(Modifier.fillMaxSize(0.44f), LiveDesign.text.copy(alpha = 0.86f))
    }
}

/** Record control: red gradient disc, white ring, disc→stop square (iOS `RecordButton`). */
@Composable
fun RecordButton(
    recording: Boolean,
    modifier: Modifier = Modifier,
    onClick: () -> Unit,
    enabled: Boolean = true,
) {
    val actionLabel =
        stringResource(if (recording) R.string.record_action_stop else R.string.record_action_start)
    val recordingState =
        stringResource(
            if (recording) R.string.record_state_recording else R.string.record_state_standby,
        )
    Canvas(
        modifier
            .chromeClickable(enabled = enabled, onClick = onClick)
            .semantics {
                contentDescription = actionLabel
                stateDescription = recordingState
                role = Role.Button
                if (enabled) {
                    semanticsOnClick(label = actionLabel) {
                        onClick()
                        true
                    }
                }
            },
    ) {
        val d = size.minDimension
        val center = Offset(size.width / 2, size.height / 2)
        if (recording) {
            // Approximation of the iOS recording glow shadow.
            drawCircle(LiveDesign.rec.copy(alpha = 0.28f), radius = d * 0.56f, center = center)
        }
        drawCircle(
            brush =
                Brush.radialGradient(
                    colors = listOf(Color(0.88f, 0.28f, 0.30f), LiveDesign.rec),
                    center = Offset(center.x, center.y - d / 2),
                    radius = d * (48f / 72f),
                ),
            radius = d / 2,
            center = center,
        )
        drawCircle(
            Color.White.copy(alpha = 0.17f),
            radius = d / 2 - 1.5.dp.toPx(),
            center = center,
            style = Stroke(width = 3.dp.toPx()),
        )
        if (recording) {
            val side = d * (25f / 72f)
            drawRoundRect(
                LiveDesign.rec,
                topLeft = Offset(center.x - side / 2, center.y - side / 2),
                size = Size(side, side),
                cornerRadius = CornerRadius(8.dp.toPx()),
            )
        } else {
            drawCircle(LiveDesign.rec, radius = d * (58f / 72f) / 2, center = center)
        }
    }
}

/** Battery glyph + authoritative value + device glyph column (iOS `BatteryIndicator`, `.rail`). */
@Composable
fun BatteryIndicatorColumn(
    percent: Int?,
    isCamera: Boolean,
    modifier: Modifier = Modifier,
    externalPower: Boolean? = null,
) {
    val presentation = monitorBatteryPresentation(percent, externalPower)
    val batteryPercent = presentation.percent
    val low = batteryPercent?.let { if (isCamera) it < 10 else it <= 15 } == true
    val tint =
        when {
            low -> Color.Red
            batteryPercent == null && externalPower != true -> LiveDesign.faint
            isCamera -> LiveDesign.accent
            else -> LiveDesign.text.copy(alpha = 0.85f)
        }
    val source =
        stringResource(if (isCamera) R.string.battery_source_camera else R.string.battery_source_phone)
    val description =
        when {
            batteryPercent != null && externalPower == true ->
                stringResource(R.string.battery_description_power, source, batteryPercent)
            batteryPercent != null ->
                stringResource(R.string.battery_description_percent, source, batteryPercent)
            externalPower == true -> stringResource(R.string.battery_description_external, source)
            else -> stringResource(R.string.battery_description_unavailable, source)
        }
    Column(
        modifier = modifier.semantics { contentDescription = description },
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(4.dp, Alignment.CenterVertically),
    ) {
        BatteryGlyph(
            percent = batteryPercent,
            tint = tint,
            modifier = Modifier.size(22.dp, 11.dp),
            externalPower = presentation.externalPower,
        )
        Text(
            presentation.label,
            style = chromeStyle(10.5f, FontWeight.Medium, mono = true),
            color = LiveDesign.text.copy(alpha = 0.72f),
        )
        if (isCamera) {
            CameraGlyph(tint = LiveDesign.muted, modifier = Modifier.size(15.dp, 12.dp))
        } else {
            PhoneGlyph(tint = LiveDesign.muted, modifier = Modifier.size(9.dp, 14.dp))
        }
    }
}

// MARK: - Canvas glyphs (SF Symbol approximations)

/** SF `battery.NNpercent` (horizontal body, quarter-bucket fill), empty when unavailable. */
@Composable
fun BatteryGlyph(
    percent: Int?,
    tint: Color,
    modifier: Modifier = Modifier,
    externalPower: Boolean = false,
) {
    val batteryPercent = validBatteryPercent(percent)
    // iOS buckets the fill at 0/25/50/75/100%.
    val fill =
        when {
            batteryPercent == null || batteryPercent < 13 -> 0f
            batteryPercent < 38 -> 0.25f
            batteryPercent < 63 -> 0.5f
            batteryPercent < 88 -> 0.75f
            else -> 1f
        }
    Canvas(modifier) {
        val bodyWidth = size.width * 0.86f
        val stroke = 1.2.dp.toPx()
        drawRoundRect(
            tint.copy(alpha = 0.6f),
            topLeft = Offset(0f, 0f),
            size = Size(bodyWidth, size.height),
            cornerRadius = CornerRadius(size.height * 0.3f),
            style = Stroke(stroke),
        )
        // Terminal nub.
        drawRoundRect(
            tint.copy(alpha = 0.6f),
            topLeft = Offset(bodyWidth + stroke, size.height * 0.3f),
            size = Size(size.width - bodyWidth - stroke, size.height * 0.4f),
            cornerRadius = CornerRadius(1.dp.toPx()),
        )
        if (fill > 0f) {
            val inset = stroke * 1.8f
            drawRoundRect(
                tint,
                topLeft = Offset(inset, inset),
                size = Size((bodyWidth - 2 * inset) * fill, size.height - 2 * inset),
                cornerRadius = CornerRadius(size.height * 0.18f),
            )
        }
        if (externalPower) {
            drawBatteryPowerMarker(bodyWidth)
        }
    }
}

/** Dark charging bolt with a light keyline, matching iOS's visible powered-state treatment. */
private fun DrawScope.drawBatteryPowerMarker(bodyWidth: Float): Unit {
    val centerX = bodyWidth * 0.5f
    val marker =
        Path().apply {
            moveTo(centerX + size.height * 0.08f, size.height * 0.08f)
            lineTo(centerX - size.height * 0.25f, size.height * 0.53f)
            lineTo(centerX + size.height * 0.02f, size.height * 0.53f)
            lineTo(centerX - size.height * 0.14f, size.height * 0.92f)
            lineTo(centerX + size.height * 0.38f, size.height * 0.42f)
            lineTo(centerX + size.height * 0.11f, size.height * 0.42f)
            close()
        }
    drawPath(
        path = marker,
        color = LiveDesign.text.copy(alpha = 0.92f),
        style = Stroke(width = 0.9.dp.toPx()),
    )
    drawPath(path = marker, color = LiveDesign.background)
}

/** SF `iphone` outline. */
@Composable
fun PhoneGlyph(tint: Color, modifier: Modifier = Modifier) {
    Canvas(modifier) {
        drawRoundRect(
            tint,
            topLeft = Offset.Zero,
            size = size,
            cornerRadius = CornerRadius(size.width * 0.25f),
            style = Stroke(1.2.dp.toPx()),
        )
        drawLine(
            tint,
            start = Offset(size.width * 0.35f, size.height - 2.2.dp.toPx()),
            end = Offset(size.width * 0.65f, size.height - 2.2.dp.toPx()),
            strokeWidth = 1.dp.toPx(),
            cap = StrokeCap.Round,
        )
    }
}

/** SF `camera` outline. */
@Composable
fun CameraGlyph(tint: Color, modifier: Modifier = Modifier) {
    Canvas(modifier) {
        val stroke = 1.2.dp.toPx()
        val bodyTop = size.height * 0.22f
        drawRoundRect(
            tint,
            topLeft = Offset(0f, bodyTop),
            size = Size(size.width, size.height - bodyTop),
            cornerRadius = CornerRadius(size.height * 0.18f),
            style = Stroke(stroke),
        )
        // Viewfinder hump.
        drawLine(
            tint,
            start = Offset(size.width * 0.32f, bodyTop),
            end = Offset(size.width * 0.42f, 0.5f * stroke),
            strokeWidth = stroke,
        )
        drawLine(
            tint,
            start = Offset(size.width * 0.42f, 0.5f * stroke),
            end = Offset(size.width * 0.58f, 0.5f * stroke),
            strokeWidth = stroke,
        )
        drawLine(
            tint,
            start = Offset(size.width * 0.58f, 0.5f * stroke),
            end = Offset(size.width * 0.68f, bodyTop),
            strokeWidth = stroke,
        )
        drawCircle(
            tint,
            radius = size.height * 0.22f,
            center = Offset(size.width / 2, bodyTop + (size.height - bodyTop) / 2),
            style = Stroke(stroke),
        )
    }
}

/** SF `cellularbars` with `variableValue` (filled bars vs dim bars). */
@Composable
fun SignalBarsGlyph(bars: Int, tint: Color, modifier: Modifier = Modifier.size(16.dp, 12.dp)) {
    Canvas(modifier) {
        val barWidth = size.width / 4f * 0.68f
        val gap = size.width / 4f * 0.32f
        for (index in 0 until 4) {
            val height = size.height * (0.35f + 0.65f * index / 3f)
            drawRoundRect(
                if (index < bars) tint else tint.copy(alpha = 0.3f),
                topLeft = Offset(index * (barWidth + gap), size.height - height),
                size = Size(barWidth, height),
                cornerRadius = CornerRadius(barWidth * 0.35f),
            )
        }
    }
}

/** SF `video` (camera body + lens flag). */
@Composable
fun VideoGlyph(tint: Color, modifier: Modifier = Modifier.size(14.dp, 10.dp)) {
    Canvas(modifier) {
        val bodyWidth = size.width * 0.68f
        drawRoundRect(
            tint,
            topLeft = Offset.Zero,
            size = Size(bodyWidth, size.height),
            cornerRadius = CornerRadius(size.height * 0.28f),
        )
        val path =
            Path().apply {
                moveTo(bodyWidth + size.width * 0.06f, size.height * 0.5f)
                lineTo(size.width, size.height * 0.12f)
                lineTo(size.width, size.height * 0.88f)
                close()
            }
        drawPath(path, tint)
    }
}

/** SF `film` (frame + sprocket columns). */
@Composable
fun FilmGlyph(tint: Color, modifier: Modifier = Modifier.size(12.dp, 11.dp)) {
    Canvas(modifier) {
        val stroke = 1.1.dp.toPx()
        drawRoundRect(
            tint,
            topLeft = Offset.Zero,
            size = size,
            cornerRadius = CornerRadius(size.height * 0.14f),
            style = Stroke(stroke),
        )
        val inset = size.width * 0.22f
        drawLine(tint, Offset(inset, 0f), Offset(inset, size.height), stroke)
        drawLine(
            tint,
            Offset(size.width - inset, 0f),
            Offset(size.width - inset, size.height),
            stroke,
        )
        drawLine(
            tint,
            Offset(inset, size.height / 2),
            Offset(size.width - inset, size.height / 2),
            stroke * 0.8f,
        )
    }
}

/** SF `sdcard` (card outline with a clipped corner). */
@Composable
fun SdCardGlyph(tint: Color, modifier: Modifier = Modifier.size(9.dp, 12.dp)) {
    Canvas(modifier) {
        val cut = size.width * 0.34f
        val r = size.width * 0.18f
        val path =
            Path().apply {
                moveTo(cut, 0f)
                lineTo(size.width - r, 0f)
                quadraticTo(size.width, 0f, size.width, r)
                lineTo(size.width, size.height - r)
                quadraticTo(size.width, size.height, size.width - r, size.height)
                lineTo(r, size.height)
                quadraticTo(0f, size.height, 0f, size.height - r)
                lineTo(0f, cut)
                close()
            }
        drawPath(path, tint, style = Stroke(1.1.dp.toPx()))
    }
}

/** SF `lock` / `lock.fill` (shackle + body). */
@Composable
fun PadlockGlyph(tint: Color, filled: Boolean, modifier: Modifier = Modifier) {
    Canvas(modifier) {
        val stroke = 1.6.dp.toPx()
        // SF proportions: near-square body on the lower ~55%, a tall narrow
        // shackle on top.
        val bodyTop = size.height * 0.45f
        val bodyInset = size.width * 0.08f
        val shackleWidth = size.width * 0.48f
        drawArc(
            tint,
            startAngle = 180f,
            sweepAngle = 180f,
            useCenter = false,
            topLeft = Offset((size.width - shackleWidth) / 2, stroke / 2),
            size = Size(shackleWidth, (bodyTop - stroke / 2) * 2f),
            style = Stroke(stroke),
        )
        val bodyRect = Rect(bodyInset, bodyTop, size.width - bodyInset, size.height)
        drawRoundRect(
            tint,
            topLeft = bodyRect.topLeft,
            size = bodyRect.size,
            cornerRadius = CornerRadius(size.width * 0.16f),
            style = if (filled) androidx.compose.ui.graphics.drawscope.Fill else Stroke(stroke),
        )
    }
}

/** iOS `IconSettings` (gearshape) stand-in. */
@Composable
fun GearGlyph(tint: Color, modifier: Modifier = Modifier) {
    Canvas(modifier) {
        val stroke = 2.dp.toPx()
        val center = Offset(size.width / 2, size.height / 2)
        val outer = size.minDimension / 2 - stroke / 2
        val ring = outer * 0.68f
        drawCircle(tint, radius = ring, center = center, style = Stroke(stroke))
        drawCircle(tint, radius = ring * 0.4f, center = center, style = Stroke(stroke * 0.85f))
        repeat(8) { index ->
            val angle = Math.toRadians(index * 45.0 + 22.5)
            val dir = Offset(kotlin.math.cos(angle).toFloat(), kotlin.math.sin(angle).toFloat())
            drawLine(
                tint,
                start = center + dir * (ring - stroke / 2),
                end = center + dir * outer,
                strokeWidth = stroke * 1.6f,
                cap = StrokeCap.Round,
            )
        }
    }
}

/** iOS `IconMedia` (film-frame) stand-in: rounded frame + sprocket columns. */
@Composable
fun MediaStackGlyph(tint: Color, modifier: Modifier = Modifier) {
    Canvas(modifier) {
        val stroke = 1.8.dp.toPx()
        drawRoundRect(
            tint,
            topLeft = Offset(stroke / 2, stroke / 2),
            size = Size(size.width - stroke, size.height - stroke),
            cornerRadius = CornerRadius(size.height * 0.2f),
            style = Stroke(stroke),
        )
        // Sprocket columns: two filled holes down each side.
        val holeW = size.width * 0.12f
        val holeH = size.height * 0.16f
        for (side in listOf(size.width * 0.16f, size.width * 0.84f - holeW)) {
            for (row in listOf(size.height * 0.24f, size.height * 0.6f)) {
                drawRoundRect(
                    tint,
                    topLeft = Offset(side, row),
                    size = Size(holeW, holeH),
                    cornerRadius = CornerRadius(holeW * 0.4f),
                )
            }
        }
        // Center pane divider lines framing the picture area.
        val paneInset = size.width * 0.34f
        drawLine(
            tint,
            Offset(paneInset, stroke),
            Offset(paneInset, size.height - stroke),
            stroke * 0.8f,
        )
        drawLine(
            tint,
            Offset(size.width - paneInset, stroke),
            Offset(size.width - paneInset, size.height - stroke),
            stroke * 0.8f,
        )
    }
}

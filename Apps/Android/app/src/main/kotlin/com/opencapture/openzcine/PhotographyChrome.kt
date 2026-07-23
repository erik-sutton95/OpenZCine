package com.opencapture.openzcine

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.opencapture.openzcine.bridge.ZoneFrame
import com.opencapture.openzcine.core.CameraPropertySnapshot
import java.util.Locale

/**
 * Photography capture strip when the body reports photo mode (iOS
 * `MonitorCaptureStrip` while `isPhotography`): the SAME glass pill, cell
 * shape, and typography as the cinema capture strip, rendering the stills
 * readouts MODE/ISO/SHUTTER/IRIS/DRIVE/FOCUS/WB/METER. Stills pickers
 * are still stubs, so every tile
 * routes to [onOpenControl] with its label instead of a drum picker.
 */
@Composable
internal fun PhotographyCaptureStrip(
    properties: CameraPropertySnapshot,
    onOpenControl: (String) -> Unit,
    modifier: Modifier = Modifier,
    maxContentWidth: Dp? = null,
    /**
     * Publishes the glass pill's root bounds in dp (iOS `captureBarFrame`),
     * matching the cinema strip's reporting contract.
     */
    onBarBoundsInRoot: ((ZoneFrame) -> Unit)? = null,
) {
    val density = LocalDensity.current
    // Same 58dp glass shell as MonitorCaptureStrip so the two bottom bars
    // always align; when a width budget is given, only the CELLS scale down.
    Box(
        modifier =
            modifier
                .height(LiveDesign.CONTROL_HEIGHT_DP.dp)
                .glass(ChromeShape)
                .then(
                    if (onBarBoundsInRoot != null) {
                        Modifier.onGloballyPositioned { coords ->
                            val b = coords.boundsInRoot()
                            with(density) {
                                onBarBoundsInRoot(
                                    ZoneFrame(
                                        x = b.left.toDp().value,
                                        y = b.top.toDp().value,
                                        width = b.width.toDp().value,
                                        height = b.height.toDp().value,
                                    ),
                                )
                            }
                        }
                    } else {
                        Modifier
                    },
                )
                .padding(horizontal = 12.dp, vertical = 4.dp),
        contentAlignment = Alignment.CenterStart,
    ) {
        val cells: @Composable () -> Unit = {
            PhotographyStripCells(
                properties = properties,
                onOpenControl = onOpenControl,
            )
        }
        if (maxContentWidth != null) {
            FitScale(maxContentWidth - 24.dp) { cells() }
        } else {
            cells()
        }
    }
}

@Composable
private fun PhotographyStripCells(
    properties: CameraPropertySnapshot,
    onOpenControl: (String) -> Unit,
) {
    Row(
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        photographyStripTiles(properties).forEach { tile ->
            Box(
                Modifier
                    .chromeClickable { onOpenControl(tile.label) }
                    .semantics(mergeDescendants = true) {
                        contentDescription = "${tile.label} ${tile.value}"
                    },
            ) {
                CaptureSettingCell(
                    label = tile.label,
                    value = tile.value,
                    widestValue = tile.widestValue,
                    active = false,
                    controlLocked = false,
                    // WB presets render as icons like the movie tile; Kelvin stays numeric.
                    wbIcon = if (tile.label == "WB") captureBarWbIcon(tile.value) else null,
                )
            }
        }
    }
}

/** One stills readout in the shared capture-cell shape. */
private data class PhotographyStripTile(
    val label: String,
    val value: String,
    val widestValue: String,
)

/** iOS `photographyCaptureValues`: same tiles, same order, same width pins. */
private fun photographyStripTiles(
    properties: CameraPropertySnapshot,
): List<PhotographyStripTile> =
    listOf(
        PhotographyStripTile("MODE", properties.exposureMode ?: "—", "Auto"),
        PhotographyStripTile("ISO", properties.iso?.toString() ?: "—", "25600"),
        PhotographyStripTile("SHUTTER", properties.shutterSpeed ?: "—", "1/16000"),
        PhotographyStripTile("IRIS", properties.iris ?: "—", "f/2.8"),
        PhotographyStripTile("DRIVE", compactDriveLabel(properties.stillCaptureMode) ?: "—", "Single"),
        PhotographyStripTile("FOCUS", properties.focusMode ?: "—", "Wide-L"),
        PhotographyStripTile("WB", stillWhiteBalanceValue(properties), "5560K"),
        PhotographyStripTile("METER", properties.meteringMode ?: "—", "Matrix"),
    )

/** Drive-mode label compacted to strip width ("Continuous H" → "CH"). */
private fun compactDriveLabel(stillCaptureMode: String?): String? =
    when (stillCaptureMode) {
        null -> null
        "Continuous H" -> "CH"
        "Continuous L" -> "CL"
        "Continuous H+" -> "CH+"
        "Self-timer" -> "Timer"
        else -> stillCaptureMode
    }

/**
 * WB tile readout (iOS `stillWhiteBalanceValue`): the Kelvin figure while in
 * colour-temperature mode, else the preset name (presets render as icons in
 * the strip, like the movie tile).
 */
internal fun stillWhiteBalanceValue(properties: CameraPropertySnapshot): String {
    val kelvin = properties.whiteBalanceKelvin
    if (properties.whiteBalanceMode == "Color temp" && kelvin != null) return "${kelvin}K"
    return properties.whiteBalanceMode ?: "—"
}

/** Quality label compacted to strip width ("RAW+JPEG Fine★" → "R+JF★"). */
internal fun CameraPropertySnapshot.stillQualityCompactLabel(): String? {
    val compression = compression ?: return imageSize
    if (compression.startsWith("RAW+JPEG")) {
        val suffix = compression.drop("RAW+JPEG ".length)
        val letter = suffix.firstOrNull()?.toString() ?: ""
        val star = if (suffix.endsWith("★")) "★" else ""
        return "R+J$letter$star"
    }
    if (compression.startsWith("JPEG")) {
        val suffix = compression.drop("JPEG ".length)
        val letter = suffix.firstOrNull()?.toString() ?: ""
        val star = if (suffix.endsWith("★")) "★" else ""
        return "JPG $letter$star"
    }
    return compression
}

/** Image-size label compacted for the photo top bar ("Size L" → "L"). */
internal fun CameraPropertySnapshot.stillSizeCompactLabel(): String? =
    imageSize?.replace("Size ", "")

/** iOS stub feedback for a not-yet-implemented photography control. */
internal fun photographyControlStubMessage(label: String): String {
    val capitalized =
        label.lowercase(Locale.ROOT).replaceFirstChar { it.titlecase(Locale.ROOT) }
    return "$capitalized control — coming next in photography mode."
}

/**
 * Frames left on the card, in the timecode slot's typography (iOS
 * `ShotsRemainingReadout`). Counts above four digits compact to "12.3k" the
 * way camera bodies do.
 */
@Composable
internal fun ShotsRemainingReadout(shotsRemaining: Int?, modifier: Modifier = Modifier) {
    val label = shotsRemaining?.let(::shotsRemainingCompactLabel) ?: "—"
    Text(
        buildAnnotatedString {
            withStyle(SpanStyle(color = LiveDesign.text)) { append(label) }
            withStyle(
                SpanStyle(
                    color = LiveDesign.muted,
                    fontSize = 12.sp,
                    fontWeight = FontWeight.SemiBold,
                ),
            ) { append(" SHOTS") }
        },
        style = chromeStyle(20f, FontWeight.Medium, mono = true),
        maxLines = 1,
        softWrap = false,
        modifier = modifier,
    )
}

/** "1234" up to four digits, "12.3k" beyond, like the camera's own counter. */
internal fun shotsRemainingCompactLabel(count: Int): String =
    if (count > 9999) {
        String.format(Locale.ROOT, "%.1fk", count / 1000.0)
    } else {
        count.toString()
    }

/** System-rail still shutter (replaces the red record control in photography mode). */
@Composable
internal fun PhotographyShutterButton(
    isCapturing: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
) {
    Box(
        modifier
            .size(54.dp)
            .clip(CircleShape)
            .border(3.dp, Color.White.copy(alpha = 0.92f), CircleShape)
            .clickable(enabled = enabled && !isCapturing, onClick = onClick)
            .semantics {
                contentDescription = if (isCapturing) "Capturing" else "Shutter"
            },
        contentAlignment = Alignment.Center,
    ) {
        Box(
            Modifier
                .size(42.dp)
                .clip(CircleShape)
                .background(if (isCapturing) Color.White.copy(alpha = 0.5f) else Color.White),
        )
    }
}

/** Whether the shell should show photography chrome for this snapshot. */
internal fun prefersPhotographyChrome(properties: CameraPropertySnapshot): Boolean =
    properties.captureSelector.equals("photo", ignoreCase = true)

/** SF `photo` stand-in: rounded frame, sun dot, mountain line. */
@Composable
internal fun PhotoGlyph(tint: Color, modifier: Modifier = Modifier) {
    Canvas(modifier) {
        val stroke = 1.2.dp.toPx()
        drawRoundRect(
            tint,
            topLeft = Offset(stroke / 2, stroke / 2),
            size = androidx.compose.ui.geometry.Size(
                size.width - stroke,
                size.height - stroke,
            ),
            cornerRadius = CornerRadius(size.height * 0.2f),
            style = Stroke(stroke),
        )
        drawCircle(
            tint,
            radius = size.height * 0.10f,
            center = Offset(size.width * 0.30f, size.height * 0.32f),
        )
        val mountains =
            Path().apply {
                moveTo(size.width * 0.14f, size.height * 0.76f)
                lineTo(size.width * 0.40f, size.height * 0.42f)
                lineTo(size.width * 0.56f, size.height * 0.60f)
                lineTo(size.width * 0.70f, size.height * 0.48f)
                lineTo(size.width * 0.86f, size.height * 0.76f)
            }
        drawPath(
            mountains,
            tint,
            style = Stroke(stroke, cap = StrokeCap.Round, join = StrokeJoin.Round),
        )
    }
}

/** SF `camera.aperture` stand-in: ring with six blade strokes. */
@Composable
internal fun ApertureGlyph(tint: Color, modifier: Modifier = Modifier) {
    Canvas(modifier) {
        val stroke = 1.2.dp.toPx()
        val center = Offset(size.width / 2f, size.height / 2f)
        val radius = size.minDimension / 2f - stroke / 2f
        drawCircle(tint, radius = radius, center = center, style = Stroke(stroke))
        repeat(6) { index ->
            val outerAngle = Math.toRadians(index * 60.0)
            val innerAngle = Math.toRadians(index * 60.0 + 55.0)
            val outer =
                center +
                    Offset(
                        kotlin.math.cos(outerAngle).toFloat(),
                        kotlin.math.sin(outerAngle).toFloat(),
                    ) * radius
            val inner =
                center +
                    Offset(
                        kotlin.math.cos(innerAngle).toFloat(),
                        kotlin.math.sin(innerAngle).toFloat(),
                    ) * (radius * 0.42f)
            drawLine(tint, start = outer, end = inner, strokeWidth = stroke, cap = StrokeCap.Round)
        }
    }
}

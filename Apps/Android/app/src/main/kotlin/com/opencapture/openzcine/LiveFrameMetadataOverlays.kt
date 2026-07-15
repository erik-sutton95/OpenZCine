package com.opencapture.openzcine

import android.content.Context
import android.graphics.Paint
import android.graphics.Typeface
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.rotate
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.opencapture.openzcine.core.LiveCameraLevel
import com.opencapture.openzcine.core.LiveFocusBox
import com.opencapture.openzcine.core.LiveFocusInfo
import com.opencapture.openzcine.core.LiveFocusResult
import com.opencapture.openzcine.settings.LocalFramingAssistConfiguration
import com.opencapture.openzcine.settings.LocalLevelStyle
import java.util.Locale
import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.sqrt

/** A floating-point feed-local rectangle used by focus and level overlay math. */
internal data class LiveOverlayRect(
    val left: Float,
    val top: Float,
    val width: Float,
    val height: Float,
) {
    val right: Float get() = left + width
    val bottom: Float get() = top + height
    val centerX: Float get() = left + width / 2f
    val centerY: Float get() = top + height / 2f
}

/** Intersects two overlay rectangles, returning null when they do not overlap. */
internal fun intersectLiveOverlayRects(
    first: LiveOverlayRect,
    second: LiveOverlayRect,
): LiveOverlayRect? {
    val left = maxOf(first.left, second.left)
    val top = maxOf(first.top, second.top)
    val right = minOf(first.right, second.right)
    val bottom = minOf(first.bottom, second.bottom)
    if (right <= left || bottom <= top) return null
    return LiveOverlayRect(left = left, top = top, width = right - left, height = bottom - top)
}

/** Source label for an on-screen level reading. */
internal enum class LiveLevelSource {
    CAMERA,
    DEVICE_GRAVITY,
}

/** One display-ready level reading with explicit provenance. */
internal data class LiveLevelReading(
    val rollDegrees: Double,
    val pitchDegrees: Double,
    val source: LiveLevelSource,
    val isDebugFixture: Boolean,
    val deviceTiltProvenance: DeviceTiltProvenance? = null,
)

/** How the monitor derived a fallback from the phone rather than from the camera. */
internal enum class DeviceTiltProvenance(
    val visibleLabel: String,
    val accessibilityLabel: String,
) {
    /** Android's fused gravity sensor supplied the device-vector directly. */
    GRAVITY_SENSOR("DEVICE GRAVITY", "device gravity sensor"),
    /** A normalized, low-pass accelerometer vector approximated device tilt. */
    ACCELEROMETER_LOW_PASS("DEVICE TILT", "device tilt from low-pass accelerometer"),
}

/** Normalized device-vector sample used by the accelerometer fallback. */
internal data class DeviceTiltVector(
    val x: Float,
    val y: Float,
    val z: Float,
)

/** Device-derived fallback values before they receive an on-screen provenance label. */
internal data class DeviceGravityLevel(
    val rollDegrees: Double,
    val pitchDegrees: Double,
    val provenance: DeviceTiltProvenance = DeviceTiltProvenance.GRAVITY_SENSOR,
)

/** Pixel metrics for the iOS-matched two-axis level gauge. */
internal data class LiveGaugeMetrics(
    val landscapeRollLift: Float,
    val portraitRollLift: Float,
    val trailingInset: Float,
    val chromeClearance: Float,
    val axisSpan: Float,
    val maxAngleDegrees: Double,
    val tickStepDegrees: Double,
    val levelThresholdDegrees: Double,
    val baselineStrokeWidth: Float,
    val centerTickHalfLength: Float,
    val tickHalfLength: Float,
    val tickStrokeWidth: Float,
    val beadRadius: Float,
    val beadStrokeWidth: Float,
    val chevronGap: Float,
    val chevronStep: Float,
    val chevronHalfSize: Float,
    val chevronStrokeWidth: Float,
    val readoutOffset: Float,
    val verticalReadoutOffset: Float,
    val readoutTextSize: Float,
)

/** The two track centres for the operator-facing level gauge. */
internal data class LiveGaugeSeats(
    val roll: Offset,
    val pitch: Offset,
)

/**
 * Seats the gauge against the visible part of the feed, not against an
 * off-screen de-squeezed overhang. The landscape roll track clears the bottom
 * monitor chrome; portrait adds an explicit capture-strip clearance.
 */
internal fun liveGaugeSeats(
    feed: LiveOverlayRect,
    visibleBounds: LiveOverlayRect,
    isPortrait: Boolean,
    bottomChromeInset: Float,
    metrics: LiveGaugeMetrics,
): LiveGaugeSeats {
    val visible = intersectLiveOverlayRects(feed, visibleBounds) ?: feed
    val rollLift =
        if (isPortrait) {
            metrics.portraitRollLift + maxOf(0f, bottomChromeInset)
        } else {
            maxOf(
                metrics.landscapeRollLift,
                maxOf(0f, bottomChromeInset) + metrics.beadRadius + metrics.chromeClearance,
            )
        }
    return LiveGaugeSeats(
        roll = Offset(visible.centerX, visible.bottom - rollLift),
        pitch = Offset(maxOf(visible.left, visible.right - metrics.trailingInset), visible.centerY),
    )
}

/**
 * Computes the visual feed rectangle after the monitor's local de-squeeze
 * transform. The input is the same integer aspect-fit rectangle
 * used by [LiveFeedView], never the broader monitor zone map.
 */
internal fun liveOverlayFeedRect(
    content: LiveFeedContentRect,
    horizontalPresentationScale: Float,
    verticalPresentationScale: Float = 1f,
): LiveOverlayRect? {
    if (horizontalPresentationScale <= 0f || !horizontalPresentationScale.isFinite()) return null
    if (verticalPresentationScale <= 0f || !verticalPresentationScale.isFinite()) return null
    val scaledWidth = content.width * horizontalPresentationScale
    val scaledHeight = content.height * verticalPresentationScale
    if (scaledWidth <= 0f || scaledHeight <= 0f) return null
    return LiveOverlayRect(
        left = content.left + (content.width - scaledWidth) / 2f,
        top = content.top + (content.height - scaledHeight) / 2f,
        width = scaledWidth,
        height = scaledHeight,
    )
}

/** Maps one camera-coordinate AF box into [feed]'s actual visible image rect. */
internal fun liveFocusBoxRect(
    focus: LiveFocusInfo,
    box: LiveFocusBox,
    feed: LiveOverlayRect,
): LiveOverlayRect? {
    if (
        focus.coordinateWidth <= 0 ||
            focus.coordinateHeight <= 0 ||
            box.width <= 0 ||
            box.height <= 0 ||
            feed.width <= 0f ||
            feed.height <= 0f
    ) {
        return null
    }
    val scaleX = feed.width / focus.coordinateWidth
    val scaleY = feed.height / focus.coordinateHeight
    val width = box.width * scaleX
    val height = box.height * scaleY
    return LiveOverlayRect(
        left = feed.left + box.centerX * scaleX - width / 2f,
        top = feed.top + box.centerY * scaleY - height / 2f,
        width = width,
        height = height,
    )
}

/** Prefers a valid camera horizon and uses gravity only when the frame lacks one. */
internal fun resolveLiveLevel(
    camera: LiveCameraLevel?,
    deviceGravity: DeviceGravityLevel?,
): LiveLevelReading? {
    if (camera != null && camera.rollDegrees.isFinite() && camera.pitchDegrees.isFinite()) {
        return LiveLevelReading(
            rollDegrees = camera.rollDegrees,
            pitchDegrees = camera.pitchDegrees,
            source = LiveLevelSource.CAMERA,
            isDebugFixture = camera.isDebugFixture,
        )
    }
    if (deviceGravity != null && deviceGravity.rollDegrees.isFinite() && deviceGravity.pitchDegrees.isFinite()) {
        return LiveLevelReading(
            rollDegrees = deviceGravity.rollDegrees,
            pitchDegrees = deviceGravity.pitchDegrees,
            source = LiveLevelSource.DEVICE_GRAVITY,
            isDebugFixture = false,
            deviceTiltProvenance = deviceGravity.provenance,
        )
    }
    return null
}

/** Accessible provenance copy that never lets debug fixtures masquerade as camera telemetry. */
internal fun liveLevelAccessibilityDescription(
    reading: LiveLevelReading,
    style: LocalLevelStyle,
): String =
    if (reading.source == LiveLevelSource.CAMERA) {
        if (reading.isDebugFixture) {
            "Debug fixture level, not camera metadata, ${style.label.lowercase()}"
        } else {
            "Camera virtual horizon, ${style.label.lowercase()}"
        }
    } else {
        "${reading.deviceTiltProvenance?.accessibilityLabel ?: "device tilt"} fallback, ${style.label.lowercase()}"
    }

/** Gravity-vector conversion matching the iOS portrait/landscape display mapping. */
internal fun deviceGravityLevel(
    gravityX: Float,
    gravityY: Float,
    gravityZ: Float,
    isPortrait: Boolean,
    provenance: DeviceTiltProvenance = DeviceTiltProvenance.GRAVITY_SENSOR,
): DeviceGravityLevel? {
    val x = gravityX.toDouble()
    val y = gravityY.toDouble()
    val z = gravityZ.toDouble()
    if (!x.isFinite() || !y.isFinite() || !z.isFinite()) return null
    val rollRadians = if (isPortrait) atan2(x, -y) else atan2(-y, -x)
    val pitchRadians = atan2(z, sqrt(x * x + y * y))
    return DeviceGravityLevel(
        rollDegrees = Math.toDegrees(rollRadians),
        pitchDegrees = Math.toDegrees(pitchRadians),
        provenance = provenance,
    )
}

/** Normalizes a raw sensor vector so a low-pass filter tracks tilt direction, not acceleration magnitude. */
internal fun normalizedDeviceTiltVector(x: Float, y: Float, z: Float): DeviceTiltVector? {
    if (!x.isFinite() || !y.isFinite() || !z.isFinite()) return null
    val magnitude = sqrt((x * x + y * y + z * z).toDouble()).toFloat()
    if (!magnitude.isFinite() || magnitude <= DEVICE_TILT_MINIMUM_MAGNITUDE) return null
    return DeviceTiltVector(x = x / magnitude, y = y / magnitude, z = z / magnitude)
}

/**
 * Smooths an accelerometer sample into a normalized device-tilt vector.
 *
 * This is only an explicitly labelled fallback for devices such as the
 * SM-A127F that do not expose [Sensor.TYPE_GRAVITY]; it never replaces a
 * camera virtual-horizon value.
 */
internal fun lowPassDeviceTilt(
    previous: DeviceTiltVector?,
    sampleX: Float,
    sampleY: Float,
    sampleZ: Float,
    retention: Float = DEVICE_TILT_LOW_PASS_RETENTION,
): DeviceTiltVector? {
    if (!retention.isFinite() || retention !in 0f..1f) return null
    val sample = normalizedDeviceTiltVector(sampleX, sampleY, sampleZ) ?: return null
    val prior = previous ?: return sample
    val incomingWeight = 1f - retention
    return normalizedDeviceTiltVector(
        x = prior.x * retention + sample.x * incomingWeight,
        y = prior.y * retention + sample.y * incomingWeight,
        z = prior.z * retention + sample.z * incomingWeight,
    )
}

/**
 * Focus boxes and level instrument mounted over the visible image rectangle.
 * Camera metadata follows the decoded frame through [LiveFeedPresentationState]
 * so latest-wins feed pacing cannot mismatch overlay state and JPEG pixels.
 */
@Composable
internal fun LiveFrameMetadataOverlay(
    presentationState: LiveFeedPresentationState,
    configuration: LocalFramingAssistConfiguration,
    cleanMode: Boolean,
    isPortrait: Boolean,
    /** Local-pixel height of monitor chrome covering the feed's bottom edge. */
    gaugeBottomChromeInset: Float = 0f,
    modifier: Modifier = Modifier,
) {
    val cameraLevel = presentationState.level
    val levelEnabled = configuration.levelEnabled && !cleanMode
    val cameraLevelAvailable = cameraLevel?.let(::cameraLevelIsValid) == true
    val deviceGravity =
        rememberDeviceGravityLevel(
            enabled = levelEnabled && !cameraLevelAvailable,
            isPortrait = isPortrait,
        )
    val level = resolveLiveLevel(cameraLevel, deviceGravity)

    BoxWithConstraints(modifier.fillMaxSize()) {
        val density = LocalDensity.current
        val viewport =
            with(density) {
                LiveOverlayRect(
                    left = 0f,
                    top = 0f,
                    width = maxWidth.toPx(),
                    height = maxHeight.toPx(),
                )
            }
        val content =
            with(density) {
                liveFeedContentRect(
                    containerWidth = maxWidth.toPx(),
                    containerHeight = maxHeight.toPx(),
                    sourceWidth = presentationState.sourceWidth,
                    sourceHeight = presentationState.sourceHeight,
                )
            }
        val feed =
            content?.let {
                liveOverlayFeedRect(
                    content = it,
                    horizontalPresentationScale = configuration.horizontalPresentationScale,
                    verticalPresentationScale = configuration.verticalPresentationScale,
                )
            }
        if (feed != null) {
            val debugFixtureShown =
                presentationState.focus?.isDebugFixture == true ||
                    presentationState.level?.isDebugFixture == true
            CameraFocusOverlay(focus = presentationState.focus, feed = feed)
            if (levelEnabled) {
                CameraLevelOverlay(
                    reading = level,
                    style = configuration.levelStyle,
                    feed = feed,
                    visibleBounds = viewport,
                    isPortrait = isPortrait,
                    bottomChromeInset = gaugeBottomChromeInset,
                    debugFixtureShown = debugFixtureShown,
                )
            }
            DebugMetadataBadge(show = debugFixtureShown, feed = feed)
        }
    }
}

@Composable
private fun CameraFocusOverlay(focus: LiveFocusInfo?, feed: LiveOverlayRect) {
    if (focus == null || focus.boxes.isEmpty()) return
    val description = focus.accessibilityDescription()
    Canvas(
        Modifier
            .fillMaxSize()
            .clearAndSetSemantics { contentDescription = description },
    ) {
        focus.boxes.forEachIndexed { index, box ->
            val rect = liveFocusBoxRect(focus, box, feed) ?: return@forEachIndexed
            val color = focusBoxColor(focus, index)
            val radius = min(min(rect.width, rect.height) * 0.12f, 7.dp.toPx())
            drawRoundRect(
                color = color,
                topLeft = Offset(rect.left, rect.top),
                size = Size(rect.width, rect.height),
                cornerRadius = CornerRadius(radius, radius),
                style = Stroke(width = 1.5.dp.toPx(), cap = StrokeCap.Round, join = StrokeJoin.Round),
            )
        }
    }
}

@Composable
private fun CameraLevelOverlay(
    reading: LiveLevelReading?,
    style: LocalLevelStyle,
    feed: LiveOverlayRect,
    visibleBounds: LiveOverlayRect,
    isPortrait: Boolean,
    bottomChromeInset: Float,
    debugFixtureShown: Boolean,
) {
    if (reading == null) return
    val density = LocalDensity.current
    val gaugeMetrics =
        with(density) {
            LiveGaugeMetrics(
                landscapeRollLift = 104.dp.toPx(),
                portraitRollLift = 30.dp.toPx(),
                trailingInset = 44.dp.toPx(),
                chromeClearance = 8.dp.toPx(),
                axisSpan = 84.dp.toPx(),
                maxAngleDegrees = 8.0,
                tickStepDegrees = 2.0,
                levelThresholdDegrees = 0.6,
                baselineStrokeWidth = 2.dp.toPx(),
                centerTickHalfLength = 9.dp.toPx(),
                tickHalfLength = 5.dp.toPx(),
                tickStrokeWidth = 1.dp.toPx(),
                beadRadius = 6.5.dp.toPx(),
                beadStrokeWidth = 2.dp.toPx(),
                chevronGap = 16.dp.toPx(),
                chevronStep = 8.dp.toPx(),
                chevronHalfSize = 3.dp.toPx(),
                chevronStrokeWidth = 1.5.dp.toPx(),
                readoutOffset = 24.dp.toPx(),
                verticalReadoutOffset = 42.dp.toPx(),
                readoutTextSize = 11.sp.toPx(),
            )
        }
    val readoutPaint =
        remember {
            Paint(Paint.ANTI_ALIAS_FLAG).apply {
                typeface = Typeface.create(Typeface.MONOSPACE, Typeface.BOLD)
                textAlign = Paint.Align.CENTER
            }
        }
    val description = liveLevelAccessibilityDescription(reading, style)
    Box(Modifier.fillMaxSize().clearAndSetSemantics { contentDescription = description }) {
        Canvas(Modifier.fillMaxSize()) {
            when (style) {
                LocalLevelStyle.HORIZON -> drawHorizonLevel(reading, feed)
                LocalLevelStyle.GAUGE ->
                    drawGaugeLevel(
                        reading = reading,
                        feed = feed,
                        visibleBounds = visibleBounds,
                        isPortrait = isPortrait,
                        bottomChromeInset = bottomChromeInset,
                        metrics = gaugeMetrics,
                        readoutPaint = readoutPaint,
                    )
            }
        }
        if (reading.source == LiveLevelSource.DEVICE_GRAVITY) {
            androidx.compose.material3.Text(
                text = reading.deviceTiltProvenance?.visibleLabel ?: "DEVICE TILT",
                style = chromeStyle(9.5f, FontWeight.Bold, mono = true),
                color = LiveDesign.muted,
                modifier =
                    Modifier
                        .offset {
                            metadataBadgeOffset(
                                feed = feed,
                                density = density,
                                extraVerticalOffset = if (debugFixtureShown) 30.dp else 0.dp,
                            )
                        }
                        .background(LiveDesign.background.copy(alpha = 0.76f), ChromeShape)
                        .padding(horizontal = 6.dp, vertical = 3.dp),
            )
        }
    }
}

@Composable
private fun DebugMetadataBadge(show: Boolean, feed: LiveOverlayRect) {
    if (!show) return
    val density = LocalDensity.current
    androidx.compose.material3.Text(
        text = "DEBUG FIXTURE — NOT CAMERA METADATA",
        style = chromeStyle(9.5f, FontWeight.Bold, mono = true),
        color = LiveDesign.text,
        modifier =
            Modifier
                .offset { metadataBadgeOffset(feed = feed, density = density) }
                .background(LiveDesign.background.copy(alpha = 0.76f), ChromeShape)
                .padding(horizontal = 6.dp, vertical = 3.dp),
    )
}

/** Keeps provenance badges below the top info deck without relying on screen-global geometry. */
private fun metadataBadgeOffset(
    feed: LiveOverlayRect,
    density: androidx.compose.ui.unit.Density,
    extraVerticalOffset: androidx.compose.ui.unit.Dp = 0.dp,
): IntOffset =
    with(density) {
        val inset = 8.dp.roundToPx()
        val topBadgeOffset = 92.dp.roundToPx().toFloat()
        IntOffset(
            x = (feed.left + inset).roundToInt(),
            y =
                (
                    maxOf(feed.top + inset, feed.top + minOf(feed.height * 0.2f, topBadgeOffset)) +
                        extraVerticalOffset.toPx()
                    ).roundToInt(),
        )
    }

private fun cameraLevelIsValid(level: LiveCameraLevel): Boolean =
    level.rollDegrees.isFinite() && level.pitchDegrees.isFinite()

private fun focusBoxColor(focus: LiveFocusInfo, index: Int): Color =
    when {
        index > 0 -> LiveDesign.good
        focus.result == LiveFocusResult.FOCUSED || focus.trackingAFActive -> LiveDesign.good
        else -> Color.White.copy(alpha = 0.72f)
    }

/** Accessible focus copy that distinguishes debug fixtures from camera metadata. */
internal fun LiveFocusInfo.accessibilityDescription(): String {
    val state =
        when (result) {
            LiveFocusResult.FOCUSED -> "focused"
            LiveFocusResult.NOT_FOCUSED -> "not focused"
            LiveFocusResult.UNKNOWN -> "focus state unknown"
        }
    val subject = if (subjectDetectionActive) "Subject detection active." else ""
    val tracking = if (trackingAFActive) " Tracking active." else ""
    val origin =
        if (isDebugFixture) {
            "Debug focus fixture, not camera focus data."
        } else {
            "Camera focus overlay."
        }
    return "$origin ${boxes.size} boxes. $state. $subject$tracking"
}

private fun androidx.compose.ui.graphics.drawscope.DrawScope.drawHorizonLevel(
    reading: LiveLevelReading,
    feed: LiveOverlayRect,
) {
    val color = if (abs(reading.rollDegrees) < HORIZON_LEVEL_TOLERANCE_DEGREES) LiveDesign.good else LiveDesign.accent
    val center = Offset(feed.centerX, feed.centerY)
    val wing = 64.dp.toPx()
    val gap = 10.dp.toPx()
    val ringRadius = 5.dp.toPx()
    rotate(reading.rollDegrees.toFloat(), pivot = center) {
        drawCircle(color = color, radius = ringRadius, center = center, style = Stroke(1.6.dp.toPx()))
        drawLine(
            color = color,
            start = Offset(center.x - ringRadius - gap - wing, center.y),
            end = Offset(center.x - ringRadius - gap, center.y),
            strokeWidth = 2.dp.toPx(),
            cap = StrokeCap.Round,
        )
        drawLine(
            color = color,
            start = Offset(center.x + ringRadius + gap, center.y),
            end = Offset(center.x + ringRadius + gap + wing, center.y),
            strokeWidth = 2.dp.toPx(),
            cap = StrokeCap.Round,
        )
    }
}

private fun androidx.compose.ui.graphics.drawscope.DrawScope.drawGaugeLevel(
    reading: LiveLevelReading,
    feed: LiveOverlayRect,
    visibleBounds: LiveOverlayRect,
    isPortrait: Boolean,
    bottomChromeInset: Float,
    metrics: LiveGaugeMetrics,
    readoutPaint: Paint,
) {
    val seats =
        liveGaugeSeats(
            feed = feed,
            visibleBounds = visibleBounds,
            isPortrait = isPortrait,
            bottomChromeInset = bottomChromeInset,
            metrics = metrics,
        )
    drawGaugeAxis(
        seat = seats.roll,
        orientation = GaugeAxisOrientation.HORIZONTAL,
        value = reading.rollDegrees,
        metrics = metrics,
        readoutPaint = readoutPaint,
    )
    drawGaugeAxis(
        seat = seats.pitch,
        orientation = GaugeAxisOrientation.VERTICAL,
        value = reading.pitchDegrees,
        metrics = metrics,
        readoutPaint = readoutPaint,
    )
}

/** Matches the iOS two-axis gauge: roll horizontal, pitch vertical. */
private enum class GaugeAxisOrientation {
    HORIZONTAL,
    VERTICAL,
}

private fun androidx.compose.ui.graphics.drawscope.DrawScope.drawGaugeAxis(
    seat: Offset,
    orientation: GaugeAxisOrientation,
    value: Double,
    metrics: LiveGaugeMetrics,
    readoutPaint: Paint,
) {
    val horizontal = orientation == GaugeAxisOrientation.HORIZONTAL
    val isLevel = abs(value) < metrics.levelThresholdDegrees
    val tint = if (isLevel) LiveDesign.good else LiveDesign.accent
    val beadOffset =
        (value / metrics.maxAngleDegrees).coerceIn(-1.0, 1.0).toFloat() * metrics.axisSpan
    val trackStart =
        if (horizontal) Offset(seat.x - metrics.axisSpan, seat.y) else Offset(seat.x, seat.y - metrics.axisSpan)
    val trackEnd =
        if (horizontal) Offset(seat.x + metrics.axisSpan, seat.y) else Offset(seat.x, seat.y + metrics.axisSpan)
    drawLine(
        color = Color.White.copy(alpha = 0.22f),
        start = trackStart,
        end = trackEnd,
        strokeWidth = metrics.baselineStrokeWidth,
    )

    var degrees = -metrics.maxAngleDegrees
    while (degrees <= metrics.maxAngleDegrees + 0.001) {
        val offset = (degrees / metrics.maxAngleDegrees).toFloat() * metrics.axisSpan
        val isCentre = abs(degrees) < 0.001
        val half = if (isCentre) metrics.centerTickHalfLength else metrics.tickHalfLength
        val tickCenter = if (horizontal) Offset(seat.x + offset, seat.y) else Offset(seat.x, seat.y - offset)
        val tickStart = if (horizontal) Offset(tickCenter.x, tickCenter.y - half) else Offset(tickCenter.x - half, tickCenter.y)
        val tickEnd = if (horizontal) Offset(tickCenter.x, tickCenter.y + half) else Offset(tickCenter.x + half, tickCenter.y)
        drawLine(
            color = Color.White.copy(alpha = if (isCentre) 0.75f else 0.34f),
            start = tickStart,
            end = tickEnd,
            strokeWidth = if (isCentre) metrics.baselineStrokeWidth else metrics.tickStrokeWidth,
        )
        degrees += metrics.tickStepDegrees
    }

    val bead = if (horizontal) Offset(seat.x + beadOffset, seat.y) else Offset(seat.x, seat.y - beadOffset)
    drawCircle(color = tint, radius = metrics.beadRadius, center = bead)
    drawCircle(
        color = Color.Black.copy(alpha = 0.45f),
        radius = metrics.beadRadius,
        center = bead,
        style = Stroke(metrics.beadStrokeWidth),
    )
    if (!isLevel) {
        drawGaugeChevrons(
            bead = bead,
            orientation = orientation,
            value = value,
            metrics = metrics,
        )
    }
    drawGaugeReadout(
        seat = seat,
        orientation = orientation,
        value = value,
        isLevel = isLevel,
        metrics = metrics,
        paint = readoutPaint,
    )
}

private fun androidx.compose.ui.graphics.drawscope.DrawScope.drawGaugeChevrons(
    bead: Offset,
    orientation: GaugeAxisOrientation,
    value: Double,
    metrics: LiveGaugeMetrics,
) {
    val horizontal = orientation == GaugeAxisOrientation.HORIZONTAL
    val sign = if (value > 0.0) 1f else -1f
    val urgency =
        when (abs(value)) {
            in 0.0..<metrics.maxAngleDegrees / 3.0 -> 1
            in metrics.maxAngleDegrees / 3.0..<metrics.maxAngleDegrees * 2.0 / 3.0 -> 2
            else -> 3
        }
    val anchor =
        if (horizontal) {
            Offset(bead.x - sign * metrics.chevronGap, bead.y)
        } else {
            Offset(bead.x, bead.y + sign * metrics.chevronGap)
        }
    repeat(urgency) { index ->
        val centre =
            if (horizontal) {
                Offset(anchor.x - sign * index * metrics.chevronStep, anchor.y)
            } else {
                Offset(anchor.x, anchor.y + sign * index * metrics.chevronStep)
            }
        drawGaugeChevron(
            center = centre,
            orientation = orientation,
            pointsTowardNegative = value > 0.0,
            color = LiveDesign.accent.copy(alpha = 1f - index * 0.22f),
            metrics = metrics,
        )
    }
}

private fun androidx.compose.ui.graphics.drawscope.DrawScope.drawGaugeChevron(
    center: Offset,
    orientation: GaugeAxisOrientation,
    pointsTowardNegative: Boolean,
    color: Color,
    metrics: LiveGaugeMetrics,
) {
    val half = metrics.chevronHalfSize
    val (start, middle, end) =
        when (orientation) {
            GaugeAxisOrientation.HORIZONTAL ->
                if (pointsTowardNegative) {
                    Triple(
                        Offset(center.x + half, center.y - half),
                        Offset(center.x - half, center.y),
                        Offset(center.x + half, center.y + half),
                    )
                } else {
                    Triple(
                        Offset(center.x - half, center.y - half),
                        Offset(center.x + half, center.y),
                        Offset(center.x - half, center.y + half),
                    )
                }
            GaugeAxisOrientation.VERTICAL ->
                if (pointsTowardNegative) {
                    Triple(
                        Offset(center.x - half, center.y + half),
                        Offset(center.x, center.y - half),
                        Offset(center.x + half, center.y + half),
                    )
                } else {
                    Triple(
                        Offset(center.x - half, center.y - half),
                        Offset(center.x, center.y + half),
                        Offset(center.x + half, center.y - half),
                    )
                }
        }
    drawLine(color = color, start = start, end = middle, strokeWidth = metrics.chevronStrokeWidth)
    drawLine(color = color, start = middle, end = end, strokeWidth = metrics.chevronStrokeWidth)
}

private fun androidx.compose.ui.graphics.drawscope.DrawScope.drawGaugeReadout(
    seat: Offset,
    orientation: GaugeAxisOrientation,
    value: Double,
    isLevel: Boolean,
    metrics: LiveGaugeMetrics,
    paint: Paint,
) {
    val shown = if (abs(value) < 0.05) 0.0 else value
    val centre =
        if (orientation == GaugeAxisOrientation.HORIZONTAL) {
            Offset(seat.x, seat.y - metrics.readoutOffset)
        } else {
            Offset(seat.x - metrics.verticalReadoutOffset, seat.y)
        }
    paint.color = (if (isLevel) LiveDesign.good else LiveDesign.text.copy(alpha = 0.85f)).toArgb()
    paint.textSize = metrics.readoutTextSize
    paint.textAlign = Paint.Align.CENTER
    val baseline = centre.y - (paint.ascent() + paint.descent()) / 2f
    drawContext.canvas.nativeCanvas.drawText(
        String.format(Locale.US, "%+.1f°", shown),
        centre.x,
        baseline,
        paint,
    )
}

@Composable
private fun rememberDeviceGravityLevel(enabled: Boolean, isPortrait: Boolean): DeviceGravityLevel? {
    val context = LocalContext.current
    val sensorManager = remember(context) {
        context.getSystemService(Context.SENSOR_SERVICE) as SensorManager
    }
    var reading by remember { mutableStateOf<DeviceGravityLevel?>(null) }

    DisposableEffect(enabled, isPortrait, sensorManager) {
        reading = null
        if (!enabled) return@DisposableEffect onDispose { }
        // TYPE_GRAVITY is the preferred fused source. The SM-A127F test floor
        // exposes only an accelerometer, however, so derive a normalized,
        // low-pass device-tilt approximation rather than silently removing
        // the explicitly labelled fallback on that hardware.
        val gravitySensor = sensorManager.getDefaultSensor(Sensor.TYPE_GRAVITY)
        val accelerometerSensor = sensorManager.getDefaultSensor(Sensor.TYPE_ACCELEROMETER)
        val sensor = gravitySensor ?: accelerometerSensor
            ?: return@DisposableEffect onDispose { }
        val derivesGravityFromAccelerometer = gravitySensor == null
        var filteredTilt: DeviceTiltVector? = null
        val listener =
            object : SensorEventListener {
                override fun onSensorChanged(event: SensorEvent) {
                    if (event.values.size < 3) return
                    val vector =
                        if (derivesGravityFromAccelerometer) {
                            lowPassDeviceTilt(
                                previous = filteredTilt,
                                sampleX = event.values[0],
                                sampleY = event.values[1],
                                sampleZ = event.values[2],
                            )?.also { filteredTilt = it } ?: return
                        } else {
                            DeviceTiltVector(event.values[0], event.values[1], event.values[2])
                        }
                    reading =
                        deviceGravityLevel(
                            gravityX = vector.x,
                            gravityY = vector.y,
                            gravityZ = vector.z,
                            isPortrait = isPortrait,
                            provenance =
                                if (derivesGravityFromAccelerometer) {
                                    DeviceTiltProvenance.ACCELEROMETER_LOW_PASS
                                } else {
                                    DeviceTiltProvenance.GRAVITY_SENSOR
                                },
                        )
                }

                override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) = Unit
            }
        sensorManager.registerListener(listener, sensor, SensorManager.SENSOR_DELAY_GAME)
        onDispose { sensorManager.unregisterListener(listener) }
    }
    return reading
}

private const val HORIZON_LEVEL_TOLERANCE_DEGREES = 0.8
private const val DEVICE_TILT_LOW_PASS_RETENTION = 0.8f
private const val DEVICE_TILT_MINIMUM_MAGNITUDE = 0.0001f

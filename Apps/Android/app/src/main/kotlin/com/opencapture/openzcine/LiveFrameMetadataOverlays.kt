package com.opencapture.openzcine

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import com.opencapture.monitorui.MonitorLevelDisplay
import com.opencapture.monitorui.rememberMonitorDeviceTilt
import com.opencapture.monitorui.MonitorTiltSource
import com.opencapture.monitorui.MonitorDeviceTilt
import com.opencapture.monitorui.MonitorLevelOverlay
import com.opencapture.monitorui.MonitorScopeRect
import com.opencapture.opencine.nikon.LiveCameraLevel
import com.opencapture.openzcine.settings.LocalFramingAssistConfiguration
import com.opencapture.monitorui.MonitorLevelStyle
import kotlin.math.min
import kotlin.math.roundToInt
import com.opencapture.opencine.runtime.NativeFeedContentRect
import com.opencapture.opencine.runtime.nativeFeedContentRect

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
    val deviceTiltProvenance: MonitorTiltSource? = null,
)

/**
 * The shared gauge's bounds in dp: the visible part of the feed above the bottom chrome that covers
 * it, so the roll strip clears a capture strip in portrait and the bottom bars in landscape.
 */
internal fun levelGaugeBounds(
    visibleBounds: LiveOverlayRect,
    bottomChromeInset: Float,
    density: Float,
): MonitorScopeRect =
    MonitorScopeRect(
        visibleBounds.left / density,
        visibleBounds.top / density,
        visibleBounds.width / density,
        maxOf(0f, visibleBounds.height - maxOf(0f, bottomChromeInset)) / density,
    )

/**
 * Computes the visual feed rectangle after the monitor's local de-squeeze
 * transform. The input is the same integer fit or centre-cropped fill
 * rectangle used by [LiveFeedView], never the broader monitor zone map.
 */
internal fun liveOverlayFeedRect(
    content: NativeFeedContentRect,
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

/** Prefers a valid camera horizon and uses the phone's tilt only when the frame lacks one. */
internal fun resolveLiveLevel(
    camera: LiveCameraLevel?,
    deviceGravity: MonitorDeviceTilt?,
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
            deviceTiltProvenance = deviceGravity.source,
        )
    }
    return null
}

/** Accessible provenance copy that never lets debug fixtures masquerade as camera telemetry. */
internal fun liveLevelAccessibilityDescription(
    reading: LiveLevelReading,
    style: MonitorLevelStyle,
): String =
    if (reading.source == LiveLevelSource.CAMERA) {
        if (reading.isDebugFixture) {
            "Debug fixture level, not camera metadata, ${style.title.lowercase()}"
        } else {
            "Camera virtual horizon, ${style.title.lowercase()}"
        }
    } else {
        "${reading.deviceTiltProvenance?.accessibilityLabel ?: "device tilt"} fallback, ${style.title.lowercase()}"
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
    isPortrait: Boolean,
    aspectFill: Boolean = false,
    /** Local-pixel height of monitor chrome covering the feed's bottom edge. */
    gaugeBottomChromeInset: Float = 0f,
    focusPointLocked: Boolean = false,
    focusLockProgress: Float = 0f,
    /** The AF box is an operator-configurable element like any other (`ChromeSection.FOCUS_BOX`). */
    focusBoxVisible: Boolean = true,
    /** 0.3 while the Edit view has it switched off, so its badge still has something to sit on. */
    focusBoxAlpha: Float = 1f,
    /** Edit-view proxy: applied to an invisible box over the primary AF box, or null when live. */
    focusBoxEditModifier: Modifier? = null,
    modifier: Modifier = Modifier,
) {
    val cameraLevel = presentationState.level
    // Tool visibility comes from [configuration], already filtered for the DISP mode by
    // `renderedFramingAssists` (#256). The EV meter is the shared surface's gauge (A1-32).
    val levelEnabled = configuration.levelEnabled
    val cameraLevelAvailable = cameraLevel?.let(::cameraLevelIsValid) == true
    val deviceGravity = rememberMonitorDeviceTilt(enabled = levelEnabled && !cameraLevelAvailable, portrait = isPortrait)
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
                nativeFeedContentRect(
                    containerWidth = maxWidth.toPx(),
                    containerHeight = maxHeight.toPx(),
                    sourceWidth = presentationState.sourceWidth,
                    sourceHeight = presentationState.sourceHeight,
                    aspectFill = aspectFill,
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
            if (focusBoxVisible) {
                CameraFocusOverlay(
                    focus = presentationState.focus,
                    feed = feed,
                    locked = focusPointLocked,
                    lockProgress = focusLockProgress,
                    alpha = focusBoxAlpha,
                    editModifier = focusBoxEditModifier,
                    mirrored = configuration.mirrorsHorizontally,
                    mirroredVertical = configuration.flipsVertically,
                )
            }
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
private fun CameraLevelOverlay(
    reading: LiveLevelReading?,
    style: MonitorLevelStyle,
    feed: LiveOverlayRect,
    visibleBounds: LiveOverlayRect,
    isPortrait: Boolean,
    bottomChromeInset: Float,
    debugFixtureShown: Boolean,
) {
    if (reading == null) return
    val density = LocalDensity.current
    val description = liveLevelAccessibilityDescription(reading, style)
    Box(Modifier.fillMaxSize().clearAndSetSemantics { contentDescription = description }) {
        when (style) {
            // The shared overlay: a horizon through the picture's centre, or the two-axis gauge with
            // roll along the bottom and pitch on the trailing side.
            MonitorLevelStyle.HORIZON, MonitorLevelStyle.GAUGE ->
                MonitorLevelOverlay(
                    display = if (style == MonitorLevelStyle.HORIZON) MonitorLevelDisplay.Horizon(reading.rollDegrees)
                        else MonitorLevelDisplay.Gauges(reading.rollDegrees, reading.pitchDegrees),
                    feedDp =
                        MonitorScopeRect(
                            feed.left / density.density, feed.top / density.density,
                            feed.width / density.density, feed.height / density.density,
                        ),
                    viewportDp = levelGaugeBounds(visibleBounds, bottomChromeInset, density.density),
                    portrait = isPortrait,
                )
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

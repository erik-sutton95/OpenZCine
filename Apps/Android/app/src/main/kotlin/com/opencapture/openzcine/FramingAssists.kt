package com.opencapture.openzcine

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.CompositingStrategy
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.opencapture.openzcine.settings.LocalDesqueezeOrientation
import com.opencapture.openzcine.settings.LocalDesqueezeRatio
import com.opencapture.openzcine.settings.LocalFramingAspectRatio
import com.opencapture.openzcine.settings.LocalFramingAssistConfiguration
import com.opencapture.openzcine.settings.LocalLevelStyle
import kotlin.math.roundToInt

/** A rectangle expressed in the hosting monitor's local pixels for deterministic overlay layout. */
internal data class FramingAssistRect(
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

/** One labelled aspect guide resolved inside the visible de-squeezed feed. */
internal data class LocalFramingGuideFrame(
    val ratio: LocalFramingAspectRatio,
    val rect: FramingAssistRect,
)

/** The pure layout decisions made by [LocalFramingAssistOverlay]. */
internal data class LocalFramingRenderPlan(
    /** Exact de-squeezed image content, never a synthetic screen zone. */
    val presentationRect: FramingAssistRect,
    /** Every selected local delivery frame in stable narrow-to-wide draw order. */
    val guideFrames: List<LocalFramingGuideFrame>,
    /** Dims the inverse union of [guideFrames] inside [presentationRect]. */
    val drawsInverseGuideMask: Boolean,
    val drawsRuleOfThirds: Boolean,
    val drawsPhiGrid: Boolean,
    val drawsDiagonalGrid: Boolean,
    val drawsCenterCrosshair: Boolean,
)

/**
 * Resolves local framing geometry inside the exact visible feed content.
 *
 * [feed] is the exact fit/fill image rectangle before the host canvas clips
 * it. Keeping the complete over-wide portrait-fill rectangle matches iOS:
 * guides, grids, crosshair, de-squeeze, and AF all remain registered to camera
 * pixels while the physical viewport clips only their visible portions.
 */
internal fun localFramingRenderPlan(
    feed: FramingAssistRect,
    configuration: LocalFramingAssistConfiguration,
    cleanMode: Boolean,
): LocalFramingRenderPlan {
    val presentationRect =
        localDesqueezePresentationRect(
            feed = feed,
            enabled = configuration.desqueezeEnabled,
            factor = configuration.desqueezeFactor,
            orientation = configuration.desqueezeOrientation,
        )
    val guideFrames =
        if (configuration.drawsGuides) {
            configuration.selectedGuideRatios
                .sortedBy(LocalFramingAspectRatio::aspectRatio)
                .map { ratio ->
                    LocalFramingGuideFrame(
                        ratio = ratio,
                        rect = centeredGuideRect(presentationRect, ratio),
                    )
                }
        } else {
            emptyList()
        }
    val drawsGrid = !cleanMode && configuration.drawsGrid
    return LocalFramingRenderPlan(
        presentationRect = presentationRect,
        guideFrames = guideFrames,
        drawsInverseGuideMask = configuration.guideMaskEnabled && guideFrames.isNotEmpty(),
        // Match iOS clean output: retain delivery framing and de-squeeze, but
        // hide the busier compositional grid and crosshair.
        drawsRuleOfThirds = drawsGrid && configuration.ruleOfThirdsEnabled,
        drawsPhiGrid = drawsGrid && configuration.phiGridEnabled,
        drawsDiagonalGrid = drawsGrid && configuration.diagonalGridEnabled,
        drawsCenterCrosshair = !cleanMode && configuration.centerCrosshairEnabled,
    )
}

/** Convenience overload for pure tests that use a feed starting at the origin. */
internal fun localFramingRenderPlan(
    width: Float,
    height: Float,
    configuration: LocalFramingAssistConfiguration,
    cleanMode: Boolean,
): LocalFramingRenderPlan =
    localFramingRenderPlan(
        feed = FramingAssistRect(0f, 0f, width.coerceAtLeast(0f), height.coerceAtLeast(0f)),
        configuration = configuration,
        cleanMode = cleanMode,
    )

/**
 * Returns the visible presentation rectangle after local de-squeeze.
 *
 * Horizontal de-squeeze produces a centred pillarbox; vertical de-squeeze
 * produces a centred letterbox. Neither changes the camera, the encoded frame,
 * or any media file.
 */
internal fun localDesqueezePresentationRect(
    feed: FramingAssistRect,
    enabled: Boolean,
    factor: Float,
    orientation: LocalDesqueezeOrientation,
): FramingAssistRect {
    val squeeze = factor.coerceAtLeast(1f)
    if (!enabled || squeeze <= 1f || feed.width <= 0f || feed.height <= 0f) return feed
    return when (orientation) {
        LocalDesqueezeOrientation.HORIZONTAL -> {
            val width = feed.width / squeeze
            FramingAssistRect(
                left = feed.centerX - width / 2f,
                top = feed.top,
                width = width,
                height = feed.height,
            )
        }
        LocalDesqueezeOrientation.VERTICAL -> {
            val height = feed.height / squeeze
            FramingAssistRect(
                left = feed.left,
                top = feed.centerY - height / 2f,
                width = feed.width,
                height = height,
            )
        }
    }
}

/** Returns a centred delivery-frame guide within [feed]. */
internal fun centeredGuideRect(
    feed: FramingAssistRect,
    ratio: LocalFramingAspectRatio,
): FramingAssistRect {
    if (feed.width <= 0f || feed.height <= 0f) return FramingAssistRect(feed.left, feed.top, 0f, 0f)
    val feedAspectRatio = feed.width / feed.height
    return if (feedAspectRatio > ratio.aspectRatio) {
        val width = feed.height * ratio.aspectRatio
        FramingAssistRect(
            left = feed.left + (feed.width - width) / 2f,
            top = feed.top,
            width = width,
            height = feed.height,
        )
    } else {
        val height = feed.width / ratio.aspectRatio
        FramingAssistRect(
            left = feed.left,
            top = feed.top + (feed.height - height) / 2f,
            width = feed.width,
            height = height,
        )
    }
}

/**
 * Feed-aligned local framing overlays for the Android monitor.
 *
 * [presentationState] carries the decoded frame dimensions used by
 * [LiveFeedView], so the live monitor resolves the same `LiveFeedContentRect`
 * rather than estimating against its enclosing zone. [feedRect] is the exact
 * pixel-space seam for callers such as Media3 playback that already own the
 * decoded image's aspect-fit rectangle.
 */
@Composable
internal fun LocalFramingAssistOverlay(
    configuration: LocalFramingAssistConfiguration,
    cleanMode: Boolean,
    presentationState: LiveFeedPresentationState? = null,
    feedRect: FramingAssistRect? = null,
    aspectFill: Boolean = false,
    modifier: Modifier = Modifier,
) {
    val accessibilitySummary = localFramingAssistAccessibilitySummary(configuration)
    BoxWithConstraints(
        modifier
            .fillMaxSize()
            .clearAndSetSemantics {
                contentDescription = accessibilitySummary
            },
    ) {
        val density = LocalDensity.current
        val sourceWidth = presentationState?.sourceWidth ?: 0
        val sourceHeight = presentationState?.sourceHeight ?: 0
        val exactLiveFeed =
            with(density) {
                if (presentationState == null) {
                    null
                } else {
                    liveFeedContentRect(
                        containerWidth = maxWidth.toPx(),
                        containerHeight = maxHeight.toPx(),
                        sourceWidth = sourceWidth,
                        sourceHeight = sourceHeight,
                        aspectFill = aspectFill,
                    )?.toFramingAssistRect()
                }
            }
        val plan =
            remember(
                configuration,
                cleanMode,
                feedRect,
                aspectFill,
                presentationState,
                sourceWidth,
                sourceHeight,
                exactLiveFeed,
                maxWidth,
                maxHeight,
                density,
            ) {
                val fallbackFeed =
                    with(density) {
                        FramingAssistRect(
                            left = 0f,
                            top = 0f,
                            width = maxWidth.toPx(),
                            height = maxHeight.toPx(),
                        )
                    }
                // Before the first live frame, draw nothing rather than align
                // a local framing overlay to the broader monitor zone.
                val feed = feedRect ?: exactLiveFeed ?: fallbackFeed.takeIf { presentationState == null }
                feed?.let {
                    localFramingRenderPlan(
                        feed = it,
                        configuration = configuration,
                        cleanMode = cleanMode,
                    )
                }
            }
        if (plan != null) {
            Canvas(
                Modifier
                    .fillMaxSize()
                    // The inverse mask uses destination-out to reveal the union
                    // of overlapping frames. An offscreen layer makes that union
                    // local to the overlay instead of punching through app chrome.
                    .graphicsLayer { compositingStrategy = CompositingStrategy.Offscreen },
            ) {
                if (plan.drawsInverseGuideMask) {
                    drawInverseGuideMask(plan.presentationRect, plan.guideFrames)
                }
                plan.guideFrames.forEach { drawFrameGuide(it.rect) }
                if (plan.drawsRuleOfThirds) drawGridFractions(plan.presentationRect, listOf(1f / 3f, 2f / 3f))
                if (plan.drawsPhiGrid) drawGridFractions(plan.presentationRect, listOf(0.382f, 0.618f))
                if (plan.drawsDiagonalGrid) drawDiagonalGrid(plan.presentationRect)
                if (plan.drawsCenterCrosshair) drawCentreCrosshair(plan.presentationRect)
            }
            plan.guideFrames.forEach { frame ->
                FramingGuideLabel(frame)
            }
        }
    }
}

@Composable
private fun localFramingAssistAccessibilitySummary(
    configuration: LocalFramingAssistConfiguration,
): String {
    val guides =
        if (configuration.drawsGuides) {
            pluralStringResource(
                R.plurals.framing_accessibility_guides_on,
                configuration.selectedGuideRatios.size,
                configuration.selectedGuideRatios.size,
            )
        } else {
            stringResource(R.string.framing_accessibility_guides_off)
        }
    val mask =
        stringResource(
            if (configuration.guideMaskEnabled) {
                R.string.framing_accessibility_mask_on
            } else {
                R.string.framing_accessibility_mask_off
            },
        )
    val grid =
        stringResource(
            if (configuration.drawsGrid) {
                R.string.framing_accessibility_grid_on
            } else {
                R.string.framing_accessibility_grid_off
            },
        )
    val crosshair =
        stringResource(
            if (configuration.centerCrosshairEnabled) {
                R.string.framing_accessibility_crosshair_on
            } else {
                R.string.framing_accessibility_crosshair_off
            },
        )
    val desqueeze =
        if (configuration.desqueezeEnabled) {
            val orientation =
                stringResource(
                    if (configuration.desqueezeOrientation == LocalDesqueezeOrientation.HORIZONTAL) {
                        R.string.orientation_horizontal
                    } else {
                        R.string.orientation_vertical
                    },
                )
            val ratio =
                stringResource(
                    when (LocalDesqueezeRatio.matching(configuration.desqueezeFactor)
                        ?: configuration.desqueezeRatio) {
                        LocalDesqueezeRatio.X100 -> R.string.desqueeze_1
                        LocalDesqueezeRatio.X133 -> R.string.desqueeze_133
                        LocalDesqueezeRatio.X150 -> R.string.desqueeze_15
                        LocalDesqueezeRatio.X160 -> R.string.desqueeze_16
                        LocalDesqueezeRatio.X165 -> R.string.desqueeze_165
                        LocalDesqueezeRatio.X180 -> R.string.desqueeze_18
                        LocalDesqueezeRatio.X200 -> R.string.desqueeze_2
                    },
                )
            stringResource(R.string.framing_accessibility_desqueeze_on, orientation, ratio)
        } else {
            stringResource(R.string.framing_accessibility_desqueeze_off)
        }
    val level =
        if (configuration.levelEnabled) {
            val style =
                stringResource(
                    if (configuration.levelStyle == LocalLevelStyle.HORIZON) {
                        R.string.level_horizon
                    } else {
                        R.string.level_gauge
                    },
                )
            stringResource(R.string.framing_accessibility_level_on, style)
        } else {
            stringResource(R.string.framing_accessibility_level_off)
        }
    return stringResource(
        R.string.framing_accessibility_summary,
        guides,
        mask,
        grid,
        crosshair,
        desqueeze,
        level,
    )
}

/** Converts the feed renderer's exact integer fit/fill rectangle into framing coordinates. */
private fun LiveFeedContentRect.toFramingAssistRect(): FramingAssistRect =
    FramingAssistRect(left.toFloat(), top.toFloat(), width.toFloat(), height.toFloat())

/** Draws the inverse union mask: overlapping selected frames stay transparent. */
private fun androidx.compose.ui.graphics.drawscope.DrawScope.drawInverseGuideMask(
    presentation: FramingAssistRect,
    frames: List<LocalFramingGuideFrame>,
) {
    drawRect(
        color = Color.Black.copy(alpha = 0.6f),
        topLeft = Offset(presentation.left, presentation.top),
        size = Size(presentation.width, presentation.height),
    )
    frames.forEach { frame ->
        drawRect(
            color = Color.Black,
            topLeft = Offset(frame.rect.left, frame.rect.top),
            size = Size(frame.rect.width, frame.rect.height),
            blendMode = BlendMode.DstOut,
        )
    }
}

/** Content-aligned delivery-ratio label matching iOS's compact guide labels. */
@Composable
private fun FramingGuideLabel(frame: LocalFramingGuideFrame) {
    val density = LocalDensity.current
    val inset = with(density) { 8.dp.roundToPx() }
    Text(
        text =
            stringResource(
                when (frame.ratio) {
                    LocalFramingAspectRatio.RATIO_276 -> R.string.framing_ratio_276
                    LocalFramingAspectRatio.RATIO_239 -> R.string.framing_ratio_239
                    LocalFramingAspectRatio.RATIO_235 -> R.string.framing_ratio_235
                    LocalFramingAspectRatio.RATIO_200 -> R.string.framing_ratio_200
                    LocalFramingAspectRatio.RATIO_185 -> R.string.framing_ratio_185
                    LocalFramingAspectRatio.RATIO_16_9 -> R.string.framing_ratio_16_9
                    LocalFramingAspectRatio.RATIO_166 -> R.string.framing_ratio_166
                    LocalFramingAspectRatio.RATIO_143 -> R.string.framing_ratio_143
                    LocalFramingAspectRatio.RATIO_4_3 -> R.string.framing_ratio_4_3
                    LocalFramingAspectRatio.RATIO_9_16 -> R.string.framing_ratio_9_16
                    LocalFramingAspectRatio.RATIO_4_5 -> R.string.framing_ratio_4_5
                    LocalFramingAspectRatio.RATIO_1_1 -> R.string.framing_ratio_1_1
                    LocalFramingAspectRatio.RATIO_2_3 -> R.string.framing_ratio_2_3
                    LocalFramingAspectRatio.RATIO_191 -> R.string.framing_ratio_191
                },
            ),
        style = chromeStyle(10f, FontWeight.Bold, mono = true).copy(letterSpacing = 1.2.sp),
        color = LiveDesign.accent,
        modifier =
            Modifier.offset {
                IntOffset(
                    x = (frame.rect.left + inset).roundToInt(),
                    y = (frame.rect.top + inset).roundToInt(),
                )
            }
                .background(Color.Black.copy(alpha = 0.42f), RoundedCornerShape(5.dp))
                .padding(horizontal = 6.dp, vertical = 2.dp),
    )
}

private fun androidx.compose.ui.graphics.drawscope.DrawScope.drawFrameGuide(
    rect: FramingAssistRect,
) {
    drawRect(
        color = LiveDesign.accent.copy(alpha = 0.85f),
        topLeft = Offset(rect.left, rect.top),
        size = Size(rect.width, rect.height),
        style = Stroke(width = 1.dp.toPx()),
    )
}

private fun androidx.compose.ui.graphics.drawscope.DrawScope.drawGridFractions(
    rect: FramingAssistRect,
    fractions: List<Float>,
) {
    val strokeWidth = 1.dp.toPx()
    val color = Color.White.copy(alpha = 0.22f)
    fractions.forEach { fraction ->
        val x = rect.left + rect.width * fraction
        val y = rect.top + rect.height * fraction
        drawLine(color, Offset(x, rect.top), Offset(x, rect.bottom), strokeWidth)
        drawLine(color, Offset(rect.left, y), Offset(rect.right, y), strokeWidth)
    }
}

private fun androidx.compose.ui.graphics.drawscope.DrawScope.drawDiagonalGrid(rect: FramingAssistRect) {
    val color = Color.White.copy(alpha = 0.22f)
    val strokeWidth = 1.dp.toPx()
    drawLine(color, Offset(rect.left, rect.top), Offset(rect.right, rect.bottom), strokeWidth)
    drawLine(color, Offset(rect.right, rect.top), Offset(rect.left, rect.bottom), strokeWidth)
}

private fun androidx.compose.ui.graphics.drawscope.DrawScope.drawCentreCrosshair(
    rect: FramingAssistRect,
) {
    val center = Offset(rect.centerX, rect.centerY)
    val arm = 20.dp.toPx()
    val strokeWidth = 1.4.dp.toPx()
    val color = Color.White.copy(alpha = 0.65f)
    drawLine(
        color,
        Offset(center.x - arm, center.y),
        Offset(center.x + arm, center.y),
        strokeWidth,
        cap = StrokeCap.Round,
    )
    drawLine(
        color,
        Offset(center.x, center.y - arm),
        Offset(center.x, center.y + arm),
        strokeWidth,
        cap = StrokeCap.Round,
    )
}

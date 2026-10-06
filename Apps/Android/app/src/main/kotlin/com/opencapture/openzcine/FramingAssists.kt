package com.opencapture.openzcine

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.offset
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shadow
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.opencapture.monitorui.MonitorAspectGuideFrames
import com.opencapture.monitorui.MonitorFeedCrosshair
import com.opencapture.monitorui.MonitorFeedGrid
import com.opencapture.monitorui.MonitorGuideAspect
import com.opencapture.monitorui.MonitorScopeRect
import com.opencapture.opencine.media.MonitorDesqueezeDirection
import com.opencapture.openzcine.settings.LocalFramingAssistConfiguration
import com.opencapture.openzcine.settings.LocalLevelStyle
import kotlin.math.roundToInt
import com.opencapture.opencine.runtime.nativeFeedContentRect

/** The pure layout decisions made by [LocalFramingAssistOverlay], in the hosting monitor's local pixels. */
internal data class LocalFramingRenderPlan(
    /** Exact de-squeezed image content, never a synthetic screen zone. */
    val presentationRect: MonitorScopeRect,
    /** Selected local delivery frames; the shared marks draw them narrow to wide. */
    val guides: Set<MonitorGuideAspect>,
    /** Dims the inverse union of [guides] inside [presentationRect]. */
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
    feed: MonitorScopeRect,
    configuration: LocalFramingAssistConfiguration,
): LocalFramingRenderPlan {
    val presentationRect =
        localDesqueezePresentationRect(
            feed = feed,
            enabled = configuration.desqueezeEnabled,
            factor = configuration.desqueezeFactor,
            direction = configuration.desqueezeDirection,
        )
    val guides = if (configuration.drawsGuides) configuration.selectedGuideRatios else emptySet()
    val drawsGrid = configuration.drawsGrid
    // DISP-mode policy is NOT applied here: the caller passes a configuration already filtered by
    // `rendersLive`, so clean view draws exactly the tools the operator pinned (#256).
    return LocalFramingRenderPlan(
        presentationRect = presentationRect,
        guides = guides,
        drawsInverseGuideMask = configuration.guideMaskEnabled && guides.isNotEmpty(),
        drawsRuleOfThirds = drawsGrid && configuration.ruleOfThirdsEnabled,
        drawsPhiGrid = drawsGrid && configuration.phiGridEnabled,
        drawsDiagonalGrid = drawsGrid && configuration.diagonalGridEnabled,
        drawsCenterCrosshair = configuration.centerCrosshairEnabled,
    )
}

/** Convenience overload for pure tests that use a feed starting at the origin. */
internal fun localFramingRenderPlan(
    width: Float,
    height: Float,
    configuration: LocalFramingAssistConfiguration,
): LocalFramingRenderPlan =
    localFramingRenderPlan(
        feed = MonitorScopeRect(0f, 0f, width.coerceAtLeast(0f), height.coerceAtLeast(0f)),
        configuration = configuration,
    )

/**
 * Returns the visible presentation rectangle after local de-squeeze.
 *
 * Vertical (narrowing) produces a centred pillarbox; horizontal (widening) produces a centred
 * letterbox. Neither changes the camera, the encoded frame, or any media file.
 */
internal fun localDesqueezePresentationRect(
    feed: MonitorScopeRect,
    enabled: Boolean,
    factor: Float,
    direction: MonitorDesqueezeDirection,
): MonitorScopeRect {
    val squeeze = factor.coerceAtLeast(1f)
    if (!enabled || squeeze <= 1f || feed.width <= 0f || feed.height <= 0f) return feed
    return when (direction) {
        MonitorDesqueezeDirection.VERTICAL -> {
            val width = feed.width / squeeze
            MonitorScopeRect(feed.midX - width / 2f, feed.y, width, feed.height)
        }
        MonitorDesqueezeDirection.HORIZONTAL -> {
            val height = feed.height / squeeze
            MonitorScopeRect(feed.x, feed.midY - height / 2f, feed.width, height)
        }
    }
}

/**
 * Feed-aligned local framing overlays for the Android monitor.
 *
 * [presentationState] carries the decoded frame dimensions used by
 * [LiveFeedView], so the live monitor resolves the same `NativeFeedContentRect`
 * rather than estimating against its enclosing zone. [feedRect] is the exact
 * pixel-space seam for callers such as Media3 playback that already own the
 * decoded image's aspect-fit rectangle.
 */
@Composable
internal fun LocalFramingAssistOverlay(
    configuration: LocalFramingAssistConfiguration,
    presentationState: LiveFeedPresentationState? = null,
    feedRect: MonitorScopeRect? = null,
    aspectFill: Boolean = false,
    /**
     * The active 50/50 Log-vs-LUT comparison, or `null`. Drawn here rather than in its own
     * overlay so the divider and the shader's boundary come from the same `presentationRect`.
     * Already mode-filtered by the caller — it follows the LUT's own clean-view pin.
     */
    splitComparison: FeedSplitOrientation? = null,
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
                    nativeFeedContentRect(
                        containerWidth = maxWidth.toPx(),
                        containerHeight = maxHeight.toPx(),
                        sourceWidth = sourceWidth,
                        sourceHeight = sourceHeight,
                        aspectFill = aspectFill,
                    )?.let { MonitorScopeRect(it.left.toFloat(), it.top.toFloat(), it.width.toFloat(), it.height.toFloat()) }
                }
            }
        val plan =
            remember(
                configuration,
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
                val fallbackFeed = with(density) { MonitorScopeRect(0f, 0f, maxWidth.toPx(), maxHeight.toPx()) }
                // Before the first live frame, draw nothing rather than align
                // a local framing overlay to the broader monitor zone.
                val feed = feedRect ?: exactLiveFeed ?: fallbackFeed.takeIf { presentationState == null }
                feed?.let {
                    localFramingRenderPlan(
                        feed = it,
                        configuration = configuration,
                    )
                }
            }
        if (plan != null) {
            val feed = plan.presentationRect
            MonitorAspectGuideFrames(plan.guides, feed, plan.drawsInverseGuideMask)
            MonitorFeedGrid(feed, plan.drawsRuleOfThirds, plan.drawsPhiGrid, plan.drawsDiagonalGrid)
            if (plan.drawsCenterCrosshair) MonitorFeedCrosshair(feed)
            splitComparison?.let { split ->
                Canvas(Modifier.fillMaxSize()) { drawSplitDivider(feed, split) }
                SplitComparisonLabels(feed, split)
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
                    if (configuration.desqueezeDirection == MonitorDesqueezeDirection.HORIZONTAL) {
                        R.string.orientation_horizontal
                    } else {
                        R.string.orientation_vertical
                    },
                )
            // "2x", "1.33x": the factor without trailing zeros.
            val ratio = "%.2f".format(java.util.Locale.US, configuration.desqueezeFactor).trimEnd('0').trimEnd('.') + "x"
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

/**
 * The 50/50 comparison's two half labels, hugging the divider at one edge of the image.
 *
 * Not centred in each half on purpose: the operator is judging the picture, and a caption over the
 * subject is exactly what "without permanently obscuring the image" rules out.
 */
@Composable
private fun SplitComparisonLabels(rect: MonitorScopeRect, orientation: FeedSplitOrientation) {
    val density = LocalDensity.current
    val logOffset: Offset
    val lutOffset: Offset
    // Matches the iOS placement: a fraction of the way along the divider, which clears the status
    // deck in landscape and in portrait without knowing which chrome is mounted.
    if (orientation == FeedSplitOrientation.VERTICAL) {
        val y = rect.y + rect.height * ALONG_DIVIDER
        logOffset = Offset(rect.midX - with(density) { 30.dp.toPx() }, y)
        lutOffset = Offset(rect.midX + with(density) { 8.dp.toPx() }, y)
    } else {
        val x = rect.x + rect.width * ALONG_DIVIDER
        logOffset = Offset(x, rect.midY - with(density) { 15.dp.toPx() })
        lutOffset = Offset(x, rect.midY + with(density) { 4.dp.toPx() })
    }
    SplitComparisonLabel(FeedSplitOrientation.LOG_LABEL, logOffset)
    SplitComparisonLabel(FeedSplitOrientation.LUT_LABEL, lutOffset)
}

/** Where along the divider the label pair sits, as a fraction of the visible image. */
private const val ALONG_DIVIDER = 0.16f

/**
 * Deliberately tiny and unfilled: the split itself already says which half is which, so these only
 * confirm it. A drop shadow rather than a filled chip — the graded half can be far darker or far
 * brighter than the log half depending on the look, and a shadow reads over both where one fixed
 * fill colour reads over neither.
 */
@Composable
private fun SplitComparisonLabel(text: String, offset: Offset) {
    Text(
        text = text,
        style =
            chromeStyle(8f, FontWeight.SemiBold, mono = true).copy(
                letterSpacing = 0.5.sp,
                shadow =
                    Shadow(
                        color = Color.Black.copy(alpha = 0.8f),
                        offset = Offset(0f, 1f),
                        blurRadius = 3f,
                    ),
            ),
        color = Color.White.copy(alpha = 0.85f),
        modifier = Modifier.offset { IntOffset(offset.x.roundToInt(), offset.y.roundToInt()) },
    )
}

/**
 * The hairline at the comparison boundary — the centre of the visible image rectangle, the same
 * line the fragment shader grades on one side of.
 */
private fun androidx.compose.ui.graphics.drawscope.DrawScope.drawSplitDivider(
    rect: MonitorScopeRect,
    orientation: FeedSplitOrientation,
) {
    val width = 1.dp.toPx()
    if (orientation == FeedSplitOrientation.VERTICAL) {
        drawRect(
            color = Color.White.copy(alpha = 0.5f),
            topLeft = Offset(rect.midX - width / 2f, rect.y),
            size = Size(width, rect.height),
        )
    } else {
        drawRect(
            color = Color.White.copy(alpha = 0.5f),
            topLeft = Offset(rect.x, rect.midY - width / 2f),
            size = Size(rect.width, width),
        )
    }
}

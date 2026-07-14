package com.opencapture.openzcine

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import com.opencapture.openzcine.settings.LocalDesqueezePresentation
import com.opencapture.openzcine.settings.LocalFramingAssistConfiguration
import com.opencapture.openzcine.settings.LocalFramingGuide
import kotlin.math.roundToInt

/** A rectangle expressed in feed-local pixels for deterministic overlay layout. */
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

/** The pure layout decisions made by [LocalFramingAssistOverlay]. */
internal data class LocalFramingRenderPlan(
    val presentationRect: FramingAssistRect,
    val guideRect: FramingAssistRect?,
    val drawsRuleOfThirds: Boolean,
    val drawsCenterCrosshair: Boolean,
)

/**
 * Resolves local framing geometry inside the already-computed monitor feed
 * zone. It does not know about camera state or recreate the shared zone map.
 */
internal fun localFramingRenderPlan(
    width: Float,
    height: Float,
    configuration: LocalFramingAssistConfiguration,
    cleanMode: Boolean,
): LocalFramingRenderPlan {
    val presentationRect =
        localDesqueezePresentationRect(
            width = width,
            height = height,
            presentation = configuration.desqueezePresentation,
        )
    return LocalFramingRenderPlan(
        presentationRect = presentationRect,
        guideRect = centeredGuideRect(presentationRect, configuration.guide),
        // Match iOS clean output: retain delivery framing and presentation,
        // hide the busier compositional grid and crosshair.
        drawsRuleOfThirds = !cleanMode && configuration.ruleOfThirdsEnabled,
        drawsCenterCrosshair = !cleanMode && configuration.centerCrosshairEnabled,
    )
}

/** Returns the centred, horizontal de-squeeze presentation rectangle. */
internal fun localDesqueezePresentationRect(
    width: Float,
    height: Float,
    presentation: LocalDesqueezePresentation,
): FramingAssistRect {
    val safeWidth = width.coerceAtLeast(0f)
    val safeHeight = height.coerceAtLeast(0f)
    val presentedWidth = safeWidth * presentation.horizontalPresentationScale
    return FramingAssistRect(
        left = (safeWidth - presentedWidth) / 2f,
        top = 0f,
        width = presentedWidth,
        height = safeHeight,
    )
}

/** Returns a centred delivery-frame guide within [feed], or `null` when off. */
internal fun centeredGuideRect(
    feed: FramingAssistRect,
    guide: LocalFramingGuide,
): FramingAssistRect? {
    val aspectRatio = guide.aspectRatio ?: return null
    if (feed.width <= 0f || feed.height <= 0f) return null
    val feedAspectRatio = feed.width / feed.height
    return if (feedAspectRatio > aspectRatio) {
        val width = feed.height * aspectRatio
        FramingAssistRect(
            left = feed.left + (feed.width - width) / 2f,
            top = feed.top,
            width = width,
            height = feed.height,
        )
    } else {
        val height = feed.width / aspectRatio
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
 * The parent mounts this in the existing `zones.feed` box, so guide geometry
 * follows the exact shared-core feed zone instead of independently estimating
 * portrait or landscape bounds. The overlay is intentionally non-interactive:
 * controls stay in Operator Setup and no local affordance can mutate Nikon
 * camera settings.
 */
@Composable
public fun LocalFramingAssistOverlay(
    configuration: LocalFramingAssistConfiguration,
    cleanMode: Boolean,
    modifier: Modifier = Modifier,
) {
    BoxWithConstraints(
        modifier
            .fillMaxSize()
            .clearAndSetSemantics {
                contentDescription = configuration.accessibilitySummary
            },
    ) {
        val density = LocalDensity.current
        val plan =
            remember(configuration, cleanMode, maxWidth, maxHeight, density) {
                with(density) {
                    localFramingRenderPlan(
                        width = maxWidth.toPx(),
                        height = maxHeight.toPx(),
                        configuration = configuration,
                        cleanMode = cleanMode,
                    )
                }
            }
        val label = localFramingBadgeLabel(configuration)
        val guide = plan.guideRect
        Canvas(Modifier.fillMaxSize()) {
            plan.guideRect?.let { drawFrameGuide(it) }
            if (plan.drawsRuleOfThirds) drawThirdsGrid(plan.presentationRect)
            if (plan.drawsCenterCrosshair) drawCentreCrosshair(plan.presentationRect)
        }
        // A guide gives the label an unoccluded, content-aligned home. Do not
        // pin a desqueeze-only badge to the feed edge: the landscape capture
        // strip and portrait system bar own those edges.
        if (label != null && guide != null) {
            val inset = with(density) { 8.dp.roundToPx() }
            Text(
                text = label,
                style = chromeStyle(9.5f, FontWeight.Bold, mono = true),
                color = LiveDesign.text,
                modifier =
                    Modifier.offset {
                        IntOffset(
                            x = (guide.left + inset).roundToInt(),
                            y = (guide.top + inset).roundToInt(),
                        )
                    }
                        .background(LiveDesign.background.copy(alpha = 0.7f), ChromeShape)
                        .padding(horizontal = 7.dp, vertical = 4.dp),
            )
        }
    }
}

private fun localFramingBadgeLabel(configuration: LocalFramingAssistConfiguration): String? {
    if (configuration.guide == LocalFramingGuide.OFF) return null
    val labels = buildList {
        add("GUIDE ${configuration.guide.label}")
        if (configuration.desqueezePresentation != LocalDesqueezePresentation.OFF) {
            add("DESQ ${configuration.desqueezePresentation.label}")
        }
    }
    return labels.takeIf { it.isNotEmpty() }?.joinToString(separator = " · ")
}

private fun androidx.compose.ui.graphics.drawscope.DrawScope.drawFrameGuide(
    rect: FramingAssistRect,
) {
    drawRect(
        color = LiveDesign.accent.copy(alpha = 0.88f),
        topLeft = Offset(rect.left, rect.top),
        size = Size(rect.width, rect.height),
        style = Stroke(width = 1.dp.toPx()),
    )
}

private fun androidx.compose.ui.graphics.drawscope.DrawScope.drawThirdsGrid(
    rect: FramingAssistRect,
) {
    val strokeWidth = 1.dp.toPx()
    val color = Color.White.copy(alpha = 0.28f)
    listOf(1f / 3f, 2f / 3f).forEach { fraction ->
        val x = rect.left + rect.width * fraction
        val y = rect.top + rect.height * fraction
        drawLine(color, Offset(x, rect.top), Offset(x, rect.bottom), strokeWidth)
        drawLine(color, Offset(rect.left, y), Offset(rect.right, y), strokeWidth)
    }
}

private fun androidx.compose.ui.graphics.drawscope.DrawScope.drawCentreCrosshair(
    rect: FramingAssistRect,
) {
    val center = Offset(rect.centerX, rect.centerY)
    val arm = 20.dp.toPx()
    val strokeWidth = 1.4.dp.toPx()
    val color = Color.White.copy(alpha = 0.68f)
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

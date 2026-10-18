package com.opencapture.openzcine

import androidx.compose.runtime.Immutable
import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.opencapture.opencine.cameracontrols.FalseColorReference as CommonFalseColorReference
import com.opencapture.monitorui.MonitorFalseColorReferenceMarker
import com.opencapture.monitorui.MonitorFalseColorReferenceSegment
import com.opencapture.monitorui.MonitorFalseColorReferenceValues
import com.opencapture.monitorui.MonitorRect
import com.opencapture.monitorui.MonitorScopePanelSize
import kotlin.math.min

// The camera's false colour key (Swift owns the curve and clip policy) as values for the shared
// ruler, and its default spot under the feed.

private const val FALSE_COLOR_REFERENCE_WIDTH = 264f
private const val FALSE_COLOR_REFERENCE_HEIGHT = 52f
private const val FALSE_COLOR_REFERENCE_GAP = 10f
private const val FALSE_COLOR_REFERENCE_BOTTOM_CLEARANCE = 14f + LiveDesign.CONTROL_HEIGHT_DP

@Immutable
internal data class FalseColorReferencePresentation(
    val scale: FeedFalseColorScale,
    val reference: FeedFalseColorReference,
    val read709: Boolean = false,
)

/** Render-success state consumed by the unscaled sibling reference overlay. */
@Stable
public class LiveFeedEffectsPresentationState {
    internal var falseColorReference: FalseColorReferencePresentation? by mutableStateOf(null)
        private set

    internal fun present(scale: FeedFalseColorScale, reference: FeedFalseColorReference, read709: Boolean = false) {
        falseColorReference = FalseColorReferencePresentation(scale, reference, read709)
    }

    internal fun clear() {
        falseColorReference = null
    }
}

/** Preserves the established viewport-relative anchor, then applies control clearance exactly once. */
internal fun controlSafeFalseColorReferenceDefaultFrame(
    feed: MonitorRect,
    layout: MonitorAnalysisPanelLayout,
    bottomChromeClearance: Float = FALSE_COLOR_REFERENCE_BOTTOM_CLEARANCE,
    horizontalFraction: Float = 0f,
): MonitorRect =
    clampScopeFrame(
        falseColorReferenceDefaultFrame(
            feed = feed,
            viewport = layout.viewport,
            bottomChromeClearance = bottomChromeClearance,
            horizontalFraction = horizontalFraction,
        ),
        layout.safeBounds,
    )

/** iOS `feedOutsideCenter(.bottomLeading)` translated into the Android zone map. */
internal fun falseColorReferenceDefaultFrame(
    feed: MonitorRect,
    viewport: MonitorRect,
    bottomChromeClearance: Float = FALSE_COLOR_REFERENCE_BOTTOM_CLEARANCE,
    horizontalFraction: Float = 0f,
): MonitorRect {
    val feedBottom = feed.y + feed.height
    val outsideTop = feedBottom + FALSE_COLOR_REFERENCE_GAP
    val viewportBottom = viewport.y + viewport.height
    val top =
        if (outsideTop + FALSE_COLOR_REFERENCE_HEIGHT <= viewportBottom) {
            outsideTop
        } else {
            min(
                feedBottom,
                viewportBottom - bottomChromeClearance.coerceAtLeast(0f),
            ) - FALSE_COLOR_REFERENCE_GAP - FALSE_COLOR_REFERENCE_HEIGHT
        }
    return clampScopeFrame(
        MonitorRect(
            x =
                feed.x +
                    maxOf(0f, feed.width - min(FALSE_COLOR_REFERENCE_WIDTH, feed.width)) *
                    horizontalFraction.coerceIn(0f, 1f),
            y = top,
            width = min(FALSE_COLOR_REFERENCE_WIDTH, feed.width),
            height = FALSE_COLOR_REFERENCE_HEIGHT,
        ),
        viewport,
    )
}

/** The Swift reference as the shared ruler's values: bands, stop markers (STOPS) or axis words. */
internal fun FalseColorReferencePresentation.referenceValues(): MonitorFalseColorReferenceValues {
    val curve = reference.curveLabel(read709)
    return MonitorFalseColorReferenceValues(
        subtitle = "${scale.label} · $curve",
        segments =
            reference.segments.mapIndexed { index, segment ->
                MonitorFalseColorReferenceSegment(
                    index,
                    segment.lowerFraction.toDouble(),
                    segment.upperFraction.toDouble(),
                    segment.color[0].toDouble(),
                    segment.color[1].toDouble(),
                    segment.color[2].toDouble(),
                )
            },
        markers =
            if (scale == FeedFalseColorScale.STOPS) {
                // The shared ruler starts each label 10 dp before its stop and clips at the panel, so the
                // Min and Max ends (0 and 1) are held 16 dp inside it, where the old ruler aligned them.
                val edge = 16.0 / MonitorScopePanelSize.falseColorReference.width
                reference.stopMarkerLabels.zip(reference.stopMarkerFractions.toList()).mapIndexed { index, (label, at) ->
                    MonitorFalseColorReferenceMarker(index, label, at.toDouble().coerceIn(edge, 1.0 - edge))
                }
            } else {
                emptyList()
            },
        axisLabels = CommonFalseColorReference.axisLabels(scale.sharedScale),
    )
}

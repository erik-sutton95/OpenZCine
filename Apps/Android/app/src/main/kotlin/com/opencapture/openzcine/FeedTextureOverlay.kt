package com.opencapture.openzcine

import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawWithCache
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.clipRect
import androidx.compose.ui.unit.dp

/** Source dimensions retained independently from per-frame presentation state. */
@Immutable
internal data class FeedTextureSourceGeometry(
    val width: Int,
    val height: Int,
)

/**
 * Reuses the existing geometry while the stream resolution is unchanged, so
 * this texture-specific state allocates and invalidates only for a genuine
 * resolution change.
 */
internal fun retainedFeedTextureSourceGeometry(
    current: FeedTextureSourceGeometry?,
    width: Int,
    height: Int,
): FeedTextureSourceGeometry? {
    if (width <= 0 || height <= 0) return null
    if (current?.width == width && current.height == height) return current
    return FeedTextureSourceGeometry(width = width, height = height)
}

/** iOS-matched, deterministic feed texture constants and normalized samples. */
internal object FeedTexturePattern {
    const val VIGNETTE_START_RADIUS_DP = 70f
    const val VIGNETTE_END_RADIUS_DP = 620f
    const val VIGNETTE_EDGE_OPACITY = 0.46f
    const val GRAIN_SAMPLE_COUNT = 180
    const val GRAIN_SIZE_DP = 1f

    val normalizedX: FloatArray =
        FloatArray(GRAIN_SAMPLE_COUNT) { index ->
            ((index * 73) % 791).toFloat() / 791f
        }
    val normalizedY: FloatArray =
        FloatArray(GRAIN_SAMPLE_COUNT) { index ->
            ((index * 47) % 367).toFloat() / 367f
        }
    val opacity: FloatArray =
        FloatArray(GRAIN_SAMPLE_COUNT) { index ->
            0.016f + (index % 5) * 0.004f
        }
}

/**
 * Exact on-screen image rectangle receiving the texture. Fit letterbox and
 * de-squeeze bars are excluded; fill overhang is intersected with the viewport.
 */
internal fun feedTextureVisibleRect(
    containerWidth: Float,
    containerHeight: Float,
    sourceWidth: Int,
    sourceHeight: Int,
    aspectFill: Boolean,
    horizontalPresentationScale: Float,
    verticalPresentationScale: Float,
): LiveOverlayRect? {
    val content =
        liveFeedContentRect(
            containerWidth = containerWidth,
            containerHeight = containerHeight,
            sourceWidth = sourceWidth,
            sourceHeight = sourceHeight,
            aspectFill = aspectFill,
        ) ?: return null
    val presented =
        liveOverlayFeedRect(
            content = content,
            horizontalPresentationScale = horizontalPresentationScale,
            verticalPresentationScale = verticalPresentationScale,
        ) ?: return null
    val viewport =
        LiveOverlayRect(
            left = 0f,
            top = 0f,
            width = containerWidth,
            height = containerHeight,
        )
    return intersectLiveOverlayRects(presented, viewport)
}

/**
 * Static presentation texture composited after the feed renderer and before
 * focus, framing, horizon, and monitor chrome. The cache observes geometry and
 * operator presentation only, never the per-frame bitmap state.
 */
@Composable
internal fun FeedTextureOverlay(
    presentationState: LiveFeedPresentationState,
    aspectFill: Boolean,
    horizontalPresentationScale: Float,
    verticalPresentationScale: Float,
    modifier: Modifier = Modifier,
) {
    val source = presentationState.feedTextureSourceGeometry
    val sourceWidth = source?.width ?: 0
    val sourceHeight = source?.height ?: 0

    Spacer(
        modifier
            .fillMaxSize()
            // Brush and geometry objects rebuild only when this cache's layout or captured
            // presentation values change. This does not claim an off-screen raster or FPS gain.
            .drawWithCache {
                val visible =
                    feedTextureVisibleRect(
                        containerWidth = size.width,
                        containerHeight = size.height,
                        sourceWidth = sourceWidth,
                        sourceHeight = sourceHeight,
                        aspectFill = aspectFill,
                        horizontalPresentationScale = horizontalPresentationScale,
                        verticalPresentationScale = verticalPresentationScale,
                    )
                if (visible == null) {
                    onDrawBehind {}
                } else {
                    val startFraction =
                        FeedTexturePattern.VIGNETTE_START_RADIUS_DP /
                            FeedTexturePattern.VIGNETTE_END_RADIUS_DP
                    val vignette =
                        Brush.radialGradient(
                            colorStops =
                                arrayOf(
                                    0f to Color.Transparent,
                                    startFraction to Color.Transparent,
                                    1f to
                                        Color.Black.copy(
                                            alpha = FeedTexturePattern.VIGNETTE_EDGE_OPACITY,
                                        ),
                                ),
                            center = Offset(visible.centerX, visible.centerY),
                            radius = FeedTexturePattern.VIGNETTE_END_RADIUS_DP.dp.toPx(),
                        )
                    val grainSize = FeedTexturePattern.GRAIN_SIZE_DP.dp.toPx()
                    val grainRadius = grainSize / 2f

                    onDrawBehind {
                        clipRect(
                            left = visible.left,
                            top = visible.top,
                            right = visible.right,
                            bottom = visible.bottom,
                        ) {
                            // Source-over black is equivalent to the iOS multiply vignette here,
                            // without requesting an off-screen compositing layer.
                            drawRect(
                                brush = vignette,
                                topLeft = Offset(visible.left, visible.top),
                                size = Size(visible.width, visible.height),
                            )
                            for (index in 0 until FeedTexturePattern.GRAIN_SAMPLE_COUNT) {
                                drawCircle(
                                    color = Color.White,
                                    radius = grainRadius,
                                    center =
                                        Offset(
                                            x =
                                                visible.left +
                                                    FeedTexturePattern.normalizedX[index] *
                                                    visible.width +
                                                    grainRadius,
                                            y =
                                                visible.top +
                                                    FeedTexturePattern.normalizedY[index] *
                                                    visible.height +
                                                    grainRadius,
                                        ),
                                    alpha = FeedTexturePattern.opacity[index],
                                )
                            }
                        }
                    }
                }
            },
    )
}

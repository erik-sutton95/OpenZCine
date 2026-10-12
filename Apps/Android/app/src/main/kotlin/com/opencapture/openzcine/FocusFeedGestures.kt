package com.opencapture.openzcine

import com.opencapture.opencine.nikon.LiveFocusInfo
import com.opencapture.opencine.appkit.MonitorDisplayMode
import kotlin.math.abs
import com.opencapture.opencine.runtime.NativeFeedContentRect

import com.opencapture.monitorui.*

internal typealias FocusFeedPixelPoint = MonitorFocusPixelPoint
internal typealias FocusFeedCoordinate = MonitorFocusCoordinate
internal typealias FocusFeedGeometrySignature = MonitorFocusGeometrySignature
internal typealias FocusFeedGestureThresholds = MonitorFocusGestureThresholds
internal typealias FocusFeedGestureState = MonitorFocusGestureState
internal typealias FocusFeedGestureEvent = MonitorFocusGestureEvent

internal data class FocusFeedGeometry(
    val presentedFeed: LiveOverlayRect, val hitBounds: LiveOverlayRect,
    val coordinateWidth: Int?, val coordinateHeight: Int?, val generation: Long, val mirrored: Boolean = false,
    val mirroredVertical: Boolean = false,
) {
    internal val common: MonitorFocusGeometry get() = MonitorFocusGeometry(
        MonitorRect(presentedFeed.left, presentedFeed.top, presentedFeed.width, presentedFeed.height),
        MonitorRect(hitBounds.left, hitBounds.top, hitBounds.width, hitBounds.height),
        coordinateWidth, coordinateHeight, generation, mirrored, mirroredVertical)
    init { common }
    val signature: FocusFeedGeometrySignature get() = common.signature
    val hasAuthoritativeCoordinateSpace: Boolean get() = common.hasAuthoritativeCoordinateSpace
    fun acceptsGestureAt(point: FocusFeedPixelPoint): Boolean = common.acceptsGestureAt(point)
    fun cameraCoordinateAt(point: FocusFeedPixelPoint): FocusFeedCoordinate? = common.cameraCoordinateAt(point)
}

/**
 * Builds direct-AF geometry from the exact feed destination and local presentation transforms.
 *
 * Camera coordinate dimensions have no fallback here. The presentation geometry remains usable
 * for DISP swipes when authoritative positive AF dimensions are absent, while direct AF mapping
 * remains unavailable.
 */
internal fun focusFeedGeometry(
    content: NativeFeedContentRect,
    horizontalPresentationScale: Float,
    verticalPresentationScale: Float = 1f,
    viewport: LiveOverlayRect,
    coordinateWidth: Int? = null,
    coordinateHeight: Int? = null,
    generation: Long,
    mirrored: Boolean = false,
    mirroredVertical: Boolean = false,
): FocusFeedGeometry? {
    if (!viewport.hasFinitePositiveSize()) return null
    val presented =
        liveOverlayFeedRect(
            content = content,
            horizontalPresentationScale = horizontalPresentationScale,
            verticalPresentationScale = verticalPresentationScale,
        ) ?: return null
    val visible = intersectLiveOverlayRects(presented, viewport) ?: return null
    val hasCoordinateSpace =
        coordinateWidth != null &&
            coordinateHeight != null &&
            coordinateWidth > 0 &&
            coordinateHeight > 0
    return FocusFeedGeometry(
        presentedFeed = presented,
        hitBounds = visible,
        coordinateWidth = coordinateWidth.takeIf { hasCoordinateSpace },
        coordinateHeight = coordinateHeight.takeIf { hasCoordinateSpace },
        generation = generation,
        mirrored = mirrored,
        mirroredVertical = mirroredVertical,
    )
}

/** Display-only feed-zone geometry used before the first decoded frame reports source dimensions. */
internal fun focusFeedViewportGeometry(
    viewport: LiveOverlayRect,
    generation: Long,
): FocusFeedGeometry? {
    if (!viewport.hasFinitePositiveSize()) return null
    return FocusFeedGeometry(
        presentedFeed = viewport,
        hitBounds = viewport,
        coordinateWidth = null,
        coordinateHeight = null,
        generation = generation,
    )
}

/** Whether real camera metadata can safely authorize AF placement and app-lock gestures. */
internal fun focusMetadataSupportsDirectInput(focus: LiveFocusInfo?): Boolean =
    focus != null &&
        !focus.isDebugFixture &&
        focus.coordinateWidth > 0 &&
        focus.coordinateHeight > 0 &&
        focus.boxes.isNotEmpty()

/** Whether the camera-authoritative primary box or tracking state makes reset useful. */
internal fun focusResetAvailable(
    focus: LiveFocusInfo?,
    focusPointLocked: Boolean,
): Boolean {
    if (
        focusPointLocked ||
            !focusMetadataSupportsDirectInput(focus)
    ) {
        return false
    }
    val authoritativeFocus = requireNotNull(focus)
    val primary = authoritativeFocus.boxes.first()
    val trackingLatched =
        authoritativeFocus.trackingAFActive ||
            (
                authoritativeFocus.subjectDetectionActive &&
                    (
                        authoritativeFocus.boxes.size > 1 ||
                            (authoritativeFocus.selectedBoxIndex ?: 0) > 0
                    )
                )
    if (trackingLatched) return true
    val horizontalOffset =
        abs(primary.centerX - authoritativeFocus.coordinateWidth / 2f) /
            authoritativeFocus.coordinateWidth
    val verticalOffset =
        abs(primary.centerY - authoritativeFocus.coordinateHeight / 2f) /
            authoritativeFocus.coordinateHeight
    return horizontalOffset > 0.04f || verticalOffset > 0.04f
}


private fun LiveOverlayRect.hasFinitePositiveSize(): Boolean =
    left.isFinite() && top.isFinite() && width.isFinite() && height.isFinite() && width > 0f && height > 0f

internal data class FocusFeedGestureContext(
    val geometry: FocusFeedGeometry?, val interfaceLocked: Boolean = false, val focusPointLocked: Boolean = false,
    val focusAvailable: Boolean = true, val commandPending: Boolean = false, val mediaBusy: Boolean = false,
) {
    internal val common: MonitorFocusGestureContext get() = MonitorFocusGestureContext(
        geometry?.common, interfaceLocked, focusPointLocked, focusAvailable, commandPending, mediaBusy)
    val canRecognizeDisplayGesture: Boolean get() = common.canRecognizeDisplayGesture
    val canRecognizeFocusGesture: Boolean get() = common.canRecognizeFocusGesture
    val canSetFocusPoint: Boolean get() = common.canSetFocusPoint
}
internal sealed interface FocusFeedGestureAction {
    data class SetFocusPoint(val coordinate: FocusFeedCoordinate) : FocusFeedGestureAction
    data class RequestDisplayMode(val mode: MonitorDisplayMode) : FocusFeedGestureAction
    data object ToggleFocusPointLock : FocusFeedGestureAction
}
internal fun MonitorFocusGestureAction.sourceRequest(): FocusFeedGestureAction = when (this) {
    is MonitorFocusGestureAction.SetFocusPoint -> FocusFeedGestureAction.SetFocusPoint(coordinate)
    is MonitorFocusGestureAction.RequestDisplayMode -> FocusFeedGestureAction.RequestDisplayMode(
        if (mode == MonitorFocusDisplayRequest.CLEAN) MonitorDisplayMode.CLEAN else MonitorDisplayMode.LIVE)
    MonitorFocusGestureAction.ToggleFocusPointLock -> FocusFeedGestureAction.ToggleFocusPointLock
}
internal data class FocusFeedGestureReduction(val state: MonitorFocusGestureState, val action: FocusFeedGestureAction? = null)
internal fun reduceFocusFeedGesture(state: MonitorFocusGestureState, event: MonitorFocusGestureEvent,
    context: FocusFeedGestureContext, thresholds: MonitorFocusGestureThresholds = MonitorFocusGestureThresholds.Default): FocusFeedGestureReduction {
    val result = reduceMonitorFocusGesture(state, event, context.common, thresholds)
    return FocusFeedGestureReduction(result.state, result.action?.sourceRequest())
}

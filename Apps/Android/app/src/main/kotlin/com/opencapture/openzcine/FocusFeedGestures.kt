package com.opencapture.openzcine

import com.opencapture.openzcine.core.LiveFocusInfo
import com.opencapture.openzcine.settings.MonitorDisplayMode
import kotlin.math.abs
import kotlin.math.hypot
import kotlin.math.roundToInt

/** One point in the feed composable's local pixel coordinate space. */
internal data class FocusFeedPixelPoint(
    val x: Float,
    val y: Float,
)

/** One direct AF point in the camera's authoritative live-view coordinate space. */
internal data class FocusFeedCoordinate(
    val x: Int,
    val y: Int,
)

/** Geometry identity captured when a feed gesture begins. */
internal data class FocusFeedGeometrySignature(
    val generation: Long,
    val presentedFeed: LiveOverlayRect,
    val hitBounds: LiveOverlayRect,
    val coordinateWidth: Int?,
    val coordinateHeight: Int?,
)

/**
 * Exact feed geometry used to inverse-map pointer input into camera AF coordinates.
 *
 * [presentedFeed] is the full rendered and de-squeezed image, including any cropped overhang.
 * [hitBounds] is only the visible intersection used to accept or reject input. Mapping always uses
 * [presentedFeed], so a fill crop cannot incorrectly stretch the visible slice across the camera's
 * whole coordinate space.
 */
internal data class FocusFeedGeometry(
    val presentedFeed: LiveOverlayRect,
    val hitBounds: LiveOverlayRect,
    val coordinateWidth: Int?,
    val coordinateHeight: Int?,
    val generation: Long,
) {
    init {
        require(presentedFeed.hasFinitePositiveSize())
        require(hitBounds.hasFinitePositiveSize())
        require((coordinateWidth == null) == (coordinateHeight == null))
        require(coordinateWidth == null || coordinateWidth > 0)
        require(coordinateHeight == null || coordinateHeight > 0)
    }

    /** True only when real camera metadata supplied a usable AF coordinate space. */
    val hasAuthoritativeCoordinateSpace: Boolean
        get() = coordinateWidth != null && coordinateHeight != null

    val signature: FocusFeedGeometrySignature
        get() =
            FocusFeedGeometrySignature(
                generation = generation,
                presentedFeed = presentedFeed,
                hitBounds = hitBounds,
                coordinateWidth = coordinateWidth,
                coordinateHeight = coordinateHeight,
            )

    /** Whether [point] lands on the visible rendered feed, independent of AF metadata. */
    fun acceptsGestureAt(point: FocusFeedPixelPoint): Boolean =
        point.x.isFinite() && point.y.isFinite() && hitBounds.containsInclusive(point)

    /**
     * Maps a visible feed-local pixel to a camera coordinate, or rejects the point.
     *
     * Nikon's dimensions describe a zero-based coordinate space, so inclusive endpoints are
     * `0...(dimension - 1)`. The right and bottom feed edges must never emit the dimension itself.
     */
    fun cameraCoordinateAt(point: FocusFeedPixelPoint): FocusFeedCoordinate? {
        val width = coordinateWidth ?: return null
        val height = coordinateHeight ?: return null
        if (!acceptsGestureAt(point)) return null

        val normalizedX = ((point.x - presentedFeed.left) / presentedFeed.width).coerceIn(0f, 1f)
        val normalizedY = ((point.y - presentedFeed.top) / presentedFeed.height).coerceIn(0f, 1f)
        return FocusFeedCoordinate(
            x =
                (normalizedX * (width - 1))
                    .roundToInt()
                    .coerceIn(0, width - 1),
            y =
                (normalizedY * (height - 1))
                    .roundToInt()
                    .coerceIn(0, height - 1),
        )
    }
}

/**
 * Builds direct-AF geometry from the exact feed destination and local presentation transforms.
 *
 * Camera coordinate dimensions have no fallback here. The presentation geometry remains usable
 * for DISP swipes when authoritative positive AF dimensions are absent, while direct AF mapping
 * remains unavailable.
 */
internal fun focusFeedGeometry(
    content: LiveFeedContentRect,
    horizontalPresentationScale: Float,
    verticalPresentationScale: Float = 1f,
    viewport: LiveOverlayRect,
    coordinateWidth: Int? = null,
    coordinateHeight: Int? = null,
    generation: Long,
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

/** Feed and command conditions sampled for each pure gesture-reducer event. */
internal data class FocusFeedGestureContext(
    val geometry: FocusFeedGeometry?,
    val interfaceLocked: Boolean = false,
    val focusPointLocked: Boolean = false,
    val focusAvailable: Boolean = true,
    val commandPending: Boolean = false,
    val mediaBusy: Boolean = false,
) {
    /** DISP gestures only need a visible feed and the app-wide interface lock to be open. */
    val canRecognizeDisplayGesture: Boolean
        get() =
            geometry != null &&
                !interfaceLocked

    /** AF placement and app-lock gestures require authoritative, non-busy camera focus state. */
    val canRecognizeFocusGesture: Boolean
        get() =
            canRecognizeDisplayGesture &&
                focusAvailable &&
                !commandPending &&
                !mediaBusy &&
                geometry?.hasAuthoritativeCoordinateSpace == true

    val canSetFocusPoint: Boolean
        get() = canRecognizeFocusGesture && !focusPointLocked
}

/** Motion and timing thresholds, expressed in the same local units as pointer positions. */
internal data class FocusFeedGestureThresholds(
    val holdDurationMillis: Long = 300L,
    val holdSlop: Float = 10f,
    val dragStartDistance: Float = 28f,
    val completedSwipeDistance: Float = 44f,
    val swipeAxisMargin: Float = 8f,
) {
    init {
        require(holdDurationMillis > 0L)
        require(holdSlop >= 0f && holdSlop.isFinite())
        require(dragStartDistance > 0f && dragStartDistance.isFinite())
        require(completedSwipeDistance > 0f && completedSwipeDistance.isFinite())
        require(swipeAxisMargin >= 0f && swipeAxisMargin.isFinite())
    }

    companion object {
        /** iOS-parity thresholds when the reducer receives logical-point positions. */
        val Default: FocusFeedGestureThresholds = FocusFeedGestureThresholds()

        /** iOS-parity logical thresholds scaled for Compose pointer positions, which are pixels. */
        fun forDensity(density: Float): FocusFeedGestureThresholds {
            require(density > 0f && density.isFinite())
            return FocusFeedGestureThresholds(
                holdSlop = 10f * density,
                dragStartDistance = 28f * density,
                completedSwipeDistance = 44f * density,
                swipeAxisMargin = 8f * density,
            )
        }
    }
}

/** State retained by the pure feed-gesture reducer between pointer events. */
internal sealed interface FocusFeedGestureState {
    data object Idle : FocusFeedGestureState

    data class Tracking(
        val down: FocusFeedPixelPoint,
        val current: FocusFeedPixelPoint,
        val downUptimeMillis: Long,
        val holdEligible: Boolean,
        val geometrySignature: FocusFeedGeometrySignature,
    ) : FocusFeedGestureState

    data class Dragging(
        val down: FocusFeedPixelPoint,
        val current: FocusFeedPixelPoint,
        val geometrySignature: FocusFeedGeometrySignature,
    ) : FocusFeedGestureState

    data class Held(
        val geometrySignature: FocusFeedGeometrySignature,
    ) : FocusFeedGestureState
}

/** One input event accepted by [reduceFocusFeedGesture]. */
internal sealed interface FocusFeedGestureEvent {
    data class Down(
        val position: FocusFeedPixelPoint,
        val uptimeMillis: Long,
        val pointerCount: Int = 1,
        val consumed: Boolean = false,
    ) : FocusFeedGestureEvent

    data class Move(
        val position: FocusFeedPixelPoint,
        val uptimeMillis: Long,
        val pointerCount: Int = 1,
        val consumed: Boolean = false,
    ) : FocusFeedGestureEvent

    data class HoldTimeout(
        val uptimeMillis: Long,
    ) : FocusFeedGestureEvent

    data class Up(
        val position: FocusFeedPixelPoint,
        val uptimeMillis: Long,
        val pointerCount: Int = 1,
        val consumed: Boolean = false,
    ) : FocusFeedGestureEvent

    /** Re-evaluates gates and geometry without manufacturing a pointer event. */
    data object ContextChanged : FocusFeedGestureEvent

    data object Cancel : FocusFeedGestureEvent
}

/** A side effect requested by the feed reducer for the Compose owner to execute. */
internal sealed interface FocusFeedGestureAction {
    data class SetFocusPoint(
        val coordinate: FocusFeedCoordinate,
    ) : FocusFeedGestureAction

    data class RequestDisplayMode(
        val mode: MonitorDisplayMode,
    ) : FocusFeedGestureAction

    data object ToggleFocusPointLock : FocusFeedGestureAction
}

/** Next reducer state and its optional one-shot side effect. */
internal data class FocusFeedGestureReduction(
    val state: FocusFeedGestureState,
    val action: FocusFeedGestureAction? = null,
)

/**
 * Reduces one feed-pointer event without retaining state or performing side effects.
 *
 * The caller must provide pointer counts including the lifted primary pointer on
 * [FocusFeedGestureEvent.Up]. Any second pointer, consumed event, interface lock, or geometry
 * identity change cancels the entire touch sequence until a fresh
 * [FocusFeedGestureEvent.Down].
 */
internal fun reduceFocusFeedGesture(
    state: FocusFeedGestureState,
    event: FocusFeedGestureEvent,
    context: FocusFeedGestureContext,
    thresholds: FocusFeedGestureThresholds = FocusFeedGestureThresholds.Default,
): FocusFeedGestureReduction {
    if (event === FocusFeedGestureEvent.Cancel) return idleReduction()
    if (event.invalidatesPointerSequence()) return idleReduction()
    if (!context.canRecognizeDisplayGesture) return idleReduction()

    val geometry = context.geometry ?: return idleReduction()
    val stateSignature = state.geometrySignatureOrNull()
    val currentState =
        if (stateSignature == null || stateSignature == geometry.signature) {
            state
        } else {
            FocusFeedGestureState.Idle
        }
    return when (event) {
        is FocusFeedGestureEvent.Down -> reduceDown(currentState, event, geometry, context)
        is FocusFeedGestureEvent.Move -> reduceMove(currentState, event, context, thresholds)
        is FocusFeedGestureEvent.HoldTimeout ->
            reduceHoldTimeout(currentState, event, context, thresholds)
        is FocusFeedGestureEvent.Up -> reduceUp(currentState, event, context, thresholds)
        FocusFeedGestureEvent.ContextChanged ->
            FocusFeedGestureReduction(
                if (currentState is FocusFeedGestureState.Tracking) {
                    currentState.copy(
                        holdEligible =
                            currentState.holdEligible && context.canRecognizeFocusGesture,
                    )
                } else {
                    currentState
                },
            )
        FocusFeedGestureEvent.Cancel -> idleReduction()
    }
}

private fun reduceDown(
    state: FocusFeedGestureState,
    event: FocusFeedGestureEvent.Down,
    geometry: FocusFeedGeometry,
    context: FocusFeedGestureContext,
): FocusFeedGestureReduction {
    if (state !== FocusFeedGestureState.Idle) return idleReduction()
    if (!geometry.acceptsGestureAt(event.position)) return idleReduction()
    return FocusFeedGestureReduction(
        FocusFeedGestureState.Tracking(
            down = event.position,
            current = event.position,
            downUptimeMillis = event.uptimeMillis,
            holdEligible = context.canRecognizeFocusGesture,
            geometrySignature = geometry.signature,
        ),
    )
}

private fun reduceMove(
    state: FocusFeedGestureState,
    event: FocusFeedGestureEvent.Move,
    context: FocusFeedGestureContext,
    thresholds: FocusFeedGestureThresholds,
): FocusFeedGestureReduction =
    when (state) {
        is FocusFeedGestureState.Tracking -> {
            val distance = state.down.distanceTo(event.position)
            val updated =
                state.copy(
                    current = event.position,
                    holdEligible = state.holdEligible && distance <= thresholds.holdSlop,
                )
            when {
                distance >= thresholds.dragStartDistance ->
                    FocusFeedGestureReduction(
                        FocusFeedGestureState.Dragging(
                            down = state.down,
                            current = event.position,
                            geometrySignature = state.geometrySignature,
                        ),
                    )
                updated.holdEligible &&
                    context.canRecognizeFocusGesture &&
                    event.uptimeMillis - state.downUptimeMillis >= thresholds.holdDurationMillis ->
                    heldReduction(state.geometrySignature)
                else -> FocusFeedGestureReduction(updated)
            }
        }
        is FocusFeedGestureState.Dragging ->
            FocusFeedGestureReduction(state.copy(current = event.position))
        is FocusFeedGestureState.Held -> FocusFeedGestureReduction(state)
        FocusFeedGestureState.Idle -> idleReduction()
    }

private fun reduceHoldTimeout(
    state: FocusFeedGestureState,
    event: FocusFeedGestureEvent.HoldTimeout,
    context: FocusFeedGestureContext,
    thresholds: FocusFeedGestureThresholds,
): FocusFeedGestureReduction {
    if (state !is FocusFeedGestureState.Tracking || !state.holdEligible) {
        return FocusFeedGestureReduction(state)
    }
    val elapsed = event.uptimeMillis - state.downUptimeMillis
    return if (elapsed >= thresholds.holdDurationMillis) {
        if (context.canRecognizeFocusGesture) {
            heldReduction(state.geometrySignature)
        } else {
            FocusFeedGestureReduction(state.copy(holdEligible = false))
        }
    } else {
        FocusFeedGestureReduction(state)
    }
}

private fun reduceUp(
    state: FocusFeedGestureState,
    event: FocusFeedGestureEvent.Up,
    context: FocusFeedGestureContext,
    thresholds: FocusFeedGestureThresholds,
): FocusFeedGestureReduction =
    when (state) {
        is FocusFeedGestureState.Tracking -> reduceTrackingUp(state, event, context, thresholds)
        is FocusFeedGestureState.Dragging -> completeDrag(state.down, event.position, thresholds)
        is FocusFeedGestureState.Held -> idleReduction()
        FocusFeedGestureState.Idle -> idleReduction()
    }

private fun reduceTrackingUp(
    state: FocusFeedGestureState.Tracking,
    event: FocusFeedGestureEvent.Up,
    context: FocusFeedGestureContext,
    thresholds: FocusFeedGestureThresholds,
): FocusFeedGestureReduction {
    val distance = state.down.distanceTo(event.position)
    if (distance >= thresholds.dragStartDistance) {
        return completeDrag(state.down, event.position, thresholds)
    }
    val elapsed = event.uptimeMillis - state.downUptimeMillis
    if (
        context.canRecognizeFocusGesture &&
        state.holdEligible &&
            distance <= thresholds.holdSlop &&
            elapsed >= thresholds.holdDurationMillis
    ) {
        return FocusFeedGestureReduction(
            state = FocusFeedGestureState.Idle,
            action = FocusFeedGestureAction.ToggleFocusPointLock,
        )
    }
    if (!context.canSetFocusPoint) return idleReduction()
    val coordinate = context.geometry?.cameraCoordinateAt(event.position) ?: return idleReduction()
    return FocusFeedGestureReduction(
        state = FocusFeedGestureState.Idle,
        action = FocusFeedGestureAction.SetFocusPoint(coordinate),
    )
}

private fun completeDrag(
    down: FocusFeedPixelPoint,
    up: FocusFeedPixelPoint,
    thresholds: FocusFeedGestureThresholds,
): FocusFeedGestureReduction {
    val deltaX = up.x - down.x
    val deltaY = up.y - down.y
    val completed =
        abs(deltaY) > thresholds.completedSwipeDistance &&
            abs(deltaY) > abs(deltaX) + thresholds.swipeAxisMargin
    if (!completed) return idleReduction()
    return FocusFeedGestureReduction(
        state = FocusFeedGestureState.Idle,
        action =
            FocusFeedGestureAction.RequestDisplayMode(
                if (deltaY > 0f) MonitorDisplayMode.CLEAN else MonitorDisplayMode.LIVE,
            ),
    )
}

private fun heldReduction(
    signature: FocusFeedGeometrySignature,
): FocusFeedGestureReduction =
    FocusFeedGestureReduction(
        state = FocusFeedGestureState.Held(signature),
        action = FocusFeedGestureAction.ToggleFocusPointLock,
    )

private fun idleReduction(): FocusFeedGestureReduction =
    FocusFeedGestureReduction(FocusFeedGestureState.Idle)

private fun FocusFeedGestureState.geometrySignatureOrNull(): FocusFeedGeometrySignature? =
    when (this) {
        is FocusFeedGestureState.Tracking -> geometrySignature
        is FocusFeedGestureState.Dragging -> geometrySignature
        is FocusFeedGestureState.Held -> geometrySignature
        FocusFeedGestureState.Idle -> null
    }

private fun FocusFeedGestureEvent.invalidatesPointerSequence(): Boolean =
    when (this) {
        is FocusFeedGestureEvent.Down ->
            pointerCount != 1 || consumed || !position.hasFiniteCoordinates()
        is FocusFeedGestureEvent.Move ->
            pointerCount != 1 || consumed || !position.hasFiniteCoordinates()
        is FocusFeedGestureEvent.Up ->
            pointerCount != 1 || consumed || !position.hasFiniteCoordinates()
        is FocusFeedGestureEvent.HoldTimeout,
        FocusFeedGestureEvent.ContextChanged,
        FocusFeedGestureEvent.Cancel,
        -> false
    }

private fun FocusFeedPixelPoint.hasFiniteCoordinates(): Boolean = x.isFinite() && y.isFinite()

private fun FocusFeedPixelPoint.distanceTo(other: FocusFeedPixelPoint): Float =
    hypot(other.x - x, other.y - y)

private fun LiveOverlayRect.containsInclusive(point: FocusFeedPixelPoint): Boolean =
    point.x >= left && point.x <= right && point.y >= top && point.y <= bottom

private fun LiveOverlayRect.hasFinitePositiveSize(): Boolean =
    left.isFinite() &&
        top.isFinite() &&
        width.isFinite() &&
        height.isFinite() &&
        width > 0f &&
        height > 0f

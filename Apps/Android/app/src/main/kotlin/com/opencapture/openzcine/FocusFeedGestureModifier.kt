package com.opencapture.openzcine

import android.os.SystemClock
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.calculateZoom
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.Modifier
import androidx.compose.ui.input.pointer.PointerEvent
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput
import kotlinx.coroutines.withTimeoutOrNull

/**
 * One feed-local pointer arbiter for tap-to-focus, DISP swipe, focus lock, and feed zoom.
 *
 * ONE recognizer serves the drag's two roles — pan while zoomed, the DISP swipe when not. Two
 * drag recognizers on one surface arbitrate unpredictably: on iOS the earlier-recognizing pan
 * starved the swipe even while inert (`7020cf9`), which is why the roles share this arbiter here
 * rather than stacking a second `pointerInput`.
 *
 * A second pointer permanently cancels focus/lock/swipe recognition for that touch sequence and
 * drives the zoom instead: [onPinch] receives the accumulated factor together with the pinch's own
 * start centroid, so every pinch pivots on where it began rather than reusing a stale anchor.
 *
 * Full geometry, the interface lock, and [isZoomed] are pointer-input keys, so a rotation, crop,
 * de-squeeze, coordinate-space change, lock, or a change in the drag's role cancels the active
 * coroutine before a stale coordinate can be emitted. Updated-state callbacks and focus gates keep
 * later DISP swipes and focus decisions current without restarting solely for camera command
 * availability.
 */
@Composable
internal fun Modifier.focusFeedGestures(
    geometry: FocusFeedGeometry?,
    context: FocusFeedGestureContext,
    isPortrait: Boolean,
    isZoomed: Boolean,
    onHoldingChanged: (Boolean) -> Unit,
    onAction: (FocusFeedGestureAction) -> Unit,
    onPinch: (factor: Float, startX: Float, startY: Float) -> Unit,
    onPinchEnd: () -> Unit,
    onPan: (translationX: Float, translationY: Float) -> Unit,
    onPanEnd: () -> Unit,
): Modifier {
    val currentContext by rememberUpdatedState(context)
    val currentOnHoldingChanged by rememberUpdatedState(onHoldingChanged)
    val currentOnAction by rememberUpdatedState(onAction)
    val currentOnPinch by rememberUpdatedState(onPinch)
    val currentOnPinchEnd by rememberUpdatedState(onPinchEnd)
    val currentOnPan by rememberUpdatedState(onPan)
    val currentOnPanEnd by rememberUpdatedState(onPanEnd)
    return pointerInput(
        geometry,
        context.interfaceLocked,
        isPortrait,
        isZoomed,
    ) {
        val thresholds = FocusFeedGestureThresholds.forDensity(density)
        awaitEachGesture {
            var gestureState: FocusFeedGestureState = FocusFeedGestureState.Idle
            var pinchZoom = 1f
            var sawMultiplePointers = false
            // The pinch's own start centroid, captured once. Reusing an earlier pinch's anchor
            // makes the picture lunge sideways when you re-pinch after a pan.
            var pinchStart: FocusFeedPixelPoint? = null
            var panned = false

            fun reduce(event: FocusFeedGestureEvent) {
                val reduction =
                    reduceFocusFeedGesture(
                        state = gestureState,
                        event = event,
                        context = currentContext,
                        thresholds = thresholds,
                    )
                gestureState = reduction.state
                currentOnHoldingChanged(
                    (gestureState as? FocusFeedGestureState.Tracking)?.holdEligible == true,
                )
                reduction.action?.let { action ->
                    // While zoomed the drag is a pan, so its DISP swipe stands down. Taps still
                    // reach focus — only the swipe's lane is taken.
                    if (isZoomed && action is FocusFeedGestureAction.RequestDisplayMode) return@let
                    currentOnAction(action)
                }
            }

            try {
                val down =
                    awaitFirstDown(
                        requireUnconsumed = true,
                        pass = PointerEventPass.Main,
                    )
                reduce(
                    FocusFeedGestureEvent.Down(
                        position = FocusFeedPixelPoint(down.position.x, down.position.y),
                        uptimeMillis = down.uptimeMillis,
                        consumed = down.isConsumed,
                    ),
                )
                val holdDeadlineUptimeMillis =
                    SystemClock.uptimeMillis() + thresholds.holdDurationMillis
                while (true) {
                    val event =
                        awaitNextFocusPointerEvent(
                            state = gestureState,
                            holdDeadlineUptimeMillis = holdDeadlineUptimeMillis,
                        )
                    if (event == null) {
                        reduce(
                            FocusFeedGestureEvent.HoldTimeout(
                                down.uptimeMillis + thresholds.holdDurationMillis,
                            ),
                        )
                        continue
                    }
                    if (event.changes.any { it.isConsumed }) {
                        reduce(FocusFeedGestureEvent.Cancel)
                        return@awaitEachGesture
                    }

                    val pressedCount = event.changes.count { it.pressed }
                    if (pressedCount >= 2 || sawMultiplePointers) {
                        if (!sawMultiplePointers) {
                            sawMultiplePointers = true
                            reduce(FocusFeedGestureEvent.Cancel)
                            val pressed = event.changes.filter { it.pressed }
                            if (pressed.isNotEmpty()) {
                                pinchStart =
                                    FocusFeedPixelPoint(
                                        pressed.sumOf { it.position.x.toDouble() }
                                            .toFloat() / pressed.size,
                                        pressed.sumOf { it.position.y.toDouble() }
                                            .toFloat() / pressed.size,
                                    )
                            }
                        }
                        pinchZoom *= event.calculateZoom()
                        event.changes.forEach { it.consume() }
                        pinchStart?.let { currentOnPinch(pinchZoom, it.x, it.y) }
                        if (pressedCount == 0) {
                            currentOnPinchEnd()
                            return@awaitEachGesture
                        }
                        continue
                    }

                    val primary = event.changes.firstOrNull { it.id == down.id }
                        ?: event.changes.firstOrNull()
                        ?: run {
                            reduce(FocusFeedGestureEvent.Cancel)
                            return@awaitEachGesture
                        }
                    val point = FocusFeedPixelPoint(primary.position.x, primary.position.y)
                    if (pressedCount == 0) {
                        reduce(
                            FocusFeedGestureEvent.Up(
                                position = point,
                                uptimeMillis = primary.uptimeMillis,
                                pointerCount = event.changes.size,
                                consumed = primary.isConsumed,
                            ),
                        )
                        if (panned) currentOnPanEnd()
                        primary.consume()
                        return@awaitEachGesture
                    }
                    reduce(
                        FocusFeedGestureEvent.Move(
                            position = point,
                            uptimeMillis = primary.uptimeMillis,
                            pointerCount = pressedCount,
                            consumed = primary.isConsumed,
                        ),
                    )
                    if (isZoomed) {
                        // Cumulative from the touch-down, matching the iOS drag's `translation`,
                        // so the owner can hold it as in-flight state and commit once on release.
                        panned = true
                        currentOnPan(
                            point.x - down.position.x,
                            point.y - down.position.y,
                        )
                    }
                    primary.consume()
                }
            } finally {
                currentOnHoldingChanged(false)
            }
        }
    }
}

private suspend fun androidx.compose.ui.input.pointer.AwaitPointerEventScope.awaitNextFocusPointerEvent(
    state: FocusFeedGestureState,
    holdDeadlineUptimeMillis: Long,
): PointerEvent? {
    val tracking = state as? FocusFeedGestureState.Tracking
    if (tracking == null || !tracking.holdEligible) {
        return awaitPointerEvent(PointerEventPass.Main)
    }
    // Compose's test injector owns a virtual pointer-event clock. A real monotonic deadline keeps
    // coroutine scheduling in one clock domain, while the reducer still receives an event-relative
    // timestamp and therefore behaves identically for physical and injected input.
    val remaining = holdDeadlineUptimeMillis - SystemClock.uptimeMillis()
    if (remaining <= 0L) return null
    return withTimeoutOrNull(remaining) {
        awaitPointerEvent(PointerEventPass.Main)
    }
}

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
 * One feed-local pointer arbiter for tap-to-focus, DISP swipe, focus lock, and portrait pinch.
 *
 * A second pointer permanently cancels focus/lock/swipe recognition for that touch sequence and
 * hands only the accumulated pinch scale to [onPortraitPinch]. Full geometry and the interface
 * lock are pointer-input keys, so a rotation, crop, de-squeeze, coordinate-space change, or lock
 * cancels the active coroutine before a stale coordinate can be emitted. Updated-state callbacks
 * and focus gates keep later DISP swipes and focus decisions current without restarting solely for
 * camera command availability.
 */
@Composable
internal fun Modifier.focusFeedGestures(
    geometry: FocusFeedGeometry?,
    context: FocusFeedGestureContext,
    isPortrait: Boolean,
    onHoldingChanged: (Boolean) -> Unit,
    onAction: (FocusFeedGestureAction) -> Unit,
    onPortraitPinch: (Float) -> Unit,
): Modifier {
    val currentContext by rememberUpdatedState(context)
    val currentOnHoldingChanged by rememberUpdatedState(onHoldingChanged)
    val currentOnAction by rememberUpdatedState(onAction)
    val currentOnPortraitPinch by rememberUpdatedState(onPortraitPinch)
    return pointerInput(
        geometry,
        context.interfaceLocked,
        isPortrait,
    ) {
        val thresholds = FocusFeedGestureThresholds.forDensity(density)
        awaitEachGesture {
            var gestureState: FocusFeedGestureState = FocusFeedGestureState.Idle
            var pinchZoom = 1f
            var sawMultiplePointers = false

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
                reduction.action?.let(currentOnAction)
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
                        }
                        pinchZoom *= event.calculateZoom()
                        event.changes.forEach { it.consume() }
                        if (pressedCount == 0) {
                            if (isPortrait) currentOnPortraitPinch(pinchZoom)
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

package com.opencapture.openzcine

import android.os.Build
import android.view.HapticFeedbackConstants
import android.view.View
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.platform.LocalView

/**
 * Operator-facing haptics for the Android shell.
 *
 * iOS uses `UIImpactFeedbackGenerator` gated by `preferences.hapticsEnabled`. Android mirrors
 * that with [View.performHapticFeedback], but system "Touch feedback" is often off — when the
 * in-app toggle is on we ignore the global setting so the operator's preference wins.
 * [chromeClickable] and chrome presses call [selection] automatically.
 */
interface OperatorHaptics {
    fun selection()

    fun tick()

    fun confirm()

    fun longPress()

    companion object {
        val None: OperatorHaptics =
            object : OperatorHaptics {
                override fun selection() = Unit

                override fun tick() = Unit

                override fun confirm() = Unit

                override fun longPress() = Unit
            }
    }
}

/** Defaults to a no-op so previews and unit trees don't crash before a provider is installed. */
val LocalOperatorHaptics = staticCompositionLocalOf { OperatorHaptics.None }

private class ViewOperatorHaptics(
    private val view: View,
    private val enabled: () -> Boolean,
) : OperatorHaptics {
    override fun selection() {
        perform(
            preferred = HapticFeedbackConstants.CONTEXT_CLICK,
            fallback = HapticFeedbackConstants.KEYBOARD_TAP,
        )
    }

    override fun tick() {
        perform(
            preferred = HapticFeedbackConstants.CLOCK_TICK,
            fallback = HapticFeedbackConstants.KEYBOARD_TAP,
        )
    }

    override fun confirm() {
        val preferred =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                HapticFeedbackConstants.CONFIRM
            } else {
                HapticFeedbackConstants.LONG_PRESS
            }
        perform(preferred = preferred, fallback = HapticFeedbackConstants.LONG_PRESS)
    }

    override fun longPress() {
        perform(
            preferred = HapticFeedbackConstants.LONG_PRESS,
            fallback = HapticFeedbackConstants.KEYBOARD_TAP,
        )
    }

    private fun perform(preferred: Int, fallback: Int) {
        if (!enabled()) return
        // Some surfaces clear this; keep the app toggle authoritative.
        view.isHapticFeedbackEnabled = true
        // App toggle is the source of truth — don't let system Sound settings silence us.
        @Suppress("DEPRECATION")
        val flags = HapticFeedbackConstants.FLAG_IGNORE_GLOBAL_SETTING
        if (!view.performHapticFeedback(preferred, flags)) {
            view.performHapticFeedback(fallback, flags)
        }
    }
}

/** Builds a real haptic helper bound to the current [LocalView] and [enabled] gate. */
@Composable
fun rememberOperatorHaptics(enabled: () -> Boolean): OperatorHaptics {
    val view = LocalView.current
    val enabledState = rememberUpdatedState(enabled)
    return remember(view) { ViewOperatorHaptics(view) { enabledState.value() } }
}

/**
 * Fire a system haptic that respects the in-app operator toggle, not the global Sound setting.
 * Prefer [LocalOperatorHaptics] from Compose; this is for pointer/gesture code that only has a
 * [View].
 */
fun View.performOperatorHaptic(feedbackConstant: Int, enabled: Boolean = true) {
    if (!enabled) return
    isHapticFeedbackEnabled = true
    @Suppress("DEPRECATION")
    val flags = HapticFeedbackConstants.FLAG_IGNORE_GLOBAL_SETTING
    if (!performHapticFeedback(feedbackConstant, flags)) {
        performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP, flags)
    }
}

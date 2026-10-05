package com.opencapture.openzcine

import android.view.HapticFeedbackConstants
import android.view.View

/**
 * Fire a system haptic that respects the in-app operator toggle, not the global Sound setting.
 * Prefer appkit's `LocalOperatorHaptics` from Compose; this is for pointer/gesture code that only has a
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

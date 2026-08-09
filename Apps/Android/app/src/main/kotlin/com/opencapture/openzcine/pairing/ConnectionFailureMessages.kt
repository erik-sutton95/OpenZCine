package com.opencapture.openzcine.pairing

/**
 * Maps raw session/native failure strings to operator-facing copy, the Android
 * counterpart of iOS `StartupConnectionCopy.friendly` plus the
 * `rejectedInitiator` guidance in `NativeAppRoot`.
 *
 * Device logs show camera-AP Wi‑Fi often succeeds (Android may silently rejoin a
 * previously approved SSID) while the PTP-IP handshake fails with
 * `rejectedInitiator` — never bury that under a generic "Couldn't reach".
 */
/**
 * Whether a failure detail says the CAMERA no longer recognizes this phone — the signal that a
 * fresh pairing, not another saved-profile retry, is the remedy. `rejectedInitiator` is the
 * shared core's own `PTPIPHandshake` case name riding in the detail string; this is THE one
 * classifier — reconnect escalation and operator copy must never grow separate copies of it.
 */
internal fun indicatesCameraForgotThisPhone(detail: String?): Boolean {
    val lower = detail?.trim()?.lowercase().orEmpty()
    if (lower.isEmpty()) return false
    return lower.contains("rejectedinitiator") ||
        (lower.contains("rejected") && lower.contains("handshake")) ||
        lower.contains("rejected the ptp-ip")
}

/**
 * Whether a saved-profile attempt's failure says the profile itself is unusable and a fresh
 * pairing is the remedy — the Android twin of iOS `isSavedProfileUnavailable`. Beyond the
 * refusals above, a body that HANGS UP mid-establishment is a camera whose newly created
 * network profile has never met this initiator (the field diagnostics that motivated the iOS
 * fix: `pairing=skipped → "The camera ended the connection"`).
 */
internal fun indicatesSavedProfileUnavailable(detail: String?): Boolean {
    if (indicatesCameraForgotThisPhone(detail)) return true
    val lower = detail?.trim()?.lowercase().orEmpty()
    return lower.contains("closed the connection") || lower.contains("savedprofilerequired")
}

internal fun friendlyCameraConnectionFailure(raw: String?): String {
    val message = raw?.trim().orEmpty()
    if (message.isEmpty()) {
        return "Couldn't reach the camera. Check Wi‑Fi and try again."
    }
    val lower = message.lowercase()
    if (indicatesCameraForgotThisPhone(message)) {
        return "The camera didn't recognize this phone. On the camera, open Connect to PC and create or choose a profile for this phone, then try again."
    }
    if (lower.contains("timed out") || lower.contains("timeout")) {
        return "The camera didn't respond in time. Check Wi‑Fi and try again."
    }
    if (lower.contains("closed the connection")) {
        return "The camera ended the connection. Try again."
    }
    if (lower.contains("pairing") && lower.contains("code")) {
        return "The camera did not provide a pairing code. Restart Connect to PC on the camera, then pair again."
    }
    if (lower.contains("first-time pairing") || lower.contains("savedprofilerequired")) {
        return "This camera needs to pair with this phone again. Use Pair new camera, or create a Connect to PC profile for this phone."
    }
    // Never surface raw PTP opcode dumps to the operator.
    if (lower.contains("ptp-ip") || lower.contains("0x")) {
        return "Couldn't reach the camera. Check Wi‑Fi and try again."
    }
    return message
}

package com.opencapture.openzcine.pairing

import com.opencapture.opencine.nikon.CameraConnectionFailure
import com.opencapture.opencine.nikon.NikonBodyWake

/**
 * Operator copy for a failed camera connect, the Android counterpart of iOS
 * `StartupConnectionCopy.friendly` plus the `rejectedInitiator` guidance in `NativeAppRoot`.
 *
 * It reads the typed [CameraConnectionFailure] the Swift session layer sends, never the failure
 * message's words (A4-45). Device logs show camera-AP Wi-Fi often succeeds (Android may silently
 * rejoin a previously approved SSID) while the PTP-IP handshake refuses this initiator, so that
 * refusal gets its own guidance instead of a generic "Couldn't reach".
 *
 * [detail] is shown as is only when the failure has no copy of its own (another device holds the
 * camera, or an untyped failure) and the text is operator-facing; a blank or technical detail
 * reads as unreachable.
 */
internal fun friendlyCameraConnectionFailure(failure: CameraConnectionFailure?, detail: String?): String =
    when (failure) {
        CameraConnectionFailure.REJECTED_INITIATOR ->
            "The camera didn't recognize this phone. On the camera, open Connect to PC and create or choose a profile for this phone, then try again."
        CameraConnectionFailure.TIMEOUT -> "The camera didn't respond in time. Check Wi‑Fi and try again."
        CameraConnectionFailure.CAMERA_SILENT -> NikonBodyWake.silentMessage("")
        CameraConnectionFailure.CONNECTION_CLOSED -> "The camera ended the connection. Try again."
        CameraConnectionFailure.PAIRING_CHALLENGE_UNAVAILABLE ->
            "The camera did not provide a pairing code. Restart Connect to PC on the camera, then pair again."
        CameraConnectionFailure.SAVED_PROFILE_REQUIRED ->
            "This camera needs to pair with this phone again. Use Pair new camera, or create a Connect to PC profile for this phone."
        // The transport refusing a non-numeric dial target means some path handed the dialer a
        // non-address key (#327); the operator's remedy is the rejoin/rediscover flow.
        CameraConnectionFailure.NON_NUMERIC_HOST ->
            "Couldn't find the camera's address on its network. Rejoin the camera's Wi‑Fi and try again."
        // The body wake asked the network and nothing answered: the shared copy iOS shows.
        CameraConnectionFailure.CAMERA_SILENT -> NikonBodyWake.silentMessage("")
        // Never surface socket errors or PTP-IP packet dumps to the operator.
        CameraConnectionFailure.UNREACHABLE -> UNREACHABLE_COPY
        CameraConnectionFailure.BUSY, CameraConnectionFailure.OTHER, null ->
            detail?.trim()?.takeIf { it.isNotEmpty() && !it.looksTechnical() } ?: UNREACHABLE_COPY
    }

/**
 * An untyped failure's detail is shown only when it is operator text. A message naming a protocol
 * frame, a hex code or a transport exception is the dump the old text sanitizer replaced (ZAB-147).
 */
private fun String.looksTechnical(): Boolean {
    val lower = lowercase()
    return listOf("0x", "ptp", "errno", "exception").any { it in lower }
}

private const val UNREACHABLE_COPY = "Couldn't reach the camera. Check Wi‑Fi and try again."

package com.opencapture.openzcine

import com.opencapture.opencine.core.SessionCloseReason
import com.opencapture.opencine.nikon.CameraSession
import com.opencapture.opencine.nikon.NikonOpenCineSession
import kotlinx.coroutines.CoroutineScope
import java.util.IdentityHashMap

/**
 * One common session per native connection at the app root. Pairing, the cameras page and
 * the monitor share its identity and receipts; a cover never creates or closes an adapter.
 * The root's native-session retirement still releases the OS connection and camera-AP lease.
 */
internal class NikonShellSessions(private val scope: CoroutineScope) {
    private val sessions = IdentityHashMap<CameraSession, NikonOpenCineSession>()

    fun acquire(native: CameraSession): NikonOpenCineSession =
        sessions.getOrPut(native) { NikonOpenCineSession(native, scope) }

    fun retire(native: CameraSession) {
        sessions.remove(native)?.closeNow(SessionCloseReason.REQUESTED)
    }
}

/** Presentation-only targets over real observations. They never mutate the native state flow. */
internal fun com.opencapture.opencine.nikon.CameraPropertySnapshot.withPendingControls(
    pending: Map<com.opencapture.opencine.core.SettingKey, com.opencapture.opencine.core.SettingValue>,
): com.opencapture.opencine.nikon.CameraPropertySnapshot {
    var shown = this
    val iso = pending[com.opencapture.opencine.core.SettingKey.ISO] as? com.opencapture.opencine.core.SettingValue.Iso
    val manual = iso?.value as? com.opencapture.opencine.core.ISOValue.Manual
    if (manual != null) shown = shown.copy(iso = manual.iso.toLong(), isoAuto = false)
    val balance = pending[com.opencapture.opencine.core.SettingKey.WHITE_BALANCE] as? com.opencapture.opencine.core.SettingValue.WhiteBalance
    when (val value = balance?.value) {
        com.opencapture.opencine.core.WhiteBalanceValue.Auto -> shown = shown.copy(whiteBalanceMode = "Auto")
        is com.opencapture.opencine.core.WhiteBalanceValue.Preset -> shown = shown.copy(whiteBalanceMode = value.id)
        is com.opencapture.opencine.core.WhiteBalanceValue.Kelvin -> shown = shown.copy(whiteBalanceMode = "Color temp", whiteBalanceKelvin = value.kelvin)
        null -> Unit
    }
    return shown
}

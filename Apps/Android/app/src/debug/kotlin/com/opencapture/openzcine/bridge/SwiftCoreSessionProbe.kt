package com.opencapture.openzcine.bridge

import android.content.Intent
import android.util.Log
import com.opencapture.openzcine.core.CameraSessionState
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

/**
 * Debug-only end-to-end session probe: connects [SwiftCoreCameraSession] to a
 * camera (or fake-ZR server), reads real properties through the Swift core,
 * and disconnects gracefully — the whole run logged under the
 * `SwiftCoreCameraSession` logcat tag.
 *
 * Point it at a host:
 * ```
 * adb shell am start -n com.opencapture.openzcine/.MainActivity --es zc.session.host 192.168.1.1
 * ```
 * For a fake-ZR server on the development Mac, forward the PTP-IP port first:
 * `adb reverse tcp:15740 tcp:15740`, then use host `127.0.0.1`.
 */
object SwiftCoreSessionProbe {
    private const val TAG = "SwiftCoreCameraSession"

    /** String intent extra carrying the camera host for the probe. */
    const val EXTRA_SESSION_HOST = "zc.session.host"

    /** Starts the probe when [intent] carries [EXTRA_SESSION_HOST]; no-op otherwise. */
    fun maybeStart(intent: Intent) {
        val host = intent.getStringExtra(EXTRA_SESSION_HOST) ?: return
        if (!SwiftCore.isAvailable) {
            Log.w(TAG, "libOpenZCineAndroid.so not bundled — run `just android-core` first")
            return
        }
        CoroutineScope(Dispatchers.IO).launch { run(host) }
    }

    private suspend fun run(host: String) {
        Log.i(TAG, "probe: connecting to $host")
        val session =
            SwiftCoreCameraSession(host) { phase, detail ->
                Log.i(TAG, "phase: $phase${if (detail.isEmpty()) "" else " — $detail"}")
            }
        session.connect()

        val state = session.state.value
        if (state !is CameraSessionState.Connected) {
            Log.w(TAG, "probe: connect failed — state=$state")
            return
        }
        Log.i(
            TAG,
            "connected: ${state.identity.name} model=${state.identity.model} " +
                "serial=${state.identity.serialNumber}",
        )
        val battery = session.readProperty(SwiftCore.PROP_BATTERY_LEVEL)
        Log.i(TAG, "battery: ${battery ?: "<no answer>"}%")
        val recording = session.readProperty(SwiftCore.PROP_MOVIE_REC_PROHIBITION)
        Log.i(TAG, "recProhibition: ${recording ?: "<no answer>"} (0x0 = recordable)")

        session.disconnect()
        Log.i(TAG, "disconnected (graceful CloseSession)")
    }
}

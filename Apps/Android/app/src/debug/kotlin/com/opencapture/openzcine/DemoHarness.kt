package com.opencapture.openzcine

import android.content.Intent
import android.util.Log
import com.opencapture.openzcine.bridge.SwiftCore
import com.opencapture.openzcine.bridge.SwiftCoreCameraSession
import com.opencapture.openzcine.core.CameraIdentity
import com.opencapture.openzcine.core.CameraSession
import com.opencapture.openzcine.core.FakeCameraSession
import com.opencapture.openzcine.core.LiveFrameSource

/**
 * Debug-only demo hooks, mirroring `ios/Runner/DemoHarness.swift`: this real
 * implementation lives in `src/debug` only, `src/release` carries an inert
 * stub, so release builds physically cannot activate demo behaviour — the
 * Android equivalent of the iOS `#if DEBUG` isolation.
 *
 * Activate the synthetic feed:
 * ```
 * adb shell am start -n com.opencapture.openzcine/.MainActivity --ez zc.demo.feed true
 * ```
 * Or drive the REAL shell session (Swift-core PTP-IP connect + live view)
 * against a camera or fake-ZR server:
 * ```
 * adb shell am start -n com.opencapture.openzcine/.MainActivity --es zc.session.host <ipv4>
 * ```
 * (fake ZR on the development Mac: `adb reverse tcp:15740 tcp:15740`, host
 * `127.0.0.1`; connect phases log under the `SwiftCoreCameraSession` tag).
 */
object DemoHarness {
    private const val TAG = "SwiftCoreCameraSession"

    /** Boolean intent extra that switches the synthetic demo feed on. */
    const val EXTRA_DEMO_FEED = "zc.demo.feed"

    /** String intent extra carrying the camera host for a real Swift-core session. */
    const val EXTRA_SESSION_HOST = "zc.session.host"

    /**
     * The debug session/feed override for [intent], or null in a normal
     * launch: `zc.session.host` makes the shell session a real
     * [SwiftCoreCameraSession] (null frame source — the shell streams the
     * session's own live view once connected); `zc.demo.feed` pairs a fake
     * session with the synthetic 25 fps frame source.
     */
    fun demoLiveFeed(intent: Intent): Pair<CameraSession, LiveFrameSource?>? {
        intent.getStringExtra(EXTRA_SESSION_HOST)?.let { host ->
            if (!SwiftCore.isAvailable) {
                Log.w(TAG, "libOpenZCineAndroid.so not bundled — run `just android-core` first")
            }
            Log.i(TAG, "shell session → Swift core at $host")
            return SwiftCoreCameraSession(host) { phase, detail ->
                Log.i(TAG, "phase: $phase${if (detail.isEmpty()) "" else " — $detail"}")
            } to null
        }
        if (!intent.getBooleanExtra(EXTRA_DEMO_FEED, false)) return null
        val session =
            FakeCameraSession(
                CameraIdentity(name = "Demo Feed", model = "OpenZCine Demo", serialNumber = "DEMO"),
            )
        return session to DemoFrameSource()
    }
}

package com.opencapture.openzcine

import android.content.Intent
import com.opencapture.openzcine.bridge.SwiftCoreSessionProbe
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
 *
 * Feed effects (needs API 33 + the staged Swift core; combine freely):
 * ```
 * --es zc.assist lut,falsecolor,peaking,zebra   which effects are on
 * --es zc.lut log3g10|nlog|mono                 built-in look (default log3g10)
 * --es zc.fc.scale stops|ire                    false-colour scale (default stops)
 * ```
 */
object DemoHarness {
    /** Boolean intent extra that switches the synthetic demo feed on. */
    const val EXTRA_DEMO_FEED = "zc.demo.feed"

    /**
     * A demo session + synthetic 25 fps frame source when [intent] carries
     * [EXTRA_DEMO_FEED]; null in a normal launch. Also the debug intent entry
     * point for the Swift-core session probe (`zc.session.host` — see
     * [SwiftCoreSessionProbe]), which runs as a logcat side effect without
     * replacing the shell's session, and for the feed-effect flags
     * (`zc.assist` — applied to whichever feed renders, demo or live).
     */
    fun demoLiveFeed(intent: Intent): Pair<CameraSession, LiveFrameSource>? {
        SwiftCoreSessionProbe.maybeStart(intent)
        FeedEffectsState.current =
            FeedEffects.parse(
                intent.getStringExtra("zc.assist"),
                intent.getStringExtra("zc.lut"),
                intent.getStringExtra("zc.fc.scale"),
            )
        if (!intent.getBooleanExtra(EXTRA_DEMO_FEED, false)) return null
        val session =
            FakeCameraSession(
                CameraIdentity(name = "Demo Feed", model = "OpenZCine Demo", serialNumber = "DEMO"),
            )
        return session to DemoFrameSource()
    }
}

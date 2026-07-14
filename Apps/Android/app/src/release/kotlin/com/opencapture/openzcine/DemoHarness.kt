package com.opencapture.openzcine

import android.content.Intent
import com.opencapture.openzcine.core.CameraSession
import com.opencapture.openzcine.core.LiveFrameSource

/**
 * Release stub — the demo harness does not exist outside debug builds. The
 * real implementation is in `src/debug` (see its doc for the philosophy,
 * mirrored from `ios/Runner/DemoHarness.swift`).
 */
object DemoHarness {
    /** Never matched in release: the extra is read only by the debug harness. */
    const val EXTRA_DEMO_FEED = "zc.demo.feed"

    /** Never matched in release: the extra is read only by the debug harness. */
    const val EXTRA_SESSION_HOST = "zc.session.host"

    /** Always null: release builds carry no demo session or frame source. */
    @Suppress("UNUSED_PARAMETER")
    fun demoLiveFeed(intent: Intent): Pair<CameraSession, LiveFrameSource?>? = null
}

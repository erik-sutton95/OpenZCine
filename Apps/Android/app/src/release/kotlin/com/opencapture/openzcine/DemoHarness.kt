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
    const val EXTRA_SCOPES = "zc.scopes"

    /** Always null: release builds carry no demo frame source. */
    @Suppress("UNUSED_PARAMETER")
    fun demoLiveFeed(intent: Intent): Pair<CameraSession, LiveFrameSource>? = null

    /** Always null: the debug scope toggle does not exist in release builds. */
    @Suppress("UNUSED_PARAMETER")
    fun scopeKind(intent: Intent): ScopeKind? = null
}

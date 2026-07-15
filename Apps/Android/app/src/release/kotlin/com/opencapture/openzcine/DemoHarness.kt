package com.opencapture.openzcine

import android.content.Intent
import com.opencapture.openzcine.core.CameraSession
import com.opencapture.openzcine.core.LiveFrameSource
import com.opencapture.openzcine.media.MediaGalleryFailureInjection
import com.opencapture.openzcine.pairing.PairingScript

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

    /** Never matched in release: the extra is read only by the debug harness. */
    const val EXTRA_SESSION_HOST = "zc.session.host"

    /** Never matched in release: the extra is read only by the debug harness. */
    const val EXTRA_MEDIA = "zc.media"

    /** Release builds cannot auto-open debug surfaces. */
    @Suppress("UNUSED_PARAMETER")
    fun opensMedia(intent: Intent): Boolean = false

    /** Release builds cannot auto-open debug surfaces. */
    @Suppress("UNUSED_PARAMETER")
    fun autoPlaysMedia(intent: Intent): Boolean = false

    /** Release builds cannot inject Gallery failures. */
    @Suppress("UNUSED_PARAMETER")
    internal fun galleryFailureInjection(intent: Intent): MediaGalleryFailureInjection =
        MediaGalleryFailureInjection.NONE

    /** Always null: release builds carry no demo frame source. */
    @Suppress("UNUSED_PARAMETER")
    fun demoLiveFeed(intent: Intent): Pair<CameraSession, LiveFrameSource?>? = null

    /** Always null: release builds carry no scripted pairing wizard. */
    @Suppress("UNUSED_PARAMETER")
    fun pairingScript(intent: Intent): PairingScript? = null

    /** Always null: release builds always run the platform-resolved glass tier. */
    @Suppress("UNUSED_PARAMETER")
    fun glassTierOverride(intent: Intent): String? = null

    /** Always null: the debug scope toggle does not exist in release builds. */
    @Suppress("UNUSED_PARAMETER")
    fun scopeKind(intent: Intent): ScopeKind? = null

    /** Always null: release builds cannot activate debug scope selections. */
    @Suppress("UNUSED_PARAMETER")
    fun scopeKinds(intent: Intent): List<ScopeKind>? = null
}

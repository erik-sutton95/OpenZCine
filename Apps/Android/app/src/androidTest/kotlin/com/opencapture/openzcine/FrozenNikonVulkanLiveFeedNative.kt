package com.opencapture.openzcine

import android.graphics.Bitmap

/**
 * JNI surface of the frozen donor renderer (`:frozen-vulkan-donor`). The original
 * `VulkanLiveFeedNative` declarations, renamed only. SIMULATED parity fixture.
 */
internal object FrozenNikonVulkanLiveFeedNative {
    init {
        System.loadLibrary("frozen_nikon_live_feed_vk")
    }

    external fun nativeInitAssets(assets: android.content.res.AssetManager)

    external fun isAvailable(): Boolean

    external fun createSession(): Long

    external fun destroySession(session: Long)

    external fun attachSurface(session: Long, surface: android.view.Surface): Boolean

    external fun detachSurface(session: Long)

    external fun resize(session: Long, width: Int, height: Int)

    external fun resume(session: Long)

    external fun pause(session: Long)

    external fun clearFrame(session: Long)

    external fun clearPlan(session: Long)

    external fun submitBitmap(session: Long, bitmap: Bitmap): Boolean

    external fun setPlan(
        session: Long,
        lutSize: Int,
        lutRgba: ByteArray?,
        limitsPaintSize: Int,
        limitsPaintRgba: ByteArray?,
        limitsWeightSize: Int,
        limitsWeightRgba: ByteArray?,
        limitsOn: Boolean,
        peakingOn: Boolean,
        peakingColor: FloatArray,
        deLogCurve: FloatArray,
        peakingRatioThreshold: Float,
        peakingNoiseGate: Float,
        zebraHighlightOn: Boolean,
        zebraHighlight: Float,
        zebraHighlightColor: FloatArray,
        zebraMidtoneOn: Boolean,
        zebraMidtone: Float,
        zebraMidtoneColor: FloatArray,
        aspectFill: Boolean,
        mirrored: Boolean,
        splitOn: Boolean,
        splitVertical: Boolean,
    ): Boolean
}

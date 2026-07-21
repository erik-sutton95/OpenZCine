package com.opencapture.openzcine

import android.media.MediaCodecList
import android.util.Log

private const val TAG = "ZCLiveFeedHW"

/**
 * Phase 3: opportunistic hardware MJPEG path.
 *
 * Most Android SoCs (including SM-A127F) expose **no** `video/mjpeg` MediaCodec
 * decoder. When a device does, we log once so a future decode path can attach
 * without inventing a second software pipeline.
 */
internal object LiveFeedMjpegHardware {
    @Volatile private var probed = false
    @Volatile private var available = false

    /** True when MediaCodec lists a decoder for motion JPEG. */
    fun isAvailable(): Boolean {
        if (!probed) {
            probed = true
            available =
                MediaCodecList(MediaCodecList.ALL_CODECS).codecInfos.any { info ->
                    !info.isEncoder &&
                        info.supportedTypes.any {
                            it.equals("video/mjpeg", ignoreCase = true) ||
                                it.equals("video/x-motion-jpeg", ignoreCase = true)
                        }
                }
            Log.i(TAG, "MediaCodec video/mjpeg available=$available")
        }
        return available
    }
}

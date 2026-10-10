package com.opencapture.openzcine

import com.opencapture.opencine.runtime.monitorJpegSampleSizeForLongSide
import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * `inSampleSize` is power-of-two, so a cap set just below the source width does not trim a little —
 * it halves. The default cap was 960 against a 1024-wide live-view frame, which decoded every frame
 * at 512×288 on every device, and that is most of what read as JPEG blocking on Android.
 */
class JpegSampleSizeTest {
    /** The widest frame `LiveViewImageSize` can produce (XGA box, 16:9 readout). */
    private val feedWidth = 1024
    private val feedHeight = 576

    @Test
    fun `full width live view frame decodes unscaled at the default cap`() {
        assertEquals(
            1,
            monitorJpegSampleSizeForLongSide(
                feedWidth,
                feedHeight,
                LIVE_FEED_MAX_LONG_SIDE,
            ),
        )
    }

    @Test
    fun `a cap below the feed width halves it -- the regression this guards`() {
        assertEquals(2, monitorJpegSampleSizeForLongSide(feedWidth, feedHeight, 960))
    }

    /**
     * Why the retired low-RAM cap could never do what it said. It was documented as a "slightly
     * smaller decode" for assist-heavy frames, but power-of-two sampling offers no such step: at
     * this width the only choices are full (1024) and half (512). 720 bought quarter-resolution
     * pixels, not a trim, and that is what read as a soft feed on A12-class devices.
     */
    @Test
    fun `a cap between the halves buys half resolution, not a trim`() {
        assertEquals(2, monitorJpegSampleSizeForLongSide(feedWidth, feedHeight, 720))
        assertEquals(2, monitorJpegSampleSizeForLongSide(feedWidth, feedHeight, 1023))
        assertEquals(1, monitorJpegSampleSizeForLongSide(feedWidth, feedHeight, feedWidth))
    }

    @Test
    fun `oversized sources are still bounded`() {
        assertEquals(2, monitorJpegSampleSizeForLongSide(1920, 1080, LIVE_FEED_MAX_LONG_SIDE))
        assertEquals(4, monitorJpegSampleSizeForLongSide(4096, 2160, LIVE_FEED_MAX_LONG_SIDE))
    }

    @Test
    fun `zero or invalid inputs never scale`() {
        assertEquals(1, monitorJpegSampleSizeForLongSide(feedWidth, feedHeight, 0))
        assertEquals(1, monitorJpegSampleSizeForLongSide(0, 0, LIVE_FEED_MAX_LONG_SIDE))
    }
}

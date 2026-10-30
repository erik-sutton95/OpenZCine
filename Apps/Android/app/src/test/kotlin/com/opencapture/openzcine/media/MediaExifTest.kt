package com.opencapture.openzcine.media

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

/** JVM coverage for the session orientation cache (the upright turn itself is OpenCine's
 * `MonitorBitmapDecoder`, tested there). */
class MediaExifTest {
    @Test
    fun `session cache learns valid orientations only`() {
        MediaExifOrientation.learn("test/object/a", 6)
        MediaExifOrientation.learn("test/object/b", 0)
        MediaExifOrientation.learn("test/object/c", 9)

        assertEquals(6, MediaExifOrientation.learned("test/object/a"))
        assertNull(MediaExifOrientation.learned("test/object/b"))
        assertNull(MediaExifOrientation.learned("test/object/c"))
        assertNull(MediaExifOrientation.learned(null))
    }
}

package com.opencapture.openzcine.media

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

/** JVM coverage for the pure EXIF upright-transform table and the session orientation cache. */
class MediaExifTest {
    @Test
    fun `upright transform matches the TIFF orientation table`() {
        assertNull(MediaExifOrientation.uprightTransform(null))
        assertNull(MediaExifOrientation.uprightTransform(1))
        assertNull(MediaExifOrientation.uprightTransform(0))
        assertNull(MediaExifOrientation.uprightTransform(9))
        assertEquals(UprightTransform(0, true), MediaExifOrientation.uprightTransform(2))
        assertEquals(UprightTransform(180, false), MediaExifOrientation.uprightTransform(3))
        assertEquals(UprightTransform(180, true), MediaExifOrientation.uprightTransform(4))
        assertEquals(UprightTransform(90, true), MediaExifOrientation.uprightTransform(5))
        // The common portrait cases: top of the shot on the card's right (6) or left (8).
        assertEquals(UprightTransform(90, false), MediaExifOrientation.uprightTransform(6))
        assertEquals(UprightTransform(270, true), MediaExifOrientation.uprightTransform(7))
        assertEquals(UprightTransform(270, false), MediaExifOrientation.uprightTransform(8))
    }

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

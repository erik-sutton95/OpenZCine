package com.opencapture.openzcine.media

import com.opencapture.opencine.nikon.NikonMediaClipRecord
import com.opencapture.opencine.nikon.NikonMediaContentKind
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

    @Test
    fun `a still's grid shape turns once its orientation is learned`() {
        val still = NikonLibraryClip("SIMULATED", NikonMediaClipRecord(handle = 0x2002, storageId = 65_537,
            sizeBytes = 100, captureDate = "20261028T120000", pixelWidth = 6048, pixelHeight = 4032,
            filename = "_NZR0102.JPG", contentKind = NikonMediaContentKind.STILL_PHOTO, stillPhoto = null))
        assertEquals(1.5, mediaClipAspectRatio(still))

        MediaExifOrientation.learn(still.clip.libraryKey(still.bucket), 6)

        assertEquals(4032.0 / 6048.0, mediaClipAspectRatio(still))
    }
}

package com.opencapture.openzcine.media

import com.opencapture.opencine.appkit.MonitorDeliverySelectionFacts
import com.opencapture.opencine.nikon.NikonMediaClipRecord
import com.opencapture.opencine.nikon.NikonMediaContentKind
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * ZIB-469 (Android twin): a still travels as its original, so the delivery popup must know it is
 * one and offer no clip export (Bake LUT, MOV/MP4, renamed movie).
 */
class NikonStillDeliveryTest {
    private fun clip(name: String, kind: NikonMediaContentKind) =
        NikonMediaClipRecord(1, 1, 4, "20261007T120000", 1920, 1080, name, kind, null)

    @Test fun stillsAndMoviesAreToldApartForThePopup(): Unit {
        assertEquals(true, nikonDeliveryFileFacts(clip("DSC_0001.JPG", NikonMediaContentKind.STILL_PHOTO)).isStill)
        assertEquals(false, nikonDeliveryFileFacts(clip("DSC_0002.MOV", NikonMediaContentKind.PLAYABLE_PROXY)).isStill)
        assertEquals(false, nikonDeliveryFileFacts(clip("DSC_0003.R3D", NikonMediaContentKind.R3D_MASTER)).isStill)
        assertNull(nikonDeliveryFileFacts(clip("DSC_0004.XYZ", NikonMediaContentKind.UNSUPPORTED)).isStill)
        val still = nikonDeliveryFileFacts(clip("DSC_0001.JPG", NikonMediaContentKind.STILL_PHOTO))
        assertEquals("DSC_0001.JPG", still.filename)
        assertTrue(MonitorDeliverySelectionFacts(listOf(still), 1, null).allStills)
    }
}

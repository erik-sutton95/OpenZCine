package com.opencapture.openzcine.media

import com.opencapture.opencine.nikon.NikonMediaClipRecord
import com.opencapture.opencine.nikon.NikonMediaContentKind
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull

class MediaClipCellPresentationTest {
    @Test fun realIdentitySourceAndPreviewAdmissionLabelsStayGolden() {
        for ((kind, action) in listOf(
            NikonMediaContentKind.PLAYABLE_PROXY to "PLAY", NikonMediaContentKind.STILL_PHOTO to "VIEW",
            NikonMediaContentKind.R3D_MASTER to "MASTER", NikonMediaContentKind.UNSUPPORTED to "MEDIA",
        )) {
            val clip = sample("01.MOV", kind)
            val value = mediaClipCellPresentation(clip, "SIMULATED-cell", false, false, null, false, false, false)
            assertEquals(clip.libraryKey("SIMULATED-cell"), value.id)
            assertEquals("01.MOV", value.title)
            assertEquals(action, value.source)
            assertEquals("01.MOV, ${action.lowercase()}", value.accessibilityDescription)
            assertEquals("Select 01.MOV", value.selectionEntryLabel)
            assertNull(value.progress)
            assertNull(value.duration)
            assertNull(value.completionBadge)
            assertNull(value.transferCaption)
        }
    }

    @Test fun actualPairBurstAndFavoriteFactsKeepCurrentNativeLabels() {
        val clip = sample("01.JPG", NikonMediaContentKind.STILL_PHOTO)
        val value = mediaClipCellPresentation(clip, "SIMULATED-cell", true, true, 4, false, false, false)
        assertEquals("1MB · RAW+J", value.mediaBadge)
        assertEquals(4, value.burstCount)
        assertEquals("Remove 01.JPG from favorites", value.favoriteLabel)
        assertEquals(true, value.favorite)
        val ordinary = mediaClipCellPresentation(clip, "SIMULATED-cell", false, false, null, false, false, false)
        assertNull(ordinary.burstCount)
        assertEquals("1MB · JPG", ordinary.mediaBadge)
        assertFalse(ordinary.favorite)
        assertEquals("Add 01.JPG to favorites", ordinary.favoriteLabel)
    }

    @Test fun selectionSuffixIsCurrentAndListKeepsRealMetadata() {
        val clip = sample("01.JPG", NikonMediaContentKind.STILL_PHOTO)
        val selected = mediaClipCellPresentation(clip, "SIMULATED-cell", false, true, 4, false, true, true)
        assertEquals("01.JPG, view, selected", selected.accessibilityDescription)
        assertNull(selected.selectionEntryLabel)
        assertNull(selected.burstCount)
        // Android's real RAW+J badge remains visible during selection, unlike the Swift donor.
        assertEquals("1MB · RAW+J", selected.mediaBadge)
        val list = mediaClipCellPresentation(clip, "SIMULATED-cell", false, true, 4, true, true, false)
        assertEquals("1MB · RAW+J · VIEW", list.detail)
        assertEquals("01.JPG, view, not selected", list.accessibilityDescription)
        assertNull(list.source)
        assertNull(list.mediaBadge)
        assertNull(list.burstCount)
    }

    private fun sample(filename: String, kind: NikonMediaContentKind): NikonMediaClipRecord = NikonMediaClipRecord(
        handle = 1, storageId = 65_537, sizeBytes = 1_000_000, captureDate = "",
        pixelWidth = 0, pixelHeight = 0, filename = filename, contentKind = kind, stillPhoto = null,
    )
}

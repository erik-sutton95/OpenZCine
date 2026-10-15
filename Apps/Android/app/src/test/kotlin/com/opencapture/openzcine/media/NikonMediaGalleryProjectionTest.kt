package com.opencapture.openzcine.media

import com.opencapture.opencine.nikon.NikonMediaClipRecord
import com.opencapture.opencine.nikon.NikonMediaContentKind
import com.opencapture.opencine.nikon.NikonStillPhotoClassification
import com.opencapture.opencine.nikon.NikonStillPreviewStrategy
import com.opencapture.opencine.appkit.MonitorMediaSort
import java.time.LocalDate
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** SIMULATED actual gallery adapter, with unchanged JNI/action ownership out of scope. */
class NikonMediaGalleryProjectionTest {
    private fun clip(name: String, handle: Long = 1, width: Int = 6048, date: String = "20260727T120000") =
        NikonMediaClipRecord(handle, 11, 2, date, width, 4000, name, NikonMediaContentKind.STILL_PHOTO,
            NikonStillPhotoClassification(name.substringAfterLast('.').let { if (it == "JPG") "JPEG" else if (it == "TIF") "TIFF" else it }, NikonStillPreviewStrategy.THUMBNAIL_ONLY))
    private fun project(clips: List<NikonMediaClipRecord>, filters: MediaLibraryFilters = MediaLibraryFilters(),
        favorites: Set<String> = emptySet(), category: MediaLibraryCategory = MediaLibraryCategory.PHOTOS,
        sort: MonitorMediaSort = MonitorMediaSort.NEWEST) =
        NikonAppGalleryProjection(clips, emptyMap(), category, favorites, "cam", sort,
            filters, LocalDate.of(2026, 7, 27))
    @Test fun actualCategoryRankPrecedesFormatAndFourWidthDomainStaysUnknown() {
        val rows = listOf(clip("L.JPG", width = 6048), clip("M.NEF", 2, 4032), clip("S.TIF", 3, 3024))
        val filters = MediaLibraryFilters(formats = setOf(MediaFormatFilter.NEF), photoSizes = setOf(MediaPhotoSizeFilter.MEDIUM))
        assertEquals(listOf("M.NEF"), project(rows, filters).displayedClips.map { it.filename })
        val four = project(rows + clip("DX.JPG", 4, 2000), filters)
        assertTrue(four.filterOptions.photoSizes.isEmpty()); assertTrue(four.displayedClips.isEmpty())
    }
    @Test fun hiddenActiveResolutionFiltersPhotosButDoesNotOfferVideoChips() {
        val projection = project(listOf(clip("L.JPG"), clip("M.TIF", 2, 4032)),
            MediaLibraryFilters(resolutions = setOf(MediaResolutionFilter.SIX_K)))
        assertTrue(projection.filterOptions.resolutions.isEmpty())
        assertEquals(listOf("L.JPG"), projection.displayedClips.map { it.filename })
    }
    @Test fun rawPairSurvivorAndUnfilteredCompanionUseActualBucketAndSlot() {
        val jpeg = clip("A.JPG")
        val raw = clip("A.NEF", 2)
        assertEquals(listOf("A.JPG"), project(listOf(jpeg, raw)).displayedClips.map { it.filename })
        val onlyRaw = project(listOf(jpeg, raw), MediaLibraryFilters(formats = setOf(MediaFormatFilter.NEF)))
        assertEquals(listOf("A.NEF"), onlyRaw.displayedClips.map { it.filename })
        assertTrue(onlyRaw.hasRawSibling(jpeg) { it.libraryKey("cam") })
        assertFalse(project(listOf(jpeg, raw.copy(storageId = 22))).hasRawSibling(jpeg) { it.libraryKey("cam") })
    }
    @Test fun sortedSurvivorsRemainSelectionBasisWhileGridCollapsesCaptureRepresentative() {
        val a = clip("DSC_0001.JPG")
        val b = clip("DSC_0002.JPG", 2, date = "20260727T120001")
        val c = clip("DSC_0003.JPG", 3, date = "20260727T120002")
        val projection = project(listOf(c, a, b))
        assertEquals(listOf("DSC_0003.JPG", "DSC_0002.JPG", "DSC_0001.JPG"), projection.displayedClips.map { it.filename })
        assertEquals(listOf("DSC_0001.JPG"), projection.gridClips.map { it.filename })
        assertEquals(listOf(a, b, c), projection.members(a) { it.libraryKey("cam") })
    }
    @Test fun actualFavoriteSnapshotReplacementRebuildsCategoryWithoutInventedRatingHistory() {
        val a = clip("A.JPG")
        val b = clip("B.JPG", 2)
        assertEquals(listOf(a), project(listOf(a, b), favorites = setOf(a.libraryKey("cam")), category = MediaLibraryCategory.FAVORITES).displayedClips)
        assertEquals(listOf(b), project(listOf(a, b), favorites = setOf(b.libraryKey("cam")), category = MediaLibraryCategory.FAVORITES).displayedClips)
        assertEquals(listOf(b, a, a), MediaLibraryFiltering.sort(listOf(a, b, a), MonitorMediaSort.NEWEST))
    }
    @Test fun ratingSortPutsFavoritesFirstThenNewest() {
        // A4-15: the Nikon gallery offers the shared RATING order.
        val old = clip("OLD.JPG", 1, date = "20260701T120000")
        val new = clip("NEW.JPG", 2, date = "20260720T120000")
        val favorite = clip("FAV.JPG", 3, date = "20260710T120000")
        assertEquals(listOf(favorite, new, old), project(listOf(old, new, favorite), favorites = setOf(favorite.libraryKey("cam")),
            category = MediaLibraryCategory.ALL, sort = MonitorMediaSort.RATING).displayedClips)
    }
}

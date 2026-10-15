package com.opencapture.openzcine.media

import com.opencapture.opencine.media.*
import com.opencapture.opencine.nikon.*
import com.opencapture.opencine.appkit.MonitorMediaSort
import java.time.LocalDate

/** Actual payload mapping only; the shared result owns visible IDs, groups and expansion. */
internal class NikonAppGalleryProjection(
    clips: List<NikonMediaClipRecord>,
    actualIDs: Map<String, MediaAssetID>,
    category: MediaLibraryCategory,
    favoriteIDs: Set<String>,
    cameraID: String,
    sortOrder: MonitorMediaSort,
    filters: MediaLibraryFilters = MediaLibraryFilters(),
    today: LocalDate = LocalDate.now(),
    libraryKey: (NikonMediaClipRecord) -> String = { it.libraryKey(cameraID) },
    private val ownerOf: (NikonMediaClipRecord) -> String = { cameraID },
) {
    private val input = clips.map { clip ->
        val key = libraryKey(clip)
        NikonGallerySourceItem(actualIDs[key] ?: NikonMediaLibraryAssets.asset(ownerOf(clip), key, clip).id,
            key, ownerOf(clip), clip, key in favoriteIDs)
    }
    private val byID = input.associate { it.id to it.clip }
    private val IDsByLegacy = input.associate { it.legacyID to it.id }
    private val keysByID = input.associate { it.id to it.legacyID }
    val policy = NikonAndroidGalleryProjectionPolicy(input, today)
    val result = MonitorMediaProjection.project(input.map { it.id },
        MonitorMediaProjectionRequest(category = category.projectionCategory(), sort = sortOrder.projectionSort(),
            formats = filters.formats.mapTo(linkedSetOf()) { it.title },
            resolutions = filters.resolutions.mapTo(linkedSetOf()) { it.title },
            photoSizes = filters.photoSizes.mapTo(linkedSetOf()) { it.title },
            dateWindow = filters.dateWindow?.title, storage = filters.storageId?.toString(),
            requireLocal = false, selectionScope = MonitorMediaProjectionSelectionScope.ALL_SURVIVORS), policy)
    val displayedClips get() = result.displayIDs.mapNotNull(byID::get)
    val gridClips get() = result.gridIDs.mapNotNull(byID::get)
    val filterOptions get() = MediaFilterOptions(
        formats = result.offered.formats.mapNotNull { key -> MediaFormatFilter.entries.firstOrNull { it.title == key } },
        resolutions = result.offered.resolutions.mapNotNull { key -> MediaResolutionFilter.entries.firstOrNull { it.title == key } },
        photoSizes = result.offered.photoSizes.mapNotNull { key -> MediaPhotoSizeFilter.entries.firstOrNull { it.title == key } },
        dateWindows = result.offered.dateWindows.mapNotNull { key -> MediaDateWindowFilter.entries.firstOrNull { it.title == key } })
    val legacyGroups get() = result.groups.map { group -> BurstSeries(group.members.mapNotNull(keysByID::get)) }
    fun members(clip: NikonMediaClipRecord, key: (NikonMediaClipRecord) -> String): List<NikonMediaClipRecord> =
        IDsByLegacy[key(clip)]?.let(result::group)?.members?.mapNotNull(byID::get).orEmpty()
    fun hasRawSibling(clip: NikonMediaClipRecord, key: (NikonMediaClipRecord) -> String): Boolean =
        IDsByLegacy[key(clip)]?.let(policy::rawCompanion) != null
    companion object {
        fun sorted(clips: List<NikonMediaClipRecord>, sort: MonitorMediaSort): List<NikonMediaClipRecord> {
            // Preserve duplicate payloads accepted by the original sorting API.
            return clips.sortedWith { left, right ->
                NikonAndroidGalleryProjectionPolicy.compareClips(left, right, sort.projectionSort())
            }
        }
    }
}
private fun MediaLibraryCategory.projectionCategory() = when (this) {
    MediaLibraryCategory.ALL -> MonitorMediaProjectionCategory.ALL
    MediaLibraryCategory.VIDEOS -> MonitorMediaProjectionCategory.VIDEOS
    MediaLibraryCategory.PHOTOS -> MonitorMediaProjectionCategory.PHOTOS
    MediaLibraryCategory.FAVORITES -> MonitorMediaProjectionCategory.FAVORITES
}
private fun MonitorMediaSort.projectionSort() = MonitorMediaProjectionSort.valueOf(name)

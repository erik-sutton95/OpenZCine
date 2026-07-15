package com.opencapture.openzcine.media

import com.opencapture.openzcine.core.CameraStorageSlotStatus

/** UI-safe decimal-gigabyte values for one authoritative camera card. */
internal data class MediaStorageSlotPresentation(
    val storageId: Long,
    val slotNumber: Int,
    val freeGigabytes: Long,
    val totalGigabytes: Long,
)

/**
 * Returns capacity cards only while the live camera source is actually connected.
 *
 * The incoming order is already camera-authored by the Swift facade and is
 * intentionally preserved. Local media and stale/disconnected sessions never
 * surface cached capacity as though it were current.
 */
internal fun mediaStorageSlotPresentations(
    source: MediaLibrarySource,
    cameraConnected: Boolean,
    cameraSessionAvailable: Boolean,
    slots: List<CameraStorageSlotStatus>,
): List<MediaStorageSlotPresentation> {
    if (
        source != MediaLibrarySource.CAMERA ||
            !cameraConnected ||
            !cameraSessionAvailable
    ) {
        return emptyList()
    }
    return slots.map { slot ->
        MediaStorageSlotPresentation(
            storageId = slot.storageId,
            slotNumber = slot.slotNumber,
            freeGigabytes = slot.freeSpaceBytes / BYTES_PER_DECIMAL_GIGABYTE,
            totalGigabytes = slot.totalCapacityBytes / BYTES_PER_DECIMAL_GIGABYTE,
        )
    }
}

/** Toggles the same storage-ID filter used by the media grid and filter dialog. */
internal fun MediaLibraryFilters.togglingStorageSlot(storageId: Long): MediaLibraryFilters =
    copy(storageId = storageId.takeUnless { this.storageId == storageId })

private const val BYTES_PER_DECIMAL_GIGABYTE: Long = 1_000_000_000L

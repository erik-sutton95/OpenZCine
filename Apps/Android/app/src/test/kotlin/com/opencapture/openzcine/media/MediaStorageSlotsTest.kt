package com.opencapture.openzcine.media

import com.opencapture.openzcine.core.CameraStorageSlotStatus
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

class MediaStorageSlotsTest {
    @Test
    fun connectedCameraPresentationPreservesSwiftOrderAndDecimalCapacity() {
        val slots =
            listOf(
                slot(id = 131_073, number = 1, total = 954_900_000_000, free = 242_900_000_000),
                slot(id = 65_537, number = 2, total = 0, free = 111_900_000_000),
            )

        val presentation =
            mediaStorageSlotPresentations(
                source = MediaLibrarySource.CAMERA,
                cameraConnected = true,
                cameraSessionAvailable = true,
                slots = slots,
            )

        assertEquals(listOf(131_073L, 65_537L), presentation.map { it.storageId })
        assertEquals(listOf(1, 2), presentation.map { it.slotNumber })
        assertEquals(listOf(242L, 111L), presentation.map { it.freeGigabytes })
        assertEquals(listOf(954L, 0L), presentation.map { it.totalGigabytes })
    }

    @Test
    fun capacityCardsHideForLocalDisconnectedAndUnavailableSources() {
        val slots = listOf(slot(id = 65_537, number = 1, total = 954, free = 242))

        assertTrue(
            mediaStorageSlotPresentations(
                MediaLibrarySource.LOCAL,
                cameraConnected = true,
                cameraSessionAvailable = true,
                slots,
            ).isEmpty(),
        )
        assertTrue(
            mediaStorageSlotPresentations(
                MediaLibrarySource.CAMERA,
                cameraConnected = false,
                cameraSessionAvailable = true,
                slots,
            ).isEmpty(),
        )
        assertTrue(
            mediaStorageSlotPresentations(
                MediaLibrarySource.CAMERA,
                cameraConnected = true,
                cameraSessionAvailable = false,
                slots,
            ).isEmpty(),
        )
    }

    @Test
    fun selectingCardTogglesTheExistingStorageFilter() {
        val first = MediaLibraryFilters().togglingStorageSlot(65_537)
        assertEquals(65_537L, first.storageId)

        val cleared = first.togglingStorageSlot(65_537)
        assertNull(cleared.storageId)

        val second = first.togglingStorageSlot(131_073)
        assertEquals(131_073L, second.storageId)
    }

    @Test
    fun authoritativeSlotGenerationRetainsEmptyCardSelection() {
        val filters = MediaLibraryFilters(storageId = 131_073)
        assertEquals(
            filters,
            filters.retainingAvailableStorage(MediaLibrarySource.CAMERA, setOf(65_537, 131_073)),
        )
        assertNull(
            filters.retainingAvailableStorage(MediaLibrarySource.CAMERA, setOf(65_537)).storageId,
        )
    }

    private fun slot(
        id: Long,
        number: Int,
        total: Long,
        free: Long,
    ): CameraStorageSlotStatus =
        CameraStorageSlotStatus(
            storageId = id,
            slotNumber = number,
            totalCapacityBytes = total,
            freeSpaceBytes = free,
        )
}

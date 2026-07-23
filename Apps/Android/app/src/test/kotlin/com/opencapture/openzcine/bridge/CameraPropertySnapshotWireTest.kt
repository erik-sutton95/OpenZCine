package com.opencapture.openzcine.bridge

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class CameraPropertySnapshotWireTest {
    @Test
    fun decodesOrderedStorageSlotsAndPreservesLegacyFirstCard() {
        val decoded = CameraPropertySnapshotWire.decode(validPayload())

        assertTrue(decoded.isValid)
        assertEquals(NativePropertyRefreshResult.ACCEPTED, decoded.result)
        assertEquals(954_000_000_000L, decoded.snapshot.storage?.totalCapacityBytes)
        assertEquals(242_000_000_000L, decoded.snapshot.storage?.freeSpaceBytes)
        assertEquals(
            listOf(65_537L, 131_073L),
            decoded.snapshot.storageSlots.map { it.storageId },
        )
        assertEquals(listOf(1, 2), decoded.snapshot.storageSlots.map { it.slotNumber })
        assertEquals(
            listOf(954_000_000_000L, 512_000_000_000L),
            decoded.snapshot.storageSlots.map { it.totalCapacityBytes },
        )
        assertEquals(
            listOf(242_000_000_000L, 111_000_000_000L),
            decoded.snapshot.storageSlots.map { it.freeSpaceBytes },
        )
        assertEquals("HLG", decoded.snapshot.stillToneMode)
    }

    @Test
    fun acceptsExplicitUnknownTotalWithoutInventingCapacity() {
        val decoded =
            CameraPropertySnapshotWire.decode(
                validPayload()
                    .replace("storageSlotCount\t2", "storageSlotCount\t1")
                    .lineSequence()
                    .filterNot { it.startsWith("storageSlot.1.") }
                    .map {
                        when {
                            it.startsWith("storageSlot.0.totalCapacityBytes") ->
                                "storageSlot.0.totalCapacityBytes\t0"
                            else -> it
                        }
                    }.joinToString("\n"),
            )

        assertTrue(decoded.isValid)
        assertEquals(0L, decoded.snapshot.storageSlots.single().totalCapacityBytes)
        assertEquals(242_000_000_000L, decoded.snapshot.storageSlots.single().freeSpaceBytes)
    }

    @Test
    fun missingSlotCountWithIndexedFieldsIsRejected() {
        assertRejected(validPayload().replace("storageSlotCount\t2\n", ""))
    }

    @Test
    fun partialOrUnexpectedIndexedRecordsAreRejected() {
        assertRejected(
            validPayload().lineSequence()
                .filterNot { it.startsWith("storageSlot.1.freeSpaceBytes") }
                .joinToString("\n"),
        )
        assertRejected(validPayload() + "\nstorageSlot.2.storageId\t196609")
    }

    @Test
    fun slotIdentityOverflowDuplicateAndOrderMismatchAreRejected() {
        assertRejected(
            validPayload().replace(
                "storageSlot.0.storageId\t65537",
                "storageSlot.0.storageId\t4294967296",
            ),
        )
        assertRejected(
            validPayload().replace(
                "storageSlot.0.storageId\t65537",
                "storageSlot.0.storageId\t4294967295",
            ),
        )
        assertRejected(
            validPayload().replace(
                "storageSlot.1.storageId\t131073",
                "storageSlot.1.storageId\t65537",
            ),
        )
        assertRejected(
            validPayload().replace(
                "storageSlot.1.slotNumber\t2",
                "storageSlot.1.slotNumber\t3",
            ),
        )
    }

    @Test
    fun capacityOverflowNegativeAndInconsistencyAreRejected() {
        assertRejected(
            validPayload().replace(
                "storageSlot.1.totalCapacityBytes\t512000000000",
                "storageSlot.1.totalCapacityBytes\t9223372036854775808",
            ),
        )
        assertRejected(
            validPayload().replace(
                "storageSlot.1.freeSpaceBytes\t111000000000",
                "storageSlot.1.freeSpaceBytes\t-1",
            ),
        )
        assertRejected(
            validPayload().replace(
                "storageSlot.1.freeSpaceBytes\t111000000000",
                "storageSlot.1.freeSpaceBytes\t600000000000",
            ),
        )
    }

    @Test
    fun legacyStoragePairIsAlsoAtomicAndConsistent() {
        assertRejected(validPayload().replace("storageFreeSpaceBytes\t242000000000\n", ""))
        assertRejected(
            validPayload().replace(
                "storageFreeSpaceBytes\t242000000000",
                "storageFreeSpaceBytes\t1000000000000",
            ),
        )

        val noStorage = CameraPropertySnapshotWire.decode("result\taccepted\nstorageSlotCount\t0")
        assertTrue(noStorage.isValid)
        assertNull(noStorage.snapshot.storage)
        assertTrue(noStorage.snapshot.storageSlots.isEmpty())
    }

    private fun assertRejected(payload: String) {
        val decoded = CameraPropertySnapshotWire.decode(payload)
        assertFalse(decoded.isValid)
        assertEquals(NativePropertyRefreshResult.TRANSPORT_FAILED, decoded.result)
        assertTrue(decoded.snapshot.storageSlots.isEmpty())
    }

    private fun validPayload(): String =
        listOf(
            "result\taccepted",
            "stillToneMode\tHLG",
            "storageTotalCapacityBytes\t954000000000",
            "storageFreeSpaceBytes\t242000000000",
            "storageSlotCount\t2",
            "storageSlot.0.storageId\t65537",
            "storageSlot.0.slotNumber\t1",
            "storageSlot.0.totalCapacityBytes\t954000000000",
            "storageSlot.0.freeSpaceBytes\t242000000000",
            "storageSlot.1.storageId\t131073",
            "storageSlot.1.slotNumber\t2",
            "storageSlot.1.totalCapacityBytes\t512000000000",
            "storageSlot.1.freeSpaceBytes\t111000000000",
        ).joinToString("\n")
}

package com.opencapture.openzcine.pairing

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull

class SavedCameraRecordsTest {
    @Test
    fun `canonicalization normalizes profile fields and keeps meaningful metadata`() {
        val records =
            SavedCameraRecords.canonicalized(
                listOf(
                    SavedCameraRecord(
                        host = " 192.168.1.1 ",
                        cameraName = "  ZR_6001234 ",
                        transport = SavedCameraTransport.CAMERA_ACCESS_POINT,
                        lastSeenAtEpochMillis = 20L,
                        wifiSsid = " NIKON_ZR_01234 ",
                        customName = " A camera ",
                    ),
                ),
            )

        assertEquals(1, records.size)
        assertEquals("192.168.1.1", records.single().host)
        assertEquals("ZR_6001234", records.single().cameraName)
        assertEquals("NIKON_ZR_01234", records.single().wifiSsid)
        assertEquals("A camera", records.single().customName)
        assertEquals("A camera", records.single().displayTitle)
    }

    @Test
    fun `upsert refreshes a dynamic host but preserves AP metadata and nickname`() {
        val original =
            SavedCameraRecord(
                host = "172.20.10.2",
                cameraName = "ZR_6001234",
                transport = SavedCameraTransport.PHONE_HOTSPOT,
                lastSeenAtEpochMillis = 10L,
                wifiSsid = "NIKON_ZR_01234",
                customName = "A camera",
            )

        val updated =
            SavedCameraRecords.upserting(
                host = "172.20.10.7",
                cameraName = "zr_6001234",
                transport = SavedCameraTransport.PHONE_HOTSPOT,
                lastSeenAtEpochMillis = 20L,
                wifiSsid = null,
                records = listOf(original),
            )

        assertEquals(1, updated.size)
        assertEquals("172.20.10.7", updated.single().host)
        assertEquals("172.20.10.2", updated.single().id)
        assertEquals("NIKON_ZR_01234", updated.single().wifiSsid)
        assertEquals("A camera", updated.single().customName)
    }

    @Test
    fun `generic camera names do not collapse distinct profiles`() {
        val records =
            SavedCameraRecords.canonicalized(
                listOf(
                    SavedCameraRecord(
                        host = "192.168.1.1",
                        cameraName = "Nikon ZR",
                        transport = SavedCameraTransport.CAMERA_ACCESS_POINT,
                        lastSeenAtEpochMillis = null,
                        wifiSsid = null,
                    ),
                    SavedCameraRecord(
                        host = "192.168.1.2",
                        cameraName = "Nikon ZR",
                        transport = SavedCameraTransport.CAMERA_ACCESS_POINT,
                        lastSeenAtEpochMillis = null,
                        wifiSsid = null,
                    ),
                ),
            )

        assertEquals(2, records.size)
        assertFalse(SavedCameraRecords.cameraNamesMatch("Nikon ZR", "Nikon ZR"))
    }

    @Test
    fun `usb and wifi profiles for one named camera remain independently reconnectable`() {
        val records =
            SavedCameraRecords.canonicalized(
                listOf(
                    SavedCameraRecord(
                        host = "usb:5d6f4d746ecf9da40a1b0ce273d3d8d3",
                        cameraName = "ZR_6001234",
                        transport = SavedCameraTransport.USB_C,
                        lastSeenAtEpochMillis = 20L,
                        wifiSsid = null,
                    ),
                    SavedCameraRecord(
                        host = "172.20.10.7",
                        cameraName = "ZR_6001234",
                        transport = SavedCameraTransport.PHONE_HOTSPOT,
                        lastSeenAtEpochMillis = 10L,
                        wifiSsid = null,
                    ),
                ),
            )

        assertEquals(2, records.size)
        assertEquals(SavedCameraTransport.USB_C, records.first().transport)
        assertEquals(SavedCameraTransport.PHONE_HOTSPOT, records.last().transport)
    }

    @Test
    fun `renaming and removal normalize their inputs`() {
        val record =
            SavedCameraRecord(
                host = "192.168.1.1",
                cameraName = "ZR_6001234",
                transport = SavedCameraTransport.CAMERA_ACCESS_POINT,
                lastSeenAtEpochMillis = null,
                wifiSsid = null,
            )
        val renamed =
            SavedCameraRecords.updatingCustomName(
                host = " 192.168.1.1 ",
                customName = "  ",
                records = listOf(record),
            )

        assertNull(renamed.single().customName)
        assertEquals(emptyList(), SavedCameraRecords.removing("192.168.1.1", records = renamed))
    }

    /**
     * The #293 report: pairing a second body removed the first. Every camera-AP Nikon is
     * 192.168.1.1, so both records share one address — a shared host (or a profileID defaulted
     * from it) merges records only when the names don't contradict it, and forgetting one of the
     * two must not delete the other.
     */
    @Test
    fun `two bodies sharing the access-point address both survive`() {
        val first =
            SavedCameraRecords.upserting(
                host = "192.168.1.1",
                cameraName = "Z 6III_1234567",
                transport = SavedCameraTransport.CAMERA_ACCESS_POINT,
                lastSeenAtEpochMillis = 1_000L,
                wifiSsid = "Z6III_AP",
                records = emptyList(),
            )
        val both =
            SavedCameraRecords.upserting(
                host = "192.168.1.1",
                cameraName = "Z 5_7654321",
                transport = SavedCameraTransport.CAMERA_ACCESS_POINT,
                lastSeenAtEpochMillis = 2_000L,
                wifiSsid = "Z5_AP",
                records = first,
            )
        assertEquals(listOf("Z 6III_1234567", "Z 5_7654321"), both.map { it.cameraName })

        // Forgetting the Z 5 by name leaves the Z 6III standing.
        val afterForget = SavedCameraRecords.removing("192.168.1.1", "Z 5_7654321", both)
        assertEquals(listOf("Z 6III_1234567"), afterForget.map { it.cameraName })
    }
}

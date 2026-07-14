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
        assertEquals(emptyList(), SavedCameraRecords.removing("192.168.1.1", renamed))
    }
}

package com.opencapture.openzcine.pairing

import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * The Android twin of the shared core's `SavedCameraPathGroups`: one ROW per body, grouped by
 * ASSIGNED-name identity (Android records carry no serial), setups newest-first, the active
 * setup preferring reachability over recency — the iOS row rules.
 */
class SavedCameraGroupsTest {
    @Test
    fun `setups of one body group into a single row`() {
        val groups =
            SavedCameraGroups.group(
                listOf(
                    record("172.20.10.8", "ZR_6002199", SavedCameraTransport.PHONE_HOTSPOT, 10L),
                    record("10.99.0.20", "ZR_6002199", SavedCameraTransport.INFRASTRUCTURE, 30L),
                    record("usb:zr", "ZR_6002199", SavedCameraTransport.USB_C, 20L),
                    record("192.168.1.1", "Z6_7005555", SavedCameraTransport.CAMERA_ACCESS_POINT, 5L),
                )
            )
        assertEquals(2, groups.size)
        // Members most-recently-seen first.
        assertEquals(
            listOf(
                SavedCameraTransport.INFRASTRUCTURE,
                SavedCameraTransport.USB_C,
                SavedCameraTransport.PHONE_HOTSPOT,
            ),
            groups[0].map(SavedCameraRecord::transport),
        )
        assertEquals("Z6_7005555", groups[1].single().cameraName)
    }

    @Test
    fun `generic names carry no identity and stay singleton rows`() {
        val groups =
            SavedCameraGroups.group(
                listOf(
                    record("10.0.0.2", "Nikon ZR", SavedCameraTransport.INFRASTRUCTURE, 1L),
                    record("172.20.10.9", "Nikon ZR", SavedCameraTransport.PHONE_HOTSPOT, 2L),
                )
            )
        assertEquals(2, groups.size)
    }

    @Test
    fun `the active setup prefers a reachable one over a newer offline one`() {
        val hotspot = record("172.20.10.8", "ZR_6002199", SavedCameraTransport.PHONE_HOTSPOT, 10L)
        val router = record("10.99.0.20", "ZR_6002199", SavedCameraTransport.INFRASTRUCTURE, 30L)
        val group = SavedCameraGroups.group(listOf(hotspot, router)).single()
        assertEquals(router, SavedCameraGroups.activeRecord(group) { false })
        assertEquals(
            hotspot,
            SavedCameraGroups.activeRecord(group) { it.transport == SavedCameraTransport.PHONE_HOTSPOT },
        )
    }

    @Test
    fun `missing setup kinds offer exactly what the camera lacks`() {
        val group =
            listOf(
                record("10.99.0.20", "ZR_6002199", SavedCameraTransport.INFRASTRUCTURE, 1L),
                record("usb:zr", "ZR_6002199", SavedCameraTransport.USB_C, 2L),
            )
        assertEquals(
            listOf(
                SavedCameraTransport.CAMERA_ACCESS_POINT,
                SavedCameraTransport.PHONE_HOTSPOT,
            ),
            missingSetupKinds(group),
        )
        assertEquals(
            emptyList(),
            missingSetupKinds(
                group +
                    listOf(
                        record("192.168.1.1", "ZR_6002199", SavedCameraTransport.CAMERA_ACCESS_POINT, 3L),
                        record("172.20.10.8", "ZR_6002199", SavedCameraTransport.PHONE_HOTSPOT, 4L),
                    )
            ),
        )
    }

    private fun record(
        host: String,
        name: String,
        transport: SavedCameraTransport,
        seen: Long,
    ): SavedCameraRecord =
        SavedCameraRecord(
            host = host,
            cameraName = name,
            transport = transport,
            lastSeenAtEpochMillis = seen,
            wifiSsid = null,
        )
}

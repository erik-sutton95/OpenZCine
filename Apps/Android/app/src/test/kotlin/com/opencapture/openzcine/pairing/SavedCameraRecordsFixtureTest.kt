package com.opencapture.openzcine.pairing

import com.opencapture.openzcine.TestSharedPreferences
import com.opencapture.openzcine.settings.LiveViewQualityBias
import com.opencapture.openzcine.settings.LiveViewStreamPreset
import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * The saved setups as this app's own store writes them: the golden fixture OpenCine's
 * `NikonSavedRecordsV0` (Android) migration tests read. Regenerate with
 * `OPENCINE_WRITE_FIXTURES=<path to nikon-records-v0-android.json> ./gradlew :app:testDebugUnitTest
 * --tests '*SavedCameraRecordsFixtureTest*'`.
 */
class SavedCameraRecordsFixtureTest {
    private val at = 1_759_307_200_250L

    /**
     * Body A paired on its access point, then given a Studio Wi-Fi setup and a USB-C setup, renamed
     * on every path; body B on the phone's hotspot; body C on its access point under a pending key;
     * and a camera that never reported a name.
     */
    private fun appRecords(): List<SavedCameraRecord> {
        var records = emptyList<SavedCameraRecord>()
        records = SavedCameraRecords.upserting(
            "192.168.1.1", "ZR_3001234", SavedCameraTransport.CAMERA_ACCESS_POINT, at, "NIKON_ZR_3001234", records,
        )
        records = SavedCameraRecords.upserting(
            "192.168.50.23", "ZR_3001234", SavedCameraTransport.INFRASTRUCTURE, at + 200_000, null, records,
            networkName = "Studio",
        )
        records = SavedCameraRecords.upserting(
            "usb:3f9a2c", "ZR_3001234", SavedCameraTransport.USB_C, at + 100_000, null, records,
        )
        for (host in listOf("192.168.1.1", "192.168.50.23", "usb:3f9a2c")) {
            records = SavedCameraRecords.updatingCustomName(host, "A-cam", records)
        }
        records = SavedCameraRecords.updatingSetupName("192.168.50.23", SavedCameraTransport.INFRASTRUCTURE, "Studio", records)
        records = SavedCameraRecords.updatingStreamSettings(
            "192.168.1.1", SavedCameraTransport.CAMERA_ACCESS_POINT, LiveViewStreamPreset.FAST, LiveViewQualityBias.LATENCY, records,
        )
        records = SavedCameraRecords.upserting(
            "192.168.43.20", "ZR_4005678", SavedCameraTransport.PHONE_HOTSPOT, at + 300_000, null, records,
        )
        records = SavedCameraRecords.upserting(
            "", "Z_8_5009999", SavedCameraTransport.CAMERA_ACCESS_POINT, at - 100_000, "NIKON_Z8_5009999", records,
        ).let { it + SavedCameraRecords.pinnedToAccessPoint(
            SavedCameraRecord("x", "Z_8_5009999", SavedCameraTransport.CAMERA_ACCESS_POINT, at - 100_000, "NIKON_Z8_5009999"),
        ) }
        records = SavedCameraRecords.upserting(
            "10.0.0.5", "", SavedCameraTransport.INFRASTRUCTURE, null, null, records,
        )
        return records
    }

    @Test
    fun `the store writes what the migration fixture holds`() {
        val preferences = TestSharedPreferences()
        val store = SharedPreferencesSavedCameraStore(preferences)
        store.replace(appRecords())
        val written = preferences.getString("records-json", null)!!
        System.getenv("OPENCINE_WRITE_FIXTURES")?.takeIf { it.endsWith(".json") }?.let { File(it).writeText(written) }
        assertEquals(SavedCameraRecords.canonicalized(appRecords()), store.records())
    }
}

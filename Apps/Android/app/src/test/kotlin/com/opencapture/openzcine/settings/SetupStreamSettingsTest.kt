package com.opencapture.openzcine.settings

import com.opencapture.openzcine.pairing.SavedCameraRecord
import com.opencapture.openzcine.pairing.SavedCameraRecords
import com.opencapture.openzcine.pairing.SavedCameraTransport
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

/**
 * The Kotlin half of the pair. Every case here has a twin in the shared core's
 * `SetupStreamSettingsTests.swift` — the two suites are the only thing keeping a path from
 * meaning one bias on iPhone and another here.
 */
class SetupStreamSettingsTest {
    @Test
    fun `only the access point starts at a faster bias than the seed`() {
        for (transport in SavedCameraTransport.entries) {
            val resolved =
                SetupStreamSettings.qualityBias(
                    stored = null,
                    transport = transport,
                    seed = LiveViewQualityBias.BALANCED,
                )
            val expected =
                if (transport == SavedCameraTransport.CAMERA_ACCESS_POINT) {
                    LiveViewQualityBias.LATENCY
                } else {
                    LiveViewQualityBias.BALANCED
                }
            assertEquals(expected, resolved, "transport=$transport")
        }
        // No transport at all is not an access point.
        assertEquals(
            LiveViewQualityBias.BALANCED,
            SetupStreamSettings.qualityBias(
                stored = null,
                transport = null,
                seed = LiveViewQualityBias.BALANCED,
            ),
        )
    }

    @Test
    fun `a stored bias wins on every path including the access point`() {
        for (transport in SavedCameraTransport.entries) {
            for (stored in LiveViewQualityBias.entries) {
                assertEquals(
                    stored,
                    SetupStreamSettings.qualityBias(
                        stored = stored,
                        transport = transport,
                        seed = LiveViewQualityBias.BALANCED,
                    ),
                    "transport=$transport stored=$stored",
                )
            }
        }
    }

    @Test
    fun `no path overrides the stream preset including the access point`() {
        for (transport in SavedCameraTransport.entries) {
            assertEquals(
                LiveViewStreamPreset.QUALITY,
                SetupStreamSettings.streamPreset(
                    stored = null,
                    transport = transport,
                    seed = LiveViewStreamPreset.QUALITY,
                ),
            )
            assertEquals(
                LiveViewStreamPreset.FAST,
                SetupStreamSettings.streamPreset(
                    stored = LiveViewStreamPreset.FAST,
                    transport = transport,
                    seed = LiveViewStreamPreset.QUALITY,
                ),
            )
        }
    }

    /** The shipped seeds are the same two values on both shells. */
    @Test
    fun `the shipped defaults match the shared core`() {
        assertEquals(LiveViewStreamPreset.QUALITY, LiveViewStreamPreset.SHIPPED_DEFAULT)
        assertEquals(LiveViewQualityBias.BALANCED, LiveViewQualityBias.SHIPPED_DEFAULT)
    }

    /**
     * One camera's access-point and router setups are two records, and a pick on one must not
     * reach the other — the whole reason these settings moved off a single global key.
     */
    @Test
    fun `writing one setup's stream settings leaves its sibling setup alone`() {
        val records =
            listOf(
                SavedCameraRecord(
                    host = "192.168.1.1",
                    cameraName = "ZR_6002199",
                    transport = SavedCameraTransport.CAMERA_ACCESS_POINT,
                    lastSeenAtEpochMillis = null,
                    wifiSsid = "NIKON_ZR_6002199",
                ),
                SavedCameraRecord(
                    host = "10.0.0.5",
                    cameraName = "ZR_6002199",
                    transport = SavedCameraTransport.INFRASTRUCTURE,
                    lastSeenAtEpochMillis = null,
                    wifiSsid = null,
                ),
            )

        val updated =
            SavedCameraRecords.updatingStreamSettings(
                host = "192.168.1.1",
                transport = SavedCameraTransport.CAMERA_ACCESS_POINT,
                streamPreset = LiveViewStreamPreset.FAST,
                qualityBias = LiveViewQualityBias.LATENCY,
                records = records,
            )

        val accessPoint =
            updated.first { it.transport == SavedCameraTransport.CAMERA_ACCESS_POINT }
        val router = updated.first { it.transport == SavedCameraTransport.INFRASTRUCTURE }
        assertEquals(LiveViewStreamPreset.FAST, accessPoint.streamPreset)
        assertEquals(LiveViewQualityBias.LATENCY, accessPoint.qualityBias)
        assertNull(router.streamPreset)
        assertNull(router.qualityBias)
    }

    /**
     * The divergence this used to pin is gone: Android keys a setup on (camera, path) like the
     * shared core, so one body's same-host access-point and router setups stay two rows — and each
     * therefore keeps its own stream settings, which is what this file is about.
     */
    @Test
    fun `two same-host setups of one camera stay two records`() {
        val records =
            listOf(
                SavedCameraRecord(
                    host = "192.168.1.1",
                    cameraName = "ZR_6002199",
                    transport = SavedCameraTransport.CAMERA_ACCESS_POINT,
                    lastSeenAtEpochMillis = null,
                    wifiSsid = "NIKON_ZR_6002199",
                ),
                SavedCameraRecord(
                    host = "192.168.1.1",
                    cameraName = "ZR_6002199",
                    transport = SavedCameraTransport.INFRASTRUCTURE,
                    lastSeenAtEpochMillis = null,
                    wifiSsid = null,
                ),
            )

        val canonical = SavedCameraRecords.canonicalized(records)

        assertEquals(2, canonical.size)
        assertEquals(
            setOf(
                SavedCameraTransport.CAMERA_ACCESS_POINT,
                SavedCameraTransport.INFRASTRUCTURE,
            ),
            canonical.map { it.transport }.toSet(),
        )
    }

    @Test
    fun `a null argument leaves that setting alone rather than clearing it`() {
        val records =
            listOf(
                SavedCameraRecord(
                    host = "192.168.1.1",
                    cameraName = "ZR_6002199",
                    transport = SavedCameraTransport.CAMERA_ACCESS_POINT,
                    lastSeenAtEpochMillis = null,
                    wifiSsid = null,
                    streamPreset = LiveViewStreamPreset.QUALITY,
                    qualityBias = LiveViewQualityBias.DETAIL,
                ),
            )

        val updated =
            SavedCameraRecords.updatingStreamSettings(
                host = "192.168.1.1",
                transport = SavedCameraTransport.CAMERA_ACCESS_POINT,
                streamPreset = null,
                qualityBias = LiveViewQualityBias.LATENCY,
                records = records,
            )

        assertEquals(LiveViewStreamPreset.QUALITY, updated.first().streamPreset)
        assertEquals(LiveViewQualityBias.LATENCY, updated.first().qualityBias)
    }

    /**
     * Every reconnect upserts a record that knows nothing about stream settings. If the merge let
     * that win, an operator's choice would survive exactly until the next time they used the setup.
     */
    @Test
    fun `reconnecting to a setup does not erase the stream settings chosen on it`() {
        val chosen =
            SavedCameraRecord(
                host = "192.168.1.1",
                cameraName = "ZR_6002199",
                transport = SavedCameraTransport.CAMERA_ACCESS_POINT,
                lastSeenAtEpochMillis = 1_700_000_000_000L,
                wifiSsid = "NIKON_ZR_6002199",
                streamPreset = LiveViewStreamPreset.FAST,
                qualityBias = LiveViewQualityBias.LATENCY,
            )

        val merged =
            SavedCameraRecords.upserting(
                host = chosen.host,
                cameraName = chosen.cameraName,
                transport = chosen.transport,
                lastSeenAtEpochMillis = 1_800_000_000_000L,
                wifiSsid = chosen.wifiSsid,
                records = listOf(chosen),
            )

        assertEquals(1, merged.size)
        assertEquals(LiveViewStreamPreset.FAST, merged.first().streamPreset)
        assertEquals(LiveViewQualityBias.LATENCY, merged.first().qualityBias)
    }
}

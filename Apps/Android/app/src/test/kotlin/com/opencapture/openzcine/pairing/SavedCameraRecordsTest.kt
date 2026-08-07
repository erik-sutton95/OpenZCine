package com.opencapture.openzcine.pairing

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull

class SavedCameraRecordsTest {
    /** Unnamed routers on different subnets are different setups — no permission required. */
    @Test
    fun `two unnamed routers on different subnets are two setups`() {
        val records =
            listOf(
                SavedCameraRecord(
                    host = "192.168.1.246",
                    cameraName = "ZR_6002199",
                    transport = SavedCameraTransport.INFRASTRUCTURE,
                    lastSeenAtEpochMillis = 1_000,
                    wifiSsid = null,
                ),
                SavedCameraRecord(
                    host = "192.168.129.66",
                    cameraName = "ZR_6002199",
                    transport = SavedCameraTransport.INFRASTRUCTURE,
                    lastSeenAtEpochMillis = 2_000,
                    wifiSsid = null,
                ),
            )

        assertEquals(2, SavedCameraRecords.canonicalized(records).size)
    }

    /** And a lease moving inside ONE router is still one setup. */
    @Test
    fun `an unnamed router absorbs its own lease changes`() {
        val records =
            listOf(
                SavedCameraRecord(
                    host = "192.168.1.50",
                    cameraName = "ZR_6002199",
                    transport = SavedCameraTransport.INFRASTRUCTURE,
                    lastSeenAtEpochMillis = 1_000,
                    wifiSsid = null,
                ),
                SavedCameraRecord(
                    host = "192.168.1.246",
                    cameraName = "ZR_6002199",
                    transport = SavedCameraTransport.INFRASTRUCTURE,
                    lastSeenAtEpochMillis = 2_000,
                    wifiSsid = null,
                ),
            )

        val canonical = SavedCameraRecords.canonicalized(records)
        assertEquals(1, canonical.size)
        assertEquals("192.168.1.246", canonical.first().host)
    }

    /**
     * A camera reached from the studio and from home is two setups. The network's name is the only
     * thing that can say so — the address changes with the lease.
     */
    @Test
    fun `two named networks are two router setups`() {
        val records =
            listOf(
                SavedCameraRecord(
                    host = "192.168.1.50",
                    cameraName = "ZR_6002199",
                    transport = SavedCameraTransport.INFRASTRUCTURE,
                    lastSeenAtEpochMillis = 1_000,
                    wifiSsid = null,
                    networkName = "Studio",
                ),
                SavedCameraRecord(
                    host = "10.0.0.9",
                    cameraName = "ZR_6002199",
                    transport = SavedCameraTransport.INFRASTRUCTURE,
                    lastSeenAtEpochMillis = 2_000,
                    wifiSsid = null,
                    networkName = "Home",
                ),
            )

        assertEquals(2, SavedCameraRecords.canonicalized(records).size)
    }

    /** THE reason this is not keyed on the address: a new lease is still one setup. */
    @Test
    fun `a new address on the same network stays one router setup`() {
        val records =
            listOf(
                SavedCameraRecord(
                    host = "192.168.1.50",
                    cameraName = "ZR_6002199",
                    transport = SavedCameraTransport.INFRASTRUCTURE,
                    lastSeenAtEpochMillis = 1_000,
                    wifiSsid = null,
                    networkName = "Studio",
                ),
                SavedCameraRecord(
                    host = "192.168.1.77",
                    cameraName = "ZR_6002199",
                    transport = SavedCameraTransport.INFRASTRUCTURE,
                    lastSeenAtEpochMillis = 2_000,
                    wifiSsid = null,
                    networkName = "Studio",
                ),
            )

        val canonical = SavedCameraRecords.canonicalized(records)
        assertEquals(1, canonical.size)
        assertEquals("192.168.1.77", canonical.first().host)
    }

    /**
     * A refusal must cost nothing: an unnamed network joins whatever is there, which is the
     * single-router behaviour every operator had before names existed.
     */
    @Test
    fun `an unnamed network joins the router setup already there`() {
        val records =
            listOf(
                SavedCameraRecord(
                    host = "192.168.1.50",
                    cameraName = "ZR_6002199",
                    transport = SavedCameraTransport.INFRASTRUCTURE,
                    lastSeenAtEpochMillis = 1_000,
                    wifiSsid = null,
                    networkName = "Studio",
                ),
                SavedCameraRecord(
                    host = "192.168.1.77",
                    cameraName = "ZR_6002199",
                    transport = SavedCameraTransport.INFRASTRUCTURE,
                    lastSeenAtEpochMillis = 2_000,
                    wifiSsid = null,
                    networkName = null,
                ),
            )

        val canonical = SavedCameraRecords.canonicalized(records)
        assertEquals(1, canonical.size)
        // …and the name learned once is not erased by the connect that could not read it.
        assertEquals("Studio", canonical.first().networkName)
    }

    /** Only infrastructure has a network to be told apart by. */
    @Test
    fun `a network name is never stamped on a non-router setup`() {
        val records =
            SavedCameraRecords.upserting(
                host = "192.168.1.1",
                cameraName = "ZR_6002199",
                transport = SavedCameraTransport.CAMERA_ACCESS_POINT,
                lastSeenAtEpochMillis = 1_000,
                wifiSsid = "NIKON_ZR_6002199",
                records = emptyList(),
                networkName = "Studio",
            )

        assertNull(records.single().networkName)
    }

    /** The SSID the platform hands back is quoted, and sometimes refused outright. */
    @Test
    fun `a platform ssid is unwrapped and its refusals rejected`() {
        assertEquals("Studio", ConnectedNetworkName.sanitized("\"Studio\""))
        assertEquals("Studio", ConnectedNetworkName.sanitized("  Studio  "))
        assertNull(ConnectedNetworkName.sanitized(null))
        assertNull(ConnectedNetworkName.sanitized(""))
        assertNull(ConnectedNetworkName.sanitized("\"\""))
        assertNull(ConnectedNetworkName.sanitized("<unknown ssid>"))
        // A camera's own access point is never an infrastructure network.
        assertNull(ConnectedNetworkName.sanitized("\"NIKON_Z6_123456\""))
    }

    /**
     * A record IS one camera setup, keyed by (camera, path). One body's access-point and router
     * setups routinely share an address — every camera-AP Nikon answers on 192.168.1.1 — and
     * matching on the address alone swallowed one into the other.
     */
    @Test
    fun `one camera's setups stay one row each even at a shared address`() {
        val records =
            listOf(
                SavedCameraRecord(
                    host = "192.168.1.1",
                    cameraName = "ZR_6002199",
                    transport = SavedCameraTransport.CAMERA_ACCESS_POINT,
                    lastSeenAtEpochMillis = 1_000,
                    wifiSsid = "NIKON_ZR_6002199",
                ),
                SavedCameraRecord(
                    host = "192.168.1.1",
                    cameraName = "ZR_6002199",
                    transport = SavedCameraTransport.INFRASTRUCTURE,
                    lastSeenAtEpochMillis = 2_000,
                    wifiSsid = null,
                ),
                SavedCameraRecord(
                    host = "192.168.1.1",
                    cameraName = "ZR_6002199",
                    transport = SavedCameraTransport.PHONE_HOTSPOT,
                    lastSeenAtEpochMillis = 3_000,
                    wifiSsid = null,
                ),
            )

        val canonical = SavedCameraRecords.canonicalized(records)

        assertEquals(3, canonical.size)
        assertEquals(3, canonical.map { it.transport }.toSet().size)
    }

    /**
     * The cross-host merge that absorbs a DHCP move must survive the transport key: the same
     * router handing out a new address is still ONE setup, not a second one.
     */
    @Test
    fun `a new address on the same transport is still the same setup`() {
        val records =
            listOf(
                SavedCameraRecord(
                    host = "192.168.1.50",
                    cameraName = "ZR_6002199",
                    transport = SavedCameraTransport.INFRASTRUCTURE,
                    lastSeenAtEpochMillis = 1_000,
                    wifiSsid = null,
                ),
                SavedCameraRecord(
                    host = "192.168.1.77",
                    cameraName = "ZR_6002199",
                    transport = SavedCameraTransport.INFRASTRUCTURE,
                    lastSeenAtEpochMillis = 2_000,
                    wifiSsid = null,
                ),
            )

        val canonical = SavedCameraRecords.canonicalized(records)

        assertEquals(1, canonical.size)
        assertEquals("192.168.1.77", canonical.first().host)
    }

    /**
     * An access-point stamp on a foreign address describes a session that was never on the
     * camera's own network. Pinning the host alone used to throw that address away with the
     * router setup it always was; it becomes its own row instead (shared core's
     * `splittingAccessPoint`).
     */
    @Test
    fun `an access-point record carrying a foreign host splits into both setups`() {
        val poisoned =
            SavedCameraRecord(
                host = "10.0.0.9",
                cameraName = "ZR_6002199",
                transport = SavedCameraTransport.CAMERA_ACCESS_POINT,
                lastSeenAtEpochMillis = 1_000,
                wifiSsid = "NIKON_ZR_6002199",
                customName = "A camera",
            )

        val canonical = SavedCameraRecords.canonicalized(listOf(poisoned))

        assertEquals(2, canonical.size)
        val accessPoint =
            canonical.first { it.transport == SavedCameraTransport.CAMERA_ACCESS_POINT }
        val router = canonical.first { it.transport == SavedCameraTransport.INFRASTRUCTURE }
        // The access point goes back to the address it lives at by definition.
        assertEquals("192.168.1.1", accessPoint.host)
        // The foreign address keeps describing what it always described.
        assertEquals("10.0.0.9", router.host)
        // The operator's nickname belongs to the camera, so both halves keep it.
        assertEquals("A camera", accessPoint.customName)
        assertEquals("A camera", router.customName)
        // Two rows answering to one id would collide in the card list and in reconnect targeting.
        assertEquals(2, canonical.map { it.id }.toSet().size)
    }

    /** An access-point record already at the access point's address has nothing to hand over. */
    @Test
    fun `a healthy access-point record is not split`() {
        val healthy =
            SavedCameraRecord(
                host = "192.168.1.1",
                cameraName = "ZR_6002199",
                transport = SavedCameraTransport.CAMERA_ACCESS_POINT,
                lastSeenAtEpochMillis = 1_000,
                wifiSsid = "NIKON_ZR_6002199",
            )

        assertEquals(1, SavedCameraRecords.canonicalized(listOf(healthy)).size)
    }

    /**
     * The operator's Router choice must survive persistence — the wizard used to collapse it
     * into PHONE_HOTSPOT at save time, silently reclassifying every router camera (the Android
     * twin of iOS's old "Wi-Fi" transport-string collapse).
     */
    @Test
    fun `infrastructure transport survives persistence round trips`() {
        assertEquals(
            SavedCameraTransport.INFRASTRUCTURE,
            SavedCameraTransport.fromPersistedValue("infrastructure"),
        )
        assertEquals("Router", SavedCameraTransport.INFRASTRUCTURE.displayName)
        // Unknown or legacy blobs keep their historical hotspot landing.
        assertEquals(
            SavedCameraTransport.PHONE_HOTSPOT,
            SavedCameraTransport.fromPersistedValue("something-old"),
        )
    }

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
        // Two router setups, because two ADDRESSES are what makes these profiles distinct. This
        // case used to be written as two camera-AP setups at .1 and .2 -- an input the AP-host
        // invariant now makes impossible, since a camera access point only ever hands out .1.
        // Two generically-named records that both resolve to that one address are genuinely
        // indistinguishable and do merge; two bodies with real names at it stay apart (see
        // `two bodies sharing the camera-AP address both survive`).
        val records =
            SavedCameraRecords.canonicalized(
                listOf(
                    SavedCameraRecord(
                        host = "192.168.1.1",
                        cameraName = "Nikon ZR",
                        transport = SavedCameraTransport.INFRASTRUCTURE,
                        lastSeenAtEpochMillis = null,
                        wifiSsid = null,
                    ),
                    SavedCameraRecord(
                        host = "192.168.1.2",
                        cameraName = "Nikon ZR",
                        transport = SavedCameraTransport.INFRASTRUCTURE,
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

    /**
     * An access-point setup lives at the AP's fixed address. "+ Add setup -> Camera access point"
     * builds its record by copying the row it was invoked from, so without pinning it produced an
     * AP setup carrying a router address -- one that dials somewhere the camera never answers, and
     * that suppresses the very join which would have fixed it (the app believes it already holds
     * the AP setup it needs).
     */
    @Test
    fun canonicalizedPinsACameraApSetupToTheAccessPointAddress() {
        val poisoned =
            SavedCameraRecord(
                host = "192.168.1.246",
                cameraName = "ZR_6002199",
                transport = SavedCameraTransport.CAMERA_ACCESS_POINT,
                lastSeenAtEpochMillis = 1_000L,
                wifiSsid = "NIKON_ZR_6002199",
            )
        // The foreign address is no longer discarded — it becomes the router setup it always
        // described — so the access-point half is taken by transport rather than by `single()`.
        val canonical = SavedCameraRecords.canonicalized(listOf(poisoned))
        val repaired =
            canonical.first { it.transport == SavedCameraTransport.CAMERA_ACCESS_POINT }
        assertEquals(SavedCameraRecords.CAMERA_ACCESS_POINT_HOST, repaired.host)
        assertEquals("NIKON_ZR_6002199", repaired.wifiSsid)
        assertEquals(
            "192.168.1.246",
            canonical.first { it.transport == SavedCameraTransport.INFRASTRUCTURE }.host,
        )
    }

    /** A router setup keeps its own address -- the repair must only touch AP-stamped records. */
    @Test
    fun canonicalizedLeavesARouterSetupAddressAlone() {
        val router =
            SavedCameraRecord(
                host = "192.168.1.246",
                cameraName = "ZR_6002199",
                transport = SavedCameraTransport.INFRASTRUCTURE,
                lastSeenAtEpochMillis = 1_000L,
                wifiSsid = null,
            )
        assertEquals("192.168.1.246", SavedCameraRecords.canonicalized(listOf(router)).single().host)
    }
}

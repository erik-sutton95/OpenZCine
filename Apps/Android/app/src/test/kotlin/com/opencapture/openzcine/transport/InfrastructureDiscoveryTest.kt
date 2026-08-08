package com.opencapture.openzcine.transport

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import kotlinx.coroutines.test.runTest

/**
 * Twin of `Tests/OpenZCineCoreTests/InfrastructureDiscoveryTests.swift`. Both suites drive the same
 * table, so a network can never mean one diagnosis on iPhone and another on Android.
 */
class InfrastructureDiscoveryTest {
    // MARK: - Directed hosts

    @Test
    fun `directed hosts keep only dialable addresses on a subnet we are standing in`() {
        val directed =
            InfrastructureDiscovery.directedHosts(
                candidates =
                    listOf(
                        "192.168.1.246", // on our subnet — keep
                        "192.168.129.246", // a sibling setup's travel router — drop
                        "usb:00000030-3030", // a device-id key, never a network peer — drop
                        "ap:NIKON_ZR_02199", // a pending access-point key — drop
                        "192.168.1.246", // duplicate — keep one
                        "", // nothing at all — drop
                    ),
                localSubnets = listOf("192.168.1"),
            )

        assertEquals(listOf("192.168.1.246"), directed)
    }

    /**
     * Dialling a sibling setup on another network was a field false-fail: adding a new Wi-Fi setup
     * armed a watch on the Wi-Fi setup the camera already had, dialled an address on the network
     * the operator had just left, and reported the failure as the NEW setup's.
     */
    @Test
    fun `a sibling setup on another network is never a directed candidate`() {
        val directed =
            InfrastructureDiscovery.directedHosts(
                candidates = listOf("192.168.129.246"),
                localSubnets = listOf("192.168.1"),
            )
        assertTrue(directed.isEmpty())
    }

    @Test
    fun `an excluded host is never dialled`() {
        val directed =
            InfrastructureDiscovery.directedHosts(
                candidates = listOf("192.168.1.246"),
                localSubnets = listOf("192.168.1"),
                excluded = setOf("192.168.1.246"),
            )
        assertTrue(directed.isEmpty())
    }

    // MARK: - Typed verdicts

    /**
     * Verdicts travelled as strings on iOS and drifted: a verdict nobody emitted was counted as
     * occupancy, while running out of file descriptors counted as `other` — evidence about the
     * phone, read as evidence about the network.
     */
    @Test
    fun `only an answer proves somebody holds the address`() {
        for (verdict in HostProbeVerdict.entries) {
            val tally = InfrastructureSweepTally.from(mapOf("10.0.0.2" to verdict))
            assertEquals(1, tally.hostsProbed, "$verdict")
            assertEquals(if (verdict.isOccupied) 1 else 0, tally.occupiedCount, "$verdict")
            assertEquals(if (verdict == HostProbeVerdict.OPEN) 1 else 0, tally.openCount, "$verdict")
        }
        assertTrue(HostProbeVerdict.REFUSED.isOccupied)
        // A dial the OS refused us, and one that exhausted this device, say nothing about the host.
        assertFalse(HostProbeVerdict.DENIED.isOccupied)
        assertFalse(HostProbeVerdict.UNREACHABLE_OTHER.isOccupied)
        assertFalse(HostProbeVerdict.UNREACHABLE_OTHER.isSilence)
    }

    @Test
    fun `a tally counts open refused timeout and occupancy`() {
        val tally =
            InfrastructureSweepTally.from(
                mapOf(
                    "192.168.1.1" to HostProbeVerdict.REFUSED,
                    "192.168.1.10" to HostProbeVerdict.TIMEOUT,
                    "192.168.1.20" to HostProbeVerdict.TIMEOUT,
                    "192.168.1.246" to HostProbeVerdict.OPEN,
                    "192.168.1.50" to HostProbeVerdict.NO_ROUTE,
                    "192.168.1.60" to HostProbeVerdict.DENIED,
                ),
            )

        assertEquals(6, tally.hostsProbed)
        assertEquals(1, tally.openCount)
        assertEquals(1, tally.refusedCount)
        assertEquals(2, tally.timeoutCount)
        assertEquals(1, tally.noRouteCount)
        assertEquals(1, tally.deniedCount)
        assertEquals(listOf("192.168.1.246"), tally.openHosts)
        assertEquals(2, tally.occupiedCount)
    }

    /** A body that wakes on the second pass must not be forgotten because the first pass missed it. */
    @Test
    fun `passes union rather than overwrite each other`() {
        val first =
            InfrastructureSweepTally.from(
                mapOf("10.0.0.2" to HostProbeVerdict.TIMEOUT, "10.0.0.3" to HostProbeVerdict.REFUSED),
            )
        val second =
            InfrastructureSweepTally.from(
                mapOf("10.0.0.2" to HostProbeVerdict.OPEN, "10.0.0.3" to HostProbeVerdict.REFUSED),
            )
        val merged = first.merging(second)

        assertEquals(2, merged.hostsProbed)
        assertEquals(listOf("10.0.0.2"), merged.openHosts)
        assertEquals(listOf("10.0.0.2", "10.0.0.3"), merged.occupiedHosts)
    }

    // MARK: - classifyMiss

    /**
     * The verdict the app owed an operator on a 6 GHz/MLO network: the phone and the camera held
     * addresses on one subnet from one DHCP server, and no packet passed between them. Every host
     * went silent, and the app said "still searching" for days.
     */
    @Test
    fun `a silent subnet is reported as unreachable, not as camera not found`() {
        val silent =
            InfrastructureSweepTally.from(
                (2..200).associate { "192.168.1.$it" to HostProbeVerdict.TIMEOUT },
            )
        assertEquals(
            InfrastructureMissReason.NetworkUnreachable,
            InfrastructureDiscovery.classifyMiss(
                preflight = InfrastructurePreflight.Ready(listOf("192.168.1")),
                onCameraAccessPoint = false,
                tally = silent,
            ),
        )

        // The same subnet with the router answering is a LIVE network holding no camera — a
        // different sentence, and a different thing to go and do.
        val live = silent.copy(refusedCount = 1, occupiedCount = 1, occupiedHosts = listOf("192.168.1.1"))
        assertEquals(
            InfrastructureMissReason.HostsVisibleNoPtp,
            InfrastructureDiscovery.classifyMiss(
                preflight = InfrastructurePreflight.Ready(listOf("192.168.1")),
                onCameraAccessPoint = false,
                tally = live,
            ),
        )

        // No sweep at all must never be dressed up as one.
        assertEquals(
            InfrastructureMissReason.CameraNotFound,
            InfrastructureDiscovery.classifyMiss(
                preflight = InfrastructurePreflight.Ready(listOf("192.168.1")),
                onCameraAccessPoint = false,
                tally = null,
            ),
        )
    }

    @Test
    fun `preflight failures and a held camera outrank any tally`() {
        assertEquals(
            InfrastructureMissReason.NoScannableInterface,
            InfrastructureDiscovery.classifyMiss(
                preflight = InfrastructurePreflight.NoScannableInterface,
                onCameraAccessPoint = false,
                tally = null,
            ),
        )
        assertEquals(
            InfrastructureMissReason.OnCameraAccessPoint,
            InfrastructureDiscovery.classifyMiss(
                preflight = InfrastructurePreflight.Ready(listOf("192.168.1")),
                onCameraAccessPoint = true,
                tally = null,
            ),
        )
        assertEquals(
            InfrastructureMissReason.HeldByOtherDevice("Erik's iPad"),
            InfrastructureDiscovery.classifyMiss(
                preflight = InfrastructurePreflight.Ready(listOf("192.168.1")),
                onCameraAccessPoint = false,
                tally = null,
                heldHolderName = "Erik's iPad",
            ),
        )
    }

    // MARK: - Operator copy

    @Test
    fun `operator copy names the one thing to do`() {
        assertTrue(
            InfrastructureDiscovery.operatorCopy(InfrastructureMissReason.HostsVisibleNoPtp)
                .contains("Connect to computer"),
        )
        val onAp =
            InfrastructureDiscovery.operatorCopy(
                InfrastructureMissReason.OnCameraAccessPoint,
                cameraName = "ZR_6001234",
            )
        assertTrue(onAp.contains("ZR_6001234"))
        assertTrue(onAp.contains("own Wi"))
    }

    /**
     * The popup is read by somebody holding a camera, not by somebody reading a packet capture.
     * Dotted subnets, arrow-chained menu paths and port numbers all shipped on iOS once.
     */
    @Test
    fun `operator copy stays short and untechnical`() {
        val reasons =
            listOf(
                InfrastructureMissReason.LocalNetworkDenied,
                InfrastructureMissReason.NoScannableInterface,
                InfrastructureMissReason.OnCameraAccessPoint,
                InfrastructureMissReason.NetworkUnreachable,
                InfrastructureMissReason.HostsVisibleNoPtp,
                InfrastructureMissReason.CameraNotFound,
                InfrastructureMissReason.HeldByOtherDevice("Erik's iPad"),
            )
        for (reason in reasons) {
            val copy = InfrastructureDiscovery.operatorCopy(reason, cameraName = "ZR_6001234")
            assertTrue(copy.length <= 130, "too long for a popup: $copy")
            assertFalse(copy.contains("→"), "menu arrows are jargon: $copy")
            assertFalse(copy.contains("15740"), "port numbers are jargon: $copy")
            assertFalse(copy.contains(".x"), "dotted subnets are jargon: $copy")
        }
    }

    // MARK: - The finder

    private fun finder(verdicts: Map<String, HostProbeVerdict>) =
        InfrastructureCameraFinder(log = {}) { host, _ ->
            verdicts[host] ?: HostProbeVerdict.TIMEOUT
        }

    private val onSubnetOne = listOf(LocalIPv4Interface("wlan0", "192.168.1.146"))

    @Test
    fun `a directed host that answers is found without sweeping`() = runTest {
        var dialled = 0
        val counting =
            InfrastructureCameraFinder(log = {}) { host, _ ->
                dialled += 1
                if (host == "192.168.1.246") HostProbeVerdict.OPEN else HostProbeVerdict.TIMEOUT
            }

        val report =
            counting.search(
                directedCandidates = listOf("192.168.1.246"),
                knownNames = mapOf("192.168.1.246" to "ZR_6002199"),
                interfaces = onSubnetOne,
            )

        assertTrue(report.foundCamera)
        assertEquals("192.168.1.246", report.cameras.single().host)
        assertEquals("ZR_6002199", report.cameras.single().name)
        // One dial, not 254: the reconnect case must not pay for a sweep.
        assertEquals(1, dialled)
    }

    @Test
    fun `a camera nobody has saved is found by the sweep`() = runTest {
        val report =
            finder(mapOf("192.168.1.246" to HostProbeVerdict.OPEN))
                .search(interfaces = onSubnetOne)

        assertTrue(report.foundCamera)
        assertEquals("192.168.1.246", report.cameras.single().host)
    }

    /** The whole point of the port: before it, this camera could not be found on Android at all. */
    @Test
    fun `the sweep covers every address of the subnet we stand in`() = runTest {
        val report =
            finder(mapOf("192.168.1.254" to HostProbeVerdict.OPEN))
                .search(interfaces = onSubnetOne)

        assertTrue(report.foundCamera, "the last address of the /24 must be swept too")
        assertEquals("192.168.1.254", report.cameras.single().host)
    }

    @Test
    fun `a silent sweep reports the network, and a live one reports the camera`() = runTest {
        val silent = finder(emptyMap()).search(interfaces = onSubnetOne)
        assertEquals(InfrastructureMissReason.NetworkUnreachable, silent.miss)

        val live =
            finder(mapOf("192.168.1.1" to HostProbeVerdict.REFUSED))
                .search(interfaces = onSubnetOne)
        assertEquals(InfrastructureMissReason.HostsVisibleNoPtp, live.miss)
        assertEquals(listOf("192.168.1.1"), live.occupiedHosts)
    }

    @Test
    fun `the phone's own address and a shielded camera are never dialled`() = runTest {
        val dialledHosts = mutableSetOf<String>()
        val recording =
            InfrastructureCameraFinder(log = {}) { host, _ ->
                dialledHosts.add(host)
                HostProbeVerdict.TIMEOUT
            }

        recording.search(
            excludedHosts = setOf("192.168.1.99"),
            interfaces = onSubnetOne,
        )

        assertFalse(dialledHosts.contains("192.168.1.146"), "never dial ourselves")
        assertFalse(dialledHosts.contains("192.168.1.99"), "never dial a shielded camera")
    }

    @Test
    fun `on the camera's own access point the search declines instead of sweeping`() = runTest {
        var dialled = 0
        val counting =
            InfrastructureCameraFinder(log = {}) { _, _ ->
                dialled += 1
                HostProbeVerdict.TIMEOUT
            }

        val report = counting.search(onCameraAccessPoint = true, interfaces = onSubnetOne)

        assertEquals(InfrastructureMissReason.OnCameraAccessPoint, report.miss)
        assertEquals(0, dialled)
    }

    @Test
    fun `with no scannable interface the search says so rather than sweeping nothing`() = runTest {
        val report = finder(emptyMap()).search(interfaces = emptyList())
        assertEquals(InfrastructureMissReason.NoScannableInterface, report.miss)
    }
}

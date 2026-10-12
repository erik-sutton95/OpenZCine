package com.opencapture.openzcine.transport

import com.opencapture.opencine.nikon.HostProbeVerdict
import com.opencapture.opencine.nikon.InfrastructureMissReason
import com.opencapture.opencine.nikon.NikonLocalInterface
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import kotlinx.coroutines.test.runTest

/**
 * This app's infrastructure finder and its copy. The miss classification it relies on is
 * OpenCine's (`InfrastructureDiscoveryTest` in the nikon module, pinned to Swift by vectors).
 */
class InfrastructureDiscoveryTest {
    // MARK: - Operator copy

    @Test
    fun `operator copy names the one thing to do`() {
        assertTrue(
            InfrastructureMissReason.HostsVisibleNoPtp.operatorCopy()
                .contains("Connect to computer"),
        )
        val onAp =
            InfrastructureMissReason.OnCameraAccessPoint.operatorCopy(cameraName = "ZR_6001234")
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
            val copy = reason.operatorCopy(cameraName = "ZR_6001234")
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

    private val onSubnetOne = listOf(NikonLocalInterface("wlan0", "192.168.1.146"))

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

    /**
     * Dialling a sibling setup on another network was a field false-fail: adding a new Wi-Fi setup
     * armed a watch on the Wi-Fi setup the camera already had, dialled an address on the network
     * the operator had just left, and reported the failure as the NEW setup's.
     */
    @Test
    fun `a sibling setup on another network is never dialled`() = runTest {
        val dialledHosts = mutableSetOf<String>()
        val recording =
            InfrastructureCameraFinder(log = {}) { host, _ ->
                dialledHosts.add(host)
                if (host == "192.168.129.246") HostProbeVerdict.OPEN else HostProbeVerdict.TIMEOUT
            }

        val report =
            recording.search(directedCandidates = listOf("192.168.129.246"), interfaces = onSubnetOne)

        assertFalse(report.foundCamera)
        assertFalse(dialledHosts.contains("192.168.129.246"))
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

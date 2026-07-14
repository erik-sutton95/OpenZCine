package com.opencapture.openzcine.transport

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.asFlow
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.test.runTest

/** Discovery bookkeeping against a scripted [NsdBrowser] (no Android framework). */
class CameraDiscoveryTest {
    private class FakeNsdBrowser(private val scripted: List<NsdEvent>) : NsdBrowser {
        var requestedServiceType: String? = null

        override fun events(serviceType: String): Flow<NsdEvent> {
            requestedServiceType = serviceType
            return scripted.asFlow()
        }
    }

    private suspend fun snapshots(vararg events: NsdEvent): List<List<DiscoveredCamera>> =
        CameraDiscovery(FakeNsdBrowser(events.toList())).cameras().toList()

    @Test
    fun `browses the ptp service type`() = runTest {
        val browser = FakeNsdBrowser(emptyList())

        CameraDiscovery(browser).cameras().toList()

        assertEquals("_ptp._tcp.", browser.requestedServiceType)
    }

    @Test
    fun `resolved service appears as a camera`() = runTest {
        val snapshots =
            snapshots(
                NsdEvent.ServiceFound("ZR_1234"),
                NsdEvent.ServiceResolved("ZR_1234", "192.168.1.7", 15740),
            )

        assertEquals(
            listOf(emptyList(), listOf(DiscoveredCamera("ZR_1234", "192.168.1.7", 15740))),
            snapshots,
        )
    }

    @Test
    fun `accepts the private IPv4 ranges supported by iOS discovery`() {
        listOf("172.16.0.1", "172.31.255.254", "192.168.1.7").forEach { host ->
            assertTrue(CameraDiscovery.isSupportedPtpIpDiscoveryHost(host), host)
        }
    }

    @Test
    fun `rejects IPv6 public and malformed NSD endpoints`() {
        listOf(
            "fe80::1",
            "2001:db8::1",
            "8.8.8.8",
            "10.0.0.7",
            "172.15.0.7",
            "172.32.0.7",
            "169.254.1.7",
            "192.167.1.7",
            "192.168.1.256",
            "192.168.1",
            "192.168.1.7 ",
            "camera.local",
        ).forEach { host ->
            assertFalse(CameraDiscovery.isSupportedPtpIpDiscoveryHost(host), host)
        }
    }

    @Test
    fun `unsupported resolution never becomes a selectable camera`() = runTest {
        val snapshots =
            snapshots(
                NsdEvent.ServiceResolved("IPv6 ZR", "fe80::5", 15740),
                NsdEvent.ServiceResolved("Public ZR", "8.8.8.8", 15740),
                NsdEvent.ServiceResolved("Malformed ZR", "192.168.1.256", 15740),
            )

        assertEquals(listOf(emptyList<DiscoveredCamera>()), snapshots)
    }

    @Test
    fun `found but unresolved service is not a camera yet`() = runTest {
        assertEquals(listOf(emptyList()), snapshots(NsdEvent.ServiceFound("ZR_1234")))
    }

    @Test
    fun `lost service disappears from the set`() = runTest {
        val snapshots =
            snapshots(
                NsdEvent.ServiceResolved("ZR_1234", "192.168.1.7", 15740),
                NsdEvent.ServiceLost("ZR_1234"),
            )

        assertEquals(emptyList<DiscoveredCamera>(), snapshots.last())
    }

    @Test
    fun `re-resolution updates a camera's address in place`() = runTest {
        val snapshots =
            snapshots(
                NsdEvent.ServiceResolved("ZR_1234", "192.168.1.7", 15740),
                NsdEvent.ServiceResolved("ZR_1234", "192.168.1.9", 15740),
            )

        assertEquals(listOf(DiscoveredCamera("ZR_1234", "192.168.1.9", 15740)), snapshots.last())
    }

    @Test
    fun `unsupported re-resolution removes a stale camera`() = runTest {
        val snapshots =
            snapshots(
                NsdEvent.ServiceResolved("ZR_1234", "192.168.1.7", 15740),
                NsdEvent.ServiceResolved("ZR_1234", "fe80::5", 15740),
            )

        assertEquals(emptyList<DiscoveredCamera>(), snapshots.last())
    }

    @Test
    fun `multiple cameras sort by name`() = runTest {
        val snapshots =
            snapshots(
                NsdEvent.ServiceResolved("ZR_B", "192.168.1.8", 15740),
                NsdEvent.ServiceResolved("ZR_A", "192.168.1.7", 15740),
            )

        assertEquals(listOf("ZR_A", "ZR_B"), snapshots.last().map(DiscoveredCamera::name))
    }

    @Test
    fun `access point camera targets the fixed ZR host`() {
        assertEquals(
            DiscoveredCamera("Nikon ZR", "192.168.1.1", 15740),
            CameraDiscovery.accessPointCamera(),
        )
    }
}

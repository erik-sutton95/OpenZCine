package com.opencapture.openzcine.transport

import kotlin.test.Test
import kotlin.test.assertEquals
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

package com.opencapture.openzcine.transport

import com.opencapture.opencine.nikon.HostProbeVerdict
import com.opencapture.opencine.nikon.NikonDialPurpose
import com.opencapture.opencine.nikon.NikonDialer
import com.opencapture.opencine.nikon.NikonLocalInterface
import com.opencapture.opencine.nikon.NikonPresence
import com.opencapture.opencine.nikonwire.MonitorRelayWire
import com.opencapture.openzcine.relay.RelayPresence
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/** The Nikon passive-only rule on the app's cameras list (SHELL-02 D8), pinned. */
class CameraListDiscoveryTest {
    private class RecordingDialer : NikonDialer {
        val dials = mutableListOf<Pair<String, NikonDialPurpose>>()

        override suspend fun presence(host: String): NikonPresence? {
            synchronized(dials) { dials += host to NikonDialPurpose.PRESENCE }
            if (host != "192.168.1.7") return null
            val line = MonitorRelayWire.relayPresenceLine("Phone B", true, "192.168.1.20", 51234)
            return NikonPresence("Phone B", "192.168.1.20", line)
        }

        override suspend fun isAlive(host: String): Boolean {
            synchronized(dials) { dials += host to NikonDialPurpose.PRESENCE }
            return host == "192.168.1.30"
        }

        override suspend fun scanControlPort(host: String, timeoutMillis: Int): HostProbeVerdict {
            synchronized(dials) { dials += host to NikonDialPurpose.CAMERA_CONTROL }
            return HostProbeVerdict.OPEN
        }
    }

    @Test
    fun theCamerasListNeverDialsTheControlPort() = runTest {
        val dialer = RecordingDialer()
        val list = CameraListDiscovery(dialer, { listOf(NikonLocalInterface("wlan0", "192.168.1.42")) })

        val presences = list.presences()
        val alive = list.alive(listOf("192.168.1.30", "192.168.1.31"))

        assertTrue(dialer.dials.none { it.second == NikonDialPurpose.CAMERA_CONTROL }, "the list never reaches a camera's control port")
        assertEquals(253 + 2, dialer.dials.size)
        // The relay fields only this app reads survive the shared sweep.
        assertEquals(mapOf("192.168.1.7" to RelayPresence("Phone B", true, "192.168.1.20", 51234)), presences)
        assertEquals(setOf("192.168.1.30"), alive)
    }
}

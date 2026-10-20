package com.opencapture.openzcine.pairing

import com.opencapture.monitorui.MonitorPairingDevice
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * The discover step's rows belong to an idle wizard: once a phase owns the connect pane, a
 * second tap must not start a second first-time pairing (ZAB-140).
 */
class PairingConnectPaneTest {
    private val discovered =
        listOf(
            MonitorPairingDevice("192.168.1.10", "Nikon ZR", "nearby"),
            MonitorPairingDevice("192.168.1.11", "Nikon Z6III", "nearby"),
        )

    private val connecting =
        listOf(
            PairingPhase.ReadyToJoin("NIKON_ZR_01234", "a1b2c3d4", keyFromScan = true),
            PairingPhase.Joining,
            PairingPhase.Handshaking,
            PairingPhase.Pairing(null),
            PairingPhase.ConfirmOnCamera(null),
            PairingPhase.Reconnecting,
        )

    @Test
    fun `the idle discover step offers its rows`() {
        assertEquals(discovered, pairingDiscoveredRows(PairingPhase.Idle, discovered))
    }

    @Test
    fun `a connect in flight hides the discovered rows`() {
        for (phase in connecting) {
            assertTrue(pairingDiscoveredRows(phase, discovered).isEmpty(), "$phase still offers rows")
        }
    }

    @Test
    fun `the failure card hides the discovered rows`() {
        assertTrue(pairingDiscoveredRows(PairingPhase.Error("Couldn't reach the camera."), discovered).isEmpty())
    }

    @Test
    fun `a row tap is ignored while a connect is in flight`() {
        for (phase in connecting) {
            assertFalse(pairingAcceptsSelection(phase), "$phase accepts a second tap")
        }
    }

    @Test
    fun `a row tap works on the discover step and after the failure card`() {
        assertTrue(pairingAcceptsSelection(PairingPhase.Idle))
        assertTrue(pairingAcceptsSelection(PairingPhase.Error("Couldn't reach the camera.")))
    }
}

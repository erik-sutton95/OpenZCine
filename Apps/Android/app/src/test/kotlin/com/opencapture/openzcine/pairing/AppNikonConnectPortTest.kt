package com.opencapture.openzcine.pairing

import com.opencapture.opencine.core.ConnectionFailure
import com.opencapture.opencine.core.RecoveryAction
import com.opencapture.opencine.core.RouteKind
import com.opencapture.opencine.nikon.CameraIdentity
import com.opencapture.opencine.nikon.FakeCameraSession
import com.opencapture.opencine.nikon.NikonConnectException
import com.opencapture.opencine.nikon.NikonConnectRequest
import com.opencapture.opencine.nikon.NikonSighting
import com.opencapture.openzcine.transport.DiscoveredCamera
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** The app's `NikonConnectPort`: held setups ask first, failures are typed, sightings name setups. */
class AppNikonConnectPortTest {
    private val studio = SavedCameraRecord("192.168.1.30", "ZR_3001234", SavedCameraTransport.INFRASTRUCTURE, 1_000, null)
    private val ap =
        SavedCameraRecord("192.168.1.1", "ZR_3001234", SavedCameraTransport.CAMERA_ACCESS_POINT, 2_000, "NIKON_ZR_3001234")

    private fun environment() =
        PairingEnvironment(
            joinCameraAp = { _, _ -> true },
            releaseCameraAp = {},
            hotspotCameras = emptyFlow(),
            createSession = { FakeCameraSession(CameraIdentity("ZR_3001234", "ZR", "3001234")) },
            usbCameraSource = null,
            createUsbSession = { error("no USB here") },
            credentials =
                object : PairingCredentials {
                    override var lastSsid: String? = null

                    override fun passphrase(ssid: String): String? = "key"

                    override fun save(ssid: String, passphrase: String) = Unit
                },
        )

    @Test
    fun aHeldSavedSetupAsksBeforeTakingOver() = runTest {
        val connector = SavedCameraConnector(environment(), { true }, { false }, backgroundScope)
        connector.discoveredCameras.value = listOf(DiscoveredCamera("ZR_3001234", "192.168.1.30", 15740, "Phone B"))
        var paired: PairedCamera? = null
        val port =
            AppNikonConnectPort(
                { id, args -> "$id ${args.joinToString()}".trim() }, connector, { listOf(studio) }, { null },
                onPaired = { paired = it }, onForget = {}, onExplicitUsbReconnect = {}, scope = backgroundScope,
                offersDiagnostics = false,
            )
        val request = NikonConnectRequest.Saved("192.168.1.30", RouteKind.INFRASTRUCTURE_NETWORK)

        val failure = assertFailsWith<NikonConnectException> { port.connect(request) }.failure
        assertEquals(ConnectionFailure.Reason.HeldElsewhere, failure.reason)
        assertEquals(AppNikonConnectPort.TAKE_OVER, (failure.actions.first() as RecoveryAction.Integration).id)
        assertNull(paired, "nothing dials a held camera before the operator agrees")

        port.allowTakeOver("192.168.1.30")
        val connection = port.connect(request)
        assertEquals("192.168.1.30", connection.host)
        assertEquals(RouteKind.INFRASTRUCTURE_NETWORK, connection.kind)
        assertEquals("ZR_3001234", paired?.savedCamera?.cameraName)
    }

    @Test
    fun wifiOffAsksForSettings() = runTest {
        val connector = SavedCameraConnector(environment(), { false }, { false }, backgroundScope)
        val port =
            AppNikonConnectPort(
                { id, _ -> "$id" }, connector, { listOf(ap) }, { null }, onPaired = {}, onForget = {},
                onExplicitUsbReconnect = {}, scope = backgroundScope, offersDiagnostics = true,
            )
        val failure =
            assertFailsWith<NikonConnectException> {
                port.connect(NikonConnectRequest.Saved("192.168.1.1", RouteKind.CAMERA_ACCESS_POINT))
            }.failure
        assertEquals(ConnectionFailure.Reason.RadioOff(ConnectionFailure.Radio.WIFI), failure.reason)
        assertEquals(listOf(RecoveryAction.OpenSettings, RecoveryAction.Retry), failure.actions)
    }

    @Test
    fun sightingsNameSavedSetupsAndPhasesCarryTheAppCopy() = runTest {
        val connector = SavedCameraConnector(environment(), { true }, { false }, backgroundScope)
        val port =
            AppNikonConnectPort(
                { id, _ -> "$id" }, connector, { listOf(studio, ap) }, { null }, onPaired = {}, onForget = {},
                onExplicitUsbReconnect = {}, scope = backgroundScope, offersDiagnostics = false,
            )
        connector.aliveHosts.value = setOf("192.168.1.30")
        connector.discoveredCameras.value =
            listOf(
                DiscoveredCamera("Z_8_7000001", "192.168.1.40", 15740),
                DiscoveredCamera("Camera", "192.168.1.41", 15740, "Phone B"),
            )
        assertEquals(
            listOf(
                NikonSighting("192.168.1.30", "ZR_3001234", NikonSighting.Source.LIVENESS),
                NikonSighting("192.168.1.40", "Z_8_7000001", NikonSighting.Source.NETWORK),
                NikonSighting("192.168.1.41", "Camera", NikonSighting.Source.HELD_BY_ANOTHER_DEVICE, "Phone B"),
            ),
            port.currentSightings(),
            "the access point lights only from its own network",
        )
        runCurrent()
        assertNull(port.phase.value)
    }

    @Test
    fun aRemovedAccessPointSetupTakesItsKey() {
        val second = ap.copy(host = "ap:NIKON_Z8_5009999", wifiSsid = "NIKON_Z8_5009999", cameraName = "Z_8_5009999")
        assertEquals(listOf("NIKON_ZR_3001234"), removedAccessPointSsids(listOf(studio, ap, second), listOf(studio, second)))
        assertTrue(removedAccessPointSsids(listOf(ap), listOf(ap.copy(customName = "A"))).isEmpty())
    }
}

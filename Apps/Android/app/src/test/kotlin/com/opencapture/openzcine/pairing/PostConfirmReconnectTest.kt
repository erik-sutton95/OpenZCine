package com.opencapture.openzcine.pairing

import com.opencapture.opencine.nikon.CameraConnectionPhase
import com.opencapture.opencine.nikon.CameraConnectionProgress
import com.opencapture.opencine.nikon.CameraIdentity
import com.opencapture.opencine.nikon.CameraSession
import com.opencapture.opencine.nikon.FakeCameraSession
import com.opencapture.opencine.nikon.HostProbeVerdict
import com.opencapture.opencine.nikon.NikonBodyWake
import com.opencapture.opencine.nikon.NikonDialer
import com.opencapture.opencine.nikon.NikonLocalInterface
import com.opencapture.opencine.nikon.NikonPresence
import com.opencapture.opencine.nikon.SavedCameraRecord
import com.opencapture.opencine.nikon.SavedCameraTransport
import com.opencapture.openzcine.R
import com.opencapture.openzcine.transport.CameraListDiscovery
import com.opencapture.openzcine.transport.DiscoveredCamera
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.test.currentTime
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNull
import kotlin.test.assertSame
import kotlin.test.assertTrue

/**
 * The one reconnect after the body's pairing Confirm (A4-42): the wizard's first pair and a saved
 * setup's re-pair both run [reconnectAfterBodyConfirm], and the connector's copy comes from the
 * app's resources.
 */
class PostConfirmReconnectTest {
    private val identity = CameraIdentity("ZR_3001234", "ZR", "3001234")
    private val copy = PortCopy { id, args -> "$id ${args.joinToString(" ")}".trim() }

    /** A session whose connect walks [phases] a beat apart, then connects. */
    private class ScriptedSession(
        private val phases: List<CameraConnectionPhase>,
        identity: CameraIdentity,
        private val base: FakeCameraSession = FakeCameraSession(identity),
    ) : CameraSession by base {
        private val progress = MutableStateFlow(CameraConnectionProgress())
        override val connectionProgress: StateFlow<CameraConnectionProgress> = progress
        var disconnected = false

        override suspend fun connect() {
            for (phase in phases) {
                progress.value = CameraConnectionProgress(phase)
                delay(10)
            }
            base.connect()
            progress.value = CameraConnectionProgress(CameraConnectionPhase.CONNECTED)
        }

        override suspend fun disconnect() {
            disconnected = true
            base.disconnect()
        }
    }

    private class Dials(val sessions: MutableList<ScriptedSession>) {
        val hosts = mutableListOf<String>()
        val opened = mutableListOf<ScriptedSession>()

        fun open(host: String): CameraSession {
            hosts += host
            return sessions.removeAt(0).also { opened += it }
        }
    }

    /** List discovery whose liveness dial answers from dial [answerOn] on (never, when null). */
    private class Liveness(private val answerOn: Int?) {
        var dials = 0
        val discovery =
            CameraListDiscovery(
                object : NikonDialer {
                    override suspend fun presence(host: String): NikonPresence? = null

                    override suspend fun isAlive(host: String): Boolean = ++dials >= (answerOn ?: Int.MAX_VALUE)

                    override suspend fun scanControlPort(host: String, timeoutMillis: Int): HostProbeVerdict =
                        error("the connector never dials a control port to wake a body")
                },
                { listOf(NikonLocalInterface("wlan0", "192.168.1.42")) },
            )
    }

    private fun environment(dials: Dials, joins: MutableList<String> = mutableListOf()) =
        PairingEnvironment(
            joinCameraAp = { ssid, _ -> joins.add(ssid) },
            releaseCameraAp = {},
            hotspotCameras = emptyFlow(),
            createSession = dials::open,
            usbCameraSource = null,
            createUsbSession = { error("no USB here") },
            credentials =
                object : PairingCredentials {
                    override var lastSsid: String? = null

                    override fun passphrase(ssid: String): String? = "stored"

                    override fun save(ssid: String, passphrase: String) = Unit
                },
        )

    @Test
    fun aSessionThatAsksForAnotherConfirmIsNeverHandedOver() = runTest {
        val asksAgain = ScriptedSession(listOf(CameraConnectionPhase.HANDSHAKING, CameraConnectionPhase.PAIRING), identity)
        val clean = ScriptedSession(listOf(CameraConnectionPhase.HANDSHAKING), identity)
        val dials = Dials(mutableListOf(asksAgain, clean))
        val hotspot = SavedCameraRecord("172.20.10.5", "ZR_3001234", SavedCameraTransport.PHONE_HOTSPOT, 1_000, null)
        var reconnecting = 0

        val paired =
            reconnectAfterBodyConfirm(
                environment(dials),
                hotspot,
                discovered = { listOf(DiscoveredCamera("ZR_3001234", "172.20.10.7", 15740)) },
                usbCameras = { emptyList() },
            ) { reconnecting += 1 }

        assertSame(clean, paired?.session, "the restore-then-pair that fell into pairing is not a monitor session")
        assertTrue(asksAgain.disconnected)
        assertEquals(false, clean.disconnected)
        assertEquals("172.20.10.7", paired?.savedCamera?.host, "the camera's live address wins")
        assertEquals(listOf("172.20.10.7", "172.20.10.7"), dials.hosts)
        assertEquals(2, reconnecting)
    }

    @Test
    fun anAccessPointSetupRejoinsAndWaitsForDiscoveryToNameTheCamera() = runTest {
        val clean = ScriptedSession(emptyList(), identity)
        val dials = Dials(mutableListOf(clean))
        val joins = mutableListOf<String>()
        val pending =
            SavedCameraRecord("ap:nikon_zr_3001234", "ZR_3001234", SavedCameraTransport.CAMERA_ACCESS_POINT, 1_000, "NIKON_ZR_3001234")
        // Discovery names the camera on the third pass, after the access point is back.
        var passes = 0
        val discovered = { if (++passes < 3) emptyList() else listOf(DiscoveredCamera("ZR_3001234", "192.168.1.1", 15740)) }

        val paired = reconnectAfterBodyConfirm(environment(dials, joins), pending, discovered, { emptyList() }) {}

        assertSame(clean, paired?.session)
        assertEquals(listOf("192.168.1.1"), dials.hosts, "the pending key is never dialled (#327)")
        assertEquals("192.168.1.1", paired?.savedCamera?.host)
        assertEquals(List(3) { "NIKON_ZR_3001234" }, joins, "the AP rebooted: the first pass rejoins, and so does every unbound pass")
    }

    @Test
    fun aCameraThatKeepsAskingForConfirmEndsTheReconnect() = runTest {
        val sessions = MutableList(200) { ScriptedSession(listOf(CameraConnectionPhase.CONFIRM_ON_CAMERA), identity) }
        val dials = Dials(sessions)
        val router = SavedCameraRecord("192.168.1.30", "ZR_3001234", SavedCameraTransport.INFRASTRUCTURE, 1_000, null)

        assertNull(reconnectAfterBodyConfirm(environment(dials), router, { emptyList() }, { emptyList() }) {})
        assertTrue(dials.opened.isNotEmpty() && dials.opened.all { it.disconnected })
    }

    @Test
    fun theConnectorsFailureCopyComesFromResources() = runTest {
        val connector = SavedCameraConnector(environment(Dials(mutableListOf())), { false }, { false }, backgroundScope, copy)
        val ap = SavedCameraRecord("192.168.1.1", "ZR_3001234", SavedCameraTransport.CAMERA_ACCESS_POINT, 1_000, "NIKON_ZR_3001234")
        val wifiOff = assertFailsWith<SavedCameraConnectException> { connector.connect(ap) }
        assertEquals("${R.string.conn_wifi_off_detail}", wifiOff.message)
        assertTrue(wifiOff.wifiOff)

        val unreachable = ScriptedSession(emptyList(), identity, FakeCameraSession(discoverable = null))
        val router = SavedCameraRecord("192.168.1.30", "ZR_3001234", SavedCameraTransport.INFRASTRUCTURE, 1_000, null)
        val online =
            SavedCameraConnector(
                environment(Dials(mutableListOf(unreachable))), { true }, { false }, backgroundScope, copy,
                Liveness(answerOn = 1).discovery,
            )
        assertEquals(
            "${R.string.conn_unreachable_detail} ${router.displayTitle} ${R.string.conn_wrong_network_hint}",
            assertFailsWith<SavedCameraConnectException> { online.connect(router) }.message,
        )
    }

    /** A router setup the list does not see, after the body slept (physical run 2026-10-18). */
    @Test
    fun anUnseenRouterSetupThatStaysSilentNeverStartsAHandshake() = runTest {
        val dials = Dials(mutableListOf())
        val liveness = Liveness(answerOn = null)
        val router = SavedCameraRecord("192.168.1.30", "ZR_3001234", SavedCameraTransport.INFRASTRUCTURE, 1_000, null)
        val connector = SavedCameraConnector(environment(dials), { true }, { false }, backgroundScope, copy, liveness.discovery)

        val failure = assertFailsWith<SavedCameraConnectException> { connector.connect(router) }

        assertEquals(NikonBodyWake.silentMessage(router.displayTitle), failure.message)
        assertEquals(NikonBodyWake.DIALS, liveness.dials)
        assertTrue(dials.hosts.isEmpty(), "no PTP/IP Init goes to a body that never answered")
    }

    @Test
    fun anUnseenRouterSetupThatWakesConnectsOnTheSameAttempt() = runTest {
        val dials = Dials(mutableListOf(ScriptedSession(emptyList(), identity)))
        val liveness = Liveness(answerOn = 3)
        val router = SavedCameraRecord("192.168.1.30", "ZR_3001234", SavedCameraTransport.INFRASTRUCTURE, 1_000, null)
        val connector = SavedCameraConnector(environment(dials), { true }, { false }, backgroundScope, copy, liveness.discovery)

        val paired = connector.connect(router)

        assertEquals("192.168.1.30", paired.savedCamera.host)
        assertEquals(listOf("192.168.1.30"), dials.hosts)
        assertEquals(3, liveness.dials)
        assertTrue(currentTime >= 2 * NikonBodyWake.INTERVAL_MILLIS)
    }

    @Test
    fun aRouterSetupTheListAlreadySeesSkipsTheWake() = runTest {
        val dials = Dials(mutableListOf(ScriptedSession(emptyList(), identity)))
        val liveness = Liveness(answerOn = null)
        val router = SavedCameraRecord("192.168.1.30", "ZR_3001234", SavedCameraTransport.INFRASTRUCTURE, 1_000, null)
        val connector = SavedCameraConnector(environment(dials), { true }, { false }, backgroundScope, copy, liveness.discovery)
        connector.aliveHosts.value = setOf("192.168.1.30")

        connector.connect(router)

        assertEquals(0, liveness.dials)
        assertEquals(listOf("192.168.1.30"), dials.hosts)
    }
}

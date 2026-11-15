package com.opencapture.openzcine.multiview

import android.content.SharedPreferences
import com.opencapture.opencine.appkit.MultiviewCameraAction
import com.opencapture.opencine.appkit.MultiviewNetworkRestore
import com.opencapture.opencine.appkit.MultiviewStageLayout
import com.opencapture.opencine.appkit.MultiviewStagePreferences
import com.opencapture.opencine.appkit.MultiviewStagePreferencesStore
import com.opencapture.opencine.appkit.pickerFooter
import com.opencapture.opencine.appkit.enqueueAdd
import com.opencapture.opencine.appkit.networkRestore
import com.opencapture.opencine.appkit.pickerRows
import com.opencapture.opencine.appkit.screenAppeared
import com.opencapture.opencine.appkit.stageTile
import com.opencapture.opencine.appkit.toggleLUT
import com.opencapture.opencine.core.MonotonicInstant
import com.opencapture.opencine.core.StationHostPath
import com.opencapture.opencine.core.StationNetwork
import com.opencapture.opencine.nikon.CameraIdentity
import com.opencapture.opencine.nikon.CameraPropertySnapshot
import com.opencapture.opencine.nikon.CameraRecordingState
import com.opencapture.opencine.nikon.CameraSession
import com.opencapture.opencine.nikon.CameraSessionState
import com.opencapture.opencine.nikon.LiveFrame
import com.opencapture.opencine.nikon.LiveFrameTimecode
import com.opencapture.opencine.nikon.NikonMovieTone
import com.opencapture.opencine.nikon.NikonMultiviewSavedSetup
import com.opencapture.opencine.nikon.NikonSighting
import com.opencapture.openzcine.FeedLut
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertSame
import kotlin.test.assertTrue
import kotlin.test.fail
import kotlin.time.Duration.Companion.milliseconds

/**
 * OpenZCine on the shared Multiview: the app's host over OpenCine's coordinator with scripted Z
 * bodies behind the real Nikon member links, on virtual time. SIMULATED: physical Nikon behavior is
 * untested. iOS mirror: `ZCineMultiviewHostTests`.
 */
class ZCineMultiviewHostTest {
    /** This phone on a router's Wi-Fi at 192.168.1.10/24. */
    private object PhoneOnWiFi : StationHostPath {
        override fun address(hotspot: Boolean): String? = if (hotspot) null else "192.168.1.10"
        override fun netmask(hotspot: Boolean): String? = if (hotspot) null else "255.255.255.0"
        override suspend fun join(network: StationNetwork): String? = null
    }

    /** One scripted Z body: its session's commands and goodbye, and the frames it sends. */
    private class Body(serial: String, tone: String? = null) : CameraSession {
        val received = mutableListOf<String>()
        private val pending = Channel<LiveFrame>(Channel.UNLIMITED)
        val properties = MutableStateFlow(CameraPropertySnapshot(iso = 800, movieTone = tone))
        override val state: StateFlow<CameraSessionState> =
            MutableStateFlow(CameraSessionState.Connected(CameraIdentity("ZR", "Nikon ZR", serial)))
        override val recordingState: StateFlow<CameraRecordingState> = MutableStateFlow(CameraRecordingState.STANDBY)
        override val cameraProperties: StateFlow<CameraPropertySnapshot> get() = properties
        var collections = 0
        val frames: Flow<LiveFrame> = flow {
            collections += 1
            received += "liveView"
            try {
                for (frame in pending) emit(frame)
            } finally {
                received += "endLiveView"
            }
        }

        fun frame(recording: Boolean = false) {
            pending.trySend(
                LiveFrame(
                    timestampNanos = 0, jpegData = ByteArray(0), isRecording = recording,
                    timecode = LiveFrameTimecode(on = true, hour = 14, minute = 32, second = 8, frame = 12),
                ),
            )
        }

        override suspend fun connect() {}

        override suspend fun setRecording(recording: Boolean) {
            received += if (recording) "start" else "stop"
        }

        override suspend fun disconnect() {
            received += "shutdown"
        }
    }

    /** The scripted network: bodies by host, what the passive pass sees, every dial and exclusion. */
    private class Network {
        val bodies = mutableMapOf<String, Body>()
        var seen: List<NikonSighting> = emptyList()
        val dials = mutableListOf<String>()
        val excludedAsked = mutableListOf<Set<String>>()
    }

    private fun TestScope.environment(
        network: Network,
        saved: List<NikonMultiviewSavedSetup> = emptyList(),
        store: MultiviewStagePreferencesStore? = null,
    ) = ZCineMultiviewEnvironment(
        connect = { host ->
            network.dials += host
            val body = network.bodies[host] ?: error("Nothing answered")
            ZCineMemberTransport(body, body.frames)
        },
        currentHolder = { null },
        sightings = { _, _, excluded ->
            network.excludedAsked += excluded
            network.seen.filter { it.host !in excluded }
        },
        saved = { saved },
        hostPath = PhoneOnWiFi,
        clock = { testScheduler.currentTime },
        monotonic = { MonotonicInstant(testScheduler.currentTime.milliseconds) },
        presentationStore = store,
    )

    private fun TestScope.until(what: String, condition: () -> Boolean) {
        repeat(400) {
            if (condition()) return
            advanceTimeBy(50.milliseconds)
            runCurrent()
        }
        fail("Timed out: $what")
    }

    /** A stage with the body "3001" (recording N-Log) live on slot 0 at 192.168.1.20. */
    private fun TestScope.liveStage(network: Network): Pair<ZCineMultiview, Body> {
        val body = Body("3001", tone = "N-Log")
        body.frame()
        network.bodies["192.168.1.20"] = body
        network.seen = listOf(NikonSighting("192.168.1.20", "ZR", NikonSighting.Source.NETWORK))
        val stage = ZCineMultiview(environment(network), backgroundScope)
        assertFalse(stage.coordinator.screenAppeared(startsSession = true), "no network wizard")
        until("the body is listed") { stage.coordinator.pickerRows().isNotEmpty() }
        val row = stage.coordinator.pickerRows().first()
        assertTrue(stage.coordinator.enqueueAdd(row.id, 0))
        until("the member is live") { stage.coordinator.members[0].publishing }
        return stage to body
    }

    @Test
    fun theAddListOffersSightingsAndSavedSetupsButNeverAMember() = runTest {
        val network = Network()
        network.seen = listOf(
            NikonSighting("192.168.1.20", "ZR", NikonSighting.Source.NETWORK),
            NikonSighting("192.168.1.22", null, NikonSighting.Source.HELD_BY_ANOTHER_DEVICE, heldBy = "iPad"),
        )
        network.bodies["192.168.1.20"] = Body("3001").also { it.frame() }
        val stage = ZCineMultiview(
            environment(network, saved = listOf(NikonMultiviewSavedSetup("192.168.1.21", "Z 8 router"))),
            backgroundScope,
        )
        stage.coordinator.start()
        until("the list fills") { stage.coordinator.pickerRows().size == 2 }
        assertEquals(listOf("ZR", "Z 8 router"), stage.coordinator.pickerRows().map { it.title }, "a body another device holds is not offered")
        assertTrue(stage.coordinator.pickerFooter.endsWith(ZCineMultiview.PICKER_GUIDANCE), "the camera-menu steps follow the footer")
        assertTrue(network.dials.isEmpty(), "listing dials no body")
        val row = stage.coordinator.pickerRows().first()
        stage.coordinator.enqueueAdd(row.id, 0)
        until("the member is live") { stage.coordinator.members[0].publishing }
        until("the next pass excludes the member") { network.excludedAsked.lastOrNull() == setOf("192.168.1.20") }
        until("the list drops the member") { stage.coordinator.pickerRows().map { it.title } == listOf("Z 8 router") }
        assertEquals(listOf("192.168.1.20"), network.dials, "only the picked body")
        stage.coordinator.stop()
    }

    @Test
    fun aLiveTileShowsItsReadingsAndAutoLUTFromTheRecordingTone() = runTest {
        val network = Network()
        val (stage, body) = liveStage(network)
        until("the tone is read") { stage.links[0].recordingTone == NikonMovieTone.N_LOG }
        assertEquals(FeedLut.NLOG_709, stage.autoLook(0))
        assertTrue(stage.lutShown(0), "Auto LUT starts on")
        assertEquals(FeedLut.NLOG_709.label, stage.links[0].autoLUT.conversion)
        val readings = assertNotNull(stage.readings(0))
        assertEquals("ZR", readings.name)
        assertEquals("Nikon ZR", readings.model, "the model GetDeviceInfo reported, as Pocket shows it")
        assertEquals("14:32:08", readings.timecode, "HH:MM:SS like Pocket")
        assertEquals("800", readings.readouts.first().value)
        assertNull(readings.recordingSeconds)
        val tile = assertNotNull(stage.coordinator.stageTile(0))
        assertTrue(tile.actions.any { it.id == MultiviewCameraAction.LUT }, "Auto LUT is offered")
        stage.coordinator.toggleLUT(0)
        assertFalse(stage.lutShown(0), "the operator turns it off per camera")
        body.properties.value = body.properties.value.copy(movieTone = "SDR")
        body.frame(recording = true)
        until("the take shows") { stage.links[0].recordReport?.recording == true }
        assertNull(stage.readings(0)?.recordingSeconds, "a Z body reports no take length: the tally reads REC")
        assertNull(stage.autoLook(0), "SDR needs no look")
        stage.coordinator.stop()
    }

    @Test
    fun liveViewBorrowsTheMemberAndItsTileResumesOnReturn() = runTest {
        val network = Network()
        val (stage, body) = liveStage(network)
        var lent: ZCineMemberTransport? = null
        stage.lendToLiveView = { _, transport ->
            lent = transport
            true
        }
        until("the member's control path is up") { stage.coordinator.members[0].controlHost != null }
        assertTrue(stage.coordinator.openLiveView(0))
        assertEquals(0, stage.lentSlot)
        assertFalse(stage.showsPicture(0), "repairs wait while Live View holds the link")
        assertSame(body, lent?.session)
        assertTrue(stage.owns(body) && stage.lentSession(body))
        until("the tile's pump stood down") { body.received.last() == "endLiveView" }
        stage.returnLentSession()
        assertNull(stage.lentSlot)
        until("the tile resumes") { body.collections == 2 }
        assertFalse("start" in body.received || "stop" in body.received)
        assertFalse("shutdown" in body.received, "the session stayed open")
        stage.coordinator.stop()
    }

    @Test
    fun recordConfirmationFollowsThePreferenceAndCloseReturnsNothing() = runTest {
        val network = Network()
        val (stage, body) = liveStage(network)
        stage.recordConfirmation = { false }
        assertFalse(stage.confirmsRecord)
        stage.recordConfirmation = { true }
        assertTrue(stage.confirmsRecord)
        assertEquals(MultiviewNetworkRestore.NONE, stage.coordinator.networkRestore, "a Z body is never sent anywhere")
        var stopped = false
        stage.stopped = { stopped = true }
        assertTrue(stage.coordinator.closeStage())
        assertTrue(stopped)
        until("the session is closed") { "shutdown" in body.received }
        assertFalse("start" in body.received || "stop" in body.received)
    }

    @Test
    fun theStageLayoutKeepsTheExistingPreferenceKey() = runTest {
        val preferences = MemoryPreferences()
        val store = MultiviewStagePreferencesStore(preferences, ZCineMultiview.PRESENTATION_KEY)
        // What the previous multicam stage saved under the same file and key.
        assertEquals("multiview-presentation", ZCineMultiview.PRESENTATION_PREFERENCES)
        assertEquals("stage", ZCineMultiview.PRESENTATION_KEY)
        assertTrue(store.save(MultiviewStagePreferences(layout = MultiviewStageLayout.GRID, selected = 2, fill = true)))
        val stage = ZCineMultiview(environment(Network(), store = store), backgroundScope)
        assertEquals(MultiviewStageLayout.GRID, stage.coordinator.presentation.layout)
        assertEquals(2, stage.coordinator.presentation.selected)
        assertTrue(stage.coordinator.presentation.fill)
        assertTrue(ZCineMultiview.joinsMultiview(com.opencapture.opencine.nikon.SavedCameraTransport.INFRASTRUCTURE))
        assertTrue(ZCineMultiview.joinsMultiview(com.opencapture.opencine.nikon.SavedCameraTransport.PHONE_HOTSPOT))
        assertFalse(ZCineMultiview.joinsMultiview(com.opencapture.opencine.nikon.SavedCameraTransport.USB_C), "USB-C leaves Multiview")
        assertFalse(ZCineMultiview.joinsMultiview(com.opencapture.opencine.nikon.SavedCameraTransport.CAMERA_ACCESS_POINT))
    }

    /** String-only in-memory preferences: what the stage store reads and writes. */
    private class MemoryPreferences : SharedPreferences {
        private val values = mutableMapOf<String, String?>()

        override fun getAll(): MutableMap<String, *> = values.toMutableMap()
        override fun getString(key: String?, defValue: String?): String? = values[key] ?: defValue
        override fun getStringSet(key: String?, defValues: MutableSet<String>?): MutableSet<String>? = defValues
        override fun getInt(key: String?, defValue: Int): Int = defValue
        override fun getLong(key: String?, defValue: Long): Long = defValue
        override fun getFloat(key: String?, defValue: Float): Float = defValue
        override fun getBoolean(key: String?, defValue: Boolean): Boolean = defValue
        override fun contains(key: String?): Boolean = key in values
        override fun registerOnSharedPreferenceChangeListener(listener: SharedPreferences.OnSharedPreferenceChangeListener?) {}
        override fun unregisterOnSharedPreferenceChangeListener(listener: SharedPreferences.OnSharedPreferenceChangeListener?) {}

        override fun edit(): SharedPreferences.Editor = object : SharedPreferences.Editor {
            private val staged = mutableMapOf<String, String?>()

            override fun putString(key: String, value: String?): SharedPreferences.Editor = apply { staged[key] = value }
            override fun putStringSet(key: String?, values: MutableSet<String>?): SharedPreferences.Editor = this
            override fun putInt(key: String?, value: Int): SharedPreferences.Editor = this
            override fun putLong(key: String?, value: Long): SharedPreferences.Editor = this
            override fun putFloat(key: String?, value: Float): SharedPreferences.Editor = this
            override fun putBoolean(key: String?, value: Boolean): SharedPreferences.Editor = this
            override fun remove(key: String): SharedPreferences.Editor = apply { staged[key] = null }
            override fun clear(): SharedPreferences.Editor = this
            override fun commit(): Boolean {
                values.putAll(staged)
                return true
            }

            override fun apply() {
                commit()
            }
        }
    }
}

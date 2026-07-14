package com.opencapture.openzcine.bridge

import com.opencapture.openzcine.core.CameraIdentity
import com.opencapture.openzcine.core.CameraControl
import com.opencapture.openzcine.core.CameraControlException
import com.opencapture.openzcine.core.CameraPropertyRefreshFailure
import com.opencapture.openzcine.core.CameraPropertyRefreshStatus
import com.opencapture.openzcine.core.CameraRecordingState
import com.opencapture.openzcine.core.CameraSessionEvent
import com.opencapture.openzcine.core.CameraSessionState
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlinx.coroutines.async
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.withTimeout

/**
 * JVM-side behavior only: the native library is never present in unit tests
 * (`SwiftCore.isAvailable` is false), so these cover the guard paths — the
 * wire behavior itself is tested in Swift against the fake ZR
 * (`Tests/OpenZCineAndroidFacadeTests`).
 */
@OptIn(ExperimentalCoroutinesApi::class)
class SwiftCoreCameraSessionTest {
    @Test
    fun `starts disconnected`() {
        assertEquals(
            CameraSessionState.Disconnected,
            SwiftCoreCameraSession("192.168.1.1").state.value,
        )
    }

    @Test
    fun `connect without the native core stays disconnected and does not crash`() = runTest {
        val session = SwiftCoreCameraSession("192.168.1.1")

        session.connect()

        assertEquals(CameraSessionState.Disconnected, session.state.value)
    }

    @Test
    fun `readProperty is null while disconnected`() = runTest {
        assertNull(SwiftCoreCameraSession("192.168.1.1").readProperty(SwiftCore.PROP_BATTERY_LEVEL))
    }

    @Test
    fun `disconnect while disconnected is safe`() = runTest {
        val session = SwiftCoreCameraSession("192.168.1.1")

        session.disconnect()

        assertEquals(CameraSessionState.Disconnected, session.state.value)
    }

    @Test
    fun `cancelling a connection tears down native work and ignores its late callback`() = runTest {
        val bridge = FakeBridge()
        val session = SwiftCoreCameraSession("192.168.1.1", { _, _ -> }, bridge)

        val connecting = async { session.connect() }
        runCurrent()
        connecting.cancelAndJoin()
        bridge.listeners.single().onConnected("ZR", "NIKON ZR", "6001234")

        assertEquals(1, bridge.disconnects)
        assertEquals(CameraSessionState.Disconnected, session.state.value)
    }

    @Test
    fun `retry accepts only the current connection callback`() = runTest {
        val bridge = FakeBridge()
        val session = SwiftCoreCameraSession("192.168.1.1", { _, _ -> }, bridge)
        val first = async { session.connect() }
        runCurrent()
        first.cancelAndJoin()

        val second = async { session.connect() }
        runCurrent()
        bridge.listeners.first().onConnected("Old", "NIKON ZR", "old")
        assertEquals(CameraSessionState.Connecting, session.state.value)

        bridge.listeners.last().onConnected("ZR", "NIKON ZR", "6001234")
        second.await()

        assertEquals(
            CameraSessionState.Connected(CameraIdentity("ZR", "NIKON ZR", "6001234")),
            session.state.value,
        )
    }

    @Test
    fun `recording control uses the current Swift session after connection`() = runTest {
        val bridge = FakeBridge()
        val session = SwiftCoreCameraSession("192.168.1.1", { _, _ -> }, bridge)
        val connecting = async { session.connect() }
        runCurrent()
        bridge.listeners.single().onConnected("ZR", "NIKON ZR", "6001234")
        connecting.await()

        session.setRecording(true)

        assertEquals(listOf(true), bridge.recordingRequests)
        assertEquals(CameraRecordingState.RECORDING, session.recordingState.value)
    }

    @Test
    fun `camera control passes only a typed selector and human readable label`() = runTest {
        val bridge = FakeBridge()
        val session = SwiftCoreCameraSession("192.168.1.1", { _, _ -> }, bridge)
        val connecting = async { session.connect() }
        runCurrent()
        bridge.listeners.single().onConnected("ZR", "NIKON ZR", "6001234")
        connecting.await()

        session.applyControl(CameraControl.WHITE_BALANCE, "5600K")

        assertEquals(listOf(CameraControl.WHITE_BALANCE to "5600K"), bridge.controlRequests)
    }

    @Test
    fun `camera control maps native failures to typed exceptions`() = runTest {
        val bridge = FakeBridge()
        val session = SwiftCoreCameraSession("192.168.1.1", { _, _ -> }, bridge)
        val connecting = async { session.connect() }
        runCurrent()
        bridge.listeners.single().onConnected("ZR", "NIKON ZR", "6001234")
        connecting.await()

        bridge.controlResult = SwiftCore.CONTROL_COMMAND_MEDIA_BUSY
        assertControlFailure(session, CameraControlException.MediaBusy)

        bridge.controlResult = SwiftCore.CONTROL_COMMAND_NO_SESSION
        assertControlFailure(session, CameraControlException.NotConnected)

        bridge.controlResult = SwiftCore.CONTROL_COMMAND_UNSUPPORTED
        assertControlFailure(session, CameraControlException.UnsupportedSelection)

        bridge.controlResult = SwiftCore.CONTROL_COMMAND_REJECTED
        assertControlFailure(session, CameraControlException.CommandRejected)

        bridge.controlResult = SwiftCore.CONTROL_COMMAND_TRANSPORT_FAILED
        assertControlFailure(session, CameraControlException.TransportFailed)
    }

    @Test
    fun `camera control rejects a disconnected session before native work`() = runTest {
        val bridge = FakeBridge()
        val session = SwiftCoreCameraSession("192.168.1.1", { _, _ -> }, bridge)

        assertControlFailure(session, CameraControlException.NotConnected)

        assertEquals(emptyList(), bridge.controlRequests)
    }

    @Test
    fun `camera control serializes with disconnect`() = runTest {
        val bridge = FakeBridge()
        val session = SwiftCoreCameraSession("192.168.1.1", { _, _ -> }, bridge)
        val connecting = async { session.connect() }
        runCurrent()
        bridge.listeners.single().onConnected("ZR", "NIKON ZR", "6001234")
        connecting.await()

        val controlStarted = CountDownLatch(1)
        val releaseControl = CountDownLatch(1)
        bridge.controlHandler = { _, _ ->
            controlStarted.countDown()
            check(releaseControl.await(5, TimeUnit.SECONDS))
            SwiftCore.CONTROL_COMMAND_ACCEPTED
        }
        val controlling = async { session.applyControl(CameraControl.ISO, "800") }
        runCurrent()
        try {
            assertTrue(controlStarted.await(5, TimeUnit.SECONDS))
            val disconnecting = async { session.disconnect() }
            runCurrent()

            assertEquals(0, bridge.disconnects)

            releaseControl.countDown()
            controlling.await()
            disconnecting.await()
        } finally {
            releaseControl.countDown()
        }

        assertEquals(1, bridge.disconnects)
    }

    @Test
    fun `camera events preserve raw property data and authoritatively update recording`() = runTest {
        val bridge = FakeBridge()
        val session = SwiftCoreCameraSession("192.168.1.1", { _, _ -> }, bridge)
        val connecting = async { session.connect() }
        runCurrent()
        bridge.listeners.single().onConnected("ZR", "NIKON ZR", "6001234")
        connecting.await()

        val propertyEvent = async { session.events.first() }
        runCurrent()
        bridge.eventListeners.single().onEvent(
            0x4006,
            9,
            longArrayOf(0xD0A4, -1),
        )

        assertEquals(
            CameraSessionEvent.PropertyChanged(
                rawEventCode = 0x4006,
                transactionId = 9,
                rawParameters = listOf(0xD0A4, 0xFFFF_FFFFL),
                propertyCode = 0xD0A4,
            ),
            propertyEvent.await(),
        )

        bridge.eventListeners.single().onEvent(0xC10A, 10, longArrayOf())

        assertEquals(CameraRecordingState.RECORDING, session.recordingState.value)
    }

    @Test
    fun `late camera event after disconnect is ignored`() = runTest {
        val bridge = FakeBridge()
        val session = SwiftCoreCameraSession("192.168.1.1", { _, _ -> }, bridge)
        val connecting = async { session.connect() }
        runCurrent()
        bridge.listeners.single().onConnected("ZR", "NIKON ZR", "6001234")
        connecting.await()

        session.disconnect()
        bridge.eventListeners.single().onEvent(0xC10A, 10, longArrayOf())

        assertEquals(CameraSessionState.Disconnected, session.state.value)
        assertEquals(CameraRecordingState.STANDBY, session.recordingState.value)
    }

    @Test
    fun `unexpected event channel end makes the session disconnected`() = runTest {
        val bridge = FakeBridge()
        val session = SwiftCoreCameraSession("192.168.1.1", { _, _ -> }, bridge)
        val connecting = async { session.connect() }
        runCurrent()
        bridge.listeners.single().onConnected("ZR", "NIKON ZR", "6001234")
        connecting.await()

        bridge.eventListeners.single().onEnded("The camera closed the connection.")
        bridge.eventListeners.single().onEvent(0xC10A, 10, longArrayOf())

        assertEquals(CameraSessionState.Disconnected, session.state.value)
        assertEquals(CameraRecordingState.STANDBY, session.recordingState.value)
    }

    @Test
    fun `initial semantic readback publishes a typed property state flow`() = runTest {
        val bridge = FakeBridge()
        bridge.propertyRefreshPayload = propertyPayload()
        val session =
            SwiftCoreCameraSession(
                host = "192.168.1.1",
                phaseLogger = { _, _ -> },
                core = bridge,
                propertyRefreshScope = this,
                propertyRefreshDispatcher = StandardTestDispatcher(testScheduler),
                propertyPollIntervalMillis = 60_000,
            )
        val connecting = async { session.connect() }
        runCurrent()
        bridge.listeners.single().onConnected("ZR", "NIKON ZR", "6001234")
        connecting.await()
        runCurrent()

        assertEquals(800L, session.cameraProperties.value.iso)
        assertEquals("M", session.cameraProperties.value.exposureMode)
        assertEquals("1/50", session.cameraProperties.value.shutterSpeed)
        assertEquals("f/2.8", session.cameraProperties.value.iris)
        assertEquals("Color temp", session.cameraProperties.value.whiteBalanceMode)
        assertEquals(5_600, session.cameraProperties.value.whiteBalanceKelvin)
        assertEquals("24-70mm f/2.8", session.cameraProperties.value.lens)
        assertEquals("AF-C", session.cameraProperties.value.focusMode)
        assertEquals("Line", session.cameraProperties.value.audioInput)
        assertEquals(500_000_000_000, session.cameraProperties.value.storage?.freeSpaceBytes)
        assertEquals(
            CameraPropertyRefreshStatus.Ready,
            session.propertyRefreshStatus.value,
        )
        assertEquals(
            listOf(
                FakeBridge.PropertyRefreshRequest(
                    request = SwiftCore.PROPERTY_REFRESH_BOOTSTRAP,
                    recording = false,
                    propertyCode = 0L,
                ),
            ),
            bridge.refreshRequests(),
        )

        session.disconnect()
    }

    @Test
    fun `property events debounce and coalesce into one semantic refresh`() = runTest {
        val bridge = FakeBridge()
        bridge.propertyRefreshHandler = { request ->
            if (request.request == SwiftCore.PROPERTY_REFRESH_EVENT) {
                propertyPayload(iso = 1_250, warningRaw = 7, temperatureStatus = "CHECK")
            } else {
                propertyPayload()
            }
        }
        val session =
            SwiftCoreCameraSession(
                host = "192.168.1.1",
                phaseLogger = { _, _ -> },
                core = bridge,
                propertyRefreshScope = this,
                propertyRefreshDispatcher = StandardTestDispatcher(testScheduler),
                propertyPollIntervalMillis = 60_000,
                propertyEventDebounceMillis = 250,
            )
        val connecting = async { session.connect() }
        runCurrent()
        bridge.listeners.single().onConnected("ZR", "NIKON ZR", "6001234")
        connecting.await()
        runCurrent()
        bridge.clearRefreshRequests()

        bridge.eventListeners.single().onEvent(0x4006, 9, longArrayOf(0xD0A4))
        bridge.eventListeners.single().onEvent(0x4006, 10, longArrayOf(0xD0A4))
        advanceTimeBy(249)
        runCurrent()
        assertEquals(emptyList(), bridge.refreshRequests())

        advanceTimeBy(1)
        runCurrent()

        assertEquals(
            listOf(
                FakeBridge.PropertyRefreshRequest(
                    request = SwiftCore.PROPERTY_REFRESH_EVENT,
                    recording = false,
                    propertyCode = 0xD0A4,
                ),
            ),
            bridge.refreshRequests(),
        )
        assertEquals(1_250L, session.cameraProperties.value.iso)
        assertEquals(7, session.cameraProperties.value.warningRaw)
        assertEquals(CameraPropertyRefreshStatus.Ready, session.propertyRefreshStatus.value)

        session.disconnect()
    }

    @Test
    fun `property refresh is single flight with concurrent manual requests`() = runTest {
        val bridge = FakeBridge()
        val session =
            SwiftCoreCameraSession(
                host = "192.168.1.1",
                phaseLogger = { _, _ -> },
                core = bridge,
                automaticallyRefreshProperties = false,
            )
        val connecting = async { session.connect() }
        runCurrent()
        bridge.listeners.single().onConnected("ZR", "NIKON ZR", "6001234")
        connecting.await()

        val firstNativeRead = CountDownLatch(1)
        val releaseFirstRead = CountDownLatch(1)
        val secondNativeRead = CountDownLatch(1)
        bridge.propertyRefreshHandler = { request ->
            if (bridge.refreshRequests().size == 1) {
                firstNativeRead.countDown()
                check(releaseFirstRead.await(5, TimeUnit.SECONDS))
            } else {
                secondNativeRead.countDown()
            }
            propertyPayload(iso = if (request.propertyCode == 0L) 800 else 1_000)
        }

        val first = async(Dispatchers.Default) { session.refreshProperties() }
        try {
            assertTrue(firstNativeRead.await(5, TimeUnit.SECONDS))
            val second = async(Dispatchers.Default) { session.refreshProperties() }

            assertFalse(secondNativeRead.await(150, TimeUnit.MILLISECONDS))
            assertEquals(1, bridge.maximumRefreshConcurrency())

            releaseFirstRead.countDown()
            first.await()
            second.await()
        } finally {
            releaseFirstRead.countDown()
        }

        assertEquals(2, bridge.refreshRequests().size)
        assertEquals(1, bridge.maximumRefreshConcurrency())
        session.disconnect()
    }

    @Test
    fun `disconnect clears a manual refresh completing during teardown`() = runTest {
        val bridge = FakeBridge()
        val session =
            SwiftCoreCameraSession(
                host = "192.168.1.1",
                phaseLogger = { _, _ -> },
                core = bridge,
                automaticallyRefreshProperties = false,
            )
        val connecting = async { session.connect() }
        runCurrent()
        bridge.listeners.single().onConnected("ZR", "NIKON ZR", "6001234")
        connecting.await()

        val nativeReadStarted = CountDownLatch(1)
        val releaseNativeRead = CountDownLatch(1)
        bridge.propertyRefreshHandler = {
            nativeReadStarted.countDown()
            check(releaseNativeRead.await(5, TimeUnit.SECONDS))
            propertyPayload(iso = 1_600)
        }

        val refresh = async(Dispatchers.Default) { session.refreshProperties() }
        try {
            assertTrue(nativeReadStarted.await(5, TimeUnit.SECONDS))
            assertEquals(CameraPropertyRefreshStatus.Refreshing, session.propertyRefreshStatus.value)

            val disconnect = async(Dispatchers.Default) { session.disconnect() }
            withTimeout(5_000) {
                session.propertyRefreshStatus.first { it == CameraPropertyRefreshStatus.Idle }
            }
            releaseNativeRead.countDown()
            refresh.await()
            disconnect.await()
        } finally {
            releaseNativeRead.countDown()
        }

        assertEquals(CameraSessionState.Disconnected, session.state.value)
        assertEquals(CameraPropertyRefreshStatus.Idle, session.propertyRefreshStatus.value)
        assertNull(session.cameraProperties.value.iso)
    }

    @Test
    fun `unsupported failures preserve state and disconnect cancels pending refreshes`() = runTest {
        val bridge = FakeBridge()
        val session =
            SwiftCoreCameraSession(
                host = "192.168.1.1",
                phaseLogger = { _, _ -> },
                core = bridge,
                propertyRefreshScope = this,
                propertyRefreshDispatcher = StandardTestDispatcher(testScheduler),
                propertyPollIntervalMillis = 100,
                propertyEventDebounceMillis = 50,
            )
        val connecting = async { session.connect() }
        runCurrent()
        bridge.listeners.single().onConnected("ZR", "NIKON ZR", "6001234")
        connecting.await()
        runCurrent()

        bridge.clearRefreshRequests()
        bridge.propertyRefreshPayload = propertyPayload(result = "unsupported", iso = 640)
        session.refreshProperties()
        assertEquals(640L, session.cameraProperties.value.iso)
        assertEquals(
            CameraPropertyRefreshStatus.Degraded(
                CameraPropertyRefreshFailure.UNSUPPORTED_PROPERTY,
            ),
            session.propertyRefreshStatus.value,
        )
        assertTrue(session.state.value is CameraSessionState.Connected)

        bridge.propertyRefreshPayload = null
        session.refreshProperties()
        assertEquals(640L, session.cameraProperties.value.iso)
        assertEquals(
            CameraPropertyRefreshStatus.Degraded(
                CameraPropertyRefreshFailure.TRANSPORT_FAILED,
            ),
            session.propertyRefreshStatus.value,
        )

        bridge.propertyRefreshPayload = "result\tunknown"
        session.refreshProperties()
        assertEquals(640L, session.cameraProperties.value.iso)
        assertEquals(
            CameraPropertyRefreshStatus.Degraded(
                CameraPropertyRefreshFailure.TRANSPORT_FAILED,
            ),
            session.propertyRefreshStatus.value,
        )

        bridge.clearRefreshRequests()
        bridge.eventListeners.single().onEvent(0x4006, 11, longArrayOf(0xD0A4))
        session.disconnect()
        advanceTimeBy(1_000)
        runCurrent()

        assertEquals(CameraSessionState.Disconnected, session.state.value)
        assertEquals(CameraPropertyRefreshStatus.Idle, session.propertyRefreshStatus.value)
        assertEquals(null, session.cameraProperties.value.iso)
        assertEquals(emptyList(), bridge.refreshRequests())
    }

    private class FakeBridge : SwiftCoreSessionBridge {
        data class PropertyRefreshRequest(
            val request: Int,
            val recording: Boolean,
            val propertyCode: Long,
        )

        override val isAvailable: Boolean = true
        val listeners = mutableListOf<SwiftCore.SessionListener>()
        val eventListeners = mutableListOf<SwiftCore.SessionEventListener>()
        val recordingRequests = mutableListOf<Boolean>()
        val controlRequests = mutableListOf<Pair<CameraControl, String>>()
        private val refreshLock = Any()
        private val propertyRefreshRequests = mutableListOf<PropertyRefreshRequest>()
        private var activeRefreshes = 0
        private var maximumRefreshes = 0
        @Volatile var propertyRefreshPayload: String? = propertyPayload()
        @Volatile var propertyRefreshHandler: ((PropertyRefreshRequest) -> String?)? = null
        var controlResult = SwiftCore.CONTROL_COMMAND_ACCEPTED
        var controlHandler: ((CameraControl, String) -> Int)? = null
        var disconnects = 0

        override fun connect(host: String, listener: SwiftCore.SessionListener) {
            listeners += listener
        }

        override fun startEventStream(listener: SwiftCore.SessionEventListener) {
            eventListeners += listener
        }

        override fun readProperty(code: Int): String? = null

        override fun refreshPropertySnapshot(
            request: Int,
            recording: Boolean,
            propertyCode: Long,
        ): String? {
            val entry = PropertyRefreshRequest(request, recording, propertyCode)
            synchronized(refreshLock) {
                propertyRefreshRequests += entry
                activeRefreshes += 1
                maximumRefreshes = maxOf(maximumRefreshes, activeRefreshes)
            }
            try {
                return propertyRefreshHandler?.invoke(entry) ?: propertyRefreshPayload
            } finally {
                synchronized(refreshLock) {
                    activeRefreshes -= 1
                }
            }
        }

        fun refreshRequests(): List<PropertyRefreshRequest> =
            synchronized(refreshLock) { propertyRefreshRequests.toList() }

        fun clearRefreshRequests() {
            synchronized(refreshLock) { propertyRefreshRequests.clear() }
        }

        fun maximumRefreshConcurrency(): Int = synchronized(refreshLock) { maximumRefreshes }

        override fun setRecording(recording: Boolean): Int {
            recordingRequests += recording
            return SwiftCore.RECORDING_COMMAND_ACCEPTED
        }

        override fun applyControl(control: CameraControl, label: String): Int {
            controlRequests += control to label
            return controlHandler?.invoke(control, label) ?: controlResult
        }

        override fun disconnect() {
            disconnects++
        }
    }

    private suspend fun assertControlFailure(
        session: SwiftCoreCameraSession,
        expected: CameraControlException,
    ) {
        try {
            session.applyControl(CameraControl.ISO, "800")
            throw AssertionError("Expected $expected")
        } catch (actual: CameraControlException) {
            assertEquals(expected, actual)
        }
    }

    private companion object {
        fun propertyPayload(
            result: String = "accepted",
            iso: Int = 800,
            warningRaw: Int = 0,
            temperatureStatus: String = "OK",
        ): String =
            listOf(
                "result\t$result",
                "iso\t$iso",
                "baseIso\tHigh",
                "exposureMode\tM",
                "shutterMode\tspeed",
                "shutterSpeed\t1/50",
                "iris\tf/2.8",
                "whiteBalanceMode\tColor temp",
                "whiteBalanceKelvin\t5600",
                "batteryPercent\t80",
                "warningRaw\t$warningRaw",
                "temperatureStatus\t$temperatureStatus",
                "storageTotalCapacityBytes\t1000000000000",
                "storageFreeSpaceBytes\t500000000000",
                "lens\t24-70mm f/2.8",
                "focusMode\tAF-C",
                "audioInput\tLine",
            ).joinToString("\n")
    }
}

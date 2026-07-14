package com.opencapture.openzcine.bridge

import com.opencapture.openzcine.core.CameraIdentity
import com.opencapture.openzcine.core.CameraControl
import com.opencapture.openzcine.core.CameraControlException
import com.opencapture.openzcine.core.CameraRecordingState
import com.opencapture.openzcine.core.CameraSessionEvent
import com.opencapture.openzcine.core.CameraSessionState
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlinx.coroutines.async
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest

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

    private class FakeBridge : SwiftCoreSessionBridge {
        override val isAvailable: Boolean = true
        val listeners = mutableListOf<SwiftCore.SessionListener>()
        val eventListeners = mutableListOf<SwiftCore.SessionEventListener>()
        val recordingRequests = mutableListOf<Boolean>()
        val controlRequests = mutableListOf<Pair<CameraControl, String>>()
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
}

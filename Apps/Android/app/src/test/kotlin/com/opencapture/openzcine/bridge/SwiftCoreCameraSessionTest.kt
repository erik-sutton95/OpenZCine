package com.opencapture.openzcine.bridge

import com.opencapture.openzcine.core.CameraIdentity
import com.opencapture.openzcine.core.CameraRecordingState
import com.opencapture.openzcine.core.CameraSessionState
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlinx.coroutines.async
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.ExperimentalCoroutinesApi
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

    private class FakeBridge : SwiftCoreSessionBridge {
        override val isAvailable: Boolean = true
        val listeners = mutableListOf<SwiftCore.SessionListener>()
        val recordingRequests = mutableListOf<Boolean>()
        var disconnects = 0

        override fun connect(host: String, listener: SwiftCore.SessionListener) {
            listeners += listener
        }

        override fun readProperty(code: Int): String? = null

        override fun setRecording(recording: Boolean): Int {
            recordingRequests += recording
            return SwiftCore.RECORDING_COMMAND_ACCEPTED
        }

        override fun disconnect() {
            disconnects++
        }
    }
}

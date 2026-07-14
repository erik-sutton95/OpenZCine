package com.opencapture.openzcine.bridge

import com.opencapture.openzcine.core.CameraSessionState
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlinx.coroutines.test.runTest

/**
 * JVM-side behavior only: the native library is never present in unit tests
 * (`SwiftCore.isAvailable` is false), so these cover the guard paths — the
 * wire behavior itself is tested in Swift against the fake ZR
 * (`Tests/OpenZCineAndroidFacadeTests`).
 */
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
}

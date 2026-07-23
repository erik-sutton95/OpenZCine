package com.opencapture.openzcine.bridge

import com.opencapture.openzcine.core.CameraControl
import com.opencapture.openzcine.core.CameraControlException
import com.opencapture.openzcine.core.CameraConnectionPhase
import com.opencapture.openzcine.core.CameraConnectionProgress
import com.opencapture.openzcine.core.CameraFocusException
import com.opencapture.openzcine.core.CameraFocusPoint
import com.opencapture.openzcine.core.CameraIdentity
import com.opencapture.openzcine.core.CameraPropertyRefreshFailure
import com.opencapture.openzcine.core.CameraPropertyRefreshStatus
import com.opencapture.openzcine.core.CameraRecordingState
import com.opencapture.openzcine.core.CameraSessionEvent
import com.opencapture.openzcine.core.CameraSessionState
import com.opencapture.openzcine.transport.UsbPtpTransport
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertFailsWith
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
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy

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
    fun `first pair passes its direct strategy and stable initiator identity to Swift`() = runTest {
        val bridge = FakeBridge()
        val initiatorGuid = ByteArray(16) { index -> index.toByte() }
        val session =
            SwiftCoreCameraSession(
                host = "192.168.1.1",
                phaseLogger = { _, _ -> },
                core = bridge,
                connectionStrategy = PtpIpConnectionStrategy.FIRST_TIME_PAIRING,
                initiatorGuid = initiatorGuid,
            )

        val connecting = async { session.connect() }
        runCurrent()

        assertEquals(
            PtpIpConnectionStrategy.FIRST_TIME_PAIRING,
            bridge.ptpIpConnects.single().connectionStrategy,
        )
        assertContentEquals(initiatorGuid, bridge.ptpIpConnects.single().initiatorGuid)
        bridge.listeners.single().onConnected("ZR", "NIKON ZR", "6001234")
        connecting.await()
    }

    @Test
    fun `pairing progress does not collapse an accepted Nikon challenge into a handshake`() = runTest {
        val bridge = FakeBridge()
        val session = SwiftCoreCameraSession("192.168.1.1", { _, _ -> }, bridge)

        val connecting = async { session.connect() }
        runCurrent()
        val listener = bridge.listeners.single()

        listener.onPhase("pairing", "")
        assertEquals(
            CameraConnectionProgress(CameraConnectionPhase.PAIRING),
            session.connectionProgress.value,
        )
        listener.onPhase("confirmOnCamera", "123456")
        assertEquals(
            CameraConnectionProgress(CameraConnectionPhase.CONFIRM_ON_CAMERA, "123456"),
            session.connectionProgress.value,
        )

        listener.onConnected("ZR", "NIKON ZR", "6001234")
        connecting.await()
        assertEquals(
            CameraConnectionProgress(CameraConnectionPhase.CONNECTED, "ZR"),
            session.connectionProgress.value,
        )
    }

    @Test
    fun `USB connection hands only a raw transport to the Swift bridge and cancellation cleans it up`() =
        runTest {
            val bridge = FakeBridge()
            val transport = FakeUsbTransport()
            val session =
                SwiftCoreCameraSession(
                    host = "usb:5d6f4d746ecf9da40a1b0ce273d3d8d3",
                    phaseLogger = { _, _ -> },
                    core = bridge,
                    usbTransport = transport,
                    cameraNameHint = "Nikon USB camera",
                )

            val connecting = async { session.connect() }
            runCurrent()

            assertEquals(emptyList(), bridge.hostConnects)
            assertEquals(1, bridge.usbConnects.size)
            assertTrue(bridge.usbConnects.single().transport === transport)
            assertEquals("Nikon USB camera", bridge.usbConnects.single().cameraNameHint)

            connecting.cancelAndJoin()

            assertEquals(1, bridge.disconnects)
            assertTrue(transport.isClosed())
            assertEquals(CameraSessionState.Disconnected, session.state.value)
        }

    @Test
    fun `cancelling USB attempt A cannot close newer retry B`() = runTest {
        val bridge = FakeBridge()
        val transportA = FakeUsbTransport()
        val transportB = FakeUsbTransport()
        val first = usbSession(bridge, transportA)
        val second = usbSession(bridge, transportB)
        val disconnectStarted = CountDownLatch(1)
        val releaseDisconnect = CountDownLatch(1)

        val connectingA = async { first.connect() }
        runCurrent()
        val ownerA = bridge.usbConnects.single().connectionOwner
        bridge.disconnectHandler = { owner ->
            if (owner == ownerA) {
                disconnectStarted.countDown()
                check(releaseDisconnect.await(5, TimeUnit.SECONDS))
            }
        }

        connectingA.cancel()
        runCurrent()
        assertTrue(disconnectStarted.await(5, TimeUnit.SECONDS))

        val connectingB = async { second.connect() }
        runCurrent()
        bridge.listeners.last().onConnected("ZR", "NIKON ZR", "6001234")
        connectingB.await()

        releaseDisconnect.countDown()
        connectingA.cancelAndJoin()

        assertEquals(listOf(ownerA), bridge.disconnectOwners)
        assertTrue(transportA.isClosed())
        assertFalse(transportB.isClosed())
        assertEquals(
            CameraSessionState.Connected(CameraIdentity("ZR", "NIKON ZR", "6001234")),
            second.state.value,
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

        bridge.roundTripMilliseconds = 13.75
        bridge.controlResult = SwiftCore.CONTROL_COMMAND_READBACK_MISMATCH
        assertControlFailure(session, CameraControlException.ReadbackMismatch)
        assertEquals(13.75, session.latestCommandRoundTripMilliseconds.value)

        bridge.controlResult = SwiftCore.CONTROL_COMMAND_TRANSPORT_FAILED
        assertControlFailure(session, CameraControlException.TransportFailed)
    }

    @Test
    fun `session publishes native RTT and clears it during disconnect`() = runTest {
        val bridge = FakeBridge().apply { roundTripMilliseconds = 7.25 }
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

        assertEquals(7.25, session.latestCommandRoundTripMilliseconds.value)

        bridge.roundTripMilliseconds = 11.5
        session.applyControl(CameraControl.ISO, "800")
        assertEquals(11.5, session.latestCommandRoundTripMilliseconds.value)

        session.disconnect()
        assertNull(session.latestCommandRoundTripMilliseconds.value)
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
    fun `focus commands pass typed coordinates and reset through the Swift bridge`() = runTest {
        val bridge = FakeBridge()
        val session = connectedSession(bridge)

        assertTrue(session.changeAfArea(CameraFocusPoint(3_024, 1_700)))
        session.resetFocusPoint()

        assertEquals(listOf(CameraFocusPoint(3_024, 1_700)), bridge.focusRequests)
        assertEquals(1, bridge.focusResetRequests)
    }

    @Test
    fun `focus commands map every native result to a typed exception`() = runTest {
        val bridge = FakeBridge()
        val session = connectedSession(bridge)

        val cases =
            listOf(
                SwiftCore.FOCUS_COMMAND_NO_SESSION to CameraFocusException.NotConnected,
                SwiftCore.FOCUS_COMMAND_MEDIA_BUSY to CameraFocusException.MediaBusy,
                SwiftCore.FOCUS_COMMAND_UNAVAILABLE to CameraFocusException.Unavailable,
                SwiftCore.FOCUS_COMMAND_REJECTED to CameraFocusException.CommandRejected,
                SwiftCore.FOCUS_COMMAND_TRANSPORT_FAILED to CameraFocusException.TransportFailed,
                99 to CameraFocusException.TransportFailed,
            )
        for ((result, expected) in cases) {
            bridge.focusResult = result
            assertEquals(
                expected,
                assertFailsWith<CameraFocusException> {
                    session.changeAfArea(CameraFocusPoint(10, 20))
                },
            )
        }

        bridge.focusResult = SwiftCore.FOCUS_COMMAND_ACCEPTED
        bridge.focusResetResult = SwiftCore.FOCUS_COMMAND_MEDIA_BUSY
        assertEquals(
            CameraFocusException.MediaBusy,
            assertFailsWith<CameraFocusException> { session.resetFocusPoint() },
        )

        bridge.available = false
        assertEquals(
            CameraFocusException.CoreUnavailable,
            assertFailsWith<CameraFocusException> {
                session.changeAfArea(CameraFocusPoint(10, 20))
            },
        )
    }

    @Test
    fun `focus command rejects a disconnected session before native work`() = runTest {
        val bridge = FakeBridge()
        val session = SwiftCoreCameraSession("192.168.1.1", { _, _ -> }, bridge)

        assertEquals(
            CameraFocusException.NotConnected,
            assertFailsWith<CameraFocusException> {
                session.changeAfArea(CameraFocusPoint(10, 20))
            },
        )
        assertEquals(emptyList(), bridge.focusRequests)
    }

    @Test
    fun `focus waiters are latest wins while an accepted native request finishes`() = runTest {
        val bridge = FakeBridge()
        val session = connectedSession(bridge)
        val firstStarted = CountDownLatch(1)
        val releaseFirst = CountDownLatch(1)
        bridge.focusHandler = { point ->
            if (point == CameraFocusPoint(100, 100)) {
                firstStarted.countDown()
                check(releaseFirst.await(5, TimeUnit.SECONDS))
            }
            SwiftCore.FOCUS_COMMAND_ACCEPTED
        }

        val first = async(Dispatchers.Default) { session.changeAfArea(CameraFocusPoint(100, 100)) }
        try {
            assertTrue(firstStarted.await(5, TimeUnit.SECONDS))
            val stale = async { session.changeAfArea(CameraFocusPoint(200, 200)) }
            runCurrent()
            val latest = async { session.changeAfArea(CameraFocusPoint(300, 300)) }
            runCurrent()

            releaseFirst.countDown()
            assertTrue(first.await())
            assertFalse(stale.await())
            assertTrue(latest.await())
        } finally {
            releaseFirst.countDown()
        }

        assertEquals(
            listOf(CameraFocusPoint(100, 100), CameraFocusPoint(300, 300)),
            bridge.focusRequests,
        )
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
    fun `PTP-IP event channel end keeps the command session connected`() = runTest {
        val bridge = FakeBridge()
        val phases = mutableListOf<Pair<String, String>>()
        val session =
            SwiftCoreCameraSession(
                "192.168.1.1",
                { phase, detail -> phases += phase to detail },
                bridge,
            )
        val connecting = async { session.connect() }
        runCurrent()
        bridge.listeners.single().onConnected("ZR", "NIKON ZR", "6001234")
        connecting.await()

        bridge.eventListeners.single().onEnded("The camera closed the connection.")

        assertEquals(
            CameraSessionState.Connected(CameraIdentity("ZR", "NIKON ZR", "6001234")),
            session.state.value,
        )
        assertEquals(listOf("eventChannelEnded" to "The camera closed the connection."), phases)

        session.setRecording(true)
        assertEquals(listOf(true), bridge.recordingRequests)

        session.disconnect()
        assertEquals(1, bridge.disconnects)
    }

    @Test
    fun `USB event channel end tears down its native owner`() = runTest {
        val bridge = FakeBridge()
        val transport = FakeUsbTransport()
        val session =
            SwiftCoreCameraSession(
                host = "usb:5d6f4d746ecf9da40a1b0ce273d3d8d3",
                phaseLogger = { _, _ -> },
                core = bridge,
                propertyRefreshScope = this,
                propertyRefreshDispatcher = StandardTestDispatcher(testScheduler),
                automaticallyRefreshProperties = false,
                usbTransport = transport,
                cameraNameHint = "Nikon USB camera",
            )
        val connecting = async { session.connect() }
        runCurrent()
        bridge.listeners.single().onConnected("ZR", "NIKON ZR", "6001234")
        connecting.await()

        bridge.eventListeners.single().onEnded("The camera closed the USB event endpoint.")

        assertEquals(CameraSessionState.Connecting, session.state.value)
        runCurrent()
        assertEquals(CameraSessionState.Disconnected, session.state.value)
        assertEquals(1, bridge.disconnects)
        assertTrue(transport.isClosed())
    }

    @Test
    fun `USB event teardown waits for an in-flight camera command`() = runTest {
        val bridge = FakeBridge()
        val transport = FakeUsbTransport()
        val session =
            SwiftCoreCameraSession(
                host = "usb:5d6f4d746ecf9da40a1b0ce273d3d8d3",
                phaseLogger = { _, _ -> },
                core = bridge,
                propertyRefreshScope = this,
                propertyRefreshDispatcher = StandardTestDispatcher(testScheduler),
                automaticallyRefreshProperties = false,
                usbTransport = transport,
                cameraNameHint = "Nikon USB camera",
            )
        val connecting = async { session.connect() }
        runCurrent()
        bridge.listeners.single().onConnected("ZR", "NIKON ZR", "6001234")
        connecting.await()

        val commandStarted = CountDownLatch(1)
        val releaseCommand = CountDownLatch(1)
        bridge.controlHandler = { _, _ ->
            commandStarted.countDown()
            check(releaseCommand.await(5, TimeUnit.SECONDS))
            SwiftCore.CONTROL_COMMAND_ACCEPTED
        }
        val command = async(Dispatchers.Default) { session.applyControl(CameraControl.ISO, "800") }
        try {
            assertTrue(commandStarted.await(5, TimeUnit.SECONDS))
            bridge.eventListeners.single().onEnded("The camera closed the USB event endpoint.")
            runCurrent()

            assertEquals(CameraSessionState.Connecting, session.state.value)
            assertEquals(0, bridge.disconnects)

            releaseCommand.countDown()
            command.await()
            runCurrent()
        } finally {
            releaseCommand.countDown()
        }

        assertEquals(CameraSessionState.Disconnected, session.state.value)
        assertEquals(1, bridge.disconnects)
        assertTrue(transport.isClosed())
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
        assertEquals("6K · 25p", session.cameraProperties.value.resolutionFrameRate)
        assertEquals("R3D NE", session.cameraProperties.value.codecSelection)
        assertEquals("Neutral", session.cameraProperties.value.whiteBalanceTint)
        assertEquals(
            listOf("90°", "180°", "360°"),
            session.cameraProperties.value.controlCapabilities.shutterValues,
        )
        assertEquals(
            listOf("6K · 25p", "4K · 60p"),
            session.cameraProperties.value.controlCapabilities.resolutionFrameRates,
        )
        assertEquals(
            listOf("1600", "3200"),
            session.cameraProperties.value.controlCapabilities.isoValues,
        )
        assertEquals(
            listOf("f/2.8", "f/4"),
            session.cameraProperties.value.controlCapabilities.irisValues,
        )
        assertEquals(
            listOf("Sunny", "5600K"),
            session.cameraProperties.value.controlCapabilities.whiteBalanceValues,
        )
        assertEquals(
            listOf("AF-C", "MF"),
            session.cameraProperties.value.controlCapabilities.focusModes,
        )
        assertEquals(
            listOf("Wide-L", "Subject"),
            session.cameraProperties.value.controlCapabilities.focusAreas,
        )
        assertEquals(
            listOf("People", "Animal"),
            session.cameraProperties.value.controlCapabilities.focusSubjects,
        )
        assertEquals(
            listOf("Auto", "12"),
            session.cameraProperties.value.controlCapabilities.audioSensitivities,
        )
        assertEquals(
            listOf("Line", "Microphone"),
            session.cameraProperties.value.controlCapabilities.audioInputs,
        )
        assertEquals(
            listOf("OFF", "ON"),
            session.cameraProperties.value.controlCapabilities.windFilters,
        )
        assertEquals(
            listOf("OFF", "ON"),
            session.cameraProperties.value.controlCapabilities.attenuators,
        )
        assertEquals(
            listOf("OFF", "ON"),
            session.cameraProperties.value.controlCapabilities.audio32BitFloat,
        )
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
    fun `EV fast polling interleaves needle reads between round-robin ticks`() = runTest {
        val bridge = FakeBridge()
        val session =
            SwiftCoreCameraSession(
                host = "192.168.1.1",
                phaseLogger = { _, _ -> },
                core = bridge,
                propertyRefreshScope = this,
                propertyRefreshDispatcher = StandardTestDispatcher(testScheduler),
                propertyPollIntervalMillis = 3_000,
                evIndicatorPollIntervalMillis = 750,
            )
        val connecting = async { session.connect() }
        runCurrent()
        bridge.listeners.single().onConnected("ZR", "NIKON ZR", "6001234")
        connecting.await()
        runCurrent()
        bridge.clearRefreshRequests()

        // Off: one regular tick per 3 s and no EV reads.
        advanceTimeBy(3_100)
        runCurrent()
        assertEquals(
            listOf(SwiftCore.PROPERTY_REFRESH_NEXT),
            bridge.refreshRequests().map { it.request },
        )

        // On: the flip engages after the in-flight regular delay, then the
        // needle reads every 750 ms with the round-robin kept at its stride.
        session.setExposureIndicatorFastPolling(true)
        advanceTimeBy(3_100)
        runCurrent()
        bridge.clearRefreshRequests()
        advanceTimeBy(3_100)
        runCurrent()
        assertEquals(
            listOf(
                SwiftCore.PROPERTY_REFRESH_EV_INDICATOR,
                SwiftCore.PROPERTY_REFRESH_EV_INDICATOR,
                SwiftCore.PROPERTY_REFRESH_EV_INDICATOR,
                SwiftCore.PROPERTY_REFRESH_EV_INDICATOR,
                SwiftCore.PROPERTY_REFRESH_NEXT,
            ),
            bridge.refreshRequests().map { it.request },
        )

        // Off again: after the residual fast tick flushes, plain cadence only.
        session.setExposureIndicatorFastPolling(false)
        advanceTimeBy(800)
        runCurrent()
        bridge.clearRefreshRequests()
        advanceTimeBy(6_200)
        runCurrent()
        assertEquals(
            listOf(SwiftCore.PROPERTY_REFRESH_NEXT, SwiftCore.PROPERTY_REFRESH_NEXT),
            bridge.refreshRequests().map { it.request },
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
        val idleObserved = CountDownLatch(1)
        val observeIdle =
            async(Dispatchers.Default) {
                session.propertyRefreshStatus.first { it == CameraPropertyRefreshStatus.Idle }
                idleObserved.countDown()
            }
        try {
            assertTrue(nativeReadStarted.await(5, TimeUnit.SECONDS))
            assertEquals(CameraPropertyRefreshStatus.Refreshing, session.propertyRefreshStatus.value)

            val disconnect = async(Dispatchers.Default) { session.disconnect() }
            // `runTest` advances virtual time immediately when a StateFlow await
            // suspends. The teardown runs on the real default dispatcher, so a
            // virtual `withTimeout` can race it on a busy CI runner. The latch
            // observes the same public state transition against wall-clock time.
            assertTrue(idleObserved.await(5, TimeUnit.SECONDS))
            releaseNativeRead.countDown()
            refresh.await()
            disconnect.await()
        } finally {
            releaseNativeRead.countDown()
            observeIdle.cancelAndJoin()
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
        data class PtpIpConnect(
            val host: String,
            val connectionOwner: Long,
            val connectionStrategy: PtpIpConnectionStrategy,
            val initiatorGuid: ByteArray,
        )

        data class UsbConnect(
            val transport: UsbPtpTransport,
            val host: String,
            val cameraNameHint: String,
            val connectionOwner: Long,
        )

        data class PropertyRefreshRequest(
            val request: Int,
            val recording: Boolean,
            val propertyCode: Long,
        )

        @Volatile var available: Boolean = true
        override val isAvailable: Boolean
            get() = available
        val listeners = mutableListOf<SwiftCore.SessionListener>()
        val hostConnects = mutableListOf<String>()
        val ptpIpConnects = mutableListOf<PtpIpConnect>()
        val usbConnects = mutableListOf<UsbConnect>()
        val eventListeners = mutableListOf<SwiftCore.SessionEventListener>()
        val recordingRequests = mutableListOf<Boolean>()
        val controlRequests = mutableListOf<Pair<CameraControl, String>>()
        val focusRequests = mutableListOf<CameraFocusPoint>()
        var focusResetRequests = 0
        val disconnectOwners = mutableListOf<Long>()
        private val refreshLock = Any()
        private val propertyRefreshRequests = mutableListOf<PropertyRefreshRequest>()
        private var activeRefreshes = 0
        private var maximumRefreshes = 0
        @Volatile var propertyRefreshPayload: String? = propertyPayload()
        @Volatile var propertyRefreshHandler: ((PropertyRefreshRequest) -> String?)? = null
        @Volatile var disconnectHandler: ((Long) -> Unit)? = null
        var controlResult = SwiftCore.CONTROL_COMMAND_ACCEPTED
        var controlHandler: ((CameraControl, String) -> Int)? = null
        var focusResult = SwiftCore.FOCUS_COMMAND_ACCEPTED
        var focusResetResult = SwiftCore.FOCUS_COMMAND_ACCEPTED
        var focusHandler: ((CameraFocusPoint) -> Int)? = null
        var roundTripMilliseconds: Double? = null
        var disconnects = 0

        override fun connect(
            host: String,
            connectionOwner: Long,
            listener: SwiftCore.SessionListener,
        ) {
            hostConnects += host
            listeners += listener
        }

        override fun connect(
            host: String,
            connectionOwner: Long,
            connectionStrategy: PtpIpConnectionStrategy,
            initiatorGuid: ByteArray,
            listener: SwiftCore.SessionListener,
        ) {
            hostConnects += host
            ptpIpConnects +=
                PtpIpConnect(
                    host = host,
                    connectionOwner = connectionOwner,
                    connectionStrategy = connectionStrategy,
                    initiatorGuid = initiatorGuid.copyOf(),
                )
            listeners += listener
        }

        override fun connectUsb(
            transport: UsbPtpTransport,
            host: String,
            cameraNameHint: String,
            connectionOwner: Long,
            listener: SwiftCore.SessionListener,
        ) {
            usbConnects += UsbConnect(transport, host, cameraNameHint, connectionOwner)
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

        override fun latestRoundTripMilliseconds(): Double? = roundTripMilliseconds

        override fun applyControl(control: CameraControl, label: String): Int {
            controlRequests += control to label
            return controlHandler?.invoke(control, label) ?: controlResult
        }

        override fun changeAfArea(point: CameraFocusPoint): Int {
            synchronized(focusRequests) { focusRequests += point }
            return focusHandler?.invoke(point) ?: focusResult
        }

        override fun resetFocusPoint(): Int {
            focusResetRequests += 1
            return focusResetResult
        }

        override fun disconnect(connectionOwner: Long) {
            disconnects++
            disconnectOwners += connectionOwner
            disconnectHandler?.invoke(connectionOwner)
            usbConnects.lastOrNull { it.connectionOwner == connectionOwner }?.transport?.close()
        }
    }

    private class FakeUsbTransport : UsbPtpTransport {
        private var closed = false

        override fun writeBulk(bytes: ByteArray, timeoutMillis: Int): Int =
            if (closed) -1 else bytes.size

        override fun readBulk(maxBytes: Int, timeoutMillis: Int): ByteArray? = null

        override fun readEvent(maxBytes: Int, timeoutMillis: Int): ByteArray? = null

        override fun isClosed(): Boolean = closed

        override fun close() {
            closed = true
        }
    }

    private fun usbSession(
        bridge: FakeBridge,
        transport: FakeUsbTransport,
    ): SwiftCoreCameraSession =
        SwiftCoreCameraSession(
            host = "usb:5d6f4d746ecf9da40a1b0ce273d3d8d3",
            phaseLogger = { _, _ -> },
            core = bridge,
            usbTransport = transport,
            cameraNameHint = "Nikon USB camera",
        )

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

    private suspend fun TestScope.connectedSession(bridge: FakeBridge): SwiftCoreCameraSession {
        val session = SwiftCoreCameraSession("192.168.1.1", { _, _ -> }, bridge)
        val connecting = async { session.connect() }
        runCurrent()
        bridge.listeners.single().onConnected("ZR", "NIKON ZR", "6001234")
        connecting.await()
        return session
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
                "resolutionFrameRate\t6K · 25p",
                "codecSelection\tR3D NE",
                "whiteBalanceTint\tNeutral",
                "options.iso\t1600\u001F3200",
                "options.shutter\t90°\u001F180°\u001F360°",
                "options.iris\tf/2.8\u001Ff/4",
                "options.whiteBalance\tSunny\u001F5600K",
                "options.focusMode\tAF-C\u001FMF",
                "options.focusArea\tWide-L\u001FSubject",
                "options.focusSubject\tPeople\u001FAnimal",
                "options.audioSensitivity\tAuto\u001F12",
                "options.audioInput\tLine\u001FMicrophone",
                "options.windFilter\tOFF\u001FON",
                "options.attenuator\tOFF\u001FON",
                "options.audio32BitFloat\tOFF\u001FON",
                "options.resolutionFrameRate\t6K · 25p\u001F4K · 60p",
                "options.codec\tR3D NE\u001FH.265",
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

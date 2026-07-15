package com.opencapture.openzcine.bridge

import com.opencapture.openzcine.core.CameraIdentity
import com.opencapture.openzcine.core.CameraPropertyRefreshFailure
import com.opencapture.openzcine.core.CameraPropertyRefreshStatus
import com.opencapture.openzcine.core.CameraSessionState
import com.opencapture.openzcine.core.LiveFrame
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest

@OptIn(ExperimentalCoroutinesApi::class)
class AndroidLinkQualityTest {
    @Test
    fun `preview request parser rejects malformed core payloads`() {
        assertEquals(
            SwiftLiveViewRequest(1, 3, 33_000_000L),
            parseLiveViewRequest("1\t3\t33000000"),
        )
        assertNull(parseLiveViewRequest("1\t3"))
        assertNull(parseLiveViewRequest("1\t4\t33000000"))
        assertNull(parseLiveViewRequest("1\t3\t0"))
    }

    @Test
    fun `controller stores dormant policy then restarts only an active preview pump`() = runTest {
        val nominal = SwiftLiveViewRequest(1, 1, 33_000_000L)
        val serious = SwiftLiveViewRequest(2, 3, 49_500_000L)
        val configured = mutableListOf<SwiftLiveViewRequest>()
        var stops = 0
        lateinit var listener: SwiftCore.LiveFrameListener
        val source =
            SwiftCoreLiveFrameSource(
                available = { true },
                start = { listener = it },
                stop = {
                    stops++
                    listener.onEnded()
                },
                configurePreview = {
                    configured += it
                    true
                },
                sharingScope = backgroundScope,
                restartDelayMillis = 0L,
            )
        val controller =
            AndroidLiveViewController(
                source = source,
                policy = SwiftLiveViewPolicyBridge { input ->
                    if (input.thermalTier == 2) serious else nominal
                },
            )
        val normalInput =
            SwiftLiveViewPolicyInput(
                streamPreset = 0,
                qualityBias = 0,
                thermalTier = 0,
                isRecording = false,
                cameraOverheating = false,
            )

        controller.apply(normalInput)
        assertEquals(nominal, source.previewRequest)
        assertEquals(0, stops)

        val collector = launch { source.frames.collect() }
        runCurrent()
        assertEquals(listOf(nominal), configured)

        controller.apply(normalInput.copy(thermalTier = 2))
        runCurrent()
        assertEquals(1, stops)
        assertEquals(listOf(nominal, serious), configured)

        collector.cancelAndJoin()
    }

    @Test
    fun `health monitor forwards observed frames and transport failures without RTT fabrication`() {
        val inputs = mutableListOf<LinkHealthInput>()
        var now = 1_000_000_000L
        val monitor =
            AndroidLinkHealthMonitor(
                bridge = LinkHealthBridge { input ->
                    inputs += input
                    LinkHealthPresentation(score = 73, signalBars = 3, detail = "Bridge result")
                },
                clockNanos = { now },
            )
        val connected =
            CameraSessionState.Connected(
                CameraIdentity(name = "Nikon ZR", model = "NIKON ZR", serialNumber = "TEST"),
            )

        monitor.updateSession(
            state = connected,
            streamRequested = true,
            transportIsUsb = false,
            targetFramesPerSecond = 30.0,
            isDemoSession = false,
        )
        monitor.recordFrame(LiveFrame(now, byteArrayOf(1)))
        now += 33_000_000L
        monitor.recordFrame(LiveFrame(now, byteArrayOf(2)))

        val streaming = assertNotNull(inputs.lastOrNull())
        assertEquals(AndroidLinkPhase.STREAMING, streaming.phase)
        assertNull(streaming.roundTripMilliseconds)
        assertTrue(assertNotNull(streaming.liveViewFramesPerSecond) > 29.0)
        assertEquals(30.0, streaming.targetLiveViewFramesPerSecond)
        assertEquals(3, monitor.presentation.signalBars)

        monitor.reportPropertyRefresh(
            CameraPropertyRefreshStatus.Degraded(CameraPropertyRefreshFailure.TRANSPORT_FAILED),
        )
        assertEquals(1, assertNotNull(inputs.lastOrNull()).recentCommandFailures)

        monitor.updateSession(
            state = CameraSessionState.Disconnected,
            streamRequested = false,
            transportIsUsb = false,
            targetFramesPerSecond = 30.0,
            isDemoSession = false,
        )
        val disconnected = assertNotNull(inputs.lastOrNull())
        assertEquals(AndroidLinkPhase.DISCONNECTED, disconnected.phase)
        assertTrue(disconnected.resetSignalBars)
    }

    @Test
    fun `health monitor enters recovery when a requested stream never delivers its first frame`() {
        val inputs = mutableListOf<LinkHealthInput>()
        var now = 5_000_000_000L
        val monitor =
            AndroidLinkHealthMonitor(
                bridge = LinkHealthBridge { input ->
                    inputs += input
                    LinkHealthPresentation(score = 0, signalBars = 0, detail = "Observed")
                },
                clockNanos = { now },
            )
        monitor.updateSession(
            state =
                CameraSessionState.Connected(
                    CameraIdentity(name = "Nikon ZR", model = "NIKON ZR", serialNumber = "TEST"),
                ),
            streamRequested = true,
            transportIsUsb = false,
            targetFramesPerSecond = 30.0,
            isDemoSession = false,
        )
        val initial = assertNotNull(inputs.lastOrNull())
        assertEquals(AndroidLinkPhase.STREAMING, initial.phase)
        assertEquals(0.0, initial.secondsSinceLastGoodFrame)

        now += 1_600_000_000L
        monitor.refresh()
        val stalled = assertNotNull(inputs.lastOrNull())
        assertEquals(AndroidLinkPhase.RECOVERING, stalled.phase)
        assertTrue(assertNotNull(stalled.secondsSinceLastGoodFrame) >= 1.5)
        assertTrue(stalled.isRecoveringStream)
    }

    @Test
    fun `explicit demo sources stay labelled as a demo health phase`() {
        var observed: LinkHealthInput? = null
        val monitor =
            AndroidLinkHealthMonitor(
                bridge = LinkHealthBridge { input ->
                    observed = input
                    LinkHealthPresentation(score = 85, signalBars = 4, detail = "Demo session")
                },
                clockNanos = { 0L },
            )

        monitor.updateSession(
            state =
                CameraSessionState.Connected(
                    CameraIdentity(name = "Demo Feed", model = "Fixture", serialNumber = "DEMO"),
                ),
            streamRequested = true,
            transportIsUsb = false,
            targetFramesPerSecond = 30.0,
            isDemoSession = true,
        )

        val input = assertNotNull(observed)
        assertEquals(AndroidLinkPhase.DEMO, input.phase)
        assertNull(input.roundTripMilliseconds)
        assertNull(input.liveViewFramesPerSecond)
    }
}

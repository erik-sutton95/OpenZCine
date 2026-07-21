package com.opencapture.openzcine

import com.opencapture.openzcine.bridge.SwiftCoreLiveFrameSource
import com.opencapture.openzcine.core.CameraIdentity
import com.opencapture.openzcine.core.CameraRecordingState
import com.opencapture.openzcine.core.CameraSessionState
import com.opencapture.openzcine.core.LiveFrameTimecode
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest

@OptIn(ExperimentalCoroutinesApi::class)
class MonitorPreviewPolicyTest {
    @Test
    fun `command mode removes feed audio and health consumers so the pump ends`() = runTest {
        var starts = 0
        var stops = 0
        val source =
            SwiftCoreLiveFrameSource(
                available = { true },
                start = { starts++ },
                stop = { stops++ },
                configurePreview = { true },
                sharingScope = backgroundScope,
            )
        val liveMonitorSource = checkNotNull(monitorPreviewFrameSource(source, isCommandMode = false))
        val feed = launch { liveMonitorSource.frames.collect() }
        val audio = launch { liveMonitorSource.frames.collect() }
        val health =
            launch {
                source.currentStreamFrames.collect()
            }
        runCurrent()
        advanceUntilIdle()

        assertEquals(1, starts)
        assertNull(monitorPreviewFrameSource(source, isCommandMode = true))

        feed.cancelAndJoin()
        audio.cancelAndJoin()
        health.cancelAndJoin()
        runCurrent()
        advanceUntilIdle()

        assertEquals(1, stops)
    }

    @Test
    fun `command transition retains camera timecode without retaining the preview source`() = runTest {
        val cameraA = CameraIdentity("Nikon ZR A", "ZR", "ZR-A")
        val cameraB = CameraIdentity("Nikon ZR B", "ZR", "ZR-B")
        val connectedA = CameraSessionState.Connected(cameraA)
        val timecode = LiveFrameTimecode(true, 1, 2, 3, 4)
        val retention = MonitorTimecodeRetention(monitorTimecodeOwner(connectedA))
        retention.accept(timecode)
        val source =
            SwiftCoreLiveFrameSource(
                available = { true },
                start = {},
                stop = {},
                configurePreview = { true },
                sharingScope = backgroundScope,
            )

        assertNull(monitorPreviewFrameSource(source, isCommandMode = true))
        assertEquals(timecode, retention.timecodeFor(connectedA))
        // Disabled / missing headers must not wipe the last good camera TC
        // (Nikon briefly reports on=false around record transitions).
        retention.accept(LiveFrameTimecode(false, 0, 0, 0, 0))
        assertEquals(timecode, retention.timecodeFor(connectedA))
        retention.accept(null)
        assertEquals(timecode, retention.timecodeFor(connectedA))
        // Second boundary must publish immediately (frame-only ticks are rate-limited).
        val advanced = LiveFrameTimecode(true, 1, 2, 4, 0)
        retention.accept(advanced)
        assertEquals(advanced, retention.timecodeFor(connectedA))
        assertNull(retention.timecodeFor(CameraSessionState.Disconnected))
        assertNull(retention.timecodeFor(CameraSessionState.Connected(cameraB)))
        assertNull(
            MonitorTimecodeRetention(cameraB)
                .timecodeFor(CameraSessionState.Connected(cameraB)),
        )
    }

    @Test
    fun `rejected StartMovieRec never changes the preview recording policy input`() {
        val states =
            listOf(
                CameraRecordingState.STANDBY,
                CameraRecordingState.STARTING,
                CameraRecordingState.STANDBY,
            )

        val previewInputs = states.map(::previewPolicyRecordingActive)

        assertEquals(listOf(false, false, false), previewInputs)
        assertEquals(1, previewInputs.distinct().size)
    }

    @Test
    fun `in flight stop keeps recording preview policy until native stop succeeds`() {
        val states =
            listOf(
                CameraRecordingState.RECORDING,
                CameraRecordingState.STOPPING,
                CameraRecordingState.STANDBY,
            )

        val previewInputs = states.map(::previewPolicyRecordingActive)

        assertEquals(listOf(true, true, false), previewInputs)
        assertFalse(previewInputs[2])
    }
}

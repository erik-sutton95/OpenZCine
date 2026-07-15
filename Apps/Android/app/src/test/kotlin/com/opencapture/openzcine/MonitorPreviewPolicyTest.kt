package com.opencapture.openzcine

import com.opencapture.openzcine.bridge.SwiftCoreLiveFrameSource
import com.opencapture.openzcine.core.CameraRecordingState
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

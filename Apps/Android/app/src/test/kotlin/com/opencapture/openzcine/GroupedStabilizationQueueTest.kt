package com.opencapture.openzcine

import com.opencapture.opencine.cameracontrols.MonitorOperatorLiveIdentity
import com.opencapture.opencine.nikon.*
import kotlin.test.*
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest

/** SIMULATED actual grouped producer, app queue and admitted session boundary; no camera. */
@OptIn(ExperimentalCoroutinesApi::class)
class GroupedStabilizationQueueTest {
    private fun request(control: CameraControl) = CommandControlRequest(
        title = "SIMULATED", control = control, currentValue = "OFF",
        options = if (control == CameraControl.VIBRATION_REDUCTION) listOf("OFF", "ON", "SPORT") else listOf("OFF", "ON"),
    )

    @Test fun revokedQueuedGroupedWriteDoesNotSendAndFreshSelectionStillWorks() = runTest {
        val camera = NativeBoundary()
        val enabled = AtomicBoolean(true)
        val producer = NikonStabilizationCommands()
        val source = MonitorOperatorLiveIdentity(null, null, Any())
        producer.publish(camera, source, true, enabled::get)
        val refused = mutableListOf<Exception>()
        val queue = nikonNativeControlWrites(backgroundScope, camera, { _, _ -> false }, { _, _ -> false }, { _, error -> refused += error })
        val hold = CompletableDeferred<Unit>()
        camera.completion = hold
        queue.submit(CameraControl.ISO, NikonNativeControlSelection(request(CameraControl.ISO), "800"))
        runCurrent()
        queue.submit(CameraControl.VIBRATION_REDUCTION, assertNotNull(producer.selection(request(CameraControl.VIBRATION_REDUCTION), "SPORT")))
        enabled.set(false)
        // Regranting the same source must not resurrect the already queued receipt.
        producer.publish(camera, source, true) { true }
        hold.complete(Unit)
        runCurrent()
        assertEquals(listOf(CameraControl.ISO to "800"), camera.sent)
        assertEquals(listOf<Exception>(CameraControlException.CommandRejected), refused)
        assertNull(queue.pending)
        assertFalse(queue.isWaiting(CameraControl.VIBRATION_REDUCTION))
        queue.submit(CameraControl.ELECTRONIC_VR, assertNotNull(producer.selection(request(CameraControl.ELECTRONIC_VR), "ON")))
        runCurrent()
        assertEquals(listOf(CameraControl.ISO to "800", CameraControl.ELECTRONIC_VR to "ON"), camera.sent)
        assertEquals("OFF", camera.cameraProperties.value.vibrationReduction)
        assertEquals("ON", camera.cameraProperties.value.electronicVr)
        assertNull(queue.pending)
        producer.close()
    }

    @Test fun nativeWaiterRefusesButEnteredWriteKeepsCompletionAndReadback() = runTest {
        for (entered in listOf(false, true)) {
            val camera = NativeBoundary()
            val enabled = AtomicBoolean(true)
            val producer = NikonStabilizationCommands()
            producer.publish(camera, MonitorOperatorLiveIdentity(null, null, Any()), true, enabled::get)
            val gate = CompletableDeferred<Unit>()
            if (entered) camera.completion = gate else camera.beforeEntry = gate
            val refused = mutableListOf<Exception>()
            val queue = nikonNativeControlWrites(backgroundScope, camera, { _, _ -> false }, { _, _ -> false }, { _, e -> refused += e })
            queue.submit(CameraControl.VIBRATION_REDUCTION, assertNotNull(producer.selection(request(CameraControl.VIBRATION_REDUCTION), "SPORT")))
            runCurrent()
            assertEquals(if (entered) 1 else 0, camera.sent.size)
            enabled.set(false)
            gate.complete(Unit)
            runCurrent()
            assertEquals(if (entered) listOf(CameraControl.VIBRATION_REDUCTION to "SPORT") else emptyList(), camera.sent)
            assertEquals(if (entered) "SPORT" else "OFF", camera.cameraProperties.value.vibrationReduction)
            assertEquals(if (entered) 1 else 0, camera.refreshes)
            assertEquals(if (entered) emptyList() else listOf<Exception>(CameraControlException.CommandRejected), refused)
            assertNull(queue.pending)
            // No ambient receipt may contaminate a legacy direct payload.
            queue.submit(CameraControl.ELECTRONIC_VR, NikonNativeControlSelection(request(CameraControl.ELECTRONIC_VR), "ON"))
            runCurrent()
            assertEquals(CameraControl.ELECTRONIC_VR to "ON", camera.sent.last())
            producer.close()
        }
    }

    @Test fun sourceReplacementRetiresOldQueueAndCannotBorrowAnotherNativeOwner() = runTest {
        val first = NativeBoundary()
        val next = NativeBoundary()
        val producer = NikonStabilizationCommands()
        producer.publish(first, MonitorOperatorLiveIdentity(null, null, Any()), true) { true }
        val captured = assertNotNull(producer.selection(request(CameraControl.ELECTRONIC_VR), "ON"))
        producer.publish(next, MonitorOperatorLiveIdentity(null, null, Any()), true) { true }
        val old = async { runCatching { captured.apply(first) }.exceptionOrNull() }
        val borrowed = async { runCatching { captured.apply(next) }.exceptionOrNull() }
        runCurrent()
        assertEquals(CameraControlException.CommandRejected, old.await())
        assertEquals(CameraControlException.CommandRejected, borrowed.await())
        assertTrue(first.sent.isEmpty() && next.sent.isEmpty())
        assertNotNull(producer.selection(request(CameraControl.ELECTRONIC_VR), "ON")).apply(next)
        assertEquals(listOf(CameraControl.ELECTRONIC_VR to "ON"), next.sent)
        producer.close()
    }

    @Test fun coalescingKeepsOnlyLatestChosenRowAndOrdinaryPublicationKeepsReceipt() = runTest {
        val camera = NativeBoundary()
        val producer = NikonStabilizationCommands()
        val source = MonitorOperatorLiveIdentity(null, null, Any())
        producer.publish(camera, source, true) { true }
        val refused = mutableListOf<Exception>()
        val queue = nikonNativeControlWrites(backgroundScope, camera, { _, _ -> false }, { _, _ -> false }, { _, e -> refused += e })
        val hold = CompletableDeferred<Unit>()
        camera.completion = hold
        queue.submit(CameraControl.ISO, NikonNativeControlSelection(request(CameraControl.ISO), "800"))
        runCurrent()
        queue.submit(CameraControl.VIBRATION_REDUCTION, assertNotNull(producer.selection(request(CameraControl.VIBRATION_REDUCTION), "ON")))
        queue.submit(CameraControl.ELECTRONIC_VR, assertNotNull(producer.selection(request(CameraControl.ELECTRONIC_VR), "ON")))
        queue.submit(CameraControl.VIBRATION_REDUCTION, assertNotNull(producer.selection(request(CameraControl.VIBRATION_REDUCTION), "SPORT")))
        producer.publish(camera, source, true) { true }
        hold.complete(Unit)
        runCurrent()
        assertEquals(listOf(CameraControl.ISO to "800", CameraControl.VIBRATION_REDUCTION to "SPORT", CameraControl.ELECTRONIC_VR to "ON"), camera.sent)
        assertEquals(3, camera.refreshes)
        assertTrue(refused.isEmpty())
        assertNull(queue.pending)
        producer.close()
    }

    private class NativeBoundary : CameraSession {
        override val state = MutableStateFlow<CameraSessionState>(CameraSessionState.Connected(CameraIdentity("SIMULATED", "SIMULATED", "SIMULATED")))
        override val recordingState = MutableStateFlow(CameraRecordingState.STANDBY)
        override val cameraProperties = MutableStateFlow(CameraPropertySnapshot(vibrationReduction = "OFF", electronicVr = "OFF"))
        val sent = mutableListOf<Pair<CameraControl, String>>()
        var beforeEntry: CompletableDeferred<Unit>? = null
        var completion: CompletableDeferred<Unit>? = null
        var refreshes = 0
        override suspend fun connect() = Unit
        override suspend fun disconnect() = Unit
        override suspend fun setRecording(recording: Boolean) = Unit
        override suspend fun refreshProperties() { refreshes++ }
        override suspend fun applyControl(control: CameraControl, label: String, admission: CameraCommandAdmission) {
            beforeEntry?.also { beforeEntry = null }?.await()
            if (!admission.admits(this)) throw CameraControlException.CommandRejected
            send(control, label)
        }
        override suspend fun applyControl(control: CameraControl, label: String) {
            beforeEntry?.also { beforeEntry = null }?.await()
            send(control, label)
        }
        private suspend fun send(control: CameraControl, label: String) {
            sent += control to label
            completion?.also { completion = null }?.await()
            cameraProperties.value = when (control) {
                CameraControl.VIBRATION_REDUCTION -> cameraProperties.value.copy(vibrationReduction = label)
                CameraControl.ELECTRONIC_VR -> cameraProperties.value.copy(electronicVr = label)
                else -> cameraProperties.value
            }
        }
    }
}

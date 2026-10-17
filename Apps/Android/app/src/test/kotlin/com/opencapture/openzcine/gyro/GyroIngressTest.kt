package com.opencapture.openzcine.gyro

import org.junit.Assert.assertEquals
import org.junit.Test

class GyroIngressTest {
    @Test fun `delayed samples do not overtake queued stop interruption or next start`() {
        val samples = List(451) { AndroidGyroSample(9.0 + it / 100.0, 1.0, 2.0, 3.0) }
        val events = listOf(
            RecordingObservation(true, 10.0, 0.0),
            RecordingObservation(false, 11.0, 0.0),
            RecordingObservation(false, 11.1, 0.0, interrupted = true),
            RecordingObservation(true, 12.0, 0.0),
        )
        val steps = mutableListOf<String>()
        replayGyroIngress(samples, events,
            ingest = { steps += "samples ${it.size}" },
            observe = { steps += "${it.recording} ${it.timestamp} ${it.interrupted}" })
        assertEquals(listOf("samples 101", "true 10.0 false",
            "samples 100", "false 11.0 false", "samples 10", "false 11.1 true",
            "samples 90", "true 12.0 false", "samples 150"), steps)
    }

    @Test fun `queued starts retain their mount when selection changes before replay`() {
        var selected = "rearDown"
        val first = RecordingObservation(true, 10.0, 0.0, mountPreset = selected)
        selected = "rearLeft"
        val stop = RecordingObservation(false, 11.0, 0.0, mountPreset = selected)
        val next = RecordingObservation(true, 12.0, 0.0, mountPreset = selected)
        selected = "frontUp"
        val received = mutableListOf<RecordingObservation>()
        replayGyroIngress(emptyList(), listOf(next, first, stop), ingest = {}, observe = received::add)
        assertEquals("frontUp", selected)
        assertEquals(listOf("rearDown", "rearLeft", "rearLeft"), received.map { it.mountPreset })
        assertEquals(listOf(10.0, 11.0, 12.0), received.map { it.timestamp })
    }

    @Test fun `queued takes freeze the calibration and manual preset as one choice`() {
        var selected = GyroMountSelection("rearDown", "{\"verified\":1}")
        val first = RecordingObservation(true, 10.0, 0.0, mountPreset = selected.preset,
            calibrationJSON = selected.calibrationJSON)
        selected = GyroMountSelection("frontUp")
        val next = RecordingObservation(true, 12.0, 0.0, mountPreset = selected.preset,
            calibrationJSON = selected.calibrationJSON)
        val received = mutableListOf<RecordingObservation>()
        replayGyroIngress(emptyList(), listOf(next, first), ingest = {}, observe = received::add)
        assertEquals(listOf("rearDown", "frontUp"), received.map { it.mountPreset })
        assertEquals(listOf("{\"verified\":1}", ""), received.map { it.calibrationJSON })
    }
}

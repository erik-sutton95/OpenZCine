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
}

package com.opencapture.openzcine.gyro

/** A camera observation stamped before it enters the serial file writer. */
internal data class RecordingObservation(val recording: Boolean?, val timestamp: Double,
    val date: Double, val interrupted: Boolean = false)

/** Interleaves one bounded platform batch without applying any take policy. */
internal fun replayGyroIngress(samples: List<AndroidGyroSample>, observations: List<RecordingObservation>,
    ingest: (List<AndroidGyroSample>) -> Unit, observe: (RecordingObservation) -> Unit) {
    var consumed = 0
    for (observation in observations.sortedBy { it.timestamp }) {
        var end = consumed
        while (end < samples.size && samples[end].timestamp <= observation.timestamp) end += 1
        if (end > consumed) ingest(samples.subList(consumed, end))
        consumed = end
        observe(observation)
    }
    if (consumed < samples.size) ingest(samples.subList(consumed, samples.size))
}

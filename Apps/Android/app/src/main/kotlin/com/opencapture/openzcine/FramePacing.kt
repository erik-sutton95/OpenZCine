package com.opencapture.openzcine

import com.opencapture.opencine.nikon.LiveFrame
import com.opencapture.opencine.runtime.MonitorFramePacingStats
import com.opencapture.opencine.runtime.monitorPumpFramesWithSourceFrame
import kotlinx.coroutines.flow.Flow

typealias FramePacingStats = MonitorFramePacingStats

suspend fun <T : Any> pumpFramesWithSourceFrame(frames: Flow<LiveFrame>, stats: FramePacingStats,
    decode: (LiveFrame) -> T?, present: (LiveFrame, T) -> Unit,
    isCurrent: () -> Boolean = { true }) {
    monitorPumpFramesWithSourceFrame(frames, stats, { it.timestampNanos }, decode, present, isCurrent)
}

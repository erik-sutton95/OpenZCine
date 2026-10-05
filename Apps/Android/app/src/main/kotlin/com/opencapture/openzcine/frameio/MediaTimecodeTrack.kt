package com.opencapture.openzcine.frameio

import com.opencapture.opencine.runtime.MonitorMovieTimecode
import java.nio.file.Path

/** Existing metadata helper now delegates the shared box/sample owner. */
internal object MediaTimecodeTrack {
    fun copyTimecodeTrack(source: Path, target: Path): Boolean = MonitorMovieTimecode.copyTimecodeTrack(source, target)
}

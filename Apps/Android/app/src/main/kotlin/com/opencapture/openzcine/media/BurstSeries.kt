package com.opencapture.openzcine.media

internal typealias BurstFrame = com.opencapture.opencine.nikon.BurstFrame
internal typealias BurstSeries = com.opencapture.opencine.nikon.BurstSeries

/** Legacy test/caller names delegate to the integration owner. */
internal object BurstSeriesGrouping {
    fun group(frames: List<BurstFrame>, minCount: Int = 3, windowSeconds: Int = 1): List<BurstSeries> =
        com.opencapture.opencine.nikon.BurstSeriesGrouping.group(frames, minCount, windowSeconds)
    fun captureSeconds(captureDate: String): Int? =
        com.opencapture.opencine.nikon.BurstSeriesGrouping.captureSeconds(captureDate)
}

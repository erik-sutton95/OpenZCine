package com.opencapture.openzcine

import com.opencapture.monitorui.MonitorPlaybackZoom

/** Original live-picture limit supplied to the common gesture geometry. */
internal data class FeedZoom(val scale: Float = 1f, val offsetX: Float = 0f, val offsetY: Float = 0f) {
    val isZoomed: Boolean get() = common.isZoomed
    internal val common: MonitorPlaybackZoom get() = MonitorPlaybackZoom(scale, offsetX, offsetY, maximumScale = MAXIMUM)
    internal companion object {
        const val MAXIMUM = 8f
        const val SNAP_BACK_BELOW = 1.05f
        const val ZOOMED_ABOVE = 1.001f
        val NONE = FeedZoom()
    }
}

internal fun feedZoomAfterTransform(committed: FeedZoom, zoomChange: Float, centroidX: Float, centroidY: Float,
    panChangeX: Float, panChangeY: Float, width: Float, height: Float,
    pictureWidth: Float = width, pictureHeight: Float = height): FeedZoom {
    val value = committed.common.transformed(zoomChange, centroidX, centroidY, panChangeX, panChangeY,
        width, height, pictureWidth, pictureHeight)
    return FeedZoom(value.scale, value.offsetX, value.offsetY)
}
internal fun feedZoomSettled(zoom: FeedZoom): FeedZoom = zoom.common.settled().let {
    FeedZoom(it.scale, it.offsetX, it.offsetY)
}

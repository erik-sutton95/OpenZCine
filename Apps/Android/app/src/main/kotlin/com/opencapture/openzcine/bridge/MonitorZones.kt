package com.opencapture.openzcine.bridge

/** One zone frame in full-physical-viewport dp coordinates. */
data class ZoneFrame(val x: Float, val y: Float, val width: Float, val height: Float)

/** How a zone's chrome is drawn. */
enum class ZoneStyle {
    INFO_PILL,
    INFO_BAR,
    AXIS_HORIZONTAL,
    AXIS_VERTICAL,
    SCOPES_FLOATING,
    SCOPES_STACKED,
    BATTERY_RAIL,
    BATTERY_INLINE,
}

/**
 * The monitor's zone frames, projected from the shared OpenCine
 * `MonitorLayoutPolicy.fieldMonitor` layout in `MonitorScreen`.
 *
 * [batteryPhone]/[batteryCamera] are per-indicator battery frames, present only
 * when [batteryStyle] is [ZoneStyle.BATTERY_RAIL].
 */
data class MonitorZones(
    val feed: ZoneFrame,
    val infoBar: ZoneFrame,
    val captureStrip: ZoneFrame?,
    val assistStrip: ZoneFrame?,
    val systemCluster: ZoneFrame,
    val lock: ZoneFrame,
    val disp: ZoneFrame,
    val record: ZoneFrame,
    val media: ZoneFrame,
    val settings: ZoneFrame,
    val batteryCluster: ZoneFrame?,
    val batteryStyle: ZoneStyle?,
    val batteryPhone: ZoneFrame?,
    val batteryCamera: ZoneFrame?,
    val scopes: ZoneFrame?,
    val controlsGrid: ZoneFrame?,
)

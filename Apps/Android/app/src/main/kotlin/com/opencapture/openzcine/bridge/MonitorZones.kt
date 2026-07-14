package com.opencapture.openzcine.bridge

/** One zone frame in full-physical-viewport dp coordinates. */
data class ZoneFrame(val x: Float, val y: Float, val width: Float, val height: Float)

/** Mirror of the core's `MonitorZoneStyle`; ordinals match `MonitorZoneMapWire`. */
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
 * Parsed monitor zone map — the Kotlin view of the core's `MonitorZoneMap`,
 * decoded from the flat `[kind, style, x, y, width, height]` records produced
 * by `SwiftCore.monitorZoneMap` / `MonitorZoneMapWire.flattened` (Swift).
 *
 * [batteryPhone]/[batteryCamera] are the per-indicator frames of the landscape
 * battery rail (`MonitorBatteryRailLayout.fit`), present only when
 * [batteryStyle] is [ZoneStyle.BATTERY_RAIL].
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
) {
    companion object {
        private const val STRIDE = 6

        /** Decodes the wire array; throws when a required zone is missing. */
        fun parse(flat: FloatArray): MonitorZones {
            require(flat.size % STRIDE == 0) { "zone array length ${flat.size} not a multiple of $STRIDE" }
            val frames = HashMap<Int, ZoneFrame>()
            val styles = HashMap<Int, ZoneStyle>()
            for (start in flat.indices step STRIDE) {
                val kind = flat[start].toInt()
                frames[kind] = ZoneFrame(flat[start + 2], flat[start + 3], flat[start + 4], flat[start + 5])
                val style = flat[start + 1].toInt()
                if (style >= 0) styles[kind] = ZoneStyle.entries[style]
            }
            fun required(kind: Int): ZoneFrame =
                requireNotNull(frames[kind]) { "zone map missing required kind $kind" }
            return MonitorZones(
                feed = required(0),
                infoBar = required(1),
                captureStrip = frames[2],
                assistStrip = frames[3],
                systemCluster = required(4),
                lock = required(5),
                disp = required(6),
                record = required(7),
                media = required(8),
                settings = required(9),
                batteryCluster = frames[10],
                batteryStyle = styles[10],
                batteryPhone = frames[13],
                batteryCamera = frames[14],
                scopes = frames[11],
                controlsGrid = frames[12],
            )
        }
    }
}

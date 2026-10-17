package com.opencapture.openzcine.gyro

import org.json.JSONArray

/** Display information and GCSV mapping supplied by the shared Swift core. */
internal data class GyroMountOption(val id: String, val title: String, val group: String?,
    val shortLabel: String, val detail: String, val orientation: String)

/** Decodes the core's catalog without defining a second set of mount mappings. */
internal fun decodeGyroMountPresets(payload: String): List<GyroMountOption> {
    val values = JSONArray(payload)
    val options = List(values.length()) { index ->
        val value = values.getJSONObject(index)
        GyroMountOption(value.getString("id"), value.getString("title"),
            if (value.isNull("group")) null else value.getString("group"),
            value.getString("shortLabel"), value.getString("detail"), value.getString("orientation"))
    }
    require(options.any { it.id == "unconfigured" } && options.map { it.id }.distinct().size == options.size)
        { "The shared gyro mount catalog is invalid." }
    require(options.all { it.id.isNotBlank() && it.title.isNotBlank() && it.shortLabel.isNotBlank() &&
        it.detail.isNotBlank() && it.orientation.isNotBlank() }) { "The shared gyro mount catalog is incomplete." }
    return options
}

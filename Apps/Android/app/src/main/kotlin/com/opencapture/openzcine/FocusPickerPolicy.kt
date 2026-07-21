package com.opencapture.openzcine

/**
 * Focus picker ladders — 1:1 with iOS `CameraPicker.focus.modes`
 * (AF Mode / Area / Subject).
 *
 * Labels match `PTPCameraPropertyDecoders` movie-AF tables so they round-trip
 * with the body. AF-mode options keep the full picker set even when a lens
 * ring override temporarily advertises MF-only (same merge as the shared core).
 */
internal object FocusPickerPolicy {
    /** iOS FOCUS → AF Mode drum (MF first, base AF-F). */
    val afModeOptions: List<String> = listOf("MF", "AF-S", "AF-C", "AF-F")

    /** iOS FOCUS → Area drum. */
    val areaOptions: List<String> =
        listOf("Single", "Wide-S", "Wide-L", "Auto", "Subject")

    /** iOS FOCUS → Subject drum. */
    val subjectOptions: List<String> =
        listOf("Auto", "People", "Animal", "Bird", "Vehicle", "Airplane")

    const val AF_MODE_BASE: String = "AF-F"
    const val AREA_BASE: String = "Single"
    const val SUBJECT_BASE: String = "Auto"

    /** Header subtitle (iOS `CameraPicker.focus.subtitle`). */
    const val SUBTITLE: String = "AF mode · area · subject"

    /**
     * AF Mode drum: always the full iOS list, then any extra camera-advertised
     * labels (mirrors core `mergedMovieFocusModeOptions`).
     */
    fun afModeOptions(cameraAdvertised: List<String>): List<String> {
        val extras =
            cameraAdvertised.filter { label ->
                label.isNotBlank() && label !in afModeOptions
            }
        return afModeOptions + extras
    }

    /**
     * Area / Subject drums: prefer a multi-value camera enum that is not a
     * sparse demo stub; otherwise the iOS ladder, with any extra body labels
     * appended.
     */
    fun areaOptions(cameraAdvertised: List<String>): List<String> =
        mergeLadder(cameraAdvertised, areaOptions)

    fun subjectOptions(cameraAdvertised: List<String>): List<String> =
        mergeLadder(cameraAdvertised, subjectOptions)

    fun isAfModeLabel(value: String): Boolean =
        value in afModeOptions || value == "MF"

    fun isAreaLabel(value: String): Boolean =
        value in areaOptions || value.startsWith("Wide-")

    fun isSubjectLabel(value: String): Boolean =
        value in subjectOptions || value == "Off"

    private fun mergeLadder(cameraAdvertised: List<String>, ladder: List<String>): List<String> {
        val fromCamera = cameraAdvertised.filter { it.isNotBlank() }
        if (fromCamera.size <= 1) return ladder
        // Sparse or clearly wrong demo lists (e.g. mixed AF + area tokens) fall
        // back to the iOS ladder when fewer than half the ladder is present.
        val overlap = fromCamera.count { it in ladder }
        if (overlap < (ladder.size + 1) / 2) {
            val extras = fromCamera.filter { it !in ladder }
            return ladder + extras
        }
        val extras = fromCamera.filter { it !in ladder }
        // Preserve ladder order for known labels, then body-only extras.
        val known = ladder.filter { it in fromCamera.toSet() }
        return known + extras
    }
}

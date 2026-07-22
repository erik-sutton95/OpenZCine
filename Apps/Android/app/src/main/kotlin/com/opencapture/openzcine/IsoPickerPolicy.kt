package com.opencapture.openzcine

/**
 * ISO picker layout and recording-lock rules for Nikon ZR dual-base sensitivity.
 *
 * 1:1 with `Sources/OpenZCineCore/ISOPickerPolicy.swift`. R3D NE exposes separate
 * low/high base ISO circuits; other codecs use Auto On/Off plus a unified drum.
 */
internal object IsoPickerPolicy {
    /** Low-base ISO steps (200–3200). */
    val lowBaseOptions: List<String> =
        listOf(
            "200",
            "250",
            "320",
            "400",
            "500",
            "640",
            "800",
            "1000",
            "1250",
            "1600",
            "2000",
            "2500",
            "3200",
        )

    /** High-base ISO steps (1600–25600). */
    val highBaseOptions: List<String> =
        listOf(
            "1600",
            "2000",
            "2500",
            "3200",
            "4000",
            "5000",
            "6400",
            "8000",
            "10000",
            "12800",
            "16000",
            "20000",
            "25600",
        )

    /** Native low-base ISO flagged in the drum. */
    const val LOW_BASE_MARKER: String = "800"

    /** Native high-base ISO flagged in the drum. */
    const val HIGH_BASE_MARKER: String = "6400"

    /** Exposure mode that enables camera-managed ISO. */
    const val AUTO_ISO_ON_EXPOSURE_MODE: String = "Auto"

    /** Exposure mode that releases ISO for the drum. */
    const val AUTO_ISO_OFF_EXPOSURE_MODE: String = "M"

    /** Single-drum ISO steps for codecs that auto-switch base circuits. */
    val unifiedOptions: List<String> =
        (lowBaseOptions + highBaseOptions).distinct()

    /** Whether the active codec is R3D NE (raw or shortened camera labels). */
    fun isR3DNECodec(codec: String): Boolean {
        val short =
            codec
                .trim()
                .let { raw ->
                    when {
                        raw.contains("R3D", ignoreCase = true) &&
                            raw.contains("NE", ignoreCase = true) -> "R3D NE"
                        else -> raw
                    }
                }
        return short == "R3D NE"
    }

    /** R3D NE keeps separate LOW/HIGH base drums. */
    fun showsDualBaseCircuits(codec: String): Boolean = isR3DNECodec(codec)

    /** Non-R3D NE codecs use Auto On/Off tabs. */
    fun showsAutoISOControl(codec: String): Boolean = !showsDualBaseCircuits(codec)

    /** Exposure modes where the body typically owns ISO. */
    fun isAutoISOActive(exposureMode: String?): Boolean {
        val mode = exposureMode?.trim().orEmpty()
        if (mode.isEmpty()) return false
        return when (mode) {
            "Auto", "P", "A", "S" -> true
            else -> mode.contains("auto", ignoreCase = true)
        }
    }

    /** Active Auto tab: 0 = Auto On, 1 = Auto Off. */
    fun autoISOModeIndex(exposureMode: String?): Int =
        if (isAutoISOActive(exposureMode)) 0 else 1

    /** ISO cannot be changed while recording in R3D NE. */
    fun blocksISOChangeWhileRecording(codec: String, isRecording: Boolean): Boolean =
        isR3DNECodec(codec) && isRecording

    /** Star markers for the active layout. */
    fun markedValues(codec: String, modeIndex: Int): Set<String> =
        if (showsDualBaseCircuits(codec)) {
            when (modeIndex) {
                0 -> setOf(LOW_BASE_MARKER)
                1 -> setOf(HIGH_BASE_MARKER)
                else -> emptySet()
            }
        } else {
            setOf(LOW_BASE_MARKER, HIGH_BASE_MARKER)
        }

    /** Subtitle shown under the ISO picker header. */
    fun pickerSubtitle(codec: String): String =
        when {
            showsDualBaseCircuits(codec) -> "Sensitivity · dual base"
            showsAutoISOControl(codec) -> "Sensitivity · auto / manual"
            else -> "Sensitivity"
        }

    /** Mode tabs for the ISO picker. */
    fun pickerModes(codec: String): List<IsoPickerMode> =
        when {
            showsDualBaseCircuits(codec) ->
                listOf(
                    IsoPickerMode(
                        title = "Low Base",
                        detail = "$LOW_BASE_MARKER · 200-3200",
                        options = lowBaseOptions,
                        base = LOW_BASE_MARKER,
                    ),
                    IsoPickerMode(
                        title = "High Base",
                        detail = "$HIGH_BASE_MARKER · 1600-25600",
                        options = highBaseOptions,
                        base = HIGH_BASE_MARKER,
                    ),
                )
            showsAutoISOControl(codec) ->
                listOf(
                    IsoPickerMode(
                        title = "Auto On",
                        detail = "Camera controls ISO",
                        options = unifiedOptions,
                        base = LOW_BASE_MARKER,
                        activatesAutoISO = true,
                    ),
                    IsoPickerMode(
                        title = "Auto Off",
                        detail = "Manual ISO",
                        options = unifiedOptions,
                        base = LOW_BASE_MARKER,
                        activatesAutoISO = false,
                    ),
                )
            else -> emptyList()
        }

    /** Options for the active ISO layout and mode tab. */
    fun options(codec: String, modeIndex: Int): List<String> {
        val modes = pickerModes(codec)
        return if (modes.isEmpty() || modeIndex !in modes.indices) {
            unifiedOptions
        } else {
            modes[modeIndex].options
        }
    }
}

/** One segmented mode under the ISO picker (LOW/HIGH base or Auto On/Off). */
internal data class IsoPickerMode(
    val title: String,
    val detail: String?,
    val options: List<String>,
    val base: String,
    val activatesAutoISO: Boolean? = null,
)

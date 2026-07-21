package com.opencapture.openzcine

/**
 * ISO picker layout and recording-lock rules for Nikon ZR dual-base sensitivity.
 *
 * 1:1 with `Sources/OpenZCineCore/ISOPickerPolicy.swift`. R3D NE exposes separate
 * low/high base ISO circuits; other codecs keep dual-base hardware but
 * auto-switch, so the operator sees one drum with native-base markers.
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

    /** Single-drum ISO steps for codecs that auto-switch base circuits. */
    val unifiedOptions: List<String> =
        (lowBaseOptions + highBaseOptions).distinct()

    /** Whether the active codec is R3D NE (raw or shortened camera labels). */
    fun isR3DNECodec(codec: String): Boolean {
        val short =
            codec
                .trim()
                .let { raw ->
                    // Match MonitorTextFormat.codecShortLabel for R3D NE detection.
                    when {
                        raw.contains("R3D", ignoreCase = true) &&
                            raw.contains("NE", ignoreCase = true) -> "R3D NE"
                        else -> raw
                    }
                }
        return short == "R3D NE"
    }

    /** R3D NE keeps separate LOW/HIGH base drums; every other codec uses a unified drum. */
    fun showsDualBaseCircuits(codec: String): Boolean = isR3DNECodec(codec)

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
        if (showsDualBaseCircuits(codec)) "Sensitivity · dual base" else "Sensitivity"

    /** Mode tabs for the ISO picker. Empty when the unified drum is shown. */
    fun pickerModes(codec: String): List<IsoPickerMode> =
        if (!showsDualBaseCircuits(codec)) {
            emptyList()
        } else {
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

/** One segmented mode under the ISO picker (LOW/HIGH base for R3D NE). */
internal data class IsoPickerMode(
    val title: String,
    val detail: String?,
    val options: List<String>,
    val base: String,
)

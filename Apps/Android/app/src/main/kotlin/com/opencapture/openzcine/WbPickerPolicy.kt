package com.opencapture.openzcine

/**
 * White-balance picker ladders — 1:1 with iOS `CameraPicker.whiteBalance.modes`
 * (Kelvin / Preset / Tint).
 *
 * Kelvin steps match shared-core `WhiteBalanceKelvinPolicy`:
 * Nikon K [Choose color temperature] **2500–10000 K** body **dial** steps
 * (~10 mired; e.g. **5560K**, not round **5600K** from fine-tune).
 */
internal object WbPickerPolicy {
    /** Inclusive Nikon documented range (ZR / Z-series manuals). */
    const val MINIMUM_KELVIN: Int = 2_500
    const val MAXIMUM_KELVIN: Int = 10_000
    /** Dial step nearest daylight — not the round 5600 of prose / fine-tune. */
    const val DEFAULT_KELVIN: Int = 5_560

    /** Fine-adjust step (Kelvin) on long-press of the selected drum value. */
    const val FINE_STEP_KELVIN: Int = 10

    /**
     * Body dial colour-temperature steps (Kelvin) — keep in lockstep with
     * `Sources/OpenZCineCore/WhiteBalanceKelvinPolicy.swift`.
     */
    val kelvinSteps: List<Int> =
        listOf(
            2_500, 2_560, 2_630, 2_700, 2_780, 2_860, 2_940, 3_030, 3_130, 3_230,
            3_330, 3_450, 3_570, 3_700, 3_850, 4_000, 4_170, 4_350, 4_550, 4_760,
            5_000, 5_260, 5_560, 5_880, 6_250, 6_670, 7_140, 7_690, 8_330, 9_090,
            10_000,
        )

    /** Kelvin-circuit drum labels. */
    val kelvinOptions: List<String> = kelvinSteps.map { "${it}K" }

    /**
     * Named presets (iOS PRESET tab). Labels match
     * `PTPCameraPropertyDecoders.wbModeNames` so they round-trip with the body.
     */
    val presetOptions: List<String> =
        listOf(
            "Auto",
            "Natural auto",
            "Sunny",
            "Cloudy",
            "Shade",
            "Incandescent",
            "Fluorescent",
            "Flash",
            "Preset",
        )

    const val KELVIN_BASE: String = "5560K"
    const val PRESET_BASE: String = "Auto"

    /** Header subtitle (iOS `CameraPicker.whiteBalance.subtitle`). */
    const val SUBTITLE: String = "Kelvin / preset / tint"

    /**
     * Kelvin drum: use a denser camera-advertised enum when present; otherwise
     * the full Nikon dial ladder. Sparse demo stubs must not shrink the drum.
     * [liveLabel] is inserted when the body is on an off-ladder temperature
     * (e.g. fine-tuned 5600K).
     */
    fun kelvinOptions(
        cameraAdvertised: List<String>,
        liveLabel: String? = null,
    ): List<String> {
        val fromCamera =
            cameraAdvertised
                .mapNotNull { kelvin(from = it) }
                .distinct()
                .sorted()
        val base =
            if (fromCamera.size > kelvinSteps.size) fromCamera else kelvinSteps
        val live = liveLabel?.let { kelvin(from = it) }
        val steps =
            if (live != null && live !in base) {
                (base + live).sorted()
            } else {
                base
            }
        return steps.map { "${it}K" }
    }

    /** Prefer multi-value named presets; otherwise the iOS list. */
    fun presetOptions(cameraAdvertised: List<String>): List<String> {
        val presets =
            cameraAdvertised.filter {
                !isKelvinLabel(it) && it.isNotBlank()
            }
        return if (presets.size > 1) presets else presetOptions
    }

    fun kelvin(from: String): Int? {
        val trimmed = from.trim()
        val numeric =
            if (trimmed.endsWith("K", ignoreCase = true)) {
                trimmed.dropLast(1)
            } else {
                trimmed
            }
        val value = numeric.toIntOrNull() ?: return null
        return value.takeIf { it in MINIMUM_KELVIN..MAXIMUM_KELVIN }
    }

    fun isKelvinLabel(value: String): Boolean = kelvin(from = value) != null

    fun isPresetLabel(value: String): Boolean =
        value in presetOptions ||
            (!isKelvinLabel(value) && value.isNotBlank() && value != "—" && value != "Color temp")

    /**
     * Nudge a Kelvin label by [delta] K (typically ±[FINE_STEP_KELVIN]), clamped
     * to 2500–10000. Null when [from] is not a Kelvin readout.
     */
    fun fineAdjust(from: String, delta: Int): String? {
        val current = kelvin(from = from) ?: return null
        val next = (current + delta).coerceIn(MINIMUM_KELVIN, MAXIMUM_KELVIN)
        return "${next}K"
    }

    fun canFineAdjust(from: String, delta: Int): Boolean {
        val current = kelvin(from = from) ?: return false
        val next = current + delta
        return next in MINIMUM_KELVIN..MAXIMUM_KELVIN && next != current
    }
}

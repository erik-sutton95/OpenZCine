package com.opencapture.openzcine

/**
 * ISO picker layout and recording-lock rules for Nikon ZR dual-base sensitivity.
 *
 * 1:1 with `Sources/OpenZCineCore/ISOPickerPolicy.swift`. R3D NE exposes separate
 * low/high base ISO circuits; other codecs use Auto On/Off plus a unified drum.
 * Auto Off / manual ISO is only offered in exposure mode **M**.
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

    /** Label written for Auto On (`MovISOAutoControl` UINT8 = 1). */
    const val AUTO_ISO_ON_LABEL: String = "ON"

    /** Label written for Auto Off (`MovISOAutoControl` UINT8 = 0). */
    const val AUTO_ISO_OFF_LABEL: String = "OFF"

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

    /**
     * Whether movie ISO auto is active (`MovISOAutoControl` 0xD0AD).
     * Independent of exposure-program Auto (P/A/S/M). Unpolled (`null`) → manual.
     */
    fun isAutoISOActive(isoAuto: Boolean?): Boolean = isoAuto == true

    /**
     * Whether the operator may write a manual movie ISO for this codec / mode.
     *
     * - **R3D NE**: always manual dual-base (even in A/S/P).
     * - **Other codecs**: only exposure mode **M** (Auto Off + drum). Fail closed when unknown.
     */
    fun allowsManualISO(codec: String, exposureMode: String?): Boolean =
        if (showsDualBaseCircuits(codec)) true else exposureMode == "M"

    /**
     * True when the ISO value drum is camera-owned (Auto On, or non-R3D mode is not M).
     * Always false for R3D NE dual-base (recording lock is separate).
     */
    fun isISOValueCameraOwned(
        codec: String,
        isoAuto: Boolean?,
        exposureMode: String?,
    ): Boolean =
        if (showsDualBaseCircuits(codec)) {
            false
        } else {
            isAutoISOActive(isoAuto) || !allowsManualISO(codec, exposureMode)
        }

    /** Active Auto tab: 0 = Auto On, 1 = Auto Off (when M allows manual on non-R3D). */
    fun autoISOModeIndex(
        codec: String,
        isoAuto: Boolean?,
        exposureMode: String? = null,
    ): Int =
        if (!allowsManualISO(codec, exposureMode)) {
            0
        } else if (isAutoISOActive(isoAuto)) {
            0
        } else {
            1
        }

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
    fun pickerSubtitle(codec: String, exposureMode: String? = null): String =
        when {
            showsDualBaseCircuits(codec) -> "Sensitivity · dual base"
            showsAutoISOControl(codec) && allowsManualISO(codec, exposureMode) ->
                "Sensitivity · auto / manual"
            showsAutoISOControl(codec) -> "Sensitivity · auto (M mode for manual)"
            else -> "Sensitivity"
        }

    /** Mode tabs for the ISO picker. Auto Off only when exposure mode is M (non-R3D). */
    fun pickerModes(codec: String, exposureMode: String? = null): List<IsoPickerMode> =
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
                buildList {
                    add(
                        IsoPickerMode(
                            title = "Auto On",
                            detail = "Camera controls ISO",
                            options = unifiedOptions,
                            base = LOW_BASE_MARKER,
                            activatesAutoISO = true,
                        ),
                    )
                    if (allowsManualISO(codec, exposureMode)) {
                        add(
                            IsoPickerMode(
                                title = "Auto Off",
                                detail = "Manual ISO",
                                options = unifiedOptions,
                                base = LOW_BASE_MARKER,
                                activatesAutoISO = false,
                            ),
                        )
                    }
                }
            else -> emptyList()
        }

    /**
     * Options for the active ISO layout and mode tab.
     * Injects [includingLiveISO] when Auto is outside the fixed ladder (e.g. 51200).
     */
    fun options(
        codec: String,
        modeIndex: Int,
        includingLiveISO: String? = null,
    ): List<String> {
        val modes = pickerModes(codec)
        val base =
            if (modes.isEmpty() || modeIndex !in modes.indices) {
                unifiedOptions
            } else {
                modes[modeIndex].options
            }
        val live = includingLiveISO?.trim().orEmpty()
        if (live.isEmpty() || !live.all { it.isDigit() } || live in base) {
            return base
        }
        val liveValue = live.toLongOrNull() ?: return base + live
        val mutable = base.toMutableList()
        val insertAt = mutable.indexOfFirst { (it.toLongOrNull() ?: Long.MAX_VALUE) > liveValue }
        if (insertAt < 0) {
            mutable.add(live)
        } else {
            mutable.add(insertAt, live)
        }
        return mutable
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

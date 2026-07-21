package com.opencapture.openzcine

/**
 * Shutter picker Angle / Speed ladders — 1:1 with iOS `CameraPicker.shutter.modes`
 * and the hardcoded fallback used when the body has not advertised a full enum.
 */
internal object ShutterPickerPolicy {
    /** Angle-circuit drum (iOS ANGLE tab). */
    val angleOptions: List<String> =
        listOf(
            "5.6°",
            "11.2°",
            "22.5°",
            "45°",
            "72°",
            "86.4°",
            "90°",
            "108°",
            "144°",
            "172°",
            "180°",
            "216°",
            "288°",
            "346°",
            "360°",
        )

    /** Speed-circuit drum (iOS SPEED tab). */
    val speedOptions: List<String> =
        listOf(
            "1/6",
            "1/8",
            "1/10",
            "1/13",
            "1/15",
            "1/20",
            "1/25",
            "1/30",
            "1/40",
            "1/50",
            "1/60",
            "1/80",
            "1/100",
            "1/125",
            "1/160",
            "1/200",
            "1/250",
            "1/320",
            "1/400",
            "1/500",
            "1/640",
            "1/800",
            "1/1000",
            "1/1250",
            "1/1600",
            "1/2000",
            "1/2500",
            "1/3200",
            "1/4000",
            "1/5000",
            "1/6400",
            "1/8000",
            "1/10000",
            "1/13000",
            "1/16000",
        )

    const val ANGLE_BASE: String = "180°"
    const val SPEED_BASE: String = "1/50"

    /** Header subtitle (iOS `CameraPicker.shutter.subtitle`). */
    const val SUBTITLE: String = "Angle / speed"

    /**
     * Prefer a camera-advertised ladder when it has more than one value and
     * matches the circuit; otherwise the hardcoded iOS fallback.
     */
    fun angleOptions(cameraAdvertised: List<String>): List<String> {
        val angles = cameraAdvertised.filter { it.contains('°') }
        return if (angles.size > 1) angles else angleOptions
    }

    fun speedOptions(cameraAdvertised: List<String>): List<String> {
        val speeds =
            cameraAdvertised.filter {
                it.startsWith("1/") || it.equals("Bulb", ignoreCase = true)
            }
        return if (speeds.size > 1) speeds else speedOptions
    }
}

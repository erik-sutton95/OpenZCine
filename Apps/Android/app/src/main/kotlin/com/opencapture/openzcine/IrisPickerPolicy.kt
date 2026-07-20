package com.opencapture.openzcine

/**
 * IRIS drum when the body has not advertised an f-number enum — 1:1 with the
 * shared-core third-stop ladder used by iOS (`PTPCameraPropertyDecoders.availableApertures`).
 */
internal object IrisPickerPolicy {
    /** Full third-stop ladder from f/1.4 through f/22. */
    val fullLadder: List<String> =
        listOf(
            "f/1.4",
            "f/1.6",
            "f/1.8",
            "f/2.0",
            "f/2.2",
            "f/2.5",
            "f/2.8",
            "f/3.2",
            "f/3.5",
            "f/4.0",
            "f/4.5",
            "f/5.0",
            "f/5.6",
            "f/6.3",
            "f/7.1",
            "f/8.0",
            "f/9.0",
            "f/10.0",
            "f/11.0",
            "f/13.0",
            "f/14.0",
            "f/16.0",
            "f/18.0",
            "f/20.0",
            "f/22.0",
        )

    /**
     * Options for the mounted lens when known (widest marked aperture and
     * narrower stops), otherwise the full ladder.
     */
    fun options(forLensDescriptor: String?): List<String> {
        val widest = widestAperture(forLensDescriptor) ?: return fullLadder
        val fromLadder = fullLadder.filter { stop ->
            apertureNumber(stop)?.let { it >= widest - 0.05 } == true
        }
        if (fromLadder.isEmpty()) return fullLadder
        val head = fromLadder.first()
        val headN = apertureNumber(head)
        return if (headN != null && kotlin.math.abs(headN - widest) > 0.05) {
            listOf(String.format(java.util.Locale.US, "f/%.1f", widest)) + fromLadder
        } else {
            fromLadder
        }
    }

    private fun widestAperture(lens: String?): Double? {
        if (lens.isNullOrBlank()) return null
        val match = Regex("""f/\s*(\d+(?:\.\d+)?)""", RegexOption.IGNORE_CASE).find(lens) ?: return null
        return match.groupValues[1].toDoubleOrNull()
    }

    private fun apertureNumber(label: String): Double? {
        val match = Regex("""f/\s*(\d+(?:\.\d+)?)""", RegexOption.IGNORE_CASE).find(label) ?: return null
        return match.groupValues[1].toDoubleOrNull()
    }
}

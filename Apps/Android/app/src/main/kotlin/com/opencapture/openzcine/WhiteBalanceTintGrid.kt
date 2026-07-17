package com.opencapture.openzcine

import kotlin.math.abs
import kotlin.math.roundToInt

/**
 * Kotlin mirror of shared-core `WhiteBalanceTint` grid policy used by the iOS
 * pad and the Android facade write path.
 *
 * Axes: x = amber(+) ↔ blue(−), y = green(+) ↔ magenta(−), cells −6…+6.
 * One A–B cell = 0.5 units; one G–M cell = 0.25 units.
 */
internal object WhiteBalanceTintGrid {
    val cellRange: IntRange = -6..6
    const val amberBlueUnitsPerCell: Double = 0.5
    const val greenMagentaUnitsPerCell: Double = 0.25

    /** Operator-facing readout: `"A1.5 · G0.75"`, or `"Neutral"`. */
    fun label(amberBlueCell: Int, greenMagentaCell: Int): String {
        val ab = clamp(amberBlueCell)
        val gm = clamp(greenMagentaCell)
        val parts = mutableListOf<String>()
        if (ab != 0) {
            parts += (if (ab > 0) "A" else "B") + trimmed(abs(ab) * amberBlueUnitsPerCell)
        }
        if (gm != 0) {
            parts += (if (gm > 0) "G" else "M") + trimmed(abs(gm) * greenMagentaUnitsPerCell)
        }
        return if (parts.isEmpty()) "Neutral" else parts.joinToString(" · ")
    }

    /**
     * Decodes a camera/operator label back to grid cells. Unknown shapes fall
     * back to neutral so the pad always has a defined thumb position.
     */
    fun cellsFromLabel(label: String): Pair<Int, Int> {
        val trimmedLabel = label.trim()
        if (trimmedLabel.isEmpty() || trimmedLabel.equals("Neutral", ignoreCase = true)) {
            return 0 to 0
        }
        var ab = 0
        var gm = 0
        for (part in trimmedLabel.split(" · ", "·").map { it.trim() }.filter { it.isNotEmpty() }) {
            when {
                part.startsWith("A", ignoreCase = true) ->
                    ab = unitsToCells(part.drop(1), amberBlueUnitsPerCell)
                part.startsWith("B", ignoreCase = true) ->
                    ab = -unitsToCells(part.drop(1), amberBlueUnitsPerCell)
                part.startsWith("G", ignoreCase = true) ->
                    gm = unitsToCells(part.drop(1), greenMagentaUnitsPerCell)
                part.startsWith("M", ignoreCase = true) ->
                    gm = -unitsToCells(part.drop(1), greenMagentaUnitsPerCell)
            }
        }
        return clamp(ab) to clamp(gm)
    }

    /** Full 13×13 label set in row-major green→magenta / blue→amber order. */
    fun allLabels(): List<String> =
        cellRange.flatMap { gm ->
            cellRange.map { ab -> label(ab, gm) }
        }

    fun clamp(value: Int): Int = value.coerceIn(cellRange.first, cellRange.last)

    private fun unitsToCells(raw: String, unitsPerCell: Double): Int {
        val units = raw.toDoubleOrNull() ?: return 0
        return (units / unitsPerCell).roundToInt()
    }

    private fun trimmed(value: Double): String =
        if (value == value.toInt().toDouble()) {
            value.toInt().toString()
        } else {
            value.toString()
        }
}

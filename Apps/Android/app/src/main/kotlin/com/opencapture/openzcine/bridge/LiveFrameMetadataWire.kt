package com.opencapture.openzcine.bridge

import com.opencapture.openzcine.core.LiveCameraLevel
import com.opencapture.openzcine.core.LiveFocusBox
import com.opencapture.openzcine.core.LiveFocusInfo
import com.opencapture.openzcine.core.LiveFocusResult

/** Converts one additive Swift callback's focus primitives into the core API model. */
internal fun liveFocusInfoFromWire(
    hasFocus: Boolean,
    coordinateWidth: Int,
    coordinateHeight: Int,
    focusResult: Int,
    subjectDetectionActive: Boolean,
    trackingAFActive: Boolean,
    selectedBoxIndex: Int,
    flattenedBoxes: IntArray,
): LiveFocusInfo? {
    if (!hasFocus || coordinateWidth <= 0 || coordinateHeight <= 0) return null
    if (flattenedBoxes.size % FOCUS_BOX_COMPONENT_COUNT != 0) return null

    val boxes =
        flattenedBoxes
            .asList()
            .chunked(FOCUS_BOX_COMPONENT_COUNT)
            .map { components ->
                LiveFocusBox(
                    centerX = components[0],
                    centerY = components[1],
                    width = components[2],
                    height = components[3],
                )
            }
    if (boxes.any { !it.isValidFor(coordinateWidth, coordinateHeight) }) return null

    return LiveFocusInfo(
        coordinateWidth = coordinateWidth,
        coordinateHeight = coordinateHeight,
        result = liveFocusResultFromWire(focusResult),
        subjectDetectionActive = subjectDetectionActive,
        trackingAFActive = trackingAFActive,
        selectedBoxIndex = selectedBoxIndex.takeIf { it in boxes.indices },
        boxes = boxes,
    )
}

/** Converts one additive Swift callback's already-normalized level primitives. */
internal fun liveCameraLevelFromWire(
    hasLevel: Boolean,
    rollDegrees: Double,
    pitchDegrees: Double,
    yawDegrees: Double,
): LiveCameraLevel? {
    if (!hasLevel || !rollDegrees.isFinite() || !pitchDegrees.isFinite() || !yawDegrees.isFinite()) {
        return null
    }
    return LiveCameraLevel(
        rollDegrees = rollDegrees,
        pitchDegrees = pitchDegrees,
        yawDegrees = yawDegrees,
    )
}

private fun liveFocusResultFromWire(value: Int): LiveFocusResult =
    when (value) {
        1 -> LiveFocusResult.NOT_FOCUSED
        2 -> LiveFocusResult.FOCUSED
        else -> LiveFocusResult.UNKNOWN
    }

private fun LiveFocusBox.isValidFor(coordinateWidth: Int, coordinateHeight: Int): Boolean =
    width > 0 &&
        height > 0 &&
        centerX in 0..coordinateWidth &&
        centerY in 0..coordinateHeight

private const val FOCUS_BOX_COMPONENT_COUNT = 4

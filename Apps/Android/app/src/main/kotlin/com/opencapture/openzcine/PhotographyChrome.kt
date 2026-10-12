package com.opencapture.openzcine

import androidx.compose.foundation.layout.size
import androidx.compose.ui.graphics.Color
import com.opencapture.opencine.nikon.CameraPropertySnapshot
import java.util.Locale

// The photography capture strip renders through the shared `MonitorCaptureStrip`
// over `photographyCaptureSettings` (PhotographyPickers.kt) — iOS reuses
// `CaptureSettingButton` for both chromes the same way.

/** Drive-mode label compacted to strip width ("Continuous H" → "CH"). */
internal fun compactDriveLabel(stillCaptureMode: String?): String? =
    when (stillCaptureMode) {
        null -> null
        "Continuous H" -> "CH"
        "Continuous L" -> "CL"
        "Continuous H+" -> "CH+"
        "Self-timer" -> "Timer"
        else -> stillCaptureMode
    }

/**
 * Picture-control label compacted to strip width (iOS
 * `compactPictureControlLabel`): body-style codes for the built-ins; Auto and
 * the creative names are short enough to show whole.
 */
internal fun compactPictureControlLabel(pictureControl: String?): String? =
    when (pictureControl) {
        null -> null
        "Standard" -> "SD"
        "Neutral" -> "NL"
        "Vivid" -> "VI"
        "Monochrome" -> "MC"
        "Portrait" -> "PT"
        "Landscape" -> "LS"
        "Flat" -> "FL"
        "Flat Mono" -> "FM"
        "Deep Tone Mono" -> "DTM"
        "Rich Tone Portrait" -> "RTP"
        else -> pictureControl
    }

/**
 * WB tile readout (iOS `stillWhiteBalanceValue`): the Kelvin figure while in
 * colour-temperature mode, else the preset name (presets render as icons in
 * the strip, like the movie tile).
 */
internal fun stillWhiteBalanceValue(properties: CameraPropertySnapshot): String {
    // The STILLS side: `WhiteBalance` (0x5005) is its own camera setting, and a movie value
    // standing in for it is what made the readout jump when a take started.
    val mode = properties.activeWhiteBalanceMode(photography = true)
    val kelvin = properties.whiteBalanceKelvin
    if (mode == "Color temp" && kelvin != null) return "${kelvin}K"
    return mode ?: "—"
}

/** Quality label compacted to strip width ("RAW+JPEG Fine★" → "R+JF★"). */
internal fun CameraPropertySnapshot.stillQualityCompactLabel(): String? {
    val compression = compression ?: return imageSize
    if (compression.startsWith("RAW+JPEG")) {
        val suffix = compression.drop("RAW+JPEG ".length)
        val letter = suffix.firstOrNull()?.toString() ?: ""
        val star = if (suffix.endsWith("★")) "★" else ""
        return "R+J$letter$star"
    }
    if (compression.startsWith("JPEG")) {
        val suffix = compression.drop("JPEG ".length)
        val letter = suffix.firstOrNull()?.toString() ?: ""
        val star = if (suffix.endsWith("★")) "★" else ""
        return "JPG $letter$star"
    }
    return compression
}

/** Image-size label compacted for the photo top bar ("Size L" → "L"). */
internal fun CameraPropertySnapshot.stillSizeCompactLabel(): String? =
    imageSize?.replace("Size ", "")

/**
 * Top-bar SIZE readout: image area + size class ("FX · L"), ranked against the
 * camera's enumerated ImageSize strings so the pill never shows a raw
 * resolution (iOS `stillSizeAreaLabel`). Falls back to whichever half is known.
 */
internal fun CameraPropertySnapshot.stillSizeAreaLabel(): String? {
    val size = stillSizeClassLabel()
    return when {
        imageArea != null && size != null -> "$imageArea · $size"
        imageArea != null -> imageArea
        else -> size
    }
}

/**
 * Ranks the current image-size string among the camera's enumerated sizes:
 * largest pixel count = L, then M, then S. "Size L"-form strings pass through.
 */
internal fun CameraPropertySnapshot.stillSizeClassLabel(): String? {
    if (imageSize == null) return null
    val letters = listOf("L", "M", "S")
    stillSizeCompactLabel()?.takeIf { it in letters }?.let { return it }
    val ranked =
        controlCapabilities.imageSizes
            .mapNotNull { option -> stillSizePixelCount(option)?.let { option to it } }
            .sortedByDescending { it.second }
    val index = ranked.indexOfFirst { it.first == imageSize }
    return letters.getOrNull(index.takeIf { it >= 0 } ?: return null)
}

/** "6048x4032" → 24_385_536; null for strings that aren't a WxH resolution. */
private fun stillSizePixelCount(size: String): Long? {
    val parts = size.lowercase(Locale.ROOT).split("x")
    if (parts.size != 2) return null
    val width = parts[0].trim().toLongOrNull() ?: return null
    val height = parts[1].trim().toLongOrNull() ?: return null
    return width * height
}

/** The instant review's settings line, captured at present time (iOS `presentInstantReview`). */
internal fun photographyReviewInfoLine(properties: CameraPropertySnapshot): String? =
    listOfNotNull(
        properties.iso?.let { "ISO $it" },
        properties.shutterSpeed,
        properties.iris,
        properties.compression,
    )
        .joinToString("   ")
        .ifEmpty { null }

/** "1234" up to four digits, "12.3k" beyond, like the camera's own counter. */
internal fun shotsRemainingCompactLabel(count: Int): String =
    if (count > 9999) {
        String.format(Locale.ROOT, "%.1fk", count / 1000.0)
    } else {
        count.toString()
    }

/** Whether the shell should show photography chrome for this snapshot. */
internal fun prefersPhotographyChrome(properties: CameraPropertySnapshot): Boolean =
    properties.captureSelector.equals("photo", ignoreCase = true)

/** The live-view frame aspect for a photo image-area label (iOS `photographyFeedAspect`). */
internal fun photographyFeedAspect(imageArea: String?): Float =
    when (imageArea) {
        "1:1" -> 1f
        "16:9" -> 16f / 9f
        // FX / DX / unknown: the 3:2 stills frame.
        else -> 3f / 2f
    }

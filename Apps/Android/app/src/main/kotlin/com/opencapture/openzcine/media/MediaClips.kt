package com.opencapture.openzcine.media

import java.util.Locale

/**
 * One browsable media object listed from the camera — the Kotlin mirror of
 * the facade's `FacadeMediaClip` / `MediaListWire` (Sources/
 * OpenZCineAndroidFacade/MediaBrowse.swift).
 */
data class MediaClipRecord(
    /** PTP object handle (UInt32 as an unsigned value in a Long). */
    val handle: Long,
    /** Owning storage volume. */
    val storageId: Long,
    /** On-card size in bytes (PTP `ObjectCompressedSize`, 32-bit). */
    val sizeBytes: Long,
    /** PTP date-time string (`YYYYMMDDThhmmss`) or empty. */
    val captureDate: String,
    /** Full-image pixel size (0 when the camera omits it). */
    val pixelWidth: Int,
    val pixelHeight: Int,
    /** True when the shared core classifies this as a playable proxy. */
    val isPlayableProxy: Boolean,
    /** Sanitized on-card filename, e.g. `C0001.MOV`. */
    val filename: String,
) {
    /** Uppercased file extension, e.g. `MOV`; empty when the name has none. */
    val codecLabel: String =
        filename.substringAfterLast('.', missingDelimiterValue = "").uppercase(Locale.US)

    /** iOS `MediaClipFormatting.byteLabel`: `412MB` below 1 GB, else `1.3GB`. */
    val sizeLabel: String
        get() {
            if (sizeBytes <= 0) return "0 B"
            val mb = sizeBytes / 1_000_000.0
            return if (mb < 1_000) {
                String.format(Locale.US, "%.0fMB", mb)
            } else {
                String.format(Locale.US, "%.1fGB", mb / 1_000)
            }
        }

    /** Grid-cell badge: size plus codec (`1.3GB · MOV`). */
    val badgeLabel: String =
        if (codecLabel.isEmpty()) sizeLabel else "$sizeLabel · $codecLabel"
}

/** Parsing and ordering for the media listing crossing the JNI seam. */
object MediaClips {
    /**
     * Parses the facade's wire format — one record per line, tab-separated
     * `handle, storageID, sizeBytes, captureDate, width, height, playable, filename`
     * (filename last; it is sanitized tab/newline-free by the facade).
     * Malformed lines are skipped, never fatal: the listing is network input.
     */
    fun parse(wire: String): List<MediaClipRecord> =
        wire.lineSequence()
            .mapNotNull { line ->
                val fields = line.split('\t')
                if (fields.size != 8) return@mapNotNull null
                MediaClipRecord(
                    handle = fields[0].toLongOrNull() ?: return@mapNotNull null,
                    storageId = fields[1].toLongOrNull() ?: return@mapNotNull null,
                    sizeBytes = fields[2].toLongOrNull() ?: return@mapNotNull null,
                    captureDate = fields[3],
                    pixelWidth = fields[4].toIntOrNull() ?: return@mapNotNull null,
                    pixelHeight = fields[5].toIntOrNull() ?: return@mapNotNull null,
                    isPlayableProxy =
                        when (fields[6]) {
                            "1" -> true
                            "0" -> false
                            else -> return@mapNotNull null
                        },
                    filename = fields[7].ifEmpty { return@mapNotNull null },
                )
            }
            .toList()

    /**
     * The iOS browser's default `newest` order: capture date descending (the
     * PTP `YYYYMMDDThhmmss` format sorts lexicographically), filename
     * descending as the tiebreaker.
     */
    fun newestFirst(clips: List<MediaClipRecord>): List<MediaClipRecord> =
        clips.sortedWith(
            compareByDescending<MediaClipRecord> { it.captureDate }
                .thenByDescending { it.filename.lowercase(Locale.US) },
        )
}

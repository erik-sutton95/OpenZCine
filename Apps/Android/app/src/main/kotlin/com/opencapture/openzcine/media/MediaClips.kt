package com.opencapture.openzcine.media

import java.util.Locale

/** Shared-core browser action decoded from one `MediaListWire` record. */
public enum class MediaContentKind(private val wireCode: String) {
    /** MOV/MP4/M4V proxy that opens the progressive video player. */
    PLAYABLE_PROXY("proxy"),

    /** A still image that opens the transfer-backed photo viewer. */
    STILL_PHOTO("still"),

    /** An unpaired RED master; it remains deliberately non-previewable. */
    R3D_MASTER("r3d"),

    /** A future or unrecognised media-library object. */
    UNSUPPORTED("unsupported");

    companion object {
        /** Decodes the core's stable media-action code without inspecting a filename. */
        internal fun fromWire(code: String): MediaContentKind? =
            entries.firstOrNull { it.wireCode == code }
    }
}

/** Shared-core still decoder policy decoded from one `MediaListWire` record. */
public enum class StillPreviewStrategy(private val wireCode: String) {
    /** JPEG and PNG may decode before the object has completely transferred. */
    PROGRESSIVE("progressive"),

    /** HEIF/TIFF decoding is attempted only after the complete cache is published. */
    COMPLETE_FILE("complete"),

    /** Nikon RAW is shown through the camera thumbnail only; no false full-preview claim. */
    THUMBNAIL_ONLY("thumbnail");

    companion object {
        /** Decodes the core's stable still-policy code without inspecting a filename. */
        internal fun fromWire(code: String): StillPreviewStrategy? =
            entries.firstOrNull { it.wireCode == code }
    }
}

/** Core-authorized still policy and fallback label rendered by the Android viewer. */
public data class StillPhotoClassification(
    val formatLabel: String,
    val previewStrategy: StillPreviewStrategy,
)

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
    /** Sanitized on-card filename, e.g. `C0001.MOV`. */
    val filename: String,
    /** Shared-core browser action; Kotlin does not classify filename extensions. */
    val contentKind: MediaContentKind,
    /** Shared-core still decoder policy; null for non-still browser actions. */
    val stillPhoto: StillPhotoClassification?,
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
     * `handle, storageID, sizeBytes, captureDate, width, height, playable,
     * kind, stillStrategy, stillFormatLabel, filename`
     * (filename last; it is sanitized tab/newline-free by the facade).
     * Malformed lines are skipped, never fatal: the listing is network input.
     */
    fun parse(wire: String): List<MediaClipRecord> =
        wire.lineSequence()
            .mapNotNull { line ->
                val fields = line.split('\t')
                if (fields.size != 11) return@mapNotNull null
                val isPlayableProxy =
                    when (fields[6]) {
                        "1" -> true
                        "0" -> false
                        else -> return@mapNotNull null
                    }
                val contentKind = MediaContentKind.fromWire(fields[7]) ?: return@mapNotNull null
                if (isPlayableProxy != (contentKind == MediaContentKind.PLAYABLE_PROXY)) {
                    return@mapNotNull null
                }
                val stillPhoto =
                    when (contentKind) {
                        MediaContentKind.STILL_PHOTO -> {
                            val previewStrategy =
                                StillPreviewStrategy.fromWire(fields[8]) ?: return@mapNotNull null
                            val formatLabel = fields[9].ifEmpty { return@mapNotNull null }
                            StillPhotoClassification(formatLabel, previewStrategy)
                        }
                        MediaContentKind.PLAYABLE_PROXY,
                        MediaContentKind.R3D_MASTER,
                        MediaContentKind.UNSUPPORTED,
                        -> {
                            if (fields[8].isNotEmpty() || fields[9].isNotEmpty()) {
                                return@mapNotNull null
                            }
                            null
                        }
                    }
                MediaClipRecord(
                    handle = fields[0].toLongOrNull() ?: return@mapNotNull null,
                    storageId = fields[1].toLongOrNull() ?: return@mapNotNull null,
                    sizeBytes = fields[2].toLongOrNull() ?: return@mapNotNull null,
                    captureDate = fields[3],
                    pixelWidth = fields[4].toIntOrNull() ?: return@mapNotNull null,
                    pixelHeight = fields[5].toIntOrNull() ?: return@mapNotNull null,
                    filename = fields[10].ifEmpty { return@mapNotNull null },
                    contentKind = contentKind,
                    stillPhoto = stillPhoto,
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

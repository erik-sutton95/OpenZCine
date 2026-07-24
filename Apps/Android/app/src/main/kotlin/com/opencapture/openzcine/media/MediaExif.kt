package com.opencapture.openzcine.media

import android.graphics.Bitmap
import android.graphics.Matrix
import android.media.ExifInterface
import java.io.ByteArrayInputStream
import java.io.InputStream
import java.nio.file.Files
import java.nio.file.Path
import java.util.concurrent.ConcurrentHashMap

/**
 * EXIF orientation support for camera stills. `BitmapFactory` ignores the tag, and the body's
 * PTP thumbnails can arrive EXIF-stripped — so portrait shots rendered sideways everywhere.
 * Bytes that carry the tag rotate directly; stripped thumbs fall back to the orientation this
 * session learned from the same object's full file (iOS persists the same fact on the index
 * row — Android's record crosses a fixed JNI wire format, so the cache lives in memory).
 */
internal object MediaExifOrientation {
    // ponytail: session-scoped memory cache keyed by object library key; widen the facade
    // wire format to persist it only if sideways-until-first-view grids ever bother anyone.
    private val learned = ConcurrentHashMap<String, Int>()

    /** Remembers a full-file answer so stripped thumbnails of the same object rotate too. */
    fun learn(key: String, orientation: Int) {
        if (orientation in 1..8) learned[key] = orientation
    }

    fun learned(key: String?): Int? = key?.let(learned::get)

    /** The orientation tag (1–8) in [bytes]; null when absent or unreadable. */
    fun fromBytes(bytes: ByteArray): Int? = fromStream(ByteArrayInputStream(bytes))

    /** File variant — the streamed full still always carries its header. */
    fun fromFile(path: Path): Int? =
        runCatching { Files.newInputStream(path).use(::fromStream) }.getOrNull()

    private fun fromStream(stream: InputStream): Int? =
        runCatching {
            ExifInterface(stream)
                .getAttributeInt(ExifInterface.TAG_ORIENTATION, 0)
                .takeIf { it in 1..8 }
        }.getOrNull()

    /**
     * Pure upright transform for an EXIF orientation value: clockwise rotation plus a trailing
     * horizontal mirror (rotate first, then mirror — the standard TIFF/EXIF decomposition).
     * Null for upright/unknown values, so callers can skip the bitmap copy entirely.
     */
    fun uprightTransform(orientation: Int?): UprightTransform? =
        when (orientation) {
            2 -> UprightTransform(rotationDegrees = 0, mirrored = true)
            3 -> UprightTransform(rotationDegrees = 180, mirrored = false)
            4 -> UprightTransform(rotationDegrees = 180, mirrored = true)
            5 -> UprightTransform(rotationDegrees = 90, mirrored = true)
            6 -> UprightTransform(rotationDegrees = 90, mirrored = false)
            7 -> UprightTransform(rotationDegrees = 270, mirrored = true)
            8 -> UprightTransform(rotationDegrees = 270, mirrored = false)
            else -> null
        }
}

/** Clockwise rotation plus trailing horizontal mirror that makes a decoded bitmap upright. */
internal data class UprightTransform(val rotationDegrees: Int, val mirrored: Boolean)

/** Applies the upright transform for [orientation]; returns the receiver when already upright. */
internal fun Bitmap.upright(orientation: Int?): Bitmap {
    val transform = MediaExifOrientation.uprightTransform(orientation) ?: return this
    val matrix = Matrix()
    matrix.postRotate(transform.rotationDegrees.toFloat())
    if (transform.mirrored) matrix.postScale(-1f, 1f)
    return Bitmap.createBitmap(this, 0, 0, width, height, matrix, true)
}

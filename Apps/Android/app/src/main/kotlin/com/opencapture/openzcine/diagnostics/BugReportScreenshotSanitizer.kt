package com.opencapture.openzcine.diagnostics

import android.content.ContentResolver
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Matrix
import android.graphics.Paint
import android.media.ExifInterface
import android.net.Uri
import java.io.ByteArrayOutputStream
import kotlin.math.max
import kotlin.math.roundToInt

/** Result of preparing one picker image without retaining its URI or filename. */
internal sealed interface BugReportScreenshotSanitizationResult {
    data class Success(val screenshot: BugReportScreenshot) : BugReportScreenshotSanitizationResult

    data object UnsupportedImage : BugReportScreenshotSanitizationResult

    data object TooLarge : BugReportScreenshotSanitizationResult
}

/**
 * Reads a user-selected image once, bakes orientation, and emits a fresh
 * bounded RGBA PNG. The original URI, source filename, bytes, and embedded
 * EXIF/XMP/GPS metadata never leave this short-lived method.
 */
internal class BugReportScreenshotSanitizer(private val contentResolver: ContentResolver) {
    fun sanitize(uri: Uri): BugReportScreenshotSanitizationResult {
        val dimensions = readDimensions(uri) ?: return BugReportScreenshotSanitizationResult.UnsupportedImage
        val orientation = readOrientation(uri)
        val decoded = decode(uri, dimensions) ?: return BugReportScreenshotSanitizationResult.UnsupportedImage
        try {
            val oriented = applyOrientation(decoded, orientation)
            try {
                val bounded = downsampleToMaximumDimension(oriented)
                try {
                    return encodeBoundedPng(bounded)
                } finally {
                    if (bounded !== oriented) bounded.recycle()
                }
            } finally {
                if (oriented !== decoded) oriented.recycle()
            }
        } finally {
            decoded.recycle()
        }
    }

    private fun readDimensions(uri: Uri): ImageDimensions? =
        runCatching {
            contentResolver.openInputStream(uri)?.use { input ->
                val options = BitmapFactory.Options().apply { inJustDecodeBounds = true }
                BitmapFactory.decodeStream(input, null, options)
                val width = options.outWidth
                val height = options.outHeight
                if (width > 0 && height > 0) ImageDimensions(width, height) else null
            }
        }.getOrNull()

    private fun readOrientation(uri: Uri): Int =
        runCatching {
            contentResolver.openInputStream(uri)?.use { input ->
                ExifInterface(input).getAttributeInt(
                    ExifInterface.TAG_ORIENTATION,
                    ExifInterface.ORIENTATION_NORMAL,
                )
            }
        }.getOrNull() ?: ExifInterface.ORIENTATION_NORMAL

    private fun decode(uri: Uri, dimensions: ImageDimensions): Bitmap? =
        runCatching {
            contentResolver.openInputStream(uri)?.use { input ->
                BitmapFactory.decodeStream(
                    input,
                    null,
                    BitmapFactory.Options().apply {
                        inSampleSize = decodeSampleSize(dimensions)
                        inPreferredConfig = Bitmap.Config.ARGB_8888
                        inScaled = false
                    },
                )
            }
        }.getOrNull()

    private fun decodeSampleSize(dimensions: ImageDimensions): Int {
        var sampleSize = 1
        while (
            sampledDimension(dimensions.width, sampleSize) > MAXIMUM_DECODE_DIMENSION ||
                sampledDimension(dimensions.height, sampleSize) > MAXIMUM_DECODE_DIMENSION ||
                sampledPixels(dimensions, sampleSize) > MAXIMUM_DECODE_PIXELS
        ) {
            if (sampleSize >= MAXIMUM_SAMPLE_SIZE) return sampleSize
            sampleSize *= 2
        }
        return sampleSize
    }

    private fun sampledDimension(value: Int, sampleSize: Int): Long =
        (value.toLong() + sampleSize - 1L) / sampleSize

    private fun sampledPixels(dimensions: ImageDimensions, sampleSize: Int): Long =
        sampledDimension(dimensions.width, sampleSize) *
            sampledDimension(dimensions.height, sampleSize)

    private fun applyOrientation(source: Bitmap, orientation: Int): Bitmap {
        val matrix =
            Matrix().apply {
                when (orientation) {
                    ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> preScale(-1f, 1f)
                    ExifInterface.ORIENTATION_ROTATE_180 -> setRotate(180f)
                    ExifInterface.ORIENTATION_FLIP_VERTICAL -> preScale(1f, -1f)
                    ExifInterface.ORIENTATION_TRANSPOSE -> {
                        setRotate(90f)
                        postScale(-1f, 1f)
                    }
                    ExifInterface.ORIENTATION_ROTATE_90 -> setRotate(90f)
                    ExifInterface.ORIENTATION_TRANSVERSE -> {
                        setRotate(-90f)
                        postScale(-1f, 1f)
                    }
                    ExifInterface.ORIENTATION_ROTATE_270 -> setRotate(-90f)
                }
            }
        return if (matrix.isIdentity) {
            source
        } else {
            Bitmap.createBitmap(source, 0, 0, source.width, source.height, matrix, true)
        }
    }

    private fun downsampleToMaximumDimension(source: Bitmap): Bitmap {
        val longestSide = max(source.width, source.height)
        if (longestSide <= BugReportAttachmentLimits.MAXIMUM_IMAGE_DIMENSION) return source
        val scale = BugReportAttachmentLimits.MAXIMUM_IMAGE_DIMENSION.toFloat() / longestSide
        return Bitmap.createScaledBitmap(
            source,
            max(1, (source.width * scale).roundToInt()),
            max(1, (source.height * scale).roundToInt()),
            true,
        )
    }

    private fun encodeBoundedPng(source: Bitmap): BugReportScreenshotSanitizationResult {
        var candidate = copyAsArgb(source)
        try {
            repeat(MAXIMUM_PNG_SHRINK_ATTEMPTS) {
                val bytes = pngBytes(candidate) ?: return BugReportScreenshotSanitizationResult.UnsupportedImage
                if (bytes.size <= BugReportAttachmentLimits.MAXIMUM_SCREENSHOT_BYTES) {
                    return BugReportScreenshot.fromSanitizedPng(bytes)
                        ?.let(BugReportScreenshotSanitizationResult::Success)
                        ?: BugReportScreenshotSanitizationResult.UnsupportedImage
                }
                if (candidate.width == 1 && candidate.height == 1) {
                    return BugReportScreenshotSanitizationResult.TooLarge
                }
                val next =
                    Bitmap.createScaledBitmap(
                        candidate,
                        max(1, (candidate.width * PNG_SHRINK_SCALE).roundToInt()),
                        max(1, (candidate.height * PNG_SHRINK_SCALE).roundToInt()),
                        true,
                    )
                candidate.recycle()
                candidate = next
            }
            return BugReportScreenshotSanitizationResult.TooLarge
        } finally {
            candidate.recycle()
        }
    }

    private fun copyAsArgb(source: Bitmap): Bitmap =
        Bitmap.createBitmap(source.width, source.height, Bitmap.Config.ARGB_8888).also { copy ->
            Canvas(copy).drawBitmap(source, 0f, 0f, Paint(Paint.FILTER_BITMAP_FLAG))
        }

    private fun pngBytes(bitmap: Bitmap): ByteArray? =
        ByteArrayOutputStream().use { output ->
            if (bitmap.compress(Bitmap.CompressFormat.PNG, 100, output)) output.toByteArray() else null
        }

    private data class ImageDimensions(
        val width: Int,
        val height: Int,
    )

    private companion object {
        const val MAXIMUM_DECODE_DIMENSION: Long = 4_096
        const val MAXIMUM_DECODE_PIXELS: Long = 12L * 1_024L * 1_024L
        const val MAXIMUM_SAMPLE_SIZE: Int = 1 shl 28
        const val MAXIMUM_PNG_SHRINK_ATTEMPTS: Int = 12
        const val PNG_SHRINK_SCALE: Float = 0.8f
    }
}

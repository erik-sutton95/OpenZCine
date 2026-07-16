package com.opencapture.openzcine.diagnostics

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.ExifInterface
import android.net.Uri
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import java.io.File
import java.io.FileOutputStream
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class BugReportScreenshotSanitizerTest {
    @Test
    fun reRenderedPngDropsSourceExifAndBakesItsOrientation() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val source = File.createTempFile("Bob-iPhone-", ".jpg", context.cacheDir)
        try {
            writeJpegWithIdentifyingExif(source)

            val result = BugReportScreenshotSanitizer(context.contentResolver).sanitize(Uri.fromFile(source))

            assertTrue(result is BugReportScreenshotSanitizationResult.Success)
            val png = (result as BugReportScreenshotSanitizationResult.Success).screenshot.copyPngBytes()
            assertTrue(isPng(png))
            val outputText = String(png, Charsets.ISO_8859_1)
            assertFalse(outputText.contains("Bob's iPhone"))
            assertFalse(outputText.contains("Bob-iPhone"))
            assertFalse(outputText.contains("EXIF", ignoreCase = true))
            val bitmap = BitmapFactory.decodeByteArray(png, 0, png.size)
            assertNotNull(bitmap)
            val outputBitmap = requireNotNull(bitmap)
            try {
                assertEquals(4, outputBitmap.width)
                assertEquals(8, outputBitmap.height)
            } finally {
                outputBitmap.recycle()
            }
        } finally {
            source.delete()
        }
    }

    private fun writeJpegWithIdentifyingExif(target: File) {
        val bitmap = Bitmap.createBitmap(8, 4, Bitmap.Config.ARGB_8888)
        try {
            bitmap.eraseColor(0xFF334455.toInt())
            FileOutputStream(target).use { output ->
                assertTrue(bitmap.compress(Bitmap.CompressFormat.JPEG, 95, output))
            }
        } finally {
            bitmap.recycle()
        }
        ExifInterface(target.absolutePath).apply {
            setAttribute(ExifInterface.TAG_MODEL, "Bob's iPhone")
            setAttribute(ExifInterface.TAG_MAKE, "Bob Camera Co")
            setAttribute(
                ExifInterface.TAG_ORIENTATION,
                ExifInterface.ORIENTATION_ROTATE_90.toString(),
            )
            saveAttributes()
        }
    }
}

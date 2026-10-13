package com.opencapture.openzcine

import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.PixelFormat
import android.hardware.HardwareBuffer
import android.media.ImageReader
import android.os.Handler
import android.os.HandlerThread
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.opencapture.opencine.runtime.bitmapVulkanUniforms
import com.opencapture.openpocketcine.feed.OpcVulkan
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/** SIMULATED known pixels through actual JNI, Vulkan sampling and native WSI readback. */
@RunWith(AndroidJUnit4::class)
class NikonBitmapColorContractTest {
    @Test fun bitmapPrimariesAndNeutralGrayKeepTheirActualChannels() {
        assertTrue("Actual Vulkan renderer required", OpcVulkan.isAvailable)
        val handle = OpcVulkan.nativeCreateBitmap()
        assertNotEquals(0L, handle)
        val thread = HandlerThread("bitmap-color-contract").apply { start() }
        val pixels = LinkedBlockingQueue<ByteArray>()
        val reader = ImageReader.newInstance(9, 15, PixelFormat.RGBA_8888, 4,
            HardwareBuffer.USAGE_GPU_COLOR_OUTPUT or HardwareBuffer.USAGE_CPU_READ_OFTEN)
        reader.setOnImageAvailableListener({ source ->
            source.acquireNextImage()?.use { image ->
                val plane = image.planes.single()
                assertEquals(4, plane.pixelStride)
                val buffer = plane.buffer
                buffer.position(7 * plane.rowStride + 4 * plane.pixelStride)
                pixels.add(ByteArray(4).also { buffer.get(it) })
            }
        }, Handler(thread.looper))
        try {
            assertTrue(OpcVulkan.nativeAttachBitmapWindow(handle, reader.surface))
            OpcVulkan.nativeResize(handle, 9, 15)
            assertTrue(OpcVulkan.nativeConfigureBitmap(handle,
                bitmapVulkanUniforms(null, false, false), 0, null, 0, null, 0, null))
            assertTrue(OpcVulkan.nativeSetBitmapPaused(handle, false))
            for (color in listOf(Color.GREEN, Color.rgb(128, 128, 128), Color.RED, Color.BLUE)) {
                val bitmap = Bitmap.createBitmap(3, 5, Bitmap.Config.ARGB_8888)
                try {
                    bitmap.eraseColor(color)
                    assertTrue(OpcVulkan.nativeSubmitBitmap(handle, bitmap))
                    val actual = requireNotNull(pixels.poll(10, TimeUnit.SECONDS)) { "No actual native present" }
                    val expected = byteArrayOf(Color.red(color).toByte(), Color.green(color).toByte(),
                        Color.blue(color).toByte(), 255.toByte())
                    assertArrayEquals("Actual input color ${color.toUInt().toString(16)}", expected, actual)
                } finally { bitmap.recycle() }
            }
        } finally {
            OpcVulkan.nativeDestroy(handle)
            reader.close()
            thread.quitSafely()
            thread.join(2000)
            assertTrue("Readback thread must stop", !thread.isAlive)
        }
    }
}

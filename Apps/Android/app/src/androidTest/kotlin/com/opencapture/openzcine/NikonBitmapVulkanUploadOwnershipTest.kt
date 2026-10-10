package com.opencapture.openzcine

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.opencapture.opencine.media.FeedEffectsRenderPlan
import com.opencapture.opencine.runtime.bitmapVulkanUniforms
import com.opencapture.openpocketcine.feed.OpcVulkan
import java.io.ByteArrayOutputStream
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

/** Real Vulkan upload/fence gates over decoded pixels. No surface/readback pixel claim. */
@RunWith(AndroidJUnit4::class)
class NikonBitmapVulkanUploadOwnershipTest {
    private fun decoded(width: Int, height: Int): Bitmap {
        val raster = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        raster.eraseColor(Color.rgb(180, 64, 210))
        val output = ByteArrayOutputStream()
        try { check(raster.compress(Bitmap.CompressFormat.PNG, 100, output)) }
        finally { raster.recycle() }
        val bytes = output.toByteArray()
        return requireNotNull(BitmapFactory.decodeByteArray(bytes, 0, bytes.size)).also {
            assertEquals(width, it.width)
            assertEquals(height, it.height)
            assertEquals(Bitmap.Config.ARGB_8888, it.config)
        }
    }

    private fun configure(handle: Long, controls: FloatArray, size: Int = 0, bytes: ByteArray? = null): Boolean =
        OpcVulkan.nativeConfigureBitmap(handle, controls, size, bytes, 0, null, 0, null)

    @Test fun rejectedControlShapeCannotPoisonDecodedUploadOrDimensionReplacement() {
        assertTrue("actual shared Vulkan library required", OpcVulkan.isAvailable)
        assertTrue("actual Vulkan probe required", OpcVulkan.nativeProbeBitmap())
        val handle = OpcVulkan.nativeCreateBitmap()
        assertNotEquals("actual Vulkan device creation required", 0L, handle)
        val first = decoded(13, 7)
        val successor = decoded(7, 13)
        try {
            val controls = bitmapVulkanUniforms(FeedEffectsRenderPlan.IDENTITY, false, false)
            assertFalse(configure(handle, FloatArray(39)))
            assertTrue(configure(handle, controls))
            assertTrue(OpcVulkan.nativeSubmitBitmap(handle, first))
            assertFalse(configure(handle, FloatArray(41)))
            assertTrue(OpcVulkan.nativeSubmitBitmap(handle, successor))
            assertTrue(configure(handle, controls))
            assertTrue(OpcVulkan.nativeSubmitBitmap(handle, first))
            OpcVulkan.nativeClearBitmap(handle)
            assertTrue(OpcVulkan.nativeSubmitBitmap(handle, successor))
        } finally {
            OpcVulkan.nativeDestroy(handle)
            first.recycle(); successor.recycle()
        }
    }

    @Test fun impossibleCubePayloadStaysSoftDisabledAndRealCubeSuccessorStillUploads() {
        assertTrue(OpcVulkan.isAvailable)
        val handle = OpcVulkan.nativeCreateBitmap()
        assertNotEquals(0L, handle)
        val source = decoded(17, 11)
        try {
            val controls = bitmapVulkanUniforms(FeedEffectsRenderPlan.IDENTITY, false, false)
            // This dimension makes unchecked cubic arithmetic wrap to zero.
            // The actual source primitive must soft-disable that one invalid
            // cube, without allocating, poisoning the owner or losing source.
            assertTrue(configure(handle, controls, 1 shl 30, ByteArray(0)))
            assertTrue(OpcVulkan.nativeSubmitBitmap(handle, source))
            val cube = ByteArray(2 * 2 * 2 * 4) { i -> if (i % 4 == 3) 255.toByte() else 64.toByte() }
            controls[0] = 2f
            assertTrue(configure(handle, controls, 2, cube))
            assertTrue(OpcVulkan.nativeSubmitBitmap(handle, source))
            assertTrue(configure(handle, controls, 65, ByteArray(0)))
            assertTrue(OpcVulkan.nativeSubmitBitmap(handle, source))
            assertTrue(configure(handle, controls, 2, cube))
            assertTrue(OpcVulkan.nativeSubmitBitmap(handle, source))
        } finally {
            OpcVulkan.nativeDestroy(handle)
            source.recycle()
        }
    }
}

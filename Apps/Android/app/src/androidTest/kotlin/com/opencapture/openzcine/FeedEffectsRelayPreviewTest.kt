package com.opencapture.openzcine

import android.graphics.Bitmap
import android.graphics.Color
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.filters.SdkSuppress
import kotlin.math.abs
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/** Device proof that the exact AGSL phone treatment can be baked into a relay bitmap. */
@RunWith(AndroidJUnit4::class)
@SdkSuppress(minSdkVersion = 33)
class FeedEffectsRelayPreviewTest {
    @Test
    fun monochromePhoneTreatmentIsBakedIntoBoundedWearPreview() {
        val source = Bitmap.createBitmap(640, 360, Bitmap.Config.ARGB_8888)
        source.eraseColor(Color.rgb(235, 80, 24))
        val renderer =
            FeedEffectsRenderer.create(
                FeedEffects(lut = FeedLutSelection.BuiltIn(FeedLut.MONO)),
            )

        assertNotNull(renderer)
        try {
            val preview = requireNotNull(renderer).bakePreview(source, maximumWidth = 256)
            assertNotNull(preview)
            requireNotNull(preview)
            try {
                assertEquals(256, preview.width)
                assertEquals(144, preview.height)
                val pixel = preview.getPixel(preview.width / 2, preview.height / 2)
                assertTrue(abs(Color.red(pixel) - Color.green(pixel)) <= 2)
                assertTrue(abs(Color.green(pixel) - Color.blue(pixel)) <= 2)
            } finally {
                preview.recycle()
            }
        } finally {
            renderer?.close()
            source.recycle()
        }
    }
}

package com.opencapture.openzcine

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.opencapture.opencine.media.MonitorLUTCube
import com.opencapture.opencine.media.MonitorZebraMaskPolicy
import com.opencapture.opencine.runtime.MonitorBitmapEffects
import java.io.ByteArrayOutputStream
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

/** Actual decoded PNG and hardware AGSL output; SIMULATED native gate, never a CPU substitute. */
@RunWith(AndroidJUnit4::class)
@android.annotation.TargetApi(33)
class NikonBitmapEffectsPixelParityTest {
    private fun source(width: Int, height: Int): Bitmap {
        val raster = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        val palette = intArrayOf(
            Color.RED, Color.GREEN, Color.BLUE, Color.WHITE,
            Color.rgb(128, 128, 128), Color.rgb(240, 200, 32),
        )
        val pixels = IntArray(width * height) { i ->
            val x = i % width
            val y = i / width
            palette[(x / 7 + y / 5) % palette.size]
        }
        raster.setPixels(pixels, 0, width, 0, 0, width, height)
        val bytes = ByteArrayOutputStream()
        try { check(raster.compress(Bitmap.CompressFormat.PNG, 100, bytes)) }
        finally { raster.recycle() }
        val encoded = bytes.toByteArray()
        return requireNotNull(BitmapFactory.decodeByteArray(encoded, 0, encoded.size)).also {
            assertEquals(width, it.width)
            assertEquals(height, it.height)
            assertEquals(Bitmap.Config.ARGB_8888, it.config)
        }
    }

    private fun configuration() = FeedEffectsRenderConfiguration(
        curveOrdinal = 0,
        clipNative = 1f,
        deLogCurve = floatArrayOf(0f, 0f, 1f, 0f, 1f),
        peakingRatioThreshold = 2.10f,
        peakingNoiseGate = 0.00174f,
        peakingColor = floatArrayOf(1f, 0.28f, 0.25f),
        highlightEnabled = true,
        highlightCode = 0.55f,
        highlightColor = floatArrayOf(0.1f, 0.9f, 0.8f),
        midtoneEnabled = true,
        midtoneCode = 0.50f,
        midtoneColor = floatArrayOf(1f, 0.7f, 0.1f),
    )

    private fun constantCube(red: Int, green: Int, blue: Int): MonitorLUTCube {
        val bytes = ByteArray(2 * 2 * 2 * 4)
        for (i in bytes.indices step 4) {
            bytes[i] = red.toByte()
            bytes[i + 1] = green.toByte()
            bytes[i + 2] = blue.toByte()
            bytes[i + 3] = 255.toByte()
        }
        return MonitorLUTCube(2, bytes)
    }

    private fun pixels(bitmap: Bitmap): IntArray = IntArray(bitmap.width * bitmap.height).also {
        bitmap.getPixels(it, 0, bitmap.width, 0, 0, bitmap.width, bitmap.height)
    }

    /**
     * The adopter against the frozen donor graph. Zebra left the donor's luma measure for the
     * shared one (A3-11), so a zebra plan is held to the shared default renderer instead.
     */
    private fun renderPair(source: Bitmap, plan: FeedEffectsRenderPlan, width: Int): IntArray {
        val shared = if (plan.effects.zebra) MonitorBitmapEffects.create(plan.nativePlan, plan.falseColorReady) else null
        val frozen = if (shared == null) FrozenNikonFeedEffectsRenderer.create(plan) else null
        val donor: AutoCloseable = shared ?: requireNotNull(frozen)
        fun bakeDonor(w: Int) = shared?.bakePreview(source, w) ?: frozen?.bakePreview(source, w)
        val adopter = FeedEffectsRenderer.create(plan)
        var before: Bitmap? = null
        var after: Bitmap? = null
        try {
            before = requireNotNull(bakeDonor(width)) { "donor hardware render absent" }
            after = requireNotNull(adopter.bakePreview(source, width)) { "shared hardware render absent" }
            assertEquals(before.width, after.width)
            assertEquals(before.height, after.height)
            val expected = pixels(before)
            assertArrayEquals("original hardware graph pixels", expected, pixels(after))
            return expected
        } finally {
            before?.recycle(); after?.recycle()
            donor.close(); adopter.close()
        }
    }

    @Test fun decodedColoredZebraPeakingAndGradeMatchWholeOriginalHardwareGraph() {
        for ((width, height) in listOf(63 to 41, 41 to 63)) {
            val image = source(width, height)
            try {
                val plain = FeedEffectsRenderPlan(FeedEffects.NONE, configuration(), null, null, null)
                val plainPixels = renderPair(image, plain, width)
                val gray = constantCube(32, 32, 32)
                val cases = listOf(
                    FeedEffectsRenderPlan(FeedEffects(zebra = true), configuration(), null, null, null),
                    FeedEffectsRenderPlan(FeedEffects(peaking = true), configuration(), null, null, null),
                    FeedEffectsRenderPlan(
                        FeedEffects(peaking = true, zebra = true), configuration(), gray, null, null,
                    ),
                )
                for ((index, plan) in cases.withIndex()) {
                    val treated = renderPair(image, plan, width)
                    assertTrue("effect $index must paint", treated.indices.any { treated[it] != plainPixels[it] })
                    renderPair(image, plan, width / 2)
                }
            } finally { image.recycle() }
        }
    }

    @Test fun limitsPaintWeightAndBothSplitAxesMatchOriginalSourceCoordinatePolicy() {
        val image = source(61, 47)
        val grade = constantCube(32, 48, 64)
        val paint = constantCube(204, 51, 102)
        val weight = constantCube(128, 0, 0)
        try {
            val plain = renderPair(image, FeedEffectsRenderPlan(FeedEffects.NONE, configuration(), null, null, null), 61)
            for (axis in FeedSplitOrientation.entries) {
                val split = FeedEffects(
                    lut = FeedLutSelection.BuiltIn(FeedLut.NLOG_709), splitComparison = axis,
                )
                val splitPixels = renderPair(image, FeedEffectsRenderPlan(split, configuration(), grade, null, null), 61)
                assertTrue(splitPixels.indices.any { splitPixels[it] != plain[it] })
                assertTrue(splitPixels.indices.any { splitPixels[it] == plain[it] })
                val limits = FeedEffectsRenderPlan(
                    split.copy(falseColor = FeedFalseColorScale.LIMITS), configuration(), grade, paint, weight,
                )
                val limitsPixels = renderPair(image, limits, 61)
                assertTrue(limitsPixels.indices.any { limitsPixels[it] != splitPixels[it] })
                renderPair(image, limits, 29)
            }
        } finally { image.recycle() }
    }

    /** A3-11: Z zebra is the shared measure, which differs from the donor's luma on colour. */
    @Test fun zebraIsTheSharedMeasureNotTheDonorLumaAndCloseIsTerminal() {
        val image = source(63, 41)
        val plan = FeedEffectsRenderPlan(FeedEffects(zebra = true), configuration(), null, null, null)
        val donor = FrozenNikonFeedEffectsRenderer.create(plan)
        val adopter = FeedEffectsRenderer.create(plan)
        val defaults = MonitorBitmapEffects.create(plan.nativePlan, false, MonitorZebraMaskPolicy())
        var luma: Bitmap? = null
        var z: Bitmap? = null
        var maximum: Bitmap? = null
        try {
            luma = requireNotNull(donor.bakePreview(image, image.width))
            z = requireNotNull(adopter.bakePreview(image, image.width))
            maximum = requireNotNull(defaults.bakePreview(image, image.width))
            assertArrayEquals("Z zebra is the shared default measure", pixels(maximum), pixels(z))
            assertFalse("the donor luma measure differs on the coloured raster", pixels(luma).contentEquals(pixels(z)))
            adopter.close()
            assertNull(adopter.bakePreview(image, image.width))
            defaults.close()
            assertNull(defaults.bakePreview(image, image.width))
        } finally {
            luma?.recycle(); z?.recycle(); maximum?.recycle()
            donor.close(); adopter.close(); defaults.close(); image.recycle()
        }
    }
}

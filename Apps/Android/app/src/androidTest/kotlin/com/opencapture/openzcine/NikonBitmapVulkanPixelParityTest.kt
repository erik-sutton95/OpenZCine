package com.opencapture.openzcine

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import android.graphics.PixelFormat
import android.hardware.HardwareBuffer
import android.media.Image
import android.media.ImageReader
import android.os.Handler
import android.os.HandlerThread
import android.view.Surface
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.opencapture.opencine.media.MonitorLUTCube
import com.opencapture.opencine.media.MonitorZebraMaskPolicy
import com.opencapture.opencine.runtime.bitmapVulkanUniforms
import com.opencapture.openpocketcine.feed.OpcVulkan
import java.io.ByteArrayOutputStream
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.Semaphore
import java.util.concurrent.TimeUnit
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Real Vulkan WSI readback, SIMULATED device gate: for the same decoded raster, plan and surface,
 * the shared OpcVulkan Bitmap pipeline presents exactly the swapchain images of the input-corrected frozen donor
 * Nikon Vulkan renderer, including how many it presents. No tolerance, no skip.
 */
@RunWith(AndroidJUnit4::class)
class NikonBitmapVulkanPixelParityTest {
    private interface Feed : AutoCloseable {
        fun attach(surface: Surface, width: Int, height: Int)
        fun plan(plan: FeedEffectsRenderPlan, aspectFill: Boolean, mirrored: Boolean)
        fun resume()
        fun pause()
        fun clearFrame()
        fun clearPlan()
        fun submit(frame: Bitmap): Boolean
    }

    /** The retired app path: the donor's own Kotlin call shapes over its frozen renderer. */
    private class DonorFeed : Feed {
        private val native = FrozenNikonVulkanLiveFeedNative
        private val session: Long

        init {
            native.nativeInitAssets(InstrumentationRegistry.getInstrumentation().context.assets)
            assertTrue("actual donor Vulkan renderer required", native.isAvailable())
            session = native.createSession()
            assertNotEquals("actual donor Vulkan session required", 0L, session)
        }

        override fun attach(surface: Surface, width: Int, height: Int) {
            assertTrue(native.attachSurface(session, surface))
            native.resize(session, width, height)
        }

        override fun plan(plan: FeedEffectsRenderPlan, aspectFill: Boolean, mirrored: Boolean) {
            assertTrue(
                native.setPlan(
                    session,
                    plan.baseCube?.size ?: 0, plan.baseCube?.rgba,
                    plan.limitsPaintCube?.size ?: 0, plan.limitsPaintCube?.rgba,
                    plan.limitsWeightCube?.size ?: 0, plan.limitsWeightCube?.rgba,
                    plan.limitsReady, plan.effects.peaking,
                    plan.configuration.peakingColor, plan.configuration.deLogCurve,
                    plan.configuration.peakingRatioThreshold, plan.configuration.peakingNoiseGate,
                    plan.effects.zebra && plan.configuration.highlightEnabled,
                    plan.configuration.highlightCode, plan.configuration.highlightColor,
                    plan.effects.zebra && plan.configuration.midtoneEnabled,
                    plan.configuration.midtoneCode, plan.configuration.midtoneColor,
                    aspectFill, mirrored,
                    plan.splitComparison != null,
                    plan.splitComparison == FeedSplitOrientation.VERTICAL,
                ),
            )
        }

        override fun resume() = native.resume(session)
        override fun pause() = native.pause(session)
        override fun clearFrame() = native.clearFrame(session)
        override fun clearPlan() = native.clearPlan(session)
        override fun submit(frame: Bitmap): Boolean {
            // The frozen donor labels RGBA_8888 as BGRA, a known channel defect.
            // Correct only its fixture input so its unchanged shader/lifetime oracle
            // sees the same logical RGB as the corrected production Bitmap path.
            val pixels = IntArray(frame.width * frame.height)
            frame.getPixels(pixels, 0, frame.width, 0, 0, frame.width, frame.height)
            for (index in pixels.indices) {
                val pixel = pixels[index]
                pixels[index] = Color.argb(Color.alpha(pixel), Color.blue(pixel), Color.green(pixel), Color.red(pixel))
            }
            val corrected = Bitmap.createBitmap(pixels, frame.width, frame.height, Bitmap.Config.ARGB_8888)
            return try { native.submitBitmap(session, corrected) } finally { corrected.recycle() }
        }
        override fun close() = native.destroySession(session)
    }

    /** The adopted path: MonitorBitmapVulkanSession's exact OpcVulkan calls and uniform packing. */
    private class SharedFeed(private val zebraPolicy: MonitorZebraMaskPolicy? = null) : Feed {
        private val handle: Long

        init {
            assertTrue("actual shared Vulkan library required", OpcVulkan.isAvailable)
            assertTrue("actual shared Vulkan Bitmap probe required", OpcVulkan.nativeProbeBitmap())
            handle = OpcVulkan.nativeCreateBitmap()
            assertNotEquals("actual shared Vulkan device required", 0L, handle)
        }

        override fun attach(surface: Surface, width: Int, height: Int) {
            assertTrue(OpcVulkan.nativeAttachBitmapWindow(handle, surface))
            OpcVulkan.nativeResize(handle, width, height)
        }

        override fun plan(plan: FeedEffectsRenderPlan, aspectFill: Boolean, mirrored: Boolean) {
            val adopted = plan.nativePlan
            val native = zebraPolicy?.let { policy ->
                com.opencapture.opencine.media.FeedEffectsRenderPlan(
                    adopted.lutCube, adopted.falseColorPaint, adopted.falseColorWeight,
                    adopted.peaking, adopted.peakingColor, adopted.peakingRatioThreshold,
                    adopted.peakingNoiseGate, adopted.zebraHighlightOn, adopted.zebraHighlightCode,
                    adopted.zebraHighlightColor, adopted.zebraMidtoneOn, adopted.zebraMidtoneCode,
                    adopted.zebraMidtoneHalf, adopted.zebraMidtoneColor, adopted.splitComparison,
                    adopted.splitVertical, adopted.scopeTap, policy,
                )
            } ?: adopted
            assertTrue(
                OpcVulkan.nativeConfigureBitmap(
                    handle, bitmapVulkanUniforms(native, aspectFill, mirrored),
                    native.lutCube?.size ?: 0, native.lutCube?.rgba,
                    native.falseColorPaint?.size ?: 0, native.falseColorPaint?.rgba,
                    native.falseColorWeight?.size ?: 0, native.falseColorWeight?.rgba,
                ),
            )
        }

        override fun resume() = assertTrue(OpcVulkan.nativeSetBitmapPaused(handle, false))
        override fun pause() = assertTrue(OpcVulkan.nativeSetBitmapPaused(handle, true))
        override fun clearFrame() = OpcVulkan.nativeClearBitmap(handle)
        override fun clearPlan() = OpcVulkan.nativeClearBitmapPlan(handle)
        override fun submit(frame: Bitmap) = OpcVulkan.nativeSubmitBitmap(handle, frame)
        override fun close() = OpcVulkan.nativeDestroy(handle)
    }

    /** CPU-readable consumer of every swapchain image the producer presents, in order. */
    private class Readback(val width: Int, val height: Int) : AutoCloseable {
        private val thread = HandlerThread("nikon-vulkan-parity").apply { start() }
        private val frames = LinkedBlockingQueue<ByteArray>()
        private val arrivals = Semaphore(0)
        val reader: ImageReader = ImageReader.newInstance(
            width, height, PixelFormat.RGBA_8888, 4,
            HardwareBuffer.USAGE_GPU_COLOR_OUTPUT or HardwareBuffer.USAGE_CPU_READ_OFTEN,
        ).apply {
            setOnImageAvailableListener({ source ->
                source.acquireNextImage()?.let { image ->
                    image.use { frames.add(it.packedRgba()) }
                    arrivals.release()
                }
            }, Handler(thread.looper))
        }

        fun awaitNextPresentation() {
            check(arrivals.tryAcquire(10, TimeUnit.SECONDS)) {
                "an accepted visible submit did not reach the Vulkan consumer"
            }
        }

        /** The first [expected] presents, then any further ones until the producer is quiet. */
        fun presented(expected: Int): List<ByteArray> {
            val result = mutableListOf<ByteArray>()
            repeat(expected) {
                result += requireNotNull(frames.poll(10, TimeUnit.SECONDS)) {
                    "only ${result.size} of $expected Vulkan presents reached the consumer"
                }
            }
            while (true) result += frames.poll(500, TimeUnit.MILLISECONDS) ?: return result
        }

        override fun close() {
            reader.close()
            thread.quitSafely()
        }

        private fun Image.packedRgba(): ByteArray {
            val plane = planes[0]
            assertEquals(4, plane.pixelStride)
            val row = width * 4
            val out = ByteArray(row * height)
            val buffer = plane.buffer
            for (y in 0 until height) {
                buffer.position(y * plane.rowStride)
                buffer.get(out, y * row, row)
            }
            return out
        }
    }

    /** Lossless decode of hard edges and saturated colour; [variant] rotates the bars. */
    private fun decoded(variant: Int = 0): Bitmap {
        val raster = Bitmap.createBitmap(17, 9, Bitmap.Config.ARGB_8888)
        val bars = intArrayOf(Color.BLACK, Color.WHITE, Color.RED, Color.BLACK, Color.BLUE, Color.WHITE)
        for (y in 0 until 9) for (x in 0 until 17) {
            raster.setPixel(x, y,
                if (y in 3..5 && x in 7..9) Color.WHITE else bars[(x / 3 + variant) % bars.size])
        }
        val encoded = ByteArrayOutputStream()
        try { check(raster.compress(Bitmap.CompressFormat.PNG, 100, encoded)) } finally { raster.recycle() }
        val bytes = encoded.toByteArray()
        return requireNotNull(BitmapFactory.decodeByteArray(bytes, 0, bytes.size)).also {
            assertEquals(Bitmap.Config.ARGB_8888, it.config)
        }
    }

    private fun configuration(zebra: Boolean) = FeedEffectsRenderConfiguration(
        curveOrdinal = 0, clipNative = 255f, deLogCurve = floatArrayOf(0f, 0.25f, 0.5f, 0.75f, 1f),
        peakingRatioThreshold = 1.35f, peakingNoiseGate = 0.008f, peakingColor = floatArrayOf(1f, 0f, 0f),
        highlightEnabled = zebra, highlightCode = 0.9f, highlightColor = floatArrayOf(1f, 1f, 1f),
        midtoneEnabled = zebra, midtoneCode = 0.3f, midtoneColor = floatArrayOf(1f, 0.72f, 0.2f),
    )

    /** 2³ cube in the packed `(g·n² + b·n + r)·4` lattice; [map] gives the output per corner. */
    private fun cube(map: (Int, Int, Int) -> Triple<Int, Int, Int>): MonitorLUTCube {
        val size = 2
        val rgba = ByteArray(size * size * size * 4)
        for (green in 0 until size) for (blue in 0 until size) for (red in 0 until size) {
            val offset = (green * size * size + blue * size + red) * 4
            val (r, g, b) = map(red, green, blue)
            rgba[offset] = (r * 255).toByte()
            rgba[offset + 1] = (g * 255).toByte()
            rgba[offset + 2] = (b * 255).toByte()
            rgba[offset + 3] = 0xff.toByte()
        }
        return MonitorLUTCube(size, rgba)
    }

    private fun plans(): Map<String, FeedEffectsRenderPlan> {
        val swizzle = cube { r, g, b -> Triple(g, b, r) }
        val lut = FeedLutSelection.BuiltIn(FeedLut.entries.first())
        return mapOf(
            "identity" to FeedEffectsRenderPlan(FeedEffects(), configuration(false), null, null, null),
            "lut" to FeedEffectsRenderPlan(FeedEffects(lut = lut), configuration(false), swizzle, null, null),
            "split" to FeedEffectsRenderPlan(
                FeedEffects(lut = lut, splitComparison = FeedSplitOrientation.VERTICAL),
                configuration(false), swizzle, null, null),
            "limits" to FeedEffectsRenderPlan(
                FeedEffects(lut = lut, falseColor = FeedFalseColorScale.LIMITS),
                configuration(false), swizzle,
                cube { r, g, b -> Triple(1 - r, g, 1 - b) },
                cube { r, _, _ -> Triple(r, r, r) }),
            "zebra" to FeedEffectsRenderPlan(FeedEffects(zebra = true), configuration(true), null, null, null),
            "peaking" to FeedEffectsRenderPlan(FeedEffects(peaking = true), configuration(false), null, null, null),
        )
    }

    private fun render(
        feed: () -> Feed, width: Int, height: Int, expected: Int,
        observeSubmissions: Boolean = false, steps: Feed.() -> Unit,
    ): List<ByteArray> = Readback(width, height).use { readback ->
        feed().use { owner ->
            owner.attach(readback.reader.surface, width, height)
            val observed = if (observeSubmissions) object : Feed by owner {
                private var paused = true
                override fun resume() { owner.resume(); paused = false }
                override fun pause() { owner.pause(); paused = true }
                override fun submit(frame: Bitmap): Boolean {
                    val accepted = owner.submit(frame)
                    if (accepted && !paused) readback.awaitNextPresentation()
                    return accepted
                }
            } else owner
            observed.steps()
            readback.presented(expected)
        }
    }

    private fun single(
        feed: () -> Feed, plan: FeedEffectsRenderPlan, width: Int, height: Int,
        aspectFill: Boolean, mirrored: Boolean,
    ): List<ByteArray> {
        val input = decoded()
        try {
            return render(feed, width, height, expected = 1) {
                plan(plan, aspectFill, mirrored)
                resume()
                assertTrue(submit(input))
            }
        } finally { input.recycle() }
    }

    private fun assertSamePresents(label: String, donor: List<ByteArray>, shared: List<ByteArray>) {
        assertEquals("$label present count", donor.size, shared.size)
        donor.indices.forEach { assertArrayEquals("$label present $it", donor[it], shared[it]) }
    }

    @Test fun decodedRasterLookMatchesFrozenDonorVulkanExactly() {
        val surfaces = listOf(
            Triple(61 to 35, false, false), Triple(61 to 35, false, true),
            Triple(35 to 61, false, false), Triple(35 to 61, true, false),
        )
        for ((name, plan) in plans()) {
            for ((size, fill, mirrored) in surfaces) {
                val (width, height) = size
                val label = "$name ${width}x$height fill=$fill mirrored=$mirrored"
                val donor = single({ DonorFeed() }, plan, width, height, fill, mirrored)
                // Nonvacuity: the donor actually painted picture, not only its clear colour.
                val painted = donor.last().asList().chunked(4).any { it.take(3).any { channel -> channel != 0.toByte() } }
                assertTrue(label, painted)
                assertSamePresents(label, donor, single({ SharedFeed() }, plan, width, height, fill, mirrored))
            }
        }
    }

    @Test fun pausedSubmitResumeAndClearsPresentTheDonorSequence() {
        val plan = plans().getValue("lut")
        val first = decoded(0)
        val second = decoded(1)
        try {
            val steps: Feed.() -> Unit = {
                plan(plan, aspectFill = false, mirrored = false)
                resume()
                assertTrue(submit(first))
                pause()
                assertTrue(submit(second))
                resume()
                assertTrue(submit(second))
                clearFrame()
                assertTrue(submit(first))
                clearPlan()
                assertTrue(submit(first))
            }
            val donor = render({ DonorFeed() }, 61, 35, expected = 4, observeSubmissions = true, steps = steps)
            assertEquals("a paused submit presents nothing", 4, donor.size)
            assertFalse(donor[0].contentEquals(donor[1]))
            assertFalse("clearing the plan drops the LUT", donor[2].contentEquals(donor[3]))
            assertSamePresents("sequence", donor, render({ SharedFeed() }, 61, 35, expected = 4, observeSubmissions = true, steps = steps))
        } finally {
            first.recycle()
            second.recycle()
        }
    }

    @Test fun sharedNeutralZebraPolicyIsNotTheDonorOnSaturatedColour() {
        // Nonvacuity: the gate above holds because the app passes the donor's luma policy; the
        // shared neutral default (maximum component, ramp bias) paints the saturated red bar.
        val plan = plans().getValue("zebra")
        val donor = single({ DonorFeed() }, plan, 61, 35, aspectFill = false, mirrored = false).last()
        val adopted = single({ SharedFeed() }, plan, 61, 35, aspectFill = false, mirrored = false).last()
        val neutral = single(
            { SharedFeed(MonitorZebraMaskPolicy()) }, plan, 61, 35, aspectFill = false, mirrored = false,
        ).last()
        assertArrayEquals(donor, adopted)
        assertFalse(donor.contentEquals(neutral))
    }
}

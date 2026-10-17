package com.opencapture.openzcine

import android.graphics.Bitmap
import android.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.opencapture.openzcine.bridge.SwiftCore
import com.opencapture.opencine.cameracontrols.MonitorLutImportResult
import com.opencapture.opencine.cameracontrols.MonitorLutLibrary
import com.opencapture.openzcine.lut.StoredLutCategory
import com.opencapture.openzcine.multicam.MulticamLookRenderer
import com.opencapture.openzcine.multicam.MulticamPicture
import com.opencapture.openzcine.multicam.NativeMulticamLookRenderer
import com.opencapture.openzcine.multicam.multicamLookRendererFactory
import java.util.Collections
import java.io.File
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import kotlin.math.abs
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * SIMULATED tile frames through the actual per-member look owner and the shipped native AGSL chain
 * (FeedEffectsRenderPlans + FeedEffectsRenderer.bakePreview). Pixels are read back from what each
 * member actually publishes to its tile.
 */
@RunWith(AndroidJUnit4::class)
class MulticamPictureLookTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private lateinit var scope: CoroutineScope

    @Before fun setUp() {
        assumeTrue("Native looks need API 33 and the staged Swift core", multicamLookRendererFactory(null) != null)
        scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    }

    @After fun tearDown() { if (::scope.isInitialized) scope.cancel() }

    private fun solid(color: Int): Bitmap =
        Bitmap.createBitmap(8, 8, Bitmap.Config.ARGB_8888).apply { eraseColor(color) }.copy(Bitmap.Config.ARGB_8888, false)

    private fun main(block: () -> Unit) = instrumentation.runOnMainSync(block)

    private class Published {
        val frames: MutableList<ImageBitmap?> = Collections.synchronizedList(mutableListOf())
        fun last(): ImageBitmap? = synchronized(frames) { frames.lastOrNull() }
    }

    private fun waitFor(message: String, predicate: () -> Boolean) {
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(10)
        while (System.nanoTime() < deadline) {
            var done = false
            main { done = predicate() }
            if (done) return
            Thread.sleep(20)
        }
        throw AssertionError(message)
    }

    private fun pixel(image: ImageBitmap?): Int = assertNotNull(image).asAndroidBitmap().getPixel(4, 4)

    private fun channels(color: Int) = Triple(Color.red(color), Color.green(color), Color.blue(color))

    /** MONO of the hand-built red: equal channels at the red's luma, never the red itself. */
    private fun assertMonoOfRed(color: Int) {
        val (r, g, b) = channels(color)
        assertTrue(abs(r - g) <= 3 && abs(g - b) <= 3, "mono channels equal, got $r,$g,$b")
        assertTrue(r in 40..110, "mono of red luma in 40..110, got $r")
    }

    private fun assertMonoOfBlue(color: Int) {
        val (r, g, b) = channels(color)
        assertTrue(abs(r - g) <= 3 && abs(g - b) <= 3, "mono channels equal, got $r,$g,$b")
        assertTrue(r in 5..45, "mono of blue luma in 5..45, got $r")
    }

    private fun assertRawRed(color: Int) = assertEquals(Triple(220, 30, 30), channels(color))

    /** Wraps the actual native renderer; [gate] holds the next render until released. */
    private class Gated(private val inner: MulticamLookRenderer) : MulticamLookRenderer {
        @Volatile var gate: CountDownLatch? = null
        val started = CountDownLatch(1)
        @Volatile var closedOn: String? = null
        override fun render(frame: Bitmap, selection: FeedLutSelection): Bitmap? {
            started.countDown()
            gate?.await(10, TimeUnit.SECONDS)
            return inner.render(frame, selection)
        }
        override fun close() { closedOn = Thread.currentThread().name; inner.close() }
    }

    private fun picture(published: Published, renderer: MulticamLookRenderer): MulticamPicture {
        lateinit var picture: MulticamPicture
        main {
            picture = MulticamPicture(FeedLutSelection.BuiltIn(FeedLut.MONO)) { published.frames += it }
            picture.attach(scope, { renderer }, FeedLutSelection.BuiltIn(FeedLut.MONO))
        }
        return picture
    }

    /** Real shared import, Swift validation, retained tile owner and native AGSL pixels. */
    @Test fun sameNameImportRefreshesMultiviewPixelsWithoutChangingTheSelectedLook() = runBlocking {
        val root = File(instrumentation.targetContext.cacheDir, "lut-refresh-" + UUID.randomUUID())
        val library = MonitorLutLibrary(mapOf(StoredLutCategory.CUSTOM to root),
            pack = { SwiftCore.packImportedLut(it) })
        fun cube(rgb: String) = ("LUT_3D_SIZE 2\n" + (rgb + "\n").repeat(8)).toByteArray()
        val published = Published()
        val picture = picture(published, NativeMulticamLookRenderer(library))
        try {
            val first = assertIs<MonitorLutImportResult.Imported>(
                library.importCube(StoredLutCategory.CUSTOM, cube("1 0 0"), "Operator Look.cube")).entry
            val selection = FeedLutSelection.Stored(first.selection)
            val frame = solid(Color.rgb(80, 80, 80))
            main { picture.select(selection); picture.showLut(true); picture.accept(frame) }
            waitFor("first stored look reaches the tile") { published.frames.size == 1 }
            assertTrue(Color.red(pixel(published.last())) > 230)
            assertTrue(Color.blue(pixel(published.last())) < 20)

            val replacement = assertIs<MonitorLutImportResult.Imported>(
                library.importCube(StoredLutCategory.CUSTOM, cube("0 0 1"), "Operator Look.cube")).entry
            assertEquals(first.selection, replacement.selection)
            main { picture.accept(frame) }
            waitFor("same-name replacement reaches the retained tile") { published.frames.size == 2 }
            val replaced = pixel(published.last())
            assertTrue(Color.blue(replaced) > 230, "Replacement cube produces blue: ${channels(replaced)}")
            assertTrue(Color.red(replaced) < 20, "Replacement cube produces blue: ${channels(replaced)}")
            main { assertEquals(selection, picture.selection); assertTrue(picture.lutEnabled) }
            assertEquals(listOf(first.selection), library.entries.value.map { it.selection })

            assertIs<MonitorLutImportResult.Rejected>(
                library.importCube(StoredLutCategory.CUSTOM, "not a cube".toByteArray(), "Operator Look.cube"))
            main { picture.accept(frame) }
            waitFor("rejected replacement preserves the valid tile look") { published.frames.size == 3 }
            assertTrue(Color.blue(pixel(published.last())) > 230)
            assertTrue(Color.red(pixel(published.last())) < 20)
            assertEquals(cube("0 0 1").toList(), File(root, "Operator Look.cube").readBytes().toList())
        } finally {
            main { picture.retire() }
            root.deleteRecursively()
        }
    }

    @Test fun eachMemberRendersOnlyItsOwnLookAndToggleRebakesTheLatestPicture() {
        assertTrue(SwiftCore.isAvailable)
        val a = Published()
        val b = Published()
        val first = picture(a, NativeMulticamLookRenderer(null))
        val second = picture(b, NativeMulticamLookRenderer(null))
        val red = solid(Color.rgb(220, 30, 30))
        main { first.accept(red); second.accept(red) }
        assertRawRed(pixel(a.last()))
        assertRawRed(pixel(b.last()))
        main { first.showLut(true) }
        waitFor("member A bakes its look without a new frame") { a.frames.size == 2 }
        assertMonoOfRed(pixel(a.last()))
        assertRawRed(pixel(b.last()))
        assertEquals(1, b.frames.size, "member B is untouched by A's look")
        // A different selection on B only: B grades with its own look, A keeps MONO.
        main { second.select(FeedLutSelection.BuiltIn(FeedLut.NLOG_709)); second.showLut(true) }
        waitFor("member B bakes its own look") { b.frames.size == 2 }
        val graded = channels(pixel(b.last()))
        assertTrue(graded != Triple(220, 30, 30), "N-Log look changes B's pixels, got $graded")
        assertTrue(abs(graded.first - graded.second) > 20, "N-Log look keeps colour, got $graded")
        assertMonoOfRed(pixel(a.last()))
        main { first.showLut(false) }
        assertRawRed(pixel(a.last()))
        main { first.retire(); second.retire() }
    }

    @Test fun newestSourceWinsAndAPendingBakeForAnOlderFrameNeverPublishes() {
        val published = Published()
        val gated = Gated(NativeMulticamLookRenderer(null)).apply { gate = CountDownLatch(1) }
        val picture = picture(published, gated)
        main { picture.showLut(true) }
        main { picture.accept(solid(Color.rgb(220, 30, 30))) }
        assertTrue(gated.started.await(5, TimeUnit.SECONDS))
        main { picture.accept(solid(Color.rgb(30, 30, 220))) }
        gated.gate?.countDown()
        waitFor("the newest frame publishes") { published.frames.isNotEmpty() }
        Thread.sleep(200)
        assertEquals(1, published.frames.size, "the red frame's bake was superseded, not shown")
        assertMonoOfBlue(pixel(published.last()))
        main { picture.retire() }
    }

    @Test fun aLookChangeWhileABakeIsPendingPublishesOnlyTheNewLook() {
        val published = Published()
        val gated = Gated(NativeMulticamLookRenderer(null)).apply { gate = CountDownLatch(1) }
        val picture = picture(published, gated)
        main { picture.select(FeedLutSelection.BuiltIn(FeedLut.NLOG_709)) }
        main { picture.accept(solid(Color.rgb(220, 30, 30))) }
        main { picture.showLut(true) }
        assertTrue(gated.started.await(5, TimeUnit.SECONDS))
        main { picture.select(FeedLutSelection.BuiltIn(FeedLut.MONO)) }
        gated.gate?.countDown()
        waitFor("the current look publishes") { published.frames.size == 2 }
        Thread.sleep(200)
        assertEquals(2, published.frames.size, "raw, then only the current look")
        assertMonoOfRed(pixel(published.last()))
        main { picture.retire() }
    }

    @Test fun retirementDiscardsLateOutputAndClosesTheRendererOnItsWorker() {
        val published = Published()
        val gated = Gated(NativeMulticamLookRenderer(null)).apply { gate = CountDownLatch(1) }
        val picture = picture(published, gated)
        main { picture.showLut(true) }
        main { picture.accept(solid(Color.rgb(220, 30, 30))) }
        assertTrue(gated.started.await(5, TimeUnit.SECONDS))
        main { picture.retire() }
        gated.gate?.countDown()
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(5)
        while (gated.closedOn == null && System.nanoTime() < deadline) Thread.sleep(20)
        assertEquals("multiview-member-look", gated.closedOn)
        Thread.sleep(200)
        assertEquals(listOf<ImageBitmap?>(null), published.frames.toList(), "only the retirement clear publishes")
        main { picture.accept(solid(Color.rgb(220, 30, 30))) }
        assertNull(published.last(), "a retired member accepts no frame")
    }
}

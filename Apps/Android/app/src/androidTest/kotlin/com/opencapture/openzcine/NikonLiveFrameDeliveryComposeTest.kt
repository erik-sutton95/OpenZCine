package com.opencapture.openzcine

import android.graphics.Bitmap
import android.graphics.Color
import android.os.Looper
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.opencapture.opencine.nikon.LiveFrame
import com.opencapture.opencine.nikon.LiveFrameSource
import java.io.ByteArrayOutputStream
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.flow.flow
import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/** SIMULATED JPEG through the actual live collector and native picture backend, without a camera. */
@RunWith(AndroidJUnit4::class)
class NikonLiveFrameDeliveryComposeTest {
    @Test fun liveEntryDecodesOnWorkerAndPublishesActualSourceOnMain() {
        val pixels = Bitmap.createBitmap(32, 24, Bitmap.Config.ARGB_8888)
        val jpeg = try {
            pixels.eraseColor(Color.YELLOW)
            ByteArrayOutputStream().use { output ->
                assertTrue(pixels.compress(Bitmap.CompressFormat.JPEG, 90, output))
                output.toByteArray()
            }
        } finally { pixels.recycle() }
        val original = LiveFrame(1, jpeg)
        val received = CountDownLatch(1)
        val retired = CountDownLatch(1)
        val publications = AtomicInteger()
        val source = object : LiveFrameSource {
            override val frames = flow {
                assertEquals("zc-feed-decode", Thread.currentThread().name.substringBefore(" @"))
                assertTrue(Looper.myLooper() !== Looper.getMainLooper())
                try {
                    emit(original)
                    awaitCancellation()
                } finally { retired.countDown() }
            }
        }
        // A real Activity preserves AndroidUiDispatcher through background plan preparation.
        // Compose test continuation interceptors may resume that preparation off Android main.
        ActivityScenario.launch(ComponentActivity::class.java).use { scenario ->
            scenario.onActivity { activity ->
                activity.setContent {
                    OpenZCineTheme {
                        LiveFeedView(source = source, effects = FeedEffects(),
                            onPresentedFrame = { frame, bitmap, _, _ ->
                                check(Looper.myLooper() === Looper.getMainLooper()) { "Bitmap picture owner is main-confined" }
                                assertSame(original, frame)
                                assertEquals(32, bitmap.width)
                                assertEquals(24, bitmap.height)
                                publications.incrementAndGet()
                                received.countDown()
                            })
                    }
                }
            }
            assertTrue("Actual live collector must present", received.await(10, TimeUnit.SECONDS))
        }
        assertTrue("Disconnect must cancel its source collector", retired.await(10, TimeUnit.SECONDS))
        InstrumentationRegistry.getInstrumentation().waitForIdleSync()
        assertEquals(1, publications.get())
    }
}

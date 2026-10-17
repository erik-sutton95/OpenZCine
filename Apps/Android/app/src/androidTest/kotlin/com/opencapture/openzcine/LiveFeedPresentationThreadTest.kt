package com.opencapture.openzcine

import android.graphics.Bitmap
import android.os.Looper
import android.view.View
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.ui.Modifier
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.opencapture.opencine.nikon.LiveFrame
import com.opencapture.opencine.nikon.LiveFrameSource
import java.io.ByteArrayOutputStream
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.flow
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/** SIMULATED JPEGs exercise the production decoder and real device renderer. */
@RunWith(AndroidJUnit4::class)
class LiveFeedPresentationThreadTest {
    @Test fun canvasPreviewClearsGpuFramesWithoutLeavingItsOwnerThread() {
        assertPresentedFrames(preferComposablePresentation = true)
    }

    @Test fun nativePreviewPresentsFramesWithoutLeavingItsOwnerThread() {
        assertPresentedFrames(preferComposablePresentation = false)
    }

    private fun assertPresentedFrames(preferComposablePresentation: Boolean) {
        val frames = CountDownLatch(3)
        val nativeMounted = AtomicBoolean(preferComposablePresentation)
        val callbackOnMain = AtomicReference<Boolean>()
        val relayCallbackOnMain = AtomicReference<Boolean>()
        val presentation = LiveFeedPresentationState()
        val bitmap = Bitmap.createBitmap(160, 90, Bitmap.Config.ARGB_8888)
        val jpeg = ByteArrayOutputStream().use { output ->
            bitmap.eraseColor(android.graphics.Color.GREEN)
            bitmap.compress(Bitmap.CompressFormat.JPEG, 90, output)
            output.toByteArray()
        }
        bitmap.recycle()
        val source = object : LiveFrameSource {
            override val frames = flow {
                while (true) {
                    emit(LiveFrame(System.nanoTime(), jpeg))
                    delay(40)
                }
            }
        }
        ActivityScenario.launch(ComponentActivity::class.java).use { scenario ->
            scenario.onActivity { activity ->
                activity.setContent {
                    OpenZCineTheme {
                        LiveFeedView(
                            source = source,
                            modifier = Modifier.fillMaxSize(),
                            presentationState = presentation,
                            effects = FeedEffects(),
                            preferComposablePresentation = preferComposablePresentation,
                            onFrame = {
                                callbackOnMain.set(Looper.myLooper() === Looper.getMainLooper())
                            },
                            onPresentedFrame = { _, _, _, _ ->
                                relayCallbackOnMain.set(Looper.myLooper() === Looper.getMainLooper())
                                if (nativeMounted.get()) {
                                    frames.countDown()
                                } else {
                                    activity.runOnUiThread {
                                        nativeMounted.set(activity.window.decorView
                                            .findViewWithTag<View>("monitor.native.picture") != null)
                                    }
                                }
                            },
                        )
                    }
                }
            }
            assertTrue("Preview frames must reach both worker observers after the selected renderer mounts", frames.await(10, TimeUnit.SECONDS))
            scenario.onActivity {
                assertEquals(160, presentation.sourceWidth)
                assertEquals(90, presentation.sourceHeight)
                assertFalse(callbackOnMain.get())
                assertFalse(relayCallbackOnMain.get())
            }
        }
    }
}

package com.opencapture.openzcine.media

import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.ColorMatrix
import android.graphics.ColorMatrixColorFilter
import android.graphics.RenderEffect
import android.graphics.SurfaceTexture
import android.os.Build
import android.view.TextureView
import android.widget.FrameLayout
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.opencapture.openzcine.MainActivity
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import org.junit.After
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

/** Device proof that playback scopes sample TextureView before view effects. */
@RunWith(AndroidJUnit4::class)
class PlaybackCleanScopeInputTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private var scenario: ActivityScenario<MainActivity>? = null

    @After
    fun closeActivity() {
        scenario?.close()
        scenario = null
    }

    @Test
    fun textureBitmapRemainsDecodedSourceWhenRenderEffectIsInstalled() {
        assumeTrue(Build.VERSION.SDK_INT >= 33)
        val available = CountDownLatch(1)
        val updated = CountDownLatch(1)
        val awaitingPostedFrame = AtomicBoolean(false)
        lateinit var texture: TextureView
        val launched: ActivityScenario<MainActivity> =
            ActivityScenario.launch(
                Intent(instrumentation.targetContext, MainActivity::class.java),
            )
        scenario = launched
        launched.onActivity { activity: MainActivity ->
                    texture =
                        TextureView(activity).apply {
                            surfaceTextureListener =
                                object : TextureView.SurfaceTextureListener {
                                    override fun onSurfaceTextureAvailable(
                                        surface: SurfaceTexture,
                                        width: Int,
                                        height: Int,
                                    ) {
                                        available.countDown()
                                    }

                                    override fun onSurfaceTextureSizeChanged(
                                        surface: SurfaceTexture,
                                        width: Int,
                                        height: Int,
                                    ) = Unit

                                    override fun onSurfaceTextureDestroyed(surface: SurfaceTexture): Boolean = true

                                    override fun onSurfaceTextureUpdated(surface: SurfaceTexture) {
                                        if (awaitingPostedFrame.get()) updated.countDown()
                                    }
                                }
                        }
                    activity.setContentView(
                        FrameLayout(activity).apply {
                            addView(
                                texture,
                                FrameLayout.LayoutParams(
                                    FrameLayout.LayoutParams.MATCH_PARENT,
                                    FrameLayout.LayoutParams.MATCH_PARENT,
                                ),
                            )
                        },
                    )
        }
        assertTrue("TextureView surface did not become available", available.await(5, TimeUnit.SECONDS))

        instrumentation.runOnMainSync {
            val canvas = requireNotNull(texture.lockCanvas())
            canvas.drawColor(Color.RED)
            awaitingPostedFrame.set(true)
            texture.unlockCanvasAndPost(canvas)
        }
        assertTrue("posted TextureView frame did not become visible", updated.await(5, TimeUnit.SECONDS))

        lateinit var captured: Bitmap
        instrumentation.runOnMainSync {
            val invert =
                ColorMatrix(
                    floatArrayOf(
                        -1f, 0f, 0f, 0f, 255f,
                        0f, -1f, 0f, 0f, 255f,
                        0f, 0f, -1f, 0f, 255f,
                        0f, 0f, 0f, 1f, 0f,
                    ),
                )
            texture.setRenderEffect(
                RenderEffect.createColorFilterEffect(ColorMatrixColorFilter(invert)),
            )
            captured = requireNotNull(texture.getBitmap(8, 8))
        }

        val pixel = captured.getPixel(4, 4)
        assertTrue("scope capture unexpectedly contains the view effect", Color.red(pixel) > 240)
        assertTrue(Color.green(pixel) < 15)
        assertTrue(Color.blue(pixel) < 15)
    }
}

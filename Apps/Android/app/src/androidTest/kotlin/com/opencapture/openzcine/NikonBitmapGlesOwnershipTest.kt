@file:androidx.media3.common.util.UnstableApi

package com.opencapture.openzcine

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import java.io.ByteArrayOutputStream
import android.graphics.Color
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.size
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.opencapture.opencine.media.FeedEffectsRenderPlan
import com.opencapture.opencine.runtime.MonitorBitmapFrameLease
import com.opencapture.opencine.runtime.MonitorBitmapFramePool
import com.opencapture.opencine.runtime.MonitorBitmapGlesSession
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** Real decoded-bitmap lease and actual surface publication gates; SIMULATED device proof. */
@RunWith(AndroidJUnit4::class)
class NikonBitmapGlesOwnershipTest {
    @get:Rule val compose = createComposeRule()

    private fun decodedSource(): Bitmap {
        val raster = Bitmap.createBitmap(13, 7, Bitmap.Config.ARGB_8888)
        raster.eraseColor(Color.rgb(180, 64, 210))
        val encoded = ByteArrayOutputStream()
        try { check(raster.compress(Bitmap.CompressFormat.JPEG, 95, encoded)) }
        finally { raster.recycle() }
        val bytes = encoded.toByteArray()
        // Mutable decode: the gates below set exact pixels on the real decoded raster.
        val options = BitmapFactory.Options().apply { inMutable = true }
        return requireNotNull(BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options)).also {
            assertEquals(13, it.width)
            assertEquals(7, it.height)
            assertEquals(LiveFeedColorMode.SDR, decodedLiveFeedColorMode(it))
        }
    }

    @Test fun closedPoolRetainsBorrowedPixelsUntilTheirSingleRelease() {
        val source = decodedSource()
        val pool = MonitorBitmapFramePool(size = 1)
        source.eraseColor(Color.rgb(180, 64, 210))
        val lease = requireNotNull(pool.copy(source))
        try {
            pool.close()
            source.eraseColor(Color.GREEN)
            assertFalse(lease.bitmap.isRecycled)
            assertEquals(Color.rgb(180, 64, 210), lease.bitmap.getPixel(6, 3))
            assertNull(pool.copy(source))
            lease.release()
            assertTrue(lease.bitmap.isRecycled)
            lease.release()
            assertTrue(lease.bitmap.isRecycled)
        } finally {
            lease.release()
            pool.close()
            source.recycle()
        }
    }

    @Test fun allThreeSlotsAreBoundedAndOnlyReturnedSlotAcceptsSuccessorPixels() {
        val source = decodedSource()
        val pool = MonitorBitmapFramePool()
        source.eraseColor(Color.RED)
        val a = requireNotNull(pool.copy(source))
        val b = requireNotNull(pool.copy(source))
        val c = requireNotNull(pool.copy(source))
        var d: MonitorBitmapFrameLease? = null
        try {
            assertNull(pool.copy(source))
            a.release()
            source.eraseColor(Color.BLUE)
            d = requireNotNull(pool.copy(source))
            assertSame(a.bitmap, d.bitmap)
            assertEquals(Color.BLUE, d.bitmap.getPixel(6, 3))
            assertEquals(Color.RED, b.bitmap.getPixel(6, 3))
            assertEquals(Color.RED, c.bitmap.getPixel(6, 3))
            assertNull(pool.copy(source))
        } finally {
            a.release(); b.release(); c.release(); d?.release()
            pool.close()
            source.recycle()
        }
    }

    @Test fun postedOldSurfaceFailureCannotFailTheSamePlanOnReplacementSurface() {
        val owner = MonitorBitmapGlesSession()
        var old: LegacyLiveFeedGlSurface? = null
        var successor: LegacyLiveFeedGlSurface? = null
        compose.setContent {
            Row {
                AndroidView(
                    factory = { LegacyLiveFeedGlSurface(it).also { view -> old = view } },
                    modifier = Modifier.size(64.dp),
                )
                AndroidView(
                    factory = { LegacyLiveFeedGlSurface(it).also { view -> successor = view } },
                    modifier = Modifier.size(64.dp),
                )
            }
        }
        try {
            compose.runOnIdle {
                val first = requireNotNull(old)
                val next = requireNotNull(successor)
                assertTrue(first.isAttachedToWindow)
                assertTrue(next.isAttachedToWindow)
                owner.resume()
                owner.update(FeedEffectsRenderPlan.IDENTITY, false, false)
                owner.attach(first)
                val queuedFailure = requireNotNull(first.onRenderFailure)
                // Both surfaces stay mounted. The posted failure runs after this
                // main-thread block, when the actual native owner admits only next.
                queuedFailure(FeedEffectsRenderPlan.IDENTITY, IllegalStateException("retired surface"))
                owner.attach(next)
            }
            compose.runOnIdle {
                assertFalse(owner.renderFailed)
                assertTrue(owner.recordRenderFailure(FeedEffectsRenderPlan.IDENTITY))
                assertTrue(owner.renderFailed)
                owner.dispose()
                assertFalse(owner.recordRenderFailure(FeedEffectsRenderPlan.IDENTITY))
            }
        } finally {
            compose.runOnIdle { owner.dispose() }
        }
    }
}

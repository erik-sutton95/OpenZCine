package com.opencapture.openzcine

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.opencapture.monitorui.MonitorAssistTool
import com.opencapture.opencine.appkit.MonitorAssistState
import com.opencapture.opencine.media.MonitorTransfer
import com.opencapture.opencine.media.ScopeAssistBundle
import com.opencapture.opencine.media.ScopeLevelAxis
import com.opencapture.opencine.media.ScopeTrafficLights
import com.opencapture.opencine.nikon.LiveFrame
import com.opencapture.opencine.nikon.LiveFrameSource
import com.opencapture.openzcine.bridge.SwiftCore
import java.io.ByteArrayOutputStream
import java.util.concurrent.CopyOnWriteArrayList
import kotlin.math.roundToInt
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.flow
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/**
 * A1-05 (Android): the live scope source the Z monitor hands the shared surface publishes the
 * shared engine's reading of the camera's picture, on the camera's transfer and stated clip.
 */
@RunWith(AndroidJUnit4::class)
class NikonScopeEngineAdoptionTest {
    @get:Rule val composeRule = createComposeRule()

    @Test fun theLiveScopeSourcePublishesTheSharedEnginesBundle() {
        assertTrue("The camera mapping needs the staged Swift core", SwiftCore.isAvailable)
        val input = ExposureAssistCameraInput()
        val mapping = requireNotNull(resolveExposureAssistMapping(input))
        val transfer = when (mapping.curveOrdinal) {
            ExposureCurveOrdinals.NIKON_NLOG -> MonitorTransfer.NLOG
            ExposureCurveOrdinals.RED_LOG3G10 -> MonitorTransfer.LOG3G10
            ExposureCurveOrdinals.HLG -> MonitorTransfer.HDR
            else -> MonitorTransfer.SRGB
        }
        val clip = mapping.clipNative.roundToInt()
        // A grey picture with a blue patch inside the shared clip shelf (just under the stated clip).
        val source = PatchSource(grey = 96, blue = clip - 5)
        val assist = MonitorAssistState().apply {
            toggle(MonitorAssistTool.WAVE); toggle(MonitorAssistTool.HISTO); toggle(MonitorAssistTool.LIGHTS)
        }
        val published = CopyOnWriteArrayList<ScopeAssistBundle>()
        composeRule.setContent {
            val bundles = rememberNikonLiveScopeBundles(
                setOf(ScopeKind.WAVEFORM, ScopeKind.HISTOGRAM, ScopeKind.TRAFFIC_LIGHTS), emptyList(), assist,
                input, null, null, AndroidThermalTier.NOMINAL, source, isPortrait = false,
                portraitFloating = false, scopeZone = null)
            LaunchedEffect(bundles) { bundles?.collect { if (it.revision > 0) published += it } }
        }
        composeRule.waitUntil(10_000) { consecutive(published) != null }
        val (previous, bundle) = requireNotNull(consecutive(published))

        // The camera's facts: its curve as the shared transfer and its stated clip.
        assertEquals(transfer, bundle.transfer)
        assertEquals(clip, bundle.ceiling.clipByte(transfer))
        // A1-38: the shared panels draw the shared axis, the camera's clip on the clip line at 100.
        val axis = bundle.levelAxis ?: ScopeLevelAxis.of(bundle.transfer, bundle.iso, bundle.ceiling)
        assertEquals(ScopeLevelAxis.of(transfer, ceiling = bundle.ceiling), axis)
        assertEquals(100f, axis.table[clip], 0.5f)
        // A1-39: the lamps are the shared reading, with its hysteresis over the previous tick.
        val samples = bundle.samples
        assertEquals(
            ScopeTrafficLights.reading(samples.histogramRed, samples.histogramGreen, samples.histogramBlue, transfer,
                assist.crushClipCompensation.pixelFractionThreshold, previous.traffic, samples.histogramLuma,
                bundle.ceiling),
            bundle.traffic)
        // The shared clip shelf flags the blue patch under the stated clip.
        assertTrue("blue sits in the clip shelf", bundle.traffic.blue.clip)
        assertNotNull(bundle.histogramDisplay)
    }

    private fun consecutive(bundles: List<ScopeAssistBundle>): Pair<ScopeAssistBundle, ScopeAssistBundle>? =
        bundles.zipWithNext().lastOrNull { (a, b) -> b.revision == a.revision + 1 }

    /** SIMULATED camera JPEGs: grey with a blue patch over a quarter of the frame. */
    private class PatchSource(grey: Int, blue: Int) : LiveFrameSource {
        private val jpeg = ByteArrayOutputStream().use { output ->
            val bitmap = Bitmap.createBitmap(320, 180, Bitmap.Config.ARGB_8888)
            bitmap.eraseColor(android.graphics.Color.rgb(grey, grey, grey))
            Canvas(bitmap).drawRect(0f, 0f, 160f, 90f,
                Paint().apply { color = android.graphics.Color.rgb(grey / 2, grey / 2, blue) })
            bitmap.compress(Bitmap.CompressFormat.JPEG, 100, output)
            bitmap.recycle()
            output.toByteArray()
        }
        override val frames = flow {
            while (true) {
                emit(LiveFrame(System.nanoTime(), jpeg))
                delay(60)
            }
        }
    }
}

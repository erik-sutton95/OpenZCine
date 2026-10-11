package com.opencapture.openzcine

import android.app.Activity
import android.os.Looper
import android.content.Context
import android.graphics.Bitmap
import android.view.View
import android.view.ViewGroup
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.requiredSize
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performSemanticsAction
import androidx.compose.ui.semantics.SemanticsActions
import com.opencapture.monitorui.MonitorAssistTool
import androidx.compose.ui.test.performClick
import androidx.test.platform.app.InstrumentationRegistry
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.runner.lifecycle.ActivityLifecycleMonitorRegistry
import androidx.test.runner.lifecycle.Stage
import com.opencapture.opencine.appkit.MonitorControlModel
import com.opencapture.opencine.nikon.CameraIdentity
import com.opencapture.opencine.nikon.FakeCameraSession
import com.opencapture.opencine.nikon.LiveFrame
import com.opencapture.opencine.nikon.LiveFrameSource
import com.opencapture.opencine.nikon.NikonOpenCineSession
import com.opencapture.openzcine.settings.OperatorSettings
import java.io.ByteArrayOutputStream
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.flow.flow
import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** SIMULATED raster through the production Nikon shared screen and actual native GPU host. */
@RunWith(AndroidJUnit4::class)
class NikonMonitorHostLifetimeComposeTest {
    @get:Rule val composeRule = createComposeRule()

    @Test fun nativePictureSurvivesModesCoversAndGeometryWhileCommandReleasesPreviewDemand() {
        val source = CountedPictureSource()
        val session = FakeCameraSession(CameraIdentity("SIMULATED", "SIMULATED", "host-lifetime"))
        runBlocking { session.connect() }
        val mounted = mutableStateOf(true)
        val front = mutableStateOf(true)
        val landscape = mutableStateOf(false)
        lateinit var settings: OperatorSettings
        composeRule.mainClock.autoAdvance = false
        composeRule.setContent {
            val context = LocalContext.current
            settings = remember {
                OperatorSettings(context.getSharedPreferences("z1-host-lifetime", Context.MODE_PRIVATE).also { it.edit().clear().commit() })
            }
            val scope = rememberCoroutineScope()
            val common = remember { NikonOpenCineSession(session, scope) }
            val control = remember { MonitorControlModel(scope).also { it.bind(common) } }
            DisposableEffect(Unit) { onDispose { control.unbind() } }
            OpenZCineTheme {
                if (mounted.value) Box(Modifier.requiredSize(
                    if (landscape.value) 840.dp else 400.dp, if (landscape.value) 400.dp else 840.dp)) {
                    MonitorScreen(session = session, frameSource = source, commonSession = common, commonControl = control,
                        assists = idleNikonAssists(), operatorSettings = settings,
                        isMonitorFront = front.value, liveViewEnabled = true, sessionRecoveryEnabled = false, glassTierOverride = "flat")
                }
            }
        }
        composeRule.mainClock.advanceTimeByFrame()
        composeRule.waitUntil(10_000) { nativePicture() != null }
        lateinit var original: View
        var detachments = 0
        composeRule.runOnIdle {
            original = requireNotNull(nativePicture())
            original.addOnAttachStateChangeListener(object : View.OnAttachStateChangeListener {
                override fun onViewAttachedToWindow(view: View) = Unit
                override fun onViewDetachedFromWindow(view: View) { detachments += 1 }
            })
        }
        composeRule.waitUntil(5_000) { source.collectors.get() >= 2 }
        for (wide in listOf(true, false)) {
            composeRule.runOnIdle { landscape.value = wide }
            composeRule.mainClock.advanceTimeByFrame()
            repeat(3) {
                composeRule.mainClock.advanceTimeByFrame()
                composeRule.waitForIdle()
                composeRule.runOnIdle {
                    assertSame("Geometry and DISP must preserve the native renderer view", original, nativePicture())
                    assertEquals(0, detachments)
                }
                changeDisplay()
            }
        }
        composeRule.mainClock.advanceTimeByFrame()
        composeRule.waitUntil(5_000) { source.collectors.get() >= 2 }
        val previewCollectors = source.collectors.get()
        changeDisplay()
        changeDisplay()
        composeRule.mainClock.advanceTimeByFrame()
        composeRule.waitUntil(5_000) { source.collectors.get() < previewCollectors }
        // Full-screen Settings/Media cover ownership is supplied by the root's front value.
        // A cover hides chrome while retaining the same picture source and native renderer.
        for (covered in listOf(true, false, true, false)) {
            composeRule.runOnIdle { front.value = !covered }
            composeRule.mainClock.advanceTimeByFrame()
            composeRule.runOnIdle { assertSame(original, nativePicture()); assertEquals(0, detachments) }
        }
        composeRule.runOnIdle { mounted.value = false }
        composeRule.mainClock.advanceTimeByFrame()
        composeRule.waitUntil(5_000) { source.collectors.get() == 0 }
        composeRule.runOnIdle { assertEquals(1, detachments); assertTrue(original.parent == null) }
    }

    @Test fun actualPortraitPaletteKeepsThirdScopeActiveAndItsOptionsAvailable() {
        val source = CountedPictureSource()
        val session = FakeCameraSession(CameraIdentity("SIMULATED", "SIMULATED", "scope-selection"))
        runBlocking { session.connect() }
        val assists = idleNikonAssists()
        composeRule.setContent {
            val context = LocalContext.current
            val settings = remember {
                OperatorSettings(context.getSharedPreferences("SIMULATED-scope-selection", Context.MODE_PRIVATE)
                    .also { it.edit().clear().commit() })
            }
            val scope = rememberCoroutineScope()
            val common = remember { NikonOpenCineSession(session, scope) }
            val control = remember { MonitorControlModel(scope).also { it.bind(common) } }
            DisposableEffect(Unit) { onDispose { control.unbind() } }
            OpenZCineTheme {
                Box(Modifier.requiredSize(400.dp, 840.dp)) {
                    MonitorScreen(session, common, control, source, assists, settings,
                        liveViewEnabled = true, sessionRecoveryEnabled = false, glassTierOverride = "flat")
                }
            }
        }
        composeRule.waitUntil(5_000) { source.collectors.get() >= 2 }
        composeRule.onNodeWithTag("monitor.assists.expand").performClick()
        for (tool in listOf(MonitorAssistTool.WAVE, MonitorAssistTool.HISTO, MonitorAssistTool.PARADE)) {
            composeRule.onNodeWithContentDescription("${tool.title}, off").performClick()
        }
        composeRule.runOnIdle {
            assertTrue(assists.shared.isOn(MonitorAssistTool.WAVE))
            assertTrue(assists.shared.isOn(MonitorAssistTool.HISTO))
            assertTrue(assists.shared.isOn(MonitorAssistTool.PARADE))
            assertEquals(listOf(ScopeKind.PARADE, ScopeKind.HISTOGRAM),
                assists.shared.portraitScopes(scopesShown(assists.shared::isOn)))
        }
        composeRule.onNodeWithContentDescription("${MonitorAssistTool.PARADE.title}, on")
            .performSemanticsAction(SemanticsActions.OnLongClick)
        composeRule.runOnIdle { assertEquals(MonitorAssistTool.PARADE, assists.shared.configureTool) }
        composeRule.onNodeWithContentDescription("Dismiss ${MonitorAssistTool.PARADE.title}").performClick()
        composeRule.runOnIdle { assertTrue(assists.shared.isOn(MonitorAssistTool.WAVE)) }
    }

    private fun nativePicture(): View? {
        fun find(view: View): View? {
            if (view.tag == "monitor.native.picture") return view
            if (view is ViewGroup) for (index in 0 until view.childCount) find(view.getChildAt(index))?.let { return it }
            return null
        }
        var found: View? = null
        val inspect = {
            val activities = ActivityLifecycleMonitorRegistry.getInstance().getActivitiesInStage(Stage.RESUMED)
            found = activities.firstNotNullOfOrNull { find((it as Activity).window.decorView) }
        }
        if (Looper.myLooper() == Looper.getMainLooper()) inspect()
        else InstrumentationRegistry.getInstrumentation().runOnMainSync(inspect)
        return found
    }

    private fun changeDisplay() {
        val label = InstrumentationRegistry.getInstrumentation().targetContext.getString(R.string.a11y_monitor_disp)
        composeRule.onNodeWithContentDescription(label).performClick()
        composeRule.mainClock.advanceTimeByFrame()
    }

    private class CountedPictureSource : LiveFrameSource {
        val collectors = AtomicInteger()
        private val jpeg = ByteArrayOutputStream().use { output ->
            val bitmap = Bitmap.createBitmap(160, 90, Bitmap.Config.ARGB_8888)
            bitmap.eraseColor(android.graphics.Color.GREEN)
            bitmap.compress(Bitmap.CompressFormat.JPEG, 90, output)
            bitmap.recycle()
            output.toByteArray()
        }
        override val frames = flow {
            collectors.incrementAndGet()
            try { emit(LiveFrame(System.nanoTime(), jpeg)); awaitCancellation() }
            finally { collectors.decrementAndGet() }
        }
    }
}

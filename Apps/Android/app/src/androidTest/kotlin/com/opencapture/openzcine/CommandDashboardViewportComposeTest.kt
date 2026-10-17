package com.opencapture.openzcine

import android.content.Context
import android.content.pm.ActivityInfo
import android.content.res.Configuration
import android.graphics.Bitmap
import android.graphics.Color
import android.os.Build
import android.os.SystemClock
import android.view.View
import android.view.ViewTreeObserver
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.hasAnyAncestor
import androidx.compose.ui.test.hasAnyDescendant
import androidx.compose.ui.test.hasContentDescription
import androidx.compose.ui.test.hasScrollAction
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.performScrollToNode
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.test.swipeUp
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.runner.lifecycle.ActivityLifecycleMonitorRegistry
import androidx.test.runner.lifecycle.Stage
import com.opencapture.opencine.appkit.MonitorControlModel
import com.opencapture.opencine.appkit.MonitorDisplayMode
import com.opencapture.opencine.appkit.MonitorOperatorSessionModel
import com.opencapture.opencine.nikon.CameraIdentity
import com.opencapture.opencine.nikon.FakeCameraSession
import com.opencapture.opencine.nikon.NikonOpenCineSession
import com.opencapture.openzcine.settings.OperatorSettings
import java.util.UUID
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.floor
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** SIMULATED native window through the production monitor and shared dashboard slot. */
@OptIn(ExperimentalTestApi::class)
@RunWith(AndroidJUnit4::class)
class CommandDashboardViewportComposeTest {
    @get:Rule val composeRule = createComposeRule()
    private lateinit var display: MonitorOperatorSessionModel
    private val iso = hasContentDescription("ISO:", substring = true)
    private val last = hasContentDescription("Grid:", substring = true)
    private val more = hasContentDescription("More command controls below.", substring = true)
    private var observedView: View? = null
    private var drawListener: ViewTreeObserver.OnDrawListener? = null
    private val eventSequence = AtomicInteger()
    private val drawSequence = AtomicInteger()
    private val commitSequence = AtomicInteger()
    private val modeSequence = AtomicInteger()
    private val observedMode = AtomicReference<String?>(null)

    @After fun removeCaptureObserver() {
        InstrumentationRegistry.getInstrumentation().runOnMainSync {
            val view = observedView
            val listener = drawListener
            if (view != null && listener != null && view.viewTreeObserver.isAlive) {
                view.viewTreeObserver.removeOnDrawListener(listener)
            }
        }
    }

    @Test fun portraitShowsWholePrimaryRowsAndScrollsToTheLastSection() {
        show(portrait = true)
        val scroller = composeRule.onNode(hasScrollAction() and hasAnyDescendant(iso), useUnmergedTree = true)
        val viewport = scroller.fetchSemanticsNode().boundsInRoot
        val density = InstrumentationRegistry.getInstrumentation().targetContext.resources.displayMetrics.density
        assertTrue("Three complete 76dp rows and two 9dp gaps need 246dp: $viewport", viewport.height >= 246f * density - 1f)
        for (title in listOf("ISO:", "Shutter:", "VR / e-VR:")) {
            val tile = composeRule.onNodeWithContentDescription(title, substring = true, useUnmergedTree = true)
            tile.assertIsDisplayed()
            val bounds = tile.fetchSemanticsNode().boundsInRoot
            assertTrue("The whole primary tile $title must be painted: $bounds", bounds.height >= 76f * density - 1f)
            assertTrue("$title must fit its real viewport", bounds.top >= viewport.top - 1f && bounds.bottom <= viewport.bottom + 1f)
        }
        screenshot("portrait-initial", portrait = true)
        scroller.performScrollToNode(last)
        composeRule.onNode(last, useUnmergedTree = true).assertIsDisplayed()
        screenshot("portrait-scrolled-end", portrait = true)
    }

    @Test fun landscapeShowsItsOverflowCueAndScrollsToTheLastCell() {
        show(portrait = false)
        composeRule.onNode(more, useUnmergedTree = true).assertIsDisplayed()
        screenshot("landscape-initial", portrait = false)
        val scroller = composeRule.onNode(hasScrollAction() and hasAnyDescendant(last), useUnmergedTree = true)
        scroller.performScrollToNode(last)
        scroller.performTouchInput { swipeUp() }
        composeRule.waitUntil(10_000) { composeRule.onAllNodes(more, useUnmergedTree = true).fetchSemanticsNodes().isEmpty() }
        composeRule.onNode(last, useUnmergedTree = true).assertIsDisplayed()
        screenshot("landscape-scrolled-end", portrait = false)
    }

    private fun show(portrait: Boolean) {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        instrumentation.runOnMainSync {
            ActivityLifecycleMonitorRegistry.getInstance().getActivitiesInStage(Stage.RESUMED).single()
                .requestedOrientation = if (portrait) ActivityInfo.SCREEN_ORIENTATION_PORTRAIT else ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE
        }
        composeRule.waitUntil(15_000) {
            instrumentation.targetContext.resources.configuration.orientation ==
                if (portrait) Configuration.ORIENTATION_PORTRAIT else Configuration.ORIENTATION_LANDSCAPE
        }
        instrumentation.runOnMainSync {
            val view = ActivityLifecycleMonitorRegistry.getInstance().getActivitiesInStage(Stage.RESUMED).single()
                .window.decorView
            observedView = view
            val listener = ViewTreeObserver.OnDrawListener {
                val draw = drawSequence.incrementAndGet()
                val modeAtDraw = currentMode()
                trace("native-draw-$draw")
                if (Build.VERSION.SDK_INT >= 29 && view.isHardwareAccelerated && view.viewTreeObserver.isAlive) {
                    view.viewTreeObserver.registerFrameCommitCallback {
                        commitSequence.incrementAndGet()
                        trace("native-frame-commit-$draw-modeAtDraw-$modeAtDraw")
                    }
                }
            }
            drawListener = listener
            view.viewTreeObserver.addOnDrawListener(listener)
            observeWindow("observer-installed")
        }
        val session = FakeCameraSession(CameraIdentity("SIMULATED", "SIMULATED", "command-viewport"))
        runBlocking { session.connect() }
        val namespace = "SIMULATED.command-viewport.${UUID.randomUUID()}"
        composeRule.setContent {
            val context = LocalContext.current
            val settings = remember { OperatorSettings(context.getSharedPreferences(namespace, Context.MODE_PRIVATE)) }
            val scope = rememberCoroutineScope()
            val common = remember { NikonOpenCineSession(session, scope) }
            val control = remember { MonitorControlModel(scope).also { it.bind(common) } }
            val assists = remember { idleNikonAssists() }
            display = rememberTestOperatorSession(assists, settings)
            LaunchedEffect(display) {
                snapshotFlow { display.mode }.collect { trace("snapshot-mode-${it.name}") }
            }
            DisposableEffect(Unit) { onDispose { control.unbind() } }
            OpenZCineTheme {
                MonitorScreen(
                    session = session, commonSession = common, commonControl = control,
                    operatorSession = display, frameSource = null, assists = assists, operatorSettings = settings,
                    liveViewEnabled = false, sessionRecoveryEnabled = false,
                )
            }
        }
        composeRule.waitUntil(15_000) {
            ::display.isInitialized && display.interactive && !display.locked && MonitorDisplayMode.COMMAND in display.modes
        }
        composeRule.runOnIdle {
            observeWindow("before-original-command-select")
            assertTrue(display.select(MonitorDisplayMode.COMMAND))
            observeWindow("after-original-command-select")
        }
        composeRule.waitUntilAtLeastOneExists(iso, 15_000)
        composeRule.waitForIdle()
    }

    private fun screenshot(name: String, portrait: Boolean) {
        composeRule.waitForIdle()
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        instrumentation.runOnMainSync { observeWindow("$name-before-semantic-freeze") }
        val paint = freezeDashboardPaint()
        instrumentation.runOnMainSync { observeWindow("$name-before-bitmap") }
        val bitmap = requireNotNull(instrumentation.uiAutomation.takeScreenshot())
        instrumentation.runOnMainSync { observeWindow("$name-after-bitmap") }
        assertEquals("The screenshot must have the requested orientation", portrait, bitmap.height > bitmap.width)
        val destination = instrumentation.targetContext.filesDir.resolve("SIMULATED-command-grid-$name.png")
        try {
            destination.outputStream().use { assertTrue(bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)) }
            assertDashboardPaint(bitmap, name, paint)
        } finally {
            bitmap.recycle()
        }
        println("SIMULATED command viewport screenshot: ${destination.name}")
    }

    private data class PaintTile(val bounds: Rect, val label: List<String>?)
    private data class PaintSnapshot(val density: Float, val tiles: List<PaintTile>)

    private fun freezeDashboardPaint(): PaintSnapshot {
        val density = InstrumentationRegistry.getInstrumentation().targetContext.resources.displayMetrics.density
        val tile = SemanticsMatcher("dashboard tile with a value") { node ->
            node.config.getOrNull(SemanticsProperties.ContentDescription)?.any { it.contains(": ") } == true
        }
        val nodes = composeRule.onAllNodes(tile and hasAnyAncestor(hasScrollAction()), useUnmergedTree = true)
            .fetchSemanticsNodes()
        val tiles = nodes.map { PaintTile(it.boundsInWindow, it.config.getOrNull(SemanticsProperties.ContentDescription)?.toList()) }
        for (entry in tiles) println("SIMULATED capture-frozen-semantics ns=${SystemClock.elapsedRealtimeNanos()} " +
            "mode=${currentMode()} density=$density label=${entry.label} bounds=${entry.bounds}")
        return PaintSnapshot(density, tiles)
    }

    /** Catch the production picture.notice layer covering real tiles even when waiting is false. */
    private fun assertDashboardPaint(bitmap: Bitmap, name: String, paint: PaintSnapshot) {
        val density = paint.density
        var sampled = 0
        for (tile in paint.tiles) {
            val bounds = tile.bounds
            if (bounds.width < 16f * density || bounds.height < 24f * density) continue
            val left = ceil(bounds.left + 4f * density).toInt().coerceAtLeast(0)
            val right = floor(bounds.right - 4f * density).toInt().coerceAtMost(bitmap.width)
            val top = ceil(bounds.top + 4f * density).toInt().coerceAtLeast(0)
            val bottom = floor(bounds.bottom - 4f * density).toInt().coerceAtMost(bitmap.height)
            assertTrue("A visible tile needs a real screenshot region: $bounds", right > left && bottom > top)
            var surface = 0
            var ink = 0
            for (y in top until bottom) for (x in left until right) {
                val pixel = bitmap.getPixel(x, y)
                // The established dashboard surface is #1A1B1C; the obscuring notice is black.
                if (abs(Color.red(pixel) - 26) <= 2 && abs(Color.green(pixel) - 27) <= 2 &&
                    abs(Color.blue(pixel) - 28) <= 2) surface += 1
                if (Color.red(pixel) >= 80 && Color.green(pixel) >= 80 && Color.blue(pixel) >= 80) ink += 1
            }
            val area = (right - left) * (bottom - top)
            val label = tile.label
            println("SIMULATED production dashboard paint $name $label rect=$left,$top,$right,$bottom surface=$surface/$area ink=$ink")
            assertTrue("The full window must paint the actual tile surface: $label", surface * 2 >= area)
            assertTrue("The full window must paint the actual tile text: $label", ink >= 8)
            sampled += 1
        }
        assertTrue("Production dashboard paint must cover multiple visible tiles", sampled >= 4)
    }

    private fun currentMode(): String = if (::display.isInitialized) display.mode.name else "UNINITIALIZED"

    private fun trace(event: String) {
        val mode = currentMode()
        val previous = observedMode.getAndSet(mode)
        if (mode != previous) modeSequence.incrementAndGet()
        println("SIMULATED capture-observer seq=${eventSequence.incrementAndGet()} ns=${SystemClock.elapsedRealtimeNanos()} " +
            "event=$event mode=$mode previous=$previous modeSequence=${modeSequence.get()} " +
            "draws=${drawSequence.get()} commits=${commitSequence.get()} thread=${Thread.currentThread().name}")
    }

    private fun observeWindow(event: String) {
        trace(event)
        val view = observedView ?: return
        val location = IntArray(2)
        view.getLocationOnScreen(location)
        println("SIMULATED capture-window ns=${SystemClock.elapsedRealtimeNanos()} event=$event mode=${currentMode()} " +
            "view=${System.identityHashCode(view)} size=${view.width},${view.height} screen=${location[0]},${location[1]} " +
            "attached=${view.isAttachedToWindow} shown=${view.isShown} visibility=${view.windowVisibility} " +
            "focus=${view.hasWindowFocus()} hardware=${view.isHardwareAccelerated} " +
            "display=${view.display?.displayId} rotation=${view.display?.rotation}")
    }
}

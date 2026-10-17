package com.opencapture.openzcine

import android.content.Context
import android.content.pm.ActivityInfo
import android.content.res.Configuration
import android.graphics.Bitmap
import android.graphics.Color
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
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
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.floor
import kotlinx.coroutines.runBlocking
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
        composeRule.runOnIdle { assertTrue(display.select(MonitorDisplayMode.COMMAND)) }
        composeRule.waitUntilAtLeastOneExists(iso, 15_000)
        composeRule.waitForIdle()
    }

    private fun screenshot(name: String, portrait: Boolean) {
        composeRule.waitForIdle()
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val bitmap = requireNotNull(instrumentation.uiAutomation.takeScreenshot())
        assertEquals("The screenshot must have the requested orientation", portrait, bitmap.height > bitmap.width)
        val destination = instrumentation.targetContext.filesDir.resolve("SIMULATED-command-grid-$name.png")
        try {
            destination.outputStream().use { assertTrue(bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)) }
            assertDashboardPaint(bitmap, name)
        } finally {
            bitmap.recycle()
        }
        println("SIMULATED command viewport screenshot: ${destination.name}")
    }

    /** Catch the production picture.notice layer covering real tiles even when waiting is false. */
    private fun assertDashboardPaint(bitmap: Bitmap, name: String) {
        val density = InstrumentationRegistry.getInstrumentation().targetContext.resources.displayMetrics.density
        val tile = SemanticsMatcher("dashboard tile with a value") { node ->
            node.config.getOrNull(SemanticsProperties.ContentDescription)?.any { it.contains(": ") } == true
        }
        val nodes = composeRule.onAllNodes(tile and hasAnyAncestor(hasScrollAction()), useUnmergedTree = true)
            .fetchSemanticsNodes()
        var sampled = 0
        for (node in nodes) {
            val bounds = node.boundsInWindow
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
            val label = node.config.getOrNull(SemanticsProperties.ContentDescription)
            println("SIMULATED production dashboard paint $name $label rect=$left,$top,$right,$bottom surface=$surface/$area ink=$ink")
            assertTrue("The full window must paint the actual tile surface: $label", surface * 2 >= area)
            assertTrue("The full window must paint the actual tile text: $label", ink >= 8)
            sampled += 1
        }
        assertTrue("Production dashboard paint must cover multiple visible tiles", sampled >= 4)
    }
}

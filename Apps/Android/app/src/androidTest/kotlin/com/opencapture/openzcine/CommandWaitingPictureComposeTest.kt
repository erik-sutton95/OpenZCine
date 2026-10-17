package com.opencapture.openzcine

import android.content.Context
import android.content.pm.ActivityInfo
import android.content.res.Configuration
import android.graphics.Bitmap
import android.graphics.Color as PixelColor
import android.view.View
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Text
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.runner.lifecycle.ActivityLifecycleMonitorRegistry
import androidx.test.runner.lifecycle.Stage
import com.opencapture.monitorui.LiveMonitorLayout
import com.opencapture.monitorui.MonitorCommandDashboardLayout
import com.opencapture.monitorui.MonitorRect
import com.opencapture.monitorui.MonitorStatusPresentation
import com.opencapture.monitorui.MonitorToolUsageState
import com.opencapture.opencine.appkit.MonitorControlModel
import com.opencapture.opencine.appkit.MonitorDisplayMode
import com.opencapture.opencine.appkit.MonitorOperatorCaptureInputs
import com.opencapture.opencine.appkit.MonitorOperatorSessionModel
import com.opencapture.opencine.cameracontrols.MonitorOperatorBodyViews
import com.opencapture.opencine.cameracontrols.MonitorOperatorLiveAssists
import com.opencapture.opencine.cameracontrols.MonitorOperatorLiveIdentity
import com.opencapture.opencine.cameracontrols.MonitorOperatorLiveLayout
import com.opencapture.opencine.cameracontrols.MonitorOperatorLivePicture
import com.opencapture.opencine.cameracontrols.MonitorOperatorLiveSource
import com.opencapture.opencine.cameracontrols.MonitorOperatorLiveStatus
import com.opencapture.opencine.cameracontrols.MonitorOperatorLiveSurface
import com.opencapture.opencine.cameracontrols.MonitorOperatorRecordSource
import com.opencapture.opencine.cameracontrols.MonitorOperatorSignalOptions
import com.opencapture.openzcine.settings.OperatorSettings
import java.util.UUID
import kotlin.math.roundToInt
import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** SIMULATED injected notice through the real shared slot, above the native picture and dashboard.
 * Mirrored with MonitorCommandWaitingPictureTests; original dashboard oracles remain unchanged. */
@OptIn(ExperimentalTestApi::class)
@RunWith(AndroidJUnit4::class)
class CommandWaitingPictureComposeTest {
    @get:Rule val composeRule = createComposeRule()
    private lateinit var display: MonitorOperatorSessionModel
    private lateinit var layout: LiveMonitorLayout
    private var waiting by mutableStateOf(true)
    private var native: View? = null
    private var created = 0
    private var released = 0
    private var density = 1f

    @Test fun portraitCommandPaintExcludesWaitingPicture() = command(portrait = true)
    @Test fun landscapeCommandPaintExcludesWaitingPicture() = command(portrait = false)

    @Test fun liveAndCleanKeepWaitingPresentationVisible() {
        show(portrait = false)
        for (mode in listOf(MonitorDisplayMode.LIVE, MonitorDisplayMode.CLEAN)) {
            composeRule.runOnIdle { if (display.mode != mode) assertTrue(display.select(mode)) }
            composeRule.waitUntilAtLeastOneExists(hasTestTag("SIMULATED.waiting"), 5_000)
            assertPaint("${mode.name}-waiting", PixelColor.MAGENTA)
            composeRule.onNodeWithTag("SIMULATED.waiting").assertExists()
            assertTrue(waiting)
        }
    }

    @Test fun modeChangesRetainTheNativePictureOwnerAndReturnItsPaint() {
        waiting = false
        show(portrait = false)
        val owner = requireNotNull(native)
        for (mode in listOf(MonitorDisplayMode.COMMAND, MonitorDisplayMode.CLEAN, MonitorDisplayMode.LIVE)) {
            composeRule.runOnIdle { assertTrue(display.select(mode)) }
            composeRule.waitForIdle()
            assertSame(owner, native)
            assertEquals(1, created)
            assertEquals(0, released)
        }
        assertPaint("returned-LIVE-native-owner", PixelColor.BLUE, detail = false)
    }

    private fun command(portrait: Boolean) {
        show(portrait)
        composeRule.runOnIdle { assertTrue(display.select(MonitorDisplayMode.COMMAND)) }
        composeRule.waitUntilAtLeastOneExists(hasTestTag("SIMULATED.dashboard"), 5_000)
        val pointX = layout.onFeed.midX
        val pointY = layout.onFeed.midY + 64f
        val dashboard = MonitorCommandDashboardLayout.frame(checkNotNull(layout.field))
        assertTrue("The sample must lie in the actual dashboard viewport", pointX in dashboard.x..dashboard.maxX &&
            pointY in dashboard.y..dashboard.maxY)
        assertPaint(if (portrait) "portrait-COMMAND" else "landscape-COMMAND", PixelColor.GREEN)
        composeRule.onNodeWithTag("SIMULATED.waiting").assertDoesNotExist()
        assertTrue("Command must not clear the source's waiting state", waiting)
        assertEquals(1, created)
        assertEquals(0, released)
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
        val namespace = "SIMULATED.command-waiting.${UUID.randomUUID()}"
        composeRule.setContent {
            val context = LocalContext.current
            val localDensity = LocalDensity.current
            val settings = remember { OperatorSettings(context.getSharedPreferences(namespace, Context.MODE_PRIVATE)) }
            val scope = rememberCoroutineScope()
            val control = remember { MonitorControlModel(scope) }
            val assists = remember { idleNikonAssists() }
            display = rememberTestOperatorSession(assists, settings)
            remember(display) { display.declare(MonitorDisplayMode.entries); true }
            val owner = remember { Any() }
            val identity = remember { MonitorOperatorLiveIdentity(null, null, owner, monitor = "SIMULATED") }
            DisposableEffect(Unit) { onDispose { control.unbind(); context.getSharedPreferences(namespace, Context.MODE_PRIVATE).edit().clear().apply() } }
            OpenZCineTheme {
                BoxWithConstraints(Modifier.fillMaxSize()) {
                    density = localDensity.density
                    layout = LiveMonitorLayout.fieldMonitor(maxWidth.value, maxHeight.value, 0f, 0f, 0f, 0f,
                        showsBottomBars = false, pictureAspect = 16f / 9f, showsValues = false)
                    val frame = layout.onFeed
                    MonitorOperatorLiveSurface(control, display,
                        MonitorOperatorLiveLayout(layout, null, frame, MonitorRect(0f, 0f, maxWidth.value, maxHeight.value), 16f / 9f),
                        MonitorOperatorLiveSource<String, String>(identity = { identity }, available = emptySet(),
                            picture = MonitorOperatorLivePicture(16f / 9f, waiting, false, false, false),
                            status = MonitorOperatorLiveStatus({ MonitorStatusPresentation(null) }, false, false,
                                null, emptyList(), null, null, null), cameraBattery = null,
                            capture = MonitorOperatorCaptureInputs(emptyList(), open = {}, dismiss = {}),
                            record = MonitorOperatorRecordSource(false, false, false, null),
                            exposure = null, level = null, levelViewFlip = false, audio = null, readOnly = false,
                            borrowed = false, returnToStage = null, coverOpen = false, note = null,
                            clearNote = {}, vpnActive = { false }, settings = {}, media = {}),
                        MonitorOperatorLiveAssists(null, emptyList(), emptySet(), null, MonitorOperatorSignalOptions(),
                            MonitorToolUsageState(), {}, emptyMap()),
                        MonitorOperatorBodyViews(dashboard = { Box(Modifier.fillMaxSize().background(Color.Green)
                            .testTag("SIMULATED.dashboard")) }, waitingPicture = {
                            // Faithful later notice producer: opaque feed plate, still supplied in Command.
                            if (waiting) Box(Modifier.offset { IntOffset((frame.x * density).roundToInt(), (frame.y * density).roundToInt()) }
                                .size(frame.width.dp, frame.height.dp).background(Color.Black).testTag("SIMULATED.waiting"),
                                contentAlignment = Alignment.Center) {
                                Text("SIMULATED waiting picture", color = Color.White, modifier = Modifier.offset(y = (-48).dp))
                                Box(Modifier.offset(y = 64.dp).size(32.dp).background(Color.Magenta))
                            }
                        }), modifier = Modifier.fillMaxSize(), picture = {
                            AndroidView(factory = { View(it).also { view ->
                                view.setBackgroundColor(PixelColor.BLUE); native = view; created += 1
                            } }, modifier = Modifier.fillMaxSize(), onRelease = { released += 1 })
                        }, cameraPanel = { _, _, _, _ -> }, photoRelease = null)
                }
            }
        }
        composeRule.waitUntil(5_000) { native != null }
        composeRule.waitForIdle()
    }

    private fun assertPaint(name: String, expected: Int, detail: Boolean = true) {
        composeRule.waitForIdle()
        val root = composeRule.onRoot().fetchSemanticsNode().boundsInWindow
        val x = (root.left + layout.onFeed.midX * density).roundToInt()
        val y = (root.top + (layout.onFeed.midY + if (detail) 64f else -64f) * density).roundToInt()
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val image = requireNotNull(instrumentation.uiAutomation.takeScreenshot())
        try {
            val file = instrumentation.targetContext.filesDir.resolve("SIMULATED-command-waiting-$name.png")
            file.outputStream().use { assertTrue(image.compress(Bitmap.CompressFormat.PNG, 100, it)) }
            val pixel = image.getPixel(x, y)
            println("SIMULATED full-window paint $name x=$x y=$y pixel=$pixel expected=$expected native=$created/$released")
            assertEquals("Full-window paint must show the expected layer at the actual overlap", expected, pixel)
        } finally { image.recycle() }
    }
}

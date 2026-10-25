package com.opencapture.openzcine

import android.content.Context
import android.content.pm.ActivityInfo
import android.content.res.Configuration
import android.graphics.Bitmap
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.hasContentDescription
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.runner.lifecycle.ActivityLifecycleMonitorRegistry
import androidx.test.runner.lifecycle.Stage
import com.opencapture.opencine.appkit.MonitorControlModel
import com.opencapture.opencine.appkit.MonitorDisplayMode
import com.opencapture.opencine.appkit.MonitorOperatorSessionModel
import com.opencapture.opencine.nikon.CameraIdentity
import com.opencapture.opencine.nikon.FakeCameraSession
import com.opencapture.opencine.nikon.LiveFrame
import com.opencapture.opencine.nikon.LiveFrameSource
import com.opencapture.opencine.nikon.LiveFrameTimecode
import com.opencapture.opencine.nikon.NikonOpenCineSession
import com.opencapture.openzcine.settings.OperatorSettings
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import java.io.ByteArrayOutputStream
import java.util.UUID
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.runBlocking

/**
 * Hardware pass 1.3: DISP 3's hero owns the record chip and the timecode, so the live header's
 * clock never repeats it above the dashboard, in either orientation. SIMULATED body.
 */
@OptIn(ExperimentalTestApi::class)
@RunWith(AndroidJUnit4::class)
class CommandHeaderComposeTest {
    @get:Rule val composeRule = createComposeRule()
    private lateinit var display: MonitorOperatorSessionModel
    private val timecode = SemanticsMatcher("a timecode readout") { node ->
        node.config.getOrNull(SemanticsProperties.ContentDescription)?.any { it.startsWith("Timecode") } == true
    }
    private val hero = hasTestTag("monitor.command.hero")
    private val iso = hasContentDescription("ISO:", substring = true)

    @Test fun portraitCommandShowsOnlyTheHeroTimecode(): Unit = onlyTheHero(portrait = true)

    @Test fun landscapeCommandShowsOnlyTheHeroTimecode(): Unit = onlyTheHero(portrait = false)

    private fun onlyTheHero(portrait: Boolean) {
        show(portrait)
        composeRule.waitUntil(15_000) { composeRule.onAllNodes(timecode, useUnmergedTree = true).fetchSemanticsNodes().isNotEmpty() }
        composeRule.runOnIdle { assertTrue(display.select(MonitorDisplayMode.COMMAND)) }
        composeRule.waitUntilAtLeastOneExists(iso, 15_000)
        composeRule.waitUntilAtLeastOneExists(hero, 15_000)
        composeRule.waitForIdle()
        val clocks = composeRule.onAllNodes(timecode, useUnmergedTree = true).fetchSemanticsNodes()
        val heroes = composeRule.onAllNodes(timecode and hero, useUnmergedTree = true).fetchSemanticsNodes()
        assertEquals("DISP 3 must show one timecode, its hero: ${clocks.map { it.config }}", 1, clocks.size)
        assertEquals(1, heroes.size)
        // Live keeps the header's clock.
        composeRule.runOnIdle { assertTrue(display.select(MonitorDisplayMode.LIVE)) }
        composeRule.waitUntil(15_000) {
            composeRule.onAllNodes(hero, useUnmergedTree = true).fetchSemanticsNodes().isEmpty() &&
                composeRule.onAllNodes(timecode, useUnmergedTree = true).fetchSemanticsNodes().isNotEmpty()
        }
    }

    /** A SIMULATED body that reports a running timecode, so the live header draws its clock. */
    private object TimecodeFrames : LiveFrameSource {
        private val jpeg = ByteArrayOutputStream().use { output ->
            val bitmap = Bitmap.createBitmap(160, 90, Bitmap.Config.ARGB_8888)
            bitmap.compress(Bitmap.CompressFormat.JPEG, 80, output)
            bitmap.recycle()
            output.toByteArray()
        }
        override val frames = flow {
            var frame = 0
            while (true) {
                emit(LiveFrame(System.nanoTime(), jpeg, timecode = LiveFrameTimecode(true, 1, 2, 3, frame++ % 25)))
                delay(200)
            }
        }
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
        val session = FakeCameraSession(CameraIdentity("SIMULATED", "SIMULATED", "command-header"))
        runBlocking { session.connect() }
        val namespace = "SIMULATED.command-header.${UUID.randomUUID()}"
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
                    operatorSession = display, frameSource = TimecodeFrames, assists = assists, operatorSettings = settings,
                    sessionRecoveryEnabled = false,
                )
            }
        }
        composeRule.waitUntil(15_000) {
            ::display.isInitialized && display.interactive && !display.locked && MonitorDisplayMode.COMMAND in display.modes
        }
    }
}

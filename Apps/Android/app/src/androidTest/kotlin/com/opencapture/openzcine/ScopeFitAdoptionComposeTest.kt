package com.opencapture.openzcine

import android.content.Context
import android.graphics.Bitmap
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.requiredSize
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.unit.dp
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.opencapture.monitorui.MonitorAssistTool
import com.opencapture.opencine.appkit.MonitorControlModel
import com.opencapture.opencine.nikon.CameraIdentity
import com.opencapture.opencine.nikon.FakeCameraSession
import com.opencapture.opencine.nikon.LiveFrame
import com.opencapture.opencine.nikon.LiveFrameSource
import com.opencapture.opencine.nikon.NikonOpenCineSession
import com.opencapture.openzcine.settings.OperatorSettings
import java.io.ByteArrayOutputStream
import java.io.File
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.runBlocking
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/**
 * A1-20 (Android): portrait fit with three scopes on floats every scope as the shared movable
 * panel, as Pocket and Insta do. Before, Z alone stacked the first two under the picture and hid
 * the third. SIMULATED body and picture.
 */
@OptIn(ExperimentalTestApi::class)
@RunWith(AndroidJUnit4::class)
class ScopeFitAdoptionComposeTest {
    @get:Rule val composeRule = createComposeRule()

    private val scopes = listOf(MonitorAssistTool.WAVE, MonitorAssistTool.PARADE, MonitorAssistTool.HISTO)

    @Test fun portraitFitFloatsEveryActiveScope() {
        mount(Modifier.requiredSize(400.dp, 840.dp))
        for (tool in scopes) {
            composeRule.waitUntilAtLeastOneExists(hasTestTag("monitor.scope.panel.${tool.name}"), 5_000)
        }
    }

    /** Evidence: the monitor with the three scopes in the current orientation, saved for adb pull. */
    @Test fun scopeFitScreen() {
        mount(Modifier.fillMaxSize())
        runCatching {
            composeRule.waitUntil(5_000) {
                scopes.all { tool ->
                    composeRule.onAllNodes(hasTestTag("monitor.scope.panel.${tool.name}"))
                        .fetchSemanticsNodes().isNotEmpty()
                }
            }
        }
        Thread.sleep(1_500)
        val context = ApplicationProvider.getApplicationContext<Context>()
        val metrics = context.resources.displayMetrics
        val orientation = if (metrics.widthPixels > metrics.heightPixels) "landscape" else "portrait"
        val image = composeRule.onRoot().captureToImage().asAndroidBitmap()
        File(context.getExternalFilesDir(null), "f11-scope-fit-$orientation.png").outputStream().use {
            image.compress(Bitmap.CompressFormat.PNG, 100, it)
        }
    }

    private fun mount(frame: Modifier) {
        val session = FakeCameraSession(CameraIdentity("SIMULATED", "SIMULATED", "scope-fit"))
        runBlocking { session.connect() }
        val assists = idleNikonAssists().also { assists -> scopes.forEach { assists.shared.toggle(it) } }
        val source = GreenPictureSource()
        composeRule.setContent {
            val context = LocalContext.current
            val settings = remember {
                OperatorSettings(context.getSharedPreferences("SIMULATED-scope-fit", Context.MODE_PRIVATE)
                    .also { it.edit().clear().commit() })
            }
            val scope = rememberCoroutineScope()
            val common = remember { NikonOpenCineSession(session, scope) }
            val control = remember { MonitorControlModel(scope).also { it.bind(common) } }
            DisposableEffect(Unit) { onDispose { control.unbind() } }
            OpenZCineTheme {
                Box(frame) {
                    MonitorScreen(session, common, control, rememberTestOperatorSession(assists, settings), source, assists,
                        settings, liveViewEnabled = true, sessionRecoveryEnabled = false)
                }
            }
        }
    }

    /** One green SIMULATED frame, then silence. */
    private class GreenPictureSource : LiveFrameSource {
        private val jpeg = ByteArrayOutputStream().use { output ->
            val bitmap = Bitmap.createBitmap(160, 90, Bitmap.Config.ARGB_8888)
            bitmap.eraseColor(android.graphics.Color.GREEN)
            bitmap.compress(Bitmap.CompressFormat.JPEG, 90, output)
            bitmap.recycle()
            output.toByteArray()
        }
        override val frames = flow { emit(LiveFrame(System.nanoTime(), jpeg)); awaitCancellation() }
    }
}

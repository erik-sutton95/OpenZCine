package com.opencapture.openzcine.relay

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.content.pm.ActivityInfo
import android.content.res.Configuration
import androidx.activity.ComponentActivity
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performTextInput
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.UiDevice
import com.opencapture.monitorui.MonitorPalette
import com.opencapture.openzcine.OpenZCineTheme
import com.opencapture.opencine.cameracontrols.WatcherBrowse
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.RuleChain
import org.junit.rules.TestRule
import org.junit.runner.RunWith
import org.junit.runners.model.Statement

/** SIMULATED shared browse rendering/actions over the real app host used at its actual entry. */
@RunWith(AndroidJUnit4::class)
class RelayWatcherBrowseComposeTest {
    private val compose = createAndroidComposeRule<ComponentActivity>()
    private val orientation = TestRule { base, _ ->
        object : Statement() {
            override fun evaluate() {
                val device = UiDevice.getInstance(InstrumentationRegistry.getInstrumentation())
                if (watcherProofOrientation() == Configuration.ORIENTATION_PORTRAIT) device.setOrientationNatural()
                else device.setOrientationLeft()
                try { base.evaluate() } finally { device.unfreezeRotation() }
            }
        }
    }
    @get:Rule val rules: RuleChain = RuleChain.outerRule(orientation).around(compose)

    @Test
    fun sharedBrowseUsesCurrentDiscoveryAndTheRealHostActions() {
        val expectedOrientation = watcherProofOrientation()
        if (expectedOrientation == Configuration.ORIENTATION_PORTRAIT) {
            compose.activityRule.scenario.onActivity {
                it.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
            }
            compose.activityRule.scenario.recreate()
        }
        compose.waitUntil(10_000) {
            compose.activity.resources.configuration.orientation == expectedOrientation
        }
        val feed = RelayBroadcast("SIMULATED deployed feed", "127.0.0.1", 65010, null)
        val feeds = mutableStateOf(emptyList<RelayBroadcast>())
        val state = mutableStateOf<RelayWatchUiState?>(null)
        val error = mutableStateOf<String?>(null)
        val joined = mutableListOf<RelayBroadcast>()
        val submitted = mutableListOf<String>()
        var finds = 0
        var closed = false
        val host = RelayWatcherBrowseHost({ feeds.value }, { state.value }, { error.value },
            { finds += 1 }, joined::add, submitted::add, { closed = true })
        compose.setContent {
            OpenZCineTheme {
                WatcherBrowse(host, modifier = Modifier.background(MonitorPalette.background).windowInsetsPadding(WindowInsets.safeDrawing),
                    networkInstructions = "SIMULATED supported local network", emptyMessage = "SIMULATED empty network")
            }
        }
        compose.onNodeWithText("Watch a feed").assertIsDisplayed()
        compose.onNodeWithText("SIMULATED empty network").performScrollTo().assertIsDisplayed()
        compose.runOnIdle { error.value = "SIMULATED discovery unavailable" }
        compose.onNodeWithText("SIMULATED discovery unavailable").performScrollTo().assertIsDisplayed()
        compose.onNodeWithText("Find shared feeds").performScrollTo().performClick()
        compose.runOnIdle { assertEquals(2, finds); error.value = null; feeds.value = listOf(feed) }
        compose.onNodeWithText(feed.name).performScrollTo().performClick()
        compose.runOnIdle { assertSame(feed, joined.single()); state.value = RelayWatchUiState() }
        compose.onNodeWithText("Joining…").performScrollTo().assertIsDisplayed()
        compose.runOnIdle {
            state.value = RelayWatchUiState(phase = RelayWatchUiState.Phase.DENIED,
                needsPasscode = true, failureReason = "SIMULATED wrong passcode")
        }
        compose.onNodeWithText("SIMULATED wrong passcode").performScrollTo().assertIsDisplayed()
        compose.onNodeWithText("Passcode").performScrollTo().assertIsDisplayed()
        saveWatcherProofImage(compose.onRoot().captureToImage().asAndroidBitmap(), "shared-browse", expectedOrientation)
        compose.onNodeWithText("Passcode").performScrollTo().performTextInput("  saved code  ")
        compose.onNodeWithText("Join").performScrollTo().performClick()
        compose.runOnIdle { assertEquals(listOf("saved code"), submitted) }
        compose.onNodeWithText("Close").performScrollTo().performClick()
        compose.runOnIdle { assertEquals(true, closed) }
    }
}

internal fun watcherProofOrientation(): Int =
    when (InstrumentationRegistry.getArguments().getString("z-watch-orientation") ?: "landscape") {
        "landscape" -> Configuration.ORIENTATION_LANDSCAPE
        "portrait" -> Configuration.ORIENTATION_PORTRAIT
        else -> error("Unknown requested watcher proof orientation")
    }

internal fun saveWatcherProofImage(bitmap: Bitmap, label: String, expectedOrientation: Int) {
    assertTrue("Captured root must have the requested orientation",
        if (expectedOrientation == Configuration.ORIENTATION_PORTRAIT) bitmap.width < bitmap.height
        else bitmap.width > bitmap.height)
    val context = InstrumentationRegistry.getInstrumentation().targetContext
    val output = File(context.getExternalFilesDir(null), "z-watch-entry-visual-v2").also { it.mkdirs() }
    val file = File(output, "SIMULATED-$label-${bitmap.width}x${bitmap.height}.png")
    file.outputStream().use { assertTrue("PNG encoding must succeed", bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)) }
    assertTrue("Saved PNG must contain bytes", file.length() > 0)
    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    BitmapFactory.decodeFile(file.path, bounds)
    assertEquals(bitmap.width, bounds.outWidth)
    assertEquals(bitmap.height, bounds.outHeight)
}

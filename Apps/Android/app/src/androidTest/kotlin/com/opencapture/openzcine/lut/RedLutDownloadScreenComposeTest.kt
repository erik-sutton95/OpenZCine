package com.opencapture.openzcine.lut

import android.content.res.Configuration
import android.graphics.Bitmap
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.test.assertAll
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.hasClickAction
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onAllNodesWithContentDescription
import androidx.compose.ui.test.onFirst
import androidx.compose.ui.test.onRoot
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.opencapture.openzcine.R
import java.io.File
import java.io.FileOutputStream
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** A4-45: the RED download gateway renders with monitor-ui actions; saves the screen for review. */
@RunWith(AndroidJUnit4::class)
class RedLutDownloadScreenComposeTest {
    @get:Rule
    val composeRule = createComposeRule()

    @Test
    fun gatewayRendersWithMonitorActions() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        var orientation = Configuration.ORIENTATION_UNDEFINED
        composeRule.setContent {
            orientation = LocalConfiguration.current.orientation
            RedLutDownloadScreen(AndroidLutLibrary(context), onClose = {})
        }
        composeRule.waitForIdle()

        // The top-leading close button and the gateway's own Close action share the label.
        val close = composeRule.onAllNodesWithContentDescription(context.getString(R.string.action_close))
        close.assertAll(hasClickAction())
        close.onFirst().assertIsDisplayed()
        val side = if (orientation == Configuration.ORIENTATION_LANDSCAPE) "landscape" else "portrait"
        val dir = File(context.filesDir, "f16p").apply { mkdirs() }
        FileOutputStream(File(dir, "red-gateway-$side.png")).use {
            composeRule.onRoot().captureToImage().asAndroidBitmap().compress(Bitmap.CompressFormat.PNG, 100, it)
        }
    }
}

package com.opencapture.openzcine

import android.content.pm.ActivityInfo
import android.content.res.Configuration
import android.graphics.Bitmap
import androidx.compose.ui.test.junit4.AndroidComposeTestRule
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File

/** Waits for the fixture activity's actual landscape layout before composing test content. */
internal fun AndroidComposeTestRule<*, *>.settleLandscape() {
    settleOrientation(landscape = true)
}

/** Waits for the fixture activity's actual portrait layout before composing test content. */
internal fun AndroidComposeTestRule<*, *>.settlePortrait() {
    settleOrientation(landscape = false)
}

private fun AndroidComposeTestRule<*, *>.settleOrientation(landscape: Boolean) {
    val host = activity
    val requested = if (landscape) ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE else ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
    val expected = if (landscape) Configuration.ORIENTATION_LANDSCAPE else Configuration.ORIENTATION_PORTRAIT
    runOnUiThread { host.requestedOrientation = requested }
    waitUntil(5_000) {
        val current = activity
        current.resources.configuration.orientation == expected &&
            (if (landscape) current.window.decorView.width > current.window.decorView.height
            else current.window.decorView.height > current.window.decorView.width)
    }
    waitForIdle()
}

/** Saves the whole display, including all four edges, to the target app's temporary cache. */
internal fun AndroidComposeTestRule<*, *>.saveLandscapeEvidence(name: String) {
    saveDisplayEvidence(name, landscape = true)
}

/** Saves the whole portrait display to the target app's temporary cache. */
internal fun AndroidComposeTestRule<*, *>.savePortraitEvidence(name: String) {
    saveDisplayEvidence(name, landscape = false)
}

private fun AndroidComposeTestRule<*, *>.saveDisplayEvidence(name: String, landscape: Boolean) {
    waitForIdle()
    val instrumentation = InstrumentationRegistry.getInstrumentation()
    instrumentation.waitForIdleSync()
    var screenshot: Bitmap? = null
    waitUntil(5_000) {
        val image = instrumentation.uiAutomation.takeScreenshot()
        if (image != null && (if (landscape) image.width > image.height else image.height > image.width)) {
            screenshot = image
            true
        } else {
            image?.recycle()
            false
        }
    }
    val image = requireNotNull(screenshot)
    try {
        val directory = File(instrumentation.targetContext.cacheDir, "diagnostics/ready")
        check(directory.mkdirs() || directory.isDirectory)
        File(directory, "$name.png").outputStream().use {
            check(image.compress(Bitmap.CompressFormat.PNG, 100, it))
        }
    } finally {
        image.recycle()
    }
}

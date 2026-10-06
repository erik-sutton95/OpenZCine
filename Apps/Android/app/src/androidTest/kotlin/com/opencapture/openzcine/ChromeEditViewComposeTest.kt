package com.opencapture.openzcine

import android.content.Context
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assert
import androidx.compose.ui.test.assertHeightIsAtLeast
import androidx.compose.ui.test.assertWidthIsAtLeast
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.unit.dp
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.opencapture.monitorui.MonitorRect
import com.opencapture.opencine.appkit.ChromeEditBadges
import com.opencapture.opencine.appkit.ChromeEditDoneBanner
import com.opencapture.openzcine.settings.CaptureLayoutMode
import com.opencapture.openzcine.settings.ChromeSection
import com.opencapture.openzcine.settings.MonitorDisplayMode
import com.opencapture.openzcine.settings.OperatorSettings
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** The Edit view is the shared chrome editor over Nikon's sections, on the capture side the body reports. */
@RunWith(AndroidJUnit4::class)
class ChromeEditViewComposeTest {
    @get:Rule val compose = createComposeRule()

    private val preferences =
        ApplicationProvider.getApplicationContext<Context>()
            .getSharedPreferences("chrome-edit-view-test", Context.MODE_PRIVATE)
            .apply { edit().clear().commit() }

    @Test
    fun eyeTogglesThePhotoSideAndDoneReturnsToSettings() {
        val settings = OperatorSettings(preferences)
        settings.beginChromeEditing(MonitorDisplayMode.LIVE)
        var returned = 0
        val host = NikonChromeEditHost(settings, CaptureLayoutMode.PHOTO) { returned += 1 }
        val photoBefore = settings.chrome(MonitorDisplayMode.LIVE, CaptureLayoutMode.PHOTO)[ChromeSection.STATUS_BAR].value
        val videoBefore = settings.chrome(MonitorDisplayMode.LIVE, CaptureLayoutMode.VIDEO)[ChromeSection.STATUS_BAR].value
        compose.setContent {
            Box(Modifier.fillMaxSize()) {
                ChromeEditBadges(
                    host, MonitorDisplayMode.LIVE,
                    mapOf(ChromeSection.STATUS_BAR to MonitorRect(69f, 16f, 678f, 42f)),
                    852f, 393f, touchTarget = MIN_TAP_TARGET_DP,
                )
                ChromeEditDoneBanner(host, MonitorDisplayMode.LIVE)
            }
        }

        val eye = compose.onNodeWithTag("monitor.chromeEdit.statusBar")
        eye.assert(SemanticsMatcher.expectValue(SemanticsProperties.ContentDescription, listOf("Status Bar")))
            .assertWidthIsAtLeast(MIN_TAP_TARGET_DP.dp)
            .assertHeightIsAtLeast(MIN_TAP_TARGET_DP.dp)
            .performClick()
        compose.waitForIdle()
        assertEquals(!photoBefore, settings.chrome(MonitorDisplayMode.LIVE, CaptureLayoutMode.PHOTO)[ChromeSection.STATUS_BAR].value)
        assertEquals(videoBefore, settings.chrome(MonitorDisplayMode.LIVE, CaptureLayoutMode.VIDEO)[ChromeSection.STATUS_BAR].value)

        compose.onNodeWithText("Editing Live").assertExists()
        compose.onNodeWithText("Done").performClick()
        compose.waitForIdle()
        assertNull(settings.chromeEditorMode)
        assertEquals(1, returned)
    }
}

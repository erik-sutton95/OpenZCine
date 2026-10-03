package com.opencapture.openzcine

import android.content.Context
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.opencapture.opencine.nikon.CameraIdentity
import com.opencapture.opencine.nikon.CameraSession
import com.opencapture.opencine.nikon.FakeCameraSession
import com.opencapture.openzcine.diagnostics.BugReportSubmitter
import com.opencapture.openzcine.diagnostics.SystemSettingsActions
import com.opencapture.openzcine.media.MediaCacheStore
import com.opencapture.openzcine.settings.OperatorSettings
import com.opencapture.openzcine.settings.OperatorSettingsScreen
import com.opencapture.openzcine.settings.OperatorSettingsTab
import java.nio.file.Files
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** SIMULATED inputs through the actual Nikon page and shared navigation/safety controls. */
@RunWith(AndroidJUnit4::class)
class NikonOperatorSettingsComposeTest {
    @get:Rule val composeRule = createComposeRule()

    @Test fun sharedSafetyControlsPersistExistingKeysAndEveryTabRemainsReachable() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val preferences = context.getSharedPreferences("z2-settings-page", Context.MODE_PRIVATE)
        preferences.edit().clear().putString("unrelated.operator.choice", "retained").commit()
        val settings = OperatorSettings(preferences)
        show(settings, OperatorSettingsTab.CONTROLS)

        for (label in listOf("Record confirmation", "Keep screen awake", "Haptics")) {
            composeRule.onNodeWithContentDescription(label).performScrollTo().performClick()
        }
        composeRule.runOnIdle {
            val reloaded = OperatorSettings(preferences)
            assertFalse(reloaded.recordConfirmationEnabled.value)
            assertFalse(reloaded.keepScreenAwake.value)
            assertFalse(reloaded.hapticsEnabled.value)
            assertFalse(preferences.getBoolean("controls.recordConfirmation", true))
            assertFalse(preferences.getBoolean("controls.keepScreenAwake", true))
            assertFalse(preferences.getBoolean("controls.haptics", true))
            assertEquals("retained", preferences.getString("unrelated.operator.choice", null))
        }
        for (tab in OperatorSettingsTab.entries) {
            composeRule.onNodeWithTag("monitor.settings.tab.${tab.title}")
                .performScrollTo().performClick().assertIsDisplayed()
        }
        preferences.edit().clear().commit()
    }

    @Test fun liveSessionWithoutDisconnectAuthorityOffersNoInertAction() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val preferences = context.getSharedPreferences("z2-settings-read-only", Context.MODE_PRIVATE)
        preferences.edit().clear().commit()
        val session = FakeCameraSession(CameraIdentity("SIMULATED", "SIMULATED", "settings-read-only"))
        runBlocking { session.connect() }
        show(OperatorSettings(preferences), OperatorSettingsTab.LINK, session)
        composeRule.onNodeWithText("Active link").assertIsDisplayed()
        composeRule.onNodeWithText("Disconnect").assertDoesNotExist()
        preferences.edit().clear().commit()
    }

    private fun show(
        settings: OperatorSettings, initial: OperatorSettingsTab, session: CameraSession? = null,
    ) {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val guide = LiveViewGuideController(context.getSharedPreferences("z2-settings-guide", Context.MODE_PRIVATE))
        val cache = MediaCacheStore(Files.createTempDirectory(context.cacheDir.toPath(), "z2-settings"))
        composeRule.setContent {
            OpenZCineTheme {
                OperatorSettingsScreen(
                    session = session, assistState = AssistState(FeedEffects.NONE, null),
                    settings = settings, mediaCacheStore = cache,
                    systemSettingsActions = NoExternalActions,
                    bugReportSubmitter = BugReportSubmitter { error("This page fixture never submits a report") },
                    liveViewGuideController = guide, onShowGuideOnNextRealFrame = {},
                    initialTab = initial, onClose = {},
                )
            }
        }
    }

    private object NoExternalActions : SystemSettingsActions {
        override fun openSupport(): Boolean = false
        override fun requestFeature(): Boolean = false
        override fun openGitHubBugReport(): Boolean = false
        override fun openSecurityAdvisory(): Boolean = false
        override fun openSource(): Boolean = false
        override fun openPrivacy(): Boolean = false
        override fun openTerms(): Boolean = false
        override fun shareDiagnostics(): Boolean = false
    }
}

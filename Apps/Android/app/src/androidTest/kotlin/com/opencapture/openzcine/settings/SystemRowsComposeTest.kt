package com.opencapture.openzcine.settings

import android.content.Context
import androidx.compose.ui.test.assertHeightIsAtLeast
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.unit.dp
import androidx.test.core.app.ApplicationProvider
import com.opencapture.monitorui.settings.MonitorSettingsTab
import com.opencapture.openzcine.OpenZCineTheme
import com.opencapture.openzcine.diagnostics.SystemSettingsActions
import com.opencapture.openzcine.idleNikonAssists
import com.opencapture.openzcine.rememberTestOperatorSession
import com.opencapture.openzcine.media.MediaCacheStore
import java.nio.file.Files
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test

class SystemRowsComposeTest {
    @get:Rule val compose = createComposeRule()
    private val context = ApplicationProvider.getApplicationContext<Context>()
    private val preferences = context.getSharedPreferences("system-rows-compose", Context.MODE_PRIVATE)
    private val cacheDirectory = Files.createTempDirectory(context.cacheDir.toPath(), "system-rows-compose")

    @Test
    fun reportProblemUsesTheNativeCallbackWhileFeatureRemainsAnExternalAction() {
        preferences.edit().clear().commit()
        val settings = OperatorSettings(preferences)
        val assists = idleNikonAssists()
        val cache = MediaCacheStore(cacheDirectory)
        val actions = RecordingSystemSettingsActions()
        var report = 0
        compose.setContent {
            OpenZCineTheme {
                OperatorSettingsScreen(
                    session = null,
                    assists = assists,
                    operatorSession = rememberTestOperatorSession(assists, settings),
                    settings = settings,
                    mediaCacheStore = cache,
                    systemSettingsActions = actions,
                    onReportProblem = { report += 1 },
                    initialTab = MonitorSettingsTab.SYSTEM,
                    onClose = {},
                )
            }
        }

        // The shared Help & Feedback card rows fire the app's recorded native actions.
        listOf("Open Support", "Report a Problem", "Request a Feature").forEach { description ->
            compose.onNodeWithContentDescription(description)
                .performScrollTo()
                .assertHeightIsAtLeast(48.dp)
                .performClick()
        }

        // Diagnostics sharing lives in the shared Diagnostic options card (Save diagnostic
        // report); the native shareDiagnostics callback remains the external action boundary.
        compose.onNodeWithText("Diagnostic options").performScrollTo().performClick()
        compose.onNodeWithText("Save", ignoreCase = true).performScrollTo().performClick()

        // The shared Project & Legal card rows are the operator's real web destinations
        // (browser launches owned by the shared card); the System tab still must present
        // each of them, so assert the wiring surface stays complete.
        listOf("Open Source Code", "Open Privacy Policy", "Open Terms of Use").forEach { description ->
            compose.onNodeWithContentDescription(description)
                .performScrollTo()
                .assertHeightIsAtLeast(48.dp)
                .assertIsDisplayed()
        }

        compose.runOnIdle {
            assertEquals(1, actions.support)
            assertEquals(1, report)
            assertEquals(1, actions.feature)
            assertEquals(1, actions.diagnostics)
        }
        // OpenCine's reporting rows: the automatic-reports row and the reporting privacy link.
        compose.onNodeWithText("Automatic error reports").performScrollTo().assertIsDisplayed()
        compose.onNodeWithText("Reporting Privacy").performScrollTo().assertIsDisplayed()
    }

    @After
    fun clearTestStores() {
        preferences.edit().clear().commit()
        cacheDirectory.toFile().deleteRecursively()
    }

    private class RecordingSystemSettingsActions : SystemSettingsActions {
        var support = 0
        var feature = 0
        var source = 0
        var privacy = 0
        var terms = 0
        var diagnostics = 0

        override fun openSupport(): Boolean = true.also { support += 1 }

        override fun requestFeature(): Boolean = true.also { feature += 1 }

        override fun openSource(): Boolean = true.also { source += 1 }

        override fun openPrivacy(): Boolean = true.also { privacy += 1 }

        override fun openTerms(): Boolean = true.also { terms += 1 }

        override fun shareDiagnostics(): Boolean = true.also { diagnostics += 1 }
    }
}

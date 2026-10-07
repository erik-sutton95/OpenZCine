package com.opencapture.openzcine.settings

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.assertHeightIsAtLeast
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.unit.dp
import com.opencapture.openzcine.OpenZCineTheme
import com.opencapture.openzcine.diagnostics.SystemSettingsActions
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test

class SystemRowsComposeTest {
    @get:Rule val compose = createComposeRule()

    @Test
    fun reportProblemUsesTheNativeCallbackWhileFeatureRemainsAnExternalAction() {
        val actions = RecordingSystemSettingsActions()
        var report = 0
        compose.setContent {
            OpenZCineTheme {
                Column(Modifier.verticalScroll(rememberScrollState())) {
                    SystemRows(
                        actions = actions,
                        onReportProblem = { report += 1 },
                    )
                }
            }
        }

        // The shared Help & Feedback and Project & Legal cards (iOS System page since #228).
        val actionDescriptions =
            listOf(
                "Open Support",
                "Report a Problem",
                "Request a Feature",
                "Share Diagnostics",
                "Open Source Code",
                "Open Privacy Policy",
                "Open Terms of Use",
            )
        actionDescriptions.forEach { description ->
            compose.onNodeWithContentDescription(description)
                .performScrollTo()
                .assertHeightIsAtLeast(48.dp)
                .performClick()
        }

        compose.runOnIdle {
            assertEquals(1, actions.support)
            assertEquals(1, report)
            assertEquals(1, actions.feature)
            assertEquals(1, actions.diagnostics)
            assertEquals(1, actions.source)
            assertEquals(1, actions.privacy)
            assertEquals(1, actions.terms)
        }
        // OpenCine's reporting rows: the automatic-reports row and the reporting privacy link.
        compose.onNodeWithText("Automatic error reports").performScrollTo().assertIsDisplayed()
        compose.onNodeWithText("Reporting Privacy").performScrollTo().assertIsDisplayed()
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

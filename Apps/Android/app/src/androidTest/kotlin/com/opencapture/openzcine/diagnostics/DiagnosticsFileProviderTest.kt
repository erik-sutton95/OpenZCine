package com.opencapture.openzcine.diagnostics

import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.core.content.IntentCompat
import androidx.test.core.app.ApplicationProvider
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class DiagnosticsFileProviderTest {
    @Test
    fun reportSharesOnlyThroughReadGrantedDiagnosticsAuthority() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val eventFile = File(context.filesDir, "diagnostics-test-${System.nanoTime()}/events.log")
        val store = DiagnosticEventStore(eventFile, nowMillis = { 1_000 })
        store.record(AndroidDiagnosticEvent.APP_LAUNCHED)
        val diagnostics =
            AndroidAppDiagnostics.createForTest(
                context = context,
                store = store,
                exitReader = HistoricalProcessExitReader { emptyList() },
            )

        val intent = requireNotNull(diagnostics.createShareIntent())
        val uri =
            requireNotNull(
                IntentCompat.getParcelableExtra(intent, Intent.EXTRA_STREAM, Uri::class.java),
            )

        assertEquals(Intent.ACTION_SEND, intent.action)
        assertEquals("text/plain", intent.type)
        assertEquals("${context.packageName}.diagnostics-share", uri.authority)
        assertTrue(intent.flags and Intent.FLAG_GRANT_READ_URI_PERMISSION != 0)
        assertTrue(uri.path.orEmpty().startsWith("/shared_diagnostics/"))
        val report =
            requireNotNull(context.contentResolver.openInputStream(uri)).bufferedReader().use {
                it.readText()
            }
        assertTrue(report.contains("OpenZCine Android Diagnostics"))
        assertTrue(report.contains("app.launched"))
        assertTrue(report.contains("No diagnostics are uploaded"))
    }

    @Test
    fun AndroidExitInfoIsReducedToClosedReasonAndImportanceEnums() {
        assertEquals(
            DiagnosticExitReason.CRASH,
            diagnosticExitReason(ApplicationExitInfo.REASON_CRASH),
        )
        assertEquals(
            DiagnosticExitReason.ANR,
            diagnosticExitReason(ApplicationExitInfo.REASON_ANR),
        )
        assertEquals(DiagnosticExitReason.OTHER, diagnosticExitReason(Int.MAX_VALUE))
        assertEquals(
            DiagnosticExitImportance.FOREGROUND,
            diagnosticExitImportance(
                ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND,
            ),
        )
        assertEquals(
            DiagnosticExitImportance.CACHED,
            diagnosticExitImportance(ActivityManager.RunningAppProcessInfo.IMPORTANCE_CACHED),
        )
    }

    @Test
    fun missingNativeIntentHandlerReturnsFalseWithoutLaunching() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val diagnostics =
            AndroidAppDiagnostics.createForTest(
                context = context,
                store =
                    DiagnosticEventStore(
                        File(context.filesDir, "diagnostics-handler-test/events.log"),
                    ),
                exitReader = HistoricalProcessExitReader { emptyList() },
            )
        val actions =
            AndroidSystemSettingsActions(
                context = context,
                diagnostics = diagnostics,
                intentLauncher = { false },
        )

        assertFalse(actions.openSupport())
        assertFalse(actions.requestFeature())
        assertFalse(actions.openGitHubBugReport())
        assertFalse(actions.openSecurityAdvisory())
        assertFalse(actions.openSource())
        assertFalse(actions.openPrivacy())
        assertFalse(actions.openTerms())
    }

    @Test
    fun githubBugReportUsesTheCanonicalIssueForm() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val diagnostics =
            AndroidAppDiagnostics.createForTest(
                context = context,
                store =
                    DiagnosticEventStore(
                        File(context.filesDir, "diagnostics-github-bug-report/events.log"),
                    ),
                exitReader = HistoricalProcessExitReader { emptyList() },
            )
        var launchedIntent: Intent? = null
        val actions =
            AndroidSystemSettingsActions(
                context = context,
                diagnostics = diagnostics,
                intentLauncher = { intent ->
                    launchedIntent = intent
                    true
                },
            )

        assertTrue(actions.openGitHubBugReport())
        assertEquals(Intent.ACTION_VIEW, launchedIntent?.action)
        assertEquals(AndroidSupportLinks.BUG_REPORT, launchedIntent?.dataString)
    }
}

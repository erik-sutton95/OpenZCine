package com.opencapture.openzcine.diagnostics

import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.content.ClipData
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.annotation.RequiresApi
import androidx.core.content.FileProvider
import com.opencapture.openzcine.BuildConfig
import java.io.File

private const val DIAGNOSTICS_AUTHORITY_SUFFIX = ".diagnostics-share"
internal const val DIAGNOSTICS_READY_RELATIVE_PATH: String = "diagnostics/ready"

internal fun interface HistoricalProcessExitReader {
    fun recentExits(): List<DiagnosticHistoricalExit>
}

/** Android 11+ process-exit reader reduced to a fixed privacy-safe schema. */
private class AndroidHistoricalProcessExitReader(private val context: Context) :
    HistoricalProcessExitReader {
    override fun recentExits(): List<DiagnosticHistoricalExit> =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            readApi30(context)
        } else {
            emptyList()
        }

    @RequiresApi(Build.VERSION_CODES.R)
    private fun readApi30(context: Context): List<DiagnosticHistoricalExit> {
        val activityManager = context.getSystemService(ActivityManager::class.java) ?: return emptyList()
        return runCatching {
            activityManager
                .getHistoricalProcessExitReasons(
                    context.packageName,
                    0,
                    DiagnosticReportRenderer.MAXIMUM_HISTORICAL_EXITS,
                )
                .map { info ->
                    DiagnosticHistoricalExit(
                        timestampMillis = info.timestamp.coerceAtLeast(0),
                        reason = diagnosticExitReason(info.reason),
                        importance = diagnosticExitImportance(info.importance),
                    )
                }
        }.getOrDefault(emptyList())
    }
}

internal fun diagnosticExitReason(reason: Int): DiagnosticExitReason =
    when (reason) {
        ApplicationExitInfo.REASON_ANR -> DiagnosticExitReason.ANR
        ApplicationExitInfo.REASON_CRASH -> DiagnosticExitReason.CRASH
        ApplicationExitInfo.REASON_CRASH_NATIVE -> DiagnosticExitReason.CRASH_NATIVE
        ApplicationExitInfo.REASON_DEPENDENCY_DIED -> DiagnosticExitReason.DEPENDENCY_DIED
        ApplicationExitInfo.REASON_EXCESSIVE_RESOURCE_USAGE ->
            DiagnosticExitReason.EXCESSIVE_RESOURCE_USAGE
        ApplicationExitInfo.REASON_INITIALIZATION_FAILURE ->
            DiagnosticExitReason.INITIALIZATION_FAILURE
        ApplicationExitInfo.REASON_LOW_MEMORY -> DiagnosticExitReason.LOW_MEMORY
        ApplicationExitInfo.REASON_PACKAGE_STATE_CHANGE ->
            DiagnosticExitReason.PACKAGE_STATE_CHANGE
        ApplicationExitInfo.REASON_PACKAGE_UPDATED -> DiagnosticExitReason.PACKAGE_UPDATED
        ApplicationExitInfo.REASON_PERMISSION_CHANGE -> DiagnosticExitReason.PERMISSION_CHANGE
        ApplicationExitInfo.REASON_SIGNALED -> DiagnosticExitReason.SIGNALED
        ApplicationExitInfo.REASON_USER_REQUESTED -> DiagnosticExitReason.USER_REQUESTED
        ApplicationExitInfo.REASON_USER_STOPPED -> DiagnosticExitReason.USER_STOPPED
        ApplicationExitInfo.REASON_UNKNOWN -> DiagnosticExitReason.UNKNOWN
        else -> DiagnosticExitReason.OTHER
    }

internal fun diagnosticExitImportance(importance: Int): DiagnosticExitImportance =
    when {
        importance <= ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND ->
            DiagnosticExitImportance.FOREGROUND
        importance <= ActivityManager.RunningAppProcessInfo.IMPORTANCE_VISIBLE ->
            DiagnosticExitImportance.VISIBLE
        importance <= ActivityManager.RunningAppProcessInfo.IMPORTANCE_SERVICE ->
            DiagnosticExitImportance.SERVICE
        importance < ActivityManager.RunningAppProcessInfo.IMPORTANCE_CACHED ->
            DiagnosticExitImportance.BACKGROUND
        importance < ActivityManager.RunningAppProcessInfo.IMPORTANCE_GONE ->
            DiagnosticExitImportance.CACHED
        else -> DiagnosticExitImportance.UNKNOWN
    }

/**
 * Process-local coordinator for privacy-bounded diagnostics and operator share reports.
 *
 * This class has no network dependency and performs no telemetry upload. Its
 * only external handoff is an explicit Android share intent for a report the
 * operator can inspect first.
 */
internal class AndroidAppDiagnostics private constructor(
    private val context: Context,
    private val store: DiagnosticEventStore,
    private val exitReader: HistoricalProcessExitReader,
) {
    fun record(event: AndroidDiagnosticEvent) {
        runCatching { store.record(event) }
    }

    /**
     * The opt-in anonymous-report activity log, reduced to closed event names.
     *
     * This is intentionally not [createReport]: it has no timestamps, Android
     * exit summaries, device details, or free-form local diagnostics content.
     */
    fun privacyFilteredActivityLog(): List<String> =
        runCatching { store.privacyFilteredActivityLog() }.getOrDefault(emptyList())

    fun createReport(): File? =
        runCatching {
            val readyDirectory = File(context.cacheDir, DIAGNOSTICS_READY_RELATIVE_PATH)
            readyDirectory.mkdirs()
            readyDirectory.listFiles()?.forEach(File::delete)
            val generatedAt = System.currentTimeMillis()
            val report =
                DiagnosticReportRenderer.render(
                    metadata =
                        DiagnosticReportMetadata(
                            generatedAtMillis = generatedAt,
                            appVersion = BuildConfig.VERSION_NAME,
                            buildNumber = BuildConfig.VERSION_CODE,
                            androidApi = Build.VERSION.SDK_INT,
                            deviceClass =
                                if (context.resources.configuration.smallestScreenWidthDp >= 600) {
                                    DiagnosticDeviceClass.TABLET
                                } else {
                                    DiagnosticDeviceClass.PHONE
                                },
                        ),
                    events = store.recentEvents(),
                    historicalExits = exitReader.recentExits(),
                )
            File(readyDirectory, "OpenZCine-Android-Diagnostics-$generatedAt.txt").also { file ->
                file.writeText(report, Charsets.UTF_8)
            }
        }.onSuccess {
            record(AndroidDiagnosticEvent.DIAGNOSTICS_EXPORTED)
        }.getOrNull()

    fun createShareIntent(): Intent? {
        val report = createReport() ?: return null
        val uri =
            runCatching {
                FileProvider.getUriForFile(
                    context,
                    context.packageName + DIAGNOSTICS_AUTHORITY_SUFFIX,
                    report,
                )
            }.getOrNull() ?: return null
        return Intent(Intent.ACTION_SEND).apply {
            type = "text/plain"
            putExtra(Intent.EXTRA_STREAM, uri)
            clipData = ClipData.newRawUri("OpenZCine diagnostics", uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
    }

    internal companion object {
        fun create(context: Context): AndroidAppDiagnostics =
            context.applicationContext.let { appContext ->
                AndroidAppDiagnostics(
                    context = appContext,
                    store =
                        DiagnosticEventStore(
                            File(appContext.filesDir, "diagnostics/events.log"),
                        ),
                    exitReader = AndroidHistoricalProcessExitReader(appContext),
                )
            }

        fun createForTest(
            context: Context,
            store: DiagnosticEventStore,
            exitReader: HistoricalProcessExitReader,
        ): AndroidAppDiagnostics = AndroidAppDiagnostics(context, store, exitReader)
    }
}

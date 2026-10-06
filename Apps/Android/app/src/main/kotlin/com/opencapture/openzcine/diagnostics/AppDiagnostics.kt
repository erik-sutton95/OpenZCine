package com.opencapture.openzcine.diagnostics

import android.content.Context
import android.net.ConnectivityManager
import com.opencapture.opencine.appkit.diagnostics.DiagnosticsHost
import com.opencapture.opencine.appkit.diagnostics.FeedIncidentOrigin
import com.opencapture.opencine.appkit.diagnostics.FeedIncidentRuntime
import com.opencapture.opencine.appkit.diagnostics.ManualProblemReport
import com.opencapture.opencine.appkit.diagnostics.ReliabilityReporting
import com.opencapture.opencine.appkit.diagnostics.ReliabilityReportingConsent
import com.opencapture.opencine.appkit.diagnostics.ReliabilityReportingDSN
import com.opencapture.opencine.appkit.diagnostics.ReliabilityReportingGate
import com.opencapture.opencine.appkit.diagnostics.ReliabilityReportingHostPolicy
import com.opencapture.opencine.vocabulary.PrivacyRedactor
import com.opencapture.openzcine.BuildConfig

/** The app's diagnostics: OpenCine's runtime with this app's names, destination, Sentry and OkHttp. */
internal object AppDiagnostics {
    val host =
        DiagnosticsHost(
            product = "OpenZCine",
            releasePackage = "com.opencapture.openzcine",
            versionName = BuildConfig.VERSION_NAME,
            versionCode = BuildConfig.VERSION_CODE,
            debug = BuildConfig.DEBUG,
            // ponytail: no git revision stamp in this build yet; Pocket's SOURCE_REVISION task if wanted.
            sourceRevision = "unknown",
            reportingDsn = BuildConfig.SENTRY_DSN_ANDROID,
            reportingClient = "openzcine-android",
            // iOS ReliabilityDiagnostics.supportEmail (unconfirmed); named only when a report cannot be sent.
            supportEmail = "support@opencapture.org",
            preferencesName = "openzcine.operator-settings",
            redact = PrivacyRedactor::redact,
        )
    val dsn = ReliabilityReportingDSN()
    val consent = ReliabilityReportingConsent(dsn)

    // The camera access point is 192.168.1.x, the most common home-router subnet, so an address
    // prefix would hold reports forever at home. The camera path is the process binding instead.
    val gate = ReliabilityReportingGate(consent, ReliabilityReportingHostPolicy(), cameraIPv4Prefix = "camera-path-is-bound")
    val origin = FeedIncidentOrigin({ null }, host.redact)
    val reporting =
        ReliabilityReporting(host, consent, dsn, gate, origin, ::SentryReliabilitySink) {
            manualReport.noteCameraPathClear()
        }
    val incidents = FeedIncidentRuntime(reporting)
    val manualReport = ManualProblemReport(host, dsn, gate, OkHttpManualReportUpload)

    /** Installs reporting once per process; the camera path is "this process is bound to the camera's Wi-Fi". */
    fun install(context: Context) {
        val app = context.applicationContext
        val connectivity = app.getSystemService(ConnectivityManager::class.java)
        incidents.install(app.filesDir)
        reporting.install(app, incidents)
        // After reporting.install, which sets its own address-prefix probe.
        gate.extraCameraPathProbe = { connectivity?.boundNetworkForProcess != null }
        manualReport.install(app)
    }
}

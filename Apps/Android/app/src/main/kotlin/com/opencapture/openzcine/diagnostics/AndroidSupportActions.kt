package com.opencapture.openzcine.diagnostics

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.net.toUri
import java.net.URLEncoder

/** Stable support and public-project destinations shared by Settings and tests. */
internal object AndroidSupportLinks {
    const val SUPPORT: String = "https://openzcine.app/support/"
    const val FEATURE_REQUEST: String =
        "https://github.com/erik-sutton95/OpenZCine/discussions/new?category=ideas-feature-requests"
    const val SOURCE: String = "https://github.com/erik-sutton95/OpenZCine"
    const val PRIVACY: String = "https://openzcine.app/privacy/"
    const val TERMS: String = "https://openzcine.app/terms/"
    private const val BUG_REPORT: String =
        "https://github.com/erik-sutton95/OpenZCine/issues/new"

    fun bugReport(metadata: AndroidSupportMetadata): String {
        val platform =
            "OpenZCine ${metadata.appVersion} (build ${metadata.buildNumber}), " +
                "Android API ${metadata.androidApi}, ${metadata.deviceClass.label}"
        return "$BUG_REPORT?template=bug_report.yml" +
            "&title=${queryValue("[Android] ")}" +
            "&platform=${queryValue(platform)}"
    }

    private fun queryValue(value: String): String =
        URLEncoder.encode(value, Charsets.UTF_8.name()).replace("+", "%20")
}

/** Closed, non-identifying metadata used only to prefill a public bug form. */
internal data class AndroidSupportMetadata(
    val appVersion: String,
    val buildNumber: Int,
    val androidApi: Int,
    val deviceClass: DiagnosticDeviceClass,
)

/** Actions exposed by the Android System settings tab. */
internal interface SystemSettingsActions {
    fun openSupport(): Boolean

    fun reportBug(): Boolean

    fun requestFeature(): Boolean

    fun openSource(): Boolean

    fun openPrivacy(): Boolean

    fun openTerms(): Boolean

    fun shareDiagnostics(): Boolean
}

/** Native intent launcher that returns false instead of throwing when no handler exists. */
internal class AndroidSystemSettingsActions(
    private val context: Context,
    private val diagnostics: AndroidAppDiagnostics,
    private val intentLauncher: (Intent) -> Boolean = { intent -> safeLaunch(context, intent) },
) : SystemSettingsActions {
    private val metadata: AndroidSupportMetadata
        get() =
            AndroidSupportMetadata(
                appVersion = com.opencapture.openzcine.BuildConfig.VERSION_NAME,
                buildNumber = com.opencapture.openzcine.BuildConfig.VERSION_CODE,
                androidApi = Build.VERSION.SDK_INT,
                deviceClass =
                    if (context.resources.configuration.smallestScreenWidthDp >= 600) {
                        DiagnosticDeviceClass.TABLET
                    } else {
                        DiagnosticDeviceClass.PHONE
                    },
            )

    override fun openSupport(): Boolean = openUri(AndroidSupportLinks.SUPPORT)

    override fun reportBug(): Boolean = openUri(AndroidSupportLinks.bugReport(metadata))

    override fun requestFeature(): Boolean = openUri(AndroidSupportLinks.FEATURE_REQUEST)

    override fun openSource(): Boolean = openUri(AndroidSupportLinks.SOURCE)

    override fun openPrivacy(): Boolean = openUri(AndroidSupportLinks.PRIVACY)

    override fun openTerms(): Boolean = openUri(AndroidSupportLinks.TERMS)

    override fun shareDiagnostics(): Boolean {
        val shareIntent = diagnostics.createShareIntent() ?: return false
        return intentLauncher(Intent.createChooser(shareIntent, "Share OpenZCine diagnostics"))
    }

    private fun openUri(value: String): Boolean =
        intentLauncher(Intent(Intent.ACTION_VIEW, value.toUri()))

    internal companion object {
        fun safeLaunch(context: Context, intent: Intent): Boolean {
            if (context !is Activity) intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            return try {
                context.startActivity(intent)
                true
            } catch (_: ActivityNotFoundException) {
                false
            } catch (_: SecurityException) {
                false
            }
        }
    }
}

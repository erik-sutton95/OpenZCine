package com.opencapture.openzcine.diagnostics

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import androidx.core.net.toUri

/** Stable support and public-project destinations shared by Settings and tests. */
internal object AndroidSupportLinks {
    const val SUPPORT: String = "https://openzcine.app/support/"
    const val FEATURE_REQUEST: String =
        "https://github.com/erik-sutton95/OpenZCine/discussions/new?category=ideas-feature-requests"
    const val SOURCE: String = "https://github.com/erik-sutton95/OpenZCine"
    const val PRIVACY: String = "https://openzcine.app/privacy/"
    const val TERMS: String = "https://openzcine.app/terms/"
    const val SECURITY_ADVISORY: String =
        "https://github.com/erik-sutton95/OpenZCine/security/advisories/new"
}

/** Actions exposed by the Android System settings tab. */
internal interface SystemSettingsActions {
    fun openSupport(): Boolean

    fun requestFeature(): Boolean

    fun openSecurityAdvisory(): Boolean

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
    override fun openSupport(): Boolean = openUri(AndroidSupportLinks.SUPPORT)

    override fun requestFeature(): Boolean = openUri(AndroidSupportLinks.FEATURE_REQUEST)

    override fun openSecurityAdvisory(): Boolean = openUri(AndroidSupportLinks.SECURITY_ADVISORY)

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

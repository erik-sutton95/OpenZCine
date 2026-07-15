package com.opencapture.openzcine

import android.content.res.Resources
import androidx.annotation.StringRes

/** Resolves typed Android resources for pure presentation builders and JVM-test fixtures. */
internal fun interface PhoneStringResolver {
    fun resolve(@StringRes resource: Int, vararg formatArgs: Any): String
}

/** Locale-aware production resolver backed by this app's current Android resources. */
internal fun Resources.phoneStringResolver(): PhoneStringResolver =
    PhoneStringResolver { resource, formatArgs -> getString(resource, *formatArgs) }

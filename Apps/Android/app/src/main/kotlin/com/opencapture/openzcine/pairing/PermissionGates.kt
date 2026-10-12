package com.opencapture.openzcine.pairing

import android.util.Log
import androidx.compose.runtime.Composable
import com.opencapture.opencine.appkit.PermissionGate

/** Saved "denied before" answers, so a denial survives process death and routes to Settings. */
private const val PERMISSIONS_PREFERENCES = "openzcine.permissions"

/**
 * OpenCine's permission gate with this app's saved answers and log. Every runtime permission this
 * app asks for goes through it: the dialog while Android still shows it, the app's Settings page
 * once it does not, and a fresh check on every return to the app.
 */
@Composable
internal fun rememberPermissionGate(
    label: String,
    needed: List<String>,
    request: List<String> = needed,
    onGranted: () -> Unit = {},
): PermissionGate =
    com.opencapture.opencine.appkit.rememberPermissionGate(
        label, needed, PERMISSIONS_PREFERENCES,
        log = { Log.i("OpenZCinePermissions", it) },
        request = request, onGranted = onGranted,
    )

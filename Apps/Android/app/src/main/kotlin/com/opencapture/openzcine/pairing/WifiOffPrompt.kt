package com.opencapture.openzcine.pairing

import android.content.Context
import android.content.Intent
import android.net.wifi.WifiManager
import android.provider.Settings
import androidx.annotation.StringRes
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import com.opencapture.openzcine.R

/**
 * Choose-time gate for every camera-AP flow: joining the camera's own network
 * needs the Wi‑Fi radio on, and with it off [CameraApJoiner] can only fail
 * silently after its scan waits. Defaults to `true` when the service is
 * missing — never block a join on a broken probe.
 */
internal fun isWifiRadioEnabled(context: Context): Boolean =
    context.applicationContext
        .getSystemService(WifiManager::class.java)
        ?.isWifiEnabled != false

/**
 * Whether this phone currently sits on a camera's own soft-AP network. Used to
 * block joins that cannot work from there (camera APs isolate their clients).
 * Reads the associated SSID, which needs the location permission the app
 * already holds for Wi‑Fi discovery; an unreadable SSID reports `false`.
 */
internal fun isOnCameraAccessPointNetwork(context: Context): Boolean {
    val wifi =
        context.applicationContext.getSystemService(WifiManager::class.java) ?: return false
    @Suppress("DEPRECATION")
    val raw = wifi.connectionInfo?.ssid ?: return false
    return looksLikeNikonAccessPointSsid(raw.trim().removeSurrounding("\""))
}

/**
 * Network-remedy prompt for camera-AP flows. Defaults to the "Wi‑Fi is off"
 * copy; the watch-blocked case reuses the same shape with its own strings.
 * The confirm button opens Android's system Wi‑Fi panel (API 29+, the app's
 * minSdk floor) so the operator can fix the network in place; they re-tap
 * afterwards.
 */
@Composable
internal fun WifiOffPromptDialog(
    onDismiss: () -> Unit,
    @StringRes title: Int = R.string.pairing_wifi_off_title,
    @StringRes message: Int = R.string.pairing_wifi_off_message,
) {
    val context = LocalContext.current
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(title)) },
        text = { Text(stringResource(message)) },
        confirmButton = {
            TextButton(
                onClick = {
                    onDismiss()
                    runCatching { context.startActivity(Intent(Settings.Panel.ACTION_WIFI)) }
                },
            ) {
                Text(stringResource(R.string.pairing_wifi_off_settings))
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text(stringResource(R.string.action_cancel))
            }
        },
    )
}

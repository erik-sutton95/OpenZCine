package com.opencapture.openzcine.pairing

import android.content.Context
import android.content.Intent
import android.net.wifi.WifiManager
import android.provider.Settings
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
 * "Wi‑Fi is off" prompt shown instead of starting a camera-AP join while the
 * radio is disabled. The confirm button opens Android's system Wi‑Fi panel
 * (API 29+, the app's minSdk floor) so the operator can flip it on in place;
 * they re-tap the setup afterwards.
 */
@Composable
internal fun WifiOffPromptDialog(onDismiss: () -> Unit) {
    val context = LocalContext.current
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.pairing_wifi_off_title)) },
        text = { Text(stringResource(R.string.pairing_wifi_off_message)) },
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

package com.opencapture.openzcine

import android.os.BatteryManager
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import kotlinx.coroutines.delay

private const val PHONE_BATTERY_REFRESH_MILLIS = 60_000L

/** Current Android-reported handset battery, refreshed without a synthetic fallback. */
@Composable
internal fun rememberPhoneBatteryPercent(): Int? {
    val context = LocalContext.current.applicationContext
    val manager = remember(context) { context.getSystemService(BatteryManager::class.java) }
    var percent by remember(manager) { mutableStateOf(readPhoneBatteryPercent(manager)) }
    LaunchedEffect(manager) {
        while (true) {
            delay(PHONE_BATTERY_REFRESH_MILLIS)
            percent = readPhoneBatteryPercent(manager)
        }
    }
    return percent
}

/** Reads Android's capacity property and rejects its unavailable sentinel values. */
internal fun readPhoneBatteryPercent(manager: BatteryManager?): Int? =
    runCatching { manager?.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY) }
        .getOrNull()
        .let(::validBatteryPercent)

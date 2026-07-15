package com.opencapture.openzcine

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.BatteryManager
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import androidx.core.content.ContextCompat
import kotlin.math.roundToInt

/** Android handset battery percentage and externally powered state. */
internal data class PhoneBatteryReadout(
    val percent: Int?,
    val externalPower: Boolean?,
)

/** Current Android handset battery, refreshed immediately by the protected system broadcast. */
@Composable
internal fun rememberPhoneBatteryReadout(): PhoneBatteryReadout {
    val context = LocalContext.current.applicationContext
    val manager = remember(context) { context.getSystemService(BatteryManager::class.java) }
    var readout by remember(manager) {
        mutableStateOf(
            PhoneBatteryReadout(
                percent = readPhoneBatteryPercent(manager),
                externalPower = null,
            ),
        )
    }
    DisposableEffect(context, manager) {
        val receiver =
            object : BroadcastReceiver() {
                override fun onReceive(receiveContext: Context?, intent: Intent?): Unit {
                    readout = readPhoneBatteryReadout(intent, manager)
                }
            }
        var registered = false
        val stickyIntent =
            runCatching {
                ContextCompat.registerReceiver(
                    context,
                    receiver,
                    IntentFilter(Intent.ACTION_BATTERY_CHANGED),
                    ContextCompat.RECEIVER_NOT_EXPORTED,
                ).also { registered = true }
            }.getOrNull()
        if (stickyIntent != null) {
            readout = readPhoneBatteryReadout(stickyIntent, manager)
        }
        onDispose {
            if (registered) {
                runCatching { context.unregisterReceiver(receiver) }
            }
        }
    }
    return readout
}

/** Parses one battery broadcast, falling back only to Android's capacity property. */
internal fun readPhoneBatteryReadout(
    intent: Intent?,
    manager: BatteryManager?,
): PhoneBatteryReadout =
    phoneBatteryReadout(
        level = intent?.getIntExtra(BatteryManager.EXTRA_LEVEL, Int.MIN_VALUE),
        scale = intent?.getIntExtra(BatteryManager.EXTRA_SCALE, Int.MIN_VALUE),
        status = intent?.getIntExtra(BatteryManager.EXTRA_STATUS, BatteryManager.BATTERY_STATUS_UNKNOWN),
        fallbackPercent = readPhoneBatteryPercent(manager),
    )

/** Pure battery projection used by the receiver and JVM tests. */
internal fun phoneBatteryReadout(
    level: Int?,
    scale: Int?,
    status: Int?,
    fallbackPercent: Int?,
): PhoneBatteryReadout {
    val broadcastPercent =
        if (level != null && scale != null && level >= 0 && scale > 0) {
            validBatteryPercent((level.toDouble() * 100.0 / scale.toDouble()).roundToInt())
        } else {
            null
        }
    val externalPower =
        when (status) {
            BatteryManager.BATTERY_STATUS_CHARGING,
            BatteryManager.BATTERY_STATUS_FULL,
            -> true
            BatteryManager.BATTERY_STATUS_DISCHARGING,
            BatteryManager.BATTERY_STATUS_NOT_CHARGING,
            -> false
            else -> null
        }
    return PhoneBatteryReadout(
        percent = broadcastPercent ?: validBatteryPercent(fallbackPercent),
        externalPower = externalPower,
    )
}

/** Reads Android's capacity property and rejects its unavailable sentinel values. */
internal fun readPhoneBatteryPercent(manager: BatteryManager?): Int? =
    runCatching { manager?.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY) }
        .getOrNull()
        .let(::validBatteryPercent)

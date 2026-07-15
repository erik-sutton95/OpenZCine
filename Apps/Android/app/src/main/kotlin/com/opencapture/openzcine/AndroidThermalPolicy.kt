package com.opencapture.openzcine

import android.os.PowerManager
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext

/** Portable `ThermalTier` raw values mirrored by the shared Swift core. */
internal enum class AndroidThermalTier(internal val wireValue: Int) {
    NOMINAL(0),
    FAIR(1),
    SERIOUS(2),
    CRITICAL(3),
}

/**
 * Maps Android's host-only thermal signal onto the portable core tier.
 *
 * Android's light/moderate states are intentionally non-shedding `FAIR`;
 * severe starts the same gentle preview reduction as iOS `serious`, and
 * critical/emergency/shutdown use the strict preview-only critical cap.
 */
internal fun androidThermalTierFor(status: Int): AndroidThermalTier =
    when {
        status >= PowerManager.THERMAL_STATUS_CRITICAL -> AndroidThermalTier.CRITICAL
        status >= PowerManager.THERMAL_STATUS_SEVERE -> AndroidThermalTier.SERIOUS
        status >= PowerManager.THERMAL_STATUS_LIGHT -> AndroidThermalTier.FAIR
        else -> AndroidThermalTier.NOMINAL
    }

/** Observes real Android thermal status while this monitor is composed. */
@Composable
internal fun rememberAndroidThermalTier(): AndroidThermalTier {
    val context = LocalContext.current
    val powerManager = remember(context) { context.getSystemService(PowerManager::class.java) }
    var thermalStatus by remember(powerManager) {
        mutableIntStateOf(powerManager?.currentThermalStatus ?: PowerManager.THERMAL_STATUS_NONE)
    }
    DisposableEffect(powerManager, context) {
        val manager = powerManager
        if (manager == null) {
            onDispose {}
        } else {
            val listener = PowerManager.OnThermalStatusChangedListener { thermalStatus = it }
            manager.addThermalStatusListener(context.mainExecutor, listener)
            onDispose { manager.removeThermalStatusListener(listener) }
        }
    }
    return androidThermalTierFor(thermalStatus)
}

package com.opencapture.openzcine.transport

import android.content.Context
import android.net.wifi.WifiManager
import android.util.Log

/**
 * Holds Wi-Fi in low-latency mode while a wireless camera session is live.
 *
 * Live view is a strict request/response pull loop: the app asks for a frame and waits. Wi-Fi
 * power save is built for the opposite traffic — bursty, tolerant of a wake delay — so between
 * frames the radio is free to doze, and every frame pays the wake on the way back. The policy that
 * decides how aggressively it dozes is vendor firmware, and it is markedly more aggressive on some
 * silicon than others.
 *
 * That last point is why this exists rather than something cleverer. A field report says a
 * COMPETITOR's app shows the same platform-shaped latency split we do — and nothing in our code is
 * shared with theirs. What both sit on is the platform's power management, and neither app can
 * have been holding this lock.
 *
 * `WIFI_MODE_FULL_LOW_LATENCY` is the mode the platform provides for exactly this case. It only
 * takes effect while the app is in the foreground, which is precisely when a monitor is being
 * watched, and the platform drops it for us otherwise — so there is no battery trap here for an
 * operator who backgrounds the app with a camera still connected.
 *
 * Cable sessions do not take it: there is no radio in that path to keep awake.
 */
public class WifiLowLatencyLock(context: Context) {
    private val wifi = context.applicationContext.getSystemService(WifiManager::class.java)
    private var lock: WifiManager.WifiLock? = null

    /** Idempotent. */
    public fun acquire() {
        if (lock?.isHeld == true) return
        val manager = wifi ?: return
        val held =
            runCatching {
                    manager
                        .createWifiLock(WifiManager.WIFI_MODE_FULL_LOW_LATENCY, TAG)
                        .apply {
                            setReferenceCounted(false)
                            acquire()
                        }
                }
                .onFailure { Log.w(TAG, "wifi low-latency lock unavailable: ${it.message}") }
                .getOrNull()
        lock = held
        if (held?.isHeld == true) Log.i(TAG, "wifi low-latency lock held")
    }

    /** Idempotent, and safe to call for a lock that was never taken. */
    public fun release() {
        val current = lock ?: return
        lock = null
        runCatching { if (current.isHeld) current.release() }
            .onFailure { Log.w(TAG, "wifi lock release failed: ${it.message}") }
    }

    private companion object {
        const val TAG = "openzcine:live-view"
    }
}

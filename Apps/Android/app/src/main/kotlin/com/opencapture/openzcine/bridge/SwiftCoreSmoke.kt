package com.opencapture.openzcine.bridge

import android.util.Log

/**
 * Debug-only smoke check proving the Swift core answers over JNI: logs the
 * core version, one real protocol-logic round trip, and callback deliveries
 * under the `SwiftCoreSmoke` logcat tag.
 */
object SwiftCoreSmoke {
    private const val TAG = "SwiftCoreSmoke"

    /** Sample PTP friendly name a Nikon ZR reports over PTP-IP discovery. */
    const val SAMPLE_CAMERA_NAME = "ZR_6001234"

    /**
     * Formats the smoke-report lines. Pure — unit-testable without the
     * native library.
     */
    fun formatReport(version: String, ssid: String?, displayName: String): List<String> =
        listOf(
            "core: $version",
            "ssid($SAMPLE_CAMERA_NAME): ${ssid ?: "<none>"}",
            "displayName($SAMPLE_CAMERA_NAME): $displayName",
        )

    /** Runs the smoke check; logs a warning instead of crashing when the .so is absent. */
    fun run() {
        if (!SwiftCore.isAvailable) {
            Log.w(TAG, "libOpenZCineAndroid.so not bundled — run `just android-core` before installing")
            return
        }
        formatReport(
            version = SwiftCore.coreVersion(),
            ssid = SwiftCore.deriveAccessPointSSID(SAMPLE_CAMERA_NAME),
            displayName = SwiftCore.resolveDisplayName(SAMPLE_CAMERA_NAME),
        ).forEach { Log.i(TAG, it) }
        SwiftCore.startConnectionDemo { title, detail ->
            Log.i(TAG, "phase: $title — $detail")
        }
    }
}

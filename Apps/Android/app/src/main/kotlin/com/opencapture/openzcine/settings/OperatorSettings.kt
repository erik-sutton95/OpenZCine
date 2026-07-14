package com.opencapture.openzcine.settings

import android.content.Context
import android.content.SharedPreferences
import androidx.compose.runtime.mutableStateOf

/**
 * Persisted operator preferences — the Android counterpart of the iOS shell's
 * `OperatorPreferences` (UserDefaults-backed). Each switch is Compose-observable
 * and writes through to app-private [SharedPreferences] on every change.
 *
 * ponytail: plain SharedPreferences, not DataStore — a handful of booleans read
 * once at composition needs no coroutine plumbing or new dependency.
 */
public class OperatorSettings(private val preferences: SharedPreferences) {

    public constructor(
        context: Context
    ) : this(context.getSharedPreferences(STORE_NAME, Context.MODE_PRIVATE))

    /** One persisted switch: Compose-observable value, write-through on set. */
    public inner class Toggle internal constructor(
        public val key: String,
        public val default: Boolean,
    ) {
        private val state = mutableStateOf(preferences.getBoolean(key, default))

        public var value: Boolean
            get() = state.value
            set(new) {
                state.value = new
                preferences.edit().putBoolean(key, new).apply()
            }

        public fun toggle() {
            value = !value
        }
    }

    // Display — live-status readout visibility (iOS `displayChrome.*Visible`).
    // AWAITING WIRING: the monitor `InfoPill` does not read these yet (the
    // monitor shell files are owned by the shell task); the switches persist
    // operator intent so the readout pass can consume them unchanged.
    public val recReadoutVisible: Toggle = Toggle("display.recReadout", default = true)
    public val codecReadoutVisible: Toggle = Toggle("display.codecReadout", default = true)
    public val mediaReadoutVisible: Toggle = Toggle("display.mediaReadout", default = true)
    public val fpsReadoutVisible: Toggle = Toggle("display.fpsReadout", default = true)

    // View Assist — tool enables (iOS `AssistConfiguration` tool toggles).
    // AWAITING WIRING: the feed-effects engine (PR #119) reads these when it
    // lands on this stack; until then the switches only record intent.
    public val falseColorEnabled: Toggle = Toggle("assist.falseColor", default = false)
    public val zebraEnabled: Toggle = Toggle("assist.zebra", default = false)
    public val peakingEnabled: Toggle = Toggle("assist.peaking", default = false)
    public val waveformEnabled: Toggle = Toggle("assist.waveform", default = false)

    /** Every persisted switch, for reset-to-defaults and key-collision checks. */
    public val all: List<Toggle> =
        listOf(
            recReadoutVisible,
            codecReadoutVisible,
            mediaReadoutVisible,
            fpsReadoutVisible,
            falseColorEnabled,
            zebraEnabled,
            peakingEnabled,
            waveformEnabled,
        )

    private companion object {
        const val STORE_NAME = "openzcine.operator-settings"
    }
}

/**
 * "0.1.117 (42)" — versionName (versionCode), matching the iOS System tab's
 * App Version row (`OperatorSettingsPanel.appVersionText`, marketing version +
 * build number).
 */
public fun appVersionText(versionName: String, versionCode: Int): String =
    "$versionName ($versionCode)"

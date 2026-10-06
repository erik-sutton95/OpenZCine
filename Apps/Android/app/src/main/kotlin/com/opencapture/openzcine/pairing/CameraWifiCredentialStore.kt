package com.opencapture.openzcine.pairing

import android.content.Context
import android.content.SharedPreferences
import com.opencapture.opencine.platform.KeystoreSeal

/**
 * Encrypted-at-rest storage for camera Wi-Fi keys, the Android counterpart of
 * the iOS Keychain-backed `CameraWiFiCredentialStore`: the camera-AP key is
 * entered once and remembered per SSID.
 *
 * Values are sealed by the shared [KeystoreSeal] (AES/GCM, non-exportable
 * Keystore key) under this app's alias and persisted in app-private
 * [SharedPreferences]; the preference names and alias are the installed data
 * contract. The plaintext key must never be logged or included in errors.
 */
public class CameraWifiCredentialStore(context: Context) : PairingCredentials {
    private val preferences: SharedPreferences =
        context.getSharedPreferences("openzcine.camera-wifi", Context.MODE_PRIVATE)
    private val seal = KeystoreSeal("openzcine.camera-wifi")

    override var lastSsid: String?
        get() = preferences.getString(LAST_SSID_PREFERENCE, null)
        set(value) {
            preferences.edit().putString(LAST_SSID_PREFERENCE, value?.trim()).apply()
        }

    /** The remembered Wi-Fi key for [ssid], or null when none is stored (or undecryptable). */
    override fun passphrase(ssid: String): String? =
        preferences.getString(entryName(ssid), null)?.let(seal::open)

    /** Remembers [passphrase] for [ssid], replacing any previous value. */
    override fun save(ssid: String, passphrase: String) {
        val sealed = seal.seal(passphrase) ?: return
        preferences.edit().putString(entryName(ssid), sealed).apply()
    }

    /** Forgets the key for [ssid]. */
    override fun remove(ssid: String) {
        preferences.edit().remove(entryName(ssid)).apply()
    }

    private fun entryName(ssid: String): String = "ssid:" + ssid.trim()

    private companion object {
        const val LAST_SSID_PREFERENCE = "last-ssid"
    }
}

package com.opencapture.openzcine.pairing

import android.content.Context
import android.content.SharedPreferences
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Encrypted-at-rest storage for camera Wi-Fi keys, the Android counterpart of
 * the iOS Keychain-backed `CameraWiFiCredentialStore`
 * (ios/Runner/CameraWiFiCredentialStore.swift): the camera-AP key is entered
 * once and remembered per SSID.
 *
 * Values are AES/GCM-encrypted with a non-exportable Android Keystore key and
 * persisted in app-private [SharedPreferences]. Jetpack Security's
 * `EncryptedSharedPreferences` is deprecated (the library was abandoned in
 * 2024); direct Keystore encryption is the current supported route.
 *
 * The plaintext key must never be logged or included in errors.
 */
public class CameraWifiCredentialStore(context: Context) : PairingCredentials {
    private val preferences: SharedPreferences =
        context.getSharedPreferences("openzcine.camera-wifi", Context.MODE_PRIVATE)

    override var lastSsid: String?
        get() = preferences.getString(LAST_SSID_PREFERENCE, null)
        set(value) {
            preferences.edit().putString(LAST_SSID_PREFERENCE, value?.trim()).apply()
        }

    /** The remembered Wi-Fi key for [ssid], or null when none is stored (or undecryptable). */
    override fun passphrase(ssid: String): String? {
        val stored = preferences.getString(entryName(ssid), null) ?: return null
        val parts = stored.split(SEPARATOR, limit = 2)
        if (parts.size != 2) return null
        return runCatching {
                val cipher = Cipher.getInstance(TRANSFORMATION)
                val iv = Base64.decode(parts[0], Base64.NO_WRAP)
                cipher.init(Cipher.DECRYPT_MODE, keystoreEntry(), GCMParameterSpec(128, iv))
                String(cipher.doFinal(Base64.decode(parts[1], Base64.NO_WRAP)), Charsets.UTF_8)
            }
            .getOrNull()
    }

    /** Remembers [passphrase] for [ssid], replacing any previous value. */
    override fun save(ssid: String, passphrase: String) {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, keystoreEntry())
        val sealed = cipher.doFinal(passphrase.toByteArray(Charsets.UTF_8))
        val value =
            Base64.encodeToString(cipher.iv, Base64.NO_WRAP) +
                SEPARATOR +
                Base64.encodeToString(sealed, Base64.NO_WRAP)
        preferences.edit().putString(entryName(ssid), value).apply()
    }

    private fun entryName(ssid: String): String = "ssid:" + ssid.trim()

    /** The non-exportable AES key, generated inside the Keystore on first use. */
    private fun keystoreEntry(): SecretKey {
        val keystore = KeyStore.getInstance(KEYSTORE).apply { load(null) }
        (keystore.getKey(ALIAS, null) as? SecretKey)?.let {
            return it
        }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, KEYSTORE)
        generator.init(
            KeyGenParameterSpec.Builder(
                    ALIAS,
                    KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
                )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .build()
        )
        return generator.generateKey()
    }

    private companion object {
        const val KEYSTORE = "AndroidKeyStore"
        const val ALIAS = "openzcine.camera-wifi"
        const val TRANSFORMATION = "AES/GCM/NoPadding"
        const val SEPARATOR = ":"
        const val LAST_SSID_PREFERENCE = "last-ssid"
    }
}

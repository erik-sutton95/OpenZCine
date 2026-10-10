package com.opencapture.openzcine.pairing

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith

/** Keys saved by the pre-shared store (its inline AES/GCM code, verbatim) still open after upgrade. */
@RunWith(AndroidJUnit4::class)
class CameraWifiCredentialStoreCompatTest {
    private val context = ApplicationProvider.getApplicationContext<Context>()
    private val preferences = context.getSharedPreferences("openzcine.camera-wifi", Context.MODE_PRIVATE)
    private val ssid = "Z_COMPAT_TEST"

    @After fun forget() {
        preferences.edit().remove("ssid:$ssid").apply()
    }

    @Test fun keySealedByThePreviousStoreStillOpens() {
        preferences.edit().putString("ssid:$ssid", legacySeal("camera-ap-key")).commit()
        assertEquals("camera-ap-key", CameraWifiCredentialStore(context).passphrase(" $ssid "))
    }

    @Test fun savedKeyRoundTripsAndRemoveForgetsIt() {
        val store = CameraWifiCredentialStore(context)
        store.save(ssid, "another-key")
        assertEquals("another-key", store.passphrase(ssid))
        store.remove(ssid)
        assertNull(store.passphrase(ssid))
    }

    private fun legacySeal(passphrase: String): String {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, legacyKey())
        val sealed = cipher.doFinal(passphrase.toByteArray(Charsets.UTF_8))
        return Base64.encodeToString(cipher.iv, Base64.NO_WRAP) + ":" + Base64.encodeToString(sealed, Base64.NO_WRAP)
    }

    private fun legacyKey(): SecretKey {
        val keystore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (keystore.getKey("openzcine.camera-wifi", null) as? SecretKey)?.let { return it }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        generator.init(
            KeyGenParameterSpec.Builder(
                "openzcine.camera-wifi",
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .build(),
        )
        return generator.generateKey()
    }
}

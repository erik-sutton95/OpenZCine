package com.opencapture.openzcine.frameio

import android.content.Context
import android.content.SharedPreferences
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import java.util.Base64 as JavaBase64
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** A refreshable OAuth token held only in encrypted Android app storage. */
internal class FrameioStoredToken(
    val accessToken: String,
    val refreshToken: String?,
    val expiresAtEpochMillis: Long,
    val tokenType: String,
) {
    override fun toString(): String = "FrameioStoredToken(redacted)"
}

/** A pending PKCE callback transaction that must remain encrypted at rest. */
internal class FrameioPendingAuthorization(
    val redirectURI: String,
    val state: String,
    val verifier: String,
    val createdAtEpochMillis: Long,
) {
    override fun toString(): String = "FrameioPendingAuthorization(redacted)"
}

/** Encrypted secret state for Frame.io. Neither value may enter normal preferences. */
internal class FrameioSecretState(
    val token: FrameioStoredToken?,
    val pendingAuthorization: FrameioPendingAuthorization?,
) {
    override fun toString(): String = "FrameioSecretState(redacted)"
}

/** Narrow test seam for the encrypted Frame.io token + PKCE state store. */
internal interface FrameioSecretStore {
    fun load(): FrameioSecretState

    fun saveToken(token: FrameioStoredToken)

    fun clearToken()

    fun savePendingAuthorization(pending: FrameioPendingAuthorization)

    fun clearPendingAuthorization()

    fun clearAll()
}

/**
 * Keystore-encrypted token and pending-PKCE store.
 *
 * This mirrors the camera Wi-Fi credential store but uses a distinct key and
 * file. AES-GCM ciphertext is app-private; the AES key never leaves Android
 * Keystore. A corrupt or undecryptable blob fails closed and is removed rather
 * than ever being treated as a signed-in state.
 */
internal class AndroidFrameioSecretStore(context: Context) : FrameioSecretStore {
    private val preferences: SharedPreferences =
        context.getSharedPreferences(PREFERENCES_NAME, Context.MODE_PRIVATE)

    @Synchronized
    override fun load(): FrameioSecretState {
        val encoded = preferences.getString(SECRET_PREFERENCE, null) ?: return FrameioSecretState(null, null)
        val decoded = runCatching { decrypt(encoded) }.getOrNull()
        val state = decoded?.let(FrameioSecretCodec::decode)
        if (state == null) {
            preferences.edit().remove(SECRET_PREFERENCE).apply()
            return FrameioSecretState(null, null)
        }
        return state
    }

    @Synchronized
    override fun saveToken(token: FrameioStoredToken) {
        val current = load()
        persist(FrameioSecretState(token, current.pendingAuthorization))
    }

    @Synchronized
    override fun clearToken() {
        val current = load()
        persist(FrameioSecretState(null, current.pendingAuthorization))
    }

    @Synchronized
    override fun savePendingAuthorization(pending: FrameioPendingAuthorization) {
        val current = load()
        persist(FrameioSecretState(current.token, pending))
    }

    @Synchronized
    override fun clearPendingAuthorization() {
        val current = load()
        persist(FrameioSecretState(current.token, null))
    }

    @Synchronized
    override fun clearAll() {
        preferences.edit().remove(SECRET_PREFERENCE).apply()
    }

    private fun persist(state: FrameioSecretState) {
        if (state.token == null && state.pendingAuthorization == null) {
            preferences.edit().remove(SECRET_PREFERENCE).apply()
            return
        }
        val ciphertext = encrypt(FrameioSecretCodec.encode(state))
        preferences.edit().putString(SECRET_PREFERENCE, ciphertext).apply()
    }

    private fun encrypt(plaintext: String): String {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, keystoreEntry())
        val sealed = cipher.doFinal(plaintext.toByteArray(Charsets.UTF_8))
        return listOf(
            FORMAT_VERSION,
            Base64.encodeToString(cipher.iv, Base64.NO_WRAP),
            Base64.encodeToString(sealed, Base64.NO_WRAP),
        ).joinToString(SEPARATOR)
    }

    private fun decrypt(encoded: String): String {
        val fields = encoded.split(SEPARATOR, limit = 3)
        require(fields.size == 3 && fields[0] == FORMAT_VERSION)
        val cipher = Cipher.getInstance(TRANSFORMATION)
        val iv = Base64.decode(fields[1], Base64.NO_WRAP)
        cipher.init(Cipher.DECRYPT_MODE, keystoreEntry(), GCMParameterSpec(128, iv))
        return String(cipher.doFinal(Base64.decode(fields[2], Base64.NO_WRAP)), Charsets.UTF_8)
    }

    private fun keystoreEntry(): SecretKey {
        val keystore = KeyStore.getInstance(KEYSTORE).apply { load(null) }
        (keystore.getKey(KEY_ALIAS, null) as? SecretKey)?.let { return it }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, KEYSTORE)
        generator.init(
            KeyGenParameterSpec.Builder(
                KEY_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            ).setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .build(),
        )
        return generator.generateKey()
    }

    private companion object {
        const val PREFERENCES_NAME = "openzcine.frameio"
        const val SECRET_PREFERENCE = "oauth-state.v1"
        const val KEYSTORE = "AndroidKeyStore"
        const val KEY_ALIAS = "openzcine.frameio.oauth"
        const val TRANSFORMATION = "AES/GCM/NoPadding"
        const val FORMAT_VERSION = "v1"
        const val SEPARATOR = ":"
    }
}

/** Versioned text codec kept independent of Keystore and Android JSON APIs for host-side tests. */
internal object FrameioSecretCodec {
    fun encode(state: FrameioSecretState): String =
        listOf(
            FORMAT_VERSION,
            state.token?.let(::encodeToken) ?: NONE,
            state.pendingAuthorization?.let(::encodePendingAuthorization) ?: NONE,
        ).joinToString(FIELD_SEPARATOR)

    fun decode(encoded: String): FrameioSecretState? {
        if (encoded.length > MAXIMUM_ENCODED_BYTES) return null
        val fields = encoded.split(FIELD_SEPARATOR)
        if (fields.size != 3 || fields[0] != FORMAT_VERSION) return null
        val token = if (fields[1] == NONE) null else decodeToken(fields[1]) ?: return null
        val pending =
            if (fields[2] == NONE) null else decodePendingAuthorization(fields[2]) ?: return null
        return FrameioSecretState(token, pending)
    }

    private fun encodeToken(token: FrameioStoredToken): String =
        listOf(
            TOKEN_MARKER,
            encodeString(token.accessToken),
            encodeNullableString(token.refreshToken),
            token.expiresAtEpochMillis.toString(),
            encodeString(token.tokenType),
        ).joinToString(PART_SEPARATOR)

    private fun decodeToken(encoded: String): FrameioStoredToken? {
        val fields = encoded.split(PART_SEPARATOR)
        if (fields.size != 5 || fields[0] != TOKEN_MARKER) return null
        val access = decodeString(fields[1])?.takeIf(String::isSafeHeaderValue) ?: return null
        val refresh = decodeNullableString(fields[2]) ?: return null
        val expiresAt = fields[3].toLongOrNull() ?: return null
        val type = decodeString(fields[4])?.takeIf(String::isNotBlank) ?: return null
        if (
            expiresAt <= 0 ||
                !type.equals("bearer", ignoreCase = true) ||
                (refresh.value != null && !refresh.value.isSafeHeaderValue())
        ) {
            return null
        }
        return FrameioStoredToken(access, refresh.value, expiresAt, type)
    }

    private fun encodePendingAuthorization(pending: FrameioPendingAuthorization): String =
        listOf(
            PENDING_MARKER,
            encodeString(pending.redirectURI),
            encodeString(pending.state),
            encodeString(pending.verifier),
            pending.createdAtEpochMillis.toString(),
        ).joinToString(PART_SEPARATOR)

    private fun decodePendingAuthorization(encoded: String): FrameioPendingAuthorization? {
        val fields = encoded.split(PART_SEPARATOR)
        if (fields.size != 5 || fields[0] != PENDING_MARKER) return null
        val redirect = decodeString(fields[1])?.takeIf(String::isNotBlank) ?: return null
        val state = decodeString(fields[2])?.takeIf(String::isNotBlank) ?: return null
        val verifier = decodeString(fields[3])?.takeIf(String::isNotBlank) ?: return null
        val createdAt = fields[4].toLongOrNull() ?: return null
        if (createdAt <= 0 || verifier.length !in 43..128) return null
        return FrameioPendingAuthorization(redirect, state, verifier, createdAt)
    }

    private fun encodeNullableString(value: String?): String =
        value?.let { present -> "$PRESENT_MARKER${encodeString(present)}" } ?: NONE

    private fun decodeNullableString(encoded: String): DecodedNullableString? =
        when {
            encoded == NONE -> DecodedNullableString(null)
            encoded.startsWith(PRESENT_MARKER) ->
                decodeString(encoded.removePrefix(PRESENT_MARKER))?.let(::DecodedNullableString)
            else -> null
        }

    private const val FORMAT_VERSION = "v1"
    private const val FIELD_SEPARATOR = "|"
    private const val PART_SEPARATOR = ","
    private const val NONE = "-"
    private const val PRESENT_MARKER = "s"
    private const val TOKEN_MARKER = "t"
    private const val PENDING_MARKER = "p"
    private const val MAXIMUM_ENCODED_BYTES = 32 * 1024
}

/** Persisted non-secret Frame.io project destination. */
internal data class FrameioDestination(
    val accountID: String,
    val workspaceID: String,
    val projectID: String,
    val projectName: String,
    val folderID: String,
)

/** Project selection does not contain bearer material, so it is stored separately. */
internal interface FrameioDestinationStore {
    fun load(): FrameioDestination?

    fun save(destination: FrameioDestination)

    fun clear()
}

/** App-private project-destination preferences. */
internal class AndroidFrameioDestinationStore(context: Context) : FrameioDestinationStore {
    private val preferences = context.getSharedPreferences(PREFERENCES_NAME, Context.MODE_PRIVATE)

    override fun load(): FrameioDestination? =
        preferences.getString(DESTINATION_PREFERENCE, null)?.let(FrameioDestinationCodec::decode)

    override fun save(destination: FrameioDestination) {
        preferences.edit().putString(DESTINATION_PREFERENCE, FrameioDestinationCodec.encode(destination)).apply()
    }

    override fun clear() {
        preferences.edit().remove(DESTINATION_PREFERENCE).apply()
    }

    private companion object {
        const val PREFERENCES_NAME = "openzcine.frameio"
        const val DESTINATION_PREFERENCE = "destination.v1"
    }
}

/** Pure destination codec used by the app-private preference adapter. */
internal object FrameioDestinationCodec {
    fun encode(destination: FrameioDestination): String =
        listOf(
            FORMAT_VERSION,
            encodeString(destination.accountID),
            encodeString(destination.workspaceID),
            encodeString(destination.projectID),
            encodeString(destination.projectName),
            encodeString(destination.folderID),
        ).joinToString(SEPARATOR)

    fun decode(encoded: String): FrameioDestination? {
        if (encoded.length > MAXIMUM_ENCODED_BYTES) return null
        val fields = encoded.split(SEPARATOR)
        if (fields.size != 6 || fields[0] != FORMAT_VERSION) return null
        val accountID = decodeString(fields[1])?.takeIf(String::isNotBlank) ?: return null
        val workspaceID = decodeString(fields[2])?.takeIf(String::isNotBlank) ?: return null
        val projectID = decodeString(fields[3])?.takeIf(String::isNotBlank) ?: return null
        val projectName = decodeString(fields[4])?.takeIf(String::isNotBlank) ?: return null
        val folderID = decodeString(fields[5])?.takeIf(String::isNotBlank) ?: return null
        return FrameioDestination(accountID, workspaceID, projectID, projectName, folderID)
    }

    private const val FORMAT_VERSION = "v1"
    private const val SEPARATOR = "|"
    private const val MAXIMUM_ENCODED_BYTES = 8 * 1024
}

private class DecodedNullableString(val value: String?)

private fun encodeString(value: String): String =
    JavaBase64.getUrlEncoder().withoutPadding().encodeToString(value.toByteArray(Charsets.UTF_8))

private fun decodeString(value: String): String? =
    runCatching { String(JavaBase64.getUrlDecoder().decode(value), Charsets.UTF_8) }.getOrNull()

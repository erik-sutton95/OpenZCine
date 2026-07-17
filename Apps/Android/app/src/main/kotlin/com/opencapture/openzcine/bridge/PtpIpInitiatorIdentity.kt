package com.opencapture.openzcine.bridge

import android.content.Context
import android.content.SharedPreferences
import java.security.SecureRandom

/**
 * Provides this Android installation's stable PTP-IP initiator identity.
 *
 * Nikon persists the 16-byte GUID sent in a PTP-IP `Init_Command_Request` as
 * part of a paired computer profile. The value must therefore survive app
 * relaunches, but is not a secret: it is stored as hexadecimal in normal
 * app-private [SharedPreferences]. The returned value is always a defensive
 * copy, so callers cannot mutate the persisted per-install identity.
 */
public class PtpIpInitiatorIdentity internal constructor(
    private val preferences: SharedPreferences,
) {
    /** Creates a provider backed by this app installation's private preferences. */
    public constructor(context: Context) :
        this(
            context.applicationContext.getSharedPreferences(
                PREFERENCES_NAME,
                Context.MODE_PRIVATE,
            ),
        )

    /**
     * Returns the stable 16-byte PTP-IP initiator GUID for this app install.
     *
     * A missing or malformed stored value is replaced atomically for this
     * process with a new cryptographically strong GUID, unless
     * [preferLegacyStaticIdentity] is true for a one-time upgrade carrying
     * already-saved Android camera profiles. That migration preserves profiles
     * created by the prior static Android initiator instead of silently
     * stranding them. Persistence uses [SharedPreferences.Editor.commit], so
     * this function never returns a newly generated or migrated identity unless
     * it was synchronously written first.
     *
     * @throws PtpIpInitiatorIdentityPersistenceException when a replacement
     * GUID could not be committed.
     */
    public fun guid(preferLegacyStaticIdentity: Boolean = false): ByteArray =
        synchronized(PERSISTENCE_LOCK) {
            PtpIpInitiatorGuidCodec.decode(readStoredGuid())?.copyOf()
                ?: persistGuid(
                    if (preferLegacyStaticIdentity) {
                        LEGACY_STATIC_ANDROID_GUID
                    } else {
                        PtpIpInitiatorGuidCodec.generate()
                    },
                )
        }

    private fun readStoredGuid(): String? =
        runCatching { preferences.getString(GUID_KEY, null) }.getOrNull()

    private fun persistGuid(guid: ByteArray): ByteArray {
        val persisted =
            preferences.edit().putString(GUID_KEY, PtpIpInitiatorGuidCodec.encode(guid)).commit()
        if (!persisted) {
            throw PtpIpInitiatorIdentityPersistenceException(
                "Could not persist the Android PTP-IP initiator identity.",
            )
        }
        return guid.copyOf()
    }

    internal companion object {
        const val PREFERENCES_NAME = "openzcine.ptp-ip-initiator"
        const val GUID_KEY = "guid-v1"

        private val PERSISTENCE_LOCK = Any()
        private val LEGACY_STATIC_ANDROID_GUID: ByteArray = "OpenZCineAndroid".encodeToByteArray()
    }
}

/** The per-install PTP-IP initiator identity could not be durably stored. */
public class PtpIpInitiatorIdentityPersistenceException(message: String) :
    IllegalStateException(message)

/**
 * Pure codec and generator policy for PTP-IP's required 16-byte initiator GUID.
 *
 * This deliberately uses a strict fixed-width hexadecimal representation so a
 * truncated, non-hex, or legacy value is never presented to the camera as a
 * different identity by accident.
 */
internal object PtpIpInitiatorGuidCodec {
    const val BYTE_COUNT = 16
    private const val HEX_LENGTH = BYTE_COUNT * 2
    private const val HEX_DIGITS = "0123456789abcdef"
    private val secureRandom = SecureRandom()

    /** Encodes exactly one PTP-IP initiator GUID. */
    fun encode(guid: ByteArray): String {
        require(guid.size == BYTE_COUNT) {
            "A PTP-IP initiator GUID must contain exactly $BYTE_COUNT bytes."
        }
        return buildString(HEX_LENGTH) {
            guid.forEach { byte ->
                val value = byte.toInt() and 0xff
                append(HEX_DIGITS[value ushr 4])
                append(HEX_DIGITS[value and 0x0f])
            }
        }
    }

    /** Decodes a complete 16-byte GUID, or rejects malformed persisted data. */
    fun decode(encoded: String?): ByteArray? {
        if (encoded?.length != HEX_LENGTH) return null
        val guid = ByteArray(BYTE_COUNT)
        for (index in guid.indices) {
            val high = encoded[index * 2].digitToIntOrNull(16) ?: return null
            val low = encoded[index * 2 + 1].digitToIntOrNull(16) ?: return null
            guid[index] = ((high shl 4) or low).toByte()
        }
        return guid
    }

    /** Generates a fresh 16-byte identity with the platform cryptographic RNG. */
    fun generate(): ByteArray = ByteArray(BYTE_COUNT).also(secureRandom::nextBytes)
}

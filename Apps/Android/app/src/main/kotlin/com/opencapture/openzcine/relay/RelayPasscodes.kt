package com.opencapture.openzcine.relay

import android.content.Context
import android.content.SharedPreferences
import com.opencapture.opencine.relayruntime.WatcherRelaySecrets
import com.opencapture.opencine.relayruntime.WatcherRelaySecrets.LegacyMove
import com.opencapture.opencine.relayruntime.WatcherRelaySecrets.Lookup

/**
 * App-owned legacy locations beside the shared device-only secure store. Failed migrations keep
 * the original credential usable and retry on reads, as on iOS. New answers never enter the old
 * plaintext files, and no length rule is applied to a credential already saved.
 */
class RelayPasscodes internal constructor(
    private val secure: RelaySecurePasscodes,
    private val legacyHost: SharedPreferences,
    private val legacyWatchers: SharedPreferences,
) {
    constructor(context: Context, service: String) : this(
        KeystoreRelayPasscodes(WatcherRelaySecrets(context.applicationContext, service)),
        context.applicationContext.getSharedPreferences(RelayBroadcastController.LEGACY_PASSCODE_STORE, Context.MODE_PRIVATE),
        context.applicationContext.getSharedPreferences("relay_passcodes", Context.MODE_PRIVATE),
    )

    init {
        hostPasscodeLookup()
        for ((host, value) in legacyWatchers.all) {
            if (value is String) rememberedPasscodeLookup(host)
        }
    }

    /** The effective credential, including an old copy that could not be securely migrated. */
    fun hostPasscodeLookup(): Lookup = lookup(
        legacyHost, RelayBroadcastController.LEGACY_PASSCODE_KEY,
        secure::hostPasscodeLookup, secure::adoptLegacyHostPasscode,
    )

    fun rememberedPasscodeLookup(host: String): Lookup = lookup(
        legacyWatchers, host, { secure.rememberedPasscodeLookup(host) },
        { secure.adoptLegacyRememberedPasscode(it, host) },
    )

    fun storeHostPasscode(code: String): Boolean = store(
        code, legacyHost, RelayBroadcastController.LEGACY_PASSCODE_KEY,
        secure::storeHostPasscode, secure::adoptLegacyHostPasscode,
    )

    fun storeRememberedPasscode(code: String, host: String): Boolean = store(
        code, legacyWatchers, host, { secure.storeRememberedPasscode(it, host) },
        { secure.adoptLegacyRememberedPasscode(it, host) },
    )

    private fun lookup(
        legacy: SharedPreferences, key: String, read: () -> Lookup, move: (String) -> LegacyMove,
    ): Lookup {
        val retained = legacy.getString(key, null)
        if (retained != null) {
            val result = move(retained)
            if (result.releasesLegacyCopy) {
                legacy.edit().remove(key).commit()
            } else if (retained.isNotEmpty()) {
                return Lookup.Stored(retained)
            }
        }
        return read()
    }

    private fun store(
        code: String, legacy: SharedPreferences, key: String,
        write: (String) -> Boolean, move: (String) -> LegacyMove,
    ): Boolean {
        if (code.isEmpty()) {
            // Secure the old credential before removing its only usable copy. Require the
            // removal's commit result even when a failed commit changed the in-memory view;
            // otherwise clearing the secure value can resurrect old plaintext after relaunch.
            val retained = legacy.getString(key, null)
            if (retained != null && !move(retained).releasesLegacyCopy) return false
            if (!legacy.edit().remove(key).commit()) return false
        }
        if (!write(code)) return false
        // The shared write returned true only after secure readback. A leftover older copy
        // cannot replace this verified credential; a later read retries its removal.
        if (code.isNotEmpty()) legacy.edit().remove(key).commit()
        return true
    }
}

/** Typed secure I/O; crypto, readback and migration rollback remain in OpenCine. */
internal interface RelaySecurePasscodes {
    fun hostPasscodeLookup(): Lookup
    fun rememberedPasscodeLookup(host: String): Lookup
    fun storeHostPasscode(code: String): Boolean
    fun storeRememberedPasscode(code: String, host: String): Boolean
    fun adoptLegacyHostPasscode(code: String): LegacyMove
    fun adoptLegacyRememberedPasscode(code: String, host: String): LegacyMove
}

private class KeystoreRelayPasscodes(private val secrets: WatcherRelaySecrets) : RelaySecurePasscodes {
    override fun hostPasscodeLookup(): Lookup = secrets.hostPasscodeLookup()
    override fun rememberedPasscodeLookup(host: String): Lookup = secrets.rememberedPasscodeLookup(host)
    override fun storeHostPasscode(code: String): Boolean = secrets.storeHostPasscode(code)
    override fun storeRememberedPasscode(code: String, host: String): Boolean = secrets.storeRememberedPasscode(code, host)
    override fun adoptLegacyHostPasscode(code: String): LegacyMove = secrets.adoptLegacyHostPasscode(code)
    override fun adoptLegacyRememberedPasscode(code: String, host: String): LegacyMove =
        secrets.adoptLegacyRememberedPasscode(code, host)
}

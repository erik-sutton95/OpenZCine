package com.opencapture.openzcine.relay

import android.content.Context
import java.util.UUID

/**
 * This install's stable relay identity.
 *
 * A host uses it to recognise a watcher across a reconnect, so a control token survives a blink on
 * a congested set (`RelayControlLease`). Persisted rather than derived: a device name is not
 * unique and an address is not stable, and this decides who may press record.
 *
 * App-private and never leaves the relay handshake — it names no person, device or network.
 */
public object RelayWatcherIdentity {
    private const val PREFS = "openzcine.relay"
    private const val KEY = "watcherId"

    public fun current(context: Context): String {
        val prefs = context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        prefs.getString(KEY, null)?.takeIf(String::isNotEmpty)?.let { return it }
        val minted = UUID.randomUUID().toString()
        prefs.edit().putString(KEY, minted).apply()
        return minted
    }
}

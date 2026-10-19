package com.opencapture.openzcine.settings

import com.opencapture.monitorui.MonitorWatcherPasscodeRule
import com.opencapture.openzcine.relay.RelayBroadcastController

/**
 * The Sharing tab's watcher passcode field without a live broadcast. Standalone Settings (no
 * camera connected) previously had no controller to ask, so a stored passcode showed empty and a
 * typed one was silently dropped (ZAB-352). The relay secrets store is the same one a broadcast
 * reads, so a code set here is in force when sharing starts.
 */
internal class RelayPasscodeField(
    private val controller: RelayBroadcastController?,
    private val readStored: () -> String?,
    private val storeStored: (String) -> Boolean,
) {
    /** The code in force: the live controller's, else the relay secrets store's. */
    val value: String get() = controller?.savedPasscode ?: readStored().orEmpty()

    /** Stores under the shared rule; a too-short entry or a store refusal changes nothing. */
    fun store(entry: String): Boolean {
        val next = MonitorWatcherPasscodeRule.entry(entry).passcode ?: return false
        return controller?.savePasscode(next) ?: storeStored(next)
    }
}

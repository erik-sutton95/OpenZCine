package com.opencapture.openzcine.settings

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
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
    /** The secrets store's code, read once and kept as Compose state so a stored code redraws. */
    private var standalone by mutableStateOf(readStored())

    /** The code in force: the live controller's, else the relay secrets store's. */
    val value: String get() = controller?.savedPasscode ?: standalone.orEmpty()

    /** Stores under the shared rule; a too-short entry or a store refusal changes nothing. */
    fun store(entry: String): Boolean {
        val next = MonitorWatcherPasscodeRule.entry(entry).passcode ?: return false
        controller?.let { return it.savePasscode(next) }
        if (!storeStored(next)) return false
        standalone = next
        return true
    }
}

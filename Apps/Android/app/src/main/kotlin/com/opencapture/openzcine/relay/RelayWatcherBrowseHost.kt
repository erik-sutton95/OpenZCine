package com.opencapture.openzcine.relay

import com.opencapture.opencine.cameracontrols.WatcherBrowseHost
import com.opencapture.opencine.cameracontrols.WatcherFeedRow
import com.opencapture.opencine.cameracontrols.WatcherJoinStatus

/** Thin browse values/actions over the deployed directory and controller; no second relay owner. */
internal class RelayWatcherBrowseHost(
    private val broadcasts: () -> List<RelayBroadcast>,
    private val status: () -> RelayWatchUiState?,
    private val browseError: () -> String?,
    private val browse: () -> Unit,
    private val join: (RelayBroadcast) -> Unit,
    private val submitPasscode: (String) -> Unit,
    private val close: () -> Unit,
) : WatcherBrowseHost {
    override val watcherFeeds: List<WatcherFeedRow>
        get() = broadcasts().map { WatcherFeedRow(it.name, it.name) }
    override val watcherBrowseError: String? get() = browseError()
    override val watcherPasscodeError: String?
        get() = status()?.takeIf { it.needsPasscode }?.failureReason
    override val watcherJoinStatus: WatcherJoinStatus
        get() = status()?.let { value ->
            when (value.phase) {
                RelayWatchUiState.Phase.CONNECTING -> WatcherJoinStatus.Connecting
                RelayWatchUiState.Phase.WATCHING -> WatcherJoinStatus.Live
                RelayWatchUiState.Phase.DENIED -> if (value.needsPasscode) WatcherJoinStatus.NeedsPasscode
                    else WatcherJoinStatus.Failed(value.failureReason ?: "The broadcast refused this device.")
                RelayWatchUiState.Phase.FAILED -> WatcherJoinStatus.Failed(value.failureReason ?: "The broadcast disconnected.")
            }
        } ?: WatcherJoinStatus.Idle
    override fun startWatcherBrowse() { browse() }
    override fun joinWatcherFeed(id: String) { broadcasts().firstOrNull { it.name == id }?.let(join) }
    override fun retryWatcherPasscode(code: String) { submitPasscode(code) }
    override fun stopWatching() { close() }
}

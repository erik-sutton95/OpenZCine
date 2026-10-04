@file:androidx.media3.common.util.UnstableApi

package com.opencapture.openzcine.media

import androidx.media3.common.Player
import com.opencapture.opencine.appkit.MonitorMediaLibraryModel
import com.opencapture.opencine.appkit.MonitorMediaRecord
import com.opencapture.opencine.appkit.MonitorPlaybackCandidate
import com.opencapture.opencine.media.*
import java.util.UUID
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlin.time.Duration

/** Logical/native item binding; actual growing DataSource, audio renderer and effects stay in
 * the existing native composition. Transfer teardown remains ahead of playlist navigation. */
internal class NikonPlaybackNativePort : MonitorPlaybackPort {
    override var onEvent: ((MonitorPlaybackItemToken, MonitorPlaybackEvent) -> Unit)? = null
    private var claimedOwner: UUID? = null
    private var token: MonitorPlaybackItemToken? = null
    private var source: MonitorPlaybackItem? = null
    private var installed: Attachment? = null
    private var pending: CompletableDeferred<MonitorPlaybackMetadata>? = null

    internal class Attachment(
        val token: MonitorPlaybackItemToken, val player: Player,
        private val beforeRelease: () -> Unit,
        val seekNative: (Long, Boolean) -> Unit,
    ) {
        private var closed = false
        fun close() {
            if (closed) return
            closed = true
            // Drop the picture reference and audio renderer before releasing this exact player.
            beforeRelease()
            player.pause()
            player.release()
        }
    }

    fun candidates(
        record: MonitorMediaRecord<NikonLibraryClip>, library: MonitorMediaLibraryModel<NikonLibraryClip>,
    ): List<MonitorPlaybackCandidate> {
        val representation = record.asset.representations.firstOrNull() ?: return emptyList()
        val address = record.address.representations[representation.id] ?: return emptyList()
        val item = MonitorPlaybackItem(
            library.cache.directory.file(address).toURI(),
            if (record.payload.clip.filename.endsWith(".MOV", ignoreCase = true)) "video/quicktime" else "video/mp4",
            record.asset.id.rawValue, representation.role,
        )
        source = item
        // Genuine canonical native address; GrowingFileDataSource remains bound to the captured
        // progressive entry, which can read its .part bytes before this final file is published.
        return listOf(MonitorPlaybackCandidate.Cached(item))
    }

    override fun retireItem(token: MonitorPlaybackItemToken) {
        if (claimedOwner != null && claimedOwner != token.owner) return
        if (claimedOwner == null && token.revision != 0L) return
        if (this.token?.let { token.revision < it.revision } == true) return
        retireNative()
        claimedOwner = token.owner
        this.token = token
        source = null
        pending = CompletableDeferred()
    }

    override suspend fun prepare(
        item: MonitorPlaybackItem, token: MonitorPlaybackItemToken, readyTimeout: Duration?,
    ): MonitorPlaybackMetadata {
        if (this.token != token || source != item) retired()
        val wait = pending ?: retired()
        val facts = wait.await()
        currentCoroutineContext().ensureActive()
        if (this.token != token || installed?.token != token) retired()
        return facts
    }

    fun attach(
        player: Player, token: MonitorPlaybackItemToken, beforeRelease: () -> Unit,
        seekNative: (Long, Boolean) -> Unit,
    ): Attachment {
        val captured = Attachment(token, player, beforeRelease, seekNative)
        if (this.token != token || source == null) {
            captured.close()
            return captured
        }
        installed = captured
        onEvent?.invoke(token, MonitorPlaybackEvent.ItemInstalled)
        if (this.token == token && installed === captured) {
            pending?.complete(MonitorPlaybackMetadata())
        }
        return captured
    }

    fun publish(attachment: Attachment?, event: MonitorPlaybackEvent) {
        if (attachment == null || installed !== attachment || token != attachment.token) return
        onEvent?.invoke(attachment.token, event)
    }

    fun fail(token: MonitorPlaybackItemToken, message: String) {
        if (this.token != token) return
        onEvent?.invoke(token, MonitorPlaybackEvent.Failed(message))
        if (this.token == token) pending?.completeExceptionally(
            MonitorPlaybackException(MonitorPlaybackFailure.NATIVE_FAILURE))
    }

    fun detach(attachment: Attachment) {
        attachment.close()
        if (installed === attachment) installed = null
    }

    override fun play(rate: Double, token: MonitorPlaybackItemToken) {
        current(token)?.setPlaybackSpeed(rate.toFloat())
        current(token)?.play()
    }

    override fun pause(token: MonitorPlaybackItemToken) { current(token)?.pause() }

    override suspend fun seek(seconds: Double, tolerance: Double, token: MonitorPlaybackItemToken): Boolean {
        val captured = current(token) ?: return false
        // Original Media3 preview uses CLOSEST_SYNC; the final commit uses EXACT.
        val attachment = installed ?: return false
        attachment.seekNative((seconds * 1000.0).toLong(), tolerance > 0.0)
        return current(token) === captured
    }

    override fun setMuted(muted: Boolean, token: MonitorPlaybackItemToken) {
        current(token)?.volume = if (muted) 0f else 1f
    }

    override fun close(token: MonitorPlaybackItemToken) {
        if (claimedOwner != token.owner || this.token?.let { token.revision < it.revision } == true) return
        retireNative()
        this.token = null
        source = null
    }

    private fun current(token: MonitorPlaybackItemToken): Player? =
        installed?.takeIf { this.token == token && it.token == token }?.player

    private fun retireNative() {
        pending?.completeExceptionally(MonitorPlaybackException(MonitorPlaybackFailure.RETIRED))
        pending = null
        val old = installed
        installed = null
        old?.close()
    }

    private fun retired(): Nothing = throw MonitorPlaybackException(MonitorPlaybackFailure.RETIRED)
}

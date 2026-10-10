@file:androidx.media3.common.util.UnstableApi

package com.opencapture.openzcine.media

import androidx.media3.common.Player
import com.opencapture.opencine.appkit.MonitorMediaLibraryModel
import com.opencapture.opencine.appkit.MonitorMediaRecord
import com.opencapture.opencine.appkit.MonitorPlaybackCandidate
import com.opencapture.opencine.media.*
import java.util.UUID
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlin.time.Duration

/** Logical/native item binding; actual growing DataSource, audio renderer and effects stay in
 * the existing native composition. Transfer teardown remains ahead of playlist navigation. */
internal class NikonPlaybackNativePort(
    private val transferFactory: ((MonitorMediaRecord<NikonLibraryClip>, () -> Boolean) -> MediaTransferCoordinator)? = null,
    private val sourceCurrent: () -> Boolean = { true },
    cleanupScope: CoroutineScope? = null,
    private val beforePrepare: suspend () -> Unit = {},
    private val captureBeforePrepare: () -> (suspend () -> Unit) = { {} },
) : MonitorPlaybackPort {
    data class Source(
        val token: MonitorPlaybackItemToken,
        val record: MonitorMediaRecord<NikonLibraryClip>,
        val preparation: MediaTransferPreparation = MediaTransferPreparation.Loading,
        val buffered: Float = 0f,
    )
    private val mutableSource = MutableStateFlow<Source?>(null)
    val preparedSource: StateFlow<Source?> = mutableSource.asStateFlow()
    private var transfer: MediaTransferCoordinator? = null
    private var cleanup: Job? = null
    private val ownsCleanupScope = cleanupScope == null && transferFactory != null
    private val cleanupScope = cleanupScope ?: if (transferFactory != null) CoroutineScope(SupervisorJob() + Dispatchers.IO) else null

    override var onEvent: ((MonitorPlaybackItemToken, MonitorPlaybackEvent) -> Unit)? = null
    private var claimedOwner: UUID? = null
    private var token: MonitorPlaybackItemToken? = null
    private var source: MonitorPlaybackItem? = null
    private var installed: Attachment? = null
    private var pending: CompletableDeferred<MonitorPlaybackMetadata>? = null
    private var preparationBarrier: (suspend () -> Unit)? = null

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
        val captured = token
        if (captured != null) mutableSource.value = Source(captured, record)
        // Genuine canonical native address; GrowingFileDataSource remains bound to the captured
        // progressive entry, which can read its .part bytes before this final file is published.
        return listOf(MonitorPlaybackCandidate.Cached(item))
    }

    override fun retireItem(token: MonitorPlaybackItemToken) {
        if (claimedOwner != null && claimedOwner != token.owner) return
        if (claimedOwner == null && token.revision != 0L) return
        if (this.token?.let { token.revision < it.revision } == true) return
        claimedOwner = token.owner
        this.token = token
        val capturedBarrier = captureBeforePrepare()
        if (this.token != token) return
        retireNative()
        if (this.token != token) return
        preparationBarrier = capturedBarrier
        pending = CompletableDeferred()
    }

    override suspend fun prepare(
        item: MonitorPlaybackItem, token: MonitorPlaybackItemToken, readyTimeout: Duration?,
    ): MonitorPlaybackMetadata {
        if (!admitted(token, item)) retired()
        val wait = pending ?: retired()
        val binding = mutableSource.value?.takeIf { it.token == token } ?: retired()
        val barrier = preparationBarrier
        // The previous entered PTP operation completes and stops before this source opens IO.
        cleanup?.join()
        beforePrepare()
        barrier?.invoke()
        currentCoroutineContext().ensureActive()
        if (!admitted(token, item)) retired()
        val coordinator = transferFactory?.invoke(binding.record) { admitted(token, item) }
        if (coordinator != null) {
            if (!admitted(token, item)) {
                withContext(NonCancellable) { coordinator.close() }; retired()
            }
            transfer = coordinator
            val preparation = coordinator.prepare()
            currentCoroutineContext().ensureActive()
            if (!admitted(token, item) || transfer !== coordinator) retired()
            mutableSource.value = binding.copy(preparation = preparation)
            if (!admitted(token, item)) retired()
            when (preparation) {
                is MediaTransferPreparation.Failed -> fail(token, preparation.message)
                MediaTransferPreparation.Cancelled -> retired()
                else -> Unit
            }
        }
        val facts = wait.await()
        currentCoroutineContext().ensureActive()
        if (!admitted(token, item) || installed?.token != token) retired()
        return facts
    }

    fun attach(
        player: Player, token: MonitorPlaybackItemToken, beforeRelease: () -> Unit,
        seekNative: (Long, Boolean) -> Unit,
    ): Attachment {
        val captured = Attachment(token, player, beforeRelease, seekNative)
        val item = source
        if (item == null || !admitted(token, item)) {
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
        if (!isCurrent(attachment)) return
        requireNotNull(attachment)
        onEvent?.invoke(attachment.token, event)
    }

    fun isCurrent(attachment: Attachment?): Boolean {
        val captured = attachment ?: return false
        val item = source ?: return false
        return installed === captured && admitted(captured.token, item) && installed === captured
    }

    fun fail(token: MonitorPlaybackItemToken, message: String) {
        val captured = source ?: return
        if (!admitted(token, captured)) return
        onEvent?.invoke(token, MonitorPlaybackEvent.Failed(message))
        if (this.token == token) pending?.completeExceptionally(
            MonitorPlaybackException(MonitorPlaybackFailure.NATIVE_FAILURE))
    }

    fun updateBuffer(attachment: Attachment?, fraction: Float) {
        if (!isCurrent(attachment)) return
        requireNotNull(attachment)
        val captured = mutableSource.value?.takeIf { it.token == attachment.token } ?: return
        mutableSource.value = captured.copy(buffered = fraction)
    }

    /** Back waits for the exact native source teardown; no camera command is sent by covers. */
    suspend fun finishEnteredTransfer() { cleanup?.join() }

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
        this.token = null
        retireNative()
        if (this.token != null) return
        if (ownsCleanupScope) {
            val job = cleanup
            if (job == null) cleanupScope?.cancel()
            else job.invokeOnCompletion {
                if (this.token == null && cleanup === job) cleanupScope?.cancel()
            }
        }
    }

    private fun admitted(token: MonitorPlaybackItemToken, item: MonitorPlaybackItem): Boolean {
        if (this.token != token || source != item) return false
        val accepted = sourceCurrent()
        return accepted && this.token == token && source == item
    }

    private fun current(token: MonitorPlaybackItemToken): Player? {
        val captured = installed ?: return null
        return captured.takeIf { it.token == token && isCurrent(it) }?.player
    }

    private fun retireNative() {
        val outgoing = transfer; transfer = null
        val wait = pending; pending = null
        preparationBarrier = null
        val old = installed; installed = null
        source = null
        if (outgoing != null) {
            val previous = cleanup
            val task = requireNotNull(cleanupScope).launch(start = CoroutineStart.LAZY) {
                previous?.join()
                withContext(NonCancellable) { outgoing.close() }
            }
            cleanup = task; task.start()
        }
        // Commit retirement before publication or SDK release can synchronously open a successor.
        mutableSource.value = null
        wait?.completeExceptionally(MonitorPlaybackException(MonitorPlaybackFailure.RETIRED))
        old?.close()
    }

    private fun retired(): Nothing = throw MonitorPlaybackException(MonitorPlaybackFailure.RETIRED)
}

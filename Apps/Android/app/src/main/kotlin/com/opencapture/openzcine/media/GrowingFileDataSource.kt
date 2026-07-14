package com.opencapture.openzcine.media

import android.net.Uri
import androidx.media3.common.C
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.BaseDataSource
import androidx.media3.datasource.DataSpec
import java.io.EOFException
import java.io.IOException
import java.io.InterruptedIOException
import java.nio.ByteBuffer
import java.nio.channels.ClosedChannelException
import java.nio.channels.FileChannel
import kotlin.math.min

/**
 * Media3 data source for a cache file that is still growing.
 *
 * Reads already-downloaded bytes immediately. At a temporary EOF it blocks
 * until [MediaCacheEntry.append], completion, failure, cancellation, or
 * [close] wakes it. EOF is returned only after the entry completes (or the
 * requested [DataSpec.length] has been consumed), so ExoPlayer never mistakes
 * a momentary transfer boundary for the end of the camera object.
 */
@UnstableApi
class GrowingFileDataSource(
    private val entry: MediaCacheEntry,
) : BaseDataSource(false) {
    private val lifecycleLock = Any()

    @Volatile private var opened = false
    @Volatile private var closed = false
    private var channel: FileChannel? = null
    private var currentPosition = 0L
    private var bytesRemaining = 0L
    private var openedUri: Uri? = null
    private var transferIsStarted = false

    /** Opens the progressive file at the position and length requested by Media3. */
    override fun open(dataSpec: DataSpec): Long {
        transferInitializing(dataSpec)
        val remaining = openAt(dataSpec.position, dataSpec.length)
        openedUri = dataSpec.uri
        transferStarted(dataSpec)
        transferIsStarted = true
        return remaining
    }

    /**
     * Opens without constructing Android's [Uri], keeping filesystem behavior
     * directly testable in deterministic host-side JVM tests.
     */
    internal fun openAt(position: Long, length: Long = C.LENGTH_UNSET.toLong()): Long {
        require(position >= 0) { "position must not be negative." }
        require(length == C.LENGTH_UNSET.toLong() || length >= 0) {
            "length must be non-negative or LENGTH_UNSET."
        }
        if (position > entry.expectedLength) {
            throw EOFException(
                "Position $position exceeds media length ${entry.expectedLength}.",
            )
        }

        synchronized(lifecycleLock) {
            if (opened) throw IOException("Growing media data source is already open.")
            val openedChannel = entry.openReadableChannel()
            closed = false
            opened = true
            currentPosition = position
            bytesRemaining =
                if (length == C.LENGTH_UNSET.toLong()) {
                    entry.expectedLength - position
                } else {
                    min(length, entry.expectedLength - position)
                }
            channel = openedChannel
            return bytesRemaining
        }
    }

    /**
     * Reads cached bytes or waits while the transfer is active at temporary
     * EOF. Failure, cancellation, and close are surfaced as I/O errors.
     */
    override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
        require(offset >= 0 && length >= 0 && offset <= buffer.size && length <= buffer.size - offset) {
            "Invalid destination range."
        }
        if (closed) throw ClosedChannelException()
        if (!opened) throw IOException("Growing media data source is not open.")
        if (length == 0) return 0
        if (bytesRemaining == 0L) return C.RESULT_END_OF_INPUT

        val snapshot = entry.awaitReadable(currentPosition) { closed }
        if (closed) throw ClosedChannelException()
        val available = snapshot.availableLength - currentPosition
        if (available <= 0) {
            return when (snapshot.state) {
                MediaCacheState.COMPLETE -> C.RESULT_END_OF_INPUT
                MediaCacheState.FAILED ->
                    throw IOException("Camera media transfer failed.", snapshot.failure)
                MediaCacheState.CANCELLED ->
                    throw InterruptedIOException("Camera media transfer was cancelled.")
                MediaCacheState.ACTIVE ->
                    throw EOFException("Media cache length changed while reading.")
            }
        }

        val requested = min(length.toLong(), min(available, bytesRemaining)).toInt()
        val activeChannel = channel ?: throw ClosedChannelException()
        val count =
            activeChannel.read(
                ByteBuffer.wrap(buffer, offset, requested),
                currentPosition,
            )
        if (count <= 0) {
            throw EOFException("Media cache advertised bytes that could not be read.")
        }
        currentPosition += count
        bytesRemaining -= count
        if (transferIsStarted) bytesTransferred(count)
        return count
    }

    /** URI supplied by the active Media3 [DataSpec], or null for a host-test opening. */
    override fun getUri(): Uri? = openedUri

    /**
     * Closes the file and releases any read blocked at temporary EOF without
     * cancelling the underlying transfer entry.
     */
    override fun close() {
        val channelToClose: FileChannel?
        val shouldEndTransfer: Boolean
        synchronized(lifecycleLock) {
            closed = true
            opened = false
            openedUri = null
            channelToClose = channel
            channel = null
            shouldEndTransfer = transferIsStarted
            transferIsStarted = false
        }
        entry.signalReaders()
        try {
            channelToClose?.close()
        } finally {
            if (shouldEndTransfer) transferEnded()
        }
    }
}

package com.opencapture.openzcine.media

import android.net.Uri
import androidx.media3.common.C
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.BaseDataSource
import androidx.media3.datasource.DataSpec

/** Media3 event/URI adapter; shared Media owns progressive reads, seeks, EOF and cancellation. */
@UnstableApi
public class GrowingFileDataSource(private val entry: MediaCacheEntry) : BaseDataSource(false) {
    private val reader = entry.reader()
    private val lifecycleLock = Any()
    private var openedUri: Uri? = null
    private var transferIsStarted = false

    override fun open(dataSpec: DataSpec): Long {
        transferInitializing(dataSpec)
        val remaining = openAt(dataSpec.position, dataSpec.length)
        synchronized(lifecycleLock) {
            openedUri = dataSpec.uri
            transferStarted(dataSpec)
            transferIsStarted = true
        }
        return remaining
    }

    /** The original host-test entry point exercises the same shared reader as Media3. */
    internal fun openAt(position: Long, length: Long = C.LENGTH_UNSET.toLong()): Long =
        reader.openAt(position, if (length == C.LENGTH_UNSET.toLong()) null else length)

    override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
        val count = reader.read(buffer, offset, length)
        synchronized(lifecycleLock) {
            if (count > 0 && transferIsStarted) bytesTransferred(count)
        }
        return count
    }

    override fun getUri(): Uri? = synchronized(lifecycleLock) { openedUri }

    override fun close() {
        val shouldEndTransfer = synchronized(lifecycleLock) {
            openedUri = null
            transferIsStarted.also { transferIsStarted = false }
        }
        try { reader.close() } finally { if (shouldEndTransfer) transferEnded() }
    }
}

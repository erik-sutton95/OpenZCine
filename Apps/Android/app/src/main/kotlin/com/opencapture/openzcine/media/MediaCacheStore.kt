package com.opencapture.openzcine.media

import java.io.IOException
import java.io.InterruptedIOException
import java.nio.ByteBuffer
import java.nio.channels.FileChannel
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.Path
import java.nio.file.StandardCopyOption
import java.nio.file.StandardOpenOption
import java.security.MessageDigest
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

/** Lifecycle of one progressive media-cache entry. */
enum class MediaCacheState {
    /** The temporary file can accept more sequential chunks. */
    ACTIVE,

    /** The expected byte count was received and the final file was published atomically. */
    COMPLETE,

    /** The transfer failed; buffered bytes remain available for a later resume. */
    FAILED,

    /** The transfer was cancelled; buffered bytes remain available for a later resume. */
    CANCELLED,
}

/**
 * Stable identity for one PTP object in a camera cache bucket.
 *
 * Nikon camera filenames are not globally unique: a card can be swapped,
 * another storage volume can contain the same basename, and handles can be
 * reused after deletion. Every field therefore contributes to the cache key;
 * [filename] is retained for validation and diagnostics, not used directly as
 * the on-disk artifact name.
 */
data class MediaCacheObjectIdentity(
    /** PTP storage volume containing the object. */
    val storageId: Long,
    /** PTP object handle within that storage volume. */
    val handle: Long,
    /** Camera capture timestamp, when supplied by ObjectInfo. */
    val captureDate: String,
    /** Safe camera basename, e.g. `C0001.MOV`. */
    val filename: String,
) {
    /** Builds the identity directly from the Android media-list wire record. */
    public constructor(clip: MediaClipRecord) : this(
        storageId = clip.storageId,
        handle = clip.handle,
        captureDate = clip.captureDate,
        filename = clip.filename,
    )

    internal fun cacheKeyMaterial(): String =
        "$storageId\u0000$handle\u0000$captureDate\u0000$filename"
}

/** Base class for deterministic media-cache validation errors. */
sealed class MediaCacheException(message: String, cause: Throwable? = null) :
    IOException(message, cause)

/** The camera filename was not a safe single path component. */
class UnsafeMediaCacheFilenameException(filename: String) :
    MediaCacheException("Unsafe camera media filename: $filename")

/** A chunk did not begin at the current resumable offset. */
class MediaCacheOffsetException(
    /** Offset at which the next chunk must begin. */
    val expectedOffset: Long,
    /** Offset supplied by the transfer callback. */
    val actualOffset: Long,
) : MediaCacheException("Expected media chunk at $expectedOffset, received $actualOffset.")

/** A temporary or final file did not match its authoritative expected length. */
class MediaCacheLengthException(
    /** Authoritative object length reported by the camera. */
    val expectedLength: Long,
    /** Length found or proposed locally. */
    val actualLength: Long,
) : MediaCacheException("Expected media length $expectedLength, found $actualLength.")

/** A write or resume was attempted from an incompatible terminal state. */
class MediaCacheStateException(
    /** State that rejected the operation. */
    val cacheState: MediaCacheState,
) : MediaCacheException("Media cache entry is not writable in state $cacheState.")

/**
 * Persistent progressive-media cache rooted at an app-owned directory.
 *
 * Camera identities are SHA-256 bucketed so raw serials never become paths.
 * Camera filenames must already be safe basenames; they are rejected rather
 * than rewritten so the cache key stays stable across reconnects. Android
 * integration should pass a directory below `Context.noBackupFilesDir`.
 *
 * @property rootDirectory App-owned directory dedicated to camera media.
 */
class MediaCacheStore(rootDirectory: Path) {
    /** Normalized absolute root containing every cache bucket. */
    val rootDirectory: Path = rootDirectory.toAbsolutePath().normalize()

    private val entries = mutableMapOf<CacheKey, MediaCacheEntry>()

    init {
        Files.createDirectories(this.rootDirectory)
    }

    /**
     * Opens or creates the stable cache entry for one uniquely identified
     * camera object.
     *
     * An existing `.part` file is resumed at its current length. An existing
     * final file is accepted only when its length exactly matches
     * [expectedLength]. Repeated calls in one process return the same entry so
     * readers and the transfer writer share wake-up state.
     */
    @Synchronized
    fun openEntry(
        cameraID: String,
        identity: MediaCacheObjectIdentity,
        expectedLength: Long,
    ): MediaCacheEntry {
        require(cameraID.isNotBlank()) { "cameraID must not be blank." }
        require(expectedLength >= 0) { "expectedLength must not be negative." }
        validateFilename(identity.filename)

        val bucket = bucketPath(cameraID)
        Files.createDirectories(bucket)
        check(!Files.isSymbolicLink(bucket)) { "Media cache bucket must not be a symbolic link." }

        val artifactName = sha256Hex(identity.cacheKeyMaterial())
        val finalPath = containedPath(bucket, "$artifactName.media")
        val partialPath = containedPath(bucket, "$artifactName.part")
        val key = CacheKey(bucket.fileName.toString(), artifactName)
        entries[key]?.let { existing ->
            if (existing.expectedLength != expectedLength) {
                throw MediaCacheLengthException(expectedLength, existing.expectedLength)
            }
            return existing
        }

        val entry = createEntry(partialPath, finalPath, expectedLength)
        entries[key] = entry
        return entry
    }

    private fun createEntry(
        partialPath: Path,
        finalPath: Path,
        expectedLength: Long,
    ): MediaCacheEntry {
        if (Files.exists(finalPath, LinkOption.NOFOLLOW_LINKS)) {
            requireRegularFile(finalPath)
            val finalLength = Files.size(finalPath)
            if (finalLength != expectedLength) {
                throw MediaCacheLengthException(expectedLength, finalLength)
            }
            Files.deleteIfExists(partialPath)
            return MediaCacheEntry.completed(partialPath, finalPath, expectedLength)
        }

        if (Files.exists(partialPath, LinkOption.NOFOLLOW_LINKS)) {
            requireRegularFile(partialPath)
        } else {
            Files.createFile(partialPath)
        }
        val partialLength = Files.size(partialPath)
        if (partialLength > expectedLength) {
            throw MediaCacheLengthException(expectedLength, partialLength)
        }
        return MediaCacheEntry.active(partialPath, finalPath, expectedLength, partialLength)
    }

    private fun requireRegularFile(path: Path) {
        if (!Files.isRegularFile(path, LinkOption.NOFOLLOW_LINKS)) {
            throw InvalidMediaCacheFileException(path.fileName.toString())
        }
    }

    private fun bucketPath(cameraID: String): Path =
        rootDirectory.resolve(sha256Hex(cameraID)).normalize().also { path ->
            check(path.parent == rootDirectory) { "Camera bucket escaped the media cache root." }
        }

    private fun containedPath(bucket: Path, basename: String): Path =
        bucket.resolve(basename).normalize().also { path ->
            if (!path.startsWith(rootDirectory) || path.parent != bucket) {
                throw UnsafeMediaCacheFilenameException(basename)
            }
        }

    private fun validateFilename(filename: String) {
        if (
            filename.isBlank() ||
                filename == "." ||
                filename == ".." ||
                filename.indexOf('\u0000') >= 0 ||
                filename.contains('/') ||
                filename.contains('\\')
        ) {
            throw UnsafeMediaCacheFilenameException(filename)
        }
    }

    private fun sha256Hex(value: String): String {
        val hex = "0123456789abcdef"
        val digest = MessageDigest.getInstance("SHA-256").digest(value.toByteArray(Charsets.UTF_8))
        return buildString(digest.size * 2) {
            digest.forEach { byte ->
                val unsigned = byte.toInt() and 0xFF
                append(hex[unsigned ushr 4])
                append(hex[unsigned and 0x0F])
            }
        }
    }

    private data class CacheKey(val bucket: String, val filename: String)
}

/**
 * One resumable progressive file shared by a sequential writer and one or
 * more growing-file readers.
 *
 * Mutations are serialized, offsets are validated before writing, and every
 * state or byte-count change wakes blocked readers.
 */
class MediaCacheEntry private constructor(
    /** Stable temporary path used while bytes are arriving. */
    val partialPath: Path,
    /** Stable final path published only after full-length validation. */
    val finalPath: Path,
    /** Authoritative total object size in bytes. */
    val expectedLength: Long,
    initialLength: Long,
    initialState: MediaCacheState,
) {
    private val lock = ReentrantLock()
    private val changed = lock.newCondition()
    private var currentLength = initialLength
    private var currentState = initialState
    private var currentFailure: IOException? = null

    /** Current number of bytes available locally. */
    val downloadedBytes: Long
        get() = lock.withLock { currentLength }

    /** Current transfer lifecycle. */
    val state: MediaCacheState
        get() = lock.withLock { currentState }

    /** Fraction in `0...1`, including `1` for a completed empty object. */
    val progress: Double
        get() =
            lock.withLock {
                if (expectedLength == 0L) {
                    if (currentState == MediaCacheState.COMPLETE) 1.0 else 0.0
                } else {
                    currentLength.toDouble() / expectedLength.toDouble()
                }
            }

    /**
     * Appends one transfer chunk at [offset].
     *
     * The offset must equal [downloadedBytes], and the write may not extend
     * beyond [expectedLength].
     */
    fun append(offset: Long, bytes: ByteArray) {
        lock.withLock {
            ensureActive()
            if (offset != currentLength) {
                throw MediaCacheOffsetException(currentLength, offset)
            }
            val diskLength = Files.size(partialPath)
            if (diskLength != currentLength) {
                throw MediaCacheLengthException(currentLength, diskLength)
            }
            val byteCount = bytes.size.toLong()
            if (byteCount > expectedLength - currentLength) {
                val reportedLength =
                    if (byteCount > Long.MAX_VALUE - currentLength) {
                        Long.MAX_VALUE
                    } else {
                        currentLength + byteCount
                    }
                throw MediaCacheLengthException(expectedLength, reportedLength)
            }
            if (bytes.isEmpty()) return
            val proposedLength = currentLength + byteCount

            FileChannel.open(partialPath, StandardOpenOption.WRITE).use { channel ->
                channel.position(offset)
                val buffer = ByteBuffer.wrap(bytes)
                while (buffer.hasRemaining()) {
                    channel.write(buffer)
                }
            }
            currentLength = proposedLength
            changed.signalAll()
        }
    }

    /**
     * Validates the full byte count and atomically publishes the final file.
     *
     * The temporary and final paths share one directory, making
     * [StandardCopyOption.ATOMIC_MOVE] a same-filesystem operation.
     */
    fun complete() {
        lock.withLock {
            ensureActive()
            val diskLength = Files.size(partialPath)
            if (diskLength != currentLength) {
                throw MediaCacheLengthException(currentLength, diskLength)
            }
            if (currentLength != expectedLength) {
                throw MediaCacheLengthException(expectedLength, currentLength)
            }
            Files.move(
                partialPath,
                finalPath,
                StandardCopyOption.ATOMIC_MOVE,
                StandardCopyOption.REPLACE_EXISTING,
            )
            currentState = MediaCacheState.COMPLETE
            changed.signalAll()
        }
    }

    /** Marks the transfer failed while preserving partial bytes for resume. */
    fun fail(error: IOException) {
        lock.withLock {
            if (currentState != MediaCacheState.ACTIVE) return
            currentFailure = error
            currentState = MediaCacheState.FAILED
            changed.signalAll()
        }
    }

    /** Marks the transfer cancelled while preserving partial bytes for resume. */
    fun cancel() {
        lock.withLock {
            if (currentState != MediaCacheState.ACTIVE) return
            currentState = MediaCacheState.CANCELLED
            changed.signalAll()
        }
    }

    /** Reactivates a failed or cancelled entry at its existing byte offset. */
    fun resume() {
        lock.withLock {
            when (currentState) {
                MediaCacheState.ACTIVE -> return
                MediaCacheState.COMPLETE -> throw MediaCacheStateException(currentState)
                MediaCacheState.FAILED,
                MediaCacheState.CANCELLED,
                -> {
                    val diskLength = Files.size(partialPath)
                    if (diskLength != currentLength) {
                        throw MediaCacheLengthException(currentLength, diskLength)
                    }
                    currentFailure = null
                    currentState = MediaCacheState.ACTIVE
                    changed.signalAll()
                }
            }
        }
    }

    internal fun openReadableChannel(): FileChannel =
        lock.withLock {
            val path = if (currentState == MediaCacheState.COMPLETE) finalPath else partialPath
            FileChannel.open(path, StandardOpenOption.READ)
        }

    internal fun awaitReadable(position: Long, isClosed: () -> Boolean): CacheReadSnapshot {
        lock.withLock {
            try {
                while (
                    currentState == MediaCacheState.ACTIVE &&
                        currentLength <= position &&
                        !isClosed()
                ) {
                    changed.await()
                }
            } catch (error: InterruptedException) {
                Thread.currentThread().interrupt()
                throw InterruptedIOException("Interrupted while waiting for media cache growth.")
                    .apply { initCause(error) }
            }
            return CacheReadSnapshot(currentLength, currentState, currentFailure)
        }
    }

    internal fun signalReaders() {
        lock.withLock { changed.signalAll() }
    }

    private fun ensureActive() {
        if (currentState != MediaCacheState.ACTIVE) {
            throw MediaCacheStateException(currentState)
        }
    }

    internal companion object {
        fun active(
            partialPath: Path,
            finalPath: Path,
            expectedLength: Long,
            initialLength: Long,
        ): MediaCacheEntry =
            MediaCacheEntry(
                partialPath,
                finalPath,
                expectedLength,
                initialLength,
                MediaCacheState.ACTIVE,
            )

        fun completed(
            partialPath: Path,
            finalPath: Path,
            expectedLength: Long,
        ): MediaCacheEntry =
            MediaCacheEntry(
                partialPath,
                finalPath,
                expectedLength,
                expectedLength,
                MediaCacheState.COMPLETE,
            )
    }
}

internal data class CacheReadSnapshot(
    val availableLength: Long,
    val state: MediaCacheState,
    val failure: IOException?,
)

private class InvalidMediaCacheFileException(filename: String) :
    MediaCacheException("Media cache path is not a regular file: $filename")

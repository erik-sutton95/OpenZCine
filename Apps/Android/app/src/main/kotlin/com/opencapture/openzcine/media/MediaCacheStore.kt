package com.opencapture.openzcine.media

import java.io.IOException
import java.io.InterruptedIOException
import java.nio.ByteBuffer
import java.nio.channels.FileChannel
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.NoSuchFileException
import java.nio.file.Path
import java.nio.file.StandardCopyOption
import java.nio.file.StandardOpenOption
import java.nio.file.attribute.BasicFileAttributes
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
 * Aggregate storage occupied by app-owned progressive media artifacts.
 *
 * Incomplete entries are `.part` files and remain separate from complete
 * `.media` files so Settings can clear safe-to-remove files without
 * interrupting resumable transfers.
 */
public data class MediaCacheUsage(
    /** Number of fully published cache files. */
    public val completeEntryCount: Int,
    /** Bytes occupied by fully published cache files. */
    public val completeBytes: Long,
    /** Number of incomplete or resumable cache files. */
    public val incompleteEntryCount: Int,
    /** Bytes occupied by incomplete or resumable cache files. */
    public val incompleteBytes: Long,
) {
    /** Total bytes occupied by all recognized progressive cache artifacts. */
    public val totalBytes: Long
        get() = completeBytes.saturatingAdd(incompleteBytes)
}

/**
 * Result of removing completed progressive-media cache entries.
 *
 * Incomplete entries are intentionally never deleted by this operation: their
 * transfer owner can resume them safely after Settings is closed.
 */
public data class MediaCacheClearResult(
    /** Number of completed cache entries removed. */
    public val removedCompleteEntryCount: Int,
    /** Bytes reclaimed from completed cache entries. */
    public val removedCompleteBytes: Long,
    /** Number of incomplete entries intentionally retained. */
    public val preservedIncompleteEntryCount: Int,
    /** Bytes intentionally retained for incomplete entries. */
    public val preservedIncompleteBytes: Long,
)

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
        requireSafeDirectory(this.rootDirectory)
    }

    /**
     * Returns the aggregate size of recognized, app-owned progressive cache
     * files below [rootDirectory]. Share-provider artifacts, camera media, and
     * any unrecognized files are outside this accounting boundary.
     */
    @Synchronized
    public fun cacheUsage(): MediaCacheUsage {
        val artifacts = scanArtifacts()
        return usageFor(artifacts)
    }

    /**
     * Removes only complete `.media` artifacts from the progressive cache.
     *
     * `.part` files are intentionally preserved so active, failed, and
     * cancelled transfers keep their resumable bytes. The scan accepts only
     * hash-named regular files below hash-named direct children of
     * [rootDirectory], never follows symbolic links, and never visits the
     * provider share cache.
     */
    @Synchronized
    public fun clearCompletedEntries(): MediaCacheClearResult {
        val artifacts = scanArtifacts()
        val before = usageFor(artifacts)
        val deletedPaths = mutableSetOf<Path>()
        var removedEntries = 0
        var removedBytes = 0L

        artifacts
            .asSequence()
            .filter { it.kind == CacheArtifactKind.COMPLETE }
            .forEach { artifact ->
                if (Files.deleteIfExists(artifact.path)) {
                    deletedPaths.add(artifact.path)
                    removedEntries += 1
                    removedBytes = removedBytes.saturatingAdd(artifact.bytes)
                }
            }

        if (deletedPaths.isNotEmpty()) {
            entries
                .filterValues { entry -> entry.finalPath in deletedPaths }
                .keys
                .toList()
                .forEach(entries::remove)
        }

        return MediaCacheClearResult(
            removedCompleteEntryCount = removedEntries,
            removedCompleteBytes = removedBytes,
            preservedIncompleteEntryCount = before.incompleteEntryCount,
            preservedIncompleteBytes = before.incompleteBytes,
        )
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

    /**
     * Returns an already-published entry for [identity], or `null` when its
     * final artifact is unavailable or no longer validates against
     * [expectedLength].
     *
     * This is deliberately a lookup, not an open: callers such as the local
     * media library and batch share must never create an empty `.part` file
     * merely by inspecting availability. The method consults one
     * identity-derived path only; it never scans an app directory for media.
     */
    @Synchronized
    fun completedEntryOrNull(
        cameraID: String,
        identity: MediaCacheObjectIdentity,
        expectedLength: Long,
    ): MediaCacheEntry? {
        require(cameraID.isNotBlank()) { "cameraID must not be blank." }
        require(expectedLength >= 0) { "expectedLength must not be negative." }
        validateFilename(identity.filename)

        val bucket = bucketPath(cameraID)
        if (
            !Files.isDirectory(bucket, LinkOption.NOFOLLOW_LINKS) ||
                Files.isSymbolicLink(bucket)
        ) {
            return null
        }

        val artifactName = sha256Hex(identity.cacheKeyMaterial())
        val finalPath = containedPath(bucket, "$artifactName.media")
        val partialPath = containedPath(bucket, "$artifactName.part")
        val key = CacheKey(bucket.fileName.toString(), artifactName)
        entries[key]?.let { existing ->
            if (
                existing.expectedLength != expectedLength ||
                    existing.state != MediaCacheState.COMPLETE ||
                    existing.downloadedBytes != expectedLength
            ) {
                return null
            }
            if (hasExactFinalLength(finalPath, expectedLength)) {
                return existing
            }
            // Only evict a stale completed entry. An active entry remains in
            // the map so its transfer owner can continue resuming it.
            entries.remove(key)
            return null
        }

        if (!hasExactFinalLength(finalPath, expectedLength)) return null

        return MediaCacheEntry.completed(partialPath, finalPath, expectedLength).also { entry ->
            entries[key] = entry
        }
    }

    /**
     * Full purge for one deliberately deleted camera object: the final
     * `.media` artifact AND its resumable `.part` go together (iOS
     * `MediaLibrary.purgeClip` semantics — nothing a later scan or resume
     * could resurrect the item from). The in-process entry is dropped so an
     * open reader cannot republish the identity.
     */
    @Synchronized
    fun purgeEntry(cameraID: String, identity: MediaCacheObjectIdentity) {
        require(cameraID.isNotBlank()) { "cameraID must not be blank." }
        validateFilename(identity.filename)

        val bucket = bucketPath(cameraID)
        if (
            !Files.isDirectory(bucket, LinkOption.NOFOLLOW_LINKS) ||
                Files.isSymbolicLink(bucket)
        ) {
            return
        }
        val artifactName = sha256Hex(identity.cacheKeyMaterial())
        entries.remove(CacheKey(bucket.fileName.toString(), artifactName))
        try {
            Files.deleteIfExists(containedPath(bucket, "$artifactName.media"))
        } catch (_: IOException) {
        }
        try {
            Files.deleteIfExists(containedPath(bucket, "$artifactName.part"))
        } catch (_: IOException) {
        }
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

    private fun hasExactFinalLength(path: Path, expectedLength: Long): Boolean =
        try {
            Files.isRegularFile(path, LinkOption.NOFOLLOW_LINKS) &&
                Files.size(path) == expectedLength
        } catch (_: IOException) {
            false
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

    private fun scanArtifacts(): List<CacheArtifact> {
        requireSafeDirectory(rootDirectory)
        val artifacts = mutableListOf<CacheArtifact>()
        Files.newDirectoryStream(rootDirectory).use { buckets ->
            buckets.forEach { bucket ->
                if (!isCacheBucket(bucket) || !isSafeDirectory(bucket)) return@forEach
                Files.newDirectoryStream(bucket).use { entries ->
                    entries.forEach { path ->
                        val kind = artifactKind(path.fileName.toString()) ?: return@forEach
                        val attributes = noFollowAttributesOrNull(path) ?: return@forEach
                        if (!attributes.isRegularFile) return@forEach
                        artifacts += CacheArtifact(path, kind, attributes.size())
                    }
                }
            }
        }
        return artifacts
    }

    private fun usageFor(artifacts: List<CacheArtifact>): MediaCacheUsage {
        val complete = artifacts.filter { it.kind == CacheArtifactKind.COMPLETE }
        val incomplete = artifacts.filter { it.kind == CacheArtifactKind.INCOMPLETE }
        return MediaCacheUsage(
            completeEntryCount = complete.size,
            completeBytes = complete.fold(0L) { total, artifact -> total.saturatingAdd(artifact.bytes) },
            incompleteEntryCount = incomplete.size,
            incompleteBytes = incomplete.fold(0L) { total, artifact -> total.saturatingAdd(artifact.bytes) },
        )
    }

    private fun requireSafeDirectory(path: Path) {
        check(isSafeDirectory(path)) { "Media cache directory is not a regular directory." }
    }

    private fun isSafeDirectory(path: Path): Boolean =
        noFollowAttributesOrNull(path)?.isDirectory == true

    private fun noFollowAttributesOrNull(path: Path): BasicFileAttributes? =
        try {
            Files.readAttributes(path, BasicFileAttributes::class.java, LinkOption.NOFOLLOW_LINKS)
        } catch (_: NoSuchFileException) {
            null
        }

    private fun isCacheBucket(path: Path): Boolean =
        path.parent == rootDirectory && CACHE_BUCKET_NAME.matches(path.fileName.toString())

    private fun artifactKind(filename: String): CacheArtifactKind? =
        when {
            COMPLETE_ARTIFACT_NAME.matches(filename) -> CacheArtifactKind.COMPLETE
            INCOMPLETE_ARTIFACT_NAME.matches(filename) -> CacheArtifactKind.INCOMPLETE
            else -> null
        }

    private data class CacheArtifact(
        val path: Path,
        val kind: CacheArtifactKind,
        val bytes: Long,
    )

    private enum class CacheArtifactKind {
        COMPLETE,
        INCOMPLETE,
    }

    private companion object {
        val CACHE_BUCKET_NAME = Regex("[0-9a-f]{64}")
        val COMPLETE_ARTIFACT_NAME = Regex("[0-9a-f]{64}\\.media")
        val INCOMPLETE_ARTIFACT_NAME = Regex("[0-9a-f]{64}\\.part")
    }

    private data class CacheKey(val bucket: String, val filename: String)
}

private fun Long.saturatingAdd(other: Long): Long =
    if (other > Long.MAX_VALUE - this) Long.MAX_VALUE else this + other

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

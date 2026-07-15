package com.opencapture.openzcine.media

import java.io.IOException
import java.nio.ByteBuffer
import java.nio.channels.FileChannel
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.Path
import java.nio.file.StandardCopyOption
import java.nio.file.StandardOpenOption
import java.nio.file.attribute.FileTime
import java.security.MessageDigest
import java.util.Locale

/** Base class for a clip that cannot safely enter the Android share flow. */
sealed class MediaShareException(message: String, cause: Throwable? = null) :
    IOException(message, cause)

/** A share was requested before the progressive cache published its final file. */
class IncompleteMediaShareException(
    /** The cache state that rejected the request. */
    val cacheState: MediaCacheState,
) : MediaShareException("Clip is not fully cached (state: $cacheState).")

/** The camera filename is not safe to use as share-sheet display metadata. */
class UnsafeMediaShareFilenameException(filename: String) :
    MediaShareException("Unsafe camera media filename for sharing: $filename")

/** The published cache file was missing, mutable, or did not match the camera byte count. */
class InvalidMediaShareSourceException(message: String) : MediaShareException(message)

/** The temporary share cache cannot safely make room for another completed clip. */
class MediaShareCacheLimitException(message: String) : MediaShareException(message)

/** Returns whether [filename] is safe to use as external media display metadata. */
internal fun isSafeMediaDisplayName(filename: String): Boolean =
    !(
        filename.isBlank() ||
            filename != filename.trim() ||
            filename == "." ||
            filename == ".." ||
            filename.indexOf('\u0000') >= 0 ||
            filename.contains('/') ||
            filename.contains('\\') ||
            filename.any { character -> character.code < 0x20 || character.code == 0x7F } ||
            filename.substringBeforeLast('.', missingDelimiterValue = "").isBlank()
    )

/**
 * A fully copied share artifact held below app-owned `cacheDir/share/ready`.
 *
 * [file] is deliberately not the no-backup progressive cache file. The Android
 * `FileProvider` exposes only this ready directory, while [displayName] keeps
 * the camera's validated filename available to the receiving app.
 */
data class StagedMediaShare(
    /** App-cache file that may be handed to the Android `FileProvider`. */
    val file: Path,
    /** Validated camera filename shown by the receiving app. */
    val displayName: String,
    /** MIME family from the core action when available, otherwise generic media. */
    val mimeType: String,
)

/**
 * Pure description of the platform intent assembled by [AndroidMediaShareIntent].
 *
 * Keeping this policy Android-free lets host JVM tests cover the share contract
 * without relying on framework `Intent` stubs.
 */
internal data class MediaShareIntentSpec(
    val action: String,
    val mimeType: String,
    val streamExtraIncluded: Boolean,
    val clipDataLabel: String,
    val grantsReadUriPermission: Boolean,
    val chooserTitle: String,
) {
    companion object {
        /** Builds the immutable policy for one staged clip. */
        fun forShare(share: StagedMediaShare): MediaShareIntentSpec = forShares(listOf(share))

        /**
         * Builds the immutable policy for one or more already-staged artifacts.
         *
         * Mixed camera media deliberately uses a wildcard MIME type: every individual URI
         * keeps its filename extension and FileProvider type, while a narrow
         * shared MIME type would hide one of the selected assets from many
         * native share targets.
         */
        fun forShares(shares: List<StagedMediaShare>): MediaShareIntentSpec {
            require(shares.isNotEmpty()) { "At least one staged media file is required." }
            val first = shares.first()
            val single = shares.size == 1
            return MediaShareIntentSpec(
                action = if (single) ACTION_SEND else ACTION_SEND_MULTIPLE,
                mimeType =
                    shares.map(StagedMediaShare::mimeType).distinct().singleOrNull() ?: "*/*",
                streamExtraIncluded = true,
                clipDataLabel = if (single) first.displayName else "OpenZCine media",
                grantsReadUriPermission = true,
                chooserTitle =
                    if (single) "Share ${first.displayName}" else "Share ${shares.size} items",
            )
        }

        /** Android's canonical `ACTION_SEND` string, kept JVM-testable here. */
        const val ACTION_SEND = "android.intent.action.SEND"

        /** Android's canonical multi-stream share action, kept JVM-testable here. */
        const val ACTION_SEND_MULTIPLE = "android.intent.action.SEND_MULTIPLE"
    }
}

/**
 * Copies only complete progressive-cache entries into an app-cache directory
 * intentionally scoped for Android sharing.
 *
 * The progressive cache belongs under `noBackupFilesDir`; this class accepts
 * its immutable final file but never returns that path. Its provider-visible
 * files live exclusively below `cacheDir/share/ready`, while transient copy
 * files remain in the sibling, provider-inaccessible `share/staging` folder.
 *
 * A ready artifact is retained for at least 24 hours after each successful
 * staging request. This grace interval protects the asynchronous temporary
 * URI grant made when Android opens the chooser: recipients must copy the
 * content while that grant is active, rather than treating this cache URI as
 * durable storage. Production retains at most eight artifacts and one GiB;
 * if it cannot make room without violating the grace interval, staging fails
 * instead of deleting a possibly granted artifact.
 *
 * @param cacheDirectory The app's scoped `Context.cacheDir` path.
 */
class MediaShareStager private constructor(
    cacheDirectory: Path,
    policy: ReadyCachePolicy,
) {
    /** Creates a stager with the production temporary-share retention policy. */
    constructor(cacheDirectory: Path) :
        this(
            cacheDirectory = cacheDirectory,
            policy =
                ReadyCachePolicy(
                    clock = System::currentTimeMillis,
                    maximumReadyBytes = DEFAULT_MAXIMUM_READY_BYTES,
                    maximumReadyArtifacts = DEFAULT_MAXIMUM_READY_ARTIFACTS,
                    grantRetentionMillis = URI_GRANT_RETENTION_MILLIS,
                ),
        )

    internal constructor(
        cacheDirectory: Path,
        clock: () -> Long,
        maximumReadyBytes: Long,
        maximumReadyArtifacts: Int,
        grantRetentionMillis: Long,
    ) :
        this(
            cacheDirectory = cacheDirectory,
            policy =
                ReadyCachePolicy(
                    clock = clock,
                    maximumReadyBytes = maximumReadyBytes,
                    maximumReadyArtifacts = maximumReadyArtifacts,
                    grantRetentionMillis = grantRetentionMillis,
                ),
        )

    private val clock: () -> Long = policy.clock
    private val maximumReadyBytes: Long = policy.maximumReadyBytes
    private val maximumReadyArtifacts: Int = policy.maximumReadyArtifacts
    private val grantRetentionMillis: Long = policy.grantRetentionMillis
    private val cacheDirectory: Path = cacheDirectory.toAbsolutePath().normalize()
    private val shareDirectory: Path = containedDirectory(this.cacheDirectory, "share")
    private val readyDirectory: Path = containedDirectory(shareDirectory, "ready")
    private val stagingDirectory: Path = containedDirectory(shareDirectory, "staging")

    init {
        require(maximumReadyBytes > 0) { "maximumReadyBytes must be positive." }
        require(maximumReadyArtifacts > 0) { "maximumReadyArtifacts must be positive." }
        require(grantRetentionMillis >= 0) { "grantRetentionMillis must not be negative." }
        ensureDirectory(this.cacheDirectory)
        ensureDirectory(shareDirectory)
        ensureDirectory(readyDirectory)
        ensureDirectory(stagingDirectory)
    }

    /**
     * Copies [entry]'s validated final artifact into the provider-visible
     * share directory and returns its safe metadata.
     *
     * A partial, failed, or cancelled entry is rejected before its `.part`
     * file can be observed. [cancellationCheck] is called between bounded I/O
     * chunks, so a closing playback screen can cancel a large copy and leave
     * no partial artifact under either share directory. Ready artifacts are
     * content-addressed; equal lengths alone never reuse a prior clip.
     *
     * @param cancellationCheck Invoked between bounded I/O operations so callers
     * can stop staging before any share intent is launched.
     * @throws IncompleteMediaShareException when the progressive transfer is incomplete.
     * The MIME family comes from [clip]'s shared-core [MediaContentKind], while
     * its filename remains display metadata and a validated target suffix only.
     * Kotlin never selects a media action from a filename extension.
     *
     * @throws MediaShareException when the filename, cache capacity, or final
     * cache artifact is unsafe.
     */
    fun stage(
        entry: MediaCacheEntry,
        clip: MediaClipRecord,
        cancellationCheck: () -> Unit = {},
    ): StagedMediaShare =
        stage(
            entry = entry,
            filename = clip.filename,
            mimeType = mimeTypeFor(clip.contentKind),
            cancellationCheck = cancellationCheck,
        )

    /**
     * Stages a legacy caller's already-authorized display name with a generic
     * MIME type. New camera-media callers must use [stage] with a
     * [MediaClipRecord] so the shared-core action determines the MIME family.
     */
    fun stage(
        entry: MediaCacheEntry,
        filename: String,
        cancellationCheck: () -> Unit = {},
    ): StagedMediaShare =
        stage(
            entry = entry,
            filename = filename,
            mimeType = GENERIC_MEDIA_MIME_TYPE,
            cancellationCheck = cancellationCheck,
        )

    /**
     * Publishes an already-complete app-owned export into the same bounded
     * FileProvider-ready cache as camera originals. The source is copied and
     * content-verified; callers may safely delete their transient export once
     * this method returns.
     */
    internal fun stagePreparedArtifact(
        source: Path,
        expectedBytes: Long,
        displayName: String,
        mimeType: String,
        cancellationCheck: () -> Unit = {},
    ): StagedMediaShare {
        validateFilename(displayName)
        if (expectedBytes <= 0 || !mimeType.matches(SAFE_MIME_TYPE)) {
            throw InvalidMediaShareSourceException("The prepared delivery artifact is invalid.")
        }
        val normalizedSource = source.toAbsolutePath().normalize()
        if (
            normalizedSource.fileName.toString().endsWith(".part") ||
                !Files.isRegularFile(normalizedSource, LinkOption.NOFOLLOW_LINKS) ||
                Files.isSymbolicLink(normalizedSource) ||
                Files.size(normalizedSource) != expectedBytes
        ) {
            throw InvalidMediaShareSourceException("The prepared delivery artifact is incomplete.")
        }
        return stageCompleteSource(
            source = normalizedSource,
            expectedLength = expectedBytes,
            filename = displayName,
            mimeType = mimeType,
            cancellationCheck = cancellationCheck,
        )
    }

    private fun stage(
        entry: MediaCacheEntry,
        filename: String,
        mimeType: String,
        cancellationCheck: () -> Unit,
    ): StagedMediaShare {
        validateFilename(filename)
        ensureComplete(entry)
        cancellationCheck()

        val source = entry.finalPath.toAbsolutePath().normalize()
        validatePublishedSourcePath(entry, source)

        return stageCompleteSource(
            source = source,
            expectedLength = entry.expectedLength,
            filename = filename,
            mimeType = mimeType,
            cancellationCheck = cancellationCheck,
        )
    }

    private fun stageCompleteSource(
        source: Path,
        expectedLength: Long,
        filename: String,
        mimeType: String,
        cancellationCheck: () -> Unit,
    ): StagedMediaShare {
        val displayExtension = filename.substringAfterLast('.').lowercase(Locale.ROOT)
        val temporary = Files.createTempFile(stagingDirectory, "share-", ".tmp")
        var movedTarget: Path? = null
        var targetWasPublished = false
        try {
            val copied =
                copySourceToTemporary(
                    source = source,
                    expectedLength = expectedLength,
                    temporary = temporary,
                    cancellationCheck = cancellationCheck,
                )
            val target = targetPath(copied.contentDigest, displayExtension)

            synchronized(readyCacheLock) {
                cancellationCheck()
                val now = clock()
                if (isUsableReadyCopy(target, copied, cancellationCheck)) {
                    markReadyForGrant(target, now)
                    reclaimReadyCache(
                        protectedPath = target,
                        incomingBytes = 0,
                        incomingArtifacts = 0,
                        now = now,
                        cancellationCheck = cancellationCheck,
                    )
                    return StagedMediaShare(target, filename, mimeType)
                }

                replaceUnusableTargetIfExpired(target, now)
                reclaimReadyCache(
                    protectedPath = target,
                    incomingBytes = copied.byteCount,
                    incomingArtifacts = 1,
                    now = now,
                    cancellationCheck = cancellationCheck,
                )
                cancellationCheck()
                // `ready` is FileProvider-visible, so only an atomically published,
                // complete file may enter it. Both directories are below cacheDir.
                Files.move(
                    temporary,
                    target,
                    StandardCopyOption.ATOMIC_MOVE,
                    StandardCopyOption.REPLACE_EXISTING,
                )
                movedTarget = target
                markReadyForGrant(target, now)
                targetWasPublished = true
                return StagedMediaShare(target, filename, mimeType)
            }
        } finally {
            if (!targetWasPublished) {
                runCatching { Files.deleteIfExists(temporary) }
                movedTarget?.let { target -> runCatching { Files.deleteIfExists(target) } }
            }
        }
    }

    private fun ensureComplete(entry: MediaCacheEntry) {
        if (entry.state != MediaCacheState.COMPLETE || entry.downloadedBytes != entry.expectedLength) {
            throw IncompleteMediaShareException(entry.state)
        }
    }

    private fun validatePublishedSourcePath(entry: MediaCacheEntry, source: Path) {
        val partial = entry.partialPath.toAbsolutePath().normalize()
        if (source == partial || source.fileName.toString().endsWith(".part")) {
            throw InvalidMediaShareSourceException("A progressive .part file cannot be shared.")
        }
        if (!Files.isRegularFile(source, LinkOption.NOFOLLOW_LINKS)) {
            throw InvalidMediaShareSourceException("The completed camera cache file is unavailable.")
        }
        val sourceLength = Files.size(source)
        if (sourceLength != entry.expectedLength) {
            throw InvalidMediaShareSourceException(
                "Completed camera cache length changed " +
                    "(expected ${entry.expectedLength} bytes, found $sourceLength).",
            )
        }
    }

    /**
     * Opens the source once with `NOFOLLOW_LINKS` and copies from that handle.
     *
     * The preflight path validation above is intentionally not trusted for the
     * copy: a replacement after validation cannot redirect this already-open
     * file descriptor to a symlink or a different path entry.
     */
    private fun copySourceToTemporary(
        source: Path,
        expectedLength: Long,
        temporary: Path,
        cancellationCheck: () -> Unit,
    ): CopiedMediaSource =
        FileChannel.open(source, StandardOpenOption.READ, LinkOption.NOFOLLOW_LINKS).use { sourceChannel ->
            cancellationCheck()
            val openedLength = sourceChannel.size()
            if (openedLength != expectedLength) {
                throw InvalidMediaShareSourceException(
                    "Completed camera cache length changed after opening " +
                        "(expected $expectedLength bytes, found $openedLength).",
                )
            }

            FileChannel.open(temporary, StandardOpenOption.WRITE, StandardOpenOption.TRUNCATE_EXISTING).use {
                targetChannel ->
                val digest = MessageDigest.getInstance("SHA-256")
                val buffer = ByteBuffer.allocate(COPY_BUFFER_BYTES)
                var copiedBytes = 0L
                while (copiedBytes < expectedLength) {
                    cancellationCheck()
                    buffer.clear()
                    buffer.limit(
                        minOf(
                            buffer.capacity().toLong(),
                            expectedLength - copiedBytes,
                        ).toInt(),
                    )
                    val read = sourceChannel.read(buffer)
                    if (read < 0) {
                        throw InvalidMediaShareSourceException(
                            "Completed camera cache ended before $expectedLength bytes were copied.",
                        )
                    }
                    if (read == 0) continue

                    buffer.flip()
                    digest.update(buffer.asReadOnlyBuffer())
                    while (buffer.hasRemaining()) {
                        cancellationCheck()
                        targetChannel.write(buffer)
                    }
                    copiedBytes += read.toLong()
                }

                cancellationCheck()
                if (sourceChannel.size() != expectedLength || Files.size(temporary) != expectedLength) {
                    throw InvalidMediaShareSourceException(
                        "Cached clip changed while preparing the share copy " +
                            "(expected $expectedLength bytes).",
                    )
                }
                CopiedMediaSource(byteCount = copiedBytes, contentDigest = hex(digest.digest()))
            }
        }

    private fun isUsableReadyCopy(
        path: Path,
        copied: CopiedMediaSource,
        cancellationCheck: () -> Unit,
    ): Boolean {
        if (!Files.isRegularFile(path, LinkOption.NOFOLLOW_LINKS)) return false
        return try {
            FileChannel.open(path, StandardOpenOption.READ, LinkOption.NOFOLLOW_LINKS).use { channel ->
                if (channel.size() != copied.byteCount) return@use false
                val digest = MessageDigest.getInstance("SHA-256")
                val buffer = ByteBuffer.allocate(COPY_BUFFER_BYTES)
                while (true) {
                    cancellationCheck()
                    buffer.clear()
                    val read = channel.read(buffer)
                    if (read < 0) break
                    if (read == 0) continue
                    buffer.flip()
                    digest.update(buffer)
                }
                hex(digest.digest()) == copied.contentDigest
            }
        } catch (_: IOException) {
            false
        }
    }

    /**
     * Keeps an unusable artifact intact while its temporary FileProvider grant
     * may still be in use. Even a corrupt content-addressed file can belong to
     * a recipient that has not finished reading its granted URI yet.
     */
    private fun replaceUnusableTargetIfExpired(target: Path, now: Long) {
        if (!Files.exists(target, LinkOption.NOFOLLOW_LINKS)) return
        val existing =
            readyArtifact(target)
                ?: throw InvalidMediaShareSourceException(
                    "Existing share artifact cannot be safely inspected for replacement.",
                )
        if (!existing.isExpired(now)) {
            throw MediaShareCacheLimitException(
                "An existing share artifact is still within its URI-grant retention window.",
            )
        }
        if (!Files.deleteIfExists(target)) {
            throw InvalidMediaShareSourceException(
                "Existing share artifact disappeared before it could be safely replaced.",
            )
        }
    }

    /** Reclaims only artifacts that have outlived the documented URI-grant grace period. */
    private fun reclaimReadyCache(
        protectedPath: Path,
        incomingBytes: Long,
        incomingArtifacts: Int,
        now: Long,
        cancellationCheck: () -> Unit,
    ) {
        var retainedBytes = 0L
        var retainedArtifacts = 0
        val artifacts = readyArtifacts()
        artifacts.forEach { artifact ->
            retainedBytes = saturatingAdd(retainedBytes, artifact.byteCount)
            retainedArtifacts += 1
        }

        val evictionCandidates =
            artifacts
                .asSequence()
                .filter { artifact -> artifact.path != protectedPath && artifact.isExpired(now) }
                .sortedWith(compareBy<ReadyArtifact>({ it.lastGrantedAtMillis }, { it.path.fileName.toString() }))
                .iterator()

        while (exceedsReadyCapacity(retainedBytes, retainedArtifacts, incomingBytes, incomingArtifacts) &&
            evictionCandidates.hasNext()
        ) {
            cancellationCheck()
            val artifact = evictionCandidates.next()
            if (Files.deleteIfExists(artifact.path)) {
                retainedBytes = (retainedBytes - artifact.byteCount).coerceAtLeast(0)
                retainedArtifacts -= 1
            }
        }

        if (incomingArtifacts > 0 &&
            exceedsReadyCapacity(retainedBytes, retainedArtifacts, incomingBytes, incomingArtifacts)
        ) {
            throw MediaShareCacheLimitException(
                "The temporary share cache is full; existing URI grants are still within their retention window.",
            )
        }
    }

    private fun readyArtifacts(): List<ReadyArtifact> =
        Files.list(readyDirectory).use { paths ->
            val artifacts = mutableListOf<ReadyArtifact>()
            val iterator = paths.iterator()
            while (iterator.hasNext()) {
                val path = iterator.next()
                if (Files.isRegularFile(path, LinkOption.NOFOLLOW_LINKS)) {
                    artifacts +=
                        ReadyArtifact(
                            path = path,
                            byteCount = Files.size(path),
                            lastGrantedAtMillis =
                                Files.getLastModifiedTime(path, LinkOption.NOFOLLOW_LINKS).toMillis(),
                        )
                }
            }
            artifacts
        }

    private fun readyArtifact(path: Path): ReadyArtifact? {
        if (!Files.isRegularFile(path, LinkOption.NOFOLLOW_LINKS)) return null
        return try {
            ReadyArtifact(
                path = path,
                byteCount = Files.size(path),
                lastGrantedAtMillis =
                    Files.getLastModifiedTime(path, LinkOption.NOFOLLOW_LINKS).toMillis(),
            )
        } catch (_: IOException) {
            null
        }
    }

    private fun ReadyArtifact.isExpired(now: Long): Boolean =
        lastGrantedAtMillis <= now - grantRetentionMillis

    private fun exceedsReadyCapacity(
        retainedBytes: Long,
        retainedArtifacts: Int,
        incomingBytes: Long,
        incomingArtifacts: Int,
    ): Boolean =
        saturatingAdd(retainedBytes, incomingBytes) > maximumReadyBytes ||
            retainedArtifacts > maximumReadyArtifacts - incomingArtifacts

    private fun markReadyForGrant(path: Path, now: Long) {
        Files.setLastModifiedTime(path, FileTime.fromMillis(now))
    }

    private fun targetPath(contentDigest: String, extension: String): Path =
        readyDirectory.resolve("$contentDigest.$extension").normalize().also { path ->
            if (path.parent != readyDirectory) {
                throw InvalidMediaShareSourceException("Share artifact escaped the ready directory.")
            }
        }

    private fun containedDirectory(parent: Path, name: String): Path =
        parent.resolve(name).normalize().also { path ->
            if (path.parent != parent) {
                throw InvalidMediaShareSourceException("Share directory escaped its app-cache root.")
            }
        }

    private fun ensureDirectory(path: Path) {
        Files.createDirectories(path)
        if (!Files.isDirectory(path, LinkOption.NOFOLLOW_LINKS) || Files.isSymbolicLink(path)) {
            throw InvalidMediaShareSourceException("Share directory is not a safe app-cache directory.")
        }
    }

    private fun mimeTypeFor(contentKind: MediaContentKind): String =
        when (contentKind) {
            MediaContentKind.PLAYABLE_PROXY -> "video/*"
            MediaContentKind.STILL_PHOTO -> "image/*"
            MediaContentKind.R3D_MASTER,
            MediaContentKind.UNSUPPORTED,
            -> GENERIC_MEDIA_MIME_TYPE
        }

    private fun validateFilename(filename: String) {
        if (!isSafeMediaDisplayName(filename)) {
            throw UnsafeMediaShareFilenameException(filename)
        }
    }

    private fun saturatingAdd(first: Long, second: Long): Long =
        if (first > Long.MAX_VALUE - second) Long.MAX_VALUE else first + second

    private fun hex(bytes: ByteArray): String {
        val hex = "0123456789abcdef"
        return buildString(bytes.size * 2) {
            bytes.forEach { byte ->
                val unsigned = byte.toInt() and 0xFF
                append(hex[unsigned ushr 4])
                append(hex[unsigned and 0x0F])
            }
        }
    }

    private data class CopiedMediaSource(
        val byteCount: Long,
        val contentDigest: String,
    )

    private data class ReadyArtifact(
        val path: Path,
        val byteCount: Long,
        val lastGrantedAtMillis: Long,
    )

    private data class ReadyCachePolicy(
        val clock: () -> Long,
        val maximumReadyBytes: Long,
        val maximumReadyArtifacts: Int,
        val grantRetentionMillis: Long,
    )

    private companion object {
        const val COPY_BUFFER_BYTES: Int = 64 * 1024
        const val DEFAULT_MAXIMUM_READY_BYTES: Long = 1_073_741_824L
        const val DEFAULT_MAXIMUM_READY_ARTIFACTS: Int = 8
        const val URI_GRANT_RETENTION_MILLIS: Long = 24L * 60L * 60L * 1000L
        const val GENERIC_MEDIA_MIME_TYPE: String = "application/octet-stream"
        val SAFE_MIME_TYPE: Regex = Regex("[a-z0-9][a-z0-9.+-]*/[a-z0-9][a-z0-9.+*-]*")

        /** Serializes ready-cache publication and eviction across stager instances in this process. */
        val readyCacheLock: Any = Any()
    }
}

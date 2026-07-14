package com.opencapture.openzcine.media

import java.io.IOException
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.Path
import java.nio.file.StandardCopyOption
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

/** The camera filename has no supported video extension for a native share target. */
class UnsupportedMediaShareFormatException(filename: String) :
    MediaShareException("This clip format cannot be shared: $filename")

/** The published cache file was missing, mutable, or did not match the camera byte count. */
class InvalidMediaShareSourceException(message: String) : MediaShareException(message)

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
    /** Accurate MIME type resolved from [displayName]. */
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
        fun forShare(share: StagedMediaShare): MediaShareIntentSpec =
            MediaShareIntentSpec(
                action = ACTION_SEND,
                mimeType = share.mimeType,
                streamExtraIncluded = true,
                clipDataLabel = share.displayName,
                grantsReadUriPermission = true,
                chooserTitle = "Share ${share.displayName}",
            )

        /** Android's canonical `ACTION_SEND` string, kept JVM-testable here. */
        const val ACTION_SEND = "android.intent.action.SEND"
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
 * @param cacheDirectory The app's scoped `Context.cacheDir` path.
 */
class MediaShareStager(cacheDirectory: Path) {
    private val cacheDirectory: Path = cacheDirectory.toAbsolutePath().normalize()
    private val shareDirectory: Path = containedDirectory(this.cacheDirectory, "share")
    private val readyDirectory: Path = containedDirectory(shareDirectory, "ready")
    private val stagingDirectory: Path = containedDirectory(shareDirectory, "staging")

    init {
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
     * file can be observed. Repeated calls reuse the same verified ready copy
     * instead of expanding the app cache for one immutable camera object.
     *
     * @throws IncompleteMediaShareException when the progressive transfer is incomplete.
     * @throws MediaShareException when the filename, MIME type, or final cache artifact is unsafe.
     */
    fun stage(entry: MediaCacheEntry, filename: String): StagedMediaShare {
        val mimeType = mimeTypeFor(filename)
        ensureComplete(entry)

        val source = entry.finalPath.toAbsolutePath().normalize()
        validatePublishedSource(entry, source)

        val extension = filename.substringAfterLast('.').lowercase(Locale.ROOT)
        val target = targetPath(source, extension)
        if (isUsableReadyCopy(target, entry.expectedLength)) {
            return StagedMediaShare(target, filename, mimeType)
        }
        Files.deleteIfExists(target)

        val temporary = Files.createTempFile(stagingDirectory, "share-", ".tmp")
        try {
            Files.copy(source, temporary, StandardCopyOption.REPLACE_EXISTING)
            val copiedLength = Files.size(temporary)
            if (copiedLength != entry.expectedLength) {
                throw InvalidMediaShareSourceException(
                    "Cached clip changed while preparing the share copy " +
                        "(expected ${entry.expectedLength} bytes, found $copiedLength).",
                )
            }
            // `ready` is FileProvider-visible, so only an atomically published,
            // complete file may enter it. Both directories are below cacheDir.
            Files.move(
                temporary,
                target,
                StandardCopyOption.ATOMIC_MOVE,
                StandardCopyOption.REPLACE_EXISTING,
            )
        } catch (error: IOException) {
            runCatching { Files.deleteIfExists(temporary) }
            throw error
        }
        return StagedMediaShare(target, filename, mimeType)
    }

    private fun ensureComplete(entry: MediaCacheEntry) {
        if (entry.state != MediaCacheState.COMPLETE || entry.downloadedBytes != entry.expectedLength) {
            throw IncompleteMediaShareException(entry.state)
        }
    }

    private fun validatePublishedSource(entry: MediaCacheEntry, source: Path) {
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

    private fun isUsableReadyCopy(path: Path, expectedLength: Long): Boolean =
        Files.isRegularFile(path, LinkOption.NOFOLLOW_LINKS) && Files.size(path) == expectedLength

    private fun targetPath(source: Path, extension: String): Path =
        readyDirectory.resolve("${sha256Hex(source.toString())}.$extension").normalize().also { path ->
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

    private fun mimeTypeFor(filename: String): String {
        validateFilename(filename)
        val extension = filename.substringAfterLast('.', missingDelimiterValue = "").lowercase(Locale.ROOT)
        return MIME_TYPES[extension] ?: throw UnsupportedMediaShareFormatException(filename)
    }

    private fun validateFilename(filename: String) {
        if (
            filename.isBlank() ||
                filename != filename.trim() ||
                filename == "." ||
                filename == ".." ||
                filename.indexOf('\u0000') >= 0 ||
                filename.contains('/') ||
                filename.contains('\\') ||
                filename.any { character -> character.code < 0x20 || character.code == 0x7F } ||
                filename.substringBeforeLast('.', missingDelimiterValue = "").isBlank()
        ) {
            throw UnsafeMediaShareFilenameException(filename)
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

    private companion object {
        val MIME_TYPES: Map<String, String> =
            mapOf(
                "mov" to "video/quicktime",
                "qt" to "video/quicktime",
                "mp4" to "video/mp4",
                "m4v" to "video/mp4",
                "mkv" to "video/x-matroska",
                "avi" to "video/x-msvideo",
            )
    }
}

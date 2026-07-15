package com.opencapture.openzcine.media

import android.content.ContentResolver
import android.content.ContentValues
import android.os.Environment
import android.provider.MediaStore
import java.io.FilterOutputStream
import java.io.IOException
import java.io.OutputStream
import java.nio.ByteBuffer
import java.nio.channels.FileChannel
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.Path
import java.nio.file.StandardOpenOption
import java.time.LocalDateTime
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.ResolverStyle
import java.util.Locale
import java.util.concurrent.CancellationException
import java.util.concurrent.atomic.AtomicBoolean

/** A complete immutable video copy that may be written into the device gallery. */
internal data class MediaGalleryArtifact(
    val file: Path,
    val displayName: String,
    val mimeType: String,
    val expectedBytes: Long,
    val captureTimestampMillis: Long? = null,
) {
    companion object {
        /** Converts the existing complete-cache staging result into a gallery input. */
        fun fromStagedShare(
            share: StagedMediaShare,
            captureTimestampMillis: Long? = null,
        ): MediaGalleryArtifact {
            if (!share.mimeType.startsWith("video/")) {
                throw InvalidMediaGalleryArtifactException("Only staged video media can be saved to Gallery.")
            }
            if (!isSafeMediaDisplayName(share.displayName)) {
                throw InvalidMediaGalleryArtifactException("The prepared video has an unsafe display name.")
            }
            val mimeType = galleryVideoMimeType(share.displayName)
                ?: throw InvalidMediaGalleryArtifactException(
                    "${share.displayName} isn't a supported Gallery video.",
                )
            val file = share.file.toAbsolutePath().normalize()
            val byteCount =
                runCatching { Files.size(file) }
                    .getOrElse {
                        throw InvalidMediaGalleryArtifactException(
                            "${share.displayName} is no longer available for Gallery.",
                            it,
                        )
                    }
            return MediaGalleryArtifact(
                file,
                share.displayName,
                mimeType,
                byteCount,
                captureTimestampMillis,
            )
        }
    }
}

/** A scoped MediaStore row that remains hidden while its bytes are being written. */
internal data class PendingMediaGalleryItem(val identifier: String)

/** Small platform seam that keeps MediaStore orchestration host-JVM testable. */
internal interface MediaGalleryGateway {
    fun createPending(artifact: MediaGalleryArtifact): PendingMediaGalleryItem

    fun openPending(item: PendingMediaGalleryItem): OutputStream

    fun publish(item: PendingMediaGalleryItem)

    fun deletePending(item: PendingMediaGalleryItem)
}

/** Debug-only failure point selected by the variant-specific demo harness. */
internal enum class MediaGalleryFailureInjection {
    NONE,
    WRITE_ONCE,
    ;

    companion object {
        fun parse(raw: String?): MediaGalleryFailureInjection =
            when (raw?.lowercase(Locale.ROOT)) {
                "write", "write-once" -> WRITE_ONCE
                else -> NONE
            }
    }
}

/** Android 10+ scoped-storage adapter for publishing operator-selected videos. */
internal class AndroidMediaGalleryGateway(
    private val resolver: ContentResolver,
    failureInjection: MediaGalleryFailureInjection = MediaGalleryFailureInjection.NONE,
) : MediaGalleryGateway {
    private val failNextWrite = AtomicBoolean(failureInjection == MediaGalleryFailureInjection.WRITE_ONCE)

    override fun createPending(artifact: MediaGalleryArtifact): PendingMediaGalleryItem {
        val values =
            ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, artifact.displayName)
                put(MediaStore.MediaColumns.MIME_TYPE, artifact.mimeType)
                put(
                    MediaStore.MediaColumns.RELATIVE_PATH,
                    "${Environment.DIRECTORY_MOVIES}/$GALLERY_DIRECTORY",
                )
                put(MediaStore.MediaColumns.IS_PENDING, 1)
                artifact.captureTimestampMillis?.let { timestamp ->
                    put(MediaStore.Video.VideoColumns.DATE_TAKEN, timestamp)
                }
            }
        val uri =
            resolver.insert(
                MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY),
                values,
            ) ?: throw MediaGalleryStoreUnavailableException(
                "Android didn't create a pending Gallery item.",
            )
        return PendingMediaGalleryItem(uri.toString())
    }

    override fun openPending(item: PendingMediaGalleryItem): OutputStream {
        val uri = android.net.Uri.parse(item.identifier)
        val output =
            resolver.openOutputStream(uri, "w")
                ?: throw MediaGalleryStoreUnavailableException(
                    "Android didn't open the pending Gallery item.",
                )
        if (!failNextWrite.compareAndSet(true, false)) return output
        return object : FilterOutputStream(output) {
            private fun fail(): Nothing = throw IOException("Injected Gallery write failure.")

            override fun write(value: Int) = fail()

            override fun write(bytes: ByteArray, offset: Int, length: Int) = fail()
        }
    }

    override fun publish(item: PendingMediaGalleryItem) {
        val values = ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) }
        val updated = resolver.update(android.net.Uri.parse(item.identifier), values, null, null)
        if (updated != 1) {
            throw MediaGalleryPublishException("Android didn't publish the completed Gallery item.")
        }
    }

    override fun deletePending(item: PendingMediaGalleryItem) {
        // A zero count is idempotent success: the provider may already have discarded the row.
        resolver.delete(android.net.Uri.parse(item.identifier), null, null)
    }

    private companion object {
        const val GALLERY_DIRECTORY = "OpenZCine"
    }
}

/** Parses the camera's PTP date without inventing a timestamp when metadata is incomplete. */
internal fun mediaCaptureTimestampMillis(
    captureDate: String,
    zoneId: ZoneId = ZoneId.systemDefault(),
): Long? =
    runCatching {
        LocalDateTime.parse(captureDate, PTP_CAPTURE_DATE_FORMATTER)
            .atZone(zoneId)
            .toInstant()
            .toEpochMilli()
    }.getOrNull()

private val PTP_CAPTURE_DATE_FORMATTER: DateTimeFormatter =
    DateTimeFormatter.ofPattern("uuuuMMdd'T'HHmmss", Locale.ROOT)
        .withResolverStyle(ResolverStyle.STRICT)

/** Stable operator-facing failure categories for one Gallery item. */
internal enum class MediaGalleryFailureKind {
    PERMISSION_DENIED,
    SOURCE_UNAVAILABLE,
    STORAGE_UNAVAILABLE,
    WRITE_FAILED,
    PUBLISH_FAILED,
    CLEANUP_FAILED,
}

/** One failed item in a sequential Gallery batch. */
internal data class MediaGalleryFailure(
    val displayName: String,
    val kind: MediaGalleryFailureKind,
    val operatorMessage: String,
)

/** Items intentionally omitted before the MediaStore writer runs. */
internal data class MediaGalleryOmissions(
    val nonVideoCount: Int = 0,
    val incompleteCount: Int = 0,
    val preparationFailureCount: Int = 0,
    val temporaryCleanupFailureCount: Int = 0,
) {
    init {
        require(nonVideoCount >= 0)
        require(incompleteCount >= 0)
        require(preparationFailureCount >= 0)
        require(temporaryCleanupFailureCount >= 0)
    }

    val totalCount: Int
        get() = nonVideoCount + incompleteCount + preparationFailureCount
}

/** Complete and partial outcome from a sequential Gallery batch. */
internal data class MediaGalleryBatchResult(
    val savedCount: Int,
    val failures: List<MediaGalleryFailure>,
) {
    init {
        require(savedCount >= 0)
    }

    val failedCount: Int
        get() = failures.size

    /** Concise, truthful result text shared by browser and playback. */
    fun operatorMessage(omissions: MediaGalleryOmissions = MediaGalleryOmissions()): String {
        val parts = mutableListOf<String>()
        when {
            savedCount > 0 -> parts += "Saved $savedCount ${noun(savedCount, "clip", "clips")} to Gallery"
            failedCount > 0 -> parts += failures.first().operatorMessage
            else -> parts += "No videos were saved to Gallery"
        }
        if (savedCount > 0 && failedCount > 0) {
            parts += "$failedCount ${noun(failedCount, "clip", "clips")} couldn't be saved"
        } else if (savedCount == 0 && failedCount > 1) {
            parts += "${failedCount - 1} more ${noun(failedCount - 1, "clip", "clips")} failed"
        }
        if (omissions.nonVideoCount > 0) {
            parts +=
                "${omissions.nonVideoCount} non-video " +
                    "${noun(omissions.nonVideoCount, "item", "items")} skipped"
        }
        if (omissions.incompleteCount > 0) {
            parts +=
                "${omissions.incompleteCount} incomplete " +
                    "${noun(omissions.incompleteCount, "item wasn't", "items weren't")} ready"
        }
        if (omissions.preparationFailureCount > 0) {
            parts +=
                "${omissions.preparationFailureCount} " +
                    "${noun(omissions.preparationFailureCount, "item", "items")} couldn't be prepared"
        }
        if (omissions.temporaryCleanupFailureCount > 0) {
            parts +=
                "${omissions.temporaryCleanupFailureCount} temporary " +
                    "${noun(omissions.temporaryCleanupFailureCount, "export wasn't", "exports weren't")} removed"
        }
        return parts.joinToString(separator = "; ", postfix = ".")
    }

    private fun noun(count: Int, singular: String, plural: String): String =
        if (count == 1) singular else plural
}

/**
 * Sequentially copies complete prepared videos into scoped MediaStore rows.
 *
 * Each row remains `IS_PENDING=1` until the source byte count is verified. Any
 * exception or cancellation after insertion attempts deletion before the
 * failure is returned or cancellation is rethrown.
 */
internal class MediaGallerySaver(private val gateway: MediaGalleryGateway) {
    fun save(
        artifacts: List<MediaGalleryArtifact>,
        cancellationCheck: () -> Unit = {},
    ): MediaGalleryBatchResult {
        var saved = 0
        val failures = mutableListOf<MediaGalleryFailure>()
        artifacts.forEach { artifact ->
            cancellationCheck()
            val failure = saveOne(artifact, cancellationCheck)
            if (failure == null) saved += 1 else failures += failure
        }
        return MediaGalleryBatchResult(savedCount = saved, failures = failures)
    }

    private fun saveOne(
        artifact: MediaGalleryArtifact,
        cancellationCheck: () -> Unit,
    ): MediaGalleryFailure? {
        var phase = SavePhase.VALIDATE
        var pending: PendingMediaGalleryItem? = null
        try {
            validateArtifact(artifact)
            cancellationCheck()
            phase = SavePhase.CREATE
            pending = gateway.createPending(artifact)
            cancellationCheck()
            phase = SavePhase.WRITE
            gateway.openPending(pending).use { output ->
                copyExact(artifact, output, cancellationCheck)
            }
            cancellationCheck()
            phase = SavePhase.PUBLISH
            gateway.publish(pending)
            return null
        } catch (cancelled: CancellationException) {
            val cleanupFailure = pending?.let(::cleanupFailure)
            cleanupFailure?.let(cancelled::addSuppressed)
            throw cancelled
        } catch (error: Exception) {
            val cleanupFailure = pending?.let(::cleanupFailure)
            return classifyFailure(artifact.displayName, phase, error, cleanupFailure)
        }
    }

    private fun validateArtifact(artifact: MediaGalleryArtifact) {
        if (!isSafeMediaDisplayName(artifact.displayName)) {
            throw InvalidMediaGalleryArtifactException("The Gallery display name is unsafe.")
        }
        if (galleryVideoMimeType(artifact.displayName) != artifact.mimeType) {
            throw InvalidMediaGalleryArtifactException("The prepared Gallery video type is inconsistent.")
        }
        if (artifact.expectedBytes <= 0) {
            throw InvalidMediaGalleryArtifactException("The prepared Gallery video is empty.")
        }
        if (
            !Files.isRegularFile(artifact.file, LinkOption.NOFOLLOW_LINKS) ||
                Files.isSymbolicLink(artifact.file) ||
                Files.size(artifact.file) != artifact.expectedBytes
        ) {
            throw InvalidMediaGalleryArtifactException("The prepared Gallery video is no longer complete.")
        }
    }

    private fun copyExact(
        artifact: MediaGalleryArtifact,
        output: OutputStream,
        cancellationCheck: () -> Unit,
    ) {
        FileChannel.open(
            artifact.file,
            StandardOpenOption.READ,
            LinkOption.NOFOLLOW_LINKS,
        ).use { source ->
            if (source.size() != artifact.expectedBytes) {
                throw InvalidMediaGalleryArtifactException("The prepared Gallery video changed before writing.")
            }
            val buffer = ByteBuffer.allocate(COPY_BUFFER_BYTES)
            var copied = 0L
            while (copied < artifact.expectedBytes) {
                cancellationCheck()
                buffer.clear()
                buffer.limit(
                    minOf(buffer.capacity().toLong(), artifact.expectedBytes - copied).toInt(),
                )
                val read = source.read(buffer)
                if (read < 0) {
                    throw InvalidMediaGalleryArtifactException("The prepared Gallery video ended early.")
                }
                if (read == 0) continue
                output.write(buffer.array(), 0, read)
                copied += read.toLong()
            }
            cancellationCheck()
            output.flush()
            if (copied != artifact.expectedBytes || source.size() != artifact.expectedBytes) {
                throw InvalidMediaGalleryArtifactException("The prepared Gallery video changed while writing.")
            }
        }
    }

    private fun cleanupFailure(item: PendingMediaGalleryItem): Exception? =
        try {
            gateway.deletePending(item)
            null
        } catch (error: Exception) {
            error
        }

    private fun classifyFailure(
        displayName: String,
        phase: SavePhase,
        error: Exception,
        cleanupFailure: Exception?,
    ): MediaGalleryFailure {
        if (cleanupFailure != null) {
            return MediaGalleryFailure(
                displayName = displayName,
                kind = MediaGalleryFailureKind.CLEANUP_FAILED,
                operatorMessage =
                    "Android couldn't clean up an incomplete Gallery item for $displayName. " +
                        "Restart the app before retrying.",
            )
        }
        if (error is SecurityException) {
            return MediaGalleryFailure(
                displayName = displayName,
                kind = MediaGalleryFailureKind.PERMISSION_DENIED,
                operatorMessage =
                    "Gallery access was denied for $displayName. Check Android storage access and try again.",
            )
        }
        val kind =
            when {
                error is InvalidMediaGalleryArtifactException ->
                    MediaGalleryFailureKind.SOURCE_UNAVAILABLE
                phase == SavePhase.CREATE -> MediaGalleryFailureKind.STORAGE_UNAVAILABLE
                phase == SavePhase.WRITE -> MediaGalleryFailureKind.WRITE_FAILED
                phase == SavePhase.PUBLISH -> MediaGalleryFailureKind.PUBLISH_FAILED
                else -> MediaGalleryFailureKind.SOURCE_UNAVAILABLE
            }
        val message =
            when (kind) {
                MediaGalleryFailureKind.SOURCE_UNAVAILABLE ->
                    "$displayName is no longer a complete readable video. Cache it again and retry."
                MediaGalleryFailureKind.STORAGE_UNAVAILABLE ->
                    "Android couldn't create a Gallery item for $displayName. Check available device storage."
                MediaGalleryFailureKind.WRITE_FAILED ->
                    "Android couldn't finish writing $displayName to Gallery. Check available device storage."
                MediaGalleryFailureKind.PUBLISH_FAILED ->
                    "Android couldn't publish $displayName to Gallery. The incomplete item was removed."
                MediaGalleryFailureKind.PERMISSION_DENIED,
                MediaGalleryFailureKind.CLEANUP_FAILED,
                -> error.message ?: "Gallery delivery failed for $displayName."
            }
        return MediaGalleryFailure(displayName, kind, message)
    }

    private enum class SavePhase {
        VALIDATE,
        CREATE,
        WRITE,
        PUBLISH,
    }

    private companion object {
        const val COPY_BUFFER_BYTES = 256 * 1024
    }
}

/** The prepared item is not a safe, complete Gallery input. */
internal class InvalidMediaGalleryArtifactException(message: String, cause: Throwable? = null) :
    IOException(message, cause)

/** MediaStore refused to create or open a pending row. */
internal class MediaGalleryStoreUnavailableException(message: String) : IOException(message)

/** MediaStore did not publish exactly one completed row. */
internal class MediaGalleryPublishException(message: String) : IOException(message)

/** Exact MediaStore video MIME metadata after core-owned video classification. */
internal fun galleryVideoMimeType(displayName: String): String? =
    when (displayName.substringAfterLast('.', missingDelimiterValue = "").lowercase(Locale.ROOT)) {
        "mov" -> "video/quicktime"
        "mp4", "m4v" -> "video/mp4"
        else -> null
    }

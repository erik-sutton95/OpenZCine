@file:androidx.media3.common.util.UnstableApi

package com.opencapture.openzcine.frameio

import android.content.Context
import android.net.Uri
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.effect.DefaultVideoFrameProcessor
import androidx.media3.effect.SingleColorLut
import androidx.media3.transformer.Composition
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.Effects
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.ProgressHolder
import androidx.media3.transformer.Transformer
import com.opencapture.openzcine.FeedLutSelection
import com.opencapture.openzcine.bridge.SwiftCore
import com.opencapture.openzcine.lut.AndroidLutLibrary
import com.opencapture.openzcine.media.StagedMediaShare
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.channels.FileChannel
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.Path
import java.nio.file.StandardCopyOption
import java.nio.file.StandardOpenOption
import java.time.Instant
import java.util.UUID
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** Container chosen for a LUT-baked native or Frame.io export. */
internal enum class MediaExportContainer(
    val label: String,
    val extension: String,
    val mimeType: String,
) {
    MOV("MOV", "mov", "video/quicktime"),
    MP4("MP4", "mp4", "video/mp4"),
}

/** One explicit per-run configuration shared by every external media destination. */
internal data class MediaDeliveryConfiguration(
    val bakeLut: Boolean = false,
    val exportContainer: MediaExportContainer = MediaExportContainer.MOV,
    val includeMetadata: Boolean = true,
    val selectedLut: FeedLutSelection? = null,
    val forceFrameioReupload: Boolean = false,
) {
    init {
        require(!bakeLut || selectedLut != null) {
            "A LUT-baked delivery requires an operator-selected LUT."
        }
    }
}

/** Compatibility name retained for existing Frame.io call sites and tests. */
internal typealias FrameioDeliveryOptions = MediaDeliveryConfiguration

/** Non-secret camera/media context retained while a network hop tears down the session. */
internal data class FrameioArtifactContext(
    val cameraID: String,
    val captureDate: String,
    val supportsLutBake: Boolean,
    val stableClipIdentity: String = "",
)

/** One Swift-approved cube ready for Media3's export-only colour effect. */
internal class FrameioLutPayload(
    val displayName: String,
    val cubeSize: Int,
    val packedRgba: ByteArray,
) {
    init {
        require(cubeSize in 2..64 && packedRgba.size == cubeSize * cubeSize * cubeSize * 4) {
            "The selected LUT payload is invalid."
        }
    }

    override fun toString(): String = "FrameioLutPayload(name=$displayName, pixels=redacted)"
}

/** Upload-ready output plus the exact look that was actually baked, if any. */
internal class FrameioPreparedArtifact(
    val share: StagedMediaShare,
    val byteCount: Long,
    val appliedLutName: String?,
    val transientExport: Path?,
) {
    override fun toString(): String = "FrameioPreparedArtifact(redacted)"
}

/** Typed preparation boundary between approved cache copies and cloud upload. */
internal interface FrameioArtifactPreparer {
    suspend fun prepare(
        artifact: FrameioDeliveryArtifact,
        options: FrameioDeliveryOptions,
        onProgress: suspend (Double) -> Unit,
    ): FrameioPreparedArtifact

    suspend fun release(prepared: FrameioPreparedArtifact)
}

/** Default test/minimal path: upload the already-approved staged original unchanged. */
internal object PassthroughFrameioArtifactPreparer : FrameioArtifactPreparer {
    override suspend fun prepare(
        artifact: FrameioDeliveryArtifact,
        options: FrameioDeliveryOptions,
        onProgress: suspend (Double) -> Unit,
    ): FrameioPreparedArtifact {
        if (options.bakeLut) {
            throw FrameioDeliveryException("LUT-baked Frame.io export is unavailable in this install.")
        }
        return FrameioPreparedArtifact(
            share = artifact.share,
            byteCount = artifact.byteCount,
            appliedLutName = null,
            transientExport = null,
        )
    }

    override suspend fun release(prepared: FrameioPreparedArtifact) = Unit
}

/** Resolves only a built-in core cube or revalidated app-private stored selection. */
internal interface FrameioLutProvider {
    suspend fun approvedPayload(selection: FeedLutSelection): FrameioLutPayload?
}

/** Production LUT resolver. Kotlin never parses `.cube` source or invents colour math. */
internal class AndroidFrameioLutProvider(
    private val library: AndroidLutLibrary,
) : FrameioLutProvider {
    override suspend fun approvedPayload(selection: FeedLutSelection): FrameioLutPayload? =
        when (selection) {
            is FeedLutSelection.BuiltIn -> {
                if (!SwiftCore.isAvailable) return null
                val packed = SwiftCore.bakeLut(selection.value.wireOrdinal, BUILT_IN_CUBE_SIZE)
                    ?: return null
                FrameioLutPayload(selection.value.label, BUILT_IN_CUBE_SIZE, packed)
            }
            is FeedLutSelection.Stored -> {
                if (!library.prepare(selection.value)) return null
                val packed = library.packedCube(selection.value) ?: return null
                val name = library.displayName(selection.value) ?: return null
                FrameioLutPayload(name, packed.cubeSize, packed.rgba)
            }
        }

    private companion object {
        const val BUILT_IN_CUBE_SIZE = 33
    }
}

/** Export seam kept separate so host tests do not need a codec or Android looper. */
internal interface FrameioLutVideoExporter {
    suspend fun export(
        source: Path,
        target: Path,
        lut: FrameioLutPayload,
        onProgress: suspend (Double) -> Unit,
    )
}

/**
 * Media3 Transformer export that applies one approved 3D LUT to video frames.
 * The camera/share original remains read-only and audio is retained.
 */
internal class AndroidMedia3FrameioLutVideoExporter(
    context: Context,
    private val mainDispatcher: CoroutineDispatcher = Dispatchers.Main.immediate,
) : FrameioLutVideoExporter {
    private val context = context.applicationContext

    override suspend fun export(
        source: Path,
        target: Path,
        lut: FrameioLutPayload,
        onProgress: suspend (Double) -> Unit,
    ) = withContext(mainDispatcher) {
        Files.deleteIfExists(target)
        val completion = CompletableDeferred<Unit>()
        // OpenZCine's monitor cubes are authored over electrical/display-
        // encoded SDR values. Pin Media3's working space explicitly so this
        // export cannot silently regress to the pre-1.4 linear-SDR default.
        val videoFrameProcessorFactory =
            DefaultVideoFrameProcessor.Factory.Builder()
                .setSdrWorkingColorSpace(DefaultVideoFrameProcessor.WORKING_COLOR_SPACE_ORIGINAL)
                .build()
        val transformer =
            Transformer.Builder(context)
                .setVideoMimeType(MimeTypes.VIDEO_H264)
                .setAudioMimeType(MimeTypes.AUDIO_AAC)
                .setVideoFrameProcessorFactory(videoFrameProcessorFactory)
                .addListener(
                    object : Transformer.Listener {
                        override fun onCompleted(composition: Composition, exportResult: ExportResult) {
                            completion.complete(Unit)
                        }

                        override fun onError(
                            composition: Composition,
                            exportResult: ExportResult,
                            exportException: ExportException,
                        ) {
                            completion.completeExceptionally(
                                FrameioDeliveryException(
                                    "OpenZCine couldn't bake the selected LUT for this clip. " +
                                        "The source may use a codec or HDR mode this device cannot export safely.",
                                ),
                            )
                        }
                    },
                ).build()
        val effect = SingleColorLut.createFromCube(lut.toMedia3Cube())
        val item =
            EditedMediaItem.Builder(MediaItem.fromUri(Uri.fromFile(source.toFile())))
                .setEffects(Effects(emptyList(), listOf(effect)))
                .build()

        coroutineScope {
            transformer.start(item, target.toString())
            val watchdog = FrameioExportProgressWatchdog(EXPORT_STALL_TIMEOUT_MILLIS)
            val progressJob =
                launch {
                    val holder = ProgressHolder()
                    while (isActive && !completion.isCompleted) {
                        if (transformer.getProgress(holder) == Transformer.PROGRESS_STATE_AVAILABLE) {
                            watchdog.recordProgress(holder.progress)
                            onProgress((holder.progress / 100.0).coerceIn(0.0, 1.0))
                        }
                        if (watchdog.hasStalled()) {
                            transformer.cancel()
                            completion.completeExceptionally(
                                FrameioDeliveryException(
                                    "OpenZCine stopped the LUT export because this device's media encoder stopped making progress.",
                                ),
                            )
                        }
                        delay(PROGRESS_POLL_MILLIS)
                    }
                }
            try {
                completion.await()
                onProgress(1.0)
            } finally {
                progressJob.cancel()
                if (!completion.isCompleted) transformer.cancel()
            }
        }
    }

    private companion object {
        const val PROGRESS_POLL_MILLIS = 180L
        const val EXPORT_STALL_TIMEOUT_MILLIS = 180_000L
    }
}

/** Monotonic no-progress deadline for device codec/driver stalls. */
internal class FrameioExportProgressWatchdog(
    stallTimeoutMillis: Long,
    private val nanoClock: () -> Long = System::nanoTime,
) {
    private val stallTimeoutNanos: Long
    private var lastProgress = -1
    private var lastAdvanceNanos: Long

    init {
        require(stallTimeoutMillis in 1..Long.MAX_VALUE / NANOS_PER_MILLISECOND) {
            "Export stall timeout must be positive and bounded."
        }
        stallTimeoutNanos = stallTimeoutMillis * NANOS_PER_MILLISECOND
        lastAdvanceNanos = nanoClock()
    }

    fun recordProgress(progress: Int) {
        val bounded = progress.coerceIn(0, 100)
        if (bounded > lastProgress) {
            lastProgress = bounded
            lastAdvanceNanos = nanoClock()
        }
    }

    fun hasStalled(): Boolean = nanoClock() - lastAdvanceNanos >= stallTimeoutNanos

    private companion object {
        const val NANOS_PER_MILLISECOND = 1_000_000L
    }
}

/** Production preparer for optional, per-delivery LUT-baked MOV or MP4 output. */
internal class AndroidFrameioArtifactPreparer(
    private val exportRoot: Path,
    private val lutProvider: FrameioLutProvider,
    private val exporter: FrameioLutVideoExporter,
    private val deleteExport: (Path) -> Boolean = Files::deleteIfExists,
) : FrameioArtifactPreparer {
    override suspend fun prepare(
        artifact: FrameioDeliveryArtifact,
        options: FrameioDeliveryOptions,
        onProgress: suspend (Double) -> Unit,
    ): FrameioPreparedArtifact {
        if (!options.bakeLut) {
            return FrameioPreparedArtifact(artifact.share, artifact.byteCount, null, null)
        }
        if (!artifact.context.supportsLutBake) {
            throw FrameioDeliveryException(
                "${artifact.share.displayName} isn't a video proxy that can receive a baked LUT.",
            )
        }
        val selection = requireNotNull(options.selectedLut)
        val lut = lutProvider.approvedPayload(selection)
            ?: throw FrameioDeliveryException(
                "The selected LUT is no longer approved for export. Re-select or re-import it and try again.",
            )
        withContext(Dispatchers.IO) {
            Files.createDirectories(exportRoot)
            pruneOwnedFrameioExports(exportRoot)
        }
        val target = exportRoot.resolve("frameio-${UUID.randomUUID()}.${options.exportContainer.extension}")
        try {
            exporter.export(artifact.share.file, target, lut, onProgress)
            val byteCount =
                withContext(Dispatchers.IO) {
                    finalizeMediaExportContainer(target, options.exportContainer)
                    if (!Files.isRegularFile(target) || Files.size(target) <= 0) {
                        throw FrameioDeliveryException(
                            "The LUT-baked export did not produce a complete video.",
                        )
                    }
                    Files.size(target)
                }
            return FrameioPreparedArtifact(
                share =
                    StagedMediaShare(
                        file = target,
                        displayName = bakedFilename(artifact.share.displayName, options.exportContainer),
                        mimeType = options.exportContainer.mimeType,
                    ),
                byteCount = byteCount,
                appliedLutName = lut.displayName,
                transientExport = target,
            )
        } catch (error: Throwable) {
            val cleanupFailure =
                withContext(NonCancellable + Dispatchers.IO) {
                    try {
                        val removed = deleteExport(target)
                        if (!removed && Files.exists(target, LinkOption.NOFOLLOW_LINKS)) {
                            FrameioDeliveryException(
                                "OpenZCine couldn't remove the incomplete Frame.io export.",
                            )
                        } else {
                            null
                        }
                    } catch (cleanupError: Throwable) {
                        cleanupError
                    }
                }
            cleanupFailure?.let(error::addSuppressed)
            throw error
        }
    }

    override suspend fun release(prepared: FrameioPreparedArtifact) {
        withContext(NonCancellable + Dispatchers.IO) {
            prepared.transientExport?.let { path ->
                val removed =
                    try {
                        deleteExport(path)
                    } catch (_: Exception) {
                        false
                    }
                if (!removed && Files.exists(path, LinkOption.NOFOLLOW_LINKS)) {
                    throw FrameioDeliveryException(
                        "OpenZCine couldn't remove the temporary Frame.io export.",
                    )
                }
            }
        }
    }

    private fun bakedFilename(original: String, container: MediaExportContainer): String =
        original.substringBeforeLast('.', missingDelimiterValue = original).ifBlank { "OpenZCine" } +
            ".${container.extension}"
}

/**
 * Media3 always emits an ISO-BMFF MP4. Its H.264/AAC box graph is also valid in
 * QuickTime MOV, so MOV delivery rewrites the completed `ftyp` brands instead
 * of merely relabelling an MP4 file. The transient export is the only file
 * opened for writing; the camera/share original remains read-only.
 */
internal fun finalizeMediaExportContainer(target: Path, container: MediaExportContainer) {
    if (container == MediaExportContainer.MP4) return
    if (
        !Files.isRegularFile(target, LinkOption.NOFOLLOW_LINKS) ||
            Files.isSymbolicLink(target)
    ) {
        throw FrameioDeliveryException("The LUT-baked MOV export is not a complete regular file.")
    }
    FileChannel.open(
        target,
        StandardOpenOption.READ,
        StandardOpenOption.WRITE,
        LinkOption.NOFOLLOW_LINKS,
    ).use { channel ->
        val header = ByteBuffer.allocate(QUICKTIME_FTYP_HEADER_BYTES).order(ByteOrder.BIG_ENDIAN)
        while (header.hasRemaining()) {
            if (channel.read(header) <= 0) {
                throw FrameioDeliveryException("The LUT-baked MOV export has an incomplete media header.")
            }
        }
        header.flip()
        val boxSize = header.int.toLong() and 0xFFFF_FFFFL
        val boxType = ByteArray(4).also(header::get)
        if (
            !boxType.contentEquals(FTYP_BOX_TYPE) ||
                boxSize < QUICKTIME_FTYP_HEADER_BYTES ||
                boxSize > channel.size()
        ) {
            throw FrameioDeliveryException("The LUT-baked MOV export has an unsupported media header.")
        }
        writeFully(channel, QUICKTIME_MAJOR_BRAND_OFFSET, QUICKTIME_BRAND)
        writeFully(channel, QUICKTIME_COMPATIBLE_BRAND_OFFSET, QUICKTIME_BRAND)
        channel.force(true)
    }
}

private fun writeFully(channel: FileChannel, offset: Long, bytes: ByteArray) {
    channel.position(offset)
    val buffer = ByteBuffer.wrap(bytes)
    while (buffer.hasRemaining()) channel.write(buffer)
}

private val FTYP_BOX_TYPE = byteArrayOf(0x66, 0x74, 0x79, 0x70)
private val QUICKTIME_BRAND = byteArrayOf(0x71, 0x74, 0x20, 0x20)
private const val QUICKTIME_FTYP_HEADER_BYTES = 20
private const val QUICKTIME_MAJOR_BRAND_OFFSET = 8L
private const val QUICKTIME_COMPATIBLE_BRAND_OFFSET = 16L

/** Removes only app-owned transient exports by age and a bounded cache budget. */
internal fun pruneOwnedFrameioExports(
    root: Path,
    protected: Set<Path> = emptySet(),
    nowEpochMillis: Long = System.currentTimeMillis(),
    maximumAgeMillis: Long = FRAMEIO_EXPORT_MAXIMUM_AGE_MILLIS,
    maximumBytes: Long = FRAMEIO_EXPORT_MAXIMUM_BYTES,
) {
    require(maximumAgeMillis >= 0 && maximumBytes >= 0)
    if (!Files.isDirectory(root, LinkOption.NOFOLLOW_LINKS)) return
    val protectedPaths = protected.map { it.toAbsolutePath().normalize() }.toSet()
    val candidates =
        Files.list(root).use { paths ->
            paths.iterator().asSequence()
                .filter { path ->
                    path.fileName.toString().matches(FRAMEIO_EXPORT_FILENAME) &&
                        Files.isRegularFile(path, LinkOption.NOFOLLOW_LINKS) &&
                        !Files.isSymbolicLink(path)
                }.map { path ->
                    OwnedFrameioExport(
                        path = path,
                        modifiedAt = Files.getLastModifiedTime(path).toMillis(),
                        sizeBytes = Files.size(path),
                    )
                }.sortedBy(OwnedFrameioExport::modifiedAt)
                .toList()
        }
    val surviving = mutableListOf<OwnedFrameioExport>()
    candidates.forEach { export ->
        val normalized = export.path.toAbsolutePath().normalize()
        val expired = nowEpochMillis - export.modifiedAt > maximumAgeMillis
        if (normalized !in protectedPaths && expired) {
            Files.deleteIfExists(export.path)
        } else {
            surviving += export
        }
    }
    var totalBytes = surviving.sumOf(OwnedFrameioExport::sizeBytes)
    surviving.forEach { export ->
        if (totalBytes <= maximumBytes) return@forEach
        val normalized = export.path.toAbsolutePath().normalize()
        if (normalized !in protectedPaths && Files.deleteIfExists(export.path)) {
            totalBytes -= export.sizeBytes
        }
    }
}

private data class OwnedFrameioExport(
    val path: Path,
    val modifiedAt: Long,
    val sizeBytes: Long,
)

private val FRAMEIO_EXPORT_FILENAME =
    Regex(
        "frameio-[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-" +
            "[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\\.(mov|mp4)",
    )
private const val FRAMEIO_EXPORT_MAXIMUM_AGE_MILLIS = 24L * 60L * 60L * 1_000L
private const val FRAMEIO_EXPORT_MAXIMUM_BYTES = 2L * 1_024L * 1_024L * 1_024L

/** Writes a local sidecar only after Frame.io confirms the upload. */
internal interface FrameioMetadataSidecarWriter {
    suspend fun recordSuccessfulDelivery(
        artifact: FrameioDeliveryArtifact,
        prepared: FrameioPreparedArtifact,
        destination: FrameioDestination,
        options: FrameioDeliveryOptions,
    )
}

internal object NoFrameioMetadataSidecarWriter : FrameioMetadataSidecarWriter {
    override suspend fun recordSuccessfulDelivery(
        artifact: FrameioDeliveryArtifact,
        prepared: FrameioPreparedArtifact,
        destination: FrameioDestination,
        options: FrameioDeliveryOptions,
    ) = Unit
}

/** Stable, secret-free sidecar payload written only after a confirmed upload. */
internal data class FrameioMetadataSidecar(
    val cameraID: String,
    val captureDate: String,
    val deliveredAt: String,
    val deliveryFilename: String,
    val lutName: String?,
    val originalFilename: String,
    val projectName: String,
    val sizeBytes: Long,
)

/** Small JSON encoder kept Android-free so escaping and field policy are host-testable. */
internal object FrameioMetadataSidecarCodec {
    fun encode(value: FrameioMetadataSidecar): String =
        buildString {
            append("{\n")
            appendField("cameraID", value.cameraID)
            appendField("captureDate", value.captureDate)
            appendField("deliveredAt", value.deliveredAt)
            appendField("deliveryFilename", value.deliveryFilename)
            appendNullableField("lutName", value.lutName)
            appendField("originalFilename", value.originalFilename)
            appendField("projectName", value.projectName)
            append("  \"sizeBytes\": ${value.sizeBytes},\n")
            append("  \"version\": 1\n")
            append('}')
        }

    private fun StringBuilder.appendField(name: String, value: String) {
        append("  ")
        append(jsonString(name))
        append(": ")
        append(jsonString(value))
        append(",\n")
    }

    private fun StringBuilder.appendNullableField(name: String, value: String?) {
        append("  ")
        append(jsonString(name))
        append(": ")
        append(value?.let(::jsonString) ?: "null")
        append(",\n")
    }

    private fun jsonString(value: String): String =
        buildString {
            append('"')
            value.forEach { character ->
                when (character) {
                    '"' -> append("\\\"")
                    '\\' -> append("\\\\")
                    '\b' -> append("\\b")
                    '\u000C' -> append("\\f")
                    '\n' -> append("\\n")
                    '\r' -> append("\\r")
                    '\t' -> append("\\t")
                    else ->
                        if (character.code < 0x20) {
                            append("\\u")
                            append(character.code.toString(16).padStart(4, '0'))
                        } else {
                            append(character)
                        }
                }
            }
            append('"')
        }
}

/** App-private, bounded metadata history. OAuth values and upload URLs never enter a sidecar. */
internal class AndroidFrameioMetadataSidecarWriter(
    private val root: Path,
    private val clock: () -> Long = System::currentTimeMillis,
) : FrameioMetadataSidecarWriter {
    override suspend fun recordSuccessfulDelivery(
        artifact: FrameioDeliveryArtifact,
        prepared: FrameioPreparedArtifact,
        destination: FrameioDestination,
        options: FrameioDeliveryOptions,
    ) {
        if (!options.includeMetadata) return
        withContext(Dispatchers.IO) {
            Files.createDirectories(root)
            val deliveredAt = clock()
            val body =
                FrameioMetadataSidecarCodec.encode(
                    FrameioMetadataSidecar(
                        cameraID = artifact.context.cameraID,
                        captureDate = artifact.context.captureDate,
                        deliveredAt = Instant.ofEpochMilli(deliveredAt).toString(),
                        deliveryFilename = prepared.share.displayName,
                        lutName = prepared.appliedLutName,
                        originalFilename = artifact.share.displayName,
                        projectName = destination.projectName,
                        sizeBytes = prepared.byteCount,
                    ),
                )
            val stem = safeSidecarStem(artifact.share.displayName)
            val target = root.resolve("$stem-$deliveredAt-${UUID.randomUUID()}.meta.json")
            val temporary = root.resolve(".${target.fileName}.tmp")
            try {
                Files.write(temporary, body.toByteArray(Charsets.UTF_8))
                Files.move(
                    temporary,
                    target,
                    StandardCopyOption.ATOMIC_MOVE,
                    StandardCopyOption.REPLACE_EXISTING,
                )
                pruneSidecars()
            } finally {
                Files.deleteIfExists(temporary)
            }
        }
    }

    private fun pruneSidecars() {
        val entries =
            Files.list(root).use { paths ->
                paths.iterator().asSequence()
                    .filter { path -> path.fileName.toString().endsWith(".meta.json") }
                    .sortedBy { path -> Files.getLastModifiedTime(path).toMillis() }
                    .toList()
            }
        entries.take((entries.size - MAXIMUM_SIDECARS).coerceAtLeast(0)).forEach { path ->
            runCatching { Files.deleteIfExists(path) }
        }
    }

    private fun safeSidecarStem(filename: String): String =
        filename.substringBeforeLast('.', missingDelimiterValue = filename)
            .map { character ->
                if (character.isLetterOrDigit() || character == '-' || character == '_') {
                    character
                } else {
                    '_'
                }
            }
            .joinToString("")
            .take(64)
            .ifBlank { "OpenZCine" }

    private companion object {
        const val MAXIMUM_SIDECARS = 100
    }
}

/** Converts Swift's `(x=b*n+r,y=g)` RGBA8 texture order to Media3 `cube[r][g][b]`. */
internal fun FrameioLutPayload.toMedia3Cube(): Array<Array<IntArray>> =
    Array(cubeSize) { red ->
        Array(cubeSize) { green ->
            IntArray(cubeSize) { blue ->
                val offset = ((green * cubeSize + blue) * cubeSize + red) * 4
                val r = packedRgba[offset].toInt() and 0xFF
                val g = packedRgba[offset + 1].toInt() and 0xFF
                val b = packedRgba[offset + 2].toInt() and 0xFF
                val a = packedRgba[offset + 3].toInt() and 0xFF
                (a shl 24) or (r shl 16) or (g shl 8) or b
            }
        }
    }

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
import com.opencapture.opencine.runtime.MonitorMovieExportLut
import com.opencapture.opencine.runtime.MonitorMovieExportContainer
import com.opencapture.opencine.runtime.MonitorMovieCodecFactory
import com.opencapture.opencine.runtime.MonitorMovieCodec
import com.opencapture.opencine.runtime.MonitorNativeMovieExporter
import com.opencapture.opencine.runtime.MonitorMovieExportPreparer
import com.opencapture.opencine.runtime.MonitorMovieExportInput
import com.opencapture.opencine.runtime.MonitorPreparedMovieExport
import com.opencapture.opencine.runtime.MonitorLutMovieExporter
import com.opencapture.opencine.runtime.MonitorMovieExportErrorFactory
import com.opencapture.opencine.runtime.MonitorMovieExportFailure
import com.opencapture.openzcine.FeedLutSelection
import com.opencapture.openzcine.bridge.SwiftCore
import com.opencapture.openzcine.lut.AndroidLutLibrary
import com.opencapture.openzcine.media.StagedMediaShare
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.Path
import java.nio.file.StandardCopyOption
import java.nio.file.StandardOpenOption
import java.time.Instant
import java.util.UUID
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.withContext

/** One explicit per-run configuration shared by every external media destination. */
internal data class MediaDeliveryConfiguration(
    val bakeLut: Boolean = false,
    val exportContainer: MonitorMovieExportContainer = MonitorMovieExportContainer.MOV,
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

/** Non-secret camera/media context retained while a network hop tears down the session. */
internal data class FrameioArtifactContext(
    val cameraID: String,
    val captureDate: String,
    val supportsLutBake: Boolean,
    val stableClipIdentity: String = "",
)

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
        options: MediaDeliveryConfiguration,
        onProgress: suspend (Double) -> Unit,
    ): FrameioPreparedArtifact

    suspend fun release(prepared: FrameioPreparedArtifact)
}

/** Default test/minimal path: upload the already-approved staged original unchanged. */
internal object PassthroughFrameioArtifactPreparer : FrameioArtifactPreparer {
    override suspend fun prepare(
        artifact: FrameioDeliveryArtifact,
        options: MediaDeliveryConfiguration,
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
    suspend fun approvedPayload(selection: FeedLutSelection): MonitorMovieExportLut?
}

/** Production LUT resolver. Kotlin never parses `.cube` source or invents colour math. */
internal class AndroidFrameioLutProvider(
    private val library: AndroidLutLibrary,
) : FrameioLutProvider {
    override suspend fun approvedPayload(selection: FeedLutSelection): MonitorMovieExportLut? =
        when (selection) {
            is FeedLutSelection.BuiltIn -> {
                if (!SwiftCore.isAvailable) return null
                val packed = SwiftCore.bakeLut(selection.value.wireOrdinal, BUILT_IN_CUBE_SIZE)
                    ?: return null
                MonitorMovieExportLut(selection.value.label, BUILT_IN_CUBE_SIZE, packed)
            }
            is FeedLutSelection.Stored -> {
                if (!library.prepare(selection.value)) return null
                val packed = library.packedCube(selection.value) ?: return null
                val name = library.displayName(selection.value) ?: return null
                MonitorMovieExportLut(name, packed.cubeSize, packed.rgba)
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
        lut: MonitorMovieExportLut,
        onProgress: suspend (Double) -> Unit,
    )
}

/** Media3 construction is host-owned; export completion and polling belong to the runtime. */
internal class AndroidMedia3FrameioLutVideoExporter(
    context: Context,
    mainDispatcher: CoroutineDispatcher = Dispatchers.Main.immediate,
) : FrameioLutVideoExporter {
    private val context = context.applicationContext
    private val owner = MonitorNativeMovieExporter(
        factory = MonitorMovieCodecFactory { source, target, lut, completion ->
            // Preserve the monitor cube's electrical/display-encoded SDR working space.
            val videoFrameProcessorFactory = DefaultVideoFrameProcessor.Factory.Builder()
                .setSdrWorkingColorSpace(DefaultVideoFrameProcessor.WORKING_COLOR_SPACE_ORIGINAL)
                .build()
            val transformer = Transformer.Builder(this.context)
                .setVideoMimeType(MimeTypes.VIDEO_H264)
                .setAudioMimeType(MimeTypes.AUDIO_AAC)
                .setVideoFrameProcessorFactory(videoFrameProcessorFactory)
                .addListener(object : Transformer.Listener {
                    override fun onCompleted(composition: Composition, exportResult: ExportResult) {
                        completion.completed()
                    }

                    override fun onError(composition: Composition, exportResult: ExportResult, exportException: ExportException) {
                        completion.failed()
                    }
                }).build()
            val effect = SingleColorLut.createFromCube(lut.toArgbCube())
            val item = EditedMediaItem.Builder(MediaItem.fromUri(Uri.fromFile(source.toFile())))
                .setEffects(Effects(emptyList(), listOf(effect)))
                .build()
            object : MonitorMovieCodec {
                private val progress = ProgressHolder()
                override fun start() { transformer.start(item, target.toString()) }
                override fun progressPercent(): Int? =
                    if (transformer.getProgress(progress) == Transformer.PROGRESS_STATE_AVAILABLE) progress.progress else null
                override fun cancel() { transformer.cancel() }
            }
        },
        errors = frameioMovieExportErrors,
        mainDispatcher = mainDispatcher,
    )

    override suspend fun export(source: Path, target: Path, lut: MonitorMovieExportLut, onProgress: suspend (Double) -> Unit) =
        owner.export(source, target, lut, onProgress)
}

/** Composition supplies the approved LUT, branded filename and existing operator errors. */
internal class AndroidFrameioArtifactPreparer(
    exportRoot: Path,
    private val lutProvider: FrameioLutProvider,
    exporter: FrameioLutVideoExporter,
    deleteExport: (Path) -> Boolean = Files::deleteIfExists,
) : FrameioArtifactPreparer {
    private val owner = MonitorMovieExportPreparer(
        exportRoot = exportRoot,
        exporter = object : MonitorLutMovieExporter {
            override suspend fun export(source: Path, target: Path, lut: MonitorMovieExportLut, onProgress: suspend (Double) -> Unit) =
                exporter.export(source, target, lut, onProgress)
        },
        errors = frameioMovieExportErrors,
        ownedFilenamePrefix = "frameio",
        fallbackFilename = "OpenZCine",
        deleteExport = deleteExport,
    )

    override suspend fun prepare(
        artifact: FrameioDeliveryArtifact,
        options: MediaDeliveryConfiguration,
        onProgress: suspend (Double) -> Unit,
    ): FrameioPreparedArtifact {
        val prepared = owner.prepare(
            input = MonitorMovieExportInput(artifact.share.file, artifact.share.displayName, artifact.share.mimeType, artifact.byteCount, artifact.context.supportsLutBake),
            bakeLut = options.bakeLut,
            container = options.exportContainer,
            approvedLut = { lutProvider.approvedPayload(requireNotNull(options.selectedLut)) },
            onProgress = onProgress,
        )
        val share = if (prepared.transientExport == null) artifact.share else
            StagedMediaShare(prepared.file, prepared.displayName, prepared.mimeType)
        return FrameioPreparedArtifact(share, prepared.byteCount, prepared.appliedLutName, prepared.transientExport)
    }

    override suspend fun release(prepared: FrameioPreparedArtifact) = owner.release(
        MonitorPreparedMovieExport(prepared.share.file, prepared.share.displayName, prepared.share.mimeType, prepared.byteCount, prepared.appliedLutName, prepared.transientExport),
    )
}

private val frameioMovieExportErrors = MonitorMovieExportErrorFactory { reason, filename ->
    FrameioDeliveryException(when (reason) {
        MonitorMovieExportFailure.UNSUPPORTED_BAKE -> "$filename isn't a video proxy that can receive a baked LUT."
        MonitorMovieExportFailure.APPROVED_LUT_UNAVAILABLE -> "The selected LUT is no longer approved for export. Re-select or re-import it and try again."
        MonitorMovieExportFailure.INCOMPLETE_EXPORT -> "The LUT-baked export did not produce a complete video."
        MonitorMovieExportFailure.INVALID_MOV_FILE -> "The LUT-baked MOV export is not a complete regular file."
        MonitorMovieExportFailure.INCOMPLETE_MOV_HEADER -> "The LUT-baked MOV export has an incomplete media header."
        MonitorMovieExportFailure.UNSUPPORTED_MOV_HEADER -> "The LUT-baked MOV export has an unsupported media header."
        MonitorMovieExportFailure.CODEC_FAILED -> "OpenZCine couldn't bake the selected LUT for this clip. " +
            "The source may use a codec or HDR mode this device cannot export safely."
        MonitorMovieExportFailure.CODEC_STALLED -> "OpenZCine stopped the LUT export because this device's media encoder stopped making progress."
        MonitorMovieExportFailure.INCOMPLETE_CLEANUP -> "OpenZCine couldn't remove the incomplete Frame.io export."
        MonitorMovieExportFailure.TEMPORARY_CLEANUP -> "OpenZCine couldn't remove the temporary Frame.io export."
    })
}

/** Writes a local sidecar only after Frame.io confirms the upload. */
internal interface FrameioMetadataSidecarWriter {
    suspend fun recordSuccessfulDelivery(
        artifact: FrameioDeliveryArtifact,
        prepared: FrameioPreparedArtifact,
        destination: FrameioDestination,
        options: MediaDeliveryConfiguration,
    )
}

internal object NoFrameioMetadataSidecarWriter : FrameioMetadataSidecarWriter {
    override suspend fun recordSuccessfulDelivery(
        artifact: FrameioDeliveryArtifact,
        prepared: FrameioPreparedArtifact,
        destination: FrameioDestination,
        options: MediaDeliveryConfiguration,
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
        options: MediaDeliveryConfiguration,
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

@file:androidx.media3.common.util.UnstableApi

package com.opencapture.openzcine.frameio

import android.content.Context
import android.net.Uri
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
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
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.StandardCopyOption
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

/** Per-run choices that are applied only to this Frame.io delivery. */
internal data class FrameioDeliveryOptions(
    val bakeLut: Boolean = false,
    val includeMetadata: Boolean = false,
    val selectedLut: FeedLutSelection? = null,
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
        val transformer =
            Transformer.Builder(context)
                .setVideoMimeType(MimeTypes.VIDEO_H264)
                .setAudioMimeType(MimeTypes.AUDIO_AAC)
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
            val progressJob =
                launch {
                    val holder = ProgressHolder()
                    while (isActive && !completion.isCompleted) {
                        if (transformer.getProgress(holder) == Transformer.PROGRESS_STATE_AVAILABLE) {
                            onProgress((holder.progress / 100.0).coerceIn(0.0, 1.0))
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
    }
}

/** Production preparer for optional, per-delivery LUT-baked MP4 output. */
internal class AndroidFrameioArtifactPreparer(
    private val exportRoot: Path,
    private val lutProvider: FrameioLutProvider,
    private val exporter: FrameioLutVideoExporter,
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
        withContext(Dispatchers.IO) { Files.createDirectories(exportRoot) }
        val target = exportRoot.resolve("frameio-${UUID.randomUUID()}.mp4")
        try {
            exporter.export(artifact.share.file, target, lut, onProgress)
            val byteCount =
                withContext(Dispatchers.IO) {
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
                        displayName = bakedFilename(artifact.share.displayName),
                        mimeType = "video/mp4",
                    ),
                byteCount = byteCount,
                appliedLutName = lut.displayName,
                transientExport = target,
            )
        } catch (error: Exception) {
            withContext(NonCancellable + Dispatchers.IO) { Files.deleteIfExists(target) }
            throw error
        }
    }

    override suspend fun release(prepared: FrameioPreparedArtifact) {
        withContext(NonCancellable + Dispatchers.IO) {
            prepared.transientExport?.let { path -> runCatching { Files.deleteIfExists(path) } }
        }
    }

    private fun bakedFilename(original: String): String =
        original.substringBeforeLast('.', missingDelimiterValue = original).ifBlank { "OpenZCine" } + ".mp4"
}

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
                        sizeBytes = artifact.byteCount,
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

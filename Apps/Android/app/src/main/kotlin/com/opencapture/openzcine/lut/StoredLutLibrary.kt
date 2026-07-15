package com.opencapture.openzcine.lut

import android.content.ContentResolver
import android.content.Context
import android.database.Cursor
import android.net.Uri
import android.provider.OpenableColumns
import androidx.compose.runtime.Stable
import com.opencapture.openzcine.FeedLut
import com.opencapture.openzcine.FeedLutSelection
import com.opencapture.openzcine.bridge.SwiftCore
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.IOException
import java.text.Normalizer
import java.util.UUID
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.withContext

private const val LUT_READ_BUFFER_BYTES = 8 * 1024

/** Must remain equal to the Android Swift facade's `LUTLibraryWire.maximumSourceBytes`. */
private const val SHARED_LUT_SOURCE_LIMIT_BYTES = 16 * 1024 * 1024

/** App-private categories that map exactly onto the shared Swift `LUTCategory` cases. */
enum class StoredLutCategory(
    internal val wireOrdinal: Int,
    val label: String,
) {
    CUSTOM(0, "Custom"),
    RED(1, "RED"),
}

/**
 * A persisted selection of an app-private cube. This is intentionally only a category plus a
 * generated safe file name — never an external document URI, display path, or provider ID.
 */
class StoredLutSelection private constructor(
    val category: StoredLutCategory,
    val fileName: String,
) {
    override fun equals(other: Any?): Boolean =
        other is StoredLutSelection && category == other.category && fileName == other.fileName

    override fun hashCode(): Int = 31 * category.hashCode() + fileName.hashCode()

    override fun toString(): String = "StoredLutSelection(category=$category, fileName=$fileName)"

    companion object {
        /** Decodes a persisted selection only when its generated name remains path-safe. */
        fun fromPersisted(category: String?, fileName: String?): StoredLutSelection? {
            val parsedCategory = StoredLutCategory.entries.firstOrNull { it.name == category }
            return if (parsedCategory != null && isSafeStoredFileName(fileName)) {
                StoredLutSelection(parsedCategory, requireNotNull(fileName))
            } else {
                null
            }
        }

        internal fun generated(category: StoredLutCategory, fileName: String): StoredLutSelection {
            require(isSafeStoredFileName(fileName)) { "Generated LUT file name must be safe." }
            return StoredLutSelection(category, fileName)
        }

        internal fun isSafeStoredFileName(fileName: String?): Boolean {
            if (fileName == null || fileName.length !in 6..128) return false
            if (!fileName.endsWith(".cube", ignoreCase = true)) return false
            if (fileName.startsWith('.') || ".." in fileName) return false
            return fileName.all { character ->
                character.isAsciiLetterOrDigit() || character == '-' || character == '_' || character == '.'
            }
        }

        private fun Char.isAsciiLetterOrDigit(): Boolean =
            this in 'a'..'z' || this in 'A'..'Z' || this in '0'..'9'
    }
}

/** A listed app-private LUT plus the Swift-validated metadata available so far. */
data class StoredLutEntry(
    val selection: StoredLutSelection,
    val displayName: String,
    val cubeSize: Int? = null,
    val canonicalCacheKey: String? = null,
)

/**
 * Same-category replacement order after deleting an active stored LUT. The
 * library's entry order is already deterministic and built-in looks cannot
 * enter this typed candidate set.
 */
internal fun storedLutReplacementCandidates(
    entries: List<StoredLutEntry>,
    deleted: StoredLutSelection,
): List<StoredLutEntry> =
    entries.filter { entry ->
        entry.selection != deleted && entry.selection.category == deleted.category
    }

/**
 * Reconciles only the deleted active stored selection. Inactive selections,
 * including protected built-ins, are returned unchanged; a validated
 * same-category replacement wins before the built-in fallback.
 */
internal fun reconciledLutSelectionAfterDeletion(
    current: FeedLutSelection,
    deleted: StoredLutSelection,
    preparedReplacement: StoredLutSelection?,
): FeedLutSelection {
    if (current != FeedLutSelection.Stored(deleted)) return current
    return preparedReplacement?.let(FeedLutSelection::Stored)
        ?: FeedLutSelection.BuiltIn(FeedLut.LOG3G10_709)
}

/** A Swift-packed cube ready for the existing Android feed-effects renderer. */
data class PackedStoredLut(
    val cubeSize: Int,
    val rgba: ByteArray,
)

/** Exact outcome from a selected custom-document import. */
sealed interface CustomLutImportResult {
    data class Imported(val entry: StoredLutEntry) : CustomLutImportResult

    data class Rejected(val message: String) : CustomLutImportResult
}

/** Why an existing app-private LUT cannot currently be selected/rendered. */
sealed interface StoredLutFailure {
    data object Missing : StoredLutFailure

    data object TooLarge : StoredLutFailure

    data object InvalidOrCorrupt : StoredLutFailure

    data object SwiftCoreUnavailable : StoredLutFailure

    data object ReadFailed : StoredLutFailure

    val operatorMessage: String
        get() =
            when (this) {
                Missing -> "This LUT is no longer in the app library. Remove it or choose another look."
                TooLarge -> "This LUT exceeds the 16 MB import limit. Remove it or import a smaller .cube."
                InvalidOrCorrupt -> "This LUT can no longer be validated. Remove it or import the original again."
                SwiftCoreUnavailable -> "The shared LUT engine is unavailable in this build."
                ReadFailed -> "OpenZCine could not read this app-private LUT. Remove it or import it again."
            }
}

/** Parsed result of the versioned Swift validation record. */
internal data class ValidatedLut(
    val cubeSize: Int,
    val canonicalCacheKey: String,
) {
    companion object {
        private const val RECORD_VERSION = "1"
        private const val SEPARATOR = "\u001F"

        fun parse(record: String?): ValidatedLut? {
            val fields = record?.split(SEPARATOR) ?: return null
            if (fields.size != 3 || fields[0] != RECORD_VERSION) return null
            val cubeSize = fields[1].toIntOrNull()?.takeIf { it in 2..64 } ?: return null
            if (fields[1] != cubeSize.toString()) return null
            val cacheKey = fields[2].takeIf { it.isNotBlank() && it.length <= 256 } ?: return null
            return ValidatedLut(cubeSize, cacheKey)
        }
    }
}

/**
 * Narrow test seam over the Swift-owned parser/selection/render path. It carries bytes and typed
 * metadata only; implementations must not duplicate `.cube` parsing or colour math in Kotlin.
 */
internal interface LutCoreBridge {
    /** Whether the shared Swift library loaded for this process. */
    val isAvailable: Boolean

    fun validate(
        utf8: ByteArray,
        category: StoredLutCategory,
        fileName: String,
    ): ValidatedLut?

    fun packedCube(utf8: ByteArray): ByteArray?

    fun redDownloadAvailability(hasInternetPath: Boolean, isOnCameraAccessPoint: Boolean): String?
}

internal object SwiftLutCoreBridge : LutCoreBridge {
    @Volatile
    private var requiredSymbolsAvailable = true

    override val isAvailable: Boolean
        get() = requiredSymbolsAvailable && SwiftCore.isAvailable

    override fun validate(
        utf8: ByteArray,
        category: StoredLutCategory,
        fileName: String,
    ): ValidatedLut? =
        if (isAvailable) {
            coreCall {
                ValidatedLut.parse(
                    SwiftCore.validateImportedLut(utf8, category.wireOrdinal, fileName),
                )
            }
        } else {
            null
        }

    override fun packedCube(utf8: ByteArray): ByteArray? =
        if (isAvailable) coreCall { SwiftCore.packImportedLut(utf8) } else null

    override fun redDownloadAvailability(
        hasInternetPath: Boolean,
        isOnCameraAccessPoint: Boolean,
    ): String? =
        if (isAvailable) {
            coreCall { SwiftCore.redLutDownloadAvailability(hasInternetPath, isOnCameraAccessPoint) }
        } else {
            null
        }

    private fun <T> coreCall(block: () -> T): T? =
        try {
            block()
        } catch (_: UnsatisfiedLinkError) {
            // A stale or incorrectly staged native library must behave as unavailable, not crash a
            // settings/import flow or make Kotlin attempt a parser/render fallback.
            requiredSymbolsAvailable = false
            null
        }
}

/**
 * App-private, bounded LUT file store. It accepts only byte payloads already selected by the
 * operator through SAF, validates them in the Swift core *before* an atomic local copy, and keeps
 * only generated safe names. The store never scans shared storage or persists a content URI.
 */
@Stable
internal class StoredLutLibrary(
    private val root: File,
    private val core: LutCoreBridge,
) {
    private val lock = Any()
    private val packed = mutableMapOf<StoredLutSelection, PackedStoredLut>()
    private val _entries = MutableStateFlow(scanEntries())
    private val _failures = MutableStateFlow<Map<StoredLutSelection, StoredLutFailure>>(emptyMap())
    private val _renderGeneration = MutableStateFlow(0L)

    val entries: StateFlow<List<StoredLutEntry>> = _entries.asStateFlow()
    val failures: StateFlow<Map<StoredLutSelection, StoredLutFailure>> = _failures.asStateFlow()
    val renderGeneration: StateFlow<Long> = _renderGeneration.asStateFlow()

    /** Whether a safe, app-private file exists for a persisted selection. */
    fun contains(selection: StoredLutSelection): Boolean = fileFor(selection)?.isFile == true

    /** Current entries for one category, sorted by their generated display label. */
    fun entries(category: StoredLutCategory): List<StoredLutEntry> =
        entries.value.filter { it.selection.category == category }

    /** Returns only a cache populated by [prepare]; never blocks the draw thread on file I/O. */
    fun packedCube(selection: StoredLutSelection): PackedStoredLut? = synchronized(lock) {
        packed[selection]
    }

    /** Imports a custom LUT after the Android shell has read a selected document into bounded bytes. */
    suspend fun importCustom(utf8: ByteArray, displayHint: String?): CustomLutImportResult =
        withContext(Dispatchers.IO) {
            if (utf8.size > SHARED_LUT_SOURCE_LIMIT_BYTES) {
                return@withContext CustomLutImportResult.Rejected(
                    "This .cube is larger than the 16 MB import limit.",
                )
            }
            if (!core.isAvailable) {
                return@withContext CustomLutImportResult.Rejected(
                    "The shared LUT engine is unavailable in this build.",
                )
            }
            val selection =
                StoredLutSelection.generated(
                    category = StoredLutCategory.CUSTOM,
                    fileName = generatedFileName(displayHint),
                )
            val validation = core.validate(utf8, selection.category, selection.fileName)
                ?: return@withContext CustomLutImportResult.Rejected(
                    "OpenZCine could not validate that document as a supported .cube LUT.",
                )
            val packedCube = core.packedCube(utf8)
                ?: return@withContext CustomLutImportResult.Rejected(
                    "OpenZCine could not prepare that .cube for monitoring.",
                )
            if (!isExpectedPackedSize(packedCube, validation.cubeSize)) {
                return@withContext CustomLutImportResult.Rejected(
                    "OpenZCine received an invalid LUT render payload.",
                )
            }
            try {
                writeAtomically(selection, utf8)
            } catch (_: IOException) {
                return@withContext CustomLutImportResult.Rejected(
                    "OpenZCine could not save that LUT in its private library.",
                )
            } catch (_: SecurityException) {
                return@withContext CustomLutImportResult.Rejected(
                    "OpenZCine could not save that LUT in its private library.",
                )
            }
            val entry = StoredLutEntry(
                selection = selection,
                displayName = displayNameFor(selection.fileName),
                cubeSize = validation.cubeSize,
                canonicalCacheKey = validation.canonicalCacheKey,
            )
            synchronized(lock) {
                packed[selection] = PackedStoredLut(validation.cubeSize, packedCube)
                _entries.value = (_entries.value.filterNot { it.selection == selection } + entry).sortedBy {
                    it.displayName.lowercase()
                }
                _failures.value = _failures.value - selection
                _renderGeneration.value += 1
            }
            CustomLutImportResult.Imported(entry)
        }

    /**
     * Re-validates and prepares a stored selection off the UI/render thread. A corrupt file is
     * kept visible for explicit operator removal, but it has no packed payload and is never applied.
     */
    suspend fun prepare(selection: StoredLutSelection): Boolean = withContext(Dispatchers.IO) {
        val file = fileFor(selection)
            ?: return@withContext recordFailure(selection, StoredLutFailure.Missing)
        if (!file.isFile) return@withContext recordFailure(selection, StoredLutFailure.Missing)
        if (file.length() > SHARED_LUT_SOURCE_LIMIT_BYTES) {
            return@withContext recordFailure(selection, StoredLutFailure.TooLarge)
        }
        val utf8 =
            try {
                readBoundedLut(FileInputStream(file))
            } catch (_: IOException) {
                return@withContext recordFailure(selection, StoredLutFailure.ReadFailed)
            }
        val validation = core.validate(utf8, selection.category, selection.fileName)
            ?: return@withContext recordFailure(
                selection,
                if (core.isAvailable) StoredLutFailure.InvalidOrCorrupt
                else StoredLutFailure.SwiftCoreUnavailable,
            )
        val packedCube = core.packedCube(utf8)
            ?: return@withContext recordFailure(selection, StoredLutFailure.InvalidOrCorrupt)
        if (!isExpectedPackedSize(packedCube, validation.cubeSize)) {
            return@withContext recordFailure(selection, StoredLutFailure.InvalidOrCorrupt)
        }
        synchronized(lock) {
            packed[selection] = PackedStoredLut(validation.cubeSize, packedCube)
            _entries.value = _entries.value.map { entry ->
                if (entry.selection == selection) {
                    entry.copy(
                        cubeSize = validation.cubeSize,
                        canonicalCacheKey = validation.canonicalCacheKey,
                    )
                } else {
                    entry
                }
            }
            _failures.value = _failures.value - selection
            _renderGeneration.value += 1
        }
        true
    }

    /** Deletes only the app-private generated file and clears any selected render payload. */
    suspend fun delete(selection: StoredLutSelection): Boolean = withContext(Dispatchers.IO) {
        val file = fileFor(selection) ?: return@withContext false
        val removed = !file.exists() || file.delete()
        if (removed) {
            synchronized(lock) {
                packed.remove(selection)
                _entries.value = _entries.value.filterNot { it.selection == selection }
                _failures.value = _failures.value - selection
                _renderGeneration.value += 1
            }
        }
        removed
    }

    /** Returns the first same-category replacement that still validates and prepares successfully. */
    suspend fun firstPreparedReplacement(deleted: StoredLutSelection): StoredLutSelection? {
        for (entry in storedLutReplacementCandidates(entries.value, deleted)) {
            if (prepare(entry.selection)) return entry.selection
        }
        return null
    }

    private fun recordFailure(selection: StoredLutSelection, failure: StoredLutFailure): Boolean {
        synchronized(lock) {
            packed.remove(selection)
            _failures.value = _failures.value + (selection to failure)
            _renderGeneration.value += 1
        }
        return false
    }

    private fun scanEntries(): List<StoredLutEntry> =
        StoredLutCategory.entries.flatMap { category ->
            categoryDirectory(category).listFiles()
                .orEmpty()
                .asSequence()
                .filter(File::isFile)
                .mapNotNull { file ->
                    StoredLutSelection.fromPersisted(category.name, file.name)?.let { selection ->
                        StoredLutEntry(selection, displayNameFor(selection.fileName))
                    }
                }
                .toList()
        }.sortedBy { it.displayName.lowercase() }

    private fun fileFor(selection: StoredLutSelection): File? {
        if (!StoredLutSelection.isSafeStoredFileName(selection.fileName)) return null
        val directory = categoryDirectory(selection.category)
        val candidate = File(directory, selection.fileName)
        return if (candidate.parentFile == directory) candidate else null
    }

    private fun categoryDirectory(category: StoredLutCategory): File =
        File(root, category.name.lowercase())

    @Throws(IOException::class)
    private fun writeAtomically(selection: StoredLutSelection, utf8: ByteArray) {
        val destination = requireNotNull(fileFor(selection))
        val directory = requireNotNull(destination.parentFile)
        if (!directory.exists() && !directory.mkdirs()) {
            throw IOException("Could not create LUT library directory.")
        }
        val temporary = File.createTempFile("import-", ".tmp", directory)
        try {
            FileOutputStream(temporary).use { output ->
                output.write(utf8)
                output.fd.sync()
            }
            if (!temporary.renameTo(destination)) {
                throw IOException("Could not atomically store LUT.")
            }
        } finally {
            if (temporary.exists()) temporary.delete()
        }
    }

    private fun generatedFileName(displayHint: String?): String {
        val stem = displayHint.safeFileStem()
        val nonce = UUID.randomUUID().toString().replace("-", "").take(12)
        return "$stem-$nonce.cube"
    }

    private fun String?.safeFileStem(): String {
        val raw = this.orEmpty().substringBeforeLast('.', missingDelimiterValue = this.orEmpty())
        val ascii = Normalizer.normalize(raw, Normalizer.Form.NFD)
            .lowercase()
            .map { character -> if (character in 'a'..'z' || character in '0'..'9') character else '-' }
            .joinToString("")
            .replace(Regex("-+"), "-")
            .trim('-')
        return ascii.take(40).ifBlank { "custom-lut" }
    }

    private fun displayNameFor(fileName: String): String =
        fileName.removeSuffix(".cube")
            .replace(Regex("-[0-9a-f]{12}$"), "")
            .replace('-', ' ')
            .ifBlank { "Custom LUT" }

    private fun isExpectedPackedSize(rgba: ByteArray, cubeSize: Int): Boolean =
        rgba.size == cubeSize * cubeSize * cubeSize * 4

}

/** Android-facing façade that reads one SAF document transiently, then delegates to the safe store. */
@Stable
class AndroidLutLibrary private constructor(
    private val context: Context,
    private val store: StoredLutLibrary,
) {
    /** Production library rooted in no-backup app storage; no external provider state is retained. */
    constructor(context: Context) : this(
        context.applicationContext,
        StoredLutLibrary(
            File(context.applicationContext.noBackupFilesDir, "lut-library-v1"),
            SwiftLutCoreBridge,
        ),
    )

    /** Test-only/integration seam; production callers use [AndroidLutLibrary]([Context]). */
    internal constructor(context: Context, core: LutCoreBridge) : this(
        context.applicationContext,
        StoredLutLibrary(File(context.applicationContext.noBackupFilesDir, "lut-library-v1"), core),
    )

    val entries: StateFlow<List<StoredLutEntry>> = store.entries
    val failures: StateFlow<Map<StoredLutSelection, StoredLutFailure>> = store.failures
    val renderGeneration: StateFlow<Long> = store.renderGeneration

    fun contains(selection: StoredLutSelection): Boolean = store.contains(selection)

    fun entries(category: StoredLutCategory): List<StoredLutEntry> = store.entries(category)

    fun packedCube(selection: StoredLutSelection): PackedStoredLut? = store.packedCube(selection)

    /** Operator-facing label for one app-private selection, when it is still in the library. */
    fun displayName(selection: StoredLutSelection): String? =
        store.entries.value.firstOrNull { entry -> entry.selection == selection }?.displayName

    /**
     * Reads the single document URI selected through `ACTION_OPEN_DOCUMENT` into a bounded buffer.
     * The URI is deliberately not persisted or copied into metadata; after this call only a new
     * generated app-private file can remain.
     */
    suspend fun importFromDocument(uri: Uri): CustomLutImportResult = withContext(Dispatchers.IO) {
        val bytes =
            try {
                readSelectedDocument(uri)
            } catch (_: IOException) {
                return@withContext CustomLutImportResult.Rejected(
                    "OpenZCine could not read that selected document.",
                )
            } catch (_: SecurityException) {
                return@withContext CustomLutImportResult.Rejected(
                    "OpenZCine no longer has permission to read that selected document.",
                )
            }
        store.importCustom(bytes, displayNameFor(uri))
    }

    suspend fun prepare(selection: StoredLutSelection): Boolean = store.prepare(selection)

    suspend fun delete(selection: StoredLutSelection): Boolean = store.delete(selection)

    /** Finds a validated same-category successor after an active stored selection is deleted. */
    suspend fun firstPreparedReplacement(deleted: StoredLutSelection): StoredLutSelection? =
        store.firstPreparedReplacement(deleted)

    private fun readSelectedDocument(uri: Uri): ByteArray {
        val resolver = context.contentResolver
        val input = resolver.openInputStream(uri) ?: throw IOException("No input stream for selected document.")
        return readBoundedLut(input)
    }

    private fun displayNameFor(uri: Uri): String? =
        try {
            queryDisplayName(context.contentResolver, uri)
        } catch (_: SecurityException) {
            null
        }

}

/** Reads and closes one LUT stream without ever retaining more than the shared parser limit. */
@Throws(IOException::class)
private fun readBoundedLut(input: java.io.InputStream): ByteArray = input.use { stream ->
    val output = ByteArrayOutputStream()
    val buffer = ByteArray(LUT_READ_BUFFER_BYTES)
    var total = 0
    while (true) {
        val read = stream.read(buffer)
        if (read < 0) break
        total += read
        if (total > SHARED_LUT_SOURCE_LIMIT_BYTES) throw IOException("LUT source too large.")
        output.write(buffer, 0, read)
    }
    output.toByteArray()
}

private fun queryDisplayName(resolver: ContentResolver, uri: Uri): String? {
    val cursor: Cursor =
        resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null) ?: return null
    cursor.use {
        val index = it.getColumnIndex(OpenableColumns.DISPLAY_NAME)
        return if (index >= 0 && it.moveToFirst()) it.getString(index) else null
    }
}

package com.opencapture.openzcine.lut

import android.content.Context
import com.opencapture.opencine.cameracontrols.MonitorLutCategory
import com.opencapture.opencine.cameracontrols.MonitorLutEntry
import com.opencapture.opencine.cameracontrols.MonitorLutImportResult
import com.opencapture.opencine.cameracontrols.MonitorLutLibrary
import com.opencapture.opencine.cameracontrols.MonitorLutSelection
import com.opencapture.opencine.cameracontrols.MonitorPackedLut
import com.opencapture.opencine.vocabulary.LutCatalog
import com.opencapture.openzcine.FeedLut
import com.opencapture.openzcine.FeedLutSelection
import com.opencapture.openzcine.bridge.SwiftCore
import java.io.File

// ponytail: OpenZCine's names for the Core LUT library types (A4-27), kept so the delivery and
// media call sites stay untouched; inline them once those lanes land.
typealias AndroidLutLibrary = MonitorLutLibrary
typealias StoredLutSelection = MonitorLutSelection
typealias StoredLutEntry = MonitorLutEntry
typealias PackedStoredLut = MonitorPackedLut

/** The library's categories here: the operator's cubes plus the RED download source. */
object StoredLutCategory {
    val CUSTOM: MonitorLutCategory = MonitorLutCategory.CUSTOM
    val RED: MonitorLutCategory = MonitorLutCategory("RED")
    internal val all = listOf(CUSTOM, RED)
}

/**
 * The app's LUT library in no-backup storage. The Swift facade's `packImportedLut` runs the
 * shared `CubeLUT.validatedImport` gate and packs the renderer-safe table; a missing or stale
 * native library packs nothing, so nothing is stored or applied.
 */
fun AndroidLutLibrary(context: Context): AndroidLutLibrary {
    val root = File(context.applicationContext.noBackupFilesDir, "lut-library-v1")
    return MonitorLutLibrary(
        StoredLutCategory.all.associateWith { File(root, it.name.lowercase()) },
        pack = { bytes -> swiftCall { SwiftCore.packImportedLut(bytes) } },
        displayName = ::storedLutDisplayName,
    )
}

/** Decodes a persisted selection only for a known category and a path-safe name. */
fun MonitorLutSelection.Companion.fromPersisted(category: String?, fileName: String?): StoredLutSelection? =
    StoredLutCategory.all.firstOrNull { it.name == category }?.let { of(it, fileName) }

/** Imports a RED cube (zip member or lone download) into the RED category; null when refused. */
suspend fun AndroidLutLibrary.importRedCubeFile(file: File): StoredLutEntry? =
    (importFile(StoredLutCategory.RED, file) as? MonitorLutImportResult.Imported)?.entry

/**
 * Earlier builds stored generated `stem-<12 hex>.cube` names; they still read as the operator's
 * words. Newer imports keep the operator's file name (the shared custom LUT rule).
 */
internal fun storedLutDisplayName(fileName: String): String =
    LEGACY_NAME.matchEntire(fileName)?.let { it.groupValues[1].replace('-', ' ') } ?: LutCatalog.displayName(fileName)

private val LEGACY_NAME = Regex("""([a-z0-9-]+)-[0-9a-f]{12}\.cube""")

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

/** The shared `RedLUTDownloadPolicy` record for the RED download gate; null when Swift is unavailable. */
internal fun swiftRedDownloadAvailability(hasInternetPath: Boolean, isOnCameraAccessPoint: Boolean): String? =
    swiftCall { SwiftCore.redLutDownloadAvailability(hasInternetPath, isOnCameraAccessPoint) }

@Volatile
private var swiftSymbolsAvailable = true

private fun <T> swiftCall(block: () -> T?): T? {
    if (!swiftSymbolsAvailable || !SwiftCore.isAvailable) return null
    return try {
        block()
    } catch (_: UnsatisfiedLinkError) {
        // A stale or incorrectly staged native library behaves as unavailable, never as a crash or
        // a Kotlin parser fallback.
        swiftSymbolsAvailable = false
        null
    }
}

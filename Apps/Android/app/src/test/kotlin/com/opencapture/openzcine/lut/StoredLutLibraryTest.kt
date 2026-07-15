package com.opencapture.openzcine.lut

import com.opencapture.openzcine.FeedLut
import com.opencapture.openzcine.FeedLutSelection
import java.io.File
import kotlin.io.path.createTempDirectory
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlinx.coroutines.test.runTest

class StoredLutLibraryTest {
    @Test
    fun `custom import validates before atomic app private copy and survives a restart`() = runTest {
        val root = createTempDirectory("openzcine-lut-library").toFile()
        val core = FakeLutCore()
        val library = StoredLutLibrary(root, core)

        val result = library.importCustom(byteArrayOf(1, 2, 3), "../../Operator Look.cube")
        val imported = assertIs<CustomLutImportResult.Imported>(result).entry

        assertEquals(StoredLutCategory.CUSTOM, imported.selection.category)
        assertTrue(StoredLutSelection.isSafeStoredFileName(imported.selection.fileName))
        assertFalse(imported.selection.fileName.contains("/"))
        assertFalse(imported.selection.fileName.contains("Operator Look"))
        assertTrue(File(root, "custom/${imported.selection.fileName}").isFile)
        assertNotNull(library.packedCube(imported.selection))
        assertEquals("stored:Custom:${imported.selection.fileName}", imported.canonicalCacheKey)

        val reloaded = StoredLutLibrary(root, core)
        assertTrue(reloaded.contains(imported.selection))
        assertTrue(reloaded.prepare(imported.selection))
        assertNotNull(reloaded.packedCube(imported.selection))
    }

    @Test
    fun `invalid payload never reaches storage and corrupt app private payload reports a failure`() = runTest {
        val root = createTempDirectory("openzcine-lut-library").toFile()
        val core = FakeLutCore(valid = false)
        val library = StoredLutLibrary(root, core)

        val rejected = library.importCustom(byteArrayOf(7), "look.cube")

        assertIs<CustomLutImportResult.Rejected>(rejected)
        assertTrue(root.listFiles().isNullOrEmpty())

        core.valid = true
        val imported =
            assertIs<CustomLutImportResult.Imported>(
                library.importCustom(byteArrayOf(7), "look.cube"),
            ).entry
        core.valid = false

        assertFalse(library.prepare(imported.selection))
        assertEquals(StoredLutFailure.InvalidOrCorrupt, library.failures.value[imported.selection])
        assertNull(library.packedCube(imported.selection))
    }

    @Test
    fun `deletion removes only generated private state`() = runTest {
        val root = createTempDirectory("openzcine-lut-library").toFile()
        val library = StoredLutLibrary(root, FakeLutCore())
        val imported =
            assertIs<CustomLutImportResult.Imported>(
                library.importCustom(byteArrayOf(3), "on-set.cube"),
            ).entry

        assertTrue(library.delete(imported.selection))
        assertFalse(library.contains(imported.selection))
        assertTrue(library.entries.value.isEmpty())
        assertNull(library.packedCube(imported.selection))
    }

    @Test
    fun `active deletion replacement stays in category and skips invalid stored LUTs`() = runTest {
        val root = createTempDirectory("openzcine-lut-replacement").toFile()
        val library = StoredLutLibrary(root, FakeLutCore())
        val alpha =
            assertIs<CustomLutImportResult.Imported>(
                library.importCustom(byteArrayOf(1), "alpha.cube"),
            ).entry
        val bravo =
            assertIs<CustomLutImportResult.Imported>(
                library.importCustom(byteArrayOf(2), "bravo.cube"),
            ).entry
        val active =
            assertIs<CustomLutImportResult.Imported>(
                library.importCustom(byteArrayOf(3), "active.cube"),
            ).entry
        File(root, "custom/${alpha.selection.fileName}").writeBytes(byteArrayOf())

        assertTrue(library.delete(active.selection))

        assertEquals(bravo.selection, library.firstPreparedReplacement(active.selection))
        assertEquals(
            StoredLutFailure.InvalidOrCorrupt,
            library.failures.value[alpha.selection],
        )
    }

    @Test
    fun `replacement candidates exclude deleted and other categories`() {
        val deleted = StoredLutSelection.generated(StoredLutCategory.RED, "deleted-000000000001.cube")
        val red = StoredLutSelection.generated(StoredLutCategory.RED, "red-000000000002.cube")
        val custom = StoredLutSelection.generated(StoredLutCategory.CUSTOM, "custom-000000000003.cube")
        val entries =
            listOf(
                StoredLutEntry(deleted, "Deleted"),
                StoredLutEntry(red, "RED replacement"),
                StoredLutEntry(custom, "Custom replacement"),
            )

        assertEquals(
            listOf(red),
            storedLutReplacementCandidates(entries, deleted).map(StoredLutEntry::selection),
        )
        assertTrue(storedLutReplacementCandidates(listOf(entries.first()), deleted).isEmpty())
    }

    @Test
    fun `active stored selection prefers prepared replacement then protected built in`() {
        val deleted = StoredLutSelection.generated(StoredLutCategory.RED, "deleted-000000000001.cube")
        val replacement = StoredLutSelection.generated(StoredLutCategory.RED, "red-000000000002.cube")
        val active = FeedLutSelection.Stored(deleted)

        assertEquals(
            FeedLutSelection.Stored(replacement),
            reconciledLutSelectionAfterDeletion(active, deleted, replacement),
        )
        assertEquals(
            FeedLutSelection.BuiltIn(FeedLut.LOG3G10_709),
            reconciledLutSelectionAfterDeletion(active, deleted, null),
        )

        val protectedBuiltIn = FeedLutSelection.BuiltIn(FeedLut.MONO)
        assertEquals(
            protectedBuiltIn,
            reconciledLutSelectionAfterDeletion(protectedBuiltIn, deleted, replacement),
        )
    }

    @Test
    fun `unavailable shared core rejects an import before any private file is created`() = runTest {
        val root = createTempDirectory("openzcine-lut-library").toFile()
        val core = FakeLutCore(available = false)
        val library = StoredLutLibrary(root, core)

        val result = library.importCustom(byteArrayOf(3), "on-set.cube")

        assertIs<CustomLutImportResult.Rejected>(result)
        assertTrue(root.listFiles().isNullOrEmpty())
    }

    @Test
    fun `malformed packed payload is rejected before an import reaches private storage`() = runTest {
        val root = createTempDirectory("openzcine-lut-library").toFile()
        val library = StoredLutLibrary(root, FakeLutCore(packedByteCount = 1))

        val result = library.importCustom(byteArrayOf(3), "on-set.cube")

        assertIs<CustomLutImportResult.Rejected>(result)
        assertTrue(root.listFiles().isNullOrEmpty())
    }

    @Test
    fun `stored selection and validation wire reject malformed persisted values`() {
        assertNull(StoredLutSelection.fromPersisted("CUSTOM", "../outside.cube"))
        assertNull(StoredLutSelection.fromPersisted("UNKNOWN", "look-a1b2c3d4e5f6.cube"))
        assertNull(ValidatedLut.parse("2\u001F2\u001Fstored:Custom:look.cube"))
        assertNull(ValidatedLut.parse("1\u001F1\u001Fstored:Custom:look.cube"))
        assertNull(ValidatedLut.parse("1\u001F+2\u001Fstored:Custom:look.cube"))
        assertNull(ValidatedLut.parse("1\u001F2\u001F"))
    }

    private class FakeLutCore(
        var valid: Boolean = true,
        var available: Boolean = true,
        private val packedByteCount: Int = 2 * 2 * 2 * 4,
    ) : LutCoreBridge {
        override val isAvailable: Boolean
            get() = available

        override fun validate(
            utf8: ByteArray,
            category: StoredLutCategory,
            fileName: String,
        ): ValidatedLut? =
            if (valid && utf8.isNotEmpty()) {
                ValidatedLut(2, "stored:${category.label}:$fileName")
            } else {
                null
            }

        override fun packedCube(utf8: ByteArray): ByteArray? =
            if (valid && utf8.isNotEmpty()) ByteArray(packedByteCount) { 0x7F } else null

        override fun redDownloadAvailability(
            hasInternetPath: Boolean,
            isOnCameraAccessPoint: Boolean,
        ): String =
            when {
                isOnCameraAccessPoint -> "1\u001F1"
                hasInternetPath -> "1\u001F0"
                else -> "1\u001F2"
            }
    }
}

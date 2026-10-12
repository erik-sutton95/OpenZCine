package com.opencapture.openzcine.lut

import com.opencapture.opencine.cameracontrols.MonitorLutLibrary
import com.opencapture.opencine.cameracontrols.MonitorLutSelection
import com.opencapture.openzcine.FeedLut
import com.opencapture.openzcine.FeedLutSelection
import java.io.File
import kotlin.io.path.createTempDirectory
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlinx.coroutines.test.runTest

/** OpenZCine's adapter over the Core library (A4-27): the RED source, persisted names, reconciliation. */
class StoredLutLibraryTest {
    @Test
    fun `RED downloads import into the RED folder and legacy generated names keep their labels`() = runTest {
        val root = createTempDirectory("openzcine-lut-library").toFile()
        File(root, "custom").mkdirs()
        File(root, "custom/operator-look-a1b2c3d4e5f6.cube").writeBytes(byteArrayOf(1))
        val library = MonitorLutLibrary(
            StoredLutCategory.all.associateWith { File(root, it.name.lowercase()) },
            pack = { ByteArray(2 * 2 * 2 * 4) },
            displayName = ::storedLutDisplayName,
        )
        val download = File(root, "IPP2 Look.cube").apply { writeBytes(byteArrayOf(2)) }

        val red = assertNotNull(library.importRedCubeFile(download))

        assertEquals(StoredLutCategory.RED, red.selection.category)
        assertEquals("IPP2 Look", red.displayName)
        assertEquals(listOf(red), library.entries(StoredLutCategory.RED))
        assertEquals(listOf("operator look"), library.entries(StoredLutCategory.CUSTOM).map { it.displayName })
    }

    @Test
    fun `persisted selections decode only known categories and path safe names`() {
        assertNull(StoredLutSelection.fromPersisted("CUSTOM", "../outside.cube"))
        assertNull(StoredLutSelection.fromPersisted("UNKNOWN", "look-a1b2c3d4e5f6.cube"))
        assertNull(StoredLutSelection.fromPersisted(null, "look.cube"))
        assertEquals(
            MonitorLutSelection.of(StoredLutCategory.RED, "look.cube"),
            StoredLutSelection.fromPersisted("RED", "look.cube"),
        )
    }

    @Test
    fun `active stored selection prefers prepared replacement then protected built in`() {
        val deleted = requireNotNull(StoredLutSelection.fromPersisted("RED", "deleted-000000000001.cube"))
        val replacement = requireNotNull(StoredLutSelection.fromPersisted("RED", "red-000000000002.cube"))
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
}

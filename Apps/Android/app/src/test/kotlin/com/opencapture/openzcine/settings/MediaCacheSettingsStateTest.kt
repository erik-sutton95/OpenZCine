package com.opencapture.openzcine.settings

import com.opencapture.openzcine.media.MediaCacheObjectIdentity
import com.opencapture.openzcine.media.MediaCacheStore
import java.nio.file.Files
import java.nio.file.Path
import kotlin.io.path.createTempDirectory
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/** Tests the Settings-facing cache state independently from Compose. */
class MediaCacheSettingsStateTest {
    @Test
    fun `clear state reports reclaimed files while preserving resumable bytes`() {
        val root = createTempDirectory("openzcine-settings-cache")
        try {
            val store = MediaCacheStore(root)
            val complete = store.openEntry("camera", identity("COMPLETE.MOV"), 4)
            complete.append(0, byteArrayOf(1, 2, 3, 4))
            complete.complete()
            val incomplete = store.openEntry("camera", identity("INCOMPLETE.MOV"), 6)
            incomplete.append(0, byteArrayOf(5, 6, 7))
            val state = MediaCacheSettingsState(store)

            val initial = state.refresh()
            assertEquals(7, initial.usage.totalBytes)
            assertEquals(1, initial.usage.completeEntryCount)
            assertEquals(1, initial.usage.incompleteEntryCount)
            assertEquals(null, initial.clearResult)

            val cleared = state.clearCompleted()

            assertEquals(3, cleared.usage.totalBytes)
            assertEquals(0, cleared.usage.completeEntryCount)
            assertEquals(1, cleared.usage.incompleteEntryCount)
            assertEquals(1, cleared.clearResult?.removedCompleteEntryCount)
            assertEquals(4, cleared.clearResult?.removedCompleteBytes)
            assertEquals(1, cleared.clearResult?.preservedIncompleteEntryCount)
            assertEquals(3, cleared.clearResult?.preservedIncompleteBytes)
            assertTrue(Files.exists(incomplete.partialPath))
        } finally {
            deleteTree(root)
        }
    }

    private fun identity(filename: String): MediaCacheObjectIdentity =
        MediaCacheObjectIdentity(
            storageId = 1,
            handle = filename.hashCode().toLong(),
            captureDate = "20260715T120000",
            filename = filename,
        )

    private fun deleteTree(root: Path) {
        if (!Files.exists(root)) return
        Files.walk(root).use { paths ->
            paths.sorted(Comparator.reverseOrder()).forEach(Files::deleteIfExists)
        }
    }
}

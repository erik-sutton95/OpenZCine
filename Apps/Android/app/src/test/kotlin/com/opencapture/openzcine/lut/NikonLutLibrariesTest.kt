package com.opencapture.openzcine.lut

import com.opencapture.opencine.cameracontrols.LutPickerLayout
import com.opencapture.openzcine.FeedLut
import com.opencapture.openzcine.FeedLutSelection
import com.opencapture.openzcine.RedOutputSpaceFilter
import com.opencapture.openzcine.filteredRedLutEntries
import com.opencapture.openzcine.nikonLutLibraries
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** A2-60 (Android): Nikon's looks reach the shared picker as typed libraries, RED as a value. */
class NikonLutLibrariesTest {
    private fun stored(category: StoredLutCategory, fileName: String) =
        StoredLutEntry(StoredLutSelection.generated(category, fileName), fileName.removeSuffix(".cube"))

    private val red709 = stored(StoredLutCategory.RED, "REC709_MEDIUM_CONTRAST_SOFT.cube")
    private val red2020 = stored(StoredLutCategory.RED, "REC2020_LOW_CONTRAST.cube")
    private val custom = stored(StoredLutCategory.CUSTOM, "Operator-Look.cube")

    private class Calls {
        val builtIns = mutableListOf<FeedLut>()
        val stored = mutableListOf<StoredLutEntry>()
        val deleted = mutableListOf<StoredLutEntry>()
        val filters = mutableListOf<RedOutputSpaceFilter>()
        var imports = 0
        var downloads = 0
    }

    private fun libraries(applied: FeedLutSelection, entries: List<StoredLutEntry>, calls: Calls,
        filter: RedOutputSpaceFilter = RedOutputSpaceFilter.ALL) =
        nikonLutLibraries(applied, entries, filter, { calls.filters += it }, { calls.builtIns += it },
            { calls.stored += it }, { calls.deleted += it }, { calls.imports += 1 }, { calls.downloads += 1 })

    @Test
    fun anEmptyRedLibraryOffersTheDownload() {
        val calls = Calls()
        val tabs = libraries(FeedLutSelection.BuiltIn(FeedLut.R3D_NE_MONITOR), emptyList(), calls)
        assertEquals(listOf("Built-in", "RED", "Custom"), tabs.map { it.title })
        assertEquals(listOf(LutPickerLayout.DRUM, LutPickerLayout.DRUM, LutPickerLayout.FILES), tabs.map { it.layout })
        assertEquals(listOf(true, false, false), tabs.map { it.isCurrent })
        assertEquals(FeedLut.R3D_NE_MONITOR.credit, tabs[0].caption)
        val red = tabs[1]
        assertTrue(red.entries.isEmpty())
        assertNull(red.filter)
        assertEquals("Download from RED", red.empty?.action?.title)
        red.empty?.action?.onClick?.invoke()
        assertEquals(1, calls.downloads)
        tabs[2].onImport?.invoke()
        assertEquals(1, calls.imports)
    }

    @Test
    fun aDownloadedRedSetStarsItsDefaultAndFiltersByOutputSpace() {
        val calls = Calls()
        val entries = listOf(red2020, red709, custom)
        val red = libraries(FeedLutSelection.BuiltIn(FeedLut.LOG3G10_709), entries, calls)[1]
        assertEquals(setOf(red709.selection.fileName), red.markedIds)
        assertEquals(red709.selection.fileName, red.entries.first().id)
        assertEquals(red709.selection.fileName, red.representative?.id)
        assertEquals(listOf("All", "Rec.709", "Rec.2020"), red.filter?.options)
        red.representative?.let(red.onSelect)
        assertEquals(listOf(red709), calls.stored)
        red.filter?.onSelect?.invoke("Rec.2020")
        assertEquals(listOf(RedOutputSpaceFilter.REC2020), calls.filters)
        assertEquals(listOf(red2020), filteredRedLutEntries(listOf(red2020, red709), RedOutputSpaceFilter.REC2020))

        val applied = libraries(FeedLutSelection.Stored(red2020.selection), entries, calls, RedOutputSpaceFilter.REC2020)
        assertEquals(listOf(false, true, false), applied.map { it.isCurrent })
        assertEquals(red2020.selection.fileName, applied[1].selectedId)
        applied[1].onDelete?.invoke(applied[1].entries.single())
        assertEquals(listOf(red2020), calls.deleted)
    }

    @Test
    fun importedLooksUseTheSharedFileList() {
        val calls = Calls()
        val tabs = libraries(FeedLutSelection.Stored(custom.selection), listOf(custom), calls)
        val files = tabs[2]
        assertTrue(files.isCurrent)
        assertEquals(custom.selection.fileName, files.selectedId)
        assertEquals(listOf("Operator-Look"), files.entries.map { it.title })
        assertEquals("Import a .cube file to add your own look.", files.empty?.hint)
    }
}

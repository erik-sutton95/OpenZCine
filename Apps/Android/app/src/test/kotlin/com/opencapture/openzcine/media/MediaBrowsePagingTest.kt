package com.opencapture.openzcine.media

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.test.runTest

class MediaBrowsePagingTest {
    @Test
    fun `parses versioned page header and records`() {
        val page =
            MediaBrowsePages.parse(
                "OZCMEDIA1\t1\t32\t0\n" +
                    "4097\t65537\t1284505600\t20260713T101010\t5760\t3240\t1\tproxy\t\t\tC0001.MOV",
            )

        requireNotNull(page)
        assertTrue(page.hasMore)
        assertEquals(32, page.inspectedObjectCount)
        assertEquals(listOf("C0001.MOV"), page.clips.map { it.filename })
    }

    @Test
    fun `parses an empty final page`() {
        val page = MediaBrowsePages.parse("OZCMEDIA1\t0\t0\t0")

        requireNotNull(page)
        assertFalse(page.hasMore)
        assertTrue(page.clips.isEmpty())
    }

    @Test
    fun `rejects malformed page headers`() {
        assertNull(MediaBrowsePages.parse(""))
        assertNull(MediaBrowsePages.parse("OZCMEDIA2\t0\t0\t0"))
        assertNull(MediaBrowsePages.parse("OZCMEDIA1\tmaybe\t0\t0"))
        assertNull(MediaBrowsePages.parse("OZCMEDIA1\t0\t-1\t0"))
        assertNull(MediaBrowsePages.parse("OZCMEDIA1\t0\t129\t0"))
        assertNull(MediaBrowsePages.parse("OZCMEDIA1\t0\t0\t1\n-\t1\t-1"))
    }

    @Test
    fun `collects every page and publishes both storage cards incrementally`() = runTest {
        val gateway =
            FakeMediaBrowseGateway(
                pages =
                    listOf(
                        page(
                            hasMore = true,
                            inspected = 2,
                            records = listOf(record(5, 1, "CARD1-NEW.MOV"), record(9, 2, "CARD2-NEW.MOV")),
                        ),
                        page(
                            hasMore = true,
                            inspected = 2,
                            records = listOf(record(4, 1, "CARD1-OLD.MOV")),
                        ),
                        page(
                            hasMore = false,
                            inspected = 1,
                            records = listOf(record(8, 2, "CARD2-OLD.MOV")),
                        ),
                    ),
            )
        val updates = mutableListOf<MediaBrowseSnapshot>()

        val clips =
            loadCameraMediaPages(
                pageSize = 2,
                gateway = gateway,
                ioContext = Dispatchers.Unconfined,
                onPage = updates::add,
            )

        assertEquals(listOf(2, 3, 4), updates.map { it.clips.size })
        assertEquals(setOf(1L, 2L), updates.first().clips.map { it.storageId }.toSet())
        assertEquals(setOf(1L, 2L), clips.map { it.storageId }.toSet())
        assertEquals(listOf(2, 2, 2), gateway.requestedPageSizes)
        assertEquals(listOf(41L), gateway.cancelledCursors)
    }

    @Test
    fun `later proxy removal wins over an earlier R3D addition`() = runTest {
        val master = "7\t1\t2\t20260715T120000\t6144\t3240\t0\tr3d\t\t\tA001.R3D"
        val proxy = record(8, 2, "A001.MP4")
        val gateway =
            FakeMediaBrowseGateway(
                pages =
                    listOf(
                        page(hasMore = true, inspected = 1, records = listOf(master)),
                        page(
                            hasMore = false,
                            inspected = 1,
                            records = listOf(proxy),
                            removals = listOf(MediaObjectIdentity(storageID = 1, handle = 7)),
                        ),
                    ),
            )
        val updates = mutableListOf<MediaBrowseSnapshot>()

        val clips =
            loadCameraMediaPages(
                pageSize = 2,
                gateway = gateway,
                ioContext = Dispatchers.Unconfined,
                onPage = { updates += it },
            )

        assertEquals(listOf("A001.R3D"), updates.first().clips.map { it.filename })
        assertEquals(listOf("A001.MP4"), clips.map { it.filename })
    }

    @Test
    fun `caller cancellation always invalidates the native cursor`() = runTest {
        val gateway =
            FakeMediaBrowseGateway(
                pages = listOf(page(hasMore = true, inspected = 1, records = listOf(record(1, 1, "A.MOV")))),
            )

        assertFailsWith<CancellationException> {
            loadCameraMediaPages(
                pageSize = 1,
                gateway = gateway,
                ioContext = Dispatchers.Unconfined,
                onPage = { throw CancellationException("New listing replaced this one.") },
            )
        }
        assertEquals(listOf(41L), gateway.cancelledCursors)
    }

    @Test
    fun `invalid native page fails closed and releases the cursor`() = runTest {
        val gateway = FakeMediaBrowseGateway(pages = listOf("unversioned"))

        assertFailsWith<MediaBrowsePagingException> {
            loadCameraMediaPages(
                pageSize = 32,
                gateway = gateway,
                ioContext = Dispatchers.Unconfined,
                onPage = {},
            )
        }
        assertEquals(listOf(41L), gateway.cancelledCursors)
    }

    private class FakeMediaBrowseGateway(
        pages: List<String>,
        private val cursor: Long = 41,
    ) : MediaBrowseGateway {
        private val remainingPages = ArrayDeque(pages)
        val requestedPageSizes = mutableListOf<Int>()
        val cancelledCursors = mutableListOf<Long>()

        override fun begin(): Long = cursor

        override fun next(cursor: Long, maxObjects: Int): String? {
            assertEquals(this.cursor, cursor)
            requestedPageSizes += maxObjects
            return remainingPages.removeFirstOrNull()
        }

        override fun cancel(cursor: Long) {
            cancelledCursors += cursor
        }
    }

    private companion object {
        fun page(
            hasMore: Boolean,
            inspected: Int,
            records: List<String>,
            removals: List<MediaObjectIdentity> = emptyList(),
        ): String =
            buildList {
                add("OZCMEDIA1\t${if (hasMore) 1 else 0}\t$inspected\t${removals.size}")
                removals.forEach { add("-\t${it.storageID}\t${it.handle}") }
                addAll(records)
            }.joinToString(separator = "\n")

        fun record(handle: Long, storageID: Long, filename: String): String =
            "$handle\t$storageID\t1\t20260715T12000$handle\t1920\t1080\t1\tproxy\t\t\t$filename"
    }
}

package com.opencapture.openzcine.media

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/** JVM coverage for burst-series grouping (mirrors the shared Swift core suite). */
class BurstSeriesTest {
    private fun frame(
        id: String,
        handle: Long,
        date: String,
        storage: Long? = 1,
        stem: String = id,
        raw: Boolean = false,
        format: String = "jpg|6048x4032",
    ) = BurstFrame(id, storage, handle, date, stem, raw, format)

    @Test
    fun `groups a contiguous burst of three or more`() {
        val frames = (0 until 12).map { frame("f$it", handle = 100L + it, date = "20260724T101500") }
        val series = BurstSeriesGrouping.group(frames)
        assertEquals(1, series.size)
        assertEquals(12, series[0].count)
        assertEquals("f0", series[0].representativeID)
    }

    @Test
    fun `a gap larger than the window breaks the series`() {
        val a = (0 until 3).map { frame("a$it", handle = 10L + it, date = "20260724T101500") }
        val b = (0 until 3).map { frame("b$it", handle = 20L + it, date = "20260724T101505") }
        val series = BurstSeriesGrouping.group(a + b)
        assertEquals(2, series.size)
        assertTrue(series.all { it.count == 3 })
    }

    @Test
    fun `only runs meeting the threshold survive`() {
        val a = (0 until 3).map { frame("a$it", handle = 10L + it, date = "20260724T101500") }
        val b = (0 until 2).map { frame("b$it", handle = 20L + it, date = "20260724T101512") }
        val series = BurstSeriesGrouping.group(a + b)
        assertEquals(1, series.size)
        assertEquals(listOf("a0", "a1", "a2"), series[0].memberIDs)
    }

    @Test
    fun `singles and lone pairs are not series`() {
        val single1 = frame("s1", handle = 1, date = "20260724T101500")
        val single2 = frame("s2", handle = 2, date = "20260724T101530")
        val jpeg = frame("p.jpg", handle = 3, date = "20260724T101600", stem = "p")
        val raw =
            frame("p.nef", handle = 4, date = "20260724T101600", stem = "p", raw = true, format = "nef|6048x4032")
        assertTrue(BurstSeriesGrouping.group(listOf(single1, single2, jpeg, raw)).isEmpty())
        assertTrue(BurstSeriesGrouping.group(listOf(jpeg, raw)).isEmpty())
    }

    @Test
    fun `a burst of raw jpeg pairs is one series of N shots not two N`() {
        val frames = mutableListOf<BurstFrame>()
        for (i in 0 until 6) {
            frames += frame("shot$i.jpg", handle = 100L + i * 2, date = "20260724T101500", stem = "shot$i")
            frames +=
                frame(
                    "shot$i.nef",
                    handle = 101L + i * 2,
                    date = "20260724T101500",
                    stem = "shot$i",
                    raw = true,
                    format = "nef|6048x4032",
                )
        }
        val series = BurstSeriesGrouping.group(frames)
        assertEquals(1, series.size)
        assertEquals(6, series[0].count)
        assertTrue(series[0].memberIDs.all { it.endsWith(".jpg") })
    }

    @Test
    fun `frames on different cards do not share a series`() {
        val a = (0 until 2).map { frame("a$it", handle = 10L + it, date = "20260724T101500", storage = 1) }
        val b = (0 until 2).map { frame("b$it", handle = 20L + it, date = "20260724T101500", storage = 2) }
        assertTrue(BurstSeriesGrouping.group(a + b).isEmpty())
    }

    @Test
    fun `frames with different formats do not share a series`() {
        val frames =
            listOf(
                frame("a", handle = 1, date = "20260724T101500", format = "jpg|6048x4032"),
                frame("b", handle = 2, date = "20260724T101500", format = "jpg|1920x1080"),
                frame("c", handle = 3, date = "20260724T101500", format = "jpg|6048x4032"),
            )
        assertTrue(BurstSeriesGrouping.group(frames).isEmpty())
    }

    @Test
    fun `undated frames never burst`() {
        val frames = (0 until 4).map { frame("f$it", handle = 10L + it, date = "") }
        assertTrue(BurstSeriesGrouping.group(frames).isEmpty())
    }

    @Test
    fun `input order does not affect grouping`() {
        val frames =
            listOf(
                frame("f2", handle = 12, date = "20260724T101500"),
                frame("f0", handle = 10, date = "20260724T101500"),
                frame("f1", handle = 11, date = "20260724T101500"),
            )
        val series = BurstSeriesGrouping.group(frames)
        assertEquals(1, series.size)
        assertEquals(listOf("f0", "f1", "f2"), series[0].memberIDs)
    }
}

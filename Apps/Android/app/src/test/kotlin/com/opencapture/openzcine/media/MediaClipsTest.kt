package com.opencapture.openzcine.media

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * Wire-format parsing and display labels only — the listing itself is
 * produced and tested Swift-side against the fake ZR
 * (`Tests/OpenZCineAndroidFacadeTests/MediaBrowseTests.swift`, which also
 * pins the encoding this parser mirrors).
 */
class MediaClipsTest {
    private val wire =
        "4097\t65537\t1284505600\t20260713T101010\t5760\t3240\t1\tC0001.MOV\n" +
            "4104\t65537\t8400000\t20260714T102030\t8256\t5504\t0\tDSC_0007.JPG"

    @Test
    fun `parses records from the facade wire format`() {
        val clips = MediaClips.parse(wire)

        assertEquals(2, clips.size)
        assertEquals(
            MediaClipRecord(
                handle = 4097,
                storageId = 65537,
                sizeBytes = 1_284_505_600,
                captureDate = "20260713T101010",
                pixelWidth = 5760,
                pixelHeight = 3240,
                isPlayableProxy = true,
                filename = "C0001.MOV",
            ),
            clips[0],
        )
        assertEquals("DSC_0007.JPG", clips[1].filename)
    }

    @Test
    fun `skips malformed lines instead of failing the listing`() {
        val clips =
            MediaClips.parse(
                "not-a-number\t65537\t1\t20260713T101010\t1\t1\t1\tC0001.MOV\n" +
                    "too\tfew\tfields\n" +
                    "\n" +
                    "4097\t65537\t1\t\t0\t0\t1\tC0002.MOV",
            )

        assertEquals(listOf("C0002.MOV"), clips.map { it.filename })
    }

    @Test
    fun `empty wire is an empty card`() {
        assertTrue(MediaClips.parse("").isEmpty())
    }

    @Test
    fun `labels match the iOS formatting`() {
        val clips = MediaClips.parse(wire)

        assertEquals("1.3GB · MOV", clips[0].badgeLabel)
        assertEquals("8MB · JPG", clips[1].badgeLabel)
        assertEquals(
            "0 B",
            clips[0].copy(sizeBytes = 0).sizeLabel,
        )
    }

    @Test
    fun `newest first orders by capture date then filename`() {
        val clips =
            MediaClips.parse(
                "1\t1\t1\t20260713T101010\t0\t0\t1\tC0001.MOV\n" +
                    "2\t1\t1\t20260714T090000\t0\t0\t1\tA001.MP4\n" +
                    "3\t1\t1\t20260714T090000\t0\t0\t1\tB001.MP4",
            )

        assertEquals(
            listOf("B001.MP4", "A001.MP4", "C0001.MOV"),
            MediaClips.newestFirst(clips).map { it.filename },
        )
    }

    @Test
    fun `playback time uses compact minute clock`() {
        assertEquals("0:00", formatPlaybackTime(-1))
        assertEquals("1:05", formatPlaybackTime(65_999))
        assertEquals("61:01", formatPlaybackTime(3_661_000))
    }
}

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
        "4097\t65537\t1284505600\t20260713T101010\t5760\t3240\t1\tproxy\t\t\tC0001.MOV\n" +
            "4104\t65537\t8400000\t20260714T102030\t8256\t5504\t0\tstill\tprogressive\tJPEG\tDSC_0007.JPG"

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
                filename = "C0001.MOV",
                contentKind = MediaContentKind.PLAYABLE_PROXY,
                stillPhoto = null,
            ),
            clips[0],
        )
        assertEquals("DSC_0007.JPG", clips[1].filename)
        assertEquals(MediaContentKind.STILL_PHOTO, clips[1].contentKind)
        assertEquals(
            StillPhotoClassification("JPEG", StillPreviewStrategy.PROGRESSIVE),
            clips[1].stillPhoto,
        )
    }

    @Test
    fun `skips malformed lines instead of failing the listing`() {
        val clips =
            MediaClips.parse(
                "not-a-number\t65537\t1\t20260713T101010\t1\t1\t1\tproxy\t\t\tC0001.MOV\n" +
                    "too\tfew\tfields\n" +
                    "\n" +
                    "4097\t65537\t1\t\t0\t0\t1\tstill\t\t\tC0002.MOV\n" +
                    "4098\t65537\t1\t\t0\t0\t0\tproxy\t\t\tC0003.MOV\n" +
                    "4099\t65537\t1\t\t0\t0\t1\tproxy\t\t\tC0002.MOV",
            )

        assertEquals(listOf("C0002.MOV"), clips.map { it.filename })
    }

    @Test
    fun `empty wire is an empty card`() {
        assertTrue(MediaClips.parse("").isEmpty())
    }

    @Test
    fun `rejects unknown core content and still-policy codes`() {
        val clips =
            MediaClips.parse(
                "1\t1\t1\t\t0\t0\t0\tfuture\t\t\tUNKNOWN.BIN\n" +
                    "2\t1\t1\t\t0\t0\t0\tstill\tfuture\tJPEG\tUNKNOWN.BIN",
            )

        assertTrue(clips.isEmpty())
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
    fun `renders only the still policy encoded by the shared core`() {
        val jpeg =
            MediaClips.parse("1\t1\t1\t\t0\t0\t0\tstill\tprogressive\tJPEG\tCAMERA_OBJECT.001")
                .single()
        val png =
            MediaClips.parse("2\t1\t1\t\t0\t0\t0\tstill\tprogressive\tPNG\tFRAME.UNKNOWN")
                .single()
        val heif =
            MediaClips.parse("3\t1\t1\t\t0\t0\t0\tstill\tcomplete\tHEIF\tSTILL.BIN")
                .single()
        val raw =
            MediaClips.parse("4\t1\t1\t\t0\t0\t0\tstill\tthumbnail\tNikon RAW\tOBJECT.DATA")
                .single()
        val r3d = MediaClips.parse("5\t1\t1\t\t0\t0\t0\tr3d\t\t\tA001.R3D").single()

        assertEquals(MediaContentKind.STILL_PHOTO, jpeg.contentKind)
        assertEquals(StillPreviewStrategy.PROGRESSIVE, jpeg.stillPhoto?.previewStrategy)
        assertEquals(MediaContentKind.STILL_PHOTO, png.contentKind)
        assertEquals(StillPreviewStrategy.PROGRESSIVE, png.stillPhoto?.previewStrategy)
        assertEquals(MediaContentKind.STILL_PHOTO, heif.contentKind)
        assertEquals(StillPreviewStrategy.COMPLETE_FILE, heif.stillPhoto?.previewStrategy)
        assertEquals(MediaContentKind.STILL_PHOTO, raw.contentKind)
        assertEquals(StillPreviewStrategy.THUMBNAIL_ONLY, raw.stillPhoto?.previewStrategy)
        assertEquals(MediaContentKind.R3D_MASTER, r3d.contentKind)
        assertEquals(null, r3d.stillPhoto)
    }

    @Test
    fun `newest first orders by capture date then filename`() {
        val clips =
            MediaClips.parse(
                "1\t1\t1\t20260713T101010\t0\t0\t1\tproxy\t\t\tC0001.MOV\n" +
                    "2\t1\t1\t20260714T090000\t0\t0\t1\tproxy\t\t\tA001.MP4\n" +
                    "3\t1\t1\t20260714T090000\t0\t0\t1\tproxy\t\t\tB001.MP4",
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

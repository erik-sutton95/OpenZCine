package com.opencapture.openzcine.media

import com.opencapture.opencine.nikon.NikonMediaClipRecord
import com.opencapture.opencine.nikon.NikonMediaClips
import com.opencapture.opencine.nikon.NikonMediaContentKind
import com.opencapture.opencine.nikon.NikonStillPhotoClassification
import com.opencapture.opencine.nikon.NikonStillPreviewStrategy
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
        "4097\t65537\t1284505600\t20260713T101010\t1920\t1080\t6048\t3402\t1\tproxy\t\t\tC0001.MOV\n" +
            "4104\t65537\t8400000\t20260714T102030\t8256\t5504\t0\t0\t0\tstill\tprogressive\tJPEG\tDSC_0007.JPG"

    @Test
    fun `parses records from the facade wire format`() {
        val clips = NikonMediaClips.parse(wire)

        assertEquals(2, clips.size)
        assertEquals(
            NikonMediaClipRecord(
                handle = 4097,
                storageId = 65537,
                sizeBytes = 1_284_505_600,
                captureDate = "20260713T101010",
                pixelWidth = 1920,
                pixelHeight = 1080,
                filename = "C0001.MOV",
                contentKind = NikonMediaContentKind.PLAYABLE_PROXY,
                stillPhoto = null,
                sourcePixelWidth = 6048,
                sourcePixelHeight = 3402,
            ),
            clips[0],
        )
        assertEquals("DSC_0007.JPG", clips[1].filename)
        assertEquals(NikonMediaContentKind.STILL_PHOTO, clips[1].contentKind)
        assertEquals(
            NikonStillPhotoClassification("JPEG", NikonStillPreviewStrategy.PROGRESSIVE),
            clips[1].stillPhoto,
        )
    }

    @Test
    fun `skips malformed lines instead of failing the listing`() {
        val clips =
            NikonMediaClips.parse(
                "not-a-number\t65537\t1\t20260713T101010\t1\t1\t0\t0\t1\tproxy\t\t\tC0001.MOV\n" +
                    "too\tfew\tfields\n" +
                    "\n" +
                    "4097\t65537\t1\t\t0\t0\t0\t0\t1\tstill\t\t\tC0002.MOV\n" +
                    "4098\t65537\t1\t\t0\t0\t0\t0\t0\tproxy\t\t\tC0003.MOV\n" +
                    "4099\t65537\t1\t\t0\t0\t0\t0\t1\tproxy\t\t\tC0002.MOV",
            )

        assertEquals(listOf("C0002.MOV"), clips.map { it.filename })
    }

    @Test
    fun `empty wire is an empty card`() {
        assertTrue(NikonMediaClips.parse("").isEmpty())
    }

    @Test
    fun `rejects unknown core content and still-policy codes`() {
        val clips =
            NikonMediaClips.parse(
                "1\t1\t1\t\t0\t0\t0\t0\t0\tfuture\t\t\tUNKNOWN.BIN\n" +
                    "2\t1\t1\t\t0\t0\t0\t0\t0\tstill\tfuture\tJPEG\tUNKNOWN.BIN",
            )

        assertTrue(clips.isEmpty())
    }

    @Test
    fun `labels match the iOS formatting`() {
        val clips = NikonMediaClips.parse(wire)

        assertEquals("1.28 GB · MOV", clips[0].badgeLabel)
        assertEquals("8.4 MB · JPG", clips[1].badgeLabel)
        assertEquals("", clips[0].copy(sizeBytes = 0).sizeLabel)
    }

    @Test
    fun `renders only the still policy encoded by the shared core`() {
        val jpeg =
            NikonMediaClips.parse("1\t1\t1\t\t0\t0\t0\t0\t0\tstill\tprogressive\tJPEG\tCAMERA_OBJECT.001")
                .single()
        val png =
            NikonMediaClips.parse("2\t1\t1\t\t0\t0\t0\t0\t0\tstill\tprogressive\tPNG\tFRAME.UNKNOWN")
                .single()
        val heif =
            NikonMediaClips.parse("3\t1\t1\t\t0\t0\t0\t0\t0\tstill\tcomplete\tHEIF\tSTILL.BIN")
                .single()
        val raw =
            NikonMediaClips.parse("4\t1\t1\t\t0\t0\t0\t0\t0\tstill\tthumbnail\tNikon RAW\tOBJECT.DATA")
                .single()
        val r3d = NikonMediaClips.parse("5\t1\t1\t\t0\t0\t0\t0\t0\tr3d\t\t\tA001.R3D").single()

        assertEquals(NikonMediaContentKind.STILL_PHOTO, jpeg.contentKind)
        assertEquals(NikonStillPreviewStrategy.PROGRESSIVE, jpeg.stillPhoto?.previewStrategy)
        assertEquals(NikonMediaContentKind.STILL_PHOTO, png.contentKind)
        assertEquals(NikonStillPreviewStrategy.PROGRESSIVE, png.stillPhoto?.previewStrategy)
        assertEquals(NikonMediaContentKind.STILL_PHOTO, heif.contentKind)
        assertEquals(NikonStillPreviewStrategy.COMPLETE_FILE, heif.stillPhoto?.previewStrategy)
        assertEquals(NikonMediaContentKind.STILL_PHOTO, raw.contentKind)
        assertEquals(NikonStillPreviewStrategy.THUMBNAIL_ONLY, raw.stillPhoto?.previewStrategy)
        assertEquals(NikonMediaContentKind.R3D_MASTER, r3d.contentKind)
        assertEquals(null, r3d.stillPhoto)
    }

    @Test
    fun `newest first orders by capture date then filename`() {
        val clips =
            NikonMediaClips.parse(
                "1\t1\t1\t20260713T101010\t0\t0\t0\t0\t1\tproxy\t\t\tC0001.MOV\n" +
                    "2\t1\t1\t20260714T090000\t0\t0\t0\t0\t1\tproxy\t\t\tA001.MP4\n" +
                    "3\t1\t1\t20260714T090000\t0\t0\t0\t0\t1\tproxy\t\t\tB001.MP4",
            )

        assertEquals(
            listOf("B001.MP4", "A001.MP4", "C0001.MOV"),
            NikonMediaClips.newestFirst(clips).map { it.filename },
        )
    }

    @Test
    fun `playback time uses compact minute clock`() {
        assertEquals("0:00", formatPlaybackTime(-1))
        assertEquals("1:05", formatPlaybackTime(65_999))
        assertEquals("61:01", formatPlaybackTime(3_661_000))
    }

    @Test
    fun `partial camera listing is represented as a retryable failure`() {
        val clip = NikonMediaClips.parse(wire.lines().first()).single()

        val state = incompleteCameraBrowseState(listOf(clip))

        assertEquals("Listing stopped after 1 item. Retry to load the complete library.", state.message)
    }
}

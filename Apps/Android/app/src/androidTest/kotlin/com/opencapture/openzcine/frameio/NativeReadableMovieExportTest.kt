@file:androidx.media3.common.util.UnstableApi

package com.opencapture.openzcine.frameio

import android.graphics.Bitmap
import android.graphics.Color
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.opencapture.opencine.runtime.MonitorMovieExportContainer
import com.opencapture.opencine.runtime.MonitorMovieExportLut
import com.opencapture.openzcine.FeedLut
import com.opencapture.openzcine.FeedLutSelection
import com.opencapture.openzcine.media.StagedMediaShare
import java.nio.ByteBuffer
import java.nio.file.Files
import java.nio.file.Path
import java.util.Collections
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/** SIMULATED generated movie input through the real native Media3 exporter and app adopter. */
@RunWith(AndroidJUnit4::class)
class NativeReadableMovieExportTest {
    @Test fun actualMovAndMp4AreReadableRetainAudioTimecodeAndPublishProgress() = runBlocking {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val root = Files.createTempDirectory(context.cacheDir.toPath(), "native-readable-export-")
        val evidence = requireNotNull(context.getExternalFilesDir(null)).toPath().resolve("native-readable-export-owner-v1")
        Files.createDirectories(evidence)
        try {
            val source = root.resolve("source.mov")
            instrumentation.context.assets.open("readable-export-input.mov").use { input -> Files.copy(input, source) }
            val original = Files.readAllBytes(source)
            val sourceTimecode = timecodeSample(original)
            assertEquals(4, sourceTimecode.size)
            val sourcePixels = decodedFrame(source)
            try { assertTrue("generated source is green", Color.green(sourcePixels.getPixel(sourcePixels.width / 2, sourcePixels.height / 2)) > 120) }
            finally { sourcePixels.recycle() }
            val lut = MonitorMovieExportLut("SIMULATED constant red fixture", 2, ByteArray(32) { index ->
                when (index % 4) { 0 -> 230.toByte(); 1 -> 16; 2 -> 32; else -> 255.toByte() }
            })
            val preparer = AndroidFrameioArtifactPreparer(root.resolve("exports"), object : FrameioLutProvider {
                override suspend fun approvedPayload(selection: FeedLutSelection) = lut
            }, AndroidMedia3FrameioLutVideoExporter(context))
            val artifact = FrameioDeliveryArtifact(
                StagedMediaShare(source, "SIMULATED-source.MOV", "video/quicktime"),
                Files.size(source), FrameioArtifactContext("SIMULATED camera", "20261005T010000", true),
            )
            for (container in MonitorMovieExportContainer.entries) {
                val progress = Collections.synchronizedList(mutableListOf<Double>())
                val prepared = preparer.prepare(artifact, FrameioDeliveryOptions(
                    bakeLut = true, exportContainer = container, selectedLut = FeedLutSelection.BuiltIn(FeedLut.MONO),
                )) { progress += it }
                try {
                    assertTrue(prepared.byteCount > 0)
                    assertEquals(Files.size(prepared.share.file), prepared.byteCount)
                    assertEquals("SIMULATED-source.${container.extension}", prepared.share.displayName)
                    assertEquals(container.mimeType, prepared.share.mimeType)
                    assertEquals(lut.displayName, prepared.appliedLutName)
                    assertEquals(prepared.share.file, prepared.transientExport)
                    assertTrue(progress.isNotEmpty())
                    assertEquals(1.0, progress.last(), 0.0)
                    assertTrue(progress.all { it.isFinite() && it in 0.0..1.0 })
                    val movie = Files.readAllBytes(prepared.share.file)
                    assertArrayEquals(sourceTimecode, timecodeSample(movie))
                    val brand = movie.copyOfRange(8, 12).toString(Charsets.US_ASCII)
                    if (container == MonitorMovieExportContainer.MOV) assertEquals("qt  ", brand) else assertFalse(brand == "qt  ")
                    assertTrue("actual muxed audio has a sample", hasAudioSample(prepared.share.file))
                    val decoded = decodedFrame(prepared.share.file)
                    try {
                        assertEquals(320, decoded.width)
                        assertEquals(180, decoded.height)
                        val pixel = decoded.getPixel(decoded.width / 2, decoded.height / 2)
                        assertTrue("actual LUT-baked decoded pixels are red", Color.red(pixel) > 150 && Color.green(pixel) < 80 && Color.blue(pixel) < 100)
                        Files.newOutputStream(evidence.resolve("${container.extension}-decoded.png")).use { decoded.compress(Bitmap.CompressFormat.PNG, 100, it) }
                    } finally { decoded.recycle() }
                    Files.copy(prepared.share.file, evidence.resolve("output.${container.extension}"), java.nio.file.StandardCopyOption.REPLACE_EXISTING)
                    // ART's java.nio.file.Files has no writeString.
                    Files.write(evidence.resolve("${container.extension}-progress.json"), "{\"label\":\"SIMULATED actual native movie export\",\"samples\":${progress.toList()},\"bytes\":${prepared.byteCount}}".toByteArray())
                    assertArrayEquals(original, Files.readAllBytes(source))
                } finally { preparer.release(prepared) }
                assertFalse(Files.exists(prepared.share.file))
            }
        } finally { root.toFile().deleteRecursively() }
    }

    private fun decodedFrame(path: Path): Bitmap {
        val reader = MediaMetadataRetriever()
        try {
            reader.setDataSource(path.toString())
            val bitmap = reader.getFrameAtTime(0, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
            assertNotNull("actual movie is natively decodable", bitmap)
            return requireNotNull(bitmap)
        } finally { reader.release() }
    }

    private fun hasAudioSample(path: Path): Boolean {
        val reader = MediaExtractor()
        try {
            reader.setDataSource(path.toString())
            val track = (0 until reader.trackCount).firstOrNull { reader.getTrackFormat(it).getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true } ?: return false
            reader.selectTrack(track)
            // The AAC priming sample before the edit list's media start reads at a negative time; start at the first presented one.
            reader.seekTo(0, MediaExtractor.SEEK_TO_NEXT_SYNC)
            return reader.sampleTime >= 0 && reader.readSampleData(ByteBuffer.allocate(64 * 1024), 0) > 0
        } finally { reader.release() }
    }

    private data class Box(val start: Int, val size: Int, val type: String) {
        val payload get() = start + 8
        val end get() = start + size
    }

    /** Reads the real tmcd track and chunk sample; a bare four-letter occurrence is insufficient. */
    private fun timecodeSample(bytes: ByteArray): ByteArray {
        fun int(offset: Int) = ByteBuffer.wrap(bytes, offset, 4).int
        fun children(start: Int, end: Int): List<Box> {
            val out = mutableListOf<Box>(); var cursor = start
            while (cursor < end) {
                require(cursor + 8 <= end)
                // ISO-BMFF: size 1 carries a 64-bit largesize after the type (Media3 mdat), size 0 runs to the parent end.
                val declared = int(cursor).toLong() and 0xFFFF_FFFFL
                val header = if (declared == 1L) 16 else 8; require(cursor + header <= end)
                val size = when (declared) { 1L -> ByteBuffer.wrap(bytes, cursor + 8, 8).long; 0L -> (end - cursor).toLong(); else -> declared }
                require(size >= header && size <= end - cursor)
                out += Box(cursor, size.toInt(), bytes.copyOfRange(cursor + 4, cursor + 8).toString(Charsets.US_ASCII))
                cursor += size.toInt()
            }
            return out
        }
        fun child(box: Box, type: String) = children(box.payload, box.end).single { it.type == type }
        val moov = children(0, bytes.size).single { it.type == "moov" }
        val tracks = children(moov.payload, moov.end).filter { it.type == "trak" }
        val track = tracks.single { t ->
            val hdlr = child(child(t, "mdia"), "hdlr")
            bytes.copyOfRange(hdlr.payload + 8, hdlr.payload + 12).toString(Charsets.US_ASCII) == "tmcd"
        }
        val stbl = child(child(child(track, "mdia"), "minf"), "stbl")
        val stsz = child(stbl, "stsz"); assertEquals(1, int(stsz.payload + 8))
        val size = int(stsz.payload + 4); assertTrue(size in 1..64)
        val offsets = children(stbl.payload, stbl.end).single { it.type == "stco" || it.type == "co64" }
        assertEquals(1, int(offsets.payload + 4))
        val offset = if (offsets.type == "stco") int(offsets.payload + 8).toLong() and 0xFFFF_FFFFL else ByteBuffer.wrap(bytes, offsets.payload + 8, 8).long
        require(offset >= 0 && offset + size <= bytes.size)
        return bytes.copyOfRange(offset.toInt(), offset.toInt() + size)
    }
}

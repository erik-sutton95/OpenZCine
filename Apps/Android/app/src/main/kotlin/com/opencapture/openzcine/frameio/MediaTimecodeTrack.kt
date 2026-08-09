package com.opencapture.openzcine.frameio

import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.channels.FileChannel
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.Path
import java.nio.file.StandardCopyOption
import java.nio.file.StandardOpenOption

/**
 * Copies a camera clip's QuickTime timecode (`tmcd`) track into a finished export.
 *
 * Media3's Transformer writes video and audio only, so a LUT-baked delivery arrived at Frame.io
 * without the start timecode an NLE conforms the proxy to its R3D NE / N-RAW master with. The
 * camera stamps master and proxy from one generator, so the proxy's own track IS the master's
 * timecode: it is copied box-for-box — sample description, frame-number sample, drop-frame flags —
 * with no re-encode. iOS restores the same track with `AVMutableMovie` (`MediaTimecode.swift`).
 *
 * Best effort by contract, exactly like iOS: a source with no timecode track, a layout this
 * copier does not recognise, or a failed write leaves the export byte-identical rather than
 * failing a delivery over metadata.
 */
internal object MediaTimecodeTrack {
    /** Returns true only when [target] gained the timecode track. */
    fun copyTimecodeTrack(source: Path, target: Path): Boolean =
        try {
            copyTimecodeTrackOrThrow(source, target)
        } catch (_: Exception) {
            false
        }

    private fun copyTimecodeTrackOrThrow(source: Path, target: Path): Boolean {
        if (!Files.isRegularFile(source, LinkOption.NOFOLLOW_LINKS)) return false
        if (
            !Files.isRegularFile(target, LinkOption.NOFOLLOW_LINKS) ||
                Files.isSymbolicLink(target)
        ) {
            return false
        }
        val timecode =
            FileChannel.open(source, StandardOpenOption.READ).use(::readSourceTimecode)
                ?: return false
        return FileChannel.open(target, StandardOpenOption.READ, StandardOpenOption.WRITE)
            .use { channel -> writeTimecodeTrack(channel, target, timecode) }
    }

    // MARK: - Source

    /** The source's timecode track, ready to be re-pointed at another file's sample data. */
    private class SourceTimecode(
        val trak: ByteArray,
        /** Movie timescale the copied `tkhd` duration is expressed in. */
        val movieTimescale: Long,
        val sample: ByteArray,
    )

    private fun readSourceTimecode(channel: FileChannel): SourceTimecode? {
        val moovBox = topLevelBoxes(channel).lastOrNull { it.type == "moov" } ?: return null
        val moov = read(channel, moovBox.start, moovBox.size.toIntExact())
        val children = boxes(moov, HEADER_BYTES, moov.size)
        val movieTimescale = moov.movieTimescale(children.first { it.type == "mvhd" })
        val trak =
            children.firstOrNull { it.type == "trak" && moov.handlerType(it) == "tmcd" }
                ?: return null
        val trakBytes = moov.copyOfRange(trak.start, trak.end)
        val stbl = trakBytes.path(trakBytes.rootBox(), "mdia", "minf", "stbl") ?: return null
        val stblChildren = boxes(trakBytes, stbl.contentStart, stbl.end)
        val stsz = stblChildren.firstOrNull { it.type == "stsz" } ?: return null
        val sampleSize = trakBytes.int(stsz.contentStart + 4)
        val sampleCount = trakBytes.int(stsz.contentStart + 8)
        // A timecode track carries exactly one fixed-size frame-number sample. Anything else is a
        // layout this copier has never seen on a camera proxy, and guessing would corrupt it.
        if (sampleCount != 1 || sampleSize !in 1..MAXIMUM_SAMPLE_BYTES) return null
        val chunkOffsets = trakBytes.chunkOffsetTable(stblChildren) ?: return null
        if (chunkOffsets.entryCount != 1) return null
        val sampleOffset = trakBytes.chunkOffset(chunkOffsets, 0)
        val sample = read(channel, sampleOffset, sampleSize)
        return SourceTimecode(trakBytes, movieTimescale, sample)
    }

    // MARK: - Target

    private fun writeTimecodeTrack(
        channel: FileChannel,
        target: Path,
        timecode: SourceTimecode,
    ): Boolean {
        val fileSize = channel.size()
        val topLevel = topLevelBoxes(channel)
        val moovBox = topLevel.lastOrNull { it.type == "moov" } ?: return false
        val moov = read(channel, moovBox.start, moovBox.size.toIntExact())
        if (moov.handlerTypes().contains("tmcd")) return false

        val newMoov = buildMoov(moov, timecode)
        val delta = newMoov.size - moov.size
        val moovEnd = moovBox.start + moovBox.size
        // Chunk offsets are absolute file offsets: everything stored after the moov slides by the
        // box's growth. Offsets before it — and the new track's own placeholder — stay put.
        newMoov.shiftChunkOffsets(from = moovEnd, delta = delta.toLong())
        val sampleOffset = fileSize + delta + HEADER_BYTES
        newMoov.setTimecodeSampleOffset(sampleOffset)

        val trailer = mdatBox(timecode.sample)
        if (moovEnd == fileSize) {
            // The muxer left the moov last, so the new box can simply replace it in place.
            channel.writeFully(moovBox.start, newMoov)
            channel.writeFully(moovBox.start + newMoov.size, trailer)
            channel.truncate(moovBox.start + newMoov.size + trailer.size)
            channel.force(true)
            return true
        }
        rewriteWithNewMoov(channel, target, moovBox, newMoov, trailer)
        return true
    }

    /** Streams the export past its relocated moov; the original is replaced atomically. */
    private fun rewriteWithNewMoov(
        channel: FileChannel,
        target: Path,
        moovBox: FileBox,
        newMoov: ByteArray,
        trailer: ByteArray,
    ) {
        val temporary = target.resolveSibling(".${target.fileName}.timecode")
        try {
            FileChannel.open(
                temporary,
                StandardOpenOption.CREATE,
                StandardOpenOption.TRUNCATE_EXISTING,
                StandardOpenOption.WRITE,
            ).use { output ->
                channel.copyTo(output, from = 0, byteCount = moovBox.start)
                output.appendFully(newMoov)
                channel.copyTo(
                    output,
                    from = moovBox.start + moovBox.size,
                    byteCount = channel.size() - (moovBox.start + moovBox.size),
                )
                output.appendFully(trailer)
                output.force(true)
            }
            Files.move(
                temporary,
                target,
                StandardCopyOption.ATOMIC_MOVE,
                StandardCopyOption.REPLACE_EXISTING,
            )
        } finally {
            Files.deleteIfExists(temporary)
        }
    }

    /** Rebuilds the movie header with the copied track appended and the video track referencing it. */
    private fun buildMoov(moov: ByteArray, timecode: SourceTimecode): ByteArray {
        val children = boxes(moov, HEADER_BYTES, moov.size)
        val mvhd = children.first { it.type == "mvhd" }
        val trackID = moov.nextTrackID(mvhd, children)
        val videoTrak =
            children.firstOrNull { it.type == "trak" && moov.handlerType(it) == "vide" }
        val content = ByteArrayOutputStream()
        children.forEach { child ->
            when {
                child === mvhd -> {
                    val bytes = moov.copyOfRange(child.start, child.end)
                    bytes.putInt(bytes.size - 4, trackID + 1)
                    content.write(bytes)
                }
                child === videoTrak ->
                    content.write(moov.videoTrakWithTimecodeReference(child, trackID))
                else -> content.write(moov, child.start, child.size)
            }
        }
        content.write(
            timecode.trak.retargetedTimecodeTrak(
                trackID = trackID,
                targetMovieTimescale = moov.movieTimescale(mvhd),
                sourceMovieTimescale = timecode.movieTimescale,
            ),
        )
        return box("moov", content.toByteArray())
    }

    /** The copied track re-numbered for its new movie, with its sample offset left unresolved. */
    private fun ByteArray.retargetedTimecodeTrak(
        trackID: Int,
        targetMovieTimescale: Long,
        sourceMovieTimescale: Long,
    ): ByteArray {
        val trak = copyOf()
        val tkhd = trak.path(trak.rootBox(), "tkhd") ?: error("Timecode track has no header.")
        val version = trak[tkhd.contentStart].toInt() and 0xFF
        val trackIDOffset = tkhd.contentStart + 4 + if (version == 1) 16 else 8
        trak.putInt(trackIDOffset, trackID)
        // `tkhd.duration` is counted in the MOVIE timescale, and the export's need not match the
        // camera's; a raw copy would stretch or clip the track against its new movie.
        if (sourceMovieTimescale > 0 && targetMovieTimescale != sourceMovieTimescale) {
            val durationOffset = trackIDOffset + 4 + 4
            if (version == 1) {
                val scaled =
                    trak.long(durationOffset).rescaled(targetMovieTimescale, sourceMovieTimescale)
                trak.putLong(durationOffset, scaled)
            } else {
                val scaled =
                    trak.uint(durationOffset).rescaled(targetMovieTimescale, sourceMovieTimescale)
                trak.putInt(durationOffset, scaled.coerceAtMost(0xFFFF_FFFEL).toInt())
            }
        }
        val stbl = trak.path(trak.rootBox(), "mdia", "minf", "stbl") ?: error("No sample table.")
        val table =
            trak.chunkOffsetTable(boxes(trak, stbl.contentStart, stbl.end))
                ?: error("No chunk offset table.")
        // Zero marks the sample as "not placed yet": it sorts below every real file offset, so the
        // shift pass leaves it alone and the caller fills in the appended sample's position.
        trak.setChunkOffset(table, 0, 0L)
        return trak
    }

    /** Adds the `tref`/`tmcd` association iOS writes with `addTrackAssociation`. */
    private fun ByteArray.videoTrakWithTimecodeReference(trak: Box, trackID: Int): ByteArray {
        val existing = boxes(this, trak.contentStart, trak.end)
        // An export that already declares track references gets none added: rewriting a reference
        // list this copier did not author risks more than the association is worth, and readers
        // still find the timecode track on its own.
        if (existing.any { it.type == "tref" }) return copyOfRange(trak.start, trak.end)
        val reference = box("tref", box("tmcd", intBytes(trackID)))
        val grown = ByteArray(trak.size + reference.size)
        copyInto(grown, 0, trak.start, trak.end)
        reference.copyInto(grown, trak.size)
        grown.putInt(0, grown.size)
        return grown
    }

    private fun ByteArray.nextTrackID(mvhd: Box, children: List<Box>): Int {
        val declared = uint(mvhd.end - 4)
        if (declared in 1..0xFFFF_FFFDL) return declared.toInt()
        // A movie header that never advanced its counter still cannot collide with a live track.
        val highest =
            children.filter { it.type == "trak" }.maxOfOrNull { trak ->
                val tkhd = path(trak, "tkhd") ?: return@maxOfOrNull 0
                val version = this[tkhd.contentStart].toInt() and 0xFF
                int(tkhd.contentStart + 4 + if (version == 1) 16 else 8)
            } ?: 0
        return highest + 1
    }

    private fun ByteArray.movieTimescale(mvhd: Box): Long {
        val version = this[mvhd.contentStart].toInt() and 0xFF
        return if (version == 1) uint(mvhd.contentStart + 20) else uint(mvhd.contentStart + 12)
    }

    /** Slides every already-placed chunk offset that lives after [from] by [delta]. */
    private fun ByteArray.shiftChunkOffsets(from: Long, delta: Long) {
        if (delta == 0L) return
        forEachChunkOffsetTable { table ->
            for (index in 0 until table.entryCount) {
                val offset = chunkOffset(table, index)
                if (offset >= from) setChunkOffset(table, index, offset + delta)
            }
        }
    }

    /** Places the appended sample; the copied track is the one this rebuild put last. */
    private fun ByteArray.setTimecodeSampleOffset(offset: Long) {
        val trak = boxes(this, HEADER_BYTES, size).last { it.type == "trak" }
        val stbl = path(trak, "mdia", "minf", "stbl") ?: error("Copied track lost its sample table.")
        val table =
            chunkOffsetTable(boxes(this, stbl.contentStart, stbl.end))
                ?: error("Copied track lost its chunk offsets.")
        setChunkOffset(table, 0, offset)
    }

    private fun ByteArray.forEachChunkOffsetTable(action: (ChunkOffsetTable) -> Unit) {
        boxes(this, HEADER_BYTES, size).filter { it.type == "trak" }.forEach { trak ->
            val stbl = path(trak, "mdia", "minf", "stbl") ?: return@forEach
            chunkOffsetTable(boxes(this, stbl.contentStart, stbl.end))?.let(action)
        }
    }

    // MARK: - Box primitives

    private data class Box(val type: String, val start: Int, val size: Int) {
        val contentStart: Int
            get() = start + HEADER_BYTES

        val end: Int
            get() = start + size
    }

    private data class FileBox(val type: String, val start: Long, val size: Long)

    private data class ChunkOffsetTable(val entriesStart: Int, val entryCount: Int, val is64Bit: Boolean)

    private fun ByteArray.rootBox(): Box = Box(type(4), 0, int(0))

    private fun ByteArray.path(root: Box, vararg types: String): Box? {
        var current = root
        types.forEach { type ->
            current =
                boxes(this, current.contentStart, current.end).firstOrNull { it.type == type }
                    ?: return null
        }
        return current
    }

    private fun ByteArray.handlerType(trak: Box): String? {
        val hdlr = path(trak, "mdia", "hdlr") ?: return null
        return type(hdlr.contentStart + 8)
    }

    private fun ByteArray.handlerTypes(): List<String> =
        boxes(this, HEADER_BYTES, size).filter { it.type == "trak" }.mapNotNull { handlerType(it) }

    private fun ByteArray.chunkOffsetTable(stblChildren: List<Box>): ChunkOffsetTable? {
        val stco = stblChildren.firstOrNull { it.type == "stco" || it.type == "co64" } ?: return null
        val entryCount = int(stco.contentStart + 4)
        val is64Bit = stco.type == "co64"
        val entryBytes = if (is64Bit) 8 else 4
        if (entryCount < 0 || stco.contentStart + 8 + entryCount * entryBytes > stco.end) return null
        return ChunkOffsetTable(stco.contentStart + 8, entryCount, is64Bit)
    }

    private fun ByteArray.chunkOffset(table: ChunkOffsetTable, index: Int): Long =
        if (table.is64Bit) {
            long(table.entriesStart + index * 8)
        } else {
            uint(table.entriesStart + index * 4)
        }

    private fun ByteArray.setChunkOffset(table: ChunkOffsetTable, index: Int, offset: Long) {
        if (table.is64Bit) {
            putLong(table.entriesStart + index * 8, offset)
        } else {
            // A 32-bit table cannot address the shifted sample; leaving the file untouched is the
            // only honest outcome, so the whole copy is abandoned.
            check(offset in 0..0xFFFF_FFFFL) { "Export is too large for its 32-bit offset table." }
            putInt(table.entriesStart + index * 4, offset.toInt())
        }
    }

    private fun boxes(data: ByteArray, from: Int, until: Int): List<Box> {
        val found = mutableListOf<Box>()
        var cursor = from
        while (cursor + HEADER_BYTES <= until) {
            val size = data.int(cursor)
            check(size >= HEADER_BYTES && cursor + size <= until) { "Malformed media box." }
            found += Box(data.type(cursor + 4), cursor, size)
            cursor += size
        }
        return found
    }

    private fun topLevelBoxes(channel: FileChannel): List<FileBox> {
        val found = mutableListOf<FileBox>()
        val fileSize = channel.size()
        var position = 0L
        while (position + HEADER_BYTES <= fileSize) {
            val header = read(channel, position, HEADER_BYTES)
            val declared = header.uint(0)
            var headerBytes = HEADER_BYTES.toLong()
            val size =
                when (declared) {
                    1L -> {
                        headerBytes = 16L
                        read(channel, position + HEADER_BYTES, 8).long(0)
                    }
                    0L -> fileSize - position
                    else -> declared
                }
            check(size >= headerBytes && position + size <= fileSize) { "Malformed media file." }
            found += FileBox(header.type(4), position, size)
            position += size
        }
        return found
    }

    private fun box(type: String, content: ByteArray): ByteArray {
        val bytes = ByteArray(HEADER_BYTES + content.size)
        bytes.putInt(0, bytes.size)
        type.forEachIndexed { index, character -> bytes[4 + index] = character.code.toByte() }
        content.copyInto(bytes, HEADER_BYTES)
        return bytes
    }

    private fun mdatBox(sample: ByteArray): ByteArray = box("mdat", sample)

    private fun intBytes(value: Int): ByteArray = ByteArray(4).also { it.putInt(0, value) }

    private fun read(channel: FileChannel, position: Long, count: Int): ByteArray {
        check(count >= 0 && position >= 0) { "Invalid media read." }
        val buffer = ByteBuffer.allocate(count).order(ByteOrder.BIG_ENDIAN)
        var offset = position
        while (buffer.hasRemaining()) {
            val read = channel.read(buffer, offset)
            check(read > 0) { "Unexpected end of media file." }
            offset += read
        }
        return buffer.array()
    }

    /** `transferTo` is allowed to move fewer bytes than asked, so it is driven to completion. */
    private fun FileChannel.copyTo(output: FileChannel, from: Long, byteCount: Long) {
        var copied = 0L
        while (copied < byteCount) {
            val moved = transferTo(from + copied, byteCount - copied, output)
            check(moved > 0) { "Short copy while relocating the media header." }
            copied += moved
        }
    }

    private fun FileChannel.writeFully(position: Long, bytes: ByteArray) {
        val buffer = ByteBuffer.wrap(bytes)
        var offset = position
        while (buffer.hasRemaining()) {
            offset += write(buffer, offset)
        }
    }

    private fun FileChannel.appendFully(bytes: ByteArray) {
        val buffer = ByteBuffer.wrap(bytes)
        while (buffer.hasRemaining()) write(buffer)
    }

    private fun Long.toIntExact(): Int {
        check(this in 0..MAXIMUM_HEADER_BYTES) { "Media header is too large to rewrite." }
        return toInt()
    }

    private fun Long.rescaled(target: Long, source: Long): Long =
        if (source <= 0) this else this * target / source

    private fun ByteArray.type(position: Int): String =
        String(this, position, 4, Charsets.US_ASCII)

    private fun ByteArray.int(position: Int): Int =
        ByteBuffer.wrap(this, position, 4).order(ByteOrder.BIG_ENDIAN).int

    private fun ByteArray.uint(position: Int): Long = int(position).toLong() and 0xFFFF_FFFFL

    private fun ByteArray.long(position: Int): Long =
        ByteBuffer.wrap(this, position, 8).order(ByteOrder.BIG_ENDIAN).long

    private fun ByteArray.putInt(position: Int, value: Int) {
        ByteBuffer.wrap(this, position, 4).order(ByteOrder.BIG_ENDIAN).putInt(value)
    }

    private fun ByteArray.putLong(position: Int, value: Long) {
        ByteBuffer.wrap(this, position, 8).order(ByteOrder.BIG_ENDIAN).putLong(value)
    }

    private const val HEADER_BYTES = 8
    private const val MAXIMUM_SAMPLE_BYTES = 64
    private const val MAXIMUM_HEADER_BYTES = 64L * 1_024L * 1_024L
}

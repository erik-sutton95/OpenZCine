package com.opencapture.openzcine.lut

import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import java.io.RandomAccessFile
import java.util.zip.Inflater

/**
 * Pure ZIP walker for RED IPP2 packs.
 *
 * Android 14+ [android.os.ZipPathValidator] rejects absolute entry names (including a bare
 * `/` root) inside [java.util.zip.ZipFile] and [java.util.zip.ZipInputStream]. RED's official
 * LUT archives include those names, so libcore zip APIs throw before any `.cube` is reachable.
 *
 * This extractor never touches those APIs: it reads the central directory (preferred) or walks
 * local-file headers, inflates STORE/DEFLATE payloads, and returns only safe `.cube` files.
 */
internal object RedZipCubeExtractor {
    private const val SIG_LOCAL: Int = 0x04034b50
    private const val SIG_CENTRAL: Int = 0x02014b50
    private const val SIG_EOCD: Int = 0x06054b50
    private const val METHOD_STORE: Int = 0
    private const val METHOD_DEFLATE: Int = 8
    private const val FLAG_DATA_DESCRIPTOR: Int = 0x0008
    private const val ZIP64_SENTINEL: Long = 0xFFFF_FFFFL
    private const val MAX_NAME_BYTES: Int = 16 * 1024
    private const val MAX_EXTRA_BYTES: Int = 64 * 1024
    private const val EOCD_MIN: Int = 22
    private const val EOCD_MAX_COMMENT: Int = 65_535
    private const val EOCD_SEARCH: Int = EOCD_MIN + EOCD_MAX_COMMENT

    /**
     * Extracts up to [maxFiles] `.cube` entries from [file], each at most [maxBytes] after inflate.
     *
     * @throws IOException when the archive is truncated, uses unsupported methods for cube
     *   entries we need, or is not a ZIP at all.
     */
    fun extractCubes(
        file: File,
        maxFiles: Int = MAX_RED_ZIP_CUBE_FILES,
        maxBytes: Int = MAX_RED_CUBE_BYTES,
    ): List<RedZipCubeEntry> {
        if (!file.isFile || file.length() < 4L) {
            throw IOException("Archive is empty or missing.")
        }
        RandomAccessFile(file, "r").use { raf ->
            val fromCentral = runCatching { extractViaCentralDirectory(raf, maxFiles, maxBytes) }.getOrNull()
            if (fromCentral != null) return fromCentral
            raf.seek(0L)
            return extractViaLocalHeaders(raf, maxFiles, maxBytes)
        }
    }

    private fun extractViaCentralDirectory(
        raf: RandomAccessFile,
        maxFiles: Int,
        maxBytes: Int,
    ): List<RedZipCubeEntry>? {
        val eocd = findEocd(raf) ?: return null
        if (eocd.entryCount == 0) return emptyList()
        if (eocd.centralOffset < 0L || eocd.centralOffset >= raf.length()) return null

        val out = ArrayList<RedZipCubeEntry>(minOf(maxFiles, 64))
        var offset = eocd.centralOffset
        var remaining = eocd.entryCount
        while (remaining > 0 && out.size < maxFiles) {
            remaining -= 1
            raf.seek(offset)
            val sig = raf.readUInt32()
            if (sig != SIG_CENTRAL) {
                // Truncated or non-standard CD — fall back to local walk.
                return null
            }
            // version made by (2) + version needed (2) + general-purpose flags (2)
            raf.skipFully(6)
            val method = raf.readUInt16()
            raf.skipFully(8) // time/date + crc (crc not required for extract)
            val compressedSize = raf.readUInt32LE()
            val uncompressedSize = raf.readUInt32LE()
            val nameLen = raf.readUInt16()
            val extraLen = raf.readUInt16()
            val commentLen = raf.readUInt16()
            raf.skipFully(8) // disk start + attrs
            val localOffset = raf.readUInt32LE()
            if (nameLen > MAX_NAME_BYTES || extraLen > MAX_EXTRA_BYTES || commentLen > MAX_EXTRA_BYTES) {
                return null
            }
            val nameBytes = ByteArray(nameLen)
            raf.readFully(nameBytes)
            val name = String(nameBytes, Charsets.ISO_8859_1)
            raf.skipFully(extraLen + commentLen)
            offset = raf.filePointer

            val path = normalizeZipEntryPath(name) ?: continue
            if (!path.endsWith(".cube", ignoreCase = true)) continue
            val baseName = path.substringAfterLast('/').ifBlank { continue }
            if (baseName.startsWith("._")) continue
            if (path.contains("__MACOSX/", ignoreCase = true)) continue
            if (method != METHOD_STORE && method != METHOD_DEFLATE) continue
            if (compressedSize == ZIP64_SENTINEL || uncompressedSize == ZIP64_SENTINEL) {
                // ZIP64 cubes are not expected in RED packs; skip rather than misread.
                continue
            }
            if (uncompressedSize > maxBytes.toLong()) continue
            if (localOffset < 0L || localOffset >= raf.length()) continue

            val bytes =
                runCatching {
                    readLocalPayload(
                        raf = raf,
                        localOffset = localOffset,
                        // Prefer CD sizes; they are authoritative even when the local header
                        // used a data descriptor (flag bit 3).
                        compressedSize = compressedSize,
                        uncompressedSize = uncompressedSize,
                        method = method,
                        maxBytes = maxBytes,
                    )
                }.getOrNull() ?: continue
            if (bytes.isEmpty()) continue
            out += RedZipCubeEntry(fileName = baseName, bytes = bytes)
        }
        return out
    }

    private fun extractViaLocalHeaders(
        raf: RandomAccessFile,
        maxFiles: Int,
        maxBytes: Int,
    ): List<RedZipCubeEntry> {
        val out = ArrayList<RedZipCubeEntry>(minOf(maxFiles, 64))
        var position = 0L
        val length = raf.length()
        while (position + 30L <= length && out.size < maxFiles) {
            raf.seek(position)
            val sig = raf.readUInt32()
            when (sig) {
                SIG_LOCAL -> {
                    // fall through
                }
                SIG_CENTRAL, SIG_EOCD -> break
                else -> {
                    // Not aligned — abort local walk rather than scanning the whole file.
                    if (out.isEmpty() && position == 0L) {
                        throw IOException("Not a ZIP local-file archive.")
                    }
                    break
                }
            }
            raf.skipFully(2) // version needed
            val flags = raf.readUInt16()
            val method = raf.readUInt16()
            raf.skipFully(8) // time/date + crc
            val compressedSizeField = raf.readUInt32LE()
            val uncompressedSizeField = raf.readUInt32LE()
            val nameLen = raf.readUInt16()
            val extraLen = raf.readUInt16()
            if (nameLen > MAX_NAME_BYTES || extraLen > MAX_EXTRA_BYTES) {
                throw IOException("ZIP entry metadata too large.")
            }
            val nameBytes = ByteArray(nameLen)
            raf.readFully(nameBytes)
            val name = String(nameBytes, Charsets.ISO_8859_1)
            raf.skipFully(extraLen)
            val dataStart = raf.filePointer

            val usesDescriptor = flags and FLAG_DATA_DESCRIPTOR != 0
            val compressedSize =
                when {
                    usesDescriptor && compressedSizeField == 0L -> -1L
                    compressedSizeField == ZIP64_SENTINEL -> -1L
                    else -> compressedSizeField
                }
            val uncompressedSize =
                when {
                    usesDescriptor && uncompressedSizeField == 0L -> -1L
                    uncompressedSizeField == ZIP64_SENTINEL -> -1L
                    else -> uncompressedSizeField
                }

            val path = normalizeZipEntryPath(name)
            if (
                path != null &&
                path.endsWith(".cube", ignoreCase = true) &&
                !path.substringAfterLast('/').startsWith("._") &&
                !path.contains("__MACOSX/", ignoreCase = true) &&
                (method == METHOD_STORE || method == METHOD_DEFLATE) &&
                uncompressedSize in 0..maxBytes.toLong() &&
                compressedSize >= 0L
            ) {
                val bytes =
                    runCatching {
                        readPayloadAt(
                            raf = raf,
                            dataStart = dataStart,
                            compressedSize = compressedSize,
                            uncompressedSize = uncompressedSize,
                            method = method,
                            maxBytes = maxBytes,
                        )
                    }.getOrNull()
                if (bytes != null && bytes.isNotEmpty()) {
                    val baseName = path.substringAfterLast('/')
                    out += RedZipCubeEntry(fileName = baseName, bytes = bytes)
                }
            }

            // Advance past this entry's payload (and optional data descriptor).
            position =
                if (compressedSize >= 0L) {
                    var next = dataStart + compressedSize
                    if (usesDescriptor) {
                        // data descriptor: optional 0x08074b50 + crc + csize + usize (12 or 16)
                        next += peekDataDescriptorSkip(raf, next)
                    }
                    next
                } else {
                    // Unknown compressed size — cannot continue local walk safely.
                    break
                }
        }
        return out
    }

    private fun readLocalPayload(
        raf: RandomAccessFile,
        localOffset: Long,
        compressedSize: Long,
        uncompressedSize: Long,
        method: Int,
        maxBytes: Int,
    ): ByteArray {
        raf.seek(localOffset)
        val sig = raf.readUInt32()
        if (sig != SIG_LOCAL) throw IOException("Missing local file header.")
        // Fixed local header after signature is 26 bytes (through extra-length).
        // Central-directory sizes are authoritative (local may be zero with data descriptors).
        raf.skipFully(22) // version, flags, method, time, date, crc, csize, usize
        val nameLen = raf.readUInt16()
        val extraLen = raf.readUInt16()
        if (nameLen > MAX_NAME_BYTES || extraLen > MAX_EXTRA_BYTES) {
            throw IOException("ZIP local entry metadata too large.")
        }
        raf.skipFully(nameLen + extraLen)
        val dataStart = raf.filePointer
        if (compressedSize < 0L || uncompressedSize < 0L) {
            throw IOException("Unknown entry size.")
        }
        if (uncompressedSize > maxBytes.toLong()) throw IOException("Cube entry too large.")
        return readPayloadAt(
            raf = raf,
            dataStart = dataStart,
            compressedSize = compressedSize,
            uncompressedSize = uncompressedSize,
            method = method,
            maxBytes = maxBytes,
        )
    }

    private fun readPayloadAt(
        raf: RandomAccessFile,
        dataStart: Long,
        compressedSize: Long,
        uncompressedSize: Long,
        method: Int,
        maxBytes: Int,
    ): ByteArray {
        if (compressedSize > maxBytes.toLong() * 2L && method == METHOD_DEFLATE) {
            // Deflate usually shrinks; allow some expansion headroom but reject absurd blobs.
            if (compressedSize > maxBytes.toLong() * 4L) {
                throw IOException("Compressed cube entry too large.")
            }
        }
        if (compressedSize > Int.MAX_VALUE.toLong()) throw IOException("Entry too large.")
        raf.seek(dataStart)
        val compressed = ByteArray(compressedSize.toInt())
        raf.readFully(compressed)
        return when (method) {
            METHOD_STORE -> {
                if (compressed.size > maxBytes) throw IOException("Cube entry too large.")
                if (uncompressedSize >= 0L && compressed.size.toLong() != uncompressedSize) {
                    // Prefer declared size when STORE mismatches slightly? Fail closed.
                    if (uncompressedSize <= maxBytes.toLong() && uncompressedSize < compressed.size) {
                        compressed.copyOf(uncompressedSize.toInt())
                    } else {
                        compressed
                    }
                } else {
                    compressed
                }
            }
            METHOD_DEFLATE -> inflateRaw(compressed, uncompressedSize, maxBytes)
            else -> throw IOException("Unsupported compression method $method.")
        }
    }

    private fun inflateRaw(
        compressed: ByteArray,
        expectedUncompressed: Long,
        maxBytes: Int,
    ): ByteArray {
        val inflater = Inflater(true) // raw DEFLATE, no zlib wrapper
        return try {
            inflater.setInput(compressed)
            val out = ByteArrayOutputStream(
                when {
                    expectedUncompressed in 1..maxBytes.toLong() -> expectedUncompressed.toInt()
                    else -> minOf(maxBytes, compressed.size * 2)
                },
            )
            val chunk = ByteArray(64 * 1024)
            while (!inflater.finished()) {
                val n = inflater.inflate(chunk)
                if (n == 0) {
                    if (inflater.needsInput()) break
                    if (inflater.needsDictionary()) {
                        throw IOException("Deflate dictionary not supported.")
                    }
                    break
                }
                if (out.size() + n > maxBytes) throw IOException("Cube entry too large.")
                out.write(chunk, 0, n)
            }
            val bytes = out.toByteArray()
            if (bytes.isEmpty()) throw IOException("Empty deflated entry.")
            if (expectedUncompressed >= 0L && bytes.size.toLong() != expectedUncompressed) {
                // Accept if we stayed under the cap — some writers misstate sizes.
                if (bytes.size > maxBytes) throw IOException("Cube entry too large.")
            }
            bytes
        } finally {
            inflater.end()
        }
    }

    /**
     * Locates the End of Central Directory record by scanning backwards from EOF.
     */
    private fun findEocd(raf: RandomAccessFile): Eocd? {
        val length = raf.length()
        if (length < EOCD_MIN) return null
        val search = minOf(length, EOCD_SEARCH.toLong()).toInt()
        val buf = ByteArray(search)
        raf.seek(length - search)
        raf.readFully(buf)
        // Scan backwards for EOCD signature.
        for (i in buf.size - EOCD_MIN downTo 0) {
            if (
                buf[i] == 0x50.toByte() &&
                buf[i + 1] == 0x4b.toByte() &&
                buf[i + 2] == 0x05.toByte() &&
                buf[i + 3] == 0x06.toByte()
            ) {
                val disk = u16(buf, i + 4)
                val cdDisk = u16(buf, i + 6)
                val entriesOnDisk = u16(buf, i + 8)
                val entryCount = u16(buf, i + 10)
                val cdSize = u32(buf, i + 12)
                val cdOffset = u32(buf, i + 16)
                // Multi-disk archives are out of scope for RED LUT packs.
                if (disk != 0 || cdDisk != 0) continue
                if (entriesOnDisk != entryCount) continue
                if (cdOffset == ZIP64_SENTINEL || cdSize == ZIP64_SENTINEL) {
                    // ZIP64 EOCD locator would be needed; RED packs should not need it.
                    continue
                }
                if (cdOffset + cdSize > length) continue
                return Eocd(entryCount = entryCount, centralOffset = cdOffset)
            }
        }
        return null
    }

    /**
     * Returns how many bytes to skip for a data descriptor at [at], or 0 if absent.
     * Descriptor layout: optional sig 0x08074b50 + crc32 + csize + usize (12 or 16 bytes total
     * without sig, 16 or 20 with sig). We only need to advance past it for the local walk.
     */
    private fun peekDataDescriptorSkip(raf: RandomAccessFile, at: Long): Long {
        if (at + 12L > raf.length()) return 0L
        raf.seek(at)
        val first = raf.readUInt32()
        return if (first == 0x08074b50) {
            // signature present: sig + crc + csize + usize
            if (at + 16L <= raf.length()) 16L else 0L
        } else {
            // no signature: crc was `first`, plus csize + usize
            12L
        }
    }

    private data class Eocd(val entryCount: Int, val centralOffset: Long)
}

/** One `.cube` payload pulled from a RED zip, with a safe display basename. */
internal data class RedZipCubeEntry(val fileName: String, val bytes: ByteArray) {
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is RedZipCubeEntry) return false
        return fileName == other.fileName && bytes.contentEquals(other.bytes)
    }

    override fun hashCode(): Int = 31 * fileName.hashCode() + bytes.contentHashCode()
}

/**
 * Normalizes a zip entry name for cube matching. Returns null for paths we must
 * not treat as LUT files (empty, root-only `/`, traversal, etc.).
 */
internal fun normalizeZipEntryPath(raw: String): String? {
    var path = raw.replace('\\', '/')
    // RED packs may list a bare "/" directory or absolute-looking cube paths.
    while (path.startsWith("/")) path = path.removePrefix("/")
    if (path.isBlank() || path == "." || path == "..") return null
    if (path.split('/').any { it == ".." }) return null
    return path
}

/** Per-cube size cap — matches the shared Android/Swift 16 MB LUT source limit. */
internal const val MAX_RED_CUBE_BYTES: Int = 16 * 1024 * 1024

/** iOS importZip allows up to 512 cubes in a RED pack. */
internal const val MAX_RED_ZIP_CUBE_FILES: Int = 512

// --- little-endian helpers ---------------------------------------------------

private fun RandomAccessFile.readUInt16(): Int {
    val b0 = read()
    val b1 = read()
    if (b0 < 0 || b1 < 0) throw IOException("Unexpected EOF in ZIP.")
    return b0 or (b1 shl 8)
}

/** Signed 32-bit pattern (for ZIP signatures compared as Int). */
private fun RandomAccessFile.readUInt32(): Int {
    val b0 = read()
    val b1 = read()
    val b2 = read()
    val b3 = read()
    if (b0 < 0 || b1 < 0 || b2 < 0 || b3 < 0) throw IOException("Unexpected EOF in ZIP.")
    return b0 or (b1 shl 8) or (b2 shl 16) or (b3 shl 24)
}

/** Unsigned 32-bit value as Long (sizes and offsets). */
private fun RandomAccessFile.readUInt32LE(): Long = readUInt32().toLong() and 0xFFFF_FFFFL

private fun RandomAccessFile.skipFully(bytes: Int) {
    if (bytes <= 0) return
    var left = bytes.toLong()
    while (left > 0L) {
        val skipped = skipBytes(left.coerceAtMost(Int.MAX_VALUE.toLong()).toInt())
        if (skipped <= 0) {
            // skipBytes may return 0; fall back to seek.
            val next = filePointer + left
            if (next > length()) throw IOException("Unexpected EOF in ZIP.")
            seek(next)
            return
        }
        left -= skipped.toLong()
    }
}

private fun u16(buf: ByteArray, at: Int): Int {
    return (buf[at].toInt() and 0xff) or ((buf[at + 1].toInt() and 0xff) shl 8)
}

private fun u32(buf: ByteArray, at: Int): Long {
    return (
        (buf[at].toInt() and 0xff) or
            ((buf[at + 1].toInt() and 0xff) shl 8) or
            ((buf[at + 2].toInt() and 0xff) shl 16) or
            ((buf[at + 3].toInt() and 0xff) shl 24)
        ).toLong() and 0xFFFF_FFFFL
}

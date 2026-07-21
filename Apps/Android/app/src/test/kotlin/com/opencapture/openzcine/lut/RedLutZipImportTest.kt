package com.opencapture.openzcine.lut

import java.io.ByteArrayOutputStream
import java.util.zip.CRC32
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import org.junit.Rule
import org.junit.rules.TemporaryFolder

class RedLutZipImportTest {
    @get:Rule
    val temp = TemporaryFolder()

    @Test
    fun `looksLikeZipArchive detects local file headers and rejects html`() {
        val zip = temp.newFile("ok.zip")
        ZipOutputStream(zip.outputStream()).use { out ->
            out.putNextEntry(ZipEntry("REC709/Look.cube"))
            out.write(MINIMAL_CUBE.toByteArray())
            out.closeEntry()
        }
        assertTrue(zip.looksLikeZipArchive())

        val html = temp.newFile("page.html")
        html.writeText("<!DOCTYPE html><html><body>nope</body></html>")
        assertFalse(html.looksLikeZipArchive())
    }

    @Test
    fun `extractCubeEntriesFromZip finds nested cubes and skips mac junk`() {
        val zip = temp.newFile("nested.zip")
        ZipOutputStream(zip.outputStream()).use { out ->
            out.putNextEntry(ZipEntry("pack/REC709/A.cube"))
            out.write(MINIMAL_CUBE.toByteArray())
            out.closeEntry()
            out.putNextEntry(ZipEntry("__MACOSX/._A.cube"))
            out.write(byteArrayOf(0, 1, 2))
            out.closeEntry()
            out.putNextEntry(ZipEntry("pack/README.txt"))
            out.write("notes".toByteArray())
            out.closeEntry()
        }
        assertTrue(zip.looksLikeZipArchive())
        val cubes = extractCubeEntriesFromZip(zip)
        assertEquals(1, cubes.size)
        assertEquals("A.cube", cubes.single().fileName)
        assertTrue(cubes.single().bytes.isNotEmpty())
    }

    @Test
    fun `normalizeZipEntryPath strips absolute roots and rejects traversal`() {
        assertEquals("REC709/Look.cube", normalizeZipEntryPath("/REC709/Look.cube"))
        assertEquals(null, normalizeZipEntryPath("/"))
        assertEquals(null, normalizeZipEntryPath("../evil.cube"))
        assertEquals("ok/Look.cube", normalizeZipEntryPath("ok/Look.cube"))
    }

    @Test
    fun `extractCubeEntriesFromZip accepts absolute-looking cube paths`() {
        // RED packs use leading-slash entry names that make Android 14+
        // ZipFile/ZipInputStream throw "invalid zip entry path: /".
        val zip = temp.newFile("abs.zip")
        ZipOutputStream(zip.outputStream()).use { out ->
            out.putNextEntry(ZipEntry("/REC709/Abs.cube"))
            out.write(MINIMAL_CUBE.toByteArray())
            out.closeEntry()
        }
        val cubes = extractCubeEntriesFromZip(zip)
        assertEquals(1, cubes.size)
        assertEquals("Abs.cube", cubes.single().fileName)
        assertEquals(MINIMAL_CUBE, String(cubes.single().bytes))
    }

    @Test
    fun `extractCubeEntriesFromZip skips bare root entry and still finds cubes`() {
        // Hand-built archive: directory entry named "/" plus a nested cube.
        // This is the shape that surfaces "invalid zip entry path: /" on device.
        val cubeBytes = MINIMAL_CUBE.toByteArray()
        val zip = temp.newFile("root-slash.zip")
        zip.writeBytes(buildZipWithRootSlashAndCube(cubeBytes, "REC709/Root.cube"))
        assertTrue(zip.looksLikeZipArchive())

        val cubes = extractCubeEntriesFromZip(zip)
        assertEquals(1, cubes.size)
        assertEquals("Root.cube", cubes.single().fileName)
        assertEquals(MINIMAL_CUBE, String(cubes.single().bytes))
    }

    @Test
    fun `extractCubeEntriesFromZip inflates deflated cube entries`() {
        val cubeBytes = MINIMAL_CUBE.toByteArray()
        val zip = temp.newFile("deflated.zip")
        ZipOutputStream(zip.outputStream()).use { out ->
            val entry = ZipEntry("Looks/Deflated.cube")
            entry.method = ZipEntry.DEFLATED
            out.putNextEntry(entry)
            out.write(cubeBytes)
            out.closeEntry()
        }
        val cubes = extractCubeEntriesFromZip(zip)
        assertEquals(1, cubes.size)
        assertEquals("Deflated.cube", cubes.single().fileName)
        assertEquals(MINIMAL_CUBE, String(cubes.single().bytes))
    }

    @Test
    fun `extractCubeEntriesFromZip handles multiple cubes with mixed path styles`() {
        val zip = temp.newFile("mixed.zip")
        ZipOutputStream(zip.outputStream()).use { out ->
            out.putNextEntry(ZipEntry("/"))
            out.closeEntry()
            out.putNextEntry(ZipEntry("/REC709/One.cube"))
            out.write(MINIMAL_CUBE.toByteArray())
            out.closeEntry()
            out.putNextEntry(ZipEntry("Log3G10/Two.cube"))
            out.write(MINIMAL_CUBE.toByteArray())
            out.closeEntry()
        }
        val cubes = extractCubeEntriesFromZip(zip)
        assertEquals(2, cubes.size)
        assertEquals(setOf("One.cube", "Two.cube"), cubes.map { it.fileName }.toSet())
    }

    @Test
    fun `sanitizeCubeFileName strips path and unsafe characters`() {
        assertEquals("Look.cube", sanitizeCubeFileName("/REC709/Look.cube"))
        assertEquals("Bad_name.cube", sanitizeCubeFileName("Bad name.cube"))
        assertEquals("lut.cube", sanitizeCubeFileName("///"))
    }

    companion object {
        private val MINIMAL_CUBE =
            """
            TITLE "Test"
            LUT_3D_SIZE 2
            0 0 0
            1 0 0
            0 1 0
            1 1 0
            0 0 1
            1 0 1
            0 1 1
            1 1 1
            """.trimIndent()

        /**
         * Builds a minimal ZIP whose first central/local entry is the bare name
         * `/` (directory) followed by a STORED cube. Avoids ZipOutputStream
         * rewriting of absolute entry names so the on-disk bytes match RED's
         * observed layout as closely as possible.
         */
        private fun buildZipWithRootSlashAndCube(
            cubeBytes: ByteArray,
            cubeEntryName: String,
        ): ByteArray {
            val out = ByteArrayOutputStream()
            val localRecords = ArrayList<LocalRecord>()

            // Entry 1: bare "/" directory (stored, empty).
            localRecords += writeLocalStored(out, name = "/", data = ByteArray(0))
            // Entry 2: cube payload (stored).
            localRecords += writeLocalStored(out, name = cubeEntryName, data = cubeBytes)

            val centralOffset = out.size()
            for (record in localRecords) {
                writeCentralStored(out, record)
            }
            val centralSize = out.size() - centralOffset
            writeEocd(out, entryCount = localRecords.size, centralSize = centralSize, centralOffset = centralOffset)
            return out.toByteArray()
        }

        private data class LocalRecord(
            val name: String,
            val data: ByteArray,
            val localOffset: Int,
            val crc: Long,
        )

        private fun writeLocalStored(
            out: ByteArrayOutputStream,
            name: String,
            data: ByteArray,
        ): LocalRecord {
            val nameBytes = name.toByteArray(Charsets.ISO_8859_1)
            val offset = out.size()
            val crc = CRC32().also { it.update(data) }.value
            // local file header
            writeInt(out, 0x04034b50)
            writeShort(out, 20) // version needed
            writeShort(out, 0) // flags
            writeShort(out, 0) // store
            writeShort(out, 0) // time
            writeShort(out, 0) // date
            writeInt(out, crc.toInt())
            writeInt(out, data.size)
            writeInt(out, data.size)
            writeShort(out, nameBytes.size)
            writeShort(out, 0) // extra
            out.write(nameBytes)
            out.write(data)
            return LocalRecord(name = name, data = data, localOffset = offset, crc = crc)
        }

        private fun writeCentralStored(out: ByteArrayOutputStream, record: LocalRecord) {
            val nameBytes = record.name.toByteArray(Charsets.ISO_8859_1)
            writeInt(out, 0x02014b50)
            writeShort(out, 20) // version made by
            writeShort(out, 20) // version needed
            writeShort(out, 0) // flags
            writeShort(out, 0) // store
            writeShort(out, 0) // time
            writeShort(out, 0) // date
            writeInt(out, record.crc.toInt())
            writeInt(out, record.data.size)
            writeInt(out, record.data.size)
            writeShort(out, nameBytes.size)
            writeShort(out, 0) // extra
            writeShort(out, 0) // comment
            writeShort(out, 0) // disk start
            writeShort(out, 0) // internal attrs
            writeInt(out, 0) // external attrs
            writeInt(out, record.localOffset)
            out.write(nameBytes)
        }

        private fun writeEocd(
            out: ByteArrayOutputStream,
            entryCount: Int,
            centralSize: Int,
            centralOffset: Int,
        ) {
            writeInt(out, 0x06054b50)
            writeShort(out, 0) // disk
            writeShort(out, 0) // cd disk
            writeShort(out, entryCount)
            writeShort(out, entryCount)
            writeInt(out, centralSize)
            writeInt(out, centralOffset)
            writeShort(out, 0) // comment
        }

        private fun writeShort(out: ByteArrayOutputStream, value: Int) {
            out.write(value and 0xff)
            out.write((value ushr 8) and 0xff)
        }

        private fun writeInt(out: ByteArrayOutputStream, value: Int) {
            out.write(value and 0xff)
            out.write((value ushr 8) and 0xff)
            out.write((value ushr 16) and 0xff)
            out.write((value ushr 24) and 0xff)
        }
    }
}

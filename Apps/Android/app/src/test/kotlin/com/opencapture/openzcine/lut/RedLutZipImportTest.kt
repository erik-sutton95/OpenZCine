package com.opencapture.openzcine.lut

import java.io.File
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream
import kotlin.test.Test
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
    fun `zip with nested cubes is openable by ZipFile`() {
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
        java.util.zip.ZipFile(zip).use { archive ->
            val cubes =
                archive.entries().asSequence()
                    .filter { !it.isDirectory }
                    .map { it.name.replace('\\', '/') }
                    .filter { it.endsWith(".cube", ignoreCase = true) }
                    .filter { !it.contains("__MACOSX/") }
                    .filter { !it.substringAfterLast('/').startsWith("._") }
                    .toList()
            assertTrue(cubes == listOf("pack/REC709/A.cube"))
        }
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
    }
}

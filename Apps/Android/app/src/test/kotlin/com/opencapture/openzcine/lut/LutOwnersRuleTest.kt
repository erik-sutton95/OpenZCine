package com.opencapture.openzcine.lut

import java.nio.file.Files
import java.nio.file.Path
import kotlin.io.path.name
import kotlin.io.path.readText
import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * The custom LUT library is OpenCine's `MonitorLutLibrary` and its import gate the shared
 * `CubeLUT.validatedImport` (A4-27); this app keeps only the RED source adapter. The RED download
 * is the shared LUT pack flow (`MonitorLutPackDownloadScreen`, `MonitorLutArchive`) with RED's page,
 * hosts, scripts and words; the app draws no download page, web view or zip reader of its own.
 */
class LutOwnersRuleTest {
    private val sources = Path.of(requireNotNull(System.getProperty("openzcine.repositoryRoot")))
        .resolve("Apps/Android/app/src/main/kotlin")

    private fun sourcesContaining(token: String): List<String> = Files.walk(sources).use { paths ->
        paths.filter { it.name.endsWith(".kt") && token in it.readText() }.map(Path::name).sorted().toList()
    }

    @Test
    fun noLutStoreOrImportGateOfItsOwn() {
        for (token in listOf("class StoredLutLibrary", "class AndroidLutLibrary", "fun importCustom(", "validateImportedLut")) {
            assertEquals(emptyList(), sourcesContaining(token), token)
        }
    }

    @Test
    fun redDownloadIsTheSharedPackFlow() {
        val screen = sources.resolve("com/opencapture/openzcine/lut/RedLutDownloadScreen.kt").readText()
        assertEquals(true, "MonitorLutPackDownloadScreen(" in screen, "RED download must open the shared pack flow")
        for (token in listOf("WebView(", "RandomAccessFile", "Inflater", "TextButton(", ".clickable(")) {
            assertEquals(emptyList(), sourcesContaining(token).filter { it.startsWith("Red") }, token)
        }
    }
}

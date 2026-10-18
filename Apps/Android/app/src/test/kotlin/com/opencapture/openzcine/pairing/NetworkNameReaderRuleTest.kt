package com.opencapture.openzcine.pairing

import java.nio.file.Files
import java.nio.file.Path
import kotlin.io.path.name
import kotlin.io.path.readText
import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * [ConnectedNetworkName] is the one reader of the joined Wi-Fi network's name (A4-40: the camera
 * access point check read it on its own through the deprecated `WifiManager.connectionInfo`).
 */
class NetworkNameReaderRuleTest {
    @Test
    fun onlyConnectedNetworkNameReadsTheNetworkName() {
        val sources = Path.of(requireNotNull(System.getProperty("openzcine.repositoryRoot")))
            .resolve("Apps/Android/app/src/main/kotlin")
        val readers = Files.walk(sources).use { paths ->
            paths.filter { path ->
                path.name.endsWith(".kt") && path.readText().let { "connectionInfo" in it || "transportInfo" in it }
            }.map(Path::name).sorted().toList()
        }
        assertEquals(listOf("ConnectedNetworkName.kt"), readers)
    }
}

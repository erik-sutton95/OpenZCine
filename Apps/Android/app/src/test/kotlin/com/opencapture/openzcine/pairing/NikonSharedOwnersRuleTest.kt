package com.opencapture.openzcine.pairing

import java.nio.file.Files
import java.nio.file.Path
import kotlin.io.path.name
import kotlin.io.path.readText
import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * What OpenCine owns, this app only calls: the camera access-point join and Wi-Fi lock (platform,
 * A4-22), the Nikon network and saved-setup policies (nikon module, pinned to Swift by vectors,
 * A4-23), and the saved records' codec, written by one store (A4-24).
 */
class NikonSharedOwnersRuleTest {
    private fun sourcesContaining(token: String): List<String> {
        val sources = Path.of(requireNotNull(System.getProperty("openzcine.repositoryRoot")))
            .resolve("Apps/Android/app/src/main/kotlin")
        return Files.walk(sources).use { paths ->
            paths.filter { it.name.endsWith(".kt") && token in it.readText() }.map(Path::name).sorted().toList()
        }
    }

    @Test
    fun noCameraAccessPointJoinOrWifiLockOfItsOwn() {
        for (token in listOf("WifiNetworkSpecifier", "bindProcessToNetwork", "createWifiLock(", "CameraApAvailabilityTracker")) {
            assertEquals(emptyList(), sourcesContaining(token), token)
        }
    }

    @Test
    fun noKotlinTwinOfASwiftNikonPolicy() {
        for (token in listOf(
            "fun looksLikeNikonAccessPointSsid", "fun isDialableHost", "fun subnetBase", "fun pendingAccessPointHostKey",
            "fun classifyMiss", "class InfrastructureSweepTally", "fun canonicalized",
        )) {
            assertEquals(emptyList(), sourcesContaining(token), token)
        }
    }

    @Test
    fun oneCodecAndOneWriterForTheSavedRecords() {
        // The record keys live in OpenCine's NikonSavedRecordsV0 only.
        assertEquals(emptyList(), sourcesContaining("\"camera-name\""))
        assertEquals(listOf("SavedCameraStore.kt"), sourcesContaining("RECORDS_KEY"))
    }
}

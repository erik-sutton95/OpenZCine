package com.opencapture.openzcine.media

import java.nio.file.Files
import java.nio.file.Path
import kotlin.io.path.name
import kotlin.io.path.readText
import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * A star rating on the card is the operator's data. Only the explicit star controls (the still
 * viewer's and the player's rating shade) may write it; the favorite heart stays a local flag and
 * never writes a rating (A4-04: the heart wrote 1 or 0 over real ratings).
 */
class CameraRatingWriteRuleTest {
    @Test
    fun onlyTheStarControlsWriteACameraRating() {
        val sources = Path.of(requireNotNull(System.getProperty("openzcine.repositoryRoot")))
            .resolve("Apps/Android/app/src/main/kotlin")
        val writers = Files.walk(sources).use { paths ->
            paths.filter { it.name.endsWith(".kt") && "sessionSetObjectRating(" in it.readText() }
                .map(Path::name).sorted().toList()
        }
        assertEquals(listOf("MediaPlaybackScreen.kt", "MediaStillViewer.kt"), writers)
    }
}

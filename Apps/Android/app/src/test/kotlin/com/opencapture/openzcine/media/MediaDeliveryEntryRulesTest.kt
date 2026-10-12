package com.opencapture.openzcine.media

import java.nio.file.Files
import java.nio.file.Path
import kotlin.io.path.extension
import kotlin.io.path.readText
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * A4-18: stills and clips share through one entry, the shared delivery popup, and the root
 * chrome presents the chooser. No Z media source launches its own share intent.
 */
class MediaDeliveryEntryRulesTest {
    private val media = Path.of(
        requireNotNull(System.getProperty("openzcine.repositoryRoot")) {
            "Gradle must expose the OpenZCine repository root to source rule tests"
        },
    ).resolve("Apps/Android/app/src/main/kotlin/com/opencapture/openzcine/media")

    @Test
    fun `no media source launches its own share chooser`() {
        val offenders = Files.walk(media).use { paths ->
            paths.filter { it.extension == "kt" }.toList().filter { file ->
                val text = file.readText()
                listOf("createChooser", "ACTION_SEND", "startActivity(").any(text::contains)
            }.map { it.fileName.toString() }
        }
        assertEquals(emptyList(), offenders)
    }

    @Test
    fun `the still viewer opens the delivery popup the clips use`() {
        val viewer = media.resolve("MediaStillViewer.kt").readText()
        val browse = media.resolve("MediaBrowseScreen.kt").readText()
        assertTrue("onShare" in viewer)
        assertTrue("presentStillDelivery" in browse && "mediaDelivery.selection(" in browse)
    }
}

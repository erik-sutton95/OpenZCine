package com.opencapture.openzcine.media

import java.nio.file.Files
import java.nio.file.Path
import kotlin.io.path.name
import kotlin.io.path.readText
import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * The gallery, its player and photo pages, Back order and selection behave like Pocket and Insta
 * because Z composes the one shared media host (A4-13) and overrides none of its selection
 * defaults (A4-16) or its Back order (A4-31).
 */
class MediaHostRuleTest {
    private val sources: Map<String, String> = Files.walk(
        Path.of(requireNotNull(System.getProperty("openzcine.repositoryRoot"))).resolve("Apps/Android/app/src/main/kotlin"),
    ).use { paths -> paths.filter { it.name.endsWith(".kt") }.toList().associate { it.name to it.readText() } }

    private fun filesUsing(token: String): List<String> = sources.filterValues { token in it }.keys.sorted()

    @Test
    fun theSharedHostOwnsTheCatalogAndItsBackOrder() {
        assertEquals(emptyList(), filesUsing("MonitorOperatorCatalogScreen("))
        assertEquals(listOf("MediaBrowseScreen.kt"), filesUsing("MonitorOperatorMediaScreen("))
        assertEquals(false, "BackHandler" in sources.getValue("MediaBrowseScreen.kt"))
    }

    @Test
    fun selectionKeepsTheSharedGestureHapticAndClearingDefaults() {
        listOf("selectionConfiguration", "selectionChanged", "MonitorMediaSelectionConfiguration(",
            "navigationClearsSelection", "filterClearsSelection", "retainsVisibleSelection").forEach { override ->
            assertEquals(emptyList(), filesUsing(override), override)
        }
    }
}

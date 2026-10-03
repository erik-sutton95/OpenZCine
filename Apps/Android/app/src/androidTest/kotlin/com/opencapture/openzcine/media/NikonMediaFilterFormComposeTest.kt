package com.opencapture.openzcine.media

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.platform.LocalViewConfiguration
import androidx.compose.ui.unit.DpSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.test.click
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.assertIsSelected
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performTouchInput
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.opencapture.monitorui.MonitorMediaColorOption
import com.opencapture.monitorui.MonitorMediaFilterChipLayout
import com.opencapture.monitorui.MonitorMediaFilterChoice
import com.opencapture.monitorui.MonitorMediaFilterForm
import com.opencapture.monitorui.MonitorMediaStorageChoices
import com.opencapture.openzcine.OpenZCineTheme
import java.time.LocalDate
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** SIMULATED listed facts with the actual native Nikon dialog and shared form. */
@RunWith(AndroidJUnit4::class)
class NikonMediaFilterFormComposeTest {
    @get:Rule
    val composeRule = createComposeRule()

    @Test
    fun legacyDefaultCalendarColourAndClearActionsRemainReachable() {
        var formats by mutableStateOf(emptySet<String>())
        var colours by mutableStateOf(emptySet<Int>())
        val picks = mutableListOf<String>()
        composeRule.setContent {
            OpenZCineTheme {
                MonitorMediaFilterForm(
                    formats = listOf("MOV", "MP4"), resolutions = listOf("4K"),
                    colors = listOf(MonitorMediaColorOption(9, "LOG")),
                    formatSelection = formats, resolutionSelection = emptySet(), colorSelection = colours,
                    dateStartLabel = null, dateEndLabel = null, hasDates = true,
                    onToggleFormat = { formats = if (it in formats) formats - it else formats + it },
                    onToggleResolution = {},
                    onToggleColor = { colours = if (it in colours) colours - it else colours + it },
                    onPickStart = { picks += "start" }, onPickEnd = { picks += "end" },
                    onClear = { formats = emptySet(); colours = emptySet() },
                )
            }
        }
        composeRule.onNodeWithContentDescription("Start").performTouchInput { click() }
        composeRule.onNodeWithContentDescription("End").performTouchInput { click() }
        composeRule.onNodeWithText("MOV").performTouchInput { click() }
        composeRule.onNodeWithText("MOV").assertIsSelected()
        composeRule.onNodeWithText("LOG").performTouchInput { click() }
        composeRule.onNodeWithText("LOG").assertIsSelected()
        composeRule.runOnIdle { assertEquals(listOf("start", "end"), picks) }
        composeRule.onNodeWithText("SIZE").assertDoesNotExist()
        composeRule.onNodeWithText("STORAGE").assertDoesNotExist()
        composeRule.onNodeWithText("Clear all filters").performTouchInput { click() }
        composeRule.runOnIdle {
            assertTrue(formats.isEmpty())
            assertTrue(colours.isEmpty())
        }
        composeRule.onNodeWithText("Clear all filters").assertDoesNotExist()
    }

    @Test
    fun actualNikonDialogComposesSetsRelativeWindowsAndLosslessCardIds() {
        var filters by mutableStateOf(MediaLibraryFilters())
        var presented by mutableStateOf(true)
        val clips = listOf(
            clip(1, "A.MOV", 1920, "20260715T120000", FIRST),
            clip(2, "B.MP4", 3840, "20260401T120000", SECOND),
            clip(3, "L.JPG", 6048, "20260715T120000", FIRST, "JPEG"),
            clip(4, "M.TIF", 4032, "20260401T120000", SECOND, "TIFF"),
        )
        val offered = MediaFilterDerivation.options(clips, TODAY)
        composeRule.setContent {
            OpenZCineTheme {
                if (presented) MediaFilterDialog(
                    filters, offered, listOf(FIRST, SECOND),
                    onFiltersChanged = { filters = it }, onDismiss = { presented = false },
                )
            }
        }
        touch("JPEG filter")
        touch("TIFF filter")
        assertResults(clips, filters, setOf("L.JPG", "M.TIF"))
        touch("L filter")
        assertResults(clips, filters, setOf("L.JPG"))
        touch("M filter")
        assertResults(clips, filters, setOf("L.JPG", "M.TIF"))
        touch("TODAY filter")
        assertResults(clips, filters, setOf("L.JPG"))
        touch("7 DAYS filter")
        composeRule.runOnIdle { assertEquals(MediaDateWindowFilter.LAST_7_DAYS, filters.dateWindow) }
        touch("7 DAYS filter")
        composeRule.runOnIdle { assertNull(filters.dateWindow) }
        touch("SLOT 2 filter")
        composeRule.runOnIdle { assertEquals(SECOND, filters.storageId) }
        assertResults(clips, filters, setOf("M.TIF"))
        touch("SLOT 2 filter")
        composeRule.runOnIdle { assertNull(filters.storageId) }
        composeRule.onNodeWithContentDescription("Start").assertDoesNotExist()
        composeRule.onNodeWithContentDescription("End").assertDoesNotExist()
        composeRule.onNodeWithText("COLOUR").assertDoesNotExist()
        composeRule.onNodeWithText("Clear all filters").assertDoesNotExist()
        composeRule.onNodeWithText("Clear all").performTouchInput { click() }
        composeRule.runOnIdle { assertEquals(MediaLibraryFilters(), filters) }
        composeRule.onNodeWithText("Clear all").assertIsNotEnabled()
        composeRule.onNodeWithText("Done").performTouchInput { click() }
        composeRule.runOnIdle { assertTrue(!presented) }
    }

    @Test
    fun actualNikonUnknownMetadataAndMissingCardsOfferNoInventedGroups() {
        val offered = MediaFilterDerivation.options(listOf(clip(1, "A.MOV", 0, "", FIRST)), TODAY)
        composeRule.setContent {
            OpenZCineTheme {
                MediaFilterDialog(MediaLibraryFilters(), offered, emptyList(), {}, {})
            }
        }
        composeRule.onNodeWithText("Nothing in this tab to filter by.").assertIsDisplayed()
        listOf("FORMAT", "RESOLUTION", "SIZE", "DATE", "COLOUR", "STORAGE").forEach {
            composeRule.onNodeWithText(it).assertDoesNotExist()
        }
        composeRule.onNodeWithContentDescription("Start").assertDoesNotExist()
        composeRule.onNodeWithContentDescription("End").assertDoesNotExist()
        composeRule.onNodeWithText("Clear all").assertIsNotEnabled()
        composeRule.onNodeWithText("Done").assertIsDisplayed()
    }

    @Test
    fun sharedStorageButtonsDispatchIdsEvenWhenTheirLabelsAreEqual() {
        var selected by mutableStateOf<String?>(null)
        composeRule.setContent {
            OpenZCineTheme {
                MonitorMediaFilterForm(
                    formats = emptyList(), resolutions = emptyList(), colors = emptyList(),
                    formatSelection = emptySet(), resolutionSelection = emptySet(), colorSelection = emptySet(),
                    dateStartLabel = null, dateEndLabel = null, hasDates = false,
                    onToggleFormat = {}, onToggleResolution = {}, onToggleColor = {},
                    onPickStart = {}, onPickEnd = {}, onClear = { selected = null },
                    storage = MonitorMediaStorageChoices(
                        options = listOf(
                            MonitorMediaFilterChoice("4294967295", "Card"),
                            MonitorMediaFilterChoice("17", "Card"),
                        ),
                        selectedId = selected,
                        onToggle = { selected = it.takeUnless { selected == it } },
                    ),
                )
            }
        }
        composeRule.onNodeWithTag("monitor.media.filter.storage.4294967295").performTouchInput { click() }
        composeRule.runOnIdle { assertEquals("4294967295", selected) }
        composeRule.onNodeWithTag("monitor.media.filter.storage.17").performTouchInput { click() }
        composeRule.runOnIdle { assertEquals("17", selected) }
        composeRule.onNodeWithTag("monitor.media.filter.storage.17").performTouchInput { click() }
        composeRule.runOnIdle { assertNull(selected) }
    }

    @Test
    fun compactHorizontalChoiceRetainsItsNativeTouchFloor() {
        var selected by mutableStateOf<String?>(null)
        composeRule.setContent {
            OpenZCineTheme {
                val original = LocalViewConfiguration.current
                CompositionLocalProvider(
                    LocalViewConfiguration provides object : androidx.compose.ui.platform.ViewConfiguration by original {
                        override val minimumTouchTargetSize = DpSize.Zero
                    },
                ) {
                    Box(Modifier.padding(32.dp)) {
                        MonitorMediaFilterForm(
                            formats = emptyList(), resolutions = emptyList(), colors = emptyList(),
                            formatSelection = emptySet(), resolutionSelection = emptySet(), colorSelection = emptySet(),
                            dateStartLabel = null, dateEndLabel = null, hasDates = false,
                            onToggleFormat = {}, onToggleResolution = {}, onToggleColor = {},
                            onPickStart = {}, onPickEnd = {}, onClear = {},
                            storage = MonitorMediaStorageChoices(
                                listOf(MonitorMediaFilterChoice("17", "Card")), selected,
                                { selected = it },
                            ),
                            chipLayout = MonitorMediaFilterChipLayout.HORIZONTAL_SCROLL,
                            showsInlineClear = false,
                        )
                    }
                }
            }
        }
        // The pointer lands above the drawn capsule, within its retained 44dp hit area.
        composeRule.onNodeWithTag("monitor.media.filter.storage.17").performTouchInput {
            click(Offset(center.x, -2.dp.toPx()))
        }
        composeRule.runOnIdle { assertEquals("17", selected) }
    }

    private fun touch(description: String) {
        composeRule.onNodeWithContentDescription(description).performScrollTo().performTouchInput { click() }
        composeRule.waitForIdle()
    }

    private fun assertResults(clips: List<MediaClipRecord>, filters: MediaLibraryFilters, expected: Set<String>) {
        composeRule.runOnIdle {
            val result = MediaLibraryFiltering.displayed(
                clips, MediaLibraryCategory.ALL, emptySet(), "SIMULATED-filter",
                MediaLibrarySortOrder.NAME, filters, TODAY,
            )
            assertEquals(expected, result.mapTo(linkedSetOf(), MediaClipRecord::filename))
        }
    }

    private fun clip(handle: Long, name: String, width: Int, date: String, storage: Long, format: String? = null) =
        MediaClipRecord(
            handle = handle, storageId = storage, sizeBytes = 1, captureDate = date,
            pixelWidth = width, pixelHeight = 1, filename = name,
            contentKind = if (format != null) MediaContentKind.STILL_PHOTO else MediaContentKind.PLAYABLE_PROXY,
            stillPhoto = format?.let { StillPhotoClassification(it, StillPreviewStrategy.PROGRESSIVE) },
        )

    private companion object {
        val TODAY: LocalDate = LocalDate.of(2026, 7, 15)
        const val FIRST = 0xF001_0001L
        const val SECOND = 0xF002_0001L
    }
}

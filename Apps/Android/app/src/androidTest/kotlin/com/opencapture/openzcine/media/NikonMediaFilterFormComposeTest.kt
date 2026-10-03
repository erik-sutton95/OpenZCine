package com.opencapture.openzcine.media

import android.graphics.Bitmap
import android.view.Surface
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toPixelMap
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalViewConfiguration
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.assertIsSelected
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.click
import androidx.compose.ui.test.hasAnyDescendant
import androidx.compose.ui.test.hasScrollAction
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.test.swipeWithVelocity
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.DpSize
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.UiDevice
import com.opencapture.monitorui.MonitorMediaColorOption
import com.opencapture.monitorui.MonitorMediaFilterChipLayout
import com.opencapture.monitorui.MonitorMediaFilterChoice
import com.opencapture.monitorui.MonitorMediaFilterForm
import com.opencapture.monitorui.MonitorMediaStorageChoices
import com.opencapture.openzcine.OpenZCineTheme
import java.io.File
import java.time.LocalDate
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** SIMULATED listed facts with the actual native Nikon dialog and shared form. */
@RunWith(AndroidJUnit4::class)
class NikonMediaFilterFormComposeTest {
    @get:Rule
    val composeRule = createComposeRule()

    @Before
    fun setExplicitNativeOrientation() {
        val device = UiDevice.getInstance(InstrumentationRegistry.getInstrumentation())
        val landscape = InstrumentationRegistry.getArguments().getString("filterOrientation") == "landscape"
        if (landscape) device.setOrientationLeft() else device.setOrientationNatural()
        device.waitForIdle()
        assertEquals(if (landscape) Surface.ROTATION_90 else Surface.ROTATION_0, device.displayRotation)
    }

    @After
    fun releaseNativeRotation() {
        val device = UiDevice.getInstance(InstrumentationRegistry.getInstrumentation())
        device.setOrientationNatural()
        device.unfreezeRotation()
    }

    @Test
    fun legacyDefaultCalendarColourAndClearActionsRemainReachable() {
        var formats by mutableStateOf(emptySet<String>())
        var colours by mutableStateOf(emptySet<Int>())
        val picks = mutableListOf<String>()
        composeRule.setContent {
            FilterFixtureHost {
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
        capture("default-calendar-colour")
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
            FilterFixtureHost {
                if (presented) MediaFilterDialog(
                    filters, offered, listOf(FIRST, SECOND),
                    onFiltersChanged = { filters = it }, onDismiss = { presented = false },
                )
            }
        }
        capture("nikon-initial")
        touch("JPEG filter")
        touch("TIFF filter")
        assertResults(clips, filters, setOf("L.JPG", "M.TIF"))
        touch("L filter")
        assertResults(clips, filters, setOf("L.JPG"))
        touch("M filter")
        assertResults(clips, filters, setOf("L.JPG", "M.TIF"))
        scrollFilterBodyUp()
        touch("TODAY filter")
        assertResults(clips, filters, setOf("L.JPG"))
        touch("7 DAYS filter")
        composeRule.runOnIdle { assertEquals(MediaDateWindowFilter.LAST_7_DAYS, filters.dateWindow) }
        touch("7 DAYS filter")
        composeRule.runOnIdle { assertNull(filters.dateWindow) }
        scrollFilterBodyUp()
        touch("SLOT 2 filter")
        composeRule.runOnIdle { assertEquals(SECOND, filters.storageId) }
        assertResults(clips, filters, setOf("M.TIF"))
        capture("nikon-selected")
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
            FilterFixtureHost {
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
            FilterFixtureHost {
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
        lateinit var nativeDensity: Density
        composeRule.setContent {
            FilterFixtureHost {
                nativeDensity = LocalDensity.current
                val original = LocalViewConfiguration.current
                CompositionLocalProvider(
                    LocalViewConfiguration provides object : androidx.compose.ui.platform.ViewConfiguration by original {
                        override val minimumTouchTargetSize = DpSize.Zero
                    },
                ) {
                    Box(Modifier.padding(32.dp).background(Color.Black)) {
                        MonitorMediaFilterForm(
                            formats = emptyList(), resolutions = emptyList(), colors = emptyList(),
                            formatSelection = emptySet(), resolutionSelection = emptySet(), colorSelection = emptySet(),
                            dateStartLabel = null, dateEndLabel = null, hasDates = false,
                            onToggleFormat = {}, onToggleResolution = {}, onToggleColor = {},
                            onPickStart = {}, onPickEnd = {}, onClear = {},
                            storage = MonitorMediaStorageChoices(
                                listOf(MonitorMediaFilterChoice("17", "L")), selected,
                                { selected = it.takeUnless { selected == it } },
                            ),
                            chipLayout = MonitorMediaFilterChipLayout.HORIZONTAL_SCROLL,
                            showsInlineClear = false,
                        )
                    }
                }
            }
        }
        val chip = composeRule.onNodeWithTag("monitor.media.filter.storage.17")
        val node = chip.fetchSemanticsNode()
        val bounds = node.boundsInRoot
        val minimum = with(nativeDensity) { 44.dp.roundToPx() }
        assertTrue(
            "The visible native floor must remain 44dp: bounds=$bounds, untrimmed=${node.size}, density=${nativeDensity.density}, minimum=$minimum",
            bounds.height >= minimum && bounds.width >= minimum,
        )
        val pixels = chip.captureToImage().toPixelMap()
        val edge = with(nativeDensity) { 2.dp.roundToPx() }
        val outsideCapsule = pixels[pixels.width / 2, edge]
        val outsideLeft = pixels[edge, pixels.height / 2]
        assertTrue(
            "The pointer must be outside the drawn capsule, inside the measured floor",
            listOf(outsideCapsule, outsideLeft).all { it.red < .001f && it.green < .001f && it.blue < .001f },
        )
        chip.performTouchInput { click(Offset(center.x, 2.dp.toPx())) }
        composeRule.runOnIdle { assertEquals("17", selected) }
        chip.performTouchInput { click(Offset(2.dp.toPx(), center.y)) }
        composeRule.runOnIdle { assertNull(selected) }
    }

    @Composable
    private fun FilterFixtureHost(content: @Composable () -> Unit) {
        OpenZCineTheme {
            Box(Modifier.fillMaxSize().background(Color.Black).padding(16.dp)) { content() }
        }
    }

    private fun capture(name: String) {
        composeRule.waitForIdle()
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val image = requireNotNull(instrumentation.uiAutomation.takeScreenshot())
        val folder = File(instrumentation.targetContext.cacheDir, "SIMULATED-media-filter").apply { mkdirs() }
        File(folder, "$name-${image.width}x${image.height}.png").outputStream().use {
            check(image.compress(Bitmap.CompressFormat.PNG, 100, it))
        }
        image.recycle()
    }

    private fun scrollFilterBodyUp() {
        composeRule.onNode(
            hasScrollAction() and hasAnyDescendant(hasText("SIZE")), useUnmergedTree = true,
        ).performTouchInput {
            swipeWithVelocity(
                Offset(center.x, height * .8f), Offset(center.x, height * .2f),
                endVelocity = 0f, durationMillis = 400,
            )
        }
        composeRule.waitForIdle()
    }

    private fun touch(description: String) {
        composeRule.onNodeWithContentDescription(description).assertIsDisplayed().performTouchInput { click() }
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

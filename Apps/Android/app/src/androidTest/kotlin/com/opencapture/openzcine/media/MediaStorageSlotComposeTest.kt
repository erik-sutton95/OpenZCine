package com.opencapture.openzcine.media

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.width
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsNotSelected
import androidx.compose.ui.test.assertIsSelected
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.opencapture.openzcine.OpenZCineTheme
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** Device contract for the shared portrait/landscape camera-slot selector. */
@RunWith(AndroidJUnit4::class)
class MediaStorageSlotComposeTest {
    @get:Rule
    val composeRule = createComposeRule()

    @Test
    fun portraitCardsShowIosCapacitySummaryAndToggleSelection() {
        var selectedStorageId by mutableStateOf<Long?>(null)
        composeRule.setContent {
            OpenZCineTheme {
                MediaStorageSlotSelector(
                    slots = slots,
                    selectedStorageId = selectedStorageId,
                    horizontal = true,
                    onSelect = { selectedStorageId = it },
                )
            }
        }

        composeRule.onNodeWithText("Slot 1").assertIsDisplayed()
        composeRule.onNodeWithText("242GB / 954GB free").assertIsDisplayed()
        composeRule.onNodeWithText("111GB free").assertIsDisplayed()
        composeRule
            .onNodeWithContentDescription("Filter media by Slot 1, 242GB / 954GB free")
            .assertIsNotSelected()
            .performClick()

        composeRule.waitForIdle()
        composeRule
            .onNodeWithContentDescription("Slot 1 filter selected, 242GB / 954GB free")
            .assertIsSelected()
        composeRule.runOnIdle { assertEquals(65_537L, selectedStorageId) }
    }

    @Test
    fun landscapeCardsExposeSelectedStateSemantically() {
        composeRule.setContent {
            OpenZCineTheme {
                MediaStorageSlotSelector(
                    slots = slots,
                    selectedStorageId = 131_073,
                    horizontal = false,
                    onSelect = {},
                )
            }
        }

        composeRule
            .onNodeWithContentDescription("Slot 2 filter selected, 111GB free")
            .assertIsDisplayed()
            .assertIsSelected()
    }

    @Test
    fun compactLargeFontLandscapeRailScrollsToEveryStorageCard() {
        composeRule.setContent {
            val deviceDensity = LocalDensity.current.density
            CompositionLocalProvider(LocalDensity provides Density(deviceDensity, fontScale = 2f)) {
                OpenZCineTheme {
                    Box(Modifier.width(172.dp).height(180.dp)) {
                        MediaLibraryRail(
                            category = MediaLibraryCategory.ALL,
                            storageSlots = compactSlots,
                            selectedStorageId = null,
                            onCategoryChange = {},
                            onStorageSelect = {},
                            showsGridControls = false,
                            layout = MediaLibraryLayout.GRID,
                            thumbnailSize = MediaThumbnailSize.MEDIUM,
                            onLayoutChange = {},
                            onThumbnailSizeChange = {},
                            modifier = Modifier.width(172.dp),
                        )
                    }
                }
            }
        }

        composeRule
            .onNodeWithContentDescription("Filter media by Slot 4, 40GB / 400GB free")
            .performScrollTo()
            .assertIsDisplayed()
        composeRule.onNodeWithText("40GB / 400GB free").assertIsDisplayed()
        composeRule
            .onNodeWithContentDescription("Filter media by Slot 1, 10GB / 100GB free")
            .performScrollTo()
            .assertIsDisplayed()
    }

    private val slots =
        listOf(
            MediaStorageSlotPresentation(65_537, 1, freeGigabytes = 242, totalGigabytes = 954),
            MediaStorageSlotPresentation(131_073, 2, freeGigabytes = 111, totalGigabytes = 0),
        )

    private val compactSlots =
        (1..4).map { slot ->
            MediaStorageSlotPresentation(
                storageId = slot.toLong(),
                slotNumber = slot,
                freeGigabytes = slot * 10L,
                totalGigabytes = slot * 100L,
            )
        }
}

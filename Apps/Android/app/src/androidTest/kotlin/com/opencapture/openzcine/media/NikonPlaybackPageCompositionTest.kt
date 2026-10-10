package com.opencapture.openzcine.media

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.Text
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.doubleClick
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTouchInput
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.opencapture.monitorui.*
import com.opencapture.opencine.media.MonitorConformPreview
import com.opencapture.opencine.media.MonitorPlaybackItemToken
import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** SIMULATED source slot composition; no physical camera/player decoding claim. */
@RunWith(AndroidJUnit4::class)
class NikonPlaybackPageCompositionTest {
    @get:Rule val compose = createComposeRule()

    @Test fun cleanStartAndRestoredAccessoryPersistWithinCommonPageAcrossPendingItemReplacement() {
        val value = mutableStateOf(presentation(clean = true))
        compose.setContent {
            MonitorPlaybackScreen(value.value, actions(),
                slots = MonitorPlaybackPageSlots(headerAccessory = { Text("SIMULATED native header accessory") }),
                picture = { Box(Modifier.fillMaxSize()) }, feedAssists = {}, canvasAssists = {},
                tools = {}, assistInspector = {})
        }
        compose.onNodeWithContentDescription("Share clip").assertDoesNotExist()
        compose.onNodeWithText("SIMULATED native header accessory").assertDoesNotExist()
        compose.onNodeWithContentDescription("Show playback controls").performClick()
        compose.onNodeWithContentDescription("Share clip").assertIsNotEnabled()
        compose.onNodeWithText("SIMULATED native header accessory").assertExists()
        compose.runOnIdle { value.value = value.value.copy(
            item = MonitorPlaybackItemToken(value.value.item!!.owner, 2), ready = false) }
        compose.onNodeWithContentDescription("Share clip").assertIsNotEnabled()
        compose.onNodeWithText("SIMULATED native header accessory").assertExists()
        compose.onNodeWithContentDescription("Loop playback").assertDoesNotExist()
    }

    @Test fun actualNativeGestureWindowDoubleTapResetsCommonOwnedZoom() {
        var geometry: MonitorPlaybackPictureGeometry? = null
        compose.setContent {
            MonitorPlaybackScreen(presentation(clean = true).copy(doubleTapResetsZoom = true), actions(),
                slots = MonitorPlaybackPageSlots(),
                picture = { geometry = it; Box(Modifier.fillMaxSize().testTag("SIMULATED picture")) },
                feedAssists = {}, canvasAssists = {}, tools = {}, assistInspector = {})
        }
        compose.onNodeWithContentDescription("Playback picture controls").performTouchInput {
            down(0, center - Offset(40f, 0f)); down(1, center + Offset(40f, 0f))
            advanceEventTime(16)
            updatePointerTo(0, center - Offset(41f, 0f)); updatePointerTo(1, center + Offset(41f, 0f)); move()
            advanceEventTime(16)
            updatePointerTo(0, center - Offset(82f, 0f)); updatePointerTo(1, center + Offset(82f, 0f)); move()
            up(0); up(1)
        }
        compose.runOnIdle { assertTrue(requireNotNull(geometry).zoom.scale > 1f) }
        compose.onNodeWithContentDescription("Playback picture controls").performTouchInput { doubleClick() }
        compose.runOnIdle { assertEquals(MonitorPlaybackZoom(), requireNotNull(geometry).zoom) }
    }

    @Test fun actualOptedInGestureWindowClampsBeforeReleaseAndReversesWithoutCommittingItsAccumulator() {
        var geometry: MonitorPlaybackPictureGeometry? = null
        compose.setContent {
            MonitorPlaybackScreen(presentation(clean = true).copy(
                continuousPanBounds = true, zoomBoundary = MonitorPlaybackZoomBoundary.CANVAS,
                horizontalPresentationScale = 1.5f), actions(), slots = MonitorPlaybackPageSlots(),
                picture = { geometry = it; Box(Modifier.fillMaxSize()) },
                feedAssists = {}, canvasAssists = {}, tools = {}, assistInspector = {})
        }
        compose.onNodeWithContentDescription("Playback picture controls").performTouchInput {
            down(0, center - Offset(40f, 0f)); down(1, center + Offset(40f, 0f))
            advanceEventTime(16)
            updatePointerTo(0, center - Offset(41f, 0f)); updatePointerTo(1, center + Offset(41f, 0f)); move()
            advanceEventTime(16)
            updatePointerTo(0, center - Offset(82f, 0f)); updatePointerTo(1, center + Offset(82f, 0f)); move()
            up(0); up(1)
        }
        var maxX = 0f
        var travel = 0f
        compose.runOnIdle {
            val current = requireNotNull(geometry)
            assertTrue(current.zoom.scale > 1f)
            maxX = current.canvasWidth * (current.zoom.scale * 1.5f - 1f) / 2f
            travel = maxX * 4f + 50f
        }
        compose.onNodeWithContentDescription("Playback picture controls").performTouchInput {
            down(center); moveTo(center + Offset(travel, 0f))
        }
        compose.runOnIdle {
            assertEquals(maxX, requireNotNull(geometry).zoom.offsetX, .1f)
        }
        compose.onNodeWithContentDescription("Playback picture controls").performTouchInput {
            moveTo(center + Offset(travel - 50f, 0f))
        }
        compose.runOnIdle {
            assertEquals(maxX - 50f, requireNotNull(geometry).zoom.offsetX, .1f)
        }
        compose.onNodeWithContentDescription("Playback picture controls").performTouchInput {
            moveTo(center); up()
        }
        compose.runOnIdle {
            assertEquals(-maxX, requireNotNull(geometry).zoom.offsetX, .1f)
        }
    }

    private fun presentation(clean: Boolean) = MonitorPlaybackPresentation(
        item = MonitorPlaybackItemToken(UUID.randomUUID(), 1), title = "SIMULATED PAGE.MOV",
        subtitle = "", source = null, metadata = emptyList(), aspect = 16f / 9f, ready = true,
        error = null, progress = null, position = 1f, duration = 10f,
        positionLabel = "0:01", durationLabel = "0:10", playing = false, reachedEnd = false,
        scrubbing = false, muted = false, looping = false, previous = false, next = false,
        favorite = false, conform = MonitorConformPreview.Source(), conformTarget = null,
        initialChromeVisible = !clean, loopAvailable = false, shareEnabled = false)

    private fun actions() = MonitorPlaybackActions(
        back = {}, play = { _, _ -> }, restart = {}, seekBy = { _, _ -> }, mute = { _, _ -> },
        loop = { _, _ -> }, conform = { _, _ -> }, adjacent = { _, _ -> }, favorite = {}, share = {},
        delete = null, beginScrub = { null }, updateScrub = { _, _ -> },
        updateFrameScrub = { _, _, _ -> }, commitScrub = {}, cancelScrub = { _, _ -> })
}

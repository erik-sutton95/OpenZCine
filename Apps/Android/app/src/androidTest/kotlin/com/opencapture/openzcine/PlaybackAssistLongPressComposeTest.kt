package com.opencapture.openzcine

import androidx.compose.foundation.layout.size
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assert
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performSemanticsAction
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.opencapture.openzcine.core.CameraControl
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** TalkBack-level contract for playback's optional assist-toolbar long press. */
@OptIn(ExperimentalTestApi::class)
@RunWith(AndroidJUnit4::class)
class PlaybackAssistLongPressComposeTest {
    @get:Rule
    val composeRule = createComposeRule()

    @Test
    fun configurableToolLongClickDoesNotToggleAndAudioRemainsTapOnly() {
        val state = AssistState(FeedEffects.NONE, null)
        var configured: AssistTool? = null
        var anchorBounds: Rect? = null
        composeRule.setContent {
            OpenZCineTheme {
                AssistToolbar(
                    state = state,
                    visibleTools = listOf(AssistTool.WAVE, AssistTool.AUDIO),
                    hapticsEnabled = false,
                    onLongPressToolAnchored = { tool, bounds ->
                        configured = tool
                        anchorBounds = bounds
                    },
                )
            }
        }

        composeRule
            .onNodeWithContentDescription(AssistTool.WAVE.settingsTitle)
            .performSemanticsAction(SemanticsActions.OnLongClick)
        composeRule.runOnIdle {
            assertEquals(AssistTool.WAVE, configured)
            assertFalse(state.isOn(AssistTool.WAVE))
            assertTrue(requireNotNull(anchorBounds).width > 1f)
            assertTrue(requireNotNull(anchorBounds).height > 1f)
        }

        composeRule
            .onNodeWithContentDescription(AssistTool.WAVE.settingsTitle)
            .performClick()
        composeRule.runOnIdle { assertTrue(state.isOn(AssistTool.WAVE)) }

        composeRule
            .onNodeWithContentDescription(AssistTool.AUDIO.settingsTitle)
            .assert(SemanticsMatcher.keyNotDefined(SemanticsActions.OnLongClick))
    }

    @Test
    fun commandTileLongPressDragMovesDirectlyWithoutOpeningItsCameraControl() {
        val order = mutableStateOf(listOf(CommandTileKind.MODE, CommandTileKind.ISO, CommandTileKind.SHUTTER))
        var opened = 0
        var reorderStarted = 0
        composeRule.setContent {
            OpenZCineTheme {
                CommandGrid(
                    tiles =
                        order.value.map { kind ->
                            CommandTilePresentation(
                                kind = kind,
                                title = kind.name.lowercase().replaceFirstChar(Char::uppercase),
                                value = if (kind == CommandTileKind.MODE) "M" else "800",
                                request =
                                    if (kind == CommandTileKind.MODE) {
                                        CommandControlRequest(
                                            title = "Mode",
                                            control = CameraControl.EXPOSURE_MODE,
                                            currentValue = "M",
                                            options = listOf("M"),
                                        )
                                    } else {
                                        null
                                    },
                            )
                        },
                    controlsEnabled = true,
                    pendingControl = null,
                    onOpenControl = { opened += 1 },
                    onMoveTile = { kind, target ->
                        val next = order.value.toMutableList()
                        next.remove(kind)
                        next.add(target.coerceIn(0, next.size), kind)
                        order.value = next
                    },
                    onReorderStarted = { reorderStarted += 1 },
                    modifier = androidx.compose.ui.Modifier.size(330.dp, 90.dp),
                )
            }
        }

        composeRule
            .onNodeWithContentDescription("Mode: M", substring = true)
            .performTouchInput {
                down(center)
                advanceEventTime(700)
                up()
            }

        composeRule.runOnIdle {
            assertEquals(0, opened)
            assertEquals(1, reorderStarted)
            assertEquals(CommandTileKind.MODE, order.value.first())
        }

        composeRule
            .onNodeWithContentDescription("Mode: M", substring = true)
            .performTouchInput {
                down(center)
                advanceEventTime(700)
                moveBy(Offset(width * 1.8f, 0f))
                advanceEventTime(50)
                up()
            }

        composeRule.runOnIdle {
            assertEquals(0, opened)
            assertEquals(2, reorderStarted)
            assertEquals(CommandTileKind.MODE, order.value.last())
        }
    }
}

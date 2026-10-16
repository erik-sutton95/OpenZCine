package com.opencapture.openzcine

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.opencapture.monitorui.MonitorCommandHealth
import com.opencapture.opencine.nikon.CameraControl
import org.junit.Assert.assertEquals
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
    fun commandTileLongPressDragMovesDirectlyWithoutOpeningItsCameraControl() {
        val order = mutableStateOf(listOf(CommandTileKind.MODE, CommandTileKind.ISO, CommandTileKind.SHUTTER))
        var opened = 0
        composeRule.setContent {
            OpenZCineTheme {
                // Portrait DISP 3 (the shared dashboard's compact grid), as MonitorScreen mounts it.
                Box(Modifier.size(330.dp, 400.dp)) {
                    CommandDashboard(
                        presentation =
                            CommandDashboardPresentation(
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
                                sideSections = emptyList(),
                                health = MonitorCommandHealth("OK", true, "", "", ""),
                                frameRate = "",
                                refreshSummary = "",
                            ),
                        portrait = true,
                        controlsEnabled = true,
                        pendingControl = null,
                        onOpenControl = { opened += 1 },
                        onMoveTile = { kind, target ->
                            val next = order.value.toMutableList()
                            next.remove(kind)
                            next.add(target.coerceIn(0, next.size), kind)
                            order.value = next
                        },
                        liveFps = "25.00",
                        signalBars = 3,
                    )
                }
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
            assertEquals(CommandTileKind.MODE, order.value.last())
        }
    }
}

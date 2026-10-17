package com.opencapture.openzcine

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.SemanticsNodeInteraction
import androidx.compose.ui.test.assertContentDescriptionEquals
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.performClick
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.opencapture.monitorui.MonitorCommandDashboard
import com.opencapture.monitorui.MonitorCommandHealth
import com.opencapture.monitorui.MonitorCommandTile
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** SIMULATED mounted shared dashboard; kinds and requests vary independently of camera admission. */
@RunWith(AndroidJUnit4::class)
class CommandDashboardAccessibilityComposeTest {
    @get:Rule val composeRule = createComposeRule()
    private val opened = mutableListOf<String>()
    private val moved = mutableListOf<Pair<String, Int>>()

    @Test fun fixedReadOnlyTilesAnnounceTheirReasonWithoutOfferingReorder() {
        show()
        tile("Status").assertContentDescriptionEquals("Status: Ready. Read-only.").assertIsNotEnabled()
        tile("Unavailable").assertContentDescriptionEquals("Unavailable: N/A. Not supported.").assertIsNotEnabled()
        assertFixed("Status")
        assertFixed("Unavailable")
        composeRule.runOnIdle { assertTrue(opened.isEmpty() && moved.isEmpty()) }
    }

    @Test fun fixedEditableTileAnnouncesAndOpensOnlyItsRequest() {
        show()
        tile("ISO").assertContentDescriptionEquals("ISO: 100. Double tap to change.")
        assertFixed("ISO")
        tile("ISO").performClick()
        composeRule.runOnIdle {
            assertEquals(listOf("iso"), opened)
            assertTrue(moved.isEmpty())
        }
    }

    @Test fun fixedLockedTileAnnouncesTheLockWithoutOfferingReorder() {
        show(controlsEnabled = false)
        tile("ISO").assertContentDescriptionEquals("ISO: 100. Controls are locked.").assertIsNotEnabled()
        assertFixed("ISO")
        composeRule.runOnIdle { assertTrue(opened.isEmpty() && moved.isEmpty()) }
    }

    @Test fun lockedMovableTilesKeepLocalReorderWithoutSendingCameraRequests() {
        show(controlsEnabled = false)
        tile("Format").assertContentDescriptionEquals("Format: 4K. Controls are locked. Long press and drag to reorder.")
        tile("Temp").assertContentDescriptionEquals("Temp: OK. Read-only. Long press and drag to reorder.")
        moveEarlier("Format")
        moveEarlier("Temp")
        tile("Format").performClick()
        tile("Temp").performClick()
        composeRule.runOnIdle {
            assertEquals(listOf("format" to 2, "temperature" to 3), moved)
            assertTrue(opened.isEmpty())
        }
    }

    @Test fun pendingAndApplyingAnnouncementsKeepCoalescingAndLocalReorder() {
        show(pending = true, applyingRequest = "iso")
        tile("ISO").assertContentDescriptionEquals("ISO: 100. Applying change.")
        tile("Format").assertContentDescriptionEquals("Format: 4K. Another control is being applied.")
        tile("Status").assertContentDescriptionEquals("Status: Ready. Another control is being applied.")
        assertFixed("ISO")
        assertFixed("Status")
        tile("ISO").performClick()
        moveEarlier("Format")
        composeRule.runOnIdle {
            assertEquals(listOf("iso"), opened)
            assertEquals(listOf("format" to 2), moved)
        }
    }

    @Test fun editableMovableTileOffersBothChangeAndLocalReorder() {
        show()
        tile("Format").assertContentDescriptionEquals("Format: 4K. Double tap to change; long press and drag to reorder.")
        moveEarlier("Format")
        tile("Format").performClick()
        composeRule.runOnIdle {
            assertEquals(listOf("format"), opened)
            assertEquals(listOf("format" to 2), moved)
        }
    }

    private fun show(controlsEnabled: Boolean = true, pending: Boolean = false, applyingRequest: String? = null) {
        composeRule.setContent {
            OpenZCineTheme {
                Box(Modifier.fillMaxSize().padding(16.dp)) {
                    MonitorCommandDashboard(
                        tiles = listOf(
                            MonitorCommandTile<String, String>(title = "Status", value = "Ready"),
                            MonitorCommandTile(title = "Unavailable", value = "N/A", unavailableReason = "Not supported."),
                            MonitorCommandTile(title = "ISO", value = "100", request = "iso"),
                            MonitorCommandTile(kind = "format", title = "Format", value = "4K", request = "format"),
                            MonitorCommandTile(kind = "temperature", title = "Temp", value = "OK"),
                        ),
                        sections = emptyList(),
                        health = MonitorCommandHealth("OK", true, "SIMULATED", "SIMULATED", "SIMULATED"),
                        portrait = true,
                        controlsEnabled = controlsEnabled,
                        pending = pending,
                        applying = { it == applyingRequest },
                        onOpenControl = { opened += it },
                        onMoveTile = { kind, index -> moved += kind to index },
                        healthTrailing = {},
                    )
                }
            }
        }
        composeRule.waitForIdle()
    }

    private fun tile(title: String): SemanticsNodeInteraction =
        composeRule.onNodeWithContentDescription("$title:", substring = true, useUnmergedTree = true)

    private fun assertFixed(title: String) {
        val actions = tile(title).fetchSemanticsNode().config.getOrNull(SemanticsActions.CustomActions).orEmpty()
        assertTrue("A fixed tile cannot offer a move: $title", actions.isEmpty())
    }

    private fun moveEarlier(title: String) {
        val actions = tile(title).fetchSemanticsNode().config.getOrNull(SemanticsActions.CustomActions).orEmpty()
        val earlier = actions.single { it.label == "Move $title earlier" }
        composeRule.runOnIdle { assertTrue(earlier.action()) }
    }
}

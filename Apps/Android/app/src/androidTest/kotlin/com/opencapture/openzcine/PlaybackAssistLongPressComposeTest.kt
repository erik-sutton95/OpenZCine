package com.opencapture.openzcine

import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assert
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performSemanticsAction
import androidx.test.ext.junit.runners.AndroidJUnit4
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
        composeRule.setContent {
            OpenZCineTheme {
                AssistToolbar(
                    state = state,
                    visibleTools = listOf(AssistTool.WAVE, AssistTool.AUDIO),
                    hapticsEnabled = false,
                    onLongPressTool = { configured = it },
                )
            }
        }

        composeRule
            .onNodeWithContentDescription(AssistTool.WAVE.settingsTitle)
            .performSemanticsAction(SemanticsActions.OnLongClick)
        composeRule.runOnIdle {
            assertEquals(AssistTool.WAVE, configured)
            assertFalse(state.isOn(AssistTool.WAVE))
        }

        composeRule
            .onNodeWithContentDescription(AssistTool.WAVE.settingsTitle)
            .performClick()
        composeRule.runOnIdle { assertTrue(state.isOn(AssistTool.WAVE)) }

        composeRule
            .onNodeWithContentDescription(AssistTool.AUDIO.settingsTitle)
            .assert(SemanticsMatcher.keyNotDefined(SemanticsActions.OnLongClick))
    }
}

package com.opencapture.openzcine

import androidx.compose.runtime.Composable
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assert
import androidx.compose.ui.test.assertHasClickAction
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performSemanticsAction
import androidx.compose.ui.test.performTouchInput
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.opencapture.opencine.appkit.MonitorPhotoRelease
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/**
 * A3-22: the still release through the production component the Z monitor composes (root's fc proposal,
 * reworked): a button for accessibility, and a held press that always releases exactly once.
 */
@RunWith(AndroidJUnit4::class)
class PhotographyShutterComposeTest {
    @get:Rule val compose = createComposeRule()

    @Test fun accessibilityActivationPerformsOneCompleteRelease() {
        val events = mutableListOf<String>()
        compose.setContent { OpenZCineTheme { Release(events) } }
        compose.onNodeWithTag(TAG)
            .assert(SemanticsMatcher.expectValue(SemanticsProperties.Role, Role.Button))
            .assertHasClickAction()
            .performSemanticsAction(SemanticsActions.OnClick)
        compose.runOnIdle { assertEquals(listOf("down", "up"), events) }
    }

    @Test fun aHeldPressReleasesExactlyOnceWhenAuthorityIsWithdrawn() {
        val enabled = mutableStateOf(true)
        val events = mutableListOf<String>()
        compose.setContent { OpenZCineTheme { Release(events, enabled = enabled.value) } }
        val shutter = compose.onNodeWithTag(TAG)
        shutter.performTouchInput { down(center) }
        compose.runOnIdle {
            assertEquals(listOf("down"), events)
            enabled.value = false
        }
        compose.waitForIdle()
        shutter.performTouchInput { up() }
        compose.runOnIdle { assertEquals(listOf("down", "up"), events) }
        shutter.assertIsNotEnabled()
    }

    @Test fun aHoldKeepsTheReleaseUntilTheFingerLifts() {
        val events = mutableListOf<String>()
        compose.setContent { OpenZCineTheme { Release(events, capturing = true) } }
        val shutter = compose.onNodeWithTag(TAG)
        shutter.performTouchInput { down(center) }
        compose.runOnIdle { assertEquals(listOf("down"), events) }
        shutter.performTouchInput { up() }
        compose.runOnIdle { assertEquals(listOf("down", "up"), events) }
    }

    @Test fun aWithdrawnReleaseIgnoresAPress() {
        val events = mutableListOf<String>()
        compose.setContent { OpenZCineTheme { Release(events, enabled = false) } }
        compose.onNodeWithTag(TAG).performTouchInput { down(center); up() }
        compose.runOnIdle { assertEquals(emptyList<String>(), events) }
    }

    @Composable
    private fun Release(events: MutableList<String>, enabled: Boolean = true, capturing: Boolean = false) =
        MonitorPhotoRelease(84f, enabled, Modifier.testTag(TAG), capturing = capturing,
            onPressed = { events += "down" }, onReleased = { events += "up" })

    private companion object {
        const val TAG = "photo.release"
    }
}

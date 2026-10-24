package com.opencapture.openzcine

import android.graphics.Rect
import android.view.accessibility.AccessibilityWindowInfo
import androidx.activity.ComponentActivity
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.width
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.MutableState
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.test.SemanticsNodeInteraction
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertHeightIsAtLeast
import androidx.compose.ui.test.assertTextEquals
import androidx.compose.ui.test.assertTextContains
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.assertIsSelected
import androidx.compose.ui.test.assertWidthIsAtLeast
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performImeAction
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performTextReplacement
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.test.swipeLeft
import androidx.compose.ui.test.swipeUp
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.By
import androidx.test.uiautomator.UiDevice
import androidx.test.uiautomator.Until
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** Display and callback fixtures only. These tests never invoke a native driver or move a lens. */
@RunWith(AndroidJUnit4::class)
class FocusRackPanelComposeTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()

    @Before fun landscapeFirst() { compose.settleLandscape() }

    @Test fun nativeSavedStateAndUnavailableActionsAreExplicitForZeroOneAndTwoTargets() {
        val state = mutableStateOf(ready().copy(focusMode = "nativeAF",
            nativeAF = NativeAFRackViewState(canSet = true)))
        val actions = Actions()
        mount(state, actions)
        compose.onNodeWithTag("focusRack.nativeAF.saved.A").assertTextEquals("A not set").assertIsDisplayed()
        compose.onNodeWithTag("focusRack.nativeAF.saved.B").assertTextEquals("B not set").assertIsDisplayed()
        for (mark in listOf("A", "B")) compose.onNodeWithTag("focusRack.nativeAF.go.$mark")
            .assertIsDisplayed().assertIsNotEnabled().insideFrame()
        for (direction in listOf("aToB", "bToA")) compose.onNodeWithTag("focusRack.nativeAF.run.$direction").assertIsNotEnabled()
        compose.saveLandscapeEvidence("native-af-zero-targets-landscape")
        compose.runOnIdle { state.value = state.value.copy(nativeAF = state.value.nativeAF.copy(
            hasA = true, canGoToA = true, message = "Camera did not accept target A.")) }
        compose.onNodeWithTag("focusRack.nativeAF.saved.A").assertTextEquals("✓ A set").assertIsDisplayed()
        compose.onNodeWithTag("focusRack.nativeAF.saved.B").assertTextEquals("B not set")
        compose.onNodeWithTag("focusRack.nativeAF.go.A").assertIsEnabled()
        compose.onNodeWithTag("focusRack.nativeAF.go.B").assertIsNotEnabled()
        compose.onNodeWithTag("focusRack.nativeAF.run.aToB").assertIsNotEnabled()
        compose.saveLandscapeEvidence("native-af-one-target-landscape")
        compose.runOnIdle { state.value = state.value.copy(nativeAF = state.value.nativeAF.copy(
            hasB = true, canGoToB = true, canRun = true, message = "Target B selected")) }
        compose.onNodeWithTag("focusRack.nativeAF.saved.B").assertTextEquals("✓ B set").assertIsDisplayed()
        compose.onNodeWithTag("focusRack.nativeAF.go.B").assertIsEnabled()
        compose.onNodeWithTag("focusRack.nativeAF.run.aToB").assertIsEnabled()
        compose.onNodeWithTag("focusRack.nativeAF.run.bToA").assertIsEnabled()
        assertTrue(actions.nativeGoes.isEmpty())
        assertTrue(actions.nativeRuns.isEmpty())
        compose.saveLandscapeEvidence("native-af-two-targets-landscape")
    }

    @Test fun nativePointLockRecoveryRequiresAnExplicitActionAndRespectsInterfaceLock() {
        val state = mutableStateOf(ready().copy(focusMode = "nativeAF",
            nativeAFDisabledReason = "Unlock the focus point before selecting a new target.",
            nativeAF = NativeAFRackViewState(hasA = true, hasB = true, canSet = true, canGoToA = true,
                canGoToB = true, canRun = true, message = "Unlock the focus point before selecting a new target.")))
        val pointLocked = mutableStateOf(true)
        val interfaceUnlocked = mutableStateOf(true)
        val actions = Actions()
        mount(state, actions, setupEnabled = { interfaceUnlocked.value },
            nativePointLocked = { pointLocked.value }, onUnlockNativeFocusPoint = { pointLocked.value = false })
        compose.onNodeWithTag("focusRack.nativeAF.unlock").assertIsDisplayed().assertIsEnabled().insideFrame()
        compose.onNodeWithTag("focusRack.nativeAF.set.A").assertIsNotEnabled()
        compose.onNodeWithTag("focusRack.nativeAF.go.A").assertIsNotEnabled()
        compose.onNodeWithTag("focusRack.nativeAF.run.aToB").assertIsNotEnabled()
        compose.saveLandscapeEvidence("native-af-point-locked-landscape")
        compose.runOnIdle { interfaceUnlocked.value = false }
        compose.onNodeWithTag("focusRack.nativeAF.unlock").assertIsNotEnabled().performClick()
        assertEquals(0, actions.nativeUnlocks)
        compose.runOnIdle { interfaceUnlocked.value = true }
        compose.onNodeWithTag("focusRack.nativeAF.unlock").assertIsEnabled().performClick()
        compose.onNodeWithTag("focusRack.nativeAF.unlock").assertDoesNotExist()
        assertEquals(1, actions.nativeUnlocks)
        assertTrue(actions.nativeSets.isEmpty())
        assertTrue(actions.nativeGoes.isEmpty())
        assertTrue(actions.nativeRuns.isEmpty())
    }

    @Test fun compactNativePointLockRecoveryFitsWithoutFocusBoxes() {
        val state = mutableStateOf(ready().copy(focusMode = "nativeAF",
            nativeAF = NativeAFRackViewState(message = "Focus point locked")))
        val actions = Actions()
        mount(state, actions, compact = true, maximumHeight = 112f, nativePointLocked = { true })
        compose.onNodeWithTag("focusRack.nativeAF.unlock").assertIsDisplayed().assertIsEnabled().insideFrame().performClick()
        assertEquals(1, actions.nativeUnlocks)
        compose.onNodeWithTag("focusRack.nativeAF.run.aToB").assertDoesNotExist()
        compose.saveLandscapeEvidence("native-af-compact-point-locked-landscape")
    }

    @Test fun nativeModeOffersTargetsDelayAndDirectionalActionsWithoutTimedControls() {
        val state = mutableStateOf(ready().copy(canChangeFocusMode = true,
            nativeAF = NativeAFRackViewState(canSet = true)))
        val actions = Actions()
        mount(state, actions)
        compose.onNodeWithTag("focusRack.mode.nativeAF").performClick()
        compose.onNodeWithTag("focusRack.nativeAF").assertIsDisplayed().insideFrame()
        for (tag in listOf("positions", "nudges", "duration", "calibrate", "primary", "pull.aToB", "pull.bToA")) {
            compose.onNodeWithTag("focusRack.$tag").assertDoesNotExist()
        }
        compose.onNodeWithTag("focusRack.nativeAF.set.A").assertIsEnabled().performClick()
        assertEquals(listOf("A"), actions.nativeSets)
        assertEquals(listOf(false), actions.expansions)
        compose.runOnIdle {
            state.value = state.value.copy(nativeAF = NativeAFRackViewState(hasA = true, hasB = true,
                canSet = true, canGoToA = true, canGoToB = true, canRun = true, message = "Target A selected"))
        }
        compose.onNodeWithTag("focusRack.nativeAF.go.B").performScrollTo().assertIsEnabled().performClick()
        compose.onNodeWithTag("focusRack.nativeAF.run.aToB").assertIsDisplayed().insideFrame().performClick()
        compose.onNodeWithTag("focusRack.nativeAF.run.bToA").assertIsDisplayed().insideFrame().performClick()
        assertEquals(listOf("B"), actions.nativeGoes)
        assertEquals(listOf("B", "A"), actions.nativeRuns)
        compose.onNodeWithTag("focusRack.nativeAF.settings").performScrollTo().assertIsEnabled().performClick()
        compose.onNodeWithText("Transition speed: camera setting").performScrollTo().assertIsDisplayed()
        assertEquals(1, actions.focusSettings)
        assertTrue(actions.nudges.isEmpty())
        compose.saveLandscapeEvidence("native-rack-settings-landscape")
        compose.onNodeWithTag("focusRack.nativeAF.set.A").performScrollTo()
        compose.saveLandscapeEvidence("native-rack-ab-ready-landscape")
        compose.runOnIdle { state.value = state.value.copy(recording = true) }
        compose.onNodeWithTag("focusRack.nativeAF.run.aToB").assertTextContains("Run A→B")
        compose.runOnIdle { state.value = state.value.copy(nativeAF = state.value.nativeAF.copy(
            busy = true, canSet = false, canGoToA = false, canGoToB = false,
            canRun = false, canCancel = true, message = "Starts in 2.0 s")) }
        compose.onNodeWithTag("focusRack.nativeAF.cancel").assertIsDisplayed().insideFrame().performClick()
        assertEquals(1, actions.nativeCancels)
        compose.saveLandscapeEvidence("native-rack-countdown-landscape")
    }

    @Test fun compactNativeSelectionKeepsCancelAndStatusInsideAllEdges() {
        val state = mutableStateOf(ready().copy(focusMode = "nativeAF", nativeAF = NativeAFRackViewState(
            selectingMark = "B", canCancel = true, message = "Tap subject B in the picture.")))
        val actions = Actions()
        mount(state, actions, compact = true, maximumHeight = 112f)
        compose.onNodeWithText("Tap subject B in the picture.").assertIsDisplayed().insideFrame()
        compose.onNodeWithTag("focusRack.nativeAF.cancel").assertIsDisplayed().insideFrame().performClick()
        assertEquals(1, actions.nativeCancels)
        compose.onNodeWithTag("focusRack.panel").insideFrame()
        compose.saveLandscapeEvidence("native-rack-selecting-b-landscape")
    }

    @Test fun automaticSetupKeepsStatusScrollableAndManualSettingsAvailable() {
        val state = mutableStateOf(ready().copy(afSettingsPending = true, canNudge = false,
            canAutofocus = false, primaryEnabled = false, canChangeFocusMode = false))
        val actions = Actions()
        mount(state, actions)
        compose.onNodeWithTag("focusRack.message").performScrollTo()
            .assertTextEquals("Setting up camera AF…").assertIsDisplayed().insideFrame()
        compose.onNodeWithTag("focusRack.close").assertIsEnabled()
        openOptions()
        compose.onNodeWithText("Focus settings").performScrollTo().assertIsEnabled().performClick()
        assertEquals(1, actions.focusSettings)
        compose.saveLandscapeEvidence("auto-af-timed-setup-pending-landscape")
        compose.runOnIdle { state.value = state.value.copy(focusMode = "nativeAF") }
        compose.onNodeWithTag("focusRack.nativeAF.settings").performScrollTo().assertIsDisplayed().assertIsEnabled().insideFrame()
        compose.onNodeWithTag("focusRack.nativeAF.settings").performClick()
        assertEquals(2, actions.focusSettings)
        compose.runOnIdle { state.value = state.value.copy(nativeAF = NativeAFRackViewState(message = "Setting up camera AF…")) }
        compose.onNodeWithText("Setting up camera AF…").performScrollTo().assertIsDisplayed().insideFrame()
        compose.saveLandscapeEvidence("auto-af-native-setup-pending-landscape")
        compose.runOnIdle { state.value = state.value.copy(afSettingsPending = false,
            afSettingsFailure = "Camera AF settings are unavailable; automatic setup could not start.") }
        compose.onNodeWithText("Camera AF settings are unavailable; automatic setup could not start.")
            .performScrollTo().assertIsDisplayed().insideFrame()
        compose.onNodeWithTag("focusRack.nativeAF.settings").performScrollTo().assertIsDisplayed().assertIsEnabled().insideFrame()
        compose.saveLandscapeEvidence("auto-af-native-setup-failed-landscape")
    }

    @Test fun groupedMarksAndDirectionSelectorForwardAllSixNudgesWithoutAWheel() {
        val state = mutableStateOf(ready().copy(marks = emptyList(), canCaptureB = false))
        val actions = Actions()
        mount(state, actions)
        compose.onNodeWithTag("focusRack.capture.A").assertIsEnabled().performClick()
        compose.onNodeWithTag("focusRack.capture.B").assertIsNotEnabled()
        assertEquals(listOf("A"), actions.captures)
        compose.runOnIdle { state.value = state.value.copy(marks = listOf(mark("A", 0)), position = 4, canCaptureB = true) }
        compose.onNodeWithText("0 steps").assertIsDisplayed()
        compose.onNodeWithTag("focusRack.positions").assertTextEquals("A 0 · B — · Now 4").assertIsDisplayed().insideFrame()
        compose.onNodeWithTag("focusRack.capture.B").performClick()
        assertEquals(listOf("A", "B"), actions.captures)
        compose.onNodeWithTag("focusRack.direction.near").assertIsSelected()
        for ((near, direction) in listOf(true to "near", false to "far")) {
            val before = actions.nudges.size
            compose.onNodeWithTag("focusRack.direction.$direction").performScrollTo().assertIsEnabled().performClick()
            compose.onNodeWithTag("focusRack.direction.$direction").assertIsSelected()
            assertEquals("Changing direction must not move focus", before, actions.nudges.size)
            for (steps in listOf(1, 10, 100)) {
                val tag = "focusRack.nudge.$steps"
                compose.onNodeWithTag(tag).performScrollTo().assertIsEnabled()
                    .assertTextContains(if (near) "−$steps" else "+$steps").performClick()
                assertTouchTarget(tag)
            }
        }
        assertEquals(listOf(true to 1, true to 10, true to 100, false to 1, false to 10, false to 100), actions.nudges)
        compose.onNodeWithContentDescription("Rack focus dial; use Near and Far buttons for accessible adjustment").assertDoesNotExist()
        compose.onNodeWithTag("focusRack.tab.Marks").assertDoesNotExist()
        compose.onNodeWithTag("focusRack.stop").assertDoesNotExist()
        compose.onAllNodesWithTag("focusRack.close").assertCountEquals(1)
        compose.onNodeWithTag("focusRack.close").assertIsDisplayed().insideFrame()
        assertTransportInsideFrame()
        compose.saveLandscapeEvidence("focus-rack-production-marks-landscape")
        openOptions()
        compose.onNodeWithText("Replace A").performScrollTo().assertIsDisplayed()
        compose.onNodeWithText("Focus settings").performScrollTo().performClick()
        compose.onNodeWithTag("focusRack.reset").performScrollTo().performClick()
        assertEquals(1, actions.focusSettings)
        assertEquals(1, actions.resets)
        compose.runOnIdle { state.value = state.value.copy(canNudge = false) }
        for (steps in listOf(1, 10, 100)) compose.onNodeWithTag("focusRack.nudge.$steps").performScrollTo().assertIsNotEnabled()
        compose.onNodeWithTag("focusRack.direction.near").performScrollTo().assertIsEnabled().performClick()
        compose.onNodeWithTag("focusRack.direction.near").assertIsSelected()
        assertEquals("Idle direction selection must not bypass disabled nudge capability", 6, actions.nudges.size)
    }

    @Test fun setupNudgesKeepBoundsAndIdentityThroughProgressStopAndSettlement() {
        val resting = ready().copy(message = "")
        val state = mutableStateOf(resting)
        val actions = Actions()
        mount(state, actions)
        val tags = listOf("focusRack.panel", "focusRack.marks", "focusRack.positions", "focusRack.nudges",
            "focusRack.go.A", "focusRack.go.B", "focusRack.direction.near", "focusRack.direction.far",
            "focusRack.nudge.1", "focusRack.nudge.10", "focusRack.nudge.100",
            "focusRack.duration", "focusRack.delay", "focusRack.options")
        val restingBounds = tags.associateWith { compose.onNodeWithTag(it).fetchSemanticsNode().boundsInRoot }
        fun assertStableSetup() {
            for (tag in tags) assertEquals("Setup bounds changed for $tag", restingBounds[tag],
                compose.onNodeWithTag(tag).fetchSemanticsNode().boundsInRoot)
            for (id in listOf("direction.near", "direction.far", "nudge.1", "nudge.10", "nudge.100")) {
                compose.onNodeWithTag("focusRack.$id").assertIsDisplayed().assertIsNotEnabled().insideFrame()
            }
            for (id in listOf("A", "B")) compose.onNodeWithTag("focusRack.go.$id")
                .assertIsDisplayed().assertIsNotEnabled().insideFrame()
            compose.onNodeWithTag("focusRack.duration").assertIsNotEnabled()
            compose.onNodeWithTag("focusRack.delay").assertIsNotEnabled()
            compose.onNodeWithTag("focusRack.options").assertIsNotEnabled()
            compose.onNodeWithTag("focusRack.primary").assertIsNotEnabled()
            compose.onNodeWithTag("focusRack.stopHint").assertDoesNotExist()
            compose.onNodeWithTag("focusRack.progress").assertDoesNotExist()
            compose.onNodeWithTag("focusRack.message").assertDoesNotExist()
            assertTransportInsideFrame()
        }
        for ((near, direction, label) in listOf(Triple(true, "near", "Near −100"), Triple(false, "far", "Far +100"))) {
            compose.onNodeWithTag("focusRack.direction.$direction").assertIsEnabled().performClick()
            compose.onNodeWithTag("focusRack.nudge.100").assertIsEnabled().performClick()
            assertEquals(near to 100, actions.nudges.last())
            compose.runOnIdle { state.value = resting.copy(active = true, phase = "moving", canPause = true,
                canStop = true, primaryTitle = "Pause", primaryEnabled = true, completed = 30, total = 100,
                canNudge = false, canCaptureA = false, canCaptureB = false, canEdit = false,
                canGoToA = false, canGoToB = false, canReset = false,
                admissionMessage = "This move needs at least 4 seconds. Adjust the duration before the next timed pull.",
                nudgeProgress = FocusRackNudgeProgressViewState(near, 100, 30)) }
            compose.onNodeWithContentDescription(label).assertIsDisplayed().assertIsNotEnabled()
            compose.onNodeWithTag("focusRack.direction.$direction").assertIsSelected()
            compose.onNodeWithTag("focusRack.nudgeProgress.100", useUnmergedTree = true).assertTextEquals("30%")
            for (other in listOf(1, 10)) {
                compose.onAllNodesWithTag("focusRack.nudgeProgress.$other", useUnmergedTree = true).assertCountEquals(0)
            }
            assertStableSetup()
            compose.runOnIdle { state.value = state.value.copy(completed = 100,
                nudgeProgress = FocusRackNudgeProgressViewState(near, 100, 100)) }
            compose.onNodeWithTag("focusRack.nudgeProgress.100", useUnmergedTree = true).assertTextEquals("100%")
            assertStableSetup()
            compose.onNodeWithTag("focusRack.stop").assertIsEnabled().performClick()
            compose.saveLandscapeEvidence("focus-rack-nudge-$direction-100-moving-landscape")
            compose.runOnIdle { state.value = state.value.copy(phase = "stopping", position = null,
                canStop = false, primaryEnabled = false) }
            assertStableSetup()
            compose.onNodeWithTag("focusRack.stop").assertIsNotEnabled()
            compose.onNodeWithTag("focusRack.nudgeProgress.100", useUnmergedTree = true).assertTextEquals("100%")
            compose.saveLandscapeEvidence("focus-rack-nudge-$direction-100-stopping-landscape")
            compose.runOnIdle { state.value = resting }
            for (tag in tags) assertEquals(restingBounds[tag], compose.onNodeWithTag(tag).fetchSemanticsNode().boundsInRoot)
            compose.onNodeWithTag("focusRack.direction.$direction").assertIsSelected()
            compose.onNodeWithTag("focusRack.nudge.100").assertTextContains(if (near) "−100" else "+100").assertIsEnabled()
            compose.onNodeWithTag("focusRack.stop").assertDoesNotExist()
        }
        assertEquals(2, actions.stops)
        assertEquals(0, actions.primary)
        compose.saveLandscapeEvidence("focus-rack-nudge-settled-landscape")
    }

    @Test fun currentNudgeDirectionIsShownWithoutReplacingTheIdleSelection() {
        val resting = ready().copy(message = "")
        val state = mutableStateOf(resting)
        val actions = Actions()
        mount(state, actions)
        compose.onNodeWithTag("focusRack.direction.near").assertIsSelected()
        compose.onNodeWithTag("focusRack.direction.far").performClick()
        compose.runOnIdle { state.value = resting.copy(focusMode = "nativeAF") }
        compose.onNodeWithTag("focusRack.nudges").assertDoesNotExist()
        compose.runOnIdle { state.value = resting }
        compose.onNodeWithTag("focusRack.direction.far").assertIsSelected()
        compose.runOnIdle { state.value = resting.copy(active = true, phase = "moving", canStop = true,
            nudgeProgress = FocusRackNudgeProgressViewState(true, 1, 50)) }
        compose.onNodeWithTag("focusRack.direction.near").assertIsSelected().assertIsNotEnabled()
        compose.onNodeWithContentDescription("Near −1").assertIsDisplayed().assertIsNotEnabled()
        compose.runOnIdle { state.value = resting }
        compose.onNodeWithTag("focusRack.direction.far").assertIsSelected()
        compose.onNodeWithTag("focusRack.nudge.100").assertTextContains("+100")
        assertTrue(actions.nudges.isEmpty())
    }

    @Test fun nudgeSelectionAndStepsRespectInterfaceBusyAndStopGates() {
        val state = mutableStateOf(ready())
        val setup = mutableStateOf(false)
        val actions = Actions()
        mount(state, actions, setupEnabled = { setup.value })
        fun assertDisabled() {
            for (id in listOf("direction.near", "direction.far", "nudge.1", "nudge.10", "nudge.100"))
                compose.onNodeWithTag("focusRack.$id").performScrollTo().assertIsNotEnabled().performClick()
            assertTrue(actions.nudges.isEmpty())
        }
        assertDisabled()
        compose.runOnIdle { setup.value = true; state.value = ready().copy(active = true) }
        assertDisabled()
        compose.runOnIdle { state.value = ready().copy(canStop = true) }
        assertDisabled()
        compose.runOnIdle { state.value = ready().copy(phase = "stopping") }
        assertDisabled()
        compose.runOnIdle { state.value = ready() }
        compose.onNodeWithTag("focusRack.direction.near").performScrollTo().assertIsEnabled().assertIsSelected()
        compose.onNodeWithTag("focusRack.nudge.100").performScrollTo().assertIsEnabled()
    }

    @Test fun explicitPositioningRemainsReachableAfterTimingChanges() {
        val state = mutableStateOf(ready())
        val actions = Actions()
        mount(state, actions, updateTiming = true)
        compose.onNodeWithTag("focusRack.go.B").assertIsDisplayed().assertIsEnabled().insideFrame()
        compose.onNodeWithTag("focusRack.duration").performScrollTo().performClick()
        compose.onNodeWithTag("focusRack.editInput").performTextReplacement("10")
        compose.onNodeWithTag("focusRack.editInput").performImeAction()
        waitForKeyboardDismissed()
        compose.onNodeWithTag("focusRack.pull.aToB.detail", useUnmergedTree = true).assertTextEquals("10 s pull")
        compose.runOnIdle { state.value = state.value.copy(primaryEnabled = false,
            admissionMessage = "This move needs at least 19 seconds.", primaryDisabledReason = "Adjust timing",
            playbackInstruction = "Adjust timing", pullAToB = state.value.pullAToB?.copy(enabled = false),
            pullBToA = state.value.pullBToA?.copy(enabled = false)) }
        compose.onNodeWithTag("focusRack.pull.aToB").assertIsNotEnabled()
        compose.onNodeWithTag("focusRack.pull.bToA").assertIsNotEnabled()
        for (id in listOf("A", "B")) {
            compose.onNodeWithTag("focusRack.go.$id").assertIsDisplayed().insideFrame()
            assertTouchTarget("focusRack.go.$id")
        }
        compose.onNodeWithTag("focusRack.go.B").assertIsEnabled().performClick()
        assertEquals(listOf("B"), actions.goes)
        assertTransportInsideFrame()
        compose.saveLandscapeEvidence("focus-rack-explicit-actions-landscape")
    }

    @Test fun compactBlockedPlaybackExposesFastPositioning() {
        val state = mutableStateOf(ready().copy(
            admissionMessage = "Use Go to A or Go to B once to measure this move before timed playback.",
            playbackInstruction = "Measure move",
            pullAToB = ready().pullAToB?.copy(enabled = false),
            pullBToA = ready().pullBToA?.copy(enabled = false)))
        val actions = Actions()
        mount(state, actions, compact = true, maximumHeight = 112f)
        compose.onNodeWithTag("focusRack.go.B").assertIsDisplayed().assertIsEnabled().insideFrame()
        compose.onNodeWithTag("focusRack.go.B").performClick()
        compose.onNodeWithTag("focusRack.pull.aToB").assertDoesNotExist()
        assertEquals(listOf("B"), actions.goes)
        assertTransportInsideFrame()
        compose.saveLandscapeEvidence("focus-rack-blocked-compact-positioning")
    }

    @Test fun headerDragMovesPanelAndBodyScrollDoesNot() {
        val state = mutableStateOf(ready())
        val actions = Actions()
        mount(state, actions)
        compose.onNodeWithTag("focusRack.dragHandle").performTouchInput { swipeLeft() }
        assertTrue(actions.moves.any { it.x < 0f })
        compose.runOnIdle { actions.moves.clear() }
        compose.onNodeWithTag("focusRack.setup").performTouchInput { swipeUp() }
        assertTrue(actions.moves.isEmpty())
        assertTrue(actions.nudges.isEmpty())
        assertTransportInsideFrame()
    }

    @Test fun directPullsExposeDurationDelayAndFastPositioningInLandscape() {
        val state = mutableStateOf(ready())
        val actions = Actions()
        mount(state, actions, updateTiming = true)
        compose.onNodeWithTag("focusRack.duration").performScrollTo().assertIsDisplayed()
        compose.onNodeWithTag("focusRack.delay").assertIsDisplayed()
        compose.onNodeWithTag("focusRack.mode.fastest").assertDoesNotExist()
        compose.onNodeWithTag("focusRack.pull.aToB").assertIsEnabled().performClick()
        compose.onNodeWithTag("focusRack.pull.bToA").assertIsNotEnabled()
        assertEquals(listOf("aToB"), actions.runs)
        assertTransportInsideFrame()
        compose.saveLandscapeEvidence("focus-rack-direct-actions-landscape")
    }

    @Test fun directPullsRetainTimingAndTransportInPortrait() {
        compose.settlePortrait()
        val state = mutableStateOf(ready())
        mount(state, Actions())
        compose.onNodeWithTag("focusRack.duration").performScrollTo().assertIsDisplayed()
        compose.onNodeWithTag("focusRack.delay").assertIsDisplayed()
        compose.onNodeWithTag("focusRack.pull.aToB.detail", useUnmergedTree = true).assertTextEquals("24 s pull")
        assertTransportInsideFrame()
        compose.savePortraitEvidence("focus-rack-direct-actions-portrait")
    }

    @Test fun moveEditorForwardsDurationDelayAndKeepsLinearOptions() {
        val state = mutableStateOf(ready())
        val actions = Actions()
        mount(state, actions, updateTiming = true)
        compose.onNodeWithTag("focusRack.duration").performScrollTo().performClick()
        compose.onNodeWithTag("focusRack.editInput").performClick().performTextReplacement("32")
        compose.onNodeWithTag("focusRack.editInput").performImeAction()
        compose.onNodeWithTag("focusRack.applyEdit").assertDoesNotExist()
        assertEquals(Timing("32", "2.0", "linear", false), actions.timings.single())
        waitForKeyboardDismissed()
        compose.onNodeWithTag("focusRack.delay").performScrollTo().performClick()
        compose.onNodeWithTag("focusRack.editInput").performClick().performTextReplacement("3")
        compose.onNodeWithTag("focusRack.applyEdit").assertIsDisplayed().performClick()
        compose.onNodeWithTag("focusRack.applyEdit").assertDoesNotExist()
        waitForKeyboardDismissed()
        openOptions()
        compose.onNodeWithText("Options · Linear").assertIsDisplayed()
        compose.onNodeWithText("Ease in-out").assertDoesNotExist()
        compose.onNodeWithText("Ease in-out starts and finishes gently; it may need a longer duration.").assertDoesNotExist()
        assertEquals(32.0, actions.timings.last().duration.toDouble(), 0.0)
        assertEquals(3.0, actions.timings.last().delay.toDouble(), 0.0)
        assertEquals("linear", actions.timings.last().easing)
        assertFalse(actions.timings.last().reverse)
        assertEquals("A", state.value.fromMark)
        assertEquals("B", state.value.toMark)
        assertTransportInsideFrame()
        compose.saveLandscapeEvidence("focus-rack-production-move-landscape")
        compose.runOnIdle { state.value = state.value.copy(canEdit = false) }
        compose.onNodeWithTag("focusRack.duration").performScrollTo().assertIsNotEnabled()
        compose.onNodeWithTag("focusRack.delay").assertIsNotEnabled()
        compose.onNodeWithText("Ease in-out").assertDoesNotExist()
    }

    @Test fun sharedTransportLabelsAndCallbacksCoverRehearseRunPauseResumeAndStop() {
        val state = mutableStateOf(ready())
        val actions = Actions()
        mount(state, actions)
        compose.onNodeWithText("Rehearse A→B").assertIsEnabled().performClick()
        compose.runOnIdle { state.value = state.value.copy(position = 94,
            pullAToB = state.value.pullAToB?.copy(enabled = false),
            pullBToA = state.value.pullBToA?.copy(title = "Run B→A", enabled = true)) }
        compose.onNodeWithText("Run B→A").assertIsEnabled().performClick()
        assertEquals(listOf("aToB", "bToA"), actions.runs)
        for ((phase, title) in listOf("moving" to "Pause", "paused" to "Resume")) {
            compose.runOnIdle { state.value = state.value.copy(phase = phase, active = true,
                primaryTitle = title, canPause = title == "Pause", canStop = true, primaryEnabled = true) }
            compose.onNodeWithText(title).assertIsDisplayed().assertIsEnabled().performClick()
            assertTransportInsideFrame()
        }
        assertEquals(2, actions.primary)
        compose.onNodeWithTag("focusRack.stop").performClick()
        assertEquals(1, actions.stops)
        compose.runOnIdle { state.value = state.value.copy(phase = "stopping", primaryEnabled = false) }
        compose.onNodeWithTag("focusRack.primary").assertIsNotEnabled()
        compose.onNodeWithTag("focusRack.stop").assertIsDisplayed()
        compose.saveLandscapeEvidence("focus-rack-production-stopping-landscape")
    }

    @Test fun compactCleanAndLockedTransportKeepsMinimumTouchTargets() {
        val state = mutableStateOf(ready().copy(phase = "countdown", primaryTitle = "Pause",
            active = true, canPause = true, canStop = true, remainingDelay = 1.4))
        val locked = mutableStateOf(true)
        val actions = Actions()
        mount(state, actions, compact = true, maximumHeight = 128f, setupEnabled = { !locked.value })
        compose.onNodeWithText("Starts in 1.4 s").assertIsDisplayed()
        compose.onNodeWithTag("focusRack.expand").assertIsNotEnabled()
        compose.onNodeWithTag("focusRack.primary").assertIsEnabled().performClick()
        compose.onNodeWithTag("focusRack.stop").assertIsEnabled().performClick()
        assertEquals(1, actions.primary)
        assertEquals(1, actions.stops)
        assertTransportInsideFrame()
        compose.saveLandscapeEvidence("focus-rack-production-locked-landscape")
        compose.runOnIdle {
            state.value = state.value.copy(phase = "paused", primaryTitle = "Resume", canPause = false)
        }
        compose.onNodeWithText("Resume").assertIsNotEnabled()
        compose.runOnIdle { locked.value = false }
        compose.onNodeWithText("Paused").assertIsDisplayed()
        compose.onNodeWithText("Resume").assertIsEnabled().performClick()
        compose.onNodeWithTag("focusRack.expand").assertIsEnabled().performClick()
        assertEquals(2, actions.primary)
        assertEquals(listOf(true), actions.expansions)
        assertTransportInsideFrame()
        compose.saveLandscapeEvidence("focus-rack-production-clean-paused-landscape")
    }

    @Test fun compactTimingWarningStaysVisibleAndStopRemainsAvailableWhileLocked() {
        val state = mutableStateOf(ready().copy(timingWarning = "3 s target · ~28.07 s estimated. Timing is advisory."))
        val locked = mutableStateOf(false)
        val actions = Actions()
        mount(state, actions, compact = true, maximumHeight = 112f, setupEnabled = { !locked.value })
        compose.onNodeWithText("Timing warning").assertIsDisplayed().insideFrame()
        compose.onNodeWithTag("focusRack.expand").performClick()
        assertEquals(listOf(true), actions.expansions)
        compose.runOnIdle {
            locked.value = true
            state.value = state.value.copy(active = true, phase = "moving", canStop = true,
                canPause = true, primaryTitle = "Pause", primaryEnabled = true)
        }
        compose.onNodeWithText("Running late").assertIsDisplayed().insideFrame()
        compose.onNodeWithTag("focusRack.expand").assertIsNotEnabled()
        compose.onNodeWithTag("focusRack.stop").assertIsEnabled().performClick()
        assertEquals(1, actions.stops)
        assertTransportInsideFrame()
        compose.saveLandscapeEvidence("focus-rack-compact-timing-warning-locked-landscape")
    }

    @Test fun compactRecoveryNamesRemainVisibleWhileLocked() {
        val state = mutableStateOf(ready().copy(phase = "stopUnconfirmed", position = null,
            primaryTitle = "Reconnect camera", primaryEnabled = false, canStop = false,
            recovery = "Reconnect camera, then reset both marks."))
        mount(state, Actions(), compact = true, maximumHeight = 112f, setupEnabled = { false })
        compose.onNodeWithText("Stop unconfirmed").assertIsDisplayed().insideFrame()
        compose.onNodeWithText("Reconnect camera").assertIsDisplayed()
        compose.onNodeWithTag("focusRack.primary").assertIsNotEnabled()
        assertTransportInsideFrame()
        compose.saveLandscapeEvidence("focus-rack-production-locked-unconfirmed-landscape")
        compose.runOnIdle {
            state.value = state.value.copy(phase = "uncertain", primaryTitle = "Reset marks",
                primaryEnabled = true, recovery = "Reset marks after an external focus change.")
        }
        compose.onNodeWithText("Reference uncertain").assertIsDisplayed().insideFrame()
        compose.onNodeWithText("Reset marks").assertIsDisplayed()
        compose.onNodeWithTag("focusRack.primary").assertIsNotEnabled()
        compose.onNodeWithTag("focusRack.expand").assertIsNotEnabled()
        assertTransportInsideFrame()
        compose.saveLandscapeEvidence("focus-rack-production-locked-uncertain-landscape")
    }

    @Test fun plannedTimedDurationIsVisibleWithoutDisablingTheRequestedPull() {
        val state = mutableStateOf(ready().copy(duration = 3.0, estimatedDuration = 3.4,
            timingWarning = "Camera cadence is slower; this pull may exceed 3 s.",
            pullAToB = FocusRackActionViewState("Rehearse A→B", "3 s target · ~3.4 s estimated", true)))
        mount(state, Actions())
        compose.onNodeWithTag("focusRack.pull.aToB").assertIsEnabled().assertIsDisplayed().insideFrame()
        compose.onNodeWithTag("focusRack.estimate").performScrollTo()
            .assertTextEquals("3 s target · ~3.40 s estimated").assertIsDisplayed().insideFrame()
        compose.onNodeWithTag("focusRack.timingWarning").performScrollTo()
            .assertTextEquals("Camera cadence is slower; this pull may exceed 3 s.").assertIsDisplayed().insideFrame()
        compose.onNodeWithTag("focusRack.pull.aToB").assertIsEnabled()
        compose.saveLandscapeEvidence("timed-rack-planned-estimate-landscape")
    }

    @Test fun calibrationAdmissionHintRemainsReadableAndEditable() {
        val reason = "Use Go to A or Go to B once to measure this move before timed playback."
        val state = mutableStateOf(ready().copy(admissionMessage = reason, primaryEnabled = false,
            playbackInstruction = "Measure move", pullAToB = ready().pullAToB?.copy(enabled = false),
            pullBToA = ready().pullBToA?.copy(enabled = false)))
        mount(state, Actions())
        compose.onNodeWithTag("focusRack.dragHandle").assertIsDisplayed().insideFrame().performClick()
        compose.onNodeWithTag("focusRack.admission").assertIsDisplayed().insideFrame()
        compose.onNodeWithText(reason).assertIsDisplayed()
        assertTransportInsideFrame()
        compose.saveLandscapeEvidence("focus-rack-production-admission-landscape")
        compose.onNodeWithTag("focusRack.duration").performScrollTo().assertIsDisplayed().assertIsEnabled()
    }

    @Test fun longRecoveryAndResetRemainReachableWithoutCoveringTransport() {
        val recovery = "Reconnect the camera, select AF-S and reset both marks. Wait for a fresh image before setting A again."
        val state = mutableStateOf(ready().copy(position = null, marks = emptyList(),
            phase = "uncertain", primaryTitle = "Reset marks", canNudge = false,
            error = "SIMULATED camera failure with detailed feedback. ".repeat(15), recovery = recovery,
            canCaptureA = false, canCaptureB = false, canStop = true))
        val actions = Actions()
        mount(state, actions)
        compose.onNodeWithTag("focusRack.recovery").assertIsDisplayed().insideFrame()
        compose.onNodeWithTag("focusRack.primary").assertIsEnabled().performClick()
        openOptions()
        compose.onNodeWithTag("focusRack.reset").performScrollTo().assertIsEnabled().performClick()
        assertEquals(1, actions.primary)
        assertEquals(1, actions.resets)
        assertTransportInsideFrame()
        compose.saveLandscapeEvidence("focus-rack-production-recovery-landscape")
    }

    @Test fun timingTemplatesExplainFreshMarksAndForwardOnlyNamedTemplateIntents() {
        val template = FocusRackTimingViewState("Slow rack", "{\"name\":\"Slow rack\"}")
        val state = mutableStateOf(ready())
        val actions = Actions()
        mount(state, actions, templates = listOf(template))
        openOptions()
        compose.onNodeWithText("Timing templates require fresh marks when loaded.")
            .performScrollTo().assertIsDisplayed()
        compose.onNodeWithTag("focusRack.saveTemplate").performScrollTo().performClick()
        compose.onNodeWithTag("focusRack.editInput").performClick().performTextReplacement("Return rack")
        compose.saveLandscapeEvidence("focus-rack-production-template-editor-ime-landscape")
        compose.onNodeWithTag("focusRack.editInput").performImeAction()
        compose.onNodeWithTag("focusRack.applyEdit").assertDoesNotExist()
        compose.onNodeWithText("Slow rack").performScrollTo().performClick()
        compose.onNodeWithContentDescription("Delete Slow rack timing template")
            .assertIsDisplayed().performClick()
        assertEquals(listOf("Return rack"), actions.saved)
        assertEquals(listOf(template), actions.loaded)
        assertEquals(listOf(template), actions.deleted)
        assertTransportInsideFrame()
        compose.saveLandscapeEvidence("focus-rack-production-templates-landscape")
    }

    @Test fun templateEditorActionsStayAboveTheLandscapeKeyboard() {
        val state = mutableStateOf(ready())
        mount(state, Actions())
        val fullHeight = compose.onRoot().fetchSemanticsNode().boundsInRoot.height
        openOptions()
        compose.onNodeWithTag("focusRack.saveTemplate").performScrollTo().performClick()
        compose.onNodeWithTag("focusRack.editInput").performClick().performTextReplacement("Return rack")
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val device = UiDevice.getInstance(instrumentation)
        fun keyboardBounds(): Rect? = instrumentation.uiAutomation.windows
            .firstOrNull { it.type == AccessibilityWindowInfo.TYPE_INPUT_METHOD }
            ?.let { window -> Rect().also { window.getBoundsInScreen(it) } }
        compose.waitUntil(5_000) { keyboardBounds() != null }
        compose.saveLandscapeEvidence("focus-rack-production-editor-actions-ime-landscape")
        val keyboard = requireNotNull(keyboardBounds())
        for (label in listOf("Save", "Cancel")) {
            val button = device.wait(Until.findObject(By.text(label)), 5_000)
                ?: throw AssertionError("Missing editor action: $label")
            val bounds = button.visibleBounds
            assertTrue("$label must remain above the keyboard: $bounds, keyboard $keyboard",
                bounds.height() > 0 && bounds.top >= 0 && bounds.bottom <= keyboard.top &&
                    bounds.left >= 0 && bounds.right <= device.displayWidth)
        }
        compose.onNodeWithTag("focusRack.editInput").performImeAction()
        compose.waitUntil(5_000) { keyboardBounds() == null }
        // IME window removal precedes the activity's resize animation finishing.
        compose.waitUntil(5_000) {
            compose.onRoot().fetchSemanticsNode().boundsInRoot.height >= fullHeight
        }
        compose.waitUntil(5_000) {
            val root = compose.onRoot().fetchSemanticsNode().boundsInRoot
            listOf("focusRack.pull.aToB", "focusRack.pull.bToA").all { tag ->
                compose.onAllNodesWithTag(tag).fetchSemanticsNodes().singleOrNull()?.boundsInRoot?.let {
                    it.width > 0f && it.height > 0f && it.left >= root.left && it.top >= root.top &&
                        it.right <= root.right && it.bottom <= root.bottom
                } == true
            }
        }
        compose.saveLandscapeEvidence("focus-rack-editor-dismissed-landscape")
        assertTransportInsideFrame()
    }

    @Test fun stopIsAbsentAtRestAndRemainsVisibleUntilCancellationSettles() {
        val state = mutableStateOf(ready())
        mount(state, Actions())
        compose.onNodeWithTag("focusRack.stop").assertDoesNotExist()
        compose.runOnIdle { state.value = state.value.copy(active = true, phase = "moving",
            primaryTitle = "Pause", canPause = true, canStop = true) }
        compose.onNodeWithTag("focusRack.stop").assertIsDisplayed().assertIsEnabled()
        compose.onNodeWithTag("focusRack.stopHint").assertTextEquals("Stop cancels focus movement only.")
        compose.runOnIdle { state.value = state.value.copy(phase = "stopping", primaryTitle = "Stopping…",
            primaryEnabled = false, canPause = false, canStop = false) }
        compose.onNodeWithTag("focusRack.stop").assertIsDisplayed().assertIsNotEnabled().insideFrame()
        assertTransportInsideFrame()
    }

    @Test fun closeRequiresConfirmationAndIsDisabledDuringMovement() {
        val state = mutableStateOf(ready())
        val actions = Actions()
        mount(state, actions)
        compose.onNodeWithTag("focusRack.close").assertIsDisplayed().assertIsEnabled().performClick()
        compose.onNodeWithText("Session marks will be discarded. Saved timing templates remain available.")
            .assertIsDisplayed()
        compose.onNodeWithText("Keep open").performClick()
        assertEquals(0, actions.closes)
        compose.onNodeWithTag("focusRack.close").performClick()
        compose.saveLandscapeEvidence("focus-rack-production-close-confirmation-landscape")
        compose.onNodeWithText("Discard marks and close").performClick()
        assertEquals(1, actions.closes)
        compose.runOnIdle { state.value = state.value.copy(active = true, canStop = true) }
        compose.onNodeWithTag("focusRack.close").assertIsNotEnabled()
        compose.onNodeWithTag("focusRack.stop").assertIsEnabled()
    }

    @Test fun portraitTightRecoveryAndTransportStayWithinAllFourEdges() {
        compose.settlePortrait()
        val state = mutableStateOf(ready().copy(phase = "paused", primaryTitle = "Resume",
            canStop = true, active = true, recovery = "Reset both marks after an external focus change."))
        mount(state, Actions(), maximumHeight = 300f)
        compose.onNodeWithTag("focusRack.positions").assertTextEquals("A 0 · B 94 · Now 0")
            .assertIsDisplayed().insideFrame()
        compose.onNodeWithTag("focusRack.recovery").assertIsDisplayed().insideFrame()
        assertTransportInsideFrame()
        compose.onNodeWithTag("focusRack.duration").performScrollTo().assertIsDisplayed()
        assertTransportInsideFrame()
        compose.savePortraitEvidence("focus-rack-production-tight-portrait")
    }

    @Test fun setupChangeAdvisesWithoutRequiringReset() {
        val advisory = "Camera setup changed. Check A and B; reset marks if needed."
        val actions = Actions()
        val state = mutableStateOf(ready().copy(message = advisory))
        mount(state, actions)
        compose.onNodeWithTag("focusRack.pull.aToB").assertIsEnabled()
        compose.onNodeWithTag("focusRack.nudge.10").assertIsEnabled()
        compose.onNodeWithTag("focusRack.message").performScrollTo().assertTextEquals(advisory).assertIsDisplayed()
        assertTransportInsideFrame()
        compose.saveLandscapeEvidence("focus-rack-operator-owned-reset-landscape")
        assertEquals(0, actions.resets)
        openOptions()
        compose.onNodeWithTag("focusRack.reset").performScrollTo().assertIsEnabled().performClick()
        assertEquals(1, actions.resets)
    }

    @Test fun calibrationProjectsSharedStagesAndKeepsStopReachableInLandscape() {
        val state = mutableStateOf(ready())
        val setup = mutableStateOf(true)
        val actions = Actions()
        mount(state, actions, setupEnabled = { setup.value })
        openOptions()
        compose.onNodeWithTag("focusRack.calibrate").assertDoesNotExist()
        val next = FocusRackActionViewState("Calibrate to B", "32-pulse increments · 1/10", true)
        compose.runOnIdle { state.value = state.value.copy(calibration = next) }
        compose.onNodeWithTag("focusRack.calibrate").performScrollTo().assertIsEnabled()
            .assertTextContains(next.title).assertTextContains(requireNotNull(next.detail)).insideFrame()
        assertTouchTarget("focusRack.calibrate")
        compose.onNodeWithTag("focusRack.calibrate").performClick()
        assertEquals(1, actions.calibrations)
        assertTransportInsideFrame()
        compose.saveLandscapeEvidence("focus-rack-calibration-next-landscape")

        compose.runOnIdle { state.value = state.value.copy(calibration =
            FocusRackActionViewState("Calibrate to A", "32-pulse increments · 2/10", true)) }
        compose.onNodeWithTag("focusRack.calibrate").assertTextContains("Calibrate to A")
            .assertTextContains("32-pulse increments · 2/10").assertIsEnabled()
        compose.runOnIdle { setup.value = false }
        compose.onNodeWithTag("focusRack.calibrate").assertIsNotEnabled()
        compose.runOnIdle { setup.value = true; state.value = state.value.copy(active = true, phase = "moving",
            canStop = true, primaryTitle = "Pause", canPause = true, primaryEnabled = true, completed = 30, total = 100) }
        compose.onNodeWithTag("focusRack.calibrate").performScrollTo().assertIsNotEnabled().insideFrame()
        compose.onNodeWithTag("focusRack.stop").assertIsEnabled().performClick()
        assertEquals(1, actions.stops)
        assertTransportInsideFrame()
        compose.saveLandscapeEvidence("focus-rack-calibration-moving-landscape")

        compose.runOnIdle { state.value = state.value.copy(phase = "stopping", canStop = false, primaryEnabled = false) }
        compose.onNodeWithTag("focusRack.calibrate").assertIsNotEnabled()
        compose.onNodeWithTag("focusRack.stop").assertIsNotEnabled()
        assertTransportInsideFrame()
        compose.saveLandscapeEvidence("focus-rack-calibration-stopping-landscape")
        compose.runOnIdle { state.value = ready().copy(calibration =
            FocusRackActionViewState("Calibration measured", "All 5 sizes in both directions", false)) }
        compose.onNodeWithTag("focusRack.calibrate").performScrollTo().assertIsNotEnabled()
            .assertTextContains("Calibration measured").assertTextContains("All 5 sizes in both directions").insideFrame()
        compose.onNodeWithTag("focusRack.stop").assertDoesNotExist()
        assertEquals(1, actions.calibrations)
        assertTransportInsideFrame()
        compose.saveLandscapeEvidence("focus-rack-calibration-complete-landscape")
    }

    private fun waitForKeyboardDismissed() {
        compose.waitUntil(5_000) {
            InstrumentationRegistry.getInstrumentation().uiAutomation.windows.none {
                it.type == AccessibilityWindowInfo.TYPE_INPUT_METHOD
            }
        }
    }

    private fun mount(state: MutableState<FocusRackViewState>, actions: Actions,
        compact: Boolean = false, maximumHeight: Float = 320f,
        templates: List<FocusRackTimingViewState> = emptyList(),
        setupEnabled: () -> Boolean = { true }, updateTiming: Boolean = false,
        nativePointLocked: () -> Boolean = { false }, onUnlockNativeFocusPoint: () -> Unit = {},
    ) {
        compose.setContent {
            MaterialTheme {
                Box(Modifier.fillMaxSize().background(Color(0xFF101216)).safeDrawingPadding().padding(12.dp),
                    contentAlignment = Alignment.CenterEnd) {
                    Box(Modifier.width(300.dp)) {
                        FocusRackPanel(state.value, emptyMap(), templates, compact, maximumHeight,
                            expanded = true, onExpanded = { actions.expansions += it },
                            onCapture = { actions.captures += it },
                            onNudge = { near, steps -> actions.nudges += near to steps },
                            onTiming = { edit ->
                                val current = state.value
                                val duration = edit.duration ?: current.duration.toString()
                                val delay = edit.delay ?: current.delay.toString()
                                val easing = edit.easing ?: current.easing
                                val reverse = edit.reverse ?: (current.fromMark == "B")
                                actions.timings += Timing(duration, delay, easing, reverse)
                                if (updateTiming) state.value = current.copy(duration = duration.toDouble(),
                                    delay = delay.toDouble(), easing = easing,
                                    durationMode = edit.durationMode ?: current.durationMode,
                                    fromMark = if (reverse) "B" else "A", toMark = if (reverse) "A" else "B",
                                    primaryDetail = "${duration.removeSuffix(".0")} s pull",
                                    pullAToB = current.pullAToB?.copy(detail = "${duration.removeSuffix(".0")} s pull"),
                                    pullBToA = current.pullBToA?.copy(detail = "${duration.removeSuffix(".0")} s pull"))
                            }, onPrimary = { actions.primary++ }, onStop = { actions.stops++ },
                            onReset = { actions.resets++ }, onSave = { actions.saved += it },
                            onLoad = { actions.loaded += it }, onDelete = { actions.deleted += it },
                            onFocusSettings = { actions.focusSettings++ }, setupEnabled = setupEnabled(), onClose = { actions.closes++ },
                            onGoTo = { actions.goes += it }, onRun = { actions.runs += it },
                            onCalibrate = { actions.calibrations++ }, onMovePanel = { actions.moves += it },
                            onFocusMode = { mode -> state.value = state.value.copy(focusMode = mode) },
                            onNativeSet = { actions.nativeSets += it }, onNativeGo = { actions.nativeGoes += it },
                            onNativeRun = { actions.nativeRuns += it }, onNativeCancel = { actions.nativeCancels++ },
                            onNativeDelay = { actions.nativeDelays += it }, nativeAFPointLocked = nativePointLocked(),
                            onUnlockNativeFocusPoint = { actions.nativeUnlocks++; onUnlockNativeFocusPoint() })
                    }
                }
            }
        }
    }

    private fun openOptions() {
        compose.onNodeWithTag("focusRack.options").performScrollTo().performClick()
    }

    private fun assertTransportInsideFrame() {
        val actions = when {
            compose.onAllNodesWithTag("focusRack.primary").fetchSemanticsNodes().isNotEmpty() ->
                listOf("focusRack.primary")
            compose.onAllNodesWithTag("focusRack.pull.aToB").fetchSemanticsNodes().isNotEmpty() ->
                listOf("focusRack.pull.aToB", "focusRack.pull.bToA")
            else -> listOf("focusRack.go.A", "focusRack.go.B")
        }
        val visibleActions = if (compose.onAllNodesWithTag("focusRack.stop").fetchSemanticsNodes().isNotEmpty())
            actions + "focusRack.stop" else actions
        for (tag in visibleActions) {
            compose.onNodeWithTag(tag).assertIsDisplayed().insideFrame()
            assertTouchTarget(tag)
        }
        compose.onNodeWithTag("focusRack.panel").insideFrame()
    }

    private fun assertTouchTarget(tag: String) {
        compose.onNodeWithTag(tag).assertHeightIsAtLeast(48.dp).assertWidthIsAtLeast(48.dp)
    }

    private fun SemanticsNodeInteraction.insideFrame(): SemanticsNodeInteraction {
        val bounds = fetchSemanticsNode().boundsInRoot
        val frame = compose.onRoot().fetchSemanticsNode().boundsInRoot
        assertTrue("All edges must fit inside the display: $bounds within $frame",
            bounds.left >= frame.left && bounds.top >= frame.top &&
                bounds.right <= frame.right && bounds.bottom <= frame.bottom)
        return this
    }

    private fun ready() = FocusRackViewState(message = "SIMULATED ready.", position = 0,
        marks = listOf(mark("A", 0), mark("B", 94)), duration = 24.0, delay = 2.0,
        primaryTitle = "Rehearse A→B", primaryEnabled = true, primaryDetail = "24 s pull",
        pullAToB = FocusRackActionViewState("Rehearse A→B", "24 s pull", true),
        pullBToA = FocusRackActionViewState("Rehearse B→A", "24 s pull", false, "Go to B first"),
        canGoToB = true, canCaptureA = true,
        canCaptureB = true, canNudge = true, canEdit = true, canReset = true)

    private fun mark(id: String, position: Int) = FocusRackMarkViewState(id, position, 1, "fixture", 1)
    private data class Timing(val duration: String, val delay: String, val easing: String, val reverse: Boolean)
    private class Actions {
        val nativeSets = mutableListOf<String>()
        val nativeGoes = mutableListOf<String>()
        val nativeRuns = mutableListOf<String>()
        val nativeDelays = mutableListOf<String>()
        var nativeCancels = 0
        var nativeUnlocks = 0
        val captures = mutableListOf<String>()
        val goes = mutableListOf<String>()
        val runs = mutableListOf<String>()
        val moves = mutableListOf<androidx.compose.ui.geometry.Offset>()
        val nudges = mutableListOf<Pair<Boolean, Int>>()
        val timings = mutableListOf<Timing>()
        val saved = mutableListOf<String>()
        val loaded = mutableListOf<FocusRackTimingViewState>()
        val deleted = mutableListOf<FocusRackTimingViewState>()
        val expansions = mutableListOf<Boolean>()
        var primary = 0
        var calibrations = 0
        var stops = 0
        var resets = 0
        var focusSettings = 0
        var closes = 0
    }
}

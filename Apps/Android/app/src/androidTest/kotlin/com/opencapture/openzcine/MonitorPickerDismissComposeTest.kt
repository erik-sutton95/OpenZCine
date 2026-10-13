package com.opencapture.openzcine

import android.content.Context
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assertIsOff
import androidx.compose.ui.test.assertIsOn
import androidx.compose.ui.test.click
import androidx.compose.ui.test.hasClickAction
import androidx.compose.ui.test.hasAnyDescendant
import androidx.compose.ui.test.hasContentDescription
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.isRoot
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performSemanticsAction
import androidx.compose.ui.test.performTouchInput
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.UiDevice
import com.opencapture.opencine.appkit.MonitorControlModel
import com.opencapture.opencine.nikon.CameraCommandAdmission
import com.opencapture.opencine.nikon.CameraControl
import com.opencapture.opencine.nikon.CameraControlCapabilities
import com.opencapture.opencine.nikon.CameraIdentity
import com.opencapture.opencine.nikon.CameraPropertySnapshot
import com.opencapture.opencine.nikon.CameraSession
import com.opencapture.opencine.nikon.FakeCameraSession
import com.opencapture.opencine.nikon.NikonOpenCineSession
import com.opencapture.openzcine.settings.OperatorSettings
import java.util.concurrent.CopyOnWriteArrayList
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.flow.MutableStateFlow
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Instrumented contract that the monitor's camera panel stays dismissable while its
 * camera-control write is in flight (#328). A focus-mode write can hold the command mutex
 * for seconds (or wedge entirely on a flaky link); gating Back or the backdrop on the pending
 * write trapped the operator in the popup with no exit but killing the app. iOS
 * `dismissActivePanel` has no such gate: dismissal is always allowed and the write
 * finishes in the background.
 */
@OptIn(ExperimentalTestApi::class)
@RunWith(AndroidJUnit4::class)
class MonitorPickerDismissComposeTest {
    @get:Rule
    val composeRule = createComposeRule()

    private val sharedDrum = SemanticsMatcher.keyIsDefined(SemanticsProperties.ProgressBarRangeInfo)
    private val close = hasTestTag("monitor.capture.close")

    @Test
    fun backDismissesThePanelWhileItsWriteIsPending() = dismissWhilePending {
        UiDevice.getInstance(InstrumentationRegistry.getInstrumentation()).pressBack()
    }

    @Test
    fun backdropTapDismissesThePanelWhileItsWriteIsPending() = dismissWhilePending {
        // Above the bottom panel, over the picture: the shared dismiss backdrop.
        // A drum's small popup is a second native root. Tap the actual monitor's backdrop.
        composeRule.onNode(isRoot() and hasAnyDescendant(hasTestTag("monitor_live_feed")),
            useUnmergedTree = true).performTouchInput { click(Offset(width / 2f, height * 0.3f)) }
    }

    /** The focus-dial row is a switch to TalkBack, so it must also say whether it is on. */
    @Test
    fun focusDialRowReportsWhetherItIsOn() {
        val request =
            CommandControlRequest(
                title = "Focus",
                control = CameraControl.FOCUS_MODE,
                currentValue = "AF-C",
                options = listOf("AF-S", "AF-C", "MF"),
            )
        val picker = MonitorPickerPresentation(
            kind = MonitorPickerKind.FOCUS,
            title = "FOCUS",
            subtitle = "AF-C",
            modes = listOf(MonitorPickerModePresentation(label = "MODE", request = request)),
        )
        var enabled by mutableStateOf(true)
        composeRule.setContent {
            MonitorControlPickerPanel(
                picker = picker,
                controlsEnabled = true,
                feedback = null,
                onSelect = { _, _ -> },
                onDismiss = {},
                mfScrubEnabled = enabled,
                onToggleMfScrub = { enabled = !enabled },
            )
        }

        composeRule.onNodeWithText("Focus dial").assertIsOn().performClick()
        composeRule.onNodeWithText("Focus dial").assertIsOff()
    }

    private fun dismissWhilePending(dismiss: () -> Unit) {
        val session = GatedCamera()
        mount(session)
        composeRule.onNode(hasContentDescription("ISO", substring = true) and hasClickAction()).performClick()
        composeRule.waitUntilAtLeastOneExists(close, 5_000)
        // Settle the ISO drum on another value: the write queues and holds at the gate.
        val drum = composeRule.onNode(hasContentDescription("800") and sharedDrum)
        val range = drum.fetchSemanticsNode().config[SemanticsProperties.ProgressBarRangeInfo]
        val target = if (range.current < range.range.endInclusive) range.range.endInclusive else range.range.start
        drum.performSemanticsAction(SemanticsActions.SetProgress) { it(target) }
        composeRule.waitUntil(5_000) { session.queued }

        dismiss()

        composeRule.waitUntilDoesNotExist(close, 5_000)
        assertTrue("the write is still in flight", session.queued)
        session.gate.complete(Unit)
        composeRule.waitUntil(5_000) { session.writes.isNotEmpty() }
    }

    private fun mount(session: CameraSession) {
        composeRule.setContent {
            val context = LocalContext.current
            val settings = remember { OperatorSettings(context.getSharedPreferences(
                "SIMULATED-picker-dismiss", Context.MODE_PRIVATE).also { it.edit().clear().commit() }) }
            val scope = rememberCoroutineScope()
            val common = remember { NikonOpenCineSession(session, scope) }
            val control = remember { MonitorControlModel(scope).also { it.bind(common) } }
            DisposableEffect(Unit) { onDispose { control.unbind() } }
            OpenZCineTheme {
                val assists = remember { idleNikonAssists() }
                MonitorScreen(session, common, control, rememberTestOperatorSession(assists, settings), frameSource = null,
                    assists = assists, operatorSettings = settings, liveViewEnabled = false, sessionRecoveryEnabled = false)
            }
        }
        composeRule.waitUntilAtLeastOneExists(hasContentDescription("ISO", substring = true), 5_000)
    }

    /** SIMULATED video body whose ISO write waits for the test to release it. */
    private class GatedCamera : CameraSession by FakeCameraSession(
        CameraIdentity("SIMULATED", "SIMULATED", "picker-dismiss"), startConnected = true) {
        override val cameraProperties = MutableStateFlow(CameraPropertySnapshot(
            captureSelector = "video", iso = 800, isoAuto = false, exposureMode = "M",
            controlCapabilities = CameraControlCapabilities(isoValues = listOf("400", "800", "1600"))))
        override val reportedCameraProperties = cameraProperties
        override val reportedRecording = MutableStateFlow<Boolean?>(false)
        val writes = CopyOnWriteArrayList<Pair<CameraControl, String>>()
        val gate = CompletableDeferred<Unit>()
        @Volatile var queued = false
        override suspend fun refreshProperties() = Unit
        // The ISO drum may write through the shared control model with or without an admission,
        // so both routes hold at the gate.
        override suspend fun applyControl(control: CameraControl, label: String) =
            hold { writes += control to label }
        override suspend fun applyControl(control: CameraControl, label: String, admission: CameraCommandAdmission) =
            hold { if (admission.admits(this)) writes += control to label }
        private suspend fun hold(write: () -> Unit) {
            queued = true
            try {
                gate.await()
                write()
            } finally { queued = false }
        }
    }
}

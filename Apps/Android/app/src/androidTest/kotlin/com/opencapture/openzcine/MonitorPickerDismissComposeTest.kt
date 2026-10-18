package com.opencapture.openzcine

import android.content.Context
import android.graphics.Bitmap
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assertIsOff
import androidx.compose.ui.test.assertIsOn
import androidx.compose.ui.test.hasContentDescription
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.isRoot
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.performSemanticsAction
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.printToString
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.UiDevice
import com.opencapture.opencine.nikon.CameraCommandAdmission
import com.opencapture.opencine.nikon.CameraControl
import com.opencapture.opencine.nikon.CameraControlCapabilities
import com.opencapture.opencine.nikon.CameraIdentity
import com.opencapture.opencine.nikon.CameraPropertySnapshot
import com.opencapture.opencine.nikon.CameraSession
import com.opencapture.opencine.nikon.CameraShutterMode
import com.opencapture.opencine.nikon.FakeCameraSession
import com.opencapture.openzcine.settings.OperatorSettings
import java.io.File
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.flow.MutableStateFlow
import org.json.JSONObject
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/**
 * SIMULATED: the Nikon picker opens in the shared monitor popup, and that popup stays dismissable while
 * a camera-control write is in flight (#328). A focus-mode write can hold the command mutex for seconds
 * (or wedge on a flaky link); gating Back or the outside tap on the pending write trapped the operator
 * in the popup. Dismissal is always allowed and the write finishes in the background.
 */
@RunWith(AndroidJUnit4::class)
@OptIn(ExperimentalTestApi::class)
class MonitorPickerDismissComposeTest {
    @get:Rule
    val composeRule = createComposeRule()

    @Test
    fun backDismissesPickerWhileWritePending() {
        val session = PendingCamera()
        mount(session)
        openFocusWithPendingWrite(session, "backDismissesPickerWhileWritePending")

        UiDevice.getInstance(InstrumentationRegistry.getInstrumentation()).pressBack()

        composeRule.waitUntil(5_000) { composeRule.onAllNodes(hasTestTag("ladder_sheet")).fetchSemanticsNodes().isEmpty() }
        session.gate.complete(Unit)
    }

    @Test
    fun closeDismissesPickerWhileWritePending() {
        val session = PendingCamera()
        mount(session)
        openFocusWithPendingWrite(session, "closeDismissesPickerWhileWritePending")

        composeRule.onNodeWithTag("monitor.capture.close").performClick()

        composeRule.waitUntil(5_000) { composeRule.onAllNodes(hasTestTag("ladder_sheet")).fetchSemanticsNodes().isEmpty() }
        session.gate.complete(Unit)
    }

    /** The focus-dial row is a switch to TalkBack, so it must also say whether it is on. */
    @Test
    fun focusDialRowReportsWhetherItIsOn() {
        var enabled by mutableStateOf(true)
        composeRule.setContent {
            MonitorControlPickerPanel(
                picker = focusPicker(),
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

    private fun focusPicker(): MonitorPickerPresentation {
        val request = CommandControlRequest(
            title = "Focus",
            control = CameraControl.FOCUS_MODE,
            currentValue = "AF-C",
            options = listOf("AF-S", "AF-C", "MF"),
        )
        return MonitorPickerPresentation(
            kind = MonitorPickerKind.FOCUS,
            title = "FOCUS",
            subtitle = "AF-C",
            modes = listOf(MonitorPickerModePresentation(label = "MODE", request = request)),
        )
    }

    private fun mount(session: PendingCamera) {
        composeRule.setContent {
            val context = LocalContext.current
            val settings = remember { OperatorSettings(context.getSharedPreferences(
                "SIMULATED-picker-dismiss", Context.MODE_PRIVATE).also { it.edit().clear().commit() }) }
            TestMonitorScreen(session, remember { idleNikonAssists() }, settings)
        }
        // A cold first launch can take longer than the default wait.
        composeRule.waitForIdle()
        composeRule.waitUntilAtLeastOneExists(hasContentDescription("FOCUS", substring = true), 15_000)
    }

    /** Opens the FOCUS picker through its readout and sends a focus-mode write the camera never answers. */
    private fun openFocusWithPendingWrite(session: PendingCamera, label: String) {
        // The readout can sit outside the test window's touch area; its click action is what opens the picker.
        composeRule.onNode(hasContentDescription("FOCUS", substring = true)).performSemanticsAction(SemanticsActions.OnClick)
        try {
            composeRule.waitUntilAtLeastOneExists(hasTestTag("ladder_sheet"), 5_000)
        } catch (failure: Throwable) {
            // Preserve the failed wait's actual gate state before the compose rule tears the window down.
            captureLadderGate(label)
            throw failure
        }
        // The drum draws its labels; its accessibility action picks by position (MF leads the AF ladder).
        composeRule.onNode(hasContentDescription("AF-C") and SemanticsMatcher.keyIsDefined(SemanticsActions.SetProgress))
            .performSemanticsAction(SemanticsActions.SetProgress) { it(0f) }
        composeRule.waitUntil(5_000) { session.queued }
        composeRule.onNodeWithTag("ladder_sheet").assertExists()
        assertTrue(session.writes.isEmpty())
    }

    // Failure-only, inside the original ladder wait: no extra wait, retry or assertion is added.
    // Every diagnostic read and file operation is caught, so the original ladder throwable is
    // always the one the test reports.
    private fun captureLadderGate(label: String) {
        runCatching {
            val instrumentation = InstrumentationRegistry.getInstrumentation()
            val directory = File(instrumentation.targetContext.cacheDir, "SIMULATED-picker-gate").apply { mkdirs() }
            val file = File(directory, label)
            val diagnostic = JSONObject()
                .put("label", label)
                .put("stage", "ladder-wait-failure")
                .put("uptimeMs", android.os.SystemClock.uptimeMillis())
            // One failing read must not lose the rest of the gate state: every field is recorded
            // independently and the metadata is written before any screenshot is attempted.
            fun record(key: String, read: () -> Any?) {
                diagnostic.put(key, runCatching(read).getOrElse {
                    "unavailable: ${it.javaClass.simpleName}: ${it.message}"
                })
            }
            record("rootCount") { composeRule.onAllNodes(isRoot()).fetchSemanticsNodes().size }
            record("rootBoundsInRoot") {
                org.json.JSONArray(composeRule.onAllNodes(isRoot()).fetchSemanticsNodes()
                    .map { it.boundsInRoot.toString() })
            }
            record("rootBoundsInWindow") {
                org.json.JSONArray(composeRule.onAllNodes(isRoot()).fetchSemanticsNodes()
                    .map { it.boundsInWindow.toString() })
            }
            record("ladderSheetNodes") {
                composeRule.onAllNodes(hasTestTag("ladder_sheet"), useUnmergedTree = true)
                    .fetchSemanticsNodes().size
            }
            record("captureCloseNodes") {
                composeRule.onAllNodes(hasTestTag("monitor.capture.close"), useUnmergedTree = true)
                    .fetchSemanticsNodes().size
            }
            record("focusReadoutNodes") {
                composeRule.onAllNodes(hasContentDescription("FOCUS", substring = true), useUnmergedTree = true)
                    .fetchSemanticsNodes().size
            }
            record("semantics") {
                val roots = composeRule.onAllNodes(isRoot()).fetchSemanticsNodes()
                buildString {
                    roots.indices.forEach { index ->
                        if (index > 0) appendLine()
                        appendLine("ROOT $index")
                        appendLine(runCatching {
                            composeRule.onAllNodes(isRoot())[index].printToString(maxDepth = Int.MAX_VALUE)
                        }.getOrElse { "unavailable: ${it.javaClass.simpleName}: ${it.message}" })
                    }
                }
            }
            File(file.path + ".json").writeText(diagnostic.toString(2))
            runCatching {
                instrumentation.uiAutomation.takeScreenshot()?.let { image ->
                    try {
                        File(file.path + ".png").outputStream().use {
                            check(image.compress(Bitmap.CompressFormat.PNG, 100, it))
                        }
                    } finally {
                        image.recycle()
                    }
                }
            }.onFailure { android.util.Log.w("PickerGate", "Could not retain $label ladder failure screenshot", it) }
        }.onFailure { android.util.Log.w("PickerGate", "Could not retain $label ladder failure diagnostic", it) }
    }

    private class PendingCamera : CameraSession by FakeCameraSession(
        CameraIdentity("SIMULATED", "SIMULATED", "picker-dismiss"), startConnected = true) {
        override val cameraProperties = MutableStateFlow(CameraPropertySnapshot(
            captureSelector = "video", iso = 800, isoAuto = false, exposureMode = "M",
            shutterMode = CameraShutterMode.ANGLE, shutterLocked = false, shutterAngle = "180°",
            focusMode = "AF-C", resolutionFrameRate = "4K · 24p", codec = "ProRes 422 HQ",
            codecSelection = "ProRes 422 HQ",
            controlCapabilities = CameraControlCapabilities(isoValues = listOf("400", "800", "1600"),
                shutterValues = listOf("90°", "180°", "360°"), focusModes = listOf("AF-S", "AF-C", "MF"),
                resolutionFrameRates = listOf("4K · 24p"), codecs = listOf("ProRes 422 HQ"))))
        override val reportedCameraProperties = cameraProperties
        override val reportedRecording = MutableStateFlow<Boolean?>(false)
        val writes = mutableListOf<Pair<CameraControl, String>>()
        val gate = CompletableDeferred<Unit>()
        @Volatile var queued = false
        override suspend fun refreshProperties() = Unit
        override suspend fun applyControl(control: CameraControl, label: String) {
            queued = true
            gate.await()
            writes += control to label
        }
        override suspend fun applyControl(control: CameraControl, label: String, admission: CameraCommandAdmission) {
            queued = true
            gate.await()
            if (admission.admits(this)) writes += control to label
        }
    }
}

package com.opencapture.openzcine

import android.content.Context
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.hasContentDescription
import androidx.compose.ui.test.isRoot
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performTouchInput
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.opencapture.opencine.appkit.MonitorControlModel
import com.opencapture.opencine.core.SettingKey
import com.opencapture.opencine.nikon.CameraCommandAdmission
import com.opencapture.opencine.nikon.CameraControl
import com.opencapture.opencine.nikon.CameraControlCapabilities
import com.opencapture.opencine.nikon.CameraIdentity
import com.opencapture.opencine.nikon.CameraPropertySnapshot
import com.opencapture.opencine.nikon.CameraSession
import com.opencapture.opencine.nikon.CameraShutterMode
import com.opencapture.opencine.nikon.FakeCameraSession
import com.opencapture.opencine.nikon.NikonOpenCineSession
import com.opencapture.openzcine.settings.OperatorSettings
import java.util.concurrent.CopyOnWriteArrayList
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.flow.MutableStateFlow
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** SIMULATED pointer input through the production monitor, app adapters and shared strip. */
@RunWith(AndroidJUnit4::class)
@OptIn(ExperimentalTestApi::class)
class NikonCaptureQuickComposeTest {
    @get:Rule val composeRule = createComposeRule()
    private lateinit var mountedControl: MonitorControlModel

    private fun rootIds(): Set<Int> = composeRule.onAllNodes(isRoot()).fetchSemanticsNodes().map { it.id }.toSet()

    private fun traceFixture(phase: String) {
        val roots = rootIds()
        composeRule.runOnIdle {
            println("SIMULATED quick fixture $phase time=${composeRule.mainClock.currentTime} " +
                "auto=${composeRule.mainClock.autoAdvance} roots=$roots pending=${mountedControl.state.value.pending.keys}")
        }
    }

    @Test fun shutterHoldAdjustsTheCurrentCircuitOnlyOnRelease() {
        val session = QuickCamera()
        mount(session)
        drag("SHUTTER", beforeRelease = {
            assertTrue(session.writes.isEmpty())
            composeRule.onNodeWithTag("monitor.capture.close").assertDoesNotExist()
        })
        composeRule.waitUntil(5_000) { session.writes.isNotEmpty() }
        assertEquals(CameraControl.SHUTTER, session.writes.single().first)
        assertTrue(session.writes.single().second in listOf("90.0°", "360.0°", "90°", "360°"))
        assertEquals(false, session.cameraProperties.value.shutterLocked)
    }

    @Test fun formatDragUsesTheAdvertisedPackWithoutOpeningTheFullSheet() {
        val session = QuickCamera()
        mount(session)
        drag("Format", beforeRelease = {
            assertTrue(session.writes.isEmpty())
            composeRule.onNodeWithTag("monitor.capture.close").assertDoesNotExist()
        })
        composeRule.waitUntil(5_000) { session.writes.isNotEmpty() }
        assertEquals(CameraControl.RESOLUTION_FRAMERATE, session.writes.single().first)
        assertTrue(session.writes.single().second in session.cameraProperties.value.controlCapabilities.resolutionFrameRates)
    }

    @Test fun shutterLockAndFormatDomainChangeCancelHeldAdjustments() {
        val session = QuickCamera()
        mount(session)
        drag("SHUTTER", beforeRelease = {
            session.cameraProperties.value = session.cameraProperties.value.copy(shutterLocked = true)
            composeRule.mainClock.advanceTimeByFrame()
        })
        assertTrue(session.writes.isEmpty())
        session.cameraProperties.value = session.cameraProperties.value.copy(shutterLocked = false)
        composeRule.mainClock.advanceTimeByFrame()
        drag("Format", beforeRelease = {
            val properties = session.cameraProperties.value
            session.cameraProperties.value = properties.copy(controlCapabilities = properties.controlCapabilities.copy(
                resolutionFrameRates = listOf("4K · 24p")))
            composeRule.mainClock.advanceTimeByFrame()
        })
        assertTrue(session.writes.isEmpty())
    }

    @Test fun losingControlAuthorityDuringDragCannotWrite() {
        val session = QuickCamera()
        val surrendered = mutableStateOf(false)
        mount(session) { surrendered.value }
        drag("Format", beforeRelease = {
            surrendered.value = true
            composeRule.mainClock.advanceTimeByFrame()
        })
        assertTrue(session.writes.isEmpty())
    }

    @Test fun queuedFormatReleaseCannotBorrowAChangedCodecOrDomain() {
        val session = QuickCamera()
        session.writeGate = CompletableDeferred()
        mount(session)
        drag("Format", beforeRelease = {})
        composeRule.waitUntil(5_000) { session.queued }
        val properties = session.cameraProperties.value
        session.cameraProperties.value = properties.copy(codec = "H.265 10-bit", codecSelection = "H.265 10-bit")
        composeRule.mainClock.advanceTimeByFrame()
        session.writeGate?.complete(Unit)
        composeRule.mainClock.advanceTimeByFrame()
        composeRule.waitUntil(5_000) { !session.queued }
        assertTrue(session.writes.isEmpty())
    }

    @Test fun unknownShutterCircuitOrMissingFormatDomainNeverSeedsAnAdjustment() {
        val session = QuickCamera()
        val properties = session.cameraProperties.value
        session.cameraProperties.value = properties.copy(shutterMode = null,
            controlCapabilities = properties.controlCapabilities.copy(resolutionFrameRates = emptyList()))
        mount(session)
        drag("SHUTTER", previewExpected = false, beforeRelease = { assertTrue(session.writes.isEmpty()) })
        drag("Format", previewExpected = false, beforeRelease = { assertTrue(session.writes.isEmpty()) })
        assertTrue(session.writes.isEmpty())
    }

    @Test fun photographyShutterAndFocusKeepTheirStillsWriteDomains() {
        val session = QuickCamera()
        val properties = session.cameraProperties.value
        session.cameraProperties.value = properties.copy(captureSelector = "photo", shutterSpeed = "1/125",
            stillFocusMode = "AF-S", controlCapabilities = properties.controlCapabilities.copy(
                shutterValues = listOf("1/60", "1/125", "1/250"), focusModes = listOf("AF-S", "AF-C", "MF")))
        mount(session)
        drag("SHUTTER", beforeRelease = { assertTrue(session.writes.isEmpty()) })
        composeRule.waitUntil(5_000) { session.writes.size == 1 }
        assertEquals(CameraControl.STILL_SHUTTER, session.writes.single().first)
        drag("FOCUS", beforeRelease = { assertEquals(1, session.writes.size) })
        composeRule.waitUntil(5_000) { session.writes.size == 2 }
        assertEquals(CameraControl.STILL_FOCUS_MODE, session.writes.last().first)
    }

    @Test fun hiddenSiblingReadoutCannotOpenWhileHeldPointerCompletes() {
        val session = QuickCamera()
        mount(session)
        val siblingClick = requireNotNull(composeRule.onNode(hasContentDescription("ISO", substring = true))
            .fetchSemanticsNode().config[SemanticsActions.OnClick].action)
        val editor = composeRule.runOnIdle { requireNotNull(mountedControl.edit(SettingKey.SHUTTER)) }
        drag("SHUTTER", beforeRelease = {
            val beforeClick = rootIds()
            traceFixture("sibling-click-before")
            composeRule.runOnIdle { siblingClick() }
            composeRule.mainClock.advanceTimeByFrame()
            composeRule.waitForIdle()
            composeRule.onNodeWithTag("monitor.capture.close").assertDoesNotExist()
            assertTrue(session.writes.isEmpty())
            composeRule.runOnIdle { assertTrue(mountedControl.isCurrent(editor)) }
            traceFixture("sibling-click-after")
            assertEquals("An occluded sibling must not create or replace a popup", beforeClick, rootIds())
        })
        composeRule.waitUntil(5_000) { session.writes.isNotEmpty() }
        assertEquals(CameraControl.SHUTTER, session.writes.single().first)
        assertTrue(session.writes.single().second in listOf("90.0°", "360.0°", "90°", "360°"))
    }

    @Test fun secondPointerOnHiddenSiblingCannotStartAnAction() {
        val session = QuickCamera()
        mount(session)
        val host = composeRule.onNodeWithTag("SIMULATED-capture-quick-host")
        val sibling = composeRule.onNode(hasContentDescription("ISO", substring = true))
            .fetchSemanticsNode().boundsInRoot.center - host.fetchSemanticsNode().boundsInRoot.topLeft
        val editor = composeRule.runOnIdle { requireNotNull(mountedControl.edit(SettingKey.SHUTTER)) }
        drag("SHUTTER", beforeRelease = {
            val beforeSecondPointer = rootIds()
            traceFixture("sibling-pointer-before")
            host.performTouchInput { down(pointerId = 1, position = sibling) }
            composeRule.mainClock.advanceTimeByFrame()
            composeRule.waitForIdle()
            host.performTouchInput { up(pointerId = 1) }
            composeRule.mainClock.advanceTimeByFrame()
            composeRule.waitForIdle()
            composeRule.onNodeWithTag("monitor.capture.close").assertDoesNotExist()
            assertTrue(session.writes.isEmpty())
            composeRule.runOnIdle { assertTrue(mountedControl.isCurrent(editor)) }
            traceFixture("sibling-pointer-after")
            assertEquals("A disabled sibling must leave the held preview intact", beforeSecondPointer, rootIds())
        })
        composeRule.waitUntil(5_000) { session.writes.isNotEmpty() }
        assertEquals(CameraControl.SHUTTER, session.writes.single().first)
        assertTrue(session.writes.single().second in listOf("90.0°", "360.0°", "90°", "360°"))
    }

    @Test fun secondPointerOnTheHeldReadoutCancelsWithoutAnAction() {
        val session = QuickCamera()
        mount(session)
        val host = composeRule.onNodeWithTag("SIMULATED-capture-quick-host")
        val target = composeRule.onNode(hasContentDescription("SHUTTER", substring = true))
            .fetchSemanticsNode().boundsInRoot.center - host.fetchSemanticsNode().boundsInRoot.topLeft
        val beforeHold = rootIds()
        drag("SHUTTER", beforeRelease = {
            host.performTouchInput { down(pointerId = 1, position = target) }
            composeRule.mainClock.advanceTimeByFrame()
            host.performTouchInput { up(pointerId = 1) }
            composeRule.mainClock.autoAdvance = true
            composeRule.waitUntil(5_000) { rootIds() == beforeHold }
            composeRule.onNodeWithTag("monitor.capture.close").assertDoesNotExist()
            traceFixture("held-readout-second-pointer-cancelled")
        })
        composeRule.runOnIdle { assertTrue(session.writes.isEmpty()) }
    }

    private fun mount(session: QuickCamera, surrendered: () -> Boolean = { false }) {
        composeRule.mainClock.autoAdvance = true
        composeRule.setContent {
            val context = LocalContext.current
            val settings = remember { OperatorSettings(context.getSharedPreferences(
                "SIMULATED-capture-quick", Context.MODE_PRIVATE).also { it.edit().clear().commit() }) }
            val scope = rememberCoroutineScope()
            val common = remember { NikonOpenCineSession(session, scope) }
            val control = remember { MonitorControlModel(scope).also { it.bind(common); mountedControl = it } }
            DisposableEffect(Unit) { onDispose { control.unbind() } }
            OpenZCineTheme {
                val assists = remember { idleNikonAssists() }
                Box(Modifier.fillMaxSize().testTag("SIMULATED-capture-quick-host")) {
                    MonitorScreen(session, common, control, rememberTestOperatorSession(assists, settings), frameSource = null,
                        assists = assists, operatorSettings = settings, liveViewEnabled = false, sessionRecoveryEnabled = false,
                        controlsSurrendered = surrendered())
                }
            }
        }
        composeRule.waitUntilAtLeastOneExists(hasContentDescription("SHUTTER", substring = true), 5_000)
        composeRule.waitForIdle()
    }

    private fun drag(caption: String, previewExpected: Boolean = true, beforeRelease: () -> Unit) {
        composeRule.waitForIdle()
        composeRule.mainClock.autoAdvance = false
        val readout = composeRule.onNode(hasContentDescription(caption, substring = true))
        val roots = composeRule.onAllNodes(isRoot()).fetchSemanticsNodes().size
        readout.performTouchInput {
            down(center)
            advanceEventTime(500)
            moveBy(Offset.Zero)
        }
        composeRule.mainClock.advanceTimeBy(500)
        composeRule.waitForIdle()
        val previewRoots = roots + if (previewExpected) 1 else 0
        assertEquals("The held control must expose exactly its admitted quick preview", previewRoots,
            composeRule.onAllNodes(isRoot()).fetchSemanticsNodes().size)
        // A preview hides the original readout from accessibility. Input injection retains the
        // same pointer, so finish it through the stable host instead of querying the hidden label.
        val host = composeRule.onNodeWithTag("SIMULATED-capture-quick-host")
        host.performTouchInput { moveBy(Offset(-180f, 0f)) }
        composeRule.mainClock.advanceTimeByFrame()
        composeRule.waitForIdle()
        assertEquals("The quick preview must survive movement before admission changes", previewRoots,
            composeRule.onAllNodes(isRoot()).fetchSemanticsNodes().size)
        beforeRelease()
        host.performTouchInput { up() }
        traceFixture("released:$caption")
        // Restore normal scheduler progress for the production 120ms typed-write coalescer and
        // the preview's LaunchedEffect cleanup before another merged-tree query or receipt wait.
        composeRule.mainClock.autoAdvance = true
        composeRule.waitForIdle()
        traceFixture("settled:$caption")
    }

    private class QuickCamera : CameraSession by FakeCameraSession(
        CameraIdentity("SIMULATED", "SIMULATED", "capture-quick"), startConnected = true) {
        override val cameraProperties = MutableStateFlow(CameraPropertySnapshot(
            captureSelector = "video", iso = 800, isoAuto = false, exposureMode = "M",
            shutterMode = CameraShutterMode.ANGLE, shutterLocked = false, shutterAngle = "180°",
            resolutionFrameRate = "4K · 24p", codec = "ProRes 422 HQ", codecSelection = "ProRes 422 HQ",
            controlCapabilities = CameraControlCapabilities(isoValues = listOf("400", "800", "1600"),
                shutterValues = listOf("90°", "180°", "360°"),
                resolutionFrameRates = listOf("4K · 24p", "4K · 30p", "4K · 60p"),
                codecs = listOf("ProRes 422 HQ", "H.265 10-bit"))))
        override val reportedCameraProperties = cameraProperties
        override val reportedRecording = MutableStateFlow<Boolean?>(false)
        val writes = CopyOnWriteArrayList<Pair<CameraControl, String>>()
        var writeGate: CompletableDeferred<Unit>? = null
        @Volatile var queued = false
        override suspend fun refreshProperties() = Unit
        override suspend fun applyControl(control: CameraControl, label: String) {
            writes += control to label
        }
        override suspend fun applyControl(control: CameraControl, label: String, admission: CameraCommandAdmission) {
            queued = true
            try {
                writeGate?.await()
                if (admission.admits(this)) applyControl(control, label)
            } finally { queued = false }
        }
    }
}

package com.opencapture.openzcine

import android.content.Context
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.hasContentDescription
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performTouchInput
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.opencapture.opencine.appkit.MonitorControlModel
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
        drag("Image size", beforeRelease = {
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
        drag("Image size", beforeRelease = {
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
        drag("Image size", beforeRelease = {
            surrendered.value = true
            composeRule.mainClock.advanceTimeByFrame()
        })
        assertTrue(session.writes.isEmpty())
    }

    @Test fun queuedFormatReleaseCannotBorrowAChangedCodecOrDomain() {
        val session = QuickCamera()
        session.writeGate = CompletableDeferred()
        mount(session)
        drag("Image size", beforeRelease = {})
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
        drag("SHUTTER", beforeRelease = { assertTrue(session.writes.isEmpty()) })
        drag("Image size", beforeRelease = { assertTrue(session.writes.isEmpty()) })
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

    private fun mount(session: QuickCamera, surrendered: () -> Boolean = { false }) {
        composeRule.mainClock.autoAdvance = false
        composeRule.setContent {
            val context = LocalContext.current
            val settings = remember { OperatorSettings(context.getSharedPreferences(
                "SIMULATED-capture-quick", Context.MODE_PRIVATE).also { it.edit().clear().commit() }) }
            val scope = rememberCoroutineScope()
            val common = remember { NikonOpenCineSession(session, scope) }
            val control = remember { MonitorControlModel(scope).also { it.bind(common) } }
            DisposableEffect(Unit) { onDispose { control.unbind() } }
            OpenZCineTheme {
                val assists = remember { idleNikonAssists() }
                MonitorScreen(session, common, control, rememberTestOperatorSession(assists, settings), frameSource = null,
                    assists = assists, operatorSettings = settings, liveViewEnabled = false, sessionRecoveryEnabled = false,
                    glassTierOverride = "flat", controlsSurrendered = surrendered())
            }
        }
        composeRule.mainClock.advanceTimeByFrame()
        composeRule.waitUntilAtLeastOneExists(hasContentDescription("SHUTTER", substring = true), 5_000)
    }

    private fun drag(caption: String, beforeRelease: () -> Unit) {
        val readout = composeRule.onNode(hasContentDescription(caption, substring = true))
        readout.performTouchInput {
            down(center)
            advanceEventTime(500)
            moveBy(Offset.Zero)
        }
        composeRule.mainClock.advanceTimeBy(500)
        readout.performTouchInput { moveBy(Offset(-180f, 0f)) }
        beforeRelease()
        readout.performTouchInput { up() }
        composeRule.mainClock.advanceTimeByFrame()
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

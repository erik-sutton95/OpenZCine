package com.opencapture.openzcine

import com.opencapture.openzcine.bridge.MonitorZones
import com.opencapture.openzcine.bridge.ZoneFrame
import com.opencapture.openzcine.core.CameraControl
import com.opencapture.openzcine.core.CameraControlCapabilities
import com.opencapture.openzcine.core.CameraIdentity
import com.opencapture.openzcine.core.CameraPropertyRefreshStatus
import com.opencapture.openzcine.core.CameraPropertySnapshot
import com.opencapture.openzcine.core.CameraSessionState
import com.opencapture.openzcine.core.CameraShutterMode
import com.opencapture.openzcine.settings.MonitorDisplayMode
import com.opencapture.openzcine.settings.PortraitFeedAspect
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class MonitorCameraControlsTest {
    @Test
    fun `live capture settings reuse typed command requests`() {
        val dashboard = dashboard(cameraSnapshot())

        val settings = monitorCaptureSettings(dashboard)

        assertEquals(
            listOf(
                MonitorPickerKind.ISO,
                MonitorPickerKind.SHUTTER,
                MonitorPickerKind.IRIS,
                MonitorPickerKind.FOCUS,
                MonitorPickerKind.WHITE_BALANCE,
            ),
            settings.map(MonitorCaptureSettingPresentation::kind),
        )
        assertEquals("800", settings[0].value)
        assertEquals("180°", settings[1].value)
        assertEquals("f/2.8", settings[2].value)
        assertEquals("AF-C", settings[3].value)
        assertEquals("5600K", settings[4].value)
        assertEquals(
            listOf(CameraControl.ISO, CameraControl.BASE_ISO),
            settings[0].picker?.modes?.map { it.request.control },
        )
        assertEquals(
            listOf(CameraControl.SHUTTER, CameraControl.SHUTTER_MODE, CameraControl.SHUTTER_LOCK),
            settings[1].picker?.modes?.map { it.request.control },
        )
        assertEquals(
            listOf(CameraControl.FOCUS_MODE, CameraControl.FOCUS_AREA, CameraControl.FOCUS_SUBJECT),
            settings[3].picker?.modes?.map { it.request.control },
        )
        assertEquals(
            listOf(CameraControl.WHITE_BALANCE, CameraControl.WHITE_BALANCE_TINT),
            settings[4].picker?.modes?.map { it.request.control },
        )
        assertEquals(
            MonitorPickerKind.FOCUS,
            monitorPickerKindForRequest(
                settings,
                requireNotNull(settings[3].picker).modes[1].request,
            ),
        )
    }

    @Test
    fun `unsupported or locked camera values never gain a picker`() {
        val unavailable = monitorCaptureSettings(dashboard(CameraPropertySnapshot()))
        assertTrue(unavailable.all { it.picker == null })
        assertTrue(unavailable.all { it.value == "—" })

        val lockedShutter =
            monitorCaptureSettings(
                dashboard(
                    cameraSnapshot().copy(shutterLocked = true),
                ),
            ).first { it.kind == MonitorPickerKind.SHUTTER }
        val lockedModes = requireNotNull(lockedShutter.picker).modes.map { it.request.control }
        assertTrue(CameraControl.SHUTTER !in lockedModes)
        assertTrue(CameraControl.SHUTTER_LOCK in lockedModes)
        assertEquals("Shutter is locked on the camera.", lockedShutter.unavailableReason)
    }

    @Test
    fun `descriptor backed live controls expose exactly the camera advertised labels`() {
        val settings = monitorCaptureSettings(dashboard(cameraSnapshot()))

        val shutter = requireNotNull(settings[1].picker)
        assertEquals(
            listOf("90°", "180°"),
            shutter.modes.first { it.request.control == CameraControl.SHUTTER }.request.options,
        )
        assertEquals(
            listOf("Angle", "Speed"),
            shutter.modes.first { it.request.control == CameraControl.SHUTTER_MODE }.request.options,
        )
        assertEquals(
            listOf("Unlocked", "Locked"),
            shutter.modes.first { it.request.control == CameraControl.SHUTTER_LOCK }.request.options,
        )
        assertTrue(shutter.modes.none { "1/50" in it.request.options })

        val whiteBalance = requireNotNull(settings[4].picker)
        assertEquals(
            listOf("A2 · G1", "B1 · G1"),
            whiteBalance.modes
                .first { it.request.control == CameraControl.WHITE_BALANCE_TINT }
                .request
                .options,
        )
    }

    @Test
    fun `picker state respects lock`() {
        assertEquals(
            MonitorPickerKind.ISO,
            nextMonitorPicker(null, MonitorPickerKind.ISO, controlsEnabled = true),
        )
        assertNull(
            nextMonitorPicker(
                MonitorPickerKind.ISO,
                MonitorPickerKind.ISO,
                controlsEnabled = true,
            ),
        )
        assertEquals(
            MonitorPickerKind.ISO,
            nextMonitorPicker(
                MonitorPickerKind.ISO,
                MonitorPickerKind.IRIS,
                controlsEnabled = false,
            ),
        )
    }

    @Test
    fun `hidden rails preserve settings and active recording safety`() {
        assertEquals(
            LandscapeSideRailPlan(
                fullRailsVisible = false,
                settingsRecoveryVisible = true,
                recordingSafetyVisible = false,
            ),
            landscapeSideRailPlan(
                sideRailsVisible = false,
                recording = false,
                recordCommandPending = false,
                recordConfirmationPending = false,
            ),
        )
        assertTrue(
            landscapeSideRailPlan(
                sideRailsVisible = false,
                recording = true,
                recordCommandPending = false,
                recordConfirmationPending = false,
            ).recordingSafetyVisible,
        )
        assertTrue(
            landscapeSideRailPlan(
                sideRailsVisible = false,
                recording = false,
                recordCommandPending = true,
                recordConfirmationPending = false,
            ).recordingSafetyVisible,
        )
        assertTrue(
            landscapeSideRailPlan(
                sideRailsVisible = false,
                recording = false,
                recordCommandPending = false,
                recordConfirmationPending = true,
            ).recordingSafetyVisible,
        )
        val full =
            landscapeSideRailPlan(
                sideRailsVisible = true,
                recording = true,
                recordCommandPending = true,
                recordConfirmationPending = true,
            )
        assertTrue(full.fullRailsVisible)
        assertTrue(!full.settingsRecoveryVisible)
        assertTrue(!full.recordingSafetyVisible)
    }

    @Test
    fun `picker waits for pending camera command before chrome closes it`() {
        assertTrue(
            retainMonitorPickerForChrome(
                mode = MonitorDisplayMode.COMMAND,
                cameraValuesVisible = false,
                cameraCommandPending = true,
            ),
        )
        assertTrue(
            !retainMonitorPickerForChrome(
                mode = MonitorDisplayMode.COMMAND,
                cameraValuesVisible = true,
                cameraCommandPending = false,
            ),
        )
        assertTrue(
            !retainMonitorPickerForChrome(
                mode = MonitorDisplayMode.LIVE,
                cameraValuesVisible = false,
                cameraCommandPending = false,
            ),
        )
        assertTrue(
            retainMonitorPickerForChrome(
                mode = MonitorDisplayMode.LIVE,
                cameraValuesVisible = true,
                cameraCommandPending = false,
            ),
        )
    }

    @Test
    fun `portrait pinch uses iOS snap thresholds`() {
        assertEquals(
            PortraitFeedAspect.FILL,
            portraitAspectAfterPinch(1.16f, PortraitFeedAspect.FIT_16_9),
        )
        assertEquals(
            PortraitFeedAspect.FIT_16_9,
            portraitAspectAfterPinch(0.86f, PortraitFeedAspect.FILL),
        )
        assertNull(portraitAspectAfterPinch(1.15f, PortraitFeedAspect.FIT_16_9))
        assertNull(portraitAspectAfterPinch(0.87f, PortraitFeedAspect.FILL))
        assertNull(portraitAspectAfterPinch(1.4f, PortraitFeedAspect.FILL))
    }

    @Test
    fun `portrait fill picker clears the shared capture strip and system rail`() {
        val viewport = ZoneFrame(0f, 0f, 400f, 800f)
        val zones = portraitZones(captureStrip = ZoneFrame(0f, 610f, 400f, 64f))

        val frame =
            monitorPickerFrame(
                viewport,
                zones,
                isPortrait = true,
                anchor = MonitorPickerAnchor.CAPTURE_STRIP,
            )

        assertEquals(12f, frame.x)
        assertEquals(376f, frame.width)
        assertTrue(frame.y >= zones.infoBar.y + zones.infoBar.height + 8f)
        assertTrue(frame.y + frame.height <= requireNotNull(zones.captureStrip).y - 10f)
        assertTrue(frame.y + frame.height < zones.systemCluster.y)
    }

    @Test
    fun `portrait fit picker uses shared controls and system zones`() {
        val viewport = ZoneFrame(0f, 0f, 400f, 800f)
        val zones = portraitZones(captureStrip = null)

        val frame =
            monitorPickerFrame(
                viewport,
                zones,
                isPortrait = true,
                anchor = MonitorPickerAnchor.CONTROLS_GRID,
            )

        assertEquals(320f, frame.height)
        assertEquals(zones.systemCluster.y - 10f, frame.y + frame.height)
        assertTrue(frame.x >= viewport.x)
        assertTrue(frame.x + frame.width <= viewport.x + viewport.width)
    }

    @Test
    fun `landscape picker leaves both system rails exposed`() {
        val viewport = ZoneFrame(0f, 0f, 848f, 393f)
        val zones =
            portraitZones(captureStrip = ZoneFrame(430f, 329f, 363f, 48f)).copy(
                feed = ZoneFrame(59f, 0f, 734f, 393f),
                infoBar = ZoneFrame(80f, 8f, 690f, 46f),
            )

        val frame =
            monitorPickerFrame(
                viewport,
                zones,
                isPortrait = false,
                anchor = MonitorPickerAnchor.CAPTURE_STRIP,
            )

        assertTrue(frame.x >= zones.feed.x + 8f)
        assertTrue(frame.x + frame.width <= zones.feed.x + zones.feed.width - 8f)
    }

    @Test
    fun `portrait fill rail stays inside feed and above capture strip`() {
        val zones = portraitZones(captureStrip = ZoneFrame(0f, 610f, 400f, 64f))
        val collapsed =
            portraitFillAssistRailFrame(
                zones.feed,
                zones.captureStrip,
                expanded = false,
            )
        val expanded =
            portraitFillAssistRailFrame(
                zones.feed,
                zones.captureStrip,
                expanded = true,
            )

        assertTrue(collapsed.y + collapsed.height <= requireNotNull(zones.captureStrip).y - 10f)
        assertTrue(expanded.x >= zones.feed.x)
        assertTrue(expanded.y >= zones.feed.y)
        assertTrue(expanded.y + expanded.height <= zones.feed.y + zones.feed.height)
        assertTrue(expanded.y + expanded.height <= requireNotNull(zones.captureStrip).y - 10f)
    }

    @Test
    fun `portrait fill trailing false color key leaves collapsed rail reachable`() {
        val zones = portraitZones(captureStrip = ZoneFrame(0f, 610f, 400f, 64f))
        val rail =
            portraitFillAssistRailFrame(
                zones.feed,
                zones.captureStrip,
                expanded = false,
            )
        val reference =
            falseColorReferenceDefaultFrame(
                feed = zones.feed,
                viewport = zones.feed,
                horizontalFraction = 1f,
            )

        assertTrue(reference.x >= rail.x + rail.width)
    }

    @Test
    fun `fill content rect centre crops the exact visible feed`() {
        val fit = liveFeedContentRect(400f, 600f, 1_920, 1_080)
        val fill = liveFeedContentRect(400f, 600f, 1_920, 1_080, aspectFill = true)

        assertNotNull(fit)
        assertNotNull(fill)
        assertTrue(fit.top > 0)
        assertEquals(0, fill.top)
        assertEquals(600, fill.height)
        assertTrue(fill.left < 0)
        assertTrue(fill.width > 400)
    }

    private fun dashboard(snapshot: CameraPropertySnapshot): CommandDashboardPresentation =
        commandDashboardPresentation(
            snapshot = snapshot,
            refreshStatus = CameraPropertyRefreshStatus.Ready,
            sessionState =
                CameraSessionState.Connected(
                    CameraIdentity("ZR", "Nikon ZR", "unit-camera"),
                ),
            tileOrder = CommandTileKind.entries,
        )

    private fun cameraSnapshot(): CameraPropertySnapshot =
        CameraPropertySnapshot(
            iso = 800,
            shutterMode = CameraShutterMode.ANGLE,
            shutterLocked = false,
            shutterAngle = "180°",
            iris = "f/2.8",
            whiteBalanceMode = "Color temp",
            whiteBalanceKelvin = 5_600,
            whiteBalanceTint = "A2 · G1",
            focusMode = "AF-C",
            focusArea = "Wide-L",
            focusSubject = "People",
            baseIso = "Low",
            controlCapabilities =
                CameraControlCapabilities(
                    shutterValues = listOf("90°", "180°"),
                    baseIso = listOf("Low", "High"),
                    shutterModes = listOf("Angle", "Speed"),
                    shutterLocks = listOf("Unlocked", "Locked"),
                    whiteBalanceTints = listOf("A2 · G1", "B1 · G1"),
                ),
        )

    private fun portraitZones(captureStrip: ZoneFrame?): MonitorZones =
        MonitorZones(
            feed = ZoneFrame(0f, 52f, 400f, 622f),
            infoBar = ZoneFrame(0f, 0f, 400f, 44f),
            captureStrip = captureStrip,
            assistStrip = null,
            systemCluster = ZoneFrame(0f, 690f, 400f, 100f),
            lock = ZoneFrame(10f, 710f, 40f, 40f),
            disp = ZoneFrame(70f, 708f, 74f, 44f),
            record = ZoneFrame(160f, 698f, 83f, 83f),
            media = ZoneFrame(260f, 708f, 63f, 63f),
            settings = ZoneFrame(330f, 708f, 63f, 63f),
            batteryCluster = null,
            batteryStyle = null,
            batteryPhone = null,
            batteryCamera = null,
            scopes = null,
            controlsGrid = ZoneFrame(0f, 300f, 400f, 390f),
        )
}

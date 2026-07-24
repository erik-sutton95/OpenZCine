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
    private val strings = PhoneStringResolver { resource, _ -> resource.toString() }

    @Test
    fun `live capture settings reuse typed command requests`() {
        val dashboard = dashboard(cameraSnapshot())

        val settings = monitorCaptureSettings(dashboard, strings)

        // iOS CameraDisplayState.preview order: ISO · SHUTTER · IRIS · WB · FOCUS.
        assertEquals(
            listOf(
                MonitorPickerKind.ISO,
                MonitorPickerKind.SHUTTER,
                MonitorPickerKind.IRIS,
                MonitorPickerKind.WHITE_BALANCE,
                MonitorPickerKind.FOCUS,
            ),
            settings.map(MonitorCaptureSettingPresentation::kind),
        )
        assertEquals("800", settings[0].value)
        assertEquals("180°", settings[1].value)
        assertEquals("f/2.8", settings[2].value)
        assertEquals("5560K", settings[3].value)
        assertEquals("AF-C", settings[4].value)
        // R3D NE → dual-base ISO (iOS ISOPickerPolicy): Low Base / High Base.
        assertEquals(
            listOf("Low Base", "High Base"),
            settings[0].picker?.modes?.map(MonitorPickerModePresentation::label),
        )
        assertEquals(
            listOf(CameraControl.ISO, CameraControl.ISO),
            settings[0].picker?.modes?.map { it.request.control },
        )
        assertEquals(
            IsoPickerPolicy.lowBaseOptions,
            settings[0].picker?.modes?.first()?.request?.options,
        )
        assertEquals(
            IsoPickerPolicy.highBaseOptions,
            settings[0].picker?.modes?.get(1)?.request?.options,
        )
        assertEquals("Sensitivity · dual base", settings[0].picker?.subtitle)
        assertEquals("800 · 200-3200", settings[0].picker?.modes?.first()?.detail)
        // iOS CameraPicker.shutter: Angle / Speed dual circuit (not Value/Mode/Lock).
        assertEquals(
            listOf("Angle", "Speed"),
            settings[1].picker?.modes?.map(MonitorPickerModePresentation::label),
        )
        assertEquals(
            listOf(CameraControl.SHUTTER, CameraControl.SHUTTER),
            settings[1].picker?.modes?.map { it.request.control },
        )
        // Multi-value camera angle enum is preferred over the hardcoded ladder.
        assertEquals(
            listOf("90°", "180°"),
            settings[1].picker?.modes?.first()?.request?.options,
        )
        // Speed circuit falls back to the full iOS ladder.
        assertEquals(
            ShutterPickerPolicy.speedOptions,
            settings[1].picker?.modes?.get(1)?.request?.options,
        )
        assertEquals(ShutterPickerPolicy.SUBTITLE, settings[1].picker?.subtitle)
        assertEquals(
            CameraControl.SHUTTER_MODE,
            settings[1].picker?.modes?.first()?.activateRequest?.control,
        )
        // iOS CameraPicker.whiteBalance: Kelvin / Preset / Tint.
        assertEquals(
            listOf("Kelvin", "Preset", "Tint"),
            settings[3].picker?.modes?.map(MonitorPickerModePresentation::label),
        )
        assertEquals(
            listOf(
                CameraControl.WHITE_BALANCE,
                CameraControl.WHITE_BALANCE,
                CameraControl.WHITE_BALANCE_TINT,
            ),
            settings[3].picker?.modes?.map { it.request.control },
        )
        assertEquals(WbPickerPolicy.SUBTITLE, settings[3].picker?.subtitle)
        assertEquals(0, settings[3].picker?.initialModeIndex) // 5560K → Kelvin
        // iOS CameraPicker.focus: AF Mode / Area / Subject (independent tabs).
        assertEquals(
            listOf("AF Mode", "Area", "Subject"),
            settings[4].picker?.modes?.map(MonitorPickerModePresentation::label),
        )
        assertEquals(
            listOf(CameraControl.FOCUS_MODE, CameraControl.FOCUS_AREA, CameraControl.FOCUS_SUBJECT),
            settings[4].picker?.modes?.map { it.request.control },
        )
        assertEquals(FocusPickerPolicy.SUBTITLE, settings[4].picker?.subtitle)
        // Sparse camera AF enum still expands to the full iOS AF Mode ladder.
        assertEquals(
            FocusPickerPolicy.afModeOptions,
            settings[4].picker?.modes?.first()?.request?.options,
        )
        assertEquals(
            FocusPickerPolicy.areaOptions,
            settings[4].picker?.modes?.get(1)?.request?.options,
        )
        assertEquals(
            FocusPickerPolicy.subjectOptions,
            settings[4].picker?.modes?.get(2)?.request?.options,
        )
        assertEquals(0, settings[4].picker?.initialModeIndex) // AF-C → AF Mode
        assertEquals(
            MonitorPickerKind.FOCUS,
            monitorPickerKindForRequest(
                settings,
                requireNotNull(settings[4].picker).modes[1].request,
            ),
        )
    }

    @Test
    fun `capture bar shortens Auto Subject and maps WB preset icons`() {
        assertEquals("Auto-S", captureBarDisplayValue("Auto Subject"))
        assertEquals("AF-C", captureBarDisplayValue("AF-C"))
        assertEquals(CaptureWbIcon.AUTO, captureBarWbIcon("Auto"))
        assertEquals(CaptureWbIcon.SUNNY, captureBarWbIcon("Sunny"))
        assertNull(captureBarWbIcon("5560K"))
    }

    @Test
    fun `unsupported or locked camera values never gain a picker`() {
        val unavailable = monitorCaptureSettings(dashboard(CameraPropertySnapshot()), strings)
        assertTrue(unavailable.all { it.picker == null })
        assertTrue(unavailable.all { it.value == "—" })

        val lockedShutter =
            monitorCaptureSettings(
                dashboard(
                    cameraSnapshot().copy(shutterLocked = true),
                ),
                strings,
            ).first { it.kind == MonitorPickerKind.SHUTTER }
        // iOS still opens Angle/Speed when locked; drum is dimmed + lock banner.
        val lockedPicker = requireNotNull(lockedShutter.picker)
        assertEquals(listOf("Angle", "Speed"), lockedPicker.modes.map { it.label })
        assertTrue(lockedPicker.interactionLocked)
        assertNotNull(lockedPicker.lockBanner)
        assertEquals("Shutter is locked on the camera.", lockedShutter.unavailableReason)
        assertTrue(lockedShutter.controlLocked)
        assertTrue(lockedShutter.dimmed)
    }

    @Test
    fun `descriptor backed live controls expose exactly the camera advertised labels`() {
        val settings = monitorCaptureSettings(dashboard(cameraSnapshot()), strings)

        val shutter = requireNotNull(settings[1].picker)
        // Camera advertised multi-angle enum replaces the hardcoded angle ladder.
        assertEquals(
            listOf("90°", "180°"),
            shutter.modes.first { it.label == "Angle" }.request.options,
        )
        // Speed falls back to the full iOS ladder when the camera only advertised angles.
        assertEquals(
            ShutterPickerPolicy.speedOptions,
            shutter.modes.first { it.label == "Speed" }.request.options,
        )
        assertTrue("1/50" in shutter.modes.first { it.label == "Speed" }.request.options)

        val whiteBalance = requireNotNull(settings[3].picker)
        // Sparse camera enum (one Kelvin + one preset) → full iOS ladders per tab.
        assertEquals(
            WbPickerPolicy.kelvinOptions,
            whiteBalance.modes.first { it.label == "Kelvin" }.request.options,
        )
        assertEquals(
            WbPickerPolicy.presetOptions,
            whiteBalance.modes.first { it.label == "Preset" }.request.options,
        )
        assertEquals(
            listOf("A2 · G1", "B1 · G1"),
            whiteBalance.modes.first { it.label == "Tint" }.request.options,
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
        // Top-bar resolution/codec pickers stay open without the capture strip.
        assertTrue(
            retainMonitorPickerForChrome(
                mode = MonitorDisplayMode.LIVE,
                cameraValuesVisible = false,
                cameraCommandPending = false,
                isTopBarPicker = true,
            ),
        )
    }

    @Test
    fun `top pill pickers open only with camera advertised options`() {
        // Unwritable static ladders must not seed the drum (they always fail apply).
        val empty = monitorTopPillPickers(dashboard(CameraPropertySnapshot()), strings)
        assertTrue(empty.isEmpty())

        val advertised =
            monitorTopPillPickers(
                dashboard(
                    cameraSnapshot().copy(
                        resolutionFrameRate = "6K · 25p",
                        codec = "R3D NE",
                        codecSelection = "R3D NE",
                        controlCapabilities =
                            CameraControlCapabilities(
                                resolutionFrameRates = listOf("4K · 60p", "6K · 25p"),
                                codecs = listOf("H.265", "R3D NE"),
                            ),
                    ),
                ),
                strings,
            )
        assertEquals(
            listOf("4K · 60p", "6K · 25p"),
            advertised.getValue(MonitorPickerKind.RESOLUTION).modes.single().request.options,
        )
        assertEquals(
            "6K · 25p",
            advertised.getValue(MonitorPickerKind.RESOLUTION).modes.single().request.currentValue,
        )
        assertEquals(
            listOf("H.265", "R3D NE"),
            advertised.getValue(MonitorPickerKind.CODEC).modes.single().request.options,
        )
    }

    @Test
    fun `raw resolution tile value maps onto compact camera option`() {
        assertEquals(
            "6K · 25p",
            matchRecordingModeOption(
                "6048x3402 · 25p",
                listOf("6K · 24p", "6K · 25p", "[FX] 6K · 25p"),
            ),
        )
        assertEquals(
            "[FX] 6K · 25p",
            matchRecordingModeOption(
                "6K · 25p",
                listOf("[FX] 6K · 24p", "[FX] 6K · 25p"),
            ),
        )
        assertEquals("6K · 25p", compactRecordingModeFromRawDisplay("6048x3402 · 25p"))
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

        // iOS trailing-aligns to the capture bar (not feed ± 8). Side rails stay
        // outside the capture strip / feed band by zone-map construction.
        val strip = requireNotNull(zones.captureStrip)
        assertEquals(strip.x, frame.x, 0.01f)
        assertEquals(strip.x + strip.width, frame.x + frame.width, 0.01f)
        assertTrue(frame.x >= viewport.x)
        assertTrue(frame.x + frame.width <= viewport.x + viewport.width)
    }

    @Test
    fun `landscape picker is tall enough for the WB tint pad cluster`() {
        // SM-A12-class short landscape (~853×384 dp). Tint needs header +
        // 180dp pad cluster (28+8+108+8+28) + mode tabs + GlassPanel padding.
        val viewport = ZoneFrame(0f, 0f, 853f, 384f)
        val zones =
            portraitZones(captureStrip = ZoneFrame(430f, 320f, 363f, 48f)).copy(
                feed = ZoneFrame(59f, 0f, 734f, 384f),
                infoBar = ZoneFrame(80f, 8f, 690f, 46f),
            )

        val frame =
            monitorPickerFrame(
                viewport,
                zones,
                isPortrait = false,
                anchor = MonitorPickerAnchor.CAPTURE_STRIP,
            )

        // 16+16 padding + ~28 header + 14 gap + 180 pad + 14 gap + ~36 tabs ≈ 304.
        assertTrue(
            frame.height >= 300f,
            "picker height ${frame.height} must fit tint pad (≥ 300dp)",
        )
        assertTrue(frame.y + frame.height <= requireNotNull(zones.captureStrip).y - 10f)
    }

    @Test
    fun `landscape measured capture bar trailing-aligns the picker`() {
        val viewport = ZoneFrame(0f, 0f, 848f, 393f)
        val zones =
            portraitZones(captureStrip = ZoneFrame(430f, 329f, 363f, 48f)).copy(
                feed = ZoneFrame(59f, 0f, 734f, 393f),
                infoBar = ZoneFrame(80f, 8f, 690f, 46f),
            )
        // Content-hugging glass is narrower and trailing inside the zone slot.
        val measured = ZoneFrame(520f, 332f, 260f, 44f)

        val frame =
            monitorPickerFrame(
                viewport,
                zones,
                isPortrait = false,
                anchor = MonitorPickerAnchor.CAPTURE_STRIP,
                measuredCaptureBar = measured,
            )

        assertEquals(measured.width, frame.width, 0.01f)
        assertEquals(measured.x + measured.width, frame.x + frame.width, 0.01f)
        assertEquals(measured.y - 10f, frame.y + frame.height, 0.01f)
    }

    @Test
    fun `ISO unified codecs use a single drum without base tabs`() {
        val dashboard =
            dashboard(
                cameraSnapshot().copy(
                    codec = "N-RAW",
                    codecSelection = "N-RAW",
                ),
            )
        // Without exposure mode M, only Auto On is offered (manual needs M).
        val iso = monitorCaptureSettings(dashboard, strings).first { it.kind == MonitorPickerKind.ISO }
        assertEquals("Sensitivity · auto (M mode for manual)", iso.picker?.subtitle)
        assertEquals(1, iso.picker?.modes?.size)
        assertEquals("Auto On", iso.picker?.modes?.single()?.label)
        assertEquals(IsoPickerPolicy.unifiedOptions, iso.picker?.modes?.single()?.request?.options)
    }

    @Test
    fun `ISO Auto Off is available only in exposure mode M for non R3D`() {
        val dashboard =
            dashboard(
                cameraSnapshot().copy(
                    codec = "N-RAW",
                    codecSelection = "N-RAW",
                    exposureMode = "M",
                    isoAuto = false,
                ),
            )
        val iso =
            monitorCaptureSettings(
                    dashboard,
                    strings,
                    isoAuto = false,
                    exposureMode = "M",
                )
                .first { it.kind == MonitorPickerKind.ISO }
        assertEquals(2, iso.picker?.modes?.size)
        assertEquals(listOf("Auto On", "Auto Off"), iso.picker?.modes?.map { it.label })
        assertEquals(false, iso.picker?.drumInteractionLocked)

        val aperture =
            monitorCaptureSettings(
                    dashboard,
                    strings,
                    isoAuto = true,
                    exposureMode = "A",
                )
                .first { it.kind == MonitorPickerKind.ISO }
        assertEquals(1, aperture.picker?.modes?.size)
        assertEquals("Auto On", aperture.picker?.modes?.single()?.label)
        assertEquals(true, aperture.picker?.drumInteractionLocked)
    }

    @Test
    fun `R3D NE dual base ISO stays manual in aperture priority`() {
        val dashboard =
            dashboard(
                cameraSnapshot().copy(
                    codec = "R3D NE",
                    codecSelection = "R3D NE",
                    exposureMode = "A",
                    iso = 800,
                ),
            )
        val iso =
            monitorCaptureSettings(
                    dashboard,
                    strings,
                    exposureMode = "A",
                )
                .first { it.kind == MonitorPickerKind.ISO }
        assertEquals("Sensitivity · dual base", iso.picker?.subtitle)
        assertEquals(2, iso.picker?.modes?.size)
        assertEquals(listOf("Low Base", "High Base"), iso.picker?.modes?.map { it.label })
        assertEquals(false, iso.picker?.drumInteractionLocked)
        assertEquals(null, iso.picker?.drumLockBanner)
    }

    @Test
    fun `top bar res codec frame drops below the info bar at 340dp`() {
        val viewport = ZoneFrame(0f, 0f, 848f, 393f)
        val zones =
            portraitZones(captureStrip = ZoneFrame(430f, 329f, 363f, 48f)).copy(
                feed = ZoneFrame(59f, 0f, 734f, 393f),
                infoBar = ZoneFrame(80f, 8f, 690f, 46f),
            )
        val frame = monitorTopBarPickerFrame(viewport, zones, isCommandCenter = false)
        assertEquals(340f, frame.width)
        assertTrue(frame.y >= zones.infoBar.y + zones.infoBar.height + 8f - 0.1f)
        assertTrue(frame.x >= viewport.x + 8f)
        assertTrue(frame.x + frame.width <= viewport.x + viewport.width - 8f)
        assertTrue(MonitorPickerKind.RESOLUTION.isTopBarPicker())
        assertTrue(MonitorPickerKind.CODEC.isTopBarPicker())
        assertTrue(!MonitorPickerKind.ISO.isTopBarPicker())
    }

    @Test
    fun `top popdown centres under its own pill and quality gets the dual-drum room`() {
        val viewport = ZoneFrame(0f, 0f, 848f, 393f)
        val zones =
            portraitZones(captureStrip = ZoneFrame(430f, 329f, 363f, 48f)).copy(
                infoBar = ZoneFrame(80f, 8f, 690f, 46f),
            )
        val pill = ZoneFrame(600f, 14f, 90f, 30f)

        val frame =
            monitorTopBarPickerFrame(
                viewport,
                zones,
                isCommandCenter = false,
                kind = MonitorPickerKind.SIZE,
                anchorPill = pill,
            )
        // Centred on the tapped pill (iOS cell.midX), dropped just below it.
        assertEquals(pill.x + pill.width / 2f, frame.x + frame.width / 2f, 0.01f)
        assertEquals(pill.y + pill.height + 8f, frame.y, 0.01f)

        // The quality pair: 400 wide and the full space under the anchor, so
        // the NEF chips and star toggle are never folded under a fixed cap.
        val quality =
            monitorTopBarPickerFrame(
                viewport,
                zones,
                isCommandCenter = false,
                kind = MonitorPickerKind.QUALITY,
                anchorPill = pill,
            )
        assertEquals(400f, quality.width)
        assertEquals(
            viewport.height - quality.y - 8f,
            quality.height,
            0.01f,
        )
        assertTrue(quality.height > 300f)
    }

    @Test
    fun `landscape picker centres over a wide capture bar at the 420 cap`() {
        val viewport = ZoneFrame(0f, 0f, 900f, 400f)
        val zones =
            portraitZones(captureStrip = ZoneFrame(200f, 330f, 640f, 48f)).copy(
                infoBar = ZoneFrame(80f, 8f, 740f, 46f),
            )
        val measured = ZoneFrame(220f, 334f, 600f, 44f)

        val frame =
            monitorPickerFrame(
                viewport,
                zones,
                isPortrait = false,
                anchor = MonitorPickerAnchor.CAPTURE_STRIP,
                measuredCaptureBar = measured,
            )

        // iOS bottomPickerBody: width = min(bar, 420), centred on bar.midX.
        assertEquals(420f, frame.width)
        assertEquals(
            measured.x + measured.width / 2f,
            frame.x + frame.width / 2f,
            0.01f,
        )
        assertEquals(measured.y - 10f, frame.y + frame.height, 0.01f)
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
            whiteBalanceKelvin = 5_560,
            whiteBalanceTint = "A2 · G1",
            focusMode = "AF-C",
            focusArea = "Wide-L",
            focusSubject = "People",
            baseIso = "Low",
            codec = "R3D NE",
            codecSelection = "R3D NE",
            controlCapabilities =
                CameraControlCapabilities(
                    isoValues = listOf("800", "1600"),
                    shutterValues = listOf("90°", "180°"),
                    irisValues = listOf("f/2.8", "f/4"),
                    whiteBalanceValues = listOf("5560K", "Sunny"),
                    focusModes = listOf("AF-C", "MF"),
                    focusAreas = listOf("Wide-L", "Subject"),
                    focusSubjects = listOf("People", "Animal"),
                    baseIso = listOf("Low", "High"),
                    shutterModes = listOf("Angle", "Speed"),
                    shutterLocks = listOf("Unlocked", "Locked"),
                    whiteBalanceTints = listOf("A2 · G1", "B1 · G1"),
                    codecs = listOf("R3D NE", "N-RAW"),
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

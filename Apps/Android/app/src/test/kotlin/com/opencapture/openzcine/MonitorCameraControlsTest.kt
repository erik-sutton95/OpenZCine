package com.opencapture.openzcine

import com.opencapture.opencine.nikon.FocusPickerPolicy
import com.opencapture.opencine.nikon.ShutterPickerPolicy
import com.opencapture.monitorui.MonitorLayoutPolicy
import com.opencapture.monitorui.MonitorFieldLayout
import com.opencapture.monitorui.MonitorRect
import com.opencapture.opencine.nikon.CameraControl
import com.opencapture.opencine.nikon.CameraControlCapabilities
import com.opencapture.opencine.nikon.CameraIdentity
import com.opencapture.opencine.nikon.CameraPropertyRefreshStatus
import com.opencapture.opencine.nikon.CameraPropertySnapshot
import com.opencapture.opencine.nikon.withOptimisticControlValue
import com.opencapture.opencine.nikon.CameraSessionState
import com.opencapture.opencine.nikon.CameraShutterMode
import com.opencapture.opencine.nikon.CodecBitDepthOption
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import com.opencapture.opencine.nikon.IsoPickerPolicy
import com.opencapture.opencine.nikon.WbPickerPolicy
import com.opencapture.opencine.runtime.nativeFeedContentRect

class MonitorCameraControlsTest {
    private val strings = PhoneStringResolver { resource, _ -> resource.toString() }

    @Test
    fun `size codec and quality pickers drop from the top deck, capture pickers rise from the strip`() {
        assertTrue(MonitorPickerKind.RESOLUTION.isTopBarPicker())
        assertTrue(MonitorPickerKind.CODEC.isTopBarPicker())
        assertTrue(MonitorPickerKind.SIZE.isTopBarPicker())
        assertTrue(MonitorPickerKind.QUALITY.isTopBarPicker())
        assertFalse(MonitorPickerKind.ISO.isTopBarPicker())
    }

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
    fun `the subject-tracking AF area label is recognised as an area, not a subject`() {
        // The facade hands the core's decoded `0x8033` label straight across, so this ladder has
        // to spell it the same way. When it read the older bare "Subject", `isAreaLabel` returned
        // false and the FOCUS picker opened on AF Mode instead of Area (#274).
        assertTrue(FocusPickerPolicy.isAreaLabel("Subject tracking"))
        assertFalse(FocusPickerPolicy.isSubjectLabel("Subject tracking"))
        // The subject-*detection* drum keeps its own vocabulary; neither drum may claim the other's.
        assertTrue(FocusPickerPolicy.isSubjectLabel("People"))
        assertFalse(FocusPickerPolicy.isAreaLabel("People"))
    }

    @Test
    fun `capture bar shortens Auto Subject`() {
        assertEquals("Auto-S", captureBarDisplayValue("Auto Subject"))
        assertEquals("AF-C", captureBarDisplayValue("AF-C"))
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
    fun `an iris the body does not advertise stays read-only`() {
        // A3-20: no f-number enum means no invented ladder; the live value still reads out.
        val snapshot = cameraSnapshot()
        val noIris = snapshot.copy(controlCapabilities = snapshot.controlCapabilities.copy(irisValues = emptyList()))
        val dashboard = dashboard(noIris)
        val iris = monitorCaptureSettings(dashboard, strings).first { it.kind == MonitorPickerKind.IRIS }

        assertEquals("f/2.8", iris.value)
        assertNull(iris.picker)
        assertEquals(emptyList(), dashboard.tiles.first { it.kind == CommandTileKind.IRIS }.request?.options.orEmpty())
    }

    @Test
    fun `relayed values fill a watcher's strip by kind and never grant a picker`() {
        // A watcher's dashboard is empty — the session has no properties — so the baseline is
        // all dashes with no pickers, and the broadcaster's forwarded values fill the cells.
        val watcher =
            relayCaptureSettings(
                monitorCaptureSettings(dashboard(CameraPropertySnapshot()), strings),
                listOf(
                    com.opencapture.opencine.nikonwire.MonitorRelayWire.StateValue("ISO", "800"),
                    com.opencapture.opencine.nikonwire.MonitorRelayWire.StateValue(
                        "SHUTTER", "180°"),
                    com.opencapture.opencine.nikonwire.MonitorRelayWire.StateValue("WB", ""),
                    com.opencapture.opencine.nikonwire.MonitorRelayWire.StateValue(
                        "UNKNOWN", "x"),
                ),
            )
        assertEquals("800", watcher.first { it.kind == MonitorPickerKind.ISO }.value)
        assertEquals("180°", watcher.first { it.kind == MonitorPickerKind.SHUTTER }.value)
        // Blank forwarded values keep the dash rather than blanking the cell.
        assertEquals("—", watcher.first { it.kind == MonitorPickerKind.WHITE_BALANCE }.value)
        // Display only: the relay never conjures a picker the local presentation lacked.
        assertTrue(watcher.all { it.picker == null })
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
    fun `the codec picker carries the advertised bit depths and the body's current one`() {
        val depths =
            listOf(
                CodecBitDepthOption("H.265", "8-bit", "H.265 8-bit"),
                CodecBitDepthOption("H.265", "10-bit", "H.265 10-bit"),
            )
        val snapshot =
            cameraSnapshot().copy(
                codec = "H.265 10-bit MOV",
                codecSelection = "H.265",
                codecBitDepth = "10-bit",
                controlCapabilities =
                    cameraSnapshot().controlCapabilities.copy(
                        codecs = listOf("H.264", "H.265"),
                        codecBitDepths = depths,
                    ),
            )

        val request =
            monitorTopPillPickers(dashboard(snapshot), strings)[MonitorPickerKind.CODEC]
                ?.modes
                ?.single()
                ?.request
        assertNotNull(request)
        assertEquals(listOf("H.264", "H.265"), request.options)
        assertEquals("H.265", request.currentValue)
        // The pair, and which side is lit, both come from the core — not from the label.
        assertEquals(depths, request.bitDepths)
        assertEquals("10-bit", request.bitDepthSelection)

        // A depth tap writes the variant label, and the optimistic snapshot keeps the drum on the
        // family row while moving only the depth.
        val optimistic =
            snapshot.withOptimisticControlValue(CameraControl.CODEC, "H.265 8-bit")
        assertEquals("H.265", optimistic.codecSelection)
        assertEquals("8-bit", optimistic.codecBitDepth)
    }

    @Test
    fun `a codec the body advertises at one depth carries no depth pair`() {
        val request =
            monitorTopPillPickers(dashboard(cameraSnapshot()), strings)[MonitorPickerKind.CODEC]
                ?.modes
                ?.single()
                ?.request
        assertNotNull(request)
        assertEquals(emptyList(), request.bitDepths)
        assertNull(request.bitDepthSelection)
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
    fun `portrait fill trailing false color key leaves the collapsed assist palette reachable`() {
        val zones = portraitZones(values = MonitorRect(0f, 610f, 400f, 64f))
        val palette = MonitorLayoutPolicy.portraitAssists(floor = 610f, tablet = false)
        val reference =
            falseColorReferenceDefaultFrame(
                feed = zones.picture,
                viewport = zones.picture,
                horizontalFraction = 1f,
            )

        assertTrue(reference.x >= palette.x + palette.width)
    }

    @Test
    fun `fill content rect centre crops the exact visible feed`() {
        val fit = nativeFeedContentRect(400f, 600f, 1_920, 1_080)
        val fill = nativeFeedContentRect(400f, 600f, 1_920, 1_080, aspectFill = true)

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
                    focusAreas = listOf("Wide-L", "Subject tracking"),
                    focusSubjects = listOf("People", "Animal"),
                    baseIso = listOf("Low", "High"),
                    shutterModes = listOf("Angle", "Speed"),
                    shutterLocks = listOf("Unlocked", "Locked"),
                    whiteBalanceTints = listOf("A2 · G1", "B1 · G1"),
                    codecs = listOf("R3D NE", "N-RAW"),
                ),
        )

    // Production always mounts the assist palette; here it shares the values slot so it never
    // seats the picker higher than the values do.
    private fun portraitZones(values: MonitorRect = MonitorRect(0f, 300f, 400f, 390f)): MonitorFieldLayout =
        testFieldLayout(
            picture = MonitorRect(0f, 52f, 400f, 622f),
            status = MonitorRect(0f, 0f, 400f, 44f),
            values = values,
            assists = values,
            system = MonitorRect(0f, 690f, 400f, 100f),
            lock = MonitorRect(10f, 710f, 40f, 40f),
            display = MonitorRect(70f, 708f, 74f, 44f),
            record = MonitorRect(160f, 698f, 83f, 83f),
            media = MonitorRect(260f, 708f, 63f, 63f),
            settings = MonitorRect(330f, 708f, 63f, 63f),
        )
}

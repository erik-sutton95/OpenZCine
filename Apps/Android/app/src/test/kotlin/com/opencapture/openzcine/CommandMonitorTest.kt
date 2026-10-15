package com.opencapture.openzcine

import com.opencapture.opencine.nikon.WhiteBalanceTint
import com.opencapture.opencine.nikon.CameraControl
import com.opencapture.opencine.nikon.CameraControlCapabilities
import com.opencapture.opencine.nikon.CameraIdentity
import com.opencapture.opencine.nikon.CameraPropertyRefreshFailure
import com.opencapture.opencine.nikon.CameraPropertyRefreshStatus
import com.opencapture.opencine.nikon.CameraPropertySnapshot
import com.opencapture.opencine.nikon.CameraSessionState
import com.opencapture.opencine.nikon.CameraShutterMode
import com.opencapture.opencine.nikon.CameraStorageStatus
import com.opencapture.opencine.nikon.CameraTemperatureStatus
import kotlin.test.Test
import kotlin.test.assertContains
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class CommandMonitorTest {
    @Test
    fun `dashboard preserves raw frame size image area labels`() {
        val presentation =
            commandDashboardPresentation(
                snapshot =
                    CameraPropertySnapshot(
                        resolutionFrameRate = "[DX] 4K · 100p",
                        controlCapabilities =
                            CameraControlCapabilities(
                                resolutionFrameRates =
                                    listOf(
                                        "[FX] 6K · 25p",
                                        "[FX] 4K · 50p",
                                        "[DX] 4K · 100p",
                                    ),
                            ),
                    ),
                refreshStatus = CameraPropertyRefreshStatus.Ready,
                sessionState =
                    CameraSessionState.Connected(
                        CameraIdentity(name = "NIKON ZR", model = "ZR", serialNumber = "ZR-01"),
                    ),
                tileOrder = CommandTileKind.entries.toList(),
            )

        val resolution =
            presentation.tiles.first { it.kind == CommandTileKind.RESOLUTION_FRAMERATE }
        assertEquals("[DX] 4K · 100p", resolution.value)
        assertEquals(
            listOf("[FX] 6K · 25p", "[FX] 4K · 50p", "[DX] 4K · 100p"),
            assertNotNull(resolution.request).options,
        )
    }

    @Test
    fun `dashboard maps real snapshot values and only exposes safe control intents`() {
        val presentation =
            commandDashboardPresentation(
                snapshot =
                    CameraPropertySnapshot(
                        iso = 800,
                        exposureMode = "M",
                        shutterMode = CameraShutterMode.ANGLE,
                        shutterLocked = false,
                        shutterAngle = "180°",
                        iris = "f/2.8",
                        whiteBalanceKelvin = 5600,
                        resolution = "6K",
                        frameRate = 25,
                        codec = "R3D NE",
                        tone = "Log3G10",
                        resolutionFrameRate = "6K · 25p",
                        codecSelection = "R3D NE",
                        temperatureStatus = CameraTemperatureStatus.NORMAL,
                        storage =
                            CameraStorageStatus(
                                totalCapacityBytes = 1_000_000_000_000L,
                                freeSpaceBytes = 470_000_000_000L,
                            ),
                        lens = "NIKKOR Z 24-70mm f/2.8",
                        vibrationReduction = "ON",
                        electronicVr = "OFF",
                        cameraGrid = "ON",
                        focusMode = "AF-C",
                        focusArea = "Wide-L",
                        focusSubject = "People",
                        audioSensitivity = "Auto",
                        audioInput = "Microphone",
                        windFilter = "OFF",
                        inputAttenuator = "ON",
                        audio32BitFloat = "ON",
                        controlCapabilities =
                            CameraControlCapabilities(
                                isoValues = listOf("800", "1600", "25600"),
                                shutterValues = listOf("90°", "180°"),
                                irisValues = listOf("f/2.8", "f/4"),
                                whiteBalanceValues =
                                    listOf("Natural auto", "Sunny", "5600K"),
                                focusModes = listOf("AF-S", "AF-C", "MF"),
                                focusAreas = listOf("Wide-L", "Subject tracking"),
                                focusSubjects = listOf("People", "Airplane"),
                                audioSensitivities = listOf("Auto", "12", "20"),
                                audioInputs = listOf("Microphone", "Line"),
                                windFilters = listOf("OFF", "ON"),
                                attenuators = listOf("OFF", "ON"),
                                audio32BitFloat = listOf("OFF", "ON"),
                                resolutionFrameRates = listOf("4K · 60p", "6K · 25p"),
                                codecs = listOf("H.265", "R3D NE"),
                                vibrationReduction = listOf("OFF", "ON"),
                                electronicVr = listOf("OFF", "ON"),
                            ),
                    ),
                refreshStatus = CameraPropertyRefreshStatus.Ready,
                sessionState =
                    CameraSessionState.Connected(
                        CameraIdentity(name = "NIKON ZR", model = "ZR", serialNumber = "ZR-01"),
                    ),
                tileOrder = CommandTileKind.entries.toList(),
            )

        val iso = assertNotNull(presentation.tiles.first { it.kind == CommandTileKind.ISO }.request)
        assertEquals(CameraControl.ISO, iso.control)
        assertEquals("800", iso.currentValue)
        assertContains(iso.options, "25600")
        val isoSheet = commandControlOptions(iso, pendingControl = null)
        assertTrue(isoSheet.first { it.label == "800" }.selected)
        assertTrue(isoSheet.all { it.enabled })
        // In-flight apply no longer greys the drum — settles coalesce instead.
        assertTrue(commandControlOptions(iso, CameraControl.ISO).all { it.enabled })
        assertFalse(commandControlOptions(iso, pendingControl = null, controlsEnabled = false).any {
            it.enabled
        })

        val whiteBalance =
            assertNotNull(
                presentation.tiles.first { it.kind == CommandTileKind.WHITE_BALANCE }.request,
            )
        assertEquals(CameraControl.WHITE_BALANCE, whiteBalance.control)
        assertEquals("5600K", whiteBalance.currentValue)
        assertContains(whiteBalance.options, "Natural auto")

        val mode = assertNotNull(presentation.tiles.first { it.kind == CommandTileKind.MODE }.request)
        assertEquals(CameraControl.EXPOSURE_MODE, mode.control)
        // This snapshot advertises no `ExposureProgramMode` enum, so the drum gets the
        // conservative ladder — and a body that never said it has user banks is never offered
        // them (#274; the reported Zf).
        assertEquals(listOf("Auto", "P", "A", "S", "M"), mode.options)

        val codec = presentation.tiles.first { it.kind == CommandTileKind.CODEC }
        assertEquals("R3D NE", codec.value)
        assertEquals(
            listOf("H.265", "R3D NE"),
            assertNotNull(codec.request).options,
        )

        val resolution = presentation.tiles.first {
            it.kind == CommandTileKind.RESOLUTION_FRAMERATE
        }
        assertEquals("6K · 25p", resolution.value)
        assertEquals(
            listOf("4K · 60p", "6K · 25p"),
            assertNotNull(resolution.request).options,
        )

        assertEquals("OK", presentation.health.temperature)
        assertTrue(presentation.health.temperatureOk)
        assertEquals("470 GB · 47%", presentation.health.storage)
        assertEquals("25.00", presentation.frameRate)
        assertEquals("NIKON ZR", presentation.health.camera)
        assertEquals(
            "Log3G10",
            presentation.sideSections.first { it.title == "Image" }.cells.first {
                it.title == "Tone"
            }.value,
        )
        assertEquals("ON / OFF", presentation.tiles.first {
            it.kind == CommandTileKind.STABILIZATION
        }.value)
    }

    @Test
    fun `unreported properties stay neutral and explain a degraded refresh`() {
        val presentation =
            commandDashboardPresentation(
                snapshot = CameraPropertySnapshot(),
                refreshStatus =
                    CameraPropertyRefreshStatus.Degraded(
                        CameraPropertyRefreshFailure.UNSUPPORTED_PROPERTY,
                    ),
                sessionState =
                    CameraSessionState.Connected(
                        CameraIdentity(name = "ZR", model = "ZR", serialNumber = "ZR-01"),
                    ),
                tileOrder = CommandTileKind.entries.toList(),
            )

        val iso = presentation.tiles.first { it.kind == CommandTileKind.ISO }
        assertEquals("—", iso.value)
        assertEquals(null, iso.request)
        assertContains(iso.unavailableReason.orEmpty(), "Limited by camera")
        assertEquals("Limited by camera", presentation.refreshSummary)
    }

    @Test
    fun `malformed command values are unavailable and never expose writes`() {
        val presentation =
            commandDashboardPresentation(
                snapshot =
                    CameraPropertySnapshot(
                        iso = 0,
                        exposureMode = " ",
                        shutterSpeed = "",
                        iris = "\t",
                        whiteBalanceMode = " ",
                        whiteBalanceKelvin = 0,
                        resolution = " ",
                        frameRate = -1,
                        codec = "",
                        storage = CameraStorageStatus(100, 101),
                        lens = "\n",
                        focusMode = " ",
                        focusArea = "",
                        focusSubject = "\t",
                        microphoneSensitivity = " ",
                        audioSensitivity = "",
                        audioInput = " ",
                        windFilter = "",
                        inputAttenuator = "\t",
                        audio32BitFloat = " ",
                        vibrationReduction = "",
                        electronicVr = " ",
                        cameraGrid = "\t",
                    ),
                refreshStatus = CameraPropertyRefreshStatus.Ready,
                sessionState =
                    CameraSessionState.Connected(
                        CameraIdentity(name = " ", model = "", serialNumber = "ZR-01"),
                    ),
                tileOrder = CommandTileKind.entries.toList(),
            )

        // Without camera-advertised enums, resolution/codec must not offer static
        // fallback ladders (those always fail apply). All tiles stay write-blocked.
        assertTrue(presentation.tiles.all { it.request == null })
        val resolution =
            presentation.tiles.first { it.kind == CommandTileKind.RESOLUTION_FRAMERATE }
        assertEquals("—", resolution.value)
        assertNotNull(resolution.unavailableReason)
        val codec = presentation.tiles.first { it.kind == CommandTileKind.CODEC }
        assertEquals("—", codec.value)
        assertNotNull(codec.unavailableReason)
        assertTrue(
            presentation.sideSections
                .flatMap(CommandSideSectionPresentation::cells)
                .all { it.value == "—" && it.request == null },
        )
        assertEquals(UNAVAILABLE_MONITOR_VALUE, presentation.health.storage)
        assertEquals(UNAVAILABLE_MONITOR_VALUE, presentation.health.camera)
        assertEquals(UNAVAILABLE_MONITOR_VALUE, presentation.health.lens)
        assertFalse(presentation.health.temperatureOk)
        assertEquals("—", presentation.frameRate)
    }

    @Test
    fun `camera shutter lock keeps the current value visible but blocks writes`() {
        val presentation =
            commandDashboardPresentation(
                snapshot =
                    CameraPropertySnapshot(
                        shutterMode = CameraShutterMode.SPEED,
                        shutterSpeed = "1/50",
                        shutterLocked = true,
                    ),
                refreshStatus = CameraPropertyRefreshStatus.Ready,
                sessionState =
                    CameraSessionState.Connected(
                        CameraIdentity(name = "ZR", model = "ZR", serialNumber = "ZR-01"),
                    ),
                tileOrder = CommandTileKind.entries.toList(),
            )

        val shutter = presentation.tiles.first { it.kind == CommandTileKind.SHUTTER }
        assertEquals("1/50", shutter.value)
        assertEquals(null, shutter.request)
        assertContains(shutter.unavailableReason.orEmpty(), "locked")
    }

    @Test
    fun `shutter writes require a known unlocked active circuit`() {
        fun presentation(snapshot: CameraPropertySnapshot) =
            commandDashboardPresentation(
                snapshot = snapshot,
                refreshStatus = CameraPropertyRefreshStatus.Ready,
                sessionState =
                    CameraSessionState.Connected(
                        CameraIdentity(name = "ZR", model = "ZR", serialNumber = "ZR-01"),
                    ),
                tileOrder = CommandTileKind.entries.toList(),
            )

        // Unknown TV-lock still exposes a write domain so capture-bar Angle/Speed
        // can encode via the shared core (iOS does not wait forever on lock state).
        val unknownLock =
            presentation(
                CameraPropertySnapshot(
                    shutterMode = CameraShutterMode.ANGLE,
                    shutterAngle = "180°",
                ),
            ).tiles.first { it.kind == CommandTileKind.SHUTTER }
        assertNotNull(unknownLock.request)
        assertContains(unknownLock.request!!.options, "180°")

        val angle =
            assertNotNull(
                presentation(
                    CameraPropertySnapshot(
                        shutterMode = CameraShutterMode.ANGLE,
                        shutterAngle = "180°",
                        shutterLocked = false,
                        controlCapabilities =
                            CameraControlCapabilities(shutterValues = listOf("90°", "180°")),
                    ),
                ).tiles.first { it.kind == CommandTileKind.SHUTTER }.request,
            )
        assertContains(angle.options, "180°")
        assertFalse(angle.options.contains("1/50"))

        val speed =
            assertNotNull(
                presentation(
                    CameraPropertySnapshot(
                        shutterMode = CameraShutterMode.SPEED,
                        shutterSpeed = "1/50",
                        shutterLocked = false,
                        controlCapabilities =
                            CameraControlCapabilities(shutterValues = listOf("1/25", "1/50")),
                    ),
                ).tiles.first { it.kind == CommandTileKind.SHUTTER }.request,
            )
        assertContains(speed.options, "1/50")
        assertFalse(speed.options.contains("180°"))
    }

    @Test
    fun `resolution confirm prefers live D0A0 label over lagging fps property`() {
        // All 6K packs share WxH; a stale frameRate of 24 must not make 24p look
        // already-selected while the body is still on 25p.
        val snapshot =
            CameraPropertySnapshot(
                resolution = "6048x3402",
                frameRate = 24,
                resolutionFrameRate = "[FX] 6K · 25p",
            )
        assertTrue(
            cameraPropertyConfirmsSelection(
                snapshot,
                CameraControl.RESOLUTION_FRAMERATE,
                "[FX] 6K · 25p",
            ),
        )
        assertFalse(
            cameraPropertyConfirmsSelection(
                snapshot,
                CameraControl.RESOLUTION_FRAMERATE,
                "[FX] 6K · 24p",
            ),
        )
    }

    @Test
    fun `white balance mode outranks retained Kelvin readback`() {
        val snapshot =
            CameraPropertySnapshot(
                whiteBalanceMode = "Sunny",
                whiteBalanceKelvin = 5600,
                controlCapabilities =
                    CameraControlCapabilities(whiteBalanceValues = listOf("Sunny", "5600K")),
            )
        val presentation =
            commandDashboardPresentation(
                snapshot = snapshot,
                refreshStatus = CameraPropertyRefreshStatus.Ready,
                sessionState =
                    CameraSessionState.Connected(
                        CameraIdentity(name = "ZR", model = "ZR", serialNumber = "ZR-01"),
                    ),
                tileOrder = CommandTileKind.entries.toList(),
            )

        val whiteBalance = presentation.tiles.first { it.kind == CommandTileKind.WHITE_BALANCE }
        assertEquals("Sunny", whiteBalance.value)
        assertEquals("Sunny", assertNotNull(whiteBalance.request).currentValue)
        assertFalse(
            cameraPropertyConfirmsSelection(snapshot, CameraControl.WHITE_BALANCE, "5600K"),
        )
        assertTrue(cameraPropertyConfirmsSelection(snapshot, CameraControl.WHITE_BALANCE, "Sunny"))
    }

    @Test
    fun `R3D recording keeps the current ISO visible but blocks its write`() {
        val presentation =
            commandDashboardPresentation(
                snapshot = CameraPropertySnapshot(iso = 800, codec = "R3D NE"),
                refreshStatus = CameraPropertyRefreshStatus.Ready,
                sessionState =
                    CameraSessionState.Connected(
                        CameraIdentity(name = "ZR", model = "ZR", serialNumber = "ZR-01"),
                    ),
                tileOrder = CommandTileKind.entries.toList(),
                recording = true,
            )

        val iso = presentation.tiles.first { it.kind == CommandTileKind.ISO }
        assertEquals("800", iso.value)
        assertEquals(null, iso.request)
        assertContains(iso.unavailableReason.orEmpty(), "R3D NE")
    }

    @Test
    fun `recording locks ISO until codec readback proves a non R3D format`() {
        fun presentation(codec: String?) =
            commandDashboardPresentation(
                snapshot =
                    CameraPropertySnapshot(
                        iso = 800,
                        codec = codec,
                        controlCapabilities =
                            CameraControlCapabilities(isoValues = listOf("800", "1600")),
                    ),
                refreshStatus = CameraPropertyRefreshStatus.Ready,
                sessionState =
                    CameraSessionState.Connected(
                        CameraIdentity(name = "ZR", model = "ZR", serialNumber = "ZR-01"),
                    ),
                tileOrder = CommandTileKind.entries.toList(),
                recording = true,
            )

        val unknownCodec = presentation(null).tiles.first { it.kind == CommandTileKind.ISO }
        assertEquals(null, unknownCodec.request)
        assertContains(unknownCodec.unavailableReason.orEmpty(), "codec readback")

        val nonR3d = presentation("H.265").tiles.first { it.kind == CommandTileKind.ISO }
        assertEquals(CameraControl.ISO, assertNotNull(nonR3d.request).control)
    }

    @Test
    fun `focus and audio cells keep their distinct validated control selectors`() {
        val presentation =
            commandDashboardPresentation(
                snapshot =
                    CameraPropertySnapshot(
                        focusMode = "AF-C",
                        focusArea = "Subject tracking",
                        focusSubject = "People",
                        audioSensitivity = "12",
                        audioInput = "Line",
                        windFilter = "ON",
                        inputAttenuator = "OFF",
                        audio32BitFloat = "ON",
                        controlCapabilities =
                            CameraControlCapabilities(
                                focusModes = listOf("AF-S", "AF-C", "MF"),
                                focusAreas = listOf("Wide-L", "Subject tracking"),
                                focusSubjects = listOf("People", "Airplane"),
                                audioSensitivities = listOf("Auto", "12", "20"),
                                audioInputs = listOf("Microphone", "Line"),
                                windFilters = listOf("OFF", "ON"),
                                attenuators = listOf("OFF", "ON"),
                                audio32BitFloat = listOf("OFF", "ON"),
                            ),
                    ),
                refreshStatus = CameraPropertyRefreshStatus.Ready,
                sessionState =
                    CameraSessionState.Connected(
                        CameraIdentity(name = "ZR", model = "ZR", serialNumber = "ZR-01"),
                    ),
                tileOrder = CommandTileKind.entries.toList(),
            )

        // iOS CommandSideColumn: Image / Focus / Audio / Monitor (no Exposure).
        assertEquals(
            listOf("Image", "Focus", "Audio", "Monitor"),
            presentation.sideSections.map { it.title },
        )
        val image = presentation.sideSections.first { it.title == "Image" }.cells
        assertEquals(2, image.size)
        assertEquals("Tone", image[0].title)
        assertEquals("Picture Profile", image[1].title)
        assertTrue(image[1].muted)
        val focus = presentation.sideSections.first { it.title == "Focus" }.cells
        assertEquals(CameraControl.FOCUS_MODE, assertNotNull(focus[0].request).control)
        assertEquals(CameraControl.FOCUS_AREA, assertNotNull(focus[1].request).control)
        assertEquals(CameraControl.FOCUS_SUBJECT, assertNotNull(focus[2].request).control)
        assertContains(assertNotNull(focus[2].request).options, "Airplane")

        // iOS Audio order: Sens, 32-bit Float, Input, Wind, Atten
        val audio = presentation.sideSections.first { it.title == "Audio" }.cells
        assertEquals(CameraControl.AUDIO_SENSITIVITY, assertNotNull(audio[0].request).control)
        assertEquals(CameraControl.AUDIO_32_BIT_FLOAT, assertNotNull(audio[1].request).control)
        assertEquals(CameraControl.AUDIO_INPUT, assertNotNull(audio[2].request).control)
        assertEquals(CameraControl.WIND_FILTER, assertNotNull(audio[3].request).control)
        assertEquals(CameraControl.ATTENUATOR, assertNotNull(audio[4].request).control)
        assertContains(assertNotNull(audio[0].request).options, "20")
        assertContains(assertNotNull(audio[2].request).options, "Microphone")
        assertEquals(
            "Grid",
            presentation.sideSections.first { it.title == "Monitor" }.cells.single().title,
        )
        // Capture-bar helpers stay available off the side column.
        assertEquals(4, presentation.captureExposureCells.size)
    }

    @Test
    fun `dynamic controls expose only Swift advertised values`() {
        val presentation =
            commandDashboardPresentation(
                snapshot =
                    CameraPropertySnapshot(
                        iso = 1_600,
                        codec = "R3D NE",
                        baseIso = "High",
                        iris = "f/4",
                        whiteBalanceMode = "Sunny",
                        focusMode = "AF-C",
                        audioInput = "Line",
                        controlCapabilities =
                            CameraControlCapabilities(
                                isoValues = listOf("1600", "3200"),
                                irisValues = listOf("f/4", "f/5.6"),
                                whiteBalanceValues = listOf("Sunny", "5600K"),
                                focusModes = listOf("AF-C", "MF"),
                                audioInputs = listOf("Line"),
                            ),
                    ),
                refreshStatus = CameraPropertyRefreshStatus.Ready,
                sessionState =
                    CameraSessionState.Connected(
                        CameraIdentity(name = "ZR", model = "ZR", serialNumber = "ZR-01"),
                    ),
                tileOrder = CommandTileKind.entries.toList(),
            )

        val iso = assertNotNull(presentation.tiles.first { it.kind == CommandTileKind.ISO }.request)
        assertEquals(listOf("1600", "3200"), iso.options)
        assertFalse("800" in iso.options)
        assertEquals(
            listOf("f/4", "f/5.6"),
            assertNotNull(presentation.tiles.first { it.kind == CommandTileKind.IRIS }.request).options,
        )
        assertEquals(
            listOf("Sunny", "5600K"),
            assertNotNull(
                presentation.tiles.first { it.kind == CommandTileKind.WHITE_BALANCE }.request,
            ).options,
        )
        assertEquals(
            listOf("AF-C", "MF"),
            assertNotNull(
                presentation.sideSections.first { it.title == "Focus" }.cells.first().request,
            ).options,
        )
        // Audio order is Sens, 32-bit, Input — Input is index 2.
        assertEquals(
            listOf("Line"),
            assertNotNull(
                presentation.sideSections.first { it.title == "Audio" }.cells[2].request,
            ).options,
        )
    }

    @Test
    fun `missing dynamic capability keeps current value visible and read only`() {
        val presentation =
            commandDashboardPresentation(
                snapshot = CameraPropertySnapshot(iris = "f/2.8"),
                refreshStatus = CameraPropertyRefreshStatus.Ready,
                sessionState =
                    CameraSessionState.Connected(
                        CameraIdentity(name = "ZR", model = "ZR", serialNumber = "ZR-01"),
                    ),
                tileOrder = CommandTileKind.entries.toList(),
            )

        val iris = presentation.tiles.first { it.kind == CommandTileKind.IRIS }
        assertEquals("f/2.8", iris.value)
        // A3-20: no advertised f-number enum means no invented ladder. The facade supplies the
        // lens ladder itself where the body accepts that write.
        assertNull(iris.request)
        assertNotNull(iris.unavailableReason)
    }

    @Test
    fun `live ISO and white balance stay tappable when the body has not advertised enums`() {
        val presentation =
            commandDashboardPresentation(
                snapshot = CameraPropertySnapshot(iso = 800, whiteBalanceKelvin = 4700),
                refreshStatus = CameraPropertyRefreshStatus.Ready,
                sessionState =
                    CameraSessionState.Connected(
                        CameraIdentity(name = "ZR", model = "ZR", serialNumber = "ZR-01"),
                    ),
                tileOrder = CommandTileKind.entries.toList(),
            )

        val iso = assertNotNull(presentation.tiles.first { it.kind == CommandTileKind.ISO }.request)
        assertEquals("800", iso.currentValue)
        assertContains(iso.options, "800")
        val whiteBalance =
            assertNotNull(
                presentation.tiles.first { it.kind == CommandTileKind.WHITE_BALANCE }.request,
            )
        assertEquals(CameraControl.WHITE_BALANCE, whiteBalance.control)
        assertContains(whiteBalance.options, "4700K")
    }

    @Test
    fun `electronic VR is only on the primary VR tile not the side column`() {
        // iOS removed Assist/DISP/Guides and side-column VR/e-VR — VR lives on the
        // primary grid as "VR / e-VR". Side Image is Tone + Picture Profile only.
        val presentation =
            commandDashboardPresentation(
                snapshot =
                    CameraPropertySnapshot(
                        codec = "N-RAW",
                        electronicVr = "OFF",
                        vibrationReduction = "ON",
                        controlCapabilities =
                            CameraControlCapabilities(
                                vibrationReduction = listOf("OFF", "ON"),
                                electronicVr = listOf("OFF", "ON"),
                            ),
                    ),
                refreshStatus = CameraPropertyRefreshStatus.Ready,
                sessionState =
                    CameraSessionState.Connected(
                        CameraIdentity(name = "ZR", model = "ZR", serialNumber = "ZR-01"),
                    ),
                tileOrder = CommandTileKind.entries.toList(),
            )
        assertEquals(
            listOf("Tone", "Picture Profile"),
            presentation.sideSections.first { it.title == "Image" }.cells.map { it.title },
        )
        val vr = presentation.tiles.first { it.kind == CommandTileKind.STABILIZATION }
        assertEquals("ON / OFF", vr.value)
        assertNotNull(vr.request)
        assertEquals(CameraControl.VIBRATION_REDUCTION, vr.request!!.control)
    }

    @Test
    fun `only a codec proven non-RAW unlocks electronic VR`() {
        // iOS gates its e-VR row on MonitorTextFormat.isRawCodec
        // (ios/Runner/MonitorPanels.swift:1566-1568) — the ZR refuses e-VR on a RAW stream.
        assertTrue(electronicVRAllowsCodec("H.265 10-bit"))
        assertTrue(electronicVRAllowsCodec("ProRes 422 HQ"))
        assertFalse(electronicVRAllowsCodec("N-RAW"))
        assertFalse(electronicVRAllowsCodec("ProRes RAW HQ"))
        // Both the body's verbatim string and the shortened label classify the same.
        assertFalse(electronicVRAllowsCodec("R3D NE 10-bit R3D"))
        assertFalse(electronicVRAllowsCodec("R3D NE"))
        // A codec not read back yet is not proof of a non-RAW stream: fail closed, like the
        // facade does with the enum itself (PTPIPClientSession.swift:439-442).
        assertFalse(electronicVRAllowsCodec(null))
        assertFalse(electronicVRAllowsCodec(" "))
    }

    @Test
    fun `electronic VR tile carries the write the combined VR tile cannot`() {
        fun evrTile(codec: String) =
            commandDashboardPresentation(
                snapshot =
                    CameraPropertySnapshot(
                        codec = codec,
                        electronicVr = "OFF",
                        vibrationReduction = "ON",
                        controlCapabilities =
                            CameraControlCapabilities(
                                vibrationReduction = listOf("OFF", "ON"),
                                electronicVr = listOf("OFF", "ON"),
                            ),
                    ),
                refreshStatus = CameraPropertyRefreshStatus.Ready,
                sessionState =
                    CameraSessionState.Connected(
                        CameraIdentity(name = "ZR", model = "ZR", serialNumber = "ZR-01"),
                    ),
                tileOrder = CommandTileKind.entries.toList(),
            )
                .tiles
                .first { it.kind == CommandTileKind.ELECTRONIC_VR }

        val writable = evrTile("H.265")
        assertEquals("OFF", writable.value)
        val request = assertNotNull(writable.request)
        assertEquals(CameraControl.ELECTRONIC_VR, request.control)
        assertEquals(listOf("OFF", "ON"), request.options)
        assertNull(writable.unavailableReason)

        // RAW keeps the readout and drops the write, like iOS's greyed row.
        val blocked = evrTile("N-RAW")
        assertEquals("OFF", blocked.value)
        assertNull(blocked.request)
        assertEquals(
            "Electronic VR is unavailable for this camera or active codec.",
            blocked.unavailableReason,
        )
    }

    @Test
    fun `tile order keeps the stored key and comma format existing installs hold`() {
        val preferences = TestSharedPreferences()
        preferences.edit().putString("display.commandGrid.order.v1", "CODEC,ISO,ISO,RETIRED").apply()
        val restored = commandTileOrderStore(preferences).load()
        assertEquals(listOf(CommandTileKind.CODEC, CommandTileKind.ISO), restored.take(2))
        assertEquals(CommandTileKind.entries.toSet(), restored.toSet())
        assertEquals(CommandTileKind.entries.size, restored.size)

        val moved = moveCommandTile(restored, CommandTileKind.CODEC, targetIndex = 3)
        assertEquals(CommandTileKind.CODEC, moved[3])
        commandTileOrderStore(preferences).save(moved)
        assertEquals(
            moved.joinToString(",") { it.name },
            preferences.getString("display.commandGrid.order.v1", null),
        )
        assertEquals(moved, commandTileOrderStore(preferences).load())
    }

    @Test
    fun `dashboard tiles and side sections map from a fixture snapshot in the stored order`() {
        val order = listOf(CommandTileKind.CODEC, CommandTileKind.ISO, CommandTileKind.ISO)
        val presentation =
            commandDashboardPresentation(
                snapshot =
                    CameraPropertySnapshot(
                        iso = 800,
                        codec = "R3D NE",
                        codecSelection = "R3D NE",
                        tone = "Log3G10",
                        temperatureStatus = CameraTemperatureStatus.WARNING,
                        lens = "NIKKOR Z 24-70mm f/2.8",
                        cameraGrid = "ON",
                        controlCapabilities =
                            CameraControlCapabilities(
                                isoValues = listOf("800", "1600"),
                                codecs = listOf("H.265", "R3D NE"),
                            ),
                    ),
                refreshStatus = CameraPropertyRefreshStatus.Ready,
                sessionState =
                    CameraSessionState.Connected(
                        CameraIdentity(name = "NIKON ZR", model = "ZR", serialNumber = "ZR-01"),
                    ),
                tileOrder = order,
            )

        // Every Nikon tile once, the stored order first, the rest in declared order.
        assertEquals(normalizeCommandTileOrder(order), presentation.tiles.map { it.kind })
        assertEquals(CommandTileKind.entries.size, presentation.tiles.size)
        val iso = presentation.tiles[1]
        assertEquals("800", iso.value)
        assertEquals(CameraControl.ISO, assertNotNull(iso.request).control)
        assertEquals(CameraControl.CODEC, assertNotNull(presentation.tiles[0].request).control)

        // The shared dashboard draws the side column from the same cells, in order.
        assertEquals(listOf("Image", "Focus", "Audio", "Monitor"), presentation.sections.map { it.title })
        assertEquals(presentation.sideSections.map { it.cells }, presentation.sections.map { it.cells })
        assertEquals("Log3G10", presentation.sections[0].cells[0].value)
        assertEquals("ON", presentation.sections[3].cells[0].value)
        assertTrue(presentation.sections.flatMap { it.cells }.all { it.kind == null })

        // Health is only good for a NORMAL body; the lens and camera come from the snapshot.
        assertFalse(presentation.health.temperatureOk)
        assertEquals("NIKON ZR", presentation.health.camera)
        assertEquals("NIKKOR Z 24-70mm f/2.8", presentation.health.lens)
    }

    @Test
    fun `a command tile is one ladder tab and tint uses the shared pad`() {
        val iso = commandLadderPresentation(
            CommandControlRequest(
                title = "ISO",
                control = CameraControl.ISO,
                currentValue = "800",
                options = listOf("400", "800"),
            ),
            subtitle = "Current: 800",
        )
        assertEquals("ISO", iso.title)
        assertEquals("Current: 800", iso.subtitle)
        val tab = iso.tabs.single()
        assertEquals(CameraControl.ISO, tab.key)
        assertEquals(listOf("400", "800"), tab.ladder.values)
        assertFalse(tab.applyOnActivate)
        assertNull(tab.tint)

        val tint = commandLadderPresentation(
            CommandControlRequest(
                title = "TINT",
                control = CameraControl.WHITE_BALANCE_TINT,
                currentValue = "Neutral",
                options = listOf("Neutral"),
            ),
        )
        assertEquals(WhiteBalanceTint.cellRange, tint.tabs.single().tint?.range)
    }
}

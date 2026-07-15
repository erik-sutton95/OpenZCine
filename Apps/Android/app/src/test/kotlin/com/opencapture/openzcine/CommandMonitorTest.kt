package com.opencapture.openzcine

import androidx.compose.ui.geometry.Offset
import com.opencapture.openzcine.core.CameraControl
import com.opencapture.openzcine.core.CameraControlCapabilities
import com.opencapture.openzcine.core.CameraIdentity
import com.opencapture.openzcine.core.CameraPropertyRefreshFailure
import com.opencapture.openzcine.core.CameraPropertyRefreshStatus
import com.opencapture.openzcine.core.CameraPropertySnapshot
import com.opencapture.openzcine.core.CameraSessionState
import com.opencapture.openzcine.core.CameraShutterMode
import com.opencapture.openzcine.core.CameraStorageStatus
import com.opencapture.openzcine.core.CameraTemperatureStatus
import kotlin.test.Test
import kotlin.test.assertContains
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

class CommandMonitorTest {
    @Test
    fun `long command values shrink instead of clipping in the portrait grid`() {
        assertEquals(24f, commandTileValueSize("5600K"))
        assertEquals(20f, commandTileValueSize("R3D NE HQ"))
        assertEquals(16f, commandTileValueSize("6000x3336 · 25p"))
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
                                focusAreas = listOf("Wide-L", "Subject"),
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
        assertFalse(commandControlOptions(iso, CameraControl.ISO).any { it.enabled })
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
        assertContains(mode.options, "U3")

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

        assertEquals("OK", presentation.temperature)
        assertEquals("470 GB · 47%", presentation.storage)
        assertEquals("25.00", presentation.frameRate)
        assertEquals("NIKON ZR", presentation.camera)
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

        assertTrue(presentation.tiles.all { it.value == "—" && it.request == null })
        assertTrue(
            presentation.sideSections
                .flatMap(CommandSideSectionPresentation::cells)
                .all { it.value == "—" && it.request == null },
        )
        assertEquals("—", presentation.storage)
        assertEquals("—", presentation.camera)
        assertEquals("—", presentation.lens)
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

        val unknownLock =
            presentation(
                CameraPropertySnapshot(
                    shutterMode = CameraShutterMode.ANGLE,
                    shutterAngle = "180°",
                ),
            ).tiles.first { it.kind == CommandTileKind.SHUTTER }
        assertEquals(null, unknownLock.request)
        assertContains(unknownLock.unavailableReason.orEmpty(), "lock state")

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
                        focusArea = "Subject",
                        focusSubject = "People",
                        audioSensitivity = "12",
                        audioInput = "Line",
                        windFilter = "ON",
                        inputAttenuator = "OFF",
                        audio32BitFloat = "ON",
                        controlCapabilities =
                            CameraControlCapabilities(
                                focusModes = listOf("AF-S", "AF-C", "MF"),
                                focusAreas = listOf("Wide-L", "Subject"),
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

        assertEquals(
            listOf("Image", "Exposure", "Focus", "Audio"),
            presentation.sideSections.map { it.title },
        )
        assertEquals(4, presentation.sideSections.first { it.title == "Image" }.cells.size)
        val focus = presentation.sideSections.first { it.title == "Focus" }.cells
        assertEquals(CameraControl.FOCUS_MODE, assertNotNull(focus[0].request).control)
        assertEquals(CameraControl.FOCUS_AREA, assertNotNull(focus[1].request).control)
        assertEquals(CameraControl.FOCUS_SUBJECT, assertNotNull(focus[2].request).control)
        assertContains(assertNotNull(focus[2].request).options, "Airplane")

        val audio = presentation.sideSections.first { it.title == "Audio" }.cells
        assertEquals(CameraControl.AUDIO_SENSITIVITY, assertNotNull(audio[0].request).control)
        assertEquals(CameraControl.AUDIO_INPUT, assertNotNull(audio[1].request).control)
        assertEquals(CameraControl.WIND_FILTER, assertNotNull(audio[2].request).control)
        assertEquals(CameraControl.ATTENUATOR, assertNotNull(audio[3].request).control)
        assertEquals(CameraControl.AUDIO_32_BIT_FLOAT, assertNotNull(audio[4].request).control)
        assertContains(assertNotNull(audio[0].request).options, "20")
        assertContains(assertNotNull(audio[1].request).options, "Microphone")
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
        assertEquals(
            listOf("Line"),
            assertNotNull(
                presentation.sideSections.first { it.title == "Audio" }.cells[1].request,
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
        assertEquals(null, iris.request)
        assertContains(iris.unavailableReason.orEmpty(), "mounted lens")
    }

    @Test
    fun `electronic VR fails closed for unknown and RAW codecs`() {
        fun electronicVr(codec: String?): CommandTilePresentation {
            val presentation =
                commandDashboardPresentation(
                    snapshot =
                        CameraPropertySnapshot(
                            codec = codec,
                            electronicVr = "OFF",
                            controlCapabilities =
                                CameraControlCapabilities(electronicVr = listOf("OFF", "ON")),
                        ),
                    refreshStatus = CameraPropertyRefreshStatus.Ready,
                    sessionState =
                        CameraSessionState.Connected(
                            CameraIdentity(name = "ZR", model = "ZR", serialNumber = "ZR-01"),
                        ),
                    tileOrder = CommandTileKind.entries.toList(),
                )
            return presentation.sideSections.first { it.title == "Image" }.cells[2]
        }

        assertEquals(null, electronicVr(null).request)
        assertContains(electronicVr(null).unavailableReason.orEmpty(), "codec readback")
        assertEquals(null, electronicVr("N-RAW").request)
        assertEquals(null, electronicVr("R3D NE").request)
        assertEquals(null, electronicVr("ProRes RAW HQ").request)
        assertEquals(CameraControl.ELECTRONIC_VR, assertNotNull(electronicVr("H.265").request).control)
        assertTrue(isRawCameraCodec("N-RAW"))
        assertTrue(isRawCameraCodec("R3D NE"))
        assertTrue(isRawCameraCodec("ProRes RAW HQ"))
        assertFalse(isRawCameraCodec("H.265"))
    }

    @Test
    fun `portrait dashboard reserves a compact primary grid for its scrollable secondary controls`() {
        assertEquals(1, commandPrimaryGridRows(tileCount = 1))
        assertEquals(3, commandPrimaryGridRows(tileCount = CommandTileKind.entries.size))
        assertEquals(76, portraitCommandGridHeightDp(tileCount = 1))
        assertEquals(246, portraitCommandGridHeightDp(tileCount = CommandTileKind.entries.size))
    }

    @Test
    fun `command drag resolves every edge to a valid direct destination`() {
        assertEquals(
            0,
            commandGridSlot(Offset(-50f, -20f), 100f, 60f, 9f, columns = 3, itemCount = 8),
        )
        assertEquals(
            4,
            commandGridSlot(Offset(115f, 72f), 100f, 60f, 9f, columns = 3, itemCount = 8),
        )
        assertEquals(
            7,
            commandGridSlot(Offset(900f, 900f), 100f, 60f, 9f, columns = 3, itemCount = 8),
        )
    }

    @Test
    fun `command drag can start only inside a real tile`() {
        assertEquals(
            4,
            commandGridHitSlot(Offset(115f, 72f), 100f, 60f, 9f, columns = 3, itemCount = 8),
        )
        assertEquals(
            null,
            commandGridHitSlot(Offset(105f, 20f), 100f, 60f, 9f, columns = 3, itemCount = 8),
        )
        assertEquals(
            null,
            commandGridHitSlot(Offset(20f, 65f), 100f, 60f, 9f, columns = 3, itemCount = 8),
        )
        assertEquals(
            null,
            commandGridHitSlot(Offset(230f, 150f), 100f, 60f, 9f, columns = 3, itemCount = 8),
        )
    }

    @Test
    fun `tile order normalizes, moves, and survives a reload`() {
        val preferences = TestSharedPreferences()
        val store = CommandTileOrderStore(preferences)
        store.save(
            listOf(
                CommandTileKind.CODEC,
                CommandTileKind.ISO,
                CommandTileKind.ISO,
            ),
        )

        val restored = CommandTileOrderStore(preferences).load()
        assertEquals(CommandTileKind.CODEC, restored.first())
        assertEquals(CommandTileKind.ISO, restored[1])
        assertEquals(CommandTileKind.entries.toSet(), restored.toSet())

        val moved = moveCommandTile(restored, CommandTileKind.CODEC, targetIndex = 3)
        assertEquals(CommandTileKind.CODEC, moved[3])
        assertFalse(moved == restored)
        assertTrue(moved.containsAll(CommandTileKind.entries))

        store.save(moved)
        assertEquals(moved, CommandTileOrderStore(preferences).load())
    }
}

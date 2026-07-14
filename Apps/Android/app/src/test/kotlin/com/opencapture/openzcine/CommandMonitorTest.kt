package com.opencapture.openzcine

import com.opencapture.openzcine.core.CameraControl
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
    fun `dashboard maps real snapshot values and only exposes safe control intents`() {
        val presentation =
            commandDashboardPresentation(
                snapshot =
                    CameraPropertySnapshot(
                        iso = 800,
                        exposureMode = "M",
                        shutterMode = CameraShutterMode.ANGLE,
                        shutterAngle = "180°",
                        iris = "f/2.8",
                        whiteBalanceKelvin = 5600,
                        resolution = "6K",
                        frameRate = 25,
                        codec = "R3D NE",
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
        assertEquals(null, codec.request)
        assertContains(codec.unavailableReason.orEmpty(), "descriptor")

        assertEquals("OK", presentation.temperature)
        assertEquals("470 GB · 47%", presentation.storage)
        assertEquals("25.00", presentation.frameRate)
        assertEquals("NIKON ZR", presentation.camera)
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
                snapshot = CameraPropertySnapshot(iso = 800, codec = codec),
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
                    ),
                refreshStatus = CameraPropertyRefreshStatus.Ready,
                sessionState =
                    CameraSessionState.Connected(
                        CameraIdentity(name = "ZR", model = "ZR", serialNumber = "ZR-01"),
                    ),
                tileOrder = CommandTileKind.entries.toList(),
            )

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
    }
}

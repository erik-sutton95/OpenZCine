package com.opencapture.openzcine.relay

import com.opencapture.openzcine.core.CameraControl
import com.opencapture.openzcine.core.LiveAudioMeterChannel
import com.opencapture.openzcine.core.LiveAudioMeterLevels
import com.opencapture.openzcine.core.LiveFeedRotation
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

/**
 * The vocabulary both platforms speak. A word that means one control going out and another
 * coming in is a control-handoff bug nothing else catches: the write simply lands somewhere
 * else on the far body.
 */
class RelayTranslationTest {
    @Test
    fun `every mapped control survives a round trip through the wire vocabulary`() {
        val controls =
            listOf(
                CameraControl.ISO to "800",
                CameraControl.SHUTTER to "1/50",
                CameraControl.IRIS to "f/2.8",
                CameraControl.WHITE_BALANCE to "5600K",
                CameraControl.RESOLUTION_FRAMERATE to "6K · 25p",
                CameraControl.CODEC to "R3D NE",
                CameraControl.EXPOSURE_MODE to "M",
                CameraControl.STILL_ISO to "400",
                CameraControl.STILL_SHUTTER to "1/250",
                CameraControl.STILL_IRIS to "f/4",
                CameraControl.STILL_DRIVE to "Single",
                CameraControl.STILL_METER to "Matrix",
                CameraControl.STILL_QUALITY to "RAW+JPEG Fine",
                CameraControl.STILL_PICTURE_CONTROL to "Standard",
            )
        controls.forEach { (control, label) ->
            val command = RelayPickerVocabulary.command(control, label)!!
            assertEquals(
                RelayPickerVocabulary.Write(control, label),
                RelayPickerVocabulary.write(command.picker, command.value),
                "$control did not survive the round trip",
            )
        }
    }

    @Test
    fun `the wire names pickers the way iOS does`() {
        // Pinned against `CameraPicker`'s raw values — the far side matches on these strings.
        assertEquals("iso", RelayPickerVocabulary.command(CameraControl.ISO, "800")!!.picker)
        assertEquals(
            "whiteBalance",
            RelayPickerVocabulary.command(CameraControl.WHITE_BALANCE, "5600K")!!.picker,
        )
        assertEquals(
            "resolution",
            RelayPickerVocabulary.command(CameraControl.RESOLUTION_FRAMERATE, "4K · 60p")!!.picker,
        )
        assertEquals("mode", RelayPickerVocabulary.command(CameraControl.EXPOSURE_MODE, "M")!!.picker)
        assertEquals(
            "stillISO",
            RelayPickerVocabulary.command(CameraControl.STILL_ISO, "400")!!.picker,
        )
    }

    @Test
    fun `the exposure helpers ride inside their owning picker, both ways`() {
        // iOS `routeRelayHelperValue` recognises exactly these four words.
        assertEquals(
            MonitorRelayWire.Command.PickerValue("iso", "High base"),
            RelayPickerVocabulary.command(CameraControl.BASE_ISO, "High"),
        )
        assertEquals(
            MonitorRelayWire.Command.PickerValue("iso", "Auto on"),
            RelayPickerVocabulary.command(CameraControl.ISO_AUTO, "ON"),
        )
        assertEquals(
            MonitorRelayWire.Command.PickerValue("iso", "Auto off"),
            RelayPickerVocabulary.command(CameraControl.ISO_AUTO, "OFF"),
        )
        assertEquals(
            MonitorRelayWire.Command.PickerValue("shutter", "Angle"),
            RelayPickerVocabulary.command(CameraControl.SHUTTER_MODE, "Angle"),
        )
        assertEquals(
            RelayPickerVocabulary.Write(CameraControl.BASE_ISO, "Low"),
            RelayPickerVocabulary.write("iso", "Low base"),
        )
        assertEquals(
            RelayPickerVocabulary.Write(CameraControl.ISO_AUTO, "ON"),
            RelayPickerVocabulary.write("iso", "Auto on"),
        )
        assertEquals(
            RelayPickerVocabulary.Write(CameraControl.SHUTTER_MODE, "Speed"),
            RelayPickerVocabulary.write("shutter", "Speed"),
        )
        // A helper word must never shadow a real value: an ISO step is still an ISO write, and
        // a shutter time is still a shutter write.
        assertEquals(
            RelayPickerVocabulary.Write(CameraControl.ISO, "6400"),
            RelayPickerVocabulary.write("iso", "6400"),
        )
        assertEquals(
            RelayPickerVocabulary.Write(CameraControl.SHUTTER, "180.0°"),
            RelayPickerVocabulary.write("shutter", "180.0°"),
        )
    }

    @Test
    fun `a control or picker the other platform does not round-trip stays unspoken`() {
        // Tab-routed on both shells with no relay fork — sending them would invent a contract.
        assertNull(RelayPickerVocabulary.command(CameraControl.FOCUS_MODE, "AF-C"))
        assertNull(RelayPickerVocabulary.command(CameraControl.AUDIO_INPUT, "Mic"))
        assertNull(RelayPickerVocabulary.command(CameraControl.WHITE_BALANCE_TINT, "A2 G1"))
        assertNull(RelayPickerVocabulary.write("focus", "AF-C"))
        assertNull(RelayPickerVocabulary.write("audio", "Mic"))
        assertNull(RelayPickerVocabulary.write("stabilization", "Normal"))
    }

    @Test
    fun `meter segments and dBFS convert the way the core does`() {
        // Core `AudioMeterLevels(cameraIndicator:)`: segment 0 at the floor, 14 at 0 dBFS,
        // evenly spaced between.
        assertEquals(-60.0, RelayAudioMeter.decibels(0), absoluteTolerance = 1e-9)
        assertEquals(0.0, RelayAudioMeter.decibels(14), absoluteTolerance = 1e-9)
        assertEquals(-30.0, RelayAudioMeter.decibels(7), absoluteTolerance = 1e-9)
        // Out-of-range segments clamp rather than fabricate a level off the scale.
        assertEquals(-60.0, RelayAudioMeter.decibels(-3), absoluteTolerance = 1e-9)
        assertEquals(0.0, RelayAudioMeter.decibels(99), absoluteTolerance = 1e-9)
        // Every segment the body can report survives the broadcaster→watcher round trip, so a
        // watcher's bars sit exactly where the broadcaster's do.
        (0..14).forEach { segment ->
            assertEquals(segment, RelayAudioMeter.segment(RelayAudioMeter.decibels(segment)))
        }
        val levels =
            LiveAudioMeterLevels(
                left = LiveAudioMeterChannel(levelDb = -30.0, peakDb = -60.0),
                right =
                    LiveAudioMeterChannel(
                        levelDb = RelayAudioMeter.decibels(9),
                        peakDb = RelayAudioMeter.decibels(12),
                    ),
            )
        assertEquals(
            MonitorRelayWire.Sound(
                peakLeft = 0,
                peakRight = 12,
                currentLeft = 7,
                currentRight = 9,
            ),
            RelayAudioMeter.sound(levels),
        )
        val decoded =
            RelayAudioMeter.levels(
                MonitorRelayWire.Sound(
                    peakLeft = 14,
                    peakRight = 0,
                    currentLeft = 7,
                    currentRight = 0,
                )
            )
        assertEquals(0.0, decoded.left.peakDb, absoluteTolerance = 1e-9)
        assertEquals(-30.0, decoded.left.levelDb, absoluteTolerance = 1e-9)
        assertEquals(-60.0, decoded.right.levelDb, absoluteTolerance = 1e-9)
    }

    @Test
    fun `rotation uses the core's raw values in both directions`() {
        // Pinned, not derived from the enum order: this is what an iOS watcher reads.
        assertEquals(0, relayRotationWireValue(LiveFeedRotation.LANDSCAPE))
        assertEquals(1, relayRotationWireValue(LiveFeedRotation.PORTRAIT_GRIP_UP))
        assertEquals(2, relayRotationWireValue(LiveFeedRotation.PORTRAIT_GRIP_DOWN))
        assertEquals(3, relayRotationWireValue(LiveFeedRotation.UPSIDE_DOWN))
    }
}

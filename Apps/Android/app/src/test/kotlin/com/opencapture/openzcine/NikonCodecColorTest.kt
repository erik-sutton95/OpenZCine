package com.opencapture.openzcine

import com.opencapture.opencine.nikon.CameraControl
import com.opencapture.opencine.nikon.CameraControlCapabilities
import com.opencapture.opencine.nikon.CameraPropertySnapshot
import com.opencapture.opencine.nikon.withOptimisticControlValue
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** The Z body's codec and colour popup on Android: Swift decides the tones, the shell lists them. */
class NikonCodecColorTest {
    private fun snapshot(tones: List<String>, editable: Boolean, tone: String?) =
        CameraPropertySnapshot(
            codec = "H.265 10-bit MOV",
            movieTone = tone,
            controlCapabilities = CameraControlCapabilities(movieTones = tones, movieToneEditable = editable),
        )

    @Test
    fun theOfferedTonesOfTheActiveCodecAreTheColourSection() {
        val choices = nikonCodecColorChoices(snapshot(listOf("SDR", "HLG", "N-Log"), true, "N-Log"))
        assertTrue(choices.showsColor)
        assertEquals(listOf("SDR", "HLG", "N-Log"), choices.colors.map { it.label })
        assertEquals("N-Log", choices.selectedColorChoice?.label)
        assertTrue(choices.colorEditable)
        val request = movieToneRequest(choices)
        assertEquals(CameraControl.MOVIE_TONE, request.control)
        assertEquals(listOf("SDR", "HLG", "N-Log"), request.options)
        assertEquals("N-Log", request.currentValue)
    }

    @Test
    fun aFixedToneIsShownAndOffersNoWrite() {
        val choices = nikonCodecColorChoices(snapshot(listOf("Log3G10"), false, "Log3G10"))
        assertTrue(choices.showsColor)
        assertFalse(choices.colorEditable)
        assertEquals(emptyList(), movieToneRequest(choices).options)
        assertEquals(emptyList(), snapshot(listOf("Log3G10"), false, "Log3G10")
            .controlCapabilities.options(CameraControl.MOVIE_TONE))
    }

    @Test
    fun aCodecWithoutToneHidesTheColourReadout() {
        val choices = nikonCodecColorChoices(snapshot(emptyList(), false, null))
        assertFalse(choices.showsColor)
        val sections = com.opencapture.openzcine.core.MonitorDataAvailability.OWNING.monitorSections(
            cameraReportsTimecode = true, isPhotographyMode = false, reportsColor = choices.showsColor)
        assertFalse(com.opencapture.opencine.appkit.MonitorDisplaySection.COLOR in sections)
        val shown = com.opencapture.openzcine.core.MonitorDataAvailability.OWNING.monitorSections(
            cameraReportsTimecode = true, isPhotographyMode = false, reportsColor = true)
        assertTrue(com.opencapture.opencine.appkit.MonitorDisplaySection.COLOR in shown)
        val photo = com.opencapture.openzcine.core.MonitorDataAvailability.OWNING.monitorSections(
            cameraReportsTimecode = true, isPhotographyMode = true, reportsColor = true)
        assertFalse(com.opencapture.opencine.appkit.MonitorDisplaySection.COLOR in photo)
    }

    @Test
    fun aTonePickShowsAtOnceUntilTheBodyAnswers() {
        val next = snapshot(listOf("SDR", "HLG", "N-Log"), true, "N-Log")
            .withOptimisticControlValue(CameraControl.MOVIE_TONE, "HLG")
        assertEquals("HLG", next.movieTone)
    }
}

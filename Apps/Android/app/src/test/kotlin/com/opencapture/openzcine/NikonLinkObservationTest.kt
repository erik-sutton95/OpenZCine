package com.opencapture.openzcine

import com.opencapture.opencine.cameracontrols.MonitorLinkMeter
import com.opencapture.opencine.nikon.CameraIdentity
import com.opencapture.opencine.nikon.CameraSessionState
import com.opencapture.opencine.vocabulary.SessionRecoveryCopy
import com.opencapture.opencine.vocabulary.SessionRecoveryUi
import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * A3-16: the Nikon monitor's chip reads the shared words. `connectionMessage` never reaches the
 * monitor, so this chip is where a stopped picture explains itself, and a dropped session outranks a
 * rejected stream.
 */
class NikonLinkObservationTest {
    private val connected = CameraSessionState.Connected(CameraIdentity("Z 6III", "Z 6III", "1"))

    private fun label(
        state: CameraSessionState = connected,
        recovery: SessionRecoveryUi = SessionRecoveryUi.Idle,
        previewRejected: Boolean = false,
        frames: PresentedFrameCounter = PresentedFrameCounter(),
    ): String =
        MonitorLinkMeter().apply {
            tick(nikonLinkObservation(state, recovery, previewRejected, frames, linkBars = 2), 1_000)
        }.label

    @Test
    fun theChipNamesTheRouteBeforeAnyPicture() {
        assertEquals("\u2014", label(CameraSessionState.Disconnected))
        assertEquals("LINK", label(CameraSessionState.Connecting))
        assertEquals("LINK", label(connected), "connected, no picture yet")
    }

    @Test
    fun everyBoundedRecoveryStateReadsTheHeldFrameBadgeAndOutranksARejectedPreview() {
        for (state in listOf(
            SessionRecoveryUi.Retrying(attempt = 1, maxAttempts = 4),
            SessionRecoveryUi.WaitingForOperator(attemptsMade = 4),
            SessionRecoveryUi.PausedAfterDrops(drops = 3),
        )) {
            assertEquals(SessionRecoveryCopy.HELD_FRAME_BADGE, label(recovery = state, previewRejected = true), "$state")
        }
        assertEquals("RECOV", label(previewRejected = true))
    }

    @Test
    fun presentedPicturesPrintTheRateAndTheSwiftBarsPassThrough() {
        val frames = PresentedFrameCounter()
        val meter = MonitorLinkMeter()
        meter.tick(nikonLinkObservation(connected, SessionRecoveryUi.Idle, false, frames, linkBars = 3), 1_000)
        repeat(6) { frames.presented(1_000L + it * 40) }
        meter.tick(nikonLinkObservation(connected, SessionRecoveryUi.Idle, false, frames, linkBars = 3), 1_200)
        assertEquals("30.00", meter.label)
        assertEquals(3, meter.bars)
        assertEquals(1_200L, frames.lastPresentedAtMillis)
    }
}

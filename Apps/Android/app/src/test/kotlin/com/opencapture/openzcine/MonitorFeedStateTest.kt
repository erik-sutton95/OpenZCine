package com.opencapture.openzcine

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

/**
 * The frame-rate chip's fallback word (iOS `NativeAppRoot.liveFPS`). `connectionMessage` never
 * reaches the monitor, so this chip is the only place a stopped picture explains itself — and the
 * precedence between "the session is gone" and "the stream is restarting" is what decides which
 * word the operator reads during a drop.
 */
class MonitorFeedStateTest {
    @Test
    fun `a healthy stream leaves the measured rate alone`() {
        assertNull(monitorFeedState(MonitorRecoveryState.Idle, previewRejected = false))
    }

    @Test
    fun `every bounded-recovery state reads NO LINK`() {
        for (state in
            listOf(
                MonitorRecoveryState.Retrying(attempt = 1, maxAttempts = 4),
                MonitorRecoveryState.WaitingForOperator(attemptsMade = 4),
                MonitorRecoveryState.PausedAfterRepeatedDrops(drops = 3),
            )
        ) {
            assertEquals(
                MonitorFeedState.NO_LINK,
                monitorFeedState(state, previewRejected = false),
                "$state holds a dead frame, so the chip must say so",
            )
        }
    }

    @Test
    fun `a rejected preview on a live session reads RECOV`() {
        assertEquals(
            MonitorFeedState.RECOV,
            monitorFeedState(MonitorRecoveryState.Idle, previewRejected = true),
        )
    }

    @Test
    fun `a dropped session outranks a rejected preview`() {
        assertEquals(
            MonitorFeedState.NO_LINK,
            monitorFeedState(
                MonitorRecoveryState.Retrying(attempt = 2, maxAttempts = 4),
                previewRejected = true,
            ),
        )
    }
}

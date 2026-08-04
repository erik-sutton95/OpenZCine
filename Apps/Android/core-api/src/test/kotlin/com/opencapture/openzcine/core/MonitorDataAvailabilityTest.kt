package com.opencapture.openzcine.core

import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * Pins the availability truth table to the core definition (`VideoSource.swift`,
 * `MonitorDataAvailability`) — the watcher rows are what the iOS watcher actually renders, so a
 * drift here is a visible platform divergence, not a style choice.
 */
class MonitorDataAvailabilityTest {

    @Test
    fun `an owning session mounts everything`() {
        val owning = MonitorDataAvailability.OWNING
        assertTrue(owning.cameraControls)
        assertTrue(owning.recordControl)
        assertTrue(owning.mediaBrowser)
        assertTrue(owning.focusBoxes)
        assertTrue(owning.cameraTimecode)
    }

    @Test
    fun `a watcher without control keeps readings and loses every control`() {
        val watcher = MonitorDataAvailability.watcher(holdsControl = false)
        assertFalse(watcher.cameraControls)
        assertFalse(watcher.recordControl)
        assertFalse(watcher.mediaBrowser)
        // The host forwards the readings — blanking these would hide data the watcher has.
        assertTrue(watcher.focusBoxes)
        assertTrue(watcher.cameraTimecode)
        assertTrue(watcher.audioMeters)
    }

    @Test
    fun `holding the control token grants the proxied controls but never the card`() {
        val holding = MonitorDataAvailability.watcher(holdsControl = true)
        assertTrue(holding.cameraControls)
        assertTrue(holding.recordControl)
        // Media browsing needs the PTP link itself; the token proxies commands, not transfers.
        assertFalse(holding.mediaBrowser)
    }
}

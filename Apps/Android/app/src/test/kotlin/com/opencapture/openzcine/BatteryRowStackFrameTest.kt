package com.opencapture.openzcine

import com.opencapture.openzcine.bridge.ZoneFrame
import kotlin.test.Test
import kotlin.test.assertEquals

class BatteryRowStackFrameTest {
    private val anchor = ZoneFrame(13f, 60f, 38f, 70f)
    private val lock = ZoneFrame(16f, 10f, 40f, 40f)

    @Test
    fun `seats directly under the lock button`() {
        val frame = batteryRowStackFrame(anchor, lock)
        assertEquals(lock.y + lock.height + BATTERY_STACK_CLEARANCE_DP, frame.y)
        // The stack keeps the zone lane's leading x and its fixed footprint.
        assertEquals(13f, frame.x)
        assertEquals(BATTERY_STACK_WIDTH_DP, frame.width)
        assertEquals(BATTERY_STACK_HEIGHT_DP, frame.height)
    }

    @Test
    fun `tracks the lock frame, not the anchor's own y`() {
        val lowerLock = ZoneFrame(16f, 24f, 40f, 44f)
        val frame = batteryRowStackFrame(anchor, lowerLock)
        assertEquals(24f + 44f + BATTERY_STACK_CLEARANCE_DP, frame.y)
    }
}

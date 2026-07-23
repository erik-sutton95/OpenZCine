package com.opencapture.openzcine

import com.opencapture.openzcine.bridge.ZoneFrame
import kotlin.test.Test
import kotlin.test.assertEquals

class BatteryRowStackFrameTest {
    private val anchor = ZoneFrame(13f, 60f, 38f, 70f)
    private val lock = ZoneFrame(16f, 10f, 40f, 40f)

    @Test
    fun `hugs the display cutout from above`() {
        val frame = batteryRowStackFrame(anchor, lock, cutoutTopY = 192f)
        assertEquals(192f - BATTERY_STACK_CLEARANCE_DP - BATTERY_STACK_HEIGHT_DP, frame.y)
        // The stack keeps the zone lane's leading x and its fixed footprint.
        assertEquals(13f, frame.x)
        assertEquals(BATTERY_STACK_WIDTH_DP, frame.width)
        assertEquals(BATTERY_STACK_HEIGHT_DP, frame.height)
    }

    @Test
    fun `seats under the lock button without a cutout`() {
        val frame = batteryRowStackFrame(anchor, lock, cutoutTopY = null)
        assertEquals(lock.y + lock.height + BATTERY_STACK_CLEARANCE_DP, frame.y)
    }

    @Test
    fun `never rises above the lock clearance for a high cutout`() {
        val frame = batteryRowStackFrame(anchor, lock, cutoutTopY = 20f)
        assertEquals(lock.y + lock.height + BATTERY_STACK_CLEARANCE_DP, frame.y)
    }
}

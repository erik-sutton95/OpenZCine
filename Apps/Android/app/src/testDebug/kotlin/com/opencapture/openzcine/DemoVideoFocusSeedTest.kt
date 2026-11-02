package com.opencapture.openzcine

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** `zc.demo.focusPair` seeds the recenter key on a sample video as on the synthetic bars. */
class DemoVideoFocusSeedTest {
    @Test
    fun `a sample video carries the seeded focus point only when asked`() {
        val jpeg = byteArrayOf(0xFF.toByte(), 0xD8.toByte(), 0xFF.toByte(), 0xD9.toByte())

        val seeded = DemoVideoFrameSource(openDataSource = { null }, seededFocusPoint = true)
            .liveFrame(jpeg, frameIndex = 12, fps = 25).focus
        assertNotNull(seeded)
        val box = seeded.boxes.single()
        // Off centre, so the recenter key has work to do; real (not a moving debug fixture).
        assertTrue(box.centerX < seeded.coordinateWidth / 2 && box.centerY < seeded.coordinateHeight / 2)
        assertEquals(false, seeded.isDebugFixture)

        assertNull(DemoVideoFrameSource(openDataSource = { null }).liveFrame(jpeg, 12, 25).focus)
    }
}

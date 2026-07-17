package com.opencapture.openzcine

import com.opencapture.openzcine.bridge.ZoneFrame
import kotlin.test.Test
import kotlin.test.assertEquals

class CutoutHuggedBatteryFramesTest {
    private val bounds = ZoneFrame(0f, 0f, 853f, 384f)
    private val phone = ZoneFrame(8f, 60f, 30f, 40f)
    private val camera = ZoneFrame(8f, 300f, 30f, 40f)

    @Test
    fun `clusters phone above and camera below the cutout centre`() {
        val (huggedPhone, huggedCamera) =
            cutoutHuggedBatteryFrames(phone, camera, cutoutCenterY = 192f, bounds = bounds)
        assertEquals(192f - 14f - 40f, huggedPhone!!.y)
        assertEquals(192f + 14f, huggedCamera!!.y)
    }

    @Test
    fun `falls back to zone frames without a cutout`() {
        assertEquals(
            phone to camera,
            cutoutHuggedBatteryFrames(phone, camera, cutoutCenterY = null, bounds = bounds),
        )
    }

    @Test
    fun `falls back when hugged frames would leave the feed bounds`() {
        assertEquals(
            phone to camera,
            cutoutHuggedBatteryFrames(phone, camera, cutoutCenterY = 10f, bounds = bounds),
        )
    }
}

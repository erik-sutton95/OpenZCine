package com.opencapture.openzcine.core

import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * Pins the profile to the core definition (`RelayBitrateAdaptation.swift`,
 * `RelayEncoderProfile`). The operator picks between the same two words on both shells, so a
 * number that drifts here is a promise the Android broadcast quietly stops keeping.
 */
class RelayEncoderProfileTest {

    @Test
    fun `the stance numbers match the shared core`() {
        assertEquals("lowLatency", RelayEncoderProfile.LOW_LATENCY.wireValue)
        assertEquals("Low latency", RelayEncoderProfile.LOW_LATENCY.title)
        assertEquals(50, RelayEncoderProfile.LOW_LATENCY.maxKeyframeInterval)
        assertEquals(2, RelayEncoderProfile.LOW_LATENCY.maxInFlightFramesPerPeer)

        assertEquals("quality", RelayEncoderProfile.QUALITY.wireValue)
        assertEquals("Quality", RelayEncoderProfile.QUALITY.title)
        assertEquals(120, RelayEncoderProfile.QUALITY.maxKeyframeInterval)
        assertEquals(4, RelayEncoderProfile.QUALITY.maxInFlightFramesPerPeer)
    }

    @Test
    fun `an unknown stored value falls back to the tightest path`() {
        assertEquals(RelayEncoderProfile.LOW_LATENCY, RelayEncoderProfile.fromWireValue(null))
        assertEquals(RelayEncoderProfile.LOW_LATENCY, RelayEncoderProfile.fromWireValue(""))
        assertEquals(RelayEncoderProfile.LOW_LATENCY, RelayEncoderProfile.fromWireValue("hevc"))
        assertEquals(RelayEncoderProfile.QUALITY, RelayEncoderProfile.fromWireValue("quality"))
    }
}

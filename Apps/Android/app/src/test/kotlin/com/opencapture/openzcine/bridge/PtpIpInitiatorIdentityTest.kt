package com.opencapture.openzcine.bridge

import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals

class PtpIpInitiatorIdentityTest {
    /**
     * Cross-platform wire contract. These are the bytes iOS sends
     * (`PTPIPInitiator.appGUID`, Sources/OpenZCineCore/PTPIPHandshake.swift), and a Nikon body
     * keys its paired-computer profile to them. Drifting from iOS means Android is a stranger to
     * a body paired from an iPhone; changing them at all strands every profile in the field.
     */
    @Test
    fun `initiator GUID is byte for byte the shared OpenZCine identity`() {
        val expected =
            byteArrayOf(
                0x4F, 0x70, 0x65, 0x6E, 0x5A, 0x43, 0x69, 0x6E,
                0x65, 0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66,
            )

        assertContentEquals(expected, PtpIpInitiatorIdentity.guid)
    }

    @Test
    fun `initiator GUID is the 16 bytes PTP IP requires`() {
        assertEquals(16, PtpIpInitiatorIdentity.guid.size)
    }

    @Test
    fun `caller cannot mutate the shared identity through a returned array`() {
        val first = PtpIpInitiatorIdentity.guid
        val expected = first.copyOf()

        first[0] = (first[0].toInt() xor 0xff).toByte()

        assertContentEquals(expected, PtpIpInitiatorIdentity.guid)
    }
}

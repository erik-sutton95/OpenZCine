package com.opencapture.openzcine.bridge

import com.opencapture.openzcine.TestSharedPreferences
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertNull

class PtpIpInitiatorIdentityTest {
    @Test
    fun `codec preserves one complete 16 byte GUID`() {
        val source = ByteArray(PtpIpInitiatorGuidCodec.BYTE_COUNT) { index -> index.toByte() }

        val encoded = PtpIpInitiatorGuidCodec.encode(source)

        assertEquals("000102030405060708090a0b0c0d0e0f", encoded)
        assertContentEquals(source, PtpIpInitiatorGuidCodec.decode(encoded))
    }

    @Test
    fun `codec rejects malformed persisted values`() {
        assertNull(PtpIpInitiatorGuidCodec.decode(null))
        assertNull(PtpIpInitiatorGuidCodec.decode(""))
        assertNull(PtpIpInitiatorGuidCodec.decode("0".repeat(31)))
        assertNull(PtpIpInitiatorGuidCodec.decode("z".repeat(32)))
    }

    @Test
    fun `generation produces exactly one PTP IP GUID`() {
        assertEquals(PtpIpInitiatorGuidCodec.BYTE_COUNT, PtpIpInitiatorGuidCodec.generate().size)
    }

    @Test
    fun `valid persisted GUID is reused exactly across provider construction`() {
        val preferences = TestSharedPreferences()
        val expected = ByteArray(PtpIpInitiatorGuidCodec.BYTE_COUNT) { index -> (index + 16).toByte() }
        preferences.edit()
            .putString(PtpIpInitiatorIdentity.GUID_KEY, PtpIpInitiatorGuidCodec.encode(expected))
            .commit()

        val first = PtpIpInitiatorIdentity(preferences)
        val afterRelaunch = PtpIpInitiatorIdentity(preferences)

        assertContentEquals(expected, first.guid())
        assertContentEquals(expected, afterRelaunch.guid())
    }

    @Test
    fun `missing persisted GUID is generated and then reused`() {
        val preferences = TestSharedPreferences()

        assertReplacementWasPersisted(preferences)
    }

    @Test
    fun `malformed persisted GUID is replaced and then reused`() {
        val preferences = TestSharedPreferences()
        preferences.edit().putString(PtpIpInitiatorIdentity.GUID_KEY, "not-a-guid").commit()

        assertReplacementWasPersisted(preferences)
    }

    @Test
    fun `caller cannot mutate the persisted GUID through a returned array`() {
        val preferences = TestSharedPreferences()
        val provider = PtpIpInitiatorIdentity(preferences)
        val first = provider.guid()
        val expected = first.copyOf()

        first[0] = (first[0].toInt() xor 0xff).toByte()

        assertContentEquals(expected, provider.guid())
    }

    private fun assertReplacementWasPersisted(preferences: TestSharedPreferences) {
        val replacement = PtpIpInitiatorIdentity(preferences).guid()
        val reloaded = PtpIpInitiatorIdentity(preferences).guid()

        assertEquals(PtpIpInitiatorGuidCodec.BYTE_COUNT, replacement.size)
        assertEquals(
            PtpIpInitiatorGuidCodec.encode(replacement),
            preferences.getString(PtpIpInitiatorIdentity.GUID_KEY, null),
        )
        assertContentEquals(replacement, reloaded)
    }
}

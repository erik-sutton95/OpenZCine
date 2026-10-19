package com.opencapture.openzcine.settings

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** ZAB-352: standalone Settings reads and writes the broadcast passcode without a controller. */
class RelayPasscodeFieldTest {
    @Test
    fun standaloneSettingsShowsAndStoresTheBroadcastPasscode() {
        var stored: String? = "4821"
        val field = RelayPasscodeField(
            controller = null,
            readStored = { stored },
            storeStored = { stored = it; true },
        )
        assertEquals("4821", field.value, "a stored passcode must not read as an open feed")
        assertTrue(field.store("1357"))
        assertEquals("1357", field.value)
        assertEquals("1357", stored)
    }

    @Test
    fun theSharedRuleRefusesATooShortEntryAndKeepsTheStoredCode() {
        var stored: String? = "4821"
        val field = RelayPasscodeField(
            controller = null,
            readStored = { stored },
            storeStored = { stored = it; true },
        )
        assertFalse(field.store("12"))
        assertEquals("4821", stored)
    }

    @Test
    fun aRefusedStoreKeepsThePreviousCode() {
        var stored: String? = "4821"
        val field = RelayPasscodeField(
            controller = null,
            readStored = { stored },
            storeStored = { false },
        )
        assertFalse(field.store("1357"))
        assertEquals("4821", stored)
    }
}

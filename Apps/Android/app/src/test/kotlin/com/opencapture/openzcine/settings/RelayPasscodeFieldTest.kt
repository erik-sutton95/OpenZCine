package com.opencapture.openzcine.settings

import androidx.compose.runtime.snapshots.Snapshot
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** ZAB-352: standalone Settings reads and writes the broadcast passcode without a controller. */
class RelayPasscodeFieldTest {
    @Test
    fun standaloneSettingsShowsAndStoresTheBroadcastPasscode(): Unit {
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
    fun theSharedRuleRefusesATooShortEntryAndKeepsTheStoredCode(): Unit {
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
    fun aRefusedStoreKeepsThePreviousCode(): Unit {
        var stored: String? = "4821"
        val field = RelayPasscodeField(
            controller = null,
            readStored = { stored },
            storeStored = { false },
        )
        assertFalse(field.store("1357"))
        assertEquals("4821", stored)
    }

    @Test
    fun theStandaloneCodeIsComposeStateSoAStoredCodeRedraws(): Unit {
        var lookups = 0
        var stored: String? = "4821"
        val field = RelayPasscodeField(
            controller = null,
            readStored = { lookups++; stored },
            storeStored = { stored = it; true },
        )
        repeat(3) { field.value }
        assertEquals(1, lookups, "a recomposition must not read the secrets store again")

        var stateReads = 0
        val observed = Snapshot.takeSnapshot(readObserver = { stateReads++ })
        try {
            observed.enter { field.value }
        } finally {
            observed.dispose()
        }
        assertTrue(stateReads > 0, "the field must read Compose state so a change redraws it")

        var applied = false
        val handle = Snapshot.registerApplyObserver { _, _ -> applied = true }
        try {
            assertTrue(field.store("1357"))
            Snapshot.sendApplyNotifications()
        } finally {
            handle.dispose()
        }
        assertTrue(applied, "a stored code must notify the composition")
        assertEquals("1357", field.value)
    }
}

package com.opencapture.openzcine.relay

import android.content.SharedPreferences
import com.opencapture.opencine.relayruntime.WatcherRelaySecrets.LegacyMove
import com.opencapture.opencine.relayruntime.WatcherRelaySecrets.Lookup
import java.lang.reflect.Proxy
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class RelayPasscodesTest {
    @Test
    fun failedMigrationKeepsEverySavedHostAndWatcherCredentialUsable() {
        for (code in listOf("a", "ab", "abc", "  abc  ", "set pass", "🎬")) {
            val rig = Rig(code)
            rig.secure.available = false
            assertEquals(code, rig.passcodes.hostPasscodeLookup().usableValue)
            assertEquals(Lookup.Stored(code), rig.passcodes.rememberedPasscodeLookup("Set A"))
            assertEquals(code, rig.host.values[HOST_KEY])
            assertEquals(code, rig.watchers.values["Set A"])
        }
    }

    @Test
    fun aFailedWriteIntoAnEmptySecureStoreCannotOpenTheProtectedBroadcast() {
        val rig = Rig("abc")
        rig.secure.writesSucceed = false
        assertEquals("abc", rig.passcodes.hostPasscodeLookup().usableValue)
        assertEquals("abc", rig.passcodes.hostPasscodeLookup().usableValue)
        assertEquals("abc", rig.passcodes.rememberedPasscodeLookup("Set A").usableValue)
        assertEquals("abc", rig.host.values[HOST_KEY])
    }

    @Test
    fun readsRetryMigrationAndRemoveOnlyTheVerifiedLegacyCredentials() {
        val rig = Rig("abc")
        rig.secure.writesSucceed = false
        assertEquals("abc", rig.passcodes.hostPasscodeLookup().usableValue)
        rig.secure.writesSucceed = true
        assertEquals("abc", rig.passcodes.hostPasscodeLookup().usableValue)
        assertEquals("abc", rig.passcodes.rememberedPasscodeLookup("Set A").usableValue)
        assertFalse(rig.host.values.containsKey(HOST_KEY))
        assertFalse(rig.watchers.values.containsKey("Set A"))
        assertEquals(true, rig.host.values["unrelated"])
        assertEquals("other", rig.watchers.values["Set B"])
        val relaunched = RelayPasscodes(rig.secure, rig.host.preferences, rig.watchers.preferences)
        assertEquals("abc", relaunched.hostPasscodeLookup().usableValue)
        assertEquals("abc", relaunched.rememberedPasscodeLookup("Set A").usableValue)
    }

    @Test
    fun aVerifiedSecureCredentialWinsOverAnOlderPlaintextCopy() {
        val rig = Rig("old")
        rig.secure.host = "current"
        rig.secure.remembered["Set A"] = "current-watcher"
        assertEquals("current", rig.passcodes.hostPasscodeLookup().usableValue)
        assertEquals("current-watcher", rig.passcodes.rememberedPasscodeLookup("Set A").usableValue)
        assertFalse(rig.host.values.containsKey(HOST_KEY))
        assertFalse(rig.watchers.values.containsKey("Set A"))
    }

    @Test
    fun unavailableStorageWithoutALegacyCredentialIsNeverAnOpenFeed() {
        val rig = Rig(null)
        rig.secure.available = false
        assertNull(rig.passcodes.hostPasscodeLookup().usableValue)
        assertNull(rig.passcodes.rememberedPasscodeLookup("Set A").usableValue)
        assertFalse(rig.passcodes.storeHostPasscode("new code"))
        assertFalse(rig.passcodes.storeRememberedPasscode("new code", "Set A"))
    }

    @Test
    fun aFailedSecureEditDoesNotReportSuccessOrDiscardTheRetainedCredential() {
        val rig = Rig("abc")
        rig.secure.writesSucceed = false
        assertFalse(rig.passcodes.storeHostPasscode("new code"))
        assertFalse(rig.passcodes.storeRememberedPasscode("new code", "Set A"))
        assertEquals("abc", rig.passcodes.hostPasscodeLookup().usableValue)
        assertEquals("abc", rig.passcodes.rememberedPasscodeLookup("Set A").usableValue)
    }

    @Test
    fun aClearCannotResurrectRetainedCredentialsAfterRelaunch() {
        val rig = Rig("abc")
        rig.secure.writesSucceed = false
        assertFalse(rig.passcodes.storeHostPasscode(""))
        assertFalse(rig.passcodes.storeRememberedPasscode("", "Set A"))
        assertEquals("abc", rig.passcodes.hostPasscodeLookup().usableValue)
        rig.secure.writesSucceed = true
        assertTrue(rig.passcodes.storeHostPasscode(""))
        assertTrue(rig.passcodes.storeRememberedPasscode("", "Set A"))
        val relaunched = RelayPasscodes(rig.secure, rig.host.preferences, rig.watchers.preferences)
        assertEquals(Lookup.Absent, relaunched.hostPasscodeLookup())
        assertEquals(Lookup.Absent, relaunched.rememberedPasscodeLookup("Set A"))
        assertFalse(rig.host.values.containsKey(HOST_KEY))
        assertFalse(rig.watchers.values.containsKey("Set A"))
    }

    @Test
    fun aFailedLegacyRemovalBlocksClearingInsteadOfResurrectingTheOldCode() {
        val rig = Rig("abc")
        rig.host.removalSucceeds = false
        rig.watchers.removalSucceeds = false
        assertFalse(rig.passcodes.storeHostPasscode(""))
        assertFalse(rig.passcodes.storeRememberedPasscode("", "Set A"))
        assertEquals("abc", rig.passcodes.hostPasscodeLookup().usableValue)
        assertEquals("abc", rig.passcodes.rememberedPasscodeLookup("Set A").usableValue)
        rig.host.removalSucceeds = true
        rig.watchers.removalSucceeds = true
        assertTrue(rig.passcodes.storeHostPasscode(""))
        assertTrue(rig.passcodes.storeRememberedPasscode("", "Set A"))
        assertEquals(Lookup.Absent, rig.passcodes.hostPasscodeLookup())
        assertEquals(Lookup.Absent, rig.passcodes.rememberedPasscodeLookup("Set A"))
    }

    internal class Rig(code: String?) {
        val secure = SecureStorage()
        val host = MemoryPreferences(mutableMapOf<String, Any>("unrelated" to true).apply { if (code != null) put(HOST_KEY, code) })
        val watchers = MemoryPreferences(mutableMapOf<String, Any>("Set B" to "other").apply { if (code != null) put("Set A", code) })
        val passcodes by lazy { RelayPasscodes(secure, host.preferences, watchers.preferences) }
    }

    /** Models unavailable Keystore I/O; migration/readback semantics are tested in Core. */
    internal class SecureStorage : RelaySecurePasscodes {
        var host: String? = null
        val remembered = mutableMapOf<String, String>()
        var available = true
        var writesSucceed = true
        private fun lookup(value: String?): Lookup = if (!available) Lookup.Unavailable("unavailable")
            else value?.let { Lookup.Stored(it) } ?: Lookup.Absent
        override fun hostPasscodeLookup(): Lookup = lookup(host)
        override fun rememberedPasscodeLookup(host: String): Lookup = lookup(remembered[host])
        override fun storeHostPasscode(code: String): Boolean {
            if (!available || !writesSucceed) return false
            host = code.takeIf(String::isNotEmpty)
            return true
        }
        override fun storeRememberedPasscode(code: String, host: String): Boolean {
            if (!available || !writesSucceed) return false
            if (code.isEmpty()) remembered.remove(host) else remembered[host] = code
            return true
        }
        override fun adoptLegacyHostPasscode(code: String): LegacyMove = move(code, hostPasscodeLookup(), ::storeHostPasscode)
        override fun adoptLegacyRememberedPasscode(code: String, host: String): LegacyMove =
            move(code, rememberedPasscodeLookup(host)) { storeRememberedPasscode(it, host) }
        private fun move(code: String, lookup: Lookup, store: (String) -> Boolean): LegacyMove = when {
            code.isEmpty() -> LegacyMove.NOTHING_TO_MOVE
            lookup is Lookup.Stored -> LegacyMove.KEPT_STORED
            lookup is Lookup.Unavailable -> LegacyMove.FAILED
            store(code) -> LegacyMove.MOVED
            else -> LegacyMove.FAILED
        }
    }

    /** Only the SharedPreferences I/O boundary is replaced; the credential adapter is real. */
    internal class MemoryPreferences(val values: MutableMap<String, Any>) {
        var removalSucceeds = true
        val preferences: SharedPreferences = Proxy.newProxyInstance(
            SharedPreferences::class.java.classLoader, arrayOf(SharedPreferences::class.java),
        ) { _, method, args ->
            when (method.name) {
                "getString" -> values[args[0]] as? String ?: args[1]
                "contains" -> values.containsKey(args[0])
                "getAll" -> values.toMap()
                "edit" -> editor()
                else -> error("Unexpected preferences call: ${method.name}")
            }
        } as SharedPreferences

        private fun editor(): SharedPreferences.Editor {
            val removals = mutableSetOf<String>()
            return Proxy.newProxyInstance(
                SharedPreferences.Editor::class.java.classLoader, arrayOf(SharedPreferences.Editor::class.java),
            ) { proxy, method, args ->
                when (method.name) {
                    "remove" -> { removals += args[0] as String; proxy }
                    // A failed disk commit may still update the process's preferences view.
                    "commit" -> { removals.forEach(values::remove); removalSucceeds }
                    else -> error("Unexpected editor call: ${method.name}")
                }
            } as SharedPreferences.Editor
        }
    }

    private companion object {
        const val HOST_KEY = "sharing.watcherPasscode"
    }
}

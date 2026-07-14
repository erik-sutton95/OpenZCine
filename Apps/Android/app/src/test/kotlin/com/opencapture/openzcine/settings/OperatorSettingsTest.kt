package com.opencapture.openzcine.settings

import android.content.SharedPreferences
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class OperatorSettingsTest {
    private val store = FakePreferences()

    @Test
    fun `readouts default visible, assist tools default off`() {
        val settings = OperatorSettings(store)
        assertTrue(settings.recReadoutVisible.value)
        assertTrue(settings.codecReadoutVisible.value)
        assertTrue(settings.mediaReadoutVisible.value)
        assertTrue(settings.fpsReadoutVisible.value)
        assertFalse(settings.falseColorEnabled.value)
        assertFalse(settings.zebraEnabled.value)
        assertFalse(settings.peakingEnabled.value)
        assertFalse(settings.waveformEnabled.value)
    }

    @Test
    fun `toggle writes through and survives a reload`() {
        OperatorSettings(store).apply {
            falseColorEnabled.toggle()
            fpsReadoutVisible.toggle()
        }
        val reloaded = OperatorSettings(store)
        assertTrue(reloaded.falseColorEnabled.value)
        assertFalse(reloaded.fpsReadoutVisible.value)
    }

    @Test
    fun `storage keys never collide`() {
        val keys = OperatorSettings(store).all.map { it.key }
        assertEquals(keys.size, keys.toSet().size)
    }

    @Test
    fun `version text matches the iOS format`() {
        assertEquals("0.1.117 (42)", appVersionText("0.1.117", 42))
    }
}

/** In-memory [SharedPreferences] — only the boolean surface the store uses is real. */
private class FakePreferences : SharedPreferences {
    private val values = mutableMapOf<String, Any?>()

    override fun getAll(): MutableMap<String, *> = values

    override fun getString(key: String?, defValue: String?): String? =
        values[key] as? String ?: defValue

    override fun getStringSet(
        key: String?,
        defValues: MutableSet<String>?,
    ): MutableSet<String>? {
        @Suppress("UNCHECKED_CAST")
        return values[key] as? MutableSet<String> ?: defValues
    }

    override fun getInt(key: String?, defValue: Int): Int = values[key] as? Int ?: defValue

    override fun getLong(key: String?, defValue: Long): Long = values[key] as? Long ?: defValue

    override fun getFloat(key: String?, defValue: Float): Float =
        values[key] as? Float ?: defValue

    override fun getBoolean(key: String?, defValue: Boolean): Boolean =
        values[key] as? Boolean ?: defValue

    override fun contains(key: String?): Boolean = values.containsKey(key)

    override fun edit(): SharedPreferences.Editor = FakeEditor()

    override fun registerOnSharedPreferenceChangeListener(
        listener: SharedPreferences.OnSharedPreferenceChangeListener?
    ) = Unit

    override fun unregisterOnSharedPreferenceChangeListener(
        listener: SharedPreferences.OnSharedPreferenceChangeListener?
    ) = Unit

    private inner class FakeEditor : SharedPreferences.Editor {
        override fun putString(key: String?, value: String?): SharedPreferences.Editor =
            apply { values[key!!] = value }

        override fun putStringSet(
            key: String?,
            value: MutableSet<String>?,
        ): SharedPreferences.Editor = apply { values[key!!] = value }

        override fun putInt(key: String?, value: Int): SharedPreferences.Editor =
            apply { values[key!!] = value }

        override fun putLong(key: String?, value: Long): SharedPreferences.Editor =
            apply { values[key!!] = value }

        override fun putFloat(key: String?, value: Float): SharedPreferences.Editor =
            apply { values[key!!] = value }

        override fun putBoolean(key: String?, value: Boolean): SharedPreferences.Editor =
            apply { values[key!!] = value }

        override fun remove(key: String?): SharedPreferences.Editor =
            apply { values.remove(key) }

        override fun clear(): SharedPreferences.Editor = apply { values.clear() }

        override fun commit(): Boolean = true

        override fun apply() = Unit
    }
}

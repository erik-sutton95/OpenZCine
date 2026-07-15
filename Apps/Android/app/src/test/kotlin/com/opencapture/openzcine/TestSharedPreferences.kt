package com.opencapture.openzcine

import android.content.SharedPreferences

/** In-memory [SharedPreferences] used by JVM persistence tests. */
internal class TestSharedPreferences : SharedPreferences {
    private val values = mutableMapOf<String, Any?>()

    override fun getAll(): MutableMap<String, *> = values

    override fun getString(key: String?, defValue: String?): String? =
        values[key] as? String ?: defValue

    override fun getStringSet(
        key: String?,
        defValues: MutableSet<String>?,
    ): MutableSet<String>? {
        @Suppress("UNCHECKED_CAST")
        return (values[key] as? MutableSet<String>)?.toMutableSet() ?: defValues?.toMutableSet()
    }

    override fun getInt(key: String?, defValue: Int): Int = values[key] as? Int ?: defValue

    override fun getLong(key: String?, defValue: Long): Long = values[key] as? Long ?: defValue

    override fun getFloat(key: String?, defValue: Float): Float =
        values[key] as? Float ?: defValue

    override fun getBoolean(key: String?, defValue: Boolean): Boolean =
        values[key] as? Boolean ?: defValue

    override fun contains(key: String?): Boolean = values.containsKey(key)

    override fun edit(): SharedPreferences.Editor = Editor()

    override fun registerOnSharedPreferenceChangeListener(
        listener: SharedPreferences.OnSharedPreferenceChangeListener?,
    ) = Unit

    override fun unregisterOnSharedPreferenceChangeListener(
        listener: SharedPreferences.OnSharedPreferenceChangeListener?,
    ) = Unit

    private inner class Editor : SharedPreferences.Editor {
        override fun putString(key: String?, value: String?): SharedPreferences.Editor =
            apply { values[key!!] = value }

        override fun putStringSet(
            key: String?,
            value: MutableSet<String>?,
        ): SharedPreferences.Editor = apply { values[key!!] = value?.toMutableSet() }

        override fun putInt(key: String?, value: Int): SharedPreferences.Editor =
            apply { values[key!!] = value }

        override fun putLong(key: String?, value: Long): SharedPreferences.Editor =
            apply { values[key!!] = value }

        override fun putFloat(key: String?, value: Float): SharedPreferences.Editor =
            apply { values[key!!] = value }

        override fun putBoolean(key: String?, value: Boolean): SharedPreferences.Editor =
            apply { values[key!!] = value }

        override fun remove(key: String?): SharedPreferences.Editor = apply { values.remove(key) }

        override fun clear(): SharedPreferences.Editor = apply { values.clear() }

        override fun commit(): Boolean = true

        override fun apply() = Unit
    }
}

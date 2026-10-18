package com.opencapture.openzcine

import android.content.Context
import android.content.SharedPreferences

/**
 * Raw copies of the preference files a test changes, written back exactly afterwards. Saved cameras
 * live in two files (the Nikon records and the shared cameras document the app mirrors them into),
 * so a test that seeds a camera snapshots both or it leaks that camera into the next test.
 */
internal class PreferencesSnapshot(context: Context, vararg names: String) {
    private val saved: List<Pair<SharedPreferences, Map<String, *>>> =
        names.map { context.getSharedPreferences(it, Context.MODE_PRIVATE) }.map { it to it.all.toMap() }

    fun clear() = saved.forEach { (store, _) -> check(store.edit().clear().commit()) }

    fun restore() = saved.forEach { (store, values) ->
        val editor = store.edit().clear()
        values.forEach { (key, value) ->
            when (value) {
                is String -> editor.putString(key, value)
                is Boolean -> editor.putBoolean(key, value)
                is Int -> editor.putInt(key, value)
                is Long -> editor.putLong(key, value)
                is Float -> editor.putFloat(key, value)
                is Set<*> -> editor.putStringSet(key, value.map { requireNotNull(it as? String) }.toSet())
                else -> error("Unsupported saved preference type for $key")
            }
        }
        check(editor.commit())
    }
}

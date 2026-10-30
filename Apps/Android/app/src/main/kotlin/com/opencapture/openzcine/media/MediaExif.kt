package com.opencapture.openzcine.media

import androidx.compose.runtime.mutableStateMapOf

/**
 * Orientation a still's tagged thumbnail or full file taught this session. Camera thumbnails
 * arrive tagged with their still's orientation (the shared Nikon layer reads it from the still's
 * head) and `MonitorBitmapDecoder` turns them upright; a thumbnail that carries none (a HEIF
 * still's) falls back to the orientation learned here from the same object's full file. The
 * staggered grid reads it for a portrait card's shape, so the map is snapshot state: a learned
 * orientation resizes that card once. iOS persists the same fact on the index row; Android's
 * record crosses a fixed JNI wire format, so it lives in memory.
 */
internal object MediaExifOrientation {
    private val learned = mutableStateMapOf<String, Int>()

    /** Remembers an answer so thumbnails of the same object that carry none rotate too. */
    fun learn(key: String, orientation: Int) {
        if (orientation in 1..8 && learned[key] != orientation) learned[key] = orientation
    }

    fun learned(key: String?): Int? = key?.let(learned::get)
}

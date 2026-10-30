package com.opencapture.openzcine.media

import java.util.concurrent.ConcurrentHashMap

/**
 * Orientation a still's full file taught this session. Camera thumbnails arrive tagged with their
 * still's orientation (the shared Nikon layer reads it from the still's head) and
 * `MonitorBitmapDecoder` turns them upright; a thumbnail that carries none (a HEIF still's) falls
 * back to the orientation learned here from the same object's full file. iOS persists the same
 * fact on the index row; Android's record crosses a fixed JNI wire format, so it lives in memory.
 */
internal object MediaExifOrientation {
    private val learned = ConcurrentHashMap<String, Int>()

    /** Remembers a full-file answer so thumbnails of the same object that carry none rotate too. */
    fun learn(key: String, orientation: Int) {
        if (orientation in 1..8) learned[key] = orientation
    }

    fun learned(key: String?): Int? = key?.let(learned::get)
}

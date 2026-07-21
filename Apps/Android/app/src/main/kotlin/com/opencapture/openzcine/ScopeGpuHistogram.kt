package com.opencapture.openzcine

import android.graphics.Bitmap
import android.util.Log

private const val TAG = "ZCScopeGpu"

/**
 * Phase 4: GPU-oriented histogram path (Metal/MPS parity sketch).
 *
 * Full waveform scatter stays a follow-on. For now this provides a fast
 * luminance histogram over a downscaled copy so scopes can leave the UI
 * thread without blocking feed present. When Vulkan compute lands, this
 * adapter swaps implementation without changing [ScopeView] call sites.
 */
internal object ScopeGpuHistogram {
    data class Result(
        val luma: IntArray,
        val red: IntArray,
        val green: IntArray,
        val blue: IntArray,
    )

    /**
     * Samples [frame] into 256-bin channel histograms. Uses a software reduce
     * at [maxLongSide] so A12 stays under budget; Vulkan compute can replace
     * the body without API churn.
     */
    fun sample(frame: Bitmap, maxLongSide: Int = 256): Result? {
        if (frame.isRecycled || frame.width <= 0 || frame.height <= 0) return null
        return try {
            val scale =
                maxLongSide.toFloat() / maxOf(frame.width, frame.height).toFloat()
            val w = (frame.width * scale).toInt().coerceAtLeast(1)
            val h = (frame.height * scale).toInt().coerceAtLeast(1)
            val scaled =
                if (w == frame.width && h == frame.height) {
                    frame
                } else {
                    Bitmap.createScaledBitmap(frame, w, h, true)
                }
            val pixels = IntArray(w * h)
            scaled.getPixels(pixels, 0, w, 0, 0, w, h)
            if (scaled !== frame) scaled.recycle()
            samplePixels(pixels)
        } catch (error: RuntimeException) {
            Log.w(TAG, "histogram sample failed", error)
            null
        } catch (_: OutOfMemoryError) {
            null
        }
    }

    /** Pure binning for JVM tests and future GPU readback consumers. */
    fun samplePixels(pixels: IntArray): Result {
        val luma = IntArray(256)
        val red = IntArray(256)
        val green = IntArray(256)
        val blue = IntArray(256)
        for (p in pixels) {
            val r = (p shr 16) and 0xff
            val g = (p shr 8) and 0xff
            val b = p and 0xff
            val y = ((54 * r + 183 * g + 19 * b) shr 8).coerceIn(0, 255)
            red[r]++
            green[g]++
            blue[b]++
            luma[y]++
        }
        return Result(luma, red, green, blue)
    }
}

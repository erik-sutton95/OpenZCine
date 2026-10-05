@file:androidx.media3.common.util.UnstableApi

package com.opencapture.openzcine

import android.content.Context
import android.graphics.Bitmap
import android.graphics.ColorSpace
import android.os.Build
import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue

/** Electrical color contract of one decoded monitor frame. */
internal enum class LiveFeedColorMode {
    UNKNOWN,
    SDR,
    HDR,
    UNSUPPORTED,
}

/** Pure color-mode decision used by the decoder seam and JVM tests. */
internal fun classifyLiveFeedColorMode(
    hasGainmap: Boolean,
    isSrgb: Boolean,
    usesHdrTransfer: Boolean,
    usesFloatingPointPixels: Boolean,
): LiveFeedColorMode =
    when {
        hasGainmap || usesHdrTransfer -> LiveFeedColorMode.HDR
        isSrgb && !usesFloatingPointPixels -> LiveFeedColorMode.SDR
        else -> LiveFeedColorMode.UNSUPPORTED
    }

/**
 * Classifies the decoded bitmap before any assist renderer can see it.
 *
 * Nikon's current MJPEG monitor path is requested as 8-bit sRGB. Ultra HDR,
 * HLG/PQ, floating-point, or unrecognised wide-gamut input fails closed to the
 * plain feed rather than silently feeding a different electrical space into
 * the monitor cubes.
 */
internal fun decodedLiveFeedColorMode(bitmap: Bitmap): LiveFeedColorMode {
    val colorSpace = bitmap.colorSpace
    val usesHdrTransfer =
        Build.VERSION.SDK_INT >= 34 &&
            (colorSpace == ColorSpace.get(ColorSpace.Named.BT2020_HLG) ||
                colorSpace == ColorSpace.get(ColorSpace.Named.BT2020_PQ))
    return classifyLiveFeedColorMode(
        hasGainmap = Build.VERSION.SDK_INT >= 34 && bitmap.hasGainmap(),
        isSrgb = colorSpace?.isSrgb == true,
        usesHdrTransfer = usesHdrTransfer,
        usesFloatingPointPixels = bitmap.config == Bitmap.Config.RGBA_F16,
    )
}

/** Feed effects are supported throughout the app's API 29+ platform floor. */
internal fun liveFeedEffectsPlatformAvailable(sdk: Int, swiftCoreAvailable: Boolean): Boolean =
    sdk >= 29 && swiftCoreAvailable

/** Per-frame gate: the current LUT/effect plan consumes original SDR values only. */
internal fun liveFeedEffectsCanRender(
    sdk: Int,
    swiftCoreAvailable: Boolean,
    colorMode: LiveFeedColorMode,
): Boolean =
    liveFeedEffectsPlatformAvailable(sdk, swiftCoreAvailable) && colorMode == LiveFeedColorMode.SDR

/** Source-facing compatibility names over the shared pixel-rounded viewport. */
internal typealias LiveFeedGlViewport = com.opencapture.opencine.runtime.MonitorBitmapGlViewport

internal fun liveFeedGlViewport(
    surfaceWidth: Int, surfaceHeight: Int,
    sourceWidth: Int, sourceHeight: Int, aspectFill: Boolean,
): LiveFeedGlViewport? = com.opencapture.opencine.runtime.monitorBitmapGlViewport(
    surfaceWidth, surfaceHeight, sourceWidth, sourceHeight, aspectFill,
)

/** Native owners retain copy slots, render thread, texture/programs and terminal retirement. */
internal typealias LegacyLiveFeedFrameLease = com.opencapture.opencine.runtime.MonitorBitmapFrameLease
internal typealias LegacyLiveFeedFramePool = com.opencapture.opencine.runtime.MonitorBitmapFramePool

internal class LegacyLiveFeedGlSurface(context: Context) :
    com.opencapture.opencine.runtime.MonitorBitmapGlesSurface(context, ::Media3FeedGlBackend) {
    fun update(plan: FeedEffectsRenderPlan, aspectFill: Boolean, mirrored: Boolean) =
        super.update(plan.nativePlan, aspectFill, mirrored)
}

@Stable
internal class LegacyLiveFeedSurfaceState {
    private val native = com.opencapture.opencine.runtime.MonitorBitmapGlesSession().also { owner ->
        owner.onFailureStateChanged = { renderFailed = it }
    }
    var renderFailed: Boolean by mutableStateOf(false)
        private set
    fun submit(frame: Bitmap) = native.submit(frame)
    fun update(plan: FeedEffectsRenderPlan, aspectFill: Boolean, mirrored: Boolean) =
        native.update(plan.nativePlan, aspectFill, mirrored)
    fun attach(view: LegacyLiveFeedGlSurface) = native.attach(view)
    fun detach(view: LegacyLiveFeedGlSurface) = native.detach(view)
    fun clear() = native.clear()
    fun resume() = native.resume()
    fun pause() = native.pause()
    fun dispose() = native.dispose()
    internal fun recordRenderFailure(plan: FeedEffectsRenderPlan): Boolean =
        native.recordRenderFailure(plan.nativePlan)
}

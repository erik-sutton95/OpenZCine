package com.opencapture.openzcine

import android.content.Context
import android.graphics.Bitmap
import android.os.Build
import android.util.Log
import android.view.SurfaceView
import android.view.View
import com.opencapture.opencine.runtime.MonitorBitmapVulkanSession
import com.opencapture.opencine.media.MonitorZebraMaskPolicy
import com.opencapture.openpocketcine.feed.OpcVulkan

private const val TAG = "ZCLiveFeedGpu"

/**
 * GPU present path for the live monitor feed (Metal-parity on Android).
 *
 * Adapters grade [FeedEffectsRenderPlan] into a [SurfaceView]. Compose chrome
 * overlays the surface; the graded video never round-trips through Compose Canvas.
 *
 * **Liquid glass caveat:** Kyant `layerBackdrop` cannot sample a SurfaceView.
 * [LiveFeedView] only activates this backend when glass is FLAT (or absent);
 * FULL glass uses Compose Canvas + AGSL so chrome/popups blur the feed.
 */
internal interface LiveFeedGpuBackend {
    /** Android view that owns the swapchain / GL surface. */
    fun createView(context: Context): View

    fun attach(view: View)

    fun detach(view: View)

    fun updatePlan(plan: FeedEffectsRenderPlan?, aspectFill: Boolean, mirrored: Boolean, mirroredVertical: Boolean = false)

    fun submitFrame(frame: Bitmap)

    fun clearFrame()

    fun resume()

    fun pause()

    fun dispose()

    /** True after a hard render failure; caller may fall back to plain Canvas. */
    val renderFailed: Boolean

    val kind: Kind

    enum class Kind {
        GLES,
        VULKAN,
    }
}

/**
 * Chooses the live GPU present backend.
 *
 * Order: Vulkan (when native module loads + device supports it) → GLES2 surface.
 * AGSL is intentionally **not** a live-monitor backend (A12 jank measurements).
 */
/** Phones reporting less total RAM keep the proven GLES surface. */
private const val MIN_VULKAN_RAM_BYTES: Long = 4L * 1024L * 1024L * 1024L

internal object LiveFeedGpuBackendFactory {
    @Volatile private var vulkanProbed = false
    @Volatile private var vulkanAvailable = false

    fun create(context: Context): LiveFeedGpuBackend {
        if (preferVulkan(context.applicationContext)) {
            runCatching {
                val backend = VulkanLiveFeedBackend(context.applicationContext)
                Log.i(TAG, "live feed GPU backend=VULKAN")
                return backend
            }.onFailure { error ->
                Log.w(TAG, "Vulkan live feed init failed — falling back to GLES", error)
            }
        }
        Log.i(TAG, "live feed GPU backend=GLES")
        return GlesLiveFeedBackend()
    }

    private fun preferVulkan(appContext: Context): Boolean {
        if (Build.VERSION.SDK_INT < 29) return false
        // Floor devices (A12 / <4 GB): ship the proven GLES surface first.
        // Vulkan remains preferred on mid/high-RAM phones once native init succeeds.
        val lowRam =
            runCatching {
                val am =
                    appContext.getSystemService(Context.ACTIVITY_SERVICE)
                        as android.app.ActivityManager
                val info = android.app.ActivityManager.MemoryInfo().also(am::getMemoryInfo)
                am.isLowRamDevice || info.totalMem < MIN_VULKAN_RAM_BYTES
            }.getOrDefault(false)
        if (lowRam) {
            Log.i(TAG, "low-RAM floor — preferring GLES live surface")
            return false
        }
        if (!vulkanProbed) {
            vulkanProbed = true
            vulkanAvailable =
                runCatching { OpcVulkan.isAvailable && OpcVulkan.nativeProbeBitmap() }
                    .getOrDefault(false)
            Log.i(TAG, "Vulkan native available=$vulkanAvailable")
        }
        return vulkanAvailable
    }
}

/**
 * GLES2 surface adapter wrapping the existing one-pass [LegacyLiveFeedSurfaceState]
 * (same shader as Media3 playback).
 */
internal class GlesLiveFeedBackend : LiveFeedGpuBackend {
    private val state = LegacyLiveFeedSurfaceState()

    override val kind: LiveFeedGpuBackend.Kind = LiveFeedGpuBackend.Kind.GLES

    override val renderFailed: Boolean
        get() = state.renderFailed

    override fun createView(context: Context): View =
        LegacyLiveFeedGlSurface(context).also { /* attach happens in AndroidView factory */ }

    override fun attach(view: View) {
        val surface = view as? LegacyLiveFeedGlSurface ?: return
        state.attach(surface)
    }

    override fun detach(view: View) {
        val surface = view as? LegacyLiveFeedGlSurface ?: return
        state.detach(surface)
    }

    private var uploadedPlan: FeedEffectsRenderPlan? = null
    private var uploadedAspectFill = false
    private var uploadedMirrored = false
    private var uploadedMirroredVertical = false

    override fun updatePlan(plan: FeedEffectsRenderPlan?, aspectFill: Boolean, mirrored: Boolean, mirroredVertical: Boolean) {
        // Same per-recomposition storm as the Vulkan path — see the note on its own `uploadedPlan`.
        // Cheaper per call here, but a texture re-upload per frame is still a texture re-upload per
        // frame, and the two backends must not drift on when they consider a plan new.
        if (plan === uploadedPlan && aspectFill == uploadedAspectFill &&
            mirrored == uploadedMirrored && mirroredVertical == uploadedMirroredVertical
        ) {
            return
        }
        uploadedPlan = plan
        uploadedAspectFill = aspectFill
        uploadedMirrored = mirrored
        uploadedMirroredVertical = mirroredVertical
        if (plan != null) state.update(plan, aspectFill, mirrored, mirroredVertical) else state.clear()
    }

    override fun submitFrame(frame: Bitmap) {
        state.submit(frame)
    }

    override fun clearFrame() {
        state.clear()
    }

    override fun resume() {
        state.resume()
    }

    override fun pause() {
        state.pause()
    }

    override fun dispose() {
        state.dispose()
    }
}

/** Source/backend selection over the existing shared Bitmap native picture owner. */
internal class VulkanLiveFeedBackend(
    private val appContext: Context,
) : LiveFeedGpuBackend {
    private val native = MonitorBitmapVulkanSession { Log.e(TAG, it) }
    override val kind: LiveFeedGpuBackend.Kind = LiveFeedGpuBackend.Kind.VULKAN
    override val renderFailed: Boolean get() = native.failed
    override fun createView(context: Context): View = native.createView(context)
    override fun attach(view: View) = native.attach(view)
    override fun detach(view: View) = native.detach(view)
    override fun updatePlan(plan: FeedEffectsRenderPlan?, aspectFill: Boolean, mirrored: Boolean, mirroredVertical: Boolean) =
        native.updatePlan(plan?.nativePlan, aspectFill, mirrored, mirroredVertical)
    override fun submitFrame(frame: Bitmap) = native.submit(frame)
    override fun clearFrame() = native.clearFrame()
    override fun resume() = native.resume()
    override fun pause() = native.pause()
    override fun dispose() = native.close()
}

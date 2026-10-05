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

    fun updatePlan(plan: FeedEffectsRenderPlan?, aspectFill: Boolean, mirrored: Boolean)

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
                am.isLowRamDevice || info.totalMem < MIN_FULL_GLASS_RAM_BYTES
            }.getOrDefault(false)
        if (lowRam) {
            Log.i(TAG, "low-RAM floor — preferring GLES live surface")
            return false
        }
        if (!vulkanProbed) {
            vulkanProbed = true
            vulkanAvailable =
                runCatching {
                    VulkanLiveFeedNative.nativeInitAssets(appContext.assets)
                    VulkanLiveFeedNative.isAvailable()
                }.getOrDefault(false)
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

    override fun updatePlan(plan: FeedEffectsRenderPlan?, aspectFill: Boolean, mirrored: Boolean) {
        // Same per-recomposition storm as the Vulkan path — see the note on its own `uploadedPlan`.
        // Cheaper per call here, but a texture re-upload per frame is still a texture re-upload per
        // frame, and the two backends must not drift on when they consider a plan new.
        if (plan === uploadedPlan && aspectFill == uploadedAspectFill &&
            mirrored == uploadedMirrored
        ) {
            return
        }
        uploadedPlan = plan
        uploadedAspectFill = aspectFill
        uploadedMirrored = mirrored
        if (plan != null) state.update(plan, aspectFill, mirrored) else state.clear()
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
    override fun updatePlan(plan: FeedEffectsRenderPlan?, aspectFill: Boolean, mirrored: Boolean) =
        native.updatePlan(plan?.nativePlan, aspectFill, mirrored)
    override fun submitFrame(frame: Bitmap) = native.submit(frame)
    override fun clearFrame() = native.clearFrame()
    override fun resume() = native.resume()
    override fun pause() = native.pause()
    override fun dispose() = native.close()
}

/** Original internal helper signatures delegate to the shared native binding. */
internal object VulkanLiveFeedNative {
    fun nativeInitAssets(assets: android.content.res.AssetManager) = Unit
    fun isAvailable(): Boolean = OpcVulkan.isAvailable && OpcVulkan.nativeProbeBitmap()
    fun createSession(): Long = OpcVulkan.nativeCreateBitmap()
    fun destroySession(session: Long) = OpcVulkan.nativeDestroy(session)
    fun attachSurface(session: Long, surface: android.view.Surface): Boolean =
        OpcVulkan.nativeAttachBitmapWindow(session, surface)
    fun detachSurface(session: Long) = OpcVulkan.nativeDetachWindow(session)
    fun resize(session: Long, width: Int, height: Int) = OpcVulkan.nativeResize(session, width, height)
    fun resume(session: Long) { OpcVulkan.nativeSetBitmapPaused(session, false) }
    fun pause(session: Long) { OpcVulkan.nativeSetBitmapPaused(session, true) }
    fun clearFrame(session: Long) = OpcVulkan.nativeClearBitmap(session)
    fun clearPlan(session: Long) = OpcVulkan.nativeClearBitmapPlan(session)
    fun submitBitmap(session: Long, bitmap: Bitmap): Boolean = OpcVulkan.nativeSubmitBitmap(session, bitmap)

    fun setPlan(
        session: Long,
        lutSize: Int, lutRgba: ByteArray?,
        limitsPaintSize: Int, limitsPaintRgba: ByteArray?,
        limitsWeightSize: Int, limitsWeightRgba: ByteArray?,
        limitsOn: Boolean, peakingOn: Boolean,
        peakingColor: FloatArray, deLogCurve: FloatArray,
        peakingRatioThreshold: Float, peakingNoiseGate: Float,
        zebraHighlightOn: Boolean, zebraHighlight: Float, zebraHighlightColor: FloatArray,
        zebraMidtoneOn: Boolean, zebraMidtone: Float, zebraMidtoneColor: FloatArray,
        aspectFill: Boolean, mirrored: Boolean, splitOn: Boolean, splitVertical: Boolean,
    ): Boolean {
        // Preserve the raw helper's original uniform values and cube payloads.
        // The shared native owner validates each packed 2D cube independently.
        val controls = FloatArray(40)
        controls[0] = lutSize.toFloat()
        controls[1] = if (peakingOn) 1f else 0f
        controls[2] = if (zebraHighlightOn) 1f else 0f
        controls[3] = if (zebraMidtoneOn) 1f else 0f
        peakingColor.take(3).forEachIndexed { i, value -> controls[4 + i] = value }
        zebraHighlightColor.take(3).forEachIndexed { i, value -> controls[8 + i] = value }
        zebraMidtoneColor.take(3).forEachIndexed { i, value -> controls[12 + i] = value }
        controls[16] = peakingRatioThreshold
        controls[17] = peakingNoiseGate
        controls[18] = zebraHighlight
        controls[19] = zebraMidtone
        controls[20] = if (aspectFill) 1f else 0f
        controls[21] = if (splitOn) 1f else 0f
        controls[22] = if (splitVertical) 1f else 0f
        controls[23] = if (mirrored) 1f else 0f
        deLogCurve.take(5).forEachIndexed { i, value -> controls[24 + i] = value }
        controls[32] = limitsPaintSize.toFloat()
        controls[33] = limitsWeightSize.toFloat()
        controls[34] = if (limitsOn) 1f else 0f
        controls[36] = 0f
        controls[37] = 0f
        controls[38] = 5f / 255f
        return OpcVulkan.nativeConfigureBitmap(
            session, controls, lutSize, lutRgba,
            limitsPaintSize, limitsPaintRgba, limitsWeightSize, limitsWeightRgba,
        )
    }
}

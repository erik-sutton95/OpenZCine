package com.opencapture.openzcine

import android.content.Context
import android.graphics.Bitmap
import android.os.Build
import android.util.Log
import android.view.SurfaceView
import android.view.View

private const val TAG = "ZCLiveFeedGpu"

/**
 * GPU present path for the live monitor feed (Metal-parity on Android).
 *
 * Adapters grade [FeedEffectsRenderPlan] into a [SurfaceView]. Compose chrome
 * overlays the surface; the graded video never round-trips through Compose Canvas.
 */
internal interface LiveFeedGpuBackend {
    /** Android view that owns the swapchain / GL surface. */
    fun createView(context: Context): View

    fun attach(view: View)

    fun detach(view: View)

    fun updatePlan(plan: FeedEffectsRenderPlan?, aspectFill: Boolean)

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
                    System.loadLibrary("openzcine_live_feed_vk")
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

    override fun updatePlan(plan: FeedEffectsRenderPlan?, aspectFill: Boolean) {
        if (plan != null) state.update(plan, aspectFill) else state.clear()
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

/**
 * Vulkan swapchain present path. JNI implementation lives in
 * `src/main/cpp/live_feed_vk/`. Falls back is handled by the factory.
 */
internal class VulkanLiveFeedBackend(
    private val appContext: Context,
) : LiveFeedGpuBackend {
    private val session = VulkanLiveFeedNative.createSession()
    private var surfaceView: SurfaceView? = null
    private var disposed = false

    override val kind: LiveFeedGpuBackend.Kind = LiveFeedGpuBackend.Kind.VULKAN

    @Volatile
    override var renderFailed: Boolean = false
        private set

    init {
        check(session != 0L) { "Vulkan session create failed" }
    }

    override fun createView(context: Context): View {
        val view = SurfaceView(context)
        view.holder.addCallback(
            object : android.view.SurfaceHolder.Callback {
                override fun surfaceCreated(holder: android.view.SurfaceHolder) {
                    if (disposed) return
                    if (!VulkanLiveFeedNative.attachSurface(session, holder.surface)) {
                        renderFailed = true
                        Log.e(TAG, "Vulkan attachSurface failed")
                    }
                }

                override fun surfaceChanged(
                    holder: android.view.SurfaceHolder,
                    format: Int,
                    width: Int,
                    height: Int,
                ) {
                    if (disposed) return
                    VulkanLiveFeedNative.resize(session, width, height)
                }

                override fun surfaceDestroyed(holder: android.view.SurfaceHolder) {
                    if (disposed) return
                    VulkanLiveFeedNative.detachSurface(session)
                }
            },
        )
        surfaceView = view
        return view
    }

    override fun attach(view: View) {
        // Surface callbacks own attach; keep for interface symmetry.
    }

    override fun detach(view: View) {
        if (!disposed) VulkanLiveFeedNative.detachSurface(session)
    }

    override fun updatePlan(plan: FeedEffectsRenderPlan?, aspectFill: Boolean) {
        if (disposed) return
        if (plan == null) {
            VulkanLiveFeedNative.clearPlan(session)
            return
        }
        // Upload Swift-baked cube + uniforms into the native grade pass.
        val ok =
            VulkanLiveFeedNative.setPlan(
                session,
                plan.baseCube?.size ?: 0,
                plan.baseCube?.rgba,
                plan.limitsPaintCube?.size ?: 0,
                plan.limitsPaintCube?.rgba,
                plan.limitsWeightCube?.size ?: 0,
                plan.limitsWeightCube?.rgba,
                plan.limitsReady,
                plan.effects.peaking,
                plan.configuration.peakingColor,
                plan.configuration.deLogCurve,
                plan.configuration.peakingThreshold,
                plan.configuration.peakingRamp,
                plan.effects.zebra && plan.configuration.highlightEnabled,
                plan.configuration.highlightCode,
                plan.configuration.highlightColor,
                plan.effects.zebra && plan.configuration.midtoneEnabled,
                plan.configuration.midtoneCode,
                plan.configuration.midtoneColor,
                aspectFill,
            )
        if (!ok) {
            renderFailed = true
            Log.e(TAG, "Vulkan setPlan failed")
        }
    }

    override fun submitFrame(frame: Bitmap) {
        if (disposed || renderFailed) return
        if (!VulkanLiveFeedNative.submitBitmap(session, frame)) {
            renderFailed = true
            Log.e(TAG, "Vulkan submitBitmap failed")
        }
    }

    override fun clearFrame() {
        if (!disposed) VulkanLiveFeedNative.clearFrame(session)
    }

    override fun resume() {
        if (!disposed) VulkanLiveFeedNative.resume(session)
    }

    override fun pause() {
        if (!disposed) VulkanLiveFeedNative.pause(session)
    }

    override fun dispose() {
        if (disposed) return
        disposed = true
        VulkanLiveFeedNative.destroySession(session)
        surfaceView = null
    }
}

/** JNI surface for [libopenzcine_live_feed_vk.so]. */
internal object VulkanLiveFeedNative {
    external fun nativeInitAssets(assets: android.content.res.AssetManager)

    external fun isAvailable(): Boolean

    external fun createSession(): Long

    external fun destroySession(session: Long)

    external fun attachSurface(session: Long, surface: android.view.Surface): Boolean

    external fun detachSurface(session: Long)

    external fun resize(session: Long, width: Int, height: Int)

    external fun resume(session: Long)

    external fun pause(session: Long)

    external fun clearFrame(session: Long)

    external fun clearPlan(session: Long)

    external fun submitBitmap(session: Long, bitmap: Bitmap): Boolean

    external fun setPlan(
        session: Long,
        lutSize: Int,
        lutRgba: ByteArray?,
        limitsPaintSize: Int,
        limitsPaintRgba: ByteArray?,
        limitsWeightSize: Int,
        limitsWeightRgba: ByteArray?,
        limitsOn: Boolean,
        peakingOn: Boolean,
        peakingColor: FloatArray,
        deLogCurve: FloatArray,
        peakingThreshold: Float,
        peakingRamp: Float,
        zebraHighlightOn: Boolean,
        zebraHighlight: Float,
        zebraHighlightColor: FloatArray,
        zebraMidtoneOn: Boolean,
        zebraMidtone: Float,
        zebraMidtoneColor: FloatArray,
        aspectFill: Boolean,
    ): Boolean
}

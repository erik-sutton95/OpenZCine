package com.opencapture.openzcine

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.RenderEffect
import androidx.annotation.RequiresApi
import com.opencapture.opencine.runtime.MonitorBitmapEffects
import com.opencapture.opencine.runtime.MonitorBitmapPreviewBaker
import com.opencapture.opencine.media.MonitorZebraMaskPolicy
import com.opencapture.openzcine.lut.AndroidLutLibrary

typealias LiveFramePreviewBaker = MonitorBitmapPreviewBaker

/** Native primitive adapter; the shared owner holds shader, bitmap bindings and preview target. */
@RequiresApi(33)
class FeedEffectsRenderer private constructor(private val native: MonitorBitmapEffects) :
    LiveFramePreviewBaker, AutoCloseable {
    internal val falseColorReady: Boolean get() = native.falseColorReady
    fun draw(canvas: Canvas, frame: Bitmap, dstLeft: Float, dstTop: Float,
        dstWidth: Float, dstHeight: Float) =
        native.draw(canvas, frame, dstLeft, dstTop, dstWidth, dstHeight)
    override fun bakePreview(frame: Bitmap, maximumWidth: Int): Bitmap? =
        native.bakePreview(frame, maximumWidth)
    fun viewRenderEffect(width: Int, height: Int): RenderEffect? = native.viewRenderEffect(width, height)
    override fun close() = native.close()
    companion object {
        fun create(effects: FeedEffects, configuration: FeedEffectsConfiguration,
            cameraInput: ExposureAssistCameraInput, lutLibrary: AndroidLutLibrary? = null): FeedEffectsRenderer? {
            val plan = FeedEffectsRenderPlanFactory.create(effects, configuration, cameraInput, lutLibrary)
                ?: return null
            return create(plan)
        }
        internal fun create(plan: FeedEffectsRenderPlan): FeedEffectsRenderer = FeedEffectsRenderer(
            MonitorBitmapEffects.create(plan.nativePlan, plan.falseColorReady,
                MonitorZebraMaskPolicy(MonitorZebraMaskPolicy.HighlightMeasure.REC709_LUMA, 0.0)))
    }
}

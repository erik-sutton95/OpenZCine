@file:androidx.media3.common.util.UnstableApi

package com.opencapture.openzcine

import android.content.Context
import android.graphics.Bitmap
import androidx.media3.common.util.GlProgram
import androidx.media3.common.util.GlUtil
import com.opencapture.opencine.runtime.NativeGlBackend
import com.opencapture.opencine.runtime.NativeGlProgram

/** Existing Media3 primitives; native runtime owns programs, cubes and multipass targets. */
internal class FeedEffectsGlProgram(
    context: Context,
    plan: FeedEffectsRenderPlan,
    flipInputVertically: Boolean = false,
) {
    private val native = com.opencapture.opencine.runtime.FeedEffectsGlProgram(
        Media3FeedGlBackend(context), plan.nativePlan, flipInputVertically,
    )

    fun draw(
        inputTexture: Int,
        sourceWidth: Float,
        sourceHeight: Float,
        displayWidth: Float,
        displayHeight: Float,
        mirrored: Boolean = false,
    ) = native.draw(inputTexture, sourceWidth, sourceHeight, displayWidth, displayHeight, mirrored)

    fun release() = native.release()
}

internal class Media3FeedGlBackend(private val context: Context) : NativeGlBackend {
    override fun createProgram(vertexAsset: String, fragmentAsset: String): NativeGlProgram =
        Media3FeedGlProgram(GlProgram(context, vertexAsset, fragmentAsset))
    override fun normalizedCoordinateBounds(): FloatArray = GlUtil.getNormalizedCoordinateBounds()
    override val homogeneousCoordinateVectorSize: Int get() = GlUtil.HOMOGENEOUS_COORDINATE_VECTOR_SIZE
    override fun createTexture(width: Int, height: Int): Int = GlUtil.createTexture(width, height, false)
    override fun createTexture(bitmap: Bitmap): Int = GlUtil.createTexture(bitmap)
    override fun createFramebuffer(texture: Int): Int = GlUtil.createFboForTexture(texture)
    override fun focusFramebuffer(framebuffer: Int, width: Int, height: Int) =
        GlUtil.focusFramebufferUsingCurrentContext(framebuffer, width, height)
    override fun deleteFramebuffer(framebuffer: Int) = GlUtil.deleteFbo(framebuffer)
    override fun deleteTexture(texture: Int) = GlUtil.deleteTexture(texture)
    override fun checkError() = GlUtil.checkGlError()
}

private class Media3FeedGlProgram(private val program: GlProgram) : NativeGlProgram {
    override fun use() = program.use()
    override fun setBufferAttribute(name: String, values: FloatArray, size: Int) =
        program.setBufferAttribute(name, values, size)
    override fun setFloatsUniform(name: String, values: FloatArray) = program.setFloatsUniform(name, values)
    override fun setSamplerTexIdUniform(name: String, texture: Int, unit: Int) =
        program.setSamplerTexIdUniform(name, texture, unit)
    override fun bindAttributesAndUniforms() = program.bindAttributesAndUniforms()
    override fun delete() = program.delete()
}

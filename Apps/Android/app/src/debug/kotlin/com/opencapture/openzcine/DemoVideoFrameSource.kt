package com.opencapture.openzcine

import android.content.Context
import android.content.res.AssetFileDescriptor
import android.graphics.ImageFormat
import android.graphics.Rect
import android.graphics.YuvImage
import android.media.Image
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.util.Log
import com.opencapture.openzcine.core.LiveFrame
import com.opencapture.openzcine.core.LiveFrameSource
import com.opencapture.openzcine.core.LiveFrameTimecode
import java.io.ByteArrayOutputStream
import java.io.File
import kotlin.math.roundToInt
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.FlowCollector
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.isActive
import kotlin.coroutines.coroutineContext

/**
 * Debug-only [LiveFrameSource] that loops a local sample video (gitignored
 * `samples/` clips staged into debug assets, or `zc.demo.video` path).
 *
 * Uses **sequential** [MediaExtractor] + [MediaCodec] H.264 decode — not
 * [android.media.MediaMetadataRetriever.getFrameAtTime], which re-seeks from
 * keyframes and is an order of magnitude too slow for a 1080p proxy.
 *
 * First pass: decode every frame in order, emit JPEG immediately, and keep a
 * copy for looping. Steady loop: replay the in-memory buffer at the clip fps
 * (typically 25) with no decoder work.
 *
 * The sample never ships in release; it stays outside the committed tree.
 */
class DemoVideoFrameSource(
    private val openDataSource: () -> DataSource?,
    @Suppress("UNUSED_PARAMETER")
    private val includeDebugCameraLevel: Boolean = true,
) : LiveFrameSource {
    override val frames: Flow<LiveFrame> =
        flow {
            val source = openDataSource()
            if (source == null) {
                Log.w(TAG, "sample video could not be opened")
                return@flow
            }
            val loop = ArrayList<ByteArray>(MAX_LOOP_FRAMES)
            var clipFps = DEFAULT_CLIP_FPS
            try {
                val collector: FlowCollector<LiveFrame> = this
                val decoded =
                    decodeClipSequentially(source) { jpeg, frameIndex, fps ->
                        clipFps = fps
                        if (loop.size < MAX_LOOP_FRAMES) loop += jpeg
                        if (coroutineContext.isActive) {
                            collector.emit(
                                LiveFrame(
                                    timestampNanos = System.nanoTime(),
                                    jpegData = jpeg,
                                    audioLevels = null,
                                    focus = null,
                                    level = null,
                                    timecode = demoTimecode(frameIndex, fps),
                                    measuredFramesPerSecond = fps.toDouble(),
                                ),
                            )
                        }
                    }
                if (!decoded) {
                    Log.w(TAG, "sequential decode produced no frames")
                    return@flow
                }
            } catch (error: Exception) {
                Log.w(TAG, "demo video decode failed", error)
            } finally {
                source.close()
            }

            if (loop.isEmpty()) return@flow
            Log.i(TAG, "demo video loop ready (${loop.size} frames @ ${clipFps} fps)")
            val periodNanos = 1_000_000_000L / clipFps
            var frameIndex = 0L
            val startNanos = System.nanoTime()
            while (coroutineContext.isActive) {
                val jpeg = loop[(frameIndex % loop.size).toInt()]
                emit(
                    LiveFrame(
                        timestampNanos = System.nanoTime(),
                        jpegData = jpeg,
                        audioLevels = null,
                        focus = null,
                        level = null,
                        timecode = demoTimecode(frameIndex, clipFps),
                        measuredFramesPerSecond = clipFps.toDouble(),
                    ),
                )
                frameIndex++
                val dueNanos = startNanos + frameIndex * periodNanos
                val waitMillis = (dueNanos - System.nanoTime()) / 1_000_000
                if (waitMillis > 0) delay(waitMillis)
            }
        }
            .flowOn(Dispatchers.Default)

    /**
     * Sequential MediaCodec decode of the video track. Invokes [onFrame] for
     * each decoded sample. Returns true when at least one frame was produced.
     */
    private suspend fun decodeClipSequentially(
        source: DataSource,
        onFrame: suspend (jpeg: ByteArray, frameIndex: Long, fps: Int) -> Unit,
    ): Boolean {
        val extractor = MediaExtractor()
        source.applyTo(extractor)
        val trackIndex = selectVideoTrack(extractor) ?: run {
            Log.w(TAG, "no video track in sample")
            extractor.release()
            return false
        }
        extractor.selectTrack(trackIndex)
        val format = extractor.getTrackFormat(trackIndex)
        val mime = format.getString(MediaFormat.KEY_MIME) ?: run {
            extractor.release()
            return false
        }
        val width = format.getInteger(MediaFormat.KEY_WIDTH)
        val height = format.getInteger(MediaFormat.KEY_HEIGHT)
        val fps = resolveClipFps(format)
        Log.i(TAG, "demo video decoding $mime ${width}x${height} @ ${fps} fps (sequential MediaCodec)")

        val codec = MediaCodec.createDecoderByType(mime)
        // Request a flexible YUV output so we can compress to JPEG without a Surface.
        format.setInteger(
            MediaFormat.KEY_COLOR_FORMAT,
            android.media.MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Flexible,
        )
        codec.configure(format, null, null, 0)
        codec.start()

        val bufferInfo = MediaCodec.BufferInfo()
        val jpegStream = ByteArrayOutputStream()
        var inputDone = false
        var outputDone = false
        var frameIndex = 0L
        var sawFrame = false
        val timeoutUs = 10_000L

        try {
            while (!outputDone && coroutineContext.isActive) {
                if (!inputDone) {
                    val inIndex = codec.dequeueInputBuffer(timeoutUs)
                    if (inIndex >= 0) {
                        val input = codec.getInputBuffer(inIndex)
                        if (input == null) {
                            codec.queueInputBuffer(inIndex, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            inputDone = true
                        } else {
                            val sampleSize = extractor.readSampleData(input, 0)
                            if (sampleSize < 0) {
                                codec.queueInputBuffer(
                                    inIndex, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM,
                                )
                                inputDone = true
                            } else {
                                val pts = extractor.sampleTime.coerceAtLeast(0L)
                                codec.queueInputBuffer(inIndex, 0, sampleSize, pts, 0)
                                extractor.advance()
                            }
                        }
                    }
                }

                when (val outIndex = codec.dequeueOutputBuffer(bufferInfo, timeoutUs)) {
                    MediaCodec.INFO_TRY_AGAIN_LATER -> Unit
                    MediaCodec.INFO_OUTPUT_FORMAT_CHANGED ->
                        Log.d(TAG, "decoder output format: ${codec.outputFormat}")
                    else -> {
                        if (outIndex >= 0) {
                            val eos = bufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0
                            if (bufferInfo.size > 0 && bufferInfo.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG == 0) {
                                val image = codec.getOutputImage(outIndex)
                                if (image != null) {
                                    try {
                                        val jpeg = imageToJpeg(image, jpegStream)
                                        if (jpeg != null) {
                                            sawFrame = true
                                            onFrame(jpeg, frameIndex, fps)
                                            frameIndex++
                                        }
                                    } finally {
                                        image.close()
                                    }
                                }
                            }
                            codec.releaseOutputBuffer(outIndex, false)
                            if (eos) outputDone = true
                        }
                    }
                }
            }
        } finally {
            runCatching { codec.stop() }
            runCatching { codec.release() }
            runCatching { extractor.release() }
        }
        return sawFrame
    }

    companion object {
        private const val TAG = "DemoVideoFrameSource"
        private const val DEFAULT_CLIP_FPS = 25
        private const val MAX_LOOP_FRAMES = 300
        /** Long-edge cap for demo JPEG so BitmapFactory + GL stay light. */
        private const val MAX_LONG_EDGE = 1280
        private const val JPEG_QUALITY = 82
        private const val ASSET_DEMO_DIR = "demo"

        /** Preferred sample name when several files exist under samples/assets. */
        const val PREFERRED_SAMPLE_NAME = "A002_C057_0704BT.MP4"

        fun resolve(
            context: Context,
            explicitPath: String?,
            includeDebugCameraLevel: Boolean,
        ): DemoVideoFrameSource? {
            explicitPath?.trim()?.takeIf { it.isNotEmpty() }?.let { path ->
                val file = File(path)
                if (file.isFile) {
                    Log.i(TAG, "demo video ← file $path")
                    return DemoVideoFrameSource(
                        openDataSource = {
                            try {
                                FileDataSource(path)
                            } catch (error: Exception) {
                                Log.w(TAG, "cannot open demo file $path", error)
                                null
                            }
                        },
                        includeDebugCameraLevel = includeDebugCameraLevel,
                    )
                }
                Log.w(TAG, "zc.demo.video path not found: $path")
            }

            val assetName = preferredDemoAsset(context) ?: return null
            val assetPath = "$ASSET_DEMO_DIR/$assetName"
            Log.i(TAG, "demo video ← asset $assetPath")
            return DemoVideoFrameSource(
                openDataSource = { openAssetDataSource(context, assetPath) },
                includeDebugCameraLevel = includeDebugCameraLevel,
            )
        }

        fun preferredDemoAsset(context: Context): String? {
            val names =
                runCatching { context.assets.list(ASSET_DEMO_DIR)?.toList().orEmpty() }
                    .getOrDefault(emptyList())
                    .filter { name ->
                        val lower = name.lowercase()
                        lower.endsWith(".mp4") ||
                            lower.endsWith(".mov") ||
                            lower.endsWith(".m4v")
                    }
            if (names.isEmpty()) return null
            return names.firstOrNull { it.equals(PREFERRED_SAMPLE_NAME, ignoreCase = true) }
                ?: names.sorted().first()
        }

        private fun openAssetDataSource(context: Context, assetPath: String): DataSource? =
            try {
                AssetDataSource(context.assets.openFd(assetPath))
            } catch (error: Exception) {
                Log.w(TAG, "cannot open demo asset $assetPath", error)
                null
            }

        private fun selectVideoTrack(extractor: MediaExtractor): Int? {
            for (i in 0 until extractor.trackCount) {
                val mime = extractor.getTrackFormat(i).getString(MediaFormat.KEY_MIME) ?: continue
                if (mime.startsWith("video/")) return i
            }
            return null
        }

        private fun resolveClipFps(format: MediaFormat): Int {
            if (format.containsKey(MediaFormat.KEY_FRAME_RATE)) {
                val rate = format.getInteger(MediaFormat.KEY_FRAME_RATE)
                if (rate in 1..120) return rate
            }
            return DEFAULT_CLIP_FPS
        }

        /**
         * Converts a decoder [Image] (YUV_420_888) to a scaled JPEG. Hardware
         * decode is cheap; this JPEG step is the remaining cost and is still
         * far cheaper than per-frame keyframe seeks.
         */
        private fun imageToJpeg(image: Image, stream: ByteArrayOutputStream): ByteArray? {
            val width = image.width
            val height = image.height
            if (width <= 0 || height <= 0) return null
            val nv21 = yuv420ToNv21(image) ?: return null
            // Optional downscale via YuvImage is awkward; compress full frame
            // then let LiveFeedView's BitmapFactory path handle display scale.
            // For long edge > MAX, subsample by packing a smaller NV21.
            val (outW, outH, outNv21) = scaleNv21IfNeeded(nv21, width, height)
            stream.reset()
            val ok =
                YuvImage(outNv21, ImageFormat.NV21, outW, outH, null)
                    .compressToJpeg(Rect(0, 0, outW, outH), JPEG_QUALITY, stream)
            return if (ok) stream.toByteArray() else null
        }

        private fun scaleNv21IfNeeded(
            nv21: ByteArray,
            width: Int,
            height: Int,
        ): Triple<Int, Int, ByteArray> {
            val longEdge = maxOf(width, height)
            if (longEdge <= MAX_LONG_EDGE) return Triple(width, height, nv21)
            val scale = MAX_LONG_EDGE.toFloat() / longEdge.toFloat()
            val outW = (width * scale).roundToInt().and(1.inv()).coerceAtLeast(2)
            val outH = (height * scale).roundToInt().and(1.inv()).coerceAtLeast(2)
            // Nearest-neighbour scale of Y and interleaved VU — good enough for demo.
            val out = ByteArray(outW * outH + outW * outH / 2)
            var o = 0
            for (y in 0 until outH) {
                val sy = y * height / outH
                val row = sy * width
                for (x in 0 until outW) {
                    val sx = x * width / outW
                    out[o++] = nv21[row + sx]
                }
            }
            val uvOut = outW * outH
            val uvSrc = width * height
            for (y in 0 until outH / 2) {
                val sy = y * height / outH
                val srcRow = uvSrc + sy * width
                val dstRow = uvOut + y * outW
                for (x in 0 until outW / 2) {
                    val sx = x * width / outW
                    val si = srcRow + sx * 2
                    val di = dstRow + x * 2
                    out[di] = nv21[si]
                    out[di + 1] = nv21[si + 1]
                }
            }
            return Triple(outW, outH, out)
        }

        /** Packs YUV_420_888 planes into NV21 (Y + interleaved VU). */
        private fun yuv420ToNv21(image: Image): ByteArray? {
            val width = image.width
            val height = image.height
            val yPlane = image.planes[0]
            val uPlane = image.planes[1]
            val vPlane = image.planes[2]
            val yBuf = yPlane.buffer
            val uBuf = uPlane.buffer
            val vBuf = vPlane.buffer
            val yRowStride = yPlane.rowStride
            val yPixelStride = yPlane.pixelStride
            val uRowStride = uPlane.rowStride
            val uPixelStride = uPlane.pixelStride
            val vRowStride = vPlane.rowStride
            val vPixelStride = vPlane.pixelStride
            val out = ByteArray(width * height + width * height / 2)
            // Y
            var outIndex = 0
            if (yPixelStride == 1 && yRowStride == width) {
                yBuf.position(0)
                yBuf.get(out, 0, width * height)
                outIndex = width * height
            } else {
                val yRow = ByteArray(yRowStride)
                for (row in 0 until height) {
                    yBuf.position(row * yRowStride)
                    yBuf.get(yRow, 0, minOf(yRowStride, yBuf.remaining()))
                    if (yPixelStride == 1) {
                        System.arraycopy(yRow, 0, out, outIndex, width)
                        outIndex += width
                    } else {
                        var col = 0
                        while (col < width) {
                            out[outIndex++] = yRow[col * yPixelStride]
                            col++
                        }
                    }
                }
            }
            // VU interleaved (NV21)
            val chromaHeight = height / 2
            val chromaWidth = width / 2
            for (row in 0 until chromaHeight) {
                val uRowStart = row * uRowStride
                val vRowStart = row * vRowStride
                for (col in 0 until chromaWidth) {
                    val uIndex = uRowStart + col * uPixelStride
                    val vIndex = vRowStart + col * vPixelStride
                    out[outIndex++] = vBuf.get(vIndex)
                    out[outIndex++] = uBuf.get(uIndex)
                }
            }
            return out
        }

        private fun demoTimecode(frameIndex: Long, fps: Int): LiveFrameTimecode {
            val seconds = frameIndex / fps
            return LiveFrameTimecode(
                on = true,
                hour = (seconds / 3_600 % 24).toInt(),
                minute = (seconds / 60 % 60).toInt(),
                second = (seconds % 60).toInt(),
                frame = (frameIndex % fps).toInt(),
            )
        }
    }

    /** Opaque input for MediaExtractor (file path or asset FD). */
    interface DataSource {
        fun applyTo(extractor: MediaExtractor)
        fun close()
    }

    private class FileDataSource(private val path: String) : DataSource {
        override fun applyTo(extractor: MediaExtractor) {
            extractor.setDataSource(path)
        }

        override fun close() = Unit
    }

    private class AssetDataSource(private val afd: AssetFileDescriptor) : DataSource {
        override fun applyTo(extractor: MediaExtractor) {
            extractor.setDataSource(afd.fileDescriptor, afd.startOffset, afd.length)
        }

        override fun close() {
            runCatching { afd.close() }
        }
    }
}

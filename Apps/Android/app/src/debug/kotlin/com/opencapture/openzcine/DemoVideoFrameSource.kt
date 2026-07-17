package com.opencapture.openzcine

import android.content.Context
import android.content.res.AssetFileDescriptor
import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.util.Log
import com.opencapture.openzcine.core.LiveFrame
import com.opencapture.openzcine.core.LiveFrameSource
import com.opencapture.openzcine.core.LiveFrameTimecode
import java.io.ByteArrayOutputStream
import java.io.File
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOn

/**
 * Debug-only [LiveFrameSource] that loops JPEG frames extracted from a local
 * sample video (gitignored `samples/` clips staged into debug assets, or an
 * explicit on-device path via `zc.demo.video`). [DemoHarness] falls back to
 * the synthetic colour-bar feed when nothing is readable.
 *
 * The sample never ships in release; it stays outside the committed tree.
 */
class DemoVideoFrameSource(
    private val openSession: () -> ExtractionSession?,
    @Suppress("UNUSED_PARAMETER")
    private val includeDebugCameraLevel: Boolean = true,
    private val framesPerSecond: Int = DEFAULT_FPS,
    private val maxFrames: Int = MAX_EXTRACTED_FRAMES,
) : LiveFrameSource {
    override val frames: Flow<LiveFrame> =
        flow {
            val loop = extractJpegLoop()
            if (loop.isEmpty()) {
                Log.w(TAG, "sample video produced no frames — demo feed will fall back")
                return@flow
            }
            Log.i(TAG, "demo video loop ready (${loop.size} frames @ ${framesPerSecond} fps)")
            val periodNanos = 1_000_000_000L / framesPerSecond
            val startNanos = System.nanoTime()
            var frameIndex = 0L
            while (true) {
                val jpeg = loop[(frameIndex % loop.size).toInt()]
                emit(
                    LiveFrame(
                        timestampNanos = System.nanoTime(),
                        jpegData = jpeg,
                        // Keep synthetic audio/AF/level off the pure sample path.
                        audioLevels = null,
                        focus = null,
                        level = null,
                        timecode = demoTimecode(frameIndex, framesPerSecond),
                        measuredFramesPerSecond = framesPerSecond.toDouble(),
                    ),
                )
                frameIndex++
                val dueNanos = startNanos + frameIndex * periodNanos
                val waitMillis = (dueNanos - System.nanoTime()) / 1_000_000
                if (waitMillis > 0) delay(waitMillis)
            }
        }
            .flowOn(Dispatchers.Default)

    private fun extractJpegLoop(): List<ByteArray> {
        val session = openSession() ?: return emptyList()
        return try {
            val retriever = session.retriever
            val durationMs =
                retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
                    ?.toLongOrNull()
                    ?.coerceAtLeast(1L)
                    ?: return emptyList()
            val reportedFps =
                retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_CAPTURE_FRAMERATE)
                    ?.toFloatOrNull()
                    ?.takeIf { it >= 1f }
            val fps = reportedFps?.toInt() ?: framesPerSecond
            val naturalCount = ((durationMs / 1000.0) * fps).toInt().coerceAtLeast(1)
            val count = naturalCount.coerceAtMost(maxFrames)
            val stepUs = (durationMs * 1000L) / count
            val out = ArrayList<ByteArray>(count)
            val stream = ByteArrayOutputStream()
            for (index in 0 until count) {
                val bitmap =
                    retriever.getFrameAtTime(
                        index * stepUs,
                        MediaMetadataRetriever.OPTION_CLOSEST,
                    )
                        ?: continue
                val scaled = scaleForDemo(bitmap)
                if (scaled !== bitmap) bitmap.recycle()
                stream.reset()
                scaled.compress(Bitmap.CompressFormat.JPEG, 82, stream)
                scaled.recycle()
                out += stream.toByteArray()
            }
            out
        } catch (error: RuntimeException) {
            Log.w(TAG, "failed to extract demo video frames", error)
            emptyList()
        } finally {
            session.close()
        }
    }

    private fun scaleForDemo(source: Bitmap): Bitmap {
        val longEdge = maxOf(source.width, source.height)
        if (longEdge <= MAX_LONG_EDGE) return source
        val scale = MAX_LONG_EDGE.toFloat() / longEdge.toFloat()
        val width = (source.width * scale).toInt().coerceAtLeast(1)
        val height = (source.height * scale).toInt().coerceAtLeast(1)
        return Bitmap.createScaledBitmap(source, width, height, true)
    }

    /** Owns a [MediaMetadataRetriever] and any asset FD it still needs. */
    class ExtractionSession(
        val retriever: MediaMetadataRetriever,
        private val assetFd: AssetFileDescriptor? = null,
    ) {
        fun close() {
            runCatching { retriever.release() }
            runCatching { assetFd?.close() }
        }
    }

    companion object {
        private const val TAG = "DemoVideoFrameSource"
        private const val DEFAULT_FPS = 25
        private const val MAX_EXTRACTED_FRAMES = 150
        private const val MAX_LONG_EDGE = 1280
        private const val ASSET_DEMO_DIR = "demo"

        /** Preferred sample name when several files exist under samples/assets. */
        const val PREFERRED_SAMPLE_NAME = "A002_C057_0704BT.MP4"

        /**
         * Builds a video frame source from (in order): explicit path, staged
         * debug assets under `demo/`, or `null` when nothing is readable.
         */
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
                        openSession = {
                            try {
                                ExtractionSession(
                                    MediaMetadataRetriever().also { it.setDataSource(path) },
                                )
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
                openSession = { openAssetSession(context, assetPath) },
                includeDebugCameraLevel = includeDebugCameraLevel,
            )
        }

        /** Lists files under the debug demo asset folder; prefers [PREFERRED_SAMPLE_NAME]. */
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

        private fun openAssetSession(
            context: Context,
            assetPath: String,
        ): ExtractionSession? =
            try {
                val afd = context.assets.openFd(assetPath)
                val retriever =
                    MediaMetadataRetriever().also {
                        it.setDataSource(afd.fileDescriptor, afd.startOffset, afd.length)
                    }
                ExtractionSession(retriever, afd)
            } catch (error: Exception) {
                Log.w(TAG, "cannot open demo asset $assetPath", error)
                null
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
}

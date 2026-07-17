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
import kotlinx.coroutines.isActive
import kotlin.coroutines.coroutineContext

/**
 * Debug-only [LiveFrameSource] that loops a local sample video (gitignored
 * `samples/` clips staged into debug assets, or `zc.demo.video` path).
 *
 * Strategy (tuned for low-end devices like SM-A12):
 * 1. Decode a modest set of evenly spaced frames with
 *    [MediaMetadataRetriever] (first frame first so the feed is never blank).
 * 2. Once the loop buffer is full, replay it at a steady rate with no further
 *    seeks — smooth looping without real-time MediaCodec complexity.
 *
 * The sample never ships in release; it stays outside the committed tree.
 */
class DemoVideoFrameSource(
    private val openSession: () -> ExtractionSession?,
    @Suppress("UNUSED_PARAMETER")
    private val includeDebugCameraLevel: Boolean = true,
    private val playbackFps: Int = PLAYBACK_FPS,
) : LiveFrameSource {
    override val frames: Flow<LiveFrame> =
        flow {
            val session = openSession()
            if (session == null) {
                Log.w(TAG, "sample video could not be opened")
                return@flow
            }
            val loop = ArrayList<ByteArray>(MAX_LOOP_FRAMES)
            try {
                val retriever = session.retriever
                val durationMs =
                    retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
                        ?.toLongOrNull()
                        ?.coerceAtLeast(1L)
                if (durationMs == null) {
                    Log.w(TAG, "sample video has no duration metadata")
                    return@flow
                }
                val sampleCount =
                    ((durationMs / 1000.0) * SAMPLE_FPS)
                        .toInt()
                        .coerceIn(MIN_LOOP_FRAMES, MAX_LOOP_FRAMES)
                val stepUs = (durationMs * 1_000L) / sampleCount
                Log.i(
                    TAG,
                    "demo video extracting $sampleCount frames from ${durationMs}ms clip",
                )
                val stream = ByteArrayOutputStream()
                // Phase 1: extract and emit as we go so the first frame appears ASAP.
                for (index in 0 until sampleCount) {
                    if (!coroutineContext.isActive) return@flow
                    val timeUs = index * stepUs
                    val bitmap =
                        retriever.getFrameAtTime(
                            timeUs,
                            MediaMetadataRetriever.OPTION_CLOSEST,
                        )
                    if (bitmap == null) {
                        Log.w(TAG, "null frame at ${timeUs}us — skipping")
                        continue
                    }
                    val jpeg = jpegBytes(bitmap, stream)
                    loop += jpeg
                    emit(
                        LiveFrame(
                            timestampNanos = System.nanoTime(),
                            jpegData = jpeg,
                            audioLevels = null,
                            focus = null,
                            level = null,
                            timecode = demoTimecode(index.toLong(), SAMPLE_FPS),
                            measuredFramesPerSecond = SAMPLE_FPS.toDouble(),
                        ),
                    )
                    // Yield so the UI can present the first frames while we keep decoding.
                    delay(0)
                }
            } catch (error: RuntimeException) {
                Log.w(TAG, "demo video extract failed", error)
            } finally {
                session.close()
            }

            if (loop.isEmpty()) {
                Log.w(TAG, "sample video produced no frames")
                return@flow
            }
            Log.i(TAG, "demo video loop ready (${loop.size} frames @ ${playbackFps} fps)")
            // Phase 2: smooth in-memory loop — no more seeks.
            val periodNanos = 1_000_000_000L / playbackFps
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
                        timecode = demoTimecode(frameIndex, playbackFps),
                        measuredFramesPerSecond = playbackFps.toDouble(),
                    ),
                )
                frameIndex++
                val dueNanos = startNanos + frameIndex * periodNanos
                val waitMillis = (dueNanos - System.nanoTime()) / 1_000_000
                if (waitMillis > 0) delay(waitMillis)
            }
        }
            .flowOn(Dispatchers.Default)

    private fun jpegBytes(source: Bitmap, stream: ByteArrayOutputStream): ByteArray {
        val scaled = scaleForDemo(source)
        if (scaled !== source) source.recycle()
        stream.reset()
        scaled.compress(Bitmap.CompressFormat.JPEG, 80, stream)
        scaled.recycle()
        return stream.toByteArray()
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
        /** Frames sampled during the initial extract pass (motion preview). */
        private const val SAMPLE_FPS = 8
        /** Steady loop rate after the buffer is full. */
        private const val PLAYBACK_FPS = 12
        private const val MIN_LOOP_FRAMES = 8
        private const val MAX_LOOP_FRAMES = 48
        private const val MAX_LONG_EDGE = 960
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

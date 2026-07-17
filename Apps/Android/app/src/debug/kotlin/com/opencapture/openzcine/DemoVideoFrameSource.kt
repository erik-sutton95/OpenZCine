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
 * Strategy:
 * 1. Read the clip's native frame rate (falls back to 25 when metadata is
 *    missing — matches the A002 sample and typical cinema proxies).
 * 2. Decode one JPEG per clip frame with [MediaMetadataRetriever], emitting
 *    each as it lands so the feed is never blank during the first pass.
 * 3. Once the buffer is full, replay it in memory at the clip fps — no further
 *    seeks, so the steady loop can hold true 25 fps even on low-end devices.
 *
 * The sample never ships in release; it stays outside the committed tree.
 */
class DemoVideoFrameSource(
    private val openSession: () -> ExtractionSession?,
    @Suppress("UNUSED_PARAMETER")
    private val includeDebugCameraLevel: Boolean = true,
) : LiveFrameSource {
    override val frames: Flow<LiveFrame> =
        flow {
            val session = openSession()
            if (session == null) {
                Log.w(TAG, "sample video could not be opened")
                return@flow
            }
            val loop = ArrayList<ByteArray>(MAX_LOOP_FRAMES)
            var clipFps = DEFAULT_CLIP_FPS
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
                clipFps = resolveClipFps(retriever)
                val sampleCount =
                    ((durationMs / 1000.0) * clipFps)
                        .toInt()
                        .coerceIn(MIN_LOOP_FRAMES, MAX_LOOP_FRAMES)
                // One sample per clip frame period so the loop preserves
                // native cadence (e.g. 25 fps for a 25 fps clip).
                val stepUs = 1_000_000L / clipFps
                Log.i(
                    TAG,
                    "demo video extracting $sampleCount frames " +
                        "from ${durationMs}ms clip @ ${clipFps} fps",
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
                            // During extract, delivery rate is decode-bound;
                            // report the target clip fps for chrome consistency.
                            timecode = demoTimecode(index.toLong(), clipFps),
                            measuredFramesPerSecond = clipFps.toDouble(),
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
            Log.i(TAG, "demo video loop ready (${loop.size} frames @ ${clipFps} fps)")
            // Phase 2: smooth in-memory loop at the clip's native frame rate.
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
        /** Fallback when the container does not report a capture frame rate. */
        private const val DEFAULT_CLIP_FPS = 25
        private const val MIN_LOOP_FRAMES = 8
        /** ~6s @ 25 fps with headroom for slightly longer samples. */
        private const val MAX_LOOP_FRAMES = 180
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

        /**
         * Prefers the file's reported capture frame rate, then falls back to
         * 25 (cinema-proxy default matching the A002 sample).
         */
        private fun resolveClipFps(retriever: MediaMetadataRetriever): Int {
            val reported =
                retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_CAPTURE_FRAMERATE)
                    ?.toFloatOrNull()
                    ?.takeIf { it in 1f..120f }
            if (reported != null) return reported.toInt().coerceAtLeast(1)
            return DEFAULT_CLIP_FPS
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

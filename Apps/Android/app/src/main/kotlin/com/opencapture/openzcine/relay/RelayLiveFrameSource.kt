package com.opencapture.openzcine.relay

import android.graphics.ImageFormat
import android.graphics.Rect
import android.graphics.YuvImage
import android.media.MediaCodec
import android.media.MediaFormat
import com.opencapture.openzcine.core.LiveCameraLevel
import com.opencapture.openzcine.core.LiveFocusBox
import com.opencapture.openzcine.core.LiveFocusInfo
import com.opencapture.openzcine.core.LiveFocusResult
import com.opencapture.openzcine.core.LiveFrame
import com.opencapture.openzcine.core.LiveFrameSource
import com.opencapture.openzcine.core.LiveFrameTimecode
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow

/**
 * Turns relayed frames into the [LiveFrameSource] the monitor already renders — scopes, LUTs and
 * peaking all run on the relayed picture, exactly like the iOS watcher. JPEG frames pass through
 * byte-for-byte; HEVC frames (an iOS broadcaster's normal output) decode through MediaCodec and
 * re-emerge as JPEG for the shared frame pipeline.
 */
class RelayLiveFrameSource : LiveFrameSource {
    private val mutableFrames =
        MutableSharedFlow<LiveFrame>(replay = 1, extraBufferCapacity = 2)
    override val frames: Flow<LiveFrame> = mutableFrames

    private val hevc = HevcFrameDecoder()
    private var lastTimestampNanos: Long = 0
    private var measuredFPS: Double? = null

    /** Feeds one relayed frame; decodes off the caller's thread requirements (call on IO). */
    fun submit(metadata: MonitorRelayWire.FrameMetadata, image: ByteArray) {
        val jpeg =
            when (metadata.codec) {
                MonitorRelayWire.FrameCodec.JPEG -> image
                MonitorRelayWire.FrameCodec.HEVC ->
                    hevc.decodeToJpeg(image, metadata.isKeyframe, metadata.parameterSets)
                        ?: return
                else -> return
            }
        val now = System.nanoTime()
        if (lastTimestampNanos > 0) {
            val delta = (now - lastTimestampNanos) / 1_000_000_000.0
            if (delta > 0.0001) {
                val instantaneous = 1.0 / delta
                // Same smoothing stance as the camera source: steady readout, honest trend.
                measuredFPS =
                    measuredFPS?.let { it * 0.8 + instantaneous * 0.2 } ?: instantaneous
            }
        }
        lastTimestampNanos = now
        mutableFrames.tryEmit(
            LiveFrame(
                timestampNanos = now,
                jpegData = jpeg,
                isRecording = metadata.isRecording,
                // Wire sound levels are the host's raw meter steps; the shared dBFS mapping
                // lives host-side, so a watcher without it hides the meters — the iOS
                // watcher's behavior when a header carries no sound indicator.
                audioLevels = null,
                focus =
                    metadata.focus?.let { focus ->
                        LiveFocusInfo(
                            coordinateWidth = focus.coordinateWidth,
                            coordinateHeight = focus.coordinateHeight,
                            result =
                                when (focus.focusResult) {
                                    1 -> LiveFocusResult.NOT_FOCUSED
                                    2 -> LiveFocusResult.FOCUSED
                                    else -> LiveFocusResult.UNKNOWN
                                },
                            subjectDetectionActive = focus.subjectDetectionActive,
                            trackingAFActive = focus.trackingAFActive,
                            selectedBoxIndex = focus.selectedBoxIndex,
                            boxes =
                                focus.boxes.map {
                                    LiveFocusBox(it.centerX, it.centerY, it.width, it.height)
                                },
                        )
                    },
                level =
                    if (metadata.levelRoll != null && metadata.levelPitch != null) {
                        LiveCameraLevel(
                            rollDegrees = metadata.levelRoll,
                            pitchDegrees = metadata.levelPitch,
                            yawDegrees = 0.0,
                        )
                    } else {
                        null
                    },
                timecode =
                    metadata.timecode?.let {
                        LiveFrameTimecode(it.on, it.hour, it.minute, it.second, it.frame)
                    },
                measuredFramesPerSecond = measuredFPS,
            )
        )
    }

    fun release() {
        hevc.release()
    }
}

/**
 * Synchronous MediaCodec HEVC decode to JPEG. The iOS encoder ships hvcC-style frames — every
 * NAL prefixed with a 4-byte big-endian length, parameter sets carried separately on keyframes —
 * while MediaCodec wants Annex-B start codes, so both convert here.
 */
internal class HevcFrameDecoder {
    private var codec: MediaCodec? = null
    private var configuredCsd: ByteArray? = null

    fun decodeToJpeg(
        frame: ByteArray,
        isKeyframe: Boolean,
        parameterSets: List<ByteArray>?,
    ): ByteArray? {
        val csd = parameterSets?.takeIf(List<ByteArray>::isNotEmpty)?.let(::annexBParameterSets)
        val active =
            try {
                ensureCodec(csd)
            } catch (_: Exception) {
                return null
            } ?: return null
        // A rebuilt decoder waits on a keyframe; predicted frames would smear.
        if (awaitingKeyframe) {
            if (!isKeyframe) return null
            awaitingKeyframe = false
        }
        return try {
            // Feed and drain are DECOUPLED: a hardware decoder holds several frames of
            // pipeline depth, so demanding output for the input just queued starves it —
            // the first outputs only appear a few frames in, then track the input rate.
            val annexB = annexBFrame(frame)
            val inputIndex = active.dequeueInputBuffer(INPUT_TIMEOUT_MICROS)
            if (inputIndex >= 0) {
                fed += 1
                active.getInputBuffer(inputIndex)?.apply {
                    clear()
                    put(annexB)
                    // Monotonic PTS: several hardware decoders silently hold or drop frames
                    // whose timestamps never advance, which presents as a black feed with no
                    // error anywhere.
                    presentationMicros += FRAME_STEP_MICROS
                    active.queueInputBuffer(inputIndex, 0, annexB.size, presentationMicros, 0)
                }
            }
            var jpeg = drainNewestJpeg(active)
            submitted += 1
            if (jpeg != null) {
                decoded += 1
                fedSinceOutput = 0
            } else {
                fedSinceOutput += 1
                // A hardware decoder that consumes valid frames without EVER producing output
                // is rejecting the stream silently — the iOS broadcaster encodes HEVC Main10,
                // which low-end hardware decoders drop without an error. The platform software
                // decoder handles Main10; switch once, deterministically.
                if (!usingSoftwareDecoder && fedSinceOutput > SOFTWARE_FALLBACK_FED_FRAMES) {
                    android.util.Log.w(
                        "RelayHEVC",
                        "no output after $fedSinceOutput frames; switching to software decoder",
                    )
                    usingSoftwareDecoder = true
                    release()
                    fedSinceOutput = 0
                    jpeg = null
                }
            }
            if (submitted % 50 == 1) {
                val head =
                    frame.take(8).joinToString(" ") { String.format("%02X", it) }
                android.util.Log.i(
                    "RelayHEVC",
                    "submitted=$submitted decoded=$decoded fed=$fed key=$isKeyframe " +
                        "bytes=${frame.size} head=[$head]",
                )
            }
            jpeg
        } catch (error: Exception) {
            // The reference chain broke (skip, resize, mid-stream join): rebuild on the next
            // keyframe's parameter sets rather than smearing. Logged like the iOS decoder's
            // failure path — a silent black feed is undiagnosable in the field.
            android.util.Log.w("RelayHEVC", "decode failed; rebuilding on next keyframe", error)
            release()
            null
        }
    }

    private var awaitingKeyframe = false
    private var presentationMicros = 0L
    private var submitted = 0
    private var fed = 0
    private var fedSinceOutput = 0
    private var usingSoftwareDecoder = false
    private var decoded = 0

    private fun ensureCodec(csd: ByteArray?): MediaCodec? {
        val current = codec
        if (current != null && (csd == null || csd.contentEquals(configuredCsd))) {
            return current
        }
        release()
        val newCsd = csd ?: return null
        val format =
            MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_HEVC, 1920, 1080).apply {
                setByteBuffer("csd-0", ByteBuffer.wrap(newCsd))
                // No forced color format: a Main10 stream decodes to P010 on the software
                // path, and requesting 8-bit flexible put the codec straight into the error
                // state. The plane converter below handles both sample widths.
            }
        val created =
            if (usingSoftwareDecoder) {
                MediaCodec.createByCodecName(SOFTWARE_DECODER_NAME)
            } else {
                MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_VIDEO_HEVC)
            }
        created.configure(format, null, null, 0)
        created.start()
        android.util.Log.i(
            "RelayHEVC",
            "decoder configured (${created.name}, csd ${newCsd.size} bytes)",
        )
        codec = created
        configuredCsd = newCsd
        awaitingKeyframe = true
        return created
    }

    /** Drains every ready output, converting only the NEWEST to JPEG — a monitor's discipline. */
    private fun drainNewestJpeg(active: MediaCodec): ByteArray? {
        val info = MediaCodec.BufferInfo()
        var newest = -1
        var timeoutMicros = DRAIN_TIMEOUT_MICROS
        while (true) {
            val outputIndex = active.dequeueOutputBuffer(info, timeoutMicros)
            timeoutMicros = 0
            when {
                outputIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> continue
                outputIndex >= 0 -> {
                    if (newest >= 0) active.releaseOutputBuffer(newest, false)
                    newest = outputIndex
                }
                else -> break
            }
        }
        if (newest < 0) return null
        val image = active.getOutputImage(newest)
        val jpeg =
            image?.let {
                val nv21 = yuv420ToNv21(it)
                val out = ByteArrayOutputStream()
                YuvImage(nv21, ImageFormat.NV21, it.width, it.height, null)
                    .compressToJpeg(Rect(0, 0, it.width, it.height), JPEG_QUALITY, out)
                out.toByteArray()
            }
        image?.close()
        active.releaseOutputBuffer(newest, false)
        return jpeg
    }

    fun release() {
        runCatching {
            codec?.stop()
            codec?.release()
        }
        codec = null
        configuredCsd = null
    }

    private companion object {
        const val INPUT_TIMEOUT_MICROS = 20_000L
        const val DRAIN_TIMEOUT_MICROS = 12_000L
        const val FRAME_STEP_MICROS = 40_000L
        const val SOFTWARE_FALLBACK_FED_FRAMES = 75
        const val SOFTWARE_DECODER_NAME = "c2.android.hevc.decoder"
        const val JPEG_QUALITY = 88

        val START_CODE = byteArrayOf(0x00, 0x00, 0x00, 0x01)

        fun annexBParameterSets(sets: List<ByteArray>): ByteArray {
            val out = ByteArrayOutputStream()
            sets.forEach {
                out.write(START_CODE)
                out.write(it)
            }
            return out.toByteArray()
        }

        /** 4-byte-length-prefixed NALs → Annex-B start codes. */
        fun annexBFrame(frame: ByteArray): ByteArray {
            val out = ByteArrayOutputStream(frame.size + 16)
            var offset = 0
            while (offset + 4 <= frame.size) {
                val length = MonitorRelayWire.readUInt32BE(frame, offset)
                offset += 4
                if (length <= 0 || offset + length > frame.size) break
                out.write(START_CODE)
                out.write(frame, offset, length)
                offset += length
            }
            return out.toByteArray()
        }

        fun yuv420ToNv21(image: android.media.Image): ByteArray {
            val width = image.width
            val height = image.height
            val out = ByteArray(width * height * 3 / 2)
            val y = image.planes[0]
            val u = image.planes[1]
            val v = image.planes[2]
            // 16-bit little-endian planes (P010, the Main10 output): the top 8 of the 10
            // significant bits live in the HIGH byte. 8-bit planes read at the sample itself.
            val yWide = y.pixelStride >= 2
            val yHigh = if (yWide) 1 else 0
            var position = 0
            val yBuffer = y.buffer
            for (row in 0 until height) {
                val base = row * y.rowStride
                for (col in 0 until width) {
                    out[position++] = yBuffer.get(base + col * y.pixelStride + yHigh)
                }
            }
            val uWide = u.pixelStride >= 2 && v.pixelStride >= 2 && yWide
            val cHigh = if (uWide) 1 else 0
            val uBuffer = u.buffer
            val vBuffer = v.buffer
            for (row in 0 until height / 2) {
                val uBase = row * u.rowStride
                val vBase = row * v.rowStride
                for (col in 0 until width / 2) {
                    out[position++] = vBuffer.get(vBase + col * v.pixelStride + cHigh)
                    out[position++] = uBuffer.get(uBase + col * u.pixelStride + cHigh)
                }
            }
            return out
        }
    }
}

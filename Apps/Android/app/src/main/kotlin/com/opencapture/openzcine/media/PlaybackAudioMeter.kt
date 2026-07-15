@file:androidx.media3.common.util.UnstableApi

package com.opencapture.openzcine.media

import android.content.Context
import android.os.SystemClock
import androidx.media3.common.C
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.audio.BaseAudioProcessor
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.audio.AudioSink
import androidx.media3.exoplayer.audio.DefaultAudioSink
import com.opencapture.openzcine.bridge.SwiftCore
import com.opencapture.openzcine.core.LiveAudioMeterChannel
import com.opencapture.openzcine.core.LiveAudioMeterLevels
import java.nio.ByteBuffer
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlin.math.abs
import kotlin.math.max

private const val PLAYBACK_AUDIO_METER_POLL_MILLIS = 42L
private const val PLAYBACK_AUDIO_METER_WIRE_SIZE = 6

/** Loudest decoded linear samples accumulated since the previous meter poll. */
internal data class DecodedPlaybackAudioPeaks(
    val left: Float,
    val right: Float,
)

/**
 * Media3 PCM processor that observes decoded playback audio without changing its bytes.
 *
 * [DefaultAudioSink] converts integer PCM to 16-bit before custom processors when float output is
 * disabled. Channel zero feeds left, channel one feeds right, mono is mirrored, and additional
 * channels are passed through but intentionally ignored to match the iOS playback tap. Peak
 * accumulation is lock-guarded across Media3's audio thread and the Compose polling coroutine.
 * Because this processor runs before the sink applies `Player.volume`, muted playback remains
 * metered while output bytes and the caller's audio-focus policy stay untouched.
 */
internal class DecodedPlaybackAudioProcessor : BaseAudioProcessor() {
    private val peakLock = Any()
    private var leftPeak = 0f
    private var rightPeak = 0f

    override fun onConfigure(inputAudioFormat: AudioProcessor.AudioFormat): AudioProcessor.AudioFormat {
        if (inputAudioFormat.encoding != C.ENCODING_PCM_16BIT || inputAudioFormat.channelCount < 1) {
            throw AudioProcessor.UnhandledAudioFormatException(inputAudioFormat)
        }
        return inputAudioFormat
    }

    override fun queueInput(inputBuffer: ByteBuffer) {
        check(inputAudioFormat != AudioProcessor.AudioFormat.NOT_SET) {
            "Audio processor must be configured and flushed before queueInput."
        }
        if (!inputBuffer.hasRemaining()) return

        val channelCount = inputAudioFormat.channelCount
        val frameSize = inputAudioFormat.bytesPerFrame
        var frameOffset = inputBuffer.position()
        var observedLeft = 0f
        var observedRight = 0f
        while (frameOffset + frameSize <= inputBuffer.limit()) {
            val left = linearMagnitude(inputBuffer.getShort(frameOffset))
            val right =
                if (channelCount > 1) {
                    linearMagnitude(inputBuffer.getShort(frameOffset + Short.SIZE_BYTES))
                } else {
                    left
                }
            observedLeft = max(observedLeft, left)
            observedRight = max(observedRight, right)
            frameOffset += frameSize
        }
        synchronized(peakLock) {
            leftPeak = max(leftPeak, observedLeft)
            rightPeak = max(rightPeak, observedRight)
        }

        val outputBuffer = replaceOutputBuffer(inputBuffer.remaining())
        outputBuffer.put(inputBuffer)
        outputBuffer.flip()
    }

    /** Returns and clears the loudest samples observed since the preceding drain. */
    fun drainPeaks(): DecodedPlaybackAudioPeaks =
        synchronized(peakLock) {
            DecodedPlaybackAudioPeaks(leftPeak, rightPeak).also {
                leftPeak = 0f
                rightPeak = 0f
            }
        }

    override fun onFlush(streamMetadata: AudioProcessor.StreamMetadata) {
        clearPeaks()
    }

    override fun onReset() {
        clearPeaks()
    }

    private fun clearPeaks() {
        synchronized(peakLock) {
            leftPeak = 0f
            rightPeak = 0f
        }
    }

    private fun linearMagnitude(sample: Short): Float = abs(sample.toInt()) / 32_768f
}

/**
 * Media3 renderer factory that inserts [audioProcessor] into decoded PCM playback.
 *
 * Pass this factory to `ExoPlayer.Builder(context, factory)`, then retain the caller's existing
 * `setAudioAttributes(..., handleAudioFocus = true)` and `player.volume` mute handling. Float
 * output is deliberately disabled because Media3 bypasses audio processing on that path.
 */
@Suppress("UNUSED_PARAMETER")
internal class PlaybackAudioMeterRenderersFactory(
    context: Context,
    private val audioProcessor: DecodedPlaybackAudioProcessor,
) : DefaultRenderersFactory(context) {
    override fun buildAudioSink(
        context: Context,
        enableFloatOutput: Boolean,
        enableAudioOutputPlaybackParams: Boolean,
    ): AudioSink =
        DefaultAudioSink.Builder(context)
            .setEnableFloatOutput(false)
            .setEnableAudioOutputPlaybackParameters(enableAudioOutputPlaybackParams)
            .setAudioProcessors(arrayOf<AudioProcessor>(audioProcessor))
            .build()
}

/** Small injectable boundary around the Swift JNI ballistics function. */
internal fun interface PlaybackAudioMeterStepper {
    fun step(
        previousPayload: FloatArray,
        leftPeakLinear: Float,
        rightPeakLinear: Float,
        deltaTimeSeconds: Float,
    ): FloatArray?
}

private object SwiftPlaybackAudioMeterStepper : PlaybackAudioMeterStepper {
    override fun step(
        previousPayload: FloatArray,
        leftPeakLinear: Float,
        rightPeakLinear: Float,
        deltaTimeSeconds: Float,
    ): FloatArray? =
        if (SwiftCore.isAvailable) {
            SwiftCore.playbackAudioMeterStep(
                previousPayload,
                leftPeakLinear,
                rightPeakLinear,
                deltaTimeSeconds,
            )
        } else {
            null
        }
}

/** Validated native state plus the presentation type already consumed by Android audio panels. */
internal class PlaybackAudioMeterWire private constructor(
    val payload: FloatArray,
    val levels: LiveAudioMeterLevels,
) {
    companion object {
        /** Fails closed when native code returns a truncated, non-finite, or impossible payload. */
        fun parse(payload: FloatArray?): PlaybackAudioMeterWire? {
            if (payload == null || payload.size != PLAYBACK_AUDIO_METER_WIRE_SIZE) return null
            if (payload.any { !it.isFinite() }) return null
            if (!validChannel(payload[0], payload[1], payload[2])) return null
            if (!validChannel(payload[3], payload[4], payload[5])) return null
            return PlaybackAudioMeterWire(
                payload = payload.copyOf(),
                levels =
                    LiveAudioMeterLevels(
                        left =
                            LiveAudioMeterChannel(
                                levelDb = payload[0].toDouble(),
                                peakDb = payload[1].toDouble(),
                            ),
                        right =
                            LiveAudioMeterChannel(
                                levelDb = payload[3].toDouble(),
                                peakDb = payload[4].toDouble(),
                            ),
                    ),
            )
        }

        private fun validChannel(levelDb: Float, peakDb: Float, peakAge: Float): Boolean =
            levelDb <= 0f && peakDb in levelDb..0f && peakAge >= 0f
    }
}

/**
 * Coordinates decoded peak drains with Swift-owned meter ballistics at iOS's 42 ms cadence.
 *
 * Compose can collect [levels] while a `LaunchedEffect` runs [poll]. The processor remains in the
 * player's sink for its lifetime, but starting a polling session discards any unobserved stale
 * peak. Cancelling the session clears the published value. Only one polling coroutine may run.
 */
internal class PlaybackAudioMeterCoordinator(
    val audioProcessor: DecodedPlaybackAudioProcessor = DecodedPlaybackAudioProcessor(),
    private val stepper: PlaybackAudioMeterStepper = SwiftPlaybackAudioMeterStepper,
    private val monotonicNanos: () -> Long = SystemClock::elapsedRealtimeNanos,
    private val pollIntervalMillis: Long = PLAYBACK_AUDIO_METER_POLL_MILLIS,
) {
    private val polling = AtomicBoolean(false)
    private val mutableLevels = MutableStateFlow<LiveAudioMeterLevels?>(null)

    init {
        require(pollIntervalMillis > 0L) { "pollIntervalMillis must be positive." }
    }

    /** Latest Swift-resolved levels, or null before polling and after a malformed native result. */
    val levels: StateFlow<LiveAudioMeterLevels?> = mutableLevels.asStateFlow()

    /** Creates the renderer factory that must be supplied when the playback player is built. */
    fun renderersFactory(context: Context): PlaybackAudioMeterRenderersFactory =
        PlaybackAudioMeterRenderersFactory(context, audioProcessor)

    /** Polls until cancellation, publishing only validated shared-core meter values. */
    suspend fun poll() {
        check(polling.compareAndSet(false, true)) { "Playback audio meter is already polling." }
        audioProcessor.drainPeaks()
        var previousPayload = FloatArray(0)
        var lastTickNanos = monotonicNanos()
        try {
            while (true) {
                delay(pollIntervalMillis)
                val nowNanos = monotonicNanos()
                val elapsedNanos = (nowNanos - lastTickNanos).coerceAtLeast(0L)
                lastTickNanos = nowNanos
                val peaks = audioProcessor.drainPeaks()
                val payload =
                    stepper.step(
                        previousPayload = previousPayload,
                        leftPeakLinear = peaks.left,
                        rightPeakLinear = peaks.right,
                        deltaTimeSeconds = elapsedNanos / 1_000_000_000f,
                    )
                val wire = PlaybackAudioMeterWire.parse(payload)
                previousPayload = wire?.payload ?: FloatArray(0)
                mutableLevels.value = wire?.levels
            }
        } finally {
            audioProcessor.drainPeaks()
            mutableLevels.value = null
            polling.set(false)
        }
    }
}

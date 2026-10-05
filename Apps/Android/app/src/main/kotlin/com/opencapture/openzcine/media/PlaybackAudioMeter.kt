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
import com.opencapture.opencine.runtime.MonitorAudioPeakAccumulator
import com.opencapture.opencine.runtime.MonitorAudioPeakSample
import com.opencapture.opencine.runtime.MonitorPcmAudioInput
import com.opencapture.opencine.runtime.MonitorPcmFormat
import com.opencapture.opencine.runtime.MonitorPcmSampleType
import com.opencapture.opencine.nikon.LiveAudioMeterChannel
import com.opencapture.opencine.nikon.LiveAudioMeterLevels
import java.nio.ByteBuffer
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

private const val PLAYBACK_AUDIO_METER_POLL_MILLIS = 42L
private const val PLAYBACK_AUDIO_METER_WIRE_SIZE = 6

/** A drained measurement with the actual prepared native input that admitted it. */
internal class DecodedPlaybackAudioTicket(
    val sample: MonitorAudioPeakSample,
    internal val input: MonitorPcmAudioInput,
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
    private val peaks = MonitorAudioPeakAccumulator()
    private val sourceLock = Any()
    @Volatile private var input: MonitorPcmAudioInput? = null
    @Volatile private var closed = false

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
        // Sampling observes complete frames without moving the Media3 input position.
        input?.ingest(inputBuffer)
        val outputBuffer = replaceOutputBuffer(inputBuffer.remaining())
        outputBuffer.put(inputBuffer)
        outputBuffer.flip()
    }

    /** Capture the actual input identity and its measurement in one short native-source lock. */
    fun drainTicket(): DecodedPlaybackAudioTicket? = synchronized(sourceLock) {
        val current = input ?: return@synchronized null
        val sample = peaks.sampleAndReset() ?: return@synchronized null
        DecodedPlaybackAudioTicket(sample, current)
    }

    /** Retired work cannot publish or disturb a successor; native stepping stays outside the lock. */
    fun publishIfCurrent(ticket: DecodedPlaybackAudioTicket, publish: () -> Unit): Boolean =
        synchronized(sourceLock) {
            if (closed || input !== ticket.input) return@synchronized false
            publish()
            true
        }

    /** Raw measurement compatibility; production presentation consumes [drainTicket]. */
    fun drainSample(): MonitorAudioPeakSample? = drainTicket()?.sample

    override fun onFlush(streamMetadata: AudioProcessor.StreamMetadata) {
        synchronized(sourceLock) {
            input?.close()
            input = null
            if (!closed && inputAudioFormat != AudioProcessor.AudioFormat.NOT_SET) {
                input = MonitorPcmAudioInput(peaks).also {
                    it.prepare(
                        MonitorPcmFormat(
                            MonitorPcmSampleType.SIGNED16,
                            inputAudioFormat.channelCount,
                            null,
                        ),
                    )
                }
            }
        }
    }

    override fun onReset() {
        synchronized(sourceLock) {
            input?.close()
            input = null
        }
    }

    /** Player disposal is terminal; late format or decoded callbacks cannot reopen metering. */
    fun close() {
        synchronized(sourceLock) {
            closed = true
            input?.close()
            input = null
            peaks.close()
        }
    }
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
    private val closed = AtomicBoolean(false)
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
        check(!closed.get()) { "Playback audio meter is closed." }
        check(polling.compareAndSet(false, true)) { "Playback audio meter is already polling." }
        audioProcessor.drainSample()
        var previousPayload = FloatArray(0)
        var previousInput: MonitorPcmAudioInput? = null
        var lastTickNanos = monotonicNanos()
        try {
            while (true) {
                delay(pollIntervalMillis)
                val nowNanos = monotonicNanos()
                val elapsedNanos = (nowNanos - lastTickNanos).coerceAtLeast(0L)
                lastTickNanos = nowNanos
                if (closed.get()) return
                val ticket = audioProcessor.drainTicket()
                val peaks = ticket?.sample
                if (ticket == null || peaks == null) {
                    previousPayload = FloatArray(0)
                    previousInput = null
                    mutableLevels.value = null
                    continue
                }
                if (previousInput !== ticket.input) {
                    previousPayload = FloatArray(0)
                }
                val payload =
                    stepper.step(
                        previousPayload = previousPayload,
                        leftPeakLinear = peaks.left,
                        rightPeakLinear = peaks.right,
                        deltaTimeSeconds = elapsedNanos / 1_000_000_000f,
                    )
                val wire = PlaybackAudioMeterWire.parse(payload)
                val published = audioProcessor.publishIfCurrent(ticket) {
                    previousInput = ticket.input
                    previousPayload = wire?.payload ?: FloatArray(0)
                    mutableLevels.value = wire?.levels
                }
                if (!published) {
                    previousPayload = FloatArray(0)
                    previousInput = null
                    mutableLevels.value = null
                }
            }
        } finally {
            audioProcessor.drainSample()
            mutableLevels.value = null
            polling.set(false)
        }
    }

    fun close() {
        closed.set(true)
        audioProcessor.close()
        mutableLevels.value = null
    }
}

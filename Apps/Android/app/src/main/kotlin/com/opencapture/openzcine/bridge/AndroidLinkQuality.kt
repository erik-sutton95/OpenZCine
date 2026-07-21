package com.opencapture.openzcine.bridge

import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.opencapture.openzcine.core.CameraPropertyRefreshFailure
import com.opencapture.openzcine.core.CameraPropertyRefreshStatus
import com.opencapture.openzcine.core.CameraSessionState
import com.opencapture.openzcine.core.LiveFrame
import java.util.ArrayDeque
import kotlin.math.max

/** Swift-approved preview request that Android may pass unchanged to the live-view facade. */
public data class SwiftLiveViewRequest(
    val imageSize: Int,
    val compression: Int,
    val frameIntervalNanoseconds: Long,
) {
    init {
        require(imageSize in 1..3) { "Preview image size must be 1...3." }
        require(compression in 1..3) { "Preview compression must be 1...3." }
        require(frameIntervalNanoseconds in MIN_FRAME_INTERVAL_NANOS..MAX_FRAME_INTERVAL_NANOS) {
            "Preview interval must be between ${MIN_FRAME_INTERVAL_NANOS}ns and ${MAX_FRAME_INTERVAL_NANOS}ns."
        }
    }

    /** Target monitor frames per second implied by the approved preview cadence. */
    val targetFramesPerSecond: Double
        get() = NANOS_PER_SECOND.toDouble() / frameIntervalNanoseconds.toDouble()

    internal companion object {
        const val NANOS_PER_SECOND = 1_000_000_000L
        /** Fixed 60 Hz monitor pull target (always). */
        const val MIN_FRAME_INTERVAL_NANOS = NANOS_PER_SECOND / 60L
        /** Validation floor only; policy never emits slower than 60 Hz. */
        const val MAX_FRAME_INTERVAL_NANOS = 100_000_000L
        /** Always 60 Hz. */
        const val STANDARD_FRAME_INTERVAL_NANOS = MIN_FRAME_INTERVAL_NANOS
        val DEFAULT = SwiftLiveViewRequest(2, 2, STANDARD_FRAME_INTERVAL_NANOS)
    }
}

/** Inputs that Kotlin persists or observes, with all policy resolved in Swift. */
internal data class SwiftLiveViewPolicyInput(
    val streamPreset: Int,
    val qualityBias: Int,
    val thermalTier: Int,
    val isRecording: Boolean,
    val cameraOverheating: Boolean,
    /**
     * Unused — monitor cadence is always 60 Hz. Kept so call sites that
     * still pass a body frame rate compile cleanly.
     */
    val recordingFrameRate: Int? = null,
)

/** Injectable coarse JNI seam for unit tests; protocol policy remains in Swift. */
internal fun interface SwiftLiveViewPolicyBridge {
    fun resolve(input: SwiftLiveViewPolicyInput): SwiftLiveViewRequest?
}

/** Production resolver for the shared Swift live-view policy. */
internal object ProductionSwiftLiveViewPolicyBridge : SwiftLiveViewPolicyBridge {
    override fun resolve(input: SwiftLiveViewPolicyInput): SwiftLiveViewRequest? {
        if (!SwiftCore.isAvailable) return null
        val payload =
            SwiftCore.resolveLiveViewRequest(
                streamPreset = input.streamPreset,
                qualityBias = input.qualityBias,
                thermalTier = input.thermalTier,
                isRecording = input.isRecording,
                cameraOverheating = input.cameraOverheating,
                recordingFrameRate = input.recordingFrameRate ?: 0,
            ) ?: return null
        return parseLiveViewRequest(payload)
    }
}

/**
 * Retains the latest Swift-approved preview request for one live-frame source.
 *
 * A changed request stops only the live-view pump; the source's existing retry
 * path applies the new request before it starts again. No camera recording
 * property is exposed through this controller.
 *
 * **While recording, never stop a healthy pump** solely to apply a new size /
 * compression / cadence. `EndLiveView` mid-take freezes the ZR monitor until
 * the take ends (StartLiveView is often rejected while MovieRec is active).
 * Deferred requests apply on the next non-recording [apply].
 */
@Stable
internal class AndroidLiveViewController(
    private val source: SwiftCoreLiveFrameSource,
    private val policy: SwiftLiveViewPolicyBridge = ProductionSwiftLiveViewPolicyBridge,
) {
    /** Desired Swift policy request; it becomes applied only after native confirmation. */
    var request: SwiftLiveViewRequest? by mutableStateOf(null)
        private set

    suspend fun apply(input: SwiftLiveViewPolicyInput) {
        val resolved = policy.resolve(input) ?: return
        val rejected = source.previewState.value is SwiftLiveViewPreviewState.Rejected
        val changed = request != resolved
        if (!changed && !rejected) return

        // Keep the stream alive for the whole take. Recording flips
        // LiveViewLoadPolicy's size cap (Quality 3→2) which used to force a
        // full pump restart and freeze the feed until EndMovieRec.
        if (
            input.isRecording &&
                source.isNativePumpRunning &&
                !rejected
        ) {
            return
        }

        source.updatePreviewRequest(resolved)
        request = resolved
    }
}

/** Parses the fixed Swift-owned `size<TAB>compression<TAB>interval` record. */
internal fun parseLiveViewRequest(payload: String): SwiftLiveViewRequest? {
    val fields = payload.split('\t')
    if (fields.size != 3) return null
    val imageSize = fields[0].toIntOrNull() ?: return null
    val compression = fields[1].toIntOrNull() ?: return null
    val interval = fields[2].toLongOrNull() ?: return null
    return runCatching { SwiftLiveViewRequest(imageSize, compression, interval) }.getOrNull()
}

/** Snapshot rendered by the Android monitor and Operator Setup Link tab. */
internal data class LinkHealthPresentation(
    val score: Int = 0,
    val signalBars: Int = 0,
    val detail: String = "Not connected",
)

/** Observations passed without interpretation to the portable Swift health scorer. */
internal data class LinkHealthInput(
    val phase: Int,
    val roundTripMilliseconds: Double?,
    val liveViewFramesPerSecond: Double?,
    val targetLiveViewFramesPerSecond: Double,
    val secondsSinceLastGoodFrame: Double?,
    val consecutiveBadFrames: Int,
    val recentCommandFailures: Int,
    val isRecoveringStream: Boolean,
    val isUsbTransport: Boolean,
    val resetSignalBars: Boolean,
)

/** Injectable coarse JNI seam that prevents Kotlin from duplicating health rules. */
internal fun interface LinkHealthBridge {
    fun score(input: LinkHealthInput): LinkHealthPresentation?
}

/** Production health scorer and bar hysteresis bridge. */
internal object ProductionLinkHealthBridge : LinkHealthBridge {
    override fun score(input: LinkHealthInput): LinkHealthPresentation? {
        if (!SwiftCore.isAvailable) return null
        val payload =
            SwiftCore.linkHealthSnapshot(
                phase = input.phase,
                roundTripMilliseconds = input.roundTripMilliseconds ?: 0.0,
                hasRoundTrip = input.roundTripMilliseconds != null,
                liveViewFps = input.liveViewFramesPerSecond ?: 0.0,
                hasLiveViewFps = input.liveViewFramesPerSecond != null,
                targetLiveViewFps = input.targetLiveViewFramesPerSecond,
                secondsSinceLastGoodFrame = input.secondsSinceLastGoodFrame ?: 0.0,
                hasLastGoodFrame = input.secondsSinceLastGoodFrame != null,
                consecutiveBadFrames = input.consecutiveBadFrames,
                recentCommandFailures = input.recentCommandFailures,
                isRecoveringStream = input.isRecoveringStream,
                isUsbTransport = input.isUsbTransport,
                resetSignalBars = input.resetSignalBars,
            ) ?: return null
        return parseLinkHealthPresentation(payload)
    }
}

/** Parses the fixed Swift-owned `score<TAB>bars<TAB>detail` record. */
internal fun parseLinkHealthPresentation(payload: String): LinkHealthPresentation? {
    val fields = payload.split('\t', limit = 3)
    if (fields.size != 3) return null
    val score = fields[0].toIntOrNull()?.coerceIn(0, 100) ?: return null
    val bars = fields[1].toIntOrNull()?.coerceIn(0, 4) ?: return null
    if (fields[2].isBlank()) return null
    return LinkHealthPresentation(score, bars, fields[2])
}

/** Android phase values mirrored by `AndroidCameraLinkPhaseWire` in Swift. */
internal object AndroidLinkPhase {
    const val DISCONNECTED = 0
    const val CONNECTING = 1
    const val CONNECTED_IDLE = 2
    const val STREAMING = 3
    const val RECOVERING = 4
    const val DEMO = 5
}

/**
 * Collects real Android session/frame observations while leaving all scoring
 * and signal-bar hysteresis to Swift. RTT is accepted only from the active
 * session's measured native command channel; unavailable remains null.
 */
@Stable
public class AndroidLinkHealthMonitor internal constructor(
    private val bridge: LinkHealthBridge,
    private val clockNanos: () -> Long,
) {
    /** Creates the production monitor backed by the Swift policy bridge. */
    public constructor() : this(ProductionLinkHealthBridge, System::nanoTime)

    internal var presentation: LinkHealthPresentation by mutableStateOf(LinkHealthPresentation())
        private set

    private val recentFrameTimes = ArrayDeque<Long>()
    private var lastGoodFrameNanos: Long? = null
    private var streamRequestedAtNanos: Long? = null
    private var connected = false
    private var connecting = false
    private var isDemoSession = false
    private var streamingRequested = false
    private var isUsbTransport = false
    private var targetFramesPerSecond = 30.0
    private var recentCommandFailures = 0
    private var roundTripMilliseconds: Double? = null
    private var resetBars = true
    /** Last JNI health score time — throttles score() off the per-frame hot path. */
    private var lastScoreNanos: Long = 0L

    /** Replaces connection truth from the real session state flow. */
    internal fun updateSession(
        state: CameraSessionState,
        streamRequested: Boolean,
        transportIsUsb: Boolean,
        targetFramesPerSecond: Double,
        isDemoSession: Boolean,
    ) {
        val wasConnected = connected
        val wasStreamingRequested = streamingRequested
        val nowNanos = clockNanos()
        connected = state is CameraSessionState.Connected
        connecting = state is CameraSessionState.Connecting
        this.isDemoSession = isDemoSession
        streamingRequested = streamRequested
        isUsbTransport = transportIsUsb
        this.targetFramesPerSecond = max(1.0, targetFramesPerSecond)
        if (!connected) {
            // Disconnected and replacement-connection states must both drop
            // every observation owned by the former native session.
            recentFrameTimes.clear()
            lastGoodFrameNanos = null
            streamRequestedAtNanos = null
            recentCommandFailures = 0
            roundTripMilliseconds = null
            resetBars = true
        } else if (!streamRequested) {
            // A clean/command/media surface has released the preview pump.
            // Its next request must measure first-frame freshness from zero,
            // not inherit a stale frame from the former run.
            recentFrameTimes.clear()
            lastGoodFrameNanos = null
            streamRequestedAtNanos = null
        } else if (!wasStreamingRequested) {
            recentFrameTimes.clear()
            lastGoodFrameNanos = null
            streamRequestedAtNanos = nowNanos
        } else if (!wasConnected && connected) {
            resetBars = true
        }
        refresh()
    }

    /** Records one successfully parsed live-view frame from the active source. */
    internal fun recordFrame(frame: LiveFrame) {
        val timestamp = frame.timestampNanos.takeIf { it > 0 } ?: clockNanos()
        if (streamRequestedAtNanos == null) streamRequestedAtNanos = timestamp
        lastGoodFrameNanos = timestamp
        recentFrameTimes.addLast(timestamp)
        trimOldFrames(timestamp)
        // Cheap timestamp bookkeeping every frame; JNI health scoring is rate-limited.
        // Per-frame score() was a main-thread hitch (~every 20–30 frames under load).
        // Still score immediately for the first two frames so FPS / STREAMING
        // presentation arms without waiting a full score interval.
        val needsColdStartScore = recentFrameTimes.size <= 2
        if (
            needsColdStartScore ||
                lastScoreNanos == 0L ||
                timestamp - lastScoreNanos >= SCORE_INTERVAL_NANOS
        ) {
            lastScoreNanos = timestamp
            refresh(nowNanos = timestamp)
        }
    }

    /** Records only an observed command-channel transport failure, never a guessed radio event. */
    internal fun reportPropertyRefresh(status: CameraPropertyRefreshStatus) {
        recentCommandFailures =
            when ((status as? CameraPropertyRefreshStatus.Degraded)?.failure) {
                CameraPropertyRefreshFailure.TRANSPORT_FAILED -> minOf(3, recentCommandFailures + 1)
                else -> max(0, recentCommandFailures - 1)
            }
        refresh()
    }

    /** Replaces the latest native command RTT; null clears stale session data. */
    internal fun reportRoundTripMilliseconds(value: Double?) {
        roundTripMilliseconds = value?.takeIf { it.isFinite() && it > 0.0 }
        refresh()
    }

    /** Updates freshness while a stream is quiet; call at a bounded UI cadence. */
    internal fun refresh(nowNanos: Long = clockNanos()) {
        val phase = currentPhase(nowNanos)
        val freshnessReferenceNanos = lastGoodFrameNanos ?: streamRequestedAtNanos
        val secondsSinceGood =
            if (
                (phase == AndroidLinkPhase.STREAMING || phase == AndroidLinkPhase.RECOVERING) &&
                    freshnessReferenceNanos != null
            ) {
                max(
                    0.0,
                    (nowNanos - freshnessReferenceNanos).toDouble() /
                        SwiftLiveViewRequest.NANOS_PER_SECOND,
                )
            } else {
                null
            }
        val fps = if (phase == AndroidLinkPhase.STREAMING) measuredFramesPerSecond(nowNanos) else null
        val updated =
            bridge.score(
                LinkHealthInput(
                    phase = phase,
                    roundTripMilliseconds = roundTripMilliseconds,
                    liveViewFramesPerSecond = fps,
                    targetLiveViewFramesPerSecond = targetFramesPerSecond,
                    secondsSinceLastGoodFrame = secondsSinceGood,
                    consecutiveBadFrames = 0,
                    recentCommandFailures = recentCommandFailures,
                    isRecoveringStream = phase == AndroidLinkPhase.RECOVERING,
                    isUsbTransport = isUsbTransport,
                    resetSignalBars = resetBars,
                ),
            )
        resetBars = false
        if (updated != null) presentation = updated
    }

    private fun currentPhase(nowNanos: Long): Int =
        when {
            !connected && !connecting -> AndroidLinkPhase.DISCONNECTED
            connecting -> AndroidLinkPhase.CONNECTING
            isDemoSession -> AndroidLinkPhase.DEMO
            !streamingRequested -> AndroidLinkPhase.CONNECTED_IDLE
            else -> {
                val freshnessReferenceNanos = lastGoodFrameNanos ?: streamRequestedAtNanos
                if (
                    freshnessReferenceNanos != null &&
                        nowNanos - freshnessReferenceNanos > STALE_STREAM_NANOS
                ) {
                    AndroidLinkPhase.RECOVERING
                } else {
                    AndroidLinkPhase.STREAMING
                }
            }
        }

    private fun trimOldFrames(nowNanos: Long) {
        while (
            recentFrameTimes.isNotEmpty() &&
                nowNanos - recentFrameTimes.first > FPS_WINDOW_NANOS
        ) {
            recentFrameTimes.removeFirst()
        }
    }

    private fun measuredFramesPerSecond(nowNanos: Long): Double? {
        trimOldFrames(nowNanos)
        val oldest = recentFrameTimes.firstOrNull() ?: return null
        val newest = recentFrameTimes.lastOrNull() ?: return null
        if (newest <= oldest) return null
        return (recentFrameTimes.size - 1).toDouble() * SwiftLiveViewRequest.NANOS_PER_SECOND /
            (newest - oldest).toDouble()
    }

    private companion object {
        const val FPS_WINDOW_NANOS = SwiftLiveViewRequest.NANOS_PER_SECOND
        const val STALE_STREAM_NANOS = 1_500_000_000L
        /** Score at most ~4 Hz from frame arrivals; the 1 s UI loop still refreshes. */
        const val SCORE_INTERVAL_NANOS = SwiftLiveViewRequest.NANOS_PER_SECOND / 4L
    }
}

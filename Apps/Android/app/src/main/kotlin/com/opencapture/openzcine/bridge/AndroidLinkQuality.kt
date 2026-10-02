package com.opencapture.openzcine.bridge

import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.opencapture.opencine.nikon.CameraPropertyRefreshFailure
import com.opencapture.opencine.nikon.CameraPropertyRefreshStatus
import com.opencapture.opencine.nikon.CameraSessionState
import com.opencapture.opencine.nikon.LiveFrame
import java.util.ArrayDeque
import kotlin.math.max
import com.opencapture.opencine.nikon.CameraPropertySnapshot
import com.opencapture.opencine.nikon.NikonNative
import com.opencapture.opencine.nikon.SwiftCoreCameraSession
import com.opencapture.opencine.nikon.SwiftCoreLiveFrameSource
import com.opencapture.opencine.nikon.SwiftLiveViewPreviewState
import com.opencapture.opencine.nikon.SwiftLiveViewRequest

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
    /**
     * What the stream SHOULD be delivering: the body's recording rate, exactly as iOS scores it
     * (`NativeAppRoot.currentLinkHealthInputs` → `cameraPropertySnapshot.fps ?? 30`). Never the
     * preview pull cadence — see [SwiftLiveViewRequest.targetFramesPerSecond].
     */
    val targetLiveViewFramesPerSecond: Double,
    /**
     * Fallback freshness only, measured from frame ARRIVALS. Whenever a native live-view pump is
     * running, the Swift JNI entry point replaces this with the pump watchdog's decode clock, for
     * the same reason iOS measures at decode (`AndroidLiveViewStreamHealth`).
     */
    val secondsSinceLastGoodFrame: Double?,
    /**
     * Always 0 from this shell: an unparsable frame is dropped inside the Swift live-view pump and
     * never crosses JNI, so Kotlin has no bad frame to count. The real streak is read off the
     * active session's watchdog at the JNI boundary.
     */
    val consecutiveBadFrames: Int,
    val recentCommandFailures: Int,
    val isRecoveringStream: Boolean,
    val isUsbTransport: Boolean,
    val resetSignalBars: Boolean,
    /**
     * Measured link throughput, or null before the first frame. Appended to the caption because
     * the score cannot say whether a healthy-latency link is simply too narrow for the preset.
     */
    val throughputMegabitsPerSecond: Double? = null,
    /**
     * The scored session's native connection owner. Swift reads that owner's pump watchdog
     * only; null (no real session) never borrows another camera's stream health.
     */
    val connectionOwner: Long? = null,
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
            NikonNative.linkHealthSnapshot(
                connectionOwner = input.connectionOwner ?: NO_CONNECTION_OWNER,
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
                throughputMegabitsPerSecond = input.throughputMegabitsPerSecond ?: 0.0,
                hasThroughput = input.throughputMegabitsPerSecond != null,
            ) ?: return null
        return parseLinkHealthPresentation(payload)
    }
}

/** Never issued by `SwiftCoreCameraSession` (owners start at 1), so Swift finds no session. */
private const val NO_CONNECTION_OWNER: Long = 0L

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
    /** Body recording rate; iOS's same 30 fps fallback until the body reports one. */
    private var targetFramesPerSecond = 30.0
    private var recentCommandFailures = 0
    private var roundTripMilliseconds: Double? = null
    private var resetBars = true
    private var connectionOwner: Long? = null
    /** Last JNI health score time — throttles score() off the per-frame hot path. */
    private var lastScoreNanos: Long = 0L

    /**
     * Replaces connection truth from the real session state flow.
     *
     * [targetFramesPerSecond] is the BODY's recording rate (`CameraPropertySnapshot.frameRate`),
     * the same input iOS scores against. Passing the preview pull cadence instead scores a healthy
     * feed against a rate the body never produces — see
     * [SwiftLiveViewRequest.targetFramesPerSecond].
     */
    internal fun updateSession(
        state: CameraSessionState,
        streamRequested: Boolean,
        transportIsUsb: Boolean,
        targetFramesPerSecond: Double,
        isDemoSession: Boolean,
        connectionOwner: Long? = null,
    ) {
        this.connectionOwner = connectionOwner
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
                    // Not an observation — the shell has none to make. A frame that fails to parse
                    // is caught and dropped inside `PTPIPClientSession.runLiveViewPump`, so it
                    // never reaches this class, and a hardcoded 0 here used to mean the shared
                    // scorer's -50 bad-frame penalty could NEVER fire: the bars stayed high
                    // exactly as the body degraded. `SwiftCoreJNI.swiftCoreLinkHealthSnapshot` now
                    // substitutes the pump watchdog's real streak (and its decode-clock freshness)
                    // whenever a pump is running; this literal is the no-pump fallback.
                    consecutiveBadFrames = 0,
                    recentCommandFailures = recentCommandFailures,
                    isRecoveringStream = phase == AndroidLinkPhase.RECOVERING,
                    isUsbTransport = isUsbTransport,
                    resetSignalBars = resetBars,
                    connectionOwner = connectionOwner,
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

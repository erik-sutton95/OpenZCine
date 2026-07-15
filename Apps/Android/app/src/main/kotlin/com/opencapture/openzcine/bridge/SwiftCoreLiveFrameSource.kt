package com.opencapture.openzcine.bridge

import com.opencapture.openzcine.core.LiveAudioMeterChannel
import com.opencapture.openzcine.core.LiveAudioMeterLevels
import com.opencapture.openzcine.core.LiveFrame
import com.opencapture.openzcine.core.LiveFrameSource
import com.opencapture.openzcine.core.LiveFrameTimecode
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.buffer
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.retryWhen
import kotlinx.coroutines.flow.shareIn
import kotlinx.coroutines.flow.transform
import kotlinx.coroutines.withContext

private class LiveViewEndedException : IllegalStateException("The native live-view pump ended.")

private data class StreamFrame(
    val generation: Long,
    val frame: LiveFrame,
)

private data class PreviewRequestPlan(
    val request: SwiftLiveViewRequest,
    val version: Long,
)

/** Measures actual native-frame delivery cadence without inventing a camera setting. */
internal class LiveFrameRateEstimator(
    private val smoothingWeight: Double = 0.25,
) {
    init {
        require(smoothingWeight in 0.0..1.0) { "smoothingWeight must be in 0...1." }
    }

    private var previousTimestampNanos: Long? = null
    private var smoothedIntervalNanos: Double? = null

    /** Adds one monotonic timestamp and returns measured FPS once two valid frames exist. */
    fun record(timestampNanos: Long): Double? {
        val previous = previousTimestampNanos
        previousTimestampNanos = timestampNanos
        if (previous == null) return null
        val interval = timestampNanos - previous
        if (interval !in MIN_INTERVAL_NANOS..MAX_INTERVAL_NANOS) {
            smoothedIntervalNanos = null
            return null
        }
        val prior = smoothedIntervalNanos
        val smoothed =
            if (prior == null) {
                interval.toDouble()
            } else {
                prior * (1.0 - smoothingWeight) + interval * smoothingWeight
            }
        smoothedIntervalNanos = smoothed
        return NANOS_PER_SECOND / smoothed
    }

    private companion object {
        const val NANOS_PER_SECOND = 1_000_000_000.0
        const val MIN_INTERVAL_NANOS = 500_000L
        const val MAX_INTERVAL_NANOS = 5_000_000_000L
    }
}

/**
 * Ownership of the native pump. Every transition is protected by
 * `previewRequestLock`; native calls intentionally happen after ownership is
 * claimed, never while the lock is held.
 */
private sealed interface NativePumpState {
    data object Idle : NativePumpState

    data class Starting(
        val requestVersion: Long,
        val generation: Long,
    ) : NativePumpState

    data class Running(
        val requestVersion: Long,
        val generation: Long,
    ) : NativePumpState

    data class Stopping(val generation: Long) : NativePumpState
}

private enum class PumpStartReservation {
    Reserved,
    Stale,
    Busy,
}

/** The outcome of applying Android's Swift-owned preview request to the active camera. */
internal sealed interface SwiftLiveViewPreviewState {
    /** No live-view consumer has asked the source to configure a stream yet. */
    data object Idle : SwiftLiveViewPreviewState

    /** A request is waiting for the native facade to confirm it. */
    data class Pending(val requested: SwiftLiveViewRequest) : SwiftLiveViewPreviewState

    /** The native facade accepted the request used by the current or last stream. */
    data class Applied(val request: SwiftLiveViewRequest) : SwiftLiveViewPreviewState

    /**
     * The requested configuration was rejected. A non-null [retainedRequest]
     * means the previous confirmed configuration was restored before streaming.
     */
    data class Rejected(
        val requested: SwiftLiveViewRequest,
        val retainedRequest: SwiftLiveViewRequest?,
    ) : SwiftLiveViewPreviewState
}

/**
 * [LiveFrameSource] over the Swift core's live-view pump. The first [frames]
 * collector starts live view on the facade's active session; all collectors
 * share that one pump and receive the latest frame, and removing the final
 * collector stops it. This lets the monitor feed and scopes consume the same
 * stream without issuing duplicate `StartLiveView` commands. The buffer is
 * conflated so backpressure stays latest-wins end to end. A pump-ended signal
 * restarts the native stream while a consumer still exists; this prevents a
 * transient transport end from leaving feed and scopes frozen forever.
 *
 * The constructor parameters exist for JVM tests only — production code uses
 * the defaults, which bind to the JNI facade.
 */
class SwiftCoreLiveFrameSource(
    private val available: () -> Boolean = { SwiftCore.isAvailable },
    private val start: (SwiftCore.LiveFrameListener) -> Unit = SwiftCore::sessionStartLiveView,
    private val stop: () -> Unit = SwiftCore::sessionStopLiveView,
    private val configurePreview: (SwiftLiveViewRequest) -> Boolean = { request ->
        if (!SwiftCore.isAvailable) {
            false
        } else {
            SwiftCore.sessionConfigureLiveView(
                imageSize = request.imageSize,
                compression = request.compression,
                frameIntervalNanoseconds = request.frameIntervalNanoseconds,
            )
        }
    },
    private val sharingScope: CoroutineScope =
        CoroutineScope(SupervisorJob() + Dispatchers.IO),
    private val restartDelayMillis: Long = 250L,
    private val onRecordingState: (Boolean) -> Unit = {},
    private val stopDispatcher: CoroutineDispatcher = Dispatchers.IO,
    private val beforeStartReservation: suspend () -> Unit = {},
) : LiveFrameSource {
    init {
        require(restartDelayMillis >= 0L) { "restartDelayMillis must not be negative." }
    }

    private val previewRequestLock = Any()
    private var requestedPreview = SwiftLiveViewRequest.DEFAULT
    private var requestedPreviewVersion = 0L
    private var appliedPreview: SwiftLiveViewRequest? = null
    private var nativePumpState: NativePumpState = NativePumpState.Idle
    private val previewUpdates = Channel<Unit>(Channel.CONFLATED)
    private val pumpStateUpdates = Channel<Unit>(Channel.CONFLATED)
    private val _previewState = MutableStateFlow<SwiftLiveViewPreviewState>(SwiftLiveViewPreviewState.Idle)
    private val nextStreamGeneration = AtomicLong(0L)
    private val activeStreamGeneration = AtomicLong(0L)

    /** Current requested preview policy, retained for the next stream start. */
    internal val previewRequest: SwiftLiveViewRequest
        get() = synchronized(previewRequestLock) { requestedPreview }

    /** Last preview request that the native facade explicitly accepted. */
    internal val appliedPreviewRequest: SwiftLiveViewRequest?
        get() = synchronized(previewRequestLock) { appliedPreview }

    /** Preview application state for the Link surface. */
    internal val previewState: StateFlow<SwiftLiveViewPreviewState>
        get() = _previewState

    private val upstream: Flow<StreamFrame> =
        callbackFlow {
                // No native library (APK built without `just android-core`):
                // complete immediately instead of crashing on the external fun.
                if (!available()) {
                    close()
                    return@callbackFlow
                }
                // Configure a camera-confirmed request before a pump can run.
                // If a body rejects a new verify-on-HW enum, restore only a
                // previously confirmed request; otherwise leave live view
                // paused and make the rejection visible to the Link surface.
                val reservation = awaitReservedPumpStart()
                val generation = reservation.generation
                try {
                    start(
                        object : SwiftCore.LiveFrameListener {
                        private val frameRateEstimator = LiveFrameRateEstimator()

                        override fun onFrame(
                            jpeg: ByteArray,
                            timestampNanos: Long,
                            isRecording: Boolean,
                            leftLevelDb: Double,
                            leftPeakDb: Double,
                            rightLevelDb: Double,
                            rightPeakDb: Double,
                            hasAudioLevels: Boolean,
                        ) {
                            emitFrame(
                                jpeg = jpeg,
                                timestampNanos = timestampNanos,
                                isRecording = isRecording,
                                leftLevelDb = leftLevelDb,
                                leftPeakDb = leftPeakDb,
                                rightLevelDb = rightLevelDb,
                                rightPeakDb = rightPeakDb,
                                hasAudioLevels = hasAudioLevels,
                            )
                        }

                        override fun onFrameWithMetadata(
                            jpeg: ByteArray,
                            timestampNanos: Long,
                            isRecording: Boolean,
                            leftLevelDb: Double,
                            leftPeakDb: Double,
                            rightLevelDb: Double,
                            rightPeakDb: Double,
                            hasAudioLevels: Boolean,
                            hasFocus: Boolean,
                            focusCoordinateWidth: Int,
                            focusCoordinateHeight: Int,
                            focusResult: Int,
                            subjectDetectionActive: Boolean,
                            trackingAFActive: Boolean,
                            selectedBoxIndex: Int,
                            focusBoxes: IntArray,
                            hasLevel: Boolean,
                            levelRollDegrees: Double,
                            levelPitchDegrees: Double,
                            levelYawDegrees: Double,
                        ) {
                            emitFrame(
                                jpeg = jpeg,
                                timestampNanos = timestampNanos,
                                isRecording = isRecording,
                                leftLevelDb = leftLevelDb,
                                leftPeakDb = leftPeakDb,
                                rightLevelDb = rightLevelDb,
                                rightPeakDb = rightPeakDb,
                                hasAudioLevels = hasAudioLevels,
                                focus =
                                    liveFocusInfoFromWire(
                                        hasFocus = hasFocus,
                                        coordinateWidth = focusCoordinateWidth,
                                        coordinateHeight = focusCoordinateHeight,
                                        focusResult = focusResult,
                                        subjectDetectionActive = subjectDetectionActive,
                                        trackingAFActive = trackingAFActive,
                                        selectedBoxIndex = selectedBoxIndex,
                                        flattenedBoxes = focusBoxes,
                                    ),
                                level =
                                    liveCameraLevelFromWire(
                                        hasLevel = hasLevel,
                                        rollDegrees = levelRollDegrees,
                                        pitchDegrees = levelPitchDegrees,
                                        yawDegrees = levelYawDegrees,
                                    ),
                            )
                        }

                        override fun onFrameWithFullMetadata(
                            jpeg: ByteArray,
                            timestampNanos: Long,
                            isRecording: Boolean,
                            leftLevelDb: Double,
                            leftPeakDb: Double,
                            rightLevelDb: Double,
                            rightPeakDb: Double,
                            hasAudioLevels: Boolean,
                            hasFocus: Boolean,
                            focusCoordinateWidth: Int,
                            focusCoordinateHeight: Int,
                            focusResult: Int,
                            subjectDetectionActive: Boolean,
                            trackingAFActive: Boolean,
                            selectedBoxIndex: Int,
                            focusBoxes: IntArray,
                            hasLevel: Boolean,
                            levelRollDegrees: Double,
                            levelPitchDegrees: Double,
                            levelYawDegrees: Double,
                            timecodeOn: Boolean,
                            timecodeHour: Int,
                            timecodeMinute: Int,
                            timecodeSecond: Int,
                            timecodeFrame: Int,
                        ) {
                            emitFrame(
                                jpeg = jpeg,
                                timestampNanos = timestampNanos,
                                isRecording = isRecording,
                                leftLevelDb = leftLevelDb,
                                leftPeakDb = leftPeakDb,
                                rightLevelDb = rightLevelDb,
                                rightPeakDb = rightPeakDb,
                                hasAudioLevels = hasAudioLevels,
                                focus =
                                    liveFocusInfoFromWire(
                                        hasFocus = hasFocus,
                                        coordinateWidth = focusCoordinateWidth,
                                        coordinateHeight = focusCoordinateHeight,
                                        focusResult = focusResult,
                                        subjectDetectionActive = subjectDetectionActive,
                                        trackingAFActive = trackingAFActive,
                                        selectedBoxIndex = selectedBoxIndex,
                                        flattenedBoxes = focusBoxes,
                                    ),
                                level =
                                    liveCameraLevelFromWire(
                                        hasLevel = hasLevel,
                                        rollDegrees = levelRollDegrees,
                                        pitchDegrees = levelPitchDegrees,
                                        yawDegrees = levelYawDegrees,
                                    ),
                                timecode =
                                    LiveFrameTimecode(
                                        on = timecodeOn,
                                        hour = timecodeHour,
                                        minute = timecodeMinute,
                                        second = timecodeSecond,
                                        frame = timecodeFrame,
                                    ),
                            )
                        }

                        private fun emitFrame(
                            jpeg: ByteArray,
                            timestampNanos: Long,
                            isRecording: Boolean,
                            leftLevelDb: Double,
                            leftPeakDb: Double,
                            rightLevelDb: Double,
                            rightPeakDb: Double,
                            hasAudioLevels: Boolean,
                            focus: com.opencapture.openzcine.core.LiveFocusInfo? = null,
                            level: com.opencapture.openzcine.core.LiveCameraLevel? = null,
                            timecode: LiveFrameTimecode? = null,
                        ) {
                            onRecordingState(isRecording)
                            val audioLevels =
                                if (hasAudioLevels) {
                                    LiveAudioMeterLevels(
                                        left = LiveAudioMeterChannel(leftLevelDb, leftPeakDb),
                                        right = LiveAudioMeterChannel(rightLevelDb, rightPeakDb),
                                    )
                                } else {
                                    null
                                }
                            trySend(
                                StreamFrame(
                                    generation = generation,
                                    frame =
                                        LiveFrame(
                                            timestampNanos = timestampNanos,
                                            jpegData = jpeg,
                                            isRecording = isRecording,
                                            audioLevels = audioLevels,
                                            focus = focus,
                                            level = level,
                                            timecode = timecode,
                                            measuredFramesPerSecond =
                                                frameRateEstimator.record(timestampNanos),
                                        ),
                                ),
                            )
                        }

                        override fun onEnded() {
                            close(LiveViewEndedException())
                        }
                        },
                    )
                } catch (error: Throwable) {
                    failPumpStart(generation)
                    throw error
                }
                if (completePumpStart(reservation)) {
                    stopClaimedPump(generation)
                }
                awaitClose {
                    releasePumpFromFlow(generation)
                }
            }
            .buffer(Channel.CONFLATED)
            .retryWhen { cause, _ ->
                if (cause !is LiveViewEndedException) return@retryWhen false
                delay(restartDelayMillis)
                true
            }

    private val sharedFrames =
        upstream.shareIn(
            scope = sharingScope,
            started = SharingStarted.WhileSubscribed(stopTimeoutMillis = 0),
            replay = 1,
        )

    /**
     * Visual consumers retain the last JPEG across a temporary source restart.
     * Health consumers must use [currentStreamFrames], which rejects replay
     * emitted by a former native pump generation.
     */
    override val frames: Flow<LiveFrame> = sharedFrames.map { it.frame }

    /** Frames proven to come from the currently requested native stream generation. */
    internal val currentStreamFrames: Flow<LiveFrame> =
        sharedFrames.transform { streamFrame ->
            if (activeStreamGeneration.get() == streamFrame.generation) {
                emit(streamFrame.frame)
            }
        }

    private suspend fun awaitReservedPumpStart(): NativePumpState.Starting {
        while (true) {
            awaitPumpIdle()
            val plan = awaitConfiguredPreviewRequest()
            beforeStartReservation()
            val generation = nextStreamGeneration.incrementAndGet()
            when (reservePumpStart(plan, generation)) {
                PumpStartReservation.Reserved ->
                    return NativePumpState.Starting(plan.version, generation)
                PumpStartReservation.Stale -> continue
                PumpStartReservation.Busy -> pumpStateUpdates.receive()
            }
        }
    }

    private suspend fun awaitPumpIdle() {
        while (synchronized(previewRequestLock) { nativePumpState !is NativePumpState.Idle }) {
            pumpStateUpdates.receive()
        }
    }

    private suspend fun awaitConfiguredPreviewRequest(): PreviewRequestPlan {
        while (true) {
            val plan = currentPreviewPlan()
            if (!publishPendingIfCurrent(plan)) continue
            if (configurePreviewSafely(plan.request)) {
                val accepted =
                    synchronized(previewRequestLock) {
                        if (!isCurrentPreviewPlanLocked(plan)) {
                            false
                        } else {
                            appliedPreview = plan.request
                            _previewState.value = SwiftLiveViewPreviewState.Applied(plan.request)
                            true
                        }
                    }
                if (!accepted) continue
                return plan
            }

            if (!isCurrentPreviewPlan(plan)) continue
            val retained = appliedPreviewRequest
            if (
                retained != null &&
                    retained != plan.request &&
                    configurePreviewSafely(retained)
            ) {
                val restored =
                    synchronized(previewRequestLock) {
                        if (!isCurrentPreviewPlanLocked(plan)) {
                            false
                        } else {
                            _previewState.value =
                                SwiftLiveViewPreviewState.Rejected(
                                    requested = plan.request,
                                    retainedRequest = retained,
                                )
                            true
                        }
                    }
                if (!restored) continue
                return plan
            }

            val rejected =
                synchronized(previewRequestLock) {
                    if (!isCurrentPreviewPlanLocked(plan)) return@synchronized false
                    if (appliedPreview == retained) appliedPreview = null
                    _previewState.value =
                        SwiftLiveViewPreviewState.Rejected(
                            requested = plan.request,
                            retainedRequest = null,
                        )
                    true
                }
            if (!rejected) continue
            previewUpdates.receive()
        }
    }

    private fun currentPreviewPlan(): PreviewRequestPlan =
        synchronized(previewRequestLock) {
            PreviewRequestPlan(requestedPreview, requestedPreviewVersion)
        }

    private fun publishPendingIfCurrent(plan: PreviewRequestPlan): Boolean =
        synchronized(previewRequestLock) {
            if (!isCurrentPreviewPlanLocked(plan)) {
                false
            } else {
                _previewState.value = SwiftLiveViewPreviewState.Pending(plan.request)
                true
            }
        }

    private fun isCurrentPreviewPlan(plan: PreviewRequestPlan): Boolean =
        synchronized(previewRequestLock) { isCurrentPreviewPlanLocked(plan) }

    private fun isCurrentPreviewPlanLocked(plan: PreviewRequestPlan): Boolean =
        requestedPreviewVersion == plan.version && requestedPreview == plan.request

    private fun reservePumpStart(
        plan: PreviewRequestPlan,
        generation: Long,
    ): PumpStartReservation =
        synchronized(previewRequestLock) {
            if (!isCurrentPreviewPlanLocked(plan)) {
                PumpStartReservation.Stale
            } else if (nativePumpState !is NativePumpState.Idle) {
                PumpStartReservation.Busy
            } else {
                nativePumpState = NativePumpState.Starting(plan.version, generation)
                activeStreamGeneration.set(generation)
                PumpStartReservation.Reserved
            }
        }

    private fun completePumpStart(reservation: NativePumpState.Starting): Boolean =
        synchronized(previewRequestLock) {
            check(nativePumpState == reservation) { "Native live-view start ownership was lost." }
            if (requestedPreviewVersion == reservation.requestVersion) {
                nativePumpState =
                    NativePumpState.Running(
                        requestVersion = reservation.requestVersion,
                        generation = reservation.generation,
                    )
                false
            } else {
                activeStreamGeneration.compareAndSet(reservation.generation, 0L)
                nativePumpState = NativePumpState.Stopping(reservation.generation)
                true
            }
        }

    private fun failPumpStart(generation: Long) {
        val released =
            synchronized(previewRequestLock) {
                val state = nativePumpState
                if (state !is NativePumpState.Starting || state.generation != generation) {
                    false
                } else {
                    activeStreamGeneration.compareAndSet(generation, 0L)
                    nativePumpState = NativePumpState.Idle
                    true
                }
            }
        if (released) pumpStateUpdates.trySend(Unit)
    }

    private fun releasePumpFromFlow(generation: Long) {
        val claimed =
            synchronized(previewRequestLock) {
                when (val state = nativePumpState) {
                    is NativePumpState.Starting -> state.generation == generation
                    is NativePumpState.Running -> state.generation == generation
                    is NativePumpState.Idle,
                    is NativePumpState.Stopping,
                    -> false
                }.also { shouldStop ->
                    if (shouldStop) {
                        activeStreamGeneration.compareAndSet(generation, 0L)
                        nativePumpState = NativePumpState.Stopping(generation)
                    }
                }
            }
        if (!claimed) return
        try {
            stop()
        } finally {
            completePumpStop(generation)
        }
    }

    private suspend fun stopClaimedPump(generation: Long) {
        try {
            withContext(NonCancellable + stopDispatcher) { stop() }
        } finally {
            completePumpStop(generation)
        }
    }

    private fun completePumpStop(generation: Long) {
        val released =
            synchronized(previewRequestLock) {
                val state = nativePumpState
                if (state !is NativePumpState.Stopping || state.generation != generation) {
                    false
                } else {
                    nativePumpState = NativePumpState.Idle
                    true
                }
            }
        if (released) pumpStateUpdates.trySend(Unit)
    }

    private fun configurePreviewSafely(request: SwiftLiveViewRequest): Boolean =
        try {
            configurePreview(request)
        } catch (error: Throwable) {
            if (error is CancellationException) throw error
            false
        }

    /**
     * Updates the next Swift-owned preview request and restarts only an active
     * monitor stream so the camera receives it immediately. `stop()` sends
     * `EndLiveView`; retry then configures the latest request before starting
     * again. The request contains preview size/compression/pull cadence only.
     */
    internal suspend fun updatePreviewRequest(request: SwiftLiveViewRequest): Boolean {
        var changed = false
        var stopGeneration: Long? = null
        val accepted =
            synchronized(previewRequestLock) {
                changed = requestedPreview != request
                val retryingRejectedRequest =
                    !changed && _previewState.value is SwiftLiveViewPreviewState.Rejected
                if (!changed && !retryingRejectedRequest) return@synchronized false
                if (changed) {
                    requestedPreview = request
                }
                requestedPreviewVersion += 1
                _previewState.value = SwiftLiveViewPreviewState.Pending(request)
                when (val state = nativePumpState) {
                    is NativePumpState.Starting ->
                        activeStreamGeneration.compareAndSet(state.generation, 0L)
                    is NativePumpState.Running -> {
                        activeStreamGeneration.compareAndSet(state.generation, 0L)
                        nativePumpState = NativePumpState.Stopping(state.generation)
                        stopGeneration = state.generation
                    }
                    is NativePumpState.Idle,
                    is NativePumpState.Stopping,
                    -> Unit
                }
                true
            }
        if (!accepted) return false

        previewUpdates.trySend(Unit)
        stopGeneration?.let { stopClaimedPump(it) }
        return changed
    }
}

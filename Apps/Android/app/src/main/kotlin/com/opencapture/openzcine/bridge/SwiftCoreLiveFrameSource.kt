package com.opencapture.openzcine.bridge

import com.opencapture.openzcine.core.LiveFrame
import com.opencapture.openzcine.core.LiveAudioMeterChannel
import com.opencapture.openzcine.core.LiveAudioMeterLevels
import com.opencapture.openzcine.core.LiveFrameSource
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
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
) : LiveFrameSource {
    init {
        require(restartDelayMillis >= 0L) { "restartDelayMillis must not be negative." }
    }

    private val previewRequestLock = Any()
    private var requestedPreview = SwiftLiveViewRequest.DEFAULT
    private var appliedPreview: SwiftLiveViewRequest? = null
    private val previewUpdates = Channel<Unit>(Channel.CONFLATED)
    private val _previewState = MutableStateFlow<SwiftLiveViewPreviewState>(SwiftLiveViewPreviewState.Idle)
    private val liveViewPumpActive = AtomicBoolean(false)
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
                awaitConfiguredPreviewRequest()
                val generation = nextStreamGeneration.incrementAndGet()
                activeStreamGeneration.set(generation)
                liveViewPumpActive.set(true)
                try {
                    start(
                        object : SwiftCore.LiveFrameListener {
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
                    activeStreamGeneration.compareAndSet(generation, 0L)
                    liveViewPumpActive.set(false)
                    throw error
                }
                awaitClose {
                    activeStreamGeneration.compareAndSet(generation, 0L)
                    if (liveViewPumpActive.getAndSet(false)) stop()
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

    private suspend fun awaitConfiguredPreviewRequest(): SwiftLiveViewRequest {
        while (true) {
            val requested = previewRequest
            _previewState.value = SwiftLiveViewPreviewState.Pending(requested)
            if (configurePreviewSafely(requested)) {
                if (!isCurrentPreviewRequest(requested)) continue
                synchronized(previewRequestLock) { appliedPreview = requested }
                _previewState.value = SwiftLiveViewPreviewState.Applied(requested)
                return requested
            }

            if (!isCurrentPreviewRequest(requested)) continue
            val retained = appliedPreviewRequest
            if (
                retained != null &&
                    retained != requested &&
                    configurePreviewSafely(retained)
            ) {
                if (!isCurrentPreviewRequest(requested)) continue
                _previewState.value =
                    SwiftLiveViewPreviewState.Rejected(
                        requested = requested,
                        retainedRequest = retained,
                    )
                return retained
            }

            if (!isCurrentPreviewRequest(requested)) continue
            if (retained != null) {
                synchronized(previewRequestLock) {
                    if (appliedPreview == retained) appliedPreview = null
                }
            }
            _previewState.value =
                SwiftLiveViewPreviewState.Rejected(
                    requested = requested,
                    retainedRequest = null,
                )
            previewUpdates.receive()
        }
    }

    private fun isCurrentPreviewRequest(request: SwiftLiveViewRequest): Boolean =
        synchronized(previewRequestLock) { requestedPreview == request }

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
        val changed =
            synchronized(previewRequestLock) {
                if (requestedPreview == request) {
                    false
                } else {
                    requestedPreview = request
                    true
                }
            }
        val retryingRejectedRequest = !changed && _previewState.value is SwiftLiveViewPreviewState.Rejected
        if (!changed && !retryingRejectedRequest) return false

        _previewState.value = SwiftLiveViewPreviewState.Pending(request)
        previewUpdates.trySend(Unit)
        if (liveViewPumpActive.compareAndSet(true, false)) {
            // The requested generation has changed. Do not let a late frame
            // or replay from the stopping pump count as fresh link health.
            activeStreamGeneration.set(0L)
            withContext(Dispatchers.IO) { stop() }
        }
        return changed
    }
}

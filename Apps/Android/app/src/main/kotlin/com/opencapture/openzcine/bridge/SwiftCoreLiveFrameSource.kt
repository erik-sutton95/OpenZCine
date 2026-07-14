package com.opencapture.openzcine.bridge

import com.opencapture.openzcine.core.LiveFrame
import com.opencapture.openzcine.core.LiveFrameSource
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.buffer
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.flow.retryWhen
import kotlinx.coroutines.flow.shareIn

private class LiveViewEndedException : IllegalStateException("The native live-view pump ended.")

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
    private val sharingScope: CoroutineScope =
        CoroutineScope(SupervisorJob() + Dispatchers.IO),
    private val restartDelayMillis: Long = 250L,
    private val onRecordingState: (Boolean) -> Unit = {},
) : LiveFrameSource {
    init {
        require(restartDelayMillis >= 0L) { "restartDelayMillis must not be negative." }
    }

    private val upstream: Flow<LiveFrame> =
        callbackFlow {
                // No native library (APK built without `just android-core`):
                // complete immediately instead of crashing on the external fun.
                if (!available()) {
                    close()
                    return@callbackFlow
                }
                start(
                    object : SwiftCore.LiveFrameListener {
                        override fun onFrame(
                            jpeg: ByteArray,
                            timestampNanos: Long,
                            isRecording: Boolean,
                        ) {
                            onRecordingState(isRecording)
                            trySend(LiveFrame(timestampNanos, jpeg, isRecording))
                        }

                        override fun onEnded() {
                            close(LiveViewEndedException())
                        }
                    },
                )
                awaitClose { stop() }
            }
            .buffer(Channel.CONFLATED)
            .retryWhen { cause, _ ->
                if (cause !is LiveViewEndedException) return@retryWhen false
                delay(restartDelayMillis)
                true
            }

    override val frames: Flow<LiveFrame> =
        upstream.shareIn(
            scope = sharingScope,
            started = SharingStarted.WhileSubscribed(stopTimeoutMillis = 0),
            replay = 1,
        )
}

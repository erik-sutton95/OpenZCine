package com.opencapture.openzcine.bridge

import com.opencapture.openzcine.core.LiveFrame
import com.opencapture.openzcine.core.LiveFrameSource
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.buffer
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.flow.flowOn

/**
 * [LiveFrameSource] over the Swift core's live-view pump: collecting [frames]
 * starts live view on the facade's active session, cancelling collection (or
 * the pump ending — disconnect, transport error) stops it. The buffer is
 * conflated so backpressure stays latest-wins end to end; the flow completes
 * when the pump reports the stream ended.
 *
 * The constructor parameters exist for JVM tests only — production code uses
 * the defaults, which bind to the JNI facade.
 */
class SwiftCoreLiveFrameSource(
    private val available: () -> Boolean = { SwiftCore.isAvailable },
    private val start: (SwiftCore.LiveFrameListener) -> Unit = SwiftCore::sessionStartLiveView,
    private val stop: () -> Unit = SwiftCore::sessionStopLiveView,
    private val onRecordingState: (Boolean) -> Unit = {},
) : LiveFrameSource {
    override val frames: Flow<LiveFrame> =
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
                            close()
                        }
                    },
                )
                awaitClose { stop() }
            }
            .buffer(Channel.CONFLATED)
            .flowOn(Dispatchers.IO)
}

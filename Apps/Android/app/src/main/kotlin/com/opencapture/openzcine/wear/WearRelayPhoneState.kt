package com.opencapture.openzcine.wear

import com.opencapture.openzcine.core.CameraPropertySnapshot
import com.opencapture.openzcine.core.CameraRecordingException
import com.opencapture.openzcine.core.CameraSessionState
import com.opencapture.openzcine.core.CameraStorageStatus
import com.opencapture.openzcine.wearrelay.WatchCommandResult
import com.opencapture.openzcine.wearrelay.WatchConnectionState
import com.opencapture.openzcine.wearrelay.WatchRecordState
import com.opencapture.openzcine.wearrelay.WatchRelayState
import com.opencapture.openzcine.wearrelay.WatchTimecode
import kotlin.math.roundToInt

/**
 * Current safety conditions for a record request arriving from the wearable.
 *
 * The watch intentionally bypasses the phone's visible confirmation prompt,
 * but never these live-monitor, lifecycle, camera-session, or pending-command
 * gates. This is a pure value so its rejection policy has JVM coverage.
 */
internal data class WearRecordCommandSafety(
    val monitorFront: Boolean,
    val applicationResumed: Boolean,
    val cameraConnected: Boolean,
    val recordCommandPending: Boolean,
    val recordConfirmationPending: Boolean,
    val cameraControlPending: Boolean,
)

/** Returns the operator-safe reason a wearable record request cannot run, if any. */
internal fun wearRecordCommandRejection(safety: WearRecordCommandSafety): String? =
    when {
        !safety.applicationResumed || !safety.monitorFront -> "Open the live monitor on the phone."
        !safety.cameraConnected -> "Connect a camera on the phone."
        safety.recordCommandPending -> "A recording command is already pending."
        safety.recordConfirmationPending -> "Finish the pending record confirmation on the phone."
        safety.cameraControlPending -> "Wait for the active camera control."
        else -> null
    }

/** Builds a rejected reply without changing a camera/session value. */
internal fun rejectedWearRecordResult(
    safety: WearRecordCommandSafety,
    isRecording: Boolean,
): WatchCommandResult =
    WatchCommandResult(
        accepted = false,
        isRecording = isRecording,
        error = wearRecordCommandRejection(safety) ?: "unavailable",
    )

/**
 * Routes the watch toggle through the same typed camera recording seam as the
 * phone, after the foreground/session/pending-work policy accepts it. Live
 * preview is deliberately not required: watchOS can record while its feed is
 * paused or the command dashboard is selected.
 */
internal suspend fun executeWearRecordCommand(
    safety: WearRecordCommandSafety,
    isRecording: Boolean,
    setRecording: suspend (Boolean) -> Unit,
): WatchCommandResult {
    if (wearRecordCommandRejection(safety) != null) {
        return rejectedWearRecordResult(safety, isRecording)
    }
    val target = !isRecording
    return try {
        setRecording(target)
        WatchCommandResult(accepted = true, isRecording = target, error = null)
    } catch (error: CameraRecordingException) {
        WatchCommandResult(
            accepted = false,
            isRecording = isRecording,
            error = error.message ?: "unavailable",
        )
    }
}

/** Retains the latest real frame readouts when the connected phone pauses preview. */
internal fun retainWatchFrameMetadata(
    state: WatchRelayState,
    previous: WatchRelayState?,
): WatchRelayState {
    if (state.connection != WatchConnectionState.CONNECTED || previous == null) return state
    val previousTimecode = previous.timecode
    val hasPreviousTimecode =
        previousTimecode.on ||
            previousTimecode.hour != 0 ||
            previousTimecode.minute != 0 ||
            previousTimecode.second != 0 ||
            previousTimecode.frame != 0
    return state.copy(
        timecode =
            if (!state.timecode.on && hasPreviousTimecode) previousTimecode else state.timecode,
        liveFPS =
            if (state.liveFPS == "—" && previous.liveFPS != "—") {
                previous.liveFPS
            } else {
                state.liveFPS
            },
    )
}

/**
 * Creates the honest Android phone snapshot consumed by the Wear OS relay.
 *
 * Timecode/FPS begin unavailable and are replaced only by metadata from an
 * actually presented native camera frame inside [AndroidWearPhoneRelay].
 * Storage and battery enter only from the real Swift-core property snapshot.
 */
internal fun androidWatchRelayState(
    sessionState: CameraSessionState,
    cameraProperties: CameraPropertySnapshot,
    isRecording: Boolean,
    monitorFront: Boolean,
    applicationResumed: Boolean,
    liveFeedActive: Boolean,
): WatchRelayState {
    val connectedIdentity = (sessionState as? CameraSessionState.Connected)?.identity
    val foreground = monitorFront && applicationResumed
    val connection =
        when {
            !foreground -> WatchConnectionState.DISCONNECTED
            connectedIdentity != null -> WatchConnectionState.CONNECTED
            else -> WatchConnectionState.NO_CAMERA
        }
    val hasCamera = connection == WatchConnectionState.CONNECTED
    return WatchRelayState(
        recordState = if (isRecording) WatchRecordState.RECORDING else WatchRecordState.STANDBY,
        timecode = WatchTimecode.unavailable(),
        mediaStatus = null,
        media = if (hasCamera) cameraProperties.storage?.let(::storageLabel) ?: "—" else "—",
        // The canonical Swift relay model is a non-optional 0...100 value.
        // Match watchOS by preserving a real zero-percent camera readout.
        cameraBatteryPercent =
            if (hasCamera) cameraProperties.batteryPercent?.takeIf { it in 0..100 } ?: 0 else 0,
        cameraName = if (hasCamera) connectedIdentity?.name.orEmpty() else "",
        isRecording = isRecording,
        connection = connection,
        feedLive = hasCamera && liveFeedActive,
        liveFPS = "—",
    )
}

private fun storageLabel(storage: CameraStorageStatus): String {
    val freeGiB = storage.freeSpaceBytes.coerceAtLeast(0L) / BYTES_PER_GIB
    if (storage.totalCapacityBytes <= 0L) return "$freeGiB GB"
    val percent =
        ((storage.freeSpaceBytes.toDouble() / storage.totalCapacityBytes.toDouble()) * 100)
            .roundToInt()
            .coerceIn(0, 100)
    return "$freeGiB GB · $percent%"
}

private const val BYTES_PER_GIB: Long = 1_073_741_824L

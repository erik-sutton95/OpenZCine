package com.opencapture.openzcine.wear

import com.opencapture.openzcine.core.CameraPropertySnapshot
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
    val liveFeedActive: Boolean,
    val recordCommandPending: Boolean,
    val recordConfirmationPending: Boolean,
    val cameraControlPending: Boolean,
)

/** Returns the operator-safe reason a wearable record request cannot run, if any. */
internal fun wearRecordCommandRejection(safety: WearRecordCommandSafety): String? =
    when {
        !safety.applicationResumed || !safety.monitorFront -> "Open the live monitor on the phone."
        !safety.cameraConnected -> "Connect a camera on the phone."
        !safety.liveFeedActive -> "Start live view before recording."
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
 * Creates the honest Android phone snapshot consumed by the Wear OS relay.
 *
 * Android has not yet bridged camera timecode or measured live FPS (OPE-63),
 * so this intentionally sends explicit unavailable placeholders instead of
 * deriving a shell clock or copying the debug monitor values. Storage and
 * battery enter only from the real Swift-core property snapshot.
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
        // Zero is the canonical relay model's explicit unavailable/default
        // value. The Wear UI presents it as an em dash until a camera snapshot
        // supplies an in-range battery number, rather than inventing a charge.
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

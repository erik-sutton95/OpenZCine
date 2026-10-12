package com.opencapture.openzcine.wear

import android.graphics.Bitmap
import androidx.compose.foundation.Image
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalResources
import androidx.compose.ui.res.stringResource
import androidx.wear.compose.material3.MaterialTheme
import com.opencapture.monitorui.MonitorTimecodeFormat
import com.opencapture.monitorui.wrist.*
import com.opencapture.openzcine.wearrelay.WatchConnectionState
import com.opencapture.openzcine.wearrelay.WatchRelayState
import com.opencapture.openzcine.wearrelay.WatchTimecode

/** Immutable UI input, separated from Data Layer ownership for UI testing. */
internal data class WearMonitorPresentation(
    val phoneReachable: Boolean,
    val state: WatchRelayState?,
    val frame: Bitmap?,
    val frameTimecode: WatchTimecode?,
    val isSendingCommand: Boolean,
    val commandMessage: String?,
    val presentationRevision: Long = 0,
) {
    val isRecording: Boolean get() = neutral().isRecording
    val canRecord: Boolean get() = neutral().canRecord

}

internal typealias WearScreenLayout = MonitorWristLayout
internal fun wearScreenLayout(isRound: Boolean, widthDp: Float): WearScreenLayout = monitorWristLayout(isRound, widthDp)
internal fun fittedSingleLineFontSize(text: String, availableWidthDp: Float, maximumSizeSp: Float = 11f): Float =
    monitorWristSingleLineFontSize(text, availableWidthDp, maximumSizeSp)

@Composable
internal fun WearMonitorScreen(controller: WearRelayController) {
    WearMonitorContent(controller.presentation(), controller::sendToggleRecord, current = controller::presentation)
}

/** Codec/localized facts and the bounded bitmap view; common UI owns the complete wrist surface. */
@Composable
internal fun WearMonitorContent(presentation: WearMonitorPresentation, onToggleRecord: () -> Unit,
    current: () -> WearMonitorPresentation = { presentation }) {
    val resources = LocalResources.current
    val value = presentation.neutral(presentation.state?.mediaStatus?.let {
        resources.getString(R.string.wear_storage_capacity, it.gigabytesFree, it.percentFree)
    })
    val copy = MonitorWristCopy(
        monitorDescription = stringResource(R.string.wear_monitor_description),
        openOnPhone = stringResource(R.string.wear_open_on_phone), waitingForPhone = stringResource(R.string.wear_waiting_for_phone),
        phoneUnavailable = stringResource(R.string.wear_phone_unavailable), noCamera = stringResource(R.string.wear_no_camera),
        feedPaused = stringResource(R.string.wear_feed_paused), waitingForPreview = stringResource(R.string.wear_waiting_for_preview),
        timecodeUnavailable = MonitorTimecodeFormat.placeholder(frames = true), unavailable = stringResource(R.string.wear_unavailable),
        startRecording = stringResource(R.string.wear_start_recording_description), stopRecording = stringResource(R.string.wear_stop_recording_description),
        batteryLabel = { resources.getString(R.string.wear_battery_percent, it) })
    MaterialTheme {
        MonitorWristScreen(value, copy, onToggleRecord = { token ->
            if (current().neutral().isCurrent(token)) onToggleRecord()
        }) { modifier ->
            presentation.frame?.let {
                Image(it.asImageBitmap(), contentDescription = stringResource(R.string.wear_live_preview_description),
                    modifier = modifier, contentScale = ContentScale.Crop)
            }
        }
    }
}

private fun WearRelayController.presentation(): WearMonitorPresentation = WearMonitorPresentation(
    phoneReachable, state, frame, frameTimecode, isSendingCommand, commandMessage, presentationRevision)

private fun WearMonitorPresentation.neutral(storageStatus: String? = null): MonitorWristPresentation {
    val connection = when (state?.connection) {
        WatchConnectionState.CONNECTED -> MonitorWristConnection.CONNECTED
        WatchConnectionState.DISCONNECTED -> MonitorWristConnection.DISCONNECTED
        WatchConnectionState.NO_CAMERA -> MonitorWristConnection.NO_CAMERA
        null -> null
    }
    return MonitorWristPresentation(presentationRevision, phoneReachable, connection, state?.feedLive,
        state?.isRecording, isSendingCommand, commandMessage, frame != null, state?.cameraBatteryPercent,
        state?.timecode?.takeIf { it.on }?.label(), frameTimecode?.takeIf { it.on }?.label(), storageStatus, state?.media)
}

/** The body's frame timecode by the shared rule (every Z body declares frame precision). */
private fun WatchTimecode.label(): String? = MonitorTimecodeFormat.label(hour, minute, second, frame)

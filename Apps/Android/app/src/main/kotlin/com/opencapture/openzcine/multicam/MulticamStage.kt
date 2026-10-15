package com.opencapture.openzcine.multicam

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.opencapture.monitorui.MonitorMaterial
import com.opencapture.monitorui.MonitorPalette
import com.opencapture.monitorui.MonitorTypography
import com.opencapture.monitorui.monitorMaterial
import com.opencapture.opencine.appkit.MultiviewCameraAction
import com.opencapture.opencine.appkit.MultiviewCameraPicker
import com.opencapture.opencine.appkit.MultiviewPickerRow
import com.opencapture.opencine.appkit.MultiviewReadout
import com.opencapture.opencine.appkit.MultiviewRecordContext
import com.opencapture.opencine.appkit.MultiviewStage
import com.opencapture.opencine.appkit.MultiviewStageSurface
import com.opencapture.opencine.appkit.MultiviewStageStateProvider
import com.opencapture.opencine.appkit.MultiviewNetworkRestore
import com.opencapture.opencine.appkit.MultiviewStageActions
import com.opencapture.opencine.appkit.MultiviewTally
import com.opencapture.opencine.media.storageReadout
import com.opencapture.opencine.appkit.MultiviewTile
import com.opencapture.opencine.appkit.MultiviewTileStatus
import com.opencapture.opencine.appkit.MultiviewTool
import com.opencapture.opencine.core.Availability
import com.opencapture.opencine.core.ISOValue
import com.opencapture.opencine.core.MonitorEntryID
import com.opencapture.opencine.core.SettingKey
import com.opencapture.opencine.core.SettingValue
import com.opencapture.opencine.core.WhiteBalanceValue
import com.opencapture.opencine.nikon.NikonCameraBatteryGauge
import kotlinx.coroutines.delay
import com.opencapture.opencine.nikon.SavedCameraRecord

/** One saved body offered by Add camera; [refusal] says why it cannot join, null when it can. */
data class MulticamPickerRow(val record: SavedCameraRecord, val refusal: String?)

/**
 * The multicam stage (Android twin of iOS `MulticamStage`): OpenCine's shared Multiview stage over
 * this app's members. Membership, the eligible-subset record plan, per-member results and
 * property writes stay in [MulticamCoordinator].
 */
@Composable
fun MulticamStage(
    coordinator: MulticamCoordinator,
    confirmsRecord: Boolean,
    pickerRows: () -> List<MulticamPickerRow>,
    openLiveView: (MonitorEntryID) -> Unit,
    close: () -> Unit,
) {
    var adding by remember { mutableStateOf<Int?>(null) }
    var leaving by remember { mutableStateOf(false) }
    val fill = coordinator.presentation.fill
    BackHandler(enabled = coordinator.lent == null && com.opencapture.opencine.appkit.LocalMultiviewStageVisible.current) { leaving = true }
    MultiviewStageSurface(coordinator.arrangement, coordinator.focusedSlot,
        // The stage covers Your cameras; it takes every touch that no control of its own takes.
        Modifier.fillMaxSize().background(MonitorPalette.backgroundDeep).pointerInput(Unit) { detectTapGestures {} }
            .testTag("multicam.stage"),
    ) { viewport ->
        val layout = viewport.layout
        MultiviewStageStateProvider(coordinator.presentation) {
        MultiviewStage(
            tiles = (0 until MulticamCoordinator.TILES).map { slot -> coordinator.memberAt(slot)?.let { tile(it, coordinator) } },
            layout = layout, arrangement = coordinator.arrangement, selected = coordinator.focusedSlot, fill = fill,
            tools = listOf(MultiviewTool.LAYOUT, MultiviewTool.FIT),
            readouts = coordinator.program?.takeIf { it.isLive }?.let { readouts(it, coordinator) },
            recording = coordinator.anyRecording, groupBusy = coordinator.groupBusy, confirmsRecord = confirmsRecord,
            actions = MultiviewStageActions(
                select = coordinator::select,
                arrange = { coordinator.arrangement = it },
                setFill = { coordinator.presentation.fill = it },
                openLiveView = { slot -> coordinator.memberAt(slot)?.let { openLiveView(it.id) } },
                add = { adding = it },
                perform = { action, slot ->
                    coordinator.memberAt(slot)?.let { member ->
                        when (action) {
                            MulticamTileAction.RECONNECT -> coordinator.retry(member.id)
                            MulticamTileAction.REMOVE -> coordinator.remove(member.id)
                        }
                    }
                },
                close = { leaving = true },
                recordContext = { slot ->
                    val plan = slot?.let(coordinator::memberAt)?.let { coordinator.plan(it.id) } ?: coordinator.groupPlan()
                    MultiviewRecordContext(plan, busy = coordinator.groupBusy)
                },
                record = { plan, slot -> coordinator.start(plan, together = slot == null) },
                // The value the operator picked, by the name shown: one no longer advertised writes nothing.
                choose = { slot, readout, choice ->
                    coordinator.memberAt(slot)?.takeIf { readout == 0 || readout == 2 }?.let { member ->
                        val key = if (readout == 0) SettingKey.ISO else SettingKey.WHITE_BALANCE
                        choices(key, member, coordinator).firstOrNull { it.second == choice }
                            ?.let { (value, _) -> coordinator.set(value, member.id, if (readout == 0) "ISO" else "WB") }
                    }
                },
            ),
        ) { slot ->
            coordinator.memberAt(slot)?.frame?.let {
                Image(it, null, Modifier.fillMaxSize(), contentScale = if (fill) ContentScale.Crop else ContentScale.Fit)
            }
        }
        }
        coordinator.toast?.let { text ->
            LaunchedEffect(text) {
                delay(4_000)
                if (coordinator.toast == text) coordinator.toast = null
            }
            Text(
                text,
                style = MonitorTypography.text(13f, FontWeight.Medium),
                modifier =
                    Modifier.align(Alignment.TopCenter).padding(top = viewport.safeArea.top.dp + 24.dp)
                        .widthIn(max = 420.dp).monitorMaterial(MonitorMaterial.Info, CircleShape)
                        .clickable { coordinator.toast = null }.padding(horizontal = 16.dp, vertical = 10.dp)
                        .testTag("multicam.toast"),
            )
        }
        adding?.let { slot ->
            val rows = pickerRows()
            MultiviewCameraPicker(
                rows = rows.mapIndexed { index, row ->
                    MultiviewPickerRow(
                        index.toString(), row.record.customName ?: row.record.cameraName,
                        detail = row.refusal ?: row.record.transport.displayName, enabled = row.refusal == null,
                    )
                },
                onCancel = { adding = null },
                onPick = { id ->
                    rows.getOrNull(id.toInt())?.let { row ->
                        adding = null
                        coordinator.add(row.record, reachable = true, slot = slot)
                    }
                },
                empty = MulticamCopy.EMPTY_PICKER,
            )
        }
    }
    if (leaving) {
        AlertDialog(
            onDismissRequest = { leaving = false },
            text = { Text(MultiviewNetworkRestore.NONE.closeQuestion) },
            confirmButton = {
                TextButton(onClick = {
                    leaving = false
                    close()
                }) { Text(MultiviewNetworkRestore.CLOSE_ACTION) }
            },
            dismissButton = { TextButton(onClick = { leaving = false }) { Text("Cancel") } },
        )
    }
}

/** This app's camera option ids beside the shared Live View id. */
private object MulticamTileAction {
    const val RECORD = "record"
    const val RECONNECT = "reconnect"
    const val REMOVE = "remove"
}

/** The member's values as the shared stage shows them; unknown stays unknown. */
internal fun tile(member: MulticamMember, coordinator: MulticamCoordinator): MultiviewTile {
    val rolling = member.recording.takeIf { member.isLive }
    val (status, detail) = when (val state = member.status) {
        MemberStatus.Live -> null to "Connected"
        MemberStatus.Connecting -> MultiviewTileStatus("Connecting…", inProgress = true) to "Connecting…"
        is MemberStatus.Failed -> MultiviewTileStatus(
            state.reason, inProgress = false,
            actions = listOf(
                MultiviewCameraAction(MulticamTileAction.RECONNECT, "Reconnect"),
                MultiviewCameraAction(MulticamTileAction.REMOVE, "Remove", MultiviewCameraAction.Kind.DESTRUCTIVE),
            ),
        ) to state.reason
    }
    val battery = com.opencapture.opencine.cameracontrols.cameraPowerReading(member.batteryReading)
    return MultiviewTile(
        storage = member.control?.refresh()?.storage?.storageReadout?.free ?: MultiviewTally.UNAVAILABLE,
        name = member.displayName, model = member.record.transport.displayName,
        // The body's five-step gauge (A5-01): bars, never a percent it did not report.
        batteryBars = battery?.bars,
        batteryBarCount = battery?.barCount ?: NikonCameraBatteryGauge.BAR_COUNT,
        timecode = member.timecode,
        tally = MultiviewTally.text(rolling, waiting = coordinator.groupBusy),
        // Nikon reports no take length: the tile times it from the first recording frame.
        recordingSince = member.recordingSinceMillis.takeIf { rolling == true && !coordinator.groupBusy },
        recording = member.recording == true, note = member.note, tileNote = member.note,
        readouts = readouts(member, coordinator), status = status, detail = detail,
        failure = (member.status as? MemberStatus.Failed)?.reason,
        actions = listOf(
            MultiviewCameraAction(MultiviewCameraAction.LIVE_VIEW, "Open Live View", enabled = member.isLive),
            MultiviewCameraAction(
                MulticamTileAction.RECORD, if (member.recording == true) "Stop recording" else "Start recording",
                MultiviewCameraAction.Kind.RECORD,
                enabled = member.isLive && !coordinator.groupBusy && coordinator.plan(member.id).isExecutable,
            ),
            MultiviewCameraAction(MulticamTileAction.RECONNECT, "Reconnect", closes = true),
            MultiviewCameraAction(MulticamTileAction.REMOVE, "Remove camera", MultiviewCameraAction.Kind.DESTRUCTIVE),
        ),
        accessibilityValue = detail,
    )
}

/**
 * ISO, shutter, white balance and focus as read back from the camera. ISO and white balance offer
 * the camera's own advertised choices; picking one writes to that camera only.
 */
private fun readouts(member: MulticamMember, coordinator: MulticamCoordinator): List<MultiviewReadout> {
    val properties = member.properties
    return listOf(
        MultiviewReadout(
            "ISO", properties.iso?.toString() ?: MultiviewTally.UNAVAILABLE,
            choices(SettingKey.ISO, member, coordinator).map { it.second },
        ),
        MultiviewReadout("SHUTTER", properties.shutterAngle ?: properties.shutterSpeed ?: MultiviewTally.UNAVAILABLE),
        MultiviewReadout(
            "WB", properties.whiteBalanceKelvin?.let { "${it}K" } ?: properties.whiteBalanceMode ?: MultiviewTally.UNAVAILABLE,
            choices(SettingKey.WHITE_BALANCE, member, coordinator).map { it.second },
        ),
        MultiviewReadout("FOCUS", properties.focusMode ?: MultiviewTally.UNAVAILABLE),
    )
}

/** What the camera advertises for [key], with the name the stage shows. */
private fun choices(key: SettingKey, member: MulticamMember, coordinator: MulticamCoordinator): List<Pair<SettingValue, String>> =
    coordinator.descriptor(key, member)?.takeIf { it.availability == Availability.Available }?.domain?.choices.orEmpty()
        .mapNotNull { choice ->
            val name = when (choice) {
                is SettingValue.Iso -> (choice.value as? ISOValue.Manual)?.iso?.toString()
                is SettingValue.WhiteBalance -> when (val wb = choice.value) {
                    is WhiteBalanceValue.Preset -> wb.id
                    WhiteBalanceValue.Auto -> "Auto"
                    else -> null
                }
                else -> null
            }
            name?.let { choice to it }
        }

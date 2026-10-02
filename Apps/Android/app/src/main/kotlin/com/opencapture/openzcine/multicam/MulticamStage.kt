package com.opencapture.openzcine.multicam

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.requiredSize
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.opencapture.monitorui.MonitorIcon
import com.opencapture.monitorui.MonitorMaterial
import com.opencapture.monitorui.MonitorPalette
import com.opencapture.monitorui.MonitorRecordLamp
import com.opencapture.monitorui.MonitorRect
import com.opencapture.monitorui.MonitorTypography
import com.opencapture.monitorui.MultiviewArrangement
import com.opencapture.monitorui.MultiviewPresentationLayout
import com.opencapture.monitorui.MultiviewSafeArea
import com.opencapture.monitorui.monitorMaterial
import com.opencapture.opencine.core.Availability
import com.opencapture.opencine.core.ISOValue
import com.opencapture.opencine.core.MonitorEntryID
import com.opencapture.opencine.core.SettingKey
import com.opencapture.opencine.core.SettingValue
import com.opencapture.opencine.core.WhiteBalanceValue
import com.opencapture.opencine.multicam.RecordDirection
import com.opencapture.opencine.multicam.RecordPlan
import com.opencapture.openzcine.pairing.SavedCameraRecord
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/** One saved body offered by Add camera; [refusal] says why it cannot join, null when it can. */
data class MulticamPickerRow(val record: SavedCameraRecord, val refusal: String?)

/**
 * The multicam stage (Android twin of iOS `MulticamStage`): four fixed tiles laid out by the
 * shared `MultiviewPresentationLayout` (Grid / Center stage), drawn with monitor-ui chrome.
 */
@Composable
fun MulticamStage(
    coordinator: MulticamCoordinator,
    confirmsRecord: Boolean,
    pickerRows: () -> List<MulticamPickerRow>,
    openLiveView: (MonitorEntryID) -> Unit,
    close: () -> Unit,
) {
    val scope = rememberCoroutineScope()
    var adding by remember { mutableStateOf<Int?>(null) }
    var clean by remember { mutableStateOf(false) }
    var confirming by remember { mutableStateOf<RecordPlan?>(null) }
    var leaving by remember { mutableStateOf(false) }
    val insets = WindowInsets.safeDrawing.asPaddingValues()
    val direction = LocalLayoutDirection.current
    BackHandler { leaving = true }
    BoxWithConstraints(
        // The stage covers Your cameras; it takes every touch that no control of its own takes.
        Modifier.fillMaxSize().background(MonitorPalette.backgroundDeep).pointerInput(Unit) { detectTapGestures {} }
            .testTag("multicam.stage"),
    ) {
        val layout =
            MultiviewPresentationLayout.compute(
                maxWidth.value, maxHeight.value,
                MultiviewSafeArea(
                    insets.calculateTopPadding().value, insets.calculateLeftPadding(direction).value,
                    insets.calculateBottomPadding().value, insets.calculateRightPadding(direction).value,
                ),
                coordinator.arrangement, coordinator.focusedSlot,
            )
        val strip = if (layout.secondaryViewport != null) layout.secondaryIndices else emptyList()
        for (slot in 0 until MulticamCoordinator.TILES) {
            if (slot in strip) continue
            Tile(layout, slot, coordinator, clean, openLiveView) { adding = slot }
        }
        layout.secondaryViewport?.let { viewport ->
            // Center stage's trailing strip scrolls inside its viewport.
            val height = strip.maxOf { layout.tiles[it].maxY } - viewport.y
            Box(Modifier.at(viewport).verticalScroll(rememberScrollState())) {
                Box(Modifier.requiredSize(viewport.width.dp, height.dp)) {
                    for (slot in strip) {
                        Tile(layout, slot, coordinator, clean, openLiveView, origin = viewport) { adding = slot }
                    }
                }
            }
        }
        if (!clean) {
            ChromeButton(layout.sessionControls, MonitorIcon.X, "Close multicam") { leaving = true }
            ChromeButton(
                layout.network,
                if (coordinator.arrangement == MultiviewArrangement.GRID) MonitorIcon.LAYOUT_LIST else MonitorIcon.LAYOUT_GRID,
                if (coordinator.arrangement == MultiviewArrangement.GRID) "Center stage" else "Grid",
            ) {
                coordinator.arrangement =
                    if (coordinator.arrangement == MultiviewArrangement.GRID) {
                        MultiviewArrangement.CENTER_STAGE
                    } else {
                        MultiviewArrangement.GRID
                    }
            }
            coordinator.program?.takeIf { it.isLive }?.let { program ->
                Values(program, coordinator, Modifier.at(layout.readouts))
            }
        }
        ChromeButton(layout.display, if (clean) MonitorIcon.EYE_OFF else MonitorIcon.EYE, "DISP", active = clean) {
            clean = !clean
        }
        val enabled = coordinator.canRecord
        Box(
            Modifier.at(layout.record).clickable(enabled = enabled) {
                val plan = coordinator.groupPlan()
                when {
                    !plan.isExecutable -> coordinator.toast = MulticamCopy.COULDNT_REC
                    confirmsRecord -> confirming = plan
                    else -> scope.launch { coordinator.run(plan) }
                }
            }.semantics {
                contentDescription = if (coordinator.anyRecording) "Stop recording on all" else "Record on all"
            }.testTag("multicam.record"),
        ) {
            MonitorRecordLamp(coordinator.anyRecording, Modifier.fillMaxSize())
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
                    Modifier.align(Alignment.TopCenter).padding(top = insets.calculateTopPadding() + 24.dp)
                        .widthIn(max = 420.dp).monitorMaterial(MonitorMaterial.Info, CircleShape)
                        .clickable { coordinator.toast = null }.padding(horizontal = 16.dp, vertical = 10.dp)
                        .testTag("multicam.toast"),
            )
        }
        adding?.let { slot ->
            Picker(
                pickerRows(),
                pick = { record ->
                    adding = null
                    coordinator.add(record, reachable = true, slot = slot)
                },
                dismiss = { adding = null },
            )
        }
    }
    confirming?.let { plan ->
        AlertDialog(
            onDismissRequest = { confirming = null },
            text = { Text(MulticamCopy.confirm(plan.direction, coordinator.names(plan))) },
            confirmButton = {
                TextButton(onClick = {
                    confirming = null
                    scope.launch { coordinator.run(plan) }
                }) { Text(if (plan.direction == RecordDirection.STOP) "Stop recording" else "Start recording") }
            },
            dismissButton = { TextButton(onClick = { confirming = null }) { Text("Cancel") } },
        )
    }
    if (leaving) {
        AlertDialog(
            onDismissRequest = { leaving = false },
            text = { Text("Close multicam? Recording continues on every camera.") },
            confirmButton = {
                TextButton(onClick = {
                    leaving = false
                    close()
                }) { Text("Close multicam") }
            },
            dismissButton = { TextButton(onClick = { leaving = false }) { Text("Cancel") } },
        )
    }
}

private fun Modifier.at(rect: MonitorRect, origin: MonitorRect? = null): Modifier =
    offset((rect.x - (origin?.x ?: 0f)).dp, (rect.y - (origin?.y ?: 0f)).dp).requiredSize(rect.width.dp, rect.height.dp)

@Composable
private fun ChromeButton(
    rect: MonitorRect,
    icon: MonitorIcon,
    label: String,
    active: Boolean = false,
    action: () -> Unit,
) {
    val shape = RoundedCornerShape(14.dp)
    Box(
        Modifier.at(rect).monitorMaterial(MonitorMaterial.Compact, shape)
            .then(if (active) Modifier.border(1.5.dp, MonitorPalette.accent.copy(alpha = .75f), shape) else Modifier)
            .clickable(onClick = action).semantics { contentDescription = label },
        contentAlignment = Alignment.Center,
    ) {
        MonitorIcon(icon, null, Modifier.size(20.dp), tint = if (active) MonitorPalette.accent else MonitorPalette.text)
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun Tile(
    layout: MultiviewPresentationLayout,
    slot: Int,
    coordinator: MulticamCoordinator,
    clean: Boolean,
    openLiveView: (MonitorEntryID) -> Unit,
    origin: MonitorRect? = null,
    add: () -> Unit,
) {
    val frame = layout.tiles[slot]
    val member = coordinator.memberAt(slot)
    val selected = slot == coordinator.focusedSlot
    val compact = frame.width < 200f || frame.height < 136f
    // The program values sit inside the selected tile in landscape and Grid: its footer rides above.
    val footerInset = if (selected && layout.readoutsOverlay && !clean) maxOf(0f, frame.maxY - layout.readouts.y) else 0f
    var menu by remember { mutableStateOf(false) }
    val shape = RoundedCornerShape(10.dp)
    Box(
        Modifier.at(frame, origin).background(MonitorPalette.surface, shape)
            .border(if (selected) 1.5.dp else 1.dp, if (selected) MonitorPalette.accent else MonitorPalette.border, shape)
            .combinedClickable(
                onClick = { if (member == null) add() else coordinator.select(slot) },
                onDoubleClick = { member?.let { openLiveView(it.id) } },
                onLongClick = { if (member != null) menu = true },
            ).testTag("multicam.tile.$slot"),
    ) {
        if (member == null) {
            Column(Modifier.align(Alignment.Center), horizontalAlignment = Alignment.CenterHorizontally) {
                MonitorIcon(MonitorIcon.PLUS, null, Modifier.size(18.dp), tint = MonitorPalette.secondary)
                Text("Add camera", style = MonitorTypography.text(if (compact) 11f else 13f, FontWeight.SemiBold).copy(color = MonitorPalette.secondary))
            }
            return@Box
        }
        member.frame?.let { Image(it, null, Modifier.fillMaxSize(), contentScale = ContentScale.Fit) }
        val style = MonitorTypography.readout(if (compact) 10f else 12f, FontWeight.SemiBold)
        Column(Modifier.fillMaxSize().padding(if (compact) 6.dp else 10.dp)) {
            Row {
                Column(Modifier.weight(1f)) {
                    Text("${member.letter}  ${member.displayName}", style = style, maxLines = 1)
                    member.note?.let { Text(it, style = style.copy(color = MonitorPalette.recording)) }
                }
                member.batteryPercent?.let { battery ->
                    val tint = when {
                        battery <= 20 -> MonitorPalette.recording
                        battery <= 40 -> MonitorPalette.digitalCrop
                        else -> MonitorPalette.text
                    }
                    Text("$battery%", style = style.copy(color = tint))
                }
            }
            Spacer(Modifier.weight(1f))
            Row(Modifier.padding(bottom = footerInset.dp)) {
                Text(member.timecode.orEmpty(), style = style, modifier = Modifier.weight(1f))
                Text(tally(member, coordinator.groupBusy), style = style.copy(color = if (member.recording == true) MonitorPalette.recording else MonitorPalette.text))
            }
        }
        when (val status = member.status) {
            MemberStatus.Connecting ->
                Text("Connecting…", style = style.copy(color = MonitorPalette.secondary), modifier = Modifier.align(Alignment.Center))
            is MemberStatus.Failed ->
                Column(Modifier.align(Alignment.Center), horizontalAlignment = Alignment.CenterHorizontally) {
                    Text(status.reason, style = style.copy(color = MonitorPalette.secondary))
                    TextButton(onClick = { coordinator.retry(member.id) }) {
                        Text("Retry", style = style.copy(color = MonitorPalette.accent))
                    }
                }
            MemberStatus.Live -> Unit
        }
        val scope = rememberCoroutineScope()
        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
            if (member.isLive) {
                DropdownMenuItem(text = { Text("Open Live View") }, onClick = {
                    menu = false
                    openLiveView(member.id)
                })
                DropdownMenuItem(
                    text = { Text(if (member.recording == true) "Stop recording" else "Start recording") },
                    onClick = {
                        menu = false
                        scope.launch { coordinator.run(coordinator.plan(member.id)) }
                    },
                )
            }
            DropdownMenuItem(text = { Text("Reconnect") }, onClick = {
                menu = false
                coordinator.retry(member.id)
            })
            DropdownMenuItem(text = { Text("Remove camera") }, onClick = {
                menu = false
                coordinator.remove(member.id)
            })
        }
    }
}

/** `REC mm:ss` while rolling (timed from the take's first recording frame), else STBY. */
@Composable
private fun tally(member: MulticamMember, busy: Boolean): String {
    if (busy) return "WAIT"
    val recording = member.recording?.takeIf { member.isLive } ?: return "-"
    if (!recording) return "STBY"
    val since = member.recordingSinceMillis ?: return "REC"
    var now by remember { mutableStateOf(System.currentTimeMillis()) }
    LaunchedEffect(since) {
        while (true) {
            now = System.currentTimeMillis()
            delay(1_000)
        }
    }
    val seconds = maxOf(0L, (now - since) / 1_000)
    return "REC %02d:%02d".format(seconds / 60, seconds % 60)
}

/**
 * The program camera's values. ISO and white balance open that camera's own advertised choices
 * and write to it only; its readback decides what shows.
 */
@Composable
private fun Values(member: MulticamMember, coordinator: MulticamCoordinator, modifier: Modifier) {
    val properties = member.properties
    Row(
        modifier.monitorMaterial(MonitorMaterial.Compact, RoundedCornerShape(10.dp)).padding(horizontal = 10.dp),
        horizontalArrangement = Arrangement.spacedBy(18.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Value("ISO", properties.iso?.toString(), coordinator, member, SettingKey.ISO) {
            ((it as? SettingValue.Iso)?.value as? ISOValue.Manual)?.iso?.toString()
        }
        Value("SHUTTER", properties.shutterAngle ?: properties.shutterSpeed, coordinator, member)
        Value(
            "WB", properties.whiteBalanceKelvin?.let { "${it}K" } ?: properties.whiteBalanceMode,
            coordinator, member, SettingKey.WHITE_BALANCE,
        ) {
            when (val wb = (it as? SettingValue.WhiteBalance)?.value) {
                is WhiteBalanceValue.Preset -> wb.id
                WhiteBalanceValue.Auto -> "Auto"
                else -> null
            }
        }
        Value("FOCUS", properties.focusMode, coordinator, member)
    }
}

@Composable
private fun Value(
    title: String,
    text: String?,
    coordinator: MulticamCoordinator,
    member: MulticamMember,
    key: SettingKey? = null,
    label: ((SettingValue) -> String?)? = null,
) {
    var open by remember { mutableStateOf(false) }
    val descriptor = key?.let { coordinator.descriptor(it, member) }
    val choices =
        descriptor?.takeIf { it.availability == Availability.Available }?.domain?.choices.orEmpty()
            .mapNotNull { choice -> label?.invoke(choice)?.let { choice to it } }
    Box {
        Column(
            Modifier.then(if (choices.isNotEmpty()) Modifier.clickable { open = true } else Modifier)
                .testTag("multicam.value.${title.lowercase()}"),
        ) {
            Text(title, style = MonitorTypography.text(8f, FontWeight.Bold).copy(color = MonitorPalette.faint))
            Text(text ?: "-", style = MonitorTypography.readout(13f, FontWeight.SemiBold), maxLines = 1)
        }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            for ((choice, name) in choices) {
                DropdownMenuItem(text = { Text(name) }, onClick = {
                    open = false
                    coordinator.set(choice, member.id, title)
                })
            }
        }
    }
}

/** Saved bodies, one row per setup; the ones that cannot join say why. */
@Composable
private fun Picker(rows: List<MulticamPickerRow>, pick: (SavedCameraRecord) -> Unit, dismiss: () -> Unit) {
    Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = .35f)).clickable(onClick = dismiss)) {
        Column(
            Modifier.align(Alignment.Center).widthIn(max = 420.dp).padding(24.dp)
                .background(MonitorPalette.surface, RoundedCornerShape(16.dp)).padding(18.dp)
                .testTag("multicam.picker"),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Text("Add camera", style = MonitorTypography.text(16f, FontWeight.SemiBold))
            if (rows.isEmpty()) {
                Text(MulticamCopy.EMPTY_PICKER, style = MonitorTypography.text(13f).copy(color = MonitorPalette.muted))
            }
            Column(Modifier.heightIn(max = 320.dp).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                for (row in rows) {
                    Column(
                        Modifier.fillMaxWidth().background(MonitorPalette.tile, RoundedCornerShape(10.dp))
                            .clickable(enabled = row.refusal == null) { pick(row.record) }.padding(12.dp),
                    ) {
                        val alpha = if (row.refusal == null) 1f else .5f
                        Text(row.record.customName ?: row.record.cameraName, style = MonitorTypography.text(14f, FontWeight.SemiBold).copy(color = MonitorPalette.text.copy(alpha = alpha)))
                        Text(row.refusal ?: row.record.transport.displayName, style = MonitorTypography.text(12f).copy(color = MonitorPalette.muted.copy(alpha = alpha)))
                    }
                }
            }
        }
    }
}

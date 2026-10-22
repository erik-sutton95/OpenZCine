package com.opencapture.openzcine

import android.graphics.Bitmap
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.relocation.BringIntoViewRequester
import androidx.compose.foundation.relocation.bringIntoViewRequester
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/** Display-only projection of the shared Swift controller. No position or timing policy lives here. */
internal data class FocusRackViewState(
    val phase: String = "idle", val message: String = "Connect a camera to set focus marks.",
    val recovery: String? = null, val error: String? = null, val admissionMessage: String? = null,
    val position: Int? = null, val marks: List<FocusRackMarkViewState> = emptyList(),
    val fromMark: String = "A", val toMark: String = "B", val duration: Double = 3.0,
    val delay: Double = 0.0, val easing: String = "linear", val durationMode: String = "timed",
    val estimatedDuration: Double? = null,
    val primaryTitle: String = "Set A and B", val primaryEnabled: Boolean = false,
    val primaryDetail: String? = null, val primaryDisabledReason: String? = null,
    val pullAToB: FocusRackActionViewState? = null, val pullBToA: FocusRackActionViewState? = null,
    val calibration: FocusRackActionViewState? = null,
    val playbackInstruction: String? = null,
    val canGoToA: Boolean = false, val canGoToB: Boolean = false,
    val canCaptureA: Boolean = false, val canCaptureB: Boolean = false, val canNudge: Boolean = false, val canEdit: Boolean = false,
    val canReset: Boolean = false, val canAutofocus: Boolean = false, val canPause: Boolean = false, val canStop: Boolean = false, val active: Boolean = false,
    val completed: Int = 0, val total: Int = 0, val minimumDuration: Double? = null,
    val captureRevision: Long = 0, val remainingDelay: Double = 0.0,
    val nudgeProgress: FocusRackNudgeProgressViewState? = null,
)
/** Acknowledged setup progress supplied by Swift, never estimated by the shell. */
internal data class FocusRackNudgeProgressViewState(val towardNear: Boolean, val steps: Int, val percent: Int)
internal data class FocusRackActionViewState(val title: String, val detail: String?, val enabled: Boolean,
    val disabledReason: String? = null)
internal data class FocusRackMarkViewState(val id: String, val position: Int, val revision: Long,
    val sessionID: String, val frameSequence: Long)
internal data class FocusRackTimingViewState(val name: String, val json: String)

/** Only edited fields cross the queued boundary; Swift merges and validates them. */
internal data class FocusRackTimingEdit(val duration: String? = null, val delay: String? = null,
    val easing: String? = null, val durationMode: String? = null, val reverse: Boolean? = null)

/** Native editor and compact transport. Actions are semantic intents to the Swift owner. */
@Composable
internal fun FocusRackPanel(state: FocusRackViewState, thumbnails: Map<String, Bitmap>,
    templates: List<FocusRackTimingViewState>, compact: Boolean, maximumHeight: Float,
    expanded: Boolean, onExpanded: (Boolean) -> Unit, onCapture: (String) -> Unit,
    onNudge: (Boolean, Int) -> Unit, onTiming: (FocusRackTimingEdit) -> Unit,
    onPrimary: () -> Unit, onStop: () -> Unit, onReset: () -> Unit,
    onSave: (String) -> Unit, onLoad: (FocusRackTimingViewState) -> Unit,
    onDelete: (FocusRackTimingViewState) -> Unit, onFocusSettings: () -> Unit,
    setupEnabled: Boolean = true, onClose: () -> Unit = {},
    onGoTo: (String) -> Unit = {}, onRun: (String) -> Unit = {}, onMovePanel: (Offset) -> Unit = {}, onResetPanel: () -> Unit = {},
    onCalibrate: () -> Unit = {},
) {
    var optionsExpanded by remember { mutableStateOf(false) }
    val nudging = state.nudgeProgress != null
    val directPulls = !state.active && state.position != null && state.marks.size == 2 &&
        state.pullAToB != null && state.pullBToA != null
    val compactPositioning = compact && directPulls && setupEnabled &&
        state.pullAToB?.enabled != true && state.pullBToA?.enabled != true
    var editingField by remember { mutableStateOf<String?>(null) }
    var editText by remember { mutableStateOf("") }
    var confirmClose by remember { mutableStateOf(false) }
    val setupScroll = rememberScrollState()
    val admissionAttention = remember { BringIntoViewRequester() }
    var showAdmission by remember { mutableStateOf(false) }
    val panelDensity = LocalDensity.current.density
    val movePanel by rememberUpdatedState(onMovePanel)
    val shape = RoundedCornerShape(12.dp)
    MaterialTheme(colorScheme = darkColorScheme(primary = Color(0xFFD8B16B), onPrimary = Color.Black,
        surface = Color(0xFF181B20), onSurface = Color.White, background = Color(0xFF181B20))) {
    Column(Modifier.fillMaxWidth().heightIn(max = maximumHeight.dp).clip(shape)
        .background(Color(0xF0181B20)).padding(horizontal = 10.dp, vertical = if (compact) 4.dp else 8.dp)
        .testTag("focusRack.panel"), verticalArrangement = Arrangement.spacedBy(if (compact) 2.dp else 6.dp)) {
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(4.dp),
            verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f).heightIn(min = 48.dp)
                .clickable(enabled = setupEnabled && !nudging) {
                    if (state.admissionMessage != null) {
                        onExpanded(true)
                        showAdmission = true
                    }
                }
                .pointerInput(setupEnabled, panelDensity) {
                    if (setupEnabled) detectDragGestures { change, amount ->
                        change.consume()
                        movePanel(amount / panelDensity)
                    }
                }
                .testTag("focusRack.dragHandle")
                .semantics {
                    contentDescription = "Move Focus Rack panel"
                    customActions = if (!setupEnabled) emptyList() else listOf(
                        CustomAccessibilityAction("Move panel left") { onMovePanel(Offset(-80f, 0f)); true },
                        CustomAccessibilityAction("Move panel right") { onMovePanel(Offset(80f, 0f)); true },
                        CustomAccessibilityAction("Move panel up") { onMovePanel(Offset(0f, -80f)); true },
                        CustomAccessibilityAction("Move panel down") { onMovePanel(Offset(0f, 80f)); true },
                        CustomAccessibilityAction("Reset panel position") { onResetPanel(); true })
                }, verticalArrangement = Arrangement.Center) {
                Text(if (compact) when (state.phase) {
                    "countdown" -> "Starts in ${"%.1f".format(state.remainingDelay)} s"
                    "pausing" -> "Pausing…"
                    "paused" -> "Paused"
                    "stopping" -> "Stopping…"
                    "moving" -> if (state.total > 0) "Focus Rack · ${state.completed * 100 / state.total}%" else "Moving focus"
                    "complete" -> "Complete"
                    "uncertain" -> "Reference uncertain"
                    "stopUnconfirmed" -> "Stop unconfirmed"
                    "refused" -> "Camera busy"
                    "failed" -> "Move stopped"
                    else -> "Focus Rack"
                } else if (state.admissionMessage != null && state.canEdit) "Move needs attention" else "⠿ Focus Rack",
                    color = Color.White, fontSize = 12.sp)
                if (!compact && state.admissionMessage == null) Text(state.playbackInstruction ?: "Drag to move",
                    color = Color.LightGray, fontSize = 10.sp)
            }
            TextButton(onClick = { onExpanded(!expanded) }, enabled = setupEnabled && !nudging,
                modifier = Modifier.width(48.dp).heightIn(min = 48.dp).testTag("focusRack.expand")
                    .semantics { contentDescription = if (expanded && !compact) "Collapse focus rack" else "Open focus rack setup" },
                contentPadding = PaddingValues(0.dp)) {
                Text(if (expanded && !compact) "⌄" else "⌃", fontSize = 22.sp)
            }
            TextButton(onClick = { confirmClose = true }, enabled = !state.active && setupEnabled,
                modifier = Modifier.width(48.dp).heightIn(min = 48.dp).testTag("focusRack.close")
                    .semantics { contentDescription = "Close Focus Rack" },
                contentPadding = PaddingValues(0.dp)) { Text("×", fontSize = 24.sp) }
        }
        if (!compact) {
                Column(Modifier.fillMaxWidth().padding(vertical = 4.dp).testTag("focusRack.marks"),
                    verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    if ((state.position != null && !state.active) || nudging) {
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        listOf("A", "B").forEach { id ->
                            val mark = state.marks.firstOrNull { it.id == id }
                            val canUse = if (mark == null) {
                                if (id == "A") state.canCaptureA else state.canCaptureB
                            } else if (id == "A") state.canGoToA else state.canGoToB
                            OutlinedButton(onClick = { if (mark == null) onCapture(id) else onGoTo(id) },
                                enabled = setupEnabled && canUse && !nudging,
                                modifier = Modifier.weight(1f).heightIn(min = 56.dp)
                                    .testTag("focusRack.${if (mark == null) "capture" else "go"}.$id"),
                                contentPadding = PaddingValues(horizontal = 6.dp, vertical = 4.dp)) {
                                Box(Modifier.size(32.dp, 40.dp).clip(RoundedCornerShape(5.dp))
                                    .background(Color.White.copy(alpha = 0.08f)), contentAlignment = Alignment.Center) {
                                    thumbnails[id]?.let { image -> Image(image.asImageBitmap(),
                                        "$id focus mark", Modifier.fillMaxSize()) } ?: Text(id, fontSize = 18.sp)
                                }
                                Spacer(Modifier.width(6.dp))
                                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                                    Text(if (mark == null) "Set $id" else "Go to $id", fontSize = 12.sp, lineHeight = 14.sp)
                                    if (mark != null) Text("Fast reposition", fontSize = 10.sp, lineHeight = 12.sp, color = Color.LightGray)
                                    Text(mark?.let { "${it.position} steps" } ?: "Not set", fontSize = 11.sp, lineHeight = 13.sp,
                                        color = Color.LightGray)
                                }
                            }
                        }
                    }
                    }
                    val positions = if (state.position == null) "Positions unknown · Reset marks" else {
                        val a = state.marks.firstOrNull { it.id == "A" }?.position?.toString() ?: "—"
                        val b = state.marks.firstOrNull { it.id == "B" }?.position?.toString() ?: "—"
                        "A $a · B $b · Now ${state.position}"
                    }
                    Text(positions, color = Color.LightGray, fontSize = 11.sp, lineHeight = 14.sp,
                        fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace,
                        modifier = Modifier.fillMaxWidth().testTag("focusRack.positions")
                            .semantics { contentDescription = "Relative focus steps: $positions" })
                }
            Column(Modifier.weight(1f, fill = false).verticalScroll(setupScroll)
                .testTag("focusRack.setup").semantics { contentDescription = "Focus rack setup" }, verticalArrangement = Arrangement.spacedBy(8.dp)) {
                FocusRackNudgeControls(state.canNudge && !nudging, state.nudgeProgress, onNudge)
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    listOf("duration" to "Duration", "delay" to "Start delay").forEach { (field, label) ->
                        OutlinedButton(onClick = { editingField = field
                            editText = (if (field == "duration") state.duration else state.delay).toString() },
                            enabled = state.canEdit && !nudging, modifier = Modifier.weight(1f).heightIn(min = 48.dp)
                                .testTag("focusRack.$field"), contentPadding = PaddingValues(4.dp)) {
                            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                                Text(label, fontSize = 11.sp, lineHeight = 14.sp)
                                Text("${if (field == "duration") state.duration else state.delay} s", fontSize = 15.sp, lineHeight = 18.sp)
                            }
                        }
                    }
                }
                TextButton(onClick = { optionsExpanded = !optionsExpanded }, enabled = !nudging,
                    modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp).testTag("focusRack.options")) {
                    Text("Options · Linear")
                    Spacer(Modifier.weight(1f))
                    Text(if (optionsExpanded) "⌃" else "⌄")
                }
                if (optionsExpanded) {
                    Text("Set A, adjust with Near/Far, then set B. Keep zoom and the focus ring fixed.",
                        color = Color.LightGray, fontSize = 11.sp)
                    state.calibration?.let { action ->
                        OutlinedButton(onClick = onCalibrate,
                            enabled = action.enabled && !state.active && !nudging && setupEnabled,
                            modifier = Modifier.fillMaxWidth().heightIn(min = 56.dp).testTag("focusRack.calibrate"),
                            contentPadding = PaddingValues(horizontal = 8.dp, vertical = 6.dp)) {
                            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                                Text(action.title, fontSize = 12.sp, lineHeight = 16.sp)
                                action.detail?.let { Text(it, fontSize = 10.sp, lineHeight = 14.sp,
                                    modifier = Modifier.testTag("focusRack.calibrate.detail")) }
                            }
                        }
                    }
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        state.marks.forEach { mark ->
                            TextButton(onClick = { onCapture(mark.id) },
                                enabled = !nudging && if (mark.id == "A") state.canCaptureA else state.canCaptureB,
                                modifier = Modifier.weight(1f).heightIn(min = 48.dp)
                                    .testTag("focusRack.capture.${mark.id}")) { Text("Replace ${mark.id}") }
                        }
                    }
                    Text("Timing templates require fresh marks when loaded.", color = Color.LightGray, fontSize = 11.sp)
                    OutlinedButton(onClick = { editingField = "template"; editText = "" }, enabled = state.canEdit && !nudging,
                        modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp)
                            .testTag("focusRack.saveTemplate")) { Text("Save timing…") }
                    templates.forEach { template ->
                        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                            TextButton(onClick = { onLoad(template) }, enabled = state.canEdit && !nudging,
                                modifier = Modifier.weight(1f).heightIn(min = 48.dp)) { Text(template.name) }
                            TextButton(onClick = { onDelete(template) }, enabled = state.canEdit && !nudging,
                                modifier = Modifier.heightIn(min = 48.dp).semantics {
                                    contentDescription = "Delete ${template.name} timing template"
                                }) { Text("Delete") }
                        }
                    }
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        OutlinedButton(onClick = onFocusSettings, enabled = setupEnabled && !state.active,
                            modifier = Modifier.weight(1f).heightIn(min = 48.dp), contentPadding = PaddingValues(4.dp)) {
                            Text("Focus settings", fontSize = 12.sp)
                        }
                        OutlinedButton(onClick = onReset, enabled = state.canReset && !nudging,
                            modifier = Modifier.weight(1f).heightIn(min = 48.dp).testTag("focusRack.reset"),
                            contentPadding = PaddingValues(4.dp)) { Text("Reset marks", fontSize = 12.sp) }
                    }
                }
                state.admissionMessage?.let { Text(it, color = Color(0xFFFFCE9B), fontSize = 12.sp,
                    modifier = Modifier.bringIntoViewRequester(admissionAttention).testTag("focusRack.admission")) }
                val message = state.error ?: state.message
                if (message.isNotBlank()) Text(message, color = if (state.error != null) Color(0xFFFFBE9E) else Color.LightGray,
                    fontSize = 12.sp, modifier = Modifier.testTag("focusRack.message"))
            }
            state.recovery?.let { Text(it, color = Color(0xFFFFCE9B), fontSize = 12.sp,
                modifier = Modifier.testTag("focusRack.recovery")) }
            if (state.active && state.total > 0 && !nudging) LinearProgressIndicator(
                progress = { state.completed.toFloat() / state.total }, modifier = Modifier.fillMaxWidth()
                    .testTag("focusRack.progress"))
        }
        val showsStop = state.canStop || state.phase == "stopping"
        if (showsStop && !compact && !nudging) Text("Stop cancels focus movement only.", color = Color.LightGray,
            fontSize = 11.sp, modifier = Modifier.testTag("focusRack.stopHint"))
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            if (compactPositioning) {
                listOf("A", "B").forEach { id ->
                    FocusRackGoButton(id, if (id == "A") state.canGoToA else state.canGoToB, onGoTo)
                }
            } else if (directPulls) {
                listOf("aToB" to state.pullAToB, "bToA" to state.pullBToA).forEach { (direction, action) ->
                    Button(onClick = { onRun(direction) }, enabled = setupEnabled && action?.enabled == true,
                        modifier = Modifier.weight(1f).heightIn(min = 48.dp).testTag("focusRack.pull.$direction"),
                        contentPadding = PaddingValues(horizontal = 4.dp)) {
                        Column(horizontalAlignment = Alignment.CenterHorizontally) {
                            Text(action?.title.orEmpty(), fontSize = 12.sp, lineHeight = 16.sp)
                            action?.detail?.let { Text(it, fontSize = 10.sp, lineHeight = 14.sp,
                                modifier = Modifier.testTag("focusRack.pull.$direction.detail")) }
                        }
                    }
                }
            } else {
            Button(onClick = onPrimary, enabled = state.primaryEnabled && !nudging && (setupEnabled || state.canPause),
                modifier = Modifier.weight(1f).heightIn(min = 48.dp).testTag("focusRack.primary"),
                contentPadding = PaddingValues(horizontal = 6.dp)) {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    Text(state.primaryTitle, fontSize = 12.sp)
                    state.primaryDetail?.let { Text(it, fontSize = 10.sp,
                        modifier = Modifier.testTag("focusRack.primaryDetail")) }
                }
            }
            }
            if (showsStop) OutlinedButton(onClick = onStop, enabled = state.canStop && state.phase != "stopping",
                modifier = Modifier.heightIn(min = 48.dp).testTag("focusRack.stop")
                    .semantics { contentDescription = "Stop focus movement. Recording continues; focus stays where it stops." },
                contentPadding = PaddingValues(horizontal = 12.dp)) {
                Text(if (state.phase == "stopping") "Stopping…" else "Stop", color = Color(0xFFFFAA9B), fontSize = 12.sp)
            }
        }
    }
    LaunchedEffect(showAdmission, compact, state.admissionMessage) {
        if (showAdmission && !compact) {
            if (state.admissionMessage != null) {
                withFrameNanos { }
                admissionAttention.bringIntoView()
            }
            showAdmission = false
        }
    }
    LaunchedEffect(state.active) { if (state.active) editingField = null }
    fun applyEditor() {
        when (editingField) {
            "duration" -> onTiming(FocusRackTimingEdit(duration = editText))
            "delay" -> onTiming(FocusRackTimingEdit(delay = editText))
            "template" -> onSave(editText)
        }
        editingField = null
    }
    editingField?.let { field ->
        val editorFocus = remember(field) { FocusRequester() }
        Dialog(onDismissRequest = { editingField = null },
            properties = DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false)) {
            Box(Modifier.fillMaxSize().windowInsetsPadding(WindowInsets.safeDrawing).imePadding()
                .padding(12.dp), contentAlignment = Alignment.TopCenter) {
                Surface(shape = RoundedCornerShape(12.dp), tonalElevation = 6.dp,
                    modifier = Modifier.widthIn(max = 560.dp)) {
                    Row(Modifier.padding(12.dp), horizontalArrangement = Arrangement.spacedBy(8.dp),
                        verticalAlignment = Alignment.CenterVertically) {
                        OutlinedTextField(editText, { editText = it }, singleLine = true,
                            label = { Text(when (field) {
                                "duration" -> "Duration (seconds)"
                                "delay" -> "Start delay (seconds)"
                                else -> "Template name"
                            }) }, modifier = Modifier.weight(1f).focusRequester(editorFocus)
                                .testTag("focusRack.editInput"),
                            keyboardOptions = KeyboardOptions(keyboardType = if (field == "template") KeyboardType.Text else KeyboardType.Decimal,
                                imeAction = ImeAction.Done), keyboardActions = KeyboardActions(onDone = { applyEditor() }))
                        TextButton(onClick = { editingField = null }, modifier = Modifier.heightIn(min = 48.dp)) { Text("Cancel") }
                        Button(onClick = { applyEditor() }, modifier = Modifier.heightIn(min = 48.dp)
                            .testTag("focusRack.applyEdit")) { Text(if (field == "template") "Save" else "Apply") }
                    }
                }
            }
            LaunchedEffect(field) { editorFocus.requestFocus() }
        }
    }
    if (confirmClose) AlertDialog(onDismissRequest = { confirmClose = false },
        title = { Text("Close Focus Rack?") },
        text = { Text("Session marks will be discarded. Saved timing templates remain available.") },
        confirmButton = { TextButton(onClick = { confirmClose = false; onClose() }) { Text("Discard marks and close") } },
        dismissButton = { TextButton(onClick = { confirmClose = false }) { Text("Keep open") } })
    }
}

@Composable
private fun FocusRackNudgeControls(enabled: Boolean, progress: FocusRackNudgeProgressViewState?,
    onNudge: (Boolean, Int) -> Unit) {
    Row(Modifier.fillMaxWidth().testTag("focusRack.nudges"), horizontalArrangement = Arrangement.spacedBy(4.dp)) {
        listOf(Triple(true, 10, "near10"), Triple(true, 1, "near"),
            Triple(false, 1, "far"), Triple(false, 10, "far10")).forEach { (near, steps, id) ->
            val direction = if (near) "Near" else "Far"
            val amount = if (near) "−$steps" else "+$steps"
            val percent = progress?.takeIf { it.towardNear == near && it.steps == steps }?.percent
            OutlinedButton(onClick = { onNudge(near, steps) }, enabled = enabled,
                modifier = Modifier.weight(1f).heightIn(min = 48.dp).testTag("focusRack.$id")
                    .semantics {
                        contentDescription = "$direction $amount"
                        if (percent != null) stateDescription = "$percent percent"
                    },
                contentPadding = PaddingValues(2.dp)) {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    Text(direction, fontSize = 11.sp, lineHeight = 14.sp)
                    Text(if (percent == null) amount else "$percent%", fontSize = 13.sp, lineHeight = 16.sp,
                        color = if (percent == null) Color.Unspecified else Color.White,
                        modifier = if (percent == null) Modifier else Modifier.testTag("focusRack.nudgeProgress.$id"))
                }
            }
        }
    }
}

@Composable
private fun RowScope.FocusRackGoButton(id: String, enabled: Boolean, onGoTo: (String) -> Unit) {
    OutlinedButton(onClick = { onGoTo(id) }, enabled = enabled,
        modifier = Modifier.weight(1f).heightIn(min = 48.dp).testTag("focusRack.go.$id"),
        contentPadding = PaddingValues(4.dp)) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Text("Go to $id", fontSize = 12.sp)
            Text("Fast reposition", fontSize = 10.sp)
        }
    }
}

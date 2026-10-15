package com.opencapture.openzcine.multicam

import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.opencapture.monitorui.MonitorIcon
import com.opencapture.monitorui.MonitorImagePreview
import com.opencapture.monitorui.MonitorInspector
import com.opencapture.monitorui.MonitorPalette
import com.opencapture.monitorui.MonitorTab
import com.opencapture.monitorui.MonitorTypography
import com.opencapture.monitorui.monitorChromeClickable
import com.opencapture.opencine.appkit.MonitorCaptureDrum
import com.opencapture.opencine.appkit.MonitorControlModel
import com.opencapture.opencine.appkit.MultiviewStageViewport
import com.opencapture.opencine.appkit.captureField
import com.opencapture.opencine.core.CameraCommand
import com.opencapture.opencine.core.CameraSession
import com.opencapture.opencine.core.CameraSessionID
import com.opencapture.opencine.core.CameraSnapshot
import com.opencapture.opencine.core.CommandReceipt
import com.opencapture.opencine.core.CommandRejection
import com.opencapture.opencine.core.CommandStage
import com.opencapture.opencine.core.MonitorEntryID
import com.opencapture.opencine.core.OperationID
import com.opencapture.opencine.core.SessionCloseReason
import com.opencapture.opencine.core.SettingKey
import com.opencapture.opencine.multicam.EditorLease
import com.opencapture.opencine.nikon.CameraCommandAdmission
import com.opencapture.opencine.nikon.NikonOpenCineSession
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.flow.StateFlow

/** The settings a Multiview member edits, in the iOS panel's order. */
internal val multiviewEditableSettings = listOf(
    SettingKey.ISO, SettingKey.SHUTTER, SettingKey.APERTURE, SettingKey.WHITE_BALANCE,
    SettingKey.EXPOSURE_COMPENSATION, SettingKey.FOCUS_MODE, SettingKey.FRAME_RATE,
)

/** The iOS `SettingKey.rawValue` spelling, so both platforms share accessibility identifiers. */
internal val SettingKey.identifier: String
    get() = name.lowercase().split('_').let { parts ->
        parts.first() + parts.drop(1).joinToString("") { it.replaceFirstChar(Char::uppercase) }
    }

/**
 * A borrowed control surface over the member's existing session. Closing it retires only this
 * editor: accepted commands and the member's picture and connection keep their owner. Every
 * forwarded command carries a native admission bound to the member's own link session and this
 * editor's receipt, so a write queued before retirement never reaches a replacement member.
 */
internal class MulticamEditorSession(
    private val source: NikonOpenCineSession,
    private val owner: com.opencapture.opencine.nikon.CameraSession,
    private val isCurrent: () -> Boolean,
) : CameraSession {
    private val active = AtomicBoolean(true)
    private val rejected = ConcurrentHashMap<OperationID, CommandReceipt>()

    override val id: CameraSessionID get() = source.id
    override val snapshots: StateFlow<CameraSnapshot> get() = source.snapshots
    val isActive: Boolean get() = active.get()

    override suspend fun submit(command: CameraCommand): CommandReceipt {
        rejected[command.operation]?.let { return it }
        if (!active.get() || !isCurrent()) {
            return CommandReceipt(command.operation, id, command.intent, CommandStage.Rejected(CommandRejection.AuthorityExpired))
                .also { rejected[command.operation] = it }
        }
        // The predicate reads only this thread-safe receipt; it runs at the native queue's gate.
        return source.submit(command, CameraCommandAdmission(owner) { active.get() })
    }

    override suspend fun outcome(operation: OperationID): CommandReceipt? = rejected[operation] ?: source.outcome(operation)

    override fun receipt(operation: OperationID): CommandReceipt? = rejected[operation] ?: source.receipt(operation)

    /** Retires the editor only; the member session stays open and recording is untouched. */
    override suspend fun close(reason: SessionCloseReason) = closeNow(reason)

    override fun closeNow(reason: SessionCloseReason) {
        active.set(false)
    }
}

/** One open Multiview camera editor: the member, its engine lease and the borrowed facade. */
class MulticamCameraEditor internal constructor(
    val member: MonitorEntryID,
    val lease: EditorLease,
    internal val session: MulticamEditorSession,
) {
    internal fun retire() = session.closeNow(SessionCloseReason.REQUESTED)
}

/** The shared inspector and typed capture drums, bound only to the selected member's editor. */
@Composable
internal fun MulticamCameraSettings(
    coordinator: MulticamCoordinator,
    editor: MulticamCameraEditor,
    viewport: MultiviewStageViewport,
) {
    val scope = rememberCoroutineScope()
    val control = remember(editor) { MonitorControlModel(scope) }
    DisposableEffect(editor, control) {
        control.bind(editor.session)
        onDispose { control.unbind() }
    }
    val state by control.state.collectAsState()
    val member = coordinator.member(editor.member)
    MonitorInspector(
        title = "Camera",
        viewportWidth = viewport.width,
        viewportHeight = viewport.height,
        onDismiss = coordinator::closeCameraSettings,
        modifier = Modifier.testTag("multiview.settings.panel"),
        trailing = true,
        hasNavigation = false,
        safeLeading = viewport.safeArea.leading,
        safeTrailing = viewport.safeArea.trailing,
        safeTop = viewport.safeArea.top,
        safeBottom = viewport.safeArea.bottom,
        close = { MulticamPanelClose("Close camera settings", coordinator::closeCameraSettings) },
        compactHeader = true,
    ) {
        Column(Modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            MulticamMemberTabs(
                slots = coordinator.members.map { it.slot }.filter { it in coordinator.cameraSettingsSlots }.sorted(),
                selected = member?.slot,
                title = { coordinator.memberAt(it)?.letter.orEmpty() },
                identifier = { "multiview.settings.camera.$it" },
                select = coordinator::openCameraSettings,
            )
            val scroll = rememberScrollState()
            Column(Modifier.weight(1f).fillMaxWidth().verticalScroll(scroll), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                // This member's own accepted picture (its look applied), never another camera's.
                MonitorImagePreview(member?.frame, "${member?.displayName.orEmpty()} picture",
                    Modifier.testTag("multiview.settings.preview"))
                if (state.snapshot != null) {
                    multiviewEditableSettings.forEach { key ->
                        val field = control.captureField(key) ?: return@forEach
                        Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                            Text(field.title, style = MonitorTypography.text(11f, FontWeight.SemiBold), color = MonitorPalette.muted)
                            MonitorCaptureDrum(control, field, modifier = Modifier.testTag("multiview.settings.${key.identifier}"))
                        }
                    }
                }
            }
        }
    }
}

@Composable
internal fun MulticamPanelClose(label: String, onClose: () -> Unit) {
    Box(Modifier.padding(end = 8.dp).size(48.dp).testTag("monitor.capture.close")
        .monitorChromeClickable(onClick = onClose)
        .semantics { contentDescription = label; role = Role.Button },
        contentAlignment = Alignment.Center) {
        MonitorIcon(MonitorIcon.X, null, Modifier.size(13.dp), MonitorPalette.muted)
    }
}

/** One tab per member, identified by slot so both platforms share identifiers. */
@Composable
internal fun MulticamMemberTabs(
    slots: List<Int>, selected: Int?, title: (Int) -> String, identifier: (Int) -> String, select: (Int) -> Unit,
) {
    Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState())) {
        slots.forEachIndexed { index, slot ->
            MonitorTab(slot == selected, { if (slot != selected) select(slot) },
                Modifier.testTag(identifier(slot)), separator = index > 0, accessibilityLabel = "Camera ${title(slot)}") {
                Text(title(slot), style = MonitorTypography.text(13f, FontWeight.SemiBold),
                    color = if (slot == selected) MonitorPalette.text else MonitorPalette.muted)
            }
        }
    }
}

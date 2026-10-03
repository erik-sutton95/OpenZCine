package com.opencapture.openzcine.settings

import com.opencapture.monitorui.settings.MonitorSettingsActionPill
import com.opencapture.monitorui.settings.MonitorSupportAction
import com.opencapture.monitorui.settings.MonitorSupportSettings
import androidx.compose.ui.platform.testTag

import com.opencapture.openzcine.performOperatorHaptic
import com.opencapture.monitorui.settings.LocalMonitorSettingsScrollContext
import com.opencapture.monitorui.settings.MonitorOperatorSafetySettings
import com.opencapture.monitorui.settings.MonitorAppInformationSettings
import com.opencapture.monitorui.settings.MonitorCacheSettings
import com.opencapture.monitorui.settings.MonitorProjectLegalSettings
import com.opencapture.monitorui.settings.MonitorSettingsNumberField
import com.opencapture.monitorui.settings.MonitorSettingsPage
import com.opencapture.monitorui.settings.MonitorSettingsRowCard
import com.opencapture.monitorui.settings.MonitorSettingsSwitchInlineRow
import com.opencapture.monitorui.settings.MonitorSettingsTab

import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import android.net.Uri
import android.os.Build
import android.text.format.Formatter
import android.view.HapticFeedbackConstants
import android.widget.Toast
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalResources
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.LocalTextStyle
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.opencapture.openzcine.BuildConfig
import com.opencapture.openzcine.R
import com.opencapture.openzcine.AssistState
import com.opencapture.openzcine.AssistTool
import com.opencapture.openzcine.ChromeShape
import com.opencapture.openzcine.ExposureAssistCameraInput
import com.opencapture.openzcine.FeedPeakingColor
import com.opencapture.openzcine.FeedPeakingSensitivity
import com.opencapture.openzcine.FeedZebraStripeColor
import com.opencapture.openzcine.FeedZebraUnit
import com.opencapture.openzcine.LiveDesign
import com.opencapture.openzcine.LiveViewGuideController
import com.opencapture.openzcine.prefersPhotographyChrome
import com.opencapture.openzcine.zebraEditorValue
import com.opencapture.openzcine.zebraMonitorPercent
import com.opencapture.openzcine.chromeStyle
import com.opencapture.openzcine.bridge.AndroidLinkHealthMonitor
import com.opencapture.openzcine.bridge.LinkHealthPresentation
import com.opencapture.openzcine.bridge.SwiftCore
import com.opencapture.opencine.nikon.SwiftCoreLiveFrameSource
import com.opencapture.opencine.nikon.CameraSession
import com.opencapture.opencine.nikon.CameraSessionState
import com.opencapture.openzcine.FeedFalseColorScale
import com.opencapture.openzcine.FeedLut
import com.opencapture.openzcine.frameio.FrameioConnectionState
import com.opencapture.openzcine.frameio.FrameioDeliveryController
import com.opencapture.openzcine.frameio.FrameioNetworkState
import com.opencapture.openzcine.diagnostics.BugReportPathChooser
import com.opencapture.openzcine.diagnostics.BugReportScreen
import com.opencapture.openzcine.diagnostics.BugReportSubmitter
import com.opencapture.openzcine.diagnostics.SystemSettingsActions
import com.opencapture.openzcine.media.MediaCacheClearResult
import com.opencapture.openzcine.media.MediaCacheStore
import com.opencapture.openzcine.relay.RelayCameraSession
import com.opencapture.openzcine.relay.RelayWatchUiState
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlin.math.roundToInt

/** Shared navigation vocabulary; existing debug enum names remain unchanged. */
public typealias OperatorSettingsTab = MonitorSettingsTab

private enum class BugReportDestination {
    CHOOSER,
    ANONYMOUS,
}

/**
 * Whether an internet-backed Operator Setup action has to leave the camera's access point first
 * (iOS `requestInternetDestination`, MonitorPanels.swift:4755).
 *
 * The in-app bug report and the Adobe sign-in both transact from THIS process, and the process
 * is bound to a Wi-Fi network that has no internet at all — so they cannot reach anything until
 * the consented hop runs. External links are unaffected: the browser is a different process and
 * never sees our binding.
 */
internal fun settingsActionNeedsInternetHop(state: FrameioNetworkState?): Boolean =
    state == FrameioNetworkState.CAMERA_ACCESS_POINT

/**
 * The full-screen Operator Settings surface — a 1:1 structural port of the
 * iOS `OperatorSettingsPanel` (ios/Runner/MonitorPanels.swift): floating close
 * button, eyebrow/title header with the live tile, vertical tab rail, and a
 * rounded content pane per tab. [assistState] is the monitor toolbar's state,
 * so view-assist changes apply immediately and persist through one seam.
 *
 * [session] is null for standalone startup settings. That state never creates
 * a session or sends a camera command; the live tile instead explains that
 * only app-local setup is available. [mediaCacheStore] is scoped to the
 * app-owned progressive cache, not camera or share-provider storage.
 */
@Composable
internal fun OperatorSettingsScreen(
    session: CameraSession?,
    assistState: AssistState,
    settings: OperatorSettings,
    mediaCacheStore: MediaCacheStore,
    frameioController: FrameioDeliveryController? = null,
    linkHealth: AndroidLinkHealthMonitor? = null,
    liveViewSource: SwiftCoreLiveFrameSource? = null,
    activeTransportLabel: String? = null,
    onDisconnect: (() -> Unit)? = null,
    onReconnect: (() -> Unit)? = null,
    systemSettingsActions: SystemSettingsActions,
    bugReportSubmitter: BugReportSubmitter,
    bugReportActivityLogProvider: () -> List<String> = { emptyList() },
    liveViewGuideController: LiveViewGuideController,
    onShowGuideNow: (() -> Unit)? = null,
    onShowGuideOnNextRealFrame: () -> Unit,
    onCompletedMediaCacheCleared: () -> Unit = {},
    initialTab: OperatorSettingsTab = OperatorSettingsTab.LINK,
    relaySharing: com.opencapture.openzcine.relay.RelayBroadcastController? = null,
    relaySharingEnabled: Boolean = false,
    onRelayShareToggle: ((Boolean) -> Unit)? = null,
    /** Watch-session state, for the Link tab's "Held By" readout (iOS `linkRows`). */
    relayWatchUi: RelayWatchUiState? = null,
    onClose: () -> Unit,
) {
    val context = LocalContext.current
    val scopeLimitMessage = stringResource(R.string.settings_scope_limit)
    val isPortrait = LocalConfiguration.current.orientation == Configuration.ORIENTATION_PORTRAIT
    val cameraProperties = if (session == null) null else session.cameraProperties.collectAsState().value
    val cameraInput =
        remember(
            cameraProperties?.codec,
            cameraProperties?.iso,
            cameraProperties?.baseIso,
            cameraProperties?.captureSelector,
            cameraProperties?.stillToneMode,
        ) {
            ExposureAssistCameraInput(
                codec = cameraProperties?.codec,
                iso = cameraProperties?.iso,
                baseIso = cameraProperties?.baseIso,
                // Match the live monitor: while the photo selector is active the zebra
                // editor converts against the display-referred stills mapping.
                stillsToneMode =
                    if (cameraProperties != null && prefersPhotographyChrome(cameraProperties)) {
                        cameraProperties.stillToneMode.orEmpty()
                    } else {
                        null
                    },
            )
        }
    val feedbackView = LocalView.current
    val toggleSetting: (OperatorSettings.Toggle) -> Unit = { toggle ->
        val hapticsWereEnabled = settings.hapticsEnabled.value
        toggle.toggle()
        if (hapticsWereEnabled) {
            feedbackView.performOperatorHaptic(HapticFeedbackConstants.KEYBOARD_TAP)
        }
    }
    val toggleAssist: (AssistTool) -> Unit = { tool ->
        val hapticsEnabled = settings.hapticsEnabled.value
        val maximumScopes = if (session != null && isPortrait) 2 else null
        val changed = assistState.toggle(tool, maximumActiveScopes = maximumScopes)
        if (!changed) {
            Toast.makeText(
                context,
                scopeLimitMessage,
                Toast.LENGTH_SHORT,
            ).show()
        } else if (hapticsEnabled) {
            feedbackView.performOperatorHaptic(HapticFeedbackConstants.KEYBOARD_TAP)
        }
    }
    val emitHaptic: () -> Unit = {
        if (settings.hapticsEnabled.value) {
            feedbackView.performOperatorHaptic(HapticFeedbackConstants.KEYBOARD_TAP)
        }
    }
    var selectedTab by rememberSaveable(initialTab) { mutableStateOf(initialTab) }
    var bugReportDestination by remember { mutableStateOf<BugReportDestination?>(null) }
    val panelScope = rememberCoroutineScope()
    // Whether this phone is still process-bound to the camera's no-internet AP. The Storage tab
    // reads it too, but Report a Problem is on System, so refresh once for the whole surface.
    LaunchedEffect(frameioController) { frameioController?.refresh() }
    // The camera rejoin runs when Operator Setup is dismissed, not when the report or the Adobe
    // browser round trip ends: both outlive the row that started the hop (iOS re-hosts the
    // panel as a standalone cover for the same reason — MonitorPanels.swift:4919-4943).
    DisposableEffect(frameioController) {
        onDispose {
            val controller = frameioController
            if (controller != null && controller.isInternetHopActive) {
                endInternetHopAfterDismiss(controller)
            }
        }
    }
    var pendingReportHop by remember { mutableStateOf(false) }
    var reportHopBusy by remember { mutableStateOf(false) }
    var hopFailureMessage by remember { mutableStateOf<String?>(null) }
    val hopFailureFallback = stringResource(R.string.settings_hop_failed_message)
    // iOS `requestInternetDestination(.reportProblem)`: consent, hop, then the report.
    val requestReportProblem: () -> Unit = {
        if (!reportHopBusy) {
            if (settingsActionNeedsInternetHop(frameioController?.networkState)) {
                pendingReportHop = true
            } else {
                bugReportDestination = BugReportDestination.CHOOSER
            }
        }
    }

    when (bugReportDestination) {
        BugReportDestination.CHOOSER ->
            BugReportPathChooser(
                onChooseAnonymous = { bugReportDestination = BugReportDestination.ANONYMOUS },
                onContinueWithGitHub = systemSettingsActions::openGitHubBugReport,
                onClose = { bugReportDestination = null },
            )
        BugReportDestination.ANONYMOUS ->
            BugReportScreen(
                submitter = bugReportSubmitter,
                activityLogProvider = bugReportActivityLogProvider,
                onOpenSecurityAdvisory = systemSettingsActions::openSecurityAdvisory,
                onClose = { bugReportDestination = null },
            )
        null -> BoxWithConstraints(
            Modifier.fillMaxSize()
                .background(LiveDesign.background)
                .pointerInput(Unit) { detectTapGestures {} }
                .windowInsetsPadding(WindowInsets.safeDrawing)
        ) {
            val compact = maxWidth < 600.dp
            val condensed = maxHeight < 300.dp
            val disconnected = remember { MutableStateFlow<CameraSessionState>(CameraSessionState.Disconnected) }
            val state by (session?.state ?: disconnected).collectAsState()
            val linked = state is CameraSessionState.Connected
            val phase = when (val current = state) {
                is CameraSessionState.Connected ->
                    linkHealth?.presentation?.detail?.takeIf { it.isNotBlank() }
                        ?: "${current.identity.name} · ${activeTransportLabel ?: "Wi-Fi"}"
                CameraSessionState.Connecting -> stringResource(R.string.camera_connecting_short)
                CameraSessionState.Disconnected -> stringResource(R.string.settings_local_only)
            }
            MonitorSettingsPage(
                brand = "OpenZCine",
                selection = selectedTab,
                onSelect = { selectedTab = it },
                isLive = linked,
                phaseLabel = phase,
                disconnect = onDisconnect,
                feedback = emitHaptic,
                sharingSubtitle = stringResource(R.string.settings_subtitle_sharing),
                sharingRail = "Broadcast & watchers",
                modifier = Modifier.padding(start = 61.dp, end = 16.dp, top = 14.dp, bottom = 12.dp),
            ) { tab ->
                val scroll = LocalMonitorSettingsScrollContext.current
                when (tab) {
                    OperatorSettingsTab.SHARING -> SharingRows(
                        session = session, sharing = relaySharing, settings = settings,
                        enabled = relaySharingEnabled, onShareToggle = onRelayShareToggle,
                        onInteraction = emitHaptic,
                    )
                    OperatorSettingsTab.LINK -> LinkRows(
                        session, settings, linkHealth, liveViewSource, activeTransportLabel,
                        relayWatchUi, onDisconnect, onReconnect, emitHaptic,
                    )
                    OperatorSettingsTab.ASSIST -> AssistRows(
                        settings, assistState, cameraInput, toggleSetting, toggleAssist, emitHaptic,
                    )
                    OperatorSettingsTab.CONTROLS -> ControlsRows(settings, emitHaptic, toggleSetting)
                    OperatorSettingsTab.DISPLAY -> NikonDisplaySettings(
                        settings, compact, toggleSetting, emitHaptic,
                        checkNotNull(scroll).scrollState, scroll.viewportBounds,
                        liveCaptureMode = if (cameraProperties != null && prefersPhotographyChrome(cameraProperties)) {
                            CaptureLayoutMode.PHOTO
                        } else {
                            CaptureLayoutMode.VIDEO
                        },
                        onEditView = { mode -> settings.beginChromeEditing(mode); onClose() },
                    )
                    OperatorSettingsTab.STORAGE -> StorageRows(
                        mediaCacheStore, frameioController, condensed, onCompletedMediaCacheCleared,
                    )
                    OperatorSettingsTab.SYSTEM -> SystemRows(
                        systemSettingsActions, requestReportProblem, liveViewGuideController,
                        onShowGuideNow, onShowGuideOnNextRealFrame,
                    )
                }
            }
            Box(Modifier.padding(start = 16.dp, top = 22.dp)) { PanelCloseButton(onClick = onClose) }
        }
    }

    // iOS "Leave camera Wi-Fi?" (MonitorPanels.swift:3910-3925) — consent first, hop second,
    // report third. Declining leaves the camera session exactly as it was.
    if (pendingReportHop) {
        val controller = frameioController
        AlertDialog(
            onDismissRequest = { pendingReportHop = false },
            title = { Text(stringResource(R.string.settings_report_hop_title)) },
            text = { Text(stringResource(R.string.settings_report_hop_message)) },
            confirmButton = {
                TextButton(
                    onClick = {
                        pendingReportHop = false
                        if (controller == null) {
                            hopFailureMessage = hopFailureFallback
                        } else {
                            reportHopBusy = true
                            panelScope.launch {
                                val online =
                                    try {
                                        controller.beginInternetHop()
                                    } catch (_: Exception) {
                                        false
                                    }
                                reportHopBusy = false
                                if (online) {
                                    bugReportDestination = BugReportDestination.CHOOSER
                                } else {
                                    hopFailureMessage =
                                        controller.errorMessage ?: hopFailureFallback
                                }
                            }
                        }
                    },
                ) {
                    Text(stringResource(R.string.action_continue))
                }
            },
            dismissButton = {
                TextButton(onClick = { pendingReportHop = false }) {
                    Text(stringResource(R.string.action_cancel))
                }
            },
        )
    }
    // Leaving an AP and waiting for a validated route takes seconds, not milliseconds. Without
    // this the Report pill looks dead and gets tapped again.
    if (reportHopBusy) {
        AlertDialog(
            onDismissRequest = {},
            title = { Text(stringResource(R.string.frameio_switching_networks)) },
            text = { Text(stringResource(R.string.settings_hop_progress_message)) },
            confirmButton = {},
        )
    }
    hopFailureMessage?.let { message ->
        AlertDialog(
            onDismissRequest = { hopFailureMessage = null },
            title = { Text(stringResource(R.string.settings_hop_failed_title)) },
            text = { Text(message) },
            confirmButton = {
                TextButton(onClick = { hopFailureMessage = null }) {
                    Text(stringResource(R.string.action_ok))
                }
            },
        )
    }
}

/**
 * Rejoins the camera after a consented internet hop, from a scope that outlives this
 * composition — the operator has already dismissed the surface that started it.
 *
 * ponytail: same three lines as lut/RedLutDownloadScreen.kt's `endInternetHopAfterDismiss`,
 * which is private to that file. Hoist one copy if a third caller appears.
 */
private fun endInternetHopAfterDismiss(controller: FrameioDeliveryController) {
    CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate).launch {
        try {
            withContext(NonCancellable) { controller.endInternetHop() }
        } catch (_: Exception) {
            // Best-effort rejoin; the operator has already left the settings surface.
        }
    }
}

/** Eyebrow + title with the live tile pinned trailing (iOS `settingsTop`). */
/**
 * Sharing tab — 1:1 with iOS `sharingRows`: enable, watcher count, 4-digit watcher passcode,
 * control-requests policy, and the live control rows (requested / held-by with Take Back).
 *
 * The tab is always present, exactly like iOS. A watcher gets the one row explaining that
 * sharing happens on the broadcasting device (re-sharing would stack a second encode and a
 * second hop on everyone downstream); standalone setup gets the same passcode / priority /
 * control-policy rows, because those are preferences an operator sets up BEFORE a shoot, and
 * the broadcast reads them the moment it starts.
 */
@Composable
private fun SharingRows(
    session: CameraSession?,
    sharing: com.opencapture.openzcine.relay.RelayBroadcastController?,
    settings: OperatorSettings,
    enabled: Boolean,
    onShareToggle: ((Boolean) -> Unit)?,
    onInteraction: () -> Unit,
) {
    // Watching another device's broadcast: the only surface that owns a RelayCameraSession
    // (relay/RelayWatchController.kt). iOS keys the same branch off `videoSource == .relay`.
    if (session is RelayCameraSession) {
        val state by session.state.collectAsState()
        SettingsRowCard {
            SettingsInlineRow(
                title = stringResource(R.string.sharing_watching),
                help = stringResource(R.string.help_sharing_watcher),
                showTopDivider = false,
            ) {
                SettingsValueText(
                    (state as? CameraSessionState.Connected)?.identity?.name
                        ?: stringResource(R.string.camera_none),
                )
            }
        }
        return
    }
    val ui = if (sharing == null) null else sharing.ui.collectAsState().value
    var passcodeDraft by remember { mutableStateOf(settings.relayWatcherPasscode.value) }
    SettingsRowCard {
        if (sharing == null) {
            SettingsInlineRow(
                title = stringResource(R.string.sharing_share_this_feed),
                help = stringResource(R.string.help_sharing_share_feed),
                showTopDivider = false,
            ) {
                SettingsValueText(stringResource(R.string.sharing_share_unavailable))
            }
        } else {
            SettingsSwitchRow(
                stringResource(R.string.sharing_share_this_feed),
                isOn = enabled,
                help = stringResource(R.string.help_sharing_share_feed),
                showTopDivider = false,
            ) {
                onShareToggle?.invoke(!enabled)
                onInteraction()
            }
        }
        // A listener that cannot bind is silent otherwise: the switch springs straight back
        // (the shell assigns `relaySharingEnabled = start(...)`) and the operator is left with
        // a control that refuses to move. The sentence comes from the host itself
        // (relay/MonitorRelayHost.kt "Couldn't start sharing: …"), which is what iOS shows on
        // the monitor (MonitorRelayLink.swift:314 → NativeAppRoot.swift:1295). The controller
        // clears it on the next start/stop, so it never outlives the attempt it explains.
        ui?.failureReason?.let { reason ->
            Text(
                reason,
                style = chromeStyle(10.5f, FontWeight.Normal),
                color = LiveDesign.rec,
                modifier = Modifier.padding(bottom = 6.dp),
            )
        }
        if (ui != null) {
            SettingsInlineRow(
                title = stringResource(R.string.sharing_watching),
                help = stringResource(R.string.help_sharing_watching),
            ) {
                SettingsValueText(stringResource(R.string.sharing_watching_count, ui.watcherCount))
            }
        }
        // Between Watching and the passcode, exactly where the iOS Sharing panel puts it. The
        // option words come from the shared core rather than a string resource, so the two shells
        // cannot end up offering differently-named stances.
        SettingsInlineRow(
            title = stringResource(R.string.sharing_broadcast_priority),
            help = stringResource(R.string.help_sharing_priority),
        ) {
            val profile =
                com.opencapture.openzcine.core.RelayEncoderProfile.fromWireValue(
                    settings.relayEncoderProfile.value
                )
            SettingsSegmented(
                options =
                    com.opencapture.openzcine.core.RelayEncoderProfile.entries.map { it.title },
                selected = profile.title,
            ) { value ->
                val picked =
                    com.opencapture.openzcine.core.RelayEncoderProfile.entries.firstOrNull {
                        it.title == value
                    } ?: return@SettingsSegmented
                settings.relayEncoderProfile.value = picked.wireValue
                sharing?.encoderProfile = picked
                onInteraction()
            }
        }
        SettingsInlineRow(
            title = stringResource(R.string.sharing_watcher_passcode),
            help = stringResource(R.string.help_sharing_passcode),
        ) {
            BasicTextField(
                value = passcodeDraft,
                onValueChange = { new ->
                    passcodeDraft = new.filter(Char::isDigit).take(4)
                    // Applies live to NEW joins, exactly like iOS; watchers already in keep
                    // their access until they leave. A cleared field means open.
                    if (passcodeDraft.length == 4 || passcodeDraft.isEmpty()) {
                        settings.relayWatcherPasscode.value = passcodeDraft
                        sharing?.watcherPasscode = passcodeDraft
                    }
                },
                textStyle =
                    LocalTextStyle.current.copy(
                        color = LiveDesign.text,
                        fontSize = 14.sp,
                        textAlign = TextAlign.End,
                    ),
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                singleLine = true,
                modifier = Modifier.width(96.dp),
            )
        }
        SettingsSwitchRow(
            stringResource(R.string.sharing_control_requests),
            isOn = settings.relayAllowsControlRequests.value,
            help = stringResource(R.string.help_sharing_control_requests),
        ) {
            settings.relayAllowsControlRequests.toggle()
            sharing?.allowsControlRequests = settings.relayAllowsControlRequests.value
            onInteraction()
        }
        ui?.pendingControlRequestName?.let {
            SettingsInlineRow(
                title = stringResource(R.string.sharing_control_requested),
                help = stringResource(R.string.help_sharing_control_requested),
            ) {
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    MonitorSettingsActionPill(stringResource(R.string.sharing_decline)) {
                        sharing?.declinePendingControl()
                    }
                    MonitorSettingsActionPill(stringResource(R.string.sharing_grant)) {
                        sharing?.grantPendingControl()
                    }
                }
            }
        }
        ui?.controlHolderName?.let { holder ->
            SettingsInlineRow(
                title = stringResource(R.string.sharing_control_held_by),
                help = stringResource(R.string.help_sharing_camera_control),
            ) {
                Row(
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    SettingsValueText(holder)
                    MonitorSettingsActionPill(stringResource(R.string.sharing_take_back)) {
                        sharing?.reclaimControl()
                    }
                }
            }
        }
    }
}

/**
 * Link tab — 1:1 with iOS `linkRows`: dash-scale health meter, then one row card
 * with transport, the watcher's control readout, stream preset and Quality bias.
 */
@Composable
private fun LinkRows(
    session: CameraSession?,
    settings: OperatorSettings,
    linkHealth: AndroidLinkHealthMonitor?,
    liveViewSource: SwiftCoreLiveFrameSource?,
    activeTransportLabel: String?,
    relayWatchUi: RelayWatchUiState?,
    onDisconnect: (() -> Unit)?,
    onReconnect: (() -> Unit)?,
    onInteraction: () -> Unit,
) {
    // liveViewSource is accepted for call-site parity; iOS Link no longer surfaces
    // preview-apply diagnostics in this tab.
    @Suppress("UNUSED_PARAMETER")
    val unusedLiveViewSource = liveViewSource
    val disconnectedState = remember { MutableStateFlow<CameraSessionState>(CameraSessionState.Disconnected) }
    val state by (session?.state ?: disconnectedState).collectAsState()
    val linked = state is CameraSessionState.Connected
    val health = linkHealth?.presentation ?: LinkHealthPresentation()
    val scoreBand =
        when {
            health.score >= 80 -> "Stable"
            health.score >= 50 -> "Watch"
            else -> "Poor"
        }
    val healthCaption =
        if (session == null || !linked) {
            health.detail.ifBlank { stringResource(R.string.settings_link_no_camera_caption) }
        } else {
            val detail = health.detail.ifBlank { stringResource(R.string.settings_active_link) }
            "$detail · $scoreBand"
        }
    val transportValue =
        when {
            session == null && activeTransportLabel == null ->
                stringResource(R.string.settings_transport_not_connected)
            !linked -> stringResource(R.string.settings_transport_not_connected)
            else ->
                stringResource(
                    R.string.settings_transport_active,
                    activeTransportLabel ?: "Wi-Fi",
                )
        }
    SettingsDashScale(
        title = stringResource(R.string.settings_link_health),
        caption = healthCaption,
        score = if (linked) health.score else 0,
    )

    SettingsRowCard {
        SettingsInlineRow(
            title = stringResource(R.string.settings_current_transport),
            help = stringResource(R.string.help_link_transport),
            showTopDivider = false,
        ) {
            SettingsValueText(transportValue)
        }
        // A watcher drives nothing until the broadcaster hands over the token, so the Link tab
        // says who is holding it (iOS `linkRows`, videoSource == .relay). The ask/give-back
        // itself stays on the live view, not in a settings sheet.
        if (session is RelayCameraSession) {
            SettingsInlineRow(
                title = stringResource(R.string.sharing_control_held_by),
                help = stringResource(R.string.help_link_held_by),
            ) {
                SettingsValueText(
                    when {
                        relayWatchUi == null -> stringResource(R.string.settings_control_broadcaster)
                        relayWatchUi.holdsControl -> stringResource(R.string.settings_control_this_device)
                        else ->
                            relayWatchUi.controlHolderName
                                ?: stringResource(R.string.settings_control_broadcaster)
                    },
                )
            }
        }
        SettingsInlineRow(
            title = stringResource(R.string.settings_stream_preset),
            help = stringResource(R.string.help_link_stream_preset),
        ) {
            Row(
                Modifier.selectableGroup(),
                horizontalArrangement = Arrangement.spacedBy(3.dp),
            ) {
                LiveViewStreamPreset.entries.forEach { preset ->
                    AssistChoice(
                        label = preset.label,
                        selected = settings.streamPreset == preset,
                    ) {
                        settings.streamPreset = preset
                        onInteraction()
                    }
                }
            }
        }
        SettingsInlineRow(
            title = stringResource(R.string.settings_quality_bias),
            help = stringResource(R.string.help_link_quality_bias),
        ) {
            Row(
                Modifier.selectableGroup(),
                horizontalArrangement = Arrangement.spacedBy(3.dp),
            ) {
                LiveViewQualityBias.entries.forEach { bias ->
                    AssistChoice(
                        label = stringResource(bias.settingsLabelResource),
                        selected = settings.qualityBias == bias,
                    ) {
                        settings.qualityBias = bias
                        onInteraction()
                    }
                }
            }
        }
        // "Health Threshold" (which rendered the stream-preset word "Balanced" under a health
        // label) and a hardcoded "Reconnect Window · 4 sec" used to sit here. iOS has neither,
        // and neither read anything or set anything — a readout of a number nothing consults.
    }

    // What this device does to the picture after the camera has sent it — iOS `linkRows`' third
    // card. Both rows are announcements rather than controls: iOS runs them on VideoToolbox, and
    // the Android counterpart (Play services' Media Enhancement API) is researched but not built.
    // See docs/android-feed-enhancement.md. Shown on every device because a promise, unlike an
    // option, does not have to be gated on what the hardware can run.
    SettingsRowCard(title = stringResource(R.string.settings_processing)) {
        SettingsInlineRow(
            title = stringResource(R.string.settings_feed_upscaler),
            help = stringResource(R.string.help_link_feed_upscaler),
            showTopDivider = false,
        ) {
            SettingsValueText(stringResource(R.string.settings_coming_soon))
        }
        SettingsInlineRow(
            title = stringResource(R.string.settings_feed_noise_reduction),
            help = stringResource(R.string.help_link_feed_noise_reduction),
        ) {
            SettingsValueText(stringResource(R.string.settings_coming_soon))
        }
    }
}

/**
 * View Assist tab — 1:1 with iOS `ViewAssistSettingsRows`: eight per-tool cards
 * (False Color, Zebra, Waveform, Parade, Histogram, Vectorscope, Peaking,
 * Traffic Lights). Landscape uses the same two-column masonry reading order;
 * portrait is a single full-width column. Tool on/off and LUT library stay on
 * the monitor toolbar popups, matching iOS.
 */
@Composable
private fun AssistRows(
    settings: OperatorSettings,
    assistState: AssistState,
    cameraInput: ExposureAssistCameraInput,
    onSettingToggle: (OperatorSettings.Toggle) -> Unit,
    onAssistToggle: (AssistTool) -> Unit,
    onInteraction: () -> Unit,
) {
    @Suppress("UNUSED_PARAMETER")
    val unusedSettingToggle = onSettingToggle
    val imageEffectsAvailable = Build.VERSION.SDK_INT >= 33 && SwiftCore.isAvailable
    val isPortrait = LocalConfiguration.current.orientation == Configuration.ORIENTATION_PORTRAIT

    @Composable
    fun FalseColorCard() {
        if (!imageEffectsAvailable) {
            SettingsRowCard(title = stringResource(R.string.settings_false_color)) {
                SettingsInlineRow(
                    title = stringResource(R.string.settings_image_processing),
                    showTopDivider = false,
                    stacked = true,
                ) {
                    SettingsValueText(stringResource(R.string.settings_image_processing_unavailable))
                }
            }
            return
        }
        val configuration = settings.feedEffectsConfiguration
        SettingsRowCard(
            title = stringResource(R.string.settings_false_color),
            onReset = {
                assistState.resetFalseColorSelection()
                settings.resetFalseColorConfiguration()
                onInteraction()
            },
        ) {
            SettingsInlineRow(
                title = stringResource(R.string.settings_scale),
                showTopDivider = false,
                stacked = true,
            ) {
                SettingsSegmented(
                    options = FeedFalseColorScale.entries.map { it.label },
                    selected = assistState.selectedFalseColorScale.label,
                ) { label ->
                    FeedFalseColorScale.entries.firstOrNull { it.label == label }?.let { scale ->
                        assistState.selectFalseColorScale(scale)
                        onInteraction()
                    }
                }
            }
            SettingsSwitchRow(
                stringResource(R.string.settings_reference_display),
                isOn = configuration.falseColorReferenceEnabled,
                stacked = true,
            ) {
                val enabled = !configuration.falseColorReferenceEnabled
                settings.feedEffectsConfiguration =
                    configuration.copy(falseColorReferenceEnabled = enabled)
                if (enabled && !assistState.isOn(AssistTool.FALSE)) {
                    onAssistToggle(AssistTool.FALSE)
                } else {
                    onInteraction()
                }
            }
        }
    }

    @Composable
    fun PeakingCard() {
        if (!imageEffectsAvailable) return
        PeakingSettingsRows(settings, onInteraction)
    }

    @Composable
    fun ZebraCard() {
        if (!imageEffectsAvailable) return
        ZebraSettingsRows(settings, cameraInput, onInteraction)
    }

    if (isPortrait) {
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            FalseColorCard()
            ZebraCard()
            WaveformSettingsCard(settings, onInteraction)
            ParadeSettingsCard(settings, onInteraction)
            HistogramSettingsCard(settings, onInteraction)
            VectorscopeSettingsCard(settings, onInteraction)
            PeakingCard()
            TrafficLightsSettingsCard(settings, onInteraction)
        }
    } else {
        // iOS masonry: left = odd cards (FC, Waveform, Histogram, Peaking),
        // right = even (Zebra, Parade, Vectorscope, Traffic Lights).
        Row(
            Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalAlignment = Alignment.Top,
        ) {
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                FalseColorCard()
                WaveformSettingsCard(settings, onInteraction)
                HistogramSettingsCard(settings, onInteraction)
                PeakingCard()
            }
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                ZebraCard()
                ParadeSettingsCard(settings, onInteraction)
                VectorscopeSettingsCard(settings, onInteraction)
                TrafficLightsSettingsCard(settings, onInteraction)
            }
        }
    }
}

private val imageEffectTools: Set<AssistTool> =
    setOf(AssistTool.LUT, AssistTool.PEAK, AssistTool.FALSE, AssistTool.ZEBRA)

@Composable
private fun feedLutLabel(lut: FeedLut): String =
    stringResource(
        when (lut) {
            FeedLut.LOG3G10_709 -> R.string.lut_log_709
            FeedLut.NLOG_709 -> R.string.lut_nlog_709
            FeedLut.MONO -> R.string.lut_mono
            FeedLut.R3D_NE_MONITOR -> R.string.lut_r3d_ne_monitor
        },
    )

@Composable
private fun peakingSensitivityLabel(value: FeedPeakingSensitivity): String =
    stringResource(
        when (value) {
            FeedPeakingSensitivity.LOW -> R.string.peaking_low
            FeedPeakingSensitivity.MEDIUM -> R.string.peaking_medium
            FeedPeakingSensitivity.HIGH -> R.string.peaking_high
        },
    )

@Composable
private fun peakingColorLabel(value: FeedPeakingColor): String =
    stringResource(
        when (value) {
            FeedPeakingColor.WHITE -> R.string.color_white
            FeedPeakingColor.BLUE -> R.string.color_blue
            FeedPeakingColor.RED -> R.string.color_red
            FeedPeakingColor.GREEN -> R.string.color_green
        },
    )

@Composable
private fun zebraColorLabel(value: FeedZebraStripeColor): String =
    stringResource(
        when (value) {
            FeedZebraStripeColor.WHITE -> R.string.color_white
            FeedZebraStripeColor.AMBER -> R.string.color_amber
            FeedZebraStripeColor.RED -> R.string.color_red
            FeedZebraStripeColor.CYAN -> R.string.color_cyan
            FeedZebraStripeColor.GREEN -> R.string.color_green
        },
    )

/** iOS peaking rows: segmented sensitivity + colour dots (not text chips). */
@Composable
private fun PeakingSettingsRows(settings: OperatorSettings, onInteraction: () -> Unit) {
    val configuration = settings.feedEffectsConfiguration
    SettingsRowCard(
        title = stringResource(R.string.settings_peaking),
        onReset = {
            settings.resetPeakingConfiguration()
            onInteraction()
        },
    ) {
        SettingsInlineRow(
            title = stringResource(R.string.settings_sensitivity),
            showTopDivider = false,
            stacked = true,
        ) {
            SettingsSegmented(
                options = FeedPeakingSensitivity.entries.map { it.label },
                selected = configuration.peakingSensitivity.label,
            ) { label ->
                FeedPeakingSensitivity.entries.firstOrNull { it.label == label }?.let { sensitivity ->
                    settings.feedEffectsConfiguration =
                        configuration.copy(peakingSensitivity = sensitivity)
                    onInteraction()
                }
            }
        }
        SettingsInlineRow(title = stringResource(R.string.settings_color), stacked = true) {
            SettingsColorDots(
                dots = SettingsPalette.peaking,
                selectedName = configuration.peakingColor.label,
            ) { name ->
                FeedPeakingColor.entries.firstOrNull { it.label == name }?.let { color ->
                    settings.feedEffectsConfiguration = configuration.copy(peakingColor = color)
                    onInteraction()
                }
            }
        }
    }
}

/** iOS zebra: units segmented + compact zone rows (switch + number + colour dots). */
@Composable
private fun ZebraSettingsRows(
    settings: OperatorSettings,
    cameraInput: ExposureAssistCameraInput,
    onInteraction: () -> Unit,
) {
    val configuration = settings.feedEffectsConfiguration
    SettingsRowCard(
        title = stringResource(R.string.settings_zebra),
        onReset = {
            settings.resetZebraConfiguration()
            onInteraction()
        },
    ) {
        SettingsInlineRow(
            title = stringResource(R.string.settings_units),
            showTopDivider = false,
            stacked = true,
        ) {
            SettingsSegmented(
                options = FeedZebraUnit.entries.map { it.label },
                selected = configuration.zebraUnit.label,
            ) { label ->
                FeedZebraUnit.entries.firstOrNull { it.label == label }?.let { unit ->
                    settings.feedEffectsConfiguration = configuration.copy(zebraUnit = unit)
                    onInteraction()
                }
            }
        }
        ZebraZoneRow(
            title = stringResource(R.string.settings_highlight),
            enabled = configuration.zebraHighlightEnabled,
            onEnabledToggle = {
                settings.feedEffectsConfiguration =
                    configuration.copy(zebraHighlightEnabled = !configuration.zebraHighlightEnabled)
                onInteraction()
            },
            cameraInput = cameraInput,
            unit = configuration.zebraUnit,
            monitorPercent = configuration.zebraHighlightIre,
            onThreshold = { percent ->
                settings.feedEffectsConfiguration = configuration.copy(zebraHighlightIre = percent)
                onInteraction()
            },
            palette = SettingsPalette.highlight,
            selectedColor = configuration.zebraHighlightColor.label,
            onColor = { name ->
                FeedZebraStripeColor.entries.firstOrNull { it.label == name }?.let { color ->
                    settings.feedEffectsConfiguration =
                        configuration.copy(zebraHighlightColor = color)
                    onInteraction()
                }
            },
        )
        ZebraZoneRow(
            title = stringResource(R.string.settings_midtone),
            enabled = configuration.zebraMidtoneEnabled,
            onEnabledToggle = {
                settings.feedEffectsConfiguration =
                    configuration.copy(zebraMidtoneEnabled = !configuration.zebraMidtoneEnabled)
                onInteraction()
            },
            cameraInput = cameraInput,
            unit = configuration.zebraUnit,
            monitorPercent = configuration.zebraMidtoneIre,
            onThreshold = { percent ->
                settings.feedEffectsConfiguration = configuration.copy(zebraMidtoneIre = percent)
                onInteraction()
            },
            palette = SettingsPalette.midtone,
            selectedColor = configuration.zebraMidtoneColor.label,
            onColor = { name ->
                FeedZebraStripeColor.entries.firstOrNull { it.label == name }?.let { color ->
                    settings.feedEffectsConfiguration =
                        configuration.copy(zebraMidtoneColor = color)
                    onInteraction()
                }
            },
        )
    }
}

/**
 * iOS `zebraZoneRow` (compact): title stacked above switch + number field + colour
 * dots on one control row.
 */
@Composable
private fun ZebraZoneRow(
    title: String,
    enabled: Boolean,
    onEnabledToggle: () -> Unit,
    cameraInput: ExposureAssistCameraInput,
    unit: FeedZebraUnit,
    monitorPercent: Float,
    onThreshold: (Float) -> Unit,
    palette: List<SettingsColorDot>,
    selectedColor: String,
    onColor: (String) -> Unit,
) {
    val editorValue =
        remember(cameraInput, unit, monitorPercent) {
            zebraEditorValue(cameraInput, unit, monitorPercent)
        }
    val maximum = if (unit == FeedZebraUnit.NATIVE) 255 else 100
    SettingsInlineRow(title = title, stacked = true) {
        Row(
            Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(Modifier.settingsClickable(role = Role.Switch, onClick = onEnabledToggle)) {
                SettingsSwitchGraphic(isOn = enabled)
            }
            if (editorValue != null) {
                Box(Modifier.testTag("settings.zebra.threshold.$title")) {
                    MonitorSettingsNumberField(
                        value = editorValue.roundToInt().coerceIn(0, maximum),
                        maximum = maximum,
                    ) { value ->
                        zebraMonitorPercent(cameraInput, unit, value.toFloat())?.let(onThreshold)
                    }
                }
            }
            Spacer(Modifier.weight(1f))
            SettingsColorDots(
                dots = palette,
                selectedName = selectedColor,
                compact = true,
                onSelect = onColor,
            )
        }
    }
}

/** Digits-only direct entry with the same closed-range clamp as iOS. */
internal fun normalizedZebraEntry(raw: String, maximum: Int): Int? =
    raw.toIntOrNull()?.coerceIn(0, maximum)

/** Canvas-only scope controls. Each option below has a corresponding render/sampler path. */
/** Waveform card — iOS segmented mode, percent slider, guide switches. */
@Composable
private fun WaveformSettingsCard(settings: OperatorSettings, onInteraction: () -> Unit) {
    val configuration = settings.scopeAssistConfiguration
    SettingsRowCard(
        title = stringResource(R.string.settings_waveform),
        onReset = {
            settings.resetWaveformConfiguration()
            onInteraction()
        },
    ) {
        SettingsInlineRow(
            title = stringResource(R.string.settings_mode),
            showTopDivider = false,
            stacked = true,
        ) {
            SettingsSegmented(
                options = ScopeWaveformMode.entries.map { it.label },
                selected = configuration.waveformMode.label,
            ) { label ->
                ScopeWaveformMode.entries.firstOrNull { it.label == label }?.let { mode ->
                    settings.scopeAssistConfiguration = configuration.copy(waveformMode = mode)
                    onInteraction()
                }
            }
        }
        ScopeBrightnessRow(
            brightness = configuration.waveformBrightness,
            onSelect = { value ->
                settings.scopeAssistConfiguration = configuration.copy(waveformBrightness = value)
                onInteraction()
            },
        )
        ScopeGuideRows(
            guides = configuration.waveformGuides,
            onChange = { guides ->
                settings.scopeAssistConfiguration = configuration.copy(waveformGuides = guides)
                onInteraction()
            },
        )
    }
}

/** Parade card — iOS segmented mode, percent slider, guide switches. */
@Composable
private fun ParadeSettingsCard(settings: OperatorSettings, onInteraction: () -> Unit) {
    val configuration = settings.scopeAssistConfiguration
    SettingsRowCard(
        title = stringResource(R.string.settings_parade),
        onReset = {
            settings.resetParadeConfiguration()
            onInteraction()
        },
    ) {
        SettingsInlineRow(
            title = stringResource(R.string.settings_mode),
            showTopDivider = false,
            stacked = true,
        ) {
            SettingsSegmented(
                options = ScopeParadeMode.entries.map { it.label },
                selected = configuration.paradeMode.label,
            ) { label ->
                ScopeParadeMode.entries.firstOrNull { it.label == label }?.let { mode ->
                    settings.scopeAssistConfiguration = configuration.copy(paradeMode = mode)
                    onInteraction()
                }
            }
        }
        ScopeBrightnessRow(
            brightness = configuration.paradeBrightness,
            onSelect = { value ->
                settings.scopeAssistConfiguration = configuration.copy(paradeBrightness = value)
                onInteraction()
            },
        )
        ScopeGuideRows(
            guides = configuration.paradeGuides,
            onChange = { guides ->
                settings.scopeAssistConfiguration = configuration.copy(paradeGuides = guides)
                onInteraction()
            },
        )
    }
}

/** Vectorscope card — iOS trace zoom + brightness slider. */
@Composable
private fun VectorscopeSettingsCard(settings: OperatorSettings, onInteraction: () -> Unit) {
    val configuration = settings.scopeAssistConfiguration
    SettingsRowCard(
        title = stringResource(R.string.settings_vectorscope),
        onReset = {
            settings.resetVectorscopeConfiguration()
            onInteraction()
        },
    ) {
        SettingsInlineRow(
            title = stringResource(R.string.settings_trace_zoom),
            showTopDivider = false,
            stacked = true,
        ) {
            SettingsSegmented(
                options = ScopeVectorscopeZoom.entries.map { it.label },
                selected = configuration.vectorscopeZoom.label,
            ) { label ->
                ScopeVectorscopeZoom.entries.firstOrNull { it.label == label }?.let { zoom ->
                    settings.scopeAssistConfiguration = configuration.copy(vectorscopeZoom = zoom)
                    onInteraction()
                }
            }
        }
        ScopeBrightnessRow(
            brightness = configuration.vectorscopeBrightness,
            onSelect = { value ->
                settings.scopeAssistConfiguration = configuration.copy(vectorscopeBrightness = value)
                onInteraction()
            },
        )
    }
}

/**
 * Histogram card — iOS: Traffic Lights switch + Crush/Clip Compensation (panel
 * scale is not an operator-setup control on iOS).
 */
@Composable
private fun HistogramSettingsCard(settings: OperatorSettings, onInteraction: () -> Unit) {
    SettingsRowCard(
        title = stringResource(R.string.settings_histogram),
        onReset = {
            settings.resetHistogramConfiguration()
            onInteraction()
        },
    ) {
        SettingsSwitchRow(
            stringResource(R.string.settings_traffic_lights),
            isOn = settings.histogramTrafficLightsEnabled.value,
            showTopDivider = false,
            stacked = true,
        ) {
            settings.histogramTrafficLightsEnabled.toggle()
            onInteraction()
        }
        SettingsInlineRow(title = stringResource(R.string.settings_crush_clip), stacked = true) {
            CrushClipSegmentedControl(
                selected = settings.scopeCrushClipCompensation,
                onSelect = { compensation ->
                    settings.scopeCrushClipCompensation = compensation
                    onInteraction()
                },
            )
        }
    }
}

/** Traffic Lights card — iOS: Crush/Clip Compensation only (shared with histogram). */
@Composable
private fun TrafficLightsSettingsCard(settings: OperatorSettings, onInteraction: () -> Unit) {
    SettingsRowCard(
        title = stringResource(R.string.settings_traffic_lights),
        onReset = {
            settings.resetTrafficLightsConfiguration()
            onInteraction()
        },
    ) {
        SettingsInlineRow(
            title = stringResource(R.string.settings_crush_clip),
            showTopDivider = false,
            stacked = true,
        ) {
            CrushClipSegmentedControl(
                selected = settings.scopeCrushClipCompensation,
                onSelect = { compensation ->
                    settings.scopeCrushClipCompensation = compensation
                    onInteraction()
                },
            )
        }
    }
}

@Composable
private fun CrushClipSegmentedControl(
    selected: ScopeCrushClipCompensation,
    onSelect: (ScopeCrushClipCompensation) -> Unit,
) {
    SettingsCrushClipSegmented(
        options = ScopeCrushClipCompensation.entries.map { it.label to it.compactLabel },
        selectedLabel = selected.label,
    ) { label ->
        ScopeCrushClipCompensation.entries.firstOrNull { it.label == label }?.let(onSelect)
    }
}

@Composable
private fun ScopeBrightnessRow(brightness: Int, onSelect: (Int) -> Unit) {
    SettingsInlineRow(title = stringResource(R.string.settings_brightness), stacked = true) {
        SettingsPercentSlider(
            value = brightness,
            range =
                ScopeAssistConfiguration.MIN_BRIGHTNESS..ScopeAssistConfiguration.MAX_BRIGHTNESS,
            onChange = onSelect,
        )
    }
}

@Composable
private fun ScopeGuideRows(guides: ScopeGuideLines, onChange: (ScopeGuideLines) -> Unit) {
    SettingsSwitchRow(
        stringResource(R.string.settings_safe_border_clip),
        isOn = guides.clip,
        stacked = true,
    ) {
        onChange(guides.copy(clip = !guides.clip))
    }
    SettingsSwitchRow(
        stringResource(R.string.settings_safe_border_crush),
        isOn = guides.crush,
        stacked = true,
    ) {
        onChange(guides.copy(crush = !guides.crush))
    }
    SettingsSwitchRow(
        stringResource(R.string.settings_middle_gray),
        isOn = guides.middle,
        stacked = true,
    ) {
        onChange(guides.copy(middle = !guides.middle))
    }
}

/** Controls whose effects stay wholly within the Android shell. */
@Composable
private fun ControlsRows(
    settings: OperatorSettings,
    feedback: () -> Unit,
    onToggle: (OperatorSettings.Toggle) -> Unit,
) {
    MonitorOperatorSafetySettings(
        recordConfirmation = settings.recordConfirmationEnabled.value,
        haptics = settings.hapticsEnabled.value,
        keepScreenAwake = settings.keepScreenAwake.value,
        onRecordConfirmation = { settings.recordConfirmationEnabled.value = it },
        onHaptics = { settings.hapticsEnabled.value = it },
        onKeepScreenAwake = { settings.keepScreenAwake.value = it },
        keepScreenAwakeHelp = "Keeps the live monitor or clip playback awake while the app is active.",
        feedback = feedback,
    )
    MonitorSettingsRowCard(title = "Input & orientation") {
        MonitorSettingsSwitchInlineRow(
            title = stringResource(R.string.settings_media_remote),
            isOn = settings.mediaRemoteShutterEnabled.value,
            showTopDivider = false,
        ) { onToggle(settings.mediaRemoteShutterEnabled) }
        Text(
            stringResource(R.string.settings_media_remote_caption),
            style = chromeStyle(10.5f, FontWeight.Normal),
            color = LiveDesign.muted,
            modifier = Modifier.padding(bottom = 6.dp),
        )
        MonitorSettingsSwitchInlineRow(
            title = stringResource(R.string.settings_auto_rotate_feed),
            isOn = settings.autoRotateFeedEnabled.value,
            help = stringResource(R.string.help_controls_auto_rotate_feed),
        ) { onToggle(settings.autoRotateFeedEnabled) }
    }
}

/** Compact active/inactive choice chip shared by the local image-assist settings. */
@Composable
private fun AssistChoice(label: String, selected: Boolean, onClick: () -> Unit) {
    Text(
        label,
        style = chromeStyle(10f, FontWeight.SemiBold, mono = true),
        color = if (selected) LiveDesign.accent else LiveDesign.muted,
        maxLines = 1,
        modifier =
            Modifier
                .background(
                    if (selected) LiveDesign.accentDim else LiveDesign.background.copy(alpha = 0.38f),
                    ChromeShape,
                )
                .border(1.dp, if (selected) LiveDesign.accentDim else LiveDesign.hairline, ChromeShape)
                .settingsClickable(role = Role.RadioButton, onClick = onClick)
                .padding(horizontal = 6.dp, vertical = 5.dp),
    )
}

/** Local progressive-media cache controls, available before a camera connects. */
@Composable
private fun StorageRows(
    mediaCacheStore: MediaCacheStore,
    frameioController: FrameioDeliveryController?,
    condensed: Boolean,
    onCompletedMediaCacheCleared: () -> Unit,
) {
    val context = LocalContext.current
    val resources = LocalResources.current
    val scope = rememberCoroutineScope()
    val storageState = remember(mediaCacheStore) { MediaCacheSettingsState(mediaCacheStore) }
    var snapshot by remember(mediaCacheStore) { mutableStateOf<MediaCacheStorageSnapshot?>(null) }
    var loadFailure by remember(mediaCacheStore) { mutableStateOf<String?>(null) }
    var clearing by remember { mutableStateOf(false) }

    LaunchedEffect(storageState) {
        try {
            snapshot = withContext(Dispatchers.IO) { storageState.refresh() }
            loadFailure = null
        } catch (error: Exception) {
            loadFailure = error.message ?: resources.getString(R.string.cache_read_failed)
        }
    }

    // iOS order: Frame.io first, then one Local Media Cache / Clear Cache card.
    frameioController?.let { controller ->
        FrameioStorageRows(controller, condensed)
    }
    fun clearNow() {
        clearing = true
        loadFailure = null
        scope.launch {
            try {
                snapshot = withContext(Dispatchers.IO) { storageState.clearCompleted() }
                onCompletedMediaCacheCleared()
            } catch (error: Exception) {
                loadFailure = error.message ?: resources.getString(R.string.cache_clear_failed)
            } finally {
                clearing = false
            }
        }
    }
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        MonitorCacheSettings(
            sizeLabel = cacheSizeLabel(context, snapshot?.usage?.totalBytes),
            clearing = clearing,
            scopeHelp = stringResource(R.string.help_storage_cache),
            clearHelp = stringResource(R.string.help_storage_clear_cache),
            clear = ::clearNow,
        )
        snapshot?.clearResult?.let { result ->
            Text(
                clearResultLabel(context, result),
                style = chromeStyle(10.5f, FontWeight.Normal),
                color = LiveDesign.good,
            )
        }
        loadFailure?.let { message ->
            Text(
                message,
                style = chromeStyle(10.5f, FontWeight.Normal),
                color = LiveDesign.accent,
            )
        }
    }
}

/** Frame.io account entry point; upload project selection lives beside media selection. */
@Composable
private fun FrameioStorageRows(controller: FrameioDeliveryController, condensed: Boolean) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var hopConfirmVisible by remember { mutableStateOf(false) }
    var hopBusy by remember { mutableStateOf(false) }
    LaunchedEffect(controller) { controller.refresh() }

    fun beginSignIn() {
        val authorizationURL = controller.beginSignIn() ?: return
        try {
            context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(authorizationURL)))
        } catch (_: Exception) {
            controller.signInBrowserUnavailable()
        }
    }

    /**
     * iOS `signInFrameioOverInternet` (MonitorPanels.swift:4922): Adobe sign-in is an HTTPS
     * round trip, and the camera AP has no internet — so leave it, wait for a validated route,
     * and only then hand the authorization URL to a browser. Without this the button called
     * `beginSignIn`, which failed `requireOnline` and wrote an error string, every time.
     * The camera rejoin runs when Operator Setup is dismissed, because the browser round trip
     * (and the redirect back into MainActivity) outlives this row.
     */
    fun signInOverInternet() {
        scope.launch {
            hopBusy = true
            val online =
                try {
                    controller.beginInternetHop()
                } catch (_: Exception) {
                    false
                }
            hopBusy = false
            // A failed hop already left its operator-facing reason in `errorMessage`, which
            // this card renders under the row.
            if (online) beginSignIn()
        }
    }

    fun requestSignIn() {
        if (settingsActionNeedsInternetHop(controller.networkState)) {
            hopConfirmVisible = true
        } else {
            beginSignIn()
        }
    }

    @Suppress("UNUSED_PARAMETER")
    val unusedCondensed = condensed
    val connectionLabel =
        when (controller.connectionState) {
            FrameioConnectionState.UNCONFIGURED -> stringResource(R.string.status_not_configured)
            FrameioConnectionState.SIGNED_OUT -> stringResource(R.string.frameio_not_connected)
            FrameioConnectionState.AUTHORIZING -> stringResource(R.string.frameio_waiting_signin)
            FrameioConnectionState.CONNECTED -> stringResource(R.string.status_connected)
            FrameioConnectionState.ERROR -> stringResource(R.string.status_needs_attention)
        }

    // iOS Storage: single "Frame.io" row with Log out / Sign in / status value.
    SettingsRowCard {
        SettingsInlineRow(
            title = stringResource(R.string.frameio_delivery),
            help = stringResource(R.string.help_storage_frameio),
            showTopDivider = false,
        ) {
            when {
                hopBusy -> SettingsValueText(stringResource(R.string.frameio_switching_networks))
                controller.connectionState == FrameioConnectionState.CONNECTED ->
                    SettingsLinkAction(stringResource(R.string.action_log_out)) {
                        controller.disconnect()
                    }
                controller.connectionState == FrameioConnectionState.UNCONFIGURED ->
                    SettingsValueText(stringResource(R.string.frameio_not_set_up))
                controller.connectionState == FrameioConnectionState.SIGNED_OUT ->
                    if (settingsActionNeedsInternetHop(controller.networkState)) {
                        SettingsLinkAction(stringResource(R.string.frameio_sign_in_over_internet)) {
                            requestSignIn()
                        }
                    } else {
                        SettingsLinkAction(stringResource(R.string.action_sign_in)) { beginSignIn() }
                    }
                controller.connectionState == FrameioConnectionState.ERROR ->
                    SettingsLinkAction(stringResource(R.string.action_try_again)) { requestSignIn() }
                else -> SettingsValueText(connectionLabel)
            }
        }
        controller.errorMessage?.let { message ->
            Text(
                message,
                style = chromeStyle(10.5f, FontWeight.Normal),
                color = LiveDesign.accent,
            )
        }
    }

    // iOS "Leave camera Wi-Fi to sign in?" (MonitorPanels.swift:4875-4882): the camera link
    // drops for the duration, so the operator says yes to that before anything happens.
    if (hopConfirmVisible) {
        AlertDialog(
            onDismissRequest = { hopConfirmVisible = false },
            title = { Text(stringResource(R.string.frameio_hop_signin_title)) },
            text = { Text(stringResource(R.string.frameio_hop_signin_message)) },
            confirmButton = {
                TextButton(
                    onClick = {
                        hopConfirmVisible = false
                        signInOverInternet()
                    },
                ) {
                    Text(stringResource(R.string.action_sign_in))
                }
            },
            dismissButton = {
                TextButton(onClick = { hopConfirmVisible = false }) {
                    Text(stringResource(R.string.action_cancel))
                }
            },
        )
    }
}

private fun cacheSizeLabel(context: Context, bytes: Long?): String =
    when {
        bytes == null -> context.getString(R.string.status_calculating)
        bytes == 0L -> context.getString(R.string.status_empty)
        else -> Formatter.formatFileSize(context, bytes)
    }

private fun clearResultLabel(context: Context, result: MediaCacheClearResult): String =
    when {
        result.removedCompleteEntryCount == 0 -> context.getString(R.string.cache_none_removed)
        result.preservedIncompleteEntryCount == 0 ->
            context.getString(
                R.string.cache_removed,
                cacheSizeLabel(context, result.removedCompleteBytes),
            )
        else ->
            context.getString(
                R.string.cache_removed_preserved,
                cacheSizeLabel(context, result.removedCompleteBytes),
                cacheSizeLabel(context, result.preservedIncompleteBytes),
            )
    }

/** System tab: native support/share intents, replayable guide, project links, and build data. */
@Composable
internal fun SystemRows(
    actions: SystemSettingsActions,
    onReportProblem: () -> Unit,
    guideController: LiveViewGuideController,
    onShowGuideNow: (() -> Unit)?,
    onShowGuideOnNextRealFrame: () -> Unit,
) {
    val context = LocalContext.current
    val unavailableMessage = stringResource(R.string.system_action_unavailable)
    fun runAction(action: () -> Boolean) {
        if (!action()) {
            Toast.makeText(
                context,
                unavailableMessage,
                Toast.LENGTH_SHORT,
            ).show()
        }
    }

    MonitorSupportSettings(
        reportTitle = stringResource(R.string.system_report_problem),
        reportHelp = "Choose an anonymous in-app report or the richer signed-in GitHub form. Either creates a public GitHub issue.",
        reportActionTitle = stringResource(R.string.action_report),
        report = onReportProblem,
        actions = listOf(
            MonitorSupportAction(id = "support.open", title = stringResource(R.string.system_support),
                actionTitle = stringResource(R.string.action_open),
                accessibilityLabel = stringResource(R.string.system_open_support),
                action = { runAction(actions::openSupport) }),
            MonitorSupportAction(id = "support.feature", title = stringResource(R.string.system_request_feature),
                actionTitle = stringResource(R.string.action_request),
                accessibilityLabel = stringResource(R.string.system_request_feature),
                action = { runAction(actions::requestFeature) }),
            MonitorSupportAction(id = "support.diagnostics", title = stringResource(R.string.system_share_diagnostics),
                actionTitle = stringResource(R.string.action_share),
                accessibilityLabel = stringResource(R.string.system_share_diagnostics),
                action = { runAction(actions::shareDiagnostics) }),
            MonitorSupportAction(id = "support.guide", title = stringResource(R.string.system_live_view_guide),
                actionTitle = stringResource(R.string.action_show_again),
                accessibilityLabel = "Show Live View Guide Again",
                action = {
                    if (onShowGuideNow != null) onShowGuideNow()
                    else onShowGuideOnNextRealFrame()
                }),
        ),
    )

    MonitorProjectLegalSettings(
        sourceHelp = "View the OpenZCine project and contribute on GitHub.",
        termsHelp = "Read the OpenZCine terms of use.",
        source = { runAction(actions::openSource) },
        privacy = { runAction(actions::openPrivacy) },
        terms = { runAction(actions::openTerms) },
    )
    MonitorAppInformationSettings(
        theme = stringResource(R.string.system_theme_warm_dark),
        protocolName = "PTP / PTP-IP",
        version = appVersionText(BuildConfig.VERSION_NAME, BuildConfig.VERSION_CODE),
        themeHelp = "Dark earth interface tuned for low reflection on set.",
        protocolHelp = "Camera control speaks standard PTP over USB and PTP-IP over Wi-Fi.",
        versionHelp = "Current OpenZCine build from the native project metadata.",
    )
}

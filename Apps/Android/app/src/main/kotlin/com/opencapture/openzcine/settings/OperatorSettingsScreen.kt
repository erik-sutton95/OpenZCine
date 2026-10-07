package com.opencapture.openzcine.settings

import com.opencapture.monitorui.settings.MonitorSettingsInlineRow
import com.opencapture.monitorui.settings.MonitorSettingsValueText
import com.opencapture.monitorui.settings.MonitorSettingsSegmented
import com.opencapture.monitorui.settings.MonitorSettingsChoices
import com.opencapture.monitorui.settings.MonitorSettingsActionPill
import com.opencapture.monitorui.settings.MonitorConnectionSettings
import com.opencapture.monitorui.MonitorLinkHealth
import com.opencapture.monitorui.settings.MonitorLinkHealthScale
import com.opencapture.monitorui.settings.MonitorSupportAction
import com.opencapture.monitorui.settings.MonitorSupportSettings
import com.opencapture.opencine.appkit.diagnostics.settingsStatus
import com.opencapture.openzcine.NikonAssists
import com.opencapture.openzcine.performOperatorHaptic
import com.opencapture.monitorui.settings.LocalMonitorSettingsScrollContext
import com.opencapture.monitorui.settings.MonitorOperatorSafetySettings
import com.opencapture.monitorui.settings.MonitorInputOrientationSettings
import com.opencapture.monitorui.settings.MonitorAppInformationSettings
import com.opencapture.monitorui.settings.MonitorCacheSettings
import com.opencapture.monitorui.settings.MonitorProjectLegalSettings
import com.opencapture.monitorui.settings.MonitorSettingsPage
import com.opencapture.monitorui.settings.MonitorSettingsRowCard
import com.opencapture.monitorui.settings.MonitorSettingsSwitchInlineRow
import com.opencapture.monitorui.settings.MonitorSettingsTab
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.text.format.Formatter
import android.view.HapticFeedbackConstants
import android.widget.Toast
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalResources
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.res.stringResource
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
import com.opencapture.openzcine.ExposureAssistCameraInput
import com.opencapture.openzcine.LiveDesign
import com.opencapture.openzcine.prefersPhotographyChrome
import com.opencapture.openzcine.chromeStyle
import com.opencapture.openzcine.bridge.AndroidLinkHealthMonitor
import com.opencapture.openzcine.bridge.LinkHealthPresentation
import com.opencapture.opencine.nikon.CameraSession
import com.opencapture.opencine.nikon.CameraSessionState
import com.opencapture.openzcine.frameio.FrameioConnectionState
import com.opencapture.openzcine.frameio.FrameioDeliveryController
import com.opencapture.openzcine.frameio.FrameioNetworkState
import com.opencapture.openzcine.diagnostics.AppDiagnostics
import com.opencapture.openzcine.diagnostics.SystemSettingsActions
import com.opencapture.openzcine.media.MediaCacheClearResult
import com.opencapture.openzcine.media.MediaCacheStore
import com.opencapture.openzcine.relay.RelayCameraSession
import com.opencapture.openzcine.relay.RelayWatchUiState
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Whether an internet-backed Operator Setup action has to leave the camera's access point first
 * (iOS `requestInternetDestination`, MonitorPanels.swift:4755).
 *
 * The Adobe sign-in transacts from THIS process, and the process is bound to a Wi-Fi network
 * that has no internet at all, so it cannot reach anything until the consented hop runs. External links are unaffected: the browser is a different process and
 * never sees our binding.
 */
internal fun settingsActionNeedsInternetHop(state: FrameioNetworkState?): Boolean =
    state == FrameioNetworkState.CAMERA_ACCESS_POINT

/**
 * The full-screen Operator Settings surface — a 1:1 structural port of the
 * iOS `OperatorSettingsPanel` (ios/Runner/MonitorPanels.swift): floating close
 * button, eyebrow/title header with the live tile, vertical tab rail, and a
 * rounded content pane per tab. [assists] is the monitor's assist state,
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
    assists: NikonAssists,
    settings: OperatorSettings,
    mediaCacheStore: MediaCacheStore,
    frameioController: FrameioDeliveryController? = null,
    linkHealth: AndroidLinkHealthMonitor? = null,
    activeTransportLabel: String? = null,
    onDisconnect: (() -> Unit)? = null,
    systemSettingsActions: SystemSettingsActions,
    onReportProblem: () -> Unit,
    onCompletedMediaCacheCleared: () -> Unit = {},
    initialTab: MonitorSettingsTab = MonitorSettingsTab.LINK,
    relaySharing: com.opencapture.openzcine.relay.RelayBroadcastController? = null,
    relaySharingEnabled: Boolean = false,
    onRelayShareToggle: ((Boolean) -> Unit)? = null,
    /** Watch-session state, for the Link tab's "Held By" readout (iOS `linkRows`). */
    relayWatchUi: RelayWatchUiState? = null,
    onClose: () -> Unit,
) {
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
    val emitHaptic: () -> Unit = {
        if (settings.hapticsEnabled.value) {
            feedbackView.performOperatorHaptic(HapticFeedbackConstants.KEYBOARD_TAP)
        }
    }
    var selectedTab by rememberSaveable(initialTab) { mutableStateOf(initialTab) }
    // The camera rejoin runs when Operator Setup is dismissed, not when the Adobe browser round
    // trip ends: it outlives the row that started the hop (iOS re-hosts the panel as a standalone
    // cover for the same reason, MonitorPanels.swift:4919-4943).
    DisposableEffect(frameioController) {
        onDispose {
            val controller = frameioController
            if (controller != null && controller.isInternetHopActive) {
                controller.endInternetHopAfterDismiss()
            }
        }
    }

    BoxWithConstraints(
        Modifier.fillMaxSize()
            .background(LiveDesign.background)
            .pointerInput(Unit) { detectTapGestures {} }
            .windowInsetsPadding(WindowInsets.safeDrawing)
    ) {
        val compact = maxWidth < 600.dp
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
                MonitorSettingsTab.SHARING -> SharingRows(
                    session = session, sharing = relaySharing, settings = settings,
                    enabled = relaySharingEnabled, onShareToggle = onRelayShareToggle,
                    onInteraction = emitHaptic,
                )
                MonitorSettingsTab.LINK -> LinkRows(
                    session, settings, linkHealth, activeTransportLabel, relayWatchUi, emitHaptic,
                )
                MonitorSettingsTab.ASSIST -> NikonViewAssistSettings(assists.shared, cameraInput, emitHaptic)
                MonitorSettingsTab.CONTROLS -> ControlsRows(settings, emitHaptic)
                MonitorSettingsTab.DISPLAY -> NikonDisplaySettings(
                    settings, assists.shared, compact, toggleSetting, emitHaptic,
                    checkNotNull(scroll).scrollState, scroll.viewportBounds,
                    liveCaptureMode = if (cameraProperties != null && prefersPhotographyChrome(cameraProperties)) {
                        CaptureLayoutMode.PHOTO
                    } else {
                        CaptureLayoutMode.VIDEO
                    },
                    onEditView = { mode -> settings.beginChromeEditing(mode); onClose() },
                )
                MonitorSettingsTab.STORAGE -> StorageRows(
                    mediaCacheStore, frameioController, onCompletedMediaCacheCleared,
                )
                MonitorSettingsTab.SYSTEM -> SystemRows(
                    systemSettingsActions, onReportProblem, emitHaptic,
                )
            }
        }
        Box(Modifier.padding(start = 16.dp, top = 22.dp)) { PanelCloseButton(onClick = onClose) }
    }
}

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
        MonitorSettingsRowCard {
            MonitorSettingsInlineRow(
                title = stringResource(R.string.sharing_watching),
                help = stringResource(R.string.help_sharing_watcher),
                showTopDivider = false,
            ) {
                MonitorSettingsValueText(
                    (state as? CameraSessionState.Connected)?.identity?.name
                        ?: stringResource(R.string.camera_none),
                )
            }
        }
        return
    }
    val ui = if (sharing == null) null else sharing.ui.collectAsState().value
    var passcodeDraft by remember { mutableStateOf(settings.relayWatcherPasscode.value) }
    MonitorSettingsRowCard {
        if (sharing == null) {
            MonitorSettingsInlineRow(
                title = stringResource(R.string.sharing_share_this_feed),
                help = stringResource(R.string.help_sharing_share_feed),
                showTopDivider = false,
            ) {
                MonitorSettingsValueText(stringResource(R.string.sharing_share_unavailable))
            }
        } else {
            MonitorSettingsSwitchInlineRow(
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
            MonitorSettingsInlineRow(
                title = stringResource(R.string.sharing_watching),
                help = stringResource(R.string.help_sharing_watching),
            ) {
                MonitorSettingsValueText(stringResource(R.string.sharing_watching_count, ui.watcherCount))
            }
        }
        // Between Watching and the passcode, exactly where the iOS Sharing panel puts it. The
        // option words come from the shared core rather than a string resource, so the two shells
        // cannot end up offering differently-named stances.
        MonitorSettingsInlineRow(
            title = stringResource(R.string.sharing_broadcast_priority),
            help = stringResource(R.string.help_sharing_priority),
        ) {
            val profile =
                com.opencapture.openzcine.core.RelayEncoderProfile.fromWireValue(
                    settings.relayEncoderProfile.value
                )
            MonitorSettingsSegmented(
                options =
                    com.opencapture.openzcine.core.RelayEncoderProfile.entries.map { it.title },
                selected = profile.title,
            ) { value ->
                val picked =
                    com.opencapture.openzcine.core.RelayEncoderProfile.entries.firstOrNull {
                        it.title == value
                    } ?: return@MonitorSettingsSegmented
                settings.relayEncoderProfile.value = picked.wireValue
                sharing?.encoderProfile = picked
                onInteraction()
            }
        }
        MonitorSettingsInlineRow(
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
        MonitorSettingsSwitchInlineRow(
            stringResource(R.string.sharing_control_requests),
            isOn = settings.relayAllowsControlRequests.value,
            help = stringResource(R.string.help_sharing_control_requests),
        ) {
            settings.relayAllowsControlRequests.toggle()
            sharing?.allowsControlRequests = settings.relayAllowsControlRequests.value
            onInteraction()
        }
        ui?.pendingControlRequestName?.let {
            MonitorSettingsInlineRow(
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
            MonitorSettingsInlineRow(
                title = stringResource(R.string.sharing_control_held_by),
                help = stringResource(R.string.help_sharing_camera_control),
            ) {
                Row(
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    MonitorSettingsValueText(holder)
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
    activeTransportLabel: String?,
    relayWatchUi: RelayWatchUiState?,
    onInteraction: () -> Unit,
) {
    val disconnectedState = remember { MutableStateFlow<CameraSessionState>(CameraSessionState.Disconnected) }
    val state by (session?.state ?: disconnectedState).collectAsState()
    val linked = state is CameraSessionState.Connected
    val health = linkHealth?.presentation ?: LinkHealthPresentation()
    val healthCaption =
        if (session == null || !linked) {
            health.detail.ifBlank { stringResource(R.string.settings_link_no_camera_caption) }
        } else {
            val detail = health.detail.ifBlank { stringResource(R.string.settings_active_link) }
            "$detail · ${MonitorLinkHealth.band(health.score).label}"
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
    MonitorLinkHealthScale(
        title = stringResource(R.string.settings_link_health),
        caption = healthCaption,
        score = if (linked) health.score else 0,
    )

    MonitorConnectionSettings(
        transport = transportValue,
        transportHelp = stringResource(R.string.help_link_transport),
        phase = when (state) {
            is CameraSessionState.Connected -> "Connected"
            CameraSessionState.Connecting -> "Connecting"
            CameraSessionState.Disconnected -> "Disconnected"
        },
        phaseHelp = "The current connection state reported by this device.",
    )
    MonitorSettingsRowCard(title = "Picture") {
        // A watcher drives nothing until the broadcaster hands over the token, so the Link tab
        // says who is holding it (iOS `linkRows`, videoSource == .relay). The ask/give-back
        // itself stays on the live view, not in a settings sheet.
        if (session is RelayCameraSession) {
            MonitorSettingsInlineRow(
                title = stringResource(R.string.sharing_control_held_by),
                help = stringResource(R.string.help_link_held_by),
            ) {
                MonitorSettingsValueText(
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
        MonitorSettingsInlineRow(
            title = stringResource(R.string.settings_stream_preset),
            help = stringResource(R.string.help_link_stream_preset),
        ) {
            MonitorSettingsChoices(options = LiveViewStreamPreset.entries, selected = settings.streamPreset,
                compact = false, title = { it.label }) { preset ->
                settings.streamPreset = preset
                onInteraction()
            }
        }
        MonitorSettingsInlineRow(
            title = stringResource(R.string.settings_quality_bias),
            help = stringResource(R.string.help_link_quality_bias),
        ) {
            val resources = LocalResources.current
            MonitorSettingsChoices(options = LiveViewQualityBias.entries, selected = settings.qualityBias,
                compact = false, title = { resources.getString(it.settingsLabelResource) }) { bias ->
                settings.qualityBias = bias
                onInteraction()
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
    MonitorSettingsRowCard(title = stringResource(R.string.settings_processing)) {
        MonitorSettingsInlineRow(
            title = stringResource(R.string.settings_feed_upscaler),
            help = stringResource(R.string.help_link_feed_upscaler),
            showTopDivider = false,
        ) {
            MonitorSettingsValueText(stringResource(R.string.settings_coming_soon))
        }
        MonitorSettingsInlineRow(
            title = stringResource(R.string.settings_feed_noise_reduction),
            help = stringResource(R.string.help_link_feed_noise_reduction),
        ) {
            MonitorSettingsValueText(stringResource(R.string.settings_coming_soon))
        }
    }
}

/** Controls whose effects stay wholly within the Android shell. */
@Composable
private fun ControlsRows(
    settings: OperatorSettings,
    feedback: () -> Unit,
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
    MonitorInputOrientationSettings(
        remoteShutter = settings.mediaRemoteShutterEnabled.value,
        onRemoteShutter = { settings.mediaRemoteShutterEnabled.value = it },
        remoteTitle = stringResource(R.string.settings_media_remote),
        remoteCaption = stringResource(R.string.settings_media_remote_caption),
        autoRotateFeed = settings.autoRotateFeedEnabled.value,
        onAutoRotateFeed = { settings.autoRotateFeedEnabled.value = it },
        rotationTitle = stringResource(R.string.settings_auto_rotate_feed),
        rotationHelp = stringResource(R.string.help_controls_auto_rotate_feed),
        feedback = feedback,
    )
}

/** Local progressive-media cache controls, available before a camera connects. */
@Composable
private fun StorageRows(
    mediaCacheStore: MediaCacheStore,
    frameioController: FrameioDeliveryController?,
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
        FrameioStorageRows(controller)
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
private fun FrameioStorageRows(controller: FrameioDeliveryController) {
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

    val connectionLabel =
        when (controller.connectionState) {
            FrameioConnectionState.UNCONFIGURED -> stringResource(R.string.status_not_configured)
            FrameioConnectionState.SIGNED_OUT -> stringResource(R.string.frameio_not_connected)
            FrameioConnectionState.AUTHORIZING -> stringResource(R.string.frameio_waiting_signin)
            FrameioConnectionState.CONNECTED -> stringResource(R.string.status_connected)
            FrameioConnectionState.ERROR -> stringResource(R.string.status_needs_attention)
        }

    // iOS Storage: single "Frame.io" row with Log out / Sign in / status value.
    MonitorSettingsRowCard {
        MonitorSettingsInlineRow(
            title = stringResource(R.string.frameio_delivery),
            help = stringResource(R.string.help_storage_frameio),
            showTopDivider = false,
        ) {
            when {
                hopBusy -> MonitorSettingsValueText(stringResource(R.string.frameio_switching_networks))
                controller.connectionState == FrameioConnectionState.CONNECTED ->
                    MonitorSettingsActionPill(stringResource(R.string.action_log_out)) {
                        controller.disconnect()
                    }
                controller.connectionState == FrameioConnectionState.UNCONFIGURED ->
                    MonitorSettingsValueText(stringResource(R.string.frameio_not_set_up))
                controller.connectionState == FrameioConnectionState.SIGNED_OUT ->
                    if (settingsActionNeedsInternetHop(controller.networkState)) {
                        MonitorSettingsActionPill(stringResource(R.string.frameio_sign_in_over_internet)) {
                            requestSignIn()
                        }
                    } else {
                        MonitorSettingsActionPill(stringResource(R.string.action_sign_in)) { beginSignIn() }
                    }
                controller.connectionState == FrameioConnectionState.ERROR ->
                    MonitorSettingsActionPill(stringResource(R.string.action_try_again)) { requestSignIn() }
                else -> MonitorSettingsValueText(connectionLabel)
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

/** System tab: native support/share intents, project links, and build data. */
@Composable
internal fun SystemRows(
    actions: SystemSettingsActions,
    onReportProblem: () -> Unit,
    feedback: () -> Unit = {},
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

    var automaticReports by remember { mutableStateOf(AppDiagnostics.reporting.isOptedIn) }
    val report by AppDiagnostics.manualReport.snapshot.collectAsState()
    MonitorSupportSettings(
        automaticReports = automaticReports,
        available = AppDiagnostics.reporting.isAvailable,
        automaticHelp = stringResource(R.string.help_system_automatic_reports),
        unavailableHelp = stringResource(R.string.help_system_automatic_reports_unavailable),
        onAutomaticReports = { automaticReports = it; AppDiagnostics.reporting.setConsent(it) },
        privacy = { runAction(actions::openPrivacy) },
        status = report.settingsStatus,
        discard = if (report.allowsDiscard) ({ AppDiagnostics.manualReport.discard() }) else null,
        feedback = feedback,
        reportTitle = stringResource(R.string.system_report_problem),
        reportHelp = stringResource(R.string.help_system_report_problem),
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
        theme = stringResource(R.string.system_theme_charcoal),
        protocolName = "PTP / PTP-IP",
        version = appVersionText(BuildConfig.VERSION_NAME, BuildConfig.VERSION_CODE),
        themeHelp = "Charcoal field-monitor chrome with gold accents, tuned for low reflection on set.",
        protocolHelp = "Camera control speaks standard PTP over USB and PTP-IP over Wi-Fi.",
        versionHelp = "Current OpenZCine build from the native project metadata.",
    )
}

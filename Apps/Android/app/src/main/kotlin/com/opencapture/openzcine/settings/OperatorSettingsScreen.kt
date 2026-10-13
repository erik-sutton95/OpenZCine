package com.opencapture.openzcine.settings

import com.opencapture.monitorui.settings.MonitorAccountState
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
import com.opencapture.monitorui.MonitorAssistTool
import com.opencapture.opencine.cameracontrols.*
import com.opencapture.opencine.appkit.MonitorOperatorSessionModel
import com.opencapture.opencine.appkit.MonitorSettingsCacheIdentity
import com.opencapture.opencine.appkit.MonitorSettingsCacheSource
import com.opencapture.opencine.appkit.MonitorSettingsAccountActions
import com.opencapture.opencine.appkit.MonitorSettingsAccountModel
import com.opencapture.opencine.appkit.MonitorSettingsInternetLease
import com.opencapture.opencine.appkit.MonitorSettingsInternetCleanup
import com.opencapture.monitorui.settings.MonitorDisplayChoice
import com.opencapture.monitorui.settings.MonitorAssistSettingsSection
import java.util.UUID
import com.opencapture.openzcine.performOperatorHaptic
import com.opencapture.monitorui.settings.LocalMonitorSettingsScrollContext
import com.opencapture.monitorui.settings.MonitorOperatorSafetySettings
import com.opencapture.monitorui.settings.MonitorInputOrientationSettings
import com.opencapture.monitorui.settings.MonitorAppInformationSettings
import com.opencapture.opencine.vocabulary.MediaClipFormatting
import com.opencapture.monitorui.settings.MonitorCacheSettings
import com.opencapture.monitorui.settings.MonitorProjectLegalSettings
import com.opencapture.monitorui.settings.MonitorSettingsPage
import com.opencapture.monitorui.settings.MonitorSettingsRowCard
import com.opencapture.monitorui.settings.MonitorSettingsSwitchInlineRow
import com.opencapture.monitorui.settings.MonitorSettingsTab
import android.content.Context
import android.content.Intent
import android.net.Uri
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
import com.opencapture.opencine.frameio.FrameioConnectionState
import com.opencapture.opencine.frameio.FrameioDeliveryController
import com.opencapture.opencine.frameio.FrameioNetworkState
import com.opencapture.openzcine.diagnostics.AppDiagnostics
import com.opencapture.openzcine.diagnostics.AndroidSupportLinks
import com.opencapture.openzcine.diagnostics.SystemSettingsActions
import com.opencapture.opencine.core.SavedCamera
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
    /** The display owner the Display rows edit. */
    operatorSession: MonitorOperatorSessionModel,
    /** Whether a live monitor sits under these settings, so Edit view can open on it. */
    editsLiveView: Boolean = false,
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
    accountModel: MonitorSettingsAccountModel? = null,
    accountCurrent: (() -> Boolean)? = null,
    /** The saved setups, for the Link tab's Your cameras card. */
    savedCameras: List<SavedCamera> = emptyList(),
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
    val context = LocalContext.current
    val resources = LocalResources.current
    val accountScope = rememberCoroutineScope()
    val retainedAccount = accountModel ?: remember { MonitorSettingsAccountModel(accountScope) }
    var localAccountCurrent by remember(retainedAccount) { mutableStateOf(true) }
    DisposableEffect(retainedAccount, accountModel) {
        onDispose {
            localAccountCurrent = false
            if (accountModel == null) retainedAccount.retire()
        }
    }
    val closeOwned: () -> Unit = { retainedAccount.retire(); onClose() }
    val disconnected = remember { MutableStateFlow<CameraSessionState>(CameraSessionState.Disconnected) }
    val state by (session?.state ?: disconnected).collectAsState()
    val linked = state is CameraSessionState.Connected
    val health = linkHealth?.presentation
    val phase = when (val current = state) {
        is CameraSessionState.Connected -> health?.detail?.takeIf { it.isNotBlank() }
            ?: "${current.identity.name} · ${activeTransportLabel ?: "Wi-Fi"}"
        CameraSessionState.Connecting -> stringResource(R.string.camera_connecting_short)
        CameraSessionState.Disconnected -> stringResource(R.string.settings_local_only)
    }
    val cacheOwner = remember(mediaCacheStore, session) { UUID.randomUUID() }
    var cacheCurrent by remember(cacheOwner) { mutableStateOf(true) }
    var clearReceipt by remember(cacheOwner) { mutableStateOf<String?>(null) }
    val storageState = remember(mediaCacheStore) { MediaCacheSettingsState(mediaCacheStore) }
    DisposableEffect(cacheOwner) { onDispose { cacheCurrent = false } }
    val cacheSource = MonitorSettingsCacheSource(
        MonitorSettingsCacheIdentity(mediaCacheStore.rootDirectory.toString(), cacheOwner.toString()), 0,
        isCurrent = { cacheCurrent },
        count = { withContext(Dispatchers.IO) { storageState.refresh().usage.totalBytes } },
        clear = {
            val result = withContext(Dispatchers.IO) { storageState.clearCompleted() }
            if (cacheCurrent) {
                clearReceipt = result.clearResult?.let { clearResultLabel(context, it) }
                onCompletedMediaCacheCleared()
            }
        },
        clearSummary = { clearReceipt },
    )
    // One layout per DISP mode over the shared owner; Edit view opens on the live monitor and Done
    // returns here, to Display.
    val display = MonitorOperatorDisplaySource(operatorSession, NIKON_DISPLAY_SECTIONS,
        if (editsLiveView) ({ mode -> retainedAccount.retire(); operatorSession.beginEditing(mode) }) else null)
    val unavailable = stringResource(R.string.settings_image_processing_unavailable)
    val assistSections = listOf(MonitorAssistTool.FALSE, MonitorAssistTool.ZEBRA, MonitorAssistTool.WAVE,
        MonitorAssistTool.PARADE, MonitorAssistTool.HISTO, MonitorAssistTool.VECTOR, MonitorAssistTool.PEAK,
        MonitorAssistTool.LIGHTS).mapNotNull { tool ->
        if (tool == MonitorAssistTool.FALSE && !nikonImageProcessingAvailable)
            MonitorAssistSettingsSection.Unavailable(tool, unavailable)
        else nikonAssistSection(tool, assists.shared, cameraInput, emitHaptic)
    }
    val healthCaption = if (!linked) {
        health?.detail?.takeIf { it.isNotBlank() } ?: stringResource(R.string.settings_link_no_camera_caption)
    } else {
        val detail = health?.detail?.takeIf { it.isNotBlank() } ?: stringResource(R.string.settings_active_link)
        health?.score?.let { "$detail · ${MonitorLinkHealth.band(it).label}" } ?: detail
    }
    val transportValue = if (!linked) stringResource(R.string.settings_transport_not_connected)
        else stringResource(R.string.settings_transport_active, activeTransportLabel ?: "Wi-Fi")
    val link = MonitorSettingsLinkSource(transportValue, stringResource(R.string.help_link_transport),
        when (state) {
            is CameraSessionState.Connected -> "Connected"
            CameraSessionState.Connecting -> "Connecting"
            CameraSessionState.Disconnected -> "Disconnected"
        }, "The current connection state reported by this device.",
        stringResource(R.string.settings_link_health), healthCaption, if (linked) health?.score else null,
        choices = listOf(
            MonitorSettingsChoiceSource(stringResource(R.string.settings_stream_preset),
                stringResource(R.string.help_link_stream_preset),
                LiveViewStreamPreset.entries.map { MonitorDisplayChoice(it.name, it.label) }, settings.streamPreset.name,
                select = { id -> LiveViewStreamPreset.entries.firstOrNull { it.name == id }?.let {
                    settings.streamPreset = it; emitHaptic()
                } }),
            MonitorSettingsChoiceSource(stringResource(R.string.settings_quality_bias),
                stringResource(R.string.help_link_quality_bias),
                LiveViewQualityBias.entries.map { MonitorDisplayChoice(it.name, resources.getString(it.settingsLabelResource)) },
                settings.qualityBias.name, select = { id -> LiveViewQualityBias.entries.firstOrNull { it.name == id }?.let {
                    settings.qualityBias = it; emitHaptic()
                } }),
        ),
        controlHolder = if (session is RelayCameraSession) MonitorSettingsReadoutSource(
            stringResource(R.string.sharing_control_held_by), stringResource(R.string.help_link_held_by),
            when {
                relayWatchUi == null -> stringResource(R.string.settings_control_broadcaster)
                relayWatchUi.holdsControl -> stringResource(R.string.settings_control_this_device)
                else -> relayWatchUi.controlHolderName ?: stringResource(R.string.settings_control_broadcaster)
            }) else null,
        processingTitle = stringResource(R.string.settings_processing),
        processing = listOf(
            MonitorSettingsReadoutSource(stringResource(R.string.settings_feed_upscaler),
                stringResource(R.string.help_link_feed_upscaler), stringResource(R.string.settings_coming_soon)),
            MonitorSettingsReadoutSource(stringResource(R.string.settings_feed_noise_reduction),
                stringResource(R.string.help_link_feed_noise_reduction), stringResource(R.string.settings_coming_soon)),
        ),
        savedCameras = monitorSavedCameraSummaries(savedCameras),
        savedCamerasHelp = stringResource(R.string.help_link_saved_cameras),
    )
    val controls = MonitorSettingsControlsSource(settings.recordConfirmationEnabled.value,
        { settings.recordConfirmationEnabled.value = it }, settings.hapticsEnabled.value,
        { settings.hapticsEnabled.value = it }, settings.keepScreenAwake.value,
        { settings.keepScreenAwake.value = it },
        "Keeps the live monitor or clip playback awake while the app is active.",
        remoteShutter = settings.mediaRemoteShutterEnabled.value,
        setRemoteShutter = { settings.mediaRemoteShutterEnabled.value = it },
        remoteTitle = stringResource(R.string.settings_media_remote),
        remoteCaption = stringResource(R.string.settings_media_remote_caption),
        autoRotateFeed = settings.autoRotateFeedEnabled.value,
        setAutoRotateFeed = { settings.autoRotateFeedEnabled.value = it },
        rotationTitle = stringResource(R.string.settings_auto_rotate_feed),
        rotationHelp = stringResource(R.string.help_controls_auto_rotate_feed))
    val account = frameioController?.let { controller ->
        accountSource(controller, retainedAccount, accountCurrent ?: { localAccountCurrent })
    }
    val configuration = MonitorOperatorSettingsConfiguration("OpenZCine", linked, phase,
        closeOwned, onDisconnect?.let { disconnect -> { retainedAccount.retire(); disconnect() } }, emitHaptic, link,
        sharingSource(session, relaySharing, settings, relaySharingEnabled, onRelayShareToggle, emitHaptic),
        stringResource(R.string.settings_subtitle_sharing), "Broadcast & watchers", controls,
        cache = MonitorSettingsCachePresentation(cacheSource, formatBytes = { cacheSizeLabel(context, it) },
            checking = stringResource(R.string.status_calculating), readFailure = stringResource(R.string.cache_read_failed),
            clearFailure = stringResource(R.string.cache_clear_failed), scopeHelp = stringResource(R.string.help_storage_cache),
            clearHelp = stringResource(R.string.help_storage_clear_cache), summaryColor = LiveDesign.good),
        account = account,
        support = supportSource(systemSettingsActions, onReportProblem),
        diagnostics = MonitorSettingsDiagnosticsSource(
            save = { if (!systemSettingsActions.shareDiagnostics()) toastUnavailable(context) },
            incidents = AppDiagnostics.incidents),
        legal = remember(context) {
            zLegalDocuments(context.assets.open("NOTICE").bufferedReader().use { it.readText() }.trimEnd())
        },
        information = MonitorSettingsInformationSource(stringResource(R.string.system_theme_charcoal), "PTP / PTP-IP",
            appVersionText(BuildConfig.VERSION_NAME, BuildConfig.VERSION_CODE),
            "Charcoal field-monitor chrome with gold accents, tuned for low reflection on set.",
            "Camera control speaks standard PTP over USB and PTP-IP over Wi-Fi.",
            "Current OpenZCine build from the native project metadata."),
    )
    MonitorOperatorSettingsScreen(configuration, assistSections, display, initialTab, cacheOwner)
}

/** Actual broadcast service observations and admitted native actions. */
@Composable
private fun sharingSource(session: CameraSession?, sharing: com.opencapture.openzcine.relay.RelayBroadcastController?,
    settings: OperatorSettings, enabled: Boolean, onShareToggle: ((Boolean) -> Unit)?,
    feedback: () -> Unit): MonitorSettingsSharingSource {
    val state = if (session is RelayCameraSession) session.state.collectAsState().value else null
    val ui = sharing?.ui?.collectAsState()?.value
    val pendingRequest = ui?.pendingControlRequest
    val profile = com.opencapture.openzcine.core.RelayEncoderProfile.fromWireValue(settings.relayEncoderProfile.value)
    return MonitorSettingsSharingSource(
        watching = if (session is RelayCameraSession) MonitorSettingsReadoutSource(
            stringResource(R.string.sharing_watching), stringResource(R.string.help_sharing_watcher),
            (state as? CameraSessionState.Connected)?.identity?.name ?: stringResource(R.string.camera_none)) else null,
        sharingTitle = stringResource(R.string.sharing_share_this_feed), sharingHelp = stringResource(R.string.help_sharing_share_feed),
        sharing = if (sharing == null) null else enabled, setSharing = if (sharing == null) null else onShareToggle,
        unavailable = stringResource(R.string.sharing_share_unavailable), failure = ui?.failureReason,
        watcherCount = ui?.let { MonitorSettingsReadoutSource(stringResource(R.string.sharing_watching),
            stringResource(R.string.help_sharing_watching), stringResource(R.string.sharing_watching_count, it.watcherCount)) },
        priority = MonitorSettingsChoiceSource(stringResource(R.string.sharing_broadcast_priority),
            stringResource(R.string.help_sharing_priority), com.opencapture.openzcine.core.RelayEncoderProfile.entries.map {
                MonitorDisplayChoice(it.wireValue.toString(), it.title)
            }, profile.wireValue.toString(), select = { id ->
                com.opencapture.openzcine.core.RelayEncoderProfile.entries.firstOrNull { it.wireValue.toString() == id }?.let {
                    settings.relayEncoderProfile.value = it.wireValue; sharing?.encoderProfile = it; feedback()
                }
            }, segmented = true),
        passcodeTitle = stringResource(R.string.sharing_watcher_passcode), passcodeHelp = stringResource(R.string.help_sharing_passcode),
        passcode = settings.relayWatcherPasscode.value, setPasscode = {
            settings.relayWatcherPasscode.value = it; sharing?.watcherPasscode = it
        }, controlRequestsTitle = stringResource(R.string.sharing_control_requests),
        controlRequestsHelp = stringResource(R.string.help_sharing_control_requests),
        controlRequests = settings.relayAllowsControlRequests.value, setControlRequests = {
            settings.relayAllowsControlRequests.value = it; sharing?.allowsControlRequests = it
        }, pending = ui?.pendingControlRequestName?.let { MonitorSettingsReadoutSource(
            stringResource(R.string.sharing_control_requested), stringResource(R.string.help_sharing_control_requested), it) },
        declineTitle = stringResource(R.string.sharing_decline), decline = pendingRequest?.let { captured ->
            sharing?.let { owner -> { owner.declinePendingControl(captured) } }
        },
        grantTitle = stringResource(R.string.sharing_grant), grant = pendingRequest?.let { captured ->
            sharing?.let { owner -> { owner.grantPendingControl(captured) } }
        },
        holder = ui?.controlHolderName?.let { MonitorSettingsReadoutSource(stringResource(R.string.sharing_control_held_by),
            stringResource(R.string.help_sharing_camera_control), it) },
        takeBackTitle = stringResource(R.string.sharing_take_back), takeBack = sharing?.let { it::reclaimControl },
    )
}

/** OS support/account adapters retain native permissions, consent and actual intents. */
@Composable
private fun supportSource(actions: SystemSettingsActions, onReportProblem: () -> Unit): MonitorSettingsSupportSource {
    val context = LocalContext.current
    fun runAction(action: () -> Boolean) {
        if (!action()) toastUnavailable(context)
    }
    var automaticReports by remember { mutableStateOf(AppDiagnostics.reporting.isOptedIn) }
    val report by AppDiagnostics.manualReport.snapshot.collectAsState()
    return MonitorSettingsSupportSource(onReportProblem, automaticReports, AppDiagnostics.reporting.isAvailable,
        stringResource(R.string.help_system_automatic_reports), stringResource(R.string.help_system_automatic_reports_unavailable),
        { automaticReports = it; AppDiagnostics.reporting.setConsent(it) },
        stringResource(R.string.system_report_problem), stringResource(R.string.help_system_report_problem),
        stringResource(R.string.action_report),
        report.settingsStatus, if (report.allowsDiscard) ({ AppDiagnostics.manualReport.discard() }) else null,
        listOf(
            MonitorSupportAction("support.open", stringResource(R.string.system_support), actionTitle = stringResource(R.string.action_open),
                accessibilityLabel = stringResource(R.string.system_open_support), action = { runAction(actions::openSupport) }),
            MonitorSupportAction("support.feature", stringResource(R.string.system_request_feature), actionTitle = stringResource(R.string.action_request),
                accessibilityLabel = stringResource(R.string.system_request_feature), action = { runAction(actions::requestFeature) }),
        ), AndroidSupportLinks.SOURCE, "View the OpenZCine project and contribute on GitHub.", "Read the OpenZCine terms of use.")
}

private fun toastUnavailable(context: Context) {
    Toast.makeText(context, context.getString(R.string.system_action_unavailable), Toast.LENGTH_SHORT).show()
}

/** Existing native account/route service; the common page owns consent, busy state and card jobs. */
@Composable
private fun accountSource(controller: FrameioDeliveryController, model: MonitorSettingsAccountModel,
    current: () -> Boolean): MonitorSettingsAccountSource {
    val context = LocalContext.current
    fun beginSignIn() {
        val authorizationURL = controller.beginSignIn() ?: return
        try {
            context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(authorizationURL)))
        } catch (_: Exception) {
            controller.signInBrowserUnavailable()
        }
    }
    val state = controller.connectionState
    val label = when (state) {
        FrameioConnectionState.UNCONFIGURED -> stringResource(R.string.frameio_not_set_up)
        FrameioConnectionState.SIGNED_OUT -> stringResource(R.string.frameio_not_connected)
        FrameioConnectionState.AUTHORIZING -> stringResource(R.string.frameio_waiting_signin)
        FrameioConnectionState.CONNECTED -> stringResource(R.string.status_connected)
        FrameioConnectionState.ERROR -> stringResource(R.string.status_needs_attention)
    }
    val needsConsent = settingsActionNeedsInternetHop(controller.networkState)
    val actions = MonitorSettingsAccountActions(controller, current, needsConsent,
        connect = { beginSignIn() }, disconnect = controller::disconnect,
        beginInternet = { admission ->
            controller.claimInternetHop(admission)?.let { captured ->
                MonitorSettingsInternetLease(
                    isCurrent = { controller.ownsInternetHop(captured) },
                    wait = { controller.waitInternetHop(captured) },
                    restore = { controller.restoreInternetHopAfterDismiss(captured) },
                    cleanup = MonitorSettingsInternetCleanup.ON_RETIRE,
                )
            }
        }, internetFailure = controller.errorMessage)
    return MonitorSettingsAccountSource(model, actions, controller, stringResource(R.string.frameio_delivery),
        stringResource(R.string.help_storage_frameio), when (state) {
            FrameioConnectionState.UNCONFIGURED -> MonitorAccountState.NOT_CONFIGURED
            FrameioConnectionState.SIGNED_OUT -> MonitorAccountState.SIGNED_OUT
            FrameioConnectionState.AUTHORIZING -> MonitorAccountState.CONNECTING
            FrameioConnectionState.CONNECTED -> MonitorAccountState.SIGNED_IN
            FrameioConnectionState.ERROR -> MonitorAccountState.ATTENTION
        }, label,
        stringResource(when {
            state == FrameioConnectionState.ERROR -> R.string.action_try_again
            needsConsent -> R.string.frameio_sign_in_over_internet
            else -> R.string.action_sign_in
        }), stringResource(R.string.action_log_out), stringResource(R.string.frameio_switching_networks),
        controller.errorMessage,
        stringResource(R.string.frameio_hop_signin_title), stringResource(R.string.frameio_hop_signin_message),
        stringResource(R.string.action_sign_in), stringResource(R.string.action_cancel),
        controller::refresh)
}

private fun cacheSizeLabel(context: Context, bytes: Long?): String =
    when {
        bytes == null -> context.getString(R.string.status_calculating)
        bytes == 0L -> context.getString(R.string.status_empty)
        else -> MediaClipFormatting.byteLabel(bytes)
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

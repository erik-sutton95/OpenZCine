package com.opencapture.openzcine.pairing

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.opencapture.openzcine.R
import com.opencapture.openzcine.core.CameraConnectionPhase
import com.opencapture.openzcine.core.CameraSession
import com.opencapture.openzcine.core.CameraSessionState
import com.opencapture.openzcine.transport.DiscoveredCamera
import com.opencapture.openzcine.transport.UsbPtpCamera
import com.opencapture.openzcine.transport.UsbPtpCameraAccess
import com.opencapture.openzcine.transport.UsbPtpOpenResult
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull

private sealed interface SavedCameraPhase {
    data object Idle : SavedCameraPhase

    data class Joining(val title: String) : SavedCameraPhase

    data class Connecting(val title: String) : SavedCameraPhase

    data class Pairing(val title: String) : SavedCameraPhase

    data class ConfirmOnCamera(val title: String, val pin: String?) : SavedCameraPhase

    data class Reconnecting(val title: String) : SavedCameraPhase

    data class Error(val message: String) : SavedCameraPhase
}

private fun SavedCameraPhase.isBusy(): Boolean =
    this !is SavedCameraPhase.Idle && this !is SavedCameraPhase.Error

/**
 * Applies a deliberate monitor action to USB auto-reconnect suppression. A
 * disconnect holds an already-attached profile at saved-camera home; an
 * explicit reconnect clears only that profile's hold.
 */
internal fun usbAutoReconnectSuppressionAfterUserAction(
    suppressedHosts: Set<String>,
    record: SavedCameraRecord?,
    reconnect: Boolean,
): Set<String> =
    when {
        record?.transport != SavedCameraTransport.USB_C -> suppressedHosts
        reconnect -> suppressedHosts - record.host
        else -> suppressedHosts + record.host
    }

/** Suppressions only survive while the physical USB attachment is still present. */
internal fun attachedUsbAutoReconnectSuppressions(
    suppressedHosts: Set<String>,
    attachedHosts: Set<String>,
): Set<String> = suppressedHosts.intersect(attachedHosts)

/** Whether an attached saved USB profile may receive its one auto-reconnect attempt. */
internal fun mayAutoReconnectUsb(
    record: SavedCameraRecord,
    attachedHosts: Set<String>,
    attemptedHosts: Set<String>,
    suppressedHosts: Set<String>,
): Boolean =
    record.transport == SavedCameraTransport.USB_C &&
        record.host in attachedHosts &&
        record.host !in attemptedHosts &&
        record.host !in suppressedHosts

/**
 * Saved-camera startup surface, matching the iOS shell's durable camera home.
 *
 * It is deliberately the reconnect owner: camera-AP records rejoin only their
 * stored SSID, whereas hotspot records only use discovery/last-known PTP-IP
 * hosts and never ask Android to switch networks. [onOpenSettings] opens
 * app-local operator setup without constructing a camera session.
 */
@Composable
public fun SavedCamerasExperience(
    cameras: List<SavedCameraRecord>,
    environment: PairingEnvironment,
    onPaired: (PairedCamera) -> Unit,
    onPairNewCamera: () -> Unit,
    onOpenSettings: () -> Unit,
    onRecordsChanged: (List<SavedCameraRecord>) -> Unit,
    cachedMediaCameraIDs: Set<String> = emptySet(),
    onOpenCachedMedia: (SavedCameraRecord) -> Unit = {},
    requestedReconnectID: String? = null,
    onReconnectRequestConsumed: () -> Unit = {},
    suppressedUsbAutoReconnectHosts: Set<String> = emptySet(),
    onUsbAutoReconnectSuppressionCleared: (String) -> Unit = {},
) {
    val scope = rememberCoroutineScope()
    val work = remember { mutableStateOf<Job?>(null) }
    val handedOff = remember { mutableStateOf(false) }
    var phase by remember { mutableStateOf<SavedCameraPhase>(SavedCameraPhase.Idle) }
    var discoveredCameras by remember { mutableStateOf(emptyList<DiscoveredCamera>()) }
    var usbCameras by remember { mutableStateOf(emptyList<UsbPtpCamera>()) }
    var attemptedUsbReconnectHosts by remember { mutableStateOf(emptySet<String>()) }
    var removalTarget by remember { mutableStateOf<SavedCameraRecord?>(null) }
    var renameTarget by remember { mutableStateOf<SavedCameraRecord?>(null) }
    var renameDraft by remember { mutableStateOf("") }

    LaunchedEffect(environment) {
        environment.hotspotCameras.collect { discoveredCameras = it }
    }
    LaunchedEffect(environment) {
        val source = environment.usbCameraSource
        if (source == null) {
            usbCameras = emptyList()
        } else {
            source.cameras.collect { usbCameras = it }
        }
    }
    DisposableEffect(environment) {
        onDispose {
            work.value?.cancel()
            if (!handedOff.value) environment.releaseCameraAp()
        }
    }

    fun resolvedHost(record: SavedCameraRecord): String {
        if (record.transport == SavedCameraTransport.CAMERA_ACCESS_POINT) return record.host
        if (record.transport == SavedCameraTransport.USB_C) return record.host
        return discoveredCameras.firstOrNull { camera ->
            camera.host == record.host ||
                SavedCameraRecords.cameraNamesMatch(camera.name, record.cameraName)
        }?.host ?: record.host
    }

    fun createStrictSavedProfileSession(record: SavedCameraRecord): CameraSession? =
        when (record.transport) {
            SavedCameraTransport.CAMERA_ACCESS_POINT,
            SavedCameraTransport.PHONE_HOTSPOT,
            -> environment.createSavedProfileSession(resolvedHost(record))
            SavedCameraTransport.USB_C -> {
                val source = environment.usbCameraSource ?: return null
                val camera =
                    usbCameras.firstOrNull {
                        it.access == UsbPtpCameraAccess.READY && it.hostKey == record.host
                    } ?: return null
                when (val opened = source.open(camera)) {
                    is UsbPtpOpenResult.Opened -> environment.createSavedProfileUsbSession(opened)
                    is UsbPtpOpenResult.Rejected -> null
                }
            }
        }

    suspend fun reconnectAfterNikonPairing(
        record: SavedCameraRecord,
        cameraApReassociated: Boolean? = null,
    ): PairedCamera? {
        if (record.transport == SavedCameraTransport.CAMERA_ACCESS_POINT) {
            val reappeared =
                cameraApReassociated
                    ?: environment.awaitCameraApRestart(FIRST_PAIR_CAMERA_AP_RESTART_TIMEOUT_MILLIS)
            if (!reappeared) return null
        } else {
            delay(FIRST_PAIR_HOTSPOT_SETTLE_MILLIS)
        }

        return withTimeoutOrNull<PairedCamera>(FIRST_PAIR_RECONNECT_TIMEOUT_MILLIS) {
            var reconnected: PairedCamera? = null
            while (reconnected == null) {
                phase = SavedCameraPhase.Reconnecting(record.displayTitle)
                val session = createStrictSavedProfileSession(record)
                if (session != null) {
                    var handedOffSession = false
                    try {
                        session.connect()
                        val connected = session.state.value as? CameraSessionState.Connected
                        if (connected != null) {
                            handedOffSession = true
                            reconnected =
                                PairedCamera(
                                    session = session,
                                    savedCamera =
                                        record.copy(
                                            host = resolvedHost(record),
                                            cameraName = connected.identity.name,
                                            lastSeenAtEpochMillis = System.currentTimeMillis(),
                                        ),
                                )
                        }
                    } finally {
                        if (!handedOffSession) {
                            withContext(NonCancellable) { session.disconnect() }
                        }
                    }
                }
                if (reconnected == null) {
                    delay(FIRST_PAIR_RECONNECT_INTERVAL_MILLIS)
                }
            }
            checkNotNull(reconnected)
        }
    }

    fun reconnect(record: SavedCameraRecord, explicit: Boolean = true) {
        if (phase !is SavedCameraPhase.Idle && phase !is SavedCameraPhase.Error) return
        if (explicit && record.transport == SavedCameraTransport.USB_C) {
            onUsbAutoReconnectSuppressionCleared(record.host)
        }
        handedOff.value = false
        // Mark synchronously so an explicit Link-tab reconnect and the USB
        // attachment observer cannot race into two profile-owned sessions.
        phase = SavedCameraPhase.Connecting(record.displayTitle)
        work.value =
            scope.launch {
                var session: CameraSession? = null
                var handoffSucceeded = false
                var host = resolvedHost(record)
                try {
                    if (record.transport == SavedCameraTransport.USB_C) {
                        val source = environment.usbCameraSource
                        if (source == null) {
                            phase =
                                SavedCameraPhase.Error(
                                    "USB-C camera support is unavailable on this device.",
                                )
                            return@launch
                        }
                        val camera =
                            usbCameras.firstOrNull {
                                it.access == UsbPtpCameraAccess.READY && it.hostKey == record.host
                            }
                        if (camera == null) {
                            phase =
                                SavedCameraPhase.Error(
                                    "Connect your saved USB-C camera and approve Android access before reconnecting.",
                                )
                            return@launch
                        }
                        when (val opened = source.open(camera)) {
                            is UsbPtpOpenResult.Opened -> {
                                host = opened.hostKey
                                session =
                                    try {
                                        environment.createUsbSession(opened)
                                    } catch (error: Exception) {
                                        // The source has already claimed its
                                        // physical interface. Release it if
                                        // the session wrapper cannot take
                                        // ownership, before propagating the
                                        // normal reconnect failure.
                                        opened.transport.close()
                                        throw error
                                    }
                            }
                            is UsbPtpOpenResult.Rejected -> {
                                phase = SavedCameraPhase.Error(opened.message)
                                return@launch
                            }
                        }
                    } else if (record.transport == SavedCameraTransport.CAMERA_ACCESS_POINT) {
                        val ssid = record.wifiSsid
                        if (ssid == null) {
                            phase =
                                SavedCameraPhase.Error(
                                    "This camera needs its Wi‑Fi network name. Pair it again to refresh the profile.",
                                )
                            return@launch
                        }
                        val key = environment.credentials.passphrase(ssid)
                        if (key == null) {
                            phase =
                                SavedCameraPhase.Error(
                                    "The Wi‑Fi key for $ssid is not available on this phone. Pair again to save it.",
                                )
                            return@launch
                        }
                        phase = SavedCameraPhase.Joining(record.displayTitle)
                        if (!environment.joinCameraAp(ssid, key)) {
                            phase =
                                SavedCameraPhase.Error(
                                    "Couldn't join $ssid. Check the camera is powered on and try again.",
                                )
                            return@launch
                        }
                    }

                    phase = SavedCameraPhase.Connecting(record.displayTitle)
                    val activeSession = session ?: environment.createSession(host)
                    session = activeSession
                    // Start observing before a rejected saved profile can
                    // become a fresh Nikon pairing. The body may restart its
                    // AP immediately after its confirmation, so subscribing
                    // only after the temporary session returns can miss it.
                    val cameraApRestartWaiter =
                        if (record.transport == SavedCameraTransport.CAMERA_ACCESS_POINT) {
                            async(start = CoroutineStart.UNDISPATCHED) {
                                environment.awaitCameraApRestart(
                                    FIRST_PAIR_CAMERA_AP_RESTART_TIMEOUT_MILLIS,
                                )
                            }
                        } else {
                            null
                        }
                    var pairingWasConfirmed = false
                    var pairingPin: String? = null
                    val progressWatcher =
                        launch(start = CoroutineStart.UNDISPATCHED) {
                            activeSession.connectionProgress.collect { progress ->
                                when (progress.phase) {
                                    CameraConnectionPhase.PAIRING ->
                                        phase = SavedCameraPhase.Pairing(record.displayTitle)
                                    CameraConnectionPhase.CONFIRM_ON_CAMERA -> {
                                        pairingWasConfirmed = true
                                        pairingPin = progress.detail.ifBlank { null }
                                        phase =
                                            SavedCameraPhase.ConfirmOnCamera(
                                                record.displayTitle,
                                                pairingPin,
                                            )
                                    }
                                    else -> Unit
                                }
                            }
                        }
                    val pairedCamera =
                        try {
                            activeSession.connect()
                            val connected = activeSession.state.value as? CameraSessionState.Connected
                            if (pairingWasConfirmed) {
                                // A saved profile was rejected and Nikon accepted a fresh
                                // pairing request. Mirror iOS: never hand this temporary
                                // session to the monitor; wait for the body confirmation and
                                // reconnect with the newly restored profile instead.
                                phase = SavedCameraPhase.ConfirmOnCamera(record.displayTitle, pairingPin)
                                withContext(NonCancellable) { activeSession.disconnect() }
                                reconnectAfterNikonPairing(
                                    record.copy(
                                        host = host,
                                        cameraName =
                                            connected?.identity?.name ?: record.cameraName,
                                        lastSeenAtEpochMillis = System.currentTimeMillis(),
                                    ),
                                    cameraApReassociated = cameraApRestartWaiter?.await(),
                                )
                            } else {
                                connected?.let {
                                    PairedCamera(
                                        session = activeSession,
                                        savedCamera =
                                            record.copy(
                                                host = host,
                                                cameraName = it.identity.name,
                                                lastSeenAtEpochMillis = System.currentTimeMillis(),
                                            ),
                                    )
                                }
                            }
                        } finally {
                            progressWatcher.cancel()
                            cameraApRestartWaiter?.cancel()
                        }
                    if (pairedCamera == null) {
                        phase =
                            SavedCameraPhase.Error(
                                "Couldn't reach ${record.displayTitle}. Check the camera connection and try again.",
                            )
                        return@launch
                    }
                    handoffSucceeded = true
                    handedOff.value = true
                    session = pairedCamera.session
                    onPaired(pairedCamera)
                } catch (error: CancellationException) {
                    session?.let { active ->
                        withContext(NonCancellable) { active.disconnect() }
                    }
                    throw error
                } catch (_: Exception) {
                    phase =
                        SavedCameraPhase.Error(
                            "Couldn't reach ${record.displayTitle}. Check the camera connection and try again.",
                        )
                } finally {
                    if (!handoffSucceeded) {
                        session?.let { active ->
                            withContext(NonCancellable) { active.disconnect() }
                        }
                        if (record.transport == SavedCameraTransport.CAMERA_ACCESS_POINT) {
                            environment.releaseCameraAp()
                        }
                    }
                }
            }
    }

    fun cancelWork() {
        work.value?.cancel()
        work.value = null
        environment.releaseCameraAp()
        phase = SavedCameraPhase.Idle
    }

    // Match the iOS saved-camera behavior: reconnect one time for each real
    // USB attachment. The key drops out of this set on detach, re-arming the
    // next plug-in without spinning retries against a body that rejected a
    // session or was unplugged mid-connect.
    LaunchedEffect(cameras, usbCameras, phase, suppressedUsbAutoReconnectHosts, requestedReconnectID) {
        val attachedHosts =
            usbCameras
                .filter { it.access == UsbPtpCameraAccess.READY }
                .mapNotNull(UsbPtpCamera::hostKey)
                .toSet()
        attemptedUsbReconnectHosts = attemptedUsbReconnectHosts.intersect(attachedHosts)
        val attachedSuppressions =
            attachedUsbAutoReconnectSuppressions(
                suppressedHosts = suppressedUsbAutoReconnectHosts,
                attachedHosts = attachedHosts,
            )
        (suppressedUsbAutoReconnectHosts - attachedSuppressions)
            .forEach(onUsbAutoReconnectSuppressionCleared)
        if (phase != SavedCameraPhase.Idle || requestedReconnectID != null) return@LaunchedEffect
        val match =
            cameras.firstOrNull { record ->
                mayAutoReconnectUsb(
                    record = record,
                    attachedHosts = attachedHosts,
                    attemptedHosts = attemptedUsbReconnectHosts,
                    suppressedHosts = attachedSuppressions,
                )
            } ?: return@LaunchedEffect
        attemptedUsbReconnectHosts += match.host
        reconnect(match, explicit = false)
    }

    // Link settings returns here after it has released the active monitor
    // session. Keep reconnection in this saved-profile owner so camera AP,
    // hotspot, and USB routes retain their established lifecycle rules.
    LaunchedEffect(requestedReconnectID, cameras, phase) {
        val requestedID = requestedReconnectID ?: return@LaunchedEffect
        if (phase != SavedCameraPhase.Idle) return@LaunchedEffect
        val requested = cameras.firstOrNull { it.id == requestedID }
        onReconnectRequestConsumed()
        requested?.let(::reconnect)
    }

    val busy = phase.isBusy()
    val statusTitle =
        when (phase) {
            is SavedCameraPhase.Joining -> stringResource(R.string.pairing_status_joining)
            is SavedCameraPhase.Connecting -> stringResource(R.string.pairing_status_connecting)
            is SavedCameraPhase.Pairing -> stringResource(R.string.pairing_status_pairing)
            is SavedCameraPhase.ConfirmOnCamera ->
                stringResource(R.string.pairing_status_confirm_on_camera)
            is SavedCameraPhase.Reconnecting ->
                stringResource(R.string.pairing_status_reconnecting)
            is SavedCameraPhase.Error,
            SavedCameraPhase.Idle,
            -> stringResource(R.string.pairing_status_ready)
        }

    Box(Modifier.fillMaxSize().startupBackdrop()) {
        Column(
            Modifier.fillMaxSize()
                .windowInsetsPadding(WindowInsets.safeDrawing)
                .padding(horizontal = 24.dp, vertical = 12.dp),
        ) {
            // Settings lives on the intro card, matching iOS — the header
            // carries only the wordmark, title, legal links, and status pill.
            StartupHeader(
                title = stringResource(R.string.saved_your_cameras),
                statusTitle = statusTitle,
                isBusy = busy,
            )
            Spacer(Modifier.height(12.dp))
            BoxWithConstraints(Modifier.weight(1f)) {
                val twoColumn = maxWidth >= 640.dp
                val overviewWidth = maxOf(236.dp, maxWidth * 0.28f)
                if (twoColumn) {
                    Row(horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                        SavedCameraOverview(
                            onPairNewCamera = onPairNewCamera,
                            onOpenSettings = onOpenSettings,
                            enabled = !busy,
                            modifier = Modifier.width(overviewWidth).fillMaxSize(),
                        )
                        SavedCameraList(
                            cameras = cameras,
                            discoveredCameras = discoveredCameras,
                            usbCameras = usbCameras,
                            phase = phase,
                            cachedMediaCameraIDs = cachedMediaCameraIDs,
                            onConnect = ::reconnect,
                            onOpenCachedMedia = onOpenCachedMedia,
                            onRename = { record ->
                                renameTarget = record
                                renameDraft = record.customName.orEmpty()
                            },
                            onRemove = { removalTarget = it },
                            fillAvailableHeight = true,
                            scrollRows = true,
                            modifier = Modifier.weight(1f).fillMaxSize(),
                        )
                    }
                } else {
                    LazyColumn(
                        Modifier.fillMaxSize(),
                        verticalArrangement = Arrangement.spacedBy(12.dp),
                    ) {
                        item {
                            SavedCameraOverview(
                                onPairNewCamera = onPairNewCamera,
                                onOpenSettings = onOpenSettings,
                                enabled = !busy,
                                modifier = Modifier.fillMaxWidth(),
                            )
                        }
                        item {
                            SavedCameraList(
                                cameras = cameras,
                                discoveredCameras = discoveredCameras,
                                usbCameras = usbCameras,
                                phase = phase,
                                cachedMediaCameraIDs = cachedMediaCameraIDs,
                                onConnect = ::reconnect,
                                onOpenCachedMedia = onOpenCachedMedia,
                                onRename = { record ->
                                    renameTarget = record
                                    renameDraft = record.customName.orEmpty()
                                },
                                onRemove = { removalTarget = it },
                                fillAvailableHeight = false,
                                scrollRows = false,
                                modifier = Modifier.fillMaxWidth(),
                            )
                        }
                    }
                }
            }
        }
        // Every reconnect phase renders in the shared connect popup, exactly
        // like iOS's ConnectionProgressSheet over the saved-camera home.
        val popupPhase =
            when (val active = phase) {
                SavedCameraPhase.Idle -> null
                is SavedCameraPhase.Joining -> ConnectionPopupPhase.JoiningWifi
                is SavedCameraPhase.Connecting -> ConnectionPopupPhase.Handshaking
                is SavedCameraPhase.Pairing -> ConnectionPopupPhase.Pairing
                is SavedCameraPhase.ConfirmOnCamera ->
                    ConnectionPopupPhase.ConfirmOnCamera(active.pin)
                is SavedCameraPhase.Reconnecting -> ConnectionPopupPhase.Reconnecting
                is SavedCameraPhase.Error -> ConnectionPopupPhase.Failed(active.message)
            }
        popupPhase?.let { popup ->
            ConnectionProgressPopup(
                deviceName =
                    connectionDisplayName(
                        when (val active = phase) {
                            is SavedCameraPhase.Joining -> active.title
                            is SavedCameraPhase.Connecting -> active.title
                            is SavedCameraPhase.Pairing -> active.title
                            is SavedCameraPhase.ConfirmOnCamera -> active.title
                            is SavedCameraPhase.Reconnecting -> active.title
                            else -> null
                        },
                    ),
                phase = popup,
                onConnect = {},
                onDismiss = ::cancelWork,
            )
        }
    }

    removalTarget?.let { record ->
        AlertDialog(
            onDismissRequest = { removalTarget = null },
            title = { Text(stringResource(R.string.saved_remove_title)) },
            text = {
                Text(stringResource(R.string.saved_remove_message, record.displayTitle))
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        onRecordsChanged(SavedCameraRecords.removing(record.host, cameras))
                        removalTarget = null
                    },
                ) {
                    Text(stringResource(R.string.action_remove))
                }
            },
            dismissButton = {
                TextButton(onClick = { removalTarget = null }) {
                    Text(stringResource(R.string.action_cancel))
                }
            },
        )
    }
    renameTarget?.let { record ->
        AlertDialog(
            onDismissRequest = { renameTarget = null },
            title = { Text(stringResource(R.string.saved_rename_title)) },
            text = {
                Column {
                    Text(stringResource(R.string.saved_rename_message))
                    Spacer(Modifier.height(8.dp))
                    OutlinedTextField(
                        value = renameDraft,
                        onValueChange = { renameDraft = it },
                        singleLine = true,
                        label = { Text(stringResource(R.string.saved_rename_hint)) },
                    )
                }
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        onRecordsChanged(
                            SavedCameraRecords.updatingCustomName(
                                host = record.host,
                                customName = renameDraft,
                                records = cameras,
                            ),
                        )
                        renameTarget = null
                    },
                ) {
                    Text(stringResource(R.string.action_save))
                }
            },
            dismissButton = {
                TextButton(onClick = { renameTarget = null }) {
                    Text(stringResource(R.string.action_cancel))
                }
            },
        )
    }
}

@Composable
private fun SavedCameraOverview(
    onPairNewCamera: () -> Unit,
    onOpenSettings: () -> Unit,
    enabled: Boolean,
    modifier: Modifier,
) {
    Column(
        modifier.startupCard().padding(horizontal = 20.dp, vertical = 16.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Text(
            stringResource(R.string.saved_your_cameras_title),
            color = StartupColors.ink,
            fontSize = 26.sp,
            fontWeight = FontWeight.Bold,
            lineHeight = 29.sp,
        )
        Text(
            stringResource(R.string.saved_intro_body),
            color = StartupColors.muted,
            fontSize = 13.sp,
            lineHeight = 18.sp,
        )
        Spacer(Modifier.weight(1f, fill = false))
        StartupFilledButton(
            text = stringResource(R.string.saved_pair_new_camera),
            enabled = enabled,
            onClick = onPairNewCamera,
            modifier = Modifier.fillMaxWidth(),
        )
        StartupOutlineButton(
            text = stringResource(R.string.action_settings),
            onClick = onOpenSettings,
            modifier = Modifier.fillMaxWidth(),
        )
    }
}

@Composable
private fun SavedCameraList(
    cameras: List<SavedCameraRecord>,
    discoveredCameras: List<DiscoveredCamera>,
    usbCameras: List<UsbPtpCamera>,
    phase: SavedCameraPhase,
    cachedMediaCameraIDs: Set<String>,
    onConnect: (SavedCameraRecord) -> Unit,
    onOpenCachedMedia: (SavedCameraRecord) -> Unit,
    onRename: (SavedCameraRecord) -> Unit,
    onRemove: (SavedCameraRecord) -> Unit,
    fillAvailableHeight: Boolean,
    scrollRows: Boolean,
    modifier: Modifier,
) {
    val busy = phase.isBusy()
    Column(modifier.startupCard().padding(20.dp)) {
        Text(
            stringResource(R.string.saved_camera_list),
            color = StartupColors.muted,
            fontSize = 11.sp,
            fontWeight = FontWeight.SemiBold,
            letterSpacing = 1.4.sp,
        )
        Spacer(Modifier.height(6.dp))
        Text(
            stringResource(R.string.saved_tap_to_connect),
            color = StartupColors.ink,
            fontSize = 21.sp,
            fontWeight = FontWeight.Bold,
        )
        Spacer(Modifier.height(10.dp))
        val rowScroll = rememberScrollState()
        Column(
            (if (fillAvailableHeight) Modifier.weight(1f) else Modifier)
                .then(
                    if (scrollRows) {
                        Modifier.fadeOverflowBottom(rowScroll).verticalScroll(rowScroll)
                    } else {
                        Modifier
                    },
                ),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            if (cameras.isEmpty()) {
                Text(
                    stringResource(R.string.saved_empty),
                    color = StartupColors.muted,
                    fontSize = 13.sp,
                    lineHeight = 18.sp,
                )
            } else {
                cameras.forEach { record ->
                    val isDiscovered =
                        if (record.transport == SavedCameraTransport.USB_C) {
                            usbCameras.any {
                                it.access == UsbPtpCameraAccess.READY && it.hostKey == record.host
                            }
                        } else {
                            discoveredCameras.any { camera ->
                                camera.host == record.host ||
                                    SavedCameraRecords.cameraNamesMatch(
                                        camera.name,
                                        record.cameraName,
                                    )
                            }
                        }
                    SavedCameraRow(
                        record = record,
                        isDiscovered = isDiscovered,
                        hasCachedMedia = record.id in cachedMediaCameraIDs,
                        enabled = !busy,
                        onConnect = { onConnect(record) },
                        onOpenCachedMedia = { onOpenCachedMedia(record) },
                        onRename = { onRename(record) },
                        onRemove = { onRemove(record) },
                    )
                }
            }
        }
    }
}

@Composable
internal fun SavedCameraRow(
    record: SavedCameraRecord,
    isDiscovered: Boolean,
    hasCachedMedia: Boolean,
    enabled: Boolean,
    onConnect: () -> Unit,
    onOpenCachedMedia: () -> Unit,
    onRename: () -> Unit,
    onRemove: () -> Unit,
) {
    val availabilityColor = if (isDiscovered) StartupColors.ready else StartupColors.dim
    val moreOptionsDescription = stringResource(R.string.saved_more_options)
    var optionsExpanded by remember { mutableStateOf(false) }
    Column(
        Modifier.fillMaxWidth()
            .startupTile(borderColor = availabilityColor.copy(alpha = 0.28f))
            .clickable(enabled = enabled, onClick = onConnect)
            .padding(horizontal = 14.dp, vertical = 12.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Text(
                record.displayTitle,
                color = StartupColors.ink,
                fontSize = 15.sp,
                fontWeight = FontWeight.SemiBold,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f),
            )
            Text(
                stringResource(
                    if (isDiscovered) R.string.saved_pill_online else R.string.saved_pill_offline
                ),
                color = availabilityColor,
                fontSize = 11.sp,
                fontWeight = FontWeight.SemiBold,
                modifier =
                    Modifier.border(1.dp, availabilityColor.copy(alpha = 0.45f), CircleShape)
                        .padding(horizontal = 9.dp, vertical = 4.dp),
            )
            // iOS fills the Connect button only when the camera is actually
            // reachable; offline rows get the quiet outline style.
            if (isDiscovered) {
                StartupFilledButton(
                    text = stringResource(R.string.action_connect),
                    enabled = enabled,
                    onClick = onConnect,
                    modifier = Modifier.width(96.dp),
                )
            } else {
                StartupOutlineButton(
                    text = stringResource(R.string.action_connect),
                    onClick = onConnect,
                    modifier = Modifier.width(96.dp),
                )
            }
            Box {
                Text(
                    "⋯",
                    color = StartupColors.muted,
                    fontSize = 17.sp,
                    fontWeight = FontWeight.Bold,
                    modifier =
                        Modifier.clip(CircleShape)
                            .clickable(enabled = enabled) { optionsExpanded = true }
                            .padding(horizontal = 8.dp, vertical = 4.dp)
                            .semantics {
                                contentDescription = moreOptionsDescription
                            },
                )
                DropdownMenu(
                    expanded = optionsExpanded,
                    onDismissRequest = { optionsExpanded = false },
                ) {
                    DropdownMenuItem(
                        text = { Text(stringResource(R.string.action_rename)) },
                        onClick = {
                            optionsExpanded = false
                            onRename()
                        },
                    )
                    DropdownMenuItem(
                        text = { Text(stringResource(R.string.action_remove)) },
                        onClick = {
                            optionsExpanded = false
                            onRemove()
                        },
                    )
                }
            }
        }
        Text(
            savedCameraSubtitle(record),
            color = StartupColors.muted,
            fontSize = 13.sp,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        if (hasCachedMedia && enabled) {
            StartupOutlineButton(
                text = stringResource(R.string.saved_media_library),
                onClick = onOpenCachedMedia,
                modifier = Modifier.fillMaxWidth(),
            )
        }
    }
}

/**
 * iOS row subtitle: `USB-C · connect cable to wake the session` or
 * `Wi‑Fi · <SSID> · <recency>`, with the recency phrased off the record's
 * last-seen timestamp.
 */
@Composable
private fun savedCameraSubtitle(record: SavedCameraRecord): String {
    if (record.transport == SavedCameraTransport.USB_C) {
        return stringResource(R.string.saved_usb_subtitle)
    }
    val networkName = record.wifiSsid ?: record.host
    val lastSeen = record.lastSeenAtEpochMillis
    val recency =
        if (lastSeen == null) {
            stringResource(R.string.saved_profile_fallback)
        } else {
            when (val days = ((System.currentTimeMillis() - lastSeen) / 86_400_000L).toInt()) {
                0 -> stringResource(R.string.saved_last_today)
                1 -> stringResource(R.string.saved_last_yesterday)
                else -> stringResource(R.string.saved_last_days, days)
            }
        }
    return stringResource(R.string.saved_wifi_subtitle, networkName, recency)
}

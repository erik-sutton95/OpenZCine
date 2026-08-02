package com.opencapture.openzcine.pairing

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.horizontalScroll
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
import androidx.compose.foundation.layout.size
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.opencapture.openzcine.R
import com.opencapture.openzcine.bridge.SwiftCore
import com.opencapture.openzcine.core.CameraConnectionPhase
import com.opencapture.openzcine.core.CameraSession
import com.opencapture.openzcine.core.CameraSessionState
import com.opencapture.openzcine.transport.CameraDiscovery
import com.opencapture.openzcine.transport.DiscoveredCamera
import com.opencapture.openzcine.transport.UsbPtpCamera
import com.opencapture.openzcine.transport.UsbPtpCameraAccess
import com.opencapture.openzcine.transport.UsbPtpOpenResult
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull

private sealed interface SavedCameraPhase {
    data object Idle : SavedCameraPhase

    /**
     * Camera-AP profile staged for join: the operator must confirm before we
     * issue [CameraApJoiner.join] (which surfaces Android's switch-network
     * dialog). Matches first-pair [ConnectionPopupPhase.ReadyToJoin].
     */
    data class ReadyToJoin(
        val record: SavedCameraRecord,
        val ssid: String,
        val key: String,
    ) : SavedCameraPhase

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
 * [onOpenMediaLibrary] opens the offline Media browser for all cached clips
 * (iOS startup `Media Library` / `openCachedMediaLibrary`).
 */
@Composable
public fun SavedCamerasExperience(
    cameras: List<SavedCameraRecord>,
    environment: PairingEnvironment,
    onPaired: (PairedCamera) -> Unit,
    onPairNewCamera: () -> Unit,
    onOpenSettings: () -> Unit,
    onOpenMediaLibrary: () -> Unit = {},
    onRecordsChanged: (List<SavedCameraRecord>) -> Unit,
    requestedReconnectID: String? = null,
    onReconnectRequestConsumed: () -> Unit = {},
    suppressedUsbAutoReconnectHosts: Set<String> = emptySet(),
    onUsbAutoReconnectSuppressionCleared: (String) -> Unit = {},
    onShareDiagnostics: (() -> Unit)? = null,
    nearbyBroadcasts: List<com.opencapture.openzcine.relay.RelayBroadcast> = emptyList(),
    onWatchBroadcast: (com.opencapture.openzcine.relay.RelayBroadcast) -> Unit = {},
) {
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    val work = remember { mutableStateOf<Job?>(null) }
    val handedOff = remember { mutableStateOf(false) }
    var phase by remember { mutableStateOf<SavedCameraPhase>(SavedCameraPhase.Idle) }
    var wifiOffPromptVisible by remember { mutableStateOf(false) }
    var discoveredCameras by remember { mutableStateOf(emptyList<DiscoveredCamera>()) }
    var usbCameras by remember { mutableStateOf(emptyList<UsbPtpCamera>()) }
    var attemptedUsbReconnectHosts by remember { mutableStateOf(emptySet<String>()) }
    var removalTarget by remember { mutableStateOf<List<SavedCameraRecord>?>(null) }
    var renameTarget by remember { mutableStateOf<List<SavedCameraRecord>?>(null) }
    var addSetupTarget by remember { mutableStateOf<List<SavedCameraRecord>?>(null) }
    // An armed add-setup watch (iOS pendingSetupIntent): the sheet's no-match buttons arm it,
    // and the first discovery on that path connects — the tap was consent given in advance.
    var armedSetupWatch by
        remember { mutableStateOf<Pair<SavedCameraRecord, SavedCameraTransport>?>(null) }
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
    val readyApSsid = (phase as? SavedCameraPhase.ReadyToJoin)?.ssid
    LaunchedEffect(readyApSsid) {
        val ssid = readyApSsid ?: return@LaunchedEffect
        while (true) {
            environment.primeCameraApScan(ssid)
            delay(2_000)
        }
    }
    DisposableEffect(environment) {
        onDispose {
            work.value?.cancel()
            if (!handedOff.value) environment.releaseCameraAp()
        }
    }

    fun resolvedHost(record: SavedCameraRecord): String {
        if (record.transport == SavedCameraTransport.CAMERA_ACCESS_POINT) {
            return CameraDiscovery.NIKON_ZR_ACCESS_POINT_HOST
        }
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
            SavedCameraTransport.INFRASTRUCTURE,
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

    /** Same session shape as a normal My-cameras reconnect (restore-then-pair). */
    fun createPostConfirmReconnectSession(record: SavedCameraRecord): CameraSession? =
        when (record.transport) {
            SavedCameraTransport.CAMERA_ACCESS_POINT,
            SavedCameraTransport.PHONE_HOTSPOT,
            SavedCameraTransport.INFRASTRUCTURE,
            -> environment.createSession(resolvedHost(record))
            SavedCameraTransport.USB_C -> {
                val source = environment.usbCameraSource ?: return null
                val camera =
                    usbCameras.firstOrNull {
                        it.access == UsbPtpCameraAccess.READY && it.hostKey == record.host
                    } ?: return null
                when (val opened = source.open(camera)) {
                    is UsbPtpOpenResult.Opened -> environment.createUsbSession(opened)
                    is UsbPtpOpenResult.Rejected -> null
                }
            }
        }

    suspend fun reconnectAfterNikonPairing(
        record: SavedCameraRecord,
        confirmPin: String? = null,
    ): PairedCamera? {
        val isCameraAp = record.transport == SavedCameraTransport.CAMERA_ACCESS_POINT
        phase = SavedCameraPhase.ConfirmOnCamera(record.displayTitle, confirmPin)
        if (isCameraAp) {
            awaitCameraApReadyAfterConfirm(
                awaitReassociation = environment.awaitCameraApRestart,
                isProcessBound = environment.isCameraApProcessBound,
            )
        } else {
            delay(FIRST_PAIR_HOTSPOT_SETTLE_MILLIS)
        }
        val rejoinSsid = record.wifiSsid?.takeIf { isCameraAp && it.isNotBlank() }
        val rejoinKey = rejoinSsid?.let(environment.credentials::passphrase)

        if (!isCameraAp) {
            return withTimeoutOrNull(FIRST_PAIR_RECONNECT_TIMEOUT_MILLIS) {
                while (true) {
                    phase = SavedCameraPhase.Reconnecting(record.displayTitle)
                    val session = createPostConfirmReconnectSession(record)
                    if (session != null) {
                        var handedOffSession = false
                        try {
                            session.connect()
                            val connected = session.state.value as? CameraSessionState.Connected
                            if (
                                connected != null &&
                                    session.connectionProgress.value.phase !=
                                        CameraConnectionPhase.CONFIRM_ON_CAMERA
                            ) {
                                handedOffSession = true
                                return@withTimeoutOrNull PairedCamera(
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
                    delay(FIRST_PAIR_RECONNECT_INTERVAL_MILLIS)
                }
                @Suppress("UNREACHABLE_CODE")
                null
            }
        }

        var paired: PairedCamera? = null
        val ok =
            reconnectCameraApAfterConfirm(
                rejoinSsid = rejoinSsid,
                rejoinKey = rejoinKey,
                isProcessBound = environment.isCameraApProcessBound,
                alwaysForceJoinFirst = true,
                ensureJoined = environment.ensureCameraApJoined,
                forceJoin = { ssid, key, timeout ->
                    environment.releaseCameraAp()
                    environment.ensureCameraApJoined(ssid, key, timeout)
                },
                connectSavedProfile = {
                    val session =
                        createPostConfirmReconnectSession(record)
                            ?: return@reconnectCameraApAfterConfirm false
                    var handedOffSession = false
                    try {
                        session.connect()
                        val connected = session.state.value as? CameraSessionState.Connected
                        val phaseNow = session.connectionProgress.value.phase
                        if (
                            connected != null &&
                                phaseNow != CameraConnectionPhase.CONFIRM_ON_CAMERA &&
                                phaseNow != CameraConnectionPhase.PAIRING
                        ) {
                            handedOffSession = true
                            paired =
                                PairedCamera(
                                    session = session,
                                    savedCamera =
                                        record.copy(
                                            host = resolvedHost(record),
                                            cameraName = connected.identity.name,
                                            lastSeenAtEpochMillis = System.currentTimeMillis(),
                                        ),
                                )
                            true
                        } else {
                            false
                        }
                    } finally {
                        if (!handedOffSession) {
                            withContext(NonCancellable) { session.disconnect() }
                        }
                    }
                },
                onPhaseReconnecting = {
                    phase = SavedCameraPhase.Reconnecting(record.displayTitle)
                },
            )
        return if (ok) paired else null
    }

    fun beginReconnectWork(
        record: SavedCameraRecord,
        cameraApSsid: String?,
        cameraApKey: String?,
    ) {
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
                        val ssid =
                            cameraApSsid
                                ?: record.wifiSsid
                                ?: run {
                                    phase =
                                        SavedCameraPhase.Error(
                                            "This camera needs its Wi‑Fi network name. Pair it again to refresh the profile.",
                                        )
                                    return@launch
                                }
                        val key =
                            cameraApKey
                                ?: environment.credentials.passphrase(ssid)
                                ?: run {
                                    phase =
                                        SavedCameraPhase.Error(
                                            "The Wi‑Fi key for $ssid is not available on this phone. Pair again to save it.",
                                        )
                                    return@launch
                                }
                        phase = SavedCameraPhase.Joining(record.displayTitle)
                        // Pre-scan + fail-fast retries live inside joinWithFallback.
                        val joined = environment.joinCameraAp(ssid, key)
                        if (!joined) {
                            // Wi-Fi toggled off after the join was staged: the joiner bails
                            // in milliseconds, and the generic copy would be misleading.
                            if (!isWifiRadioEnabled(context)) {
                                wifiOffPromptVisible = true
                                phase = SavedCameraPhase.Idle
                                return@launch
                            }
                            phase =
                                SavedCameraPhase.Error(
                                    "Couldn't join $ssid. Keep the camera's network screen on, stay near the camera, and try again. If Android shows \"Searching for devices…\" and finds nothing, re-pair with a fresh SSID/key scan.",
                                )
                            return@launch
                        }
                        // Wi‑Fi association can complete before the camera answers
                        // PTP-IP Init; racing that window surfaces rejectedInitiator
                        // and a generic "Couldn't connect" with no system Wi‑Fi sheet
                        // (Android silently rejoins a previously approved AP).
                        delay(CAMERA_AP_POST_JOIN_SETTLE_MILLIS)
                    }

                    val isCameraAp = record.transport == SavedCameraTransport.CAMERA_ACCESS_POINT
                    val maxAttempts = if (isCameraAp) CAMERA_AP_CONNECT_ATTEMPTS else 1
                    var lastFailureDetail: String? = null
                    var pairedCamera: PairedCamera? = null
                    var attempt = 0
                    while (pairedCamera == null && attempt < maxAttempts) {
                        if (attempt > 0) {
                            delay(CAMERA_AP_CONNECT_RETRY_DELAY_MILLIS)
                        }
                        attempt += 1
                        phase = SavedCameraPhase.Connecting(record.displayTitle)
                        // Prefer restore-then-pair; on the last camera-AP attempt after a
                        // handshake rejection, force first-time pairing so a forgotten
                        // camera-side profile can be recreated without wiping the phone.
                        val useFirstTimePairing =
                            isCameraAp &&
                                attempt == maxAttempts &&
                                indicatesSavedProfileUnavailable(lastFailureDetail)
                        val attemptSession =
                            session
                                ?: if (useFirstTimePairing) {
                                    environment.createFirstTimePairingSession(host)
                                } else {
                                    environment.createSession(host)
                                }
                        session = attemptSession
                        var pairingWasConfirmed = false
                        var pairingPin: String? = null
                        var failureDetail: String? = null
                        val progressWatcher =
                            launch(start = CoroutineStart.UNDISPATCHED) {
                                attemptSession.connectionProgress.collect { progress ->
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
                                        CameraConnectionPhase.FAILED ->
                                            failureDetail = progress.detail.ifBlank { null }
                                        else -> Unit
                                    }
                                }
                            }
                        try {
                            attemptSession.connect()
                            val connected =
                                attemptSession.state.value as? CameraSessionState.Connected
                            pairedCamera =
                                if (pairingWasConfirmed) {
                                    // A saved profile was rejected and Nikon accepted a fresh
                                    // pairing request. Mirror iOS: never hand this temporary
                                    // session to the monitor; wait for the body confirmation and
                                    // reconnect with the newly restored profile instead.
                                    phase =
                                        SavedCameraPhase.ConfirmOnCamera(
                                            record.displayTitle,
                                            pairingPin,
                                        )
                                    withContext(NonCancellable) { attemptSession.disconnect() }
                                    session = null
                                    reconnectAfterNikonPairing(
                                        record.copy(
                                            host = host,
                                            cameraName =
                                                connected?.identity?.name ?: record.cameraName,
                                            lastSeenAtEpochMillis = System.currentTimeMillis(),
                                        ),
                                        confirmPin = pairingPin,
                                    )
                                } else {
                                    connected?.let {
                                        PairedCamera(
                                            session = attemptSession,
                                            savedCamera =
                                                record.copy(
                                                    host = host,
                                                    cameraName = it.identity.name,
                                                    lastSeenAtEpochMillis =
                                                        System.currentTimeMillis(),
                                                ),
                                        )
                                    }
                                }
                            if (pairedCamera == null) {
                                lastFailureDetail =
                                    failureDetail
                                        ?: attemptSession.connectionProgress.value.detail
                                            .takeIf { it.isNotBlank() }
                                withContext(NonCancellable) { attemptSession.disconnect() }
                                session = null
                            }
                        } finally {
                            progressWatcher.cancel()
                        }
                    }
                    if (pairedCamera == null) {
                        phase =
                            SavedCameraPhase.Error(
                                friendlyCameraConnectionFailure(
                                    lastFailureDetail
                                        ?: "Couldn't reach ${record.displayTitle}. Check the camera connection and try again.",
                                ) + wrongNetworkHint(record),
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
                            friendlyCameraConnectionFailure(
                                "Couldn't reach ${record.displayTitle}. Check the camera connection and try again.",
                            ) + wrongNetworkHint(record),
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

    /**
     * Operator tapped Connect on a saved card. Camera-AP profiles stage a
     * Ready-to-join confirm (SSID + Connect) so we explicitly prompt the join
     * before issuing Android's switch-network dialog — previously reconnect
     * jumped straight into Joining and only said "Tap Connect when Android
     * asks" without an in-app join step when the system UI never appeared.
     * Hotspot and USB go straight into the connect work.
     */
    fun reconnect(record: SavedCameraRecord, explicit: Boolean = true) {
        if (phase !is SavedCameraPhase.Idle && phase !is SavedCameraPhase.Error) return
        if (explicit && record.transport == SavedCameraTransport.USB_C) {
            onUsbAutoReconnectSuppressionCleared(record.host)
        }
        handedOff.value = false
        if (record.transport == SavedCameraTransport.CAMERA_ACCESS_POINT) {
            if (!isWifiRadioEnabled(context)) {
                wifiOffPromptVisible = true
                return
            }
            val ssid = record.wifiSsid
            if (ssid.isNullOrBlank()) {
                phase =
                    SavedCameraPhase.Error(
                        "This camera needs its Wi‑Fi network name. Pair it again to refresh the profile.",
                    )
                return
            }
            val key = environment.credentials.passphrase(ssid)
            if (key == null) {
                phase =
                    SavedCameraPhase.Error(
                        "The Wi‑Fi key for $ssid is not available on this phone. Pair again to save it.",
                    )
                return
            }
            phase = SavedCameraPhase.ReadyToJoin(record = record, ssid = ssid, key = key)
            environment.primeCameraApScan(ssid)
            return
        }
        beginReconnectWork(record, cameraApSsid = null, cameraApKey = null)
    }

    // Fulfill an armed add-setup watch: the first discovery on the asked-for path connects,
    // through the same synthesized-record reconnect the sheet's Connect Now uses. Strict
    // name matching — a mismatch just leaves the row waiting, never connects a wrong body.
    LaunchedEffect(armedSetupWatch, discoveredCameras, usbCameras) {
        val (anchor, transport) = armedSetupWatch ?: return@LaunchedEffect
        if (phase.isBusy()) return@LaunchedEffect
        val host =
            when (transport) {
                SavedCameraTransport.USB_C ->
                    usbCameras
                        .firstOrNull {
                            it.access == UsbPtpCameraAccess.READY &&
                                SavedCameraRecords.cameraNamesMatch(
                                    it.displayName,
                                    anchor.cameraName,
                                )
                        }
                        ?.hostKey
                SavedCameraTransport.INFRASTRUCTURE,
                SavedCameraTransport.PHONE_HOTSPOT,
                ->
                    discoveredCameras
                        .firstOrNull {
                            // Same per-kind network-shape rule as the availability chips: an
                            // armed Router watch must not be fulfilled by the body still on
                            // this phone's hotspot (wrong path, wrong record), and vice versa.
                            SavedCameraRecords.cameraNamesMatch(it.name, anchor.cameraName) &&
                                SavedCameraRecords.isPhoneHotspotHost(it.host) ==
                                    (transport == SavedCameraTransport.PHONE_HOTSPOT)
                        }
                        ?.host
                else -> null
            }
        if (host != null) {
            armedSetupWatch = null
            reconnect(
                anchor.copy(
                    transport = transport,
                    host = host,
                    profileID = host,
                    wifiSsid = null,
                    lastSeenAtEpochMillis = null,
                )
            )
        }
    }

    /**
     * "+ Add setup -> Camera access point" on a camera saved another way. With a derivable SSID
     * and a stored key this stages the normal Ready-to-join confirm on a synthetic AP record --
     * the setup persists itself when that connect succeeds, exactly like iOS. Without a stored
     * key the pairing wizard owns first-time credentials (its scan flow), so route there.
     */
    fun addCameraApSetup(record: SavedCameraRecord) {
        if (phase !is SavedCameraPhase.Idle && phase !is SavedCameraPhase.Error) return
        if (!isWifiRadioEnabled(context)) {
            wifiOffPromptVisible = true
            return
        }
        val ssid =
            record.wifiSsid?.takeIf(::looksLikeNikonAccessPointSsid)
                ?: runCatching { SwiftCore.deriveAccessPointSSID(record.cameraName) }.getOrNull()
        val key = ssid?.let(environment.credentials::passphrase)
        if (ssid == null || key == null) {
            onPairNewCamera()
            return
        }
        handedOff.value = false
        val apRecord = record.copy(transport = SavedCameraTransport.CAMERA_ACCESS_POINT, wifiSsid = ssid)
        phase = SavedCameraPhase.ReadyToJoin(record = apRecord, ssid = ssid, key = key)
        environment.primeCameraApScan(ssid)
    }

    /** Confirm Ready-to-join and issue the camera-AP join + session connect. */
    fun confirmCameraApJoin() {
        val staged = phase as? SavedCameraPhase.ReadyToJoin ?: return
        beginReconnectWork(
            record = staged.record,
            cameraApSsid = staged.ssid,
            cameraApKey = staged.key,
        )
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
            is SavedCameraPhase.ReadyToJoin -> stringResource(R.string.pairing_status_ready)
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
                            onOpenMediaLibrary = onOpenMediaLibrary,
                            onOpenSettings = onOpenSettings,
                            enabled = !busy,
                            modifier = Modifier.width(overviewWidth).fillMaxSize(),
                        )
                        SavedCameraList(
                            cameras = cameras,
                            discoveredCameras = discoveredCameras,
                            usbCameras = usbCameras,
                            phase = phase,
                            onConnect = ::reconnect,
                            onRename = { group ->
                                renameTarget = group
                                renameDraft = group.first().customName.orEmpty()
                            },
                            onRemove = { removalTarget = it },
                            onAddSetup = { addSetupTarget = it },
                            onForgetSetup = { record ->
                                onRecordsChanged(
                                    SavedCameraRecords.removing(
                                        record.host, record.cameraName, cameras
                                    )
                                )
                            },
                            nearbyBroadcasts = nearbyBroadcasts,
                            onWatchBroadcast = onWatchBroadcast,
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
                                onOpenMediaLibrary = onOpenMediaLibrary,
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
                                onConnect = ::reconnect,
                                onRename = { group ->
                                    renameTarget = group
                                    renameDraft = group.first().customName.orEmpty()
                                },
                                onRemove = { removalTarget = it },
                                onAddSetup = { addSetupTarget = it },
                                onForgetSetup = { record ->
                                    onRecordsChanged(
                                        SavedCameraRecords.removing(
                                            record.host, record.cameraName, cameras
                                        )
                                    )
                                },
                                nearbyBroadcasts = nearbyBroadcasts,
                                onWatchBroadcast = onWatchBroadcast,
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
                is SavedCameraPhase.ReadyToJoin ->
                    // Prefer the camera AP SSID in the join prompt so the
                    // operator knows which network Android will request.
                    ConnectionPopupPhase.ReadyToJoin(key = null, keyFromScan = false)
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
                            is SavedCameraPhase.ReadyToJoin -> active.ssid
                            is SavedCameraPhase.Joining -> active.title
                            is SavedCameraPhase.Connecting -> active.title
                            is SavedCameraPhase.Pairing -> active.title
                            is SavedCameraPhase.ConfirmOnCamera -> active.title
                            is SavedCameraPhase.Reconnecting -> active.title
                            else -> null
                        },
                    ),
                phase = popup,
                onConnect = ::confirmCameraApJoin,
                onDismiss = ::cancelWork,
                onShareDiagnostics =
                    onShareDiagnostics.takeIf { popup is ConnectionPopupPhase.Failed },
            )
        }
    }

    removalTarget?.let { group ->
        AlertDialog(
            onDismissRequest = { removalTarget = null },
            title = { Text(stringResource(R.string.saved_remove_title)) },
            text = {
                Text(stringResource(R.string.saved_remove_message, group.first().displayTitle))
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        // Remove means the CAMERA -- every saved setup goes with it, matching
                        // iOS. Per-setup removal lives on the chips (long-press).
                        var remaining = cameras
                        for (record in group) {
                            remaining =
                                SavedCameraRecords.removing(
                                    record.host, record.cameraName, remaining
                                )
                        }
                        onRecordsChanged(remaining)
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
    renameTarget?.let { group ->
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
                        // The name belongs to the CAMERA, so it lands on every setup --
                        // otherwise a body renamed on its hotspot setup answers to its bare
                        // name when cabled (the iOS rule).
                        var updated = cameras
                        for (record in group) {
                            updated =
                                SavedCameraRecords.updatingCustomName(
                                    host = record.host,
                                    customName = renameDraft,
                                    records = updated,
                                )
                        }
                        onRecordsChanged(updated)
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
    if (wifiOffPromptVisible) {
        WifiOffPromptDialog(onDismiss = { wifiOffPromptVisible = false })
    }
    addSetupTarget?.let { group ->
        val anchor = group.first()
        SavedCameraAddSetupDialog(
            group = group,
            usbReadyHostKey =
                usbCameras.firstOrNull { it.access == UsbPtpCameraAccess.READY }?.hostKey,
            routerDiscoveredHost =
                discoveredCameras
                    .firstOrNull {
                        SavedCameraRecords.cameraNamesMatch(it.name, anchor.cameraName)
                    }
                    ?.host,
            onDismiss = { addSetupTarget = null },
            onJoinCameraAp = { record ->
                addSetupTarget = null
                addCameraApSetup(record)
            },
            onConnectSetup = { transport, host ->
                addSetupTarget = null
                // Connecting over this path IS adding the setup: the record saves itself with
                // this transport on success. A fresh profileID keeps the new setup from
                // merging into the sibling it was copied from.
                reconnect(
                    anchor.copy(
                        transport = transport,
                        host = host,
                        profileID = host,
                        wifiSsid = null,
                        lastSeenAtEpochMillis = null,
                    )
                )
            },
            onArmSetupWatch = { transport ->
                addSetupTarget = null
                armedSetupWatch = anchor to transport
            },
        )
    }
}

@Composable
private fun SavedCameraOverview(
    onPairNewCamera: () -> Unit,
    onOpenMediaLibrary: () -> Unit,
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
        // iOS intro card order: Pair new → Media Library → Settings.
        StartupFilledButton(
            text = stringResource(R.string.saved_pair_new_camera),
            enabled = enabled,
            onClick = onPairNewCamera,
            modifier = Modifier.fillMaxWidth(),
        )
        StartupOutlineButton(
            text = stringResource(R.string.saved_media_library),
            enabled = enabled,
            onClick = onOpenMediaLibrary,
            modifier = Modifier.fillMaxWidth(),
        )
        StartupOutlineButton(
            text = stringResource(R.string.action_settings),
            enabled = enabled,
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
    onConnect: (SavedCameraRecord) -> Unit,
    onRename: (List<SavedCameraRecord>) -> Unit,
    onRemove: (List<SavedCameraRecord>) -> Unit,
    onAddSetup: (List<SavedCameraRecord>) -> Unit,
    onForgetSetup: (SavedCameraRecord) -> Unit,
    nearbyBroadcasts: List<com.opencapture.openzcine.relay.RelayBroadcast>,
    onWatchBroadcast: (com.opencapture.openzcine.relay.RelayBroadcast) -> Unit,
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
                // One ROW per body: records stay one-per-setup on disk; the assigned name
                // groups them here (Android's identity axis -- see SavedCameraGroups).
                val isDiscovered = { record: SavedCameraRecord ->
                    if (record.transport == SavedCameraTransport.USB_C) {
                        usbCameras.any {
                            it.access == UsbPtpCameraAccess.READY && it.hostKey == record.host
                        }
                    } else {
                        discoveredCameras.any { camera ->
                            if (camera.host == record.host) return@any true
                            if (!SavedCameraRecords.cameraNamesMatch(
                                    camera.name,
                                    record.cameraName,
                                )
                            ) {
                                return@any false
                            }
                            // A name match only lights a setup whose kind agrees with the
                            // network the discovery came from (iOS rule): a body found over
                            // the phone's hotspot is not evidence for the Router setup, and
                            // an AP setup lights on its own fixed host only.
                            val viaHotspot =
                                SavedCameraRecords.isPhoneHotspotHost(camera.host)
                            when (record.transport) {
                                SavedCameraTransport.PHONE_HOTSPOT -> viaHotspot
                                SavedCameraTransport.INFRASTRUCTURE -> !viaHotspot
                                SavedCameraTransport.CAMERA_ACCESS_POINT -> false
                                SavedCameraTransport.USB_C -> true
                            }
                        }
                    }
                }
                SavedCameraGroups.group(cameras).forEach { group ->
                    val active = SavedCameraGroups.activeRecord(group, isDiscovered)
                    SavedCameraRow(
                        group = group,
                        active = active,
                        isDiscovered = isDiscovered,
                        enabled = !busy,
                        onConnect = onConnect,
                        onRename = { onRename(group) },
                        onRemove = { onRemove(group) },
                        onAddSetup = { onAddSetup(group) },
                        onForgetSetup = onForgetSetup,
                    )
                }
            }
            // Broadcasts are listed beside cameras on the same screen — found and forgotten
            // on the same schedule, exactly like the iOS camera list.
            Spacer(Modifier.height(12.dp))
            Text(
                stringResource(R.string.saved_nearby_broadcasts),
                color = StartupColors.muted,
                fontSize = 11.sp,
                fontWeight = FontWeight.SemiBold,
                letterSpacing = 1.4.sp,
            )
            Spacer(Modifier.height(6.dp))
            if (nearbyBroadcasts.isEmpty()) {
                Text(
                    stringResource(R.string.saved_nearby_broadcasts_empty),
                    color = StartupColors.dim,
                    fontSize = 12.sp,
                )
            } else {
                nearbyBroadcasts.forEach { broadcast ->
                    Row(
                        Modifier.fillMaxWidth()
                            .startupTile(borderColor = StartupColors.ready.copy(alpha = 0.28f))
                            .clickable(enabled = !busy) { onWatchBroadcast(broadcast) }
                            .padding(horizontal = 14.dp, vertical = 12.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        Text(
                            broadcast.name,
                            color = StartupColors.ink,
                            fontSize = 15.sp,
                            fontWeight = FontWeight.SemiBold,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                            modifier = Modifier.weight(1f),
                        )
                        StartupFilledButton(
                            text = stringResource(R.string.relay_watch),
                            enabled = !busy,
                            onClick = { onWatchBroadcast(broadcast) },
                            modifier = Modifier.width(96.dp),
                        )
                    }
                    Spacer(Modifier.height(8.dp))
                }
            }
        }
    }
}

@Composable
internal fun SavedCameraRow(
    group: List<SavedCameraRecord>,
    active: SavedCameraRecord,
    isDiscovered: (SavedCameraRecord) -> Boolean,
    enabled: Boolean,
    onConnect: (SavedCameraRecord) -> Unit,
    onRename: () -> Unit,
    onRemove: () -> Unit,
    onAddSetup: () -> Unit,
    onForgetSetup: (SavedCameraRecord) -> Unit,
) {
    val activeDiscovered = isDiscovered(active)
    val availabilityColor = if (activeDiscovered) StartupColors.ready else StartupColors.dim
    val moreOptionsDescription = stringResource(R.string.saved_more_options)
    var optionsExpanded by remember { mutableStateOf(false) }
    Column(
        Modifier.fillMaxWidth()
            .startupTile(borderColor = availabilityColor.copy(alpha = 0.28f))
            .clickable(enabled = enabled) { onConnect(active) }
            .padding(horizontal = 14.dp, vertical = 12.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Text(
                active.displayTitle,
                color = StartupColors.ink,
                fontSize = 15.sp,
                fontWeight = FontWeight.SemiBold,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f),
            )
            Text(
                stringResource(
                    if (activeDiscovered) {
                        R.string.saved_pill_online
                    } else {
                        R.string.saved_pill_offline
                    }
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
            if (activeDiscovered) {
                StartupFilledButton(
                    text = stringResource(R.string.action_connect),
                    enabled = enabled,
                    onClick = { onConnect(active) },
                    modifier = Modifier.width(96.dp),
                )
            } else {
                StartupOutlineButton(
                    text = stringResource(R.string.action_connect),
                    onClick = { onConnect(active) },
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
            savedCameraSubtitle(active),
            color = StartupColors.muted,
            fontSize = 13.sp,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        // One body, several ways in: a chip per saved setup, availability dot on each. The
        // row's title, pill and Connect follow the ACTIVE setup; a chip tap connects over
        // that specific one, long-press forgets it, and "+" adds a setup this camera doesn't
        // have yet. Scrolls sideways rather than truncating -- the iOS row's rule.
        val chipScroll = rememberScrollState()
        Row(
            Modifier.horizontalScroll(chipScroll),
            horizontalArrangement = Arrangement.spacedBy(6.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            group.forEach { record ->
                SavedCameraSetupChip(
                    record = record,
                    isActive = record.id == active.id,
                    isDiscovered = isDiscovered(record),
                    enabled = enabled,
                    canForget = group.size > 1,
                    onConnect = { onConnect(record) },
                    onForget = { onForgetSetup(record) },
                )
            }
            if (missingSetupKinds(group).isNotEmpty()) {
                Text(
                    "+ " + stringResource(R.string.saved_add_setup),
                    color = StartupColors.muted,
                    fontSize = 11.sp,
                    fontWeight = FontWeight.SemiBold,
                    modifier =
                        Modifier.clip(CircleShape)
                            .border(1.dp, StartupColors.muted.copy(alpha = 0.35f), CircleShape)
                            .clickable(enabled = enabled, onClick = onAddSetup)
                            .padding(horizontal = 10.dp, vertical = 5.dp),
                )
            }
        }
    }
}

/** The kinds this camera could still be set up for -- mirror of the iOS list. */
internal fun missingSetupKinds(group: List<SavedCameraRecord>): List<SavedCameraTransport> {
    val saved = group.map(SavedCameraRecord::transport).toSet()
    return listOf(
            SavedCameraTransport.USB_C,
            SavedCameraTransport.CAMERA_ACCESS_POINT,
            SavedCameraTransport.INFRASTRUCTURE,
            SavedCameraTransport.PHONE_HOTSPOT,
        )
        .filterNot(saved::contains)
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun SavedCameraSetupChip(
    record: SavedCameraRecord,
    isActive: Boolean,
    isDiscovered: Boolean,
    enabled: Boolean,
    canForget: Boolean,
    onConnect: () -> Unit,
    onForget: () -> Unit,
) {
    var forgetExpanded by remember { mutableStateOf(false) }
    val dotColor = if (isDiscovered) StartupColors.ready else StartupColors.dim
    Box {
        Row(
            Modifier.clip(CircleShape)
                .background(
                    StartupColors.control.copy(alpha = if (isActive) 0.8f else 0.45f)
                )
                .border(
                    1.dp,
                    if (isActive) {
                        StartupColors.accent.copy(alpha = 0.45f)
                    } else {
                        StartupColors.border.copy(alpha = 0.12f)
                    },
                    CircleShape,
                )
                .combinedClickable(
                    enabled = enabled,
                    onClick = onConnect,
                    onLongClick =
                        if (canForget) {
                            { forgetExpanded = true }
                        } else {
                            null
                        },
                )
                .padding(horizontal = 9.dp, vertical = 5.dp),
            horizontalArrangement = Arrangement.spacedBy(5.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(Modifier.size(6.dp).clip(CircleShape).background(dotColor))
            Text(
                record.transport.displayName,
                color = if (isActive) StartupColors.ink else StartupColors.muted,
                fontSize = 10.5.sp,
                fontWeight = FontWeight.SemiBold,
                maxLines = 1,
            )
        }
        DropdownMenu(
            expanded = forgetExpanded,
            onDismissRequest = { forgetExpanded = false },
        ) {
            DropdownMenuItem(
                text = {
                    Text(
                        stringResource(
                            R.string.saved_forget_setup,
                            record.transport.displayName,
                        )
                    )
                },
                onClick = {
                    forgetExpanded = false
                    onForget()
                },
            )
        }
    }
}

/**
 * "+ Add setup" on a saved camera: a mini-wizard scoped to THIS camera, offering only the
 * setup kinds it doesn't have yet -- the iOS sheet, as a dialog. Setups save themselves at
 * the next connect; this only prepares the way (joins the camera's Wi-Fi for AP when the key
 * is already stored, guides for the rest).
 */
@Composable
private fun SavedCameraAddSetupDialog(
    group: List<SavedCameraRecord>,
    usbReadyHostKey: String?,
    routerDiscoveredHost: String?,
    onDismiss: () -> Unit,
    onJoinCameraAp: (SavedCameraRecord) -> Unit,
    onConnectSetup: (SavedCameraTransport, String) -> Unit,
    onArmSetupWatch: (SavedCameraTransport) -> Unit,
) {
    val active = group.first()
    AlertDialog(
        onDismissRequest = onDismiss,
        title = {
            Text(stringResource(R.string.saved_add_setup_title, active.displayTitle))
        },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text(
                    stringResource(R.string.saved_add_setup_body),
                    color = StartupColors.muted,
                    fontSize = 13.sp,
                    lineHeight = 18.sp,
                )
                missingSetupKinds(group).forEach { kind ->
                    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        Text(
                            stringResource(
                                when (kind) {
                                    SavedCameraTransport.CAMERA_ACCESS_POINT ->
                                        R.string.saved_setup_ap_title
                                    SavedCameraTransport.INFRASTRUCTURE ->
                                        R.string.saved_setup_router_title
                                    SavedCameraTransport.PHONE_HOTSPOT ->
                                        R.string.saved_setup_hotspot_title
                                    SavedCameraTransport.USB_C ->
                                        R.string.saved_setup_usb_title
                                }
                            ),
                            color = StartupColors.ink,
                            fontSize = 14.sp,
                            fontWeight = FontWeight.SemiBold,
                        )
                        Text(
                            stringResource(
                                when (kind) {
                                    SavedCameraTransport.CAMERA_ACCESS_POINT ->
                                        R.string.saved_setup_ap_body
                                    SavedCameraTransport.INFRASTRUCTURE ->
                                        R.string.saved_setup_router_body
                                    SavedCameraTransport.PHONE_HOTSPOT ->
                                        R.string.saved_setup_hotspot_body
                                    SavedCameraTransport.USB_C ->
                                        R.string.saved_setup_usb_body
                                }
                            ),
                            color = StartupColors.muted,
                            fontSize = 12.5.sp,
                            lineHeight = 17.sp,
                        )
                        // Every row DOES something — connect immediately when the path is
                        // already reachable, else dismiss into the list, which is watching.
                        when (kind) {
                            SavedCameraTransport.CAMERA_ACCESS_POINT ->
                                TextButton(onClick = { onJoinCameraAp(active) }) {
                                    Text(stringResource(R.string.saved_setup_ap_action_join))
                                }
                            SavedCameraTransport.USB_C ->
                                TextButton(
                                    onClick = {
                                        val hostKey = usbReadyHostKey
                                        if (hostKey != null) {
                                            onConnectSetup(SavedCameraTransport.USB_C, hostKey)
                                        } else {
                                            onArmSetupWatch(SavedCameraTransport.USB_C)
                                        }
                                    },
                                ) {
                                    Text(
                                        stringResource(
                                            if (usbReadyHostKey != null) {
                                                R.string.saved_setup_connect_now
                                            } else {
                                                R.string.saved_setup_connect_when_plugged
                                            }
                                        )
                                    )
                                }
                            SavedCameraTransport.INFRASTRUCTURE ->
                                TextButton(
                                    onClick = {
                                        val host = routerDiscoveredHost
                                        if (host != null) {
                                            onConnectSetup(
                                                SavedCameraTransport.INFRASTRUCTURE, host
                                            )
                                        } else {
                                            onArmSetupWatch(
                                                SavedCameraTransport.INFRASTRUCTURE
                                            )
                                        }
                                    },
                                ) {
                                    Text(
                                        stringResource(
                                            if (routerDiscoveredHost != null) {
                                                R.string.saved_setup_connect_now
                                            } else {
                                                R.string.saved_setup_find_on_network
                                            }
                                        )
                                    )
                                }
                            SavedCameraTransport.PHONE_HOTSPOT ->
                                TextButton(
                                    onClick = {
                                        onArmSetupWatch(SavedCameraTransport.PHONE_HOTSPOT)
                                    },
                                ) {
                                    Text(stringResource(R.string.saved_setup_wait_for_camera))
                                }
                        }
                    }
                }
            }
        },
        confirmButton = {
            TextButton(onClick = onDismiss) {
                Text(stringResource(R.string.action_cancel))
            }
        },
    )
}

/**
 * iOS row subtitle, path-typed: `USB-C · connect cable to wake the session`, or
 * `<path> · <recency>` -- with the camera's own SSID shown ONLY on the AP setup. A router
 * record wearing a derived NIKON_… name was the display face of the old cross-path confusion.
 */
@Composable
private fun savedCameraSubtitle(record: SavedCameraRecord): String {
    if (record.transport == SavedCameraTransport.USB_C) {
        return stringResource(R.string.saved_usb_subtitle)
    }
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
    val ssid =
        record.wifiSsid.takeIf {
            record.transport == SavedCameraTransport.CAMERA_ACCESS_POINT && !it.isNullOrBlank()
        }
    return if (ssid != null) {
        stringResource(
            R.string.saved_path_subtitle_ssid, record.transport.displayName, ssid, recency
        )
    } else {
        stringResource(R.string.saved_path_subtitle, record.transport.displayName, recency)
    }
}

/**
 * The forgot-to-switch-networks case, word for word from iOS: a router/hotspot camera that
 * cannot be found is overwhelmingly a phone on the WRONG network, and a spinner that never
 * says so leaves the operator waiting on a connect that cannot succeed. AP setups are
 * excluded -- their remedy is the join flow, which reconnect already runs.
 */
private fun wrongNetworkHint(record: SavedCameraRecord): String =
    when (record.transport) {
        SavedCameraTransport.INFRASTRUCTURE,
        SavedCameraTransport.PHONE_HOTSPOT,
        ->
            " If the camera is on a router or hotspot, make sure this device is on the same " +
                "network — that is where it was reached last time."
        SavedCameraTransport.CAMERA_ACCESS_POINT,
        SavedCameraTransport.USB_C,
        -> ""
    }

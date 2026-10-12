package com.opencapture.openzcine.pairing

import com.opencapture.opencine.nikon.NikonHosts
import com.opencapture.opencine.nikon.CameraConnectionPhase
import com.opencapture.opencine.nikon.CameraSession
import com.opencapture.opencine.nikon.CameraSessionState
import com.opencapture.opencine.nikon.UsbPtpOpenResult
import com.opencapture.openzcine.transport.CameraDiscovery
import com.opencapture.openzcine.transport.CameraListDiscovery
import com.opencapture.openzcine.transport.DiscoveredCamera
import com.opencapture.openzcine.transport.UsbPtpCamera
import com.opencapture.openzcine.transport.UsbPtpCameraAccess
import com.opencapture.openzcine.transport.localIPv4Interfaces
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import com.opencapture.opencine.nikon.SavedCameraRecord
import com.opencapture.opencine.nikon.SavedCameraRecords
import com.opencapture.opencine.nikon.SavedCameraTransport

/** Where a saved-setup reconnect is (the phases the connect card shows). */
internal sealed interface SavedCameraPhase {
    data object Idle : SavedCameraPhase

    /** An armed "+ Add setup" watch waiting for the camera on [transport]. */
    data class WatchingForSetup(val title: String, val transport: SavedCameraTransport) : SavedCameraPhase

    data class Joining(val title: String) : SavedCameraPhase

    data class Connecting(val title: String) : SavedCameraPhase

    data class Pairing(val title: String) : SavedCameraPhase

    data class ConfirmOnCamera(val title: String, val pin: String?) : SavedCameraPhase

    data class Reconnecting(val title: String) : SavedCameraPhase
}

/** A reconnect that ended without a camera, with the operator copy the card shows. */
internal class SavedCameraConnectException(message: String, val wifiOff: Boolean = false) : Exception(message)

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
 * The saved-setup reconnect owner (moved out of the old saved-cameras screen so the shared
 * connection flow can drive it through `NikonConnectPort`): camera-AP records rejoin only their
 * stored SSID, hotspot and router records only use discovery and last-known PTP-IP hosts and never
 * ask Android to switch networks, USB-C records open the attached device. Discovery here is
 * passive (NSD, the USB attachment list, liveness dials); the cameras list never speaks PTP.
 */
internal class SavedCameraConnector(
    private val environment: PairingEnvironment,
    /** Whether the phone's Wi-Fi radio is on ([isWifiRadioEnabled]). */
    private val wifiEnabled: () -> Boolean,
    /** Whether the phone is on a camera's own access point ([isOnCameraAccessPointNetwork]). */
    private val onCameraAccessPoint: () -> Boolean,
    private val scope: CoroutineScope,
    private val listDiscovery: CameraListDiscovery = CameraListDiscovery(),
) {
    private val _phase = MutableStateFlow<SavedCameraPhase>(SavedCameraPhase.Idle)
    val phase: StateFlow<SavedCameraPhase> = _phase.asStateFlow()
    val discoveredCameras = MutableStateFlow(emptyList<DiscoveredCamera>())
    val usbCameras = MutableStateFlow(emptyList<UsbPtpCamera>())
    val aliveHosts = MutableStateFlow(emptySet<String>())

    /**
     * This phone's own hotspot subnet(s). Every per-kind rule leans on it: a hotspot discovery
     * lights the Hotspot setup, never the Wi-Fi one. Polled: turning a hotspot on is a
     * several-second human action, and enumerating interfaces is a syscall.
     */
    val hotspotSubnetBases = MutableStateFlow(emptySet<String>())
    private var discovery: Job? = null

    /** Listening runs while the cameras list shows; liveness dials only the given saved hosts. */
    fun startDiscovery(savedWirelessHosts: () -> Set<String>) {
        if (discovery != null) return
        discovery =
            scope.launch {
                launch { environment.hotspotCameras.collect { discoveredCameras.value = it } }
                environment.usbCameraSource?.let { source -> launch { source.cameras.collect { usbCameras.value = it } } }
                launch {
                    while (true) {
                        hotspotSubnetBases.value =
                            withContext(Dispatchers.IO) { SavedCameraRecords.phoneHotspotSubnetBases(localIPv4Interfaces()) }
                        delay(5_000)
                    }
                }
                while (true) {
                    refreshLiveness(savedWirelessHosts())
                    delay(10_000)
                }
            }
    }

    fun stopDiscovery() {
        discovery?.cancel()
        discovery = null
    }

    /** The saved wireless hosts' liveness, from the presence-port dial (never PTP). */
    suspend fun refreshLiveness(hosts: Set<String>) {
        aliveHosts.value = if (hosts.isEmpty()) emptySet() else listDiscovery.alive(hosts)
    }

    /** The live discovery this saved setup would be dialling, when there is one. */
    fun discoveryFor(record: SavedCameraRecord): DiscoveredCamera? {
        if (record.transport == SavedCameraTransport.USB_C) return null
        return discoveredCameras.value.firstOrNull { camera ->
            camera.host == record.host || SavedCameraRecords.cameraNamesMatch(camera.name, record.cameraName)
        }
    }

    /**
     * Whether this setup is reachable now (the setup chip's light): an access point only from its
     * own network, a cable when attached, a wireless setup when liveness or a discovery on the
     * matching network shape says so.
     */
    fun isDiscovered(record: SavedCameraRecord): Boolean =
        when {
            record.transport == SavedCameraTransport.CAMERA_ACCESS_POINT && !onCameraAccessPoint() ->
                false
            record.transport == SavedCameraTransport.USB_C ->
                usbCameras.value.any { it.access == UsbPtpCameraAccess.READY && it.hostKey == record.host }
            record.host in aliveHosts.value -> true
            else ->
                discoveredCameras.value.any { camera ->
                    if (camera.host == record.host) return@any true
                    if (!SavedCameraRecords.cameraNamesMatch(camera.name, record.cameraName)) return@any false
                    val viaHotspot = SavedCameraRecords.isPhoneHotspotHost(camera.host, hotspotSubnetBases.value)
                    when (record.transport) {
                        SavedCameraTransport.PHONE_HOTSPOT -> viaHotspot
                        SavedCameraTransport.INFRASTRUCTURE -> !viaHotspot
                        SavedCameraTransport.CAMERA_ACCESS_POINT -> false
                        SavedCameraTransport.USB_C -> true
                    }
                }
        }

    /**
     * The address this setup may dial right now, or null when nothing is dialable yet: a camera-AP
     * record holding the pending key must rediscover on the live link after join, never hand the
     * key itself to the transport (#327).
     */
    private fun resolvedHost(record: SavedCameraRecord): String? {
        if (record.transport == SavedCameraTransport.USB_C) return record.host
        return CameraDiscovery.dialableSavedHost(record.host, discoveryFor(record)?.host)
    }

    /** Same session shape as a normal reconnect (restore-then-pair). */
    private fun createPostConfirmReconnectSession(record: SavedCameraRecord): CameraSession? =
        when (record.transport) {
            SavedCameraTransport.CAMERA_ACCESS_POINT,
            SavedCameraTransport.PHONE_HOTSPOT,
            SavedCameraTransport.INFRASTRUCTURE,
            // A null host means discovery has not named the camera yet: report "no session" so
            // the owning retry loop keeps waiting instead of dialling a non-address.
            -> resolvedHost(record)?.let(environment.createSession)
            SavedCameraTransport.USB_C -> {
                val source = environment.usbCameraSource ?: return null
                val camera =
                    usbCameras.value.firstOrNull { it.access == UsbPtpCameraAccess.READY && it.hostKey == record.host }
                        ?: return null
                when (val opened = source.open(camera)) {
                    is UsbPtpOpenResult.Opened -> environment.createUsbSession(opened)
                    is UsbPtpOpenResult.Rejected -> null
                }
            }
        }

    private suspend fun reconnectAfterNikonPairing(record: SavedCameraRecord, confirmPin: String? = null): PairedCamera? {
        val isCameraAp = record.transport == SavedCameraTransport.CAMERA_ACCESS_POINT
        _phase.value = SavedCameraPhase.ConfirmOnCamera(record.displayTitle, confirmPin)
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
                    _phase.value = SavedCameraPhase.Reconnecting(record.displayTitle)
                    val paired = createPostConfirmReconnectSession(record)?.let { tryConnected(it, record) }
                    if (paired != null) return@withTimeoutOrNull paired
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
                    val session = createPostConfirmReconnectSession(record) ?: return@reconnectCameraApAfterConfirm false
                    paired = tryConnected(session, record)
                    paired != null
                },
                onPhaseReconnecting = { _phase.value = SavedCameraPhase.Reconnecting(record.displayTitle) },
            )
        return if (ok) paired else null
    }

    /** Connects [session]; hands it over only when it is live and past the body confirmation. */
    private suspend fun tryConnected(session: CameraSession, record: SavedCameraRecord): PairedCamera? {
        var handedOffSession = false
        try {
            session.connect()
            val connected = session.state.value as? CameraSessionState.Connected
            val phaseNow = session.connectionProgress.value.phase
            if (connected != null && phaseNow != CameraConnectionPhase.CONFIRM_ON_CAMERA && phaseNow != CameraConnectionPhase.PAIRING) {
                handedOffSession = true
                return PairedCamera(
                    session = session,
                    savedCamera =
                        record.copy(
                            host = resolvedHost(record) ?: record.host,
                            cameraName = connected.identity.name,
                            lastSeenAtEpochMillis = System.currentTimeMillis(),
                        ),
                )
            }
            return null
        } finally {
            if (!handedOffSession) withContext(NonCancellable) { session.disconnect() }
        }
    }

    /**
     * Connects [record] (camera AP: joins [cameraApSsid] with [cameraApKey], else the stored SSID
     * and key). Returns the live session; throws [SavedCameraConnectException] with the card's copy,
     * and rethrows cancellation after releasing everything it opened.
     */
    suspend fun connect(record: SavedCameraRecord, cameraApSsid: String? = null, cameraApKey: String? = null): PairedCamera {
        _phase.value = SavedCameraPhase.Connecting(record.displayTitle)
        var session: CameraSession? = null
        var handoffSucceeded = false
        // May still be the non-dialable pending key here: a camera-AP setup resolves it by
        // discovery on the live link AFTER the join below (#327).
        var host = resolvedHost(record) ?: record.host
        try {
            if (record.transport == SavedCameraTransport.USB_C) {
                val source =
                    environment.usbCameraSource ?: throw SavedCameraConnectException("USB-C camera support is unavailable on this device.")
                val camera =
                    usbCameras.value.firstOrNull { it.access == UsbPtpCameraAccess.READY && it.hostKey == record.host }
                        ?: throw SavedCameraConnectException(
                            "Connect your saved USB-C camera and approve Android access before reconnecting.",
                        )
                when (val opened = source.open(camera)) {
                    is UsbPtpOpenResult.Opened -> {
                        host = opened.hostKey
                        session =
                            try {
                                environment.createUsbSession(opened)
                            } catch (error: Exception) {
                                // The source already claimed its physical interface: release it
                                // when the session wrapper cannot take ownership.
                                opened.transport.close()
                                throw error
                            }
                    }
                    is UsbPtpOpenResult.Rejected -> throw SavedCameraConnectException(opened.message)
                }
            } else if (record.transport == SavedCameraTransport.CAMERA_ACCESS_POINT) {
                if (!wifiEnabled()) throw SavedCameraConnectException(WIFI_OFF_MESSAGE, wifiOff = true)
                val ssid =
                    cameraApSsid ?: record.wifiSsid
                        ?: throw SavedCameraConnectException(
                            "This camera needs its Wi‑Fi network name. Pair it again to refresh the profile.",
                        )
                val key =
                    cameraApKey ?: environment.credentials.passphrase(ssid)
                        ?: throw SavedCameraConnectException(
                            "The Wi‑Fi key for $ssid is not available on this phone. Pair again to save it.",
                        )
                _phase.value = SavedCameraPhase.Joining(record.displayTitle)
                // Pre-scan + fail-fast retries live inside joinWithFallback.
                environment.primeCameraApScan(ssid)
                if (!environment.joinCameraAp(ssid, key)) {
                    // Wi-Fi toggled off after the join was staged: the joiner bails in
                    // milliseconds, and the generic copy would be misleading.
                    if (!wifiEnabled()) throw SavedCameraConnectException(WIFI_OFF_MESSAGE, wifiOff = true)
                    throw SavedCameraConnectException(
                        "Couldn't join $ssid. Keep the camera's network screen on, stay near the camera, and try again. If Android shows \"Searching for devices…\" and finds nothing, re-pair with a fresh SSID/key scan.",
                    )
                }
                // The encrypted store is the only place a confirmed key lives: a key that arrived
                // from the add-setup scan has never been written anywhere else.
                environment.credentials.save(ssid, key)
                // Wi-Fi association can complete before the camera answers PTP-IP Init; racing
                // that window surfaces rejectedInitiator.
                delay(CAMERA_AP_POST_JOIN_SETTLE_MILLIS)
                // Discover on the live link with a FRESH browse: results from the pre-join
                // network are stale here (#327).
                if (!NikonHosts.isDialableHost(host)) {
                    host =
                        withTimeoutOrNull(CAMERA_AP_DISCOVER_AFTER_JOIN_MILLIS) {
                            environment.hotspotCameras.first { it.isNotEmpty() }.first().host
                        }
                            ?: throw SavedCameraConnectException(
                                "Joined $ssid but couldn't find the camera on its network. Keep the camera on its connection screen and try again.",
                            )
                }
            }

            val isCameraAp = record.transport == SavedCameraTransport.CAMERA_ACCESS_POINT
            val maxAttempts = if (isCameraAp) CAMERA_AP_CONNECT_ATTEMPTS else 1
            var lastFailureDetail: String? = null
            var pairedCamera: PairedCamera? = null
            var attempt = 0
            while (pairedCamera == null && attempt < maxAttempts) {
                if (attempt > 0) delay(CAMERA_AP_CONNECT_RETRY_DELAY_MILLIS)
                attempt += 1
                _phase.value = SavedCameraPhase.Connecting(record.displayTitle)
                // Restore-then-pair; on the last camera-AP attempt after a handshake rejection,
                // force first-time pairing so a forgotten camera-side profile can be recreated.
                val useFirstTimePairing =
                    isCameraAp && attempt == maxAttempts && indicatesSavedProfileUnavailable(lastFailureDetail)
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
                    scope.launch(start = CoroutineStart.UNDISPATCHED) {
                        attemptSession.connectionProgress.collect { progress ->
                            when (progress.phase) {
                                CameraConnectionPhase.PAIRING -> _phase.value = SavedCameraPhase.Pairing(record.displayTitle)
                                CameraConnectionPhase.CONFIRM_ON_CAMERA -> {
                                    pairingWasConfirmed = true
                                    pairingPin = progress.detail.ifBlank { null }
                                    _phase.value = SavedCameraPhase.ConfirmOnCamera(record.displayTitle, pairingPin)
                                }
                                CameraConnectionPhase.FAILED -> failureDetail = progress.detail.ifBlank { null }
                                else -> Unit
                            }
                        }
                    }
                try {
                    attemptSession.connect()
                    val connected = attemptSession.state.value as? CameraSessionState.Connected
                    pairedCamera =
                        if (pairingWasConfirmed) {
                            // A saved profile was rejected and Nikon accepted a fresh pairing:
                            // never hand this temporary session to the monitor; wait for the body
                            // confirmation and reconnect with the newly restored profile.
                            _phase.value = SavedCameraPhase.ConfirmOnCamera(record.displayTitle, pairingPin)
                            withContext(NonCancellable) { attemptSession.disconnect() }
                            session = null
                            reconnectAfterNikonPairing(
                                record.copy(
                                    host = host,
                                    cameraName = connected?.identity?.name ?: record.cameraName,
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
                                            lastSeenAtEpochMillis = System.currentTimeMillis(),
                                        ),
                                )
                            }
                        }
                    if (pairedCamera == null) {
                        lastFailureDetail =
                            failureDetail ?: attemptSession.connectionProgress.value.detail.takeIf { it.isNotBlank() }
                        withContext(NonCancellable) { attemptSession.disconnect() }
                        session = null
                    }
                } finally {
                    progressWatcher.cancel()
                }
            }
            if (pairedCamera == null) {
                throw SavedCameraConnectException(
                    friendlyCameraConnectionFailure(
                        lastFailureDetail ?: "Couldn't reach ${record.displayTitle}. Check the camera connection and try again.",
                    ) + wrongNetworkHint(record),
                )
            }
            handoffSucceeded = true
            return pairedCamera
        } catch (error: SavedCameraConnectException) {
            throw error
        } catch (error: CancellationException) {
            throw error
        } catch (_: Exception) {
            throw SavedCameraConnectException(
                friendlyCameraConnectionFailure(
                    "Couldn't reach ${record.displayTitle}. Check the camera connection and try again.",
                ) + wrongNetworkHint(record),
            )
        } finally {
            _phase.value = SavedCameraPhase.Idle
            if (!handoffSucceeded) {
                session?.let { active -> withContext(NonCancellable) { active.disconnect() } }
                if (record.transport == SavedCameraTransport.CAMERA_ACCESS_POINT) environment.releaseCameraAp()
            }
        }
    }

    /**
     * An armed "+ Add setup" watch: suspends until the camera of [anchor] shows on [transport]
     * (a ready cable, or a discovery whose network shape fits), and returns the setup to connect.
     * Strict name matching, except that a single shape-fitting candidate is the camera the tap
     * consented to (a generic name never matches strictly).
     */
    suspend fun awaitSetup(anchor: SavedCameraRecord, transport: SavedCameraTransport): SavedCameraRecord {
        _phase.value = SavedCameraPhase.WatchingForSetup(anchor.displayTitle, transport)
        try {
            while (true) {
                val host =
                    when (transport) {
                        SavedCameraTransport.USB_C -> {
                            val ready = usbCameras.value.filter { it.access == UsbPtpCameraAccess.READY }
                            (ready.firstOrNull { SavedCameraRecords.cameraNamesMatch(it.displayName, anchor.cameraName) }
                                ?: ready.singleOrNull())?.hostKey
                        }
                        SavedCameraTransport.INFRASTRUCTURE, SavedCameraTransport.PHONE_HOTSPOT -> {
                            val fitting =
                                discoveredCameras.value.filter {
                                    SavedCameraRecords.isPhoneHotspotHost(it.host, hotspotSubnetBases.value) ==
                                        (transport == SavedCameraTransport.PHONE_HOTSPOT)
                                }
                            (fitting.firstOrNull { SavedCameraRecords.cameraNamesMatch(it.name, anchor.cameraName) }
                                ?: fitting.singleOrNull())?.host
                        }
                        SavedCameraTransport.CAMERA_ACCESS_POINT -> null
                    }
                if (host != null) {
                    // A fresh profile id keeps the new setup from merging into the sibling it was
                    // copied from; it saves itself on the connect.
                    return anchor.copy(transport = transport, host = host, profileID = host, wifiSsid = null, lastSeenAtEpochMillis = null)
                }
                delay(500)
            }
        } finally {
            _phase.value = SavedCameraPhase.Idle
        }
    }

    companion object {
        const val WIFI_OFF_MESSAGE: String = "Joining the camera's Wi‑Fi needs Wi‑Fi turned on. Turn on Wi‑Fi, then try again."

        /**
         * The forgot-to-switch-networks case: a router or hotspot camera that cannot be found is
         * overwhelmingly a phone on the wrong network. AP setups are excluded; their remedy is the
         * join flow, which reconnect already runs.
         */
        fun wrongNetworkHint(record: SavedCameraRecord): String =
            when (record.transport) {
                SavedCameraTransport.INFRASTRUCTURE,
                SavedCameraTransport.PHONE_HOTSPOT,
                ->
                    " If the camera is on a router or hotspot, make sure this device is on the same " +
                        "network, where it was reached last time."
                SavedCameraTransport.CAMERA_ACCESS_POINT,
                SavedCameraTransport.USB_C,
                -> ""
            }
    }
}

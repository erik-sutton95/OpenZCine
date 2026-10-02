package com.opencapture.openzcine.pairing

import com.opencapture.opencine.core.ConnectionFailure
import com.opencapture.opencine.core.DiscoveryMode
import com.opencapture.opencine.core.RecoveryAction
import com.opencapture.opencine.core.RouteKind
import com.opencapture.opencine.nikon.NikonConnectException
import com.opencapture.opencine.nikon.NikonConnectPort
import com.opencapture.opencine.nikon.NikonConnectRequest
import com.opencapture.opencine.nikon.NikonConnection
import com.opencapture.opencine.nikon.NikonConnectionPhase
import com.opencapture.opencine.nikon.NikonIntegration
import com.opencapture.opencine.nikon.NikonOpenCineSession
import com.opencapture.opencine.nikon.NikonSighting
import com.opencapture.openzcine.R
import com.opencapture.openzcine.transport.UsbPtpCameraAccess
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.launch

/**
 * OpenCine's `NikonConnectPort` over this app's own reconnect machinery ([SavedCameraConnector])
 * and its saved setups. The app keeps its save rules: [onPaired] persists the setup and opens the
 * monitor, [onForget] removes setups (with the access point's key), and the integration reads the
 * records back from [recordsJson].
 *
 * A saved setup another device holds fails with a "Take over" action instead of dialling; the
 * operator's tap ([allowTakeOver]) lets the retry through. An access-point setup the add-setup
 * scan produced arrives through [pendingAccessPoint] (its key never enters the shared document).
 */
internal class AppNikonConnectPort(
    /** This app's string resources (a seam so JVM tests need no Context). */
    private val copy: PortCopy,
    private val connector: SavedCameraConnector,
    private val records: () -> List<SavedCameraRecord>,
    private val recordsJson: () -> String?,
    private val onPaired: (PairedCamera) -> Unit,
    private val onForget: (hosts: List<String>) -> Unit,
    private val onExplicitUsbReconnect: (host: String) -> Unit,
    private val scope: CoroutineScope,
    private val offersDiagnostics: Boolean,
    /** Root-owned adapter, shared by pairing, cameras and the monitor. */
    private val commonSession: (com.opencapture.opencine.nikon.CameraSession) -> NikonOpenCineSession = { NikonOpenCineSession(it, scope) },
) : NikonConnectPort {
    override val sightings = MutableStateFlow<List<NikonSighting>>(emptyList())
    override val phase = MutableStateFlow<Pair<NikonConnectionPhase, String?>?>(null)
    private val takeOvers = mutableSetOf<String>()
    private var sightingsJob: Job? = null

    /** SSID and key the add-setup scan read for the next access-point setup. */
    var pendingAccessPoint: Pair<String, String>? = null

    init {
        scope.launch { connector.phase.collect { phase.value = phaseOf(it) } }
    }

    override fun savedRecords(): String? = recordsJson()

    private var requested = false

    /**
     * Discovery runs only while the cameras page shows: the model asks whenever nothing is live,
     * but the wizard and the monitor (reached without the model) must not pay for the list's dials.
     */
    var pageVisible: Boolean = false
        set(value) {
            field = value
            updateDiscovery()
        }

    /** Both modes listen the same way here: pairing runs its own wizard search (not this port). */
    override fun startDiscovery(mode: DiscoveryMode) {
        requested = true
        updateDiscovery()
    }

    override fun stopDiscovery() {
        requested = false
        updateDiscovery()
    }

    private fun updateDiscovery() {
        if (!(requested && pageVisible)) {
            connector.stopDiscovery()
            sightingsJob?.cancel()
            sightingsJob = null
            return
        }
        connector.startDiscovery {
            records()
                .filter { it.transport == SavedCameraTransport.INFRASTRUCTURE || it.transport == SavedCameraTransport.PHONE_HOTSPOT }
                .map(SavedCameraRecord::host)
                .filter(String::isNotBlank)
                .toSet()
        }
        if (sightingsJob != null) return
        sightingsJob =
            scope.launch {
                combine(connector.discoveredCameras, connector.usbCameras, connector.aliveHosts, connector.hotspotSubnetBases) { _, _, _, _ -> }
                    .collect { sightings.value = currentSightings() }
            }
    }

    /**
     * Each reachable saved setup by its own host (the integration names its camera), then the
     * cameras discovery sees that no setup describes, and ready USB cameras.
     */
    internal fun currentSightings(): List<NikonSighting> {
        val saved = records()
        val reachable =
            saved.filter(connector::isDiscovered).map { record ->
                val held = connector.discoveryFor(record)?.heldByDeviceName
                NikonSighting(
                    record.host, record.cameraName,
                    when {
                        held != null -> NikonSighting.Source.HELD_BY_ANOTHER_DEVICE
                        record.transport == SavedCameraTransport.USB_C -> NikonSighting.Source.USB
                        else -> NikonSighting.Source.LIVENESS
                    },
                    held,
                )
            }
        val unsaved =
            connector.discoveredCameras.value
                .filter { camera ->
                    saved.none { it.host == camera.host || SavedCameraRecords.cameraNamesMatch(camera.name, it.cameraName) }
                }
                .map {
                    NikonSighting(
                        it.host, it.name,
                        if (it.isHeldByAnotherDevice) NikonSighting.Source.HELD_BY_ANOTHER_DEVICE else NikonSighting.Source.NETWORK,
                        it.heldByDeviceName,
                    )
                }
        val usb =
            connector.usbCameras.value
                .filter { camera -> camera.access == UsbPtpCameraAccess.READY && saved.none { it.host == camera.hostKey } }
                .mapNotNull { camera -> camera.hostKey?.let { NikonSighting(it, camera.displayName, NikonSighting.Source.USB) } }
        return reachable + unsaved + usb
    }

    /** The operator agreed to drop the device holding the camera at [host]: the next connect goes. */
    fun allowTakeOver(host: String) {
        takeOvers += host
    }

    override suspend fun connect(request: NikonConnectRequest): NikonConnection {
        var apSsid: String? = null
        var apKey: String? = null
        val record: SavedCameraRecord =
            when (request) {
                is NikonConnectRequest.Saved ->
                    records().firstOrNull { it.host.equals(request.host, ignoreCase = true) && kindOf(it.transport) == request.kind }
                        ?: throw failure(ConnectionFailure.Reason.NotFound, "setup.gone", copy.text(R.string.conn_failed_detail))
                is NikonConnectRequest.AddSetup -> {
                    val anchor =
                        records().firstOrNull { it.host.equals(request.anchorHost, ignoreCase = true) && kindOf(it.transport) == request.anchorKind }
                            ?: throw failure(ConnectionFailure.Reason.NotFound, "setup.gone", copy.text(R.string.conn_failed_detail))
                    val transport = transportOf(request.kind)
                    if (transport == SavedCameraTransport.CAMERA_ACCESS_POINT) {
                        val scanned = pendingAccessPoint
                        pendingAccessPoint = null
                        apSsid = scanned?.first ?: accessPointSsidFor(anchor)
                        apKey = scanned?.second
                        // Pinned to the access point's own address: the anchor is a router or
                        // hotspot setup, and its host is not where the camera's own network answers.
                        SavedCameraRecords.pinnedToAccessPoint(
                            anchor.copy(transport = SavedCameraTransport.CAMERA_ACCESS_POINT, wifiSsid = apSsid),
                        )
                    } else {
                        connector.awaitSetup(anchor, transport)
                    }
                }
                is NikonConnectRequest.Discovered -> {
                    // A camera discovery sees; the integration asked first when another device holds it.
                    val sighting = request.sighting
                    val transport =
                        when {
                            sighting.source == NikonSighting.Source.USB -> SavedCameraTransport.USB_C
                            SavedCameraRecords.isPhoneHotspotHost(sighting.host, connector.hotspotSubnetBases.value) ->
                                SavedCameraTransport.PHONE_HOTSPOT
                            else -> SavedCameraTransport.INFRASTRUCTURE
                        }
                    if (request.takeOver) takeOvers += sighting.host
                    SavedCameraRecord(sighting.host, sighting.name.orEmpty(), transport, null, null)
                }
            }
        val held = connector.discoveryFor(record)?.takeIf { it.isHeldByAnotherDevice }
        if (held != null && record.host !in takeOvers) {
            throw NikonConnectException(
                NikonIntegration.failure(
                    ConnectionFailure.Reason.HeldElsewhere, "held",
                    held.heldByDeviceName?.takeIf(String::isNotBlank)
                        ?.let { copy.text(R.string.pairing_take_over_message_named, it) }
                        ?: copy.text(R.string.pairing_take_over_message),
                ).copy(
                    actions =
                        listOf(
                            RecoveryAction.Integration(TAKE_OVER, copy.text(R.string.action_take_over)),
                            RecoveryAction.Retry,
                        ),
                ),
            )
        }
        takeOvers.remove(record.host)
        if (request is NikonConnectRequest.Saved && record.transport == SavedCameraTransport.USB_C) {
            onExplicitUsbReconnect(record.host)
        }
        val paired =
            try {
                connector.connect(record, apSsid, apKey)
            } catch (error: SavedCameraConnectException) {
                throw if (error.wifiOff) {
                    NikonConnectException(
                        NikonIntegration.failure(ConnectionFailure.Reason.RadioOff(ConnectionFailure.Radio.WIFI), "wifi.off", error.message.orEmpty())
                            .copy(actions = listOf(RecoveryAction.OpenSettings, RecoveryAction.Retry)),
                    )
                } else {
                    failure(ConnectionFailure.Reason.Other, "connect.failed", error.message.orEmpty())
                }
            }
        onPaired(paired)
        return NikonConnection(commonSession(paired.session), paired.savedCamera.host, kindOf(paired.savedCamera.transport))
    }

    // ponytail: nothing to do; the integration cancels the coroutine running connect(), which
    // unwinds the connector and releases what it opened (the access point included).
    override fun cancel() = Unit

    override fun forget(hosts: List<String>) = onForget(hosts)

    private fun failure(reason: ConnectionFailure.Reason, code: String, message: String): NikonConnectException {
        val failure = NikonIntegration.failure(reason, code, message)
        return NikonConnectException(
            if (offersDiagnostics) {
                failure.copy(actions = failure.actions + RecoveryAction.Integration(DIAGNOSTICS, "Share diagnostics"))
            } else {
                failure
            },
        )
    }

    private fun phaseOf(phase: SavedCameraPhase): Pair<NikonConnectionPhase, String?>? =
        when (phase) {
            SavedCameraPhase.Idle -> null
            is SavedCameraPhase.WatchingForSetup ->
                NikonConnectionPhase.DISCOVERING to
                    when (phase.transport) {
                        SavedCameraTransport.USB_C -> copy.text(R.string.conn_watch_usb_detail, phase.title)
                        SavedCameraTransport.PHONE_HOTSPOT -> copy.text(R.string.conn_watch_hotspot_detail)
                        else -> copy.text(R.string.conn_searching_detail, phase.title)
                    }
            is SavedCameraPhase.Joining -> NikonConnectionPhase.JOINING_WIFI to copy.text(R.string.conn_joining_detail)
            is SavedCameraPhase.Connecting ->
                NikonConnectionPhase.HANDSHAKING to copy.text(R.string.conn_handshaking_detail, phase.title)
            is SavedCameraPhase.Pairing -> NikonConnectionPhase.PAIRING to copy.text(R.string.conn_pairing_detail, phase.title)
            is SavedCameraPhase.ConfirmOnCamera ->
                NikonConnectionPhase.CONFIRM_ON_CAMERA to copy.text(R.string.conn_confirm_detail, phase.title)
            is SavedCameraPhase.Reconnecting ->
                NikonConnectionPhase.HANDSHAKING to copy.text(R.string.conn_reconnecting_detail, phase.title)
        }

    companion object {
        const val TAKE_OVER: String = "takeOver"
        const val DIAGNOSTICS: String = "diagnostics"

        fun kindOf(transport: SavedCameraTransport): RouteKind =
            when (transport) {
                SavedCameraTransport.CAMERA_ACCESS_POINT -> RouteKind.CAMERA_ACCESS_POINT
                SavedCameraTransport.INFRASTRUCTURE -> RouteKind.INFRASTRUCTURE_NETWORK
                SavedCameraTransport.PHONE_HOTSPOT -> RouteKind.PHONE_HOTSPOT
                SavedCameraTransport.USB_C -> RouteKind.USB
            }

        fun transportOf(kind: RouteKind): SavedCameraTransport =
            when (kind) {
                RouteKind.CAMERA_ACCESS_POINT -> SavedCameraTransport.CAMERA_ACCESS_POINT
                RouteKind.INFRASTRUCTURE_NETWORK -> SavedCameraTransport.INFRASTRUCTURE
                RouteKind.USB -> SavedCameraTransport.USB_C
                RouteKind.PHONE_HOTSPOT, RouteKind.CAPTURE_DEVICE -> SavedCameraTransport.PHONE_HOTSPOT
            }
    }
}

/** The copy the port shows, from this app's string resources. */
internal fun interface PortCopy {
    fun text(id: Int, vararg args: Any): String
}

/**
 * The access-point SSIDs whose last setup is gone between [before] and [after]: their keys go with
 * them (a remembered key is what let a re-added setup join silently, so a forgotten camera could
 * not be told from a remembered one).
 */
internal fun removedAccessPointSsids(before: List<SavedCameraRecord>, after: List<SavedCameraRecord>): List<String> {
    val kept = after.mapNotNull(SavedCameraRecord::wifiSsid).toSet()
    return before
        .filter { it.transport == SavedCameraTransport.CAMERA_ACCESS_POINT }
        .mapNotNull(SavedCameraRecord::wifiSsid)
        .filterNot(kept::contains)
        .distinct()
}

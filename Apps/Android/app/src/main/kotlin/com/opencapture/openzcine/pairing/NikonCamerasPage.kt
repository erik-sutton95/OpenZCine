package com.opencapture.openzcine.pairing

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.opencapture.opencine.appkit.AddSetupChooser
import com.opencapture.opencine.appkit.AddSetupFlow
import com.opencapture.opencine.appkit.AddSetupNotice
import com.opencapture.opencine.appkit.AddSetupOption
import com.opencapture.monitorui.MonitorCameraAction
import com.opencapture.monitorui.MonitorConnectFailure
import com.opencapture.monitorui.MonitorIcon
import com.opencapture.monitorui.MonitorPalette
import com.opencapture.opencine.appkit.CameraItem
import com.opencapture.opencine.appkit.DiscoveryPermissions
import com.opencapture.opencine.appkit.IntegrationSlots
import com.opencapture.opencine.core.RouteDraft
import com.opencapture.opencine.core.SavedCamera
import com.opencapture.opencine.nikon.NikonAccessPointSsid
import com.opencapture.opencine.nikon.NikonNative
import com.opencapture.opencine.nikon.NikonSavedRecordsV0
import com.opencapture.opencine.nikon.SavedCameraRecord
import com.opencapture.opencine.nikon.SavedCameraRecords
import com.opencapture.opencine.nikon.SavedCameraTransport
import com.opencapture.openzcine.R
import com.opencapture.openzcine.relay.RelayBroadcast
import com.opencapture.openzcine.transport.UsbPtpCameraAccess

/**
 * The SSID a camera-AP setup for this camera would join: the one on the record, else the one
 * derived from the body's name. Null when neither answers (a renamed or generic camera name),
 * which is exactly the case where the credential scanner has to read it off the camera's own
 * network screen. Twin of iOS `CameraWiFiSSID.resolve(for:) ?? deriveSSID(fromCameraName:)`.
 */
internal fun accessPointSsidFor(record: SavedCameraRecord): String? =
    record.wifiSsid?.takeIf(NikonAccessPointSsid::isNikonZAccessPoint)
        ?: runCatching { NikonNative.deriveAccessPointSSID(record.cameraName) }.getOrNull()

/** The kinds this camera could still be set up for (mirror of the iOS list). */
internal fun missingSetupKinds(group: List<SavedCameraRecord>): List<SavedCameraTransport> {
    val saved = group.map(SavedCameraRecord::transport).toSet()
    return listOf(
            SavedCameraTransport.USB_C,
            SavedCameraTransport.CAMERA_ACCESS_POINT,
            SavedCameraTransport.INFRASTRUCTURE,
            SavedCameraTransport.PHONE_HOTSPOT,
        )
        // Router stays on offer however many are saved: each network is its own setup, keyed by
        // the network's name. Every other kind is singular: the access point is the camera's own
        // network, the hotspot is this phone, the cable is the cable.
        .filterNot { it != SavedCameraTransport.INFRASTRUCTURE && saved.contains(it) }
}

/** The shared saved-camera document's preferences (SHELL-02): `openzcine.cameras` / `document`. */
internal const val CAMERAS_DOCUMENT_PREFERENCES: String = "openzcine.cameras"

/** The app records behind a camera of the shared document (its routes name host and transport). */
internal fun recordsOf(camera: SavedCamera, records: List<SavedCameraRecord>): List<SavedCameraRecord> =
    records.filter { record ->
        camera.routes.any {
            it.extras[NikonSavedRecordsV0.Extra.HOST].equals(record.host, ignoreCase = true) &&
                it.extras[NikonSavedRecordsV0.Extra.TRANSPORT] == record.transport.persistedValue
        }
    }

/**
 * This app's slots on the shared pages: the pair page's way into the transport wizard
 * ([onChooseConnection]: the camera access point, hotspot, router, USB-C and HDMI paths that nearby
 * discovery alone never offers), adding a setup (its add-setup choices; an access point without a
 * stored key goes through [onScanAccessPoint], the full-screen credential scanner) and the take-over
 * question.
 */
internal fun nikonIntegrationSlots(
    connector: SavedCameraConnector,
    records: () -> List<SavedCameraRecord>,
    credentials: PairingCredentials,
    onScanAccessPoint: (SavedCamera) -> Unit,
    onChooseConnection: () -> Unit,
): IntegrationSlots =
    IntegrationSlots(
        pairing = {
            ChooseConnectionEntry(onChooseConnection)
            val cameras by connector.usbCameras.collectAsState()
            val pending = cameras.filter {
                it.access == UsbPtpCameraAccess.NEEDS_PERMISSION || it.access == UsbPtpCameraAccess.DENIED
            }
            pending.forEach { camera ->
                val detail = stringResource(usbCameraDetailResource(camera.access))
                Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text(camera.displayName, fontWeight = FontWeight.SemiBold)
                    Text(detail, fontSize = 11.sp)
                    val action = stringResource(R.string.action_allow)
                    MonitorCameraAction(
                        text = action, primary = false, enabled = true,
                        contentDescription = action,
                        onClick = { connector.requestUsbPermission(camera) },
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
            }
        },
        addSetup = { camera, done ->
            addSetupFlow(camera, recordsOf(camera, records()), connector, credentials, done, onScanAccessPoint)
        },
    )

/** The pair page's entry to the transport wizard, in the cameras page's own action style. */
@Composable
private fun ChooseConnectionEntry(onClick: () -> Unit) {
    val title = stringResource(R.string.pairing_step_choose_path)
    MonitorCameraAction(
        text = title, primary = false, enabled = true, contentDescription = title, onClick = onClick,
        modifier = Modifier.fillMaxWidth(),
        icon = { tint -> MonitorIcon(MonitorIcon.PLUS, null, Modifier.size(14.dp), tint = tint) },
    )
}

/**
 * "+ Add setup": the kinds this camera does not have yet. Every row does something: a reachable
 * path connects now, an unreachable one arms a watch the card shows while it waits (both are the
 * same `RouteDraft`; the connect saves the setup), and the access point joins with its stored key
 * or scans the camera's network screen first.
 */
@Composable
private fun addSetupFlow(
    camera: SavedCamera,
    group: List<SavedCameraRecord>,
    connector: SavedCameraConnector,
    credentials: PairingCredentials,
    done: (RouteDraft?) -> Unit,
    onScanAccessPoint: (SavedCamera) -> Unit,
): AddSetupFlow {
    val anchor =
        group.firstOrNull()
            ?: run {
                androidx.compose.runtime.LaunchedEffect(camera.id) { done(null) }
                return AddSetupFlow(AddSetupChooser("", "", emptyList()), onSelect = {}, onCancel = { done(null) })
            }
    // Asked for here only: naming a network is the one thing this permission buys, and a second
    // router setup is the one place the name is needed.
    val networkName =
        rememberPermissionGate("setup.networkName", DiscoveryPermissions.wifiName, DiscoveryPermissions.wifiNameRequest)
    val usbCameras by connector.usbCameras.collectAsState()
    val discovered by connector.discoveredCameras.collectAsState()
    val usbReady = usbCameras.any { it.access == UsbPtpCameraAccess.READY }
    val routerFound = discovered.any { SavedCameraRecords.cameraNamesMatch(it.name, anchor.cameraName) }
    val apKeyStored = remember(anchor.id) { accessPointSsidFor(anchor)?.let(credentials::passphrase) != null }
    val options = missingSetupKinds(group).map { kind ->
        val (title, body) = when (kind) {
            SavedCameraTransport.CAMERA_ACCESS_POINT -> R.string.saved_setup_ap_title to R.string.saved_setup_ap_body
            SavedCameraTransport.INFRASTRUCTURE -> R.string.saved_setup_router_title to R.string.saved_setup_router_body
            SavedCameraTransport.PHONE_HOTSPOT -> R.string.saved_setup_hotspot_title to R.string.saved_setup_hotspot_body
            SavedCameraTransport.USB_C -> R.string.saved_setup_usb_title to R.string.saved_setup_usb_body
        }
        val action = when (kind) {
            SavedCameraTransport.CAMERA_ACCESS_POINT -> if (apKeyStored) R.string.saved_setup_ap_action_join else R.string.saved_setup_ap_action_scan
            SavedCameraTransport.USB_C -> if (usbReady) R.string.saved_setup_connect_now else R.string.saved_setup_connect_when_plugged
            SavedCameraTransport.INFRASTRUCTURE -> if (routerFound) R.string.saved_setup_connect_now else R.string.saved_setup_find_on_network
            SavedCameraTransport.PHONE_HOTSPOT -> R.string.saved_setup_wait_for_camera
        }
        AddSetupOption(kind.name, AppNikonConnectPort.kindOf(kind), stringResource(title), stringResource(body), stringResource(action))
    }
    val notice = if (group.any { it.transport == SavedCameraTransport.INFRASTRUCTURE } && !networkName.granted) {
        AddSetupNotice("networkName", stringResource(R.string.saved_setup_router_name_permission), stringResource(R.string.saved_setup_router_name_permission_action))
    } else null
    return AddSetupFlow(
        chooser = AddSetupChooser(stringResource(R.string.saved_add_setup_title, anchor.displayTitle), stringResource(R.string.saved_add_setup_body), options, notice = notice),
        onSelect = { option ->
            if (option.kind == com.opencapture.opencine.core.RouteKind.CAMERA_ACCESS_POINT && !apKeyStored) {
                done(null)
                onScanAccessPoint(camera)
            } else {
                done(RouteDraft(option.kind))
            }
        },
        onNoticeAction = { if (it == "networkName") networkName.request() },
        onCancel = { done(null) },
        cancelTitle = stringResource(R.string.action_cancel),
    )
}

/** The filtered-network notice's row id on the shared page. */
internal const val FILTER_NOTICE_ID: String = "notice:filter"

/** A broadcast's row id on the shared page. */
internal const val RELAY_ROW_PREFIX: String = "relay:"

/**
 * The NEARBY rows this app adds after the cameras: the filtered-network notice when it is proven,
 * then the broadcasts this phone can watch.
 */
@Composable
internal fun nearbyBroadcastItems(broadcasts: List<RelayBroadcast>, networkFiltersDiscovery: Boolean): List<CameraItem> {
    val notice =
        if (networkFiltersDiscovery) {
            listOf(
                CameraItem(
                    id = FILTER_NOTICE_ID, name = "This network", subtitle = "Devices below were found directly",
                    status = "", actionTitle = "", isAvailable = false,
                    failure = MonitorConnectFailure("Discovery is filtered", stringResource(R.string.saved_network_filters_discovery), emptyList()),
                ),
            )
        } else {
            emptyList()
        }
    val watch = stringResource(R.string.relay_watch)
    return notice +
        broadcasts.map {
            CameraItem(
                id = RELAY_ROW_PREFIX + it.name, name = it.name, subtitle = "Live feed from another device", badge = "LIVE",
                status = "Watch the picture without controlling the camera.", actionTitle = watch,
            )
        }
}

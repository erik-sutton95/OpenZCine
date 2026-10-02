package com.opencapture.openzcine.pairing

import android.content.SharedPreferences
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.opencapture.monitorui.MonitorConnectFailure
import com.opencapture.opencine.appkit.CameraItem
import com.opencapture.opencine.appkit.IntegrationSlots
import com.opencapture.opencine.appkit.SavedCamerasStore
import com.opencapture.opencine.appkit.StoredString
import com.opencapture.opencine.appkit.stored
import com.opencapture.opencine.core.RouteDraft
import com.opencapture.opencine.core.SavedCamera
import com.opencapture.opencine.nikon.NikonNative
import com.opencapture.opencine.nikon.NikonSavedRecordsV0
import com.opencapture.opencine.nikon.NikonTakeOverPrompt
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
    record.wifiSsid?.takeIf(::looksLikeNikonAccessPointSsid)
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

/**
 * The shared saved-camera document over this app's own records, which stay in
 * `openzcine.saved-cameras` / `records-json` where every older build reads them (mirrored, merged
 * on every load). [onRecordsPatched] runs right after the shared page patched the records (a
 * rename, a forgotten setup) so the app reads them back. Wi-Fi keys are never touched here.
 */
internal fun nikonCamerasStore(
    document: SharedPreferences,
    records: SharedPreferences,
    onRecordsPatched: () -> Unit,
): SavedCamerasStore =
    SavedCamerasStore(
        document.stored("document"),
        SavedCamerasStore.Legacy(
            object : StoredString {
                override fun read(): String? = records.getString(SharedPreferencesSavedCameraStore.RECORDS_KEY, null)

                override fun write(value: String) {
                    records.edit().putString(SharedPreferencesSavedCameraStore.RECORDS_KEY, value).apply()
                    onRecordsPatched()
                }
            },
            NikonSavedRecordsV0(),
            "records",
        ),
    )

/** The app's records after the shared page patched them; a removed access point setup takes its key. */
internal fun recordsAfterSharedEdit(
    before: List<SavedCameraRecord>,
    store: SavedCameraStore,
    removeKey: (String) -> Unit,
): List<SavedCameraRecord> = store.records().also { after -> removedAccessPointSsids(before, after).forEach(removeKey) }

/** The app's forget: every setup at [hosts] goes, each access point setup taking its own key. */
internal fun recordsForgetting(
    hosts: List<String>,
    records: List<SavedCameraRecord>,
    removeKey: (String) -> Unit,
): List<SavedCameraRecord> {
    var remaining = records
    for (record in records.filter { r -> hosts.any { it.equals(r.host, ignoreCase = true) } }) {
        record.wifiSsid?.takeIf { record.transport == SavedCameraTransport.CAMERA_ACCESS_POINT }?.let(removeKey)
        remaining = SavedCameraRecords.removing(record.host, record.cameraName, remaining)
    }
    return remaining
}

/** The app records behind a camera of the shared document (its routes name host and transport). */
internal fun recordsOf(camera: SavedCamera, records: List<SavedCameraRecord>): List<SavedCameraRecord> =
    records.filter { record ->
        camera.routes.any {
            it.extras[NikonSavedRecordsV0.Extra.HOST].equals(record.host, ignoreCase = true) &&
                it.extras[NikonSavedRecordsV0.Extra.TRANSPORT] == record.transport.persistedValue
        }
    }

/**
 * This app's slots on the shared pages: adding a setup (its add-setup choices; an access point
 * without a stored key goes through [onScanAccessPoint], the full-screen credential scanner) and
 * the take-over question.
 */
internal fun nikonIntegrationSlots(
    connector: SavedCameraConnector,
    records: () -> List<SavedCameraRecord>,
    credentials: PairingCredentials,
    onScanAccessPoint: (SavedCamera) -> Unit,
): IntegrationSlots =
    IntegrationSlots(
        addRoute = { camera, done ->
            AddSetupCard(camera, recordsOf(camera, records()), connector, credentials, done, onScanAccessPoint)
        },
        prompt = { prompt -> (prompt as? NikonTakeOverPrompt)?.let { TakeOverPromptDialog(it) } },
    )

@Composable
private fun TakeOverPromptDialog(prompt: NikonTakeOverPrompt) {
    AlertDialog(
        onDismissRequest = prompt.cancel,
        title = { Text(stringResource(R.string.pairing_take_over_title)) },
        text = { Text(prompt.fallbackText) },
        confirmButton = { TextButton(onClick = prompt.confirm) { Text(stringResource(R.string.action_take_over)) } },
        dismissButton = { TextButton(onClick = prompt.cancel) { Text(stringResource(R.string.action_cancel)) } },
    )
}

/**
 * "+ Add setup": the kinds this camera does not have yet. Every row does something: a reachable
 * path connects now, an unreachable one arms a watch the card shows while it waits (both are the
 * same `RouteDraft`; the connect saves the setup), and the access point joins with its stored key
 * or scans the camera's network screen first.
 */
@Composable
private fun AddSetupCard(
    camera: SavedCamera,
    group: List<SavedCameraRecord>,
    connector: SavedCameraConnector,
    credentials: PairingCredentials,
    done: (RouteDraft?) -> Unit,
    onScanAccessPoint: (SavedCamera) -> Unit,
) {
    val anchor =
        group.firstOrNull()
            ?: run {
                androidx.compose.runtime.LaunchedEffect(camera.id) { done(null) }
                return
            }
    val context = LocalContext.current
    // Asked for here only: naming a network is the one thing this permission buys, and a second
    // router setup is the one place the name is needed.
    var networkNameGranted by remember { mutableStateOf(ConnectedNetworkName.isPermissionGranted(context)) }
    val networkNameLauncher =
        rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { networkNameGranted = it }
    val usbCameras by connector.usbCameras.collectAsState()
    val discovered by connector.discoveredCameras.collectAsState()
    val usbReady = usbCameras.any { it.access == UsbPtpCameraAccess.READY }
    val routerFound = discovered.any { SavedCameraRecords.cameraNamesMatch(it.name, anchor.cameraName) }
    val apKeyStored = remember(anchor.id) { accessPointSsidFor(anchor)?.let(credentials::passphrase) != null }
    Column(
        Modifier.background(StartupColors.surface, RoundedCornerShape(20.dp)).padding(20.dp).verticalScroll(rememberScrollState()),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text(stringResource(R.string.saved_add_setup_title, anchor.displayTitle), color = StartupColors.ink, fontSize = 17.sp, fontWeight = FontWeight.Bold)
        Text(stringResource(R.string.saved_add_setup_body), color = StartupColors.muted, fontSize = 13.sp, lineHeight = 18.sp)
        if (group.any { it.transport == SavedCameraTransport.INFRASTRUCTURE } && !networkNameGranted) {
            Text(stringResource(R.string.saved_setup_router_name_permission), color = StartupColors.muted, fontSize = 12.5.sp, lineHeight = 17.sp)
            TextButton(onClick = { networkNameLauncher.launch(android.Manifest.permission.ACCESS_FINE_LOCATION) }) {
                Text(stringResource(R.string.saved_setup_router_name_permission_action), color = StartupColors.accent, fontSize = 13.sp)
            }
        }
        for (kind in missingSetupKinds(group)) {
            val (title, body) =
                when (kind) {
                    SavedCameraTransport.CAMERA_ACCESS_POINT -> R.string.saved_setup_ap_title to R.string.saved_setup_ap_body
                    SavedCameraTransport.INFRASTRUCTURE -> R.string.saved_setup_router_title to R.string.saved_setup_router_body
                    SavedCameraTransport.PHONE_HOTSPOT -> R.string.saved_setup_hotspot_title to R.string.saved_setup_hotspot_body
                    SavedCameraTransport.USB_C -> R.string.saved_setup_usb_title to R.string.saved_setup_usb_body
                }
            val action =
                when (kind) {
                    SavedCameraTransport.CAMERA_ACCESS_POINT ->
                        if (apKeyStored) R.string.saved_setup_ap_action_join else R.string.saved_setup_ap_action_scan
                    SavedCameraTransport.USB_C ->
                        if (usbReady) R.string.saved_setup_connect_now else R.string.saved_setup_connect_when_plugged
                    SavedCameraTransport.INFRASTRUCTURE ->
                        if (routerFound) R.string.saved_setup_connect_now else R.string.saved_setup_find_on_network
                    SavedCameraTransport.PHONE_HOTSPOT -> R.string.saved_setup_wait_for_camera
                }
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(stringResource(title), color = StartupColors.ink, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
                Text(stringResource(body), color = StartupColors.muted, fontSize = 12.5.sp, lineHeight = 17.sp)
                TextButton(
                    onClick = {
                        if (kind == SavedCameraTransport.CAMERA_ACCESS_POINT && !apKeyStored) {
                            done(null)
                            onScanAccessPoint(camera)
                        } else {
                            done(RouteDraft(AppNikonConnectPort.kindOf(kind)))
                        }
                    },
                ) { Text(stringResource(action)) }
            }
        }
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
            TextButton(onClick = { done(null) }) { Text(stringResource(R.string.action_cancel)) }
        }
    }
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

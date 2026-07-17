package com.opencapture.openzcine.pairing

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.Uri
import android.net.nsd.NsdManager
import android.os.Build
import android.provider.Settings
import androidx.annotation.StringRes
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
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
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
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
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalResources
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.opencapture.openzcine.R
import com.opencapture.openzcine.bridge.SwiftCoreCameraSession
import com.opencapture.openzcine.core.CameraSession
import com.opencapture.openzcine.core.CameraSessionState
import com.opencapture.openzcine.transport.AndroidNsdBrowser
import com.opencapture.openzcine.transport.AndroidUsbPtpCameraSource
import com.opencapture.openzcine.transport.CameraDiscovery
import com.opencapture.openzcine.transport.DiscoveredCamera
import com.opencapture.openzcine.transport.UsbPtpCamera
import com.opencapture.openzcine.transport.UsbPtpCameraAccess
import com.opencapture.openzcine.transport.UsbPtpCameraSource
import com.opencapture.openzcine.transport.UsbPtpOpenResult
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** Saved camera-AP credential surface the wizard needs (real: [CameraWifiCredentialStore]). */
public interface PairingCredentials {
    /** Last camera SSID the operator joined — prefills the wizard's SSID field. */
    public var lastSsid: String?

    /** The remembered Wi-Fi key for [ssid], or null when none is stored. */
    public fun passphrase(ssid: String): String?

    /** Remembers [passphrase] for [ssid]. */
    public fun save(ssid: String, passphrase: String)
}

/**
 * Side-effect seams behind the pairing wizard, so the debug demo harness can
 * script every state for screenshots (mirroring `ios/Runner/DemoHarness.swift`).
 *
 * The hard AP/hotspot separation is visible here: [joinCameraAp] is invoked
 * ONLY from the camera-AP path's network step, and [hotspotCameras] is
 * collected ONLY on the phone-hotspot path's discover step — the two paths
 * share no join/scan machinery.
 */
public class PairingEnvironment(
    /** Joins the camera's own Wi-Fi network (camera-AP path only). */
    public val joinCameraAp: suspend (ssid: String, passphrase: String?) -> Boolean,
    /** Releases the camera-AP network binding (camera-AP path only). */
    public val releaseCameraAp: () -> Unit,
    /** NSD camera discovery on the hotspot subnet (phone-hotspot path only). */
    public val hotspotCameras: Flow<List<DiscoveredCamera>>,
    /** Builds the control session once a camera host is known. */
    public val createSession: (host: String) -> CameraSession,
    /** Android USB Host discovery and raw-byte ownership, when the device supports it. */
    public val usbCameraSource: UsbPtpCameraSource?,
    /** Builds a Swift-core-backed session over an already-open USB PTP transport. */
    public val createUsbSession: (UsbPtpOpenResult.Opened) -> CameraSession,
    /** Remembered camera-AP credentials. */
    public val credentials: PairingCredentials,
)

/**
 * Production [PairingEnvironment] over the real platform services.
 *
 * [phaseLogger] receives progress and failure phases. Callers must discard or privately handle the
 * detail value rather than placing it in an anonymous report.
 */
public fun realPairingEnvironment(
    context: Context,
    phaseLogger: (String, String) -> Unit = { _, _ -> },
): PairingEnvironment {
    val joiner = CameraApJoiner(context.getSystemService(ConnectivityManager::class.java))
    val discovery =
        CameraDiscovery(AndroidNsdBrowser(context.getSystemService(NsdManager::class.java)))
    val usbCameraSource = AndroidUsbPtpCameraSource(context)
    return PairingEnvironment(
        joinCameraAp = { ssid, passphrase -> joiner.join(ssid, passphrase) },
        releaseCameraAp = joiner::release,
        hotspotCameras = discovery.cameras(),
        createSession = { host -> SwiftCoreCameraSession(host, phaseLogger) },
        usbCameraSource = usbCameraSource,
        createUsbSession = { opened ->
            SwiftCoreCameraSession(
                host = opened.hostKey,
                cameraNameHint = opened.displayName,
                usbTransport = opened.transport,
                phaseLogger = phaseLogger,
            )
        },
        credentials = CameraWifiCredentialStore(context),
    )
}

/**
 * Debug-only wizard script: a forced starting state plus a fake environment,
 * so every wizard state can be driven for screenshot verification. Built
 * exclusively by the debug `DemoHarness`; release builds always pass null.
 */
public data class PairingScript(
    val start: PairingFlowState,
    val environment: PairingEnvironment,
    /** Jump straight into the connecting phase (for the connecting screenshot). */
    val autoConnect: Boolean = false,
)

/** A connected session together with the profile needed to reconnect after relaunch. */
public data class PairedCamera(
    /** The live, protocol-verified session handed to the monitor. */
    val session: CameraSession,
    /** Durable, non-secret connection metadata for the startup camera list. */
    val savedCamera: SavedCameraRecord,
)

/** The runtime permission NSD/Wi-Fi discovery needs on this OS version. */
public fun requiredPairingPermission(): String =
    if (Build.VERSION.SDK_INT >= 33) {
        Manifest.permission.NEARBY_WIFI_DEVICES
    } else {
        Manifest.permission.ACCESS_FINE_LOCATION
    }

/** Whether the pairing permission is already granted. */
public fun isPairingPermissionGranted(context: Context): Boolean =
    context.checkSelfPermission(requiredPairingPermission()) == PackageManager.PERMISSION_GRANTED

// MARK: - Copy

/**
 * Wizard copy, ported from iOS `StartupWizardContent` / `NativeAppRoot`
 * (body-agnostic "your camera" per the Z-lineup pass; "iPhone" → "phone").
 */
internal object PairingCopy {
    @StringRes
    fun stepTitle(step: PairingStep): Int =
        when (step) {
            PairingStep.PERMISSIONS -> R.string.pairing_step_permissions
            PairingStep.CHOOSE_PATH -> R.string.pairing_step_choose_path
            PairingStep.PREPARE -> R.string.pairing_step_prepare
            PairingStep.NETWORK -> R.string.pairing_step_network
            PairingStep.DISCOVER -> R.string.pairing_step_discover
        }

    @StringRes
    fun introFooter(step: PairingStep): Int =
        when (step) {
            PairingStep.PERMISSIONS -> R.string.pairing_footer_permissions
            PairingStep.CHOOSE_PATH -> R.string.pairing_footer_choose_path
            PairingStep.PREPARE -> R.string.pairing_footer_prepare
            PairingStep.NETWORK -> R.string.pairing_footer_network
            PairingStep.DISCOVER -> R.string.pairing_footer_discover
        }

    @StringRes
    fun pathTitle(path: PairingPath): Int =
        when (path) {
            PairingPath.CAMERA_ACCESS_POINT -> R.string.pairing_path_camera_ap
            PairingPath.PHONE_HOTSPOT -> R.string.pairing_path_phone_hotspot
            PairingPath.USB_C -> R.string.pairing_path_usb_c
        }

    @StringRes
    fun pathBadge(path: PairingPath): Int =
        when (path) {
            PairingPath.CAMERA_ACCESS_POINT -> R.string.pairing_badge_simplest
            PairingPath.PHONE_HOTSPOT -> R.string.pairing_badge_best_wireless
            PairingPath.USB_C -> R.string.pairing_badge_direct_cable
        }

    fun pathPros(path: PairingPath): List<Int> =
        when (path) {
            PairingPath.CAMERA_ACCESS_POINT ->
                listOf(R.string.pairing_pro_light_battery, R.string.pairing_pro_no_phone_setup)
            PairingPath.PHONE_HOTSPOT ->
                listOf(R.string.pairing_pro_wireless_quality, R.string.pairing_pro_stable_high_settings)
            PairingPath.USB_C ->
                listOf(R.string.pairing_pro_direct_wired, R.string.pairing_pro_no_wifi_key)
        }

    @StringRes
    fun pathCon(path: PairingPath): Int =
        when (path) {
            PairingPath.CAMERA_ACCESS_POINT -> R.string.pairing_con_softer_link
            PairingPath.PHONE_HOTSPOT -> R.string.pairing_con_battery_drain
            PairingPath.USB_C -> R.string.pairing_con_data_cable
        }

    /** Short landscape-card copy that keeps every connection choice readable. */
    @StringRes
    fun compactPathPro(path: PairingPath): Int =
        when (path) {
            PairingPath.CAMERA_ACCESS_POINT -> R.string.pairing_compact_pro_camera_ap
            PairingPath.PHONE_HOTSPOT -> R.string.pairing_compact_pro_hotspot
            PairingPath.USB_C -> R.string.pairing_compact_pro_usb
        }

    /** Short landscape-card tradeoff paired with [compactPathPro]. */
    @StringRes
    fun compactPathCon(path: PairingPath): Int =
        when (path) {
            PairingPath.CAMERA_ACCESS_POINT -> R.string.pairing_compact_con_camera_ap
            PairingPath.PHONE_HOTSPOT -> R.string.pairing_compact_con_hotspot
            PairingPath.USB_C -> R.string.pairing_compact_con_usb
        }

    // [VERIFY-ON-HW] Confirm the ZR's exact menu wording for each path on hardware.
    fun prepareSteps(path: PairingPath): List<Int> =
        when (path) {
            PairingPath.CAMERA_ACCESS_POINT ->
                listOf(
                    R.string.pairing_prepare_ap_1,
                    R.string.pairing_prepare_ap_2,
                    R.string.pairing_prepare_ap_3,
                )
            PairingPath.PHONE_HOTSPOT ->
                listOf(
                    R.string.pairing_prepare_hotspot_1,
                    R.string.pairing_prepare_hotspot_2,
                    R.string.pairing_prepare_hotspot_3,
                    R.string.pairing_prepare_hotspot_4,
                )
            PairingPath.USB_C ->
                listOf(
                    R.string.pairing_prepare_usb_1,
                    R.string.pairing_prepare_usb_2,
                    R.string.pairing_prepare_usb_3,
                )
        }

    @StringRes
    fun networkSubtitle(path: PairingPath, keyRemembered: Boolean): Int =
        when (path) {
            PairingPath.CAMERA_ACCESS_POINT ->
                if (keyRemembered) {
                    R.string.pairing_network_ap_remembered
                } else {
                    R.string.pairing_network_ap_new
                }
            PairingPath.PHONE_HOTSPOT -> R.string.pairing_network_hotspot
            PairingPath.USB_C -> R.string.pairing_network_usb
        }

    /** Camera-side instruction card lines for the hotspot network step. */
    val hotspotCameraSteps: List<Int> =
        listOf(
            R.string.pairing_hotspot_camera_1,
            R.string.pairing_hotspot_camera_2,
            R.string.pairing_hotspot_camera_3,
            R.string.pairing_hotspot_camera_4,
        )

    @get:StringRes
    val permissionTitle: Int =
        if (Build.VERSION.SDK_INT >= 33) {
            R.string.pairing_permission_nearby
        } else {
            R.string.pairing_permission_location
        }

    @get:StringRes
    val permissionDetail: Int =
        if (Build.VERSION.SDK_INT >= 33) {
            R.string.pairing_permission_nearby_detail
        } else {
            R.string.pairing_permission_location_detail
        }
}

// MARK: - Wizard

/** What the wizard is busy doing besides showing a step. */
private sealed interface PairingPhase {
    data object Idle : PairingPhase

    data object Joining : PairingPhase

    data object Connecting : PairingPhase

    data class Error(val message: String) : PairingPhase
}

/**
 * The first-pair wizard — Android port of the iOS `StartupFirstPairWizardView`
 * (ios/Runner/StartupDesign.swift): a two-column landscape layout with the
 * goal/progress intro card on the left and the current step card on the
 * right. Ends by handing a connected [PairedCamera] to [onPaired].
 * [onOpenSettings] is available before a connection is in progress so local
 * preferences and media cache can be managed without a camera session.
 */
@Composable
public fun PairingExperience(
    environment: PairingEnvironment,
    script: PairingScript? = null,
    onPaired: (PairedCamera) -> Unit,
    onOpenSettings: (() -> Unit)? = null,
) {
    val context = LocalContext.current
    val resources = LocalResources.current
    var permissionGranted by remember { mutableStateOf(isPairingPermissionGranted(context)) }
    var permissionDenied by remember { mutableStateOf(false) }
    var flow by remember {
        mutableStateOf(
            script?.start ?: PairingFlowState.initial(isPairingPermissionGranted(context))
        )
    }
    var phase by remember { mutableStateOf<PairingPhase>(PairingPhase.Idle) }
    var ssidField by remember {
        mutableStateOf(
            environment.credentials.lastSsid ?: CameraDiscovery.NIKON_ZR_SSID_PREFIX
        )
    }
    var keyField by remember {
        mutableStateOf(
            environment.credentials.lastSsid?.let(environment.credentials::passphrase) ?: ""
        )
    }
    // This remains process-memory-only. `joinCameraAp` is the sole point that
    // writes a confirmed key into the encrypted credential store.
    var keyCameFromScanner by remember { mutableStateOf(false) }
    var cameraWifiScannerPresented by remember { mutableStateOf(false) }
    val keyWasRemembered = remember { keyField.isNotEmpty() }
    var cameras by remember { mutableStateOf(emptyList<DiscoveredCamera>()) }
    var usbCameras by remember { mutableStateOf(emptyList<UsbPtpCamera>()) }
    val scope = rememberCoroutineScope()
    val work = remember { mutableStateOf<Job?>(null) }
    val handedOff = remember { mutableStateOf(false) }

    fun clearScannedCameraWifiDraft() {
        if (!keyCameFromScanner) return
        keyField = ""
        keyCameFromScanner = false
        ssidField = environment.credentials.lastSsid ?: CameraDiscovery.NIKON_ZR_SSID_PREFIX
    }

    DisposableEffect(environment) {
        onDispose {
            work.value?.cancel()
            if (!handedOff.value) environment.releaseCameraAp()
        }
    }

    fun connect(
        session: CameraSession,
        savedCamera: SavedCameraRecord,
        unreachableMessage: String,
    ) {
        phase = PairingPhase.Connecting
        work.value =
            scope.launch {
                try {
                    session.connect()
                    val connected = session.state.value as? CameraSessionState.Connected
                    if (connected != null) {
                        handedOff.value = true
                        onPaired(
                            PairedCamera(
                                session = session,
                                savedCamera =
                                    savedCamera.copy(
                                        cameraName = connected.identity.name,
                                        lastSeenAtEpochMillis = System.currentTimeMillis(),
                                    ),
                            ),
                        )
                    } else {
                        withContext(NonCancellable) { session.disconnect() }
                        phase = PairingPhase.Error(unreachableMessage)
                    }
                } catch (error: CancellationException) {
                    // `sessionConnect` begins native work asynchronously. A
                    // cancelled wizard must tear that work down before a retry
                    // can claim the process-wide PTP slot.
                    withContext(NonCancellable) { session.disconnect() }
                    throw error
                } catch (_: Exception) {
                    withContext(NonCancellable) { session.disconnect() }
                    phase = PairingPhase.Error(unreachableMessage)
                }
            }
    }

    fun connect(host: String) {
        val transport =
            if (flow.path == PairingPath.CAMERA_ACCESS_POINT) {
                SavedCameraTransport.CAMERA_ACCESS_POINT
            } else {
                SavedCameraTransport.PHONE_HOTSPOT
            }
        connect(
            session = environment.createSession(host),
            savedCamera =
                SavedCameraRecord(
                    host = host,
                    cameraName = resources.getString(R.string.pairing_default_camera_name),
                    transport = transport,
                    lastSeenAtEpochMillis = null,
                    wifiSsid =
                        if (transport == SavedCameraTransport.CAMERA_ACCESS_POINT) {
                            ssidField.trim().takeIf(String::isNotEmpty)
                        } else {
                            null
                        },
                ),
            unreachableMessage = resources.getString(R.string.pairing_error_camera_unreachable),
        )
    }

    fun connectUsb(camera: UsbPtpCamera) {
        val source = environment.usbCameraSource
        if (source == null) {
            phase = PairingPhase.Error(resources.getString(R.string.pairing_error_usb_unsupported))
            return
        }
        when (camera.access) {
            UsbPtpCameraAccess.NEEDS_PERMISSION,
            UsbPtpCameraAccess.DENIED,
            -> source.requestPermission(camera)
            UsbPtpCameraAccess.IDENTITY_UNAVAILABLE ->
                phase =
                    PairingPhase.Error(
                        resources.getString(R.string.pairing_error_usb_identity),
                    )
            UsbPtpCameraAccess.READY ->
                when (val opened = source.open(camera)) {
                    is UsbPtpOpenResult.Opened -> {
                        val session =
                            try {
                                environment.createUsbSession(opened)
                            } catch (_: Exception) {
                                // The source already claimed a physical
                                // interface. Do not leave it claimed when the
                                // Swift session wrapper cannot be created.
                                opened.transport.close()
                                phase =
                                    PairingPhase.Error(
                                        resources.getString(R.string.pairing_error_usb_session),
                                    )
                                return
                            }
                        connect(
                            session = session,
                            savedCamera =
                                SavedCameraRecord(
                                    host = opened.hostKey,
                                    cameraName = opened.displayName,
                                    transport = SavedCameraTransport.USB_C,
                                    lastSeenAtEpochMillis = null,
                                    wifiSsid = null,
                                ),
                            unreachableMessage =
                                resources.getString(R.string.pairing_error_usb_unreachable),
                        )
                    }
                    is UsbPtpOpenResult.Rejected -> phase = PairingPhase.Error(opened.message)
                }
        }
    }

    fun joinCameraAp() {
        val ssid = ssidField.trim()
        if (ssid.isEmpty()) return
        val passphrase = keyField.ifEmpty { null }
        phase = PairingPhase.Joining
        work.value =
            scope.launch {
                val joined = environment.joinCameraAp(ssid, passphrase)
                if (joined) {
                    if (passphrase != null) environment.credentials.save(ssid, passphrase)
                    environment.credentials.lastSsid = ssid
                    // The encrypted store now owns a successful scanned key;
                    // release the plaintext draft before the PTP connect begins.
                    keyField = ""
                    keyCameFromScanner = false
                    // Camera-AP mode: the ZR always answers on the fixed AP host.
                    connect(CameraDiscovery.NIKON_ZR_ACCESS_POINT_HOST)
                } else {
                    phase =
                        PairingPhase.Error(
                            resources.getString(R.string.pairing_error_wifi_join)
                        )
                }
            }
    }

    fun cancelWork() {
        work.value?.cancel()
        work.value = null
        if (flow.path == PairingPath.CAMERA_ACCESS_POINT) environment.releaseCameraAp()
        clearScannedCameraWifiDraft()
        phase = PairingPhase.Idle
    }

    fun retreat() {
        if (flow.step == PairingStep.NETWORK) clearScannedCameraWifiDraft()
        phase = PairingPhase.Idle
        flow = flow.retreat()
    }

    // Permission launcher + re-check on return from Settings.
    val permissionLauncher =
        rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
            permissionGranted = granted
            permissionDenied = !granted
        }
    fun requestPairingPermission() {
        if (permissionDenied) {
            context.startActivity(
                Intent(
                    Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                    Uri.fromParts("package", context.packageName, null),
                )
            )
        } else {
            permissionLauncher.launch(requiredPairingPermission())
        }
    }
    val lifecycleOwner = LocalLifecycleOwner.current
    DisposableEffect(lifecycleOwner) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_RESUME) {
                permissionGranted = isPairingPermissionGranted(context)
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }

    // Discovery is deliberately transport-specific: hotspot discovery never
    // touches USB, and USB enumeration never scans or joins a network.
    if (flow.step == PairingStep.DISCOVER) {
        LaunchedEffect(environment, flow.path) {
            if (flow.path == PairingPath.USB_C) {
                cameras = emptyList()
                val source = environment.usbCameraSource
                if (source == null) {
                    usbCameras = emptyList()
                } else {
                    source.cameras.collect { usbCameras = it }
                }
            } else {
                usbCameras = emptyList()
                environment.hotspotCameras.collect { cameras = it }
            }
        }
    }

    if (script?.autoConnect == true) {
        LaunchedEffect(script) { connect(CameraDiscovery.NIKON_ZR_ACCESS_POINT_HOST) }
    }

    val busy = phase == PairingPhase.Joining || phase == PairingPhase.Connecting
    val statusTitle =
        when {
            phase == PairingPhase.Joining -> stringResource(R.string.pairing_status_joining)
            phase == PairingPhase.Connecting -> stringResource(R.string.pairing_status_connecting)
            flow.step == PairingStep.DISCOVER -> stringResource(R.string.pairing_status_looking)
            else -> stringResource(R.string.pairing_status_ready)
        }

    Box(Modifier.fillMaxSize().startupBackdrop()) {
        Column(
            Modifier.fillMaxSize()
                .windowInsetsPadding(WindowInsets.safeDrawing)
                .padding(horizontal = 24.dp, vertical = 12.dp)
        ) {
            StartupHeader(
                title = stringResource(R.string.pairing_connection_setup),
                statusTitle = statusTitle,
                isBusy = busy || flow.step == PairingStep.DISCOVER,
                onOpenSettings = if (busy) null else onOpenSettings,
            )
            Spacer(Modifier.height(12.dp))
            BoxWithConstraints(Modifier.weight(1f)) {
                val viewportWidth = maxWidth
                val twoColumn = viewportWidth >= 640.dp
                // Three connection choices need enough horizontal room in the
                // shallow landscape panel to keep every card's title and
                // tradeoffs visible. Give the active choice step a little of
                // the intro column's unused width rather than clipping its
                // scrollable card body behind the navigation edge.
                val introWidth =
                    if (flow.step == PairingStep.CHOOSE_PATH) {
                        168.dp
                    } else {
                        maxOf(236.dp, viewportWidth * 0.28f)
                    }
                if (twoColumn) {
                    val compactThreshold =
                        if (flow.step == PairingStep.CHOOSE_PATH) 500.dp else 400.dp
                    val compactStep = viewportWidth - introWidth - 16.dp < compactThreshold
                    val condensedChoiceCards =
                        flow.step == PairingStep.CHOOSE_PATH && !compactStep
                    Row(horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                        IntroCard(
                            flow = flow,
                            condensed = condensedChoiceCards,
                            modifier = Modifier.width(introWidth).fillMaxSize(),
                        )
                        StepCard(
                            flow = flow,
                            phase = phase,
                            permissionGranted = permissionGranted,
                            permissionDenied = permissionDenied,
                            ssidField = ssidField,
                            onSsidChange = {
                                ssidField = it
                                keyCameFromScanner = false
                            },
                            keyField = keyField,
                            onKeyChange = {
                                keyField = it
                                keyCameFromScanner = false
                            },
                            keyCameFromScanner = keyCameFromScanner,
                            keyWasRemembered = keyWasRemembered,
                            cameras = cameras,
                            usbCameras = usbCameras,
                            onRequestPermission = ::requestPairingPermission,
                            onScanCameraWifi = { cameraWifiScannerPresented = true },
                            onChoose = { flow = flow.choose(it) },
                            onAdvance = { flow = flow.advance() },
                            onRetreat = ::retreat,
                            onJoin = ::joinCameraAp,
                            onConnectCamera = { connect(it.host) },
                            onConnectUsbCamera = ::connectUsb,
                            onCancel = ::cancelWork,
                            compact = compactStep,
                            condensedChoiceCards = condensedChoiceCards,
                            modifier = Modifier.weight(1f).fillMaxSize(),
                        )
                    }
                } else {
                    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                        StartupWizardProgress(
                            currentStep = flow.displayStepNumber,
                            totalSteps = flow.stepCount,
                        )
                        StepCard(
                            flow = flow,
                            phase = phase,
                            permissionGranted = permissionGranted,
                            permissionDenied = permissionDenied,
                            ssidField = ssidField,
                            onSsidChange = {
                                ssidField = it
                                keyCameFromScanner = false
                            },
                            keyField = keyField,
                            onKeyChange = {
                                keyField = it
                                keyCameFromScanner = false
                            },
                            keyCameFromScanner = keyCameFromScanner,
                            keyWasRemembered = keyWasRemembered,
                            cameras = cameras,
                            usbCameras = usbCameras,
                            onRequestPermission = ::requestPairingPermission,
                            onScanCameraWifi = { cameraWifiScannerPresented = true },
                            onChoose = { flow = flow.choose(it) },
                            onAdvance = { flow = flow.advance() },
                            onRetreat = ::retreat,
                            onJoin = ::joinCameraAp,
                            onConnectCamera = { connect(it.host) },
                            onConnectUsbCamera = ::connectUsb,
                            onCancel = ::cancelWork,
                            compact = viewportWidth < 480.dp,
                            condensedChoiceCards = false,
                            modifier = Modifier.weight(1f).fillMaxWidth(),
                        )
                    }
                }
            }
        }
        if (cameraWifiScannerPresented) {
            CameraWifiScannerOverlay(
                onConfirmed = { candidate ->
                    // The scanner has already been reviewed by the operator;
                    // this stages the exact fields for the normal Join action.
                    // No credential is persisted until a successful join.
                    ssidField = candidate.ssid
                    keyField = candidate.key
                    keyCameFromScanner = true
                    cameraWifiScannerPresented = false
                },
                onDismiss = { cameraWifiScannerPresented = false },
            )
        }
    }
}

// MARK: - Left column

@Composable
private fun IntroCard(
    flow: PairingFlowState,
    condensed: Boolean = false,
    modifier: Modifier = Modifier,
) {
    // Vertical budget is tight in the ~360dp-tall landscape band — sizes are
    // trimmed from the iOS 32pt title so the footer never clips the card edge.
    Column(
        modifier.startupCard().padding(
            horizontal = if (condensed) 16.dp else 20.dp,
            vertical = if (condensed) 14.dp else 16.dp,
        ),
    ) {
        Text(
            stringResource(R.string.pairing_first_run),
            color = StartupColors.muted,
            fontSize = 11.sp,
            fontWeight = FontWeight.SemiBold,
            letterSpacing = 1.4.sp,
        )
        Spacer(Modifier.height(if (condensed) 6.dp else 8.dp))
        Text(
            stringResource(R.string.pairing_intro_title),
            color = StartupColors.ink,
            fontSize = if (condensed) 21.sp else 24.sp,
            fontWeight = FontWeight.Bold,
            lineHeight = if (condensed) 24.sp else 27.sp,
        )
        Spacer(Modifier.height(if (condensed) 6.dp else 8.dp))
        Text(
            if (condensed) {
                stringResource(R.string.pairing_intro_compact)
            } else {
                stringResource(R.string.pairing_intro_full)
            },
            color = StartupColors.muted,
            fontSize = if (condensed) 11.sp else 12.sp,
            lineHeight = if (condensed) 15.sp else 16.sp,
        )
        Spacer(Modifier.weight(1f))
        StartupWizardProgress(currentStep = flow.displayStepNumber, totalSteps = flow.stepCount)
        Spacer(Modifier.height(if (condensed) 6.dp else 8.dp))
        Text(
            if (condensed) {
                stringResource(R.string.pairing_change_path_later)
            } else {
                stringResource(PairingCopy.introFooter(flow.step))
            },
            color = StartupColors.dim,
            fontSize = if (condensed) 10.sp else 11.sp,
            lineHeight = if (condensed) 13.sp else 15.sp,
        )
    }
}

// MARK: - Right column

@Composable
private fun StepCard(
    flow: PairingFlowState,
    phase: PairingPhase,
    permissionGranted: Boolean,
    permissionDenied: Boolean,
    ssidField: String,
    onSsidChange: (String) -> Unit,
    keyField: String,
    onKeyChange: (String) -> Unit,
    keyCameFromScanner: Boolean,
    keyWasRemembered: Boolean,
    cameras: List<DiscoveredCamera>,
    usbCameras: List<UsbPtpCamera>,
    onRequestPermission: () -> Unit,
    onScanCameraWifi: () -> Unit,
    onChoose: (PairingPath) -> Unit,
    onAdvance: () -> Unit,
    onRetreat: () -> Unit,
    onJoin: () -> Unit,
    onConnectCamera: (DiscoveredCamera) -> Unit,
    onConnectUsbCamera: (UsbPtpCamera) -> Unit,
    onCancel: () -> Unit,
    compact: Boolean,
    condensedChoiceCards: Boolean,
    modifier: Modifier = Modifier,
) {
    Column(modifier.startupCard().padding(20.dp)) {
        Text(
            stringResource(R.string.pairing_step_counter, flow.displayStepNumber, flow.stepCount),
            color = StartupColors.muted,
            fontSize = 11.sp,
            fontWeight = FontWeight.SemiBold,
            letterSpacing = 1.4.sp,
        )
        Spacer(Modifier.height(6.dp))
        Text(
            stringResource(PairingCopy.stepTitle(flow.step)),
            color = StartupColors.ink,
            fontSize = 21.sp,
            fontWeight = FontWeight.Bold,
        )
        Spacer(Modifier.height(10.dp))

        val busy = phase == PairingPhase.Joining || phase == PairingPhase.Connecting
        Column(Modifier.weight(1f).verticalScroll(rememberScrollState())) {
            if (busy) {
                BusyBody(phase)
            } else {
                when (flow.step) {
                    PairingStep.PERMISSIONS ->
                        PermissionsBody(permissionGranted, permissionDenied, onRequestPermission)
                    PairingStep.CHOOSE_PATH ->
                        ChoosePathBody(
                            onChoose = onChoose,
                            compact = compact,
                            condensed = condensedChoiceCards,
                        )
                    PairingStep.PREPARE ->
                        NumberedCards(PairingCopy.prepareSteps(flow.path).map { stringResource(it) })
                    PairingStep.NETWORK ->
                        NetworkBody(
                            path = flow.path,
                            ssidField = ssidField,
                            onSsidChange = onSsidChange,
                            keyField = keyField,
                            onKeyChange = onKeyChange,
                            keyCameFromScanner = keyCameFromScanner,
                            keyWasRemembered = keyWasRemembered,
                            onScanCameraWifi = onScanCameraWifi,
                        )
                    PairingStep.DISCOVER ->
                        DiscoverBody(
                            path = flow.path,
                            cameras = cameras,
                            usbCameras = usbCameras,
                            onConnectCamera = onConnectCamera,
                            onConnectUsbCamera = onConnectUsbCamera,
                        )
                }
                (phase as? PairingPhase.Error)?.let { error ->
                    Spacer(Modifier.height(10.dp))
                    Text(
                        error.message,
                        color = StartupColors.destructive,
                        fontSize = 12.sp,
                        lineHeight = 16.sp,
                    )
                }
            }
        }

        // Footer nav — mirrors iOS: none on the choose step (tapping a card
        // advances); Cancel while busy; Back + primary elsewhere.
        if (busy || flow.step != PairingStep.CHOOSE_PATH) {
            Spacer(Modifier.height(12.dp))
        }
        if (busy) {
            Row {
                Spacer(Modifier.weight(1f))
                StartupOutlineButton(
                    stringResource(R.string.action_cancel),
                    onClick = onCancel,
                    modifier = Modifier.width(116.dp),
                )
            }
        } else if (flow.step != PairingStep.CHOOSE_PATH) {
            Row(
                Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                if (flow.canRetreat) {
                    StartupOutlineButton(
                        stringResource(R.string.action_back),
                        onClick = onRetreat,
                        modifier = Modifier.width(116.dp),
                    )
                }
                if (!compact) Spacer(Modifier.weight(1f))
                when {
                    flow.step == PairingStep.NETWORK &&
                        flow.path == PairingPath.CAMERA_ACCESS_POINT ->
                        StartupFilledButton(
                            stringResource(R.string.pairing_join_camera_wifi),
                            enabled = ssidField.isNotBlank(),
                            onClick = onJoin,
                            modifier =
                                if (compact) Modifier.weight(1f) else Modifier.width(220.dp),
                        )
                    !flow.isFinalStep ->
                        StartupFilledButton(
                            stringResource(R.string.action_continue),
                            enabled = flow.step != PairingStep.PERMISSIONS || permissionGranted,
                            onClick = onAdvance,
                            modifier =
                                if (compact) Modifier.weight(1f) else Modifier.width(220.dp),
                        )
                    // DISCOVER advances by tapping a found camera — no primary.
                    else -> {}
                }
            }
        }
    }
}

// MARK: - Step bodies

@Composable
private fun BusyBody(phase: PairingPhase) {
    Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
        Text(
            if (phase == PairingPhase.Joining) {
                stringResource(R.string.pairing_busy_joining)
            } else {
                stringResource(R.string.pairing_busy_connecting)
            },
            color = StartupColors.ink,
            fontSize = 15.sp,
            fontWeight = FontWeight.SemiBold,
        )
        Text(
            if (phase == PairingPhase.Joining) {
                stringResource(R.string.pairing_busy_joining_detail)
            } else {
                stringResource(R.string.pairing_busy_connecting_detail)
            },
            color = StartupColors.muted,
            fontSize = 12.sp,
            lineHeight = 17.sp,
        )
        StartupIndeterminateBar()
    }
}

@Composable
private fun PermissionsBody(granted: Boolean, denied: Boolean, onRequest: () -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Column(
            Modifier.fillMaxWidth()
                .startupInstructionCard()
                .clickable(enabled = !granted, onClick = onRequest)
                .padding(horizontal = 16.dp, vertical = 13.dp)
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text(
                        stringResource(PairingCopy.permissionTitle),
                        color = StartupColors.ink,
                        fontSize = 15.sp,
                        fontWeight = FontWeight.SemiBold,
                    )
                    Spacer(Modifier.height(2.dp))
                    Text(
                        stringResource(PairingCopy.permissionDetail),
                        color = StartupColors.muted,
                        fontSize = 12.sp,
                        lineHeight = 16.sp,
                    )
                }
                Spacer(Modifier.width(8.dp))
                when {
                    granted -> StatusPill(stringResource(R.string.status_allowed), StartupColors.ready)
                    denied -> StatusPill(stringResource(R.string.status_settings), StartupColors.muted)
                    else ->
                        Text(
                            stringResource(R.string.action_allow),
                            color = StartupColors.darkText,
                            fontSize = 14.sp,
                            fontWeight = FontWeight.SemiBold,
                            modifier =
                                Modifier.clip(CircleShape)
                                    .background(StartupColors.accent)
                                    .padding(horizontal = 14.dp, vertical = 8.dp),
                        )
                }
            }
        }
        if (!granted) {
            Text(
                stringResource(R.string.pairing_permission_required),
                color = StartupColors.dim,
                fontSize = 11.sp,
            )
        }
    }
}

@Composable
private fun StatusPill(text: String, color: androidx.compose.ui.graphics.Color) {
    Text(
        text,
        color = color,
        fontSize = 12.sp,
        fontWeight = FontWeight.SemiBold,
        modifier =
            Modifier.border(1.dp, color.copy(alpha = 0.5f), CircleShape)
                .padding(horizontal = 12.dp, vertical = 6.dp),
    )
}

@Composable
private fun ChoosePathBody(
    onChoose: (PairingPath) -> Unit,
    compact: Boolean,
    condensed: Boolean,
) {
    // Tight vertical budget: all three cards must clear the card fold without
    // scrolling on the ~180dp step body of a 720px-tall landscape panel. On a
    // narrow portrait viewport they stack inside the body's existing scroll.
    if (compact) {
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            for (path in PairingPath.entries) {
                PathChoiceCard(path, onChoose, Modifier.fillMaxWidth(), condensed = false)
            }
        }
    } else {
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            for (path in PairingPath.entries) {
                PathChoiceCard(path, onChoose, Modifier.weight(1f), condensed = condensed)
            }
        }
    }
}

@Composable
private fun PathChoiceCard(
    path: PairingPath,
    onChoose: (PairingPath) -> Unit,
    modifier: Modifier,
    condensed: Boolean,
) {
    Column(
        modifier
            .startupTile()
            .clickable { onChoose(path) }
            .padding(horizontal = 12.dp, vertical = if (condensed) 8.dp else 10.dp)
    ) {
        Text(
            stringResource(PairingCopy.pathTitle(path)),
            color = StartupColors.ink,
            fontSize = if (condensed) 14.sp else 15.sp,
            fontWeight = FontWeight.Bold,
            lineHeight = if (condensed) 17.sp else 18.sp,
        )
        Spacer(Modifier.height(if (condensed) 5.dp else 6.dp))
        Text(
            stringResource(PairingCopy.pathBadge(path)),
            color = StartupColors.accent,
            fontSize = if (condensed) 11.sp else 12.sp,
            fontWeight = FontWeight.SemiBold,
            modifier =
                Modifier.clip(CircleShape)
                    .background(StartupColors.accent.copy(alpha = 0.15f))
                    .padding(horizontal = if (condensed) 8.dp else 9.dp, vertical = if (condensed) 2.dp else 3.dp),
        )
        Spacer(Modifier.height(if (condensed) 5.dp else 7.dp))
        if (condensed) {
            Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                TradeoffRow(
                    "+",
                    StartupColors.ready,
                    stringResource(PairingCopy.compactPathPro(path)),
                    compact = true,
                )
                TradeoffRow(
                    "−",
                    StartupColors.dim,
                    stringResource(PairingCopy.compactPathCon(path)),
                    compact = true,
                )
            }
        } else {
            Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
                for (pro in PairingCopy.pathPros(path)) {
                    TradeoffRow("+", StartupColors.ready, stringResource(pro))
                }
                TradeoffRow("−", StartupColors.dim, stringResource(PairingCopy.pathCon(path)))
            }
        }
    }
}

@Composable
private fun TradeoffRow(
    symbol: String,
    color: androidx.compose.ui.graphics.Color,
    text: String,
    compact: Boolean = false,
) {
    Row(horizontalArrangement = Arrangement.spacedBy(7.dp)) {
        Text(
            symbol,
            color = color,
            fontSize = if (compact) 11.sp else 12.sp,
            fontWeight = FontWeight.Bold,
        )
        Text(
            text,
            color = StartupColors.muted,
            fontSize = if (compact) 11.sp else 12.sp,
            lineHeight = if (compact) 14.sp else 16.sp,
        )
    }
}

/** Numbered instruction cards (iOS `StartupWizardPrepareCards`). */
@Composable
private fun NumberedCards(steps: List<String>) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        steps.forEachIndexed { index, step ->
            Row(
                Modifier.fillMaxWidth()
                    .startupInstructionCard()
                    .padding(horizontal = 12.dp, vertical = 9.dp),
                horizontalArrangement = Arrangement.spacedBy(10.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Box(
                    Modifier.size(24.dp)
                        .clip(RoundedCornerShape(8.dp))
                        .background(StartupColors.accent.copy(alpha = 0.12f))
                        .border(
                            1.dp,
                            StartupColors.accent.copy(alpha = 0.45f),
                            RoundedCornerShape(8.dp),
                        ),
                    contentAlignment = Alignment.Center,
                ) {
                    Text(
                        stringResource(R.string.step_number, index + 1),
                        color = StartupColors.accent,
                        fontSize = 12.sp,
                        fontWeight = FontWeight.Bold,
                    )
                }
                Text(
                    step,
                    color = StartupColors.ink,
                    fontSize = 14.sp,
                    fontWeight = FontWeight.Medium,
                    lineHeight = 18.sp,
                    modifier = Modifier.weight(1f),
                )
            }
        }
    }
}

@Composable
private fun NetworkBody(
    path: PairingPath,
    ssidField: String,
    onSsidChange: (String) -> Unit,
    keyField: String,
    onKeyChange: (String) -> Unit,
    keyCameFromScanner: Boolean,
    keyWasRemembered: Boolean,
    onScanCameraWifi: () -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(
            stringResource(PairingCopy.networkSubtitle(path, keyRemembered = keyWasRemembered)),
            color = StartupColors.muted,
            fontSize = 13.sp,
            lineHeight = 18.sp,
        )
        // Camera-AP: the subtitle already tells the operator where the SSID and
        // key are — the entry fields must sit above the scroll fold, so no
        // camera instruction card here (iOS "tight" mode collapses it too).
        if (path == PairingPath.PHONE_HOTSPOT) {
            DeviceInstructionCard(
                label = stringResource(R.string.pairing_on_camera),
                steps = PairingCopy.hotspotCameraSteps.map { stringResource(it) },
            )
        }
        if (path == PairingPath.CAMERA_ACCESS_POINT) {
            Column(
                Modifier.fillMaxWidth()
                    .startupInstructionCard()
                    .padding(horizontal = 12.dp, vertical = 10.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Text(
                    stringResource(R.string.pairing_on_phone),
                    color = StartupColors.muted,
                    fontSize = 10.sp,
                    fontWeight = FontWeight.Bold,
                    letterSpacing = 1.2.sp,
                )
                if (keyCameFromScanner) {
                    ScannedCameraWifiCredentials(
                        ssid = ssidField,
                        key = keyField,
                        onRescan = onScanCameraWifi,
                    )
                } else {
                    StartupTextField(
                        value = ssidField,
                        onValueChange = onSsidChange,
                        placeholder =
                            stringResource(
                                R.string.pairing_network_ssid_hint,
                                CameraDiscovery.NIKON_ZR_SSID_PREFIX,
                            ),
                    )
                    StartupTextField(
                        value = keyField,
                        onValueChange = onKeyChange,
                        placeholder = stringResource(R.string.pairing_network_key_hint),
                        password = true,
                    )
                    StartupOutlineButton(
                        text = stringResource(R.string.pairing_scan_ssid_key),
                        onClick = onScanCameraWifi,
                        modifier = Modifier.fillMaxWidth(),
                    )
                    Text(
                        stringResource(R.string.pairing_scanner_privacy),
                        color = StartupColors.dim,
                        fontSize = 11.sp,
                        lineHeight = 15.sp,
                    )
                }
            }
        }
    }
}

/** Reviewed scanner result, held only until the operator explicitly joins the camera AP. */
@Composable
private fun ScannedCameraWifiCredentials(
    ssid: String,
    key: String,
    onRescan: () -> Unit,
) {
    val keyDescription = stringResource(R.string.pairing_scanned_key_description)
    Text(
        stringResource(R.string.pairing_scanned_check),
        color = StartupColors.ready,
        fontSize = 10.sp,
        fontWeight = FontWeight.Bold,
        letterSpacing = 1.1.sp,
    )
    Text(
        ssid,
        color = StartupColors.ink,
        fontSize = 14.sp,
        fontWeight = FontWeight.SemiBold,
        modifier =
            Modifier.fillMaxWidth()
                .clip(RoundedCornerShape(14.dp))
                .background(StartupColors.control)
                .padding(horizontal = 13.dp, vertical = 10.dp),
    )
    Text(
        key,
        color = StartupColors.ink,
        fontSize = 14.sp,
        fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace,
        modifier =
            Modifier.fillMaxWidth()
                .clip(RoundedCornerShape(14.dp))
                .background(StartupColors.control)
                .padding(horizontal = 13.dp, vertical = 10.dp)
                .clearAndSetSemantics {
                    contentDescription = keyDescription
                },
    )
    StartupOutlineButton(
        text = stringResource(R.string.pairing_rescan_ssid_key),
        onClick = onRescan,
        modifier = Modifier.fillMaxWidth(),
    )
}

/** Device-labelled numbered instruction card (iOS `StartupWizardDeviceInstructionCard`). */
@Composable
private fun DeviceInstructionCard(label: String, steps: List<String>) {
    Column(
        Modifier.fillMaxWidth()
            .startupInstructionCard()
            .padding(horizontal = 12.dp, vertical = 8.dp),
        verticalArrangement = Arrangement.spacedBy(3.dp),
    ) {
        Text(
            label,
            color = StartupColors.muted,
            fontSize = 10.sp,
            fontWeight = FontWeight.Bold,
            letterSpacing = 1.2.sp,
        )
        steps.forEachIndexed { index, step ->
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(
                    stringResource(R.string.step_number, index + 1),
                    color = StartupColors.muted,
                    fontSize = 10.sp,
                    fontWeight = FontWeight.Bold,
                    modifier = Modifier.width(14.dp),
                )
                Text(
                    step,
                    color = StartupColors.ink,
                    fontSize = 12.sp,
                    fontWeight = FontWeight.Medium,
                    lineHeight = 16.sp,
                )
            }
        }
    }
}

@Composable
private fun DiscoverBody(
    path: PairingPath,
    cameras: List<DiscoveredCamera>,
    usbCameras: List<UsbPtpCamera>,
    onConnectCamera: (DiscoveredCamera) -> Unit,
    onConnectUsbCamera: (UsbPtpCamera) -> Unit,
) {
    if (path == PairingPath.USB_C) {
        UsbDiscoverBody(usbCameras, onConnectUsbCamera)
        return
    }
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        if (cameras.isEmpty()) {
            Column(
                Modifier.fillMaxWidth()
                    .startupInstructionCard()
                    .padding(horizontal = 12.dp, vertical = 14.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                Text(
                    stringResource(R.string.pairing_waiting_hotspot),
                    color = StartupColors.ink,
                    fontSize = 13.sp,
                    fontWeight = FontWeight.SemiBold,
                )
                Text(
                    stringResource(R.string.pairing_waiting_hotspot_detail),
                    color = StartupColors.muted,
                    fontSize = 11.sp,
                )
            }
            StartupIndeterminateBar()
        } else {
            for (camera in cameras) {
                Row(
                    Modifier.fillMaxWidth()
                        .startupTile(borderColor = StartupColors.ready.copy(alpha = 0.28f))
                        .clickable { onConnectCamera(camera) }
                        .padding(horizontal = 14.dp, vertical = 12.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Column(Modifier.weight(1f)) {
                        Text(
                            camera.name,
                            color = StartupColors.ink,
                            fontSize = 14.sp,
                            fontWeight = FontWeight.SemiBold,
                        )
                        Text(
                            stringResource(R.string.pairing_wifi_nearby),
                            color = StartupColors.muted,
                            fontSize = 11.sp,
                        )
                    }
                    Text(
                        stringResource(R.string.action_connect),
                        color = StartupColors.darkText,
                        fontSize = 13.sp,
                        fontWeight = FontWeight.SemiBold,
                        modifier =
                            Modifier.clip(RoundedCornerShape(16.dp))
                                .background(StartupColors.accent)
                                .padding(horizontal = 14.dp, vertical = 8.dp),
                    )
                }
            }
        }
    }
}

@Composable
private fun UsbDiscoverBody(
    cameras: List<UsbPtpCamera>,
    onConnectCamera: (UsbPtpCamera) -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        if (cameras.isEmpty()) {
            Column(
                Modifier.fillMaxWidth()
                    .startupInstructionCard()
                    .padding(horizontal = 12.dp, vertical = 14.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                Text(
                    stringResource(R.string.pairing_waiting_usb),
                    color = StartupColors.ink,
                    fontSize = 13.sp,
                    fontWeight = FontWeight.SemiBold,
                )
                Text(
                    stringResource(R.string.pairing_waiting_usb_detail),
                    color = StartupColors.muted,
                    fontSize = 11.sp,
                )
            }
            StartupIndeterminateBar()
        } else {
            cameras.forEach { camera ->
                val actionable =
                    camera.access == UsbPtpCameraAccess.READY ||
                        camera.access == UsbPtpCameraAccess.NEEDS_PERMISSION ||
                        camera.access == UsbPtpCameraAccess.DENIED
                Row(
                    Modifier.fillMaxWidth()
                        .startupTile(borderColor = StartupColors.ready.copy(alpha = 0.28f))
                        .clickable(enabled = actionable) { onConnectCamera(camera) }
                        .padding(horizontal = 14.dp, vertical = 12.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Column(Modifier.weight(1f)) {
                        Text(
                            camera.displayName,
                            color = StartupColors.ink,
                            fontSize = 14.sp,
                            fontWeight = FontWeight.SemiBold,
                        )
                        if (camera.isDebugFixture) {
                            Text(
                                USB_DEBUG_FIXTURE_LABEL,
                                color = StartupColors.accent,
                                fontSize = 9.sp,
                                fontWeight = FontWeight.Bold,
                                letterSpacing = 0.8.sp,
                            )
                        }
                        Text(
                            if (camera.isDebugFixture) {
                                usbCameraDebugDetail(camera.access)
                            } else {
                                stringResource(usbCameraDetailResource(camera.access))
                            },
                            color = StartupColors.muted,
                            fontSize = 11.sp,
                        )
                    }
                    Text(
                        stringResource(usbCameraActionResource(camera.access)),
                        color = if (actionable) StartupColors.darkText else StartupColors.muted,
                        fontSize = 13.sp,
                        fontWeight = FontWeight.SemiBold,
                        modifier =
                            Modifier.clip(RoundedCornerShape(16.dp))
                                .background(
                                    if (actionable) {
                                        StartupColors.accent
                                    } else {
                                        StartupColors.control
                                    },
                                )
                                .padding(horizontal = 14.dp, vertical = 8.dp),
                    )
                }
            }
        }
    }
}

internal const val USB_DEBUG_FIXTURE_LABEL: String = "DEBUG FIXTURE — NOT USB HARDWARE"

@StringRes
internal fun usbCameraDetailResource(
    access: UsbPtpCameraAccess,
): Int =
    when (access) {
        UsbPtpCameraAccess.NEEDS_PERMISSION -> R.string.pairing_usb_permission
        UsbPtpCameraAccess.READY -> R.string.pairing_usb_ready
        UsbPtpCameraAccess.DENIED -> R.string.pairing_usb_denied
        UsbPtpCameraAccess.IDENTITY_UNAVAILABLE -> R.string.pairing_usb_identity
    }

internal fun usbCameraDebugDetail(access: UsbPtpCameraAccess): String =
    when (access) {
        UsbPtpCameraAccess.NEEDS_PERMISSION -> "SIMULATED · permission needed"
        UsbPtpCameraAccess.READY -> "SIMULATED · ready"
        UsbPtpCameraAccess.DENIED -> "SIMULATED · access denied"
        UsbPtpCameraAccess.IDENTITY_UNAVAILABLE -> "SIMULATED · no stable identity"
    }

@StringRes
private fun usbCameraActionResource(access: UsbPtpCameraAccess): Int =
    when (access) {
        UsbPtpCameraAccess.NEEDS_PERMISSION -> R.string.action_allow
        UsbPtpCameraAccess.READY -> R.string.action_connect
        UsbPtpCameraAccess.DENIED -> R.string.action_allow
        UsbPtpCameraAccess.IDENTITY_UNAVAILABLE -> R.string.status_unavailable
    }

// MARK: - Controls

@Composable
internal fun StartupFilledButton(
    text: String,
    enabled: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Box(
        modifier
            .height(40.dp)
            .clip(RoundedCornerShape(16.dp))
            .background(
                if (enabled) StartupColors.accent else StartupColors.control.copy(alpha = 0.6f)
            )
            .clickable(enabled = enabled, onClick = onClick)
            .alpha(if (enabled) 1f else 0.55f),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            text,
            color = if (enabled) StartupColors.darkText else StartupColors.muted,
            fontSize = 14.sp,
            fontWeight = FontWeight.SemiBold,
            maxLines = 1,
        )
    }
}

@Composable
internal fun StartupOutlineButton(text: String, onClick: () -> Unit, modifier: Modifier = Modifier) {
    Box(
        modifier
            .height(40.dp)
            .clip(RoundedCornerShape(16.dp))
            .background(StartupColors.control.copy(alpha = 0.82f))
            .border(1.dp, StartupColors.border.copy(alpha = 0.12f), RoundedCornerShape(16.dp))
            .clickable(onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            text,
            color = StartupColors.ink,
            fontSize = 14.sp,
            fontWeight = FontWeight.SemiBold,
            maxLines = 1,
        )
    }
}

/** Single-line field in the startup control style; never logs its contents. */
@Composable
private fun StartupTextField(
    value: String,
    onValueChange: (String) -> Unit,
    placeholder: String,
    password: Boolean = false,
) {
    BasicTextField(
        value = value,
        onValueChange = onValueChange,
        singleLine = true,
        textStyle =
            TextStyle(
                color = StartupColors.ink,
                fontSize = 15.sp,
                fontWeight = FontWeight.Medium,
            ),
        cursorBrush = SolidColor(StartupColors.accent),
        visualTransformation =
            if (password) PasswordVisualTransformation() else VisualTransformation.None,
        decorationBox = { innerTextField ->
            Box(
                Modifier.fillMaxWidth()
                    .height(42.dp)
                    .clip(RoundedCornerShape(16.dp))
                    .background(StartupColors.control)
                    .border(
                        1.dp,
                        StartupColors.border.copy(alpha = 0.12f),
                        RoundedCornerShape(16.dp),
                    )
                    .padding(horizontal = 13.dp),
                contentAlignment = Alignment.CenterStart,
            ) {
                if (value.isEmpty()) {
                    Text(placeholder, color = StartupColors.dim, fontSize = 14.sp)
                }
                innerTextField()
            }
        },
    )
}

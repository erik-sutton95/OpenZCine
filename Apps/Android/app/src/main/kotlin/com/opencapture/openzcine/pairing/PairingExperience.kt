package com.opencapture.openzcine.pairing

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.net.nsd.NsdManager
import android.os.Build
import android.provider.Settings
import android.util.Log
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
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.fillMaxHeight
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
import androidx.compose.foundation.text.BasicText
import androidx.compose.foundation.text.TextAutoSize
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalResources
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.opencapture.openzcine.R
import com.opencapture.openzcine.bridge.PtpIpConnectionStrategy
import com.opencapture.openzcine.bridge.PtpIpInitiatorIdentity
import com.opencapture.openzcine.bridge.SwiftCoreCameraSession
import com.opencapture.openzcine.core.CameraConnectionPhase
import com.opencapture.openzcine.core.CameraConnectionProgress
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
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull

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
    /** Builds a saved-camera session that may recover a rejected legacy profile by pairing. */
    public val createSession: (host: String) -> CameraSession,
    /** Builds a strict saved-profile session after Nikon has accepted a pairing request. */
    public val createSavedProfileSession: (host: String) -> CameraSession = createSession,
    /** Builds a session that starts directly in Nikon's first-time pairing path. */
    public val createFirstTimePairingSession: (host: String) -> CameraSession = createSession,
    /** Android USB Host discovery and raw-byte ownership, when the device supports it. */
    public val usbCameraSource: UsbPtpCameraSource?,
    /** Builds a USB-C saved-camera session that may restore then pair as needed. */
    public val createUsbSession: (UsbPtpOpenResult.Opened) -> CameraSession,
    /** Builds a strict saved-profile USB-C session after Nikon pairing is confirmed. */
    public val createSavedProfileUsbSession: (UsbPtpOpenResult.Opened) -> CameraSession =
        createUsbSession,
    /** Builds a USB-C session that may restore a profile before first-time pairing. */
    public val createFirstTimePairingUsbSession: (UsbPtpOpenResult.Opened) -> CameraSession =
        createUsbSession,
    /** Remembered camera-AP credentials. */
    public val credentials: PairingCredentials,
    /**
     * Waits for the current camera AP to leave and return after first-time
     * pairing. Non-camera-AP environments use the default and retry their
     * discovered profile endpoint.
     */
    public val awaitCameraApRestart: suspend (timeoutMillis: Long) -> Boolean = { true },
)

/**
 * Production [PairingEnvironment] over the real platform services.
 *
 * [hasLegacySavedCameraProfiles] is true only while upgrading an installation
 * that already has Android camera records from the former shared initiator
 * GUID. It lets that one install retain those camera-side profiles; new
 * installs always receive a fresh private identity.
 *
 * [phaseLogger] receives progress and failure phases. Callers must discard or
 * privately handle the detail value rather than placing it in an anonymous
 * report. Safe phases are also written to logcat.
 */
public fun realPairingEnvironment(
    context: Context,
    hasLegacySavedCameraProfiles: Boolean = false,
    phaseLogger: (String, String) -> Unit = { _, _ -> },
): PairingEnvironment {
    val joiner = CameraApJoiner(context)
    val discovery =
        CameraDiscovery(AndroidNsdBrowser(context.getSystemService(NsdManager::class.java)))
    val usbCameraSource = AndroidUsbPtpCameraSource(context)
    val initiatorGuid =
        PtpIpInitiatorIdentity(context).guid(
            preferLegacyStaticIdentity = hasLegacySavedCameraProfiles,
        )
    val combinedPhaseLogger: (String, String) -> Unit = { phase, detail ->
        logCameraSessionPhase(phase, detail)
        phaseLogger(phase, detail)
    }
    return PairingEnvironment(
        joinCameraAp = { ssid, passphrase -> joiner.join(ssid, passphrase) },
        releaseCameraAp = joiner::release,
        hotspotCameras = discovery.cameras(),
        createSession = { host ->
            SwiftCoreCameraSession(
                host = host,
                connectionStrategy = PtpIpConnectionStrategy.RESTORE_PROFILE_THEN_PAIRING,
                initiatorGuid = initiatorGuid,
                phaseLogger = combinedPhaseLogger,
            )
        },
        createSavedProfileSession = { host ->
            SwiftCoreCameraSession(
                host = host,
                connectionStrategy = PtpIpConnectionStrategy.SAVED_PROFILE,
                initiatorGuid = initiatorGuid,
                phaseLogger = combinedPhaseLogger,
            )
        },
        createFirstTimePairingSession = { host ->
            SwiftCoreCameraSession(
                host = host,
                connectionStrategy = PtpIpConnectionStrategy.FIRST_TIME_PAIRING,
                initiatorGuid = initiatorGuid,
                phaseLogger = combinedPhaseLogger,
            )
        },
        usbCameraSource = usbCameraSource,
        createUsbSession = { opened ->
            SwiftCoreCameraSession(
                host = opened.hostKey,
                cameraNameHint = opened.displayName,
                usbTransport = opened.transport,
                connectionStrategy = PtpIpConnectionStrategy.RESTORE_PROFILE_THEN_PAIRING,
                phaseLogger = combinedPhaseLogger,
            )
        },
        createSavedProfileUsbSession = { opened ->
            SwiftCoreCameraSession(
                host = opened.hostKey,
                cameraNameHint = opened.displayName,
                usbTransport = opened.transport,
                connectionStrategy = PtpIpConnectionStrategy.SAVED_PROFILE,
                phaseLogger = combinedPhaseLogger,
            )
        },
        createFirstTimePairingUsbSession = { opened ->
            SwiftCoreCameraSession(
                host = opened.hostKey,
                cameraNameHint = opened.displayName,
                usbTransport = opened.transport,
                connectionStrategy = PtpIpConnectionStrategy.RESTORE_PROFILE_THEN_PAIRING,
                phaseLogger = combinedPhaseLogger,
            )
        },
        credentials = CameraWifiCredentialStore(context),
        awaitCameraApRestart = joiner::awaitReassociation,
    )
}

/** Emits only safe connection failures to logcat, never pairing-phase details. */
private fun logCameraSessionPhase(phase: String, detail: String) {
    val message = cameraSessionDiagnosticMessage(phase, detail) ?: return
    Log.w(CAMERA_SESSION_LOG_TAG, message)
}

private const val CAMERA_SESSION_LOG_TAG = "SwiftCoreCameraSession"

/** Returns only diagnostics whose phase cannot carry the camera pairing credential. */
internal fun cameraSessionDiagnosticMessage(phase: String, detail: String): String? =
    when (phase) {
        "failed", "eventChannelEnded", "eventChannelCleanupFailed" -> "$phase: $detail"
        else -> null
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
    /** Stages the connect popup: `ready`, `joining`, or `failed` (iOS ZC_DEMO_JOIN_POPUP). */
    val joinPopup: String? = null,
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

/** Whether Camera (the credential scanner's permission) is already granted. */
public fun isCameraPermissionGranted(context: Context): Boolean =
    context.checkSelfPermission(Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED

/** Whether every permission the wizard's permissions step lists is granted. */
public fun arePairingPermissionsGranted(context: Context): Boolean =
    isPairingPermissionGranted(context) && isCameraPermissionGranted(context)

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
            PairingPath.USB_C -> R.string.pairing_badge_most_stable
        }

    fun pathPros(path: PairingPath): List<Int> =
        when (path) {
            PairingPath.CAMERA_ACCESS_POINT ->
                listOf(R.string.pairing_pro_light_battery, R.string.pairing_pro_no_phone_setup)
            PairingPath.PHONE_HOTSPOT ->
                listOf(R.string.pairing_pro_wireless_quality, R.string.pairing_pro_stable_high_settings)
            PairingPath.USB_C ->
                listOf(R.string.pairing_pro_usb_stable, R.string.pairing_pro_usb_no_radio)
        }

    @StringRes
    fun pathCon(path: PairingPath): Int =
        when (path) {
            PairingPath.CAMERA_ACCESS_POINT -> R.string.pairing_con_softer_link
            PairingPath.PHONE_HOTSPOT -> R.string.pairing_con_battery_drain
            PairingPath.USB_C -> R.string.pairing_con_usb_tethered
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
    fun networkSubtitle(path: PairingPath): Int =
        when (path) {
            PairingPath.CAMERA_ACCESS_POINT -> R.string.pairing_network_ap
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

    /** Credentials staged in the connect popup, waiting for the operator's Connect. */
    data class ReadyToJoin(val ssid: String, val key: String?, val keyFromScan: Boolean) :
        PairingPhase

    data object Joining : PairingPhase

    data object Handshaking : PairingPhase

    data class Pairing(val pin: String?) : PairingPhase

    data class ConfirmOnCamera(val pin: String?) : PairingPhase

    data object Reconnecting : PairingPhase

    data class Error(val message: String) : PairingPhase
}

/** Maps the shared-core lifecycle without treating a PTP-IP handshake as pairing. */
private fun pairingPhaseFor(progress: CameraConnectionProgress): PairingPhase? =
    when (progress.phase) {
        CameraConnectionPhase.HANDSHAKING -> PairingPhase.Handshaking
        CameraConnectionPhase.PAIRING -> PairingPhase.Pairing(progress.detail.ifBlank { null })
        CameraConnectionPhase.CONFIRM_ON_CAMERA -> PairingPhase.ConfirmOnCamera(
            progress.detail.ifBlank { null },
        )
        else -> null
    }

internal const val FIRST_PAIR_CAMERA_AP_RESTART_TIMEOUT_MILLIS: Long = 60_000L
internal const val FIRST_PAIR_RECONNECT_TIMEOUT_MILLIS: Long = 60_000L
internal const val FIRST_PAIR_RECONNECT_INTERVAL_MILLIS: Long = 2_000L
internal const val FIRST_PAIR_HOTSPOT_SETTLE_MILLIS: Long = 2_000L

/**
 * Pause after a successful camera-AP join before the first PTP-IP Init.
 * Device logs show `rejectedInitiator` ~30ms after association when we race
 * the camera's stack; iOS waits for subnet confirmation and a similar settle.
 */
internal const val CAMERA_AP_POST_JOIN_SETTLE_MILLIS: Long = 1_200L

/** How many PTP-IP establish attempts after a camera-AP rejoin. */
internal const val CAMERA_AP_CONNECT_ATTEMPTS: Int = 3

internal const val CAMERA_AP_CONNECT_RETRY_DELAY_MILLIS: Long = 1_500L

/** How often the USB discover step re-enumerates while waiting for a camera. */
internal const val USB_DISCOVER_POLL_INTERVAL_MILLIS: Long = 1_500L

private fun PairingPhase.isBusy(): Boolean =
    this !is PairingPhase.Idle && this !is PairingPhase.Error

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
    onPairingProfilePrepared: (SavedCameraRecord) -> Unit = {},
    onOpenSettings: (() -> Unit)? = null,
    onShowSavedCameras: (() -> Unit)? = null,
) {
    val context = LocalContext.current
    val resources = LocalResources.current
    var permissionGranted by remember { mutableStateOf(isPairingPermissionGranted(context)) }
    var permissionDenied by remember { mutableStateOf(false) }
    var cameraPermissionGranted by remember {
        mutableStateOf(isCameraPermissionGranted(context))
    }
    var cameraPermissionDenied by remember { mutableStateOf(false) }
    var flow by remember {
        mutableStateOf(
            script?.start ?: PairingFlowState.initial(arePairingPermissionsGranted(context))
        )
    }
    var phase by remember { mutableStateOf<PairingPhase>(PairingPhase.Idle) }
    // The SSID actually joined this run — recorded on the saved profile so a
    // reconnect can rejoin the same camera AP.
    var joinedSsid by remember { mutableStateOf<String?>(null) }
    // Device title for the connect popup (SSID while joining, camera name after).
    var connectingName by remember { mutableStateOf<String?>(null) }
    var cameraWifiScannerPresented by remember { mutableStateOf(false) }
    var cameras by remember { mutableStateOf(emptyList<DiscoveredCamera>()) }
    var usbCameras by remember { mutableStateOf(emptyList<UsbPtpCamera>()) }
    val scope = rememberCoroutineScope()
    val work = remember { mutableStateOf<Job?>(null) }
    val handedOff = remember { mutableStateOf(false) }

    DisposableEffect(environment) {
        onDispose {
            work.value?.cancel()
            if (!handedOff.value) environment.releaseCameraAp()
        }
    }

    fun reconnectHost(record: SavedCameraRecord): String =
        if (record.transport == SavedCameraTransport.PHONE_HOTSPOT) {
            cameras.firstOrNull { camera ->
                camera.host == record.host ||
                    SavedCameraRecords.cameraNamesMatch(camera.name, record.cameraName)
            }?.host ?: record.host
        } else {
            record.host
        }

    fun createSavedProfileReconnectSession(record: SavedCameraRecord): CameraSession? =
        when (record.transport) {
            SavedCameraTransport.CAMERA_ACCESS_POINT,
            SavedCameraTransport.PHONE_HOTSPOT,
            -> environment.createSavedProfileSession(reconnectHost(record))
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

    suspend fun reconnectAfterFirstPair(
        savedCamera: SavedCameraRecord,
        confirmPin: String? = null,
    ): PairedCamera? {
        val isCameraAp = savedCamera.transport == SavedCameraTransport.CAMERA_ACCESS_POINT
        // Stay on "Tap Confirm on the camera" while the body restarts its AP —
        // do not flip to Reconnecting until the network is back (or the wait
        // times out and we start active rejoin attempts).
        phase = PairingPhase.ConfirmOnCamera(confirmPin)
        if (isCameraAp) {
            // Prefer reassociation of the still-bound join (loss → return when
            // the operator taps Confirm). Fall through to active rejoin loops
            // if the wait times out or the binding was already released.
            environment.awaitCameraApRestart(FIRST_PAIR_CAMERA_AP_RESTART_TIMEOUT_MILLIS)
        } else {
            // Hotspot/USB: short settle after body-side confirmation.
            delay(FIRST_PAIR_HOTSPOT_SETTLE_MILLIS)
        }
        // iOS keeps re-applying the camera AP configuration while the just-paired
        // camera reboots its Wi-Fi (attemptPairedReconnectRejoin), then reconnects
        // off the saved profile the moment it returns — staying armed until a
        // connect succeeds. Android's WifiNetworkSpecifier does NOT auto-rejoin a
        // rebooted AP if the binding was dropped, so each pass re-issues the
        // join before attempting the saved-profile connect. Re-joining a
        // session-approved SSID is silent on API 31+.
        val rejoinSsid = savedCamera.wifiSsid?.takeIf { isCameraAp && it.isNotBlank() }
        val rejoinKey = rejoinSsid?.let(environment.credentials::passphrase)

        return withTimeoutOrNull<PairedCamera>(FIRST_PAIR_RECONNECT_TIMEOUT_MILLIS) {
            var reconnected: PairedCamera? = null
            while (reconnected == null) {
                phase = PairingPhase.Reconnecting
                if (rejoinSsid != null && !environment.joinCameraAp(rejoinSsid, rejoinKey)) {
                    // The rebooted AP hasn't returned yet; wait and re-apply.
                    delay(FIRST_PAIR_RECONNECT_INTERVAL_MILLIS)
                    continue
                }
                val session = createSavedProfileReconnectSession(savedCamera)
                if (session != null) {
                    var handedOffSession = false
                    try {
                        session.connect()
                        val connected = session.state.value as? CameraSessionState.Connected
                        if (connected != null) {
                            handedOffSession = true
                            reconnected = PairedCamera(
                                session = session,
                                savedCamera =
                                    savedCamera.copy(
                                        host = reconnectHost(savedCamera),
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

    fun connect(
        session: CameraSession,
        savedCamera: SavedCameraRecord,
        unreachableMessage: String,
        firstTimePairing: Boolean,
    ) {
        phase = PairingPhase.Handshaking
        work.value =
            scope.launch {
                // Latch confirm-on-camera outside StateFlow "latest only" — a
                // fast FAILED after confirmOnCamera used to overwrite the phase
                // before the collector ran, so we never entered the wait path.
                var confirmation: PairingPhase.ConfirmOnCamera? = null
                var sawPairingChallenge = false
                val progressWatcher =
                    launch(start = CoroutineStart.UNDISPATCHED) {
                        session.connectionProgress.collect { progress ->
                            when (progress.phase) {
                                CameraConnectionPhase.PAIRING -> {
                                    sawPairingChallenge = true
                                    phase = PairingPhase.Pairing(progress.detail.ifBlank { null })
                                }
                                CameraConnectionPhase.CONFIRM_ON_CAMERA -> {
                                    val confirmed =
                                        PairingPhase.ConfirmOnCamera(
                                            progress.detail.ifBlank { null },
                                        )
                                    confirmation = confirmed
                                    phase = confirmed
                                }
                                CameraConnectionPhase.HANDSHAKING ->
                                    phase = PairingPhase.Handshaking
                                else -> Unit
                            }
                        }
                    }
                try {
                    session.connect()
                    val connected = session.state.value as? CameraSessionState.Connected
                    // USB-C pairs in-session over the cable — there is no
                    // Wi-Fi-restart / confirm-on-body step (matches iOS, which
                    // uses the USB session directly). Only the Wi-Fi paths run
                    // the shutdown → reconnect dance, which re-applies the
                    // camera AP SSID a USB camera does not have.
                    val pairingConfirmed =
                        confirmation.takeIf {
                            savedCamera.transport != SavedCameraTransport.USB_C
                        }
                    // If StateFlow collapsed confirmOnCamera → FAILED, still
                    // treat a first-time Wi-Fi pair that reached the pairing
                    // challenge as body-confirm pending (iOS acceptedPairing).
                    val treatAsPairedAwaitingBody =
                        pairingConfirmed != null ||
                            (
                                firstTimePairing &&
                                    sawPairingChallenge &&
                                    savedCamera.transport != SavedCameraTransport.USB_C
                            )
                    if (firstTimePairing && treatAsPairedAwaitingBody) {
                        // Nikon has accepted `ConfirmPairing`, but this is still
                        // not a usable monitor session. Persist the profile,
                        // close the temporary session, then wait for the body
                        // confirmation/restart and reconnect through that profile.
                        val preparedProfile =
                            savedCamera.copy(
                                cameraName = connected?.identity?.name ?: savedCamera.cameraName,
                                lastSeenAtEpochMillis = System.currentTimeMillis(),
                            )
                        onPairingProfilePrepared(preparedProfile)
                        val pin = pairingConfirmed?.pin
                        phase = PairingPhase.ConfirmOnCamera(pin)
                        withContext(NonCancellable) { session.disconnect() }
                        val reconnected =
                            reconnectAfterFirstPair(preparedProfile, confirmPin = pin)
                        if (reconnected != null) {
                            handedOff.value = true
                            onPaired(reconnected)
                        } else {
                            phase =
                                PairingPhase.Error(
                                    friendlyCameraConnectionFailure(unreachableMessage),
                                )
                        }
                    } else if (connected != null) {
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
                        val detail = session.connectionProgress.value.detail
                        phase =
                            PairingPhase.Error(
                                friendlyCameraConnectionFailure(
                                    detail.takeIf { it.isNotBlank() } ?: unreachableMessage,
                                ),
                            )
                    }
                } catch (error: CancellationException) {
                    // `sessionConnect` begins native work asynchronously. A
                    // cancelled wizard must tear that work down before a retry
                    // can claim the process-wide PTP slot.
                    withContext(NonCancellable) { session.disconnect() }
                    throw error
                } catch (_: Exception) {
                    withContext(NonCancellable) { session.disconnect() }
                    phase =
                        PairingPhase.Error(friendlyCameraConnectionFailure(unreachableMessage))
                } finally {
                    progressWatcher.cancel()
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
        val discoveredName = cameras.firstOrNull { it.host == host }?.name
        if (discoveredName != null) connectingName = discoveredName
        connect(
            session = environment.createFirstTimePairingSession(host),
            savedCamera =
                SavedCameraRecord(
                    host = host,
                    cameraName =
                        discoveredName ?: resources.getString(R.string.pairing_default_camera_name),
                    transport = transport,
                    lastSeenAtEpochMillis = null,
                    wifiSsid =
                        if (transport == SavedCameraTransport.CAMERA_ACCESS_POINT) {
                            joinedSsid
                        } else {
                            null
                        },
                ),
            unreachableMessage = resources.getString(R.string.pairing_error_camera_unreachable),
            firstTimePairing = true,
        )
    }

    fun connectUsb(camera: UsbPtpCamera) {
        val source = environment.usbCameraSource
        if (source == null) {
            phase = PairingPhase.Error(resources.getString(R.string.pairing_error_usb_unsupported))
            return
        }
        connectingName = camera.displayName
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
                                environment.createFirstTimePairingUsbSession(opened)
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
                            firstTimePairing = true,
                        )
                    }
                    is UsbPtpOpenResult.Rejected -> phase = PairingPhase.Error(opened.message)
                }
        }
    }

    fun joinCameraAp(ssid: String, passphrase: String?) {
        if (ssid.isBlank()) return
        joinedSsid = ssid
        connectingName = ssid
        phase = PairingPhase.Joining
        work.value =
            scope.launch {
                val joined = environment.joinCameraAp(ssid, passphrase)
                if (joined) {
                    // The encrypted store is the only place a confirmed key
                    // lives; the popup's plaintext staging dies with the phase.
                    if (passphrase != null) environment.credentials.save(ssid, passphrase)
                    environment.credentials.lastSsid = ssid
                    // Association can finish before the camera answers PTP-IP
                    // Init; match the saved-reconnect settle before handshaking.
                    delay(CAMERA_AP_POST_JOIN_SETTLE_MILLIS)
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

    /**
     * The network step's single action (iOS "Connect my camera"): the first-pair
     * wizard ALWAYS opens the scanner — scanning is the only credential path
     * here, exactly like iOS's `advanceFirstPairWizard` →
     * `presentCameraWiFiScanner`. Remembered keys shortcut only saved-camera
     * reconnects, never a fresh pairing.
     */
    fun connectMyCamera() {
        cameraWifiScannerPresented = true
    }

    fun cancelWork() {
        work.value?.cancel()
        work.value = null
        if (flow.path == PairingPath.CAMERA_ACCESS_POINT) environment.releaseCameraAp()
        connectingName = null
        phase = PairingPhase.Idle
    }

    fun retreat() {
        phase = PairingPhase.Idle
        flow = flow.retreat()
    }

    // Permission launchers + re-check on return from Settings.
    val permissionLauncher =
        rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
            permissionGranted = granted
            permissionDenied = !granted
        }
    val cameraPermissionLauncher =
        rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
            cameraPermissionGranted = granted
            cameraPermissionDenied = !granted
        }
    fun openAppSettings() {
        context.startActivity(
            Intent(
                Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                Uri.fromParts("package", context.packageName, null),
            )
        )
    }
    fun requestPairingPermission() {
        if (permissionDenied) {
            openAppSettings()
        } else {
            permissionLauncher.launch(requiredPairingPermission())
        }
    }
    fun requestCameraPermission() {
        if (cameraPermissionDenied) {
            openAppSettings()
        } else {
            cameraPermissionLauncher.launch(Manifest.permission.CAMERA)
        }
    }
    val lifecycleOwner = LocalLifecycleOwner.current
    DisposableEffect(lifecycleOwner) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_RESUME) {
                permissionGranted = isPairingPermissionGranted(context)
                cameraPermissionGranted = isCameraPermissionGranted(context)
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
                    // Poll deviceList while waiting: Samsung/OEM devices don't
                    // reliably deliver ACTION_USB_DEVICE_ATTACHED to a runtime
                    // receiver, so a camera plugged in on this step would never
                    // reach the flow otherwise.
                    launch {
                        while (isActive) {
                            source.refresh()
                            delay(USB_DISCOVER_POLL_INTERVAL_MILLIS)
                        }
                    }
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
    if (script?.joinPopup != null) {
        LaunchedEffect(script) {
            connectingName = "NIKON_ZR_01234"
            phase =
                when (script.joinPopup) {
                    "joining" -> PairingPhase.Joining
                    "failed" ->
                        PairingPhase.Error(resources.getString(R.string.pairing_error_wifi_join))
                    else ->
                        PairingPhase.ReadyToJoin("NIKON_ZR_01234", "a1b2c3d4", keyFromScan = true)
                }
        }
    }

    val busy = phase.isBusy()
    // iOS keeps the wizard's status pill amber "Looking" for the whole first
    // pair (discovery runs behind it); connect phases render in the popup, so
    // the pill only switches wording while one is active.
    val statusTitle =
        when {
            phase == PairingPhase.Joining -> stringResource(R.string.pairing_status_joining)
            phase == PairingPhase.Handshaking -> stringResource(R.string.pairing_status_connecting)
            phase is PairingPhase.Pairing -> stringResource(R.string.pairing_status_pairing)
            phase is PairingPhase.ConfirmOnCamera ->
                stringResource(R.string.pairing_status_confirm_on_camera)
            phase == PairingPhase.Reconnecting -> stringResource(R.string.pairing_status_reconnecting)
            else -> stringResource(R.string.pairing_status_looking)
        }

    Box(Modifier.fillMaxSize().startupBackdrop()) {
        Column(
            Modifier.fillMaxSize()
                .windowInsetsPadding(WindowInsets.safeDrawing)
                .padding(horizontal = 24.dp, vertical = 10.dp)
        ) {
            // No Settings entry during first pairing — iOS keeps it on the
            // saved-cameras home only.
            StartupHeader(
                title = stringResource(R.string.pairing_connection_setup),
                statusTitle = statusTitle,
                isBusy = true,
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
                        148.dp
                    } else {
                        maxOf(236.dp, viewportWidth * 0.28f)
                    }
                if (twoColumn) {
                    val compactThreshold =
                        if (flow.step == PairingStep.CHOOSE_PATH) 500.dp else 400.dp
                    val compactStep = viewportWidth - introWidth - 16.dp < compactThreshold
                    val condensedIntro = flow.step == PairingStep.CHOOSE_PATH && !compactStep
                    Row(horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                        IntroCard(
                            flow = flow,
                            condensed = condensedIntro,
                            onShowSavedCameras = onShowSavedCameras,
                            modifier = Modifier.width(introWidth).fillMaxSize(),
                        )
                        StepCard(
                            flow = flow,
                            permissionGranted = permissionGranted,
                            permissionDenied = permissionDenied,
                            cameraPermissionGranted = cameraPermissionGranted,
                            cameraPermissionDenied = cameraPermissionDenied,
                            cameras = cameras,
                            usbCameras = usbCameras,
                            onRequestPermission = ::requestPairingPermission,
                            onRequestCameraPermission = ::requestCameraPermission,
                            onChoose = { flow = flow.choose(it) },
                            onAdvance = { flow = flow.advance() },
                            onRetreat = ::retreat,
                            onConnectMyCamera = ::connectMyCamera,
                            onConnectCamera = { connect(it.host) },
                            onConnectUsbCamera = ::connectUsb,
                            compact = compactStep,
                            tightChrome = true,
                            modifier = Modifier.weight(1f).fillMaxSize(),
                        )
                    }
                } else {
                    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                        // iOS portrait stacks the first-run hero above the
                        // progress bar on every step.
                        PortraitIntroHeader(
                            flow = flow,
                            onShowSavedCameras = onShowSavedCameras,
                        )
                        StartupWizardProgress(
                            currentStep = flow.displayStepNumber,
                            totalSteps = flow.stepCount,
                        )
                        StepCard(
                            flow = flow,
                            permissionGranted = permissionGranted,
                            permissionDenied = permissionDenied,
                            cameraPermissionGranted = cameraPermissionGranted,
                            cameraPermissionDenied = cameraPermissionDenied,
                            cameras = cameras,
                            usbCameras = usbCameras,
                            onRequestPermission = ::requestPairingPermission,
                            onRequestCameraPermission = ::requestCameraPermission,
                            onChoose = { flow = flow.choose(it) },
                            onAdvance = { flow = flow.advance() },
                            onRetreat = ::retreat,
                            onConnectMyCamera = ::connectMyCamera,
                            onConnectCamera = { connect(it.host) },
                            onConnectUsbCamera = ::connectUsb,
                            compact = viewportWidth < 480.dp,
                            modifier = Modifier.weight(1f).fillMaxWidth(),
                        )
                    }
                }
            }
        }
        val popupPhase =
            when (val active = phase) {
                PairingPhase.Idle -> null
                is PairingPhase.ReadyToJoin ->
                    ConnectionPopupPhase.ReadyToJoin(active.key, active.keyFromScan)
                PairingPhase.Joining -> ConnectionPopupPhase.JoiningWifi
                PairingPhase.Handshaking -> ConnectionPopupPhase.Handshaking
                is PairingPhase.Pairing -> ConnectionPopupPhase.Pairing
                is PairingPhase.ConfirmOnCamera ->
                    ConnectionPopupPhase.ConfirmOnCamera(active.pin)
                PairingPhase.Reconnecting -> ConnectionPopupPhase.Reconnecting
                is PairingPhase.Error -> ConnectionPopupPhase.Failed(active.message)
            }
        popupPhase?.let { popup ->
            ConnectionProgressPopup(
                deviceName = connectionDisplayName(connectingName),
                phase = popup,
                onConnect = {
                    (phase as? PairingPhase.ReadyToJoin)?.let { staged ->
                        joinCameraAp(staged.ssid, staged.key)
                    }
                },
                onDismiss = ::cancelWork,
            )
        }
        if (cameraWifiScannerPresented) {
            CameraWifiScannerOverlay(
                onConfirmed = { candidate ->
                    // The scanner has already been reviewed by the operator;
                    // this stages the connect popup's Connect action. No
                    // credential is persisted until a successful join.
                    cameraWifiScannerPresented = false
                    connectingName = candidate.ssid
                    phase =
                        PairingPhase.ReadyToJoin(
                            candidate.ssid,
                            candidate.key,
                            keyFromScan = true,
                        )
                },
                onDismiss = { cameraWifiScannerPresented = false },
            )
        }
    }
}

// MARK: - Left column

/**
 * The stacked first-run hero above the progress bar in single-column layouts —
 * iOS `portraitIntroHeader`: eyebrow, title, walkthrough line, per-step helper.
 */
@Composable
private fun PortraitIntroHeader(
    flow: PairingFlowState,
    onShowSavedCameras: (() -> Unit)?,
) {
    // Sizes mirror iOS's compactPortrait profile (StartupDesign.swift
    // `portraitIntroHeader`): 11pt eyebrow / 22pt title / 12pt body / 11pt helper.
    Column {
        Row(verticalAlignment = Alignment.Top) {
            Column(Modifier.weight(1f)) {
                Text(
                    stringResource(R.string.pairing_first_run),
                    color = StartupColors.muted,
                    fontSize = 11.sp,
                    fontWeight = FontWeight.SemiBold,
                    letterSpacing = 1.4.sp,
                )
                Spacer(Modifier.height(4.dp))
                Text(
                    stringResource(R.string.pairing_intro_title),
                    color = StartupColors.ink,
                    fontSize = 22.sp,
                    fontWeight = FontWeight.Bold,
                    lineHeight = 25.sp,
                )
            }
            onShowSavedCameras?.let { showSavedCameras ->
                Spacer(Modifier.width(12.dp))
                StartupOutlineButton(
                    text = stringResource(R.string.saved_your_cameras),
                    onClick = showSavedCameras,
                    leadingChevron = true,
                )
            }
        }
        Spacer(Modifier.height(6.dp))
        Text(
            stringResource(R.string.pairing_intro_full),
            color = StartupColors.muted,
            fontSize = 12.sp,
            lineHeight = 16.sp,
        )
        Spacer(Modifier.height(6.dp))
        Text(
            stringResource(PairingCopy.introFooter(flow.step)),
            color = StartupColors.dim,
            fontSize = 11.sp,
            lineHeight = 15.sp,
        )
    }
}

@Composable
private fun IntroCard(
    flow: PairingFlowState,
    condensed: Boolean = false,
    onShowSavedCameras: (() -> Unit)? = null,
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
        onShowSavedCameras?.let { showSavedCameras ->
            Spacer(Modifier.height(if (condensed) 6.dp else 8.dp))
            StartupOutlineButton(
                text = stringResource(R.string.saved_your_cameras),
                onClick = showSavedCameras,
                leadingChevron = true,
                modifier = Modifier.fillMaxWidth(),
            )
        }
    }
}

// MARK: - Right column

@Composable
private fun StepCard(
    flow: PairingFlowState,
    permissionGranted: Boolean,
    permissionDenied: Boolean,
    cameraPermissionGranted: Boolean,
    cameraPermissionDenied: Boolean,
    cameras: List<DiscoveredCamera>,
    usbCameras: List<UsbPtpCamera>,
    onRequestPermission: () -> Unit,
    onRequestCameraPermission: () -> Unit,
    onChoose: (PairingPath) -> Unit,
    onAdvance: () -> Unit,
    onRetreat: () -> Unit,
    onConnectMyCamera: () -> Unit,
    onConnectCamera: (DiscoveredCamera) -> Unit,
    onConnectUsbCamera: (UsbPtpCamera) -> Unit,
    compact: Boolean,
    tightChrome: Boolean = false,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier.startupCard().padding(
            horizontal = if (tightChrome) 16.dp else 20.dp,
            vertical = if (tightChrome) 14.dp else 20.dp,
        )
    ) {
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

        val bodyScroll = rememberScrollState()
        Column(Modifier.weight(1f).fadeOverflowBottom(bodyScroll).verticalScroll(bodyScroll)) {
            when (flow.step) {
                PairingStep.PERMISSIONS ->
                    PermissionsBody(
                        nearbyGranted = permissionGranted,
                        nearbyDenied = permissionDenied,
                        cameraGranted = cameraPermissionGranted,
                        cameraDenied = cameraPermissionDenied,
                        onRequestNearby = onRequestPermission,
                        onRequestCamera = onRequestCameraPermission,
                    )
                PairingStep.CHOOSE_PATH ->
                    ChoosePathBody(onChoose = onChoose, compact = compact)
                PairingStep.PREPARE ->
                    NumberedCards(PairingCopy.prepareSteps(flow.path).map { stringResource(it) })
                PairingStep.NETWORK -> NetworkBody(path = flow.path)
                PairingStep.DISCOVER ->
                    DiscoverBody(
                        path = flow.path,
                        cameras = cameras,
                        usbCameras = usbCameras,
                        onConnectCamera = onConnectCamera,
                        onConnectUsbCamera = onConnectUsbCamera,
                    )
            }
        }

        // Footer nav — mirrors iOS: none on the choose step (tapping a card
        // advances); Back + primary elsewhere. Connect phases render in the
        // shared popup, never in this card.
        if (flow.step != PairingStep.CHOOSE_PATH) {
            Spacer(Modifier.height(12.dp))
            Row(
                Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                if (flow.canRetreat) {
                    StartupOutlineButton(
                        stringResource(R.string.action_back),
                        onClick = onRetreat,
                        leadingChevron = true,
                        modifier = Modifier.width(116.dp),
                    )
                }
                if (!compact) Spacer(Modifier.weight(1f))
                when {
                    flow.step == PairingStep.NETWORK ->
                        StartupFilledButton(
                            stringResource(R.string.pairing_connect_my_camera),
                            enabled = true,
                            onClick =
                                if (flow.path == PairingPath.CAMERA_ACCESS_POINT) {
                                    onConnectMyCamera
                                } else {
                                    onAdvance
                                },
                            modifier =
                                if (compact) Modifier.weight(1f) else Modifier.width(220.dp),
                        )
                    !flow.isFinalStep ->
                        StartupFilledButton(
                            stringResource(R.string.action_continue),
                            enabled =
                                flow.step != PairingStep.PERMISSIONS ||
                                    (permissionGranted && cameraPermissionGranted),
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
private fun PermissionsBody(
    nearbyGranted: Boolean,
    nearbyDenied: Boolean,
    cameraGranted: Boolean,
    cameraDenied: Boolean,
    onRequestNearby: () -> Unit,
    onRequestCamera: () -> Unit,
) {
    // Structure and sizes mirror iOS `StartupWizardPermissionsStep` in the
    // compactPortrait profile: 10pt group label, 30pt icon circles at 14%
    // accent, 13pt titles / 11pt details, inset hairline divider.
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Column(Modifier.fillMaxWidth().startupInstructionCard()) {
            Row(
                Modifier.padding(start = 12.dp, end = 12.dp, top = 10.dp, bottom = 6.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                StartupGlyph(
                    StartupGlyphKind.SHIELD,
                    tint = StartupColors.accent,
                    modifier = Modifier.size(13.dp),
                )
                Text(
                    stringResource(R.string.pairing_permissions_group),
                    color = StartupColors.muted,
                    fontSize = 10.sp,
                    fontWeight = FontWeight.SemiBold,
                )
            }
            PermissionRow(
                glyph = StartupGlyphKind.CAMERA,
                title = stringResource(R.string.pairing_permission_camera),
                detail = stringResource(R.string.pairing_permission_camera_detail),
                granted = cameraGranted,
                denied = cameraDenied,
                onRequest = onRequestCamera,
            )
            Box(
                Modifier.fillMaxWidth()
                    .padding(start = 42.dp)
                    .height(1.dp)
                    .background(StartupColors.border.copy(alpha = 0.10f))
            )
            PermissionRow(
                glyph = StartupGlyphKind.WIFI,
                title = stringResource(PairingCopy.permissionTitle),
                detail = stringResource(PairingCopy.permissionDetail),
                granted = nearbyGranted,
                denied = nearbyDenied,
                onRequest = onRequestNearby,
            )
        }
        if (!nearbyGranted || !cameraGranted) {
            Text(
                stringResource(R.string.pairing_permission_required),
                color = StartupColors.dim,
                fontSize = 11.sp,
                lineHeight = 15.sp,
            )
        }
    }
}

@Composable
private fun PermissionRow(
    glyph: StartupGlyphKind,
    title: String,
    detail: String,
    granted: Boolean,
    denied: Boolean,
    onRequest: () -> Unit,
) {
    Row(
        Modifier.fillMaxWidth()
            .clickable(enabled = !granted, onClick = onRequest)
            .padding(horizontal = 14.dp, vertical = 11.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Box(
            Modifier.size(30.dp)
                .background(StartupColors.accent.copy(alpha = 0.14f), CircleShape),
            contentAlignment = Alignment.Center,
        ) {
            StartupGlyph(glyph, tint = StartupColors.accent, modifier = Modifier.size(15.dp))
        }
        Column(Modifier.weight(1f)) {
            Text(
                title,
                color = StartupColors.ink,
                fontSize = 13.sp,
                fontWeight = FontWeight.SemiBold,
            )
            Spacer(Modifier.height(2.dp))
            Text(
                detail,
                color = StartupColors.muted,
                fontSize = 11.sp,
                lineHeight = 15.sp,
            )
        }
        when {
            granted ->
                PermissionStatusPill(
                    text = stringResource(R.string.status_allowed),
                    glyph = "✓",
                    fill = StartupColors.ready.copy(alpha = 0.16f),
                    stroke = StartupColors.ready.copy(alpha = 0.5f),
                    textColor = StartupColors.ready,
                )
            denied ->
                PermissionStatusPill(
                    text = stringResource(R.string.status_settings),
                    glyph = null,
                    fill = StartupColors.control.copy(alpha = 0.6f),
                    stroke = StartupColors.border.copy(alpha = 0.12f),
                    textColor = StartupColors.muted,
                )
            else ->
                PermissionStatusPill(
                    text = stringResource(R.string.action_allow),
                    glyph = null,
                    fill = StartupColors.accent,
                    stroke = androidx.compose.ui.graphics.Color.Transparent,
                    textColor = StartupColors.darkText,
                )
        }
    }
}

@Composable
private fun PermissionStatusPill(
    text: String,
    glyph: String?,
    fill: androidx.compose.ui.graphics.Color,
    stroke: androidx.compose.ui.graphics.Color,
    textColor: androidx.compose.ui.graphics.Color,
) {
    Row(
        Modifier.clip(CircleShape)
            .background(fill)
            .border(1.dp, stroke, CircleShape)
            .padding(horizontal = 14.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(5.dp),
    ) {
        if (glyph != null) {
            Text(glyph, color = textColor, fontSize = 11.sp, fontWeight = FontWeight.Bold)
        }
        Text(text, color = textColor, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
    }
}

@Composable
private fun ChoosePathBody(
    onChoose: (PairingPath) -> Unit,
    compact: Boolean,
) {
    // iOS `transportCards`: portrait stacks the full cards inside the step
    // body's scroll; landscape puts the same three cards side by side with
    // wrapping copy — there is no condensed variant.
    if (compact) {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            for (path in PairingPath.entries) {
                PathChoiceCard(path, onChoose, Modifier.fillMaxWidth())
            }
        }
    } else {
        Row(
            Modifier.height(IntrinsicSize.Max),
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            for (path in PairingPath.entries) {
                PathChoiceCard(
                    path,
                    onChoose,
                    Modifier.weight(1f).fillMaxHeight(),
                    tight = true,
                )
            }
        }
    }
}

/**
 * One transport option (iOS `StartupWizardTransportCard`, 14pt padding / 34pt
 * tile). [tight] trims the vertical chrome for the landscape band — Android
 * phones are ~30dp shorter there than the iPhone the fixed iOS metrics fit.
 */
@Composable
private fun PathChoiceCard(
    path: PairingPath,
    onChoose: (PairingPath) -> Unit,
    modifier: Modifier,
    tight: Boolean = false,
) {
    Column(
        modifier
            .startupTile()
            .clickable { onChoose(path) }
            .padding(horizontal = 14.dp, vertical = if (tight) 8.dp else 14.dp)
    ) {
        Box(
            Modifier.size(if (tight) 26.dp else 34.dp)
                .clip(RoundedCornerShape(9.dp))
                .background(StartupColors.accent.copy(alpha = 0.12f)),
            contentAlignment = Alignment.Center,
        ) {
            StartupGlyph(
                kind =
                    when (path) {
                        PairingPath.CAMERA_ACCESS_POINT -> StartupGlyphKind.ANTENNA
                        PairingPath.PHONE_HOTSPOT -> StartupGlyphKind.PHONE_WAVES
                        PairingPath.USB_C -> StartupGlyphKind.CABLE
                    },
                tint = StartupColors.accent,
                modifier = Modifier.size(if (tight) 15.dp else 19.dp),
            )
        }
        Spacer(Modifier.height(if (tight) 5.dp else 10.dp))
        if (tight) {
            // One auto-shrinking line in the landscape band (iOS shrinks via
            // minimumScaleFactor; a wrapped title is what overflows here).
            BasicText(
                stringResource(PairingCopy.pathTitle(path)),
                style =
                    TextStyle(
                        color = StartupColors.ink,
                        fontWeight = FontWeight.Bold,
                    ),
                maxLines = 1,
                autoSize = TextAutoSize.StepBased(11.sp, 15.sp, 0.5.sp),
            )
        } else {
            Text(
                stringResource(PairingCopy.pathTitle(path)),
                color = StartupColors.ink,
                fontSize = 15.sp,
                fontWeight = FontWeight.Bold,
                lineHeight = 18.sp,
                maxLines = 2,
            )
        }
        Spacer(Modifier.height(if (tight) 4.dp else 8.dp))
        Text(
            stringResource(PairingCopy.pathBadge(path)),
            color = StartupColors.accent,
            fontSize = 12.sp,
            fontWeight = FontWeight.SemiBold,
            modifier =
                Modifier.clip(CircleShape)
                    .background(StartupColors.accent.copy(alpha = 0.15f))
                    .padding(horizontal = 9.dp, vertical = if (tight) 2.dp else 4.dp),
        )
        Spacer(Modifier.height(if (tight) 4.dp else 10.dp))
        Column(verticalArrangement = Arrangement.spacedBy(if (tight) 2.dp else 6.dp)) {
            for (pro in PairingCopy.pathPros(path)) {
                TradeoffRow("+", StartupColors.ready, stringResource(pro), tight = tight)
            }
            TradeoffRow(
                "−",
                StartupColors.dim,
                stringResource(PairingCopy.pathCon(path)),
                tight = tight,
            )
        }
    }
}

@Composable
private fun TradeoffRow(
    symbol: String,
    color: androidx.compose.ui.graphics.Color,
    text: String,
    tight: Boolean = false,
) {
    Row(horizontalArrangement = Arrangement.spacedBy(7.dp)) {
        Text(
            symbol,
            color = color,
            fontSize = if (tight) 11.sp else 12.sp,
            fontWeight = FontWeight.Bold,
            modifier = Modifier.width(12.dp),
        )
        Text(
            text,
            color = StartupColors.muted,
            fontSize = if (tight) 11.sp else 12.sp,
            lineHeight = if (tight) 14.sp else 16.sp,
            modifier = Modifier.weight(1f),
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

/**
 * The network step is instruction-only on every path (iOS
 * `StartupWizardNetworkStep`): the camera-AP flow is scanner-first — the
 * "Connect my camera" primary opens the scanner, never a typed credential form.
 */
@Composable
private fun NetworkBody(path: PairingPath) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(
            stringResource(PairingCopy.networkSubtitle(path)),
            color = StartupColors.muted,
            fontSize = 13.sp,
            lineHeight = 18.sp,
        )
        when (path) {
            PairingPath.CAMERA_ACCESS_POINT -> {
                DeviceInstructionCard(
                    glyph = StartupGlyphKind.APERTURE,
                    label = stringResource(R.string.pairing_on_camera),
                    steps = listOf(stringResource(R.string.pairing_network_ap_camera_1)),
                )
                DeviceInstructionCard(
                    glyph = StartupGlyphKind.PHONE,
                    label = stringResource(R.string.pairing_on_phone),
                    steps = listOf(stringResource(R.string.pairing_network_ap_phone_1)),
                )
            }
            PairingPath.PHONE_HOTSPOT ->
                DeviceInstructionCard(
                    glyph = StartupGlyphKind.APERTURE,
                    label = stringResource(R.string.pairing_on_camera),
                    steps = PairingCopy.hotspotCameraSteps.map { stringResource(it) },
                )
            PairingPath.USB_C -> {
                DeviceInstructionCard(
                    glyph = StartupGlyphKind.APERTURE,
                    label = stringResource(R.string.pairing_on_camera),
                    steps =
                        listOf(
                            stringResource(R.string.pairing_network_usb_camera_1),
                            stringResource(R.string.pairing_network_usb_camera_2),
                        ),
                )
                DeviceInstructionCard(
                    glyph = StartupGlyphKind.PHONE,
                    label = stringResource(R.string.pairing_on_phone),
                    steps = listOf(stringResource(R.string.pairing_network_usb_phone_1)),
                )
            }
        }
    }
}

/** Device-labelled numbered instruction card (iOS `StartupWizardDeviceInstructionCard`). */
@Composable
private fun DeviceInstructionCard(
    glyph: StartupGlyphKind,
    label: String,
    steps: List<String>,
) {
    Column(
        Modifier.fillMaxWidth()
            .startupInstructionCard()
            .padding(horizontal = 14.dp, vertical = 11.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            StartupGlyph(glyph, tint = StartupColors.accent, modifier = Modifier.size(16.dp))
            Text(
                label,
                color = StartupColors.ink,
                fontSize = 14.sp,
                fontWeight = FontWeight.SemiBold,
            )
        }
        steps.forEachIndexed { index, step ->
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(
                    stringResource(R.string.step_number, index + 1),
                    color = StartupColors.muted,
                    fontSize = 11.sp,
                    fontWeight = FontWeight.Bold,
                    modifier = Modifier.width(14.dp),
                )
                Text(
                    step,
                    color = StartupColors.ink,
                    fontSize = 13.sp,
                    fontWeight = FontWeight.Medium,
                    lineHeight = 17.sp,
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
            EmptyDiscoveryCard(
                glyph = StartupGlyphKind.ANTENNA,
                title = stringResource(R.string.pairing_looking_for_cameras),
                detail = stringResource(R.string.pairing_waiting_hotspot_detail),
            )
        } else {
            for (camera in cameras) {
                Row(
                    Modifier.fillMaxWidth()
                        .startupTile(borderColor = StartupColors.ready.copy(alpha = 0.28f))
                        .clickable { onConnectCamera(camera) }
                        .padding(horizontal = 14.dp, vertical = 12.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    StartupGlyph(
                        StartupGlyphKind.CAMERA,
                        tint = StartupColors.accent,
                        modifier = Modifier.size(20.dp),
                    )
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
            EmptyDiscoveryCard(
                glyph = StartupGlyphKind.CABLE,
                title = stringResource(R.string.pairing_waiting_usb),
                detail = stringResource(R.string.pairing_waiting_usb_detail),
            )
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

/** Centered icon + copy card while discovery waits (iOS `StartupEmptyDiscoveryCard`). */
@Composable
private fun EmptyDiscoveryCard(glyph: StartupGlyphKind, title: String, detail: String) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Column(
            Modifier.fillMaxWidth()
                .startupInstructionCard()
                .padding(horizontal = 12.dp, vertical = 16.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            StartupGlyph(glyph, tint = StartupColors.accent, modifier = Modifier.size(26.dp))
            Text(
                title,
                color = StartupColors.ink,
                fontSize = 14.sp,
                fontWeight = FontWeight.SemiBold,
            )
            Text(
                detail,
                color = StartupColors.muted,
                fontSize = 12.sp,
                lineHeight = 16.sp,
            )
        }
        StartupIndeterminateBar()
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
internal fun StartupOutlineButton(
    text: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    leadingChevron: Boolean = false,
    enabled: Boolean = true,
) {
    Row(
        modifier
            .height(40.dp)
            .clip(RoundedCornerShape(16.dp))
            .background(StartupColors.control.copy(alpha = if (enabled) 0.82f else 0.55f))
            .border(1.dp, StartupColors.border.copy(alpha = 0.12f), RoundedCornerShape(16.dp))
            .clickable(enabled = enabled, onClick = onClick)
            .alpha(if (enabled) 1f else 0.55f)
            .padding(horizontal = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.Center,
    ) {
        if (leadingChevron) {
            StartupGlyph(
                StartupGlyphKind.CHEVRON_LEFT,
                tint = StartupColors.ink,
                modifier = Modifier.size(13.dp),
            )
            Spacer(Modifier.width(5.dp))
        }
        // Auto-shrinks instead of clipping: the wizard's landscape intro column
        // narrows to 148dp on the choose step, and large system font scales
        // can outgrow any fixed width.
        BasicText(
            text,
            style =
                TextStyle(
                    color = StartupColors.ink,
                    fontWeight = FontWeight.SemiBold,
                ),
            maxLines = 1,
            autoSize = TextAutoSize.StepBased(10.sp, 14.sp, 0.5.sp),
        )
    }
}

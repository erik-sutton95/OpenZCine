package com.opencapture.openzcine.pairing

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.net.nsd.NsdManager
import android.os.Build
import android.util.Log
import androidx.annotation.StringRes
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.LocalTextStyle
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalResources
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.opencapture.opencine.nikon.NikonTakeOverPrompt
import com.opencapture.monitorui.MonitorPairingCheck
import com.opencapture.monitorui.MonitorPairingCheckState
import com.opencapture.monitorui.MonitorPairingDevice
import com.opencapture.monitorui.MonitorPairingInstruction
import com.opencapture.monitorui.MonitorPairingInstructionIcon
import com.opencapture.monitorui.MonitorPairingPresentation
import com.opencapture.monitorui.MonitorPairingStep
import com.opencapture.monitorui.MonitorPalette
import com.opencapture.monitorui.MonitorTypography
import com.opencapture.opencine.appkit.CamerasModel
import com.opencapture.opencine.appkit.DiscoveryPermissions
import com.opencapture.opencine.appkit.PermissionGate
import com.opencapture.opencine.appkit.IntegrationPairingFlow
import com.opencapture.opencine.appkit.PairScreen
import com.opencapture.opencine.appkit.pairPageFrame
import com.opencapture.openzcine.R
import com.opencapture.opencine.nikon.PtpIpConnectionStrategy
import com.opencapture.opencine.nikon.PtpIpInitiatorIdentity
import com.opencapture.opencine.nikon.SwiftCoreCameraSession
import com.opencapture.opencine.nikon.CameraConnectionPhase
import com.opencapture.opencine.nikon.CameraSession
import com.opencapture.opencine.nikon.CameraSessionState
import com.opencapture.openzcine.hasExternalUvcCamera
import com.opencapture.openzcine.transport.AndroidNsdBrowser
import com.opencapture.openzcine.transport.AndroidUsbPtpCameraSource
import com.opencapture.openzcine.transport.CameraDiscovery
import com.opencapture.openzcine.transport.DiscoveredCamera
import com.opencapture.openzcine.transport.InfrastructureCameraFinder
import com.opencapture.openzcine.transport.operatorCopy
import com.opencapture.opencine.nikon.InfrastructureMissReason
import com.opencapture.opencine.nikon.NikonCameraAp
import com.opencapture.openzcine.transport.InfrastructureSearchReport
import com.opencapture.openzcine.transport.UsbPtpCamera
import com.opencapture.openzcine.transport.UsbPtpCameraAccess
import com.opencapture.openzcine.transport.UsbPtpCameraSource
import com.opencapture.opencine.nikon.UsbPtpOpenResult
import com.opencapture.opencine.nikon.UsbPtpTransportReopener
import com.opencapture.openzcine.transport.reopenReadyUsbTransport
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.filterNotNull
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import com.opencapture.monitorui.MonitorIcon
import com.opencapture.opencine.nikon.SavedCameraRecord
import com.opencapture.opencine.nikon.SavedCameraTransport

/** Saved camera-AP credential surface the wizard needs (real: [CameraWifiCredentialStore]). */
public interface PairingCredentials {
    /** Last camera SSID the operator joined — prefills the wizard's SSID field. */
    public var lastSsid: String?

    /** The remembered Wi-Fi key for [ssid], or null when none is stored. */
    public fun passphrase(ssid: String): String?

    /** Remembers [passphrase] for [ssid]. */
    public fun save(ssid: String, passphrase: String)

    /**
     * Forgets the key for [ssid] — a forgotten camera-AP setup must not leave its credential on
     * the phone (iOS `clearCameraWiFiCredential(forForgottenSSID:)`). Defaulted because the demo
     * harnesses implementing this interface hold nothing durable to forget.
     */
    public fun remove(ssid: String) {}
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
    /**
     * One Wi‑Fi-path search pass: patient directed dials, then an occupancy sweep of the subnets
     * this device stands in, and a typed reason when it finds nothing (Wi‑Fi path only).
     *
     * mDNS alone cannot carry this path. A body waiting on its Connect-to-computer screen
     * announces nothing, so before this seam a camera on a Wi‑Fi network Android had never paired
     * with simply could not be found — the same camera and network that worked on iPhone.
     */
    public val searchInfrastructure:
        suspend (directed: List<String>, knownNames: Map<String, String>) -> InfrastructureSearchReport =
        { directed, knownNames ->
            InfrastructureCameraFinder()
                .search(directedCandidates = directed, knownNames = knownNames)
        },
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
    /**
     * True while the process is still bound to the camera AP (after a successful
     * reassociation). Defaults to false so demo harnesses never skip a join.
     */
    public val isCameraApProcessBound: () -> Boolean = { false },
    /**
     * Joins the camera AP unless already process-bound. Production uses
     * [NikonCameraAp.ensureJoined]; demos may just call [joinCameraAp].
     */
    public val ensureCameraApJoined: suspend (ssid: String, passphrase: String?, timeoutMillis: Int) -> Boolean =
        { ssid, passphrase, _ -> joinCameraAp(ssid, passphrase) },
    /**
     * Warms Wi‑Fi scan results for [ssid] before Connect (Ready-to-join card).
     * No-op in demo harnesses.
     */
    public val primeCameraApScan: (ssid: String) -> Unit = {},
)

/**
 * Production [PairingEnvironment] over the real platform services.
 *
 * [phaseLogger] receives progress and failure phases. Callers must discard or
 * privately handle the detail value rather than placing it in a shared
 * report. Safe phases are also written to logcat.
 */
public fun realPairingEnvironment(
    context: Context,
    phaseLogger: (String, String) -> Unit = { _, _ -> },
): PairingEnvironment {
    val joiner = NikonCameraAp.joiner(context)
    val discovery =
        CameraDiscovery(AndroidNsdBrowser(context.getSystemService(NsdManager::class.java)))
    val initiatorGuid = PtpIpInitiatorIdentity.guid
    val combinedPhaseLogger: (String, String) -> Unit = { phase, detail ->
        logCameraSessionPhase(phase, detail)
        phaseLogger(phase, detail)
    }
    // Enumeration facts reach the EXPORTED report, not just logcat: a field report is a file an
    // operator can send, and logcat needs a cable to a laptop. The detail is deliberately empty —
    // the phase token carries everything, and nothing identifying crosses this seam.
    val usbCameraSource =
        AndroidUsbPtpCameraSource(
            context,
            onDiagnosticPhase = { phase -> combinedPhaseLogger(phase, "") },
        )
    return PairingEnvironment(
        // NikonCameraAp.join owns pre-scan + fail-fast retries + the Nikon model prefix.
        joinCameraAp = { ssid, passphrase -> NikonCameraAp.join(joiner, ssid, passphrase) },
        releaseCameraAp = joiner::release,
        primeCameraApScan = { joiner.primeScan() },
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
            usbCameraSession(
                opened = opened,
                source = usbCameraSource,
                connectionStrategy = PtpIpConnectionStrategy.RESTORE_PROFILE_THEN_PAIRING,
                phaseLogger = combinedPhaseLogger,
            )
        },
        createSavedProfileUsbSession = { opened ->
            usbCameraSession(
                opened = opened,
                source = usbCameraSource,
                connectionStrategy = PtpIpConnectionStrategy.SAVED_PROFILE,
                phaseLogger = combinedPhaseLogger,
            )
        },
        createFirstTimePairingUsbSession = { opened ->
            usbCameraSession(
                opened = opened,
                source = usbCameraSource,
                connectionStrategy = PtpIpConnectionStrategy.RESTORE_PROFILE_THEN_PAIRING,
                phaseLogger = combinedPhaseLogger,
            )
        },
        credentials = CameraWifiCredentialStore(context),
        awaitCameraApRestart = joiner::awaitReassociation,
        isCameraApProcessBound = joiner::isProcessBound,
        ensureCameraApJoined = { ssid, passphrase, timeoutMillis ->
            NikonCameraAp.ensureJoined(joiner, ssid, passphrase, timeoutMillis)
        },
    )
}

private fun usbCameraSession(
    opened: UsbPtpOpenResult.Opened,
    source: UsbPtpCameraSource,
    connectionStrategy: PtpIpConnectionStrategy,
    phaseLogger: (String, String) -> Unit,
): SwiftCoreCameraSession =
    SwiftCoreCameraSession(
        host = opened.hostKey,
        cameraNameHint = opened.displayName,
        usbTransport = opened.transport,
        connectionStrategy = connectionStrategy,
        usbReopener =
            UsbPtpTransportReopener {
                reopenReadyUsbTransport(source, opened.hostKey)
            },
        phaseLogger = phaseLogger,
    )

/** Emits only safe connection failures to logcat, never pairing-phase details. */
private fun logCameraSessionPhase(phase: String, detail: String) {
    val message = cameraSessionDiagnosticMessage(phase, detail) ?: return
    Log.w(CAMERA_SESSION_LOG_TAG, message)
}

private const val CAMERA_SESSION_LOG_TAG = "SwiftCoreCameraSession"

/** Returns only diagnostics whose phase cannot carry the camera pairing credential. */
internal fun cameraSessionDiagnosticMessage(phase: String, detail: String): String? =
    when (phase) {
        "failed",
        "failed.usb",
        "failed.ptp",
        "failed.wifiJoin",
        "failed.usbPermission",
        "failed.pairing",
        "failed.reconnect",
        "eventChannelEnded",
        "eventChannelCleanupFailed",
        // The detail is a closed CameraControl name plus an elapsed-millis figure —
        // no pairing credential can ride it.
        "propertyWriteSlow",
        -> "$phase: $detail"
        else ->
            if (phase.startsWith("usb.")) {
                "$phase: $detail"
            } else {
                null
            }
    }

/** Closed diagnostic phase token for the first-run transport choice. */
internal fun diagnosticPhaseForPairingPath(path: PairingPath): String =
    when (path) {
        PairingPath.CAMERA_ACCESS_POINT -> "path.cameraAp"
        PairingPath.PHONE_HOTSPOT -> "path.phoneHotspot"
        PairingPath.WIFI_NETWORK -> "path.wifiNetwork"
        PairingPath.USB_C -> "path.usb"
        PairingPath.HDMI_CAPTURE -> "path.hdmi"
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
    /** Stages the connect pane: `ready`, `joining`, or `failed` (iOS ZC_DEMO_JOIN_POPUP). */
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

/**
 * What the permissions step asks for: Android 12 ignores a fine-location request that does not
 * carry coarse with it, so below API 33 it asks for both.
 */
internal fun pairingPermissionRequest(): List<String> =
    if (Build.VERSION.SDK_INT >= 33) listOf(requiredPairingPermission()) else DiscoveryPermissions.wifiNameRequest

/** Whether the pairing permission is already granted. */
public fun isPairingPermissionGranted(context: Context): Boolean =
    context.checkSelfPermission(requiredPairingPermission()) == PackageManager.PERMISSION_GRANTED

/**
 * Whether this device has a camera the credential scanner can open.
 *
 * A field monitor can run Android with no camera at all. Typed Wi-Fi entry
 * still pairs, so the scanner asks for the camera itself, only when it opens.
 */
public fun deviceHasCamera(context: Context): Boolean =
    context.packageManager.hasSystemFeature(PackageManager.FEATURE_CAMERA_ANY)

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
    fun cardTitle(card: PairingCard): Int =
        when (card) {
            PairingCard.WIRELESS -> R.string.pairing_card_wireless
            PairingCard.CABLE_LINK -> R.string.pairing_card_cable_link
        }

    @StringRes
    fun cardBadge(card: PairingCard): Int =
        when (card) {
            PairingCard.WIRELESS -> R.string.pairing_badge_most_freedom
            PairingCard.CABLE_LINK -> R.string.pairing_badge_most_stable
        }

    fun cardPros(card: PairingCard): List<Int> =
        when (card) {
            PairingCard.WIRELESS ->
                listOf(R.string.pairing_pro_wireless_move, R.string.pairing_pro_wireless_no_cable)
            PairingCard.CABLE_LINK ->
                listOf(R.string.pairing_pro_usb_stable, R.string.pairing_pro_usb_no_radio)
        }

    @StringRes
    fun cardCon(card: PairingCard): Int =
        when (card) {
            PairingCard.WIRELESS -> R.string.pairing_con_wireless_battery
            PairingCard.CABLE_LINK -> R.string.pairing_con_usb_tethered
        }

    /** Short caption on a nested option pill — the real trade, now the card copy is generic. */
    @StringRes
    fun optionCaption(path: PairingPath): Int =
        when (path) {
            PairingPath.CAMERA_ACCESS_POINT -> R.string.pairing_option_camera_ap
            PairingPath.PHONE_HOTSPOT -> R.string.pairing_option_phone_hotspot
            PairingPath.WIFI_NETWORK -> R.string.pairing_option_router
            PairingPath.USB_C -> R.string.pairing_option_usb_c
            PairingPath.HDMI_CAPTURE -> R.string.pairing_option_hdmi
        }

    @StringRes
    fun pathTitle(path: PairingPath): Int =
        when (path) {
            PairingPath.CAMERA_ACCESS_POINT -> R.string.pairing_path_camera_ap
            PairingPath.PHONE_HOTSPOT -> R.string.pairing_path_phone_hotspot
            PairingPath.WIFI_NETWORK -> R.string.pairing_path_router
            PairingPath.USB_C -> R.string.pairing_path_usb_c
            PairingPath.HDMI_CAPTURE -> R.string.pairing_path_hdmi
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
            PairingPath.WIFI_NETWORK ->
                listOf(
                    R.string.pairing_prepare_router_1,
                    R.string.pairing_prepare_router_2,
                    R.string.pairing_prepare_router_3,
                )
            PairingPath.USB_C ->
                listOf(
                    R.string.pairing_prepare_usb_1,
                    R.string.pairing_prepare_usb_2,
                    R.string.pairing_prepare_usb_3,
                )
            PairingPath.HDMI_CAPTURE ->
                listOf(
                    R.string.pairing_prepare_hdmi_1,
                    R.string.pairing_prepare_hdmi_2,
                    R.string.pairing_prepare_hdmi_3,
                )
        }

    @StringRes
    fun networkSubtitle(path: PairingPath): Int =
        when (path) {
            PairingPath.CAMERA_ACCESS_POINT -> R.string.pairing_network_ap
            PairingPath.PHONE_HOTSPOT -> R.string.pairing_network_hotspot
            PairingPath.WIFI_NETWORK -> R.string.pairing_network_router
            PairingPath.USB_C -> R.string.pairing_network_usb
            // Unreachable: the HDMI sequence carries no NETWORK step (PairingFlowState).
            PairingPath.HDMI_CAPTURE -> R.string.pairing_network_usb
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

    /** Credentials staged in the connect pane, waiting for the operator's Connect. */
    data class ReadyToJoin(val ssid: String, val key: String?, val keyFromScan: Boolean) :
        PairingPhase

    data object Joining : PairingPhase

    data object Handshaking : PairingPhase

    data class Pairing(val pin: String?) : PairingPhase

    data class ConfirmOnCamera(val pin: String?) : PairingPhase

    data object Reconnecting : PairingPhase

    data class Error(val message: String) : PairingPhase
}

/**
 * Max wait for body Confirm + camera AP readiness (reassociation **or** PTP
 * probe). Keep modest — TCP probe exits early once the body answers.
 */
internal const val FIRST_PAIR_CAMERA_AP_RESTART_TIMEOUT_MILLIS: Long = 25_000L
/**
 * Wall clock for post-Confirm reconnect (includes a full 20s Wi‑Fi rejoin budget
 * plus several Init retries — My-cameras shape).
 */
internal const val FIRST_PAIR_RECONNECT_TIMEOUT_MILLIS: Long = 60_000L
/** Gap between failed join/connect passes when the AP is not yet bound. */
internal const val FIRST_PAIR_RECONNECT_INTERVAL_MILLIS: Long = 500L
/**
 * Gap when already process-bound to the camera AP — Init can fail while the
 * body finishes rebooting; keep short so we recover as soon as PTP answers.
 */
internal const val FIRST_PAIR_BOUND_RETRY_INTERVAL_MILLIS: Long = 400L
internal const val FIRST_PAIR_HOTSPOT_SETTLE_MILLIS: Long = 2_000L
/** Specifier timeout for post-confirm rejoin attempts (full 45s only for first join). */
internal const val FIRST_PAIR_REJOIN_TIMEOUT_MILLIS: Int = 10_000

/**
 * Pause after a successful camera-AP join before the first PTP-IP Init.
 * Device logs show `rejectedInitiator` ~30ms after association when we race
 * the camera's stack; iOS waits for subnet confirmation and a similar settle.
 */
internal const val CAMERA_AP_POST_JOIN_SETTLE_MILLIS: Long = 1_200L

/** How many PTP-IP establish attempts after a camera-AP rejoin. */
internal const val CAMERA_AP_CONNECT_ATTEMPTS: Int = 3

/**
 * How long a fresh NSD browse may take to name the camera on its own network after a join.
 * Real hardware needs a while after association (DHCP + mDNS settling + the body's PTP
 * service coming up) — iOS allows 45s for the same wait, with the card's Cancel to escape.
 */
internal const val CAMERA_AP_DISCOVER_AFTER_JOIN_MILLIS: Long = 45_000L

internal const val CAMERA_AP_CONNECT_RETRY_DELAY_MILLIS: Long = 1_500L

/** How often the USB discover step re-enumerates while waiting for a camera. */
internal const val USB_DISCOVER_POLL_INTERVAL_MILLIS: Long = 1_500L

/**
 * Pause between Wi‑Fi search passes.
 *
 * A pass already spends seconds dialling, and the camera it is looking for may still be
 * finishing its own network setup — so the gap is for the operator's benefit, not the radio's:
 * long enough that a miss reason stays on screen to be read.
 */
internal const val WIFI_SEARCH_PASS_INTERVAL_MILLIS: Long = 2_000L

private fun PairingPhase.isBusy(): Boolean =
    this !is PairingPhase.Idle && this !is PairingPhase.Error

/**
 * The first-pair wizard (iOS `StartupFirstPairWizardView`), hosted in OpenCine's shared pair
 * page through an `IntegrationPairingFlow`: the page's rail shows the wizard's steps, its pane
 * the current step, and a connect in flight takes over the pane (title, detail, live line,
 * actions). Ends by handing a connected [PairedCamera] to [onPaired].
 */
@Composable
public fun PairingExperience(
    environment: PairingEnvironment,
    camerasModel: CamerasModel,
    onReportProblem: (() -> Unit)? = null,
    script: PairingScript? = null,
    onPaired: (PairedCamera) -> Unit,
    onPairingProfilePrepared: (SavedCameraRecord) -> Unit = {},
    /**
     * The operator gave up on a pairing. Anything [onPairingProfilePrepared] saved for it and
     * nothing ever connected through is theirs to take back. Twin of iOS
     * `cancelConnectionAttempt`.
     */
    onPairingAbandoned: () -> Unit = {},
    /**
     * Opens the monitor on the attached HDMI capture device — picture only,
     * no PTP session and no saved camera.
     */
    onStartHdmiMonitor: () -> Unit,
    onShowSavedCameras: (() -> Unit)? = null,
    /**
     * The way out of the wizard for a device that will not pair a camera — the watcher-only
     * entry. Opens the camera-list home, where nearby broadcasts are listed and joined; the
     * list screen owns that choice, the wizard only points at it (the iOS row's rule).
     */
    onOpenWatcherList: (() -> Unit)? = null,
    /** Explicit local report handoff when pairing cannot complete (no automatic upload). */
    onShareDiagnostics: (() -> Unit)? = null,
    /**
     * Closed connection phase tokens for the local diagnostics report
     * (e.g. `path.usb`, `failed.wifiJoin`). Must never receive free-form
     * operator or camera text — only stable tokens from [diagnosticPhaseForPairingPath].
     */
    onDiagnosticPhase: (String) -> Unit = {},
    onPrivacy: (() -> Unit)? = null,
    onTerms: (() -> Unit)? = null,
) {
    val context = LocalContext.current
    val resources = LocalResources.current
    // Wi-Fi paths only (PairingPath.usesWifi). The shared gate remembers a denial across process
    // death and sends the next ask to Settings once Android stops showing the dialog.
    val network =
        rememberPermissionGate("pairing.network", listOf(requiredPairingPermission()), pairingPermissionRequest())
    var flow by remember {
        mutableStateOf(
            script?.start ?: PairingFlowState.initial(isPairingPermissionGranted(context))
        )
    }
    var phase by remember { mutableStateOf<PairingPhase>(PairingPhase.Idle) }
    // The SSID actually joined this run — recorded on the saved profile so a
    // reconnect can rejoin the same camera AP.
    var joinedSsid by remember { mutableStateOf<String?>(null) }
    // Device title for the connect pane (SSID while joining, camera name after).
    var connectingName by remember { mutableStateOf<String?>(null) }
    var cameraWifiScannerPresented by remember { mutableStateOf(false) }
    /** A scanned key the operator corrected; null while the scan's own value still stands. */
    var correctedScanKey by remember { mutableStateOf<String?>(null) }
    /** A scanned network name the operator corrected; null while the scan's own value stands. */
    var correctedScanSsid by remember { mutableStateOf<String?>(null) }
    var wifiOffPromptVisible by remember { mutableStateOf(false) }
    var cameras by remember { mutableStateOf(emptyList<DiscoveredCamera>()) }
    var usbCameras by remember { mutableStateOf(emptyList<UsbPtpCamera>()) }
    var hdmiCaptureReady by remember { mutableStateOf(false) }
    /** Why the last Wi‑Fi search pass found nothing, when it found nothing. */
    var wifiSearchMiss by remember { mutableStateOf<InfrastructureMissReason?>(null) }
    val scope = rememberCoroutineScope()
    val work = remember { mutableStateOf<Job?>(null) }
    val handedOff = remember { mutableStateOf(false) }

    DisposableEffect(environment) {
        onDispose {
            work.value?.cancel()
            if (!handedOff.value) environment.releaseCameraAp()
        }
    }

    /** The one post-confirm reconnect ([reconnectAfterBodyConfirm]), shown on this wizard's card. */
    suspend fun reconnectAfterFirstPair(
        savedCamera: SavedCameraRecord,
        confirmPin: String? = null,
    ): PairedCamera? {
        // Stay on "Tap Confirm on the camera" while the body restarts its AP.
        phase = PairingPhase.ConfirmOnCamera(confirmPin)
        return reconnectAfterBodyConfirm(
            environment,
            savedCamera,
            discovered = { cameras },
            usbCameras = { usbCameras },
        ) { phase = PairingPhase.Reconnecting }
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
                            onDiagnosticPhase("failed.reconnect")
                            phase =
                                PairingPhase.Error(
                                    friendlyCameraConnectionFailure(null, unreachableMessage),
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
                        val failed = session.connectionProgress.value
                        // Session-layer failures already emit closed phase tokens via
                        // phaseLogger (failed.usb / failed.ptp). Do not double-record here.
                        phase =
                            PairingPhase.Error(
                                friendlyCameraConnectionFailure(
                                    failed.failure,
                                    failed.detail.takeIf { it.isNotBlank() } ?: unreachableMessage,
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
                    if (savedCamera.transport == SavedCameraTransport.USB_C) {
                        onDiagnosticPhase("failed.usb")
                    } else {
                        onDiagnosticPhase("failed.ptp")
                    }
                    phase =
                        PairingPhase.Error(friendlyCameraConnectionFailure(null, unreachableMessage))
                } finally {
                    progressWatcher.cancel()
                }
            }
    }

    fun connect(host: String) {
        // The wizard's declared path reaches persistence intact. Router used to collapse into
        // PHONE_HOTSPOT here — one line that silently reclassified every router camera.
        val transport =
            when (flow.path) {
                PairingPath.CAMERA_ACCESS_POINT -> SavedCameraTransport.CAMERA_ACCESS_POINT
                PairingPath.WIFI_NETWORK -> SavedCameraTransport.INFRASTRUCTURE
                else -> SavedCameraTransport.PHONE_HOTSPOT
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
            onDiagnosticPhase("failed.usb")
            phase = PairingPhase.Error(resources.getString(R.string.pairing_error_usb_unsupported))
            return
        }
        connectingName = camera.displayName
        when (camera.access) {
            UsbPtpCameraAccess.NEEDS_PERMISSION,
            UsbPtpCameraAccess.DENIED,
            -> {
                onDiagnosticPhase("failed.usbPermission")
                source.requestPermission(camera)
            }
            UsbPtpCameraAccess.IDENTITY_UNAVAILABLE -> {
                onDiagnosticPhase("failed.usb")
                phase =
                    PairingPhase.Error(
                        resources.getString(R.string.pairing_error_usb_identity),
                    )
            }
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
                                onDiagnosticPhase("failed.usb")
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
                    is UsbPtpOpenResult.Rejected -> {
                        onDiagnosticPhase("failed.usb")
                        phase = PairingPhase.Error(opened.message)
                    }
                }
        }
    }

    fun joinCameraAp(ssid: String, passphrase: String?) {
        if (ssid.isBlank()) return
        if (!isWifiRadioEnabled(context)) {
            wifiOffPromptVisible = true
            return
        }
        joinedSsid = ssid
        connectingName = ssid
        phase = PairingPhase.Joining
        onDiagnosticPhase("joiningWifi")
        work.value =
            scope.launch {
                // Retries + pre-scan live inside NikonCameraAp.join: one call only.
                val joined = environment.joinCameraAp(ssid, passphrase)
                if (joined) {
                    // The encrypted store is the only place a confirmed key
                    // lives; the pane's plaintext staging dies with the phase.
                    if (passphrase != null) environment.credentials.save(ssid, passphrase)
                    environment.credentials.lastSsid = ssid
                    // Association can finish before the camera answers PTP-IP
                    // Init; match the saved-reconnect settle before handshaking.
                    delay(CAMERA_AP_POST_JOIN_SETTLE_MILLIS)
                    // Discover on the live link — no fixed camera-AP IP. The window matches the
                    // saved-reconnect one (and iOS's 45s browse): 3s regularly lost the race
                    // against a body still bringing up mDNS after association.
                    val host =
                        cameras.firstOrNull()?.host
                            ?: withTimeoutOrNull(CAMERA_AP_DISCOVER_AFTER_JOIN_MILLIS) {
                                environment.hotspotCameras.first { it.isNotEmpty() }.first().host
                            }
                    if (host != null) {
                        connect(host)
                    } else {
                        onDiagnosticPhase("failed.noCameraOnAp")
                        phase =
                            PairingPhase.Error(
                                resources.getString(R.string.pairing_error_wifi_join)
                            )
                    }
                } else {
                    onDiagnosticPhase("failed.wifiJoin")
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
        if (!isWifiRadioEnabled(context)) {
            wifiOffPromptVisible = true
            return
        }
        cameraWifiScannerPresented = true
    }

    fun cancelWork() {
        work.value?.cancel()
        work.value = null
        if (flow.path == PairingPath.CAMERA_ACCESS_POINT) environment.releaseCameraAp()
        connectingName = null
        phase = PairingPhase.Idle
        // A pairing the operator walked away from leaves no row behind — the profile is saved
        // before the body confirmation, and this is the dismiss on both "Confirm on camera" and
        // the failure card.
        onPairingAbandoned()
    }

    fun retreat() {
        phase = PairingPhase.Idle
        flow = flow.retreat()
    }

    // Discovery is deliberately transport-specific: hotspot discovery never
    // touches USB, USB enumeration never scans or joins a network, and HDMI
    // only ever asks CameraX whether a capture device is enumerated.
    if (flow.step == PairingStep.DISCOVER) {
        LaunchedEffect(environment, flow.path) {
            when (flow.path) {
                PairingPath.USB_C -> {
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
                }
                PairingPath.HDMI_CAPTURE -> {
                    cameras = emptyList()
                    usbCameras = emptyList()
                    // Same reasoning as the USB poll: attach delivery is not
                    // reliable, so a cable plugged in on this step is found by
                    // asking again.
                    while (isActive) {
                        hdmiCaptureReady = hasExternalUvcCamera(context)
                        delay(USB_DISCOVER_POLL_INTERVAL_MILLIS)
                    }
                }
                PairingPath.WIFI_NETWORK -> {
                    usbCameras = emptyList()
                    // mDNS stays live for the whole step — a body sometimes announces briefly —
                    // but it is not the mechanism. A body sitting on its Connect-to-computer
                    // screen announces nothing at all, which is why this path needs a search.
                    launch {
                        environment.hotspotCameras.collect { found ->
                            if (found.isNotEmpty()) {
                                cameras = found
                                wifiSearchMiss = null
                            }
                        }
                    }
                    while (isActive) {
                        val report =
                            environment.searchInfrastructure(
                                emptyList(),
                                cameras.associate { it.host to it.name },
                            )
                        if (report.foundCamera) {
                            cameras = report.cameras
                            wifiSearchMiss = null
                        } else {
                            // A miss with a REASON. "Still searching" for ever is what an operator
                            // got before, on a network the app could already prove was silent.
                            wifiSearchMiss = report.miss
                        }
                        delay(WIFI_SEARCH_PASS_INTERVAL_MILLIS)
                    }
                }
                else -> {
                    usbCameras = emptyList()
                    environment.hotspotCameras.collect { cameras = it }
                }
            }
        }
    }

    if (script?.autoConnect == true) {
        // Demo scripts drive the operator's own action; never invent an IP.
        LaunchedEffect(script) {
            if (flow.step == PairingStep.NETWORK && flow.path == PairingPath.CAMERA_ACCESS_POINT) {
                // The network step connects by joining the scanned access point, then discovers
                // the camera on that link. Same scripted scan as `joinPopup`.
                joinCameraAp("NIKON_ZR_01234", "a1b2c3d4")
            } else {
                // Scripted discovery publishes its camera after a delay; wait for the first host.
                connect(snapshotFlow { cameras.firstOrNull()?.host }.filterNotNull().first())
            }
        }
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
    // A connect in flight renders in the pair page's pane (title, detail, live line, actions):
    // the copy of the old full-screen connect card.
    val deviceName = connectionDisplayName(connectingName)
    val connectDetail =
        when (val active = phase) {
            PairingPhase.Idle -> ""
            is PairingPhase.ReadyToJoin -> stringResource(R.string.conn_ready_detail, deviceName)
            PairingPhase.Joining -> stringResource(R.string.conn_joining_detail)
            PairingPhase.Handshaking -> stringResource(R.string.conn_handshaking_detail, deviceName)
            is PairingPhase.Pairing -> stringResource(R.string.conn_pairing_detail, deviceName)
            // The app auto-accepts the pairing request, so the camera's PIN is never something
            // the operator has to enter (iOS omits it too).
            is PairingPhase.ConfirmOnCamera -> stringResource(R.string.conn_confirm_detail, deviceName)
            PairingPhase.Reconnecting -> stringResource(R.string.conn_reconnecting_detail, deviceName)
            is PairingPhase.Error -> active.message
        }
    val connectStatus =
        when (phase) {
            PairingPhase.Joining, PairingPhase.Handshaking, PairingPhase.Reconnecting ->
                stringResource(R.string.conn_connecting_title)
            is PairingPhase.Pairing -> stringResource(R.string.conn_pairing_title)
            is PairingPhase.ConfirmOnCamera -> stringResource(R.string.conn_confirm_title)
            else -> null
        }

    // Connecting to a held camera drops the holder's session (the single-initiator mechanism the
    // discovery shield exists to avoid): the row names whose it is, and this stops the tap being
    // the whole decision.
    val consentSource = remember { Any() }
    DisposableEffect(camerasModel, consentSource) {
        onDispose { camerasModel.consent.retire(consentSource) }
    }
    val discovery =
        discoveryPane(flow.path, cameras, usbCameras, hdmiCaptureReady, wifiSearchMiss)
            .takeIf { flow.step == PairingStep.DISCOVER }
    fun selectDiscovered(id: String) {
        when {
            id == HDMI_DEVICE_ID -> onStartHdmiMonitor()
            id.startsWith(USB_DEVICE_PREFIX) ->
                usbCameras.firstOrNull { USB_DEVICE_PREFIX + it.token == id }?.let(::connectUsb)
            else -> cameras.firstOrNull { it.host == id }?.let { camera ->
                if (camera.isHeldByAnotherDevice) {
                    camerasModel.consent.present(
                        NikonTakeOverPrompt(camera.name, camera.heldByDeviceName, confirm = { connect(camera.host) }, cancel = {}),
                        source = consentSource,
                        isCurrent = { flow.step == PairingStep.DISCOVER && cameras.any { it.host == camera.host && it.isHeldByAnotherDevice } },
                    )
                } else {
                    camerasModel.consent.retire(consentSource)
                    connect(camera.host)
                }
            }
        }
    }

    Box(Modifier.fillMaxSize().background(MonitorPalette.background)) {
        val steps = flow.sequence
        val primary = when {
            flow.step == PairingStep.CHOOSE_PATH || flow.isFinalStep && flow.step != PairingStep.NETWORK -> null
            flow.step == PairingStep.NETWORK -> stringResource(R.string.pairing_connect_my_camera)
            // The permission is asked from the step's own button; Settings once Android stops asking.
            flow.step == PairingStep.PERMISSIONS && !network.granted ->
                stringResource(if (network.needsSettings) R.string.status_settings else R.string.action_allow)
            else -> stringResource(R.string.action_continue)
        }
        PairScreen(
            model = camerasModel,
            onDone = { onShowSavedCameras?.invoke() ?: onOpenWatcherList?.invoke() },
            onDiagnostics = { onShareDiagnostics?.invoke() },
            onReportProblem = { onReportProblem?.invoke() },
            // The page's one watch entry (its menu): a watcher-only device never pairs.
            onWatchFeed = onOpenWatcherList,
            modifier = Modifier.pairPageFrame(),
            pairingFlow = IntegrationPairingFlow(
                presentation = MonitorPairingPresentation(
                    steps = steps.map { MonitorPairingStep(stringResource(PairingCopy.stepTitle(it)), "") },
                    currentStep = flow.displayStepNumber - 1,
                    title = stringResource(PairingCopy.stepTitle(flow.step)),
                    body = when (flow.step) {
                        PairingStep.NETWORK -> stringResource(PairingCopy.networkSubtitle(flow.path))
                        PairingStep.PERMISSIONS -> stringResource(PairingCopy.permissionDetail)
                        PairingStep.DISCOVER -> discovery?.detail.orEmpty()
                        else -> ""
                    },
                    target = "Nikon Z", hint = "",
                    devices = discovery?.devices.orEmpty(),
                    progress = discovery?.waiting,
                    instructions = if (flow.step == PairingStep.NETWORK) networkInstructions(flow.path) else emptyList(),
                    checks = if (flow.step == PairingStep.PERMISSIONS) listOf(networkPermissionCheck(network)) else emptyList(),
                    primaryAction = primary,
                    primaryActionEnabled = !busy,
                    backAction =
                        when {
                            flow.canRetreat -> stringResource(R.string.action_back)
                            // The way home exists only when there is a home to go to.
                            onShowSavedCameras != null -> stringResource(R.string.saved_your_cameras)
                            else -> null
                        },
                ).let { step ->
                    when (val active = phase) {
                        PairingPhase.Idle -> step
                        is PairingPhase.Error ->
                            step.copy(
                                title = deviceName, body = stringResource(R.string.conn_failed_title), error = active.message,
                                primaryAction = onShareDiagnostics?.let { stringResource(R.string.conn_share_diagnostics) },
                                primaryActionEnabled = true, backAction = stringResource(R.string.action_close),
                            )
                        is PairingPhase.ReadyToJoin ->
                            step.copy(
                                title = deviceName, body = connectDetail,
                                primaryAction = stringResource(R.string.action_connect), primaryActionEnabled = true,
                                backAction = stringResource(R.string.action_cancel),
                            )
                        else ->
                            step.copy(
                                title = deviceName, body = connectDetail, progress = connectStatus,
                                primaryAction = null, backAction = stringResource(R.string.action_cancel),
                            )
                    }
                },
                onPrimary = {
                    val staged = phase as? PairingPhase.ReadyToJoin
                    if (staged != null) {
                        // The CORRECTED values when the operator fixed a misread character,
                        // otherwise the scan's own.
                        joinCameraAp(correctedScanSsid?.takeIf(String::isNotBlank) ?: staged.ssid, correctedScanKey ?: staged.key)
                    } else if (phase is PairingPhase.Error) {
                        onShareDiagnostics?.invoke()
                    } else if (flow.step == PairingStep.NETWORK && flow.path == PairingPath.CAMERA_ACCESS_POINT) {
                        connectMyCamera()
                    } else if (flow.step == PairingStep.PERMISSIONS && !network.granted) {
                        network.request()
                    } else {
                        flow = flow.advance()
                    }
                },
                onSelect = ::selectDiscovered,
                onBack = {
                    when {
                        phase != PairingPhase.Idle -> cancelWork()
                        flow.canRetreat -> retreat()
                        else -> onShowSavedCameras?.invoke()
                    }
                },
                content = {
                    val staged = phase as? PairingPhase.ReadyToJoin
                    if (phase != PairingPhase.Idle) {
                        // The connect pane: only a scan needs content beyond the page's own lines.
                        if (staged?.key != null && staged.keyFromScan) {
                            ScannedJoinFields(staged, onSsidEdited = { correctedScanSsid = it }, onKeyEdited = { correctedScanKey = it })
                        }
                    } else when (flow.step) {
                        PairingStep.CHOOSE_PATH -> ChoosePathBody(
                            onChoose = { path ->
                                onDiagnosticPhase(diagnosticPhaseForPairingPath(path))
                                flow = flow.choose(path)
                            },
                        )
                        PairingStep.PREPARE -> NumberedCards(PairingCopy.prepareSteps(flow.path).map { stringResource(it) })
                        // The shared page draws these from the presentation: the permission check,
                        // the network cards and the discovered devices.
                        PairingStep.PERMISSIONS, PairingStep.NETWORK, PairingStep.DISCOVER -> Unit
                    }
                },
            ),
            onPrivacy = onPrivacy,
            onTerms = onTerms,
        )
        if (cameraWifiScannerPresented) {
            CameraWifiScannerOverlay(
                onConfirmed = { candidate ->
                    // The scanner has already been reviewed by the operator;
                    // this stages the connect pane's Connect action. No
                    // credential is persisted until a successful join.
                    cameraWifiScannerPresented = false
                    connectingName = candidate.ssid
                    phase =
                        PairingPhase.ReadyToJoin(
                            candidate.ssid,
                            candidate.key,
                            keyFromScan = true,
                        )
                    // Warm scan results before Connect so the system panel is not empty.
                    environment.primeCameraApScan(candidate.ssid)
                },
                onDismiss = { cameraWifiScannerPresented = false },
                onDiagnosticPhase = onDiagnosticPhase,
            )
        }
        if (wifiOffPromptVisible) {
            WifiOffPromptDialog(onDismiss = { wifiOffPromptVisible = false })
        }
        // Keep scanning while the Ready-to-join card is up.
        val readySsid = (phase as? PairingPhase.ReadyToJoin)?.ssid
        LaunchedEffect(readySsid) {
            val ssid = readySsid ?: return@LaunchedEffect
            while (true) {
                environment.primeCameraApScan(ssid)
                delay(2_000)
            }
        }
    }
}

// MARK: - Connect pane

/** Operator-friendly device title: the raw SSID or camera name, else the generic body name. */
private fun connectionDisplayName(raw: String?): String = raw?.trim().orEmpty().ifEmpty { "Nikon camera" }

/**
 * The scanned network name and key, EDITABLE: OCR misreads a character now and then (0/O, 1/l,
 * 5/S, 8/B), and an operator who can see the wrong character must be able to fix it. Both
 * fields, because one scan produced both: a wrong key is refused by the network, a wrong name
 * simply never appears. Twin of the iOS join fields.
 */
@Composable
private fun ScannedJoinFields(
    staged: PairingPhase.ReadyToJoin,
    onSsidEdited: (String) -> Unit,
    onKeyEdited: (String) -> Unit,
) {
    var ssid by remember(staged.ssid) { mutableStateOf(staged.ssid) }
    var key by remember(staged.key) { mutableStateOf(staged.key.orEmpty()) }
    ScannedField(stringResource(R.string.conn_scanned_network), ssid) {
        ssid = it
        onSsidEdited(it)
    }
    ScannedField(stringResource(R.string.conn_scanned_key), key) {
        key = it
        onKeyEdited(it)
    }
    Text(
        stringResource(R.string.conn_scanned_caption),
        color = MonitorPalette.muted,
        style = MonitorTypography.text(12f).copy(lineHeight = 16.sp),
    )
}

@Composable
private fun ScannedField(label: String, value: String, onValueChange: (String) -> Unit) {
    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(
            label.uppercase(),
            color = MonitorPalette.faint,
            style = MonitorTypography.text(8f, FontWeight.Bold).copy(letterSpacing = 1.3.sp),
        )
        BasicTextField(
            value = value,
            onValueChange = onValueChange,
            singleLine = true,
            textStyle = LocalTextStyle.current.copy(color = MonitorPalette.text, fontSize = 16.sp, fontFamily = FontFamily.Monospace),
            cursorBrush = SolidColor(MonitorPalette.text),
            modifier = Modifier.fillMaxWidth().paneCard().padding(horizontal = 13.dp, vertical = 12.dp),
        )
    }
}

// MARK: - Step bodies

/** The pair pane's card surface (the shared page's instruction and device cards). */
private fun Modifier.paneCard(): Modifier =
    clip(RoundedCornerShape(11.dp))
        .background(Color.White.copy(alpha = 0.03f))
        .border(1.dp, Color.White.copy(alpha = 0.06f), RoundedCornerShape(11.dp))

@Composable
private fun ChoosePathBody(onChoose: (PairingPath) -> Unit) {
    // iOS `transportCards`, stacked inside the step body's scroll. Cards group
    // several paths, so the operator picks a kind of connection first and the
    // specific one second.
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        for (card in PairingCard.entries) {
            PathChoiceCard(card, onChoose, Modifier.fillMaxWidth())
        }
    }
}

/** One transport option (iOS `StartupWizardTransportCard`). */
@Composable
private fun PathChoiceCard(
    card: PairingCard,
    onChoose: (PairingPath) -> Unit,
    modifier: Modifier,
) {
    // A card with one option is a leaf — revealing a single choice would be a step for nothing.
    val single = card.options.singleOrNull()
    var showsOptions by rememberSaveable(card) { mutableStateOf(false) }
    Column(
        modifier
            .paneCard()
            .clickable {
                if (single != null) onChoose(single) else showsOptions = !showsOptions
            }
            .padding(13.dp),
        verticalArrangement = Arrangement.spacedBy(9.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(9.dp)) {
            Box(
                Modifier.size(26.dp).background(MonitorPalette.accent.copy(alpha = 0.12f), RoundedCornerShape(8.dp)),
                contentAlignment = Alignment.Center,
            ) {
                MonitorIcon(
                    icon =
                        when (card) {
                            PairingCard.WIRELESS -> MonitorIcon.RADIO
                            PairingCard.CABLE_LINK -> MonitorIcon.CABLE
                        },
                    contentDescription = null,
                    modifier = Modifier.size(14.dp),
                    tint = MonitorPalette.accent,
                )
            }
            Text(
                stringResource(PairingCopy.cardTitle(card)),
                color = MonitorPalette.text,
                style = MonitorTypography.text(13.5f, FontWeight.SemiBold),
                maxLines = 2,
                modifier = Modifier.weight(1f),
            )
            Text(
                stringResource(PairingCopy.cardBadge(card)).uppercase(),
                color = MonitorPalette.accent,
                style = MonitorTypography.text(8.5f, FontWeight.Bold).copy(letterSpacing = 1.1.sp),
                maxLines = 1,
            )
        }
        if (showsOptions && single == null) {
            Column(verticalArrangement = Arrangement.spacedBy(7.dp)) {
                for (option in card.options) {
                    Column(
                        Modifier.fillMaxWidth()
                            .clip(RoundedCornerShape(9.dp))
                            .background(MonitorPalette.accent.copy(alpha = 0.08f))
                            .clickable { onChoose(option) }
                            .padding(horizontal = 11.dp, vertical = 9.dp),
                        verticalArrangement = Arrangement.spacedBy(2.dp),
                    ) {
                        Text(
                            stringResource(PairingCopy.pathTitle(option)),
                            color = MonitorPalette.text,
                            style = MonitorTypography.text(12.5f, FontWeight.SemiBold),
                        )
                        Text(
                            stringResource(PairingCopy.optionCaption(option)),
                            color = MonitorPalette.muted,
                            style = MonitorTypography.text(9.5f),
                        )
                    }
                }
            }
        } else {
            Column(verticalArrangement = Arrangement.spacedBy(5.dp)) {
                for (pro in PairingCopy.cardPros(card)) {
                    TradeoffRow("+", MonitorPalette.accent, stringResource(pro))
                }
                TradeoffRow("−", MonitorPalette.faint, stringResource(PairingCopy.cardCon(card)))
            }
        }
    }
}

@Composable
private fun TradeoffRow(
    symbol: String,
    color: Color,
    text: String,
) {
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(
            symbol,
            color = color,
            style = MonitorTypography.text(12f, FontWeight.Bold),
            modifier = Modifier.width(12.dp),
        )
        Text(
            text,
            color = MonitorPalette.secondary,
            style = MonitorTypography.text(12f).copy(lineHeight = 15.5.sp),
            modifier = Modifier.weight(1f),
        )
    }
}

/** Numbered instruction cards (iOS `StartupWizardPrepareCards`), in the pane's card style. */
@Composable
private fun NumberedCards(steps: List<String>) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        steps.forEachIndexed { index, step ->
            Row(
                Modifier.fillMaxWidth().paneCard().padding(13.dp),
                horizontalArrangement = Arrangement.spacedBy(11.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Box(
                    Modifier.size(22.dp).background(MonitorPalette.accent.copy(alpha = 0.16f), CircleShape),
                    contentAlignment = Alignment.Center,
                ) {
                    Text(
                        stringResource(R.string.step_number, index + 1),
                        color = MonitorPalette.accent,
                        style = MonitorTypography.text(10f, FontWeight.Bold),
                        maxLines = 1,
                    )
                }
                Text(
                    step,
                    color = MonitorPalette.secondary,
                    style = MonitorTypography.text(12.5f).copy(lineHeight = 15.5.sp),
                    modifier = Modifier.weight(1f),
                )
            }
        }
    }
}

/** The permissions step's one check: the Wi-Fi permission, as the shared page's check row. */
@Composable
private fun networkPermissionCheck(network: PermissionGate): MonitorPairingCheck =
    MonitorPairingCheck(
        title = stringResource(PairingCopy.permissionTitle),
        subtitle = stringResource(R.string.pairing_permissions_group),
        state = if (network.granted) MonitorPairingCheckState.COMPLETE else MonitorPairingCheckState.ACTIVE,
        stateLabel =
            stringResource(
                when {
                    network.granted -> R.string.status_allowed
                    network.needsSettings -> R.string.status_settings
                    else -> R.string.action_allow
                },
            ).uppercase(),
    )

/** The device row id of the HDMI capture device ([discoveryPane]). */
private const val HDMI_DEVICE_ID = "hdmi"

/** Prefix of a USB camera's device row id; the rest is its [UsbPtpCamera.token]. */
private const val USB_DEVICE_PREFIX = "usb:"

/** What the discover step shows on the shared pane: its rows, or why it is still waiting. */
private class DiscoveryPane(val devices: List<MonitorPairingDevice>, val waiting: String?, val detail: String)

/**
 * The discover step on the shared pane: found cameras (Wi-Fi), attached cameras (USB-C) or the
 * capture device (HDMI) as its device rows, else the waiting line and why. A row's tap is the
 * flow's `onSelect` with the row id.
 */
@Composable
private fun discoveryPane(
    path: PairingPath,
    cameras: List<DiscoveredCamera>,
    usbCameras: List<UsbPtpCamera>,
    hdmiCaptureReady: Boolean,
    wifiSearchMiss: InfrastructureMissReason?,
): DiscoveryPane =
    when (path) {
        PairingPath.USB_C ->
            DiscoveryPane(
                usbCameras.map { camera ->
                    MonitorPairingDevice(
                        id = USB_DEVICE_PREFIX + camera.token,
                        name = camera.displayName,
                        subtitle =
                            if (camera.isDebugFixture) {
                                "$USB_DEBUG_FIXTURE_LABEL · ${usbCameraDebugDetail(camera.access)}"
                            } else {
                                stringResource(usbCameraDetailResource(camera.access))
                            },
                        busy = camera.access == UsbPtpCameraAccess.IDENTITY_UNAVAILABLE,
                    )
                },
                stringResource(R.string.pairing_waiting_usb).takeIf { usbCameras.isEmpty() },
                stringResource(R.string.pairing_waiting_usb_detail).takeIf { usbCameras.isEmpty() }.orEmpty(),
            )
        PairingPath.HDMI_CAPTURE ->
            DiscoveryPane(
                listOfNotNull(
                    MonitorPairingDevice(
                        HDMI_DEVICE_ID,
                        stringResource(R.string.pairing_hdmi_device_title),
                        stringResource(R.string.pairing_hdmi_device_detail),
                    ).takeIf { hdmiCaptureReady },
                ),
                stringResource(R.string.pairing_waiting_hdmi).takeIf { !hdmiCaptureReady },
                stringResource(R.string.pairing_waiting_hdmi_detail).takeIf { !hdmiCaptureReady }.orEmpty(),
            )
        else ->
            DiscoveryPane(
                // The holder replaces "nearby": on this row the question is not where the camera
                // is, it is who has it.
                cameras.map { camera ->
                    MonitorPairingDevice(camera.host, camera.name, camera.heldByLabel ?: stringResource(R.string.pairing_wifi_nearby))
                },
                stringResource(R.string.pairing_looking_for_cameras).takeIf { cameras.isEmpty() },
                // A diagnosis the moment the search has one: once a sweep proved the subnet silent,
                // or busy with nothing serving PTP, "still looking" withholds what the operator
                // could act on.
                if (cameras.isEmpty()) {
                    wifiSearchMiss?.operatorCopy()
                        ?: stringResource(R.string.pairing_waiting_hotspot_detail)
                } else {
                    ""
                },
            )
    }

/**
 * The network step is instruction-only on every path (iOS `StartupWizardNetworkStep`): the
 * camera-AP flow is scanner-first, so the "Connect my camera" primary opens the scanner, never a
 * typed credential form. The shared page draws these as its camera and phone instruction cards.
 */
@Composable
private fun networkInstructions(path: PairingPath): List<MonitorPairingInstruction> {
    val camera = stringResource(R.string.pairing_on_camera)
    val phone = stringResource(R.string.pairing_on_phone)
    @Composable
    fun card(title: String, icon: MonitorPairingInstructionIcon, vararg lines: Int) =
        MonitorPairingInstruction(title, icon, lines.map { stringResource(it) })
    return when (path) {
        PairingPath.CAMERA_ACCESS_POINT -> listOf(
            card(camera, MonitorPairingInstructionIcon.CAMERA, R.string.pairing_network_ap_camera_1),
            card(phone, MonitorPairingInstructionIcon.PHONE, R.string.pairing_network_ap_phone_1),
        )
        PairingPath.PHONE_HOTSPOT -> listOf(
            card(camera, MonitorPairingInstructionIcon.CAMERA, *PairingCopy.hotspotCameraSteps.toIntArray()),
        )
        PairingPath.USB_C -> listOf(
            card(camera, MonitorPairingInstructionIcon.CAMERA,
                R.string.pairing_network_usb_camera_1, R.string.pairing_network_usb_camera_2),
            card(phone, MonitorPairingInstructionIcon.PHONE, R.string.pairing_network_usb_phone_1),
        )
        // Unreachable: the HDMI sequence carries no NETWORK step (PairingFlowState).
        PairingPath.HDMI_CAPTURE -> emptyList()
        // Nothing to join from here: both devices are already on someone else's network,
        // so this step is a check rather than an action.
        PairingPath.WIFI_NETWORK -> listOf(
            card(camera, MonitorPairingInstructionIcon.CAMERA, R.string.pairing_network_router_camera_1),
            card(phone, MonitorPairingInstructionIcon.PHONE, R.string.pairing_network_router_phone_1),
        )
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

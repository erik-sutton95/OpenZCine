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
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.opencapture.openzcine.bridge.SwiftCoreCameraSession
import com.opencapture.openzcine.core.CameraSession
import com.opencapture.openzcine.core.CameraSessionState
import com.opencapture.openzcine.transport.AndroidNsdBrowser
import com.opencapture.openzcine.transport.CameraDiscovery
import com.opencapture.openzcine.transport.DiscoveredCamera
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
    /** Remembered camera-AP credentials. */
    public val credentials: PairingCredentials,
)

/** Production [PairingEnvironment] over the real platform services. */
public fun realPairingEnvironment(context: Context): PairingEnvironment {
    val joiner = CameraApJoiner(context.getSystemService(ConnectivityManager::class.java))
    val discovery =
        CameraDiscovery(AndroidNsdBrowser(context.getSystemService(NsdManager::class.java)))
    return PairingEnvironment(
        joinCameraAp = { ssid, passphrase -> joiner.join(ssid, passphrase) },
        releaseCameraAp = joiner::release,
        hotspotCameras = discovery.cameras(),
        createSession = { host -> SwiftCoreCameraSession(host) },
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
    fun stepTitle(step: PairingStep): String =
        when (step) {
            PairingStep.PERMISSIONS -> "Allow permissions"
            PairingStep.CHOOSE_PATH -> "Choose how to connect"
            PairingStep.PREPARE -> "Prepare your camera"
            PairingStep.NETWORK -> "Set up the network"
            PairingStep.DISCOVER -> "Find and pair"
        }

    fun introFooter(step: PairingStep): String =
        when (step) {
            PairingStep.PERMISSIONS ->
                "Only what pairing needs — change anytime in Android Settings."
            PairingStep.CHOOSE_PATH ->
                "Each trades battery, quality, and convenience — pick what fits the shoot."
            PairingStep.PREPARE ->
                "Menu names match the Nikon ZR; they may vary by model and firmware version."
            PairingStep.NETWORK ->
                "Get both devices onto the same network — we'll find the camera automatically."
            PairingStep.DISCOVER -> "Keep the camera powered on and nearby while we find it."
        }

    fun pathTitle(path: PairingPath): String =
        when (path) {
            PairingPath.CAMERA_ACCESS_POINT -> "Camera's Access Point"
            PairingPath.PHONE_HOTSPOT -> "Phone's Hotspot"
        }

    fun pathBadge(path: PairingPath): String =
        when (path) {
            PairingPath.CAMERA_ACCESS_POINT -> "Simplest"
            PairingPath.PHONE_HOTSPOT -> "Best wireless"
        }

    fun pathPros(path: PairingPath): List<String> =
        when (path) {
            PairingPath.CAMERA_ACCESS_POINT ->
                listOf("Lightest battery use", "No phone setup needed")
            PairingPath.PHONE_HOTSPOT -> listOf("Best wireless quality", "Stable at high settings")
        }

    fun pathCon(path: PairingPath): String =
        when (path) {
            PairingPath.CAMERA_ACCESS_POINT -> "Softer link, lower quality"
            PairingPath.PHONE_HOTSPOT -> "Heavier battery drain"
        }

    // [VERIFY-ON-HW] Confirm the ZR's exact menu wording for each path on hardware.
    fun prepareSteps(path: PairingPath): List<String> =
        when (path) {
            PairingPath.CAMERA_ACCESS_POINT ->
                listOf(
                    "On the camera: Network menu → Connect to computer → Network settings.",
                    "Choose Create Profile and give the profile a name.",
                    "Select Direct connection to computer — the camera shows its SSID and key.",
                )
            PairingPath.PHONE_HOTSPOT ->
                listOf(
                    "Turn on your phone's Wi‑Fi hotspot (Settings → Hotspot & tethering).",
                    "Note the hotspot name and password — the camera needs them to join.",
                    "On the camera: Network menu → Connect to computer.",
                    "We'll walk through joining your hotspot in the next step.",
                )
        }

    fun networkSubtitle(path: PairingPath, keyRemembered: Boolean): String =
        when (path) {
            PairingPath.CAMERA_ACCESS_POINT ->
                if (keyRemembered) {
                    "The key for this camera is remembered — check the SSID and tap Join."
                } else {
                    "Enter the SSID and key from the camera's screen — " +
                        "we remember the key for next time."
                }
            PairingPath.PHONE_HOTSPOT -> "Keep your phone's Wi‑Fi hotspot on. Then on the camera:"
        }

    /** Camera-side instruction card lines for the hotspot network step. */
    val hotspotCameraSteps: List<String> =
        listOf(
            "Connect to computer → Network settings",
            "Create Profile → name your profile",
            "Search for Wi‑Fi network → join this phone's hotspot",
            "IP address → Obtain automatically",
        )

    val permissionTitle: String =
        if (Build.VERSION.SDK_INT >= 33) "Nearby devices" else "Location"

    val permissionDetail: String =
        if (Build.VERSION.SDK_INT >= 33) {
            "Find and stream from your camera over Wi‑Fi."
        } else {
            "Android uses Location access to find cameras on Wi‑Fi. " +
                "Your location is never tracked or stored."
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
 */
@Composable
public fun PairingExperience(
    environment: PairingEnvironment,
    script: PairingScript? = null,
    onPaired: (PairedCamera) -> Unit,
) {
    val context = LocalContext.current
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
    val keyWasRemembered = remember { keyField.isNotEmpty() }
    var cameras by remember { mutableStateOf(emptyList<DiscoveredCamera>()) }
    val scope = rememberCoroutineScope()
    val work = remember { mutableStateOf<Job?>(null) }
    val handedOff = remember { mutableStateOf(false) }

    DisposableEffect(environment) {
        onDispose {
            work.value?.cancel()
            if (!handedOff.value) environment.releaseCameraAp()
        }
    }

    fun connect(host: String) {
        phase = PairingPhase.Connecting
        work.value =
            scope.launch {
                val session = environment.createSession(host)
                try {
                    session.connect()
                    val connected = session.state.value as? CameraSessionState.Connected
                    if (connected != null) {
                        handedOff.value = true
                        onPaired(
                            PairedCamera(
                                session = session,
                                savedCamera =
                                    SavedCameraRecord(
                                        host = host,
                                        cameraName = connected.identity.name,
                                        transport =
                                            if (flow.path == PairingPath.CAMERA_ACCESS_POINT) {
                                                SavedCameraTransport.CAMERA_ACCESS_POINT
                                            } else {
                                                SavedCameraTransport.PHONE_HOTSPOT
                                            },
                                        lastSeenAtEpochMillis = System.currentTimeMillis(),
                                        wifiSsid =
                                            if (flow.path == PairingPath.CAMERA_ACCESS_POINT) {
                                                ssidField.trim().takeIf(String::isNotEmpty)
                                            } else {
                                                null
                                            },
                                    ),
                            ),
                        )
                    } else {
                        phase =
                            PairingPhase.Error(
                                "Couldn't reach the camera. Check Wi‑Fi and try again."
                            )
                    }
                } catch (error: CancellationException) {
                    // `sessionConnect` begins native work asynchronously. A
                    // cancelled wizard must tear that work down before a retry
                    // can claim the process-wide PTP slot.
                    withContext(NonCancellable) { session.disconnect() }
                    throw error
                }
            }
    }

    fun joinCameraAp() {
        val ssid = ssidField.trim()
        if (ssid.isEmpty()) return
        phase = PairingPhase.Joining
        work.value =
            scope.launch {
                val joined = environment.joinCameraAp(ssid, keyField.ifEmpty { null })
                if (joined) {
                    if (keyField.isNotEmpty()) environment.credentials.save(ssid, keyField)
                    environment.credentials.lastSsid = ssid
                    // Camera-AP mode: the ZR always answers on the fixed AP host.
                    connect(CameraDiscovery.NIKON_ZR_ACCESS_POINT_HOST)
                } else {
                    phase =
                        PairingPhase.Error(
                            "Couldn't join the camera's Wi‑Fi. Check the key and try again."
                        )
                }
            }
    }

    fun cancelWork() {
        work.value?.cancel()
        work.value = null
        if (flow.path == PairingPath.CAMERA_ACCESS_POINT) environment.releaseCameraAp()
        phase = PairingPhase.Idle
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

    // Hotspot path ONLY: watch for the camera to join the phone's hotspot.
    // The phone hosts — it never scans or joins networks on this path.
    if (flow.step == PairingStep.DISCOVER) {
        LaunchedEffect(environment) {
            environment.hotspotCameras.collect { cameras = it }
        }
    }

    if (script?.autoConnect == true) {
        LaunchedEffect(script) { connect(CameraDiscovery.NIKON_ZR_ACCESS_POINT_HOST) }
    }

    val busy = phase == PairingPhase.Joining || phase == PairingPhase.Connecting
    val statusTitle =
        when {
            phase == PairingPhase.Joining -> "Joining"
            phase == PairingPhase.Connecting -> "Connecting"
            flow.step == PairingStep.DISCOVER -> "Looking"
            else -> "Ready"
        }

    Box(Modifier.fillMaxSize().startupBackdrop()) {
        Column(
            Modifier.fillMaxSize()
                .windowInsetsPadding(WindowInsets.safeDrawing)
                .padding(horizontal = 24.dp, vertical = 12.dp)
        ) {
            StartupHeader(
                title = "Connection setup",
                statusTitle = statusTitle,
                isBusy = busy || flow.step == PairingStep.DISCOVER,
            )
            Spacer(Modifier.height(12.dp))
            BoxWithConstraints(Modifier.weight(1f)) {
                val viewportWidth = maxWidth
                val twoColumn = viewportWidth >= 640.dp
                val introWidth = maxOf(236.dp, viewportWidth * 0.28f)
                if (twoColumn) {
                    val compactStep = viewportWidth - introWidth - 16.dp < 400.dp
                    Row(horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                        IntroCard(
                            flow = flow,
                            modifier = Modifier.width(introWidth).fillMaxSize(),
                        )
                        StepCard(
                            flow = flow,
                            phase = phase,
                            permissionGranted = permissionGranted,
                            permissionDenied = permissionDenied,
                            ssidField = ssidField,
                            onSsidChange = { ssidField = it },
                            keyField = keyField,
                            onKeyChange = { keyField = it },
                            keyWasRemembered = keyWasRemembered,
                            cameras = cameras,
                            onRequestPermission = ::requestPairingPermission,
                            onChoose = { flow = flow.choose(it) },
                            onAdvance = { flow = flow.advance() },
                            onRetreat = {
                                phase = PairingPhase.Idle
                                flow = flow.retreat()
                            },
                            onJoin = ::joinCameraAp,
                            onConnectCamera = { connect(it.host) },
                            onCancel = ::cancelWork,
                            compact = compactStep,
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
                            onSsidChange = { ssidField = it },
                            keyField = keyField,
                            onKeyChange = { keyField = it },
                            keyWasRemembered = keyWasRemembered,
                            cameras = cameras,
                            onRequestPermission = ::requestPairingPermission,
                            onChoose = { flow = flow.choose(it) },
                            onAdvance = { flow = flow.advance() },
                            onRetreat = {
                                phase = PairingPhase.Idle
                                flow = flow.retreat()
                            },
                            onJoin = ::joinCameraAp,
                            onConnectCamera = { connect(it.host) },
                            onCancel = ::cancelWork,
                            compact = viewportWidth < 480.dp,
                            modifier = Modifier.weight(1f).fillMaxWidth(),
                        )
                    }
                }
            }
        }
    }
}

// MARK: - Left column

@Composable
private fun IntroCard(flow: PairingFlowState, modifier: Modifier = Modifier) {
    // Vertical budget is tight in the ~360dp-tall landscape band — sizes are
    // trimmed from the iOS 32pt title so the footer never clips the card edge.
    Column(modifier.startupCard().padding(horizontal = 20.dp, vertical = 16.dp)) {
        Text(
            "FIRST RUN",
            color = StartupColors.muted,
            fontSize = 11.sp,
            fontWeight = FontWeight.SemiBold,
            letterSpacing = 1.4.sp,
        )
        Spacer(Modifier.height(8.dp))
        Text(
            "Pair your camera.",
            color = StartupColors.ink,
            fontSize = 24.sp,
            fontWeight = FontWeight.Bold,
            lineHeight = 27.sp,
        )
        Spacer(Modifier.height(8.dp))
        Text(
            "We'll walk you through it — your camera is connected in about a minute.",
            color = StartupColors.muted,
            fontSize = 12.sp,
            lineHeight = 16.sp,
        )
        Spacer(Modifier.weight(1f))
        StartupWizardProgress(currentStep = flow.displayStepNumber, totalSteps = flow.stepCount)
        Spacer(Modifier.height(8.dp))
        Text(
            PairingCopy.introFooter(flow.step),
            color = StartupColors.dim,
            fontSize = 11.sp,
            lineHeight = 15.sp,
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
    keyWasRemembered: Boolean,
    cameras: List<DiscoveredCamera>,
    onRequestPermission: () -> Unit,
    onChoose: (PairingPath) -> Unit,
    onAdvance: () -> Unit,
    onRetreat: () -> Unit,
    onJoin: () -> Unit,
    onConnectCamera: (DiscoveredCamera) -> Unit,
    onCancel: () -> Unit,
    compact: Boolean,
    modifier: Modifier = Modifier,
) {
    Column(modifier.startupCard().padding(20.dp)) {
        Text(
            "STEP ${flow.displayStepNumber} OF ${flow.stepCount}",
            color = StartupColors.muted,
            fontSize = 11.sp,
            fontWeight = FontWeight.SemiBold,
            letterSpacing = 1.4.sp,
        )
        Spacer(Modifier.height(6.dp))
        Text(
            PairingCopy.stepTitle(flow.step),
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
                    PairingStep.CHOOSE_PATH -> ChoosePathBody(onChoose, compact)
                    PairingStep.PREPARE -> NumberedCards(PairingCopy.prepareSteps(flow.path))
                    PairingStep.NETWORK ->
                        NetworkBody(
                            path = flow.path,
                            ssidField = ssidField,
                            onSsidChange = onSsidChange,
                            keyField = keyField,
                            onKeyChange = onKeyChange,
                            keyWasRemembered = keyWasRemembered,
                        )
                    PairingStep.DISCOVER -> DiscoverBody(cameras, onConnectCamera)
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
                StartupOutlineButton("Cancel", onClick = onCancel, modifier = Modifier.width(116.dp))
            }
        } else if (flow.step != PairingStep.CHOOSE_PATH) {
            Row(
                Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                if (flow.canRetreat) {
                    StartupOutlineButton(
                        "Back",
                        onClick = onRetreat,
                        modifier = Modifier.width(116.dp),
                    )
                }
                if (!compact) Spacer(Modifier.weight(1f))
                when {
                    flow.step == PairingStep.NETWORK &&
                        flow.path == PairingPath.CAMERA_ACCESS_POINT ->
                        StartupFilledButton(
                            "Join camera Wi‑Fi",
                            enabled = ssidField.isNotBlank(),
                            onClick = onJoin,
                            modifier =
                                if (compact) Modifier.weight(1f) else Modifier.width(220.dp),
                        )
                    !flow.isFinalStep ->
                        StartupFilledButton(
                            "Continue",
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
                "Joining the camera's Wi‑Fi network…"
            } else {
                "Connecting to your camera…"
            },
            color = StartupColors.ink,
            fontSize = 15.sp,
            fontWeight = FontWeight.SemiBold,
        )
        Text(
            if (phase == PairingPhase.Joining) {
                "Android asks you to confirm the connection the first time."
            } else {
                "Keep the camera powered on — this takes a few seconds."
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
                        PairingCopy.permissionTitle,
                        color = StartupColors.ink,
                        fontSize = 15.sp,
                        fontWeight = FontWeight.SemiBold,
                    )
                    Spacer(Modifier.height(2.dp))
                    Text(
                        PairingCopy.permissionDetail,
                        color = StartupColors.muted,
                        fontSize = 12.sp,
                        lineHeight = 16.sp,
                    )
                }
                Spacer(Modifier.width(8.dp))
                when {
                    granted -> StatusPill("Allowed", StartupColors.ready)
                    denied -> StatusPill("Settings", StartupColors.muted)
                    else ->
                        Text(
                            "Allow",
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
                "Required to connect to your camera — grant it to continue.",
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
private fun ChoosePathBody(onChoose: (PairingPath) -> Unit, compact: Boolean) {
    // Tight vertical budget: both cards must clear the card fold without
    // scrolling on the ~180dp step body of a 720px-tall landscape panel. On a
    // narrow portrait viewport they stack inside the body's existing scroll.
    if (compact) {
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            for (path in PairingPath.entries) {
                PathChoiceCard(path, onChoose, Modifier.fillMaxWidth())
            }
        }
    } else {
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            for (path in PairingPath.entries) {
                PathChoiceCard(path, onChoose, Modifier.weight(1f))
            }
        }
    }
}

@Composable
private fun PathChoiceCard(
    path: PairingPath,
    onChoose: (PairingPath) -> Unit,
    modifier: Modifier,
) {
    Column(
        modifier
            .startupTile()
            .clickable { onChoose(path) }
            .padding(horizontal = 12.dp, vertical = 10.dp)
    ) {
        Text(
            PairingCopy.pathTitle(path),
            color = StartupColors.ink,
            fontSize = 15.sp,
            fontWeight = FontWeight.Bold,
        )
        Spacer(Modifier.height(6.dp))
        Text(
            PairingCopy.pathBadge(path),
            color = StartupColors.accent,
            fontSize = 12.sp,
            fontWeight = FontWeight.SemiBold,
            modifier =
                Modifier.clip(CircleShape)
                    .background(StartupColors.accent.copy(alpha = 0.15f))
                    .padding(horizontal = 9.dp, vertical = 3.dp),
        )
        Spacer(Modifier.height(7.dp))
        Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
            for (pro in PairingCopy.pathPros(path)) {
                TradeoffRow("+", StartupColors.ready, pro)
            }
            TradeoffRow("−", StartupColors.dim, PairingCopy.pathCon(path))
        }
    }
}

@Composable
private fun TradeoffRow(symbol: String, color: androidx.compose.ui.graphics.Color, text: String) {
    Row(horizontalArrangement = Arrangement.spacedBy(7.dp)) {
        Text(symbol, color = color, fontSize = 12.sp, fontWeight = FontWeight.Bold)
        Text(text, color = StartupColors.muted, fontSize = 12.sp, lineHeight = 16.sp)
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
                        "${index + 1}",
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
    keyWasRemembered: Boolean,
) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(
            PairingCopy.networkSubtitle(path, keyRemembered = keyWasRemembered),
            color = StartupColors.muted,
            fontSize = 13.sp,
            lineHeight = 18.sp,
        )
        // Camera-AP: the subtitle already tells the operator where the SSID and
        // key are — the entry fields must sit above the scroll fold, so no
        // camera instruction card here (iOS "tight" mode collapses it too).
        if (path == PairingPath.PHONE_HOTSPOT) {
            DeviceInstructionCard(
                label = "ON CAMERA",
                steps = PairingCopy.hotspotCameraSteps,
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
                    "ON THIS PHONE",
                    color = StartupColors.muted,
                    fontSize = 10.sp,
                    fontWeight = FontWeight.Bold,
                    letterSpacing = 1.2.sp,
                )
                StartupTextField(
                    value = ssidField,
                    onValueChange = onSsidChange,
                    placeholder = "Network SSID (${CameraDiscovery.NIKON_ZR_SSID_PREFIX}…)",
                )
                StartupTextField(
                    value = keyField,
                    onValueChange = onKeyChange,
                    placeholder = "Network key",
                    password = true,
                )
            }
        }
    }
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
                    "${index + 1}",
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
    cameras: List<DiscoveredCamera>,
    onConnectCamera: (DiscoveredCamera) -> Unit,
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
                    "Waiting for the camera to join this phone's hotspot",
                    color = StartupColors.ink,
                    fontSize = 13.sp,
                    fontWeight = FontWeight.SemiBold,
                )
                Text(
                    "The camera appears here a few seconds after it joins.",
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
                            "Wi‑Fi · nearby",
                            color = StartupColors.muted,
                            fontSize = 11.sp,
                        )
                    }
                    Text(
                        "Connect",
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

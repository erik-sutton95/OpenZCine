package com.opencapture.openzcine

import android.content.Intent
import android.content.pm.ApplicationInfo
import android.graphics.Color
import android.net.nsd.NsdManager
import android.os.Bundle
import android.view.KeyEvent
import android.view.WindowManager
import android.widget.Toast
import androidx.activity.SystemBarStyle
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.ui.res.stringResource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.delay
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.ContentScale
import androidx.core.splashscreen.SplashScreen.Companion.installSplashScreen
import java.util.concurrent.atomic.AtomicBoolean
import com.opencapture.opencine.nikon.CameraSession
import com.opencapture.opencine.nikon.CameraSessionState
import com.opencapture.openzcine.bridge.SwiftCore
import com.opencapture.openzcine.bridge.SwiftCoreSmoke
import com.opencapture.openzcine.bridge.AndroidLinkHealthMonitor
import com.opencapture.opencine.nikon.SwiftCoreCameraSession
import com.opencapture.opencine.nikon.SwiftCoreLiveFrameSource
import com.opencapture.opencine.nikon.LiveFrameSource
import com.opencapture.openzcine.frameio.AndroidFrameioCameraApHop
import com.opencapture.openzcine.frameio.FrameioInternetHopState
import com.opencapture.openzcine.frameio.FrameioRedirectCallback
import com.opencapture.openzcine.frameio.frameioDeliveryController
import com.opencapture.openzcine.diagnostics.AndroidAppDiagnostics
import com.opencapture.openzcine.diagnostics.AndroidBugReportClient
import com.opencapture.openzcine.diagnostics.AndroidDiagnosticEvent
import com.opencapture.openzcine.diagnostics.AndroidSystemSettingsActions
import com.opencapture.openzcine.media.AndroidMediaGalleryGateway
import com.opencapture.openzcine.media.MediaBrowseScreen
import com.opencapture.openzcine.media.MediaCacheStore
import com.opencapture.openzcine.media.MediaDeliveryCompletionToast
import com.opencapture.openzcine.media.MediaDeliveryCoordinator
import com.opencapture.openzcine.media.MediaDeliveryProgressOverlay
import com.opencapture.openzcine.media.MediaLibraryCameraBucket
import com.opencapture.openzcine.media.MediaLibraryCategory
import com.opencapture.openzcine.media.MediaLibraryIndex
import com.opencapture.openzcine.media.SharedPreferencesMediaLibraryPreferences
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.windowInsetsPadding
import com.opencapture.openzcine.lut.AndroidLutLibrary
import com.opencapture.openzcine.pairing.PairedCamera
import com.opencapture.openzcine.pairing.PairingExperience
import com.opencapture.openzcine.pairing.ConnectedNetworkName
import com.opencapture.openzcine.pairing.SavedCameraRecords
import com.opencapture.openzcine.pairing.SavedCameraRecord
import com.opencapture.openzcine.pairing.SavedCameraTransport
import com.opencapture.openzcine.pairing.AppNikonConnectPort
import com.opencapture.openzcine.pairing.CameraWifiScannerOverlay
import com.opencapture.openzcine.pairing.FILTER_NOTICE_ID
import com.opencapture.openzcine.pairing.RELAY_ROW_PREFIX
import com.opencapture.openzcine.pairing.SavedCameraConnector
import com.opencapture.openzcine.pairing.isOnCameraAccessPointNetwork
import com.opencapture.openzcine.pairing.isWifiRadioEnabled
import com.opencapture.openzcine.pairing.WifiOffPromptDialog
import com.opencapture.openzcine.pairing.attachedUsbAutoReconnectSuppressions
import com.opencapture.openzcine.pairing.mayAutoReconnectUsb
import com.opencapture.openzcine.pairing.nearbyBroadcastItems
import com.opencapture.openzcine.pairing.nikonIntegrationSlots
import com.opencapture.openzcine.pairing.CAMERAS_DOCUMENT_PREFERENCES
import com.opencapture.openzcine.pairing.nikonCamerasStore
import com.opencapture.openzcine.pairing.recordsAfterSharedEdit
import com.opencapture.openzcine.pairing.recordsForgetting
import com.opencapture.monitorui.MonitorPalette
import com.opencapture.opencine.appkit.AppIntegration
import com.opencapture.opencine.appkit.CamerasModel
import com.opencapture.opencine.appkit.ShellModel
import com.opencapture.opencine.appkit.MonitorControlModel
import com.opencapture.opencine.core.ConnectedCamera
import com.opencapture.opencine.core.IntegrationID
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.currentStateAsState
import androidx.lifecycle.Lifecycle
import com.opencapture.opencine.appkit.CamerasScreen
import com.opencapture.opencine.core.ConnectTarget
import com.opencapture.opencine.core.RecoveryAction
import com.opencapture.opencine.core.RouteDraft
import com.opencapture.opencine.core.RouteKind
import com.opencapture.opencine.core.SavedCamera
import com.opencapture.opencine.nikon.NikonIntegration
import com.opencapture.opencine.nikon.NikonSavedRecordsV0
import com.opencapture.openzcine.multicam.LocalMulticamReturn
import com.opencapture.openzcine.multicam.MulticamCoordinator
import com.opencapture.openzcine.multicam.MulticamPickerRow
import com.opencapture.openzcine.multicam.MulticamStage
import com.opencapture.openzcine.multicam.multicamDecoder
import com.opencapture.openzcine.multicam.multicamLink
import com.opencapture.openzcine.transport.UsbPtpCameraAccess
import com.opencapture.openzcine.pairing.SharedPreferencesSavedCameraStore
import com.opencapture.openzcine.transport.WifiLowLatencyLock
import com.opencapture.openzcine.pairing.realPairingEnvironment
import com.opencapture.openzcine.pairing.usbAutoReconnectSuppressionAfterUserAction
import com.opencapture.openzcine.relay.RelayPresence
import com.opencapture.openzcine.transport.CameraListDiscovery
import com.opencapture.openzcine.relay.mergedNearbyBroadcasts
import com.opencapture.openzcine.relay.presenceProvesFiltering
import com.opencapture.openzcine.relay.updatedPresenceHiddenSince
import com.opencapture.openzcine.remote.AndroidMediaRemoteShutter
import com.opencapture.openzcine.settings.LiveViewQualityBias
import com.opencapture.openzcine.settings.LiveViewStreamPreset
import com.opencapture.openzcine.settings.OperatorSettings
import com.opencapture.openzcine.settings.OperatorSettingsScreen
import com.opencapture.openzcine.settings.OperatorSettingsTab
import com.opencapture.openzcine.settings.SetupStreamSettings
import com.opencapture.openzcine.transport.AndroidNsdBrowser
import com.opencapture.openzcine.transport.NsdCameraSessionFactory
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import com.opencapture.opencine.nikon.NikonNative
import com.opencapture.opencine.appkit.rememberOperatorHaptics
import com.opencapture.opencine.appkit.LocalOperatorHaptics

/** A consented Frame.io network hop exclusively owns disconnect/reconnect until it settles. */
private fun FrameioInternetHopState.allowsMonitorSessionRecovery(): Boolean =
    this is FrameioInternetHopState.Idle || this is FrameioInternetHopState.Rejoined

/**
 * App entry point: persisted cameras open the reconnect home; first-run and
 * add-camera flows use the camera-AP / phone-hotspot pairing wizard, then
 * hand the verified [CameraSession] to the monitor shell. Debug hooks (demo
 * feed, NSD transport probe) bypass startup straight to the monitor.
 */
class MainActivity : ComponentActivity() {
    private lateinit var mediaRemoteShutter: AndroidMediaRemoteShutter
    private val diagnostics: AndroidAppDiagnostics by lazy {
        AndroidAppDiagnostics.create(applicationContext)
    }

    // A replayable activity-local callback is enough for both a cold launch and
    // an existing singleTop task. The controller validates the exact URI and
    // PKCE state before it ever makes a network request.
    private val frameioRedirectCallback = MutableStateFlow<FrameioRedirectCallback?>(null)

    /**
     * Holds the solid system SplashScreen until the first Compose frame so we
     * never flash a second (platform) logo — only [LaunchSplashOverlay] brands.
     */
    private val composeFirstFrameDrawn = AtomicBoolean(false)

    override fun onCreate(savedInstanceState: Bundle?) {
        val splashScreen = installSplashScreen()
        splashScreen.setKeepOnScreenCondition { !composeFirstFrameDrawn.get() }
        super.onCreate(savedInstanceState)
        // Load the Swift core (and with it OpenCine's NikonNative) before any camera session.
        SwiftCore.isAvailable
        mediaRemoteShutter = AndroidMediaRemoteShutter(applicationContext)
        diagnostics.record(AndroidDiagnosticEvent.APP_LAUNCHED)
        publishFrameioRedirect(intent)
        if (BuildConfig.DEBUG) SwiftCoreSmoke.run()
        // Camera-monitor chrome owns the whole panel, like the iOS shell:
        // sticky-immersive system bars (hidden; a swipe reveals them
        // transiently and they re-hide), forced-dark transparent bar styling
        // so the transient overlay is never an opaque white band, and
        // shortEdges cutout mode so the feed draws under the punch-hole (the
        // cutout arrives as a safe-area inset for the zone map).
        enableEdgeToEdge(
            statusBarStyle = SystemBarStyle.dark(Color.TRANSPARENT),
            navigationBarStyle = SystemBarStyle.dark(Color.TRANSPARENT),
        )
        window.isNavigationBarContrastEnforced = false
        window.attributes.layoutInDisplayCutoutMode =
            WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
        val demo = DemoHarness.demoLiveFeed(intent, applicationContext)
        val debugAssistEffects = DemoHarness.assistEffects(intent)
        val debugScopes = DemoHarness.scopeKinds(intent)
        val debugPortraitAspect = DemoHarness.portraitFeedAspect(intent)
        val debugLiveGuideStep = DemoHarness.liveGuideStep(intent)
        val debugInitialSettingsTab = DemoHarness.settingsTab(intent)
        val debugSession: CameraSession? =
            demo?.first ?: if (isNsdTransportRequested()) nsdTransportSession() else null
        val pairingScript = DemoHarness.pairingScript(intent)
        val debugSplitComparison = DemoHarness.splitComparison(intent)
        val operatorSettings =
            OperatorSettings(applicationContext).also { settings ->
                debugPortraitAspect?.let { settings.portraitFeedAspect = it }
            }
        // Screenshot affordance: open the Edit view straight away (zc.demo.chromeEdit).
        DemoHarness.chromeEditMode(intent)?.let(operatorSettings::beginChromeEditing)
        setContent {
            // Drop the solid system hold as soon as Compose paints; the only
            // branded splash is LaunchSplashOverlay (rounded logo + wordmark).
            SideEffect { composeFirstFrameDrawn.set(true) }
            OpenZCineTheme {
                val operatorHaptics =
                    rememberOperatorHaptics { operatorSettings.hapticsEnabled.value }
                CompositionLocalProvider(LocalOperatorHaptics provides operatorHaptics) {
                Box(Modifier.fillMaxSize()) {
                var monitorSession by remember { mutableStateOf(debugSession) }
                // The HDMI capture feed beside a capture-only session. Non-null
                // exactly while the monitor is on the HDMI path; closed (CameraX
                // unbind) whenever the monitor exits.
                var uvcSource by remember { mutableStateOf<UvcFrameSource?>(null) }
                // A monitor reached from a saved card retains that exact
                // profile. Link settings may then leave the monitor without
                // guessing a topology or constructing a second session.
                var activeSavedCamera by remember { mutableStateOf<SavedCameraRecord?>(null) }
                // The row the running pairing CREATED, so walking away from it takes the row back
                // out — the wizard saves before the body confirmation. Null once anything
                // connected through it, or when the pairing refreshed a setup that already
                // existed. Twin of iOS `pairingCreatedRecordHost`.
                var pairingCreatedSetup by remember { mutableStateOf<SavedCameraRecord?>(null) }
                var requestedReconnectID by rememberSaveable { mutableStateOf<String?>(null) }
                var suppressedUsbAutoReconnectHosts by remember { mutableStateOf(emptySet<String>()) }
                val connectionScope = rememberCoroutineScope()
                val shellSessions = remember(connectionScope) { NikonShellSessions(connectionScope) }
                // The monitor relay ("multicast") — iOS parity: this device can WATCH another
                // device's broadcast, and BROADCAST its own feed to watchers.
                var watchController by
                    remember { mutableStateOf<com.opencapture.openzcine.relay.RelayWatchController?>(null) }
                var relayBroadcastEnabled by remember { mutableStateOf(false) }
                val relayDeviceName =
                    remember {
                        android.provider.Settings.Global.getString(
                            contentResolver, "device_name"
                        )
                            ?.takeIf(String::isNotBlank) ?: android.os.Build.MODEL
                    }
                val relayBroadcastController =
                    remember {
                        val portPrefs =
                            applicationContext.getSharedPreferences(
                                "relay_broadcast", MODE_PRIVATE)
                        com.opencapture.openzcine.relay.RelayBroadcastController(
                            scope = connectionScope,
                            nsdManager = getSystemService(NsdManager::class.java),
                            deviceName = relayDeviceName,
                            loadPreferredPort = { portPrefs.getInt("listenerPort", 0) },
                            savePreferredPort = { port ->
                                portPrefs.edit().putInt("listenerPort", port).apply()
                            },
                        )
                    }
                val relayBroadcastUi by relayBroadcastController.ui.collectAsState()
                // The A12-class jpeg-only verdict survives relaunches so the first join skips
                // the ~45 s HEVC decode probe. Scoped to this exact install (lastUpdateTime):
                // any reinstall may carry a stream profile the hardware CAN decode and probes
                // again — versionCode alone never changes between debug installs.
                val relayCodecPrefs =
                    remember {
                        applicationContext.getSharedPreferences("relay_codec", MODE_PRIVATE)
                    }
                val installStamp =
                    remember {
                        packageManager.getPackageInfo(packageName, 0).lastUpdateTime
                    }
                val persistJpegOnly: () -> Unit = remember {
                    {
                        relayCodecPrefs.edit().putLong("jpegOnlyInstall", installStamp).apply()
                    }
                }
                LaunchedEffect(Unit) {
                    if (relayCodecPrefs.getLong("jpegOnlyInstall", -1L) == installStamp) {
                        com.opencapture.openzcine.relay.RelayWatchController.seedJpegOnly()
                    }
                }
                // Watcher passcodes, one entry per broadcaster name — the durable half of the
                // controller's process-wide memory (it is rebuilt on every join, so alone it
                // forgets at launch). iOS keeps the same dictionary in UserDefaults
                // (`storedRelayPasscode(forHost:)`). NOT install-scoped like the jpeg-only
                // verdict above: a set's passcode does not change because this app was rebuilt.
                val relayPasscodePrefs =
                    remember {
                        applicationContext.getSharedPreferences("relay_passcodes", MODE_PRIVATE)
                    }
                val persistWatcherPasscode: (String, String) -> Unit = remember {
                    { broadcasterName, code ->
                        relayPasscodePrefs.edit().putString(broadcasterName, code).apply()
                    }
                }
                LaunchedEffect(Unit) {
                    com.opencapture.openzcine.relay.RelayWatchController.seedPasscodes(
                        relayPasscodePrefs.all
                            .mapNotNull { (name, code) -> (code as? String)?.let { name to it } }
                            .toMap()
                    )
                }
                LaunchedEffect(Unit) {
                    // Debug-only direct watch (adb reverse cross-platform verification).
                    DemoHarness.relayWatchEndpoint(intent)?.let { (host, port) ->
                        // Named once: the passcode is stored under this exact name and read back
                        // by it, so a second literal is a silently-forgotten code waiting to
                        // happen.
                        val direct =
                            com.opencapture.openzcine.relay.RelayBroadcast(
                                name = "Direct",
                                host = host,
                                port = port,
                                servedCameraHost = null,
                            )
                        watchController =
                            com.opencapture.openzcine.relay.RelayWatchController(
                                    scope = connectionScope,
                                    deviceName = relayDeviceName,
                                    broadcast = direct,
                                    watcherId =
                                        com.opencapture.openzcine.relay.RelayWatcherIdentity
                                            .current(applicationContext),
                                    onPasscodeRemembered = { code ->
                                        persistWatcherPasscode(direct.name, code)
                                    },
                                )
                                .also { it.start() }
                    }
                }
                val savedCameraStore =
                    remember { SharedPreferencesSavedCameraStore(applicationContext) }
                // The app-private LUT library owns transient SAF import and Swift-packed render
                // payloads. It is deliberately process-local; only generated selections persist.
                val lutLibrary = remember { AndroidLutLibrary(applicationContext) }
                val mediaCacheStore =
                    remember {
                        MediaCacheStore(
                            applicationContext.noBackupFilesDir.resolve("media-cache").toPath(),
                        )
                    }
                val mediaLibraryIndex =
                    remember {
                        MediaLibraryIndex(
                            SharedPreferencesMediaLibraryPreferences(applicationContext),
                        )
                    }
                val frameioController =
                    remember { frameioDeliveryController(applicationContext, lutLibrary) }
                // The root releases the delivery owners before their supplied scope.
                val deliveryScope = remember(frameioController) {
                    CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
                }
                // App-scoped share/export progress (iOS MediaDeliveryCoordinator).
                val mediaDeliveryCoordinator =
                    remember(frameioController) {
                        MediaDeliveryCoordinator(
                            appContext = applicationContext,
                            frameioController = frameioController,
                            galleryGateway =
                                AndroidMediaGalleryGateway(
                                    applicationContext.contentResolver,
                                    DemoHarness.galleryFailureInjection(intent),
                                ),
                            scope = deliveryScope,
                        )
                    }
                DisposableEffect(mediaDeliveryCoordinator) {
                    onDispose {
                        mediaDeliveryCoordinator.close()
                        deliveryScope.cancel()
                    }
                }
                val deliveryDisplay by mediaDeliveryCoordinator.display.collectAsState()
                val liveViewGuide =
                    remember {
                        LiveViewGuideController(applicationContext, diagnostics::record)
                    }
                val systemSettingsActions =
                    remember {
                        AndroidSystemSettingsActions(this@MainActivity, diagnostics)
                    }
                val bugReportSubmitter =
                    remember {
                        AndroidBugReportClient(applicationContext)
                    }
                LaunchedEffect(debugLiveGuideStep) {
                    debugLiveGuideStep?.let(liveViewGuide::forceForDebug)
                }
                val frameioRedirect by frameioRedirectCallback.collectAsState()
                LaunchedEffect(frameioController, frameioRedirect) {
                    frameioRedirect?.let { callback ->
                        frameioController.completeRedirect(callback.uri)
                        if (frameioRedirectCallback.value === callback) {
                            frameioRedirectCallback.value = null
                        }
                    }
                }
                var savedCameras by remember { mutableStateOf(savedCameraStore.records()) }
                // Every complete on-device cache, for the startup Media Library
                // (iOS `openCachedMediaLibrary` / listAllCachedClips).
                var completedMediaBuckets by
                    remember { mutableStateOf(emptyMap<String, MediaLibraryCameraBucket>()) }
                var mediaCacheRevision by remember { mutableStateOf(0) }
                // Keep the process-wide camera-AP binding alive while its
                // handed-off session is active, then release it alongside the
                // PTP slot when this activity or session leaves composition.
                // Creating this once also prevents recomposition from
                // orphaning a CameraApJoiner callback.
                val pairingEnvironment =
                    remember(pairingScript) {
                        pairingScript?.environment
                            ?: realPairingEnvironment(applicationContext) { phase, detail ->
                                if (phase == "connect.gate") {
                                    diagnostics.recordConnectTrace(detail)
                                    return@realPairingEnvironment
                                }
                                // Closed phase tokens only; free-form detail is discarded here.
                                AndroidDiagnosticEvent.fromPhase(phase)?.let {
                                    diagnostics.record(it)
                                }
                            }
                    }
                // USB attach/detach must stay observed while a handed-off
                // session is on the monitor; close the Android receiver only
                // when this activity's whole Compose tree leaves.
                DisposableEffect(pairingEnvironment) {
                    onDispose { pairingEnvironment.usbCameraSource?.close() }
                }
                // Multicam (NIKON-01): up to four bodies on the shared OpenCineMulticam engine,
                // each on its own saved-profile session beside the single-camera monitor.
                val multicam =
                    remember(pairingEnvironment) {
                        MulticamCoordinator(
                            scope = connectionScope,
                            connect = { record ->
                                withContext(Dispatchers.IO) { multicamLink(record, pairingEnvironment) }
                            },
                            decoder = ::multicamDecoder,
                        )
                    }
                // iOS showsCameraListWithoutSavedCameras: once a watcher-only device
                // asks for the camera list, an empty saved list stops forcing the
                // wizard — that's where nearby broadcasts live.
                var watcherListRequested by rememberSaveable { mutableStateOf(false) }
                // Branded launch splash (iOS `LaunchSplashTiming`: fully
                // visible 2250ms, then a 350ms ease-out fade). Debug demo and
                // scripted launches skip it so screenshots stay deterministic.
                var launchSplashVisible by
                    rememberSaveable {
                        // Debug settings deep-links skip splash so tab screenshots stay deterministic
                        // (mirrors demo/scripted launches).
                        mutableStateOf(
                            debugSession == null &&
                                pairingScript == null &&
                                debugInitialSettingsTab == null,
                        )
                    }
                LaunchedEffect(Unit) {
                    if (launchSplashVisible) {
                        delay(2_250)
                        launchSplashVisible = false
                    }
                }
                /**
                 * Saves a Nikon-confirmed profile before the temporary pairing
                 * session is released. The monitor is deliberately not entered
                 * here: [PairingExperience] must reconnect with this profile
                 * after the camera applies its body-side confirmation.
                 */
                fun persistPairedCameraProfile(saved: SavedCameraRecord): SavedCameraRecord {
                    val before = savedCameras
                    val updated =
                        SavedCameraRecords.upserting(
                            host = saved.host,
                            cameraName = saved.cameraName,
                            transport = saved.transport,
                            lastSeenAtEpochMillis = saved.lastSeenAtEpochMillis,
                            wifiSsid = saved.wifiSsid,
                            records = savedCameras,
                            // Read at SAVE time, which is the only moment this device is
                            // demonstrably on the network the setup describes. Null whenever the
                            // operator has not allowed the read, and an unnamed network joins
                            // whatever router setup exists — the behaviour everyone had before.
                            networkName = ConnectedNetworkName.read(this@MainActivity),
                        )
                    savedCameras = updated
                    savedCameraStore.replace(updated)
                    // The wizard saves here BEFORE the body confirmation, so remember a row this
                    // pairing created — an abandoned pairing takes it back out again. A camera
                    // that already had this setup refreshed a row instead, and that one is not
                    // ours to remove: a failed re-pair must never cost a working setup.
                    pairingCreatedSetup = SavedCameraRecords.createdSetup(before, updated)
                    return updated.firstOrNull { candidate ->
                            candidate.transport == saved.transport &&
                                (
                                    candidate.host == saved.host ||
                                        SavedCameraRecords.cameraNamesMatch(
                                            candidate.cameraName,
                                            saved.cameraName,
                                        )
                                )
                        } ?: saved
                }

                /**
                 * Points the operator's stream-settings picks at ONE setup's record, and seeds
                 * the live values from it. Twin of iOS `adoptActiveSetupStreamSettings` /
                 * `recordActiveSetupStreamSettings`.
                 */
                fun adoptSetupStreamSettings(record: SavedCameraRecord?) {
                    if (record == null) {
                        operatorSettings.activeSetupStreamSettingsWriter = null
                        return
                    }
                    operatorSettings.adoptSetupStreamSettings(
                        streamPreset =
                            SetupStreamSettings.streamPreset(
                                stored = record.streamPreset,
                                transport = record.transport,
                                seed = LiveViewStreamPreset.SHIPPED_DEFAULT,
                            ),
                        qualityBias =
                            SetupStreamSettings.qualityBias(
                                stored = record.qualityBias,
                                transport = record.transport,
                                seed = LiveViewQualityBias.SHIPPED_DEFAULT,
                            ),
                    )
                    operatorSettings.activeSetupStreamSettingsWriter = { preset, bias ->
                        val updated =
                            SavedCameraRecords.updatingStreamSettings(
                                host = record.host,
                                transport = record.transport,
                                streamPreset = preset,
                                qualityBias = bias,
                                records = savedCameras,
                            )
                        savedCameras = updated
                        savedCameraStore.replace(updated)
                    }
                }

                fun acceptPairedCamera(paired: PairedCamera) {
                    activeSavedCamera = persistPairedCameraProfile(paired.savedCamera)
                    // The pairing produced a working session, so its row has earned its place.
                    pairingCreatedSetup = null
                    adoptSetupStreamSettings(activeSavedCamera)
                    monitorSession = paired.session
                }

                /** Takes back a row the wizard saved for a pairing that never connected. */
                fun discardAbandonedPairingSetup() {
                    val created = pairingCreatedSetup ?: return
                    pairingCreatedSetup = null
                    // A live session means the setup earned its place whatever the card is doing.
                    if (monitorSession != null) return
                    val updated =
                        SavedCameraRecords.removing(
                            host = created.host,
                            cameraName = created.cameraName,
                            records = savedCameras,
                            transport = created.transport,
                        )
                    savedCameras = updated
                    savedCameraStore.replace(updated)
                }
                // The shared cameras page (SHELL-02): saved setups live in OpenCine's saved-camera
                // document ("openzcine.cameras"), mirrored to this app's own records, which its
                // connect, pairing and settings code keeps writing with its own rules; every such
                // write is merged into the document at once (onReplaced below).
                val savedCameraConnector =
                    remember(pairingEnvironment) {
                        SavedCameraConnector(
                            pairingEnvironment,
                            wifiEnabled = { isWifiRadioEnabled(applicationContext) },
                            onCameraAccessPoint = { isOnCameraAccessPointNetwork(applicationContext) },
                            scope = connectionScope,
                        )
                    }
                var scanningAccessPointFor by remember { mutableStateOf<SavedCamera?>(null) }
                var watchOnCameraApNoticeVisible by remember { mutableStateOf(false) }
                val nikonPort =
                    remember(savedCameraConnector) {
                        AppNikonConnectPort(
                            copy = { id, args -> applicationContext.getString(id, *args) },
                            connector = savedCameraConnector,
                            records = { savedCameras },
                            recordsJson = savedCameraStore::recordsJson,
                            onPaired = ::acceptPairedCamera,
                            onForget = { hosts ->
                                savedCameras = recordsForgetting(hosts, savedCameras, pairingEnvironment.credentials::remove)
                                savedCameraStore.replace(savedCameras)
                            },
                            onExplicitUsbReconnect = { host ->
                                suppressedUsbAutoReconnectHosts = suppressedUsbAutoReconnectHosts - host
                            },
                            scope = connectionScope,
                            offersDiagnostics = true,
                            commonSession = shellSessions::acquire,
                            commonServices = shellSessions::services,
                        )
                    }
                val camerasModel =
                    remember(nikonPort) {
                        CamerasModel(
                            listOf(
                                AppIntegration(
                                    NikonIntegration(nikonPort),
                                    nikonIntegrationSlots(
                                        savedCameraConnector,
                                        { savedCameras },
                                        pairingEnvironment.credentials,
                                        onScanAccessPoint = { scanningAccessPointFor = it },
                                    ),
                                ),
                            ),
                            // The shared page patched the records (a rename, a forgotten setup): this
                            // app reads them back, and a removed access-point setup takes its key.
                            nikonCamerasStore(
                                getSharedPreferences(CAMERAS_DOCUMENT_PREFERENCES, MODE_PRIVATE),
                                getSharedPreferences(SharedPreferencesSavedCameraStore.PREFERENCES_NAME, MODE_PRIVATE),
                            ) {
                                savedCameras =
                                    recordsAfterSharedEdit(savedCameras, savedCameraStore, pairingEnvironment.credentials::remove)
                            },
                            connectionScope,
                        ).also { model -> savedCameraStore.onReplaced = model::reloadSaved }
                    }
                val shell = remember(camerasModel, connectionScope) {
                    ShellModel(camerasModel, MonitorControlModel(connectionScope)).also {
                        it.control.onNote = { note -> android.widget.Toast.makeText(applicationContext, note, android.widget.Toast.LENGTH_SHORT).show() }
                        if (pairingScript != null) it.beginPairing()
                        if (debugInitialSettingsTab != null) it.open(ShellModel.Cover.SETTINGS)
                    }
                }
                val shellState by shell.state.collectAsState()
                LaunchedEffect(savedCameras, monitorSession, shellState.cover, mediaCacheRevision) {
                    if (monitorSession != null) return@LaunchedEffect
                    completedMediaBuckets =
                        withContext(Dispatchers.IO) {
                            mediaLibraryIndex
                                .completedCameraBuckets(
                                    savedCameras.map(SavedCameraRecord::id),
                                    mediaCacheStore,
                                ).associateBy(MediaLibraryCameraBucket::savedCameraID)
                        }
                }
                val sceneState by LocalLifecycleOwner.current.lifecycle.currentStateAsState()
                LaunchedEffect(sceneState) { shell.setSceneActive(sceneState.isAtLeast(Lifecycle.State.RESUMED)) }
                LaunchedEffect(monitorSession, activeSavedCamera) {
                    val native = monitorSession ?: return@LaunchedEffect
                    val borrowed = multicam.lentMember(native)
                    val common = borrowed?.control ?: shellSessions.acquire(native)
                    if (shell.state.value.monitor?.session?.id == common.id) return@LaunchedEffect
                    camerasModel.reloadSaved()
                    val saved = camerasModel.state.value.saved.firstOrNull { camera ->
                        camera.routes.any { it.extras[NikonSavedRecordsV0.Extra.PROFILE_ID] == activeSavedCamera?.profileID }
                    } ?: SavedCamera(
                        id = "monitor:${common.id}", integration = IntegrationID("nikon"),
                        advertisedName = activeSavedCamera?.cameraName ?: "Monitor", model = "")
                    val connected = ConnectedCamera(saved, common, shellSessions.services(native, common))
                    if (borrowed != null) {
                        shell.borrow(connected) {
                            monitorSession = null
                            multicam.reclaim()
                        }
                    } else {
                        shell.present(connected)
                    }
                }
                // A live session handed back (disconnect, drop): the shared page discovers again.
                LaunchedEffect(monitorSession == null) {
                    if (monitorSession == null) { shell.close(); camerasModel.sessionEnded() }
                }
                val camerasState by camerasModel.state.collectAsState()
                /** The saved camera and route that hold the app record with [profileID]. */
                fun savedRoute(profileID: String): Pair<SavedCamera, com.opencapture.opencine.core.ConnectionRouteID>? =
                    camerasState.saved.firstNotNullOfOrNull { camera ->
                        camera.routes
                            .firstOrNull { it.extras[NikonSavedRecordsV0.Extra.PROFILE_ID] == profileID }
                            ?.let { camera to it.id }
                    }
                // Link settings leaves the monitor asking for a reconnect of the same setup.
                LaunchedEffect(requestedReconnectID, camerasState.saved, camerasState.attempts.isEmpty()) {
                    val requestedID = requestedReconnectID ?: return@LaunchedEffect
                    if (camerasState.attempts.isNotEmpty() || monitorSession != null) return@LaunchedEffect
                    requestedReconnectID = null
                    savedRoute(requestedID)?.let { (camera, route) -> camerasModel.connect(camera, route) }
                }
                // One reconnect per real USB attachment of a saved cable setup (the key drops out
                // on detach, re-arming the next plug-in without retrying a refused body).
                var attemptedUsbReconnectHosts by remember { mutableStateOf(emptySet<String>()) }
                val usbCameras by savedCameraConnector.usbCameras.collectAsState()
                LaunchedEffect(usbCameras, savedCameras, camerasState.attempts.isEmpty(), suppressedUsbAutoReconnectHosts) {
                    val attached =
                        usbCameras.filter { it.access == UsbPtpCameraAccess.READY }.mapNotNull { it.hostKey }.toSet()
                    attemptedUsbReconnectHosts = attemptedUsbReconnectHosts.intersect(attached)
                    suppressedUsbAutoReconnectHosts = attachedUsbAutoReconnectSuppressions(suppressedUsbAutoReconnectHosts, attached)
                    if (camerasState.attempts.isNotEmpty() || monitorSession != null || requestedReconnectID != null) return@LaunchedEffect
                    val match =
                        savedCameras.firstOrNull {
                            mayAutoReconnectUsb(it, attached, attemptedUsbReconnectHosts, suppressedUsbAutoReconnectHosts)
                        } ?: return@LaunchedEffect
                    attemptedUsbReconnectHosts = attemptedUsbReconnectHosts + match.host
                    savedRoute(match.profileID)?.let { (camera, route) -> camerasModel.connect(camera, route) }
                }
                // Startup and monitor are both immersive; re-assert whenever
                // the surface changes so a transient swipe-reveal on one
                // surface never leaks bars onto the next.
                val immersive = monitorSession != null || shellState.cover == ShellModel.Cover.MEDIA
                LaunchedEffect(immersive) { applyImmersiveSystemBars() }
                // Wi-Fi power save costs a wake on every frame of a request/response pull loop,
                // and how aggressively it dozes is vendor firmware. Held only while a WIRELESS
                // session is actually on the monitor — a cable session has no radio to keep awake,
                // and the platform ignores the mode outside the foreground anyway.
                val wifiLowLatencyLock = remember { WifiLowLatencyLock(applicationContext) }
                val wirelessSessionLive =
                    monitorSession != null &&
                        activeSavedCamera?.transport.let {
                            it != null && it != SavedCameraTransport.USB_C
                        }
                DisposableEffect(wirelessSessionLive) {
                    if (wirelessSessionLive) wifiLowLatencyLock.acquire()
                    onDispose { wifiLowLatencyLock.release() }
                }
                LaunchedEffect(immersive, operatorSettings.keepScreenAwake.value) {
                    if (operatorSettings.shouldKeepScreenAwake(immersive)) {
                        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    } else {
                        window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    }
                }
                // Bind the HDMI capture device once its monitor session exists.
                // CameraX pauses/resumes delivery with the activity lifecycle on
                // its own; explicit close happens on monitor exit.
                val currentUvcSource = uvcSource
                LaunchedEffect(currentUvcSource) { currentUvcSource?.start(this@MainActivity) }
                val active = monitorSession
                val watching = watchController
                if (active == null && watching != null) {
                    val watchUi by watching.ui.collectAsState()
                    LaunchedEffect(watchUi.endedByBroadcaster) {
                        if (watchUi.endedByBroadcaster) {
                            val leaving = watching
                            watchController = null
                            connectionScope.launch { leaving.stop() }
                        }
                    }
                    val watchAssist =
                        remember(watching) {
                            restoreNikonAssists(applicationContext, availableStoredLut = lutLibrary::contains)
                        }
                    val leaveWatch: () -> Unit = {
                        val leaving = watching
                        watchController = null
                        connectionScope.launch { leaving.stop() }
                    }
                    // The watcher's Operator Setup (iOS: the same settings panel over the
                    // monitor with `videoSource == .relay`; its Disconnect routes through
                    // leaveRelay). Media stays unwired — iOS `mediaBrowser` needs an owned
                    // camera session, which a watcher never has.
                    var watchSettingsPresented by
                        remember(watching) { mutableStateOf(false) }
                    val watchCommon = remember(watching.session) { shellSessions.acquire(watching.session) }
                    val watchControl = remember(watchCommon) { MonitorControlModel(connectionScope).also { it.bind(watchCommon) } }
                    DisposableEffect(watchCommon) {
                        onDispose { watchControl.unbind(); shellSessions.retire(watching.session) }
                    }
                    Box(Modifier.fillMaxSize()) {
                        MonitorScreen(
                            watching.session,
                            commonSession = watchCommon,
                            commonControl = watchControl,
                            frameSource = watching.frameSource,
                            assists = watchAssist,
                            operatorSettings = operatorSettings,
                            lutLibrary = lutLibrary,
                            // Same stand-down as the connected monitor: the full-screen
                            // settings surface must not fight the feed decode for CPU/GPU
                            // on lower-tier phones.
                            liveViewEnabled = !watchSettingsPresented,
                            isMonitorFront = !watchSettingsPresented,
                            sessionRecoveryEnabled = false,
                            isDemoSession = false,
                            // The watcher chrome: readings mount, controls only with the token
                            // (iOS `monitorAvailability` on `videoSource == .relay`).
                            availability =
                                com.opencapture.openzcine.core.MonitorDataAvailability.watcher(
                                    holdsControl = watchUi.holdsControl
                                ),
                            relayedState = watchUi.state,
                            onOpenSettings = { watchSettingsPresented = true },
                            onOpenMedia = {},
                            onBackToOperatorMenu = leaveWatch,
                        )
                        if (!watchSettingsPresented) {
                            // Gated, not layered: composing the watch overlay under the
                            // settings surface would float its pill (and passcode dialog, a
                            // separate window) over the settings — iOS suppresses the
                            // on-glass key under the settings cover the same way.
                            com.opencapture.openzcine.relay.RelayWatchOverlay(
                                ui = watchUi,
                                onAskForControl = watching::requestControl,
                                onGiveBackControl = watching::releaseControl,
                                onSubmitPasscode = watching::submitPasscode,
                                onRetry = watching::retry,
                                onLeave = leaveWatch,
                            )
                        } else {
                            OperatorSettingsScreen(
                                session = watching.session,
                                assists = watchAssist,
                                settings = operatorSettings,
                                mediaCacheStore = mediaCacheStore,
                                frameioController = frameioController,
                                // The Link tab's "Held By" reads the token off this state.
                                // Without it the row falls back to "The broadcaster" forever —
                                // including while THIS device holds control, which is the one
                                // moment the row exists to report (iOS `linkRows`).
                                relayWatchUi = watchUi,
                                systemSettingsActions = systemSettingsActions,
                                bugReportSubmitter = bugReportSubmitter,
                                bugReportActivityLogProvider =
                                    diagnostics::privacyFilteredActivityLog,
                                liveViewGuideController = liveViewGuide,
                                onShowGuideOnNextRealFrame =
                                    liveViewGuide::replayOnNextRealFrame,
                                onCompletedMediaCacheCleared = {
                                    mediaLibraryIndex.clearCameraCatalogs()
                                    mediaCacheRevision += 1
                                },
                                // The watcher leaves from the session controls, exactly like
                                // iOS (`model.disconnect()` routes a relay viewer through
                                // leaveRelay).
                                onDisconnect = leaveWatch,
                                onClose = { watchSettingsPresented = false },
                            )
                            BackHandler { watchSettingsPresented = false }
                        }
                    }
                } else if (active == null && shellState.cover == ShellModel.Cover.MEDIA) {
                    val offlineBuckets = remember { completedMediaBuckets.values.toList() }
                    val primary = offlineBuckets.firstOrNull()
                    val offlineAssist =
                        remember(primary?.cameraID, offlineBuckets.size) {
                            restoreNikonAssists(applicationContext, availableStoredLut = lutLibrary::contains)
                        }
                    MediaBrowseScreen(
                        catalogIndex = mediaLibraryIndex,
                        cameraID = primary?.cameraID ?: "offline-all-cameras",
                        cameraConnected = false,
                        cameraSessionAvailable = false,
                        connectionOwner = null,
                        cacheRevision = mediaCacheRevision,
                        savedCameraID = primary?.savedCameraID,
                        cameraDisplayName =
                            when {
                                offlineBuckets.isEmpty() -> "Media Library"
                                offlineBuckets.size == 1 -> offlineBuckets.first().displayName
                                else -> "All cameras"
                            },
                        offlineCameraIDs = offlineBuckets.map { it.cameraID },
                        assists = offlineAssist,
                        exposureAssistCameraInput = ExposureAssistCameraInput(),
                        operatorSettings = operatorSettings,
                        lutLibrary = lutLibrary,
                        frameioController = frameioController,
                        mediaDeliveryCoordinator = mediaDeliveryCoordinator,
                        onRatingDiagnostic = diagnostics::record,
                        onClose = { shell.dismissCover() },
                    )
                } else if (active == null) {
                    val standaloneSettingsPresented = shellState.cover == ShellModel.Cover.SETTINGS
                    // An empty list is not a home unless a watcher asked for it. Once shown, the
                    // pair page stays until the operator leaves it: pairing saves its profile
                    // before the connect, and that must not swap the page mid-pairing.
                    val pairingPage = shellState.pairing || (savedCameras.isEmpty() && !watcherListRequested)
                    LaunchedEffect(pairingPage) { if (pairingPage) shell.beginPairing() }
                    BackHandler(enabled = standaloneSettingsPresented) { shell.dismissCover() }
                    BackHandler(
                        enabled =
                            !standaloneSettingsPresented &&
                                pairingPage &&
                                (savedCameras.isNotEmpty() || watcherListRequested),
                    ) {
                        shell.endPairing()
                    }
                    val nearbyBroadcasts by
                        remember {
                            com.opencapture.openzcine.relay.RelayBroadcastDirectory(
                                    AndroidNsdBrowser(getSystemService(NsdManager::class.java))
                                )
                                .broadcasts()
                        }
                            .collectAsState(initial = emptyList())
                    // Unicast presence sweep (iOS parity): on networks whose routers filter
                    // multicast, the NSD browse lists nothing — direct answers on the presence
                    // port keep broadcasts joinable, and an answer NSD cannot see is the proof
                    // the network filters discovery (the operator warning in the list).
                    var relayPresences by
                        remember { mutableStateOf(emptyMap<String, RelayPresence>()) }
                    var presenceRefutedNames by
                        remember { mutableStateOf(emptySet<String>()) }
                    var networkFiltersDiscovery by remember { mutableStateOf(false) }
                    LaunchedEffect(Unit) {
                        // The cameras list's discovery: passive only (presence sweep).
                        val scanner = CameraListDiscovery()
                        var hiddenSince = emptyMap<String, Long>()
                        while (true) {
                            // The scanner's own 30 s limiter makes most ticks no-ops. Each
                            // completed sweep REPLACES the set — authoritative, so a host that
                            // stopped answering leaves no ghost row — and the verdict
                            // re-evaluates every tick so the 10 s hidden threshold trips
                            // between sweeps.
                            scanner.presences()?.let { hits ->
                                relayPresences = hits
                                // A browsed name with no unicast answer is a stale NSD
                                // record — the goodbye packet is multicast too, and this
                                // network eats it (iOS presenceRefutedRelayNames).
                                presenceRefutedNames =
                                    nearbyBroadcasts.mapTo(mutableSetOf()) { it.name } -
                                        hits.values.mapTo(mutableSetOf()) { it.name }
                            }
                            val now = android.os.SystemClock.elapsedRealtime()
                            hiddenSince =
                                updatedPresenceHiddenSince(
                                    presences = relayPresences,
                                    nsdNames =
                                        nearbyBroadcasts.mapTo(mutableSetOf()) { it.name },
                                    selfName = relayDeviceName,
                                    previous = hiddenSince,
                                    nowMillis = now,
                                )
                            networkFiltersDiscovery = presenceProvesFiltering(hiddenSince, now)
                            delay(10_000)
                        }
                    }
                    Box(Modifier.fillMaxSize()) {
                        if (!pairingPage) {
                            // In-use beacons (w=0) shield their camera from probes but are not
                            // joinable; presence answers NSD never delivered join as rows.
                            val broadcasts =
                                mergedNearbyBroadcasts(nearbyBroadcasts, relayPresences, relayDeviceName, presenceRefutedNames)
                                    .filter { it.isWatchable }
                            DisposableEffect(nikonPort) {
                                nikonPort.pageVisible = true
                                onDispose { nikonPort.pageVisible = false }
                            }
                            CamerasScreen(
                                model = camerasModel,
                                brandName = "OpenZCine",
                                onPair = shell::beginPairing,
                                onMedia = {
                                    // iOS openCachedMediaLibrary: every complete on-device cache bucket.
                                    shell.open(ShellModel.Cover.MEDIA)
                                },
                                onSettings = { shell.open(ShellModel.Cover.SETTINGS) },
                                // The shared pages' own ground and margins (the pair page draws
                                // MonitorPalette.background itself; this page leaves it to the app).
                                modifier =
                                    Modifier.background(MonitorPalette.background)
                                        .windowInsetsPadding(WindowInsets.safeDrawing)
                                        .padding(start = 18.dp, top = 24.dp, end = 18.dp, bottom = 16.dp),
                                nearbyNote = "on this network",
                                onMultiview = if (MulticamCoordinator.TILES > 1) multicam::begin else null,
                                onIntegrationAction = { cameraID, action ->
                                    when (action) {
                                        AppNikonConnectPort.TAKE_OVER -> {
                                            val target = camerasState.failures[cameraID]?.target as? ConnectTarget.Saved
                                            target?.camera?.routes?.firstOrNull { it.id == target.route }
                                                ?.extras?.get(NikonSavedRecordsV0.Extra.HOST)
                                                ?.let(nikonPort::allowTakeOver)
                                            camerasModel.perform(RecoveryAction.Retry, cameraID)
                                        }
                                        AppNikonConnectPort.DIAGNOSTICS ->
                                            if (!systemSettingsActions.shareDiagnostics()) {
                                                Toast.makeText(
                                                        this@MainActivity,
                                                        getString(R.string.system_action_unavailable),
                                                        Toast.LENGTH_SHORT,
                                                    )
                                                    .show()
                                            }
                                    }
                                },
                                extraNearby = nearbyBroadcastItems(broadcasts, networkFiltersDiscovery),
                                onExtraNearby = { id ->
                                    val broadcast =
                                        broadcasts.firstOrNull { RELAY_ROW_PREFIX + it.name == id } ?: return@CamerasScreen
                                    // A watcher ON the camera's own AP can see broadcasts but its
                                    // join cannot reach them (camera APs isolate their clients).
                                    if (isOnCameraAccessPointNetwork(this@MainActivity)) {
                                        watchOnCameraApNoticeVisible = true
                                        return@CamerasScreen
                                    }
                                    relayBroadcastController.stop(notifyReason = "The broadcast ended.")
                                    relayBroadcastEnabled = false
                                    watchController =
                                        com.opencapture.openzcine.relay
                                            .RelayWatchController(
                                                scope = connectionScope,
                                                deviceName = relayDeviceName,
                                                broadcast = broadcast,
                                                watcherId =
                                                    com.opencapture.openzcine.relay.RelayWatcherIdentity
                                                        .current(applicationContext),
                                                onJpegOnlyLatched = persistJpegOnly,
                                                onPasscodeRemembered = { code ->
                                                    persistWatcherPasscode(broadcast.name, code)
                                                },
                                            )
                                            .also { it.start() }
                                },
                                onPrivacy = { systemSettingsActions.openPrivacy() },
                                onTerms = { systemSettingsActions.openTerms() },
                            )
                            // "+ Add setup -> Camera access point" without a stored key: the
                            // scan reads SSID and key off the camera's own network screen,
                            // anchored to THIS camera (never a second one).
                            scanningAccessPointFor?.let { camera ->
                                CameraWifiScannerOverlay(
                                    onConfirmed = { candidate ->
                                        scanningAccessPointFor = null
                                        nikonPort.pendingAccessPoint = candidate.ssid to candidate.key
                                        camerasModel.addRoute(
                                            RouteDraft(RouteKind.CAMERA_ACCESS_POINT, network = candidate.ssid),
                                            camera,
                                        )
                                    },
                                    onDismiss = { scanningAccessPointFor = null },
                                )
                            }
                            if (watchOnCameraApNoticeVisible) {
                                WifiOffPromptDialog(
                                    onDismiss = { watchOnCameraApNoticeVisible = false },
                                    title = R.string.watch_on_camera_ap_title,
                                    message = R.string.watch_on_camera_ap_message,
                                )
                            }
                        } else {
                            PairingExperience(
                                environment = pairingEnvironment,
                                camerasModel = camerasModel,
                                onReportProblem = { systemSettingsActions.openGitHubBugReport() },
                                script = pairingScript,
                                onPaired = ::acceptPairedCamera,
                                onPairingProfilePrepared = ::persistPairedCameraProfile,
                                onPairingAbandoned = ::discardAbandonedPairingSetup,
                                onStartHdmiMonitor = {
                                    // Picture only: no PTP session, no saved
                                    // camera, and no stale profile steering
                                    // link-health or reconnect heuristics.
                                    activeSavedCamera = null
                                    adoptSetupStreamSettings(null)
                                    uvcSource = UvcFrameSource(applicationContext)
                                    monitorSession =
                                        CaptureOnlyCameraSession(
                                            getString(R.string.pairing_hdmi_device_title)
                                        )
                                },
                                onOpenSettings = { shell.open(ShellModel.Cover.SETTINGS) },
                                onShowSavedCameras =
                                    if (savedCameras.isEmpty()) {
                                        null
                                    } else {
                                        shell::endPairing
                                    },
                                onOpenWatcherList = {
                                    watcherListRequested = true
                                    shell.endPairing()
                                },
                                onShareDiagnostics = {
                                    if (!systemSettingsActions.shareDiagnostics()) {
                                        Toast.makeText(
                                                this@MainActivity,
                                                getString(R.string.system_action_unavailable),
                                                Toast.LENGTH_SHORT,
                                            )
                                            .show()
                                    }
                                },
                                onDiagnosticPhase = { phase ->
                                    if (phase != "connect.gate") {
                                        AndroidDiagnosticEvent.fromPhase(phase)?.let {
                                            diagnostics.record(it)
                                        }
                                    }
                                },
                                onPrivacy = { systemSettingsActions.openPrivacy() },
                                onTerms = { systemSettingsActions.openTerms() },
                            )
                        }
                        if (multicam.presented) {
                            MulticamStage(
                                coordinator = multicam,
                                confirmsRecord = operatorSettings.recordConfirmationEnabled.value,
                                pickerRows = {
                                    val usb = pairingEnvironment.usbCameraSource?.cameras?.value.orEmpty()
                                    savedCameras.filter { record -> multicam.members.none { it.record.host == record.host } }
                                        .map { record ->
                                            // Network setups are dialled on Add (an operator action, not a
                                            // discovery probe); USB-C needs the body attached and permitted.
                                            val reachable =
                                                record.transport != SavedCameraTransport.USB_C ||
                                                    usb.any { it.hostKey == record.host && it.access == UsbPtpCameraAccess.READY }
                                            MulticamPickerRow(record, multicam.refusal(record, reachable))
                                        }
                                },
                                openLiveView = { id ->
                                    multicam.lend(id)?.let { session ->
                                        activeSavedCamera = multicam.member(id)?.record
                                        monitorSession = session
                                    }
                                },
                                close = multicam::end,
                            )
                        }
                        if (standaloneSettingsPresented) {
                            val standaloneAssist =
                                remember {
                                    restoreNikonAssists(applicationContext, availableStoredLut = lutLibrary::contains)
                                }
                            OperatorSettingsScreen(
                                session = null,
                                assists = standaloneAssist,
                                settings = operatorSettings,
                                mediaCacheStore = mediaCacheStore,
                                frameioController = frameioController,
                                // iOS's startup Settings lands on Link; a debug
                                // intent can still force a specific tab.
                                initialTab = debugInitialSettingsTab ?: OperatorSettingsTab.LINK,
                                systemSettingsActions = systemSettingsActions,
                                bugReportSubmitter = bugReportSubmitter,
                                bugReportActivityLogProvider = diagnostics::privacyFilteredActivityLog,
                                liveViewGuideController = liveViewGuide,
                                onShowGuideOnNextRealFrame =
                                    liveViewGuide::replayOnNextRealFrame,
                                onCompletedMediaCacheCleared = {
                                    mediaLibraryIndex.clearCameraCatalogs()
                                    mediaCacheRevision += 1
                                },
                                onClose = { shell.dismissCover() },
                            )
                        }
                        LaunchSplashOverlay(visible = launchSplashVisible)
                    }
                } else {
                    var monitorSessionRecoveryEnabled by
                        remember(active) { mutableStateOf(true) }
                    LaunchedEffect(active, pairingEnvironment) {
                        try {
                            awaitCancellation()
                        } finally {
                            withContext(NonCancellable) {
                                // A multicam member keeps its session for its tile.
                                if (!multicam.owns(active)) {
                                    shellSessions.retire(active)
                                    active.disconnect()
                                    pairingEnvironment.releaseCameraAp()
                                }
                            }
                        }
                    }
                    if (SwiftCore.isAvailable) {
                        // The real shell needs the shared core's zone map. An APK
                        // built without `just android-core` (plain CI android-check)
                        // has no native library, so it keeps the placeholder.
                        // Settings and Media are the shell's covers: mutually-exclusive,
                        // full-screen surfaces over the monitor so it keeps its state while
                        // either surface owns interaction.
                        val overlay = shellState.cover
                        LaunchedEffect(shellState.monitor?.id) {
                            if (shellState.monitor != null && DemoHarness.opensMedia(intent)) {
                                shell.open(ShellModel.Cover.MEDIA)
                            }
                        }
                        val assist = remember(active) {
                            restoreNikonAssists(applicationContext, debugAssistEffects, debugScopes, lutLibrary::contains).also { assists ->
                                debugSplitComparison?.let {
                                    assists.shared.setSplitComparison(true, vertical = it == FeedSplitOrientation.VERTICAL)
                                }
                            }
                        }
                        val currentSessionState by active.state.collectAsState()
                        val currentCameraProperties by active.cameraProperties.collectAsState()
                        LaunchedEffect(currentSessionState) {
                            diagnostics.record(
                                when (currentSessionState) {
                                    is CameraSessionState.Connected ->
                                        AndroidDiagnosticEvent.CONNECTION_CONNECTED
                                    CameraSessionState.Connecting ->
                                        AndroidDiagnosticEvent.CONNECTION_CONNECTING
                                    CameraSessionState.Disconnected ->
                                        AndroidDiagnosticEvent.CONNECTION_DISCONNECTED
                                },
                            )
                        }
                        DisposableEffect(active) {
                            diagnostics.record(AndroidDiagnosticEvent.MONITOR_PRESENTED)
                            onDispose {
                                liveViewGuide.onRealFrameUnavailable()
                                diagnostics.record(AndroidDiagnosticEvent.MONITOR_DISMISSED)
                            }
                        }
                        // In-use beacon (iOS parity): while this session is held and NOT shared,
                        // advertise the relay type with ch= + w=0 so no other device's camera
                        // list PTP-probes the held body. The real broadcast's advertisement
                        // carries the same shield, so only one runs at a time.
                        val inUseBeaconHost =
                            if (
                                currentSessionState is CameraSessionState.Connected &&
                                    !relayBroadcastEnabled
                            ) {
                                activeSavedCamera?.host?.takeIf(String::isNotBlank)
                            } else {
                                null
                            }
                        LaunchedEffect(inUseBeaconHost) {
                            if (inUseBeaconHost == null) return@LaunchedEffect
                            val beacon =
                                com.opencapture.openzcine.relay.CameraInUseBeacon(
                                    getSystemService(NsdManager::class.java),
                                    relayDeviceName,
                                )
                            beacon.start(inUseBeaconHost)
                            try {
                                kotlinx.coroutines.awaitCancellation()
                            } finally {
                                beacon.stop()
                            }
                        }
                        val playbackExposureAssistCameraInput =
                            remember(
                                currentCameraProperties.codec,
                                currentCameraProperties.iso,
                                currentCameraProperties.baseIso,
                            ) {
                                ExposureAssistCameraInput(
                                    codec = currentCameraProperties.codec,
                                    iso = currentCameraProperties.iso,
                                    baseIso = currentCameraProperties.baseIso,
                                )
                            }
                        val monitorLinkHealth = remember(active) { AndroidLinkHealthMonitor() }
                        val frameioCameraHop =
                            remember(active, activeSavedCamera, pairingEnvironment, pairingScript, demo) {
                                AndroidFrameioCameraApHop(
                                    activeSession = active,
                                    savedCamera = activeSavedCamera,
                                    environment = pairingEnvironment,
                                    fixtureSession = pairingScript != null || demo?.second != null,
                                    onReconnected = ::acceptPairedCamera,
                                )
                            }
                        DisposableEffect(frameioController, frameioCameraHop) {
                            frameioController.attachCameraHop(frameioCameraHop)
                            onDispose { frameioController.attachCameraHop(null) }
                        }
                        val disconnectToSavedCameraHome: (Boolean) -> Unit = disconnect@{ reconnect ->
                            val exitingSession = active
                            // A multicam member lent to Live View goes back to its tile: the
                            // session stays open (no CloseSession) and the stage resumes it.
                            if (multicam.lentMember(exitingSession) != null) {
                                shell.close()
                                return@disconnect
                            }
                            val reconnectID = activeSavedCamera?.id
                            monitorSessionRecoveryEnabled = false
                            suppressedUsbAutoReconnectHosts =
                                usbAutoReconnectSuppressionAfterUserAction(
                                    suppressedHosts = suppressedUsbAutoReconnectHosts,
                                    record = activeSavedCamera,
                                    reconnect = reconnect,
                                )
                            // iOS `disconnectCameraSession`: clear the shell
                            // synchronously, then fire-and-forget network
                            // teardown. Awaiting CloseSession / EndLiveView
                            // here made Android feel hung for several seconds
                            // after a drop or manual disconnect (stopLiveView
                            // alone can wait commandTimeout+2s on a dead link).
                            // The monitor LaunchedEffect dispose path still
                            // runs disconnect + releaseCameraAp when the
                            // session leaves composition.
                            if (monitorSession === exitingSession) {
                                relayBroadcastController.stop(
                                    notifyReason = "The broadcast ended.")
                                relayBroadcastEnabled = false
                                shell.close()
                                monitorSession = null
                                uvcSource?.close()
                                uvcSource = null
                                // Back to the cameras page, or the pair page when nothing
                                // is saved (an HDMI-only user may have no saved cameras).
                                shell.endPairing()
                                requestedReconnectID = if (reconnect) reconnectID else null
                            }
                        }
                        // Keep the library identity stable while a consented Frame.io hop
                        // disconnects this exact session. Re-keying it to "camera" here would
                        // discard the selected clips and project context before upload.
                        val cameraID =
                            remember(active, activeSavedCamera) {
                                (active.state.value as? CameraSessionState.Connected)
                                    ?.identity
                                    ?.let { identity ->
                                        identity.serialNumber.ifBlank {
                                            "${identity.model}:${identity.name}"
                                        }
                                    }
                                    ?: activeSavedCamera?.host
                                    ?: "camera"
                            }
                        val returnToMulticam: (() -> Unit)? =
                            if (multicam.lentMember(active) != null) {
                                { disconnectToSavedCameraHome(false) }
                            } else {
                                null
                            }
                        CompositionLocalProvider(LocalMulticamReturn provides returnToMulticam) {
                        Box {
                            MonitorScreen(
                                active,
                                commonSession = multicam.lentMember(active)?.control ?: shellSessions.acquire(active),
                                commonControl = shell.control,
                                frameSource = demo?.second ?: uvcSource,
                                assists = assist,
                                operatorSettings = operatorSettings,
                                lutLibrary = lutLibrary,
                                frameioController = frameioController,
                                // Media already owned this gate. Settings also
                                // drops every preview consumer so the native
                                // live-view pump and GPU decode path release
                                // while Operator Setup is on top — otherwise
                                // the full-screen sheet fights the feed for
                                // CPU/GPU on lower-tier phones.
                                liveViewEnabled = overlay == null,
                                glassTierOverride = DemoHarness.glassTierOverride(intent),
                                mediaRemoteShutter = mediaRemoteShutter,
                                isMonitorFront = overlay == null,
                                sessionRecoveryEnabled =
                                    monitorSessionRecoveryEnabled &&
                                        frameioController.internetHopState
                                            .allowsMonitorSessionRecovery(),
                                linkHealth = monitorLinkHealth,
                                activeTransportIsUsb =
                                    activeSavedCamera?.transport == SavedCameraTransport.USB_C,
                                isDemoSession = pairingScript != null || demo?.second != null,
                                liveViewGuideController = liveViewGuide,
                                onOpenSettings = {
                                    mediaRemoteShutter.disarm()
                                    shell.open(ShellModel.Cover.SETTINGS)
                                },
                                onOpenMedia = {
                                    mediaRemoteShutter.disarm()
                                    shell.open(ShellModel.Cover.MEDIA)
                                },
                                // Recovery affordance's "Operator menu": the same explicit exit
                                // Operator Settings offers, so a late reconnect can never
                                // resurrect a session the operator just left.
                                onBackToOperatorMenu = {
                                    mediaRemoteShutter.disarm()
                                    disconnectToSavedCameraHome(false)
                                },
                                recoveryStateOverride = DemoHarness.sessionRecoveryOverride(intent),
                                onDriveDiagnostic = diagnostics::record,
                                controlsSurrendered =
                                    relayBroadcastUi.controlHolderName != null,
                            )
                            relayBroadcastUi.controlHolderName?.let { holder ->
                                Row(
                                    Modifier.align(Alignment.BottomCenter)
                                        // The watcher's key already clears the bottom chrome per
                                        // orientation; this pill's own fixed 64dp was
                                        // orientation-blind and landed on the portrait system
                                        // band's DISP/record/media row. One lane, one definition
                                        // (relay/RelayWatchScreen.kt) — iOS seats both keys
                                        // against the same assist-strip zone.
                                        .padding(
                                            bottom =
                                                com.opencapture.openzcine.relay
                                                    .relayControlKeyBottomInset()
                                        )
                                        .clip(RoundedCornerShape(22.dp))
                                        .background(
                                            androidx.compose.ui.graphics.Color.Black.copy(alpha = 0.72f)
                                        )
                                        .clickable { relayBroadcastController.reclaimControl() }
                                        .padding(horizontal = 16.dp, vertical = 9.dp),
                                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                                    verticalAlignment = Alignment.CenterVertically,
                                ) {
                                    Text(
                                        stringResource(R.string.sharing_revoke_control),
                                        color = androidx.compose.ui.graphics.Color(0xFFE0A73A),
                                        fontSize = 12.sp,
                                        fontWeight = FontWeight.Bold,
                                        letterSpacing = 0.8.sp,
                                    )
                                    Text(
                                        holder,
                                        color = androidx.compose.ui.graphics.Color.White.copy(alpha = 0.7f),
                                        fontSize = 12.sp,
                                        maxLines = 1,
                                    )
                                }
                            }
                            relayBroadcastUi.pendingControlRequestName?.let { asking ->
                                Row(
                                    Modifier.align(Alignment.TopCenter)
                                        .padding(top = 10.dp)
                                        .background(
                                            androidx.compose.ui.graphics.Color.Black.copy(alpha = 0.72f),
                                            RoundedCornerShape(22.dp),
                                        )
                                        .padding(horizontal = 14.dp, vertical = 8.dp),
                                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                                    verticalAlignment = Alignment.CenterVertically,
                                ) {
                                    Text(
                                        stringResource(
                                            R.string.sharing_asks_to_control, asking
                                        ),
                                        color = androidx.compose.ui.graphics.Color.White,
                                        fontSize = 13.sp,
                                    )
                                    Text(
                                        stringResource(R.string.sharing_decline),
                                        color = androidx.compose.ui.graphics.Color.White.copy(alpha = 0.8f),
                                        fontSize = 13.sp,
                                        modifier =
                                            Modifier.clickable {
                                                relayBroadcastController
                                                    .declinePendingControl()
                                            },
                                    )
                                    Text(
                                        stringResource(R.string.sharing_grant),
                                        color = androidx.compose.ui.graphics.Color(0xFFE0A73A),
                                        fontSize = 13.sp,
                                        modifier =
                                            Modifier.clickable {
                                                relayBroadcastController.grantPendingControl()
                                            },
                                    )
                                }
                            }
                            when (overlay) {
                                null -> Unit
                                ShellModel.Cover.SETTINGS ->
                                    OperatorSettingsScreen(
                                        session = active,
                                        assists = assist,
                                        settings = operatorSettings,
                                        mediaCacheStore = mediaCacheStore,
                                        frameioController = frameioController,
                                        linkHealth = monitorLinkHealth,
                                        relaySharing = relayBroadcastController,
                                        relaySharingEnabled = relayBroadcastEnabled,
                                        onRelayShareToggle = { enable ->
                                            if (enable) {
                                                val frames =
                                                    demo?.second
                                                        ?: uvcSource
                                                        ?: (active as? SwiftCoreCameraSession)
                                                            ?.liveFrames
                                                            as? LiveFrameSource
                                                if (frames != null) {
                                                    relayBroadcastController.watcherPasscode =
                                                        operatorSettings
                                                            .relayWatcherPasscode
                                                            .value
                                                    relayBroadcastController
                                                        .allowsControlRequests =
                                                        operatorSettings
                                                            .relayAllowsControlRequests
                                                            .value
                                                    relayBroadcastController.encoderProfile =
                                                        com.opencapture.openzcine.core
                                                            .RelayEncoderProfile
                                                            .fromWireValue(
                                                                operatorSettings
                                                                    .relayEncoderProfile
                                                                    .value
                                                            )
                                                    relayBroadcastEnabled =
                                                        relayBroadcastController.start(
                                                            session = active,
                                                            frames = frames,
                                                            cameraName =
                                                                activeSavedCamera
                                                                    ?.displayTitle,
                                                            servedCameraHost =
                                                                activeSavedCamera?.host,
                                                        )
                                                }
                                            } else {
                                                relayBroadcastController.stop(
                                                    notifyReason = "The broadcast ended.")
                                                relayBroadcastEnabled = false
                                            }
                                        },
                                        liveViewSource =
                                            (active as? SwiftCoreCameraSession)
                                                ?.liveFrames as? SwiftCoreLiveFrameSource,
                                        activeTransportLabel = activeSavedCamera?.transport?.displayName,
                                        onDisconnect =
                                            activeSavedCamera?.let {
                                                { disconnectToSavedCameraHome(false) }
                                            },
                                        onReconnect =
                                            activeSavedCamera?.let {
                                                { disconnectToSavedCameraHome(true) }
                                            },
                                        systemSettingsActions = systemSettingsActions,
                                        bugReportSubmitter = bugReportSubmitter,
                                        bugReportActivityLogProvider = diagnostics::privacyFilteredActivityLog,
                                        liveViewGuideController = liveViewGuide,
                                        onShowGuideNow = {
                                            liveViewGuide.replayNow()
                                            shell.dismissCover()
                                        },
                                        onShowGuideOnNextRealFrame = {
                                            liveViewGuide.replayOnNextRealFrame()
                                            shell.dismissCover()
                                        },
                                        onCompletedMediaCacheCleared = {
                                            mediaLibraryIndex.clearCameraCatalogs()
                                            mediaCacheRevision += 1
                                        },
                                        onClose = { shell.dismissCover() },
                                    )
                                ShellModel.Cover.MEDIA ->
                                    MediaBrowseScreen(
                                        catalogIndex = mediaLibraryIndex,
                                        cameraID = cameraID,
                                        mediaService = shellSessions.media(active, multicam.lentMember(active)?.control ?: shellSessions.acquire(active)),
                                        cameraConnected =
                                            currentSessionState is CameraSessionState.Connected,
                                        connectionOwner =
                                            (active as? SwiftCoreCameraSession)?.connectionOwner,
                                        cacheRevision = mediaCacheRevision,
                                        savedCameraID = activeSavedCamera?.id,
                                        cameraDisplayName = activeSavedCamera?.displayTitle,
                                        cameraStorageSlots = currentCameraProperties.storageSlots,
                                        // Sidebar opens on the active capture side's
                                        // media (iOS `openMediaBrowser`).
                                        initialCategory =
                                            if (prefersPhotographyChrome(currentCameraProperties)) {
                                                MediaLibraryCategory.PHOTOS
                                            } else {
                                                MediaLibraryCategory.VIDEOS
                                            },
                                        assists = assist,
                                        exposureAssistCameraInput = playbackExposureAssistCameraInput,
                                        operatorSettings = operatorSettings,
                                        lutLibrary = lutLibrary,
                                        frameioController = frameioController,
                                        mediaDeliveryCoordinator = mediaDeliveryCoordinator,
                                        autoPlayFirstProxy = DemoHarness.autoPlaysMedia(intent),
                                        onRatingDiagnostic = diagnostics::record,
                                        onClose = { shell.dismissCover() },
                                    )
                            }
                        }
                        }
                        BackHandler(enabled = overlay == ShellModel.Cover.SETTINGS) {
                            shell.dismissCover()
                        }
                    } else {
                        MonitorShell(
                            active,
                            frameSource = demo?.second,
                            sessionRecoveryEnabled = monitorSessionRecoveryEnabled,
                        )
                    }
                }
                // Global delivery progress (iOS MediaDeliveryGlobalOverlay) — survives
                // leaving media browser / playback while export or Frame.io upload runs.
                deliveryDisplay.overlay?.let { state ->
                    Box(
                        Modifier
                            .align(Alignment.TopCenter)
                            .windowInsetsPadding(WindowInsets.safeDrawing)
                            .padding(top = 12.dp, start = 16.dp, end = 16.dp),
                    ) {
                        MediaDeliveryProgressOverlay(
                            state = state,
                            expanded = deliveryDisplay.expanded,
                            onCancel = mediaDeliveryCoordinator::cancel,
                            onExpandToggle = {
                                mediaDeliveryCoordinator.isExpanded =
                                    !mediaDeliveryCoordinator.isExpanded
                            },
                        )
                    }
                }
                deliveryDisplay.toast?.let { toast ->
                    MediaDeliveryCompletionToast(
                        message = toast,
                        modifier = Modifier.align(Alignment.BottomCenter),
                    )
                }
                } // app-root Box
                } // LocalOperatorHaptics
            } // OpenZCineTheme
        } // setContent
    }

    override fun onKeyDown(keyCode: Int, event: KeyEvent): Boolean =
        if (::mediaRemoteShutter.isInitialized && mediaRemoteShutter.dispatchKeyEvent(event)) {
            true
        } else {
            super.onKeyDown(keyCode, event)
        }

    override fun onKeyUp(keyCode: Int, event: KeyEvent): Boolean =
        if (::mediaRemoteShutter.isInitialized && mediaRemoteShutter.dispatchKeyEvent(event)) {
            true
        } else {
            super.onKeyUp(keyCode, event)
        }

    override fun onPause() {
        if (::mediaRemoteShutter.isInitialized) mediaRemoteShutter.disarm()
        super.onPause()
    }

    override fun onStart() {
        super.onStart()
        diagnostics.record(AndroidDiagnosticEvent.APP_FOREGROUND)
    }

    override fun onStop() {
        diagnostics.record(AndroidDiagnosticEvent.APP_BACKGROUND)
        super.onStop()
    }

    override fun onDestroy() {
        if (::mediaRemoteShutter.isInitialized) mediaRemoteShutter.close()
        super.onDestroy()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        publishFrameioRedirect(intent)
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        // System dialogs (runtime permissions, the Wi-Fi network-request
        // sheet) re-show the bars while they hold focus; re-assert immersive
        // as soon as this window gets focus back.
        if (hasFocus) applyImmersiveSystemBars()
    }

    private fun publishFrameioRedirect(newIntent: Intent) {
        if (newIntent.action != Intent.ACTION_VIEW) return
        newIntent.dataString?.takeIf(String::isNotBlank)?.let { callbackURI ->
            frameioRedirectCallback.value = FrameioRedirectCallback(callbackURI)
            // Do not retain an OAuth callback (and its one-time code) in the
            // Activity intent after handing it to the process-local verifier.
            newIntent.data = null
        }
    }

    /** Hides the system bars on every surface; styling stays transparent-dark. */
    private fun applyImmersiveSystemBars() {
        // BEHAVIOR_DEFAULT, not TRANSIENT_BARS_BY_SWIPE: the swipe reveal is
        // equally transient on this device under both, but only DEFAULT emits
        // the legacy system-UI visibility event MonitorScreen listens to for
        // the rail shift (verified on the SM-A127F — transient mode emits no
        // observable signal at all).
        WindowCompat.getInsetsController(window, window.decorView).apply {
            systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_DEFAULT
            // Startup and monitor both run fully immersive: Android's status
            // bar is far busier than iOS's clock strip, so hiding it is the
            // closer match to the iOS startup screens (a swipe reveals it).
            hide(WindowInsetsCompat.Type.systemBars())
        }
    }

    /**
     * Debug-only hook to exercise the real NSD discovery + socket transport:
     * `adb shell am start -n com.opencapture.openzcine/.MainActivity --ez openzcine.nsdTransport true`
     */
    private fun isNsdTransportRequested(): Boolean =
        (applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0 &&
            intent.getBooleanExtra("openzcine.nsdTransport", false)

    private fun nsdTransportSession(): CameraSession =
        NsdCameraSessionFactory(AndroidNsdBrowser(getSystemService(NsdManager::class.java)))
            .create()
}

/**
 * Placeholder monitor: a black feed area showing connection status from
 * [session]. While connected with an active [frameSource], the feed area
 * renders the live frame stream (aspect-fit, black letterbox); otherwise it
 * falls back to the status text ("No camera" when disconnected).
 */
@Composable
fun MonitorShell(
    session: CameraSession,
    frameSource: LiveFrameSource? = null,
    sessionRecoveryEnabled: Boolean = true,
) {
    val state by session.state.collectAsState()

    MonitorSessionRecoveryEffect(session, enabled = sessionRecoveryEnabled)

    Box(
        modifier = Modifier.fillMaxSize().background(BrandColors.background),
        contentAlignment = Alignment.Center,
    ) {
        when (val current = state) {
            is CameraSessionState.Connected ->
                if (frameSource != null) {
                    // No native core here, so no assist state: the shell feed is unprocessed.
                    LiveFeedView(frameSource, modifier = Modifier.fillMaxSize(), effects = FeedEffects.NONE)
                } else {
                    Text(
                        text = current.identity.name,
                        color = BrandColors.accent,
                        style = MaterialTheme.typography.titleMedium,
                    )
                }

            CameraSessionState.Connecting ->
                Text(
                    text = "Connecting…",
                    color = BrandColors.dimmedText,
                    style = MaterialTheme.typography.titleMedium,
                )

            CameraSessionState.Disconnected ->
                Text(
                    text = "No camera",
                    color = BrandColors.dimmedText,
                    style = MaterialTheme.typography.titleMedium,
                )
        }
    }
}

/**
 * The **only** branded cold-start splash (iOS `LaunchSplashContent`):
 * solid brand backdrop, full-bleed AppLogo clipped to continuous rounded
 * corners (size × 0.22), and the OpenZCine wordmark. The system SplashScreen
 * is a matching solid hold with a transparent icon so it never shows a
 * second square logo.
 */
@Composable
private fun LaunchSplashOverlay(visible: Boolean) {
    AnimatedVisibility(
        visible = visible,
        enter = androidx.compose.animation.EnterTransition.None,
        exit = fadeOut(tween(durationMillis = 350)),
    ) {
        BoxWithConstraints(
            Modifier.fillMaxSize().background(androidx.compose.ui.graphics.Color(0xFF0A0908)),
        ) {
            val landscape = maxWidth >= maxHeight
            // iOS: min(width * (landscape ? 0.16 : 0.28), 96)
            val logoSize =
                minOf(
                    maxWidth * if (landscape) 0.16f else 0.28f,
                    96.dp,
                )
            // iOS AppLogoMark continuous corner: size * 0.22
            val logoCorner = logoSize * 0.22f
            val wordmarkSp = if (landscape) 34.sp else 30.sp
            @Composable
            fun RoundedAppLogo() {
                Image(
                    painter = painterResource(R.drawable.openzcine_app_logo),
                    contentDescription = "OpenZCine",
                    contentScale = ContentScale.Crop,
                    modifier =
                        Modifier
                            .size(logoSize)
                            .clip(RoundedCornerShape(logoCorner)),
                )
            }
            if (landscape) {
                Row(
                    Modifier
                        .fillMaxSize()
                        .padding(horizontal = maxOf(32.dp, maxWidth * 0.08f)),
                    horizontalArrangement =
                        Arrangement.spacedBy(
                            maxOf(32.dp, maxWidth * 0.06f),
                            Alignment.CenterHorizontally,
                        ),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    RoundedAppLogo()
                    Text(
                        "OpenZCine",
                        color = androidx.compose.ui.graphics.Color(0xFFF2ECE2),
                        fontSize = wordmarkSp,
                        fontWeight = FontWeight.Bold,
                    )
                }
            } else {
                Column(
                    Modifier.fillMaxSize(),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(24.dp, Alignment.CenterVertically),
                ) {
                    RoundedAppLogo()
                    Text(
                        "OpenZCine",
                        color = androidx.compose.ui.graphics.Color(0xFFF2ECE2),
                        fontSize = wordmarkSp,
                        fontWeight = FontWeight.Bold,
                    )
                }
            }
        }
    }
}

package com.opencapture.openzcine

import com.opencapture.opencine.platform.WifiLowLatencyLock
import com.opencapture.opencine.appkit.retainedMonitorRoot
import com.opencapture.opencine.appkit.MonitorActivityLaunch
import com.opencapture.opencine.appkit.rememberMonitorLaunchSplash
import com.opencapture.opencine.appkit.MonitorKeepScreenAwake
import com.opencapture.opencine.appkit.MonitorLaunchSplash
import com.opencapture.opencine.appkit.MonitorAutomaticReportsOffer
import com.opencapture.opencine.appkit.MonitorReportsOffer
import com.opencapture.opencine.appkit.MonitorLaunchBrand
import android.content.Intent
import android.graphics.Color
import android.net.nsd.NsdManager
import android.os.Bundle
import android.os.SystemClock
import android.view.KeyEvent
import android.widget.Toast
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.ui.res.stringResource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.delay
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import com.opencapture.monitorui.LocalMonitorBackdrops
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
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
import androidx.compose.ui.semantics.clearAndSetSemantics
import kotlinx.coroutines.flow.catch
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.core.splashscreen.SplashScreen.Companion.installSplashScreen
import com.opencapture.opencine.nikon.CameraSession
import com.opencapture.opencine.nikon.CameraSessionState
import com.opencapture.openzcine.bridge.SwiftCore
import com.opencapture.opencine.gyro.GyroCaptureCoordinator
import com.opencapture.opencine.gyro.GyroNative
import com.opencapture.opencine.cameracontrols.MonitorSettingsGyroSource
import com.opencapture.opencine.cameracontrols.gyro.GyroCopy
import com.opencapture.opencine.cameracontrols.gyro.GyroFeatureHost
import com.opencapture.openzcine.bridge.SwiftCoreSmoke
import com.opencapture.openzcine.bridge.AndroidLinkHealthMonitor
import com.opencapture.opencine.nikon.NikonGyroCameraAdapter
import com.opencapture.opencine.nikon.SwiftCoreCameraSession
import com.opencapture.opencine.nikon.SwiftCoreLiveFrameSource
import com.opencapture.opencine.nikon.LiveFrameSource
import com.opencapture.openzcine.frameio.AndroidFrameioCameraApHop
import com.opencapture.opencine.frameio.FrameioInternetHopState
import com.opencapture.openzcine.frameio.FrameioRedirectCallback
import com.opencapture.openzcine.frameio.frameioArtifactPreparer
import com.opencapture.openzcine.frameio.frameioDeliveryController
import com.opencapture.opencine.cameracontrols.MonitorLegalDocumentScreen
import com.opencapture.opencine.cameracontrols.MonitorLegalPage
import com.opencapture.opencine.cameracontrols.MonitorOperatorDeliveryChrome
import com.opencapture.opencine.cameracontrols.rememberMonitorDeliveryCoordinator
import com.opencapture.openzcine.diagnostics.AndroidAppDiagnostics
import com.opencapture.openzcine.diagnostics.AppDiagnostics
import com.opencapture.opencine.appkit.diagnostics.ManualProblemReportDialog
import com.opencapture.openzcine.diagnostics.AndroidDiagnosticEvent
import com.opencapture.openzcine.diagnostics.AndroidSystemSettingsActions
import com.opencapture.openzcine.media.MediaBrowseScreen
import com.opencapture.openzcine.media.MediaCacheStore
import com.opencapture.openzcine.media.NikonMediaDelivery
import com.opencapture.openzcine.media.ZMediaShare
import com.opencapture.openzcine.media.MediaLibraryCameraBucket
import com.opencapture.openzcine.media.MediaLibraryCategory
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.windowInsetsPadding
import com.opencapture.openzcine.pairing.PairedCamera
import com.opencapture.openzcine.pairing.PairingExperience
import com.opencapture.openzcine.pairing.ConnectedNetworkName
import com.opencapture.opencine.nikon.SavedCameraRecord
import com.opencapture.opencine.nikon.SavedCameraTransport
import com.opencapture.openzcine.pairing.AppNikonConnectPort
import com.opencapture.openzcine.pairing.CameraWifiScannerOverlay
import com.opencapture.openzcine.pairing.FILTER_NOTICE_ID
import com.opencapture.openzcine.pairing.RELAY_ROW_PREFIX
import com.opencapture.openzcine.pairing.PortCopy
import com.opencapture.openzcine.pairing.SavedCameraConnector
import com.opencapture.openzcine.pairing.isOnCameraAccessPointNetwork
import com.opencapture.openzcine.pairing.isWifiRadioEnabled
import com.opencapture.openzcine.pairing.WifiOffPromptDialog
import com.opencapture.openzcine.pairing.attachedUsbAutoReconnectSuppressions
import com.opencapture.openzcine.pairing.mayAutoReconnectUsb
import com.opencapture.openzcine.pairing.nearbyBroadcastItems
import com.opencapture.openzcine.pairing.nikonIntegrationSlots
import com.opencapture.openzcine.pairing.CAMERAS_DOCUMENT_PREFERENCES
import com.opencapture.monitorui.MonitorPalette
import com.opencapture.opencine.appkit.AppIntegration
import com.opencapture.opencine.appkit.AppShell
import com.opencapture.opencine.appkit.CamerasModel
import com.opencapture.opencine.appkit.ShellActions
import com.opencapture.opencine.appkit.ShellBrand
import com.opencapture.opencine.appkit.ShellModel
import com.opencapture.opencine.appkit.MonitorOperatorSessionModel
import com.opencapture.opencine.appkit.ShellCoverPresentation
import com.opencapture.opencine.appkit.MonitorSettingsAccountModel
import com.opencapture.opencine.appkit.MonitorControlModel
import com.opencapture.opencine.core.ConnectedCamera
import com.opencapture.opencine.core.IntegrationID
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.currentStateAsState
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.lifecycleScope
import com.opencapture.opencine.appkit.CamerasScreen
import com.opencapture.opencine.core.ConnectTarget
import com.opencapture.opencine.core.RecoveryAction
import com.opencapture.opencine.core.RouteDraft
import com.opencapture.opencine.core.RouteKind
import com.opencapture.opencine.core.SavedCamera
import com.opencapture.opencine.nikon.NikonIntegration
import com.opencapture.opencine.nikon.NikonSavedRecordsV0
import com.opencapture.openzcine.multicam.MulticamCoordinator
import com.opencapture.openzcine.multicam.MulticamPickerRow
import com.opencapture.openzcine.multicam.MulticamStage
import com.opencapture.openzcine.transport.UsbPtpCameraAccess
import com.opencapture.openzcine.pairing.SharedPreferencesSavedCameraStore
import com.opencapture.openzcine.pairing.usbAutoReconnectSuppressionAfterUserAction
import com.opencapture.openzcine.transport.CameraListDiscovery
import com.opencapture.openzcine.relay.monitorRelayNearbyOwner
import com.opencapture.opencine.appkit.MonitorRemoteShutter
import com.opencapture.openzcine.settings.LiveViewQualityBias
import com.opencapture.openzcine.settings.LiveViewStreamPreset
import com.opencapture.openzcine.settings.OperatorSettings
import com.opencapture.openzcine.settings.OperatorSettingsScreen
import com.opencapture.openzcine.settings.SetupStreamSettings
import com.opencapture.openzcine.settings.ZLegalDocuments
import com.opencapture.openzcine.transport.AndroidNsdBrowser
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
    private val gyroCapture by lazy {
        GyroCaptureCoordinator(applicationContext, openZCineGyroHostConfiguration(filesDir))
    }
    private lateinit var mediaRemoteShutter: MonitorRemoteShutter
    private val diagnostics: AndroidAppDiagnostics by lazy {
        AndroidAppDiagnostics.create(applicationContext)
    }

    // A replayable activity-local callback is enough for both a cold launch and
    // an existing singleTop task. The controller validates the exact URI and
    // PKCE state before it ever makes a network request.
    private val frameioRedirectCallback = MutableStateFlow<FrameioRedirectCallback?>(null)

    /** Holds the solid system SplashScreen until the first Compose frame; the root brands from then on. */
    private val launch = MonitorActivityLaunch()

    /** The session and its owners, kept across recreation (an undeclared configuration change). */
    internal lateinit var root: AppRoot
        private set

    override fun onCreate(savedInstanceState: Bundle?) {
        installSplashScreen().setKeepOnScreenCondition { !launch.firstFrameDrawn }
        super.onCreate(savedInstanceState)
        val localReview = MonitorReview.decode(intent)
        // Load the Swift core (and with it OpenCine's NikonNative) before any camera session.
        SwiftCore.isAvailable
        // A staged LIVE review reuses the debug demo feed (the typed fake session and its frame
        // source), so the staged monitor shows the live chrome with no radio, camera or USB.
        // A staged CHROME_EDIT review is the same staged monitor with its editor open.
        val stagedIntent =
            if (localReview?.screen == com.opencapture.monitorui.ReviewLaunch.Screen.LIVE ||
                localReview?.screen == com.opencapture.monitorui.ReviewLaunch.Screen.CHROME_EDIT)
                Intent(intent).putExtra(DemoHarness.EXTRA_DEMO_FEED, true)
            else intent
        mediaRemoteShutter = MonitorRemoteShutter(applicationContext, "OpenZCineMediaRemoteShutter")
        diagnostics.record(AndroidDiagnosticEvent.APP_LAUNCHED)
        AppDiagnostics.install(applicationContext)
        // A recreated activity's intent was already handed to the retained controller.
        if (savedInstanceState == null) publishFrameioRedirect(intent)
        if (BuildConfig.DEBUG) SwiftCoreSmoke.run()
        root =
            retainedMonitorRoot {
                AppRoot(
                    applicationContext, DemoHarness.demoLiveFeed(stagedIntent, applicationContext),
                    DemoHarness.pairingScript(stagedIntent), diagnostics, DemoHarness.galleryFailureInjection(stagedIntent),
                )
            }
        val demo = root.demo
        val debugAssistEffects = DemoHarness.assistEffects(intent)
        val debugScopes = DemoHarness.scopeKinds(intent)
        val debugPortraitAspect = DemoHarness.portraitFeedAspect(intent)
        val debugInitialSettingsTab = DemoHarness.settingsTab(intent)
        val debugSession: CameraSession? = demo?.first
        val pairingScript = root.pairingScript
        val debugSplitComparison = DemoHarness.splitComparison(intent)
        val operatorSettings =
            OperatorSettings(applicationContext).also { settings ->
                debugPortraitAspect?.let { settings.portraitFeedAspect = it }
            }
        // Screenshot affordance: open the Edit view straight away (zc.demo.chromeEdit).
        val debugChromeEdit = DemoHarness.chromeEditMode(intent) ?: MonitorReview.chromeEdit(localReview)
        // Camera-monitor chrome owns the whole panel, like the iOS shell: the shared launch draws
        // edge to edge with forced-dark transparent bars (the transient overlay is never an opaque
        // white band) and the feed under the punch-hole (the cutout arrives as a safe-area inset
        // for the zone map); the bars themselves are sticky-immersive.
        launch.setContent(this) {
            OpenZCineTheme {
                GyroFeatureHost(gyroCapture, ZMediaShare) {
                val operatorHaptics =
                    rememberOperatorHaptics { operatorSettings.hapticsEnabled.value }
                // The presented picture under every shared material panel; the monitor feeds and activates it.
                val liveBackdrop = remember { NikonLiveBackdrop(applicationContext) }
                DisposableEffect(liveBackdrop) { onDispose { liveBackdrop.close() } }
                CompositionLocalProvider(LocalOperatorHaptics provides operatorHaptics,
                    LocalMonitorBackdrops provides listOf(liveBackdrop.source)) {
                Box(Modifier.fillMaxSize().reviewMetadata(localReview)) {
                // The session, its HDMI feed and its saved profile live in the retained root.
                var monitorSession by root::monitorSession
                var uvcSource by root::uvcSource
                var activeSavedCamera by root::activeSavedCamera
                val gyroState by gyroCapture.state.collectAsState()
                val gyroSource = MonitorSettingsGyroSource(
                    enabled = gyroState.enabled, setEnabled = gyroCapture::setEnabled,
                    status = GyroCopy.pillA11y(gyroState.pill.kind, warning = false),
                    available = gyroState.available || gyroState.enabled,
                    openLogs = gyroCapture::presentLogs,
                    calibrate = if (gyroState.canCalibrate) gyroCapture::beginCalibration else null,
                )
                // The row the running pairing CREATED, so walking away from it takes the row back
                // out — the wizard saves before the body confirmation. Null once anything
                // connected through it, or when the pairing refreshed a setup that already
                // existed. Twin of iOS `pairingCreatedRecordHost`.
                var pairingCreatedSetup by remember { mutableStateOf<SavedCameraRecord?>(null) }
                var requestedReconnectID by rememberSaveable { mutableStateOf<String?>(null) }
                var suppressedUsbAutoReconnectHosts by remember { mutableStateOf(emptySet<String>()) }
                val connectionScope = rememberCoroutineScope()
                val shellSessions = root.shellSessions
                // The monitor relay ("multicast") — iOS parity: this device can WATCH another
                // device's broadcast, and BROADCAST its own feed to watchers.
                var watchController by
                    remember { mutableStateOf<com.opencapture.openzcine.relay.RelayWatchController?>(null) }
                var watcherBrowsePresented by remember { mutableStateOf(false) }
                var watcherBrowseError by remember { mutableStateOf<String?>(null) }
                var watcherBrowseGeneration by remember { mutableStateOf(0) }
                var relayBroadcastEnabled by remember { mutableStateOf(false) }
                val relayDeviceName =
                    remember {
                        android.provider.Settings.Global.getString(
                            contentResolver, "device_name"
                        )
                            ?.takeIf(String::isNotBlank) ?: android.os.Build.MODEL
                    }
                // The broadcast passcode and the watcher passcodes (one per broadcaster name),
                // sealed by the shared relay secrets (iOS keeps them in the Keychain). NOT
                // install-scoped like the jpeg-only verdict below: a set's passcode does not
                // change because this app was rebuilt. The plain-text copies of earlier builds
                // move in once; each leaves only after its sealed copy read back.
                val relayPasscodes =
                    remember {
                        com.opencapture.openzcine.relay.RelayPasscodes(
                                applicationContext,
                                com.opencapture.openzcine.relay.RelayWatchController.SECRETS_SERVICE,
                            )
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
                            passcodes = relayPasscodes,
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
                                    passcodes = relayPasscodes,
                                )
                                .also { it.start() }
                    }
                }
                val savedCameraStore = root.savedCameraStore
                val lutLibrary = root.lutLibrary
                val mediaCacheStore = root.mediaCacheStore
                val mediaLibraryIndex = root.mediaLibraryIndex
                val frameioController = root.frameioController
                val settingsAccount = remember(frameioController) { MonitorSettingsAccountModel(connectionScope) }
                var settingsAccountCurrent by remember(settingsAccount) { mutableStateOf(true) }
                DisposableEffect(settingsAccount) {
                    onDispose { settingsAccountCurrent = false; settingsAccount.retire() }
                }
                val deliveryCoordinator = root.mediaDeliveryCoordinator
                val mediaDelivery = root.mediaDelivery
                val systemSettingsActions =
                    remember {
                        AndroidSystemSettingsActions(this@MainActivity, diagnostics)
                    }
                var showProblemReport by remember { mutableStateOf(false) }
                // A2-27: privacy and terms are bundled pages, readable on the camera's network.
                var legalPage by remember { mutableStateOf<MonitorLegalPage?>(null) }
                // The transport wizard is an explicit choice: Pair a new camera on the cameras page, or
                // the pair page's Nikon entry. An empty saved list stays on the shared pair page, the
                // same home as the other apps.
                var transportWizard by remember { mutableStateOf(pairingScript != null) }
                val frameioRedirect by frameioRedirectCallback.collectAsState()
                LaunchedEffect(frameioController, frameioRedirect) {
                    frameioRedirect?.let { callback ->
                        frameioController.completeRedirect(callback.uri)
                        if (frameioRedirectCallback.value === callback) {
                            frameioRedirectCallback.value = null
                        }
                    }
                }
                val savedCameras by savedCameraStore::current
                // Every complete on-device cache, for the startup Media Library
                // (iOS `openCachedMediaLibrary` / listAllCachedClips).
                var completedMediaBuckets by
                    remember { mutableStateOf(emptyMap<String, MediaLibraryCameraBucket>()) }
                var mediaCacheRevision by remember { mutableStateOf(0) }
                val pairingEnvironment = root.pairingEnvironment
                val multicam = root.multicam
                // Debug demo, scripted, settings deep-link and review launches skip the splash so
                // screenshots stay deterministic.
                val launchSplash =
                    rememberMonitorLaunchSplash(
                        enabled = debugSession == null && pairingScript == null && debugInitialSettingsTab == null && localReview == null,
                    )
                /**
                 * Saves a Nikon-confirmed profile before the temporary pairing
                 * session is released. The monitor is deliberately not entered
                 * here: [PairingExperience] must reconnect with this profile
                 * after the camera applies its body-side confirmation.
                 */
                fun persistPairedCameraProfile(saved: SavedCameraRecord): SavedCameraRecord {
                    // The network is read at SAVE time, the only moment this device is
                    // demonstrably on the network the setup describes.
                    val (record, created) = savedCameraStore.savePaired(saved, ConnectedNetworkName.read(this@MainActivity))
                    // The wizard saves here BEFORE the body confirmation, so remember a row this
                    // pairing created: an abandoned pairing takes it back out again.
                    pairingCreatedSetup = created
                    return record
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
                                stored = LiveViewStreamPreset.fromStoredName(record.streamPreset),
                                transport = record.transport,
                                seed = LiveViewStreamPreset.SHIPPED_DEFAULT,
                            ),
                        qualityBias =
                            SetupStreamSettings.qualityBias(
                                stored = LiveViewQualityBias.fromStoredName(record.qualityBias),
                                transport = record.transport,
                                seed = LiveViewQualityBias.SHIPPED_DEFAULT,
                            ),
                    )
                    operatorSettings.activeSetupStreamSettingsWriter = { preset, bias ->
                        savedCameraStore.saveStreamSettings(record, preset?.name, bias?.name)
                    }
                }

                fun acceptPairedCamera(paired: PairedCamera) {
                    transportWizard = false
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
                    savedCameraStore.discard(created)
                }
                // The shared cameras page (SHELL-02): saved setups live in OpenCine's saved-camera
                // document ("openzcine.cameras"), mirrored to this app's own records, which its
                // connect, pairing and settings code keeps writing with its own rules through
                // savedCameraStore, the one writer; every such write is merged into the document
                // at once (bind below).
                val connectCopy = remember { PortCopy { id, args -> applicationContext.getString(id, *args) } }
                val savedCameraConnector =
                    remember(pairingEnvironment) {
                        SavedCameraConnector(
                            pairingEnvironment,
                            wifiEnabled = { isWifiRadioEnabled(applicationContext) },
                            onCameraAccessPoint = { isOnCameraAccessPointNetwork(applicationContext) },
                            scope = connectionScope,
                            copy = connectCopy,
                        )
                    }
                var scanningAccessPointFor by remember { mutableStateOf<SavedCamera?>(null) }
                var watchOnCameraApNoticeVisible by remember { mutableStateOf(false) }
                val nikonPort =
                    remember(savedCameraConnector) {
                        AppNikonConnectPort(
                            copy = connectCopy,
                            connector = savedCameraConnector,
                            records = { savedCameras },
                            recordsJson = savedCameraStore::recordsJson,
                            onPaired = ::acceptPairedCamera,
                            onForget = savedCameraStore::forget,
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
                                        onChooseConnection = { transportWizard = true },
                                    ),
                                ),
                            ),
                            // The shared page patches the records (a rename, a forgotten setup): the
                            // store reads them back, and a removed access-point setup takes its key.
                            savedCameraStore.camerasStore(getSharedPreferences(CAMERAS_DOCUMENT_PREFERENCES, MODE_PRIVATE)),
                            connectionScope,
                            // A reachable setup beats a newer offline one (Nikon main's row rule).
                            CamerasModel.RoutePolicy.PREFER_REACHABLE,
                        ).also { model -> savedCameraStore.bind(model, pairingEnvironment.credentials::remove) }
                    }
                // The one note sink: refusals and interruptions show on the monitor (Pocket's placement).
                val monitorNote = remember { mutableStateOf<String?>(null) }
                val shell = remember(camerasModel, connectionScope) {
                    ShellModel(camerasModel, MonitorControlModel(connectionScope)).also {
                        it.control.onNote = { note -> monitorNote.value = note }
                        if (pairingScript != null) it.beginPairing()
                        if (debugInitialSettingsTab != null) it.open(ShellModel.Cover.SETTINGS)
                    }
                }
                val shellState by shell.state.collectAsState()
                var reviewBucket by remember { mutableStateOf<MediaLibraryCameraBucket?>(null) }
                LaunchedEffect(localReview) {
                    if (localReview == null) return@LaunchedEffect
                    // Typed, review-gated staging per screen (A7 increment 4): each staged screen
                    // shows its own production composition over the seeded, idle state; no radio,
                    // connection or command ever reaches a camera.
                    when (localReview.screen) {
                        com.opencapture.monitorui.ReviewLaunch.Screen.PAIR -> shell.beginPairing()
                        com.opencapture.monitorui.ReviewLaunch.Screen.CAMERAS -> {
                            savedCameraStore.replace(listOf(
                                SavedCameraRecord(host = "simulated-studio.local", cameraName = "Studio camera",
                                    transport = SavedCameraTransport.CAMERA_ACCESS_POINT,
                                    lastSeenAtEpochMillis = 1_000L, wifiSsid = "Studio-5G"),
                                SavedCameraRecord(host = "simulated-travel.local", cameraName = "Travel camera",
                                    transport = SavedCameraTransport.CAMERA_ACCESS_POINT,
                                    lastSeenAtEpochMillis = 500L, wifiSsid = "Travel-5G"),
                            ))
                            camerasModel.reloadSaved()
                        }
                        com.opencapture.monitorui.ReviewLaunch.Screen.LIVE,
                        com.opencapture.monitorui.ReviewLaunch.Screen.CHROME_EDIT ->
                            // The demo feed's fake session; the shell presents it as the monitor.
                            demo?.first?.let { monitorSession = it }
                        com.opencapture.monitorui.ReviewLaunch.Screen.MEDIA,
                        com.opencapture.monitorui.ReviewLaunch.Screen.PLAYBACK -> {
                            MonitorReview.start(applicationContext, mediaCacheStore, mediaLibraryIndex, localReview)
                            reviewBucket = MonitorReview.bucket(localReview)
                            mediaCacheRevision += 1
                            shell.open(ShellModel.Cover.MEDIA)
                        }
                        com.opencapture.monitorui.ReviewLaunch.Screen.SETTINGS -> shell.open(ShellModel.Cover.SETTINGS)
                        else -> Unit
                    }
                }
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
                // Automatic reports and a queued problem report wait from a connect attempt until the
                // monitor's session retires, recovery included (A6-08): one lease while either holds.
                val holdsCameraPath = camerasState.attempts.isNotEmpty() || monitorSession != null
                DisposableEffect(holdsCameraPath) {
                    val cameraPath = if (holdsCameraPath) AppDiagnostics.reporting.beginCameraPath() else null
                    onDispose { cameraPath?.close() }
                }
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
                MonitorKeepScreenAwake(operatorSettings.keepScreenAwake.value)
                // Bind the HDMI capture device once its monitor session exists.
                // CameraX pauses/resumes delivery with the activity lifecycle on
                // its own; explicit close happens on monitor exit.
                val currentUvcSource = uvcSource
                LaunchedEffect(currentUvcSource) { currentUvcSource?.start(this@MainActivity) }
                val monitored = monitorSession
                val watching = watchController
                val watcherBrowseUi = watching?.ui?.collectAsState()?.value
                LaunchedEffect(watcherBrowseUi?.phase) {
                    if (watcherBrowseUi?.phase == com.opencapture.openzcine.relay.RelayWatchUiState.Phase.WATCHING) {
                        watcherBrowsePresented = false
                    }
                }
                if (monitored == null && watching != null && !watcherBrowsePresented) {
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
                    val watchNote = remember(watching) { mutableStateOf<String?>(null) }
                    val watchControl = remember(watchCommon) {
                        MonitorControlModel(connectionScope).also { it.bind(watchCommon); it.onNote = { note -> watchNote.value = note } }
                    }
                    // The watcher's display owner. It has no shell monitor to edit in place, so Settings offers
                    // the Display rows without Edit view.
                    val watchOperatorSession = remember(watchAssist) {
                        MonitorOperatorSessionModel(shell, watchAssist.shared, operatorSettings.displayPreferences, connectionScope)
                    }
                    DisposableEffect(watchCommon) {
                        onDispose { watchControl.unbind(); shellSessions.retire(watching.session) }
                    }
                    Box(Modifier.fillMaxSize()) {
                        MonitorScreen(
                            watching.session,
                            commonSession = watchCommon,
                            commonControl = watchControl,
                            operatorSession = watchOperatorSession,
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
                            note = watchNote.value,
                            clearNote = { if (watchNote.value == it) watchNote.value = null },
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
                                controlSession = watchCommon,
                                assists = watchAssist,
                                operatorSession = watchOperatorSession,
                                settings = operatorSettings,
                                mediaCacheStore = mediaCacheStore,
                                frameioController = frameioController,
                                accountModel = settingsAccount, accountCurrent = { settingsAccountCurrent },
                                savedCameras = camerasState.saved,
                                // The Link tab's "Held By" reads the token off this state.
                                // Without it the row falls back to "The broadcaster" forever —
                                // including while THIS device holds control, which is the one
                                // moment the row exists to report (iOS `linkRows`).
                                relayWatchUi = watchUi,
                                gyro = gyroSource,
                                systemSettingsActions = systemSettingsActions,
                                onReportProblem = { showProblemReport = true },
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
                        }
                    }
                } else {
                    // The shared root (AppShell, iOS LinkExperience): the camera monitor while the shell holds
                    // one, else Nikon's pair page or the shared cameras page, with the shell's cover over them.
                    // The relay watcher above stays outside, like Pocket's. The standalone media library
                    // replaces the pages: nothing discovers under it.
                    val standaloneMedia = monitored == null && shellState.cover == ShellModel.Cover.MEDIA
                    // The wizard stays up once the operator opens it. Saving a profile before the
                    // connect must not swap the page mid-pairing.
                    val showTransportWizard = transportWizard
                    // The relay's NEARBY rows, browsed and swept only while the pages show.
                    val (broadcasts, filtersDiscovery) =
                        if (monitored == null && !standaloneMedia) {
                            val nearbyBroadcasts by
                                remember(watcherBrowseGeneration) {
                                    com.opencapture.openzcine.relay.RelayBroadcastDirectory(
                                            AndroidNsdBrowser(getSystemService(NsdManager::class.java))
                                        )
                                        .broadcasts()
                                        .catch { error ->
                                            watcherBrowseError = error.localizedMessage
                                            emit(emptyList())
                                        }
                                }
                                    .collectAsState(initial = emptyList())
                            // Unicast presence sweep (iOS parity): on networks whose routers filter
                            // multicast, the NSD browse lists nothing; direct answers on the presence
                            // port keep broadcasts joinable, and an answer NSD cannot see is the proof
                            // the network filters discovery (the operator warning in the list).
                            val relayNearby = remember { monitorRelayNearbyOwner() }
                            var nearbyPublication by remember { mutableStateOf(relayNearby.publication) }
                            LaunchedEffect(watcherBrowseGeneration) {
                                // The SDK scanner retains the original passive 30-second limiter.
                                val scanner = CameraListDiscovery()
                                val publicationSource = relayNearby.beginSweep()
                                try {
                                    while (true) {
                                        relayNearby.replaceListings(nearbyBroadcasts)
                                        val hits = scanner.presences()
                                        val now = android.os.SystemClock.elapsedRealtime()
                                        if (hits != null) {
                                            relayNearby.applySweep(hits, relayDeviceName, now, publicationSource)
                                        }
                                        if (relayNearby.evaluateFiltering(relayDeviceName, now, publicationSource)) {
                                            nearbyPublication = relayNearby.publication
                                        }
                                        delay(10_000)
                                    }
                                } finally {
                                    relayNearby.retireSweep(publicationSource)
                                }
                            }
                            relayNearby.watchableListings(nearbyBroadcasts, relayDeviceName) to
                                nearbyPublication.networkFiltersDiscovery
                        } else {
                            emptyList<com.opencapture.openzcine.relay.RelayBroadcast>() to false
                        }
                    val openWatcherBrowse: () -> Unit = {
                        if (monitored == null && camerasState.attempts.isEmpty()) {
                            watcherBrowsePresented = true
                        }
                    }
                    val joinWatcherBroadcast: (com.opencapture.openzcine.relay.RelayBroadcast) -> Unit = join@{ broadcast ->
                        if (isOnCameraAccessPointNetwork(this@MainActivity)) {
                            watchOnCameraApNoticeVisible = true
                            return@join
                        }
                        relayBroadcastController.stop(notifyReason = "The broadcast ended.")
                        relayBroadcastEnabled = false
                        val previous = watchController
                        if (previous != null) connectionScope.launch { previous.stop() }
                        watcherBrowsePresented = true
                        watchController = com.opencapture.openzcine.relay.RelayWatchController(
                            scope = connectionScope, deviceName = relayDeviceName, broadcast = broadcast,
                            watcherId = com.opencapture.openzcine.relay.RelayWatcherIdentity.current(applicationContext),
                            onJpegOnlyLatched = persistJpegOnly, passcodes = relayPasscodes,
                        ).also { it.start() }
                    }
                    val watcherBrowseHost = com.opencapture.openzcine.relay.RelayWatcherBrowseHost(
                        broadcasts = { broadcasts }, status = { watcherBrowseUi },
                        browseError = { watcherBrowseError },
                        browse = { watcherBrowseError = null; watcherBrowseGeneration += 1 },
                        join = joinWatcherBroadcast,
                        submitPasscode = { code -> watchController?.submitPasscode(code) },
                        close = {
                            watcherBrowsePresented = false
                            val leaving = watchController
                            watchController = null
                            if (leaving != null) connectionScope.launch { leaving.stop() }
                        },
                    )
                    var monitorSessionRecoveryEnabled by remember(monitored) { mutableStateOf(true) }
                    val monitorAssist = remember(monitored) {
                        monitored?.let {
                            restoreNikonAssists(applicationContext, debugAssistEffects, debugScopes, lutLibrary::contains).also { assists ->
                                debugSplitComparison?.let {
                                    assists.shared.setSplitComparison(true, vertical = it == FeedSplitOrientation.VERTICAL)
                                }
                            }
                        }
                    }
                    // The one display owner for this monitor: DISP modes, chrome, editor, lock and arming.
                    val monitorOperatorSession = remember(monitorAssist) {
                        monitorAssist?.let {
                            MonitorOperatorSessionModel(shell, it.shared, operatorSettings.displayPreferences, connectionScope)
                        }
                    }
                    LaunchedEffect(monitorOperatorSession, shellState.monitor?.id) {
                        monitorOperatorSession?.synchronize(shellState.monitor?.id)
                        // After synchronizing: a new monitor retires the previous one's editor.
                        if (shellState.monitor != null) debugChromeEdit?.let { monitorOperatorSession?.beginEditing(it) }
                    }
                    DisposableEffect(monitorOperatorSession) { onDispose { monitorOperatorSession?.close() } }
                    val monitorState = monitored?.state?.collectAsState()?.value
                    val monitorProperties = monitored?.cameraProperties?.collectAsState()?.value
                    val monitorLinkHealth = remember(monitored) { AndroidLinkHealthMonitor() }
                    // Preserve the camera's existing storage namespace across the planned AP leave.
                    val monitorCameraID = remember(monitored, activeSavedCamera) {
                        (monitored?.state?.value as? CameraSessionState.Connected)?.identity?.let { identity ->
                            identity.serialNumber.ifBlank { "${identity.model}:${identity.name}" }
                        } ?: activeSavedCamera?.host ?: "camera"
                    }
                    fun disconnectToSavedCameraHome(active: CameraSession): (Boolean) -> Unit = disconnect@{ reconnect ->
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
                    @Composable
                    fun CameraMonitor(active: CameraSession) {
                        LaunchedEffect(active, pairingEnvironment) {
                            try {
                                awaitCancellation()
                            } finally {
                                withContext(NonCancellable) {
                                    // A multicam member keeps its session for its tile, and a
                                    // recreated activity keeps the root's.
                                    if (!multicam.owns(active) && !isChangingConfigurations) {
                                        disconnectAfterGyroPreparation(
                                            isArmed = gyroCapture.state.value.isArmed,
                                            prepare = gyroCapture::prepareForDisconnect,
                                            disconnect = {
                                                shellSessions.retire(active)
                                                active.disconnect()
                                                pairingEnvironment.releaseCameraAp()
                                            },
                                        )
                                    }
                                    gyroCapture.bind(null)
                                }
                            }
                        }
                        // Settings and Media are the shell's covers: mutually-exclusive,
                        // full-screen surfaces over the monitor so it keeps its state while
                        // either surface owns interaction.
                        val overlay = shellState.cover
                        LaunchedEffect(shellState.monitor?.id) {
                            if (shellState.monitor != null && DemoHarness.opensMedia(intent)) {
                                shell.open(ShellModel.Cover.MEDIA)
                            }
                        }
                        val assist = monitorAssist ?: return
                        val operatorSession = monitorOperatorSession ?: return
                        val currentSessionState = monitorState ?: return
                        val currentCameraProperties = monitorProperties ?: return
                        val native = active as? SwiftCoreCameraSession
                        val incidentOwner = native?.connectionOwner
                        val canonicalIncidentConnection = native != null && incidentOwner != null &&
                            currentSessionState is CameraSessionState.Connected && !multicam.owns(active)
                        val incidentProducer = remember(active, incidentOwner, canonicalIncidentConnection) {
                            if (!canonicalIncidentConnection) null else {
                                val source = AppDiagnostics.incidents.beginBoundSession(
                                    AppDiagnostics.incidents.sessionContext(cameraFamily = "nikon"))
                                val bound = com.opencapture.opencine.appkit.diagnostics.FeedIncidentBindings.bind(source,
                                    ownerIsCurrent = { native?.connectionOwner == incidentOwner })
                                com.opencapture.openzcine.diagnostics.NikonFeedIncidentProducer(bound)
                            }
                        }
                        DisposableEffect(incidentProducer) { onDispose { incidentProducer?.end() } }

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
                            onDispose { diagnostics.record(AndroidDiagnosticEvent.MONITOR_DISMISSED) }
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
                        val frameioCameraHop =
                            remember(active, activeSavedCamera, pairingEnvironment, pairingScript, demo) {
                                AndroidFrameioCameraApHop(
                                    activeSession = active,
                                    savedCamera = activeSavedCamera,
                                    environment = pairingEnvironment,
                                    fixtureSession = pairingScript != null || demo?.second != null,
                                    onReconnected = ::acceptPairedCamera,
                                    prepareForDisconnect = {
                                        if (gyroCapture.state.value.isArmed) {
                                            gyroCapture.prepareForDisconnect()
                                        }
                                    },
                                )
                            }
                        DisposableEffect(frameioController, frameioCameraHop) {
                            frameioController.attachCameraHop(frameioCameraHop)
                            onDispose { frameioController.attachCameraHop(null) }
                        }
                        val disconnectToSavedCameraHome = disconnectToSavedCameraHome(active)
                        val returnToMulticam: (() -> Unit)? =
                            if (multicam.lentMember(active) != null) {
                                { disconnectToSavedCameraHome(false) }
                            } else {
                                null
                            }
                        LaunchedEffect(active, returnToMulticam != null) {
                            val adapter = native?.takeIf { returnToMulticam == null && demo == null }?.let {
                                NikonGyroCameraAdapter(
                                    it,
                                    it.liveFrames as? SwiftCoreLiveFrameSource,
                                    GyroNative,
                                    lifecycleScope,
                                    now = { SystemClock.elapsedRealtimeNanos() / 1e9 },
                                )
                            }
                            gyroCapture.bind(adapter)
                            gyroCapture.setHostEligible(adapter != null)
                        }
                        Box {
                            MonitorScreen(
                                active,
                                commonSession = multicam.lentMember(active)?.control ?: shellSessions.acquire(active),
                                commonControl = shell.control,
                                operatorSession = operatorSession,
                                frameSource = demo?.second ?: uvcSource,
                                assists = assist,
                                operatorSettings = operatorSettings,
                                lutLibrary = lutLibrary,
                                frameioController = frameioController,
                                // Media already owned this gate. Settings also
                                // drops every preview consumer so the native
                                // live-view pump and GPU decode path release
                                // while Operator Setup is on top; otherwise
                                // the full-screen sheet fights the feed for
                                // CPU/GPU on lower-tier phones.
                                liveViewEnabled = gyroState.ring != null || gyroState.setupSteps.isNotEmpty() ||
                                    overlay == null && !gyroState.logsPresented,
                                liveBackdrop = liveBackdrop,
                                mediaRemoteShutter = mediaRemoteShutter,
                                isMonitorFront = overlay == null && !gyroState.logsPresented &&
                                    gyroState.ring == null && gyroState.setupSteps.isEmpty(),
                                sessionRecoveryEnabled =
                                    monitorSessionRecoveryEnabled &&
                                        frameioController.internetHopState
                                            .allowsMonitorSessionRecovery(),
                                currentCameraHolder = {
                                    activeSavedCamera?.host?.takeIf(String::isNotBlank)
                                        ?.let { savedCameraConnector.currentHolder(it) }
                                },
                                linkHealth = monitorLinkHealth,
                                incidentProducer = incidentProducer,
                                activeTransportIsUsb =
                                    activeSavedCamera?.transport == SavedCameraTransport.USB_C,
                                isDemoSession = pairingScript != null || demo?.second != null,
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
                                borrowed = shellState.monitor?.isBorrowed == true,
                                returnToStage = returnToMulticam,
                                note = monitorNote.value,
                                clearNote = { if (monitorNote.value == it) monitorNote.value = null },
                                gyroState = gyroState.takeIf { returnToMulticam == null },
                                onOpenGyroLogs = gyroCapture::presentLogs,
                            )
                            relayBroadcastUi.controlHolderName?.let { holder ->
                                com.opencapture.opencine.cameracontrols.MonitorWatcherControlKey(
                                    text = stringResource(R.string.sharing_revoke_control),
                                    accented = true,
                                    holderName = holder,
                                    onClick = { relayBroadcastController.reclaimControl() },
                                    modifier = Modifier.align(Alignment.BottomCenter)
                                        // The watcher's key already clears the bottom chrome per
                                        // orientation; this pill's own fixed 64dp was
                                        // orientation-blind and landed on the portrait system
                                        // band's DISP/record/media row. One lane, one definition
                                        // (relay/RelayWatchScreen.kt); iOS seats both keys
                                        // against the same assist-strip zone.
                                        .padding(
                                            bottom =
                                                com.opencapture.openzcine.relay
                                                    .relayControlKeyBottomInset()
                                        ),
                                )
                            }
                            relayBroadcastUi.pendingControlRequestName?.let { asking ->
                                val pendingRequest = relayBroadcastUi.pendingControlRequest
                                com.opencapture.opencine.cameracontrols.MonitorRelayControlRequest(
                                    title = stringResource(R.string.sharing_asks_to_control, asking),
                                    grantLabel = stringResource(R.string.sharing_grant),
                                    denyLabel = stringResource(R.string.sharing_decline),
                                    onGrant = {
                                        pendingRequest?.let(relayBroadcastController::grantPendingControl)
                                    },
                                    onDeny = {
                                        pendingRequest?.let(relayBroadcastController::declinePendingControl)
                                    },
                                )
                            }
                        }
                    }
                    @Composable
                    fun CameraPage(active: CameraSession, cover: ShellModel.Cover) {
                        val assist = monitorAssist ?: return
                        val operatorSession = monitorOperatorSession ?: return
                        val currentSessionState = monitorState ?: return
                        val currentCameraProperties = monitorProperties ?: return
                        val cameraID = monitorCameraID
                        val disconnectToSavedCameraHome = disconnectToSavedCameraHome(active)
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
                            when (cover) {
                                ShellModel.Cover.SETTINGS ->
                                    OperatorSettingsScreen(
                                        session = active,
                                        controlSession = multicam.lentMember(active)?.control ?: shellSessions.acquire(active),
                                        gyro = gyroSource,
                                        assists = assist,
                                        operatorSession = operatorSession,
                                        editsLiveView = true,
                                        settings = operatorSettings,
                                        mediaCacheStore = mediaCacheStore,
                                        frameioController = frameioController,
                                        accountModel = settingsAccount, accountCurrent = { settingsAccountCurrent },
                                        savedCameras = camerasState.saved,
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
                                                // A passcode the store cannot read now never
                                                // starts an unprotected broadcast.
                                                if (frames != null &&
                                                    relayBroadcastController.loadPasscode()) {
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
                                                            common =
                                                                multicam.lentMember(active)?.control
                                                                    ?: shellSessions.acquire(active),
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
                                        activeTransportLabel = activeSavedCamera?.transport?.displayName,
                                        onDisconnect =
                                            activeSavedCamera?.let {
                                                { disconnectToSavedCameraHome(false) }
                                            },
                                        systemSettingsActions = systemSettingsActions,
                                        onReportProblem = { showProblemReport = true },
                                        onCompletedMediaCacheCleared = {
                                            mediaLibraryIndex.clearCameraCatalogs()
                                            mediaCacheRevision += 1
                                        },
                                        onClose = { shell.dismissCover() },
                                    )
                                ShellModel.Cover.MEDIA ->
                                    MediaBrowseScreen(
                                        cacheStore = mediaCacheStore,
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
                                        mediaDelivery = mediaDelivery,
                                        autoPlayFirstProxy = DemoHarness.autoPlaysMedia(intent),
                                        onRatingDiagnostic = diagnostics::record,
                                        onClose = { shell.dismissCover() },
                                    )
                            }
                    }
                    @Composable
                    fun StandaloneMedia() {
                        // Read as state: a bucket scan still running when the cover opens adds its cameras here.
                        // A review launch stages its own seeded bucket ahead of the on-device caches.
                        val offlineBuckets = reviewBucket?.let(::listOf) ?: completedMediaBuckets.values.toList()
                        val primary = offlineBuckets.firstOrNull()
                        val offlineAssist =
                            remember(primary?.cameraID, offlineBuckets.size) {
                                restoreNikonAssists(applicationContext, availableStoredLut = lutLibrary::contains)
                            }
                        MediaBrowseScreen(
                            cacheStore = mediaCacheStore,
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
                            mediaDelivery = mediaDelivery,
                            // `ReviewLaunch(screen: .playback)`: the staged gallery opens its first
                            // clip once, as a tap would (the demo play path's same affordance).
                            autoPlayFirstProxy = localReview?.screen ==
                                com.opencapture.monitorui.ReviewLaunch.Screen.PLAYBACK,
                            onRatingDiagnostic = diagnostics::record,
                            onClose = { shell.dismissCover() },
                        )
                    }
                    @Composable
                    fun StandaloneSettings() {
                        val standaloneAssist =
                            remember {
                                restoreNikonAssists(applicationContext, availableStoredLut = lutLibrary::contains)
                            }
                        val standaloneSession = remember(standaloneAssist) {
                            MonitorOperatorSessionModel(shell, standaloneAssist.shared, operatorSettings.displayPreferences,
                                connectionScope)
                        }
                        OperatorSettingsScreen(
                            session = null,
                            controlSession = null,
                            gyro = gyroSource,
                            assists = standaloneAssist,
                            operatorSession = standaloneSession,
                            settings = operatorSettings,
                            mediaCacheStore = mediaCacheStore,
                            frameioController = frameioController,
                            // The passcode is stored in the relay secrets, the same store a later
                            // broadcast reads, so standalone Settings can set it (ZAB-352).
                            standalonePasscodes = relayPasscodes,
                            accountModel = settingsAccount, accountCurrent = { settingsAccountCurrent },
                            savedCameras = camerasState.saved,
                            // The shared landing-tab rule; a typed review stages the tab it names,
                            // and a debug intent can still force a tab.
                            initialTab = localReview?.settingsTab ?: debugInitialSettingsTab,
                            systemSettingsActions = systemSettingsActions,
                            onReportProblem = { showProblemReport = true },
                            onCompletedMediaCacheCleared = {
                                mediaLibraryIndex.clearCameraCatalogs()
                                mediaCacheRevision += 1
                            },
                            onClose = { shell.dismissCover() },
                        )
                    }
                    val pairPage: @Composable () -> Unit = {
                        // The wizard always opens from a shared page, so Back returns to it.
                        BackHandler {
                            transportWizard = false
                            shell.endPairing()
                        }
                        PairingExperience(
                            environment = pairingEnvironment,
                            camerasModel = camerasModel,
                            onReportProblem = { showProblemReport = true },
                            script = pairingScript,
                            onPaired = ::acceptPairedCamera,
                            onPairingProfilePrepared = ::persistPairedCameraProfile,
                            onPairingAbandoned = ::discardAbandonedPairingSetup,
                            onStartHdmiMonitor = {
                                // Picture only: no PTP session, no saved
                                // camera, and no stale profile steering
                                // link-health or reconnect heuristics.
                                transportWizard = false
                                activeSavedCamera = null
                                adoptSetupStreamSettings(null)
                                uvcSource = UvcFrameSource(applicationContext)
                                monitorSession =
                                    CaptureOnlyCameraSession(
                                        getString(R.string.pairing_hdmi_device_title)
                                    )
                            },
                            onShowSavedCameras = {
                                transportWizard = false
                                shell.showCameras()
                            },
                            onOpenWatcherList = openWatcherBrowse,
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
                            onPrivacy = { legalPage = MonitorLegalPage.PRIVACY },
                            onTerms = { legalPage = MonitorLegalPage.TERMS },
                        )
                    }
                    AppShell(
                        model = shell,
                        modifier = if (watcherBrowsePresented) Modifier.clearAndSetSemantics {} else Modifier,
                        brand = ShellBrand("OpenZCine", nearbyNote = "on this network"),
                        actions =
                            ShellActions(
                                diagnostics = { systemSettingsActions.shareDiagnostics() },
                                reportProblem = { showProblemReport = true },
                                watchFeed = openWatcherBrowse,
                                multiview = if (MulticamCoordinator.TILES > 1) {
                                    { camerasModel.consent.retire(); multicam.begin() }
                                } else null,
                                integrationAction = { cameraID, action ->
                                    when (action) {
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
                                privacy = { legalPage = MonitorLegalPage.PRIVACY },
                                terms = { legalPage = MonitorLegalPage.TERMS },
                                // Pair a new camera opens the transport wizard; a nearby card
                                // opens the shared pair page (the integration declares its tap).
                                pair = {
                                    transportWizard = true
                                    shell.beginPairing()
                                },
                                extraNearby = extra@{ id ->
                                    if (broadcasts.none { RELAY_ROW_PREFIX + it.name == id }) return@extra
                                    openWatcherBrowse()
                                },
                            ),
                        monitor = { live ->
                            // A session handed over but not yet presented, or one already gone: nothing until
                            // the app's session and the shell's monitor agree.
                            val common = monitored?.let { multicam.lentMember(it)?.control ?: shellSessions.acquire(it) }
                            if (monitored != null && common?.id == live.session.id) CameraMonitor(monitored)
                        },
                        page = { cover ->
                            val active = monitored
                            if (active != null) CameraPage(active, cover)
                            else when (cover) {
                                ShellModel.Cover.MEDIA -> StandaloneMedia()
                                ShellModel.Cover.SETTINGS -> StandaloneSettings()
                            }
                        },
                        coverPresentation = ShellCoverPresentation.SHELL,
                        pageFrame = { _, content ->
                            if (!standaloneMedia) {
                                DisposableEffect(nikonPort) {
                                    nikonPort.pageVisible = true
                                    onDispose { nikonPort.pageVisible = false }
                                }
                                // Clearance belongs to the shared pages (the pair page's frame is
                                // the shell's); both pages keep this ground.
                                Box(Modifier.fillMaxSize().background(MonitorPalette.background)) {
                                    content()
                                }
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
                            }
                        },
                        extraNearby = nearbyBroadcastItems(broadcasts, filtersDiscovery),
                        prePage = if (showTransportWizard && !standaloneMedia) pairPage else null,
                    )
                    if (watcherBrowsePresented) {
                        com.opencapture.opencine.cameracontrols.WatcherBrowse(
                            host = watcherBrowseHost,
                            modifier = Modifier.fillMaxSize().background(MonitorPalette.background)
                                .windowInsetsPadding(WindowInsets.safeDrawing),
                            networkInstructions = "Join the same regular Wi-Fi as the sharing device. Leave the camera's own Wi-Fi before watching; it may block traffic between devices.",
                            emptyMessage = "No shared feeds on this network. Check that sharing is on and both devices can reach each other. Allow Local Network if asked.",
                        )
                    }
                    if (multicam.presented) {
                        com.opencapture.opencine.appkit.MultiviewStageVisibility(monitored == null && !standaloneMedia) {
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
                    }
                    if (monitored == null && !standaloneMedia) {
                        MonitorLaunchSplash(LAUNCH_BRAND, launchSplash)
                        if (!launchSplash.visible && !multicam.presented && localReview == null) {
                            MonitorAutomaticReportsOffer(
                                MonitorReportsOffer(
                                    AppDiagnostics.consent, AppDiagnostics.reporting, AppDiagnostics.host.product,
                                    onPrivacy = { legalPage = MonitorLegalPage.PRIVACY },
                                ),
                            )
                        }
                    }
                }
                // The shared delivery chrome: progress, outcome toast and the share chooser.
                MonitorOperatorDeliveryChrome(
                    deliveryCoordinator,
                    ZMediaShare,
                    mediaDelivery::mimeType,
                    displayName = mediaDelivery::displayName,
                )
                if (showProblemReport) {
                    ManualProblemReportDialog(
                        AppDiagnostics.manualReport,
                        diagnosticText = {
                            val state = monitorSession?.state?.value
                            diagnostics.boundedDiagnosticText(
                                cameraModel = (state as? CameraSessionState.Connected)?.identity?.model ?: "none",
                                phase = when (state) {
                                    is CameraSessionState.Connected -> "connected"
                                    CameraSessionState.Connecting -> "connecting"
                                    else -> "disconnected"
                                },
                            )
                        },
                        // The platform 48 dp minimum touch target, as on Nikon's settings pills.
                        actionMinimumTouchTarget = true,
                        onClose = { showProblemReport = false },
                        onPrivacy = { legalPage = MonitorLegalPage.PRIVACY },
                    )
                }
                legalPage?.let { page ->
                    Dialog(
                        onDismissRequest = { legalPage = null },
                        properties = DialogProperties(usePlatformDefaultWidth = false),
                    ) {
                        MonitorLegalDocumentScreen(ZLegalDocuments, page) { legalPage = null }
                    }
                }
                } // app-root Box
                } // LocalOperatorHaptics
                } // GyroFeatureHost
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
        gyroCapture.setForeground(false)
        if (::mediaRemoteShutter.isInitialized) mediaRemoteShutter.disarm()
        AppDiagnostics.manualReport.setForeground(false)
        super.onPause()
    }

    override fun onResume() {
        super.onResume()
        gyroCapture.setForeground(true)
        AppDiagnostics.manualReport.setForeground(true)
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
        gyroCapture.close()
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
}

/** The launch splash (iOS `LaunchSplashContent`) over the matching solid system hold. */
private val LAUNCH_BRAND =
    MonitorLaunchBrand(
        R.drawable.openzcine_app_logo, "OpenZCine",
        background = androidx.compose.ui.graphics.Color(0xFF0A0908),
        ink = androidx.compose.ui.graphics.Color(0xFFF2ECE2),
        logoScale = ContentScale.Crop,
    )

package com.opencapture.openzcine

import android.content.Intent
import android.content.pm.ApplicationInfo
import android.graphics.Color
import android.net.nsd.NsdManager
import android.os.Bundle
import android.view.KeyEvent
import android.view.WindowManager
import androidx.activity.SystemBarStyle
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
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
import androidx.core.splashscreen.SplashScreen.Companion.installSplashScreen
import com.opencapture.openzcine.core.CameraSession
import com.opencapture.openzcine.core.CameraSessionState
import com.opencapture.openzcine.bridge.SwiftCore
import com.opencapture.openzcine.bridge.SwiftCoreSmoke
import com.opencapture.openzcine.bridge.AndroidLinkHealthMonitor
import com.opencapture.openzcine.bridge.SwiftCoreCameraSession
import com.opencapture.openzcine.bridge.SwiftCoreLiveFrameSource
import com.opencapture.openzcine.core.LiveFrameSource
import com.opencapture.openzcine.frameio.AndroidFrameioCameraApHop
import com.opencapture.openzcine.frameio.FrameioRedirectCallback
import com.opencapture.openzcine.frameio.frameioDeliveryController
import com.opencapture.openzcine.diagnostics.AndroidAppDiagnostics
import com.opencapture.openzcine.diagnostics.AndroidDiagnosticEvent
import com.opencapture.openzcine.diagnostics.AndroidSystemSettingsActions
import com.opencapture.openzcine.media.MediaBrowseScreen
import com.opencapture.openzcine.media.MediaCacheStore
import com.opencapture.openzcine.lut.AndroidLutLibrary
import com.opencapture.openzcine.pairing.PairedCamera
import com.opencapture.openzcine.pairing.PairingExperience
import com.opencapture.openzcine.pairing.SavedCameraRecords
import com.opencapture.openzcine.pairing.SavedCameraRecord
import com.opencapture.openzcine.pairing.SavedCameraTransport
import com.opencapture.openzcine.pairing.SavedCamerasExperience
import com.opencapture.openzcine.pairing.SharedPreferencesSavedCameraStore
import com.opencapture.openzcine.pairing.realPairingEnvironment
import com.opencapture.openzcine.pairing.usbAutoReconnectSuppressionAfterUserAction
import com.opencapture.openzcine.remote.AndroidMediaRemoteShutter
import com.opencapture.openzcine.settings.OperatorSettings
import com.opencapture.openzcine.settings.OperatorSettingsScreen
import com.opencapture.openzcine.settings.OperatorSettingsTab
import com.opencapture.openzcine.transport.AndroidNsdBrowser
import com.opencapture.openzcine.transport.NsdCameraSessionFactory
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

private enum class MonitorOverlay {
    NONE,
    SETTINGS,
    MEDIA,
}

private enum class StartupSurface {
    SAVED_CAMERAS,
    PAIRING,
}

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

    override fun onCreate(savedInstanceState: Bundle?) {
        installSplashScreen()
        super.onCreate(savedInstanceState)
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
        val demo = DemoHarness.demoLiveFeed(intent)
        val debugAssistEffects = DemoHarness.assistEffects(intent)
        val debugScopes = DemoHarness.scopeKinds(intent)
        val debugPortraitAspect = DemoHarness.portraitFeedAspect(intent)
        val debugLiveGuideStep = DemoHarness.liveGuideStep(intent)
        val debugSession: CameraSession? =
            demo?.first ?: if (isNsdTransportRequested()) nsdTransportSession() else null
        val pairingScript = DemoHarness.pairingScript(intent)
        val operatorSettings =
            OperatorSettings(applicationContext).also { settings ->
                debugPortraitAspect?.let { settings.portraitFeedAspect = it }
            }
        setContent {
            OpenZCineTheme {
                var monitorSession by remember { mutableStateOf(debugSession) }
                // A monitor reached from a saved card retains that exact
                // profile. Link settings may then leave the monitor without
                // guessing a topology or constructing a second session.
                var activeSavedCamera by remember { mutableStateOf<SavedCameraRecord?>(null) }
                var requestedReconnectID by rememberSaveable { mutableStateOf<String?>(null) }
                var suppressedUsbAutoReconnectHosts by remember { mutableStateOf(emptySet<String>()) }
                val connectionScope = rememberCoroutineScope()
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
                val frameioController =
                    remember { frameioDeliveryController(applicationContext, lutLibrary) }
                val liveViewGuide =
                    remember {
                        LiveViewGuideController(applicationContext, diagnostics::record)
                    }
                val systemSettingsActions =
                    remember {
                        AndroidSystemSettingsActions(this@MainActivity, diagnostics)
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
                // Keep the process-wide camera-AP binding alive while its
                // handed-off session is active, then release it alongside the
                // PTP slot when this activity or session leaves composition.
                // Creating this once also prevents recomposition from
                // orphaning a CameraApJoiner callback.
                val pairingEnvironment =
                    remember(pairingScript) {
                        pairingScript?.environment
                            ?: realPairingEnvironment(applicationContext)
                    }
                // USB attach/detach must stay observed while a handed-off
                // session is on the monitor; close the Android receiver only
                // when this activity's whole Compose tree leaves.
                DisposableEffect(pairingEnvironment) {
                    onDispose { pairingEnvironment.usbCameraSource?.close() }
                }
                var startupSurface by
                    rememberSaveable {
                        mutableStateOf(
                            if (pairingScript != null || savedCameras.isEmpty()) {
                                StartupSurface.PAIRING
                            } else {
                                StartupSurface.SAVED_CAMERAS
                            },
                        )
                    }
                var standaloneSettingsPresented by rememberSaveable { mutableStateOf(false) }
                fun acceptPairedCamera(paired: PairedCamera) {
                    val saved = paired.savedCamera
                    val updated =
                        SavedCameraRecords.upserting(
                            host = saved.host,
                            cameraName = saved.cameraName,
                            transport = saved.transport,
                            lastSeenAtEpochMillis = saved.lastSeenAtEpochMillis,
                            wifiSsid = saved.wifiSsid,
                            records = savedCameras,
                        )
                    savedCameras = updated
                    savedCameraStore.replace(updated)
                    activeSavedCamera =
                        updated.firstOrNull { candidate ->
                            candidate.transport == saved.transport &&
                                (
                                    candidate.host == saved.host ||
                                        SavedCameraRecords.cameraNamesMatch(
                                            candidate.cameraName,
                                            saved.cameraName,
                                        )
                                )
                        } ?: saved
                    monitorSession = paired.session
                }
                // The monitor is immersive; the pairing screens keep the
                // (transparent, dark-styled) system bars, like the iOS
                // startup screens keep the status bar.
                val immersive = monitorSession != null
                LaunchedEffect(immersive) { setSystemBarsHidden(immersive) }
                LaunchedEffect(immersive, operatorSettings.keepScreenAwake.value) {
                    if (operatorSettings.shouldKeepScreenAwake(immersive)) {
                        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    } else {
                        window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    }
                }
                val active = monitorSession
                if (active == null) {
                    BackHandler(enabled = standaloneSettingsPresented) {
                        standaloneSettingsPresented = false
                    }
                    BackHandler(
                        enabled =
                            !standaloneSettingsPresented &&
                                startupSurface == StartupSurface.PAIRING &&
                                savedCameras.isNotEmpty(),
                    ) {
                        startupSurface = StartupSurface.SAVED_CAMERAS
                    }
                    Box(Modifier.fillMaxSize()) {
                        when (startupSurface) {
                            StartupSurface.SAVED_CAMERAS ->
                                SavedCamerasExperience(
                                    cameras = savedCameras,
                                    environment = pairingEnvironment,
                                    onPaired = ::acceptPairedCamera,
                                    onPairNewCamera = { startupSurface = StartupSurface.PAIRING },
                                    onOpenSettings = { standaloneSettingsPresented = true },
                                    requestedReconnectID = requestedReconnectID,
                                    onReconnectRequestConsumed = { requestedReconnectID = null },
                                    suppressedUsbAutoReconnectHosts = suppressedUsbAutoReconnectHosts,
                                    onUsbAutoReconnectSuppressionCleared = { host ->
                                        suppressedUsbAutoReconnectHosts =
                                            suppressedUsbAutoReconnectHosts - host
                                    },
                                    onRecordsChanged = { updated ->
                                        savedCameras = updated
                                        savedCameraStore.replace(updated)
                                        if (updated.isEmpty()) {
                                            startupSurface = StartupSurface.PAIRING
                                        }
                                    },
                                )
                            StartupSurface.PAIRING ->
                                PairingExperience(
                                    environment = pairingEnvironment,
                                    script = pairingScript,
                                    onPaired = ::acceptPairedCamera,
                                    onOpenSettings = { standaloneSettingsPresented = true },
                                )
                        }
                        if (standaloneSettingsPresented) {
                            val standaloneAssist =
                                remember {
                                    AssistState.restore(
                                        applicationContext,
                                        intentEffects = null,
                                        intentScope = null,
                                        availableStoredLut = lutLibrary::contains,
                                    )
                                }
                            LaunchedEffect(standaloneAssist) {
                                standaloneAssist.activateEffectsMirror()
                            }
                            OperatorSettingsScreen(
                                session = null,
                                assistState = standaloneAssist,
                                settings = operatorSettings,
                                mediaCacheStore = mediaCacheStore,
                                frameioController = frameioController,
                                lutLibrary = lutLibrary,
                                initialTab = OperatorSettingsTab.STORAGE,
                                systemSettingsActions = systemSettingsActions,
                                liveViewGuideController = liveViewGuide,
                                onShowGuideOnNextRealFrame =
                                    liveViewGuide::replayOnNextRealFrame,
                                onClose = { standaloneSettingsPresented = false },
                            )
                        }
                    }
                } else {
                    LaunchedEffect(active, pairingEnvironment) {
                        try {
                            awaitCancellation()
                        } finally {
                            withContext(NonCancellable) {
                                active.disconnect()
                                pairingEnvironment.releaseCameraAp()
                            }
                        }
                    }
                    if (SwiftCore.isAvailable) {
                        // The real shell needs the shared core's zone map. An APK
                        // built without `just android-core` (plain CI android-check)
                        // has no native library, so it keeps the placeholder.
                        // Settings and Media render as mutually-exclusive,
                        // full-screen surfaces over the monitor so the shell keeps
                        // its state while either surface owns interaction.
                        var overlay by rememberSaveable {
                            mutableStateOf(
                                if (DemoHarness.opensMedia(intent)) {
                                    MonitorOverlay.MEDIA
                                } else {
                                    MonitorOverlay.NONE
                                },
                            )
                        }
                        val assist = remember(active) {
                            AssistState.restore(
                                applicationContext,
                                debugAssistEffects,
                                debugScopes?.firstOrNull(),
                                intentScopes = debugScopes,
                                availableStoredLut = lutLibrary::contains,
                            )
                        }
                        LaunchedEffect(assist) { assist.activateEffectsMirror() }
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
                        val disconnectToSavedCameraHome: (Boolean) -> Unit = { reconnect ->
                            val exitingSession = active
                            val reconnectID = activeSavedCamera?.id
                            suppressedUsbAutoReconnectHosts =
                                usbAutoReconnectSuppressionAfterUserAction(
                                    suppressedHosts = suppressedUsbAutoReconnectHosts,
                                    record = activeSavedCamera,
                                    reconnect = reconnect,
                                )
                            connectionScope.launch {
                                // Finish this exact profile's slot and AP
                                // lease before SavedCamerasExperience gets a
                                // chance to own a reconnect. Its cleanup is
                                // idempotent with the monitor lifecycle
                                // effect directly above.
                                withContext(NonCancellable) {
                                    exitingSession.disconnect()
                                    pairingEnvironment.releaseCameraAp()
                                }
                                if (monitorSession === exitingSession) {
                                    monitorSession = null
                                    startupSurface = StartupSurface.SAVED_CAMERAS
                                    requestedReconnectID = if (reconnect) reconnectID else null
                                }
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
                        Box {
                            MonitorScreen(
                                active,
                                frameSource = demo?.second,
                                assist = assist,
                                operatorSettings = operatorSettings,
                                lutLibrary = lutLibrary,
                                liveViewEnabled = overlay != MonitorOverlay.MEDIA,
                                glassTierOverride = DemoHarness.glassTierOverride(intent),
                                mediaRemoteShutter = mediaRemoteShutter,
                                isMonitorFront = overlay == MonitorOverlay.NONE,
                                linkHealth = monitorLinkHealth,
                                activeTransportIsUsb =
                                    activeSavedCamera?.transport == SavedCameraTransport.USB_C,
                                isDemoSession = pairingScript != null || demo?.second != null,
                                liveViewGuideController = liveViewGuide,
                                onOpenSettings = {
                                    mediaRemoteShutter.disarm()
                                    overlay = MonitorOverlay.SETTINGS
                                },
                                onOpenMedia = {
                                    mediaRemoteShutter.disarm()
                                    overlay = MonitorOverlay.MEDIA
                                },
                            )
                            when (overlay) {
                                MonitorOverlay.NONE -> Unit
                                MonitorOverlay.SETTINGS ->
                                    OperatorSettingsScreen(
                                        session = active,
                                        assistState = assist,
                                        settings = operatorSettings,
                                        mediaCacheStore = mediaCacheStore,
                                        frameioController = frameioController,
                                        lutLibrary = lutLibrary,
                                        linkHealth = monitorLinkHealth,
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
                                        liveViewGuideController = liveViewGuide,
                                        onShowGuideNow = {
                                            liveViewGuide.replayNow()
                                            overlay = MonitorOverlay.NONE
                                        },
                                        onShowGuideOnNextRealFrame = {
                                            liveViewGuide.replayOnNextRealFrame()
                                            overlay = MonitorOverlay.NONE
                                        },
                                        onClose = { overlay = MonitorOverlay.NONE },
                                    )
                                MonitorOverlay.MEDIA ->
                                    MediaBrowseScreen(
                                        cameraID = cameraID,
                                        cameraConnected =
                                            currentSessionState is CameraSessionState.Connected,
                                        liveAssistState = assist,
                                        exposureAssistCameraInput = playbackExposureAssistCameraInput,
                                        operatorSettings = operatorSettings,
                                        lutLibrary = lutLibrary,
                                        frameioController = frameioController,
                                        selectedLut = assist.selectedLut,
                                        autoPlayFirstProxy = DemoHarness.autoPlaysMedia(intent),
                                        galleryFailureInjection =
                                            DemoHarness.galleryFailureInjection(intent),
                                        onClose = { overlay = MonitorOverlay.NONE },
                                    )
                            }
                        }
                        BackHandler(enabled = overlay == MonitorOverlay.SETTINGS) {
                            overlay = MonitorOverlay.NONE
                        }
                    } else {
                        MonitorShell(active, frameSource = demo?.second)
                    }
                }
            }
        }
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

    private fun publishFrameioRedirect(newIntent: Intent) {
        if (newIntent.action != Intent.ACTION_VIEW) return
        newIntent.dataString?.takeIf(String::isNotBlank)?.let { callbackURI ->
            frameioRedirectCallback.value = FrameioRedirectCallback(callbackURI)
            // Do not retain an OAuth callback (and its one-time code) in the
            // Activity intent after handing it to the process-local verifier.
            newIntent.data = null
        }
    }

    /** Hides (monitor) or shows (pairing) the system bars; styling stays transparent-dark. */
    private fun setSystemBarsHidden(hidden: Boolean) {
        // BEHAVIOR_DEFAULT, not TRANSIENT_BARS_BY_SWIPE: the swipe reveal is
        // equally transient on this device under both, but only DEFAULT emits
        // the legacy system-UI visibility event MonitorScreen listens to for
        // the rail shift (verified on the SM-A127F — transient mode emits no
        // observable signal at all).
        WindowCompat.getInsetsController(window, window.decorView).apply {
            systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_DEFAULT
            if (hidden) {
                hide(WindowInsetsCompat.Type.systemBars())
            } else {
                show(WindowInsetsCompat.Type.systemBars())
            }
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
fun MonitorShell(session: CameraSession, frameSource: LiveFrameSource? = null) {
    val state by session.state.collectAsState()

    LaunchedEffect(session) { session.connect() }

    Box(
        modifier = Modifier.fillMaxSize().background(BrandColors.background),
        contentAlignment = Alignment.Center,
    ) {
        when (val current = state) {
            is CameraSessionState.Connected ->
                if (frameSource != null) {
                    LiveFeedView(frameSource, modifier = Modifier.fillMaxSize())
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

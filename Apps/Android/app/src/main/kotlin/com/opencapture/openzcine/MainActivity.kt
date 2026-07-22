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
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
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
import com.opencapture.openzcine.core.CameraSession
import com.opencapture.openzcine.core.CameraSessionState
import com.opencapture.openzcine.bridge.SwiftCore
import com.opencapture.openzcine.bridge.SwiftCoreSmoke
import com.opencapture.openzcine.bridge.AndroidLinkHealthMonitor
import com.opencapture.openzcine.bridge.SwiftCoreCameraSession
import com.opencapture.openzcine.bridge.SwiftCoreLiveFrameSource
import com.opencapture.openzcine.core.LiveFrameSource
import com.opencapture.openzcine.frameio.AndroidFrameioCameraApHop
import com.opencapture.openzcine.frameio.FrameioInternetHopState
import com.opencapture.openzcine.frameio.FrameioRedirectCallback
import com.opencapture.openzcine.frameio.frameioDeliveryController
import com.opencapture.openzcine.diagnostics.AndroidAppDiagnostics
import com.opencapture.openzcine.diagnostics.AndroidBugReportClient
import com.opencapture.openzcine.diagnostics.AndroidDiagnosticEvent
import com.opencapture.openzcine.diagnostics.AndroidSystemSettingsActions
import com.opencapture.openzcine.media.MediaBrowseScreen
import com.opencapture.openzcine.media.MediaCacheStore
import com.opencapture.openzcine.media.MediaDeliveryCompletionToast
import com.opencapture.openzcine.media.MediaDeliveryCoordinator
import com.opencapture.openzcine.media.MediaDeliveryProgressOverlay
import com.opencapture.openzcine.media.MediaLibraryCameraBucket
import com.opencapture.openzcine.media.MediaLibraryIndex
import com.opencapture.openzcine.media.SharedPreferencesMediaLibraryPreferences
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.windowInsetsPadding
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
import kotlinx.coroutines.Dispatchers
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
        val operatorSettings =
            OperatorSettings(applicationContext).also { settings ->
                debugPortraitAspect?.let { settings.portraitFeedAspect = it }
            }
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
                val mediaLibraryIndex =
                    remember {
                        MediaLibraryIndex(
                            SharedPreferencesMediaLibraryPreferences(applicationContext),
                        )
                    }
                val frameioController =
                    remember { frameioDeliveryController(applicationContext, lutLibrary) }
                // App-scoped share/export progress (iOS MediaDeliveryCoordinator).
                val mediaDeliveryCoordinator =
                    remember(frameioController) {
                        MediaDeliveryCoordinator(
                            appContext = applicationContext,
                            frameioController = frameioController,
                        )
                    }
                LaunchedEffect(frameioController.deliveryState) {
                    mediaDeliveryCoordinator.bindFrameioDeliveryState(frameioController.deliveryState)
                }
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
                // Read once: a pre-parity Android installation paired every
                // saved card with one static PTP-IP GUID. The production
                // environment migrates that identity only on this upgrade;
                // new installs receive their own persisted identity instead.
                val hasSavedCameraProfilesAtLaunch = remember { savedCameras.isNotEmpty() }
                // Offline Media: per-camera card entry or the global startup
                // Media Library (all complete caches), matching iOS
                // `openCachedMediaLibrary` / listAllCachedClips.
                var offlineMediaBuckets by
                    remember { mutableStateOf<List<MediaLibraryCameraBucket>?>(null) }
                var completedMediaBuckets by
                    remember { mutableStateOf(emptyMap<String, MediaLibraryCameraBucket>()) }
                var mediaCacheRevision by remember { mutableStateOf(0) }
                LaunchedEffect(savedCameras, monitorSession, offlineMediaBuckets, mediaCacheRevision) {
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
                // Keep the process-wide camera-AP binding alive while its
                // handed-off session is active, then release it alongside the
                // PTP slot when this activity or session leaves composition.
                // Creating this once also prevents recomposition from
                // orphaning a CameraApJoiner callback.
                val pairingEnvironment =
                    remember(pairingScript) {
                        pairingScript?.environment
                            ?: realPairingEnvironment(
                                applicationContext,
                                hasLegacySavedCameraProfiles = hasSavedCameraProfilesAtLaunch,
                            ) { phase, _ ->
                                AndroidDiagnosticEvent.fromFailurePhase(phase)?.let {
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
                var standaloneSettingsPresented by
                    rememberSaveable { mutableStateOf(debugInitialSettingsTab != null) }
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

                fun acceptPairedCamera(paired: PairedCamera) {
                    activeSavedCamera = persistPairedCameraProfile(paired.savedCamera)
                    monitorSession = paired.session
                }
                // Startup and monitor are both immersive; re-assert whenever
                // the surface changes so a transient swipe-reveal on one
                // surface never leaks bars onto the next.
                val immersive = monitorSession != null || offlineMediaBuckets != null
                LaunchedEffect(immersive) { applyImmersiveSystemBars() }
                LaunchedEffect(immersive, operatorSettings.keepScreenAwake.value) {
                    if (operatorSettings.shouldKeepScreenAwake(immersive)) {
                        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    } else {
                        window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    }
                }
                val active = monitorSession
                val offlineBuckets = offlineMediaBuckets
                if (active == null && offlineBuckets != null) {
                    val primary = offlineBuckets.firstOrNull()
                    val offlineAssist =
                        remember(primary?.cameraID, offlineBuckets.size) {
                            AssistState.restore(
                                applicationContext,
                                intentEffects = null,
                                intentScope = null,
                                availableStoredLut = lutLibrary::contains,
                            )
                        }
                    LaunchedEffect(offlineAssist) { offlineAssist.activateEffectsMirror() }
                    MediaBrowseScreen(
                        cameraID = primary?.cameraID ?: "offline-all-cameras",
                        cameraConnected = false,
                        cameraSessionAvailable = false,
                        savedCameraID = primary?.savedCameraID,
                        cameraDisplayName =
                            when {
                                offlineBuckets.isEmpty() -> "Media Library"
                                offlineBuckets.size == 1 -> offlineBuckets.first().displayName
                                else -> "All cameras"
                            },
                        offlineCameraIDs = offlineBuckets.map { it.cameraID },
                        liveAssistState = offlineAssist,
                        exposureAssistCameraInput = ExposureAssistCameraInput(),
                        operatorSettings = operatorSettings,
                        lutLibrary = lutLibrary,
                        frameioController = frameioController,
                        mediaDeliveryCoordinator = mediaDeliveryCoordinator,
                        selectedLut = offlineAssist.selectedLut,
                        onClose = { offlineMediaBuckets = null },
                    )
                } else if (active == null) {
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
                                    onOpenMediaLibrary = {
                                        // iOS openCachedMediaLibrary: every
                                        // complete on-device cache bucket.
                                        offlineMediaBuckets =
                                            completedMediaBuckets.values.toList()
                                    },
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
                                    onPairingProfilePrepared = ::persistPairedCameraProfile,
                                    onOpenSettings = { standaloneSettingsPresented = true },
                                    onShowSavedCameras =
                                        if (savedCameras.isEmpty()) {
                                            null
                                        } else {
                                            { startupSurface = StartupSurface.SAVED_CAMERAS }
                                        },
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
                                // iOS's startup Settings lands on Link; a debug
                                // intent can still force a specific tab.
                                initialTab = debugInitialSettingsTab ?: OperatorSettingsTab.LINK,
                                systemSettingsActions = systemSettingsActions,
                                bugReportSubmitter = bugReportSubmitter,
                                bugReportActivityLogProvider = diagnostics::privacyFilteredActivityLog,
                                liveViewGuideController = liveViewGuide,
                                onShowGuideOnNextRealFrame =
                                    liveViewGuide::replayOnNextRealFrame,
                                onCompletedMediaCacheCleared = { mediaCacheRevision += 1 },
                                onClose = { standaloneSettingsPresented = false },
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
                                monitorSession = null
                                startupSurface = StartupSurface.SAVED_CAMERAS
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
                        Box {
                            MonitorScreen(
                                active,
                                frameSource = demo?.second,
                                assist = assist,
                                operatorSettings = operatorSettings,
                                lutLibrary = lutLibrary,
                                frameioController = frameioController,
                                // Media already owned this gate. Settings also
                                // drops every preview consumer so the native
                                // live-view pump and GPU decode path release
                                // while Operator Setup is on top — otherwise
                                // the full-screen sheet fights the feed for
                                // CPU/GPU on lower-tier phones.
                                liveViewEnabled = overlay == MonitorOverlay.NONE,
                                glassTierOverride = DemoHarness.glassTierOverride(intent),
                                mediaRemoteShutter = mediaRemoteShutter,
                                isMonitorFront = overlay == MonitorOverlay.NONE,
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
                                        bugReportSubmitter = bugReportSubmitter,
                                        bugReportActivityLogProvider = diagnostics::privacyFilteredActivityLog,
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
                                        savedCameraID = activeSavedCamera?.id,
                                        cameraDisplayName = activeSavedCamera?.displayTitle,
                                        cameraStorageSlots = currentCameraProperties.storageSlots,
                                        liveAssistState = assist,
                                        exposureAssistCameraInput = playbackExposureAssistCameraInput,
                                        operatorSettings = operatorSettings,
                                        lutLibrary = lutLibrary,
                                        frameioController = frameioController,
                                        mediaDeliveryCoordinator = mediaDeliveryCoordinator,
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
                        MonitorShell(
                            active,
                            frameSource = demo?.second,
                            sessionRecoveryEnabled = monitorSessionRecoveryEnabled,
                        )
                    }
                }
                // Global delivery progress (iOS MediaDeliveryGlobalOverlay) — survives
                // leaving media browser / playback while export or Frame.io upload runs.
                mediaDeliveryCoordinator.overlayState?.let { state ->
                    Box(
                        Modifier
                            .align(Alignment.TopCenter)
                            .windowInsetsPadding(WindowInsets.safeDrawing)
                            .padding(top = 12.dp, start = 16.dp, end = 16.dp),
                    ) {
                        MediaDeliveryProgressOverlay(
                            state = state,
                            expanded = mediaDeliveryCoordinator.isExpanded,
                            onCancel = mediaDeliveryCoordinator::cancel,
                            onExpandToggle = {
                                mediaDeliveryCoordinator.isExpanded =
                                    !mediaDeliveryCoordinator.isExpanded
                            },
                        )
                    }
                }
                mediaDeliveryCoordinator.completionToast?.let { toast ->
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

package com.opencapture.openzcine

import android.content.pm.ApplicationInfo
import android.graphics.Color
import android.net.nsd.NsdManager
import android.os.Bundle
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
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import com.opencapture.openzcine.core.CameraSession
import com.opencapture.openzcine.core.CameraSessionState
import com.opencapture.openzcine.bridge.SwiftCore
import com.opencapture.openzcine.bridge.SwiftCoreSmoke
import com.opencapture.openzcine.core.LiveFrameSource
import com.opencapture.openzcine.media.MediaBrowseScreen
import com.opencapture.openzcine.media.MediaCacheStore
import com.opencapture.openzcine.pairing.PairedCamera
import com.opencapture.openzcine.pairing.PairingExperience
import com.opencapture.openzcine.pairing.SavedCameraRecords
import com.opencapture.openzcine.pairing.SavedCamerasExperience
import com.opencapture.openzcine.pairing.SharedPreferencesSavedCameraStore
import com.opencapture.openzcine.pairing.realPairingEnvironment
import com.opencapture.openzcine.settings.OperatorSettings
import com.opencapture.openzcine.settings.OperatorSettingsScreen
import com.opencapture.openzcine.settings.OperatorSettingsTab
import com.opencapture.openzcine.transport.AndroidNsdBrowser
import com.opencapture.openzcine.transport.NsdCameraSessionFactory
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.awaitCancellation
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
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
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
        val debugSession: CameraSession? =
            demo?.first ?: if (isNsdTransportRequested()) nsdTransportSession() else null
        val pairingScript = DemoHarness.pairingScript(intent)
        setContent {
            OpenZCineTheme {
                var monitorSession by remember { mutableStateOf(debugSession) }
                val savedCameraStore =
                    remember { SharedPreferencesSavedCameraStore(applicationContext) }
                val operatorSettings = remember { OperatorSettings(applicationContext) }
                val mediaCacheStore =
                    remember {
                        MediaCacheStore(
                            applicationContext.noBackupFilesDir.resolve("media-cache").toPath(),
                        )
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
                                        FeedEffects.NONE,
                                        intentScope = null,
                                    )
                                }
                            OperatorSettingsScreen(
                                session = null,
                                assistState = standaloneAssist,
                                settings = operatorSettings,
                                mediaCacheStore = mediaCacheStore,
                                initialTab = OperatorSettingsTab.STORAGE,
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
                                FeedEffectsState.current,
                                DemoHarness.scopeKind(intent),
                                DemoHarness.scopeKinds(intent),
                            )
                        }
                        val currentSessionState by active.state.collectAsState()
                        val cameraID =
                            (currentSessionState as? CameraSessionState.Connected)
                                ?.identity
                                ?.let { identity ->
                                    identity.serialNumber.ifBlank {
                                        "${identity.model}:${identity.name}"
                                    }
                                }
                                ?: "camera"
                        Box {
                            MonitorScreen(
                                active,
                                frameSource = demo?.second,
                                assist = assist,
                                operatorSettings = operatorSettings,
                                liveViewEnabled = overlay != MonitorOverlay.MEDIA,
                                glassTierOverride = DemoHarness.glassTierOverride(intent),
                                onOpenSettings = { overlay = MonitorOverlay.SETTINGS },
                                onOpenMedia = { overlay = MonitorOverlay.MEDIA },
                            )
                            when (overlay) {
                                MonitorOverlay.NONE -> Unit
                                MonitorOverlay.SETTINGS ->
                                    OperatorSettingsScreen(
                                        session = active,
                                        assistState = assist,
                                        settings = operatorSettings,
                                        mediaCacheStore = mediaCacheStore,
                                        onClose = { overlay = MonitorOverlay.NONE },
                                    )
                                MonitorOverlay.MEDIA ->
                                    MediaBrowseScreen(
                                        cameraID = cameraID,
                                        cameraConnected =
                                            currentSessionState is CameraSessionState.Connected,
                                        autoPlayFirstProxy = DemoHarness.autoPlaysMedia(intent),
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

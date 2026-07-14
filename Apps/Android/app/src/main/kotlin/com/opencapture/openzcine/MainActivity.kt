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
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import com.opencapture.openzcine.core.CameraSession
import com.opencapture.openzcine.core.CameraSessionState
import com.opencapture.openzcine.bridge.SwiftCore
import com.opencapture.openzcine.bridge.SwiftCoreSmoke
import com.opencapture.openzcine.core.LiveFrameSource
import com.opencapture.openzcine.pairing.PairingExperience
import com.opencapture.openzcine.pairing.realPairingEnvironment
import com.opencapture.openzcine.transport.AndroidNsdBrowser
import com.opencapture.openzcine.transport.NsdCameraSessionFactory

/**
 * App entry point: the pairing wizard first (camera-AP and phone-hotspot
 * paths), handing a connected [CameraSession] to the monitor shell. Debug
 * hooks (demo feed, NSD transport probe) bypass pairing straight to the
 * monitor, preserving the existing capture workflows.
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
                // The monitor is immersive; the pairing screens keep the
                // (transparent, dark-styled) system bars, like the iOS
                // startup screens keep the status bar.
                val immersive = monitorSession != null
                LaunchedEffect(immersive) { setSystemBarsHidden(immersive) }
                val active = monitorSession
                if (active == null) {
                    PairingExperience(
                        environment = pairingScript?.environment
                            ?: realPairingEnvironment(this@MainActivity),
                        script = pairingScript,
                        onPaired = { monitorSession = it },
                    )
                } else if (SwiftCore.isAvailable) {
                    // The real shell needs the shared core's zone map. An APK
                    // built without `just android-core` (plain CI android-check)
                    // has no native library, so it keeps the placeholder.
                    MonitorScreen(active, frameSource = demo?.second)
                } else {
                    MonitorShell(active, frameSource = demo?.second)
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

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
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import com.opencapture.openzcine.core.CameraSession
import com.opencapture.openzcine.core.CameraSessionState
import com.opencapture.openzcine.bridge.SwiftCore
import com.opencapture.openzcine.bridge.SwiftCoreSmoke
import com.opencapture.openzcine.core.FakeCameraSession
import com.opencapture.openzcine.core.LiveFrameSource
import com.opencapture.openzcine.transport.AndroidNsdBrowser
import com.opencapture.openzcine.transport.NsdCameraSessionFactory

/**
 * App entry point: a full-screen placeholder monitor shell fed by the
 * [CameraSession] seam. Real chrome (controls, scopes, panels) comes later;
 * this only proves the shell-to-core boundary end to end.
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
        // BEHAVIOR_DEFAULT, not TRANSIENT_BARS_BY_SWIPE: the swipe reveal is
        // equally transient on this device under both, but only DEFAULT emits
        // the legacy system-UI visibility event MonitorScreen listens to for
        // the rail shift (verified on the SM-A127F — transient mode emits no
        // observable signal at all).
        WindowCompat.getInsetsController(window, window.decorView).apply {
            systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_DEFAULT
            hide(WindowInsetsCompat.Type.systemBars())
        }
        // ponytail: fake backend by default until the real core lands behind
        // the seam; DI arrives with the first production implementation. Two
        // debug-only overrides: the demo harness (synthetic feed) wins, then
        // the NSD discovery + socket transport path.
        val demo = DemoHarness.demoLiveFeed(intent)
        val session: CameraSession =
            demo?.first
                ?: if (isNsdTransportRequested()) nsdTransportSession() else FakeCameraSession()
        setContent {
            OpenZCineTheme {
                if (SwiftCore.isAvailable) {
                    // The real shell needs the shared core's zone map. An APK
                    // built without `just android-core` (plain CI android-check)
                    // has no native library, so it keeps the placeholder.
                    MonitorScreen(
                        session,
                        frameSource = demo?.second,
                        glassTierOverride = DemoHarness.glassTierOverride(intent),
                    )
                } else {
                    MonitorShell(session, frameSource = demo?.second)
                }
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

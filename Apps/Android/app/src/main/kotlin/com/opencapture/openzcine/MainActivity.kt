package com.opencapture.openzcine

import android.content.pm.ApplicationInfo
import android.net.nsd.NsdManager
import android.os.Bundle
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
import com.opencapture.openzcine.core.FakeCameraSession
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
        enableEdgeToEdge()
        // ponytail: fake backend by default until the real core lands behind
        // the seam; DI arrives with the first production implementation.
        val session: CameraSession =
            if (isNsdTransportRequested()) nsdTransportSession() else FakeCameraSession()
        setContent {
            OpenZCineTheme {
                MonitorShell(session)
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
 * [session]. The "No camera" state is the only state the fake reaches.
 */
@Composable
fun MonitorShell(session: CameraSession) {
    val state by session.state.collectAsState()

    LaunchedEffect(session) { session.connect() }

    Box(
        modifier = Modifier.fillMaxSize().background(BrandColors.background),
        contentAlignment = Alignment.Center,
    ) {
        when (val current = state) {
            is CameraSessionState.Connected ->
                Text(
                    text = current.identity.name,
                    color = BrandColors.accent,
                    style = MaterialTheme.typography.titleMedium,
                )

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

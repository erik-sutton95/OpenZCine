package com.opencapture.openzcine

import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import com.opencapture.opencine.appkit.CamerasModel
import com.opencapture.opencine.appkit.MonitorAssistState
import com.opencapture.opencine.appkit.MonitorControlModel
import com.opencapture.opencine.appkit.MonitorOperatorSessionModel
import com.opencapture.opencine.appkit.SavedCamerasStore
import com.opencapture.opencine.appkit.ShellModel
import com.opencapture.opencine.appkit.StoredString
import com.opencapture.opencine.nikon.CameraSession
import com.opencapture.opencine.nikon.NikonOpenCineSession
import com.opencapture.openzcine.settings.OperatorSettings

/** An in-memory assist set with nothing switched on and nothing saved. */
internal fun idleNikonAssists(): NikonAssists =
    NikonAssists(MonitorAssistState().apply { syncVisible(emptySet()) }, FeedLutSelection.BuiltIn(FeedLut.LOG3G10_709)) {}

/** The monitor's display owner as MainActivity builds it, over a shell with no saved cameras. */
@Composable
internal fun rememberTestOperatorSession(assists: NikonAssists, settings: OperatorSettings): MonitorOperatorSessionModel {
    val scope = rememberCoroutineScope()
    return remember(assists, settings) {
        val document = object : StoredString {
            var value: String? = null
            override fun read(): String? = value
            override fun write(value: String) { this.value = value }
        }
        val shell = ShellModel(CamerasModel(emptyList(), SavedCamerasStore(document), scope), MonitorControlModel(scope))
        MonitorOperatorSessionModel(shell, assists.shared, settings.displayPreferences, scope)
    }
}

/** The production live monitor over [session], with no feed and no recovery, as tests drive it. */
@Composable
internal fun TestMonitorScreen(session: CameraSession, assists: NikonAssists, settings: OperatorSettings) {
    val scope = rememberCoroutineScope()
    val common = remember(session) { NikonOpenCineSession(session, scope) }
    val control = remember(common) { MonitorControlModel(scope).also { it.bind(common) } }
    DisposableEffect(control) { onDispose { control.unbind() } }
    OpenZCineTheme {
        MonitorScreen(session, common, control, rememberTestOperatorSession(assists, settings), frameSource = null,
            assists = assists, operatorSettings = settings, liveViewEnabled = false, sessionRecoveryEnabled = false)
    }
}

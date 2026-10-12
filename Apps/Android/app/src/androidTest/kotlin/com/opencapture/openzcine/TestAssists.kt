package com.opencapture.openzcine

import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import com.opencapture.opencine.appkit.CamerasModel
import com.opencapture.opencine.appkit.MonitorAssistState
import com.opencapture.opencine.appkit.MonitorControlModel
import com.opencapture.opencine.appkit.MonitorOperatorSessionModel
import com.opencapture.opencine.appkit.SavedCamerasStore
import com.opencapture.opencine.appkit.ShellModel
import com.opencapture.opencine.appkit.StoredString
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

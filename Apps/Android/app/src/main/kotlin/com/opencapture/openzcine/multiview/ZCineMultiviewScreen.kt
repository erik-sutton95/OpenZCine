package com.opencapture.openzcine.multiview

import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import com.opencapture.opencine.appkit.MultiviewScreen

/**
 * Android Multiview. As iOS: OpenCine's shared Multiview screen (stage, Add list, camera settings
 * popup, Live View hand-off, prompts) over [stage], which hosts what only OpenZCine has: each
 * tile's picture with its Auto LUT, the readings, the settings editor and the Live View loan to the
 * app's one monitor. [recordConfirmation] is the operator's Settings preference; [endLiveView] ends
 * the monitor's loan (the monitor then returns the session to its tile).
 */
@Composable
internal fun ZCineMultiviewScreen(
    stage: ZCineMultiview,
    recordConfirmation: () -> Boolean,
    endLiveView: () -> Unit,
    onClose: () -> Unit,
) {
    val confirms by rememberUpdatedState(recordConfirmation)
    val end by rememberUpdatedState(endLiveView)
    DisposableEffect(stage) {
        stage.recordConfirmation = { confirms() }
        stage.endLiveView = { end() }
        onDispose { stage.endLiveView = {} }
    }
    MultiviewScreen(stage.coordinator, stage, onClose, Modifier.testTag("multicam.stage"))
}

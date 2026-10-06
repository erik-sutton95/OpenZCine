package com.opencapture.openzcine

import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.opencapture.opencine.vocabulary.SessionDropSuspect
import com.opencapture.opencine.vocabulary.SessionRecoveryCopy
import com.opencapture.opencine.vocabulary.SessionRecoveryUi
import kotlinx.coroutines.delay
import com.opencapture.opencine.appkit.MonitorRecoveryOverlay as SharedRecoveryCard

/**
 * Recovery affordance over a **held** live-view frame after an established
 * session dropped: the shared recovery card with this camera's copy.
 *
 * A knocked cable or a camera power cycle must not throw a shoot back to the
 * connect screen, so the operator stays in the monitor. Two ways out: retry
 * here, or leave for the operator menu.
 */
@Composable
internal fun MonitorRecoveryOverlay(
    state: SessionRecoveryUi,
    cameraName: String,
    onRetry: () -> Unit,
    onBackToOperatorMenu: () -> Unit,
    modifier: Modifier = Modifier,
) {
    if (state is SessionRecoveryUi.Idle) return
    // The first automatic retry fires immediately and usually heals a blip within a second;
    // flashing the full card for that was the "retry prompt for like a sec" (iOS twin). The
    // card waits out a short grace on attempt 1; attempt 2+ and the give-up state show at once.
    var graceElapsed by remember { mutableStateOf(false) }
    LaunchedEffect(state !is SessionRecoveryUi.Idle) {
        graceElapsed = false
        delay(2_500)
        graceElapsed = true
    }
    if (state is SessionRecoveryUi.Retrying && state.attempt <= 1 && !graceElapsed) return
    SharedRecoveryCard(
        retrying = state is SessionRecoveryUi.Retrying,
        title = SessionRecoveryCopy.title(state),
        // Nikon bodies drop the session when another phone scans for them, so the paused copy says so.
        detail = SessionRecoveryCopy.detail(state, cameraName, SessionDropSuspect.OTHER_DEVICE_SCANNING),
        retryTitle = SessionRecoveryCopy.RETRY_CONNECTION,
        operatorMenuTitle = SessionRecoveryCopy.OPERATOR_MENU,
        onRetry = onRetry,
        onOperatorMenu = onBackToOperatorMenu,
        modifier = modifier,
        // The platform 48 dp minimum touch target.
        actionMinHeight = 48.dp,
    )
}

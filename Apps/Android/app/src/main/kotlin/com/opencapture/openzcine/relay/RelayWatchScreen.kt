package com.opencapture.openzcine.relay

import android.content.res.Configuration
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.foundation.text.KeyboardOptions
import com.opencapture.openzcine.R

/**
 * The watcher's on-glass control key — iOS `WatcherControlKey`, word for word: one pill
 * reflecting the token so the control and its state cannot disagree, centred above the bottom
 * bars on the live view (never inside a settings sheet). Record is NOT a second pill: holding
 * control mounts the monitor's own record button (availability-gated), routed over the relay
 * through the watch session — the iOS shape exactly.
 */
@Composable
fun RelayWatchOverlay(
    ui: RelayWatchUiState,
    onAskForControl: () -> Unit,
    onGiveBackControl: () -> Unit,
    onSubmitPasscode: (String) -> Unit,
    onRetry: () -> Unit,
    onLeave: () -> Unit,
) {
    BackHandler(onBack = onLeave)
    // The root Box deliberately carries NO pointer handling: only the pill (and the failure
    // keys) hit-test, so the monitor chrome underneath stays tappable everywhere else.
    Box(Modifier.fillMaxSize()) {
        when (ui.phase) {
            RelayWatchUiState.Phase.WATCHING ->
                if (ui.holdsControl || ui.allowsControlRequests) {
                    // Above the bottom chrome's lane, like iOS (`laneTop - keyHeight - 8`).
                    // Landscape: the bottom bars run 14dp inset + 58dp tall and DISP/settings
                    // live on the right rail, so 84dp floats the pill 12dp above the bars.
                    // Portrait: the system bar (lock/DISP/record/media/settings, 100dp, 14dp
                    // lift) plus the 58dp assist toolbar own the bottom — 84dp sat the pill
                    // ON the system keys. 192 = 100 + 14 + 58 + 12 gap + 8 lane gap.
                    // ponytail: fixed lane clearances; anchoring to the live zone map needs
                    // the monitor shell to export it.
                    val portrait =
                        LocalConfiguration.current.orientation ==
                            Configuration.ORIENTATION_PORTRAIT
                    WatcherKey(
                        text =
                            stringResource(
                                if (ui.holdsControl) {
                                    R.string.relay_give_back_control
                                } else {
                                    R.string.relay_ask_for_control
                                }
                            ),
                        accented = ui.holdsControl,
                        onClick = if (ui.holdsControl) onGiveBackControl else onAskForControl,
                        modifier =
                            Modifier.align(Alignment.BottomCenter)
                                .padding(bottom = if (portrait) 192.dp else 84.dp),
                    )
                }
            RelayWatchUiState.Phase.CONNECTING ->
                CenteredNotice(text = stringResource(R.string.relay_watch_connecting))
            RelayWatchUiState.Phase.FAILED ->
                Column(
                    Modifier.align(Alignment.Center),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    Text(
                        ui.failureReason ?: stringResource(R.string.relay_watch_dropped),
                        color = Color.White.copy(alpha = 0.9f),
                        fontSize = 14.sp,
                        textAlign = TextAlign.Center,
                    )
                    Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        WatcherKey(
                            text = stringResource(R.string.relay_try_again),
                            accented = true,
                            onClick = onRetry,
                        )
                        WatcherKey(
                            text = stringResource(R.string.relay_leave),
                            accented = false,
                            onClick = onLeave,
                        )
                    }
                }
            RelayWatchUiState.Phase.DENIED -> Unit
        }
        if (ui.phase == RelayWatchUiState.Phase.DENIED && ui.needsPasscode) {
            var draft by remember { mutableStateOf("") }
            AlertDialog(
                onDismissRequest = onLeave,
                title = { Text(stringResource(R.string.relay_passcode_title)) },
                text = {
                    Column {
                        Text(
                            if (ui.passcodeWasWrong) {
                                stringResource(R.string.relay_passcode_wrong)
                            } else {
                                stringResource(R.string.relay_passcode_body)
                            }
                        )
                        Spacer(Modifier.height(8.dp))
                        OutlinedTextField(
                            value = draft,
                            onValueChange = { new ->
                                draft = new.filter(Char::isDigit).take(4)
                                if (draft.length == 4) onSubmitPasscode(draft)
                            },
                            singleLine = true,
                            keyboardOptions =
                                KeyboardOptions(keyboardType = KeyboardType.Number),
                            label = { Text(stringResource(R.string.relay_passcode_hint)) },
                        )
                    }
                },
                confirmButton = {
                    TextButton(
                        onClick = { if (draft.length == 4) onSubmitPasscode(draft) },
                    ) {
                        Text(stringResource(R.string.action_connect))
                    }
                },
                dismissButton = {
                    TextButton(onClick = onLeave) {
                        Text(stringResource(R.string.action_cancel))
                    }
                },
            )
        }
    }
}

@Composable
private fun WatcherKey(
    text: String,
    accented: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val accent = Color(0xFFE0A73A)
    Text(
        text,
        color = if (accented) accent else Color.White,
        fontSize = 12.sp,
        fontWeight = FontWeight.Bold,
        letterSpacing = 0.8.sp,
        modifier =
            modifier.background(Color.Black.copy(alpha = 0.55f), CircleShape)
                .border(
                    1.dp,
                    if (accented) accent else Color.White.copy(alpha = 0.25f),
                    CircleShape,
                )
                .clickable(onClick = onClick)
                .padding(horizontal = 16.dp, vertical = 9.dp),
    )
}

@Composable
private fun CenteredNotice(text: String) {
    Box(Modifier.fillMaxSize()) {
        Text(
            text,
            color = Color.White.copy(alpha = 0.85f),
            fontSize = 14.sp,
            modifier = Modifier.align(Alignment.Center),
        )
    }
}

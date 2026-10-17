package com.opencapture.openzcine.gyro

import android.content.ClipData
import android.content.Context
import android.content.Intent
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.core.content.FileProvider
import com.opencapture.monitorui.MonitorPalette
import com.opencapture.monitorui.MonitorConfirmPopup
import com.opencapture.monitorui.settings.MonitorSettingsActionPill
import com.opencapture.monitorui.settings.MonitorSettingsRowCard
import java.io.File
import java.text.DateFormat
import java.util.Date
import java.util.Locale
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job

/** Compact capture health, opening the same logs list as Operator Setup. */
@Composable
internal fun GyroStatusPill(state: GyroCaptureState, modifier: Modifier = Modifier, onClick: () -> Unit) {
    val label = when {
        state.status == "Gyro sample gaps" -> "GYRO GAP"
        state.failed -> "GYRO ERROR"
        state.status == "Saving" -> "GYRO SAVING"
        state.logging -> "GYRO REC"
        state.status == "Ready" -> "GYRO ARMED"
        state.status == "Starting gyroscope" -> "GYRO STARTING"
        else -> "GYRO OFFLINE"
    }
    Text(label, modifier.background(androidx.compose.ui.graphics.Color.Black.copy(alpha = 0.65f),
        RoundedCornerShape(24.dp)).clickable(onClick = onClick).padding(horizontal = 10.dp, vertical = 7.dp)
        .testTag("gyro-status"), color = if (state.failed) MonitorPalette.accent else MonitorPalette.text,
        fontSize = 11.sp, fontWeight = FontWeight.SemiBold, fontFamily = FontFamily.Monospace)
}

/** App-owned motion logs, including incomplete files retained after failed recovery. */
@Composable
internal fun GyroLogsScreen(state: GyroCaptureState, onShare: (GyroLogEntry) -> Unit,
    onDelete: (GyroLogEntry) -> Unit, onClose: () -> Unit) {
    var deleting by remember { mutableStateOf<GyroLogEntry?>(null) }
    BackHandler(onBack = onClose)
    Column(Modifier.fillMaxSize().background(MonitorPalette.background)
        .windowInsetsPadding(WindowInsets.safeDrawing).padding(16.dp)
        .testTag("gyro-logs"), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
            Text("Gyro logs", color = MonitorPalette.text)
            MonitorSettingsActionPill("Close", onClick = onClose)
        }
        Text("Select the matching video and lens profile in Gyroflow. Each log keeps the mount selected for that take.",
            color = MonitorPalette.muted)
        if (state.logging || state.failed) Text(state.status,
            color = if (state.failed) MonitorPalette.accent else MonitorPalette.text)
        state.storageWarning?.let { Text(it, color = MonitorPalette.accent) }
        if (state.logs.isEmpty()) Text("No saved gyro logs. Enable logging in Controls before your next take.",
            color = MonitorPalette.muted)
        LazyColumn(verticalArrangement = Arrangement.spacedBy(10.dp), modifier = Modifier.weight(1f)) {
            items(state.logs, key = { it.id }) { entry ->
                MonitorSettingsRowCard {
                    Text(entry.cameraLabel, color = MonitorPalette.text)
                    Text(DateFormat.getDateTimeInstance().format(Date(entry.startDateMillis)), color = MonitorPalette.muted)
                    Text("Mount: ${entry.mountDetail(state.mountCatalog)}", color = MonitorPalette.muted)
                    entry.summary?.let { summary ->
                        Text(String.format(Locale.US, "%.1f s · %.1f Hz · %s", summary.getDouble("duration"),
                            summary.getDouble("measuredRate"), entry.health), color = MonitorPalette.text)
                        Text(String.format(Locale.US, "Largest gap %.1f ms · Approximate REC offset %+.2f s",
                            summary.getDouble("largestGap") * 1_000,
                            summary.getDouble("approximateStartOffset")), color = MonitorPalette.muted)
                    } ?: Text(entry.health, color = MonitorPalette.muted)
                    Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        MonitorSettingsActionPill("Share", modifier = Modifier.testTag("gyro-share-${entry.id}"),
                            enabled = entry.canShare, onClick = { onShare(entry) })
                        MonitorSettingsActionPill("Delete", modifier = Modifier.testTag("gyro-delete-${entry.id}"),
                            enabled = !entry.active, onClick = { deleting = entry })
                    }
                }
            }
        }
    }
    deleting?.let { entry ->
        Dialog(onDismissRequest = { deleting = null }, properties = DialogProperties(usePlatformDefaultWidth = false)) {
            Box(Modifier.testTag("gyro-delete-confirmation")) {
                MonitorConfirmPopup("Delete gyro log?", "Delete", onDismiss = { deleting = null },
                    onConfirm = { deleting = null; onDelete(entry) })
            }
        }
    }
}

/** Stages off Main under the activity's scope; chooser and failure callbacks run on Main. */
internal fun shareGyroLog(context: Context, entry: GyroLogEntry, scope: CoroutineScope,
    onFailure: (Exception) -> Unit): Job = shareGyroLog(scope, context.cacheDir, entry,
    onReady = { staged -> presentGyroLog(context, staged) }, onFailure = onFailure)

private fun presentGyroLog(context: Context, staged: File) {
    val uri = FileProvider.getUriForFile(context, "${context.packageName}.media-share", staged)
    val send = Intent(Intent.ACTION_SEND).apply {
        type = "text/plain"
        putExtra(Intent.EXTRA_STREAM, uri)
        putExtra(Intent.EXTRA_TITLE, staged.name)
        clipData = ClipData.newRawUri("Gyro log", uri)
        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
    }
    context.startActivity(Intent.createChooser(send, "Share gyro log"))
}

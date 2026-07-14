package com.opencapture.openzcine.pairing

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.opencapture.openzcine.core.CameraSessionState
import com.opencapture.openzcine.transport.DiscoveredCamera
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

private sealed interface SavedCameraPhase {
    data object Idle : SavedCameraPhase

    data class Joining(val title: String) : SavedCameraPhase

    data class Connecting(val title: String) : SavedCameraPhase

    data class Error(val message: String) : SavedCameraPhase
}

/**
 * Saved-camera startup surface, matching the iOS shell's durable camera home.
 *
 * It is deliberately the reconnect owner: camera-AP records rejoin only their
 * stored SSID, whereas hotspot records only use discovery/last-known PTP-IP
 * hosts and never ask Android to switch networks. [onOpenSettings] opens
 * app-local operator setup without constructing a camera session.
 */
@Composable
public fun SavedCamerasExperience(
    cameras: List<SavedCameraRecord>,
    environment: PairingEnvironment,
    onPaired: (PairedCamera) -> Unit,
    onPairNewCamera: () -> Unit,
    onOpenSettings: () -> Unit,
    onRecordsChanged: (List<SavedCameraRecord>) -> Unit,
) {
    val scope = rememberCoroutineScope()
    val work = remember { mutableStateOf<Job?>(null) }
    val handedOff = remember { mutableStateOf(false) }
    var phase by remember { mutableStateOf<SavedCameraPhase>(SavedCameraPhase.Idle) }
    var discoveredCameras by remember { mutableStateOf(emptyList<DiscoveredCamera>()) }
    var removalTarget by remember { mutableStateOf<SavedCameraRecord?>(null) }
    var renameTarget by remember { mutableStateOf<SavedCameraRecord?>(null) }
    var renameDraft by remember { mutableStateOf("") }

    LaunchedEffect(environment) {
        environment.hotspotCameras.collect { discoveredCameras = it }
    }
    DisposableEffect(environment) {
        onDispose {
            work.value?.cancel()
            if (!handedOff.value) environment.releaseCameraAp()
        }
    }

    fun resolvedHost(record: SavedCameraRecord): String {
        if (record.transport == SavedCameraTransport.CAMERA_ACCESS_POINT) return record.host
        return discoveredCameras.firstOrNull { camera ->
            camera.host == record.host ||
                SavedCameraRecords.cameraNamesMatch(camera.name, record.cameraName)
        }?.host ?: record.host
    }

    fun reconnect(record: SavedCameraRecord) {
        if (phase !is SavedCameraPhase.Idle && phase !is SavedCameraPhase.Error) return
        handedOff.value = false
        val host = resolvedHost(record)
        work.value =
            scope.launch {
                var session: com.opencapture.openzcine.core.CameraSession? = null
                var handoffSucceeded = false
                try {
                    if (record.transport == SavedCameraTransport.CAMERA_ACCESS_POINT) {
                        val ssid = record.wifiSsid
                        if (ssid == null) {
                            phase =
                                SavedCameraPhase.Error(
                                    "This camera needs its Wi‑Fi network name. Pair it again to refresh the profile.",
                                )
                            return@launch
                        }
                        val key = environment.credentials.passphrase(ssid)
                        if (key == null) {
                            phase =
                                SavedCameraPhase.Error(
                                    "The Wi‑Fi key for $ssid is not available on this phone. Pair again to save it.",
                                )
                            return@launch
                        }
                        phase = SavedCameraPhase.Joining(record.displayTitle)
                        if (!environment.joinCameraAp(ssid, key)) {
                            phase =
                                SavedCameraPhase.Error(
                                    "Couldn't join $ssid. Check the camera is powered on and try again.",
                                )
                            return@launch
                        }
                    }

                    phase = SavedCameraPhase.Connecting(record.displayTitle)
                    session = environment.createSession(host)
                    session.connect()
                    val connected = session.state.value as? CameraSessionState.Connected
                    if (connected == null) {
                        phase =
                            SavedCameraPhase.Error(
                                "Couldn't reach ${record.displayTitle}. Check the camera connection and try again.",
                            )
                        return@launch
                    }
                    handoffSucceeded = true
                    handedOff.value = true
                    onPaired(
                        PairedCamera(
                            session = session,
                            savedCamera =
                                record.copy(
                                    host = host,
                                    cameraName = connected.identity.name,
                                    lastSeenAtEpochMillis = System.currentTimeMillis(),
                                ),
                        ),
                    )
                } catch (error: CancellationException) {
                    session?.let { active ->
                        withContext(NonCancellable) { active.disconnect() }
                    }
                    throw error
                } catch (_: Exception) {
                    phase =
                        SavedCameraPhase.Error(
                            "Couldn't reach ${record.displayTitle}. Check the camera connection and try again.",
                        )
                } finally {
                    if (!handoffSucceeded) {
                        session?.let { active ->
                            withContext(NonCancellable) { active.disconnect() }
                        }
                        if (record.transport == SavedCameraTransport.CAMERA_ACCESS_POINT) {
                            environment.releaseCameraAp()
                        }
                    }
                }
            }
    }

    fun cancelWork() {
        work.value?.cancel()
        work.value = null
        environment.releaseCameraAp()
        phase = SavedCameraPhase.Idle
    }

    val busy = phase is SavedCameraPhase.Joining || phase is SavedCameraPhase.Connecting
    val statusTitle =
        when (phase) {
            is SavedCameraPhase.Joining -> "Joining"
            is SavedCameraPhase.Connecting -> "Connecting"
            is SavedCameraPhase.Error -> "Needs attention"
            SavedCameraPhase.Idle -> "Ready"
        }

    Box(Modifier.fillMaxSize().startupBackdrop()) {
        Column(
            Modifier.fillMaxSize()
                .windowInsetsPadding(WindowInsets.safeDrawing)
                .padding(horizontal = 24.dp, vertical = 12.dp),
        ) {
            StartupHeader(
                title = "Your cameras",
                statusTitle = statusTitle,
                isBusy = busy,
                onOpenSettings = if (busy) null else onOpenSettings,
            )
            Spacer(Modifier.height(12.dp))
            BoxWithConstraints(Modifier.weight(1f)) {
                val twoColumn = maxWidth >= 640.dp
                val overviewWidth = maxOf(236.dp, maxWidth * 0.28f)
                if (twoColumn) {
                    Row(horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                        SavedCameraOverview(
                            cameraCount = cameras.size,
                            onPairNewCamera = onPairNewCamera,
                            enabled = !busy,
                            modifier = Modifier.width(overviewWidth).fillMaxSize(),
                        )
                        SavedCameraList(
                            cameras = cameras,
                            discoveredCameras = discoveredCameras,
                            phase = phase,
                            onConnect = ::reconnect,
                            onRename = { record ->
                                renameTarget = record
                                renameDraft = record.customName.orEmpty()
                            },
                            onRemove = { removalTarget = it },
                            onCancel = ::cancelWork,
                            fillAvailableHeight = true,
                            scrollRows = true,
                            modifier = Modifier.weight(1f).fillMaxSize(),
                        )
                    }
                } else {
                    LazyColumn(
                        Modifier.fillMaxSize(),
                        verticalArrangement = Arrangement.spacedBy(12.dp),
                    ) {
                        item {
                            SavedCameraOverview(
                                cameraCount = cameras.size,
                                onPairNewCamera = onPairNewCamera,
                                enabled = !busy,
                                modifier = Modifier.fillMaxWidth(),
                            )
                        }
                        item {
                            SavedCameraList(
                                cameras = cameras,
                                discoveredCameras = discoveredCameras,
                                phase = phase,
                                onConnect = ::reconnect,
                                onRename = { record ->
                                    renameTarget = record
                                    renameDraft = record.customName.orEmpty()
                                },
                                onRemove = { removalTarget = it },
                                onCancel = ::cancelWork,
                                fillAvailableHeight = false,
                                scrollRows = false,
                                modifier = Modifier.fillMaxWidth(),
                            )
                        }
                    }
                }
            }
        }
    }

    removalTarget?.let { record ->
        AlertDialog(
            onDismissRequest = { removalTarget = null },
            title = { Text("Remove ${record.displayTitle}?") },
            text = {
                Text(
                    "This removes the saved camera profile from this phone. You can pair it again later.",
                )
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        onRecordsChanged(SavedCameraRecords.removing(record.host, cameras))
                        removalTarget = null
                    },
                ) {
                    Text("Remove")
                }
            },
            dismissButton = {
                TextButton(onClick = { removalTarget = null }) { Text("Cancel") }
            },
        )
    }
    renameTarget?.let { record ->
        AlertDialog(
            onDismissRequest = { renameTarget = null },
            title = { Text("Name ${record.displayTitle}") },
            text = {
                OutlinedTextField(
                    value = renameDraft,
                    onValueChange = { renameDraft = it },
                    singleLine = true,
                    label = { Text("Camera name") },
                )
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        onRecordsChanged(
                            SavedCameraRecords.updatingCustomName(
                                host = record.host,
                                customName = renameDraft,
                                records = cameras,
                            ),
                        )
                        renameTarget = null
                    },
                ) {
                    Text("Save")
                }
            },
            dismissButton = {
                TextButton(onClick = { renameTarget = null }) { Text("Cancel") }
            },
        )
    }
}

@Composable
private fun SavedCameraOverview(
    cameraCount: Int,
    onPairNewCamera: () -> Unit,
    enabled: Boolean,
    modifier: Modifier,
) {
    Column(
        modifier.startupCard().padding(horizontal = 20.dp, vertical = 16.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Text(
            "CAMERAS",
            color = StartupColors.muted,
            fontSize = 11.sp,
            fontWeight = FontWeight.SemiBold,
            letterSpacing = 1.4.sp,
        )
        Text(
            if (cameraCount == 1) "One camera is ready." else "$cameraCount cameras are ready.",
            color = StartupColors.ink,
            fontSize = 24.sp,
            fontWeight = FontWeight.Bold,
            lineHeight = 27.sp,
        )
        Text(
            "Reconnect a camera, update its label, or pair another body. Camera Wi‑Fi keys stay encrypted on this phone.",
            color = StartupColors.muted,
            fontSize = 12.sp,
            lineHeight = 16.sp,
        )
        Spacer(Modifier.weight(1f, fill = false))
        StartupFilledButton(
            text = "Pair new camera",
            enabled = enabled,
            onClick = onPairNewCamera,
            modifier = Modifier.fillMaxWidth(),
        )
    }
}

@Composable
private fun SavedCameraList(
    cameras: List<SavedCameraRecord>,
    discoveredCameras: List<DiscoveredCamera>,
    phase: SavedCameraPhase,
    onConnect: (SavedCameraRecord) -> Unit,
    onRename: (SavedCameraRecord) -> Unit,
    onRemove: (SavedCameraRecord) -> Unit,
    onCancel: () -> Unit,
    fillAvailableHeight: Boolean,
    scrollRows: Boolean,
    modifier: Modifier,
) {
    val busy = phase is SavedCameraPhase.Joining || phase is SavedCameraPhase.Connecting
    Column(modifier.startupCard().padding(20.dp)) {
        Text(
            "SAVED CAMERAS",
            color = StartupColors.muted,
            fontSize = 11.sp,
            fontWeight = FontWeight.SemiBold,
            letterSpacing = 1.4.sp,
        )
        Spacer(Modifier.height(6.dp))
        Text(
            if (busy) {
                when (val active = phase) {
                    is SavedCameraPhase.Joining -> "Joining ${active.title}"
                    is SavedCameraPhase.Connecting -> "Connecting ${active.title}"
                }
            } else {
                "Choose a camera to reconnect"
            },
            color = StartupColors.ink,
            fontSize = 21.sp,
            fontWeight = FontWeight.Bold,
        )
        Spacer(Modifier.height(10.dp))
        Column(
            (if (fillAvailableHeight) Modifier.weight(1f) else Modifier)
                .then(
                    if (scrollRows) {
                        Modifier.verticalScroll(rememberScrollState())
                    } else {
                        Modifier
                    },
                ),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            if (cameras.isEmpty()) {
                Text(
                    "No saved cameras yet. Pair a camera to make reconnecting faster next time.",
                    color = StartupColors.muted,
                    fontSize = 13.sp,
                    lineHeight = 18.sp,
                )
            } else {
                cameras.forEach { record ->
                    SavedCameraRow(
                        record = record,
                        isDiscovered =
                            discoveredCameras.any { camera ->
                                camera.host == record.host ||
                                    SavedCameraRecords.cameraNamesMatch(
                                        camera.name,
                                        record.cameraName,
                                    )
                            },
                        enabled = !busy,
                        onConnect = { onConnect(record) },
                        onRename = { onRename(record) },
                        onRemove = { onRemove(record) },
                    )
                }
            }
            (phase as? SavedCameraPhase.Error)?.let { error ->
                Text(
                    error.message,
                    color = StartupColors.destructive,
                    fontSize = 12.sp,
                    lineHeight = 16.sp,
                )
            }
        }
        Spacer(Modifier.height(12.dp))
        if (busy) {
            Row {
                Spacer(Modifier.weight(1f))
                StartupOutlineButton(
                    text = "Cancel",
                    onClick = onCancel,
                    modifier = Modifier.width(116.dp),
                )
            }
        }
    }
}

@Composable
private fun SavedCameraRow(
    record: SavedCameraRecord,
    isDiscovered: Boolean,
    enabled: Boolean,
    onConnect: () -> Unit,
    onRename: () -> Unit,
    onRemove: () -> Unit,
) {
    val availabilityColor = if (isDiscovered) StartupColors.ready else StartupColors.muted
    Column(
        Modifier.fillMaxWidth()
            .startupTile(borderColor = availabilityColor.copy(alpha = 0.28f))
            .clickable(enabled = enabled, onClick = onConnect)
            .padding(horizontal = 14.dp, vertical = 12.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text(
                    record.displayTitle,
                    color = StartupColors.ink,
                    fontSize = 15.sp,
                    fontWeight = FontWeight.SemiBold,
                    maxLines = 1,
                )
                if (record.customName != null) {
                    Text(
                        record.cameraName,
                        color = StartupColors.dim,
                        fontSize = 11.sp,
                        maxLines = 1,
                    )
                }
            }
            Text(
                if (isDiscovered) "Nearby" else "Saved",
                color = availabilityColor,
                fontSize = 11.sp,
                fontWeight = FontWeight.SemiBold,
                modifier =
                    Modifier.border(1.dp, availabilityColor.copy(alpha = 0.45f), CircleShape)
                        .padding(horizontal = 9.dp, vertical = 4.dp),
            )
        }
        Text(
            "${record.transport.displayName} · ${record.host}",
            color = StartupColors.muted,
            fontSize = 11.sp,
            maxLines = 1,
        )
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            StartupFilledButton(
                text = "Connect",
                enabled = enabled,
                onClick = onConnect,
                modifier = Modifier.width(112.dp),
            )
            Text(
                "Rename",
                color = StartupColors.muted,
                fontSize = 12.sp,
                fontWeight = FontWeight.Medium,
                modifier = Modifier.clickable(enabled = enabled, onClick = onRename).padding(8.dp),
            )
            Text(
                "Remove",
                color = StartupColors.destructive,
                fontSize = 12.sp,
                fontWeight = FontWeight.Medium,
                modifier = Modifier.clickable(enabled = enabled, onClick = onRemove).padding(8.dp),
            )
        }
    }
}

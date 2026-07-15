package com.opencapture.openzcine.media

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.opencapture.openzcine.FeedLutSelection
import com.opencapture.openzcine.frameio.FrameioConnectionState
import com.opencapture.openzcine.frameio.FrameioDeliveryController
import com.opencapture.openzcine.frameio.FrameioDeliveryOptions
import com.opencapture.openzcine.frameio.FrameioHopAvailability
import com.opencapture.openzcine.frameio.FrameioInternetHopState
import com.opencapture.openzcine.frameio.FrameioNetworkState
import com.opencapture.openzcine.frameio.FrameioProject
import com.opencapture.openzcine.frameio.FrameioProjectState
import com.opencapture.openzcine.frameio.FrameioReachabilityPolicy
import kotlinx.coroutines.launch

/**
 * Project picker for complete-cache Frame.io delivery.
 *
 * The dialog intentionally does not initiate OAuth itself. Settings owns the
 * explicit browser hand-off, while this surface explains unavailable
 * configuration and offers only a destination once a verified session exists.
 */
@Composable
internal fun FrameioDeliveryDialog(
    controller: FrameioDeliveryController,
    readyCount: Int,
    selectedLut: FeedLutSelection?,
    selectedLutLabel: String?,
    onDismiss: () -> Unit,
    onDeliver: (FrameioDeliveryOptions) -> Unit,
) {
    val scope = rememberCoroutineScope()
    var projectMenuExpanded by remember { mutableStateOf(false) }
    var newProjectName by remember { mutableStateOf("") }
    var bakeLut by remember(selectedLut) { mutableStateOf(selectedLut != null) }
    var includeMetadata by remember { mutableStateOf(true) }
    var showHopConfirmation by remember { mutableStateOf(false) }
    val eligibleProjects =
        controller.projectListing?.projects?.filter { project ->
            !project.rootFolderID.isNullOrBlank()
        }.orEmpty()
    val online = controller.networkState == FrameioNetworkState.ONLINE
    val onCameraAp = controller.networkState == FrameioNetworkState.CAMERA_ACCESS_POINT
    val hopBusy =
        controller.internetHopState is FrameioInternetHopState.LeavingCamera ||
            controller.internetHopState is FrameioInternetHopState.WaitingForInternet ||
            controller.internetHopState is FrameioInternetHopState.RejoiningCamera
    val canDeliver = online && controller.selectedDestination != null && readyCount > 0

    LaunchedEffect(online, controller.connectionState) {
        if (
            online &&
                controller.connectionState == FrameioConnectionState.CONNECTED &&
                controller.projectState == FrameioProjectState.IDLE
        ) {
            controller.loadProjects()
        }
    }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Frame.io Delivery") },
        text = {
            Column(
                modifier = Modifier.fillMaxWidth().verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                when (controller.connectionState) {
                    FrameioConnectionState.UNCONFIGURED ->
                        Text(
                            "Frame.io is unavailable in this Android build until an approved Adobe Native App client and exact redirect URI are supplied.",
                        )
                    FrameioConnectionState.SIGNED_OUT,
                    FrameioConnectionState.ERROR,
                    ->
                        Text("Sign in from Settings → Storage before delivering media to Frame.io.")
                    FrameioConnectionState.AUTHORIZING ->
                        Text("Finish Adobe sign-in in the browser. OpenZCine will continue only after it receives and verifies the redirect.")
                    FrameioConnectionState.CONNECTED -> {
                        if (onCameraAp) {
                            FrameioHopGate(controller, hopBusy)
                        } else if (online) {
                            FrameioProjectPicker(
                                controller = controller,
                                eligibleProjects = eligibleProjects,
                                online = true,
                                projectMenuExpanded = projectMenuExpanded,
                                onProjectMenuExpanded = { projectMenuExpanded = it },
                                newProjectName = newProjectName,
                                onNewProjectNameChanged = { newProjectName = it },
                                onLoadProjects = { scope.launch { controller.loadProjects() } },
                                onCreateProject = {
                                    scope.launch {
                                        controller.createProject(newProjectName)
                                        newProjectName = ""
                                    }
                                },
                            )
                            FrameioExportOptions(
                                bakeLut = bakeLut,
                                includeMetadata = includeMetadata,
                                selectedLutLabel = selectedLutLabel,
                                onBakeLutChanged = { bakeLut = it },
                                onIncludeMetadataChanged = { includeMetadata = it },
                            )
                        }
                    }
                }
                if (!online && !onCameraAp) {
                    Text(FrameioReachabilityPolicy.operatorMessage(controller.networkState))
                }
                controller.errorMessage?.let { message -> Text(message) }
                if (!onCameraAp) {
                    Text(
                        "Only complete cached media is sent. A LUT bake creates a temporary MP4 and never changes the camera original.",
                    )
                }
            }
        },
        confirmButton = {
            when (controller.connectionState) {
                FrameioConnectionState.CONNECTED -> {
                    if (onCameraAp) {
                        TextButton(
                            enabled =
                                !hopBusy &&
                                    controller.cameraHopAvailability == FrameioHopAvailability.READY,
                            onClick = { showHopConfirmation = true },
                        ) {
                            Text(if (hopBusy) "Switching networks…" else "Hop to internet")
                        }
                    } else {
                        TextButton(
                            enabled =
                                if (controller.selectedDestination == null) {
                                    online && controller.projectState != FrameioProjectState.LOADING
                                } else {
                                    canDeliver
                                },
                            onClick = {
                                if (controller.selectedDestination == null) {
                                    scope.launch { controller.loadProjects() }
                                } else {
                                    onDeliver(
                                        FrameioDeliveryOptions(
                                            bakeLut = bakeLut,
                                            includeMetadata = includeMetadata,
                                            selectedLut = selectedLut.takeIf { bakeLut },
                                        ),
                                    )
                                }
                            },
                        ) {
                            Text(
                                if (controller.selectedDestination == null) {
                                    "Load projects"
                                } else {
                                    "Deliver $readyCount"
                                },
                            )
                        }
                    }
                }
                else -> Unit
            }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Close") } },
    )

    if (showHopConfirmation) {
        AlertDialog(
            onDismissRequest = { showHopConfirmation = false },
            title = { Text("Leave camera Wi-Fi?") },
            text = {
                Text(
                    "OpenZCine will disconnect this camera session and release its local Wi-Fi only after you tap Hop. Your selected clips stay in this delivery, and the app will use the saved camera profile to rejoin and verify a new session afterward.",
                )
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        showHopConfirmation = false
                        scope.launch { controller.beginInternetHop() }
                    },
                ) {
                    Text("Hop")
                }
            },
            dismissButton = {
                TextButton(onClick = { showHopConfirmation = false }) { Text("Cancel") }
            },
        )
    }
}

@Composable
private fun FrameioHopGate(controller: FrameioDeliveryController, hopBusy: Boolean) {
    val detail =
        when {
            hopBusy -> "Switching to a validated internet route while this delivery stays open."
            controller.cameraHopAvailability == FrameioHopAvailability.READY ->
                "Frame.io needs internet. Hop off the camera access point, choose the project and export options, then upload. OpenZCine will rejoin through the saved profile afterward."
            else -> controller.cameraHopAvailability.operatorMessage
        }
    Text(detail)
}

@Composable
private fun FrameioExportOptions(
    bakeLut: Boolean,
    includeMetadata: Boolean,
    selectedLutLabel: String?,
    onBakeLutChanged: (Boolean) -> Unit,
    onIncludeMetadataChanged: (Boolean) -> Unit,
) {
    Text("EXPORT")
    FrameioOptionRow(
        title = "Bake selected LUT",
        detail =
            selectedLutLabel?.let { name -> "$name, temporary MP4 copy" }
                ?: "Choose a monitor LUT before opening Media",
        checked = bakeLut,
        enabled = selectedLutLabel != null,
        onCheckedChange = onBakeLutChanged,
    )
    FrameioOptionRow(
        title = "Include metadata",
        detail = "Keep a private local JSON sidecar after Frame.io confirms the upload",
        checked = includeMetadata,
        enabled = true,
        onCheckedChange = onIncludeMetadataChanged,
    )
}

@Composable
private fun FrameioOptionRow(
    title: String,
    detail: String,
    checked: Boolean,
    enabled: Boolean,
    onCheckedChange: (Boolean) -> Unit,
) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Column(Modifier.weight(1f)) {
            Text(title)
            Text(detail)
        }
        Switch(
            checked = checked,
            enabled = enabled,
            onCheckedChange = onCheckedChange,
        )
    }
}

@Composable
private fun FrameioProjectPicker(
    controller: FrameioDeliveryController,
    eligibleProjects: List<FrameioProject>,
    online: Boolean,
    projectMenuExpanded: Boolean,
    onProjectMenuExpanded: (Boolean) -> Unit,
    newProjectName: String,
    onNewProjectNameChanged: (String) -> Unit,
    onLoadProjects: () -> Unit,
    onCreateProject: () -> Unit,
) {
    when (controller.projectState) {
        FrameioProjectState.IDLE ->
            TextButton(enabled = online, onClick = onLoadProjects) { Text("Load Frame.io projects") }
        FrameioProjectState.LOADING ->
            CircularProgressIndicator(modifier = Modifier.padding(8.dp))
        FrameioProjectState.ERROR ->
            TextButton(enabled = online, onClick = onLoadProjects) { Text("Try loading projects again") }
        FrameioProjectState.READY -> {
            if (eligibleProjects.isEmpty()) {
                Text("This workspace has no projects with an upload folder yet.")
            } else {
                Box {
                    TextButton(onClick = { onProjectMenuExpanded(true) }) {
                        Text(
                            controller.selectedDestination?.projectName ?: "Choose a project",
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                    DropdownMenu(
                        expanded = projectMenuExpanded,
                        onDismissRequest = { onProjectMenuExpanded(false) },
                    ) {
                        eligibleProjects.forEach { project ->
                            DropdownMenuItem(
                                text = { Text(project.name) },
                                onClick = {
                                    controller.selectProject(project)
                                    onProjectMenuExpanded(false)
                                },
                            )
                        }
                    }
                }
            }
            OutlinedTextField(
                value = newProjectName,
                onValueChange = onNewProjectNameChanged,
                label = { Text("New project") },
                modifier = Modifier.fillMaxWidth(),
                singleLine = true,
            )
            TextButton(
                enabled = online && newProjectName.isNotBlank(),
                onClick = onCreateProject,
            ) {
                Text("Create project")
            }
        }
    }
}

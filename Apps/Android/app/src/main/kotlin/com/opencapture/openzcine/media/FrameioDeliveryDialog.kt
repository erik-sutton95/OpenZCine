package com.opencapture.openzcine.media

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.opencapture.openzcine.frameio.FrameioConnectionState
import com.opencapture.openzcine.frameio.FrameioDeliveryController
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
    onDismiss: () -> Unit,
    onDeliver: () -> Unit,
) {
    val scope = rememberCoroutineScope()
    var projectMenuExpanded by remember { mutableStateOf(false) }
    var newProjectName by remember { mutableStateOf("") }
    val eligibleProjects =
        controller.projectListing?.projects?.filter { project ->
            !project.rootFolderID.isNullOrBlank()
        }.orEmpty()
    val online = controller.networkState == FrameioNetworkState.ONLINE
    val canDeliver = online && controller.selectedDestination != null && readyCount > 0

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Frame.io Delivery") },
        text = {
            Column(
                modifier = Modifier.fillMaxWidth(),
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
                    FrameioConnectionState.CONNECTED ->
                        FrameioProjectPicker(
                            controller = controller,
                            eligibleProjects = eligibleProjects,
                            online = online,
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
                }
                if (!online) {
                    Text(FrameioReachabilityPolicy.operatorMessage(controller.networkState))
                }
                controller.errorMessage?.let { message -> Text(message) }
                Text("Only complete cached media is sent. Native Share remains a separate fallback.")
            }
        },
        confirmButton = {
            when (controller.connectionState) {
                FrameioConnectionState.CONNECTED ->
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
                                onDeliver()
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
                else -> Unit
            }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Close") } },
    )
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

package com.opencapture.openzcine.media

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.opencapture.monitorui.MonitorMediaDeliveryPanel
import com.opencapture.monitorui.MonitorMediaDeliveryValue
import com.opencapture.opencine.runtime.MonitorMovieExportContainer
import com.opencapture.openzcine.FeedLutSelection
import com.opencapture.openzcine.LiveDesign
import com.opencapture.openzcine.chromeStyle
import com.opencapture.openzcine.frameio.FrameioConnectionState
import com.opencapture.openzcine.frameio.FrameioDeliveryController
import com.opencapture.openzcine.frameio.FrameioDeliveryOptions
import com.opencapture.openzcine.frameio.FrameioNetworkState
import com.opencapture.openzcine.frameio.FrameioProjectState
import com.opencapture.openzcine.frameio.MediaDeliveryConfiguration
import kotlinx.coroutines.launch

/** iOS `MediaDeliveryDestination` — where a delivery run sends prepared clips. */
internal enum class MediaDeliveryDestination(
    val title: String,
    val subtitle: String,
    val actionTitle: String,
) {
    NATIVE_SHARE(
        title = "Share",
        subtitle = "Nearby Share, Files, and other apps",
        actionTitle = "Share",
    ),
    FRAMEIO(
        title = "Frame.io",
        subtitle = "Upload to your Frame.io project",
        actionTitle = "Upload",
    ),
}

/** iOS `MediaDeliveryPostExportAction` for the native Share path. */
internal enum class MediaDeliveryPostExportAction {
    SYSTEM_SHARE,
    SAVE_TO_PHOTOS,
}

private enum class DeliveryStep {
    DESTINATION,
    OPTIONS,
}

/**
 * iOS `MediaDeliveryPopup` port: destination picker → options, then Share / Upload.
 * Glass panel over a dimmed scrim (not a Material AlertDialog).
 */
@Composable
internal fun MediaDeliveryPopup(
    clipCount: Int,
    readyCount: Int,
    cameraConnected: Boolean,
    selectedLut: FeedLutSelection?,
    selectedLutLabel: String?,
    frameioController: FrameioDeliveryController?,
    preferredDestination: MediaDeliveryDestination? = null,
    busy: Boolean = false,
    /**
     * Pulls the selection off the camera before the internet hop leaves its Wi‑Fi. On the camera
     * access point this is the only moment the clips are still reachable, so caching afterwards —
     * as the upload path does on every other network — would find nothing.
     */
    onCacheBeforeHop: suspend () -> Unit = {},
    onDismiss: () -> Unit,
    onNativeShare: (MediaDeliveryConfiguration) -> Unit,
    onSaveToGallery: (MediaDeliveryConfiguration) -> Unit,
    onFrameioDeliver: (FrameioDeliveryOptions) -> Unit,
) {
    val scope = rememberCoroutineScope()
    var cachingForHop by remember { mutableStateOf(false) }
    var step by
        remember(preferredDestination) {
            mutableStateOf(
                if (preferredDestination == null) DeliveryStep.DESTINATION else DeliveryStep.OPTIONS,
            )
        }
    var destination by remember(preferredDestination) { mutableStateOf(preferredDestination) }
    var shareAction by remember { mutableStateOf(MediaDeliveryPostExportAction.SYSTEM_SHARE) }
    var bakeLut by remember(selectedLut) { mutableStateOf(selectedLut != null) }
    var exportContainer by remember { mutableStateOf(MonitorMovieExportContainer.MOV) }
    var includeMetadata by remember { mutableStateOf(true) }
    var forceReupload by remember { mutableStateOf(false) }
    var showHopConfirm by remember { mutableStateOf(false) }
    val configuration =
        MediaDeliveryConfiguration(
            bakeLut = bakeLut && selectedLut != null,
            exportContainer = exportContainer,
            includeMetadata = includeMetadata,
            selectedLut = selectedLut.takeIf { bakeLut },
            forceFrameioReupload = forceReupload,
        )
    val online = frameioController?.networkState == FrameioNetworkState.ONLINE
    val onCameraAp = frameioController?.networkState == FrameioNetworkState.CAMERA_ACCESS_POINT
    val frameioConnected =
        frameioController?.connectionState == FrameioConnectionState.CONNECTED
    val frameioConfigured =
        frameioController?.connectionState != FrameioConnectionState.UNCONFIGURED &&
            frameioController != null
    val hopBusy =
        frameioController?.let { frameioHopBlocksDismissal(it.internetHopState) } == true
    val hasDeliverable = canDeliverMedia(readyCount, clipCount, cameraConnected)
    val frameioProjectReady =
        frameioController?.selectedDestination != null || onCameraAp == true
    val canContinue =
        when (destination) {
            MediaDeliveryDestination.NATIVE_SHARE -> hasDeliverable && !busy
            MediaDeliveryDestination.FRAMEIO ->
                hasDeliverable &&
                    frameioConfigured &&
                    frameioConnected &&
                    frameioProjectReady &&
                    !busy &&
                    !(bakeLut && selectedLut == null)
            null -> false
        }
    val frameioHopGate = destination == MediaDeliveryDestination.FRAMEIO && onCameraAp

    LaunchedEffect(destination, online, frameioController?.connectionState) {
        if (
            destination == MediaDeliveryDestination.FRAMEIO &&
                online &&
                frameioConnected &&
                frameioController?.projectState == FrameioProjectState.IDLE
        ) {
            frameioController.loadProjects()
        }
    }

    val projects = MediaDeliveryPanelValue.projects(frameioController?.projectListing)
    val service = if (destination == MediaDeliveryDestination.FRAMEIO) {
        if (frameioHopGate) {
            MonitorMediaDeliveryValue.Service.InternetGate(
                heading = "FRAME.IO",
                message = "Frame.io needs the internet. Hop off the camera's Wi‑Fi to pick a project and upload - the camera reconnects automatically when you're done.",
                busy = cachingForHop || hopBusy,
                busyTitle = if (cachingForHop) "Caching from camera…" else "Switching networks…",
            )
        } else if (frameioController != null) {
            MediaDeliveryPanelValue.projectService(
                listing = frameioController.projectListing,
                selectedID = frameioController.selectedDestination?.projectID,
                selectedLabel = frameioController.selectedDestination?.projectName,
                loading = frameioController.projectState == FrameioProjectState.LOADING,
                error = frameioController.errorMessage.takeIf {
                    frameioController.projectState == FrameioProjectState.ERROR
                },
            )
        } else null
    } else null
    val configuring = step == DeliveryStep.OPTIONS && !frameioHopGate
    val value = MonitorMediaDeliveryValue(
        step = if (step == DeliveryStep.DESTINATION) MonitorMediaDeliveryValue.Step.DESTINATION
            else MonitorMediaDeliveryValue.Step.OPTIONS,
        title = destination?.title ?: "Share",
        selectionLabel = "$clipCount clip${if (clipCount == 1) "" else "s"}",
        notices = buildList {
            if (readyCount < clipCount) add(MonitorMediaDeliveryValue.Notice(
                if (cameraConnected) "${clipCount - readyCount} on-camera clip(s) will be cached from the camera first."
                else "${clipCount - readyCount} on-camera clip(s) will be skipped - reconnect to cache them.",
            ))
            if (destination == MediaDeliveryDestination.FRAMEIO && !frameioHopGate) {
                add(MonitorMediaDeliveryValue.Notice(
                    frameioController?.selectedDestination?.projectName?.let { "Project: $it" }
                        ?: "Choose a Frame.io project",
                ))
            }
        },
        destinations = MediaDeliveryDestination.entries.map { candidate ->
            MonitorMediaDeliveryValue.Destination(
                id = candidate.name,
                title = candidate.title,
                subtitle = if (candidate == MediaDeliveryDestination.FRAMEIO && frameioConfigured && !frameioConnected) {
                    "Sign in from Settings → Storage first."
                } else candidate.subtitle,
                enabled = when (candidate) {
                    MediaDeliveryDestination.NATIVE_SHARE -> hasDeliverable
                    MediaDeliveryDestination.FRAMEIO -> frameioConfigured && frameioConnected && hasDeliverable
                },
            )
        },
        service = service,
        export = if (configuring) MediaDeliveryPanelValue.export(configuration, selectedLutLabel, destination) else null,
        footer = if (configuring) MonitorMediaDeliveryValue.Footer(
            postExport = if (destination == MediaDeliveryDestination.NATIVE_SHARE) {
                MediaDeliveryPanelValue.postExport(shareAction)
            } else null,
            actionTitle = when (destination) {
                MediaDeliveryDestination.NATIVE_SHARE -> if (shareAction == MediaDeliveryPostExportAction.SAVE_TO_PHOTOS) {
                    "Save to Photos"
                } else "Share"
                MediaDeliveryDestination.FRAMEIO -> "Upload"
                null -> "Continue"
            },
            enabled = canContinue,
        ) else null,
    )

    fun handleDeliveryAction(action: MonitorMediaDeliveryValue.Action): Unit {
        when (action) {
            MonitorMediaDeliveryValue.Action.Close -> {
                if (!busy && !hopBusy && !cachingForHop) onDismiss()
            }
            MonitorMediaDeliveryValue.Action.Back -> step = DeliveryStep.DESTINATION
            MonitorMediaDeliveryValue.Action.Begin -> if (canContinue) {
                when (destination) {
                    MediaDeliveryDestination.NATIVE_SHARE -> when (shareAction) {
                        MediaDeliveryPostExportAction.SYSTEM_SHARE -> onNativeShare(configuration)
                        MediaDeliveryPostExportAction.SAVE_TO_PHOTOS -> onSaveToGallery(configuration)
                    }
                    MediaDeliveryDestination.FRAMEIO -> onFrameioDeliver(configuration)
                    null -> Unit
                }
            }
            MonitorMediaDeliveryValue.Action.HopToInternet -> showHopConfirm = true
            MonitorMediaDeliveryValue.Action.RetryProjects -> scope.launch { frameioController?.loadProjects() }
            MonitorMediaDeliveryValue.Action.CreateProject -> Unit
            is MonitorMediaDeliveryValue.Action.Destination -> {
                val candidate = MediaDeliveryDestination.entries.firstOrNull { it.name == action.id }
                if (candidate != null && value.destinations.any { it.id == action.id && it.enabled }) {
                    destination = candidate
                    step = DeliveryStep.OPTIONS
                    if (candidate == MediaDeliveryDestination.FRAMEIO && online && frameioConnected) {
                        scope.launch { frameioController?.loadProjects() }
                    }
                }
            }
            is MonitorMediaDeliveryValue.Action.Option -> when (action.option) {
                MonitorMediaDeliveryValue.Option.BAKE_LUT -> bakeLut = action.on
                MonitorMediaDeliveryValue.Option.INCLUDE_METADATA -> includeMetadata = action.on
                MonitorMediaDeliveryValue.Option.REUPLOAD -> forceReupload = action.on
                MonitorMediaDeliveryValue.Option.CONVERT_LOG, MonitorMediaDeliveryValue.Option.BAKE_EXPOSURE -> Unit
            }
            is MonitorMediaDeliveryValue.Action.Selection -> when (action.selection) {
                MonitorMediaDeliveryValue.Selection.FORMAT -> MonitorMovieExportContainer.entries
                    .firstOrNull { it.name == action.id }?.let { exportContainer = it }
                MonitorMediaDeliveryValue.Selection.POST_EXPORT -> MediaDeliveryPostExportAction.entries
                    .firstOrNull { it.name == action.id }?.let { shareAction = it }
                MonitorMediaDeliveryValue.Selection.PROJECT -> projects?.firstOrNull { it.id == action.id }
                    ?.let { frameioController?.selectProject(it) }
                MonitorMediaDeliveryValue.Selection.OUTPUT_CURVE -> Unit
            }
        }
    }

    Box(
        Modifier.fillMaxSize()
            .background(Color.Black.copy(alpha = 0.45f))
            .clickable(
                interactionSource = remember { MutableInteractionSource() },
                indication = null,
            ) {
                // The popup's scope still owns the cache pre-pass before the route hand-off.
                if (!busy && !hopBusy && !cachingForHop) onDismiss()
            },
        contentAlignment = Alignment.Center,
    ) {
        MonitorMediaDeliveryPanel(
            value = value,
            modifier = Modifier.padding(24.dp).widthIn(max = 380.dp),
            onAction = ::handleDeliveryAction,
            destinationIcon = { id ->
                Text(
                    if (id == MediaDeliveryDestination.FRAMEIO.name) "⬆" else "⇧",
                    style = chromeStyle(18f, FontWeight.SemiBold),
                    color = if (value.destinations.any { it.id == id && it.enabled }) LiveDesign.text else LiveDesign.faint,
                )
            },
        )
    }

    if (showHopConfirm && frameioController != null) {
        androidx.compose.material3.AlertDialog(
            onDismissRequest = { showHopConfirm = false },
            title = { Text("Hop to internet?") },
            text = {
                Text(
                    "Frame.io needs the internet. OpenZCine will leave the camera Wi‑Fi, then reconnect when delivery finishes.",
                )
            },
            confirmButton = {
                androidx.compose.material3.TextButton(
                    onClick = {
                        showHopConfirm = false
                        scope.launch {
                            cachingForHop = true
                            try {
                                onCacheBeforeHop()
                            } finally {
                                cachingForHop = false
                            }
                            frameioController.beginInternetHop()
                        }
                    },
                ) { Text("Hop") }
            },
            dismissButton = {
                androidx.compose.material3.TextButton(onClick = { showHopConfirm = false }) {
                    Text("Cancel")
                }
            },
        )
    }
}

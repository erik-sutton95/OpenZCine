package com.opencapture.openzcine.media

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Switch
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
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.opencapture.openzcine.FeedLutSelection
import com.opencapture.openzcine.LiveDesign
import com.opencapture.openzcine.chromeStyle
import com.opencapture.openzcine.frameio.FrameioConnectionState
import com.opencapture.openzcine.frameio.FrameioDeliveryController
import com.opencapture.openzcine.frameio.FrameioDeliveryOptions
import com.opencapture.openzcine.frameio.FrameioNetworkState
import com.opencapture.openzcine.frameio.FrameioProjectState
import com.opencapture.openzcine.frameio.MediaDeliveryConfiguration
import com.opencapture.openzcine.frameio.MediaExportContainer
import com.opencapture.openzcine.glass
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
    onDismiss: () -> Unit,
    onNativeShare: (MediaDeliveryConfiguration) -> Unit,
    onSaveToGallery: (MediaDeliveryConfiguration) -> Unit,
    onFrameioDeliver: (FrameioDeliveryOptions) -> Unit,
) {
    val scope = rememberCoroutineScope()
    var step by
        remember(preferredDestination) {
            mutableStateOf(
                if (preferredDestination == null) DeliveryStep.DESTINATION else DeliveryStep.OPTIONS,
            )
        }
    var destination by remember(preferredDestination) { mutableStateOf(preferredDestination) }
    var shareAction by remember { mutableStateOf(MediaDeliveryPostExportAction.SYSTEM_SHARE) }
    var bakeLut by remember(selectedLut) { mutableStateOf(selectedLut != null) }
    var exportContainer by remember { mutableStateOf(MediaExportContainer.MOV) }
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
    val hasDeliverable = readyCount > 0 || (cameraConnected && clipCount > 0)
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

    Box(
        Modifier.fillMaxSize()
            .background(Color.Black.copy(alpha = 0.45f))
            .clickable(
                interactionSource = remember { MutableInteractionSource() },
                indication = null,
            ) {
                if (!busy && !hopBusy) onDismiss()
            },
        contentAlignment = Alignment.Center,
    ) {
        Column(
            Modifier.padding(24.dp)
                .widthIn(max = 380.dp)
                .heightIn(max = 520.dp)
                .glass(RoundedCornerShape(LiveDesign.CORNER_RADIUS_DP.dp))
                .clickable(
                    interactionSource = remember { MutableInteractionSource() },
                    indication = null,
                ) {}
                .padding(16.dp),
        ) {
            when (step) {
                DeliveryStep.DESTINATION -> DestinationHeader(onClose = onDismiss)
                DeliveryStep.OPTIONS ->
                    OptionsHeader(
                        title = destination?.title ?: "Share",
                        onBack = { step = DeliveryStep.DESTINATION },
                    )
            }
            Spacer(Modifier.height(12.dp))
            Column(
                Modifier.weight(1f, fill = false).verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(16.dp),
            ) {
                Text(
                    "$clipCount clip${if (clipCount == 1) "" else "s"}",
                    style = chromeStyle(15f, FontWeight.SemiBold),
                    color = LiveDesign.text,
                )
                if (readyCount < clipCount) {
                    Text(
                        if (cameraConnected) {
                            "${clipCount - readyCount} on-camera clip(s) will be cached from the camera first."
                        } else {
                            "${clipCount - readyCount} on-camera clip(s) will be skipped — reconnect to cache them."
                        },
                        style = chromeStyle(12f, FontWeight.Medium),
                        color = LiveDesign.muted,
                    )
                }
                when (step) {
                    DeliveryStep.DESTINATION -> {
                        Text(
                            "DESTINATION",
                            style = chromeStyle(10f, FontWeight.Bold, mono = true),
                            color = LiveDesign.muted,
                        )
                        MediaDeliveryDestination.entries.forEach { candidate ->
                            val enabled =
                                when (candidate) {
                                    MediaDeliveryDestination.NATIVE_SHARE -> hasDeliverable
                                    MediaDeliveryDestination.FRAMEIO ->
                                        frameioConfigured && frameioConnected && hasDeliverable
                                }
                            DestinationRow(
                                destination = candidate,
                                enabled = enabled,
                                detail =
                                    if (
                                        candidate == MediaDeliveryDestination.FRAMEIO &&
                                            frameioConfigured &&
                                            !frameioConnected
                                    ) {
                                        "Sign in from Settings → Storage first."
                                    } else {
                                        candidate.subtitle
                                    },
                                onClick = {
                                    destination = candidate
                                    step = DeliveryStep.OPTIONS
                                    if (
                                        candidate == MediaDeliveryDestination.FRAMEIO &&
                                            online &&
                                            frameioConnected
                                    ) {
                                        scope.launch { frameioController?.loadProjects() }
                                    }
                                },
                            )
                        }
                    }
                    DeliveryStep.OPTIONS -> {
                        when (destination) {
                            MediaDeliveryDestination.NATIVE_SHARE -> {
                                NativeExportOptions(
                                    bakeLut = bakeLut,
                                    exportContainer = exportContainer,
                                    includeMetadata = includeMetadata,
                                    selectedLutLabel = selectedLutLabel,
                                    onBakeLutChanged = { bakeLut = it },
                                    onExportContainerChanged = { exportContainer = it },
                                    onIncludeMetadataChanged = { includeMetadata = it },
                                )
                            }
                            MediaDeliveryDestination.FRAMEIO -> {
                                if (frameioHopGate) {
                                    FrameioHopSection(
                                        hopBusy = hopBusy,
                                        onHop = { showHopConfirm = true },
                                    )
                                } else if (frameioController != null) {
                                    FrameioOptionsBody(
                                        controller = frameioController,
                                        bakeLut = bakeLut,
                                        exportContainer = exportContainer,
                                        includeMetadata = includeMetadata,
                                        forceReupload = forceReupload,
                                        selectedLutLabel = selectedLutLabel,
                                        onBakeLutChanged = { bakeLut = it },
                                        onExportContainerChanged = { exportContainer = it },
                                        onIncludeMetadataChanged = { includeMetadata = it },
                                        onForceReuploadChanged = { forceReupload = it },
                                    )
                                }
                            }
                            null -> Unit
                        }
                    }
                }
            }
            if (step == DeliveryStep.OPTIONS && !frameioHopGate) {
                Spacer(Modifier.height(12.dp))
                if (destination == MediaDeliveryDestination.NATIVE_SHARE) {
                    SegmentedShareAction(
                        selected = shareAction,
                        onSelect = { shareAction = it },
                    )
                    Spacer(Modifier.height(10.dp))
                }
                FooterActionButton(
                    title =
                        when (destination) {
                            MediaDeliveryDestination.NATIVE_SHARE ->
                                if (shareAction == MediaDeliveryPostExportAction.SAVE_TO_PHOTOS) {
                                    "Save to Photos"
                                } else {
                                    "Share"
                                }
                            MediaDeliveryDestination.FRAMEIO -> "Upload"
                            null -> "Continue"
                        },
                    enabled = canContinue && !frameioHopGate,
                    onClick = {
                        when (destination) {
                            MediaDeliveryDestination.NATIVE_SHARE ->
                                when (shareAction) {
                                    MediaDeliveryPostExportAction.SYSTEM_SHARE ->
                                        onNativeShare(configuration)
                                    MediaDeliveryPostExportAction.SAVE_TO_PHOTOS ->
                                        onSaveToGallery(configuration)
                                }
                            MediaDeliveryDestination.FRAMEIO -> onFrameioDeliver(configuration)
                            null -> Unit
                        }
                    },
                )
            }
        }
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
                        scope.launch { frameioController.beginInternetHop() }
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

@Composable
private fun DestinationHeader(onClose: () -> Unit) {
    Row(
        Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Text(
            "SHARE",
            style = chromeStyle(14f, FontWeight.Bold, mono = true),
            color = LiveDesign.text,
        )
        Spacer(Modifier.weight(1f))
        Box(
            Modifier.size(30.dp)
                .clip(CircleShape)
                .background(LiveDesign.hairline.copy(alpha = 0.35f))
                .clickable(onClick = onClose),
            contentAlignment = Alignment.Center,
        ) {
            Text("×", style = chromeStyle(16f, FontWeight.SemiBold), color = LiveDesign.text)
        }
    }
}

@Composable
private fun OptionsHeader(title: String, onBack: () -> Unit) {
    Row(
        Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Text(
            "‹ Back",
            style = chromeStyle(13f, FontWeight.SemiBold),
            color = LiveDesign.accent,
            modifier = Modifier.clickable(onClick = onBack),
        )
        Column(Modifier.weight(1f)) {
            Text(title, style = chromeStyle(15f, FontWeight.SemiBold), color = LiveDesign.text)
            Text("Options", style = chromeStyle(11f, FontWeight.Medium), color = LiveDesign.muted)
        }
    }
}

@Composable
private fun DestinationRow(
    destination: MediaDeliveryDestination,
    enabled: Boolean,
    detail: String,
    onClick: () -> Unit,
) {
    Row(
        Modifier.fillMaxWidth()
            .clip(RoundedCornerShape(LiveDesign.CORNER_RADIUS_DP.dp))
            .background(LiveDesign.hairline.copy(alpha = 0.35f))
            .clickable(enabled = enabled, onClick = onClick)
            .padding(horizontal = 12.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text(
            if (destination == MediaDeliveryDestination.FRAMEIO) "⬆" else "⇧",
            style = chromeStyle(18f, FontWeight.SemiBold),
            color = if (enabled) LiveDesign.text else LiveDesign.faint,
        )
        Column(Modifier.weight(1f)) {
            Text(
                destination.title,
                style = chromeStyle(14f, FontWeight.SemiBold),
                color = if (enabled) LiveDesign.text else LiveDesign.faint,
            )
            Text(detail, style = chromeStyle(11f, FontWeight.Medium), color = LiveDesign.muted)
        }
        Text("›", style = chromeStyle(14f, FontWeight.SemiBold), color = LiveDesign.faint)
    }
}

@Composable
private fun SegmentedShareAction(
    selected: MediaDeliveryPostExportAction,
    onSelect: (MediaDeliveryPostExportAction) -> Unit,
) {
    Row(
        Modifier.fillMaxWidth()
            .clip(RoundedCornerShape(LiveDesign.CORNER_RADIUS_DP.dp))
            .background(LiveDesign.hairline.copy(alpha = 0.35f))
            .padding(3.dp),
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        listOf(
                MediaDeliveryPostExportAction.SYSTEM_SHARE to "Share",
                MediaDeliveryPostExportAction.SAVE_TO_PHOTOS to "Save to Photos",
            )
            .forEach { (action, label) ->
                val on = selected == action
                Box(
                    Modifier.weight(1f)
                        .clip(RoundedCornerShape(LiveDesign.CORNER_RADIUS_DP.dp - 2.dp))
                        .background(if (on) LiveDesign.accent.copy(alpha = 0.28f) else Color.Transparent)
                        .clickable { onSelect(action) }
                        .padding(vertical = 8.dp),
                    contentAlignment = Alignment.Center,
                ) {
                    Text(
                        label,
                        style = chromeStyle(12f, FontWeight.SemiBold),
                        color = if (on) LiveDesign.text else LiveDesign.muted,
                    )
                }
            }
    }
}

@Composable
private fun FooterActionButton(title: String, enabled: Boolean, onClick: () -> Unit) {
    Box(
        Modifier.fillMaxWidth()
            .clip(RoundedCornerShape(LiveDesign.CORNER_RADIUS_DP.dp))
            .background(
                if (enabled) LiveDesign.accent.copy(alpha = 0.22f)
                else LiveDesign.hairline.copy(alpha = 0.25f),
            )
            .border(
                width = 1.dp,
                color =
                    if (enabled) LiveDesign.accent.copy(alpha = 0.55f)
                    else LiveDesign.hairline.copy(alpha = 0.35f),
                shape = RoundedCornerShape(LiveDesign.CORNER_RADIUS_DP.dp),
            )
            .clickable(enabled = enabled, onClick = onClick)
            .padding(vertical = 12.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            title,
            style = chromeStyle(15f, FontWeight.SemiBold),
            color = if (enabled) LiveDesign.text else LiveDesign.faint,
        )
    }
}

@Composable
private fun FrameioHopSection(hopBusy: Boolean, onHop: () -> Unit) {
    Text(
        "Frame.io needs the internet. Hop off the camera's Wi‑Fi to pick a project and upload — the camera reconnects automatically when you're done.",
        style = chromeStyle(13f, FontWeight.Medium),
        color = LiveDesign.muted,
    )
    if (hopBusy) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            CircularProgressIndicator(
                modifier = Modifier.size(16.dp),
                color = LiveDesign.accent,
                strokeWidth = 2.dp,
            )
            Text(
                "Switching networks…",
                style = chromeStyle(13f, FontWeight.Medium),
                color = LiveDesign.muted,
            )
        }
    } else {
        FooterActionButton(title = "Hop to internet", enabled = true, onClick = onHop)
    }
}

@Composable
private fun FrameioOptionsBody(
    controller: FrameioDeliveryController,
    bakeLut: Boolean,
    exportContainer: MediaExportContainer,
    includeMetadata: Boolean,
    forceReupload: Boolean,
    selectedLutLabel: String?,
    onBakeLutChanged: (Boolean) -> Unit,
    onExportContainerChanged: (MediaExportContainer) -> Unit,
    onIncludeMetadataChanged: (Boolean) -> Unit,
    onForceReuploadChanged: (Boolean) -> Unit,
) {
    val projects =
        controller.projectListing?.projects?.filter { !it.rootFolderID.isNullOrBlank() }.orEmpty()
    val selected = controller.selectedDestination
    Text(
        selected?.projectName?.let { "Project: $it" } ?: "Choose a Frame.io project",
        style = chromeStyle(12f, FontWeight.Medium),
        color = LiveDesign.muted,
    )
    projects.take(8).forEach { project ->
        val on = selected?.projectID == project.id
        Text(
            if (on) "✓ ${project.name}" else project.name,
            style = chromeStyle(13f, FontWeight.SemiBold),
            color = if (on) LiveDesign.accent else LiveDesign.text,
            modifier =
                Modifier.fillMaxWidth()
                    .clickable {
                        controller.selectProject(project)
                    }
                    .padding(vertical = 6.dp),
        )
    }
    NativeExportOptions(
        bakeLut = bakeLut,
        exportContainer = exportContainer,
        includeMetadata = includeMetadata,
        selectedLutLabel = selectedLutLabel,
        onBakeLutChanged = onBakeLutChanged,
        onExportContainerChanged = onExportContainerChanged,
        onIncludeMetadataChanged = onIncludeMetadataChanged,
    )
    Row(
        Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Text(
                "Force re-upload",
                style = chromeStyle(12f, FontWeight.SemiBold),
                color = LiveDesign.text,
            )
            Text(
                "Upload again even if Frame.io already has this clip",
                style = chromeStyle(10f, FontWeight.Medium),
                color = LiveDesign.muted,
            )
        }
        Switch(checked = forceReupload, onCheckedChange = onForceReuploadChanged)
    }
}

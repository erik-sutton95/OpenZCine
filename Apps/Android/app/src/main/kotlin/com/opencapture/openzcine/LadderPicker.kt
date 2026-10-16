package com.opencapture.openzcine

import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import com.opencapture.opencine.appkit.MonitorControlModel
import com.opencapture.opencine.cameracontrols.LadderSheet
import com.opencapture.opencine.nikon.NikonLadderControl
import com.opencapture.opencine.nikon.NikonRecordingFormatPresentation
import com.opencapture.opencine.vocabulary.CaptureTint
import com.opencapture.opencine.vocabulary.LadderTab

/** A Nikon picker on the shared LadderSheet, drawn from the shared Nikon capture popup. */
@Composable
internal fun VideoLadderBody(
    picker: MonitorPickerPresentation,
    control: MonitorControlModel?,
    controlsEnabled: Boolean,
    error: String?,
    unavailable: String?,
    fromTop: Boolean,
    onWrite: (CommandControlRequest, String) -> Unit,
    onClose: () -> Unit,
    onHold: (() -> Unit)?,
    tintLabel: (CaptureTint) -> String,
    tintHelp: String?,
    footer: @Composable (LadderTab<NikonLadderControl>) -> Unit,
    modifier: Modifier = Modifier,
    chromeless: Boolean = false,
    recordingFormats: List<NikonRecordingFormatPresentation> = emptyList(),
) {
    LadderSheet(
        presentation = videoLadderPresentation(picker),
        enabled = controlsEnabled,
        onWrite = { write ->
            val (request, value) = requestForLadderWrite(picker, write) ?: return@LadderSheet
            onWrite(request, value)
        },
        onClose = onClose,
        modifier = modifier,
        control = control,
        fromTop = fromTop,
        chromeless = chromeless,
        error = error,
        unavailable = if (controlsEnabled) null else unavailable,
        onHold = onHold,
        tintLabel = tintLabel,
        tintHelp = tintHelp,
        footer = footer,
        formats = ladderFormats(picker, recordingFormats),
    )
}

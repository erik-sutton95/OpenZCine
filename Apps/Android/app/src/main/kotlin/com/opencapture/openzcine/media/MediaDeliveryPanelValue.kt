package com.opencapture.openzcine.media

import com.opencapture.monitorui.MonitorMediaDeliveryProgressValue
import com.opencapture.monitorui.MonitorMediaDeliveryValue
import com.opencapture.opencine.runtime.MonitorMovieExportContainer
import com.opencapture.openzcine.frameio.FrameioInternetHopState
import com.opencapture.openzcine.frameio.FrameioProject
import com.opencapture.openzcine.frameio.FrameioProjectListing
import com.opencapture.openzcine.frameio.MediaDeliveryConfiguration

/** Source choices projected into common rendering; no export, cache or route ownership. */
internal object MediaDeliveryPanelValue {
    fun export(
        configuration: MediaDeliveryConfiguration,
        selectedLutLabel: String?,
        destination: MediaDeliveryDestination?,
    ): MonitorMediaDeliveryValue.Export = MonitorMediaDeliveryValue.Export(
        bakeLUT = MonitorMediaDeliveryValue.Toggle(
            title = "Bake selected LUT",
            help = selectedLutLabel?.let { "$it, temporary ${configuration.exportContainer.label} copy" }
                ?: "No approved monitor LUT is selected",
            isOn = configuration.bakeLut,
            enabled = selectedLutLabel != null,
        ),
        format = MonitorMediaDeliveryValue.Choices(
            title = "Container for baked exports",
            help = "Container applies only when a LUT is baked. Originals are never changed.",
            options = MonitorMovieExportContainer.entries.map { MonitorMediaDeliveryValue.Choice(it.name, it.label) },
            selectedID = configuration.exportContainer.name,
        ),
        includeMetadata = MonitorMediaDeliveryValue.Toggle(
            title = "Include metadata",
            help = "Share clip details and preserve camera capture time in Gallery",
            isOn = configuration.includeMetadata,
        ),
        reupload = if (destination == MediaDeliveryDestination.FRAMEIO) {
            MonitorMediaDeliveryValue.Toggle(
                title = "Force re-upload",
                help = "Upload again even if Frame.io already has this clip",
                isOn = configuration.forceFrameioReupload,
            )
        } else null,
    )

    /** Absent listing stays unknown; an actual listing preserves the original eight-project limit. */
    fun projects(listing: FrameioProjectListing?): List<FrameioProject>? =
        listing?.projects?.filter { !it.rootFolderID.isNullOrBlank() }?.take(8)

    /** Project facts preserve actual first-eight choices and the independently known destination. */
    fun projectService(
        listing: FrameioProjectListing?,
        selectedID: String?,
        selectedLabel: String?,
        loading: Boolean,
        error: String?,
    ): MonitorMediaDeliveryValue.Service.Projects = MonitorMediaDeliveryValue.Service.Projects(
        heading = "PROJECT",
        help = "Upload destination in your Frame.io workspace.",
        loading = loading,
        error = error,
        choices = projects(listing)?.map { MonitorMediaDeliveryValue.Choice(it.id, it.name) },
        selectedID = selectedID,
        allowsCreation = false,
        selectedLabel = selectedLabel,
    )

    fun postExport(action: MediaDeliveryPostExportAction): MonitorMediaDeliveryValue.Choices =
        MonitorMediaDeliveryValue.Choices(
            title = "",
            options = listOf(
                MonitorMediaDeliveryValue.Choice(MediaDeliveryPostExportAction.SYSTEM_SHARE.name, "Share"),
                MonitorMediaDeliveryValue.Choice(MediaDeliveryPostExportAction.SAVE_TO_PHOTOS.name, "Save to Photos"),
            ),
            selectedID = action.name,
        )
}

internal fun MediaDeliveryOverlayState.monitorProgressValue(): MonitorMediaDeliveryProgressValue =
    MonitorMediaDeliveryProgressValue(
        status = statusLine,
        batch = batchLine,
        fraction = overallFraction,
        preparing = isPreparingClip,
        showsProgress = !isPreparingClip,
    )

/** Prevents dismissal while the non-cancellable camera-network hand-off owns the dialog. */
internal fun frameioHopBlocksDismissal(state: FrameioInternetHopState): Boolean =
    when (state) {
        FrameioInternetHopState.LeavingCamera,
        FrameioInternetHopState.WaitingForInternet,
        FrameioInternetHopState.RejoiningCamera,
        -> true
        FrameioInternetHopState.Idle,
        FrameioInternetHopState.Online,
        is FrameioInternetHopState.Rejoined,
        is FrameioInternetHopState.Failed,
        -> false
    }

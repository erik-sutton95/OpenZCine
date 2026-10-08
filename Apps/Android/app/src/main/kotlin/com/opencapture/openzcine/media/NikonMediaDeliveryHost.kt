package com.opencapture.openzcine.media

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import com.opencapture.opencine.appkit.*
import com.opencapture.opencine.cameracontrols.MonitorOperatorDeliveryPopupOverlay
import com.opencapture.opencine.runtime.MonitorMovieExportContainer
import com.opencapture.openzcine.frameio.*
import java.util.UUID
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn

/** Captured canonical/native facts and SDK ports; all popup and batch policy lives in OpenCine. */
internal class NikonMediaDeliveryHost(
    private val scope: CoroutineScope,
    private val coordinator: MediaDeliveryCoordinator,
    private val frameio: FrameioDeliveryController,
    private val cache: MediaCacheStore,
    private val library: MonitorMediaLibraryModel<NikonLibraryClip>,
    private val opening: MonitorMediaGalleryOpen<NikonLibraryClip>,
    private val connectionOwner: Long?,
    private val sourceCurrent: () -> Boolean,
    private val captureRecord: (MonitorMediaRecord<NikonLibraryClip>) -> MonitorPlaybackAdmission,
    private val configuration: () -> MediaDeliveryConfiguration,
    private val lutLabel: () -> String? = { null },
    private val beforeFirstIO: suspend () -> Unit = {},
) {
    internal class Popup internal constructor(
        val model: MonitorDeliveryPreparationModel<Unit, MonitorMovieExportContainer, FrameioProject, FrameioCapturedProjectListing, FrameioInternetLease>,
        internal val capture: Capture,
    )
    internal data class Chooser(val id: UUID, val shares: List<StagedMediaShare>, val metadata: String?)
    private val popupState = MutableStateFlow<Popup?>(null)
    val popup: StateFlow<Popup?> = popupState
    private val chooserState = MutableStateFlow<Chooser?>(null)
    val chooser: StateFlow<Chooser?> = chooserState
    val coverPresented: StateFlow<Boolean> = combine(popupState, chooserState, coordinator.display, coordinator.nativeState) { popup, chooser, display, native ->
        popup != null || chooser != null || display.overlay != null || native.running
    }.stateIn(scope, SharingStarted.Eagerly, false)
    var capturedRun: MonitorDeliveryRunHandle? = null
        private set
    private var capturedRoute: FrameioInternetLease? = null
    private var revision = UUID.randomUUID()
    private var closed = false

    fun share(record: MonitorMediaRecord<NikonLibraryClip>) = share(listOf(record))
    fun share(records: List<MonitorMediaRecord<NikonLibraryClip>>) {
        if (closed || records.isEmpty() || chooserState.value != null) return
        val source = records.map(captureRecord)
        if (!sourceCurrent() || !library.isCurrent(opening.admission) || source.any { !it.isCurrent() }) return
        val native = configuration()
        val label = lutLabel()
        if (!sourceCurrent() || source.any { !it.isCurrent() }) return
        val old = popupState.value
        popupState.value = null; old?.model?.close()
        revision = UUID.randomUUID()
        val captured = Capture(records.toList(), source, native, label, revision)
        if (!captured.current()) return
        val remote = remote(captured)
        val options = MonitorDeliveryExportOptions<Unit, MonitorMovieExportContainer>(
            curves = emptyList(), formats = MonitorMovieExportContainer.entries.map { MonitorDeliveryChoice(it.name, it.label, it) },
            lutAvailable = { native.selectedLut != null }, convertLogAvailable = { null }, lutLabel = { label },
            convertHelp = "", convertUnavailableHelp = "", bakeExposureAvailable = { null }, formatsForRemoteUpload = true,
            filename = { records.singleOrNull()?.payload?.clip?.filename })
        val preparation = MonitorDeliveryPreparationModel(scope, observeSelection = { captured.selectionFacts() },
            configuration = MonitorDeliveryExportConfiguration(Unit, native.exportContainer,
                bakeLUT = native.selectedLut != null, bakeLUTExposure = false, includeMetadata = native.includeMetadata,
                forceReupload = native.forceFrameioReupload), exportOptions = options, remote = remote,
            sourceCurrent = { captured.current() }, beforeInternetHop = {
                val outgoing = capturedRun
                val oldRoute = capturedRoute
                val run = coordinator.cacheCaptured(captured.selection, connectionOwner,
                    MonitorDeliveryAdmission { captured.current() }, beforeIO = {
                        beforeFirstIO()
                        outgoing?.cancelAndJoin()
                        oldRoute?.let { if (it !== captured.lease) frameio.endInternetHop(it) }
                    }) ?: error("Selection is no longer available.")
                capturedRun = run
                run.awaitEnteredCleanup()
                if (!captured.current()) error("Selection is no longer available.")
            })
        if (!captured.current()) { preparation.close(); return }
        popupState.value = Popup(preparation, captured)
        preparation.start()
    }

    internal inner class Capture(
        val records: List<MonitorMediaRecord<NikonLibraryClip>>, private val native: List<MonitorPlaybackAdmission>,
        val configuration: MediaDeliveryConfiguration, val label: String?, private val originalRevision: UUID,
    ) {
        val selection = records.map { MediaDeliverySelection(it.payload.bucket, it.payload.clip) }
        private val directory = library.cache.directory
        private val directoryRoot = directory.root
        private val directoryGeneration = directory.generation
        private val cacheRoot = cache.rootDirectory
        private val store = library.cache.catalogStore
        private val namespace = store?.namespace
        private val storeGeneration = store?.generation
        val frameioAccountRevision = frameio.accountRevision
        val frameioDestination = frameio.selectedDestination
        var lease: FrameioInternetLease? = null
        private fun contentCurrent(): Boolean {
            if (directory.root != directoryRoot || directory.generation != directoryGeneration || cache.rootDirectory != cacheRoot ||
                library.cache.catalogStore !== store || store?.namespace != namespace || store?.generation != storeGeneration) return false
            val indexed = library.cache.load()
            val accepted = records.all { old -> indexed.firstOrNull { it.asset.id == old.asset.id }?.let {
                it.address == old.address && sameNikonActionContent(it.payload.clip, old.payload.clip)
            } ?: true }
            return accepted && directory.root == directoryRoot && directory.generation == directoryGeneration &&
                cache.rootDirectory == cacheRoot && library.cache.catalogStore === store &&
                store?.namespace == namespace && store?.generation == storeGeneration
        }
        fun nativeCurrent(): Boolean = sourceCurrent() && library.isCurrent(opening.admission) &&
            native.all { it.isCurrent() } && sourceCurrent()
        fun current(): Boolean {
            if (closed || revision != originalRevision || !contentCurrent()) return false
            val route = lease
            val planned = route != null && frameio.ownsInternetHop(route) && route.leftCamera == true
            val connected = nativeCurrent()
            return (planned || connected) && !closed && revision == originalRevision && contentCurrent() &&
                (if (planned) route != null && frameio.ownsInternetHop(route) else native.all { it.isCurrent() })
        }
        fun completionCurrent(): Boolean {
            if (closed || revision != originalRevision || !contentCurrent()) return false
            val route = lease
            val capturedRoute = route != null && (frameio.ownsInternetHop(route) || frameio.endedInternetHop(route))
            return (capturedRoute || nativeCurrent()) && !closed && revision == originalRevision && contentCurrent() &&
                (if (capturedRoute) route != null && (frameio.ownsInternetHop(route) || frameio.endedInternetHop(route)) else native.all { it.isCurrent() })
        }
        fun selectionFacts() = MonitorDeliverySelectionFacts(records.map { MonitorDeliveryFileFacts(it.payload.clip.filename,
            it.payload.clip.sizeBytes.takeIf { size -> size > 0 }) }, selection.count {
            runCatching { cache.completedEntryOrNull(it.cameraID, MediaCacheObjectIdentity(it.clip), it.clip.sizeBytes) }.getOrNull() != null
        }, if (nativeCurrent()) connectionOwner != null else false)
    }
    private fun remote(capture: Capture) = MonitorDeliveryRemoteService<FrameioProject, FrameioCapturedProjectListing, FrameioInternetLease>(
        presentation = MonitorDeliveryRemotePresentation("Frame.io", "Uploading to Frame.io"),
        observe = { frameio.refresh(); MonitorDeliveryRemoteFacts(frameio.isConfigured, frameio.isConnected,
            frameio.networkState == FrameioNetworkState.CAMERA_ACCESS_POINT, frameio.selectedDestination?.projectID,
            frameio.selectedDestination?.projectName) },
        load = {
            val listing = frameio.loadProjectsCaptured { capture.current() }
            MonitorDeliveryProjectListing(listing, listing.listing.projects.filter { !it.rootFolderID.isNullOrBlank() }.take(8).map { projectValue(it) })
        },
        create = { name, context -> projectValue(frameio.createProjectCaptured(name, context) { capture.current() }) },
        persist = { project, context -> frameio.selectProjectCaptured(project.payload, context) { capture.current() } },
        internet = MonitorDeliveryInternetService(needsHop = { frameio.networkState == FrameioNetworkState.CAMERA_ACCESS_POINT },
            begin = {
                val lease = frameio.claimInternetHop { capture.current() } ?: error(frameio.errorMessage ?: "Camera route is no longer available.")
                capture.lease = lease; capturedRoute = lease; lease
            }, owns = frameio::ownsInternetHop, wait = frameio::waitInternetHop,
            restoreEntered = { frameio.endInternetHop(it) }, restore = frameio::restoreInternetHopAfterDismiss),
        transfer = { old -> frameio.transferInternetHop(old)?.also { capture.lease = it; capturedRoute = it } })
    private fun projectValue(project: FrameioProject) = MonitorDeliveryProject(project.id, project.name,
        !project.rootFolderID.isNullOrBlank(), project)
    fun dismissPopup(expected: Popup) {
        if (popupState.value !== expected) return
        popupState.value = null; expected.model.close()
    }
    fun begin(expected: Popup, request: MonitorDeliveryPreparedRequest<Unit, MonitorMovieExportContainer, FrameioInternetLease>) {
        val capture = expected.capture
        if (!capture.current()) { request.internetLease?.let(frameio::restoreInternetHopAfterDismiss); return }
        val config = request.configuration ?: run { request.internetLease?.let(frameio::restoreInternetHopAfterDismiss); return }
        val prepared = expected.model.state.value
        val projects = prepared.listing?.context
        val account = projects?.accountRevision ?: capture.frameioAccountRevision
        val selectedID = prepared.selectedProjectID ?: prepared.remoteFacts?.savedProjectID
        val project = prepared.listing?.projects?.firstOrNull { it.id == selectedID && it.uploadable == true }?.payload
        val folder = project?.rootFolderID?.takeIf { it.isNotBlank() }
        val destination = if (projects != null && project != null && folder != null)
            FrameioDestination(projects.listing.accountID, projects.listing.workspaceID, project.id, project.name, folder)
        else capture.frameioDestination?.takeIf { it.projectID == selectedID &&
            (projects == null || (it.accountID == projects.listing.accountID && it.workspaceID == projects.listing.workspaceID)) }
        fun accountCurrent(): Boolean = frameio.accountRevision == account && (projects == null || frameio.ownsProjects(projects))
        val remoteAdmission = MonitorDeliveryAdmission { accountCurrent() && capture.current() && accountCurrent() }
        if (request.destination == MonitorDeliveryDestination.REMOTE_UPLOAD && (destination == null || !remoteAdmission.isCurrent())) {
            request.internetLease?.let(frameio::restoreInternetHopAfterDismiss); return
        }
        val native = capture.configuration.copy(bakeLut = config.bakeLUT, exportContainer = config.exportFormat,
            includeMetadata = config.includeMetadata, forceFrameioReupload = config.forceReupload)
        val outgoing = capturedRun
        val route = capturedRoute
        val beforeIO: suspend () -> Unit = {
            beforeFirstIO()
            outgoing?.cancelAndJoin()
            route?.let { if (it !== request.internetLease) frameio.endInternetHop(it) }
        }
        val admission = MonitorDeliveryAdmission { capture.current() }
        val nativeOwner = connectionOwner.takeIf { capture.nativeCurrent() }
        capturedRun = when {
            request.destination == MonitorDeliveryDestination.REMOTE_UPLOAD -> coordinator.beginFrameioCaptured(
                capture.selection, native, nativeOwner, remoteAdmission, request.internetLease, beforeIO,
                MonitorDeliveryAdmission { accountCurrent() && capture.completionCurrent() && accountCurrent() }, projects, destination)
            request.action == MonitorDeliveryPostExportAction.SAVE_TO_PHOTOS -> coordinator.beginSaveToPhotosCaptured(
                capture.selection, native, nativeOwner, admission, beforeIO, request.internetLease,
                MonitorDeliveryAdmission { capture.completionCurrent() })
            else -> coordinator.beginNativeShareCaptured(capture.selection, native, nativeOwner, admission, beforeIO,
                request.internetLease, MonitorDeliveryAdmission { capture.completionCurrent() }) { shares, metadata ->
                if (capture.completionCurrent()) chooserState.value = Chooser(UUID.randomUUID(), shares, metadata)
            }
        }
    }
    fun acknowledgeChooser(id: UUID) {
        if (chooserState.value?.id == id) chooserState.value = null
    }
    fun close() {
        if (closed) return
        closed = true; revision = UUID.randomUUID()
        val old = popupState.value; popupState.value = null; chooserState.value = null
        old?.model?.close()
        capturedRun?.cancel()
    }
    suspend fun cancelAndJoin() {
        val run = capturedRun; val route = capturedRoute
        close(); run?.cancelAndJoin(); route?.let { frameio.endInternetHop(it) }
    }
    suspend fun awaitEnteredCleanup() {
        val run = capturedRun; val route = capturedRoute
        run?.awaitEnteredCleanup(); route?.let { frameio.endInternetHop(it) }
    }
}

@Composable internal fun NikonMediaDeliveryHostView(host: NikonMediaDeliveryHost) {
    val popup by host.popup.collectAsState()
    val chooser by host.chooser.collectAsState()
    val context = LocalContext.current
    var launched by remember(host) { mutableStateOf<UUID?>(null) }
    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()) {
        launched?.let(host::acknowledgeChooser); launched = null
    }
    DisposableEffect(host) { onDispose { host.close() } }
    popup?.let { expected -> MonitorOperatorDeliveryPopupOverlay(expected.model,
        onClose = { host.dismissPopup(expected) }, onBegin = { host.begin(expected, it) }) }
    LaunchedEffect(chooser?.id) {
        val current = chooser ?: return@LaunchedEffect
        if (launched == null) {
            launched = current.id
            try { launcher.launch(AndroidMediaShareIntent.chooserIntent(context, current.shares, current.metadata)) }
            catch (_: Exception) { host.acknowledgeChooser(current.id); launched = null }
        }
    }
}

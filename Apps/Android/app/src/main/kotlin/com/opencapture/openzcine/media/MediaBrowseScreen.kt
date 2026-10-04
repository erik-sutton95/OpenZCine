package com.opencapture.openzcine.media

import com.opencapture.monitorui.MonitorClipCard
import com.opencapture.monitorui.MonitorCatalogDisplayControls
import com.opencapture.monitorui.MonitorCatalogHeader
import com.opencapture.monitorui.MonitorMediaNavigation
import com.opencapture.monitorui.MonitorMediaNavigationCategory
import com.opencapture.monitorui.MonitorMediaFilterForm
import com.opencapture.monitorui.MonitorMediaFilterChoice
import com.opencapture.monitorui.MonitorMediaFilterChipLayout
import com.opencapture.monitorui.MonitorMediaPhotoSizeChoices
import com.opencapture.monitorui.MonitorMediaDateWindowChoices
import com.opencapture.monitorui.MonitorMediaStorageChoices
import com.opencapture.monitorui.MonitorPageHeading
import com.opencapture.monitorui.MonitorPageScaffold
import com.opencapture.monitorui.MonitorThumbnailSize
import com.opencapture.monitorui.MonitorMediaSelectionConfiguration
import com.opencapture.monitorui.MonitorMediaSelectionFeedback
import com.opencapture.monitorui.MonitorMediaSelectionHost
import com.opencapture.monitorui.MonitorMediaHitTarget

import com.opencapture.openzcine.performOperatorHaptic
import com.opencapture.openzcine.LocalOperatorHaptics

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import android.view.HapticFeedbackConstants
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.snapping.rememberSnapFlingBehavior
import androidx.compose.foundation.lazy.grid.rememberLazyGridState
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.platform.LocalViewConfiguration
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.displayCutout
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.widthIn
import androidx.compose.ui.graphics.Brush
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.ProgressBarRangeInfo
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.disabled
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.progressBarRangeInfo
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.opencapture.openzcine.AssistState
import com.opencapture.openzcine.ExposureAssistCameraInput
import com.opencapture.openzcine.FilmGlyph
import com.opencapture.openzcine.FeedLutSelection
import com.opencapture.openzcine.LiveDesign
import com.opencapture.openzcine.R
import com.opencapture.openzcine.bridge.SwiftCore
import com.opencapture.openzcine.chromeClickable
import com.opencapture.openzcine.chromeStyle
import com.opencapture.openzcine.diagnostics.AndroidDiagnosticEvent
import com.opencapture.openzcine.frameio.FrameioDeliveryArtifact
import com.opencapture.openzcine.frameio.FrameioArtifactContext
import com.opencapture.openzcine.frameio.FrameioDeliveryController
import com.opencapture.openzcine.frameio.FrameioDeliveryOptions
import com.opencapture.openzcine.frameio.FrameioPreparedArtifact
import com.opencapture.openzcine.frameio.FrameioDeliveryState
import com.opencapture.openzcine.frameio.FrameioInternetHopState
import com.opencapture.openzcine.frameio.MediaDeliveryConfiguration
import com.opencapture.openzcine.glass
import com.opencapture.openzcine.lut.AndroidLutLibrary
import com.opencapture.opencine.nikon.CameraStorageSlotStatus
import com.opencapture.openzcine.settings.OperatorSettings
import java.nio.file.Files
import java.nio.file.LinkOption
import kotlin.math.abs
import kotlin.math.roundToInt
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import com.opencapture.opencine.nikon.NikonNative

/**
 * ObjectInfo budget per cursor advance. The facade alternates cards inside
 * each page, and Compose publishes every page before requesting the next one.
 */
private const val MEDIA_BROWSE_PAGE_SIZE = 32

/** Loading / loaded / failed states of one camera or persisted-local listing pass. */
internal sealed interface BrowseState {
    data object Loading : BrowseState

    data class Loaded(
        val clips: List<MediaClipRecord>,
        val isLoadingMore: Boolean = false,
    ) : BrowseState

    data class Failed(val message: String) : BrowseState
}

/** A truncated camera enumeration is a failed catalog, never a complete partial listing. */
internal fun incompleteCameraBrowseState(partialClips: List<MediaClipRecord>): BrowseState.Failed {
    if (partialClips.isEmpty()) {
        return BrowseState.Failed("Couldn't finish listing camera media.")
    }
    val itemLabel = if (partialClips.size == 1) "item" else "items"
    return BrowseState.Failed(
        "Listing stopped after ${partialClips.size} $itemLabel. Retry to load the complete library.",
    )
}

/** Outcome of staging the safe subset of a multi-selection for Android sharing. */
private data class BatchShareResult(
    val staged: List<StagedMediaShare>,
    val stagedClips: List<MediaClipRecord>,
    val incompleteCount: Int,
    val failedCount: Int,
    val firstFailure: String?,
)

/** Gallery writer result paired with the selection items omitted before writing. */
private data class GalleryDelivery(
    val result: MediaGalleryBatchResult,
    val omissions: MediaGalleryOmissions,
)

/** One configured, verified artifact paired with its stable source record. */
private data class PreparedExternalMedia(
    val clip: MediaClipRecord,
    val artifact: FrameioPreparedArtifact,
)

/** Partial-safe result from applying one export configuration to staged media. */
private data class ExternalMediaPreparation(
    val prepared: List<PreparedExternalMedia>,
    val failedCount: Int,
    val firstFailure: String?,
)

/**
 * Stages the exact same immutable ready copies for native Share, Gallery, and
 * Frame.io delivery. This is intentionally the only bridge from a camera cache
 * entry to an external destination; progressive `.part` files never reach it.
 */
private fun stageSelectedMedia(
    context: Context,
    cacheStore: MediaCacheStore,
    cameraID: String,
    selection: List<MediaClipRecord>,
    cameraIDFor: (MediaClipRecord) -> String = { cameraID },
    cancellationCheck: () -> Unit = {},
): BatchShareResult {
    val stager = MediaShareStager(context.cacheDir.toPath())
    val staged = mutableListOf<StagedMediaShare>()
    val stagedClips = mutableListOf<MediaClipRecord>()
    var incomplete = 0
    var failed = 0
    var firstFailure: String? = null
    selection.forEach { clip ->
        cancellationCheck()
        val entry =
            runCatching {
                cacheStore.completedEntryOrNull(
                    cameraIDFor(clip),
                    MediaCacheObjectIdentity(clip),
                    clip.sizeBytes,
                )
            }.getOrNull()
        if (entry == null) {
            incomplete += 1
            return@forEach
        }
        try {
            staged += stager.stage(entry, clip, cancellationCheck)
            stagedClips += clip
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            failed += 1
            if (firstFailure == null) firstFailure = error.message
        }
    }
    return BatchShareResult(staged, stagedClips, incomplete, failed, firstFailure)
}

private suspend fun prepareExternalMedia(
    controller: FrameioDeliveryController,
    cameraID: String,
    staged: BatchShareResult,
    configuration: MediaDeliveryConfiguration,
    cancellationCheck: () -> Unit,
): ExternalMediaPreparation {
    val prepared = mutableListOf<PreparedExternalMedia>()
    var failed = 0
    var firstFailure: String? = null
    try {
        staged.staged.zip(staged.stagedClips).forEach { (share, clip) ->
            cancellationCheck()
            try {
                val artifact =
                    controller.prepareForExternalDelivery(
                    FrameioDeliveryArtifact(
                        share = share,
                        byteCount = withContext(Dispatchers.IO) { Files.size(share.file) },
                        context =
                            FrameioArtifactContext(
                                cameraID = cameraID,
                                captureDate = clip.captureDate,
                                supportsLutBake =
                                    clip.contentKind == MediaContentKind.PLAYABLE_PROXY,
                                stableClipIdentity = clip.libraryKey(cameraID),
                            ),
                    ),
                    configuration,
                )
                prepared += PreparedExternalMedia(clip, artifact)
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                failed += 1
                if (firstFailure == null) firstFailure = error.message
            }
        }
    } catch (error: CancellationException) {
        withContext(NonCancellable) {
            prepared.forEach { item ->
                runCatching { controller.releaseExternalDelivery(item.artifact) }
            }
        }
        throw error
    }
    return ExternalMediaPreparation(prepared, failed, firstFailure)
}

/** Privacy-bounded details attached to Android's share intent only when requested. */
internal fun mediaDeliveryMetadataSummary(clips: List<MediaClipRecord>): String {
    val lines =
        clips.take(MAXIMUM_SHARE_METADATA_ITEMS).map { clip ->
            val filename = clip.filename.take(MAXIMUM_SHARE_METADATA_FILENAME_CHARACTERS)
            val date = clip.captureDate.ifBlank { "unknown date" }.take(32)
            "$filename · $date · ${clip.sizeLabel}"
        }.toMutableList()
    val omitted = clips.size - lines.size
    if (omitted > 0) lines += "+$omitted more selected ${if (omitted == 1) "item" else "items"}"
    return lines.joinToString(separator = "\n")
}

private const val MAXIMUM_SHARE_METADATA_ITEMS = 32
private const val MAXIMUM_SHARE_METADATA_FILENAME_CHARACTERS = 160

internal fun frameioDeliverySummary(
    state: FrameioDeliveryState,
    internetHopState: FrameioInternetHopState,
    errorMessage: String?,
    skippedBeforeUpload: Int,
): String =
    when (state) {
        is FrameioDeliveryState.Completed ->
            buildString {
                if (state.uploadedCount > 0) {
                    append("Delivered ${state.uploadedCount} cached item")
                    if (state.uploadedCount != 1) append('s')
                } else {
                    append("No new cached items uploaded")
                }
                if (state.skippedCount > 0) {
                    append("; ${state.skippedCount} already uploaded")
                }
                if (state.failedCount > 0) {
                    append("; ${state.failedCount} failed")
                }
                state.firstFailureMessage?.takeIf(String::isNotBlank)?.let { firstFailure ->
                    append("; first failure: ${firstFailure.trimEnd('.')}")
                }
                if (state.metadataFailureCount > 0) {
                    append("; ${state.metadataFailureCount} metadata sidecar")
                    if (state.metadataFailureCount != 1) append('s')
                    append(" not saved")
                }
                if (state.cleanupFailureCount > 0) {
                    append("; ${state.cleanupFailureCount} temporary export")
                    if (state.cleanupFailureCount != 1) append('s')
                    append(" not removed")
                }
                if (state.historyFailureCount > 0) {
                    append("; ${state.historyFailureCount} upload history ")
                    append(if (state.historyFailureCount == 1) "failure" else "failures")
                }
                if (skippedBeforeUpload > 0) {
                    append("; $skippedBeforeUpload not prepared")
                }
                when (internetHopState) {
                    is FrameioInternetHopState.Rejoined -> append("; camera rejoined")
                    is FrameioInternetHopState.Failed -> append("; camera rejoin not verified")
                    else -> Unit
                }
            }
        is FrameioDeliveryState.Failed ->
            buildString {
                append(state.message)
                if (internetHopState is FrameioInternetHopState.Failed) {
                    append("; camera rejoin not verified")
                    if (internetHopState.message.isNotBlank()) {
                        append(": ${internetHopState.message}")
                    }
                }
            }
        FrameioDeliveryState.Idle -> errorMessage ?: "Frame.io delivery didn't start."
        is FrameioDeliveryState.Uploading -> "Frame.io delivery is still in progress."
    }

/** Rejoins a consented camera-AP hop even when local preparation never reaches upload. */
internal suspend fun endActiveFrameioHopAfterMediaJob(
    isActive: () -> Boolean,
    endHop: suspend () -> Unit,
) {
    if (isActive()) withContext(NonCancellable) { endHop() }
}

/** Preserves a preparation error while making a later camera-rejoin failure explicit. */
internal fun frameioPreparationMessageAfterRejoin(
    message: String?,
    internetHopState: FrameioInternetHopState,
): String? {
    if (message == null || internetHopState !is FrameioInternetHopState.Failed) return message
    return buildString {
        append(message)
        append(" Camera rejoin not verified")
        if (internetHopState.message.isNotBlank()) append(": ${internetHopState.message}")
    }
}

/** Keeps the loaded camera library stable during the one consented network round trip. */
internal fun frameioHopKeepsCameraLibraryMounted(
    state: FrameioInternetHopState,
    rejoinedConnectionObserved: Boolean,
): Boolean =
    when (state) {
        FrameioInternetHopState.LeavingCamera,
        FrameioInternetHopState.WaitingForInternet,
        FrameioInternetHopState.Online,
        FrameioInternetHopState.RejoiningCamera,
        -> true
        is FrameioInternetHopState.Rejoined -> !rejoinedConnectionObserved
        FrameioInternetHopState.Idle,
        is FrameioInternetHopState.Failed,
        -> false
    }

/** Prevents a retained Frame.io hop state from fabricating a camera in offline-only browsing. */
internal fun effectiveMediaCameraConnection(
    cameraSessionAvailable: Boolean,
    cameraConnected: Boolean,
    frameioInternetHopState: FrameioInternetHopState,
    rejoinedConnectionObserved: Boolean,
): Boolean {
    if (!cameraSessionAvailable) return false
    return cameraConnected ||
        frameioHopKeepsCameraLibraryMounted(
            frameioInternetHopState,
            rejoinedConnectionObserved,
        )
}

/**
 * Library source is never operator-toggled (iOS sets it programmatically). A
 * connected camera session always lists the camera; offline opens always read
 * complete cache. Persisted `view.source` from a prior offline visit must not
 * stick and suppress camera fetch after reconnect.
 */
internal fun mediaLibrarySourceForConnection(cameraConnected: Boolean): MediaLibrarySource =
    if (cameraConnected) MediaLibrarySource.CAMERA else MediaLibrarySource.LOCAL

/**
 * Full-screen Android media library.
 *
 * The camera source is the shared Swift core's bounded listing wire. The local
 * source is deliberately narrower: it contains only metadata that a prior
 * shared-core listing persisted and whose exact identity-derived cache entry
 * is complete. No Android code infers camera media actions from a filename,
 * searches filesystem paths, or performs PTP work.
 */
@Composable
internal fun MediaBrowseScreen(
    cameraID: String,
    cameraConnected: Boolean,
    cameraSessionAvailable: Boolean = true,
    /**
     * Native connection owner of the camera session this library browses. Every camera-media
     * facade call is addressed to it; null (offline or demo) reaches no camera at all.
     */
    connectionOwner: Long?,
    mediaService: com.opencapture.opencine.nikon.NikonMediaService? = null,
    savedCameraID: String? = null,
    cameraDisplayName: String? = null,
    /**
     * When non-empty and the camera is offline, "On device" lists complete
     * cache artifacts from every listed camera bucket (iOS offline
     * `listAllCachedClips` aggregate). Empty = single [cameraID] only.
     */
    offlineCameraIDs: List<String> = emptyList(),
    cameraStorageSlots: List<CameraStorageSlotStatus> = emptyList(),
    /**
     * Sidebar tab matched to the active capture side at open — Videos from
     * cinema, Photos from photography (iOS `openMediaBrowser`). Null restores
     * the persisted tab; manual tab switches persist as before.
     */
    initialCategory: MediaLibraryCategory? = null,
    liveAssistState: AssistState,
    exposureAssistCameraInput: ExposureAssistCameraInput,
    operatorSettings: OperatorSettings,
    lutLibrary: AndroidLutLibrary,
    frameioController: FrameioDeliveryController,
    mediaDeliveryCoordinator: MediaDeliveryCoordinator? = null,
    selectedLut: FeedLutSelection,
    autoPlayFirstProxy: Boolean = false,
    galleryFailureInjection: MediaGalleryFailureInjection = MediaGalleryFailureInjection.NONE,
    /** Bumped when Settings clears the camera media cache so an open gallery reloads. */
    cacheRevision: Int = 0,
    /** Records a closed rating-write breadcrumb (attempted / confirmed / refused). */
    onRatingDiagnostic: (AndroidDiagnosticEvent) -> Unit = {},
    onClose: () -> Unit,
) {
    val catalogOwner = remember(mediaService) { mediaService?.let(::NikonMediaGalleryCatalog) }
    DisposableEffect(catalogOwner) { onDispose { catalogOwner?.retire() } }
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val playbackAssistState =
        remember(context, lutLibrary) {
            PlaybackAssistState.restore(context, liveAssistState) { selection ->
                lutLibrary.contains(selection)
            }
        }
    val cacheStore =
        remember(context) {
            MediaCacheStore(context.noBackupFilesDir.resolve("media-cache").toPath())
        }
    val libraryIndex =
        remember(context) {
            MediaLibraryIndex(SharedPreferencesMediaLibraryPreferences(context))
        }
    val galleryGateway =
        remember(context, galleryFailureInjection) {
            AndroidMediaGalleryGateway(context.contentResolver, galleryFailureInjection)
        }
    LaunchedEffect(cameraID, savedCameraID, cameraDisplayName) {
        val savedID = savedCameraID ?: return@LaunchedEffect
        val displayName = cameraDisplayName ?: return@LaunchedEffect
        withContext(Dispatchers.IO) {
            libraryIndex.rememberCameraBucket(savedID, cameraID, displayName)
        }
    }
    val internetHopState = frameioController.internetHopState
    var rejoinedConnectionObserved by remember(cameraID) { mutableStateOf(false) }
    LaunchedEffect(internetHopState, cameraConnected) {
        when (internetHopState) {
            is FrameioInternetHopState.Rejoined -> {
                if (cameraConnected) rejoinedConnectionObserved = true
            }
            FrameioInternetHopState.LeavingCamera,
            FrameioInternetHopState.WaitingForInternet,
            FrameioInternetHopState.Online,
            FrameioInternetHopState.RejoiningCamera,
            FrameioInternetHopState.Idle,
            is FrameioInternetHopState.Failed,
            -> rejoinedConnectionObserved = false
        }
    }
    val effectiveCameraConnected =
        effectiveMediaCameraConnection(
            cameraSessionAvailable,
            cameraConnected,
            internetHopState,
            rejoinedConnectionObserved,
        )
    // Connection owns source. Category / layout / sort still restore from prefs.
    val librarySource = mediaLibrarySourceForConnection(effectiveCameraConnected)
    var options by
        remember(cameraID) {
            val restored = libraryIndex.viewOptions(MediaLibrarySource.CAMERA)
            mutableStateOf(
                restored.copy(
                    source = librarySource,
                    category = initialCategory ?: restored.category,
                ),
            )
        }
    LaunchedEffect(librarySource) {
        if (options.source != librarySource) {
            options = options.copy(source = librarySource)
        }
    }
    var favorites by remember(cameraID) { mutableStateOf(emptySet<String>()) }
    // Offline multi-camera library: object key → owning cache bucket cameraID.
    var offlineClipOwners by
        remember(cameraID, offlineCameraIDs) { mutableStateOf(emptyMap<String, String>()) }
    fun ownerCameraID(clip: MediaClipRecord): String =
        offlineClipOwners[clip.offlineObjectKey()] ?: cameraID
    fun clipKey(clip: MediaClipRecord): String = clip.libraryKey(ownerCameraID(clip))
    var state by remember(cameraID) { mutableStateOf<BrowseState>(BrowseState.Loading) }
    var reloadKey by remember { mutableIntStateOf(0) }
    // Camera-card deletion in flight: the listing effect stays cancelled while
    // non-null so an already-enumerated page cannot re-add the deleted rows.
    var pendingDeletion by remember(cameraID) { mutableStateOf<List<MediaClipRecord>?>(null) }
    // Deletion progress (completed, total) while a batch delete runs — drives the progress bar
    // and keeps the grid steady until the run finishes (the listing restarts once, at the end).
    var deletionProgress by remember { mutableStateOf<Pair<Int, Int>?>(null) }
    // Shots the operator selected (smaller than the file total when RAW+JPEG pairs / masters /
    // backups ride along) — kept so the progress bar can explain the inflated file count.
    var deletionSelectedCount by remember { mutableStateOf(0) }
    var deleteConfirmTargets by remember { mutableStateOf<List<MediaClipRecord>?>(null) }
    var playingClip by remember { mutableStateOf<MediaClipRecord?>(null) }
    var viewingPhoto by remember { mutableStateOf<MediaClipRecord?>(null) }
    // The representative of a burst series whose members are being browsed (Manage series).
    var seriesRepresentative by remember { mutableStateOf<MediaClipRecord?>(null) }
    var closeRequested by remember { mutableStateOf(false) }
    var autoPlayHandled by remember { mutableStateOf(false) }
    var isSelecting by remember { mutableStateOf(false) }
    var selectedIDs by remember { mutableStateOf(emptySet<String>()) }
    var readySelectionIDs by remember { mutableStateOf(emptySet<String>()) }
    var shareInProgress by remember { mutableStateOf(false) }
    var shareMessage by remember { mutableStateOf<String?>(null) }
    var shareJob by remember { mutableStateOf<Job?>(null) }
    var frameioDeliveryPresented by remember { mutableStateOf(false) }
    var frameioPreparationInProgress by remember { mutableStateOf(false) }
    var nativeDeliveryPresented by remember { mutableStateOf(false) }
    var filters by remember(cameraID) { mutableStateOf(MediaLibraryFilters()) }
    var filterDialogPresented by remember { mutableStateOf(false) }
    var browseStorageSlots by
        remember(cameraID) { mutableStateOf<List<CameraStorageSlotStatus>?>(null) }

    fun updateOptions(updated: MediaLibraryViewOptions) {
        if (shareInProgress) return
        // Never let category/layout edits re-stick a stale source preference.
        val coerced = updated.copy(source = librarySource)
        options = coerced
        libraryIndex.saveViewOptions(coerced)
        isSelecting = false
        selectedIDs = emptySet()
        readySelectionIDs = emptySet()
        shareMessage = null
        nativeDeliveryPresented = false
    }

    fun updateFilters(updated: MediaLibraryFilters) {
        filters = updated
        isSelecting = false
        selectedIDs = emptySet()
    }

    fun toggleStorageSlot(storageId: Long) {
        updateFilters(filters.togglingStorageSlot(storageId))
    }

    fun exitSelection() {
        isSelecting = false
        selectedIDs = emptySet()
        readySelectionIDs = emptySet()
        nativeDeliveryPresented = false
    }

    fun cancelActiveShareOrExitSelection() {
        val activeShare = shareJob
        if (!shareInProgress || activeShare == null) {
            exitSelection()
            return
        }
        activeShare.cancel()
    }

    LaunchedEffect(cameraID, offlineCameraIDs) {
        favorites =
            withContext(Dispatchers.IO) {
                val ids =
                    offlineCameraIDs.takeIf { it.isNotEmpty() } ?: listOf(cameraID)
                ids.flatMap { id -> libraryIndex.favoriteIDs(id) }.toSet()
            }
    }

    LaunchedEffect(
        cameraID,
        mediaService,
        offlineCameraIDs,
        librarySource,
        effectiveCameraConnected,
        reloadKey,
        cacheRevision,
        pendingDeletion != null,
    ) {
        // A deletion owns the camera between the cancelled old listing and the
        // fresh re-enumeration it schedules; never list mid-deletion.
        if (pendingDeletion != null) return@LaunchedEffect
        state = BrowseState.Loading
        val nextState =
            when (librarySource) {
                MediaLibrarySource.CAMERA -> {
                    browseStorageSlots = null
                    offlineClipOwners = emptyMap()
                    if (!effectiveCameraConnected) {
                        BrowseState.Failed("Reconnect the camera to list media.")
                    } else if (!SwiftCore.isAvailable) {
                        BrowseState.Failed("Camera core is not bundled in this build.")
                    } else {
                        val listingCheckpoint =
                            withContext(Dispatchers.IO) {
                                libraryIndex.beginCameraListing(cameraID)
                            }
                        try {
                            val producer = mediaService ?: throw MediaBrowsePagingException("Camera media source unavailable.")
                            val owner = catalogOwner ?: throw MediaBrowsePagingException("Camera media source unavailable.")
                            val browse = owner.open()
                            val cursor = browse.catalog()
                            var catalog = com.opencapture.opencine.media.MediaCatalog()
                            var clips: List<MediaClipRecord> = emptyList()
                            try {
                                while (true) {
                                    val delta = cursor.next() ?: break
                                    kotlinx.coroutines.currentCoroutineContext().ensureActive()
                                    if (!producer.isCurrent(browse.binding)) throw kotlinx.coroutines.CancellationException("Source retired")
                                    val page = owner.capture(delta, catalog, browse.binding)
                                    catalog = page.catalog; clips = page.clips
                                    owner.admit(browse.binding)
                                    listingCheckpoint.applyPage(page.additions, page.removals)
                                    browseStorageSlots = producer.storageSlots(browse.binding)
                                    if (!producer.isCurrent(browse.binding)) throw kotlinx.coroutines.CancellationException("Source retired")
                                    state = BrowseState.Loaded(clips, isLoadingMore = !delta.complete)
                                }
                                owner.admit(browse.binding)
                                check(catalog.complete) { "Partial source catalog cannot prune the legacy index." }
                            } finally { cursor.close() }
                            owner.admit(browse.binding)
                            withContext(Dispatchers.IO) {
                                owner.admit(browse.binding)
                                // The camera answered for every object it holds, so rows it never
                                // listed are gone from the card — prune them unless a complete
                                // local copy keeps the clip browsable offline.
                                listingCheckpoint.commit(prunesUnlistedClips = true) { clip ->
                                    runCatching {
                                        cacheStore.completedEntryOrNull(
                                            cameraID,
                                            MediaCacheObjectIdentity(clip),
                                            clip.sizeBytes,
                                        )
                                    }.getOrNull() != null
                                }
                            }
                            BrowseState.Loaded(clips)
                        } catch (error: CancellationException) {
                            throw error
                        } catch (error: com.opencapture.opencine.media.MediaServiceException) {
                            if (error.failure == com.opencapture.opencine.media.MediaServiceFailure.RETIRED) {
                                throw CancellationException("Camera media source retired", error)
                            }
                            withContext(Dispatchers.IO) { listingCheckpoint.commit() }
                            val partial = (state as? BrowseState.Loaded)?.clips.orEmpty()
                            incompleteCameraBrowseState(partial)
                        } catch (_: MediaBrowsePagingException) {
                            // A partial pass proves nothing about the rows it never reached.
                            withContext(Dispatchers.IO) { listingCheckpoint.commit() }
                            val partial = (state as? BrowseState.Loaded)?.clips.orEmpty()
                            incompleteCameraBrowseState(partial)
                        }
                    }
                }
                MediaLibrarySource.LOCAL -> {
                    val (clips, owners) =
                        withContext(Dispatchers.IO) {
                            // iOS offline `.camera` spans every per-serial bucket
                            // and keeps only fully downloaded entries.
                            val bucketIDs =
                                offlineCameraIDs.takeIf { it.isNotEmpty() }
                                    ?: listOf(cameraID)
                            val nextOwners = linkedMapOf<String, String>()
                            val nextClips = ArrayList<MediaClipRecord>()
                            for (bucketID in bucketIDs) {
                                for (clip in libraryIndex.persistedClips(bucketID)) {
                                    val complete =
                                        runCatching {
                                            cacheStore.completedEntryOrNull(
                                                bucketID,
                                                MediaCacheObjectIdentity(clip),
                                                clip.sizeBytes,
                                            )
                                        }.getOrNull()
                                    if (complete != null) {
                                        nextOwners[clip.offlineObjectKey()] = bucketID
                                        nextClips += clip
                                    }
                                }
                            }
                            nextClips to nextOwners
                        }
                    offlineClipOwners = owners
                    BrowseState.Loaded(clips)
                }
            }
        state = nextState
        if (
            autoPlayFirstProxy &&
                !autoPlayHandled &&
                nextState is BrowseState.Loaded
        ) {
            autoPlayHandled = true
            playingClip =
                nextState.clips.firstOrNull {
                    it.contentKind == MediaContentKind.PLAYABLE_PROXY
                }
        }
    }

    // Runs one confirmed camera-card deletion after the listing effect above
    // cancelled: delete each object on the card, then purge every local trace
    // the list scan could resurrect an item from — cached bytes, resumable
    // partials, the index row, and the favorite. Clearing [pendingDeletion]
    // restarts the listing so the fresh enumeration confirms the deletions.
    LaunchedEffect(pendingDeletion) {
        val targets = pendingDeletion ?: return@LaunchedEffect
        // A still viewer closed by this deletion may leave its transfer draining; the blocking
        // stop joins the pump so the card never sees a delete interleaved with reads of the same
        // object. The grid holds steady (the listing stays cancelled) — one progress bar covers
        // the run and it refreshes once at the end.
        withContext(Dispatchers.IO) {
            if (SwiftCore.isAvailable) connectionOwner?.let(NikonNative::sessionStopMediaTransfer)
        }
        deletionProgress = 0 to targets.size
        targets.forEachIndexed { index, clip ->
            withContext(Dispatchers.IO) {
                // Protected objects are refused by the body and stay listed; their caches stay
                // too so the row remains fully backed.
                if (
                    SwiftCore.isAvailable &&
                        connectionOwner != null &&
                        NikonNative.sessionDeleteObject(connectionOwner, clip.handle.toInt())
                ) {
                    val owner = ownerCameraID(clip)
                    runCatching {
                        cacheStore.purgeEntry(owner, MediaCacheObjectIdentity(clip))
                    }
                    libraryIndex.purgeClip(owner, clip)
                }
            }
            deletionProgress = (index + 1) to targets.size
        }
        deletionProgress = null
        favorites =
            withContext(Dispatchers.IO) {
                val ids = offlineCameraIDs.takeIf { it.isNotEmpty() } ?: listOf(cameraID)
                ids.flatMap { id -> libraryIndex.favoriteIDs(id) }.toSet()
            }
        exitSelection()
        pendingDeletion = null
    }

    fun requestDeletion(selection: List<MediaClipRecord>) {
        if (selection.isEmpty() || pendingDeletion != null) return
        val catalog = (state as? BrowseState.Loaded)?.clips.orEmpty()
        deleteConfirmTargets = null
        viewingPhoto = null
        deletionSelectedCount = selection.size
        pendingDeletion = cameraDeletionTargets(catalog, selection, ::ownerCameraID)
    }

    val loadedClips = (state as? BrowseState.Loaded)?.clips.orEmpty()
    val visibleStorageSlots =
        mediaStorageSlotPresentations(
            source = librarySource,
            cameraConnected = cameraConnected,
            cameraSessionAvailable = cameraSessionAvailable,
            slots = browseStorageSlots ?: cameraStorageSlots,
        )
    LaunchedEffect(cameraID, librarySource, state, visibleStorageSlots) {
        if (state !is BrowseState.Loaded) return@LaunchedEffect
        val retained =
            filters.retainingAvailableStorage(
                librarySource,
                visibleStorageSlots.mapTo(linkedSetOf(), MediaStorageSlotPresentation::storageId),
            )
        if (retained != filters) filters = retained
    }
    // Filtering ends in a sortedWith that lowercases every filename per comparison, so it must not
    // re-run on unrelated recompositions (a selection tap used to pay for a full re-sort).
    val displayedClips =
        remember(
            loadedClips,
            options.category,
            favorites,
            cameraID,
            options.sortOrder,
            filters,
            offlineClipOwners,
        ) {
            MediaLibraryFiltering.displayed(
                clips = loadedClips,
                category = options.category,
                favoriteIDs = favorites,
                cameraID = cameraID,
                sortOrder = options.sortOrder,
                filters = filters,
                libraryKey = ::clipKey,
                ownerOf = ::ownerCameraID,
            )
        }
    // The chips the popup may offer, derived from the category's own listing before any chip is
    // applied — so a category never advertises a value its media cannot match.
    val filterOptions =
        remember(loadedClips, options.category, favorites, cameraID, offlineClipOwners) {
            MediaFilterDerivation.options(
                MediaLibraryFiltering.categoryScoped(
                    clips = loadedClips,
                    category = options.category,
                    favoriteIDs = favorites,
                    cameraID = cameraID,
                    libraryKey = ::clipKey,
                ),
            )
        }
    // Only an operator navigation prunes, never a discovery batch: chips derived from a listing
    // that is still streaming in must not clear a selection the operator just made.
    LaunchedEffect(options.category, librarySource) {
        val retained = filters.retainingOfferedChips(filterOptions)
        if (retained != filters) filters = retained
    }
    // One key pass over the library, reused by every lookup below. Rebuilding this per call was
    // the other half of the multiselect stall.
    val clipsByKey = remember(displayedClips) { displayedClips.associateBy(::clipKey) }
    // Collapse continuous-drive runs into one representative cell per series (iOS
    // filteredMediaClips burst step). Grouping runs on the displayed set, so an offline pass
    // groups only cached frames; the series view reaches the hidden members.
    val burstSeries =
        remember(displayedClips) {
            BurstSeriesGrouping.group(displayedClips.map { it.burstFrame(ownerCameraID(it)) })
        }
    val burstByRepresentative =
        remember(burstSeries) { burstSeries.associateBy { it.representativeID } }
    val hiddenBurstIDs =
        remember(burstSeries) { burstSeries.flatMapTo(hashSetOf()) { it.memberIDs.drop(1) } }
    val gridClips =
        remember(displayedClips, hiddenBurstIDs) {
            if (hiddenBurstIDs.isEmpty()) displayedClips
            else displayedClips.filter { clipKey(it) !in hiddenBurstIDs }
        }
    fun burstMembers(representative: MediaClipRecord): List<MediaClipRecord> {
        val series = burstByRepresentative[clipKey(representative)] ?: return emptyList()
        return series.memberIDs.mapNotNull { clipsByKey[it] }
    }
    // A grid burst cell stands for its whole series (iOS `burstExpanded`): expand each selected
    // representative to every member so a multiselect delete/share acts on the whole set, not
    // just the representative. Non-series clips pass through; deduped, order preserved.
    fun burstExpanded(clips: List<MediaClipRecord>): List<MediaClipRecord> {
        if (clips.isEmpty()) return clips
        val byID = clipsByKey
        val seen = HashSet<String>()
        val result = ArrayList<MediaClipRecord>(clips.size)
        for (clip in clips) {
            val members =
                burstByRepresentative[clipKey(clip)]?.memberIDs?.mapNotNull { byID[it] }
                    ?.takeIf { it.isNotEmpty() } ?: listOf(clip)
            for (member in members) if (seen.add(clipKey(member))) result.add(member)
        }
        return result
    }
    // Pair lookups scan the unfiltered catalog so the RAW side survives tab
    // and chip filters (iOS `rawSibling(of:)`).
    val rawStillPairKeys =
        remember(loadedClips, offlineClipOwners) {
            loadedClips.mapNotNullTo(hashSetOf()) { clip ->
                if (clip.isRawStill) clip.rawPairKey(ownerCameraID(clip)) else null
            }
        }
    fun hasRawSibling(clip: MediaClipRecord): Boolean =
        clip.isJpegStill && clip.rawPairKey(ownerCameraID(clip)) in rawStillPairKeys
    val selectedClips =
        remember(clipsByKey, selectedIDs) {
            displayedClips.filter { clip -> clipKey(clip) in selectedIDs }
        }
    // Delete/share act on the whole burst series behind a selected representative (iOS
    // `burstExpanded`); the selection COUNT stays on the representatives, mirroring iOS.
    val selectedSeriesClips =
        remember(clipsByKey, selectedClips, burstByRepresentative) {
            burstExpanded(selectedClips)
        }
    val visibleIDs = clipsByKey.keys

    LaunchedEffect(visibleIDs) {
        val retained = MediaLibrarySelection.retainVisible(selectedIDs, visibleIDs)
        if (retained != selectedIDs) selectedIDs = retained
        if (retained.isEmpty()) isSelecting = false
    }

    // Only the delivery popup reads this, and it stats every selected clip on disk. Keyed on the
    // ID set rather than the rebuilt clip list so it doesn't restart on unrelated recompositions,
    // and skipped entirely while no popup is up — otherwise every selection tap paid for a disk
    // fan-out plus the second full pass of this screen that writing the result triggers.
    LaunchedEffect(
        cameraID,
        offlineClipOwners,
        selectedIDs,
        nativeDeliveryPresented,
        frameioDeliveryPresented,
    ) {
        if (!nativeDeliveryPresented && !frameioDeliveryPresented) return@LaunchedEffect
        readySelectionIDs =
            withContext(Dispatchers.IO) {
                selectedClips.mapNotNull { clip ->
                    val owner = ownerCameraID(clip)
                    val complete =
                        runCatching {
                            cacheStore.completedEntryOrNull(
                                owner,
                                MediaCacheObjectIdentity(clip),
                                clip.sizeBytes,
                            )
                        }.getOrNull()
                    clip.libraryKey(owner).takeIf { complete != null }
                }.toSet()
            }
    }
    val selectedLutLabel =
        when (selectedLut) {
            is FeedLutSelection.BuiltIn -> selectedLut.value.label
            is FeedLutSelection.Stored -> lutLibrary.displayName(selectedLut.value)
        }

    // Re-merge favorites across offline buckets so the star stays accurate after a change.
    fun mergedFavorites(updated: Set<String>): Set<String> =
        if (offlineCameraIDs.isEmpty()) {
            updated
        } else {
            offlineCameraIDs.flatMap { id -> libraryIndex.favoriteIDs(id) }.toSet()
        }

    fun toggleFavorite(clip: MediaClipRecord) {
        val owner = ownerCameraID(clip)
        val updated = libraryIndex.toggleFavorite(owner, clip)
        favorites = mergedFavorites(updated)
        // Heart and camera star are one signal (Favorites reads the set that star writes fill):
        // agree the body's rating with the heart when connected. Best-effort — an offline clip
        // keeps only the local flag. [verify-on-HW]
        val nowFavorite = clip.libraryKey(owner) in updated
        val ratingOwner = connectionOwner
        if (
            effectiveCameraConnected && SwiftCore.isAvailable && clip.handle != 0L && ratingOwner != null
        ) {
            scope.launch {
                withContext(Dispatchers.IO) {
                    NikonNative.sessionSetObjectRating(
                        ratingOwner,
                        clip.handle.toInt(),
                        if (nowFavorite) 1 else 0,
                    )
                }
            }
        }
    }

    // Mirrors a camera star write (viewer/player, seed-read or set) into the local favorite set
    // so the Favorites tab surfaces rated shots. iOS `mirrorRatingIntoIndex`.
    fun mirrorRating(clip: MediaClipRecord, stars: Int) {
        val owner = ownerCameraID(clip)
        favorites = mergedFavorites(libraryIndex.setFavorite(owner, clip, stars >= 1))
    }

    fun open(clip: MediaClipRecord) {
        // A burst representative opens the series view (its other frames are hidden in the grid).
        if (burstByRepresentative[clipKey(clip)] != null) {
            seriesRepresentative = clip
            return
        }
        when (clip.contentKind) {
            MediaContentKind.PLAYABLE_PROXY -> playingClip = clip
            MediaContentKind.STILL_PHOTO -> viewingPhoto = clip
            MediaContentKind.R3D_MASTER ->
                shareMessage = "${clip.filename} is a camera master; preview is unavailable."
            MediaContentKind.UNSUPPORTED ->
                shareMessage = "${clip.filename} has no Android preview yet."
        }
    }

    fun beginSelection(clip: MediaClipRecord) {
        if (shareInProgress) return
        isSelecting = true
        selectedIDs = MediaLibrarySelection.begin(clipKey(clip))
        shareMessage = null
    }



    fun beginBatchShare(configuration: MediaDeliveryConfiguration) {
        if (shareInProgress || selectedClips.isEmpty()) return
        val selectionSnapshot = selectedSeriesClips
        val coordinator = mediaDeliveryCoordinator
        if (coordinator != null) {
            // The whole selection goes to the coordinator: it caches whatever is still only on
            // the camera before delivering. Filtering to already-cached entries here is what
            // silently shipped 2 of 10 selected clips.
            coordinator.beginNativeShare(
                selection = selectionSnapshot.map { MediaDeliverySelection(ownerCameraID(it), it) },
                configuration = configuration,
                cameraConnectionOwner = connectionOwner.takeIf { effectiveCameraConnected },
            ) { published, metadata ->
                context.startActivity(
                    AndroidMediaShareIntent.chooserIntent(context, published, metadata),
                )
                exitSelection()
            }
            return
        }
        val selectionSnapshotLegacy = selectedSeriesClips
        shareInProgress = true
        shareMessage = null
        shareJob =
            scope.launch {
                val stageContext = coroutineContext
                try {
                    val staged =
                        withContext(Dispatchers.IO) {
                            stageSelectedMedia(
                                context,
                                cacheStore,
                                cameraID,
                                selectionSnapshotLegacy,
                                cameraIDFor = ::ownerCameraID,
                            ) { stageContext.ensureActive() }
                        }
                    if (staged.staged.isEmpty()) {
                        shareMessage =
                            staged.firstFailure
                                ?: "Only complete cached media can be shared."
                    } else {
                        val configured =
                            prepareExternalMedia(
                                frameioController,
                                cameraID,
                                staged,
                                configuration,
                            ) { stageContext.ensureActive() }
                        val published = mutableListOf<StagedMediaShare>()
                        val publishedClips = mutableListOf<MediaClipRecord>()
                        var publicationFailures = 0
                        var cleanupFailures = 0
                        configured.prepared.forEach { item ->
                            try {
                                val share =
                                    if (item.artifact.transientExport == null) {
                                        item.artifact.share
                                    } else {
                                        withContext(Dispatchers.IO) {
                                            MediaShareStager(context.cacheDir.toPath())
                                                .stagePreparedArtifact(
                                                    source = item.artifact.share.file,
                                                    expectedBytes = item.artifact.byteCount,
                                                    displayName = item.artifact.share.displayName,
                                                    mimeType = item.artifact.share.mimeType,
                                                ) { stageContext.ensureActive() }
                                        }
                                    }
                                published += share
                                publishedClips += item.clip
                            } catch (error: CancellationException) {
                                throw error
                            } catch (_: Exception) {
                                publicationFailures += 1
                            } finally {
                                val released =
                                    withContext(NonCancellable) {
                                        runCatching {
                                            frameioController.releaseExternalDelivery(item.artifact)
                                        }.isSuccess
                                    }
                                if (!released) cleanupFailures += 1
                            }
                        }
                        if (published.isEmpty()) {
                            shareMessage =
                                configured.firstFailure
                                    ?: "Couldn't produce a complete configured share artifact."
                            return@launch
                        }
                        val metadata =
                            mediaDeliveryMetadataSummary(publishedClips)
                                .takeIf { configuration.includeMetadata }
                        context.startActivity(
                            AndroidMediaShareIntent.chooserIntent(context, published, metadata),
                        )
                        val skipped =
                            staged.incompleteCount +
                                staged.failedCount +
                                configured.failedCount +
                                publicationFailures
                        shareMessage =
                            buildString {
                                append("Sharing ${published.size} configured item")
                                if (published.size != 1) append('s')
                                if (skipped > 0) append("; $skipped skipped")
                                if (cleanupFailures > 0) {
                                    append("; $cleanupFailures temporary export cleanup failed")
                                }
                            }
                        exitSelection()
                    }
                } catch (error: CancellationException) {
                    throw error
                } catch (error: Exception) {
                    shareMessage = error.message ?: "Couldn't prepare the selected media for sharing."
                } finally {
                    shareInProgress = false
                    shareJob = null
                }
            }
    }

    fun presentNativeDelivery() {
        if (shareInProgress || selectedClips.isEmpty()) return
        nativeDeliveryPresented = true
    }

    fun beginBatchGallerySave(configuration: MediaDeliveryConfiguration) {
        if (shareInProgress || selectedClips.isEmpty()) return
        val selectionSnapshot = selectedSeriesClips
        // Gallery accepts playable proxies AND still photos; only R3D masters
        // and unsupported objects are omitted.
        val savableSelection =
            selectionSnapshot.filter { clip ->
                clip.contentKind == MediaContentKind.PLAYABLE_PROXY ||
                    clip.contentKind == MediaContentKind.STILL_PHOTO
            }
        val omittedCount = selectionSnapshot.size - savableSelection.size
        nativeDeliveryPresented = false
        if (savableSelection.isEmpty()) {
            shareMessage =
                MediaGalleryBatchResult(savedCount = 0, failures = emptyList())
                    .operatorMessage(MediaGalleryOmissions(nonVideoCount = omittedCount))
            return
        }
        val coordinator = mediaDeliveryCoordinator
        if (coordinator != null) {
            // The full snapshot goes across: the coordinator caches the on-camera clips first and
            // reports the non-savable ones itself, so nothing is dropped between here and Gallery.
            coordinator.beginSaveToPhotos(
                selection = selectionSnapshot.map { MediaDeliverySelection(ownerCameraID(it), it) },
                configuration = configuration,
                cameraConnectionOwner = connectionOwner.takeIf { effectiveCameraConnected },
            )
            exitSelection()
            return
        }
        shareInProgress = true
        shareMessage = null
        shareJob =
            scope.launch {
                val stageContext = coroutineContext
                try {
                    val staged =
                        withContext(Dispatchers.IO) {
                            stageSelectedMedia(
                                context,
                                cacheStore,
                                cameraID,
                                savableSelection,
                            ) { stageContext.ensureActive() }
                        }
                    val configured =
                        prepareExternalMedia(
                            frameioController,
                            cameraID,
                            staged,
                            configuration,
                        ) { stageContext.ensureActive() }
                    var artifactFailures = 0
                    val artifacts =
                        withContext(Dispatchers.IO) {
                            configured.prepared.mapNotNull { item ->
                                runCatching {
                                    MediaGalleryArtifact.fromStagedShare(
                                        item.artifact.share,
                                        mediaCaptureTimestampMillis(item.clip.captureDate)
                                            .takeIf { configuration.includeMetadata },
                                    )
                                }.onFailure { artifactFailures += 1 }
                                    .getOrNull()
                            }
                        }
                    var cleanupFailures = 0
                    val result =
                        try {
                            withContext(Dispatchers.IO) {
                                MediaGallerySaver(galleryGateway).save(artifacts) {
                                    stageContext.ensureActive()
                                }
                            }
                        } finally {
                            configured.prepared.forEach { item ->
                                val released =
                                    withContext(NonCancellable) {
                                        runCatching {
                                            frameioController.releaseExternalDelivery(item.artifact)
                                        }.isSuccess
                                    }
                                if (!released) cleanupFailures += 1
                            }
                        }
                    val delivery =
                        GalleryDelivery(
                            result = result,
                            omissions =
                                MediaGalleryOmissions(
                                    nonVideoCount = omittedCount,
                                    incompleteCount = staged.incompleteCount,
                                    preparationFailureCount =
                                        staged.failedCount +
                                            configured.failedCount +
                                            artifactFailures,
                                    temporaryCleanupFailureCount = cleanupFailures,
                                ),
                        )
                    shareMessage = delivery.result.operatorMessage(delivery.omissions)
                    if (
                        delivery.result.savedCount == savableSelection.size &&
                            delivery.result.failedCount == 0 &&
                            delivery.omissions.totalCount == 0
                    ) {
                        exitSelection()
                    }
                } catch (error: CancellationException) {
                    throw error
                } catch (_: Exception) {
                    shareMessage = "Couldn't prepare the selected media for Gallery."
                } finally {
                    shareInProgress = false
                    shareJob = null
                }
            }
    }

    fun presentFrameioDelivery() {
        if (shareInProgress || selectedClips.isEmpty()) return
        frameioController.refresh()
        frameioDeliveryPresented = true
    }

    fun beginFrameioDelivery(options: FrameioDeliveryOptions) {
        if (shareInProgress || selectedClips.isEmpty()) return
        val selectionSnapshot = selectedSeriesClips
        frameioDeliveryPresented = false
        shareInProgress = true
        frameioPreparationInProgress = true
        shareMessage = null
        shareJob =
            scope.launch {
                val stageContext = coroutineContext
                // The upload runs here, not in the coordinator, so hand it the job the overlay's
                // Cancel must reach — otherwise Cancel stopped nothing mid-upload.
                mediaDeliveryCoordinator?.trackExternalDelivery(stageContext[Job])
                var skippedBeforeUpload: Int? = null
                var completedWithoutFailures = false
                var cancelled = false
                try {
                    // Pull the on-camera clips down first; staging only sees complete entries, so
                    // without this pass an uncached selection uploaded nothing and said nothing.
                    // Mid-hop the phone is off the camera's Wi-Fi — that selection was already
                    // cached before the hop, and retrying here would only stall on dead sockets.
                    mediaDeliveryCoordinator?.cacheFromCamera(
                        destination = MediaDeliveryKind.FRAMEIO,
                        selection =
                            selectionSnapshot.map { MediaDeliverySelection(ownerCameraID(it), it) },
                        cameraConnectionOwner =
                            connectionOwner.takeIf {
                                effectiveCameraConnected && !frameioController.isInternetHopActive
                            },
                    )
                    val result =
                        withContext(Dispatchers.IO) {
                            stageSelectedMedia(
                                context,
                                cacheStore,
                                cameraID,
                                selectionSnapshot,
                                cameraIDFor = ::ownerCameraID,
                            ) { stageContext.ensureActive() }
                        }
                    if (result.staged.isEmpty()) {
                        shareMessage =
                            result.firstFailure
                                ?: "Only complete cached media can be delivered to Frame.io."
                        return@launch
                    }
                    val artifacts =
                        withContext(Dispatchers.IO) {
                            result.staged.zip(result.stagedClips).map { (share, clip) ->
                                val owner = ownerCameraID(clip)
                                FrameioDeliveryArtifact(
                                    share = share,
                                    byteCount = Files.size(share.file),
                                    context =
                                        FrameioArtifactContext(
                                            cameraID = owner,
                                            captureDate = clip.captureDate,
                                            supportsLutBake =
                                                clip.contentKind == MediaContentKind.PLAYABLE_PROXY,
                                            stableClipIdentity = clip.libraryKey(owner),
                                        ),
                                )
                            }
                        }
                    skippedBeforeUpload = result.incompleteCount + result.failedCount
                    frameioController.deliver(artifacts, options)
                    val completed = frameioController.deliveryState as? FrameioDeliveryState.Completed
                    completedWithoutFailures = completed != null && completed.failedCount == 0
                } catch (error: CancellationException) {
                    cancelled = true
                    shareMessage = "Frame.io delivery cancelled."
                    throw error
                } catch (_: Exception) {
                    shareMessage = "Couldn't prepare the selected media for Frame.io delivery."
                } finally {
                    endActiveFrameioHopAfterMediaJob(
                        isActive = { frameioController.isInternetHopActive },
                        endHop = { frameioController.endInternetHop() },
                    )
                    shareMessage =
                        if (skippedBeforeUpload != null && !cancelled) {
                            frameioDeliverySummary(
                                state = frameioController.deliveryState,
                                internetHopState = frameioController.internetHopState,
                                errorMessage = frameioController.errorMessage,
                                skippedBeforeUpload = skippedBeforeUpload,
                            )
                        } else {
                            frameioPreparationMessageAfterRejoin(
                                shareMessage,
                                frameioController.internetHopState,
                            )
                        }
                    if (completedWithoutFailures && !cancelled) exitSelection()
                    mediaDeliveryCoordinator?.trackExternalDelivery(null)
                    frameioPreparationInProgress = false
                    shareInProgress = false
                    shareJob = null
                }
            }
    }

    LaunchedEffect(closeRequested) {
        if (!closeRequested) return@LaunchedEffect
        shareJob?.cancelAndJoin()
        if (frameioController.isInternetHopActive) {
            withContext(NonCancellable) { frameioController.endInternetHop() }
        }
        catalogOwner?.close()
        onClose()
    }
    BackHandler(enabled = playingClip == null && viewingPhoto == null) {
        if (isSelecting) cancelActiveShareOrExitSelection() else closeRequested = true
    }

    val density = LocalDensity.current
    val direction = LocalLayoutDirection.current
    val cutout = WindowInsets.displayCutout
    fun edge(insetPx: Int, extra: Float, floor: Float): Float =
        maxOf(with(density) { insetPx.toDp().value } + extra, floor)
    val topPad = edge(cutout.getTop(density), 6f, 16f)
    val trailingPad = edge(cutout.getRight(density, direction), 6f, 20f)
    val bottomPad = edge(cutout.getBottom(density), 4f, 14f)

    Box(
        Modifier.fillMaxSize()
            .background(LiveDesign.background)
            // This overlay owns every empty pixel; gestures never reach the
            // paused monitor below it.
            .pointerInput(Unit) { detectTapGestures {} },
    ) {
        BoxWithConstraints(Modifier.fillMaxSize()) {
            val portrait = maxHeight > maxWidth
            val leadingPad = edge(cutout.getLeft(density, direction), 6f, if (portrait) 16f else 64f)
            val contentModifier =
                Modifier.fillMaxSize().padding(
                    top = topPad.dp,
                    start = leadingPad.dp,
                    end = trailingPad.dp,
                    bottom = bottomPad.dp,
                )

            val showsGridControls =
                !isSelecting && !shareInProgress && !frameioPreparationInProgress
            val showRefresh =
                librarySource == MediaLibrarySource.CAMERA && effectiveCameraConnected
            val refreshInProgress =
                state is BrowseState.Loading ||
                    (state as? BrowseState.Loaded)?.isLoadingMore == true
            MonitorPageScaffold(
                modifier = contentModifier,
                navigationWidth = 206f,
                heading = {
                    Box(Modifier.padding(start = if (portrait) 45.dp else 0.dp)) {
                        MonitorPageHeading(title = "Media", kicker = "OpenZCine")
                    }
                },
                navigation = { navigationPortrait ->
                    if (navigationPortrait) {
                        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                            MediaCategoryStrip(
                                selected = options.category,
                                onSelect = { category -> updateOptions(options.copy(category = category)) },
                            )
                            if (visibleStorageSlots.isNotEmpty() && effectiveCameraConnected) {
                                MediaStorageSlotSelector(
                                    slots = visibleStorageSlots,
                                    selectedStorageId = filters.storageId,
                                    horizontal = true,
                                    onSelect = ::toggleStorageSlot,
                                )
                            }
                        }
                    } else {
                        MediaLibraryRail(
                            category = options.category,
                            storageSlots = if (effectiveCameraConnected) visibleStorageSlots else emptyList(),
                            selectedStorageId = filters.storageId,
                            onCategoryChange = { category -> updateOptions(options.copy(category = category)) },
                            onStorageSelect = ::toggleStorageSlot,
                            showsGridControls = showsGridControls,
                            layout = options.layout,
                            thumbnailSize = options.thumbnailSize,
                            onLayoutChange = { layout -> updateOptions(options.copy(layout = layout)) },
                            onThumbnailSizeChange = { size -> updateOptions(options.copy(thumbnailSize = size)) },
                            modifier = Modifier.fillMaxSize(),
                        )
                    }
                },
            ) {
                Column(Modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    MediaLibraryHeader(
                        state = state,
                        category = options.category,
                        displayedCount = displayedClips.size,
                        isSelecting = isSelecting,
                        selectedCount = selectedClips.size,
                        shareInProgress = shareInProgress,
                        frameioPreparationInProgress = frameioPreparationInProgress,
                        frameioDeliveryState = frameioController.deliveryState,
                        frameioInternetHopState = internetHopState,
                        sortOrder = options.sortOrder,
                        activeFilterCount = filters.activeCount,
                        deleteAvailable = librarySource == MediaLibrarySource.CAMERA && effectiveCameraConnected,
                        showRefresh = showRefresh,
                        refreshInProgress = refreshInProgress,
                        compact = portrait,
                        onRefresh = { reloadKey += 1 },
                        onExitSelection = ::cancelActiveShareOrExitSelection,
                        onDelete = { deleteConfirmTargets = selectedSeriesClips },
                        onShare = { presentNativeDelivery() },
                        onSortChange = { sort -> updateOptions(options.copy(sortOrder = sort)) },
                        onShowFilters = { filterDialogPresented = true },
                    )
                    Box(Modifier.weight(1f).fillMaxWidth()) {
                        MediaLibraryBody(
                            state = state,
                            clips = gridClips,
                            source = librarySource,
                            layout = options.layout,
                            thumbnailSize = options.thumbnailSize,
                            cameraID = cameraID,
                            cameraIDFor = ::ownerCameraID,
                            clipIdentity = ::clipKey,
                            hasRawSibling = ::hasRawSibling,
                            burstCountOf = { burstByRepresentative[clipKey(it)]?.count },
                            cameraConnected = cameraConnected,
                            connectionOwner = connectionOwner,
                            cacheStore = cacheStore,
                            favorites = favorites,
                            isSelecting = isSelecting,
                            selectedIDs = selectedIDs,
                            onOpen = ::open,
                            onBeginSelection = { identity -> if (!shareInProgress) beginSelection(identity) },
                            onSweepSelection = { next -> if (!shareInProgress) selectedIDs = next },
                            onToggleFavorite = ::toggleFavorite,
                            onRetry = { reloadKey += 1 },
                            modifier = Modifier.fillMaxSize()
                                .padding(bottom = if (portrait && showsGridControls) 84.dp else 0.dp),
                        )
                        if (portrait && showsGridControls) {
                            PortraitMediaGridControlsBand(
                                layout = options.layout,
                                thumbnailSize = options.thumbnailSize,
                                onLayoutChange = { layout -> updateOptions(options.copy(layout = layout)) },
                                onThumbnailSizeChange = { size -> updateOptions(options.copy(thumbnailSize = size)) },
                                modifier = Modifier.align(Alignment.BottomCenter),
                            )
                        }
                    }
                }
            }
        }

        CloseCircleButton(
            Modifier.padding(start = 16.dp, top = maxOf(topPad, 22f).dp),
            onClick = { closeRequested = true },
        )

        shareMessage?.let { message ->
            MediaStatusMessage(
                message = message,
                modifier = Modifier.align(Alignment.BottomCenter).padding(16.dp),
            )
        }

        if (nativeDeliveryPresented || frameioDeliveryPresented) {
            MediaDeliveryPopup(
                clipCount = selectedClips.size,
                readyCount = readySelectionIDs.size,
                cameraConnected = effectiveCameraConnected,
                selectedLut = selectedLut.takeIf { selectedLutLabel != null },
                selectedLutLabel = selectedLutLabel,
                frameioController = frameioController,
                preferredDestination =
                    if (frameioDeliveryPresented && !nativeDeliveryPresented) {
                        MediaDeliveryDestination.FRAMEIO
                    } else {
                        null
                    },
                busy = shareInProgress || frameioPreparationInProgress,
                onCacheBeforeHop = {
                    mediaDeliveryCoordinator?.cacheFromCamera(
                        destination = MediaDeliveryKind.FRAMEIO,
                        selection =
                            selectedSeriesClips.map { MediaDeliverySelection(ownerCameraID(it), it) },
                        cameraConnectionOwner = connectionOwner.takeIf { effectiveCameraConnected },
                    )
                },
                onDismiss = {
                    nativeDeliveryPresented = false
                    frameioDeliveryPresented = false
                    if (frameioController.isInternetHopActive) {
                        scope.launch {
                            withContext(NonCancellable) { frameioController.endInternetHop() }
                        }
                    }
                },
                onNativeShare = { configuration ->
                    nativeDeliveryPresented = false
                    frameioDeliveryPresented = false
                    beginBatchShare(configuration)
                },
                onSaveToGallery = { configuration ->
                    nativeDeliveryPresented = false
                    frameioDeliveryPresented = false
                    beginBatchGallerySave(configuration)
                },
                onFrameioDeliver = { options ->
                    nativeDeliveryPresented = false
                    frameioDeliveryPresented = false
                    beginFrameioDelivery(options)
                },
            )
        }

        if (filterDialogPresented) {
            MediaFilterDialog(
                filters = filters,
                options = filterOptions,
                storageIds = visibleStorageSlots.map(MediaStorageSlotPresentation::storageId),
                onFiltersChanged = ::updateFilters,
                onDismiss = { filterDialogPresented = false },
            )
        }

        // Manage-series view, iPhone-Photos burst style: the selected frame full-screen through
        // the still viewer (streaming decode, zoom, rating, RAW toggle, share, single-frame
        // delete all keep working) with a bottom scrubber strip; "Delete all" routes the whole
        // set through the shared confirm + batch deletion. Dismisses when its frames are gone.
        seriesRepresentative?.let { representative ->
            val members = remember(representative, displayedClips) { burstMembers(representative) }
            LaunchedEffect(members) { if (members.isEmpty()) seriesRepresentative = null }
            var selectedFrameKey by remember(representative) { mutableStateOf<String?>(null) }
            val selected =
                members.firstOrNull { clipKey(it) == selectedFrameKey } ?: members.firstOrNull()
            selected?.let { clip ->
                val owner = ownerCameraID(clip)
                MediaStillViewer(
                    clip = clip,
                    desqueeze = operatorSettings.localFramingAssistConfiguration,
                    cameraID = owner,
                    cameraTransferAvailable = cameraConnected,
                    connectionOwner = connectionOwner,
                    rawSibling = rawSibling(loadedClips, clip, ::ownerCameraID),
                    deleteAvailable =
                        librarySource == MediaLibrarySource.CAMERA && effectiveCameraConnected,
                    deleteConfirmMessage =
                        deleteConfirmationMessage(loadedClips, listOf(clip), ::ownerCameraID),
                    onDelete = { requestDeletion(listOf(clip)) },
                    onDeleteAll = { if (members.isNotEmpty()) deleteConfirmTargets = members },
                    onRatingMirrored = ::mirrorRating,
                    onRatingDiagnostic = onRatingDiagnostic,
                    onResolvedObjectSize = { resolvedClip, resolvedSize ->
                        libraryIndex.rememberResolvedObjectSize(
                            ownerCameraID(resolvedClip),
                            resolvedClip,
                            resolvedSize,
                        )
                    },
                    filmstrip = {
                        BurstFilmstrip(
                            members = members,
                            selectedKey = clipKey(clip),
                            keyOf = ::clipKey,
                            onSelect = { selectedFrameKey = it },
                            thumb = { member, thumbModifier ->
                                ClipArtwork(
                                    clip = member,
                                    source = librarySource,
                                    cameraID = ownerCameraID(member),
                                    cameraConnected = effectiveCameraConnected,
                                    connectionOwner = connectionOwner,
                                    cacheStore = cacheStore,
                                    modifier = thumbModifier,
                                )
                            },
                        )
                    },
                    onClose = { seriesRepresentative = null },
                )
            }
        }

        deleteConfirmTargets?.let { targets ->
            MediaDeleteConfirmDialog(
                // Context-aware: pair/master/backup notes appear only when this selection
                // actually pulls those companions in (videos never see stills wording).
                message = deleteConfirmationMessage(loadedClips, targets, ::ownerCameraID),
                onDelete = { requestDeletion(targets) },
                onDismiss = { deleteConfirmTargets = null },
            )
        }

        playingClip?.let { clip ->
            val owner = ownerCameraID(clip)
            MediaPlaybackScreen(
                initialClip = clip,
                filteredClips = displayedClips,
                cameraID = owner,
                cameraTransferAvailable = cameraConnected,
                connectionOwner = connectionOwner,
                favoriteIDs = favorites,
                framingConfiguration = operatorSettings.localFramingAssistConfiguration,
                galleryFailureInjection = galleryFailureInjection,
                playbackAssistState = playbackAssistState,
                sharedAssistState = liveAssistState,
                exposureAssistCameraInput = exposureAssistCameraInput,
                operatorSettings = operatorSettings,
                lutLibrary = lutLibrary,
                frameioController = frameioController,
                mediaDeliveryCoordinator = mediaDeliveryCoordinator,
                onToggleFavorite = ::toggleFavorite,
                onRatingMirrored = ::mirrorRating,
                onRatingDiagnostic = onRatingDiagnostic,
                onResolvedObjectSize = { resolvedClip, resolvedSize ->
                    libraryIndex.rememberResolvedObjectSize(
                        ownerCameraID(resolvedClip),
                        resolvedClip,
                        resolvedSize,
                    )
                },
                onClose = {
                    playingClip = null
                    reloadKey += 1
                },
            )
        }
        viewingPhoto?.let { clip ->
            val owner = ownerCameraID(clip)
            MediaStillViewer(
                clip = clip,
                desqueeze = operatorSettings.localFramingAssistConfiguration,
                cameraID = owner,
                cameraTransferAvailable = cameraConnected,
                connectionOwner = connectionOwner,
                rawSibling = rawSibling(loadedClips, clip, ::ownerCameraID),
                deleteAvailable =
                    librarySource == MediaLibrarySource.CAMERA && effectiveCameraConnected,
                deleteConfirmMessage =
                    deleteConfirmationMessage(loadedClips, listOf(clip), ::ownerCameraID),
                onDelete = { requestDeletion(listOf(clip)) },
                onRatingMirrored = ::mirrorRating,
                onRatingDiagnostic = onRatingDiagnostic,
                onResolvedObjectSize = { resolvedClip, resolvedSize ->
                    libraryIndex.rememberResolvedObjectSize(
                        ownerCameraID(resolvedClip),
                        resolvedClip,
                        resolvedSize,
                    )
                },
                onClose = {
                    viewingPhoto = null
                    reloadKey += 1
                },
            )
        }

        // Batch-delete progress: the grid holds steady behind this until the run finishes.
        deletionProgress?.let { (done, total) ->
            Box(
                Modifier
                    .fillMaxSize()
                    .background(Color.Black.copy(alpha = 0.35f))
                    .chromeClickable(onClick = {}),  // swallow taps mid-delete
                contentAlignment = Alignment.Center,
            ) {
                Column(
                    Modifier
                        .glass(RoundedCornerShape(16.dp))
                        .padding(horizontal = 24.dp, vertical = 20.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    val picks = deletionSelectedCount.coerceAtLeast(1)
                    Text(
                        "Deleting $picks ${if (picks == 1) "item" else "items"}…",
                        style = chromeStyle(14f, FontWeight.SemiBold),
                        color = LiveDesign.text,
                    )
                    // Explain the inflated file count: 8 picks can be 16 files once each
                    // RAW+JPEG pair (and any backup copies) are counted.
                    Text(
                        if (total > picks) "$done of $total files · incl. RAW + copies"
                        else "$done of $total",
                        style = chromeStyle(11f, FontWeight.Normal),
                        color = LiveDesign.muted,
                    )
                    LinearProgressIndicator(
                        progress = { if (total > 0) done.toFloat() / total else 0f },
                        modifier = Modifier.width(220.dp).padding(top = 6.dp),
                    )
                }
            }
        }
    }
}

/** Horizontal category strip that keeps labels readable on portrait phones. */
@Composable
private fun MediaCategoryStrip(
    selected: MediaLibraryCategory,
    onSelect: (MediaLibraryCategory) -> Unit,
    modifier: Modifier = Modifier,
) {
    val scroll = rememberScrollState()
    MonitorMediaNavigation(
        categories = mediaNavigationCategories,
        selectedID = selected.name,
        vertical = false,
        onSelect = { id -> MediaLibraryCategory.entries.firstOrNull { it.name == id }?.let(onSelect) },
        modifier = modifier.horizontalScroll(scroll),
    )
}

private val mediaNavigationCategories = MediaLibraryCategory.entries.map {
    MonitorMediaNavigationCategory(id = it.name, title = it.title)
}

/** Ordered, selectable capacity cards shared by portrait and landscape media layouts. */
@Composable
internal fun MediaStorageSlotSelector(
    slots: List<MediaStorageSlotPresentation>,
    selectedStorageId: Long?,
    horizontal: Boolean,
    onSelect: (Long) -> Unit,
    modifier: Modifier = Modifier,
) {
    if (slots.isEmpty()) return
    if (horizontal) {
        Row(
            modifier.fillMaxWidth().horizontalScroll(rememberScrollState()),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            slots.forEach { slot ->
                MediaStorageSlotCard(
                    slot = slot,
                    active = selectedStorageId == slot.storageId,
                    horizontal = true,
                    onClick = { onSelect(slot.storageId) },
                )
            }
        }
    } else {
        Column(modifier, verticalArrangement = Arrangement.spacedBy(6.dp)) {
            slots.forEach { slot ->
                MediaStorageSlotCard(
                    slot = slot,
                    active = selectedStorageId == slot.storageId,
                    horizontal = false,
                    onClick = { onSelect(slot.storageId) },
                )
            }
        }
    }
}

@Composable
private fun MediaStorageSlotCard(
    slot: MediaStorageSlotPresentation,
    active: Boolean,
    horizontal: Boolean,
    onClick: () -> Unit,
) {
    val label = stringResource(R.string.media_storage_slot_label, slot.slotNumber)
    val summary =
        if (slot.totalGigabytes > 0) {
            stringResource(
                R.string.media_storage_slot_summary,
                slot.freeGigabytes,
                slot.totalGigabytes,
            )
        } else {
            stringResource(R.string.media_storage_slot_summary_unknown_total, slot.freeGigabytes)
        }
    val description =
        stringResource(
            if (active) {
                R.string.media_storage_slot_filter_selected_description
            } else {
                R.string.media_storage_slot_filter_description
            },
            slot.slotNumber,
            summary,
        )
    val shape = RoundedCornerShape(8.dp)
    Column(
        Modifier.then(if (horizontal) Modifier.width(154.dp) else Modifier.fillMaxWidth())
            .heightIn(min = 48.dp)
            .clip(shape)
            .background(if (active) LiveDesign.accentDim else LiveDesign.surface.copy(alpha = 0.55f))
            .border(
                1.dp,
                if (active) LiveDesign.accent.copy(alpha = 0.5f) else LiveDesign.hairline,
                shape,
            ).semantics {
                contentDescription = description
                role = Role.RadioButton
                selected = active
            }.chromeClickable(onClick)
            .padding(horizontal = 10.dp, vertical = 8.dp),
        verticalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        Text(
            label,
            style = chromeStyle(11f, FontWeight.SemiBold, mono = true),
            color = if (active) LiveDesign.accent else LiveDesign.text,
            maxLines = 1,
        )
        Text(
            summary,
            style = chromeStyle(9f, FontWeight.Medium, mono = true),
            color = LiveDesign.muted,
            maxLines = if (horizontal) 1 else 2,
        )
    }
}

/**
 * Landscape navigation rail — iOS sidebar: category tabs, optional storage
 * cards, spacer, then layout/density controls at the bottom (172pt wide).
 * No Camera/On-device source toggle (iOS sets source programmatically).
 */
@Composable
internal fun MediaLibraryRail(
    category: MediaLibraryCategory,
    storageSlots: List<MediaStorageSlotPresentation>,
    selectedStorageId: Long?,
    onCategoryChange: (MediaLibraryCategory) -> Unit,
    onStorageSelect: (Long) -> Unit,
    showsGridControls: Boolean,
    layout: MediaLibraryLayout,
    thumbnailSize: MediaThumbnailSize,
    onLayoutChange: (MediaLibraryLayout) -> Unit,
    onThumbnailSizeChange: (MediaThumbnailSize) -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(modifier, verticalArrangement = Arrangement.spacedBy(14.dp)) {
        Column(
            Modifier.weight(1f, fill = false).fillMaxWidth().verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            MonitorMediaNavigation(
                categories = mediaNavigationCategories,
                selectedID = category.name,
                vertical = true,
                onSelect = { id -> MediaLibraryCategory.entries.firstOrNull { it.name == id }?.let(onCategoryChange) },
            )
            if (storageSlots.isNotEmpty()) {
                MediaStorageSlotSelector(
                    slots = storageSlots,
                    selectedStorageId = selectedStorageId,
                    horizontal = false,
                    onSelect = onStorageSelect,
                )
            }
        }
        if (showsGridControls) {
            MediaGridLayoutControls(layout, thumbnailSize, onLayoutChange, onThumbnailSizeChange)
        }
    }
}

@Composable
private fun MediaGridLayoutControls(
    layout: MediaLibraryLayout,
    thumbnailSize: MediaThumbnailSize,
    onLayoutChange: (MediaLibraryLayout) -> Unit,
    onThumbnailSizeChange: (MediaThumbnailSize) -> Unit,
    modifier: Modifier = Modifier,
) {
    MonitorCatalogDisplayControls(
        list = layout == MediaLibraryLayout.LIST,
        thumbnailSize = when (thumbnailSize) {
            MediaThumbnailSize.SMALL -> MonitorThumbnailSize.SMALL
            MediaThumbnailSize.MEDIUM -> MonitorThumbnailSize.MEDIUM
            MediaThumbnailSize.LARGE -> MonitorThumbnailSize.LARGE
        },
        onList = { onLayoutChange(if (it) MediaLibraryLayout.LIST else MediaLibraryLayout.GRID) },
        onThumbnailSize = {
            onThumbnailSizeChange(when (it) {
                MonitorThumbnailSize.SMALL -> MediaThumbnailSize.SMALL
                MonitorThumbnailSize.MEDIUM -> MediaThumbnailSize.MEDIUM
                MonitorThumbnailSize.LARGE -> MediaThumbnailSize.LARGE
            })
        },
        modifier = modifier,
    )
}

/** iOS portrait bottom band: gradient fade + layout/density capsule. */
@Composable
private fun PortraitMediaGridControlsBand(
    layout: MediaLibraryLayout,
    thumbnailSize: MediaThumbnailSize,
    onLayoutChange: (MediaLibraryLayout) -> Unit,
    onThumbnailSizeChange: (MediaThumbnailSize) -> Unit,
    modifier: Modifier = Modifier,
) {
    Box(
        modifier
            .fillMaxWidth()
            .height(84.dp)
            .background(
                Brush.verticalGradient(
                    colors =
                        listOf(
                            LiveDesign.background.copy(alpha = 0f),
                            LiveDesign.background.copy(alpha = 0.94f),
                        ),
                ),
            ),
        contentAlignment = Alignment.BottomCenter,
    ) {
        MediaGridLayoutControls(
            layout = layout,
            thumbnailSize = thumbnailSize,
            onLayoutChange = onLayoutChange,
            onThumbnailSizeChange = onThumbnailSizeChange,
            modifier = Modifier.padding(bottom = 4.dp),
        )
    }
}

/**
 * Main title/header — iOS mainHeader: MULTIMEDIA identity + FILTER/SORT only.
 * Layout density controls live in the sidebar / portrait bottom band.
 */
@Composable
private fun MediaLibraryHeader(
    state: BrowseState,
    category: MediaLibraryCategory,
    displayedCount: Int,
    isSelecting: Boolean,
    selectedCount: Int,
    shareInProgress: Boolean,
    frameioPreparationInProgress: Boolean,
    frameioDeliveryState: FrameioDeliveryState,
    frameioInternetHopState: FrameioInternetHopState,
    sortOrder: MediaLibrarySortOrder,
    activeFilterCount: Int,
    deleteAvailable: Boolean,
    showRefresh: Boolean,
    refreshInProgress: Boolean,
    compact: Boolean,
    onRefresh: () -> Unit,
    onExitSelection: () -> Unit,
    onDelete: () -> Unit,
    onShare: () -> Unit,
    onSortChange: (MediaLibrarySortOrder) -> Unit,
    onShowFilters: () -> Unit,
) {
    if (isSelecting) {
        SelectionHeader(
            selectedCount = selectedCount,
            shareInProgress = shareInProgress,
            frameioPreparationInProgress = frameioPreparationInProgress,
            frameioDeliveryState = frameioDeliveryState,
            frameioInternetHopState = frameioInternetHopState,
            deleteAvailable = deleteAvailable,
            onExit = onExitSelection,
            onDelete = onDelete,
            onShare = onShare,
        )
        return
    }

    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.Top, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        val orders = MediaLibrarySortOrder.entries
        MonitorCatalogHeader(
            title = category.titleForHeader(),
            subtitle = itemCountLabel(state, displayedCount),
            compact = compact,
            sort = sortOrder.title,
            filterActive = activeFilterCount > 0,
            filterCount = activeFilterCount,
            onSort = { onSortChange(orders[(orders.indexOf(sortOrder) + 1) % orders.size]) },
            onFilter = onShowFilters,
            modifier = Modifier.weight(1f),
        )
        if (showRefresh) RefreshControl(enabled = !refreshInProgress, onClick = onRefresh)
        if (refreshInProgress) CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp)
    }
}

/**
 * iOS `selectionHeader`: close · "N selected" · single Share capsule.
 * Share opens the unified delivery popup (native + Frame.io), same as a clip.
 */
@Composable
private fun SelectionHeader(
    selectedCount: Int,
    shareInProgress: Boolean,
    frameioPreparationInProgress: Boolean,
    frameioDeliveryState: FrameioDeliveryState,
    frameioInternetHopState: FrameioInternetHopState,
    deleteAvailable: Boolean,
    onExit: () -> Unit,
    onDelete: () -> Unit,
    onShare: () -> Unit,
) {
    val rejoiningCamera = frameioInternetHopState is FrameioInternetHopState.RejoiningCamera
    val upload = frameioDeliveryState as? FrameioDeliveryState.Uploading
    val busy = shareInProgress || frameioPreparationInProgress || upload != null || rejoiningCamera
    val shareEnabled = selectedCount > 0 && !busy
    val deleteEnabled = deleteAvailable && selectedCount > 0 && !busy
    Row(
        Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text(
            if (rejoiningCamera) "Rejoining" else if (busy) "Stop" else "Cancel",
            style = chromeStyle(13f, FontWeight.SemiBold),
            color = if (busy && !rejoiningCamera) LiveDesign.accent else LiveDesign.muted,
            modifier =
                Modifier.glass(CircleShape)
                    .semantics {
                        contentDescription =
                            if (rejoiningCamera) {
                                "Rejoining saved camera Wi-Fi network"
                            } else if (busy) {
                                "Cancel active media delivery"
                            } else {
                                "Exit media selection"
                            }
                        if (rejoiningCamera) disabled() else role = Role.Button
                    }
                    .chromeClickable(enabled = !rejoiningCamera, onClick = onExit)
                    .padding(horizontal = 12.dp, vertical = 9.dp),
        )
        Text(
            "$selectedCount selected",
            modifier = Modifier.weight(1f),
            style = chromeStyle(20f, FontWeight.SemiBold),
            color = LiveDesign.text,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        // iOS selection-bar Delete capsule: destructive red, camera source only.
        if (deleteAvailable) {
            Text(
                "Delete",
                style = chromeStyle(14f, FontWeight.SemiBold),
                color = if (deleteEnabled) Color(0xFFFF5A54) else LiveDesign.faint,
                maxLines = 1,
                modifier =
                    Modifier.clip(CapsuleShape)
                        .border(1.dp, LiveDesign.hairline, CapsuleShape)
                        .semantics {
                            contentDescription =
                                if (deleteEnabled) {
                                    "Delete $selectedCount selected items from the camera card"
                                } else {
                                    "Delete selected media"
                                }
                            if (deleteEnabled) role = Role.Button else disabled()
                        }
                        .chromeClickable(enabled = deleteEnabled, onClick = onDelete)
                        .padding(horizontal = 14.dp, vertical = 8.dp),
            )
        }
        // iOS Label("Share", systemImage: "square.and.arrow.up") capsule.
        val shareLabel =
            when {
                rejoiningCamera -> "REJOINING…"
                upload != null ->
                    "UP ${upload.itemIndex}/${upload.itemCount} ${(upload.progress * 100).roundToInt()}%"
                frameioPreparationInProgress || shareInProgress -> "PREPARING…"
                else -> "Share"
            }
        Text(
            shareLabel,
            style = chromeStyle(14f, FontWeight.SemiBold),
            color = if (shareEnabled || busy) LiveDesign.accent else LiveDesign.faint,
            maxLines = 1,
            modifier =
                Modifier.clip(CapsuleShape)
                    .background(if (shareEnabled) LiveDesign.accentDim else Color.Transparent)
                    .border(1.dp, LiveDesign.hairline, CapsuleShape)
                    .semantics {
                        contentDescription =
                            if (shareEnabled) {
                                "Share $selectedCount selected items"
                            } else if (busy) {
                                "Media delivery in progress"
                            } else {
                                "Share selected media"
                            }
                        if (shareEnabled) role = Role.Button else disabled()
                    }
                    .chromeClickable(enabled = shareEnabled, onClick = onShare)
                    .padding(horizontal = 14.dp, vertical = 8.dp),
        )
    }
}

@Composable
private fun FrameioSelectionAction(
    readyCount: Int,
    enabled: Boolean,
    preparationInProgress: Boolean,
    upload: FrameioDeliveryState.Uploading?,
    rejoiningCamera: Boolean,
    onClick: () -> Unit,
) {
    val label =
        when {
            rejoiningCamera -> "REJOINING CAMERA"
            upload != null ->
                "UP ${upload.itemIndex}/${upload.itemCount} ${(upload.progress * 100).roundToInt()}%"
            preparationInProgress -> "PREPARING…"
            else -> "FRAME.IO $readyCount"
        }
    Text(
        label,
        style = chromeStyle(11f, FontWeight.Bold, mono = true),
        color =
            if (enabled || preparationInProgress || upload != null || rejoiningCamera) {
                LiveDesign.accent
            } else {
                LiveDesign.faint
            },
        maxLines = 1,
        modifier =
            Modifier.glass(CapsuleShape)
                .semantics {
                    when {
                        rejoiningCamera -> {
                            contentDescription = "Rejoining saved camera Wi-Fi network"
                            liveRegion = LiveRegionMode.Polite
                            disabled()
                        }
                        upload != null -> {
                            contentDescription =
                                "Uploading Frame.io clip ${upload.itemIndex} of ${upload.itemCount}: ${(upload.progress * 100).roundToInt()} percent"
                            progressBarRangeInfo =
                                ProgressBarRangeInfo(
                                    upload.progress.toFloat().coerceIn(0f, 1f),
                                    0f..1f,
                                )
                            liveRegion = LiveRegionMode.Polite
                            disabled()
                        }
                        preparationInProgress -> {
                            contentDescription = "Preparing selected media for Frame.io delivery"
                            progressBarRangeInfo = ProgressBarRangeInfo.Indeterminate
                            liveRegion = LiveRegionMode.Polite
                            disabled()
                        }
                        else -> {
                            contentDescription =
                                "Deliver $readyCount complete cached media items to Frame.io"
                            role = Role.Button
                            if (!enabled) disabled()
                        }
                    }
                }.chromeClickable(enabled) { onClick() }
                .padding(horizontal = 12.dp, vertical = 9.dp),
    )
}

@Composable
private fun DeliverySelectionAction(
    readyCount: Int,
    enabled: Boolean,
    shareInProgress: Boolean,
    frameioPreparationInProgress: Boolean,
    uploadInProgress: Boolean,
    onClick: () -> Unit,
) {
    Text(
        if (shareInProgress && !frameioPreparationInProgress && !uploadInProgress) {
            "WORKING…"
        } else {
            "DELIVER"
        },
        style = chromeStyle(11f, FontWeight.Bold, mono = true),
        color = if (enabled) LiveDesign.accent else LiveDesign.faint,
        maxLines = 1,
        modifier =
            Modifier.glass(CapsuleShape)
                .semantics {
                    contentDescription =
                        if (shareInProgress) {
                            "Media delivery in progress"
                        } else {
                            "Choose delivery for $readyCount complete cached media items"
                        }
                    if (enabled) role = Role.Button else disabled()
                }.chromeClickable(enabled) { onClick() }
                .padding(horizontal = 12.dp, vertical = 9.dp),
    )
}

/** Sort popup uses explicit menu choices rather than cycling a hidden state. */
/** iOS gallery REFRESH — an on-demand authoritative re-enumeration. */
@Composable
private fun RefreshControl(enabled: Boolean, onClick: () -> Unit) {
    val description = stringResource(R.string.media_refresh_cd)
    Row(
        Modifier.glass(CapsuleShape)
            .alpha(if (enabled) 1f else 0.5f)
            .semantics {
                contentDescription = description
                role = Role.Button
                if (!enabled) disabled()
            }
            .chromeClickable(enabled = enabled, onClick = onClick)
            .padding(horizontal = 10.dp, vertical = 9.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            stringResource(R.string.media_refresh),
            style = chromeStyle(10f, FontWeight.Bold, mono = true),
            color = LiveDesign.muted,
        )
    }
}

@Composable
internal fun MediaFilterDialog(
    filters: MediaLibraryFilters,
    options: MediaFilterOptions,
    storageIds: List<Long>,
    onFiltersChanged: (MediaLibraryFilters) -> Unit,
    onDismiss: () -> Unit,
) {
    val haptics = LocalOperatorHaptics.current
    androidx.compose.ui.window.Dialog(
        onDismissRequest = onDismiss,
        properties =
            androidx.compose.ui.window.DialogProperties(
                usePlatformDefaultWidth = false,
            ),
    ) {
        Box(
            Modifier
                .fillMaxSize()
                .background(Color.Black.copy(alpha = 0.45f))
                .chromeClickable(onClick = onDismiss),
            contentAlignment = Alignment.TopCenter,
        ) {
            Column(
                Modifier
                    .padding(top = 72.dp, start = 20.dp, end = 20.dp)
                    .widthIn(max = 400.dp)
                    .fillMaxWidth()
                    .glass(RoundedCornerShape(LiveDesign.CORNER_RADIUS_DP.dp))
                    .chromeClickable(onClick = {}) // absorb taps so backdrop doesn't dismiss mid-row
                    .padding(16.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Text(
                    "Filters",
                    style = chromeStyle(16f, FontWeight.SemiBold),
                    color = LiveDesign.text,
                )
                Column(
                    Modifier
                        .fillMaxWidth()
                        .weight(1f, fill = false)
                        .heightIn(max = 290.dp)
                        .verticalScroll(rememberScrollState()),
                    verticalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    MonitorMediaFilterForm(
                        formats = options.formats.map(MediaFormatFilter::title),
                        resolutions = options.resolutions.map(MediaResolutionFilter::title),
                        colors = emptyList(),
                        formatSelection = filters.formats.mapTo(linkedSetOf(), MediaFormatFilter::title),
                        resolutionSelection = filters.resolutions.mapTo(linkedSetOf(), MediaResolutionFilter::title),
                        colorSelection = emptySet(),
                        dateStartLabel = null,
                        dateEndLabel = null,
                        hasDates = false,
                        onToggleFormat = { id ->
                            options.formats.firstOrNull { it.title == id }?.let { value ->
                                haptics.selection()
                                onFiltersChanged(filters.copy(formats = filters.formats.toggled(value)))
                            }
                        },
                        onToggleResolution = { id ->
                            options.resolutions.firstOrNull { it.title == id }?.let { value ->
                                haptics.selection()
                                onFiltersChanged(filters.copy(resolutions = filters.resolutions.toggled(value)))
                            }
                        },
                        onToggleColor = {},
                        onPickStart = {},
                        onPickEnd = {},
                        onClear = { onFiltersChanged(MediaLibraryFilters()) },
                        photoSizes = options.photoSizes.takeIf { it.isNotEmpty() }?.let { sizes ->
                            MonitorMediaPhotoSizeChoices(
                                options = sizes.map { MonitorMediaFilterChoice(it.name, it.title) },
                                selectedIds = filters.photoSizes.mapTo(linkedSetOf()) { it.name },
                                onToggle = { id ->
                                    sizes.firstOrNull { it.name == id }?.let { value ->
                                        haptics.selection()
                                        onFiltersChanged(filters.copy(photoSizes = filters.photoSizes.toggled(value)))
                                    }
                                },
                            )
                        },
                        dateWindows = options.dateWindows.takeIf { it.isNotEmpty() }?.let { windows ->
                            MonitorMediaDateWindowChoices(
                                options = windows.map { MonitorMediaFilterChoice(it.name, it.title) },
                                selectedId = filters.dateWindow?.name,
                                onToggle = { id ->
                                    windows.firstOrNull { it.name == id }?.let { value ->
                                        haptics.selection()
                                        onFiltersChanged(
                                            filters.copy(dateWindow = value.takeUnless { filters.dateWindow == value }),
                                        )
                                    }
                                },
                            )
                        },
                        storage = storageIds.takeIf { it.isNotEmpty() }?.let { slots ->
                            MonitorMediaStorageChoices(
                                options = slots.mapIndexed { index, id ->
                                    MonitorMediaFilterChoice(id.toString(), "SLOT ${index + 1}")
                                },
                                selectedId = filters.storageId?.toString(),
                                onToggle = { id ->
                                    slots.firstOrNull { it.toString() == id }?.let { storageId ->
                                        haptics.selection()
                                        onFiltersChanged(filters.togglingStorageSlot(storageId))
                                    }
                                },
                            )
                        },
                        chipLayout = MonitorMediaFilterChipLayout.HORIZONTAL_SCROLL,
                        showsInlineClear = false,
                    )
                }
                Row(
                    Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                ) {
                    Text(
                        "Clear all",
                        style = chromeStyle(13f, FontWeight.Medium),
                        color =
                            if (filters.activeCount > 0) LiveDesign.accent else LiveDesign.faint,
                        modifier =
                            Modifier.chromeClickable(enabled = filters.activeCount > 0) {
                                onFiltersChanged(MediaLibraryFilters())
                            },
                    )
                    Text(
                        "Done",
                        style = chromeStyle(13f, FontWeight.SemiBold),
                        color = LiveDesign.accent,
                        modifier = Modifier.chromeClickable(onClick = onDismiss),
                    )
                }
            }
        }
    }
}


private fun <Value> Set<Value>.toggled(value: Value): Set<Value> =
    toMutableSet().apply { if (!add(value)) remove(value) }

/** Body chooses state, grid, or list without changing the data source. */
@Composable
private fun MediaLibraryBody(
    state: BrowseState,
    clips: List<MediaClipRecord>,
    source: MediaLibrarySource,
    layout: MediaLibraryLayout,
    thumbnailSize: MediaThumbnailSize,
    cameraID: String,
    cameraIDFor: (MediaClipRecord) -> String = { cameraID },
    clipIdentity: (MediaClipRecord) -> String = { it.libraryKey(cameraID) },
    /** A same-stem RAW rides behind this JPEG — the cell shows one item for the pair. */
    hasRawSibling: (MediaClipRecord) -> Boolean = { false },
    /** Frame count when a clip represents a burst series (null for an ordinary clip). */
    burstCountOf: (MediaClipRecord) -> Int? = { null },
    cameraConnected: Boolean,
    connectionOwner: Long?,
    cacheStore: MediaCacheStore,
    favorites: Set<String>,
    isSelecting: Boolean,
    selectedIDs: Set<String>,
    onOpen: (MediaClipRecord) -> Unit,
    onBeginSelection: (MediaClipRecord) -> Unit,
    /** Full selection set after a Photos-style range paint (not a delta). */
    onSweepSelection: (Set<String>) -> Unit,
    onToggleFavorite: (MediaClipRecord) -> Unit,
    onRetry: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Box(modifier) {
        when (state) {
            BrowseState.Loading -> ListingState(source)
            is BrowseState.Failed -> FailedState(state.message, onRetry)
            is BrowseState.Loaded ->
                if (clips.isEmpty() && state.isLoadingMore) {
                    ListingState(source)
                } else if (clips.isEmpty()) {
                    EmptyState(source)
                } else if (layout == MediaLibraryLayout.GRID) {
                    MediaClipGrid(
                        clips = clips,
                        thumbnailSize = thumbnailSize,
                        source = source,
                        cameraIDFor = cameraIDFor,
                        clipIdentity = clipIdentity,
                        hasRawSibling = hasRawSibling,
                        burstCountOf = burstCountOf,
                        cameraConnected = cameraConnected,
                        connectionOwner = connectionOwner,
                        cacheStore = cacheStore,
                        favorites = favorites,
                        isSelecting = isSelecting,
                        selectedIDs = selectedIDs,
                        onOpen = onOpen,
                        onBeginSelection = onBeginSelection,
                        onSweepSelection = onSweepSelection,
                        onToggleFavorite = onToggleFavorite,
                    )
                } else {
                    MediaClipList(
                        clips = clips,
                        source = source,
                        cameraIDFor = cameraIDFor,
                        clipIdentity = clipIdentity,
                        hasRawSibling = hasRawSibling,
                        burstCountOf = burstCountOf,
                        cameraConnected = cameraConnected,
                        connectionOwner = connectionOwner,
                        cacheStore = cacheStore,
                        favorites = favorites,
                        isSelecting = isSelecting,
                        selectedIDs = selectedIDs,
                        onOpen = onOpen,
                        onBeginSelection = onBeginSelection,
                        onSweepSelection = onSweepSelection,
                        onToggleFavorite = onToggleFavorite,
                    )
                }
        }
    }
}

/** Source-native hold/slop plus the actual 72dp band; common frames replace per-MOVE steps. */
@Composable
private fun rememberSelectionInputPolicy(): MonitorMediaSelectionConfiguration {
    val density = LocalDensity.current.density
    val nativeInput = LocalViewConfiguration.current
    return remember(nativeInput.longPressTimeoutMillis, nativeInput.touchSlop, density) {
        MonitorMediaSelectionConfiguration(
            holdMilliseconds = nativeInput.longPressTimeoutMillis,
            movementTolerance = nativeInput.touchSlop / density,
            allowsSelectionEntry = false,
            sweepsSideways = false,
            edgeBand = 72f,
            maximumEdgeSpeed = 620f,
            edgeCurve = MonitorMediaSelectionConfiguration.EdgeCurve.LINEAR,
            viewportEdgeLimitRatio = null,
        )
    }
}

/** Actual source cards consume the common mounted-hit and native input owner.
 * Browsing entry remains on the cells; a subsequent selecting touch arms a hold.
 * Native vertical scrolling and frame-clock edge scrolling share the real lazy state.
 */
@Composable
private fun MediaClipGrid(
    clips: List<MediaClipRecord>,
    thumbnailSize: MediaThumbnailSize,
    source: MediaLibrarySource,
    cameraIDFor: (MediaClipRecord) -> String,
    clipIdentity: (MediaClipRecord) -> String,
    hasRawSibling: (MediaClipRecord) -> Boolean,
    burstCountOf: (MediaClipRecord) -> Int? = { null },
    cameraConnected: Boolean,
    connectionOwner: Long?,
    cacheStore: MediaCacheStore,
    favorites: Set<String>,
    isSelecting: Boolean,
    selectedIDs: Set<String>,
    onOpen: (MediaClipRecord) -> Unit,
    onBeginSelection: (MediaClipRecord) -> Unit,
    onSweepSelection: (Set<String>) -> Unit,
    onToggleFavorite: (MediaClipRecord) -> Unit,
) {
    val gridState = rememberLazyGridState()
    val orderedIDs = remember(clips, clipIdentity) { clips.map(clipIdentity) }
    val view = LocalView.current
    val selectionInput = rememberSelectionInputPolicy()
    MonitorMediaSelectionHost(
        ids = orderedIDs,
        selecting = isSelecting,
        selected = selectedIDs,
        scroll = gridState,
        onOpen = { id -> clips.firstOrNull { clipIdentity(it) == id }?.let(onOpen) },
        onSelectionChange = { _, next -> onSweepSelection(next) },
        modifier = Modifier.fillMaxSize(),
        sessionKey = source to connectionOwner,
        configuration = selectionInput,
        onFeedback = { event ->
            view.performOperatorHaptic(
                if (event == MonitorMediaSelectionFeedback.BEGAN) HapticFeedbackConstants.LONG_PRESS
                else HapticFeedbackConstants.CLOCK_TICK,
            )
        },
    ) { registry ->
        LazyVerticalGrid(
            columns = GridCells.Adaptive(minSize = thumbnailSize.minimumCellWidthDp.dp),
            state = gridState,
            modifier = Modifier.fillMaxSize(),
            horizontalArrangement = Arrangement.spacedBy(16.dp),
            verticalArrangement = Arrangement.spacedBy(4.dp),
            contentPadding = PaddingValues(bottom = 28.dp),
        ) {
            items(clips, key = { clip -> clipIdentity(clip) }) { clip ->
                val identity = clipIdentity(clip)
                MonitorMediaHitTarget(registry = registry, id = identity) {
                    MediaClipArtworkAdapter(
                        clip = clip,
                        list = false,
                        source = source,
                        cameraID = cameraIDFor(clip),
                        hasRawSibling = hasRawSibling(clip),
                        burstCount = burstCountOf(clip),
                        cameraConnected = cameraConnected,
                        connectionOwner = connectionOwner,
                        cacheStore = cacheStore,
                        favorite = identity in favorites,
                        selected = identity in selectedIDs,
                        isSelecting = isSelecting,
                        onClick = { onOpen(clip) },
                        onLongPress = { onBeginSelection(clip) },
                        onToggleSelection = { onSweepSelection(MediaLibrarySelection.toggle(selectedIDs, identity)) },
                        onToggleFavorite = { onToggleFavorite(clip) },
                    )
                }
            }
        }
    }
}

/** List arrangement keeps the same source-authorized records and actions. */
@Composable
private fun MediaClipList(
    clips: List<MediaClipRecord>,
    source: MediaLibrarySource,
    cameraIDFor: (MediaClipRecord) -> String,
    clipIdentity: (MediaClipRecord) -> String,
    hasRawSibling: (MediaClipRecord) -> Boolean,
    burstCountOf: (MediaClipRecord) -> Int? = { null },
    cameraConnected: Boolean,
    connectionOwner: Long?,
    cacheStore: MediaCacheStore,
    favorites: Set<String>,
    isSelecting: Boolean,
    selectedIDs: Set<String>,
    onOpen: (MediaClipRecord) -> Unit,
    onBeginSelection: (MediaClipRecord) -> Unit,
    onSweepSelection: (Set<String>) -> Unit,
    onToggleFavorite: (MediaClipRecord) -> Unit,
) {
    val listState = rememberLazyListState()
    val orderedIDs = remember(clips, clipIdentity) { clips.map(clipIdentity) }
    val view = LocalView.current
    val selectionInput = rememberSelectionInputPolicy()
    MonitorMediaSelectionHost(
        ids = orderedIDs,
        selecting = isSelecting,
        selected = selectedIDs,
        scroll = listState,
        onOpen = { id -> clips.firstOrNull { clipIdentity(it) == id }?.let(onOpen) },
        onSelectionChange = { _, next -> onSweepSelection(next) },
        modifier = Modifier.fillMaxSize(),
        sessionKey = source to connectionOwner,
        configuration = selectionInput,
        onFeedback = { event ->
            view.performOperatorHaptic(
                if (event == MonitorMediaSelectionFeedback.BEGAN) HapticFeedbackConstants.LONG_PRESS
                else HapticFeedbackConstants.CLOCK_TICK,
            )
        },
    ) { registry ->
        LazyColumn(
            state = listState,
            modifier = Modifier.fillMaxSize(),
            verticalArrangement = Arrangement.spacedBy(8.dp),
            contentPadding = PaddingValues(bottom = 28.dp),
        ) {
            items(clips, key = { clip -> clipIdentity(clip) }) { clip ->
                val identity = clipIdentity(clip)
                MonitorMediaHitTarget(registry = registry, id = identity) {
                    MediaClipArtworkAdapter(
                        clip = clip,
                        list = true,
                        source = source,
                        cameraID = cameraIDFor(clip),
                        hasRawSibling = hasRawSibling(clip),
                        cameraConnected = cameraConnected,
                        connectionOwner = connectionOwner,
                        cacheStore = cacheStore,
                        favorite = identity in favorites,
                        selected = identity in selectedIDs,
                        isSelecting = isSelecting,
                        onClick = { onOpen(clip) },
                        onLongPress = { onBeginSelection(clip) },
                        onToggleSelection = { onSweepSelection(MediaLibrarySelection.toggle(selectedIDs, identity)) },
                        onToggleFavorite = { onToggleFavorite(clip) },
                    )
                }
            }
        }
    }
}
/** Source artwork and intents adapted to the exercised common grid/list owner. */
@Composable
private fun MediaClipArtworkAdapter(
    clip: MediaClipRecord, source: MediaLibrarySource, cameraID: String,
    hasRawSibling: Boolean, burstCount: Int? = null, cameraConnected: Boolean,
    connectionOwner: Long?, cacheStore: MediaCacheStore, favorite: Boolean, selected: Boolean,
    isSelecting: Boolean, list: Boolean, onClick: () -> Unit, onLongPress: () -> Unit,
    onToggleSelection: () -> Unit, onToggleFavorite: () -> Unit, modifier: Modifier = Modifier,
) {
    MonitorClipCard(
        clip = mediaClipCellPresentation(
            clip, cameraID, favorite, hasRawSibling, burstCount, list, isSelecting, selected),
        list = list, selecting = isSelecting, selected = selected,
        onOpen = onClick, onSelect = if (isSelecting) onToggleSelection else onLongPress,
        onFavorite = if (isSelecting) null else onToggleFavorite,
        modifier = modifier, clicks = !isSelecting,
    ) {
        ClipArtwork(
            clip = clip, source = source, cameraID = cameraID, cameraConnected = cameraConnected,
            connectionOwner = connectionOwner, cacheStore = cacheStore, modifier = Modifier.fillMaxSize(),
        )
    }
}

/**
 * iPhone-Photos-style burst scrubber (iOS `BurstFilmstrip`): dragging scrolls the strip with the
 * centered thumb highlighting live; the displayed frame commits only when the scroll SETTLES, not
 * on every intermediate frame. The viewer re-streams each frame, so committing on every thumb that
 * crossed centre was the lag + reload storm (and the programmatic-scroll rubber-band). Tapping a
 * thumb jumps to it immediately; external selection changes (deletion advance) re-center the strip.
 */
@Composable
private fun BurstFilmstrip(
    members: List<MediaClipRecord>,
    selectedKey: String,
    keyOf: (MediaClipRecord) -> String,
    onSelect: (String) -> Unit,
    thumb: @Composable (MediaClipRecord, Modifier) -> Unit,
) {
    // Widest a thumb gets (selected). Half of it is subtracted from the side inset so the
    // first/last frame can sit dead-centre; the inset math and the item width must stay in sync.
    val maxThumbWidth = 46.dp
    val listState = rememberLazyListState()
    val currentSelected by rememberUpdatedState(selectedKey)
    val currentOnSelect by rememberUpdatedState(onSelect)
    // The thumb under the centre line — drives the live highlight only, NOT the heavy viewer
    // (which commits when the scrub settles). Reset when the series changes.
    var centeredKey by remember(members) { mutableStateOf(selectedKey) }

    fun centeredKeyNow(): String? {
        val info = listState.layoutInfo
        val center = (info.viewportStartOffset + info.viewportEndOffset) / 2
        val index = info.visibleItemsInfo.minByOrNull { abs(it.offset + it.size / 2 - center) }?.index
        return index?.let { members.getOrNull(it) }?.let(keyOf)
    }

    // Cheap live highlight: track the centred thumb continuously (no viewer reload).
    LaunchedEffect(listState, members) {
        snapshotFlow { centeredKeyNow() }.collect { key -> if (key != null) centeredKey = key }
    }
    // Commit the displayed frame only after the scrub SETTLES (idle after a real drag/fling).
    // Reading layoutInfo at settle time picks the actually-rested thumb, so a programmatic
    // re-center (which rests on the already-selected frame) never commits back — no rubber-band.
    LaunchedEffect(listState, members) {
        var wasScrolling = false
        snapshotFlow { listState.isScrollInProgress }.collect { scrolling ->
            if (wasScrolling && !scrolling) {
                val key = centeredKeyNow()
                if (key != null && key != currentSelected) currentOnSelect(key)
            }
            wasScrolling = scrolling
        }
    }
    // External selection (tap, deletion advance) re-centers the strip; a settle-commit already
    // left centeredKey == selectedKey, so this no-ops for scrubs (iOS `guard scrolledID != …`).
    LaunchedEffect(selectedKey, members) {
        if (centeredKey == selectedKey) return@LaunchedEffect
        centeredKey = selectedKey
        val index = members.indexOfFirst { keyOf(it) == selectedKey }
        if (index >= 0 && !listState.isScrollInProgress) listState.animateScrollToItem(index)
    }
    BoxWithConstraints(Modifier.fillMaxWidth().height(56.dp)) {
        // Half the viewport (minus half a max-width thumb) so ANY thumb — first and last
        // included — can reach the centre anchor (was a fixed 130, unreachable on a wide
        // landscape screen). With this inset, start-aligned snapping lands a thumb centred.
        val sideInset = ((maxWidth - maxThumbWidth) / 2f).coerceAtLeast(0.dp)
        LazyRow(
            state = listState,
            horizontalArrangement = Arrangement.spacedBy(4.dp),
            verticalAlignment = Alignment.CenterVertically,
            contentPadding = PaddingValues(horizontal = sideInset),
            // .viewAligned snapping: the scrub lands cleanly on a frame instead of drifting.
            flingBehavior = rememberSnapFlingBehavior(listState),
            modifier = Modifier.fillMaxWidth(),
        ) {
            items(members, key = { keyOf(it) }) { member ->
                val isSelected = keyOf(member) == centeredKey
                Box(
                    Modifier
                        .width(if (isSelected) maxThumbWidth else 30.dp)
                        .height(44.dp)
                        .clip(RoundedCornerShape(4.dp))
                        .border(
                            if (isSelected) 1.5.dp else 0.dp,
                            if (isSelected) LiveDesign.accent else Color.Transparent,
                            RoundedCornerShape(4.dp),
                        )
                        .chromeClickable { onSelect(keyOf(member)) },
                ) {
                    thumb(member, Modifier.fillMaxSize())
                }
            }
        }
    }
}

/** Thumbnail policy: camera thumbnails when connected, final cached stills only otherwise. */
@Composable
private fun ClipArtwork(
    clip: MediaClipRecord,
    source: MediaLibrarySource,
    cameraID: String,
    cameraConnected: Boolean,
    connectionOwner: Long?,
    cacheStore: MediaCacheStore,
    modifier: Modifier = Modifier,
) {
    var thumbnail by remember(clip.libraryKey(cameraID), source) { mutableStateOf<ImageBitmap?>(null) }
    LaunchedEffect(clip.libraryKey(cameraID), source, cameraConnected) {
        thumbnail =
            withContext(Dispatchers.IO) {
                val cameraThumbnail =
                    if (
                        source == MediaLibrarySource.CAMERA &&
                            cameraConnected &&
                            SwiftCore.isAvailable &&
                            connectionOwner != null
                    ) {
                        NikonNative.sessionThumbnail(connectionOwner, clip.handle.toInt())?.let { jpeg ->
                            // The body's thumb bytes may be EXIF-stripped — fall back to the
                            // orientation this session learned from the object's full file.
                            val key = clip.libraryKey(cameraID)
                            val orientation =
                                MediaExifOrientation.fromBytes(jpeg)
                                    ?.also { MediaExifOrientation.learn(key, it) }
                                    ?: MediaExifOrientation.learned(key)
                            BitmapFactory.decodeByteArray(jpeg, 0, jpeg.size)
                                ?.upright(orientation)
                                ?.asImageBitmap()
                        }
                    } else {
                        null
                    }
                cameraThumbnail ?: cachedStillThumbnail(cacheStore, cameraID, clip)
            }
    }
    val image = thumbnail
    if (image != null) {
        Image(
            bitmap = image,
            contentDescription = null,
            modifier = modifier,
            contentScale = ContentScale.Crop,
        )
    } else {
        FilmGlyph(LiveDesign.faint, Modifier.size(34.dp, 30.dp))
    }
}

/** Decodes a small still thumbnail only from the validated final cache path. */
private fun cachedStillThumbnail(
    cacheStore: MediaCacheStore,
    cameraID: String,
    clip: MediaClipRecord,
): ImageBitmap? {
    if (clip.contentKind != MediaContentKind.STILL_PHOTO) return null
    val entry =
        runCatching {
            cacheStore.completedEntryOrNull(
                cameraID,
                MediaCacheObjectIdentity(clip),
                clip.sizeBytes,
            )
        }.getOrNull() ?: return null
    if (!java.nio.file.Files.isRegularFile(entry.finalPath, LinkOption.NOFOLLOW_LINKS)) return null
    return try {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(entry.finalPath.toString(), bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
        var sampleSize = 1
        while (bounds.outWidth / sampleSize > 640 || bounds.outHeight / sampleSize > 640) {
            sampleSize *= 2
        }
        // The full file carries the orientation header — learn it for the object so the
        // connected grid's (possibly EXIF-stripped) camera thumbs rotate too.
        val orientation =
            MediaExifOrientation.fromFile(entry.finalPath)?.also {
                MediaExifOrientation.learn(clip.libraryKey(cameraID), it)
            }
        BitmapFactory.decodeFile(
            entry.finalPath.toString(),
            BitmapFactory.Options().apply {
                inSampleSize = sampleSize
                inPreferredConfig = Bitmap.Config.ARGB_8888
            },
        )?.upright(orientation)?.asImageBitmap()
    } catch (_: OutOfMemoryError) {
        null
    } catch (_: RuntimeException) {
        null
    }
}

/** iOS-aligned loading state, specialized for its selected safe source. */
@Composable
private fun ListingState(source: MediaLibrarySource) {
    CenteredState {
        CircularProgressIndicator(color = LiveDesign.muted)
        Text(
            if (source == MediaLibrarySource.CAMERA) "Listing clips on camera…" else "Opening local library…",
            style = chromeStyle(15f, FontWeight.Medium),
            color = LiveDesign.muted,
        )
        Text(
            if (source == MediaLibrarySource.CAMERA) {
                "Querying card storage…"
            } else {
                "Checking persisted complete cache entries…"
            },
            style = chromeStyle(12f, FontWeight.Normal),
            color = LiveDesign.faint,
        )
    }
}

/** Empty local media never means arbitrary files were searched. */
@Composable
private fun EmptyState(source: MediaLibrarySource) {
    CenteredState {
        FilmGlyph(LiveDesign.faint, Modifier.size(44.dp, 40.dp))
        Text(
            if (source == MediaLibrarySource.CAMERA) "No clips yet" else "No complete cached media",
            style = chromeStyle(15f, FontWeight.Medium),
            color = LiveDesign.muted,
        )
        Text(
            if (source == MediaLibrarySource.CAMERA) {
                "Clips appear here as they\u2019re discovered on the card."
            } else {
                "Complete camera media you have opened appears here safely."
            },
            style = chromeStyle(12f, FontWeight.Normal),
            color = LiveDesign.faint,
        )
    }
}

/** Listing failure (including no camera connection), with an explicit retry action. */
@Composable
private fun FailedState(message: String, onRetry: () -> Unit) {
    CenteredState {
        Text(
            "Couldn't list media",
            style = chromeStyle(15f, FontWeight.Medium),
            color = LiveDesign.muted,
        )
        Text(
            message,
            style = chromeStyle(12f, FontWeight.Normal),
            color = LiveDesign.faint,
        )
        Text(
            "Retry",
            style = chromeStyle(13f, FontWeight.SemiBold),
            color = LiveDesign.accent,
            modifier =
                Modifier.glass(CircleShape)
                    .chromeClickable(onRetry)
                    .padding(horizontal = 16.dp, vertical = 8.dp),
        )
    }
}

/** Shared centered-column scaffold for listing, empty, and failure states. */
@Composable
private fun CenteredState(content: @Composable () -> Unit) {
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            content()
        }
    }
}

/** A brief in-app result message that remains above the safe bottom edge. */
@Composable
private fun MediaStatusMessage(message: String, modifier: Modifier = Modifier) {
    Text(
        message,
        modifier = modifier.glass(RoundedCornerShape(LiveDesign.CORNER_RADIUS_DP.dp)).padding(12.dp),
        style = chromeStyle(12f, FontWeight.Medium),
        color = LiveDesign.text,
        maxLines = 3,
        overflow = TextOverflow.Ellipsis,
    )
}

/** Round glass close button with an X glyph (iOS `CloseButton`, 37pt). */
@Composable
private fun CloseCircleButton(modifier: Modifier = Modifier, onClick: () -> Unit) {
    Box(
        modifier.size(37.dp).glass(CircleShape).chromeClickable(onClick),
        contentAlignment = Alignment.Center,
    ) {
        Canvas(Modifier.size(11.dp)) {
            val stroke = 1.8.dp.toPx()
            drawLine(
                LiveDesign.text,
                Offset(0f, 0f),
                Offset(size.width, size.height),
                stroke,
                StrokeCap.Round,
            )
            drawLine(
                LiveDesign.text,
                Offset(size.width, 0f),
                Offset(0f, size.height),
                stroke,
                StrokeCap.Round,
            )
        }
    }
}

private fun MediaLibraryCategory.titleForHeader(): String =
    when (this) {
        MediaLibraryCategory.ALL -> "All clips"
        MediaLibraryCategory.VIDEOS -> "Videos"
        MediaLibraryCategory.PHOTOS -> "Photos"
        MediaLibraryCategory.FAVORITES -> "Favorites"
    }

private fun itemCountLabel(state: BrowseState, displayedCount: Int): String =
    when (state) {
        BrowseState.Loading -> "Scanning…"
        is BrowseState.Failed -> "—"
        is BrowseState.Loaded ->
            if (state.isLoadingMore) {
                "Listing… ${state.clips.size} found"
            } else {
                "$displayedCount item${if (displayedCount == 1) "" else "s"}"
            }
    }

private val CapsuleShape: RoundedCornerShape
    get() = RoundedCornerShape(percent = 50)

private fun Modifier.badgeBackground(): Modifier =
    background(Color.Black.copy(alpha = 0.58f), RoundedCornerShape(4.dp))

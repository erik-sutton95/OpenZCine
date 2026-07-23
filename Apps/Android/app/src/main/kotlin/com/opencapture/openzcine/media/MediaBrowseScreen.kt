package com.opencapture.openzcine.media

import com.opencapture.openzcine.performOperatorHaptic

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.combinedClickable
import android.view.HapticFeedbackConstants
import android.view.View
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.scrollBy
import androidx.compose.foundation.gestures.waitForUpOrCancellation
import androidx.compose.foundation.lazy.grid.rememberLazyGridState
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.platform.LocalView
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
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
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInRoot
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
import com.opencapture.openzcine.core.CameraStorageSlotStatus
import com.opencapture.openzcine.settings.OperatorSettings
import java.nio.file.Files
import java.nio.file.LinkOption
import kotlin.math.roundToInt
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

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
    onClose: () -> Unit,
) {
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
    var deleteConfirmTargets by remember { mutableStateOf<List<MediaClipRecord>?>(null) }
    var playingClip by remember { mutableStateOf<MediaClipRecord?>(null) }
    var viewingPhoto by remember { mutableStateOf<MediaClipRecord?>(null) }
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
        offlineCameraIDs,
        librarySource,
        effectiveCameraConnected,
        reloadKey,
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
                            val clips =
                                loadCameraMediaPages(
                                    pageSize = MEDIA_BROWSE_PAGE_SIZE,
                                    onStart = { slots -> browseStorageSlots = slots },
                                    onPage = { snapshot ->
                                        listingCheckpoint.applyPage(
                                            snapshot.addedClips,
                                            snapshot.removedObjects,
                                        )
                                        state =
                                            BrowseState.Loaded(
                                                clips = snapshot.clips,
                                                isLoadingMore = snapshot.hasMore,
                                            )
                                    },
                                )
                            withContext(Dispatchers.IO) { listingCheckpoint.commit() }
                            BrowseState.Loaded(clips)
                        } catch (error: CancellationException) {
                            throw error
                        } catch (_: MediaBrowsePagingException) {
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
        withContext(Dispatchers.IO) {
            targets.forEach { clip ->
                // Protected objects are refused by the body and stay listed;
                // their caches stay too so the row remains fully backed.
                if (!SwiftCore.isAvailable || !SwiftCore.sessionDeleteObject(clip.handle.toInt())) {
                    return@forEach
                }
                val owner = ownerCameraID(clip)
                runCatching {
                    cacheStore.purgeEntry(owner, MediaCacheObjectIdentity(clip))
                }
                libraryIndex.purgeClip(owner, clip)
            }
        }
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
        pendingDeletion = cameraDeletionTargets(catalog, selection)
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
    val displayedClips =
        MediaLibraryFiltering.displayed(
            clips = loadedClips,
            category = options.category,
            favoriteIDs = favorites,
            cameraID = cameraID,
            sortOrder = options.sortOrder,
            filters = filters,
            libraryKey = ::clipKey,
        )
    val selectedClips =
        displayedClips.filter { clip -> clipKey(clip) in selectedIDs }
    val visibleIDs = displayedClips.map { clip -> clipKey(clip) }.toSet()

    LaunchedEffect(visibleIDs) {
        val retained = MediaLibrarySelection.retainVisible(selectedIDs, visibleIDs)
        if (retained != selectedIDs) selectedIDs = retained
        if (retained.isEmpty()) isSelecting = false
    }

    LaunchedEffect(cameraID, offlineClipOwners, selectedClips) {
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
    val readyGalleryCount =
        selectedClips.count { clip ->
            (
                clip.contentKind == MediaContentKind.PLAYABLE_PROXY ||
                    clip.contentKind == MediaContentKind.STILL_PHOTO
            ) &&
                clipKey(clip) in readySelectionIDs
        }
    val selectedLutLabel =
        when (selectedLut) {
            is FeedLutSelection.BuiltIn -> selectedLut.value.label
            is FeedLutSelection.Stored -> lutLibrary.displayName(selectedLut.value)
        }

    fun toggleFavorite(clip: MediaClipRecord) {
        val owner = ownerCameraID(clip)
        val updated = libraryIndex.toggleFavorite(owner, clip)
        // Re-merge favorites across offline buckets so the star stays accurate.
        favorites =
            if (offlineCameraIDs.isEmpty()) {
                updated
            } else {
                offlineCameraIDs.flatMap { id -> libraryIndex.favoriteIDs(id) }.toSet()
            }
    }

    fun open(clip: MediaClipRecord) {
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

    fun toggleSelection(clip: MediaClipRecord) {
        if (shareInProgress) return
        selectedIDs = MediaLibrarySelection.toggle(selectedIDs, clipKey(clip))
    }

    fun beginBatchShare(configuration: MediaDeliveryConfiguration) {
        if (shareInProgress || selectedClips.isEmpty()) return
        val selectionSnapshot = selectedClips
        val coordinator = mediaDeliveryCoordinator
        if (coordinator != null) {
            scope.launch {
                val items =
                    withContext(Dispatchers.IO) {
                        selectionSnapshot.mapNotNull { clip ->
                            val owner = ownerCameraID(clip)
                            val entry =
                                runCatching {
                                    cacheStore.completedEntryOrNull(
                                        owner,
                                        MediaCacheObjectIdentity(clip),
                                        clip.sizeBytes,
                                    )
                                }.getOrNull() ?: return@mapNotNull null
                            MediaDeliveryWorkItem(owner, clip, entry)
                        }
                    }
                if (items.isEmpty()) {
                    shareMessage = "Only complete cached media can be shared."
                    return@launch
                }
                coordinator.beginNativeShare(items, configuration) { published, metadata ->
                    context.startActivity(
                        AndroidMediaShareIntent.chooserIntent(context, published, metadata),
                    )
                    exitSelection()
                }
            }
            return
        }
        val selectionSnapshotLegacy = selectedClips
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
        val selectionSnapshot = selectedClips
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
            scope.launch {
                val items =
                    withContext(Dispatchers.IO) {
                        savableSelection.mapNotNull { clip ->
                            val owner = ownerCameraID(clip)
                            val entry =
                                runCatching {
                                    cacheStore.completedEntryOrNull(
                                        owner,
                                        MediaCacheObjectIdentity(clip),
                                        clip.sizeBytes,
                                    )
                                }.getOrNull() ?: return@mapNotNull null
                            MediaDeliveryWorkItem(owner, clip, entry)
                        }
                    }
                if (items.isEmpty()) {
                    shareMessage = "No complete cached media is ready."
                    return@launch
                }
                coordinator.beginSaveToPhotos(items, configuration)
                exitSelection()
            }
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
        val selectionSnapshot = selectedClips
        frameioDeliveryPresented = false
        shareInProgress = true
        frameioPreparationInProgress = true
        shareMessage = null
        shareJob =
            scope.launch {
                val stageContext = coroutineContext
                var skippedBeforeUpload: Int? = null
                var completedWithoutFailures = false
                var cancelled = false
                try {
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
        if (effectiveCameraConnected) {
            withContext(Dispatchers.IO) { SwiftCore.sessionExitMediaMode() }
        }
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

            // iOS MediaBrowserView: no Camera/On-device source chrome. Landscape =
            // 172pt category sidebar with grid/list density controls at the
            // bottom; portrait = category strip + bottom density band.
            val showsGridControls =
                !isSelecting && !shareInProgress && !frameioPreparationInProgress
            if (portrait) {
                Column(contentModifier, verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    MediaCategoryStrip(
                        selected = options.category,
                        modifier = Modifier.padding(start = 45.dp),
                        onSelect = { category -> updateOptions(options.copy(category = category)) },
                    )
                    if (visibleStorageSlots.isNotEmpty() && effectiveCameraConnected) {
                        MediaStorageSlotSelector(
                            slots = visibleStorageSlots,
                            selectedStorageId = filters.storageId,
                            horizontal = true,
                            onSelect = ::toggleStorageSlot,
                            modifier = Modifier.padding(start = 45.dp),
                        )
                    }
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
                        deleteAvailable =
                            librarySource == MediaLibrarySource.CAMERA &&
                                effectiveCameraConnected,
                        onExitSelection = ::cancelActiveShareOrExitSelection,
                        onDelete = { deleteConfirmTargets = selectedClips },
                        onShare = {
                            // Unified Share sheet (native + Frame.io), like iOS.
                            presentNativeDelivery()
                        },
                        onSortChange = { sort -> updateOptions(options.copy(sortOrder = sort)) },
                        onShowFilters = { filterDialogPresented = true },
                    )
                    Box(Modifier.weight(1f).fillMaxWidth()) {
                        MediaLibraryBody(
                            state = state,
                            clips = displayedClips,
                            source = librarySource,
                            layout = options.layout,
                            thumbnailSize = options.thumbnailSize,
                            cameraID = cameraID,
                            cameraIDFor = ::ownerCameraID,
                            clipIdentity = ::clipKey,
                            cameraConnected = cameraConnected,
                            cacheStore = cacheStore,
                            favorites = favorites,
                            isSelecting = isSelecting,
                            selectedIDs = selectedIDs,
                            onOpen = ::open,
                            onBeginSelection = { identity ->
                                if (!shareInProgress) beginSelection(identity)
                            },
                            onToggleSelection = { identity ->
                                if (!shareInProgress) toggleSelection(identity)
                            },
                            onSweepSelection = { next ->
                                if (!shareInProgress) selectedIDs = next
                            },
                            onToggleFavorite = ::toggleFavorite,
                            onRetry = { reloadKey += 1 },
                            modifier = Modifier.fillMaxSize(),
                        )
                        if (showsGridControls) {
                            // iOS portraitGridControlsBand: fade + layout/density capsule.
                            PortraitMediaGridControlsBand(
                                layout = options.layout,
                                thumbnailSize = options.thumbnailSize,
                                onLayoutChange = { layout ->
                                    updateOptions(options.copy(layout = layout))
                                },
                                onThumbnailSizeChange = { size ->
                                    updateOptions(options.copy(thumbnailSize = size))
                                },
                                modifier = Modifier.align(Alignment.BottomCenter),
                            )
                        }
                    }
                }
            } else {
                Row(contentModifier, horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                    MediaLibraryRail(
                        category = options.category,
                        storageSlots =
                            if (effectiveCameraConnected) visibleStorageSlots else emptyList(),
                        selectedStorageId = filters.storageId,
                        onCategoryChange = { category ->
                            updateOptions(options.copy(category = category))
                        },
                        onStorageSelect = ::toggleStorageSlot,
                        showsGridControls = showsGridControls,
                        layout = options.layout,
                        thumbnailSize = options.thumbnailSize,
                        onLayoutChange = { layout -> updateOptions(options.copy(layout = layout)) },
                        onThumbnailSizeChange = { size ->
                            updateOptions(options.copy(thumbnailSize = size))
                        },
                        modifier = Modifier.width(172.dp).fillMaxHeight(),
                    )
                    Column(
                        Modifier.weight(1f),
                        verticalArrangement = Arrangement.spacedBy(6.dp),
                    ) {
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
                            deleteAvailable =
                                librarySource == MediaLibrarySource.CAMERA &&
                                    effectiveCameraConnected,
                            onExitSelection = ::cancelActiveShareOrExitSelection,
                            onDelete = { deleteConfirmTargets = selectedClips },
                            onShare = { presentNativeDelivery() },
                            onSortChange = { sort -> updateOptions(options.copy(sortOrder = sort)) },
                            onShowFilters = { filterDialogPresented = true },
                        )
                        MediaLibraryBody(
                            state = state,
                            clips = displayedClips,
                            source = librarySource,
                            layout = options.layout,
                            thumbnailSize = options.thumbnailSize,
                            cameraID = cameraID,
                            cameraIDFor = ::ownerCameraID,
                            clipIdentity = ::clipKey,
                            cameraConnected = cameraConnected,
                            cacheStore = cacheStore,
                            favorites = favorites,
                            isSelecting = isSelecting,
                            selectedIDs = selectedIDs,
                            onOpen = ::open,
                            onBeginSelection = { identity ->
                                if (!shareInProgress) beginSelection(identity)
                            },
                            onToggleSelection = { identity ->
                                if (!shareInProgress) toggleSelection(identity)
                            },
                            onSweepSelection = { next ->
                                if (!shareInProgress) selectedIDs = next
                            },
                            onToggleFavorite = ::toggleFavorite,
                            onRetry = { reloadKey += 1 },
                            modifier = Modifier.weight(1f),
                        )
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
                storageIds = visibleStorageSlots.map(MediaStorageSlotPresentation::storageId),
                onFiltersChanged = ::updateFilters,
                onDismiss = { filterDialogPresented = false },
            )
        }

        deleteConfirmTargets?.let { targets ->
            MediaDeleteConfirmDialog(
                message =
                    deleteConfirmationMessage(
                        targets,
                        hasRawPair =
                            targets.size == 1 &&
                                rawSibling(loadedClips, targets.single()) != null,
                    ),
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
                cameraID = owner,
                cameraTransferAvailable = cameraConnected,
                hasRawSibling = rawSibling(loadedClips, clip) != null,
                deleteAvailable =
                    librarySource == MediaLibrarySource.CAMERA && effectiveCameraConnected,
                onDelete = { requestDeletion(listOf(clip)) },
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
    }
}

/** Horizontal category strip that keeps labels readable on portrait phones. */
@Composable
private fun MediaCategoryStrip(
    selected: MediaLibraryCategory,
    onSelect: (MediaLibraryCategory) -> Unit,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier
            .fillMaxWidth()
            .horizontalScroll(rememberScrollState())
            .glass(RoundedCornerShape(LiveDesign.CORNER_RADIUS_DP.dp))
            .padding(4.dp),
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        MediaLibraryCategory.entries.forEach { category ->
            MediaCategoryButton(
                category = category,
                active = category == selected,
                onClick = { onSelect(category) },
                compact = true,
            )
        }
    }
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
    Column(
        modifier.padding(4.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        Column(
            Modifier
                .fillMaxWidth()
                .glass(RoundedCornerShape(LiveDesign.CORNER_RADIUS_DP.dp))
                .padding(4.dp),
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            MediaLibraryCategory.entries.forEach { candidate ->
                MediaCategoryButton(
                    category = candidate,
                    active = candidate == category,
                    onClick = { onCategoryChange(candidate) },
                )
            }
        }
        if (storageSlots.isNotEmpty()) {
            MediaStorageSlotSelector(
                slots = storageSlots,
                selectedStorageId = selectedStorageId,
                horizontal = false,
                onSelect = onStorageSelect,
            )
        }
        Spacer(Modifier.weight(1f))
        if (showsGridControls) {
            MediaGridLayoutControls(
                layout = layout,
                thumbnailSize = thumbnailSize,
                onLayoutChange = onLayoutChange,
                onThumbnailSizeChange = onThumbnailSizeChange,
                modifier = Modifier.fillMaxWidth(),
            )
        }
    }
}

/**
 * iOS sidebarGridControls / portraitGridControlsBand capsule: layout toggle
 * (grid↔list) + S/M/L square density icons (not text labels in the header).
 */
@Composable
private fun MediaGridLayoutControls(
    layout: MediaLibraryLayout,
    thumbnailSize: MediaThumbnailSize,
    onLayoutChange: (MediaLibraryLayout) -> Unit,
    onThumbnailSizeChange: (MediaThumbnailSize) -> Unit,
    modifier: Modifier = Modifier,
) {
    val buttonSize = 37.dp
    val corner = LiveDesign.CORNER_RADIUS_DP.dp
    Row(
        modifier
            .glass(CapsuleShape)
            .padding(horizontal = 6.dp, vertical = 6.dp)
            .semantics { contentDescription = "Media layout and thumbnail size" },
        horizontalArrangement = Arrangement.spacedBy(4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            Modifier
                .size(buttonSize)
                .clip(RoundedCornerShape(corner))
                .background(LiveDesign.glassBright)
                .semantics {
                    contentDescription = layout.accessibilityLabel
                    role = Role.Button
                }
                .chromeClickable {
                    onLayoutChange(
                        if (layout == MediaLibraryLayout.GRID) {
                            MediaLibraryLayout.LIST
                        } else {
                            MediaLibraryLayout.GRID
                        },
                    )
                },
            contentAlignment = Alignment.Center,
        ) {
            // iOS: list.bullet when grid active (tap → list), grid when list.
            Text(
                if (layout == MediaLibraryLayout.GRID) "☰" else "⊞",
                style = chromeStyle(14f, FontWeight.SemiBold),
                color = LiveDesign.muted,
            )
        }
        MediaThumbnailSize.entries.forEach { size ->
            val active = size == thumbnailSize
            val iconSp =
                when (size) {
                    MediaThumbnailSize.SMALL -> 9.sp
                    MediaThumbnailSize.MEDIUM -> 12.sp
                    MediaThumbnailSize.LARGE -> 15.sp
                }
            Box(
                Modifier
                    .size(buttonSize)
                    .clip(RoundedCornerShape(corner))
                    .background(if (active) LiveDesign.accentDim else Color.Transparent)
                    .semantics {
                        contentDescription = size.accessibilityLabel
                        role = Role.RadioButton
                    }
                    .chromeClickable { onThumbnailSizeChange(size) },
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    "■",
                    fontSize = iconSp,
                    fontWeight = FontWeight.Bold,
                    color = if (active) LiveDesign.accent else LiveDesign.muted,
                )
            }
        }
    }
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

/** One accessible category tab. */
@Composable
private fun MediaCategoryButton(
    category: MediaLibraryCategory,
    active: Boolean,
    onClick: () -> Unit,
    compact: Boolean = false,
) {
    Text(
        category.title,
        style = chromeStyle(12f, if (active) FontWeight.SemiBold else FontWeight.Medium),
        color = if (active) LiveDesign.accent else LiveDesign.muted,
        modifier =
            Modifier.then(if (compact) Modifier else Modifier.fillMaxWidth())
                .clip(RoundedCornerShape(8.dp))
                .background(if (active) LiveDesign.accentDim else Color.Transparent)
                .semantics {
                    contentDescription = "Show ${category.title} media"
                    role = Role.Tab
                }.chromeClickable(onClick)
                .padding(horizontal = 12.dp, vertical = 9.dp),
    )
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

    Row(
        Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Box(Modifier.weight(1f)) {
            MediaHeaderIdentity(state, category, displayedCount)
        }
        FilterControl(activeCount = activeFilterCount, onClick = onShowFilters)
        SortControl(sortOrder = sortOrder, onSelect = onSortChange)
    }
}

@Composable
private fun MediaHeaderIdentity(
    state: BrowseState,
    category: MediaLibraryCategory,
    displayedCount: Int,
) {
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(
            "MULTIMEDIA",
            style = chromeStyle(10f, FontWeight.Bold, mono = true).copy(letterSpacing = 0.8.sp),
            color = LiveDesign.muted,
        )
        Row(
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                category.titleForHeader(),
                style = chromeStyle(26f, FontWeight.SemiBold),
                color = LiveDesign.text,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text("·", style = chromeStyle(18f, FontWeight.Medium), color = LiveDesign.faint)
            Text(
                itemCountLabel(state, displayedCount),
                style = chromeStyle(14f, FontWeight.Medium),
                color = LiveDesign.muted,
                maxLines = 1,
            )
        }
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
@Composable
private fun SortControl(sortOrder: MediaLibrarySortOrder, onSelect: (MediaLibrarySortOrder) -> Unit) {
    // iOS: a blind-cycle "SORT" pill — tapping advances to the next order.
    val orders = MediaLibrarySortOrder.entries
    val next = orders[(orders.indexOf(sortOrder) + 1) % orders.size]
    Text(
        "SORT",
        style = chromeStyle(10f, FontWeight.Bold, mono = true),
        color = LiveDesign.muted,
        modifier =
            Modifier.glass(CapsuleShape)
                .semantics { contentDescription = "Sort media: ${sortOrder.title}" }
                .chromeClickable { onSelect(next) }
                .padding(horizontal = 10.dp, vertical = 9.dp),
    )
}

/** Grid/list switch retained across launches in [MediaLibraryIndex]. */
@Composable
private fun LayoutControl(layout: MediaLibraryLayout, onToggle: (MediaLibraryLayout) -> Unit) {
    val next = if (layout == MediaLibraryLayout.GRID) MediaLibraryLayout.LIST else MediaLibraryLayout.GRID
    Box(
        modifier =
            Modifier.size(36.dp)
                .glass(CircleShape)
                .semantics {
                    contentDescription = layout.accessibilityLabel
                    role = Role.Button
                }.chromeClickable { onToggle(next) },
        contentAlignment = Alignment.Center,
    ) {
        Text(
            if (layout == MediaLibraryLayout.GRID) "☷" else "▦",
            style = chromeStyle(18f, FontWeight.Medium),
            color = LiveDesign.muted,
        )
    }
}

/** Opens the composable filter sheet and exposes its active-group count. */
@Composable
private fun FilterControl(activeCount: Int, onClick: () -> Unit) {
    // iOS: FILTER pill with optional accent count badge.
    Row(
        Modifier.glass(CapsuleShape)
            .semantics {
                contentDescription =
                    if (activeCount > 0) "$activeCount active media filters" else "Filter media"
                role = Role.Button
            }.chromeClickable(onClick)
            .padding(horizontal = 10.dp, vertical = 9.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Text(
            "FILTER",
            style = chromeStyle(10f, FontWeight.Bold, mono = true),
            color = if (activeCount > 0) LiveDesign.accent else LiveDesign.muted,
        )
        if (activeCount > 0) {
            Text(
                "$activeCount",
                style = chromeStyle(9f, FontWeight.Bold, mono = true),
                color = LiveDesign.background,
                modifier =
                    Modifier
                        .clip(CapsuleShape)
                        .background(LiveDesign.accent)
                        .padding(horizontal = 6.dp, vertical = 1.dp),
            )
        }
    }
}

/** Three persisted adaptive-grid density presets. */
@Composable
private fun ThumbnailSizeControl(
    selected: MediaThumbnailSize,
    onSelect: (MediaThumbnailSize) -> Unit,
) {
    Row(
        Modifier.glass(CapsuleShape).padding(3.dp),
        horizontalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        MediaThumbnailSize.entries.forEach { size ->
            val active = size == selected
            Text(
                size.name.take(1),
                style = chromeStyle(10f, FontWeight.Bold, mono = true),
                color = if (active) LiveDesign.accent else LiveDesign.muted,
                modifier =
                    Modifier.clip(CircleShape)
                        .background(if (active) LiveDesign.accentDim else Color.Transparent)
                        .semantics {
                            contentDescription = size.accessibilityLabel
                            role = Role.RadioButton
                        }.chromeClickable { onSelect(size) }
                        .padding(horizontal = 9.dp, vertical = 6.dp),
            )
        }
    }
}

/**
 * Camera-scoped filter controls. iOS presents a ~400pt glass popup over a
 * dimmed backdrop — not a Material AlertDialog.
 */
@Composable
private fun MediaFilterDialog(
    filters: MediaLibraryFilters,
    storageIds: List<Long>,
    onFiltersChanged: (MediaLibraryFilters) -> Unit,
    onDismiss: () -> Unit,
) {
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
                        .heightIn(max = 290.dp)
                        .verticalScroll(rememberScrollState()),
                    verticalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    FilterSection("FORMAT") {
                        MediaContainerFilter.entries.forEach { value ->
                            FilterChoice(value.title, value in filters.containers) {
                                onFiltersChanged(
                                    filters.copy(containers = filters.containers.toggled(value)),
                                )
                            }
                        }
                    }
                    FilterSection("RESOLUTION") {
                        MediaResolutionFilter.entries.forEach { value ->
                            FilterChoice(value.title, value in filters.resolutions) {
                                onFiltersChanged(
                                    filters.copy(resolutions = filters.resolutions.toggled(value)),
                                )
                            }
                        }
                    }
                    FilterSection("DATE") {
                        FilterChoice("TODAY", filters.todayOnly) {
                            onFiltersChanged(filters.copy(todayOnly = !filters.todayOnly))
                        }
                    }
                    if (storageIds.isNotEmpty()) {
                        FilterSection("STORAGE") {
                            storageIds.forEachIndexed { index, storageId ->
                                FilterChoice("SLOT ${index + 1}", filters.storageId == storageId) {
                                    onFiltersChanged(
                                        filters.copy(
                                            storageId =
                                                if (filters.storageId == storageId) null
                                                else storageId,
                                        ),
                                    )
                                }
                            }
                        }
                    }
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

@Composable
private fun FilterSection(title: String, content: @Composable RowScope.() -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(title, style = chromeStyle(9f, FontWeight.Bold, mono = true), color = LiveDesign.muted)
        Row(
            Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()),
            horizontalArrangement = Arrangement.spacedBy(6.dp),
            content = content,
        )
    }
}

@Composable
private fun FilterChoice(title: String, selected: Boolean, onClick: () -> Unit) {
    Text(
        title,
        style = chromeStyle(10f, FontWeight.Bold, mono = true),
        color = if (selected) LiveDesign.accent else LiveDesign.muted,
        modifier =
            Modifier.clip(CapsuleShape)
                .background(if (selected) LiveDesign.accentDim else LiveDesign.background)
                .border(1.dp, if (selected) LiveDesign.accent else LiveDesign.hairline, CapsuleShape)
                .semantics {
                    contentDescription = "$title filter"
                    role = Role.Checkbox
                }.chromeClickable(onClick)
                .padding(horizontal = 12.dp, vertical = 8.dp),
    )
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
    cameraConnected: Boolean,
    cacheStore: MediaCacheStore,
    favorites: Set<String>,
    isSelecting: Boolean,
    selectedIDs: Set<String>,
    onOpen: (MediaClipRecord) -> Unit,
    onBeginSelection: (MediaClipRecord) -> Unit,
    onToggleSelection: (MediaClipRecord) -> Unit,
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
                        cameraConnected = cameraConnected,
                        cacheStore = cacheStore,
                        favorites = favorites,
                        isSelecting = isSelecting,
                        selectedIDs = selectedIDs,
                        onOpen = onOpen,
                        onBeginSelection = onBeginSelection,
                        onToggleSelection = onToggleSelection,
                        onSweepSelection = onSweepSelection,
                        onToggleFavorite = onToggleFavorite,
                    )
                } else {
                    MediaClipList(
                        clips = clips,
                        source = source,
                        cameraIDFor = cameraIDFor,
                        clipIdentity = clipIdentity,
                        cameraConnected = cameraConnected,
                        cacheStore = cacheStore,
                        favorites = favorites,
                        isSelecting = isSelecting,
                        selectedIDs = selectedIDs,
                        onOpen = onOpen,
                        onBeginSelection = onBeginSelection,
                        onToggleSelection = onToggleSelection,
                        onSweepSelection = onSweepSelection,
                        onToggleFavorite = onToggleFavorite,
                    )
                }
        }
    }
}

/**
 * Adaptive grid with iOS Photos-style multi-select:
 * long-press a cell to enter selection, then long-press + drag to range-paint
 * select/deselect (shrinking the drag restores the pre-sweep snapshot).
 *
 * While selecting, cells drop their own clickables and a full-size overlay owns
 * tap-toggle + long-press range paint so LazyGrid scroll cannot steal the gesture.
 */
@Composable
private fun MediaClipGrid(
    clips: List<MediaClipRecord>,
    thumbnailSize: MediaThumbnailSize,
    source: MediaLibrarySource,
    cameraIDFor: (MediaClipRecord) -> String,
    clipIdentity: (MediaClipRecord) -> String,
    cameraConnected: Boolean,
    cacheStore: MediaCacheStore,
    favorites: Set<String>,
    isSelecting: Boolean,
    selectedIDs: Set<String>,
    onOpen: (MediaClipRecord) -> Unit,
    onBeginSelection: (MediaClipRecord) -> Unit,
    onToggleSelection: (MediaClipRecord) -> Unit,
    onSweepSelection: (Set<String>) -> Unit,
    onToggleFavorite: (MediaClipRecord) -> Unit,
) {
    val cellFrames = remember { mutableStateMapOf<String, Rect>() }
    var gridOrigin by remember { mutableStateOf(Offset.Zero) }
    val gridState = rememberLazyGridState()
    val sweepScope = rememberCoroutineScope()
    val orderedIDs = remember(clips) { clips.map(clipIdentity) }
    // Live map/origin for mid-drag hit tests (edge auto-scroll moves cells without
    // waiting for a rememberUpdatedState snapshot).
    val currentSelected by rememberUpdatedState(selectedIDs)
    val currentClips by rememberUpdatedState(clips)
    val currentIdentity by rememberUpdatedState(clipIdentity)
    val currentSweep by rememberUpdatedState(onSweepSelection)
    val currentToggle by rememberUpdatedState(onToggleSelection)
    val view = LocalView.current
    val density = LocalDensity.current
    val edgeBandPx = with(density) { 72.dp.toPx() }

    LaunchedEffect(clips) { cellFrames.clear() }

    Box(
        Modifier.fillMaxSize()
            .onGloballyPositioned { coordinates -> gridOrigin = coordinates.positionInRoot() },
    ) {
        LazyVerticalGrid(
            columns = GridCells.Adaptive(minSize = thumbnailSize.minimumCellWidthDp.dp),
            state = gridState,
            modifier = Modifier.fillMaxSize(),
            // iOS LazyVGrid spacing: 16.
            horizontalArrangement = Arrangement.spacedBy(16.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
            contentPadding = PaddingValues(bottom = 28.dp),
            // Overlay owns movement while selecting; plain scroll resumes after exit.
            userScrollEnabled = !isSelecting,
        ) {
            items(clips, key = { clip -> clipIdentity(clip) }) { clip ->
                val identity = clipIdentity(clip)
                MediaClipCell(
                    clip = clip,
                    source = source,
                    cameraID = cameraIDFor(clip),
                    cameraConnected = cameraConnected,
                    cacheStore = cacheStore,
                    favorite = identity in favorites,
                    selected = identity in selectedIDs,
                    isSelecting = isSelecting,
                    // Cells only open / enter selection outside multi-select; the overlay
                    // owns toggle + paint once [isSelecting] is true.
                    onClick = { onOpen(clip) },
                    onLongPress = { onBeginSelection(clip) },
                    onToggleFavorite = { onToggleFavorite(clip) },
                    modifier =
                        Modifier.onGloballyPositioned { coordinates ->
                            cellFrames[identity] = coordinates.boundsInRoot()
                        },
                )
            }
        }

        // Full-size gesture layer above cells so combinedClickable cannot steal long-press
        // and so vertical drags cannot reach LazyGrid while selecting.
        if (isSelecting) {
            Box(
                Modifier
                    .fillMaxSize()
                    .mediaSelectionGestures(
                        orderedIDs = orderedIDs,
                        frames = { cellFrames },
                        origin = { gridOrigin },
                        selectedIDs = { currentSelected },
                        clips = { currentClips },
                        clipIdentity = { currentIdentity(it) },
                        onToggle = { currentToggle(it) },
                        onSweep = { currentSweep(it) },
                        onScrollBy = { delta ->
                            sweepScope.launch { gridState.scrollBy(delta) }
                        },
                        onEdgeScroll = { delta, finger, paintAt ->
                            sweepScope.launch {
                                gridState.scrollBy(delta)
                                paintAt(finger)
                            }
                        },
                        view = view,
                        edgeBandPx = edgeBandPx,
                    ),
            )
        }
    }
}

/** List arrangement uses the same core-authorized records and favorite state. */
@Composable
private fun MediaClipList(
    clips: List<MediaClipRecord>,
    source: MediaLibrarySource,
    cameraIDFor: (MediaClipRecord) -> String,
    clipIdentity: (MediaClipRecord) -> String,
    cameraConnected: Boolean,
    cacheStore: MediaCacheStore,
    favorites: Set<String>,
    isSelecting: Boolean,
    selectedIDs: Set<String>,
    onOpen: (MediaClipRecord) -> Unit,
    onBeginSelection: (MediaClipRecord) -> Unit,
    onToggleSelection: (MediaClipRecord) -> Unit,
    onSweepSelection: (Set<String>) -> Unit,
    onToggleFavorite: (MediaClipRecord) -> Unit,
) {
    val rowFrames = remember { mutableStateMapOf<String, Rect>() }
    var listOrigin by remember { mutableStateOf(Offset.Zero) }
    val listState = rememberLazyListState()
    val sweepScope = rememberCoroutineScope()
    val orderedIDs = remember(clips) { clips.map(clipIdentity) }
    val currentSelected by rememberUpdatedState(selectedIDs)
    val currentClips by rememberUpdatedState(clips)
    val currentIdentity by rememberUpdatedState(clipIdentity)
    val currentToggle by rememberUpdatedState(onToggleSelection)
    val currentSweep by rememberUpdatedState(onSweepSelection)
    val view = LocalView.current
    val density = LocalDensity.current
    val edgeBandPx = with(density) { 72.dp.toPx() }

    LaunchedEffect(clips) { rowFrames.clear() }

    Box(
        Modifier.fillMaxSize()
            .onGloballyPositioned { coordinates -> listOrigin = coordinates.positionInRoot() },
    ) {
        LazyColumn(
            state = listState,
            modifier = Modifier.fillMaxSize(),
            verticalArrangement = Arrangement.spacedBy(8.dp),
            contentPadding = PaddingValues(bottom = 28.dp),
            userScrollEnabled = !isSelecting,
        ) {
            items(clips, key = { clip -> clipIdentity(clip) }) { clip ->
                val identity = clipIdentity(clip)
                MediaClipListRow(
                    clip = clip,
                    source = source,
                    cameraID = cameraIDFor(clip),
                    cameraConnected = cameraConnected,
                    cacheStore = cacheStore,
                    favorite = identity in favorites,
                    selected = identity in selectedIDs,
                    isSelecting = isSelecting,
                    onClick = { onOpen(clip) },
                    onLongPress = { onBeginSelection(clip) },
                    onToggleFavorite = { onToggleFavorite(clip) },
                    modifier =
                        Modifier.onGloballyPositioned { coordinates ->
                            rowFrames[identity] = coordinates.boundsInRoot()
                        },
                )
            }
        }

        if (isSelecting) {
            Box(
                Modifier
                    .fillMaxSize()
                    .mediaSelectionGestures(
                        orderedIDs = orderedIDs,
                        frames = { rowFrames },
                        origin = { listOrigin },
                        selectedIDs = { currentSelected },
                        clips = { currentClips },
                        clipIdentity = { currentIdentity(it) },
                        onToggle = { currentToggle(it) },
                        onSweep = { currentSweep(it) },
                        onScrollBy = { delta ->
                            sweepScope.launch { listState.scrollBy(delta) }
                        },
                        onEdgeScroll = { delta, finger, paintAt ->
                            sweepScope.launch {
                                listState.scrollBy(delta)
                                paintAt(finger)
                            }
                        },
                        view = view,
                        edgeBandPx = edgeBandPx,
                    ),
            )
        }
    }
}

/**
 * Photos-style multi-select overlay gestures:
 * - short tap toggles the hit clip
 * - long-press + drag range-paints select/deselect from a pre-gesture snapshot
 * - vertical drag before long-press scrolls the list/grid (content follows the finger)
 *
 * The overlay sits above the lazy list so native user-scroll cannot see the pointer;
 * finger pans are applied with [onScrollBy] instead.
 */
private fun Modifier.mediaSelectionGestures(
    orderedIDs: List<String>,
    frames: () -> Map<String, Rect>,
    origin: () -> Offset,
    selectedIDs: () -> Set<String>,
    clips: () -> List<MediaClipRecord>,
    clipIdentity: (MediaClipRecord) -> String,
    onToggle: (MediaClipRecord) -> Unit,
    onSweep: (Set<String>) -> Unit,
    onScrollBy: (delta: Float) -> Unit,
    onEdgeScroll: (delta: Float, finger: Offset, paintAt: (Offset) -> Unit) -> Unit,
    view: View,
    edgeBandPx: Float,
): Modifier =
    pointerInput(orderedIDs) {
        fun indexAt(local: Offset): Int? {
            val id = hitClipID(frames(), origin(), local) ?: return null
            return orderedIDs.indexOf(id).takeIf { it >= 0 }
        }
        fun clipAt(local: Offset): MediaClipRecord? {
            val id = hitClipID(frames(), origin(), local) ?: return null
            return clips().firstOrNull { clipIdentity(it) == id }
        }
        awaitEachGesture {
            val down = awaitFirstDown(requireUnconsumed = false)
            down.consume()
            val touchSlop = viewConfiguration.touchSlop
            val longPressTimeout = viewConfiguration.longPressTimeoutMillis

            // null = long-press timeout (start paint)
            // "up" = short tap (toggle)
            // Offset = moved past slop before long-press (scroll from that position)
            val early: Any? =
                withTimeoutOrNull(longPressTimeout) {
                    var current = down
                    while (current.pressed) {
                        val event = awaitPointerEvent(PointerEventPass.Main)
                        val change =
                            event.changes.firstOrNull { it.id == down.id }
                                ?: return@withTimeoutOrNull "up"
                        change.consume()
                        if (!change.pressed) return@withTimeoutOrNull "up"
                        if ((change.position - down.position).getDistance() > touchSlop) {
                            return@withTimeoutOrNull change.position
                        }
                        current = change
                    }
                    "up"
                }

            when (early) {
                "up" -> clipAt(down.position)?.let(onToggle)
                is Offset -> {
                    // Finger moved before long-press: pan the list with the finger.
                    // scrollBy(positive) moves content up; finger up (y decreases) → positive.
                    var lastY = early.y
                    // Include the slop-crossing delta from the down point so the first
                    // move feels immediate rather than waiting for the next event.
                    val initialDelta = down.position.y - early.y
                    if (initialDelta != 0f) onScrollBy(initialDelta)
                    var pressed = true
                    while (pressed) {
                        val event = awaitPointerEvent(PointerEventPass.Main)
                        val change = event.changes.firstOrNull { it.id == down.id }
                        if (change == null) break
                        change.consume()
                        if (change.pressed) {
                            val delta = lastY - change.position.y
                            if (delta != 0f) onScrollBy(delta)
                            lastY = change.position.y
                        }
                        pressed = change.pressed
                    }
                }
                null -> {
                    val startIndex = indexAt(down.position)
                    if (startIndex == null) {
                        waitForUpOrCancellation()
                        return@awaitEachGesture
                    }
                    val snapshot = selectedIDs()
                    val paintSelect = orderedIDs[startIndex] !in snapshot
                    var lastIndex: Int? = null
                    fun paintTo(index: Int) {
                        if (index == lastIndex) return
                        lastIndex = index
                        onSweep(
                            MediaLibrarySelection.paintRange(
                                snapshot = snapshot,
                                orderedIDs = orderedIDs,
                                anchorIndex = startIndex,
                                currentIndex = index,
                                paintSelect = paintSelect,
                            ),
                        )
                        view.performOperatorHaptic(HapticFeedbackConstants.CLOCK_TICK)
                    }
                    fun paintAt(local: Offset) {
                        indexAt(local)?.let(::paintTo)
                    }
                    view.performOperatorHaptic(HapticFeedbackConstants.LONG_PRESS)
                    paintTo(startIndex)

                    val height = size.height.toFloat()
                    while (true) {
                        val event = awaitPointerEvent(PointerEventPass.Main)
                        val change = event.changes.firstOrNull { it.id == down.id } ?: break
                        change.consume()
                        if (!change.pressed) break
                        paintAt(change.position)
                        // Edge auto-scroll (iOS edgeBand ≈ 90pt).
                        val y = change.position.y
                        val delta =
                            when {
                                y < edgeBandPx ->
                                    -((edgeBandPx - y) / edgeBandPx * 28f).coerceAtLeast(4f)
                                y > height - edgeBandPx ->
                                    ((y - (height - edgeBandPx)) / edgeBandPx * 28f)
                                        .coerceAtLeast(4f)
                                else -> 0f
                            }
                        if (delta != 0f) {
                            onEdgeScroll(delta, change.position, ::paintAt)
                        }
                    }
                }
            }
        }
    }

/** Grid card with action-safe metadata; a long press starts library selection. */
@Composable
private fun MediaClipCell(
    clip: MediaClipRecord,
    source: MediaLibrarySource,
    cameraID: String,
    cameraConnected: Boolean,
    cacheStore: MediaCacheStore,
    favorite: Boolean,
    selected: Boolean,
    isSelecting: Boolean,
    onClick: () -> Unit,
    onLongPress: () -> Unit,
    onToggleFavorite: () -> Unit,
    modifier: Modifier = Modifier,
) {
    // While multi-selecting the parent overlay owns all pointer input; cell clickables
    // would steal long-press and re-enable scroll competition.
    val interaction =
        if (isSelecting) {
            Modifier
        } else {
            Modifier.combinedClickable(
                onClick = onClick,
                onLongClick = onLongPress,
                onLongClickLabel = "Select ${clip.filename}",
            )
        }
    Column(modifier, verticalArrangement = Arrangement.spacedBy(7.dp)) {
        Box(
            Modifier.fillMaxWidth()
                .aspectRatio(16f / 9f)
                .clip(RoundedCornerShape(LiveDesign.CORNER_RADIUS_DP.dp))
                .background(LiveDesign.surface)
                .border(
                    if (selected) 2.dp else 1.dp,
                    if (selected) LiveDesign.accent else LiveDesign.hairline,
                    RoundedCornerShape(LiveDesign.CORNER_RADIUS_DP.dp),
                ).semantics {
                    contentDescription = clipAccessibilityLabel(clip, selected, isSelecting)
                    role = Role.Button
                }.then(interaction),
            contentAlignment = Alignment.Center,
        ) {
            ClipArtwork(
                clip = clip,
                source = source,
                cameraID = cameraID,
                cameraConnected = cameraConnected,
                cacheStore = cacheStore,
                modifier = Modifier.fillMaxSize(),
            )
            Text(
                clipActionLabel(clip),
                style = chromeStyle(9f, FontWeight.Bold, mono = true),
                color = if (clip.isPreviewable) LiveDesign.accent else LiveDesign.faint,
                modifier =
                    Modifier.align(Alignment.TopStart)
                        .padding(7.dp)
                        .badgeBackground()
                        .padding(horizontal = 6.dp, vertical = 3.dp),
            )
            Text(
                clip.badgeLabel,
                style = chromeStyle(9f, FontWeight.Bold, mono = true),
                color = LiveDesign.text,
                modifier =
                    Modifier.align(Alignment.BottomEnd)
                        .padding(7.dp)
                        .badgeBackground()
                        .padding(horizontal = 6.dp, vertical = 3.dp),
            )
            // iOS has no "ON DEVICE" cell badge — offline is implied by the library source.
            if (isSelecting) {
                SelectionMarker(selected = selected, modifier = Modifier.align(Alignment.TopEnd).padding(7.dp))
            } else {
                FavoriteButton(
                    favorite = favorite,
                    filename = clip.filename,
                    onClick = onToggleFavorite,
                    modifier = Modifier.align(Alignment.TopEnd).padding(7.dp),
                )
            }
        }
        Text(
            clip.filename,
            style = chromeStyle(12f, FontWeight.Medium),
            color = LiveDesign.text,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

/** Dense row version of [MediaClipCell]. */
@Composable
private fun MediaClipListRow(
    clip: MediaClipRecord,
    source: MediaLibrarySource,
    cameraID: String,
    cameraConnected: Boolean,
    cacheStore: MediaCacheStore,
    favorite: Boolean,
    selected: Boolean,
    isSelecting: Boolean,
    onClick: () -> Unit,
    onLongPress: () -> Unit,
    onToggleFavorite: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val interaction =
        if (isSelecting) {
            Modifier
        } else {
            Modifier.combinedClickable(
                onClick = onClick,
                onLongClick = onLongPress,
                onLongClickLabel = "Select ${clip.filename}",
            )
        }
    Row(
        modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(LiveDesign.CORNER_RADIUS_DP.dp))
            .background(if (selected) LiveDesign.accentDim else LiveDesign.surface)
            .border(
                if (selected) 2.dp else 1.dp,
                if (selected) LiveDesign.accent else LiveDesign.hairline,
                RoundedCornerShape(LiveDesign.CORNER_RADIUS_DP.dp),
            ).semantics {
                contentDescription = clipAccessibilityLabel(clip, selected, isSelecting)
                role = Role.Button
            }.then(interaction)
            .padding(8.dp),
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            Modifier.size(width = 104.dp, height = 62.dp)
                .clip(RoundedCornerShape(8.dp))
                .background(LiveDesign.background),
            contentAlignment = Alignment.Center,
        ) {
            ClipArtwork(
                clip = clip,
                source = source,
                cameraID = cameraID,
                cameraConnected = cameraConnected,
                cacheStore = cacheStore,
                modifier = Modifier.fillMaxSize(),
            )
            if (isSelecting) {
                SelectionMarker(selected = selected, modifier = Modifier.align(Alignment.TopEnd).padding(5.dp))
            }
        }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Text(
                clip.filename,
                style = chromeStyle(13f, FontWeight.SemiBold),
                color = LiveDesign.text,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                "${clip.badgeLabel} · ${clipActionLabel(clip)}",
                style = chromeStyle(10f, FontWeight.Medium, mono = true),
                color = LiveDesign.muted,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        if (!isSelecting) {
            FavoriteButton(favorite = favorite, filename = clip.filename, onClick = onToggleFavorite)
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
    cacheStore: MediaCacheStore,
    modifier: Modifier = Modifier,
) {
    var thumbnail by remember(clip.libraryKey(cameraID), source) { mutableStateOf<ImageBitmap?>(null) }
    LaunchedEffect(clip.libraryKey(cameraID), source, cameraConnected) {
        thumbnail =
            withContext(Dispatchers.IO) {
                val cameraThumbnail =
                    if (source == MediaLibrarySource.CAMERA && cameraConnected && SwiftCore.isAvailable) {
                        SwiftCore.sessionThumbnail(clip.handle.toInt())?.let { jpeg ->
                            BitmapFactory.decodeByteArray(jpeg, 0, jpeg.size)?.asImageBitmap()
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
        BitmapFactory.decodeFile(
            entry.finalPath.toString(),
            BitmapFactory.Options().apply {
                inSampleSize = sampleSize
                inPreferredConfig = Bitmap.Config.ARGB_8888
            },
        )?.asImageBitmap()
    } catch (_: OutOfMemoryError) {
        null
    } catch (_: RuntimeException) {
        null
    }
}

/** Favorite icon is a persisted library flag, not a camera mutation. */
@Composable
private fun FavoriteButton(
    favorite: Boolean,
    filename: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Box(
        modifier =
            modifier
                .size(32.dp)
                .glass(CircleShape)
                .semantics {
                    contentDescription =
                        if (favorite) "Remove $filename from favorites" else "Add $filename to favorites"
                    role = Role.Button
                }.chromeClickable(onClick),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            if (favorite) "★" else "☆",
            style = chromeStyle(17f, FontWeight.Medium),
            color = if (favorite) LiveDesign.accent else LiveDesign.text,
        )
    }
}

/** Visible selection state, including an unselected affordance for sweep mode. */
@Composable
private fun SelectionMarker(selected: Boolean, modifier: Modifier = Modifier) {
    Box(
        modifier =
            modifier
                .size(30.dp)
                .background(
                    if (selected) LiveDesign.accent else Color.Black.copy(alpha = 0.56f),
                    CircleShape,
                ),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            if (selected) "✓" else "○",
            style = chromeStyle(16f, FontWeight.Bold),
            color = if (selected) LiveDesign.background else LiveDesign.text,
        )
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

private val MediaClipRecord.isPreviewable: Boolean
    get() =
        contentKind == MediaContentKind.PLAYABLE_PROXY ||
            contentKind == MediaContentKind.STILL_PHOTO

private fun clipActionLabel(clip: MediaClipRecord): String =
    when (clip.contentKind) {
        MediaContentKind.PLAYABLE_PROXY -> "PLAY"
        MediaContentKind.STILL_PHOTO -> "VIEW"
        MediaContentKind.R3D_MASTER -> "MASTER"
        MediaContentKind.UNSUPPORTED -> "MEDIA"
    }

private fun clipAccessibilityLabel(
    clip: MediaClipRecord,
    selected: Boolean,
    isSelecting: Boolean,
): String =
    buildString {
        append(clip.filename)
        append(", ")
        append(clipActionLabel(clip).lowercase())
        if (isSelecting) append(if (selected) ", selected" else ", not selected")
    }

private fun hitClipID(
    frames: Map<String, Rect>,
    gridOrigin: Offset,
    localPoint: Offset,
): String? {
    val rootPoint = Offset(gridOrigin.x + localPoint.x, gridOrigin.y + localPoint.y)
    return frames.entries.firstOrNull { (_, frame) -> frame.contains(rootPoint) }?.key
}

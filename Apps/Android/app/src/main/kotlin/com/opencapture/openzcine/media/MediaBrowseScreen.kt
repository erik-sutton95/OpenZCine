package com.opencapture.openzcine.media

import com.opencapture.opencine.cameracontrols.MonitorOperatorCatalogScreen
import com.opencapture.opencine.cameracontrols.MonitorMediaGalleryPresentation
import com.opencapture.opencine.cameracontrols.MonitorMediaGalleryEmpty
import com.opencapture.opencine.cameracontrols.MonitorMediaGalleryFilters
import com.opencapture.opencine.cameracontrols.MonitorMediaGalleryFileFacts
import com.opencapture.opencine.cameracontrols.MonitorMediaGalleryNavigation
import com.opencapture.opencine.cameracontrols.MonitorMediaGalleryFilterAction
import com.opencapture.opencine.cameracontrols.MonitorMediaGalleryStorage
import com.opencapture.opencine.appkit.MonitorMediaGalleryOperations
import com.opencapture.opencine.appkit.MonitorMediaGalleryOpen
import com.opencapture.opencine.appkit.MonitorMediaRecord
import com.opencapture.opencine.appkit.MonitorMediaGalleryDeletion
import com.opencapture.opencine.appkit.MonitorMediaGalleryAccess
import com.opencapture.opencine.appkit.MonitorMediaDeletionPreparation
import com.opencapture.opencine.appkit.MonitorMediaLibraryActionToken

import com.opencapture.monitorui.MonitorIcon
import com.opencapture.monitorui.MonitorMediaFilterChoice
import com.opencapture.monitorui.MonitorThumbnailSize
import com.opencapture.monitorui.MonitorMediaSelectionConfiguration
import com.opencapture.opencine.nikon.NikonMediaClipRecord
import com.opencapture.opencine.nikon.NikonMediaContentKind
import com.opencapture.openzcine.NikonAssists
import com.opencapture.opencine.appkit.LocalOperatorHaptics
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.ui.platform.LocalViewConfiguration
import kotlinx.coroutines.launch
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.setValue
import com.opencapture.opencine.appkit.*
import com.opencapture.opencine.media.MediaCatalog
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.opencapture.openzcine.ExposureAssistCameraInput
import com.opencapture.openzcine.FeedLutSelection
import com.opencapture.openzcine.LiveDesign
import com.opencapture.openzcine.R
import com.opencapture.openzcine.bridge.SwiftCore
import com.opencapture.opencine.cameracontrols.chromeClickable
import com.opencapture.openzcine.chromeStyle
import com.opencapture.openzcine.diagnostics.AndroidDiagnosticEvent
import com.opencapture.openzcine.frameio.FrameioDeliveryController
import com.opencapture.openzcine.frameio.FrameioDeliveryState
import com.opencapture.openzcine.frameio.FrameioInternetHopState
import com.opencapture.openzcine.frameio.MediaDeliveryConfiguration
import com.opencapture.openzcine.lut.AndroidLutLibrary
import com.opencapture.opencine.nikon.CameraStorageSlotStatus
import com.opencapture.openzcine.settings.OperatorSettings
import java.nio.file.Files
import java.nio.file.LinkOption
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.withContext
import com.opencapture.opencine.nikon.NikonMediaClips
import com.opencapture.opencine.nikon.NikonNative
import com.opencapture.monitorui.MonitorMediaLayout
import com.opencapture.monitorui.MonitorMaterial
import com.opencapture.monitorui.monitorMaterial

/** Loading / loaded / failed states of one camera or persisted-local listing pass. */
internal sealed interface BrowseState {
    data object Loading : BrowseState

    data class Loaded(
        val clips: List<NikonMediaClipRecord>,
        val isLoadingMore: Boolean = false,
    ) : BrowseState

    data class Failed(val message: String) : BrowseState
}

/** A truncated camera enumeration is a failed catalog, never a complete partial listing. */
internal fun incompleteCameraBrowseState(partialClips: List<NikonMediaClipRecord>): BrowseState.Failed {
    if (partialClips.isEmpty()) {
        return BrowseState.Failed("Couldn't finish listing camera media.")
    }
    val itemLabel = if (partialClips.size == 1) "item" else "items"
    return BrowseState.Failed(
        "Listing stopped after ${partialClips.size} $itemLabel. Retry to load the complete library.",
    )
}

/** Privacy-bounded details attached to Android's share intent only when requested. */
internal fun mediaDeliveryMetadataSummary(clips: List<NikonMediaClipRecord>): String {
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
    cacheStore: MediaCacheStore,
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
    assists: NikonAssists,
    exposureAssistCameraInput: ExposureAssistCameraInput,
    operatorSettings: OperatorSettings,
    lutLibrary: AndroidLutLibrary,
    frameioController: FrameioDeliveryController,
    mediaDeliveryCoordinator: MediaDeliveryCoordinator,
    autoPlayFirstProxy: Boolean = false,
    /** Bumped when Settings clears the camera media cache so an open gallery reloads. */
    cacheRevision: Int = 0,
    /** The actual root's canonical index also receives Settings clear/delete mutations. */
    catalogIndex: MediaLibraryIndex? = null,
    /** Records a closed rating-write breadcrumb (attempted / confirmed / refused). */
    onRatingDiagnostic: (AndroidDiagnosticEvent) -> Unit = {},
    onClose: () -> Unit,
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val libraryIndex =
        remember(context, catalogIndex) {
            catalogIndex ?: MediaLibraryIndex(SharedPreferencesMediaLibraryPreferences(context))
        }
    var library by remember(cameraID, mediaService, offlineCameraIDs, libraryIndex) { mutableStateOf<MonitorMediaLibraryModel<NikonLibraryClip>?>(null) }
    var libraryCodec by remember(cameraID, mediaService, offlineCameraIDs, libraryIndex) { mutableStateOf<NikonMediaLibraryCodec?>(null) }
    var librarySourceOwner by remember(cameraID, mediaService, offlineCameraIDs, libraryIndex) { mutableStateOf<com.opencapture.opencine.nikon.NikonMediaService?>(null) }
    val libraryActions = remember(cameraID, mediaService, offlineCameraIDs, libraryIndex, cacheStore) {
        NikonMediaLibraryActions(libraryIndex, cacheStore, { library }, { libraryCodec })
    }
    var deletionAction by remember(cameraID, mediaService, libraryIndex) {
        mutableStateOf<NikonMediaLibraryActions.Capture?>(null)
    }
    val emptyLibraryState = remember(cameraID) { kotlinx.coroutines.flow.MutableStateFlow(MonitorMediaLibraryState<NikonLibraryClip>()) }
    val libraryState by (library?.state ?: emptyLibraryState).collectAsState()
    DisposableEffect(library, mediaService) {
        val retired = library
        onDispose {
            // Retire exact native lease before Compose cancels the inherited cleanup scope.
            val binding = retired?.binding
            if (binding != null) mediaService?.retireBrowse(binding)
            retired?.close()
        }
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
    fun ownerCameraID(clip: NikonMediaClipRecord): String =
        offlineClipOwners[clip.offlineObjectKey()] ?: cameraID
    fun clipKey(clip: NikonMediaClipRecord): String = clip.libraryKey(ownerCameraID(clip))
    var state by remember(cameraID) { mutableStateOf<BrowseState>(BrowseState.Loading) }
    var reloadKey by remember { mutableIntStateOf(0) }
    // Camera-card deletion in flight: the listing effect stays cancelled while
    // non-null so an already-enumerated page cannot re-add the deleted rows.
    var pendingDeletion by remember(cameraID) { mutableStateOf<List<NikonMediaClipRecord>?>(null) }
    // Deletion progress (completed, total) while a batch delete runs — drives the progress bar
    // and keeps the grid steady until the run finishes (the listing restarts once, at the end).
    var deletionProgress by remember { mutableStateOf<Pair<Int, Int>?>(null) }
    // Shots the operator selected (smaller than the file total when RAW+JPEG pairs / masters /
    // backups ride along) — kept so the progress bar can explain the inflated file count.
    var deletionSelectedCount by remember { mutableStateOf(0) }
    var deleteConfirmTargets by remember { mutableStateOf<List<NikonMediaClipRecord>?>(null) }
    var playingClip by remember { mutableStateOf<NikonMediaClipRecord?>(null) }
    var viewingPhoto by remember { mutableStateOf<NikonMediaClipRecord?>(null) }
    var openedPhotoLibrary by remember { mutableStateOf<MonitorMediaLibraryModel<NikonLibraryClip>?>(null) }
    var photoOpening by remember { mutableStateOf<MonitorMediaGalleryOpen<NikonLibraryClip>?>(null) }
    var seriesFrames by remember { mutableStateOf<List<MonitorMediaRecord<NikonLibraryClip>>>(emptyList()) }
    // The representative of a burst series whose members are being browsed (Manage series).
    var seriesRepresentative by remember { mutableStateOf<NikonMediaClipRecord?>(null) }
    var closeRequested by remember { mutableStateOf(false) }
    var autoPlayHandled by remember { mutableStateOf(false) }
    var deliverySelection by remember(cameraID) { mutableStateOf<List<NikonLibraryClip>>(emptyList()) }
    var deliveryAdmission by remember(cameraID) { mutableStateOf<MonitorMediaLibraryActionToken?>(null) }
    var deliveryHost by remember { mutableStateOf<NikonMediaDeliveryHost?>(null) }
    val deliveryDisplay by mediaDeliveryCoordinator.display.collectAsState()
    val shareInProgress = deliveryDisplay.overlay != null
    var shareMessage by remember { mutableStateOf<String?>(null) }
    var filters by remember(cameraID) { mutableStateOf(MediaLibraryFilters()) }
    var browseStorageSlots by
        remember(cameraID) { mutableStateOf<List<CameraStorageSlotStatus>?>(null) }

    fun updateOptions(updated: MediaLibraryViewOptions) {
        if (shareInProgress) return
        // Never let category/layout edits re-stick a stale source preference.
        val coerced = updated.copy(source = librarySource)
        options = coerced
        libraryIndex.saveViewOptions(coerced)
        shareMessage = null
    }

    fun updateFilters(updated: MediaLibraryFilters) {
        filters = updated
    }

    fun toggleStorageSlot(storageId: Long) {
        updateFilters(filters.togglingStorageSlot(storageId))
    }

    fun exitSelection() {
        library?.clearSelection()
        deliverySelection = emptyList(); deliveryAdmission = null
    }

    fun cancelActiveShareOrExitSelection() {
        val outgoing = deliveryHost?.capturedRun
        if (shareInProgress && outgoing != null) outgoing.cancel() else exitSelection()
    }

    LaunchedEffect(cameraID, offlineCameraIDs) {
        favorites =
            withContext(Dispatchers.IO) {
                val ids =
                    offlineCameraIDs.takeIf { it.isNotEmpty() } ?: listOf(cameraID)
                ids.flatMap { id -> libraryIndex.favoriteIDs(id) }.toSet()
            }
    }

    LaunchedEffect(cameraID, mediaService, offlineCameraIDs, librarySource,
        effectiveCameraConnected, reloadKey, cacheRevision, pendingDeletion != null) {
        if (pendingDeletion != null) return@LaunchedEffect
        // The old listing retires before local IO can suspend; deletion retires it at request capture.
        library?.let { previous ->
            previous.binding?.let { librarySourceOwner?.retireBrowse(it) }
            previous.close()
        }
        state = BrowseState.Loading
        val connectedSource = mediaService.takeIf {
            effectiveCameraConnected && librarySource == MediaLibrarySource.CAMERA && SwiftCore.isAvailable
        }
        val buckets = if (librarySource == MediaLibrarySource.LOCAL)
            offlineCameraIDs.takeIf { it.isNotEmpty() } ?: listOf(cameraID) else listOf(cameraID)
        val initialRows = withContext(Dispatchers.IO) {
            buckets.flatMap { bucket -> libraryIndex.persistedClips(bucket).map { NikonLibraryClip(bucket, it) } }
        }
        var owner = library
        if (owner == null) {
            val codec = NikonMediaLibraryCodec(cameraID, connectedSource, cacheStore,
                favoriteKeys = { buckets.flatMap { libraryIndex.favoriteIDs(it) }.toSet() },
                hasLocalCopy = { clip -> runCatching {
                    cacheStore.completedEntryOrNull(cameraID, MediaCacheObjectIdentity(clip), clip.sizeBytes)
                }.getOrNull() != null })
            owner = MonitorMediaLibraryModel(
                cache = MonitorMediaCache(cacheStore.libraryDirectory, codec,
                    eligibility = MonitorMediaOriginalEligibility.ExactSize,
                    catalogAddress = libraryIndex.catalogByteStore(cameraID).namespace, preservedMetadata = emptyList(),
                    catalogStore = libraryIndex.catalogByteStore(cameraID)),
                favoritesStore = NikonLibraryFavorites(libraryIndex, buckets),
                service = connectedSource, scope = scope,
                cacheScanning = MonitorMediaCacheScanning.BACKGROUND,
                catalogPersistence = MonitorMediaCatalogPersistence.LISTING_COMPLETE_OR_NON_CANCEL_FAILURE,
                initialCatalog = MediaCatalog(), initialRecords = initialRows.map(codec::record),
                catalogBase = MonitorMediaCatalogBase.FRESH_LISTING)
            owner.visibility(MonitorMediaLibraryVisibility.ALL_RECORDS)
            libraryCodec = codec; librarySourceOwner = connectedSource; library = owner
        } else if (librarySourceOwner !== connectedSource) {
            // Producer replacement also replaces its pure binding-capture codec.
            owner.close(); library = null; reloadKey += 1; return@LaunchedEffect
        }
        val actual = owner
        val currentCodec = libraryCodec ?: return@LaunchedEffect
        actual.applyLocalRecords(MonitorMediaCatalogCapture(resetLibrary = true,
            upserts = initialRows.map(currentCodec::record),
            sourceFavoriteKeys = buckets.flatMap { libraryIndex.favoriteIDs(it) }.toSet()), actual.actionToken)
        if (librarySource == MediaLibrarySource.LOCAL) {
            val localRows = withContext(Dispatchers.IO) {
                initialRows.filter { value -> runCatching {
                    cacheStore.completedEntryOrNull(value.bucket, MediaCacheObjectIdentity(value.clip), value.clip.sizeBytes)
                }.getOrNull() != null }
            }
            val codec = libraryCodec ?: return@LaunchedEffect
            actual.applyLocalRecords(MonitorMediaCatalogCapture(resetLibrary = true,
                upserts = localRows.map(codec::record),
                sourceFavoriteKeys = buckets.flatMap { libraryIndex.favoriteIDs(it) }.toSet()), actual.actionToken)
            if (!actual.state.value.browsing) actual.begin()
            offlineClipOwners = localRows.associate { it.clip.offlineObjectKey() to it.bucket }
            state = BrowseState.Loaded(localRows.map { it.clip })
        } else if (connectedSource == null) {
            state = BrowseState.Failed(if (!effectiveCameraConnected) "Reconnect the camera to list media."
                else "Camera core is not bundled in this build.")
        } else {
            offlineClipOwners = emptyMap(); browseStorageSlots = null
            libraryCodec?.beginListing()
            if (actual.state.value.browsing) actual.refresh() else actual.begin()
            actual.state.collect { snapshot ->
                val binding = actual.binding
                if (library !== actual || !snapshot.browsing) return@collect
                val clips = if (binding != null && connectedSource.isCurrent(binding)) {
                    NikonMediaClips.newestFirst(snapshot.catalog.assets.mapNotNull { asset ->
                        connectedSource.mediaCatalogRecord(asset.id, binding)?.clip
                    })
                } else emptyList()
                if (binding != null) browseStorageSlots = connectedSource.storageSlots(binding)
                state = if (snapshot.fetching && snapshot.catalogPageCount == 0) BrowseState.Loading
                    else if (snapshot.note != null && !snapshot.fetching) incompleteCameraBrowseState(clips)
                    else BrowseState.Loaded(clips, isLoadingMore = snapshot.fetching)
                if (autoPlayFirstProxy && !autoPlayHandled && !snapshot.fetching) {
                    autoPlayHandled = true
                    val first = snapshot.records.firstOrNull {
                        it.payload.clip.contentKind == NikonMediaContentKind.PLAYABLE_PROXY
                    }
                    if (first != null) {
                        openedPhotoLibrary = actual
                        photoOpening = MonitorMediaGalleryOpen(first,
                            snapshot.records.filter { it.facts.playbackEligible != false &&
                                (it.facts.presentationKind ?: it.asset.kind) == first.asset.kind }, actual.actionToken)
                        playingClip = first.payload.clip
                    }
                }
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
        val action = deletionAction ?: return@LaunchedEffect
        // The existing stop joins the native pump before the first admitted delete.
        withContext(Dispatchers.IO) {
            if (SwiftCore.isAvailable) connectionOwner?.let(NikonNative::sessionStopMediaTransfer)
        }
        if (action.isCurrent) deletionProgress = 0 to targets.size
        action.deleteBatch(targets.map { NikonLibraryClip(ownerCameraID(it), it) },
            deleteObject = { value ->
                withContext(Dispatchers.IO) {
                    SwiftCore.isAvailable && connectionOwner != null &&
                        NikonNative.sessionDeleteObject(connectionOwner, value.clip.handle.toInt())
                }
            }, onProgress = { completed, total -> deletionProgress = completed to total })
        if (!action.isCurrent || deletionAction !== action) return@LaunchedEffect
        deletionProgress = null
        favorites = withContext(Dispatchers.IO) {
            val ids = offlineCameraIDs.takeIf { it.isNotEmpty() } ?: listOf(cameraID)
            ids.flatMap { id -> libraryIndex.favoriteIDs(id) }.toSet()
        }
        if (!action.isCurrent || deletionAction !== action) return@LaunchedEffect
        exitSelection()
        pendingDeletion = null; deletionAction = null
    }

    fun requestDeletion(selection: List<NikonMediaClipRecord>) {
        if (selection.isEmpty() || pendingDeletion != null) return
        val catalog = (state as? BrowseState.Loaded)?.clips.orEmpty()
        deleteConfirmTargets = null
        viewingPhoto = null
        deletionSelectedCount = selection.size
        val targets = cameraDeletionTargets(catalog, selection, ::ownerCameraID)
        deletionAction = libraryActions.beginDeletion(targets.map { NikonLibraryClip(ownerCameraID(it), it) }) {
            library?.let { owner ->
                owner.binding?.let { librarySourceOwner?.retireBrowse(it) }
                owner.close()
            }
        }
        pendingDeletion = targets
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
    // A captured neutral pass supplies options, sorted survivors and grid representatives together.
    val projection = remember(loadedClips, options.category, favorites, cameraID,
        options.sortOrder, filters, offlineClipOwners, libraryState.records) {
        val actualIDs = libraryState.records.associate {
            it.payload.clip.libraryKey(it.payload.bucket) to it.asset.id
        }
        NikonAppGalleryProjection(loadedClips, actualIDs, options.category, favorites,
            cameraID, options.sortOrder, filters, libraryKey = ::clipKey, ownerOf = ::ownerCameraID)
    }
    val displayedClips = projection.displayedClips
    val filterOptions = projection.filterOptions
    // Only an operator navigation prunes, never a discovery batch: chips derived from a listing
    // that is still streaming in must not clear a selection the operator just made.
    LaunchedEffect(options.category, librarySource) {
        val retained = filters.retainingOfferedChips(filterOptions)
        if (retained != filters) filters = retained
    }
    val gridClips = projection.gridClips
    val burstSeries = projection.legacyGroups
    val burstByRepresentative = remember(burstSeries) { burstSeries.associateBy { it.representativeID } }
    fun burstMembers(representative: NikonMediaClipRecord): List<NikonMediaClipRecord> =
        projection.members(representative, ::clipKey)
    fun hasRawSibling(clip: NikonMediaClipRecord): Boolean = projection.hasRawSibling(clip, ::clipKey)
    val selectedClips = deliverySelection.map { it.clip }
    val selectedLut = assists.lut
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

    fun toggleFavorite(clip: NikonMediaClipRecord) {
        val owner = ownerCameraID(clip)
        val value = NikonLibraryClip(owner, clip)
        val action = libraryActions.capture(listOf(value))
        val updated = action.toggleFavorite(value)
        if (updated != null && action.isCurrent) favorites = mergedFavorites(updated)
        // Heart and camera star are one signal (Favorites reads the set that star writes fill):
        // agree the body's rating with the heart when connected. Best-effort — an offline clip
        // keeps only the local flag. [verify-on-HW]
        val nowFavorite = action.favoriteTarget(value)
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
    fun captureRatingCompletion(clip: NikonMediaClipRecord): NikonMediaRatingCompletion {
        val value = NikonLibraryClip(ownerCameraID(clip), clip)
        return libraryActions.captureRatingCompletion(value) { favorites = mergedFavorites(it) }
    }
    fun mirrorRating(clip: NikonMediaClipRecord, stars: Int) { captureRatingCompletion(clip).mirror(stars) }

    fun galleryOperations(actual: MonitorMediaLibraryModel<NikonLibraryClip>): MonitorMediaGalleryOperations<NikonLibraryClip> = MonitorMediaGalleryOperations<NikonLibraryClip>(
        favorite = { record -> toggleFavorite(record.payload.clip) },
        access = { record -> MonitorMediaGalleryAccess(
            share = !shareInProgress,
            delete = librarySource == MediaLibrarySource.CAMERA && effectiveCameraConnected &&
                !shareInProgress,
        ) },
        openNotice = { record -> when (record.payload.clip.contentKind) {
            NikonMediaContentKind.R3D_MASTER -> "${record.payload.clip.filename} is a camera master; preview is unavailable."
            NikonMediaContentKind.UNSUPPORTED -> "${record.payload.clip.filename} has no Android preview yet."
            else -> null
        } },
        deletionMessage = { rows -> deleteConfirmationMessage(loadedClips, rows.map { it.payload.clip }, ::ownerCameraID) },
        acceptedDeletion = MonitorMediaGalleryDeletion(
            capture = { rows ->
                val targets = cameraDeletionTargets(loadedClips, rows.map { it.payload.clip }, ::ownerCameraID)
                libraryActions.capture(targets.map { NikonLibraryClip(ownerCameraID(it), it) }).captureDeletionAuthority()
            }, perform = { rows, authority ->
                val targets = cameraDeletionTargets(loadedClips, rows.map { it.payload.clip }, ::ownerCameraID)
                    .map { NikonLibraryClip(ownerCameraID(it), it) }
                val action = libraryActions.capture(targets)
                val nativeOwner = connectionOwner
                val browseBinding = actual.binding
                val browseSource = librarySourceOwner
                // SDK drain stays source-specific; the Library retires all gallery work itself.
                if (authority.isCurrent && action.isCurrent) withContext(Dispatchers.IO) {
                    if (SwiftCore.isAvailable && authority.isCurrent) nativeOwner?.let(NikonNative::sessionStopMediaTransfer)
                }
                action.deleteBatch(targets, deleteObject = { value ->
                    withContext(Dispatchers.IO) {
                        SwiftCore.isAvailable && nativeOwner != null &&
                            NikonNative.sessionDeleteObject(nativeOwner, value.clip.handle.toInt())
                    }
                }, onProgress = { _, _ -> }, accepted = authority,
                    preparation = MonitorMediaDeletionPreparation.RETIRE_GALLERY,
                    prepare = { browseBinding?.let { browseSource?.retireBrowse(it) } },
                    afterFinish = { completed ->
                        if (completed.isCompleting && action.sourceIsCurrent) {
                            val updated = withContext(Dispatchers.IO) {
                                (offlineCameraIDs.takeIf { it.isNotEmpty() } ?: listOf(cameraID))
                                    .flatMap { libraryIndex.favoriteIDs(it) }.toSet()
                            }
                            if (completed.isCompleting && action.sourceIsCurrent) {
                                favorites = updated
                                actual.relist(after = completed)
                            }
                        }
                    })
            },
        ),
    )

    fun open(clip: NikonMediaClipRecord, captured: MonitorMediaGalleryOpen<NikonLibraryClip>? = null) {
        val actual = library ?: return
        val record = captured?.record ?: actual.state.value.records.firstOrNull {
            it.payload.clip.libraryKey(it.payload.bucket) == clipKey(clip)
        } ?: return
        val opening = captured ?: MonitorMediaGalleryOpen(record,
            actual.displayedRecords.filter { it.facts.playbackEligible != false &&
                (it.facts.presentationKind ?: it.asset.kind) == (record.facts.presentationKind ?: record.asset.kind) }, actual.actionToken)
        if (!actual.isCurrent(opening.admission)) return
        openedPhotoLibrary = actual
        photoOpening = opening
        // A burst representative opens the series view (its other frames are hidden in the grid).
        if (burstByRepresentative[clipKey(clip)] != null) {
            seriesRepresentative = clip
            seriesFrames = burstMembers(clip).mapNotNull { member -> actual.state.value.records.firstOrNull {
                it.payload.clip.libraryKey(it.payload.bucket) == clipKey(member)
            } }
            return
        }
        when (clip.contentKind) {
            NikonMediaContentKind.PLAYABLE_PROXY -> playingClip = clip
            NikonMediaContentKind.STILL_PHOTO -> viewingPhoto = clip
            NikonMediaContentKind.R3D_MASTER ->
                shareMessage = "${clip.filename} is a camera master; preview is unavailable."
            NikonMediaContentKind.UNSUPPORTED ->
                shareMessage = "${clip.filename} has no Android preview yet."
        }
    }

    fun presentNativeDelivery() {
        val actual = library ?: return
        val token = deliveryAdmission ?: return
        if (shareInProgress || selectedClips.isEmpty() || !actual.isCurrent(token)) return
        val records = deliverySelection.mapNotNull { selected -> actual.state.value.records.firstOrNull {
            it.payload.bucket == selected.bucket && sameNikonActionContent(it.payload.clip, selected.clip)
        } }
        if (records.size != deliverySelection.size || records.isEmpty()) return
        val action = libraryActions.capture(records.map { it.payload })
        if (!action.sourceIsCurrent || !actual.isCurrent(token)) return
        val capturedLut = selectedLut.takeIf { selectedLutLabel != null }
        val capturedLabel = selectedLutLabel
        val outgoing = deliveryHost
        outgoing?.close()
        val host = NikonMediaDeliveryHost(scope, mediaDeliveryCoordinator, frameioController, cacheStore,
            actual, MonitorMediaGalleryOpen(records.first(), records, token), connectionOwner,
            sourceCurrent = { library === actual && action.sourceIsCurrent },
            captureRecord = { record -> val captured = libraryActions.capture(listOf(record.payload))
                MonitorPlaybackAdmission { library === actual && actual.isCurrent(token) && captured.sourceIsCurrent } },
            configuration = { MediaDeliveryConfiguration(selectedLut = capturedLut) },
            lutLabel = { capturedLabel }, beforeFirstIO = { outgoing?.cancelAndJoin() })
        deliveryHost = host
        host.share(records)
    }

    LaunchedEffect(closeRequested) {
        if (!closeRequested) return@LaunchedEffect
        val outgoing = deliveryHost
        outgoing?.cancelAndJoin()
        library?.close()
        onClose()
    }
    BackHandler(enabled = shareInProgress && playingClip == null && viewingPhoto == null) {
        cancelActiveShareOrExitSelection()
    }
    Box(Modifier.fillMaxSize().background(LiveDesign.background)) {
        val selectionHaptics = LocalOperatorHaptics.current
        library?.let { actual ->
            val catalogOperations = galleryOperations(actual)
            val sourcePresentation = MonitorMediaGalleryPresentation(
                projection.result,
                category = com.opencapture.opencine.vocabulary.MediaLibraryTab.valueOf(options.category.name),
                layout = com.opencapture.monitorui.MonitorMediaLayout.valueOf(options.layout.name),
                thumbnailSize = com.opencapture.monitorui.MonitorThumbnailSize.valueOf(options.thumbnailSize.name),
                sort = com.opencapture.opencine.vocabulary.MediaLibrarySort.valueOf(options.sortOrder.name),
                activeFilterCount = filters.activeCount,
                filters = MonitorMediaGalleryFilters(
                    formats = filterOptions.formats.map { it.title }, resolutions = filterOptions.resolutions.map { it.title },
                    photoSizes = filterOptions.photoSizes.map { MonitorMediaFilterChoice(it.name, it.title) },
                    dateWindows = filterOptions.dateWindows.map { MonitorMediaFilterChoice(it.name, it.title) },
                    storage = visibleStorageSlots.map { MonitorMediaFilterChoice(it.storageId.toString(), "SLOT ${it.slotNumber}") },
                    formatSelection = filters.formats.mapTo(linkedSetOf()) { it.title },
                    resolutionSelection = filters.resolutions.mapTo(linkedSetOf()) { it.title },
                    photoSizeSelection = filters.photoSizes.mapTo(linkedSetOf()) { it.name },
                    dateWindow = filters.dateWindow?.name, storageID = filters.storageId?.toString(), dialog = true,
                ), storage = mediaGalleryStorageValues(visibleStorageSlots, filters.storageId),
                navigationClearsSelection = true, filterClearsSelection = true, retainsVisibleSelection = true,
                empty = when (val load = state) {
                    BrowseState.Loading -> MonitorMediaGalleryEmpty(
                        if (librarySource == MediaLibrarySource.CAMERA) "Listing clips on camera…" else "Opening local library…",
                        if (librarySource == MediaLibrarySource.CAMERA) "Querying card storage…" else "Checking persisted complete cache entries…",
                        loading = true,
                    )
                    is BrowseState.Failed -> MonitorMediaGalleryEmpty("Couldn't list media", load.message, retry = true)
                    is BrowseState.Loaded -> MonitorMediaGalleryEmpty(
                        if (librarySource == MediaLibrarySource.CAMERA) "No clips yet" else "No complete cached media",
                        if (librarySource == MediaLibrarySource.CAMERA) "Clips appear here as they're discovered on the card."
                        else "Complete camera media you have opened appears here safely.",
                    )
                },
            )
            MonitorOperatorCatalogScreen(library = actual, brand = "OpenZCine", sourceAvailable = effectiveCameraConnected,
                operations = catalogOperations, presentation = sourcePresentation,
                selectionConfiguration = rememberSelectionInputPolicy(),
                selectionChanged = selectionHaptics::tick,
                navigation = { action -> when (action) {
                    is MonitorMediaGalleryNavigation.Category -> updateOptions(options.copy(category = MediaLibraryCategory.valueOf(action.value.name)))
                    is MonitorMediaGalleryNavigation.Layout -> updateOptions(options.copy(layout = com.opencapture.monitorui.MonitorMediaLayout.valueOf(action.value.name)))
                    is MonitorMediaGalleryNavigation.ThumbnailSize -> updateOptions(options.copy(thumbnailSize = MonitorThumbnailSize.valueOf(action.value.name)))
                    MonitorMediaGalleryNavigation.CycleSort -> {
                        val all = MediaLibrarySortOrder.entries
                        updateOptions(options.copy(sortOrder = all[(all.indexOf(options.sortOrder) + 1) % all.size]))
                    }
                } }, sourceFilter = { action -> when (action) {
                    is MonitorMediaGalleryFilterAction.Format -> filterOptions.formats.firstOrNull { it.title == action.id }
                        ?.let { updateFilters(filters.copy(formats = filters.formats.toMutableSet().apply { if (!add(it)) remove(it) })) }
                    is MonitorMediaGalleryFilterAction.Resolution -> filterOptions.resolutions.firstOrNull { it.title == action.id }
                        ?.let { updateFilters(filters.copy(resolutions = filters.resolutions.toMutableSet().apply { if (!add(it)) remove(it) })) }
                    is MonitorMediaGalleryFilterAction.PhotoSize -> filterOptions.photoSizes.firstOrNull { it.name == action.id }
                        ?.let { updateFilters(filters.copy(photoSizes = filters.photoSizes.toMutableSet().apply { if (!add(it)) remove(it) })) }
                    is MonitorMediaGalleryFilterAction.DateWindow -> filterOptions.dateWindows.firstOrNull { it.name == action.id }
                        ?.let { updateFilters(filters.copy(dateWindow = it.takeUnless { it == filters.dateWindow })) }
                    is MonitorMediaGalleryFilterAction.Storage -> action.id.toLongOrNull()?.let(::toggleStorageSlot)
                    MonitorMediaGalleryFilterAction.Reset -> updateFilters(MediaLibraryFilters())
                } }, facts = { record -> MonitorMediaGalleryFileFacts(record.payload.clip.badgeLabel) },
                cell = { record, cell -> mediaClipCellPresentation(record.payload.clip, record.payload.bucket,
                    record.favorite, hasRawSibling(record.payload.clip), burstByRepresentative[clipKey(record.payload.clip)]?.count,
                    cell.list, cell.selecting, cell.selected) },
                deletionDetail = { progress -> if (progress.total > progress.selectedCount)
                    "${progress.completed} of ${progress.total} files · incl. RAW + copies" else null },
                begin = {}, refresh = { reloadKey += 1 }, close = { closeRequested = true },
                open = { request -> if (actual.isCurrent(request.admission)) open(request.record.payload.clip, request) },
                share = { records, token ->
                    if (actual.isCurrent(token) && !shareInProgress) {
                        deliverySelection = records.map { it.payload }; deliveryAdmission = token; presentNativeDelivery()
                    }
                },
            ) { request ->
                key(request.admission) {
                    ClipArtwork(clip = request.record.payload.clip, source = librarySource,
                        cameraID = request.record.payload.bucket, cameraConnected = effectiveCameraConnected,
                        connectionOwner = connectionOwner, cacheStore = cacheStore, modifier = Modifier.fillMaxSize(),
                        admission = { request.isCurrent })
                }
            }
        }
        if (library == null) com.opencapture.opencine.cameracontrols.MediaEmptyState(
            listing = true,
            subtitle = if (librarySource == MediaLibrarySource.CAMERA) "Querying card storage…" else "Checking persisted complete cache entries…",
            title = if (librarySource == MediaLibrarySource.CAMERA) "Listing clips on camera…" else "Opening local library…",
        )
        shareMessage?.let { message ->
            MediaStatusMessage(
                message = message,
                modifier = Modifier.align(Alignment.BottomCenter).padding(16.dp),
            )
        }

        deliveryHost?.let { NikonMediaDeliveryHostView(it) }

        seriesRepresentative?.let { representative ->
            val actual = openedPhotoLibrary
            val opening = photoOpening
            val members = seriesFrames
            var selectedFrameKey by remember(representative) { mutableStateOf<String?>(null) }
            val selected = members.firstOrNull { it.asset.id.rawValue == selectedFrameKey } ?: members.firstOrNull()
            if (actual != null && opening != null && selected != null) {
                val actualState by actual.state.collectAsState()
                val target = selected.payload
                val raw = rawSibling(loadedClips, target.clip, ::ownerCameraID)?.let { sibling ->
                    actualState.records.firstOrNull { it.payload.clip.libraryKey(it.payload.bucket) == sibling.libraryKey(target.bucket) }
                }
                val action = remember(actual, opening.admission, selected.asset.id) {
                    libraryActions.capture((listOf(selected) + listOfNotNull(raw) + members).map { it.payload })
                }
                MediaStillViewer(cacheStore = cacheStore, library = actual, record = selected, admission = opening.admission,
                    sourceCurrent = { library === actual && action.sourceIsCurrent }, operations = galleryOperations(actual),
                    assist = assists.shared, cameraTransferAvailable = cameraConnected, connectionOwner = connectionOwner,
                    rawRecord = raw, collection = members, selectRecord = { selectedFrameKey = it.asset.id.rawValue },
                    thumbnail = { request, modifier ->
                        ClipArtwork(clip = request.record.payload.clip, source = librarySource,
                            cameraID = request.record.payload.bucket, cameraConnected = effectiveCameraConnected,
                            connectionOwner = connectionOwner, cacheStore = cacheStore, modifier = modifier,
                            admission = { request.isCurrent() })
                    }, onRatingMirrored = ::mirrorRating, onCaptureRatingCompletion = ::captureRatingCompletion,
                    onRatingDiagnostic = onRatingDiagnostic, onResolvedObjectSize = { resolvedClip, resolvedSize ->
                        libraryIndex.rememberResolvedObjectSize(ownerCameraID(resolvedClip), resolvedClip, resolvedSize)
                    }, onDeletedReturning = { admission ->
                        if (library !== actual || !actual.isCurrent(admission)) return@MediaStillViewer
                        val index = members.indexOfFirst { it.asset.id == selected.asset.id }.coerceAtLeast(0)
                        seriesFrames = members.mapNotNull { actual.record(it.asset.id) }
                        photoOpening = MonitorMediaGalleryOpen(opening.record, opening.playlist, admission)
                        if (seriesFrames.isEmpty()) seriesRepresentative = null
                        else selectedFrameKey = seriesFrames[minOf(index, seriesFrames.lastIndex)].asset.id.rawValue
                    }, onClose = { seriesRepresentative = null })
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
            val actual = openedPhotoLibrary
            val opening = photoOpening
            if (actual != null && opening != null) {
                val owner = ownerCameraID(clip)
                val action = remember(actual, opening.id) { libraryActions.capture(listOf(opening.record.payload)) }
                var playbackDeletionReturn by remember(actual, opening.id) {
                    mutableStateOf<MonitorMediaDeletionCompletion?>(null)
                }
                MediaPlaybackScreen(
                    cacheStore = cacheStore,
                    library = actual,
                    playbackRecords = opening.playlist,
                    initialClip = clip,
                    filteredClips = displayedClips,
                    cameraID = owner,
                    cameraTransferAvailable = cameraConnected,
                    connectionOwner = connectionOwner,
                    favoriteIDs = favorites,
                    assists = assists,
                    exposureAssistCameraInput = exposureAssistCameraInput,
                    operatorSettings = operatorSettings,
                    lutLibrary = lutLibrary,
                    frameioController = frameioController,
                    mediaDeliveryCoordinator = mediaDeliveryCoordinator,
                    onToggleFavorite = ::toggleFavorite,
                    onRatingMirrored = ::mirrorRating,
                    onCaptureRatingCompletion = ::captureRatingCompletion,
                    onRatingDiagnostic = onRatingDiagnostic,
                    onResolvedObjectSize = { resolvedClip, resolvedSize ->
                        libraryIndex.rememberResolvedObjectSize(
                            ownerCameraID(resolvedClip),
                            resolvedClip,
                            resolvedSize,
                        )
                    },
                    onClose = {
                        if (photoOpening?.id == opening.id && openedPhotoLibrary === actual) {
                            playingClip = null; photoOpening = null; openedPhotoLibrary = null
                            reloadKey += 1
                        }
                    },
                    opening = opening,
                    sourceCurrent = { library === actual && action.sourceIsCurrent },
                    captureRecord = { record ->
                        val captured = libraryActions.capture(listOf(record.payload))
                        val completed = playbackDeletionReturn
                        val admission = completed?.admission ?: opening.admission
                        MonitorPlaybackAdmission {
                            library === actual && actual.isCurrent(admission) &&
                                (completed == null || completed.isCurrent) && captured.sourceIsCurrent &&
                                library === actual && actual.isCurrent(admission) &&
                                (completed == null || completed.isCurrent)
                        }
                    },
                    captureDeletion = { record, cleanup ->
                        if (librarySource != MediaLibrarySource.CAMERA || !effectiveCameraConnected ||
                            shareInProgress || library !== actual || connectionOwner == null) null else {
                            val selected = listOf(record.payload.clip)
                            val plan = deletionPlan(loadedClips, selected, ::ownerCameraID)
                            val targets = plan.targets.map { NikonLibraryClip(ownerCameraID(it), it) }
                            val capturedAction = libraryActions.capture(targets)
                            val authority = capturedAction.captureDeletionAuthority()
                            val nativeOwner = connectionOwner
                            val browseBinding = actual.binding
                            val browseSource = librarySourceOwner
                            if (authority == null || !authority.isCurrent || !capturedAction.sourceIsCurrent) null else {
                                MonitorOperatorPlaybackDeletionRequest(
                                    com.opencapture.opencine.media.MonitorPlaybackDeletionConfirmation(
                                        title = "Delete clip from camera?",
                                        message = deleteConfirmationMessage(selected, plan)), authority,
                                    perform = perform@{
                                        fun accepted() = librarySource == MediaLibrarySource.CAMERA && effectiveCameraConnected &&
                                            library === actual && connectionOwner == nativeOwner &&
                                            authority.isCurrent && capturedAction.sourceIsCurrent &&
                                            sameDeletionPlan(plan, deletionPlan(loadedClips, selected, ::ownerCameraID)) &&
                                            library === actual && connectionOwner == nativeOwner && authority.isCurrent
                                        if (!accepted() || !cleanup() || !accepted()) return@perform
                                        capturedAction.deleteBatch(targets, deleteObject = { value ->
                                            withContext(Dispatchers.IO) {
                                                SwiftCore.isAvailable && nativeOwner != null && authority.isCurrent &&
                                                    NikonNative.sessionDeleteObject(nativeOwner, value.clip.handle.toInt())
                                            }
                                        }, onProgress = { _, _ -> }, accepted = authority,
                                            preparation = MonitorMediaDeletionPreparation.RETIRE_GALLERY,
                                            prepare = { browseBinding?.let { browseSource?.retireBrowse(it) } },
                                            afterFinish = { completed ->
                                                if (completed.isCompleting && capturedAction.sourceIsCurrent) {
                                                    val updated = withContext(Dispatchers.IO) {
                                                        (offlineCameraIDs.takeIf { it.isNotEmpty() } ?: listOf(cameraID))
                                                            .flatMap { libraryIndex.favoriteIDs(it) }.toSet()
                                                    }
                                                    if (completed.isCompleting && capturedAction.sourceIsCurrent) {
                                                        favorites = updated
                                                        actual.relist(after = completed)
                                                    }
                                                }
                                            })
                                        val completed = authority.completion
                                        if (completed != null && completed.claim == authority.id && completed.isCurrent &&
                                            library === actual && connectionOwner == nativeOwner &&
                                            actual.isCurrent(completed.admission) && completed.isCurrent) {
                                            playbackDeletionReturn = completed
                                        }
                                    })
                            }
                        }
                    },
                )
            }
        }
        viewingPhoto?.let { clip ->
            val actual = openedPhotoLibrary
            val opening = photoOpening
            if (actual != null && opening != null) {
                val actualState by actual.state.collectAsState()
                val raw = rawSibling(loadedClips, clip, ::ownerCameraID)?.let { sibling ->
                    actualState.records.firstOrNull { it.payload.clip.libraryKey(it.payload.bucket) == sibling.libraryKey(opening.record.payload.bucket) }
                }
                val action = remember(actual, opening.admission, opening.record.asset.id) {
                    libraryActions.capture((listOf(opening.record) + listOfNotNull(raw)).map { it.payload })
                }
                MediaStillViewer(cacheStore = cacheStore, library = actual, record = opening.record, admission = opening.admission,
                    sourceCurrent = { library === actual && action.sourceIsCurrent }, operations = galleryOperations(actual),
                    assist = assists.shared, cameraTransferAvailable = cameraConnected, connectionOwner = connectionOwner,
                    rawRecord = raw, onRatingMirrored = ::mirrorRating, onCaptureRatingCompletion = ::captureRatingCompletion,
                    onRatingDiagnostic = onRatingDiagnostic, onResolvedObjectSize = { resolvedClip, resolvedSize ->
                        libraryIndex.rememberResolvedObjectSize(ownerCameraID(resolvedClip), resolvedClip, resolvedSize)
                    }, onClose = { viewingPhoto = null; reloadKey += 1 })
            }
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
                        .monitorMaterial(MonitorMaterial.Compact, RoundedCornerShape(16.dp))
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

/** Existing source APIs map values into the same storage/navigation/form owners used in production. */
@Composable
private fun mediaGalleryStorageValues(slots: List<MediaStorageSlotPresentation>, selected: Long?): List<MonitorMediaGalleryStorage> =
    slots.map { slot ->
        val label = stringResource(R.string.media_storage_slot_label, slot.slotNumber)
        val summary = if (slot.totalGigabytes > 0) stringResource(R.string.media_storage_slot_summary,
            slot.freeGigabytes, slot.totalGigabytes)
            else stringResource(R.string.media_storage_slot_summary_unknown_total, slot.freeGigabytes)
        val active = selected == slot.storageId
        val description = stringResource(if (active) R.string.media_storage_slot_filter_selected_description
            else R.string.media_storage_slot_filter_description, slot.slotNumber, summary)
        MonitorMediaGalleryStorage(slot.storageId.toString(), label, summary, active, description)
    }

@Composable
internal fun MediaStorageSlotSelector(slots: List<MediaStorageSlotPresentation>, selectedStorageId: Long?,
    horizontal: Boolean, onSelect: (Long) -> Unit, modifier: Modifier = Modifier) {
    com.opencapture.opencine.cameracontrols.MonitorMediaGalleryStorageCards(
        mediaGalleryStorageValues(slots, selectedStorageId),
        select = { it.toLongOrNull()?.let(onSelect) }, horizontal = horizontal, modifier = modifier)
}

@Composable
internal fun MediaLibraryRail(category: MediaLibraryCategory, storageSlots: List<MediaStorageSlotPresentation>,
    selectedStorageId: Long?, onCategoryChange: (MediaLibraryCategory) -> Unit, onStorageSelect: (Long) -> Unit,
    showsGridControls: Boolean, layout: MonitorMediaLayout, thumbnailSize: MonitorThumbnailSize,
    onLayoutChange: (MonitorMediaLayout) -> Unit, onThumbnailSizeChange: (MonitorThumbnailSize) -> Unit,
    modifier: Modifier = Modifier) {
    com.opencapture.opencine.cameracontrols.MonitorMediaGalleryNavigationRail(
        category = com.opencapture.opencine.vocabulary.MediaLibraryTab.valueOf(category.name),
        storage = mediaGalleryStorageValues(storageSlots, selectedStorageId),
        selectCategory = { onCategoryChange(MediaLibraryCategory.valueOf(it.name)) },
        selectStorage = { it.toLongOrNull()?.let(onStorageSelect) }, layout = layout, thumbnailSize = thumbnailSize,
        selectLayout = onLayoutChange, selectThumbnailSize = onThumbnailSizeChange,
        showsDisplayControls = showsGridControls, modifier = modifier)
}

@Composable
internal fun MediaFilterDialog(filters: MediaLibraryFilters, options: MediaFilterOptions, storageIds: List<Long>,
    onFiltersChanged: (MediaLibraryFilters) -> Unit, onDismiss: () -> Unit) {
    val haptics = LocalOperatorHaptics.current
    com.opencapture.opencine.cameracontrols.MonitorMediaGalleryFilterDialog(
        filters = MonitorMediaGalleryFilters(formats = options.formats.map { it.title }, resolutions = options.resolutions.map { it.title },
            photoSizes = options.photoSizes.map { MonitorMediaFilterChoice(it.name, it.title) },
            dateWindows = options.dateWindows.map { MonitorMediaFilterChoice(it.name, it.title) },
            storage = storageIds.mapIndexed { index, id -> MonitorMediaFilterChoice(id.toString(), "SLOT ${index + 1}") },
            formatSelection = filters.formats.mapTo(linkedSetOf()) { it.title },
            resolutionSelection = filters.resolutions.mapTo(linkedSetOf()) { it.title },
            photoSizeSelection = filters.photoSizes.mapTo(linkedSetOf()) { it.name },
            dateWindow = filters.dateWindow?.name, storageID = filters.storageId?.toString(), dialog = true),
        hasActiveFilters = filters.activeCount > 0, close = onDismiss,
        action = { action ->
            if (action != MonitorMediaGalleryFilterAction.Reset) haptics.selection()
            when (action) {
                is MonitorMediaGalleryFilterAction.Format -> options.formats.firstOrNull { it.title == action.id }
                    ?.let { onFiltersChanged(filters.copy(formats = filters.formats.toMutableSet().apply { if (!add(it)) remove(it) })) }
                is MonitorMediaGalleryFilterAction.Resolution -> options.resolutions.firstOrNull { it.title == action.id }
                    ?.let { onFiltersChanged(filters.copy(resolutions = filters.resolutions.toMutableSet().apply { if (!add(it)) remove(it) })) }
                is MonitorMediaGalleryFilterAction.PhotoSize -> options.photoSizes.firstOrNull { it.name == action.id }
                    ?.let { onFiltersChanged(filters.copy(photoSizes = filters.photoSizes.toMutableSet().apply { if (!add(it)) remove(it) })) }
                is MonitorMediaGalleryFilterAction.DateWindow -> options.dateWindows.firstOrNull { it.name == action.id }
                    ?.let { onFiltersChanged(filters.copy(dateWindow = it.takeUnless { it == filters.dateWindow })) }
                is MonitorMediaGalleryFilterAction.Storage -> action.id.toLongOrNull()?.let { onFiltersChanged(filters.togglingStorageSlot(it)) }
                MonitorMediaGalleryFilterAction.Reset -> onFiltersChanged(MediaLibraryFilters())
            }
        })
}

/** Platform input facts only; the common selection owner performs hold/sweep/edge policy. */
@Composable
private fun rememberSelectionInputPolicy(): MonitorMediaSelectionConfiguration {
    val density = LocalDensity.current.density
    val input = LocalViewConfiguration.current
    return remember(input.longPressTimeoutMillis, input.touchSlop, density) {
        MonitorMediaSelectionConfiguration(holdMilliseconds = input.longPressTimeoutMillis,
            movementTolerance = input.touchSlop / density, allowsSelectionEntry = true,
            sweepsSideways = false, edgeBand = 72f, maximumEdgeSpeed = 620f,
            edgeCurve = MonitorMediaSelectionConfiguration.EdgeCurve.LINEAR, viewportEdgeLimitRatio = null)
    }
}

/** Thumbnail policy: camera thumbnails when connected, final cached stills only otherwise. */
@Composable
private fun ClipArtwork(
    clip: NikonMediaClipRecord,
    source: MediaLibrarySource,
    cameraID: String,
    cameraConnected: Boolean,
    connectionOwner: Long?,
    cacheStore: MediaCacheStore,
    modifier: Modifier = Modifier,
    admission: () -> Boolean = { true },
) {
    var thumbnail by remember(clip.libraryKey(cameraID), source) { mutableStateOf<ImageBitmap?>(null) }
    LaunchedEffect(clip.libraryKey(cameraID), source, cameraConnected, connectionOwner) {
        if (!admission()) return@LaunchedEffect
        val decoded = withContext(Dispatchers.IO) {
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
        if (admission()) thumbnail = decoded
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
        MonitorIcon(MonitorIcon.FILM, null, Modifier.size(30.dp), LiveDesign.faint)
    }
}

/** Decodes a small still thumbnail only from the validated final cache path. */
private fun cachedStillThumbnail(
    cacheStore: MediaCacheStore,
    cameraID: String,
    clip: NikonMediaClipRecord,
): ImageBitmap? {
    if (clip.contentKind != NikonMediaContentKind.STILL_PHOTO) return null
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

/** A brief in-app result message that remains above the safe bottom edge. */
@Composable
private fun MediaStatusMessage(message: String, modifier: Modifier = Modifier) {
    Text(
        message,
        modifier = modifier.monitorMaterial(MonitorMaterial.Compact, RoundedCornerShape(LiveDesign.CORNER_RADIUS_DP.dp)).padding(12.dp),
        style = chromeStyle(12f, FontWeight.Medium),
        color = LiveDesign.text,
        maxLines = 3,
        overflow = TextOverflow.Ellipsis,
    )
}

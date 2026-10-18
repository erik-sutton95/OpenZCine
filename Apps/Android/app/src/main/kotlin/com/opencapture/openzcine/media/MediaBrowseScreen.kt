package com.opencapture.openzcine.media

import com.opencapture.opencine.cameracontrols.MonitorOperatorMediaDelivery
import com.opencapture.opencine.cameracontrols.MonitorOperatorMediaPresentation
import com.opencapture.opencine.cameracontrols.MonitorOperatorMediaScreen
import com.opencapture.opencine.cameracontrols.MonitorMediaCatalogArtwork
import com.opencapture.opencine.cameracontrols.MonitorMediaGalleryPresentation
import com.opencapture.opencine.cameracontrols.MonitorMediaGalleryEmpty
import com.opencapture.opencine.cameracontrols.MonitorMediaGalleryFilters
import com.opencapture.opencine.cameracontrols.MonitorMediaGalleryFileFacts
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
import com.opencapture.opencine.nikon.NikonMediaClipRecord
import com.opencapture.opencine.nikon.NikonMediaContentKind
import com.opencapture.opencine.nikon.NikonMediaDeletionPlan
import com.opencapture.openzcine.NikonAssists
import com.opencapture.opencine.appkit.LocalOperatorHaptics
import android.content.Context
import androidx.compose.foundation.background
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
import androidx.compose.ui.platform.LocalContext
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
import com.opencapture.opencine.cameracontrols.MonitorOperatorDeliveryHost
import com.opencapture.opencine.frameio.FrameioInternetHopState
import com.opencapture.openzcine.lut.AndroidLutLibrary
import com.opencapture.opencine.nikon.CameraStorageSlotStatus
import com.opencapture.openzcine.settings.OperatorSettings
import java.nio.file.Files
import java.nio.file.LinkOption
import kotlinx.coroutines.Dispatchers
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
            "$filename · $date · ${clip.sizeLabel.ifEmpty { "unknown size" }}"
        }.toMutableList()
    val omitted = clips.size - lines.size
    if (omitted > 0) lines += "+$omitted more selected ${if (omitted == 1) "item" else "items"}"
    return lines.joinToString(separator = "\n")
}

private const val MAXIMUM_SHARE_METADATA_ITEMS = 32
private const val MAXIMUM_SHARE_METADATA_FILENAME_CHARACTERS = 160

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
    mediaDelivery: NikonMediaDelivery,
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
    val internetHopState = mediaDelivery.frameio.internetHopState
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
    // Connection owns source. Category / layout / sort / thumbnail size are the library's, persisted.
    val librarySource = mediaLibrarySourceForConnection(effectiveCameraConnected)
    // Videos from cinema, Photos from photography: applied once to the first library of this open.
    var pendingCategory by remember(cameraID) { mutableStateOf(initialCategory) }
    // Offline multi-camera library: object key → owning cache bucket cameraID.
    var offlineClipOwners by
        remember(cameraID, offlineCameraIDs) { mutableStateOf(emptyMap<String, String>()) }
    fun ownerCameraID(clip: NikonMediaClipRecord): String =
        offlineClipOwners[clip.offlineObjectKey()] ?: cameraID
    fun clipKey(clip: NikonMediaClipRecord): String = clip.libraryKey(ownerCameraID(clip))
    var state by remember(cameraID) { mutableStateOf<BrowseState>(BrowseState.Loading) }
    var reloadKey by remember { mutableIntStateOf(0) }
    var closeRequested by remember { mutableStateOf(false) }
    var autoPlayHandled by remember { mutableStateOf(false) }
    var autoPlay by remember { mutableStateOf<MonitorMediaGalleryOpen<NikonLibraryClip>?>(null) }
    /** Opens the first playable proxy once, as a tap would, when [autoPlayFirstProxy] asks for it. */
    fun stageAutoPlay(actual: MonitorMediaLibraryModel<NikonLibraryClip>, records: List<MonitorMediaRecord<NikonLibraryClip>>) {
        if (!autoPlayFirstProxy || autoPlayHandled) return
        autoPlayHandled = true
        val first = records.firstOrNull { it.payload.clip.contentKind == NikonMediaContentKind.PLAYABLE_PROXY } ?: return
        autoPlay = MonitorMediaGalleryOpen(first,
            records.filter { it.facts.playbackEligible != false &&
                (it.facts.presentationKind ?: it.asset.kind) == first.asset.kind }, actual.actionToken)
    }
    var deliverySelection by remember(cameraID) { mutableStateOf<List<NikonLibraryClip>>(emptyList()) }
    var deliveryAdmission by remember(cameraID) { mutableStateOf<MonitorMediaLibraryActionToken?>(null) }
    var deliveryPopup by remember { mutableStateOf<NikonDeliverySelection?>(null) }
    val deliveryState by mediaDelivery.coordinator.lifetime.state.collectAsState()
    val shareInProgress = deliveryState.running
    var filters by remember(cameraID) { mutableStateOf(MediaLibraryFilters()) }
    var browseStorageSlots by
        remember(cameraID) { mutableStateOf<List<CameraStorageSlotStatus>?>(null) }

    fun updateFilters(updated: MediaLibraryFilters) {
        filters = updated
    }

    fun exitSelection() {
        library?.clearSelection()
        deliverySelection = emptyList(); deliveryAdmission = null
    }


    LaunchedEffect(cameraID, mediaService, offlineCameraIDs, librarySource,
        effectiveCameraConnected, reloadKey, cacheRevision) {
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
                catalogBase = MonitorMediaCatalogBase.FRESH_LISTING,
                viewOptions = libraryIndex.mediaPreferences(cameraID))
            owner.visibility(MonitorMediaLibraryVisibility.ALL_RECORDS)
            pendingCategory?.let { owner.filter(category = MonitorMediaCategoryFilter.valueOf(it.name)); pendingCategory = null }
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
            // The offline library opens its first clip too (a staged `ReviewLaunch(screen: .playback)`).
            stageAutoPlay(actual, actual.state.value.records)
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
                if (!snapshot.fetching) stageAutoPlay(actual, snapshot.records)
            }
        }
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
    // The library's records carry the favorite flag (local favorites and mirrored star writes).
    val favorites = remember(libraryState.records) {
        libraryState.records.filter { it.favorite }.mapTo(linkedSetOf()) { it.payload.clip.libraryKey(it.payload.bucket) }
    }
    // A captured neutral pass supplies options, sorted survivors and grid representatives together.
    val projection = remember(loadedClips, libraryState.category, favorites, cameraID,
        libraryState.sort, filters, offlineClipOwners, libraryState.records) {
        val actualIDs = libraryState.records.associate {
            it.payload.clip.libraryKey(it.payload.bucket) to it.asset.id
        }
        NikonAppGalleryProjection(loadedClips, actualIDs, MediaLibraryCategory.valueOf(libraryState.category.name), favorites,
            cameraID, libraryState.sort, filters, libraryKey = ::clipKey, ownerOf = ::ownerCameraID)
    }
    val displayedClips = projection.displayedClips
    val filterOptions = projection.filterOptions
    // Only an operator navigation prunes, never a discovery batch: chips derived from a listing
    // that is still streaming in must not clear a selection the operator just made.
    LaunchedEffect(libraryState.category, librarySource) {
        val retained = filters.retainingOfferedChips(filterOptions)
        if (retained != filters) filters = retained
    }
    val burstSeries = projection.legacyGroups
    val burstByRepresentative = remember(burstSeries) { burstSeries.associateBy { it.representativeID } }
    fun burstMembers(representative: NikonMediaClipRecord): List<NikonMediaClipRecord> =
        projection.members(representative, ::clipKey)
    val selectedLut = assists.lut
    val selectedLutLabel =
        when (selectedLut) {
            is FeedLutSelection.BuiltIn -> selectedLut.value.label
            is FeedLutSelection.Stored -> lutLibrary.displayName(selectedLut.value)
        }

    // The heart is a local flag, as in Pocket and Insta. It never writes the camera's star rating:
    // that is the operator's data on the card. A star write still mirrors into the favorites.
    fun toggleFavorite(clip: NikonMediaClipRecord) {
        val value = NikonLibraryClip(ownerCameraID(clip), clip)
        libraryActions.capture(listOf(value)).toggleFavorite(value)
    }

    // Mirrors a camera star write (viewer/player, seed-read or set) into the local favorite set
    // so the Favorites tab surfaces rated shots. iOS `mirrorRatingIntoIndex`.
    fun captureRatingCompletion(clip: NikonMediaClipRecord): NikonMediaRatingCompletion =
        libraryActions.captureRatingCompletion(NikonLibraryClip(ownerCameraID(clip), clip)) {}
    fun mirrorRating(clip: NikonMediaClipRecord, stars: Int) { captureRatingCompletion(clip).mirror(stars) }

    /** [presentation] keeps a still viewer's own deletion from closing it when the gallery relists. */
    fun galleryOperations(actual: MonitorMediaLibraryModel<NikonLibraryClip>,
        presentation: MonitorOperatorMediaPresentation<NikonLibraryClip>? = null,
    ): MonitorMediaGalleryOperations<NikonLibraryClip> = MonitorMediaGalleryOperations<NikonLibraryClip>(
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
                val targets = NikonMediaDeletionPlan.of(loadedClips, rows.map { it.payload.clip }, ::ownerCameraID).targets
                libraryActions.capture(targets.map { NikonLibraryClip(ownerCameraID(it), it) }).captureDeletionAuthority()
            }, perform = { rows, authority ->
                val targets = NikonMediaDeletionPlan.of(loadedClips, rows.map { it.payload.clip }, ::ownerCameraID).targets
                    .map { NikonLibraryClip(ownerCameraID(it), it) }
                val action = libraryActions.capture(targets)
                val nativeOwner = connectionOwner
                val browseBinding = actual.binding
                val browseSource = librarySourceOwner
                suspend fun run() {
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
                            if (completed.isCompleting && action.sourceIsCurrent) actual.relist(after = completed)
                        })
                }
                if (presentation != null) presentation.retaining { run() } else run()
            },
        ),
    )

    fun presentNativeDelivery() {
        val actual = library ?: return
        val token = deliveryAdmission ?: return
        // The share callback sets the selection and presents in one step: read the state, not the
        // value this composition captured, which still holds the previous (empty) selection then.
        if (shareInProgress || deliverySelection.isEmpty() || !actual.isCurrent(token)) return
        val records = deliverySelection.mapNotNull { selected -> actual.state.value.records.firstOrNull {
            it.payload.bucket == selected.bucket && sameNikonActionContent(it.payload.clip, selected.clip)
        } }
        if (records.size != deliverySelection.size || records.isEmpty()) return
        val action = libraryActions.capture(records.map { it.payload })
        if (!action.sourceIsCurrent || !actual.isCurrent(token)) return
        val capturedLut = selectedLut.takeIf { selectedLutLabel != null }
        val capturedLabel = selectedLutLabel
        deliveryPopup = mediaDelivery.selection(records, actual, MonitorMediaGalleryOpen(records.first(), records, token),
            connectionOwner, sourceCurrent = { library === actual && action.sourceIsCurrent },
            captureRecord = { record -> val captured = libraryActions.capture(listOf(record.payload))
                MonitorPlaybackAdmission { library === actual && actual.isCurrent(token) && captured.sourceIsCurrent } },
            selectedLut = capturedLut, lutLabel = capturedLabel)
    }

    /** A still shares through the same delivery popup as clips (A4-18). */
    fun presentStillDelivery(record: MonitorMediaRecord<NikonLibraryClip>, actual: MonitorMediaLibraryModel<NikonLibraryClip>,
        opening: MonitorMediaGalleryOpen<NikonLibraryClip>, sourceIsCurrent: () -> Boolean) {
        if (shareInProgress || !actual.isCurrent(opening.admission)) return
        deliveryPopup = mediaDelivery.selection(listOf(record), actual, opening, connectionOwner,
            sourceCurrent = { library === actual && sourceIsCurrent() },
            captureRecord = { MonitorPlaybackAdmission { library === actual && actual.isCurrent(opening.admission) && sourceIsCurrent() } },
            selectedLut = selectedLut.takeIf { selectedLutLabel != null }, lutLabel = selectedLutLabel)
    }

    LaunchedEffect(closeRequested) {
        if (!closeRequested) return@LaunchedEffect
        // A delivery run belongs to the app, not this gallery: it continues after close (A4-10).
        library?.close()
        onClose()
    }
    Box(Modifier.fillMaxSize().background(LiveDesign.background)) {
        library?.let { actual ->
            val host = remember(actual) { MonitorOperatorMediaHost(actual) }
            LaunchedEffect(host, autoPlay) { autoPlay?.let { if (host.open(it) || !actual.isCurrent(it.admission)) autoPlay = null } }
            val sourcePresentation = MonitorMediaGalleryPresentation(
                projection.result,
                category = com.opencapture.opencine.vocabulary.MediaLibraryTab.valueOf(libraryState.category.name),
                layout = libraryState.layout, thumbnailSize = libraryState.thumbnailSize,
                sort = com.opencapture.opencine.vocabulary.MediaLibrarySort.valueOf(libraryState.sort.name),
                activeFilterCount = filters.activeCount,
                filters = nikonGalleryFilters(filters, filterOptions,
                    visibleStorageSlots.map { MonitorMediaFilterChoice(it.storageId.toString(), "SLOT ${it.slotNumber}") }),
                storage = mediaGalleryStorageValues(visibleStorageSlots, filters.storageId),
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
            val thumbnail: @Composable (MonitorMediaRecord<NikonLibraryClip>, Modifier, () -> Boolean) -> Unit = { record, modifier, admitted ->
                ClipArtwork(clip = record.payload.clip, source = librarySource,
                    cameraID = record.payload.bucket, cameraConnected = effectiveCameraConnected,
                    connectionOwner = connectionOwner, cacheStore = cacheStore, modifier = modifier, admission = admitted)
            }
            MonitorOperatorMediaScreen(library = actual, title = cameraDisplayName ?: "OpenZCine",
                sourceAvailable = effectiveCameraConnected, operations = galleryOperations(actual),
                facts = { record -> MonitorMediaGalleryFileFacts(record.payload.clip.badgeLabel) },
                close = { closeRequested = true }, begin = {},
                // A camera listing refreshes in place and keeps the grid; anything else lists anew.
                refresh = { if (actual.state.value.browsing && actual.binding != null) actual.refresh() else reloadKey += 1 },
                delivery = MonitorOperatorMediaDelivery(
                    presented = deliveryPopup != null,
                    share = { records, token ->
                        if (actual.isCurrent(token) && !shareInProgress) {
                            deliverySelection = records.map { it.payload }; deliveryAdmission = token; presentNativeDelivery()
                        }
                    }, dismiss = { deliveryPopup = null; exitSelection() }),
                presentation = sourcePresentation,
                sourceFilter = { action -> updateFilters(filters.applying(action, filterOptions)) },
                cell = { record, cell -> mediaClipCellPresentation(record.payload.clip, record.payload.bucket,
                    record.favorite, projection.hasRawSibling(record.payload.clip, ::clipKey),
                    burstByRepresentative[clipKey(record.payload.clip)]?.count, cell.list, cell.selecting, cell.selected) },
                deletionDetail = { progress -> if (progress.total > progress.selectedCount)
                    "${progress.completed} of ${progress.total} files · incl. RAW + copies" else null },
                host = host,
                thumbnail = { request ->
                    key(request.admission) { thumbnail(request.record, Modifier.fillMaxSize()) { request.isCurrent } }
                },
                player = { presentation ->
                    val opening = presentation.request
                    val clip = opening.record.payload.clip
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
                        cameraID = ownerCameraID(clip),
                        cameraTransferAvailable = cameraConnected,
                        connectionOwner = connectionOwner,
                        favoriteIDs = favorites,
                        assists = assists,
                        exposureAssistCameraInput = exposureAssistCameraInput,
                        operatorSettings = operatorSettings,
                        lutLibrary = lutLibrary,
                        mediaDelivery = mediaDelivery,
                        onToggleFavorite = ::toggleFavorite,
                        onRatingMirrored = ::mirrorRating,
                        onCaptureRatingCompletion = ::captureRatingCompletion,
                        onRatingDiagnostic = onRatingDiagnostic,
                        onResolvedObjectSize = { resolvedClip, resolvedSize ->
                            libraryIndex.rememberResolvedObjectSize(ownerCameraID(resolvedClip), resolvedClip, resolvedSize)
                        },
                        // The library stays live under the player; a delete inside it relists by itself.
                        onClose = presentation::close,
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
                                val plan = NikonMediaDeletionPlan.of(loadedClips, selected, ::ownerCameraID)
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
                                                sameDeletionPlan(plan, NikonMediaDeletionPlan.of(loadedClips, selected, ::ownerCameraID)) &&
                                                library === actual && connectionOwner == nativeOwner && authority.isCurrent
                                            if (!accepted() || !cleanup() || !accepted()) return@perform
                                            // The player's own deletion relists the gallery; it stays presented across it.
                                            presentation.retaining {
                                                capturedAction.deleteBatch(targets, deleteObject = { value ->
                                                    withContext(Dispatchers.IO) {
                                                        SwiftCore.isAvailable && nativeOwner != null && authority.isCurrent &&
                                                            NikonNative.sessionDeleteObject(nativeOwner, value.clip.handle.toInt())
                                                    }
                                                }, onProgress = { _, _ -> }, accepted = authority,
                                                    preparation = MonitorMediaDeletionPreparation.RETIRE_GALLERY,
                                                    prepare = { browseBinding?.let { browseSource?.retireBrowse(it) } },
                                                    afterFinish = { completed ->
                                                        if (completed.isCompleting && capturedAction.sourceIsCurrent) actual.relist(after = completed)
                                                    })
                                                val completed = authority.completion
                                                if (completed != null && completed.claim == authority.id && completed.isCurrent &&
                                                    library === actual && connectionOwner == nativeOwner &&
                                                    actual.isCurrent(completed.admission) && completed.isCurrent) {
                                                    playbackDeletionReturn = completed
                                                    presentation.readmit(completed.admission)
                                                }
                                            }
                                        })
                                }
                            }
                        },
                    )
                },
                photo = { presentation ->
                    val opening = presentation.request
                    val clip = opening.record.payload.clip
                    val actualState by actual.state.collectAsState()
                    val operations = galleryOperations(actual, presentation)
                    fun recordOf(member: NikonMediaClipRecord, bucket: String) =
                        actualState.records.firstOrNull { it.payload.clip.libraryKey(it.payload.bucket) == member.libraryKey(bucket) }
                    if (burstByRepresentative[clipKey(clip)] != null) {
                        // A burst representative opens the series view (its other frames are hidden in the grid).
                        var members by remember(opening.id) {
                            mutableStateOf(burstMembers(clip).mapNotNull { recordOf(it, ownerCameraID(it)) })
                        }
                        var selectedFrameKey by remember(opening.id) { mutableStateOf<String?>(null) }
                        val selected = members.firstOrNull { it.asset.id.rawValue == selectedFrameKey } ?: members.firstOrNull()
                        if (selected != null) {
                            val target = selected.payload
                            val raw = NikonMediaDeletionPlan.rawSibling(loadedClips, target.clip, ::ownerCameraID)?.let { recordOf(it, target.bucket) }
                            val action = remember(actual, presentation.admission, selected.asset.id) {
                                libraryActions.capture((listOf(selected) + listOfNotNull(raw) + members).map { it.payload })
                            }
                            MediaStillViewer(cacheStore = cacheStore, library = actual, record = selected, admission = presentation.admission,
                                sourceCurrent = { library === actual && action.sourceIsCurrent }, operations = operations,
                                assist = assists.shared, cameraTransferAvailable = cameraConnected, connectionOwner = connectionOwner,
                                rawRecord = raw, collection = members, selectRecord = { selectedFrameKey = it.asset.id.rawValue },
                                thumbnail = { request, modifier -> thumbnail(request.record, modifier) { request.isCurrent() } },
                                onRatingMirrored = ::mirrorRating, onCaptureRatingCompletion = ::captureRatingCompletion,
                                onRatingDiagnostic = onRatingDiagnostic, onResolvedObjectSize = { resolvedClip, resolvedSize ->
                                    libraryIndex.rememberResolvedObjectSize(ownerCameraID(resolvedClip), resolvedClip, resolvedSize)
                                }, onDeletedReturning = { admission ->
                                    if (library !== actual || !actual.isCurrent(admission)) return@MediaStillViewer
                                    val index = members.indexOfFirst { it.asset.id == selected.asset.id }.coerceAtLeast(0)
                                    members = members.mapNotNull { actual.record(it.asset.id) }
                                    if (members.isEmpty() || !presentation.readmit(admission)) presentation.close()
                                    else selectedFrameKey = members[minOf(index, members.lastIndex)].asset.id.rawValue
                                }, onShare = { record ->
                                    presentStillDelivery(record, actual,
                                        MonitorMediaGalleryOpen(record, listOf(record), presentation.admission)) { action.sourceIsCurrent }
                                }, onClose = presentation::close)
                        }
                    } else {
                        val raw = NikonMediaDeletionPlan.rawSibling(loadedClips, clip, ::ownerCameraID)?.let { recordOf(it, opening.record.payload.bucket) }
                        val action = remember(actual, presentation.admission, opening.record.asset.id) {
                            libraryActions.capture((listOf(opening.record) + listOfNotNull(raw)).map { it.payload })
                        }
                        MediaStillViewer(cacheStore = cacheStore, library = actual, record = opening.record, admission = presentation.admission,
                            sourceCurrent = { library === actual && action.sourceIsCurrent }, operations = operations,
                            assist = assists.shared, cameraTransferAvailable = cameraConnected, connectionOwner = connectionOwner,
                            rawRecord = raw, onRatingMirrored = ::mirrorRating, onCaptureRatingCompletion = ::captureRatingCompletion,
                            onRatingDiagnostic = onRatingDiagnostic, onResolvedObjectSize = { resolvedClip, resolvedSize ->
                                libraryIndex.rememberResolvedObjectSize(ownerCameraID(resolvedClip), resolvedClip, resolvedSize)
                            }, onShare = { record ->
                                presentStillDelivery(record, actual,
                                    MonitorMediaGalleryOpen(record, listOf(record), presentation.admission)) { action.sourceIsCurrent }
                            }, onClose = presentation::close)
                    }
                },
            ) {
                // Popup preparation belongs to the shared host; its accepted run belongs to the root.
            }
        }
        if (library == null) com.opencapture.opencine.cameracontrols.MediaEmptyState(
            listing = true,
            subtitle = if (librarySource == MediaLibrarySource.CAMERA) "Querying card storage…" else "Checking persisted complete cache entries…",
            title = if (librarySource == MediaLibrarySource.CAMERA) "Listing clips on camera…" else "Opening local library…",
        )
        MonitorOperatorDeliveryHost(deliveryPopup, onDismissPopup = { deliveryPopup = null }, mediaDelivery.coordinator)
    }
}

/** The Nikon filter facts as the shared form's values; storage chips are the inserted card slots. */
internal fun nikonGalleryFilters(filters: MediaLibraryFilters, options: MediaFilterOptions,
    storage: List<MonitorMediaFilterChoice>): MonitorMediaGalleryFilters = MonitorMediaGalleryFilters(
    formats = options.formats.map { it.title }, resolutions = options.resolutions.map { it.title },
    photoSizes = options.photoSizes.map { MonitorMediaFilterChoice(it.name, it.title) },
    dateWindows = options.dateWindows.map { MonitorMediaFilterChoice(it.name, it.title) },
    storage = storage,
    formatSelection = filters.formats.mapTo(linkedSetOf()) { it.title },
    resolutionSelection = filters.resolutions.mapTo(linkedSetOf()) { it.title },
    photoSizeSelection = filters.photoSizes.mapTo(linkedSetOf()) { it.name },
    dateWindow = filters.dateWindow?.name, storageID = filters.storageId?.toString(), dialog = true,
)

/** One shared filter form action applied to the Nikon filter facts. */
internal fun MediaLibraryFilters.applying(action: MonitorMediaGalleryFilterAction, options: MediaFilterOptions): MediaLibraryFilters {
    fun <T> Set<T>.toggled(value: T): Set<T> = if (value in this) this - value else this + value
    return when (action) {
        is MonitorMediaGalleryFilterAction.Format -> options.formats.firstOrNull { it.title == action.id }
            ?.let { copy(formats = formats.toggled(it)) }
        is MonitorMediaGalleryFilterAction.Resolution -> options.resolutions.firstOrNull { it.title == action.id }
            ?.let { copy(resolutions = resolutions.toggled(it)) }
        is MonitorMediaGalleryFilterAction.PhotoSize -> options.photoSizes.firstOrNull { it.name == action.id }
            ?.let { copy(photoSizes = photoSizes.toggled(it)) }
        is MonitorMediaGalleryFilterAction.DateWindow -> options.dateWindows.firstOrNull { it.name == action.id }
            ?.let { copy(dateWindow = it.takeUnless { it == dateWindow }) }
        is MonitorMediaGalleryFilterAction.Storage -> action.id.toLongOrNull()?.let(::togglingStorageSlot)
        MonitorMediaGalleryFilterAction.Reset -> MediaLibraryFilters()
    } ?: this
}

/** Existing source APIs map values into the same storage/navigation/form owners used in production. */
@Composable
internal fun mediaGalleryStorageValues(slots: List<MediaStorageSlotPresentation>, selected: Long?): List<MonitorMediaGalleryStorage> =
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
    MonitorMediaCatalogArtwork(
        identity = clip.libraryKey(cameraID) to source,
        reload = cameraConnected to connectionOwner,
        isCurrent = admission,
        modifier = modifier,
        load = {
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
                            MonitorBitmapDecoder.decode(jpeg, MonitorBitmapDecoder.THUMBNAIL_EDGE)
                                ?.upright(orientation)
                                ?.asImageBitmap()
                        }
                    } else {
                        null
                    }
                cameraThumbnail ?: cachedStillThumbnail(cacheStore, cameraID, clip)
            }
        },
    ) {
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
    // The full file carries the orientation header: learn it for the object so the
    // connected grid's (possibly EXIF-stripped) camera thumbs rotate too.
    val orientation =
        MediaExifOrientation.fromFile(entry.finalPath)?.also {
            MediaExifOrientation.learn(clip.libraryKey(cameraID), it)
        }
    return MonitorBitmapDecoder.decode(entry.finalPath.toFile(), MonitorBitmapDecoder.THUMBNAIL_EDGE)
        ?.upright(orientation)?.asImageBitmap()
}

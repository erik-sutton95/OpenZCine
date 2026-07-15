package com.opencapture.openzcine.media

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.displayCutout
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
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
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Text
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
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.opencapture.openzcine.FilmGlyph
import com.opencapture.openzcine.LiveDesign
import com.opencapture.openzcine.bridge.SwiftCore
import com.opencapture.openzcine.chromeClickable
import com.opencapture.openzcine.chromeStyle
import com.opencapture.openzcine.glass
import java.nio.file.LinkOption
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Enumeration cap handed to the facade — at most this many ObjectInfo round
 * trips per listing, so a packed card never wedges the session (the iOS USB
 * lesson: never gate on cataloging a whole card).
 */
private const val MAX_LISTED_OBJECTS = 256

/** Loading / loaded / failed states of one camera or persisted-local listing pass. */
private sealed interface BrowseState {
    data object Loading : BrowseState

    data class Loaded(val clips: List<MediaClipRecord>) : BrowseState

    data class Failed(val message: String) : BrowseState
}

/** Outcome of staging the safe subset of a multi-selection for Android sharing. */
private data class BatchShareResult(
    val staged: List<StagedMediaShare>,
    val incompleteCount: Int,
    val failedCount: Int,
    val firstFailure: String?,
)

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
fun MediaBrowseScreen(
    cameraID: String,
    cameraConnected: Boolean,
    autoPlayFirstProxy: Boolean = false,
    onClose: () -> Unit,
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val cacheStore =
        remember(context) {
            MediaCacheStore(context.noBackupFilesDir.resolve("media-cache").toPath())
        }
    val libraryIndex =
        remember(context) {
            MediaLibraryIndex(SharedPreferencesMediaLibraryPreferences(context))
        }
    val defaultSource = if (cameraConnected) MediaLibrarySource.CAMERA else MediaLibrarySource.LOCAL
    var options by
        remember(cameraID) {
            val restored = libraryIndex.viewOptions(defaultSource)
            mutableStateOf(
                if (cameraConnected) restored else restored.copy(source = MediaLibrarySource.LOCAL),
            )
        }
    var favorites by remember(cameraID) { mutableStateOf(emptySet<String>()) }
    var state by remember(cameraID) { mutableStateOf<BrowseState>(BrowseState.Loading) }
    var reloadKey by remember { mutableIntStateOf(0) }
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

    fun updateOptions(updated: MediaLibraryViewOptions) {
        options = updated
        libraryIndex.saveViewOptions(updated)
        isSelecting = false
        selectedIDs = emptySet()
        readySelectionIDs = emptySet()
        shareMessage = null
    }

    fun exitSelection() {
        isSelecting = false
        selectedIDs = emptySet()
        readySelectionIDs = emptySet()
    }

    LaunchedEffect(cameraID) {
        favorites = withContext(Dispatchers.IO) { libraryIndex.favoriteIDs(cameraID) }
    }

    LaunchedEffect(cameraID, options.source, cameraConnected, reloadKey) {
        state = BrowseState.Loading
        val nextState =
            withContext(Dispatchers.IO) {
                when (options.source) {
                    MediaLibrarySource.CAMERA -> {
                        if (!cameraConnected) {
                            BrowseState.Failed("Reconnect the camera or choose On device media.")
                        } else if (!SwiftCore.isAvailable) {
                            BrowseState.Failed("Camera core is not bundled in this build.")
                        } else {
                            SwiftCore.sessionListMedia(MAX_LISTED_OBJECTS)
                                ?.let { wire ->
                                    val clips = MediaClips.parse(wire)
                                    libraryIndex.rememberCameraListing(cameraID, clips)
                                    BrowseState.Loaded(clips)
                                }
                                ?: BrowseState.Failed("Not connected to a camera.")
                        }
                    }
                    MediaLibrarySource.LOCAL -> {
                        val clips =
                            libraryIndex.persistedClips(cameraID).filter { clip ->
                                runCatching {
                                    cacheStore.completedEntryOrNull(
                                        cameraID,
                                        MediaCacheObjectIdentity(clip),
                                        clip.sizeBytes,
                                    )
                                }.getOrNull() != null
                            }
                        BrowseState.Loaded(clips)
                    }
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

    val loadedClips = (state as? BrowseState.Loaded)?.clips.orEmpty()
    val displayedClips =
        MediaLibraryFiltering.displayed(
            clips = loadedClips,
            category = options.category,
            favoriteIDs = favorites,
            cameraID = cameraID,
            sortOrder = options.sortOrder,
        )
    val selectedClips =
        displayedClips.filter { clip -> clip.libraryKey(cameraID) in selectedIDs }
    val visibleIDs = displayedClips.map { clip -> clip.libraryKey(cameraID) }.toSet()

    LaunchedEffect(visibleIDs) {
        val retained = MediaLibrarySelection.retainVisible(selectedIDs, visibleIDs)
        if (retained != selectedIDs) selectedIDs = retained
        if (retained.isEmpty()) isSelecting = false
    }

    LaunchedEffect(cameraID, selectedClips) {
        readySelectionIDs =
            withContext(Dispatchers.IO) {
                selectedClips.mapNotNull { clip ->
                    val complete =
                        runCatching {
                            cacheStore.completedEntryOrNull(
                                cameraID,
                                MediaCacheObjectIdentity(clip),
                                clip.sizeBytes,
                            )
                        }.getOrNull()
                    clip.libraryKey(cameraID).takeIf { complete != null }
                }.toSet()
            }
    }

    fun toggleFavorite(clip: MediaClipRecord) {
        favorites = libraryIndex.toggleFavorite(cameraID, clip)
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
        isSelecting = true
        selectedIDs = MediaLibrarySelection.begin(clip.libraryKey(cameraID))
        shareMessage = null
    }

    fun toggleSelection(clip: MediaClipRecord) {
        selectedIDs = MediaLibrarySelection.toggle(selectedIDs, clip.libraryKey(cameraID))
    }

    fun beginBatchShare() {
        if (shareInProgress || selectedClips.isEmpty()) return
        val selectionSnapshot = selectedClips
        shareInProgress = true
        shareMessage = null
        shareJob =
            scope.launch {
                try {
                    val result =
                        withContext(Dispatchers.IO) {
                            val stager = MediaShareStager(context.cacheDir.toPath())
                            val staged = mutableListOf<StagedMediaShare>()
                            var incomplete = 0
                            var failed = 0
                            var firstFailure: String? = null
                            selectionSnapshot.forEach { clip ->
                                val entry =
                                    runCatching {
                                        cacheStore.completedEntryOrNull(
                                            cameraID,
                                            MediaCacheObjectIdentity(clip),
                                            clip.sizeBytes,
                                        )
                                    }.getOrNull()
                                if (entry == null) {
                                    incomplete += 1
                                    return@forEach
                                }
                                try {
                                    staged += stager.stage(entry, clip)
                                } catch (error: Exception) {
                                    failed += 1
                                    if (firstFailure == null) firstFailure = error.message
                                }
                            }
                            BatchShareResult(staged, incomplete, failed, firstFailure)
                        }
                    if (result.staged.isEmpty()) {
                        shareMessage =
                            result.firstFailure
                                ?: "Only complete cached media can be shared."
                    } else {
                        context.startActivity(AndroidMediaShareIntent.chooserIntent(context, result.staged))
                        shareMessage =
                            buildString {
                                append("Sharing ${result.staged.size} cached item")
                                if (result.staged.size != 1) append('s')
                                if (result.incompleteCount > 0 || result.failedCount > 0) {
                                    append("; ")
                                    append(result.incompleteCount + result.failedCount)
                                    append(" skipped")
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

    LaunchedEffect(closeRequested) {
        if (!closeRequested) return@LaunchedEffect
        shareJob?.cancelAndJoin()
        withContext(Dispatchers.IO) { SwiftCore.sessionExitMediaMode() }
        onClose()
    }
    BackHandler(enabled = playingClip == null && viewingPhoto == null) {
        if (isSelecting) exitSelection() else closeRequested = true
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

            if (portrait) {
                Column(contentModifier, verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    MediaSourceToggle(
                        selected = options.source,
                        modifier = Modifier.padding(start = 45.dp),
                        onSelect = { source -> updateOptions(options.copy(source = source)) },
                    )
                    MediaCategoryStrip(
                        selected = options.category,
                        modifier = Modifier.padding(start = 45.dp),
                        onSelect = { category -> updateOptions(options.copy(category = category)) },
                    )
                    MediaLibraryHeader(
                        state = state,
                        category = options.category,
                        displayedCount = displayedClips.size,
                        isSelecting = isSelecting,
                        selectedCount = selectedClips.size,
                        readyCount = readySelectionIDs.size,
                        shareInProgress = shareInProgress,
                        layout = options.layout,
                        sortOrder = options.sortOrder,
                        onExitSelection = ::exitSelection,
                        onShare = ::beginBatchShare,
                        onLayoutChange = { layout -> updateOptions(options.copy(layout = layout)) },
                        onSortChange = { sort -> updateOptions(options.copy(sortOrder = sort)) },
                    )
                    MediaLibraryBody(
                        state = state,
                        clips = displayedClips,
                        source = options.source,
                        layout = options.layout,
                        cameraID = cameraID,
                        cameraConnected = cameraConnected,
                        cacheStore = cacheStore,
                        favorites = favorites,
                        isSelecting = isSelecting,
                        selectedIDs = selectedIDs,
                        onOpen = ::open,
                        onBeginSelection = ::beginSelection,
                        onToggleSelection = ::toggleSelection,
                        onSweepSelection = { identities ->
                            selectedIDs = MediaLibrarySelection.addSweep(selectedIDs, identities)
                        },
                        onToggleFavorite = ::toggleFavorite,
                        onRetry = { reloadKey += 1 },
                        modifier = Modifier.weight(1f),
                    )
                }
            } else {
                Row(contentModifier, horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                    MediaLibraryRail(
                        source = options.source,
                        category = options.category,
                        onSourceChange = { source -> updateOptions(options.copy(source = source)) },
                        onCategoryChange = { category -> updateOptions(options.copy(category = category)) },
                        modifier = Modifier.width(164.dp),
                    )
                    Column(
                        Modifier.weight(1f),
                        verticalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        MediaLibraryHeader(
                            state = state,
                            category = options.category,
                            displayedCount = displayedClips.size,
                            isSelecting = isSelecting,
                            selectedCount = selectedClips.size,
                            readyCount = readySelectionIDs.size,
                            shareInProgress = shareInProgress,
                            layout = options.layout,
                            sortOrder = options.sortOrder,
                            onExitSelection = ::exitSelection,
                            onShare = ::beginBatchShare,
                            onLayoutChange = { layout -> updateOptions(options.copy(layout = layout)) },
                            onSortChange = { sort -> updateOptions(options.copy(sortOrder = sort)) },
                        )
                        MediaLibraryBody(
                            state = state,
                            clips = displayedClips,
                            source = options.source,
                            layout = options.layout,
                            cameraID = cameraID,
                            cameraConnected = cameraConnected,
                            cacheStore = cacheStore,
                            favorites = favorites,
                            isSelecting = isSelecting,
                            selectedIDs = selectedIDs,
                            onOpen = ::open,
                            onBeginSelection = ::beginSelection,
                            onToggleSelection = ::toggleSelection,
                            onSweepSelection = { identities ->
                                selectedIDs = MediaLibrarySelection.addSweep(selectedIDs, identities)
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

        playingClip?.let { clip ->
            MediaPlaybackScreen(
                clip = clip,
                cameraID = cameraID,
                onClose = {
                    playingClip = null
                    reloadKey += 1
                },
            )
        }
        viewingPhoto?.let { clip ->
            MediaStillViewer(
                clip = clip,
                cameraID = cameraID,
                onClose = {
                    viewingPhoto = null
                    reloadKey += 1
                },
            )
        }
    }
}

/** Source control shared by the portrait strip and landscape rail. */
@Composable
private fun MediaSourceToggle(
    selected: MediaLibrarySource,
    onSelect: (MediaLibrarySource) -> Unit,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier.glass(RoundedCornerShape(LiveDesign.CORNER_RADIUS_DP.dp)).padding(4.dp),
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        MediaLibrarySource.entries.forEach { source ->
            val active = source == selected
            Text(
                source.title.uppercase(),
                style = chromeStyle(10f, FontWeight.Bold, mono = true),
                color = if (active) LiveDesign.accent else LiveDesign.muted,
                modifier =
                    Modifier.clip(RoundedCornerShape(8.dp))
                        .background(if (active) LiveDesign.accentDim else Color.Transparent)
                        .semantics {
                            contentDescription = "Show ${source.title} media"
                            role = Role.Tab
                        }.chromeClickable { onSelect(source) }
                        .padding(horizontal = 10.dp, vertical = 8.dp),
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

/** Landscape navigation rail. */
@Composable
private fun MediaLibraryRail(
    source: MediaLibrarySource,
    category: MediaLibraryCategory,
    onSourceChange: (MediaLibrarySource) -> Unit,
    onCategoryChange: (MediaLibraryCategory) -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier.glass(RoundedCornerShape(LiveDesign.CORNER_RADIUS_DP.dp)).padding(4.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        MediaLibrarySource.entries.forEach { candidate ->
            val active = candidate == source
            Text(
                candidate.title.uppercase(),
                style = chromeStyle(10f, FontWeight.Bold, mono = true),
                color = if (active) LiveDesign.accent else LiveDesign.muted,
                modifier =
                    Modifier.fillMaxWidth()
                        .clip(RoundedCornerShape(8.dp))
                        .background(if (active) LiveDesign.accentDim else Color.Transparent)
                        .semantics {
                            contentDescription = "Show ${candidate.title} media"
                            role = Role.Tab
                        }.chromeClickable { onSourceChange(candidate) }
                        .padding(horizontal = 12.dp, vertical = 9.dp),
            )
        }
        Spacer(Modifier.heightIn(min = 4.dp))
        MediaLibraryCategory.entries.forEach { candidate ->
            MediaCategoryButton(
                category = candidate,
                active = candidate == category,
                onClick = { onCategoryChange(candidate) },
            )
        }
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

/** Main title/header controls, or the bounded selection and delivery bar. */
@Composable
private fun MediaLibraryHeader(
    state: BrowseState,
    category: MediaLibraryCategory,
    displayedCount: Int,
    isSelecting: Boolean,
    selectedCount: Int,
    readyCount: Int,
    shareInProgress: Boolean,
    layout: MediaLibraryLayout,
    sortOrder: MediaLibrarySortOrder,
    onExitSelection: () -> Unit,
    onShare: () -> Unit,
    onLayoutChange: (MediaLibraryLayout) -> Unit,
    onSortChange: (MediaLibrarySortOrder) -> Unit,
) {
    if (isSelecting) {
        SelectionHeader(
            selectedCount = selectedCount,
            readyCount = readyCount,
            shareInProgress = shareInProgress,
            onExit = onExitSelection,
            onShare = onShare,
        )
        return
    }

    Row(
        Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
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
        SortControl(sortOrder = sortOrder, onSelect = onSortChange)
        LayoutControl(layout = layout, onToggle = onLayoutChange)
    }
}

/** Selection-only header; delivery remains disabled until at least one final cache exists. */
@Composable
private fun SelectionHeader(
    selectedCount: Int,
    readyCount: Int,
    shareInProgress: Boolean,
    onExit: () -> Unit,
    onShare: () -> Unit,
) {
    Row(
        Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Text(
            "Cancel",
            style = chromeStyle(13f, FontWeight.SemiBold),
            color = LiveDesign.muted,
            modifier =
                Modifier.glass(CircleShape)
                    .semantics { contentDescription = "Exit media selection" }
                    .chromeClickable(onExit)
                    .padding(horizontal = 12.dp, vertical = 9.dp),
        )
        Text(
            "$selectedCount selected",
            modifier = Modifier.weight(1f),
            style = chromeStyle(20f, FontWeight.SemiBold),
            color = LiveDesign.text,
            maxLines = 1,
        )
        val enabled = readyCount > 0 && !shareInProgress
        Text(
            if (shareInProgress) "PREPARING…" else "SHARE $readyCount",
            style = chromeStyle(11f, FontWeight.Bold, mono = true),
            color = if (enabled) LiveDesign.accent else LiveDesign.faint,
            modifier =
                Modifier.glass(CapsuleShape)
                    .semantics {
                        contentDescription = "Share $readyCount complete cached media items"
                        role = Role.Button
                    }.chromeClickable(enabled) { onShare() }
                    .padding(horizontal = 12.dp, vertical = 9.dp),
        )
    }
}

/** Sort popup uses explicit menu choices rather than cycling a hidden state. */
@Composable
private fun SortControl(sortOrder: MediaLibrarySortOrder, onSelect: (MediaLibrarySortOrder) -> Unit) {
    var expanded by remember { mutableStateOf(false) }
    Box {
        Text(
            "${sortOrder.title.uppercase()} ▾",
            style = chromeStyle(10f, FontWeight.Bold, mono = true),
            color = LiveDesign.muted,
            modifier =
                Modifier.glass(CapsuleShape)
                    .semantics { contentDescription = "Sort media: ${sortOrder.title}" }
                    .chromeClickable { expanded = true }
                    .padding(horizontal = 10.dp, vertical = 9.dp),
        )
        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            MediaLibrarySortOrder.entries.forEach { order ->
                DropdownMenuItem(
                    text = { Text(order.title) },
                    onClick = {
                        expanded = false
                        onSelect(order)
                    },
                )
            }
        }
    }
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

/** Body chooses state, grid, or list without changing the data source. */
@Composable
private fun MediaLibraryBody(
    state: BrowseState,
    clips: List<MediaClipRecord>,
    source: MediaLibrarySource,
    layout: MediaLibraryLayout,
    cameraID: String,
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
    onRetry: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Box(modifier) {
        when (state) {
            BrowseState.Loading -> ListingState(source)
            is BrowseState.Failed -> FailedState(state.message, onRetry)
            is BrowseState.Loaded ->
                if (clips.isEmpty()) {
                    EmptyState(source)
                } else if (layout == MediaLibraryLayout.GRID) {
                    MediaClipGrid(
                        clips = clips,
                        source = source,
                        cameraID = cameraID,
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
                        cameraID = cameraID,
                        cameraConnected = cameraConnected,
                        cacheStore = cacheStore,
                        favorites = favorites,
                        isSelecting = isSelecting,
                        selectedIDs = selectedIDs,
                        onOpen = onOpen,
                        onBeginSelection = onBeginSelection,
                        onToggleSelection = onToggleSelection,
                        onToggleFavorite = onToggleFavorite,
                    )
                }
        }
    }
}

/** Adaptive grid with long-press selection and a selection-mode drag sweep. */
@Composable
private fun MediaClipGrid(
    clips: List<MediaClipRecord>,
    source: MediaLibrarySource,
    cameraID: String,
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
    val currentFrames by rememberUpdatedState(cellFrames.toMap())
    val currentOrigin by rememberUpdatedState(gridOrigin)
    val currentSweep by rememberUpdatedState(onSweepSelection)

    LaunchedEffect(clips) { cellFrames.clear() }
    val sweepModifier =
        if (isSelecting) {
            Modifier.pointerInput(Unit) {
                detectDragGestures(
                    onDragStart = { point ->
                        hitClipID(currentFrames, currentOrigin, point)?.let { identity ->
                            currentSweep(setOf(identity))
                        }
                    },
                    onDrag = { change, _ ->
                        hitClipID(currentFrames, currentOrigin, change.position)?.let { identity ->
                            currentSweep(setOf(identity))
                        }
                    },
                )
            }
        } else {
            Modifier
        }

    LazyVerticalGrid(
        columns = GridCells.Adaptive(minSize = 150.dp),
        modifier =
            Modifier.fillMaxSize()
                .onGloballyPositioned { coordinates -> gridOrigin = coordinates.positionInRoot() }
                .then(sweepModifier),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
        contentPadding = PaddingValues(bottom = 28.dp),
        // Drag sweep owns one-finger movement in selection mode. Exiting the
        // mode immediately returns ordinary scrolling.
        userScrollEnabled = !isSelecting,
    ) {
        items(clips, key = { clip -> clip.libraryKey(cameraID) }) { clip ->
            val identity = clip.libraryKey(cameraID)
            MediaClipCell(
                clip = clip,
                source = source,
                cameraID = cameraID,
                cameraConnected = cameraConnected,
                cacheStore = cacheStore,
                favorite = identity in favorites,
                selected = identity in selectedIDs,
                isSelecting = isSelecting,
                onClick = {
                    if (isSelecting) onToggleSelection(clip) else onOpen(clip)
                },
                onLongPress = { onBeginSelection(clip) },
                onToggleFavorite = { onToggleFavorite(clip) },
                modifier =
                    Modifier.onGloballyPositioned { coordinates ->
                        cellFrames[identity] = coordinates.boundsInRoot()
                    },
            )
        }
    }
}

/** List arrangement uses the same core-authorized records and favorite state. */
@Composable
private fun MediaClipList(
    clips: List<MediaClipRecord>,
    source: MediaLibrarySource,
    cameraID: String,
    cameraConnected: Boolean,
    cacheStore: MediaCacheStore,
    favorites: Set<String>,
    isSelecting: Boolean,
    selectedIDs: Set<String>,
    onOpen: (MediaClipRecord) -> Unit,
    onBeginSelection: (MediaClipRecord) -> Unit,
    onToggleSelection: (MediaClipRecord) -> Unit,
    onToggleFavorite: (MediaClipRecord) -> Unit,
) {
    LazyColumn(
        Modifier.fillMaxSize(),
        verticalArrangement = Arrangement.spacedBy(8.dp),
        contentPadding = PaddingValues(bottom = 28.dp),
    ) {
        items(clips, key = { clip -> clip.libraryKey(cameraID) }) { clip ->
            val identity = clip.libraryKey(cameraID)
            MediaClipListRow(
                clip = clip,
                source = source,
                cameraID = cameraID,
                cameraConnected = cameraConnected,
                cacheStore = cacheStore,
                favorite = identity in favorites,
                selected = identity in selectedIDs,
                isSelecting = isSelecting,
                onClick = {
                    if (isSelecting) onToggleSelection(clip) else onOpen(clip)
                },
                onLongPress = { onBeginSelection(clip) },
                onToggleFavorite = { onToggleFavorite(clip) },
            )
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
                }.combinedClickable(
                    onClick = onClick,
                    onLongClick = onLongPress,
                    onLongClickLabel = "Select ${clip.filename}",
                ),
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
            if (source == MediaLibrarySource.LOCAL) {
                Text(
                    "ON DEVICE",
                    style = chromeStyle(8f, FontWeight.Bold, mono = true),
                    color = LiveDesign.muted,
                    modifier =
                        Modifier.align(Alignment.BottomStart)
                            .padding(7.dp)
                            .badgeBackground()
                            .padding(horizontal = 5.dp, vertical = 3.dp),
                )
            }
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
) {
    Row(
        Modifier.fillMaxWidth()
            .clip(RoundedCornerShape(LiveDesign.CORNER_RADIUS_DP.dp))
            .background(if (selected) LiveDesign.accentDim else LiveDesign.surface)
            .border(
                if (selected) 2.dp else 1.dp,
                if (selected) LiveDesign.accent else LiveDesign.hairline,
                RoundedCornerShape(LiveDesign.CORNER_RADIUS_DP.dp),
            ).semantics {
                contentDescription = clipAccessibilityLabel(clip, selected, isSelecting)
                role = Role.Button
            }.combinedClickable(
                onClick = onClick,
                onLongClick = onLongPress,
                onLongClickLabel = "Select ${clip.filename}",
            ).padding(8.dp),
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
            if (source == MediaLibrarySource.LOCAL) {
                Text(
                    "ON DEVICE",
                    style = chromeStyle(9f, FontWeight.Bold, mono = true),
                    color = LiveDesign.faint,
                )
            }
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
            if (source == MediaLibrarySource.CAMERA) "No media yet" else "No complete cached media",
            style = chromeStyle(15f, FontWeight.Medium),
            color = LiveDesign.muted,
        )
        Text(
            if (source == MediaLibrarySource.CAMERA) {
                "Media appears here as the card is listed."
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
        MediaLibraryCategory.ALL -> "All media"
        MediaLibraryCategory.VIDEOS -> "Videos"
        MediaLibraryCategory.PHOTOS -> "Photos"
        MediaLibraryCategory.FAVORITES -> "Favorites"
    }

private fun itemCountLabel(state: BrowseState, displayedCount: Int): String =
    when (state) {
        BrowseState.Loading -> "Scanning…"
        is BrowseState.Failed -> "—"
        is BrowseState.Loaded -> "$displayedCount item${if (displayedCount == 1) "" else "s"}"
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

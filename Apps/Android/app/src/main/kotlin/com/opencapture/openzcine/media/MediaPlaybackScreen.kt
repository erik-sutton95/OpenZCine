@file:androidx.media3.common.util.UnstableApi

package com.opencapture.openzcine.media
import com.opencapture.monitorui.MonitorAssistTool
import com.opencapture.openzcine.NikonAssistChip
import com.opencapture.openzcine.NikonAssistInspector
import com.opencapture.openzcine.NikonAssistPalette
import com.opencapture.openzcine.NikonAssists
import com.opencapture.openzcine.feedEffects
import com.opencapture.openzcine.feedEffectsConfiguration
import com.opencapture.openzcine.framing
import com.opencapture.openzcine.nikonHasOptions
import com.opencapture.openzcine.nikonPlaybackAssistTools
import com.opencapture.openzcine.performOperatorHaptic
import com.opencapture.monitorui.MonitorPlaybackZoomBoundary
import com.opencapture.monitorui.MonitorPlaybackActions
import com.opencapture.monitorui.MonitorPlaybackPresentation
import com.opencapture.monitorui.MonitorPlaybackScreen
import com.opencapture.monitorui.MonitorPlaybackPageSlots
import com.opencapture.monitorui.MonitorPlaybackCanvasContext
import com.opencapture.monitorui.MonitorPlaybackPictureGeometry
import com.opencapture.monitorui.MonitorPlaybackToolsContext
import com.opencapture.monitorui.MonitorPlaybackInspectorContext
import com.opencapture.monitorui.MonitorEditingCancellation
import com.opencapture.opencine.appkit.MonitorMediaLibraryModel
import com.opencapture.opencine.appkit.MonitorMediaPlaybackModel
import com.opencapture.opencine.appkit.MonitorMediaRecord
import com.opencapture.opencine.media.MonitorPlaybackEvent
import com.opencapture.opencine.media.MonitorPlaybackMetadata
import com.opencapture.opencine.media.MonitorPlaybackItemToken
import android.net.Uri
import android.os.Build
import android.view.HapticFeedbackConstants
import android.view.LayoutInflater
import android.view.TextureView
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.only
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material.icons.filled.Star
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.Effect
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.Tracks
import androidx.media3.common.VideoFrameProcessor
import androidx.media3.common.VideoSize
import androidx.media3.datasource.DataSource
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.SeekParameters
import androidx.media3.exoplayer.source.ProgressiveMediaSource
import androidx.media3.ui.PlayerView
import com.opencapture.openzcine.AudioMetersOverlay
import com.opencapture.openzcine.ExposureAssistCameraInput
import com.opencapture.openzcine.FalseColorReferenceOverlay
import com.opencapture.openzcine.FeedEffectsRenderer
import com.opencapture.openzcine.FeedEffectsRenderPlan
import com.opencapture.openzcine.FeedEffectsRenderPlanFactory
import com.opencapture.openzcine.FeedLutSelection
import com.opencapture.openzcine.FramingAssistRect
import com.opencapture.openzcine.LiveDesign
import com.opencapture.openzcine.LiveFeedEffectsPresentationState
import com.opencapture.openzcine.LocalFramingAssistOverlay
import com.opencapture.openzcine.PlaybackScopePanels
import com.opencapture.openzcine.R
import com.opencapture.openzcine.bridge.SwiftCore
import com.opencapture.monitorui.MonitorRect
import com.opencapture.openzcine.chromeClickable
import com.opencapture.openzcine.chromeStyle
import com.opencapture.openzcine.diagnostics.AndroidDiagnosticEvent
import com.opencapture.openzcine.glass
import com.opencapture.openzcine.frameio.FrameioArtifactContext
import com.opencapture.openzcine.frameio.FrameioDeliveryArtifact
import com.opencapture.openzcine.frameio.FrameioDeliveryController
import com.opencapture.openzcine.frameio.FrameioDeliveryOptions
import com.opencapture.openzcine.frameio.MediaDeliveryConfiguration
import com.opencapture.openzcine.lut.AndroidLutLibrary
import com.opencapture.openzcine.rememberAndroidThermalTier
import com.opencapture.openzcine.resolveFalseColorReference
import com.opencapture.openzcine.scopesShown
import com.opencapture.openzcine.settings.LocalFramingAssistConfiguration
import com.opencapture.openzcine.settings.OperatorSettings
import java.nio.file.Files
import kotlin.math.max
import kotlin.math.roundToInt
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import com.opencapture.opencine.nikon.NikonNative

/** A close or clip switch waits for the current Swift-owned transfer to stop. */
private sealed interface PlaybackSessionAction {
    data object Close : PlaybackSessionAction

    data class Navigate(val record: MonitorMediaRecord<NikonLibraryClip>) : PlaybackSessionAction
}

/**
 * Full-screen Android proxy player.
 *
 * The browser supplies its already-filtered library result so previous/next
 * stays within the operator's current view. Kotlin owns only Media3, local
 * gestures, lifecycle, and safe cache presentation; the shared Swift facade
 * remains the authority for media classification, transfer authorization,
 * size resolution, partial reads, and PTP command serialization.
 */
@Composable
internal fun MediaPlaybackScreen(
    library: MonitorMediaLibraryModel<NikonLibraryClip>?,
    playbackRecords: List<MonitorMediaRecord<NikonLibraryClip>>,
    initialClip: MediaClipRecord,
    filteredClips: List<MediaClipRecord>,
    cameraID: String,
    cameraTransferAvailable: Boolean = true,
    /** Native connection owner every camera call is addressed to; null reaches no camera. */
    connectionOwner: Long?,
    favoriteIDs: Set<String>,
    assists: NikonAssists,
    exposureAssistCameraInput: ExposureAssistCameraInput,
    operatorSettings: OperatorSettings,
    lutLibrary: AndroidLutLibrary?,
    frameioController: FrameioDeliveryController,
    mediaDeliveryCoordinator: MediaDeliveryCoordinator,
    onToggleFavorite: (MediaClipRecord) -> Unit,
    /** Mirrors a camera star (seed-read or write) into the local favorite index. */
    onRatingMirrored: (MediaClipRecord, Int) -> Unit = { _, _ -> },
    onCaptureRatingCompletion: ((MediaClipRecord) -> NikonMediaRatingCompletion)? = null,
    /** Records a closed rating-write breadcrumb (attempted / confirmed / refused). */
    onRatingDiagnostic: (AndroidDiagnosticEvent) -> Unit = {},
    onResolvedObjectSize: (MediaClipRecord, Long) -> Unit = { _, _ -> },
    onClose: () -> Unit,
): Unit {
    if (library == null) {
        PlaybackLoading("Preparing media library…")
        return
    }
    val initial = remember(library, initialClip.libraryKey(cameraID)) {
        playbackRecords.firstOrNull { it.payload.bucket == cameraID && it.payload.clip == initialClip }
    }
    if (initial == null) {
        PlaybackFailure("This clip is not in the current media library.")
        return
    }
    val playbackScope = rememberCoroutineScope()
    val session = remember(library, initialClip.libraryKey(cameraID)) {
        NikonPlaybackSession(library, initial, playbackRecords, playbackScope)
    }
    val logicalState by session.owner.state.collectAsState()
    if (logicalState.closed) {
        PlaybackLoading("Closing media playback…")
        return
    }
    val activeClip = logicalState.active?.payload?.clip ?: initialClip
    DisposableEffect(session) { onDispose { session.owner.close() } }
    val playableRecords = playbackRecords.filter { it.payload.clip.contentKind == MediaContentKind.PLAYABLE_PROXY }
    val activeIndex = playableRecords.indexOfFirst { it.asset.id == logicalState.active?.asset?.id }
    val previous = if (activeIndex > 0) playableRecords.getOrNull(activeIndex - 1) else null
    val next = if (activeIndex >= 0) playableRecords.getOrNull(activeIndex + 1) else null
    val activeBucket = logicalState.active?.payload?.bucket ?: cameraID
    val favorite = activeClip.libraryKey(activeBucket) in favoriteIDs

    // Keying the complete session guarantees that a finished close of the old
    // transfer disposes its player/cache work before the next clip is composed.
    key(activeClip.libraryKey(activeBucket)) {
        PlaybackClipSession(
            clip = activeClip,
            session = session,
            playback = session.owner,
            native = session.native,
            itemToken = logicalState.token,
            cameraID = activeBucket,
            cameraTransferAvailable = cameraTransferAvailable,
            connectionOwner = connectionOwner,
            favorite = favorite,
            previous = previous,
            next = next,
            assists = assists,
            exposureAssistCameraInput = exposureAssistCameraInput,
            operatorSettings = operatorSettings,
            lutLibrary = lutLibrary,
            frameioController = frameioController,
            mediaDeliveryCoordinator = mediaDeliveryCoordinator,
            onToggleFavorite = { onToggleFavorite(activeClip) },
            onRatingMirrored = onRatingMirrored,
            onCaptureRatingCompletion = onCaptureRatingCompletion,
            onRatingDiagnostic = onRatingDiagnostic,
            onResolvedObjectSize = onResolvedObjectSize,
            onNavigate = { target -> session.navigate(target, playableRecords) },
            onClose = { session.owner.close(); onClose() },
        )
    }
}

@Composable
private fun PlaybackClipSession(
    session: NikonPlaybackSession,
    playback: MonitorMediaPlaybackModel<NikonLibraryClip, Unit>,
    native: NikonPlaybackNativePort,
    itemToken: MonitorPlaybackItemToken,
    clip: MediaClipRecord,
    cameraID: String,
    cameraTransferAvailable: Boolean,
    connectionOwner: Long?,
    favorite: Boolean,
    previous: MonitorMediaRecord<NikonLibraryClip>?,
    next: MonitorMediaRecord<NikonLibraryClip>?,
    assists: NikonAssists,
    exposureAssistCameraInput: ExposureAssistCameraInput,
    operatorSettings: OperatorSettings,
    lutLibrary: AndroidLutLibrary?,
    frameioController: FrameioDeliveryController,
    mediaDeliveryCoordinator: MediaDeliveryCoordinator,
    onToggleFavorite: () -> Unit,
    onRatingMirrored: (MediaClipRecord, Int) -> Unit,
    onCaptureRatingCompletion: ((MediaClipRecord) -> NikonMediaRatingCompletion)?,
    onRatingDiagnostic: (AndroidDiagnosticEvent) -> Unit,
    onResolvedObjectSize: (MediaClipRecord, Long) -> Unit,
    onNavigate: (MonitorMediaRecord<NikonLibraryClip>) -> Unit,
    onClose: () -> Unit,
) {
    val context = LocalContext.current
    val cacheStore =
        remember(context) {
            MediaCacheStore(context.noBackupFilesDir.resolve("media-cache").toPath())
        }
    val shareCacheDirectory = remember(context) { context.cacheDir.toPath() }
    val deliveryScope = rememberCoroutineScope()
    val currentOnResolvedObjectSize by rememberUpdatedState(onResolvedObjectSize)
    val currentOnNavigate by rememberUpdatedState(onNavigate)
    val coordinator =
        remember(cacheStore, cameraID, clip, cameraTransferAvailable, connectionOwner) {
            MediaTransferCoordinator(
                prepareTransfer = {
                    withContext(Dispatchers.IO) {
                        prepareMediaObjectTransfer(
                            cacheStore = cacheStore,
                            cameraID = cameraID,
                            clip = clip,
                            objectLabel = "clip",
                            bridge = SwiftCoreMediaObjectTransferBridge(connectionOwner),
                            cameraTransferAvailable = cameraTransferAvailable,
                            onResolvedSize = { resolvedSize ->
                                currentOnResolvedObjectSize(clip, resolvedSize)
                            },
                        )
                    }
                },
                stopTransfer = {
                    if (cameraTransferAvailable && connectionOwner != null) {
                        withContext(Dispatchers.IO) {
                            NikonNative.sessionStopMediaTransfer(connectionOwner)
                        }
                    }
                },
            )
        }
    var preparation by remember(clip.handle) {
        mutableStateOf<MediaTransferPreparation>(MediaTransferPreparation.Loading)
    }
    var pendingAction by remember { mutableStateOf<PlaybackSessionAction?>(null) }
    var shareableEntry by remember(clip.handle) { mutableStateOf<MediaCacheEntry?>(null) }
    var shareState by remember(clip.handle) { mutableStateOf(PlaybackShareState.BUFFERING) }
    var deliveryInProgress by remember(clip.handle) { mutableStateOf(false) }
    var deliveryMessage by remember(clip.handle) { mutableStateOf<String?>(null) }
    var deliveryJob by remember(clip.handle) { mutableStateOf<Job?>(null) }
    var deliveryChooserPresented by remember(clip.handle) { mutableStateOf(false) }
    var activePlayer by remember(clip.handle) { mutableStateOf<Player?>(null) }
    val latestDeliveryJob = rememberUpdatedState(deliveryJob)
    val actionInProgress = pendingAction != null
    // Pulled down to rate, and left open across clips until pushed back up — so NOT keyed to the
    // clip, unlike the rating value itself (iOS `ratingShadeOpen`).
    var ratingShadeOpen by remember { mutableStateOf(false) }
    // Camera-read star rating (null until read, or unreachable — row hidden).
    // Seeded by read, confirmed by the entry point's built-in readback: the
    // camera stays source of truth for every write.
    var ratingStars by remember(clip.handle) { mutableStateOf<Int?>(null) }
    // Set when the body refuses a rating write — surfaced with its response code above the star
    // row, never a silent rollback; auto-cleared so it doesn't linger over playback.
    var ratingMessage by remember(clip.handle) { mutableStateOf<String?>(null) }
    val ratingScope = rememberCoroutineScope()
    LaunchedEffect(clip.handle, cameraTransferAvailable, connectionOwner) {
        if (!cameraTransferAvailable || !SwiftCore.isAvailable) return@LaunchedEffect
        val owner = connectionOwner ?: return@LaunchedEffect
        val completion = onCaptureRatingCompletion?.invoke(clip)
        val read =
            withContext(Dispatchers.IO) { NikonNative.sessionObjectRating(owner, clip.handle.toInt()) }
        if (read >= 0 && completion?.isCurrent != false) {
            if (completion != null && !completion.mirror(read)) return@LaunchedEffect
            ratingStars = read
            // Self-correct the local favorite cache against the body (truth) on open.
            if (completion == null) onRatingMirrored(clip, read)
        }
    }
    LaunchedEffect(ratingMessage) {
        if (ratingMessage != null) {
            delay(4000)
            ratingMessage = null
        }
    }
    fun selectRating(target: Int) {
        val previous = ratingStars
        ratingStars = target
        onRatingDiagnostic(AndroidDiagnosticEvent.RATING_WRITE_ATTEMPTED)
        val completion = onCaptureRatingCompletion?.invoke(clip)
        ratingScope.launch {
            val written =
                withContext(Dispatchers.IO) {
                    // -1 = "could not be attempted"; never another camera's card.
                    val owner = connectionOwner ?: return@withContext -1
                    NikonNative.sessionSetObjectRating(owner, clip.handle.toInt(), target)
                }
            when (val outcome = ratingWriteResult(written)) {
                is RatingWriteResult.Confirmed -> {
                    if (completion != null && !completion.mirror(outcome.stars)) return@launch
                    ratingStars = outcome.stars
                    ratingMessage = null
                    if (completion == null) onRatingMirrored(clip, outcome.stars)  // mirror only a confirmed write
                    onRatingDiagnostic(AndroidDiagnosticEvent.RATING_WRITE_CONFIRMED)
                }
                is RatingWriteResult.Refused -> {
                    if (completion?.isCurrent == false) return@launch
                    ratingStars = previous
                    ratingMessage = ratingRefusalMessage(outcome.code)
                    onRatingDiagnostic(
                        if (outcome.code == 0x2013) {
                            AndroidDiagnosticEvent.RATING_WRITE_REFUSED_ACCESS_DENIED
                        } else {
                            AndroidDiagnosticEvent.RATING_WRITE_REFUSED
                        })
                }
            }
        }
    }
    val deliveryLut = assists.lut
    val deliveryLutLabel =
        when (deliveryLut) {
            is FeedLutSelection.BuiltIn -> deliveryLut.value.label
            is FeedLutSelection.Stored -> lutLibrary?.displayName(deliveryLut.value)
        }

    fun requestClose() {
        if (pendingAction == null) pendingAction = PlaybackSessionAction.Close
    }

    fun requestNavigation(target: MonitorMediaRecord<NikonLibraryClip>?) {
        if (target != null && pendingAction == null) {
            pendingAction = PlaybackSessionAction.Navigate(target)
        }
    }

    fun beginShare(configuration: MediaDeliveryConfiguration) {
        if (deliveryInProgress || actionInProgress) return
        session.pauseForDelivery(activePlayer?.isPlaying == true)
        deliveryMessage = null
        mediaDeliveryCoordinator.beginNativeShare(
            selection = listOf(MediaDeliverySelection(cameraID, clip)),
            configuration = configuration,
            cameraConnectionOwner = connectionOwner.takeIf { cameraTransferAvailable },
        ) { published, metadata ->
            context.startActivity(
                AndroidMediaShareIntent.chooserIntent(context, published, metadata),
            )
        }
    }

    fun beginGallerySave(configuration: MediaDeliveryConfiguration) {
        if (deliveryInProgress || actionInProgress) return
        session.pauseForDelivery(activePlayer?.isPlaying == true)
        deliveryMessage = null
        mediaDeliveryCoordinator.beginSaveToPhotos(
            selection = listOf(MediaDeliverySelection(cameraID, clip)),
            configuration = configuration,
            cameraConnectionOwner = connectionOwner.takeIf { cameraTransferAvailable },
        )
    }

    fun beginFrameioDelivery(options: FrameioDeliveryOptions) {
        if (deliveryInProgress || actionInProgress) return
        val playbackPause = session.pauseForDelivery(activePlayer?.isPlaying == true)
        var deliveryTicket: NikonDeliveryPresentation.ExternalTicket? = null
        val job =
            deliveryScope.launch(start = CoroutineStart.LAZY) {
                val stageContext = coroutineContext
                val runningJob = stageContext[Job]
                try {
                    val completedEntry =
                        shareableEntry
                            ?: mediaDeliveryCoordinator
                                .cacheFromCamera(
                                    destination = MediaDeliveryKind.FRAMEIO,
                                    selection = listOf(MediaDeliverySelection(cameraID, clip)),
                                    cameraConnectionOwner =
                                        connectionOwner.takeIf { cameraTransferAvailable },
                                    ticket = deliveryTicket,
                                )
                                .items
                                .firstOrNull()
                                ?.entry
                    if (completedEntry == null) {
                        deliveryMessage = "Couldn't cache this clip from the camera."
                        return@launch
                    }
                    val staged =
                        withContext(Dispatchers.IO) {
                            MediaShareStager(shareCacheDirectory).stage(completedEntry, clip) {
                                stageContext.ensureActive()
                            }
                        }
                    val artifact =
                        FrameioDeliveryArtifact(
                            share = staged,
                            byteCount = withContext(Dispatchers.IO) { Files.size(staged.file) },
                            context =
                                FrameioArtifactContext(
                                    cameraID = cameraID,
                                    captureDate = clip.captureDate,
                                    supportsLutBake = true,
                                    stableClipIdentity = clip.libraryKey(cameraID),
                                ),
                        )
                    val capturedTicket = deliveryTicket
                    frameioController.deliver(listOf(artifact), options) { state ->
                        capturedTicket?.let { mediaDeliveryCoordinator.bindFrameioDeliveryState(it, state) }
                    }
                    deliveryMessage = "Uploaded to Frame.io."
                } catch (error: CancellationException) {
                    throw error
                } catch (error: Exception) {
                    deliveryMessage = error.message ?: "Couldn't deliver this clip to Frame.io."
                } finally {
                    if (pendingAction == null && playbackPause != null) session.resumeAfterDelivery(playbackPause)
                    deliveryTicket?.let { mediaDeliveryCoordinator.finishExternalDelivery(it) }
                    if (deliveryJob === runningJob) {
                        deliveryJob = null
                        deliveryInProgress = false
                    }
                }
            }
        deliveryJob = job
        deliveryMessage = null
        deliveryInProgress = true
        // The overlay narrating this upload lives in the coordinator, and so must its Cancel.
        deliveryTicket = mediaDeliveryCoordinator.trackExternalDelivery(job)
        job.start()
    }

    LaunchedEffect(coordinator) {
        val prepared = coordinator.prepare()
        preparation = prepared
        if (prepared is MediaTransferPreparation.Failed) native.fail(itemToken, prepared.message)
    }

    // A progressive entry is playable before it is deliverable. Poll only the
    // synchronized entry state: no partial `.part` can grow a share action.
    LaunchedEffect(preparation) {
        shareableEntry = null
        deliveryMessage = null
        val entry = (preparation as? MediaTransferPreparation.Ready)?.entry ?: run {
            shareState = PlaybackShareState.UNAVAILABLE
            return@LaunchedEffect
        }
        while (isActive) {
            val nextShareState =
                playbackShareState(
                    state = entry.state,
                    downloadedBytes = entry.downloadedBytes,
                    expectedLength = entry.expectedLength,
                )
            shareState = nextShareState
            if (nextShareState == PlaybackShareState.READY) {
                shareableEntry = entry
                return@LaunchedEffect
            }
            if (nextShareState == PlaybackShareState.UNAVAILABLE) return@LaunchedEffect
            delay(200)
        }
    }

    // Serialize navigation and close behind transfer teardown. Starting the
    // adjacent proxy before the previous PTP transfer stops would violate the
    // one-session camera command boundary the Swift core enforces.
    LaunchedEffect(pendingAction, coordinator) {
        val action = pendingAction ?: return@LaunchedEffect
        deliveryJob?.cancelAndJoin()
        coordinator.close()
        when (action) {
            PlaybackSessionAction.Close -> onClose()
            is PlaybackSessionAction.Navigate -> currentOnNavigate(action.record)
        }
    }

    // Activity teardown can dispose the surface without the in-app back path.
    // Preserve the camera invariant by stopping from a bounded IO coroutine.
    DisposableEffect(coordinator) {
        onDispose {
            val runningDeliveryJob = latestDeliveryJob.value
            val cleanup = CoroutineScope(SupervisorJob() + Dispatchers.IO)
            cleanup.launch {
                try {
                    runningDeliveryJob?.cancelAndJoin()
                    coordinator.close()
                } finally {
                    cleanup.cancel()
                }
            }
        }
    }

    Box(
        Modifier.fillMaxSize()
            .background(Color.Black)
            // This overlay owns every empty pixel; gestures never reach the paused monitor below it.
            .pointerInput(Unit) { detectTapGestures {} },
    ) {
        NikonPlaybackPage(
                    entry = (preparation as? MediaTransferPreparation.Ready)?.entry,
                    preparation = preparation,
                    title = clip.filename,
                    favorite = favorite,
                    previous = previous != null && !actionInProgress,
                    next = next != null && !actionInProgress,
                    onBack = ::requestClose,
                    backEnabled = !actionInProgress,
                    onAdjacent = { offset -> requestNavigation(if (offset < 0) previous else next) },
                    onFavorite = onToggleFavorite,
                    session = session,
                    playback = playback,
                    native = native,
                    itemToken = itemToken,
                    assists = assists,
                    exposureAssistCameraInput = exposureAssistCameraInput,
                    operatorSettings = operatorSettings,
                    lutLibrary = lutLibrary,

                    ratingShadeOpen = ratingShadeOpen,
                    onRatingShadeOpenChanged = { ratingShadeOpen = it },
                    onPlayerChanged = { activePlayer = it },
                    shareReady =
                        canDeliverMedia(
                            readyCount = if (shareState == PlaybackShareState.READY) 1 else 0,
                            clipCount = 1,
                            cameraConnected = cameraTransferAvailable,
                        ),
                    deliveryInProgress = deliveryInProgress,
                    coverPresented = deliveryChooserPresented || deliveryInProgress,
                    onShare = { deliveryChooserPresented = true },
                    ratingStars = ratingStars,
                    ratingMessage = ratingMessage,
                    onSelectRating = ::selectRating,
                )

        if (deliveryChooserPresented) {
            MediaDeliveryPopup(
                clipCount = 1,
                readyCount = if (shareState == PlaybackShareState.READY) 1 else 0,
                cameraConnected = cameraTransferAvailable,
                selectedLut = deliveryLut.takeIf { deliveryLutLabel != null },
                selectedLutLabel = deliveryLutLabel,
                frameioController = frameioController,
                busy = deliveryInProgress,
                onDismiss = { deliveryChooserPresented = false },
                onNativeShare = { configuration ->
                    deliveryChooserPresented = false
                    beginShare(configuration)
                },
                onSaveToGallery = { configuration ->
                    deliveryChooserPresented = false
                    beginGallerySave(configuration)
                },
                onFrameioDeliver = { options ->
                    deliveryChooserPresented = false
                    beginFrameioDelivery(options)
                },
            )
        }

        if (actionInProgress) {
            PlaybackLoading(
                if (pendingAction is PlaybackSessionAction.Navigate) {
                    "Switching camera media…"
                } else {
                    "Closing camera media…"
                },
            )
        }
    }
}

private class NikonNativePlaybackContent(
    val aspect: Float, val buffered: Float, val error: String?,
    val horizontalPresentationScale: Float, val verticalPresentationScale: Float,
    val picture: @Composable (MonitorPlaybackPictureGeometry) -> Unit,
    val canvas: @Composable (MonitorPlaybackCanvasContext) -> Unit,
    val tools: @Composable (MonitorPlaybackToolsContext) -> Unit,
    val inspector: @Composable (MonitorPlaybackInspectorContext) -> Unit,
    val dismissInspector: () -> Boolean,
)

@Composable
private fun NikonPlaybackPage(
    entry: MediaCacheEntry?, preparation: MediaTransferPreparation, title: String,
    favorite: Boolean, previous: Boolean, next: Boolean,
    onBack: () -> Unit, backEnabled: Boolean, onAdjacent: (Int) -> Unit, onFavorite: () -> Unit,
    session: NikonPlaybackSession, playback: MonitorMediaPlaybackModel<NikonLibraryClip, Unit>,
    native: NikonPlaybackNativePort, itemToken: MonitorPlaybackItemToken,
    assists: NikonAssists,
    exposureAssistCameraInput: ExposureAssistCameraInput, operatorSettings: OperatorSettings,
    lutLibrary: AndroidLutLibrary?, ratingShadeOpen: Boolean, onRatingShadeOpenChanged: (Boolean) -> Unit,
    onPlayerChanged: (Player?) -> Unit, shareReady: Boolean, deliveryInProgress: Boolean, coverPresented: Boolean,
    onShare: () -> Unit, ratingStars: Int?, ratingMessage: String?, onSelectRating: (Int) -> Unit,
) {
    val logical by playback.state.collectAsState()
    val hapticView = LocalView.current
    val content = entry?.let {
        rememberNikonNativePlayback(session, playback, native, itemToken, it,
            assists, exposureAssistCameraInput, operatorSettings,
            lutLibrary, onPlayerChanged)
    }
    val presentedPosition = if (logical.scrubbing) logical.scrubPosition else logical.position
    val value = MonitorPlaybackPresentation(
        item = itemToken, title = title, subtitle = "", source = null, metadata = emptyList(),
        aspect = content?.aspect ?: 16f / 9f, ready = logical.ready,
        error = (preparation as? MediaTransferPreparation.Failed)?.message ?: content?.error ?: logical.error,
        progress = entry?.progress,
        position = presentedPosition.toFloat(), duration = (logical.duration ?: 0.0).toFloat(),
        positionLabel = formatPlaybackTime((presentedPosition * 1000.0).toLong()),
        durationLabel = formatPlaybackTime(((logical.duration ?: 0.0) * 1000.0).toLong()),
        playing = logical.reportedPlaying ?: logical.playRequested, reachedEnd = logical.reachedEnd,
        scrubbing = logical.scrubbing, muted = logical.muted, looping = false,
        previous = previous, next = next, favorite = favorite,
        conform = logical.metadata.conform, conformTarget = logical.conformTarget,
        loopAvailable = false, shareEnabled = shareReady && !deliveryInProgress,
        buffered = content?.buffered ?: 0f, doubleTapResetsZoom = true, continuousPanBounds = true,
        zoomBoundary = MonitorPlaybackZoomBoundary.CANVAS,
        horizontalPresentationScale = content?.horizontalPresentationScale ?: 1f,
        verticalPresentationScale = content?.verticalPresentationScale ?: 1f)
    fun admitted(token: MonitorPlaybackItemToken, action: () -> Unit) {
        if (playback.isActive && playback.state.value.token == token) action()
    }
    val actions = MonitorPlaybackActions(
        back = onBack,
        play = { token, play -> admitted(token) { playback.setPlaying(play) } },
        restart = { token -> admitted(token) { playback.restart() } },
        seekBy = { token, delta -> admitted(token) { playback.seekBy(delta) } },
        mute = { token, muted -> admitted(token) { playback.setMuted(muted) } },
        loop = { _, _ -> },
        conform = { token, target -> admitted(token) { playback.setConformTarget(target) } },
        adjacent = { token, offset -> admitted(token) { onAdjacent(offset) } },
        favorite = { token -> admitted(token, onFavorite) },
        share = { token -> admitted(token) { if (shareReady && !deliveryInProgress) onShare() } },
        delete = null,
        beginScrub = { token -> if (playback.isActive && playback.state.value.token == token)
            playback.beginScrub() else null },
        updateScrub = { edit, seconds -> playback.updateScrub(seconds, edit) },
        updateFrameScrub = { edit, delta, width -> playback.updateFrameScrub(delta, width, edit) },
        commitScrub = playback::commitScrub,
        cancelScrub = { edit, why -> playback.cancelScrub(why == MonitorEditingCancellation.INTERRUPTED, edit) },
        longPressFeedback = { hapticView.performOperatorHaptic(HapticFeedbackConstants.LONG_PRESS) },
        dismissAssistInspector = { content?.dismissInspector?.invoke() ?: false })
    MonitorPlaybackScreen(value, actions,
        slots = MonitorPlaybackPageSlots(
            headerAccessory = {
                if (ratingStars != null) {
                    Column(horizontalAlignment = Alignment.CenterHorizontally) {
                        Row(Modifier.size(52.dp, 20.dp).glass(CircleShape)
                            .chromeClickable { onRatingShadeOpenChanged(!ratingShadeOpen) }
                            .semantics { contentDescription = if (ratingShadeOpen) "Hide star rating" else "Show star rating" },
                            horizontalArrangement = Arrangement.Center) {
                            Icon(Icons.Filled.Star, null, tint = LiveDesign.muted, modifier = Modifier.size(11.dp))
                            Icon(if (ratingShadeOpen) Icons.Filled.KeyboardArrowUp else Icons.Filled.KeyboardArrowDown,
                                null, tint = LiveDesign.muted, modifier = Modifier.size(13.dp))
                        }
                        if (ratingShadeOpen) StarRatingRow(stars = ratingStars, onSelect = onSelectRating)
                    }
                }
                if (ratingMessage != null) Text(ratingMessage, color = LiveDesign.text)
            }, canvasDetails = { content?.canvas?.invoke(it) },
            onChromeVisibilityChanged = { if (!it) content?.dismissInspector?.invoke() },
            onAssistExpansionChanged = { if (!it) content?.dismissInspector?.invoke() }),
        coverPresented = coverPresented,
        backHandler = { handle -> BackHandler(enabled = backEnabled, onBack = handle) },
        picture = { content?.picture?.invoke(it) },
        feedAssists = {}, canvasAssists = {},
        tools = { content?.tools?.invoke(it) },
        assistInspector = { content?.inspector?.invoke(it) })
}

@Composable
private fun rememberNikonNativePlayback(
    session: NikonPlaybackSession,
    playback: MonitorMediaPlaybackModel<NikonLibraryClip, Unit>,
    native: NikonPlaybackNativePort,
    itemToken: MonitorPlaybackItemToken,
    entry: MediaCacheEntry,
    assists: NikonAssists,
    exposureAssistCameraInput: ExposureAssistCameraInput,
    operatorSettings: OperatorSettings,
    lutLibrary: AndroidLutLibrary?,
    /** Owned by the parent so it survives clip changes, like the operator left it. */
    onPlayerChanged: (Player?) -> Unit,
    /**
     * Camera-read clip star rating; null means offline or unreadable. The shade shows zero stars
     * in that case rather than nothing — an opened shade that renders empty reads as broken.
     */
    /** Transient rating-write refusal line (with the body's response code); null hides it. */
) : NikonNativePlaybackContent {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    val audioMeterCoordinator = remember(entry, itemToken) { PlaybackAudioMeterCoordinator() }
    val player =
        remember(entry, itemToken, audioMeterCoordinator) {
            val dataSourceFactory = DataSource.Factory { GrowingFileDataSource(entry) }
            ExoPlayer.Builder(context, audioMeterCoordinator.renderersFactory(context)).build().apply {
                setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(C.USAGE_MEDIA)
                        .setContentType(C.AUDIO_CONTENT_TYPE_MOVIE)
                        .build(),
                    true,
                )
                setHandleAudioBecomingNoisy(true)
                setSeekParameters(SeekParameters.EXACT)
                val source =
                    ProgressiveMediaSource.Factory(dataSourceFactory)
                        .createMediaSource(MediaItem.fromUri(Uri.parse("camera-cache://clip")))
                setMediaSource(source)
                // Installing the Media3 video graph before preparation is required for later
                // effect-list replacement on the API 29–32 playback fallback.
                if (Build.VERSION.SDK_INT in 29..32) setVideoEffects(emptyList())
                prepare()
            }
        }
    val playbackAudioLevels by audioMeterCoordinator.levels.collectAsState()
    val audioMetersVisible = assists.shared.isPlaybackVisible(MonitorAssistTool.AUDIO)
    LaunchedEffect(audioMeterCoordinator, audioMetersVisible) {
        if (audioMetersVisible) audioMeterCoordinator.poll()
    }
    val playerView =
        remember(context) {
            LayoutInflater.from(context)
                .inflate(R.layout.playback_player_view, null, false) as PlayerView
        }
    val textureView = remember(playerView) { playerView.videoSurfaceView as? TextureView }
    var attachment by remember(player, itemToken) {
        mutableStateOf<NikonPlaybackNativePort.Attachment?>(null)
    }
    DisposableEffect(player, playerView, itemToken) {
        playerView.player = player
        onPlayerChanged(player)
        val captured = native.attach(
            player, itemToken,
            beforeRelease = {
                onPlayerChanged(null)
                if (playerView.player === player) playerView.player = null
                audioMeterCoordinator.close()
            },
            seekNative = { target, preview ->
                player.setSeekParameters(if (preview) SeekParameters.CLOSEST_SYNC else SeekParameters.EXACT)
                player.seekTo(target)
            },
        )
        attachment = captured
        onDispose { native.detach(captured) }
    }
    // Media3 owns audio focus through the configured movie attributes. Pausing
    // on lifecycle loss prevents an opened chooser or background app from
    // continuing playback; Android deliberately does not auto-resume on return.
    DisposableEffect(lifecycleOwner, player) {
        val observer =
            LifecycleEventObserver { _, event ->
                if (event == Lifecycle.Event.ON_PAUSE && playback.state.value.token == itemToken) {
                    // Original Android policy never resumes merely because the app returns.
                    session.scenePaused(itemToken)
                } else if (event == Lifecycle.Event.ON_RESUME && playback.state.value.token == itemToken) {
                    session.sceneResumed(itemToken)
                }
            }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }

    var bufferedFraction by remember(entry) { mutableFloatStateOf(0f) }
    var playbackState by remember(entry) { mutableIntStateOf(Player.STATE_BUFFERING) }
    var playbackError by remember(entry) { mutableStateOf<PlaybackException?>(null) }
    var videoSize by remember(entry) { mutableStateOf(VideoSize.UNKNOWN) }
    var videoColorMode by
        remember(entry, player) {
            mutableStateOf(selectedPlaybackVideoColorMode(player.currentTracks))
        }
    val playbackFramingConfiguration =
        assists.shared.framing(assists.shared::isPlaybackVisible, operatorSettings.levelStyle)
    val framingAssistsVisible = playbackFramingConfiguration.hasPlaybackFramingOverlay

    DisposableEffect(player, attachment) {
        val listener =
            object : Player.Listener {
                override fun onPlaybackStateChanged(state: Int) {
                    playbackState = state
                    // Seeking away from the end may emit a delayed non-ended state after the
                    // slider has already reset this flag. Mirror Media3 rather than latching the
                    // old end event so the primary button is Play again at a real seek position.
                    if (state == Player.STATE_ENDED) native.publish(attachment, MonitorPlaybackEvent.Ended)
                }

                override fun onIsPlayingChanged(isPlaying: Boolean) {
                    native.publish(attachment, MonitorPlaybackEvent.Playing(isPlaying))
                }

                override fun onVideoSizeChanged(size: VideoSize) {
                    videoSize = size
                }

                override fun onTracksChanged(tracks: Tracks) {
                    videoColorMode = selectedPlaybackVideoColorMode(tracks)
                    // The container's nominal rate is all a proxy MP4 carries. `NO_VALUE` means
                    // the demuxer never established one, which the policy treats as unknown and
                    // refuses — better than conforming against a guess.
                    val rate = selectedPlaybackVideoFrameRate(tracks)
                    native.publish(attachment, MonitorPlaybackEvent.Metadata(
                        MonitorPlaybackMetadata(
                            duration = player.duration.takeIf { it > 0 && it != C.TIME_UNSET }?.div(1000.0),
                            width = videoSize.width.takeIf { it > 0 }?.toDouble(),
                            height = videoSize.height.takeIf { it > 0 }?.toDouble(),
                            conform = com.opencapture.opencine.media.MonitorConformPreview.Source(captureRate = rate?.toDouble()),
                        ),
                    ))
                }

                override fun onPlayerError(error: PlaybackException) {
                    playbackError = error
                    native.publish(attachment, MonitorPlaybackEvent.Failed(error.message ?: "Could not open that clip."))
                }
            }
        player.addListener(listener)
        onDispose { player.removeListener(listener) }
    }

    LaunchedEffect(player, attachment) {
        if (attachment == null) return@LaunchedEffect
        while (isActive) {
            native.publish(attachment, MonitorPlaybackEvent.Position(max(0L, player.currentPosition) / 1000.0))
            val observedDuration = player.duration.takeIf { it > 0L && it != C.TIME_UNSET }
            native.publish(attachment, MonitorPlaybackEvent.Metadata(
                MonitorPlaybackMetadata(
                    duration = observedDuration?.div(1000.0),
                    width = videoSize.width.takeIf { it > 0 }?.toDouble(),
                    height = videoSize.height.takeIf { it > 0 }?.toDouble(),
                    conform = com.opencapture.opencine.media.MonitorConformPreview.Source(
                        captureRate = selectedPlaybackVideoFrameRate(player.currentTracks)?.toDouble()),
                ),
            ))
            // Prefer ExoPlayer buffered window; fall back to cache-download progress.
            val playerBuffered =
                if (observedDuration != null) {
                    (player.bufferedPosition.toFloat() / observedDuration.toFloat()).coerceIn(0f, 1f)
                } else {
                    0f
                }
            bufferedFraction =
                max(playerBuffered, entry.progress.toFloat().coerceIn(0f, 1f))
            native.publish(attachment, MonitorPlaybackEvent.Playing(player.isPlaying))
            playbackState = player.playbackState
            playbackError = player.playerError
            delay(200)
        }
    }

    val effects = assists.feedEffects(assists.shared::isPlaybackVisible)
    val effectsConfiguration = assists.shared.feedEffectsConfiguration
    val playbackScopes = scopesShown(assists.shared::isPlaybackVisible)
    val cameraInput = exposureAssistCameraInput
    val effectsPresentationState = remember { LiveFeedEffectsPresentationState() }
    val playbackEffectDisplaySize = remember(entry) { PlaybackEffectDisplaySize() }
    val playbackScopeFrameSource =
        remember(entry) {
            if (Build.VERSION.SDK_INT in 29..32) PlaybackCleanScopeFrameSource() else null
        }
    val lutRenderGeneration = lutLibrary?.renderGeneration?.collectAsState()?.value ?: 0L
    LaunchedEffect(lutLibrary, effects.lut) {
        val stored = (effects.lut as? FeedLutSelection.Stored)?.value
        if (stored != null) lutLibrary?.prepare(stored)
    }
    var renderPlan by remember { mutableStateOf<FeedEffectsRenderPlan?>(null) }
    var renderer by remember { mutableStateOf<FeedEffectsRenderer?>(null) }
    LaunchedEffect(
        effects,
        effectsConfiguration,
        cameraInput,
        lutLibrary,
        lutRenderGeneration,
    ) {
        renderPlan = null
        renderer = null
        if (effects.isIdentity || Build.VERSION.SDK_INT < 29) return@LaunchedEffect
        val nextPlan =
            withContext(Dispatchers.Default) {
                FeedEffectsRenderPlanFactory.create(
                    effects,
                    effectsConfiguration,
                    cameraInput,
                    lutLibrary,
                )
            }
        renderPlan = nextPlan
        renderer =
            if (Build.VERSION.SDK_INT >= 33 && nextPlan != null) {
                withContext(Dispatchers.Default) { FeedEffectsRenderer.create(nextPlan) }
            } else {
                null
            }
    }
    val imageEffectsAvailable =
        playbackImageEffectsAvailable(Build.VERSION.SDK_INT, SwiftCore.isAvailable, videoColorMode)
    val playbackFeedEffect =
        remember(renderPlan, playbackEffectDisplaySize) {
            renderPlan?.let { PlaybackFeedEffect(it, playbackEffectDisplaySize) }
        }
    val fallbackDisplayAssistsActive =
        Build.VERSION.SDK_INT in 29..32 &&
            videoColorMode == PlaybackVideoColorMode.SDR &&
            playbackFeedEffect != null
    val scopesVisible = playbackScopes.isNotEmpty()
    LaunchedEffect(
        player,
        playbackFeedEffect,
        playbackScopeFrameSource,
        fallbackDisplayAssistsActive,
        scopesVisible,
    ) {
        if (Build.VERSION.SDK_INT !in 29..32) return@LaunchedEffect
        val nextEffects: List<Effect> =
            playbackVideoEffectStages(fallbackDisplayAssistsActive, scopesVisible).map { stage ->
                when (stage) {
                    PlaybackVideoEffectStage.CLEAN_SCOPE ->
                        requireNotNull(playbackScopeFrameSource).effect
                    PlaybackVideoEffectStage.DISPLAY_ASSISTS -> requireNotNull(playbackFeedEffect)
                }
            }
        player.setVideoEffects(nextEffects)
        if (shouldRedrawPlaybackVideoEffects(player.playbackState, player.isPlaying)) {
            player.setVideoEffects(VideoFrameProcessor.REDRAW)
        }
    }
    val falseColorReady =
        if (Build.VERSION.SDK_INT >= 33) {
            renderer?.falseColorReady == true
        } else {
            fallbackDisplayAssistsActive && renderPlan?.falseColorReady == true
        }
    LaunchedEffect(
        falseColorReady,
        effects.falseColor,
        effectsConfiguration.falseColorReferenceEnabled,
        cameraInput,
        effectsPresentationState,
    ) {
        effectsPresentationState.clear()
        val scale =
            effects.falseColor?.takeIf { effectsConfiguration.falseColorReferenceEnabled }
        if (falseColorReady && scale != null) {
            val reference =
                withContext(Dispatchers.Default) {
                    resolveFalseColorReference(scale, cameraInput)
                }
            if (reference != null) effectsPresentationState.present(scale, reference)
        }
    }
    DisposableEffect(textureView, renderer) {
        val surface = textureView
        if (surface == null || Build.VERSION.SDK_INT < 33) {
            onDispose {}
        } else {
            val applyEffect =
                Runnable {
                    surface.setRenderEffect(renderer?.viewRenderEffect(surface.width, surface.height))
                }
            val layoutListener =
                android.view.View.OnLayoutChangeListener { _, _, _, _, _, _, _, _, _ ->
                    applyEffect.run()
                }
            surface.addOnLayoutChangeListener(layoutListener)
            surface.post(applyEffect)
            onDispose {
                surface.removeCallbacks(applyEffect)
                surface.removeOnLayoutChangeListener(layoutListener)
                surface.setRenderEffect(null)
            }
        }
    }

    val thermalTier = rememberAndroidThermalTier()
    val sourceWidth = if (videoSize.width > 0)
        max(1, (videoSize.width * videoSize.pixelWidthHeightRatio).roundToInt()) else 16
    val sourceHeight = if (videoSize.height > 0) videoSize.height else 9
    return NikonNativePlaybackContent(
        aspect = sourceWidth.toFloat() / sourceHeight,
        horizontalPresentationScale = playbackFramingConfiguration.horizontalPresentationScale,
        verticalPresentationScale = playbackFramingConfiguration.verticalPresentationScale,
        buffered = bufferedFraction,
        error = if (playbackError != null || entry.state == MediaCacheState.FAILED)
            playbackFailureMessage(playbackError, entry.state == MediaCacheState.FAILED) else null,
        picture = { geometry ->
            SideEffect { playbackEffectDisplaySize.update(geometry.feed.width, geometry.feed.height) }
            AndroidView(factory = { playerView },
                update = { view -> if (view.player !== player) view.player = player },
                modifier = Modifier.fillMaxSize().graphicsLayer {
                    scaleX = geometry.zoom.scale * playbackFramingConfiguration.horizontalPresentationScale
                    scaleY = geometry.zoom.scale * playbackFramingConfiguration.verticalPresentationScale
                    translationX = geometry.zoom.offsetX
                    translationY = geometry.zoom.offsetY
                })
        },
        canvas = { context ->
            val geometry = context.geometry
            val density = LocalDensity.current.density
            val feedFrame = MonitorRect(geometry.feed.x / density, geometry.feed.y / density,
                geometry.feed.width / density, geometry.feed.height / density)
            val analysisViewport = MonitorRect(context.analysis.x / density, context.analysis.y / density,
                context.analysis.width / density, context.analysis.height / density)
        if (framingAssistsVisible) {
            LocalFramingAssistOverlay(
                configuration = playbackFramingConfiguration,
                feedRect =
                    FramingAssistRect(geometry.feed.x, geometry.feed.y,
                        geometry.feed.width, geometry.feed.height),
                modifier = Modifier.fillMaxSize(),
            )
        }
        if (
            textureView != null &&
                SwiftCore.isAvailable &&
                playbackScopes.isNotEmpty() &&
                geometry.canvasWidth > 0
        ) {
            PlaybackScopePanels(
                selectedScopes = playbackScopes,
                assist = assists.shared,
                cameraInput = cameraInput,
                lutSelection = effects.lut,
                lutLibrary = lutLibrary,
                thermalTier = thermalTier,
                textureView = textureView,
                currentFrameKey = { player.currentPosition },
                cleanFrameSource =
                    playbackScopeFrameSource.takeIf { fallbackDisplayAssistsActive },
                viewport = analysisViewport,
            )
        }
        FalseColorReferenceOverlay(
            effectsState = effectsPresentationState,
            feed = feedFrame,
            viewport = analysisViewport,
            placementStoreName = "playbackFalseColorReferencePlacement",
            // analysisViewport already excludes playback chrome.
            bottomChromeClearance = 0f,
            // A trailing-biased default avoids the leading waveform/parade
            // footprint on short landscape displays; the panel remains movable.
            defaultHorizontalFraction = 0.72f,
        )
        if (audioMetersVisible) {
            AudioMetersOverlay(
                levels = playbackAudioLevels,
                sensitivity = null,
                feed = feedFrame,
                viewport = analysisViewport,
                placementStoreName = "playbackAudioMeterPlacement",
                // analysisViewport already excludes playback chrome.
                bottomChromeClearance = 0f,
                // Keep the tall meter clear of the next-clip arrow in portrait.
                trailingEdgeGap =
                    if (geometry.canvasWidth < geometry.canvasHeight) 70f else 10f,
            )
        }


        },
        tools = { context ->
            if (assists.shared.configureTool == null) {
                NikonAssistPalette(
                    nikonPlaybackAssistTools(imageEffectsAvailable).map(NikonAssistChip::Tool), assists,
                    playback = true, portrait = context.portrait, locked = false,
                    modifier = Modifier.offset(x = context.frame.x.dp, y = context.frame.y.dp)
                        .size(context.frame.width.dp, context.frame.height.dp),
                    requestExpand = context.expanded, onExpansionHandled = context.onExpansionHandled,
                )
            }
        },
        inspector = { chrome ->
            assists.shared.configureTool?.let { tool ->
                NikonAssistInspector(
                    tool, nikonPlaybackAssistTools(imageEffectsAvailable).filter { it.nikonHasOptions }, assists,
                    operatorSettings, cameraInput, lutLibrary, chrome.width, chrome.height,
                    safeLeading = chrome.leading, safeTop = chrome.top, safeBottom = chrome.bottom,
                    safeTrailing = chrome.trailing, onDismiss = { assists.shared.configureTool = null },
                )
            }
        },
        dismissInspector = {
            if (assists.shared.configureTool != null) { assists.shared.configureTool = null; true } else false
        })
}

private val LocalFramingAssistConfiguration.hasPlaybackFramingOverlay: Boolean
    get() =
        drawsGrid ||
            centerCrosshairEnabled ||
            drawsGuides ||
            desqueezeEnabled

private fun playbackFailureMessage(
    error: PlaybackException?,
    cacheFailed: Boolean,
): String =
    when {
        cacheFailed -> "Camera media transfer failed. The partial cache remains private and cannot be shared."
        error?.errorCode == PlaybackException.ERROR_CODE_DECODING_FORMAT_UNSUPPORTED ||
            error?.errorCode == PlaybackException.ERROR_CODE_DECODER_INIT_FAILED ->
            "This camera proxy uses a codec this Android device cannot decode. It remains private and can be shared after its cache completes."
        else -> "Couldn't play this camera proxy. It remains private and is shareable only after a complete cache artifact is verified."
    }

@Composable
private fun PlaybackFailure(message: String) {
    Box(Modifier.fillMaxSize().padding(horizontal = 28.dp), contentAlignment = Alignment.Center) {
        Text(
            message,
            style = chromeStyle(13f, FontWeight.Medium),
            color = LiveDesign.muted,
            maxLines = 4,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

@Composable
private fun PlaybackLoading(message: String) {
    Column(
        Modifier.fillMaxSize(),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        CircularProgressIndicator(color = LiveDesign.muted)
        Text(
            message,
            modifier = Modifier.padding(top = 12.dp),
            style = chromeStyle(12f, FontWeight.Medium),
            color = LiveDesign.muted,
        )
    }
}

internal fun formatPlaybackTime(milliseconds: Long): String {
    val seconds = max(0L, milliseconds) / 1_000L
    return "%d:%02d".format(seconds / 60L, seconds % 60L)
}

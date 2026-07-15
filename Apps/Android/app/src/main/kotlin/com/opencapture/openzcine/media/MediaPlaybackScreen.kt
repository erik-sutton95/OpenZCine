@file:androidx.media3.common.util.UnstableApi

package com.opencapture.openzcine.media

import android.net.Uri
import android.os.Build
import android.os.SystemClock
import android.view.HapticFeedbackConstants
import android.view.LayoutInflater
import android.view.TextureView
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.detectDragGesturesAfterLongPress
import androidx.compose.foundation.gestures.rememberTransformableState
import androidx.compose.foundation.gestures.transformable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.WindowInsetsSides
import androidx.compose.foundation.layout.displayCutout
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.only
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
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
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.disabled
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntSize
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
import com.opencapture.openzcine.AssistTool
import com.opencapture.openzcine.AssistState
import com.opencapture.openzcine.AssistToolbar
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
import com.opencapture.openzcine.bridge.ZoneFrame
import com.opencapture.openzcine.chromeClickable
import com.opencapture.openzcine.chromeStyle
import com.opencapture.openzcine.glass
import com.opencapture.openzcine.liveFeedContentRect
import com.opencapture.openzcine.lut.AndroidLutLibrary
import com.opencapture.openzcine.rememberAndroidThermalTier
import com.opencapture.openzcine.resolveFalseColorReference
import com.opencapture.openzcine.settings.LocalFramingAssistConfiguration
import com.opencapture.openzcine.settings.OperatorSettings
import com.opencapture.openzcine.withScale
import com.opencapture.openzcine.zone
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

private const val PLAYBACK_ZOOM_MAX = 4f

private data class PlaybackTransportFlash(val glyph: String, val generation: Long)

/** A close or clip switch waits for the current Swift-owned transfer to stop. */
private sealed interface PlaybackSessionAction {
    data object Close : PlaybackSessionAction

    data class Navigate(val clip: MediaClipRecord) : PlaybackSessionAction
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
fun MediaPlaybackScreen(
    initialClip: MediaClipRecord,
    filteredClips: List<MediaClipRecord>,
    cameraID: String,
    favoriteIDs: Set<String>,
    framingConfiguration: LocalFramingAssistConfiguration,
    playbackAssistState: PlaybackAssistState,
    sharedAssistState: AssistState,
    exposureAssistCameraInput: ExposureAssistCameraInput,
    operatorSettings: OperatorSettings,
    lutLibrary: AndroidLutLibrary?,
    onToggleFavorite: (MediaClipRecord) -> Unit,
    onClose: () -> Unit,
): Unit {
    var activeClip by remember(initialClip.libraryKey(cameraID)) { mutableStateOf(initialClip) }
    val playableClips = remember(filteredClips) { PlaybackNavigation.playableClips(filteredClips) }
    val previous = PlaybackNavigation.adjacent(playableClips, activeClip, direction = -1)
    val next = PlaybackNavigation.adjacent(playableClips, activeClip, direction = 1)
    val favorite = activeClip.libraryKey(cameraID) in favoriteIDs

    // Keying the complete session guarantees that a finished close of the old
    // transfer disposes its player/cache work before the next clip is composed.
    key(activeClip.libraryKey(cameraID)) {
        PlaybackClipSession(
            clip = activeClip,
            cameraID = cameraID,
            favorite = favorite,
            previous = previous,
            next = next,
            framingConfiguration = framingConfiguration,
            playbackAssistState = playbackAssistState,
            sharedAssistState = sharedAssistState,
            exposureAssistCameraInput = exposureAssistCameraInput,
            operatorSettings = operatorSettings,
            lutLibrary = lutLibrary,
            onToggleFavorite = { onToggleFavorite(activeClip) },
            onNavigate = { target -> activeClip = target },
            onClose = onClose,
        )
    }
}

@Composable
private fun PlaybackClipSession(
    clip: MediaClipRecord,
    cameraID: String,
    favorite: Boolean,
    previous: MediaClipRecord?,
    next: MediaClipRecord?,
    framingConfiguration: LocalFramingAssistConfiguration,
    playbackAssistState: PlaybackAssistState,
    sharedAssistState: AssistState,
    exposureAssistCameraInput: ExposureAssistCameraInput,
    operatorSettings: OperatorSettings,
    lutLibrary: AndroidLutLibrary?,
    onToggleFavorite: () -> Unit,
    onNavigate: (MediaClipRecord) -> Unit,
    onClose: () -> Unit,
) {
    val context = LocalContext.current
    val cacheStore =
        remember(context) {
            MediaCacheStore(context.noBackupFilesDir.resolve("media-cache").toPath())
        }
    val shareCacheDirectory = remember(context) { context.cacheDir.toPath() }
    val shareScope = rememberCoroutineScope()
    val coordinator =
        remember(cacheStore, cameraID, clip) {
            MediaTransferCoordinator(
                prepareTransfer = {
                    withContext(Dispatchers.IO) {
                        prepareMediaObjectTransfer(
                            cacheStore = cacheStore,
                            cameraID = cameraID,
                            clip = clip,
                            objectLabel = "clip",
                        )
                    }
                },
                stopTransfer = {
                    withContext(Dispatchers.IO) { SwiftCore.sessionStopMediaTransfer() }
                },
            )
        }
    var preparation by remember(clip.handle) {
        mutableStateOf<MediaTransferPreparation>(MediaTransferPreparation.Loading)
    }
    var pendingAction by remember { mutableStateOf<PlaybackSessionAction?>(null) }
    var shareableEntry by remember(clip.handle) { mutableStateOf<MediaCacheEntry?>(null) }
    var shareState by remember(clip.handle) { mutableStateOf(PlaybackShareState.BUFFERING) }
    var shareInProgress by remember(clip.handle) { mutableStateOf(false) }
    var shareFailure by remember(clip.handle) { mutableStateOf<String?>(null) }
    var shareJob by remember(clip.handle) { mutableStateOf<Job?>(null) }
    var activePlayer by remember(clip.handle) { mutableStateOf<Player?>(null) }
    val latestShareJob = rememberUpdatedState(shareJob)
    val actionInProgress = pendingAction != null
    var chromeVisible by remember(clip.handle) { mutableStateOf(true) }

    fun requestClose() {
        if (pendingAction == null) pendingAction = PlaybackSessionAction.Close
    }

    fun requestNavigation(target: MediaClipRecord?) {
        if (target != null && pendingAction == null) {
            pendingAction = PlaybackSessionAction.Navigate(target)
        }
    }

    fun beginShare() {
        val completedEntry = shareableEntry ?: return
        if (shareInProgress || actionInProgress) return
        val job =
            shareScope.launch(start = CoroutineStart.LAZY) {
                val stageContext = coroutineContext
                val runningJob = stageContext[Job]
                try {
                    val staged =
                        withContext(Dispatchers.IO) {
                            MediaShareStager(shareCacheDirectory)
                                .stage(completedEntry, clip) {
                                    stageContext.ensureActive()
                                }
                        }
                    stageContext.ensureActive()
                    if (pendingAction != null) {
                        throw CancellationException("Playback closed before sharing began.")
                    }
                    // Pause before another activity gains the foreground. Media3 also releases
                    // its focus through the lifecycle observer if the chooser backgrounds us.
                    activePlayer?.pause()
                    context.startActivity(AndroidMediaShareIntent.chooserIntent(context, staged))
                } catch (error: CancellationException) {
                    throw error
                } catch (error: Exception) {
                    shareFailure = error.message ?: "Couldn't prepare this clip for sharing."
                } finally {
                    if (shareJob === runningJob) {
                        shareJob = null
                        shareInProgress = false
                    }
                }
            }
        shareJob = job
        shareFailure = null
        shareInProgress = true
        job.start()
    }

    LaunchedEffect(coordinator) {
        preparation = coordinator.prepare()
    }

    // A progressive entry is playable before it is deliverable. Poll only the
    // synchronized entry state: no partial `.part` can grow a share action.
    LaunchedEffect(preparation) {
        shareableEntry = null
        shareFailure = null
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
        shareJob?.cancelAndJoin()
        coordinator.close()
        when (action) {
            PlaybackSessionAction.Close -> onClose()
            is PlaybackSessionAction.Navigate -> onNavigate(action.clip)
        }
    }
    BackHandler(enabled = !actionInProgress) { requestClose() }

    // Activity teardown can dispose the surface without the in-app back path.
    // Preserve the camera invariant by stopping from a bounded IO coroutine.
    DisposableEffect(coordinator) {
        onDispose {
            val runningShareJob = latestShareJob.value
            val cleanup = CoroutineScope(SupervisorJob() + Dispatchers.IO)
            cleanup.launch {
                try {
                    runningShareJob?.cancelAndJoin()
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
        when (val current = preparation) {
            MediaTransferPreparation.Loading -> PlaybackLoading("Preparing camera media…")
            is MediaTransferPreparation.Failed -> PlaybackFailure(current.message)
            is MediaTransferPreparation.Ready ->
                ProgressivePlayer(
                    entry = current.entry,
                    framingConfiguration = framingConfiguration,
                    playbackAssistState = playbackAssistState,
                    sharedAssistState = sharedAssistState,
                    exposureAssistCameraInput = exposureAssistCameraInput,
                    operatorSettings = operatorSettings,
                    lutLibrary = lutLibrary,
                    chromeVisible = chromeVisible,
                    onChromeVisibleChanged = { chromeVisible = it },
                    onPlayerChanged = { activePlayer = it },
                )
            MediaTransferPreparation.Cancelled -> PlaybackLoading("Closing camera media…")
        }

        previous?.let {
            PlaybackNavigationButton(
                label = "‹",
                contentDescription = "Previous video in current filter",
                modifier = Modifier.align(Alignment.CenterStart).padding(start = 16.dp),
                enabled = !actionInProgress,
            ) { requestNavigation(it) }
        }
        next?.let {
            PlaybackNavigationButton(
                label = "›",
                contentDescription = "Next video in current filter",
                modifier = Modifier.align(Alignment.CenterEnd).padding(end = 16.dp),
                enabled = !actionInProgress,
            ) { requestNavigation(it) }
        }

        if (chromeVisible) {
            Column(
                Modifier.fillMaxWidth()
                    .windowInsetsPadding(
                        WindowInsets.displayCutout.only(
                            WindowInsetsSides.Horizontal + WindowInsetsSides.Top,
                        ),
                    )
                    .padding(horizontal = 16.dp, vertical = 14.dp),
            ) {
            Row(
                Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                PlaybackButton("‹", "Back", enabled = !actionInProgress) { requestClose() }
                Text(
                    clip.filename,
                    modifier = Modifier.weight(1f),
                    style = chromeStyle(14f, FontWeight.SemiBold),
                    color = LiveDesign.text,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                PlaybackButton(
                    if (favorite) "★" else "☆",
                    if (favorite) "Remove ${clip.filename} from favorites" else "Add ${clip.filename} to favorites",
                    enabled = !actionInProgress,
                    onClick = onToggleFavorite,
                )
                if (shareState == PlaybackShareState.READY) {
                    PlaybackButton(
                        if (shareInProgress) "…" else "SHARE",
                        "Share ${clip.filename}",
                        enabled = !shareInProgress && !actionInProgress,
                        onClick = ::beginShare,
                    )
                }
            }
            when (shareState) {
                PlaybackShareState.BUFFERING ->
                    Text(
                        "Buffering camera proxy — sharing unlocks after the private cache completes.",
                        modifier = Modifier.padding(start = 54.dp, top = 5.dp, end = 8.dp),
                        style = chromeStyle(10.5f, FontWeight.Medium),
                        color = LiveDesign.muted,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                    )
                PlaybackShareState.UNAVAILABLE,
                PlaybackShareState.READY,
                -> Unit
            }
            shareFailure?.let { message ->
                Text(
                    "Share unavailable: $message",
                    modifier = Modifier.padding(start = 54.dp, top = 5.dp, end = 8.dp),
                    style = chromeStyle(11f, FontWeight.Medium),
                    color = LiveDesign.accent,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            }
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

@Composable
private fun ProgressivePlayer(
    entry: MediaCacheEntry,
    framingConfiguration: LocalFramingAssistConfiguration,
    playbackAssistState: PlaybackAssistState,
    sharedAssistState: AssistState,
    exposureAssistCameraInput: ExposureAssistCameraInput,
    operatorSettings: OperatorSettings,
    lutLibrary: AndroidLutLibrary?,
    chromeVisible: Boolean,
    onChromeVisibleChanged: (Boolean) -> Unit,
    onPlayerChanged: (Player?) -> Unit,
) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    val audioMeterCoordinator = remember(entry) { PlaybackAudioMeterCoordinator() }
    val player =
        remember(entry, audioMeterCoordinator) {
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
                playWhenReady = true
            }
        }
    val playbackAudioLevels by audioMeterCoordinator.levels.collectAsState()
    LaunchedEffect(audioMeterCoordinator, playbackAssistState.assists.audioMetersEnabled) {
        if (playbackAssistState.assists.audioMetersEnabled) audioMeterCoordinator.poll()
    }
    val playerView =
        remember(context) {
            LayoutInflater.from(context)
                .inflate(R.layout.playback_player_view, null, false) as PlayerView
        }
    val textureView = remember(playerView) { playerView.videoSurfaceView as? TextureView }
    DisposableEffect(player, playerView) {
        playerView.player = player
        onPlayerChanged(player)
        onDispose {
            onPlayerChanged(null)
            playerView.player = null
            player.release()
        }
    }
    // Media3 owns audio focus through the configured movie attributes. Pausing
    // on lifecycle loss prevents an opened chooser or background app from
    // continuing playback; Android deliberately does not auto-resume on return.
    DisposableEffect(lifecycleOwner, player) {
        val observer =
            LifecycleEventObserver { _, event ->
                if (event == Lifecycle.Event.ON_PAUSE) player.pause()
            }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }

    var position by remember(entry) { mutableLongStateOf(0L) }
    var duration by remember(entry) { mutableLongStateOf(0L) }
    var bufferedFraction by remember(entry) { mutableFloatStateOf(0f) }
    var playing by remember(entry) { mutableStateOf(true) }
    var audioMode by remember(entry) { mutableStateOf(PlaybackAudioMode.AUDIBLE) }
    var playbackState by remember(entry) { mutableIntStateOf(Player.STATE_BUFFERING) }
    var playbackError by remember(entry) { mutableStateOf<PlaybackException?>(null) }
    var reachedEnd by remember(entry) { mutableStateOf(false) }
    var scrubPosition by remember(entry) { mutableFloatStateOf(0f) }
    var scrubbing by remember(entry) { mutableStateOf(false) }
    var wasPlayingBeforeScrub by remember(entry) { mutableStateOf(false) }
    var lastPreviewSeekAt by remember(entry) { mutableLongStateOf(0L) }
    var zoom by remember(entry) { mutableFloatStateOf(1f) }
    var pan by remember(entry) { mutableStateOf(PlaybackPan()) }
    var viewport by remember(entry) { mutableStateOf(IntSize.Zero) }
    var videoSize by remember(entry) { mutableStateOf(VideoSize.UNKNOWN) }
    var videoColorMode by
        remember(entry, player) {
            mutableStateOf(selectedPlaybackVideoColorMode(player.currentTracks))
        }
    var assistMode by remember(entry) { mutableStateOf(false) }
    var assistOptionsTool by remember(entry) { mutableStateOf<AssistTool?>(null) }
    var assistToolbarBounds by remember(entry) { mutableStateOf<Rect?>(null) }
    var frameScrubbing by remember(entry) { mutableStateOf(false) }
    var frameScrubOrigin by remember(entry) { mutableLongStateOf(0L) }
    var frameScrubHorizontal by remember(entry) { mutableFloatStateOf(0f) }
    var playbackFlash by remember(entry) { mutableStateOf<PlaybackTransportFlash?>(null) }
    val playbackFramingConfiguration =
        playbackAssistState.framingConfiguration(framingConfiguration)
    val framingAssistsVisible = playbackFramingConfiguration.hasPlaybackFramingOverlay
    val hapticView = LocalView.current

    BackHandler(enabled = assistOptionsTool != null) { assistOptionsTool = null }
    LaunchedEffect(chromeVisible, assistMode) {
        if (!chromeVisible || !assistMode) assistOptionsTool = null
    }

    fun clampScrub(value: Float): Long =
        PlaybackTimeline.clampPosition(value.toLong(), duration).also { scrubPosition = it.toFloat() }

    fun resetZoom() {
        zoom = 1f
        pan = PlaybackPan()
    }

    fun togglePlayback(showFlash: Boolean = false) {
        val glyph =
            when {
                reachedEnd -> "▶"
                player.isPlaying -> "Ⅱ"
                else -> "▶"
            }
        if (reachedEnd) {
            player.seekTo(0L)
            reachedEnd = false
            player.play()
        } else if (player.isPlaying) {
            player.pause()
        } else {
            player.play()
        }
        if (showFlash) {
            playbackFlash = PlaybackTransportFlash(glyph, SystemClock.elapsedRealtimeNanos())
        }
    }

    fun finishFrameScrub() {
        if (!frameScrubbing) return
        val target = clampScrub(scrubPosition)
        player.setSeekParameters(SeekParameters.EXACT)
        player.seekTo(target)
        position = target
        scrubbing = false
        frameScrubbing = false
        reachedEnd = target >= duration && duration > 0
        if (wasPlayingBeforeScrub) player.play()
    }

    LaunchedEffect(playbackFlash) {
        val displayed = playbackFlash ?: return@LaunchedEffect
        delay(700)
        if (playbackFlash == displayed) playbackFlash = null
    }

    val transformState =
        rememberTransformableState { _, zoomChange, panChange, _ ->
            val nextZoom = (zoom * zoomChange).coerceIn(1f, PLAYBACK_ZOOM_MAX)
            zoom = nextZoom
            pan =
                clampPlaybackPan(
                    requested = PlaybackPan(pan.x + panChange.x, pan.y + panChange.y),
                    viewportWidth = viewport.width.toFloat(),
                    viewportHeight = viewport.height.toFloat(),
                    zoom = nextZoom,
                    horizontalPresentationScale =
                        if (framingAssistsVisible) {
                            playbackFramingConfiguration.horizontalPresentationScale
                        } else {
                            1f
                        },
                    verticalPresentationScale =
                        if (framingAssistsVisible) {
                            playbackFramingConfiguration.verticalPresentationScale
                        } else {
                            1f
                        },
                )
            if (nextZoom <= 1.01f) pan = PlaybackPan()
        }

    DisposableEffect(player) {
        val listener =
            object : Player.Listener {
                override fun onPlaybackStateChanged(state: Int) {
                    playbackState = state
                    // Seeking away from the end may emit a delayed non-ended state after the
                    // slider has already reset this flag. Mirror Media3 rather than latching the
                    // old end event so the primary button is Play again at a real seek position.
                    reachedEnd = requiresPlaybackReplay(state)
                }

                override fun onIsPlayingChanged(isPlaying: Boolean) {
                    playing = isPlaying
                }

                override fun onVideoSizeChanged(size: VideoSize) {
                    videoSize = size
                }

                override fun onTracksChanged(tracks: Tracks) {
                    videoColorMode = selectedPlaybackVideoColorMode(tracks)
                }

                override fun onPlayerError(error: PlaybackException) {
                    playbackError = error
                }
            }
        player.addListener(listener)
        onDispose { player.removeListener(listener) }
    }

    LaunchedEffect(player) {
        while (isActive) {
            position = max(0L, player.currentPosition)
            duration = player.duration.takeIf { it > 0L && it != C.TIME_UNSET } ?: 0L
            bufferedFraction = entry.progress.toFloat().coerceIn(0f, 1f)
            playing = player.isPlaying
            playbackState = player.playbackState
            playbackError = player.playerError
            if (!scrubbing) scrubPosition = position.toFloat()
            delay(200)
        }
    }

    val effects = playbackAssistState.assists.effects
    val effectsConfiguration = operatorSettings.feedEffectsConfiguration
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
    val scopesVisible = playbackAssistState.assists.selectedScopes.isNotEmpty()
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

    val cacheFailed = entry.state == MediaCacheState.FAILED
    val horizontalPresentationScale =
        if (framingAssistsVisible) playbackFramingConfiguration.horizontalPresentationScale else 1f
    val verticalPresentationScale =
        if (framingAssistsVisible) playbackFramingConfiguration.verticalPresentationScale else 1f
    val density = LocalDensity.current.density
    val viewportWidthDp = viewport.width / density
    val viewportHeightDp = viewport.height / density
    val sourceWidth =
        if (videoSize.width > 0) {
            max(1, (videoSize.width * videoSize.pixelWidthHeightRatio).roundToInt())
        } else {
            16
        }
    val sourceHeight = if (videoSize.height > 0) videoSize.height else 9
    val fittedVideo =
        liveFeedContentRect(
            containerWidth = viewport.width.toFloat(),
            containerHeight = viewport.height.toFloat(),
            sourceWidth = sourceWidth,
            sourceHeight = sourceHeight,
        )
    SideEffect {
        playbackEffectDisplaySize.update(
            fittedVideo?.width?.toFloat() ?: viewport.width.toFloat(),
            fittedVideo?.height?.toFloat() ?: viewport.height.toFloat(),
        )
    }
    val feedFrame =
        fittedVideo?.let { rect ->
            ZoneFrame(
                x = rect.left / density,
                y = rect.top / density,
                width = rect.width / density,
                height = rect.height / density,
            )
        } ?: ZoneFrame(0f, 0f, viewportWidthDp, viewportHeightDp)
    val topChromeClearance =
        when {
            !chromeVisible -> 0f
            viewportWidthDp > viewportHeightDp -> 52f
            else -> 62f
        }
    val bottomChromeClearance =
        when {
            !chromeVisible -> 0f
            assistMode -> 82f
            else -> 118f
        }
    val analysisViewport =
        ZoneFrame(
            x = 0f,
            y = topChromeClearance,
            width = viewportWidthDp,
            height =
                max(
                    1f,
                    viewportHeightDp - topChromeClearance - bottomChromeClearance,
                ),
        )
    val playbackInfoBar = ZoneFrame(0f, 0f, viewportWidthDp, topChromeClearance)
    val thermalTier = rememberAndroidThermalTier()
    Box(
        Modifier.fillMaxSize()
            .clipToBounds()
            .onSizeChanged { viewport = it },
    ) {
        AndroidView(
            factory = { playerView },
            update = { view -> if (view.player !== player) view.player = player },
            // TextureView is selected at PlayerView inflation time. It remains
            // under Compose chrome, accepts the shared GPU RenderEffect, and
            // exposes a clean SurfaceTexture bitmap to the scope sampler.
            modifier =
                Modifier.fillMaxSize()
                    .graphicsLayer {
                        scaleX = zoom * horizontalPresentationScale
                        scaleY = zoom * verticalPresentationScale
                        translationX = pan.x
                        translationY = pan.y
                    },
        )
        // Match iOS: frame gestures belong to the exact aspect-fit video rectangle. Later-drawn
        // chrome retains its own hit targets where it overlaps that rectangle.
        Box(
            Modifier.zone(feedFrame)
                .pointerInput(frameScrubbing, density) {
                    if (frameScrubbing) return@pointerInput
                    awaitEachGesture {
                        val first = awaitFirstDown(requireUnconsumed = false)
                        var horizontal = 0f
                        var vertical = 0f
                        var pressed = true
                        while (pressed) {
                            val event = awaitPointerEvent()
                            val change = event.changes.firstOrNull { it.id == first.id } ?: break
                            horizontal += change.position.x - change.previousPosition.x
                            vertical += change.position.y - change.previousPosition.y
                            pressed = change.pressed
                        }
                        playbackChromeVisibilityForSwipe(
                            horizontalDeltaDp = horizontal / density,
                            verticalDeltaDp = vertical / density,
                        )?.let(onChromeVisibleChanged)
                    }
                }
                .pointerInput(zoom, duration, viewport) {
                    if (zoom <= 1.05f && duration > 0L && viewport.width > 0) {
                        detectDragGesturesAfterLongPress(
                            onDragStart = {
                                wasPlayingBeforeScrub = player.isPlaying
                                player.pause()
                                frameScrubbing = true
                                scrubbing = true
                                frameScrubOrigin =
                                    PlaybackTimeline.clampPosition(player.currentPosition, duration)
                                frameScrubHorizontal = 0f
                                scrubPosition = frameScrubOrigin.toFloat()
                                hapticView.performHapticFeedback(HapticFeedbackConstants.LONG_PRESS)
                            },
                            onDragEnd = ::finishFrameScrub,
                            onDragCancel = ::finishFrameScrub,
                        ) { change, dragAmount ->
                            if (!frameScrubbing) return@detectDragGesturesAfterLongPress
                            change.consume()
                            frameScrubHorizontal += dragAmount.x
                            val target =
                                playbackFrameScrubTarget(
                                    originMillis = frameScrubOrigin,
                                    horizontalDeltaPixels = frameScrubHorizontal,
                                    viewportWidthPixels = max(1, (feedFrame.width * density).roundToInt()),
                                    durationMillis = duration,
                                )
                            scrubPosition = target.toFloat()
                            reachedEnd = target >= duration
                            val now = SystemClock.elapsedRealtime()
                            if (PlaybackTimeline.shouldPreviewSeek(lastPreviewSeekAt, now)) {
                                player.setSeekParameters(SeekParameters.CLOSEST_SYNC)
                                player.seekTo(target)
                                lastPreviewSeekAt = now
                            }
                        }
                    }
                }
                .transformable(transformState)
                .pointerInput(zoom, scrubbing, reachedEnd) {
                    detectTapGestures(
                        onTap = { if (!scrubbing) togglePlayback(showFlash = true) },
                        onDoubleTap = { resetZoom() },
                    )
                },
        )
        if (framingAssistsVisible) {
            LocalFramingAssistOverlay(
                configuration = playbackFramingConfiguration,
                cleanMode = false,
                feedRect =
                    fittedVideo?.let { rect ->
                        FramingAssistRect(
                            left = rect.left.toFloat(),
                            top = rect.top.toFloat(),
                            width = rect.width.toFloat(),
                            height = rect.height.toFloat(),
                        )
                    },
                modifier = Modifier.fillMaxSize(),
            )
        }
        if (
            textureView != null &&
                SwiftCore.isAvailable &&
                playbackAssistState.assists.selectedScopes.isNotEmpty() &&
                viewport.width > 0
        ) {
            PlaybackScopePanels(
                selectedScopes = playbackAssistState.assists.selectedScopes,
                crushClipCompensationRaw = operatorSettings.scopeCrushClipCompensation.wireValue,
                histogramTrafficLightsEnabled = operatorSettings.histogramTrafficLightsEnabled.value,
                configuration = operatorSettings.scopeAssistConfiguration,
                cameraInput = cameraInput,
                lutSelection = playbackAssistState.assists.effects.lut,
                lutLibrary = lutLibrary,
                onScaleChange = { kind, scale ->
                    operatorSettings.scopeAssistConfiguration =
                        operatorSettings.scopeAssistConfiguration.withScale(kind, scale)
                },
                thermalTier = thermalTier,
                textureView = textureView,
                currentFrameKey = { player.currentPosition },
                cleanFrameSource =
                    playbackScopeFrameSource.takeIf { fallbackDisplayAssistsActive },
                feed = feedFrame,
                infoBar = playbackInfoBar,
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
        if (playbackAssistState.assists.audioMetersEnabled) {
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
                    if (viewportWidthDp < viewportHeightDp) 70f else 10f,
            )
        }

        playbackFlash?.let { flash ->
            Box(
                Modifier.align(Alignment.Center).size(74.dp).glass(CircleShape),
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    flash.glyph,
                    style = chromeStyle(34f, FontWeight.SemiBold),
                    color = LiveDesign.text,
                )
            }
        }
        if (frameScrubbing && duration > 0L) {
            Column(
                Modifier.align(Alignment.Center)
                    .glass(CircleShape)
                    .padding(horizontal = 18.dp, vertical = 10.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Text(
                    formatPlaybackTime(scrubPosition.toLong()),
                    style = chromeStyle(16f, FontWeight.SemiBold, mono = true),
                    color = LiveDesign.text,
                )
                Text(
                    "/ ${formatPlaybackTime(duration)}",
                    style = chromeStyle(10f, FontWeight.Medium, mono = true),
                    color = LiveDesign.muted,
                )
            }
        }

        when {
            playbackError != null || cacheFailed ->
                PlaybackFailure(playbackFailureMessage(playbackError, cacheFailed))
            playbackState == Player.STATE_BUFFERING ->
                PlaybackLoading("Buffering ${(bufferedFraction * 100).toInt()}%")
        }

        if (chromeVisible) {
            Column(
                Modifier.align(Alignment.BottomCenter)
                    .fillMaxWidth()
                    .windowInsetsPadding(
                        WindowInsets.safeDrawing.only(
                            WindowInsetsSides.Horizontal + WindowInsetsSides.Bottom,
                        ),
                    )
                    .padding(horizontal = 16.dp, vertical = 14.dp)
                    .glass(RoundedCornerShape(LiveDesign.CORNER_RADIUS_DP.dp))
                    .padding(horizontal = 12.dp, vertical = 9.dp),
                verticalArrangement = Arrangement.spacedBy(5.dp),
            ) {
                if (assistMode) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        AssistToolbar(
                            state = playbackAssistState.assists,
                            modifier =
                                Modifier.weight(1f)
                                    .height(58.dp)
                                    .onGloballyPositioned { assistToolbarBounds = it.boundsInRoot() },
                            visibleTools = operatorSettings.visibleAssistToolbarTools,
                            imageEffectsAvailable = imageEffectsAvailable,
                            framingConfiguration = playbackFramingConfiguration,
                            onToggleFramingTool = { tool ->
                                playbackAssistState.toggle(tool)
                                val next = playbackAssistState.framingConfiguration(framingConfiguration)
                                pan =
                                    clampPlaybackPan(
                                        requested = pan,
                                        viewportWidth = viewport.width.toFloat(),
                                        viewportHeight = viewport.height.toFloat(),
                                        zoom = zoom,
                                        horizontalPresentationScale = next.horizontalPresentationScale,
                                        verticalPresentationScale = next.verticalPresentationScale,
                                    )
                            },
                            hapticsEnabled = operatorSettings.hapticsEnabled.value,
                            onLongPressTool = { tool -> assistOptionsTool = tool },
                        )
                        PlaybackButton(
                            "VIEW",
                            "Hide playback assist toolbar",
                            highlighted = true,
                        ) {
                            assistOptionsTool = null
                            assistMode = false
                        }
                    }
                } else {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        TimeLabel(if (scrubbing) scrubPosition.toLong() else position)
                        Slider(
                            value = scrubPosition.coerceIn(0f, max(1f, duration.toFloat())),
                            onValueChange = { value ->
                                if (!scrubbing) {
                                    wasPlayingBeforeScrub = player.isPlaying
                                    player.pause()
                                    player.setSeekParameters(SeekParameters.CLOSEST_SYNC)
                                    scrubbing = true
                                }
                                val target = clampScrub(value)
                                val now = SystemClock.elapsedRealtime()
                                if (PlaybackTimeline.shouldPreviewSeek(lastPreviewSeekAt, now)) {
                                    player.seekTo(target)
                                    lastPreviewSeekAt = now
                                }
                            },
                            onValueChangeFinished = {
                                val target = clampScrub(scrubPosition)
                                player.setSeekParameters(SeekParameters.EXACT)
                                player.seekTo(target)
                                position = target
                                scrubbing = false
                                reachedEnd = target >= duration && duration > 0L
                                if (wasPlayingBeforeScrub) player.play()
                            },
                            valueRange = 0f..max(1f, duration.toFloat()),
                            modifier = Modifier.weight(1f),
                            colors =
                                SliderDefaults.colors(
                                    thumbColor = LiveDesign.accent,
                                    activeTrackColor = LiveDesign.accent,
                                    inactiveTrackColor = LiveDesign.hairline,
                                ),
                        )
                        TimeLabel(duration)
                    }
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        PlaybackButton("−15", "Back 15 seconds") {
                            val target =
                                PlaybackTimeline.clampPosition(
                                    player.currentPosition - 15_000L,
                                    duration,
                                )
                            player.seekTo(target)
                            reachedEnd = false
                        }
                        PlaybackButton(
                            if (reachedEnd) "↺" else if (playing) "Ⅱ" else "▶",
                            if (reachedEnd) "Replay from beginning" else "Play or pause",
                        ) { togglePlayback() }
                        PlaybackButton("+15", "Forward 15 seconds") {
                            val target =
                                PlaybackTimeline.clampPosition(
                                    player.currentPosition + 15_000L,
                                    duration,
                                )
                            player.seekTo(target)
                            if (target < duration) reachedEnd = false
                        }
                        Spacer(Modifier.weight(1f))
                        PlaybackButton(
                            if (audioMode == PlaybackAudioMode.MUTED) "MUTED" else "AUDIO",
                            if (audioMode == PlaybackAudioMode.MUTED) "Unmute" else "Mute",
                        ) {
                            audioMode = audioMode.toggled()
                            player.volume = audioMode.volume
                        }
                        PlaybackButton(
                            "VIEW",
                            "Show playback assist toolbar",
                            highlighted = playbackAssistState.hasAnyVisibleAssist,
                        ) {
                            assistMode = true
                        }
                    }
                }
            }
        }
        assistOptionsTool?.let { tool ->
            PlaybackAssistOptionsOverlay(
                tool = tool,
                toolbarBounds = assistToolbarBounds,
                playbackState = playbackAssistState,
                sharedAssistState = sharedAssistState,
                settings = operatorSettings,
                cameraInput = cameraInput,
                lutLibrary = lutLibrary,
                onDismiss = { assistOptionsTool = null },
            )
        }
    }
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
private fun PlaybackNavigationButton(
    label: String,
    contentDescription: String,
    modifier: Modifier,
    enabled: Boolean,
    onClick: () -> Unit,
) {
    Box(
        modifier
            .size(44.dp)
            .glass(CircleShape)
            .semantics {
                this.contentDescription = contentDescription
                role = Role.Button
                if (!enabled) disabled()
            }.chromeClickable { if (enabled) onClick() },
        contentAlignment = Alignment.Center,
    ) {
        Text(
            label,
            style = chromeStyle(24f, FontWeight.SemiBold),
            color = if (enabled) LiveDesign.accent else LiveDesign.faint,
        )
    }
}

@Composable
private fun PlaybackButton(
    label: String,
    contentDescription: String,
    enabled: Boolean = true,
    highlighted: Boolean = false,
    onClick: () -> Unit,
) {
    Box(
        Modifier.size(width = if (label.length > 2) 54.dp else 44.dp, height = 40.dp)
            .glass(CircleShape)
            .semantics {
                this.contentDescription = contentDescription
                role = Role.Button
                if (!enabled) disabled()
            }.chromeClickable { if (enabled) onClick() },
        contentAlignment = Alignment.Center,
    ) {
        Text(
            label,
            style = chromeStyle(if (label.length > 2) 9f else 16f, FontWeight.SemiBold),
            color =
                when {
                    !enabled -> LiveDesign.faint
                    highlighted -> LiveDesign.accent
                    else -> LiveDesign.text
                },
        )
    }
}

@Composable
private fun TimeLabel(milliseconds: Long) {
    Text(
        formatPlaybackTime(milliseconds),
        modifier = Modifier.size(width = 42.dp, height = 18.dp),
        style = chromeStyle(10f, FontWeight.Medium, mono = true),
        color = LiveDesign.muted,
    )
}

internal fun formatPlaybackTime(milliseconds: Long): String {
    val seconds = max(0L, milliseconds) / 1_000L
    return "%d:%02d".format(seconds / 60L, seconds % 60L)
}

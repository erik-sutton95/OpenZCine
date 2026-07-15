@file:androidx.media3.common.util.UnstableApi

package com.opencapture.openzcine.media

import android.net.Uri
import android.os.SystemClock
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectTapGestures
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
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.only
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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.disabled
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.datasource.DataSource
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.SeekParameters
import androidx.media3.exoplayer.source.ProgressiveMediaSource
import androidx.media3.ui.compose.PlayerSurface
import androidx.media3.ui.compose.SURFACE_TYPE_TEXTURE_VIEW
import com.opencapture.openzcine.LiveDesign
import com.opencapture.openzcine.LocalFramingAssistOverlay
import com.opencapture.openzcine.bridge.SwiftCore
import com.opencapture.openzcine.chromeClickable
import com.opencapture.openzcine.chromeStyle
import com.opencapture.openzcine.glass
import com.opencapture.openzcine.settings.LocalFramingAssistConfiguration
import kotlin.math.max
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
    onPlayerChanged: (Player?) -> Unit,
) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    val player =
        remember(entry) {
            val dataSourceFactory = DataSource.Factory { GrowingFileDataSource(entry) }
            ExoPlayer.Builder(context).build().apply {
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
                prepare()
                playWhenReady = true
            }
        }
    DisposableEffect(player) {
        onPlayerChanged(player)
        onDispose {
            onPlayerChanged(null)
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
    var framingAssistsVisible by remember(entry) { mutableStateOf(false) }

    fun clampScrub(value: Float): Long =
        PlaybackTimeline.clampPosition(value.toLong(), duration).also { scrubPosition = it.toFloat() }

    fun resetZoom() {
        zoom = 1f
        pan = PlaybackPan()
    }

    fun togglePlayback() {
        if (reachedEnd) {
            player.seekTo(0L)
            reachedEnd = false
            player.play()
        } else if (player.isPlaying) {
            player.pause()
        } else {
            player.play()
        }
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
                            framingConfiguration.horizontalPresentationScale
                        } else {
                            1f
                        },
                    verticalPresentationScale =
                        if (framingAssistsVisible) {
                            framingConfiguration.verticalPresentationScale
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

    val cacheFailed = entry.state == MediaCacheState.FAILED
    val horizontalPresentationScale =
        if (framingAssistsVisible) framingConfiguration.horizontalPresentationScale else 1f
    val verticalPresentationScale =
        if (framingAssistsVisible) framingConfiguration.verticalPresentationScale else 1f
    Box(
        Modifier.fillMaxSize()
            .clipToBounds()
            .onSizeChanged { viewport = it },
        contentAlignment = Alignment.Center,
    ) {
        PlayerSurface(
            player = player,
            // TextureView is required here: SurfaceView escapes Compose's layer ordering when
            // transformed, which can put a zoomed frame above playback chrome on real devices.
            // TextureView remains composited beneath the overlay while preserving Media3 playback.
            surfaceType = SURFACE_TYPE_TEXTURE_VIEW,
            modifier =
                Modifier.fillMaxSize()
                    .graphicsLayer {
                        scaleX = zoom * horizontalPresentationScale
                        scaleY = zoom * verticalPresentationScale
                        translationX = pan.x
                        translationY = pan.y
                    },
        )
        // Only the unobstructed video region owns frame gestures. Media3's surface and Compose
        // chrome overlap visually, so attaching a pointer handler to either full-screen layer can
        // still share a stream with a button beneath the same touch coordinate. The later-drawn
        // chrome owns its hit targets; these insets keep the recognizer away from their edges.
        Box(
            Modifier.fillMaxSize()
                .padding(start = 76.dp, top = 64.dp, end = 76.dp, bottom = 128.dp)
                .transformable(transformState)
                .pointerInput(zoom, scrubbing, reachedEnd) {
                    detectTapGestures(
                        onTap = { if (!scrubbing) togglePlayback() },
                        onDoubleTap = { resetZoom() },
                    )
                },
        )
        if (framingAssistsVisible) {
            // These overlays are geometry-only and therefore valid on a Media3
            // Surface. Color looks, scopes, and audio meters stay absent until
            // Android has a decoded-frame/audio-tap playback renderer.
            LocalFramingAssistOverlay(
                configuration = framingConfiguration,
                cleanMode = false,
                modifier = Modifier.fillMaxSize(),
            )
        }

        when {
            playbackError != null || cacheFailed ->
                PlaybackFailure(playbackFailureMessage(playbackError, cacheFailed))
            playbackState == Player.STATE_BUFFERING ->
                PlaybackLoading("Buffering ${(bufferedFraction * 100).toInt()}%")
        }

        Column(
            Modifier.align(Alignment.BottomCenter)
                .fillMaxWidth()
                .windowInsetsPadding(
                    WindowInsets.displayCutout.only(
                        WindowInsetsSides.Horizontal + WindowInsetsSides.Bottom,
                    ),
                )
                .padding(horizontal = 16.dp, vertical = 14.dp)
                .glass(RoundedCornerShape(LiveDesign.CORNER_RADIUS_DP.dp))
                .padding(horizontal = 12.dp, vertical = 9.dp),
            verticalArrangement = Arrangement.spacedBy(5.dp),
        ) {
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
                        reachedEnd = target < duration
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
                    val target = PlaybackTimeline.clampPosition(player.currentPosition - 15_000L, duration)
                    player.seekTo(target)
                    reachedEnd = false
                }
                PlaybackButton(
                    if (reachedEnd) "↺" else if (playing) "Ⅱ" else "▶",
                    if (reachedEnd) "Replay from beginning" else "Play or pause",
                ) { togglePlayback() }
                PlaybackButton("+15", "Forward 15 seconds") {
                    val target = PlaybackTimeline.clampPosition(player.currentPosition + 15_000L, duration)
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
                    if (framingAssistsVisible) "FRAME" else "ASSIST",
                    if (framingAssistsVisible) "Hide playback framing assists" else "Show playback framing assists",
                ) {
                    framingAssistsVisible = !framingAssistsVisible
                    pan =
                        clampPlaybackPan(
                            requested = pan,
                            viewportWidth = viewport.width.toFloat(),
                            viewportHeight = viewport.height.toFloat(),
                            zoom = zoom,
                            horizontalPresentationScale =
                                if (framingAssistsVisible) {
                                    framingConfiguration.horizontalPresentationScale
                                } else {
                                    1f
                                },
                            verticalPresentationScale =
                                if (framingAssistsVisible) {
                                    framingConfiguration.verticalPresentationScale
                                } else {
                                    1f
                                },
                        )
                }
            }
            if (framingAssistsVisible) {
                Text(
                    if (framingConfiguration.hasPlaybackFramingOverlay) {
                        "Playback framing only. Color looks, scopes, and meters require decoded playback inputs."
                    } else {
                        "No local framing aids selected. Configure grid, guide, or de-squeeze in Operator Setup."
                    },
                    style = chromeStyle(9.5f, FontWeight.Medium),
                    color = LiveDesign.muted,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
            }
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
            color = if (enabled) LiveDesign.text else LiveDesign.faint,
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

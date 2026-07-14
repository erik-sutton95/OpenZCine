@file:androidx.media3.common.util.UnstableApi

package com.opencapture.openzcine.media

import android.net.Uri
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectTapGestures
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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.disabled
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import androidx.media3.datasource.DataSource
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.ProgressiveMediaSource
import androidx.media3.ui.compose.PlayerSurface
import com.opencapture.openzcine.LiveDesign
import com.opencapture.openzcine.bridge.SwiftCore
import com.opencapture.openzcine.chromeClickable
import com.opencapture.openzcine.chromeStyle
import com.opencapture.openzcine.glass
import java.io.IOException
import kotlin.math.max
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CancellationException
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
import kotlinx.coroutines.sync.Mutex

internal sealed interface PlaybackPreparation {
    data object Loading : PlaybackPreparation

    data class Ready(val entry: MediaCacheEntry) : PlaybackPreparation

    data class Failed(val message: String) : PlaybackPreparation

    data object Cancelled : PlaybackPreparation
}

/**
 * Serializes one media-transfer preparation and teardown sequence.
 *
 * Native preparation may start the transfer before it returns. Holding the
 * mutex across that setup makes a close wait for it, so teardown cannot race
 * ahead and leave a hidden transfer running.
 */
internal class MediaTransferCoordinator(
    private val prepareTransfer: suspend () -> PlaybackPreparation,
    private val stopTransfer: suspend () -> Unit,
) {
    private val mutex = Mutex()
    private var closed = false

    suspend fun prepare(): PlaybackPreparation {
        mutex.lock()
        return try {
            if (closed) PlaybackPreparation.Cancelled else prepareTransfer()
        } finally {
            mutex.unlock()
        }
    }

    suspend fun close() {
        mutex.lock()
        try {
            if (closed) return
            closed = true
            stopTransfer()
        } finally {
            mutex.unlock()
        }
    }
}

/**
 * Full-screen progressive proxy player. Camera bytes stream into a persistent
 * growing cache while Media3 reads the same entry; all PTP policy remains in
 * the shared Swift facade.
 */
@Composable
fun MediaPlaybackScreen(
    clip: MediaClipRecord,
    cameraID: String,
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
                        preparePlayback(cacheStore, cameraID, clip)
                    }
                },
                stopTransfer = {
                    withContext(Dispatchers.IO) { SwiftCore.sessionStopMediaTransfer() }
                },
            )
        }
    var preparation by remember(clip.handle) {
        mutableStateOf<PlaybackPreparation>(PlaybackPreparation.Loading)
    }
    var closeRequested by remember { mutableStateOf(false) }
    var shareableEntry by remember(clip.handle) { mutableStateOf<MediaCacheEntry?>(null) }
    var shareInProgress by remember(clip.handle) { mutableStateOf(false) }
    var shareFailure by remember(clip.handle) { mutableStateOf<String?>(null) }
    var shareJob by remember(clip.handle) { mutableStateOf<Job?>(null) }
    val latestShareJob = rememberUpdatedState(shareJob)

    val requestClose: () -> Unit = {
        if (!closeRequested) {
            closeRequested = true
            shareJob?.cancel()
        }
    }

    LaunchedEffect(coordinator) {
        preparation = coordinator.prepare()
    }

    // A progressive entry is playable before it is deliverable. Poll only this
    // lightweight state until finalization so no partial `.part` can expose a
    // Share affordance; MediaCacheEntry owns the synchronized state read.
    LaunchedEffect(preparation) {
        shareableEntry = null
        shareFailure = null
        val entry = (preparation as? PlaybackPreparation.Ready)?.entry ?: return@LaunchedEffect
        while (isActive) {
            when (entry.state) {
                MediaCacheState.COMPLETE -> {
                    if (entry.downloadedBytes == entry.expectedLength) {
                        shareableEntry = entry
                    }
                    return@LaunchedEffect
                }
                MediaCacheState.ACTIVE -> delay(200)
                MediaCacheState.FAILED,
                MediaCacheState.CANCELLED,
                -> return@LaunchedEffect
            }
        }
    }

    LaunchedEffect(closeRequested, coordinator) {
        if (!closeRequested) return@LaunchedEffect
        shareJob?.cancelAndJoin()
        coordinator.close()
        onClose()
    }
    BackHandler(enabled = !closeRequested) { requestClose() }

    // Activity teardown can dispose the surface without the in-app back path.
    // Preserve the camera invariant by stopping on a bounded IO coroutine.
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
            .pointerInput(Unit) { detectTapGestures {} },
    ) {
        when (val current = preparation) {
            PlaybackPreparation.Loading -> PlaybackLoading("Preparing camera media…")
            is PlaybackPreparation.Failed -> PlaybackFailure(current.message)
            is PlaybackPreparation.Ready -> ProgressivePlayer(current.entry)
            PlaybackPreparation.Cancelled -> PlaybackLoading("Closing camera media…")
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
                PlaybackButton("‹", "Back", enabled = !closeRequested) { requestClose() }
                Text(
                    clip.filename,
                    modifier = Modifier.weight(1f),
                    style = chromeStyle(14f, FontWeight.SemiBold),
                    color = LiveDesign.text,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                val completedEntry = shareableEntry
                if (completedEntry != null) {
                    PlaybackButton(
                        if (shareInProgress) "…" else "SHARE",
                        "Share ${clip.filename}",
                        enabled = !shareInProgress && !closeRequested,
                    ) {
                        val job =
                            shareScope.launch(start = CoroutineStart.LAZY) {
                                val stageContext = coroutineContext
                                val runningJob = stageContext[Job]
                                try {
                                    val staged =
                                        withContext(Dispatchers.IO) {
                                            MediaShareStager(shareCacheDirectory)
                                                .stage(completedEntry, clip.filename) {
                                                    stageContext.ensureActive()
                                                }
                                        }
                                    stageContext.ensureActive()
                                    if (closeRequested) {
                                        throw CancellationException("Playback closed before sharing began.")
                                    }
                                    context.startActivity(
                                        AndroidMediaShareIntent.chooserIntent(context, staged),
                                    )
                                } catch (error: CancellationException) {
                                    throw error
                                } catch (error: Exception) {
                                    shareFailure =
                                        error.message ?: "Couldn't prepare this clip for sharing."
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
                }
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
}

private fun preparePlayback(
    cacheStore: MediaCacheStore,
    cameraID: String,
    clip: MediaClipRecord,
): PlaybackPreparation {
    if (!SwiftCore.isAvailable) {
        return PlaybackPreparation.Failed("Camera core is not bundled in this build.")
    }
    return try {
        val totalBytes =
            SwiftCore.sessionResolveMediaSize(clip.handle.toInt(), clip.sizeBytes)
        if (totalBytes < 0) throw IOException("Camera did not provide the clip size.")
        val entry = cacheStore.openEntry(cameraID, MediaCacheObjectIdentity(clip), totalBytes)
        when (entry.state) {
            MediaCacheState.FAILED,
            MediaCacheState.CANCELLED,
            -> entry.resume()
            MediaCacheState.ACTIVE,
            MediaCacheState.COMPLETE,
            -> Unit
        }
        if (entry.state != MediaCacheState.COMPLETE) {
            SwiftCore.sessionStartMediaTransfer(
                handle = clip.handle.toInt(),
                reportedSize = totalBytes,
                resumeOffset = entry.downloadedBytes,
                listener = entry.transferListener(),
            )
        }
        PlaybackPreparation.Ready(entry)
    } catch (error: Exception) {
        PlaybackPreparation.Failed(error.message ?: "Camera media could not be opened.")
    }
}

private fun MediaCacheEntry.transferListener(): SwiftCore.MediaTransferListener =
    object : SwiftCore.MediaTransferListener {
        override fun onStarted(totalBytes: Long) {
            if (totalBytes != expectedLength) {
                fail(MediaCacheLengthException(expectedLength, totalBytes))
            }
        }

        override fun onChunk(offset: Long, bytes: ByteArray): Boolean =
            try {
                append(offset, bytes)
                true
            } catch (error: Exception) {
                fail(error.asIOException())
                false
            }

        override fun onCompleted(totalBytes: Long) {
            try {
                if (totalBytes != expectedLength) {
                    throw MediaCacheLengthException(expectedLength, totalBytes)
                }
                complete()
            } catch (error: Exception) {
                fail(error.asIOException())
            }
        }

        override fun onStopped(cachedBytes: Long) {
            cancel()
        }

        override fun onFailed(message: String) {
            fail(IOException(message))
        }
    }

private fun Exception.asIOException(): IOException =
    this as? IOException ?: IOException(message ?: "Media cache write failed.", this)

@Composable
private fun ProgressivePlayer(entry: MediaCacheEntry) {
    val context = LocalContext.current
    val player =
        remember(entry) {
            val dataSourceFactory = DataSource.Factory { GrowingFileDataSource(entry) }
            ExoPlayer.Builder(context).build().apply {
                val source =
                    ProgressiveMediaSource.Factory(dataSourceFactory)
                        .createMediaSource(MediaItem.fromUri(Uri.parse("camera-cache://clip")))
                setMediaSource(source)
                prepare()
                playWhenReady = true
            }
        }
    DisposableEffect(player) { onDispose { player.release() } }

    var position by remember { mutableLongStateOf(0) }
    var duration by remember { mutableLongStateOf(0) }
    var bufferedFraction by remember { mutableFloatStateOf(0f) }
    var playing by remember { mutableStateOf(true) }
    var muted by remember { mutableStateOf(false) }
    var playbackState by remember { mutableIntStateOf(Player.STATE_BUFFERING) }
    var playbackError by remember { mutableStateOf<String?>(null) }
    var scrubPosition by remember { mutableFloatStateOf(0f) }
    var scrubbing by remember { mutableStateOf(false) }

    LaunchedEffect(player) {
        while (isActive) {
            position = max(0, player.currentPosition)
            duration = max(0, player.duration)
            bufferedFraction = entry.progress.toFloat().coerceIn(0f, 1f)
            playing = player.isPlaying
            playbackState = player.playbackState
            playbackError = player.playerError?.message
            if (!scrubbing) scrubPosition = position.toFloat()
            delay(200)
        }
    }

    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        PlayerSurface(player = player, modifier = Modifier.fillMaxSize())

        val cacheFailed = entry.state == MediaCacheState.FAILED
        when {
            playbackError != null || cacheFailed ->
                PlaybackFailure(playbackError ?: "Camera media transfer failed.")
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
                TimeLabel(position)
                Slider(
                    value = scrubPosition.coerceIn(0f, max(1f, duration.toFloat())),
                    onValueChange = {
                        scrubbing = true
                        scrubPosition = it
                    },
                    onValueChangeFinished = {
                        player.seekTo(scrubPosition.toLong())
                        scrubbing = false
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
                    player.seekTo(max(0, player.currentPosition - 15_000))
                }
                PlaybackButton(if (playing) "Ⅱ" else "▶", "Play or pause") {
                    if (player.isPlaying) player.pause() else player.play()
                }
                PlaybackButton("+15", "Forward 15 seconds") {
                    player.seekTo(
                        if (duration > 0) minOf(duration, player.currentPosition + 15_000)
                        else player.currentPosition + 15_000,
                    )
                }
                Spacer(Modifier.weight(1f))
                PlaybackButton(if (muted) "MUTED" else "AUDIO", "Mute") {
                    muted = !muted
                    player.volume = if (muted) 0f else 1f
                }
            }
        }
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

@Composable
private fun PlaybackFailure(message: String) {
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Text(
            message,
            style = chromeStyle(13f, FontWeight.Medium),
            color = LiveDesign.muted,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
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
            }
            .chromeClickable { if (enabled) onClick() },
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
    val seconds = max(0, milliseconds) / 1_000
    return "%d:%02d".format(seconds / 60, seconds % 60)
}

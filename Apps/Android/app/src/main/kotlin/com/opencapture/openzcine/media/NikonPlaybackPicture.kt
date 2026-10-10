@file:androidx.media3.common.util.UnstableApi

package com.opencapture.openzcine.media

import android.net.Uri
import android.os.Build
import android.view.LayoutInflater
import android.view.TextureView
import androidx.compose.foundation.layout.requiredSize
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.unit.dp
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
import com.opencapture.monitorui.MonitorFalseColorReferenceValues
import com.opencapture.monitorui.MonitorPlaybackInteractionOptions
import com.opencapture.monitorui.MonitorPlaybackPictureGeometry
import com.opencapture.opencine.appkit.MonitorMediaPlaybackModel
import com.opencapture.opencine.appkit.MonitorPlaybackAudioSession
import com.opencapture.opencine.appkit.MonitorPlaybackScopeFrame
import com.opencapture.opencine.appkit.MonitorPlaybackScopeSession
import com.opencapture.opencine.media.MonitorPlaybackEvent
import com.opencapture.opencine.media.MonitorPlaybackItemToken
import com.opencapture.opencine.media.MonitorPlaybackMetadata
import com.opencapture.opencine.media.ScopeAssistBundle
import com.opencapture.openzcine.ExposureAssistCameraInput
import com.opencapture.openzcine.FeedEffectsRenderer
import com.opencapture.openzcine.FeedEffectsRenderPlan
import com.opencapture.openzcine.FeedEffectsRenderPlanFactory
import com.opencapture.openzcine.FeedLutSelection
import com.opencapture.openzcine.NikonAssists
import com.opencapture.openzcine.NikonPlaybackScopeConfiguration
import com.opencapture.openzcine.PlaybackScopeFrameTap
import com.opencapture.openzcine.R
import com.opencapture.openzcine.bridge.SwiftCore
import com.opencapture.openzcine.feedEffects
import com.opencapture.openzcine.feedEffectsConfiguration
import com.opencapture.openzcine.framing
import com.opencapture.openzcine.lut.AndroidLutLibrary
import com.opencapture.openzcine.rememberAndroidThermalTier
import com.opencapture.openzcine.rememberNikonPlaybackScopeConfiguration
import com.opencapture.openzcine.scopesShown
import com.opencapture.openzcine.settings.OperatorSettings
import com.opencapture.openzcine.settings.nikonFalseColorReference
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.roundToInt
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.withContext

/** Bounded Media3 source; the shared player owns gestures, scopes, transport and presentation. */
internal class NikonPlaybackPicture(
    val effects: com.opencapture.opencine.media.FeedEffectsRenderPlan,
    val audio: MonitorPlaybackAudioSession,
    val scopes: Flow<ScopeAssistBundle>,
    val imageEffectsAvailable: Boolean,
    val reference: MonitorFalseColorReferenceValues?,
    val transfer: com.opencapture.opencine.media.MonitorTransfer?,
    val clipByte: Int?,
    val buffered: Float,
    val error: String?,
    val interaction: MonitorPlaybackInteractionOptions,
    val picture: @Composable (MonitorPlaybackPictureGeometry) -> Unit,
)

@Composable
internal fun rememberNikonPlaybackPicture(
    playback: MonitorMediaPlaybackModel<NikonLibraryClip, Unit>,
    native: NikonPlaybackNativePort,
    itemToken: MonitorPlaybackItemToken,
    entry: MediaCacheEntry,
    assists: NikonAssists,
    exposureAssistCameraInput: ExposureAssistCameraInput,
    operatorSettings: OperatorSettings,
    lutLibrary: AndroidLutLibrary?,
    scope: CoroutineScope,
): NikonPlaybackPicture {
    val context = LocalContext.current
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
    val audio = remember(audioMeterCoordinator, scope) { audioMeterCoordinator.sharedSession(scope) }
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
        val captured = native.attach(
            player, itemToken,
            beforeRelease = {
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
                            width = videoSize.width.takeIf { it > 0 }?.let { max(1, (it * videoSize.pixelWidthHeightRatio).roundToInt()).toDouble() },
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
                    width = videoSize.width.takeIf { it > 0 }?.let { max(1, (it * videoSize.pixelWidthHeightRatio).roundToInt()).toDouble() },
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
            native.updateBuffer(attachment, bufferedFraction)
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
    var reference by remember(entry, itemToken) { mutableStateOf<MonitorFalseColorReferenceValues?>(null) }
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
        effects.falseColorRec709,
        cameraInput,
    ) {
        reference = null
        val scale =
            effects.falseColor?.takeIf { effectsConfiguration.falseColorReferenceEnabled }
        if (falseColorReady && scale != null) {
            val nextReference =
                withContext(Dispatchers.Default) {
                    nikonFalseColorReference(scale, cameraInput, read709 = effects.falseColorRec709)
                }
            if (native.isCurrent(attachment)) reference = nextReference
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
    val scopeConfiguration = rememberNikonPlaybackScopeConfiguration(playbackScopes, assists.shared,
        cameraInput, effects.lut, lutLibrary, thermalTier)
    val scopeSession = remember(entry, itemToken, scopeConfiguration?.cadenceMilliseconds) {
        MonitorPlaybackScopeSession<NikonPlaybackScopeConfiguration>(scope,
            cadenceMilliseconds = scopeConfiguration?.cadenceMilliseconds ?: 84,
            derive = { samples, configuration, previous ->
                withContext(Dispatchers.Default) { configuration.bundle(samples, previous) }
            })
    }
    val frameTap = remember(entry, itemToken) { PlaybackScopeFrameTap() }
    LaunchedEffect(scopeSession, scopeConfiguration, attachment, textureView,
        playbackScopeFrameSource, fallbackDisplayAssistsActive, playbackScopes) {
        val configuration = scopeConfiguration ?: run {
            scopeSession.retire(itemToken); frameTap.reset(); return@LaunchedEffect
        }
        val captured = attachment
        val clean = playbackScopeFrameSource.takeIf { fallbackDisplayAssistsActive }
        frameTap.reset(); clean?.reset()
        scopeSession.synchronize(itemToken, enabled = captured != null && textureView != null &&
            SwiftCore.isAvailable && playbackScopes.isNotEmpty(), configuration = configuration,
            read = {
                val frame = clean?.capture() ?: textureView?.let {
                    frameTap.capture(it) { player.currentPosition }
                }
                frame?.let { observed ->
                    val samples = withContext(Dispatchers.Default) { configuration.samples(observed) }
                    MonitorPlaybackScopeFrame(observed.publication, samples)
                }
            }, ifCurrent = {
                playback.isActive && playback.state.value.token == itemToken && native.isCurrent(captured)
            })
    }
    DisposableEffect(scopeSession) { onDispose { scopeSession.close() } }
    val error = if (playbackError != null || entry.state == MediaCacheState.FAILED)
        playbackFailureMessage(playbackError, entry.state == MediaCacheState.FAILED) else null
    LaunchedEffect(error, attachment) {
        if (error != null) native.publish(attachment, MonitorPlaybackEvent.Failed(error))
    }
    return NikonPlaybackPicture(
        effects = renderPlan?.nativePlan ?: com.opencapture.opencine.media.FeedEffectsRenderPlan.IDENTITY,
        audio = audio, scopes = scopeSession.bundle, imageEffectsAvailable = imageEffectsAvailable,
        reference = reference, transfer = scopeConfiguration?.transfer, clipByte = scopeConfiguration?.clipByte,
        buffered = bufferedFraction, error = error,
        interaction = MonitorPlaybackInteractionOptions(doubleTapResetsZoom = true,
            continuousPanBounds = true, zoomAgainstCanvas = true,
            horizontalPresentationScale = playbackFramingConfiguration.horizontalPresentationScale,
            verticalPresentationScale = playbackFramingConfiguration.verticalPresentationScale),
        picture = { geometry ->
            val density = LocalDensity.current.density
            val rawWidth = geometry.feed.width / abs(playbackFramingConfiguration.horizontalPresentationScale).coerceAtLeast(0.001f)
            val rawHeight = geometry.feed.height / abs(playbackFramingConfiguration.verticalPresentationScale).coerceAtLeast(0.001f)
            SideEffect { playbackEffectDisplaySize.update(rawWidth, rawHeight) }
            AndroidView(factory = { playerView },
                update = { view -> if (view.player !== player && native.isCurrent(attachment)) view.player = player },
                modifier = Modifier.requiredSize((rawWidth / density).dp, (rawHeight / density).dp).graphicsLayer {
                    scaleX = geometry.zoom.scale * playbackFramingConfiguration.horizontalPresentationScale *
                        (if (playbackFramingConfiguration.mirrorsHorizontally) -1f else 1f)
                    scaleY = geometry.zoom.scale * playbackFramingConfiguration.verticalPresentationScale *
                        (if (playbackFramingConfiguration.flipsVertically) -1f else 1f)
                    translationX = geometry.zoom.offsetX
                    translationY = geometry.zoom.offsetY
                })
        })
}

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

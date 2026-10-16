@file:androidx.media3.common.util.UnstableApi

package com.opencapture.openzcine.media

import android.content.Context
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.opencapture.monitorui.MonitorAssistTool
import com.opencapture.monitorui.MonitorPlaybackInteractionOptions
import com.opencapture.opencine.appkit.*
import com.opencapture.opencine.cameracontrols.*
import com.opencapture.opencine.media.*
import com.opencapture.opencine.nikon.NikonMediaClipRecord
import com.opencapture.opencine.nikon.NikonMediaContentKind
import com.opencapture.openzcine.ExposureAssistCameraInput
import com.opencapture.openzcine.LiveDesign
import com.opencapture.openzcine.NikonAssists
import com.opencapture.openzcine.NikonLutOptions
import com.opencapture.openzcine.chromeStyle
import com.opencapture.openzcine.diagnostics.AndroidDiagnosticEvent
import com.opencapture.opencine.cameracontrols.MonitorOperatorDeliveryHost
import com.opencapture.openzcine.FeedLutSelection
import com.opencapture.openzcine.lut.AndroidLutLibrary
import com.opencapture.openzcine.nikonPlaybackAssistTools
import com.opencapture.openzcine.settings.OperatorSettings
import com.opencapture.openzcine.settings.SettingsPalette
import com.opencapture.openzcine.settings.nikonAssistSection
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch

/** Nikon source/native leaves around the complete common player and its borrowed gallery. */
@Composable
internal fun MediaPlaybackScreen(
    cacheStore: MediaCacheStore,
    library: MonitorMediaLibraryModel<NikonLibraryClip>?,
    playbackRecords: List<MonitorMediaRecord<NikonLibraryClip>>,
    initialClip: NikonMediaClipRecord,
    filteredClips: List<NikonMediaClipRecord>,
    cameraID: String,
    cameraTransferAvailable: Boolean = true,
    connectionOwner: Long?,
    favoriteIDs: Set<String>,
    assists: NikonAssists,
    exposureAssistCameraInput: ExposureAssistCameraInput,
    operatorSettings: OperatorSettings,
    lutLibrary: AndroidLutLibrary?,
    mediaDelivery: NikonMediaDelivery,
    onToggleFavorite: (NikonMediaClipRecord) -> Unit,
    onRatingMirrored: (NikonMediaClipRecord, Int) -> Unit = { _, _ -> },
    onCaptureRatingCompletion: ((NikonMediaClipRecord) -> NikonMediaRatingCompletion)? = null,
    onRatingDiagnostic: (AndroidDiagnosticEvent) -> Unit = {},
    onResolvedObjectSize: (NikonMediaClipRecord, Long) -> Unit = { _, _ -> },
    onClose: () -> Unit,
    opening: MonitorMediaGalleryOpen<NikonLibraryClip>? = null,
    sourceCurrent: () -> Boolean = { true },
    captureRecord: ((MonitorMediaRecord<NikonLibraryClip>) -> MonitorPlaybackAdmission)? = null,
    captureDeletion: ((MonitorMediaRecord<NikonLibraryClip>, suspend () -> Boolean) -> MonitorOperatorPlaybackDeletionRequest?)? = null,
): Unit {
    val actualLibrary = library ?: run {
        com.opencapture.opencine.cameracontrols.MonitorOperatorMediaUnavailable(close = onClose); return
    }
    val initial = remember(actualLibrary, opening?.id, initialClip.libraryKey(cameraID)) {
        opening ?: playbackRecords.firstOrNull {
            it.payload.bucket == cameraID && it.payload.clip == initialClip
        }?.let { record -> MonitorMediaGalleryOpen(record,
            playbackRecords.filter { it.payload.clip.contentKind == NikonMediaContentKind.PLAYABLE_PROXY },
            actualLibrary.actionToken) }
    } ?: run {
        com.opencapture.opencine.cameracontrols.MonitorOperatorMediaUnavailable(close = onClose); return
    }
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    val currentOwner = rememberUpdatedState(connectionOwner)
    val currentTransfer = rememberUpdatedState(cameraTransferAvailable)
    val currentSource = rememberUpdatedState(sourceCurrent)
    val capture = remember(actualLibrary, initial.id, connectionOwner, cacheStore) {
        val originalOwner = connectionOwner
        val directory = actualLibrary.cache.directory
        val generation = directory.generation
        val root = directory.root
        fun source(): Boolean = currentOwner.value == originalOwner && directory.root == root &&
            directory.generation == generation && currentSource.value() &&
            currentOwner.value == originalOwner && directory.root == root && directory.generation == generation
        val admission: (MonitorMediaRecord<NikonLibraryClip>) -> MonitorPlaybackAdmission = captureRecord ?: { record ->
            val token = actualLibrary.actionToken
            MonitorPlaybackAdmission { source() && actualLibrary.isCurrent(token) &&
                actualLibrary.record(record.asset.id)?.let { sameNikonActionContent(it.payload.clip, record.payload.clip) } == true && source() }
        }
        NikonPlaybackSourceCapture(::source, admission)
    }
    val coordinator = mediaDelivery.coordinator
    var deliveryPopup by remember(actualLibrary, initial.id) { mutableStateOf<NikonDeliverySelection?>(null) }
    fun share(record: MonitorMediaRecord<NikonLibraryClip>) {
        if (coordinator.isActive) return
        val lut = assists.lut
        val label = when (lut) {
            is FeedLutSelection.BuiltIn -> lut.value.label
            is FeedLutSelection.Stored -> lutLibrary?.displayName(lut.value)
        }
        deliveryPopup = mediaDelivery.selection(listOf(record), actualLibrary, initial, connectionOwner, capture.source,
            capture.record, selectedLut = lut.takeIf { label != null }, lutLabel = label)
    }
    val playerContext = remember(actualLibrary, initial.id, connectionOwner, cacheStore) {
        NikonOperatorPlaybackContext(actualLibrary, initial, scope, capture.source, capture.record,
            transferFactory = nikonPlaybackTransfers(cacheStore, connectionOwner, cameraTransferAvailable,
                onResolvedObjectSize), captureDeliveryCleanup = {
                // One PTP data channel: a delivery still caching from the camera yields to playback.
                val outgoing = coordinator.capturedRun.takeIf { coordinator.holdsCameraTransfer }
                suspend { outgoing?.cancelAndJoin() }
            })
    }
    val owner by playerContext.media.state.collectAsState()
    val logical = owner.playback
    val native = playerContext.native
    val emptySource = remember { MutableStateFlow<NikonPlaybackNativePort.Source?>(null) }
    val prepared by (native?.preparedSource ?: emptySource).collectAsState()
    val source = prepared
    val entry = (source?.preparation as? MediaTransferPreparation.Ready)?.entry
    val picture = if (logical != null && native != null && source != null && entry != null) key(source.token) {
        rememberNikonPlaybackPicture(logical, native, source.token, entry, assists,
            exposureAssistCameraInput, operatorSettings, lutLibrary, scope)
    } else null
    val cover = deliveryPopup != null
    val usage = remember(context) { MonitorToolUsagePreferences(
        context.getSharedPreferences("assist", Context.MODE_PRIVATE), "assistToolUsage.v1") }
    val placements = remember(context, assists.shared) { playbackPanelPlacement(context, assists) }
    val emptyScopes = remember { MutableStateFlow(ScopeAssistBundle.EMPTY) }
    val assistSource = MonitorOperatorAssistSource(
        AssistHost(SettingsPalette.peaking, SettingsPalette.highlight, SettingsPalette.midtone),
        picture?.scopes ?: emptyScopes, scopeStackMoved = {}, lookPicker = null,
        panelPlacement = placements,
        lookMenu = { NikonLutOptions(assists, lutLibrary, onOpenRedDownload = {},
            onRequestLutImport = null, includesComparison = false) }, paradeIntensityScale = 1.0)
    val signal = MonitorOperatorSignalOptions(
        falseColor = { nikonAssistSection(MonitorAssistTool.FALSE, assists.shared,
            exposureAssistCameraInput, {})?.Menu() },
        zebra = { nikonAssistSection(MonitorAssistTool.ZEBRA, assists.shared,
            exposureAssistCameraInput, {})?.Menu() },
        reference = picture?.reference, referenceAvailable = picture?.reference != null)
    val operations = nikonPlaybackOperations(playerContext, coordinator, capture, captureDeletion,
        transferAvailable = { currentTransfer.value }, cover = cover, prepared = { prepared },
        onToggleFavorite = onToggleFavorite, rating = playbackRating(cameraTransferAvailable, connectionOwner,
            onRatingMirrored, onCaptureRatingCompletion, onRatingDiagnostic))
    var closing by remember(playerContext) { mutableStateOf(false) }
    fun close() {
        if (closing) return
        closing = true
        val outgoing = playerContext.native
        playerContext.media.closePlayback()
        // A delivery run belongs to the app and continues after the player closes (A4-10).
        scope.launch {
            outgoing?.finishEnteredTransfer()
            onClose()
        }
    }
    DisposableEffect(playerContext) {
        onDispose { playerContext.media.closePlayback() }
    }
    Box(Modifier.fillMaxSize()) {
        MonitorOperatorPlaybackScreen(model = playerContext.media, initial = initial,
            assist = assists.shared, assists = assistSource, usageStore = usage,
            effects = picture?.effects ?: FeedEffectsRenderPlan.IDENTITY, cacheOriginal = false,
            deliveryPresented = cover, operations = operations,
            source = { record ->
                val captured = prepared?.takeIf {
                    it.record.asset.id == record.asset.id && logical?.state?.value?.let { current ->
                        current.ready && current.token == it.token && playerContext.media.isCurrent(it.token)
                    } == true
                }
                val item = (captured?.preparation as? MediaTransferPreparation.Ready)?.entry
                MonitorPlaybackSourceValues(progress = item?.progress,
                    colorLabel = record.asset.colorLabel,
                    transfer = picture?.transfer, clipByte = picture?.clipByte,
                    clockStyle = MonitorPlaybackClockStyle.ELAPSED_MINUTES_SECONDS,
                    bufferedThroughSeconds = captured?.bufferedThroughSeconds)
            }, nativeAudio = { value -> picture?.audio?.takeIf { value === logical } },
            close = ::close, share = ::share,
            signalOptions = signal,
            availableAssistTools = nikonPlaybackAssistTools(picture?.imageEffectsAvailable == true).toSet(),
            initialChromeVisible = true,
            interaction = picture?.interaction ?: MonitorPlaybackInteractionOptions(
                doubleTapResetsZoom = true, continuousPanBounds = true, zoomAgainstCanvas = true),
            picture = { _, _, geometry -> picture?.picture?.invoke(geometry) })
        MonitorOperatorDeliveryHost(deliveryPopup, onDismissPopup = { deliveryPopup = null }, coordinator)
        if (closing) PlaybackLoading("Closing camera media…")
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

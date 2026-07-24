package com.opencapture.openzcine.media

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.rememberTransformableState
import androidx.compose.foundation.gestures.transformable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.WindowInsetsSides
import androidx.compose.foundation.layout.displayCutout
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.only
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Share
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import com.opencapture.openzcine.LiveDesign
import com.opencapture.openzcine.bridge.SwiftCore
import com.opencapture.openzcine.chromeClickable
import com.opencapture.openzcine.chromeStyle
import com.opencapture.openzcine.diagnostics.AndroidDiagnosticEvent
import com.opencapture.openzcine.glass
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.Path
import java.util.Locale
import kotlin.math.max
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

private const val MAX_PREVIEW_DIMENSION_PX = 2_048
private const val PROGRESSIVE_DECODE_STEP_BYTES = 256L * 1_024L

/**
 * Full-screen, transfer-backed still-photo viewer.
 *
 * JPEG and PNG previews are decoded again as the cache grows; HEIF/TIFF is
 * only attempted after an atomically published complete cache; Nikon RAW is
 * deliberately thumbnail-only until Android gains a real RAW renderer. The
 * Swift core continues to own all PTP operations and transfer serialization.
 */
@Composable
internal fun MediaStillViewer(
    clip: MediaClipRecord,
    cameraID: String,
    cameraTransferAvailable: Boolean = true,
    /** The grid item hides this same-stem RAW behind the JPEG (delete removes both). */
    rawSibling: MediaClipRecord? = null,
    /** Camera-card deletion offered only while the camera source is live. */
    deleteAvailable: Boolean = false,
    /** Post-confirmation deletion; the browse screen owns the card operations. */
    onDelete: () -> Unit = {},
    /** Mirrors a camera star (seed-read or write) into the local favorite index. */
    onRatingMirrored: (MediaClipRecord, Int) -> Unit = { _, _ -> },
    /** Records a closed rating-write breadcrumb (attempted / confirmed / refused). */
    onRatingDiagnostic: (AndroidDiagnosticEvent) -> Unit = {},
    onResolvedObjectSize: (MediaClipRecord, Long) -> Unit = { _, _ -> },
    onClose: () -> Unit,
) {
    val context = LocalContext.current
    // RAW side of the JPG/RAW toggle is active (paired stills only). The
    // displayed side is what the viewer loads, names, and shares; the JPEG
    // stays the item's identity for ratings and deletion (iOS `displayClip`).
    var showingRaw by remember(clip.handle) { mutableStateOf(false) }
    var sideSwitchInFlight by remember(clip.handle) { mutableStateOf(false) }
    val displayClip = stillViewerDisplaySide(clip, rawSibling, showingRaw)
    val classification =
        displayClip.stillPhoto
            ?: StillPhotoClassification("Photo", StillPreviewStrategy.THUMBNAIL_ONLY)
    val cacheStore =
        remember(context) {
            MediaCacheStore(context.noBackupFilesDir.resolve("media-cache").toPath())
        }
    val currentOnResolvedObjectSize by rememberUpdatedState(onResolvedObjectSize)
    val coordinator =
        remember(cacheStore, cameraID, displayClip, cameraTransferAvailable) {
            MediaTransferCoordinator(
                prepareTransfer = {
                    withContext(Dispatchers.IO) {
                        prepareMediaObjectTransfer(
                            cacheStore = cacheStore,
                            cameraID = cameraID,
                            clip = displayClip,
                            objectLabel = "image",
                            cameraTransferAvailable = cameraTransferAvailable,
                            onResolvedSize = { resolvedSize ->
                                currentOnResolvedObjectSize(displayClip, resolvedSize)
                            },
                        )
                    }
                },
                stopTransfer = {
                    if (cameraTransferAvailable) {
                        withContext(Dispatchers.IO) { SwiftCore.sessionStopMediaTransfer() }
                    }
                },
            )
        }
    val loadGate = remember(displayClip.handle) { StillViewerLoadGate() }
    var thumbnail by remember(displayClip.handle) { mutableStateOf<Bitmap?>(null) }
    var fullPreview by remember(displayClip.handle) { mutableStateOf<Bitmap?>(null) }
    var previewState by remember(displayClip.handle) {
        mutableStateOf<StillPreviewUiState>(StillPreviewStates.initial())
    }
    // The displayed side's completed cache artifact. The share button arms
    // once the full file has landed — iOS keeps its button live and waits;
    // the transfer banner already narrates progress here, so arming late is
    // the same information with less machinery.
    var shareableEntry by remember(displayClip.handle) { mutableStateOf<MediaCacheEntry?>(null) }
    var shareInProgress by remember(displayClip.handle) { mutableStateOf(false) }
    var shareMessage by remember(displayClip.handle) { mutableStateOf<String?>(null) }
    var closeRequested by remember { mutableStateOf(false) }
    var deleteConfirmPresented by remember(clip.handle) { mutableStateOf(false) }
    // Camera-read star rating; null until loaded (or unreachable — row hidden).
    // The camera stays source of truth: seeded by read, every write confirmed
    // by the entry point's built-in readback (the body rounds off-step down).
    var ratingStars by remember(clip.handle) { mutableStateOf<Int?>(null) }
    LaunchedEffect(clip.handle, cameraTransferAvailable) {
        if (!cameraTransferAvailable || !SwiftCore.isAvailable) return@LaunchedEffect
        val read =
            withContext(Dispatchers.IO) { SwiftCore.sessionObjectRating(clip.handle.toInt()) }
        if (read >= 0) {
            ratingStars = read
            // Self-correct the local favorite cache against the body (truth) on open — this is
            // also how a shot starred in instant playback lands under Favorites once opened.
            onRatingMirrored(clip, read)
        }
    }
    val viewerScope = rememberCoroutineScope()

    LaunchedEffect(coordinator, classification) {
        val requestGeneration = loadGate.begin()
        val cameraThumbnail =
            withContext(Dispatchers.IO) {
                if (cameraTransferAvailable && SwiftCore.isAvailable) {
                    SwiftCore.sessionThumbnail(displayClip.handle.toInt())?.let { jpeg ->
                        BitmapFactory.decodeByteArray(jpeg, 0, jpeg.size)
                    }
                } else {
                    null
                }
            }
        if (!loadGate.accepts(requestGeneration)) return@LaunchedEffect
        thumbnail = cameraThumbnail

        // THUMBNAIL_ONLY (Nikon RAW) still transfers the full file — iOS
        // streams the RAW side too so it can be shared/kept offline — while
        // the honest thumbnail-fallback message stands in for the preview.
        when (val preparation = coordinator.prepare()) {
            is MediaTransferPreparation.Ready ->
                observeStillPreview(
                    entry = preparation.entry,
                    classification = classification,
                    loadGate = loadGate,
                    requestGeneration = requestGeneration,
                    hasThumbnail = { thumbnail != null },
                    showState = { state ->
                        if (loadGate.accepts(requestGeneration)) previewState = state
                    },
                    showFullPreview = { bitmap ->
                        if (loadGate.accepts(requestGeneration)) fullPreview = bitmap
                    },
                    clearFullPreview = {
                        if (loadGate.accepts(requestGeneration)) fullPreview = null
                    },
                    onCompleteEntry = { entry ->
                        if (loadGate.accepts(requestGeneration)) shareableEntry = entry
                    },
                )
            is MediaTransferPreparation.Failed ->
                if (loadGate.accepts(requestGeneration)) {
                    previewState =
                        StillPreviewStates.transferFailed(preparation.message, thumbnail != null)
                }
            MediaTransferPreparation.Cancelled -> Unit
            MediaTransferPreparation.Loading -> Unit
        }
    }

    LaunchedEffect(closeRequested, coordinator) {
        if (!closeRequested) return@LaunchedEffect
        loadGate.invalidate()
        previewState = StillPreviewUiState.Closed
        coordinator.close()
        onClose()
    }
    BackHandler(enabled = !closeRequested) { closeRequested = true }

    // Activity teardown can dispose the surface without an in-app Back event.
    // Keep the shared camera invariant: a transfer must stop and join before
    // it can no longer be represented by this viewer.
    DisposableEffect(coordinator) {
        onDispose {
            loadGate.invalidate()
            val cleanup = CoroutineScope(SupervisorJob() + Dispatchers.IO)
            cleanup.launch {
                try {
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
            // The overlay owns all empty pixels; monitor gestures never leak
            // through while a photo transfer owns camera media mode.
            .pointerInput(Unit) { detectTapGestures {} },
    ) {
        val displayedImage = fullPreview ?: thumbnail
        if (displayedImage != null) {
            ZoomableStillPreview(
                bitmap = displayedImage,
                filename = displayClip.filename,
                modifier = Modifier.fillMaxSize(),
            )
        } else {
            StillPreviewPlaceholder(previewState)
        }

        StillViewerChrome(
            filename = displayClip.filename,
            closeEnabled = !closeRequested,
            deleteAvailable = deleteAvailable && !closeRequested,
            // JPG ⇄ RAW toggle for a same-stem pair (iOS `sideToggle`).
            showingRaw = if (rawSibling != null) showingRaw else null,
            onSelectSide = { raw ->
                if (raw != showingRaw && !sideSwitchInFlight && !closeRequested) {
                    sideSwitchInFlight = true
                    loadGate.invalidate()
                    viewerScope.launch {
                        // iOS `showSide` cancels the active stream before the
                        // other side loads; the same join order the deletion
                        // path keeps, so the card never sees two transfers.
                        coordinator.close()
                        showingRaw = raw
                        sideSwitchInFlight = false
                    }
                }
            },
            onDelete = { deleteConfirmPresented = true },
            // Shares the currently-viewed side of the still (JPEG/HEIF/NEF
            // alike) once its camera download completes (iOS `shareButton`).
            shareEnabled = shareableEntry != null && !closeRequested,
            shareInProgress = shareInProgress,
            onShare = {
                val entry = shareableEntry
                if (entry != null && !shareInProgress) {
                    shareInProgress = true
                    shareMessage = null
                    val target = displayClip
                    viewerScope.launch {
                        try {
                            val staged =
                                withContext(Dispatchers.IO) {
                                    MediaShareStager(context.cacheDir.toPath())
                                        .stage(entry, target)
                                }
                            context.startActivity(
                                AndroidMediaShareIntent.chooserIntent(context, staged),
                            )
                        } catch (error: CancellationException) {
                            throw error
                        } catch (error: Exception) {
                            shareMessage = error.message ?: "Couldn't share this photo."
                        } finally {
                            shareInProgress = false
                        }
                    }
                }
            },
            onClose = { closeRequested = true },
        )
        // Clip star rating written to the card — hidden until the camera read
        // lands and while the transfer status banner owns the bottom edge.
        val stars = ratingStars
        if (
            stars != null &&
            previewState !is StillPreviewUiState.Downloading &&
            previewState != StillPreviewUiState.Preparing
        ) {
            Box(
                Modifier.fillMaxSize()
                    .windowInsetsPadding(
                        WindowInsets.displayCutout.only(
                            WindowInsetsSides.Horizontal + WindowInsetsSides.Bottom,
                        ),
                    )
                    .padding(bottom = 18.dp),
                contentAlignment = Alignment.BottomCenter,
            ) {
                StarRatingRow(stars = stars) { target ->
                    val previous = ratingStars
                    ratingStars = target
                    onRatingDiagnostic(AndroidDiagnosticEvent.RATING_WRITE_ATTEMPTED)
                    viewerScope.launch {
                        val written =
                            withContext(Dispatchers.IO) {
                                val result =
                                    SwiftCore.sessionSetObjectRating(clip.handle.toInt(), target)
                                if (result >= 0 && rawSibling != null) {
                                    // iOS parity: a pair writes both sides, tolerating
                                    // the RAW side's refusal; the JPEG handle stays the
                                    // confirming identity. [verify-on-HW]
                                    SwiftCore.sessionSetObjectRating(
                                        rawSibling.handle.toInt(),
                                        target,
                                    )
                                }
                                result
                            }
                        when (val outcome = ratingWriteResult(written)) {
                            is RatingWriteResult.Confirmed -> {
                                ratingStars = outcome.stars
                                shareMessage = null
                                // Mirror ONLY a confirmed write onto the JPEG-identity row.
                                onRatingMirrored(clip, outcome.stars)
                                onRatingDiagnostic(AndroidDiagnosticEvent.RATING_WRITE_CONFIRMED)
                            }
                            is RatingWriteResult.Refused -> {
                                // Never a silent rollback — say why, with the body's response code.
                                ratingStars = previous
                                shareMessage = ratingRefusalMessage(outcome.code)
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
            }
        }
        StillPreviewStatus(previewState, shareMessage)
    }
    if (deleteConfirmPresented) {
        MediaDeleteConfirmDialog(
            message =
                if (rawSibling != null) {
                    "Delete this photo from the camera card? " +
                        "Both the RAW and JPEG files are removed."
                } else {
                    "Delete this photo from the camera card?"
                },
            onDelete = {
                deleteConfirmPresented = false
                onDelete()
            },
            onDismiss = { deleteConfirmPresented = false },
        )
    }
}

private suspend fun observeStillPreview(
    entry: MediaCacheEntry,
    classification: StillPhotoClassification,
    loadGate: StillViewerLoadGate,
    requestGeneration: Long,
    hasThumbnail: () -> Boolean,
    showState: (StillPreviewUiState) -> Unit,
    showFullPreview: (Bitmap) -> Unit,
    clearFullPreview: () -> Unit,
    onCompleteEntry: (MediaCacheEntry) -> Unit,
) {
    var lastDecodeBytes = -1L
    while (currentCoroutineContext().isActive && loadGate.accepts(requestGeneration)) {
        val cacheState = entry.state
        val downloadedBytes = entry.downloadedBytes
        when (cacheState) {
            MediaCacheState.ACTIVE -> {
                showState(StillPreviewStates.downloading(classification, entry.progress))
                if (
                    classification.previewStrategy == StillPreviewStrategy.PROGRESSIVE &&
                        downloadedBytes > 0 &&
                        (lastDecodeBytes < 0 ||
                            downloadedBytes - lastDecodeBytes >= PROGRESSIVE_DECODE_STEP_BYTES)
                ) {
                    val decoded = withContext(Dispatchers.IO) { decodeCacheBitmap(entry) }
                    if (!loadGate.accepts(requestGeneration)) return
                    if (decoded != null) showFullPreview(decoded)
                    lastDecodeBytes = downloadedBytes
                }
                delay(200)
            }
            MediaCacheState.COMPLETE -> {
                // The full file has landed whether or not it decodes — a
                // complete NEF is shareable behind its thumbnail preview.
                onCompleteEntry(entry)
                val decoded = withContext(Dispatchers.IO) { decodeCacheBitmap(entry) }
                if (!loadGate.accepts(requestGeneration)) return
                if (decoded != null) {
                    showFullPreview(decoded)
                    showState(StillPreviewUiState.FullPreview)
                } else {
                    clearFullPreview()
                    showState(StillPreviewStates.decoderUnavailable(classification, hasThumbnail()))
                }
                return
            }
            MediaCacheState.FAILED -> {
                clearFullPreview()
                showState(
                    StillPreviewStates.transferFailed(
                        "Camera image transfer failed.",
                        hasThumbnail(),
                    ),
                )
                return
            }
            MediaCacheState.CANCELLED -> {
                clearFullPreview()
                showState(
                    StillPreviewStates.transferFailed(
                        "Camera image transfer was cancelled.",
                        hasThumbnail(),
                    ),
                )
                return
            }
        }
    }
}

/** Decodes an image from the cache's currently readable partial or final file. */
private fun decodeCacheBitmap(entry: MediaCacheEntry): Bitmap? {
    val path = if (entry.state == MediaCacheState.COMPLETE) entry.finalPath else entry.partialPath
    return decodeBitmap(path)
}

/**
 * Bounds-first decode with a fixed in-memory ceiling for high-resolution ZR
 * stills. A 2K sampled source is enough for the 1×–4× phone viewer while
 * avoiding an 8K ARGB allocation that would evict the active camera session.
 */
private fun decodeBitmap(path: Path): Bitmap? {
    if (!Files.isRegularFile(path, LinkOption.NOFOLLOW_LINKS)) return null
    return try {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(path.toString(), bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null

        val options =
            BitmapFactory.Options().apply {
                inSampleSize = previewSampleSize(bounds.outWidth, bounds.outHeight)
                inPreferredConfig = Bitmap.Config.ARGB_8888
            }
        BitmapFactory.decodeFile(path.toString(), options)
    } catch (_: OutOfMemoryError) {
        null
    } catch (_: RuntimeException) {
        null
    }
}

/** Largest power-of-two sample that keeps either source dimension near 2K. */
internal fun previewSampleSize(width: Int, height: Int): Int {
    var sampleSize = 1
    while (
        width / sampleSize > MAX_PREVIEW_DIMENSION_PX ||
            height / sampleSize > MAX_PREVIEW_DIMENSION_PX
    ) {
        sampleSize *= 2
    }
    return sampleSize
}

@Composable
private fun ZoomableStillPreview(
    bitmap: Bitmap,
    filename: String,
    modifier: Modifier = Modifier,
) {
    var scale by remember(bitmap) { mutableFloatStateOf(1f) }
    var panOffset by remember(bitmap) { mutableStateOf(Offset.Zero) }
    var viewportSize by remember { mutableStateOf(IntSize.Zero) }
    val adjustZoom: (Float) -> Unit = { requestedScale ->
        scale = requestedScale.coerceIn(1f, 4f)
        panOffset = boundedPan(panOffset, scale, viewportSize)
    }
    val transformState =
        rememberTransformableState { centroid, zoomChange, panChange, _ ->
            val previousScale = scale
            val updatedScale = (previousScale * zoomChange).coerceIn(1f, 4f)
            // Anchored pinch (iOS `AnchoredPinchZoom`): with a centre-pivot scale
            // followed by a translation, a content point p renders at
            // p·scale + offset — so holding the point under the pinch centroid c
            // fixed across a scale step means offset' = c − (c − offset)·ratio.
            val center = Offset(viewportSize.width / 2f, viewportSize.height / 2f)
            val anchor = centroid - center
            val ratio = if (previousScale > 0f) updatedScale / previousScale else 1f
            scale = updatedScale
            panOffset =
                if (updatedScale <= 1f) {
                    Offset.Zero
                } else {
                    boundedPan(
                        anchor - (anchor - panOffset) * ratio + panChange,
                        updatedScale,
                        viewportSize,
                    )
                }
        }
    // iOS `endGesture`: a pinch released just about 1× settles back to exactly 1×.
    LaunchedEffect(transformState, bitmap) {
        snapshotFlow { transformState.isTransformInProgress }
            .collect { inProgress ->
                if (!inProgress && scale < 1.05f) {
                    scale = 1f
                    panOffset = Offset.Zero
                }
            }
    }
    val zoomLabel = String.format(Locale.US, "Zoom %.1fx", scale)

    Box(
        modifier
            .clipToBounds()
            .onSizeChanged { viewportSize = it }
            .transformable(transformState)
            .semantics {
                contentDescription = "Photo preview for $filename"
                stateDescription = zoomLabel
                customActions =
                    listOf(
                        CustomAccessibilityAction("Zoom in") {
                            adjustZoom(scale * 1.5f)
                            true
                        },
                        CustomAccessibilityAction("Zoom out") {
                            adjustZoom(scale / 1.5f)
                            true
                        },
                        CustomAccessibilityAction("Reset zoom") {
                            adjustZoom(1f)
                            true
                        },
                    )
            },
        contentAlignment = Alignment.Center,
    ) {
        androidx.compose.foundation.Image(
            bitmap = bitmap.asImageBitmap(),
            contentDescription = null,
            modifier =
                Modifier.fillMaxSize().graphicsLayer {
                    scaleX = scale
                    scaleY = scale
                    translationX = panOffset.x
                    translationY = panOffset.y
                },
            contentScale = ContentScale.Fit,
        )
    }
}

private fun boundedPan(offset: Offset, scale: Float, viewportSize: IntSize): Offset {
    if (scale <= 1f) return Offset.Zero
    val maximumX = max(0f, viewportSize.width * (scale - 1f) / 2f)
    val maximumY = max(0f, viewportSize.height * (scale - 1f) / 2f)
    return Offset(
        x = offset.x.coerceIn(-maximumX, maximumX),
        y = offset.y.coerceIn(-maximumY, maximumY),
    )
}

@Composable
private fun StillPreviewPlaceholder(state: StillPreviewUiState) {
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            if (state is StillPreviewUiState.Preparing || state is StillPreviewUiState.Downloading) {
                CircularProgressIndicator(color = LiveDesign.accent)
            }
            Text(
                "Camera photo",
                style = chromeStyle(15f, FontWeight.SemiBold),
                color = LiveDesign.muted,
            )
        }
    }
}

@Composable
private fun StillViewerChrome(
    filename: String,
    closeEnabled: Boolean,
    deleteAvailable: Boolean,
    /** Active side of a RAW+JPEG pair; null hides the toggle (unpaired stills). */
    showingRaw: Boolean?,
    onSelectSide: (Boolean) -> Unit,
    onDelete: () -> Unit,
    shareEnabled: Boolean,
    shareInProgress: Boolean,
    onShare: () -> Unit,
    onClose: () -> Unit,
) {
    Row(
        Modifier.fillMaxWidth()
            .windowInsetsPadding(
                WindowInsets.displayCutout.only(
                    WindowInsetsSides.Horizontal + WindowInsetsSides.Top,
                ),
            )
            .padding(horizontal = 16.dp, vertical = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        StillViewerCloseButton(enabled = closeEnabled, onClick = onClose)
        Box(
            Modifier.weight(1f).horizontalScroll(rememberScrollState()),
            contentAlignment = Alignment.CenterStart,
        ) {
            Text(
                filename,
                style = chromeStyle(14f, FontWeight.SemiBold),
                color = LiveDesign.text,
                softWrap = false,
                overflow = TextOverflow.Clip,
            )
        }
        if (showingRaw != null) {
            StillViewerSideToggle(showingRaw = showingRaw, onSelectSide = onSelectSide)
        }
        if (deleteAvailable) {
            StillViewerDeleteButton(onClick = onDelete)
        }
        StillViewerShareButton(
            enabled = shareEnabled,
            inProgress = shareInProgress,
            onClick = onShare,
        )
    }
}

/** Share circle (iOS viewer `shareButton`): system share sheet for the viewed side. */
@Composable
private fun StillViewerShareButton(enabled: Boolean, inProgress: Boolean, onClick: () -> Unit) {
    Box(
        Modifier.size(40.dp)
            .glass(CircleShape)
            .semantics {
                contentDescription = "Share photo"
                role = Role.Button
            }
            .chromeClickable(enabled && !inProgress) { onClick() },
        contentAlignment = Alignment.Center,
    ) {
        if (inProgress) {
            CircularProgressIndicator(
                color = LiveDesign.accent,
                strokeWidth = 2.dp,
                modifier = Modifier.size(18.dp),
            )
        } else {
            Icon(
                Icons.Filled.Share,
                contentDescription = null,
                tint = if (enabled) LiveDesign.text else LiveDesign.faint,
                modifier = Modifier.size(18.dp),
            )
        }
    }
}

/** Compact JPG ⇄ RAW switch for a same-stem pair (iOS viewer `sideToggle`). */
@Composable
private fun StillViewerSideToggle(showingRaw: Boolean, onSelectSide: (Boolean) -> Unit) {
    Row(
        Modifier
            .background(Color.Black.copy(alpha = 0.35f), CircleShape)
            .border(1.dp, LiveDesign.hairline, CircleShape)
            .padding(2.dp)
            .semantics {
                contentDescription = "Photo format"
                stateDescription = if (showingRaw) "RAW" else "JPG"
            },
        horizontalArrangement = Arrangement.spacedBy(2.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        StillViewerSideSegment("JPG", active = !showingRaw) { onSelectSide(false) }
        StillViewerSideSegment("RAW", active = showingRaw) { onSelectSide(true) }
    }
}

@Composable
private fun StillViewerSideSegment(title: String, active: Boolean, onClick: () -> Unit) {
    Text(
        title,
        style = chromeStyle(10f, FontWeight.Bold, mono = true),
        color = if (active) LiveDesign.accent else LiveDesign.muted,
        modifier =
            Modifier
                .background(if (active) LiveDesign.accentDim else Color.Transparent, CircleShape)
                .semantics {
                    contentDescription = "Show $title"
                    role = Role.Button
                }
                .chromeClickable { onClick() }
                .padding(horizontal = 10.dp, vertical = 6.dp),
    )
}

/** Trash circle (iOS viewer `deleteButton`): destructive confirmation follows. */
@Composable
private fun StillViewerDeleteButton(onClick: () -> Unit) {
    Box(
        Modifier.size(40.dp)
            .glass(CircleShape)
            .semantics {
                contentDescription = "Delete photo from the camera card"
                role = Role.Button
            }
            .chromeClickable { onClick() },
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            Icons.Outlined.Delete,
            contentDescription = null,
            tint = Color(0xFFFF5A54),
            modifier = Modifier.size(19.dp),
        )
    }
}

@Composable
private fun StillViewerCloseButton(enabled: Boolean, onClick: () -> Unit) {
    Box(
        Modifier.size(40.dp)
            .glass(CircleShape)
            .semantics {
                contentDescription = "Close photo viewer"
                role = Role.Button
            }
            .chromeClickable(enabled) { onClick() },
        contentAlignment = Alignment.Center,
    ) {
        Text(
            "×",
            style = chromeStyle(22f, FontWeight.Medium),
            color = if (enabled) LiveDesign.text else LiveDesign.faint,
        )
    }
}

@Composable
private fun StillPreviewStatus(state: StillPreviewUiState, shareMessage: String? = null) {
    val message =
        shareMessage
            ?: when (state) {
                StillPreviewUiState.Preparing -> "Preparing camera thumbnail…"
                is StillPreviewUiState.Downloading ->
                    "${state.message} ${(state.progress * 100).toInt()}%"
                is StillPreviewUiState.ThumbnailFallback -> state.message
                is StillPreviewUiState.Failed -> state.message
                StillPreviewUiState.FullPreview,
                StillPreviewUiState.Closed,
                -> return
            }

    Box(
        Modifier.fillMaxSize()
            .windowInsetsPadding(
                WindowInsets.displayCutout.only(
                    WindowInsetsSides.Horizontal + WindowInsetsSides.Bottom,
                ),
            )
            .padding(horizontal = 16.dp, vertical = 14.dp),
        contentAlignment = Alignment.BottomCenter,
    ) {
        Text(
            message,
            modifier =
                Modifier.fillMaxWidth()
                    .glass(RoundedCornerShape(LiveDesign.CORNER_RADIUS_DP.dp))
                    .padding(horizontal = 12.dp, vertical = 9.dp),
            style = chromeStyle(12f, FontWeight.Medium),
            color = LiveDesign.muted,
        )
    }
}

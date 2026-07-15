package com.opencapture.openzcine.media

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
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
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
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
import com.opencapture.openzcine.glass
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.Path
import java.util.Locale
import kotlin.math.max
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
    onClose: () -> Unit,
) {
    val context = LocalContext.current
    val classification =
        clip.stillPhoto
            ?: StillPhotoClassification("Photo", StillPreviewStrategy.THUMBNAIL_ONLY)
    val cacheStore =
        remember(context) {
            MediaCacheStore(context.noBackupFilesDir.resolve("media-cache").toPath())
        }
    val coordinator =
        remember(cacheStore, cameraID, clip, cameraTransferAvailable) {
            MediaTransferCoordinator(
                prepareTransfer = {
                    withContext(Dispatchers.IO) {
                        prepareMediaObjectTransfer(
                            cacheStore = cacheStore,
                            cameraID = cameraID,
                            clip = clip,
                            objectLabel = "image",
                            cameraTransferAvailable = cameraTransferAvailable,
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
    val loadGate = remember(clip.handle) { StillViewerLoadGate() }
    var thumbnail by remember(clip.handle) { mutableStateOf<Bitmap?>(null) }
    var fullPreview by remember(clip.handle) { mutableStateOf<Bitmap?>(null) }
    var previewState by remember(clip.handle) {
        mutableStateOf<StillPreviewUiState>(StillPreviewStates.initial())
    }
    var closeRequested by remember { mutableStateOf(false) }

    LaunchedEffect(coordinator, classification) {
        val requestGeneration = loadGate.begin()
        val cameraThumbnail =
            withContext(Dispatchers.IO) {
                if (cameraTransferAvailable && SwiftCore.isAvailable) {
                    SwiftCore.sessionThumbnail(clip.handle.toInt())?.let { jpeg ->
                        BitmapFactory.decodeByteArray(jpeg, 0, jpeg.size)
                    }
                } else {
                    null
                }
            }
        if (!loadGate.accepts(requestGeneration)) return@LaunchedEffect
        thumbnail = cameraThumbnail

        if (classification.previewStrategy == StillPreviewStrategy.THUMBNAIL_ONLY) {
            previewState = StillPreviewStates.decoderUnavailable(classification, thumbnail != null)
            return@LaunchedEffect
        }

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
                filename = clip.filename,
                modifier = Modifier.fillMaxSize(),
            )
        } else {
            StillPreviewPlaceholder(previewState)
        }

        StillViewerChrome(
            filename = clip.filename,
            closeEnabled = !closeRequested,
            onClose = { closeRequested = true },
        )
        StillPreviewStatus(previewState)
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
        rememberTransformableState { _, zoomChange, panChange, _ ->
            val updatedScale = (scale * zoomChange).coerceIn(1f, 4f)
            scale = updatedScale
            panOffset =
                if (updatedScale <= 1f) {
                    Offset.Zero
                } else {
                    boundedPan(panOffset + panChange, updatedScale, viewportSize)
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
private fun StillPreviewStatus(state: StillPreviewUiState) {
    val message =
        when (state) {
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

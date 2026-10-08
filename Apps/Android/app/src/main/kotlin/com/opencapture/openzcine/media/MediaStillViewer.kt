package com.opencapture.openzcine.media

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import com.opencapture.opencine.appkit.*
import com.opencapture.opencine.cameracontrols.MonitorOperatorPhotoScreen
import com.opencapture.opencine.nikon.NikonMediaClipRecord
import com.opencapture.opencine.nikon.NikonNative
import com.opencapture.opencine.nikon.NikonStillPhotoClassification
import com.opencapture.opencine.nikon.NikonStillPreviewStrategy
import com.opencapture.openzcine.bridge.SwiftCore
import com.opencapture.openzcine.diagnostics.AndroidDiagnosticEvent
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.Path
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.withContext

private const val MAX_PREVIEW_DIMENSION_PX = 2_048
private const val PROGRESSIVE_DECODE_STEP_BYTES = 256L * 1_024L

/** Native image/record ports composed into the complete shared still-picture owner. */
@Composable
internal fun MediaStillViewer(
    cacheStore: MediaCacheStore,
    library: MonitorMediaLibraryModel<NikonLibraryClip>,
    record: MonitorMediaRecord<NikonLibraryClip>,
    admission: MonitorMediaLibraryActionToken,
    sourceCurrent: () -> Boolean,
    operations: MonitorMediaGalleryOperations<NikonLibraryClip>,
    assist: MonitorAssistState,
    cameraTransferAvailable: Boolean,
    connectionOwner: Long?,
    rawRecord: MonitorMediaRecord<NikonLibraryClip>? = null,
    collection: List<MonitorMediaRecord<NikonLibraryClip>> = emptyList(),
    selectRecord: ((MonitorMediaRecord<NikonLibraryClip>) -> Unit)? = null,
    thumbnail: (@Composable (MonitorMediaPictureRequest<NikonLibraryClip>, Modifier) -> Unit)? = null,
    onRatingMirrored: (NikonMediaClipRecord, Int) -> Unit = { _, _ -> },
    onCaptureRatingCompletion: ((NikonMediaClipRecord) -> NikonMediaRatingCompletion)? = null,
    onRatingDiagnostic: (AndroidDiagnosticEvent) -> Unit = {},
    onResolvedObjectSize: (NikonMediaClipRecord, Long) -> Unit = { _, _ -> },
    onDeleted: (() -> Unit)? = null,
    onDeletedReturning: ((MonitorMediaLibraryActionToken) -> Unit)? = null,
    onClose: () -> Unit,
) {
    val context = LocalContext.current
    val io = remember(library, record.asset.id, admission, cacheStore, connectionOwner) {
        NikonStillPictureIO(cacheStore, cameraTransferAvailable, connectionOwner, onResolvedObjectSize)
    }
    val variants = remember(record, rawRecord) {
        if (rawRecord == null) emptyList() else listOf(
            MonitorMediaPictureVariant("JPG", record), MonitorMediaPictureVariant("RAW", rawRecord))
    }
    val rating = MonitorMediaPictureRatingService<NikonLibraryClip>(levels = (1..5).toList(),
        read = { request ->
            if (!cameraTransferAvailable || !SwiftCore.isAvailable || !request.isCurrent()) null
            else {
                val clip = request.record.payload.clip
                val completion = onCaptureRatingCompletion?.invoke(clip)
                val value = withContext(Dispatchers.IO) {
                    val owner = connectionOwner
                    if (owner == null || !request.isCurrent()) -1
                    else NikonNative.sessionObjectRating(owner, clip.handle.toInt())
                }
                if (value < 0 || !request.isCurrent() || completion?.isCurrent == false) null
                else if (completion != null && !completion.mirror(value)) null
                else { if (completion == null) onRatingMirrored(clip, value); value }
            }
        }, commit = { target, request ->
            val clip = request.record.payload.clip
            val completion = onCaptureRatingCompletion?.invoke(clip)
            if (!request.isCurrent() || completion?.isCurrent == false || connectionOwner == null ||
                !cameraTransferAvailable || !SwiftCore.isAvailable) MonitorMediaPictureRatingResult.Unavailable
            else {
                onRatingDiagnostic(AndroidDiagnosticEvent.RATING_WRITE_ATTEMPTED)
                val written = withContext(Dispatchers.IO) {
                    if (!request.isCurrent()) -1 else {
                        val result = NikonNative.sessionSetObjectRating(connectionOwner, clip.handle.toInt(), target)
                        if (result >= 0 && rawRecord != null && request.isCurrent()) {
                            // JPEG remains confirming identity; the paired RAW may refuse independently.
                            NikonNative.sessionSetObjectRating(connectionOwner, rawRecord.payload.clip.handle.toInt(), target)
                        }
                        result
                    }
                }
                if (!request.isCurrent() || completion?.isCurrent == false) MonitorMediaPictureRatingResult.Unavailable
                else when (val outcome = ratingWriteResult(written)) {
                    is RatingWriteResult.Confirmed -> {
                        if (completion != null && !completion.mirror(outcome.stars)) MonitorMediaPictureRatingResult.Unavailable
                        else {
                            if (completion == null) onRatingMirrored(clip, outcome.stars)
                            onRatingDiagnostic(AndroidDiagnosticEvent.RATING_WRITE_CONFIRMED)
                            MonitorMediaPictureRatingResult.Confirmed(outcome.stars)
                        }
                    }
                    is RatingWriteResult.Refused -> {
                        onRatingDiagnostic(if (outcome.code == 0x2013) AndroidDiagnosticEvent.RATING_WRITE_REFUSED_ACCESS_DENIED
                            else AndroidDiagnosticEvent.RATING_WRITE_REFUSED)
                        MonitorMediaPictureRatingResult.Refused(ratingRefusalMessage(outcome.code))
                    }
                }
            }
        })
    val sharing = MonitorMediaPictureSharing<NikonLibraryClip>(readiness = { request ->
        if (io.completed(request) != null && operations.access?.invoke(request.record)?.share != false)
            MonitorMediaPictureShareReadiness.READY else MonitorMediaPictureShareReadiness.UNAVAILABLE
    }, perform = { request ->
        val entry = io.completed(request)
        if (entry != null && request.isCurrent()) {
            val staged = withContext(Dispatchers.IO) {
                MediaShareStager(context.cacheDir.toPath()).stage(entry, request.record.payload.clip)
            }
            if (request.isCurrent()) context.startActivity(AndroidMediaShareIntent.chooserIntent(context, staged))
        }
    })
    MonitorOperatorPhotoScreen(library = library, record = record, admission = admission, assist = assist,
        loaders = MonitorMediaPictureLoaders(preview = io::preview, cached = io::cached, progressive = io::progressive),
        operations = operations, sourceCurrent = sourceCurrent, variants = variants, rating = rating, sharing = sharing,
        share = {}, collection = collection, selectRecord = selectRecord, collectionThumbnail = thumbnail,
        deleted = onDeleted, deletedReturning = onDeletedReturning, close = onClose)
}

/** Only SDK transfer and native bitmap/EXIF facts live here; the shared owner schedules and joins. */
private class NikonStillPictureIO(
    private val cache: MediaCacheStore,
    private val cameraTransferAvailable: Boolean,
    private val connectionOwner: Long?,
    private val onResolvedObjectSize: (NikonMediaClipRecord, Long) -> Unit,
) {
    private val thumbnails = mutableMapOf<com.opencapture.opencine.media.MediaAssetID, Bitmap?>()
    private val complete = mutableMapOf<com.opencapture.opencine.media.MediaAssetID, MediaCacheEntry>()
    fun completed(request: MonitorMediaPictureRequest<NikonLibraryClip>): MediaCacheEntry? =
        complete[request.record.asset.id]?.takeIf { request.isCurrent() && it.state == MediaCacheState.COMPLETE }
    suspend fun preview(request: MonitorMediaPictureRequest<NikonLibraryClip>): Bitmap? {
        if (!request.isCurrent()) return null
        val value = request.record.payload
        val bitmap = withContext(Dispatchers.IO) {
            if (!cameraTransferAvailable || !SwiftCore.isAvailable || connectionOwner == null || !request.isCurrent()) null
            else NikonNative.sessionThumbnail(connectionOwner, value.clip.handle.toInt())?.let { jpeg ->
                if (!request.isCurrent()) null else {
                    val key = value.clip.libraryKey(value.bucket)
                    val orientation = MediaExifOrientation.fromBytes(jpeg)?.also { MediaExifOrientation.learn(key, it) }
                        ?: MediaExifOrientation.learned(key)
                    BitmapFactory.decodeByteArray(jpeg, 0, jpeg.size)?.upright(orientation)
                }
            }
        }
        if (!request.isCurrent()) return null
        thumbnails[request.record.asset.id] = bitmap
        return bitmap
    }
    suspend fun cached(request: MonitorMediaPictureRequest<NikonLibraryClip>): Bitmap? {
        if (!request.isCurrent()) return null
        val value = request.record.payload
        val entry = withContext(Dispatchers.IO) {
            if (!request.isCurrent()) null else cache.completedEntryOrNull(value.bucket, MediaCacheObjectIdentity(value.clip), value.clip.sizeBytes)
        } ?: return null
        if (!request.isCurrent()) return null
        complete[request.record.asset.id] = entry
        val bitmap = withContext(Dispatchers.IO) { decodeCacheBitmap(entry) }
        return bitmap.takeIf { request.isCurrent() }
    }
    suspend fun progressive(publication: MonitorMediaPicturePublication<NikonLibraryClip, Bitmap>): Bitmap? {
        val request = publication.request
        if (!request.isCurrent()) return null
        val value = request.record.payload
        val classification = value.clip.stillPhoto ?: NikonStillPhotoClassification("Photo", NikonStillPreviewStrategy.THUMBNAIL_ONLY)
        val coordinator = MediaTransferCoordinator(prepareTransfer = {
            withContext(Dispatchers.IO) {
                if (!request.isCurrent()) MediaTransferPreparation.Cancelled else prepareMediaObjectTransfer(
                    cacheStore = cache, cameraID = value.bucket, clip = value.clip, objectLabel = "image",
                    bridge = SwiftCoreMediaObjectTransferBridge(connectionOwner), cameraTransferAvailable = cameraTransferAvailable,
                    onResolvedSize = { if (request.isCurrent()) onResolvedObjectSize(value.clip, it) })
            }
        }, stopTransfer = {
            if (cameraTransferAvailable && SwiftCore.isAvailable && connectionOwner != null)
                withContext(Dispatchers.IO) { NikonNative.sessionStopMediaTransfer(connectionOwner) }
        })
        try {
            return when (val prepared = coordinator.prepare()) {
                is MediaTransferPreparation.Ready -> observe(prepared.entry, classification, publication)
                is MediaTransferPreparation.Failed -> {
                    publication.publish(StillPreviewStates.transferFailed(prepared.message,
                        thumbnails[request.record.asset.id] != null).pictureStatus())
                    thumbnails[request.record.asset.id]
                }
                MediaTransferPreparation.Cancelled, MediaTransferPreparation.Loading -> null
            }
        } finally {
            withContext(NonCancellable) { coordinator.close() }
        }
    }
    private suspend fun observe(entry: MediaCacheEntry, classification: NikonStillPhotoClassification,
        publication: MonitorMediaPicturePublication<NikonLibraryClip, Bitmap>): Bitmap? {
        var lastDecodeBytes = -1L
        val request = publication.request
        val thumbnail = thumbnails[request.record.asset.id]
        while (currentCoroutineContext().isActive && publication.isCurrent) {
            val bytes = entry.downloadedBytes
            when (entry.state) {
                MediaCacheState.ACTIVE -> {
                    publication.publish(StillPreviewStates.downloading(classification, entry.progress).pictureStatus())
                    if (classification.previewStrategy == NikonStillPreviewStrategy.PROGRESSIVE && bytes > 0 &&
                        (lastDecodeBytes < 0 || bytes - lastDecodeBytes >= PROGRESSIVE_DECODE_STEP_BYTES)) {
                        val bitmap = withContext(Dispatchers.IO) { decodeCacheBitmap(entry) }
                        if (!publication.isCurrent) return null
                        if (bitmap != null) publication.publish(bitmap)
                        lastDecodeBytes = bytes
                    }
                    delay(200)
                }
                MediaCacheState.COMPLETE -> {
                    complete[request.record.asset.id] = entry
                    val value = request.record.payload
                    val bitmap = withContext(Dispatchers.IO) {
                        val decoded = decodeCacheBitmap(entry)
                        if (request.isCurrent()) MediaExifOrientation.fromFile(entry.finalPath)?.let {
                            MediaExifOrientation.learn(value.clip.libraryKey(value.bucket), it)
                        }
                        decoded
                    }
                    if (!publication.isCurrent) return null
                    publication.publish(if (bitmap != null) StillPreviewUiState.FullPreview.pictureStatus()
                        else StillPreviewStates.decoderUnavailable(classification, thumbnail != null).pictureStatus())
                    if (bitmap == null && thumbnail != null) publication.publish(thumbnail)
                    return bitmap ?: thumbnail
                }
                MediaCacheState.FAILED, MediaCacheState.CANCELLED -> {
                    publication.publish(StillPreviewStates.transferFailed(
                        if (entry.state == MediaCacheState.FAILED) "Camera image transfer failed." else "Camera image transfer was cancelled.",
                        thumbnail != null).pictureStatus())
                    if (thumbnail != null) publication.publish(thumbnail)
                    return thumbnail
                }
            }
        }
        return null
    }
}
private fun StillPreviewUiState.pictureStatus(): MonitorMediaPictureStatus = when (this) {
    StillPreviewUiState.Preparing -> MonitorMediaPictureStatus("Preparing camera thumbnail…", showsRating = false)
    is StillPreviewUiState.Downloading -> MonitorMediaPictureStatus(message, progress, showsRating = false)
    is StillPreviewUiState.ThumbnailFallback -> MonitorMediaPictureStatus(message)
    is StillPreviewUiState.Failed -> MonitorMediaPictureStatus(message)
    StillPreviewUiState.FullPreview, StillPreviewUiState.Closed -> MonitorMediaPictureStatus()
}

/** Decoding thresholds, EXIF interpretation and SDK file choice remain source facts. */
private fun decodeCacheBitmap(entry: MediaCacheEntry): Bitmap? =
    decodeBitmap(if (entry.state == MediaCacheState.COMPLETE) entry.finalPath else entry.partialPath)

private fun decodeBitmap(path: Path): Bitmap? {
    if (!Files.isRegularFile(path, LinkOption.NOFOLLOW_LINKS)) return null
    return try {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(path.toString(), bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
        val options = BitmapFactory.Options().apply {
            inSampleSize = previewSampleSize(bounds.outWidth, bounds.outHeight)
            inPreferredConfig = Bitmap.Config.ARGB_8888
        }
        BitmapFactory.decodeFile(path.toString(), options)?.upright(MediaExifOrientation.fromFile(path))
    } catch (_: OutOfMemoryError) { null }
    catch (_: RuntimeException) { null }
}

/** Largest power-of-two sample that preserves the original 2K native decode ceiling. */
internal fun previewSampleSize(width: Int, height: Int): Int {
    var sampleSize = 1
    while (width / sampleSize > MAX_PREVIEW_DIMENSION_PX || height / sampleSize > MAX_PREVIEW_DIMENSION_PX) sampleSize *= 2
    return sampleSize
}

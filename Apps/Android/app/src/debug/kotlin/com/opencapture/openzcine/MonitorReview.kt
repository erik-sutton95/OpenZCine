package com.opencapture.openzcine

import android.content.Context
import android.content.Intent
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.testTagsAsResourceId
import com.opencapture.monitorui.ReviewLaunch
import com.opencapture.opencine.media.ProgressiveMediaCacheState
import com.opencapture.opencine.nikon.NikonMediaClipRecord
import com.opencapture.opencine.nikon.NikonMediaContentKind
import com.opencapture.opencine.platform.ReviewMediaSeed
import com.opencapture.openzcine.media.MediaCacheObjectIdentity
import com.opencapture.openzcine.media.MediaCacheStore
import com.opencapture.openzcine.media.MediaLibraryCameraBucket
import com.opencapture.openzcine.media.MediaLibraryIndex
import com.opencapture.openzcine.media.MediaLibrarySource
import java.io.File
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

internal fun Modifier.reviewMetadata(review: ReviewLaunch?): Modifier =
    if (review == null) this else semantics { testTagsAsResourceId = true }

/** SIMULATED local review through the root's actual progressive cache, index, gallery and player. */
internal object MonitorReview {
    private const val NAMESPACE = "SIMULATED-S1"

    fun decode(intent: Intent?): ReviewLaunch? = ReviewLaunch.decode { intent?.getStringExtra(it) }
        ?.takeIf { it.screen == ReviewLaunch.Screen.MEDIA && it.source == ReviewLaunch.Source.LOCAL && !it.connected }

    fun bucket(review: ReviewLaunch?): MediaLibraryCameraBucket? = review?.let {
        MediaLibraryCameraBucket(NAMESPACE, NAMESPACE, "SIMULATED local media")
    }

    suspend fun start(context: Context, cache: MediaCacheStore, index: MediaLibraryIndex, review: ReviewLaunch) {
        withContext(Dispatchers.IO) {
            val staging = File(context.cacheDir, NAMESPACE)
            val clips = ReviewMediaSeed.write(staging, review.mediaCount) { clip ->
                ReviewMediaSeed.Destination(File(staging, clip.filename))
            }
            val records = clips.map { clip ->
                val record = record(clip)
                val entry = cache.openEntry(NAMESPACE, MediaCacheObjectIdentity(record), clip.byteCount)
                if (entry.state != ProgressiveMediaCacheState.COMPLETE) {
                    val bytes = File(staging, clip.filename).readBytes()
                    entry.append(entry.downloadedBytes, bytes.copyOfRange(entry.downloadedBytes.toInt(), bytes.size))
                    entry.complete()
                }
                record
            }
            index.rememberCameraListing(NAMESPACE, records)
            index.saveViewOptions(index.viewOptions(MediaLibrarySource.LOCAL).copy(layout = review.layout))
        }
    }

    /** Integration record adapter only; no session, connection owner or camera command is created. */
    private fun record(clip: ReviewMediaSeed.Clip): NikonMediaClipRecord = NikonMediaClipRecord(
        handle = clip.ordinal.toLong(), storageId = 1, sizeBytes = clip.byteCount,
        captureDate = clip.captureDate, pixelWidth = clip.width, pixelHeight = clip.height,
        filename = clip.filename, contentKind = NikonMediaContentKind.PLAYABLE_PROXY, stillPhoto = null,
    )
}

package com.opencapture.openzcine

import android.content.Context
import android.content.Intent
import androidx.compose.ui.Modifier
import com.opencapture.monitorui.ReviewLaunch
import com.opencapture.opencine.appkit.MonitorDisplayMode
import com.opencapture.openzcine.media.MediaCacheStore
import com.opencapture.openzcine.media.MediaLibraryCameraBucket
import com.opencapture.openzcine.media.MediaLibraryIndex

internal fun Modifier.reviewMetadata(review: ReviewLaunch?): Modifier = this

/** The Debug-only local review is unavailable in shipped builds. */
internal object MonitorReview {
    fun decode(intent: Intent?): ReviewLaunch? = null
    fun chromeEdit(review: ReviewLaunch?): MonitorDisplayMode? = null
    fun bucket(review: ReviewLaunch?): MediaLibraryCameraBucket? = null
    suspend fun start(context: Context, cache: MediaCacheStore, index: MediaLibraryIndex, review: ReviewLaunch) = Unit
}

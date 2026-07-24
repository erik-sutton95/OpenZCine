package com.opencapture.openzcine

import android.graphics.BitmapFactory
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.blur
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.opencapture.openzcine.core.CameraSession
import com.opencapture.openzcine.media.MediaExifOrientation
import com.opencapture.openzcine.media.upright
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch

/** How the shell reacts to a body-fired capture-complete event. */
internal enum class BodyCaptureSync {
    /** Movie mode, or an app release is in flight (that path syncs itself). */
    IGNORE,

    /** Photo mode without the PLAY tool: refresh the shots readout only. */
    SHOTS_ONLY,

    /** Photo mode with PLAY armed: instant playback plus the shots refresh. */
    REVIEW_AND_SHOTS,
}

/**
 * iOS event-drain guards for a body-fired shutter: react only in photo mode
 * and never while an app-initiated release is in flight — the app path
 * schedules its own review on completion. One review per body run
 * (capture-complete, never per object-added).
 */
internal fun bodyCaptureSyncAction(
    isPhotography: Boolean,
    instantReviewEnabled: Boolean,
    appReleaseInFlight: Boolean,
): BodyCaptureSync =
    when {
        !isPhotography || appReleaseInFlight -> BodyCaptureSync.IGNORE
        instantReviewEnabled -> BodyCaptureSync.REVIEW_AND_SHOTS
        else -> BodyCaptureSync.SHOTS_ONLY
    }

/** One presented instant review (iOS `InstantReviewState`). */
internal data class InstantReviewPresentation(
    val image: ImageBitmap,
    /**
     * False while the tiny embedded thumb stands in — the overlay blurs it
     * behind a spinner, and the review countdown doesn't start until the full
     * image lands (or its stream fails).
     */
    val isFullResolution: Boolean,
    /** Arms the timed dismissal (full image landed, or its stream gave up). */
    val countdownArmed: Boolean,
    /** The captured JPEG's object handle so the overlay can rate it in place. */
    val handle: Int,
    /** Settings line captured at present time so later polls can't rewrite it. */
    val infoLine: String?,
    val starred: Boolean = false,
)

/**
 * Post-capture instant playback (iOS `scheduleInstantReview` /
 * `fetchAndPresentReview`): after a completed release with the PLAY tool on,
 * diff the card against the pre-capture baseline, present the embedded thumb
 * immediately (blurred, spinner), then stream the full image in chunks between
 * live-view frames and swap it over the presented review. One review per run,
 * JPEG-gated — a RAW-only quality has no streamable full image.
 * [verify-on-HW: enumeration lag per body]
 */
internal class InstantReviewController(private val session: CameraSession) {
    private val _review = MutableStateFlow<InstantReviewPresentation?>(null)
    val review: StateFlow<InstantReviewPresentation?> = _review
    private var fetchJob: Job? = null

    /** Arms the post-capture diff with the card's current handles (iOS seed). */
    fun seedBaseline(scope: CoroutineScope) {
        scope.launch { runCatching { session.seedInstantReviewBaseline() } }
    }

    /** Schedules the review for a just-completed capture run. */
    fun onCaptureRunCompleted(
        scope: CoroutineScope,
        enabled: Boolean,
        compression: String?,
        infoLine: String?,
    ) {
        if (!enabled) return
        // JPEG-gated: RAW-only qualities have no streamable full image.
        if (compression?.contains("JPEG") != true) return
        fetchJob?.cancel()
        fetchJob = scope.launch {
            repeat(6) { attempt ->
                val handle = runCatching { session.resolveNewestStillHandle() }.getOrNull()
                if (handle != null) {
                    presentAndUpgrade(handle, infoLine)
                    return@launch
                }
                if (attempt < 5) delay(150)
            }
        }
    }

    private suspend fun presentAndUpgrade(handle: Int, infoLine: String?) {
        val thumbBytes = runCatching { session.stillThumbnail(handle) }.getOrNull() ?: return
        val thumb = decodeReviewBitmap(thumbBytes) ?: return
        _review.value =
            InstantReviewPresentation(
                image = thumb,
                isFullResolution = false,
                countdownArmed = false,
                handle = handle,
                infoLine = infoLine,
            )
        // The embedded thumb is instant but tiny — stream the full image and
        // swap it over the presented review (abandoned once dismissed). A
        // failed stream arms the countdown on the thumb so a timed review can
        // never hang on the blurred stand-in.
        val full =
            runCatching { session.stillFullImage(handle) }.getOrNull()
                ?.let(::decodeReviewBitmap)
        val current = _review.value ?: return
        if (current.handle != handle) return
        _review.value =
            if (full != null) {
                current.copy(image = full, isFullResolution = true, countdownArmed = true)
            } else {
                current.copy(countdownArmed = true)
            }
    }

    /** Writes the one-star favorite in place (iOS `rateInstantReview`). */
    fun setStarred(scope: CoroutineScope, starred: Boolean) {
        val current = _review.value ?: return
        scope.launch {
            val confirmed =
                runCatching { session.setStillRating(current.handle, if (starred) 1 else 0) }
                    .getOrNull()
            if (confirmed != null) {
                val latest = _review.value ?: return@launch
                if (latest.handle == current.handle) {
                    _review.value = latest.copy(starred = confirmed >= 1)
                }
            }
        }
    }

    fun dismiss() {
        fetchJob?.cancel()
        fetchJob = null
        session.cancelStillImageFetch()
        _review.value = null
    }
}

/** Display-sized decode — the review never shows more pixels than the screen. */
private fun decodeReviewBitmap(bytes: ByteArray): ImageBitmap? {
    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
    var sample = 1
    while (
        bounds.outWidth / (sample * 2) > REVIEW_MAX_PIXEL ||
        bounds.outHeight / (sample * 2) > REVIEW_MAX_PIXEL
    ) {
        sample *= 2
    }
    val options = BitmapFactory.Options().apply { inSampleSize = sample }
    // BitmapFactory ignores EXIF — honor it so a portrait capture reviews upright (the full
    // image carries the tag; a stripped embedded thumb stays as-shot until the upgrade).
    return BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options)
        ?.upright(MediaExifOrientation.fromBytes(bytes))
        ?.asImageBitmap()
}

private const val REVIEW_MAX_PIXEL = 4096

// ponytail: fixed review duration; an operator setting (incl. ∞) follows iOS's
// assistConfiguration.instantReviewSeconds when settings grow a photo section.
private const val REVIEW_SECONDS = 3

/**
 * The freshest captured still, full-screen until the review duration elapses
 * or the operator taps it away (iOS instant-review overlay): blurred thumb +
 * spinner until the full image lands, the captured settings line along the
 * bottom, and a single favorite star writing the one-star rating in place.
 */
@Composable
internal fun InstantReviewOverlay(
    review: InstantReviewPresentation,
    onDismiss: () -> Unit,
    onToggleStar: (Boolean) -> Unit,
    modifier: Modifier = Modifier,
) {
    // The countdown starts only once the full image (or its failure fallback)
    // lands — the operator gets the whole duration with the real image.
    LaunchedEffect(review.countdownArmed, review.handle) {
        if (review.countdownArmed) {
            delay(REVIEW_SECONDS * 1000L)
            onDismiss()
        }
    }
    Box(
        modifier
            .fillMaxSize()
            .background(Color.Black.copy(alpha = 0.94f))
            .chromeClickable(onClick = onDismiss)
            .semantics { contentDescription = "Instant playback" },
        contentAlignment = Alignment.Center,
    ) {
        Image(
            bitmap = review.image,
            contentDescription = null,
            contentScale = ContentScale.Fit,
            modifier =
                Modifier.fillMaxSize().blur(if (review.isFullResolution) 0.dp else 16.dp),
        )
        if (!review.isFullResolution) {
            CircularProgressIndicator(
                color = LiveDesign.accent,
                modifier = Modifier.size(34.dp),
            )
        }
        review.infoLine?.let { info ->
            Text(
                info,
                style = chromeStyle(13f, FontWeight.Medium, mono = true),
                color = Color.White.copy(alpha = 0.92f),
                maxLines = 1,
                modifier =
                    Modifier.align(Alignment.BottomCenter)
                        .padding(bottom = 18.dp)
                        .background(
                            Color.Black.copy(alpha = 0.45f),
                            ChromeShape,
                        )
                        .padding(horizontal = 12.dp, vertical = 5.dp),
            )
        }
        // Single favorite star — the culling decision before the next frame.
        Text(
            if (review.starred) "★" else "☆",
            style = chromeStyle(24f, FontWeight.SemiBold),
            color = if (review.starred) LiveDesign.accent else Color.White.copy(alpha = 0.85f),
            modifier =
                Modifier.align(Alignment.TopEnd)
                    .padding(top = 14.dp, end = 18.dp)
                    .chromeClickable { onToggleStar(!review.starred) }
                    .padding(8.dp)
                    .semantics {
                        contentDescription =
                            if (review.starred) "Remove favorite star" else "Favorite this shot"
                    },
        )
    }
}

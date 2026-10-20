package com.opencapture.openzcine

import com.opencapture.opencine.nikon.LiveFocusResult
import com.opencapture.opencine.nikon.LiveFocusInfo
import com.opencapture.opencine.appkit.MonitorReviewOptions
import com.opencapture.monitorui.MonitorRect
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.geometry.Offset
import androidx.compose.foundation.Canvas
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
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.ui.layout.ContentScale
import com.opencapture.openzcine.settings.LocalFramingAssistConfiguration
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.opencapture.opencine.nikon.CameraSession
import com.opencapture.openzcine.media.MediaExifOrientation
import com.opencapture.openzcine.media.upright
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import com.opencapture.opencine.cameracontrols.chromeClickable

/** One presented instant review (iOS `InstantReviewState`). */
internal data class InstantReviewPresentation(
    val image: ImageBitmap,
    /**
     * False while the tiny embedded thumb stands in — the overlay blurs it
     * behind a spinner, and the review countdown doesn't start until the sharp
     * image (the JPEG/HEIF itself, or a RAW's embedded preview) lands, or its
     * read fails.
     */
    val isFullResolution: Boolean,
    /** Arms the timed dismissal (sharp image landed, or its read gave up). */
    val countdownArmed: Boolean,
    /** The captured still's object handle so the overlay can rate it in place. */
    val handle: Int,
    /** Settings line captured at present time so later polls can't rewrite it. */
    val infoLine: String?,
    val starred: Boolean = false,
    /** The camera's AF metadata when this capture completed; later frames cannot replace it. */
    val focus: LiveFocusInfo? = null,
)

/**
 * Post-capture instant playback (iOS `scheduleInstantReview` /
 * `fetchAndPresentReview`): after a completed release with the PLAY tool on,
 * look up the shot's card object (the `ObjectAdded` handle, else a diff
 * against the pre-capture baseline; Core OpenCineNikon `NikonStillReview`
 * owns the rules) for up to [INSTANT_REVIEW_OBJECT_WINDOW_MILLIS], present the
 * embedded thumb immediately (blurred, spinner), then read the sharp image
 * between live-view frames and swap it over the presented review. One review
 * per run, for every quality: JPEG/HEIF read whole, a RAW-only shot shows its
 * NEF's embedded preview.
 * [verify-on-HW: card write time per body and quality]
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
        infoLine: String?,
        focus: LiveFocusInfo? = null,
    ) {
        if (!enabled) return
        fetchJob?.cancel()
        fetchJob = scope.launch {
            // A slow card write (RAW+JPEG Fine* in M/P/A/S) can land well after
            // the release completes, so the lookup runs for a time window.
            val deadline = System.nanoTime() + INSTANT_REVIEW_OBJECT_WINDOW_MILLIS * 1_000_000L
            while (System.nanoTime() < deadline) {
                val handle = runCatching { session.resolveNewestStillHandle() }.getOrNull()
                if (handle != null) {
                    presentAndUpgrade(handle, infoLine, focus)
                    return@launch
                }
                delay(INSTANT_REVIEW_OBJECT_POLL_MILLIS)
            }
            // The window closed without a new object while an earlier lookup's stand-in thumb
            // is up: arm its countdown so the blurred thumb can never stay on screen.
            _review.value?.let { if (!it.countdownArmed) _review.value = it.copy(countdownArmed = true) }
        }
    }

    private suspend fun presentAndUpgrade(handle: Int, infoLine: String?, focus: LiveFocusInfo?) {
        val thumb =
            runCatching { session.stillThumbnail(handle) }.getOrNull()?.let(::decodeReviewBitmap)
        if (thumb != null) {
            _review.value =
                InstantReviewPresentation(
                    image = thumb,
                    isFullResolution = false,
                    countdownArmed = false,
                    handle = handle,
                    infoLine = infoLine,
                    focus = focus,
                )
        }
        // The embedded thumb is instant but tiny: read the sharp image and
        // swap it over the presented review (abandoned once dismissed). A
        // failed read arms the countdown on the thumb so a timed review can
        // never hang on the blurred stand-in. Without a thumb the sharp image
        // is presented directly.
        val sharp =
            runCatching { session.stillFullImage(handle) }.getOrNull()
                ?.let(::decodeReviewBitmap)
        val current = _review.value
        if (thumb == null) {
            if (sharp == null) return
            _review.value =
                InstantReviewPresentation(
                    image = sharp,
                    isFullResolution = true,
                    countdownArmed = true,
                    handle = handle,
                    infoLine = infoLine,
                    focus = focus,
                )
            return
        }
        if (current == null || current.handle != handle) return
        _review.value =
            if (sharp != null) {
                current.copy(image = sharp, isFullResolution = true, countdownArmed = true)
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

/**
 * How long a review looks for the shot's card object; mirrors Core
 * `NikonStillReviewPolicy.objectWindowMilliseconds` (iOS uses it directly).
 */
internal const val INSTANT_REVIEW_OBJECT_WINDOW_MILLIS = 4_000L

/** Pause between lookups; mirrors `NikonStillReviewPolicy.objectPollIntervalMilliseconds`. */
internal const val INSTANT_REVIEW_OBJECT_POLL_MILLIS = 150L

/** The captured AF boxes over the review, present only while Focus Point is on. */
internal const val INSTANT_REVIEW_FOCUS_TAG = "instantReview.focus"

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
    /** De-squeeze configuration; the ratio is derived here, where the still's size is known. */
    desqueeze: LocalFramingAssistConfiguration? = null,
    options: MonitorReviewOptions = MonitorReviewOptions(),
) {
    // The countdown starts only once the full image (or its failure fallback)
    // lands — the operator gets the whole duration with the real image.
    LaunchedEffect(review.countdownArmed, review.handle, options.duration) {
        if (review.countdownArmed) {
            options.duration.automaticDismissMillis?.let { duration ->
                delay(duration)
                onDismiss()
            }
        }
    }
    val desqueezeAspectRatio =
        desqueeze?.desqueezedAspectRatio(review.image.width, review.image.height)
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
            // With a ratio the parent Box's max constraints make `aspectRatio` the fit, and
            // FillBounds stretches the squeezed pixels into it; without one nothing changes.
            contentScale =
                if (desqueezeAspectRatio != null) ContentScale.FillBounds else ContentScale.Fit,
            modifier =
                (
                    if (desqueezeAspectRatio != null) {
                        Modifier.aspectRatio(desqueezeAspectRatio)
                    } else {
                        Modifier.fillMaxSize()
                    }
                ).blur(if (review.isFullResolution) 0.dp else 16.dp),
        )
        if (!review.isFullResolution) {
            CircularProgressIndicator(
                color = LiveDesign.accent,
                modifier = Modifier.size(34.dp),
            )
        }
        if (options.showsFocusPoint) review.focus?.takeIf { it.coordinateWidth > 0 && it.coordinateHeight > 0 }?.let { focus ->
            Canvas(Modifier.fillMaxSize().testTag(INSTANT_REVIEW_FOCUS_TAG)) {
                val aspect = desqueezeAspectRatio ?: (review.image.width.toFloat() / review.image.height)
                val fitted = MonitorRect(0f, 0f, size.width, size.height).fittedContent(aspect)
                focus.boxes.forEach { box ->
                    val width = (box.width.toFloat() / focus.coordinateWidth * fitted.width).coerceAtLeast(10f)
                    val height = (box.height.toFloat() / focus.coordinateHeight * fitted.height).coerceAtLeast(10f)
                    drawRect(if (focus.result == LiveFocusResult.FOCUSED) Color.Green else Color.White,
                        topLeft = Offset(
                            fitted.x + box.centerX.toFloat() / focus.coordinateWidth * fitted.width - width / 2,
                            fitted.y + box.centerY.toFloat() / focus.coordinateHeight * fitted.height - height / 2),
                        size = Size(width, height),
                        style = Stroke(2.dp.toPx()))
                }
            }
        }
        review.infoLine?.takeIf { options.showsCaptureInfo }?.let { info ->
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

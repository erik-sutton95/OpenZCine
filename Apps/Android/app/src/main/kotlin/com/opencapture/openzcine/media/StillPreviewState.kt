package com.opencapture.openzcine.media

/** The text-and-chrome state of one Android still-photo viewer request. */
internal sealed interface StillPreviewUiState {
    /** The camera thumbnail is being requested before any payload transfer. */
    data object Preparing : StillPreviewUiState

    /** A decodable image payload is arriving in the shared progressive cache. */
    data class Downloading(
        val progress: Double,
        val message: String,
    ) : StillPreviewUiState

    /** A full still image decoded successfully from the cache. */
    data object FullPreview : StillPreviewUiState

    /** The camera thumbnail remains visible because no full preview is available. */
    data class ThumbnailFallback(val message: String) : StillPreviewUiState

    /** The camera transfer failed before a full preview could be decoded. */
    data class Failed(val message: String) : StillPreviewUiState

    /** The viewer has invalidated its request and must not accept more updates. */
    data object Closed : StillPreviewUiState
}

/** Pure presentation policy for full-preview progress and honest decoder fallbacks. */
internal object StillPreviewStates {
    fun initial(): StillPreviewUiState = StillPreviewUiState.Preparing

    fun downloading(
        classification: StillPhotoClassification,
        progress: Double,
    ): StillPreviewUiState.Downloading {
        val message =
            when (classification.previewStrategy) {
                StillPreviewStrategy.PROGRESSIVE ->
                    "Loading full ${classification.formatLabel} preview…"
                StillPreviewStrategy.COMPLETE_FILE ->
                    "Downloading ${classification.formatLabel} image…"
                StillPreviewStrategy.THUMBNAIL_ONLY ->
                    "Preparing camera thumbnail…"
            }
        return StillPreviewUiState.Downloading(progress.coerceIn(0.0, 1.0), message)
    }

    fun decoderUnavailable(
        classification: StillPhotoClassification,
        hasThumbnail: Boolean,
    ): StillPreviewUiState.ThumbnailFallback =
        StillPreviewUiState.ThumbnailFallback(
            buildString {
                append(
                    when (classification.previewStrategy) {
                        StillPreviewStrategy.THUMBNAIL_ONLY ->
                            "${classification.formatLabel} files are not decoded for a full preview on Android."
                        StillPreviewStrategy.PROGRESSIVE,
                        StillPreviewStrategy.COMPLETE_FILE,
                        ->
                            "This ${classification.formatLabel} image could not be decoded for a full preview on this Android device."
                    },
                )
                append(
                    if (hasThumbnail) {
                        " Showing the camera thumbnail."
                    } else {
                        " The camera did not provide a thumbnail."
                    },
                )
            },
        )

    fun transferFailed(
        message: String,
        hasThumbnail: Boolean,
    ): StillPreviewUiState.Failed =
        StillPreviewUiState.Failed(
            if (hasThumbnail) "$message Showing the camera thumbnail." else message,
        )
}

/**
 * Generation gate for asynchronous thumbnail, cache, and decode work.
 *
 * Compose cancellation stops the caller, while this tiny gate also rejects a
 * non-cooperative bitmap decode that returns after the viewer has closed or a
 * new request has replaced it.
 */
internal class StillViewerLoadGate {
    private var generation: Long = 0

    fun begin(): Long {
        generation += 1
        return generation
    }

    fun invalidate() {
        generation += 1
    }

    fun accepts(requestGeneration: Long): Boolean = generation == requestGeneration
}

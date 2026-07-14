package com.opencapture.openzcine.media

import android.graphics.BitmapFactory
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.displayCutout
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.opencapture.openzcine.FilmGlyph
import com.opencapture.openzcine.LiveDesign
import com.opencapture.openzcine.bridge.SwiftCore
import com.opencapture.openzcine.chromeClickable
import com.opencapture.openzcine.chromeStyle
import com.opencapture.openzcine.glass
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Enumeration cap handed to the facade — at most this many ObjectInfo round
 * trips per listing, so a packed card never wedges the session (the iOS USB
 * lesson: never gate on cataloging a whole card).
 */
private const val MAX_LISTED_OBJECTS = 256

/** Loading / loaded / failed states of one listing pass. */
private sealed interface BrowseState {
    data object Loading : BrowseState

    data class Loaded(val clips: List<MediaClipRecord>) : BrowseState

    data class Failed(val message: String) : BrowseState
}

/**
 * Full-screen media browse — the v1 (browse-only) Android port of the iOS
 * `MediaBrowserView` main column (ios/Runner/MediaBrowser.swift): the
 * MULTIMEDIA header, the adaptive dark clip grid with size/codec badges, and
 * the listing/empty states. Sidebar tabs, filters, selection, and playback
 * land with later slices. Renders over the monitor; [onClose] returns to it.
 */
@Composable
fun MediaBrowseScreen(onClose: () -> Unit) {
    var state by remember { mutableStateOf<BrowseState>(BrowseState.Loading) }
    var reloadKey by remember { mutableIntStateOf(0) }

    LaunchedEffect(reloadKey) {
        state = BrowseState.Loading
        state =
            withContext(Dispatchers.IO) {
                if (!SwiftCore.isAvailable) {
                    BrowseState.Failed("Camera core is not bundled in this build.")
                } else {
                    SwiftCore.sessionListMedia(MAX_LISTED_OBJECTS)
                        ?.let { BrowseState.Loaded(MediaClips.newestFirst(MediaClips.parse(it))) }
                        ?: BrowseState.Failed("Not connected to a camera.")
                }
            }
    }

    // iOS browser edge treatment: cutout-aware padding with landscape floors
    // (leading 64dp clears the floating close button; see MediaBrowserView).
    val density = LocalDensity.current
    val direction = LocalLayoutDirection.current
    val cutout = WindowInsets.displayCutout
    fun edge(insetPx: Int, extra: Float, floor: Float): Float =
        maxOf(with(density) { insetPx.toDp().value } + extra, floor)
    val topPad = edge(cutout.getTop(density), 6f, 16f)
    val leadingPad = edge(cutout.getLeft(density, direction), 6f, 64f)
    val trailingPad = edge(cutout.getRight(density, direction), 6f, 20f)
    val bottomPad = edge(cutout.getBottom(density), 4f, 14f)

    Box(Modifier.fillMaxSize().background(LiveDesign.background)) {
        Column(
            Modifier.fillMaxSize()
                .padding(
                    top = topPad.dp,
                    start = leadingPad.dp,
                    end = trailingPad.dp,
                    bottom = bottomPad.dp,
                ),
            verticalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            BrowseHeader(state)
            when (val current = state) {
                BrowseState.Loading -> ListingState()
                is BrowseState.Failed ->
                    FailedState(current.message, onRetry = { reloadKey++ })
                is BrowseState.Loaded ->
                    if (current.clips.isEmpty()) EmptyState() else ClipGrid(current.clips)
            }
        }

        // Floating close button (iOS `CloseButton`), over the corner.
        CloseCircleButton(
            Modifier.padding(start = 16.dp, top = maxOf(topPad, 22f).dp),
            onClick = onClose,
        )
    }
}

/** The iOS main-column header: MULTIMEDIA kicker, title, item count. */
@Composable
private fun BrowseHeader(state: BrowseState) {
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(
            "MULTIMEDIA",
            style = chromeStyle(10f, FontWeight.Bold, mono = true).copy(letterSpacing = 0.8.sp),
            color = LiveDesign.muted,
        )
        Row(
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                "All clips",
                style = chromeStyle(26f, FontWeight.SemiBold),
                color = LiveDesign.text,
            )
            Text("·", style = chromeStyle(18f, FontWeight.Medium), color = LiveDesign.faint)
            Text(
                when (state) {
                    BrowseState.Loading -> "Scanning…"
                    is BrowseState.Failed -> "—"
                    is BrowseState.Loaded ->
                        "${state.clips.size} item${if (state.clips.size == 1) "" else "s"}"
                },
                style = chromeStyle(14f, FontWeight.Medium),
                color = LiveDesign.muted,
            )
        }
    }
}

/** The adaptive dark clip grid (iOS `gridCells`, medium thumbnail preset). */
@Composable
private fun ClipGrid(clips: List<MediaClipRecord>) {
    LazyVerticalGrid(
        columns = GridCells.Adaptive(minSize = 210.dp),
        horizontalArrangement = Arrangement.spacedBy(16.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
        // iOS parity: the grid scrolls its last row clear of the fold.
        contentPadding = PaddingValues(bottom = 24.dp),
    ) {
        items(clips, key = { it.handle }) { clip -> ClipCell(clip) }
    }
}

/** One clip cell: 16:9 thumbnail, badge bottom-right, filename below. */
@Composable
private fun ClipCell(clip: MediaClipRecord) {
    var thumbnail by remember(clip.handle) { mutableStateOf<ImageBitmap?>(null) }
    LaunchedEffect(clip.handle) {
        if (thumbnail != null) return@LaunchedEffect
        thumbnail =
            withContext(Dispatchers.IO) {
                SwiftCore.sessionThumbnail(clip.handle.toInt())?.let { jpeg ->
                    BitmapFactory.decodeByteArray(jpeg, 0, jpeg.size)?.asImageBitmap()
                }
            }
    }

    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Box(
            Modifier.fillMaxWidth()
                .aspectRatio(16f / 9f)
                .clip(RoundedCornerShape(LiveDesign.CORNER_RADIUS_DP.dp))
                .background(LiveDesign.surface)
                .border(
                    1.dp,
                    LiveDesign.hairline,
                    RoundedCornerShape(LiveDesign.CORNER_RADIUS_DP.dp),
                ),
            contentAlignment = Alignment.Center,
        ) {
            val image = thumbnail
            if (image != null) {
                Image(
                    bitmap = image,
                    contentDescription = clip.filename,
                    modifier = Modifier.fillMaxSize(),
                    contentScale = ContentScale.Crop,
                )
            } else {
                FilmGlyph(LiveDesign.faint, Modifier.size(34.dp, 30.dp))
            }
            Text(
                clip.badgeLabel,
                style = chromeStyle(10f, FontWeight.Bold, mono = true),
                color = LiveDesign.text,
                modifier =
                    Modifier.align(Alignment.BottomEnd)
                        .padding(8.dp)
                        .background(Color.Black.copy(alpha = 0.58f), RoundedCornerShape(4.dp))
                        .padding(horizontal = 6.dp, vertical = 3.dp),
            )
        }
        Text(
            clip.filename,
            style = chromeStyle(12f, FontWeight.Medium),
            color = LiveDesign.text,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

/** iOS `listingState`: spinner over "Listing clips on camera…". */
@Composable
private fun ListingState() {
    CenteredState {
        CircularProgressIndicator(color = LiveDesign.muted)
        Text(
            "Listing clips on camera…",
            style = chromeStyle(15f, FontWeight.Medium),
            color = LiveDesign.muted,
        )
        Text(
            "Querying card storage…",
            style = chromeStyle(12f, FontWeight.Normal),
            color = LiveDesign.faint,
        )
    }
}

/** iOS `emptyState`: film glyph, title, subtitle. */
@Composable
private fun EmptyState() {
    CenteredState {
        FilmGlyph(LiveDesign.faint, Modifier.size(44.dp, 40.dp))
        Text(
            "No clips yet",
            style = chromeStyle(15f, FontWeight.Medium),
            color = LiveDesign.muted,
        )
        Text(
            "Clips appear here as they're discovered on the card.",
            style = chromeStyle(12f, FontWeight.Normal),
            color = LiveDesign.faint,
        )
    }
}

/** Listing failure (including "not connected"), with a retry pill. */
@Composable
private fun FailedState(message: String, onRetry: () -> Unit) {
    CenteredState {
        Text(
            "Couldn't list media",
            style = chromeStyle(15f, FontWeight.Medium),
            color = LiveDesign.muted,
        )
        Text(message, style = chromeStyle(12f, FontWeight.Normal), color = LiveDesign.faint)
        Text(
            "Retry",
            style = chromeStyle(13f, FontWeight.SemiBold),
            color = LiveDesign.accent,
            modifier =
                Modifier.glass(CircleShape)
                    .chromeClickable(onRetry)
                    .padding(horizontal = 16.dp, vertical = 8.dp),
        )
    }
}

/** Shared centered-column scaffold for the listing/empty/failed states. */
@Composable
private fun CenteredState(content: @Composable () -> Unit) {
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            content()
        }
    }
}

/** Round glass close button with an X glyph (iOS `CloseButton`, 37pt). */
@Composable
private fun CloseCircleButton(modifier: Modifier = Modifier, onClick: () -> Unit) {
    Box(
        modifier.size(37.dp).glass(CircleShape).chromeClickable(onClick),
        contentAlignment = Alignment.Center,
    ) {
        Canvas(Modifier.size(11.dp)) {
            val stroke = 1.8.dp.toPx()
            drawLine(
                LiveDesign.text,
                Offset(0f, 0f),
                Offset(size.width, size.height),
                stroke,
                StrokeCap.Round,
            )
            drawLine(
                LiveDesign.text,
                Offset(size.width, 0f),
                Offset(0f, size.height),
                stroke,
                StrokeCap.Round,
            )
        }
    }
}

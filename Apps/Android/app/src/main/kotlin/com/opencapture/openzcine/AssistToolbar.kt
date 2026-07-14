package com.opencapture.openzcine

import android.content.Context
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.CompositingStrategy
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp

/**
 * The eight v1 assist-toolbar tools, mirroring the iOS bottom-left strip
 * (`MonitorAssistTool` in the shared core): four feed effects and four scopes.
 * The iOS-only framing aids (guides/grid/crosshair/level/de-sq) and audio
 * meters land with their engines.
 */
enum class AssistTool(val label: String) {
    LUT("LUT"),
    PEAK("PEAK"),
    FALSE("FALSE"),
    ZEBRA("ZEBRA"),
    WAVE("WAVE"),
    PARADE("PARADE"),
    HISTO("HISTO"),
    VECTOR("VECTOR"),
}

/**
 * Assist toggle state behind the toolbar: the feed-effect set (LUT / false
 * colour / peaking / zebra, baked by [FeedEffectsRenderer]) and the active
 * scope panel. Every change is mirrored into [FeedEffectsState.current] (the
 * engine input `LiveFeedView` reads) and handed to [persist].
 *
 * Debug intents still win a session: when the launch intent carried any
 * `zc.assist`/`zc.scopes` selection, [restore] seeds from it verbatim instead
 * of the persisted toggles, keeping the intent-driven tests deterministic.
 */
class AssistState(
    initialEffects: FeedEffects,
    initialScope: ScopeKind?,
    private val persist: (FeedEffects, ScopeKind?) -> Unit = { _, _ -> },
) {
    var effects: FeedEffects by mutableStateOf(initialEffects)
        private set

    var scope: ScopeKind? by mutableStateOf(initialScope)
        private set

    init {
        FeedEffectsState.current = initialEffects
    }

    /** Whether [tool]'s pill renders lit. */
    fun isOn(tool: AssistTool): Boolean =
        when (tool) {
            AssistTool.LUT -> effects.lut != null
            AssistTool.PEAK -> effects.peaking
            AssistTool.FALSE -> effects.falseColor != null
            AssistTool.ZEBRA -> effects.zebra
            AssistTool.WAVE -> scope == ScopeKind.WAVEFORM
            AssistTool.PARADE -> scope == ScopeKind.PARADE
            AssistTool.HISTO -> scope == ScopeKind.HISTOGRAM
            AssistTool.VECTOR -> scope == ScopeKind.VECTORSCOPE
        }

    /**
     * Toggles [tool]. LUT and false colour are mutually exclusive (false
     * colour *is* the monitoring image, iOS semantics); scopes are
     * single-active in v1 — tapping another scope switches to it.
     */
    // ponytail: no LUT-restore memory when false colour turns off, and one
    // scope at a time; multi-scope + remembered looks arrive with the iOS
    // preference model.
    fun toggle(tool: AssistTool) {
        when (tool) {
            AssistTool.LUT ->
                update(
                    effects.copy(
                        lut = if (effects.lut == null) FeedLut.LOG3G10_709 else null,
                        falseColor = null,
                    ),
                )
            AssistTool.FALSE ->
                update(
                    effects.copy(
                        falseColor =
                            if (effects.falseColor == null) FeedFalseColorScale.STOPS else null,
                        lut = null,
                    ),
                )
            AssistTool.PEAK -> update(effects.copy(peaking = !effects.peaking))
            AssistTool.ZEBRA -> update(effects.copy(zebra = !effects.zebra))
            AssistTool.WAVE -> toggleScope(ScopeKind.WAVEFORM)
            AssistTool.PARADE -> toggleScope(ScopeKind.PARADE)
            AssistTool.HISTO -> toggleScope(ScopeKind.HISTOGRAM)
            AssistTool.VECTOR -> toggleScope(ScopeKind.VECTORSCOPE)
        }
    }

    private fun toggleScope(kind: ScopeKind) {
        scope = if (scope == kind) null else kind
        persist(effects, scope)
    }

    private fun update(next: FeedEffects) {
        effects = next
        FeedEffectsState.current = next
        persist(effects, scope)
    }

    companion object {
        private const val PREFS = "assist"

        /** Serializes [effects] back into the `zc.assist` token grammar. */
        fun tokens(effects: FeedEffects): String =
            listOfNotNull(
                "lut".takeIf { effects.lut != null },
                "falsecolor".takeIf { effects.falseColor != null },
                "peaking".takeIf { effects.peaking },
                "zebra".takeIf { effects.zebra },
            ).joinToString(",")

        /**
         * Restores the persisted toggles from SharedPreferences — unless the
         * launch intent specified a selection ([intentEffects] non-identity or
         * [intentScope] non-null), which then IS the session state.
         */
        fun restore(context: Context, intentEffects: FeedEffects, intentScope: ScopeKind?): AssistState {
            val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val fromIntent = !intentEffects.isIdentity || intentScope != null
            val effects =
                if (fromIntent) {
                    intentEffects
                } else {
                    FeedEffects.parse(
                        prefs.getString("tokens", null),
                        prefs.getString("lut", null),
                        prefs.getString("fcScale", null),
                    )
                }
            val scope =
                if (fromIntent) intentScope else ScopeKind.fromToken(prefs.getString("scope", null))
            return AssistState(effects, scope) { nextEffects, nextScope ->
                prefs.edit()
                    .putString("tokens", tokens(nextEffects))
                    .putString("lut", nextEffects.lut?.id)
                    .putString("fcScale", nextEffects.falseColor?.id)
                    .putString("scope", nextScope?.token)
                    .apply()
            }
        }
    }
}

/**
 * The bottom assist toolbar (iOS `MonitorAssistStrip`, `axis: .horizontal`):
 * a glass pill holding a horizontal scroller of tool cells, grouped into
 * threes by hairline dividers, with gold edge chevrons + fades hinting at
 * off-screen tools. Mounted at the zone map's `assistStrip` zone in landscape
 * live mode and the portrait fit-mode toolbar band.
 */
@Composable
fun AssistToolbar(state: AssistState, modifier: Modifier = Modifier) {
    val scroll = rememberScrollState()
    val leadingFade = scroll.canScrollBackward
    val trailingFade = scroll.canScrollForward
    Box(modifier.glass(ChromeShape)) {
        Row(
            Modifier
                .fillMaxHeight()
                .padding(start = 7.dp, end = 14.dp)
                .graphicsLayer { compositingStrategy = CompositingStrategy.Offscreen }
                .drawWithContent {
                    drawContent()
                    // Edge fades (iOS ScrollEdgeFades.gradient): scrolled-under
                    // tools dissolve at the active edge.
                    val fade = size.width * 0.09f
                    if (leadingFade) {
                        drawRect(
                            Brush.horizontalGradient(
                                0f to Color.Transparent, 1f to Color.Black, endX = fade,
                            ),
                            size = Size(fade, size.height),
                            blendMode = BlendMode.DstIn,
                        )
                    }
                    if (trailingFade) {
                        drawRect(
                            Brush.horizontalGradient(
                                0f to Color.Black, 1f to Color.Transparent,
                                startX = size.width - fade, endX = size.width,
                            ),
                            topLeft = Offset(size.width - fade, 0f),
                            size = Size(fade, size.height),
                            blendMode = BlendMode.DstIn,
                        )
                    }
                }
                .horizontalScroll(scroll),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            AssistTool.entries.forEachIndexed { index, tool ->
                if (index > 0 && index % 3 == 0) {
                    Box(
                        Modifier.padding(horizontal = 4.dp)
                            .size(width = 1.dp, height = 28.dp)
                            .background(LiveDesign.hairlineStrong),
                    )
                }
                AssistToolCell(tool, state.isOn(tool)) { state.toggle(tool) }
            }
        }
        ScrollChevron(leading = true, visible = leadingFade, Modifier.align(Alignment.CenterStart))
        ScrollChevron(leading = false, visible = trailingFade, Modifier.align(Alignment.CenterEnd))
    }
}

/** Gold edge chevron hinting at off-screen tools (iOS `scrollChevron`). */
@Composable
private fun ScrollChevron(leading: Boolean, visible: Boolean, modifier: Modifier = Modifier) {
    Canvas(
        modifier
            .padding(horizontal = 5.dp)
            .size(8.dp, 12.dp)
            .alpha(if (visible) 1f else 0f),
    ) {
        val path =
            Path().apply {
                if (leading) {
                    moveTo(size.width, 0f)
                    lineTo(0f, size.height / 2)
                    lineTo(size.width, size.height)
                } else {
                    moveTo(0f, 0f)
                    lineTo(size.width, size.height / 2)
                    lineTo(0f, size.height)
                }
            }
        drawPath(
            path,
            LiveDesign.accent,
            style = Stroke(2.dp.toPx(), cap = StrokeCap.Round, join = StrokeJoin.Round),
        )
    }
}

/**
 * One tool pill: glyph over a mono label, gold-on-dim-accent while on (iOS
 * `AssistToolButton`, the mockup `.tool` box model with its 52pt floor).
 */
@Composable
private fun AssistToolCell(tool: AssistTool, isOn: Boolean, onClick: () -> Unit) {
    val tint = if (isOn) LiveDesign.accent else LiveDesign.muted
    Column(
        modifier =
            Modifier
                .background(if (isOn) LiveDesign.accentDim else Color.Transparent, ChromeShape)
                .chromeClickable(onClick)
                .padding(vertical = 5.dp, horizontal = 8.dp)
                .widthIn(min = 36.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Box(Modifier.height(23.dp), contentAlignment = Alignment.Center) {
            AssistToolGlyph(tool, tint, Modifier.size(19.dp))
        }
        Text(
            tool.label,
            style = chromeStyle(9f, FontWeight.Medium, mono = true),
            color = tint,
            maxLines = 1,
        )
    }
}

/** Canvas stand-ins for the iOS SF Symbol per tool (`MonitorAssistTool.icon`). */
@Composable
private fun AssistToolGlyph(tool: AssistTool, tint: Color, modifier: Modifier = Modifier) {
    Canvas(modifier) {
        val stroke = Stroke(1.6.dp.toPx(), cap = StrokeCap.Round, join = StrokeJoin.Round)
        when (tool) {
            // SF `camera.filters`: three overlapping circles.
            AssistTool.LUT -> {
                val r = size.minDimension * 0.28f
                drawCircle(tint, r, Offset(size.width / 2, r), style = stroke)
                drawCircle(tint, r, Offset(r, size.height - r), style = stroke)
                drawCircle(tint, r, Offset(size.width - r, size.height - r), style = stroke)
            }
            // SF `mountain.2`: two peaks.
            AssistTool.PEAK -> {
                val base = size.height * 0.85f
                val path =
                    Path().apply {
                        moveTo(0f, base)
                        lineTo(size.width * 0.32f, size.height * 0.25f)
                        lineTo(size.width * 0.52f, base * 0.72f)
                        lineTo(size.width * 0.70f, size.height * 0.42f)
                        lineTo(size.width, base)
                    }
                drawPath(path, tint, style = stroke)
            }
            // SF `circle.lefthalf.filled`.
            AssistTool.FALSE -> {
                val r = size.minDimension / 2 - 1.dp.toPx()
                val c = Offset(size.width / 2, size.height / 2)
                drawCircle(tint, r, c, style = stroke)
                drawArc(
                    tint,
                    startAngle = 90f,
                    sweepAngle = 180f,
                    useCenter = true,
                    topLeft = Offset(c.x - r, c.y - r),
                    size = Size(2 * r, 2 * r),
                )
            }
            // Three diagonal stripes (iOS `ZebraStripesShape`).
            AssistTool.ZEBRA -> {
                val diag = 0.7071f
                val halfLen = size.minDimension * 0.40f / 2
                val step = size.minDimension * 0.27f
                for (index in 0 until 3) {
                    val offset = index - 1f
                    val cx = size.width / 2 + offset * step * diag
                    val cy = size.height / 2 + offset * step * diag
                    drawLine(
                        tint,
                        Offset(cx - halfLen * 2 * diag, cy + halfLen * 2 * diag),
                        Offset(cx + halfLen * 2 * diag, cy - halfLen * 2 * diag),
                        strokeWidth = 2.dp.toPx(),
                        cap = StrokeCap.Round,
                    )
                }
            }
            // SF `waveform.path`: one luma trace line.
            AssistTool.WAVE -> {
                val midY = size.height / 2
                val path =
                    Path().apply {
                        moveTo(0f, midY)
                        lineTo(size.width * 0.2f, midY - size.height * 0.32f)
                        lineTo(size.width * 0.4f, midY + size.height * 0.28f)
                        lineTo(size.width * 0.6f, midY - size.height * 0.18f)
                        lineTo(size.width * 0.8f, midY + size.height * 0.34f)
                        lineTo(size.width, midY)
                    }
                drawPath(path, tint, style = stroke)
            }
            // SF `chart.bar.xaxis`: bars on a baseline.
            AssistTool.PARADE -> {
                val base = size.height * 0.82f
                drawLine(tint, Offset(0f, base), Offset(size.width, base), 1.6.dp.toPx())
                val barW = size.width * 0.17f
                for ((index, heightScale) in listOf(0.45f, 0.75f, 0.6f).withIndex()) {
                    drawRoundRect(
                        tint,
                        topLeft =
                            Offset(size.width * (0.1f + 0.3f * index), base - base * heightScale),
                        size = Size(barW, base * heightScale),
                        cornerRadius = CornerRadius(barW * 0.3f),
                    )
                }
            }
            // SF `waveform`: symmetric level bars.
            AssistTool.HISTO -> {
                val midY = size.height / 2
                for ((index, heightScale) in
                    listOf(0.25f, 0.55f, 0.9f, 0.45f, 0.7f, 0.3f).withIndex()) {
                    val x = size.width * (0.08f + 0.168f * index)
                    drawLine(
                        tint,
                        Offset(x, midY - size.height * heightScale / 2),
                        Offset(x, midY + size.height * heightScale / 2),
                        strokeWidth = 1.8.dp.toPx(),
                        cap = StrokeCap.Round,
                    )
                }
            }
            // SF `circle.grid.cross`: graticule circle + cross.
            AssistTool.VECTOR -> {
                val r = size.minDimension / 2 - 1.dp.toPx()
                val c = Offset(size.width / 2, size.height / 2)
                drawCircle(tint, r, c, style = stroke)
                val gap = r * 0.4f
                drawLine(tint, Offset(c.x, c.y - r), Offset(c.x, c.y - gap), 1.6.dp.toPx())
                drawLine(tint, Offset(c.x, c.y + gap), Offset(c.x, c.y + r), 1.6.dp.toPx())
                drawLine(tint, Offset(c.x - r, c.y), Offset(c.x - gap, c.y), 1.6.dp.toPx())
                drawLine(tint, Offset(c.x + gap, c.y), Offset(c.x + r, c.y), 1.6.dp.toPx())
            }
        }
    }
}

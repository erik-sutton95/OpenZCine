package com.opencapture.openzcine

import android.content.Context
import android.content.SharedPreferences
import android.view.HapticFeedbackConstants
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
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp

/**
 * The assist-toolbar tools, mirroring the iOS bottom-left strip
 * (`MonitorAssistTool` in the shared core): four feed effects and five scopes.
 * The iOS-only framing aids (guides/grid/crosshair/level/de-sq) and audio
 * meters land with their engines.
 */
enum class AssistTool(val label: String, val settingsTitle: String) {
    LUT("LUT", "LUT"),
    PEAK("PEAK", "Focus Peaking"),
    FALSE("FALSE", "False Color"),
    ZEBRA("ZEBRA", "Zebra"),
    WAVE("WAVE", "Waveform"),
    PARADE("PARADE", "Parade"),
    HISTO("HISTO", "Histogram"),
    VECTOR("VECTOR", "Vectorscope"),
    LIGHTS("LIGHTS", "Traffic Lights"),

    ;

    companion object {
        /** Decodes a persisted enum name while safely ignoring retired or malformed values. */
        internal fun fromStoredName(value: String): AssistTool? =
            entries.firstOrNull { it.name == value }
    }
}

/**
 * Assist toggle state behind the toolbar: the feed-effect set (LUT / false
 * colour / peaking / zebra, baked by [FeedEffectsRenderer]) and independently
 * selected scope panels. Every change is mirrored into [FeedEffectsState.current]
 * (the engine input `LiveFeedView` reads) and handed to [persist].
 *
 * Debug intents still win a session: when the launch intent carried any
 * `zc.assist`/`zc.scopes` selection, [restore] seeds from it verbatim instead
 * of the persisted toggles, keeping the intent-driven tests deterministic.
 */
class AssistState(
    initialEffects: FeedEffects,
    initialScope: ScopeKind?,
    initialScopes: Set<ScopeKind> = initialScope?.let(::setOf) ?: emptySet(),
    initialScopeActivationOrder: List<ScopeKind> = ScopeKind.canonical.filter(initialScopes::contains),
    initialLut: FeedLut = initialEffects.lut ?: FeedLut.LOG3G10_709,
    initialFalseColorScale: FeedFalseColorScale =
        initialEffects.falseColor ?: FeedFalseColorScale.STOPS,
    private val persistSelections: (FeedLut, FeedFalseColorScale) -> Unit = { _, _ -> },
    private val persistScopeSelections: (Set<ScopeKind>, List<ScopeKind>) -> Unit = { _, _ -> },
    private val persist: (FeedEffects, ScopeKind?) -> Unit = { _, _ -> },
) {
    var effects: FeedEffects by mutableStateOf(initialEffects)
        private set

    /** Every independently enabled scope tool, in the iOS canonical domain. */
    var selectedScopes: Set<ScopeKind> by mutableStateOf(ScopeKind.canonical.filter(initialScopes::contains).toSet())
        private set

    /** Oldest-to-newest scope activation history, used by portrait's two-panel selection. */
    var scopeActivationOrder: List<ScopeKind> by
        mutableStateOf(normalizeScopeOrder(initialScopeActivationOrder, selectedScopes))
        private set

    /**
     * Compatibility view of the legacy one-scope preference: the most recently
     * activated scope, or the canonical last active scope after an old migration.
     */
    val scope: ScopeKind?
        get() = scopeActivationOrder.lastOrNull() ?: ScopeKind.canonical.lastOrNull(selectedScopes::contains)

    /** The at-most-two scopes portrait fit mode mounts, matching iOS recency policy. */
    val displayedPortraitScopes: List<ScopeKind>
        get() = portraitDisplayedScopes(selectedScopes, scopeActivationOrder)

    /** The LUT that will be enabled next, retained even while LUT is off. */
    var selectedLut: FeedLut by mutableStateOf(initialLut)
        private set

    /** The false-colour scale that will be enabled next, retained while off. */
    var selectedFalseColorScale: FeedFalseColorScale by mutableStateOf(initialFalseColorScale)
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
            AssistTool.WAVE -> ScopeKind.WAVEFORM in selectedScopes
            AssistTool.PARADE -> ScopeKind.PARADE in selectedScopes
            AssistTool.HISTO -> ScopeKind.HISTOGRAM in selectedScopes
            AssistTool.VECTOR -> ScopeKind.VECTORSCOPE in selectedScopes
            AssistTool.LIGHTS -> ScopeKind.TRAFFIC_LIGHTS in selectedScopes
        }

    /**
     * Toggles [tool]. LUT and false colour are mutually exclusive (false
     * colour *is* the monitoring image, iOS semantics). Scopes are independent:
     * tapping another scope leaves an existing scope visible and records the
     * recency Android's portrait layout needs.
     */
    fun toggle(tool: AssistTool) {
        when (tool) {
            AssistTool.LUT ->
                update(
                    effects.copy(
                        lut = if (effects.lut == null) selectedLut else null,
                        falseColor = null,
                    ),
                )
            AssistTool.FALSE ->
                update(
                    effects.copy(
                        falseColor =
                            if (effects.falseColor == null) selectedFalseColorScale else null,
                        lut = null,
                    ),
                )
            AssistTool.PEAK -> update(effects.copy(peaking = !effects.peaking))
            AssistTool.ZEBRA -> update(effects.copy(zebra = !effects.zebra))
            AssistTool.WAVE -> toggleScope(ScopeKind.WAVEFORM)
            AssistTool.PARADE -> toggleScope(ScopeKind.PARADE)
            AssistTool.HISTO -> toggleScope(ScopeKind.HISTOGRAM)
            AssistTool.VECTOR -> toggleScope(ScopeKind.VECTORSCOPE)
            AssistTool.LIGHTS -> toggleScope(ScopeKind.TRAFFIC_LIGHTS)
        }
    }

    /** Selects the LUT used the next time (or currently while) LUT is enabled. */
    fun selectLut(lut: FeedLut) {
        selectedLut = lut
        if (effects.lut != null) {
            update(effects.copy(lut = lut))
        } else {
            persistSelections(selectedLut, selectedFalseColorScale)
        }
    }

    /** Selects the false-colour scale used the next time (or currently while) it is enabled. */
    fun selectFalseColorScale(scale: FeedFalseColorScale) {
        selectedFalseColorScale = scale
        if (effects.falseColor != null) {
            update(effects.copy(falseColor = scale))
        } else {
            persistSelections(selectedLut, selectedFalseColorScale)
        }
    }

    private fun toggleScope(kind: ScopeKind) {
        val next = selectedScopes.toMutableSet()
        val nextOrder = scopeActivationOrder.toMutableList()
        if (next.add(kind)) {
            nextOrder.remove(kind)
            nextOrder += kind
        } else {
            next.remove(kind)
            nextOrder.remove(kind)
        }
        selectedScopes = ScopeKind.canonical.filter(next::contains).toSet()
        scopeActivationOrder = normalizeScopeOrder(nextOrder, selectedScopes)
        persistState()
    }

    private fun update(next: FeedEffects) {
        effects = next
        FeedEffectsState.current = next
        persistState()
    }

    private fun persistState() {
        persist(effects, scope)
        persistScopeSelections(selectedScopes, scopeActivationOrder)
        persistSelections(selectedLut, selectedFalseColorScale)
    }

    companion object {
        private const val PREFS = "assist"
        private const val SCOPES_KEY = "scopes"
        private const val SCOPE_ACTIVATION_ORDER_KEY = "scopeActivationOrder"

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
         * [intentScopes] non-null), which then IS the session state. [intentScope]
         * remains the source-compatible single-scope bridge for existing callers.
         */
        fun restore(
            context: Context,
            intentEffects: FeedEffects,
            intentScope: ScopeKind?,
            intentScopes: List<ScopeKind>? = intentScope?.let(::listOf),
        ): AssistState {
            val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            return restore(prefs, intentEffects, intentScope, intentScopes)
        }

        /** Restores local assist state from [preferences]; exposed to JVM tests through `internal`. */
        internal fun restore(
            preferences: SharedPreferences,
            intentEffects: FeedEffects,
            intentScope: ScopeKind?,
            intentScopes: List<ScopeKind>? = intentScope?.let(::listOf),
        ): AssistState {
            val fromIntent = !intentEffects.isIdentity || intentScopes != null
            val storedLut =
                preferences.getString("lut", null)
                    ?.let(FeedLut::fromId)
                    ?: FeedLut.LOG3G10_709
            val storedFalseColorScale =
                preferences.getString("fcScale", null)
                    ?.let(FeedFalseColorScale::fromId)
                    ?: FeedFalseColorScale.STOPS
            val effects =
                if (fromIntent) {
                    intentEffects
                } else {
                    FeedEffects.parse(
                        preferences.getString("tokens", null),
                        preferences.getString("lut", null),
                        preferences.getString("fcScale", null),
                    )
                }
            val storedScopes =
                ScopeKind.parseTokens(preferences.getString(SCOPES_KEY, null))
                    ?: ScopeKind.fromToken(preferences.getString("scope", null))?.let(::listOf)
                    ?: emptyList()
            val selectedScopes =
                if (fromIntent) {
                    intentScopes.orEmpty()
                } else {
                    storedScopes
                }
            val scopeActivationOrder =
                if (fromIntent) {
                    intentScopes.orEmpty()
                } else {
                    ScopeKind.parseTokens(preferences.getString(SCOPE_ACTIVATION_ORDER_KEY, null)).orEmpty()
                }
            return AssistState(
                effects,
                initialScope = selectedScopes.lastOrNull(),
                initialScopes = selectedScopes.toSet(),
                initialScopeActivationOrder = scopeActivationOrder,
                persist = { nextEffects, nextScope ->
                    preferences.edit()
                        .putString("tokens", tokens(nextEffects))
                        .putString("scope", nextScope?.token)
                        .apply()
                },
                persistScopeSelections = { nextScopes, nextOrder ->
                    preferences.edit()
                        .putString(SCOPES_KEY, ScopeKind.tokens(nextScopes))
                        .putString(SCOPE_ACTIVATION_ORDER_KEY, nextOrder.joinToString(",") { it.token })
                        // Keep the old single selection current for an app version
                        // that has not learned the multi-scope key yet.
                        .putString("scope", nextOrder.lastOrNull()?.token ?: nextScopes.lastOrNull()?.token)
                        .apply()
                },
                initialLut = effects.lut ?: storedLut,
                initialFalseColorScale = effects.falseColor ?: storedFalseColorScale,
                persistSelections = { lut, falseColorScale ->
                    preferences.edit()
                        .putString("lut", lut.id)
                        .putString("fcScale", falseColorScale.id)
                        .apply()
                },
            )
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
fun AssistToolbar(
    state: AssistState,
    modifier: Modifier = Modifier,
    visibleTools: List<AssistTool> = AssistTool.entries.toList(),
    hapticsEnabled: Boolean = true,
) {
    val scroll = rememberScrollState()
    val view = LocalView.current
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
            visibleTools.forEachIndexed { index, tool ->
                if (index > 0 && index % 3 == 0) {
                    Box(
                        Modifier.padding(horizontal = 4.dp)
                            .size(width = 1.dp, height = 28.dp)
                            .background(LiveDesign.hairlineStrong),
                    )
                }
                AssistToolCell(tool, state.isOn(tool)) {
                    state.toggle(tool)
                    if (hapticsEnabled) {
                        view.performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP)
                    }
                }
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
                .semantics {
                    contentDescription = tool.settingsTitle
                    stateDescription = if (isOn) "On" else "Off"
                }
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
            // Three compact RED-style goal posts: top clip dots, centre line,
            // and bottom crush dots. The live panel carries the actual meter.
            AssistTool.LIGHTS -> {
                val columns = listOf(0.2f, 0.5f, 0.8f)
                val top = size.height * 0.16f
                val bottom = size.height * 0.84f
                val centre = size.height / 2
                for (xFraction in columns) {
                    val x = size.width * xFraction
                    drawCircle(tint, size.minDimension * 0.075f, Offset(x, top))
                    drawLine(tint, Offset(x, top + size.height * 0.13f), Offset(x, bottom - size.height * 0.13f), 1.6.dp.toPx())
                    drawLine(tint, Offset(x - size.width * 0.10f, centre), Offset(x + size.width * 0.10f, centre), 1.2.dp.toPx())
                    drawCircle(tint, size.minDimension * 0.075f, Offset(x, bottom))
                }
            }
        }
    }
}

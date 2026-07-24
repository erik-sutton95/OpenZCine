package com.opencapture.openzcine

import android.content.Context
import android.content.SharedPreferences
import android.os.Build
import android.view.HapticFeedbackConstants
import androidx.annotation.StringRes
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
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
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
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
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.opencapture.openzcine.bridge.SwiftCore
import com.opencapture.openzcine.bridge.ZoneFrame
import com.opencapture.openzcine.lut.StoredLutSelection
import com.opencapture.openzcine.settings.LocalFramingAssistConfiguration

/**
 * The assist-toolbar tools, mirroring the iOS bottom-left strip
 * (`MonitorAssistTool` in the shared core): four feed effects, five scopes,
 * camera-derived audio meters, and the Android-owned framing controls. LEVEL
 * only changes local presentation: the overlay still prefers camera metadata
 * and labels its device-gravity fallback, and never writes Nikon camera state.
 */
enum class AssistTool(val label: String, val settingsTitle: String) {
    LUT("LUT", "LUT"),
    PEAK("PEAK", "Peaking"),
    FALSE("FALSE", "False Color"),
    ZEBRA("ZEBRA", "Zebra"),
    WAVE("WAVE", "Waveform"),
    PARADE("PARADE", "RGB Parade"),
    HISTO("HISTO", "Histogram"),
    VECTOR("VECTOR", "Vectorscope"),
    LIGHTS("LIGHTS", "Traffic Lights"),
    GUIDES("GUIDES", "Guides"),
    GRID("GRID", "Grid"),
    CROSS("CROSS", "Crosshair"),
    LEVEL("LEVEL", "Horizon"),
    /** Camera-fed exposure indicator (the body's own metering needle). */
    EV("EV", "EV Meter"),
    DESQ("DE-SQ", "Desqueeze"),
    /** Photography-only instant playback of the just-captured still. */
    PLAY("PLAY", "Instant Playback"),
    AUDIO("AUDIO", "Audio Levels"),

    ;

    /** Whether a long press opens the iOS-equivalent quick-configuration panel. */
    val hasConfiguration: Boolean
        // ponytail: PLAY's iOS options drawer (AF box / info / duration) is a
        // follow-up; the toggle alone covers the between-shots review.
        get() = this != AUDIO && this != EV && this != PLAY

    /**
     * Assist tools that apply to still photography (iOS `appliesToPhotography`):
     * the exposure aids plus the composition aids photographers actually use.
     * Everything else is cinema-only, keeping the photo toolbar deliberately
     * shorter so the stills strip gets the bar width.
     */
    val appliesToPhotography: Boolean
        get() =
            when (this) {
                PEAK, FALSE, ZEBRA, HISTO, GRID, LEVEL, EV, PLAY -> true
                else -> false
            }

    /** Photography-only tools, hidden from the cinema toolbar entirely. */
    val isPhotographyOnly: Boolean
        get() = this == PLAY

    companion object {
        /**
         * Tools whose toggle state lives in [OperatorSettings], never camera or
         * feed-effect state. EV rides with the framing group: its visibility is
         * a local presentation choice, while the value stays camera-fed.
         */
        val framingTools: Set<AssistTool> = setOf(GUIDES, GRID, CROSS, LEVEL, EV, DESQ)

        /** Independently selectable scope panels subject to the portrait fit-mode cap. */
        val scopeTools: Set<AssistTool> = setOf(WAVE, PARADE, HISTO, VECTOR, LIGHTS)

        /** Decodes a persisted enum name while safely ignoring retired or malformed values. */
        internal fun fromStoredName(value: String): AssistTool? =
            entries.firstOrNull { it.name == value }
    }
}

/**
 * Front-pins the between-shots tools (iOS `MonitorAssistStrip.frontPinned`):
 * photography leads with the EV meter (Android has no instant playback, so EV
 * takes the lead slot); video keeps its leading tool and seats EV second.
 */
internal fun frontPinnedAssistTools(
    tools: List<AssistTool>,
    photography: Boolean,
): List<AssistTool> {
    if (photography) {
        // Photography leads with instant playback then the EV meter (iOS pins).
        val pins = listOf(AssistTool.PLAY, AssistTool.EV).filter { it in tools }
        if (pins.isEmpty()) return tools
        return pins + tools.filterNot { it in pins }
    }
    val evIndex = tools.indexOf(AssistTool.EV)
    if (evIndex <= 1) return tools
    val rest = tools.toMutableList()
    rest.removeAt(evIndex)
    rest.add(1, AssistTool.EV)
    return rest
}

/** iOS `MonitorAssistStrip.expandedWidth`: the vertical rail's column width. */
internal const val ASSIST_RAIL_EXPANDED_WIDTH_DP = 60f

/** iOS `MonitorAssistStrip.collapsedPillSize`: the collapsed pill's diameter. */
internal const val ASSIST_RAIL_COLLAPSED_PILL_DP = 44f

/** iOS `MonitorAssistStrip.bottomFadeHeight`: the expanded rail's scroll fade. */
internal const val ASSIST_RAIL_BOTTOM_FADE_DP = 40f

/**
 * Seats photography's collapsible vertical assist rail beside the lock/battery
 * lane (iOS `MonitorUnified` photo-rail placement): the rail clears whichever
 * left-edge chrome reaches furthest (lock button or battery stack) plus 12dp,
 * hugs the lock row while expanded, centre-aligns the collapsed pill on the
 * lock button, and runs down to the assist band's bottom edge unless the
 * measured capture strip actually enters the rail's lane — then it stops 10dp
 * above the band.
 */
internal fun photographyAssistRailFrame(
    lock: ZoneFrame,
    batteryTrailing: Float?,
    assistBand: ZoneFrame,
    measuredCaptureBar: ZoneFrame?,
    expanded: Boolean,
): ZoneFrame {
    val leftChromeTrailing = maxOf(lock.x + lock.width, batteryTrailing ?: 0f)
    val laneLeading = leftChromeTrailing + 12f
    val laneTrailing = laneLeading + ASSIST_RAIL_EXPANDED_WIDTH_DP
    if (!expanded) {
        val railCenterX = laneLeading + ASSIST_RAIL_EXPANDED_WIDTH_DP / 2f
        return ZoneFrame(
            x = railCenterX - ASSIST_RAIL_COLLAPSED_PILL_DP / 2f,
            y = lock.y + (lock.height - ASSIST_RAIL_COLLAPSED_PILL_DP) / 2f,
            width = ASSIST_RAIL_COLLAPSED_PILL_DP,
            height = ASSIST_RAIL_COLLAPSED_PILL_DP,
        )
    }
    // "Fill until it hits the bottom bar": a trailing-aligned strip on a wide
    // body never reaches the rail's lane, so the rail runs to the band bottom.
    val stripEntersLane =
        measuredCaptureBar != null &&
            measuredCaptureBar.width > 1f &&
            measuredCaptureBar.x < laneTrailing + 16f
    val railBottom =
        if (stripEntersLane) assistBand.y - 10f else assistBand.y + assistBand.height
    return ZoneFrame(
        x = laneLeading,
        y = lock.y,
        width = ASSIST_RAIL_EXPANDED_WIDTH_DP,
        height = maxOf(0f, railBottom - lock.y),
    )
}

@StringRes
internal fun AssistTool.labelResource(): Int =
    when (this) {
        AssistTool.LUT -> R.string.assist_label_lut
        AssistTool.PEAK -> R.string.assist_label_peak
        AssistTool.FALSE -> R.string.assist_label_false_color
        AssistTool.ZEBRA -> R.string.assist_label_zebra
        AssistTool.WAVE -> R.string.assist_label_waveform
        AssistTool.PARADE -> R.string.assist_label_parade
        AssistTool.HISTO -> R.string.assist_label_histogram
        AssistTool.VECTOR -> R.string.assist_label_vectorscope
        AssistTool.LIGHTS -> R.string.assist_label_traffic_lights
        AssistTool.GUIDES -> R.string.assist_label_guides
        AssistTool.GRID -> R.string.assist_label_grid
        AssistTool.CROSS -> R.string.assist_label_crosshair
        AssistTool.LEVEL -> R.string.assist_label_level
        AssistTool.EV -> R.string.assist_label_ev_meter
        AssistTool.DESQ -> R.string.assist_label_desqueeze
        AssistTool.PLAY -> R.string.assist_label_play
        AssistTool.AUDIO -> R.string.assist_label_audio
    }

@StringRes
internal fun AssistTool.titleResource(): Int =
    when (this) {
        AssistTool.LUT -> R.string.assist_label_lut
        AssistTool.PEAK -> R.string.assist_title_focus_peaking
        AssistTool.FALSE -> R.string.assist_title_false_color
        AssistTool.ZEBRA -> R.string.assist_title_zebra
        AssistTool.WAVE -> R.string.assist_title_waveform
        AssistTool.PARADE -> R.string.assist_title_parade
        AssistTool.HISTO -> R.string.assist_title_histogram
        AssistTool.VECTOR -> R.string.assist_title_vectorscope
        AssistTool.LIGHTS -> R.string.assist_title_traffic_lights
        AssistTool.GUIDES -> R.string.assist_title_frame_guides
        AssistTool.GRID -> R.string.assist_title_composition_grid
        AssistTool.CROSS -> R.string.assist_title_centre_crosshair
        AssistTool.LEVEL -> R.string.assist_title_horizon
        AssistTool.EV -> R.string.assist_title_ev_meter
        AssistTool.DESQ -> R.string.assist_title_desqueeze
        AssistTool.PLAY -> R.string.assist_title_instant_playback
        AssistTool.AUDIO -> R.string.assist_title_audio_levels
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
    initialLut: FeedLutSelection =
        initialEffects.lut ?: FeedLutSelection.BuiltIn(FeedLut.LOG3G10_709),
    initialFalseColorScale: FeedFalseColorScale =
        initialEffects.falseColor ?: FeedFalseColorScale.STOPS,
    initialAudioMetersEnabled: Boolean = false,
    private val persistSelections: (FeedLutSelection, FeedFalseColorScale) -> Unit = { _, _ -> },
    private val persistScopeSelections: (Set<ScopeKind>, List<ScopeKind>) -> Unit = { _, _ -> },
    private val persistAudioMeters: (Boolean) -> Unit = {},
    private val mirrorFeedEffectsState: Boolean = true,
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
    var selectedLut: FeedLutSelection by mutableStateOf(initialLut)
        private set

    /** The false-colour scale that will be enabled next, retained while off. */
    var selectedFalseColorScale: FeedFalseColorScale by mutableStateOf(initialFalseColorScale)
        private set

    /** Whether the live monitor shows the camera-derived stereo meter panel. */
    var audioMetersEnabled: Boolean by mutableStateOf(initialAudioMetersEnabled)
        private set

    /**
     * Whether photography's instant playback (PLAY) is armed. Session-local —
     * arming also reseeds the capture baseline via the monitor's effect.
     */
    var instantReviewEnabled: Boolean by mutableStateOf(false)
        private set

    /**
     * Activates the process-local compatibility mirror after composition has
     * committed. Constructing this state often happens inside `remember`, so
     * writing another Compose state from the initializer can race an activity
     * configuration change's initial composition.
     */
    fun activateEffectsMirror() {
        if (mirrorFeedEffectsState) FeedEffectsState.current = effects
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
            AssistTool.AUDIO -> audioMetersEnabled
            AssistTool.PLAY -> instantReviewEnabled
            // Framing tools are persisted by OperatorSettings instead of this
            // feed-effects state. AssistToolbar routes them through its local
            // framing callback; keeping this fallback false prevents an
            // accidental settings caller from treating them as image effects.
            AssistTool.GUIDES,
            AssistTool.GRID,
            AssistTool.CROSS,
            AssistTool.LEVEL,
            AssistTool.EV,
            AssistTool.DESQ,
            -> false
        }

    /**
     * Toggles [tool]. LUT and false-colour activation remain independent, as
     * on iOS: STOPS/IRE takes visual precedence in the renderer, then turning
     * False off reveals the same active look. LIMITS paints over that look.
     * Scopes are independent: tapping another scope leaves an existing scope
     * visible and records the recency Android's portrait layout needs.
     */
    fun toggle(tool: AssistTool, maximumActiveScopes: Int? = null): Boolean {
        return when (tool) {
            AssistTool.LUT ->
                if (effects.lut == null) {
                    update(effects.copy(lut = selectedLut))
                    true
                } else {
                    update(effects.copy(lut = null))
                    true
                }
            AssistTool.FALSE ->
                if (effects.falseColor != null) {
                    update(effects.copy(falseColor = null))
                    true
                } else {
                    update(effects.copy(falseColor = selectedFalseColorScale))
                    true
                }
            AssistTool.PEAK -> {
                update(effects.copy(peaking = !effects.peaking))
                true
            }
            AssistTool.ZEBRA -> {
                update(effects.copy(zebra = !effects.zebra))
                true
            }
            AssistTool.WAVE -> toggleScope(ScopeKind.WAVEFORM, maximumActiveScopes)
            AssistTool.PARADE -> toggleScope(ScopeKind.PARADE, maximumActiveScopes)
            AssistTool.HISTO -> toggleScope(ScopeKind.HISTOGRAM, maximumActiveScopes)
            AssistTool.VECTOR -> toggleScope(ScopeKind.VECTORSCOPE, maximumActiveScopes)
            AssistTool.LIGHTS -> toggleScope(ScopeKind.TRAFFIC_LIGHTS, maximumActiveScopes)
            AssistTool.AUDIO -> {
                audioMetersEnabled = !audioMetersEnabled
                persistState()
                true
            }
            AssistTool.PLAY -> {
                instantReviewEnabled = !instantReviewEnabled
                true
            }
            // See isOn: monitor and settings framing controls are routed to
            // OperatorSettings so they cannot mutate camera or effect state.
            AssistTool.GUIDES,
            AssistTool.GRID,
            AssistTool.CROSS,
            AssistTool.LEVEL,
            AssistTool.EV,
            AssistTool.DESQ,
            -> false
        }
    }

    /** Selects the LUT used the next time (or currently while) LUT is enabled. */
    fun selectLut(lut: FeedLut) {
        selectLutSelection(FeedLutSelection.BuiltIn(lut))
    }

    /** Selects a validated app-private LUT; the caller must have resolved it through the library. */
    fun selectStoredLut(lut: StoredLutSelection) {
        selectLutSelection(FeedLutSelection.Stored(lut))
    }

    private fun selectLutSelection(lut: FeedLutSelection) {
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

    /**
     * Applies configuration owned by another assist context without copying
     * that context's visibility or persistence. Playback uses this to mirror
     * iOS's shared LUT/false-colour choices while retaining independent tool
     * toggles and without replacing the live renderer mirror.
     */
    internal fun applySharedSelections(
        lut: FeedLutSelection,
        falseColorScale: FeedFalseColorScale,
    ) {
        check(!mirrorFeedEffectsState) {
            "shared selections are only valid for a context-local assist state"
        }
        selectedLut = lut
        selectedFalseColorScale = falseColorScale
        effects =
            effects.copy(
                lut = lut.takeIf { effects.lut != null },
                falseColor = falseColorScale.takeIf { effects.falseColor != null },
            )
    }

    private fun toggleScope(kind: ScopeKind, maximumActiveScopes: Int?): Boolean {
        if (kind !in selectedScopes && maximumActiveScopes != null && selectedScopes.size >= maximumActiveScopes) {
            return false
        }
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
        return true
    }

    /** Restores the iOS False Color card's default scale without changing activation. */
    fun resetFalseColorSelection() {
        selectFalseColorScale(FeedFalseColorScale.STOPS)
    }

    private fun update(next: FeedEffects) {
        effects = next
        if (mirrorFeedEffectsState) FeedEffectsState.current = next
        persistState()
    }

    private fun persistState() {
        persist(effects, scope)
        persistScopeSelections(selectedScopes, scopeActivationOrder)
        persistSelections(selectedLut, selectedFalseColorScale)
        persistAudioMeters(audioMetersEnabled)
    }

    companion object {
        private const val PREFS = "assist"
        private const val SCOPES_KEY = "scopes"
        private const val SCOPE_ACTIVATION_ORDER_KEY = "scopeActivationOrder"
        private const val AUDIO_METERS_KEY = "audioMeters"
        private const val LUT_SELECTION_KIND_KEY = "lut.selection.kind.v1"
        private const val LUT_SELECTION_CATEGORY_KEY = "lut.selection.category.v1"
        private const val LUT_SELECTION_FILE_KEY = "lut.selection.file.v1"
        private const val LUT_SELECTION_BUILT_IN = "builtIn"
        private const val LUT_SELECTION_STORED = "stored"

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
         * launch intent specified a selection ([intentEffects] non-null or
         * [intentScopes] non-null), which then IS the session state. A non-null
         * identity effect record explicitly means every image effect is off;
         * null means restore preferences. [intentScope]
         * remains the source-compatible single-scope bridge for existing callers.
         */
        fun restore(
            context: Context,
            intentEffects: FeedEffects?,
            intentScope: ScopeKind?,
            intentScopes: List<ScopeKind>? = intentScope?.let(::listOf),
            availableStoredLut: (StoredLutSelection) -> Boolean = { true },
        ): AssistState {
            val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            return restore(prefs, intentEffects, intentScope, intentScopes, availableStoredLut)
        }

        /** Restores local assist state from [preferences]; exposed to JVM tests through `internal`. */
        internal fun restore(
            preferences: SharedPreferences,
            intentEffects: FeedEffects?,
            intentScope: ScopeKind?,
            intentScopes: List<ScopeKind>? = intentScope?.let(::listOf),
            availableStoredLut: (StoredLutSelection) -> Boolean = { true },
            mirrorFeedEffectsState: Boolean = true,
            persistConfigurationSelections: Boolean = true,
        ): AssistState {
            val fromIntent = intentEffects != null || intentScopes != null
            val legacyBuiltIn =
                preferences.getString("lut", null)
                    ?.let(FeedLut::fromId)
                    ?: FeedLut.LOG3G10_709
            val storedLut =
                persistedStoredLut(preferences)
                    ?.takeIf(availableStoredLut)
                    ?.let(FeedLutSelection::Stored)
                    ?: FeedLutSelection.BuiltIn(legacyBuiltIn)
            val storedFalseColorScale =
                preferences.getString("fcScale", null)
                    ?.let(FeedFalseColorScale::fromId)
                    ?: FeedFalseColorScale.STOPS
            val parsedEffects =
                if (fromIntent) {
                    intentEffects ?: FeedEffects.NONE
                } else {
                    FeedEffects.parse(
                        preferences.getString("tokens", null),
                        preferences.getString("lut", null),
                        preferences.getString("fcScale", null),
                    )
                }
            val effects =
                if (!fromIntent && parsedEffects.lut != null) {
                    parsedEffects.copy(lut = storedLut)
                } else {
                    parsedEffects
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
                initialAudioMetersEnabled = preferences.getBoolean(AUDIO_METERS_KEY, false),
                mirrorFeedEffectsState = mirrorFeedEffectsState,
                persistSelections = { lut, falseColorScale ->
                    if (persistConfigurationSelections) {
                        val editor = preferences.edit().putString("fcScale", falseColorScale.id)
                        when (lut) {
                            is FeedLutSelection.BuiltIn ->
                                editor
                                    .putString("lut", lut.value.id)
                                    .putString(LUT_SELECTION_KIND_KEY, LUT_SELECTION_BUILT_IN)
                                    .remove(LUT_SELECTION_CATEGORY_KEY)
                                    .remove(LUT_SELECTION_FILE_KEY)
                            is FeedLutSelection.Stored ->
                                // Keep a legacy built-in fallback for an older app build, but only this
                                // version reads the category/file pair. No external URI/path is stored.
                                editor
                                    .putString("lut", FeedLut.LOG3G10_709.id)
                                    .putString(LUT_SELECTION_KIND_KEY, LUT_SELECTION_STORED)
                                    .putString(LUT_SELECTION_CATEGORY_KEY, lut.value.category.name)
                                    .putString(LUT_SELECTION_FILE_KEY, lut.value.fileName)
                        }
                        editor.apply()
                    }
                },
                persistAudioMeters = { enabled ->
                    preferences.edit().putBoolean(AUDIO_METERS_KEY, enabled).apply()
                },
            )
        }

        private fun persistedStoredLut(preferences: SharedPreferences): StoredLutSelection? {
            if (preferences.getString(LUT_SELECTION_KIND_KEY, null) != LUT_SELECTION_STORED) return null
            return StoredLutSelection.fromPersisted(
                preferences.getString(LUT_SELECTION_CATEGORY_KEY, null),
                preferences.getString(LUT_SELECTION_FILE_KEY, null),
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
    imageEffectsAvailable: Boolean =
        liveFeedEffectsPlatformAvailable(Build.VERSION.SDK_INT, SwiftCore.isAvailable),
    framingConfiguration: LocalFramingAssistConfiguration? = null,
    onToggleFramingTool: (AssistTool) -> Unit = {},
    hapticsEnabled: Boolean = true,
    enabled: Boolean = true,
    maximumActiveScopes: Int? = null,
    onScopeLimitReached: () -> Unit = {},
    onLongPressTool: ((AssistTool) -> Unit)? = null,
    onLongPressToolAnchored: ((AssistTool, Rect) -> Unit)? = null,
) {
    val supportedTools =
        if (imageEffectsAvailable) {
            visibleTools
        } else {
            visibleTools.filterNot { it in imageEffectTools }
        }
    val scroll = rememberScrollState()
    val view = LocalView.current
    val leadingFade = scroll.canScrollBackward
    val trailingFade = scroll.canScrollForward
    // iOS anchors the options popup to the whole toolbar's frame (trailing
    // edge, band above), not to the pressed cell.
    var toolbarBounds by remember { mutableStateOf<Rect?>(null) }
    Box(
        modifier
            .onGloballyPositioned { toolbarBounds = it.boundsInRoot() }
            .glass(ChromeShape),
    ) {
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
            supportedTools.forEachIndexed { index, tool ->
                // Tools group in threes; AUDIO always rides its own trailing
                // section after a divider (iOS MonitorAssistStrip).
                if (index > 0 && (tool == AssistTool.AUDIO || index % 3 == 0)) {
                    Box(
                        Modifier.padding(horizontal = 4.dp)
                            .size(width = 1.dp, height = 28.dp)
                            .background(LiveDesign.hairlineStrong),
                    )
                }
                val isFramingTool = tool in AssistTool.framingTools
                val isOn =
                    if (isFramingTool) {
                        framingConfiguration?.isToolEnabled(tool) ?: false
                    } else {
                        state.isOn(tool)
                    }
                val capBlocked =
                    tool in AssistTool.scopeTools &&
                        !isOn &&
                        maximumActiveScopes != null &&
                        state.selectedScopes.size >= maximumActiveScopes
                // iOS renders a cap-blocked scope button at 0.35 opacity while
                // keeping it tappable so the refusal toast can explain.
                Box(Modifier.alpha(if (capBlocked) 0.35f else 1f)) {
                    AssistToolCell(
                        tool = tool,
                        isOn = isOn,
                        enabled = enabled,
                        onLongClick =
                            if (tool.hasConfiguration &&
                                (onLongPressTool != null || onLongPressToolAnchored != null)
                            ) {
                                { anchor ->
                                    if (capBlocked) {
                                        onScopeLimitReached()
                                    } else {
                                        view.performOperatorHaptic(
                                            HapticFeedbackConstants.LONG_PRESS,
                                            enabled = hapticsEnabled,
                                        )
                                        onLongPressToolAnchored?.invoke(
                                            tool,
                                            toolbarBounds ?: anchor,
                                        ) ?: onLongPressTool?.invoke(tool)
                                    }
                                }
                            } else {
                                null
                            },
                    ) {
                        var changed = true
                        if (isFramingTool) {
                            onToggleFramingTool(tool)
                        } else {
                            changed = state.toggle(tool, maximumActiveScopes)
                        }
                        if (!changed) {
                            onScopeLimitReached()
                            return@AssistToolCell
                        }
                        if (hapticsEnabled) {
                            view.performOperatorHaptic(HapticFeedbackConstants.KEYBOARD_TAP)
                        }
                    }
                }
            }
        }
        ScrollChevron(leading = true, visible = leadingFade, Modifier.align(Alignment.CenterStart))
        ScrollChevron(leading = false, visible = trailingFade, Modifier.align(Alignment.CenterEnd))
    }
}

/**
 * Collapsible vertical assist rail used only by portrait-fill monitor mode.
 *
 * The caller seats this component with [portraitFillAssistRailFrame], which
 * derives exclusively from the shared Swift feed and capture-strip zones.
 * Tool behavior is identical to [AssistToolbar]; expanding the rail changes
 * only local chrome and never camera state.
 */
@Composable
internal fun PortraitFillAssistRail(
    state: AssistState,
    expanded: Boolean,
    onExpandedChange: (Boolean) -> Unit,
    modifier: Modifier = Modifier,
    visibleTools: List<AssistTool> = AssistTool.entries.toList(),
    imageEffectsAvailable: Boolean =
        liveFeedEffectsPlatformAvailable(Build.VERSION.SDK_INT, SwiftCore.isAvailable),
    framingConfiguration: LocalFramingAssistConfiguration? = null,
    onToggleFramingTool: (AssistTool) -> Unit = {},
    hapticsEnabled: Boolean = true,
    enabled: Boolean = true,
    onLongPressTool: ((AssistTool) -> Unit)? = null,
    onLongPressToolAnchored: ((AssistTool, Rect) -> Unit)? = null,
) {
    val openDescription = stringResource(R.string.assist_open_rail_description)
    val closeDescription = stringResource(R.string.assist_close_rail_description)
    val railDescription = stringResource(R.string.assist_rail_description)
    val collapsedDescription = stringResource(R.string.state_collapsed)
    val expandedDescription = stringResource(R.string.state_expanded)
    if (!expanded) {
        Box(
            modifier
                .glass(ChromeShape)
                .chromeClickable(enabled) { onExpandedChange(true) }
                .semantics {
                    contentDescription = openDescription
                    stateDescription = collapsedDescription
                },
            contentAlignment = Alignment.Center,
        ) {
            // iOS collapsed rail shows the slider.horizontal.3 glyph, not text.
            SliderHorizontal3Glyph(LiveDesign.accent, Modifier.size(18.dp))
        }
        return
    }

    val supportedTools =
        if (imageEffectsAvailable) {
            visibleTools
        } else {
            visibleTools.filterNot { it in imageEffectTools }
        }
    val scroll = rememberScrollState()
    Box(
        modifier
            // Rows must never draw outside the rail's rounded silhouette —
            // the scroll column clips to rectangular bounds otherwise (iOS
            // clipShape on the expanded rail).
            .clip(ChromeShape)
            .glass(ChromeShape)
            .semantics {
                contentDescription = railDescription
                stateDescription = expandedDescription
            },
    ) {
        Column(
            Modifier
                .fillMaxSize()
                .verticalScroll(scroll)
                .padding(horizontal = 4.dp)
                // The last row must be able to scroll fully clear of the
                // bottom fade — without this it parks half-faded against the
                // rail's rounded end (iOS bottomFadeHeight + 10 padding).
                .padding(top = 6.dp, bottom = ASSIST_RAIL_BOTTOM_FADE_DP.dp + 10.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Box(
                Modifier
                    .fillMaxWidth()
                    .height(38.dp)
                    .chromeClickable(enabled) { onExpandedChange(false) }
                    .semantics { contentDescription = closeDescription },
                contentAlignment = Alignment.Center,
            ) {
                // iOS collapse handle is a chevron, not a text label.
                ChevronCollapseGlyph(LiveDesign.accent, Modifier.size(13.dp))
            }
            AssistRailToolCells(
                supportedTools = supportedTools,
                state = state,
                framingConfiguration = framingConfiguration,
                onToggleFramingTool = onToggleFramingTool,
                hapticsEnabled = hapticsEnabled,
                enabled = enabled,
                onLongPressTool = onLongPressTool,
                onLongPressToolAnchored = onLongPressToolAnchored,
            )
        }
        // Rows scroll UNDER a bottom gradient so the last tool never
        // hard-clips mid-glyph against the rail's rounded edge — the fade
        // itself is the scroll affordance, reaching near-opaque well before
        // the rail's end (iOS bottom fade).
        Box(
            Modifier
                .align(Alignment.BottomCenter)
                .fillMaxWidth()
                .height(ASSIST_RAIL_BOTTOM_FADE_DP.dp)
                .background(
                    Brush.verticalGradient(
                        0f to LiveDesign.background.copy(alpha = 0f),
                        0.55f to LiveDesign.background.copy(alpha = 0.85f),
                        1f to LiveDesign.background.copy(alpha = 0.98f),
                    ),
                ),
        )
    }
}

/** The vertical rail's tool cells, shared by the expanded-rail scroll column. */
@Composable
private fun AssistRailToolCells(
    supportedTools: List<AssistTool>,
    state: AssistState,
    framingConfiguration: LocalFramingAssistConfiguration?,
    onToggleFramingTool: (AssistTool) -> Unit,
    hapticsEnabled: Boolean,
    enabled: Boolean,
    onLongPressTool: ((AssistTool) -> Unit)?,
    onLongPressToolAnchored: ((AssistTool, Rect) -> Unit)?,
) {
    val view = LocalView.current
    supportedTools.forEach { tool ->
            val isFramingTool = tool in AssistTool.framingTools
            val isOn =
                if (isFramingTool) {
                    framingConfiguration?.isToolEnabled(tool) ?: false
                } else {
                    state.isOn(tool)
                }
            AssistToolCell(
                tool = tool,
                isOn = isOn,
                enabled = enabled,
                onLongClick =
                    if (tool.hasConfiguration &&
                        (onLongPressTool != null || onLongPressToolAnchored != null)
                    ) {
                        { anchor ->
                            if (hapticsEnabled) {
                                view.performOperatorHaptic(HapticFeedbackConstants.LONG_PRESS)
                            }
                            onLongPressToolAnchored?.invoke(tool, anchor)
                                ?: onLongPressTool?.invoke(tool)
                        }
                    } else {
                        null
                    },
            ) {
                if (isFramingTool) {
                    onToggleFramingTool(tool)
                } else {
                    state.toggle(tool)
                }
                if (hapticsEnabled) {
                    view.performOperatorHaptic(HapticFeedbackConstants.KEYBOARD_TAP)
                }
            }
    }
}

/** Feed effects need the API 29 floor plus the staged Swift renderer policy. */
private val imageEffectTools: Set<AssistTool> =
    setOf(AssistTool.LUT, AssistTool.PEAK, AssistTool.FALSE, AssistTool.ZEBRA)

/** Maps local framing configuration to the four toolbar toggles without a camera-control seam. */
private fun LocalFramingAssistConfiguration.isToolEnabled(tool: AssistTool): Boolean =
    when (tool) {
        AssistTool.GUIDES -> drawsGuides
        AssistTool.GRID -> drawsGrid
        AssistTool.CROSS -> centerCrosshairEnabled
        AssistTool.LEVEL -> levelEnabled
        AssistTool.EV -> evMeterEnabled
        AssistTool.DESQ -> desqueezeEnabled
        else -> false
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
private fun AssistToolCell(
    tool: AssistTool,
    isOn: Boolean,
    enabled: Boolean,
    onLongClick: ((Rect) -> Unit)?,
    onClick: () -> Unit,
) {
    val tint = if (isOn) LiveDesign.accent else LiveDesign.muted
    val title = stringResource(tool.titleResource())
    val label = stringResource(tool.labelResource())
    val onState = stringResource(R.string.state_on)
    val offState = stringResource(R.string.state_off)
    var bounds by remember(tool) { mutableStateOf(Rect.Zero) }
    Column(
        modifier =
            Modifier
                .background(if (isOn) LiveDesign.accentDim else Color.Transparent, ChromeShape)
                .onGloballyPositioned { bounds = it.boundsInRoot() }
                .assistToolClickable(
                    enabled = enabled,
                    title = title,
                    onLongClick = onLongClick?.let { callback -> { callback(bounds) } },
                    onClick = onClick,
                )
                .semantics {
                    contentDescription = title
                    stateDescription = if (isOn) onState else offState
                }
                .padding(vertical = 5.dp, horizontal = 8.dp)
                .widthIn(min = 36.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Box(Modifier.height(23.dp), contentAlignment = Alignment.Center) {
            AssistToolGlyph(tool, tint, Modifier.size(19.dp))
        }
        Text(
            label,
            style = chromeStyle(9f, FontWeight.Medium, mono = true),
            color = tint,
            maxLines = 1,
        )
    }
}

/** Keeps live-view tap behavior unchanged while adding explicit TalkBack long-click semantics. */
@Composable
private fun Modifier.assistToolClickable(
    enabled: Boolean,
    title: String,
    onLongClick: (() -> Unit)?,
    onClick: () -> Unit,
): Modifier {
    val toggleDescription = stringResource(R.string.assist_toggle_description, title)
    val configureDescription = stringResource(R.string.assist_configure_description, title)
    return if (onLongClick == null) {
        chromeClickable(enabled, onClick)
    } else {
        combinedClickable(
            enabled = enabled,
            interactionSource = remember { MutableInteractionSource() },
            indication = null,
            onClickLabel = toggleDescription,
            onLongClickLabel = configureDescription,
            onLongClick = onLongClick,
            onClick = onClick,
        )
    }
}

/** Canvas stand-ins for the iOS SF Symbol per tool (`MonitorAssistTool.icon`). */
@Composable
internal fun AssistToolGlyph(tool: AssistTool, tint: Color, modifier: Modifier = Modifier) {
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
            // SF `rectangle.dashed`: delivery frame guides.
            AssistTool.GUIDES -> {
                val inset = size.minDimension * 0.16f
                val dash = size.minDimension * 0.16f
                val top = inset
                val bottom = size.height - inset
                val left = inset * 0.58f
                val right = size.width - left
                drawLine(tint, Offset(left, top), Offset(left + dash, top), 1.5.dp.toPx())
                drawLine(tint, Offset(right - dash, top), Offset(right, top), 1.5.dp.toPx())
                drawLine(tint, Offset(left, bottom), Offset(left + dash, bottom), 1.5.dp.toPx())
                drawLine(tint, Offset(right - dash, bottom), Offset(right, bottom), 1.5.dp.toPx())
                drawLine(tint, Offset(left, top), Offset(left, top + dash), 1.5.dp.toPx())
                drawLine(tint, Offset(right, top), Offset(right, top + dash), 1.5.dp.toPx())
                drawLine(tint, Offset(left, bottom - dash), Offset(left, bottom), 1.5.dp.toPx())
                drawLine(tint, Offset(right, bottom - dash), Offset(right, bottom), 1.5.dp.toPx())
            }
            // SF `grid`: thirds and phi composition lines.
            AssistTool.GRID -> {
                val fractions = listOf(1f / 3f, 2f / 3f)
                fractions.forEach { fraction ->
                    val x = size.width * fraction
                    val y = size.height * fraction
                    drawLine(tint, Offset(x, 1.dp.toPx()), Offset(x, size.height - 1.dp.toPx()), 1.3.dp.toPx())
                    drawLine(tint, Offset(1.dp.toPx(), y), Offset(size.width - 1.dp.toPx(), y), 1.3.dp.toPx())
                }
            }
            // SF `plus`: centre crosshair.
            AssistTool.CROSS -> {
                val centre = Offset(size.width / 2, size.height / 2)
                val arm = size.minDimension * 0.42f
                drawLine(tint, Offset(centre.x - arm, centre.y), Offset(centre.x + arm, centre.y), 1.7.dp.toPx())
                drawLine(tint, Offset(centre.x, centre.y - arm), Offset(centre.x, centre.y + arm), 1.7.dp.toPx())
            }
            // SF `gyroscope`: horizon ring, level line, and centre marker.
            AssistTool.LEVEL -> {
                val centre = Offset(size.width / 2, size.height / 2)
                val radius = size.minDimension * 0.42f
                drawCircle(tint, radius, centre, style = stroke)
                drawLine(
                    tint,
                    Offset(centre.x - radius * 0.72f, centre.y),
                    Offset(centre.x + radius * 0.72f, centre.y),
                    1.7.dp.toPx(),
                    StrokeCap.Round,
                )
                drawCircle(tint, size.minDimension * 0.08f, centre)
            }
            // SF `plusminus`: the camera's exposure indicator (± EV).
            AssistTool.EV -> {
                val strokeWidth = 1.7.dp.toPx()
                val plusCentre = Offset(size.width * 0.5f, size.height * 0.30f)
                val plusHalf = size.minDimension * 0.20f
                drawLine(
                    tint,
                    Offset(plusCentre.x - plusHalf, plusCentre.y),
                    Offset(plusCentre.x + plusHalf, plusCentre.y),
                    strokeWidth,
                    StrokeCap.Round,
                )
                drawLine(
                    tint,
                    Offset(plusCentre.x, plusCentre.y - plusHalf),
                    Offset(plusCentre.x, plusCentre.y + plusHalf),
                    strokeWidth,
                    StrokeCap.Round,
                )
                val minusY = size.height * 0.78f
                drawLine(
                    tint,
                    Offset(size.width * 0.5f - plusHalf, minusY),
                    Offset(size.width * 0.5f + plusHalf, minusY),
                    strokeWidth,
                    StrokeCap.Round,
                )
            }
            // SF `arrow.left.and.right`: local anamorphic de-squeeze.
            AssistTool.DESQ -> {
                val y = size.height / 2
                val inset = size.width * 0.12f
                val head = size.minDimension * 0.20f
                drawLine(tint, Offset(inset, y), Offset(size.width - inset, y), 1.7.dp.toPx(), StrokeCap.Round)
                drawLine(tint, Offset(inset, y), Offset(inset + head, y - head), 1.7.dp.toPx(), StrokeCap.Round)
                drawLine(tint, Offset(inset, y), Offset(inset + head, y + head), 1.7.dp.toPx(), StrokeCap.Round)
                drawLine(tint, Offset(size.width - inset, y), Offset(size.width - inset - head, y - head), 1.7.dp.toPx(), StrokeCap.Round)
                drawLine(tint, Offset(size.width - inset, y), Offset(size.width - inset - head, y + head), 1.7.dp.toPx(), StrokeCap.Round)
            }
            // SF `photo.badge.checkmark`: photo frame with a check tick.
            AssistTool.PLAY -> {
                val stroke2 = Stroke(1.6.dp.toPx(), cap = StrokeCap.Round, join = StrokeJoin.Round)
                drawRoundRect(
                    tint,
                    topLeft = Offset(size.width * 0.06f, size.height * 0.14f),
                    size = androidx.compose.ui.geometry.Size(
                        size.width * 0.70f,
                        size.height * 0.62f,
                    ),
                    cornerRadius = androidx.compose.ui.geometry.CornerRadius(size.height * 0.12f),
                    style = stroke2,
                )
                val check = Path().apply {
                    moveTo(size.width * 0.62f, size.height * 0.78f)
                    lineTo(size.width * 0.74f, size.height * 0.90f)
                    lineTo(size.width * 0.96f, size.height * 0.62f)
                }
                drawPath(check, tint, style = stroke2)
            }
            // SF `slider.vertical.3`: three compact audio level bars.
            AssistTool.AUDIO -> {
                val columns = listOf(0.25f, 0.5f, 0.75f)
                val levels = listOf(0.48f, 0.84f, 0.62f)
                val top = size.height * 0.14f
                val bottom = size.height * 0.86f
                columns.zip(levels).forEach { (fraction, level) ->
                    val x = size.width * fraction
                    drawLine(tint.copy(alpha = 0.36f), Offset(x, top), Offset(x, bottom), 1.4.dp.toPx())
                    drawLine(
                        tint,
                        Offset(x, bottom - (bottom - top) * level),
                        Offset(x, bottom),
                        2.2.dp.toPx(),
                        cap = StrokeCap.Round,
                    )
                }
            }
        }
    }
}

/** Canvas stand-in for SF `slider.horizontal.3` (the fill-rail collapsed pill). */
@Composable
internal fun SliderHorizontal3Glyph(tint: Color, modifier: Modifier = Modifier) {
    Canvas(modifier) {
        val stroke = size.minDimension * 0.085f
        val knobRadius = size.minDimension * 0.09f
        val rows = listOf(0.24f, 0.5f, 0.76f)
        val knobs = listOf(0.68f, 0.34f, 0.58f)
        rows.forEachIndexed { index, rowY ->
            val y = size.height * rowY
            drawLine(
                tint,
                Offset(size.width * 0.06f, y),
                Offset(size.width * 0.94f, y),
                strokeWidth = stroke,
                cap = StrokeCap.Round,
            )
            drawCircle(tint, radius = knobRadius, center = Offset(size.width * knobs[index], y))
        }
    }
}

/** Canvas stand-in for SF `chevron.left` (the fill-rail collapse handle). */
@Composable
internal fun ChevronCollapseGlyph(tint: Color, modifier: Modifier = Modifier) {
    Canvas(modifier) {
        val path = Path().apply {
            moveTo(size.width * 0.62f, size.height * 0.22f)
            lineTo(size.width * 0.38f, size.height * 0.5f)
            lineTo(size.width * 0.62f, size.height * 0.78f)
        }
        drawPath(
            path,
            tint,
            style = Stroke(width = size.minDimension * 0.12f, cap = StrokeCap.Round),
        )
    }
}

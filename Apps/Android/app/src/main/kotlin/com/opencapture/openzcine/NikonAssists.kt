package com.opencapture.openzcine

import com.opencapture.opencine.appkit.MonitorReviewOptions
import com.opencapture.opencine.appkit.MonitorReviewDuration
import android.content.Context
import android.content.SharedPreferences
import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.opencapture.monitorui.MonitorAssistTool
import com.opencapture.monitorui.MonitorFalseColorSelection
import com.opencapture.monitorui.MonitorGuideAspect
import com.opencapture.monitorui.MonitorGuideFamily
import com.opencapture.monitorui.MonitorParadeMode
import com.opencapture.monitorui.MonitorScopeGuides
import com.opencapture.monitorui.MonitorVectorscopeZoom
import com.opencapture.monitorui.MonitorWaveformMode
import com.opencapture.monitorui.MonitorZebraUnit
import com.opencapture.opencine.appkit.MonitorAssistState
import com.opencapture.opencine.media.MonitorCrushClipCompensation
import com.opencapture.opencine.media.MonitorDesqueezeDirection
import com.opencapture.opencine.media.MonitorDesqueezePreset
import com.opencapture.opencine.media.MonitorPeakingColor
import com.opencapture.opencine.media.MonitorPeakingSense
import com.opencapture.opencine.media.MonitorZebraPaint
import com.opencapture.openzcine.lut.StoredLutSelection
import com.opencapture.openzcine.settings.LocalFramingAssistConfiguration
import com.opencapture.openzcine.settings.LocalLevelStyle
import com.opencapture.opencine.appkit.MonitorDisplayMode

/**
 * The shared [MonitorAssistState] plus this camera's typed assist extensions: the monitor look LUT
 * applies (built-in, R3D NE and stored RED or custom cubes) and photography's instant review (PLAY).
 */
@Stable
class NikonAssists internal constructor(
    val shared: MonitorAssistState,
    initialLut: FeedLutSelection,
    private val persistLut: (FeedLutSelection) -> Unit,
) {
    /** The look LUT applies, kept while LUT is off. */
    var lut: FeedLutSelection by mutableStateOf(initialLut)
        private set

    /** PLAY: each new still shows full screen. Session-local, and photography only. */
    var instantReview: Boolean by mutableStateOf(false)

    /** Persisted review choices; PLAY visibility remains scoped to this monitor. */
    var reviewOptions: MonitorReviewOptions by mutableStateOf(MonitorReviewOptions())
        private set
    private var persistReview: (MonitorReviewOptions) -> Unit = {}

    internal fun restoreReviewOptions(options: MonitorReviewOptions, persist: (MonitorReviewOptions) -> Unit) {
        reviewOptions = options
        persistReview = persist
    }

    fun updateReviewOptions(options: MonitorReviewOptions) {
        reviewOptions = options
        persistReview(options)
    }

    /** Picking a look arms LUT, as the shared picker does. */
    fun selectLut(selection: FeedLutSelection) {
        lut = selection
        persistLut(selection)
        shared.armLut()
    }
}

/** Photo toolset (iOS `appliesToPhotography`): exposure aids and the composition aids stills use. */
internal val MonitorAssistTool.appliesToPhotography: Boolean
    get() = this in photographyTools

private val photographyTools =
    setOf(
        MonitorAssistTool.PEAK, MonitorAssistTool.FALSE, MonitorAssistTool.ZEBRA,
        MonitorAssistTool.HISTO, MonitorAssistTool.GRID, MonitorAssistTool.LEVEL,
        MonitorAssistTool.EV, MonitorAssistTool.DESQ, MonitorAssistTool.MIRROR,
    )

/** The camera-fed EV needle is the body's stills exposure indicator, so cinema never offers it. */
internal val MonitorAssistTool.isPhotographyOnly: Boolean
    get() = this == MonitorAssistTool.EV

/** Image effects need the API 29 floor and the Swift renderer core. */
internal val MonitorAssistTool.isImageEffect: Boolean
    get() = this in MonitorAssistState.lookOverlayTools

internal val MonitorAssistTool.scopeKind: ScopeKind?
    get() =
        when (this) {
            MonitorAssistTool.WAVE -> ScopeKind.WAVEFORM
            MonitorAssistTool.PARADE -> ScopeKind.PARADE
            MonitorAssistTool.HISTO -> ScopeKind.HISTOGRAM
            MonitorAssistTool.VECTOR -> ScopeKind.VECTORSCOPE
            MonitorAssistTool.LIGHTS -> ScopeKind.TRAFFIC_LIGHTS
            else -> null
        }

internal val ScopeKind.assistTool: MonitorAssistTool
    get() = MonitorAssistTool.entries.first { it.scopeKind == this }

/**
 * Whether [tool] renders on the live monitor: on, then filtered by DISP (clean shows pins, command
 * has no picture) and by the photo toolset. Stored state never changes, so flipping back restores it.
 */
internal fun MonitorAssistState.rendersLive(
    tool: MonitorAssistTool,
    mode: MonitorDisplayMode,
    photography: Boolean,
): Boolean {
    if (!isOn(tool) || (photography && !tool.appliesToPhotography)) return false
    return when (mode) {
        MonitorDisplayMode.LIVE -> true
        MonitorDisplayMode.CLEAN -> tool in pinned
        MonitorDisplayMode.COMMAND -> false
    }
}

/** The scopes [visible] lets through, in canonical order. */
internal fun scopesShown(visible: (MonitorAssistTool) -> Boolean): Set<ScopeKind> =
    ScopeKind.canonical.filter { visible(it.assistTool) }.toSet()

/** What the GPU chain bakes for one visibility predicate (live or playback). */
internal fun NikonAssists.feedEffects(visible: (MonitorAssistTool) -> Boolean): FeedEffects =
    FeedEffects(
        lut = lut.takeIf { visible(MonitorAssistTool.LUT) },
        falseColor = shared.falseColorScale.feedScale.takeIf { visible(MonitorAssistTool.FALSE) },
        falseColorRec709 = shared.falseColorRec709,
        peaking = visible(MonitorAssistTool.PEAK),
        zebra = visible(MonitorAssistTool.ZEBRA),
        splitComparison =
            if (!shared.splitComparison) null
            else if (shared.splitVertical) FeedSplitOrientation.VERTICAL
            else FeedSplitOrientation.HORIZONTAL,
    )

/** Canonical shared scale order; the native renderer supplies camera calibration. */
internal val nikonFalseColorScales = MonitorFalseColorSelection.entries

internal val MonitorFalseColorSelection.feedScale: FeedFalseColorScale
    get() =
        when (this) {
            MonitorFalseColorSelection.IRE -> FeedFalseColorScale.IRE
            MonitorFalseColorSelection.LIMITS -> FeedFalseColorScale.LIMITS
            MonitorFalseColorSelection.SCENE_STOPS -> FeedFalseColorScale.STOPS
            MonitorFalseColorSelection.STOPS -> FeedFalseColorScale.VIDEO
        }

/** The renderer's image-assist options, read from the shared state. */
internal val MonitorAssistState.feedEffectsConfiguration: FeedEffectsConfiguration
    get() =
        FeedEffectsConfiguration(
            falseColorReferenceEnabled = falseColorReference,
            peakingSensitivity = peakingSensitivity,
            peakingColor = peakingColor,
            zebraUnit = zebraUnit,
            zebraHighlightEnabled = zebraHighlight,
            zebraHighlightIre = zebraHighlightIRE.toFloat(),
            zebraHighlightColor = zebraHighlightColor,
            zebraMidtoneEnabled = zebraMidtone,
            zebraMidtoneIre = zebraMidtoneIRE.toFloat(),
            zebraMidtoneColor = zebraMidtoneColor,
        ).normalized()

/** The framing overlays for one visibility predicate; the level style is this camera's own. */
internal fun MonitorAssistState.framing(
    visible: (MonitorAssistTool) -> Boolean,
    levelStyle: LocalLevelStyle,
): LocalFramingAssistConfiguration =
    LocalFramingAssistConfiguration(
        guidesVisible = visible(MonitorAssistTool.GUIDES),
        selectedGuideRatios = selectedGuides,
        guideMaskEnabled = guideMask,
        gridVisible = visible(MonitorAssistTool.GRID),
        ruleOfThirdsEnabled = gridThirds,
        phiGridEnabled = gridPhi,
        diagonalGridEnabled = gridDiagonal,
        centerCrosshairEnabled = visible(MonitorAssistTool.CROSS),
        levelEnabled = visible(MonitorAssistTool.LEVEL),
        levelStyle = levelStyle,
        evMeterEnabled = visible(MonitorAssistTool.EV),
        desqueezeEnabled = visible(MonitorAssistTool.DESQ),
        mirrorEnabled = visible(MonitorAssistTool.MIRROR),
        mirrorHorizontal = mirrorHorizontal,
        mirrorVertical = mirrorVertical,
        desqueezeFactor = desqueezeFactor.toFloat(),
        desqueezeDirection = desqueezeDirection,
    )

private const val ASSIST_PREFERENCES = "assist"
private const val OPERATOR_PREFERENCES = "openzcine.operator-settings"
private const val PLAYBACK_PREFERENCES = "playbackAssists"
private const val STATE_KEY = "monitorAssist.v1"
private const val PINS_KEY = "monitorAssist.cleanPins.v1"
private const val PLAYBACK_KEY = "monitorAssist.playback.v1"
private const val LUT_KEY = "lut"
private const val LUT_KIND_KEY = "lut.selection.kind.v1"
private const val LUT_CATEGORY_KEY = "lut.selection.category.v1"
private const val LUT_FILE_KEY = "lut.selection.file.v1"
private const val LUT_STORED = "stored"

/**
 * Restores the operator's assists. A debug selection seeds the session without saving. Scope
 * centres an older build saved in the Nikon placement store move into the shared state once.
 */
internal fun restoreNikonAssists(
    context: Context,
    debugEffects: FeedEffects? = null,
    debugScopes: List<ScopeKind>? = null,
    availableStoredLut: (StoredLutSelection) -> Boolean = { true },
): NikonAssists =
    restoreNikonAssists(
        context.getSharedPreferences(ASSIST_PREFERENCES, Context.MODE_PRIVATE),
        context.getSharedPreferences(OPERATOR_PREFERENCES, Context.MODE_PRIVATE),
        context.getSharedPreferences(PLAYBACK_PREFERENCES, Context.MODE_PRIVATE),
        debugEffects, debugScopes, availableStoredLut,
    ).also {
        MonitorAnalysisPanelPlacementStore(context).movePanelCentres(into = it.shared)
        StoredPanelCenter(context, LIVE_AUDIO_METER_PLACEMENT, "audio").moveAudioCentre(into = it.shared)
    }

/** The live audio meter's own placement file before it joined the shared assist state. */
private const val LIVE_AUDIO_METER_PLACEMENT = "audioMeterPlacement"

/** [restoreNikonAssists] over explicit stores, for JVM tests. */
internal fun restoreNikonAssists(
    assist: SharedPreferences,
    operator: SharedPreferences,
    playback: SharedPreferences,
    debugEffects: FeedEffects? = null,
    debugScopes: List<ScopeKind>? = null,
    availableStoredLut: (StoredLutSelection) -> Boolean = { true },
): NikonAssists {
    val legacy = if (assist.contains(STATE_KEY)) null else LegacyNikonAssists(assist, operator, playback)
    val shared =
        MonitorAssistState(
            encoded = assist.getString(STATE_KEY, null),
            pinnedNames =
                assist.getStringSet(PINS_KEY, null)
                    ?: legacy?.pins
                    ?: MonitorAssistState.defaultPinned.map { it.name }.toSet(),
            onPersist = { assist.edit().putString(STATE_KEY, it).apply() },
            onPersistPins = { assist.edit().putStringSet(PINS_KEY, it).apply() },
            playbackNames = assist.getStringSet(PLAYBACK_KEY, null) ?: legacy?.playbackTools.orEmpty(),
            onPersistPlayback = { assist.edit().putStringSet(PLAYBACK_KEY, it).apply() },
        )
    if (legacy != null) {
        legacy.copyInto(shared)
        assist.edit()
            .putStringSet(PINS_KEY, shared.pinned.map { it.name }.toSet())
            .putStringSet(PLAYBACK_KEY, shared.playbackVisibleTools.map { it.name }.toSet())
            .apply()
        operator.edit().apply { droppedToolbarKeys.forEach(::remove) }.apply()
    }
    val storedLut =
        storedLut(assist)?.takeIf(availableStoredLut)?.let(FeedLutSelection::Stored)
            ?: FeedLutSelection.BuiltIn((assist.all[LUT_KEY] as? String)?.let(FeedLut::fromId) ?: FeedLut.LOG3G10_709)
    if (debugEffects != null || debugScopes != null) {
        val effects = debugEffects ?: FeedEffects.NONE
        val kept =
            MonitorAssistTool.entries.filter { shared.isOn(it) && !it.isImageEffect && it.scopeKind == null }
        shared.syncVisible(
            (kept + listOfNotNull(
                MonitorAssistTool.LUT.takeIf { effects.lut != null },
                MonitorAssistTool.FALSE.takeIf { effects.falseColor != null },
                MonitorAssistTool.PEAK.takeIf { effects.peaking },
                MonitorAssistTool.ZEBRA.takeIf { effects.zebra },
            ) + debugScopes.orEmpty().map { it.assistTool }).toSet(),
        )
        effects.falseColor?.let { shared.falseColorScale = it.sharedScale }
    }
    return NikonAssists(shared, debugEffects?.lut ?: storedLut) { lut ->
        val editor = assist.edit()
        when (lut) {
            is FeedLutSelection.BuiltIn ->
                editor.putString(LUT_KEY, lut.value.id).remove(LUT_KIND_KEY)
                    .remove(LUT_CATEGORY_KEY).remove(LUT_FILE_KEY)
            // Only the generated category/file pair is stored, never an external URI or path.
            is FeedLutSelection.Stored ->
                editor.putString(LUT_KIND_KEY, LUT_STORED)
                    .putString(LUT_CATEGORY_KEY, lut.value.category.name)
                    .putString(LUT_FILE_KEY, lut.value.fileName)
        }
        editor.apply()
    }.also { state ->
        state.restoreReviewOptions(MonitorReviewOptions(
            duration = MonitorReviewDuration.fromSeconds(
                assist.getInt(REVIEW_SECONDS_KEY, 5)),
            showsFocusPoint = assist.getBoolean(REVIEW_FOCUS_KEY, true),
            showsCaptureInfo = assist.getBoolean(REVIEW_INFO_KEY, true),
        )) { options ->
            assist.edit().putInt(REVIEW_SECONDS_KEY, options.duration.seconds)
                .putBoolean(REVIEW_FOCUS_KEY, options.showsFocusPoint)
                .putBoolean(REVIEW_INFO_KEY, options.showsCaptureInfo).apply()
        }
    }
}

/** The instant review's persisted options (iOS `assistConfiguration.instantReview*`). */
private const val REVIEW_SECONDS_KEY = "instantReview.seconds.v1"
private const val REVIEW_FOCUS_KEY = "instantReview.focusPoint.v1"
private const val REVIEW_INFO_KEY = "instantReview.captureInfo.v1"

private fun storedLut(assist: SharedPreferences): StoredLutSelection? =
    if (assist.all[LUT_KIND_KEY] != LUT_STORED) null
    else StoredLutSelection.fromPersisted(assist.all[LUT_CATEGORY_KEY] as? String, assist.all[LUT_FILE_KEY] as? String)

internal val FeedFalseColorScale.sharedScale: MonitorFalseColorSelection
    get() =
        when (this) {
            FeedFalseColorScale.STOPS -> MonitorFalseColorSelection.SCENE_STOPS
            FeedFalseColorScale.VIDEO -> MonitorFalseColorSelection.STOPS
            FeedFalseColorScale.IRE -> MonitorFalseColorSelection.IRE
            FeedFalseColorScale.LIMITS -> MonitorFalseColorSelection.LIMITS
        }

/** The toolbar order and per-tool bar visibility gave way to the shared usage ranking. */
private val droppedToolbarKeys =
    listOf("display.assistToolbar.order.v1", "display.assistToolbar.visible.v1") +
        listOf("trafficLights", "audioMeters", "framing", "level", "evMeter")
            .map { "display.assistToolbar.$it.visibility.migrated.v1" }

/**
 * The keys Nikon stored before it adopted the shared state, copied once. Only stored values move;
 * an absent key leaves the shared default, so a fresh install starts from the shared defaults.
 */
private class LegacyNikonAssists(
    assistStore: SharedPreferences,
    operatorStore: SharedPreferences,
    playbackStore: SharedPreferences,
) {
    // Typed reads through the raw maps: a wrong-typed or malformed old value falls back, never throws.
    private val assist: Map<String, *> = assistStore.all
    private val operator: Map<String, *> = operatorStore.all
    private val playback: Map<String, *> = playbackStore.all

    private fun on(key: String, default: Boolean = false) = operator[key] as? Boolean ?: default
    private fun text(key: String) = operator[key] as? String
    private fun float(key: String) = (operator[key] as? Float)?.takeIf(Float::isFinite)
    private inline fun <reified E : Enum<E>> enum(key: String): E? = enumValues<E>().firstOrNull { it.name == text(key) }

    val pins: Set<String>? = (operator["display.assistToolbar.cleanViewPinned.v1"] as? Set<*>)?.filterIsInstance<String>()?.toSet()

    val playbackTools: Set<String> =
        (effectTools(playback) + scopeTools(playback) +
            listOfNotNull(MonitorAssistTool.AUDIO.takeIf { playback["audioMeters"] == true }))
            .map { it.name }.toSet() +
            (playback["framingTools.v1"] as? Set<*>).orEmpty().filterIsInstance<String>()
                .mapNotNull(MonitorAssistTool::fromPersisted).map { it.name }

    private fun effectTools(store: Map<String, *>): List<MonitorAssistTool> {
        val tokens = (store["tokens"] as? String).orEmpty().split(',').map { it.trim().lowercase() }
        return listOfNotNull(
            MonitorAssistTool.LUT.takeIf { "lut" in tokens },
            MonitorAssistTool.FALSE.takeIf { "falsecolor" in tokens },
            MonitorAssistTool.PEAK.takeIf { "peaking" in tokens },
            MonitorAssistTool.ZEBRA.takeIf { "zebra" in tokens },
        )
    }

    private fun scopeTools(store: Map<String, *>): List<MonitorAssistTool> =
        (ScopeKind.parseTokens(store["scopes"] as? String)
            ?: ScopeKind.fromToken(store["scope"] as? String)?.let(::listOf).orEmpty())
            .map { it.assistTool }

    private val legacyGuide: MonitorGuideAspect? =
        when (text("assist.local.framingGuide.v1")) {
            "CINEMA_239" -> MonitorGuideAspect.CINEMA
            "WIDESCREEN_16_9" -> MonitorGuideAspect.HD
            else -> null
        }

    private fun ratio(key: String): Double? = text(key)?.removePrefix("X")?.toIntOrNull()?.let { it / 100.0 }

    private val legacyDesqueeze: Double? = ratio("assist.local.desqueezePresentation.v1")

    fun copyInto(state: MonitorAssistState) {
        val framing =
            listOfNotNull(
                MonitorAssistTool.GUIDES.takeIf { on("assist.local.guides.visible.v2", legacyGuide != null) },
                MonitorAssistTool.GRID.takeIf {
                    on("assist.local.grid.visible.v2", on("assist.local.ruleOfThirds"))
                },
                MonitorAssistTool.CROSS.takeIf { on("assist.local.centerCrosshair") },
                MonitorAssistTool.LEVEL.takeIf { on("assist.local.level") },
                MonitorAssistTool.EV.takeIf { on("assist.local.evMeter") },
                MonitorAssistTool.DESQ.takeIf {
                    on("assist.local.desqueeze.enabled.v2", (legacyDesqueeze ?: 1.0) > 1.0)
                },
                MonitorAssistTool.MIRROR.takeIf { on("assist.local.mirror.v1") },
            )
        val audio = listOfNotNull(MonitorAssistTool.AUDIO.takeIf { assist["audioMeters"] == true })
        // LUT starts off: this camera's looks are explicit transforms, never an automatic one.
        state.syncVisible((effectTools(assist) + scopeTools(assist) + audio + framing).toSet())
        ScopeKind.parseTokens(assist["scopeActivationOrder"] as? String).orEmpty()
            .forEach { state.bringToFront(it.assistTool) }
        (assist["fcScale"] as? String)?.let(FeedFalseColorScale::fromId)?.let { state.falseColorScale = it.sharedScale }

        (operator["assist.local.guides.ratios.v2"] as? Set<*>)?.let { names ->
            state.selectedGuides = names.filterIsInstance<String>().mapNotNull(::guideAspect).toSet()
        } ?: legacyGuide?.let { state.selectedGuides = setOf(it) }
        text("assist.local.guides.family.v2")?.let { state.guideFamily = MonitorGuideFamily.fromPersisted(it) }
        (operator["assist.local.guides.mask.v2"] as? Boolean)?.let { state.guideMask = it }
        state.setGridOption(
            thirds = on("assist.local.ruleOfThirds", state.gridThirds),
            phi = on("assist.local.phiGrid.v1", state.gridPhi),
            diagonal = on("assist.local.diagonalGrid.v1", state.gridDiagonal),
        )

        (float("assist.local.desqueeze.factor.v1")?.toDouble()
            ?: ratio("assist.local.desqueeze.ratio.v2") ?: legacyDesqueeze)
            ?.takeIf { it >= 1.0 }
            ?.let { value ->
                MonitorDesqueezePreset.matching(value)?.let(state::selectDesqueezePreset)
                    ?: state.updateDesqueezeFactor(value)
            }
        // Nikon named the axis it scales down (horizontal unless chosen); the shared direction names
        // the lens squeeze axis. Only an operator who set up desqueeze carries the old default over.
        if (operator.keys.any { it.startsWith("assist.local.desqueeze") }) {
            state.updateDesqueezeDirection(
                if (text("assist.local.desqueeze.orientation.v2") == "VERTICAL") MonitorDesqueezeDirection.HORIZONTAL
                else MonitorDesqueezeDirection.VERTICAL,
            )
        }
        if (on("assist.lut.splitComparison.enabled.v1")) {
            state.setSplitComparison(true, text("assist.lut.splitComparison.orientation.v1") != "HORIZONTAL")
        }

        (operator["assist.falseColor.reference.v1"] as? Boolean)?.let { state.falseColorReference = it }
        state.setPeaking(
            color = enum<MonitorPeakingColor>("assist.peaking.color.v1") ?: state.peakingColor,
            sense = if (text("assist.peaking.sensitivity.v1") == "MEDIUM") MonitorPeakingSense.MED
                else enum<MonitorPeakingSense>("assist.peaking.sensitivity.v1") ?: state.peakingSensitivity,
        )
        enum<MonitorZebraUnit>("assist.zebra.unit.v1")?.let { state.zebraUnit = it }
        state.setZebraHighlight(
            enabled = on("assist.zebra.highlight.enabled.v1", state.zebraHighlight),
            ire = float("assist.zebra.highlight.ire.v1")?.toDouble() ?: state.zebraHighlightIRE,
            color = enum<MonitorZebraPaint>("assist.zebra.highlight.color.v1") ?: state.zebraHighlightColor,
        )
        state.setZebraMidtone(
            enabled = on("assist.zebra.midtone.enabled.v1", state.zebraMidtone),
            ire = float("assist.zebra.midtone.ire.v1")?.toDouble() ?: state.zebraMidtoneIRE,
            color = enum<MonitorZebraPaint>("assist.zebra.midtone.color.v1") ?: state.zebraMidtoneColor,
        )

        copyScopes(state)
        state.persist()
    }

    private fun copyScopes(state: MonitorAssistState) {
        fun guides(prefix: String) =
            MonitorScopeGuides(
                clip = on("$prefix.clip", true), crush = on("$prefix.crush", true), middle = on("$prefix.middle", true),
            )
        // Brightness written before calibration v2 was a quarter of today's scale.
        val gain = if ((operator["assist.scopes.waveformParade.brightnessCalibrationVersion.v1"] as? Int ?: 0) >= 2) 1L else 4L
        fun brightness(key: String) = (operator[key] as? Int)?.let { (it * gain).coerceIn(0L, 200L).toInt() }
        fun scale(key: String) = float(key)?.toDouble() ?: 1.0
        state.setWaveform(
            mode = enum<MonitorWaveformMode>("assist.scopes.waveform.mode.v1") ?: state.waveMode,
            brightness = brightness("assist.scopes.waveform.brightness.v1") ?: state.waveBrightness,
            guides = guides("assist.scopes.waveform.guides.v1"),
            scale = scale("assist.scopes.waveform.scale.v1"),
        )
        state.setParade(
            mode = enum<MonitorParadeMode>("assist.scopes.parade.mode.v1") ?: state.paradeMode,
            brightness = brightness("assist.scopes.parade.brightness.v1") ?: state.paradeBrightness,
            guides = guides("assist.scopes.parade.guides.v1"),
            scale = scale("assist.scopes.parade.scale.v1"),
        )
        state.setVectorscope(
            zoom = enum<MonitorVectorscopeZoom>("assist.scopes.vector.zoom.v1") ?: state.vectorZoom,
            brightness = operator["assist.scopes.vector.brightness.v1"] as? Int ?: state.vectorBrightness,
            scale = scale("assist.scopes.vector.scale.v1"),
        )
        val compensation =
            listOf("scope-meter-v1", "assist.scopes.crushClipCompensation.v1").firstNotNullOfOrNull { operator[it] as? Int }
        state.setHistogram(
            traffic = on("assist.scopes.histogramTrafficLights.v1", state.histoTrafficLights),
            compensation = compensation?.let(MonitorCrushClipCompensation::fromRaw) ?: state.crushClipCompensation,
            scale = scale("assist.scopes.histogram.scale.v1"),
        )
        state.setScale(MonitorAssistTool.LIGHTS, scale("assist.scopes.trafficLights.scale.v1"))
    }

    private fun guideAspect(name: String): MonitorGuideAspect? =
        when (name) {
            "RATIO_276" -> MonitorGuideAspect.CINEMA_276
            "RATIO_239" -> MonitorGuideAspect.CINEMA
            "RATIO_235" -> MonitorGuideAspect.CINEMA_235
            "RATIO_200" -> MonitorGuideAspect.TWO_K
            "RATIO_185" -> MonitorGuideAspect.WIDE
            "RATIO_16_9" -> MonitorGuideAspect.HD
            "RATIO_166" -> MonitorGuideAspect.EURO
            "RATIO_143" -> MonitorGuideAspect.IMAX
            "RATIO_4_3" -> MonitorGuideAspect.ACADEMY
            "RATIO_9_16" -> MonitorGuideAspect.VERTICAL
            "RATIO_4_5" -> MonitorGuideAspect.SOCIAL
            "RATIO_1_1" -> MonitorGuideAspect.SQUARE
            "RATIO_2_3" -> MonitorGuideAspect.PORTRAIT
            "RATIO_191" -> MonitorGuideAspect.FEED
            else -> null
        }
}

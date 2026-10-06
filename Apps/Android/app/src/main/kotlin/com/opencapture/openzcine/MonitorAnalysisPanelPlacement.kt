package com.opencapture.openzcine

import android.content.Context
import android.content.SharedPreferences
import com.opencapture.monitorui.MonitorAssistTool
import com.opencapture.monitorui.MonitorScopeStoredCenter
import com.opencapture.opencine.appkit.MonitorAssistState
import com.opencapture.monitorui.MonitorFieldLayout
import com.opencapture.monitorui.MonitorRect
import com.opencapture.openzcine.settings.SideRailPlan
import kotlin.math.max
import kotlin.math.min

private const val PANEL_CONTROL_CLEARANCE_DP = 8f
// Internal: MonitorScreen's portrait aspect toggle shares the reset lane's slot metrics.
internal const val FOCUS_RESET_BUTTON_SIZE_DP = 40f
internal const val FOCUS_RESET_PANEL_GAP_DP = 10f
private const val FOCUS_RESET_MAX_CLEARANCE_PASSES = 8

/** Stable identities for the movable live-monitor analysis panels. */
internal enum class MonitorAnalysisPanelID(
    val storageKey: String,
    internal val legacyStore: LegacyPanelStore,
) {
    WAVEFORM("wave", LegacyPanelStore.SCOPES),
    PARADE("parade", LegacyPanelStore.SCOPES),
    HISTOGRAM("histo", LegacyPanelStore.SCOPES),
    VECTORSCOPE("vector", LegacyPanelStore.SCOPES),
    TRAFFIC_LIGHTS("lights", LegacyPanelStore.SCOPES),
    FALSE_COLOR_REFERENCE("fcref", LegacyPanelStore.FALSE_COLOR),
}

/** Legacy preference file that owned a panel before the OPE-68 unified store. */
internal enum class LegacyPanelStore { SCOPES, FALSE_COLOR }

/**
 * Exact viewport used for normalized persistence plus its current control-clear presentation frame.
 *
 * Persistence deliberately uses [viewport], not [safeBounds]. A toolbar appearing therefore clamps
 * the live panel without rewriting the operator's normalized intent; hiding it restores the same
 * relative position. [safeBounds] comes only from shared zone-map frames and existing portrait-rail
 * geometry.
 */
internal data class MonitorAnalysisPanelLayout(
    val viewport: MonitorRect,
    val safeBounds: MonitorRect,
) {
    init {
        require(viewport.width >= 0f && viewport.height >= 0f) {
            "monitor analysis viewport must be non-negative"
        }
        require(safeBounds.width >= 0f && safeBounds.height >= 0f) {
            "monitor analysis safe bounds must be non-negative"
        }
        require(
            safeBounds.x >= viewport.x &&
                safeBounds.y >= viewport.y &&
                safeBounds.x + safeBounds.width <= viewport.x + viewport.width &&
                safeBounds.y + safeBounds.height <= viewport.y + viewport.height,
        ) {
            "monitor analysis safe bounds must remain inside the viewport"
        }
    }
}

/**
 * Seats the focus-reset affordance in its feed-relative corner before movable-panel avoidance.
 *
 * The frame uses monitor-zone dp coordinates, matching every [MonitorAnalysisPanelLayout] frame.
 */
internal fun focusResetButtonBaseFrame(
    feed: MonitorRect,
    isPortrait: Boolean,
    bottomChromeInset: Float,
): MonitorRect {
    val x =
        if (isPortrait) {
            feed.x + feed.width - FOCUS_RESET_PANEL_GAP_DP - FOCUS_RESET_BUTTON_SIZE_DP
        } else {
            feed.x + FOCUS_RESET_PANEL_GAP_DP
        }
    return clampScopeFrame(
        MonitorRect(
            x = x,
            y =
                feed.y + feed.height -
                    bottomChromeInset.coerceAtLeast(0f) -
                    FOCUS_RESET_PANEL_GAP_DP -
                    FOCUS_RESET_BUTTON_SIZE_DP,
            width = FOCUS_RESET_BUTTON_SIZE_DP,
            height = FOCUS_RESET_BUTTON_SIZE_DP,
        ),
        feed,
    )
}

/**
 * The 50/50 quick key's slot: the focus-reset lane, one key higher when that key is mounted.
 *
 * Sharing the lane rather than claiming a corner of its own is what keeps it off the DISP key
 * (bottom-right of the rail with no bottom bar), the MF focus dial and the collapsed portrait
 * assist rail — all of which already own a corner.
 */
internal fun splitComparisonKeyFrame(
    feed: MonitorRect,
    isPortrait: Boolean,
    bottomChromeInset: Float,
    focusResetMounted: Boolean,
    widthDp: Float,
    heightDp: Float,
): MonitorRect {
    val lane = focusResetButtonBaseFrame(feed, isPortrait, bottomChromeInset)
    val lift = if (focusResetMounted) FOCUS_RESET_BUTTON_SIZE_DP + FOCUS_RESET_PANEL_GAP_DP else 0f
    // Right-aligned in portrait (the lane hugs the trailing edge there), leading-aligned in
    // landscape — so a key wider than the round reset button grows away from the feed edge.
    val x = if (isPortrait) lane.x + lane.width - widthDp else lane.x
    return clampScopeFrame(
        MonitorRect(
            x = x,
            y = lane.y + (FOCUS_RESET_BUTTON_SIZE_DP - heightDp) / 2f - lift,
            width = widthDp,
            height = heightDp,
        ),
        feed,
    )
}


/**
 * Lifts the focus-reset affordance above overlapping movable analysis panels.
 *
 * Panels are considered from lowest to highest so a crowded stack is climbed one panel at a time.
 * The bounded pass count matches the iOS policy and the result never leaves [bounds]. The button is
 * also mounted above the panels in Compose, so an impossible fully-packed layout remains reachable.
 */
internal fun focusResetButtonClearFrame(
    base: MonitorRect,
    panelFrames: Collection<MonitorRect>,
    bounds: MonitorRect,
): MonitorRect {
    val panels = panelFrames.sortedByDescending { it.y + it.height }
    var frame = clampScopeFrame(base, bounds)
    repeat(FOCUS_RESET_MAX_CLEARANCE_PASSES) {
        var moved = false
        panels.forEach { panel ->
            if (frame.intersectsWithGap(panel, FOCUS_RESET_PANEL_GAP_DP)) {
                val nextY = panel.y - FOCUS_RESET_PANEL_GAP_DP - frame.height
                if (nextY < frame.y) {
                    frame = frame.copy(y = nextY)
                    moved = true
                }
            }
        }
        if (!moved) return clampScopeFrame(frame, bounds)
    }
    return clampScopeFrame(frame, bounds)
}

private fun MonitorRect.intersectsWithGap(other: MonitorRect, gap: Float): Boolean =
    x < other.x + other.width + gap &&
        x + width > other.x - gap &&
        y < other.y + other.height + gap &&
        y + height > other.y - gap

/** Actual monitor chrome surfaces mounted beside analysis panels in the current DISP/layout mode. */
internal data class MonitorAnalysisChromeMounts(
    val assistStrip: Boolean,
    val captureStrip: Boolean,
    /**
     * Which landscape rail controls are on screen, or `null` in portrait. One plan instead of the
     * old full-rail / settings-recovery / record-safety triple: the rail is six independent
     * elements now, so a panel corridor carved from three booleans could not describe it.
     */
    val landscapeRail: SideRailPlan? = null,
)

/** Mirrors the landscape and portrait chrome mounting conditions without inferring from mode names. */
internal fun monitorAnalysisChromeMounts(
    isPortrait: Boolean,
    isPortraitFill: Boolean,
    isClean: Boolean,
    isCommand: Boolean,
    assistToolbarVisible: Boolean,
    cameraValuesVisible: Boolean,
    landscapeRail: SideRailPlan? = null,
): MonitorAnalysisChromeMounts {
    val sideMounts =
        MonitorAnalysisChromeMounts(
            assistStrip = false,
            captureStrip = false,
            landscapeRail = landscapeRail.takeIf { !isPortrait },
        )
    if (isCommand) return sideMounts
    if (isPortrait) {
        return if (isPortraitFill) {
            MonitorAnalysisChromeMounts(
                assistStrip = assistToolbarVisible,
                captureStrip = cameraValuesVisible,
            )
        } else {
            MonitorAnalysisChromeMounts(
                assistStrip = assistToolbarVisible,
                captureStrip = false,
            )
        }
    }
    return MonitorAnalysisChromeMounts(
        assistStrip = !isClean && assistToolbarVisible,
        captureStrip = !isClean && cameraValuesVisible,
        landscapeRail = sideMounts.landscapeRail,
    )
}

/** A saved normalized centre, independent of pixels, dp density, and orientation. */
internal data class NormalizedPanelCenter(
    val xFraction: Float,
    val yFraction: Float,
) {
    val isValid: Boolean
        get() = xFraction.isFinite() && yFraction.isFinite()

    fun reconciled(): NormalizedPanelCenter =
        NormalizedPanelCenter(
            xFraction = xFraction.coerceIn(0f, 1f),
            yFraction = yFraction.coerceIn(0f, 1f),
        )
}

/**
 * Resolves the live floating-panel canvas from the shared monitor zone map.
 *
 * Portrait fit returns `null`: its recency-selected scopes stay in the shared stacked zone and no
 * false-colour key is mounted. Landscape uses nearly the full physical viewport — only the side
 * button rails (lock/battery left; record/media/settings/DISP right) stay out of the drag clamp,
 * matching the iOS “almost anywhere” free roam while keeping those rails hittable. Top status and
 * bottom assist/capture strips are **not** subtracted from drag bounds (defaults still clear them).
 * Portrait fill uses the mapped feed as its exact viewport, then clears the top bar, capture strip,
 * system rail, and the assist palette's portrait column.
 */
internal fun monitorAnalysisPanelLayout(
    layout: MonitorFieldLayout,
    physicalViewport: MonitorRect,
    isPortrait: Boolean,
    isPortraitFill: Boolean,
    statusBarVisible: Boolean,
    chromeMounts: MonitorAnalysisChromeMounts,
): MonitorAnalysisPanelLayout? {
    if (isPortrait && !isPortraitFill) return null
    val viewport = if (isPortraitFill) layout.picture else physicalViewport
    var left = viewport.x
    var top = viewport.y
    var right = viewport.x + viewport.width
    var bottom = viewport.y + viewport.height

    if (isPortraitFill) {
        // Portrait fill keeps tighter chrome carving — rails sit on the feed edges.
        if (statusBarVisible) {
            top = max(top, layout.status.maxY + PANEL_CONTROL_CLEARANCE_DP)
        }
        // The assist palette's portrait column grows up the leading edge; clear its full width.
        if (chromeMounts.assistStrip) {
            left = max(left, layout.assists.maxX + PANEL_CONTROL_CLEARANCE_DP)
        }
        if (chromeMounts.captureStrip) {
            bottom = min(bottom, layout.values.y - PANEL_CONTROL_CLEARANCE_DP)
        }
        bottom = min(bottom, layout.system.y - PANEL_CONTROL_CLEARANCE_DP)
    } else {
        // Landscape: carve only the vertical button rails, and only around the controls that are
        // actually mounted. Top/bottom chrome stays drawable over panels the way iOS does (rails
        // are painted above scopes).
        val rail = chromeMounts.landscapeRail
        if (rail != null) {
            if (rail.lock) {
                left = maxOf(left, layout.lock.maxX + PANEL_CONTROL_CLEARANCE_DP)
            }
            if (rail.batteries) {
                left = maxOf(left, layout.gauges.maxX + PANEL_CONTROL_CLEARANCE_DP)
            }
            listOfNotNull(
                layout.display.takeIf { rail.disp },
                layout.record.takeIf { rail.record },
                layout.media.takeIf { rail.media },
                layout.settings.takeIf { rail.settings },
            )
                .minOfOrNull { it.x - PANEL_CONTROL_CLEARANCE_DP }
                ?.let { right = min(right, it) }
        }
    }

    val safeLeft = left.coerceIn(viewport.x, viewport.x + viewport.width)
    val safeTop = top.coerceIn(viewport.y, viewport.y + viewport.height)
    val safeRight = right.coerceIn(safeLeft, viewport.x + viewport.width)
    val safeBottom = bottom.coerceIn(safeTop, viewport.y + viewport.height)
    return MonitorAnalysisPanelLayout(
        viewport = viewport,
        safeBounds =
            MonitorRect(
                x = safeLeft,
                y = safeTop,
                width = safeRight - safeLeft,
                height = safeBottom - safeTop,
            ),
    )
}

/**
 * The live scope and false-colour centres saved before the shared assist state held them: the v2
 * file and the two pre-OPE-68 files, read once by [movePanelCentres]. A complete finite pair is
 * reconciled into 0...1; a partial or malformed v2 pair is dropped; an unknown schema fails closed
 * and keeps its data.
 */
internal class MonitorAnalysisPanelPlacementStore internal constructor(
    private val preferences: SharedPreferences,
    private val legacyScopePreferences: SharedPreferences? = null,
    private val legacyFalseColorPreferences: SharedPreferences? = null,
) {
    constructor(context: Context) : this(
        preferences = context.getSharedPreferences(STORE_NAME, Context.MODE_PRIVATE),
        legacyScopePreferences = context.getSharedPreferences(LEGACY_SCOPE_STORE_NAME, Context.MODE_PRIVATE),
        legacyFalseColorPreferences =
            context.getSharedPreferences(LEGACY_FALSE_COLOR_STORE_NAME, Context.MODE_PRIVATE),
    )

    internal fun storedCenter(id: MonitorAnalysisPanelID): NormalizedPanelCenter? {
        when (schemaState()) {
            StoreSchema.UNSUPPORTED -> return null
            StoreSchema.CURRENT -> {
                val current = readPair(preferences, xKey(id), yKey(id))
                if (current.state != StoredPairState.ABSENT) {
                    if (current.value == null) recenter(id)
                    return current.value?.reconciled()
                }
            }
            StoreSchema.LEGACY -> Unit
        }
        val legacy = legacyPreferences(id) ?: return null
        return readPair(legacy, legacyXKey(id), legacyYKey(id)).value?.reconciled()
    }

    /** Clears one panel only; all unrelated panel centres survive. */
    fun recenter(id: MonitorAnalysisPanelID) {
        if (schemaState() != StoreSchema.UNSUPPORTED) {
            preferences.edit().remove(xKey(id)).remove(yKey(id)).apply()
        }
        legacyPreferences(id)?.let { legacy ->
            legacy.edit()
                .remove(legacyXKey(id))
                .remove(legacyYKey(id))
                .apply()
        }
    }

    private fun schemaState(): StoreSchema {
        if (!preferences.contains(SCHEMA_KEY)) return StoreSchema.LEGACY
        val version = runCatching { preferences.getInt(SCHEMA_KEY, -1) }.getOrNull()
            ?: return StoreSchema.UNSUPPORTED
        return when {
            version == SCHEMA_VERSION -> StoreSchema.CURRENT
            version in 0 until SCHEMA_VERSION -> StoreSchema.LEGACY
            else -> StoreSchema.UNSUPPORTED
        }
    }

    private fun legacyPreferences(id: MonitorAnalysisPanelID): SharedPreferences? =
        when (id.legacyStore) {
            LegacyPanelStore.SCOPES -> legacyScopePreferences
            LegacyPanelStore.FALSE_COLOR -> legacyFalseColorPreferences
        }

    private fun readPair(
        source: SharedPreferences,
        xKey: String,
        yKey: String,
    ): StoredPair {
        val hasX = source.contains(xKey)
        val hasY = source.contains(yKey)
        if (!hasX && !hasY) return StoredPair(StoredPairState.ABSENT, null)
        if (!hasX || !hasY) return StoredPair(StoredPairState.INVALID, null)
        val center =
            runCatching {
                NormalizedPanelCenter(
                    xFraction = source.getFloat(xKey, Float.NaN),
                    yFraction = source.getFloat(yKey, Float.NaN),
                )
            }.getOrNull()
        return if (center?.isValid == true) {
            StoredPair(StoredPairState.COMPLETE, center)
        } else {
            StoredPair(StoredPairState.INVALID, null)
        }
    }

    private fun xKey(id: MonitorAnalysisPanelID): String = "${id.storageKey}.centerX.v2"

    private fun yKey(id: MonitorAnalysisPanelID): String = "${id.storageKey}.centerY.v2"

    private fun legacyXKey(id: MonitorAnalysisPanelID): String = "${id.storageKey}.centerX"

    private fun legacyYKey(id: MonitorAnalysisPanelID): String = "${id.storageKey}.centerY"

    private data class StoredPair(
        val state: StoredPairState,
        val value: NormalizedPanelCenter?,
    )

    private enum class StoredPairState { ABSENT, COMPLETE, INVALID }

    private enum class StoreSchema { LEGACY, CURRENT, UNSUPPORTED }

    companion object {
        internal const val STORE_NAME = "monitorAnalysisPanelPlacement"
        internal const val LEGACY_SCOPE_STORE_NAME = "scopePanelPlacement"
        internal const val LEGACY_FALSE_COLOR_STORE_NAME = "falseColorReferencePlacement"
        internal const val SCHEMA_KEY = "schema"
        internal const val SCHEMA_VERSION = 2
    }
}

/**
 * Moves the centres this store saved into the shared assist state once, then clears them here, so a
 * later launch finds nothing to move. Scope centres were saved on the landscape canvas and fill the
 * landscape slot; the false-colour key had one centre for landscape and portrait fill, so it fills
 * both slots. A centre the shared state already holds wins.
 */
internal fun MonitorAnalysisPanelPlacementStore.movePanelCentres(into: MonitorAssistState) {
    ScopeKind.entries.forEach { kind ->
        val id = kind.monitorAnalysisPanelID()
        val stored = storedCenter(id) ?: return@forEach
        into.storeCenterIfAbsent(kind.assistTool, stored.shared(), listOf(false))
        recenter(id)
    }
    storedCenter(MonitorAnalysisPanelID.FALSE_COLOR_REFERENCE)?.let { stored ->
        into.storeCenterIfAbsent(MonitorAssistTool.FALSE, stored.shared(), listOf(false, true))
        recenter(MonitorAnalysisPanelID.FALSE_COLOR_REFERENCE)
    }
}

/** Moves the live audio meter's one saved centre into both shared slots once, as [movePanelCentres]. */
internal fun StoredPanelCenter.moveAudioCentre(into: MonitorAssistState) {
    val stored = load() ?: return
    into.storeCenterIfAbsent(MonitorAssistTool.AUDIO, stored, listOf(false, true))
    clear()
}

private fun MonitorAssistState.storeCenterIfAbsent(
    tool: MonitorAssistTool,
    center: MonitorScopeStoredCenter,
    orientations: List<Boolean>,
) {
    orientations.forEach { portrait ->
        if (centerFor(tool, portrait) == null) storeCenter(tool, center, portrait)
    }
}

private fun NormalizedPanelCenter.shared(): MonitorScopeStoredCenter =
    MonitorScopeStoredCenter(xFraction.toDouble(), yFraction.toDouble())

/**
 * One panel centre in its own preference file (`<prefix>.centerX`/`.centerY`), normalized to the
 * panel's viewport: the playback false-colour key and audio meter, and the live audio meter's
 * pre-shared save.
 */
internal class StoredPanelCenter(private val preferences: SharedPreferences, private val prefix: String) {
    constructor(context: Context, name: String, prefix: String) :
        this(context.getSharedPreferences(name, Context.MODE_PRIVATE), prefix)

    fun load(): MonitorScopeStoredCenter? {
        if (!preferences.contains("$prefix.centerX") || !preferences.contains("$prefix.centerY")) return null
        val x = runCatching { preferences.getFloat("$prefix.centerX", Float.NaN) }.getOrNull() ?: return null
        val y = runCatching { preferences.getFloat("$prefix.centerY", Float.NaN) }.getOrNull() ?: return null
        if (!x.isFinite() || !y.isFinite()) return null
        return MonitorScopeStoredCenter(x.coerceIn(0f, 1f).toDouble(), y.coerceIn(0f, 1f).toDouble())
    }

    fun save(center: MonitorScopeStoredCenter) {
        preferences.edit()
            .putFloat("$prefix.centerX", center.xFraction.toFloat().coerceIn(0f, 1f))
            .putFloat("$prefix.centerY", center.yFraction.toFloat().coerceIn(0f, 1f))
            .apply()
    }

    fun clear() {
        preferences.edit().remove("$prefix.centerX").remove("$prefix.centerY").apply()
    }
}

/** Scope-to-placement identity mapping kept beside the placement policy. */
internal fun ScopeKind.monitorAnalysisPanelID(): MonitorAnalysisPanelID =
    when (this) {
        ScopeKind.WAVEFORM -> MonitorAnalysisPanelID.WAVEFORM
        ScopeKind.PARADE -> MonitorAnalysisPanelID.PARADE
        ScopeKind.HISTOGRAM -> MonitorAnalysisPanelID.HISTOGRAM
        ScopeKind.VECTORSCOPE -> MonitorAnalysisPanelID.VECTORSCOPE
        ScopeKind.TRAFFIC_LIGHTS -> MonitorAnalysisPanelID.TRAFFIC_LIGHTS
    }

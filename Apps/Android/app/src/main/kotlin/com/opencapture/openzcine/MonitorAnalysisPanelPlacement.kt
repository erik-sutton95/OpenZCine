package com.opencapture.openzcine

import android.content.Context
import android.content.SharedPreferences
import com.opencapture.openzcine.bridge.MonitorZones
import com.opencapture.openzcine.bridge.ZoneFrame
import kotlin.math.max
import kotlin.math.min

private const val PANEL_CONTROL_CLEARANCE_DP = 8f

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
    val viewport: ZoneFrame,
    val safeBounds: ZoneFrame,
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

/** Actual monitor chrome surfaces mounted beside analysis panels in the current DISP/layout mode. */
internal data class MonitorAnalysisChromeMounts(
    val assistStrip: Boolean,
    val assistRail: Boolean,
    val captureStrip: Boolean,
)

/** Mirrors the landscape and portrait chrome mounting conditions without inferring from mode names. */
internal fun monitorAnalysisChromeMounts(
    isPortrait: Boolean,
    isPortraitFill: Boolean,
    isClean: Boolean,
    isCommand: Boolean,
    assistToolbarVisible: Boolean,
    cameraValuesVisible: Boolean,
): MonitorAnalysisChromeMounts {
    if (isCommand) return MonitorAnalysisChromeMounts(false, false, false)
    if (isPortrait) {
        return if (isPortraitFill) {
            MonitorAnalysisChromeMounts(
                assistStrip = false,
                assistRail = assistToolbarVisible,
                captureStrip = cameraValuesVisible,
            )
        } else {
            MonitorAnalysisChromeMounts(
                assistStrip = assistToolbarVisible,
                assistRail = false,
                captureStrip = false,
            )
        }
    }
    return MonitorAnalysisChromeMounts(
        assistStrip = !isClean && assistToolbarVisible,
        assistRail = false,
        captureStrip = !isClean && cameraValuesVisible,
    )
}

/** Normalized app-local centre, independent of pixels, dp density, and orientation. */
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

    fun frame(size: ZoneFrame, layout: MonitorAnalysisPanelLayout): ZoneFrame {
        val normalized = reconciled()
        val centerX = layout.viewport.x + normalized.xFraction * layout.viewport.width
        val centerY = layout.viewport.y + normalized.yFraction * layout.viewport.height
        return clampScopeFrame(
            ZoneFrame(
                x = centerX - size.width / 2f,
                y = centerY - size.height / 2f,
                width = size.width,
                height = size.height,
            ),
            layout.safeBounds,
        )
    }

    companion object {
        fun from(frame: ZoneFrame, viewport: ZoneFrame): NormalizedPanelCenter =
            NormalizedPanelCenter(
                xFraction =
                    (frame.x + frame.width / 2f - viewport.x) /
                        max(1f, viewport.width),
                yFraction =
                    (frame.y + frame.height / 2f - viewport.y) /
                        max(1f, viewport.height),
            ).reconciled()
    }
}

/**
 * Resolves the live floating-panel canvas from the shared monitor zone map.
 *
 * Portrait fit returns `null`: its recency-selected scopes stay in the shared stacked zone and no
 * false-colour key is mounted. Landscape uses the physical viewport but removes the mapped top,
 * bottom, and side chrome bands. Portrait fill uses the mapped feed as its exact viewport, then
 * clears the top bar, capture strip, system rail, and the existing expanded assist-rail footprint.
 */
internal fun monitorAnalysisPanelLayout(
    zones: MonitorZones,
    physicalViewport: ZoneFrame,
    isPortrait: Boolean,
    isPortraitFill: Boolean,
    statusBarVisible: Boolean,
    chromeMounts: MonitorAnalysisChromeMounts,
): MonitorAnalysisPanelLayout? {
    if (isPortrait && !isPortraitFill) return null
    val viewport = if (isPortraitFill) zones.feed else physicalViewport
    var left = viewport.x
    var top = viewport.y
    var right = viewport.x + viewport.width
    var bottom = viewport.y + viewport.height

    if (statusBarVisible) {
        top = max(top, zones.infoBar.y + zones.infoBar.height + PANEL_CONTROL_CLEARANCE_DP)
    }

    if (isPortraitFill) {
        if (chromeMounts.assistRail) {
            val rail =
                portraitFillAssistRailFrame(
                    feed = zones.feed,
                    captureStrip = zones.captureStrip.takeIf { chromeMounts.captureStrip },
                    expanded = true,
                )
            left = max(left, rail.x + rail.width + PANEL_CONTROL_CLEARANCE_DP)
        }
        if (chromeMounts.captureStrip) {
            zones.captureStrip?.let { strip ->
                bottom = min(bottom, strip.y - PANEL_CONTROL_CLEARANCE_DP)
            }
        }
        bottom = min(bottom, zones.systemCluster.y - PANEL_CONTROL_CLEARANCE_DP)
    } else {
        left =
            maxOf(
                left,
                zones.lock.x + zones.lock.width + PANEL_CONTROL_CLEARANCE_DP,
                zones.batteryCluster?.let { it.x + it.width + PANEL_CONTROL_CLEARANCE_DP }
                    ?: left,
            )
        right =
            listOf(zones.disp, zones.record, zones.media, zones.settings)
                .minOfOrNull { it.x - PANEL_CONTROL_CLEARANCE_DP }
                ?.let { min(right, it) }
                ?: right
        if (chromeMounts.assistStrip) {
            zones.assistStrip?.let { strip ->
                bottom = min(bottom, strip.y - PANEL_CONTROL_CLEARANCE_DP)
            }
        }
        if (chromeMounts.captureStrip) {
            zones.captureStrip?.let { strip ->
                bottom = min(bottom, strip.y - PANEL_CONTROL_CLEARANCE_DP)
            }
        }
    }

    val safeLeft = left.coerceIn(viewport.x, viewport.x + viewport.width)
    val safeTop = top.coerceIn(viewport.y, viewport.y + viewport.height)
    val safeRight = right.coerceIn(safeLeft, viewport.x + viewport.width)
    val safeBottom = bottom.coerceIn(safeTop, viewport.y + viewport.height)
    return MonitorAnalysisPanelLayout(
        viewport = viewport,
        safeBounds =
            ZoneFrame(
                x = safeLeft,
                y = safeTop,
                width = safeRight - safeLeft,
                height = safeBottom - safeTop,
            ),
    )
}

/**
 * Versioned app-local placement store for live scopes and the false-colour reference.
 *
 * The first read migrates the two pre-OPE-68 preference files. Complete finite pairs are clamped
 * and copied; partial, non-finite, or type-corrupt pairs are discarded deterministically. A stored
 * centre is never rewritten merely because current chrome forces a temporary presentation clamp.
 */
internal class MonitorAnalysisPanelPlacementStore internal constructor(
    private val preferences: SharedPreferences,
    private val legacyScopePreferences: SharedPreferences? = null,
    private val legacyFalseColorPreferences: SharedPreferences? = null,
) {
    constructor(context: Context) : this(
        preferences =
            context.getSharedPreferences(
                STORE_NAME,
                Context.MODE_PRIVATE,
            ),
        legacyScopePreferences =
            context.getSharedPreferences(
                LEGACY_SCOPE_STORE_NAME,
                Context.MODE_PRIVATE,
            ),
        legacyFalseColorPreferences =
            context.getSharedPreferences(
                LEGACY_FALSE_COLOR_STORE_NAME,
                Context.MODE_PRIVATE,
            ),
    )

    fun resolve(
        id: MonitorAnalysisPanelID,
        default: ZoneFrame,
        layout: MonitorAnalysisPanelLayout,
    ): ZoneFrame {
        val stored = load(id) ?: return clampScopeFrame(default, layout.safeBounds)
        return stored.frame(default, layout)
    }

    fun save(
        id: MonitorAnalysisPanelID,
        frame: ZoneFrame,
        layout: MonitorAnalysisPanelLayout,
    ) {
        val normalized = NormalizedPanelCenter.from(frame, layout.viewport)
        currentSchemaEditor()
            .putInt(SCHEMA_KEY, SCHEMA_VERSION)
            .putFloat(xKey(id), normalized.xFraction)
            .putFloat(yKey(id), normalized.yFraction)
            .apply()
    }

    /** Clears one panel only; all unrelated active and hidden panel positions survive. */
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

    internal fun storedCenter(id: MonitorAnalysisPanelID): NormalizedPanelCenter? = load(id)

    private fun load(id: MonitorAnalysisPanelID): NormalizedPanelCenter? {
        when (schemaState()) {
            StoreSchema.UNSUPPORTED -> return null
            StoreSchema.CURRENT -> {
                val current = readPair(preferences, xKey(id), yKey(id))
                if (current.state != StoredPairState.ABSENT) {
                    if (current.value == null) recenter(id)
                    return current.value?.reconciled()?.also { reconciled ->
                        if (reconciled != current.value) writeMigrated(id, reconciled)
                    }
                }
            }
            StoreSchema.LEGACY -> Unit
        }

        val legacy = legacyPreferences(id) ?: return null
        val migrated = readPair(legacy, legacyXKey(id), legacyYKey(id))
        if (migrated.state == StoredPairState.ABSENT) return null
        legacy.edit().remove(legacyXKey(id)).remove(legacyYKey(id)).apply()
        val value = migrated.value?.reconciled() ?: return null
        writeMigrated(id, value)
        return value
    }

    private fun writeMigrated(id: MonitorAnalysisPanelID, center: NormalizedPanelCenter) {
        currentSchemaEditor()
            .putInt(SCHEMA_KEY, SCHEMA_VERSION)
            .putFloat(xKey(id), center.xFraction)
            .putFloat(yKey(id), center.yFraction)
            .apply()
    }

    /**
     * Starts a v2 write transaction. Unknown or stale schemas are cleared only for a deliberate
     * save or a supported legacy migration; passive resolution never downgrades future data.
     */
    private fun currentSchemaEditor(): SharedPreferences.Editor =
        preferences.edit().also { editor ->
            if (schemaState() != StoreSchema.CURRENT) editor.clear()
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

/** Scope-to-placement identity mapping kept beside the placement policy. */
internal fun ScopeKind.monitorAnalysisPanelID(): MonitorAnalysisPanelID =
    when (this) {
        ScopeKind.WAVEFORM -> MonitorAnalysisPanelID.WAVEFORM
        ScopeKind.PARADE -> MonitorAnalysisPanelID.PARADE
        ScopeKind.HISTOGRAM -> MonitorAnalysisPanelID.HISTOGRAM
        ScopeKind.VECTORSCOPE -> MonitorAnalysisPanelID.VECTORSCOPE
        ScopeKind.TRAFFIC_LIGHTS -> MonitorAnalysisPanelID.TRAFFIC_LIGHTS
    }

/** Only floating scopes and the false-colour key own placement. Feed-aligned assists never do. */
internal fun AssistTool.monitorAnalysisPanelID(): MonitorAnalysisPanelID? =
    when (this) {
        AssistTool.FALSE -> MonitorAnalysisPanelID.FALSE_COLOR_REFERENCE
        AssistTool.WAVE -> MonitorAnalysisPanelID.WAVEFORM
        AssistTool.PARADE -> MonitorAnalysisPanelID.PARADE
        AssistTool.HISTO -> MonitorAnalysisPanelID.HISTOGRAM
        AssistTool.VECTOR -> MonitorAnalysisPanelID.VECTORSCOPE
        AssistTool.LIGHTS -> MonitorAnalysisPanelID.TRAFFIC_LIGHTS
        else -> null
    }

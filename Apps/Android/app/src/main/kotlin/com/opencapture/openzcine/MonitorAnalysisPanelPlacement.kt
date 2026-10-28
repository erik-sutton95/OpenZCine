package com.opencapture.openzcine

import android.content.Context
import android.content.SharedPreferences
import com.opencapture.monitorui.MonitorAssistTool
import com.opencapture.monitorui.MonitorScopeStoredCenter
import com.opencapture.opencine.appkit.MonitorAssistState
import com.opencapture.monitorui.MonitorRect


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
                // Compare remaining extents: re-adding a fractional inset can round past the edge.
                safeBounds.width <= viewport.maxX - safeBounds.x &&
                safeBounds.height <= viewport.maxY - safeBounds.y,
        ) {
            "monitor analysis safe bounds must remain inside the viewport"
        }
    }
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

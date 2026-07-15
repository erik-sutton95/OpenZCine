package com.opencapture.openzcine.media

import android.content.Context
import android.content.SharedPreferences
import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.opencapture.openzcine.AssistState
import com.opencapture.openzcine.AssistTool
import com.opencapture.openzcine.FeedEffectsState
import com.opencapture.openzcine.lut.StoredLutSelection
import com.opencapture.openzcine.settings.LocalFramingAssistConfiguration

/**
 * Persisted playback-only view-assist visibility.
 *
 * IOS deliberately keeps playback visibility separate from live-monitor
 * visibility while sharing the operator's LUT, false-colour, peaking, zebra,
 * scope, and framing configuration values. Android mirrors that split here:
 * [assists] reuses the proven effect/scope state machine but never writes the
 * process-global live renderer mirror, and framing activation has its own
 * playback preference set.
 */
@Stable
class PlaybackAssistState internal constructor(
    val assists: AssistState,
    initialFramingTools: Set<AssistTool>,
    private val persistFramingTools: (Set<AssistTool>) -> Unit = {},
) {
    /** Playback-visible framing controls, independent of live-view visibility. */
    var framingTools: Set<AssistTool> by
        mutableStateOf(AssistTool.entries.filter(initialFramingTools::contains).toSet())
        private set

    /** True when any playback image, analysis, framing, or audio assist is visible. */
    val hasAnyVisibleAssist: Boolean
        get() = AssistTool.entries.any(::isOn)

    /** Playback-context activation used by the toolbar and accessibility state. */
    fun isOn(tool: AssistTool): Boolean =
        if (tool in AssistTool.framingTools) tool in framingTools else assists.isOn(tool)

    /** Toggles one playback-context tool without mutating live-monitor visibility. */
    fun toggle(tool: AssistTool): Boolean {
        if (tool !in AssistTool.framingTools) return assists.toggle(tool)
        val next = framingTools.toMutableSet()
        if (!next.add(tool)) next.remove(tool)
        framingTools = AssistTool.entries.filter(next::contains).toSet()
        persistFramingTools(framingTools)
        return true
    }

    /**
     * Applies playback visibility to the operator's shared framing values.
     * Ratio, mask, grid style, and de-squeeze factor remain shared settings;
     * only whether each aid is visible differs by context.
     */
    fun framingConfiguration(
        configured: LocalFramingAssistConfiguration,
    ): LocalFramingAssistConfiguration =
        configured.copy(
            guidesVisible = AssistTool.GUIDES in framingTools,
            gridVisible = AssistTool.GRID in framingTools,
            centerCrosshairEnabled = AssistTool.CROSS in framingTools,
            desqueezeEnabled = AssistTool.DESQ in framingTools,
        )

    companion object {
        private const val PREFERENCES = "playbackAssists"
        private const val FRAMING_TOOLS_KEY = "framingTools.v1"

        /** Restores app-private playback visibility and validates any stored LUT selection. */
        fun restore(
            context: Context,
            sharedConfiguration: AssistState? = null,
            availableStoredLut: (StoredLutSelection) -> Boolean = { true },
        ): PlaybackAssistState =
            restore(
                context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE),
                sharedConfiguration,
                availableStoredLut,
            )

        /** SharedPreferences overload used by deterministic JVM persistence tests. */
        internal fun restore(
            preferences: SharedPreferences,
            sharedConfiguration: AssistState? = null,
            availableStoredLut: (StoredLutSelection) -> Boolean = { true },
        ): PlaybackAssistState {
            val liveMirrorBeforeRestore = FeedEffectsState.current
            val effects =
                AssistState.restore(
                    preferences = preferences,
                    intentEffects = null,
                    intentScope = null,
                    availableStoredLut = availableStoredLut,
                    mirrorFeedEffectsState = false,
                )
            sharedConfiguration?.let { configuration ->
                effects.applySharedSelections(
                    configuration.selectedLut,
                    configuration.selectedFalseColorScale,
                )
            }
            check(FeedEffectsState.current == liveMirrorBeforeRestore) {
                "playback restore must not replace live effect state"
            }
            val framing =
                preferences.getStringSet(FRAMING_TOOLS_KEY, emptySet()).orEmpty()
                    .mapNotNull(AssistTool::fromStoredName)
                    .filterTo(linkedSetOf()) { it in AssistTool.framingTools }
            return PlaybackAssistState(
                assists = effects,
                initialFramingTools = framing,
                persistFramingTools = { selected ->
                    preferences.edit()
                        .putStringSet(FRAMING_TOOLS_KEY, selected.mapTo(linkedSetOf()) { it.name })
                        .apply()
                },
            )
        }
    }
}

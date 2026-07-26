package com.opencapture.openzcine

import com.opencapture.openzcine.core.CameraRecordingState
import com.opencapture.openzcine.core.LiveFrameSource
import com.opencapture.openzcine.settings.LocalFramingAssistConfiguration
import com.opencapture.openzcine.settings.MonitorDisplayMode

/**
 * Returns the monitor-owned live source only while a preview-bearing monitor
 * mode is visible. Command mode deliberately has no *preview* consumers, so
 * decode, scopes, audio and the wearable relay all stop there.
 *
 * This is not the whole story for command mode any more: the timecode readout
 * keeps the raw source (see `monitorTimecodeFrameSource`), because timecode
 * only exists in the live-view frame header.
 */
internal fun monitorPreviewFrameSource(
    source: LiveFrameSource?,
    isCommandMode: Boolean,
): LiveFrameSource? = source?.takeIf { !isCommandMode }

/**
 * The source the live-timecode readout observes.
 *
 * Command mode (DISP 3) hides the image but its hero readout *is* the timecode,
 * and timecode rides the live-view frame header only — there is no PTP timecode
 * property. Ending live view there froze the clock at whatever the last
 * pre-command frame carried, which reads as plausible and is actively wrong
 * while the camera rolls (#271). So the timecode collector deliberately keeps
 * the raw source in every DISP mode; everything else still drops out through
 * [monitorPreviewFrameSource].
 */
internal fun monitorTimecodeFrameSource(source: LiveFrameSource?): LiveFrameSource? = source

/**
 * Whether non-critical monitor chrome — the status deck, side rails, system
 * band and quick affordances — renders in [mode]. Mirrors the shared core's
 * `MonitorChromePolicy.showsChrome(in:)`: clean view (DISP 2) strips all of it.
 */
internal fun monitorShowsChrome(mode: MonitorDisplayMode): Boolean =
    mode != MonitorDisplayMode.CLEAN

/**
 * Whether a transient pop-up (camera-value picker, assist options drawer) may
 * present in [mode]. Mirrors `MonitorChromePolicy.allowsPopups(in:)`.
 */
internal fun monitorAllowsPopups(mode: MonitorDisplayMode): Boolean =
    mode != MonitorDisplayMode.CLEAN

/**
 * Whether [tool] renders right now, given the DISP [mode] and the operator's
 * clean-view pins. Mirrors `MonitorChromePolicy.isToolVisible`: live shows
 * everything switched on, clean shows only pinned tools, command shows none
 * (its dashboard replaces the feed entirely). Callers still apply the tool's
 * own on/off state — this only filters by mode.
 */
internal fun assistToolRendersInMode(
    tool: AssistTool,
    mode: MonitorDisplayMode,
    pinnedToCleanView: Set<AssistTool>,
): Boolean =
    when (mode) {
        MonitorDisplayMode.LIVE -> true
        MonitorDisplayMode.CLEAN -> tool in pinnedToCleanView
        MonitorDisplayMode.COMMAND -> false
    }

/** The [AssistTool] whose pin governs this scope panel. */
internal val ScopeKind.assistTool: AssistTool
    get() =
        when (this) {
            ScopeKind.WAVEFORM -> AssistTool.WAVE
            ScopeKind.PARADE -> AssistTool.PARADE
            ScopeKind.HISTOGRAM -> AssistTool.HISTO
            ScopeKind.VECTORSCOPE -> AssistTool.VECTOR
            ScopeKind.TRAFFIC_LIGHTS -> AssistTool.LIGHTS
        }

/** The scope panels [mode] lets through. */
internal fun renderedScopes(
    selected: Set<ScopeKind>,
    mode: MonitorDisplayMode,
    pinnedToCleanView: Set<AssistTool>,
): Set<ScopeKind> =
    selected.filterTo(mutableSetOf()) {
        assistToolRendersInMode(it.assistTool, mode, pinnedToCleanView)
    }

/** The feed effects the GPU chain should bake — clean bakes only pinned looks. */
internal fun renderedFeedEffects(
    effects: FeedEffects,
    mode: MonitorDisplayMode,
    pinnedToCleanView: Set<AssistTool>,
): FeedEffects {
    fun keeps(tool: AssistTool) = assistToolRendersInMode(tool, mode, pinnedToCleanView)
    if (keeps(AssistTool.LUT) && keeps(AssistTool.FALSE) && keeps(AssistTool.PEAK) &&
        keeps(AssistTool.ZEBRA)
    ) {
        return effects
    }
    return FeedEffects(
        lut = effects.lut?.takeIf { keeps(AssistTool.LUT) },
        falseColor = effects.falseColor?.takeIf { keeps(AssistTool.FALSE) },
        peaking = effects.peaking && keeps(AssistTool.PEAK),
        zebra = effects.zebra && keeps(AssistTool.ZEBRA),
    )
}

/** The framing aids the feed overlays should draw — clean draws only pinned ones. */
internal fun renderedFramingAssists(
    configuration: LocalFramingAssistConfiguration,
    mode: MonitorDisplayMode,
    pinnedToCleanView: Set<AssistTool>,
): LocalFramingAssistConfiguration {
    if (mode == MonitorDisplayMode.LIVE) return configuration
    fun keeps(tool: AssistTool) = assistToolRendersInMode(tool, mode, pinnedToCleanView)
    return configuration.copy(
        guidesVisible = configuration.guidesVisible && keeps(AssistTool.GUIDES),
        gridVisible = configuration.gridVisible && keeps(AssistTool.GRID),
        centerCrosshairEnabled =
            configuration.centerCrosshairEnabled && keeps(AssistTool.CROSS),
        levelEnabled = configuration.levelEnabled && keeps(AssistTool.LEVEL),
        evMeterEnabled = configuration.evMeterEnabled && keeps(AssistTool.EV),
        desqueezeEnabled = configuration.desqueezeEnabled && keeps(AssistTool.DESQ),
    )
}

/**
 * Recording inputs for preview policy use confirmed camera state. A start is
 * not confirmed until the facade reports [CameraRecordingState.RECORDING],
 * while a stop keeps the active-take preview constraints until it succeeds.
 */
internal fun previewPolicyRecordingActive(state: CameraRecordingState): Boolean =
    state == CameraRecordingState.RECORDING || state == CameraRecordingState.STOPPING

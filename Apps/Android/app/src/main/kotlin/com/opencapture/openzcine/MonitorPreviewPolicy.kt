package com.opencapture.openzcine

import com.opencapture.openzcine.core.CameraRecordingState
import com.opencapture.openzcine.core.LiveFrameSource
import com.opencapture.openzcine.settings.LocalFramingAssistConfiguration
import com.opencapture.openzcine.settings.ChromeSection
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
 * Whether [mode] renders the *full* chrome layer — the auxiliary rail keys (Settings, Media) and
 * the opaque system band behind them. Mirrors the shared core's
 * `MonitorChromePolicy.showsChrome(in:)`.
 *
 * Per-element visibility is no longer this call's business: each DISP mode owns its own
 * `OperatorSettings.chrome(mode)`, and clean simply ships with everything off. What survives here
 * is the one rule configuration cannot express — clean's rail collapses to its two essentials (the
 * DISP key, and the record control while a take is rolling) so there is always a way out.
 */
internal fun monitorShowsChrome(mode: MonitorDisplayMode): Boolean =
    mode != MonitorDisplayMode.CLEAN

/**
 * Whether the rail's lock key renders. Mirrors
 * `MonitorChromePolicy.showsLockControl(mode:preferences:interfaceLocked:)`.
 *
 * The operator may hide it (Operator Setup ▸ Display ▸ Monitor Chrome), but a **locked** monitor
 * shows it regardless: the lock key is the only control that clears the lock, so honouring the
 * hide while locked would strand the operator behind dead camera controls. Clean strips the key
 * either way — this is not a fourth clean-view exception.
 */
internal fun monitorShowsLockControl(
    mode: MonitorDisplayMode,
    lockButtonVisible: Boolean,
    interfaceLocked: Boolean,
): Boolean = monitorShowsChrome(mode) && (lockButtonVisible || interfaceLocked)

/**
 * Whether the battery indicators render. Mirrors
 * `MonitorChromePolicy.showsBatteryIndicators(mode:preferences:)` — pure chrome, configured per
 * DISP mode, so the caller passes that mode's own flag (clean ships with it off).
 */
internal fun monitorShowsBatteryIndicators(
    @Suppress("UNUSED_PARAMETER") mode: MonitorDisplayMode,
    batteryIndicatorsVisible: Boolean,
): Boolean = batteryIndicatorsVisible

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

/** One element the Edit view can badge, at its real drawn bounds in pixels. */
internal data class ChromeEditBox(
    val section: ChromeSection,
    val left: Float,
    val top: Float,
    val width: Float,
    val height: Float,
)

/** A placed eye badge: the top-left of its [ChromeEditLayout.BADGE_SIZE_DP] square. */
internal data class ChromeEditBadgePlacement(val left: Float, val top: Float)

/**
 * Where the Edit view puts each element's eye badge. Mirrors the shared core's
 * `MonitorChromeEditLayout` (`Sources/OpenZCineCore/AssistToolActivation.swift`) exactly, so both
 * shells place badges the same way.
 *
 * A fixed corner per element does not work: the monitor's elements sit edge to edge and some nest
 * inside others (the four readouts live in the status bar), so constants put badges on top of one
 * another and some of them out of reach. This picks, per element, the first corner of its measured
 * box that is clear of every badge already placed, clamping each candidate on screen first so an
 * element flush against an edge still gets a reachable badge.
 */
internal object ChromeEditLayout {
    /** Diameter of the badge itself, in the same unit as the boxes. */
    const val BADGE_SIZE_DP: Float = 26f

    /** Breathing room between two badges, and between a badge and the viewport edge. */
    const val BADGE_GAP_DP: Float = 3f

    /**
     * Badge frames keyed by section, in the same coordinate space as [boxes].
     *
     * [boxes] order is the placement priority: earlier elements get their preferred corner, later
     * ones move to the next free one. Unmeasured (zero-sized) boxes are skipped.
     */
    fun badgeFrames(
        boxes: List<ChromeEditBox>,
        viewportWidth: Float,
        viewportHeight: Float,
        badgeSize: Float = BADGE_SIZE_DP,
    ): Map<ChromeSection, ChromeEditBadgePlacement> {
        val placed = mutableListOf<ChromeEditBadgePlacement>()
        val result = LinkedHashMap<ChromeSection, ChromeEditBadgePlacement>()

        for (box in boxes) {
            if (box.width <= 1f || box.height <= 1f) continue
            val candidates =
                corners(box, badgeSize).map {
                    clamp(it, viewportWidth, viewportHeight, badgeSize)
                }
            val choice =
                candidates.firstOrNull { candidate ->
                    placed.none { overlaps(it, candidate, badgeSize) }
                } ?: candidates.first()
            placed += choice
            result[box.section] = choice
        }
        return result
    }

    /**
     * The four corner positions, centred on the corner so the badge straddles the element's edge:
     * top-trailing first (least likely to sit over content), then top-leading, bottom-trailing,
     * bottom-leading.
     */
    private fun corners(box: ChromeEditBox, badgeSize: Float): List<ChromeEditBadgePlacement> {
        val half = badgeSize / 2f
        return listOf(
            ChromeEditBadgePlacement(box.left + box.width - half, box.top - half),
            ChromeEditBadgePlacement(box.left - half, box.top - half),
            ChromeEditBadgePlacement(box.left + box.width - half, box.top + box.height - half),
            ChromeEditBadgePlacement(box.left - half, box.top + box.height - half),
        )
    }

    private fun clamp(
        placement: ChromeEditBadgePlacement,
        viewportWidth: Float,
        viewportHeight: Float,
        badgeSize: Float,
    ): ChromeEditBadgePlacement {
        val maxX = maxOf(BADGE_GAP_DP, viewportWidth - badgeSize - BADGE_GAP_DP)
        val maxY = maxOf(BADGE_GAP_DP, viewportHeight - badgeSize - BADGE_GAP_DP)
        return ChromeEditBadgePlacement(
            left = minOf(maxOf(placement.left, BADGE_GAP_DP), maxX),
            top = minOf(maxOf(placement.top, BADGE_GAP_DP), maxY),
        )
    }

    private fun overlaps(
        a: ChromeEditBadgePlacement,
        b: ChromeEditBadgePlacement,
        badgeSize: Float,
    ): Boolean =
        a.left < b.left + badgeSize + BADGE_GAP_DP &&
            b.left < a.left + badgeSize + BADGE_GAP_DP &&
            a.top < b.top + badgeSize + BADGE_GAP_DP &&
            b.top < a.top + badgeSize + BADGE_GAP_DP
}

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
        // Carried through untouched: `activeSplitComparison` already follows the LUT, so dropping
        // the look above drops the split, the divider and the labels with it.
        splitComparison = effects.splitComparison,
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

/**
 * Whether the on-feed focus dial can drive the lens in the body's current focus mode.
 *
 * Kotlin mirror of `MFDriveEligibility` in the shared core — the rule lives there; this only
 * transcribes it, the way the rest of this file mirrors core monitor policy.
 */
internal enum class MfDriveEligibility {
    /** No dial: no focus mode read yet, or MF, where the lens ring owns focus. */
    UNAVAILABLE,

    /** Dial mounted but inert and dimmed: AF-F re-focuses continuously, overriding any drive. */
    BLOCKED_BY_CONTINUOUS_AF,

    /** AF-S and AF-C hold focus between acquisitions, so a pull sticks. */
    DRIVABLE,
}

/**
 * Resolves dial eligibility from the body's reported focus mode.
 *
 * Refusals are not a factor: `Device_Busy` (STM lens initialising) and `Access_Denied` (AF
 * settling) are always transient, so nothing about a refusal makes a lens undrivable.
 */
internal fun mfDriveEligibility(focusMode: String?): MfDriveEligibility =
    when (focusMode) {
        null, "MF" -> MfDriveEligibility.UNAVAILABLE
        "AF-F" -> MfDriveEligibility.BLOCKED_BY_CONTINUOUS_AF
        else -> MfDriveEligibility.DRIVABLE
    }

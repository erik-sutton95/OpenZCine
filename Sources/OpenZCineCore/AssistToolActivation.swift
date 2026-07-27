import Foundation

/// The one authoritative rule for what the monitor puts on screen in each DISP mode. Both shells
/// ask this instead of testing `displayMode == .clean` at each render site — scattered tests are
/// exactly how scopes, traffic lights and pop-ups survived clean view (#256).
///
/// Each mode owns its own ``DisplayChromeVisibility`` (``OperatorPreferences/chrome(for:)``), so
/// what a mode shows is configuration, not a hard-coded per-mode branch. The stock configurations:
///
/// - `.live` (DISP 1): everything the operator switched on.
/// - `.clean` (DISP 2): **a bare image**. Every view-assist tool, the status deck, the bottom
///   strips and every non-critical pop-up start hidden. A tool comes back only when the operator
///   lists it in ``OperatorPreferences/cleanViewPinnedTools`` — off for all 17 by default. Leaving
///   clean restores the prior visibility exactly, because the list is a *filter*: clean never
///   mutates the operator's on/off set.
/// - `.command` (DISP 3): the data dashboard owns the screen; there is no feed, so no feed overlay
///   or scope renders regardless of pins.
///
/// **Documented critical exceptions.** These are deliberately *not* routed through this policy and
/// stay visible in clean view, because suppressing them risks a ruined or lost take:
/// camera fault and thermal/card warnings (`CameraWarningStatus`), the recording tally, connection
/// loss / reconnect notices, modal alerts that require an immediate answer (record confirmation),
/// and — while a take is rolling or a record command is awaiting confirmation — the record control
/// itself. Clean view must never remove the way to STOP a take. Analysis chrome — scopes, traffic
/// lights, histograms, meters — is never critical.
///
/// Clean also keeps the **DISP key** itself: it is the control for this feature, and the rest of
/// the cycle is only reachable through it, so hiding it would strand the operator in clean. Both
/// shells therefore render exactly two rail controls in clean — DISP always, record while rolling
/// — and strip the batteries, lock, Settings, Media, status deck and every bar. The feed swipe
/// (down → clean, up → live) remains a second way out.
public enum MonitorChromePolicy {
    /// Whether `tool` renders right now: switched on for `context`, and permitted by `mode`.
    public static func isToolVisible(
        _ tool: MonitorAssistTool,
        mode: DispMode,
        context: ViewAssistContext = .liveView,
        preferences: OperatorPreferences
    ) -> Bool {
        guard preferences.visibleAssistTools(for: context).contains(tool) else { return false }
        switch mode {
        case .live: return true
        case .clean: return preferences.cleanViewPinnedTools.contains(tool)
        case .command: return false
        }
    }

    /// The switched-on tools `mode` actually lets through — the set every render site should read.
    public static func visibleTools(
        mode: DispMode,
        context: ViewAssistContext = .liveView,
        preferences: OperatorPreferences
    ) -> Set<MonitorAssistTool> {
        let on = preferences.visibleAssistTools(for: context)
        switch mode {
        case .live: return on
        case .clean: return on.intersection(preferences.cleanViewPinnedTools)
        case .command: return []
        }
    }

    /// Whether `mode` renders the *full* chrome layer — the auxiliary rail keys (Settings, Media)
    /// and the opaque system band behind them.
    ///
    /// Per-element visibility is no longer this call's business: each DISP mode owns its own
    /// ``DisplayChromeVisibility`` (``OperatorPreferences/chrome(for:)``), and clean simply ships
    /// with everything off. What survives here is the one rule configuration cannot express —
    /// clean's rail collapses to its two essentials (the DISP key, and the record control while a
    /// take is rolling) so the operator always has a way out of the bare image.
    public static func showsChrome(in mode: DispMode) -> Bool { mode != .clean }

    /// Whether `section` renders in `mode` right now. The one read every chrome mount site should
    /// use, so a mode's configuration cannot drift between shells or orientations.
    public static func showsSection(
        _ section: DisplayChromeVisibility.Section,
        mode: DispMode,
        preferences: OperatorPreferences
    ) -> Bool {
        preferences.chrome(for: mode).isVisible(section)
    }

    /// Whether the rail's lock key renders.
    ///
    /// The operator may hide it (Settings ▸ Display ▸ Monitor Chrome), but a **locked** monitor
    /// shows it regardless: on both shells the lock key is the only control that clears the lock,
    /// so honouring the hide while locked would strand the operator behind dead camera controls.
    /// This is not a fourth clean-view exception — clean hides the key either way, and clean
    /// never locks anything.
    public static func showsLockControl(
        mode: DispMode,
        preferences: OperatorPreferences,
        interfaceLocked: Bool
    ) -> Bool {
        guard showsChrome(in: mode) else { return false }
        return preferences.chrome(for: mode).lockButtonVisible || interfaceLocked
    }

    /// Whether the battery cluster renders. Pure chrome, configured per DISP mode — clean ships
    /// with it off, and the operator may hide it in any other mode.
    public static func showsBatteryIndicators(
        mode: DispMode,
        preferences: OperatorPreferences
    ) -> Bool {
        preferences.chrome(for: mode).batteryIndicatorsVisible
    }

    /// What the side rail still mounts for one chrome/recording state.
    public struct SideRailPlan: Equatable, Sendable {
        /// The whole rail — batteries, lock, DISP, record, Media, Settings.
        public let fullRail: Bool
        /// A lone Settings key, mounted only when the rail is hidden.
        public let settingsRecovery: Bool
        /// A lone record control, mounted only when the rail is hidden mid-take.
        public let recordSafety: Bool
    }

    /// Resolves the side rail for `mode`.
    ///
    /// Hiding the rail (Settings ▸ Display ▸ Monitor Chrome) must never remove the route back to
    /// Settings — that is the only place the rail can be switched on again, so without it the
    /// operator is stranded — nor the way to STOP a rolling take. Clean is separate: it keeps the
    /// DISP key and the rolling record control instead, because the feed swipe and DISP are its
    /// documented ways out.
    public static func sideRailPlan(
        mode: DispMode,
        preferences: OperatorPreferences,
        recordingOrPending: Bool
    ) -> SideRailPlan {
        let visible = preferences.chrome(for: mode).sideRailsVisible
        return SideRailPlan(
            fullRail: visible,
            // Clean already strips the rail by design and offers DISP as its way out; a second
            // recovery key there would just put chrome back on the bare image.
            settingsRecovery: !visible && showsChrome(in: mode),
            recordSafety: !visible && recordingOrPending)
    }

    /// Whether a transient pop-up (camera-value picker, assist options drawer) may present.
    /// Clean defers them — the operator asked for a bare image. Full-screen destinations the
    /// operator navigates to deliberately (Settings, Media) are not pop-ups and are unaffected.
    public static func allowsPopups(in mode: DispMode) -> Bool { mode != .clean }

    /// Whether `mode` shows no image but still shows live camera telemetry, so the live-view
    /// stream must stay up purely as a carrier for its frame header.
    ///
    /// Timecode and record state exist ONLY in the live-view frame header — there is no PTP
    /// timecode property — so a mode that hides the image and ends live view freezes both. That
    /// is exactly what Command (DISP 3) did to its own hero timecode readout (#271). A shell in
    /// this state keeps the stream at the smallest frame the body offers and skips decode,
    /// display, the wearable relay and scope sampling.
    public static func streamsHeaderOnly(in mode: DispMode) -> Bool { mode == .command }
}

/// Pure on/off semantics for the live-monitor and playback view-assist tools.
public enum AssistToolActivation {
    public static func set(
        _ tool: MonitorAssistTool,
        visible: Bool,
        context: ViewAssistContext,
        preferences: inout OperatorPreferences,
        configuration: inout AssistConfiguration
    ) {
        switch context {
        case .liveView:
            if visible {
                preferences.liveViewVisibleAssistTools.insert(tool)
            } else {
                preferences.liveViewVisibleAssistTools.remove(tool)
            }
            if MonitorAssistTool.scopeTools.contains(tool) {
                preferences.scopeActivationOrder.removeAll { $0 == tool }
                if visible {
                    preferences.scopeActivationOrder.append(tool)
                }
            }
        case .playback:
            if visible {
                preferences.playbackVisibleAssistTools.insert(tool)
            } else {
                preferences.playbackVisibleAssistTools.remove(tool)
            }
        }
        syncOverlayEnabledFlags(preferences: preferences, configuration: &configuration)
    }

    public static func set(
        _ tool: MonitorAssistTool,
        visible: Bool,
        preferences: inout OperatorPreferences,
        configuration: inout AssistConfiguration
    ) {
        set(
            tool, visible: visible, context: .liveView, preferences: &preferences,
            configuration: &configuration)
    }

    public static func toggle(
        _ tool: MonitorAssistTool,
        context: ViewAssistContext,
        preferences: inout OperatorPreferences,
        configuration: inout AssistConfiguration
    ) {
        let isOn = preferences.visibleAssistTools(for: context).contains(tool)
        set(
            tool, visible: !isOn, context: context, preferences: &preferences,
            configuration: &configuration)
    }

    public static func toggle(
        _ tool: MonitorAssistTool,
        preferences: inout OperatorPreferences,
        configuration: inout AssistConfiguration
    ) {
        toggle(tool, context: .liveView, preferences: &preferences, configuration: &configuration)
    }

    private static func syncOverlayEnabledFlags(
        preferences: OperatorPreferences,
        configuration: inout AssistConfiguration
    ) {
        configuration.level.enabled =
            preferences.liveViewVisibleAssistTools.contains(.level)
            || preferences.playbackVisibleAssistTools.contains(.level)
        configuration.desqueeze.enabled =
            preferences.liveViewVisibleAssistTools.contains(.desqueeze)
            || preferences.playbackVisibleAssistTools.contains(.desqueeze)
    }
}

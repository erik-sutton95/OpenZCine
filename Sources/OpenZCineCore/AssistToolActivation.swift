import Foundation

/// The one authoritative rule for what the monitor puts on screen in each DISP mode. Both shells
/// ask this instead of testing `displayMode == .clean` at each render site — scattered tests are
/// exactly how scopes, traffic lights and pop-ups survived clean view (#256).
///
/// - `.live` (DISP 1): everything the operator switched on.
/// - `.clean` (DISP 2): **a bare image**. Every view-assist tool, the status deck, the side rails,
///   the bottom strips and every non-critical pop-up are hidden. A tool comes back only when the
///   operator pins it via ``OperatorPreferences/cleanViewPinnedTools`` — that pin is per tool and
///   off for all 17 by default. Leaving clean restores the prior visibility exactly, because the
///   pin is a *filter*: clean never mutates the operator's on/off set.
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

    /// Whether non-critical monitor chrome — status deck, side rails, assist/capture strips,
    /// status readouts — renders. Clean strips all of it; command replaces it with the dashboard.
    public static func showsChrome(in mode: DispMode) -> Bool { mode != .clean }

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

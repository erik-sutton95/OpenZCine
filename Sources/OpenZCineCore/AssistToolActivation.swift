import Foundation

/// The one authoritative rule for what the monitor puts on screen in each DISP mode. Both shells
/// ask this instead of testing `displayMode == .clean` at each render site — scattered tests are
/// exactly how scopes, traffic lights and pop-ups survived clean view (#256).
///
/// Each mode owns its own ``DisplayChromeVisibility`` (``OperatorPreferences/chrome(for:)``), so
/// what a mode shows is configuration, not a hard-coded per-mode branch. The stock configurations:
///
/// - `.live` (DISP 1): everything the operator switched on.
/// - `.clean` (DISP 2): **the image, the rail and the focus box**. Clean offers exactly the same
///   element list as live — it is DISP 1 with different defaults, not a smaller feature — but the
///   status deck, both bottom strips and the lock key start hidden. Every view-assist tool starts
///   hidden too, and comes back only when the operator lists it in
///   ``OperatorPreferences/cleanViewPinnedTools`` — off for all 17 by default. Leaving clean
///   restores the prior visibility exactly, because the list is a *filter*: clean never mutates
///   the operator's on/off set.
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
/// **No mode can be locked from the inside.** Every rail control is now the operator's to hide,
/// so two of them carry guarantees instead (see ``sideRailPlan(mode:preferences:capture:interfaceLocked:recordingOrPending:)``):
/// the record control returns while a take is rolling, and the Settings key returns when no
/// enabled DISP mode still carries one. The DISP key needs no guarantee because the feed swipe
/// (down → clean, up → live) changes mode without it. The lock key returns while the interface is
/// locked, because it is the only control that clears the lock.
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

    /// Whether `section` renders in `mode` right now. The one read every chrome mount site should
    /// use, so a mode's configuration cannot drift between shells or orientations.
    public static func showsSection(
        _ section: DisplayChromeVisibility.Section,
        mode: DispMode,
        capture: CaptureLayoutMode,
        preferences: OperatorPreferences
    ) -> Bool {
        preferences.chrome(for: mode, capture: capture).isVisible(section)
    }

    /// Whether the rail's lock key renders.
    ///
    /// The operator may hide it in any mode (Settings ▸ Display), but a **locked** monitor shows
    /// it regardless: on both shells the lock key is the only control that clears the lock, so
    /// honouring the hide while locked would strand the operator behind dead camera controls. The
    /// guarantee is unconditional — clean can now carry the key and can therefore lock, so the
    /// old "clean never locks anything" escape clause no longer holds.
    public static func showsLockControl(
        mode: DispMode,
        preferences: OperatorPreferences,
        capture: CaptureLayoutMode,
        interfaceLocked: Bool
    ) -> Bool {
        preferences.chrome(for: mode, capture: capture).lockButtonVisible || interfaceLocked
    }

    /// Whether the battery cluster renders. Pure chrome, configured per DISP mode.
    public static func showsBatteryIndicators(
        mode: DispMode,
        capture: CaptureLayoutMode,
        preferences: OperatorPreferences
    ) -> Bool {
        preferences.chrome(for: mode, capture: capture).batteryIndicatorsVisible
    }

    /// Which side-rail controls mount for one chrome / lock / recording state.
    ///
    /// One boolean per control, because the rail is six independent elements and used to be one
    /// switch — which is exactly why record, Media, Settings and DISP had no visibility controls
    /// of their own.
    public struct SideRailPlan: Equatable, Sendable {
        public let lock: Bool
        public let batteries: Bool
        public let disp: Bool
        public let record: Bool
        public let media: Bool
        public let settings: Bool

        /// Whether the rail mounts anything at all — the portrait system band draws only then.
        public var isEmpty: Bool {
            !(lock || batteries || disp || record || media || settings)
        }
    }

    /// Resolves the side rail for `mode`.
    ///
    /// Two of the six are guaranteed, because hiding them would leave the operator with no way
    /// out of their own configuration:
    ///
    /// - **Record** stays while a take is rolling or a record command is in flight. Nothing may
    ///   remove the way to STOP a take.
    /// - **Settings** stays when no enabled DISP mode carries one, because Settings is the only
    ///   place these switches live. Hidden in *some* modes it really is hidden — the operator
    ///   reaches Settings by cycling DISP (or the feed swipe) to a mode that keeps it.
    ///
    /// The DISP key itself carries no such guarantee: the feed swipe (down → clean, up → live) is
    /// a second, always-present way to change mode, and Settings ▸ Display switches it back on.
    /// The lock key's own guarantee lives in ``showsLockControl(mode:preferences:capture:interfaceLocked:)``.
    public static func sideRailPlan(
        mode: DispMode,
        preferences: OperatorPreferences,
        capture: CaptureLayoutMode,
        interfaceLocked: Bool,
        recordingOrPending: Bool
    ) -> SideRailPlan {
        let chrome = preferences.chrome(for: mode, capture: capture)
        let settingsReachable = preferences.enabledDispModes.contains {
            preferences.chrome(for: $0, capture: capture).railSettingsVisible
        }
        return SideRailPlan(
            lock: showsLockControl(
                mode: mode, preferences: preferences, capture: capture,
                interfaceLocked: interfaceLocked),
            batteries: chrome.batteryIndicatorsVisible,
            disp: chrome.railDispVisible,
            record: chrome.railRecordVisible || recordingOrPending,
            media: chrome.railMediaVisible,
            settings: chrome.railSettingsVisible || !settingsReachable)
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

/// Where the Edit view puts each element's eye badge.
///
/// A fixed corner per element does not work: the monitor's elements sit edge to edge and some nest
/// inside others (the four readouts live in the status bar), so constants put badges on top of one
/// another and some of them out of reach. This picks, per element, the first corner of its
/// **measured** box that is fully on screen and clear of every badge already placed, and clamps a
/// last-resort choice on screen rather than dropping a badge.
///
/// Pure geometry, so both shells place badges identically and the rule is unit-testable.
public enum MonitorChromeEditLayout {
    /// Diameter of the badge itself. Each shell grows the tap target around it separately.
    public static let badgeSize: Double = 26
    /// Breathing room kept between two badges, and between a badge and the viewport edge.
    public static let badgeGap: Double = 3

    /// One element the operator can badge, at its real drawn bounds.
    public struct Box: Equatable, Sendable {
        public let section: DisplayChromeVisibility.Section
        public let frame: MonitorModuleFrame

        public init(section: DisplayChromeVisibility.Section, frame: MonitorModuleFrame) {
            self.section = section
            self.frame = frame
        }
    }

    /// Badge frames keyed by section, in the same coordinate space as `boxes`.
    ///
    /// `boxes` order is the placement priority: earlier elements get their preferred corner, later
    /// ones move to the next free one. Unmeasured (zero-sized) boxes are skipped — there is
    /// nowhere to put their badge yet.
    public static func badgeFrames(
        _ boxes: [Box],
        viewportWidth: Double,
        viewportHeight: Double,
        badgeSize: Double = badgeSize
    ) -> [DisplayChromeVisibility.Section: MonitorModuleFrame] {
        var placed: [MonitorModuleFrame] = []
        var result: [DisplayChromeVisibility.Section: MonitorModuleFrame] = [:]

        for box in boxes where box.frame.width > 1 && box.frame.height > 1 {
            // Clamp first, then test: an element flush against a screen edge has no corner that
            // fits outright, and rejecting all four would send its badge to the fallback in the
            // middle of the screen. Nudged along the edge it still reads as that corner's badge.
            let candidates = corners(of: box.frame, badgeSize: badgeSize).map {
                clamped($0, viewportWidth: viewportWidth, viewportHeight: viewportHeight)
            }
            let choice =
                candidates.first { candidate in
                    !placed.contains { overlaps($0, candidate) }
                } ?? candidates[0]
            placed.append(choice)
            result[box.section] = choice
        }
        return result
    }

    /// The four corner positions, centred on the corner so the badge straddles the element's edge:
    /// top-trailing first (least likely to sit over content), then top-leading, bottom-trailing,
    /// bottom-leading.
    private static func corners(of frame: MonitorModuleFrame, badgeSize: Double)
        -> [MonitorModuleFrame]
    {
        let half = badgeSize / 2
        let centres = [
            (frame.x + frame.width, frame.y),
            (frame.x, frame.y),
            (frame.x + frame.width, frame.y + frame.height),
            (frame.x, frame.y + frame.height),
        ]
        return centres.map {
            MonitorModuleFrame(x: $0.0 - half, y: $0.1 - half, width: badgeSize, height: badgeSize)
        }
    }

    private static func overlaps(_ a: MonitorModuleFrame, _ b: MonitorModuleFrame) -> Bool {
        a.x < b.x + b.width + badgeGap && b.x < a.x + a.width + badgeGap
            && a.y < b.y + b.height + badgeGap && b.y < a.y + a.height + badgeGap
    }

    private static func clamped(
        _ frame: MonitorModuleFrame, viewportWidth: Double, viewportHeight: Double
    ) -> MonitorModuleFrame {
        let maxX = Swift.max(badgeGap, viewportWidth - frame.width - badgeGap)
        let maxY = Swift.max(badgeGap, viewportHeight - frame.height - badgeGap)
        return MonitorModuleFrame(
            x: Swift.min(Swift.max(frame.x, badgeGap), maxX),
            y: Swift.min(Swift.max(frame.y, badgeGap), maxY),
            width: frame.width,
            height: frame.height)
    }
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

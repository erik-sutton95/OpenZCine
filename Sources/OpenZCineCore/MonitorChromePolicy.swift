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
///   hidden too, except the tools the operator pins into clean view on the shared assist state
///   (its `cleanViewPinnedTools`). Leaving clean restores the prior visibility exactly, because the
///   list is a *filter*: clean never mutates the operator's on/off set.
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
/// enabled DISP mode still carries one. The DISP key is not among them: it is never hideable at
/// all, in any mode or configuration, because it is the only visible way to change mode and the
/// feed swipe is not an escape route for an operator who does not already know about it. The lock
/// key returns while the interface is locked, because it is the only control that clears the lock.
public enum MonitorChromePolicy {
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
            // Always on. Not a stored preference the operator can reach — see `isConfigurable`.
            disp: true,
            record: chrome.railRecordVisible || recordingOrPending,
            media: chrome.railMediaVisible,
            settings: chrome.railSettingsVisible || !settingsReachable)
    }

    /// Whether switching INTO `mode` dismisses an in-flight transient pop-up (camera-value
    /// picker, assist options drawer). Entering clean sweeps them — a popup opened in DISP 1 must
    /// not ride into the bare image. This never gates *presentation*: any control the mode's own
    /// configuration mounts (an enabled readout, the REC options key) opens its pop-up normally,
    /// because a visible control that swallows its tap reads as a broken monitor. Full-screen
    /// destinations the operator navigates to deliberately (Settings, Media) are not pop-ups and
    /// are unaffected.
    public static func dismissesPopupsOnEntry(to mode: DispMode) -> Bool { mode == .clean }

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

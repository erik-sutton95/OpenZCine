import MonitorPresentation

/// Adapts the app's persisted display preferences to shared rail visibility.
/// Mode selection and header-only streaming remain host policy.
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
    /// guarantee is unconditional ; clean can now carry the key and can therefore lock, so the
    /// old "clean never locks anything" escape clause no longer holds.
    public static func showsLockControl(
        mode: DispMode,
        preferences: OperatorPreferences,
        capture: CaptureLayoutMode,
        interfaceLocked: Bool
    ) -> Bool {
        MonitorSideRailPlan.showsLock(
            visible: preferences.chrome(for: mode, capture: capture).lockButtonVisible,
            interfaceLocked: interfaceLocked)
    }

    /// Whether the battery cluster renders. Pure chrome, configured per DISP mode.
    public static func showsBatteryIndicators(
        mode: DispMode,
        capture: CaptureLayoutMode,
        preferences: OperatorPreferences
    ) -> Bool {
        preferences.chrome(for: mode, capture: capture).batteryIndicatorsVisible
    }

    public typealias SideRailPlan = MonitorSideRailPlan

    /// Resolves the side rail for `mode`.
    ///
    /// Two of the six are guaranteed, because hiding them would leave the operator with no way
    /// out of their own configuration:
    ///
    /// - **Record** stays while a take is rolling or a record command is in flight. Nothing may
    ///   remove the way to STOP a take.
    /// - **Settings** stays when no enabled DISP mode carries one, because Settings is the only
    ///   place these switches live. Hidden in *some* modes it really is hidden ; the operator
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
            lockVisible: chrome.lockButtonVisible,
            batteriesVisible: chrome.batteryIndicatorsVisible,
            recordVisible: chrome.railRecordVisible,
            mediaVisible: chrome.railMediaVisible,
            settingsVisible: chrome.railSettingsVisible,
            settingsReachable: settingsReachable,
            interfaceLocked: interfaceLocked,
            recordingOrPending: recordingOrPending)
    }

    /// Whether switching INTO `mode` dismisses an in-flight transient pop-up (camera-value
    /// picker, assist options drawer). Entering clean sweeps them ; a popup opened in DISP 1 must
    /// not ride into the bare image. This never gates *presentation*: any control the mode's own
    /// configuration mounts (an enabled readout, the REC options key) opens its pop-up normally,
    /// because a visible control that swallows its tap reads as a broken monitor. Full-screen
    /// destinations the operator navigates to deliberately (Settings, Media) are not pop-ups and
    /// are unaffected.
    public static func dismissesPopupsOnEntry(to mode: DispMode) -> Bool { mode == .clean }

    /// Whether `mode` shows no image but still shows live camera telemetry, so the live-view
    /// stream must stay up purely as a carrier for its frame header.
    ///
    /// Timecode and record state exist ONLY in the live-view frame header ; there is no PTP
    /// timecode property ; so a mode that hides the image and ends live view freezes both. That
    /// is exactly what Command (DISP 3) did to its own hero timecode readout (#271). A shell in
    /// this state keeps the stream at the smallest frame the body offers and skips decode,
    /// display, the wearable relay and scope sampling.
    public static func streamsHeaderOnly(in mode: DispMode) -> Bool { mode == .command }
}

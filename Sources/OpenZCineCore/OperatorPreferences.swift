import Foundation

/// Whether view-assist tool visibility applies to the live monitor or media playback.
public enum ViewAssistContext: String, Codable, Equatable, Sendable {
    case liveView
    case playback
}

/// App-side view-assist tools shown around the monitor.
public enum MonitorAssistTool: String, CaseIterable, Codable, Equatable, Identifiable, Sendable {
    case lut = "LUT"
    case peaking = "PEAK"
    case falseColor = "FALSE"
    case zebra = "ZEBRA"
    case waveform = "WAVE"
    case parade = "PARADE"
    case histogram = "HISTO"
    case vectorscope = "VECTOR"
    case trafficLights = "LIGHTS"
    case audioMeters = "AUDIO"
    case guides = "GUIDES"
    case grid = "GRID"
    case crosshair = "CROSS"
    case level = "LEVEL"
    /// Camera-fed exposure indicator (the body's own metering needle).
    case evMeter = "EV"
    case desqueeze = "DE-SQ"
    /// Flips the monitored picture left-to-right, for a body pointed back at the person watching
    /// it. A display convenience only: the recording is never mirrored, and neither is anything
    /// that measures the frame.
    case mirror = "MIRROR"
    case instantReview = "PLAY"
    /// Monitoring punch-in for critical focus. Retired; see ``isRetired``.
    case magnification = "MAG"

    public var id: String { rawValue }

    /// Retired from every operator-facing surface; the case survives only so stored payloads
    /// decode. Magnification became direct manipulation (pinch the feed) — a toolbar/settings
    /// row for it is a control for a tool that no longer exists.
    public var isRetired: Bool { self == .magnification }

    /// The tool set UI and defaults build from — `allCases` minus retired tools. Decode paths
    /// filter through this too, so a blob persisted before a retirement stops resurfacing it.
    public static var activeCases: [MonitorAssistTool] { allCases.filter { !$0.isRetired } }

    /// Whether long-pressing the toolbar button opens a quick-settings popup. Tap still toggles the
    /// tool on/off. Framing aids and LUT carry richer pickers; analysis tools expose compact
    /// settings (scale, thresholds, scope modes, …) without duplicating the full settings tab.
    public var hasConfiguration: Bool {
        switch self {
        case .lut, .peaking, .falseColor, .zebra, .waveform, .parade, .histogram, .vectorscope,
            .trafficLights,
            .guides, .grid,
            .crosshair, .level, .desqueeze, .mirror, .instantReview, .magnification:
            true
        case .audioMeters, .evMeter:
            // Camera meters carry no operator-tunable options.
            false
        }
    }

    /// Tools that only exist in the photography toolset — the cinema strip never offers them.
    /// The EV meter mirrors the body's stills exposure indicator, so it is a photography tool.
    public var isPhotographyOnly: Bool {
        self == .instantReview || self == .evMeter
    }

    /// Scope-type tools: rendered as panels (floating in landscape/portrait-fill, stacked in
    /// portrait-fit) and subject to the portrait-fit 2-scope display cap.
    public static let scopeTools: [MonitorAssistTool] = [
        .waveform, .parade, .histogram, .vectorscope, .trafficLights,
    ]

    /// Operator-facing label for Display settings strips.
    public var displaySettingsTitle: String {
        switch self {
        case .lut: "LUT"
        case .peaking: "Peaking"
        case .falseColor: "False Color"
        case .zebra: "Zebra"
        case .waveform: "Waveform"
        case .parade: "Parade"
        case .histogram: "Histogram"
        case .vectorscope: "Vectorscope"
        case .trafficLights: "Traffic Lights"
        case .audioMeters: "Audio Levels"
        case .guides: "Guides"
        case .grid: "Grid"
        case .crosshair: "Crosshair"
        case .level: "Horizon"
        case .evMeter: "EV Meter"
        case .desqueeze: "Desqueeze"
        case .mirror: "Mirror"
        case .instantReview: "Instant Playback"
        case .magnification: "Magnification"
        }
    }
}

/// Which capture side of the camera a monitor layout belongs to.
///
/// A cinema operator and a stills shooter want different chrome on the same phone, and the body
/// switches between the two on its own mode dial — so every chrome configuration is keyed by DISP
/// mode **and** this. See ``OperatorPreferences/chrome(for:capture:)``.
public enum CaptureLayoutMode: String, CaseIterable, Codable, Equatable, Sendable, Identifiable {
    case video
    case photo

    public var id: String { rawValue }

    /// Operator-facing label for the Display tab's layout switch.
    public var title: String {
        switch self {
        case .video: "Video"
        case .photo: "Photo"
        }
    }
}

/// Visibility preferences for the live monitor chrome. One of these per DISP mode per capture
/// mode — see ``OperatorPreferences/chrome(for:capture:)``.
public struct DisplayChromeVisibility: Codable, Equatable, Sendable {
    public enum Section: String, CaseIterable, Codable, Equatable, Sendable, Identifiable {
        case statusBar
        /// **Legacy.** The whole right rail used to be one switch, which is why record, Media,
        /// Settings and DISP had no controls of their own. They are now `railRecord`, `railMedia`,
        /// `railSettings` and `railDisp`; this case survives only as the migration source for
        /// those four (see the decoder) and is configurable in no mode.
        case sideRails
        case assistToolbar
        case cameraValues
        case lockButton
        case batteryIndicators
        // The four status-bar readouts. Appended after the original six so a stored raw value
        // never shifts meaning.
        case recReadout
        case codecReadout
        case mediaReadout
        case fpsReadout
        // Third pass — appended, never inserted. The remaining two status-bar cells, the four rail
        // controls the `sideRails` blob used to swallow, and the AF box.
        case timecodeReadout
        case resolutionReadout
        case railRecord
        case railMedia
        case railSettings
        case railDisp
        case focusBox

        public var id: String { rawValue }

        /// Operator-facing label. Lives here so both shells and the Edit-view badges name the
        /// same element the same way.
        public var title: String {
            switch self {
            case .statusBar: "Status Bar"
            case .sideRails: "Side Rail"
            case .assistToolbar: "Tool Bar"
            case .cameraValues: "Camera Values"
            case .lockButton: "Lock Button"
            case .batteryIndicators: "Batteries"
            case .recReadout: "REC"
            case .codecReadout: "CODEC"
            case .mediaReadout: "MEDIA"
            case .fpsReadout: "FPS"
            case .timecodeReadout: "TIMECODE"
            case .resolutionReadout: "RESOLUTION"
            case .railRecord: "Record"
            case .railMedia: "Media"
            case .railSettings: "Settings"
            case .railDisp: "DISP"
            case .focusBox: "AF Box"
            }
        }

        /// The status-bar cells, so a shell can nest their badges inside the deck.
        ///
        /// In photography the same three slots carry SHOTS, image area and quality — one cell,
        /// one switch, whichever capture mode the body is in.
        public static let statusBarReadouts: [Section] = [
            .recReadout, .timecodeReadout, .resolutionReadout, .codecReadout, .mediaReadout,
            .fpsReadout,
        ]

        /// The four side-rail controls, top to bottom as the landscape rail draws them.
        public static let railControls: [Section] = [
            .railDisp, .railRecord, .railMedia, .railSettings,
        ]
    }

    /// Whether `section` currently renders.
    public func isVisible(_ section: Section) -> Bool {
        switch section {
        case .statusBar: statusBarVisible
        case .sideRails: sideRailsVisible
        case .assistToolbar: assistToolbarVisible
        case .cameraValues: cameraValuesVisible
        case .lockButton: lockButtonVisible
        case .batteryIndicators: batteryIndicatorsVisible
        case .recReadout: recReadoutVisible
        case .codecReadout: codecReadoutVisible
        case .mediaReadout: mediaReadoutVisible
        case .fpsReadout: fpsReadoutVisible
        case .timecodeReadout: timecodeReadoutVisible
        case .resolutionReadout: resolutionReadoutVisible
        case .railRecord: railRecordVisible
        case .railMedia: railMediaVisible
        case .railSettings: railSettingsVisible
        case .railDisp: railDispVisible
        case .focusBox: focusBoxVisible
        }
    }

    public init(
        statusBarVisible: Bool = true,
        sideRailsVisible: Bool = true,
        assistToolbarVisible: Bool = true,
        cameraValuesVisible: Bool = true,
        recReadoutVisible: Bool = true,
        codecReadoutVisible: Bool = true,
        mediaReadoutVisible: Bool = true,
        fpsReadoutVisible: Bool = true,
        lockButtonVisible: Bool = true,
        batteryIndicatorsVisible: Bool = true,
        timecodeReadoutVisible: Bool = true,
        resolutionReadoutVisible: Bool = true,
        railRecordVisible: Bool = true,
        railMediaVisible: Bool = true,
        railSettingsVisible: Bool = true,
        railDispVisible: Bool = true,
        focusBoxVisible: Bool = true
    ) {
        self.statusBarVisible = statusBarVisible
        self.sideRailsVisible = sideRailsVisible
        self.assistToolbarVisible = assistToolbarVisible
        self.cameraValuesVisible = cameraValuesVisible
        self.recReadoutVisible = recReadoutVisible
        self.codecReadoutVisible = codecReadoutVisible
        self.mediaReadoutVisible = mediaReadoutVisible
        self.fpsReadoutVisible = fpsReadoutVisible
        self.lockButtonVisible = lockButtonVisible
        self.batteryIndicatorsVisible = batteryIndicatorsVisible
        self.timecodeReadoutVisible = timecodeReadoutVisible
        self.resolutionReadoutVisible = resolutionReadoutVisible
        self.railRecordVisible = railRecordVisible
        self.railMediaVisible = railMediaVisible
        self.railSettingsVisible = railSettingsVisible
        self.railDispVisible = railDispVisible
        self.focusBoxVisible = focusBoxVisible
    }

    public var statusBarVisible: Bool
    public var sideRailsVisible: Bool
    public var assistToolbarVisible: Bool
    public var cameraValuesVisible: Bool
    // Per-readout visibility within the top status bar (Settings ▸ Display ▸ Live Status Readouts).
    // Independent of the DISP `Section` cycling above — the operator hides individual readouts they
    // don't ride during a take.
    public var recReadoutVisible: Bool
    public var codecReadoutVisible: Bool
    public var mediaReadoutVisible: Bool
    public var fpsReadoutVisible: Bool
    /// The rail's lock key. Hiding it is honoured only while controls are unlocked — see
    /// ``MonitorChromePolicy/showsLockControl(mode:preferences:interfaceLocked:)``.
    public var lockButtonVisible: Bool
    /// The camera/phone battery cluster on the lock-side rail.
    public var batteryIndicatorsVisible: Bool
    /// The timecode cell — the SHOTS-remaining cell in photography, same slot.
    public var timecodeReadoutVisible: Bool
    /// The resolution/frame-rate cell — the image-area/size cell in photography, same slot.
    public var resolutionReadoutVisible: Bool
    /// The rail's record control (photography: the shutter). Hiding it is honoured only while
    /// nothing is rolling — see ``MonitorChromePolicy/sideRailPlan(mode:preferences:capture:interfaceLocked:recordingOrPending:)``.
    public var railRecordVisible: Bool
    /// The rail's Media key.
    public var railMediaVisible: Bool
    /// The rail's Settings key. Hiding it is honoured only while some enabled DISP mode still
    /// carries one — Settings is the only route back to these switches.
    public var railSettingsVisible: Bool
    /// The rail's DISP key. The feed swipe (down → clean, up → live) is its second way out.
    public var railDispVisible: Bool
    /// The camera's AF / subject-detection boxes over the feed, and the recenter-focus key.
    public var focusBoxVisible: Bool

    private enum CodingKeys: String, CodingKey {
        case statusBarVisible, sideRailsVisible, assistToolbarVisible, cameraValuesVisible,
            recReadoutVisible, codecReadoutVisible, mediaReadoutVisible, fpsReadoutVisible,
            lockButtonVisible, batteryIndicatorsVisible
        case timecodeReadoutVisible, resolutionReadoutVisible
        case railRecordVisible, railMediaVisible, railSettingsVisible, railDispVisible
        case focusBoxVisible
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        statusBarVisible = try c.decode(Bool.self, forKey: .statusBarVisible)
        sideRailsVisible = try c.decode(Bool.self, forKey: .sideRailsVisible)
        assistToolbarVisible = try c.decode(Bool.self, forKey: .assistToolbarVisible)
        cameraValuesVisible = try c.decode(Bool.self, forKey: .cameraValuesVisible)
        // Per-readout flags were added later: an older saved blob lacks them, so default to visible
        // instead of failing the decode (which would reset every preference).
        recReadoutVisible = try c.decodeIfPresent(Bool.self, forKey: .recReadoutVisible) ?? true
        codecReadoutVisible = try c.decodeIfPresent(Bool.self, forKey: .codecReadoutVisible) ?? true
        mediaReadoutVisible = try c.decodeIfPresent(Bool.self, forKey: .mediaReadoutVisible) ?? true
        fpsReadoutVisible = try c.decodeIfPresent(Bool.self, forKey: .fpsReadoutVisible) ?? true
        // Same story for the lock key and the battery cluster: added after these blobs were
        // written, so an absent key means "the operator never chose" — keep them visible.
        lockButtonVisible = try c.decodeIfPresent(Bool.self, forKey: .lockButtonVisible) ?? true
        batteryIndicatorsVisible =
            try c.decodeIfPresent(Bool.self, forKey: .batteryIndicatorsVisible) ?? true
        // Third pass. The two remaining status-bar cells and the AF box were never switchable, so
        // an absent key means "the operator never chose" — keep them visible.
        timecodeReadoutVisible =
            try c.decodeIfPresent(Bool.self, forKey: .timecodeReadoutVisible) ?? true
        resolutionReadoutVisible =
            try c.decodeIfPresent(Bool.self, forKey: .resolutionReadoutVisible) ?? true
        focusBoxVisible = try c.decodeIfPresent(Bool.self, forKey: .focusBoxVisible) ?? true
        // The four rail controls were one `sideRails` blob, so a stored blob's single value is the
        // operator's choice for all four — expand it rather than defaulting them on and putting a
        // hidden rail back on their monitor.
        railRecordVisible =
            try c.decodeIfPresent(Bool.self, forKey: .railRecordVisible) ?? sideRailsVisible
        railMediaVisible =
            try c.decodeIfPresent(Bool.self, forKey: .railMediaVisible) ?? sideRailsVisible
        railSettingsVisible =
            try c.decodeIfPresent(Bool.self, forKey: .railSettingsVisible) ?? sideRailsVisible
        railDispVisible =
            try c.decodeIfPresent(Bool.self, forKey: .railDispVisible) ?? sideRailsVisible
    }

    /// DISP 2's stock configuration: a bare image plus the operator's way around it. The status
    /// deck, both bottom strips and the lock key start off; the **rail** (DISP, record, Media,
    /// Settings), the **focus box** and the **battery cluster** start on, because a clean view with
    /// no focus feedback, no battery and no route to Settings is a view you have to leave to use.
    /// The per-readout flags stay on so switching the status bar back on yields a complete bar
    /// rather than an empty pill.
    public static let cleanDefaults = DisplayChromeVisibility(
        statusBarVisible: false,
        sideRailsVisible: true,
        assistToolbarVisible: false,
        cameraValuesVisible: false,
        lockButtonVisible: false,
        batteryIndicatorsVisible: true)

    /// Whether `section` is configurable for `mode`.
    ///
    /// Live and clean offer the **same** list — clean is DISP 1 with different defaults, not a
    /// smaller feature. Command (DISP 3) replaces the feed with the dashboard, so it only owns the
    /// rail cluster. `sideRails` is configurable nowhere: it is the retired whole-rail blob, kept
    /// only so a stored value can expand into the four rail controls.
    public static func isConfigurable(_ section: Section, in mode: DispMode) -> Bool {
        if section == .sideRails { return false }
        // The DISP key is never hideable, in any mode or configuration. It was briefly offered as
        // a switch with the feed swipe as the fallback, but an escape route the operator has to
        // already know about is not an escape route — hiding the only visible way to change mode
        // is a trap whatever else is on screen.
        if section == .railDisp { return false }
        switch mode {
        case .live, .clean:
            return true
        case .command:
            // No feed, so no status bar, no readouts, no strips and no AF box — the rail only.
            return section == .lockButton || section == .batteryIndicators
                || Section.railControls.contains(section)
        }
    }

    /// The sections `mode` lets the operator show or hide, in render order.
    public static func configurableSections(in mode: DispMode) -> [Section] {
        Section.allCases.filter { isConfigurable($0, in: mode) }
    }

    public mutating func toggle(_ section: Section) {
        switch section {
        case .statusBar:
            statusBarVisible.toggle()
        case .sideRails:
            sideRailsVisible.toggle()
        case .assistToolbar:
            assistToolbarVisible.toggle()
        case .cameraValues:
            cameraValuesVisible.toggle()
        case .lockButton:
            lockButtonVisible.toggle()
        case .batteryIndicators:
            batteryIndicatorsVisible.toggle()
        case .recReadout:
            recReadoutVisible.toggle()
        case .codecReadout:
            codecReadoutVisible.toggle()
        case .mediaReadout:
            mediaReadoutVisible.toggle()
        case .fpsReadout:
            fpsReadoutVisible.toggle()
        case .timecodeReadout:
            timecodeReadoutVisible.toggle()
        case .resolutionReadout:
            resolutionReadoutVisible.toggle()
        case .railRecord:
            railRecordVisible.toggle()
        case .railMedia:
            railMediaVisible.toggle()
        case .railSettings:
            railSettingsVisible.toggle()
        case .railDisp:
            railDispVisible.toggle()
        case .focusBox:
            focusBoxVisible.toggle()
        }
    }
}

/// Persistable operator settings for monitor controls and local view assists.
public struct OperatorPreferences: Codable, Equatable, Sendable {
    public init(
        dispOrder: [DispMode],
        enabledDispModes: Set<DispMode>,
        displayChrome: DisplayChromeVisibility,
        recordConfirmationEnabled: Bool,
        bluetoothShutterEnabled: Bool = true,
        hapticsEnabled: Bool,
        keepScreenAwake: Bool,
        autoRotateFeedEnabled: Bool = true,
        streamPreset: LiveViewStreamPreset,
        qualityBias: LiveViewQualityBias,
        portraitFeedAspect: PortraitFeedAspect = .fit16x9,
        scopeActivationOrder: [MonitorAssistTool] = [],
        cleanChrome: DisplayChromeVisibility = .cleanDefaults,
        commandChrome: DisplayChromeVisibility = DisplayChromeVisibility(),
        photoDisplayChrome: DisplayChromeVisibility = DisplayChromeVisibility(),
        photoCleanChrome: DisplayChromeVisibility = .cleanDefaults,
        photoCommandChrome: DisplayChromeVisibility = DisplayChromeVisibility(),
        relayEncoderProfile: RelayEncoderProfile = .lowLatency,
        relayWatcherPasscode: String = "",
        relayAllowsControlRequests: Bool = true
    ) {
        self.dispOrder = dispOrder
        self.enabledDispModes = Self.normalizedEnabledDispModes(enabledDispModes)
        self.displayChrome = displayChrome
        self.recordConfirmationEnabled = recordConfirmationEnabled
        self.bluetoothShutterEnabled = bluetoothShutterEnabled
        self.hapticsEnabled = hapticsEnabled
        self.keepScreenAwake = keepScreenAwake
        self.autoRotateFeedEnabled = autoRotateFeedEnabled
        self.streamPreset = streamPreset
        self.qualityBias = qualityBias
        self.portraitFeedAspect = portraitFeedAspect
        self.scopeActivationOrder = scopeActivationOrder
        self.cleanChrome = cleanChrome
        self.commandChrome = commandChrome
        self.photoDisplayChrome = photoDisplayChrome
        self.photoCleanChrome = photoCleanChrome
        self.photoCommandChrome = photoCommandChrome
        self.relayEncoderProfile = relayEncoderProfile
        self.relayWatcherPasscode = relayWatcherPasscode
        self.relayAllowsControlRequests = relayAllowsControlRequests
    }

    /// Stock defaults — forwards to ``defaults``.
    public init() {
        self = Self.defaults
    }

    public var dispOrder: [DispMode]
    /// DISP modes included when the monitor DISP key cycles layouts. Order follows ``dispOrder``.
    public var enabledDispModes: Set<DispMode>
    /// DISP 1's chrome. Predates the per-mode split, so it keeps its original key and an older
    /// saved blob loads straight into it — see ``chrome(for:)``.
    public var displayChrome: DisplayChromeVisibility
    public var recordConfirmationEnabled: Bool
    /// A Bluetooth HID shutter remote's volume press toggles recording while the live monitor is
    /// up. On by default; the off toggle exists because the mechanism takes over the hardware
    /// volume buttons.
    public var bluetoothShutterEnabled: Bool
    public var hapticsEnabled: Bool
    public var keepScreenAwake: Bool
    /// Turns the monitoring image upright from the body's live-view orientation. Off keeps the
    /// picture in the camera's native landscape sensor orientation. Display only — the recording
    /// is never affected.
    public var autoRotateFeedEnabled: Bool
    public var streamPreset: LiveViewStreamPreset
    public var qualityBias: LiveViewQualityBias
    /// Which aspect the portrait feed renders at (operator pinch, persisted).
    public var portraitFeedAspect: PortraitFeedAspect
    /// Exactly the live-view-active scope tools (``MonitorAssistTool/scopeTools``), oldest to
    /// newest activation. Drives the portrait-fit recency-based 2-scope display selection.
    public var scopeActivationOrder: [MonitorAssistTool]
    /// DISP 2's chrome. Defaults to ``DisplayChromeVisibility/cleanDefaults`` — the bare image.
    public var cleanChrome: DisplayChromeVisibility
    /// DISP 3's chrome. Command replaces the feed with the dashboard, so only the rail cluster
    /// (rail, lock, batteries) is meaningful here.
    public var commandChrome: DisplayChromeVisibility
    /// The photography counterparts of the three above. A cinema operator and a stills shooter
    /// share one phone and want different chrome on it, so each DISP mode carries one layout per
    /// capture side. An upgrade seeds all three from the video set, so nothing moves until the
    /// operator deliberately diverges them.
    public var photoDisplayChrome: DisplayChromeVisibility
    public var photoCleanChrome: DisplayChromeVisibility
    public var photoCommandChrome: DisplayChromeVisibility
    /// The broadcaster's latency-vs-quality stance for the relay encoder.
    public var relayEncoderProfile: RelayEncoderProfile
    /// Watchers must enter this to receive the broadcast; empty means open. Four digits by UI
    /// convention, but the wire and the check treat it as an opaque string.
    public var relayWatcherPasscode: String
    /// Whether watchers may ask for camera control at all.
    public var relayAllowsControlRequests: Bool

    /// The chrome configuration `mode` renders on the `capture` side of the camera. Each pair owns
    /// its own set, so the operator can build a full DISP 1, a bare DISP 2 and a stripped DISP 3
    /// for video and again for stills, independently.
    public func chrome(for mode: DispMode, capture: CaptureLayoutMode) -> DisplayChromeVisibility {
        switch (capture, mode) {
        case (.video, .live): displayChrome
        case (.video, .clean): cleanChrome
        case (.video, .command): commandChrome
        case (.photo, .live): photoDisplayChrome
        case (.photo, .clean): photoCleanChrome
        case (.photo, .command): photoCommandChrome
        }
    }

    public mutating func setChrome(
        _ chrome: DisplayChromeVisibility, for mode: DispMode, capture: CaptureLayoutMode
    ) {
        switch (capture, mode) {
        case (.video, .live): displayChrome = chrome
        case (.video, .clean): cleanChrome = chrome
        case (.video, .command): commandChrome = chrome
        case (.photo, .live): photoDisplayChrome = chrome
        case (.photo, .clean): photoCleanChrome = chrome
        case (.photo, .command): photoCommandChrome = chrome
        }
    }

    /// Flips one chrome section for one DISP mode on one capture side. Sections the mode does not
    /// own are ignored — see ``DisplayChromeVisibility/isConfigurable(_:in:)``.
    public mutating func toggleChrome(
        _ section: DisplayChromeVisibility.Section, for mode: DispMode, capture: CaptureLayoutMode
    ) {
        guard DisplayChromeVisibility.isConfigurable(section, in: mode) else { return }
        var chrome = chrome(for: mode, capture: capture)
        chrome.toggle(section)
        setChrome(chrome, for: mode, capture: capture)
    }

    /// Restores one DISP mode's chrome on one capture side to its stock configuration.
    public mutating func resetChrome(for mode: DispMode, capture: CaptureLayoutMode) {
        setChrome(Self.defaults.chrome(for: mode, capture: capture), for: mode, capture: capture)
    }

    /// The ≤2 scope tools the portrait-fit stacked zone displays out of the `on` live tools: the
    /// two most recently activated (per ``scopeActivationOrder``), shown in canonical
    /// ``MonitorAssistTool/scopeTools`` order for display stability. Older active scopes stay
    /// active-but-hidden and reappear in fill mode. With no recorded order (a migrated install),
    /// the canonical `prefix(2)` shows.
    /// Records a live scope switching on (it becomes the newest) or off. Other tools are ignored;
    /// playback toggles never call this, so the live recency survives a review session.
    public mutating func recordScopeActivation(_ tool: MonitorAssistTool, on: Bool) {
        guard MonitorAssistTool.scopeTools.contains(tool) else { return }
        scopeActivationOrder.removeAll { $0 == tool }
        if on { scopeActivationOrder.append(tool) }
    }

    public func displayedFitScopes(on: Set<MonitorAssistTool>) -> [MonitorAssistTool] {
        let active = MonitorAssistTool.scopeTools.filter { on.contains($0) }
        let ordered = scopeActivationOrder.filter { active.contains($0) }
        let chosen = ordered.isEmpty ? Array(active.prefix(2)) : Array(ordered.suffix(2))
        return MonitorAssistTool.scopeTools.filter { chosen.contains($0) }
    }

    private enum CodingKeys: String, CodingKey {
        // The assist toolbar order and bar visibility keys an older build wrote are ignored: the
        // shared palette ranks tools by use.
        case dispOrder, enabledDispModes, displayChrome
        case recordConfirmationEnabled, recordHoldEnabled, bluetoothShutterEnabled, hapticsEnabled,
            keepScreenAwake, autoRotateFeedEnabled, streamPreset, qualityBias, portraitFeedAspect,
            scopeActivationOrder
        case cleanChrome, commandChrome
        case cleanChromeV2
        case photoDisplayChrome, photoCleanChrome, photoCommandChrome
        case relayEncoderProfile
        case relayWatcherPasscode, relayAllowsControlRequests
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        dispOrder = DispOrder.reconciled(
            try container.decode([DispMode].self, forKey: .dispOrder))
        if !Self.isValidDisplayOrder(dispOrder) {
            dispOrder = Self.defaults.dispOrder
        }
        enabledDispModes = Self.normalizedEnabledDispModes(
            try container.decodeIfPresent(Set<DispMode>.self, forKey: .enabledDispModes)
                ?? Set(DispMode.allCases))
        displayChrome = try container.decode(DisplayChromeVisibility.self, forKey: .displayChrome)
        if let confirmation = try container.decodeIfPresent(
            Bool.self, forKey: .recordConfirmationEnabled)
        {
            recordConfirmationEnabled = confirmation
        } else if let legacyHold = try container.decodeIfPresent(
            Bool.self, forKey: .recordHoldEnabled)
        {
            // Migrate the removed Record Hold toggle to Record Confirmation.
            recordConfirmationEnabled = legacyHold
        } else {
            recordConfirmationEnabled = true
        }
        // Predates some saved payloads. An absent key means the user never made a choice, so the
        // default-on applies; an explicitly saved false is a real opt-out and is preserved.
        bluetoothShutterEnabled =
            try container.decodeIfPresent(Bool.self, forKey: .bluetoothShutterEnabled) ?? true
        hapticsEnabled = try container.decode(Bool.self, forKey: .hapticsEnabled)
        keepScreenAwake = try container.decodeIfPresent(Bool.self, forKey: .keepScreenAwake) ?? true
        // Predates this switch. Absent means the operator never chose, so the default-on that
        // shipped with vertical mode applies; an explicitly saved false is a real opt-out.
        autoRotateFeedEnabled =
            try container.decodeIfPresent(Bool.self, forKey: .autoRotateFeedEnabled) ?? true
        streamPreset = try container.decode(LiveViewStreamPreset.self, forKey: .streamPreset)
        qualityBias = try container.decode(LiveViewQualityBias.self, forKey: .qualityBias)
        portraitFeedAspect =
            try container.decodeIfPresent(PortraitFeedAspect.self, forKey: .portraitFeedAspect)
            ?? .fit16x9
        // Older saved payloads predate this preference — tolerate absence, default to empty.
        scopeActivationOrder =
            try Self.decodeAssistToolArrayIfPresent(from: container, forKey: .scopeActivationOrder)
            ?? []
        // Chrome went per-DISP-mode after these blobs were written. The single stored set was the
        // global one, so it stays DISP 1's (decoded above into `displayChrome`); DISP 2 lands on
        // the documented bare image, and DISP 3 inherits the old global set so a rail or battery
        // cluster the operator had hidden stays hidden there. Nobody's monitor changes on update.
        //
        // DISP 2's key is versioned. Its stock configuration changed (the rail, the focus box and
        // the batteries now start ON) and a `DisplayChromeVisibility` blob writes every flag, so
        // the retired `cleanChrome` key cannot tell "the operator chose false" from "that was the
        // old default". It only ever existed in unreleased builds, so the one safe reading is to
        // start clean from the new stock set; DISP 1 and DISP 3 are untouched.
        cleanChrome =
            try container.decodeIfPresent(DisplayChromeVisibility.self, forKey: .cleanChromeV2)
            ?? .cleanDefaults
        commandChrome =
            try container.decodeIfPresent(DisplayChromeVisibility.self, forKey: .commandChrome)
            ?? displayChrome
        // Chrome went per-capture-mode after these blobs were written. Everything the operator
        // configured carries into BOTH sides, so a DISP 1 they built for video looks identical the
        // moment the body switches to stills — until they deliberately diverge the two.
        photoDisplayChrome =
            try container.decodeIfPresent(DisplayChromeVisibility.self, forKey: .photoDisplayChrome)
            ?? displayChrome
        photoCleanChrome =
            try container.decodeIfPresent(DisplayChromeVisibility.self, forKey: .photoCleanChrome)
            ?? cleanChrome
        photoCommandChrome =
            try container.decodeIfPresent(DisplayChromeVisibility.self, forKey: .photoCommandChrome)
            ?? commandChrome
        relayEncoderProfile =
            try container.decodeIfPresent(RelayEncoderProfile.self, forKey: .relayEncoderProfile)
            ?? .lowLatency
        relayWatcherPasscode =
            try container.decodeIfPresent(String.self, forKey: .relayWatcherPasscode) ?? ""
        relayAllowsControlRequests =
            try container.decodeIfPresent(Bool.self, forKey: .relayAllowsControlRequests) ?? true
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(dispOrder, forKey: .dispOrder)
        try container.encode(enabledDispModes, forKey: .enabledDispModes)
        try container.encode(displayChrome, forKey: .displayChrome)
        try container.encode(recordConfirmationEnabled, forKey: .recordConfirmationEnabled)
        try container.encode(bluetoothShutterEnabled, forKey: .bluetoothShutterEnabled)
        try container.encode(hapticsEnabled, forKey: .hapticsEnabled)
        try container.encode(keepScreenAwake, forKey: .keepScreenAwake)
        try container.encode(autoRotateFeedEnabled, forKey: .autoRotateFeedEnabled)
        try container.encode(streamPreset, forKey: .streamPreset)
        try container.encode(qualityBias, forKey: .qualityBias)
        try container.encode(portraitFeedAspect, forKey: .portraitFeedAspect)
        try container.encode(scopeActivationOrder, forKey: .scopeActivationOrder)
        try container.encode(cleanChrome, forKey: .cleanChromeV2)
        try container.encode(commandChrome, forKey: .commandChrome)
        try container.encode(photoDisplayChrome, forKey: .photoDisplayChrome)
        try container.encode(photoCleanChrome, forKey: .photoCleanChrome)
        try container.encode(photoCommandChrome, forKey: .photoCommandChrome)
        try container.encode(relayEncoderProfile, forKey: .relayEncoderProfile)
        try container.encode(relayWatcherPasscode, forKey: .relayWatcherPasscode)
        try container.encode(relayAllowsControlRequests, forKey: .relayAllowsControlRequests)
    }

    public static let defaults = OperatorPreferences(
        dispOrder: [.live, .clean, .command],
        enabledDispModes: Set(DispMode.allCases),
        displayChrome: DisplayChromeVisibility(),
        recordConfirmationEnabled: true,
        hapticsEnabled: true,
        keepScreenAwake: true,
        autoRotateFeedEnabled: true,
        // The smallest preset is ~320x240 — too little real detail for the focus and exposure
        // assists to read, and most of what a detector finds there is compression structure
        // rather than the lens. Default to the largest stream the body will send; the operator
        // can still drop to Balanced or Fast for latency. Quality bias stays at the body-default
        // middle ground, which the Size/Quality control reads as "Size".
        streamPreset: .quality,
        qualityBias: .balanced,
        cleanChrome: .cleanDefaults,
        commandChrome: DisplayChromeVisibility(),
        photoDisplayChrome: DisplayChromeVisibility(),
        photoCleanChrome: .cleanDefaults,
        photoCommandChrome: DisplayChromeVisibility()
    )

    /// Drops unknown and retired assist tool IDs; `nil` when the key is absent.
    private static func decodeAssistToolArrayIfPresent<K: CodingKey>(
        from container: KeyedDecodingContainer<K>, forKey key: K
    ) throws -> [MonitorAssistTool]? {
        guard container.contains(key) else { return nil }
        let raw = try container.decode([String].self, forKey: key)
        let valid = Set(MonitorAssistTool.activeCases)
        return raw.compactMap(MonitorAssistTool.init(rawValue:)).filter { valid.contains($0) }
    }

    /// Enabled DISP modes in persisted order — used by the monitor DISP key and its segment dots.
    public var enabledDispOrder: [DispMode] {
        let base = Self.isValidDisplayOrder(dispOrder) ? dispOrder : Self.defaults.dispOrder
        let filtered = base.filter { enabledDispModes.contains($0) }
        return filtered.isEmpty ? base : filtered
    }

    public func nextDisplayMode(after mode: DispMode) -> DispMode {
        let order = enabledDispOrder
        guard !order.isEmpty else {
            return Self.defaults.enabledDispOrder.first ?? .live
        }
        guard order.contains(mode) else {
            return order[0]
        }
        return mode.next(in: order)
    }

    /// Toggles whether `mode` participates in DISP cycling. Returns `false` when disabling the last
    /// enabled mode (at least one must stay on).
    @discardableResult
    public mutating func toggleDispMode(_ mode: DispMode) -> Bool {
        if enabledDispModes.contains(mode) {
            guard enabledDispModes.count > 1 else { return false }
            enabledDispModes.remove(mode)
            return true
        }
        enabledDispModes.insert(mode)
        return true
    }

    public static func isValidDisplayOrder(_ order: [DispMode]) -> Bool {
        order.count == DispMode.allCases.count && Set(order) == Set(DispMode.allCases)
    }

    private static func normalizedEnabledDispModes(_ modes: Set<DispMode>) -> Set<DispMode> {
        let valid = modes.intersection(Set(DispMode.allCases))
        return valid.isEmpty ? Set(DispMode.allCases) : valid
    }

    /// Reconciles the persisted DISP order with the current mode set: inserts any modes added in
    /// a newer build at their canonical position (a persisted order from an older build would
    /// otherwise omit them).
    public mutating func reconcileDispOrder() {
        let present = Set(dispOrder)
        for (index, mode) in DispMode.allCases.enumerated() where !present.contains(mode) {
            dispOrder.insert(mode, at: min(index, dispOrder.count))
        }
    }
}

/// The Nikon-only assist settings next to the shared `MonitorAssistState`: the LUT catalog pick,
/// the camera level style, zebra entry units, instant review, the retired magnifier and the scope
/// panels' options. Everything the shared state owns (tool on/off, guides, grid, desqueeze,
/// false colour, zebra, peaking, crush/clip, 50/50 split) is gone from this blob; an older blob
/// still decodes, its moved keys read once by the app's migration.
public struct AssistConfiguration: Codable, Equatable, Sendable {
    public struct Level: Codable, Equatable, Sendable {
        public enum Style: String, CaseIterable, Codable, Equatable, Sendable {
            case horizon = "Horizon"
            case gauge = "Gauge"
        }

        public init(style: Style = .horizon) {
            self.style = style
        }

        public var style: Style
    }

    /// Live-view punch-in for checking critical focus, and nothing more.
    ///
    /// A MONITORING transform: it never touches the camera's crop mode, resolution, recorded
    /// image or camera-side digital zoom. The operator punches in, confirms focus, and punches
    /// back out to the identical framing they left.
    ///
    /// Only the factor is persisted. Whether the view is currently punched in is transient by
    /// design — coming back to a session already magnified, with no memory of having done it,
    /// would read as a broken feed rather than a restored preference.
    public struct Magnification: Codable, Equatable, Sendable {
        /// The punch-in factors offered. Deliberately a closed set: this is a focus check, and a
        /// continuous zoom invites fiddling with a number that has no right answer.
        public enum Factor: String, CaseIterable, Codable, Equatable, Sendable, Identifiable {
            case x2 = "2x"
            case x3 = "3x"
            case x4 = "4x"

            public var id: String { rawValue }

            public var scale: Double {
                switch self {
                case .x2: 2
                case .x3: 3
                case .x4: 4
                }
            }
        }

        public init(factor: Factor = .x2) {
            self.factor = factor
        }

        public var factor: Factor
    }

    /// How the zebra thresholds read in the editor. The thresholds themselves live on the shared
    /// assist state's normalized monitoring axis; the unit only changes what the operator types.
    public struct Zebra: Codable, Equatable, Sendable {
        public enum Unit: String, CaseIterable, Codable, Equatable, Sendable {
            case native = "Native"
            case ire = "IRE"

            /// Operator-facing value of a normalized threshold.
            public func displayValue(for ire: Double, mapping: ExposureSignalMapping) -> Int {
                switch self {
                case .ire: Int(ire.rounded())
                case .native: Int(mapping.signalNative(monitorPercent: ire).rounded())
                }
            }

            /// The normalized threshold an operator-typed value stands for.
            public func monitorPercent(fromDisplay value: Int, mapping: ExposureSignalMapping)
                -> Double
            {
                switch self {
                case .ire: Double(value)
                case .native: mapping.monitorPercent(signalNative: Double(value))
                }
            }
        }

        public init(unit: Unit = .ire) {
            self.unit = unit
        }

        public var unit: Unit
    }

    public init(
        level: Level = Level(),
        zebra: Zebra = Zebra(),
        selectedLUT: LUTSelection = .builtIn(.log3G10Rec709)
    ) {
        self.level = level
        self.zebra = zebra
        self.selectedLUT = selectedLUT
    }

    /// Camera level overlay style (Nikon reads the body's attitude).
    public var level: Level
    public var magnification: Magnification = Magnification()
    public var zebra: Zebra
    public var instantReviewSeconds: Int = 5
    public var instantReviewShowsFocusPoint: Bool = true
    public var instantReviewShowsCaptureInfo: Bool = true
    public var selectedLUT: LUTSelection

    /// The retired `scopes` and `trafficLights` keys are ignored: the app's shared scope panel
    /// stores own those options now, and copied them once on upgrade.
    private enum CodingKeys: String, CodingKey {
        case level, magnification, zebra, selectedLUT,
            instantReviewSeconds, instantReviewShowsFocusPoint, instantReviewShowsCaptureInfo
    }

    /// Every key is optional: blobs written before the shared state took the moved fields still
    /// decode here, and a stored look that no longer exists falls back inside `LUTSelection`.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        level = try c.decodeIfPresent(Level.self, forKey: .level) ?? Level()
        magnification =
            try c.decodeIfPresent(Magnification.self, forKey: .magnification) ?? Magnification()
        zebra = try c.decodeIfPresent(Zebra.self, forKey: .zebra) ?? Zebra()
        selectedLUT =
            try c.decodeIfPresent(LUTSelection.self, forKey: .selectedLUT)
            ?? .builtIn(.log3G10Rec709)
        instantReviewSeconds =
            try c.decodeIfPresent(Int.self, forKey: .instantReviewSeconds) ?? 5
        instantReviewShowsFocusPoint =
            try c.decodeIfPresent(Bool.self, forKey: .instantReviewShowsFocusPoint) ?? true
        instantReviewShowsCaptureInfo =
            try c.decodeIfPresent(Bool.self, forKey: .instantReviewShowsCaptureInfo) ?? true
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(level, forKey: .level)
        try c.encode(magnification, forKey: .magnification)
        try c.encode(zebra, forKey: .zebra)
        try c.encode(selectedLUT, forKey: .selectedLUT)
        try c.encode(instantReviewSeconds, forKey: .instantReviewSeconds)
        try c.encode(instantReviewShowsFocusPoint, forKey: .instantReviewShowsFocusPoint)
        try c.encode(instantReviewShowsCaptureInfo, forKey: .instantReviewShowsCaptureInfo)
    }

    public static let defaults = AssistConfiguration()
}

/// The ride-along controls shown in the command monitor's primary grid (DISP 3). The operator can
/// reorder them by long-press-dragging a tile; the chosen order persists. UI-free: the shell maps
/// each kind to its title, picker and live value.
public enum CommandTileKind: String, CaseIterable, Codable, Equatable, Sendable {
    case mode
    case iso
    case shutter
    case iris
    case whiteBalance
    case resolutionFramerate
    case codec
    case ibis
}

/// Pure helpers for the persisted DISP button order.
public enum DispOrder {
    /// Every mode in its canonical position.
    public static let `default` = DispMode.allCases

    /// Reconciles a persisted order with the current mode set.
    public static func reconciled(_ order: [DispMode]) -> [DispMode] {
        var seen = Set<DispMode>()
        var result = order.filter { seen.insert($0).inserted }
        for mode in DispMode.allCases where !seen.contains(mode) {
            result.append(mode)
            seen.insert(mode)
        }
        return result.isEmpty ? `default` : result
    }

    /// Returns `order` with `mode` moved to `index` (clamped). A no-op if `mode` isn't present or
    /// is already at `index`.
    public static func moving(_ mode: DispMode, to index: Int, in order: [DispMode]) -> [DispMode] {
        guard let from = order.firstIndex(of: mode) else { return order }
        var result = order
        result.remove(at: from)
        let clamped = min(max(index, 0), result.count)
        result.insert(mode, at: clamped)
        return result
    }
}

/// Pure helpers for the persisted command-grid order.
public enum CommandGridOrder {
    /// Every tile in its canonical position.
    public static let `default` = CommandTileKind.allCases

    /// Reconciles a persisted order with the current tile set: drops duplicates and unknowns (decoded
    /// from an older/newer build), keeps the operator's arrangement, then appends any tiles that are
    /// missing in their canonical position so none ever vanish. An empty result falls back to default.
    public static func reconciled(_ order: [CommandTileKind]) -> [CommandTileKind] {
        var seen = Set<CommandTileKind>()
        var result = order.filter { seen.insert($0).inserted }
        for kind in CommandTileKind.allCases where !seen.contains(kind) {
            result.append(kind)
            seen.insert(kind)
        }
        return result.isEmpty ? `default` : result
    }

    /// Returns `order` with `kind` moved to `index` (clamped to the valid range). A no-op if `kind`
    /// isn't present or is already at `index`.
    public static func moving(_ kind: CommandTileKind, to index: Int, in order: [CommandTileKind])
        -> [CommandTileKind]
    {
        guard let from = order.firstIndex(of: kind) else { return order }
        var result = order
        result.remove(at: from)
        let clamped = min(max(index, 0), result.count)
        result.insert(kind, at: clamped)
        return result
    }
}

extension MonitorAssistTool {
    /// Assist tools that apply to still photography: the exposure aids (peaking, false
    /// color, zebra, histogram) plus the composition aids photographers actually use
    /// (grid, level, de-squeeze). Everything else is cinema-only, which keeps the photo toolbar
    /// deliberately shorter so the stills strip gets the bar width.
    ///
    /// De-squeeze is here because anamorphic lenses are used for stills too, and a squeezed
    /// preview makes faces, framing and edge behaviour impossible to judge on a tethered shoot.
    /// It is a display transform in every surface it reaches; the camera original is never
    /// touched.
    public var appliesToPhotography: Bool {
        switch self {
        case .peaking, .falseColor, .zebra, .histogram, .grid, .level, .evMeter, .instantReview,
            .desqueeze, .mirror, .magnification:
            // Mirror joins de-squeeze for the same reason: a body turned back at the subject is
            // just as common on a stills shoot, and both are display transforms that never reach
            // the camera original.
            true
        case .lut, .waveform, .parade, .vectorscope, .trafficLights, .audioMeters,
            .guides, .crosshair:
            false
        }
    }
}

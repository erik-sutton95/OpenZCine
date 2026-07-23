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
    case desqueeze = "DE-SQ"
    case instantReview = "PLAY"

    public var id: String { rawValue }

    /// Whether long-pressing the toolbar button opens a quick-settings popup. Tap still toggles the
    /// tool on/off. Framing aids and LUT carry richer pickers; analysis tools expose compact
    /// settings (scale, thresholds, scope modes, …) without duplicating the full settings tab.
    public var hasConfiguration: Bool {
        switch self {
        case .lut, .peaking, .falseColor, .zebra, .waveform, .parade, .histogram, .vectorscope,
            .trafficLights,
            .guides, .grid,
            .crosshair, .level, .desqueeze, .instantReview:
            true
        case .audioMeters:
            // Tap-only tool — the meters carry no operator-tunable options.
            false
        }
    }

    /// Tools that only exist in the photography toolset — the cinema strip never offers them.
    public var isPhotographyOnly: Bool {
        self == .instantReview
    }

    /// Exposure-analysis tools on the bottom assist toolbar (Display ▸ Exposure Tools).
    public static let exposureBarTools: [MonitorAssistTool] = [
        .peaking, .falseColor, .zebra, .waveform, .parade, .histogram, .vectorscope,
        .trafficLights, .audioMeters,
    ]

    /// Framing aids on the bottom assist toolbar (Display ▸ Frame & Composition Tools).
    public static let framingBarTools: [MonitorAssistTool] = [
        .guides, .grid, .crosshair, .level, .desqueeze,
    ]

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
        case .desqueeze: "Desqueeze"
        case .instantReview: "Instant Playback"
        }
    }
}

/// Visibility preferences for the live monitor chrome.
public struct DisplayChromeVisibility: Codable, Equatable, Sendable {
    public enum Section: Codable, Equatable, Sendable {
        case statusBar
        case sideRails
        case assistToolbar
        case cameraValues
    }

    public init(
        statusBarVisible: Bool = true,
        sideRailsVisible: Bool = true,
        assistToolbarVisible: Bool = true,
        cameraValuesVisible: Bool = true,
        recReadoutVisible: Bool = true,
        codecReadoutVisible: Bool = true,
        mediaReadoutVisible: Bool = true,
        fpsReadoutVisible: Bool = true
    ) {
        self.statusBarVisible = statusBarVisible
        self.sideRailsVisible = sideRailsVisible
        self.assistToolbarVisible = assistToolbarVisible
        self.cameraValuesVisible = cameraValuesVisible
        self.recReadoutVisible = recReadoutVisible
        self.codecReadoutVisible = codecReadoutVisible
        self.mediaReadoutVisible = mediaReadoutVisible
        self.fpsReadoutVisible = fpsReadoutVisible
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

    private enum CodingKeys: String, CodingKey {
        case statusBarVisible, sideRailsVisible, assistToolbarVisible, cameraValuesVisible,
            recReadoutVisible, codecReadoutVisible, mediaReadoutVisible, fpsReadoutVisible
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
        }
    }
}

/// Persistable operator settings for monitor controls and local view assists.
public struct OperatorPreferences: Codable, Equatable, Sendable {
    public enum StreamPreset: String, CaseIterable, Codable, Equatable, Sendable {
        case fast = "Fast"
        case balanced = "Balanced"
        case quality = "Quality"
    }

    public enum QualityBias: String, CaseIterable, Codable, Equatable, Sendable {
        case latency = "Latency"
        case balanced = "Balanced"
        case detail = "Detail"
    }

    public init(
        dispOrder: [DispMode],
        enabledDispModes: Set<DispMode>,
        displayChrome: DisplayChromeVisibility,
        assistToolbarOrder: [MonitorAssistTool],
        exposureBarVisibleControls: Set<MonitorAssistTool>,
        framingBarVisibleControls: Set<MonitorAssistTool>,
        liveViewVisibleAssistTools: Set<MonitorAssistTool>,
        playbackVisibleAssistTools: Set<MonitorAssistTool>,
        recordConfirmationEnabled: Bool,
        bluetoothShutterEnabled: Bool = true,
        hapticsEnabled: Bool,
        keepScreenAwake: Bool,
        streamPreset: StreamPreset,
        qualityBias: QualityBias,
        portraitFeedAspect: PortraitFeedAspect = .fit16x9,
        scopeActivationOrder: [MonitorAssistTool] = []
    ) {
        self.dispOrder = dispOrder
        self.enabledDispModes = Self.normalizedEnabledDispModes(enabledDispModes)
        self.displayChrome = displayChrome
        self.assistToolbarOrder = assistToolbarOrder
        self.exposureBarVisibleControls = Self.normalizedBarControls(
            exposureBarVisibleControls, allowed: MonitorAssistTool.exposureBarTools)
        self.framingBarVisibleControls = Self.normalizedBarControls(
            framingBarVisibleControls, allowed: MonitorAssistTool.framingBarTools)
        self.liveViewVisibleAssistTools = liveViewVisibleAssistTools
        self.playbackVisibleAssistTools = playbackVisibleAssistTools
        self.recordConfirmationEnabled = recordConfirmationEnabled
        self.bluetoothShutterEnabled = bluetoothShutterEnabled
        self.hapticsEnabled = hapticsEnabled
        self.keepScreenAwake = keepScreenAwake
        self.streamPreset = streamPreset
        self.qualityBias = qualityBias
        self.portraitFeedAspect = portraitFeedAspect
        self.scopeActivationOrder = scopeActivationOrder
    }

    /// Stock defaults — forwards to ``defaults``.
    public init() {
        self = Self.defaults
    }

    public var dispOrder: [DispMode]
    /// DISP modes included when the monitor DISP key cycles layouts. Order follows ``dispOrder``.
    public var enabledDispModes: Set<DispMode>
    public var displayChrome: DisplayChromeVisibility
    public var assistToolbarOrder: [MonitorAssistTool]
    /// Exposure-analysis buttons shown on the bottom assist toolbar (independent of on/off state).
    public var exposureBarVisibleControls: Set<MonitorAssistTool>
    /// Framing-aid buttons shown on the bottom assist toolbar (independent of on/off state).
    public var framingBarVisibleControls: Set<MonitorAssistTool>
    public var liveViewVisibleAssistTools: Set<MonitorAssistTool>
    public var playbackVisibleAssistTools: Set<MonitorAssistTool>
    public var recordConfirmationEnabled: Bool
    /// A Bluetooth HID shutter remote's volume press toggles recording while the live monitor is
    /// up. On by default; the off toggle exists because the mechanism takes over the hardware
    /// volume buttons.
    public var bluetoothShutterEnabled: Bool
    public var hapticsEnabled: Bool
    public var keepScreenAwake: Bool
    public var streamPreset: StreamPreset
    public var qualityBias: QualityBias
    /// Which aspect the portrait feed renders at (operator pinch, persisted).
    public var portraitFeedAspect: PortraitFeedAspect
    /// Exactly the live-view-active scope tools (``MonitorAssistTool/scopeTools``), oldest to
    /// newest activation. Drives the portrait-fit recency-based 2-scope display selection.
    public var scopeActivationOrder: [MonitorAssistTool]

    /// The ≤2 scope tools the portrait-fit stacked zone displays: the two most recently
    /// activated (per ``scopeActivationOrder``), shown in canonical ``MonitorAssistTool/scopeTools``
    /// order for display stability. Older active scopes stay active-but-hidden and reappear in
    /// fill mode. Fallback: pre-migration payloads decode with active scopes but an empty order —
    /// then fall back to canonical `prefix(2)` (exactly the legacy behaviour).
    public var displayedFitScopes: [MonitorAssistTool] {
        let active = MonitorAssistTool.scopeTools.filter {
            liveViewVisibleAssistTools.contains($0)
        }
        let ordered = scopeActivationOrder.filter { active.contains($0) }
        let chosen = ordered.isEmpty ? Array(active.prefix(2)) : Array(ordered.suffix(2))
        return MonitorAssistTool.scopeTools.filter { chosen.contains($0) }
    }

    private enum CodingKeys: String, CodingKey {
        case dispOrder, enabledDispModes, displayChrome, assistToolbarOrder
        case exposureBarVisibleControls, framingBarVisibleControls
        case liveViewVisibleAssistTools, playbackVisibleAssistTools
        case visibleAssistTools
        case recordConfirmationEnabled, recordHoldEnabled, bluetoothShutterEnabled, hapticsEnabled,
            keepScreenAwake, streamPreset, qualityBias, portraitFeedAspect, scopeActivationOrder
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
        assistToolbarOrder = try Self.decodeAssistToolArray(
            from: container, forKey: .assistToolbarOrder)
        exposureBarVisibleControls = Self.normalizedBarControls(
            try Self.decodeAssistToolSet(
                from: container, forKey: .exposureBarVisibleControls,
                default: Set(MonitorAssistTool.exposureBarTools)),
            allowed: MonitorAssistTool.exposureBarTools)
        framingBarVisibleControls = Self.normalizedBarControls(
            try Self.decodeAssistToolSet(
                from: container, forKey: .framingBarVisibleControls,
                default: Set(MonitorAssistTool.framingBarTools)),
            allowed: MonitorAssistTool.framingBarTools)
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
        streamPreset = try container.decode(StreamPreset.self, forKey: .streamPreset)
        qualityBias = try container.decode(QualityBias.self, forKey: .qualityBias)
        portraitFeedAspect =
            try container.decodeIfPresent(PortraitFeedAspect.self, forKey: .portraitFeedAspect)
            ?? .fit16x9
        // Older saved payloads predate this preference — tolerate absence, default to empty.
        scopeActivationOrder =
            try Self.decodeAssistToolArrayIfPresent(from: container, forKey: .scopeActivationOrder)
            ?? []
        if let live = try Self.decodeAssistToolSetIfPresent(
            from: container, forKey: .liveViewVisibleAssistTools)
        {
            liveViewVisibleAssistTools = live
            playbackVisibleAssistTools =
                try Self.decodeAssistToolSetIfPresent(
                    from: container, forKey: .playbackVisibleAssistTools) ?? []
        } else if let legacy = try Self.decodeAssistToolSetIfPresent(
            from: container, forKey: .visibleAssistTools)
        {
            liveViewVisibleAssistTools = legacy
            playbackVisibleAssistTools = []
        } else {
            liveViewVisibleAssistTools = []
            playbackVisibleAssistTools = []
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(dispOrder, forKey: .dispOrder)
        try container.encode(enabledDispModes, forKey: .enabledDispModes)
        try container.encode(displayChrome, forKey: .displayChrome)
        try container.encode(assistToolbarOrder, forKey: .assistToolbarOrder)
        try container.encode(exposureBarVisibleControls, forKey: .exposureBarVisibleControls)
        try container.encode(framingBarVisibleControls, forKey: .framingBarVisibleControls)
        try container.encode(liveViewVisibleAssistTools, forKey: .liveViewVisibleAssistTools)
        try container.encode(playbackVisibleAssistTools, forKey: .playbackVisibleAssistTools)
        try container.encode(recordConfirmationEnabled, forKey: .recordConfirmationEnabled)
        try container.encode(bluetoothShutterEnabled, forKey: .bluetoothShutterEnabled)
        try container.encode(hapticsEnabled, forKey: .hapticsEnabled)
        try container.encode(keepScreenAwake, forKey: .keepScreenAwake)
        try container.encode(streamPreset, forKey: .streamPreset)
        try container.encode(qualityBias, forKey: .qualityBias)
        try container.encode(portraitFeedAspect, forKey: .portraitFeedAspect)
        try container.encode(scopeActivationOrder, forKey: .scopeActivationOrder)
    }

    /// Live-monitor assist visibility. Prefer ``visibleAssistTools(for:)`` when the context is known.
    public var visibleAssistTools: Set<MonitorAssistTool> {
        get { liveViewVisibleAssistTools }
        set { liveViewVisibleAssistTools = newValue }
    }

    public func visibleAssistTools(for context: ViewAssistContext) -> Set<MonitorAssistTool> {
        switch context {
        case .liveView: liveViewVisibleAssistTools
        case .playback: playbackVisibleAssistTools
        }
    }

    public static let defaults = OperatorPreferences(
        dispOrder: [.live, .clean, .command],
        enabledDispModes: Set(DispMode.allCases),
        displayChrome: DisplayChromeVisibility(),
        assistToolbarOrder: MonitorAssistTool.allCases,
        exposureBarVisibleControls: Set(MonitorAssistTool.exposureBarTools),
        framingBarVisibleControls: Set(MonitorAssistTool.framingBarTools),
        liveViewVisibleAssistTools: [],
        playbackVisibleAssistTools: [],
        recordConfirmationEnabled: true,
        hapticsEnabled: true,
        keepScreenAwake: true,
        streamPreset: .fast,
        qualityBias: .latency
    )

    /// Whether `tool` should appear on the bottom assist toolbar (LUT is always shown).
    public func isAssistToolbarButtonVisible(_ tool: MonitorAssistTool) -> Bool {
        if MonitorAssistTool.exposureBarTools.contains(tool) {
            return exposureBarVisibleControls.contains(tool)
        }
        if MonitorAssistTool.framingBarTools.contains(tool) {
            return framingBarVisibleControls.contains(tool)
        }
        return true
    }

    public mutating func toggleExposureBarControl(_ tool: MonitorAssistTool) {
        guard MonitorAssistTool.exposureBarTools.contains(tool) else { return }
        if exposureBarVisibleControls.contains(tool) {
            exposureBarVisibleControls.remove(tool)
        } else {
            exposureBarVisibleControls.insert(tool)
        }
    }

    public mutating func toggleFramingBarControl(_ tool: MonitorAssistTool) {
        guard MonitorAssistTool.framingBarTools.contains(tool) else { return }
        if framingBarVisibleControls.contains(tool) {
            framingBarVisibleControls.remove(tool)
        } else {
            framingBarVisibleControls.insert(tool)
        }
    }

    private static func normalizedBarControls(
        _ controls: Set<MonitorAssistTool>, allowed: [MonitorAssistTool]
    ) -> Set<MonitorAssistTool> {
        let allowedSet = Set(allowed)
        return controls.intersection(allowedSet)
    }

    /// Drops unknown assist tool IDs when loading older preference blobs.
    private static func decodeAssistToolArray<K: CodingKey>(
        from container: KeyedDecodingContainer<K>, forKey key: K
    ) throws -> [MonitorAssistTool] {
        let raw = try container.decode([String].self, forKey: key)
        let valid = Set(MonitorAssistTool.allCases)
        let decoded = raw.compactMap(MonitorAssistTool.init(rawValue:)).filter {
            valid.contains($0)
        }
        // Tools introduced after the order was first persisted append at the end — without
        // this, a saved order simply never shows a new tool.
        return decoded + MonitorAssistTool.allCases.filter { !decoded.contains($0) }
    }

    /// Same as ``decodeAssistToolArray`` but tolerates an absent key (returns `nil` instead of
    /// throwing), for preferences added after the key was already being persisted.
    private static func decodeAssistToolArrayIfPresent<K: CodingKey>(
        from container: KeyedDecodingContainer<K>, forKey key: K
    ) throws -> [MonitorAssistTool]? {
        guard container.contains(key) else { return nil }
        let raw = try container.decode([String].self, forKey: key)
        let valid = Set(MonitorAssistTool.allCases)
        return raw.compactMap(MonitorAssistTool.init(rawValue:)).filter { valid.contains($0) }
    }

    private static func decodeAssistToolSet<K: CodingKey>(
        from container: KeyedDecodingContainer<K>, forKey key: K,
        default defaultValue: Set<MonitorAssistTool>
    ) throws -> Set<MonitorAssistTool> {
        if let value = try decodeAssistToolSetIfPresent(from: container, forKey: key) {
            return value
        }
        return defaultValue
    }

    private static func decodeAssistToolSetIfPresent<K: CodingKey>(
        from container: KeyedDecodingContainer<K>, forKey key: K
    ) throws -> Set<MonitorAssistTool>? {
        guard container.contains(key) else { return nil }
        let raw = try container.decode([String].self, forKey: key)
        let valid = Set(MonitorAssistTool.allCases)
        return Set(raw.compactMap(MonitorAssistTool.init(rawValue:)).filter { valid.contains($0) })
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

    /// Reconciles the persisted toolbar order with the current tool set: inserts any tools added in
    /// a newer build at their canonical position so they always surface on the bar (a persisted
    /// order from an older build would otherwise omit them). A tool the persisted blob has never
    /// seen also starts visible on its bar — new tools must surface for the operator to decide on,
    /// rather than inherit absence from a set saved before they existed. Tools the operator hid
    /// (present in the order, absent from the visible set) stay hidden.
    public mutating func reconcileAssistTools() {
        let present = Set(assistToolbarOrder)
        for (index, tool) in MonitorAssistTool.allCases.enumerated() where !present.contains(tool) {
            assistToolbarOrder.insert(tool, at: min(index, assistToolbarOrder.count))
            if MonitorAssistTool.exposureBarTools.contains(tool) {
                exposureBarVisibleControls.insert(tool)
            } else if MonitorAssistTool.framingBarTools.contains(tool) {
                framingBarVisibleControls.insert(tool)
            }
        }
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

/// Persistable configuration for app-side assist overlays.
public struct AssistConfiguration: Codable, Equatable, Sendable {
    public struct Guides: Codable, Equatable, Sendable {
        public enum Family: String, CaseIterable, Codable, Equatable, Sendable {
            case film = "Film"
            case social = "Social"
        }

        public enum AspectRatio: String, CaseIterable, Codable, Equatable, Hashable, Sendable,
            Identifiable
        {
            // Film / cinema delivery
            case ratio276 = "2.76:1"
            case ratio239 = "2.39:1"
            case ratio235 = "2.35:1"
            case ratio200 = "2.00:1"
            case ratio185 = "1.85:1"
            case ratio16x9 = "16:9"
            case ratio166 = "1.66:1"
            case ratio143 = "1.43:1"
            case ratio4x3 = "4:3"
            // Social delivery
            case ratio9x16 = "9:16"
            case ratio4x5 = "4:5"
            case ratio1x1 = "1:1"
            case ratio2x3 = "2:3"
            case ratio191 = "1.91:1"

            public var id: String { rawValue }

            /// Width ÷ height parsed from the `W:H` label (e.g. 2.39 for `2.39:1`, 0.5625 for `9:16`).
            public var value: Double {
                let parts = rawValue.split(separator: ":").compactMap { Double($0) }
                guard parts.count == 2, parts[1] > 0 else { return 1 }
                return parts[0] / parts[1]
            }

            /// Ratios shown on the Film tab, in display order (cinema / broadcast).
            public static let film: [AspectRatio] = [
                .ratio276, .ratio239, .ratio235, .ratio200, .ratio185, .ratio16x9, .ratio166,
                .ratio143, .ratio4x3,
            ]
            /// Ratios shown on the Social tab, in display order (vertical / square / landscape feeds).
            /// `16:9` appears in both tabs — selection is a single shared set, so it's the same case.
            public static let social: [AspectRatio] = [
                .ratio9x16, .ratio4x5, .ratio1x1, .ratio2x3, .ratio16x9, .ratio191,
            ]

            public static func ratios(for family: Family) -> [AspectRatio] {
                switch family {
                case .film: film
                case .social: social
                }
            }
        }

        public init(
            family: Family = .film,
            selectedRatios: Set<AspectRatio> = [.ratio239],
            maskEnabled: Bool = false
        ) {
            self.family = family
            self.selectedRatios = selectedRatios
            self.maskEnabled = maskEnabled
        }

        /// The Family tab last viewed in the popup (UI state — selection itself spans both tabs).
        public var family: Family
        /// Every aspect-ratio frame currently drawn. Multiple may be active at once; the mask darkens
        /// the inverse of their union.
        public var selectedRatios: Set<AspectRatio>
        /// Darken everything outside the (combined) selected frames.
        public var maskEnabled: Bool

        /// Adds the ratio if absent, removes it if present.
        public mutating func toggle(_ ratio: AspectRatio) {
            if selectedRatios.contains(ratio) {
                selectedRatios.remove(ratio)
            } else {
                selectedRatios.insert(ratio)
            }
        }

        public func isSelected(_ ratio: AspectRatio) -> Bool {
            selectedRatios.contains(ratio)
        }

        /// Compact label for status readouts: the lone ratio, a count when several are active, or
        /// "—" when none.
        public var summaryLabel: String {
            if selectedRatios.count == 1 { return selectedRatios.first?.rawValue ?? "—" }
            return selectedRatios.isEmpty ? "—" : "\(selectedRatios.count) ratios"
        }

        private enum CodingKeys: String, CodingKey {
            case family, selectedRatios, maskEnabled
            case aspectRatio  // legacy single-selection field
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            family = try container.decodeIfPresent(Family.self, forKey: .family) ?? .film
            maskEnabled = try container.decodeIfPresent(Bool.self, forKey: .maskEnabled) ?? false
            if let set = try container.decodeIfPresent(
                Set<AspectRatio>.self, forKey: .selectedRatios)
            {
                selectedRatios = set
            } else if let legacy = try container.decodeIfPresent(
                AspectRatio.self, forKey: .aspectRatio)
            {
                // Migrate a config saved by the single-selection build.
                selectedRatios = [legacy]
            } else {
                selectedRatios = [.ratio239]
            }
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(family, forKey: .family)
            try container.encode(selectedRatios, forKey: .selectedRatios)
            try container.encode(maskEnabled, forKey: .maskEnabled)
        }
    }

    public struct Grid: Codable, Equatable, Sendable {
        public init(thirds: Bool = true, phi: Bool = false, diagonal: Bool = false) {
            self.thirds = thirds
            self.phi = phi
            self.diagonal = diagonal
        }

        public var thirds: Bool
        public var phi: Bool
        public var diagonal: Bool

        public var enabled: Bool {
            thirds || phi || diagonal
        }
    }

    public struct Level: Codable, Equatable, Sendable {
        public enum Style: String, CaseIterable, Codable, Equatable, Sendable {
            case horizon = "Horizon"
            case gauge = "Gauge"
        }

        public init(enabled: Bool = false, style: Style = .horizon) {
            self.enabled = enabled
            self.style = style
        }

        public var enabled: Bool
        public var style: Style
    }

    public struct Desqueeze: Codable, Equatable, Sendable {
        /// Common anamorphic squeeze chips (including 1.6×). Custom values use [factor].
        public enum Ratio: String, CaseIterable, Codable, Equatable, Sendable {
            case x1 = "1x"
            case x133 = "1.33x"
            case x15 = "1.5x"
            case x16 = "1.6x"
            case x165 = "1.65x"
            case x18 = "1.8x"
            case x2 = "2x"

            /// Numeric squeeze factor (e.g. `2.0` for a 2× anamorphic).
            public var factor: Double {
                switch self {
                case .x1: 1.0
                case .x133: 1.33
                case .x15: 1.5
                case .x16: 1.6
                case .x165: 1.65
                case .x18: 1.8
                case .x2: 2.0
                }
            }

            /// Nearest named chip for a snapped factor, if any chip matches within half a step.
            public static func matching(factor: Double) -> Ratio? {
                let snapped = Desqueeze.snap(factor)
                return allCases.first { abs($0.factor - snapped) < 0.005 }
            }
        }

        public enum Orientation: String, CaseIterable, Codable, Equatable, Sendable {
            case horizontal = "Horizontal"
            case vertical = "Vertical"
        }

        /// Inclusive operator range for custom de-squeeze.
        public static let factorRange: ClosedRange<Double> = 1.0...2.0
        /// Slider / step size for custom factor (0.01×).
        public static let factorStep: Double = 0.01

        public init(
            enabled: Bool = false,
            ratio: Ratio = .x1,
            factor: Double? = nil,
            orientation: Orientation = .horizontal
        ) {
            self.enabled = enabled
            self.orientation = orientation
            let resolved = Self.snap(factor ?? ratio.factor)
            self.factor = resolved
            self.ratio = Ratio.matching(factor: resolved) ?? ratio
        }

        public var enabled: Bool
        /// Named chip when the factor matches a preset; otherwise the last selected chip (UI only).
        public var ratio: Ratio
        /// Applied squeeze factor in [factorRange], always the source of truth for rendering.
        public var factor: Double
        public var orientation: Orientation

        /// True when [factor] is not one of the named chips (custom slider value).
        public var isCustomFactor: Bool { Ratio.matching(factor: factor) == nil }

        /// Sets the applied factor from a named chip.
        public mutating func select(ratio: Ratio) {
            self.ratio = ratio
            self.factor = ratio.factor
        }

        /// Sets a custom (or snapped) factor from the 1.0…2.0 slider.
        public mutating func select(factor raw: Double) {
            let snapped = Self.snap(raw)
            self.factor = snapped
            if let match = Ratio.matching(factor: snapped) {
                self.ratio = match
            }
        }

        public static func snap(_ raw: Double) -> Double {
            let clamped = min(max(raw, factorRange.lowerBound), factorRange.upperBound)
            let steps = (clamped / factorStep).rounded()
            return min(max(steps * factorStep, factorRange.lowerBound), factorRange.upperBound)
        }

        private enum CodingKeys: String, CodingKey {
            case enabled, ratio, factor, orientation
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
            orientation =
                try c.decodeIfPresent(Orientation.self, forKey: .orientation) ?? .horizontal
            if let storedFactor = try c.decodeIfPresent(Double.self, forKey: .factor) {
                factor = Self.snap(storedFactor)
                ratio =
                    try c.decodeIfPresent(Ratio.self, forKey: .ratio)
                    ?? Ratio.matching(factor: factor) ?? .x1
            } else if let storedRatio = try c.decodeIfPresent(Ratio.self, forKey: .ratio) {
                ratio = storedRatio
                factor = storedRatio.factor
            } else {
                ratio = .x1
                factor = 1.0
            }
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(enabled, forKey: .enabled)
            try c.encode(ratio, forKey: .ratio)
            try c.encode(factor, forKey: .factor)
            try c.encode(orientation, forKey: .orientation)
        }
    }

    /// How much crush/clip pile-up to tolerate at scope edges before traffic lights glow,
    /// expressed in stops of light (quarter-stop increments). Higher values are more forgiving —
    /// useful on bodies with limited dynamic range where a small edge pile-up is normal.
    public enum CrushClipCompensation: Int, CaseIterable, Codable, Equatable, Sendable,
        Identifiable
    {
        // Raw values approximate stops×10 (quarter steps round down) so the 0 / 0.5 / 1.0 stops
        // persisted by the earlier half-step range keep their meaning unchanged.
        case zero = 0
        case quarter = 2
        case half = 5
        case threeQuarter = 7
        case one = 10

        public var id: Int { rawValue }

        /// Operator-facing label in stops (quarter-stop steps).
        public var label: String {
            switch self {
            case .zero: "0"
            case .quarter: "0.25"
            case .half: "0.5"
            case .threeQuarter: "0.75"
            case .one: "1.0"
            }
        }

        /// Tolerance in stops before crush/clip traffic lights fire.
        public var stops: Double {
            switch self {
            case .zero: 0
            case .quarter: 0.25
            case .half: 0.5
            case .threeQuarter: 0.75
            case .one: 1.0
            }
        }

        /// Fraction of total channel energy in the crush/clip band required to light a traffic light.
        /// Each quarter-stop of compensation adds 2.5 percentage points (0 stops → 0%, 1 stop → 10%).
        public var pixelFractionThreshold: Double { stops / 10.0 }

        /// Lenient decode: values persisted by the earlier 0–2-stop range that exceed the new
        /// 1.0-stop ceiling (1.5 → 15, 2.0 → 20) clamp to ``one`` instead of throwing — a throw
        /// here would fail the whole preferences decode and wipe the operator's assist setup.
        public init(from decoder: any Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(Int.self)
            self = CrushClipCompensation(rawValue: raw) ?? (raw > 10 ? .one : .zero)
        }
    }

    /// Traffic Lights RGB goal-post meter — panel scale. The meter's crush/clip tolerance is the
    /// shared ``Scopes/crushClipCompensation`` setting (one value with the histogram).
    public struct TrafficLights: Codable, Equatable, Sendable {
        public static let scaleRange: ClosedRange<Double> = Scopes.scaleRange
        public static let defaultScale = 1.0

        public static func clampedScale(_ value: Double) -> Double {
            min(max(value, scaleRange.lowerBound), scaleRange.upperBound)
        }

        public init(scale: Double = defaultScale) {
            self.scale = Self.clampedScale(scale)
        }

        public var scale: Double

        enum CodingKeys: String, CodingKey {
            case scale
        }

        /// Removed per-surface setting — read during decode by `AssistConfiguration.init(from:)`
        /// so a customized value from the split era folds into the shared setting.
        enum LegacyCodingKeys: String, CodingKey {
            case crushClipCompensation
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            scale = Self.clampedScale(
                try c.decodeIfPresent(Double.self, forKey: .scale) ?? Self.defaultScale)
        }
    }

    /// Zebra overlay zones: highlight clip warning and optional midtone reference band.
    public struct Zebra: Codable, Equatable, Sendable {
        public enum Unit: String, CaseIterable, Codable, Equatable, Sendable {
            case native = "Native"
            case ire = "IRE"
        }

        public enum StripeColor: String, CaseIterable, Codable, Equatable, Sendable {
            case white = "White"
            case amber = "Amber"
            case red = "Red"
            case cyan = "Cyan"
            case green = "Green"
        }

        public init(
            unit: Unit = .ire,
            highlightEnabled: Bool = true,
            highlightIRE: Double = 100,
            highlightColor: StripeColor = .white,
            midtoneEnabled: Bool = true,
            midtoneIRE: Double = 55,
            midtoneColor: StripeColor = .amber
        ) {
            self.unit = unit
            self.highlightEnabled = highlightEnabled
            self.highlightIRE = highlightIRE
            self.highlightColor = highlightColor
            self.midtoneEnabled = midtoneEnabled
            self.midtoneIRE = midtoneIRE
            self.midtoneColor = midtoneColor
        }

        public var unit: Unit
        public var highlightEnabled: Bool
        /// Highlight point on OpenZCine's normalized black-to-clip monitoring axis.
        public var highlightIRE: Double
        public var highlightColor: StripeColor
        public var midtoneEnabled: Bool
        /// Midtone band centre on the normalized monitoring axis. ``unit`` only changes its editor.
        public var midtoneIRE: Double
        public var midtoneColor: StripeColor

        /// Operator-facing threshold for display/edit, honouring ``unit``.
        public func displayValue(for ire: Double, curve: ExposureToneCurve = .redLog3G10) -> Int {
            displayValue(for: ire, mapping: ExposureSignalMapping(curve: curve))
        }

        public func displayValue(for ire: Double, mapping: ExposureSignalMapping) -> Int {
            switch unit {
            case .ire: Int(ire.rounded())
            case .native:
                Int(mapping.signalNative(monitorPercent: ire).rounded())
            }
        }

        public mutating func setHighlight(
            fromDisplay value: Int, curve: ExposureToneCurve = .redLog3G10
        ) {
            setHighlight(fromDisplay: value, mapping: ExposureSignalMapping(curve: curve))
        }

        public mutating func setHighlight(
            fromDisplay value: Int, mapping: ExposureSignalMapping
        ) {
            highlightIRE =
                switch unit {
                case .ire: Double(value)
                case .native:
                    mapping.monitorPercent(signalNative: Double(value))
                }
        }

        public mutating func setMidtone(
            fromDisplay value: Int, curve: ExposureToneCurve = .redLog3G10
        ) {
            setMidtone(fromDisplay: value, mapping: ExposureSignalMapping(curve: curve))
        }

        public mutating func setMidtone(
            fromDisplay value: Int, mapping: ExposureSignalMapping
        ) {
            midtoneIRE =
                switch unit {
                case .ire: Double(value)
                case .native:
                    mapping.monitorPercent(signalNative: Double(value))
                }
        }
    }

    /// Per-scope display options (footprint scale, plot mode, trace brightness, reference guide
    /// lines, histogram traffic lights). Honoured by the Canvas scope plots.
    public struct Scopes: Codable, Equatable, Sendable {
        /// Uniform footprint multiplier on a scope's base dimensions. The operator sets it directly by
        /// dragging the scope's corner resize handle, so it's a continuous value within these bounds
        /// rather than a preset. ponytail: the bounds are a UX knob — widen if operators want extremes.
        public static let scaleRange: ClosedRange<Double> = 0.6...1.6
        public static let defaultScale = 1.0
        public static func clampedScale(_ value: Double) -> Double {
            min(max(value, scaleRange.lowerBound), scaleRange.upperBound)
        }

        /// Operator-facing trace brightness. Waveform/parade use a calibrated quarter-strength
        /// baseline (`100` = the former `25`); vectorscope retains its original unity baseline.
        public static let brightnessRange: ClosedRange<Int> = 0...200
        public static let defaultBrightness = 100
        private static let waveformParadeBrightnessCalibrationVersion = 2
        public static func clampedBrightness(_ value: Int) -> Int {
            min(max(value, brightnessRange.lowerBound), brightnessRange.upperBound)
        }
        /// Original unity-based multiplier retained for vectorscope trace intensity.
        public static func brightnessMultiplier(_ percent: Int) -> Double {
            Double(clampedBrightness(percent)) / 100.0
        }
        /// Calibrated waveform/parade multiplier (`100%` = the former `25%`, `200%` = former `50%`).
        public static func waveformParadeBrightnessMultiplier(_ percent: Int) -> Double {
            Double(clampedBrightness(percent)) / 400.0
        }

        private static func decodedWaveformParadeBrightness(
            storedValue: Int?, calibrationVersion: Int?
        ) -> Int {
            guard let storedValue else { return defaultBrightness }
            guard (calibrationVersion ?? 0) < waveformParadeBrightnessCalibrationVersion else {
                return clampedBrightness(storedValue)
            }
            let (migrated, overflowed) = storedValue.multipliedReportingOverflow(by: 4)
            if overflowed {
                return storedValue < 0 ? brightnessRange.lowerBound : brightnessRange.upperBound
            }
            return clampedBrightness(migrated)
        }

        public enum WaveformMode: String, CaseIterable, Codable, Equatable, Sendable, Identifiable {
            case luma = "Luma"
            case rgb = "RGB"
            public var id: String { rawValue }
        }

        public enum ParadeMode: String, CaseIterable, Codable, Equatable, Sendable, Identifiable {
            case rgb = "RGB"
            case yrgb = "YRGB"
            public var id: String { rawValue }
        }

        /// Vectorscope trace gain (graticule stays at unity). Higher gains read the near-neutral
        /// chroma a log-encoded feed meters — the unity trace hugs the centre on Log3G10, so 2x/4x
        /// open it up like a hardware scope's trace-gain control.
        public enum VectorscopeZoom: String, CaseIterable, Codable, Equatable, Sendable,
            Identifiable
        {
            case x1 = "1x"
            case x2 = "2x"
            case x4 = "4x"
            public var id: String { rawValue }

            /// Multiplier applied to the plotted chroma before binning.
            public var gain: Double {
                switch self {
                case .x1: 1
                case .x2: 2
                case .x4: 4
                }
            }
        }

        /// Reference guide lines a waveform/parade draws (clip at the top, mid grey at centre, crush
        /// at the bottom). Named `GuideLines` to avoid colliding with the aspect-ratio `Guides` above.
        public struct GuideLines: Codable, Equatable, Sendable {
            public var clip: Bool
            public var crush: Bool
            public var middle: Bool
            public init(clip: Bool = true, crush: Bool = true, middle: Bool = true) {
                self.clip = clip
                self.crush = crush
                self.middle = middle
            }
        }

        public init(
            waveformScale: Double = defaultScale,
            waveformMode: WaveformMode = .luma,
            waveformGuides: GuideLines = GuideLines(),
            waveformBrightness: Int = defaultBrightness,
            paradeScale: Double = defaultScale,
            paradeMode: ParadeMode = .rgb,
            paradeGuides: GuideLines = GuideLines(),
            paradeBrightness: Int = defaultBrightness,
            vectorscopeScale: Double = defaultScale,
            vectorscopeZoom: VectorscopeZoom = .x1,
            vectorscopeBrightness: Int = defaultBrightness,
            histogramScale: Double = defaultScale,
            histogramTrafficLights: Bool = true,
            crushClipCompensation: CrushClipCompensation = .quarter
        ) {
            self.waveformScale = Self.clampedScale(waveformScale)
            self.waveformMode = waveformMode
            self.waveformGuides = waveformGuides
            self.waveformBrightness = Self.clampedBrightness(waveformBrightness)
            self.paradeScale = Self.clampedScale(paradeScale)
            self.paradeMode = paradeMode
            self.paradeGuides = paradeGuides
            self.paradeBrightness = Self.clampedBrightness(paradeBrightness)
            self.vectorscopeScale = Self.clampedScale(vectorscopeScale)
            self.vectorscopeZoom = vectorscopeZoom
            self.vectorscopeBrightness = Self.clampedBrightness(vectorscopeBrightness)
            self.histogramScale = Self.clampedScale(histogramScale)
            self.histogramTrafficLights = histogramTrafficLights
            self.crushClipCompensation = crushClipCompensation
        }

        public var waveformScale: Double
        public var waveformMode: WaveformMode
        public var waveformGuides: GuideLines
        public var waveformBrightness: Int
        public var paradeScale: Double
        public var paradeMode: ParadeMode
        public var paradeGuides: GuideLines
        public var paradeBrightness: Int
        public var vectorscopeScale: Double
        public var vectorscopeZoom: VectorscopeZoom
        public var vectorscopeBrightness: Int
        public var histogramScale: Double
        public var histogramTrafficLights: Bool
        /// Crush/clip tolerance shared by every surface that meters the scope edges — the
        /// histogram's traffic lights and the standalone goal-post meter read this one value.
        public var crushClipCompensation: CrushClipCompensation

        enum CodingKeys: String, CodingKey {
            case waveformScale, waveformMode, waveformGuides, waveformBrightness, paradeScale,
                paradeMode, paradeGuides, paradeBrightness,
                vectorscopeScale, vectorscopeZoom, vectorscopeBrightness,
                histogramScale, histogramTrafficLights,
                crushClipCompensation, histogramCrushClipCompensation,
                histogramNoiseFloorCompensation, waveformParadeBrightnessCalibrationVersion
        }

        /// Removed settings — decoded and discarded so older saved configs still load.
        private enum LegacyCodingKeys: String, CodingKey {
            case histogramTrafficSensitivity
            case waveformSkinTone
        }

        private struct DiscardedWaveformSkinTone: Decodable, Sendable {
            var enabled: Bool?
            var color: String?
        }

        public func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(waveformScale, forKey: .waveformScale)
            try c.encode(waveformMode, forKey: .waveformMode)
            try c.encode(waveformGuides, forKey: .waveformGuides)
            try c.encode(waveformBrightness, forKey: .waveformBrightness)
            try c.encode(paradeScale, forKey: .paradeScale)
            try c.encode(paradeMode, forKey: .paradeMode)
            try c.encode(paradeGuides, forKey: .paradeGuides)
            try c.encode(paradeBrightness, forKey: .paradeBrightness)
            try c.encode(vectorscopeScale, forKey: .vectorscopeScale)
            try c.encode(vectorscopeZoom, forKey: .vectorscopeZoom)
            try c.encode(vectorscopeBrightness, forKey: .vectorscopeBrightness)
            try c.encode(histogramScale, forKey: .histogramScale)
            try c.encode(histogramTrafficLights, forKey: .histogramTrafficLights)
            try c.encode(crushClipCompensation, forKey: .crushClipCompensation)
            try c.encode(
                Self.waveformParadeBrightnessCalibrationVersion,
                forKey: .waveformParadeBrightnessCalibrationVersion)
        }

        // Every field decodes with a default so a partial or older blob still loads — including one
        // saved while scopes used the now-removed Small/Medium/Large size preset (those keys are just
        // ignored and the scale falls back to 1.0). Scales are clamped in case a stored value drifted.
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            waveformScale = Self.clampedScale(
                try c.decodeIfPresent(Double.self, forKey: .waveformScale) ?? Self.defaultScale)
            waveformMode = try c.decodeIfPresent(WaveformMode.self, forKey: .waveformMode) ?? .luma
            waveformGuides =
                try c.decodeIfPresent(GuideLines.self, forKey: .waveformGuides) ?? GuideLines()
            let brightnessCalibrationVersion = try c.decodeIfPresent(
                Int.self, forKey: .waveformParadeBrightnessCalibrationVersion)
            waveformBrightness = Self.decodedWaveformParadeBrightness(
                storedValue: try c.decodeIfPresent(Int.self, forKey: .waveformBrightness),
                calibrationVersion: brightnessCalibrationVersion)
            paradeScale = Self.clampedScale(
                try c.decodeIfPresent(Double.self, forKey: .paradeScale) ?? Self.defaultScale)
            paradeMode = try c.decodeIfPresent(ParadeMode.self, forKey: .paradeMode) ?? .rgb
            paradeGuides =
                try c.decodeIfPresent(GuideLines.self, forKey: .paradeGuides) ?? GuideLines()
            paradeBrightness = Self.decodedWaveformParadeBrightness(
                storedValue: try c.decodeIfPresent(Int.self, forKey: .paradeBrightness),
                calibrationVersion: brightnessCalibrationVersion)
            // Vectorscope settings postdate most saved blobs — absent keys take the defaults. The
            // retired Monitor/Source selection's key is simply ignored: the vectorscope always
            // plots the source/log signal now.
            vectorscopeScale = Self.clampedScale(
                try c.decodeIfPresent(Double.self, forKey: .vectorscopeScale) ?? Self.defaultScale)
            vectorscopeZoom =
                (try? c.decode(VectorscopeZoom.self, forKey: .vectorscopeZoom)) ?? .x1
            vectorscopeBrightness = Self.clampedBrightness(
                try c.decodeIfPresent(Int.self, forKey: .vectorscopeBrightness)
                    ?? Self.defaultBrightness)
            histogramScale = Self.clampedScale(
                try c.decodeIfPresent(Double.self, forKey: .histogramScale) ?? Self.defaultScale)
            histogramTrafficLights =
                try c.decodeIfPresent(Bool.self, forKey: .histogramTrafficLights) ?? true
            if let explicit = try c.decodeIfPresent(
                CrushClipCompensation.self, forKey: .crushClipCompensation)
            {
                crushClipCompensation = explicit
            } else {
                // Per-surface era: the histogram copy was ALWAYS encoded, so a stored `.zero`
                // (the old default) is indistinguishable from "never touched" and upgrades to the
                // shared `.quarter` default; a customized (non-zero) value is honored. The
                // traffic-lights copy is folded in by `AssistConfiguration.init(from:)`, which
                // can see both blobs.
                var legacy = try c.decodeIfPresent(
                    CrushClipCompensation.self, forKey: .histogramCrushClipCompensation)
                if legacy == nil {
                    // Renamed key — same persisted enum values.
                    legacy = try c.decodeIfPresent(
                        CrushClipCompensation.self, forKey: .histogramNoiseFloorCompensation)
                }
                if legacy == nil,
                    let legacyPercent = try decoder.container(keyedBy: LegacyCodingKeys.self)
                        .decodeIfPresent(Int.self, forKey: .histogramTrafficSensitivity)
                {
                    // Pre-stops migration stored 0/5/10/15/20 as percent; 0/5/10 map 1:1 to the
                    // current raw values, anything above the 1.0-stop ceiling clamps to `.one`.
                    legacy =
                        CrushClipCompensation(rawValue: legacyPercent)
                        ?? (legacyPercent > 10 ? .one : .zero)
                }
                crushClipCompensation = legacy.flatMap { $0 == .zero ? nil : $0 } ?? .quarter
            }
            let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
            _ = try legacy.decodeIfPresent(
                DiscardedWaveformSkinTone.self, forKey: .waveformSkinTone)
        }
    }

    public init(
        guides: Guides = Guides(),
        grid: Grid = Grid(),
        level: Level = Level(),
        desqueeze: Desqueeze = Desqueeze(),
        falseColorReferenceEnabled: Bool = true,
        falseColorScale: FalseColorScale = .stops,
        zebra: Zebra = Zebra(),
        trafficLights: TrafficLights = TrafficLights(),
        peakingColor: Peaking.Color = .red,
        peakingSensitivity: Peaking.Sensitivity = .medium,
        scopes: Scopes = Scopes(),
        selectedLUT: LUTSelection = .builtIn(.log3G10Rec709)
    ) {
        self.guides = guides
        self.grid = grid
        self.level = level
        self.desqueeze = desqueeze
        self.falseColorReferenceEnabled = falseColorReferenceEnabled
        self.falseColorScale = falseColorScale
        self.zebra = zebra
        self.trafficLights = trafficLights
        self.peakingColor = peakingColor
        self.peakingSensitivity = peakingSensitivity
        self.scopes = scopes
        self.selectedLUT = selectedLUT
    }

    public var guides: Guides
    public var grid: Grid
    public var level: Level
    public var desqueeze: Desqueeze
    public var falseColorReferenceEnabled: Bool
    /// Which false-colour ramp the overlay reads against (stop landmarks, monitor IRE, or limits).
    public var falseColorScale: FalseColorScale
    /// Zebra highlight/midtone zones and display units.
    public var zebra: Zebra
    /// Traffic Lights RGB goal-post meter panel scale.
    public var trafficLights: TrafficLights
    /// Colour focus-peaking paints in-focused edges.
    public var peakingColor: Peaking.Color
    /// How aggressively peaking flags edges (maps to the detector threshold in the renderer).
    public var peakingSensitivity: Peaking.Sensitivity
    /// Instant playback review duration in seconds; 0 keeps the still up until dismissed.
    public var instantReviewSeconds: Int = 5
    /// Overlay the AF box the shot focused with on the instant-playback still.
    public var instantReviewShowsFocusPoint: Bool = true
    /// Show the capture settings line (ISO · shutter · iris · quality) under the still.
    public var instantReviewShowsCaptureInfo: Bool = true
    /// Per-scope display options (size, mode, guide lines, traffic lights).
    public var scopes: Scopes
    /// The LUT applied to the live view (gated by the `.lut` assist tool being on).
    public var selectedLUT: LUTSelection

    /// Legacy accessor for the highlight zebra IRE — forwards to ``zebra``.
    public var zebraHighlightIRE: Double {
        get { zebra.highlightIRE }
        set { zebra.highlightIRE = newValue }
    }

    private enum CodingKeys: String, CodingKey {
        case guides, grid, level, desqueeze, falseColorReferenceEnabled, falseColorScale,
            zebra, trafficLights,
            zebraHighlightIRE, peakingColor, peakingSensitivity, scopes, selectedLUT,
            instantReviewSeconds, instantReviewShowsFocusPoint, instantReviewShowsCaptureInfo
    }

    /// Removed settings — decoded and discarded so older saved configs still load.
    private enum LegacyCodingKeys: String, CodingKey {
        case falseColorSkinReferenceEnabled, falseColorCurve
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Fields present since the first persisted version decode normally; ones added later use
        // `decodeIfPresent` with a default so an older saved config still loads (no reset).
        guides = try c.decode(Guides.self, forKey: .guides)
        grid = try c.decode(Grid.self, forKey: .grid)
        level = try c.decode(Level.self, forKey: .level)
        desqueeze = try c.decode(Desqueeze.self, forKey: .desqueeze)
        falseColorReferenceEnabled = try c.decode(Bool.self, forKey: .falseColorReferenceEnabled)
        selectedLUT = try c.decode(LUTSelection.self, forKey: .selectedLUT)
        let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
        _ = try legacy.decodeIfPresent(Bool.self, forKey: .falseColorSkinReferenceEnabled)
        _ = try? legacy.decodeIfPresent(String.self, forKey: .falseColorCurve)
        falseColorScale =
            try c.decodeIfPresent(FalseColorScale.self, forKey: .falseColorScale) ?? .stops
        if let decodedZebra = try c.decodeIfPresent(Zebra.self, forKey: .zebra) {
            zebra = decodedZebra
        } else {
            let legacyIRE = try c.decodeIfPresent(Double.self, forKey: .zebraHighlightIRE) ?? 100
            zebra = Zebra(highlightIRE: legacyIRE)
        }
        scopes = try c.decodeIfPresent(Scopes.self, forKey: .scopes) ?? Scopes()
        // Compensation re-unification: split-era configs stored a second copy under
        // trafficLights. When the scopes blob predates the shared key and its own histogram copy
        // was never customized (absent or the old `.zero` default), a customized traffic-lights
        // copy carries the operator's intent — fold it into the shared setting. Current encodes
        // never write the old trafficLights key, so this only fires for split-era blobs.
        if let scopesContainer = try? c.nestedContainer(
            keyedBy: Scopes.CodingKeys.self, forKey: .scopes),
            !scopesContainer.contains(.crushClipCompensation)
        {
            let histogramLegacy =
                ((try? scopesContainer.decodeIfPresent(
                    CrushClipCompensation.self, forKey: .histogramCrushClipCompensation)) ?? nil)
                ?? ((try? scopesContainer.decodeIfPresent(
                    CrushClipCompensation.self, forKey: .histogramNoiseFloorCompensation)) ?? nil)
            if histogramLegacy == nil || histogramLegacy == .zero,
                let trafficContainer = try? c.nestedContainer(
                    keyedBy: TrafficLights.LegacyCodingKeys.self, forKey: .trafficLights),
                let trafficLegacy =
                    ((try? trafficContainer.decodeIfPresent(
                        CrushClipCompensation.self, forKey: .crushClipCompensation)) ?? nil),
                trafficLegacy != .zero
            {
                scopes.crushClipCompensation = trafficLegacy
            }
        }
        trafficLights =
            try c.decodeIfPresent(TrafficLights.self, forKey: .trafficLights) ?? TrafficLights()
        peakingColor = try c.decodeIfPresent(Peaking.Color.self, forKey: .peakingColor) ?? .red
        peakingSensitivity =
            try c.decodeIfPresent(Peaking.Sensitivity.self, forKey: .peakingSensitivity) ?? .medium
        instantReviewSeconds =
            try c.decodeIfPresent(Int.self, forKey: .instantReviewSeconds) ?? 5
        instantReviewShowsFocusPoint =
            try c.decodeIfPresent(Bool.self, forKey: .instantReviewShowsFocusPoint) ?? true
        instantReviewShowsCaptureInfo =
            try c.decodeIfPresent(Bool.self, forKey: .instantReviewShowsCaptureInfo) ?? true
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(guides, forKey: .guides)
        try c.encode(grid, forKey: .grid)
        try c.encode(level, forKey: .level)
        try c.encode(desqueeze, forKey: .desqueeze)
        try c.encode(falseColorReferenceEnabled, forKey: .falseColorReferenceEnabled)
        try c.encode(falseColorScale, forKey: .falseColorScale)
        try c.encode(zebra, forKey: .zebra)
        try c.encode(trafficLights, forKey: .trafficLights)
        try c.encode(peakingColor, forKey: .peakingColor)
        try c.encode(peakingSensitivity, forKey: .peakingSensitivity)
        try c.encode(scopes, forKey: .scopes)
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

/// Pure helpers for the persisted assist-toolbar order.
public enum AssistToolbarOrder {
    /// Every tool in its canonical position.
    public static let `default` = MonitorAssistTool.allCases

    /// Reconciles a persisted order with the current tool set (same rules as ``CommandGridOrder``).
    public static func reconciled(_ order: [MonitorAssistTool]) -> [MonitorAssistTool] {
        var seen = Set<MonitorAssistTool>()
        var result = order.filter { seen.insert($0).inserted }
        for tool in MonitorAssistTool.allCases where !seen.contains(tool) {
            result.append(tool)
            seen.insert(tool)
        }
        return result.isEmpty ? `default` : result
    }

    /// Returns `order` with `tool` moved to `index` (clamped). A no-op if `tool` isn't present or
    /// is already at `index`.
    public static func moving(
        _ tool: MonitorAssistTool, to index: Int, in order: [MonitorAssistTool]
    ) -> [MonitorAssistTool] {
        guard let from = order.firstIndex(of: tool) else { return order }
        var result = order
        result.remove(at: from)
        let clamped = min(max(index, 0), result.count)
        result.insert(tool, at: clamped)
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

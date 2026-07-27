import Foundation
import Testing

@testable import OpenZCineCore

@Test func operatorPreferencesMigrateLegacyRecordHoldToRecordConfirmation() throws {
    var dict = try #require(
        try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(OperatorPreferences.defaults)) as? [String: Any])
    dict["recordHoldEnabled"] = false
    dict.removeValue(forKey: "recordConfirmationEnabled")
    let decoded = try JSONDecoder().decode(
        OperatorPreferences.self,
        from: try JSONSerialization.data(withJSONObject: dict))
    #expect(!decoded.recordConfirmationEnabled)
}

@Test func operatorPreferencesDefaultRecordConfirmationEnabled() {
    #expect(OperatorPreferences.defaults.recordConfirmationEnabled)
}

@Test func operatorPreferencesDefaultKeepScreenAwakeEnabled() {
    #expect(OperatorPreferences.defaults.keepScreenAwake)
}

@Test func operatorPreferencesDefaultToQualityStreamAtTheSizeBias() {
    // A new install asks the body for its largest preview stream. The bias stays on the
    // middle grade, which the operator-facing Size/Quality control reads as "Size".
    #expect(OperatorPreferences.defaults.streamPreset == .quality)
    #expect(OperatorPreferences.defaults.qualityBias == .balanced)
    #expect(OperatorPreferences.defaults.qualityBias != .detail)
}

@Test func operatorPreferencesDefaultToWireframeMonitorBehavior() {
    let preferences = OperatorPreferences.defaults

    #expect(preferences.dispOrder == [.live, .clean, .command])
    #expect(preferences.enabledDispModes == Set(DispMode.allCases))
    #expect(preferences.displayChrome.statusBarVisible)
    #expect(preferences.displayChrome.sideRailsVisible)
    #expect(preferences.displayChrome.assistToolbarVisible)
    #expect(preferences.displayChrome.cameraValuesVisible)
    #expect(preferences.assistToolbarOrder.first == .lut)
    #expect(preferences.assistToolbarOrder.contains(.peaking))
    #expect(preferences.assistToolbarOrder.contains(.desqueeze))
    // No assist overlays on for a first-time boot; the operator opts in and the choice persists.
    #expect(preferences.liveViewVisibleAssistTools.isEmpty)
    #expect(preferences.playbackVisibleAssistTools.isEmpty)
}

@Test func operatorPreferencesMigrateLegacyVisibleAssistTools() throws {
    var dict = try #require(
        try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(OperatorPreferences.defaults)) as? [String: Any])
    dict["visibleAssistTools"] = ["PEAK", "WAVE"]
    dict.removeValue(forKey: "liveViewVisibleAssistTools")
    dict.removeValue(forKey: "playbackVisibleAssistTools")
    let decoded = try JSONDecoder().decode(
        OperatorPreferences.self,
        from: try JSONSerialization.data(withJSONObject: dict))
    #expect(decoded.liveViewVisibleAssistTools == [.peaking, .waveform])
    #expect(decoded.playbackVisibleAssistTools.isEmpty)
}

@Test func portraitFeedAspectDefaultsAndRoundTrips() throws {
    var prefs = OperatorPreferences.defaults
    #expect(prefs.portraitFeedAspect == .fit16x9)
    prefs.portraitFeedAspect = .fill
    let data = try JSONEncoder().encode(prefs)
    let decoded = try JSONDecoder().decode(OperatorPreferences.self, from: data)
    #expect(decoded.portraitFeedAspect == .fill)
}

@Test func operatorPreferencesRoundTripIndependentAssistContexts() throws {
    var preferences = OperatorPreferences.defaults
    preferences.liveViewVisibleAssistTools = [.falseColor, .peaking]
    preferences.playbackVisibleAssistTools = [.lut, .histogram]
    let decoded = try JSONDecoder().decode(
        OperatorPreferences.self, from: try JSONEncoder().encode(preferences))
    #expect(decoded.liveViewVisibleAssistTools == [.falseColor, .peaking])
    #expect(decoded.playbackVisibleAssistTools == [.lut, .histogram])
}

@Test func reconcileAssistToolsSurfacesToolsMissingFromAPersistedOrder() {
    var preferences = OperatorPreferences.defaults
    // A toolbar order persisted before `.lut` existed.
    preferences.assistToolbarOrder = MonitorAssistTool.allCases.filter { $0 != .lut }
    #expect(!preferences.assistToolbarOrder.contains(.lut))

    preferences.reconcileAssistTools()

    #expect(preferences.assistToolbarOrder.contains(.lut))
    #expect(preferences.assistToolbarOrder.first == .lut)
    #expect(preferences.assistToolbarOrder.count == MonitorAssistTool.allCases.count)

    // Idempotent: a second pass changes nothing.
    let reconciled = preferences.assistToolbarOrder
    preferences.reconcileAssistTools()
    #expect(preferences.assistToolbarOrder == reconciled)
}

@Test func reconcileDispOrderSurfacesModesMissingFromAPersistedOrder() {
    var preferences = OperatorPreferences.defaults
    // An order persisted before `.command` existed.
    preferences.dispOrder = [.live, .clean]
    #expect(!preferences.dispOrder.contains(.command))

    preferences.reconcileDispOrder()

    #expect(preferences.dispOrder.contains(.command))
    #expect(preferences.dispOrder == [.live, .clean, .command])
    #expect(preferences.dispOrder.count == DispMode.allCases.count)

    // Idempotent: a second pass changes nothing.
    let reconciled = preferences.dispOrder
    preferences.reconcileDispOrder()
    #expect(preferences.dispOrder == reconciled)
}

@Test func preferencesCycleDisplayModeUsingConfiguredOrder() {
    var preferences = OperatorPreferences.defaults
    preferences.dispOrder = [.live, .command, .clean]

    #expect(preferences.nextDisplayMode(after: .live) == .command)
    #expect(preferences.nextDisplayMode(after: .command) == .clean)
    #expect(preferences.nextDisplayMode(after: .clean) == .live)
}

@Test func preferencesCycleDisplayModeSkipsDisabledModes() {
    var preferences = OperatorPreferences.defaults
    preferences.dispOrder = [.live, .clean, .command]
    preferences.enabledDispModes = [.live, .command]

    #expect(preferences.enabledDispOrder == [.live, .command])
    #expect(preferences.nextDisplayMode(after: .live) == .command)
    #expect(preferences.nextDisplayMode(after: .command) == .live)
    #expect(preferences.nextDisplayMode(after: .clean) == .live)
}

@Test func preferencesCannotDisableLastDispMode() {
    var preferences = OperatorPreferences.defaults
    preferences.enabledDispModes = [.live]

    let toggled = preferences.toggleDispMode(.live)
    #expect(!toggled)
    #expect(preferences.enabledDispModes == [.live])
}

@Test func preferencesMigrateMissingEnabledDispModes() throws {
    var dict = try #require(
        try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(OperatorPreferences.defaults)) as? [String: Any])
    dict.removeValue(forKey: "enabledDispModes")
    let decoded = try JSONDecoder().decode(
        OperatorPreferences.self,
        from: try JSONSerialization.data(withJSONObject: dict))
    #expect(decoded.enabledDispModes == Set(DispMode.allCases))
}

@Test func dispOrderMovingReordersWithoutDuplicates() {
    let order = DispMode.allCases
    let moved = DispOrder.moving(.command, to: 0, in: order)
    #expect(moved.first == .command)
    #expect(Set(moved).count == order.count)
}

@Test func preferencesFallBackToDefaultDisplayOrderWhenInvalid() {
    var preferences = OperatorPreferences.defaults
    preferences.dispOrder = [.command]
    preferences.enabledDispModes = [.command]

    #expect(preferences.enabledDispOrder == [.command])
    #expect(preferences.nextDisplayMode(after: .command) == .command)
}

@Test func displayChromeTogglesIndividualSections() {
    var chrome = DisplayChromeVisibility()

    chrome.toggle(.assistToolbar)
    chrome.toggle(.cameraValues)

    #expect(chrome.statusBarVisible)
    #expect(chrome.sideRailsVisible)
    #expect(!chrome.assistToolbarVisible)
    #expect(!chrome.cameraValuesVisible)
}

@Test func displayChromeReadoutFlagsDefaultVisibleAndRoundTrip() throws {
    #expect(DisplayChromeVisibility().recReadoutVisible)
    #expect(DisplayChromeVisibility().codecReadoutVisible)
    #expect(DisplayChromeVisibility().mediaReadoutVisible)
    #expect(DisplayChromeVisibility().fpsReadoutVisible)

    var chrome = DisplayChromeVisibility()
    chrome.codecReadoutVisible = false
    chrome.fpsReadoutVisible = false
    let decoded = try JSONDecoder().decode(
        DisplayChromeVisibility.self, from: try JSONEncoder().encode(chrome))
    #expect(decoded == chrome)
}

@Test func displayChromeDecodesOlderJSONWithoutReadoutKeys() throws {
    // A chrome blob saved before the per-readout flags existed must still load with them defaulting
    // to visible, rather than failing the decode and resetting every preference.
    let legacy =
        #"{"statusBarVisible":true,"sideRailsVisible":false,"#
        + #""assistToolbarVisible":true,"cameraValuesVisible":false}"#
    let decoded = try JSONDecoder().decode(
        DisplayChromeVisibility.self, from: Data(legacy.utf8))
    #expect(!decoded.sideRailsVisible)
    #expect(decoded.recReadoutVisible)
    #expect(decoded.codecReadoutVisible)
    #expect(decoded.mediaReadoutVisible)
    #expect(decoded.fpsReadoutVisible)
    // The lock key and battery cluster were added later still, on the same terms.
    #expect(decoded.lockButtonVisible)
    #expect(decoded.batteryIndicatorsVisible)
}

@Test func lockAndBatteryChromeDefaultVisibleAndRoundTrip() throws {
    #expect(DisplayChromeVisibility().lockButtonVisible)
    #expect(DisplayChromeVisibility().batteryIndicatorsVisible)
    #expect(OperatorPreferences.defaults.displayChrome.lockButtonVisible)
    #expect(OperatorPreferences.defaults.displayChrome.batteryIndicatorsVisible)

    var chrome = DisplayChromeVisibility()
    chrome.toggle(.lockButton)
    chrome.toggle(.batteryIndicators)
    #expect(!chrome.lockButtonVisible)
    #expect(!chrome.batteryIndicatorsVisible)
    let decoded = try JSONDecoder().decode(
        DisplayChromeVisibility.self, from: try JSONEncoder().encode(chrome))
    #expect(decoded == chrome)
}

@Test func hiddenLockKeyStillRendersWhileControlsAreLocked() {
    // The lock key is the only control that clears the lock on either shell, so hiding it must
    // never strand an operator who locked first and hid it after.
    var prefs = OperatorPreferences.defaults
    prefs.displayChrome.lockButtonVisible = false

    #expect(
        !MonitorChromePolicy.showsLockControl(
            mode: .live, preferences: prefs, interfaceLocked: false))
    #expect(
        MonitorChromePolicy.showsLockControl(
            mode: .live, preferences: prefs, interfaceLocked: true))
    #expect(
        MonitorChromePolicy.showsLockControl(
            mode: .command, preferences: prefs, interfaceLocked: true))
    // Clean strips the whole rail either way — it is not a fourth clean-view exception.
    #expect(
        !MonitorChromePolicy.showsLockControl(
            mode: .clean, preferences: OperatorPreferences.defaults, interfaceLocked: true))
}

@Test func hidingTheSideRailKeepsSettingsAndTheRollingRecordControl() {
    var prefs = OperatorPreferences.defaults
    let full = MonitorChromePolicy.sideRailPlan(
        mode: .live, preferences: prefs, recordingOrPending: false)
    #expect(full.fullRail)
    #expect(!full.settingsRecovery)
    #expect(!full.recordSafety)

    prefs.displayChrome.sideRailsVisible = false
    // Settings is the only route back to the toggle that hid the rail.
    let standby = MonitorChromePolicy.sideRailPlan(
        mode: .live, preferences: prefs, recordingOrPending: false)
    #expect(!standby.fullRail)
    #expect(standby.settingsRecovery)
    #expect(!standby.recordSafety)

    let rolling = MonitorChromePolicy.sideRailPlan(
        mode: .live, preferences: prefs, recordingOrPending: true)
    #expect(rolling.recordSafety)

    // Clean keeps its own rail configuration: hiding DISP 1's rail must not touch DISP 2, whose
    // rail carries the way out of the bare image.
    let clean = MonitorChromePolicy.sideRailPlan(
        mode: .clean, preferences: prefs, recordingOrPending: false)
    #expect(clean.fullRail)
    #expect(!clean.settingsRecovery)
}

// MARK: - Per-DISP-mode chrome

@Test func chromeIsConfiguredPerDispModeAndDefaultsToABareClean() {
    let prefs = OperatorPreferences.defaults

    #expect(prefs.chrome(for: .live) == DisplayChromeVisibility())
    #expect(prefs.chrome(for: .clean) == DisplayChromeVisibility.cleanDefaults)
    #expect(prefs.chrome(for: .command) == DisplayChromeVisibility())

    // Clean's stock look: bare image, but the rail still carries the DISP key out of it.
    #expect(!prefs.chrome(for: .clean).statusBarVisible)
    #expect(!prefs.chrome(for: .clean).assistToolbarVisible)
    #expect(!prefs.chrome(for: .clean).cameraValuesVisible)
    #expect(!prefs.chrome(for: .clean).batteryIndicatorsVisible)
    #expect(prefs.chrome(for: .clean).sideRailsVisible)
}

@Test func togglingOneModesChromeLeavesTheOthersAlone() {
    var prefs = OperatorPreferences.defaults
    prefs.toggleChrome(.statusBar, for: .clean)

    #expect(prefs.chrome(for: .clean).statusBarVisible)
    #expect(prefs.chrome(for: .live).statusBarVisible)
    prefs.toggleChrome(.statusBar, for: .live)
    #expect(!prefs.chrome(for: .live).statusBarVisible)
    #expect(prefs.chrome(for: .clean).statusBarVisible)

    prefs.resetChrome(for: .clean)
    #expect(!prefs.chrome(for: .clean).statusBarVisible)
    #expect(!prefs.chrome(for: .live).statusBarVisible, "resetting one mode must not touch another")
}

@Test func sectionsAModeDoesNotOwnAreNotTogglable() {
    // Command has no feed, so no status bar to reveal; clean's rail renders its two essentials
    // whatever the operator does, and `.cleanEssentials` carries no lock key.
    #expect(!DisplayChromeVisibility.isConfigurable(.statusBar, in: .command))
    #expect(!DisplayChromeVisibility.isConfigurable(.sideRails, in: .clean))
    #expect(!DisplayChromeVisibility.isConfigurable(.lockButton, in: .clean))
    #expect(DisplayChromeVisibility.isConfigurable(.lockButton, in: .command))
    #expect(DisplayChromeVisibility.configurableSections(in: .live).count == 10)
    #expect(
        DisplayChromeVisibility.configurableSections(in: .command) == [
            .sideRails, .lockButton, .batteryIndicators,
        ])

    var prefs = OperatorPreferences.defaults
    prefs.toggleChrome(.statusBar, for: .command)
    #expect(prefs.chrome(for: .command).statusBarVisible, "a non-owned section must not flip")
}

@Test func olderPayloadsMigrateTheGlobalChromeOntoDisp1AndDisp3() throws {
    // The single stored set was the global one. It becomes DISP 1's, DISP 3 inherits it so a
    // hidden rail stays hidden on the dashboard, and DISP 2 lands on the documented bare image.
    var prefs = OperatorPreferences.defaults
    prefs.displayChrome.sideRailsVisible = false
    prefs.displayChrome.batteryIndicatorsVisible = false
    var dict = try #require(
        try JSONSerialization.jsonObject(with: try JSONEncoder().encode(prefs)) as? [String: Any])
    dict.removeValue(forKey: "cleanChrome")
    dict.removeValue(forKey: "commandChrome")

    let decoded = try JSONDecoder().decode(
        OperatorPreferences.self, from: try JSONSerialization.data(withJSONObject: dict))

    #expect(decoded.chrome(for: .live) == prefs.displayChrome)
    #expect(decoded.chrome(for: .command) == prefs.displayChrome)
    #expect(decoded.chrome(for: .clean) == DisplayChromeVisibility.cleanDefaults)
    // The rest of the blob survives — a missing new key never resets the preferences.
    #expect(decoded.dispOrder == OperatorPreferences.defaults.dispOrder)
    #expect(decoded.streamPreset == OperatorPreferences.defaults.streamPreset)
}

@Test func perModeChromeRoundTrips() throws {
    var prefs = OperatorPreferences.defaults
    prefs.toggleChrome(.statusBar, for: .clean)
    prefs.toggleChrome(.fpsReadout, for: .clean)
    prefs.toggleChrome(.sideRails, for: .command)

    let decoded = try JSONDecoder().decode(
        OperatorPreferences.self, from: try JSONEncoder().encode(prefs))

    #expect(decoded.chrome(for: .clean).statusBarVisible)
    #expect(!decoded.chrome(for: .clean).fpsReadoutVisible)
    #expect(!decoded.chrome(for: .command).sideRailsVisible)
    #expect(decoded.chrome(for: .live) == DisplayChromeVisibility())
}

@Test func aBareCleanRendersNothingItWasNotToldTo() {
    let prefs = OperatorPreferences.defaults
    for section in DisplayChromeVisibility.Section.allCases
    where section != .sideRails
        && !DisplayChromeVisibility.Section.statusBarReadouts
            .contains(section)
    {
        #expect(
            !MonitorChromePolicy.showsSection(section, mode: .clean, preferences: prefs),
            "\(section) must be off in stock clean view")
        #expect(
            MonitorChromePolicy.showsSection(section, mode: .live, preferences: prefs),
            "\(section) must be on in stock live view")
    }
}

@Test func batteryIndicatorsHideOnRequestPerDispMode() {
    var prefs = OperatorPreferences.defaults
    #expect(MonitorChromePolicy.showsBatteryIndicators(mode: .live, preferences: prefs))
    #expect(MonitorChromePolicy.showsBatteryIndicators(mode: .command, preferences: prefs))
    // Clean ships bare, so its own configuration already has them off.
    #expect(!MonitorChromePolicy.showsBatteryIndicators(mode: .clean, preferences: prefs))

    for mode in DispMode.allCases {
        prefs.toggleChrome(.batteryIndicators, for: mode)
    }
    #expect(!MonitorChromePolicy.showsBatteryIndicators(mode: .live, preferences: prefs))
    #expect(!MonitorChromePolicy.showsBatteryIndicators(mode: .command, preferences: prefs))
    // Clean's toggle flipped the other way — the point of per-mode chrome.
    #expect(MonitorChromePolicy.showsBatteryIndicators(mode: .clean, preferences: prefs))
}

@Test func assistConfigurationPersistsThroughJSONRoundTrip() throws {
    var configuration = AssistConfiguration.defaults
    configuration.grid = AssistConfiguration.Grid(thirds: true, phi: true, diagonal: false)
    configuration.desqueeze = AssistConfiguration.Desqueeze(
        // factor is source of truth; ratio chip follows when it matches a preset
        enabled: true,
        ratio: .x165,
        orientation: .vertical
    )
    configuration.guides.maskEnabled = true

    let data = try JSONEncoder().encode(configuration)
    let decoded = try JSONDecoder().decode(AssistConfiguration.self, from: data)

    #expect(decoded == configuration)
}

@Test func assistConfigurationCarriesWiredViewAssistSettings() throws {
    var configuration = AssistConfiguration.defaults
    configuration.falseColorScale = .limits
    configuration.zebra.highlightIRE = 88
    configuration.zebra.midtoneEnabled = false
    configuration.peakingColor = .green
    configuration.peakingSensitivity = .high
    configuration.scopes.crushClipCompensation = .threeQuarter

    let data = try JSONEncoder().encode(configuration)
    let decoded = try JSONDecoder().decode(AssistConfiguration.self, from: data)

    #expect(decoded.falseColorScale == .limits)
    #expect(decoded.zebra.highlightIRE == 88)
    #expect(!decoded.zebra.midtoneEnabled)
    #expect(decoded.peakingColor == .green)
    #expect(decoded.peakingSensitivity == .high)
    #expect(decoded.scopes.crushClipCompensation == .threeQuarter)
    #expect(decoded == configuration)
}

@Test func crushClipCompensationClampsLegacyOutOfRangeValues() throws {
    // The earlier range went to 2.0 stops (raw 15/20). Those persisted values must clamp to the
    // new 1.0-stop ceiling — a decode throw here would wipe the whole assist configuration.
    for legacyRaw in [15, 20] {
        let decoded = try JSONDecoder().decode(
            AssistConfiguration.CrushClipCompensation.self,
            from: Data("\(legacyRaw)".utf8)
        )
        #expect(decoded == .one)
    }
    // Unknown low values fall back to the default rather than throwing.
    let junk = try JSONDecoder().decode(
        AssistConfiguration.CrushClipCompensation.self, from: Data("3".utf8))
    #expect(junk == .zero)
}

@Test func assistConfigurationDecodesOlderJSONWithoutTheNewKeys() throws {
    // A config saved before these wired keys existed must still load: dropping them from a current
    // encoding must decode with their defaults, not fail and wipe the whole config.
    let data = try JSONEncoder().encode(AssistConfiguration.defaults)
    var dict = try #require(
        try JSONSerialization.jsonObject(with: data) as? [String: Any])
    for key in [
        "falseColorScale", "zebraHighlightIRE", "peakingColor", "peakingSensitivity", "scopes",
    ] {
        dict.removeValue(forKey: key)
    }
    let stripped = try JSONSerialization.data(withJSONObject: dict)

    let decoded = try JSONDecoder().decode(AssistConfiguration.self, from: stripped)
    #expect(decoded.falseColorScale == .stops)
    #expect(decoded.zebra.highlightIRE == 100)
    #expect(decoded.peakingColor == .red)
    #expect(decoded.peakingSensitivity == .medium)
    #expect(decoded.scopes == AssistConfiguration.Scopes())
    #expect(decoded.scopes.crushClipCompensation == .quarter)
}

@Test func assistConfigurationIgnoresRemovedFalseColorSettings() throws {
    let data = try JSONEncoder().encode(AssistConfiguration.defaults)
    var dict = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    dict["falseColorSkinReferenceEnabled"] = false
    dict["falseColorCurve"] = "Log3G10"
    let payload = try JSONSerialization.data(withJSONObject: dict)
    let decoded = try JSONDecoder().decode(AssistConfiguration.self, from: payload)
    #expect(decoded == AssistConfiguration.defaults)
    let reencoded = try #require(
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any])
    #expect(reencoded["falseColorCurve"] == nil)
}

@Test func scopeDecodeIgnoresLegacyWaveformSkinToneKey() throws {
    let legacy =
        #"{"waveformSkinTone":{"enabled":true,"color":"Rose"},"waveformMode":"RGB"}"#
    let decoded = try JSONDecoder().decode(
        AssistConfiguration.Scopes.self, from: Data(legacy.utf8))
    #expect(decoded.waveformMode == .rgb)
    #expect(decoded.waveformGuides == AssistConfiguration.Scopes.GuideLines())
}

@Test func scopeSettingsRoundTripThroughJSON() throws {
    var configuration = AssistConfiguration.defaults
    configuration.scopes.waveformMode = .rgb
    configuration.scopes.waveformScale = 1.4
    configuration.scopes.waveformGuides.crush = false
    configuration.scopes.waveformBrightness = 150
    configuration.scopes.paradeMode = .yrgb
    configuration.scopes.paradeGuides.middle = false
    configuration.scopes.paradeBrightness = 80
    configuration.scopes.histogramScale = 0.7
    configuration.scopes.histogramTrafficLights = false
    configuration.scopes.crushClipCompensation = .half

    let decoded = try JSONDecoder().decode(
        AssistConfiguration.self, from: try JSONEncoder().encode(configuration))
    #expect(decoded.scopes == configuration.scopes)
    #expect(decoded.scopes.waveformMode == .rgb)
    #expect(decoded.scopes.waveformScale == 1.4)
    #expect(!decoded.scopes.waveformGuides.crush)
    #expect(decoded.scopes.waveformGuides.clip)  // untouched flags stay on
    #expect(decoded.scopes.waveformBrightness == 150)
    #expect(decoded.scopes.paradeBrightness == 80)
    #expect(!decoded.scopes.histogramTrafficLights)
    #expect(decoded.scopes.crushClipCompensation == .half)
}

@Test func scopeBrightnessClampsToRangeOnInitAndDecode() throws {
    let range = AssistConfiguration.Scopes.brightnessRange
    let clamped = AssistConfiguration.Scopes(waveformBrightness: 999, paradeBrightness: -10)
    #expect(clamped.waveformBrightness == range.upperBound)
    #expect(clamped.paradeBrightness == range.lowerBound)

    let json = #"{"waveformBrightness": 999, "paradeBrightness": -5}"#
    let decoded = try JSONDecoder().decode(
        AssistConfiguration.Scopes.self, from: Data(json.utf8))
    #expect(decoded.waveformBrightness == range.upperBound)
    #expect(decoded.paradeBrightness == range.lowerBound)

    let legacy = #"{"waveformMode":"RGB"}"#
    let defaults = try JSONDecoder().decode(
        AssistConfiguration.Scopes.self, from: Data(legacy.utf8))
    #expect(defaults.waveformBrightness == AssistConfiguration.Scopes.defaultBrightness)
    #expect(defaults.paradeBrightness == AssistConfiguration.Scopes.defaultBrightness)
}

@Test func legacyWaveformAndParadeBrightnessMigratesToCalibratedScale() throws {
    let json =
        #"{"waveformBrightness":25,"paradeBrightness":50,"vectorscopeBrightness":25}"#
    let decoded = try JSONDecoder().decode(
        AssistConfiguration.Scopes.self, from: Data(json.utf8))

    #expect(decoded.waveformBrightness == 100)
    #expect(decoded.paradeBrightness == 200)
    #expect(decoded.vectorscopeBrightness == 25)
}

@Test func legacyWaveformAndParadeBrightnessAboveNewVisualMaximumClamps() throws {
    let json = #"{"waveformBrightness":51,"paradeBrightness":200}"#
    let decoded = try JSONDecoder().decode(
        AssistConfiguration.Scopes.self, from: Data(json.utf8))

    #expect(decoded.waveformBrightness == 200)
    #expect(decoded.paradeBrightness == 200)
}

@Test func calibratedWaveformAndParadeBrightnessMultiplierUsesQuarterStrengthBaseline() {
    #expect(AssistConfiguration.Scopes.waveformParadeBrightnessMultiplier(0) == 0)
    #expect(AssistConfiguration.Scopes.waveformParadeBrightnessMultiplier(100) == 0.25)
    #expect(AssistConfiguration.Scopes.waveformParadeBrightnessMultiplier(200) == 0.5)
    #expect(AssistConfiguration.Scopes.brightnessMultiplier(100) == 1)
}

@Test func operatorPreferencesDefaultBarVisibilityIncludesAllTools() {
    let preferences = OperatorPreferences.defaults
    #expect(
        preferences.exposureBarVisibleControls == Set(MonitorAssistTool.exposureBarTools))
    #expect(
        preferences.framingBarVisibleControls == Set(MonitorAssistTool.framingBarTools))
    for tool in MonitorAssistTool.exposureBarTools {
        #expect(preferences.isAssistToolbarButtonVisible(tool))
    }
    for tool in MonitorAssistTool.framingBarTools {
        #expect(preferences.isAssistToolbarButtonVisible(tool))
    }
    #expect(preferences.isAssistToolbarButtonVisible(.lut))
}

@Test func reconcileSurfacesNewToolsOnTheirBars() {
    var preferences = OperatorPreferences.defaults
    // Simulate a blob saved before the vectorscope/audio tools existed: the persisted order and
    // visible sets lack them — and the operator has deliberately hidden the parade button.
    preferences.assistToolbarOrder.removeAll { $0 == .vectorscope || $0 == .audioMeters }
    preferences.exposureBarVisibleControls.remove(.vectorscope)
    preferences.exposureBarVisibleControls.remove(.audioMeters)
    preferences.exposureBarVisibleControls.remove(.parade)

    preferences.reconcileAssistTools()

    #expect(preferences.assistToolbarOrder.contains(.vectorscope))
    #expect(preferences.assistToolbarOrder.contains(.audioMeters))
    #expect(preferences.exposureBarVisibleControls.contains(.vectorscope))
    #expect(preferences.exposureBarVisibleControls.contains(.audioMeters))
    // A deliberately hidden tool stays hidden — reconcile only surfaces never-seen tools.
    #expect(!preferences.exposureBarVisibleControls.contains(.parade))
}

@Test func operatorPreferencesBarVisibilityRoundTrips() throws {
    var preferences = OperatorPreferences.defaults
    preferences.exposureBarVisibleControls = [.peaking, .zebra]
    preferences.framingBarVisibleControls = [.guides, .desqueeze]
    let decoded = try JSONDecoder().decode(
        OperatorPreferences.self, from: try JSONEncoder().encode(preferences))
    #expect(decoded.exposureBarVisibleControls == [.peaking, .zebra])
    #expect(decoded.framingBarVisibleControls == [.guides, .desqueeze])
}

@Test func operatorPreferencesDecodesOlderJSONWithoutBarVisibilityKeys() throws {
    let data = try JSONEncoder().encode(OperatorPreferences.defaults)
    var dict = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    dict.removeValue(forKey: "exposureBarVisibleControls")
    dict.removeValue(forKey: "framingBarVisibleControls")
    let decoded = try JSONDecoder().decode(
        OperatorPreferences.self,
        from: try JSONSerialization.data(withJSONObject: dict))
    #expect(
        decoded.exposureBarVisibleControls == Set(MonitorAssistTool.exposureBarTools))
    #expect(
        decoded.framingBarVisibleControls == Set(MonitorAssistTool.framingBarTools))
}

@Test func operatorPreferencesToggleBarControls() {
    var preferences = OperatorPreferences.defaults
    preferences.toggleExposureBarControl(.peaking)
    #expect(!preferences.exposureBarVisibleControls.contains(.peaking))
    preferences.toggleExposureBarControl(.peaking)
    #expect(preferences.exposureBarVisibleControls.contains(.peaking))
    preferences.toggleFramingBarControl(.grid)
    #expect(!preferences.framingBarVisibleControls.contains(.grid))
}

@Test func assistToolbarOrderMovingReordersWithoutDuplicates() {
    let order = MonitorAssistTool.allCases
    let moved = AssistToolbarOrder.moving(.histogram, to: 0, in: order)
    #expect(moved.first == .histogram)
    #expect(Set(moved).count == order.count)
}

@Test func scopeScaleClampsToRangeOnInitAndDecode() throws {
    let range = AssistConfiguration.Scopes.scaleRange
    // The init clamps absurd values into the usable band.
    let clamped = AssistConfiguration.Scopes(waveformScale: 99, histogramScale: 0.01)
    #expect(clamped.waveformScale == range.upperBound)
    #expect(clamped.histogramScale == range.lowerBound)

    // A persisted out-of-range value is pulled back in on decode too.
    let json = #"{"waveformScale": 99, "paradeScale": -5}"#
    let decoded = try JSONDecoder().decode(
        AssistConfiguration.Scopes.self, from: Data(json.utf8))
    #expect(decoded.waveformScale == range.upperBound)
    #expect(decoded.paradeScale == range.lowerBound)
    #expect(decoded.histogramScale == AssistConfiguration.Scopes.defaultScale)  // missing → default
}

@Test func scopeDecodeIgnoresRemovedSizePresetKeys() throws {
    // A config saved while scopes still used the Small/Medium/Large size preset must still load —
    // the old size keys are ignored and the scale falls back to the default.
    let legacy = #"{"waveformSize":"Large","paradeSize":"Small","waveformMode":"RGB"}"#
    let decoded = try JSONDecoder().decode(
        AssistConfiguration.Scopes.self, from: Data(legacy.utf8))
    #expect(decoded.waveformScale == AssistConfiguration.Scopes.defaultScale)
    #expect(decoded.paradeScale == AssistConfiguration.Scopes.defaultScale)
    #expect(decoded.waveformMode == .rgb)  // a still-valid key is honoured
}

@Test func scopeDecodeMigratesLegacyHistogramTrafficSensitivityPercent() throws {
    // Percent presets 0/5/10 map 1:1 to the current raw values; 15/20 predate the 1.0-stop
    // ceiling and clamp to `.one`.
    let legacy = #"{"histogramTrafficSensitivity":15}"#
    let decoded = try JSONDecoder().decode(
        AssistConfiguration.Scopes.self, from: Data(legacy.utf8))
    #expect(decoded.crushClipCompensation == .one)
}

/// Builds an `AssistConfiguration` JSON blob whose scopes/trafficLights sub-blobs mimic the
/// split-compensation era (no shared `crushClipCompensation` key under scopes).
private func splitEraConfiguration(
    scopes scopeOverrides: [String: Any], trafficLights: [String: Any]
) throws -> Data {
    var dict = try #require(
        try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(AssistConfiguration.defaults)) as? [String: Any])
    var scopes = try #require(dict["scopes"] as? [String: Any])
    scopes.removeValue(forKey: "crushClipCompensation")
    for (key, value) in scopeOverrides { scopes[key] = value }
    dict["scopes"] = scopes
    dict["trafficLights"] = trafficLights
    return try JSONSerialization.data(withJSONObject: dict)
}

@Test func compensationReunificationHonorsCustomizedHistogramValue() throws {
    // A split-era customized histogram value (here the pre-ceiling 15 under the even older
    // key name) wins the shared setting; the traffic-lights copy is ignored beside it.
    let decoded = try JSONDecoder().decode(
        AssistConfiguration.self,
        from: try splitEraConfiguration(
            scopes: ["histogramNoiseFloorCompensation": 15],
            trafficLights: ["scale": 1.2, "crushClipCompensation": 5]))
    #expect(decoded.scopes.crushClipCompensation == .one)  // 1.5 stops clamps to the 1.0 ceiling
    #expect(decoded.trafficLights.scale == 1.2)
}

@Test func compensationReunificationFoldsInCustomizedTrafficLightsValue() throws {
    // Split-era configs where only the traffic-lights copy was customized (histogram stayed at
    // the old `.zero` default) keep that customization in the shared setting.
    let decoded = try JSONDecoder().decode(
        AssistConfiguration.self,
        from: try splitEraConfiguration(
            scopes: ["histogramCrushClipCompensation": 0],
            trafficLights: ["scale": 1.0, "crushClipCompensation": 7]))
    #expect(decoded.scopes.crushClipCompensation == .threeQuarter)
}

@Test func compensationReunificationUpgradesUntouchedZeroToQuarterDefault() throws {
    // The split era always encoded both copies, so stored zeros (the old default) are
    // indistinguishable from "never touched" and adopt the new shared `.quarter` default.
    let decoded = try JSONDecoder().decode(
        AssistConfiguration.self,
        from: try splitEraConfiguration(
            scopes: ["histogramCrushClipCompensation": 0],
            trafficLights: ["scale": 1.0, "crushClipCompensation": 0]))
    #expect(decoded.scopes.crushClipCompensation == .quarter)
}

@Test func sharedCompensationExplicitZeroRoundTrips() throws {
    // Post-unification, `.zero` is a deliberate choice (the default is `.quarter`) and must
    // survive a round trip rather than being "migrated" back up.
    var configuration = AssistConfiguration.defaults
    configuration.scopes.crushClipCompensation = .zero
    let decoded = try JSONDecoder().decode(
        AssistConfiguration.self, from: try JSONEncoder().encode(configuration))
    #expect(decoded.scopes.crushClipCompensation == .zero)
}

@Test func assistConfigurationDecodesRenamedHistogramCompensationKey() throws {
    let decoded = try JSONDecoder().decode(
        AssistConfiguration.self,
        from: try splitEraConfiguration(
            scopes: ["histogramCrushClipCompensation": 5],
            trafficLights: ["scale": 1.0]))
    #expect(decoded.scopes.crushClipCompensation == .half)
}

@Test func operatorPreferencesBluetoothShutterDefaultsOnAndRoundTrips() throws {
    // On by default — a paired remote should just work; the settings row is the opt-out.
    #expect(OperatorPreferences.defaults.bluetoothShutterEnabled)

    var prefs = OperatorPreferences.defaults
    prefs.bluetoothShutterEnabled = false
    let decoded = try JSONDecoder().decode(
        OperatorPreferences.self, from: try JSONEncoder().encode(prefs))
    // An explicitly saved opt-out survives the default-on migration.
    #expect(!decoded.bluetoothShutterEnabled)
}

@Test func operatorPreferencesBluetoothShutterToleratesLegacyPayloads() throws {
    var dict = try #require(
        try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(OperatorPreferences.defaults)) as? [String: Any])
    dict.removeValue(forKey: "bluetoothShutterEnabled")
    let decoded = try JSONDecoder().decode(
        OperatorPreferences.self,
        from: try JSONSerialization.data(withJSONObject: dict))
    // A payload predating the key means the user never chose — the new default-on applies.
    #expect(decoded.bluetoothShutterEnabled)
}

// MARK: - Clean view (#256)

@Test func cleanViewPinsDefaultOffAndToleratePayloadsPredatingThem() throws {
    #expect(OperatorPreferences.defaults.cleanViewPinnedTools.isEmpty)

    var dict = try #require(
        try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(OperatorPreferences.defaults)) as? [String: Any])
    dict.removeValue(forKey: "cleanViewPinnedTools")
    let decoded = try JSONDecoder().decode(
        OperatorPreferences.self,
        from: try JSONSerialization.data(withJSONObject: dict))
    #expect(decoded.cleanViewPinnedTools.isEmpty)
    // The rest of the blob must survive — a missing new key never resets the preferences.
    #expect(decoded.dispOrder == OperatorPreferences.defaults.dispOrder)
    #expect(decoded.streamPreset == OperatorPreferences.defaults.streamPreset)
}

@Test func cleanViewPinsRoundTrip() throws {
    var prefs = OperatorPreferences.defaults
    prefs.toggleCleanViewPin(.guides)
    prefs.toggleCleanViewPin(.histogram)
    prefs.toggleCleanViewPin(.histogram)  // second toggle un-pins
    let decoded = try JSONDecoder().decode(
        OperatorPreferences.self, from: try JSONEncoder().encode(prefs))
    #expect(decoded.cleanViewPinnedTools == [.guides])
}

@Test func cleanViewHidesEveryUnpinnedToolByDefault() {
    var prefs = OperatorPreferences.defaults
    prefs.liveViewVisibleAssistTools = Set(MonitorAssistTool.allCases)

    for tool in MonitorAssistTool.allCases {
        #expect(
            MonitorChromePolicy.isToolVisible(tool, mode: .live, preferences: prefs),
            "\(tool) must show in live")
        #expect(
            !MonitorChromePolicy.isToolVisible(tool, mode: .clean, preferences: prefs),
            "\(tool) must be hidden in clean by default")
        #expect(
            !MonitorChromePolicy.isToolVisible(tool, mode: .command, preferences: prefs),
            "\(tool) must be hidden in command")
    }
    #expect(MonitorChromePolicy.visibleTools(mode: .clean, preferences: prefs).isEmpty)
    #expect(MonitorChromePolicy.visibleTools(mode: .command, preferences: prefs).isEmpty)
}

@Test func cleanViewShowsExactlyThePinnedToolsAndRestoresOnLeaving() {
    var prefs = OperatorPreferences.defaults
    prefs.liveViewVisibleAssistTools = [.histogram, .peaking, .guides]
    prefs.toggleCleanViewPin(.peaking)

    #expect(MonitorChromePolicy.visibleTools(mode: .clean, preferences: prefs) == [.peaking])
    // Leaving clean restores the operator's set untouched — the pin only ever filters.
    #expect(
        MonitorChromePolicy.visibleTools(mode: .live, preferences: prefs)
            == [.histogram, .peaking, .guides])
}

@Test func cleanViewPinCannotResurrectASwitchedOffTool() {
    var prefs = OperatorPreferences.defaults
    prefs.liveViewVisibleAssistTools = []
    prefs.toggleCleanViewPin(.waveform)
    #expect(!MonitorChromePolicy.isToolVisible(.waveform, mode: .clean, preferences: prefs))
}

@Test func cleanViewPinsAreLiveViewOnly() {
    var prefs = OperatorPreferences.defaults
    prefs.playbackVisibleAssistTools = [.histogram]
    // Playback has no DISP cycle; callers pass `.live` and see the full playback set.
    #expect(
        MonitorChromePolicy.isToolVisible(
            .histogram, mode: .live, context: .playback, preferences: prefs))
}

@Test func cleanViewStripsChromeAndDefersPopups() {
    #expect(MonitorChromePolicy.showsChrome(in: .live))
    #expect(!MonitorChromePolicy.showsChrome(in: .clean))
    #expect(MonitorChromePolicy.allowsPopups(in: .live))
    #expect(!MonitorChromePolicy.allowsPopups(in: .clean))
    // Command's dashboard tiles open the value pickers, so pop-ups stay allowed there.
    #expect(MonitorChromePolicy.allowsPopups(in: .command))
}

@Test func commandKeepsTheHeaderStreamUpForLiveTimecode() {
    // Timecode rides the live-view frame header only, so the mode that shows a hero timecode and
    // no image must not end live view (#271).
    #expect(MonitorChromePolicy.streamsHeaderOnly(in: .command))
    #expect(!MonitorChromePolicy.streamsHeaderOnly(in: .live))
    #expect(!MonitorChromePolicy.streamsHeaderOnly(in: .clean))
}
// MARK: - Edit view badge placement

@Test func editBadgesTakeACornerOfTheirOwnElementAndNeverStackUp() throws {
    // Real measured landscape boxes from an iPhone 15 Pro (852x393): the four readouts nest inside
    // the status bar, and the rail and camera-value strip sit flush against the screen edges.
    let boxes: [MonitorChromeEditLayout.Box] = [
        .init(section: .statusBar, frame: MonitorModuleFrame(x: 69, y: 16, width: 678, height: 42)),
        .init(
            section: .sideRails, frame: MonitorModuleFrame(x: 763, y: 14, width: 83, height: 289)),
        .init(
            section: .assistToolbar,
            frame: MonitorModuleFrame(x: 16, y: 321, width: 344, height: 58)),
        .init(
            section: .cameraValues,
            frame: MonitorModuleFrame(x: 368, y: 321, width: 466, height: 58)),
        .init(section: .lockButton, frame: MonitorModuleFrame(x: 16, y: 17, width: 40, height: 40)),
        .init(
            section: .batteryIndicators,
            frame: MonitorModuleFrame(x: 8, y: 63, width: 41, height: 35)),
        .init(section: .recReadout, frame: MonitorModuleFrame(x: 81, y: 23, width: 67, height: 27)),
        .init(
            section: .codecReadout, frame: MonitorModuleFrame(x: 377, y: 22, width: 98, height: 30)),
        .init(
            section: .mediaReadout, frame: MonitorModuleFrame(x: 485, y: 22, width: 132, height: 30)
        ),
        .init(
            section: .fpsReadout, frame: MonitorModuleFrame(x: 627, y: 22, width: 108, height: 29)),
    ]

    let frames = MonitorChromeEditLayout.badgeFrames(
        boxes, viewportWidth: 852, viewportHeight: 393)

    #expect(frames.count == boxes.count, "every measured element must get a badge")
    for (section, frame) in frames {
        #expect(frame.x >= 0 && frame.y >= 0, "\(section) badge ran off the top or leading edge")
        #expect(
            frame.x + frame.width <= 852 && frame.y + frame.height <= 393,
            "\(section) badge ran off the trailing or bottom edge")
        // Still reads as belonging to its element: the centre stays within one badge of the box.
        let box = try #require(boxes.first { $0.section == section }).frame
        let pad = MonitorChromeEditLayout.badgeSize
        #expect(
            frame.midX >= box.x - pad && frame.midX <= box.x + box.width + pad
                && frame.midY >= box.y - pad && frame.midY <= box.y + box.height + pad,
            "\(section) badge drifted away from the element it controls")
    }
    // No two badges collide — the readouts nested inside the status bar are the hard case.
    let all = Array(frames.values)
    for i in all.indices {
        for j in all.indices where j > i {
            let a = all[i]
            let b = all[j]
            let apart =
                a.x + a.width <= b.x || b.x + b.width <= a.x || a.y + a.height <= b.y
                || b.y + b.height <= a.y
            #expect(apart, "two badges overlap at \(a) and \(b)")
        }
    }
}

@Test func editBadgeLayoutSkipsUnmeasuredElements() {
    let frames = MonitorChromeEditLayout.badgeFrames(
        [
            .init(section: .statusBar, frame: MonitorModuleFrame(x: 0, y: 0, width: 0, height: 0)),
            .init(
                section: .lockButton, frame: MonitorModuleFrame(x: 16, y: 17, width: 40, height: 40)
            ),
        ],
        viewportWidth: 852, viewportHeight: 393)

    #expect(frames[.statusBar] == nil)
    #expect(frames[.lockButton] != nil)
}

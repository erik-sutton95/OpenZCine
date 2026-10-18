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

@Test func operatorPreferencesDefaultAutoRotateFeedEnabled() {
    #expect(OperatorPreferences.defaults.autoRotateFeedEnabled)
}

@Test func operatorPreferencesAutoRotateFeedRoundTripsAndOlderBlobsDecodeToOn() throws {
    var preferences = OperatorPreferences.defaults
    preferences.autoRotateFeedEnabled = false
    let decoded = try JSONDecoder().decode(
        OperatorPreferences.self, from: try JSONEncoder().encode(preferences))
    #expect(!decoded.autoRotateFeedEnabled)

    var dict = try #require(
        try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(OperatorPreferences.defaults)) as? [String: Any])
    dict.removeValue(forKey: "autoRotateFeedEnabled")
    let legacy = try JSONDecoder().decode(
        OperatorPreferences.self,
        from: try JSONSerialization.data(withJSONObject: dict))
    #expect(legacy.autoRotateFeedEnabled)
}

@Test func theDispKeyCanNeverBeHidden() {
    // The only visible way to change mode. It was briefly a switch with the feed swipe as the
    // fallback; an escape route the operator has to already know about is not an escape route.
    for mode in DispMode.allCases {
        #expect(!DisplayChromeVisibility.isConfigurable(.railDisp, in: mode))
        #expect(!DisplayChromeVisibility.configurableSections(in: mode).contains(.railDisp))
    }

    // And it renders even with every stored flag off, in every mode and capture side.
    var preferences = OperatorPreferences.defaults
    for mode in DispMode.allCases {
        for capture in CaptureLayoutMode.allCases {
            var chrome = preferences.chrome(for: mode, capture: capture)
            for section in DisplayChromeVisibility.Section.allCases
            where chrome.isVisible(section) {
                chrome.toggle(section)
            }
            preferences.setChrome(chrome, for: mode, capture: capture)

            let plan = MonitorChromePolicy.sideRailPlan(
                mode: mode, preferences: preferences, capture: capture,
                interfaceLocked: false, recordingOrPending: false)
            #expect(plan.disp, "DISP key vanished in \(mode)/\(capture)")
        }
    }
}

@Test func qualityBiasOffersAllThreeGradesWithOneLabelEach() {
    // The control used to have two positions, so "Size" named both .latency and .balanced — and
    // Android wrote .latency for it while iOS left .balanced in place. One label per grade means
    // a given label is now the same compression byte on both shells.
    let labels = LiveViewQualityBias.allCases.map(\.settingsLabel)
    #expect(labels.count == 3)
    #expect(Set(labels).count == 3)
    #expect(LiveViewQualityBias.balanced.settingsLabel == "Balanced")

    // Both controls step the same latency-against-detail axis, so they share one vocabulary.
    #expect(labels == LiveViewStreamPreset.allCases.map(\.rawValue))

    // Each label round-trips to exactly the grade it names.
    for bias in LiveViewQualityBias.allCases {
        let matched = LiveViewQualityBias.allCases.filter {
            $0.settingsLabel == bias.settingsLabel
        }
        #expect(matched == [bias])
    }

    // And the middle grade is a real, distinct byte on the wire — not a UI-only position.
    let bytes = LiveViewQualityBias.allCases.map(\.liveViewImageCompression)
    #expect(Set(bytes).count == 3)
    #expect(
        LiveViewQualityBias.balanced.liveViewImageCompression
            != LiveViewQualityBias.latency.liveViewImageCompression)
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
    // Which assists are on is the shared assist state's; the app's tests pin its fresh defaults.
}

@Test func portraitFeedAspectDefaultsAndRoundTrips() throws {
    var prefs = OperatorPreferences.defaults
    #expect(prefs.portraitFeedAspect == .fit16x9)
    prefs.portraitFeedAspect = .fill
    let data = try JSONEncoder().encode(prefs)
    let decoded = try JSONDecoder().decode(OperatorPreferences.self, from: data)
    #expect(decoded.portraitFeedAspect == .fill)
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
    // never strand an operator who locked first and hid it after. Clean can now carry (and
    // therefore engage) the lock, so the guarantee has to hold there too.
    var prefs = OperatorPreferences.defaults
    for mode in DispMode.allCases {
        prefs.setChrome(
            {
                var chrome = prefs.chrome(for: mode, capture: .video)
                chrome.lockButtonVisible = false
                return chrome
            }(), for: mode, capture: .video)
    }

    for mode in DispMode.allCases {
        #expect(
            !MonitorChromePolicy.showsLockControl(
                mode: mode, preferences: prefs, capture: .video, interfaceLocked: false),
            "\(mode) must honour the hide while unlocked")
        #expect(
            MonitorChromePolicy.showsLockControl(
                mode: mode, preferences: prefs, capture: .video, interfaceLocked: true),
            "\(mode) must reveal the lock key while locked")
        #expect(
            MonitorChromePolicy.sideRailPlan(
                mode: mode, preferences: prefs, capture: .video, interfaceLocked: true,
                recordingOrPending: false
            ).lock)
    }
    // Clean ships with the key off, so the stock configuration exercises the same guarantee.
    #expect(
        MonitorChromePolicy.showsLockControl(
            mode: .clean, preferences: OperatorPreferences.defaults, capture: .video,
            interfaceLocked: true))
}

@Test func everyRailControlIsHideableButRecordAndSettingsCannotStrandTheOperator() {
    var prefs = OperatorPreferences.defaults
    let full = MonitorChromePolicy.sideRailPlan(
        mode: .live, preferences: prefs, capture: .video, interfaceLocked: false,
        recordingOrPending: false)
    #expect(full.disp && full.record && full.media && full.settings)

    // Every rail control off, in every enabled mode.
    for mode in DispMode.allCases {
        for section in DisplayChromeVisibility.Section.railControls {
            prefs.toggleChrome(section, for: mode, capture: .video)
        }
    }
    let stripped = MonitorChromePolicy.sideRailPlan(
        mode: .live, preferences: prefs, capture: .video, interfaceLocked: false,
        recordingOrPending: false)
    #expect(stripped.disp, "the DISP key is never hideable — it is the only way to change mode")
    #expect(!stripped.media)
    #expect(!stripped.record, "standby record is the operator's to hide")
    #expect(stripped.settings, "Settings is the only route back to these switches")

    // Rolling: the record control comes back regardless of configuration.
    #expect(
        MonitorChromePolicy.sideRailPlan(
            mode: .live, preferences: prefs, capture: .video, interfaceLocked: false,
            recordingOrPending: true
        ).record)
}

@Test func hidingSettingsInOneModeIsHonouredWhileAnotherModeStillCarriesIt() {
    var prefs = OperatorPreferences.defaults
    prefs.toggleChrome(.railSettings, for: .clean, capture: .video)

    #expect(
        !MonitorChromePolicy.sideRailPlan(
            mode: .clean, preferences: prefs, capture: .video, interfaceLocked: false,
            recordingOrPending: false
        ).settings,
        "DISP 1 still has Settings, so clean's hide is real")
    #expect(
        MonitorChromePolicy.sideRailPlan(
            mode: .live, preferences: prefs, capture: .video, interfaceLocked: false,
            recordingOrPending: false
        ).settings)

    // Only the enabled modes count — a Settings key on a mode the DISP key never reaches is not a
    // route back.
    prefs.toggleChrome(.railSettings, for: .live, capture: .video)
    prefs.enabledDispModes = [.live, .clean]
    #expect(
        MonitorChromePolicy.sideRailPlan(
            mode: .live, preferences: prefs, capture: .video, interfaceLocked: false,
            recordingOrPending: false
        ).settings,
        "no enabled mode carries Settings, so it must come back")
}

// MARK: - Per-DISP-mode chrome

@Test func chromeIsConfiguredPerDispModeAndDefaultsToABareClean() {
    let prefs = OperatorPreferences.defaults

    #expect(prefs.chrome(for: .live, capture: .video) == DisplayChromeVisibility())
    #expect(prefs.chrome(for: .clean, capture: .video) == DisplayChromeVisibility.cleanDefaults)
    #expect(prefs.chrome(for: .command, capture: .video) == DisplayChromeVisibility())

    // Clean's stock look: a bare image plus the rail, the focus box and the batteries.
    let clean = prefs.chrome(for: .clean, capture: .video)
    #expect(!clean.statusBarVisible)
    #expect(!clean.assistToolbarVisible)
    #expect(!clean.cameraValuesVisible)
    #expect(!clean.lockButtonVisible)
    #expect(clean.batteryIndicatorsVisible)
    #expect(clean.focusBoxVisible)
    #expect(clean.railDispVisible && clean.railRecordVisible)
    #expect(clean.railMediaVisible && clean.railSettingsVisible)
}

@Test func togglingOneModesChromeLeavesTheOthersAlone() {
    var prefs = OperatorPreferences.defaults
    prefs.toggleChrome(.statusBar, for: .clean, capture: .video)

    #expect(prefs.chrome(for: .clean, capture: .video).statusBarVisible)
    #expect(prefs.chrome(for: .live, capture: .video).statusBarVisible)
    prefs.toggleChrome(.statusBar, for: .live, capture: .video)
    #expect(!prefs.chrome(for: .live, capture: .video).statusBarVisible)
    #expect(prefs.chrome(for: .clean, capture: .video).statusBarVisible)

    prefs.resetChrome(for: .clean, capture: .video)
    #expect(!prefs.chrome(for: .clean, capture: .video).statusBarVisible)
    #expect(
        !prefs.chrome(for: .live, capture: .video).statusBarVisible,
        "resetting one mode must not touch another")
}

@Test func videoAndPhotoLayoutsAreIndependent() {
    var prefs = OperatorPreferences.defaults
    prefs.toggleChrome(.assistToolbar, for: .live, capture: .photo)

    #expect(!prefs.chrome(for: .live, capture: .photo).assistToolbarVisible)
    #expect(
        prefs.chrome(for: .live, capture: .video).assistToolbarVisible,
        "a stills operator's layout must not reshape the cinema one")

    prefs.resetChrome(for: .live, capture: .photo)
    #expect(prefs.chrome(for: .live, capture: .photo).assistToolbarVisible)
}

@Test func cleanOffersExactlyTheSameElementsAsLive() {
    // Clean is DISP 1 with different defaults, not a smaller feature.
    #expect(
        DisplayChromeVisibility.configurableSections(in: .clean)
            == DisplayChromeVisibility.configurableSections(in: .live))
    #expect(DisplayChromeVisibility.isConfigurable(.lockButton, in: .clean))
    for section in DisplayChromeVisibility.Section.railControls {
        #expect(
            DisplayChromeVisibility.isConfigurable(section, in: .clean)
                == DisplayChromeVisibility.isConfigurable(section, in: .live),
            "clean and live must offer the same elements, including the ones neither offers")
    }
}

@Test func sectionsAModeDoesNotOwnAreNotToggleable() {
    // Command has no feed, so no status bar, readouts, strips or AF box to reveal — the rail
    // cluster only. `sideRails` is the retired whole-rail blob and belongs to nobody.
    #expect(!DisplayChromeVisibility.isConfigurable(.statusBar, in: .command))
    #expect(!DisplayChromeVisibility.isConfigurable(.focusBox, in: .command))
    #expect(!DisplayChromeVisibility.isConfigurable(.sideRails, in: .live))
    #expect(!DisplayChromeVisibility.isConfigurable(.sideRails, in: .clean))
    #expect(!DisplayChromeVisibility.isConfigurable(.sideRails, in: .command))
    #expect(DisplayChromeVisibility.isConfigurable(.lockButton, in: .command))
    // 15, not 16: the DISP key is never offered anywhere (see `theDispKeyCanNeverBeHidden`).
    #expect(DisplayChromeVisibility.configurableSections(in: .live).count == 15)
    #expect(!DisplayChromeVisibility.isConfigurable(.railDisp, in: .live))
    #expect(
        DisplayChromeVisibility.configurableSections(in: .command) == [
            .lockButton, .batteryIndicators, .railRecord, .railMedia, .railSettings,
        ])

    var prefs = OperatorPreferences.defaults
    prefs.toggleChrome(.statusBar, for: .command, capture: .video)
    #expect(
        prefs.chrome(for: .command, capture: .video).statusBarVisible,
        "a non-owned section must not flip")
}

@Test func olderPayloadsMigrateTheGlobalChromeOntoDisp1AndDisp3() throws {
    // The single stored set was the global one. It becomes DISP 1's, DISP 3 inherits it so a
    // hidden rail stays hidden on the dashboard, and DISP 2 lands on the documented bare image.
    var prefs = OperatorPreferences.defaults
    prefs.displayChrome.batteryIndicatorsVisible = false
    var dict = try #require(
        try JSONSerialization.jsonObject(with: try JSONEncoder().encode(prefs)) as? [String: Any])
    dict.removeValue(forKey: "cleanChromeV2")
    dict.removeValue(forKey: "commandChrome")
    dict.removeValue(forKey: "photoDisplayChrome")
    dict.removeValue(forKey: "photoCleanChrome")
    dict.removeValue(forKey: "photoCommandChrome")

    let decoded = try JSONDecoder().decode(
        OperatorPreferences.self, from: try JSONSerialization.data(withJSONObject: dict))

    #expect(decoded.chrome(for: .live, capture: .video) == prefs.displayChrome)
    #expect(decoded.chrome(for: .command, capture: .video) == prefs.displayChrome)
    #expect(decoded.chrome(for: .clean, capture: .video) == DisplayChromeVisibility.cleanDefaults)
    // Every DISP mode's configuration carries into BOTH capture sides, so nothing moves the first
    // time the body switches to stills.
    for mode in DispMode.allCases {
        #expect(
            decoded.chrome(for: mode, capture: .photo) == decoded.chrome(for: mode, capture: .video)
        )
    }
    // The rest of the blob survives — a missing new key never resets the preferences.
    #expect(decoded.dispOrder == OperatorPreferences.defaults.dispOrder)
    #expect(decoded.streamPreset == OperatorPreferences.defaults.streamPreset)
}

@Test func aStoredSideRailBlobExpandsToAllFourRailControls() throws {
    // The rail used to be one switch. An operator who hid it must not find it back on their
    // monitor after the split — the single stored value is their choice for all four.
    let legacy =
        #"{"statusBarVisible":true,"sideRailsVisible":false,"assistToolbarVisible":true,"#
        + #""cameraValuesVisible":true}"#
    let hidden = try JSONDecoder().decode(DisplayChromeVisibility.self, from: Data(legacy.utf8))
    #expect(!hidden.railRecordVisible)
    #expect(!hidden.railMediaVisible)
    #expect(!hidden.railSettingsVisible)
    #expect(!hidden.railDispVisible)
    // Elements that were never part of the rail blob keep their own default.
    #expect(hidden.focusBoxVisible)
    #expect(hidden.timecodeReadoutVisible)
    #expect(hidden.resolutionReadoutVisible)

    let kept =
        #"{"statusBarVisible":true,"sideRailsVisible":true,"assistToolbarVisible":true,"#
        + #""cameraValuesVisible":true}"#
    let shown = try JSONDecoder().decode(DisplayChromeVisibility.self, from: Data(kept.utf8))
    #expect(shown.railRecordVisible && shown.railMediaVisible)
    #expect(shown.railSettingsVisible && shown.railDispVisible)
}

@Test func perModeChromeRoundTrips() throws {
    var prefs = OperatorPreferences.defaults
    prefs.toggleChrome(.statusBar, for: .clean, capture: .video)
    prefs.toggleChrome(.fpsReadout, for: .clean, capture: .video)
    prefs.toggleChrome(.railMedia, for: .command, capture: .video)
    prefs.toggleChrome(.focusBox, for: .live, capture: .photo)

    let decoded = try JSONDecoder().decode(
        OperatorPreferences.self, from: try JSONEncoder().encode(prefs))

    #expect(decoded.chrome(for: .clean, capture: .video).statusBarVisible)
    #expect(!decoded.chrome(for: .clean, capture: .video).fpsReadoutVisible)
    #expect(!decoded.chrome(for: .command, capture: .video).railMediaVisible)
    #expect(!decoded.chrome(for: .live, capture: .photo).focusBoxVisible)
    #expect(decoded.chrome(for: .live, capture: .video) == DisplayChromeVisibility())
}

@Test func aBareCleanRendersNothingItWasNotToldTo() {
    let prefs = OperatorPreferences.defaults
    // Clean's stock keeps the rail, the focus box and the batteries — everything an operator needs
    // to work in it and get back out. The status-bar cells stay switched on so putting the bar
    // back yields a complete one; they simply have no bar to render into.
    let cleanKeeps: Set<DisplayChromeVisibility.Section> =
        Set(DisplayChromeVisibility.Section.railControls)
        .union(DisplayChromeVisibility.Section.statusBarReadouts)
        .union([.batteryIndicators, .focusBox])
    for section in DisplayChromeVisibility.configurableSections(in: .clean)
    where !cleanKeeps.contains(section) {
        #expect(
            !MonitorChromePolicy.showsSection(
                section, mode: .clean, capture: .video, preferences: prefs),
            "\(section) must be off in stock clean view")
    }
    for section in DisplayChromeVisibility.configurableSections(in: .live) {
        #expect(
            MonitorChromePolicy.showsSection(
                section, mode: .live, capture: .video, preferences: prefs),
            "\(section) must be on in stock live view")
    }
}

@Test func batteryIndicatorsHideOnRequestPerDispMode() {
    var prefs = OperatorPreferences.defaults
    for mode in DispMode.allCases {
        #expect(
            MonitorChromePolicy.showsBatteryIndicators(
                mode: mode, capture: .video, preferences: prefs),
            "\(mode) ships with the batteries on")
    }

    for mode in DispMode.allCases {
        prefs.toggleChrome(.batteryIndicators, for: mode, capture: .video)
    }
    for mode in DispMode.allCases {
        #expect(
            !MonitorChromePolicy.showsBatteryIndicators(
                mode: mode, capture: .video, preferences: prefs))
    }
    // Photo keeps its own answer — the toggles above were the video side only.
    #expect(
        MonitorChromePolicy.showsBatteryIndicators(
            mode: .live, capture: .photo, preferences: prefs))
}

@Test func assistConfigurationPersistsThroughJSONRoundTrip() throws {
    var configuration = AssistConfiguration.defaults
    configuration.level.style = .gauge
    configuration.zebra.unit = .native
    configuration.magnification.factor = .x4
    configuration.instantReviewSeconds = 8
    configuration.instantReviewShowsFocusPoint = false
    configuration.selectedLUT = .stored(category: .red, fileName: "IPP2_Medium.cube")

    let data = try JSONEncoder().encode(configuration)
    let decoded = try JSONDecoder().decode(AssistConfiguration.self, from: data)

    #expect(decoded == configuration)
}

@Test func assistConfigurationDecodesOlderJSONWithoutTheNewKeys() throws {
    // A config saved before these keys existed must still load: dropping them from a current
    // encoding must decode with their defaults, not fail and wipe the whole config.
    var stored = AssistConfiguration.defaults
    stored.selectedLUT = .builtIn(.nLogRec709)
    let data = try JSONEncoder().encode(stored)
    var dict = try #require(
        try JSONSerialization.jsonObject(with: data) as? [String: Any])
    for key in ["level", "zebra", "instantReviewSeconds"] {
        dict.removeValue(forKey: key)
    }
    let stripped = try JSONSerialization.data(withJSONObject: dict)

    let decoded = try JSONDecoder().decode(AssistConfiguration.self, from: stripped)
    #expect(decoded.selectedLUT == .builtIn(.nLogRec709))
    #expect(decoded.level.style == .horizon)
    #expect(decoded.zebra.unit == .ire)
    #expect(decoded.instantReviewSeconds == 5)
}

@Test func assistConfigurationDecodesABlobWrittenBeforeTheSharedStateTookItsFields() throws {
    // The moved keys (guides, desqueeze, false colour, zebra thresholds, peaking) ride along in an
    // older blob; they are the app migration's to read, and must not stop the rest decoding.
    let legacy = #"""
        {"guides":{"family":"Film","selectedRatios":["2.39:1"],"maskEnabled":false},
        "grid":{"thirds":true,"phi":false,"diagonal":false},
        "level":{"enabled":true,"style":"Gauge"},
        "desqueeze":{"enabled":false,"ratio":"1.33x","factor":1.33,"orientation":"Vertical"},
        "falseColorReferenceEnabled":true,"falseColorScale":"IRE",
        "zebra":{"unit":"Native","highlightEnabled":true,"highlightIRE":95,"highlightColor":"Red",
                "midtoneEnabled":true,"midtoneIRE":55,"midtoneColor":"Amber"},
        "peakingColor":"Blue","peakingSensitivity":"High",
        "selectedLUT":{"builtIn":{"_0":"Log3G10→709"}},"instantReviewSeconds":3}
        """#
    let decoded = try JSONDecoder().decode(AssistConfiguration.self, from: Data(legacy.utf8))
    #expect(decoded.level.style == .gauge)
    #expect(decoded.zebra.unit == .native)
    #expect(decoded.selectedLUT == .builtIn(.log3G10Rec709))
    #expect(decoded.instantReviewSeconds == 3)
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

@Test func assistConfigurationIgnoresTheRetiredScopeKeys() throws {
    // The app's shared scope panel stores own these now; an older blob still decodes and drops
    // them on its next save.
    let data = try JSONEncoder().encode(AssistConfiguration.defaults)
    var dict = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    dict["scopes"] = ["waveformMode": "Luma", "waveformScale": 1.4]
    dict["trafficLights"] = ["scale": 1.2]
    let decoded = try JSONDecoder().decode(
        AssistConfiguration.self, from: try JSONSerialization.data(withJSONObject: dict))
    #expect(decoded == AssistConfiguration.defaults)
    let saved = try #require(
        try JSONSerialization.jsonObject(with: try JSONEncoder().encode(decoded)) as? [String: Any])
    #expect(saved["scopes"] == nil)
    #expect(saved["trafficLights"] == nil)
}

@Test func operatorPreferencesIgnoreAStoredToolbarOrderAndBarVisibility() throws {
    // The shared palette ranks tools by use, so the order and bar visibility an older build saved
    // decode to nothing and leave the blob on its next save.
    let data = try JSONEncoder().encode(OperatorPreferences.defaults)
    var dict = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    dict["assistToolbarOrder"] = ["HISTO", "LUT", "MAG", "NOPE"]
    dict["exposureBarVisibleControls"] = ["PEAK"]
    dict["framingBarVisibleControls"] = []
    let decoded = try JSONDecoder().decode(
        OperatorPreferences.self, from: try JSONSerialization.data(withJSONObject: dict))
    #expect(decoded == OperatorPreferences.defaults)

    let saved = try #require(
        try JSONSerialization.jsonObject(with: try JSONEncoder().encode(decoded)) as? [String: Any])
    #expect(saved["assistToolbarOrder"] == nil)
    #expect(saved["exposureBarVisibleControls"] == nil)
    #expect(saved["framingBarVisibleControls"] == nil)
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

@Test func enteringCleanSweepsInFlightPopups() {
    #expect(!MonitorChromePolicy.dismissesPopupsOnEntry(to: .live))
    // The sweep is entry-only: controls clean itself mounts still present their pop-ups.
    #expect(MonitorChromePolicy.dismissesPopupsOnEntry(to: .clean))
    // Command's dashboard tiles keep their value pickers; nothing is swept entering it.
    #expect(!MonitorChromePolicy.dismissesPopupsOnEntry(to: .command))
}

@Test func commandKeepsTheHeaderStreamUpForLiveTimecode() {
    // Timecode rides the live-view frame header only, so the mode that shows a hero timecode and
    // no image must not end live view (#271).
    #expect(MonitorChromePolicy.streamsHeaderOnly(in: .command))
    #expect(!MonitorChromePolicy.streamsHeaderOnly(in: .live))
    #expect(!MonitorChromePolicy.streamsHeaderOnly(in: .clean))
}

@Test func operatorPreferencesPreserveKnownChoicesBesideFutureEnums() throws {
    var raw = try #require(
        JSONSerialization.jsonObject(
            with: JSONEncoder().encode(OperatorPreferences.defaults)) as? [String: Any])
    raw["hapticsEnabled"] = false
    raw["keepScreenAwake"] = false
    raw["recordConfirmationEnabled"] = false
    raw["bluetoothShutterEnabled"] = false
    raw["autoRotateFeedEnabled"] = false
    raw["relayWatcherPasscode"] = "6203"
    raw["relayAllowsControlRequests"] = false
    raw["streamPreset"] = "future-stream-preset"
    raw["qualityBias"] = "future-quality-bias"
    raw["portraitFeedAspect"] = "future-portrait-aspect"
    raw["relayEncoderProfile"] = "future-relay-profile"
    raw["scopeActivationOrder"] = ["WAVE", "FUTURE", "PLAY", "MAG"]
    var chrome = try #require(raw["displayChrome"] as? [String: Any])
    chrome["statusBarVisible"] = false
    chrome["futureStyle"] = ["color": "amber", "gain": 3]
    raw["displayChrome"] = chrome
    let data = try JSONSerialization.data(withJSONObject: raw)
    let decoded = try JSONDecoder().decode(OperatorPreferences.self, from: data)
    #expect(!decoded.hapticsEnabled)
    #expect(!decoded.keepScreenAwake)
    #expect(!decoded.recordConfirmationEnabled)
    #expect(!decoded.bluetoothShutterEnabled)
    #expect(!decoded.autoRotateFeedEnabled)
    #expect(decoded.relayWatcherPasscode == "6203")
    #expect(!decoded.relayAllowsControlRequests)
    #expect(!decoded.displayChrome.statusBarVisible)
    #expect(decoded.scopeActivationOrder.contains(.waveform))
    #expect(decoded.scopeActivationOrder.contains(.instantReview))
    #expect(!decoded.scopeActivationOrder.contains(.magnification))
}

@Test func operatorPreferencesKeepKnownDisplayModesBesideFutureModes() throws {
    var raw = try #require(
        JSONSerialization.jsonObject(
            with: JSONEncoder().encode(OperatorPreferences.defaults)) as? [String: Any])
    var order = try #require(
        JSONSerialization.jsonObject(
            with: JSONEncoder().encode([DispMode.clean, .live, .command])) as? [String])
    order.insert("future-display-mode", at: 1)
    raw["dispOrder"] = order
    raw["enabledDispModes"] = order
    raw["hapticsEnabled"] = false
    let decoded = try JSONDecoder().decode(
        OperatorPreferences.self,
        from: JSONSerialization.data(withJSONObject: raw))
    #expect(decoded.dispOrder == [.clean, .live, .command])
    #expect(decoded.enabledDispModes == Set([.clean, .live, .command]))
    #expect(!decoded.hapticsEnabled)
}

@Test func operatorPreferencesKeepValidNestedChromeBesideMalformedMember() throws {
    var raw = try #require(
        JSONSerialization.jsonObject(
            with: JSONEncoder().encode(OperatorPreferences.defaults)) as? [String: Any])
    var chrome = try #require(raw["displayChrome"] as? [String: Any])
    chrome["statusBarVisible"] = "future-visibility"
    chrome["cameraValuesVisible"] = false
    chrome["railRecordVisible"] = false
    raw["displayChrome"] = chrome
    raw["hapticsEnabled"] = false
    let decoded = try JSONDecoder().decode(
        OperatorPreferences.self,
        from: JSONSerialization.data(withJSONObject: raw))
    #expect(decoded.displayChrome.statusBarVisible)
    #expect(!decoded.displayChrome.cameraValuesVisible)
    #expect(!decoded.displayChrome.railRecordVisible)
    #expect(!decoded.hapticsEnabled)
}

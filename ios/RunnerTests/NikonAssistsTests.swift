import MonitorPresentation
import OpenCineAppKit
import OpenCineMedia
import XCTest

@testable import OpenZCineCore
@testable import Runner

private typealias MonitorAssistTool = OpenZCineCore.MonitorAssistTool

extension MonitorAssistState where Looks == NikonMonitorLooks {
    /// A state on its own throwaway defaults suite, so tests never read or write the app's.
    static func scratch() -> NikonAssistState {
        restore(storage: UserDefaults(suiteName: "NikonAssists.\(UUID().uuidString)")!)
    }
}

/// Nikon's assists on the shared Pocket / Insta `MonitorAssistState`: the Nikon-only mapping, the
/// DISP 2 pin filter, and the one-time copy of the operator's Nikon blobs.
@MainActor
final class NikonAssistsTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite = ""

    override func setUp() async throws {
        suite = "NikonAssistsTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    /// A second, untouched install inside one test.
    private func reinstall() {
        defaults.removePersistentDomain(forName: suite)
        suite = "NikonAssistsTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    private func relaunch() -> NikonAssistState { .restore(storage: defaults) }

    /// Writes the Nikon blobs a pre-migration build left behind, then launches once.
    private func migrate(preferences: [String: Any] = [:], configuration: [String: Any] = [:])
        throws -> NikonAssistState
    {
        defaults.set(
            try JSONSerialization.data(withJSONObject: preferences),
            forKey: NikonAssistState.legacyPreferencesKey)
        defaults.set(
            try JSONSerialization.data(withJSONObject: configuration),
            forKey: NikonAssistState.legacyConfigurationKey)
        return relaunch()
    }

    private func crushClip(_ configuration: [String: Any]) throws -> MonitorCrushClipCompensation {
        try migrate(configuration: configuration).crushClipCompensation
    }

    // MARK: - Mapping

    func testEveryNikonToolSavesUnderItsSharedName() {
        for tool in MonitorAssistTool.allCases {
            XCTAssertEqual(tool.selection.rawValue, tool.rawValue)
        }
        XCTAssertFalse(MonitorAssistTool.nikonCleanPinCases.contains(.evMeter))
        XCTAssertEqual(MonitorFalseColorSelection.stops.nikonScale, .stops)
        XCTAssertEqual(MonitorFalseColorSelection.sceneStops.nikonScale, .stops)
    }

    func testAFreshInstallTakesTheSharedDefaults() {
        let state = relaunch()
        XCTAssertTrue(state.liveTools.isEmpty)
        XCTAssertTrue(state.playbackTools.isEmpty)
        XCTAssertFalse(state.lutEnabled)
        XCTAssertFalse(state.splitComparison)
        XCTAssertTrue(state.splitVertical)
        XCTAssertEqual(state.zebraHighlightIRE, LiveZebra.highlightIRE)
        XCTAssertEqual(state.crushClipCompensation, .zero)
        XCTAssertEqual(state.cleanViewPinnedTools, [.lut, .peaking, .desqueeze, .mirror])
    }

    // MARK: - Persistence

    func testLiveAndPlaybackToolsPersistIndependently() {
        let state = relaunch()
        state.set(.falseColor, visible: true, context: .liveView)
        state.set(.peaking, visible: true, context: .liveView)
        state.set(.lut, visible: true, context: .playback)
        state.set(.histogram, visible: true, context: .playback)

        let reloaded = relaunch()
        XCTAssertEqual(reloaded.liveTools, [.falseColor, .peaking])
        XCTAssertEqual(reloaded.playbackTools, [.lut, .histogram])
    }

    func testWiredViewAssistOptionsSurviveARelaunch() {
        let state = relaunch()
        state.falseColorScale = .limits
        state.zebraHighlightIRE = 88
        state.zebraMidtone = false
        state.peakingColor = .green
        state.peakingSensitivity = .high
        state.crushClipCompensation = .threeQuarter
        state.persist()

        let reloaded = relaunch()
        XCTAssertEqual(reloaded.falseColorScale, .limits)
        XCTAssertEqual(reloaded.zebraHighlightIRE, 88)
        XCTAssertFalse(reloaded.zebraMidtone)
        XCTAssertEqual(reloaded.peakingColor, .green)
        XCTAssertEqual(reloaded.peakingSensitivity, .high)
        XCTAssertEqual(reloaded.crushClipCompensation, .threeQuarter)
    }

    func testAnExplicitZeroCompensationRoundTrips() {
        let state = relaunch()
        state.crushClipCompensation = .half
        state.persist()
        state.crushClipCompensation = .zero
        state.persist()
        XCTAssertEqual(relaunch().crushClipCompensation, .zero)
    }

    func testCleanViewPinsRoundTrip() {
        let state = relaunch()
        for tool in state.cleanViewPinnedTools { state.toggleCleanViewPin(tool) }
        state.toggleCleanViewPin(MonitorAssistTool.guides.selection)
        state.toggleCleanViewPin(MonitorAssistTool.histogram.selection)
        state.toggleCleanViewPin(MonitorAssistTool.histogram.selection)  // second toggle un-pins
        XCTAssertEqual(relaunch().cleanViewPinnedTools, [.guides])
    }

    func testTheCameraEVMeterCannotBePinned() {
        let state = relaunch()
        state.toggleCleanViewPin(MonitorAssistTool.evMeter.selection)
        XCTAssertFalse(state.cleanViewPinnedTools.contains(.evMeter))
    }

    // MARK: - DISP 2 pins

    func testCleanShowsTheStockPinsAndHidesEveryOtherTool() {
        let state = relaunch()
        for tool in MonitorAssistTool.activeCases { state.set(tool, visible: true, context: .liveView) }
        let stock = NikonAssistState.cleanViewDefaultPinnedTools
        for tool in MonitorAssistTool.activeCases {
            XCTAssertTrue(state.isVisible(tool.selection), "\(tool) must show in live")
        }
        state.clean = true
        for tool in MonitorAssistTool.activeCases {
            XCTAssertEqual(
                state.isVisible(tool.selection), stock.contains(tool.selection),
                "\(tool) in clean must follow the stock pin set")
        }
    }

    func testCommandShowsNoFeedTool() {
        let model = NativeAppModel(assist: .restore(storage: defaults))
        model.assist.set(.peaking, visible: true, context: .liveView)
        model.displayMode = .command
        XCTAssertTrue(model.renderedLiveAssistTools.isEmpty)
    }

    func testCleanShowsExactlyThePinnedToolsAndRestoresOnLeaving() {
        let state = relaunch()
        for tool in [MonitorAssistTool.histogram, .peaking, .guides] {
            state.set(tool, visible: true, context: .liveView)
        }
        state.cleanViewPinnedTools = [.peaking]
        state.clean = true
        XCTAssertEqual(
            MonitorAssistTool.activeCases.filter { state.isVisible($0.selection) }, [.peaking])
        // Leaving clean restores the operator's set untouched; the pin only ever filters.
        state.clean = false
        XCTAssertEqual(state.liveTools, [.histogram, .peaking, .guides])
    }

    func testAPinCannotResurrectASwitchedOffTool() {
        let state = relaunch()
        state.toggleCleanViewPin(MonitorAssistTool.waveform.selection)
        state.clean = true
        XCTAssertFalse(state.isVisible(MonitorAssistTool.waveform.selection))
    }

    func testPinsAreLiveViewOnly() {
        let state = relaunch()
        state.set(.histogram, visible: true, context: .playback)
        state.clean = true
        XCTAssertEqual(state.playbackTools, [.histogram])
    }

    // MARK: - 50/50 comparison

    func testSplitComparisonFollowsTheCleanViewPinLikeTheLUTItself() {
        let state = relaunch()
        state.splitComparison = true
        state.set(.lut, visible: true, context: .liveView)
        state.cleanViewPinnedTools = []
        func split() -> SplitComparisonOrientation? {
            LUTResolution.splitComparison(
                visibleTools: Set(MonitorAssistTool.activeCases.filter { state.isVisible($0.selection) }),
                enabled: state.splitComparison, vertical: state.splitVertical)
        }
        XCTAssertNotNil(split())
        // Clean drops the tool unless pinned, so the comparison leaves with it.
        state.clean = true
        XCTAssertNil(split())
        state.cleanViewPinnedTools = [.lut]
        XCTAssertNotNil(split())
    }

    func testSplitOrientationSurvivesSwitchingTheComparisonOff() {
        let state = relaunch()
        state.splitComparison = true
        state.splitVertical = false
        state.persist()
        state.splitComparison = false
        state.persist()

        let reloaded = relaunch()
        XCTAssertFalse(reloaded.splitComparison)
        XCTAssertFalse(reloaded.splitVertical)
    }

    func testPlaybackToolsDoNotTouchTheScopeOrder() {
        let model = NativeAppModel(assist: .restore(storage: defaults))
        // The preferences live in the host app's defaults, which a demo launch may have written.
        model.preferences.scopeActivationOrder = []
        model.setAssist(.waveform, visible: true, context: .playback)
        XCTAssertTrue(model.preferences.scopeActivationOrder.isEmpty)
    }

    // MARK: - Palette

    func testPhotographyLeadsWithInstantPlaybackThenTheEVMeter() {
        let photo = MonitorAssistTool.activeCases.filter(\.appliesToPhotography).map(\.rawValue)
        let ranked = MonitorToolUsage().rankedIDs(in: photo, seed: nikonAssistUsageSeed)
        XCTAssertEqual(Array(ranked.prefix(2)), ["PLAY", "EV"])
    }

    func testPlaybackOffersNoCameraFedTool() {
        let tools = NativeAppModel(assist: .restore(storage: defaults)).playbackAssistPaletteTools
        for tool in [MonitorAssistTool.level, .evMeter, .instantReview, .magnification] {
            XCTAssertFalse(tools.contains(tool), "\(tool) needs a camera")
        }
        XCTAssertTrue(tools.contains(.waveform))
    }

    // MARK: - Migration from the Nikon blobs

    func testMigrationReadsTheLegacySingleContextToolKey() throws {
        let state = try migrate(preferences: ["visibleAssistTools": ["PEAK", "WAVE"]])
        XCTAssertEqual(state.liveTools, [.peaking, .waveform])
        XCTAssertTrue(state.playbackTools.isEmpty)
        XCTAssertFalse(state.lutEnabled)
    }

    func testMigrationCopiesToolsPinsAndSplitOnce() throws {
        let state = try migrate(preferences: [
            "liveViewVisibleAssistTools": ["LUT", "ZEBRA", "EV"],
            "playbackVisibleAssistTools": ["HISTO", "EV"],
            "cleanViewPinnedTools": ["ZEBRA", "EV"],
            "splitComparisonEnabled": true,
            "splitComparisonOrientation": "Top / Bottom",
        ])
        XCTAssertEqual(state.liveTools, [.lut, .zebra, .evMeter])
        XCTAssertEqual(state.playbackTools, [.histogram])
        XCTAssertEqual(state.cleanViewPinnedTools, [.zebra])
        XCTAssertTrue(state.splitComparison)
        XCTAssertFalse(state.splitVertical)

        // The shared snapshot now exists, so a later launch never re-reads the Nikon blob.
        state.set(.zebra, visible: false, context: .liveView)
        XCTAssertEqual(relaunch().liveTools, [.lut, .evMeter])
        XCTAssertEqual(relaunch().cleanViewPinnedTools, [.zebra])
    }

    func testMigrationWithoutPinsKeepsTheStockSetAndSplitOff() throws {
        let state = try migrate(preferences: ["liveViewVisibleAssistTools": ["PEAK"]])
        XCTAssertEqual(state.cleanViewPinnedTools, NikonAssistState.cleanViewDefaultPinnedTools)
        XCTAssertFalse(state.splitComparison)
        XCTAssertTrue(state.splitVertical)
    }

    func testMigrationKeepsTheOperatorsOptions() throws {
        let state = try migrate(configuration: [
            "guides": ["family": "Film", "selectedRatios": ["2.39:1"], "maskEnabled": true],
            "grid": ["thirds": false, "phi": true, "diagonal": true],
            "falseColorScale": "Limits",
            "falseColorReferenceEnabled": false,
            "zebra": [
                "highlightEnabled": true, "midtoneEnabled": false, "highlightIRE": 100,
                "midtoneIRE": 60, "highlightColor": "Red", "midtoneColor": "White",
            ],
            "peakingColor": "Green", "peakingSensitivity": "High",
        ])
        XCTAssertEqual(state.selectedGuides, [.cinema])
        XCTAssertTrue(state.guideMask)
        XCTAssertEqual(state.gridOptions, [.phi, .diagonal])
        XCTAssertEqual(state.falseColorScale, .limits)
        XCTAssertFalse(state.falseColorReference)
        // A migrated operator keeps their zebra level; only fresh installs take the shared 99.
        XCTAssertEqual(state.zebraHighlightIRE, 100)
        XCTAssertFalse(state.zebraMidtone)
        XCTAssertEqual(state.zebraMidtoneIRE, 60)
        XCTAssertEqual(state.zebraHighlightColor, .red)
        XCTAssertEqual(state.zebraMidtoneColor, .white)
        XCTAssertEqual(state.peakingColor, .green)
        XCTAssertEqual(state.peakingSensitivity, .high)
    }

    func testMigrationReadsThePreZebraBlockHighlightLevel() throws {
        XCTAssertEqual(try migrate(configuration: ["zebraHighlightIRE": 95]).zebraHighlightIRE, 95)
    }

    func testMigrationTurnsNikonsShrunkAxisIntoTheSharedDirection() throws {
        // Nikon "Horizontal" shrank the width (pillarbox): the shared vertical direction.
        let pillarbox = try migrate(configuration: [
            "desqueeze": ["factor": 2.0, "orientation": "Horizontal"]
        ])
        XCTAssertEqual(pillarbox.desqueezeFactor, 2)
        XCTAssertFalse(pillarbox.desqueezeHorizontal)
        XCTAssertFalse(pillarbox.desqueezeCustom)
        XCTAssertEqual(pillarbox.desqueeze(visible: true), NikonDesqueeze(factor: 2, horizontal: false))
        XCTAssertEqual(pillarbox.desqueeze(visible: false), .off)
    }

    func testMigrationReadsTheOlderRatioAndLeavesAnUnchosenFactor() throws {
        let ratio = try migrate(configuration: ["desqueeze": ["ratio": "1.5x", "orientation": "Vertical"]])
        XCTAssertEqual(ratio.desqueezeFactor, 1.5)
        XCTAssertTrue(ratio.desqueezeHorizontal)

        reinstall()
        let unchosen = try migrate(configuration: ["desqueeze": ["factor": 1.0]])
        XCTAssertEqual(unchosen.desqueezeFactor, 1.33)
    }

    func testMigrationSurvivesMalformedValues() throws {
        defaults.set(Data("not json".utf8), forKey: NikonAssistState.legacyPreferencesKey)
        defaults.set(
            try JSONSerialization.data(withJSONObject: [
                "zebra": ["highlightIRE": "high", "highlightColor": "Plaid"],
                "falseColorScale": 7,
                "desqueeze": ["factor": -2],
                "guides": ["selectedRatios": ["9:9"]],
                "scopes": ["crushClipCompensation": "x"],
            ]),
            forKey: NikonAssistState.legacyConfigurationKey)
        let state = relaunch()
        XCTAssertTrue(state.liveTools.isEmpty)
        XCTAssertEqual(state.zebraHighlightIRE, LiveZebra.highlightIRE)
        XCTAssertEqual(state.zebraHighlightColor, .white)
        XCTAssertEqual(state.falseColorScale, .sceneStops)
        XCTAssertEqual(state.desqueezeFactor, 1.33)
        XCTAssertEqual(state.crushClipCompensation, .zero)
    }

    // MARK: - Crush / clip from every era of the Nikon blob

    func testMigrationClampsCompensationValuesFromTheOlderRange() throws {
        // The earlier range went to 2.0 stops (raw 15/20); they clamp to the 1.0-stop ceiling.
        XCTAssertEqual(try crushClip(["scopes": ["crushClipCompensation": 15]]), .one)
        reinstall()
        XCTAssertEqual(try crushClip(["scopes": ["crushClipCompensation": 20]]), .one)
        reinstall()
        XCTAssertEqual(try crushClip(["scopes": ["crushClipCompensation": 3]]), .zero)
    }

    func testMigrationReadsTheLegacyTrafficSensitivityPercent() throws {
        XCTAssertEqual(try crushClip(["scopes": ["histogramTrafficSensitivity": 15]]), .one)
    }

    func testMigrationHonorsACustomizedSplitEraHistogramValue() throws {
        XCTAssertEqual(
            try crushClip([
                "scopes": ["histogramNoiseFloorCompensation": 15],
                "trafficLights": ["scale": 1.2, "crushClipCompensation": 5],
            ]), .one)
    }

    func testMigrationFoldsInACustomizedTrafficLightsValue() throws {
        XCTAssertEqual(
            try crushClip([
                "scopes": ["histogramCrushClipCompensation": 0],
                "trafficLights": ["scale": 1.0, "crushClipCompensation": 7],
            ]), .threeQuarter)
    }

    func testMigrationReadsTheRenamedHistogramKey() throws {
        XCTAssertEqual(
            try crushClip([
                "scopes": ["histogramCrushClipCompensation": 5], "trafficLights": ["scale": 1.0],
            ]), .half)
    }

    func testMigrationLeavesUntouchedSplitEraZerosOnTheSharedDefault() throws {
        // Stored zeros were the old default, so "never touched" takes the shared default (zero).
        XCTAssertEqual(
            try crushClip([
                "scopes": ["histogramCrushClipCompensation": 0],
                "trafficLights": ["scale": 1.0, "crushClipCompensation": 0],
            ]), .zero)
    }

    func testMigrationKeepsAnExplicitSharedZero() throws {
        XCTAssertEqual(
            try crushClip([
                "scopes": ["crushClipCompensation": 0, "histogramCrushClipCompensation": 10]
            ]), .zero)
    }

    // MARK: - Scope panels on the shared stores

    /// Writes the Nikon scope blobs a pre-migration build left behind, then launches once.
    private func scopePanels(
        scopes: Any = [String: Any](), trafficLights: Any? = nil, positions: Any? = nil
    ) throws -> NikonScopePanels {
        var configuration: [String: Any] = ["scopes": scopes]
        configuration["trafficLights"] = trafficLights
        defaults.set(
            try JSONSerialization.data(withJSONObject: configuration),
            forKey: NikonScopePanels.legacyConfigurationKey)
        if let positions {
            defaults.set(
                try JSONSerialization.data(withJSONObject: positions),
                forKey: NikonScopePanels.legacyPositionsKey)
        }
        return NikonScopePanels(storage: defaults)
    }

    func testAFreshInstallTakesTheSharedScopeDefaults() {
        let panels = NikonScopePanels(storage: defaults)
        XCTAssertEqual(panels.waveform.options, .default)
        XCTAssertEqual(panels.parade.options, .default)
        XCTAssertEqual(panels.vectorscope.options, .default)
        XCTAssertEqual(panels.histogram.options, .default)
        XCTAssertEqual(panels.trafficLights.scale, 1)
        XCTAssertNil(panels.trafficLights.position)
    }

    func testScopeMigrationCopiesTheOperatorsSettingsOnce() throws {
        let panels = try scopePanels(scopes: [
            "waveformMode": "RGB", "waveformScale": 1.4,
            "waveformGuides": ["clip": true, "crush": false, "middle": true],
            "waveformBrightness": 150, "paradeMode": "YRGB",
            "paradeGuides": ["clip": true, "crush": true, "middle": false],
            "paradeBrightness": 80, "histogramScale": 0.7, "histogramTrafficLights": false,
            "vectorscopeZoom": "2x", "waveformParadeBrightnessCalibrationVersion": 2,
        ])
        XCTAssertEqual(panels.waveform.options.mode, .rgb)
        XCTAssertEqual(panels.waveform.options.scale, 1.4)
        XCTAssertTrue(panels.waveform.options.hasCustomScale)
        XCTAssertFalse(panels.waveform.options.guides.crush)
        XCTAssertTrue(panels.waveform.options.guides.clip)  // untouched flags stay on
        XCTAssertEqual(panels.waveform.options.brightness, 150)
        XCTAssertEqual(panels.parade.options.mode, .yrgb)
        XCTAssertFalse(panels.parade.options.guides.middle)
        XCTAssertEqual(panels.parade.options.brightness, 80)
        XCTAssertEqual(panels.vectorscope.options.zoom, .x2)
        XCTAssertEqual(panels.histogram.options.scale, 0.7)
        XCTAssertFalse(panels.histogram.options.trafficLights)

        // The shared stores now exist, so a later launch never re-reads the Nikon blob.
        panels.waveform.options.mode = .luma
        XCTAssertEqual(NikonScopePanels(storage: defaults).waveform.options.mode, .luma)
        XCTAssertEqual(NikonScopePanels(storage: defaults).parade.options.brightness, 80)
    }

    func testScopeMigrationRaisesPreCalibrationTraceBrightness() throws {
        let panels = try scopePanels(scopes: [
            "waveformBrightness": 25, "paradeBrightness": 50, "vectorscopeBrightness": 25,
        ])
        XCTAssertEqual(panels.waveform.options.brightness, 100)
        XCTAssertEqual(panels.parade.options.brightness, 200)
        XCTAssertEqual(panels.vectorscope.options.brightness, 25)
    }

    func testScopeMigrationClampsBrightnessToTheVisualMaximum() throws {
        let raised = try scopePanels(scopes: ["waveformBrightness": 51, "paradeBrightness": 200])
        XCTAssertEqual(raised.waveform.options.brightness, 200)
        XCTAssertEqual(raised.parade.options.brightness, 200)

        reinstall()
        let calibrated = try scopePanels(scopes: [
            "waveformBrightness": 999, "paradeBrightness": -5,
            "waveformParadeBrightnessCalibrationVersion": 2,
        ])
        XCTAssertEqual(calibrated.waveform.options.brightness, 200)
        XCTAssertEqual(calibrated.parade.options.brightness, 0)

        reinstall()
        let unset = try scopePanels(scopes: ["waveformMode": "RGB"])
        XCTAssertEqual(unset.waveform.options.brightness, MonitorWaveformOptions.defaultBrightness)
        XCTAssertEqual(unset.parade.options.brightness, MonitorParadeOptions.defaultBrightness)
    }

    func testScopeMigrationClampsScaleAndLeavesAnUnsavedOneAutomatic() throws {
        let panels = try scopePanels(scopes: ["waveformScale": 99, "paradeScale": -5])
        XCTAssertEqual(panels.waveform.options.scale, 1.6)
        XCTAssertEqual(panels.parade.options.scale, 0.6)
        XCTAssertEqual(panels.histogram.options.scale, MonitorHistogramOptions.defaultScale)
        XCTAssertFalse(panels.histogram.options.hasCustomScale)
    }

    func testScopeMigrationIgnoresRetiredScopeKeys() throws {
        // Skin tone and the Small/Medium/Large size presets predate the continuous scale.
        let panels = try scopePanels(scopes: [
            "waveformSkinTone": ["enabled": true, "color": "Rose"],
            "waveformSize": "Large", "paradeSize": "Small", "waveformMode": "RGB",
        ])
        XCTAssertEqual(panels.waveform.options.mode, .rgb)  // a still-valid key is honoured
        XCTAssertEqual(panels.waveform.options.guides, .default)
        XCTAssertEqual(panels.waveform.options.scale, MonitorWaveformOptions.defaultScale)
        XCTAssertEqual(panels.parade.options.scale, MonitorParadeOptions.defaultScale)
    }

    func testScopeMigrationPlacesSavedPanelsInTheLandscapeSlot() throws {
        let panels = try scopePanels(
            trafficLights: ["scale": 1.2],
            positions: [
                "wave": ["xFraction": 0.25, "yFraction": 0.3],
                "traffic-lights": ["xFraction": 0.08, "yFraction": 0.58],
                "audio": ["xFraction": 0.9, "yFraction": 0.9],
            ])
        XCTAssertEqual(
            panels.waveform.options.storedCenter,
            MonitorScopeStoredCenter(xFraction: 0.25, yFraction: 0.3))
        XCTAssertNil(panels.waveform.options.storedCenterPortrait)
        XCTAssertNil(panels.parade.options.storedCenter)
        XCTAssertEqual(
            panels.trafficLights.position, MonitorScopeStoredCenter(xFraction: 0.08, yFraction: 0.58))
        XCTAssertEqual(panels.trafficLights.scale, 1.2)
    }

    func testScopeMigrationSurvivesMalformedValues() throws {
        let panels = try scopePanels(
            scopes: [
                "waveformMode": "Sparkle", "waveformBrightness": "bright", "vectorscopeZoom": 3,
                "waveformGuides": "on", "histogramTrafficLights": "yes",
            ],
            trafficLights: ["scale": "big"], positions: ["wave": "left"])
        XCTAssertEqual(panels.waveform.options.mode, .rgb)
        XCTAssertEqual(panels.waveform.options.brightness, MonitorWaveformOptions.defaultBrightness)
        XCTAssertEqual(panels.waveform.options.guides, .default)
        XCTAssertNil(panels.waveform.options.storedCenter)
        XCTAssertEqual(panels.vectorscope.options.zoom, .x1)
        XCTAssertTrue(panels.histogram.options.trafficLights)
        XCTAssertEqual(panels.trafficLights.scale, 1)
    }

    func testAMovedPanelSavesToTheSlotForItsOrientation() {
        let panels = NikonScopePanels(storage: defaults)
        let portrait = CGRect(x: 0, y: 0, width: 400, height: 800)
        panels.slot(for: .waveform).store(center: CGPoint(x: 100, y: 200), in: portrait)
        panels.slot(for: .trafficLights).store(center: CGPoint(x: 200, y: 400), in: portrait)
        let stored = MonitorScopeStoredCenter(xFraction: 0.25, yFraction: 0.25)
        XCTAssertEqual(panels.waveform.options.storedCenterPortrait, stored)
        XCTAssertNil(panels.waveform.options.storedCenter)
        XCTAssertEqual(
            panels.trafficLights.positionPortrait,
            MonitorScopeStoredCenter(xFraction: 0.5, yFraction: 0.5))
        XCTAssertNil(panels.trafficLights.position)
        let relaunched = NikonScopePanels(storage: defaults)
        XCTAssertEqual(relaunched.waveform.options.storedCenterPortrait, stored)
        XCTAssertEqual(
            relaunched.trafficLights.positionPortrait,
            MonitorScopeStoredCenter(xFraction: 0.5, yFraction: 0.5))
    }
}

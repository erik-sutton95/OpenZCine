import Testing

@testable import Runner

@Suite("Edit view entry and exit")
struct ChromeEditorReturnTests {

    @MainActor
    @Test("Opening the Edit view leaves Settings and switches the monitor to the mode being edited")
    func openingTheEditorShowsTheRealThing() {
        let model = NativeAppModel()
        model.activePanel = .settings

        model.beginChromeEditing(.clean)

        #expect(model.activePanel == nil)
        #expect(model.displayMode == .clean)
        #expect(model.chromeEditorMode == .clean)
    }

    @MainActor
    @Test("Done returns to Display settings on the section that was being edited")
    func doneReturnsToDisplaySettings() {
        // The operator came from Settings ▸ Display and the other DISP sections are what they came
        // to arrange — dropping them on the live monitor makes them find their way back, past a
        // rail they may have just hidden.
        let model = NativeAppModel()
        model.beginChromeEditing(.clean)

        model.endChromeEditing()

        #expect(model.chromeEditorMode == nil)
        #expect(model.activePanel == .settings)
        #expect(model.operatorSettingsTab == .display)
        #expect(model.chromeEditorReturnMode == .clean)
    }

    @MainActor
    @Test("The rail plan the monitor renders follows the camera's capture side")
    func railPlanFollowsTheCaptureSide() {
        let model = NativeAppModel()
        // No camera attached in a unit run, so the body reports video.
        #expect(model.captureLayoutMode == .video)

        // Set rather than toggle: `NativeAppModel()` loads the persisted preferences, so a stored
        // value from a previous run would make a toggle flip the wrong way.
        model.preferences = OperatorPreferences.defaults
        model.preferences.displayChrome.railMediaVisible = false
        #expect(!model.monitorSideRailPlan.media)
        #expect(
            model.preferences.chrome(for: .live, capture: .photo).railMediaVisible,
            "the stills layout keeps its own answer")
    }
}

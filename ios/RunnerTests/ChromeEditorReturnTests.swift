import CoreGraphics
import OpenCineAppKit
import OpenZCineCore
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

/// The Edit view's eye badges use the shared placement over this monitor's own sections.
@Suite("Edit view badge placement")
struct ChromeEditBadgePlacementTests {
    @Test("Badges sit on their own element, on screen, and never stack up")
    func editBadgesTakeAPlaceOnTheirOwnElementAndNeverStackUp() throws {
        // Real measured landscape boxes from an iPhone 15 Pro (852x393): the four readouts nest
        // inside the status bar, and the rail and camera-value strip sit flush against the edges.
        let boxes: [(key: DisplayChromeVisibility.Section, frame: CGRect)] = [
            (.statusBar, CGRect(x: 69, y: 16, width: 678, height: 42)),
            (.sideRails, CGRect(x: 763, y: 14, width: 83, height: 289)),
            (.assistToolbar, CGRect(x: 16, y: 321, width: 344, height: 58)),
            (.cameraValues, CGRect(x: 368, y: 321, width: 466, height: 58)),
            (.lockButton, CGRect(x: 16, y: 17, width: 40, height: 40)),
            (.batteryIndicators, CGRect(x: 8, y: 63, width: 41, height: 35)),
            (.recReadout, CGRect(x: 81, y: 23, width: 67, height: 27)),
            (.codecReadout, CGRect(x: 377, y: 22, width: 98, height: 30)),
            (.mediaReadout, CGRect(x: 485, y: 22, width: 132, height: 30)),
            (.fpsReadout, CGRect(x: 627, y: 22, width: 108, height: 29)),
        ]

        let frames = MonitorChromeEditBadgeLayout.badgeFrames(
            keyed: boxes, viewport: CGSize(width: 852, height: 393))

        #expect(frames.count == boxes.count, "every measured element must get a badge")
        for (section, frame) in frames {
            #expect(
                frame.minX >= 0 && frame.minY >= 0,
                "\(section) badge ran off the top or leading edge")
            #expect(
                frame.maxX <= 852 && frame.maxY <= 393,
                "\(section) badge ran off the trailing or bottom edge")
            // Still reads as belonging to its element: the centre stays within one badge of the box.
            let box = try #require(boxes.first { $0.key == section }).frame
            let pad = MonitorChromeEditBadgeLayout.badgeSize
            #expect(
                box.insetBy(dx: -pad, dy: -pad).contains(CGPoint(x: frame.midX, y: frame.midY)),
                "\(section) badge drifted away from the element it controls")
        }
        // No two badges collide: the readouts nested inside the status bar are the hard case.
        let all = Array(frames.values)
        for i in all.indices {
            for j in all.indices where j > i {
                #expect(!all[i].intersects(all[j]), "two badges overlap at \(all[i]) and \(all[j])")
            }
        }
    }

    @Test("An unmeasured element gets no badge")
    func editBadgeLayoutSkipsUnmeasuredElements() {
        let frames = MonitorChromeEditBadgeLayout.badgeFrames(
            keyed: [
                (key: DisplayChromeVisibility.Section.statusBar, frame: CGRect.zero),
                (key: .lockButton, frame: CGRect(x: 16, y: 17, width: 40, height: 40)),
            ],
            viewport: CGSize(width: 852, height: 393))

        #expect(frames[.statusBar] == nil)
        #expect(frames[.lockButton] != nil)
    }

    @MainActor
    @Test("A badge shows and hides its element on the capture side the body reports")
    func badgesFollowTheCaptureSide() {
        let model = NativeAppModel()
        let capture = model.captureLayoutMode
        let before = model.isChromeVisible(.lockButton, in: .live)
        #expect(
            before == model.preferences.chrome(for: .live, capture: capture).isVisible(.lockButton))

        model.toggleChrome(.lockButton, for: .live)

        #expect(model.isChromeVisible(.lockButton, in: .live) == !before)
        #expect(
            model.preferences.chrome(for: .live, capture: capture).isVisible(.lockButton) == !before
        )
        #expect(
            model.isChromeConfigurable(.focusBox, in: .live)
                == DisplayChromeVisibility.isConfigurable(.focusBox, in: .live))
        model.toggleChrome(.lockButton, for: .live)
    }
}
